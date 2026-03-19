# Complication visible recency: instrumentation-based dashboard design

**Version:** v1.3
**Created:** 2026-03-16 00:00 CET
**Last updated:** 2026-03-16 00:00 CET
**Status:** Design for review

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | (initial) | Verdict, schema, Trio changes, risks, validation checklist. |
| 1.1 | 2026-03-16 | Tightened correctness: visible_recency_at_bucket_end_seconds is a proxy/estimate, not guaranteed ground truth; added §6.1 multiple GTLs per bucket and §6.2 dt vs GTL alignment; first-call labeled as bootstrap approximation; off-wrist null gaps and visual interpretation risk; validation items for dt alignment and GTL-per-bucket confirmation. |
| 1.2 | 2026-03-16 | De-emphasised null-gap “visual interpretation” as a risk (not important for this use). Retroactive metric processing: clarified that Better Stack UI reprocessing is possible within data retention (current plan 8 days). |
| 1.3 | 2026-03-16 | Added §6.3 Data analysis findings: dt vs GTL alignment 100% (65/65) over 2026-03-15–16; GTL-per-bucket distribution (130 buckets, 51.5% single logical GTL, 4.6% with 2+ logical GTLs). |
**Depends on:** [sawtooth-dashboard-options.md](sawtooth-dashboard-options.md), `docs/completed/betterstack/betterstack-complication-dashboard-setup.md` (repo root), Trio GTL logging in `TrioComplicationDataStore` / `TrioWatchComplication`.

---

## 1. Verdict (concise)

- **Exact 1-minute sawtooth on the dashboard from instrumentation alone is not achievable** without either (a) a process that runs every minute and logs a recency value (not guaranteed on watchOS), or (b) emitting one log line per minute of each “tooth” (high volume, and dashboard grouping uses log receipt time so would still not attribute values to the correct minute buckets).
- **A 5-minute bucket proxy is achievable** by adding minimal instrumentation: persist “previous GTL” epoch and data age in App Group, and at each `getTimeline` log a **single** derived field `visible_recency_at_bucket_end_seconds`. This value is a **proxy/estimate** emitted at GTL time (an extrapolated recency at the end of the 5-min bucket containing this GTL), not guaranteed bucket-end ground truth — it assumes no refresh occurs between this GTL and bucket end, and depends on `dt` aligning with GTL time. Extract as a metric; dashboard groups by 5 min on `dt` and uses `maxMerge`. Off-wrist GTLs emit 0. **Approximate:** buckets with no GTL show a gap (null); we emit 0 only when a GTL runs in that bucket and is off-wrist.
- **Richer GTL fields only** (e.g. `previous_gtl_epoch`, `previous_data_age_seconds`) **do not** by themselves remove the need for ASOF in the metrics layer: the dashboard would still need “last GTL at or before bucket” to compute recency for each bucket. So the recommended approach is to **emit the bucket-level answer at log time** (one value per GTL = recency at end of the 5-min bucket containing that GTL), not just “previous” for downstream ASOF.

**Recommended designs (ranked):**

1. **5-min bucket-end value on GTL log (recommended)** — Persist previous GTL epoch/age; at each getTimeline compute and log `visible_recency_at_bucket_end_seconds` (proxy/estimate at GTL time, not guaranteed bucket-end ground truth); extract as Max; dashboard 5-min group by dt, maxMerge. Approximate for buckets that contain a GTL; gap (null) when no GTL. Off-wrist → 0 for that bucket when a GTL runs in it.
2. **Same + optional previous_* fields for Explore** — Add `previous_gtl_epoch_seconds` and `previous_data_age_seconds` to the GTL log for debugging and for any future Explore/raw-log query that wants to reconstruct the tooth without ASOF. Does not change dashboard capability by itself.
3. **External precompute job** — Keep current or richer GTL logs; run a job (e.g. cron) that does ASOF over raw logs and writes a 1-min or 5-min series into a push metric. Highest fidelity, highest ops cost; no change to Trio logging required for the job to work.

---

## 2. Context: current Explore sawtooth and dashboard limits

- **Explore sawtooth:** Uses raw logs; ASOF JOIN to “last GTL at or before each minute”; value = `data_age_seconds + (bucket_epoch - gtl_epoch)`; off-wrist → 0. Requires `raw` and per-event state; cannot be expressed as a pre-aggregated metric.
- **Dashboard:** Queries metrics table only (no `raw`). Extract Metrics run at ingestion (sum/count/avg/max/quantiles). Chart = one row per time bucket via `GROUP BY` on `dt`. **We do not assume** “last value” or stateful carry-forward; per `betterstack-guide.md` only sum, count, avg, max, quantiles are documented.
- **Metric timestamp:** Dashboard grouping uses `dt` (log receipt/event time). There is no documented way to assign a custom “event time” to a metric value. So a log line’s value is attributed to the bucket of **when the log was written**, not an arbitrary timestamp in the message.

---

## 3. Candidate log additions and assessment

| Field | Purpose | Required for 5-min proxy? | Notes |
|-------|--------|----------------------------|--------|
| `current_gtl_epoch` | Explicit name for “this” getTimeline time | No | Already logged as `get_timeline_at_epoch_seconds` in `TrioComplicationDataStore.logWidgetGetTimelineInvocation`. |
| `current_data_age_seconds` | Explicit name for “this” snapshot age | No | Already logged as `data_age_seconds`. |
| `previous_gtl_epoch_seconds` | Epoch of the previous getTimeline (for interpolation) | Yes (for computing bucket-end recency) | Not persisted today. Must persist in App Group after each GTL; on first call or after restart use sentinel (-1) or omit. |
| `previous_data_age_seconds` | Data age at the previous getTimeline | Yes (for computing bucket-end recency) | Same persistence as above. |
| `visible_recency_at_bucket_end_seconds` | **Proxy/estimate** of recency at the end of the 5-min bucket containing this GTL (emitted at GTL time; not guaranteed ground truth) | Yes (dashboard-ready value) | Computed at log time: if off-wrist → 0; else `previous_data_age_seconds + (bucket_end_epoch - previous_gtl_epoch)`. When no previous (first call), use `current_data_age_seconds` as a **bootstrap approximation** only — not true bucket-end recency. |

**Other fields considered:** None required. `battery_state` is already appended by `ComplicationLogBuffer`; off-wrist is derived from that in extraction or in-app when computing `visible_recency_at_bucket_end_seconds`.

**Correctness:** For the 5-min proxy we need exactly one of (a) a value derived at log time and attributed to the bucket of `dt`, or (b) a way to attribute a value to a different bucket (not supported per current docs). So (a) is the only path: emit `visible_recency_at_bucket_end_seconds` on the GTL log as a **proxy/estimate** (extrapolated at GTL time; not guaranteed to equal actual recency at bucket end if a refresh occurs before bucket end). `dt` then places it in a 5-min bucket; that attribution is correct only if `dt` aligns with GTL time (see §6.2).

---

## 4. Where each approach is produced (exact vs approximate)

| Approach | Exact or approximate? | Where produced | Trio code changes | Better Stack validation |
|----------|------------------------|----------------|-------------------|-------------------------|
| **5-min bucket-end value on GTL** | Approximate (one value per GTL; gaps when no GTL in bucket) | Log-emission time (complication) | Persist previous_gtl_epoch, previous_data_age_seconds in App Group; compute and log visible_recency_at_bucket_end_seconds; off-wrist → 0 | Extract Metric from new field; dashboard 5-min group, maxMerge. Confirm dt is bucket-aligned as expected. |
| **Richer GTL only (previous_*)** | Still requires ASOF for dashboard | Log-emission time | Same persistence; add previous_* to log only | Dashboard cannot use without ASOF or external job. Explore could use for alternative queries. |
| **1-minute exact series** | Exact per minute | Would require emission every minute | Would need a periodic path (e.g. BGAppRefreshTask) to run every minute and log; watchOS does not guarantee 1-min cadence | Same extraction pattern; 1-min grouping. Not recommended without verifying background refresh cadence. |
| **External precompute job** | Exact (1-min or 5-min) | External job (e.g. cron + MCP/API) | None for job; optional richer logs for job input | Push/custom metrics API; retention and idempotency. |

---

## 5. Trio code changes (5-min bucket-end design)

- **TrioComplicationDataStore (Trio Watch Shared):**
  - Add UserDefaults keys (e.g. `TrioComplication_lastGtlEpochSecondsKey`, `TrioComplication_lastGtlDataAgeSecondsKey`) in App Group.
  - Read/write last GTL epoch and last data age (after each successful getTimeline log); handle first call and provider restart (no previous → use current for bucket-end or sentinel).
  - Extend `logWidgetGetTimelineInvocation` (or add a small helper) to: (1) read previous_gtl_epoch and previous_data_age_seconds from App Group; (2) compute 5-min bucket end containing `getTimelineAtEpochSeconds`; (3) compute `visible_recency_at_bucket_end_seconds` = if off-wrist then 0 else `previous_data_age_seconds + (bucket_end_epoch - previous_gtl_epoch)` (with guard for no previous); (4) append to log message; (5) after logging, persist current getTimeline epoch and data_age_seconds for next time.
  - Off-wrist must be known at log time: battery is appended by `ComplicationLogBuffer.append` **after** the store builds the message. So the store does not have battery in the message it passes to `log()`. Options: (A) pass an `isOffWrist: Bool` (or battery context) into `logWidgetGetTimelineInvocation` and have the caller obtain it before logging, or (B) have the buffer/forwarder prepend battery to the message so the store can log a message that already includes battery (inverted flow). Option (A) is cleaner: the complication provider can read battery (e.g. from WKInterfaceDevice) before calling the store and pass a flag. **Call site change:** `TrioWatchComplication.getTimeline` must obtain battery state (or a cached value from ComplicationLogBuffer if we expose it) and pass `isOffWrist` into the store so the store can set visible_recency_at_bucket_end_seconds = 0 when off-wrist.
- **TrioWatchComplication (Trio Watch Complication):**
  - Before `store.logWidgetGetTimelineInvocation(...)`, determine off-wrist (e.g. battery_state is charging or unknown). The complication runs in the widget extension; `ComplicationLogBuffer` already has `batteryContextOnMain()` and a cached `lastBatteryContext`. We need to pass that into the log call. Easiest: add a parameter `isOffWrist: Bool` to `logWidgetGetTimelineInvocation` and have the provider compute it (e.g. read from same source as buffer, or have the store read from a shared cache). If the store reads a “last known off-wrist” from UserDefaults or a static in the buffer, we must keep it in sync; the buffer currently updates battery asynchronously. So **recommended:** provider calls something that returns current battery state (sync) and passes `isOffWrist` into the store. The provider runs on MainActor; `WKInterfaceDevice.current().batteryState` is available. So: in getTimeline, before logging, let state = WKInterfaceDevice.current().batteryState; isOffWrist = (state == .charging || state == .unknown). Pass isOffWrist into logWidgetGetTimelineInvocation.
- **Persistence:** Write previous_gtl_epoch and previous_data_age_seconds **after** we’ve built and logged the current GTL line (so “previous” is the prior invocation’s values). On first call (e.g. after install or provider restart), we have no previous; use sentinel -1 or omit the derived field; for bucket-end computation when no previous, set visible_recency_at_bucket_end_seconds = current_data_age_seconds as a **bootstrap approximation only** — not true bucket-end recency (we have no prior GTL to extrapolate from); it merely avoids a null for that bucket.

---

## 6. Risks, gaps, and operational cost

- **Gaps:** Buckets with no getTimeline call (WidgetKit budget, or extension not run) have no log line → no value in the dashboard for that bucket. Acceptable for a “when we have data, show recency” proxy. Off-wrist buckets: we emit 0 when we **do** get a GTL in that bucket and it’s off-wrist; if the watch is charging and no GTL runs in a bucket, that bucket still has **no value** (null gap). Off-wrist handling therefore **does not** eliminate gaps — it only fills the bucket when an off-wrist GTL happens to run in it. (Interpretation of nulls is not treated as a material risk for this design.) We could add a separate periodic “heartbeat” that emits 0 when off-wrist, but that again requires a periodic path.
- **Correctness:** Bucket boundaries must match dashboard grouping. We use `floor(getTimelineAtEpochSeconds / 300) * 300 + 300` as bucket_end_epoch (end of 5-min window in UTC). Dashboard uses `toStartOfInterval(dt, INTERVAL 5 MINUTE)`; `dt` is log receipt time (≈ getTimeline time). So the bucket containing the GTL is the same as the bucket of `dt` **only if** `dt` aligns with GTL time (see §6.2). We emit “recency at end of that bucket”; maxMerge over the bucket gives the max of emitted values (see §6.1 when multiple GTLs fall in the same bucket).
- **Duplicate GTL logs:** Each GTL is logged twice (two subsystems). So we might get two log lines with the same dt and same visible_recency_at_bucket_end_seconds. Extract Metric will see two values per bucket; maxMerge gives the same value. No change needed.
- **Retroactive data:** By default, Extract Metrics process only new logs. **Retroactive processing** (reprocessing historical logs so the new metric is backfilled) is **possible via the Better Stack UI** (reprocess option), as far back as data retention allows; current plan is 8 days retention.
- **Operational cost:** Minimal (one new field, two new UserDefaults keys, one-off validation of dashboard query and metric definition).

### 6.1 Multiple GTLs in the same 5-minute bucket

When more than one getTimeline call falls in the same 5-minute bucket, the dashboard receives multiple log lines (and thus multiple values of `visible_recency_at_bucket_end_seconds`) for that bucket. We use **maxMerge**, so the chart shows the **maximum** of those values. That is imperfect for representing "recency at bucket end" because: (a) each value is an extrapolation from a different GTL time, and (b) the true bucket-end recency is determined by the **last** GTL in the bucket and whether a refresh happened after it — max over all values in the bucket can overstate (e.g. early GTL had high extrapolated value, later GTL refreshed and had low value; max keeps the high one). The design **assumes that a single GTL per 5-minute bucket is the common case** (WidgetKit budget and refresh interval make multiple GTLs in one bucket less frequent). **Validation requirement:** before relying on this design for interpretation, confirm from real logs (e.g. count GTLs per 5-min bucket over a representative period) that single-GTL-per-bucket is dominant; if multiple GTLs per bucket are common, document the overstatement risk and consider whether max is still the desired aggregation.

### 6.2 Alignment of `dt` with `get_timeline_at_epoch_seconds`

The proxy attributes the emitted value to the 5-minute bucket via `dt` (the log timestamp used by Better Stack at ingestion). Correct bucket attribution **assumes** that `dt` falls in the same 5-minute window as the GTL epoch (`get_timeline_at_epoch_seconds`). If logs are buffered or forwarded (e.g. from the watch to Better Stack via an intermediate drain), delay or clock skew could cause `dt` to differ from GTL time and land in a **different** 5-minute bucket, so the value would be grouped into the wrong bucket. **Validation requirement:** verify from real logs (sample rows with both `dt` and extracted `get_timeline_at_epoch_seconds`) that `toStartOfInterval(dt, INTERVAL 5 MINUTE)` equals the 5-min bucket of the GTL epoch (e.g. `toStartOfInterval(toDateTime(get_timeline_at_epoch_seconds), INTERVAL 5 MINUTE)`). If buffering or forwarding can cross bucket boundaries, document the risk and consider whether the proxy remains acceptable for your use case.

### 6.3 Data analysis findings (2026-03-16)

Queries were run against Trio logs (S3, `_row_type = 1`) for **2026-03-15 00:00 through 2026-03-16 16:00** to validate the assumptions in §6.1 and §6.2.

**dt vs GTL alignment (§6.2):** For every GTL log line that contained a valid `get_timeline_at_epoch_seconds` value, the 5-minute bucket of `dt` was compared to the 5-minute bucket of that epoch. **Result: 65 / 65 rows aligned** (100%). No misaligned rows in this window. So for this period and source, `dt` and the GTL epoch fall in the same 5-minute bucket; buffering/forwarding did not push any row into a different bucket. (Sample size is one device and ~40 hours; still recommend spot-checking after any pipeline or drain change.)

**Multiple GTLs per 5-minute bucket (§6.1):** GTL log lines were grouped by 5-minute bucket (`toStartOfInterval(dt, INTERVAL 5 MINUTE)`). Distribution of **log-line count per bucket**:

| Log lines per bucket | Buckets | % of buckets with GTL |
|----------------------|--------|------------------------|
| 1 | 55 | 42.3 |
| 2 | 67 | 51.5 |
| 3 | 2 | 1.5 |
| 4 | 4 | 3.1 |
| 6 | 2 | 1.5 |

Total: **130 buckets** had at least one GTL log line. Each logical GTL is logged twice (two subsystems), so **2 lines ≈ 1 logical GTL**, 4 lines ≈ 2 logical GTLs, 6 lines ≈ 3 logical GTLs. So **51.5% of buckets** have exactly one logical GTL (2 log lines); **4.6%** have 2+ logical GTLs (4 or 6 lines). The assumption that **single GTL per bucket is the common case** is supported; the remainder are mostly 1-line buckets (one duplicate in another bucket or one subsystem only). **maxMerge** overstatement risk is limited to the small share of buckets with 4+ lines.

---

## 7. Proposed log schema additions

**Existing GTL line (unchanged except additions):**  
`event=complication_get_timeline_called app_group_available=... observed_generation_source=... ... get_timeline_at_epoch_seconds=<N> data_age_seconds=<M> ...`  
(+ battery appended by buffer: `battery_level_percent=... battery_state=charging|unplugged|unknown`)

**New fields (add to the same log line, space-separated key=value):**

| Field | Type | When present | Semantics |
|-------|------|--------------|-----------|
| `previous_gtl_epoch_seconds` | Int64 | When we have a previous GTL (persisted) | Epoch of the previous getTimeline call. -1 or omit when first call or after restart. |
| `previous_data_age_seconds` | Int64 | Same as above | Data age (seconds) at the previous getTimeline. -1 or omit when no previous. |
| `visible_recency_at_bucket_end_seconds` | Int64 | Always (for dashboard) | **Proxy/estimate** (emitted at GTL time; not guaranteed bucket-end ground truth). 0 when off-wrist; else previous_data_age_seconds + (bucket_end_epoch - previous_gtl_epoch). When no previous, use current_data_age_seconds as a **bootstrap approximation only** — not true bucket-end recency. |

**Off-wrist:** When `battery_state=charging` or `battery_state=unknown`, we set `visible_recency_at_bucket_end_seconds=0`. The store must know off-wrist at log time (see Trio changes: pass `isOffWrist` from provider).

---

## 8. Example log lines

**On-wrist, second GTL (has previous):**
```
event=complication_get_timeline_called app_group_available=true observed_generation_source=set observed_reload_generation=2740 ... get_timeline_at_epoch_seconds=1773642238 data_age_seconds=496 previous_gtl_epoch_seconds=1773641808 previous_data_age_seconds=3066 visible_recency_at_bucket_end_seconds=3558 battery_level_percent=15 battery_state=unplugged
```
(Computed: bucket containing 1773642238 → end 1773642300; 3066 + (1773642300 - 1773641808) = 3066 + 492 = 3558. Wait, that’s not 518. Let me recalc: bucket_end for 1773642238 = floor(1773642238/300)*300+300 = 1773642000+300 = 1773642300. So visible_recency_at_bucket_end = 3066 + (1773642300 - 1773641808) = 3066 + 492 = 3558. See value 3558 above.)

**Simpler example:** previous_gtl_epoch=1000, previous_data_age=60, getTimeline at 1027. Bucket end = 1050. visible_recency_at_bucket_end = 60 + (1050 - 1000) = 110.
```
event=complication_get_timeline_called ... get_timeline_at_epoch_seconds=1027 data_age_seconds=65 previous_gtl_epoch_seconds=1000 previous_data_age_seconds=60 visible_recency_at_bucket_end_seconds=110 ... battery_state=unplugged
```

**Off-wrist (charging):**
```
event=complication_get_timeline_called ... get_timeline_at_epoch_seconds=1773642238 data_age_seconds=496 previous_gtl_epoch_seconds=1773641808 previous_data_age_seconds=3066 visible_recency_at_bucket_end_seconds=0 battery_level_percent=15 battery_state=charging
```

**First call (no previous):** Omit previous_* or set -1; set visible_recency_at_bucket_end_seconds = current_data_age_seconds (bootstrap approximation only — not true bucket-end recency (no prior GTL to extrapolate from); it merely supplies a value for that bucket.).
```
event=complication_get_timeline_called ... get_timeline_at_epoch_seconds=1773637322 data_age_seconds=3853 visible_recency_at_bucket_end_seconds=3853 battery_level_percent=unknown battery_state=unknown
```

---

## 9. Example metric definition and dashboard query

**Extract Metric (Better Stack source Trio, new metric):**

- **Name:** `complication_visible_recency_at_bucket_end_seconds`
- **Type:** Int64
- **Aggregation:** Max (so each bucket takes the max of any GTL in that bucket).
- **SQL expression (extract from message):**
  - Option A (prefer field when present):  
    `toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*visible_recency_at_bucket_end_seconds=([0-9]+).*', '\\1'))`
  - Only for GTL events: ensure the metric is only applied to lines containing `event=complication_get_timeline_called` (either in the same extract with CASE WHEN, or as a separate metric that only fires for that event). Better Stack typically runs the expression per log line; if the field is missing the expression returns NULL and that line contributes nothing. So the expression above is sufficient if the metric is defined on the Trio source (and only GTL lines have this field).

**Dashboard chart query (5-minute line chart):**
```sql
SELECT
  toStartOfInterval(dt, INTERVAL 5 MINUTE) AS time,
  maxMerge(complication_visible_recency_at_bucket_end_seconds_max) AS value
FROM {{source}}
WHERE dt BETWEEN {{start_time}} AND {{end_time}}
GROUP BY time
ORDER BY time ASC
```
Chart: time (x), value (y). Gaps (null) where no GTL occurred in a bucket.

**Off-wrist and gaps:** We emit 0 for off-wrist GTLs, so those buckets get a 0 when a GTL runs in them. Buckets with **no** GTL at all (e.g. no budget, or charging with no GTL) remain **null gaps**. Off-wrist handling does not eliminate gaps.

---

## 10. Validation checklist for implementing agent

- [ ] Confirm Better Stack metrics table uses `dt` as log receipt/time bucket and that `toStartOfInterval(dt, INTERVAL 5 MINUTE)` matches the 5-min alignment used in the app (UTC).
- [ ] **dt vs GTL alignment:** Verify from real logs that the log timestamp (`dt`) used by Better Stack groups into the **same** 5-minute bucket as the GTL epoch (`get_timeline_at_epoch_seconds`). Sample rows: compare `toStartOfInterval(dt, INTERVAL 5 MINUTE)` with the 5-min bucket of the extracted GTL epoch. Call out risk if buffering/forwarding can cross bucket boundaries (see §6.2).
- [ ] **Multiple GTLs per bucket:** Confirm from logs (e.g. count GTLs per 5-min bucket over a representative period) that single GTL per bucket is the common case before relying on maxMerge for interpretation; document overstatement risk if multiple GTLs per bucket are common (see §6.1).
- [ ] Confirm Extract Metric supports `replaceRegexpOne` (or equivalent) and that the metric column name becomes `complication_visible_recency_at_bucket_end_seconds_max` (or as per Better Stack naming).
- [ ] Implement persistence of previous_gtl_epoch_seconds and previous_data_age_seconds in App Group UserDefaults; read before log, write after log; handle first call (no previous) with bootstrap approximation only.
- [ ] Implement off-wrist detection at getTimeline call site and pass into store so visible_recency_at_bucket_end_seconds=0 when charging/unknown.
- [ ] Add new fields to log message in `logWidgetGetTimelineInvocation` (or helper); compute bucket_end_epoch and visible_recency_at_bucket_end_seconds (proxy/estimate; bootstrap when no previous).
- [ ] Add Extract Metric via API (or UI); add dashboard chart with the query above; verify one point per 5-min bucket when GTLs occur and null gaps when they don’t.
