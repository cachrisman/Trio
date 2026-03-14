# Age Gate Fix + Diagnostic Logging

**Version:** 1.9 | **Date:** 2026-03-13
**Status:** Implemented
**Prerequisite:** `complication-freshness-implementation-guide.md` v1.11 — Step 3b deployed (builds 137-138)

---

## Problem Summary

Two issues discovered during investigation of permanent budget exhaustion (March 11–13):

1. **`currentComplicationAgeSeconds()` is a structural no-op on iOS.** It reads `TrioComplication_lastValidTimestamp` from the iPhone-side App Group, but only the watch-side `TrioComplicationDataStore` writes that key. With watchOS 7+ independent watch apps, the App Group containers are physically separate stores on different devices. The key is always `nil` on the iPhone, so the function always returns `.infinity`, and the age gate always passes. The gate was designed to conserve budget by skipping transfers when the complication is fresh, but it can never block.

2. **Critical logging blind spots** prevent diagnosing budget issues. `session.remainingComplicationUserInfoTransfers` is only logged after a successful `transferCurrentComplicationUserInfo` call (inside the `remaining > 0` branch). When the budget is 0, no log emits the actual count — you only see `budget_exhausted=true`. Session activation logs omit `isPaired`, `isWatchAppInstalled`, and the budget count.

### Root cause of budget loss (context)

The `transferCurrentComplicationUserInfo` budget (50/day, reset ~04:00 UTC) was working on March 9–11 and permanently stopped resetting on March 12 after what appears to be a WidgetKit complication deregistration triggered by a build deploy. Apple's `remainingComplicationUserInfoTransfers` returns 0 when no complication from the app is on the active watch face — including when watchOS loses track of the WidgetKit complication's registration. This is a known fragility in the WidgetKit + WatchConnectivity integration. See analysis in parent chat for full timeline and evidence.

### Strategic context

`transferCurrentComplicationUserInfo` may be unreliable by design with WidgetKit complications. R4 (`updateApplicationContext`, Step 5 in the remediation plan) is not just a safety net for budget exhaustion — it's the safety net for budget *nonexistence*. The budget-based path is a nice-to-have optimization when Apple happens to make it available, not something to build the architecture around. This plan fixes the age gate and adds diagnostics, but R4 remains the critical path.

**Ship ordering:** This PR should ship before R4 (Step 5) so the diagnostics are in place when R4 behavior is observed. Part A diagnostics are useful immediately; Part B has zero runtime impact while budget is 0.

---

## Changes

### A. Diagnostic logging (4 sites)

All changes in `AppleWatchManager.swift`.

**Expected log volume from A1:** ~600–800 lines/day (coalescer produces ~2 calls per reading × ~288 readings/day). Manageable for BetterStack. Can be reduced to a lower frequency or removed once the budget mystery is resolved.

#### A1. Budget count on every transfer attempt

Add one log line at the top of the complication transfer decision block, **before** any branching. Fires on every `sendDataToWatch` call that reaches the transfer-decision section (past the earlier guards for unpaired watch, missing app, inactive session, and stale-state skip).

**Location:** Before line 790 (`if !session.isReachable, readingEpochPresent, !isDuplicateDispatch`).

```swift
let budgetSnapshot = session.remainingComplicationUserInfoTransfers
debug(.watchManager, "🔍 complication_budget_check remaining=\(budgetSnapshot) isReachable=\(session.isReachable) readingEpochPresent=\(readingEpochPresent) isDuplicate=\(isDuplicateDispatch)")
```

**Note:** The variable is named `budgetSnapshot` (not `remaining`) to avoid shadowing the existing `let remaining = session.remainingComplicationUserInfoTransfers` at line 798 inside the `ageGatePassed` block.

**Queryable field:** `complication_budget_check remaining=`

#### A2. Full session state at activation

Expand the activation log (line 855–856) to include all budget-relevant session properties in a single structured line.

**Replace:**
```swift
debug(.watchManager, "📱 Phone session activated with state: \(activationState.rawValue)")
debug(.watchManager, "📱 Phone isReachable after activation: \(session.isReachable)")
```

**With:**
```swift
debug(.watchManager, "📱 Phone session activated state=\(activationState.rawValue) isReachable=\(session.isReachable) isPaired=\(session.isPaired) isWatchAppInstalled=\(session.isWatchAppInstalled) remaining_budget=\(session.remainingComplicationUserInfoTransfers)")
```

**Queryable field:** `Phone session activated state=`

#### A3. Budget count on reachability change

Add `remaining_budget` to the existing reachability-change log (line 1284).

**Replace:**
```swift
debug(.watchManager, "📱 Phone reachability changed: \(session.isReachable)")
```

**With:**
```swift
debug(.watchManager, "📱 Phone reachability changed: isReachable=\(session.isReachable) remaining_budget=\(session.remainingComplicationUserInfoTransfers)")
```

**Queryable field:** `Phone reachability changed: isReachable=`

#### A4. Log when complication transfer skipped due to reachable

After the existing `sendMessage` log (line 779), add a line noting that the complication transfer path was bypassed because the watch is reachable.

**After** line 779 (`debug(.watchManager, "📤 Transferred new WatchState snapshot via=sendMessage ..."`):

```swift
if readingEpochPresent, !isDuplicateDispatch {
    debug(.watchManager, "ℹ️ complication_transfer_skipped_reachable remaining=\(session.remainingComplicationUserInfoTransfers)")
}
```

**Queryable field:** `complication_transfer_skipped_reachable remaining=`

---

### B. Age gate fix — use iOS-side data instead of cross-device App Group key

**Problem:** `currentComplicationAgeSeconds()` reads `TrioComplication_lastValidTimestamp` from the iPhone's App Group. Only the watch writes this key. The iPhone never sees it. The function always returns `.infinity`.

**Fix:** Derive complication age from the `readingEpoch` embedded in `lastDispatchedGateKey`, which is already persisted on the iPhone side in the same App Group. The gate key format is `"\(epoch)|\(currentGlucose)|\(trend)|\(delta)"` (set by `computeDispatchGateKey`), so the epoch is the first pipe-delimited component.

**Format coupling:** `currentComplicationAgeSeconds()` depends on `computeDispatchGateKey` producing a pipe-delimited string with the epoch as the first component. Add a comment in `computeDispatchGateKey` documenting this dependency:
```swift
/// R2b: Builds a gate key from the complication-visible fields of a WatchState.
/// Matches the watch-side ComplicationSnapshotFingerprint for consistent dual-layer dedup.
/// Format: "epoch|glucose|trend|delta" — currentComplicationAgeSeconds() parses the epoch
/// from the first pipe-delimited component. Do not change the format without updating that function.
```

**Edge case — no glucose values:** When `glucoseValues` is empty, `computeDispatchGateKey` produces `"nil|..."`. `TimeInterval("nil")` returns `nil`, the guard fails, and the function returns `.infinity` (allows the transfer). This is correct behavior.

**Replace the body of `currentComplicationAgeSeconds()`:**

```swift
/// Step 3b: Complication age derived from the reading epoch in lastDispatchedGateKey.
/// Measures "time since the CGM reading we last sent via a complication transfer."
/// Returns .infinity if no gate key is set (first transfer always goes through).
///
/// Limitation: this measures time since iOS *sent* the transfer, not when the watch
/// *received* it. If a transferUserInfo was enqueued but the watch hasn't woken for it,
/// the gate may consider the complication "fresh" when it's actually stale. This only
/// matters in the narrow window after a budget reset where recent transferUserInfo
/// deliveries may not have landed. Part C (updateApplicationContext watch → phone)
/// provides ground-truth by having the watch report back; this gate-key path is the
/// fallback when the watch-reported timestamp isn't available yet.
private func currentComplicationAgeSeconds() -> TimeInterval {
    let gateKey = lastDispatchedGateKey
    guard !gateKey.isEmpty else {
        debug(.watchManager, "🔍 complication_age_check gate_key_empty returning=infinity")
        return .infinity
    }
    guard let epochString = gateKey.split(separator: "|").first,
          let epoch = TimeInterval(epochString), epoch > 0 else {
        debug(.watchManager, "⚠️ complication_age_check gate_key_parse_failed key=\(gateKey) returning=infinity")
        return .infinity
    }
    let readingDate = Date(timeIntervalSince1970: epoch)
    let age = max(0, Date().timeIntervalSince(readingDate))
    debug(.watchManager, "🔍 complication_age_check age_seconds=\(Int(age)) threshold=\(Int(Self.complicationAgeGateThresholdSeconds)) gate_passes=\(age > Self.complicationAgeGateThresholdSeconds) source=lastDispatchedGateKey")
    return age
}
```

**Semantics change (sent vs. received):**

The original design (if it had worked) would have measured "how stale is the complication's *actual* data?" by reading the watch-side `lastValidTimestamp` — ground truth of the last successful save. The fixed version measures "how long since iOS *sent* a complication transfer?" — an iOS-side proxy.

This is a weaker signal. Scenario: budget resets at 04:00 UTC. The last `transferUserInfo` was at 03:58. Gate key epoch = 03:58 reading. At 04:02, new reading arrives, `remaining = 50`. Age gate: `04:02 - 03:58 = 240s < 600s` → gate blocks. But the watch may not have woken for the 03:58 `transferUserInfo`, so the complication could be genuinely stale.

**Accepted trade-off:** This only matters during the narrow window after a budget reset where recent `transferUserInfo` deliveries haven't landed on the watch. In the common case, it correctly prevents burning budget on a reading the complication likely already has. The alternative (cross-device App Group read) is structurally impossible. Part C resolves this limitation fully by having the watch report ground-truth back via `updateApplicationContext`; Part B serves as the fallback until Part C's watch-reported timestamp is available.

**Activation resets the gate key:** `activationDidCompleteWith` (line 859) clears `lastDispatchedGateKey` to `""` so the first post-launch transfer always fires. With Part B, this means `currentComplicationAgeSeconds()` returns `.infinity` immediately after activation, and the first budget transfer bypasses the age gate. This is intentional — after an app restart, the phone has no knowledge of the watch's complication state, so one unconditional transfer is correct. Part C eliminates this gap: `WCSession.receivedApplicationContext` is system-persisted across launches, so even after activation the phone has the watch's last-reported timestamp.

**What changes:** When the budget IS available (`remaining > 0`), the age gate will now actually gate. If the last sent reading is < 600 seconds old, the transfer is skipped. Previously it always passed (`.infinity > 600`). The gate key is written only on actual complication enqueue (`transferCurrentComplicationUserInfo` or `transferUserInfo` fallback), so `sendMessage`-only paths don't contaminate it.

**What doesn't change:** When the budget is 0 (the current permanent state), the age gate is never evaluated. The `else` branch (budget exhausted → `transferUserInfo`) runs unconditionally. This fix has zero impact on the current budget-exhausted behavior.

---

### C. Ground-truth age gate via `updateApplicationContext` (watch → phone)

Part B is an immediate fix using data already available on the iOS side, but it measures "time since iOS *sent*" rather than "time since the watch *saved*." Part C eliminates that gap by having the watch report its actual complication state back to the phone.

#### Why `updateApplicationContext`

Four WCSession APIs can send data from watch to phone. Only one fits:

| API | Delivery | Reachability required | Semantics | Verdict |
|---|---|---|---|---|
| `sendMessage` | Immediate | Yes (both foreground) | Request/response | Age gate matters when watch is *not* reachable — useless |
| `sendMessage` replyHandler (piggyback on phone→watch message) | Immediate | Yes | Response to phone's `sendMessage` | Same problem — only fires when reachable |
| `transferUserInfo` | Queued FIFO | No | Ordered delivery | FIFO queue accumulates stale entries; wrong semantics |
| **`updateApplicationContext`** | **Last-write-wins** | **No** | **Latest state** | **Correct: only the most recent timestamp matters** |

`updateApplicationContext` is background-safe, budget-free, tiny payload, and last-write-wins — exactly the semantics needed for "what is the watch's current complication age?"

#### Watch side (TrioComplicationDataStore.swift + WatchState.swift)

**Placement:** The `updateApplicationContext` call must go inside `saveOnMain` in `TrioComplicationDataStore.swift`, after the confirmed successful write (after line 667: `log("event=complication_save_age ...")`). It cannot be placed after the `save()` call in `WatchState.saveComplicationSnapshot(from:)` because `save()` dispatches to main asynchronously via `onMain` — the caller returns before `saveOnMain` executes, so any code after `save()` runs before the save completes or fails.

**In `TrioComplicationDataStore.saveOnMain`**, after the `event=complication_save_age` log (line 668), add. `snapshot` is the `TrioComplicationSnapshot` parameter of `saveOnMain(_ snapshot:triggerReload:minInterval:)`; its `readingDate` is the CGM reading timestamp. The class uses `log(_ message: String)` (writes to `ComplicationLogBuffer` + optional forwarder), not `debug(.category, ...)` — the catch block below uses the correct call:

```swift
#if os(watchOS)
if WCSession.isSupported(), WCSession.default.activationState == .activated {
    do {
        try WCSession.default.updateApplicationContext([
            "complicationLastValidTimestamp": snapshot.readingDate.timeIntervalSince1970
        ])
        log("event=complication_age_report_sent epoch=\(Int(snapshot.readingDate.timeIntervalSince1970))")
    } catch {
        log("⚠️ complication_age_report_failed error=\(error.localizedDescription)")
    }
} else if WCSession.isSupported() {
    log("event=complication_age_report_skipped activation_state=\(WCSession.default.activationState.rawValue)")
}
#endif
```

This requires adding `import WatchConnectivity` to `TrioComplicationDataStore.swift`, guarded by `#if os(watchOS)`.

**Target membership:** `TrioComplicationDataStore.swift` is compiled into three targets: Trio (iOS), Trio Watch App, and Trio Watch Complication Extension. The `#if os(watchOS)` guard excludes the `WCSession` code from the iOS app target entirely. On watchOS, `WCSession.isSupported()` returns `true` in the watch app but `false` in the complication widget extension, providing the necessary runtime guard.

This fires after every successful complication save — whether the data arrived via `sendMessage`, `transferUserInfo`, `transferCurrentComplicationUserInfo`, or (future) `didReceiveApplicationContext` from R4. By being inside the success path of `saveOnMain`, it only reports when the snapshot was actually persisted, not when it was rejected by dedup or failed due to I/O.

**Activation gap:** If the watch saves a snapshot before `WCSession` has activated (e.g., during early launch while processing a background task), the `activationState` check prevents the call and the timestamp is not reported. In that case, the phone falls back to Part B's gate-key proxy until the next save after activation. This is acceptable — the watch typically activates its session early in launch, and subsequent saves will report correctly.

#### Phone side (AppleWatchManager.swift)

1. Implement the delegate method (logging only — no local storage needed):

```swift
func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    let raw = applicationContext["complicationLastValidTimestamp"]
    let timestamp = (raw as? TimeInterval) ?? (raw as? NSNumber)?.doubleValue
    if let timestamp {
        debug(.watchManager, "📱 complication_age_received_from_watch epoch=\(Int(timestamp)) age_seconds=\(Int(Date().timeIntervalSince(Date(timeIntervalSince1970: timestamp))))")
    }
}
```

No stored property is needed. `WCSession.default.receivedApplicationContext` is system-persisted across app launches — `currentComplicationAgeSeconds()` reads it directly at decision time, which is both simpler and guarantees the freshest available value.

2. Update `currentComplicationAgeSeconds()` to prefer the watch-reported timestamp over the gate key parse.

**Note:** If A+B+C ship together, this is the only version that gets implemented — Part B's standalone code block (above) is reference documentation for the B-only fallback path, not a separate implementation step.

```swift
/// Step 3b: Complication age from the best available source.
/// Prefers ground-truth timestamp from the watch (reported via updateApplicationContext
/// after each successful complication save). Falls back to the reading epoch in
/// lastDispatchedGateKey (iOS-side proxy) when the watch hasn't reported yet.
/// Returns .infinity if neither source has data (first transfer always goes through).
private func currentComplicationAgeSeconds() -> TimeInterval {
    // Prefer ground-truth timestamp from watch (Part C) over iOS-side proxy (Part B)
    let rawTimestamp = WCSession.default.receivedApplicationContext["complicationLastValidTimestamp"]
    let watchTimestamp = (rawTimestamp as? TimeInterval) ?? (rawTimestamp as? NSNumber)?.doubleValue ?? 0
    if watchTimestamp > 0 {
        let age = max(0, Date().timeIntervalSince(Date(timeIntervalSince1970: watchTimestamp)))
        debug(.watchManager, "🔍 complication_age_check age_seconds=\(Int(age)) threshold=\(Int(Self.complicationAgeGateThresholdSeconds)) gate_passes=\(age > Self.complicationAgeGateThresholdSeconds) source=watchApplicationContext")
        return age
    }

    // Fallback: derive from lastDispatchedGateKey (Part B)
    let gateKey = lastDispatchedGateKey
    guard !gateKey.isEmpty else {
        debug(.watchManager, "🔍 complication_age_check gate_key_empty returning=infinity")
        return .infinity
    }
    guard let epochString = gateKey.split(separator: "|").first,
          let epoch = TimeInterval(epochString), epoch > 0 else {
        debug(.watchManager, "⚠️ complication_age_check gate_key_parse_failed key=\(gateKey) returning=infinity")
        return .infinity
    }
    let readingDate = Date(timeIntervalSince1970: epoch)
    let age = max(0, Date().timeIntervalSince(readingDate))
    debug(.watchManager, "🔍 complication_age_check age_seconds=\(Int(age)) threshold=\(Int(Self.complicationAgeGateThresholdSeconds)) gate_passes=\(age > Self.complicationAgeGateThresholdSeconds) source=lastDispatchedGateKey")
    return age
}
```

The `source=watchApplicationContext` vs `source=lastDispatchedGateKey` field in the log makes it easy to verify which path is active in telemetry.

#### Interaction with R4

R4 uses `updateApplicationContext` in the *phone → watch* direction. Part C uses it in the *watch → phone* direction. These are independent — each side of WCSession maintains its own application context. Both can coexist without conflict. Specifically, `session(_:didReceiveApplicationContext:)` on the phone fires only for contexts sent by the *watch*; it does not fire for contexts the phone itself sent via R4.

**Context replacement:** `updateApplicationContext` replaces the entire outgoing dictionary. Part C sends `["complicationLastValidTimestamp": epoch]`. If the watch ever needs to send additional keys via `updateApplicationContext` for other purposes, those calls must merge with the existing context (`var ctx = WCSession.default.applicationContext; ctx["newKey"] = value; try updateApplicationContext(ctx)`) to avoid clobbering Part C's key. Currently the watch has no other `updateApplicationContext` callers, so this is a note for future extensibility, not a current issue.

#### Delivery latency

`updateApplicationContext` delivery is not instant. There can be a lag (seconds to minutes) between the watch saving a snapshot and the phone receiving the updated context. During this window, the phone's age gate uses a slightly stale timestamp. This is strictly better than Part B alone (which can be stale by the entire `transferUserInfo` delivery delay) and vastly better than the original no-op.

#### Ship strategy

Part C can ship in the same PR as A+B or as a follow-up. It touches two files (`TrioComplicationDataStore.swift` + `AppleWatchManager.swift`) vs. the single-file A+B change. If shipping together, the file list and PR scope expand. If shipping separately, Part B's standalone `currentComplicationAgeSeconds()` ships first; Part C's combined version replaces it later.

**Rollback risk:** Parts A and B are observability-only or zero-runtime-impact in the current budget=0 state — rollback risk is negligible. Part C introduces a new `WCSession` delegate method and a `updateApplicationContext` call from a watch-side shared store. If Part C causes unexpected behavior (e.g., interferes with R4 deployment), there is no feature flag to disable it short of another build. Risk is accepted: the payload is a single additive key, the phone-side delegate is read-only (logging only), and the ship-before-R4 ordering means any issue surfaces before R4 complicates the picture.

---

## File list

| File | Changes |
|---|---|
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | A1–A4, B, C (phone side: delegate + age function) |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | C (watch side: `updateApplicationContext` in `saveOnMain`) |

Single PR if shipping A+B+C together; or split into two PRs (A+B, then C) if preferred.

---

## Validation

### BetterStack queries (post-deploy)

**A1 — Verify budget count is logged:**
```sql
SELECT dt, msg FROM ... WHERE msg LIKE '%complication_budget_check remaining=%' ORDER BY dt DESC LIMIT 10
```
In the current broken state, expect `remaining=0` on most or all lines. Once budget availability returns (e.g., after a watch face toggle or WidgetKit re-registration), mixed values may appear.

**A2 — Verify activation logs full state:**
```sql
SELECT dt, msg FROM ... WHERE msg LIKE '%Phone session activated state=%' ORDER BY dt DESC LIMIT 5
```
Expect `isPaired=true isWatchAppInstalled=true remaining_budget=0`.

**B/C — Verify age gate source selection** (confirms which data path is active, not that the timestamp is current at every decision point — delivery lag means the value can be seconds to minutes behind):
```sql
SELECT dt, msg FROM ... WHERE msg LIKE '%complication_age_check%' ORDER BY dt DESC LIMIT 10
```
- Before C: expect `source=lastDispatchedGateKey` or `gate_key_empty returning=infinity`.
- After C: expect `source=watchApplicationContext` once the watch has sent at least one `updateApplicationContext`. If the watch-side context hasn't arrived yet (e.g., first launch), falls back to `source=lastDispatchedGateKey`.

**C — Verify watch → phone context delivery** (confirms the reporting path is active):
```sql
SELECT dt, msg FROM ... WHERE msg LIKE '%complication_age_received_from_watch%' ORDER BY dt DESC LIMIT 10
```
Expect `epoch=...` entries appearing after watch-side complication saves. Absence of entries after a known save indicates the activation-gap edge case or a delivery issue.

### Watch face toggle test (manual)

After deploy, switch watch face away and back. Then check:
```sql
SELECT dt, msg FROM ... WHERE msg LIKE '%complication_budget_check remaining=%' AND msg NOT LIKE '%remaining=0%' ORDER BY dt DESC LIMIT 5
```
Any row = budget restored. Empty = WidgetKit deregistration persists despite face toggle.

---

## Implementation log

Implemented on `feature/watch-complication-improvements` branch in the Trio worktree.

### Initial implementation (against v1.6 plan)

All A+B+C changes implemented together. Two files modified:

| File | Changes |
|---|---|
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | A1 (`budgetSnapshot` log), A2 (consolidated activation log), A3 (`remaining_budget` on reachability), A4 (`complication_transfer_skipped_reachable`), B (`computeDispatchGateKey` doc comment), B+C (combined `currentComplicationAgeSeconds()`), C (`didReceiveApplicationContext` delegate) |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | C (`import WatchConnectivity`, `updateApplicationContext` in `saveOnMain` after successful write) |

### Post-implementation code review fixes (v1.7)

ChatGPT code review of the implementation identified one major risk and two minor issues. All three addressed:

1. **Target membership risk (MAJOR):** `TrioComplicationDataStore.swift` is compiled into Trio (iOS), Trio Watch App, and Trio Watch Complication Extension. The bare `import WatchConnectivity` and `WCSession.default` calls would compile on iOS (wrong direction — phone → watch) and execute in the complication widget extension (invalid context). Fixed with `#if os(watchOS)` around the import and code block, plus `WCSession.isSupported()` runtime guard for the widget extension.
2. **Silent success path:** Watch-side `updateApplicationContext` logged failures but not successes, making field validation ambiguous (can't distinguish "never attempted" from "attempted but delivery lagged"). Added `event=complication_age_report_sent` success log.
3. **Brittle payload typing:** Phone-side `as? TimeInterval` cast on cross-process dictionary value is optimistic about bridging. Made defensive with `NSNumber` fallback: `(raw as? TimeInterval) ?? (raw as? NSNumber)?.doubleValue ?? 0`.

### Post-implementation code review polish (v1.9)

Claude code review of the v1.8 implementation identified no critical issues. Two items addressed:

1. **Budget branch re-read:** `budgetSnapshot` was captured for the A1 log, but the branch condition immediately below re-read `session.remainingComplicationUserInfoTransfers` live. The counter could theoretically change between the two reads. Changed the branch to use `budgetSnapshot > 0` so the log unambiguously reflects the value that was branched on.
2. **NSNumber bridging comment:** The watch writes a Swift `Double`, which WCSession bridges as `NSNumber` across the process boundary. The `as? TimeInterval` direct cast likely always misses; the `NSNumber` fallback is the path that actually succeeds. Added a comment documenting this so a future reader doesn't remove the "unnecessary" fallback.

### Post-implementation code review polish (v1.8)

ChatGPT follow-up review approved the v1.7 fixes. Three minor nits addressed:

1. **Inconsistent parse in delegate:** `didReceiveApplicationContext` used `as? TimeInterval` while `currentComplicationAgeSeconds()` used the defensive `NSNumber` fallback. Made consistent.
2. **Stale comment:** Comment above transfer block still said "to avoid unnecessary App Group reads" — no longer accurate after Part B+C replaced the App Group read. Reworded.
3. **Silent activation skip:** Watch-side `updateApplicationContext` now logs success and failure, but still said nothing when `activationState != .activated`. Added `event=complication_age_report_skipped` log with activation state.

---

## Review findings (post-implementation code review, round 3)

External review by Claude of the v1.8 implementation. Verdict: no critical issues.

| # | Source | Severity | Finding | Disposition |
|---|---|---|---|---|
| CR7 | Claude | MINOR | `budgetSnapshot` captured for A1 log but branch re-reads `session.remainingComplicationUserInfoTransfers` live. Counter could change between reads; log wouldn't reflect actual decision. | **Fixed.** Changed branch to `if budgetSnapshot > 0`. Log now unambiguously records the value that was branched on. |
| CR8 | Claude | MINOR | `NSNumber` fallback is actually the *correct* cast path (WCSession bridges Swift `Double` as `NSNumber`). `as? TimeInterval` is likely dead code. Worth a comment so future readers don't remove the fallback. | **Fixed.** Added comment in `currentComplicationAgeSeconds()` documenting the bridging behavior. |

---

## Review findings (post-implementation code review, round 2)

Follow-up review by ChatGPT after v1.7 fixes. Verdict: approved with minor nits.

| # | Source | Severity | Finding | Disposition |
|---|---|---|---|---|
| CR4 | ChatGPT | MINOR | `didReceiveApplicationContext` uses `as? TimeInterval` while `currentComplicationAgeSeconds()` uses `NSNumber` fallback — inconsistent. | **Fixed.** Made delegate parse match: `(raw as? TimeInterval) ?? (raw as? NSNumber)?.doubleValue`. |
| CR5 | ChatGPT | MINOR | Comment "to avoid unnecessary App Group reads" is stale — no longer reading App Group. | **Fixed.** Reworded to reference `receivedApplicationContext` and `lastDispatchedGateKey`. |
| CR6 | ChatGPT | MINOR | Watch-side `activationState != .activated` path is silent. Cannot distinguish "save before activation" from "attempted and failed." | **Fixed.** Added `event=complication_age_report_skipped activation_state=` log on the `else if WCSession.isSupported()` branch. |

---

## Review findings (post-implementation code review, round 1)

External review by ChatGPT of the implemented code.

| # | Source | Severity | Finding | Disposition |
|---|---|---|---|---|
| CR1 | ChatGPT | MAJOR | `TrioComplicationDataStore.swift` is in three targets (Trio iOS, Watch App, Watch Complication Extension). `import WatchConnectivity` and `WCSession.default` calls compile on iOS (wrong transfer direction) and execute in the widget extension (invalid WCSession context). | **Fixed.** Wrapped import in `#if os(watchOS)`. Wrapped code block in `#if os(watchOS)` + `WCSession.isSupported()` runtime guard. iOS target: compiled out entirely. Widget extension: compiles but `isSupported()` returns false at runtime. |
| CR2 | ChatGPT | MINOR | Watch-side success path is silent — only failures are logged. Cannot distinguish "never attempted" from "attempted, delivery lagged" when phone-side receipt logs are missing. | **Fixed.** Added `log("event=complication_age_report_sent epoch=...")` after successful `updateApplicationContext` call. |
| CR3 | ChatGPT | MINOR | Phone-side `as? TimeInterval` cast on `receivedApplicationContext` value is optimistic about cross-process dictionary bridging. `NSNumber` intermediary is more defensive. | **Fixed.** Changed to `(raw as? TimeInterval) ?? (raw as? NSNumber)?.doubleValue ?? 0`. |

---

## Review findings (v1.3 → v1.4)

Self-review. Verified plan claims against actual code in `TrioComplicationDataStore.swift`, `WatchState.swift`, and `AppleWatchManager.swift`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| S1 | MODERATE | Part C watch-side `updateApplicationContext` was placed after `save()` in `WatchState.saveComplicationSnapshot`. But `save()` dispatches to main asynchronously via `onMain` — the caller returns immediately and the actual write happens later on main. The timestamp would be reported before the save succeeds or fails. If `saveOnMain` rejects the snapshot (dedup), the phone gets a stale-but-conservative timestamp. If `saveOnMain` fails (I/O error, rare), the phone gets a timestamp for data the complication doesn't have. | **Fixed.** Moved the `updateApplicationContext` call inside `saveOnMain` in `TrioComplicationDataStore.swift`, after the confirmed successful write. This guarantees the timestamp is only reported when the snapshot was actually persisted. File list updated to reflect the new file. |
| S2 | MINOR | Plan shows two `currentComplicationAgeSeconds()` implementations: Part B standalone and Part C combined. If A+B+C ship together, only Part C's version is implemented. An implementer reading only Part B would produce the wrong function. | **Fixed.** Added note to Part C clarifying that if A+B+C ship together, Part B's code block is reference documentation, not a separate implementation step. Added note to ship strategy about which version ships in each case. |
| S3 | MINOR | Part C combined `currentComplicationAgeSeconds()` had only an inline `//` comment. Part B's version has a proper `///` doc comment. The doc comment would be lost when Part C replaces Part B. | **Fixed.** Added `///` doc comment to Part C's combined version. |
| S4 | MINOR | `updateApplicationContext` replaces the entire outgoing dictionary. If the watch later uses it for other keys, Part C's call would clobber them. Currently no other callers. | **Documented.** Added "Context replacement" note to the R4 interaction section with the merge pattern for future callers. |

---

## Review findings (v1.2 → v1.3)

External review by ChatGPT and Claude. Findings consolidated and evaluated against the actual code.

| # | Source | Severity | Finding | Disposition |
|---|---|---|---|---|
| R1 | ChatGPT | BLOCKER-ish | Part B depends on `lastDispatchedGateKey`, but `activationDidCompleteWith` (line 859) clears it to `""`. First post-activation send bypasses the age gate even if a fresh transfer was just sent. Plan didn't mention this. | **Accepted with documentation.** The clear-on-activation is intentional (existing comment: "so the first post-launch transfer always fires"). After restart, the phone has no knowledge of the watch's complication state, so one unconditional transfer is correct. Added explicit "Activation resets the gate key" paragraph to Part B. Part C eliminates this gap entirely since `receivedApplicationContext` is system-persisted across launches. |
| R2 | ChatGPT + Claude | BLOCKER | Part C's `lastReceivedComplicationTimestamp` has a no-op setter, but `didReceiveApplicationContext` assigns to it — dead code. The getter reads `receivedApplicationContext` directly, so the property wrapper is misleading. | **Fixed.** Removed the pseudo-property entirely. The delegate method now only logs. `currentComplicationAgeSeconds()` reads `WCSession.default.receivedApplicationContext` directly at decision time. |
| R3 | ChatGPT | MODERATE | Watch-side `updateApplicationContext` only fires when `activationState == .activated`. If a snapshot is saved before activation, the report is dropped. Plan overstates with "the phone always gets ground truth." | **Fixed.** Added "Activation gap" note to Part C watch side. Weakened "always" claim. When the watch misses a report, the phone falls back to Part B's gate-key proxy. |
| R4 | ChatGPT | MODERATE | Validation over-promises — says "expect `source=watchApplicationContext`" but delivery lag means the timestamp can be stale. Proves path is active, not correctness. | **Fixed.** Reworded validation queries to say "verify source selection" and "confirms the reporting path is active" rather than implying the timestamp is guaranteed current. |
| R5 | Claude | BLOCKER | A1 declares `let remaining` at outer scope; existing `let remaining` at line 798 inside `ageGatePassed` block causes a name collision (shadowing, compiler warning). | **Fixed.** Renamed A1 variable to `budgetSnapshot` with explanatory note. |
| R6 | Claude | MODERATE | Part C watch-side `try?` silently swallows `updateApplicationContext` errors. Failure to report is invisible in telemetry. | **Fixed.** Replaced `try?` with `do/catch` that logs the error via `WatchLogger`. |
| R7 | Claude | MODERATE | A4 guard allegedly missing `session.isReachable`. | **Rejected.** A4 is placed inside the `if session.isReachable { ... }` block (lines 775–780), so reachability is already guaranteed by the enclosing scope. The `readingEpochPresent` check prevents firing when there's no glucose data. Guards are sufficient as written. |
| R8 | ChatGPT | NON-BLOCKER | A1 could be narrowed to suppress irrelevant cases (no readingEpoch, etc.). | **Accepted as-is.** Already addressed in v1.1 review (NB2) with volume estimate. The unconditional nature is the point — it reveals budget state even in paths that don't reach the complication block. Can be narrowed later once the budget mystery is resolved. |

---

## Review findings (v1.0 → v1.1)

| # | Severity | Finding | Disposition |
|---|---|---|---|
| B1 | BLOCKER | A5 is dead code — Part B replaces the same function in the same PR. A5's intermediate version never ships. | **Fixed.** Removed A5 as a standalone section. Part B's implementation includes diagnostic logging on all paths (empty gate key, parse failure, success), which subsumes A5's diagnostic intent. |
| B2 | BLOCKER | Age gate semantics shift from "how stale is the complication's actual data" (watch-side ground truth) to "how long since iOS sent a transfer" (iOS-side proxy). After a budget reset, the gate could block a budget transfer if a recent `transferUserInfo` wasn't received by the watch. | **Accepted with documentation.** Added doc comment on the function, explicit trade-off section in Part B, and concrete scenario description. The original cross-device design is structurally impossible. This is the best available iOS-side signal, and the edge case only matters in the narrow window after budget reset. |
| NB1 | NON-BLOCKER | Gate key format coupling — `currentComplicationAgeSeconds()` parses `lastDispatchedGateKey` by splitting on `\|`. If `computeDispatchGateKey` changes format, the parse silently fails (returns `.infinity` — age gate never blocks, regressing to the current no-op). | **Fixed.** Added doc comment on `computeDispatchGateKey` noting the format dependency. Documented the `"nil\|..."` edge case (no glucose values → parse fails → `.infinity` → correct). |
| NB2 | NON-BLOCKER | A1 fires on every `sendDataToWatch` call (~600–800 lines/day). | **Accepted with note.** Added volume estimate to Part A header. Manageable for BetterStack; can be reduced or removed once budget mystery is resolved. |
| NB3 | NON-BLOCKER | No stated ordering relative to R4 (Step 5). | **Fixed.** Added ship-ordering note to Strategic context: this PR ships before R4 so diagnostics are in place when R4 behavior is observed. |

---

## Changelog

### v1.9 — 2026-03-13
- **CR7 fix:** Changed budget branch from `session.remainingComplicationUserInfoTransfers > 0` to `budgetSnapshot > 0` so the logged value matches the branching decision.
- **CR8 fix:** Added comment in `currentComplicationAgeSeconds()` documenting that WCSession bridges Swift `Double` as `NSNumber`, so the `NSNumber` fallback is the path that actually succeeds.
- **Post-implementation code review round 3 findings table:** Added CR7–CR8 (Claude review).

### v1.8 — 2026-03-13
- **CR4 fix:** Made `didReceiveApplicationContext` delegate parse consistent with `currentComplicationAgeSeconds()` — both now use `NSNumber` fallback chain.
- **CR5 fix:** Rewrote stale comment "to avoid unnecessary App Group reads" to reference `receivedApplicationContext` and `lastDispatchedGateKey`.
- **CR6 fix:** Added `event=complication_age_report_skipped` log on watch side when `WCSession.isSupported()` but `activationState != .activated`.
- **Post-implementation code review round 2 findings table:** Added CR4–CR6.
- **Plan code blocks updated:** Watch-side block now includes `else if` skip log; phone-side delegate block now uses defensive parse.

### v1.7 — 2026-03-13
- **Status:** Changed from Draft to Implemented. All A+B+C changes applied to `feature/watch-complication-improvements`.
- **CR1 fix (MAJOR):** Added `#if os(watchOS)` around `import WatchConnectivity` and the `updateApplicationContext` code block in `TrioComplicationDataStore.swift`. Added `WCSession.isSupported()` runtime guard. The file is compiled into Trio (iOS), Trio Watch App, and Trio Watch Complication Extension — without the guard, the code would compile on iOS (wrong direction) and execute in the widget extension (invalid context). Added "Target membership" paragraph to Part C watch side.
- **CR2 fix:** Added `event=complication_age_report_sent` success log to watch-side `updateApplicationContext` block.
- **CR3 fix:** Made phone-side `receivedApplicationContext` timestamp parse defensive with `NSNumber` fallback.
- **Implementation log:** Added section documenting the implementation and post-implementation code review fixes.
- **Post-implementation review findings table:** Added with CR1–CR3.

### v1.6 — 2026-03-13
- **Part C watch side:** Confirmed `snapshot` is the `TrioComplicationSnapshot` parameter of `saveOnMain` and `log()` is the correct logging call for `TrioComplicationDataStore`. Added explicit note to plan.
- **R4 interaction:** Added sentence clarifying `didReceiveApplicationContext` on the phone only fires for watch → phone contexts.
- **Rollback risk:** Added note to ship strategy acknowledging no feature flag for Part C; accepted because payload is additive and phone-side is read-only.

### v1.5 — 2026-03-13
- **A1 wording:** Tightened "fires on every `sendDataToWatch` call" to "fires on every call that reaches the transfer-decision section" (past earlier guards for unpaired/missing/inactive/stale).
- **A1 validation:** Softened "expect `remaining=0` on every line" to "expect mostly/all zeros in the current broken state; mixed values may appear once budget returns."

### v1.4 — 2026-03-13
- **S1 fix:** Moved Part C watch-side `updateApplicationContext` from `WatchState.saveComplicationSnapshot` (after async `save()`) into `TrioComplicationDataStore.saveOnMain` (after confirmed successful write). Prevents reporting timestamps for rejected or failed saves. File list updated: `WatchState.swift` → `TrioComplicationDataStore.swift`.
- **S2 fix:** Added note to Part C that Part B's standalone code block is reference documentation if A+B+C ship together.
- **S3 fix:** Added `///` doc comment to Part C's combined `currentComplicationAgeSeconds()`.
- **S4 documented:** Added "Context replacement" note about `updateApplicationContext` replacing the entire outgoing dictionary.
- **Ship strategy:** Updated file references and added note about which `currentComplicationAgeSeconds()` version ships in each strategy.
- **Review findings table (v1.3 → v1.4):** Added with 4 self-review findings.

### v1.3 — 2026-03-13
- **R1 disposition:** Added "Activation resets the gate key" paragraph to Part B documenting the intentional `lastDispatchedGateKey` clear on activation and why the one-time bypass is correct. Noted Part C eliminates this gap.
- **R2 fix:** Removed `lastReceivedComplicationTimestamp` pseudo-property with no-op setter. Delegate now only logs. `currentComplicationAgeSeconds()` reads `receivedApplicationContext` directly.
- **R3 fix:** Added "Activation gap" note to Part C watch side. Weakened "always gets ground truth" to acknowledge the edge case.
- **R4 fix:** Reworded validation queries to say "verify source selection" / "confirms reporting path is active."
- **R5 fix:** Renamed A1 variable from `remaining` to `budgetSnapshot` to avoid shadowing the inner declaration at line 798.
- **R6 fix:** Replaced Part C watch-side `try?` with `do/catch` + `WatchLogger` error log.
- **R7 rejected:** A4 guard is already inside the `isReachable` block; adding `session.isReachable` would be redundant.
- **Review findings table (v1.2 → v1.3):** Added with all 8 findings from ChatGPT and Claude reviews.

### v1.2 — 2026-03-13
- **Part C added:** Ground-truth age gate via `updateApplicationContext` (watch → phone). Watch reports `complicationLastValidTimestamp` after every successful complication save; phone reads it from `receivedApplicationContext` and prefers it over the Part B gate-key proxy. Includes watch-side change (`WatchState.swift`), phone-side delegate + updated `currentComplicationAgeSeconds()`, interaction notes with R4, delivery latency discussion, and ship strategy options.
- **File list updated:** Now includes `WatchState.swift` for Part C.
- **Validation updated:** Added C-specific BetterStack query; updated B query to distinguish `source=watchApplicationContext` vs `source=lastDispatchedGateKey`.

### v1.1 — 2026-03-13
- **B1 fix:** Removed A5 (dead code). Part B subsumes A5's diagnostic logging. Section count changed from "5 sites" to "4 sites."
- **B2 disposition:** Added semantics-shift trade-off section to Part B with concrete scenario, doc comment on the function, and explicit acceptance rationale.
- **NB1 fix:** Added format-dependency doc comment on `computeDispatchGateKey`. Documented `"nil|..."` edge case.
- **NB2 note:** Added A1 volume estimate (~600–800 lines/day) to Part A header.
- **NB3 fix:** Added ship-ordering note: this PR ships before R4.
- **Validation:** Updated A5/B query section to reflect Part B only (no A5).
- **Review findings table:** Added to record all findings and dispositions.

### v1.0 — 2026-03-13
- Initial draft. Five diagnostic logging sites (A1–A5) and age gate fix (B) derived from budget investigation session.
