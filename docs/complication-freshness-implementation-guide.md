# Cursor Round 2: Audit Results + Implementation Guide
**Version:** 1.4 | **Date:** 2026-03-10
**Prerequisite:** `complication-freshness-remediation-plan.md` v1.19 — all prompts resolved, plan is implementation-ready

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

BetterStack validation query must filter `transfer_path IN ('complication', 'userInfo')` — not `attempted = true`.

> ## 🛑 STOP — Code Review + Build/Deploy
> Before proceeding:
> 1. **Code review** this PR — verify gate is scoped to complication transfer only (not `sendMessage`), and `computeDispatchGateKey` uses `max(by: date)`
> 2. **Build and deploy** to device
> 3. **Observe 48h BetterStack data:**
>    - If avg C ≤ 1.3 → R2d is optional; proceed directly to Step 5
>    - If avg C > 1.3 → proceed to Step 4 (R2d)

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

### Step 5 — PR: R4 (App Group safety net, after R3)

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

## Quick Reference: New Properties on `BaseWatchManager`

| Property | Type | Initial | Purpose |
|---|---|---|---|
| `hasPerformedStartupQueueDrain` | `Bool` | `false` | R1b: one-time activation drain |
| `lastQueueDeepDrainAt` | `TimeInterval` | `0` | R1b: 60s cooldown for queue-deep drain path |
| `coalescerTriggerCount` | `Int` | `0` | R2a: reset after each coalescer fire |
| `coalescerSources` | `[String]` | `[]` | R2a: reset after each coalescer fire |
| `lastEligibleSourceAt` | `TimeInterval` | `0` | R2a/R2d: set when eligible source triggers; reset after fire |
| `complicationEligibleSources` | `Set<String>` | `["glucoseStored","glucoseUpdate"]` | R2a/R2d: defined in Step 2, used in Step 4 |

## Quick Reference: New Shared Helpers (add to `AppleWatchManager.swift`)

```swift
private func sessionIsReadyForTransfer() -> Bool   // define first
private func cancelStaleQueuedTransfers()           // uses sessionIsReadyForTransfer()
```

`sessionIsReadyForTransfer()` must be defined before `cancelStaleQueuedTransfers()` and before the R2d transfer block.

## Quick Reference: Confirmed Symbols

| Symbol | Location | Notes |
|---|---|---|
| `readingDate` | `TrioComplicationSnapshot`, `TrioWatchComplicationEntry` | CGM reading time; `date` is creation/display time |
| `TrioComplicationDataStore.complicationKind` | `TrioComplicationDataStore.swift` line 147 | = `"TrioWatchComplication"` — use constant |
| `session(_:didReceiveApplicationContext:)` | Add to `WatchState.swift` after line ~403 | Under `// MARK: - WCSessionDelegate` |

---

## Changelog

### v1.4 — 2026-03-10
- **Step 2 COMPLETED:** Marked Step 2 (R2a + R3) as completed with build 133 gate-passed block. Documented post-review fixes (queue-deep drain placement, count guard, fallback warning, drain log detail).
- **Prerequisite reference:** Updated to remediation plan v1.19.

### v1.3 — 2026-03-09
- **Step 1 COMPLETED:** Marked Step 1 (R1a + R1b + R5e) as completed with build 132 gate-passed block. Documented BetterStack verification results.

### v1.2 — 2026-03-09
- Initial version with all 6 implementation steps.