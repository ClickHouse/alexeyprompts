#!/bin/bash
# Upload only the data ClickHouse doesn't have yet: brand-new session files and
# new entries appended to existing sessions. Safe to run repeatedly (e.g. from
# cron) and safe to run from several machines that all feed the same ClickHouse,
# at different times.
#
# How it decides what to upload (the union of two sets):
#   1. NEW files  -- any local .jsonl whose path is not yet present in the `raw`
#      table is uploaded. This is what makes multi-machine / "copy the sessions
#      over and upload later" work: it does NOT depend on file mtimes, which are
#      meaningless once files are synced between machines (rsync/scp/cp preserve
#      the original, older mtime, so a plain `find -newer` would never see them).
#   2. GROWN files -- files modified since the last successful run *on this
#      machine* (tracked by a marker file) are re-uploaded so appended entries
#      get in. The `raw` table is a ReplacingMergeTree ordered by
#      (sessionId, timestamp, uuid), so rows already present are deduplicated --
#      nothing is duplicated.
#
# On the very first run (no marker, empty/missing table) that union is simply
# everything. Set FORCE=1 to ignore both the marker and the table and re-upload
# every local file.
#
# Note: a row-level timestamp filter is intentionally NOT used, because some
# entries (mode, permission-mode, file-history-snapshot, ai-title, last-prompt)
# have no timestamp and would be lost.
#
# Codex sessions (~/.codex/sessions/**/rollout-*.jsonl) are uploaded too. Their
# format is different, so each rollout is converted on the fly into Claude
# Code-shaped rows (see CODEX_SQL below) and lands in the same `raw` table,
# where the viewer shows it like any other session. The same two sets apply;
# a rollout counts as "already in ClickHouse" by its file name, which embeds
# the thread id.
#
# Usage:
#   CH_HOST=... CH_PASSWORD=... ./upload_incremental.sh
#   FORCE=1 CH_HOST=... CH_PASSWORD=... ./upload_incremental.sh   # re-upload all

set -euo pipefail

CH_HOST="${CH_HOST:-localhost}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"
MARKER="${MARKER:-$HOME/.claude/.ch_last_upload}"
PROJECTS="${PROJECTS:-$HOME/.claude/projects}"
CODEX_SESSIONS="${CODEX_SESSIONS:-$HOME/.codex/sessions}"
CODEX_INDEX="${CODEX_INDEX:-$(dirname "$CODEX_SESSIONS")/session_index.jsonl}"
FORCE="${FORCE:-}"

# Use a secure (TLS) connection for anything that isn't local. Cloud endpoints
# require it. Override explicitly with CH_SECURE=1 / CH_SECURE=0.
if [ -n "${CH_SECURE:-}" ]; then
    [ "$CH_SECURE" = 1 ] && SECURE=(--secure) || SECURE=()
elif [ "$CH_HOST" = localhost ] || [ "$CH_HOST" = 127.0.0.1 ]; then
    SECURE=()
else
    SECURE=(--secure)
fi

client() {
    clickhouse-client --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" \
        "${SECURE[@]}" "$@"
}

# Fail fast on a real connection problem (so we never confuse "can't connect"
# with "nothing new").
if ! client -q "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: cannot connect to ClickHouse at '$CH_HOST'." >&2
    echo "Check CH_HOST / CH_USER / CH_PASSWORD (and CH_SECURE for TLS)." >&2
    exit 1
fi

# Capture "now" up front so files changed *during* this run are picked up next
# time by the mtime fast-path.
NEW_MARKER=$(mktemp)
trap 'rm -f "$NEW_MARKER"' EXIT

# Local session files: Claude Code transcripts, plus Codex rollouts if present.
list_claude() { find "$PROJECTS" -name '*.jsonl' "$@"; }
list_codex() {
    [ -d "$CODEX_SESSIONS" ] || return 0
    find "$CODEX_SESSIONS" -name 'rollout-*.jsonl' "$@"
}

# Build the set of files to upload.
declare -A PICK=() CODEX_PICK=()

if [ -n "$FORCE" ]; then
    # Everything, regardless of marker or what's already loaded.
    while IFS= read -r f; do PICK["$f"]=1; done < <(list_claude)
    while IFS= read -r f; do CODEX_PICK["$f"]=1; done < <(list_codex)
else
    # 1. Locally-changed files (appended entries) -- cheap mtime fast-path.
    if [ -f "$MARKER" ]; then
        while IFS= read -r f; do PICK["$f"]=1; done < <(list_claude -newer "$MARKER")
        while IFS= read -r f; do CODEX_PICK["$f"]=1; done < <(list_codex -newer "$MARKER")
    fi

    # 2. Files ClickHouse doesn't have yet, by path. This is mtime-independent,
    #    so it catches new sessions copied from other machines and anything an
    #    earlier run missed. (Missing table -> empty set -> upload everything.)
    #    Codex rollouts are stored under a rewritten path (see CODEX_SQL), so
    #    they are matched by file name instead; it embeds the unique thread id.
    declare -A IN_CH=() IN_CH_CODEX=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        IN_CH["$p"]=1
        case "$p" in */rollout-*.jsonl) IN_CH_CODEX["${p##*/}"]=1 ;; esac
    done < <(client -q "SELECT DISTINCT path FROM claude_code.raw FORMAT TSVRaw" 2>/dev/null || true)

    while IFS= read -r f; do
        [ -n "${IN_CH["$f"]:-}" ] || PICK["$f"]=1
    done < <(list_claude)
    while IFS= read -r f; do
        [ -n "${IN_CH_CODEX["${f##*/}"]:-}" ] || CODEX_PICK["$f"]=1
    done < <(list_codex)
fi

FILES=("${!PICK[@]}")
CODEX_FILES=("${!CODEX_PICK[@]}")

if [ "${#FILES[@]}" -eq 0 ] && [ "${#CODEX_FILES[@]}" -eq 0 ]; then
    echo "Up to date -- ClickHouse already has every local session. Nothing to upload."
    mv -f "$NEW_MARKER" "$MARKER"
    trap - EXIT
    exit 0
fi
echo "Uploading ${#FILES[@]} Claude Code and ${#CODEX_FILES[@]} Codex new/changed session file(s)..."

# Read a batch of files and insert; ReplacingMergeTree deduplicates any overlap.
# Files are read line by line (JSONL) rather than with JSONAsString, so a corrupt
# line (e.g. a truncated write glued to the next entry) is simply skipped by
# isValidJSON instead of desyncing the JSON parser and failing the whole batch.
upload_batch() {
    local arr="$1"
    [ -z "$arr" ] && return 0
    arr="[${arr%,}]"
    clickhouse-local -q "
        SELECT _path AS path, line AS data
        FROM file({files:Array(String)}, 'LineAsString')
        WHERE isValidJSON(line)
        FORMAT Native
    " --param_files="$arr" \
    | client -q "INSERT INTO claude_code.raw FORMAT Native"
}

# Convert Codex rollouts into the Claude Code row shape the schema and the viewer
# expect, one output row per transcript entry:
#   - user prompts            -> type=user, string content (injected AGENTS.md /
#                                environment context is dropped; other <tag>
#                                messages, e.g. subagent notifications, isMeta)
#   - assistant text          -> type=assistant, [{type:text}]
#   - reasoning summaries     -> type=assistant, [{type:thinking}]
#   - tool calls / outputs    -> assistant tool_use / user tool_result, paired
#                                by call_id
#   - token_count events      -> type=system rows carrying message.usage. Codex
#                                repeats an event when only rate limits change,
#                                so an event counts only if the running total
#                                moved. Codex input_tokens includes cached
#                                tokens; Claude's excludes them, so subtract.
#   - task_complete           -> system/turn_duration (the "API time")
#   - compaction              -> system/compact_boundary
#   - turn_aborted            -> "[Request interrupted by user]"
#   - thread title (session_index.jsonl) -> a summary row
#   - session_meta            -> system/session_start, so even a rollout with no
#                                transcript entries is recorded as uploaded
# A subagent thread's rows go under the parent's sessionId with isSidechain,
# like Claude Code subagents. uuid is <thread id>:<line number> -- stable as the
# file grows, so re-uploads deduplicate -- and parentUuid chains the rows.
# `path` is rewritten to <codex dir>/projects/<cwd with non-alphanumerics as
# '-'>/<file>, the Claude Code layout, so the `project` column works as is.
CODEX_SQL=$(cat <<'SQL'
WITH
src AS (
    SELECT _path AS fpath, _file AS fname, _row_number AS rn, line,
        JSONExtractString(line, 'type') AS t,
        JSONExtractString(line, 'payload', 'type') AS pt,
        JSONExtractString(line, 'timestamp') AS ts
    FROM file({files:Array(String)}, 'LineAsString')
    WHERE isValidJSON(line)
),
meta AS (
    SELECT fpath,
        argMin(JSONExtractString(line, 'payload', 'id'), rn) AS own_id,
        argMin(JSONExtractString(line, 'payload', 'source', 'subagent', 'thread_spawn', 'parent_thread_id'), rn) AS parent_id,
        argMin(JSONExtractString(line, 'payload', 'cwd'), rn) AS cwd,
        argMin(JSONExtractString(line, 'payload', 'git', 'branch'), rn) AS branch,
        argMin(JSONExtractString(line, 'payload', 'cli_version'), rn) AS version
    FROM src WHERE t = 'session_meta' GROUP BY fpath
),
titles AS (
    SELECT JSONExtractString(line, 'id') AS own_id,
        argMax(JSONExtractString(line, 'thread_name'), JSONExtractString(line, 'updated_at')) AS title
    FROM file({index:String}, 'LineAsString')
    WHERE isValidJSON(line)
    GROUP BY own_id
),
ctx AS (
    SELECT *,
        if(parent_id != '', parent_id, own_id) AS sid,
        last_value(nullIf(multiIf(
            t = 'turn_context', JSONExtractString(line, 'payload', 'model'),
            t = 'world_state', JSONExtractString(line, 'payload', 'state', 'collaboration_mode', 'model'),
            ''), '')) OVER w AS model,
        coalesce(last_value(nullIf(if(t = 'turn_context', JSONExtractString(line, 'payload', 'cwd'), ''), '')) OVER w, cwd) AS row_cwd,
        if(pt = 'token_count', JSONExtractRaw(line, 'payload', 'info', 'total_token_usage'), '') AS tot,
        lagInFrame(tot) OVER (PARTITION BY fpath, pt = 'token_count' ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_tot,
        min(if(pt = 'task_started', parseDateTime64BestEffortOrNull(ts, 3), NULL))
            OVER (PARTITION BY fpath, JSONExtractString(line, 'payload', 'turn_id')) AS turn_started
    FROM src INNER JOIN meta USING fpath
    WINDOW w AS (PARTITION BY fpath ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),
conv AS (
    SELECT *,
        arrayStringConcat(arrayMap(x -> JSONExtractString(x, 'text'),
            arrayFilter(x -> JSONExtractString(x, 'type') IN ('input_text', 'output_text'),
                JSONExtractArrayRaw(line, 'payload', 'content'))), '\n') AS msg_text,
        arrayStringConcat(arrayMap(x -> JSONExtractString(x, 'text'),
            JSONExtractArrayRaw(line, 'payload', if(JSONLength(line, 'payload', 'summary') > 0, 'summary', 'content'))), '\n\n') AS reasoning_text,
        JSONExtractString(line, 'payload', 'call_id') AS call_id,
        JSONExtractString(line, 'payload', 'name') AS tool_name,
        JSONExtractString(line, 'payload', 'arguments') AS args,
        if(JSONType(line, 'payload', 'output') = 'String',
            JSONExtractString(line, 'payload', 'output'),
            JSONExtractRaw(line, 'payload', 'output')) AS out_raw,
        if(pt = 'custom_tool_call_output' AND JSONHas(out_raw, 'output'), JSONExtractString(out_raw, 'output'), out_raw) AS tool_output,
        JSONExtractUInt(line, 'payload', 'info', 'last_token_usage', 'input_tokens') AS u_in,
        JSONExtractUInt(line, 'payload', 'info', 'last_token_usage', 'cached_input_tokens') AS u_cached,
        JSONExtractUInt(line, 'payload', 'info', 'last_token_usage', 'cache_write_input_tokens') AS u_cwrite,
        JSONExtractUInt(line, 'payload', 'info', 'last_token_usage', 'output_tokens') AS u_out,
        if(JSONHas(line, 'payload', 'duration_ms'),
            JSONExtractUInt(line, 'payload', 'duration_ms'),
            toUInt64(greatest(0, dateDiff('millisecond', turn_started, parseDateTime64BestEffortOrNull(ts, 3))))) AS turn_ms,
        multiIf(
            t = 'response_item' AND pt = 'message' AND JSONExtractString(line, 'payload', 'role') = 'user'
                AND msg_text != '' AND NOT match(msg_text, '^\\s*(# AGENTS\\.md instructions|<environment_context>|<turn_aborted>|<user_instructions>|<permissions)'), 'user_text',
            t = 'response_item' AND pt = 'message' AND JSONExtractString(line, 'payload', 'role') = 'assistant' AND msg_text != '', 'assistant_text',
            t = 'response_item' AND pt = 'reasoning' AND reasoning_text != '', 'thinking',
            t = 'response_item' AND pt IN ('function_call', 'custom_tool_call', 'web_search_call'), 'tool_use',
            t = 'response_item' AND pt IN ('function_call_output', 'custom_tool_call_output'), 'tool_result',
            t = 'event_msg' AND pt = 'token_count' AND tot NOT IN ('', 'null') AND tot != prev_tot, 'usage',
            t = 'event_msg' AND pt = 'task_complete' AND turn_ms > 0, 'turn_duration',
            t = 'event_msg' AND pt = 'turn_aborted', 'interrupt',
            t = 'compacted', 'compact',
            t = 'session_meta', 'session_start',
            '') AS kind
    FROM ctx
),
rows AS (
    SELECT *,
        concat(own_id, ':', toString(rn)) AS uuid,
        lagInFrame(uuid, 1, '') OVER (PARTITION BY fpath ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS parent_uuid,
        multiIf(kind IN ('user_text', 'tool_result', 'interrupt'), 'user',
                kind IN ('assistant_text', 'thinking', 'tool_use'), 'assistant',
                'system') AS type,
        multiIf(
            kind = 'user_text', toJSONString(msg_text),
            kind = 'interrupt', toJSONString('[Request interrupted by user]'),
            kind = 'assistant_text', concat('[{"type":"text","text":', toJSONString(msg_text), '}]'),
            kind = 'thinking', concat('[{"type":"thinking","thinking":', toJSONString(reasoning_text), '}]'),
            kind = 'tool_use', concat('[{"type":"tool_use","id":', toJSONString(call_id),
                ',"name":', toJSONString(if(pt = 'web_search_call', 'web_search', tool_name)),
                ',"input":', multiIf(
                    pt = 'web_search_call', if(JSONType(line, 'payload', 'action') = 'Object', JSONExtractRaw(line, 'payload', 'action'), '{}'),
                    pt = 'custom_tool_call', concat('{"input":', toJSONString(JSONExtractString(line, 'payload', 'input')), '}'),
                    isValidJSON(args) AND JSONType(args) = 'Object', args,
                    concat('{"arguments":', toJSONString(args), '}')),
                '}]'),
            kind = 'tool_result', concat('[{"type":"tool_result","tool_use_id":', toJSONString(call_id),
                ',"content":', toJSONString(tool_output), ',"is_error":false}]'),
            '') AS content
    FROM conv
    WHERE kind != ''
)
SELECT
    concat({root:String}, '/projects/', replaceRegexpAll(cwd, '[^A-Za-z0-9]', '-'), '/', fname) AS path,
    concat('{',
        '"sessionId":', toJSONString(sid),
        ',"uuid":', toJSONString(uuid),
        ',"parentUuid":', toJSONString(parent_uuid),
        ',"timestamp":', toJSONString(ts),
        ',"type":', toJSONString(type),
        multiIf(kind = 'usage', ',"subtype":"token_count"',
                kind = 'turn_duration', concat(',"subtype":"turn_duration","durationMs":', toString(turn_ms)),
                kind = 'compact', ',"subtype":"compact_boundary"',
                kind = 'session_start', ',"subtype":"session_start"',
                ''),
        ',"cwd":', toJSONString(row_cwd),
        ',"gitBranch":', toJSONString(branch),
        ',"version":', toJSONString(version),
        ',"isSidechain":', if(parent_id != '', 'true', 'false'),
        ',"isMeta":', if(kind = 'user_text' AND match(msg_text, '^\\s*<[A-Za-z_]+>'), 'true', 'false'),
        multiIf(
            content != '', concat(',"message":{"role":', toJSONString(type), ',"model":', toJSONString(coalesce(model, '')), ',"content":', content, '}'),
            kind = 'usage', concat(',"message":{"model":', toJSONString(coalesce(model, '')), ',"usage":{',
                '"input_tokens":', toString(u_in - least(u_in, u_cached + u_cwrite)),
                ',"cache_read_input_tokens":', toString(u_cached),
                ',"cache_creation_input_tokens":', toString(u_cwrite),
                ',"output_tokens":', toString(u_out), '}}'),
            ''),
        '}') AS data
FROM rows
UNION ALL
-- A fixed uuid and no timestamp, so a renamed thread replaces the old title.
SELECT
    concat({root:String}, '/projects/', replaceRegexpAll(cwd, '[^A-Za-z0-9]', '-'), '/', fname) AS path,
    concat('{"sessionId":', toJSONString(own_id), ',"uuid":', toJSONString(concat(own_id, ':summary')),
        ',"type":"summary","summary":', toJSONString(title), '}') AS data
FROM (SELECT fpath, any(fname) AS fname FROM src GROUP BY fpath) AS f
INNER JOIN meta USING fpath
INNER JOIN titles USING own_id
WHERE parent_id = '' AND title != ''
FORMAT Native
SQL
)

upload_codex_batch() {
    local arr="$1"
    [ -z "$arr" ] && return 0
    arr="[${arr%,}]"
    local index="$CODEX_INDEX"
    [ -f "$index" ] || index=/dev/null
    clickhouse-local -q "$CODEX_SQL" --param_files="$arr" --param_index="$index" \
        --param_root="$(dirname "$CODEX_SESSIONS")" \
    | client -q "INSERT INTO claude_code.raw FORMAT Native"
}

# Pass the paths in byte-bounded batches. The whole list cannot go in one
# argument: Linux caps a single argv entry at 128 KiB (MAX_ARG_STRLEN),
# regardless of the larger ARG_MAX total -- exceeding it makes clickhouse-local
# fail to start, which surfaces downstream as "No data to insert".
# A Codex batch holds whole files, so a subagent's rows and its thread's title
# are always converted together with the file they belong to.
MAX_ARG="${MAX_ARG:-98304}"   # 96 KiB, safely under the 128 KiB single-arg limit
done_count=0
upload_files() {
    local fn="$1"; shift
    local buf="" item f
    for f in "$@"; do
        item="'${f//\'/\\\'}',"
        if [ "$(( ${#buf} + ${#item} ))" -gt "$MAX_ARG" ]; then
            "$fn" "$buf"
            buf=""
        fi
        buf+="$item"
        done_count=$((done_count + 1))
    done
    "$fn" "$buf"
}
upload_files upload_batch "${FILES[@]}"
upload_files upload_codex_batch "${CODEX_FILES[@]}"

# Commit the marker only after a successful upload.
mv -f "$NEW_MARKER" "$MARKER"
trap - EXIT
echo "Done ($done_count file(s)). Marker updated: $MARKER"
