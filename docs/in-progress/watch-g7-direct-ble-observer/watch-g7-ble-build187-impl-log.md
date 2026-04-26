# Build 187 implementation log

**Version:** v1.0  
**Created:** 2026-04-26 12:11 CET  
**Last updated:** 2026-04-26 12:11 CET  
**Plan:** [watch-g7-ble-build187-impl-plan.md](watch-g7-ble-build187-impl-plan.md)  
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree)

---

## Summary

Implemented build 187 **Tasks A, B, E, and F** per the plan: load-bearing `registerForConnectionEvents` in `centralManagerDidUpdateState` `.poweredOn` before the foreground gate, `connect` with `options: nil`, process-lifetime counters and WatchState mirrors with `Task { @MainActor in … }` and capture-before-dispatch, main glanceable BLE EGV/conn line in `GlucoseTrendView`, and debug **G7 DIRECT BLE** section with APP GROUP block removed plus 5s refresh timer. Build 188 items (C, D) were not implemented.

**Acceptance / verification (agent session):** Static re-read of all touched files; `read_lints` on Swift sources; line-length nits in `GlucoseTrendView` addressed. **No** `xcodebuild` / `ci/local-build.sh` (per **AGENTS.md**). On-device / BetterStack checks are user follow-up per the plan.

---

## Per-task log

### Task A — `registerForConnectionEvents` in `.poweredOn`

- **What:** In `G7DirectBLEObserver.centralManagerDidUpdateState`, case `.poweredOn`, after `noteStatus(.searching)` and **before** `if hasReceivedForegroundEntry`, call `registerForConnectionEvents` with `G7BLEUUID.advertisement` and `dataService`, then log `event=g7_ble_connection_events_registered reason=powered_on`.
- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Note:** In-scan `registerForConnectionEvents` retained with comment per plan (redundant defense until Task A validated).

### Task B — Suppress accessory-disconnected notification

- **What:** `centralManager.connect(peripheral, options: nil)`.
- **Files:** `G7DirectBLEObserver.swift`

### Task E — Counters + main view line

- **What:**  
  - Observer: `connectsSinceLaunch`, `egvsSinceLaunch` (increments in `didConnect` and `handleGlucose` with captured ints for main-actor mirrors).  
  - `WatchState`: `bleConnectsSinceLaunch`, `bleEGVsSinceLaunch`, `bleLastConnectAt`.  
  - UI: one line `BLE: N EGVs / M conn` when `bleConnectsSinceLaunch > 0`; primary vs secondary by `bleEGVsSinceLaunch > 0`.  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/GlucoseTrendView.swift`  
- **Note:** Plan listed `TrioMainWatchView.swift`; the recency / source block lives in **`GlucoseTrendView`**, which is the main tab content—implemented there (same user-visible location).

### Task F — Debug G7 section + remove APP GROUP + timer

- **What:**  
  - Removed APP GROUP subsection from `dataStoreStateView` (Divider through container files), kept Path row.  
  - New **G7 DIRECT BLE** after RELOAD STATUS: Status, Last connect, Last BLE EGV (from `bleLastEGVDate` / `bleLastEGVValue` only), connects/launch, EGVs/launch, MOD-E count, Was restored.  
  - Observer: `connectionEventsSinceLaunch` in `connectionEventDidOccur` for `.peerConnected`; `bleLastEGV*` in `handleGlucose` in same `Task { @MainActor in … }` as snapshot save, with value capture; `bleWasRestored` from `didReceiveWillRestoreState` on each `centralManagerDidUpdateState` (via `Task { @MainActor in }` with captured `Bool`).  
  - `onReceive(Timer.publish(every: 5, …))` → `loadSnapshot()`, `loadLogFileStats()`, `refreshTrigger = UUID()`.  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/ComplicationDebugView.swift` (`import Combine` for `Timer.publish`).

---

## Deviations / follow-ups

1. **Worktree / stash:** If you were on `feature/treatments-fixed-bottom-action` with WIP, the session ran `git stash push -u` and checked out `feature/watch-g7-direct-ble-observer-synthesis`. Restore with `git checkout <prior-branch> && git stash pop` as needed.  
2. **BetterStack string:** Log line for registration uses `g7_ble_connection_events_registered` (matches plan code block; acceptance text in plan sometimes shortens the prefix).  
3. **Build 188 + removal of scan-path** `registerForConnectionEvents`: **not** done (explicitly deferred in plan).

---

## Red-team self-review (prompt 05), three passes

### Pass 1 — Concurrency and plan alignment

- **Threading:** All new `WatchState` mutations go through `Task { @MainActor in }` (or the existing `noteStatus` / same MainActor `Task` as snapshot for `bleLast*`, `bleEGVsSinceLaunch`). Counters use `let` capture before `Task` for `connectsSinceLaunch`, `egvsSinceLaunch`, `connectionEventsSinceLaunch`—matches plan.  
- **DidConnect vs handleGlucose order:** Counters on BLE queue, then async hop—acceptable per plan.  
- **dedup path in** `handleGlucose`: EGV/egv-mirror/last-EGV not updated on early return (correct).  
- **bleWasRestored** mirrored on every `centralManagerDidUpdateState` so the debug screen reflects current `didReceiveWillRestoreState` (stable after first willRestore if any).  
- **No** stage timeouts or consecutive-failure counter (Build 188).

**Findings:** None blocking; optional nit that `bleWasRestored` main-actor updates on every state transition is slightly chatty (harmless for a Bool).

### Pass 2 — UI / Observation

- **ComplicationDebugView** reads `WatchState.shared` in `g7BLEDebugView` plus 5s backstop; BLE rows update when timer fires; observer-pushed `Task` updates are visible on next re-render.  
- **G7** debug rows do not use `latestSnapshot()` for last BLE EGV (per plan).  
- **Line length** in `GlucoseTrendView` addressed to satisfy SwiftLint-style limits.

**Findings:** None blocking.

### Pass 3 — Lifecycle and regressions

- **connect options nil** does not remove in-app disconnect handling.  
- **registerForConnectionEvents** twice (poweredOn + scan) is intentional.  
- **loadLogFileStats** on 5s timer: guarded by `isLoadingLogFiles` inside the async work (may skip a tick if load takes >5s—acceptable for debug).  
- **VStack** local `let` bindings in `GlucoseTrendView`: verified linter clean; if an older Swift toolchain chokes, replace with `Group`+computed `String` properties in the struct (unlikely for current Trio target).

**Findings:** None blocking.

**Verdict:** **clean** for build 187 scope. Residual: compile proof via local **`ci/local-build.sh`**; device / BetterStack validation per plan.

---

## Changelog

### v1.0 (2026-04-26 12:11 CET)

- Initial build 187 implementation log, per-task file list, red-team self-review, deviations, and verification note.

---
