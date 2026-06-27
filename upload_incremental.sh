#!/bin/bash
# Upload only NEW data to ClickHouse: new sessions and new entries appended to
# existing sessions. Safe to run repeatedly (e.g. from cron).
#
# How it works:
#   1. A marker file records when we last uploaded.
#   2. We read only the .jsonl files modified since then -- new session files
#      and existing files that got new entries appended.
#   3. We upload every row from those files. The `raw` table is a
#      ReplacingMergeTree ordered by (sessionId, timestamp, uuid), so the
#      handful of already-present rows in an appended file are deduplicated
#      automatically -- nothing is duplicated, and untouched files are skipped.
#
# Note: a row-level timestamp filter is intentionally NOT used, because some
# entries (mode, permission-mode, file-history-snapshot, ai-title, last-prompt)
# have no timestamp and would be lost.
#
# Usage:
#   CH_HOST=... CH_PASSWORD=... ./upload_incremental.sh

set -euo pipefail

CH_HOST="${CH_HOST:-localhost}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"
MARKER="${MARKER:-$HOME/.claude/.ch_last_upload}"

# Capture "now" up front so files changed *during* this run are picked up next time.
NEW_MARKER=$(mktemp)
trap 'rm -f "$NEW_MARKER"' EXIT

# 1. Select files modified since the last successful upload (all files on first run).
if [ -f "$MARKER" ]; then
    mapfile -t FILES < <(find "$HOME/.claude/projects" -name '*.jsonl' -newer "$MARKER")
else
    echo "No marker found -- uploading everything (first run)."
    mapfile -t FILES < <(find "$HOME/.claude/projects" -name '*.jsonl')
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No new or changed session files. Nothing to upload."
    mv -f "$NEW_MARKER" "$MARKER"
    trap - EXIT
    exit 0
fi
echo "Uploading ${#FILES[@]} new/changed session file(s)..."

# 2. Build a ClickHouse array literal of the file paths (escape any single quotes).
FILES_ARRAY="["
for f in "${FILES[@]}"; do
    FILES_ARRAY+="'${f//\'/\\\'}',"
done
FILES_ARRAY="${FILES_ARRAY%,}]"

# 3. Read those files and insert; ReplacingMergeTree deduplicates any overlap.
clickhouse-local -q "
    SELECT _path AS path, json AS data
    FROM file({files:Array(String)}, 'JSONAsString')
    WHERE isValidJSON(json)
    SETTINGS input_format_allow_errors_ratio=0.1
    FORMAT Native
" --param_files="$FILES_ARRAY" \
| clickhouse-client --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" \
    -q "INSERT INTO claude_code.raw FORMAT Native"

# 4. Commit the marker only after a successful upload.
mv -f "$NEW_MARKER" "$MARKER"
trap - EXIT
echo "Done. Marker updated: $MARKER"
