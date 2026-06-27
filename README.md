## Read the blog: [https://clickhouse.com/blog/agentic-coding](https://clickhouse.com/blog/agentic-coding)

### Alexey Prompts

A viewer of Claude Code sessions with ClickHouse backend.

![Alexey Prompts](screenshot.png)

### How to use

Create a ClickHouse database:

```
CREATE DATABASE IF NOT EXISTS claude_code;

CREATE TABLE IF NOT EXISTS claude_code.raw
(
    path String,
    data JSON
)
ENGINE = ReplacingMergeTree
ORDER BY (data.sessionId::String, data.timestamp::String, data.uuid::String);

CREATE TABLE IF NOT EXISTS claude_code.classification
(
    data JSON
)
ENGINE = ReplacingMergeTree
ORDER BY data.session_id::String;
```

Upload your sessions:

```
clickhouse-local -q "
    SELECT _path AS path, json AS data
    FROM file('$HOME/.claude/projects/*/*.jsonl', 'JSONAsString')
    WHERE isValidJSON(json)
    SETTINGS input_format_allow_errors_ratio=0.1
    FORMAT Native
" | clickhouse-client --host '...' --password '...' -q "INSERT INTO claude_code.raw FORMAT Native"
```

This is likely optional:

```
clickhouse-local -q "
    SELECT _path AS path, json AS data
    FROM file('$HOME/.claude/history.jsonl', 'JSONAsString')
    WHERE isValidJSON(json)
    SETTINGS input_format_allow_errors_ratio=0.1
    FORMAT Native
" | clickhouse-client --host '...' --password '...'  -q "INSERT INTO claude_code.raw FORMAT Native"
```

#### Uploading only new data (incremental updates)

After the first upload, you don't need to re-send everything. Re-running the
commands above is always *safe* (the `raw` table is a `ReplacingMergeTree`, so
duplicates collapse), but it re-reads and re-sends every session each time.

Use `upload_incremental.sh` to upload only **new sessions** and **new entries
appended to existing sessions**:

```
CH_HOST='...' CH_USER='...' CH_PASSWORD='...' ./upload_incremental.sh
```

It keeps a marker file (`~/.claude/.ch_last_upload`) and on each run only reads
the `.jsonl` files modified since the previous successful run, then uploads
their rows. Untouched sessions are skipped; any overlap from a session that got
new entries is deduplicated by the table's `ORDER BY (sessionId, timestamp,
uuid)`. It's idempotent, so it's a good fit for cron, e.g. hourly:

```
0 * * * * CH_HOST='...' CH_PASSWORD='...' /path/to/upload_incremental.sh >> ~/.claude/ch_upload.log 2>&1
```

To force a full re-upload, delete the marker: `rm ~/.claude/.ch_last_upload`.

Edit `index.html` around CH_URL, CH_USER, CH_PASSWORD with your database credentials.

Optional: ask claude to run classification scripts and fill the classification table.

Open `index.html`.

### Do not share your sessions publicly

The sessions contain tool calls and results, including fragments of arbitrary filess. They may contain sensisive info, that's why it's not recommended to share sessions publicly.
