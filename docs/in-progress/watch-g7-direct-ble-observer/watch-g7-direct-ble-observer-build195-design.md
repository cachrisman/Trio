# Design: G7SensorKit watchOS Adaptation + Watch BLE Observer Rewrite

**Version:** 1.17
**Status:** Accepted pending A1/A6 feasibility
**Created:** 2026-05-07 16:00 CET
**Last updated:** 2026-05-09 15:17 CET

---

## Problem

Build 194 BetterStack telemetry shows the core reliability gap in the Trio watch G7 direct BLE
path: **40% of successful BLE connections fail to reach authentication** (111 `did_connect` →
66 `auth_authenticated_bonded`). Once authentication succeeds, EGV delivery is 98% reliable.
The bottleneck is entirely in the connect → auth segment.

A confirmed secondary failure mode: **extended runtime session expiry triggers BLE teardown at
every 1-hour boundary** (H4), and the session cannot self-renew without a foreground entry (H1).
Together these produce a 4-hour overnight dead zone (00:45–04:30 UTC in build 194 data).

The current implementation (`G7DirectBLEObserver.swift`, ~858 lines) is a custom reimplementation
of the G7 BLE protocol. Pete Schwamb's `G7SensorKit` implements the same protocol with years of
field validation across Loop and Trio on iPhone. The hypothesis is that substituting G7SensorKit's
`G7Sensor` + `G7BluetoothManager` + `G7PeripheralManager` for the custom implementation will
improve auth reliability by removing divergences in threading, connection sequencing, and session
window timing.

---

## Context / Current State

**G7DirectBLEObserver.swift (current, build 194):**
- Custom CBCentralManagerDelegate + CBPeripheralDelegate implementation
- Uses `retrievePeripherals(withIdentifiers:)` as primary reconnect path (path 1), falling
  back to `retrieveConnectedPeripherals` (path 2) and active scan (path 3)
- Suffix(2) name matching, mirroring G7SensorKit
- No `0x4E` write — sensor pushes EGV unsolicited
- Session watchdog (20s GATT silence), connect deadlock detector (7 min)
- EOS detection only from `parseGlucose` (`algorithmState` or sensor age ceiling)

**Build 194 key metrics (watchOS, BetterStack source 1659391):**

| Metric | Count |
|--------|-------|
| connect_calls | 120 |
| did_connects | 111 |
| auth_authenticated_bonded | 66 |
| egv_received | 65 |
| eos_detected | 0 |
| scans | 0 |
| connect_deadlock_fired | 3 |
| session_watchdog_fired | 1 |

Auth success rate: **59%** (66/111). EGV/auth rate: **98%** (65/66).

**Confirmed bugs in build 194 relevant to this build:**

| Bug | Location | Impact |
|-----|----------|--------|
| P3: Complication snapshots carry `state: "g7_direct_ble"` | G7DirectBLEObserver line 562 | Every direct BLE reading renders as `"g7_direct_ble 110"` / `"-- · BLE"` — complications broken today |
| P4: BT-off leaves `active != nil`, blocking rescan | G7DirectBLEObserver lines 642-650 | Observer permanently wedged after Bluetooth power cycle |
| H4/P8: `willExpire` → `unexpected_invalidation` → `stop()` | G7DirectBLEObserver lines 820-828 | BLE state destroyed at every 1-hour session boundary; 4-hour overnight dead zone confirmed |
| P10: Trend arrow mapping missing triple-up/triple-down | G7DirectBLEObserver lines 576-585 | Direct BLE trend arrows inconsistent with phone-sourced data |

**Deferred bugs (not in build 195 scope):**

| Bug | Location | Reason deferred |
|-----|----------|----------------|
| P1: BLE readings shown stale when phone unreachable | TrioMainWatchView, WatchState | UI/staleness logic, separate from BLE rewrite |
| P2: Phone glucose shown fresh when CGM is stale | WatchState, AppleWatchManager | Timestamp vs reading epoch bug, separate fix |
| P6: Same-sequence dedup blocks phone delta from filling BLE's "--" | WatchState | Dedup logic, separate fix |
| P7: WC retry loop has no backoff | WatchState+Requests | WC layer, separate fix |

**Addressed by adapter design (not open bugs):**

| Bug | How addressed |
|-----|--------------|
| P5: Sensor replacement can permanently lock out new sensor | `applyNewSensorName(_:)` re-inits `G7Sensor` with WC-delivered name; sensor identity never cleared on disconnect. |

**G7SensorKit current state:**
- iOS-only due to LoopKit dependency in `G7CGMManager.swift` and `G7CGMManagerState.swift`
- All other files import only `Foundation`, `CoreBluetooth`, `HealthKit` — all watchOS-available
- Maintainer already maintains a fork for another purpose

---

## Constraints / Requirements

- Existing iOS functionality of G7SensorKit must be preserved exactly
- The watch adapter must produce the same log events as G7DirectBLEObserver where possible
- Daily counters (`bleConnectsToday`, `bleEGVsToday`) must be preserved in WatchState
- `TrioComplicationDataStore` and `WatchState` integration must be preserved
- `WKExtendedRuntimeSession` lifecycle must be maintained with self-renewal (H1/H4 fix)
- The watch adapter must NOT implement `scanForNewSensor()` — sensor lifecycle is the phone's domain
- Sensor name changes must be handled by re-initializing `G7Sensor` with the new `sensorID`
- Complication snapshots must have `state: nil` (P3 fix)
- Fork instrumentation (Task A6) must be non-blocking on BLE callback paths

---

## Decision

### Recommended approach

**Part A — G7SensorKit fork: two commits**

Commit 1 (instrumentation, committed first): Add lightweight telemetry logging to
`G7BluetoothManager`, `G7PeripheralManager`, and `G7Sensor`. Events: `auth_value_received`,
`attach_path`, and pre-auth sub-phases. All logging must be non-blocking — fire-and-forget
via `emitG7Telemetry` only — not `os_log`. See Task A6.

Commit 2 (watchOS gating, committed after): Gate the two LoopKit-dependent files behind
`#if os(iOS)`. Add `.watchOS(.vN)` to `Package.swift`. Three files changed; no logic altered.
See Tasks A2–A5.

**Part B — Trio watch app: replace G7DirectBLEObserver with thin adapter**

Delete `G7DirectBLEObserver.swift`. Create `G7WatchSensorAdapter.swift` which:
- Owns one `G7Sensor` instance initialized with WC-supplied `sensorID`
- Implements `G7SensorDelegate` — all BLE protocol work delegated to `G7Sensor`
- Handles watch-specific lifecycle: `WKExtendedRuntimeSession` with self-renewal, `WatchLogger`,
  `WatchState`, `TrioComplicationDataStore`, daily counters, telemetry
- Fixes P3, P4 (via G7Sensor), H4/P8, P10 (via G7SensorKit)

### Why this tradeoff

G7SensorKit's BLE implementation has a dedicated serial `delegateQueue`, precise `pendingAuth`
tracking, `makeActive` vs `connect` distinction, and years of field iteration. The custom
implementation has diverged in ways that are hard to diagnose. Delegating eliminates the
divergence surface entirely.

P3, P4, P10 are fixed automatically or trivially by the rewrite. H4/P8 requires an
explicit fix in the adapter's `WKExtendedRuntimeSessionDelegate`. P1, P2, P6, P7 are deferred
— separate files, separate build, would contaminate the before/after metric comparison.

Adding instrumentation to the fork (commit 1 of Part A) recovers the CB-level auth and
attach-path visibility that would otherwise be permanently lost behind the G7Sensor abstraction.

---

## Functional behavior

### G7SensorDelegate implementation — watch adapter behavior

| Delegate method | Watch adapter behavior |
|-----------------|----------------------|
| `sensorDidConnect` | Start/chain `WKExtendedRuntimeSession`; log `did_connect`; increment `bleConnectsToday`; record connect timestamp |
| `sensorDisconnected(suspectedEndOfSession:)` | Log `disconnect` with phase + `since_connect_s` + `had_egv`; **never** call `scanForNewSensor()`; re-init G7Sensor if WC has new `activePeripheralName` |
| `sensor(_:didRead:)` | If `hasReliableGlucose`: write complication (`state: nil`), update WatchState, log `egv_received` with scene/ext fields, increment `bleEGVsToday`, arm expected-window schedule. Transient: log `egv_unreliable`, skip complication |
| `sensor(_:didDiscoverNewSensor:activatedAt:)` | Always return `false` |
| `sensor(_:didReadBackfill:)` | Log `backfill_entry`; consumer deferred to build 196 |
| `sensor(_:didError:)` | Log `g7_ble_error` |
| `sensorConnectionStatusDidUpdate` | Mirror to `WatchState.applyG7DirectBleStatus` |

### Extended runtime session

#### Confirmed bug fix — H4/P8

The `stop()` on natural session expiry is a confirmed bug. Build 194 log trace:
`willExpire` → `didInvalidate(reason:-1, hasError:true)` → `unexpected_invalidation` →
`stop()` → full BLE teardown at every 1-hour boundary.

**Required fix in `didInvalidateWith`:**
- `error == nil` (natural expiry): do NOT call `stop()`. Log it, preserve BLE state.
- `error != nil` (genuine failure): log `ext_session_unexpected_invalidation`, call `stop()`.
  Schedule delayed recovery (guarded by `recoveryScheduled` flag).

#### Best-effort hypothesis — session chaining (H1, unverified)

Apple's `willExpire` docs say "finish any tasks and clean up." No confirmed examples of
perpetual chaining. Attempt it as best-effort; instrument every outcome. Never call `stop()`
on any chaining outcome. `pendingChainSession` tracked by identity to correctly classify old
vs new session callbacks. 10s timeout guard for silent watchOS denials.

#### Stale sensor binding detection

After N ≥ 3 consecutive pre-EGV disconnects with no WC update: log
`stale_sensor_binding_suspected`. After N ≥ 5: re-init `G7Sensor` with same
`knownSensorName` (fresh CB state, same identity). Never calls `scanForNewSensor()`.

### Timer lifecycle

| Timer | Cancelled by | Restored by |
|-------|-------------|-------------|
| Heartbeat | `stop()` | `start()` (which calls `stopTimers()` first) |
| Expected window | `stop()` on error teardown only; NOT cancelled by normal `sensorDisconnected` | `start()` via recovery path or foreground re-entry |

The expected window timer's purpose is to count all missed EGV opportunities. Normal BLE
disconnects do not call `stop()`, so the timer runs continuously across reconnect cycles.
Only an error teardown (unexpected session invalidation) cancels it, and the recovery path
restores it within 5 seconds.

### Complication snapshot — P3 fix

All `TrioComplicationSnapshot` calls must have `state: nil`.

### Bluetooth power state — P4

Verified in Task A1 audit. If G7BluetoothManager handles `poweredOff` correctly: no adapter
code needed. If not: fork change required.

### Trend arrow mapping — P10

Use `G7GlucoseMessage` trend output directly. G7SensorKit's 7-bucket mapping is automatic.

### State machine — sensor transition

When WC delivers a new `activePeripheralName`: re-init `G7Sensor` with new name. Sensor
identity never cleared on disconnect — only the phone drives sensor lifecycle via WC.

### Observability

#### Fork-level telemetry (G7SensorKit instrumentation, commit 1 of Part A)

Added to G7SensorKit using `emitG7Telemetry` — `internal` to the module, accessible from
all three files, already dispatches async through a serial utility queue. On watchOS, the
watch extension sets `G7Telemetry.emit` at startup to route events to WatchLogger/BetterStack
(Task B0).

**Log format:** `module=g7_core event=<name> <key=value fields>` — set by changing line 38
of `G7Telemetry.swift` from `"event=g7_ble_ios \(event)"` to `"module=g7_core event=\(event)"`.
Adapter events use `module=g7_ble event=<name>`. Use `platform=watchos` / `platform=ios` to
distinguish platforms within `module=g7_core` events.

Example log lines:
```
module=g7_core event=auth_authenticated_bonded peripheral=... g7_session=<uuid> sensor_name=DXCMYR
module=g7_core event=egv_received glucose=164 sequence=547 ... g7_session=<uuid> sensor_name=DXCMYR
module=g7_ble event=ext_session_chain_started g7_session=<uuid> sensor_name=DXCMYR
module=g7_ble event=disconnect phase=pre_egv since_did_connect_s=12 g7_session=<uuid> sensor_name=DXCMYR
```

**Sensor name injection:** The `G7Telemetry.emit` closure (Task B0) injects `g7_session=`
and `sensor_name=<sensorName>` into every fork event on watchOS — these fields follow the
`module=g7_core event=<name>` prefix from `G7Telemetry.swift`. On iOS, the emit closure
likewise injects `sensor_name=` from the iOS CGM manager context.

**Ordering caveat:** Fork (`module=g7_core`) and adapter (`module=g7_ble`) events are emitted
through separate async queues. Log order in BetterStack does not reliably reflect protocol
order. Correlate events by `g7_session=` + timestamp — never by strict log sequence.

**Already present in the fork (no changes needed):**

| Event | Key fields | Source |
|-------|-----------|--------|
| `did_connect` | `peripheral=`, `name=` | `G7BluetoothManager.centralManager(_:didConnect:)` |
| `did_fail_to_connect` | `peripheral=`, `name=`, `error=` | `G7BluetoothManager` |
| `connect_called` | `intent=makeActive\|connect`, `peripheral=`, `name=` | `G7Sensor.shouldConnectPeripheral` |
| `gatt_ready` | `peripheral=`, `name=`, `following_known=` | `G7Sensor.bluetoothManager(_:readied:)` |
| `auth_notify_requested` | `peripheral=` | Before `listenToCharacteristic(.authentication)` |
| `auth_notify_failed` | `peripheral=`, `error=` | On notification subscription failure |
| `auth_authenticated_bonded` | `peripheral=` | Gate pass — `isBonded && isAuthenticated` |
| `auth_payload_ignored` | `bytes=` | Gate fail — wrong opcode, too short, or auth/bond=0 |
| `control_notify_failed` | `error=` | On control characteristic subscription failure |
| `disconnect` | `peripheral=`, `name=`, `was_remote=`, `pending_auth=`, `followed=` | `G7Sensor.peripheralDidDisconnect` |
| `suspected_end_of_session` | `prior_name=` | `pendingAuth=true` on remote disconnect |
| `egv_received` | `glucose=`, `sequence=`, `algorithm_state=`, `age_s=`, `trend_rate=`, `display_only=` | `G7Sensor.handleGlucoseMessage` |
| `configuration_failed` | `error=` | `G7PeripheralManager.configureAndRun` |
| `scanning_status_changed` | `scanning=` | `G7Sensor.bluetoothManagerScanningStatusDidChange` |
| `backfill_finished`, `backfill_flush`, `backfill_entry` | various | `G7Sensor` backfill handling |

**To be added in Task A6:**

| Event | Key fields | Source in fork |
|-------|-----------|----------------|
| `auth_value_received` | `opcode=0x..`, `authenticated=<byte>`, `bonded=<byte>`, `bytes=`, `payload=<hex>`, `gate_passed=` | `G7Sensor.bluetoothManager(_:didReceiveAuthenticationResponse:)` — fired BEFORE `AuthChallengeRxMessage` parse, once per connection |
| `attach_path path=stored_id` | `peripheral=`, `name=` | `G7BluetoothManager.managerQueue_scanForPeripheral` — path 1 (`retrievePeripherals(withIdentifiers:)`) succeeded |
| `attach_path path=miss` | `has_identifier=` | Path 1 failed — `has_identifier=false` means no stored ID; `true` means stored ID found but no peripheral returned |
| `attach_path path=connected_peripherals` | `peripheral=`, `name=` | Per peripheral found via path 2 (`retrieveConnectedPeripherals`) |
| `attach_path path=scan` | — | Path 3 engaged — `activePeripheral == nil` after paths 1 and 2 |
| `auth_notify_subscribed` | `peripheral=` | After `pendingAuth = true` — confirms subscription succeeded |
| `control_notify_subscribed` | `peripheral=` | After `listenToCharacteristic(.control)` succeeds (post-0x05 gate pass) |

`authenticated` and `bonded` are raw byte values from the characteristic data. `bytes=` is
the total length of the characteristic value. `payload=` is the full characteristic value
as a hex string — complete protocol record for cross-referencing against the G7 spec.

#### Adapter telemetry events

| Event | Key fields | Source |
|-------|-----------|--------|
| `disconnect` | `phase`, `since_did_connect_s`, `had_egv`, `session_duration_s` | `sensorDisconnected` |
| `auth_failed_inferred` | `since_connect_s`, `consecutive_count` | `sensorDisconnected` with `phase=pre_egv` |
| `egv_received` | `scene_phase`, `ext_session_active`, `peripheral`, `time_to_first_egv_ms` | `sensor(_:didRead:)` |
| `heartbeat` | `ext_session_active`, `ext_session_state` | 5-min timer |
| `expected_window` | `tick_epoch`, `last_success_epoch`, `eligible`, `reason`, `retroactive` | Independent 5-min timer |
| `ext_session_chain_attempted` / `ext_session_chain_started` / `ext_session_chain_denied` / `ext_session_chain_timeout` | — | `willExpire`, `didStart`, `didInvalidateWith` |
| `stale_sensor_binding_suspected` | `consecutive_pre_egv_disconnects`, `minutes_since_last_egv` | After N pre-EGV disconnects |
| `g7_session=<uuid>` | In every log line | Per connect–disconnect cycle |

#### The `expected_window` event — EGV opportunity denominator

```
EGV success rate = count(module=g7_ble event=egv_received) /
                   count(module=g7_ble event=expected_window where eligible=true)
```

---

## Alternatives considered

**Alternative 1: Keep G7DirectBLEObserver, diagnose via HCI tracing** — Rejected.
**Alternative 2: Add a `sensorID` setter to the fork** — Rejected. Re-init overhead negligible.
**Alternative 3: Copy lower layers directly into watch target** — Rejected. Maintenance split.
**Alternative 4: Two builds — instrument first, rewrite second** — Rejected. Fork instrumentation recovers CB-level visibility within the same build.
**Alternative 5: Fix P1/P2/P6/P7 in build 195** — Rejected. Contaminates metric comparison.

---

## Risks / Open questions

**Risk 1: G7Sensor API surface** — Mitigated by fork. Task A1 is a hard gate.

**Risk 2: G7Sensor `delegateQueue` dispatch** — All callbacks on internal serial queue.
Adapter must dispatch WatchState and session calls appropriately.

**Risk 3: CBCentralManager restoration identifier conflict** — Checked in Task A1.

**Risk 4: `willExpire` session chaining viability (unverified API use)** — Apple's docs say
"finish tasks and clean up." No confirmed examples of perpetual chaining. Instrumented with
`chain_started` vs `chain_denied`. H4 bug fix confirmed regardless of chaining outcome.

**Risk 5: Fork instrumentation timing** — Mitigated by `emitG7Telemetry` design: all A6
calls use `emitG7Telemetry` (not `os_log`), which dispatches async through a serial utility
queue — non-blocking on BLE callback paths by construction. No sync dispatch, no awaiting.

**Risk 6: iOS telemetry format migration** — Changing G7Telemetry.swift from
`"event=g7_ble_ios \(event)"` to `"module=g7_core event=\(event)"` changes existing iOS log
format in BetterStack. Any iOS-side queries or alerts filtering `event=g7_ble_ios` will need
updating. Confirm no active iOS alerts depend on the old format before shipping A6.

**Open question: G7Sensor startup call** — Confirmed in Task A1.

---

## Success criteria (verifiable, via BetterStack build 195 data)

**Primary — auth reliability:**

| Metric | Build 194 baseline | Build 195 target |
|--------|--------------------|-----------------|
| `auth_authenticated_bonded / did_connect` | 59% (66/111) | ≥ 75% |
| `egvs / auth_authenticated_bonded` | 98% (65/66) | ≥ 98% |
| Auth proxy rate: `1 - (pre_egv_disconnects / did_connects)` | ~59% | Cross-check vs primary |
| connect_deadlock_fired | 3 | ≤ 1 |
| eos_detected | 0 | 0 |

Note: `auth_authenticated_bonded` is emitted directly by the fork (`event=g7_core`) — the
real auth gate event on watchOS once `G7Telemetry.emit` is set (Task B0). Identical metric
to build 194 baseline. `auth_proxy_rate_pct` is a cross-check, not the primary signal.

**Divergence guard:** If `auth_authenticated_bonded / did_connect`, `auth_proxy_rate_pct`,
and `auth_value_received gate_passed / did_connect` diverge by more than 5 percentage points,
treat fork telemetry as suspect — likely an instrumentation placement bug or `module=` mismatch.

**Primary — overnight reliability:**

| Metric | Build 194 baseline | Build 195 target |
|--------|--------------------|-----------------|
| `unexpected_invalidation` → teardown events | Confirmed at 1-hour boundaries | 0 — H4 confirmed fixable |
| `ext_session_chain_started` at 1-hour boundaries | Not present | Present if chaining succeeds; evaluated diagnostically |
| Overnight dead zone (zero-EGV window) | 4h (00:45–04:30) | Diagnostic only — improvement desired, not a ship gate |

**Secondary — new telemetry established:**

| Metric | Build 194 | Build 195 target |
|--------|-----------|-----------------|
| `expected_window` events present | No | Yes |
| EGV success rate (egvs / eligible ticks) | Unknown | Baseline established |
| `auth_value_received` present (fork) | No | Yes |
| `attach_path` present (fork) | No | Yes |
| Complication renders glucose/delta/age from BLE | No (P3 broken) | Yes |

Secondary: no complication freshness regression.

---

## Changelog

| Version | Date | Author | Notes |
|---------|------|--------|-------|
| 1.17 | 2026-05-09 15:17 CET | Charlie | Fix os_log → emitG7Telemetry in Part A; fix attach_path event names to path= field format |
| 1.16 | 2026-05-09 15:17 CET | Charlie | Fix adapter telemetry table to bare event names; fix os_log → emitG7Telemetry; add payload_len= to fork table; add module= example |
| 1.15 | 2026-05-09 15:17 CET | Charlie | Fix date mismatch; add iOS telemetry migration Risk 6 |
| 1.14 | 2026-05-09 15:17 CET | Charlie | module=g7_core/g7_ble format; iOS emit closure update; sensor_name= in both closures |
| 1.13 | 2026-05-09 15:17 CET | Charlie | Strip g7_ble_ prefix from adapter event names; update telemetry table |
| 1.12 | 2026-05-09 15:17 CET | Charlie | Add event=g7_core prefix and ordering caveat; sensor name injection via emit closure; payload= rationale; divergence guard |
| 1.11 | 2026-05-08 06:10 CET | Charlie | Restore auth_authenticated_bonded as primary metric; split fork telemetry table; add payload= to auth_value_received; fix attach_path fields |
| 1.10 | 2026-05-08 06:10 CET | Charlie | Fork telemetry uses emitG7Telemetry; revert to raw bytes; add B0 reference |
| 1.9 | 2026-05-08 06:10 CET | Charlie | Fix success criteria to proxy metrics; status Accepted pending A1/A6; fix hypothesis wording |
| 1.8 | 2026-05-08 06:10 CET | Charlie | Add G7SensorKit instrumentation as separate fork commit; restore auth_value_received and attach_path |
| 1.7 | 2026-05-07 23:21 CET | Charlie | Remove P9 stale reference |
| 1.6 | 2026-05-07 23:21 CET | Charlie | Add P5 to addressed-by-design table |
| 1.5 | 2026-05-07 22:07 CET | Charlie | Qualify overnight dead zone as diagnostic-only |
| 1.4 | 2026-05-07 21:52 CET | Charlie | Split session section; chain telemetry; stale sensor events; strengthen Risk 4 |
| 1.3 | 2026-05-07 21:52 CET | Charlie | One build; renumber parts; remove auth_value_received from observability spec |
| 1.2 | 2026-05-07 18:30 CET | Charlie | Add P3/P4/P8/P10 bug fixes; H4/H1; H2/H5; defer P1/P2/P6/P7 |
| 1.1 | 2026-05-07 17:30 CET | Charlie | Add telemetry improvements spec; observability section; update success criteria |
| 1.0 | 2026-05-07 16:00 CET | Charlie | Initial |