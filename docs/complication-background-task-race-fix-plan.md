# Complication Background Task Race Fix (Plan)

**Overview:** Fix complication staleness caused by completing WKWatchConnectivityRefreshBackgroundTask before userInfo processing finishes, and add diagnostic logging. Fix A is required regardless of Fix B; Fix B is observability only. v3: no double-merge, cancel finalizeWorkItem on quiet-window path, WKWatchConnectivityRefreshBackgroundTask unconditional.

---

## Summary

Build 113 improved phone coalescing and watch-side dedup, but the complication still showed stale data (e.g. "135 +14 10M") even after opening the watch app. Local `watch_log.txt` analysis showed **TrioComplicationDataStore logs stop after ~54 minutes** while WatchState logs continue for 8+ hours. Red-team review identified the root cause: **WKWatchConnectivityRefreshBackgroundTask is completed immediately** in `handleBackgroundTasks`, so the OS suspends the extension before the 0.1–0.2s debounced `finalizePendingData` → `saveComplicationSnapshot` → `saveOnMain` ever runs.

This plan implements **Fix B** (diagnostic logging) and **Fix A** (hold connectivity task open + quiet-window completion). **Fix A is required regardless of Fix B diagnostic output.** Fix B is observability only and must not gate Fix A implementation.

---

## Root Cause (Red-Team Validated)

**Race:**

1. System wakes extension to deliver `transferUserInfo` and issues a `WKWatchConnectivityRefreshBackgroundTask`.
2. `ExtensionDelegate.handle(_:backgroundTasks:)` calls `WatchState.shared.handleBackgroundTasks(backgroundTasks)`.
3. In `handleBackgroundTasks`, the task is **not** a `WKApplicationRefreshBackgroundTask`, so it falls into the `else` branch and **`task.setTaskCompletedWithSnapshot(false)` is called immediately** (WatchState.swift ~723).
4. Concurrently or just after, `session(_:didReceiveUserInfo:)` runs on WCSession's queue and dispatches `DispatchQueue.main.async { scheduleUIUpdate(with: payload) }`.
5. `scheduleUIUpdate` merges data and schedules `finalizePendingData()` via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 or 0.2, execute: workItem)`.
6. OS sees the background task completed and **suspends the extension** before the debounce delay fires.
7. `finalizePendingData` → `saveComplicationSnapshot` → `saveOnMain` **never execute**. No disk write, no ComplicationLogBuffer writes → zero TrioComplicationDataStore log output.

**Evidence:** TrioComplicationDataStore log lines (Snapshot saved, Dedup, Reload TRIGGERED) appear only from 23:13 to 00:07 in watch_log.txt; thereafter only WatchState/WatchLogger lines appear at each wake.

---

## Scope

- **Files:** All changes remain within patch 09 scope: `ExtensionDelegate.swift`, `WatchState.swift`, `TrioComplicationDataStore.swift`. Optionally a small addition in Watch Shared for Fix B (see below).
- **No changes** to AppleWatchManager (Fix E deferred), TrioWatchComplication (Fix C deferred), or phone-side relay (Fix D deferred).

---

## Fix B: Redundant WatchLogger Path in saveOnMain (Do First)

**Goal:** Break the single-point-of-failure where ComplicationLogBuffer is the only log sink for TrioComplicationDataStore. When the buffer fails (e.g. App Group write/drain issue), we get no visibility. WatchLogger uses a different path (in-memory buffer → flushToPhone) and continues to appear in watch_log.txt throughout the 8-hour gap.

**Constraint:** `TrioComplicationDataStore` lives in **Trio Watch Shared**. It must not depend on the Watch App Extension (shared code is used by both the app extension and the complication extension). So we cannot `import` WatchLogger from TrioComplicationDataStore.

**Approach:** Add an optional **log forwarding closure** to TrioComplicationDataStore, set by the Watch App Extension at launch. When `log(_ message: String)` is called, we keep the existing `ComplicationLogBuffer.append(message)` and also invoke the closure if non-nil. The closure will be set to `{ msg in Task { await WatchLogger.shared.log(msg) } }` so logs are forwarded to WatchLogger without adding a module dependency.

**Thread-safety (Critical):** `log()` is called from `latestSnapshot()`, which is documented as "May be called from any thread" (e.g. the complication extension's `loadLatestEntry()` runs on WidgetKit's queue). **Fix:** Protect `logForwarder` with a lock (e.g. `logForwarderLock`). In `log()`, lock, read the closure into a local, unlock, then call the local if non-nil (so the closure runs outside the lock and cannot deadlock with WatchLogger).

**Complication extension behavior:** The log forwarder is never set in the complication extension process (that process has no WatchLogger). At the setter site (ExtensionDelegate or WatchState), add a one-line comment: "Only set in Watch App Extension; complication extension has no WatchLogger so forwarder stays nil there."

**Implementation steps:**

1. **TrioComplicationDataStore.swift (Trio Watch Shared)**  
   Add `logForwarderLock` and guarded forwarder. In `log()`, after `ComplicationLogBuffer.append(message)`, perform the locked read and optional forwarder call.

2. **ExtensionDelegate.swift (Watch App Extension)**  
   Early in lifecycle, set the forwarder: `TrioComplicationDataStore.setLogForwarder { msg in Task { await WatchLogger.shared.log(msg) } }`.

3. **Checkpoint logs inside `saveOnMain`** (via existing `log()`):
   - **Entry:** At the very start of `saveOnMain`: `log("saveOnMain entered: glucose=..., readingDate=...")`.
   - **After dedup:** Optionally `log("saveOnMain: passed dedup, writing snapshot")` before the write block.
   - Existing logs for success/failure remain.

**Acceptance:** After deploy, watch_log.txt shows "saveOnMain entered" (and optionally "passed dedup") from TrioComplicationDataStore during background userInfo delivery.

---

## Fix A: Hold Connectivity Task Open Until Processing Completes (Quiet-Window Completion)

**Goal:** Ensure the extension is not suspended until all queued userInfo payloads for this wake have been processed. Use **quiet-window completion**: track `lastUserInfoReceivedAt`; complete tasks only after no new userInfo for ≥300ms, then run one final `finalizePendingData()` and complete all pending connectivity tasks.

**Thread-safety (Critical):** `session(_:didReceiveUserInfo:)` runs on WCSession's queue (not main). **Always dispatch to main first.** Inside the main closure, check `pendingConnectivityTasks.isEmpty` and branch; do not read main-thread state from the session queue.

**Implementation steps:**

1. **WatchState.swift**  
   Add `pendingConnectivityTasks: [WKRefreshBackgroundTask]`, `lastUserInfoReceivedAt: Date?`, and `quietWindowWorkItem: DispatchWorkItem?`. All access from main queue only.

2. **handleBackgroundTasks**  
   - If `task is WKApplicationRefreshBackgroundTask`, keep existing behavior.  
   - **Else** if `task is WKWatchConnectivityRefreshBackgroundTask`, **do not complete**. Append to `pendingConnectivityTasks` and schedule 5s safety timeout for that task.  
   - Else, complete immediately.

3. **Completion:** Only after 300ms quiet window (no new userInfo) and one final `finalizePendingData()`, or via 5s safety timeout. Do not complete in `finalizePendingData()`.

4. **didReceiveUserInfo (no double-merge):**  
   Always `DispatchQueue.main.async { [self] in ... }`. Inside the main closure:  
   - **Empty path** (`pendingConnectivityTasks.isEmpty`): Call `scheduleUIUpdate(with: payload)` only (it does merge + date guard).  
   - **Non-empty path:** Merge `payload` into `pendingData`, set `lastUserInfoReceivedAt`, cancel `quietWindowWorkItem` and **cancel `finalizeWorkItem`**, schedule 300ms quiet-window; when it fires, run one `finalizePendingData()`, then complete all tasks and clear.

5. **Safety timeout:** When adding a task, schedule `DispatchQueue.main.asyncAfter(deadline: .now() + 5.0)` to complete that task if still in `pendingConnectivityTasks`. Document: if task arrives after debounce has fired, 5s timeout rescues.

6. **Multiple tasks:** Multiple tasks in one wake are all stored; multiple `didReceiveUserInfo` reset the 300ms window; last timer runs, then one finalize and complete all.

**Acceptance:**  
- watch_log.txt shows "saveOnMain entered" (and "Snapshot saved" when data is new) for wake cycles that deliver userInfo.  
- Complication updates after background delivery.  
- No crash or hang; connectivity tasks always completed (quiet-window or 5s timeout).

---

## Fix A / Fix B Ordering

1. Implement **Fix B** (log forwarder + saveOnMain entry log) and **Fix A** (quiet-window completion, thread-safe didReceiveUserInfo).  
2. Regenerate patch 09, run patch-test.sh, build-only.  
3. Deploy and verify: watch_log.txt shows "saveOnMain entered" for background wakes; complication updates after background delivery.

---

## Validation

- Regenerate patch 09 using the mid-stack patch update workflow (Trio-dev: tmp/complication-fix-baseline with patches 01–08, tmp/complication-fix with cherry-picked changes, `generate-patch.sh`).  
- Run `scripts/patch-test.sh`.  
- Run `ci/local-build.sh --base-branch dev --build-only`.

---

## Deferred (Not in This Plan)

- **Fix C:** Complication extension logging in `getTimeline`.  
- **Fix D:** Phone-side freshness via WatchConnectivity relay (lastComplicationReload / lastSnapshotReadingDate in message payload).  
- **Fix E:** Coalescing investigation (activation/reachability paths bypassing scheduleWatchStateUpdate).

---

## Changelog

- **v3:** No double-merge; cancel finalizeWorkItem on quiet-window path; WKWatchConnectivityRefreshBackgroundTask unconditional (watchOS 3.0).
- **v2:** Quiet-window completion; Fix A mandatory; thread-safety; logForwarder lock; ordering gap and multiple-tasks documented.
- **v1:** Initial plan: Fix B (WatchLogger path + saveOnMain entry log), Fix A (hold task, skip debounce when connectivity task, safety timeout).
