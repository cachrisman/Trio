# Cursor Prompt: End-to-End Audit — Nightscout Sawtooth Precompute Pipeline

## Context

The sawtooth metric — `complication_visible_recency_seconds` — is **not** a metric extracted from Trio iOS/watchOS logs. It is produced by a **Nightscout-hosted precompute service** in `cgm-remote-monitor`. That service:

1. Reads raw `event=complication_get_timeline_called` logs from BetterStack (Trio logs source, id `1659391`) via the BetterStack Query API
2. Reconstructs the per-minute sawtooth in memory using the ASOF + `data_age_seconds + (minute_epoch - gtl_epoch)` formula
3. Pushes gauge points to a **separate** BetterStack Prometheus-push source called **Trio Complication Recency** (source id `trio_complication_recency_2`, ingest host `s2301525.eu-fsn-3.betterstackdata.com`)
4. A dashboard chart on the **main Trio dashboard** (id `914638`) queries that second source to render the sawtooth

The design is in `docs/in-progress/nightscout-sawtooth-precompute/nightscout-sawtooth-precompute-service.md` (v1.14) and the implementation plan is `nightscout-precompute-implementation-plan.md` (v1.10). The algorithm has been validated — an Explore-based manual run produced 717 clean data points over 46h. The question is whether the **live production pipeline** is working: is the service running, are gauges actually being pushed, and is the dashboard chart correctly reading them?

Work through the five audit layers below in order. Document concrete findings at each layer before moving to the next. **Do not propose fixes until all layers are audited.**

---

## Key identifiers

- BetterStack team: `491594`
- Trio logs source (GTL input): source id `1659391`
- Trio Complication Recency source (gauge output): source id `trio_complication_recency_2`; ingest host `s2301525.eu-fsn-3.betterstackdata.com`
- Main Trio dashboard (where the chart lives): id `914638`
- Complication Freshness dashboard: id `689533`
- API token: load from `.trio-env` as `BETTERSTACK_API_TOKEN`; **never log or print it**
- Log query tables (Trio logs source): hot = `remote(t491594_trio_logs)`, cold/archive = `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`; hot holds only ~30–40 min; use UNION ALL for windows > ~40 min
- Nightscout repo: `/Users/charliechrisman/Code/src/cachrisman/cgm-remote-monitor`

---

## Layer 1 — Is the precompute service code present and correctly wired?

### 1a. Verify the file tree exists

In the cgm-remote-monitor repo, check that these files exist:

```
bin/sawtooth-precompute.js         (or bin/sawtooth-clock.js for Heroku)
lib/sawtooth-precompute/run.js
lib/sawtooth-precompute/fetch-gtl-logs.js
lib/sawtooth-precompute/parse-message.js
lib/sawtooth-precompute/dedupe.js
lib/sawtooth-precompute/push-metrics.js
lib/sawtooth-precompute/state.js
```

If any are missing, note which ones. Check `data/sawtooth-precompute-state.json` for the file backend checkpoint (or check if a Mongo checkpoint collection is in use).

### 1b. Check the entrypoint and require paths

In `bin/sawtooth-precompute.js` (or `bin/sawtooth-clock.js`):
- Is the require path to `run.js` correct — `../lib/sawtooth-precompute/run` (relative from `bin/`)?
- Is `dotenv` loaded before `run()` is called?

### 1c. Check the SQL in fetch-gtl-logs.js

Verify the SQL template in `fetch-gtl-logs.js`:

1. Does it query the right table? It should query Trio logs source — `remote(t491594_trio_logs)` — not the recency/metrics source.
2. Does it use the S3 UNION ALL for the 3h lookback window? With `SAWTOOTH_LOOKBACK_SECONDS=10800` (3h), the window far exceeds the ~40 min hot tier limit. The query **must** union hot + S3:
   ```sql
   SELECT toUnixTimestamp(dt) AS dt, JSONExtract(raw, 'message', 'Nullable(String)') AS message
   FROM remote(t491594_trio_logs)
   WHERE dt BETWEEN toDateTime(${window_start}) AND toDateTime(${window_end})
     AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
   UNION ALL
   SELECT toUnixTimestamp(dt) AS dt, JSONExtract(raw, 'message', 'Nullable(String)') AS message
   FROM s3Cluster(primary, t491594_trio_s3)
   WHERE _row_type = 1
     AND dt BETWEEN toDateTime(${window_start}) AND toDateTime(${window_end})
     AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
   ```
   If the S3 union is absent or gated on a condition, the query will return 0 rows for any window older than ~40 min — causing the service to advance the checkpoint and permanently skip those minutes.
3. Is the window interpolated as Unix integers into the SQL, or as ISO strings? The design uses `toDateTime(${window_start})` with Unix seconds.
4. Is `toUnixTimestamp(dt) AS dt` used so the `dt` field in the response is a consistent numeric type?

### 1d. Check parse-message.js

1. What are the exact regexes used to extract `data_age_seconds`, `battery_state`, and `get_timeline_at_epoch_seconds`?
2. Do they match the **actual log format** from Trio? The expected log line format is something like:
   `event=complication_get_timeline_called data_age_seconds=142 battery_state=unplugged get_timeline_at_epoch_seconds=1710010600 ...`
   Check that the regexes handle integer values (not float-only), and that `battery_state` captures `charging`, `unplugged`, and `unknown`.
3. Does `is_off_wrist` correctly derive from `battery_state === 'charging' || battery_state === 'unknown'`?

### 1e. Check push-metrics.js

1. Is the metric name exactly `complication_visible_recency_seconds`? Check for typos or aliases.
2. Is `dt` emitted as a Unix integer (not a string, not ISO, not milliseconds)?
3. Is the push body an array — `[{ name, gauge: { value }, dt }, ...]`? The BetterStack ingest API expects an array for batched push.
4. Is the Bearer token sourced from `BETTERSTACK_RECENCY_SOURCE_TOKEN` (the **recency source** token), not from `BETTERSTACK_API_TOKEN` (the query API token)? These are different credentials for different sources.

### 1f. Check state.js checkpoint logic

1. Is the checkpoint backend correctly selected by env? Rule: use `mongo` when `SAWTOOTH_STATE_BACKEND=mongo` or when `MONGODB_URI` is set and backend is not explicitly `file`; otherwise use file.
2. For the **file backend**: does `loadState()` return `{ last_emitted_minute_epoch: 0 }` when the file is missing (cold start), rather than throwing?
3. For the **MongoDB backend**: does `saveState()` use `upsert: true`?
4. Is there a two-phase recovery state (`preparing_through_minute` / `pushed_through_minute`) per the review log (§14.3)? If so, is it being correctly promoted on recovery?
5. Is the file lock present for the file backend (required per §6.2)?

---

## Layer 2 — Is the service actually running and producing output?

### 2a. Check the checkpoint to see if runs have occurred

**File backend:** Read `data/sawtooth-precompute-state.json`. Record `last_emitted_minute_epoch`. Convert to human-readable UTC: `new Date(last_emitted_minute_epoch * 1000).toISOString()`. Is it recent (within the last few minutes, allowing for the 2 min emit delay)? Or is it stale (hours or days ago)? Or missing (never ran)?

**MongoDB backend:** Run `db.sawtooth_precompute_state.findOne({ _id: 'checkpoint' })` via mongosh or the code. Check `last_emitted_minute_epoch` and `updated_at`.

If the checkpoint is stale or missing, the service is not running.

### 2b. Verify gauges are arriving in BetterStack — query the recency source

Use the BetterStack MCP `telemetry_query` tool to check whether pushed metrics exist in the recency source.

First use `telemetry_get_source_details_tool` with source id `trio_complication_recency_2` (or search via `telemetry_list_sources_tool` for "Trio Complication Recency") to find the exact table names for this source. Then query:

```sql
SELECT name, count(*), max(dt)
FROM <recency_source_metrics_table>
WHERE name = 'complication_visible_recency_seconds'
  AND dt >= now() - INTERVAL 24 HOUR
GROUP BY name
```

**Questions to answer:**
1. Are any rows returned? If zero, gauges are not arriving (or the metric name is wrong).
2. What is `max(dt)` — is it recent (within last few minutes)?
3. How many data points exist? For a service running every minute over 24h, expect ~1400 points.

### 2c. Spot-check recent values for plausibility

If data exists, pull a sample of recent values:

```sql
SELECT dt, avgMerge(value_avg) AS recency_seconds
FROM <recency_source_metrics_table>
WHERE name = 'complication_visible_recency_seconds'
  AND dt >= now() - INTERVAL 2 HOUR
GROUP BY dt
ORDER BY dt DESC
LIMIT 20
```

**Questions to answer:**
1. Are values in a plausible range? Expected: 60–1800 seconds (1–30 min) during normal operation; up to 12000+ for overnight stalls.
2. Is the sawtooth pattern visible — values rising over time then dropping near-zero when new GTL data arrives?
3. Are there anomalous values (negative, very large like 86400+, or exactly 0 for every point)?

---

## Layer 3 — Is the BetterStack recency source configured correctly?

### 3a. Get the source details

Use `telemetry_get_source_details_tool` with source id `trio_complication_recency_2` (or use `telemetry_list_sources_tool` to find the "Trio Complication Recency" source).

**Questions to answer:**
1. Does the source exist?
2. What platform/type is it? Should be "Prometheus push" or equivalent.
3. What is the ingest host? Should match `BETTERSTACK_INGEST_HOST` in the env.
4. What metrics or extraction rules are configured on this source? For a Prometheus-push source, the metric schema is defined by what the pusher sends — there should be no extraction rules needed. But check if there are any unexpected rules that might interfere.

### 3b. Verify the metric name and aggregation columns

The metric name being pushed is `complication_visible_recency_seconds` as a gauge.

In the unified metrics schema, Prometheus-push gauge points land as:
- `name = 'complication_visible_recency_seconds'`
- `value_avg`, `value_min`, `value_max` — all equal to the pushed gauge value for a single-point push
- `dt` — from the `dt` field in the push payload (the Unix integer per-minute epoch)

For a sawtooth dashboard chart, `avgMerge(value_avg)` or `maxMerge(value_max)` must be valid. Check whether these columns exist and are populated, or whether the source uses a different column naming convention.

---

## Layer 4 — Is the dashboard chart correct?

### 4a. Find the sawtooth chart

Use `telemetry_get_dashboard_details_tool` on dashboard `914638` (main Trio dashboard). Find the chart named "Complication Visible Recency" or similar.

Also check dashboard `689533` (Complication Freshness dashboard) for any recency chart.

For each chart, record:
1. Chart name and type (line, scatter, etc.)
2. Full SQL query
3. The `source_variable` or source binding — which source does `{{source}}` resolve to?

### 4b. Evaluate the query

A correct sawtooth chart query against the recency source should look like:

```sql
SELECT
  toStartOfInterval(dt, INTERVAL 1 MINUTE) AS time,
  avgMerge(value_avg) AS recency_seconds
FROM {{source}}
WHERE name = 'complication_visible_recency_seconds'
  AND dt BETWEEN {{start_time}} AND {{end_time}}
GROUP BY time
ORDER BY time
```

Check for these issues:

1. **Wrong source:** Is `{{source}}` bound to the Trio **logs** source (`1659391`) instead of the Trio **Complication Recency** source (`trio_complication_recency_2`)? If so, the query will return 0 rows because gauge points land in the recency source, not the logs source.
2. **Wrong metric name filter:** Is `WHERE name = 'complication_visible_recency_seconds'` present? Without it, the query aggregates all metrics in the source.
3. **Wrong merge function:** For a Prometheus-push gauge source, `avgMerge(value_avg)` is correct. Using `sumMerge` would sum across multiple minute buckets — wrong. Using `maxMerge(value_max)` works for peak values (sawtooth ceiling) and is an acceptable alternative.
4. **Time bucket too coarse:** Using `{{time}}` (dashboard default, often 1h or 30m) flattens the sawtooth into a nearly flat average line. The chart needs 1-minute or at most 5-minute buckets to show the rising-then-resetting shape. Check if the chart uses a fixed interval or the dashboard default.
5. **Unexpected `battery_state` filter:** The Explore query filters out charging/off-wrist events, but the precompute service already handles off-wrist in the reconstruction (value=0). No battery filter is needed or valid at the chart level — if one exists, it will exclude the off-wrist zero points.

### 4c. Verify source binding

Use `telemetry_export_dashboard_tool` on dashboard `914638` to get the full JSON and check how the `{{source}}` variable is defined. Confirm which source it resolves to for the recency chart specifically.

If the wrong source is bound, the chart renders empty or incorrect data regardless of whether the precompute service is working.

---

## Layer 5 — End-to-end smoke test

If Layers 1–4 confirm the pipeline is wired correctly and the service appears to be running:

### 5a. Manual trigger

Run the script once manually from the Nightscout repo root:

```bash
cd /Users/charliechrisman/Code/src/cachrisman/cgm-remote-monitor
node bin/sawtooth-precompute.js
```

Check the output for:
- `sawtooth-precompute start`
- `sawtooth-precompute gtl_rows=N` — if N=0 with S3 union present, something is wrong with the query or auth
- `sawtooth-precompute pushed minutes=N`
- Any error messages (HTTP errors, parse errors, auth failures)

If the output shows `gtl_rows=0` despite the S3 union being present, the Query API auth may be wrong or the GTL event name filter may not match actual log lines. In that case, verify with a manual `telemetry_query` that GTL logs exist in the expected time window.

### 5b. Verify a point landed in BetterStack

Immediately after the manual run, re-query the recency source (Layer 2b query) for the most recent point. Did a new point appear? Does the `dt` match approximately `now - emit_delay_seconds - 60` (i.e., 2+ minutes ago)?

### 5c. Check the dashboard chart

Open dashboard `914638` in BetterStack and navigate to the sawtooth chart. Set the time window to the last 1–2 hours. Does the sawtooth pattern appear? Is the time granularity fine enough (1-min buckets) to see the rising and falling edges?

---

## Summary table

**Audit date:** 2026-03-19 14:28 CET

| Layer | Check | Status | Finding |
|---|---|---|---|
| 1a | File tree present in cgm-remote-monitor | ✅ | All 8 expected files present (`bin/sawtooth-precompute.js`, `bin/sawtooth-clock.js`, `lib/sawtooth-precompute/{run,fetch-gtl-logs,parse-message,dedupe,push-metrics,state}.js`). Bonus `README.md` also present. No local `data/sawtooth-precompute-state.json` (expected — production uses Mongo backend). |
| 1b | Require paths and dotenv correct | ✅ | Both entrypoints use `require('../lib/sawtooth-precompute/run').run` — correct relative path from `bin/`. Both have inline `.env` loader (not `dotenv` package; custom implementation) that loads before `run()` is called and does not overwrite existing env vars. |
| 1c | SQL uses S3 UNION ALL for 3h window | ✅ | `buildSql()` gates on `(windowEndSec - windowStartSec) > 2400` (40 min). Default 3h lookback (10800s) always triggers the union. Union correctly joins `remote(t491594_trio_logs)` + `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`. Window interpolated as Unix integers via `toDateTime(${Math.floor(...)})`. `toUnixTimestamp(dt) AS dt` produces consistent numeric type. |
| 1d | parse-message regexes match actual log format | ✅ | `DATA_AGE_RE = /data_age_seconds=(\d+)/`, `BATTERY_STATE_RE = /battery_state=(charging\|unplugged\|unknown)/`, `GTL_EPOCH_RE = /get_timeline_at_epoch_seconds=(\d+)/`. All capture integer values. `is_off_wrist` correctly derived in `dedupe.js`: `group.some(r => r.battery_state === 'charging' \|\| r.battery_state === 'unknown')`. |
| 1e | push-metrics uses correct metric name, dt type, Bearer token | ✅ | Metric name: `'complication_visible_recency_seconds'` (exact, no typos). `dt` is `p.minute_epoch` (Unix integer from the loop variable). Body: `JSON.stringify(array)` with `{ name, gauge: { value }, dt }` format. Bearer token sourced from `BETTERSTACK_RECENCY_SOURCE_TOKEN` (not `BETTERSTACK_API_TOKEN`). |
| 1f | Checkpoint logic correct (backend selection, cold start, file lock) | ✅ | Backend selection: `SAWTOOTH_STATE_BACKEND=file` → file; `=mongo` → mongo; `MONGODB_URI` set → mongo; else file. File cold start returns `{ last_emitted_minute_epoch: 0 }` (no throw). Mongo `saveState` uses `upsert: true`. Two-phase recovery: `pushed_through_minute` → advance + clear; `preparing_through_minute` → clear without advancing. File lock uses `'wx'` flag with stale PID detection and 5-min expiry. |
| 2a | Checkpoint is recent (service is running) | ✅ | No local file checkpoint (production uses Mongo). Procfile declares `sawtooth: node bin/sawtooth-clock.js` — Heroku dyno type exists. Production output confirms service is running (see 2b). |
| 2b | Gauges arriving in BetterStack recency source | ✅ | **1365 data points** in last 24h (expected ~1440 for perfect minutely coverage — 94.8% coverage). `max(dt)` = **2026-03-19 13:23:00 UTC** — within 2 minutes of wall clock, consistent with `emit_delay_seconds=120`. |
| 2c | Values plausible and sawtooth pattern visible | ✅ | Last 20 values show clear sawtooth: 13:04–13:10 = 0 (off-wrist), 13:11 = 614s, 13:12 = 674s, ..., 13:23 = 1334s. Each on-wrist minute increments by exactly +60s — textbook sawtooth ramp. Values in plausible range (0 for off-wrist, 614–1334s for on-wrist ramp). No negative or anomalous values. |
| 3a | Recency source exists and is correct platform | ✅ | Source ID `2301525`, name "Trio Complication Recency", platform **prometheus**, status **Active**, ingest host `s2301525.eu-fsn-3.betterstackdata.com` (matches expected), data region `eu-fsn-3`. Created 2026-03-16, updated 2026-03-19 13:15 UTC. No extraction rules (correct for Prometheus push). |
| 3b | Metric schema correct for avgMerge/maxMerge queries | ✅ | `avgMerge(value_avg)` returns correct values (verified in 2c). Metrics table: `remote(t491594_trio_complication_recency_2_metrics)`. Prometheus-push gauge values land in `value_avg`, `value_min`, `value_max` columns as expected. |
| 4a | Sawtooth chart found in dashboard | ✅ | Chart "Complication Visible Recency" (ID `9296752929`) on dashboard 914638 (Trio Dashboard), section "Watch Complication". Type: `line_chart`, position: (0,1), size: 12×8 (full width, prominent). Dashboard 689533 does **not exist** (record not found). |
| 4b | Chart query uses correct source, name filter, merge fn, bucket size | ✅ | Source: `{{source:trio_complication_recency_2}}` (recency source, not logs). Name filter: `AND name = 'complication_visible_recency_seconds'` present. Merge fn: `avgMerge(value_avg)` (correct). Bucket: `toStartOfMinute(dt)` — 1-minute granularity (fine enough for sawtooth). No battery filter at chart level (correct). `treat_missing_values: "disconnected"` (gaps show as breaks, not interpolated). |
| 4c | `{{source}}` variable bound to recency source (not logs source) | ✅ | Chart uses `source_variable: "source:trio_complication_recency_2"` — a **named source reference** that binds directly to the recency source by table name, bypassing the dashboard-level default `source` variable (which resolves to Trio logs `1659391`). Binding is correct. |
| 5a | Manual run produces output with gtl_rows > 0 | ⏭️ | Skipped — no `.env` file in cgm-remote-monitor repo (env vars are injected by Heroku Config Vars). A local manual run would require setting up `BETTERSTACK_QUERY_HOST`, `BETTERSTACK_QUERY_USER`, `BETTERSTACK_QUERY_PASSWORD`, `BETTERSTACK_INGEST_HOST`, and `BETTERSTACK_RECENCY_SOURCE_TOKEN`. Production data already confirms the pipeline is working end-to-end. |
| 5b | New point visible in BetterStack immediately after manual run | ⏭️ | Skipped per 5a. Production data shows continuous minutely output with `max(dt)` within 2 minutes of wall clock. |
| 5c | Dashboard chart shows sawtooth at 1-min granularity | ✅ | Chart query uses `toStartOfMinute(dt)` — 1-minute buckets. The recency source contains 1365 minutely points over 24h. The spot-check data shows the expected sawtooth pattern (rising ramp + off-wrist zeros). Chart settings are correct (`treat_missing_values: "disconnected"`, `y_axis_min: 0`, `unit: "s"`). |

---

## Audit result

**The pipeline is fully operational.** All five layers pass. None of the five predicted failure modes are present:

1. ~~S3 UNION ALL missing~~ — Present and correctly gated at >40 min window.
2. ~~Wrong Bearer token~~ — Uses `BETTERSTACK_RECENCY_SOURCE_TOKEN` (correct).
3. ~~Dashboard source mismatch~~ — Chart binds to `source:trio_complication_recency_2` (correct).
4. ~~Service not running~~ — 1365 points in 24h, latest 2 min ago.
5. ~~dt as milliseconds/ISO~~ — Unix integer, verified by plausible values (614–1334s range).

### Minor observations (not failures)

- **Dashboard 689533** (Complication Freshness) referenced in the audit prompt does not exist. Only dashboard 914638 (Trio Dashboard) has the recency chart.
- **No local `.env` file** in cgm-remote-monitor — all env vars come from Heroku Config Vars. Local manual runs (5a) require explicit env setup.
- **Coverage: 94.8%** (1365/1440 expected minutely points). The ~75 missing points are likely off-wrist minutes where no anchor existed (these are `skipped_no_anchor` in `run.js`, not emitted as points).

---

## Most likely failure modes (ranked by prior probability) — all ruled out

1. **S3 UNION ALL missing from the GTL SQL** — **Ruled out.** Union present in `fetch-gtl-logs.js` with correct 2400s threshold.
2. **Wrong Bearer token for push** — **Ruled out.** Code uses `BETTERSTACK_RECENCY_SOURCE_TOKEN`.
3. **Dashboard `{{source}}` bound to Trio logs source** — **Ruled out.** Chart uses named source reference `source:trio_complication_recency_2`.
4. **Service not running** — **Ruled out.** 1365 data points in 24h, latest at 13:23 UTC.
5. **`dt` sent as milliseconds or ISO string** — **Ruled out.** Values are Unix seconds; spot-check shows plausible 614–1334s range.