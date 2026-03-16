# Cursor Round 2: Audit Results + Implementation Guide
**Version:** 1.37 | **Date:** 2026-03-16
**Prerequisite:** `complication-freshness-remediation-plan.md` v1.52 — Build 141 deployed (patch 09); R6.1 + R5f + R5c + R5b implemented; delta/trend fix, source-predicate doc accuracy, post-review R5c/R5b corrections, and R5c follow-up cleanups applied

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

**Sequencing (Step 5 vs Step 7) — historical rationale:** Based on observed data (e.g. 24-minute gap with fresh App Group data, WidgetKit not calling `getTimeline`), R6 was shipped before R4 **(completed — R6 shipped build 140; Step 5/R4 still pending)**. R4 would have done nothing for that gap — the data was already in the App Group; the problem was WidgetKit not calling `getTimeline`. R4 sends more data via another WatchConnectivity channel but still ends with a `reloadTimelines` call that WidgetKit can ignore just as freely. R6 (Step 7) gives an independent system-triggered wake that fires when new glucose data arrives in HealthKit; each wake is another `reloadTimelines` call from a fresh background task context (e.g. during a 9-minute gap, R6 would have fired at least once from the next reading). R4 still has real value — it covers the budget-exhaustion failure mode that R6 doesn't help with — and remains the next step to ship. R4 and R6 touch different files (`AppleWatchManager.swift` for R4, `WatchState.swift` for R6).

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
> - **Observation:** 48h window starts from build 137 deploy (2026-03-12). Run avg C query ~2026-03-15. If avg C <= 1.3 → skip Step 4, proceed to Step 5. If avg C > 1.3 → proceed to Step 4 (R2d). Avg C is measured by the Trio Dashboard "Avg C / reading" chart (metric `complication_c_total_transfers`; see remediation plan §Better Stack avg C metrics).

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
    debug(.watchManager, "📦 didReceiveApplicationContext")
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
> 1. **Verify both `lastDataReceivedAt` and `forceWidgetReloadIfStale(receivedGap:)` are in scope** — these are defined in Step 6 (R5d). If implementing Step 5 before Step 6, either bundle Steps 5 and 6 in the same PR, or stub these in the watch-side handler (e.g. in-memory `Date?` for `lastDataReceivedAt` and no-op for `forceWidgetReloadIfStale`) and remove the stubs when Step 6 ships. The STOP block for Step 6 includes a cross-reference reminder.
> 2. **Code review** this PR — verify `updateApplicationContext` placement is at END of `sendDataToWatch` (not before transfer calls), `complicationMessage` is in scope, and the watch-side handler uses the three-constraint ordering
> 3. **Build and deploy** to device
> 4. **Validate during a budget exhaustion window:** `save_age` p90 should drop below 300s compared to pre-R4 baseline

---

### Step 6 — PR: R5 observability hardening (opportunistic, parallel-safe after Step 1)

**R5b:** Add `sendMessage` wall-clock timestamp on iOS send. On the watch, read `readingEpoch` from the **inner** payload (`message[WatchMessageKeys.watchState]`), not the outer envelope — see remediation plan §R5b "As implemented (post-review)" and the code comment in `WatchState.swift`.

**R5c:** Add `decode_ms` to `didReceiveUserInfo` (receive → `saveComplicationSnapshot` return). **Attribution must be threaded with the work, not shared state:** pass `fromUserInfo` and `userInfoReceiveTimestamp` through `scheduleUIUpdate` → `finalizePendingData` → `processRawDataForWatchState` → `saveComplicationSnapshot`. In `saveComplicationSnapshot`, log `reading_epoch` from the payload being saved and `decode_ms` from the threaded timestamp only (no fallback to instance state). In the pending-tasks path, capture the receive timestamp outside the `DispatchWorkItem` at creation time. See remediation plan §R5c "As implemented (post-review)" and v1.51 changelog (ChatGPT + Claude follow-up).

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

**R5f — WidgetKit entry-path events (R6.1 logging enhancement):** Both events are complication-extension / WidgetKit only (not HealthKit observer events). The complication can show fresh data from either `getTimeline` or `getSnapshot`; getTimeline-only logging does **not** reconstruct full visible recency.

**A. Timeline path — `event=complication_get_timeline_called`:**

- **`get_timeline_at_epoch_seconds`** — Unix epoch when getTimeline was invoked. Capture at log time (e.g. `Int(Date().timeIntervalSince1970)` at the start of getTimeline or immediately before the event is logged).
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to build the timeline. Compute **after** loading the snapshot that will be used to build the timeline: `max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))`. Use the snapshot that is passed to the timeline entries, not the most recent saved snapshot from another path. If there is no valid reading date (e.g. `.distantPast` or placeholder), emit the documented sentinel (e.g. `-1`).

**B. Snapshot path — `event=complication_get_snapshot_called`:**

- **`get_snapshot_at_epoch_seconds`** — Unix epoch when getSnapshot was invoked. Capture at log time.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to produce the snapshot entry. Compute **after** loading the snapshot that will be used to build the entry returned to WidgetKit on this path; use the same sentinel for invalid/placeholder reading dates.

In both paths, `data_age_seconds` must be from the snapshot **actually used to build the WidgetKit entry on that path** — not from another save/reload path or "latest known reading" in the abstract.

**Observability framing:** *Timeline-generation observability* = getTimeline events; *snapshot-generation observability* = getSnapshot events; *visible recency* = both paths matter. A chart from getTimeline only = **timeline-recency / timeline-refresh recency**; for actual **visible recency**, include getSnapshot in the analysis.

**Implementation note (getTimeline):** Compute both values after the timeline snapshot is loaded; pass them into the existing log call so the event carries the data age of the snapshot actually returned to WidgetKit.

**Implementation guidance (getSnapshot):** In `getSnapshot`, emit `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` captured at log time and `data_age_seconds` computed after loading the snapshot actually used to build the snapshot entry. Use the documented sentinel for invalid/placeholder reading dates. This is observability only and does not change WidgetKit behavior.

**Scope boundary:** R5f enhancement does not change reload logic, dedup logic, HealthKit behavior, trend/delta derivation, or WidgetKit scheduling; only improves observability of what WidgetKit rendered or prepared to render.

**Validation / query:** Timeline path fields support timeline-recency and timeline-refresh sawtooth reconstruction. A sawtooth built only from getTimeline is **not** a full visible-recency sawtooth — include getSnapshot events to better reconcile with cases where the face shows "NOW" without a logged getTimeline. Both events together support visible-recency analysis in Better Stack Explore. Standard metric-bucket dashboards may not support as-of / point-in-time reconstruction natively.

> **Post-review corrections (2026-03-15):** After implementation of R5b/R5c, a review identified (1) R5c attribution risk — a shared boolean could be overwritten before finalize ran. Fix: pass `fromUserInfo` and (for the userInfo path) `userInfoReceiveTimestamp` through the chain; capture the timestamp outside the work item in the pending-tasks path; in `saveComplicationSnapshot`, use only the threaded timestamp for `decode_ms` and derive `reading_epoch` from the payload being saved; no fallback to instance state; remove dead `lastUserInfoReadingEpoch`. (2) R5b verification — confirm watch-side epoch is read from the inner payload. Verified and documented in code. Follow-up reviews (ChatGPT, Claude) confirmed the shape and requested removal of the fallback and dead state. See remediation plan v1.50–v1.51 changelog and §R5b/§R5c "As implemented (post-review)."

> ## 🛑 STOP — Code Review + Build/Deploy
> 1. **Code review** this PR — verify `forceWidgetReloadIfStale(receivedGap:)` signature matches all call sites, `lastDataReceivedAt` is updated in both `didReceiveUserInfo` and `didReceiveApplicationContext` (if Step 5/R4 has shipped; if not, verify only `didReceiveUserInfo` — the `didReceiveApplicationContext` update is part of Step 5), and rename is complete (no remaining `lastUserInfoReceivedAt` references)
> 2. **Build and deploy** to device
> 3. **Confirm in BetterStack:** `timeline_built snapshot_age` p90 < 600s after sleep gaps; `reload_with_stale_snapshot` events are rare

---

### Step 7 — PR: R6 (HealthKit Background Delivery)

**Decision gate:** Ship R6 before or alongside R4 (see sequencing note in Part 2). **Actual: R6 shipped first (build 140); R4 is still pending.** R6 addresses two distinct failure modes: (1) budget-exhaustion staleness — HealthKit delivers when WatchConnectivity budget is exhausted, and (2) WidgetKit scheduling gaps — observed in build 139 (9-min gap with fresh App Group data, `reload_age=548s`), where the `HKObserverQuery` wake trigger provides an independent opportunity to call `reloadTimelines`. Do not gate on budget-exhaustion metrics alone.

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
- Trend: `""` (empty — no derivation in R6; derivation added in R6.1, which is spec-complete and ready for implementation)
- Glucose color: `nil` (requires user settings context not available from HealthKit)
- Compute save age: `let saveAge = Int(Date().timeIntervalSince(readingDate))` — measures HealthKit sync latency
- Construct `TrioComplicationSnapshot(glucose:trend:delta:readingDate:date:glucoseColor:)`
- Call `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` on main queue — triggers `reloadTimelines` only when (a) the snapshot passes `saveOnMain` dedup (`shouldUpdate` returns true) and (b) 5+ seconds have elapsed since the last reload. In the target scenarios (budget exhaustion, WidgetKit scheduling gaps), both conditions are typically met because no prior delivery has occurred recently. In normal dual-delivery operation, the HK snapshot passes dedup (trend differs) and the 10–60s sync latency exceeds the 5s debounce — see plan §R6 "Dedup and Dual-Delivery Behavior" for the trend overwrite tradeoff
- **Critical:** Call `completionHandler()` after the save runs: inside `DispatchQueue.main.async { save(...); completionHandler() }` on success; on error/zero-samples paths call it before return. Do not use `defer` at closure exit.
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
> 1b. Add both usage description keys to `Trio Watch App/Info.plist`. `NSHealthShareUsageDescription` is required because the watch app calls `requestAuthorization(toShare: nil, read:)`: `<key>NSHealthShareUsageDescription</key><string>Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable.</string>`. `NSHealthUpdateUsageDescription` is **also required** — App Store Connect rejects uploads with the HealthKit entitlement but missing this key, regardless of `toShare: nil` (ITMS-90683; confirmed build 140). Add any non-empty string. `NSHealthUpdateUsageDescription` does not grant write capability — authorization remains read-only.
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

### Step 7.1 — PR: R6.1 (HealthKit Channel Improvements)

**Status:** ✅ Implemented (2026-03-15). HK fetch path replaced with `HKAnchoredObjectQuery`; anchor/epoch/value persistence in `TrioComplicationDataStore`; trend/delta derivation (raw delta first, then round once); R6.1 log taxonomy. **As implemented:** No SyncIdentifier predicate — 24h date cap when anchor is nil, nil predicate when anchor exists; source filtering deferred to R6.2 (remediation plan §Source Predicate "As implemented").

**Builds on:** Step 7 / R6, shipped in build 140. R6.1 refines the HK fetch/processing path; it does not replace R6's observer registration, authorization, entitlements, or background delivery mechanics.

---

**Decision gate:**

- No additional product or telemetry gate beyond the normal R6 observation period is required before implementing R6.1.
- R6.1 is a correctness and observability refinement after the R6 baseline — it improves the quality of an already-working channel rather than enabling a new one.
- Proceed to implementation when the R6 observation period is complete and no R6-specific regressions have been identified.

---

**Files expected to change in the future implementation:**

| File | Scope of change |
|---|---|
| `Trio Watch App Extension/WatchState.swift` | Replace `HKSampleQuery` fetch helper with `HKAnchoredObjectQuery` helper; add epoch guard; update log events |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Add anchor, epoch, and previous-sample persistence methods |

These are future implementation targets, not part of this docs-only update.

---

**Implementation boundaries:**

The future R6.1 implementation should NOT modify:

- HealthKit authorization flow (`requestAuthorization`)
- `setupHealthKitBackgroundDelivery()` — registration and authorization shape. **Exception:** the `hk_background_delivery_registered` log call gains `low_power_mode=ProcessInfo.processInfo.isLowPowerModeEnabled` to match the R6.1 taxonomy. This is the only change to this function.
- `setupGlucoseObserverQuery(store:sampleType:)` — observer registration shape
- `HKObserverQuery` creation, execution, or update handler signature
- Entitlements (`TrioWatchApp.entitlements`)
- Info.plist (`Trio Watch App/Info.plist`)

R6.1 scope is the HK fetch/processing path (inside the observer callback) plus App Group persistence helpers in `TrioComplicationDataStore`. Everything upstream of the fetch and downstream of the save is unchanged.

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
- Consistent with remediation plan §R6.1 "Source Predicate Decision."

---

**Intended implementation shape:**

The future implementation replaces only the fetch/processing portion of the HK observer callback. Guidance for the implementation:

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

This should read as guidance for a future implementation pass, not as an imperative code patch for this session.

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

After a future R6.1 implementation is deployed, the following should be observable in BetterStack:

| Expectation | Query hint |
|---|---|
| `hk_observer_fired` events include `query_type=anchoredQuery` | `msg LIKE '%query_type=anchoredQuery%'` |
| `hk_observer_no_new_samples` appears for phantom fires | `msg LIKE '%hk_observer_no_new_samples%'` — should be non-zero over 24h |
| `trend_derived=true` appears on the majority of normal CGM intervals | `msg LIKE '%trend_derived=true%'` — should be the common case for consecutive 5-min readings |
| Derived `trend` values are valid direction strings | `msg LIKE '%trend=%'` — inspect actual values (`Flat`, `SingleUp`, etc.) to verify threshold mapping |
| `hk_anchor_decode_failed` should be absent under normal conditions | `msg LIKE '%hk_anchor_decode_failed%'` — expected 0 in steady state |
| `hk_observer_skipped_known_epoch` should be low-volume | `msg LIKE '%hk_observer_skipped_known_epoch%'` — present but not dominant |
| No `HKSampleQuery`-based events in new builds | `msg LIKE '%hk_observer_sample_query%'` — expected 0 from R6.1 builds |

These are future verification expectations, not claims about current code. Current build 140 uses R6's `HKSampleQuery`-based events.

**Dual-delivery dedup benefit:** When R6.1 trend derivation produces the same raw direction string as the WC path for the same reading (e.g., both produce `"Flat"`), `shouldUpdate` may return `false` for same-reading dual delivery — glucose, trend, delta, and readingDate all match. This reduces or eliminates the R6 trend-overwrite regression where `trend=""` from HK overwrote a valid WC trend. Note: delta format differences for mmol/L users (HK always mg/dL, WC may be mmol/L) can still cause `shouldUpdate` to return `true` even when the trend matches.

**Inherited unit note:** R6 (and R6.1) compute HK delta in mg/dL. The WC path formats delta in the user's preferred units. For mmol/L users, HK and WC deltas have different string representations for the same reading, which prevents dedup from recognizing them as duplicates. R6.1 does not solve this unit-format parity; it is inherited from R6 and deferred unless separately scoped.

**Source-predicate over-inclusion note:** If derived delta or trend values appear anomalous relative to expected CGM behavior — especially in multi-app HealthKit setups — consider source-predicate over-inclusion before treating it as an implementation bug. The presence-only `HKMetadataKeySyncIdentifier` filter may include non-Trio samples. This is a known R6.1 tradeoff; value-specific refinement is deferred to R6.2.

**Derivation scope boundary:** R6.1 only adds derivation for `delta` and `trend`. `glucoseColor` remains `nil`, `state` is not synthetically derived, HK delta formatting stays mg/dL-only (no mmol/L parity), and `sync_lag` is used for logging only — not in display, dedup, or trend logic. This is an intentional scope boundary.

---

**Post-implementation verification prompt (future use):**

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
> **This prompt is for future use only.** Do not execute it during this docs-only session.

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

### v1.36 — 2026-03-15 | R5c post-review follow-up (ChatGPT + Claude)

- **Review context:** After the v1.35 post-review R5c/R5b documentation, two follow-up reviews (ChatGPT, then Claude) evaluated the R5c attribution implementation.
- **ChatGPT:** Confirmed the fix (epoch from payload, timestamp threaded through the path) addresses the main attribution flaw. Requested cleanups: (1) Use only the threaded `userInfoReceiveTimestamp` for `decode_ms` when `fromUserInfo` is true — no fallback to `lastUserInfoReceiveTimestamp`, so attribution stays unambiguous. (2) Remove the unused `lastUserInfoReadingEpoch` property. Both applied in code.
- **Claude:** Confirmed capture of receive timestamp outside the `DispatchWorkItem` at creation time and `reading_epoch` from the payload being saved; noted the fallback had already been removed; confirmed unconditional nil-out of `lastUserInfoReceiveTimestamp` when `fromUserInfo` is correct. Noted R5b/R5f/R6.1 live in other files — a diff that only touches WatchState for R5c is expected.
- **Step 6:** R5c bullet and "Post-review corrections" note updated to describe threading of `userInfoReceiveTimestamp`, epoch from payload, no fallback, and removal of dead state. Prerequisite set to remediation plan v1.51.

### v1.37 — 2026-03-16 | Build 141 status

- **Build 141 built and deployed.** Patch 09 (watch-complication-improvements) with R5c/R5b corrections and complication-freshness docs (remediation plan v1.52, this guide v1.37) committed to `dev`.
- **Prerequisite:** Remediation plan v1.52.

### v1.35 — 2026-03-15 | Post-review R5c/R5b documentation

- **Review and corrections:** Implementation (R6.1, R5f, R5c, R5b, delta/trend) was reviewed; two code corrections were applied: (1) R5c attribution must ride with the work item (`scheduleUIUpdate(with:fromUserInfo:)`, `finalizePendingData(fromUserInfo:)`), not a shared flag; (2) R5b watch-side epoch extraction verified to use inner payload and documented in code. See remediation plan v1.50 changelog for full context.
- **Step 6:** R5b/R5c bullets updated with "As implemented (post-review)" guidance and pointer to plan §R5b/§R5c. New "Post-review corrections" note added above the STOP block summarizing the review and fixes.
- **Prerequisite:** Remediation plan v1.50.

### v1.34 — 2026-03-15 | R6.1 delta/trend fix + source-predicate doc accuracy

- **R6.1 delta/trend:** Implementation now computes raw numeric delta first, then rounds once for both display and trend (matches remediation plan §Delta and Trend "Numeric delta").
- **Source-predicate wording:** Step 7.1 status now states "As implemented: No SyncIdentifier predicate — 24h date cap when anchor is nil, nil predicate when anchor exists; source filtering deferred to R6.2."
- **Prerequisite:** Remediation plan v1.49.

### v1.33 — 2026-03-15 | R6.1 + R5f + R5c + R5b implementation complete

- **Step 7.1 (R6.1):** Implemented. HealthKit fetch replaced with `HKAnchoredObjectQuery`; anchor/epoch/previous-sample persistence in `TrioComplicationDataStore`; derive-then-persist; trend from integer delta (raw direction strings); R6.1 events and `fire_id`; `low_power_mode` on registration log. Deviation: SyncIdentifier predicate not applied (deferred to R6.2).
- **R5f:** `complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds` and `data_age_seconds`; new `complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` and `data_age_seconds`; data age from snapshot used on each path; sentinel `-1` for invalid reading date.
- **R5c:** `didReceiveUserInfo` decode latency: receive timestamp set on userInfo; `saveComplicationSnapshot(from:fromUserInfo:)` logs `userInfo_decoded` when fromUserInfo path completes.
- **R5b:** iPhone `sendMessage_sent` and watch `didReceiveMessage` logs with epoch and wall-clock timestamps.
- **Prerequisite:** Remediation plan v1.48.

### v1.32 — 2026-03-15 | R5f expanded: timeline + snapshot entry-path logging, getSnapshot impl guidance

- **R5f expanded to both WidgetKit entry paths:** R5f now specifies both `event=complication_get_timeline_called` (existing) and `event=complication_get_snapshot_called` (new) with analogous fields (`get_timeline_at_epoch_seconds` / `get_snapshot_at_epoch_seconds`, `data_age_seconds`). Observability framing: timeline-generation vs snapshot-generation vs visible recency (both paths matter). Chart naming: getTimeline-only = timeline-recency; for visible recency include getSnapshot.
- **getSnapshot implementation guidance added:** Emit `complication_get_snapshot_called`; capture `get_snapshot_at_epoch_seconds` at log time; compute `data_age_seconds` after loading snapshot used for snapshot entry; use sentinel for invalid reading date; observability only, no WidgetKit behavior change.
- **Scope boundary and sawtooth guidance:** R5f does not change reload, dedup, HealthKit, trend/delta, or WidgetKit scheduling. Validation/query: getTimeline-only sawtooth is not full visible-recency; include getSnapshot for visible-recency analysis in Explore.
- **Prerequisite:** Updated to remediation plan v1.47.

### v1.31 — 2026-03-15 | getTimeline visible-recency logging (R6.1 enhancement)

- **`event=complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds` and `data_age_seconds`:** R5f section expanded with visible-recency fields (complication-extension / getTimeline only, not HealthKit). Implementation note: compute after loading the snapshot used for the timeline; capture epoch at log time; use sentinel for invalid reading date. Validation/query note: supports visible recency at getTimeline and sawtooth reconstruction in Better Stack Explore; dashboard as-of may not be native. Observability only; no reload, dedup, trend, or WidgetKit behavior change.
- **Prerequisite:** Updated to remediation plan v1.46.

### v1.30 — 2026-03-15 | 3-pass adversarial review — correctness fixes, stale state, orphaned fields

**Summary:** Three-pass structured review correcting factual errors introduced when the deviation log was never backported into normative text, and clearing stale sequencing language after build 140 changed the ship order.

**Correctness fixes (blocked an implementer or would trigger a repeated compile/deploy failure):**

- **`NSHealthUpdateUsageDescription` (Step 7 pre-work, Cursor prompt):** Corrected from "not needed" to "required by App Store Connect validation." Build 140 confirmed altool rejects uploads with the HealthKit entitlement but missing this key, regardless of `toShare: nil` (ITMS-90683). Both normative sections now match the deviation note already in the gate-passed block.
- **R6a placement (Step 7 R6a bullet, Cursor prompt):** Corrected from "call alongside `WCSession.activate()`" to "call at end of `setupSession()`, **outside** the `if WCSession.isSupported()` block." CR1 (required) documented this fix, but the normative bullet text was never updated.
- **R6c glucose unit (Step 7 R6c bullet):** Corrected from `.milligramsPerDeciliter()` to `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`. The former is a LoopKit extension unavailable on watchOS — it caused the build 140 compile failure. Normative bullet was never updated after the deviation was documented.
- **Step 5 watch-side handler:** Added missing `debug(.watchManager, "📦 didReceiveApplicationContext")` log line. The Plan's §R5d version of the same handler includes it; the Guide's version did not, making R4 validation in BetterStack impossible without it.

**Orphaned field fix (R6.1 taxonomy):**

- **`hk_background_delivery_registered` `low_power_mode=Bool`:** R6.1 taxonomy changed this field from `success=Bool` (R6) to `low_power_mode=Bool` with no implementation path, no source API, no rationale for dropping `success`. Resolved: both `success=Bool` and `low_power_mode=Bool` are now specified; `low_power_mode` source is `ProcessInfo.processInfo.isLowPowerModeEnabled`; `success` is the `enableBackgroundDelivery` callback return value.

**Log taxonomy cleanup:**

- **R6 log taxonomy table:** `hk_background_delivery_registered success=false` was listed as a separate event row, implying a distinct event name. Folded into the `hk_background_delivery_registered` parent row as a note about logging prefix (CR4 intent). BetterStack queries were querying for an event that isn't a separate event.

**Stale sequencing and status language:**

- **Step 7 decision gate:** Added "Actual: R6 shipped first (build 140); R4 is still pending." Previously read as a recommendation for a future decision.
- **Step 5 STOP block:** Added explicit dependency note — `lastDataReceivedAt` and `forceWidgetReloadIfStale(receivedGap:)` are defined in Step 6 (R5d); if implementing Step 5 independently, these must be stubbed or Steps 5 and 6 bundled.
- **Step 6 STOP block:** Qualified `didReceiveApplicationContext` check — this handler doesn't exist until Step 5 ships; review item was previously stated unconditionally.
- **Step 7 R6c trend bullet:** "add in R6.1 if needed" → "derivation added in R6.1, which is spec-complete and ready for implementation."

- **Prerequisite:** Updated to remediation plan v1.45.

### v1.29 — 2026-03-15 | R6.1 delta/trend derivation clarity — numeric vs display, threshold input, fallback, scope boundary

- **Previous-sample bullet expanded:** Now explicitly requires shared previous-sample source for delta and trend, documents the single integer mg/dL delta computation, states integer delta feeds both threshold classification and display formatting, and specifies no floating-point threshold system.
- **Delta/trend fallback bullet added:** Explicit fallback behavior when no valid previous sample exists or plausibility gate fails — both trend and delta fall back, regardless of batch vs persisted source.
- **Derivation scope boundary added:** New paragraph documenting that R6.1 only derives `delta` and `trend`; `glucoseColor`, `state`, mmol/L parity, and `sync_lag` in display/dedup/trend are out of scope.
- **Prerequisite:** Updated to remediation plan v1.44.

### v1.28 — 2026-03-15 | R6.1 taxonomy fix — `fire_id` on `hk_observer_error`

- **`hk_observer_error` now includes `fire_id`:** Added `fire_id=UUID` to the R6.1 `hk_observer_error` event for consistency with all other observer-callback events.
- **Prerequisite:** Updated to remediation plan v1.43.

### v1.27 — 2026-03-15 | R6.1 final polish — verification prompt ordering, backfill validation

- **Verification prompt item 6 rewritten:** Now explicitly reflects derive-then-persist ordering on the new-sample path: (a) anchor saved, (b) delta/trend derived from previous state, (c) current sample epoch/value persisted, (d) main-thread snapshot save block runs.
- **Backfill sanity check tightened:** Backfill batch row now explicitly states the saved snapshot's reading date must correspond to the greatest `startDate` in the batch.
- **Prerequisite:** Updated to remediation plan v1.42.

### v1.26 — 2026-03-15 | Avg C observation cross-reference

- **Step 3b observation:** Added cross-reference — avg C is measured by the Trio Dashboard "Avg C / reading" chart using metric `complication_c_total_transfers` (remediation plan §Better Stack avg C metrics).
- **Prerequisite:** Updated to remediation plan v1.41.

### v1.25 — 2026-03-15 | R6.1 spec polish — derive-then-persist ordering, epoch/value persistence wording, source-predicate validation

- **Derive-then-persist ordering clarified:** Implementation shape now has a dedicated "Epoch/value persistence" bullet explicitly stating derive-first, persist-current-sample-second ordering. Separated from anchor advancement bullet for clarity.
- **Epoch/value persistence wording tightened:** Anchor advancement bullet now focuses only on anchor; epoch/value update conditions and derive-then-persist ordering are in their own bullet.
- **Source-predicate over-inclusion validation note added:** Post-implementation verification section now includes guidance that anomalous delta/trend values should be considered as possible source-predicate over-inclusion before treating them as bugs.
- **Prerequisite:** Updated to remediation plan v1.39.

### v1.24 — 2026-03-14 | R6.1 spec tightening — anchor advancement, field rename, sample ordering, trend observability

- **Anchor advancement on non-save exits clarified:** Implementation shape updated — no-new-samples and epoch-guard-skip fast-exit paths now explicitly save the new anchor while leaving epoch/value unchanged. Sanity check updated to reflect anchor advances on all successful queries. Verification prompt item 6a added for non-save-path anchor advancement.
- **`save_age` → `sync_lag` field rename documented:** Added note in log taxonomy section that R6 uses `save_age` and R6.1 renames to `sync_lag`. BetterStack query guidance for cross-build queries.
- **Anchored-query sample ordering requirement specified:** Implementation shape now states that latest/previous sample must be determined by sorting `addedObjects` by `startDate`, not by relying on raw array order.
- **`trend=String` field added to `hk_observer_fired` log taxonomy:** Logs the actual derived direction string alongside `trend_derived=Bool`. New verification expectation row for trend value validation.
- **Verification expectation wording softened:** Trend coverage expectation changed from ">80%" to "majority" with direction-string validation. Added trend-value validation row.
- **Prerequisite:** Updated to remediation plan v1.38.

### v1.23 — 2026-03-14 | R6.1 spec review fixes — previous-sample persistence, trend format, epoch ordering

- **Previous-sample persistence added:** `hkLastReceivedGlucoseValueMgDl()` / `setHKLastReceivedGlucoseValueMgDl(_:)` added to planned methods (now 6 total). Implementation shape updated to explain persisted previous sample as fallback for single-sample steady-state fires.
- **Trend format and threshold mapping specified:** Raw direction strings (`"Flat"`, `"SingleUp"`, etc.) matching WC path format. Same raw-delta thresholds as `BloodGlucose.Direction.init(trend:)`. Added trend-output sanity check.
- **Epoch-guard ordering corrected:** Fast-exit paths now consistently describe the epoch check as post-query (after anchored query returns), not pre-query. Clarified as edge-case filter for modified/re-delivered samples.
- **Anchor serialization specified:** `NSKeyedArchiver`/`NSKeyedUnarchiver` for `HKQueryAnchor` (`NSSecureCoding`, not `Codable`). Added to persistence-location section and verification prompt.
- **Deletion handling added:** Implementation shape now explicitly states deleted objects from `HKAnchoredObjectQuery` are ignored.
- **Source-predicate risk language tightened:** `HKMetadataKeySyncIdentifier` described as standard Apple key used by multiple diabetes apps. Practical over-inclusion risk acknowledged.
- **Sanity-check wording corrected:** Anchor/epoch/previous-sample helpers use App Group `UserDefaults` (thread-safe); other store APIs remain main-thread-confined. No longer characterizes entire store as thread-agnostic.
- **`fire_id` lifecycle clarified:** Generated once per observer callback, threaded through all subordinate calls.
- **Dual-delivery dedup benefit noted:** Matching raw direction strings can prevent R6 trend-overwrite regression.
- **Inherited unit note added:** HK delta is mg/dL-only; affects dedup for mmol/L users; deferred.
- **Verification prompt expanded:** Items 10 (anchor serialization) and 11 (trend format) added.
- **Prerequisite:** Updated to remediation plan v1.37.

### v1.22 — 2026-03-14 | R6.1 implementation guide added

- **Step 7.1 added:** New `### Step 7.1 — PR: R6.1 (HealthKit Channel Improvements)` section with full planning and specification guidance for the future implementation. This is a docs-only addition; no code changes.
- **Future implementation boundaries documented:** R6.1 scope is the HK fetch/processing path plus `TrioComplicationDataStore` persistence helpers. Authorization flow, observer registration, entitlements, and Info.plist are explicitly out of scope.
- **Persistence-location decision recorded:** HK anchor and last-received epoch belong in `TrioComplicationDataStore`; raw `UserDefaults(suiteName:)` in `WatchState` is forbidden for this feature.
- **Source-predicate decision recorded:** `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)` — no bundle-ID filtering in R6.1.
- **R6.1 log taxonomy added:** 11 events with fields; R6-only event replacements noted; `query_type=anchoredQuery` as discriminator.
- **Sanity checks added:** 5 design/implementation sanity checks for the future implementation.
- **Post-implementation verification expectations added:** 6 observable conditions for BetterStack validation after future deployment.
- **Post-implementation verification prompt added:** 9-point verification prompt for future use.
- **Prerequisite:** Updated to remediation plan v1.36.

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