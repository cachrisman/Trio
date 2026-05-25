# Watch G7 direct BLE — bug audit feedback & implementation log

**Version:** v1.4  
**Last updated:** 2026-05-11 13:39 CEST

---

## Initial audit findings (findings-only pass)

Scope: Trio watch app extension and related shared code; **`HapticBeacon` excluded** from audit/reporting. Severity: **Blocker** | **High** | **Medium** | **Low**.

### `Trio Watch App Extension/G7WatchSensorAdapter.swift`

**[Medium]** `consecutivePreEGVDisconnects` not reset on end-of-session from EGV  
Description: `triggerEndOfSessionFromEGV` clears binding and swaps `G7Sensor` but does not zero `consecutivePreEGVDisconnects` (counter reset elsewhere only for post-EGV disconnect, EGV success, or `stale_sensor_reinit`).  
Risk: Stale nonzero counter across EOS boundaries; misleading telemetry for consecutive pre-EGV disconnect diagnostics.

**[Medium]** `extendedSession` assigned before `extendedRuntimeSessionDidStart`  
Description: `extendedRuntimeSessionWillExpire` assigned both `pendingChainSession` and `extendedSession` to the new `WKExtendedRuntimeSession` before `didStart`, so `extendedSession` could reference a session not yet started.  
Risk: Callers treating `extendedSession` as “active” misread state during hand-off; ordering sensitive to WatchKit invalidation semantics.

**[Medium]** Unbounded `missed` array build before retro cap  
Description: `reanchorExpectedWindowTimer` appended every 300s epoch into `missed` before applying the cold-start `suffix(50)` cap for emission; very large wall-clock gaps could allocate a huge array.  
Risk: Memory/CPU spikes after long gaps, clock skew, or stale `lastEGVEpoch`.

**[Medium]** `G7SensorDelegate` callbacks vs `@MainActor` extended-runtime delegate (latent data race)  
Description: Many adapter fields (`sessionPhase`, `consecutivePreEGVDisconnects`, counters, etc.) were mutated from delegate callbacks while only a subset of telemetry used `crossThreadTelemetryLock`; extended-runtime delegate methods are `@MainActor`.  
Risk: If `G7SensorKit` delivers delegate work off the main actor concurrently with extended-session updates, torn reads/writes on shared adapter state.

**[Low]** `currentSensorName` not cleared in EOS helper  
Description: `triggerEndOfSessionFromEGV` set `knownSensorName = nil` but not `currentSensorName` (other paths keep both aligned).  
Risk: Low immediate impact while `start()` gates on `knownSensorName`; maintenance/invariant drift.

**[Low]** Per-event `log()` uses unstructured `Task { await … }`  
Description: Each log spins a new unstructured task.  
Risk: Under extreme log volume, scheduling overhead or task buildup.

### `Trio Watch App Extension/Views/ComplicationDebugView.swift`

**[Low]** `isLoadingLogFiles` may remain `true` if inner `Task` is cancelled  
Description: Flag cleared only in `await MainActor.run` at end of `loadLogFileStats`; cancellation before that block can skip the clear.  
Risk: Debug stats stuck until view recreation (edge case).

**[Low]** `triggerConfirmation` chains `DispatchQueue.main.asyncAfter` without coalescing  
Description: Repeated taps schedule overlapping delayed clears of `showConfirmation`.  
Risk: Minor toast flicker/ordering; debug-only.

**Regression check (no defect)** — `.task` polling gates on **`isActive`** (`@State` mirror of `scenePhase`), not a captured `scenePhase`, avoiding frozen environment capture in a long-lived task.

### `Trio Watch App Extension/WatchState+Requests.swift`

**[Medium]** `syncTimeoutWorkItem` not cancelled on `sendMessage` error path  
Description: On WC failure, retry/fallback ran without cancelling the 30s timeout scheduled for the successful-queue path; a late failure near the timeout boundary could duplicate fallback / `clearStartupFirstRefreshInFlightOnMain` work.  
Risk: Duplicate fallback side effects and confusing timing vs retries.

**Regression check (no defect)** — Bounded retry: `nextRetry > 3` terminates after the documented cap; backoff `5s / 10s / 20s`.

### `Trio Watch App Extension/ExtensionDelegate.swift`

No substantive findings in the scoped pass (startup logging / wiring).

### `Trio Watch App Extension/TrioWatchApp.swift`

**[Low]** Duplicate foreground hooks (SwiftUI `scenePhase` vs `applicationDidBecomeActive`)  
Description: Both can invoke `WatchState.handleForegroundActiveEntry()`; `startupIsForegroundActive` dedupes.  
Risk: Mostly benign; ordering depends on UIKit vs SwiftUI lifecycle.

### `Trio Watch App Extension/WatchState.swift` (integration points)

**[Low]** `applyG7DirectBleSnapshot` cancels `syncTimeoutWorkItem` but does not set it to `nil`  
Description: `processRawDataForWatchState` nils explicitly elsewhere.  
Risk: Low hygiene; next request replaces after cancel.

### `Trio Watch App Extension/Views/TrioMainWatchView.swift`

**[Medium]** `isSessionUnreachable` ignores reachability  
Description: Comment claimed activation or reachability; implementation used **`activationState != .activated`** only (no **`isReachable`**).  
Risk: UI/gating mismatch wherever “unreachable” implied phone reachability.

### `Trio Watch Shared/TrioComplicationDataStore.swift`

**Regression check (no defect)** — Monotonic / `lastValidTimestamp` guard lives on **`saveOnMain`** (write path); **`latestSnapshot()`** read path documents no non-monotonic “skipped write” spam (Bug #5 intent).

---

## Evaluation of external feedback (Claude)

The follow-up assessment is **sound and aligned with design intent**:

- **`consecutivePreEGVDisconnects` not reset on EOS** — Accept: counter is session-scoped for stale-binding detection; EOS should zero it (and aligning `currentSensorName` with `knownSensorName` removes drift).
- **`extendedSession` before `didStart`** — Accept with elevated risk: assign **`extendedSession` only from `extendedRuntimeSessionDidStart`**; track pre-start sessions explicitly (**`sessionPendingDidStart`**).
- **Unbounded `missed` array** — Accept as lower urgency: truncation intent correct; implementation did excess allocation before truncating.
- **Delegate thread vs `@MainActor`** — Accept as confirmed after G7SensorKit review: **`G7SensorDelegate` on `delegateQueue` (background)** vs **`@MainActor`** extended-runtime delegate → **real data-race hazard**; fix by marshaling delegate handling to MainActor.
- **`syncTimeoutWorkItem` on `sendMessage` error** — Accept: cancel/nil timeout on failure before fallback/retry.
- **`isSessionUnreachable`** — Accept: fix reachability in the boolean (or rename if semantics stay activation-only).

Hygiene items (e.g. `currentSensorName` on EOS) were treated as low urgency but shipped with the same fix batch for consistency.

---

## Implementation record (Trio worktree)

**Repository:** `Trio` (paths below relative to repo root).

### `Trio Watch App Extension/G7WatchSensorAdapter.swift`

| Area | Change |
|------|--------|
| EOS | `triggerEndOfSessionFromEGV`: **`consecutivePreEGVDisconnects = 0`**, **`currentSensorName = nil`** (with **`knownSensorName = nil`**). |
| Extended runtime | **`sessionPendingDidStart`**; **`renewSessionIfNeeded`** sets pending + `start()` only; **`extendedRuntimeSessionWillExpire`** does not assign **`extendedSession`** before start; **`extendedRuntimeSessionDidStart`** assigns **`extendedSession = session`**; **`stop()`** and chain timeout / **`didInvalidate`** clear pendings; pending-only invalidation **returns** without **`stop()`**. |
| Expected window | **`reanchorExpectedWindowTimer`**: count missed windows + **`stride(from:to:by:)`** for retro ticks (no large intermediate array). |
| Concurrency | **`G7SensorDelegate`**: **`nonisolated`** stubs → **`Task { @MainActor in … }`** into **`@MainActor`** **`handleSensor*`** helpers; connection status dispatches **`publishConnectionStatus()`** on MainActor. |

### `Trio Watch App Extension/WatchState+Requests.swift`

| Area | Change |
|------|--------|
| WC error path | **`requestWatchStateUpdate(retryCount:)`** `sendMessage` failure block: **`syncTimeoutWorkItem?.cancel()`** and **`syncTimeoutWorkItem = nil`** before fallback/retry. |

### `Trio Watch App Extension/Views/TrioMainWatchView.swift`

| Area | Change |
|------|--------|
| Reachability | **`isSessionUnreachable`**: **`activationState != .activated \|\| !session.isReachable`**. |

---

## Second round feedback (verification)

External review: **all accepted findings are addressed correctly**; implementations match intent.

| Finding | Verdict |
|--------|---------|
| **EOS counter / name** | **`consecutivePreEGVDisconnects = 0`** and **`currentSensorName = nil`** added together in EOS path — clean. |
| **`extendedSession` ordering** | **`sessionPendingDidStart`** pattern is the right design; **`extendedSession`** only assigned from **`didStart`**; pending cleared on timeout, invalidate, and **`stop`**. |
| **Unbounded `missed` / retro tick** | **`stride(from:to:by:)`** approach is strictly better than the original; no intermediate full-size array; **`lastMissed`** tracking remains correct for **`nextEpoch`**. |
| **Delegate race** | **`nonisolated`** stubs + **`Task { @MainActor in }`** hop is appropriate given **`delegateQueue`** delivery; mutable adapter state touched only on MainActor from delegate paths. |
| **`syncTimeoutWorkItem` on error** | Cancel + nil before fallback — correct order. |
| **`isSessionUnreachable`** | Fix matches the reported bug. |

**Follow-up flagged (second-order):** **`fireExpectedWindowTick`** / **`reanchorExpectedWindowTimer`** still run from **`timerQueue`**, so timer-path mutators remain off MainActor while delegate paths are MainActor-serialized. Reasonable to defer: delegate race was higher risk; **serializing the timer path to MainActor** (or equivalent) is the natural next step for full concurrency hardening — aligns with existing **Follow-ups** below.

**Overall:** Clean close on the audit scope; timer lane left as optional hardening.

---

## Option B — `@MainActor` adapter (timer hardening)

**Decision:** Make the entire **`G7WatchSensorAdapter`** `@MainActor` so isolation matches delegate marshaling and the compiler enforces it (vs mixed isolation / manual audit).

**`G7BluetoothManager` sanity check (grep `dispatchPrecondition`):** Scan/connect entry points use **`.notOnQueue(managerQueue)`** for work that must hop onto `managerQueue`; internal paths use **`.onQueue(managerQueue)`**. No **`must not call from main`** precondition surfaced — **`resumeScanning` / `stopScanning`** calls from MainActor align with **`.notOnQueue(managerQueue)`** (main is not `managerQueue`).

**Implementation (Trio worktree):**

| Area | Change |
|------|--------|
| Class | **`@MainActor final class G7WatchSensorAdapter`**; redundant per-member **`@MainActor`** on session fields / accessors / **`renewSessionIfNeeded`** / **`handleSensor*`** / WK extended delegate extension removed (class isolation applies). |
| Timers | **`timerQueue`** timers **`Task { @MainActor [weak self] in … }`** into **`emitHeartbeat`** / **`fireExpectedWindowTick`** — timers stay off MainActor; mutation runs on MainActor. **`emitHeartbeat`** body simplified (no nested **`Task`**). |
| **`stop` / `applyForegroundActiveEntry` / `mirrorDailyCounters` / `publishConnectionStatus`** | Direct MainActor calls (**no** **`Task { @MainActor`** wrappers) now that the class is isolated. |
| Delegates | **`nonisolated`** **`G7SensorDelegate`** stubs unchanged (**`Task { @MainActor in … shared … }`**). |
| **`ExtensionDelegate`** | **`G7Telemetry.emit`** wraps reads of **`shared`** / telemetry in **`Task { @MainActor in … }`** (emitter may run off main). |
| **`WatchState`** | **`@MainActor`** on **`handleForegroundActiveEntry`**, **`handleForegroundInactiveOrBackground`**, **`applyG7ActiveSensorNameFromWatchPayloadIfPresent`**, and **`scheduleUIUpdate`** (calls **`applyG7…`** synchronously). **`DispatchQueue.main.async`** paths that invoke **`applyG7…`** / **`scheduleUIUpdate`** use **`@MainActor`** closures (including **`processWatchMessage`**’s outer **`main.async`** and the userInfo branch that calls **`scheduleUIUpdate`**). |

**`HapticBeacon`** remains **`@MainActor`** — **`isIntentionallyStopped`** stays compatible without further hops.

---

## Post–Option B cleanup (external review)

Follow-up items after **`@MainActor`** adapter (same doc session / verification):

| Item | Action |
|------|--------|
| **Telemetry lock** | Removed **`NSLock`** / **`syncTelemetry`** and **`locked*`** backing stores — **`adapterSessionID`**, **`lastKnownScenePhase`**, **`lastKnownExtSessionActive`** are plain stored properties. With **`@MainActor`**, the lock implied cross-thread access that no longer exists. |
| **`triggerEndOfSessionFromEGV`** | Dropped **`Thread.isMainThread`** branch and stale CoreBluetooth/deadlock commentary; battery read assumes MainActor (delegate hop). Removed unused **`import CoreBluetooth`**. |
| **`renewSessionIfNeeded`** | Guard extended with **`sessionPendingDidStart == nil`** so a foreground renew cannot overwrite a pending start while **`extendedSession`** still reflects an old session (e.g. chain window). |

**`WatchState+Requests.swift`:** Independent review confirms **`syncTimeoutWorkItem`** cancel + nil before fallback/retry is correct; retry cap/backoff matches the implementation record. Optional note only: retry **`asyncAfter`** retains strong **`self`** (singleton — no practical leak).

---

## Follow-ups (not done here)

- Consider renaming **`isSessionUnreachable`** if semantics expand again.

---

## Changelog

### v1.4 (2026-05-11 13:39 CEST)

- **Post–Option B cleanup:** Telemetry lock removal; EOS battery/comment cleanup + drop **`import CoreBluetooth`**; **`renewSessionIfNeeded`** pending-session guard. **`WatchState+Requests`** verification note (timeout fix + optional strong-self retry).

### v1.3 (2026-05-11 13:22 CEST)

- **Option B:** Recorded **`@MainActor`** **`G7WatchSensorAdapter`**, timer **`Task { @MainActor }`** handoff, **`ExtensionDelegate`** / **`WatchState`** call-site isolation updates, and **`G7BluetoothManager`** **`dispatchPrecondition`** grep note (no main-thread prohibition for scan paths).

### v1.2 (2026-05-11 13:10 CEST)

- **Second round feedback:** Recorded verification pass — all six remediated items confirmed; **timer vs MainActor** follow-up explicitly acknowledged as legitimate second-order work (see **Second round feedback** and **Follow-ups**).

### v1.1 (2026-05-11 13:05 CEST)

- Document structure: **initial audit findings** section added first (scoped findings-only pass); **evaluation of external feedback** follows; implementation record and follow-ups unchanged in substance; **changelog moved to end**; version style **v1.1**.

### v1 (2026-05-11 12:51 CEST)

- Initial document: external feedback evaluation; implementation record for fixes in Trio worktree (`Trio/`).
