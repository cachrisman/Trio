# Better Stack: Complication dashboard (Phase 0.2) setup

**Version:** 1.3  
**Last updated:** 2026-03-16

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-13 | Initial doc — extract metrics setup, dashboard chart queries, per-event latency Explore pattern |
| 1.1 | 2026-03-16 | Added Complication Visible Recency sawtooth Explore query (initial version using saves CTE) |
| 1.2 | 2026-03-16 | Rewrote sawtooth query: switched from saves CTE to `logged_data_age` from GTL event directly; added off-wrist detection (`charging` + `unknown` battery states) via sentinel `-1` pattern; fixed deduplication via `GROUP BY dt` + `max(is_off_wrist)`; fixed sentinel bleed-through with `CASE WHEN matched_data_age = -1` in final SELECT; added 3-hour lookback with `{{start_time}}`-anchored bucket grid |
| 1.3 | 2026-03-16 | Tightened sawtooth section: exact Explore sawtooth cannot be represented natively in the dashboard metrics model; a proxy or externally precomputed series may still be possible |

---

## Why "No source variables" and "Missing columns: raw"?

Better Stack **dashboards do not query raw logs**. They query a **unified metrics table**:

- The dashboard `{{source}}` variable points to this metrics table (e.g. `remote(t491594_trio_metrics)`).
- That table has **no `raw` column** and no per-log `message` field. It has: `dt`, `name`, `_row_type`, `events_count`, `value_avg`, `tags`, etc.
- So you **must** put the complication data into that metrics pipeline by defining **Extract Metrics** (labels + metrics) on the Trio source. Then dashboard charts use `FROM {{source}}`, `countMerge(events_count)`, and `label('...')`.

There is no dashboard option to "use logs instead of metrics" — the product expects you to extract what you need from logs into the metrics schema, then build charts from that.

Ref: [Writing SQL queries](https://betterstack.com/docs/logs/dashboards/sql-queries), [Extracting metrics from logs](https://betterstack.com/docs/logs/dashboards/logs-to-metrics/), [Schema migration Feb '26](https://betterstack.com/docs/logs/unifying-metrics-schema/).

---

## Step 1: Add Extract Metrics on the Trio source

Go to **Better Stack → Sources → Trio → Configure → Extract Metrics** (or **Logs to metrics**).

**Important:** The dashboard avoids `tags` / `label()` because Better Stack’s pipeline applies `arrayElement` to tag access and fails when tag values are strings. So we use **named metrics only** (query by `name = '...'` and `sumMerge(value_sum)`). Add the metrics below; you can skip or remove the old labels.

**Type:** Use **Int64** for all count/bucket metrics; **Aggregation:** **Sum** so we can count events.

### 1) Metric: `complication_reload_requested_count`

- **Type:** **Int64** · **Aggregation:** **Sum**
- **SQL expression:**

```sql
if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_reload_requested%', 1, 0)
```

### 2) Metric: `complication_get_timeline_called_count`

- **Type:** **Int64** · **Aggregation:** **Sum**
- **SQL expression:**

```sql
if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%', 1, 0)
```

### 3) Metrics: Latency buckets (one per bucket)

Add five metrics with **Type Int64**, **Aggregation Sum**, and these exact **names** and **SQL expressions**:

| Name | SQL expression |
|------|-----------------|
| `complication_latency_le2` | `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%' AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) <= 2, 1, 0)` |
| `complication_latency_2_10` | `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%' AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) > 2 AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) <= 10, 1, 0)` |
| `complication_latency_10_60` | `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%' AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) > 10 AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) <= 60, 1, 0)` |
| `complication_latency_60_300` | `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%' AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) > 60 AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) <= 300, 1, 0)` |
| `complication_latency_gt300` | `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%' AND toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) > 300, 1, 0)` |

### 4) Metric: `complication_latency_seconds`

- **Type:** **Int64**
- **Purpose:** Latency (seconds) for getTimeline events, for avg-over-time, “worst” table, and scatter.
- **Aggregation functions:** At least **Avg** (required for current charts). You can also enable **Max**, **P50**, **P95**, **P99** for worst-table and percentile charts. If your plan supports **quantile** or **histogram**, add that for p50/p95/p99. Adding **max** is optional (then you can change the “Worst” table query to use `maxMerge(value_max)` for true worst buckets).
- **SQL expression:**

```sql
toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1'))
```

- **Metric name:** `complication_latency_seconds`

Save the source configuration. New logs will be processed into the metrics table; it may take a short while before charts show data.

---

## Step 2: Dashboard queries (pre-aggregated columns, no `name` filter)

The metrics table is **pre-aggregated**: each metric has its own column. Do **not** filter by `name`; select those columns directly. The dashboard uses:

- **Sum metrics:** `sumMerge(complication_reload_requested_count_sum)`, `sumMerge(complication_get_timeline_called_count_sum)`, and the five bucket columns `complication_latency_le2_sum` … `complication_latency_gt300_sum`. The column is already suffixed with `_sum`; use `sumMerge(column)` (e.g. `sumMerge(complication_reload_requested_count_sum)`), not a double `_sum`.
- **Latency (avg):** `avgMerge(complication_latency_seconds_avg)`.

Example (line chart):  
`SELECT {{time}} AS time, sumMerge(complication_reload_requested_count_sum) AS "Reload requested", sumMerge(complication_get_timeline_called_count_sum) AS "getTimeline called" FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ORDER BY time`

Using the wrong Merge (e.g. `sumMerge` on an avg column) causes Code 43; always match the Merge to the column: **sum** → **sum**, **avg** → **avg**.

After Step 1 is done, refresh the dashboard.

---

## Individual latency values (simple line chart)

**In the dashboard:** Charting uses the **metrics table** only. The `complication_latency_seconds` metric is stored as **aggregates** (avg, max, p50, p90, p95), so you cannot plot raw per-event values there. You can only plot those aggregates over time, for example:

- **Simple line:** one series = `avgMerge(complication_latency_seconds_avg)` (and optionally more series for `maxMerge(complication_latency_seconds_max)`, or quantile merges for p50/p95). That gives one point per time bucket (e.g. per 5 minutes), not one point per event.

**Per-event latencies:** To see a line (or scatter) of **individual** `complication_latency_seconds` values, use **Explore** (raw logs), not the dashboard. In Explore, the source has a `raw` column; you can run SQL that returns one row per getTimeline event with time and latency, then use the built-in visualization (e.g. line or scatter). Example pattern:

```sql
SELECT
  dt AS time,
  toInt64OrNull(replaceRegexpOne(JSONExtract(raw, 'message', 'Nullable(String)'), '.*latency_seconds=([0-9]+).*', '\\1')) AS latency_seconds
FROM <your_logs_table>
WHERE dt BETWEEN <start> AND <end>
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%latency_seconds=%'
ORDER BY time
```

Replace `<your_logs_table>` and time bounds with the placeholders or table name that Explore provides (e.g. `remote(...)` or the logs table from the source). That result set is one row per event; you can chart **time** (x) vs **latency_seconds** (y) as a line or scatter in Explore.

---

## Dashboard summary (Trio • Complication Freshness Phase 0.2)

Dashboard ID **689533**. All charts use `FROM {{source}}` (or `{{source:trio}}`) and `dt BETWEEN {{start_time}} AND {{end_time}}` unless noted. Time grouping uses `{{time}}` (dashboard default) unless a fixed interval is shown.

### Section 1: Volume & Reload Efficiency

| Chart | Type | Query |
|-------|------|--------|
| **Reload requests vs getTimeline calls** | line | `SELECT {{time}} AS time, sumMerge(complication_reload_requested_count_sum) AS "Reload requested", sumMerge(complication_get_timeline_called_count_sum) AS "getTimeline called" FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ORDER BY time` |
| **60s < Latency < 300s** | text | CTE returns `calls`, `between_60_300`, `over_300`, `events`, `rate`. Chart displays templated text (e.g. `{{rate}}% getTimeline calls >60s`, `{{events}} / {{calls}}`). Query: `WITH totals AS ( SELECT sumMerge(complication_latency_60_300_sum) AS between_60_300, sumMerge(complication_latency_gt300_sum) AS over_300, sumMerge(complication_get_timeline_called_count_sum) AS calls FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} ) SELECT calls, between_60_300, over_300, (between_60_300 + over_300) AS events, if(calls > 0, round((between_60_300 + over_300) * 100.0 / calls, 2), 0) AS rate FROM totals` |
| **Latency > 300s** | text | CTE same as above; returns `calls`, `between_60_300`, `over_300` (aliased as `events`), `rate` (percent >300s). Chart template e.g. `{{rate}}% getTimeline calls >300s`. Query: `WITH totals AS ( SELECT sumMerge(complication_latency_60_300_sum) AS between_60_300, sumMerge(complication_latency_gt300_sum) AS over_300, sumMerge(complication_get_timeline_called_count_sum) AS calls FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} ) SELECT calls, between_60_300, over_300 AS events, if(calls > 0, round(over_300 * 100.0 / calls, 2), 0) AS rate FROM totals` |
| **Max Latency** | number | `SELECT maxMerge(complication_latency_seconds_max) AS value FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}}` |
| **Reload efficiency (req/update)** | number | `SELECT if(reload_count > 0, reload_count / get_timeline_count , 0) AS value FROM ( SELECT sumMerge(complication_reload_requested_count_sum) AS reload_count, sumMerge(complication_get_timeline_called_count_sum) AS get_timeline_count FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} )` |
| **Reload requested (count)** | number | `SELECT sumMerge(complication_reload_requested_count_sum) AS value FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}}` |
| **getTimeline called (count)** | number | `SELECT sumMerge(complication_get_timeline_called_count_sum) AS value FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}}` |

### Section 2: Burstiness

| Chart | Type | Query |
|-------|------|--------|
| **Reloads per 5-minute bucket** | line | `SELECT toStartOfInterval(dt, INTERVAL 5 MINUTE) AS time, sumMerge(complication_reload_requested_count_sum) AS reloads_5m FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ORDER BY time` |
| **P95 burstiness** | number | `WITH buckets AS ( SELECT toStartOfInterval(dt, INTERVAL 5 MINUTE) AS time, sumMerge(complication_reload_requested_count_sum) AS reloads_5m FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ) SELECT quantile(0.95)(reloads_5m) AS p95_reload_burst_5m FROM buckets` (chart uses `value_columns`: `["p95_reload_burst_5m"]`) |
| **Burst Windows Count** | number | `WITH buckets AS ( SELECT toStartOfInterval(dt, INTERVAL 5 MINUTE) AS time, sumMerge(complication_reload_requested_count_sum) AS reloads_5m FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ) SELECT countIf(reloads_5m >= 3) AS burst_windows_ge_3 FROM buckets` |
| **Max burst in any 5-minute bucket** | number | `WITH buckets AS ( SELECT toStartOfInterval(dt, INTERVAL 5 MINUTE) AS time, sumMerge(complication_reload_requested_count_sum) AS reloads_5m FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ) SELECT max(reloads_5m) AS max_reload_burst_5m FROM buckets` |

### Section 3: Latency health

| Chart | Type | Query |
|-------|------|--------|
| **Avg & Max & P50/P90/P95 Latency (s) over time** | line | Uses **30-minute** buckets. Quantiles: `quantilesMerge(0.5, 0.9, 0.95, 0.99)(complication_latency_seconds_quantiles)[1]` P50, `[2]` P90, `[3]` P95. `SELECT toStartOfInterval(dt, INTERVAL 30 MINUTE) AS time, avgMerge(complication_latency_seconds_avg) AS "Avg", maxMerge(complication_latency_seconds_max) AS "Max", quantilesMerge(0.5, 0.9, 0.95, 0.99)(complication_latency_seconds_quantiles)[1] AS "P50", quantilesMerge(0.5, 0.9, 0.95, 0.99)(complication_latency_seconds_quantiles)[2] AS "P90", quantilesMerge(0.5, 0.9, 0.95, 0.99)(complication_latency_seconds_quantiles)[3] AS "P95" FROM {{source:trio}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ORDER BY time` |
| **Latency buckets per hour** | bar (stacked) | Uses **1-hour** buckets. `SELECT toStartOfInterval(dt, INTERVAL 1 HOUR) AS time, sumMerge(complication_latency_le2_sum) AS "≤2s", sumMerge(complication_latency_2_10_sum) AS "2-10s", sumMerge(complication_latency_10_60_sum) AS "10-60s", sumMerge(complication_latency_60_300_sum) AS "60-300s", sumMerge(complication_latency_gt300_sum) AS ">300s" FROM {{source}} WHERE dt BETWEEN {{start_time}} AND {{end_time}} GROUP BY time ORDER BY time` |
| **Complication Reload Latency** | bar (horizontal) | Single-period totals per bucket. Query uses `arrayJoin` over the five bucket labels and `sumMerge(complication_latency_*_sum)`; chart shows bucket vs value. Same pattern as in previous summary. |

---

## Limitations

- **Tags/labels:** The metrics pipeline applies `arrayElement` to any `tags['key']` or `label('key')` access; string tag values cause Code 43. The dashboard uses **only pre-aggregated metric columns** (no labels, no `name` filter), e.g. `sumMerge(complication_reload_requested_count_sum)`.
- For per-event latency inspection (e.g. worst latencies, scatter), the metrics table does not store full raw log rows; use **Explore** (raw logs) with the same filters.
- **Historical coverage:** `{{source}}` typically includes both recent and historical data that Better Stack has aggregated; exact coverage depends on your plan and retention.

---

## Complication Visible Recency (Sawtooth) — Explore only

The **exact** Explore sawtooth (per-minute interpolated recency, off-wrist flat) **cannot be represented natively** in the dashboard metrics model: dashboard charts use bucket-aggregated metrics and stateless aggregation (sum/count/avg/max/quantiles), while the sawtooth requires point-in-time logic (ASOF JOIN) and interpolation. This chart therefore lives in **Explore** (raw logs) permanently. A **proxy** (e.g. 5-minute bucket metric from instrumentation) or an **externally precomputed** series may still be possible for the dashboard; see `docs/in-progress/complication-freshness/sawtooth-dashboard-options.md` and `sawtooth-dashboard-instrumentation-design.md` for options.

**What it shows:** The data age visible on the watch complication at any given minute — i.e. direct user experience. Produces a sawtooth: age grows at 1 s/s between `getTimeline` calls, drops at each refresh. Off-wrist periods (charging, watch extension restarts) show as a zero line.

**UI time range:** The query responds to the Explore time picker via `{{start_time}}`/`{{end_time}}`. The `time_bounds` CTE is required to make BetterStack wire up the time picker variables in a complex multi-CTE query — without it the picker renders but does not trigger a re-query.

**Max range:** 3 days (`numbers(4320)` = 4320 one-minute buckets).

```sql
WITH
  time_bounds AS (
    SELECT
      toUnixTimestamp({{start_time}}) AS t_start,
      toUnixTimestamp({{end_time}}) AS t_end
  ),
  gtl AS (
    SELECT
      dt AS gtl_dt,
      toUnixTimestamp(dt) AS gtl_epoch,
      max(
        JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%battery_state=charging%'
        OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%battery_state=unknown%'
      ) AS is_off_wrist,
      argMaxIf(
        toInt64OrNull(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'data_age_seconds=([0-9]+)')),
        toInt64OrNull(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'data_age_seconds=([0-9]+)')),
        NOT (
          JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%battery_state=charging%'
          OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%battery_state=unknown%'
        )
      ) AS logged_data_age
    FROM {{source}}
    CROSS JOIN time_bounds
    WHERE dt BETWEEN {{start_time}} - INTERVAL 3 HOUR AND {{end_time}}
      AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=complication_get_timeline_called%'
    GROUP BY dt
  ),
  gtl_with_age AS (
    SELECT
      gtl_dt,
      gtl_epoch,
      if(is_off_wrist, -1, logged_data_age) AS data_age_seconds,
      1 AS _k
    FROM gtl
    WHERE is_off_wrist = 1 OR logged_data_age IS NOT NULL
  ),
  min_max AS (
    SELECT
      toUnixTimestamp({{start_time}}) AS min_ep,
      max(gtl_epoch) AS max_ep
    FROM gtl_with_age
  ),
  min_max_with_count AS (
    SELECT min_ep, max_ep, toUInt32((max_ep - min_ep) / 60) + 1 AS n_buckets
    FROM min_max
  ),
  buckets AS (
    SELECT
      toDateTime(m.min_ep - m.min_ep % 60 + number * 60, 'UTC') AS bucket_dt,
      m.min_ep - m.min_ep % 60 + number * 60 AS bucket_epoch,
      1 AS _k
    FROM min_max_with_count m
    CROSS JOIN numbers(4320)
    WHERE number < m.n_buckets
  ),
  result AS (
    SELECT
      b.bucket_dt AS time,
      g.data_age_seconds AS matched_data_age,
      g.data_age_seconds + (b.bucket_epoch - g.gtl_epoch) AS value
    FROM buckets b
    ASOF LEFT JOIN gtl_with_age g ON b._k = g._k AND b.bucket_epoch >= g.gtl_epoch
  )
SELECT time, CASE WHEN matched_data_age = -1 THEN 0 ELSE if(value < 0, 0, value) END AS value
FROM result
ORDER BY time ASC
```

**Design notes:**

- **Off-wrist detection:** Both `battery_state=charging` and `battery_state=unknown` are treated as off-wrist. `unknown` appears exclusively on `provider_restart=true` GTL events (watch extension cold restart), always off-wrist. Off-wrist epochs get `data_age_seconds = -1` as a sentinel.
- **Deduplication:** Every GTL event is logged twice (two subsystems). `GROUP BY dt` with `max(is_off_wrist)` ensures that if any duplicate at a given timestamp is off-wrist, the whole epoch is treated as off-wrist. `argMaxIf` picks `logged_data_age` only from non-off-wrist rows.
- **Final SELECT:** `CASE WHEN matched_data_age = -1 THEN 0` checks the sentinel *before* arithmetic. Using `if(value < 0, 0, value)` alone is insufficient — `(bucket_epoch - gtl_epoch)` can push a `-1` sentinel positive if the bucket is far enough from the GTL epoch, allowing charging periods to bleed through as teeth.
- **3-hour lookback:** `gtl` fetches from `{{start_time}} - INTERVAL 3 HOUR` so that if the window starts mid-tooth, the GTL that established the current age is included. `min_max` anchors `min_ep` to `{{start_time}}` so the bucket grid starts at the UI window, not 3 hours earlier.
- **`logged_data_age`:** Uses `data_age_seconds` logged directly in the GTL event rather than recomputing from saves. More accurate — avoids cross-device App Group read issues that inflate computed values.
- **`numbers(4320)`** supports up to 3 days. Do not increase beyond this without considering query cost.
- **`time_bounds` CTE** is required for the Explore UI time picker to wire up `{{start_time}}`/`{{end_time}}` in a multi-CTE query. Without it the picker renders but does not trigger re-query.