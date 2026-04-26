# Build 187 implementation log

**Version:** v1.1  
**Created:** 2026-04-26 12:11 CET  
**Last updated:** 2026-04-26 20:55 CET  
**Plan:** [watch-g7-ble-build187-impl-plan.md](watch-g7-ble-build187-impl-plan.md)  
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree)

---

## Summary

Implemented build 187 **Tasks A, B, E, and F** per the plan: load-bearing `registerForConnectionEvents` in `centralManagerDidUpdateState` `.poweredOn` before the foreground gate, `connect` with `options: nil`, process-lifetime counters and WatchState mirrors with `Task { @MainActor in … }` and capture-before-dispatch, main glanceable BLE EGV/conn line in `GlucoseTrendView`, and debug **G7 DIRECT BLE** section with APP GROUP block removed plus 5s refresh (`.task` + `Task.sleep` loop for stable lifecycle; `onAppear` for first paint). Build 188 items (C, D) were not implemented.

**v1.1 follow-up (external review):** Mirror `bleWasRestored` in `willRestoreState` as soon as `didReceiveWillRestoreState = true`. Replace per-body `Timer.publish(…).onReceive` with a single `.task` sleep loop (drops `import Combine`). Extract `G7DirectBleDebugSection` so `WatchState` is read from a dedicated view `body` (clearer than a parent `private var` for `@Observable` tracking; DATA STORE / logs still refresh-driven). Fix EGV line grammar (`1 EGV` vs `N EGVs`).

**Claude note (WatchState):** New BLE properties live on the **`@Observable class WatchState`** (main metrics block, ~lines 101–109), not on `extension TrioComplicationDataSource` (that extension only adds `watchBadgeText` and ends before the class). The earlier diff line-number read was a false alarm; no file move was required.

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
  - UI: one line `BLE: N EGV(s) / M conn` (singular `EGV` when `N == 1`) when `bleConnectsSinceLaunch > 0`; primary vs secondary by EGV count.  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/GlucoseTrendView.swift`  
- **Note:** Plan listed `TrioMainWatchView.swift`; the recency / source block lives in **`GlucoseTrendView`**, which is the main tab content—implemented there (same user-visible location).

### Task F — Debug G7 section + remove APP GROUP + timer

- **What:**  
  - Removed APP GROUP subsection from `dataStoreStateView` (Divider through container files), kept Path row.  
  - New **G7 DIRECT BLE** after RELOAD STATUS: Status, Last connect, Last BLE EGV (from `bleLastEGVDate` / `bleLastEGVValue` only), connects/launch, EGVs/launch, MOD-E count, Was restored.  
  - Observer: `connectionEventsSinceLaunch` in `connectionEventDidOccur` for `.peerConnected`; `bleLastEGV*` in `handleGlucose` in same `Task { @MainActor in … }` as snapshot save, with value capture; `bleWasRestored` mirrored in `willRestoreState` (immediate) and on each `centralManagerDidUpdateState` (captured `Bool`).  
  - 5s refresh: `.task { while !Task.isCancelled { await sleep 5s; loadSnapshot; loadLogFileStats; refreshTrigger } }` (no `Timer.publish` / no `import Combine`).  
  - G7 UI: `G7DirectBleDebugSection` (reads `WatchState.shared` in its own `body`).  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/ComplicationDebugView.swift`, `Views/GlucoseTrendView.swift` (EGV copy).

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
- **bleWasRestored** set to `true` in `willRestoreState` (after `didReceiveWillRestoreState = true`) and re-mirrored from `centralManagerDidUpdateState` (idempotent).  
- **No** stage timeouts or consecutive-failure counter (Build 188).

**Findings (v1.0):** Stale `bleWasRestored` until next `didUpdateState` was addressed in v1.1 by mirroring in `willRestoreState` too.

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

### v1.1 (2026-04-26 20:55 CET)

- Logged post-review hardening: `bleWasRestored` immediate mirror in `willRestoreState`, stable 5s polling via `.task` + `Task.sleep`, `G7DirectBleDebugSection` for observation, EGV line grammar, and clarification that BLE `WatchState` storage is on the `WatchState` class (not the small `TrioComplicationDataSource` extension).

### v1.0 (2026-04-26 12:11 CET)

- Initial build 187 implementation log, per-task file list, red-team self-review, deviations, and verification note.

---
