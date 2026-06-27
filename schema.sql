-- Schema for Claude Code session analytics
-- One table of raw JSON, made fast two ways:
--   1. JSON type hints -- the plain scalar fields (sessionId, type, token
--      counts, ...) are declared with concrete types inside the JSON column, so
--      they are stored as native typed subcolumns. No separate materialized
--      column is needed for a simple "data.x::Type" -- the hint already gives
--      typed, columnar storage.
--   2. Materialized columns -- only for values that need real computation from
--      data.message.content (a Dynamic that is a String or an Array): the
--      content-derived flags, the searchable text, the first-question text,
--      the project (parsed from path), etc. These let interactive queries
--      avoid scanning the multi-GB content on every request.
-- Both are computed on INSERT; you still only insert (path, data).
--
-- Step 1: Create the table:
--   clickhouse-client < schema.sql
--   (Needs a recent ClickHouse: the text index is a production feature, governed
--    by the enable_full_text_index setting which is on by default. On older
--    versions it was allow_experimental_full_text_index and had to be set first.)
--
-- Step 2: Load data (see upload_incremental.sh for repeated/incremental loads):
--   clickhouse-local -q "SELECT _path AS path, json AS data FROM file('$HOME/.claude/projects/*/*.jsonl', 'JSONAsString') WHERE isValidJSON(json) SETTINGS input_format_allow_errors_ratio=0.1 FORMAT Native" | clickhouse-client -q "INSERT INTO claude_code.raw FORMAT Native"

CREATE DATABASE IF NOT EXISTS claude_code;

CREATE TABLE IF NOT EXISTS claude_code.raw
(
    path String,

    -- JSON with type hints: these paths get native typed, columnar storage.
    data JSON(
        sessionId String,
        uuid String,
        parentUuid String,
        type LowCardinality(String),
        subtype LowCardinality(String),
        isMeta Bool,
        gitBranch String,
        summary String,
        durationMs UInt32,
        version String,
        message.model LowCardinality(String),
        message.usage.input_tokens UInt64,
        message.usage.output_tokens UInt64,
        message.usage.cache_read_input_tokens UInt64,
        message.usage.cache_creation_input_tokens UInt64
    ),

    -- Computed columns (NOT plain type casts) -- these earn their keep by
    -- avoiding repeated work or, crucially, reads of data.message.content.
    -- message.content is a Dynamic (String or Array), so array access uses the
    -- content[].field idiom (NOT ::Array(JSON), which throws on string-valued
    -- rows during INSERT) and string access is guarded by dynamicType()='String'.
    project      LowCardinality(String)  MATERIALIZED replaceAll(replaceRegexpOne(path, '.*/projects/([^/]+)/.*', '\\1'), '-', '/'),
    ts           Nullable(DateTime64(3)) MATERIALIZED parseDateTime64BestEffortOrNull(data.timestamp::String),
    content_kind LowCardinality(String)  MATERIALIZED dynamicType(data.message.content),
    user_text    String MATERIALIZED if(data.type::String = 'user' AND dynamicType(data.message.content) = 'String', data.message.content::String, ''),
    is_root_user UInt8  MATERIALIZED data.type::String = 'user' AND data.parentUuid::String = '',
    root_text    String MATERIALIZED if(data.type::String = 'user' AND data.parentUuid::String = '', multiIf(dynamicType(data.message.content) = 'String', data.message.content::String, toJSONString(data.message.content)), ''),
    is_plan      UInt8  MATERIALIZED data.type::String = 'assistant' AND has(arrayMap(x -> x::String, data.message.content[].name), 'EnterPlanMode'),
    is_approved  UInt8  MATERIALIZED data.type::String = 'user' AND arrayExists((t, e) -> t::String = 'tool_result' AND (e::String = 'false' OR e::String = ''), data.message.content[].type, data.message.content[].is_error),
    is_rejected  UInt8  MATERIALIZED data.type::String = 'user' AND arrayExists((t, e, c) -> t::String = 'tool_result' AND e::String = 'true' AND c::String LIKE '%tool use was rejected%', data.message.content[].type, data.message.content[].is_error, data.message.content[].content),

    -- Lowercased, concatenated searchable text + an ngram text index, so
    -- substring search (search_text LIKE '%term%') prunes granules instead of
    -- scanning every row's content. To benefit at query time:
    --   * keep enable_full_text_index on (production, on by default),
    --   * match the lowercased term, and
    --   * reference search_text only in WHERE, never in SELECT (else the whole
    --     column is read and the index is bypassed).
    -- Tradeoffs: search_text roughly triples on-disk size and makes merges
    -- heavier (each merge rebuilds the index); ngram pruning is strong only for
    -- terms with rare character sequences.
    search_text String MATERIALIZED lower(toString(data.message.content) || ' ' || data.toolUseResult.content::String || ' ' || data.toolUseResult.stdout::String || ' ' || data.toolUseResult.stderr::String || ' ' || data.summary::String),
    INDEX idx_search search_text TYPE text(tokenizer = 'ngrams') GRANULARITY 1
)
ENGINE = ReplacingMergeTree
ORDER BY (data.sessionId::String, data.timestamp::String, data.uuid::String);
