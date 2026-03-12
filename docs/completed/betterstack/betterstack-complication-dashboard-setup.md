# Better Stack: Complication dashboard (Phase 0.2) setup

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
