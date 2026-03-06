# Better Stack Guide for AI Agents

> Version 1.0 — 2026-03-06

This document captures operational knowledge for working with Better Stack (metrics, dashboards, logs) in the Trio project. It supplements the log-querying instructions already in `AGENTS.md`.

---

## Authentication

The Better Stack API token is stored in `.trio-env` as `BETTERSTACK_API_TOKEN`. Use it for direct REST API calls. The same token is also configured in Cursor's MCP settings for the `user-better-stack` MCP server.

```bash
# Read token from .trio-env (never echo or log it)
source .trio-env
# Use in API calls
curl -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" ...
```

**Never print, log, or persist the token in output, commits, or responses.**

### Key IDs

| Resource | ID |
|---|---|
| Team | `491594` |
| Source (Trio) | `1659391` |
| Source (Nightscout) | `1659378` |
| Dashboard (Complication Freshness) | `689533` |

---

## Metrics Extraction Rules (REST API)

The MCP server does **not** support creating or managing metric extraction rules. Use the REST API directly.

### API endpoints

| Action | Method | URL |
|---|---|---|
| List metrics | `GET` | `/api/v2/sources/{source_id}/metrics` |
| Create metric | `POST` | `/api/v2/sources/{source_id}/metrics` |
| Update metric | `PATCH` | `/api/v2/sources/{source_id}/metrics/{metric_id}` |
| Delete metric | `DELETE` | `/api/v2/sources/{source_id}/metrics/{metric_id}` |

Base URL: `https://telemetry.betterstack.com`

### Create metric example

```bash
curl -X POST \
  "https://telemetry.betterstack.com/api/v2/sources/1659391/metrics" \
  -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "metric",
    "attributes": {
      "name": "generation_delta_eq0",
      "sql": "CASE WHEN toInt32OrNull(extract(JSONExtractString(raw, '\''message'\''), '\''generation_delta=([^ ]+)'\'')) = 0 THEN 1 ELSE 0 END",
      "type": "sum"
    }
  }'
```

### Extraction rule design patterns

- **Regex on structured log fields:** `extract(JSONExtractString(raw, 'message'), 'field_name=([^ ]+)')`
- **Bucket metrics (CASE WHEN):** Use `toInt32OrNull()` on extracted values, then CASE WHEN for bucket ranges.
- **Aggregation types:** `sum`, `count`, `avg`, `max`, `quantiles` — these map to ClickHouse `sumState()`, `countState()`, etc.
- **Boolean/string fields as dimensions:** Extract string fields (e.g., `provider_restart`, `app_group_available`) to enable `countMergeIf()` in dashboard queries.

### Critical: extraction rules are NOT retroactive

Extraction rules only process events that arrive **after** the rule is created. Historical data is not reprocessed. The UI has a "reprocess" option; the API does **not** support this (confirmed 2026-03-06).

**Implication:** If you need metrics over historical data, you must either:
- Use pre-existing metrics that were created before the data arrived.
- Query raw logs directly via `telemetry_query`.
- Wait for new data to flow through the new extraction rules.

---

## Dashboards

### MCP tools for dashboards and charts

Use the Better Stack MCP server (`user-better-stack`) for most dashboard operations:

| Task | MCP Tool |
|---|---|
| List dashboards | `telemetry_list_dashboards_tool` |
| Get dashboard details | `telemetry_get_dashboard_details_tool` |
| Export dashboard (full JSON) | `telemetry_export_dashboard_tool` |
| Create chart | `telemetry_create_chart_tool` |
| Edit chart | `telemetry_edit_chart_tool` |
| Remove chart | `telemetry_remove_chart_tool` |
| Get chart details | `telemetry_get_chart_details_tool` |
| Chart building instructions | `telemetry_get_chart_building_instructions_tool` |

### MCP chart editing — supported and unsupported fields

`telemetry_edit_chart_tool` accepts: `id`, `name`, `chart_type`, `query`, `source_variable`, `settings`.

**NOT supported by MCP:**
- `explanation` (the "Explanation (optional)" tooltip in the UI) — this is a top-level chart field that the MCP tool cannot set.
- Direct chart CRUD via public REST API — no `/api/v2/charts/{id}` endpoint exists.

**Workarounds found:**
- `settings.description` can be set via the MCP tool (persists in the API, but maps to a different internal field than `explanation`).
- For static text charts, set the `query` parameter to populate `chart_queries[0].static_text` (this is what the UI actually renders).

### Dashboard import/export workflow

This is the only way to programmatically set `explanation` on charts and to do bulk dashboard updates:

1. **Export** the current dashboard:
   ```bash
   # Via MCP
   telemetry_export_dashboard_tool(id: 689533)
   # Or save to file for version control
   ```

2. **Edit** the JSON file (e.g., `docs/dashboard.json`) — update queries, explanations, settings, etc.

3. **Import** as a new dashboard via REST API:
   ```bash
   curl -X POST \
     "https://telemetry.betterstack.com/api/v2/dashboards/import" \
     -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "$(cat docs/dashboard.json)"
   ```

**Import file format:** The POST body must be `{"name": "Dashboard Name", "data": {<dashboard_data>}}`. Two approaches:
- If the file already has `name` and `data` keys at the top level (like after an export), cat it directly.
- If the file contains only the data portion, wrap it: `--data '{"name": "My Dashboard", "data": '"$(cat data-only.json)"'}'`

**Import always creates a NEW dashboard** — it does not update an existing one. After verifying the import, delete the old dashboard if desired.

### Dashboard JSON version control

The canonical dashboard export is stored at `docs/dashboard.json`. When making dashboard changes:
1. Make changes (via MCP tools or UI).
2. Export and save to `docs/dashboard.json`.
3. This file can be re-imported to recreate the dashboard from scratch.

### Dashboard query patterns

- **Source variable:** Always use `FROM {{source}}` (never hardcode table names like `remote(t491594_trio_metrics)`).
- **Time variables:** `{{time}}`, `{{start_time}}`, `{{end_time}}` for time axis and filtering.
- **Read aggregated metrics:** `sumMerge()`, `countMerge()`, `quantilesMerge()`, `maxMerge()`, `avgMerge()`.
- **Conditional counting:** `countMergeIf(events_count, field = 'value')`.
- **NULL handling:** `coalesce(sumMerge(metric), 0)` — extracted metrics return NULL when no data exists for a time bucket.
- **Time bucketing:** `toStartOfInterval(dt, INTERVAL 60 MINUTE) AS time` for hourly buckets.
- **Percentiles:** `quantilesMerge(0.5, 0.9, 0.95, 0.99)(metric_quantiles)[1]` — 1-indexed array.

### Known quirks

- **`name` column is empty for extracted metrics.** Dashboard queries should NOT filter with `AND name = 'metric_name'` or `AND name IN (...)` — extracted metrics are stored as distinct columns, not rows with a name.
- **Concurrent chart removals can deadlock.** Remove charts sequentially, not in parallel.
- **Import creates empty dashboards if the data structure is wrong.** Verify the `charts` array is populated in the import payload.

---

## Changelog

| Version | Date | Summary |
|---|---|---|
| 1.0 | 2026-03-06 | Initial guide covering metrics API, dashboard import/export, MCP tool capabilities and limitations, query patterns, and key learnings from Phase 0.2 implementation. |
