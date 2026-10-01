#!/bin/bash
# Claude Code hook (Stop, SessionEnd): upload whatever was appended to session
# transcripts since the last upload into claude_code.raw.
#
# The hook itself returns immediately: it re-launches this script detached, so
# neither a turn nor exiting Claude Code waits for the network. The worker:
#   - takes a lock, so overlapping hooks queue up instead of racing;
#   - scans every ~/.claude/projects/**/*.jsonl (main sessions and subagents of
#     all sessions, so anything missed earlier -- a crash, a session from before
#     the plugin was installed, files synced from another machine -- gets in);
#   - for each file whose size differs from the one recorded in its state file,
#     uploads only the lines past the recorded line count. A trailing line that
#     is still being written isn't counted, so it is sent again next time; the
#     table is a ReplacingMergeTree, so any overlap is deduplicated.
#
# The first run therefore uploads the whole history.
#
# Settings come from the plugin options (CLAUDE_PLUGIN_OPTION_*), falling back
# to the same CH_HOST / CH_USER / CH_PASSWORD / CH_SECURE / PROJECTS variables
# as upload_incremental.sh. The state file and log live in CLAUDE_PLUGIN_DATA.

set -euo pipefail

DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/clickhouse-session-upload}"
mkdir -p "$DATA"
LOG="$DATA/upload.log"

if [ -z "${UPLOAD_SESSIONS_WORKER:-}" ]; then
    # Keep the log bounded.
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        tail -c 262144 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    fi
    UPLOAD_SESSIONS_WORKER=1 setsid nohup "$0" </dev/null >>"$LOG" 2>&1 &
    exit 0
fi

# Hooks run in the session's project directory; clickhouse-local would pick up a
# config.xml from there (e.g. in a ClickHouse checkout).
cd "$DATA"

CH_HOST="${CLAUDE_PLUGIN_OPTION_CH_HOST:-${CH_HOST:-}}"
CH_USER="${CLAUDE_PLUGIN_OPTION_CH_USER:-${CH_USER:-default}}"
CH_PASSWORD="${CLAUDE_PLUGIN_OPTION_CH_PASSWORD:-${CH_PASSWORD:-}}"
PROJECTS="${PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
STATE="$DATA/uploaded.tsv"

log() { echo "$(date '+%F %T') [$$] $*"; }

if [ -z "$CH_HOST" ]; then
    log "ERROR: ClickHouse host is not configured (plugin option ch_host or CH_HOST)."
    exit 1
fi

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

exec 9>"$DATA/upload.lock"
if ! flock -w 1800 9; then
    log "Another upload has held the lock for too long, giving up."
    exit 1
fi

# State: path <TAB> size <TAB> number of complete lines already uploaded.
declare -A SIZE=() LINES=()
if [ -f "$STATE" ]; then
    while IFS=$'\t' read -r p s n; do
        SIZE["$p"]=$s
        LINES["$p"]=$n
    done < "$STATE"
fi

save_state() {
    local p
    for p in "${!SIZE[@]}"; do
        printf '%s\t%s\t%s\n' "$p" "${SIZE[$p]}" "${LINES[$p]}"
    done > "$STATE.tmp"
    mv -f "$STATE.tmp" "$STATE"
}

# Changed files, with the offset to start from and the new size / line count.
# The size is taken before counting lines, so if the file grows in between, the
# next run still sees a different size and picks up the rest.
CHANGED=() FROM=() NEW_SIZE=() NEW_LINES=()
while IFS=$'\t' read -r size p; do
    [ "${SIZE[$p]:-}" = "$size" ] && continue
    from="${LINES[$p]:-0}"
    # A file that shrank was rewritten: start over.
    [ "$size" -lt "${SIZE[$p]:-0}" ] && from=0
    CHANGED+=("$p")
    FROM+=("$from")
    NEW_SIZE+=("$size")
    NEW_LINES+=("$(wc -l < "$p")")
done < <(find "$PROJECTS" -name '*.jsonl' -printf '%s\t%p\n' 2>/dev/null)

[ "${#CHANGED[@]}" -eq 0 ] && exit 0

if ! client -q "SELECT 1" >/dev/null 2>&1; then
    log "ERROR: cannot connect to ClickHouse at '$CH_HOST'; will retry on the next hook."
    exit 1
fi

# Quote a string for a ClickHouse parameter of type Array(String) / Map(String, ...).
quote() { local s="${1//\\/\\\\}"; printf "'%s'" "${s//\'/\\\'}"; }

# Upload files CHANGED[$1 .. $2) and record them as done.
upload_range() {
    local i files="" offsets=""
    for ((i = $1; i < $2; i++)); do
        files+="$(quote "${CHANGED[$i]}"),"
        offsets+="$(quote "${CHANGED[$i]}"):${FROM[$i]},"
    done
    # Nothing new can be a normal outcome (e.g. only a half-written line was
    # appended), but the client refuses an empty insert, so let that through.
    local out
    out=$(clickhouse-local -q "
        SELECT _path AS path, line AS data
        FROM file({files:Array(String)}, 'LineAsString')
        WHERE _row_number >= {offsets:Map(String, UInt64)}[_path] AND isValidJSON(line)
        FORMAT Native
    " --param_files="[${files%,}]" --param_offsets="{${offsets%,}}" \
    | client -q "INSERT INTO claude_code.raw FORMAT Native" 2>&1; echo "status ${PIPESTATUS[*]}")
    if [[ "$out" != *"status 0 0" && ! ( "$out" == *"status 0 "* && "$out" == *NO_DATA_TO_INSERT* ) ]]; then
        log "ERROR: upload failed, will retry on the next hook: $out"
        exit 1
    fi
    for ((i = $1; i < $2; i++)); do
        SIZE["${CHANGED[$i]}"]=${NEW_SIZE[$i]}
        LINES["${CHANGED[$i]}"]=${NEW_LINES[$i]}
    done
    save_state
}

# Byte-bounded batches: a single argv entry is capped at 128 KiB on Linux, and
# each path goes into two parameters.
MAX_ARG=49152
start=0 len=0
for ((i = 0; i < ${#CHANGED[@]}; i++)); do
    item=$(( ${#CHANGED[$i]} + 24 ))
    if [ "$i" -gt "$start" ] && [ "$(( len + item ))" -gt "$MAX_ARG" ]; then
        upload_range "$start" "$i"
        start=$i len=0
    fi
    len=$(( len + item ))
done
upload_range "$start" "${#CHANGED[@]}"

log "Uploaded new entries from ${#CHANGED[@]} file(s)."
