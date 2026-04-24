# Trio Watch — G7 Direct BLE Observer (Implementation Log)

Version 1.0.

- **Branch:** `cursor/feature/watch-g7-direct-ble-observer-1c81`
- **Base branch:** `baseline-dev-patches-01-10`
- **Base commit:** `bf9cbc7e8 feat: watch-session-crash-guard`

---

## Phase 1 — Scaffolding & shared types

**Files created:**

- `Trio Watch Shared/TrioComplicationDataSource.swift` — 3-case enum
  (`watchConnectivity` / `healthKit` / `g7DirectBLE`). Codable + Sendable.

**Files modified:**

- `Trio Watch Shared/TrioComplicationDataStore.swift` — added `source:
  TrioComplicationDataSource?` field to `TrioComplicationSnapshot`,
  extended the designated initializer with a defaulted `source:`
  parameter, and added custom `Codable` implementation that uses
  `decodeIfPresent` so snapshots written by older builds still decode
  (backward compatibility). Also extended the convenience
  `save(glucose:trend:delta:...)` overload to accept `source:`.
- `ComplicationSnapshotFingerprint` is **not** extended with `source`. By
  design (noted in §15 of the design doc): the dedup comparator treats
  two paths delivering the same reading as duplicates. `source` records
  which path **won**, not how many paths contributed. Keeping `source`
  out of the fingerprint also preserves the pre-dispatch dedup
  invariant.

Nothing was changed in `TrioWatchComplication/…` — the complication
extension can ignore the new optional field. `TrioComplicationSnapshot`
call sites in `TrioWatchComplicationPreview.swift` were not modified; the
default `source: nil` keeps them source-compiling.

## Phase 2 — BLE constants, parsers, logging

**Files created:**

- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEConstants.swift` —
  service / characteristic UUIDs, opcodes (`egvRequestOpcode = 0x4e`,
  `authChallengeRxOpcode = 0x05`), timing constants (auth fallback 6 s,
  EGV fallback 330 s, reconnect backoff [2,5,10,20,30]), restoration
  identifier `trio.g7.observer.v1`, event family name strings, and the
  `ConnectSource` attribution enum.
- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEDataReader.swift` —
  little-endian integer reads and a hex-preview helper. Module-scoped so
  it does not extend the global `Data` namespace.
- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEMessages.swift` —
  `G7DirectAuthChallenge`, `G7DirectGlucoseMessage`, and
  `G7DirectBackfillMessage`. Parsing follows
  `G7SensorKit/Messages/G7GlucoseMessage.swift` and
  `G7SensorKit/Messages/G7BackfillMessage.swift` byte-for-byte; no
  dependency on LoopKit. `G7DirectGlucoseMessage.nightscoutArrowString`
  matches `WatchState.hkTrendString` thresholds so BLE and HK deltas map
  to the same arrow strings for the same slope.
- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEObserverStatus.swift` —
  5-state enum plus `G7DirectBLEObserverSnapshot` DTO.
- `Trio Watch App Extension/G7DirectBLE/G7DirectBLELog.swift` — tiny
  `G7BLELog.emit(event:fields:)` forwarder that preserves `#fileID /
  #line / #function` into `WatchLogger.shared.log` and formats
  `event=<name> <k=v …>` lines. Sanitizes whitespace and `=` inside
  values.

## Phase 3 — Observer core

**Files created:**

- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEObserver.swift` —
  ~700 lines. Singleton `@objc` NSObject with:
  - `primeCentral()` / `start()` / `stop()` / `scenePhaseChanged(_:)`
    public API, all main-thread confined.
  - `CBCentralManager` allocated on a dedicated serial queue
    (`com.trio.watch.g7.ble`, `.userInitiated`), restoration identifier
    `trio.g7.observer.v1`, `ShowPowerAlert: false`.
  - Attach ladder: `retrievePeripherals(withIdentifiers:)` →
    `retrieveConnectedPeripherals(withServices: [cgmServiceUUID])` →
    `retrieveConnectedPeripherals(withServices: [advertisementServiceUUID])`
    → `scanForPeripherals(withServices: [FEBC, cgmService])`.
  - `willRestoreState` participation: restored peripherals dispatched
    through the same `evaluatePeripheral` path with
    `source=restored`.
  - Discovery: `discoverServices(nil)` + `discoverCharacteristics(nil,
    for:)`.
  - Notify enables: authentication immediately, control + backfill on
    advance.
  - J-PAKE: characteristic cached, **never subscribed**. Logged as
    `g7_ble_jpake_skipped` on every discovery.
  - Auth advance condition: permissive with 6 s fallback timer (design
    §8). Timer starts when auth notify is confirmed enabled; cancelled
    when auth challenge with `authenticated && bonded` arrives first.
  - EGV request cadence: first_connect + auth_transition + 330 s
    fallback timer (design §9). All three paths funnel through
    `writeEGVRequestOnQueue(cadence:)` — the **only** path that writes
    to the peripheral.
  - Control-write failure: up to 3 retries / connect cycle, 10 s
    spacing (design §10).
  - Backfill: parsed and logged, not forwarded into the data store
    (design §11).
  - Reconnect: aggressive on every disconnect / connect failure;
    backoff 2/5/10/20/30 s; reset on `.poweredOn` and on `didConnect`.
    Never scene-gated (design §12 anti-pattern guard).
  - Preferred identifier persistence in watch-local `UserDefaults`
    under `trio.g7.observer.preferredPeripheralUUID`; cleared after 5
    consecutive connect failures for the same identifier.
  - Per-cycle state (`cycleStartedAt`, `cycleEGVCount`,
    `controlWriteAttemptThisCycle`, timers) reset via
    `resetPerCycleStateOnQueue`, which also emits
    `g7_ble_session_outcome` with `outcome`, `final_stage`,
    `duration_ms`, `egv_count`.
  - EGV processing builds a `TrioComplicationSnapshot` with
    `source: .g7DirectBLE`, computes local delta vs the last BLE
    reading (nil → `"--"`), and persists via
    `TrioComplicationDataStore.shared.save(_, triggerReload: true,
    minInterval: 5)`.
  - Status publishing: coarse mapping bleQueue state → UI via
    `Task { @MainActor in WatchState.shared.applyG7ObserverSnapshot(...) }`.
    `publishStatusOnQueue(.active)` demotes to `.stalled` if the last
    EGV is older than `uiStalledThresholdSeconds` (6 min).

**Deviations from the design doc during implementation:** none. One
thread-safety refinement (`isExplicitlyStopped` moved to `bleQueue`-
isolated; a tiny main-only `hasAllocatedCentralManager` flag added to
avoid data races on the observer's `centralManager` property).

## Phase 4 — Integration

**Files modified:**

- `Trio Watch App Extension/WatchState.swift`:
  - Added `g7ObserverSnapshot: G7DirectBLEObserverSnapshot` and
    `latestReadingSource: TrioComplicationDataSource?` as `@Observable`
    properties.
  - Added `applyG7ObserverSnapshot(_:)` and
    `applyBLEObservedReading(glucose:trend:delta:readingDate:)`, both
    `@MainActor`, for the observer to call back into main-thread
    `WatchState` updates.
  - WC path: `saveComplicationSnapshot(from:)` now tags the built
    snapshot `source: .watchConnectivity` and sets
    `latestReadingSource = .watchConnectivity` after a successful save.
  - HK path: `finishHKGlucoseObserverFetch(...)` now tags the built
    snapshot `source: .healthKit` and sets `latestReadingSource`
    conditionally (preserving `.g7DirectBLE` attribution if BLE
    already owns the currently-displayed reading).

- `Trio Watch App Extension/ExtensionDelegate.swift`:
  - `applicationDidFinishLaunching` calls
    `G7DirectBLEObserver.shared.primeCentral()` (eager allocation, no
    scanning).
  - `applicationDidBecomeActive` calls `G7DirectBLEObserver.shared.start()`.

- `Trio Watch App Extension/TrioWatchApp.swift`:
  - On `.active` scene phase, calls
    `G7DirectBLEObserver.shared.scenePhaseChanged(.active)`.
  - On `.inactive` / `.background`, calls
    `.scenePhaseChanged(.inactive)` — deliberate no-op for the
    observer; the log helps explicitly distinguish the "brief scene
    detour" case from proactive teardown. Anti-pattern guard is
    inline comment.

## Phase 5 — UI

**Files created:**

- `Trio Watch App Extension/Views/G7DirectBLEStatusRow.swift` — compact
  row: colored status dot, `BLE:<state>`, `src:<source>`, `<last-BLE-age>`.
  Renders only when at least one signal has non-default content so
  cold-watch UI matches the baseline.

**Files modified:**

- `Trio Watch App Extension/Views/TrioMainWatchView.swift`:
  - Wrapped `GlucoseTrendView` in a `VStack { GlucoseTrendView …;
    G7DirectBLEStatusRow(…) }` inside the page-0 `ZStack`, keeping the
    syncing-animation overlay at its existing absolute position.
  - Added `g7StatusRowFontSize` scaling to match
    `GlucoseTrendView.minutesAgoFontSize`.

## Phase 6 — Self-review

Performed per `AGENTS.md` self-review protocol:

1. Re-read every modified file top to bottom.
2. Confirmed all imports resolve.
3. Confirmed each `TrioComplicationSnapshot` call site compiles with the
   added `source:` default parameter (only the HK / WC / BLE /
   convenience paths pass it explicitly; previews, fallback snapshot,
   and complication extension continue to omit it).
4. Confirmed `ComplicationSnapshotFingerprint` and `shouldUpdate`
   continue to ignore `source`, preserving the Phase 3.0 dedup
   invariant.
5. Confirmed main-thread confinement: `WatchState` writes only from
   `Task { @MainActor in … }` or from already-main contexts;
   `TrioComplicationDataStore.save(...)` hops internally (uses `onMain`).
6. Confirmed the **only** write path to the peripheral is
   `writeEGVRequestOnQueue`, which hard-codes payload
   `Data([G7DirectBLEConstants.egvRequestOpcode])`. J-PAKE, app-key,
   and `appKeyChallenge` opcodes are deliberately absent from
   `G7DirectBLEConstants` — any future caller that wants to add one
   must edit that file, making the observer-only safety contract
   visually enforced.
7. Confirmed reconnect is never scene-gated and no scan timeout exists,
   matching the "anti-patterns observed in prior attempts" guidance.
8. `NotificationCenter` shadowing is not a concern (no Notification APIs
   are used in the new code).

## Validation performed

- Static review only. Per prompt scope, no `xcodebuild`, no
  `ci/local-build.sh`, no `scripts/sync_project_files.rb`, no
  `project.pbxproj` edits.
- No unit tests added in this pass (see plan §Unit tests). Adding them
  would require the human's Xcode target-membership step first.

## Final state at handoff

**Done:**

- Design doc + implementation plan + this log in
  `docs/in-progress/watch-g7-direct-ble-observer/`.
- Six new source files under `Trio Watch App Extension/G7DirectBLE/`.
- One new source file under `Trio Watch App Extension/Views/`.
- One new source file under `Trio Watch Shared/`.
- Four existing files modified with additive, backward-compatible
  changes.

**Pending (human step):**

- Add the new Swift files to the `Trio Watch App Extension`,
  `Trio Watch Shared` (as appropriate) and `Trio Watch App Tests`
  targets via the canonical Xcode project sync workflow. Per repo
  policy this must not be done by an agent session.
- Compilation verification (`ci/local-build.sh --base-branch dev
  --build-only` or equivalent Xcode run).
- Device validation against a real Dexcom G7 sensor + Dexcom G7 watch
  app in direct-to-watch mode.
- Unit tests for message parsers (listed in `02-implementation-plan.md`
  §Unit tests).

**Open / device-test-only verification:**

- Does `retrieveConnectedPeripherals(withServices: [cgmServiceUUID])`
  return the peripheral that the Dexcom G7 watch app is actively
  connected to, with `peripheral.state == .connected`, and does
  `connect(...)` on that peripheral work without cancelling the
  Dexcom app's ownership?
- How often does the 6 s auth fallback timer fire vs a real auth-gate
  advance? A device session showing the ratio would validate §8.
- Does the sensor accept the `[0x4e]` control write on Trio's GATT
  view while simultaneously serving the Dexcom app? The observer-only
  BLE premise rests on this being yes.
- EGV cadence in practice: once per ~5 min (expected, per §9) or
  more/less?
