# Implementation Plan: WatchConnectivity Session Crash Guard

Version: 1.0
Date: 2026-03-13
Status: Draft
Design reference: `docs/in-progress/watch-session-crash-guard/01-design.md`

## Scope

Harden `BaseWatchManager` delegate callbacks and `TrioApp.loadServices()` against crash loops caused by rapid WCSession state transitions (e.g., watch reboot with locked PIN).

## Out of scope

- Watch-side changes (watchOS app)
- Changes to the `scheduleWatchStateUpdate` coalescer (already well-designed)
- WCSession message/file-transfer reliability improvements
- CoreData initialization ordering changes

## Dependencies

- Feature branch: `feature/watch-session-crash-guard` (off `feature/watch-complication-improvements` or `dev`)
- Patch: new patch appended to stack

## Sequencing + ship boundaries

### Phase list
- Phase A: Delegate callback hardening — shippable? **yes** (eliminates the crash loop; no behavioral regressions)
- Phase B: `loadServices()` defensive resolution — shippable? **yes** (independent defense-in-depth; can ship with or without Phase A)

## Shared conventions

- This plan conforms to: `docs/process/standards-observability.md`
- Any plan-specific deviations: none

---

## Phase A: Delegate Callback Hardening

**Ship gate:** safe to ship alone? **Yes** — directly prevents the observed crash loop. Blast radius limited to WatchConnectivity session lifecycle handling; normal publisher-driven updates are untouched.

**Rollback:** Revert the patch. No persistent state changes.

### Task A1 — Add delegate debounce mechanism

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** Add a new `pendingDelegateWorkItem: DispatchWorkItem?` property alongside the existing `pendingSendWorkItem`. This provides a separate debounce lane for delegate-triggered state pushes, avoiding interference with the publisher-driven coalescer.
- **Steps (ordered):**
  1. Add property at line ~46 (near existing `pendingSendWorkItem`):
     ```swift
     private var pendingDelegateWorkItem: DispatchWorkItem?
     ```
  2. Add a private method `scheduleDelegateTriggeredUpdate(source:)` that:
     - Cancels `pendingDelegateWorkItem`
     - Creates a new `DispatchWorkItem` with a 0.5s delay
     - The work item calls `setupWatchState()` + `sendDataToWatch()` (same as current inline Task)
     - Logs the debounce (coalesce count, source) at `.watchManager` level
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
  - The 0.5s delay is short enough to be imperceptible but long enough to absorb rapid delegate storms. The publisher coalescer uses 2s trailing / 5s cap, so delegate-triggered pushes will still be faster for legitimate state changes.
  - `pendingDelegateWorkItem` is separate from `pendingSendWorkItem` so these two debounce lanes don't interfere.

### Task A2 — Guard `activationDidCompleteWith` on `.activated` state

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** Add an early return in `session(_:activationDidCompleteWith:error:)` (line 849) when `activationState != .activated`.
- **Steps (ordered):**
  1. After the existing error check (line 850-853), add:
     ```swift
     guard activationState == .activated else {
         debug(.watchManager, "📱 Ignoring activation callback — state is \(activationState.rawValue), not .activated")
         return
     }
     ```
  2. Replace the inline `Task { ... }` block (lines 871-874) with a call to `scheduleDelegateTriggeredUpdate(source: "activationCompleted")`.
  3. Keep the gate-clearing and startup-drain logic (lines 858-865) above the debounce call — those are cheap and idempotent.
- **Acceptance (verifiable):**
  - When `activationDidCompleteWith` fires with `.inactive` or `.notActivated`, the log shows the "Ignoring" message and no `setupWatchState` call is triggered.
  - When it fires with `.activated`, the debounced update fires normally.
- **Observability checks:**
  - New log line: `"Ignoring activation callback — state is X, not .activated"`
- **Notes / pitfalls:**
  - `sessionDidDeactivate` (line 1278-1280) already calls `session.activate()` which will trigger another `activationDidCompleteWith` — the guard prevents that from launching work until the session is truly active.

### Task A3 — Route `sessionReachabilityDidChange` through debounce

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** In `sessionReachabilityDidChange(_:)` (line 1283), replace the inline `Task { ... }` block with a call to `scheduleDelegateTriggeredUpdate`.
- **Steps (ordered):**
  1. In the `if session.isReachable` branch (lines 1286-1297):
     - Keep the `pendingSendWorkItem?.cancel()` and `coalescerFirstScheduledAt = nil` reset (lines 1287-1290) — this correctly clears any pending publisher-driven update since the delegate will supersede it.
     - Replace lines 1291-1294 (`Task { ... }`) with:
       ```swift
       scheduleDelegateTriggeredUpdate(source: "reachabilityChanged")
       ```
     - Keep `sendPendingAcksIfReachable()` (line 1297) — ACK sending is lightweight and should not be debounced.
  2. In the `else` branch (lines 1298-1303): **remove** the `retryConnection()` call entirely (see Task A4).
- **Acceptance (verifiable):**
  - Rapid reachability toggles produce at most 1-2 `delegate_coalescer_fired` entries in logs.
  - Watch bolus ACKs still send promptly when the watch becomes reachable.
- **Observability checks:**
  - `delegate_coalescer_fired source=reachabilityChanged coalesced=N`
- **Notes / pitfalls:**
  - The `pendingSendWorkItem?.cancel()` in the reachable branch is still needed. If a publisher-driven update was pending and the watch just became reachable, we want the delegate-triggered update to take priority (it will capture the latest state).

### Task A4 — Remove `retryConnection()` feedback loop

- **Files:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- **Change:** Remove the `retryConnection()` method (lines 206-213) and all call sites.
- **Steps (ordered):**
  1. Delete the `retryConnection()` method body (lines 205-213).
  2. Remove the call in `sessionReachabilityDidChange` `else` branch (lines 1299-1302). Replace with a debug log:
     ```swift
     debug(.watchManager, "📱 Watch became unreachable — waiting for system reconnection")
     ```
  3. Search for any other call sites of `retryConnection()` and remove them.
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
- **Change:** Replace every `resolver.resolve(...)!` in `loadServices()` (lines 67-89) with a guard-let that logs a `.error`-level message on failure but does not crash.
- **Steps (ordered):**
  1. Create a helper function above or inside `loadServices()`:
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
  3. Also fix the duplicate resolutions on lines 75+78 (`WatchManager`) and 76+80 (`ContactImageManager`) — remove the duplicates.
- **Acceptance (verifiable):**
  - Temporarily commenting out a service registration in the Swinject assembler produces a warning log instead of a crash.
  - All services still resolve correctly in normal operation (verify via debug log or breakpoint).
- **Observability checks:**
  - `.error`-level log: `"Failed to resolve service: X — skipping"` visible in Better Stack.
- **Notes / pitfalls:**
  - This is intentionally permissive — in normal operation, all services resolve. The guard-let is strictly for abnormal lifecycle scenarios (rapid background relaunch, incomplete initialization).
  - The duplicate `WatchManager` and `ContactImageManager` resolutions are likely copy-paste errors in the existing code. Removing duplicates reduces startup cost slightly.

---

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Debounce delay causes stale watch state on first activation | Low | Low | 0.5s delay is well under human perception; `setupWatchState()` always fetches current data at call time. |
| Removing `retryConnection()` delays reconnection in rare edge cases | Low | Low | iOS manages WCSession reconnection internally. Monitor via logs for 1 week post-deploy. |
| Guard-let in `loadServices()` masks a real configuration regression | Low | Medium | Logs at `.error` level — visible in Better Stack monitoring. Add alert rule if desired. |
| Delegate debounce conflicts with publisher coalescer | Very low | Low | Separate `DispatchWorkItem` properties; no shared state between the two debounce lanes. |

## Hypotheses / expectations (NOT acceptance)

- The 0.5s delegate debounce will coalesce 10-50 rapid callbacks into 1-2 state pushes during a watch reboot scenario.
- CPU usage during watch state transitions will drop significantly (fewer concurrent Core Data fetches).
- The app will remain alive and responsive during the "watch rebooted but locked" window.
- Battery impact of the removed retry loop is negligible (it was only active during disconnection periods), but overall system-level churn is reduced.

## Changelog (v1.0)

### v1.0 (2026-03-13)
- Initial implementation plan derived from crash log analysis of ~40-50 `EXC_BREAKPOINT` crashes during Apple Watch reboot with locked PIN state.
