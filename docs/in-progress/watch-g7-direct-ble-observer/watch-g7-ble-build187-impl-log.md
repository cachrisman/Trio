# G7 direct BLE — implementation log (Build 187 & 188)

**Version:** v1.2  
**Created:** 2026-04-26 12:11 CET  
**Last updated:** 2026-04-27 11:52 CEST  
**Plan:** [watch-g7-ble-build187-impl-plan.md](watch-g7-ble-build187-impl-plan.md) (v1.10 — includes **Implementation log (Build 188)** table)  
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree)

---

## Summary

**Build 187** implemented **Tasks A, B, E, and F** per the plan: load-bearing `registerForConnectionEvents` in `centralManagerDidUpdateState` `.poweredOn` before the foreground gate, `connect` with `options: nil`, process-lifetime counters and WatchState mirrors with `Task { @MainActor in … }` and capture-before-dispatch, main glanceable BLE EGV/conn line in `GlucoseTrendView`, and debug **G7 DIRECT BLE** section with the APP GROUP block removed plus 5s refresh (`.task` + `Task.sleep` loop; `onAppear` for first paint). **v1.1 (external review):** mirror `bleWasRestored` in `willRestoreState` immediately; `G7DirectBleDebugSection` for reliable `@Observable` reads; EGV line grammar; drop `import Combine` / `Timer.publish` pattern.

**Build 188** (same branch; execution logged in the plan’s **Implementation log (Build 188)** table) shipped **Tasks A–H** plus a red-team fix: Option C auth timing, session timing ladder, debug 1s/10s + scoped `.id`, horizontal chart/main/debug tabs, main single-line status, complication `· BLE`, failure / MOD-E / peripheral logs, stage timeouts, removal of scan-path `registerForConnectionEvents` and redundant `bleWasRestored` in `didUpdateState`. **Post-implementation code review** adjusted ladder `t0` to **`centralManager.connect(…)`**, moved `.id(refreshTrigger)` to **data store** + **log files** (not RELOAD), and added **`connectFailureMetricCountedThisAttempt`** so a timeout and `didFailToConnect` do not double-count; `connectFailureMetricCountedThisAttempt` is also cleared in **`didConnect`**.

**Claude note (WatchState):** BLE session fields live on the **`@Observable class WatchState`**, not on the small `TrioComplicationDataSource` extension (badge text only).

**Acceptance / verification (agent):** Static re-read of changed files; **no** `xcodebuild` / `ci/local-build.sh` (per **AGENTS.md**). Device / **BetterStack** = user follow-up.

---

## Per-task log — Build 187

### Task A — `registerForConnectionEvents` in `.poweredOn`

- **What:** In `G7DirectBLEObserver.centralManagerDidUpdateState`, case `.poweredOn`, after `noteStatus(.searching)` and **before** `if hasReceivedForegroundEntry`, call `registerForConnectionEvents` with `G7BLEUUID.advertisement` and `dataService`, then log `event=g7_ble_connection_events_registered reason=powered_on`.
- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Note (187):** In-scan `registerForConnectionEvents` was retained with a “redundant defense” comment until MOD-E was validated. **Build 188 Task H** removed the scan-path registration; **`.poweredOn` remains** the load-bearing site.

### Task B — Suppress accessory-disconnected notification

- **What:** `centralManager.connect(peripheral, options: nil)`.
- **Files:** `G7DirectBLEObserver.swift`

### Task E — Counters + main view line

- **What:**  
  - Observer: `connectsSinceLaunch`, `egvsSinceLaunch` (increments in `didConnect` and `handleGlucose` with captured ints for main-actor mirrors).  
  - `WatchState`: `bleConnectsSinceLaunch`, `bleEGVsSinceLaunch`, `bleLastConnectAt`.  
  - **187 UI:** one line `BLE: N EGV(s) / M conn` (singular `EGV` when `N == 1`) when `bleConnectsSinceLaunch > 0`; primary vs secondary by EGV count. **188** replaced this with the single-line recency + `· BLE · egvs/conns` design (see plan Task D).  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/GlucoseTrendView.swift`  
- **Note:** Plan sometimes listed `TrioMainWatchView.swift`; recency / BLE line lives in **`GlucoseTrendView`**.

### Task F — Debug G7 section + remove APP GROUP + timer (187)

- **What:**  
  - Removed APP GROUP subsection from `dataStoreStateView` (kept Path row).  
  - New **G7 DIRECT BLE** after RELOAD STATUS: status, last connect, last BLE EGV (`bleLastEGVDate` / `bleLastEGVValue`), connects/launch, EGVs/launch, MOD-E count, was restored.  
  - Observer: `connectionEventsSinceLaunch` on `peerConnected`; `bleLastEGV*` in `handleGlucose` with the snapshot `Task`; `bleWasRestored` in `willRestoreState` and (until 188) in `didUpdateState`.  
  - **187:** 5s combined `.task` for snapshot + log stats. **188:** 1s snapshot + 10s log stats, scoped `.id` (see plan).  
- **Files:** `G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/ComplicationDebugView.swift`, `Views/GlucoseTrendView.swift` (EGV copy for 187 line).

---

## Build 188 — narrative (authoritative table in plan v1.10)

See **[Implementation log (Build 188)](watch-g7-ble-build187-impl-plan.md#implementation-log-build-188)** in `watch-g7-ble-build187-impl-plan.md` for the commit-ordered table, file list, and short SHAs. Highlights:

- **Auth (Option C):** 30s auth watchdog; advance to control on `auth_notify_enabled_observer`; `session_outcome` phase ladder; `g7_ble_auth_payload_post_advance` for opcode 0x05 when already past auth.
- **UI:** `ComplicationDebugView` 1s/10s, `.id` on snapshot + log-file **@State**; `TrioMainWatchView` horizontal `TabView` chart | main | debug; `GlucoseTrendView` single status line; `TrioWatchComplication` corner `· BLE` when `source == .g7DirectBLE`.
- **Observability / safety:** `consecutiveConnectFailures` + `mode_e_total` + `peripheral_id_persisted`; `stageTimeoutWorkItem` (30s / 10s); H: remove scan re-registration and redundant `bleWasRestored` in `didUpdateState`.
- **After merge review:** Ladder `sessionPhaseConnectAt` stamped **at** `connect()`; `connectFailureMetricCountedThisAttempt`; `.id` on log files, not RELOAD; flag reset in `didConnect`.

---

## Deviations / follow-ups

1. **Worktree / stash:** If you use multiple branches, restore any stashed WIP with `git stash pop` as appropriate after switching back.  
2. **BetterStack string:** Log line for registration is `g7_ble_connection_events_registered` (plan prose sometimes shortens the prefix).  
3. **Build 188 (scan-path, bleWasRestored):** Shipped in **Task H**; see plan table. **No longer** deferred.  
4. **Compile / device:** Proof via **`ci/local-build.sh`** and on-watch / **BetterStack** runs remain user follow-up.

---

## Red-team self-review (prompt 05) — Build 187

*Historical.* Three passes below were completed for **Build 187** scope; they do **not** re-audit 188 (see plan implementation log and Build 188 narrative above). Build 188 had a focused red-team pass on **`advanceToControl` / stage timeout** ordering and follow-up on ladder semantics and the debug `.id` placement.

### Pass 1 — Concurrency and plan alignment

- **Threading:** New `WatchState` mutations from the observer use `Task { @MainActor in }` (or the existing `noteStatus` / snapshot `Task`). Counters use capture-before-`Task` where required.  
- **dedup path in** `handleGlucose`:** EGV mirrors not updated on early return (correct).  
- **bleWasRestored:** 187: mirrored in `willRestoreState` and (pre-188) in `didUpdateState`.

### Pass 2 — UI / Observation (187)

- **ComplicationDebugView** + **`G7DirectBleDebugSection`**: `WatchState` read from dedicated `body` for observation. **188** superseded 5s-only refresh; see 188 narrative.

### Pass 3 — Lifecycle (187)

- **connect options `nil`:** Preserves in-app behavior expectations. **187:** dual `registerForConnectionEvents` (poweredOn + scan) — **188** removed scan path.

**Verdict (187):** Clean for **Build 187** as shipped; **Build 188** tracked separately. Residual: local **`ci/local-build.sh`**; device / BetterStack per plan.

---

## Changelog

### v1.2 (2026-04-27 11:52 CEST)

- **Build 188** narrative section; links plan **v1.10** implementation table and short SHAs.  
- Summary and deviations updated (188 shipped; scan-path removal no longer “deferred”).  
- Red-team section retitled for **Build 187**; pointer to 188 review in plan.  
- Title: **G7 direct BLE — implementation log (Build 187 & 188).**

### v1.1 (2026-04-26 20:55 CET)

- Post-review hardening: `bleWasRestored` in `willRestoreState`, `.task` + `Task.sleep` polling, `G7DirectBleDebugSection`, EGV grammar, `WatchState` class vs extension note.

### v1.0 (2026-04-26 12:11 CET)

- Initial build 187 implementation log, per-task list, red-team self-review, deviations, and verification note.

---
