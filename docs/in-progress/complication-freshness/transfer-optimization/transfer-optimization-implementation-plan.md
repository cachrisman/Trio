# Transfer Optimization — Implementation Plan (Steps 1-4)

**Version:** v1.2
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 15:08 CET
**Status:** COMPLETED — all steps shipped; reachability-gate bug fix shipped (build 142)

**Design:** [transfer-optimization-design.md](transfer-optimization-design.md)

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

### Step 3 — PR: R2b - COMPLETED (build 134, 2026-03-11)

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
> - Observing 48h BetterStack data (no contradiction with "build 134 deployed")
>    - If avg C ≤ 1.3 → R2d is optional; proceed directly to Step 5
>    - If avg C > 1.3 → proceed to Step 4 (R2d)

---

### Step 3b — PR: Complication-age stale-first budget gate - COMPLETED (build 137, 2026-03-12)  

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
  - **Skip-log taxonomy (for BetterStack):** Three queryable categories. Step 3b age-gate skip: `skip_reason=age_gate`. R2b duplicate skip: document as `skip_reason=duplicate_gate` (even if the current log line doesn't include the literal yet). Missing readingEpoch: its own case. Queries filter by: age_gate, duplicate_gate, missing readingEpoch.
  - When transfer is skipped because complication is fresh: log `⏭️ complication_transfer_age_gate_skipped skip_reason=age_gate age_seconds=... threshold_seconds=... gate_key=...`.
  - On successful complication transfer log include: `complication_age_seconds=\(Int(complicationAgeSeconds)) complication_age_gate_threshold_seconds=\(Int(Self.complicationAgeGateThresholdSeconds))`.

**Design note:** We gate only the budget-consuming path so that the 50/day budget is spent when the complication is actually stale. `sendMessage` always fires to keep the watch app UI fresh and has no budget cost.

> ## ✅ CODE REVIEW PASSED; Step 3b deployed (builds 137-138)
> - **Code verified:** `currentComplicationAgeSeconds()` uses exact 4-step pattern (guard suite/defaults → .infinity; lastValid; if nil return .infinity; max(0, …)); no Watch Shared import. Constant `complicationAgeGateThresholdSeconds = 600`. Age gate applied only when `remaining > 0`; budget-exhausted fallback has no age gate. `lastDispatchedGateKey` set only on actual enqueue (transferCurrentComplicationUserInfo or transferUserInfo); not set on age-gate skip or sendMessage-only.
> - **Log taxonomy:** Age-gate skip logs `skip_reason=age_gate` with `age_seconds`, `threshold_seconds`, `gate_key`, `reading_date_epoch_seconds`. Success logs include `complication_age_seconds`, `complication_age_gate_threshold_seconds`.
> - **Deployed:** Step 3b included in builds 137-138 (alongside cloud logging pipeline fixes). Builds 137-138 also fix the build-mislabeling problem in `CloudLogUploader` — avg C per-build queries are now reliable. See `docs/completed/logging-fixes/`.
> - **Observation:** 48h window starts from build 137 deploy (2026-03-12). Run avg C query ~2026-03-15. If avg C <= 1.3 → skip Step 4, proceed to Step 5. If avg C > 1.3 → proceed to Step 4 (R2d). Avg C is measured by the Trio Dashboard "Avg C / reading" chart (metric `complication_c_total_transfers`; see `docs/completed/betterstack/betterstack-complication-dashboard-setup.md` for metric definitions).

---

### Step 4 — PR: R2d (gated on Step 3 data; implement only if avg C > 1.3)

> ## ✅ GATE EVALUATED (2026-03-17) — Step 4 SKIPPED
> BetterStack avg C query (build ≥ 137, S3 + hot, 2026-03-12 onward):
> - Build 141 data (Mar 16): avg C = **1.06** overall, **0.77** budget-ok windows
> - Build 141 data (Mar 17): avg C = **0.98** overall, **0.34** budget-ok windows
> - Both are well below the 1.3 gate threshold.
>
> Mar 12–15 data is dominated by 100% budget exhaustion (0 complication-path transfers, all via userInfo fallback) and mixed-build contamination — not representative of steady-state. Build 141 data is clean.
>
> **R2d will not be implemented.** Proceed directly to Step 5 (R4 — `updateApplicationContext` safety net). See remediation plan v1.53 implementation log for full per-day table.

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

### Bug fix — Reachability gate on `transferUserInfo` fallback — SHIPPED (build 142, 2026-03-19)

**File:** `AppleWatchManager.swift` — `sendDataToWatch` only

**Problem:** The budget-exhausted `transferUserInfo` fallback was nested inside the `!isReachable` gate (see design doc Step 3b code sketch). When `isReachable == true` and budget was exhausted, no background delivery was enqueued for complication refresh.

**What to implement:**

1. **Hoist `budgetSnapshot`** above the `isReachable` block so logging can reference it.

2. **Split the `complication_transfer_skipped_reachable` log** into budget-available vs budget-exhausted:
   ```swift
   if readingEpochPresent, !isDuplicateDispatch {
       if budgetSnapshot > 0 {
           debug(.watchManager, "ℹ️ complication_transfer_skipped_reachable remaining=\(budgetSnapshot)")
       } else {
           debug(.watchManager, "ℹ️ complication_budget_exhausted_reachable remaining=0 — userInfo fallback will enqueue")
       }
   }
   ```

3. **Flatten the `!isReachable` block** to only contain the budgeted path. Add `budgetSnapshot > 0` to the compound condition:
   ```swift
   if !session.isReachable, readingEpochPresent, !isDuplicateDispatch, budgetSnapshot > 0 {
       // age gate -> transferCurrentComplicationUserInfo (unchanged)
   }
   ```

4. **Extract the budget-exhausted fallback** into an independent block with no reachability condition:
   ```swift
   if budgetSnapshot == 0, readingEpochPresent, !isDuplicateDispatch {
       cancelStaleQueuedTransfers()
       session.transferUserInfo([WatchMessageKeys.watchState: complicationMessage])
       lastDispatchedGateKey = gateKey
       // log: via=userInfo budget_exhausted=true
   }
   ```

**Constraints:**
- Do not move `transferCurrentComplicationUserInfo` — stays inside `!isReachable`
- Keep `cancelStaleQueuedTransfers()` immediately before `transferUserInfo`
- Keep `lastDispatchedGateKey = gateKey` only in branches that actually enqueue a transfer
- Do not change the queue-deep drain block

**Acceptance criteria:**
For `isReachable == true`, `budgetSnapshot == 0`, `readingEpochPresent == true`, `isDuplicateDispatch == false`:
- `sendMessage` fires
- `transferUserInfo(complicationMessage)` is enqueued
- `lastDispatchedGateKey` is updated
- No misleading "skipped reachable" log emitted

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

---

## Changelog

### v1.2 (2026-03-19 15:08 CET)

- Updated status to SHIPPED (build 142). BetterStack confirms fix is live.
- Reason: fix was included in patch 09 and deployed as build 142.

### v1.1 (2026-03-19 15:03 CET)

- Added "Bug fix — Reachability gate on `transferUserInfo` fallback" step after Step 4.
- Reason: plan the surgical fix for the budget-exhausted fallback being unreachable when `isReachable == true`.

### v1.0 (2026-03-19 11:33 CET)

- Extracted from complication-freshness-implementation-guide.md v1.14 during docs reorganization.
