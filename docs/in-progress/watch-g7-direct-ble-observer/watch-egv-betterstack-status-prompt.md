# Watch G7 Direct-BLE — EGV Status Check Prompt

**Version:** v1.1

**Purpose:** Recurring task prompt. Give this to an AI agent (Claude Code, etc.) to produce a structured EGV-coverage and watch-state health report from BetterStack telemetry. Run after each new TestFlight build soaks for at least 12 hours.

**Output:** A build-over-build status table, trend classifications (improving / stable / regressing), a per-build session-coverage breakdown, and a short plain-English summary of what to watch.

---

## Task

Query BetterStack telemetry for the Trio watch app and produce a Watch EGV Status Report. Follow the exact query sequence below; do not skip steps.

---

## 1. BetterStack connection details

- **MCP server:** `mcp__betterstack__telemetry_query`
- **Source ID:** `1659391`
- **Table:** `t491594.trio`
- **Hot collection (last ~30 min):** `remote(t491594_trio_logs)`
- **Cold collection (everything else):** `s3Cluster(primary, t491594_trio_s3)` — **always use this for historical queries**; filter with `_row_type = 1` for logs.
- **Retention:** 8 days. Data older than ~8 days is gone.
- **Platform:** `watchos` events only (watch app telemetry). Phone-side events also live in this source — filter by `platform='watchos'` or `category='WatchTelemetryRing'` to isolate watch-direct-BLE data.

---

## 2. Field extraction — CRITICAL

Most watch telemetry fields are **not top-level JSON**. The `raw` column contains a JSON blob whose `message` field is a key=value string like:

```
module=g7_ble sensor_name=DXCM4c event=did_connect scene_phase=background ext_session_active=false ...
```

**Top-level JSON fields** (safe to `JSONExtract` directly):
- `build` — build number string (e.g. `"214"`)
- `category` — log category (e.g. `"WatchTelemetryRing"`)
- `event` — event name (e.g. `"egv_received"`)
- `platform` — `"watchos"` for watch events
- `message` — the key=value string (extract sub-fields from here)

**Sub-fields inside `message`** — extract with `extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'key=(\\S+)')`:
- `module` — `g7_ble` (BLE adapter layer) or `g7_core` (sensor protocol layer, fork)
- `scene_phase` — `active` | `inactive` | `background` | `unknown`
- `ext_session_active` — `true` | `false`
- `reason` — present on some events (e.g. `no_runtime`, `running_not_near_expiry`, `debounced`)
- `sensor_name` — 6-char G7 identifier (e.g. `DXCM4c`)
- `g7_session` — session UUID or `nil`
- `seq` — monotonic sequence counter (useful for gap detection)
- `battery_level_percent` — watch battery %
- `age_s` — age in seconds (on reanchor events)

`unknown` scene_phase = event logged before BUG-F stamping was active (pre-build-212 or early in a build). Treat as "indeterminate" — do not count as background or active.

---

## 3. Query sequence

Run queries in this order. Each builds on the previous.

### Step 0 — Logging health check (run once before the main queries)

**Part A — WatchLogger pipeline drops**

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  max(toUInt64OrZero(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'logs_dropped_total=(\\S+)'))) AS logs_dropped_total,
  max(toUInt64OrZero(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'daily_write_failures_total=(\\S+)'))) AS daily_write_failures_total,
  max(toUInt64OrZero(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'daily_lines_dropped_total=(\\S+)'))) AS daily_lines_dropped_total,
  count(*) AS flush_count,
  max(dt) AS latest_flush
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'platform', 'Nullable(String)') = 'watchos'
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchLogger'
  AND JSONExtract(raw, 'event', 'Nullable(String)') = 'log_pipeline_summary'
GROUP BY build
ORDER BY build DESC
```

`GROUP BY build` + `max(toUInt64OrZero(...))` gives one row per build with the highest accumulated total seen across all flushes. Do not read a single-flush row — early flushes start at zero and totals only grow.

**Part B — WatchTelemetryRing ring drops (separate loss path)**

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  max(toUInt64OrZero(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'ring_dropped_total=(\\S+)'))) AS ring_dropped_total,
  max(toUInt64OrZero(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'ring_dropped=(\\S+)'))) AS ring_dropped_last_window
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'platform', 'Nullable(String)') = 'watchos'
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'build', 'Nullable(String)') IS NOT NULL
GROUP BY build
ORDER BY build DESC
```

The ring (512-entry, drop-oldest) stamps `ring_dropped` / `ring_dropped_total` on every emitted event. This is a **different loss path** from the WatchLogger pipeline: events dropped here never reach WatchLogger at all and will not show up in any BetterStack query — including Steps 2–6.

**Interpret both parts before continuing:**
- Part A `logs_dropped_total > 0` — WatchLogger's in-memory `logs` queue (cap 500 entries) overflowed; some events that passed through the ring were dropped before reaching BetterStack. EGV/session counts for this build are **lower bounds**. Flag in the report.
- Part A `daily_write_failures_total > 0` — on-device daily log had write errors; on-device file may be missing lines. The ring and BetterStack path are unaffected.
- Part A `daily_lines_dropped_total > 0` — daily log buffer overflowed; daily file is incomplete for those windows.
- Part B `ring_dropped_total > 0` — events were evicted from the 512-entry ring before WatchLogger could drain them. Affects structured G7 events (connects, EGVs, session events). BetterStack counts are lower bounds; the daily on-device file is also affected.
- **All zeros** = no detected drops. Counts are directional-accurate but not necessarily complete: **build 214 lacks flush-truncation accounting** (ships in build 215 via `177a6c723`); a single flush >256 KB can still silently drop overflow lines. Zero counters are necessary but not sufficient for full trust on build 214.
- **Pre-214 builds (≤213):** Part A's `extract()` returns `''` (empty string, coerced to 0 by `toUInt64OrZero`) for the `*_total` fields — they were not emitted. The counter was not instrumented; silent drops may have occurred. Treat Part A results as "uninstrumented," not "zero drops."

**Note:** `log_pipeline_summary` uses `category=WatchLogger`, not `category=WatchTelemetryRing`. All other queries in this prompt use `WatchTelemetryRing`. Run this step with the respective category filters as shown.

### Step 1 — Discover builds in window

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  min(dt) AS first_seen,
  max(dt) AS last_seen,
  count(*) AS total_events,
  dateDiff('hour', min(dt), max(dt)) AS duration_hours
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'build', 'Nullable(String)') IS NOT NULL
GROUP BY build
ORDER BY first_seen DESC
LIMIT 15
```

Take note of which builds have ≥6 hours of data — shorter windows are too noisy for yield comparisons. The latest build with ≥12 hours of data is the **primary analysis build**.

### Step 2 — Event inventory per build

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  JSONExtract(raw, 'event', 'Nullable(String)') AS event,
  count(*) AS n
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'build', 'Nullable(String)') IN ('<build_A>', '<build_B>', '<build_C>')
GROUP BY build, event
ORDER BY build DESC, n DESC
LIMIT 500
```

Replace `<build_A/B/C>` with the 3 most recent builds from Step 1. This is your event discovery table — use it for trend spotting and spotting new/missing events. **Do not use its `did_connect` counts as yield denominators** — both `g7_ble` and `g7_core` emit `did_connect` per physical connection; using unfiltered counts will double the true connect rate. Use Step 3 (module=g7_ble) for all yield calculations.

### Step 3 — EGV yield by session state (g7_ble module only)

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'ext_session_active=(\\S+)') AS ext_session_active,
  extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'scene_phase=(\\S+)') AS scene_phase,
  JSONExtract(raw, 'event', 'Nullable(String)') AS event,
  count(*) AS n
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'event', 'Nullable(String)') IN ('did_connect', 'egv_received')
  AND extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'module=(\\S+)') = 'g7_ble'
  AND extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'ext_session_active=(\\S+)') != ''
  AND JSONExtract(raw, 'build', 'Nullable(String)') IN ('<build_A>', '<build_B>', '<build_C>')
GROUP BY build, ext_session_active, scene_phase, event
ORDER BY build DESC, event, n DESC
```

The `ext_session_active != ''` filter drops events where BUG-F stamping wasn't active (pre-build-212 or very early in a build's first minutes). Without it, empty-string rows inflate "no-session" counts and deflate session coverage %.

### Step 4 — Session lifecycle

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  JSONExtract(raw, 'event', 'Nullable(String)') AS event,
  extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'reason=(\\S+)') AS reason,
  count(*) AS n
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND (
    JSONExtract(raw, 'event', 'Nullable(String)') LIKE 'ext_session%'
    OR JSONExtract(raw, 'event', 'Nullable(String)') LIKE 'reanchor%'
  )
  AND JSONExtract(raw, 'build', 'Nullable(String)') IN ('<build_A>', '<build_B>', '<build_C>')
GROUP BY build, event, reason
ORDER BY build DESC, event, n DESC
LIMIT 100
```

The `reanchor%` pattern captures v2 reanchor events (builds 214+). The `ext_session%` pattern covers v1 events (build 212) and ongoing session lifecycle events across all builds.

### Step 5 — Hourly coverage for the primary build (last 48 hours)

```sql
SELECT
  toStartOfHour(dt) AS hour,
  countIf(JSONExtract(raw, 'event', 'Nullable(String)') = 'egv_received') AS egvs,
  countIf(JSONExtract(raw, 'event', 'Nullable(String)') = 'did_connect') AS connects,
  countIf(JSONExtract(raw, 'event', 'Nullable(String)') = 'pre_egv_disconnect') AS pre_egv_disc,
  countIf(JSONExtract(raw, 'event', 'Nullable(String)') = 'ext_session_started') AS sessions_started
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 2 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'build', 'Nullable(String)') = '<primary_build>'
GROUP BY hour
ORDER BY hour ASC
LIMIT 50
```

Look for zero-EGV runs ≥2 hours — these are coverage gaps. Note whether they correlate with zero session starts (likely session-expiry gaps) or zero connects (possible sensor loss / not worn).

### Step 6 — Gating and error breakdown

```sql
SELECT
  JSONExtract(raw, 'build', 'Nullable(String)') AS build,
  JSONExtract(raw, 'event', 'Nullable(String)') AS event,
  extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'reason=(\\S+)') AS reason,
  count(*) AS n
FROM s3Cluster(primary, t491594_trio_s3)
WHERE
  _row_type = 1
  AND dt > now() - INTERVAL 8 DAY
  AND JSONExtract(raw, 'category', 'Nullable(String)') = 'WatchTelemetryRing'
  AND JSONExtract(raw, 'event', 'Nullable(String)') IN (
    'ble_gated', 'connect_gated', 'connect_skipped', 'connect_timeout',
    'auth_notify_failed', 'command_timeout', 'sensor_error',
    'direct_ble_stall_detected', 'configure_retry_scheduled', 'configure_retry_abandoned',
    'pre_egv_disconnect'
  )
  AND JSONExtract(raw, 'build', 'Nullable(String)') IN ('<build_A>', '<build_B>', '<build_C>')
GROUP BY build, event, reason
ORDER BY build DESC, event, n DESC
LIMIT 200
```

---

## 4. Metrics to compute

After running the queries, compute the following for each build. Always **normalize by build duration (hours)** before comparing across builds.

**Drop-flag gate (from Step 0):** If Step 0 shows `logs_dropped_total > 0` or `ring_dropped_total > 0` for a build, annotate all yield and session figures for that build as **lower bounds** in every table. Do not include that build in trend comparisons as if its counts are exact — flag it separately in Flagged Issues.

### EGV yield table (g7_ble only)

For each build, compute from Step 3 results:

| Metric | Formula |
|---|---|
| **Session-active connects** | `did_connect` where `ext_session_active=true` (all scene phases) |
| **Session-active EGVs** | `egv_received` where `ext_session_active=true` |
| **Session-active yield** | session EGVs / session connects |
| **No-session connects** | `did_connect` where `ext_session_active=false` |
| **No-session EGVs** | `egv_received` where `ext_session_active=false` |
| **No-session yield** | no-session EGVs / no-session connects |
| **Session coverage %** | session-active connects / total connects (exclude `unknown`) |
| **Overall g7_ble yield** | total EGVs / total connects |

**Reference baselines** (established from soak data, builds 208–213):
- Session-active yield: **~98%** (target); below 90% = investigate
- No-session yield: **~58%** (floor — background OS kill); above 65% is improvement
- Session coverage: **>40%** is healthy; below 25% = behavioral or code regression

### Session health (per hour, from Step 4)

| Metric | Formula |
|---|---|
| **Sessions/hour** | `ext_session_started` count / build duration hours |
| **Foreground start requests** | `ext_session_start_requested_foreground` count |
| **Reanchor replacements** | `reanchor_replacement_started` count (v2, builds 214+) |
| **Session-start accounting** | `ext_session_started` should equal foreground requests + reanchor replacements (± restore-path starts). **Do not** compute `started / requested` as a success rate — it exceeds 100% when reanchor or restore-path starts have no matching `start_requested_foreground`. |
| **Sessions ending at OS cap** | `ext_session_will_expire` / `ext_session_started` — use this single rate only (`ext_session_bg_invalidation_ble_kept` fires for the same background sessions; do not present both as separate columns) |
| **Reanchor attempts/hour** | `reanchor_attempt` count / build hours (v2, builds 214+); `ext_session_reanchor` (v1, build 212 only) |
| **Reanchor success rate** | `reanchor_replacement_started` / `reanchor_attempt` (v2); 1 − (`ext_session_reanchor_timeout` / `ext_session_reanchor`) (v1) |
| **Reanchor disabled** | Any `ext_session_renew_skipped reason=reanchor_disabled` → feature flag off; reanchor will never fire |

> **Note on Session Health Metrics:** 
> - `ext_session_will_expire` and `ext_session_bg_invalidation_ble_kept` are **NOT independent** — both fire for the same session when a session expires naturally while the app is in background (`will_expire` fires at 60-min cap; `bg_invalidation_ble_kept` fires from within `did_invalidate` if the app is in background). Report **one** "sessions ending at OS cap" rate, not two columns.
> - Use `ext_session_did_invalidate` as the total session-ending count when cross-checking lifecycle balance.

**Reanchor version history:**
- **v1 (build 212):** Events `ext_session_reanchor` + `ext_session_reanchor_timeout`. All 12 attempts timed out — broken.
- **v2 (builds 214+):** Events `reanchor_attempt` → `reanchor_invalidated` → `reanchor_start_issued` → `reanchor_replacement_started` (success) or `reanchor_pending_timeout` (fail). Also: `reanchor_abandoned`, `reanchor_retry`, `reanchor_armA_disabled`.
- **Build 213:** v2 code ships with 213/214, but expect **0 reanchor events** unless a session runs ≥45 min during the soak — absence is not proof v2 is missing.
- Reanchor only fires when: (a) session has run ≥45 min AND (b) user opens app to `.active`. If app-opens are infrequent, reanchor rate will be low even when working correctly.

### Error rates (from Steps 2 + 6, normalized by build duration)

Use g7_ble `did_connect` from Step 3 (not Step 2) as the connect denominator for per-connect rates.

| Event | Normalization | Flag threshold |
|---|---|---|
| `auth_notify_failed` | per 100 g7_ble connects | >10 = concern |
| `command_timeout` | per 100 g7_ble connects | >15 = concern |
| `sensor_error` | per 100 g7_ble connects | >20 = concern |
| `direct_ble_stall_detected` | per hour | >1/hour = concern (normalized; build 211 baseline ~2.6/hour) |
| `configure_retry_abandoned` | per 100 g7_ble connects | >5 = concern |
| `ble_gated reason=no_runtime` | per hour | >0.5/hour = investigate |
| `pre_egv_disconnect` | per `egv_received` (ratio) | trend upward vs prior build = concern; ratio >1.5 = high background kill rate |

### EoS corroboration health

`disconnect_suspected_eos_ignored` should be **approximately equal** to `suspected_end_of_session` from the `g7_ble` module. Perfect 1:1 is not required: `g7_core` (fork) can emit `suspected_end_of_session` for scan-initiated disconnects that never generate a matching `ignored` log (different code path). A ratio of `ignored / suspected ≥ 0.8` is healthy. Significant divergence (ratio <0.5) or `suspected` >> `ignored` on a per-module basis = investigate. A rising raw count with stable ratio is acceptable — rising `suspected_end_of_session` events with a stable sensor often indicates proximity to sensor end-of-session.

---

## 5. Event glossary

| Event | Meaning |
|---|---|
| `egv_received` | A glucose reading was successfully received from the sensor |
| `did_connect` | BLE connection to G7 sensor established |
| `pre_egv_disconnect` | Connection dropped between connect and first EGV — no reading captured |
| `connect_timeout` | Connection attempt timed out (retry usually follows) |
| `connect_called` | Connection attempt initiated (includes retries) |
| `connect_skipped` | Connection skipped — sensor not in expected state |
| `connect_gated` | Connection blocked by a gating rule. `reason=rate_limit` has appeared in telemetry (builds 211, 214) but the string is not in checked Trio/patch source — investigate via the shipped G7SensorKit fork SHA (see build215 plan Task 6). Absence in shorter soaks (212/213) may be rarity + window length, not a code difference. |
| `ble_gated` | BLE scan gated; `reason=no_runtime` = OS killed background runtime |
| `gatt_ready` | GATT services discovered and ready |
| `auth_authenticated_bonded` | Auth handshake complete — BLE session ready for control messages |
| `auth_notify_failed` | Failed to subscribe to auth notifications — connection drops |
| `auth_payload_ignored` | Auth packet not yet parseable (normal, ~0.3/connect) |
| `control_notify_subscribed` | Subscribed to EGV notifications — reading imminent |
| `background_gatt_skipped` | Skip non-EGV GATT ops in background (C-209-11 optimization) |
| `configure_block_skipped` | Skip full configure when already subscribed |
| `configure_retry_scheduled` | GATT configure failed, scheduled retry |
| `configure_retry_abandoned` | Retry count exhausted — gave up on this connect |
| `direct_ble_stall_detected` | Connection hung without progress for >N seconds — stall recovery triggered |
| `direct_ble_stall_notified` | UI/phone notified of stall |
| `suspected_end_of_session` | Disconnect pattern looks like sensor end-of-session |
| `disconnect_suspected_eos_ignored` | EoS disconnect correctly suppressed by corroboration logic |
| `stale_sensor_binding_suspected` | Cached sensor state looks stale — reinit triggered |
| `stale_sensor_reinit` | Stale-binding reinit executed |
| `sensor_error` | Sensor protocol error received |
| `command_timeout` | GATT command timed out |
| `backfill_finished` | Backfill batch complete (multiple EGVs downloaded in one connect) |
| `heartbeat` | Periodic liveness ping from the watch observer |
| `expected_window` | Connect triggered within the expected 5-min reading window |
| `will_restore_state` | CoreBluetooth `centralManager(_:willRestoreState:)` at **process launch** — count ≈ process relaunches, not soak hours. Do not normalize by duration or mix into session-health tables without that caveat. |
| `ext_session_started` | Extended runtime session successfully started |
| `ext_session_start_requested_foreground` | App tried to start a session while frontmost |
| `ext_session_renew_skipped` | Session already running, renewal skipped; `reason=running_not_near_expiry` = healthy; `reason=reanchor_disabled` = feature flag off; `reason=reanchor_swap_in_flight` = reanchor already underway |
| `ext_session_will_expire` | Session reached OS 60-min cap, expiring normally |
| `ext_session_did_invalidate` | Session invalidated (by OS or intentional reanchor) |
| `ext_session_bg_invalidation_ble_kept` | OS killed the session in background; BLE connection kept alive |
| `ext_session_reanchor` | **v1 only (build 212)** — near-expiry reanchor started; always followed by timeout in build 212 |
| `ext_session_reanchor_timeout` | **v1 only (build 212)** — reanchor new-session start timed out |
| `reanchor_attempt` | **v2 (builds 214+)** — near-expiry reanchor triggered; old session about to be invalidated |
| `reanchor_invalidated` | v2 — old session successfully invalidated |
| `reanchor_start_issued` | v2 — new session start request sent |
| `reanchor_replacement_started` | v2 — new session started successfully (reanchor succeeded) |
| `reanchor_pending_timeout` | v2 — new session didn't start within timeout (equivalent to v1 timeout) |
| `reanchor_in_swap` | v2 — swap window open, waiting for new session |
| `reanchor_abandoned` | v2 — reanchor gave up (app left foreground during swap) |
| `reanchor_retry` | v2 — retry attempt after failed start |
| `reanchor_armA_disabled` | v2 — arm A disabled after consecutive failures; degraded mode |
| `egv_watchdog_fired` | Watchdog fired — no EGV received in the expected 5-min window. Indicates a stall or missed reading. Triggers reconnect/recovery. |
| `control_notify_failed` | Failed to subscribe to EGV control notifications — reading cannot proceed; connection drops and reconnects. |
| `backfill_notify_failed` | Failed to subscribe to backfill notifications — backfill batch skipped; only the live EGV may be captured. |
| `connect_timeout_reissue` | A timed-out connect was reissued (retry after timeout). Normal recovery path. |
| `sensor_name_locked` | Sensor identity locked/confirmed after pairing — appears once per sensor attach cycle. |
| `rescan_scheduled` | Peripheral scan rescheduled |
| `scanning_status_changed` | BLE scan on/off state changed |
| `attach_path` | Sensor attach path chosen (bonded / new) |

---

## 6. Known causal chains

1. **Session coverage → yield:**  
   `ext_session_active=true` → ~98% EGV yield; `ext_session_active=false` → ~58% yield.  
   A drop in session coverage is the primary driver of lower daily EGV capture.  
   Session coverage is driven by app-opens while frontmost (`.active` scene phase). Return-to-Clock set to "Default (~2 min)" gives ~2× more coverage than "1 hour" because wrist-glances require opening the app actively rather than passively viewing it.

2. **Pre-EGV disconnects → missed readings:**  
   Background process killed between GATT-ready and first EGV notification. These cluster at the 5-min reading-due moment. `ext_session_active=true` largely prevents this (~98% survive). Throttle (C-209-11) reduced many of these in builds 209+.

3. **Stall detection → reconnect overhead:**  
   A stall is a connect that hangs without progress. Stall recovery triggers a disconnect+reconnect. High `direct_ble_stall_detected` → increased `connect_called` overhead and missed readings during recovery.

4. **EoS corroboration:**  
   Sensors disconnect briefly as they cycle readings, which looks like end-of-session. The corroboration logic (`suspected_end_of_session` / `disconnect_suspected_eos_ignored`) filters these out. If `suspected` > `ignored`, readings are being incorrectly terminated.

5. **Auth flow:**  
   `did_connect` → `auth_notify_requested` → `auth_notify_subscribed` → `auth_value_received` → `auth_authenticated_bonded` → `control_notify_subscribed` → `egv_received`.  
   `auth_notify_failed` breaks the chain at step 3.

---

## 7. Report format

Produce the report in this structure:

```
## Watch EGV Status — Build <N> (YYYY-MM-DD)

### Builds in window
<table: build | dates | hours | events>

### Logging Health (Step 0)
<table: build | logs_dropped_total | ring_dropped_total | daily_write_failures_total | note>
Flag any build with nonzero totals as "lower bound" in all downstream tables.

### EGV Yield (g7_ble)
<table: build | session-active yield | no-session yield | session coverage % | overall yield>

### Session Health
<table: build | sessions/hr | foreground starts | reanchor replacements | sessions ending at OS cap % | reanchor success %>

### Error Rates (per 100 connects)
<table: build | auth_failed | cmd_timeout | sensor_err | stalls/hr | pre_egv_disc/egv>

### Coverage Gaps (primary build)
<list of zero-EGV windows ≥2 hours with probable cause>

### Trend Summary
**Improving:** <list>
**Stable:** <list>
**Regressing:** <list>
**New events (not in prior build):** <list>

### Flagged Issues
<numbered list of actionable concerns with supporting data>

### Notes
- n=1 soak device; all figures are directional
- Sensor session: <sensor_name>, <days remaining if known>
```

---

## 8. Common pitfalls

- **Do not use `remote(...)` for any window >30 minutes** — it will silently return empty. Use `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`.
- **Sub-fields like `module`, `scene_phase`, `ext_session_active` are NOT top-level JSON** — they are inside the `message` string. Extract with regex: `extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'key=(\\S+)')`.
- **`unknown` scene_phase ≠ background** — it is pre-stamping telemetry (BUG-F not yet active for that event). Exclude `unknown` when computing session-coverage %.
- **Always normalize by duration before comparing builds** — a 9-hour and a 36-hour build have incomparable raw counts.
- **`did_connect` counts both modules** (g7_ble + g7_core). Always filter `module=g7_ble` when computing per-connect yield rates to avoid double-counting.
- **`pre_egv_disconnect` can exceed `egv_received`** — each is per-connection-attempt, and some connects have only pre-EGV disconnect; others only EGV; the ratio >1 is normal when sessions are scarce.
- **Build numbers are string fields**, not integers. Use `IN ('212', '213', '214')` not `IN (212, 213, 214)`.
- **`ext_session_active` is a cached "last known" flag**, not live `WKExtendedRuntimeSession.state`. It is cleared in `willExpire` / early invalidation paths *before* some logs are emitted, so events around session expiry or reanchor transitions may carry a stale value. Yield splits by this field are directional, not exact, near session boundaries.
- **Session coverage % formula — sum across scene phases first.** From Step 3: compute `session_connects = sum of did_connect where ext_session_active='true' across ALL scene_phase values (active + inactive + background)`; then divide by `total_connects = session_connects + no_session_connects`. Do not compare per-scene-phase buckets directly; sum them first.
- **`ext_session_active` regex returns empty string (not NULL) when the field is absent.** The `WHERE ext_session_active != ''` filter in Step 3 handles this. If you write additional ad-hoc queries, add the same guard or results will include pre-BUG-F events as phantom "no-session" rows.
- **8-day retention is hard.** Data from the oldest build in the window may be partially aged out. Check `min(dt)` in Step 1 — if it's close to now()-8 days, those counts are incomplete.
- **`connect_gated reason=rate_limit` cross-build checks:** when citing prior builds as evidence (e.g. also seen in 211), include a context row for that build in "Builds in window" even if it is not a primary comparison build.
- **Coverage threshold language:** when coverage is near the ~25% reference floor, distinguish **distance-to-threshold** (e.g. 24.9% vs 25%) from **build-over-build change** (e.g. 43.6% → 24.9%). Do not phrase the former as the regression magnitude.
- **Regressing trends:** session coverage, overall g7_ble yield, and sessions/hr are usually one wear-time/coverage story — collapse them in trend summaries rather than listing three separate regressions.

---

## Changelog

### v1.1 (2026-06-26 11:45 CET)
- Reanchor v2 documented as shipping in **build 214+** (not 215+); build 213 may show zero events without implying v2 absent.
- Removed misleading **start success rate** (`started / requested`); replaced with foreground starts + reanchor replacements + accounting note.
- Merged **natural expiry** and **bg-kill** into one **sessions ending at OS cap** metric in metrics table and report format.
- Corrected **`connect_gated reason=rate_limit`** glossary (also in build 211; source not in checked tree).
- Clarified **`will_restore_state`** (per process launch, not soak hours); added pitfalls for rate_limit evidence builds, coverage threshold wording, and collapsed coverage regressions.
- Reason: feedback from build-214 status report review — metric definitions and provenance notes inherited by next agent run.
