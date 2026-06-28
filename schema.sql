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

    -- Lines added/removed per row (summed across the row's Edit/Write tool calls),
    -- so the session list sums small typed columns instead of ARRAY JOINing the
    -- content on every load.
    lines_added   UInt32 MATERIALIZED
        arraySum(arrayMap((t, n, s) -> if(t::String = 'tool_use' AND n::String = 'Edit' AND s::String != '', countSubstrings(s::String, '\n') + 1, 0), data.message.content[].type, data.message.content[].name, data.message.content[].input.new_string))
      + arraySum(arrayMap((t, n, c) -> if(t::String = 'tool_use' AND n::String = 'Write' AND c::String != '', countSubstrings(c::String, '\n') + 1, 0), data.message.content[].type, data.message.content[].name, data.message.content[].input.content)),
    lines_removed UInt32 MATERIALIZED
        arraySum(arrayMap((t, n, o) -> if(t::String = 'tool_use' AND n::String = 'Edit' AND o::String != '', countSubstrings(o::String, '\n') + 1, 0), data.message.content[].type, data.message.content[].name, data.message.content[].input.old_string)),

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


-- ---------------------------------------------------------------------------
-- Main-page accelerator: an INCREMENTAL materialized view that maintains
-- per-session aggregates as rows are inserted into `raw`, so the session list
-- reads ~one row per session instead of scanning the whole table.
--
-- sessions_state  : AggregatingMergeTree of partial aggregate states.
-- sessions_mv     : MV that writes those states on every INSERT into raw.
-- sessions        : view that finalizes the states (what the UI queries).
--
-- After creating these, backfill existing data once:
--   INSERT INTO claude_code.sessions_state <the sessions_mv SELECT body>;
-- (i.e. the same SELECT as the MV; the MV itself only sees future inserts.)
--
-- IMPORTANT: an incremental MV aggregates every INSERTED row -- it does NOT see
-- raw's ReplacingMergeTree de-duplication. So each raw row must be inserted
-- exactly once, otherwise a re-inserted row is counted again here (raw stays
-- correct, sessions_state inflates). Feed it with row-level-incremental uploads
-- (insert only new rows), not whole-file re-uploads. To reset after drift:
--   TRUNCATE TABLE claude_code.sessions_state;  -- then re-run the backfill INSERT
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claude_code.sessions_state
(
    session_id String,
    project LowCardinality(String),
    started               AggregateFunction(min, Nullable(DateTime64(3))),
    ended                 AggregateFunction(max, Nullable(DateTime64(3))),
    user_msgs             AggregateFunction(sum, UInt64),
    assistant_msgs        AggregateFunction(sum, UInt64),
    user_all              AggregateFunction(sum, UInt64),
    input_tokens          AggregateFunction(sum, UInt64),
    output_tokens         AggregateFunction(sum, UInt64),
    cache_read_tokens     AggregateFunction(sum, UInt64),
    cache_creation_tokens AggregateFunction(sum, UInt64),
    api_duration_ms       AggregateFunction(sum, UInt64),
    summary               AggregateFunction(anyIf, String, UInt8),
    model                 AggregateFunction(anyIf, String, UInt8),
    git_branch            AggregateFunction(anyIf, String, UInt8),
    fq_full               AggregateFunction(argMinIf, String, Nullable(DateTime64(3)), UInt8),
    plan_count            AggregateFunction(sum, UInt64),
    compaction_count      AggregateFunction(sum, UInt64),
    approved_count        AggregateFunction(sum, UInt64),
    rejected_count        AggregateFunction(sum, UInt64),
    lines_added           AggregateFunction(sum, UInt64),
    lines_removed         AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (session_id, project);

CREATE MATERIALIZED VIEW IF NOT EXISTS claude_code.sessions_mv TO claude_code.sessions_state AS
SELECT
    data.sessionId::String AS session_id,
    project,
    minState(ts) AS started,
    maxState(ts) AS ended,
    sumState(toUInt64(
        data.type::String = 'user'
        AND content_kind = 'String'
        AND data.isMeta::Bool = false
        AND NOT user_text LIKE '<command-name>%'
        AND NOT user_text LIKE 'Implement the following plan:%'
        AND NOT user_text LIKE '[Request interrupted by user%'
        AND NOT user_text LIKE '%This session is being continued from a previous conversation%'
        AND NOT user_text LIKE '%<task-notification>%'
    )) AS user_msgs,
    sumState(toUInt64(data.type::String = 'assistant')) AS assistant_msgs,
    sumState(toUInt64(data.type::String = 'user')) AS user_all,
    sumState(data.message.usage.input_tokens::UInt64) AS input_tokens,
    sumState(data.message.usage.output_tokens::UInt64) AS output_tokens,
    sumState(data.message.usage.cache_read_input_tokens::UInt64) AS cache_read_tokens,
    sumState(data.message.usage.cache_creation_input_tokens::UInt64) AS cache_creation_tokens,
    sumState(if(data.type::String = 'system' AND data.subtype::String = 'turn_duration', toUInt64(data.durationMs::UInt32), 0)) AS api_duration_ms,
    anyIfState(data.summary::String, data.type::String = 'summary' AND data.summary::String != '') AS summary,
    anyIfState(data.message.model::String, data.type::String = 'assistant' AND data.message.model::String NOT IN ('', '<synthetic>')) AS model,
    anyIfState(data.gitBranch::String, data.gitBranch::String != '') AS git_branch,
    argMinIfState(user_text, ts,
        data.type::String = 'user' AND content_kind = 'String' AND data.isMeta::Bool = false
        AND NOT user_text LIKE '<command-name>%'
        AND NOT user_text LIKE '[Request interrupted by user%'
        AND NOT user_text LIKE '%This session is being continued from a previous conversation%'
        AND NOT user_text LIKE '%<task-notification>%'
    ) AS fq_full,
    sumState(toUInt64(is_plan)) AS plan_count,
    sumState(toUInt64(data.type::String = 'system' AND data.subtype::String IN ('compact_boundary', 'microcompact_boundary'))) AS compaction_count,
    sumState(toUInt64(is_approved)) AS approved_count,
    sumState(toUInt64(is_rejected)) AS rejected_count,
    sumState(toUInt64(lines_added)) AS lines_added,
    sumState(toUInt64(lines_removed)) AS lines_removed
FROM claude_code.raw
WHERE path NOT LIKE '%history.jsonl'
GROUP BY session_id, project;

CREATE VIEW IF NOT EXISTS claude_code.sessions AS
SELECT
    session_id,
    project,
    minMerge(started) AS started,
    maxMerge(ended) AS ended,
    dateDiff('second', started, ended) AS total_duration_sec,
    sumMerge(user_msgs) AS user_msgs,
    sumMerge(assistant_msgs) AS assistant_msgs,
    sumMerge(user_all) + assistant_msgs AS all_msgs,
    sumMerge(input_tokens) AS input_tokens,
    sumMerge(output_tokens) AS output_tokens,
    sumMerge(cache_read_tokens) AS cache_read_tokens,
    sumMerge(cache_creation_tokens) AS cache_creation_tokens,
    sumMerge(api_duration_ms) AS api_duration_ms,
    anyIfMerge(summary) AS summary,
    anyIfMerge(model) AS model,
    anyIfMerge(git_branch) AS git_branch,
    argMinIfMerge(fq_full) AS fq_full,
    sumMerge(plan_count) AS plan_count,
    sumMerge(compaction_count) AS compaction_count,
    sumMerge(approved_count) AS approved_count,
    sumMerge(rejected_count) AS rejected_count,
    sumMerge(lines_added) AS lines_added,
    sumMerge(lines_removed) AS lines_removed
FROM claude_code.sessions_state
GROUP BY session_id, project
HAVING user_msgs > 0;
