# Sawtooth chart on dashboard: options for review

**Version:** 1.2  
**Last updated:** 2026-03-16

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | (initial) | Options 1–10, summary of Explore query, dashboard constraints, validation order. |
| 1.1 | 2026-03-16 | Added §6 Implementation plan (instrumentation-based 5-min proxy); design note in `sawtooth-dashboard-instrumentation-design.md`. |
| 1.2 | 2026-03-16 | §6 Risks: retroactive metric processing possible via Better Stack UI within retention (8 days). |

---

**Purpose:** For review by another AI agent. Summarizes the current Explore sawtooth query and graph, then proposes 5–10 ways to get a sawtooth (or proxy) into a Better Stack **dashboard** view, ordered by likelihood of achieving the desired result. Includes context to validate each suggestion.

**References:**  
- Current setup: `docs/completed/betterstack/betterstack-complication-dashboard-setup.md`  
- Better Stack process: `docs/process/betterstack-guide.md`  
- Dashboard ID: **689533**; Source ID (Trio): **1659391**

---

## 1. Summary of current Explore query and graph

### What the chart shows

- **Metric:** “Complication visible recency” — the **data age (seconds)** of the snapshot currently shown on the Apple Watch complication at each minute.
- **Interpretation:** At time T, the value = “how many seconds old was the data on the complication at T?” So it’s the **user-visible staleness** over time.
- **Shape:** A **sawtooth**: value ramps up (1 s/s) between refreshes, then drops at each `getTimeline` call when new data is shown. Off-wrist periods (charging, `battery_state=unknown` on provider restart) are drawn as a **flat zero line** (no ramp through the gap).

### How the Explore query works (high level)

1. **Input:** Raw logs from `{{source}}` (Explore unions hot + cold logs). Only rows with `event=complication_get_timeline_called` and a 3-hour lookback before `{{start_time}}`.
2. **GTL CTE:** For each log line, extract `dt`, `battery_state` (charging/unknown → off-wrist), and `data_age_seconds` from the message. **Deduplicate** by `dt` (each GTL is logged twice): `GROUP BY dt`, `max(is_off_wrist)`, `argMaxIf(logged_data_age, ..., NOT is_off_wrist)`.
3. **gtl_with_age:** One row per GTL event: `data_age_seconds = -1` when off-wrist, else the logged `data_age_seconds`. Filter to rows that are off-wrist or have a non-NULL age.
4. **Buckets:** Per-minute grid from `{{start_time}}` to `max(gtl_epoch)` (up to 4320 minutes).
5. **ASOF JOIN:** For each bucket, join to the **most recent** GTL with `gtl_epoch <= bucket_epoch`. So each minute gets the “last getTimeline before or at that minute.”
6. **Value:** `data_age_seconds + (bucket_epoch - gtl_epoch)` = interpolated age at that minute. If the matched GTL was off-wrist (`data_age_seconds = -1`), the final SELECT forces **0** (so charging/unknown windows show as flat zero).
7. **Output:** One row per minute: `(time, value)` with `value` in seconds; Explore plots a line chart.

### Why it can’t live on the dashboard today

- **Dashboards use the metrics table only.** No `raw` column, no per-log `message`, no row-level access. Only pre-aggregated columns (e.g. `dt`, `events_count`, `value_avg`, `*_sum`, `*_max`, etc.) produced by **Extract Metrics** on the source.
- **Point-in-time logic:** The sawtooth requires, for each minute, “the last GTL at or before that minute” and then arithmetic on that event. That’s an **ASOF JOIN** over event-level data. The metrics table only stores **bucket-level aggregates** (e.g. sum/count/avg/max per time bucket), not “last event in bucket” or “event at time T” unless the pipeline explicitly supports it.
- **Interpolation:** Value between two GTL events is `age_at_gtl + (T - t_gtl)`. That’s stateful (carry last GTL forward). Dashboard charts are stateless over pre-aggregated buckets.

So: the **exact** sawtooth (per-minute interpolated recency, off-wrist flat) is not representable as a standard dashboard metric query without one of the workarounds below.

---

## 2. Dashboard constraints (for validation)

- **Data source:** Dashboard `{{source}}` = metrics table (e.g. `remote(t491594_trio_metrics)`). No logs table, no `raw`.
- **Extract Metrics:** Defined on the Trio **source** (logs). They run at ingestion and populate the metrics table. Supported aggregation types (from `betterstack-guide.md`): **sum**, **count**, **avg**, **max**, **quantiles**. No `raw` or per-event SQL in dashboard queries — only `*Merge(...)` on the resulting columns.
- **Tags/labels:** The pipeline applies `arrayElement` to tag access; string tag values cause **Code 43**. This project uses **named metrics only** (no label-based filtering in dashboard queries).
- **Time grouping:** Dashboard charts group by a time expression (e.g. `{{time}}` or `toStartOfInterval(dt, INTERVAL 5 MINUTE)`). One row per bucket; one point per bucket. Granularity is configurable (e.g. 1 min, 5 min, 1 hour) but still bucket-based.
- **No “last value” in bucket** in the doc — only sum/count/avg/max/quantiles. If Better Stack supports “last value” or “latest” aggregation, that would need to be confirmed in their current docs/API.

---

## 3. Options to get a sawtooth (or proxy) on the dashboard

Ordered by **most likely to achieve the desired result** (sawtooth or close proxy on the dashboard), with enough context for another agent to validate.

---

### Option 1: Embed or link Explore in the dashboard (exact sawtooth, no aggregation change)

**Idea:** If Better Stack supports **embedding an Explore view** or a **dashboard tile that links to a saved Explore query**, put the existing sawtooth chart on the dashboard by reference. No change to the Explore query or to metrics.

**Why it’s high likelihood:** Preserves the exact current chart; no need to express ASOF logic in the metrics layer.

**Validation for another agent:**  
- Check Better Stack docs/UI for: “embed Explore”, “link to Explore”, “dashboard widget Explore”, “saved Explore view”, “iframe” or “external chart” in dashboard.  
- If such a feature exists, confirm whether the time range picker of the dashboard can drive the embedded Explore (e.g. shared `{{start_time}}`/`{{end_time}}`).  
- **Risk:** Feature may not exist; then this option is N/A.

---

### Option 2: Precompute sawtooth externally and ingest as a metric (true sawtooth, high effort)

**Idea:** Run the sawtooth logic **outside** Better Stack (e.g. scheduled job or Lambda): query raw logs via API/MCP, run ASOF-style logic or a simplified version, produce a time series “complication_visible_recency_seconds” at 1-minute resolution, then **push that series into Better Stack** as a metric (or into a source that exposes it to the dashboard). Dashboard chart then just plots that metric.

**Why it’s high likelihood:** The series is exactly the desired sawtooth; the dashboard only displays it. No need to implement ASOF in the metrics engine.

**Validation for another agent:**  
- Confirm whether Better Stack supports **ingesting pre-aggregated time series** (e.g. “metric at time T = value”) from an API or integration, and what schema (timestamp + value, bucket, etc.).  
- Check for “custom metrics”, “push metrics”, “statsd”, “Prometheus remote write”, or similar.  
- If supported: design job (frequency, idempotency, backfill), storage, and how the dashboard `{{source}}` or a second source would expose this metric.  
- **Risks:** Operational cost; possible retention/backfill limits; need to keep off-wrist logic in sync with Explore query.

---

### Option 3: Extract `data_age_seconds` metric + 1-minute dashboard buckets (stepped approximation)

**Idea:** Add an **Extract Metric** on the Trio source that, for each `complication_get_timeline_called` log line, emits `data_age_seconds` (Int64) **only when not off-wrist** (e.g. `CASE WHEN message NOT LIKE '%battery_state=charging%' AND message NOT LIKE '%battery_state=unknown%' THEN toInt64OrNull(extract(...data_age_seconds=([0-9]+)...)) ELSE NULL END`). Use **Avg** or **Max** aggregation. On the dashboard, query with **1-minute** time grouping: `toStartOfInterval(dt, INTERVAL 1 MINUTE) AS time`, then `avgMerge(complication_data_age_seconds_avg)` or `maxMerge(complication_data_age_seconds_max)` per bucket. Chart time vs that value.

**Why it’s medium–high likelihood:** Produces a **stepwise** line: within each 1-minute bucket the value is constant (avg/max of GTL events in that minute); at minutes with a refresh the value drops. No interpolation (no + (bucket_epoch - gtl_epoch)), so it’s not a true sawtooth, but with sparse GTL (e.g. one every 5–15 minutes) the line can look jagged and “sawtooth-like”. Off-wrist events are excluded at extraction time so they don’t contribute to the metric.

**Validation for another agent:**  
- Confirm the metrics table stores `dt` at sufficient granularity for 1-minute grouping (ingestion typically keeps sub-hour resolution).  
- Confirm dashboard time picker / `{{time}}` can be set to 1-minute interval (or that a fixed 1-minute expression is allowed).  
- Verify Extract Metrics support: regex/extract on `raw`/message, and conditional emission (CASE WHEN … THEN value ELSE NULL).  
- **Risks:** Many buckets (e.g. 1440 per day) may hit limits or slow queries; avg over multiple GTLs in one minute can smooth away the “drop”; duplicate GTL at same second could double-count unless dedup is handled at extraction (e.g. by emitting only one value per “logical” event — unclear if Extract Metrics can dedupe by key).

---

### Option 4: Same as Option 3 with 5-minute (or larger) buckets (rougher proxy)

**Idea:** Same Extract Metric as Option 3, but dashboard uses **5-minute** (or 15-minute) grouping. One value per bucket = avg/max data age of GTL events in that window. Shape is a coarse “staleness over time” curve, not a fine sawtooth.

**Why it’s medium likelihood:** Easiest to implement once the metric exists; fewer points, less risk of hitting bucket limits. Clearly not a true sawtooth but may be “good enough” for “how stale did things look in each window.”

**Validation for another agent:** Same as Option 3 for the metric; confirm `toStartOfInterval(dt, INTERVAL 5 MINUTE)` (or similar) is valid in dashboard charts and that the chart renders multiple points.

---

### Option 5: Max data age per bucket (worst-case proxy)

**Idea:** Extract Metric: for each GTL (on-wrist only), emit `data_age_seconds` with **Max** aggregation. Dashboard: per bucket, `maxMerge(complication_data_age_seconds_max)`. Interpret as “maximum data age observed in this bucket.” Peaks when a GTL had high age; drops when a refresh happens in the bucket. Visually jagged but not interpolated.

**Why it’s medium likelihood:** Conveys “worst staleness in the window”; may resemble a sawtooth if buckets are small and GTL rate is low. Same validation as Option 3 for extraction and bucket granularity.

---

### Option 6: Two metrics — sum(data_age) and count(GTL) — then ratio per bucket

**Idea:** Extract Metric 1: `data_age_seconds` (Sum) when on-wrist. Metric 2: already have `complication_get_timeline_called_count` (Sum). Dashboard: per bucket, `sumMerge(complication_data_age_seconds_sum) / sumMerge(complication_get_timeline_called_count_sum)` = average data age in the bucket. One point per bucket; no interpolation.

**Why it’s lower likelihood for a sawtooth:** Ratio is an average; it smooths out the sharp drops. Might still show a trend. Validate: division by zero when no GTL in bucket (use `if(count > 0, sum/count, NULL)` or similar).

---

### Option 7: “Last value” in bucket (if supported by pipeline)

**Idea:** If Better Stack’s Extract Metrics support a **“last value”** or **“latest value”** aggregation (e.g. value of the last event in each ingestion bucket), emit `data_age_seconds` with that aggregation. Dashboard would then show “age at end of each bucket.” Still no interpolation within the bucket, but closer to “recency at a point in time” than avg/max.

**Why it’s medium likelihood only if supported:** `betterstack-guide.md` lists sum, count, avg, max, quantiles — not “last” or “latest.” Another agent should confirm in current Better Stack docs/API whether any such aggregation exists. If yes, this could improve Option 3/4/5.

---

### Option 8: Quantiles of data_age per bucket (P50/P95 band)

**Idea:** Extract `data_age_seconds` with **quantiles** aggregation (if supported). Dashboard: per bucket, e.g. P50 and P95. Chart two series (P50, P95) over time. Conveys “typical vs worst” recency in the bucket; not a sawtooth but a band.

**Why it’s lower likelihood for a sawtooth:** Shape is a band, not a single tooth. Validate quantiles support for this metric type and that the dashboard can plot multiple series.

---

### Option 9: Custom client or proxy that runs Explore and renders the chart

**Idea:** Build a small service or script that calls Better Stack’s **Explore API** (if available), runs the existing sawtooth query, fetches (time, value) rows, and renders a chart (e.g. in an iframe or custom dashboard tile). The “dashboard” then contains a link or embed to this view.

**Why it’s medium likelihood:** Fidelity is exact (same query as Explore). Depends on: (1) Explore API existing and allowing ad-hoc query execution, (2) dashboard supporting custom/iframe tiles or link-out. Another agent should verify API and dashboard capabilities.

---

### Option 10: Single number or sparkline (no sawtooth, “current recency” only)

**Idea:** Don’t replicate the sawtooth. Extract `data_age_seconds` (e.g. Max). Dashboard: one **number** or **sparkline** = “max (or last) data age in the selected period” or “in the last 5 minutes.” Useful as a KPI; not a time-series sawtooth.

**Why it’s high likelihood of working:** Fits standard metric + dashboard patterns. Clearly does not achieve “sawtooth on dashboard” but is a fallback if all time-series options are too limited.

---

## 4. Suggested order for validation

| Order | Option | Goal | What to validate |
|-------|--------|------|-------------------|
| 1 | Embed/link Explore | Exact sawtooth on dashboard | UI/docs: embed Explore, shared time range |
| 2 | Precompute + ingest | True sawtooth as metric | API: push/custom metrics, schema |
| 3 | data_age metric + 1-min buckets | Stepped approximation | 1-min grouping, extract conditional metric |
| 4 | data_age metric + 5-min buckets | Coarse proxy | Same as 3, 5-min grouping |
| 5 | Max data age per bucket | Worst-case proxy | Max aggregation, small buckets |
| 6 | Sum(age)/count(GTL) ratio | Average staleness | Two metrics, division, null handling |
| 7 | “Last value” in bucket | Point-in-time proxy | Docs: last/latest aggregation |
| 8 | Quantiles (P50/P95) | Band, not sawtooth | Quantiles for this metric, multi-series |
| 9 | Custom client + Explore API | Exact chart via external app | Explore API, embed/iframe |
| 10 | Single number / sparkline | KPI only | Standard metric + number chart |

---

## 5. Cross-references for the reviewing agent

- **Current Explore sawtooth query (full SQL):** `docs/completed/betterstack/betterstack-complication-dashboard-setup.md`, section “Complication Visible Recency (Sawtooth) — Explore only”.
- **Dashboard vs Explore, metrics schema, Extract Metrics:** same doc, sections “Why No source variables…”, “Step 1: Add Extract Metrics”, “Step 2: Dashboard queries”, “Limitations”.
- **Extract Metrics API and aggregation types:** `docs/process/betterstack-guide.md` (metrics extraction rules, create metric example, aggregation types).
- **GTL log shape:** `event=complication_get_timeline_called`, message includes `data_age_seconds=N`, `battery_state=charging|unplugged|unknown`. Off-wrist = charging or unknown; dedup by `dt` with `max(is_off_wrist)`.

If the reviewing agent finds that Better Stack’s product has changed (e.g. new aggregation type, or Explore embed), re-order the list and note the finding in the same doc or a short follow-up.

---

## 6. Implementation plan: instrumentation-based 5-min proxy (v1)

**Status:** Design complete; implementation not started.  
**Design note:** `docs/in-progress/complication-freshness/sawtooth-dashboard-instrumentation-design.md` (full verdict, schema, example logs, metric definition, validation checklist).

### Goal

Enable a **5-minute bucket proxy** of complication visible recency on the dashboard by changing Trio instrumentation so each GTL log emits a dashboard-ready value (`visible_recency_at_bucket_end_seconds`) instead of relying on ASOF over raw logs. Exact 1-minute sawtooth from instrumentation alone is not achievable without a periodic process (e.g. every-minute background task), which watchOS does not guarantee.

### Approach summary

1. **Persist** in App Group UserDefaults (TrioComplicationDataStore): `last_gtl_epoch_seconds`, `last_gtl_data_age_seconds`. After each getTimeline log, write current getTimeline epoch and data_age_seconds for the next invocation.
2. **At each getTimeline (before log):** Read previous_gtl_epoch and previous_data_age_seconds; compute 5-min bucket end containing current getTimeline time; compute `visible_recency_at_bucket_end_seconds` = off-wrist → 0, else previous_data_age + (bucket_end - previous_gtl_epoch) (when no previous, use current_data_age_seconds).
3. **Off-wrist at log time:** Provider (TrioWatchComplication) must pass `isOffWrist` into the store (e.g. from `WKInterfaceDevice.current().batteryState` == charging or unknown) so the store can set the bucket-end value to 0.
4. **Log:** Add to existing GTL log line: `previous_gtl_epoch_seconds`, `previous_data_age_seconds` (when available), `visible_recency_at_bucket_end_seconds`.
5. **Better Stack:** New Extract Metric on Trio source: extract `visible_recency_at_bucket_end_seconds` (Max aggregation). Dashboard chart: `toStartOfInterval(dt, INTERVAL 5 MINUTE)` grouped, `maxMerge(complication_visible_recency_at_bucket_end_seconds_max)`.

### Trio code touchpoints (factual)

- **TrioComplicationDataStore** (`Trio Watch Shared/TrioComplicationDataStore.swift`): UserDefaults keys in §198–208 (e.g. `lastReloadRequestEpochSecondsKey`); `logWidgetGetTimelineInvocation` at ~1002–1030; App Group defaults via `appGroupDefaults`. Add keys for last GTL epoch/age; extend `logWidgetGetTimelineInvocation` to accept `isOffWrist: Bool`, read previous from defaults, compute bucket-end value, append new fields, then write current epoch/age to defaults.
- **TrioWatchComplication** (`Trio Watch Complication/TrioWatchComplication.swift`): `getTimeline` at ~163–252; calls `store.logWidgetGetTimelineInvocation(...)` at ~220. Before that call, obtain `WKInterfaceDevice.current().batteryState`; set `isOffWrist = (state == .charging || state == .unknown)`; pass into the store.
- **ComplicationLogBuffer** (`Trio Watch Shared/ComplicationLogBuffer.swift`): Appends battery context to messages in `append`; no change required for the new fields (they are part of the message built by the store).

### Better Stack validation (before implementation)

- Confirm metric extraction supports `replaceRegexpOne` (or equivalent) on `raw`/message and that the resulting column is available as `*_max` for maxMerge.
- Confirm dashboard chart can use `toStartOfInterval(dt, INTERVAL 5 MINUTE)` and that `dt` aligns with log receipt time (UTC).

### Risks and gaps

- **Gaps:** Buckets with no getTimeline call (WidgetKit budget, or no run) have no value. Off-wrist buckets get 0 only when a GTL runs in that bucket; if no GTL while charging, bucket remains empty.
- **Retroactive processing:** New metric applies by default only to logs that arrive after the metric is created. **Retroactive processing** (reprocessing historical logs so the new metric is backfilled) is **possible via the Better Stack UI**, as far back as data retention allows (current plan: 8 days).
