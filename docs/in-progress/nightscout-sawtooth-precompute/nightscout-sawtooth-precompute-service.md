# Nightscout-side precompute service for Trio complication visible recency (sawtooth)

**Version:** 1.14  
**Status:** Design — implementation-ready; Better Stack ingest and dashboard query validated (§6.1)  
**Last updated:** 2026-03-16

## Changelog

Newest-first. When updating this document, increment the version number and add a row at the top of this table. **Reviewer feedback (2026-03):** ChatGPT/Claude feedback incorporated in v1.13; no disagreements documented.

| Version | Date | Changes |
|---------|------|---------|
| 1.14 | 2026-03-16 | Red-team review (prompt workflow): §11 fetch-gtl-logs row — clarify fetch returns `{ dt, message }`, parse/dedupe produce GTL shape (align with implementation plan module boundaries). |
| 1.13 | 2026-03-16 | **ChatGPT/Claude feedback:** §1 Verdict — v1 recommendation = cron + standalone + checkpoint file **or** MongoDB (by env), not "local checkpoint file" only; in-process noted as conceptually possible but not v1 target. §4.9: Inline comment in SQL sketch that for lookback &gt; ~40 min use full S3 union. §7: Headline v1 = standalone cron; checkpoint backend = file (persistent disk) or MongoDB (Heroku/ephemeral). Changelog reordered newest-first. |
| 1.12 | 2026-03-16 | §9, §11: v1 checkpoint is **file or MongoDB** (chosen by env). When `MONGODB_URI` is set (e.g. Heroku), use Nightscout's existing DB and a dedicated collection; implementation plan §3.1, §8.5. |
| 1.11 | 2026-03-16 | Red-team review: §4.1 hot-tier retention corrected — hot holds ~30–40 min only; require S3 union when lookback &gt; ~40 min (e.g. 3h). §4.1 window_end clarified as wall-clock seconds (not floored). §4.9 SQL sketch: add toUnixTimestamp(dt) AS dt for consistent dedupe key type; Tables bullet requires S3 union for windows beyond hot tier. §6 action items: allow "or use existing" Prometheus source (e.g. Trio Complication Recency). |
| 1.10 | 2026-03-16 | §4.9: Explicit note that sketch returns only dt and message; application parses data_age_seconds, battery_state, get_timeline_at_epoch_seconds from message (regex/string split). §5 step 2: window_end = wall-clock time (not floored). §10 pseudocode: wall_now = now() for window_end; now_epoch floored only for end_minute. |
| 1.9 | 2026-03-16 | **Claude review incorporated.** §4.8: Operational note and manual recovery procedure for 0-row GTL (permanent gap risk; check dashboard; reset checkpoint, emit_delay=0, S3 for old gaps). §4.9 (new): Reference GTL query template for Node script (tables, filter, columns, time bound; example SQL sketch). §4.1: Invariant wording (window_start ≤ from_minute - lookback). §6: Runtime GTL query auth (Query API v2, BETTERSTACK_QUERY_HOST/USER/PASSWORD). §7: Pin env vars for GTL query. §8: Single writer — multi-dyno in-process unsafe; file lock for cron. §9: Checkpoint on Heroku → MongoDB (ephemeral filesystem). §5 step 3: Reference §4.9; step 5: dt = Unix integer. §6.1: Large backfill batch note. §11: fetch-gtl-logs §4.9, state/push-metrics dt and Mongo. |
| 1.8 | 2026-03-16 | **Better Stack open item resolved.** §6.1 (new): Validated ingest (POST $INGESTING_HOST/metrics, dt override, historical timestamps, batch), unified schema (value_avg/value_min/value_max, filter by name), dashboard query (avgMerge(value_avg), WHERE name = 'complication_visible_recency_seconds'). §6 table: Push URL and Dashboard row updated; action items revised. §1: Verdict set to implementation-ready; open item (4) closed. §9 and §13: Dashboard and references updated. |
| 1.7 | 2026-03-16 | Review workflow pass: §1 open items — (1)–(3) marked as specified in doc, (4) remains (Better Stack gauge query validation). §4.1 purpose: emit ceiling wording. §5 step 1 and §10 pseudocode: floor end_minute_epoch at 0. §11 dedupe.js: gtl_epoch in output. |
| 1.6 | 2026-03-16 | **ChatGPT feedback incorporated:** Verdict reworded to "viable, well-structured, not yet implementation-ready" with four open items. §4.2: explicit dedupe key (dt), gtl_epoch from parsed get_timeline_at_epoch_seconds, tie-break when grouped rows disagree (max(gtl_epoch) + log warning). §4.5: emit delay made concrete — emit ceiling = last complete minute minus emit_delay_seconds; §5 and §10 updated. §4.8 (new): empty GTL result handling — query failed vs succeeded 0 rows; plausible vs suspicious; v1 recommendation (advance with WARN). §5: emit_delay_seconds input; step 1 emit ceiling; step 3 query failure → do not advance; gtl_epoch tie-break. §6: dashboard query reclassified as open validation item. §7: v1 recommendation (cron, standalone, local checkpoint, explicit env). §8–§9: delayed-ingestion and GTL duplicates rows updated; architecture v1 preference. Pseudocode: emit_delay, end_minute with delay, query-failure early return, empty-GTL WARN. |
| 1.5 | 2026-03-16 | Step 4 cross-reference to §8; empty-GTL-list checkpoint behavior (advance to avoid infinite retry). |
| 1.4 | 2026-03-16 | Algorithm step 2 and pseudocode: window_start = max(0, ...); §4.6 batching note; observability (count of minutes pushed, push response); stop/rollback risk. |
| 1.3 | 2026-03-16 | Review pass: filter GTL list to match Explore (is_off_wrist OR data_age_seconds non-null); cold start guidance; atomic checkpoint (no partial advance on push failure); single-writer risk; dedupe tie-break (argMax); window_end and window_start clarity; Prometheus ingest URL note. |
| 1.2 | 2026-03-16 | Moved from `docs/in-progress/complication-freshness/` to `docs/in-progress/nightscout-sawtooth-precompute/`. |
| 1.1 | 2026-03-16 | Clarified Better Stack read-only SQL API (REST, basic auth) for Node job; removed query-API blocker; added References link. |
| 1.0 | 2026-03-16 | Initial design: verdict, architecture, query/state model, algorithm, Better Stack requirements, Nightscout placement, risks, implementation options. |

---

## 1. Verdict

**Viable and implementation-ready** provided the job is implemented as specified. A Nightscout-hosted job that queries Better Stack for recent GTL raw logs, reconstructs the per-minute sawtooth in memory, and pushes gauge points to Better Stack is **architecturally sound** and the Better Stack ingest/dashboard path is **validated** (see §6.1).

1. **Better Stack:** (a) Raw GTL logs are queryable via an API that accepts ClickHouse SQL (or equivalent) with time bounds — **confirmed** via MCP `telemetry_query` and cloud connection; (b) A **separate Prometheus source** is used for metrics ingestion — **push API** (POST `https://$INGESTING_HOST/metrics`, gauge + `dt` override); (c) Pushed metrics support a `dt` (timestamp) override, including **historical** timestamps for backfill — **confirmed**; (d) Dashboard query shape for pushed gauges — **validated** (§6.1): filter by `name`, use `avgMerge(value_avg)` (or value_max/value_min), same unified schema as Prometheus-like metrics.
2. **Nightscout:** The service runs as a **standalone Node script** invoked by **system cron** (v1 target) or, conceptually, a scheduled task in-process (not the v1 target). For **v1 the document recommends**: cron, standalone script in `bin/`, **checkpoint backend = file on persistent disk or MongoDB on Heroku/ephemeral** (chosen by env; §9), explicit env vars — to keep blast radius down and rollback easy (§7).
3. **Correctness:** The job must use a **recent-window + checkpoint** design, not "latest 2 GTLs," and must implement the **emit delay** and **empty-result** handling described in this doc.

**Open items:** None. Previously open items (1)–(4) are specified or validated: emit delay (§5), empty-result handling (§4.8), gtl_epoch tie-break (§4.2, §5), Better Stack gauge query (§6.1).

---

## 2. Ground truth: Explore sawtooth semantics

The canonical definition is the **Better Stack Explore** query in `docs/completed/betterstack/betterstack-complication-dashboard-setup.md` (section "Complication Visible Recency (Sawtooth) — Explore only"). Summary:

- **Input:** Raw log rows with `event=complication_get_timeline_called`, `data_age_seconds=N`, and `battery_state=charging|unplugged|unknown`.
- **Off-wrist:** `battery_state=charging` OR `battery_state=unknown` → treat as off-wrist; value for that GTL epoch is **0** (sentinel `-1` in the query, then `CASE WHEN matched_data_age = -1 THEN 0`).
- **Deduplication:** Each logical GTL is logged **twice**. The query uses `GROUP BY dt` and, per group: `max(is_off_wrist)`; `argMaxIf(logged_data_age, ..., NOT is_off_wrist)` so one row per distinct `dt`.
- **Per-minute value:** For minute bucket with epoch `bucket_epoch`, find the **most recent** GTL with `gtl_epoch <= bucket_epoch` (ASOF). Then  
  `value = data_age_seconds + (bucket_epoch - gtl_epoch)`  
  (or 0 if that GTL was off-wrist).
- **Lookback:** GTL rows are fetched from `{{start_time}} - 3 HOUR` to `{{end_time}}` so the bucket grid always has an anchor GTL for the first minute of the window.

The precompute service must reproduce this logic so the dashboard series matches Explore.

---

## 3. Why "latest 2 GTLs" is insufficient

- **Long tooth:** If the last getTimeline was 30 minutes ago, the "anchor" GTL for the last completed minute is that same GTL. You need that row; the "second" GTL might be from the previous day. So the window must extend backward at least to the anchor for the **oldest minute we intend to emit** (e.g. last completed minute).
- **Late-arriving logs:** Logs can land in Better Stack minutes after the event. If we only keep "latest 2," we might have already emitted a minute using an older anchor; when the true GTL arrives, we cannot correct the already-pushed point (no upsert of historical metrics in the docs). So we need to **re-query** a window that includes the minute we are about to emit and enough lookback to find the correct anchor; we cannot rely on a tiny in-memory tail of GTLs.
- **Off-wrist span:** A charging period is bounded by an off-wrist GTL at start and an on-wrist GTL at end (or vice versa). Representing zero for those minutes requires seeing both; two GTLs might be two on-wrist events with a gap of charging in between that we never see.
- **Idempotency:** If the job runs twice for the same minute (e.g. retry, or cron drift), we must emit the **same** value. That requires deterministic computation from the **same** input window. "Latest 2" is underspecified (which two? by `dt` or by ingestion order?) and does not guarantee repeatability when new logs arrive.

So the design must use a **time-bounded query** (e.g. GTLs from `window_start` to `window_end`) and a **checkpoint** (last emitted minute) so each run knows which minute(s) to compute and which anchor set to fetch.

---

## 4. Minimum robust query / state model

### 4.1 Query window

- **Purpose:** Fetch all GTL rows needed to compute the sawtooth for a contiguous set of minutes (from `last_emitted_minute_epoch + 60` through the **emit ceiling**: last complete minute minus `emit_delay_seconds`).
- **Window:** `[window_start_epoch, window_end_epoch]` in UTC. Recommended:  
  `window_start = max(0, last_emitted_minute_epoch - lookback_seconds)` (floor at 0 or a fixed history limit to avoid negative start).  
  `window_end` = current wall-clock time in seconds (**not** floored), so GTLs that have just landed in the current partial minute are included.  
  **Lookback:** At least 3 hours (match Explore). The invariant: **window_start must be at most `from_minute - lookback_seconds`** (where `from_minute = last_emitted_minute_epoch + 60`) so the ASOF lookup for the first emitted minute can find an anchor GTL. The formula above achieves this. Larger lookback (e.g. 6 h) improves safety for delayed ingestion at the cost of more rows.
- **Source of GTL data:** Better Stack Trio **logs** (hot + S3). The **hot tier** `remote(t491594_trio_logs)` holds only the **last ~30–40 minutes** of data (see AGENTS.md). For any window whose `window_start` is older than that, the query **must** include the S3 union (`UNION ALL` with `s3Cluster(primary, t491594_trio_s3)` and same time bounds) or most of the window will return no rows and the sawtooth will be wrong or empty. The precompute job must use the S3 union whenever lookback &gt; ~40 minutes (e.g. 3 h lookback). For backfill or delayed logs, the query must include S3.

### 4.2 Deduplication

- **Dedupe key:** Group log rows by **`dt`** (log timestamp) only. This matches Explore’s `GROUP BY dt`.
- **Per-group fields:** For each group:  
  `is_off_wrist = max(charging OR unknown)`;  
  `data_age_seconds = argMaxIf(extracted_data_age, extracted_data_age, NOT is_off_wrist)` (or leave null if all off-wrist).  
  **`gtl_epoch`** for the deduped row is taken from the parsed **`get_timeline_at_epoch_seconds`** (or equivalent) in the log message. If the Explore query uses `toUnixTimestamp(dt)` then `dt` and the parsed epoch should align; if the log also contains an explicit epoch field, use that for ASOF so computation matches the intended event time.
- **Tie-break when grouped rows disagree on `gtl_epoch`:** If rows in the same `dt` group have different parsed `get_timeline_at_epoch_seconds` values (e.g. corruption or multi-source), use a defined tie-break: **take `max(gtl_epoch)`** for that group and **log a warning**, or drop the group and log. Do not leave the tie-break implicit.
- **Filter to match Explore:** After dedupe, keep only rows where `is_off_wrist === true` OR `data_age_seconds != null`. The Explore query’s `gtl_with_age` CTE keeps exactly those (`WHERE is_off_wrist = 1 OR logged_data_age IS NOT NULL`). On-wrist rows with null data_age must not be used as anchors.

### 4.3 Off-wrist zero periods

- **Representation:** For any minute whose anchor GTL has `is_off_wrist = true`, emit **0**. Do not interpolate across off-wrist GTLs (the Explore query does not; it forces 0 for the whole span until the next on-wrist GTL).
- **Edge:** Consecutive off-wrist GTLs: each minute in between uses the most recent GTL (off-wrist), so value stays 0. No extra logic beyond "anchor's is_off_wrist → 0."

### 4.4 Cold start

- When `last_emitted_minute_epoch` is 0 (or unset), `from_minute` would be 60 (1970-01-01 00:01 UTC), so the first run could attempt to emit a huge number of minutes. **Initialize state** before the first production run: set `last_emitted_minute_epoch` to e.g. `now_epoch - 3600` (one hour ago) so the first run only fills a bounded window, or to the oldest minute you intend to backfill for a one-time backfill.

### 4.5 Missed runs / delayed ingestion / backfill

- **Missed run:** If the job doesn’t run at T+1 min (e.g. cron skip, process down), the next run should still have `last_emitted_minute_epoch` in state. Query window spans from that checkpoint minus lookback to "now." Compute **all** minutes from `last_emitted_minute_epoch + 60` through the **emit ceiling** (see below) and emit them in order. No special "catch-up" beyond emitting multiple points in one run.
- **Delayed ingestion and emit delay:** A GTL that occurred at 10:00 may land in Better Stack at 10:05. If we already emitted 10:00–10:04 using an older anchor, those points are wrong and **cannot be corrected**. The mitigation must be **concrete in the algorithm**: do **not** emit through "last complete minute"; instead emit only through **last complete minute minus an emit delay** (e.g. 120 or 180 seconds). So the **emit ceiling** is `end_minute_epoch = floor(now_epoch / 60) * 60 - 60 - emit_delay_seconds` (with `emit_delay_seconds` configurable, e.g. 120). That way minute M is emitted only after M + (delay/60) minutes have passed, giving late-arriving logs time to land. The algorithm in §5 and the pseudocode in §10 use this ceiling.
- **Backfill:** For a one-time backfill of historical days, run the job (or a batch script) with a synthetic "now" and "last_emitted" so the window covers the desired range; query S3 for that range and emit one gauge per minute. For backfill, `emit_delay_seconds` can be 0 so all minutes in the range are filled.

### 4.6 Idempotency and partial failure

- **Partial failure:** If some gauge POSTs succeed and a later one fails, do **not** advance the checkpoint. Emit and checkpoint atomically: only set `last_emitted_minute_epoch = to_minute` after **all** minutes in the batch have been pushed successfully. On any push failure, leave checkpoint unchanged; the next run will retry the same range (re-sending the same minute with the same value is idempotent only if the API overwrites; see §6). **Batching:** If the ingest API accepts multiple events per request, prefer sending all gauge points in one POST so that a single failure does not leave a partial batch.

### 4.7 Idempotency

- **Goal:** Emitting the same point twice (same minute, same value) should be safe. Emitting the same minute with a **different** value (e.g. first run without late GTL, second run with) causes **duplicate points** for that timestamp (if the API allows multiple events with same `dt`), or undefined behavior. Better Stack docs do not specify whether duplicate `dt` + name overwrite or append.
- **Strategy:** (1) **Checkpoint:** Persist `last_emitted_minute_epoch` only after the **entire** batch for this run has been pushed (see §4.6). (2) **Only emit minutes after checkpoint:** Compute minutes in `(last_emitted_minute_epoch, end_minute_epoch]` where `end_minute_epoch` is the emit ceiling (§4.5). Never re-emit `last_emitted_minute_epoch` unless doing an explicit backfill. (3) **Determinism:** For a given window of GTL rows, the ASOF logic is deterministic, so the same window → same values. If we re-run with a **larger** window (e.g. because new logs arrived), the value for an already-emitted minute might differ; we do **not** re-emit it (idempotency by checkpoint). So we accept that the series can be temporarily inconsistent with Explore until the next "tooth" refresh.

### 4.8 Empty GTL result handling

- **Do not treat all "empty" results the same.** Advancing the checkpoint when the query returns zero GTL rows avoids infinite retry but can turn transient failures or misconfiguration into **permanent dashboard gaps**. Define behavior as follows:
  - **Query failed** (HTTP error, parse error, timeout): **Do not advance** the checkpoint. Log the error; next run retries the same range.
  - **Query succeeded, zero rows returned:** Distinguish:
    - **Plausible empty:** The window is such that zero GTLs is reasonable (e.g. watch was off for hours; or this is a backfill for a period with no activity). **Option A:** Advance the checkpoint and **log at WARN** so operators see it. **Option B:** Advance only if the window is entirely in the past by more than some threshold (e.g. window_end &lt; now - 1 hour) so that "empty" is unlikely to be a transient ingestion lag.
    - **Suspicious empty:** The same or an overlapping window recently had GTL rows (e.g. previous run saw GTLs in the last lookback). **Do not advance** yet; log at WARN and retry next run. Implementing this requires retaining a small amount of prior run state (e.g. "last run had N GTLs in window") or heuristics.
- **Recommendation for v1:** Query failed → do not advance. Query succeeded with 0 rows → advance checkpoint to avoid infinite retry, but **log at WARN** and document that a transient query that returned empty (e.g. misconfigured time bound, temporary Better Stack issue) could create a permanent gap. A future improvement is to skip advancing when 0 rows is suspicious relative to recent history.

- **Operational note — 0 rows can cause permanent gaps:** If the SQL API returns HTTP 200 with 0 rows due to a transient incident (e.g. malformed response parsed as empty), a wrong filter after a log format change, or a temporary Better Stack issue, the job will advance the checkpoint and those minutes become a **permanent dashboard gap**. As soon as you see a WARN for 0 rows, check the dashboard and verify the GTL query (e.g. in Explore) — you have a limited window before data ages out of the hot tier (~30–40 min), after which backfill requires the S3 query path. **Manual recovery:** Set `last_emitted_minute_epoch` to `now_epoch - backfill_window_seconds` (e.g. 3600), set `emit_delay_seconds = 0`, and run the job (or a backfill script) so it re-queries the window and re-emits the missing minutes. Use the S3 union in the GTL query if the gap is older than hot-tier retention.

### 4.9 Reference GTL query (for Node script)

The Node script cannot use MCP; it must call the Better Stack Query API (or ClickHouse) directly. The following is a **reference SQL template** for `fetch-gtl-logs.js` so the script query stays aligned with Explore semantics. Adapt table names and field extraction to the actual log schema (message in `raw`, or structured fields).

- **Tables:** Hot tier holds ~30–40 min only. When the query window spans beyond that (e.g. 3h lookback), use the S3 union as in AGENTS.md: `FROM remote(t491594_trio_logs) WHERE ... UNION ALL SELECT ... FROM s3Cluster(primary, t491594_trio_s3) WHERE _row_type = 1 AND dt BETWEEN ...` (same time bounds and filter). Hot-tier-only is only valid for very small windows (e.g. &lt; 40 min).
- **Filter:** Restrict to GTL events, e.g. `JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'` (or the equivalent for your log shape).
- **Columns to select / extract:** `dt`; from the log message (or `raw`): `data_age_seconds` (e.g. regex or `JSONExtract`), `battery_state` (charging / unplugged / unknown), `get_timeline_at_epoch_seconds` (or equivalent epoch field). The application will dedupe by `dt`, compute `is_off_wrist` (charging OR unknown), and apply the tie-breaks in §4.2.
- **Time bound:** `dt BETWEEN toDateTime(window_start_epoch) AND toDateTime(window_end_epoch)` with `window_start_epoch` and `window_end_epoch` from §5 step 2.

Example sketch (parameterize `window_start`, `window_end`. **For lookback &gt; ~40 min (e.g. 3h default), replace with full S3 union per Tables bullet above** — this sketch shows hot tier only):

```sql
-- NOTE: For lookback > ~40 min (e.g. 3h), use full S3 union per Tables bullet above; hot tier holds ~30–40 min only.
SELECT
  toUnixTimestamp(dt) AS dt,
  JSONExtract(raw, 'message', 'Nullable(String)') AS message
FROM remote(t491594_trio_logs)
WHERE dt BETWEEN toDateTime(:window_start) AND toDateTime(:window_end)
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
```

The sketch returns `dt` as **Unix seconds** (for consistent dedupe key type) and `message`. The application **parses** `data_age_seconds`, `battery_state`, and `get_timeline_at_epoch_seconds` from the `message` string (e.g. regex or string split) before dedupe and ASOF. Then dedupe and filter in application per §4.2 and §5 step 3. If the log format uses different field names or nesting, adjust the SQL and parser so the resulting rows match what the dedupe and ASOF steps expect.

---

## 5. Reconstruction algorithm (once per minute)

**Inputs:**

- `now_epoch` (UTC, seconds).
- `last_emitted_minute_epoch` (persisted state; 0 or epoch of last minute we pushed).
- `emit_delay_seconds` (configurable, e.g. 120 or 180): do not emit minutes newer than `now - 60 - emit_delay_seconds` so late-arriving GTL logs have time to land (§4.5).
- Lookback seconds (e.g. 3 * 3600).
- Better Stack: GTL log query API; metrics push API (Prometheus source token).

**Outputs:**

- Zero or more gauge events `(minute_epoch, value)` pushed to Better Stack.
- Updated `last_emitted_minute_epoch` persisted.

**Steps:**

1. **Emit ceiling:** `end_minute_epoch = max(0, floor(now_epoch / 60) * 60 - 60 - emit_delay_seconds)` (last complete minute **minus** emit delay; floor at 0 so we never emit negative-minute buckets). If `end_minute_epoch <= last_emitted_minute_epoch`, exit (nothing to do).
2. **Window:**  
   `window_start = max(0, last_emitted_minute_epoch - lookback_seconds)` (floor at 0 per §4.1).  
   `window_end` = current wall-clock time in seconds (not floored), so the GTL query includes logs that landed in the current partial minute. Use minute-aligned time only for the emit ceiling (step 1).
3. **Query GTL rows:** Call Better Stack Query API (POST, basic auth; §6, §7) for Trio **logs**, time bounds `[window_start, window_end]`, filter and columns per **§4.9** (reference SQL template). Select: `dt`, extract `data_age_seconds` and **`get_timeline_at_epoch_seconds`** (or equivalent), detect `battery_state=charging` and `battery_state=unknown`. **If the query fails** (HTTP/parse/timeout), do not advance checkpoint; exit and retry next run (§4.8). Dedupe in application: group by **`dt`** only; per group compute `is_off_wrist`, `data_age_seconds` (argMax tie-break as Explore), and **`gtl_epoch`** from the parsed epoch field — if rows in the group disagree on `gtl_epoch`, use **max(gtl_epoch)** and log a warning (§4.2). **Filter:** keep only rows where `is_off_wrist === true` OR `data_age_seconds != null`. Sort by `gtl_epoch`. Result: list `GTL[]` of `{ gtl_epoch, data_age_seconds, is_off_wrist }`.
4. **Minute range to compute:** `from_minute = last_emitted_minute_epoch + 60`; `to_minute = end_minute_epoch` (inclusive). For each minute_epoch in `[from_minute, to_minute]` step 60:
   - **ASOF:** Find the last GTL with `gtl_epoch <= minute_epoch`. If none, skip this minute (or treat as 0; see §8 Sparse GTL coverage).
   - **Value:** If that GTL is off-wrist → `value = 0`. Else `value = data_age_seconds + (minute_epoch - gtl_epoch)`. Clamp to 0 if negative.
5. **Emit:** For each computed `(minute_epoch, value)`, POST one gauge to Better Stack:  
   `{ "name": "complication_visible_recency_seconds", "gauge": { "value": value }, "dt": minute_epoch }`  
   Use **Unix integer** for `dt` (simpler; avoids timezone serialization bugs). RFC 3339 is also valid per §6.1. Use the **Prometheus source** token (see §7).
6. **Checkpoint:** Only after **all** gauge POSTs for this run succeed, set `last_emitted_minute_epoch = to_minute` and persist. On any push failure, do not update the checkpoint (§4.6). **Empty GTL list:** If the query succeeded but returned 0 rows, see §4.8: for v1 recommend advancing the checkpoint (to avoid infinite retry) but **log at WARN**; do not advance if the query **failed**.

**Deduplication (step 3) detail:** For each distinct `dt`, collect all rows. `is_off_wrist = true` if any row has charging or unknown. `data_age_seconds =` value from the row where `NOT is_off_wrist` (argMax of extracted_data_age among those rows), else null. **`gtl_epoch`** = parsed `get_timeline_at_epoch_seconds` from the chosen row; if rows in the group disagree on that value, use **max(gtl_epoch)** and log a warning. If all off-wrist, keep one row with `is_off_wrist=true`, `data_age_seconds=null` (or -1 for sentinel). Then **filter** the list: keep only rows with `is_off_wrist === true` OR `data_age_seconds != null`.

---

## 6. Better Stack capabilities required

| Requirement | Status | Notes |
|-------------|--------|------|
| Query raw GTL logs with time bounds and filters | ✅ | MCP `telemetry_create_cloud_connection_tool` then `telemetry_query` with ClickHouse SQL; table `t491594.trio`, source_id 1659391. Hot + S3 for full history (see AGENTS.md). |
| Run query programmatically (not only Explore UI) | ✅ | Same MCP or REST equivalent. **Runtime (Node script):** Use Better Stack Query API v2 — POST to the connect host (e.g. `https://$BETTERSTACK_QUERY_HOST` or the host from cloud connection), **basic auth** with `$BETTERSTACK_QUERY_USER` / `$BETTERSTACK_QUERY_PASSWORD` (or API token in a header if documented). See §4.9 for the SQL template; §7 for env. |
| Push gauge metrics with custom `dt` | ✅ | [Ingesting metrics](https://betterstack.com/docs/logs/ingesting-data/http/metrics): POST to `https://$INGESTING_HOST/metrics`, Bearer `$SOURCE_TOKEN`, body `{"name":"...", "gauge":{"value": N}, "dt": "RFC3339" or unix_seconds}`. |
| Dashboard can plot pushed metric | ✅ | **Validated.** Pushed gauges use the same unified schema as Prometheus-like metrics. See §6.1 for ingest, storage, and dashboard query shape. |
| Upsert or overwrite historical minute | ❌ | Not documented. Sending the same `dt` again may create a duplicate or overwrite; behavior is unspecified. Idempotency strategy: don’t re-send. |

### 6.1 Validated Better Stack behavior (ingest and dashboard query)

**Source:** Authoritative Better Stack docs (ingesting metrics, SQL queries, unifying schema) as of 2026-03. This applies to metrics **pushed via HTTP** to a **Prometheus source**, not to metrics extracted from logs.

**Ingest (HTTP POST /metrics):**

- **Endpoint:** `POST https://$INGESTING_HOST/metrics`, header `Authorization: Bearer $SOURCE_TOKEN`. Create a [new Prometheus source](https://telemetry.betterstack.com/team/0/sources/new?platform=prometheus) to obtain the token; not all sources allow metrics ingestion.
- **Body:** JSON (or MessagePack / NDJSON). Single gauge: `{"name": "complication_visible_recency_seconds", "gauge": {"value": N}, "dt": <timestamp>}`. Multiple gauges: array of same shape or newline-delimited JSON. Max request size 20 MiB.
- **Timestamp (`dt`):** Overrides receive time. Allowed: RFC 3339 string (e.g. `2023-08-09T07:03:30Z`) or UNIX time in seconds, milliseconds, or nanoseconds. **Historical timestamps are accepted** (backfill is supported). If `dt` cannot be parsed, Better Stack falls back to reception time.
- **Batch:** One POST can contain an array of metric objects; the service may send multiple minutes in one request. Max request size 20 MiB. Large backfills (e.g. thousands of minutes) fit in one POST (~1000 points ≈ 40–50 kB); no explicit batch-size cap required; if splitting into multiple POSTs, advance checkpoint only after all POSTs for the run succeed (§4.6).

**Storage and schema:**

- Pushed metrics are stored in the **unified row-based metrics schema** ([unifying metrics schema](https://betterstack.com/docs/logs/unifying-metrics-schema)). Standard columns include `dt`, `name`, `_row_type`, `series_id`, `tags`, `events_count`, **`value_avg`**, **`value_min`**, **`value_max`**, `rate_avg`, and bucket/quantile columns. For **gauges**, the "Value" metric is automatically configured; values are stored in the generic **value_avg** / value_min / value_max columns (not per-metric column names like extracted log metrics). Filter by **metric name**: `WHERE name = 'complication_visible_recency_seconds'`.

**Dashboard query shape:**

- Use a chart whose **source** is the same Prometheus source used for ingest (e.g. dashboard variable `{{source}}` set to that source). Query pattern for a **single-series gauge** (no tags, one value per time bucket):

```sql
SELECT {{time}} AS time, avgMerge(value_avg) AS value
FROM {{source}}
WHERE name = 'complication_visible_recency_seconds' AND dt BETWEEN {{start_time}} AND {{end_time}}
GROUP BY time
ORDER BY time
```

- **Merge function:** For gauge "value" use **`avgMerge(value_avg)`**. Alternatives for the same data: `maxMerge(value_max)` (peak per bucket), `minMerge(value_min)`. Match the Merge to the column suffix (avg→avgMerge(value_avg)); do not mix (e.g. sumMerge(value_avg) is wrong). Ref: [Writing SQL queries — Prometheus-like metrics](https://betterstack.com/docs/logs/dashboards/sql-queries#prometheus-like-metrics), [How to query the metrics](https://betterstack.com/docs/logs/dashboards/sql-queries#how-to-query-the-metrics).
- **Time:** Use `dt BETWEEN {{start_time}} AND {{end_time}}` for filtering; use `{{time}}` in SELECT and GROUP BY for the chart time bucket (e.g. 1-minute or 5-minute resolution). For a 1-minute sawtooth, set the chart's time grouping to 1 minute so each emitted point maps to one bucket.

**What remains unspecified (do not rely on):**

- **Duplicate `dt` + name:** Better Stack does not document whether a second push with the same `dt` and metric name overwrites, appends, or is deduplicated. The design avoids re-sending the same minute (checkpoint-based idempotency).

**Action items:** (1) Create a **Prometheus source** in Better Stack for this project (or use an existing one, e.g. "Trio Complication Recency" with source id `trio_complication_recency_2`, if already created); obtain **$INGESTING_HOST** and the source token (metrics push endpoint; may differ from the logs query host). (2) Add a dashboard chart that uses that source and the query above (or equivalent with the same Merge and filters). (3) Optional: validate in UI that 1-minute grouping and time range behave as expected.

---

## 7. Nightscout (cgm-remote-monitor) implementation constraints

**Repo:** `cgm-remote-monitor` (Node.js, main `lib/server/server.js`, no separate worker process).

**Findings:**

- **Language/runtime:** Node.js 14+; no existing TypeScript or other language for jobs. Any new code should be Node (JS or TS if the project adopts it).
- **Config/env:** `lib/server/env.js` reads `process.env`; `env.settings` from `lib/settings`; `env.extendedSettings` for plugin-specific config (e.g. `env.extendedSettings.bridge`). New config: e.g. `BETTERSTACK_*` or an `extendedSettings.sawtoothPrecompute` object. **Pin for GTL log query at runtime:** `BETTERSTACK_QUERY_HOST` (connect host), `BETTERSTACK_QUERY_USER`, `BETTERSTACK_QUERY_PASSWORD` (or equivalent for Query API v2 basic auth); see §6 table and §4.9. For ingest: Prometheus source token, ingest host; lookback seconds; emit delay.
- **Scheduling:** No cron or job queue in the repo. Options: (1) **System cron** runs a standalone script (e.g. `node bin/sawtooth-precompute.js`) every minute; (2) **In-process:** a new "plugin" or server module that calls `setInterval(runPrecompute, 60_000)` after boot (similar to `lib/plugins/bridge.js` and `lib/bus.js`). The bus emits `tick` at `settings.heartbeat` seconds (configurable); that could drive the job only if heartbeat is 60s, which may conflict with other uses.
- **Deployment:** If the job runs inside Nightscout, it shares the same process and env; no extra deployment. If cron-driven, the host must have cron and the script must have access to env (e.g. `.env` or `env-cmd` as in `package.json` scripts).
- **Logging/errors:** Plugins use `console.log` / `console.error`. For production, the job should log start/end, minute range emitted, **count of minutes pushed**, and any query/push errors (including non-success HTTP response from push). Do not throw uncaught so cron or setInterval continues.

**Recommended placement:**

- **Option A (cron):** Standalone script `bin/sawtooth-precompute.js`. Reads env; calls Better Stack **Query API** (POST, basic auth; §4.9, §6) for GTL log query; runs algorithm; pushes gauges; writes checkpoint to file or Mongo (§9).
- **Option B (in-process):** New module under `lib/` (e.g. `lib/sawtooth-precompute/run.js`). Initialized in bootevent after store is ready; `setInterval(..., 60_000)`. Uses same Better Stack SQL API and push API.

**V1 recommendation:** **Standalone cron job** (not in-process). **Checkpoint backend:** file on persistent-disk hosts, MongoDB on Heroku/ephemeral hosts (§9). Explicit env vars. That keeps blast radius down and makes rollback easy (disable cron, no code in the main server process).

**Conclusion:** Better Stack provides a **read-only SQL API** (POST with basic auth to the connect host, query in body; see [Query API](https://betterstack.com/docs/logs/query-api/v2/dashboards/) / warehouse ad-hoc SQL). The Node job can call this directly with credentials from Better Stack Integrations (or an API that returns temporary credentials). No proxy required.

---

## 8. Risks (explicit)

| Risk | Mitigation |
|------|------------|
| **Clock skew** | Use UTC everywhere; derive `now_epoch` from a single source (e.g. job start time). If the server clock is wrong, emitted `dt` will be wrong; align server time with NTP. |
| **Delayed ingestion** | Emit ceiling is **last complete minute minus emit_delay_seconds** (e.g. 120–180 s) so minute M is emitted only after late logs can land; see §4.5 and §5 step 1. Dashboard may lag Explore by that delay. |
| **GTL duplicates** | Dedupe key is `dt`; output `gtl_epoch` from parsed `get_timeline_at_epoch_seconds`; if grouped rows disagree on `gtl_epoch`, use max(gtl_epoch) and log warning (§4.2). |
| **Sparse GTL coverage** | If no GTL with `gtl_epoch <= minute_epoch` exists (e.g. no logs yet for that period), either skip that minute (gap) or emit 0. Skipping is safer so the chart doesn’t show false zeros. |
| **Off-wrist gaps** | Represent as 0 only when the anchor GTL is off-wrist; do not interpolate. |
| **Inability to upsert historical minutes** | Do not re-emit; persist checkpoint; accept that late-arriving logs do not fix already-emitted minutes. |
| **Prometheus source vs Trio source** | Dashboard must have two sources (or one combined view if Better Stack supports it); chart for sawtooth uses the Prometheus source. |
| **Query API availability** | Resolved: Better Stack SQL API is REST (POST, basic auth). Node script can call it directly. |
| **Single writer** | Only one instance of the job must run (cron XOR in-process; or file lock / leader election if multiple nodes). Otherwise duplicate pushes and checkpoint corruption. **Multi-dyno (e.g. Heroku Standard):** Cron or Heroku Scheduler runs once globally, but an **in-process** `setInterval` would run on every dyno — avoid in-process on multi-dyno. For cron + file checkpoint, add a **file lock** around state read/write (e.g. `fs.open(..., 'wx')` or lockfile) so concurrent runs do not corrupt the checkpoint. |
| **Stop / rollback** | To stop: disable cron or the in-process timer; the dashboard series will show a gap from the last checkpoint. Better Stack does not document deletion of pushed metrics; to "clear" the series you can only stop emitting. |

---

## 9. Recommended architecture

1. **Separate Prometheus source** in Better Stack for precomputed metrics only. One gauge: `complication_visible_recency_seconds`.
2. **Checkpoint store:** Persist `{ last_emitted_minute_epoch: number }`. **v1 supports both:** (a) **File** — e.g. `data/sawtooth-precompute-state.json` on a host with persistent disk; (b) **MongoDB** — when `MONGODB_URI` is set (e.g. Heroku), use Nightscout's existing DB and a **dedicated collection** (single document); no local file. On Heroku do not use file (ephemeral filesystem); use Mongo. See implementation plan §3.1 (Nightscout MongoDB usage), §8.5 (Mongo checkpoint contract).
3. **Job:** For v1 prefer **cron** every minute calling `node bin/sawtooth-precompute.js` (standalone script, not in-process). Single writer. Job reads checkpoint, computes window with **emit_delay** (§5), calls Better Stack REST SQL API for GTL logs, dedupes (with gtl_epoch tie-break), runs ASOF per minute, pushes gauges with `dt`, then writes checkpoint only after all pushes succeed and per §4.8 for empty results.
4. **Dashboard:** New chart that queries the **Prometheus** source using the validated query shape in §6.1 (`name = 'complication_visible_recency_seconds'`, `avgMerge(value_avg)`).

---

## 10. Pseudocode

```text
function runPrecompute():
  state = loadState()  // { last_emitted_minute_epoch }
  wall_now = now()   // actual time (seconds); use for GTL query upper bound so we include logs in current partial minute
  now_epoch = floor(wall_now / 60) * 60   // minute-aligned; used only for emit ceiling
  emit_delay_seconds = 120   // configurable; do not emit minutes newer than this
  end_minute = max(0, now_epoch - 60 - emit_delay_seconds)   // emit ceiling; floor at 0
  if end_minute <= state.last_emitted_minute_epoch:
    return

  lookback = 3 * 3600
  window_start = max(0, state.last_emitted_minute_epoch - lookback)
  window_end = wall_now   // not floored; include GTL rows that landed in current partial minute

  gtl_rows = queryBetterStackLogs(window_start, window_end)  // on query failure: do not advance checkpoint; return
  if gtl_rows is error: return
  gtl_deduped = dedupeByDt(gtl_rows)   // GROUP BY dt; gtl_epoch from parsed get_timeline_at_epoch_seconds; if disagree use max and log
  gtl_deduped = filter(gtl_deduped, g => g.is_off_wrist || g.data_age_seconds != null)  // match Explore gtl_with_age
  if length(gtl_deduped) == 0: log WARN "empty GTL list"; still advance checkpoint after (zero) pushes per §4.8
  sort gtl_deduped by gtl_epoch

  from_minute = state.last_emitted_minute_epoch + 60
  to_minute = end_minute
  for minute_epoch in [from_minute .. to_minute] step 60:
    anchor = last(gtl_deduped where gtl_epoch <= minute_epoch)
    if anchor is null: continue
    if anchor.is_off_wrist: value = 0
    else: value = max(0, anchor.data_age_seconds + (minute_epoch - anchor.gtl_epoch))
    pushGauge("complication_visible_recency_seconds", value, minute_epoch)

  // Only advance checkpoint after all pushes succeed (atomicity; on failure, retry same range next run)
  state.last_emitted_minute_epoch = to_minute
  saveState(state)
```

---

## 11. Concrete file / module suggestions (cgm-remote-monitor)

| Path | Purpose |
|------|---------|
| `bin/sawtooth-precompute.js` | Standalone entrypoint for cron. Loads env, calls `lib/sawtooth-precompute/run.js`, exits. |
| `lib/sawtooth-precompute/run.js` | Core: load state, window, call fetchGtlLogs, dedupe, ASOF loop, pushGauges, save state. |
| `lib/sawtooth-precompute/fetch-gtl-logs.js` | Better Stack logs query: use SQL template in **§4.9**, call Query API (env: BETTERSTACK_QUERY_HOST, BETTERSTACK_QUERY_USER, BETTERSTACK_QUERY_PASSWORD); returns rows as `{ dt, message }`. Parse-message and dedupe (downstream) produce `{ gtl_epoch, data_age_seconds, is_off_wrist }`. |
| `lib/sawtooth-precompute/dedupe.js` | `dedupeByDt(rows)` → one row per `dt` with is_off_wrist, data_age_seconds, and gtl_epoch (from parsed get_timeline_at_epoch_seconds; tie-break §4.2). |
| `lib/sawtooth-precompute/push-metrics.js` | POST to Better Stack `/metrics` with Bearer token, gauge + dt. Use **Unix integer** for `dt` (see §5 step 5). |
| `lib/sawtooth-precompute/state.js` | loadState() / saveState(); backend = **file** or **MongoDB** from env (§9). When `MONGODB_URI` is set, use Mongo with dedicated collection (implementation plan §3.1, §8.5). |
| `data/sawtooth-precompute-state.json` | Checkpoint file when backend=file (create dir if missing). When backend=Mongo, no file. |
| (optional) `lib/plugins/sawtoothPrecompute.js` | Plugin that registers setInterval(60_000) and calls run(); uses env.extendedSettings.sawtoothPrecompute. |

If the job is **in-process only**, `bin/sawtooth-precompute.js` can be omitted and bootevent can require `lib/sawtooth-precompute/run.js` and schedule it.

---

## 12. Dependencies

- **Trio:** No code changes. Source of truth remains Better Stack GTL logs.
- **Better Stack:** Trio source (logs) for query; second source (Prometheus) for ingest; dashboard chart on the second source.
- **Nightscout:** New dependency only if using REST client (e.g. `axios` or `node-fetch`); no new npm deps if using Node built-in `https` for POST.

---

## 13. References

- Explore sawtooth query: `docs/completed/betterstack/betterstack-complication-dashboard-setup.md` (§ Complication Visible Recency (Sawtooth) — Explore only).
- Dashboard constraints: `docs/in-progress/complication-freshness/sawtooth-dashboard-options.md` (§1–2).
- Better Stack guide: `docs/process/betterstack-guide.md`.
- Better Stack metrics ingestion: https://betterstack.com/docs/logs/ingesting-data/http/metrics (timestamp override, gauge). Dashboard SQL for Prometheus-like metrics: https://betterstack.com/docs/logs/dashboards/sql-queries#prometheus-like-metrics. Unifying schema: https://betterstack.com/docs/logs/unifying-metrics-schema.
- AGENTS.md: Better Stack MCP (telemetry_create_cloud_connection_tool, telemetry_query), hot vs S3, table names.
- Better Stack Query API (run SQL over logs): https://betterstack.com/docs/logs/query-api/v2/dashboards/ (POST, basic auth, ClickHouse SQL).
