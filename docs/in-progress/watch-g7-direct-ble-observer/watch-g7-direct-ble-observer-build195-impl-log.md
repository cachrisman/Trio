# Build 195 — Implementation log

**Version:** 1.8  
**Status:** Phase **C** complete (WC sensor identity + removal of **`G7DirectBLEObserver`**) + **`patches/12`** regenerated  
**Created:** 2026-05-09 21:43 CET  
**Last updated:** 2026-05-09 23:04 CET  

**Design / plan:** [watch-g7-direct-ble-observer-build195-design.md](watch-g7-direct-ble-observer-build195-design.md), [watch-g7-direct-ble-observer-build195-impl-plan.md](watch-g7-direct-ble-observer-build195-impl-plan.md)

---

## Repository scope (this entry)

Changes were applied in the **standalone G7SensorKit fork** at:

`/Users/charliechrisman/Code/src/cachrisman/diabetes/G7SensorKit`

**Trio integration:** Trio's build **clones G7SensorKit from GitHub** (not a local `Trio-dev/G7SensorKit` tree). After **committing and pushing** this fork, update **`Trio-dev/patches/02-g7-reading-time-with-seconds.patch`** so it pins the **new fork commit** — that patch is what pulls the updated G7SensorKit into Trio during the patch-stack build.

---

## Task A6 — G7SensorKit instrumentation (completed in fork)

**Goal:** Namespace fork telemetry, add attach-path and auth-phase events, refactor auth parse once, fix `CBManagerState` description typo — **no behavioral changes** except the typo fix and the intentional auth telemetry shape.

### 1. `G7SensorKit/G7CGMManager/G7Telemetry.swift`

- Replaced formatted prefix **`event=g7_ble_ios`** with **`module=g7_core event=`** + the existing `event` string argument (full line: `module=g7_core event=<payload>`).
- Updated doc comments (emit example + internal helper description) to match.
- **Downstream:** Any Better Stack queries or parsers matching **`event=g7_ble_ios`** must be updated to **`module=g7_core`** (or match on `event=` within the new layout).

### 2. `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`

In **`managerQueue_scanForPeripheral()`**, added **four** `emitG7Telemetry` calls (no edits to pre-existing emits in this file):

| Location | Event prefix |
|----------|----------------|
| After retrieve-by-stored-id succeeds, **before** `handleDiscoveredPeripheral` | `attach_path path=stored_id peripheral=… name=…` |
| Start of **`else`** (miss path), **before** the connected-peripherals loop | `attach_path path=miss has_identifier=…` |
| Inside loop over `retrieveConnectedPeripherals`, **before** `handleDiscoveredPeripheral` | `attach_path path=connected_peripherals peripheral=… name=…` |
| Inside **`if activePeripheral == nil`**, **before** `scanForPeripherals` | `attach_path path=scan` |

### 3. `G7SensorKit/G7CGMManager/G7Sensor.swift`

- **`bluetoothManager(_:readied:)`:** After **`pendingAuth = true`**, inserted **`auth_notify_subscribed peripheral=<uuid>`**. Left **`auth_notify_requested`** unchanged (plan: do not modify existing `emitG7Telemetry` strings).
- **`bluetoothManager(_:didReceiveAuthenticationResponse:)`:** Replaced the outer **`if let message = …, isBonded, isAuthenticated`** with:
  - Raw **`opcode` / `authByte` / `bondByte`** and capped **`payload`** hex (`omitted` if `response.count > 8`).
  - Single **`AuthChallengeRxMessage(data:)`** parse; **`gatePass`** = `isAuthenticated && isBonded` (same gate as before).
  - **`auth_value_received`** on both parse-fail and parse-success paths (with **`gate_passed`** true/false).
  - Success path: unchanged **`pendingAuth`**, **`auth_authenticated_bonded`**, **`listenToCharacteristic(.control)`**; added **`control_notify_subscribed`** immediately after successful **`.control`** notify inside the **`do`** block.
  - Failure / ignore paths: **`auth_payload_ignored`** + debug log — **mutually exclusive** with the success branch (parse failure **`return`**s early); **at most one** **`auth_payload_ignored`** per auth callback (see pre-build review disposition).

### 4. `G7SensorKit/G7CGMManager/G7PeripheralManager.swift`

- **`extension CBManagerState`:** **`case .poweredOn`** returned **`"poweredOff"`** (copy-paste bug) → **`"poweredOn"`**.  
- **Note:** The implementation plan text references **`G7BluetoothManager.swift`** for this extension; in this fork the extension lives in **`G7PeripheralManager.swift`** only.

### Explicitly not changed (per A6)

- No new **`suspected_end_of_session`** or **`auth_authenticated_bonded`** lines (already present).
- No **`await`** / **`DispatchQueue.sync`** added inside BLE callbacks (telemetry remains **`emitG7Telemetry`** only).

### Verification (manual)

- **iOS:** Build **`G7SensorKit`** framework target in Xcode from the fork after integrating into Trio.
- **Smoke (plan):** After deploy, confirm **`module=g7_core`** lines for **`did_connect`**, **`auth_value_received`**, and **`auth_authenticated_bonded`** or **`auth_payload_ignored`** in Better Stack over a real sensor session.

---

## Tasks A3 / A4 — iOS-only CGM manager types (same fork commit as message gating)

**Goal:** On **watchOS**, the **`G7SensorKit`** module compiles **without** pulling **`G7CGMManager`** / **`G7CGMManagerState`** / LoopKit-only CGM UI glue; core BLE (**`G7Sensor`**, messages, backfill buffer types) stays shared.

| File | Change |
|------|--------|
| `G7CGMManager/G7CGMManagerState.swift` | Entire file body wrapped in **`#if os(iOS)` … `#endif`**. |
| `G7CGMManager/G7CGMManager.swift` | Entire file body wrapped in **`#if os(iOS)` … `#endif`** (includes **`G7StateObserver`**, **`G7CGMManager`**, **`G7BackfillMessage.trendRate`**, **`G7GlucoseMessage: GlucoseDisplayable`** extensions — iOS-only). |

---

## Companion files — LoopKit only behind `#if os(iOS)` (same commit)

**Goal:** Watch slice has **no unconditional `import LoopKit`** in **`G7SensorKit/`** sources; structs needed on watch keep parsing logic; LoopKit-derived **`trendType`** / **`condition`** stay on iOS only.

| File | Change |
|------|--------|
| `G7CGMManager/G7DeviceStatus.swift` | Entire file **`#if os(iOS)`** — pure iOS UI highlight type; watch adapter does not use it. |
| `Messages/ExtendedVersionMessage.swift` | Removed stale **`import LoopKit`**; **`SensorMessage`** comes from module-local **`SensorMessage.swift`**. |
| `Messages/G7GlucoseMessage.swift` | **`#if os(iOS) import LoopKit #endif`**; **`trendType`** and **`condition`** wrapped in **`#if os(iOS)`**. |
| `G7CGMManager/G7BackfillMessage.swift` | Same pattern as **`G7GlucoseMessage`** for **`trendType`** / **`condition`** and conditional import. |

**Integration reminder:** After **push** of the fork commit, bump **`Trio-dev/patches/02-g7-reading-time-with-seconds.patch`** to that SHA so Trio’s clone step picks up this Phase A bundle.

---

## Task B0 — `G7Telemetry.emit` wiring (Trio **worktree**, not Trio-dev)

**Repo path:** `Trio/` (application sources).

**watchOS — `Trio Watch App Extension/ExtensionDelegate.swift`**

- **`import G7SensorKit`** at top.
- At the **start** of **`applicationDidFinishLaunching()`**, before other startup side effects: capture **`let adapter = G7WatchSensorAdapter.shared`** and set **`G7Telemetry.emit`** so each line is forwarded as  
  **`g7_session=<id> sensor_name=<name> <full formatted line>`** via **`Task { await WatchLogger.shared.log(...) }`** (matches impl plan B0).
- **Task B1 superseded this:** the minimal **`G7WatchSensorAdapter`** stub was removed from **`ExtensionDelegate.swift`** before adding the real **`G7WatchSensorAdapter.swift`** (mandatory ordering — avoids duplicate type in the extension module). Until B1 landed, that stub held **`adapterSessionID`** / **`telemetrySensorName`** for **`G7Telemetry.emit`**.

**iOS — `Trio/Sources/Application/TrioApp.swift`**

- **`import G7SensorKit`**.
- After **`resolveOrLog(DeviceDataManager.self)`** inside **`loadServices()`**, call **`configureG7ForkTelemetry(deviceDataManager:)`** which sets **`G7Telemetry.emit`** with **`[weak deviceDataManager]`**, resolves **`sensor_name`** from **`cgmManager as? G7CGMManager`** (**`sensorName`**), and logs with **`debug(.service, "sensor_name=\(sensorName) \(line)")`** so lines enter the existing **SimpleLogReporter** / **CloudLogUploadService** path (plan referred to **`TrioLogger.shared`**, which does not exist in-tree).

**Acceptance (plan):** Fork **`emitG7Telemetry`** events reach Better Stack on watch with **`g7_session=`** once Task B1 sets **`adapterSessionID`** during real BLE sessions; iOS gains **`sensor_name=`** prefix parity.

---

## Task B1 — `G7WatchSensorAdapter.swift` (Trio worktree)

**Repo path:** `Trio/`.

| Area | Change |
|------|--------|
| **`ExtensionDelegate.swift`** | Stub **`G7WatchSensorAdapter`** deleted first; **`G7Telemetry.emit`** wiring unchanged (**references singleton**). |
| **`G7WatchSensorAdapter.swift`** | New file under **`Trio Watch App Extension/`**: **`G7Sensor`** ownership, full **`G7SensorDelegate`**, **`WKExtendedRuntimeSession`** chaining + H4/H1 handling per plan, heartbeat + expected-window timers, daily counters (**same UserDefaults keys** as **`G7DirectBLEObserver`**), **`TrioComplicationSnapshot`** with **`state: nil`**, trend via **`WatchState.trendString(fromDirectBleRate:)`** (P10), **`applyNewSensorName`** / **`applyForegroundActiveEntry`** / **`noteForegroundInactiveOrBackground`**. |
| **`WatchState.swift`** | Foreground entry / inactive hooks call **`G7WatchSensorAdapter.shared`** instead of **`G7DirectBLEObserver.shared`** so only one BLE stack runs (**Phase C** still removes **`G7DirectBLEObserver.swift`**). |

**Project membership:** **`scripts/sync_project_files_config.rb`** already globs **`Trio Watch App Extension/**/*.swift`** into the watch target — run **`scripts/sync_project_files.rb`** locally if Xcode does not pick up the new file automatically. Agents do not edit **`project.pbxproj`**.

**Follow-up (pre-build, same file):** **`emitExpectedWindowTick`** logs **`tick_epoch=`**, **`last_success_epoch=`**, **`eligible=true|false`**, **`reason=`** (`ok` / `stopped` / `no_sensor`), **`retroactive=`** — **`eligible=`** required so Better Stack queries filtering **`LIKE '%eligible=true%'`** (e.g. **`egv_success_rate_pct`**) match. **`stop()`** sets **`lastKnownExtSessionActive = false`**. **`sensorDidConnect`** sets **`sessionPhase = .preEGV`** explicitly.

---

## Task B2 — Daily counters + WatchState mirroring

**Goal (plan):** Same behavior as **`G7DirectBLEObserver`**: UserDefaults keys **`G7DirectBLEObserver.bleCountersCalendarDay`**, **`bleConnectsToday`**, **`bleEGVsToday`**; increment connects on **`sensorDidConnect`**; increment EGVs only after reliable glucose + dedup + valid glucose value (aligned with **`parseGlucose`** ordering); **`mirrorDailyCountersToWatchState()`** updates **`WatchState.shared.bleConnectsToday`** / **`bleEGVsToday`**.

**Implemented / verified in `G7WatchSensorAdapter.swift`:**

| Requirement | Notes |
|-------------|--------|
| Calendar rollover | **`loadDailyCounters()`** on init; **`loadDailyCountersIfNewCalendarDay()`** in **`start()`** and **`applyNewSensorName(_:)`** (WC name update without a full foreground **`start()`**). |
| **`applyNewSensorName(nil)`** | Does **not** call **`resumeScanning()`** (matches **`start()`** nil-sensor guard); logs **`sensor_name_cleared_no_scan`**. **`resumeScanning()`** only when **`name != nil`** and **`!isStopped`**. |
| Connect counter | **`sensorDidConnect`** → **`bleConnectsToday += 1`**, persist, mirror (matches observer **`didConnect`**). |
| EGV counter | After **`hasReliableGlucose`**, dedup, **`guard let` glucose** (non-nil mg/dL), then **`bleEGVsToday += 1`** — avoids counting **`egv_missing_glucose_value`** and keeps **`lastEGVEpoch` / expected-window** tied to real readings only. |
| WatchState | **`mirrorDailyCountersToWatchState()`** unchanged — **`Task { @MainActor in … }`**. |

**Acceptance:** **`WatchState.shared.bleConnectsToday`** and **`bleEGVsToday`** match persisted defaults across a connect + one reliable EGV cycle (same as observer semantics).

---

## Pre-build review disposition (fork + `G7WatchSensorAdapter`)

Systematic review before watch build; fork checked at **`/Users/charliechrisman/Code/src/cachrisman/diabetes/G7SensorKit`** where noted.

### Confirmed non-issues

| Item | Topic | Disposition |
|------|--------|-------------|
| 1 | **`G7Telemetry` / `emitG7Telemetry` line format** | Confirmed correct in fork: lines are **`module=g7_core event=<payload>`**. Queries and docs must use **`module=g7_core`** and **`event=`**, not a mistaken **`event=g7_core`**. |
| 2 | Double **`auth_payload_ignored`** | **Not present.** Branches in **`didReceiveAuthenticationResponse`** are mutually exclusive; guard-fail path **`return`**s early — **at most one** **`auth_payload_ignored`** per callback. |
| — | **`Package.swift` watchOS** | **N/A:** this fork uses **`G7SensorKit.xcodeproj`** only; no **`Package.swift`** at repo root. |

### Must fix before build (implemented in `G7WatchSensorAdapter.swift`)

| Item | Topic | Disposition |
|------|--------|-------------|
| 6 | **`expected_window` / `eligible=`** | **Required:** Better Stack success-rate query filters **`LIKE '%eligible=true%'`**; without **`eligible=`**, **`egv_success_rate_pct`** stays zero. Implemented **`eligible=true|false`** plus **`tick_epoch=`**, **`last_success_epoch=`**, **`reason=`**, **`retroactive=`** in **`emitExpectedWindowTick`**. |
| 5 | **`lastKnownExtSessionActive` after forced stop** | **`stop()`** sets **`lastKnownExtSessionActive = false`** so heartbeats do not keep reporting **`ext_session_active=true`** after teardown. |
| 7 | **`sessionPhase` on connect** | **`sensorDidConnect`** sets **`sessionPhase = .preEGV`** — defensive explicit reset for the auth-phase state machine. |

### Acceptable for build 195

| Item | Topic | Disposition |
|------|--------|-------------|
| 8 | EOS clears **`knownSensorName`** | Matches **legacy `G7DirectBLEObserver`** behavior; **accepted** for this build. |
| 4 | **`stop()`** invalidating **`pendingChainSession`** → **`chain_denied`** | **`nil` assignment and delegate callbacks are `@MainActor`** — serialized; **`pendingChainSession`** cleared before invalidation callbacks run — **probably fine**. |
| 3 | **`start()`** vs stale **`G7Sensor`** instance | **Low practical risk** if all sensor-name updates go through **`applyNewSensorName`** (WC handler); **accepted** with that assumption. |
| 10 | Late fork events lose **`g7_session`** after disconnect | **Accepted** for build **195**; document / accept correlation gap for delayed **`module=g7_core`** lines. |
| 9 | **`DispatchQueue.main.sync`** in **`triggerEndOfSessionFromEGV`** | Low deadlock probability from current call sites; **accepted for now**. |

**Bottom line:** Three targeted fixes in **`G7WatchSensorAdapter.swift`** (items **5**, **6**, **7**), then build.

---

## Phase C — WC sensor identity + retire **`G7DirectBLEObserver`** (completed)

**Feature branch commit:** `9e3a7d721` on **`feature/watch-g7-direct-ble-observer-synthesis`**.

| Area | Change |
|------|--------|
| **`WatchMessageKeys`** | **`g7_active_sensor_name`** — phone always includes value in watch-state dict (**`""`** when no name / not applicable). |
| **`WatchState` (iOS model)** | **`g7ActiveSensorName`** from **`G7CGMManager.sensorName`** when active CGM is G7 (**`setupWatchState`**). |
| **`AppleWatchManager.watchStateToDictionary`** | Serializes **`g7_active_sensor_name`**. |
| **Watch `WatchState.scheduleUIUpdate`** | **`applyG7ActiveSensorNameFromWatchPayloadIfPresent`** → **`G7WatchSensorAdapter.shared.applyNewSensorName`** when key present (main-thread path). |
| **Removed** | **`Trio Watch App Extension/G7DirectBLEObserver.swift`**. |
| **Misc** | **`ComplicationDebugView`** comment points at **`G7WatchSensorAdapter`**. |

**`patches/12-direct-ble-observer.patch`:** Regenerated via **`mid-stack-update.sh --patch 12 --from-feature-branch`** with **`--extra-files`** for **`G7WatchSensorAdapter.swift`**, **`ExtensionDelegate.swift`**, **`TrioApp.swift`** (those paths were outside the patch’s historical file list). Full stack **`patch-test`** passed.

**Drift note:** **`Trio/Sources/Modules/AppDiagnostics/View/AppDiagnosticsRootView.swift`** still differs on the feature branch vs patch **12** scope — treat as unrelated unless you intend it for this patch.

**Xcode:** Run your canonical **`sync_project_files`** workflow so **`G7WatchSensorAdapter.swift`** / **`ExtensionDelegate.swift`** membership stays correct (**agents do not edit `project.pbxproj`**).

---

## Changelog

### v1.8 (2026-05-09 23:04 CET)

- **Phase C:** WC **`g7_active_sensor_name`**, watch **`applyNewSensorName`** wiring, deleted **`G7DirectBLEObserver.swift`**, **`patches/12`** regenerated (**13 files** including adapter + **`ExtensionDelegate`** + **`TrioApp`**).

### v1.7 (2026-05-09 22:59 CET)

- **B2 follow-up:** **`applyNewSensorName(nil)`** — no **`resumeScanning()`** on **`G7Sensor(sensorID: nil)`**; telemetry **`sensor_name_cleared_no_scan`**.

### v1.6 (2026-05-09 22:55 CET)

- **Task B2:** Documented daily-counter parity with **`G7DirectBLEObserver`**; **`applyNewSensorName`** calls **`loadDailyCountersIfNewCalendarDay()`**; **`sensor(_:didRead:)`** reordered so valid glucose + dedup precede **`lastEGVEpoch`** / EGV counter / snapshot (fixes edge path where missing glucose could bump **`bleEGVsToday`** or advance expected-window anchor).

### v1.5 (2026-05-09 22:53 CET)

- Added **pre-build review disposition** (fork format, auth branch exclusivity, no Package.swift in fork, **`expected_window`** **`eligible=`**, **`stop()`** ext-session flag, **`sensorDidConnect`** phase reset, accepted backlog items).
- Corrected A6 bullet: **`auth_payload_ignored`** is not duplicated across branches.
- Noted **B1 follow-up** telemetry fields in **`emitExpectedWindowTick`**.

### v1.4 (2026-05-09 22:25 CET)

- Recorded **Task B1**: full **`G7WatchSensorAdapter`**, stub removal ordering from **`ExtensionDelegate`**, **`WatchState`** wiring to adapter; **`G7DirectBLEObserver`** left in tree until Phase C.

### v1.3 (2026-05-09 22:16 CET)

- Recorded **Task B0**: watch **`ExtensionDelegate`** + minimal **`G7WatchSensorAdapter`**, iOS **`TrioApp`** **`configureG7ForkTelemetry`**, and note **`debug(.service, …)`** substitution for **`TrioLogger`**. Reason: Phase B telemetry wiring traceability.

### v1.2 (2026-05-09 22:10 CET)

- Documented **Tasks A3/A4** (`G7CGMManagerState`, `G7CGMManager` iOS-only gates) and the **four companion files** ( **`G7DeviceStatus`**, **`ExtendedVersionMessage`**, **`G7GlucoseMessage`**, **`G7BackfillMessage`**) so watch builds avoid unconditional LoopKit while keeping **`G7Sensor`** message types on watchOS. Reason: Phase A fork work traceability + **`patches/02`** pin reminder.

### v1.1 (2026-05-09 21:46 CET)

- **Repository scope:** Replaced the note about mirroring `Trio-dev/G7SensorKit` with the actual flow — fork **push to GitHub** + **`patches/02-g7-reading-time-with-seconds.patch`** commit pin — since Trio clones G7SensorKit during build. Reason: align the log with how G7SensorKit enters Trio.

### v1.0 (2026-05-09 21:43 CET)

- Initial **Build 195** implementation log; documented **Task A6** completion in the standalone **G7SensorKit** fork (telemetry prefix, **`attach_path`** emits, auth single-parse + **`auth_value_received` / `auth_notify_subscribed` / `control_notify_subscribed`**, **`CBManagerState`** typo fix). Reason: preserve traceability for Phase A fork work before watch gating (A2–A5) and adapter phases.
