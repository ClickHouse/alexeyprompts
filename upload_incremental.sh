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
# Usage:
#   CH_HOST=... CH_PASSWORD=... ./upload_incremental.sh
#   FORCE=1 CH_HOST=... CH_PASSWORD=... ./upload_incremental.sh   # re-upload all

set -euo pipefail

CH_HOST="${CH_HOST:-localhost}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"
MARKER="${MARKER:-$HOME/.claude/.ch_last_upload}"
PROJECTS="${PROJECTS:-$HOME/.claude/projects}"
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

# Build the set of files to upload.
declare -A PICK=()

if [ -n "$FORCE" ]; then
    # Everything, regardless of marker or what's already loaded.
    while IFS= read -r f; do PICK["$f"]=1; done \
        < <(find "$PROJECTS" -name '*.jsonl')
else
    # 1. Locally-changed files (appended entries) -- cheap mtime fast-path.
    if [ -f "$MARKER" ]; then
        while IFS= read -r f; do PICK["$f"]=1; done \
            < <(find "$PROJECTS" -name '*.jsonl' -newer "$MARKER")
    fi

    # 2. Files ClickHouse doesn't have yet, by path. This is mtime-independent,
    #    so it catches new sessions copied from other machines and anything an
    #    earlier run missed. (Missing table -> empty set -> upload everything.)
    declare -A IN_CH=()
    while IFS= read -r p; do
        [ -n "$p" ] && IN_CH["$p"]=1
    done < <(client -q "SELECT DISTINCT path FROM claude_code.raw FORMAT TSVRaw" 2>/dev/null || true)

    while IFS= read -r f; do
        [ -n "${IN_CH["$f"]:-}" ] || PICK["$f"]=1
    done < <(find "$PROJECTS" -name '*.jsonl')
fi

FILES=("${!PICK[@]}")

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "Up to date -- ClickHouse already has every local session. Nothing to upload."
    mv -f "$NEW_MARKER" "$MARKER"
    trap - EXIT
    exit 0
fi
echo "Uploading ${#FILES[@]} new/changed session file(s)..."

# Read a batch of files and insert; ReplacingMergeTree deduplicates any overlap.
upload_batch() {
    local arr="$1"
    [ -z "$arr" ] && return 0
    arr="[${arr%,}]"
    clickhouse-local -q "
        SELECT _path AS path, json AS data
        FROM file({files:Array(String)}, 'JSONAsString')
        WHERE isValidJSON(json)
        SETTINGS input_format_allow_errors_ratio=0.1
        FORMAT Native
    " --param_files="$arr" \
    | client -q "INSERT INTO claude_code.raw FORMAT Native"
}

# Pass the paths in byte-bounded batches. The whole list cannot go in one
# argument: Linux caps a single argv entry at 128 KiB (MAX_ARG_STRLEN),
# regardless of the larger ARG_MAX total -- exceeding it makes clickhouse-local
# fail to start, which surfaces downstream as "No data to insert".
MAX_ARG="${MAX_ARG:-98304}"   # 96 KiB, safely under the 128 KiB single-arg limit
buf=""
done_count=0
for f in "${FILES[@]}"; do
    item="'${f//\'/\\\'}',"
    if [ "$(( ${#buf} + ${#item} ))" -gt "$MAX_ARG" ]; then
        upload_batch "$buf"
        buf=""
    fi
    buf+="$item"
    done_count=$((done_count + 1))
done
upload_batch "$buf"

# Commit the marker only after a successful upload.
mv -f "$NEW_MARKER" "$MARKER"
trap - EXIT
echo "Done ($done_count file(s)). Marker updated: $MARKER"
