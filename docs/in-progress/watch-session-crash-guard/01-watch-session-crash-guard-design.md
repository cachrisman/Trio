# Design: WatchConnectivity Session Crash Guard

Version: 1.5
Date: 2026-03-15
Status: Proposed

## Problem

When the Apple Watch reboots and remains locked (PIN not entered), the WCSession on the iPhone side undergoes rapid, unstable state transitions. Each transition fires `WCSessionDelegate` callbacks (`activationDidCompleteWith`, `sessionReachabilityDidChange`) which unconditionally spawn new async Tasks to build and send `WatchState`. This causes:

1. **Crash loop**: ~40–50 `EXC_BREAKPOINT` (SIGTRAP) crashes in rapid succession, each triggered by a WCSession background relaunch of the app.
2. **Unbounded concurrency**: Each delegate callback fires a new `Task { setupWatchState(); sendDataToWatch() }` with no cancellation of prior in-flight work.
3. **Feedback loop**: `sessionReachabilityDidChange` schedules a `retryConnection()` after 2 seconds which calls `session.activate()`, triggering another `activationDidCompleteWith` callback, amplifying the storm.

The crashes stopped immediately once the watch was unlocked and the session stabilized.

## Context / Current State

### `BaseWatchManager` delegate callback pattern (current)

Both `session(_:activationDidCompleteWith:error:)` and `sessionReachabilityDidChange(_:)` follow an identical pattern:

```swift
Task {
    let state = await self.setupWatchState()
    await self.sendDataToWatch(state)
}
```

There is **no**:
- Debouncing or coalescing of delegate-triggered state pushes
- Cancellation of prior Tasks when a new callback arrives
- Rate limiting or cooldown between delegate-triggered pushes
- Guard on `activationState` before launching work in `activationDidCompleteWith`
- Circuit breaker for repeated failures or rapid-fire invocations

Publisher-driven update handling varies by branch: on some baselines it is direct `Task { setupWatchState(); sendDataToWatch() }` in each sink; on others (e.g. branches with complication improvements) a 2s-trailing/5s-cap coalescer already exists. This design is intentionally scoped to delegate-triggered storm hardening and remains compatible with any existing publisher coalescer; delegate callbacks currently bypass any such coalescer and spawn their own Tasks.

### `retryConnection()` amplification

When `sessionReachabilityDidChange` fires with `isReachable == false`, the method schedules:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
    self?.retryConnection()
}
```

`retryConnection()` calls `session.activate()`, which triggers `activationDidCompleteWith`, which fires another Task. During an unstable watch state, this creates a self-reinforcing loop with a 2-second period.

### `loadServices()` force-unwraps

Every `resolver.resolve(...)!` call in `loadServices()` is a force-unwrap that produces `EXC_BREAKPOINT` on failure. While not the root cause of this specific incident, it is a latent crash vector during abnormal app lifecycle scenarios (e.g., rapid background relaunch by WCSession where the Swinject container might be in an unexpected state).

## Constraints / Requirements

- **Safety-critical context**: Trio is a diabetes management app. Crash loops prevent the user from monitoring their glucose. Any fix must prioritize app stability above watch communication fidelity.
- **No upstream changes**: This is a fork; changes must stay within the patch system.
- **Backward compatible**: The fix must not break normal watch communication flows (foreground use, background complication updates, bolus/carb requests from watch).
- **Minimal diff**: Keep changes surgical and contained to `BaseWatchManager` and `TrioApp`.

## Decision

### Recommended approach

Four targeted changes, ordered by impact:

#### Change 1: Coalesce delegate callbacks via a new delegate coalescer

Route `activationDidCompleteWith` and `sessionReachabilityDidChange` through a new lightweight debounce mechanism for delegate-initiated triggers (cancel-and-replace with a short delay). This replaces the current pattern of spawning a new `Task` for every single callback.

**Key design**: Use a single `pendingDelegateWorkItem: DispatchWorkItem?` that is cancelled-and-replaced on each delegate callback, with a short delay (e.g., 0.5s). This collapses N rapid callbacks into 1 state push.

#### Change 2: Guard `activationDidCompleteWith` on `.activated` state

Add an early return when `activationState != .activated`. The current code checks for `error` but proceeds to launch expensive work even when the activation state is `.inactive` or `.notActivated`.

#### Change 3: Remove the `retryConnection()` feedback loop

Remove the proactive `session.activate()` retry from `sessionReachabilityDidChange`. iOS delivers delegate callbacks when the session state genuinely changes; manually re-activating during instability only amplifies the problem. No replacement retry is added in this change. If retry were ever reintroduced later, it would need to be gated behind exponential backoff and a max-retry cap.

#### Change 4: Replace force-unwraps in `loadServices()` with defensive guards

Replace `resolver.resolve(...)!` calls with `guard let` statements and appropriate logging for graceful degradation. When applying this pattern, remove any duplicate resolution calls in `loadServices()` if present.

### Why this tradeoff

- **Change 1** directly addresses the root cause (unbounded concurrency from delegate storms) using a familiar cancel-and-replace debounce pattern.
- **Change 2** is a one-line guard that prevents wasted work in a common edge case.
- **Change 3** eliminates a self-reinforcing failure mode that made the crash loop worse.
- **Change 4** is a defense-in-depth hardening that prevents a class of `EXC_BREAKPOINT` crashes across all abnormal lifecycle scenarios, not just this one.

## Functional behavior

### Triggers and flows

- **Normal watch communication (no change)**: Publisher-driven updates continue as before (unchanged; implementation may be direct Tasks or an existing coalescer depending on branch).
- **Delegate callbacks (changed)**: Instead of immediately spawning a Task, delegate callbacks schedule a debounced work item. Multiple rapid callbacks collapse into one.
- **Watch reboot / locked state (changed)**: The delegate storm is absorbed by the debounce. The retry-loop amplification is eliminated. The app stays alive and responsive.

### Edge cases

- **Watch unlocked after delay**: The debounced delegate handler fires once the callbacks settle, sending the current state. Normal communication resumes.
- **Watch genuinely disconnected (not rebooting)**: `sessionReachabilityDidChange(isReachable: false)` fires once. Without the retry loop, the app simply waits for the next system callback. No behavioral regression — the retry was not guaranteed to help anyway.
- **Service resolution failure during background relaunch**: With Change 4, the app logs the failure and skips that service instead of crashing. This is strictly better than the current behavior.

### Non-functional

- **Performance**: Reduces CPU/memory usage during watch state transitions (fewer concurrent Tasks, fewer Core Data fetches).
- **Reliability**: Designed to eliminate the observed crash-loop mechanism while keeping normal watch communication intact.
- **Observability**: Each change adds debug logging (delegate debounce metrics, skipped activations, retry-loop removal logs).

### Rollout / backward compatibility

All changes are internal to the iPhone app's watch manager. No protocol changes, no watch-side changes, no data format changes. The watch app is unaffected.

## Alternatives considered (and why rejected)

### A: Defer WCSession activation until after full app initialization

**Why rejected**: WCSession must be activated early to receive background messages (e.g., watch bolus requests). Deferring activation risks missing safety-critical messages.

### B: Add a global "initializing" flag and drop all delegate callbacks during init

**Why rejected**: Overly coarse. Would miss legitimate session events during normal startup. The debounce approach is more precise.

### C: Wrap all delegate work in a serial DispatchQueue

**Why rejected**: Serializing doesn't reduce the total work — it just queues it. The debounce approach cancels superseded work entirely, which is the correct behavior (only the latest state matters).

## Risks / Open questions

| Risk | Mitigation |
|------|------------|
| Debounce delay (0.5s) could delay the first watch state push after activation | 0.5s is imperceptible; can tune if needed. Any publisher-side coalescer, if present, uses longer delays. |
| Removing `retryConnection()` might delay reconnection in some edge cases | iOS WCSession manages its own reconnection; the manual retry was redundant at best, harmful at worst. Monitor via logs. |
| Force-unwrap removal might mask a real configuration bug | The guard-let pattern logs at `.warning` level so failures are visible in Better Stack. |

## Success criteria (verifiable)

1. **No crash loop during watch reboot/locked state**: Reproduce the scenario (reboot watch, don't enter PIN) and verify zero crashes over 5 minutes.
2. **Normal watch communication unaffected**: Verify glucose updates, bolus requests, override activation, and complication updates all work as before.
3. **Delegate callbacks are coalesced**: Verify via logs that N rapid delegate callbacks produce at most one delegate-triggered state push per 0.5s debounce window (so at most 1–2 pushes over a short storm), not N pushes.
4. **No feedback loop**: Verify that `retryConnection()` / `session.activate()` is not called repeatedly in logs during watch disconnection.
5. **Service resolution failures are logged, not crashed**: Temporarily break a service registration in debug and verify the app logs the failure instead of crashing.

## Changelog

### v1.5 (2026-03-15)
- Context: explicit that publisher-driven update handling varies by branch; design scoped to delegate hardening and compatible with any existing publisher coalescer.
- Non-functional / Reliability: softened to "designed to eliminate the observed crash-loop mechanism while keeping normal watch communication intact".

### v1.4 (2026-03-15)
- Change 1: removed reference to scheduleWatchStateUpdate; describe mechanism as "cancel-and-replace with a short delay".

### v1.3 (2026-03-15)
- "Why this tradeoff": removed claim that existing coalescer is "proven in the codebase"; use "familiar debounce pattern".
- "Triggers and flows": publisher-driven updates described as "continue as before" without assuming scheduleWatchStateUpdate.
- Risks table: debounce delay mitigation no longer assumes publisher coalescer exists.

### v1.2 (2026-03-15)
- Context: generalized publisher-driven path (no assumption that scheduleWatchStateUpdate exists on all branches).
- Change 3: clarified that no replacement retry is added; backoff is only for any future reintroduction.
- Success criteria 3: tightened to one push per debounce window (at most 1–2 over a storm), not N.

### v1.1 (2026-03-15)
- Change 1: heading corrected to "via a new delegate coalescer" (we add a new mechanism, not route through the existing one).
- Change 4: clarified that duplicate resolution calls in `loadServices()` may be removed when applying the guard-let pattern.
- Risks: corrected log level for force-unwrap mitigation to `.warning` (app’s global `error()` is fatal; use warning for graceful degradation).

### v1.0 (2026-03-13)
- Initial design based on crash log analysis of ~40-50 `EXC_BREAKPOINT` crashes during Apple Watch reboot with locked PIN state.
