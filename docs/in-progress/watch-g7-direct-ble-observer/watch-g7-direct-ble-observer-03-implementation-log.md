# Trio Watch G7 Direct BLE Observer Implementation Log

**Version:** v5  
**Status:** In Progress  
**Created:** 2026-04-24 20:41 CET  
**Last updated:** 2026-04-24 23:59 CET

## Branch and base

- Branch: `cursor/watch-g7-direct-ble-observer-a-57cf`
- Base branch: `baseline-dev-patches-01-10`
- Base commit: `bf9cbc7e8395e66e0546ccb6cb750083779e44df`

## Reference fetch

Fetched all 35 requested reference files into `/tmp/g7-observer-refs` before implementation:

- DiaBLE: 13/13 files fetched successfully.
- G7SensorKit: 22/22 files fetched successfully. The prompt described 21 files but listed 22 URLs; all listed URLs were fetched.

No Trio implementation file under `docs/in-progress/watch-direct-ble-cgm/` was read during design or implementation. During final static validation, one broad repository-wide search intended to confirm absence of forbidden event names accidentally returned snippets from that forbidden folder; no file from that folder was opened with `ReadFile`, and no implementation decision was based on that output.

## Phase log

### Phase 1 - Existing scaffolding

- Located and used `TrioComplicationDataStore`, `TrioComplicationSnapshot`, `WatchLogger`, `WatchState`, `TrioWatchApp`, `TrioMainWatchView`, and `GlucoseTrendView`.
- Confirmed `TrioComplicationDataStore.save(_:triggerReload:minInterval:)` exists and is main-thread confined internally.
- Confirmed the main recency UI is in `GlucoseTrendView`.

### Phase 2 - Source attribution

Files touched:

- `Trio Watch Shared/TrioComplicationDataStore.swift`
- `Trio Watch App Extension/WatchState.swift`
- `Trio Watch App Extension/Views/TrioMainWatchView.swift`

Changes:

- Added `TrioComplicationDataSource` with `watchConnectivity`, `healthKit`, `g7DirectBLE`, and `unknown`.
- Added optional `source` to `TrioComplicationSnapshot`.
- Included source in the dedup fingerprint so a same-reading takeover from BLE can update the UI source label.
- Marked HealthKit snapshots as `.healthKit`, phone-relay snapshots as `.watchConnectivity`, and cached snapshots using their stored source.

### Phase 3 - Watch state and lifecycle

Files touched:

- `Trio Watch App Extension/WatchState.swift`

Changes:

- Added `G7DirectBLEStatus` and WatchState fields for current BLE status, last BLE event time, last BLE reading time, and displayed reading source.
- `WatchState.handleForegroundActiveEntry()` starts/resumes the observer via `G7DirectBLEObserver.shared.applyForegroundActiveEntry()` (the observer does not implement `handleForegroundActiveEntry` — that name is `WatchState`’s hook only; a mistaken `handleForegroundActiveEntry()` call on the observer broke Fastlane/Xcode compile until corrected).
- On inactive/background transitions, recorded lifecycle status but did not call `stop()`.
- Kept scene-phase wiring inside the existing `WatchState` lifecycle; `TrioWatchApp.swift` did not require a final code change.

### Phase 4 - CoreBluetooth observer

File:

- `Trio Watch App Extension/G7DirectBLEObserver.swift`

Core shape (unchanged from first land):

- Long-lived restoration-backed `CBCentralManager` on a dedicated serial queue.
- Attach ladder: persisted identifier, `retrieveConnectedPeripherals(withServices:)` for FEBC/data service, then broad scan.
- Tolerant standalone matching on DXCM/DX02/DX01/Dexcom names and FEBC/data-service advertisements; broad service/characteristic discovery.
- Subscribed to auth notify; logged J-PAKE skip; subscribed to control notify; EGV opcode `0x4e` with response; G7 EGV parse per G7SensorKit offsets; snapshots to complication store; backfill notify for logging only; disconnect/failure reconnect with bounded backoff; scan/connect timers that do not tear down an already-connected session.

**Synthesis updates** (branch `feature/watch-g7-direct-ble-observer-synthesis`; design [01-design.md](01-design.md) v2, [g7-direct-ble-synthesis-blueprint.md](g7-direct-ble-synthesis-blueprint.md)):

- **Auth (MOD-B):** Prefer `authenticated && bonded` before `advanceToControl`; log partial auth; **6s** permissive fallback if no qualifying auth packet (replaces earlier 8s / advance-on-authenticated-only wording).
- **EGV cadence (MOD-A):** **330s** fallback timer armed from **successful control write acks**; additional `sendEGVRequest` on bonded authenticated auth traffic after advance (`auth_transition`); **60s** reschedule **only** for `control_not_ready` (control notify not yet on). Not “60s while connected” for the main periodic path.
- **Control write retries (MOD-A):** Up to **three** 10s-spaced retries after consecutive failed write acks; **fourth** consecutive failure → `control_write_retries_exhausted` (see named threshold + comment in source — three retry *attempts*, not three total failures).
- **Activation anchor (MOD-C):** `sessionActivationDate` once per connect cycle inside `parseGlucose`.
- **Connection events (MOD-E):** `registerForConnectionEvents` after starting scan; `connectionEventDidOccur` → `startOrResume` on `.peerConnected` when not hard-stopped.

### Phase 5 - UI indicator

File touched:

- `Trio Watch App Extension/Views/GlucoseTrendView.swift`

Changes:

- Added a second compact line under the existing recency line: current reading source plus BLE status and last BLE event age.
- Colored the line green/yellow/red/secondary based on BLE status.

## Deviations from the plan/design during implementation

- **`WatchState` → observer entrypoint:** Code briefly called **`G7DirectBLEObserver.shared.handleForegroundActiveEntry()`**, which does not exist; the observer’s public API is **`applyForegroundActiveEntry()`**. A **Fastlane** build reported `value of type 'G7DirectBLEObserver' has no member 'handleForegroundActiveEntry'` at **`WatchState.swift:281`**; fixed to **`applyForegroundActiveEntry()`** and recorded here (same amend as the retry-threshold doc commit).
- The implementation plan listed optional parser unit tests, but none were added in this pass because the prompt explicitly excludes compilation/project membership and the parser is isolated in a new watch-extension source that is not yet target-wired. Static review covered the parser offsets against `G7SensorKit/Messages/G7GlucoseMessage.swift`.
- Backfill was kept to notification logging only. This is intentional scope control for first attach reliability; active backfill can be layered after live EGV is proven on device.

## Validation performed

- Static source review in the files modified and added.
- **Compile signal:** Fastlane/Xcode build caught the **`handleForegroundActiveEntry`** vs **`applyForegroundActiveEntry`** mismatch on **`G7DirectBLEObserver`** (see deviations above).
- **EGV timer interaction (first device run):** `sendEGVRequest` cancels `egvRequestWorkItem` at entry, so a live **330s** fallback and a **60s** `control_not_ready` reschedule should not double-fire the same send path; still worth correlating `g7_ble_egv_request_sent` reasons (`control_not_ready`, `fallback_timer_330s`, `auth_transition`, `control_write_retry`) in BetterStack to confirm ordering under real notify timing.
- Reference cross-checks:
  - UUIDs and EGV payload offsets checked against `G7SensorKit/BluetoothServices.swift` and `G7SensorKit/Messages/G7GlucoseMessage.swift`.
  - Attach strategy checked against `DiaBLE/BluetoothDelegate.swift` and `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`.
  - Auth advance behavior checked against `G7SensorKit/G7CGMManager/G7Sensor.swift` and DiaBLE's G7 auth comments.
- No `xcodebuild`, `ci/local-build.sh`, `scripts/sync_project_files.rb`, or Xcode project-file edit was run.

## Final state at handoff

Done:

- Design doc, implementation plan, and implementation log exist in `docs/in-progress/watch-g7-direct-ble-observer/`.
- Watch-extension source exists for the direct BLE observer.
- Shared snapshot source attribution is modeled and persisted.
- Watch app main UI exposes reading source and BLE observer status.
- Scene lifecycle starts on active and does not tear down on inactive/background.

Pending for human follow-up:

- Add new Swift file(s) to the correct Xcode targets, especially `G7DirectBLEObserver.swift`.
- Run Xcode build/device verification.
- Test on a watch with the official Dexcom G7 watch app installed and direct-to-watch active.
- Review BetterStack `event=g7_ble_*` traces to tune auth fallback, scan cadence, and EGV cadence (330s fallback vs `auth_transition` vs `control_not_ready`).

## Changelog

### v5 (2026-04-24 23:59 CET)
- **WatchState build fix:** Aligned **`WatchState.handleForegroundActiveEntry()`** with **`G7DirectBLEObserver.applyForegroundActiveEntry()`**; updated **Phase 3** wording, **deviations**, and **validation** so the log records why Fastlane failed (`no member 'handleForegroundActiveEntry'` on the observer) and the correct API boundary.

### v4 (2026-04-24 23:38 CET)
- Refreshed **Phase 4** to match post-synthesis behavior (330s / 60s split, strict-preferred auth + 6s fallback, write-retry semantics, MOD-C/E) so the log is not stuck on the original PR29-only “60s while connected” description.
- Documented **control-write retry budget** explicitly (four consecutive failures = three retry attempts) to match the clarified constant/comment in `G7DirectBLEObserver.swift`.
- Added a short **validation** note on correlating EGV `send` reasons in BetterStack when both `control_not_ready` and fallback timers could theoretically overlap in wall time.

### v3 (2026-04-24 20:57 CET)
- Corrected the phase 3 file list after final review showed `TrioWatchApp.swift` was unchanged in the final implementation.
- Keeps the implementation log aligned with the actual committed file set for handoff review.

### v2 (2026-04-24 20:53 CET)
- Corrected the forbidden-folder note after a final validation search returned snippets from the excluded prior-doc folder.
- Preserves an accurate audit trail for clean-room constraints while clarifying that no prior implementation document was opened or used for design.

### v1 (2026-04-24 20:41 CET)
- Created the implementation log for the clean G7 direct BLE observer effort.
- Recorded branch/base, fetched references, implementation phases, validation, and handoff state so follow-up build/device work has an audit trail.
