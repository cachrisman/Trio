# Alternative Delivery — Implementation Plan (Steps 5, 7)

**Version:** 1.3
**Date:** 2026-03-30 22:46 CEST
**Last updated:** 2026-04-06 17:27 CET
**Status:** COMPLETED — both steps shipped; build-146 second-pass follow-up **observed in production** (Better Stack 2026-04-06 — see [implementation log snapshot](alternative-delivery-implementation-log.md#better-stack--production-snapshot-queried-2026-04-06))

Design: [alternative-delivery-design.md](alternative-delivery-design.md)

---

### Step 5 — PR: R4 (applicationContext safety net, after R3)

**Files:** `AppleWatchManager.swift`, `Trio Watch App Extension/WatchState.swift`

**R4b confirmed:** `didReceiveApplicationContext` does not exist — purely additive. Add after `sessionReachabilityDidChange` (~line 631, in WCSessionDelegate section starting at line 422).

**What to implement:**

> **Prerequisite:** R4 depends on the App Group save path (`TrioComplicationDataStore`) being healthy. The complication reads exclusively through the App Group store — if saves are broken, delivering data via `applicationContext` has no effect. FP-Phase 3.0/3.1 must be shipped and stable (confirmed: shipped build 131).

iOS side (`AppleWatchManager.swift`) — at END of `sendDataToWatch`, after all transfer/sendMessage calls and R1b queue-deep drain block (i.e. just before the function's closing brace, ~line 860):
1. `guard sessionIsReadyForTransfer()` — if readiness fails, log `context_skipped` (with all three readiness conditions) and return. This is the only path that emits `context_skipped`.
2. Compute `budgetExhausted` and `queueDeep`. `guard budgetExhausted || queueDeep else { return }` — silent return; no log event (budget is healthy, nothing to do).
3. Build `ctx` wrapping `complicationMessage` under `WatchMessageKeys.watchState` with a `context_updated_at` timestamp. Log `context_attempted`.
4. `try session.updateApplicationContext(ctx)` — log `context_succeeded` on success, `context_failed` on error.
- See [alternative-delivery-design.md §R4 iOS side](alternative-delivery-design.md#ios-side) for the full code sample
- Uses `debug(.watchManager, ...)` (iOS-side logging pattern)

Watch side (`WatchState.swift`) — standalone R4 handler (no R5d integration). Add after `sessionReachabilityDidChange` (~line 631):
```swift
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { await WatchLogger.shared.log("📦 didReceiveApplicationContext") }
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else { return }
    DispatchQueue.main.async { [weak self] in
        self?.saveComplicationSnapshot(from: payload)
    }
}
```

> **⚠️ Logging pattern:** Watch-side code uses `Task { await WatchLogger.shared.log(...) }`, not `debug(.watchManager, ...)`. The `debug(.watchManager, ...)` pattern is iOS-side only.

> **R5d upgrade path:** When Step 6 (R5d) ships, extend this handler with `lastDataReceivedAt` tracking and `forceWidgetReloadIfStale(receivedGap:)` using the three-constraint ordering described in [observability-design.md §R5d](../observability/observability-design.md). See Step 6 STOP block for the cross-reference reminder.

> ## ✅ COMPLETED — build 142 deployed and validated (2026-03-19). All three validation signals confirmed: iOS context_succeeded, watch didReceiveApplicationContext, save_age p90 384s during budget exhaustion.
> **Code review verified:**
> - `updateApplicationContext` placement is at END of `sendDataToWatch` (after all transfer calls and R1b queue-deep drain, before closing brace)
> - `sessionIsReadyForTransfer()` is checked before reading budget/queue properties
> - `sessionIsReadyForTransfer()` does **not** check `isReachable` — confirmed: checks `activationState`, `isPaired`, `isWatchAppInstalled` only
> - `complicationMessage` is in scope (built unconditionally by R3) and wrapped under `WatchMessageKeys.watchState` with `context_updated_at` timestamp
> - Watch-side handler uses `Task { await WatchLogger.shared.log(...) }` (not `debug(.watchManager, ...)`)
> - Standalone R4 handler — no R5d dependencies (`lastDataReceivedAt`, `forceWidgetReloadIfStale`)
> - Existing iOS `didReceiveApplicationContext` (receives `complicationLastValidTimestamp` from watch) is a separate data flow; no conflict
> - No new linter errors introduced
>
> **Validation results (build 142):**
> - iOS: `context_succeeded` events present (`msg LIKE '%context_succeeded%'`)
> - Watch: `didReceiveApplicationContext` log events present
> - Freshness: `save_age` p90 = 384s during exhaustion windows, compared to pre-R4 baseline
> - Freshness improvement alone is suggestive but not sufficient — correlate with send/receive evidence

### Step 5.1 — staged follow-up: background-task completion alignment for R4/R5d

**Status:** First-pass task-completion alignment shipped in build 146. Production logs showed partial improvement but the user-visible 5-second dismissal persisted. Second-pass follow-up (commit `58f706a0f`, patch 09 regenerated) is **live in production telemetry** as of **2026-04-06** (terminal-marker + retry log lines present in Better Stack). **Open:** pin the exact TestFlight build, confirm UX vs the 5-second dismissal, drive `late_task_late_task` to zero if possible, and compare `path=timeout` rate vs a build-146 baseline with matching version filters.

**Files:** `Trio Watch App Extension/WatchState.swift`
**Companion observability changes staged in feature worktree:** `Trio Watch App Extension/ExtensionDelegate.swift`, `Trio Watch App Extension/TrioWatchApp.swift`

**Build-146 findings that triggered the second pass:**

1. `path=fast`, `path=application_context`, and `..._late_task` completions do appear in production — the first-pass fix was not dead code.
2. `path=timeout` still dominates many wake windows, so the common case still behaves like a 5-second watchdog completion.
3. `complication_bgtask_completion_deferred ... pending_content=true` frequently had no follow-up completion except timeout.
4. `fast_late_task_late_task` proved the terminal marker path was being chained instead of canonicalized.

**Problem now being addressed:** Reduce the remaining timeout-dominant wakes without removing the `hasContentPending` safety gate that prevents over-completing a wake while buffered session content still exists.

**Implementation shape now committed / patch-regenerated:**

1. Add a centralized helper in `WatchState.swift` to complete pending connectivity tasks and log the completion path.
2. Add a short-lived terminal marker (`lastConnectivityTerminalAt` / `lastConnectivityTerminalPath`) with a 2-second rescue window.
3. Let **successful terminal paths** record a marker even when there are zero pending tasks:
   - valid `didReceiveUserInfo` terminal path (`fast`)
   - valid `didReceiveApplicationContext` terminal path (`application_context`)
   - valid finalize path carrying a pending completion path
4. Canonicalize marker paths before storage so late rescue appends `_late_task` only once.
5. Keep **invalid / dedup / outdated / malformed** paths guarded:
   - complete only when `WCSession.hasContentPending == false`
   - these paths must not leave a broad terminal marker while more session content may still arrive
6. When completion is deferred because `hasContentPending == true`, schedule a bounded main-thread retry loop:
   - exponential backoff starting at 0.2s
   - capped at 1.0s
   - stops after a 4-second total retry budget
7. In `handleBackgroundTasks`, when a `WKWatchConnectivityRefreshBackgroundTask` is appended late, first check for a recent terminal marker and attempt an immediate completion before arming the 5-second timeout.
8. Make `scheduleUIUpdate` self-route to main before touching completion helpers or debounce state.
9. Add observability to distinguish:
   - terminal marker with zero pending tasks
   - finalize path with zero pending tasks
   - retry pending / retry ready / retry expired states
10. Keep `setTaskCompletedWithSnapshot(false)` unchanged on all proactive completion paths. This is a task-lifecycle fix, not a snapshot/UI semantics change.

**Intentional policy choice:** late-task rescue still calls the helper with `requiresNoPendingContent == true`.

**Why this is the correct staged choice:**

- A valid terminal marker proves that one watch-state path finished, not that the entire session wake is drained.
- `applicationContext` and `transferUserInfo` can both participate in the same wake; a valid `applicationContext` save must not be allowed to end the wake if queued `userInfo` complication payloads are still buffered.
- `hasContentPending` is coarse, but the unsafe failure mode is over-completing the wake and reintroducing the original suspension-before-processing bug.
- The bounded retry loop is the compromise that reduces timeout-only completions without discarding that safety gate.

**Alternative considered and deferred:** watch-state-specific pending-work tracking. This was explicitly deferred because it is a larger lifecycle change requiring a separate state model for semantic queue ownership; it is not a small logging enhancement.

**Validation gate for this staged follow-up:**

1. The watch no longer returns to the clock face at about 5 seconds after opening from the complication or app menu — **on-device**; not closed from logs alone.
2. `event=complication_bgtask_completing path=timeout` drops relative to the build-146 baseline, especially for wakes that previously logged `complication_bgtask_completion_deferred` — **requires version-filtered before/after**; 7-day aggregate in [implementation log](alternative-delivery-implementation-log.md#better-stack--production-snapshot-queried-2026-04-06) is a coarse sanity check only.
3. No `..._late_task_late_task` chaining appears in logs — **not yet met** in the 2026-04-06 window (**4** lines / 7d in snapshot); keep investigating edge paths.
4. Multiple pending deliveries still converge correctly — no sign that later watch-state updates are missed when both `applicationContext` and `transferUserInfo` participate in the same wake.
5. New logs confirm the decision boundary:
   - `..._late_task` completion paths appear
   - `event=complication_bgtask_completion_deferred ... pending_content=true` appears when rescue is intentionally deferred
   - `event=complication_bgtask_completion_retry_ready` appears when a deferred wake drains in time — **observed** in snapshot
   - `event=complication_bgtask_completion_retry_expired` explains residual timeouts when pending content never clears quickly enough — **zero in snapshot window**; keep monitoring

**Do not add in this staged change:**

- no watch-state-specific pending queue tracker
- no change to stale-data or syncing UI
- no change to snapshot completion semantics (`setTaskCompletedWithSnapshot(false)` remains)

---

### Step 7 — PR: R6 (HealthKit Background Delivery)

**Decision gate:** Ship R6 before or alongside R4 (see [Decision Gate in design doc](alternative-delivery-design.md#decision-gate)). **Actual: R6 shipped first (build 140); R4 shipped build 142.** R6 addresses two distinct failure modes: (1) budget-exhaustion staleness — HealthKit delivers when WatchConnectivity budget is exhausted, and (2) WidgetKit scheduling gaps — observed in build 139 (9-min gap with fresh App Group data, `reload_age=548s`), where the `HKObserverQuery` wake trigger provides an independent opportunity to call `reloadTimelines`. Do not gate on budget-exhaustion metrics alone.

**Before running the Cursor prompt below:** HealthKit with background delivery is already enabled on the Trio WatchKit Extension App ID in the Apple Developer portal. Only the entitlements file in the project needs to be updated.

**Files to modify:**
- `Trio Watch App Extension/WatchState.swift` — add HealthKit observer setup, sample fetch, snapshot construction
- `Trio Watch App/TrioWatchApp.entitlements` — add HealthKit + background delivery entitlements
- `Trio Watch App/Info.plist` — add `NSHealthShareUsageDescription` (required for HealthKit read authorization)

**Entitlement keys to add** (to `Trio Watch App/TrioWatchApp.entitlements`):
```xml
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.background-delivery</key>
<true/>
```

**Privacy usage description to add** (to `Trio Watch App/Info.plist`):
```xml
<key>NSHealthShareUsageDescription</key>
<string>Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable.</string>
```

The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires `NSHealthShareUsageDescription` in the requesting process's `Info.plist`. Without it, authorization may crash on launch. `NSHealthUpdateUsageDescription` is also **required by App Store Connect validation**: Apple's altool rejects uploads that have the `com.apple.developer.healthkit` entitlement but are missing this key, regardless of `toShare: nil`. Both keys must be present. (Confirmed by build 140 deployment — see deviations below.)

**What to implement:**

**R6a — Background delivery registration + authorization (WatchState.swift):**
- Add `import HealthKit` to the file
- Add `private var healthKitStore: HKHealthStore?` and `private var glucoseObserverQuery: HKObserverQuery?` properties
- Add `setupHealthKitBackgroundDelivery()` — call from **end of `setupSession()`**, **outside** the `if WCSession.isSupported()` block — HK setup must not be gated on WatchConnectivity availability (CR1 fix)
- Request read authorization for `.bloodGlucose` (toShare: nil, read: Set([bgType])) — use `[weak self]` in the callback and `guard let self` before using `self`
- Call `enableBackgroundDelivery(for: bgType, frequency: .immediate)` inside authorization callback
- Log: `hk_background_delivery_registered success=\(success)` or `hk_background_delivery_registration_failed error=\(error)`
- Log: `hk_authorization_failed granted=\(granted) error=\(error)` if denied

**R6b — Observer query (WatchState.swift):**
- Add `setupGlucoseObserverQuery(store:sampleType:)` — called from authorization success callback
- Create `HKObserverQuery(sampleType: bgType, predicate: nil)` with update handler that calls `fetchLatestGlucoseFromHealthKit(completionHandler:)`
- Store query reference in `self.glucoseObserverQuery` to prevent deallocation
- On error: log `hk_observer_error error=\(error)` and call `completionHandler()`

**R6c — Sample fetch + snapshot save (WatchState.swift):**
- Add `fetchLatestGlucoseFromHealthKit(completionHandler:)` — the core data path
- `HKSampleQuery` fetching last 2 `bloodGlucose` samples with `sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)]` — `HKSampleQuery` requires `[NSSortDescriptor]?` (not Swift `SortDescriptor`); use the keyPath API, not the deprecated `HKSampleSortIdentifierStartDate`
- Extract glucose: `latest.quantity.doubleValue(for: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)))` → `String(Int(value.rounded()))` — **Note:** `.milligramsPerDeciliter()` is a LoopKit custom extension unavailable on watchOS; use the inline unit construction (confirmed by build 140 compile failure)
- Derive delta: if 2 samples available, `latest - previous` → `String(format: "%+.0f", delta)`; else `"--"`
- Trend: `""` (empty — no derivation in R6; derivation added in R6.1, shipped build 141)
- Glucose color: `nil` (requires user settings context not available from HealthKit)
- Compute save age: `let saveAge = Int(Date().timeIntervalSince(readingDate))` — measures HealthKit sync latency
- Construct `TrioComplicationSnapshot(glucose:trend:delta:readingDate:date:glucoseColor:)`
- Call `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` on main queue — triggers `reloadTimelines` only when (a) the snapshot passes `saveOnMain` dedup (`shouldUpdate` returns true) and (b) 5+ seconds have elapsed since the last reload. In the target scenarios (budget exhaustion, WidgetKit scheduling gaps), both conditions are typically met because no prior delivery has occurred recently. In normal dual-delivery operation, the HK snapshot passes dedup (trend differs) and the 10–60s sync latency exceeds the 5s debounce — see [alternative-delivery-design.md §Dedup and Dual-Delivery Behavior](alternative-delivery-design.md#dedup-and-dual-delivery-behavior) for the trend overwrite tradeoff
- **Critical:** Call `completionHandler()` after the save runs: inside `DispatchQueue.main.async { save(...); completionHandler() }` on success; on error/zero-samples paths call it before return. Do not use `defer { completionHandler() }` at closure exit.
- Log: `hk_observer_fired reading_epoch=\(Int(readingDate.timeIntervalSince1970)) save_age=\(saveAge) glucose=\(glucoseString) delta=\(deltaString)`

**Log event taxonomy (R6):**

| Event | Fields | When |
|---|---|---|
| `hk_background_delivery_registered` | `success=Bool` | App launch, authorization granted. ⚠️ When `success=false` with no error (enableBackgroundDelivery returned false), log with `⚠️` prefix rather than `✅` to distinguish from the success case — see CR4 |

All events use `debug(.watchManager, ...)` or WatchLogger per target; watch extension uses `WatchLogger.shared.log`. The `hk_observer_fired` event is the primary validation signal — distinguishable from WatchConnectivity via `msg LIKE '%hk_observer_fired%'`.

**Test plan:**

1. **On-device (active CGM):** Deploy to device. Wait for the next CGM reading to be written to HealthKit by Trio. Verify `hk_observer_fired` appears in BetterStack logs. After a second reading (~5 min later), verify delta is computed correctly. Note: background delivery is not supported on Simulator — all HealthKit observer/background-delivery validation must be on-device.

2. **On-device (real CGM running):** Deploy to device with active CGM session.
   - Verify `hk_background_delivery_registered success=true` at app launch
   - Verify `hk_observer_fired` events appear in BetterStack with ~5-min cadence matching CGM interval
   - Verify during budget-exhaustion window: `hk_observer_fired` events continue even when `complication_transfer_remaining=0`
   - Verify dual-delivery behavior: same-reading WC + HK deliveries are not always deduped — the HK snapshot's `trend=""` differs from WC's real trend, so `shouldUpdate` returns `true` and the HK save is accepted. Confirm via logs that both `saveOnMain entered` and `Snapshot saved` fire for the HK delivery. See [alternative-delivery-design.md §Dedup and Dual-Delivery Behavior](alternative-delivery-design.md#dedup-and-dual-delivery-behavior) for the expected trend overwrite tradeoff

3. **Authorization denied:** Deny HealthKit read permission on watch.
   - Verify `hk_authorization_failed` is logged
   - Verify no `hk_observer_fired` events
   - Verify WatchConnectivity path is completely unaffected

4. **Entitlement + Info.plist verification:** Before building, confirm both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` are in `TrioWatchApp.entitlements` (without these, `enableBackgroundDelivery` silently fails), and confirm `NSHealthShareUsageDescription` is in `Trio Watch App/Info.plist` (without it, `requestAuthorization` may crash on launch).

> ## Cursor-Ready Implementation Prompt
>
> **Context:** You are implementing R6 (HealthKit Background Delivery) from the alternative-delivery design and implementation plan docs. *(Historical prompt — originally referenced the monolithic `complication-freshness-remediation-plan.md` v1.34 §R6 and `complication-freshness-implementation-guide.md` v1.20 Step 7, which have been reorganized into this subfolder.)*
>
> **Task:**
> 1. Add HealthKit + background delivery entitlements to `Trio Watch App/TrioWatchApp.entitlements` (add `com.apple.developer.healthkit` = true, `com.apple.developer.healthkit.background-delivery` = true).
> 1b. Add both usage description keys to `Trio Watch App/Info.plist`. `NSHealthShareUsageDescription` is required because the watch app calls `requestAuthorization(toShare: nil, read:)`: `<key>NSHealthShareUsageDescription</key><string>Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable.</string>`. `NSHealthUpdateUsageDescription` is **also required** — App Store Connect rejects uploads with the HealthKit entitlement but missing this key, regardless of `toShare: nil` (ITMS-90683; confirmed build 140). Add any non-empty string. `NSHealthUpdateUsageDescription` does not grant write capability — authorization remains read-only.
> 2. In `Trio Watch App Extension/WatchState.swift`:
>    - Add `import HealthKit`
>    - Add properties: `private var healthKitStore: HKHealthStore?` and `private var glucoseObserverQuery: HKObserverQuery?`
>    - Add `setupHealthKitBackgroundDelivery()` — request read auth for `.bloodGlucose`, register `enableBackgroundDelivery(for:frequency:.immediate)`, then call `setupGlucoseObserverQuery`
>    - Add `setupGlucoseObserverQuery(store:sampleType:)` — create and execute `HKObserverQuery`
>    - Add `fetchLatestGlucoseFromHealthKit(completionHandler:)` — fetch last 2 samples, build `TrioComplicationSnapshot`, save via `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)`
>    - Call `setupHealthKitBackgroundDelivery()` from `setupSession()` **outside** the `if WCSession.isSupported()` block (at end of `setupSession()`) so HK setup is independent of WatchConnectivity. In the `HKObserverQuery` update handler, add `guard let self else { completionHandler(); return }` before calling `fetchLatestGlucoseFromHealthKit` so `completionHandler()` is always called.
> 3. **Critical:** Call `completionHandler()` only after the save has run: inside `DispatchQueue.main.async { TrioComplicationDataStore.shared.save(...); completionHandler() }` on the success path. On error or zero-samples paths, call `completionHandler()` before return. Do not use `defer { completionHandler() }` at closure exit — that signals "done" before the async save runs. Trend = `""`. Delta derived from 2 samples. Glucose color = `nil`. Use `[weak self]` and `guard let self` in the `requestAuthorization` callback.
> 4. Log all events per the taxonomy in Step 7 above.
> 5. Do NOT modify `HealthKitManager.swift`, `AppleWatchManager.swift`, or `TrioComplicationDataStore.swift`.
>
> **Verify:** Build compiles. `saveOnMain` handles dedup automatically — no new dedup logic needed.

> ## ✅ GATE PASSED (build 140, 2026-03-14)
> - Entitlements verified: both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` present in `TrioWatchApp.entitlements`
> - `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` both present in `Trio Watch App/Info.plist` (Apple requires both when HealthKit entitlement is present — see deviations below)
> - `completionHandler` verified: called inside `DispatchQueue.main.async` after save on success; before return on error/zero-samples paths
> - No iPhone-side changes: `HealthKitManager.swift` untouched
> - Code reviewed (ChatGPT rounds 1-3): CR1-CR5 all addressed, sanity checks passed
> - Build 140 deployed to TestFlight
> - BetterStack confirmed: `hk_background_delivery_registered success=true` at 15:45:19 UTC; `hk_observer_fired` events at 15:45:20, 15:52:54, 15:54:15 UTC with correct glucose/delta values
> - Ongoing: cadence, HK log latency (`save_age` build 140 → `sync_lag` build 141+), budget-exhaustion coverage, dual-delivery dedup — see [implementation log — production snapshot](alternative-delivery-implementation-log.md#better-stack--production-snapshot-queried-2026-04-06) and design §R6 validation (2026-04-06)
>
> **Deviations from plan:**
> 1. **`HKUnit.milligramsPerDeciliter` unavailable on watchOS:** The plan specified `.milligramsPerDeciliter()` but this is a custom extension in `LoopKit/MockKitUI`, not linked to the watchOS target. Fixed with inline `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`.
> 2. **`NSHealthUpdateUsageDescription` required by App Store Connect:** The plan (v1.34) stated this key was "not needed" because `toShare: nil`. Apple's altool validation rejects uploads missing it when the HealthKit entitlement is present, regardless of actual write usage. Added to `Info.plist`. Does not change app behavior — authorization remains read-only.

**Step 7 — Code review findings (ChatGPT round 1)**

| # | Severity | Finding | Disposition |
|---|---|---|---|
| CR1 | **Required** | HK setup was inside `if WCSession.isSupported() { ... }`, making R6 conceptually dependent on WatchConnectivity. R6 is an independent wake path and must not be gated on WC. | **Fixed.** Call `setupHealthKitBackgroundDelivery()` outside the `if WCSession.isSupported()` block (e.g. at end of `setupSession()`) so it always runs when the watch app launches. |
| CR2 | **Required** | In `HKObserverQuery` update handler, `self?.fetchLatestGlucoseFromHealthKit(completionHandler:)` — if `self` is nil, nothing calls `completionHandler()`. System can throttle background delivery. | **Fixed.** Add `guard let self else { completionHandler(); return }` before calling `fetchLatestGlucoseFromHealthKit`. |
| CR3 | Non-blocking | Log sample query failure path: when HKSampleQuery returns error or zero/invalid samples, log for validation. | **Fixed.** Added `hk_observer_sample_query_error` and `hk_observer_sample_query_zero_samples` logs. |
| CR4 | Non-blocking | `enableBackgroundDelivery` callback: when `success == false` and no error, log distinctly (not with green check). | **Fixed.** Log `hk_background_delivery_registered success=false` with ⚠️. |
| CR5 | **Required** | `completionHandler()` was invoked via `defer` when the HKSampleQuery closure exited, but the save runs inside `DispatchQueue.main.async` — so the system was told "done" before the save executed. Wrong ordering; can cause flaky behavior. | **Fixed.** Call `completionHandler()` only after the save runs: inside the `DispatchQueue.main.async { save(...); completionHandler() }` block on the success path. Error and zero-samples paths call `completionHandler()` before return. Removed unused `[weak self]` from the HKSampleQuery closure. |

No disagreements; all changes incorporated.

**Step 7 — Sanity checks (ChatGPT round 3)**

| Check | Question | Result |
|---|---|---|
| S1 | Does `TrioComplicationDataStore.shared.save(...)` run synchronously when called from the main queue? If it does another async hop, completionHandler() could still fire before the write. | **Verified.** `save(_:triggerReload:minInterval:)` calls `onMain { saveOnMain(...) }`. `onMain` (TrioComplicationDataStore line ~881) runs `block()` synchronously when `Thread.isMainThread`; only when off main does it use `DispatchQueue.main.async`. Our R6 path calls save from inside `DispatchQueue.main.async { ... }`, so we are on main when save() runs; onMain runs saveOnMain inline. No extra async hop. completionHandler() runs after the write. |
| S2 | If WatchState can be initialized more than once, could we register multiple observer queries / duplicate setup? | **Verified.** WatchState is a singleton: `static let shared = WatchState()`. No public factory; init() runs once. No one-time guard needed. |

---

### Step 7.1 — PR: R6.1 (HealthKit Channel Improvements)

**Status:** ✅ Implemented (2026-03-15). HK fetch path replaced with `HKAnchoredObjectQuery`; anchor/epoch/value persistence in `TrioComplicationDataStore`; trend/delta derivation (raw delta first, then round once); R6.1 log taxonomy. **As implemented:** No SyncIdentifier predicate — 24h date cap when anchor is nil, nil predicate when anchor exists; source filtering deferred to R6.2 (see [healthkit-improvements-design.md §Source Predicate](../healthkit-improvements/healthkit-improvements-design.md#source-predicate)).

**Builds on:** Step 7 / R6, shipped in build 140. R6.1 refines the HK fetch/processing path; it does not replace R6's observer registration, authorization, entitlements, or background delivery mechanics.

---

**Decision gate:**

- No additional product or telemetry gate beyond the normal R6 observation period is required before implementing R6.1.
- R6.1 is a correctness and observability refinement after the R6 baseline — it improves the quality of an already-working channel rather than enabling a new one.
- Proceed to implementation when the R6 observation period is complete and no R6-specific regressions have been identified.

---

**Files changed:**

| File | Scope of change |
|---|---|
| `Trio Watch App Extension/WatchState.swift` | Replaced `HKSampleQuery` fetch helper with `HKAnchoredObjectQuery`; added epoch guard; updated log events |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Added anchor, epoch, and previous-sample persistence methods |

See [healthkit-improvements-implementation-log.md](../healthkit-improvements/healthkit-improvements-implementation-log.md) for the build 141 implementation record.

---

**Implementation boundaries:**

The R6.1 implementation did NOT modify:

- HealthKit authorization flow (`requestAuthorization`)
- `setupHealthKitBackgroundDelivery()` — registration and authorization shape. **Exception:** the `hk_background_delivery_registered` log call gains `low_power_mode=ProcessInfo.processInfo.isLowPowerModeEnabled` to match the R6.1 taxonomy. This is the only change to this function.
- `setupGlucoseObserverQuery(store:sampleType:)` — observer registration shape
- `HKObserverQuery` creation, execution, or update handler signature
- Entitlements (`TrioWatchApp.entitlements`)
- Info.plist (`Trio Watch App/Info.plist`)

R6.1 scope was the HK fetch/processing path (inside the observer callback) plus App Group persistence helpers in `TrioComplicationDataStore`. Everything upstream of the fetch and downstream of the save was unchanged.

---

**Key architectural decision — persistence location:**

- HK anchor and last-received epoch persistence belongs in `TrioComplicationDataStore`, not in raw `UserDefaults(suiteName:)` calls from `WatchState`.
- **Rationale:**
  - The existing App Group persistence pattern for the complication system already lives in `TrioComplicationDataStore` (snapshots, fingerprints, metadata, `lastValidTimestamp`).
  - Centralizing storage logic avoids leaking App Group suite name details into `WatchState`.
  - `WatchState` remains a consumer of the data store — it calls persistence methods but does not directly manage App Group `UserDefaults` for complication-related state.
- Six planned methods: `hkGlucoseAnchor()`, `saveHKGlucoseAnchor(_:)`, `hkLastReceivedGlucoseEpoch()`, `setHKLastReceivedGlucoseEpoch(_:)`, `hkLastReceivedGlucoseValueMgDl()`, `setHKLastReceivedGlucoseValueMgDl(_:)`.
- The epoch + value methods together provide the "previous sample" data needed for delta/trend derivation on single-sample steady-state fires.
- **Anchor serialization:** `HKQueryAnchor` is `NSSecureCoding`, not `Codable`. Serialize via `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)`, deserialize via `NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from:)`. Follows LoopKit `PersistenceController.storeAnchor`/`fetchAnchor` pattern. Decode failures log `hk_anchor_decode_failed` and fall back to nil anchor + 24h date cap.

---

**Key source predicate decision:**

- Use `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)` as the source filter for the anchored query.
- Do NOT use bundle-ID string filtering in R6.1.
- **Rationale:** Trio-written glucose samples already include `HKMetadataKeySyncIdentifier` in their metadata. This is a presence-only predicate (any sample with the key set, regardless of value). It filters out samples lacking sync identifiers (e.g., manual entries) without requiring hardcoded bundle identifiers.
- **Practical risk:** `HKMetadataKeySyncIdentifier` is a standard Apple sync key also used by other diabetes/HealthKit apps (Loop, xDrip, etc.). In multi-app setups, non-Trio samples may be included. This is an accepted tradeoff for R6.1. Value-specific or bundle/source refinement can be pursued in R6.2 if over-inclusion is observed.
- Consistent with [healthkit-improvements-design.md §Source Predicate](../healthkit-improvements/healthkit-improvements-design.md#source-predicate).

---

**Implementation shape (as built):**

The implementation replaced only the fetch/processing portion of the HK observer callback. Key design decisions:

- **`fire_id`:** Generate a `UUID` once at the start of each observer callback. Thread it through all subordinate query, persistence, and logging calls for that fire. Do not regenerate per helper or per save.
- `HKAnchoredObjectQuery` replaces the R6 `HKSampleQuery` fetch helper. The anchored query is executed with the persisted anchor (or `nil` + 24h date cap on first run) and returns both added samples and deleted objects since the last anchor.
- **Deleted objects** from the anchored query are ignored — deletions do not affect complication display.
- **Anchor advancement:** After every successful anchored query that returns a non-nil `newAnchor`, persist the new anchor via `TrioComplicationDataStore` — even on no-new-samples and epoch-guard-skip exits. This prevents repeated delivery of the same results on subsequent observer fires. Query errors and pre-query guard failures do not advance the anchor.
- **Epoch/value persistence — genuinely new-sample path only:** Persisted epoch and glucose value are updated only when a genuinely new sample is being processed (not on no-new-samples or epoch-guard-skip paths). On the new-sample path, delta and trend must be derived from the persisted previous epoch/value (or second-most-recent batch sample by `startDate`) *before* persisting the current sample's epoch and value. This derive-then-persist ordering prevents overwriting the previous-sample state before derivation.
- Fast-exit paths should be implemented for:
  - Guard failure (nil store, nil sample type) → log `hk_observer_guard_failed`, call `completionHandler()`
  - No new added samples from anchored query → save the new anchor (anchor advancement still applies), log `hk_observer_no_new_samples`, call `completionHandler()`
  - **Known epoch (post-query):** After the anchored query returns, if the latest returned sample's epoch matches the persisted last-received epoch → save the new anchor (anchor advancement still applies), log `hk_observer_skipped_known_epoch`, call `completionHandler()`. Do not update persisted epoch/value. This is an edge-case filter for modified/re-delivered samples, not the primary incremental mechanism (which is the anchored query returning zero new samples).
  - Query error → log `hk_observer_query_error`, call `completionHandler()`
  - Nil anchor / anchor decode failure → log `hk_observer_nil_anchor` or `hk_anchor_decode_failed`, fall back to nil anchor query with 24h cap
- **Sample ordering:** Determine latest and previous samples by sorting added samples by `startDate`, not by raw anchored-query array order. `HKAnchoredObjectQuery` returns results in store-insertion order, which is not guaranteed to be chronological — especially during backfill, sync catch-up, or retroactive sample delivery. Latest = greatest `startDate`.
- Latest sample (by `startDate`) drives the `TrioComplicationSnapshot` (glucose value, reading date).
- **Previous sample for delta/trend:** When the batch contains two or more added samples, use the second-most-recent by `startDate`. For the common steady-state case (one new sample per fire), use the persisted previous glucose value and epoch from `TrioComplicationDataStore`. Delta and trend must use the same selected previous sample — do not derive them from different sources on the same fire. Compute a single integer mg/dL delta via `Int(latestMgDl.rounded()) - Int(previousMgDl.rounded())`. This numeric delta is used for both trend classification (applied directly to the `BloodGlucose.Direction.init(trend:)` integer threshold family — no separate floating-point thresholds) and display formatting (`TrioComplicationSnapshot.delta`, e.g. `"+5"`, `"-12"`, mg/dL only). Trend output must be a raw direction string (`"Flat"`, `"SingleUp"`, etc.), not a symbol glyph. Derive only when `0 < timeDelta < 15 min` (plausibility gate).
- **Delta/trend fallback:** If no valid previous sample is available, or if the plausibility gate fails, both trend and delta fall back: trend to `""`, delta to the no-derivation default (e.g. `"--"` or blank). Do not synthesize from unrelated or implausible samples. This applies regardless of whether the previous sample was expected from the batch or persisted state.
- Exactly one main-thread save block: `DispatchQueue.main.async { TrioComplicationDataStore.shared.save(snapshot, minInterval: 5); completionHandler() }`.
- Observer `completionHandler()` must be called on every path — this is unchanged from R6.

*(Historical note: this guidance was written pre-implementation. R6.1 was implemented in build 141 — see [healthkit-improvements-implementation-log.md](../healthkit-improvements/healthkit-improvements-implementation-log.md) for the implementation record.)*

---

**Updated log taxonomy table (R6.1):**

| Event | Fields | When |
|---|---|---|
| `hk_background_delivery_registered` | `success=Bool low_power_mode=Bool` | App launch, authorization granted. `success` = return value of `enableBackgroundDelivery`. `low_power_mode` = `ProcessInfo.processInfo.isLowPowerModeEnabled` at registration time. Log with `✅` when `success=true`, `⚠️` when `success=false`. |
| `hk_background_delivery_registration_failed` | `error=String` | App launch, registration failed |
| `hk_authorization_failed` | `granted=Bool error=String` | Authorization request denied |
| `hk_observer_error` | `fire_id=UUID error=String` | Observer query error callback |
| `hk_observer_fired` | `fire_id=UUID reading_epoch=Int sync_lag=Int glucose=String delta=String trend=String trend_derived=Bool samples_in_batch=Int query_type=anchoredQuery` | Each observer fire that processes a new sample |
| `hk_observer_no_new_samples` | `fire_id=UUID` | Anchored query returned zero new samples (phantom fire) |
| `hk_observer_skipped_known_epoch` | `fire_id=UUID epoch=Int` | Latest sample epoch matches persisted last-received epoch |
| `hk_observer_query_error` | `fire_id=UUID error=String` | Anchored query returned an error |
| `hk_observer_guard_failed` | `fire_id=UUID reason=String` | Pre-query guard failed (e.g., nil store, nil sample type) |
| `hk_observer_nil_anchor` | `fire_id=UUID` | First run or anchor decode failure; nil anchor + 24h date cap |
| `hk_anchor_decode_failed` | `fire_id=UUID` | Persisted anchor data could not be decoded |

`query_type=anchoredQuery` on `hk_observer_fired` is the primary way to distinguish R6.1 logs from build-140 R6 logs in BetterStack queries. R6 logs do not include `query_type`.

**R6-only events replaced:** `hk_observer_sample_query_error` → `hk_observer_query_error`; `hk_observer_sample_query_zero_samples` → `hk_observer_no_new_samples`.

**R6 → R6.1 field-level rename on `hk_observer_fired`:** R6 uses `save_age=Int`; R6.1 renames this to `sync_lag=Int`. The semantics are identical (`now() - readingDate`), but the name better reflects end-to-end lag. BetterStack queries spanning R6 and R6.1 builds must account for this rename.

**New `trend` field on `hk_observer_fired`:** R6.1 adds `trend=String` alongside `trend_derived=Bool`. Contains the actual derived raw direction string (`"Flat"`, `"SingleUp"`, etc.) or `""` when not derivable. Enables validation of threshold mapping correctness, WC/HK format alignment, and dedup expectations.

---

**Sanity checks for R6.1:**

| Check | Expected |
|---|---|
| Anchor/epoch/previous-sample persistence methods are thread-safe | These helpers use App Group `UserDefaults` for simple reads/writes, which is thread-safe. Note: other `TrioComplicationDataStore` APIs (snapshot save, reload) remain main-thread-confined. Do not characterize the entire store as thread-agnostic. |
| Anchor, epoch, and previous-sample value are independent persistence paths | Anchor tracks HealthKit query position and advances on every successful query (including no-new-samples and epoch-guard skips); epoch + value track the last processed sample and update only when a genuinely new sample is processed. None depends on another's value. |
| Backfill batch produces one snapshot/save, not N saves | Multi-sample batch from anchored query → use latest by `startDate` for display → one `save()` call → one reload attempt. Saved snapshot's reading date must correspond to the greatest `startDate` in the batch. |
| Source predicate may over-include in multi-app setups | `HKMetadataKeySyncIdentifier` is a standard Apple sync key used by other diabetes apps. Presence-only predicate is a practical tradeoff accepted for R6.1; value-specific refinement deferred to R6.2. |
| Observer `completionHandler()` ordering remains correct | Called inside `DispatchQueue.main.async` after save on success; before return on all error/early-exit paths |
| Trend output uses raw direction strings, not symbol glyphs | Must produce `"Flat"`, `"SingleUp"`, etc. — same format as WC path — for correct `TrendSymbolMapper` rendering and dedup alignment |

---

**Post-implementation verification expectations:**

The following are observable in BetterStack for build 141+:

| Expectation | Query hint |
|---|---|
| `hk_observer_fired` events include `query_type=anchoredQuery` | `msg LIKE '%query_type=anchoredQuery%'` |
| `hk_observer_no_new_samples` appears for phantom fires | `msg LIKE '%hk_observer_no_new_samples%'` — should be non-zero over 24h |
| `trend_derived=true` appears on the majority of normal CGM intervals | `msg LIKE '%trend_derived=true%'` — should be the common case for consecutive 5-min readings |
| Derived `trend` values are valid direction strings | `msg LIKE '%trend=%'` — inspect actual values (`Flat`, `SingleUp`, etc.) to verify threshold mapping |
| `hk_anchor_decode_failed` should be absent under normal conditions | `msg LIKE '%hk_anchor_decode_failed%'` — expected 0 in steady state |
| `hk_observer_skipped_known_epoch` should be low-volume | `msg LIKE '%hk_observer_skipped_known_epoch%'` — present but not dominant |
| No `HKSampleQuery`-based events in new builds | `msg LIKE '%hk_observer_sample_query%'` — expected 0 from R6.1 builds |

Build 140 used R6's `HKSampleQuery`-based events; build 141+ uses R6.1's `HKAnchoredObjectQuery`-based events.

**Dual-delivery dedup benefit:** When R6.1 trend derivation produces the same raw direction string as the WC path for the same reading (e.g., both produce `"Flat"`), `shouldUpdate` may return `false` for same-reading dual delivery — glucose, trend, delta, and readingDate all match. This reduces or eliminates the R6 trend-overwrite regression where `trend=""` from HK overwrote a valid WC trend. Note: delta format differences for mmol/L users (HK always mg/dL, WC may be mmol/L) can still cause `shouldUpdate` to return `true` even when the trend matches.

**Inherited unit note:** R6 (and R6.1) compute HK delta in mg/dL. The WC path formats delta in the user's preferred units. For mmol/L users, HK and WC deltas have different string representations for the same reading, which prevents dedup from recognizing them as duplicates. R6.1 does not solve this unit-format parity; it is inherited from R6 and deferred unless separately scoped.

**Source-predicate over-inclusion note:** If derived delta or trend values appear anomalous relative to expected CGM behavior — especially in multi-app HealthKit setups — consider source-predicate over-inclusion before treating it as an implementation bug. The presence-only `HKMetadataKeySyncIdentifier` filter may include non-Trio samples. This is a known R6.1 tradeoff; value-specific refinement is deferred to R6.2.

**Derivation scope boundary:** R6.1 only adds derivation for `delta` and `trend`. `glucoseColor` remains `nil`, `state` is not synthetically derived, HK delta formatting stays mg/dL-only (no mmol/L parity), and `sync_lag` is used for logging only — not in display, dedup, or trend logic. This is an intentional scope boundary.

---

**Post-implementation verification prompt (used during build 141 review):**

> **Context:** You are verifying R6.1 (HealthKit Channel Improvements) implementation in `Trio Watch App Extension/WatchState.swift` and `Trio Watch Shared/TrioComplicationDataStore.swift`.
>
> **Verify the following — report pass/fail for each:**
> 1. Old `HKSampleQuery` helper for glucose fetch is removed (no `HKSampleQuery` in the HK fetch path).
> 2. `HKAnchoredObjectQuery` helper is present and used for the HK fetch.
> 3. Exactly one main-thread save block: `DispatchQueue.main.async { ... save(...) ... completionHandler() ... }`.
> 4. `completionHandler()` is called on every code path (error, no-new-samples, known-epoch skip, guard failure, success).
> 5. `completionHandler()` ordering is correct: called after save on success path, before return on error paths.
> 6. On the new-sample path, persistence ordering is: (a) new anchor is saved via `TrioComplicationDataStore`, (b) delta/trend are derived using the second-most-recent added sample by `startDate` or the previously persisted glucose value/epoch, (c) only after derivation, the current sample's epoch/value are persisted as the new previous-sample state, (d) then the main-thread snapshot save block runs.
> 6a. On no-new-samples and epoch-guard-skip paths: anchor is saved but epoch/value are NOT updated.
> 7. No raw `UserDefaults(suiteName:)` usage in `WatchState.swift` for HK anchor, epoch, or previous-sample storage.
> 8. No `defer { completionHandler() }` pattern anywhere in the HK fetch path.
> 9. No `HKSampleQuery` remaining in the HK fetch path (fully replaced by anchored query).
> 10. Anchor serialization uses `NSKeyedArchiver`/`NSKeyedUnarchiver` (not `Codable` or `JSONEncoder`).
> 11. Trend output is a raw direction string (`"Flat"`, `"SingleUp"`, etc.), not a symbol glyph.
>
> *(This prompt was used during the build 141 review cycle. All 11 checks passed.)*

---

## Quick Reference: Confirmed Symbols

| Symbol | Location | Notes |
|---|---|---|
| `readingDate` | `TrioComplicationSnapshot`, `TrioWatchComplicationEntry` | CGM reading time; `date` is creation/display time |
| `TrioComplicationDataStore.complicationKind` | `TrioComplicationDataStore.swift` line 147 | = `"TrioWatchComplication"` — use constant |
| `session(_:didReceiveApplicationContext:)` | Add to `WatchState.swift` after line ~631 | Under `// MARK: - WCSessionDelegate` (line 422); after `sessionReachabilityDidChange` |

---

## Changelog

### v1.3 (2026-04-06 17:27 CET)
- Step 5.1 / doc status: second-pass telemetry confirmed in Better Stack (2026-04-06); updated validation gate items with observed vs open outcomes; pointed R6 ongoing observation to implementation log snapshot and `sync_lag` (R6.1) instead of `save_age` p90-only wording.

### v1.2 (2026-03-30 22:46 CEST)
- Updated Step 5.1 after build 146. Recorded that the first-pass completion alignment was only partially effective in production, documented the second-pass committed follow-up (`58f706a0f`) and regenerated patch state, and added the canonical late-marker fix, bounded deferred-completion retry policy, widened 2-second rescue window, main-thread hardening for `scheduleUIUpdate`, and the new retry/marker telemetry expectations for the next deploy.

### v1.1 (2026-03-30)
- Added Step 5.1 documenting the staged follow-up that aligns `WKWatchConnectivityRefreshBackgroundTask` completion with the R4/R5d terminal paths. Recorded the terminal-marker implementation, the conservative `hasContentPending` gate for late-task rescue, the deferred watch-state-specific tracker alternative, and the exact post-build validation gate for the staged change.

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted Steps 5, 7, and 7.1 implementation plans from `complication-freshness-implementation-guide.md` into a standalone alternative-delivery implementation plan. Step 5 gate updated from "pending build/deploy" to COMPLETED with build 142 validation results. Reason: docs reorganization — group related alternative delivery channel implementation content for easier navigation and maintenance.
