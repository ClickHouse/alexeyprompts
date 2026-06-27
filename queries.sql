-- Analytical queries for Claude Code session data
-- All operate on claude_code.raw (see schema.sql).
--
-- Plain scalar fields are read as data.field::Type -- they are JSON type hints,
-- so this reads native typed subcolumns, not the dynamic JSON. Computed values
-- (project, ts, content_kind, is_root_user/root_text, is_plan/is_approved/
-- is_rejected, search_text) come from materialized columns so queries avoid
-- scanning the multi-GB data.message.content.
--
-- Content blocks are still Array(JSON): unnest with ARRAY JOIN over
-- data.message.content::Array(JSON) (guarded by content_kind LIKE 'Array%').

-- 1. Overview
SELECT
    count() AS total_rows,
    countIf(data.type::String = 'user') AS user_messages,
    countIf(data.type::String = 'assistant') AS assistant_messages,
    countIf(data.type::String = 'progress') AS progress_updates,
    uniqExact(data.sessionId::String) AS sessions,
    uniqExact(project) AS projects
FROM claude_code.raw;

-- 2. Daily activity
SELECT
    toDate(ts) AS day,
    countIf(data.type::String = 'user') AS user_msgs,
    countIf(data.type::String = 'assistant') AS assistant_msgs,
    uniqExact(data.sessionId::String) AS sessions,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens
FROM claude_code.raw
WHERE data.type::String IN ('user', 'assistant')
GROUP BY day
ORDER BY day;

-- 3. Project activity
SELECT
    project,
    countIf(data.type::String = 'user') AS user_msgs,
    countIf(data.type::String = 'assistant') AS assistant_msgs,
    uniqExact(data.sessionId::String) AS sessions,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens
FROM claude_code.raw
WHERE data.type::String IN ('user', 'assistant')
GROUP BY project
ORDER BY user_msgs DESC;

-- 4. Model usage
SELECT
    data.message.model::String AS model,
    count() AS messages,
    sum(data.message.usage.input_tokens::UInt64) AS input_tokens,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens,
    sum(data.message.usage.cache_read_input_tokens::UInt64) AS cache_read,
    sum(data.message.usage.cache_creation_input_tokens::UInt64) AS cache_creation,
    uniqExact(data.sessionId::String) AS sessions
FROM claude_code.raw
WHERE data.type::String = 'assistant'
    AND data.message.model::String NOT IN ('', '<synthetic>')
GROUP BY model
ORDER BY messages DESC;

-- 5. Tool usage ranking
SELECT
    block.name::String AS tool_name,
    count() AS calls,
    uniqExact(data.sessionId::String) AS sessions
FROM claude_code.raw
ARRAY JOIN data.message.content::Array(JSON) AS block
WHERE data.type::String = 'assistant'
    AND content_kind LIKE 'Array%'
    AND block.type::String = 'tool_use'
GROUP BY tool_name
ORDER BY calls DESC;

-- 6. Hourly distribution
SELECT
    toHour(ts) AS hour,
    countIf(data.type::String = 'user') AS user_msgs,
    countIf(data.type::String = 'assistant') AS assistant_msgs
FROM claude_code.raw
WHERE data.type::String IN ('user', 'assistant')
GROUP BY hour
ORDER BY hour;

-- 7. Token usage per assistant turn (averages by model)
SELECT
    data.message.model::String AS model,
    count() AS turns,
    avg(data.message.usage.output_tokens::UInt64) AS avg_output,
    avg(data.message.usage.input_tokens::UInt64) AS avg_input,
    max(data.message.usage.output_tokens::UInt64) AS max_output,
    avg(data.message.usage.cache_read_input_tokens::UInt64) AS avg_cache_read
FROM claude_code.raw
WHERE data.type::String = 'assistant'
    AND data.message.model::String NOT IN ('', '<synthetic>')
GROUP BY model;

-- 8. Longest sessions
SELECT
    data.sessionId::String AS session_id,
    project,
    min(ts) AS started,
    max(ts) AS ended,
    dateDiff('second', started, ended) AS duration_sec,
    countIf(data.type::String = 'user') AS user_msgs,
    countIf(data.type::String = 'assistant') AS assistant_msgs,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens
FROM claude_code.raw
WHERE data.type::String IN ('user', 'assistant')
GROUP BY session_id, project
ORDER BY duration_sec DESC
LIMIT 20;

-- 9. Most active sessions by output tokens
SELECT
    data.sessionId::String AS session_id,
    project,
    countIf(data.type::String = 'user') AS user_msgs,
    countIf(data.type::String = 'assistant') AS assistant_msgs,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens
FROM claude_code.raw
WHERE data.type::String IN ('user', 'assistant')
GROUP BY session_id, project
ORDER BY output_tokens DESC
LIMIT 20;

-- 10. First question of each session (most recent)
SELECT
    data.sessionId::String AS session_id,
    project,
    ts,
    left(root_text, 150) AS question
FROM claude_code.raw
WHERE is_root_user
    AND root_text != ''
ORDER BY ts DESC
LIMIT 30;

-- 11. Turn durations — slowest turns
SELECT
    project,
    data.sessionId::String AS session_id,
    ts,
    data.durationMs::UInt32 / 1000.0 AS duration_sec
FROM claude_code.raw
WHERE data.type::String = 'system' AND data.subtype::String = 'turn_duration'
ORDER BY data.durationMs::UInt32 DESC
LIMIT 20;

-- 12. Average turn duration by project
SELECT
    project,
    avg(data.durationMs::UInt32) / 1000 AS avg_sec,
    max(data.durationMs::UInt32) / 1000 AS max_sec,
    count() AS turns
FROM claude_code.raw
WHERE data.type::String = 'system' AND data.subtype::String = 'turn_duration'
GROUP BY project
ORDER BY avg_sec DESC;

-- 13. Weekly token consumption
SELECT
    toMonday(ts) AS week,
    sum(data.message.usage.input_tokens::UInt64) AS input_tokens,
    sum(data.message.usage.output_tokens::UInt64) AS output_tokens,
    sum(data.message.usage.cache_read_input_tokens::UInt64) AS cache_read,
    sum(data.message.usage.cache_creation_input_tokens::UInt64) AS cache_creation
FROM claude_code.raw
WHERE data.type::String = 'assistant'
GROUP BY week
ORDER BY week;

-- 14. PR links
SELECT
    data.prRepository::String AS repo,
    data.prNumber::UInt32 AS pr,
    data.prUrl::String AS url,
    ts
FROM claude_code.raw
WHERE data.type::String = 'pr-link'
ORDER BY ts DESC;

-- 15. Session summaries
SELECT
    data.summary::String AS summary,
    project
FROM claude_code.raw
WHERE data.type::String = 'summary' AND data.summary::String != ''
ORDER BY path;

-- 16. Git branches worked on
SELECT
    data.gitBranch::String AS branch,
    project,
    countIf(data.type::String = 'user') AS user_msgs,
    uniqExact(data.sessionId::String) AS sessions
FROM claude_code.raw
WHERE data.gitBranch::String != '' AND data.type::String IN ('user', 'assistant')
GROUP BY branch, project
ORDER BY user_msgs DESC
LIMIT 30;

-- 17. Claude Code versions over time
SELECT
    data.version::String AS version,
    min(ts) AS first_seen,
    max(ts) AS last_seen,
    uniqExact(data.sessionId::String) AS sessions
FROM claude_code.raw
WHERE data.version::String != '' AND data.type::String = 'user'
GROUP BY version
ORDER BY first_seen;

-- 18. Cache hit ratio by day
SELECT
    toDate(ts) AS day,
    sum(data.message.usage.cache_read_input_tokens::UInt64) AS cache_read,
    sum(data.message.usage.cache_creation_input_tokens::UInt64) AS cache_created,
    if(cache_read + cache_created > 0,
       round(cache_read * 100.0 / (cache_read + cache_created), 1), 0) AS cache_hit_pct
FROM claude_code.raw
WHERE data.type::String = 'assistant'
GROUP BY day
ORDER BY day;

-- 19. Bash commands used
SELECT
    block.input.command::String AS cmd,
    block.input.description::String AS descr,
    count() AS times
FROM claude_code.raw
ARRAY JOIN data.message.content::Array(JSON) AS block
WHERE data.type::String = 'assistant'
    AND content_kind LIKE 'Array%'
    AND block.type::String = 'tool_use'
    AND block.name::String = 'Bash'
GROUP BY cmd, descr
ORDER BY times DESC
LIMIT 30;

-- 20. Files most frequently read/edited
SELECT
    block.input.file_path::String AS file,
    block.name::String AS tool,
    count() AS times
FROM claude_code.raw
ARRAY JOIN data.message.content::Array(JSON) AS block
WHERE data.type::String = 'assistant'
    AND content_kind LIKE 'Array%'
    AND block.type::String = 'tool_use'
    AND block.name::String IN ('Read', 'Edit', 'Write')
GROUP BY file, tool
ORDER BY times DESC
LIMIT 30;

-- 21. Grep patterns — what are you searching for?
SELECT
    block.input.pattern::String AS pattern,
    count() AS times,
    uniqExact(data.sessionId::String) AS sessions
FROM claude_code.raw
ARRAY JOIN data.message.content::Array(JSON) AS block
WHERE data.type::String = 'assistant'
    AND content_kind LIKE 'Array%'
    AND block.type::String = 'tool_use'
    AND block.name::String = 'Grep'
GROUP BY pattern
ORDER BY times DESC
LIMIT 30;

-- 22. Task/subagent usage
SELECT
    block.input.subagent_type::String AS subagent,
    left(block.input.prompt::String, 100) AS prompt_preview,
    count() AS times
FROM claude_code.raw
ARRAY JOIN data.message.content::Array(JSON) AS block
WHERE data.type::String = 'assistant'
    AND content_kind LIKE 'Array%'
    AND block.type::String = 'tool_use'
    AND block.name::String = 'Task'
GROUP BY subagent, prompt_preview
ORDER BY times DESC
LIMIT 30;

-- 23. History entries (prompts pasted to sessions)
-- history.jsonl rows store a numeric (ms) timestamp and their own project field.
SELECT
    toDateTime(data.timestamp::UInt64 / 1000) AS ts,
    data.project::String AS project,
    left(data.display::String, 200) AS prompt
FROM claude_code.raw
WHERE path LIKE '%history.jsonl'
ORDER BY ts DESC
LIMIT 20;

-- 24. Full-text search across sessions (uses the ngram text index on search_text)
-- search_text is lowercased; lowercase the term so the index can prune.
SELECT
    data.sessionId::String AS session_id,
    any(project) AS project,
    count() AS hits
FROM claude_code.raw
WHERE search_text LIKE '%clickhouse%'
GROUP BY session_id
ORDER BY hits DESC
LIMIT 30;
