# Nightscout sawtooth precompute — implementation plan

**Version:** 1.13  
**Status:** Implementation plan (converts approved design into build plan)  
**Last updated:** 2026-03-20 21:58 CET  
**Design reference:** `nightscout-precompute-design.md` (v1.16)

---

## 1. Verdict

The design in `nightscout-precompute-design.md` is implementation-ready. This plan converts it into a concrete build: one standalone Node script run by cron every minute, **checkpoint in file or MongoDB** (v1 supports both; use MongoDB when `MONGODB_URI` is set — e.g. on Heroku — via a dedicated collection in Nightscout's existing DB), query to existing Trio Better Stack logs (with S3 union when window &gt; ~40 min), reconstruction in memory, batch push to the existing **Trio Complication Recency** Prometheus-push source. The Prometheus source must exist (create per design §6 if not already present). No Trio app changes. No redesign of the two-source Better Stack model, emit delay, or checkpoint semantics.

---

## 2. Scope and non-goals

**In scope**

- One new standalone script in the Nightscout (cgm-remote-monitor) repo: `bin/sawtooth-precompute.js`.
- Supporting modules under `lib/sawtooth-precompute/`: run loop, fetch GTL logs (Better Stack Query API), dedupe, push metrics (Better Stack ingest), state (file or MongoDB).
- Cron (or equivalent) invoking the script once per minute.
- **Checkpoint:** file (e.g. `data/sawtooth-precompute-state.json`) **or** MongoDB (dedicated collection in Nightscout's existing DB; use when `MONGODB_URI` is set, e.g. on Heroku). Same `last_emitted_minute_epoch` semantics either way.
- Query Trio logs from Better Stack (connect host, basic auth, ClickHouse SQL).
- Push gauge points to Better Stack source **Trio Complication Recency** (ingest host `s2301525.eu-fsn-3.betterstackdata.com`, source id `trio_complication_recency_2`).
- Emit delay (e.g. 120 s), emit ceiling, empty-GTL handling, dedupe/ASOF semantics per design.

**Out of scope (non-goals)**

- Changes to the Trio iOS app or any Trio repo code.
- Merging the two Better Stack sources into one.
- In-process Nightscout plugin or setInterval-based runner for v1 (cron + standalone only).
- Dashboard chart creation (assumed done separately against the same source).
- Removing or reducing the emit delay.

---

## 3. Implementation architecture

- **Data flow (one run):**
  1. Load checkpoint → `last_emitted_minute_epoch`.
  2. Compute emit ceiling: `end_minute = max(0, floor(now/60)*60 - 60 - emit_delay_seconds)`; if `end_minute <= last_emitted_minute_epoch`, exit.
  3. Compute window: `window_start = max(0, last_emitted_minute_epoch - lookback_seconds)`, `window_end = now` (wall-clock seconds).
  4. POST to Better Stack Query API (Trio logs): SQL over Trio logs with time bound `[window_start, window_end]`, filter GTL events; **include S3 union** when window spans &gt; ~40 min (required for 3h lookback — hot tier holds only ~30–40 min). Get rows with `dt` (Unix seconds) and `message`.
  5. Parse each row: from `message` extract `data_age_seconds`, `battery_state`, `get_timeline_at_epoch_seconds`.
  6. Dedupe by `dt`; per group: `is_off_wrist` (charging or full), `data_age_seconds` (argMax tie-break), `gtl_epoch` (parsed; if disagree use max and log WARN). Filter to rows where `is_off_wrist === true` OR `data_age_seconds != null`. Sort by `gtl_epoch`.
  7. For each minute in `(last_emitted_minute_epoch, end_minute]`: ASOF last GTL with `gtl_epoch <= minute_epoch`; value = 0 if off-wrist, else `data_age_seconds + (minute_epoch - gtl_epoch)` (clamp ≥ 0). Skip minute if no anchor (sparse GTL).
  8. POST to Better Stack ingest: one request with array of `{ name, gauge: { value }, dt }` (Unix integer), Bearer token for Trio Complication Recency source.
  9. If all pushes succeed: set `last_emitted_minute_epoch = end_minute`, save checkpoint. On any push failure: do not advance checkpoint; next run retries same range.
  10. If query returned 0 rows (and query succeeded): still advance checkpoint after (zero) pushes, log WARN. If query failed: do not advance; exit.

- **Sources:**
  - **GTL data:** Existing Trio Better Stack logs (source_id 1659391). Query via Connect API (e.g. `eu-nbg-2-connect.betterstackdata.com`), basic auth, POST body = raw SQL.
  - **Metrics sink:** Existing Better Stack Prometheus-push source **Trio Complication Recency** — name: "Trio Complication Recency", platform: Prometheus push, source id: `trio_complication_recency_2`, ingesting host: `s2301525.eu-fsn-3.betterstackdata.com`. Token from that source used as Bearer for POST `/metrics`.

### 3.1 Nightscout MongoDB usage (for checkpoint)

Nightscout (cgm-remote-monitor) already uses MongoDB as its primary store. The standalone sawtooth script can use the **same database** for checkpoint state so that on Heroku (ephemeral filesystem) the checkpoint survives restarts and deploys.

**Relevant repo files (verified):**

- **`lib/server/env.js`** — Reads `MONGODB_URI` (or `STORAGE_URI`, `MONGO_CONNECTION`, `MONGOLAB_URI`) into `env.storageURI`. Collection names are read from env (e.g. `MONGO_SETTINGS_COLLECTION` or default `'settings'`); other collections: `entries`, `treatments`, `profile`, `devicestatus`, `food`, `activity`, plus `auth_*` for authorization.
- **`lib/storage/mongo-storage.js`** — Exports `init(env, cb)`. Uses `require('mongodb').MongoClient`, connects with `env.storageURI`, and exposes:
  - `mongo.client` (MongoClient instance)
  - `mongo.db` (database from the connection; db name comes from the URI)
  - `mongo.collection(name)` → returns `mongo.db.collection(name)` (native driver collection)
  - `mongo.ensureIndexes(collection, fields)` for index creation
- **Server boot** (`lib/server/bootevent.js`) — Calls `require('../storage/mongo-storage')(env, function ready(err, store) { ... })`; passes `env` (which has `storageURI`). The returned `store` is the same `mongo` object (`.collection()`, `.db`). Rest of the app uses `ctx.store.collection(collectionName)` for reads/writes (e.g. `findOne`, `insertOne`, `updateOne`).

**Implication for the sawtooth script:** The script runs as a **separate process** (cron), so it does not use `ctx.store`. It must connect to MongoDB itself using the same connection string. Nightscout already sets `MONGODB_URI` in the environment (Heroku, Railway, etc.), so the script can:

1. Read `process.env.MONGODB_URI` (after loading `.env` if present).
2. Use `require('mongodb').MongoClient` (same dependency as Nightscout — already in `package.json`).
3. Connect once per run (or cache client for the process), then use a **dedicated collection** that Nightscout does not use (e.g. `sawtooth_precompute_state`). Use a single document keyed by `_id: 'checkpoint'` with fields `last_emitted_minute_epoch` and optional `updated_at`.
4. **loadState:** `collection.findOne({ _id: 'checkpoint' })` → return `{ last_emitted_minute_epoch: doc?.last_emitted_minute_epoch ?? 0 }`.
5. **saveState:** `collection.updateOne({ _id: 'checkpoint' }, { $set: { last_emitted_minute_epoch: state.last_emitted_minute_epoch, updated_at: new Date() } }, { upsert: true })`.

No schema migration or new Nightscout collections are required beyond this one document; the script creates the collection implicitly on first upsert. Backend selection: if `SAWTOOTH_STATE_BACKEND=mongo` or `MONGODB_URI` is set and backend is not explicitly `file`, use MongoDB; otherwise use file (so existing deployments without Mongo continue to work).

---

## 4. File / module plan

All paths relative to cgm-remote-monitor repo root.

```
bin/
  sawtooth-precompute.js          # Entrypoint: load env, require run, run(), process.exit(0|1)

lib/
  sawtooth-precompute/
    run.js                        # Main loop: loadState, window, fetchGtlLogs, dedupe, filter, sort, ASOF loop, pushGauges, saveState
    fetch-gtl-logs.js             # queryGtlLogs(windowStartSec, windowEndSec) → raw rows or throw; uses BETTERSTACK_QUERY_* and SQL template
    parse-message.js              # parseMessage(messageStr) → { data_age_seconds, battery_state, get_timeline_at_epoch_seconds } or null
    dedupe.js                     # dedupeByDt(rows) → [{ gtl_epoch, data_age_seconds, is_off_wrist }]; tie-break max(gtl_epoch)+WARN
    push-metrics.js               # pushGauges(points[]) → POST array to ingest host, Bearer token; points = [{ minute_epoch, value }]
    state.js                      # loadState() → { last_emitted_minute_epoch }; saveState(state); backend = file or MongoDB from env (§3.1)

data/
  sawtooth-precompute-state.json  # Checkpoint file when backend=file (create dir if missing)
```

- **Minimum viable v1:** `bin/sawtooth-precompute.js` + `lib/sawtooth-precompute/run.js` + `fetch-gtl-logs.js` + `parse-message.js` + `dedupe.js` + `push-metrics.js` + `state.js`. One script; checkpoint in file or MongoDB (chosen by env); cron every minute; batch push in one POST when possible.

---

## 5. Phase-by-phase implementation plan

### Phase 1: Environment and state

- [ ] **1.1** Define and document required env vars (see §7). Add to repo `.env.example` or docs: `BETTERSTACK_QUERY_HOST`, `BETTERSTACK_QUERY_USER`, `BETTERSTACK_QUERY_PASSWORD`, `BETTERSTACK_INGEST_HOST`, `BETTERSTACK_RECENCY_SOURCE_TOKEN`, `SAWTOOTH_LOOKBACK_SECONDS`, `SAWTOOTH_EMIT_DELAY_SECONDS`, `SAWTOOTH_STATE_FILE`; and for MongoDB backend: `MONGODB_URI` (reuse Nightscout's), `SAWTOOTH_STATE_BACKEND`, `SAWTOOTH_STATE_COLLECTION`.
- [ ] **1.2** Implement `lib/sawtooth-precompute/state.js` with **two backends** (chosen by env per §3.1):
  - **File backend:** When `SAWTOOTH_STATE_BACKEND=file` or `MONGODB_URI` is unset, read/write JSON file at path from env (default `data/sawtooth-precompute-state.json`). Create directory if missing. `loadState()` returns `{ last_emitted_minute_epoch: number }` (0 if missing or invalid). `saveState(state)` overwrites file atomically (write to temp then rename, or single write).
  - **MongoDB backend:** When `SAWTOOTH_STATE_BACKEND=mongo` or when `MONGODB_URI` is set and backend is not `file`, connect using `require('mongodb').MongoClient` and `process.env.MONGODB_URI` (same as Nightscout). Use collection name from `SAWTOOTH_STATE_COLLECTION` (default `sawtooth_precompute_state`). Single document: `{ _id: 'checkpoint', last_emitted_minute_epoch: number, updated_at: Date }`. **loadState:** `collection.findOne({ _id: 'checkpoint' })`; return `{ last_emitted_minute_epoch: doc?.last_emitted_minute_epoch ?? 0 }`. **saveState:** `collection.updateOne({ _id: 'checkpoint' }, { $set: { last_emitted_minute_epoch: state.last_emitted_minute_epoch, updated_at: new Date() } }, { upsert: true })`. Connect at first use in the run; close client after saveState (or on process exit) so the script exits cleanly.
- [ ] **1.3** **File backend:** **Require** a lock file (e.g. `data/sawtooth-precompute-state.lock`): acquire before loadState, release after saveState or on exit. Prevents overlapping cron runs from corrupting checkpoint (cron does not guarantee serialization — see §6.2). **MongoDB backend:** Single-writer is a **deployment invariant** (only one cron instance must run); no file lock.

### Phase 2: Better Stack query client

- [ ] **2.1** Implement `lib/sawtooth-precompute/fetch-gtl-logs.js`: Use the **single canonical contract** in §8.1 (URL, method, headers, auth, body, response format). POST to `https://${BETTERSTACK_QUERY_HOST}` with query param `output_format_pretty_row_numbers=0` if applicable. Basic auth from env. Body: SQL string. Timeout e.g. 30 s. On non-2xx or parse error: throw (caller will not advance checkpoint). **Retry once** on transient errors (ETIMEDOUT, ECONNRESET, ECONNREFUSED, HTTP 503, timeout) with a 5 s delay before throwing; non-transient errors throw immediately. Log WARN on retry.
- [ ] **2.2** SQL template: use exact table and filter from design §4.9. Hot tier holds only ~30–40 minutes (AGENTS.md); with 3h lookback, most of the window is outside hot tier, so **v1 must use the S3 union** for the GTL query whenever `(window_end - window_start) > 2400` (40 min in seconds), or always use the union for simplicity. Use `toUnixTimestamp(dt) AS dt` and `message`; parameterize `window_start` and `window_end` (Unix seconds). Example: `SELECT toUnixTimestamp(dt) AS dt, JSONExtract(raw, 'message', 'Nullable(String)') AS message FROM remote(t491594_trio_logs) WHERE dt BETWEEN toDateTime(${window_start}) AND toDateTime(${window_end}) AND ... UNION ALL SELECT ... FROM s3Cluster(primary, t491594_trio_s3) WHERE _row_type = 1 AND dt BETWEEN ...` (same time bounds and filter; see design §4.1, §4.9 and AGENTS.md for full union pattern).
- [ ] **2.3** Parse response: Use **one** response format as specified in §8.1 (e.g. JSON or the format the Query API returns). Parser yields array of `{ dt: number, message: string }`. If response is empty or no rows, return `[]`. On parse error or unexpected Content-Type: **throw** (do not implement fallback parsers for TSV/CSV/JSON; pick one and fail fast).

### Phase 3: Message parsing and dedupe

- [ ] **3.1** Implement `lib/sawtooth-precompute/parse-message.js`: input `message` string; extract `data_age_seconds` (regex e.g. `data_age_seconds=(\d+)`), `battery_state` (e.g. `battery_state=charging|unplugged|unknown`), `get_timeline_at_epoch_seconds` (e.g. `get_timeline_at_epoch_seconds=(\d+)`). Return `{ data_age_seconds: number | null, battery_state: string | null, get_timeline_at_epoch_seconds: number | null }` or null if not GTL-like.
- [ ] **3.2** Implement `lib/sawtooth-precompute/dedupe.js`: input array of `{ dt, data_age_seconds, battery_state, get_timeline_at_epoch_seconds }` (from raw rows + parse). Group by `dt`. Per group: `is_off_wrist = (battery_state === 'charging' || battery_state === 'full')` — `unknown` is treated as on-wrist (common during provider restarts; see design §4.2); `data_age_seconds` = value from one on-wrist row (argMax: prefer non-null, then max); `gtl_epoch` = parsed `get_timeline_at_epoch_seconds`; if group has multiple different `get_timeline_at_epoch_seconds`, use `max(gtl_epoch)` and log WARN. Output rows where `is_off_wrist === true` OR `data_age_seconds != null`. Sort output by `gtl_epoch`.

### Phase 4: Reconstruction and push

- [ ] **4.1** In `run.js`: from deduped GTL list, for each minute in `[from_minute, to_minute]` step 60, find last GTL with `gtl_epoch <= minute_epoch`. If none, skip minute. If anchor `is_off_wrist`, value = 0; else value = `Math.max(0, data_age_seconds + (minute_epoch - gtl_epoch))`. Collect list of `{ minute_epoch, value }`.
- [ ] **4.2** Implement `lib/sawtooth-precompute/push-metrics.js`: POST to `https://${BETTERSTACK_INGEST_HOST}/metrics`, header `Authorization: Bearer ${BETTERSTACK_RECENCY_SOURCE_TOKEN}`, `Content-Type: application/json`. Body: JSON array of `{ "name": "complication_visible_recency_seconds", "gauge": { "value": value }, "dt": minute_epoch }` (Unix integer). Single POST for full batch. On non-2xx: throw so run.js does not advance checkpoint.
- [ ] **4.3** In `run.js`: only after pushGauges() succeeds (or batch is empty), set `state.last_emitted_minute_epoch = to_minute` and call saveState(). On push failure, do not save; next run retries same range.

### Phase 5: Main loop and entrypoint

- [ ] **5.1** Implement `lib/sawtooth-precompute/run.js`: (1) loadState(), (2) wall_now = Date.now()/1000, now_epoch = floor(wall_now/60)*60, end_minute = max(0, now_epoch - 60 - emit_delay_seconds); if end_minute <= state.last_emitted_minute_epoch return; (3) window_start/window_end; (4) query GTL (try/catch: on error log and return without advancing); (5) parse each row, dedupe, filter, sort; (6) if GTL list length 0, log WARN "empty GTL list", set points = [], still will advance checkpoint after; (7) compute points (ASOF loop); (8) if points.length > 0, pushGauges(points); (9) state.last_emitted_minute_epoch = to_minute, saveState(). Use config: lookback_seconds (default 10800), emit_delay_seconds (default 120).
- [ ] **5.2** Implement `bin/sawtooth-precompute.js`: require('dotenv').config() or load env from file if present; **require('../lib/sawtooth-precompute/run').run()** (from `bin/`, use `../lib/`); process.exit(0). On uncaught error: log, process.exit(1). No arguments; all config from env.

### Phase 6: Logging and cron

- [ ] **6.1** Logging (shipped shape): **no** per-run `start` line. On emit ceiling unchanged log `sawtooth-precompute skip (nothing to do)`. After successful checkpoint for a run that had work to do, log **one** line: `sawtooth-precompute pushed gtl_rows=… parsed=… deduped=… skipped_no_anchor=… minutes=… end_minute=… anchor_gtl_epoch=… anchor_gtl_age_seconds=… emit_delay_actual_seconds=…` (see §9). On empty GTL (query OK, zero rows after parse/dedupe) log WARN `sawtooth-precompute WARN empty GTL list, advancing checkpoint` before the success line. On query or push error log `sawtooth-precompute ERROR …`. Use `console.log` / `console.warn` / `console.error` so the process log / Heroku drain captures output.
- [ ] **6.2** Cron: document crontab entry `* * * * * cd /path/to/cgm-remote-monitor && node bin/sawtooth-precompute.js >> /path/to/logs/sawtooth-precompute.log 2>&1` (or equivalent). **Only one instance must run.** Cron does **not** guarantee serialization — a long-running or stuck run can overlap the next. **File backend:** Lock file (Phase 1.3) is **required**. **MongoDB backend:** Single-writer is a deployment invariant; ensure only one cron instance is configured.

### Phase 7: Cold start and backfill

- [ ] **7.1** Document cold start: before first production run, set checkpoint so the first run is bounded. **File backend:** write state file with `last_emitted_minute_epoch` = floor(Date.now()/1000/60)*60 - 3600 (or desired backfill start). **MongoDB backend:** same value via mongosh upsert (see §11 step 3) or rely on cold start (no document → loadState returns 0); prefer explicit init for a bounded first run. Checkpoint missing or `last_emitted_minute_epoch` = 0 (file: state file missing; Mongo: no document): cold start; do not start with 0 without bounding (would imply from_minute = 60 and huge backfill).
- [ ] **7.2** Optional backfill script or env: e.g. `SAWTOOTH_EMIT_DELAY_SECONDS=0` and manually set checkpoint to old value to backfill a window; ensure GTL query uses S3 union for windows older than ~40 minutes.

---

## 6. Detailed algorithm

Same as design §5 and §10, with concrete types and failure behavior.

**Inputs (from env and state):**

- `last_emitted_minute_epoch`: number (from state — file or Mongo; 0 or last pushed minute).
- `lookback_seconds`: number (default 10800 = 3 h).
- `emit_delay_seconds`: number (default 120).

**Steps:**

1. **Emit ceiling:** `wall_now = Date.now() / 1000`; `now_epoch = Math.floor(wall_now / 60) * 60`; `end_minute_epoch = Math.max(0, now_epoch - 60 - emit_delay_seconds)`. If `end_minute_epoch <= last_emitted_minute_epoch`, exit (nothing to do).
2. **Window:** `window_start = Math.max(0, last_emitted_minute_epoch - lookback_seconds)`; `window_end = wall_now`.
3. **Query GTL:** POST SQL to Better Stack with `dt BETWEEN toDateTime(window_start) AND toDateTime(window_end)` and GTL filter. If HTTP error or parse error: log error, exit without advancing checkpoint. Response → array of `{ dt, message }`.
4. **Parse:** For each row, parse message → `data_age_seconds`, `battery_state`, `get_timeline_at_epoch_seconds`. Drop rows that fail to parse or lack GTL fields.
5. **Dedupe:** Group by `dt`. Per group: is_off_wrist (charging or full; unknown = on-wrist), data_age_seconds (argMax among on-wrist), gtl_epoch (parsed; if disagree use max, log WARN). Filter to `is_off_wrist || data_age_seconds != null`. Sort by gtl_epoch.
6. **Empty:** If deduped list length === 0: log WARN "empty GTL list"; set `points = []`; will still advance checkpoint to `to_minute` after step 8.
7. **ASOF:** `from_minute = last_emitted_minute_epoch + 60`; `to_minute = end_minute_epoch`. For minute_epoch = from_minute to to_minute step 60: find last GTL with gtl_epoch <= minute_epoch; if none, skip; else value = 0 if off_wrist else max(0, data_age_seconds + (minute_epoch - gtl_epoch)); append { minute_epoch, value } to points.
8. **Push:** If points.length > 0: POST array of gauges to ingest host; on non-2xx throw (do not advance). If points.length === 0 (empty GTL case): no POST.
9. **Checkpoint:** Set `last_emitted_minute_epoch = to_minute`; saveState(). Exit 0.

**Pseudocode (main loop):**

```text
function run():
  state = loadState()
  wall_now = now_seconds()
  now_epoch = floor(wall_now / 60) * 60
  end_minute = max(0, now_epoch - 60 - emit_delay_seconds)
  if end_minute <= state.last_emitted_minute_epoch:
    log "skip (nothing to do)"; return

  window_start = max(0, state.last_emitted_minute_epoch - lookback_seconds)
  window_end = wall_now

  rawRows = queryGtlLogs(window_start, window_end)   // throws on HTTP/parse error
  rows = rawRows.map(r => ({ ...r, ...parseMessage(r.message) })).filter(Boolean)
  gtlList = dedupeByDt(rows)   // sorted by gtl_epoch
  if gtlList.length === 0: log WARN "empty GTL list"

  from_minute = state.last_emitted_minute_epoch + 60
  to_minute = end_minute
  points = []
  for minute_epoch = from_minute to to_minute step 60:
    anchor = last(gtlList where gtl_epoch <= minute_epoch)
    if !anchor: continue
    value = anchor.is_off_wrist ? 0 : max(0, anchor.data_age_seconds + (minute_epoch - anchor.gtl_epoch))
    points.push({ minute_epoch, value })

  if points.length > 0: pushGauges(points)   // throws on failure
  // empty GTL: points=[] so pushGauges skipped; checkpoint still advances per design §4.8
  state.last_emitted_minute_epoch = to_minute
  saveState(state)
  log single "pushed" line with gtl_rows, parsed, deduped, skipped_no_anchor, minutes, end_minute, anchor_gtl_epoch, anchor_gtl_age_seconds, emit_delay_actual_seconds (see §9)
```

---

## 7. Config / env vars

| Env var | Required | Default | Description |
|---------|----------|---------|-------------|
| `BETTERSTACK_QUERY_HOST` | Yes | — | Connect host for Trio logs SQL (e.g. `eu-nbg-2-connect.betterstackdata.com`). No scheme; code uses `https://`. |
| `BETTERSTACK_QUERY_USER` | Yes | — | Basic auth user for Query API. |
| `BETTERSTACK_QUERY_PASSWORD` | Yes | — | Basic auth password for Query API. |
| `BETTERSTACK_INGEST_HOST` | Yes | — | Ingest host for metrics push (set from env; no default). Current known value for this source: `s2301525.eu-fsn-3.betterstackdata.com` — see .env example. |
| `BETTERSTACK_RECENCY_SOURCE_TOKEN` | Yes | — | Bearer token for source **Trio Complication Recency** (source id `trio_complication_recency_2`). |
| `SAWTOOTH_LOOKBACK_SECONDS` | No | 10800 | Lookback for GTL window (3 h). |
| `SAWTOOTH_EMIT_DELAY_SECONDS` | No | 120 | Cold-start emit delay (seconds); used until the dynamic lag tracker has observations. |
| `SAWTOOTH_LAG_WINDOW_SECONDS` | No | 10800 | Rolling window (seconds) for data-horizon-lag observations (3 h). |
| `SAWTOOTH_LAG_BUFFER_SECONDS` | No | 120 | Buffer added on top of `lag_window_max` to compute `effective_emit_delay`. |
| `SAWTOOTH_STATE_FILE` | No | `data/sawtooth-precompute-state.json` | Path to checkpoint file when backend=file (relative to CWD or absolute). |
| `SAWTOOTH_STATE_BACKEND` | No | inferred | `file` or `mongo`. If unset: use `mongo` when `MONGODB_URI` is set, else `file`. Use `mongo` on Heroku (Nightscout already sets `MONGODB_URI`). |
| `SAWTOOTH_STATE_COLLECTION` | No | `sawtooth_precompute_state` | MongoDB collection name when backend=mongo. Dedicated collection; one document (see §8.5). |
| `MONGODB_URI` | When backend=mongo | — | Same as Nightscout (e.g. from Heroku config). Script connects with this URI; no separate DB. |

Example `.env` snippet (values are placeholders):

```bash
BETTERSTACK_QUERY_HOST=eu-nbg-2-connect.betterstackdata.com
BETTERSTACK_QUERY_USER=your_query_user
BETTERSTACK_QUERY_PASSWORD=your_query_password
BETTERSTACK_INGEST_HOST=s2301525.eu-fsn-3.betterstackdata.com
BETTERSTACK_RECENCY_SOURCE_TOKEN=your_recency_source_token
SAWTOOTH_LOOKBACK_SECONDS=10800
SAWTOOTH_EMIT_DELAY_SECONDS=120
SAWTOOTH_LAG_WINDOW_SECONDS=10800
SAWTOOTH_LAG_BUFFER_SECONDS=120
SAWTOOTH_STATE_FILE=data/sawtooth-precompute-state.json
# Optional: use MongoDB for checkpoint (e.g. on Heroku); Nightscout already sets MONGODB_URI
# SAWTOOTH_STATE_BACKEND=mongo
# SAWTOOTH_STATE_COLLECTION=sawtooth_precompute_state
```

---

## 8. Data contracts

### 8.1 Better Stack query (GTL logs) — canonical contract

Use this contract in one place (e.g. `fetch-gtl-logs.js`); do not duplicate or vary URL/auth/response handling elsewhere.

- **URL:** `https://${BETTERSTACK_QUERY_HOST}?output_format_pretty_row_numbers=0` (no trailing path; host from env; code prepends `https://`). Query param optional per API docs.
- **Method:** POST.
- **Headers:** `Content-Type: text/plain` (or `plain/text` per Better Stack Query API), body = raw SQL string. `Accept` (if needed) set to the single response format chosen below.
- **Auth:** HTTP Basic with `BETTERSTACK_QUERY_USER` and `BETTERSTACK_QUERY_PASSWORD`.
- **Response format:** **Lock to one format.** Prefer the format documented by the Better Stack Query API for this endpoint (e.g. JSON or TSV). Request that format via Accept or API default. **Parser:** Parse only that format; produce `{ dt: number, message: string }[]`. On empty response body or zero rows, return `[]`. On parse failure or unexpected Content-Type, **throw** — do not implement fallback parsers for multiple formats.
- **SQL (concrete example — hot tier only; for windows &gt; ~40 min use the full S3 union per §2.2 and design §4.9):**

```sql
SELECT
  toUnixTimestamp(dt) AS dt,
  JSONExtract(raw, 'message', 'Nullable(String)') AS message
FROM remote(t491594_trio_logs)
WHERE dt BETWEEN toDateTime(1710000000) AND toDateTime(1710010800)
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
```

- **Response (after parser):** Array of `{ dt: number, message: string }`. Empty result = `[]`; do not treat as failure. Parser must implement the single format chosen above; throw on parse error.

### 8.2 Parsed row (after parse-message)

- **Input:** `message` string.
- **Output:** `{ data_age_seconds: number | null, battery_state: string | null, get_timeline_at_epoch_seconds: number | null }` or null. Caller drops nulls.

### 8.3 Deduped GTL row

- **Shape:** `{ gtl_epoch: number, data_age_seconds: number | null, is_off_wrist: boolean }`. Sorted by `gtl_epoch`. Filter: keep only `is_off_wrist === true || data_age_seconds != null`.

### 8.4 Checkpoint file

- **Path:** From `SAWTOOTH_STATE_FILE` or default `data/sawtooth-precompute-state.json`.
- **Format:** Single JSON object. Example:

```json
{
  "last_emitted_minute_epoch": 1710010660
}
```

- **Semantics:** `last_emitted_minute_epoch` is the Unix minute epoch (floor of second / 60 * 60) of the last minute for which a gauge was successfully pushed. 0 or missing = cold start (must initialize before first run or backfill).

### 8.5 MongoDB checkpoint (when SAWTOOTH_STATE_BACKEND=mongo or MONGODB_URI set)

- **Collection:** Name from `SAWTOOTH_STATE_COLLECTION` (default `sawtooth_precompute_state`). Same database as Nightscout (from `MONGODB_URI`). Collection is created implicitly on first upsert.
- **Document:** Single document per collection. Example:

```json
{
  "_id": "checkpoint",
  "last_emitted_minute_epoch": 1710010660,
  "updated_at": "2026-03-16T12:00:00.000Z"
}
```

- **loadState:** `collection.findOne({ _id: 'checkpoint' })`. If no document, return `{ last_emitted_minute_epoch: 0 }`. Else return `{ last_emitted_minute_epoch: doc.last_emitted_minute_epoch ?? 0 }`.
- **saveState:** `collection.updateOne({ _id: 'checkpoint' }, { $set: { last_emitted_minute_epoch: state.last_emitted_minute_epoch, updated_at: new Date() } }, { upsert: true })`.
- **Connection:** Script uses `require('mongodb').MongoClient` and `process.env.MONGODB_URI` (same env var Nightscout uses in `lib/server/env.js` → `env.storageURI`). Connect at first loadState or at run start; close after saveState or on process exit.

### 8.6 Push payload (metrics ingest)

- **Endpoint:** `POST https://${BETTERSTACK_INGEST_HOST}/metrics` (host from env; see §7). Current example value: `s2301525.eu-fsn-3.betterstackdata.com`.
- **Headers:** `Authorization: Bearer <BETTERSTACK_RECENCY_SOURCE_TOKEN>`, `Content-Type: application/json`
- **Body (array):**

```json
[
  { "name": "complication_visible_recency_seconds", "gauge": { "value": 45 }, "dt": 1710010600 },
  { "name": "complication_visible_recency_seconds", "gauge": { "value": 105 }, "dt": 1710010660 }
]
```

- **Rules:** `dt` = Unix integer (seconds). One object per minute. Metric name fixed: `complication_visible_recency_seconds`. No batching limit other than 20 MiB; v1 sends one POST per run with all minutes in the run.

---

## 9. Logging and observability

**Principles:** Minimize log volume (one success line per productive run). Prefer **cron / worker log drain** (e.g. Heroku) for timestamps: server receive time on that source supports lag metrics derived from the structured fields below.

- **Early exit (nothing to do):** `sawtooth-precompute skip (nothing to do) effective_emit_delay=… lag_window_max=… lag_obs=…` — no GTL query in that run.
- **Cold start:** WARN `sawtooth-precompute WARN cold start (checkpoint=0); …` when checkpoint is zero (unchanged).
- **Empty GTL (query OK, no usable rows):** WARN `sawtooth-precompute WARN empty GTL list, advancing checkpoint` before state advances (unchanged).
- **Dedupe tie-break:** WARN `sawtooth-precompute WARN gtl_epoch tie-break applied for dt=...` (unchanged).
- **Successful run (after all checkpoint writes for the range):** **Single** line, prefix `sawtooth-precompute pushed`, including:
  - `gtl_rows` — raw rows from Query API  
  - `parsed` — rows that passed `parseMessage`  
  - `deduped` — rows after `dedupeByDt`  
  - `skipped_no_anchor` — minute buckets with no ASOF anchor  
  - `minutes` — count of gauge points pushed this run (0 allowed)  
  - `end_minute` — emit ceiling `to_minute` (Unix seconds, minute-aligned)  
  - `anchor_gtl_epoch` — `gtl_epoch` of anchor for the **last emitted** minute, or `-1` if none  
  - `anchor_gtl_age_seconds` — `round(wall_at_log - anchor_gtl_epoch)` or `-1` if no anchor  
  - `emit_delay_actual_seconds` — `round(wall_at_log - end_minute)` (actual lag vs emitted minute)  
  - `effective_emit_delay` — emit delay used for this run (dynamic or cold-start fallback)  
  - `data_horizon_lag` — `wall_now - max(dt)` across all GTL rows; `-1` if no rows  
  - `lag_window_max` — rolling max of data_horizon_lag over the lag window; `-1` on cold start  
  - `lag_obs` — number of lag observations in the rolling window  
  `wall_at_log` is taken immediately before the log (after async work), so ages reflect end-of-run wall clock.
- **Query / push / state failures:** `sawtooth-precompute ERROR …` with context; do not advance checkpoint (unchanged).
- **Entrypoint:** Uncaught errors still logged; `bin/sawtooth-precompute.js` exits non-zero on failure.

**Observability:** Parse the `pushed` line for dashboards/alerts (Better Stack metric extraction on the **cron/worker** log source if used). Filter `anchor_gtl_age_seconds >= 0` when averaging so sentinel `-1` rows do not skew stats. README in cgm-remote-monitor lists example extraction expressions. Checkpoint `updated_at` / file mtime remains the ground truth for last successful persistence.

---

## 10. Test plan

- **Unit (optional):** parse-message: sample message strings (with/without data_age_seconds, battery_state, get_timeline_at_epoch_seconds). dedupe: two rows same dt, different gtl_epoch → one row, max gtl_epoch and WARN.
- **Integration (manual or script):** (1) Set checkpoint to known value; set emit_delay to 0; run script; verify one POST to ingest host with correct body shape and Bearer token. (2) Mock or use real Query API: run with real credentials, verify GTL query returns rows and push succeeds, checkpoint advances. (3) Query failure: simulate 5xx or timeout; verify checkpoint unchanged. (4) Push failure: simulate 4xx on ingest; verify checkpoint unchanged.
- **Cold start:** Checkpoint missing or `last_emitted_minute_epoch: 0` (file: state file missing; Mongo: no document or doc with 0); run with end_minute computed from now; verify no unbounded backfill (either exit nothing-to-do or bounded by emit ceiling). Prefer initializing checkpoint (file or Mongo per §11 step 3) before first run.
- **Empty GTL:** Mock query returning []; verify WARN logged and checkpoint advances to to_minute (no push).

---

## 11. Rollout / rollback

**Rollout**

1. Add env vars to deployment (or `.env`). **File backend:** Ensure `data/` exists and is writable (or the path in `SAWTOOTH_STATE_FILE`). **MongoDB backend:** Ensure `MONGODB_URI` is set (same as Nightscout; on Heroku this is already set) — no need to create `data/` or a state file.
2. Deploy new code (bin + lib/sawtooth-precompute).
3. **Initialize checkpoint (backend-specific):**  
   **File backend:** Write `data/sawtooth-precompute-state.json` with `last_emitted_minute_epoch` = floor(now/60)*60 - 3600 (or desired backfill start).  
   **MongoDB backend:** Either (a) insert checkpoint once, e.g. `mongosh "$MONGODB_URI" --eval 'db.getCollection("sawtooth_precompute_state").updateOne({ _id: "checkpoint" }, { $set: { last_emitted_minute_epoch: Math.floor(Date.now()/1000/60)*60 - 3600, updated_at: new Date() } }, { upsert: true })'` (adjust for your shell and mongosh syntax), or (b) rely on cold start (`last_emitted_minute_epoch = 0`) and let the first run advance from 0 — for a bounded first run, prefer (a).
4. Enable cron: `* * * * * cd /path/to/cgm-remote-monitor && node bin/sawtooth-precompute.js >> logs/sawtooth-precompute.log 2>&1`. Ensure only one instance runs (§6.2).
5. Verify: after 2+ minutes, check log for `sawtooth-precompute pushed` with expected `minutes=` and pipeline counters; check Better Stack dashboard for source Trio Complication Recency and metric `complication_visible_recency_seconds`.

**Rollback**

1. Disable cron (comment out or remove crontab line). No code revert required to stop.
2. Dashboard will show gap from last checkpoint; no deletion of already-pushed metrics.
3. If reverting code: remove or comment cron; optional: remove `lib/sawtooth-precompute`, `bin/sawtooth-precompute.js`, and state file.

---

## 12. Risks / follow-ups

- **Empty GTL → permanent gap:** If query returns 0 rows due to API glitch or wrong filter, checkpoint advances and those minutes are lost. Mitigation: WARN in logs; operational runbook: check dashboard, reset checkpoint, re-run with emit_delay=0 and S3 union if gap older than hot tier (see design §4.8).
- **Heroku:** Ephemeral filesystem; **do not use file backend** for checkpoint on Heroku. Use **MongoDB backend** (set `SAWTOOTH_STATE_BACKEND=mongo` or rely on default when `MONGODB_URI` is set). Nightscout already configures `MONGODB_URI` on Heroku; the script uses the same URI and a dedicated collection (§3.1, §8.5). v1 is suitable for Heroku when using MongoDB for checkpoint.
- **Single writer:** Only one cron instance must run. **File backend:** Lock file (Phase 1.3) is **required** to prevent overlapping runs from corrupting the checkpoint. **MongoDB backend:** Single-writer is a deployment invariant (no lock file; ensure only one instance is configured).
- **Duplicate dt:** Do not rely on Better Stack overwriting duplicate dt; avoid re-sending same minute (checkpoint guarantees we don’t).
- **Post-push persistence failure (residual risk, v1):** If push to Better Stack succeeds but `saveState({ pushed_through_minute })` then fails, state still contains only `preparing_through_minute`. On next run, loadState() clears preparing and does not advance, so the same range is retried and **duplicate emission** for that minute range can occur. This is an accepted residual risk for v1: rare (requires persistence failure immediately after push), documented here. Design goal of avoiding dependence on duplicate-timestamp behavior is not fully achieved in this edge case.

---

## 13. Changelog and reviewer feedback

(Changelog is at the end of this document.)

**Reviewer feedback (2026-03):** ChatGPT and Claude reviewed the design and implementation plan. Their recommendations (path fix §5.2, single Query API contract §8.1, lock required for file backend, single response format, rollout split by backend, empty-GTL pseudocode comment, INGEST_HOST wording, design §1/§7/§4.9 updates) were incorporated in plan v1.4 and design v1.13. **No disagreements:** all recommended changes were adopted; nothing was explicitly declined or documented as out of scope.

---

## 14. Implementation log

A detailed record of what was built and what changed compared to this plan is kept in a separate file:

**→ [implementation-log.md](implementation-log.md)**

It covers: initial implementation (§14.1), review rounds 1–3 (F1–F8, two-phase state, file lock race / Mongo lease), post-review nits and README (§14.5), and the Node clock loop for Heroku (§14.6). Code lives in **cgm-remote-monitor**: `bin/sawtooth-precompute.js`, `bin/sawtooth-clock.js`, `lib/sawtooth-precompute/*.js`.

*(Detailed subsections 14.1–14.6 are in [implementation-log.md](implementation-log.md).)*

---

## Changelog

*Dates for v1.0–v1.9 are from document history; time of day was not evidenced (file was untracked; no git history). Timestamp for v1.10 is from file mtime at time of this edit.*

| Version | Date | Changes |
|---------|------|---------|
| 1.13 | 2026-03-20 21:58 CET | **Post-implementation updates:** §3 step 6, §5 Phase 3.2, §6 step 5 — off-wrist semantics: `charging` or `full` (not `unknown`; see design §4.2 v1.16). §5 Phase 2.1 — transient query retry (1 retry, 5 s delay). §7 — new env vars `SAWTOOTH_LAG_WINDOW_SECONDS`, `SAWTOOTH_LAG_BUFFER_SECONDS`; `SAWTOOTH_EMIT_DELAY_SECONDS` described as cold-start fallback. §9 — new log fields on `pushed` and `skip` lines (`effective_emit_delay`, `data_horizon_lag`, `lag_window_max`, `lag_obs`). Design reference updated to v1.16. |
| 1.12 | 2026-03-20 11:15 CET | **Logging aligned with shipped `run.js`:** §6.1 Phase 6, §9, pseudocode tail, rollout verify — single consolidated `pushed` line (`gtl_rows`, `parsed`, `deduped`, `skipped_no_anchor`, `minutes`, `end_minute`, anchor + emit-delay fields); removed `start` / separate `gtl_rows` success lines. **Design reference** filename corrected to `nightscout-precompute-design.md` (v1.15). |
| 1.11 | 2026-03-19 14:26 CET | §14 Implementation log: detailed subsections 14.1–14.6 extracted to [implementation-log.md](implementation-log.md); plan §14 now points to that file only. |
| 1.10 | 2026-03-17 10:53 CET | Changelog moved to end of document (per docs-version-and-changelog rule). Last updated set from file mtime. |
| 1.9 | 2026-03-16 | §14.6: Heroku scheduler replaced with Node clock loop (bin/sawtooth-clock.js): wall-clock-aligned, no overlap, SIGTERM handling; Procfile and README updated. |
| 1.8 | 2026-03-16 | §14.5: Implementation log — README Heroku worker instructions, Mongo lease wording, loop drift note, v1 limitations; entrypoint .env comment; acquireMongoLease redundancy removed. |
| 1.7 | 2026-03-16 | §12: Documented residual risk (post-push persistence failure → duplicate resend). §14.4: Review round 3 — file lock stale-reap race (mtime grace), Mongo lease findOneAndUpdate. |
| 1.6 | 2026-03-16 | §14 Implementation log added (initial implementation, review round 1, review round 2). Two-phase recovery state (preparing_through_minute vs pushed_through_minute), file lock held until close(), end_minute minute-aligned, Mongo lease 5 min. |
| 1.5 | 2026-03-16 | Red-team review (prompt workflow): §7.1 cold start wording backend-aware (file + Mongo); §8.6 push endpoint use BETTERSTACK_INGEST_HOST from env, not hardcoded host; §10 test plan cold start bullet covers both backends and references §11. Phase 3 regression: §6 inputs and §9 observability wording backend-aware (file or Mongo). Design reference v1.14. |
| 1.4 | 2026-03-16 | **ChatGPT/Claude feedback:** §5.2 entrypoint: fix require path to `../lib/sawtooth-precompute/run` (from bin/). §8.1: Single canonical Better Stack Query API contract (URL, headers, auth, response format); lock to one response format, no fallback parsers. §2.3: Parser yields { dt, message } from that format only; throw on parse error. Phase 1.3: File-backend lock **required** (not optional); MongoDB backend: single-writer is deployment invariant. §6.2: Cron does not guarantee serialization; require lock for file backend. §11 Rollout: Step 3 split by backend (file = write state file; Mongo = mongosh upsert or cold start). §6 pseudocode: comment that empty GTL skips pushGauges but checkpoint still advances per §4.8. §7: BETTERSTACK_INGEST_HOST — required, no default; current value in example only. §12: Single writer + lock requirement stated explicitly. Design reference v1.13. |
| 1.3 | 2026-03-16 | **MongoDB checkpoint in v1:** Checkpoint backend is file or MongoDB (chosen by env). When `MONGODB_URI` is set, use Nightscout's existing MongoDB and a dedicated collection for checkpoint (Heroku-safe). Added §3.1 Nightscout MongoDB usage (mongo-storage.js, env.storageURI, .collection(name)); §5 Phase 1 state.js tasks for Mongo backend; §7 env SAWTOOTH_STATE_BACKEND and SAWTOOTH_STATE_COLLECTION; §8.5 MongoDB checkpoint contract; §12 v1 suitable for Heroku when using Mongo. Removed Heroku/Mongo from out-of-scope. |
| 1.2 | 2026-03-16 | Phase 1 Pass 2: §3 step 2 emit ceiling add max(0, ...) for consistency with design §5 and plan §6. §8.1 SQL example note that for windows &gt; ~40 min use full S3 union per §2.2 and design §4.9. |
| 1.1 | 2026-03-16 | Red-team review: §2.2 and §3 step 4 — v1 GTL query must include S3 union when window &gt; ~40 min (hot tier holds ~30–40 min; 3h lookback requires union). §1 — Prometheus source must exist (create per design §6 if not present). §12 — v1 not suitable for Heroku (ephemeral filesystem); use persistent disk or MongoDB follow-up. Design reference updated to v1.11. |
| 1.0 | 2026-03-16 | Initial implementation plan: phases, file tree, env vars, data contracts, algorithm detail, test/rollout/rollback. Grounded in design doc and provided Better Stack source/query details. |

When updating this document, increment the version number and add an entry at the top of the changelog table above.
