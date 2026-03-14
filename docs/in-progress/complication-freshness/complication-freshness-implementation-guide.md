# Cursor Round 2: Audit Results + Implementation Guide
**Version:** 1.21 | **Date:** 2026-03-14
**Prerequisite:** `complication-freshness-remediation-plan.md` v1.35 — all prompts resolved, plan is implementation-ready

---

**Step ↔ Plan mapping:** Step 5 = R4 (applicationContext safety net). Step 7 = R6 (HealthKit background delivery).

---

## Part 1 — Cursor Audit Round 2: Resolved Findings

All four prompts answered. Key facts for implementation:

| Question | Answer |
|---|---|
| `didReceiveApplicationContext` exists? | **No** — purely additive; add after `sessionReachabilityDidChange` (~line 403) in `WatchState.swift` |
| Widget kind string | **`TrioComplicationDataStore.complicationKind`** (= `"TrioWatchComplication"`) — use constant, not literal |
| `latestSnapshot()` safe on main? | **Yes** — does synchronous I/O (~200 bytes), but negligible; already multi-thread-safe in production |
| CGM timestamp property name | **`readingDate: Date`** on `TrioComplicationSnapshot` (distinct from `date: Date` = snapshot creation time) |
| Timeline entry type | `TrioWatchComplicationEntry` — has `readingDate` (CGM time) and `date` (WidgetKit display time) |

No further Cursor prompts needed. Proceed to implementation.

---

## Part 2 — Implementation Steps

Ship in this exact sequence. Each step is a PR unless noted. Do not rearrange.

**Sequencing (Step 5 vs Step 7):** Based on observed data (e.g. 24-minute gap with fresh App Group data, WidgetKit not calling `getTimeline`), **go straight to Step 7 (R6)**. R4 (Step 5) would have done nothing for that gap — the data was already in the App Group; the problem was WidgetKit not calling `getTimeline`. R4 sends more data via another WatchConnectivity channel but still ends with a `reloadTimelines` call that WidgetKit can ignore just as freely. R6 (Step 7) gives an independent system-triggered wake that fires when new glucose data arrives in HealthKit; each wake is another `reloadTimelines` call from a fresh background task context (e.g. during a 9-minute gap, R6 would have fired at least once from the next reading). R4 still has real value — it covers the budget-exhaustion failure mode that R6 doesn't help with — but it's lower urgency right now. You can ship R4 after R6, or bundle both in the same PR (they're complementary and touch different files: `AppleWatchManager.swift` for R4, `WatchState.swift` for R6).

---

### Step 1 — PR: R1a + R1b + R5e — COMPLETED (build 132, 2026-03-09)

**Files:** `WatchMessageKeys.swift`, `AppleWatchManager.swift`, BetterStack (alert config)

**What to implement:**

**R1a — Add keys to `WatchMessageKeys.swift`:**
```swift
static let readingEpoch = "reading_epoch"             // CGM reading timestamp as TimeInterval
static let transferEnqueuedAt = "transfer_enqueued_at" // wall time of transfer enqueue
```
In `watchStateToDictionary`: add `readingEpoch` using `state.glucoseValues.max(by: { $0.date < $1.date })?.date.timeIntervalSince1970` — use `max(by: date)`, not `.first`, to avoid sorted-order assumption.
In `sendDataToWatch`: stamp `transferEnqueuedAt = Date().timeIntervalSince1970` immediately before transfer calls.

**R1b — Add to `AppleWatchManager.swift`:**

New properties on `BaseWatchManager`:
- `hasPerformedStartupQueueDrain: Bool = false`
- `lastQueueDeepDrainAt: TimeInterval = 0`

New shared helpers (add near top of file, before `sendDataToWatch`):
```swift
private func sessionIsReadyForTransfer() -> Bool {
    guard let session = self.session else { return false }
    return session.activationState == .activated
        && session.isPaired
        && session.isWatchAppInstalled
}

private func cancelStaleQueuedTransfers() {
    guard sessionIsReadyForTransfer() else { /* log and return */ return }
    // Keep exactly 1 transfer: newest by transferEnqueuedAt within latest readingEpoch.
    // Full pseudocode in plan §R1b.
}
```

Call sites (see plan §R1b for full pseudocode):
1. `session(_:activationDidCompleteWith:)` — one-time startup drain
2. `sendDataToWatch` — in `budget_exhausted` branch, before `transferUserInfo`
3. `sendDataToWatch` — queue-deep path: guard `sessionIsReadyForTransfer()` first, then `if queue_depth > 5 && cooldown_elapsed { drain() }`

**R5e — BetterStack alert:** Create alert on query: `budget_exhausted=true AND via=userInfo > 5 in 30 min`. Warning severity. (SQL in plan §R5e.)

> ## ✅ GATE PASSED (build 132, 2026-03-09)
> - Code reviewed: `cancelStaleQueuedTransfers` logic, `sessionIsReadyForTransfer` guards, `readingEpoch` uses `max(by: date)` — all verified
> - Build 132 deployed to TestFlight
> - BetterStack confirmed: queue drained from 45 to 1 in first pass (`cancel_requested=44`), steady-state `queue_depth=2`
> - R5e alert configured in BetterStack UI
> - Observing 24h before Step 2

---

### Step 2 — PR: R2a + R3 — COMPLETED (build 133, 2026-03-10)

**Files:** `AppleWatchManager.swift`, `WatchMessageKeys.swift`, `Trio Watch App Extension/WatchState.swift` (R3 watch side)

**What to implement:**

**R2a — Modify `scheduleWatchStateUpdate`:**
- Add `source: String = "unknown"` parameter
- Add properties: `coalescerTriggerCount: Int`, `coalescerSources: [String]`, `lastEligibleSourceAt: TimeInterval`, `complicationEligibleSources: Set<String>` (define all now — required for R2a to compile)
- When `complicationEligibleSources.contains(source)`: update `lastEligibleSourceAt`
- In work item: snapshot all state before clearing → pass `sourcesSnapshot`, `lastEligibleSnapshot`, `windowStartEpoch: TimeInterval?` to `sendDataToWatch`
- Handle `coalescerFirstScheduledAt == nil`: pass `nil` (not a sentinel); log warning
- Update all 8 call sites with source tags (plan §R2a for the full list)

**R3 — Complication payload allowlist (requires R1a already live):**
- Build `complicationMessage` unconditionally at top of `sendDataToWatch` via explicit `if let` inserts (plan §R3 for full pseudocode)
- Use `readingEpochPresent` flag (not `guard...return`) to gate complication transfers — `sendMessage` always fires
- Log ⚠️ if `readingEpoch` absent; log at `debug` level for other missing keys
- Inline comment on `WatchMessageKeys.date`: `⚠️ BUILD TIME, not CGM reading time`
- Use `complicationMessage` for all complication budget paths; `fullMessage` for `sendMessage`

> ## ✅ GATE PASSED (build 133, 2026-03-10)
> - Code reviewed: `complicationMessage` built unconditionally from 7-key allowlist, `sendMessage` fires regardless of `readingEpochPresent`, `complicationEligibleSources` defined once
> - Post-review fixes applied: queue-deep drain moved outside reachability branches, `outstandingUserInfoTransfers.count` read inside `sessionIsReadyForTransfer()` guard, watch-side fallback warning log added, drain log includes paired/installed
> - Build 133 deployed to TestFlight
> - BetterStack confirmed: coalescer attribution logging working (trigger/fire with source tags), complication payload reduced to 7 keys (~200B), no missing-key warnings, queue depth steady at 1-2
> - Observing 24h coalescer attribution data before Step 3

---

### Step 3 — PR: R2b

**Files:** `AppleWatchManager.swift`

**What to implement:**

Add `lastDispatchedGateKey` backed by App Group `UserDefaults`.
Gate key = `"\(epoch)|\(currentGlucose)|\(trend)|\(delta)"` — use `max(by: date)` for epoch, matching R1a.
Gate skips complication transfer only — `sendMessage` always fires regardless. Log `complication_transfer_gate_skipped`.

**Design note:** Complication transfers are gated on `!session.isReachable` — this is intentional budget conservation, not an API limitation. When the watch app is foregrounded (`isReachable`), `sendMessage` updates the UI for free and the complication is not visible. `transferCurrentComplicationUserInfo` works regardless of reachability, but calling it only when not reachable avoids wasting the 50/day budget on invisible updates.

BetterStack validation query must filter `transfer_path IN ('complication', 'userInfo')` — not `attempted = true`.

> ## ✅ CODE REVIEW PASSED; Build 134 deployed; observing 48h
> - **Round 1 (Claude):** 6 points evaluated; 1 fix applied (`lastDispatchedGateKey = ""` in activation handler for budget-cycle reset); 4 confirmed correct; 1 accepted as cosmetic (log noise)
> - **Round 2 (ChatGPT): critical bug found + placement refinement** — `lastDispatchedGateKey` was written before the reachability check, so a sendMessage-only (reachable) path consumed the gate and suppressed the first background complication transfer for the same reading. **Fix:** moved gate key write to immediately after each actual enqueue call (`transferCurrentComplicationUserInfo` / `transferUserInfo`), not just inside the block — defensive against future early returns
> - Observing 48h BetterStack data (no contradiction with “build 134 deployed”)
>    - If avg C ≤ 1.3 → R2d is optional; proceed directly to Step 5
>    - If avg C > 1.3 → proceed to Step 4 (R2d)

---

### Step 3b — PR: Complication-age stale-first budget gate

**Files:** `AppleWatchManager.swift`

**What to implement:**

- **Helper:** `private func currentComplicationAgeSeconds() -> TimeInterval` — use this exact pattern (no Watch Shared import):
  - `guard let suiteName = appGroupIDCandidate().value, let defaults = UserDefaults(suiteName: suiteName) else { return .infinity }`
  - `let lastValid = defaults.object(forKey: "TrioComplication_lastValidTimestamp") as? Date`
  - `if lastValid == nil { return .infinity }`
  - `return max(0, Date().timeIntervalSince(lastValid!))`

- **Constant:** `private static let complicationAgeGateThresholdSeconds: TimeInterval = 600`

- **In `sendDataToWatch`:** After building `complicationMessage` and `gateKey`, before the complication transfer block:
  - `let complicationAgeSeconds = currentComplicationAgeSeconds()`
  - `let ageGatePassed = complicationAgeSeconds > Self.complicationAgeGateThresholdSeconds`
  - **Branching (explicit):** Under `if !session.isReachable, readingEpochPresent, !isDuplicateDispatch` only:
    - **If** `session.remainingComplicationUserInfoTransfers > 0`: apply age gate — **if** `ageGatePassed` then `transferCurrentComplicationUserInfo` (and set `lastDispatchedGateKey`); **else** log age-gate skip.
    - **Else** (budget exhausted): do **not** check age; run existing `cancelStaleQueuedTransfers()` and `transferUserInfo(...)` fallback (still subject to duplicate gate only). Do not gate the userInfo fallback.
  - **lastDispatchedGateKey rule:** `lastDispatchedGateKey` is ONLY set when a complication transfer is actually enqueued (after `transferCurrentComplicationUserInfo` OR after `transferUserInfo` fallback). Do NOT set it on sendMessage-only paths. Do NOT set it when the age gate fails. Do not reintroduce the Step 3 foreground→background suppression bug.
  - Do not gate `sendMessage` (budget-free).
  - **Skip-log taxonomy (for BetterStack):** Three queryable categories. Step 3b age-gate skip: `skip_reason=age_gate`. R2b duplicate skip: document as `skip_reason=duplicate_gate` (even if the current log line doesn’t include the literal yet). Missing readingEpoch: its own case. Queries filter by: age_gate, duplicate_gate, missing readingEpoch.
  - When transfer is skipped because complication is fresh: log `⏭️ complication_transfer_age_gate_skipped skip_reason=age_gate age_seconds=... threshold_seconds=... gate_key=...`.
  - On successful complication transfer log include: `complication_age_seconds=\(Int(complicationAgeSeconds)) complication_age_gate_threshold_seconds=\(Int(Self.complicationAgeGateThresholdSeconds))`.

**Design note:** We gate only the budget-consuming path so that the 50/day budget is spent when the complication is actually stale. `sendMessage` always fires to keep the watch app UI fresh and has no budget cost.

> ## ✅ CODE REVIEW PASSED; Step 3b deployed (builds 137-138)
> - **Code verified:** `currentComplicationAgeSeconds()` uses exact 4-step pattern (guard suite/defaults → .infinity; lastValid; if nil return .infinity; max(0, …)); no Watch Shared import. Constant `complicationAgeGateThresholdSeconds = 600`. Age gate applied only when `remaining > 0`; budget-exhausted fallback has no age gate. `lastDispatchedGateKey` set only on actual enqueue (transferCurrentComplicationUserInfo or transferUserInfo); not set on age-gate skip or sendMessage-only.
> - **Log taxonomy:** Age-gate skip logs `skip_reason=age_gate` with `age_seconds`, `threshold_seconds`, `gate_key`, `reading_date_epoch_seconds`. Success logs include `complication_age_seconds`, `complication_age_gate_threshold_seconds`.
> - **Deployed:** Step 3b included in builds 137-138 (alongside cloud logging pipeline fixes). Builds 137-138 also fix the build-mislabeling problem in `CloudLogUploader` — avg C per-build queries are now reliable. See `docs/completed/logging-fixes/`.
> - **Observation:** 48h window starts from build 137 deploy (2026-03-12). Run avg C query ~2026-03-15. If avg C <= 1.3 → skip Step 4, proceed to Step 5. If avg C > 1.3 → proceed to Step 4 (R2d).

---

### Step 4 — PR: R2d (gated on Step 3 data; implement only if avg C > 1.3)

**Files:** `AppleWatchManager.swift`

**What to implement:**
- Add `WatchSendMode` enum: `.complicationAndUI` / `.uiOnly`
- Mode selection: `eligibleThisWindow = lastEligibleSourceAt >= windowStartEpoch` with `lastEligibleSourceAt != 0` guard in clock-skew fallback
- Three-way fallback log split: `eligible_source_window_nil_fallback`, `eligible_source_clock_skew` (small delta), `eligible_source_epoch_inversion` (large delta)
- Use `sessionIsReadyForTransfer()` (not just `activationState`) in transfer guard
- Log `complication_transfer_attempted` and `transfer_path`
- Note: `complicationEligibleSources` and `lastEligibleSourceAt` already defined in Step 2 — do not redefine

**Before shipping:** Manually verify both test cases in simulator or on-device:
1. `glucoseStored` → `iobUpdate` (same 2s window) → confirm `mode=complicationAndUI`, `transfer_path=complication`
2. `iobUpdate` alone → confirm `mode=uiOnly`

> ## 🛑 STOP — Code Review + Build/Deploy
> 1. **Verify both manual test cases pass** before submitting for review
> 2. **Code review** this PR
> 3. **Build and deploy** to device
> 4. **Observe 48h** — confirm avg C/reading ≤ 1.3 in budget-ok windows

---

### Step 5 — PR: R4 (applicationContext safety net, after R3)

**Files:** `AppleWatchManager.swift`, `Trio Watch App Extension/WatchState.swift`

**R4b confirmed:** `didReceiveApplicationContext` does not exist — purely additive. Add after `sessionReachabilityDidChange` (~line 403).

**What to implement:**

iOS side (`AppleWatchManager.swift`) — at END of `sendDataToWatch`, after all transfer and `sendMessage` calls:
- Call `session.updateApplicationContext(complicationMessage)` when `budgetExhausted || queueDepth > 5`
- Guard `sessionIsReadyForTransfer()` before attempting
- Log `context_attempted`, `context_succeeded`, `context_failed`, `context_skipped` separately (all three readiness conditions in `context_skipped` log)

Watch side (`WatchState.swift`):
```swift
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else { return }
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Same three-constraint ordering as didReceiveUserInfo (plan §R5d):
        let gap = self.lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        self.saveComplicationSnapshot(from: payload)
        self.lastDataReceivedAt = Date()
        if gap > 600 {
            debug(.watchManager, "💤 sleep_gap_detected_context gap_seconds=\(Int(gap))")
            self.forceWidgetReloadIfStale(receivedGap: gap)
        }
    }
}
```

> ## 🛑 STOP — Code Review + Build/Deploy
> 1. **Code review** this PR — verify `updateApplicationContext` placement is at END of `sendDataToWatch` (not before transfer calls), `complicationMessage` is in scope, and the watch-side handler uses the three-constraint ordering
> 2. **Build and deploy** to device
> 3. **Validate during a budget exhaustion window:** `save_age` p90 should drop below 300s compared to pre-R4 baseline

---

### Step 6 — PR: R5 observability hardening (opportunistic, parallel-safe after Step 1)

**R5b:** Add `sendMessage` wall-clock timestamp on iOS send.

**R5c:** Add `decode_ms` to `didReceiveUserInfo` (receive → `saveComplicationSnapshot` return).

**R5d — Sleep-gap forced reload (`WatchState.swift`):**
- Rename `lastUserInfoReceivedAt` → `lastDataReceivedAt`; persist to App Group `UserDefaults`
- `forceWidgetReloadIfStale(receivedGap: TimeInterval)` — rate limiter (5 min), diagnostic snapshot read, gap-relative stale detection (`snapshotAge > receivedGap - 60`)
- Kind string: use `TrioComplicationDataStore.complicationKind`
- `latestSnapshot()` confirmed main-safe — call as-is; move to background queue only if `snapshot_read_ms > 20ms` in production
- Full pseudocode in plan §R5d

**R5f — Timeline validation logging (`TrioWatchComplication.swift`):**
```swift
// After entries array is built in getTimeline:
if let firstEntry = entries.first {
    debug(.complication, "📅 timeline_built entry_count=\(entries.count) reading_epoch=\(Int(firstEntry.readingDate.timeIntervalSince1970)) snapshot_age=\(Int(Date().timeIntervalSince(firstEntry.readingDate)))s")
}
```
This validates that WidgetKit is actually advancing the timeline, not just that the App Group store is fresh.

> ## 🛑 STOP — Code Review + Build/Deploy
> 1. **Code review** this PR — verify `forceWidgetReloadIfStale(receivedGap:)` signature matches all call sites, `lastDataReceivedAt` is updated in both `didReceiveUserInfo` and `didReceiveApplicationContext`, and rename is complete (no remaining `lastUserInfoReceivedAt` references)
> 2. **Build and deploy** to device
> 3. **Confirm in BetterStack:** `timeline_built snapshot_age` p90 < 600s after sleep gaps; `reload_with_stale_snapshot` events are rare

---

### Step 7 — PR: R6 (HealthKit Background Delivery)

**Decision gate:** Recommended: ship R6 before or alongside R4 (see sequencing note in Part 2). R6 addresses two distinct failure modes: (1) budget-exhaustion staleness — HealthKit delivers when WatchConnectivity budget is exhausted, and (2) WidgetKit scheduling gaps — observed in build 139 (9-min gap with fresh App Group data, `reload_age=548s`), where the `HKObserverQuery` wake trigger provides an independent opportunity to call `reloadTimelines`. Do not gate on budget-exhaustion metrics alone.

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

The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires `NSHealthShareUsageDescription` in the requesting process's `Info.plist`. Without it, authorization may crash on launch. `NSHealthUpdateUsageDescription` is **not** needed because `toShare: nil` means no write access is requested.

**What to implement:**

**R6a — Background delivery registration + authorization (WatchState.swift):**
- Add `import HealthKit` to the file
- Add `private var healthKitStore: HKHealthStore?` and `private var glucoseObserverQuery: HKObserverQuery?` properties
- Add `setupHealthKitBackgroundDelivery()` — call from `setupSession()` (alongside `WCSession.activate()`)
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
- Extract glucose: `latest.quantity.doubleValue(for: .milligramsPerDeciliter())` → `String(Int(value.rounded()))`
- Derive delta: if 2 samples available, `latest - previous` → `String(format: "%+.0f", delta)`; else `"--"`
- Trend: `""` (empty — no derivation in R6 initial; add in R6.1 if needed)
- Glucose color: `nil` (requires user settings context not available from HealthKit)
- Compute save age: `let saveAge = Int(Date().timeIntervalSince(readingDate))` — measures HealthKit sync latency
- Construct `TrioComplicationSnapshot(glucose:trend:delta:readingDate:date:glucoseColor:)`
- Call `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` on main queue — triggers `reloadTimelines` only when (a) the snapshot passes `saveOnMain` dedup (`shouldUpdate` returns true) and (b) 5+ seconds have elapsed since the last reload. In the target scenarios (budget exhaustion, WidgetKit scheduling gaps), both conditions are typically met because no prior delivery has occurred recently. In normal dual-delivery operation, the HK snapshot passes dedup (trend differs) and the 10–60s sync latency exceeds the 5s debounce — see plan §R6 "Dedup and Dual-Delivery Behavior" for the trend overwrite tradeoff
- **Critical:** Call `completionHandler()` after the save runs: inside `DispatchQueue.main.async { save(...); completionHandler() }` on success; on error/zero-samples paths call it before return. Do not use `defer` at closure exit.
- Log: `hk_observer_fired reading_epoch=\(Int(readingDate.timeIntervalSince1970)) save_age=\(saveAge) glucose=\(glucoseString) delta=\(deltaString)`

**Log event taxonomy (R6):**

| Event | Fields | When |
|---|---|---|
| `hk_background_delivery_registered` | `success=Bool` | App launch, authorization granted |
| `hk_background_delivery_registration_failed` | `error=String` | App launch, registration failed |
| `hk_authorization_failed` | `granted=Bool error=String` | Authorization request denied |
| `hk_observer_error` | `error=String` | Observer query error callback |
| `hk_observer_fired` | `reading_epoch=Int save_age=Int glucose=String delta=String` | Each HealthKit sample delivery |
| `hk_observer_sample_query_error` | `error=String` | HKSampleQuery returned an error (post-ChatGPT review) |
| `hk_observer_sample_query_zero_samples` | (none) | HKSampleQuery returned no samples or cast failed (post-ChatGPT review) |
| `hk_background_delivery_registered success=false` | (none) | enableBackgroundDelivery returned success=false with no error — log distinctly, not with green check (post-ChatGPT review) |

All events use `debug(.watchManager, ...)` or WatchLogger per target; watch extension uses `WatchLogger.shared.log`. The `hk_observer_fired` event is the primary validation signal — distinguishable from WatchConnectivity via `msg LIKE '%hk_observer_fired%'`.

**Test plan:**

1. **On-device (active CGM):** Deploy to device. Wait for the next CGM reading to be written to HealthKit by Trio. Verify `hk_observer_fired` appears in BetterStack logs. After a second reading (~5 min later), verify delta is computed correctly. Note: background delivery is not supported on Simulator — all HealthKit observer/background-delivery validation must be on-device.

2. **On-device (real CGM running):** Deploy to device with active CGM session.
   - Verify `hk_background_delivery_registered success=true` at app launch
   - Verify `hk_observer_fired` events appear in BetterStack with ~5-min cadence matching CGM interval
   - Verify during budget-exhaustion window: `hk_observer_fired` events continue even when `complication_transfer_remaining=0`
   - Verify dual-delivery behavior: same-reading WC + HK deliveries are not always deduped — the HK snapshot's `trend=""` differs from WC's real trend, so `shouldUpdate` returns `true` and the HK save is accepted. Confirm via logs that both `saveOnMain entered` and `Snapshot saved` fire for the HK delivery. See plan §R6 "Dedup and Dual-Delivery Behavior" for the expected trend overwrite tradeoff

3. **Authorization denied:** Deny HealthKit read permission on watch.
   - Verify `hk_authorization_failed` is logged
   - Verify no `hk_observer_fired` events
   - Verify WatchConnectivity path is completely unaffected

4. **Entitlement + Info.plist verification:** Before building, confirm both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` are in `TrioWatchApp.entitlements` (without these, `enableBackgroundDelivery` silently fails), and confirm `NSHealthShareUsageDescription` is in `Trio Watch App/Info.plist` (without it, `requestAuthorization` may crash on launch).

> ## Cursor-Ready Implementation Prompt
>
> **Context:** You are implementing R6 (HealthKit Background Delivery) from `docs/in-progress/complication-freshness/complication-freshness-remediation-plan.md` v1.34 §R6 and `docs/in-progress/complication-freshness/complication-freshness-implementation-guide.md` v1.20 Step 7.
>
> **Task:**
> 1. Add HealthKit + background delivery entitlements to `Trio Watch App/TrioWatchApp.entitlements` (add `com.apple.developer.healthkit` = true, `com.apple.developer.healthkit.background-delivery` = true).
> 1b. Add `NSHealthShareUsageDescription` to `Trio Watch App/Info.plist`: `<key>NSHealthShareUsageDescription</key><string>Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable.</string>`. Required because the watch app calls `requestAuthorization(toShare: nil, read:)`. `NSHealthUpdateUsageDescription` is NOT needed (`toShare: nil`).
> 2. In `Trio Watch App Extension/WatchState.swift`:
>    - Add `import HealthKit`
>    - Add properties: `private var healthKitStore: HKHealthStore?` and `private var glucoseObserverQuery: HKObserverQuery?`
>    - Add `setupHealthKitBackgroundDelivery()` — request read auth for `.bloodGlucose`, register `enableBackgroundDelivery(for:frequency:.immediate)`, then call `setupGlucoseObserverQuery`
>    - Add `setupGlucoseObserverQuery(store:sampleType:)` — create and execute `HKObserverQuery`
>    - Add `fetchLatestGlucoseFromHealthKit(completionHandler:)` — fetch last 2 samples, build `TrioComplicationSnapshot`, save via `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)`
>    - Call `setupHealthKitBackgroundDelivery()` from `setupSession()` **outside** the `if WCSession.isSupported()` block (at end of `setupSession()`) so HK setup is independent of WatchConnectivity. In the `HKObserverQuery` update handler, add `guard let self else { completionHandler(); return }` before calling `fetchLatestGlucoseFromHealthKit` so `completionHandler()` is always called.
> 3. **Critical:** Call `completionHandler()` only after the save has run: inside `DispatchQueue.main.async { TrioComplicationDataStore.shared.save(...); completionHandler() }` on the success path. On error or zero-samples paths, call `completionHandler()` before return. Do not use `defer { completionHandler() }` at closure exit — that signals "done" before the async save runs. Trend = `""`. Delta derived from 2 samples. Glucose color = `nil`. Use `[weak self]` and `guard let self` in the `requestAuthorization` callback.
> 4. Log all events per the taxonomy in the implementation guide Step 7.
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
> - Observing 48h for cadence, save_age p90, budget-exhaustion coverage, and dual-delivery dedup behavior
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

## Quick Reference: New Properties on `BaseWatchManager`

| Property | Type | Initial | Purpose |
|---|---|---|---|
| `hasPerformedStartupQueueDrain` | `Bool` | `false` | R1b: one-time activation drain |
| `lastQueueDeepDrainAt` | `TimeInterval` | `0` | R1b: 60s cooldown for queue-deep drain path |
| `coalescerTriggerCount` | `Int` | `0` | R2a: reset after each coalescer fire |
| `coalescerSources` | `[String]` | `[]` | R2a: reset after each coalescer fire |
| `lastEligibleSourceAt` | `TimeInterval` | `0` | R2a/R2d: set when eligible source triggers; reset after fire |
| `complicationEligibleSources` | `Set<String>` | `["glucoseStored","glucoseUpdate"]` | R2a/R2d: defined in Step 2, used in Step 4 |
| `lastDispatchedGateKey` | `String` (App Group computed) | `""` | R2b: gate key for dedup; cleared on activation |

## Quick Reference: New Shared Helpers (add to `AppleWatchManager.swift`)

```swift
private func sessionIsReadyForTransfer() -> Bool   // define first
private func cancelStaleQueuedTransfers()           // uses sessionIsReadyForTransfer()
private func computeDispatchGateKey(state:) -> String  // R2b: gate key from WatchState fields
private func currentComplicationAgeSeconds() -> TimeInterval  // Step 3b: from App Group TrioComplication_lastValidTimestamp
```

**Constants:** `private static let complicationAgeGateThresholdSeconds: TimeInterval = 600` (Step 3b).

`sessionIsReadyForTransfer()` must be defined before `cancelStaleQueuedTransfers()` and before the R2d transfer block.

## Quick Reference: Confirmed Symbols

| Symbol | Location | Notes |
|---|---|---|
| `readingDate` | `TrioComplicationSnapshot`, `TrioWatchComplicationEntry` | CGM reading time; `date` is creation/display time |
| `TrioComplicationDataStore.complicationKind` | `TrioComplicationDataStore.swift` line 147 | = `"TrioWatchComplication"` — use constant |
| `session(_:didReceiveApplicationContext:)` | Add to `WatchState.swift` after line ~403 | Under `// MARK: - WCSessionDelegate` |

---

## Changelog

### v1.21 — 2026-03-14 | R6 shipped (build 140) — gate passed + deviations documented

- **Step 7 GATE PASSED:** Build 140 deployed. `hk_background_delivery_registered success=true` and `hk_observer_fired` events confirmed in BetterStack. Replaced STOP block with gate-passed block including deployment verification.
- **Deviation 1 — `HKUnit.milligramsPerDeciliter`:** Documented that `.milligramsPerDeciliter()` is a custom `LoopKit/MockKitUI` extension unavailable on watchOS. Fix: inline `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`.
- **Deviation 2 — `NSHealthUpdateUsageDescription`:** Apple App Store Connect requires this key whenever the HealthKit entitlement is present, regardless of `toShare: nil`. Build 139 upload was rejected (ITMS-90683). Fix: added to `Info.plist`. Corrects the v1.20 statement that this key is "NOT needed."
- **Prerequisite:** Updated to remediation plan v1.35.

### v1.20 — 2026-03-14 | R6 blocker fix: NSHealthShareUsageDescription + NSSortDescriptor correction

- **Blocker found (Cursor code review, confirmed by ChatGPT + Claude):** `Trio Watch App/Info.plist` was missing `NSHealthShareUsageDescription`. The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires the read usage description in the requesting process's `Info.plist`. Without it, the watch app may crash on launch since `setupHealthKitBackgroundDelivery()` runs from `init()`.
- **Fix:** Added `NSHealthShareUsageDescription` to `Trio Watch App/Info.plist`. String: "Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable." The "when wireless sync is unavailable" clause explains why the watch needs HealthKit specifically.
- **Not needed:** `NSHealthUpdateUsageDescription` — `toShare: nil` means no write access; Apple only requires the update description when `toShare` contains types.
- **Files to modify:** Added `Trio Watch App/Info.plist` to the list.
- **Entitlements section:** Added `NSHealthShareUsageDescription` XML block and rationale.
- **STOP checklist:** Added item 2 — verify `NSHealthShareUsageDescription` present.
- **Cursor prompt:** Added task 1b for `NSHealthShareUsageDescription` in Info.plist. Updated doc version references to v1.34/v1.20.
- **Test plan:** Entitlement verification step (4) now includes Info.plist check.
- **R6c SortDescriptor correction:** `HKSampleQuery` requires `[NSSortDescriptor]?` — the Swift `SortDescriptor` type does NOT bridge to `NSSortDescriptor`. Changed recommendation to `NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)` (keyPath API, non-deprecated). The v1.17 recommendation of `SortDescriptor(\.startDate, order: .reverse)` would not compile.
- **Prerequisite:** Updated to remediation plan v1.34.

### v1.18 — 2026-03-14 | Step 7 code review (ChatGPT round 1) + red-team pass

- **CR1 (required):** Cursor prompt and code: call `setupHealthKitBackgroundDelivery()` outside `if WCSession.isSupported()` so R6 is independent of WatchConnectivity. Implemented.
- **CR2 (required):** In `HKObserverQuery` handler, add `guard let self else { completionHandler(); return }` so `completionHandler()` is always called. Implemented.
- **CR3/CR4 (non-blocking):** Added `hk_observer_sample_query_error`, `hk_observer_sample_query_zero_samples`; log `success=false` for background delivery distinctly. Implemented.
- **Log taxonomy:** Added the three new events to the R6 table. Noted watch uses WatchLogger.
- **Step 7 code review findings table:** Added with CR1–CR4 and dispositions. No disagreements.
- **Red-team self-review:** No additional blockers found; completionHandler paths and HK decoupling verified.
- **CR5 (ChatGPT round 2, required):** completionHandler() must run after the save, not when the query closure exits. Moved to inside `DispatchQueue.main.async { save(...); completionHandler() }`. Removed unused `[weak self]` from HKSampleQuery closure. R6d in remediation plan and Cursor prompt updated.
- **Sanity checks (ChatGPT round 3):** S1 — Confirmed TrioComplicationDataStore.save() uses onMain(); when already on main, block runs synchronously, so no extra async hop. S2 — WatchState is singleton (static let shared), so no duplicate setup. Added "Step 7 — Sanity checks (ChatGPT round 3)" table.

### v1.19 — 2026-03-14 | Step 7 sanity checks (ChatGPT round 3)

- Documented verification that save() runs synchronously when on main (onMain executes block inline). Documented WatchState singleton; no duplicate HK setup guard needed.

### v1.17 — 2026-03-14 | R6 pre-implementation fixes (entitlements, weak self, SortDescriptor)

- **Entitlements:** HealthKit with background delivery is already enabled on the Trio WatchKit Extension App ID. Removed "update provisioning profile" prerequisite; only entitlements file addition required.
- **R6a:** Added bullet to use `[weak self]` and `guard let self` in `requestAuthorization` callback.
- **R6c:** Specified `SortDescriptor(\.startDate, order: .reverse)` — not `NSSortDescriptor` or `HKSampleSortIdentifierStartDate`.
- **Cursor prompt (task 3):** Added explicit: Use `SortDescriptor(\.startDate, order: .reverse)`; use `[weak self]` capture with `guard let self` in `requestAuthorization` callback.
- **Prerequisite:** Updated to remediation plan v1.31.

### v1.16 — 2026-03-14 | Step 5/R4 and Step 7/R6 mapping + sequencing

- **Step ↔ Plan mapping:** Added explicit mapping: Step 5 = R4 (applicationContext safety net), Step 7 = R6 (HealthKit background delivery).
- **Sequencing:** Added recommendation to go straight to Step 7 (R6). Rationale: R4 would have done nothing for the observed 24-minute gap (data already in App Group; WidgetKit not calling getTimeline; R4 still ends with reloadTimelines WidgetKit can ignore). R6 gives independent system-triggered wake when new glucose arrives; R4 remains valuable for budget exhaustion but is lower urgency. Can ship R4 after R6 or bundle in same PR (different files).
- **Step 5 heading:** Clarified as "applicationContext safety net."
- **Step 7:** Decision gate updated to "ship R6 before or alongside R4." Added prerequisite: update provisioning profile in Apple Developer portal to enable HealthKit on watch extension App ID before running the Cursor prompt; entitlements alone are not sufficient.
- **Prerequisite:** Updated to remediation plan v1.30.

### v1.15 — 2026-03-14 | R6 reload path accuracy

- **R6c save bullet:** Qualified "triggers reloadTimelines" — now states the two conditions required: (a) snapshot passes `saveOnMain` dedup (`shouldUpdate` returns true), (b) 5+ seconds since last reload. Added cross-reference to plan §R6 "Dedup and Dual-Delivery Behavior" for the trend overwrite tradeoff in normal dual-delivery operation.
- **Prerequisite:** Updated to remediation plan v1.29.

### v1.14 — 2026-03-14 | R6 test plan + entitlement fixes

- **Test plan:** Removed simulator-based background delivery test (Apple does not support HealthKit background delivery on Simulator). Replaced with on-device test using active CGM — wait for next reading to be written to HealthKit, verify observer fires. All HealthKit observer/background-delivery validation is on-device only.
- **Entitlement:** Removed `com.apple.developer.healthkit.access` (empty array) from the XML block and the Cursor prompt. This entitlement is for sensitive HealthKit capability types and is not needed for reading `.bloodGlucose`. Only `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` are required.
- **Prerequisite:** Updated to remediation plan v1.28.

### v1.13 — 2026-03-14 | R6 decision gate broadened + saveAge fix

- **Decision gate:** Broadened from "budget-exhaustion only" to "ship after R4 — addresses both budget-exhaustion staleness and WidgetKit scheduling gaps." Cited build 139 evidence (9-min gap, `reload_age=548s`). STOP block validation line updated to cover both failure modes.
- **R6c:** Added explicit `let saveAge = Int(Date().timeIntervalSince(readingDate))` bullet to match the log line that references `\(saveAge)`. The computation was already present in the remediation plan's R6c code snippet but was missing from the guide's bullet-point description.
- **R6c save path:** Added note that `save(snapshot, minInterval: 5)` triggers `reloadTimelines` via the existing save path — this is the independent WidgetKit wake trigger.
- **Prerequisite:** Updated to remediation plan v1.27.

### v1.12 — 2026-03-14 | Step 7 (R6) HealthKit Background Delivery

- **Step 7 added:** HealthKit background delivery implementation section. Watch extension registers `HKObserverQuery` for `.bloodGlucose` with `enableBackgroundDelivery`, fetches latest 2 samples on observer fire, derives delta, constructs `TrioComplicationSnapshot`, saves via existing `TrioComplicationDataStore.shared.save()` path.
- **Entitlements:** Documents exact XML keys to add to `TrioWatchApp.entitlements` (both `healthkit` and `healthkit.background-delivery` currently missing — blocker).
- **Log taxonomy:** 5 structured events (`hk_background_delivery_registered`, `hk_background_delivery_registration_failed`, `hk_authorization_failed`, `hk_observer_error`, `hk_observer_fired`) consistent with existing `event=` convention.
- **Test plan:** 4 scenarios (on-device with CGM, authorization denied, entitlement verification). Note: simulator test replaced with on-device in v1.14.
- **Cursor-ready prompt:** Full implementation prompt targeting `WatchState.swift` and `TrioWatchApp.entitlements` only.
- **Prerequisite:** Updated to remediation plan v1.26.

### v1.11 — 2026-03-13 | Logging fixes context for Step 4 gate

- **Step 3b:** Updated gate-passed block from "implemented" to "deployed (builds 137-138)". Added deployment note referencing cloud logging pipeline fixes and their impact on avg C measurement reliability.
- **Step 4 gating:** Added observation window note — 48h starts from build 137 deploy (2026-03-12); run avg C query ~2026-03-15.
- **Prerequisite:** Updated to remediation plan v1.25.

### v1.10 — 2026-03-12 | Step 3b completion

- **Step 3b:** Marked implemented; STOP block replaced with gate-passed block. Code verification summary (helper pattern, constant, branching, lastDispatchedGateKey rule, log taxonomy) and next step (observe 48h, then Step 4/5) documented.
- **Prerequisite:** Updated to remediation plan v1.24.

### v1.9 — 2026-03-11 | Step 3b implementation review

- **Age computation scope:** `currentComplicationAgeSeconds()` and `ageGatePassed` are now computed only inside the branch where we might spend budget (`!isReachable && readingEpochPresent && !isDuplicateDispatch && remaining > 0`), reducing App Group reads and log noise when reachable or duplicate.
- **Duplicate skip log scope:** `complication_transfer_gate_skipped skip_reason=duplicate_gate` now fires only when a background complication transfer would otherwise be considered (`!isReachable && readingEpochPresent`), avoiding confusion with sendMessage-only or missing-epoch paths.
- **Skip log taxonomy:** Both duplicate and age-gate skip logs include `reading_date_epoch_seconds` for consistent BetterStack queryability.

### v1.8 — 2026-03-11 | Nit-only consistency pass

- Version bump; prerequisite aligned to remediation plan v1.23. Step 3 (R2b) block updated so “Build 134 deployed; observing 48h” is explicit and not contradicted by “pending build/deploy” wording.

### v1.7 — 2026-03-11 | Nit consistency cleanup (Step 3b)

- **Helper:** Step 3b helper made identical to remediation plan: exact 4-step pattern (guard suiteName/defaults → .infinity; let lastValid; if lastValid == nil return .infinity; return max(0, …)).
- **lastDispatchedGateKey rule:** Wording aligned across docs — only set when complication transfer actually enqueued; not on sendMessage-only; not when age gate fails; do not reintroduce Step 3 foreground→background suppression bug.
- **Skip-log taxonomy:** Three queryable categories stated consistently: skip_reason=age_gate, skip_reason=duplicate_gate, missing readingEpoch.
- **STOP block:** Explicit that age gate applies ONLY to transferCurrentComplicationUserInfo (budget-consuming), NOT sendMessage and NOT userInfo fallback.
- **Prerequisite reference:** Updated to remediation plan v1.22.

### v1.6 — 2026-03-11
- **Step 3b added:** Complication-age stale-first budget gate. New step after Step 3 (R2b), before Step 4 (R2d). Helper `currentComplicationAgeSeconds()` (guard-let for suite/defaults), constant `complicationAgeGateThresholdSeconds = 600`, explicit branching (age gate only when remaining &gt; 0; userInfo fallback never gated). Log fields: `complication_age_seconds`, `complication_age_gate_threshold_seconds`, `complication_transfer_age_gate_skipped skip_reason=age_gate`. STOP block with 48h observe (compare by reset window), tuning guidance (12m / 8m).
- **Quick Reference:** Added `currentComplicationAgeSeconds()` and `complicationAgeGateThresholdSeconds`.
- **Prerequisite reference:** Updated to remediation plan v1.21.

### v1.5 — 2026-03-11
- **Step 3 CODE REVIEW PASSED:** Documented R2b dispatch gate implementation. Two review rounds: Claude (6 points, 1 fix — activation clear) and ChatGPT (critical bug — gate key write moved inside complication transfer block to prevent sendMessage-only paths from suppressing background transfers).
- **Quick Reference:** Added `lastDispatchedGateKey` property and `computeDispatchGateKey` helper.
- **Prerequisite reference:** Updated to remediation plan v1.20.

### v1.4 — 2026-03-10
- **Step 2 COMPLETED:** Marked Step 2 (R2a + R3) as completed with build 133 gate-passed block. Documented post-review fixes (queue-deep drain placement, count guard, fallback warning, drain log detail).
- **Prerequisite reference:** Updated to remediation plan v1.19.

### v1.3 — 2026-03-09
- **Step 1 COMPLETED:** Marked Step 1 (R1a + R1b + R5e) as completed with build 132 gate-passed block. Documented BetterStack verification results.

### v1.2 — 2026-03-09
- Initial version with all 6 implementation steps.