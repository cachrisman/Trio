# Alternative Delivery — Design (R4 + R6)

**Version:** 1.4
**Date:** 2026-03-30 22:46 CEST
**Last updated:** 2026-04-08 22:26 CET
**Status:** COMPLETED — R4 shipped build 142 (validated), R6 shipped build 140; post-build-146 second-pass follow-up **observed in production logs** (Better Stack snapshot 2026-04-06 — see [implementation log](alternative-delivery-implementation-log.md))

Both R4 and R6 provide fallback delivery channels during budget exhaustion. R6 uses HealthKit as a WCSession-independent path — when the iPhone writes a blood glucose sample to HealthKit, Apple syncs it to the watch, and an `HKObserverQuery` wakes the extension to save a complication snapshot. R4 uses `applicationContext` as a budget-free parallel WCSession channel — during exhaustion or deep queue conditions, iOS sends the complication payload via `updateApplicationContext`, which the watch app extension receives and writes to the App Group store.

See [problem-and-strategy.md](../problem-and-strategy.md) for overall context.

---

## R4 — App Group Safety Net During Budget Exhaustion (Step 5)

**Priority:** P1 | **Effort:** 2–3 hrs | **Status:** COMPLETED — shipped build 142, validated. See [implementation log](alternative-delivery-implementation-log.md) for validation results.
**Files:** `AppleWatchManager.swift`, `Trio Watch App Extension/WatchState.swift`

### Architecture (corrected after Cursor R4 audit)

The complication is a WidgetKit extension. **`WCSession` is not available in WidgetKit processes.** `receivedApplicationContext` cannot be read from `getTimeline`. The only shared data path between the watch app extension and the complication is the App Group container, which `TrioComplicationDataStore` already uses.

The correct architecture is:

1. **iOS sends `updateApplicationContext`** — budget-free, always replaces with latest, delivered to watch app extension on reconnect
2. **Watch app extension receives it** via `session(_:didReceiveApplicationContext:)` and writes to `TrioComplicationDataStore` using the existing save path
3. **Complication reads from `TrioComplicationDataStore`** — unchanged, already works this way

This means `applicationContext` acts as a parallel delivery channel that feeds the same App Group store. During exhaustion windows, the complication gets fresh data from this channel rather than waiting for the 46-item `transferUserInfo` queue to drain.

> **Prerequisite:** R4 depends on the App Group save path (`TrioComplicationDataStore.shared.save` / `saveOnMain`) being healthy and stable. The complication reads exclusively through `TrioComplicationDataStore` — if the save path is broken (e.g. App Group suite unavailable, serialization failure, dedup rejecting all writes), delivering data via `applicationContext` has no effect on complication freshness. FP-Phase 3.0/3.1 (dedup, fingerprint, save path) must be shipped and confirmed stable before R4 has value.

### iOS side

> **⚠️ Placement: this entire block goes at the END of `sendDataToWatch`, AFTER all existing transfer calls and `sendMessage`.** The readiness and budget/queue guards bail out early when the session isn't ready or budget is healthy — that is intentional. But if placed before the main transfer logic, the early returns would skip all sends (complication transfer, userInfo, and sendMessage). It must come after those calls.

> **⚠️ `complicationMessage` must be in scope:** This block references `complicationMessage` (the R3 allowlist payload). If `sendDataToWatch` ever acquires an early-return path that runs before `complicationMessage` is built, the R4 safety net silently fires nothing during budget exhaustion. To prevent this: build `complicationMessage` unconditionally at the top of `sendDataToWatch`, regardless of which transfer path is subsequently taken. Do not gate its construction on `readingEpochPresent` or any other condition.

```swift
// In sendDataToWatch(), at the END — after all existing transfer/sendMessage calls:
guard sessionIsReadyForTransfer() else {
    debug(.watchManager, "📦 context_skipped activation_state=\(session.activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
    return
}

let budgetExhausted = session.remainingComplicationUserInfoTransfers == 0
let queueDeep = session.outstandingUserInfoTransfers.count > 5
guard budgetExhausted || queueDeep else { return }

let ctx: [String: Any] = [
    WatchMessageKeys.watchState: complicationMessage,
    "context_updated_at": Date().timeIntervalSince1970
]
debug(.watchManager, "📦 context_attempted budget_exhausted=\(budgetExhausted) queue_depth=\(session.outstandingUserInfoTransfers.count)")
do {
    try session.updateApplicationContext(ctx)
    debug(.watchManager, "📦 context_succeeded reading_epoch=\(readingEpoch)")
} catch {
    debug(.watchManager, "📦 context_failed context_update_failed=true error=\(error)")
}
```

> **Readiness-first ordering:** `sessionIsReadyForTransfer()` is checked before reading `remainingComplicationUserInfoTransfers` or `outstandingUserInfoTransfers`. These WCSession properties are technically readable regardless of activation state, but gating on readiness first avoids acting on potentially stale session state and keeps the structure consistent with the existing transfer paths in `sendDataToWatch`.

> **Rationale for conditional gate:** Writing `applicationContext` on every send during normal operation would add serialization work on every cycle before R2 has reduced the send rate. The gate activates precisely when it's needed — during exhaustion or when the fallback queue is backed up — and is dormant during normal operation. Can be made always-on later once R2 has tamed the send rate.

> **`context_attempted` / `context_succeeded` split:** These two log fields enable a BetterStack query to confirm the safety net is actually arming and delivering (not silently skipped due to activation state). Use `context_attempted - context_succeeded` as the failure rate metric.

### Watch app extension side

Add (or confirm) `didReceiveApplicationContext` in watch-side `WatchState.swift`:

> **R5d integration dependency:** The full handler (with `lastDataReceivedAt` and `forceWidgetReloadIfStale`) requires R5d (Step 6). The simplified version below is the standalone R4 handler — implement it if shipping R4 independently. When R5d ships, the handler is extended with the three-constraint ordering (shown in [observability-design.md §R5d](../observability/observability-design.md)).

```swift
// Standalone R4 handler (no R5d integration):
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { await WatchLogger.shared.log("📦 didReceiveApplicationContext") }
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else {
        return
    }
    // Reuse existing save path — saveOnMain (FP-Phase 3.1) handles dedup automatically:
    DispatchQueue.main.async { [weak self] in
        self?.saveComplicationSnapshot(from: payload)
    }
}
```

> **⚠️ Logging pattern:** Watch-side code (`WatchState.swift`) uses `Task { await WatchLogger.shared.log(...) }`, not `debug(.watchManager, ...)`. The `debug(.watchManager, ...)` pattern is iOS-side only (`AppleWatchManager.swift`).

The `saveOnMain` dedup gate (FP-Phase 3.1) will silently drop the write if the fingerprint matches an already-saved snapshot — no double-save risk.

### Risks

| Risk | Mitigation |
|---|---|
| Payload > 65 KB | R3 stripped payload is ~200–400 bytes — well within limit |
| Session not activated | Guard with `sessionIsReadyForTransfer()` (all three conditions) |
| `didReceiveApplicationContext` already implemented | Confirm with Prompt R4b before adding |
| Watch extension not running at delivery time | watchOS delivers on next extension wake; acceptable |
| Duplicate save with `didReceiveUserInfo` | `saveOnMain` dedup (FP-Phase 3.1) handles this transparently |

### R4 validation

Validation requires correlation across three signals — freshness improvement alone is suggestive but not sufficient to prove the `applicationContext` path is responsible.

- **Signal 1 — iOS sends:** `context_succeeded` events during `budget_exhausted=true` windows. Query: `msg LIKE '%context_succeeded%'` filtered to exhaustion hours.
- **Signal 2 — Watch receives:** `didReceiveApplicationContext` log events on the watch side. Query: `msg LIKE '%didReceiveApplicationContext%'`.
- **Signal 3 — Freshness improvement:** `save_age` distribution during `budget_exhausted=true` hours, compared to pre-R4 baseline.
- **Pass:** All three signals present, and `save_age` p90 < 300s during exhaustion windows.
- **Falsified if:** `save_age` unchanged during exhaustion despite `context_succeeded` events on iOS → watch app extension not receiving context, or `saveComplicationSnapshot` not being called from `didReceiveApplicationContext`. Also falsified if `context_succeeded` events are absent → R4 gate or readiness check is preventing sends.

### Post-build-146 follow-up — connectivity background-task completion policy

**Status:** First-pass terminal-path alignment shipped in build 146. Production logs showed partial improvement but the user-visible 5-second dismissal persisted. The second-pass follow-up (canonical late marker, bounded deferred-completion retries, added telemetry) is **present in production logs** as of Better Stack queries on **2026-04-06** — see [implementation log — production snapshot](alternative-delivery-implementation-log.md#better-stack--production-snapshot-queried-2026-04-06). Residual `late_task_late_task` lines remain low-volume but non-zero; UX and timeout-ratio vs build 146 still need explicit on-device / pinned-build comparison.

The original R4 design was still correct about `applicationContext` being a valid parallel delivery channel, but build-146 production behavior showed that lifecycle handling was only partially fixed:

1. **Early completion paths do run.**
   - `path=fast`
   - `path=application_context`
   - `..._late_task`
2. **`path=timeout` still dominates many wakes.**
   - the background task often still lives until the 5-second watchdog
3. **Deferred completions were too passive.**
   - `complication_bgtask_completion_deferred ... pending_content=true` had no follow-up path except another terminal call or timeout
4. **A real marker bug existed.**
   - `fast_late_task_late_task` proved the late-task suffix was stacking instead of reusing a canonical base marker

The current follow-up extends the watch-side terminal-point model:

1. **Successful terminal paths may still leave a short-lived rescue marker even when no connectivity task is pending yet.**
   - valid `didReceiveUserInfo` finalize path
   - valid `didReceiveApplicationContext` path
   - valid finalize path carrying a connectivity completion token
2. **Late rescue now uses a canonical base path.**
   - trailing `_late_task` segments are stripped before the marker is stored
   - rescue appends `_late_task` only once
3. **The rescue window is now 2 seconds, not 1 second.**
4. **Guarded failure / dedup / outdated paths remain conservative.**
   - invalid payload
   - pre-dispatch dedup
   - outdated watch-state payload
   - malformed message path
5. **Deferred completion now retries before falling through to timeout.**
   - if `hasContentPending == true` and tasks are pending, watch-side code schedules a bounded main-thread retry loop
   - exponential backoff starts at 0.2s, caps at 1.0s, and stops after a 4-second total budget
6. **Main-thread safety and telemetry were tightened.**
   - `scheduleUIUpdate` re-enters on main before touching lifecycle helpers
   - logs now distinguish terminal markers, finalize-with-no-pending-tasks, and retry lifecycle events
7. **`setTaskCompletedWithSnapshot(false)` remains unchanged.**

#### Why `hasContentPending` remains the correct late-rescue gate

Even when a valid terminal marker exists, immediate completion is still allowed only when `WCSession` no longer reports pending content.

This is the correct choice because:

- A valid `applicationContext` terminal event does **not** prove that queued `transferUserInfo` complication payloads have drained.
- Completing a late-arriving connectivity task while queued content still exists can recreate the original failure mode: the extension may be suspended before the remaining watch-state delivery for that wake is processed.
- In this codebase, the session also carries other `transferUserInfo` traffic (`watchLogConfirm`, watch-log delivery). That makes `hasContentPending` **coarse**, but a conservative false negative is safer than an aggressive false positive.

The current compromise is therefore:

- keep `hasContentPending` as the correctness gate
- add a bounded retry loop so short-lived pending-content drains can complete without waiting for the full 5-second watchdog
- still fall back to timeout if `hasContentPending` remains true through the retry budget

#### Tradeoff accepted

- **Pros:** prevents over-completing a connectivity wake that still has buffered content while reducing timeout-only completions caused by quickly draining session content.
- **Cons:** some wakes may still fall through to the 5-second fallback if unrelated session traffic keeps `hasContentPending` true past the retry budget.

#### Deferred refinement

A watch-state-specific pending-work tracker was considered and rejected for this staged change. It would be a larger lifecycle addition, not a small instrumentation tweak, because `WCSession` does not expose queue contents by semantic type. The design decision is to ship the smaller terminal-marker + conservative late-rescue fix first, then revisit a richer tracker only if post-deploy telemetry shows `hasContentPending` is too coarse and `path=timeout` remains materially elevated for non-watch-state reasons.

---

## R6 — HealthKit Background Delivery (Step 7)

**Priority:** P2 | **Effort:** Medium (~4–6 hrs including entitlement provisioning)

**Ship order (historical):** R6 shipped before R4 (build 140, 2026-03-14) — see §Decision Gate. Rationale at the time: R4 would have done nothing for the 24-minute gap observed prior to build 140 because the data was already in the App Group and the problem was WidgetKit not calling `getTimeline`. R6 gives an independent system-triggered wake that fires when new glucose data arrives in HealthKit, giving the watch extension an additional opportunity to call `reloadTimelines`. R4 shipped later in build 142 (2026-03-18) and was validated.

R6 addresses two distinct failure modes:
1. **Budget-exhaustion staleness:** When `complication_transfer_remaining=0`, WatchConnectivity complication transfers stop. R4's `updateApplicationContext` partially mitigates this but is still a WCSession-dependent channel.
2. **WidgetKit scheduling gaps:** Observed in build 139 — 9-minute gap (05:32–05:41 UTC) where fresh data existed in the App Group but WidgetKit did not call `getTimeline`, resulting in `reload_age=548s`. This occurs even when budget is healthy and data is fresh. R6's `HKObserverQuery` provides an independent wake trigger that fires specifically when new glucose data exists, giving the watch extension an opportunity to call `reloadTimelines` outside of WidgetKit's own scheduling.

### Architecture Summary

HealthKit provides a completely independent data delivery channel from WatchConnectivity. When the iPhone Trio app writes a blood glucose `HKQuantitySample` to HealthKit (`HealthKitManager.swift` line 205, `healthKitStore.save(glucoseSamples)`), Apple syncs the sample to the paired watch's HealthKit store. The watch extension registers an `HKObserverQuery` for `.bloodGlucose` with `enableBackgroundDelivery(for:frequency:.immediate)`, which causes the system to wake the extension via a background delivery task when new samples arrive. Inside the observer callback, the extension queries the latest 2 samples, constructs a `TrioComplicationSnapshot` (glucose value + derived delta), and calls the existing `TrioComplicationDataStore.shared.save()` path. This channel operates entirely outside of WatchConnectivity — it does not depend on `WCSession` activation state, complication transfer budget, or `sendMessage` reachability.

### What's Available in HealthKit vs What Must Be Derived

**Codebase audit (2026-03-14):** The HealthKit write in `BaseHealthKitManager.uploadGlucose(_:)` (`Trio/Sources/Services/HealthKit/HealthKitManager.swift` lines 182–205) constructs `HKQuantitySample` with:

| Field | HealthKit source | Available on watch? | Notes |
|---|---|---|---|
| Glucose value | `HKQuantitySample.quantity` (unit: `.milligramsPerDeciliter`) | ✅ Yes | Convert `doubleValue(for: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)))` → display string via `String(Int(value.rounded()))`. **Note:** `.milligramsPerDeciliter()` is a LoopKit extension unavailable on watchOS (build 140 confirmed) — use the inline unit construction. |
| Reading timestamp | `HKQuantitySample.startDate` | ✅ Yes | CGM reading time — use as `readingDate` in `TrioComplicationSnapshot` |
| Trend arrow | Not in metadata | ❌ No | Metadata contains only `HKMetadataKeyExternalUUID`, `HKMetadataKeySyncIdentifier`, `HKMetadataKeySyncVersion`, and `AppleHealthConfig.TrioInsulinType`. Must be derived or set to `""` |
| Delta | Not in metadata; derivable from query | ❌ / ✅ Derivable | Query last 2 `bloodGlucose` samples: `latest.quantity - previous.quantity`. Low complexity (~10 lines) |
| Glucose color | Requires user settings context | ❌ No | Needs threshold settings not available in HealthKit. Pass `nil` — `glucoseColor` is optional in `TrioComplicationSnapshot` |

**Trend derivation options:**

1. **Simple delta-based mapping:** Map delta magnitude per interval to an arrow (e.g., |Δ| < 1 → "→", 1–2 → "↗"/"↘", 2–3 → "↑"/"↓", >3 → "↑↑"/"↓↓"). Approximates the CGM's native trend but may diverge for sensors using proprietary smoothing (G7, Libre 3).
2. **Fallback to empty string:** Pass `""` for trend. The complication displays glucose + delta but omits the arrow. Strictly better than stale data from an exhausted WatchConnectivity channel.
3. **Recommended:** Option 2 initially. Add delta-based trend derivation as R6.1 (shipped build 141 — see [healthkit-improvements-design.md](../healthkit-improvements/healthkit-improvements-design.md)). Log `hk_trend_derived=false` so BetterStack can track the channel's display fidelity vs WatchConnectivity deliveries.

### iPhone Side Changes

**None required for basic functionality.** The existing HealthKit write (`healthKitStore.save(glucoseSamples)` at line 205) already produces `HKQuantitySample` objects with `.bloodGlucose` type, `.milligramsPerDeciliter` unit, and sufficient metadata for the watch to identify samples.

**Optional enhancement (defer to R6.1):** Add trend metadata to HealthKit writes:
```swift
// In uploadGlucose(_:), add to metadata dict:
"com.trio.trend": glucoseSample.direction?.rawValue ?? ""
```
This would avoid trend derivation on the watch but changes the HealthKit write contract. Verify existing HealthKit consumers (Tidepool, third-party apps reading Trio's BG samples) are unaffected before shipping. Defer unless trend derivation proves unreliable in practice.

### Watch Side Implementation

**R6a — `enableBackgroundDelivery` registration:**

Must be called on every app launch — registration does not persist across process restarts. Place at the **end of `setupSession()`**, **outside** the `if WCSession.isSupported()` block. HK setup is independent of WatchConnectivity — gating it on `isSupported()` would prevent background delivery on devices where WCSession is unavailable or fails, even though HealthKit works independently. Idempotent; re-registering is safe. (CR1 from build 140 code review: moving this call outside `if WCSession.isSupported()` was a required fix.)

```swift
// In WatchState, during initialization (setupSession or init):
private func setupHealthKitBackgroundDelivery() {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    let store = HKHealthStore()
    guard let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return }

    store.requestAuthorization(toShare: nil, read: Set([bgType])) { [weak self] granted, error in
        guard let self else { return }
        guard granted, error == nil else {
            debug(.watchManager, "❌ hk_authorization_failed granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
            return
        }

        store.enableBackgroundDelivery(for: bgType, frequency: .immediate) { success, error in
            if let error = error {
                debug(.watchManager, "❌ hk_background_delivery_registration_failed error=\(error.localizedDescription)")
            } else {
                debug(.watchManager, "✅ hk_background_delivery_registered success=\(success)")
            }
        }

        self.setupGlucoseObserverQuery(store: store, sampleType: bgType)
    }
}
```

**R6b — `HKObserverQuery` setup:**

Long-lived observer query for `.bloodGlucose`. The update handler fires each time HealthKit's sample database changes for that type, including cross-device sync from iPhone. *Code review note:* `setupGlucoseObserverQuery` assigns `self.healthKitStore` and executes the query from inside the authorization callback (arbitrary background thread). In practice this is fine — setup runs once at launch before concurrent access — but confirm `WatchState` has no conflicting access patterns on those properties.

```swift
private var healthKitStore: HKHealthStore?
private var glucoseObserverQuery: HKObserverQuery?

private func setupGlucoseObserverQuery(store: HKHealthStore, sampleType: HKQuantityType) {
    self.healthKitStore = store
    let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
        [weak self] _, completionHandler, error in
        guard error == nil else {
            debug(.watchManager, "❌ hk_observer_error error=\(error!.localizedDescription)")
            completionHandler()
            return
        }
        // CR2 (required): guard self before use — if self is nil, completionHandler()
        // must still be called or the system will throttle future background deliveries.
        guard let self else { completionHandler(); return }
        self.fetchLatestGlucoseFromHealthKit(completionHandler: completionHandler)
    }
    store.execute(query)
    self.glucoseObserverQuery = query
}
```

**R6c — Sample fetch inside observer callback:**

Fetch the latest 2 blood glucose samples (current value + delta derivation). `completionHandler` must be called on all code paths. On the success path, call it **inside** `DispatchQueue.main.async` after the save — not via `defer` at closure exit (see R6d).

```swift
private func fetchLatestGlucoseFromHealthKit(completionHandler: @escaping () -> Void) {
    guard let store = healthKitStore,
          let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
        completionHandler()
        return
    }

    let query = HKSampleQuery(
        sampleType: bgType,
        predicate: nil,
        limit: 2,
        sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)]
        // ⚠️ HKSampleQuery requires [NSSortDescriptor]? — Swift SortDescriptor does NOT bridge here.
        // Use keyPath API (non-deprecated). Do NOT use HKSampleSortIdentifierStartDate (deprecated).
    ) { _, results, error in
        if let error = error {
            // log hk_observer_sample_query_error
            completionHandler()
            return
        }
        guard let samples = results as? [HKQuantitySample],
              let latest = samples.first else {
            // log hk_observer_sample_query_zero_samples
            completionHandler()
            return
        }

        // ⚠️ .milligramsPerDeciliter() is a LoopKit extension unavailable on watchOS.
        // Use the inline unit construction instead (confirmed by build 140 compile failure):
        let mgDlUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        let mgDl = latest.quantity.doubleValue(for: mgDlUnit)
        let readingDate = latest.startDate
        let glucoseString = String(Int(mgDl.rounded()))
        var deltaString = "--"
        if samples.count >= 2 {
            let prevMgDl = samples[1].quantity.doubleValue(for: mgDlUnit)
            deltaString = String(format: "%+.0f", mgDl - prevMgDl)
        }
        let saveAge = Int(Date().timeIntervalSince(readingDate))
        // log hk_observer_fired

        let snapshot = TrioComplicationSnapshot(
            glucose: glucoseString,
            trend: "",
            delta: deltaString,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: nil
        )

        DispatchQueue.main.async {
            TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)
            completionHandler()
        }
    }
    store.execute(query)
}
```

**R6d — `completionHandler()` requirement:**

The `completionHandler` passed to the `HKObserverQuery` update handler **must** be called when processing is complete. Failure to call it causes the system to throttle or stop waking the extension for future updates. Call it **after** the work is done: on the success path, invoke `completionHandler()` inside the `DispatchQueue.main.async { ... }` block, after `TrioComplicationDataStore.shared.save(...)`. Do not use `defer { completionHandler() }` at HKSampleQuery closure exit — that would signal "done" before the async save runs. On error or zero-samples paths, call `completionHandler()` before returning.

### Entitlement and Info.plist Requirements

HealthKit with background delivery is already enabled on the Trio WatchKit Extension App ID in the Apple Developer portal. Add the following to the project entitlements file:

| Entitlement key | Required value | Current status | File to modify |
|---|---|---|---|
| `com.apple.developer.healthkit` | `true` | ✅ Already present in provisioning profile | `Trio Watch App/TrioWatchApp.entitlements` |
| `com.apple.developer.healthkit.background-delivery` | `true` | ✅ Already present in provisioning profile | `Trio Watch App/TrioWatchApp.entitlements` |

Add the keys to `Trio Watch App/TrioWatchApp.entitlements` (e.g. via Xcode → Signing & Capabilities → + HealthKit with "Background Delivery" checked). Entitlements file addition only required — no provisioning profile update needed.

**Privacy usage description (required):** The watch app calls `requestAuthorization(toShare: nil, read:)`, so `NSHealthShareUsageDescription` **must** be present in the watch app's `Info.plist`. Without it, the authorization request may crash the process at runtime or fail silently — and since `setupHealthKitBackgroundDelivery()` runs on every app launch, this would break the entire watch app. Add to `Trio Watch App/Info.plist`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable.</string>
```

`NSHealthUpdateUsageDescription` is also **required by App Store Connect validation** — Apple's altool rejects uploads that have the `com.apple.developer.healthkit` entitlement but are missing this key, regardless of `toShare: nil`. Build 140 confirmed this (ITMS-90683). Despite the read-only authorization intent, both usage description keys must be present. **Fixed in v1.35.**

**For reference — main app entitlements (already present):** `Trio/Resources/Trio.entitlements` has both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` = `true`, and `Trio/Resources/Info.plist` has both `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`.

**Watch Complication** (`Trio Watch Complication/TrioWatchComplication.entitlements`): Does NOT need HealthKit entitlements — it reads via the App Group shared container, not HealthKit directly.

### Dedup and Dual-Delivery Behavior

`saveOnMain` (FP-Phase 3.1) in `TrioComplicationDataStore` gates all saves through `shouldUpdate(new:current:)` — which compares `readingDate` (±1s tolerance) and display fields (`glucose`, `trend`, `delta`, `state`). Only snapshots that are newer or have different display content pass through.

**For the same CGM reading arriving via both channels:** The HealthKit-derived snapshot has `trend=""` and a numerically-derived `delta`, while the WatchConnectivity snapshot has the iPhone-computed trend and delta. Since `trend` differs (`""` ≠ `"↗"`), `shouldUpdate` returns `true` — the HK snapshot is **not** rejected as a duplicate. Both writes are accepted by `saveOnMain`.

**Practical consequence in normal operation (both channels active):** WatchConnectivity typically delivers first (lower latency). The HK delivery arrives 10–60s later, passes `shouldUpdate` (trend differs), and overwrites the WC snapshot with `trend=""`. The complication shows correct glucose + delta but loses the trend arrow until the next WC delivery (~5 min). This is acceptable because:
- The trend arrow is the least critical display field — glucose value and delta are correct
- The loss is transient (restored on the next CGM interval's WC delivery)
- The overwrite also triggers a `coalescedReloadOnMain(minInterval: 5)` call; since 10–60s > 5s, the reload is not debounced — WidgetKit gets a second reload request, which may help in WidgetKit scheduling gap scenarios

**In target scenarios (budget exhaustion, WidgetKit scheduling gaps):** WC is not delivering, so HK is the only channel. No overwrite, no trend regression. The `trend=""` is strictly better than stale data or no update at all.

**Reload conditions:** `save(snapshot, minInterval: 5)` triggers a `coalescedReloadOnMain` call only when (a) the snapshot passes `saveOnMain` dedup, and (b) 5+ seconds have elapsed since the last reload. In the target scenarios, both conditions are typically met because no prior delivery has occurred recently.

No additional dedup logic is needed in the HealthKit observer. The overwrite is benign in normal operation and beneficial in target scenarios.

### Risks

| Risk | Severity | Mitigation |
|---|---|---|
| HealthKit entitlements missing from watch extension entitlements file | **Blocker** | Add `com.apple.developer.healthkit` + `com.apple.developer.healthkit.background-delivery` to `TrioWatchApp.entitlements` (provisioning profile already has HealthKit enabled for watch extension App ID) |
| `NSHealthShareUsageDescription` missing from watch app `Info.plist` | **Blocker** | The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires the read usage description in the requesting process's `Info.plist`. Without it, authorization may crash on launch or fail silently. Add to `Trio Watch App/Info.plist`. `NSHealthUpdateUsageDescription` is also required — App Store Connect rejects uploads with the HealthKit entitlement but missing this key, regardless of `toShare: nil` (ITMS-90683; confirmed by build 140). **Both fixed in v1.35.** |
| Trend not in HealthKit metadata (derivation complexity) | Medium | Ship with `trend=""` initially. Complication shows glucose + delta. Delta-based trend derivation shipped in R6.1 (build 141). |
| HealthKit sync latency not Apple-SLA'd | Medium | Sync depends on Bluetooth proximity and system scheduling. Expect 10–60s in typical conditions, potentially minutes. HealthKit is supplementary to WatchConnectivity, not a replacement |
| `enableBackgroundDelivery` not re-registered after crash/restart | Medium | Call `setupHealthKitBackgroundDelivery()` in `WatchState.init()` / `setupSession()` on every launch. Registration is idempotent |
| `completionHandler` not called (system penalizes app) | High | Call on all paths: error/zero-samples paths before return; success path inside `DispatchQueue.main.async` after save. Do not use `defer` at closure exit — that signals "done" before the async save runs. |
| HealthKit read authorization denied by user | Medium | Watch must request read authorization for `.bloodGlucose`. If denied, observer never fires. Log `hk_authorization_failed`. Falls back to WatchConnectivity-only — no regression |
| Trend arrow overwrite in normal operation | Low | HK snapshot (`trend=""`) overwrites WC snapshot's real trend when both channels deliver same reading. Transient — restored on next WC delivery (~5 min). Glucose and delta remain correct. Mitigated by R6.1 trend derivation (build 141) — HK snapshots now include derived trend, reducing overwrite regression. |
| Battery impact from observer wakeups | Low | Observer fires only when new BG samples sync (~every 5 min for most CGMs). Per-wakeup cost is trivial: 1 sample query + 1 snapshot save + 1 App Group write |

### Validation

**BetterStack query — confirm the new channel delivers during budget exhaustion:**

```sql
SELECT
    dt,
    JSONExtract(raw, 'message', 'Nullable(String)') AS msg
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 24 HOUR
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%hk_observer_fired%'
ORDER BY dt DESC
LIMIT 50
```

**Cross-channel comparison in exhaustion windows:**

```sql
SELECT
    toStartOfHour(dt) AS hour,
    countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%hk_observer_fired%') AS hk_deliveries,
    countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%budget_exhausted=true%') AS exhaustion_events
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour DESC
```

**Pass conditions (two distinct failure modes):**
1. **Budget exhaustion:** During hours where `complication_transfer_remaining=0`, `hk_observer_fired` events should continue to appear — confirms HealthKit delivers when WatchConnectivity budget is exhausted. **Latency in logs:** build 140 R6 used `save_age=`; build **141+** (R6.1) renames the same metric to **`sync_lag=`** (`now - readingDate`). Do not treat a single global p90 threshold as a hard gate — bootstrap / catch-up fires (`query_type=sampleQuery_bootstrap`, large `samples_in_batch`) inflate tails; segment before judging steady-state behavior.
2. **WidgetKit scheduling gaps:** `reload_age` p90 < 300s overall (not just exhaustion windows). The `hk_observer_fired` → `reloadTimelines` path provides an independent wake trigger that should reduce gaps where fresh data sits in the App Group unread.

**Structured log event (`hk_observer_fired`):** Build 140: `reading_epoch=X save_age=Y glucose=…`. Build 141+: adds `sync_lag=`, `query_type=`, `trend_derived=`, `samples_in_batch=`, etc. — distinguishable from WatchConnectivity via `msg LIKE '%hk_observer_fired%'` vs `msg LIKE '%didReceiveUserInfo%'` or `msg LIKE '%didReceiveMessage%'`.

### Decision Gate

**Actual ship order:** R6 shipped before R4 (build 140, 2026-03-14). R4 shipped in build 142 (2026-03-18), validated. The originally documented ordering ("Ship R6 after R4") was reversed — see [implementation log](alternative-delivery-implementation-log.md) for the build-by-build record.

Primary motivation for R6 was twofold:
1. **Budget-exhaustion windows:** HealthKit provides a WCSession-independent delivery channel when `complication_transfer_remaining=0`.
2. **WidgetKit scheduling gaps:** Observed in build 139 — 9-minute gap with fresh App Group data, `reload_age=548s`. The `HKObserverQuery` wake trigger fires when new glucose data arrives in HealthKit, giving the watch extension an independent opportunity to call `reloadTimelines`. This addresses a failure mode that R4 cannot fix (R4 still depends on WidgetKit's scheduling to pick up App Group writes).

Do not gate R6 on budget-exhaustion metrics alone. The two failure modes are distinct — R4 addresses the data delivery gap during exhaustion, R6 addresses WidgetKit's scheduling latency via an independent wake trigger.

---

## Cursor Audit Round 2 — R4 and R6 Findings

All four prompts answered 2026-03-09. No open questions remained. Both R4 and R6 have since shipped — see status at top of this document.

---

**R4b — `didReceiveApplicationContext` status:** ✅ Implemented (build 142, commit `5ba994fcb`).

*(Pre-implementation audit finding preserved for reference:)* Method was absent from `WatchState.swift` at time of audit. Added as `session(_:didReceiveApplicationContext:)` after `sessionReachabilityDidChange` (~line 633). Purely additive — no conflict with existing code.

---

**R5d-kind — Widget kind string: `"TrioWatchComplication"`**

Defined at `Trio Watch Shared/TrioComplicationDataStore.swift` line 147: `static let complicationKind = "TrioWatchComplication"`. One widget only (the preview file has a `PreviewProvider`, not a `Widget`).

**Impact on R5d:** Replace `WidgetCenter.shared.reloadAllTimelines()` with `WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)`. Use the constant, not the string literal.

---

**R5d-snapshot — `latestSnapshot()` thread safety**

Does synchronous file I/O: reads `snapshot.json` (~200 bytes) from App Group container via `Data(contentsOf:)` + `JSONDecoder().decode()`. Falls back to `snapshot.bak` on failure. Designed to be called from any thread (used by both watch app and WidgetKit extension). Not annotated as main-thread-only.

Verdict: **safe to call as written in R5d**. The I/O cost for a 200-byte file is negligible (sub-millisecond), it's already multi-thread-safe in production, and the only dispatch hazard (`onMain {}` for `lastValidTimestamp`) only fires on the fallback code path when `appGroupDefaults` is nil. No background queue needed.

CGM reading timestamp property: **`readingDate: Date`** (distinct from `date: Date` which is the snapshot creation time).

**Impact on R5d:** `latestSnapshot()` can be called on main as written. Replace `$0.readingDate` references accordingly — confirmed correct.

---

**R5f-getTimeline — Entry type and reading date field**

`TimelineEntry` type: `TrioWatchComplicationEntry` (defined lines 12–37). Has `readingDate: Date` (CGM reading time) and `date: Date` (WidgetKit display time — distinct). In `getTimeline`, all 30 entries share the same `readingDate` from the snapshot; `date` advances by 1 minute per entry.

**Impact on R5f:** Add to `getTimeline` after building entries:
```swift
if let firstEntry = entries.first {
    debug(.complication, "📅 timeline_built entry_count=\(entries.count) reading_epoch=\(Int(firstEntry.readingDate.timeIntervalSince1970)) snapshot_age=\(Int(Date().timeIntervalSince(firstEntry.readingDate)))s")
}
```
This debug line emits **`reading_epoch`** and **`snapshot_age`** (informal) at timeline-build time — confirms WidgetKit is picking up fresh App Group data. There is **no** separate log field named `timeline_entry_epoch` (that phrase was design-only; see `build-144-plan.md` / `observability-design.md`). The structured R5f event **`event=complication_get_timeline_called`** should include `get_timeline_at_epoch_seconds` and **`data_age_seconds`** per §R5f above. R5f also specifies `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` and `data_age_seconds` for the getSnapshot path — see §R5f for both entry-path specs.

---

## Changelog

### v1.4 (2026-04-08 22:26 CET)
- **R5f-getTimeline:** Clarified naming: debug line uses `reading_epoch` / `snapshot_age`; structured metrics use `data_age_seconds`, not a field called `timeline_entry_epoch`.
- Reason: align with shipped logging and `validation-protocol.md` / `build-144-plan.md`.

### v1.3 (2026-04-06 17:27 CET)
- Status: second-pass watch connectivity follow-up is no longer “pending redeploy” — production Better Stack snapshot recorded in the implementation log. Updated §Validation for R6 / R6.1: `save_age` vs `sync_lag` rename, tail segmentation note, and relaxed wording on using a single p90 as a hard gate for HK lag.

### v1.2 (2026-03-30 22:46 CEST)
- Updated the post-build-143 follow-up into a post-build-146 design note. Recorded that build 146 only partially improved task completion, documented the canonical late-task marker fix, the bounded deferred-completion retry policy (0.2s exponential backoff, 1s cap, 4s budget), the widened 2-second rescue window, and the decision to keep `hasContentPending` as the correctness gate while still deferring a watch-state-specific pending-work tracker.

### v1.1 (2026-03-30)
- Added staged post-build-143 follow-up section documenting the connectivity background-task completion policy for R4/R5d integration. Captured the terminal-marker design, the decision to keep late-task rescue gated by `hasContentPending`, the explicit tradeoff accepted, and the deferral of watch-state-specific pending-work tracking until post-deploy telemetry justifies it.

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted R4 and R6 design sections from `complication-freshness-remediation-plan.md` and Cursor Audit Round 2 findings into a standalone alternative-delivery design document. R4 status updated to COMPLETED (build 142, validated). Reason: docs reorganization — group related alternative delivery channel content for easier navigation and maintenance.
