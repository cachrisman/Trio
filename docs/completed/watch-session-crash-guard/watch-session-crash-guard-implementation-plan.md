# Implementation Plan: WatchConnectivity Session Crash Guard

Version: 1.6
Date: 2026-03-15
Status: Shipped (build 143)
Last updated: 2026-03-21 10:54 CET
Design reference: `01-watch-session-crash-guard-design.md`

## Scope

Harden `BaseWatchManager` delegate callbacks and `TrioApp.loadServices()` against crash loops caused by rapid WCSession state transitions (e.g., watch reboot with locked PIN).

## Out of scope

- Watch-side changes (watchOS app)
- Changes to any existing publisher-driven state-update coalescer (out of scope; we add a delegate-only coalescer)
- WCSession message/file-transfer reliability improvements
- CoreData initialization ordering changes

## Dependencies

- Feature branch: `feature/watch-session-crash-guard` (off `feature/watch-complication-improvements` or `dev`)
- Patch: new patch appended to stack

**Branch sensitivity (publisher-driven updates):** The exact publisher-driven update path in `AppleWatchManager.swift` differs by base branch. If your chosen baseline already has a publisher coalescer (e.g. `scheduleWatchStateUpdate`, `pendingSendWorkItem`, `coalescerFirstScheduledAt`): preserve it and add the new delegate coalescer as a separate lane so the two do not interfere. If no publisher coalescer exists on the baseline: add only the delegate coalescer described in this plan. The tasks below are written to work in both cases; where steps refer to “if the file has a publisher-driven coalescer”, follow that branch accordingly.

## Sequencing + ship boundaries

### Phase list
- Phase A: Delegate callback hardening — shippable? **yes** (eliminates the crash loop; no behavioral regressions)
- Phase B: `loadServices()` defensive resolution — shippable? **yes** (independent defense-in-depth; can ship with or without Phase A)

## Shared conventions

- Logging: use the app’s existing `.watchManager` (or equivalent) category for delegate-coalescer and watch-session logs so they are queryable in Better Stack.
- When observability standards exist under `docs/process/`, this plan will conform; no plan-specific deviations.

---

## Phase A: Delegate Callback Hardening

**Ship gate:** safe to ship alone? **Yes** — directly prevents the observed crash loop. Blast radius limited to WatchConnectivity session lifecycle handling; normal publisher-driven updates are untouched.

**Rollback:** Revert the patch. No persistent state changes.

### Task A1 — Add delegate debounce mechanism

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` (class `BaseWatchManager`)
- **Change:** Add a new `pendingDelegateWorkItem: DispatchWorkItem?` property. This provides a dedicated debounce lane for delegate-triggered state pushes. If the same file already has a publisher-driven coalescer (e.g. `pendingSendWorkItem`), keep it separate so the two lanes do not interfere.
- **Steps (ordered):**
  1. Add property near other private state (e.g. near the `queue` / `coreDataPublisher` declarations around lines 37–39):
     ```swift
     private var pendingDelegateWorkItem: DispatchWorkItem?
     ```
  2. Add a private method `scheduleDelegateTriggeredUpdate(source:)` that:
     - Cancels `pendingDelegateWorkItem`
     - Creates a new `DispatchWorkItem` with a 0.5s delay
     - The work item calls `setupWatchState()` + `sendDataToWatch()` (same as current inline Task)
     - Logs the debounce (coalesce count, source) using the app’s watch-manager log category (e.g. `.watchManager`)
  3. Implementation sketch:
     ```swift
     private var delegateCoalesceCount = 0

     private func scheduleDelegateTriggeredUpdate(source: String) {
         DispatchQueue.main.async { [weak self] in
             guard let self else { return }
             self.pendingDelegateWorkItem?.cancel()
             self.delegateCoalesceCount += 1

             let count = self.delegateCoalesceCount
             let workItem = DispatchWorkItem { [weak self] in
                 guard let self else { return }
                 debug(.watchManager, "📡 delegate_coalescer_fired source=\(source) coalesced=\(count)")
                 self.delegateCoalesceCount = 0
                 Task {
                     let state = await self.setupWatchState()
                     await self.sendDataToWatch(state)
                 }
             }
             self.pendingDelegateWorkItem = workItem
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
         }
     }
     ```
- **Acceptance (verifiable):**
  - During a rapid delegate callback storm (simulated by toggling Airplane Mode), only 1-2 `delegate_coalescer_fired` log entries appear instead of N.
  - No crash loop when watch is rebooted and left locked.
- **Observability checks:**
  - `delegate_coalescer_fired source=... coalesced=N` log line shows how many callbacks were coalesced.
- **Notes / pitfalls:**
  - The 0.5s delay is short enough to be imperceptible but long enough to absorb rapid delegate storms. If a publisher coalescer exists elsewhere, delegate-triggered pushes remain on a separate lane.
  - Keep `pendingDelegateWorkItem` separate from any existing publisher-coalescer work item so the two lanes don't interfere.

### Task A2 — Guard `activationDidCompleteWith` on `.activated` state

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** Add an early return in `session(_:activationDidCompleteWith:error:)` when `activationState != .activated`.
- **Steps (ordered):**
  1. After the existing error check (if error, log and return), add:
     ```swift
     guard activationState == .activated else {
         debug(.watchManager, "📱 Ignoring activation callback — state is \(activationState.rawValue), not .activated")
         return
     }
     ```
  2. Replace the inline `Task { setupWatchState(); sendDataToWatch() }` in that method with a call to `scheduleDelegateTriggeredUpdate(source: "activationCompleted")`.
  3. Keep any existing gate-clearing or startup-drain logic in that method above the debounce call — those are cheap and idempotent.
- **Acceptance (verifiable):**
  - When `activationDidCompleteWith` fires with `.inactive` or `.notActivated`, the log shows the "Ignoring" message and no `setupWatchState` call is triggered.
  - When it fires with `.activated`, the debounced update fires normally.
- **Observability checks:**
  - New log line: `"Ignoring activation callback — state is X, not .activated"`
- **Notes / pitfalls:**
  - `sessionDidDeactivate` calls `session.activate()`, which triggers `activationDidCompleteWith` again; the guard prevents that from launching work until the session is truly `.activated`.

### Task A3 — Route `sessionReachabilityDidChange` through debounce

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** In `sessionReachabilityDidChange(_:)`, replace the inline `Task { setupWatchState(); sendDataToWatch() }` in the `session.isReachable` branch with a call to `scheduleDelegateTriggeredUpdate`.
- **Steps (ordered):**
  1. In the `if session.isReachable` branch:
     - If the file has a publisher-driven coalescer (e.g. `pendingSendWorkItem`, `coalescerFirstScheduledAt`), cancel the pending work item and reset the coalescer state so the delegate-triggered update takes priority.
     - Replace the `Task { ... }` that calls `setupWatchState()` and `sendDataToWatch()` with:
       ```swift
       scheduleDelegateTriggeredUpdate(source: "reachabilityChanged")
       ```
     - Keep any existing `sendPendingAcksIfReachable()` (or equivalent) — ACK sending is lightweight and should not be debounced.
  2. In the `else` branch: **remove** the `retryConnection()` call (and its `DispatchQueue.main.asyncAfter` wrapper) entirely (see Task A4).
- **Acceptance (verifiable):**
  - Rapid reachability toggles produce at most 1-2 `delegate_coalescer_fired` entries in logs.
  - Watch bolus ACKs still send promptly when the watch becomes reachable.
- **Observability checks:**
  - `delegate_coalescer_fired source=reachabilityChanged coalesced=N`
- **Notes / pitfalls:**
  - If a publisher coalescer exists, canceling its pending work when the watch becomes reachable ensures the delegate-triggered update (which will run after the debounce) takes priority and captures the latest state.

### Task A4 — Remove `retryConnection()` feedback loop

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** Remove the `retryConnection()` method and all call sites.
- **Steps (ordered):** Remove call sites first so the project still compiles; then delete the method.
  1. In `sessionReachabilityDidChange`’s `else` branch, remove the `DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.retryConnection() }` block. Replace with a single debug log:
     ```swift
     debug(.watchManager, "📱 Watch became unreachable — waiting for system reconnection")
     ```
  2. Search for any other call sites of `retryConnection()` and remove them.
  3. Delete the `retryConnection()` method (implementation calls `session.activate()` after a guard).
- **Acceptance (verifiable):**
  - During watch disconnection, no `"Attempting to reactivate session"` log lines appear.
  - Session still reconnects when watch is unlocked (system-driven).
- **Observability checks:**
  - New log line: `"Watch became unreachable — waiting for system reconnection"`
  - Absence of `"Attempting to reactivate session"` confirms no feedback loop.
- **Notes / pitfalls:**
  - iOS WCSession manages reconnection internally. The manual `session.activate()` retry was redundant and actively harmful during unstable states. There is no functional regression from removing it.

---

## Phase B: `loadServices()` Defensive Resolution

**Ship gate:** safe to ship alone? **Yes** — independent hardening, no interaction with Phase A. Blast radius: only affects app startup error handling.

**Rollback:** Revert the patch.

### Task B1 — Replace force-unwraps with guard-let + logging

- **Files:** `Trio/Sources/Application/TrioApp.swift`
- **Change:** Replace every `resolver.resolve(...)!` in `loadServices()` (roughly lines 68–87, including the conditional at 85) with a guard-let that logs a warning-level message on failure but does not crash.
- **Steps (ordered):**
  1. Create a private helper (e.g. on the same type as `loadServices()` so `resolver` is in scope) that logs at warning level (the app’s global `error()` is fatal; use `warning` for graceful degradation):
     ```swift
     private func resolveOrLog<T>(_ type: T.Type) -> T? {
         guard let service = resolver.resolve(type) else {
             warning(.default, "Failed to resolve service: \(type) — skipping")
             return nil
         }
         return service
     }
     ```
  2. Replace each `resolver.resolve(X.self)!` with the appropriate pattern:
     - For `AppearanceManager`: `resolveOrLog(AppearanceManager.self)?.setupGlobalAppearance()`
     - For all `_ = resolver.resolve(X.self)!` lines: `_ = resolveOrLog(X.self)`
  3. Remove duplicate resolutions: `WatchManager` appears at lines 75 and 78 (keep one); `ContactImageManager` at 76 and 80 (keep one).
- **Acceptance (verifiable):**
  - Temporarily commenting out a service registration in the Swinject assembler produces a warning log instead of a crash.
  - All services still resolve correctly in normal operation (verify via debug log or breakpoint).
- **Observability checks:**
  - Warning-level log: `"Failed to resolve service: X — skipping"` visible in Better Stack.
- **Notes / pitfalls:**
  - This is intentionally permissive — in normal operation, all services resolve. The guard-let is strictly for abnormal lifecycle scenarios (rapid background relaunch, incomplete initialization).
  - The duplicate `WatchManager` and `ContactImageManager` resolutions are likely copy-paste errors in the existing code. Removing duplicates reduces startup cost slightly.

---

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Debounce delay causes stale watch state on first activation | Low | Low | 0.5s delay is well under human perception; `setupWatchState()` always fetches current data at call time. |
| Removing `retryConnection()` delays reconnection in rare edge cases | Low | Low | iOS manages WCSession reconnection internally. Monitor via logs for 1 week post-deploy. |
| Guard-let in `loadServices()` masks a real configuration regression | Low | Medium | Logs at `.warning` level — visible in Better Stack monitoring. Add alert rule if desired. |
| Delegate debounce conflicts with publisher coalescer | Very low | Low | Separate `DispatchWorkItem` properties; no shared state between the two debounce lanes. |

## Hypotheses / expectations (NOT acceptance)

- The 0.5s delegate debounce will coalesce 10-50 rapid callbacks into 1-2 state pushes during a watch reboot scenario.
- CPU usage during watch state transitions will drop significantly (fewer concurrent Core Data fetches).
- The app will remain alive and responsive during the "watch rebooted but locked" window.
- Battery impact of the removed retry loop is negligible (it was only active during disconnection periods), but overall system-level churn is reduced.

## Changelog

### v1.6 (2026-03-21 10:54 CET)
- Status updated from Draft to Shipped (build 143). Added Last updated field. Fixed design reference path.
- Reason: all tasks (A1-A4, B1) implemented and shipped in patch 10 (`10-watch-session-crash-guard.patch`), deployed via build 143. Production telemetry confirms all instrumented code paths active. See `03-watch-session-crash-guard-implementation-log.md` for full validation.

### v1.5 (2026-03-15)
- Branch sensitivity: added explicit note under Dependencies on publisher-driven path differing by base branch; preserve existing coalescer and add delegate coalescer separate, or add only delegate coalescer if none exists.

### v1.4 (2026-03-15)
- A4: steps reordered — remove call sites first, then delete method (avoids compile errors); added ordering note.

### v1.3 (2026-03-15)
- B1: resolveOrLog placement clarified — private helper on same type so resolver is in scope.

### v1.2 (2026-03-15)
- Line-number agnostic: replaced fixed line refs with method names and approximate ranges so the plan stays valid across branch drift.
- A1: delegate coalescer is standalone; conditional note if publisher coalescer exists. Shared conventions: use existing watch-manager log category; observability standards reference qualified.
- A3: made publisher-coalescer cancel/reset conditional on that coalescer existing in the file.
- A4: described removal by behavior (method + else-branch block), not line numbers.
- B1: loadServices range 68–87 (and conditional 85); duplicate-resolution wording fixed (75/78 WatchManager, 76/80 ContactImageManager).

### v1.1 (2026-03-15)
- B1: clarified that `resolveOrLog` must use warning-level logging (app’s global `error()` is fatal); aligned acceptance and observability to warning level; risks table updated to .warning.
- A4: step 1 wording — delete the method (not only the body).

### v1.0 (2026-03-13)
- Initial implementation plan derived from crash log analysis of ~40-50 `EXC_BREAKPOINT` crashes during Apple Watch reboot with locked PIN state.
