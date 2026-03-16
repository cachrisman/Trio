# Trio watchOS Complication — Freshness Remediation Plan

**Version:** 1.52 | **Date:** 2026-03-16
**Status:** ✅ Build 141 built and deployed (patch 09: R5c/R5b corrections); R6 shipped and live (build 140); R6.1 + R5f + R5c + R5b implemented; delta/trend fix and doc accuracy pass applied; post-review R5c attribution and R5b verification applied; R5c follow-up (ChatGPT + Claude) cleanups applied; observing 48h from build 137 deploy (2026-03-12) before Step 4 decision gate
**Source data:** BetterStack source_id=1659391, build 131, 2026-03-08/09
**Input documents:**
- Next-Steps Report (AI/BetterStack analysis, 2026-03-09)
- ChatGPT critiques #1–#7 (on Next-Steps Report and Remediation Plan v1.2–v1.7)
- Cursor codebase audit — Round 1 (prompts R1a, R2a–c, R3a–c, R4, R5d), 2026-03-09
- Cursor codebase audit — Round 2 (prompts R4b, R5d-kind, R5d-snapshot, R5f-getTimeline), 2026-03-09
- Cursor plan-review pass (6 issues identified, all fixed in v1.10), 2026-03-09
- `complication-freshness-implementation-plan.md` v1.27 (prior plan — referenced throughout)

→ See [Changelog](#changelog) at the end of this document.

---

## Naming Convention

Phases in this document are prefixed **R** (Remediation) to avoid collision with the prior plan.

| Plan | Phase namespace | Scope |
|---|---|---|
| `complication-freshness-implementation-plan.md` v1.27 | FP-Phase 0 through FP-Phase 3 | Instrumentation, BGTask hardening, dedup/fingerprint — **complete as of build 131** |
| **This document** | **R1 through R6** | Budget exhaustion, redundant triggers, payload size, reconnect safety net, observability, HealthKit background delivery |

When referencing the prior plan's work in code comments or PRs, use `FP-Phase`. When referencing this plan, use `R1`–`R6`.

**Implementation guide step numbering:** Step 5 = R4 (applicationContext safety net). Step 7 = R6 (HealthKit background delivery).

---

## Key File Reference

All line numbers are approximate — verify before implementing.

| Symbol | File | Approx. line | Notes |
|---|---|---|---|
| `watchStateToDictionary` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~474 | `"date"` key = **build time, not CGM reading time** — see R3 comment guidance |
| `sendDataToWatch` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~545 | Reading epoch computed here (~573) for logging only — not in dict |
| `scheduleWatchStateUpdate` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~517 | `private` on `final class BaseWatchManager`; debounce hardcoded ~529 |
| Publisher subscriptions | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | 85, 92, 103, 110, 123, 129, 1531, 1543 | 8 total call sites |
| `WatchState` (iOS model) | `Trio/Sources/Models/WatchState.swift` | 4–13 | `currentGlucose: String?`, `trend: String?`, `delta: String?` |
| `WatchMessageKeys` | `Trio/Sources/Models/WatchMessageKeys.swift` | — | String key constants; new keys added here |
| `ComplicationSnapshotFingerprint` | `Trio Watch Shared/TrioComplicationDataStore.swift` | — | Defined in FP-Plan §"Shared definitions", implemented FP-Phase 3.0; **watch extension target only** |
| `processRawDataForWatchState` | `Trio Watch App Extension/WatchState.swift` | ~542 | Extracts dict keys; builds `TrioComplicationSnapshot` |
| `saveComplicationSnapshot` | `Trio Watch App Extension/WatchState.swift` | ~664 | Calls `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` |
| `didReceiveUserInfo` | `Trio Watch App Extension/WatchState.swift` | ~286 | Watch app extension process; sets `lastUserInfoReceivedAt` (~331) |
| `didReceiveMessage` | `Trio Watch App Extension/WatchState.swift` | ~230 | Watch app extension process |
| `lastUserInfoReceivedAt` | `Trio Watch App Extension/WatchState.swift` | ~102 | `private var Date?`; in-memory only; needs App Group persistence for R5d |
| `saveOnMain` | `Trio Watch Shared/TrioComplicationDataStore.swift` | ~507 | Authoritative dedup gate from FP-Phase 3.1 |
| `save(_ snapshot:)` | `Trio Watch Shared/TrioComplicationDataStore.swift` | ~581 | Accepts `TrioComplicationSnapshot` directly |
| `fetchGlucose` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~415 | Fetches up to 288 entries (limit at ~422) |
| `getTimeline` | `Trio Watch Complication/TrioWatchComplication.swift` | ~152 | WidgetKit process — **no WCSession access**; reads App Group only |
| `sessionIsReadyForTransfer()` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | new | Shared helper — add alongside `cancelStaleQueuedTransfers()`; used by R1b and R2d |

---

## 0. Problem Summary

The Trio watchOS complication displays the current CGM glucose reading and recency age. The goal is for it to always show the latest reading within a few minutes of acquisition.

**Structural problem:** `transferCurrentComplicationUserInfo` has a hard Apple limit of 50 transfers per day. The current code burns through this in 108–147 minutes due to redundant triggers. Once exhausted, the fallback is a 46-item-deep stale `transferUserInfo` queue that never drains.

**Root cause hierarchy — confirmed by BetterStack telemetry + Cursor code audit:**

1. **Six publishers** fire `scheduleWatchStateUpdate()` per CGM reading (`AppleWatchManager.swift` lines 85, 92, 103, 110, 123, 129). The 2s coalescer handles same-tick publishers but waves >2s apart produce 2–3 `transferCurrentComplicationUserInfo` calls per reading.
2. **No queue cancellation** before fallback: `outstandingUserInfoTransfers` grows to 46–48 items and is never cleared (lines 590, 594 — count read for logging only).
3. **Oversized payload:** `watchStateToDictionary` includes a 288-entry `glucoseValues` array (~18.7 KB of ~19–20 KB total). The complication needs only 5–6 scalar fields (~200 bytes).
4. **No reconnect safety net:** No mechanism to deliver the current reading during the 2–3 hour exhaustion windows. The complication is a WidgetKit extension and **cannot use `WCSession`** — the safety net must operate via the App Group shared container.

**Build 131 baseline (budget-ok window 04:00–06:27 UTC 2026-03-09):**

| Metric | Value |
|---|---|
| Avg complication transfers/reading | 2.85x (ideal: 1.0x) |
| Budget drain rate (Cycle 2) | 20.4/hr → exhausted in 147 min |
| Budget exhaustion cycles in first 8 hours | 2 |
| queue_depth throughout | 46–48 (frozen since pre-build-131) |
| save_age p90 | 289s |
| reload_age p90 | 558s |

> **Arithmetic note:** The 2.85x average is across all post-131 readings. Per-cycle drain rates (2.32x Cycle 1, 1.70x Cycle 2) reflect those specific windows — Cycle 2's lower rate reflects overnight hours with more single-transfer readings. The "87 min theoretical" figure uses the global 2.85x average as a ceiling, not a per-cycle prediction.

---

## R1 — Add Reading Epoch to Payload + Cancel Stale Queue

**Priority:** P0 — CRITICAL | **Effort:** ~3 hrs | **Standalone:** Yes
**Files:** `AppleWatchManager.swift`, `WatchMessageKeys.swift`

### Problem

Every `session.transferUserInfo()` call in the budget-exhausted fallback enqueues a new item without cancelling prior outstanding transfers. Queue confirmed frozen at 46–48 items since before build 131; grew to 48 during Cycle 1.

**Key finding from R1a audit:** The top-level `"date"` key in `watchStateToDictionary` is `WatchState.date = Date()` at state-build time — **not the CGM reading date**. The reading epoch is only computed at `sendDataToWatch` line ~573 for logging and is never placed in the transfer dictionary. R1a must add this as a new dedicated key.

> **Impact scope:** Queue cancellation reduces stale-delivery bursts on watch reconnect and prevents unbounded queue growth during exhaustion. It does **not** directly reduce `transferCurrentComplicationUserInfo` calls — that is R2's job.

### R1a — Add reading epoch and enqueue timestamp keys

Add to `WatchMessageKeys.swift`:

```swift
static let readingEpoch = "reading_epoch"           // CGM reading timestamp (TimeInterval)
static let transferEnqueuedAt = "transfer_enqueued_at"  // Transfer enqueue wall time (TimeInterval)
```

In `watchStateToDictionary(from:)`, add the CGM reading epoch:

```swift
// Use max(by: date) rather than .first to avoid assuming glucoseValues is sorted newest-first.
// .first is a load-bearing assumption — if array order isn't guaranteed, gate keys and
// readingEpoch will flap on the same reading, defeating dedup and inflating transfer counts.
if let newestReading = state.glucoseValues.max(by: { $0.date < $1.date }) {
    dict[WatchMessageKeys.readingEpoch] = newestReading.date.timeIntervalSince1970
}
```

In `sendDataToWatch()`, stamp the enqueue time immediately before the transfer calls:

```swift
message[WatchMessageKeys.transferEnqueuedAt] = Date().timeIntervalSince1970
```

### R1b — Cancel stale transfers before fallback enqueue

**Two triggers for cancellation (not just budget-exhausted):**

1. **On startup / session activation** — drain the frozen queue once on first use after app launch
2. **On every `transferUserInfo` enqueue** — cancel stale items before adding a new one

**Policy:** Keep exactly 1 transfer — the newest by `transferEnqueuedAt` within the latest `readingEpoch`. Cancel everything else, including same-epoch duplicates. This correctly deflates the 46–48 frozen queue even when all items share the same epoch (2–3 per reading, constant epoch).

```swift
// New properties on BaseWatchManager:
private var hasPerformedStartupQueueDrain = false
private var lastQueueDeepDrainAt: TimeInterval = 0  // in-process cooldown for queue-deep drain path

// Shared session readiness helper — used by cancelStaleQueuedTransfers and sendDataToWatch.
// Adding all checks in one place prevents R1b and R2d from drifting out of sync.
private func sessionIsReadyForTransfer() -> Bool {
    guard let session = self.session else { return false }
    return session.activationState == .activated
        && session.isPaired
        && session.isWatchAppInstalled
}

// New method — call from session(_:activationDidCompleteWith:) AND from sendDataToWatch:
private func cancelStaleQueuedTransfers() {
    guard sessionIsReadyForTransfer() else {
        if let session = self.session {
            debug(.watchManager, "🗑️ queue_drain_skipped session_not_ready activation=\(session.activationState.rawValue)")
        }
        return
    }
    guard let session = self.session else { return }
    let allTransfers = session.outstandingUserInfoTransfers
    guard allTransfers.count > 1 else { return } // nothing to cancel if 0 or 1

    // Find the latest reading epoch across all queued transfers:
    let latestEpoch = allTransfers
        .compactMap { $0.userInfo[WatchMessageKeys.readingEpoch] as? TimeInterval }
        .max()

    // Among transfers with the latest epoch, pick the one with the newest enqueue time.
    // If no epoch data (pre-R1a builds), fall back to keeping only the last item in the array.
    let transfersToKeep: Set<ObjectIdentifier>
    if let latest = latestEpoch {
        let latestEpochTransfers = allTransfers.filter {
            ($0.userInfo[WatchMessageKeys.readingEpoch] as? TimeInterval) == latest
        }
        // Keep the newest by enqueue time; if no enqueue stamp, keep the last in array order
        let keeper = latestEpochTransfers
            .max(by: {
                let a = $0.userInfo[WatchMessageKeys.transferEnqueuedAt] as? TimeInterval ?? 0
                let b = $1.userInfo[WatchMessageKeys.transferEnqueuedAt] as? TimeInterval ?? 0
                return a < b
            })
        transfersToKeep = keeper.map { Set([ObjectIdentifier($0)]) } ?? []
    } else {
        // No epoch data: keep only the last transfer in FIFO order
        transfersToKeep = allTransfers.last.map { Set([ObjectIdentifier($0)]) } ?? []
    }

    let depthBefore = allTransfers.count
    let toCancel = allTransfers.filter { !transfersToKeep.contains(ObjectIdentifier($0)) }
    toCancel.forEach { $0.cancel() }

    // Re-read count once after cancel — not perfectly deterministic (WCSession callbacks are async),
    // but more useful than the pre-snapshot count. treat depth_after as advisory.
    let depthAfter = session.outstandingUserInfoTransfers.count

    // Extract kept transfer's metadata for debugging:
    let keptTransfer = allTransfers.first { transfersToKeep.contains(ObjectIdentifier($0)) }
    let keptEpoch = keptTransfer?.userInfo[WatchMessageKeys.readingEpoch] as? TimeInterval ?? 0
    let keptEnqueuedAt = keptTransfer?.userInfo[WatchMessageKeys.transferEnqueuedAt] as? TimeInterval ?? 0

    // cancel_requested_count: how many cancels we issued. Comparing to depth reduction in BetterStack
    // distinguishes "we asked to cancel" from "WCSession queue didn't shrink" (async re-enqueue, session state).
    debug(.watchManager, "🗑️ queue_drain cancel_requested=\(toCancel.count) depth_before=\(depthBefore) depth_after=\(depthAfter) kept_epoch=\(Int(keptEpoch)) kept_enqueued_at=\(Int(keptEnqueuedAt))")

    // Hard-cap warning: depth_after > 5 means cancellation isn't visibly taking effect yet.
    // May be transient (async session callback) — compare cancel_requested vs depth reduction over time.
    if depthAfter > 5 {
        debug(.watchManager, "⚠️ queue_drain_incomplete depth_after=\(depthAfter) cancel_requested=\(toCancel.count) — session may not have shrunk yet; advisory only")
    }
}
```

Call sites:
```swift
// 1. In session(_:activationDidCompleteWith:) — one-time startup drain:
if !hasPerformedStartupQueueDrain {
    hasPerformedStartupQueueDrain = true
    cancelStaleQueuedTransfers()
}

// 2. In sendDataToWatch(), in the budget_exhausted branch, BEFORE transferUserInfo:
cancelStaleQueuedTransfers()

// 3. In sendDataToWatch(), queue-deep observation path (budget not yet exhausted):
// Handles the case where session was already activated before this code deployed
// and the activation drain never ran. 60-second cooldown prevents repeated iterate+cancel
// overhead if something is rapidly enqueueing (buggy call site, session weirdness).
// Guard: only read outstandingUserInfoTransfers when session is fully ready — when not
// paired/installed the count can return stale/undefined values and trigger false alarms.
let queueDeepCooldown: TimeInterval = 60
if sessionIsReadyForTransfer() {
    let queueDepthNow = session.outstandingUserInfoTransfers.count
    if queueDepthNow > 5 && (Date().timeIntervalSince1970 - lastQueueDeepDrainAt) > queueDeepCooldown {
        debug(.watchManager, "🧹 queue_deep_drain triggered depth=\(queueDepthNow)")
        lastQueueDeepDrainAt = Date().timeIntervalSince1970
        cancelStaleQueuedTransfers()
    }
}
```


### R1 validation

| Metric | Signal | Pass threshold | Falsified if |
|---|---|---|---|
| Queue depth | `queue_depth` in transfer logs | p95 < 5 within 24 hrs | Remains > 10 → cancellation not executing |
| Stale delivery burst | `didReceiveUserInfo` rate/hr | < 15/hr | Unchanged → flush behaviour unaffected |

---

## R2 — Reduce Redundant Triggers

**Priority:** P1 — HIGH | **Effort:** 3–4 hrs
**Sequence:** R2a ships first → collect 24h data → R2b → observe 48h → R2c or R2d based on result
**Files:** `AppleWatchManager.swift` (lines 85, 92, 103, 110, 123, 129, 517–541, 1531, 1543)

### Problem

Eight call sites fire `scheduleWatchStateUpdate()` (6 publishers + 2 settings observers). The 2s/5s coalescer is hardcoded as inline literals at line ~529 (`min(2.0, 5.0 - elapsed)`). Publisher waves separated by >2s each produce a separate `transferCurrentComplicationUserInfo` call.

**sendMessage does not consume budget:** `via=sendMessage` in the logs is budget-free — it does not decrement `remainingComplicationUserInfoTransfers`. Only `transferCurrentComplicationUserInfo` calls drain the budget. The `S` pattern in transfer data carries no budget cost.

### R2a — Coalescer trigger-source logging (prerequisite for R2b and R2d)

`scheduleWatchStateUpdate` is `private` on a `final class` — the signature change has no subclass impact and all call sites are in the same file.

> **⚠️ Define these now, even though their primary consumer (R2d mode selection) ships later.** R2a's coalescer logging references `complicationEligibleSources` and `lastEligibleSourceAt` at every trigger. Add all of the following to `BaseWatchManager` as part of this PR:
>
> ```swift
> // Add alongside coalescerTriggerCount and coalescerSources:
> private var lastEligibleSourceAt: TimeInterval = 0
>
> // Eligible sources for complication budget transfers. Defines which trigger sources
> // indicate fresh CGM data (as opposed to IOB/COB-only updates). Used in R2a logging
> // and by R2d mode selection.
> private let complicationEligibleSources: Set<String> = [
>     "glucoseStored",
>     "glucoseUpdate"
> ]
> ```
> These properties do no harm before R2d ships — `complicationEligibleSources` is read-only, and `lastEligibleSourceAt` just gets set and reset each coalescer cycle. But without them, R2a won't compile.

```swift
// Modified signature:
private func scheduleWatchStateUpdate(source: String = "unknown") {
    assert(Thread.isMainThread, "scheduleWatchStateUpdate must be called on main queue")
    guard let session = self.session, session.isPaired, session.isWatchAppInstalled else { return }

    // New properties (add to BaseWatchManager):
    // private var coalescerTriggerCount = 0
    // private var coalescerSources: [String] = []
    // private var lastEligibleSourceAt: TimeInterval = 0   ← used by R2d
    coalescerTriggerCount += 1
    coalescerSources.append(source)
    if complicationEligibleSources.contains(source) {
        lastEligibleSourceAt = Date().timeIntervalSince1970
    }
    debug(.watchManager, "⏱️ coalescer_trigger source=\(source) eligible=\(complicationEligibleSources.contains(source)) pending=\(pendingSendWorkItem != nil)")

    // ... existing coalescerFirstScheduledAt logic unchanged ...

    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }

        // *** Snapshot coalescer state BEFORE clearing ***
        // sendDataToWatch (and R2d mode selection) must read from snapshots, not
        // from the live properties which are cleared immediately below.
        let sourcesSnapshot = self.coalescerSources
        let triggerCountSnapshot = self.coalescerTriggerCount
        let lastEligibleSnapshot = self.lastEligibleSourceAt

        // coalescerFirstScheduledAt must never be nil here — it is set when the first
        // work item is scheduled and only cleared after fire. If it is nil, that is a
        // logic error. Pass nil as windowStartEpoch so sendDataToWatch goes straight to
        // the eligible-source fallback rather than using a sentinel value that could
        // accidentally appear in logs or serialization.
        let windowStartEpoch: TimeInterval?
        if let scheduled = self.coalescerFirstScheduledAt {
            windowStartEpoch = scheduled.timeIntervalSince1970
        } else {
            windowStartEpoch = nil
            debug(.watchManager, "⚠️ coalescer_window_start_nil — invariant violated; mode will use eligible-source fallback")
        }

        self.coalescerTriggerCount = 0
        self.coalescerSources = []
        self.lastEligibleSourceAt = 0
        self.coalescerFirstScheduledAt = nil

        debug(.watchManager, "📡 coalescer_fired trigger_count=\(triggerCountSnapshot) sources=\(sourcesSnapshot.joined(separator: \",\")) last_eligible_at=\(Int(lastEligibleSnapshot))")

        Task {
            let state = await self.setupWatchState()
            await self.sendDataToWatch(
                state,
                sourcesSnapshot: sourcesSnapshot,
                lastEligibleSourceAt: lastEligibleSnapshot,
                windowStartEpoch: windowStartEpoch   // nil → skip epoch comparison, use fallback
            )
        }
    }
    // ... existing pendingSendWorkItem and asyncAfter unchanged ...
}
```

Update all 8 call sites with source tags:

```swift
scheduleWatchStateUpdate(source: "glucoseUpdate")       // line ~85
scheduleWatchStateUpdate(source: "iobUpdate")           // line ~92
scheduleWatchStateUpdate(source: "orefDetermination")   // line ~103
scheduleWatchStateUpdate(source: "glucoseStored")       // line ~110
scheduleWatchStateUpdate(source: "overrideStored")      // line ~123
scheduleWatchStateUpdate(source: "tempTargetStored")    // line ~129
scheduleWatchStateUpdate(source: "pumpSettings")        // line ~1531
scheduleWatchStateUpdate(source: "settingsChanged")     // line ~1543
```

### R2b — Per-reading-epoch dispatch gate (requires R2a data first)

After ≥24h of `coalescer_fired sources=` data confirms publisher attribution, implement the gate.

**Confirmed field names:** `currentGlucose: String?`, `trend: String?`, `delta: String?` — all pre-formatted optional strings on the iOS `WatchState` model.

**Important:** `ComplicationSnapshotFingerprint` (FP-Phase 3.0, `TrioComplicationDataStore.swift`) lives in the **watch extension target** and is inaccessible from `AppleWatchManager.swift` (iOS target). The iOS-side gate uses an equivalent inline hash mirroring the same display fields:

```swift
// Replace the in-memory property with App Group persistence:
// (reuses APP_GROUP_SUITE constant, same as lastUserInfoReceivedAt in R5d)
private var lastDispatchedGateKey: String {
    get { UserDefaults(suiteName: APP_GROUP_SUITE)?.string(forKey: "lastDispatchedGateKey") ?? "" }
    set { UserDefaults(suiteName: APP_GROUP_SUITE)?.set(newValue, forKey: "lastDispatchedGateKey") }
}

private func computeDispatchGateKey(state: WatchState) -> String {
    // Use max(by: date) — matches watchStateToDictionary (R1a) and removes the sorted-order
    // assumption. If .first and max differ, gate keys and readingEpoch would silently disagree,
    // causing the gate to miss duplicates or flag non-duplicates.
    let epoch = state.glucoseValues.max(by: { $0.date < $1.date })
        .map { String(Int($0.date.timeIntervalSince1970)) } ?? "nil"
    // Mirror ComplicationSnapshotFingerprint fields (FP-Phase 3.0):
    let display = "\(state.currentGlucose ?? "nil")|\(state.trend ?? "nil")|\(state.delta ?? "nil")"
    return "\(epoch)|\(display)"
}

// In sendDataToWatch(), before the complication transfer calls (not before sendMessage):
let gateKey = computeDispatchGateKey(state: state)
let isDuplicateDispatch = gateKey == lastDispatchedGateKey
if isDuplicateDispatch {
    debug(.watchManager, "⏭️ complication_transfer_gate_skipped duplicate gate_key=\(gateKey)")
}
if !isDuplicateDispatch {
    lastDispatchedGateKey = gateKey
}

// complicationMessage transfer path — gated on isDuplicateDispatch:
if !isDuplicateDispatch {
    if readingEpochPresent {
        // ... complication transfer calls (R3) ...
    }
}

// sendMessage (budget-free watch UI path) — ALWAYS fires, regardless of gate.
// The R2b gate is scoped to complication budget transfers only. Suppressing sendMessage
// here would stale the watch app UI for IOB/COB updates that share a gate key with the
// prior glucose reading — a UX regression that is not worth the marginal budget saving.
if session.isReachable {
    session.sendMessage([WatchMessageKeys.watchState: fullMessage], replyHandler: nil)
}
```

> **Gate design:** Keying on `(epoch, currentGlucose, trend, delta)` rather than epoch alone means a non-glucose state change (IOB, override) that shares an epoch still dispatches via `sendMessage` (preserving watch UI freshness) while the complication transfer is correctly suppressed. This mirrors `ComplicationSnapshotFingerprint` (FP-Phase 3.0), creating a consistent dual-layer dedup: iOS-side gate (R2b) reduces complication transfers upstream; watch-side `saveOnMain` (FP-Phase 3.1) catches any that get through.

> **R2b ceiling — be honest:** The `(epoch, displayFields)` gate will not prevent the "early-nil then late-computed" double-send pattern, where the first coalescer fire has `trend=nil/delta=nil` and the second has real values. Both have different gate keys and both will transfer. This means R2b alone likely plateaus around 1.3–1.8x rather than ~1.0x. The validation target (`avg C ≤ 1.3`) reflects this. If the plateau is above 1.3x after 48h, R2d (authoritative-source gating) is the correct structural fix — not further tuning of the gate key.

### Step 3b — Complication-age stale-first budget gate

**Priority:** P1 — HIGH | **Effort:** ~2 hrs | **Sequence:** After Step 3 (R2b), before Step 4 (R2d)
**Files:** `AppleWatchManager.swift`

#### Problem

Without a staleness gate, every coalescer fire that passes the R2b duplicate gate can consume complication budget even when the complication is already showing fresh data (e.g. from a recent `sendMessage` or prior transfer). Budget then drains in the first 2–2.5 hours after the daily reset. Preserving budget for moments when the complication is actually stale improves both time-to-exhaustion and user-visible freshness during exhaustion windows.

#### Approach

Gate **only** the budget-consuming path (`transferCurrentComplicationUserInfo`) on “current complication age &gt; T”. Do not gate `sendMessage`: that path is budget-free and keeps the watch app UI fresh; gating it would stale the UI for no benefit. The fallback `transferUserInfo` path (when budget is exhausted) remains unchanged — still allowed when not duplicate, so the queue continues to receive one representative transfer per reading during exhaustion.

- **Complication age on iOS:** In the helper (see code sketch), use this exact pattern: `guard let suiteName = appGroupIDCandidate().value, let defaults = UserDefaults(suiteName: suiteName) else { return .infinity }`; then `let lastValid = defaults.object(forKey: "TrioComplication_lastValidTimestamp") as? Date`; `if lastValid == nil { return .infinity }`; else `return max(0, Date().timeIntervalSince(lastValid!))`. Same key as `TrioComplicationDataStore.lastValidTimestamp` (watch).
- **Threshold:** T = 600 seconds (10 minutes) as initial value. Data-driven from BetterStack (48h window): reload_age proxy p90 ≈ 10.3m; counts per day for staleness &gt;10m ≈ 79/day, &gt;12m ≈ 40/day, &gt;15m ≈ 14/day. T=10m targets the worst staleness while leaving room to tune (e.g. 12m if budget still drains too fast, 8m if budget remains high and staleness is acceptable).
- **Placement:** In `sendDataToWatch`, compute `complicationAgeSeconds` after `fullMessage`/`complicationMessage` are built and before the complication transfer decision. Use a helper so the read and clamp are in one place.

- **lastDispatchedGateKey rule:** `lastDispatchedGateKey` is ONLY set when a complication transfer is actually enqueued (after `transferCurrentComplicationUserInfo` OR after `transferUserInfo` fallback). Do NOT set it on sendMessage-only paths. Do NOT set it when the age gate fails. Do not reintroduce the Step 3 foreground→background suppression bug.

#### Code sketch

```swift
// Private helper — no Watch Shared import; use UserDefaults with suite only.
private static let complicationAgeGateThresholdSeconds: TimeInterval = 600

private func currentComplicationAgeSeconds() -> TimeInterval {
    guard let suiteName = appGroupIDCandidate().value, let defaults = UserDefaults(suiteName: suiteName) else { return .infinity }
    let lastValid = defaults.object(forKey: "TrioComplication_lastValidTimestamp") as? Date
    if lastValid == nil { return .infinity }
    return max(0, Date().timeIntervalSince(lastValid!))
}

// In sendDataToWatch(), after building complicationMessage and gateKey, before the complication transfer block:
let complicationAgeSeconds = currentComplicationAgeSeconds()
let ageGatePassed = complicationAgeSeconds > Self.complicationAgeGateThresholdSeconds

// Complication transfer block: only apply age gate when we would SPEND budget (remaining > 0).
// When budget is exhausted, userInfo fallback is allowed regardless of age (duplicate gate only).
if !session.isReachable, readingEpochPresent, !isDuplicateDispatch {
    if session.remainingComplicationUserInfoTransfers > 0 {
        // Budget available — gate on age so we only spend when complication is stale.
        if ageGatePassed {
            session.transferCurrentComplicationUserInfo(...)
            lastDispatchedGateKey = gateKey  // lastDispatchedGateKey ONLY set when complication transfer actually enqueued; do not set on sendMessage-only or when age gate fails (do not reintroduce Step 3 foreground→background suppression bug)
            // log: include complication_age_seconds=\(Int(complicationAgeSeconds)) complication_age_gate_threshold_seconds=\(Int(Self.complicationAgeGateThresholdSeconds))
        } else {
            // Do not touch lastDispatchedGateKey — we did not enqueue a complication transfer.
            debug(.watchManager, "⏭️ complication_transfer_age_gate_skipped skip_reason=age_gate age_seconds=\(Int(complicationAgeSeconds)) threshold_seconds=\(Int(Self.complicationAgeGateThresholdSeconds)) gate_key=\(gateKey)")
        }
    } else {
        // Budget exhausted — fallback path: no age gate; still subject to duplicate gate above.
        cancelStaleQueuedTransfers()
        session.transferUserInfo([WatchMessageKeys.watchState: complicationMessage])
        lastDispatchedGateKey = gateKey
        // existing userInfo fallback logging
    }
}
// sendMessage always fires regardless — do not gate.
```

**Skip-log taxonomy (BetterStack):** Three queryable categories. Step 3b age-gate skip: `skip_reason=age_gate`. R2b duplicate skip: document as `skip_reason=duplicate_gate` (even if the current log line doesn’t include the literal yet). Missing readingEpoch: its own case. Queries can filter by: age_gate, duplicate_gate, missing readingEpoch.

#### Validation

| Metric | Signal | Pass threshold | Falsified if |
|---|---|---|---|
| Budget spread | Daily complication transfers / remaining budget over time | Budget no longer drains in first 2–3h after reset; some budget remains into afternoon | Budget still exhausted within 3h of reset |
| Staleness | `complication_reload_age` / (future) `timeline_built snapshot_age` | Fewer events with age &gt;15m; p90 age stable or improved | Increase in &gt;15m outliers |
| Gate behavior | `complication_transfer_age_gate_skipped` count; transfer logs with `complication_age_seconds` | Age gate applies ONLY to transferCurrentComplicationUserInfo (budget-consuming); NOT sendMessage, NOT userInfo fallback. Transfers when age &gt; T; skips when age ≤ T. Budget not exhausted in first 2–3h after reset. | Transfers when age &lt; threshold; no age-gate skips when fresh; or budget still exhausted in 3h |

#### Sequence

Step 3b is implemented and deployed **after** Step 3 (R2b) and **before** Step 4 (R2d). The 48h observation after Step 3 can include Step 3b in the same build, or Step 3b can ship as a follow-on PR after R2b data is collected.

**Implementation status (2026-03-12):** Step 3b code complete in `AppleWatchManager.swift`. Verified: `currentComplicationAgeSeconds()` (exact 4-step pattern, no Watch Shared import), `complicationAgeGateThresholdSeconds = 600`, age gate applied only when `remaining > 0`; budget-exhausted fallback ungated; `lastDispatchedGateKey` set only on actual enqueue; skip/success logs include `skip_reason=age_gate`, `reading_date_epoch_seconds`, `complication_age_seconds`. Observe 48h (budget spread, age-gate skip volume) before Step 4.

**Logging pipeline fixes (2026-03-13):** Builds 137-138 deployed with cloud logging pipeline fixes (see `docs/completed/logging-fixes/`). These fixes are directly relevant to the Step 4 decision gate because they resolve the build-mislabeling problem that made avg C per-build measurements unreliable. Before build 137, `CloudLogUploader` stamped all events with the phone's `Bundle.main` build at upload time — backlogged watch/complication logs (up to 7 days old) were attributed to the wrong build. Key fixes: `[b:BUILD]` embedded in every log line at write time; drain retention reduced from 7d to 48h; upgrade-time flush on both watch and phone; drain file ACK gap fixed via `transferUserInfo`-based confirmation pathway. The reliable observation window for the Step 4 avg C gate starts from build 137 deployment (2026-03-12).

### R2c — Settings publisher debounce tuning ⚠️ Deprioritized

> **Status:** Defer until after the R2a observation window. If the attribution data shows that settings publishers (`overrideStored`, `tempTargetStored`) are causing a meaningful share of multi-C readings, implement this. If R2d (pipeline split) is pursued, this becomes unnecessary — the settings triggers would route to the UI-only channel and never touch the complication budget.

> **UX risk:** `scheduleWatchStateUpdate` drives both the complication transfer path and `sendMessage` for watch UI. Lengthening the debounce for settings triggers also delays watch UI refresh after the user changes an override or temp target. Acceptable if the delay is <15s and settings changes are infrequent, but worth validating after R2a attribution data is available.

```swift
private func scheduleWatchStateUpdate(
    source: String = "unknown",
    debounce: TimeInterval = 2.0,
    maxWait: TimeInterval = 5.0
) {
    // Line ~529 changes from: let delay = max(0.0, min(2.0, 5.0 - elapsed))
    let delay = max(0.0, min(debounce, maxWait - elapsed))
}
```

Settings call sites use longer windows; CGM call sites keep defaults:

```swift
scheduleWatchStateUpdate(source: "overrideStored",   debounce: 10.0, maxWait: 15.0) // ~123
scheduleWatchStateUpdate(source: "tempTargetStored", debounce: 10.0, maxWait: 15.0) // ~129
scheduleWatchStateUpdate(source: "pumpSettings",     debounce: 10.0, maxWait: 15.0) // ~1531
scheduleWatchStateUpdate(source: "settingsChanged",  debounce: 10.0, maxWait: 15.0) // ~1543
```

---

### R2d — Authoritative-source gating (complication vs UI channel split)

**Priority:** P1 | **Effort:** 4–6 hrs | **Decision gate:** R2a attribution data (≥24h)
**Supersedes:** R2c if implemented

> **Status:** Formal phase — not backlog. Implement if R2a attribution data shows either (a) non-glucose publishers causing >30% of multi-C readings, or (b) R2b alone does not reduce avg C/reading below 1.3x within 48h of shipping. This is the most reliable structural path from 2.85x → ~1.0x.

**Problem:** `scheduleWatchStateUpdate` routes all 8 publishers through a single pipeline that ends in both `transferCurrentComplicationUserInfo` (budget-consuming) and `sendMessage` (budget-free). Any publisher — including IOB updates, settings changes, and temp target stores — can burn complication budget even though the complication only displays glucose, trend, and delta.

**Approach:** Split `sendDataToWatch` into two modes:

```swift
enum WatchSendMode {
    case complicationAndUI   // transferCurrentComplicationUserInfo + sendMessage
    case uiOnly              // sendMessage only — no complication budget consumed
}
```

Define a source allowlist for complication-eligible sends:

> **Note:** `complicationEligibleSources` and `lastEligibleSourceAt` are defined and added to `BaseWatchManager` in R2a (they're required for R2a's logging to compile). The definition here is for reference — do not add them again.

```swift
// Already defined in R2a — shown here for reference only:
private let complicationEligibleSources: Set<String> = [
    "glucoseStored",
    "glucoseUpdate"
]
```

Track the **last eligible source timestamp** in `scheduleWatchStateUpdate` (add alongside `coalescerSources` from R2a — already covered above):

```swift
// lastEligibleSourceAt is set in R2a's scheduleWatchStateUpdate when source ∈ eligible:
// if complicationEligibleSources.contains(source) { lastEligibleSourceAt = Date().timeIntervalSince1970 }
// It is snapshotted before clearing and passed into sendDataToWatch as lastEligibleSourceAt.
```

In `sendDataToWatch`, determine mode from the **window-scoped** eligible check:

```swift
// sendDataToWatch signature update (add parameters for coalescer context):
// func sendDataToWatch(_ state: WatchState,
//                      sourcesSnapshot: [String],
//                      lastEligibleSourceAt: TimeInterval,
//                      windowStartEpoch: TimeInterval?) async   ← nil when coalescerFirstScheduledAt was nil

// Primary check: eligible if any glucose-origin event fired during this coalescer window.
// windowStartEpoch is nil when coalescerFirstScheduledAt was nil (invariant violation upstream).
// In that case skip the epoch comparison and go straight to the fallback.
var eligibleThisWindow: Bool
if let windowStart = windowStartEpoch {
    eligibleThisWindow = lastEligibleSourceAt >= windowStart
} else {
    // nil windowStart: invariant already logged upstream; go straight to fallback below.
    eligibleThisWindow = false
}

// Clock-skew / nil-windowStart fallback:
// Triggers when epoch comparison fails due to: (a) wall-clock jump backward (NTP sync,
// user time change), or (b) nil windowStart (invariant violation).
// Fallback: split into three distinct log cases so production triage can distinguish them.
// (1) windowStartEpoch == nil: invariant violation — coalescerFirstScheduledAt was nil at fire time
// (2) small negative delta (|delta| < 5s): genuine NTP skew or user time change
// (3) large negative delta: likely logic bug; fail open but flag prominently
if !eligibleThisWindow
    && lastEligibleSourceAt != 0
    && sourcesSnapshot.contains(where: { complicationEligibleSources.contains($0) }) {
    let skewDelta = windowStartEpoch.map { lastEligibleSourceAt - $0 } ?? 0
    if windowStartEpoch == nil {
        debug(.watchManager, "⚠️ eligible_source_window_nil_fallback — windowStartEpoch was nil (invariant violation); failing open to complicationAndUI")
    } else if skewDelta >= -5 && skewDelta < 0 {
        debug(.watchManager, "⚠️ eligible_source_clock_skew delta=\(String(format: "%.3f", skewDelta))s last_eligible_at=\(Int(lastEligibleSourceAt)) window_start=\(Int(windowStartEpoch!)) — NTP/time-change skew; failing open")
    } else {
        debug(.watchManager, "⚠️ eligible_source_epoch_inversion delta=\(String(format: "%.3f", skewDelta))s last_eligible_at=\(Int(lastEligibleSourceAt)) window_start=\(Int(windowStartEpoch!)) — large delta, likely logic bug; failing open to complicationAndUI")
    }
    eligibleThisWindow = true
}

let mode: WatchSendMode = eligibleThisWindow ? .complicationAndUI : .uiOnly
debug(.watchManager, "📡 send_mode mode=\(mode) last_eligible_at=\(Int(lastEligibleSourceAt)) window_start=\(windowStartEpoch.map { Int($0) }.map(String.init) ?? "nil") all_sources=\(sourcesSnapshot.joined(separator: \",\"))")

// Transfer attempt + outcome logging — prevents "avg C looks good because skips aren't counted".
// BetterStack avg C/reading query must filter transfer_path IN ('complication', 'userInfo') only.
var transferPath = "skipped_session_not_ready"

if mode == .complicationAndUI {
    // Use shared helper — same three-condition check as cancelStaleQueuedTransfers().
    if sessionIsReadyForTransfer() {
        if session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo([WatchMessageKeys.watchState: complicationMessage])
            transferPath = "complication"
        } else {
            cancelStaleQueuedTransfers()
            session.transferUserInfo([WatchMessageKeys.watchState: complicationMessage])
            transferPath = "userInfo"
        }
    }
    // else: transferPath remains "skipped_session_not_ready"
}

debug(.watchManager, "📤 complication_transfer_attempted=\(mode == .complicationAndUI) transfer_path=\(transferPath)")

// sendMessage always fires regardless of mode (budget-free, watch UI path):
if session.isReachable {
    session.sendMessage([WatchMessageKeys.watchState: fullMessage], replyHandler: nil)
}
```

> **Window-scoped rationale:** `lastEligibleSourceAt >= windowStart` answers the question "did any glucose-origin event fire during this specific coalescer window?" correctly for all source orderings:
> - `glucoseStored` → `iobUpdate` (non-glucose fires last): eligible ✅ — glucose fired in window
> - `iobUpdate` alone: not eligible ✅ — no glucose in window
> - `iobUpdate` → `glucoseStored` (glucose fires last): eligible ✅ — glucose fired in window

> **Clock-skew fallback tightening:** `lastEligibleSourceAt != 0` is required in the fallback. Without it, any eligible source in the snapshot would "invent" eligibility even if `lastEligibleSourceAt` was never set — silently reverting to "any eligible in window" behavior and re-burning budget. The `!= 0` guard means eligibility was actually observed during the session, not just present in the source list.

> **nil windowStart handling:** `windowStartEpoch: TimeInterval?` replaces the `Date(timeIntervalSince1970: .infinity)` sentinel. `nil` is an explicit signal that the invariant was violated upstream. It's self-documenting, won't appear in logs as a confusing timestamp value, and routes cleanly to the fallback path.

> **Shared `sessionIsReadyForTransfer()` helper:** R1b's `cancelStaleQueuedTransfers()` and R2d's transfer path now use the same three-condition check (`activationState == .activated && isPaired && isWatchAppInstalled`). Defined once near `cancelStaleQueuedTransfers()`.

> **`transfer_path` metric:** BetterStack avg C/reading query must filter `transfer_path IN ('complication', 'userInfo')` — not just `complication_transfer_attempted = true`. This ensures session-guard skips don't make the metric look better than reality.

> **R2c relationship:** If R2d is implemented, R2c (settings debounce) is unnecessary — settings triggers will route to `uiOnly` and never touch the complication budget. Skip R2c.

> **R2d test plan:** Before shipping, manually verify these two trigger orderings in a simulator or on-device with logging:
> 1. `glucoseStored` → `iobUpdate` (within same 2s window) → coalescer fires → confirm `mode=complicationAndUI`, `transfer_path=complication`
> 2. `iobUpdate` alone (no glucose) → coalescer fires → confirm `mode=uiOnly`


### R2 validation (estimates)

| Metric | Current | Target | Falsified if |
|---|---|---|---|
| Avg C transfers/reading | ~1.85 C | ~1.0 C | Post-deploy avg > 1.5 C in budget-ok window |
| Budget drain rate | ~20–27/hr | ~12–15/hr | Drain rate > 18/hr after 24h |
| Time to exhaustion | 108–147 min | ~3–4 hrs | Cycle < 2 hrs after R1 + R2 both shipped |

> **BetterStack query note:** The avg C/reading query must filter `transfer_path IN ('complication', 'userInfo')` — not just `complication_transfer_attempted = true`. Session-guard skips (`transfer_path = 'skipped_session_not_ready'`) must be excluded or they will make the metric appear better without any real freshness improvement.

### Better Stack avg C metrics (extraction rules)

**Definition of avg C:** Avg C = (number of **complication transfers**) / (unique CGM readings). "Complication transfers" means both the budget-consuming path and the fallback: in current log terms, **both** `via=transferCurrentComplicationUserInfo` **and** `via=userInfo` (equivalent to plan's `transfer_path IN ('complication', 'userInfo')`). Exclude `via=sendMessage` (budget-free UI path). Target: avg C ≤ 1.3.

**Legacy metric limitation:** The original Better Stack metric `complication_c_transfers` was defined to count only `via=userInfo`. That undercounts when the app uses the main complication path (`transferCurrentComplicationUserInfo`), so the dashboard "Avg C / reading" chart showed 0 whenever budget was available and the fallback was not used. Because of a Better Stack platform limitation, the existing `complication_c_transfers` extraction rule could not be modified in place.

**New metric and dashboard:** A new metric **`complication_c_total_transfers`** was created with an extraction rule that counts **both** complication paths. Aggregation: **sum** only (each matching line contributes 1; `sumMerge(complication_c_total_transfers_sum)` gives the count of transfers per bucket). The Trio Dashboard "Avg C / reading" chart is updated to use `complication_c_total_transfers` (and `complication_c_readings` unchanged) going forward. Chart formula: `sumMerge(complication_c_total_transfers_sum) * 1.0 / nullIf(uniqMerge(complication_c_readings_uniq), 0)` per time bucket.

**Extraction rule for `complication_c_total_transfers`** (aggregation: **sum**; emits 1 per matching log line, 0 otherwise):

```text
if(
  JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%Transferred new WatchState%'
  AND (
    JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%via=transferCurrentComplicationUserInfo%'
    OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%via=userInfo%'
  ),
  1,
  0
)
```

**`complication_c_readings`** (unchanged): Extract `reading_date_epoch_seconds` from any "Transferred new WatchState" line for the denominator (uniq of CGM readings). Rule: `if(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%Transferred new WatchState%', toInt64OrNull(extract(JSONExtract(raw, 'message', 'Nullable(String)'), 'reading_date_epoch_seconds=([0-9]+)')), NULL)` with aggregation type uniq.

---

## R3 — Strip Oversized Payload from Complication Transfers

**Priority:** P1 | **Effort:** 2–3 hrs | **Hard dependency: R1a must be live first**
**Files:** `AppleWatchManager.swift`, `WatchState.swift` (watch side, `saveComplicationSnapshot`)

> ⚠️ **R3 requires R1a.** The complication payload allowlist omits `glucoseValues`. Watch-side `saveComplicationSnapshot` will fall back to `latestGlucoseDate(from:)` if `readingEpoch` is absent, but since R3 also removes `glucoseValues` from the payload, neither path for deriving `readingDate` will work without R1a's `readingEpoch` key. If R3 ships before R1a, `saveComplicationSnapshot` will abort on every transfer and no snapshots will be saved. Do not rearrange this order.

### Problem

The `glucoseValues` array (288 entries × ~65 bytes = ~18.7 KB) dominates every transfer payload. Cursor confirmed the complication path only uses this array to derive `readingDate` via `latestGlucoseDate()`. All other array data is watch app UI chart data. The complication needs only `currentGlucose`, `trend`, `delta`, `currentGlucoseColorString`, and a reading date — ~200 bytes total.

### Approach: add top-level readingDate key, strip array from complication paths

**Step 1 — R1a already covers this.** The new `WatchMessageKeys.readingEpoch` key added in R1a carries the CGM reading date as a top-level scalar, making `glucoseValues` redundant for the complication path.

**Step 2 — Watch-side: prefer the new key over array derivation.**

In `saveComplicationSnapshot(from:)` on the watch side:

```swift
// Prefer top-level readingEpoch (added in R1a) over deriving from glucoseValues:
let readingDate: Date
if let epoch = dictionary[WatchMessageKeys.readingEpoch] as? TimeInterval {
    readingDate = Date(timeIntervalSince1970: epoch)
} else if let latestDate = latestGlucoseDate(from: dictionary) {
    readingDate = latestDate  // fallback: supports older iOS builds during phased rollout
} else {
    debug(.watchManager, "⚠️ saveComplicationSnapshot: no readingDate available")
    return
}
```

**Step 3 — iOS side: build `complicationMessage` from an explicit allowlist (not a strip list).**

The "copy fullMessage then remove keys" approach is a maintainability trap — any new field added to `watchStateToDictionary` silently bloats the complication payload with no compile-time warning. Instead, build `complicationMessage` explicitly from only the fields the complication needs. Adding a new field to the full payload will never affect the complication transfer unless it is deliberately added to the allowlist.

```swift
// In sendDataToWatch(), after building fullMessage from watchStateToDictionary:
var fullMessage = watchStateToDictionary(state)
fullMessage[WatchMessageKeys.transferEnqueuedAt] = Date().timeIntervalSince1970

// Complication payload — built from an explicit allowlist via safe if-let inserts.
// This avoids the Optional-as-Any bridging trap: fullMessage[key] returns Optional<Any>
// which, when cast to Any, becomes Optional<Any>.none — not NSNull — and is NOT
// property-list-safe for WatchConnectivity. Explicit if-let guarantees only real values
// are included, with no ambiguous Optional wrapping.
var complicationMessage: [String: Any] = [:]
let complicationAllowlist: [(String, String)] = [
    // (constant, human-readable name for log) — fields confirmed by Cursor R3b audit:
    (WatchMessageKeys.currentGlucose,            "currentGlucose"),
    (WatchMessageKeys.currentGlucoseColorString, "currentGlucoseColorString"),
    (WatchMessageKeys.trend,                     "trend"),
    (WatchMessageKeys.delta,                     "delta"),
    (WatchMessageKeys.readingEpoch,              "readingEpoch"),
    (WatchMessageKeys.transferEnqueuedAt,        "transferEnqueuedAt"),
    (WatchMessageKeys.date, "date"),  // ⚠️ BUILD TIME, not CGM reading time — kept for backward compat only; never treat as readingDate
]
for (key, name) in complicationAllowlist {
    if let value = fullMessage[key] {
        complicationMessage[key] = value
    } else {
        // Only readingEpoch is load-bearing — warn loudly if absent.
        // Other keys (trend, delta) can legitimately be nil during early readings;
        // log at debug level to avoid log spam in production.
        if key == WatchMessageKeys.readingEpoch {
            debug(.watchManager, "⚠️ complication_payload missing key=\(name) — load-bearing field absent")
        } else {
            debug(.watchManager, "complication_payload missing key=\(name) — non-load-bearing, continuing")
        }
    }
}

// readingEpoch is load-bearing for the complication transfer path only.
// If absent, skip the complication transfer but still fire sendMessage so the watch UI
// continues to receive data. A full return here would dark the watch UI entirely.
let readingEpochPresent = complicationMessage[WatchMessageKeys.readingEpoch] != nil
if !readingEpochPresent {
    debug(.watchManager, "⚠️ complication_transfer_skipped missing readingEpoch — R1a may not have shipped; sendMessage still firing")
}

// complicationMessage used for complication budget paths (only when readingEpoch present):
if readingEpochPresent {
    if session.remainingComplicationUserInfoTransfers > 0 {
        session.transferCurrentComplicationUserInfo([WatchMessageKeys.watchState: complicationMessage])
        debug(.watchManager, "📤 complication transfer payload_bytes=\(estimatedBytes(complicationMessage))")
    } else {
        session.transferUserInfo([WatchMessageKeys.watchState: complicationMessage])
        debug(.watchManager, "📤 userInfo transfer payload_bytes=\(estimatedBytes(complicationMessage))")
    }
}

// fullMessage used for sendMessage — ALWAYS fires regardless of readingEpoch presence.
// This keeps the watch app UI receiving data even if the complication transfer path aborts.
if session.isReachable {
    session.sendMessage([WatchMessageKeys.watchState: fullMessage], replyHandler: nil)
}
```

> **Note:** `processRawDataForWatchState` on the watch side reads all keys with optional chaining — missing watch-app-only keys silently produce nil values for those fields. No crash. No behavioural change for the complication.

> **`readingEpoch` gate scope:** The guard gates only `transferCurrentComplicationUserInfo` / `transferUserInfo`. `sendMessage` (the budget-free watch UI path) always fires. A `return` here would have silenced the watch UI whenever `readingEpoch` was absent — a regression far worse than a missed complication transfer.

### R3 validation

- `payload_bytes` log field confirms complication transfers are ~200–400 bytes
- **Falsified if:** Watch side starts logging "no readingDate available" → `readingEpoch` key not present and `glucoseValues` fallback also absent (indicates R1a didn't ship yet or key name mismatch)

---

## R4 — App Group Safety Net During Budget Exhaustion (Step 5)

**Priority:** P1 | **Effort:** 2–3 hrs | **Status:** PENDING — R6 has shipped (build 140); ship R4 as the next PR after the R6 48h observation window concludes. R4 touches `AppleWatchManager.swift` (iOS) and `WatchState.swift` (watch); R6 touched only `WatchState.swift` — no file conflict.
**Files:** `AppleWatchManager.swift`, `Trio Watch App Extension/WatchState.swift`

### Architecture (corrected after Cursor R4 audit)

The complication is a WidgetKit extension. **`WCSession` is not available in WidgetKit processes.** `receivedApplicationContext` cannot be read from `getTimeline`. The only shared data path between the watch app extension and the complication is the App Group container, which `TrioComplicationDataStore` already uses.

The correct architecture is:

1. **iOS sends `updateApplicationContext`** — budget-free, always replaces with latest, delivered to watch app extension on reconnect
2. **Watch app extension receives it** via `session(_:didReceiveApplicationContext:)` and writes to `TrioComplicationDataStore` using the existing save path
3. **Complication reads from `TrioComplicationDataStore`** — unchanged, already works this way

This means `applicationContext` acts as a parallel delivery channel that feeds the same App Group store. During exhaustion windows, the complication gets fresh data from this channel rather than waiting for the 46-item `transferUserInfo` queue to drain.

### iOS side

> **⚠️ Placement: this entire block goes at the END of `sendDataToWatch`, AFTER all existing transfer calls and `sendMessage`.** The `guard budgetExhausted || queueDeep else { return }` bails out early when budget is healthy — that is intentional. But if placed before the main transfer logic, it would skip all sends (complication transfer, userInfo, and sendMessage) whenever budget is healthy. It must come after those calls.

> **⚠️ `complicationMessage` must be in scope:** This block references `complicationMessage` (the R3 allowlist payload). If `sendDataToWatch` ever acquires an early-return path that runs before `complicationMessage` is built, the R4 safety net silently fires nothing during budget exhaustion. To prevent this: build `complicationMessage` unconditionally at the top of `sendDataToWatch`, regardless of which transfer path is subsequently taken. Do not gate its construction on `readingEpochPresent` or any other condition.

```swift
// In sendDataToWatch(), at the END — after all existing transfer/sendMessage calls:
let budgetExhausted = session.remainingComplicationUserInfoTransfers == 0
let queueDeep = session.outstandingUserInfoTransfers.count > 5
guard budgetExhausted || queueDeep else { return } // NOTE: use return, not break — this is a guard in function scope

if sessionIsReadyForTransfer() {
    // Use complicationMessage (from R3 — allowlist build, ~200–400 bytes) to stay well under 65KB:
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
} else {
    // Log all three conditions so we know which one failed:
    debug(.watchManager, "📦 context_skipped activation_state=\(session.activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
}
```

> **Rationale for conditional gate:** Writing `applicationContext` on every send during normal operation would add serialization work on every cycle before R2 has reduced the send rate. The gate activates precisely when it's needed — during exhaustion or when the fallback queue is backed up — and is dormant during normal operation. Can be made always-on later once R2 has tamed the send rate.

> **`context_attempted` / `context_succeeded` split:** These two log fields enable a BetterStack query to confirm the safety net is actually arming and delivering (not silently skipped due to activation state). Use `context_attempted - context_succeeded` as the failure rate metric.

### Watch app extension side

Add (or confirm) `didReceiveApplicationContext` in watch-side `WatchState.swift`:

> **R5d integration dependency:** The full handler (with `lastDataReceivedAt` and `forceWidgetReloadIfStale`) requires R5d (Step 6). The simplified version below is the standalone R4 handler — implement it if shipping R4 independently. When R5d ships, the handler is extended with the three-constraint ordering (shown in plan §R5d and implementation guide Step 5's watch-side block).

```swift
// Standalone R4 handler (no R5d integration):
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    debug(.watchManager, "📦 didReceiveApplicationContext")
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else {
        return
    }
    // Reuse existing save path — saveOnMain (FP-Phase 3.1) handles dedup automatically:
    DispatchQueue.main.async { [weak self] in
        self?.saveComplicationSnapshot(from: payload)
    }
}
```

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

- **Query:** `save_age` distribution filtered to `budget_exhausted=true` hours
- **Pass:** p90 < 300s during exhaustion windows
- **Falsified if:** `save_age` unchanged during exhaustion → watch app extension not receiving context, or `saveComplicationSnapshot` not being called from `didReceiveApplicationContext`

---

## R5 — Observability Hardening

**Priority:** P1 (parallel — ship opportunistically) | **Effort:** 2–3 hrs total

### R5a — Coalescer trigger-source logging

Described in R2a — **prerequisite for R2b**. Ships as the first step in the R2 series.

### R5b — sendMessage latency instrumentation

Cursor confirmed: no wall-clock timestamps on either end of the `sendMessage` path.

```swift
// AppleWatchManager.swift, sendMessage branch:
debug(.watchManager, "📨 sendMessage_sent reading_epoch=\(readingEpoch) send_wall=\(Date().timeIntervalSince1970)")

// WatchState.swift (watch side), didReceiveMessage (~line 230):
// extractedEpoch parsed from message using WatchMessageKeys.readingEpoch (R1a):
debug(.watchManager, "📬 didReceiveMessage reading_epoch=\(extractedEpoch) receive_wall=\(Date().timeIntervalSince1970)")
```

**As implemented (post-review):** The send payload is `[WatchMessageKeys.watchState: fullMessage]`; `fullMessage` is the inner watch-state dict (from `watchStateToDictionary`) and contains `readingEpoch`. On the watch, we only enter the R5b log block after `if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any], ...`, so `watchStateDict` is that inner payload. Reading `watchStateDict[WatchMessageKeys.readingEpoch]` is therefore correct for end-to-end timing. A code comment in `WatchState.swift` documents this so future changes do not read epoch from the wrong level.

### R5c — didReceiveUserInfo decode latency

```swift
// WatchState.swift, didReceiveUserInfo (~line 286):
let receiveTimestamp = Date()
// ... existing processing ...
// After saveComplicationSnapshot returns:
let decodeMs = Int(Date().timeIntervalSince(receiveTimestamp) * 1000)
debug(.watchManager, "⏱️ userInfo_decoded reading_epoch=\(readingEpoch) decode_ms=\(decodeMs)")
```

**As implemented (post-review):** Attribution must not depend on shared mutable state, because both the userInfo path and the sendMessage path use the same `pendingData` / `finalizePendingData` machinery and overlapping userInfo deliveries can overwrite instance state before a save runs. Attribution is **threaded with the work** in two ways: (1) **Path flag:** `scheduleUIUpdate(with:fromUserInfo:)` and `finalizePendingData(fromUserInfo:)` take a `fromUserInfo` parameter; the userInfo path passes `true`, the sendMessage path passes `false`; the debounced work item captures it and passes it through so the run that processes the payload decides whether to log `userInfo_decoded`. (2) **Timestamp and epoch:** The receive timestamp is passed as `userInfoReceiveTimestamp` through `scheduleUIUpdate` → `finalizePendingData` → `processRawDataForWatchState` → `saveComplicationSnapshot`. In the pending-tasks path, `receiveTs = lastUserInfoReceiveTimestamp` is captured **outside** the `DispatchWorkItem` at creation time so a second delivery cannot overwrite it before the work runs. In `saveComplicationSnapshot`, `reading_epoch` is taken from the payload being saved (`Int(readingDate.timeIntervalSince1970)` from the same `message` that produced `readingDate`), not from instance state. **No fallback:** When `fromUserInfo` is true, only the threaded `userInfoReceiveTimestamp` is used for `decode_ms`; there is no fallback to `lastUserInfoReceiveTimestamp`, so attribution stays unambiguous if a call path ever omitted the parameter. The former `lastUserInfoReadingEpoch` property was removed as dead state after the log was switched to payload-derived epoch. (Post-review follow-up: ChatGPT suggested removing the fallback and dead state; Claude confirmed the threading shape and noted the fallback had already been removed.)

### R5d — Sleep-gap forced reload

> ✅ **`latestSnapshot()` confirmed safe on main (Cursor Round 2 — Prompt R5d-snapshot).** The method performs synchronous file I/O (~200 bytes, JSON decode) but is already used from multiple threads in production and is safe to call on main at this payload size. `snapshot_read_ms` is logged on every reload call — if it ever exceeds 20ms in production, move the read to a background queue. No pre-implementation gating required.

`lastUserInfoReceivedAt: Date?` already exists at line ~102 (in-memory). Cursor confirmed it is **not persisted** — process restarts reset it to `nil`, which would produce a false infinite-gap on first receive after restart.

**Fix: persist to App Group UserDefaults and rename to `lastDataReceivedAt`:**

The property is renamed from `lastUserInfoReceivedAt` to `lastDataReceivedAt` — it must be updated by both the `didReceiveUserInfo` and `didReceiveApplicationContext` paths. Using the name `lastUserInfoReceivedAt` in the applicationContext handler is semantically wrong and easy to miss.

```swift
// Replace the in-memory property with a computed property backed by App Group UserDefaults.
// Renamed from lastUserInfoReceivedAt → lastDataReceivedAt — updated by BOTH receive paths.
private var lastDataReceivedAt: Date? {
    get {
        let epoch = UserDefaults(suiteName: APP_GROUP_SUITE)?.double(forKey: "lastDataReceivedAt") ?? 0
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
    set {
        UserDefaults(suiteName: APP_GROUP_SUITE)?.set(
            newValue?.timeIntervalSince1970 ?? 0,
            forKey: "lastDataReceivedAt"
        )
    }
}
```

Sleep-gap detection in `didReceiveUserInfo` — snapshot gap first, then save, update timestamp, then reload:

```swift
// ORDERING IS LOAD-BEARING — three constraints must all be satisfied:
// (1) gap must be computed BEFORE updating lastDataReceivedAt, or it always reads ~0ms
// (2) save must happen BEFORE forceWidgetReloadIfStale(receivedGap:), so WidgetKit reads fresh data
// (3) lastDataReceivedAt must be updated BEFORE the gap check fires the reload,
//     so subsequent deliveries don't also see a large gap
let gap = lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
self.saveComplicationSnapshot(from: userInfo)
self.lastDataReceivedAt = Date()
if gap > 600 {
    debug(.watchManager, "💤 sleep_gap_detected gap_seconds=\(Int(gap))")
    forceWidgetReloadIfStale(receivedGap: gap)
}
```

Add the same ordering to `didReceiveApplicationContext` (R4). During budget exhaustion, `didReceiveUserInfo` may not fire at all, so the applicationContext path needs its own gap detection — and **must update `lastDataReceivedAt`** so subsequent deliveries don't see an infinitely growing gap:

```swift
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    debug(.watchManager, "📦 didReceiveApplicationContext")
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else { return }
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Same three-constraint ordering as didReceiveUserInfo:
        // (1) snapshot gap BEFORE updating lastDataReceivedAt
        // (2) save BEFORE reload so WidgetKit reads fresh data
        // (3) update lastDataReceivedAt so subsequent context deliveries don't re-trigger
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

**WidgetKit reload helper** — rate-limited, with diagnostic snapshot read:

```swift
// In WatchState.swift (watch app extension):
// receivedGap: the gap that triggered this call — used to detect stale backlog slippage
// (snapshotAge ≈ receivedGap means we reloaded with data that predates the gap itself).
private func forceWidgetReloadIfStale(receivedGap: TimeInterval) {
    // Rate limiter: don't reload more than once per 5 minutes.
    let minReloadInterval: TimeInterval = 300
    let lastReloadKey = "lastWidgetReloadAt"
    let lastReloadEpoch = UserDefaults(suiteName: APP_GROUP_SUITE)?.double(forKey: lastReloadKey) ?? 0
    let timeSinceLastReload = Date().timeIntervalSince1970 - lastReloadEpoch
    guard timeSinceLastReload > minReloadInterval else {
        debug(.watchManager, "🔄 widgetCenter_reload_rate_limited time_since_last=\(Int(timeSinceLastReload))s")
        return
    }

    // No snapshot age guard. Callers save before calling this function, so latestSnapshot()
    // always reflects just-saved data — a post-save age guard reads ~fresh and blocks the
    // reload in precisely the scenario this function is designed for (first fresh reading
    // after a sleep gap). The stale-backlog concern that motivated the guard is addressed
    // upstream by R1b's queue draining. The rate limiter above is the correct backstop
    // against reload storms.

    // Read snapshot for diagnostics BEFORE triggering reload — measures the actual I/O
    // latency on this call path, not a post-reload cold read.
    let snapshotReadStart = Date()
    let reloadSnapshot = TrioComplicationDataStore.shared.latestSnapshot()
    let snapshotReadMs = Int(Date().timeIntervalSince(snapshotReadStart) * 1000)
    let reloadSnapshotEpoch = reloadSnapshot.map { Int($0.readingDate.timeIntervalSince1970) } ?? -1
    let snapshotAge = reloadSnapshot.map { Date().timeIntervalSince($0.readingDate) } ?? .infinity
    // snapshotReadMs expected <5ms (confirmed ~200 bytes, Cursor Round 2). If >20ms, move to background queue.

    // Stale-backlog detection: the signature is snapshotAge ≈ receivedGap, meaning the snapshot
    // barely advanced relative to the gap that triggered this reload — the first delivery after
    // reconnect was old backlog, not fresh data. A fixed threshold (e.g. 600s) would misclassify
    // legitimate sensor warmup gaps (>10 min without a reading). Using gap - 60 as the threshold
    // only flags cases where the snapshot is nearly as old as the gap itself.
    let isStaleBacklog = snapshotAge > (receivedGap - 60)
    if isStaleBacklog {
        debug(.watchManager, "⚠️ reload_with_stale_snapshot reading_epoch=\(reloadSnapshotEpoch) snapshot_age=\(Int(snapshotAge))s received_gap=\(Int(receivedGap))s snapshot_read_ms=\(snapshotReadMs) — reload still firing; rate limiter prevents storm")
    } else {
        debug(.watchManager, "🔄 widgetCenter_reload_triggered reading_epoch=\(reloadSnapshotEpoch) snapshot_age=\(Int(snapshotAge))s received_gap=\(Int(receivedGap))s snapshot_read_ms=\(snapshotReadMs)")
    }

    // WidgetCenter is the correct API for WidgetKit-based complications.
    // CLKComplicationServer is for legacy ClockKit and will not work here.
    // Kind string confirmed by Cursor Round 2: TrioComplicationDataStore.complicationKind = "TrioWatchComplication"
    UserDefaults(suiteName: APP_GROUP_SUITE)?.set(Date().timeIntervalSince1970, forKey: lastReloadKey)
    WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)
}
```

> **Why no snapshot age guard:** Callers save before calling this function, so `latestSnapshot().readingDate` always reflects just-saved data — a `> 300s` guard would always block the reload in the primary scenario (fresh reading arriving after a sleep gap). R1b's queue draining eliminates stale-backlog deliveries upstream. The 5-minute rate limiter is the correct storm guard. The `reload_with_stale_snapshot` warning log catches the rare reconnect-ordering edge where a stale userInfo slips through before R1b drains the queue.

> **`latestSnapshot()` thread safety (confirmed):** Safe to call on main — ~200 bytes, already multi-thread-safe in production. No background queue needed. If `snapshot_read_ms` ever logs >20ms in production, move the read to a background queue.

> **Process-restart behaviour:** With App Group persistence, the gap survives extension restarts. The rate limiter's `lastWidgetReloadAt` also persists, so a fresh restart won't cause a reload storm.

### R5e — BetterStack budget exhaustion alert

```sql
SELECT count() AS exhausted_count
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 30 MINUTE
  AND JSONExtract(raw,'message','Nullable(String)') LIKE '%budget_exhausted=true%'
  AND JSONExtract(raw,'message','Nullable(String)') LIKE '%via=userInfo%'
  AND JSONExtract(raw,'platform','Nullable(String)') = 'ios'
HAVING exhausted_count > 5
```

Set severity: **Warning** — `transferUserInfo` fallback still delivers data, just with latency.

### R5f — WidgetKit timeline and snapshot validation logging

The complication can render fresh data from **both** WidgetKit entry paths: `getTimeline` and `getSnapshot`. Both load from the App Group snapshot via `latestSnapshot()`. A chart based only on `complication_get_timeline_called` is **not** a complete visible-recency chart — the face can show fresh data from `getSnapshot` without any `getTimeline` call. R5f specifies observability for both entry points (complication extension / WidgetKit only; not HealthKit observer events).

Add to `getTimeline(in:completion:)` in `Trio Watch Complication/TrioWatchComplication.swift` after building entries (~line 229):

```swift
// R5f: timeline_entry_epoch — validates WidgetKit is picking up fresh App Group data.
// Confirmed by Cursor Round 2: TrioWatchComplicationEntry.readingDate is the CGM reading
// timestamp; date is the WidgetKit display time (distinct). All 30 entries share the same
// readingDate but have different date values (1 per minute).
if let firstEntry = entries.first {
    debug(.complication, "📅 timeline_built entry_count=\(entries.count) reading_epoch=\(Int(firstEntry.readingDate.timeIntervalSince1970)) snapshot_age=\(Int(Date().timeIntervalSince(firstEntry.readingDate)))s")
}
```

This gives `reading_epoch` and `snapshot_age` at timeline-build time. If `save_age` is fresh but `snapshot_age` here is stale, WidgetKit is not picking up the App Group writes — indicates the complication kind string is wrong or the App Group container is mismatched.

**WidgetKit entry-path events (R6.1 logging enhancement):**

**A. Timeline path — `event=complication_get_timeline_called`** (emitted when `getTimeline` is invoked):

- **`get_timeline_at_epoch_seconds`** — Unix epoch seconds when `getTimeline` was invoked or when the event is logged. Intended computation: `Int(Date().timeIntervalSince1970)` at the start of `getTimeline` or immediately before the event is logged.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to build the timeline. Intended computation: after loading the snapshot that will be returned to WidgetKit for this timeline, `max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))`. If there is no valid reading date (e.g. placeholder or fallback), use a sentinel such as `-1`. This must be based on the snapshot actually returned to WidgetKit for that timeline, not on the most recent saved snapshot from some other code path.

**B. Snapshot path — `event=complication_get_snapshot_called`** (emitted when `getSnapshot` is invoked):

- **`get_snapshot_at_epoch_seconds`** — Unix epoch seconds when `getSnapshot` was invoked or when the event is logged.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to produce the snapshot entry. Compute from the snapshot loaded and used to build the entry returned to WidgetKit on this path. Use the same sentinel (e.g. `-1`) when there is no valid reading date.

In both A and B, `data_age_seconds` must be computed from the snapshot **actually used to build the WidgetKit entry returned on that path** — not from some other save/reload path, and not from "latest known reading" in the abstract.

**Observability framing:**

- **Timeline-generation observability** — driven by `event=complication_get_timeline_called`; measures when timelines are built and with what data age.
- **Snapshot-generation observability** — driven by `event=complication_get_snapshot_called`; measures when snapshots are produced and with what data age.
- **Visible recency** — to approximate what the user actually saw, **both** paths matter. getTimeline logging alone does **not** reconstruct all visible refreshes; getSnapshot can show fresh data without any getTimeline call. getTimeline logging is still useful and should be kept for timeline-refresh analysis.

**Rationale:** These events and fields make timeline and snapshot generation directly queryable and support better reconstruction of visible recency in Better Stack Explore when both events are used. They avoid inferring visibility solely from `complication_save_age` or reload events.

**Scope boundary:** This R5f enhancement does not change reload logic, dedup logic, HealthKit behavior, trend/delta derivation, or WidgetKit scheduling. It only improves observability of what WidgetKit rendered or prepared to render on each entry path.

**Better Stack / sawtooth:** A sawtooth built only from `complication_get_timeline_called` is a **timeline-refresh sawtooth**, not a full visible-recency sawtooth. To better reconcile charts with cases where the face shows "NOW" without a logged getTimeline, snapshot logging is also needed. Better Stack Explore can use both events to better understand actual visible freshness. This may still not translate cleanly to standard metric-bucket dashboards because of as-of / point-in-time reconstruction limits.

**Chart naming / interpretation:** A chart based only on `complication_get_timeline_called` should be interpreted as **timeline-recency** or **timeline-refresh recency**. If the goal is actual **visible recency**, include `complication_get_snapshot_called` in the analysis as well.

---

## R6 — HealthKit Background Delivery (Step 7)

**Priority:** P2 | **Effort:** Medium (~4–6 hrs including entitlement provisioning)

**Ship order (historical):** R6 shipped before R4 (build 140, 2026-03-14) — see §Decision Gate. Rationale at the time: R4 would have done nothing for the 24-minute gap observed prior to build 140 because the data was already in the App Group and the problem was WidgetKit not calling `getTimeline`. R6 gives an independent system-triggered wake that fires when new glucose data arrives in HealthKit, giving the watch extension an additional opportunity to call `reloadTimelines`. R4 remains valuable for budget-exhaustion coverage — it is still pending as of this writing. R4 and R6 touch different files and can ship as separate PRs or be bundled.

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
3. **Recommended:** Option 2 initially. Add delta-based trend derivation as R6.1 (spec complete — see §R6.1, ready for implementation). Log `hk_trend_derived=false` so BetterStack can track the channel's display fidelity vs WatchConnectivity deliveries.

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
| Trend not in HealthKit metadata (derivation complexity) | Medium | Ship with `trend=""` initially. Complication shows glucose + delta. Add delta-based trend derivation in R6.1 (spec complete — see §R6.1) |
| HealthKit sync latency not Apple-SLA'd | Medium | Sync depends on Bluetooth proximity and system scheduling. Expect 10–60s in typical conditions, potentially minutes. HealthKit is supplementary to WatchConnectivity, not a replacement |
| `enableBackgroundDelivery` not re-registered after crash/restart | Medium | Call `setupHealthKitBackgroundDelivery()` in `WatchState.init()` / `setupSession()` on every launch. Registration is idempotent |
| `completionHandler` not called (system penalizes app) | High | Call on all paths: error/zero-samples paths before return; success path inside `DispatchQueue.main.async` after save. Do not use `defer` at closure exit — that signals "done" before the async save runs. |
| HealthKit read authorization denied by user | Medium | Watch must request read authorization for `.bloodGlucose`. If denied, observer never fires. Log `hk_authorization_failed`. Falls back to WatchConnectivity-only — no regression |
| Trend arrow overwrite in normal operation | Low | HK snapshot (`trend=""`) overwrites WC snapshot's real trend when both channels deliver same reading. Transient — restored on next WC delivery (~5 min). Glucose and delta remain correct. Acceptable tradeoff; add delta-based trend derivation in R6.1 (spec complete — see §R6.1) |
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
1. **Budget exhaustion:** During hours where `complication_transfer_remaining=0`, `hk_observer_fired` events should appear with `save_age` p90 < 300s — confirms HealthKit delivers when WatchConnectivity budget is exhausted.
2. **WidgetKit scheduling gaps:** `reload_age` p90 < 300s overall (not just exhaustion windows). The `hk_observer_fired` → `reloadTimelines` path provides an independent wake trigger that should reduce gaps where fresh data sits in the App Group unread.

**New structured log event:** `hk_observer_fired reading_epoch=X save_age=Y glucose=Z delta=D` — distinguishable from WatchConnectivity deliveries via `msg LIKE '%hk_observer_fired%'` vs `msg LIKE '%didReceiveUserInfo%'` or `msg LIKE '%didReceiveMessage%'`.

### Decision Gate

**Actual ship order:** R6 shipped before R4 (build 140, 2026-03-14). R4 is still pending. The originally documented ordering ("Ship R6 after R4") was reversed — see implementation guide Part 2 sequencing note and build log.

Primary motivation for R6 was twofold:
1. **Budget-exhaustion windows:** HealthKit provides a WCSession-independent delivery channel when `complication_transfer_remaining=0`.
2. **WidgetKit scheduling gaps:** Observed in build 139 — 9-minute gap with fresh App Group data, `reload_age=548s`. The `HKObserverQuery` wake trigger fires when new glucose data arrives in HealthKit, giving the watch extension an independent opportunity to call `reloadTimelines`. This addresses a failure mode that R4 cannot fix (R4 still depends on WidgetKit's scheduling to pick up App Group writes).

Do not gate R6 on budget-exhaustion metrics alone. The two failure modes are distinct — R4 addresses the data delivery gap during exhaustion, R6 addresses WidgetKit's scheduling latency via an independent wake trigger.

---

## R6.1 — HealthKit Channel Improvements

**Priority:** P2 | **Status:** Spec complete — ready for implementation

### Builds on R6

R6 established the watch-side HealthKit observer and background delivery path in build 140. The watch extension registers an `HKObserverQuery` for `.bloodGlucose` with `enableBackgroundDelivery(for:frequency:.immediate)`, fetches the latest samples via `HKSampleQuery`, constructs a `TrioComplicationSnapshot`, and saves through the existing `TrioComplicationDataStore.shared.save()` path. This channel operates entirely outside of WatchConnectivity.

R6.1 is a refinement of the HK fetch and processing path, not a replacement of R6's high-level strategy. The observer registration, authorization flow, entitlements, and background delivery mechanics remain unchanged. R6.1 does NOT change the claim that HealthKit is an independent wake path outside WatchConnectivity.

### Motivation

R6 delivered a working HealthKit channel in build 140, but several areas have known room for improvement:

1. **Non-incremental fetch:** R6 uses `HKSampleQuery` to fetch the latest 2 samples on every observer fire. This re-fetches samples the extension has already processed. An anchored query would advance past previously seen samples and only return genuinely new ones.

2. **Phantom observer fires:** The `HKObserverQuery` fires when the sample database changes for `.bloodGlucose` — including metadata updates, deletions, and cross-device sync events that do not represent a new CGM reading. R6 processes every fire identically, logging `hk_observer_fired` even when the "latest" sample was already handled. Cleaner classification is needed to separate real new-sample events from phantom fires.

3. **Same/latest sample handling:** Without a persisted "last seen" marker, R6 cannot deterministically detect when the observer fired but no new sample arrived. A persisted epoch allows a fast exit on known-epoch fires and prevents redundant snapshot saves.

4. **Trend fidelity:** R6 ships `trend=""` on all HealthKit-derived snapshots. When the HK delivery overwrites a WC-delivered snapshot in dual-delivery mode, the trend arrow is temporarily lost (see R6 "Dedup and Dual-Delivery Behavior"). Deriving a trend from consecutive samples improves display fidelity without waiting for iPhone-side metadata changes.

5. **Instrumentation gaps:** R6 logs `hk_observer_fired` for all fires uniformly. There is no distinction between "observer fired with a genuinely new sample" and "observer fired but latest sample was already processed." Separating these events improves observability and makes phantom-fire rate measurable.

R6.1 improves correctness and observability of the HealthKit channel. R6.1 does NOT reduce Apple-controlled cross-device HealthKit sync latency — sync timing remains dependent on Bluetooth proximity, system scheduling, and Apple's internal sync policy.

### Design

R6.1 specifies the replacement of the R6 HK fetch path with an `HKAnchoredObjectQuery`-based approach:

- **Replace `HKSampleQuery` with `HKAnchoredObjectQuery`:** The anchored query returns only samples added or changed since the last query anchor, eliminating redundant re-fetching of already-processed samples.
- **Persist query anchor:** The `HKQueryAnchor` returned by a successful anchored query is always saved to App Group storage — regardless of whether the result leads to a snapshot save. This includes normal new-sample processing, no-new-samples phantom fires, and epoch-guard skips. Only query errors and pre-query guard failures leave the anchor unchanged. This prevents repeated delivery of the same already-processed or empty-result state on later observer fires.
- **Persist last received glucose epoch and value:** An independent `TimeInterval` recording the `startDate` epoch of the most recently processed glucose sample, plus the glucose value in mg/dL. The epoch is used as a post-query guard to skip re-delivered/modified samples. The persisted value enables delta and trend derivation for the common steady-state case where the anchored query returns only one new sample.
- **Use latest sample for display:** The most recent sample by `startDate` in the anchored query result drives the `TrioComplicationSnapshot` glucose value and reading date. Recency must be determined by sorting the added samples by `startDate`, not by relying on the raw array order returned by `HKAnchoredObjectQuery` — store-insertion order is not guaranteed to be chronological, especially during backfill, sync catch-up, or retroactive sample delivery.
- **Delta/trend from current + previous sample:** When the anchored query returns two or more new samples (e.g., backfill), the second-most-recent sample by `startDate` in the batch provides the previous value. In the common steady-state case (one new sample per fire), the persisted previous glucose value and epoch serve as the prior sample. This ensures delta and trend derivation works on every normal CGM interval, not just multi-sample batches.

This remains a single-save-per-fire design, not one-save-per-sample. Backfill batches (e.g., after app suspension or extended background) advance the anchor across all returned samples but produce only one snapshot, one save, and one reload attempt.

### Anchor Lifecycle

| Scenario | Behavior |
|---|---|
| **First run (nil anchor)** | Query executes with `nil` anchor, which returns all matching samples. To avoid processing the full HealthKit history, the query includes a date predicate capping results to the last 24 hours. The returned anchor is saved for subsequent queries. |
| **Normal operation** | Query executes with the persisted anchor. Only samples added since the last anchor are returned. Anchor advancement, epoch/value persistence, and snapshot save follow the rules described in the rows below. |
| **Anchor advancement rule** | The new `HKQueryAnchor` is saved via `TrioComplicationDataStore` after every successful query that returns a non-nil `newAnchor` — including no-new-samples and epoch-guard-skip exits, not just the normal new-sample path. The anchor tracks HealthKit's internal query position, not whether the app saved a snapshot. On the normal new-sample path, the anchor advances even if the snapshot save is debounced or rejected by dedup. On no-new-samples and epoch-guard-skip paths, the anchor advances but the persisted epoch and glucose value are NOT updated (no new sample was processed). Query errors and pre-query guard failures do NOT advance the anchor. |
| **Anchor decode failure** | If the persisted anchor data cannot be decoded (e.g., data corruption, watchOS version change altering serialization format), the query falls back to nil anchor behavior with the 24-hour date cap. A `hk_anchor_decode_failed` event is logged. The new anchor from the fallback query is saved normally. |
| **Epoch guard (post-query)** | After the anchored query returns results, the latest returned sample's epoch is compared to the persisted last-received epoch. If they match: the new anchor is saved (see anchor advancement rule), a `hk_observer_skipped_known_epoch` event is logged, and the observer exits without saving a snapshot or updating the persisted epoch/value. This is primarily an edge-case filter for modified or re-delivered samples — samples the anchored query returns as "changed" even though the glucose value and timestamp have not changed. The anchored query's "zero new samples" result handles the majority of phantom fires; the epoch guard catches the remainder. |
| **Deletion handling** | `HKAnchoredObjectQuery` returns both added samples and deleted objects. Deleted objects are ignored for complication freshness purposes — a deletion does not affect the current display. Modified/re-delivered samples (returned as re-added) are caught by the epoch guard above. |

First run should cap backfill to the last 24 hours to avoid processing an unbounded sample history on fresh install or anchor reset.

Anchor, epoch, and previous-sample value are independent persistence paths. The anchor tracks HealthKit's internal query position; the epoch and value track the last glucose sample the extension actually processed. All are persisted but none depends on another's value.

### TrioComplicationDataStore Additions

R6.1 specifies six new persistence methods in `TrioComplicationDataStore`:

| Method | Purpose |
|---|---|
| `hkGlucoseAnchor() -> Data?` | Read the persisted `HKQueryAnchor` as encoded `Data` |
| `saveHKGlucoseAnchor(_ data: Data)` | Write the `HKQueryAnchor` encoded data to App Group storage |
| `hkLastReceivedGlucoseEpoch() -> TimeInterval` | Read the epoch (`startDate.timeIntervalSince1970`) of the most recently processed glucose sample |
| `setHKLastReceivedGlucoseEpoch(_ epoch: TimeInterval)` | Write the last-received epoch to App Group storage |
| `hkLastReceivedGlucoseValueMgDl() -> Double` | Read the glucose value (mg/dL) of the most recently processed sample |
| `setHKLastReceivedGlucoseValueMgDl(_ value: Double)` | Write the glucose value (mg/dL) of the most recently processed sample |

The epoch and value methods together provide the "previous sample" data needed for delta and trend derivation when the anchored query returns only one new sample (the common steady-state case).

**Derive-then-persist ordering:** On the genuinely new-sample path, delta and trend must be derived from the persisted previous epoch/value (or second-most-recent batch sample by `startDate`) *before* the current sample's epoch and value are persisted. Overwriting the previous-sample state before derivation would destroy the data needed for delta/trend computation. After derivation, the current sample's epoch and value are persisted, becoming the "previous" for the next fire. On no-new-samples and known-epoch-skip paths, epoch/value are not updated.

These methods belong in `TrioComplicationDataStore` because App Group persistence for the watch complication system is centralized there. All existing snapshot, fingerprint, and complication metadata persistence already flows through this class.

**Anchor serialization:** `HKQueryAnchor` conforms to `NSSecureCoding`, not `Codable`. It must be serialized via `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` and deserialized via `NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from:)`. This is the same pattern used by LoopKit's `PersistenceController.storeAnchor`/`fetchAnchor`. Decode failures should log `hk_anchor_decode_failed` and fall back to nil-anchor + 24h cap behavior.

**Raw `UserDefaults(suiteName:)` usage in `WatchState` is explicitly forbidden for R6.1 persistence.** `WatchState` should call through `TrioComplicationDataStore` for anchor, epoch, and previous-sample storage, maintaining the existing pattern where `WatchState` is a consumer of the data store, not a direct App Group accessor.

### WatchState Changes

R6.1 modifies the HK fetch/processing path in `WatchState.swift` at a design level:

- **Replace the sample-query helper with an anchored-query helper:** The planned change to `fetchLatestGlucoseFromHealthKit(completionHandler:)` replaces `HKSampleQuery` (fetch last 2, no state) with `HKAnchoredObjectQuery` (fetch since last anchor, stateful).
- **Keep unchanged (function shape):**
  - `setupHealthKitBackgroundDelivery()` — authorization request, background delivery registration, and observer setup call. **One targeted log-line change:** the `hk_background_delivery_registered` log call gains `low_power_mode=ProcessInfo.processInfo.isLowPowerModeEnabled`. No other change to function body.
  - `setupGlucoseObserverQuery(store:sampleType:)` — observer registration shape
  - `HKObserverQuery` creation and execution
  - Entitlements and Info.plist
  - HealthKit authorization flow
- **Only the fetch/processing portion changes in R6.1.** The observer callback signature, the `completionHandler` contract, and the outer structure remain identical.

The observer callback must still call `completionHandler()` on every path — error, no-new-samples, known-epoch skip, and success. This requirement is unchanged from R6.

**`fire_id` lifecycle:** A `UUID` is generated once at the start of each observer callback invocation. This `fire_id` is threaded through all subordinate functions called from that observer fire — the anchored query, persistence calls, and all log events. It is not regenerated per helper or per save. This allows correlating all log events from a single observer wake in BetterStack.

The successful save path still flows through `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)`, which triggers `coalescedReloadOnMain` only when the snapshot passes dedup and the minimum interval has elapsed. R6.1 does not change the save path, dedup behavior, or reload conditions. Accepted saves trigger a reload attempt; the reload is still subject to the existing debounce.

### Source Predicate Decision

R6.1 specifies the following source filter for the anchored query:

**Selected:** `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)`

**Rationale:**
- Trio-written glucose samples already include `HKMetadataKeySyncIdentifier` in their metadata (set during `uploadGlucose` in `HealthKitManager.swift`).
- This is a presence-only predicate: it returns any sample that has the key set, regardless of the key's value.
- Filters out samples that lack sync identifiers entirely (e.g., manually entered glucose readings), reducing phantom fires from non-synced sources.
- Avoids hardcoded bundle-ID string filtering, which is fragile and requires knowledge of the iPhone app's exact bundle identifier from the watch extension.

**Residual risk — practical, not theoretical:** `HKMetadataKeySyncIdentifier` is a standard Apple-recommended metadata key used by any HealthKit-writing app that coordinates sync to prevent duplicate imports. Other diabetes apps (Loop, xDrip, Nightscout uploader, etc.) commonly set this key on their blood glucose samples. In a multi-app setup where another glucose-writing app is active, the presence-only predicate will include that app's samples in the anchored query results. This could produce unexpected delta/trend values if the "previous" sample came from a different source with different timing. Severity is low-to-medium: the glucose values would still be valid readings, but trend derivation across sources could be misleading. Acceptable for R6.1 as a practical tradeoff. Value-specific filtering (matching Trio's UUID format) or bundle/source refinement can be pursued in R6.2 if over-inclusion is observed in practice.

**As implemented:** R6.1 shipped without applying this predicate. The current implementation uses a 24h date cap when the anchor is nil (first run or anchor decode failure) and nil predicate when an anchor exists. SyncIdentifier/source filtering is explicitly deferred to R6.2 or equivalent follow-up.

### Delta and Trend Derivation

R6.1 specifies delta and trend derivation from consecutive glucose samples. Both use a single numeric delta computed from the same pair of samples, and the trend direction is classified using the same raw-delta threshold mapping established in the Trio codebase:

- **Input:** Latest sample by `startDate` (from current anchored query result) and previous sample (second-most-recent by `startDate` in batch, or persisted previous glucose value/epoch for single-sample steady-state fires). Delta and trend derivation must use the same selected previous sample on a given fire — do not derive delta from one source and trend from another.
- **Numeric delta:** Compute the raw numeric delta first (`latestMgDl - previousMgDl`), then round once to obtain the integer used for both trend threshold mapping and the display delta string. That is: `rawDeltaMgDl = latestMgDl - previousMgDl`; `deltaInt = Int(rawDeltaMgDl.rounded())`. This single rounded integer serves as the input to the trend threshold mapping and the basis for `TrioComplicationSnapshot.delta` (e.g. `"+5"`, `"-12"`). Do not round each endpoint and subtract, which can change the bucket and display at threshold boundaries.
- **Gate:** Trend is only derived when `0 < timeDelta < 15 minutes`. This ensures the two samples are plausibly consecutive CGM readings (typical CGM interval is 5 minutes; 15 minutes allows for one missed reading).
- **Threshold mapping:** Apply the integer delta directly to the same threshold family as `BloodGlucose.Direction.init(trend:)` in `BloodGlucoseExtensions.swift`. R6.1 does not use a separate floating-point threshold system — the integer delta is the threshold input:

| Delta (mg/dL) | Direction |
|---|---|
| <= -30 | `DoubleDown` |
| <= -20 | `SingleDown` |
| <= -10 | `FortyFiveDown` |
| < 10 | `Flat` |
| < 20 | `FortyFiveUp` |
| < 30 | `SingleUp` |
| >= 30 | `DoubleUp` |

- **Output format:** The trend string stored in `TrioComplicationSnapshot.trend` must use the same raw direction string format as the WatchConnectivity path — e.g., `"Flat"`, `"FortyFiveUp"`, `"SingleUp"`, `"DoubleUp"`, `"FortyFiveDown"`, `"SingleDown"`, `"DoubleDown"`. This aligns with the existing `TrendSymbolMapper.symbol(from:)` in `TrioWatchComplication.swift` which converts these strings to display symbols. Do NOT output symbol glyphs directly.
- **Display delta formatting:** The display delta string stored in `TrioComplicationSnapshot.delta` is produced by formatting the same integer numeric delta (e.g., `"+5"`, `"-12"`). R6.1 formats delta in mg/dL only; mmol/L display parity with the WC path is deferred (see inherited unit note below).
- **Fallback:** When the plausibility gate fails (samples too far apart, no previous sample available, or time delta is zero/negative), both trend and delta fall back: trend to `""` (no arrow), delta to the existing no-derivation behavior (e.g., `"--"` or blank per the HK path's no-previous-sample handling). Do not synthesize trend or delta from unrelated or implausible samples. This applies regardless of whether the missing/invalid previous sample comes from the current batch or from persisted previous-sample state.

This aligns R6.1 with Trio's existing direction semantics. The `BloodGlucose.Direction` type and `init(trend:)` live in the iOS target (`Trio/Sources/APS/Extensions/BloodGlucoseExtensions.swift`) and may not be directly importable on the watchOS target. The implementation may need to duplicate the threshold switch statement for the watch extension, or extract it to a shared target. The threshold values and raw direction strings must match the iPhone-side mapping.

This improves display fidelity on HealthKit-derived snapshots — in R6, `trend=""` on every HK delivery caused trend arrow loss during dual-delivery overwrite. R6.1 provides a derived trend on most normal CGM intervals. When R6.1 produces the same raw direction string as the WC path for the same reading, `shouldUpdate` may return `false` for same-reading dual delivery, reducing or eliminating the R6 trend-overwrite regression.

Trend derivation does not affect Apple-controlled cross-device sync timing. It improves the content quality of HK-delivered snapshots once they arrive.

**Inherited unit note:** R6 (and by extension R6.1) computes delta in mg/dL from HealthKit samples. The WC path formats delta using the user's preferred units (mg/dL or mmol/L). For mmol/L users, HK-derived deltas and WC-derived deltas will have different string representations for the same reading (e.g., HK `"+5"` vs WC `"+0.3"`), which affects `shouldUpdate` dedup behavior — the HK snapshot will not be recognized as a duplicate of the WC snapshot. R6.1 does not solve this unit-format parity; it is inherited from R6 and deferred unless separately scoped.

**Derivation scope boundary:** R6.1 adds derivation logic for `delta` and `trend` only. The following snapshot fields and behaviors are intentionally NOT changed by R6.1:

- `glucoseColor` — remains `nil` on HK-derived snapshots. Color derivation is not in scope.
- `state` — not synthetically derived from HK data. Remains as-is from the existing HK path.
- Display-unit parity — HK-derived delta is formatted in mg/dL only. mmol/L formatting to match the WC path is deferred (see inherited unit note above).
- `sync_lag` — used for logging and observability only. Not used in display rendering, dedup logic, or trend derivation.

This is an intentional scope boundary, not a future roadmap commitment.

### Updated Log Taxonomy

R6.1 adds and refines the following structured log events:

| Event | Fields | When |
|---|---|---|
| `hk_background_delivery_registered` | `success=Bool low_power_mode=Bool` | App launch, authorization granted. `success` is the value returned by `enableBackgroundDelivery(for:frequency:completion:)`. `low_power_mode` = `ProcessInfo.processInfo.isLowPowerModeEnabled` at registration time — records whether Low Power Mode may affect background delivery cadence. Log with `✅` when `success=true`, `⚠️` when `success=false`. |
| `hk_background_delivery_registration_failed` | `error=String` | App launch, registration failed |
| `hk_authorization_failed` | `granted=Bool error=String` | Authorization request denied |
| `hk_observer_error` | `fire_id=UUID error=String` | Observer query error callback |
| `hk_observer_fired` | `fire_id=UUID reading_epoch=Int sync_lag=Int glucose=String delta=String trend=String trend_derived=Bool samples_in_batch=Int query_type=anchoredQuery` | Each observer fire that processes a new sample |
| `hk_observer_no_new_samples` | `fire_id=UUID` | Anchored query returned zero new samples (phantom fire) |
| `hk_observer_skipped_known_epoch` | `fire_id=UUID epoch=Int` | Latest sample epoch matches persisted last-received epoch |
| `hk_observer_query_error` | `fire_id=UUID error=String` | Anchored query returned an error |
| `hk_observer_guard_failed` | `fire_id=UUID reason=String` | Pre-query guard failed (e.g., nil store, nil sample type) |
| `hk_observer_nil_anchor` | `fire_id=UUID` | First run or anchor decode failure; query executed with nil anchor + 24h date cap |
| `hk_anchor_decode_failed` | `fire_id=UUID` | Persisted anchor data could not be decoded |

**R6-only events replaced in R6.1:**

| R6 Event | R6.1 Replacement | Reason |
|---|---|---|
| `hk_observer_sample_query_error` | `hk_observer_query_error` | Query type changes from `HKSampleQuery` to `HKAnchoredObjectQuery` |
| `hk_observer_sample_query_zero_samples` | `hk_observer_no_new_samples` | Semantics change: zero new samples (incremental) vs zero total samples (non-incremental) |

The `query_type=anchoredQuery` field on `hk_observer_fired` is the primary way to distinguish R6.1 logs from build-140 R6 logs in BetterStack queries. R6 logs do not include `query_type`.

**R6 → R6.1 field-level rename on `hk_observer_fired`:** R6 uses `save_age=Int`; R6.1 renames this to `sync_lag=Int`. The semantics are identical (`now() - readingDate`), but the name better reflects that the measurement captures end-to-end lag, not just save timing. BetterStack queries spanning R6 and R6.1 builds must account for this rename (e.g., filter on `msg LIKE '%save_age=%'` for R6, `msg LIKE '%sync_lag=%'` for R6.1).

**New `trend` field on `hk_observer_fired`:** R6.1 adds `trend=String` alongside the existing `trend_derived=Bool`. The `trend` field contains the actual derived raw direction string (`"Flat"`, `"FortyFiveUp"`, `"SingleUp"`, `"DoubleUp"`, `"FortyFiveDown"`, `"SingleDown"`, `"DoubleDown"`) or `""` when trend derivation was not possible. This allows BetterStack queries to validate threshold mapping correctness, WC/HK format alignment, and same-reading dual-delivery dedup expectations — not just whether trend was derived, but what value was produced. R6 does not include a `trend` field on `hk_observer_fired` (R6 always sets `trend=""`).

### Latency Domains — What R6.1 Instrumentation Separates

> **Three latency domains in the HealthKit channel:**
>
> 1. **iPhone write time** — when the iPhone Trio app writes the `HKQuantitySample` to HealthKit after receiving a CGM reading. This is app-controlled and typically near-instant.
>
> 2. **Cross-device HK sync latency** — the time between the iPhone writing the sample and the watch's HealthKit store receiving it. This is entirely Apple-controlled and depends on Bluetooth proximity, system scheduling, and watchOS background activity state. Typical range: 10–60 seconds, but can be minutes.
>
> 3. **App processing latency** — the time between the observer firing on the watch and the snapshot being saved to the App Group. This is app-controlled and should be < 1 second under normal conditions.
>
> **What `sync_lag` measures:** The `sync_lag` field on `hk_observer_fired` is computed as `now() - readingDate.timeIntervalSince1970` at the point of logging. It captures iPhone-write time + cross-device sync time + watch-side observer/query processing time up to the log statement. It does NOT isolate pure Apple sync latency, and it also includes non-trivial watch-side processing (anchor decode, query execution, sample sorting) that occurs before the log is emitted.
>
> **Estimating post-log processing:** Comparing `hk_observer_fired.dt` to the subsequent snapshot-save log's `dt` estimates only the remaining post-log processing time (snapshot construction, main-thread dispatch, save + reload). Watch-side logs cannot fully decompose total latency into perfectly separate buckets — the three domains are a conceptual model, not a clean measurement decomposition.

### Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Anchor decode/serialization failure | Medium | Fall back to nil anchor with 24h date cap. Log `hk_anchor_decode_failed`. No data loss — just a one-time re-fetch of recent samples. Anchor is re-saved on next successful query. |
| Source predicate over-inclusion | Low–Medium | `HKMetadataKeySyncIdentifier` is a standard Apple sync key used by multiple diabetes/HealthKit apps. Presence-only filtering may include non-Trio samples in multi-app setups. Accepted tradeoff for R6.1; refine to value-specific or bundle/source filtering in R6.2 if observed. |
| Trend derivation false confidence | Low | The 15-minute gate prevents deriving trend from non-consecutive samples (e.g., after a sensor gap). When the gate fails, trend falls back to `""` — no misleading arrow. Risk is that two consecutive-looking samples from different CGM sessions could produce a valid-looking but incorrect trend; severity is low because delta magnitude would typically be anomalous in that case. |
| Increased log/analysis complexity | Low | R6.1 adds more event types and fields than R6. BetterStack queries must filter on `query_type=anchoredQuery` to isolate R6.1 events from build-140 R6 logs. The added granularity improves diagnosability but requires updated query templates. |

### Validation Approach

R6.1 should be validated relative to the build 140 R6 baseline. Key areas:

| Area | Validation method | Pass condition |
|---|---|---|
| **Phantom fire rate** | Compare `hk_observer_no_new_samples` count to total `hk_observer_fired` + `hk_observer_no_new_samples` count over 24h. In R6, all fires are logged as `hk_observer_fired` regardless of whether new data existed. | Phantom fire events are classified separately; rate is measurable and not the majority of total fires. |
| **Trend derivation coverage** | Count `hk_observer_fired` events with `trend_derived=true` vs `trend_derived=false` over a 24h window with active CGM. Also inspect `trend=<value>` to verify threshold mapping produces expected direction strings. | `trend_derived=true` on the majority of normal CGM intervals (consecutive 5-min readings). Derived `trend` values are valid direction strings. |
| **Anchored-query correctness** | Verify `samples_in_batch=1` on steady-state fires (one new sample per CGM interval). After app suspension, verify `samples_in_batch > 1` for backfill with a single save. For backfill batches, confirm that the saved snapshot's `reading_epoch` corresponds to the sample with the greatest `startDate` in the batch, not an earlier sample. | Batch size matches expected sample cadence. No duplicate saves from multi-sample batches. Displayed snapshot uses the most recent sample by `startDate`. |
| **Known-epoch skip** | Count `hk_observer_skipped_known_epoch` events over 24h. | Events appear on phantom fires where the latest sample was already processed; no skips for genuinely new samples (glucose/epoch changed). |
| **No duplicate save explosion** | Confirm that multi-sample backfill batches produce exactly one `Snapshot saved` log per observer fire, not one per sample. | One snapshot save per fire, regardless of `samples_in_batch`. |

**Source-predicate over-inclusion note:** If derived delta or trend values appear anomalous relative to expected CGM behavior — especially in multi-app HealthKit setups — consider source-predicate over-inclusion before treating it as an implementation bug. The presence-only `HKMetadataKeySyncIdentifier` filter may include samples from other diabetes apps with different reading cadences or glucose sources. Symptoms include unexpected large deltas between consecutive samples or trend directions that don't match the user's CGM display. This is a known R6.1 tradeoff; value-specific or bundle/source refinement is deferred to R6.2.

### WC Failure Mode Scenarios

R6.1 improves the HealthKit channel, not WatchConnectivity. These scenarios describe why R6.1 still matters when WC is degraded or absent:

| Scenario | WC state | HK state | R6.1 behavior |
|---|---|---|---|
| **WC healthy + HK healthy** | Delivering normally | Observer fires, anchored query returns new sample | Both channels deliver. Because R6.1 produces the same raw direction strings as the WC path, `shouldUpdate` may return `false` for same-reading dual delivery (matching glucose, trend, delta, readingDate), preventing the HK overwrite entirely. If the delta differs due to unit formatting (see inherited unit note), the HK save still occurs but with a valid trend instead of R6's blank `""`. |
| **WC delayed/failing + HK healthy** | Budget exhausted, session degraded, or sendMessage failing | Observer fires, anchored query returns new sample | HK is the sole delivery channel. Anchored query provides incremental fetch; trend is derived from consecutive samples. Complication stays current via HK alone. |
| **HK fire with no new sample** | Any state | Observer fires but anchored query returns zero new samples (phantom fire) | R6.1 logs `hk_observer_no_new_samples` and calls `completionHandler()`. No snapshot save, no redundant reload. Clean classification vs R6, which would have re-fetched and potentially re-saved the same sample. |
| **Post-suspension backfill batch** | Any state | Observer fires after extended background; anchored query returns multiple samples | R6.1 processes the batch: advances anchor across all samples, uses the latest for display, derives trend if consecutive pair available, produces one snapshot save and one reload attempt. |

### Backlog / Status

| Item | Status | Notes |
|---|---|---|
| R6.1 — HealthKit Channel Improvements | Planned — spec complete, ready for implementation | Anchored-query design, anchor/epoch persistence location, source predicate decision, log taxonomy, and validation approach specified in this section. Not yet implemented. |

---



| Idea | Status | Evidence |
|---|---|---|
| #2 Trigger on `sessionReachabilityDidChange` | ✅ Already implemented | `AppleWatchManager.swift` lines 1042–1063 |
| #7 Early `WCSession.activate()` on watch | ✅ Already implemented | `WatchState.init()` → `setupSession()` at `applicationDidFinishLaunching` |
| #9 `WKApplication.scheduleBackgroundRefresh` | ✅ Already implemented | Adaptive 180–900s; called from 3 sites |
| #10 File protection on App Group snapshot | ✅ No action needed | Default protection is correct; `.completeFileProtection` would break background updates |
| #11 Preflight `WCSession` guard | ✅ Already implemented | Lines 200–226; all guards before CoreData fetches |
| #25 `saveLatestDateToDisk` blocking I/O | ✅ Non-issue | `UserDefaults.set()` is in-memory write |
| #23 `session.activate()` on iOS background | ⬇️ Low value | WCSession persists across background transitions |

---

## Backlog

| Idea | Cursor status | Disposition |
|---|---|---|
| #4 Proactive transfer on iOS app foreground | Not implemented | Deferred — R2 has now shipped; re-evaluate after R4 and R6.1 observation windows close |
| #6 Log `isReachable` duration at transfer | Not implemented | Low effort; add `lastReachabilityChangeDate: Date?` to `AppleWatchManager` |
| #8 sendMessage latency instrumentation | Partial | R5b — pending (Step 6) |
| #12 Coalescer trigger count + source logging | Not implemented | ✅ Shipped (build 133) — R5a / R2a |
| #13 Lightweight complication payload | Not implemented | ✅ Shipped (build 133) — R3 |
| #16 Sleep-gap forced reload | Not implemented | R5d — pending (Step 6) |
| #19 `WKExtendedRuntimeSession` for urgent glucose | Not implemented | High value for urgent-low; significant effort; separate project |
| #21 `didReceiveUserInfo` decode latency | Not implemented | R5c — pending (Step 6) |
| #24 Consistent `reading_epoch` across pipeline | Partial | Gaps at coalescer trigger and `didReceiveMessage`; closes with R5a + R5b |
| #28 WidgetKit `getTimeline` call clustering | Partial | Generation counter present; per-family clustering untracked; low priority |
| #30 Scheduled freshness alert | Not implemented | ✅ Shipped (build 132) — R5e |
| HealthKit background delivery on watch | ✅ Shipped (build 140) | R6 — live; `hk_observer_fired` confirmed |
| HealthKit channel improvements (anchored query, trend, observability) | 📋 Planned — spec complete | R6.1 — ready for implementation; not yet implemented |

---

## Implementation Sequence

```
R1a  (readingEpoch + transferEnqueuedAt keys in dict)  ─┐
R1b  (cancel stale queue — startup + before enqueue)    ├── one PR   ✅ SHIPPED (build 132)
R5e  (BetterStack exhaustion alert)                    ─┘

        ↓ deploy, collect 24h data

R5a / R2a  (coalescer source logging)    ← ship; collect 24h coalescer_fired data    ✅ SHIPPED (build 133)
R3         (allowlist complication msg,  ← parallel with R2a; no dependency          ✅ SHIPPED (build 133)
            watch-side prefer readingEpoch key)

        ↓ R2a data confirms publisher attribution

R2b  (epoch+fingerprint dispatch gate)               ← ship; observe 48h             ✅ SHIPPED (build 134)

Step 3b  (complication-age stale-first gate; T=600s) ← ship after R2b; observe 48h  ✅ SHIPPED (builds 137-138)

        ↓ if avg C ≤ 1.3 after 48h → R2c (optional, low priority)
        ↓ if avg C > 1.3 after 48h → R2d (pipeline split)
        (Decision gate: run avg C query ~2026-03-15 against build 137+ data)

R2c  (settings debounce — only if R2d not pursued)
R2d  (authoritative-source gating — if R2b insufficient; supersedes R2c)

R6   (HealthKit background delivery on    ← ✅ SHIPPED (build 140, 2026-03-14)
      watch — observer + sample fetch +      Shipped before R4; addresses both
      snapshot save to existing path)        budget-exhaustion and WidgetKit gaps

R4   (updateApplicationContext iOS +     ← PENDING — benefits from R3 payload being small;
      didReceiveApplicationContext watch)    ship after R6 observation period concludes

R5b + R5c + R5d  (observability)         ← PENDING — opportunistic, ship with R4 or next PR

R6.1 (HealthKit anchored query, trend    ← PENDING — spec complete, ready for implementation
      derivation, anchor persistence)       after R6 48h observation period
```

---

## Validation Protocol

Run 24 hours after each phase ships:

| Phase | Metric | Signal | Pass threshold | Falsified if |
|---|---|---|---|---|
| R1 | Queue depth | `queue_depth` in transfer logs | p95 < 5 | Remains > 10 |
| R1 | Stale delivery burst | `didReceiveUserInfo` rate/hr | < 15/hr | Unchanged |
| R2 | Transfers/reading | C count per `reading_date_epoch_seconds` | avg C ≤ 1.3 | avg > 1.5 |
| R2 | Budget drain rate | complication transfers/hr | < 15/hr | Drain > 18/hr |
| Step 3b | Budget spread | complication transfers vs. time since reset; `complication_transfer_age_gate_skipped` (skip_reason=age_gate); see also skip_reason=duplicate_gate, missing readingEpoch | Budget not exhausted in first 2–3h; skips when age ≤ T | Budget still exhausted in 3h; no age-gate skips when fresh |
| R3 | Payload size | `payload_bytes` in transfer logs | < 500 bytes | > 5 KB |
| R4 | Freshness during exhaustion | `save_age` where `budget_exhausted=true` | p90 < 300s | Unchanged |
| R5a | Publisher attribution | `coalescer_fired sources=` | No non-glucose source > 30% of multi-C readings | — |
| R5d | Widget actually advanced | `timeline_entry_epoch` in getTimeline logs | p90 age < 600s at time of `getTimeline` invocation | `save_age` fresh but `timeline_entry_epoch` stale → WidgetKit not picking up App Group writes |
| R6 | HealthKit delivery + WidgetKit wake | `hk_observer_fired` events; `reload_age` during WidgetKit scheduling gaps | `hk_observer_fired` present in exhaustion windows AND non-exhaustion gaps; `reload_age` p90 < 300s overall | No `hk_observer_fired` events; or `reload_age` unchanged in scheduling-gap windows |

---

## Decisions & Rejected Alternatives

This section documents deliberate choices to deviate from reviewer suggestions. Its purpose is to prevent the same feedback from being raised repeatedly and to give future reviewers the reasoning behind specific design decisions.

---

**R1b: Keep 1 transfer (not 2) as the post-drain target**

*Suggestion (ChatGPT critique #3):* Keep 2 transfers — "1 newest by readingEpoch, 1 newest by transferEnqueuedAt as fallback tie-breaker."

*Decision:* Keep exactly 1 — the newest by `transferEnqueuedAt` within the latest `readingEpoch`.

*Reasoning:* This is an engineering tradeoff, not a correctness claim. WatchConnectivity generally delivers `transferUserInfo` items in enqueue order within a session, but this is not a documented guarantee and cancellation/re-queuing can change the set. The argument for keeping 1 is: a second "hedge" item adds queue depth for a marginal and non-deterministic delivery benefit. If the single kept transfer fails to deliver (corrupt payload, session edge case), the next reading's transfer will be enqueued and will attempt delivery — the system self-heals within one CGM interval. The queue-depth observability benefit of keeping 1 (any `queue_depth > 2` clearly signals broken behaviour) outweighs the hedge value of keeping 2. If production telemetry shows the 1-item policy correlating with stale-complication incidents that a 2-item policy would have avoided, revisit this.

---

**R2b: Keep the (epoch, displayFields) gate rather than epoch-only**

*Suggestion (ChatGPT critique #2, partially):* Simplify the gate key to epoch alone to prevent all multi-sends per reading.

*Decision:* Gate on `(epoch, currentGlucose, trend, delta)` — same as `ComplicationSnapshotFingerprint` on the watch side.

*Reasoning:* An epoch-only gate would prevent a legitimate re-send when glucose display fields change within the same 5-minute window (e.g. a trend computation that completes 3s after the glucose value arrives). While this pattern does allow occasional 2x sends per reading, the watch-side `saveOnMain` dedup (FP-Phase 3.1) handles it if the fields haven't actually changed. The `(epoch, displayFields)` gate mirrors the existing fingerprint logic and creates a consistent dual-layer dedup. If the 2x pattern turns out to be the dominant budget drain, R2d (authoritative-source gating) is the correct fix — not collapsing to epoch-only, which would introduce a different correctness problem.

---

**R2d sequencing: gated on R2a data, not implemented speculatively**

*Suggestion (ChatGPT critique #3):* Treat the pipeline split as a near-prerequisite rather than a post-R2b option.

*Decision:* R2d ships only if avg C > 1.3 after 48h of R2b telemetry.

*Reasoning:* R2d requires knowing which sources are causing multi-C readings — that attribution data doesn't exist until R2a ships and accumulates. Implementing R2d speculatively (before R2a data) would require guessing the source allowlist, which could either under-restrict (allowlist too broad, no improvement) or over-restrict (allowlist too narrow, settings changes stop triggering complication updates at all). R2a is a low-risk instrumentation change; R2d is a behavioral change with UX consequences. The 48h observation window is the minimum viable evidence base. If R2b does hit the ≤1.3x target, R2d is unnecessary scope.

---

**R2d mode selection: "any eligible in window" vs "last source" vs "window-scoped eligible" — design history**

*v1.4 (original):* Mode = `complicationAndUI` if `coalescerSources.contains(where: { eligible.contains($0) })` — "any eligible source in window."

*Critique #3:* Too permissive — an IOB-only final wave still burns budget if a glucose event happened earlier in the same window.

*v1.5 correction:* Mode = `complicationAndUI` if `lastCoalescerSource ∈ eligible` — "last source."

*Critique #4:* Too strict — if `glucoseStored` fires then `iobUpdate` fires last in the same window, the last source is non-eligible and no complication transfer fires, even though a real glucose update arrived.

*v1.6 resolution:* Mode = `complicationAndUI` if `lastEligibleSourceAt >= coalescerFirstScheduledAt` — "any eligible source during this specific coalescer window." This is the correct predicate. `coalescerFirstScheduledAt` (already tracked) provides the window boundary. `lastEligibleSourceAt` is set in `scheduleWatchStateUpdate` when source ∈ eligible and cleared with the rest of the coalescer state. Both properties are snapshotted before clearing and passed into `sendDataToWatch`.

*Why this won't be raised again:* "Any in window" was always the intent. v1.5 introduced "last source" to solve the IOB-only misclassification, but overcorrected. The window-scoped check solves both problems by answering the correct question: "did a glucose-origin event happen during this window?"

---

**R4: activationState guard kept as-is (no pre-arming retry)**

*Suggestion (ChatGPT critique #3):* Flag that `activationState != .activated` could silently prevent R4 from arming.

*Decision:* Log `context_skipped` but do not add a retry or pre-activation queue.

*Reasoning:* If `activationState` is not `.activated` at the moment `sendDataToWatch` runs on iOS, it means WCSession is not ready — the most likely cause is the app just launched or the watch is unpaired. In these cases, `updateApplicationContext` would fail anyway. Adding a retry queue adds complexity and another failure mode. The `context_skipped activation_state=` log field gives full observability into how often this occurs. If telemetry shows `context_skipped` is common during exhaustion windows, a pre-activation retry can be added then.

---

**R5d: snapshot age guard removed; rate limiter is the only storm guard**

*Original decision (v1.7):* 600s receive gap + 300s snapshot age guard as independent thresholds.

*Reasoning at the time:* The snapshot age guard was meant to prevent noisy reloads when the first delivery after a gap is stale backlog — if snapshot hadn't advanced, no point reloading.

*Reversed in v1.12:* The guard defeats itself in the primary scenario. Callers save before calling `forceWidgetReloadIfStale()`, so `latestSnapshot().readingDate` always reflects just-saved data. After saving a fresh reading (~60s old), `snapshotAge = 60s`, the `> 300s` guard fails, and the reload is skipped — leaving the complication showing 2-hour-old data until WidgetKit's next natural refresh. The stale-backlog concern is addressed upstream by R1b's queue draining. The 5-minute rate limiter is the correct and sufficient guard against storms.

---

## Cursor Audit Round 2 — Resolved Findings

All four prompts answered 2026-03-09. No open questions remain. Plan is implementation-ready.

---

**R4b — `didReceiveApplicationContext` status: NOT implemented**

Method is absent from `Trio Watch App Extension/WatchState.swift`. The `WCSessionDelegate` conformance is on the class declaration at line 34. The five existing delegate methods are in the class body under `// MARK: - WCSessionDelegate` at line 202. Add `session(_:didReceiveApplicationContext:)` after `sessionReachabilityDidChange` (~line 403) alongside the other receive methods.

**Impact on R4:** Purely additive — no conflict with existing code.

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
This gives `timeline_entry_epoch` and `snapshot_age` at timeline-build time — confirms WidgetKit is picking up fresh App Group data. The same `event=complication_get_timeline_called` log (complication-extension / getTimeline side, not HealthKit) should include `get_timeline_at_epoch_seconds` and `data_age_seconds` per §R5f above. R5f also specifies `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` and `data_age_seconds` for the getSnapshot path — see §R5f for both entry-path specs.

---

## Changelog

### v1.52 — 2026-03-16 | Build 141 deployed (patch 09 + docs)

- **Build 141 built and deployed.** Includes patch 09 (watch-complication-improvements) with post-review R5c attribution and R5b verification corrections (R6.1, R5f, delta/trend fix, R5c follow-up cleanups).
- **Docs and patch committed to dev:** Remediation plan v1.52, implementation guide v1.37, and `patches/09-watch-complication-improvements.patch` committed together on `dev`.

### v1.51 — 2026-03-15 | R5c post-review follow-up (ChatGPT + Claude)

- **Review context:** After the v1.50 R5c attribution fix (fromUserInfo + work-item capture), two follow-up reviews (ChatGPT, then Claude) evaluated the implementation.
- **ChatGPT:** Confirmed the fix addresses the main attribution flaw (epoch from payload, timestamp threaded through the path). Requested two cleanups: (1) Remove the fallback `userInfoReceiveTimestamp ?? lastUserInfoReceiveTimestamp` so that when `fromUserInfo` is true we use only the threaded timestamp — avoids reintroducing ambiguity if a path ever reaches saveComplicationSnapshot with `fromUserInfo == true` but nil timestamp. (2) Remove the unused `lastUserInfoReadingEpoch` property and its assignment; dead attribution state can confuse future edits. Both applied.
- **Claude:** Confirmed (1) capture of `receiveTs` outside the DispatchWorkItem at creation time is correct; (2) `reading_epoch` from the payload being saved is the right fix. Noted the fallback would re-introduce a shared-state read in the unexpected-nil case; by then the fallback had already been removed per ChatGPT. Noted unconditional `lastUserInfoReceiveTimestamp = nil` when `fromUserInfo` is correct (cleans up even when no timestamp available). Confirmed R5b/R5f/R6.1 live in other files; a diff that only touches WatchState for R5c is expected.
- **§R5c "As implemented (post-review)":** Expanded to describe threading of `userInfoReceiveTimestamp`, epoch from payload, no fallback, removal of `lastUserInfoReadingEpoch`, and capture of `receiveTs` outside the work item. Added one-sentence reference to ChatGPT + Claude follow-up.

### v1.50 — 2026-03-15 | Post-review R5c attribution and R5b verification

- **Review context:** Implementation (R6.1, R5f, R5c, R5b, delta/trend fix) was reviewed; docs (remediation plan v1.49, implementation guide v1.34) were accepted. Two code corrections were required before considering the implementation ready.
- **R5c (major):** Attribution was originally implemented with a shared boolean `userInfoTriggeredThisFinalize` set/cleared by didReceiveUserInfo and didReceiveMessage. In mixed traffic, the path that last touched the flag could differ from the payload actually being finalized, producing wrong or missing `userInfo_decoded` logs. **Fix:** Attribution now rides with the work item. `scheduleUIUpdate(with:fromUserInfo:)` and `finalizePendingData(fromUserInfo:)` take a `fromUserInfo` parameter; the userInfo path (including the quiet-window work item) passes `true`, the sendMessage path passes `false`; the debounced work item captures the value and passes it through. No shared flag is used for R5c attribution.
- **R5b (near-blocker):** Reviewer requested verification that the watch-side R5b log reads `readingEpoch` from the **inner** watch-state payload (the value of `WatchMessageKeys.watchState`), not the outer sendMessage envelope. **Verified:** We only enter the R5b block after extracting `watchStateDict = message[WatchMessageKeys.watchState]`; that is the inner payload matching iPhone's `fullMessage`. A code comment was added in `WatchState.swift` documenting this for R5b end-to-end timing.
- **§R5b / §R5c:** Added "As implemented (post-review)" paragraphs summarizing the above so future implementers and reviewers see the final design.

### v1.49 — 2026-03-15 | R6.1 delta/trend correctness + source-predicate doc accuracy

- **R6.1 delta/trend fix:** Derivation now computes raw numeric delta first (`latestMgDl - previousMgDl`), then rounds once to obtain the integer used for both trend classification and display delta string. This matches the documented intent and avoids endpoint-rounding differences at threshold boundaries (display, trend bucket, dedup). No change to fallback behavior, plausibility gate, or threshold mapping.
- **Source-predicate doc accuracy:** §Source Predicate Decision now includes an "As implemented" paragraph: R6.1 shipped without the SyncIdentifier predicate; implementation uses 24h date cap when anchor is nil and nil predicate when anchor exists; SyncIdentifier/source filtering deferred to R6.2. §Delta and Trend Derivation "Numeric delta" bullet updated to specify raw-delta-first-then-round-once semantics.

### v1.48 — 2026-03-15 | R6.1 + R5f + R5c + R5b implementation complete

- **R6.1 implemented:** HealthKit fetch path replaced with `HKAnchoredObjectQuery`; anchor, last-received epoch, and previous glucose value persisted in `TrioComplicationDataStore`; derive-then-persist ordering; trend/delta from integer thresholds (raw direction strings); R6.1 log taxonomy and `fire_id`; `low_power_mode` on `hk_background_delivery_registered`. **Deviation:** SyncIdentifier presence predicate not applied (no `predicateForObjects(withMetadataKey:)` single-param API on watchOS); nil anchor uses 24h date cap only; predicate refinement deferred to R6.2.
- **R5f implemented:** `event=complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds` and `data_age_seconds`; new `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` and `data_age_seconds`; data age from snapshot actually used on each path; sentinel `-1` for invalid reading date.
- **R5c implemented:** `didReceiveUserInfo` sets receive timestamp; `saveComplicationSnapshot(from:fromUserInfo:)` logs `userInfo_decoded reading_epoch= decode_ms=` when `fromUserInfo` and timestamp set; `processRawDataForWatchState` calls with `fromUserInfo: true`.
- **R5b implemented:** iPhone `sendMessage` path logs `sendMessage_sent reading_epoch= send_wall=`; watch `didReceiveMessage` logs `didReceiveMessage reading_epoch= receive_wall=`.

### v1.47 — 2026-03-15 | R5f expanded: timeline + snapshot WidgetKit entry-path logging

- **R5f expanded from timeline-only to both WidgetKit entry paths:** R5f now specifies observability for both `getTimeline` and `getSnapshot`. The complication can render fresh data from either path; getTimeline-only logging does not reconstruct full visible recency.
- **New `event=complication_get_snapshot_called` added to spec:** Fields `get_snapshot_at_epoch_seconds` and `data_age_seconds` (same semantics as timeline path — snapshot actually used to build the entry on that path; sentinel for invalid reading date).
- **Better Stack sawtooth guidance corrected:** getTimeline-only chart is described as timeline-refresh / timeline-recency sawtooth, not full visible-recency; snapshot logging is needed to reconcile "face shows NOW without logged getTimeline"; both events support visible-recency analysis in Explore. Scope boundary and chart naming/interpretation note added.

### v1.46 — 2026-03-15 | getTimeline visible-recency logging (R6.1 enhancement)

- **`event=complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds`:** Unix epoch when getTimeline was invoked/logged; supports reconstructing recency between calls.
- **`event=complication_get_timeline_called` now includes `data_age_seconds`:** Age of the snapshot actually used to build the timeline (complication-extension / getTimeline fields only, not HealthKit observer). Enables visible recency at getTimeline time and sawtooth reconstruction in Better Stack Explore.
- **§R5f expanded:** Visible recency fields, rationale (directly queryable, avoids save/reload inference, reflects user-visible recency), scope (observability only; no behavior change), and limitation (Explore today; dashboards may not support as-of natively) added. R5f-getTimeline impact updated to reference the new fields.

### v1.45 — 2026-03-15 | 3-pass adversarial review — correctness fixes, stale sequencing, orphaned fields

**Summary:** Three-pass structured review correcting factual errors that were documented in deviation notes or code review tables but never backported to the normative sections of the plan, plus clearing stale sequencing language left over before build 140 changed the actual ship order.

**Correctness fixes in normative code (blocked an implementer or would trigger a repeated compile/deploy failure):**

- **R6c code — `SortDescriptor` compile error:** The code block used `SortDescriptor(\.startDate, order: .reverse)` as the primary form. `HKSampleQuery` requires `[NSSortDescriptor]?`; Swift `SortDescriptor` does not bridge to it and will not compile. Replaced with `NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)` with explanatory comment. (This was the actual cause of the build 140 compile issue, fixed in deviation — but normative code was never corrected.)
- **R6c code — `.milligramsPerDeciliter()` unavailable on watchOS:** Both `HKSampleQuery` result extraction calls used this LoopKit extension. Replaced with `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))` inline in both places (latest and previous sample). Comment added. The architecture table ("What's Available in HealthKit") Notes column was also corrected.
- **R6b code — `guard let self` missing (CR2):** The normative `setupGlucoseObserverQuery` code used `self?.fetchLatestGlucoseFromHealthKit(completionHandler:)`. If `self` is nil, `completionHandler()` is never called — the system throttles future background delivery. CR2 (required fix) documented this, and the CR table in the implementation guide showed it as "Fixed." But the normative plan code was never updated. Replaced with explicit `guard let self else { completionHandler(); return }` pattern with explanatory comment.

**Correctness fixes in normative text:**

- **`NSHealthUpdateUsageDescription` (§R6 Entitlement requirements, Risks table):** Both locations stated this key "is not required" because `toShare: nil`. Build 140 confirmed Apple's altool rejects uploads when the HealthKit entitlement is present but this key is absent, regardless of `toShare: nil` (ITMS-90683). Corrected in §Entitlement section and Risks table to "required by App Store Connect validation." Historical "Fixed in v1.34/v1.35" markers updated to reflect confirmed behavior.
- **R6a placement (§Watch Side Implementation):** Stated "Place in `WatchState.init()` or `setupSession()` (where `WCSession.activate()` already runs)." This description implies placement inside the `if WCSession.isSupported()` block — which CR1 explicitly required it to be **outside**. Corrected: "Place at the **end of `setupSession()`**, **outside** the `if WCSession.isSupported()` block" with rationale.
- **R4 watch-side handler — R5d dependency (§R4 watch app extension side):** Simplified handler shown without note that the full handler (with `lastDataReceivedAt` and `forceWidgetReloadIfStale`) requires R5d. Added labelled "standalone R4 handler" clarification and cross-reference to §R5d for the R5d-integrated version.

**Orphaned field fix (§R6.1 Updated Log Taxonomy):**

- **`hk_background_delivery_registered` `low_power_mode=Bool`:** R6.1 taxonomy changed this field from `success=Bool` to `low_power_mode=Bool` with no implementation path, no source API, and no explanation of why `success` was dropped. An implementer had no way to know what `low_power_mode` was or how to produce it. Resolved: both `success=Bool` and `low_power_mode=Bool` now specified; `low_power_mode` source documented as `ProcessInfo.processInfo.isLowPowerModeEnabled`; logging behavior for `success=false` case documented (⚠️ prefix).

**Stale sequencing and status language:**

- **§R6 "Recommended sequencing" paragraph:** Was written as live present-tense advice ("Go straight to R6…Ship R6 first") for a decision already made. Recast as historical rationale paragraph reflecting the actual outcome (R6 shipped build 140 before R4).
- **§R6 Decision Gate:** "Ship R6 after R4" was the original recommendation; actual order was reversed. Rewritten to document actual ship order and direct readers to §Implementation Sequence for current status.
- **§Implementation Sequence diagram:** Fully updated to reflect current state — R1–R6 all annotated with build numbers and ✅ status; R4, R5b/c/d, and R6.1 annotated as PENDING with rationale for ordering.
- **§R4 header:** "can ship after R6 or bundle with R6 in same PR" — R6 has shipped. Replaced with current status: "PENDING — ship R4 as next PR after R6 48h observation window concludes."
- **§R6 Risks table — trend derivation row:** "add delta-based trend derivation in R6.1 if user feedback requests it" (×2). Replaced with "see R6.1 (spec complete — see §R6.1)" since R6.1 is now planned independently of user feedback.
- **§R6 Trend derivation options — option 3:** Same "if user feedback requests it" language corrected to "spec complete — see §R6.1, ready for implementation."

### v1.44 — 2026-03-15 | R6.1 delta/trend derivation clarity — numeric vs display, threshold input, fallback, scope boundary

- **Section renamed:** "Trend Derivation" → "Delta and Trend Derivation" to reflect that the section covers both delta and trend.
- **Numeric vs display delta clarified:** "Delta computation" renamed to "Numeric delta" with explicit statement that the single integer mg/dL delta serves both trend classification and display-string formatting. New "Display delta formatting" bullet specifies how `TrioComplicationSnapshot.delta` is produced from the same numeric delta.
- **Shared previous-sample constraint:** Input bullet now explicitly requires that delta and trend use the same selected previous sample on a given fire.
- **Threshold input clarified:** Threshold mapping bullet now explicitly states the integer delta is applied directly — no separate floating-point threshold system in R6.1.
- **Fallback expanded:** Fallback bullet now covers both trend and delta (not just trend). Explicitly states both fall back when the plausibility gate fails, regardless of batch vs persisted previous-sample source.
- **Derivation scope boundary added:** New paragraph after the inherited unit note explicitly documenting that R6.1 only derives `delta` and `trend`; `glucoseColor`, `state`, mmol/L parity, and `sync_lag` in display/dedup/trend are intentionally out of scope.

### v1.43 — 2026-03-15 | R6.1 taxonomy fix — `fire_id` on `hk_observer_error`

- **`hk_observer_error` now includes `fire_id`:** Added `fire_id=UUID` to the R6.1 `hk_observer_error` event fields for consistency with all other observer-callback events. Per the spec, `fire_id` is generated at the start of each observer callback before error checking, so it is available on this path.

### v1.42 — 2026-03-15 | R6.1 final polish — backfill validation, Anchor Lifecycle clarity

- **Backfill validation tightened:** Anchored-query correctness pass condition now explicitly requires verifying that the saved snapshot uses the sample with the greatest `startDate` in backfill batches, not just that a single save occurred.
- **Anchor Lifecycle "Normal operation" row tightened:** Replaced vague "saved after processing" wording with a cross-reference to the detailed anchor advancement, epoch/value persistence, and snapshot save rules in subsequent rows.

### v1.41 — 2026-03-15 | Better Stack avg C metrics — complication_c_total_transfers (sum only), chart formula

- **Avg C metrics section completed:** Documented that `complication_c_total_transfers` uses **sum** aggregation only. Dashboard chart formula added: `sumMerge(complication_c_total_transfers_sum) * 1.0 / nullIf(uniqMerge(complication_c_readings_uniq), 0)` per bucket. Extraction rule label clarified to "aggregation: **sum**".

### v1.39 — 2026-03-15 | R6.1 spec polish — derive-then-persist ordering, startDate qualifiers, source-predicate validation

- **Trend Derivation `startDate` qualifier added:** Input line now explicitly says "Latest sample by `startDate`" and "second-most-recent by `startDate` in batch," matching the Design section's sort requirement. Prevents ambiguity for readers entering the Trend Derivation section directly.
- **Derive-then-persist ordering clarified:** TrioComplicationDataStore Additions section now explicitly states that delta/trend must be derived from the persisted previous epoch/value *before* the current sample's epoch/value are persisted. Prevents an implementer from accidentally overwriting the previous-sample state before derivation.
- **Source-predicate over-inclusion validation note added:** Validation Approach section now includes guidance that anomalous delta/trend values in multi-app setups should be considered as possible source-predicate over-inclusion symptoms before treating them as implementation bugs. Known R6.1 tradeoff; value-specific refinement deferred to R6.2.

### v1.38 — 2026-03-14 | R6.1 spec tightening — anchor advancement, field rename, sample ordering, trend observability

- **Anchor advancement on non-save exits clarified:** Anchor Lifecycle table restructured — "Successful anchor advancement" renamed to "Anchor advancement rule" covering all successful-query paths. Anchor is always saved after a non-error query (including no-new-samples and epoch-guard-skip exits), but epoch/value are only updated when a genuinely new sample is processed. Query errors and pre-query guard failures do not advance the anchor. Design section "Persist query anchor" bullet updated to match.
- **`save_age` → `sync_lag` field rename documented:** R6 uses `save_age` on `hk_observer_fired`; R6.1 renames to `sync_lag`. Added explicit note in Updated Log Taxonomy section with BetterStack query guidance for cross-build queries.
- **Anchored-query sample ordering requirement specified:** Design section now states that latest/previous sample must be determined by sorting `addedObjects` by `startDate`, not by relying on raw array order. Store-insertion order is not guaranteed chronological during backfill, sync catch-up, or retroactive delivery.
- **`trend=String` field added to `hk_observer_fired` log taxonomy:** R6.1 logs the actual derived direction string alongside `trend_derived=Bool`, enabling validation of threshold mapping correctness and WC/HK format alignment in BetterStack.
- **Latency-domain wording tightened:** `sync_lag` description now notes it includes watch-side observer/query processing time, not just transit. Post-log processing estimation reworded to acknowledge watch-side logs cannot fully decompose latency into separate buckets.
- **Validation approach wording softened:** Phantom fire rate and trend coverage pass conditions changed from specific percentage thresholds to directional expectations. Trend coverage now includes `trend` value validation.

### v1.37 — 2026-03-14 | R6.1 spec review fixes — previous-sample persistence, trend format, epoch ordering

- **Previous-sample persistence added:** `hkLastReceivedGlucoseValueMgDl()` and `setHKLastReceivedGlucoseValueMgDl(_:)` added to `TrioComplicationDataStore` planned methods (now 6 total). Design section updated to explain how persisted previous glucose value/epoch enables delta/trend derivation for the common steady-state single-sample anchored-query case.
- **Trend output format specified:** R6.1 must produce raw direction strings (`"Flat"`, `"SingleUp"`, etc.) matching the WC path format, not symbol glyphs. Aligns with existing `TrendSymbolMapper.symbol(from:)` and enables `shouldUpdate` dedup to correctly identify same-reading dual delivery.
- **Trend derivation changed from mg/dL/min rate to raw-delta threshold mapping:** Now uses the same `Int` delta thresholds as `BloodGlucose.Direction.init(trend:)` (<=−30 DoubleDown through >=30 DoubleUp). Threshold table added to spec. Note added that the switch statement may need duplication or extraction for the watchOS target.
- **Epoch-guard ordering corrected:** Changed from "checked before executing the anchored query" to "post-query filter applied to returned results." Clarified that this is an edge-case filter for modified/re-delivered samples, not the primary incremental mechanism.
- **Anchor serialization specified:** `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:)` / `NSKeyedUnarchiver.unarchivedObject(ofClass:from:)` — `HKQueryAnchor` is `NSSecureCoding`, not `Codable`. References LoopKit `PersistenceController` pattern.
- **Deletion handling added:** Anchor Lifecycle table now explicitly states deleted objects from `HKAnchoredObjectQuery` are ignored; modified/re-delivered samples caught by epoch guard.
- **Source-predicate risk language tightened:** `HKMetadataKeySyncIdentifier` described as a standard Apple key used by multiple diabetes apps, not a Trio-specific key. Over-inclusion risk upgraded to practical, not theoretical. Severity raised to Low–Medium.
- **Dual-delivery dedup benefit noted:** WC healthy + HK healthy scenario updated to explain that matching raw direction strings can prevent the R6 trend-overwrite regression via `shouldUpdate` returning `false`.
- **`fire_id` lifecycle clarified:** Generated once per observer callback; threaded through all subordinate functions; not regenerated per helper or save.
- **Inherited unit-consistency note added:** HK delta is mg/dL-only; WC may format as mmol/L; affects dedup for mmol/L users. Deferred unless separately scoped.

### v1.36 — 2026-03-14 | R6.1 HealthKit channel improvements spec added

- **R6.1 section added:** New `## R6.1 — HealthKit Channel Improvements` section with full planning/specification material for the follow-on HealthKit channel refinement. R6 remains shipped in build 140; R6.1 is spec complete and ready for implementation.
- **Anchored-query design specified:** Planned replacement of R6's `HKSampleQuery` fetch path with `HKAnchoredObjectQuery` — incremental fetch, persisted anchor, persisted last-received epoch, fast exit on known-epoch fires.
- **Anchor/epoch persistence location specified:** Four new methods planned for `TrioComplicationDataStore` (`hkGlucoseAnchor`, `saveHKGlucoseAnchor`, `hkLastReceivedGlucoseEpoch`, `setHKLastReceivedGlucoseEpoch`). Raw `UserDefaults(suiteName:)` in `WatchState` explicitly forbidden for this feature.
- **Source predicate decision recorded:** `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)` selected; rationale and residual risk documented.
- **Trend derivation specified:** Latest + previous sample, mg/dL/min rate, 15-minute gate, blank fallback when gate fails.
- **Log taxonomy expanded:** 11 R6.1 events specified with fields; 2 R6-only events identified for replacement; `query_type=anchoredQuery` as the R6/R6.1 discriminator.
- **Latency domains callout added:** Three-domain breakdown (iPhone write, cross-device sync, app processing) with explicit note that `sync_lag` does not isolate Apple sync latency.
- **R6.1 risks table added:** Anchor decode failure, source predicate over-inclusion, trend false confidence, log complexity.
- **Validation approach added:** Phantom fire rate, trend coverage, anchored-query correctness, known-epoch skip, no duplicate save explosion.
- **WC failure mode scenarios added:** Four scenarios showing R6.1 behavior when WC is healthy, degraded, or absent.
- **Backlog table updated:** R6.1 row added (planned — spec complete, ready for implementation).

### v1.35 — 2026-03-14 | R6 shipped (build 140) + NSHealthUpdateUsageDescription remediation

- **R6 shipped and live:** Build 140 deployed to TestFlight. `hk_background_delivery_registered success=true` confirmed at 15:45:19 UTC; `hk_observer_fired` events confirmed (glucose=110/111, delta computed correctly). HealthKit background delivery is operational on the watch.
- **Unplanned remediation — `NSHealthUpdateUsageDescription`:** Apple App Store Connect validation (altool) rejected the build 139 upload with error ITMS-90683: "Missing purpose string in Info.plist" for `NSHealthUpdateUsageDescription`. Despite `toShare: nil` (no write access requested), Apple requires both `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` whenever the `com.apple.developer.healthkit` entitlement is present. This is a blanket validation requirement, not tied to actual API usage. **Fix:** Added `NSHealthUpdateUsageDescription` to `Trio Watch App/Info.plist`: "Trio may save blood glucose readings to Apple Health to keep your health data synchronized." The v1.34 statement that `NSHealthUpdateUsageDescription` is "not needed" was correct at the code level but incorrect for App Store submission.
- **Unplanned remediation — `HKUnit.milligramsPerDeciliter` unavailable on watchOS:** Build failed with `type 'HKUnit' has no member 'milligramsPerDeciliter'`. This is a custom extension in `LoopKit/MockKitUI` which is linked to the iOS app but not the watchOS target. **Fix:** Replaced with inline construction: `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`.
- **Status line:** Updated to reflect R6 shipped.
- **Backlog table:** HealthKit row updated to ✅ Shipped.

### v1.34 — 2026-03-14 | R6 blocker fix: NSHealthShareUsageDescription for watch app

- **Blocker found (Cursor code review, confirmed by ChatGPT + Claude):** `Trio Watch App/Info.plist` was missing `NSHealthShareUsageDescription`. The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires the read usage description in the requesting process's Info.plist. Without it, authorization may crash the watch app on launch or fail silently. Since `setupHealthKitBackgroundDelivery()` runs from `init()` → `setupSession()` on every launch, this was a high-risk failure mode for the entire watch app.
- **Fix:** Added `NSHealthShareUsageDescription` to `Trio Watch App/Info.plist` with user-facing string: "Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable." The "when wireless sync is unavailable" clause explains why the watch needs HealthKit specifically (backup channel, not primary).
- **Not needed (at code level):** `NSHealthUpdateUsageDescription` — `toShare: nil` means no write access is requested. However, Apple App Store Connect validation requires `NSHealthUpdateUsageDescription` in Info.plist whenever the HealthKit entitlement is present, regardless of whether the app actually writes. See v1.35.
- **Entitlement and Info.plist Requirements section:** Renamed from "Entitlement Requirements"; added privacy usage description subsection with rationale, XML block, and explicit note that `NSHealthUpdateUsageDescription` is not needed.
- **Risks table:** Added `NSHealthShareUsageDescription` missing row (Blocker, fixed in v1.34).

### v1.32 — 2026-03-14 | Step 7 implementation — code review (ChatGPT round 1 + 2)

- **CR1:** HK setup must not be inside `if WCSession.isSupported()` — R6 is an independent wake path. Call `setupHealthKitBackgroundDelivery()` outside that block. Implemented in WatchState.
- **CR2:** In `HKObserverQuery` update handler, if `self` is nil, `completionHandler()` was never called. Add `guard let self else { completionHandler(); return }`. Implemented.
- **CR3/CR4:** Log sample query errors and zero samples; log `success=false` for background delivery distinctly. Implemented.
- **CR5 (ChatGPT round 2):** completionHandler() was called via defer when the HKSampleQuery closure exited, but the save runs in DispatchQueue.main.async — system was told "done" before save ran. Call completionHandler() inside the main.async block after save. R6d section updated; implementation guide v1.18 CR5 + prompt updated.
- **Sanity checks (ChatGPT round 3):** (1) TrioComplicationDataStore.save() uses onMain(); when caller is already on main, onMain runs the block synchronously — no extra async hop; completionHandler() after save is correct. (2) WatchState is singleton (static let shared); no duplicate HK setup. See implementation guide Step 7 sanity-checks table.

### v1.33 — 2026-03-14 | Step 7 sanity checks (ChatGPT round 3) — doc

- Version bump; sanity-check verification (save synchronous on main, WatchState singleton) already noted in v1.32 changelog. Implementation guide v1.19 adds Step 7 sanity-checks table.

### v1.31 — 2026-03-14 | R6 pre-implementation fixes (entitlements, weak self, SortDescriptor)

- **Entitlement Requirements:** HealthKit already enabled on watch extension App ID in Apple Developer portal. Table updated: both keys now ✅ "Already present in provisioning profile"; note changed to "Entitlements file addition only required — no provisioning profile update needed." Removed "must update provisioning profile" language.
- **Risks table:** HealthKit row updated to state provisioning profile already has HealthKit; only entitlements file must be added.
- **R6a code block:** Added `[weak self]` and `guard let self else { return }` in `requestAuthorization` callback to avoid strong capture in async callback.
- **R6c code block:** Replaced deprecated `NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)` with `SortDescriptor(\.startDate, order: .reverse)` in `HKSampleQuery`; removed `sort` variable.

### v1.30 — 2026-03-14 | Step 5/R4 and Step 7/R6 mapping + sequencing

- **Step ↔ Plan mapping:** Added to Naming Convention: Step 5 = R4 (applicationContext safety net), Step 7 = R6 (HealthKit background delivery).
- **R4 (Step 5):** Heading now includes "(Step 5)". Recommended line updated: can ship after R6 or bundle with R6 in same PR; noted complementary files (AppleWatchManager vs WatchState).
- **R6 (Step 7):** Heading now includes "(Step 7)". Replaced "Prerequisite: R4 must be shipped first" with **Recommended sequencing: go straight to R6.** Rationale: R4 would have done nothing for the 24-minute gap (data already in App Group, WidgetKit not calling getTimeline; R4 still ends with reloadTimelines WidgetKit can ignore). R6 gives independent system-triggered wake when new glucose arrives; e.g. during 9-min gap, R6 would have fired from 05:37 reading. R4 still valuable for budget exhaustion but lower urgency. Ship R6 first; R4 after R6 or bundle both.

### v1.29 — 2026-03-14 | R6 dedup accuracy + stale conditional language

- **Dedup and Dual-Delivery Behavior:** Rewrote section for accuracy against actual code. The prior version claimed "the second delivery is rejected as a duplicate" which was incorrect — `shouldUpdate` compares `trend` and the HK snapshot's `trend=""` differs from WC's real trend, so `shouldUpdate` returns `true` and both writes are accepted. New section documents: (a) the HK snapshot overwrites WC's trend arrow in normal dual-delivery operation, (b) this is transient and acceptable (glucose+delta correct, trend restored on next WC delivery), (c) the overwrite's `coalescedReloadOnMain` call fires because 10–60s HealthKit sync latency exceeds the 5s debounce, (d) in target scenarios (exhaustion, WidgetKit gaps) there is no overwrite because WC is not delivering.
- **Risks table:** Added "Trend arrow overwrite in normal operation" (Low severity).
- **Backlog table row:** Updated from "gated on R4 post-deploy data" to "ship after R4; see §R6" — consistent with v1.27 decision gate broadening.
- **Implementation sequence arrow:** Changed from "if p90 complication_age > 300s in exhaustion windows after 48h" to "observe 48h, then ship R6" — consistent with v1.27 decision gate broadening.

---

### v1.28 — 2026-03-14 | R6 nit fixes (naming, entitlement)

- **Naming convention:** Fixed `R1`–`R5` → `R1`–`R6` in the naming convention line and annotated the initial-draft changelog entries. The naming convention table was already updated in v1.26 but the prose reference was missed.
- **`healthkit.access` entitlement:** Not referenced in the remediation plan (only in the implementation guide). Noted here for cross-reference: the guide's XML block and Cursor prompt incorrectly included `com.apple.developer.healthkit.access` (empty array). This entitlement is for sensitive HealthKit capability types and is not needed for reading `.bloodGlucose`. Removed in guide v1.14.

---

### v1.27 — 2026-03-14 | R6 decision gate broadened

- **R6 decision gate:** Broadened from "ship only if budget-exhaustion staleness persists" to "ship after R4 — addresses two distinct failure modes." Added WidgetKit scheduling gap as co-equal motivation (observed in build 139: 9-min gap with fresh App Group data, `reload_age=548s`). The `HKObserverQuery` wake trigger fires when new glucose data arrives in HealthKit, providing an independent opportunity to call `reloadTimelines` outside of WidgetKit's own scheduling.
- **Prerequisite:** Updated to describe both failure modes explicitly (budget exhaustion + WidgetKit scheduling gaps). Removed "motivated only if" conditional language.
- **Validation:** Pass conditions split into two categories (budget exhaustion: `save_age` p90 < 300s in exhaustion windows; WidgetKit gaps: `reload_age` p90 < 300s overall). Validation Protocol table row updated.

---

### v1.26 — 2026-03-14 | R6 HealthKit Background Delivery

- **R6 section added:** New remediation phase — HealthKit background delivery as an independent complication update channel on watchOS, completely outside WatchConnectivity.
- **Codebase audit results embedded:** iPhone-side HealthKit writes confirmed in `HealthKitManager.swift` line 205 (`.bloodGlucose`, `.milligramsPerDeciliter`, no trend/delta metadata). Watch extension and complication confirmed to have zero HealthKit references. Entitlements audit: watch extension missing both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` (blocker). Main app has both.
- **Architecture:** `HKObserverQuery` + `enableBackgroundDelivery` on watch → sample fetch → `TrioComplicationSnapshot` construction → existing `TrioComplicationDataStore.shared.save()` path. Delta derived from last 2 samples; trend set to `""` initially (derivation deferred to R6.1).
- **Dedup:** `saveOnMain` (FP-Phase 3.1) handles dual-channel dedup automatically — no new dedup logic needed.
- **Naming convention:** Updated R-namespace to R1–R6. Implementation Sequence, Validation Protocol, and Backlog tables updated.

---

### v1.25 — 2026-03-13 | Logging fixes context for Step 4 gate

- **Status:** Updated to reflect builds 137-138 deployment with cloud logging pipeline fixes. Step 3b is now deployed and observable with accurate build attribution.
- **Step 3b section:** Added "Logging pipeline fixes" paragraph documenting the build-mislabeling fix and its impact on avg C measurement reliability. The 48h observation window for the Step 4 decision gate effectively starts from build 137 deployment (2026-03-12), since prior data had inaccurate build attribution.
- **Step 4 gating criteria:** avg C query must filter to build >= 137 with `dt` after build 137 deploy time. The `[b:BUILD]` token embedded in log lines by builds 137+ ensures accurate per-build attribution.
- **Cross-reference:** Logging fixes design doc, implementation plan, and cursor plan at `docs/completed/logging-fixes/`.

---

### v1.24 — 2026-03-12 | Step 3b completion

- **Status:** Step 3b (complication-age stale-first budget gate) marked implemented; code review complete. Status line updated: Step 3b code complete; observe 48h before Step 4.
- **Step 3b section:** Added "Implementation status" paragraph documenting code verification (helper pattern, constant, branching, lastDispatchedGateKey rule, log taxonomy) and next step (observe 48h).

---

### v1.23 — 2026-03-11 | Nit-only consistency pass

- Version bump only; no behavioral changes. Aligns with implementation guide v1.8 and Cursor plan reference. Validation Protocol Step 3b row: added skip_reason=age_gate (and duplicate_gate, missing readingEpoch) for queryability. Newline at EOF.

---

### v1.22 — 2026-03-11 | Nit consistency cleanup (Step 3b)

- **Helper:** Step 3b helper guidance made identical in remediation plan and implementation guide: exact 4-step pattern (guard suite/defaults → return .infinity; let lastValid; if lastValid == nil return .infinity; else return max(0, …)).
- **lastDispatchedGateKey rule:** Stated explicitly in all three docs: only set when complication transfer actually enqueued (transferCurrentComplicationUserInfo or transferUserInfo); not on sendMessage-only; not when age gate fails; do not reintroduce Step 3 foreground→background suppression bug.
- **Skip-log taxonomy:** Three queryable categories documented consistently: skip_reason=age_gate (Step 3b), skip_reason=duplicate_gate (R2b), missing readingEpoch.
- **Validation/STOP:** Step 3b STOP block (guide) now explicitly states age gate applies ONLY to transferCurrentComplicationUserInfo, NOT sendMessage and NOT userInfo fallback. Remediation validation table Gate behavior row aligned.

---

### v1.21 — 2026-03-11 | Step 3b — Complication-age stale-first budget gate

- **New step:** Step 3b (Complication-age stale-first budget gate) added to the implementation sequence, after Step 3 (R2b) and before Step 4 (R2d).
- **Behavior:** Gate use of `transferCurrentComplicationUserInfo` on current complication age &gt; T (600s initial). Complication age is computed on iOS by reading App Group key `TrioComplication_lastValidTimestamp` (written by watch-side store). If missing, treat age as very large so first transfer is allowed. `sendMessage` and budget-exhausted `transferUserInfo` fallback are not gated.
- **Rationale:** Preserve 50/day budget for moments when the complication is actually stale; avoid burning budget when complication is already fresh (e.g. from sendMessage or prior transfer).
- **Data-driven threshold:** T = 10 minutes from BetterStack 48h analysis: reload_age proxy p90 ≈ 10.3m; &gt;10m ≈ 79/day, &gt;12m ≈ 40/day, &gt;15m ≈ 14/day. Validation targets and falsifiers documented; Implementation Sequence updated to insert Step 3b.
- **Sketch and status (same release):** Code sketch corrected to explicit branching — age gate applies only when `remainingComplicationUserInfoTransfers > 0`; when budget is exhausted, userInfo fallback runs regardless of age (duplicate gate only). Skip log includes `skip_reason=age_gate` for BetterStack. Status line updated: Step 3 (R2b) deployed as build 134; observing 48h; Step 3b added (not implemented yet).

---

### v1.20 — 2026-03-11 | Step 3 implementation + code review feedback (R2b)

- **Status:** Updated to Step 3 in progress.
- **Implementation log:** Added Build 134 section documenting R2b dispatch gate implementation.
- **Code review Round 1 (Claude):** 6 points evaluated; 1 fix (activation-clear for budget-cycle concern).
- **Code review Round 2 (ChatGPT):** Critical bug found — gate key was advanced on sendMessage-only paths, suppressing complication transfers on foreground→background transition. Fix: moved gate key write inside complication transfer block.

---

### v1.19 — 2026-03-10 | Step 2 deployment (build 133)

- **Status updated:** Step 2 (R2a + R3) deployed as build 133; observing 24h before Step 3.
- **Implementation Log:** Added Build 133 entry documenting R2a coalescer attribution and R3 complication payload allowlist deployment, with BetterStack verification results.

---

### v1.18 — 2026-03-09 | Step 1 deployment (build 132)

- **Status updated:** Step 1 (R1a + R1b + R5e) deployed as build 132; observing 24h before Step 2.
- **Implementation Log section added:** Build 132 entry documenting R1a reading epoch keys, R1b stale queue drain, and R5e BetterStack alert deployment, with BetterStack verification results.

---

### v1.3 — 2026-03-09 | ChatGPT critique #2 of Remediation Plan

**Critical bug fix:**
- **R5d:** `CLKComplicationServer.reloadTimelines` replaced with `WidgetCenter.shared.reloadTimelines(ofKind:)`. The complication is a WidgetKit widget — `CLKComplicationServer` is legacy ClockKit and would silently do nothing. Would have created false confidence in the sleep-gap safety net.

**Architectural fixes:**
- **R5d:** Sleep-gap check added to `didReceiveApplicationContext` path in addition to `didReceiveUserInfo`. During budget exhaustion, `didReceiveUserInfo` may not fire at all — the check must also run on the applicationContext delivery path or it's useless precisely when it's most needed.
- **R4:** `updateApplicationContext` made conditional on `remainingComplicationUserInfoTransfers == 0 || queue_depth > 5`. Previously always-on, which would have added serialization overhead on every send before R2 tames the send rate.

**Logic corrections:**
- **R1b:** Startup/session-activation drain added. Previously only cancelled on budget-exhausted branch — the queue was already frozen at 46–48 items before exhaustion, so this would never have run. Also switched staleness heuristic from enqueue wall time to `readingEpoch` comparison — semantically correct (stale by glucose time, not transport time).
- **R2b:** `lastDispatchedGateKey` persisted to App Group `UserDefaults`. Previously in-memory only — iOS app restart or watch manager reinitialization would reset the gate and allow a re-burst of redundant transfers.

**Prioritization changes:**
- **R2c** deprioritized. Pipeline split (added to backlog) would supersede it; and the UX regression risk (shared coalescer drives both complication and watch UI) isn't worth taking before R2a attribution data is available.
- **Pipeline split** (complication channel vs UI channel) added as high-priority backlog item. Gated on R2a attribution data. The most reliable structural path from 2.85x → ~1.0x per reading. Would supersede R2c entirely.

**Open questions added:**
- Prompt R5d-kind: need `kind` string from WidgetKit `Widget` struct for `WidgetCenter.shared.reloadTimelines(ofKind:)`.

---

### v1.2 — 2026-03-09 | Cursor codebase audit Round 1 (key inventory + key names)

- **R3:** Added `WatchMessageKeys.units` to complication strip list — confirmed present in `watchStateToDictionary`, not needed by complication.
- **R3:** Confirmed `WatchMessageKeys.glucoseValues` constant name and string value `"glucoseValues"` — no rename needed.
- Remaining open question: Prompt R4b — `didReceiveApplicationContext` existence on watch side still needs Cursor confirmation.

---

### v1.1 — 2026-03-09 | Cursor codebase audit Round 1 (architecture findings)

**Critical architecture correction:**
- **R4:** `WCSession` / `receivedApplicationContext` unavailable in WidgetKit complication process. R4 redesigned: iOS sends `updateApplicationContext`, watch app extension receives via `didReceiveApplicationContext` and writes to App Group store, complication reads App Group store unchanged.

**Scope corrections:**
- **R3:** Narrowed — `glucoseValues` only used in complication path to call `latestGlucoseDate()`. Adding top-level `readingEpoch` key (R1a) eliminates the need for the array on the complication transfer path entirely.
- **R1a:** Top-level `"date"` key in `watchStateToDictionary` is build time (`Date()` at state construction), not CGM reading time. New `WatchMessageKeys.readingEpoch` constant required for the actual reading timestamp.

**Field names confirmed:**
- **R2b:** `currentGlucose: String?`, `trend: String?`, `delta: String?` — all pre-formatted optional strings on iOS `WatchState` model. Gate hash can use these directly.
- **R5d:** `lastUserInfoReceivedAt: Date?` confirmed at line ~102, but in-memory only — needs App Group persistence for cross-restart sleep gap detection.

**Safe-to-change confirmations:**
- `scheduleWatchStateUpdate` is `private` on `final class BaseWatchManager` — signature change has no subclass or protocol impact.
- Coalescer debounce is hardcoded inline literals on line ~529 (`min(2.0, 5.0 - elapsed)`) — not named constants, but trivially parameterized.

**Budget clarification:**
- `via=sendMessage` does NOT consume `remainingComplicationUserInfoTransfers`. Only `transferCurrentComplicationUserInfo` calls drain the budget. Prior report was wrong on this point.

---

### v1.0 — 2026-03-09 | Initial version

First draft of the Freshness Remediation Plan (R1–R5; R6 added in v1.26), synthesized from:
- BetterStack telemetry analysis (build 131, 2026-03-08/09)
- ChatGPT critique #1 of the Next-Steps Report
- Prior implementation plan `complication-freshness-implementation-plan.md` v1.27 (FP-Phase 0–3)

Established root-cause hierarchy (redundant triggers → budget burn → frozen queue → stale complication), defined R1–R5 phases (R6 added in v1.26), and set the implementation sequence.

---

### v1.4 — 2026-03-09 | ChatGPT critique #3 of Remediation Plan v1.3

**Logic fix — R1b same-epoch duplicate handling:**
R1b's `epoch < latestEpoch` predicate correctly cancelled older-epoch items but did nothing when all queued transfers shared the same latest epoch (e.g. 2–3 per reading with identical epoch). The frozen 46–48 item queue was entirely this pattern. Rewrote cancellation policy to group by epoch, pick the single newest transfer within the latest epoch by `transferEnqueuedAt`, and cancel everything else including same-epoch duplicates. This will actually deflate the queue to depth 1 regardless of how many same-epoch duplicates are present.

**Maintainability fix — R3 allowlist build replaces strip list:**
"Copy fullMessage then remove keys" was a maintainability trap: adding any new field to `watchStateToDictionary` would silently bloat the complication payload with no compile-time signal. Replaced with an explicit allowlist build — `complicationMessage` is now constructed directly from only the 6 fields the complication needs. Payload regression is now structurally impossible unless someone deliberately adds to the allowlist.

**Correctness fix — R5d reload gated on snapshot age, not just receive gap:** ~~Previously `forceWidgetReload()` fired whenever receive gap > 600s regardless of whether the incoming snapshot was fresh. The reload helper now checks `TrioComplicationDataStore.shared.latestSnapshot().readingDate` — reload only fires if snapshot age > 300s.~~ ⚠️ **Reversed in v1.12** — this guard defeats itself because callers save before calling `forceWidgetReloadIfStale()`, so the just-saved fresh snapshot always reads as fresh and the guard always blocks. See v1.12 changelog.

**Structural fix — R2d promoted from backlog to formal phase:**
"Pipeline split" was in the backlog. Given that R2b's `(epoch, displayFields)` gate provably allows early-nil then late-computed double sends per reading, and the stated goal is avg C ≤ 1.3, R2d is now a formal phase with a clear decision gate: if avg C > 1.3 after 48h of R2b data, implement R2d (authoritative-source allowlist for complication transfers) rather than R2c. R2c remains in the plan as a fallback but is subordinate to R2d.

**Bug fix — R4 `guard ... else { break }` footgun:**
`break` in a guard in function scope won't compile; in a `switch` it silently exits the wrong construct. Replaced with `return`. Added `context_attempted` / `context_succeeded` split log fields to allow BetterStack monitoring of whether the R4 safety net is actually arming and delivering during exhaustion windows.

**Sequence updated:**
R2b now ships and observes for 48h before deciding R2c vs R2d. Decision gate is explicit: avg C ≤ 1.3 → optional R2c; avg C > 1.3 → R2d (pipeline split). Pipeline split removed from backlog table.

**Process addition:**
Added "Decisions & Rejected Alternatives" section. Documents 5 deliberate deviations from reviewer suggestions with reasoning, so reviewers don't re-raise the same points in future critiques.

---

### v1.5 — 2026-03-09 | ChatGPT critique #4 of Remediation Plan v1.4

**Production safety fix — R3 property list compliance:**
Replaced `Optional-as-Any` / `compactMapValues` pattern with explicit `if-let` inserts. `fullMessage[key] as Any` when the key is absent produces `Optional<Any>.none`, which is not property-list-safe for WatchConnectivity and can cause `transferCurrentComplicationUserInfo` to silently fail serialization. Explicit inserts guarantee only real plist-safe values enter the payload. Added `readingEpoch` as a load-bearing guard — if absent, the entire send aborts with a log warning rather than sending an unusable payload.

**Correctness fix — R2d mode selection uses last source, not any source:**
`coalescerSources.contains(where: { eligible.contains($0) })` would classify a window as complication-eligible if any eligible source appeared at any point — even if the final trigger was IOB-only. Changed to `lastCoalescerSource` / `lastCoalescerSourceAt` tracking (add to R2a's `scheduleWatchStateUpdate`). Mode is now determined by the last trigger at coalescer fire time, aligning budget use with actual glucose-origin events.

**Robustness fix — R5d reload rate limiter:**
Added `lastWidgetReloadAt` persisted to App Group `UserDefaults`, capping forced reloads at once per 5 minutes. Prevents reload storms if App Group suite keys break, timestamps bounce, or the function is called repeatedly. Rate limiter state survives process restarts.

**Observability improvements — R1b logging:**
Added `queue_depth_before`, `queue_depth_after` (re-read once after cancel), `kept_epoch`, `kept_enqueued_at` fields. Added hard-cap warning log when `depth_after > 5` — indicates cancellation isn't taking effect. Removed race-prone startup drain log that re-read count before the method ran.

**Narrative fix — R2b ceiling acknowledged:**
Added explicit callout in R2b that the `(epoch, displayFields)` gate will not prevent the "early-nil then late-computed" double-send pattern, and that R2b may plateau above the ≤1.3x target. R2d is the structural fix for that case, not R2b.

**Validation improved:**
Added `timeline_entry_epoch` row to validation protocol — confirms WidgetKit actually advanced the timeline, not just that the App Group store is fresh.

**Decisions section update:**
R1b "FIFO certainty" framing softened to engineering tradeoff. The keep-1 decision stands, but the justification now correctly describes it as a tradeoff (self-healing via next reading's transfer) rather than a FIFO correctness claim.

**New Cursor prompts:**
- Prompt R5d-snapshot: `latestSnapshot()` thread safety, blocking I/O, and `readingDate` property name
- Prompt R5f-getTimeline: `TimelineEntry` type and reading epoch field for `timeline_entry_epoch` logging

---

### v1.6 — 2026-03-09 | ChatGPT critique #5 of Remediation Plan v1.5

**Logic fix — R2d mode selection corrected (again):**
v1.5's "last source" predicate was too strict: if `glucoseStored` fired then `iobUpdate` fired last in the same coalescer window, the last source would be non-eligible and no complication transfer would fire — silently suppressing legitimate glucose updates. Replaced with window-scoped check: `lastEligibleSourceAt >= coalescerFirstScheduledAt`. Correctly answers "did any glucose-origin event fire during this specific coalescer window?" for all source orderings. See Decisions & Rejected Alternatives for the full three-version design history.

**Correctness fix — coalescer state snapshotted before clearing:**
R2a's work item cleared `coalescerSources`, `coalescerTriggerCount`, and `coalescerFirstScheduledAt` before calling `sendDataToWatch`. Since R2d mode selection and logging depend on these values, they must be captured into local snapshots (`sourcesSnapshot`, `lastEligibleSnapshot`, `windowStartSnapshot`) before the clear. Added `lastEligibleSourceAt` to the snapshot/clear cycle. `sendDataToWatch` now receives these as parameters rather than reading stale/empty live properties.

**Robustness fix — R1b session readiness guard:**
`cancelStaleQueuedTransfers()` now guards on `session.activationState == .activated && session.isPaired && session.isWatchAppInstalled` before attempting cancellation. Avoids noise logs and undefined behavior when the watch is unavailable.

**Explicit dependency — R3 requires R1a:**
R3 phase header now carries a hard-dependency warning: R3 strips `glucoseValues` from the payload and relies on `readingEpoch` (added by R1a) as the only date derivation path. Shipping R3 before R1a will cause `saveComplicationSnapshot` to abort on every transfer and stop saving snapshots entirely. This was always implied by the sequence but is now an explicit constraint.

**Decisions section — R2d mode selection design history:**
Added entry documenting all three versions of the mode selection predicate (v1.4 "any in window," v1.5 "last source," v1.6 "window-scoped eligible") so future reviewers understand why the current design exists and won't re-raise the "any in window" or "last source" approaches.

**Test plan added to R2d:**
Two mandatory manual verification cases before shipping: (1) glucoseStored→iobUpdate must produce `mode=complicationAndUI`; (2) iobUpdate alone must produce `mode=uiOnly`.

---

### v1.7 — 2026-03-09 | ChatGPT critique #6 of Remediation Plan v1.6

**Correctness fix — R2a nil coalescerFirstScheduledAt handled explicitly:**
`?? Date()` was replaced with explicit nil detection. If `coalescerFirstScheduledAt` is nil at fire time (invariant violation), the plan now emits a `⚠️ coalescer_window_start_nil` warning and sets `windowStart = Date(timeIntervalSince1970: .infinity)` — a sentinel value that guarantees the epoch comparison always evaluates false, routing to the clock-skew fallback path rather than silently suppressing complication transfers.

**Correctness fix — R2d clock-skew fallback added:**
Wall-clock jumps backward (NTP sync, user time change) can cause `lastEligibleSourceAt >= windowStart` to evaluate false incorrectly. Added detect-and-log path: if epoch check fails but `sourcesSnapshot` contains an eligible source, emit `⚠️ eligible_source_clock_skew` and fail open (treat as eligible). Avoids the refactor cost of switching to `CACurrentMediaTime()` while making skew events observable. Refactor is deferred pending telemetry evidence. **Trigger for refactor:** if `eligible_source_clock_skew` fires more than ~once per week in production, that is the signal to switch `lastEligibleSourceAt` and `windowStartEpoch` to monotonic time (`CACurrentMediaTime()`) — wall clock is no longer trustworthy for this comparison.

**Observability fix — R2d transfer outcome logging:**
Added `complication_transfer_attempted` and `transfer_path` (complication | userInfo | skipped_session_not_ready) to prevent the "avg C/reading looks good because session-guard skips aren't counted" problem. `skipped_session_not_ready` frequency during exhaustion windows is itself a diagnostic signal.

**Robustness fix — R1b also drains queue-deep path:**
Added a third `cancelStaleQueuedTransfers()` call site: in `sendDataToWatch()`, if `queue_depth > 5` even before hitting the budget-exhausted branch. Handles the case where session was already activated before this code deployed (activation drain never ran). Safe because the readiness guard inside `cancelStaleQueuedTransfers()` prevents execution when watch is unavailable.

**Log level fix — R3 non-load-bearing missing keys:**
Non-load-bearing keys (`trend`, `delta`, etc.) now log at `debug` level when absent rather than ⚠️, preventing log spam when these fields are legitimately nil during early readings. `readingEpoch` retains ⚠️ as the only load-bearing field.

**Hard prerequisite — R5d blocked on Prompt R5d-snapshot:**
R5d section now carries an explicit blocking prerequisite: `latestSnapshot()` must be confirmed non-blocking and main-safe before implementing R5d as written. If it does file I/O, the read must move to a background queue. This was previously a "confirm" soft dependency; it is now a hard gate.

---

### v1.8 — 2026-03-09 | ChatGPT critique #7 of Remediation Plan v1.7 (final pre-implementation review)

**Cleanliness fix — nil-window sentinel replaced with explicit optional:**
`Date(timeIntervalSince1970: .infinity)` replaced with `windowStartEpoch: TimeInterval?`. `nil` is passed when `coalescerFirstScheduledAt` is nil (invariant violation). Self-documenting, won't appear in logs as a confusing timestamp, and routes cleanly to the fallback path. `sendDataToWatch` signature updated accordingly.

**Correctness fix — clock-skew fallback now requires `lastEligibleSourceAt != 0`:**
Without this guard, any eligible source in `sourcesSnapshot` would "invent" eligibility if the epoch comparison failed, even if `lastEligibleSourceAt` was never set. This would silently revert to "any eligible in snapshot" behavior and re-burn budget. The `!= 0` guard requires that eligibility was actually observed during the session, not just that an eligible source appears in the snapshot history.

**Shared helper — `sessionIsReadyForTransfer()` added:**
New method encapsulates the three-condition session readiness check (`activationState == .activated && isPaired && isWatchAppInstalled`). Used by `cancelStaleQueuedTransfers()` and the R2d transfer path. Prevents R1b and R2d from drifting out of sync again.

**Robustness fix — queue-deep drain cooldown:**
The third `cancelStaleQueuedTransfers()` call site (queue_depth > 5 path) now has a 60-second in-process cooldown via `lastQueueDeepDrainAt: TimeInterval`. Prevents repeated iterate+cancel overhead if something is rapidly enqueueing. New `lastQueueDeepDrainAt` property added to `BaseWatchManager`.

**Documentation fix — `WatchMessageKeys.date` comment strengthened:**
Inline comment in R3 allowlist now reads `⚠️ BUILD TIME, not CGM reading time — kept for backward compat only; never treat as readingDate`. Prevents the same bug from being reintroduced.

**Validation fix — BetterStack avg C/reading query must exclude session skips:**
R2 validation section now explicitly notes that the query must filter `transfer_path IN ('complication', 'userInfo')` and exclude `skipped_session_not_ready`. Prevents the metric from appearing better than reality due to silent session-guard skips.

---

### v1.9 — 2026-03-09 | Cursor audit Round 2 — all four prompts resolved

**R4b resolved:** `session(_:didReceiveApplicationContext:)` is absent from `WatchState.swift`. Purely additive — add after `sessionReachabilityDidChange` (~line 403) under `// MARK: - WCSessionDelegate`.

**R5d-kind resolved:** Widget kind string confirmed as `"TrioWatchComplication"` via `TrioComplicationDataStore.complicationKind` constant (line 147). Replaced `WidgetCenter.shared.reloadAllTimelines()` placeholder with `WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)`. Single widget in target confirmed.

**R5d-snapshot resolved:** `latestSnapshot()` performs synchronous file I/O (~200 bytes, JSON decode) but is safe to call on main — negligible cost for the file size, already used from multiple threads in production. No background queue needed. CGM timestamp property confirmed as `readingDate: Date` (distinct from `date: Date` = snapshot creation time). Hard prerequisite block removed; R5d can implement as written.

**R5f resolved:** Timeline entry type is `TrioWatchComplicationEntry` with `readingDate: Date` (CGM reading time) already propagated from snapshot into all 30 entries. Added R5f section with confirmed log snippet using `firstEntry.readingDate.timeIntervalSince1970`. `date` is the WidgetKit display time (distinct from `readingDate`); recency age in the complication views is computed as `entry.date.timeIntervalSince(entry.readingDate)`.

**Plan status:** All open questions closed. Implementation-ready.

---

### v1.10 — 2026-03-09 | Cursor plan-review pass — 6 bugs fixed

**Issue 1 (Critical) — R3 `readingEpoch` guard no longer kills `sendMessage`:**
Replaced `guard ... return` with a `readingEpochPresent` flag. `sendMessage` (budget-free watch UI path) always fires. Only `transferCurrentComplicationUserInfo` / `transferUserInfo` are gated on `readingEpochPresent`. Previous code would have blacked out the watch UI entirely whenever `readingEpoch` was absent (e.g. transitional build, empty `glucoseValues`).

**Issue 2 (Significant) — R5d reload now fires AFTER save in both handlers:**
`forceWidgetReloadIfStale()` previously fired before `saveComplicationSnapshot()` in both `didReceiveUserInfo` and `didReceiveApplicationContext`. WidgetKit would call `getTimeline` before fresh data was on disk, build a stale timeline, and the 5-minute rate limiter would block the corrective follow-up. Ordering corrected to: save → update timestamp → gap check → reload.

**Issue 3 (Notable) — renamed `lastUserInfoReceivedAt` → `lastDataReceivedAt`, updated in both handlers:**
`lastUserInfoReceivedAt` was never updated by the `didReceiveApplicationContext` path. During budget exhaustion windows (the exact scenario R4 targets), every applicationContext delivery would see `gap = infinity` and trigger a forced WidgetKit reload every 5 minutes — semantically wrong and noisy. Renamed to `lastDataReceivedAt` and updated in both handlers.

**Issue 4 (Compile error) — R1b `Set<ObjectIdentifier>` type mismatch fixed:**
`keeper.map { [ObjectIdentifier($0)] } ?? []` returns `[ObjectIdentifier]?` → `[ObjectIdentifier]`. Swift won't implicitly convert Array to Set. Fixed to `Set([ObjectIdentifier($0)])` in both branches.

**Issue 5 (Sequencing) — R2a now explicitly defines `complicationEligibleSources` and `lastEligibleSourceAt`:**
Both properties were referenced in R2a's code but only formally defined in R2d. Since R2a ships first (with a 24h observation window before R2d is even considered), R2a must define them. Added explicit callout block in R2a with the exact property declarations. R2d section updated to mark them as "already defined in R2a — shown for reference only."

**Issue 6 (Minor) — R4 guard placement now has explicit callout:**
Added `⚠️ Placement` note to R4's iOS-side block: the `guard budgetExhausted || queueDeep else { return }` goes at the END of `sendDataToWatch`, after all existing transfer and `sendMessage` calls. If placed before them it would skip all sends when budget is healthy — the opposite of the intent.

---

### v1.11 — 2026-03-09 | Cursor plan-review pass 2 — 4 issues fixed

**Issue 1 (Critical) — R5d `didReceiveUserInfo` gap now computed before timestamp update:**
In v1.10's fix, `lastDataReceivedAt = Date()` was set before computing the gap, making `Date().timeIntervalSince(Date())` ≈ 0ms always — sleep-gap detection was dead code. Fixed to match the correct `didReceiveApplicationContext` pattern: snapshot gap first, save, update timestamp, then conditionally reload.

**Issue 2 (Notable) — R2b `sendMessage` suppression documented as explicit tradeoff:**
The R2b gate `return` exits `sendDataToWatch` entirely, including the budget-free `sendMessage` path. IOB/COB updates sharing a gate key with the prior glucose reading will not reach the watch app UI until the next glucose reading. This is intentional but was undocumented. Added explicit `⚠️ Tradeoff` callout with the accept/revisit condition.

**Issue 3 (Minor) — `"bgTaskRefresh"` removed from `complicationEligibleSources`:**
No inventoried call site uses this source tag — it was a phantom entry. Removed from both the R2a definition and the R2d reference copy.

**Issue 4 (Minor) — Buggy `didReceiveApplicationContext` version removed:**
The plan previously showed a wrong implementation followed by "Wait — cleaner:" and then the correct one. Removed the wrong version; only the correct three-constraint ordering remains.

---

### v1.12 — 2026-03-09 | Cursor plan-review pass 3

**Issue 1 (Significant) — Snapshot age guard removed from `forceWidgetReloadIfStale()`:**
The guard (`snapshotAge > 300`) defeated itself: callers save before calling the function, so `latestSnapshot().readingDate` always reflects just-saved data. In the primary scenario (fresh reading arriving after a 2-hour sleep gap), `snapshotAge ≈ 60s`, the guard fails, and the reload is skipped — leaving the complication stale until WidgetKit's next natural refresh. The stale-backlog concern that motivated the guard is addressed upstream by R1b's queue draining. Guard removed; the 5-minute rate limiter is now the only storm backstop. Decisions table updated to reflect reversal.

**Issue 2 (Minor) — "v2.0" typo fixed in input documents header:**
The 6-issue plan-review pass was incorrectly attributed to "v2.0" — corrected to "v1.10".

---

### v1.13 — 2026-03-09 | ChatGPT review pass — 5 concerns addressed

**Concern 1 (act on it) — R2b gate now scoped to complication transfer only, not sendMessage:**
Previously the `guard gateKey != lastDispatchedGateKey else { return }` exited `sendDataToWatch` entirely, suppressing `sendMessage` for IOB/COB updates sharing a gate key with the prior glucose reading. Restructured using an `isDuplicateDispatch` flag: the complication transfer path is skipped when true, but `sendMessage` always fires. Follows the same pattern established by R3's `readingEpochPresent` flag. The tradeoff callout added in v1.11 is removed as the tradeoff no longer exists.

**Concern 2 (observability) — `widgetCenter_reload_triggered` now logs `reading_epoch` and `snapshot_read_ms`:**
After firing the reload, `forceWidgetReloadIfStale()` reads back the just-saved snapshot and logs `reading_epoch` (to detect stale-backlog reloads) and `snapshot_read_ms` (to prove main-thread I/O is negligible). Comment added: if `snapshot_read_ms` ever logs >20ms, move the read to a background queue.

**Concern 3 (main-thread I/O) — resolved via concern 2 log:**
No structural change to `latestSnapshot()` call site. The `snapshot_read_ms` log field provides production proof. If evidence emerges of >20ms reads, background queue refactor is the documented next step.

**Concern 4 (R2d clock-skew) — delta field added to skew fallback log:**
`eligible_source_clock_skew` log now includes `delta=Xs` (the difference between `lastEligibleSourceAt` and `windowStartEpoch`). Small negative delta → genuine time skew; large delta → logic bug. Directly answers the "skew vs bug" question without guesswork.

**Concern 5 (R4 complicationMessage scope) — explicit callout added:**
Added `⚠️ complicationMessage must be in scope` note alongside the R4 placement warning. `complicationMessage` must be built unconditionally at the top of `sendDataToWatch` — not gated on `readingEpochPresent` or any other condition — so R4's safety net always has a valid payload to send during exhaustion windows.

---

### v1.14 — 2026-03-09 | ChatGPT review pass 2 — 5 concerns addressed

**Concern 1 (stale snapshot reload) — `reload_with_stale_snapshot` warning log added:**
`forceWidgetReloadIfStale()` now logs `⚠️ reload_with_stale_snapshot` when `snapshotAge > 600s` at reload time, with `reading_epoch` and `snapshot_age` fields. Reload still fires — the rate limiter prevents storms — but the event is now searchable in BetterStack. Directly catches the reconnect-ordering edge case where a stale userInfo slips through before R1b's drain completes.

**Concern 2 (snapshot_read_ms measurement) — timer now wraps the call, logs before reload:**
Timer now measures `latestSnapshot()` on the actual call path (before reload is triggered), not after. Log fields `reading_epoch`, `snapshot_age`, and `snapshot_read_ms` all emit before `WidgetCenter.reloadTimelines()` fires. Reflects real I/O latency on the hot path.

**Concern 3 (wall-clock R2d) — monotonic refactor trigger documented:**
Added explicit trigger condition to the R2d clock-skew note: if `eligible_source_clock_skew` fires more than ~once per week in production, switch `lastEligibleSourceAt` and `windowStartEpoch` to `CACurrentMediaTime()`. No code change; telemetry determines whether the refactor is needed.

**Concern 4 (cancel_requested_count) — added to R1b drain log:**
`queue_drain` log now includes `cancel_requested=N` alongside `depth_before` and `depth_after`. Enables distinguishing "we asked to cancel N transfers" from "the queue visibly shrank by N" in BetterStack. The `queue_drain_incomplete` warning also includes `cancel_requested` for the same reason.

**Concern 5 (R4 uses raw activationState) — replaced with `sessionIsReadyForTransfer()`:**
R4's `updateApplicationContext` guard was checking only `activationState == .activated`, inconsistent with the `sessionIsReadyForTransfer()` helper built for exactly this purpose. Replaced; `context_skipped` log now includes all three conditions (`activation_state`, `paired`, `installed`) to make the skip reason visible. R4 decisions table updated accordingly.

---

### v1.15 — 2026-03-09 | Final review pass (ChatGPT + Cursor)

**Cursor — stale R5d section header fixed:**
"gated on snapshot age, not just receive gap" updated to "rate-limited, with diagnostic snapshot read" — the snapshot age guard was removed in v1.12.

**ChatGPT concern 1 (log spam) — not acted on:**
`forceWidgetReloadIfStale()` only fires when `gap > 600s` and at most once per 5 minutes — log spam is not a realistic risk in this call pattern. Skipped.

**ChatGPT concern 2 (stale threshold misclassifies sensor gaps) — fixed:**
Replaced the fixed `staleThreshold = 600s` with `snapshotAge > (receivedGap - 60)`. The real stale-backlog signature is `snapshotAge ≈ receivedGap` (snapshot barely advanced relative to the gap that triggered the reload). A fixed 600s threshold would misclassify legitimate >10-min sensor warmup or connectivity gaps as stale backlog. `forceWidgetReloadIfStale()` now accepts `receivedGap: TimeInterval` parameter; both call sites updated.

**ChatGPT concern 3 (queueDepthNow without readiness guard) — fixed:**
The queue-deep drain call site now guards `outstandingUserInfoTransfers.count` read behind `sessionIsReadyForTransfer()`. When not paired/installed the count can return stale values and trigger spurious `queue_deep_drain triggered` logs.

**ChatGPT concern 4 (R2d fallback conflates three scenarios) — fixed:**
Split into three distinct log strings: `eligible_source_window_nil_fallback` (nil windowStart — invariant violation), `eligible_source_clock_skew` (small negative delta < 5s — genuine NTP skew), and `eligible_source_epoch_inversion` (large negative delta — likely logic bug). Production triage can now distinguish these without guesswork.

**ChatGPT concern 5 (glucoseValues.first sorted-order assumption) — fixed:**
Both `watchStateToDictionary` (R1a `readingEpoch` payload) and `computeDispatchGateKey` (R2b gate epoch) switched from `.first?.date` to `.max(by: { $0.date < $1.date })`. Removes the load-bearing assumption that `glucoseValues` is sorted newest-first. Both now use the same source, so gate keys and `readingEpoch` always agree.

---

### v1.16 — 2026-03-09 | Self-review

**Bug fix — `forceWidgetReloadIfStale(receivedGap:)` call sites not updated in v1.15:**
The v1.15 signature change added `receivedGap: TimeInterval` to the helper but the two inline call sites in `didReceiveUserInfo` and `didReceiveApplicationContext` were not updated — both still called the old `forceWidgetReloadIfStale()` (no argument). This would not compile. Fixed: both call sites now pass `receivedGap: gap`. The orphaned "Update both call sites" migration note appended below the helper definition was also removed since it is now redundant.

No other issues found in self-review.

---

### v1.17 — 2026-03-09 | ChatGPT final pass

**Critical fix 1 — R5d "blocked" banner replaced:**
The `⚠️ Hard prerequisite: R5d implementation is blocked on Prompt R5d-snapshot` banner contradicted the Cursor Round 2 resolution already documented elsewhere in the plan. Replaced with a `✅ Confirmed safe on main` note referencing the resolution directly, with the `snapshot_read_ms > 20ms` refactor trigger retained.

**Critical fix 2 — ordering comment updated to use correct signature:**
The `// (2) save must happen BEFORE forceWidgetReloadIfStale()` comment in the `didReceiveUserInfo` ordering block used the old zero-argument signature. Updated to `forceWidgetReloadIfStale(receivedGap:)` to match the v1.15 signature change and prevent copy-paste compile errors. Changelog references to the old signature retained as historical record.

**Non-critical notes acknowledged, not acted on:**
- `max(by:)` on 288 values is O(n) — negligible for this call frequency; no change.
- R2d skew bucket thresholds are intentionally heuristic; documented as such.

---

## Implementation Log

### Build 132 — Step 1: R1a + R1b + R5e (2026-03-09)

**Commit:** `917777267` on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09`
**Build:** 132 (v0.6.0) — deployed to TestFlight, 17m 58s total

**R1a — Reading epoch keys:** Confirmed working. BetterStack logs show `reading_epoch` and `transfer_enqueued_at` present in watch-side payload merge at 21:25:54 UTC.

**R1b — Stale queue drain:** Confirmed working.
- 21:23:53 UTC: Startup drain attempted, `queue_drain_skipped session_not_ready activation=2` — `isPaired` or `isWatchAppInstalled` was momentarily false during app launch.
- 21:27:45 UTC: Queue drain fired successfully via budget-exhausted call site: `cancel_requested=44 depth_before=45 depth_after=1 kept_epoch=0 kept_enqueued_at=0`. All queued items were pre-R1a (no epoch data); FIFO fallback kept last item.
- 21:27:54 UTC: Follow-up drain: `cancel_requested=1 depth_before=2 depth_after=1` — new transfer enqueued between drains, immediately cleaned.
- 21:30:57 UTC: Steady state: `queue_depth=2` (down from 46-48 pre-deploy).

**R5e — BetterStack alert:** Configured manually in BetterStack UI. Warning severity.

**Observation:** The startup drain in `session(_:activationDidCompleteWith:)` was skipped due to session readiness timing, but the budget-exhausted drain in `sendDataToWatch` caught it on the next transfer cycle. The queue-deep observation path (>5 items, 60s cooldown) was not needed — the budget-exhausted drain handled the entire frozen queue.

**Next gate:** Observe 24h to confirm `queue_depth` p95 < 5 before proceeding to Step 2.

---

### Build 133 — Step 2: R2a + R3 (2026-03-10)

**Commits:** `a69955c06` (Step 1 fix: paired/installed drain log + comment), `4bb1018f3` (R2a + R3) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick a69955c06,4bb1018f3`
**Build:** 133 (v0.6.0) — deployed to TestFlight, 16m 14s total

**R2a — Coalescer attribution:** Confirmed working. BetterStack logs show:
- `coalescer_trigger` events with source tags: `glucoseStored` (eligible=true), `orefDetermination`, `iobUpdate` (eligible=false).
- `coalescer_fired` events with full attribution: `trigger_count=7 sources=glucoseStored,glucoseStored,glucoseStored,orefDetermination,iobUpdate,orefDetermination,orefDetermination last_eligible_at=1773138464`.
- Typical pattern: 3 glucoseStored triggers + 3-4 orefDetermination/iobUpdate triggers per 5-minute cycle, coalesced into a single fire.

**R3 — Complication payload allowlist:** Confirmed working.
- Watch-side `saveComplicationSnapshot` receives exactly the 7 allowlisted keys: `transfer_enqueued_at, currentGlucoseColorString, currentGlucose, delta, reading_epoch, trend, date`.
- No `complication_payload missing key` warnings — all 7 keys present in every transfer.
- No `complication_transfer_skipped` events — `readingEpoch` is always present (R1a keys established in build 132).
- Payload reduced from ~19KB (full message) to ~200 bytes (allowlist only) for complication transfers.

**R1b — Queue health (continued):** Queue depth steady at 1-2, consistent with build 132 baseline. `queue_drain` events still firing normally: `cancel_requested=1 depth_before=2 depth_after=1`.

**Bug fixes included in this build (post-Step-1 review):**
- Queue-deep drain block moved outside reachability branches (runs after all transfer paths).
- `session.outstandingUserInfoTransfers.count` read moved inside `sessionIsReadyForTransfer()` guard.
- Watch-side `saveComplicationSnapshot` logs warning when falling back to build-time date (readingEpoch missing).
- `queue_drain_skipped` log now includes `paired=` and `installed=` detail.

**Next gate:** Observe 24h coalescer attribution data to determine whether Step 3 (R2b dispatch gate) alone resolves redundant transfers, or whether Step 4 (R2d source-eligible send mode) is also needed.

---

### Build 134 — Step 3: R2b dispatch gate (2026-03-11)

**Commits:** `db760857b` (R2b dispatch gate) on `feature/watch-complication-improvements`; activation-clear fix pending commit
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick db760857b`
**Build:** Pending

**R2b — Per-reading-epoch dispatch gate:** Implemented.
- `lastDispatchedGateKey`: App Group-backed computed property using `appGroupIDCandidate()` (same helper used for generation counter diagnostics — known-good pattern).
- `computeDispatchGateKey(state:)`: Builds gate key as `"(epoch)|(currentGlucose)|(trend)|(delta)"` using `max(by: date)` for epoch (matching R1a). All fields are `String?` on `WatchState` — no locale sensitivity risk.
- Gate logic in `sendDataToWatch`: computed after `saveLatestDateToDisk`, before `sendMessage`. `sendMessage` always fires. Complication transfer gated on both `readingEpochPresent` and `!isDuplicateDispatch`. Logs `complication_transfer_gate_skipped` with gate key when duplicate detected.

**Code review feedback — Round 1 (Claude, 6 points evaluated):**

1. **`appGroupIDCandidate()` safety** — Confirmed: same helper used elsewhere in `AppleWatchManager` (line 192, generation counter). Falls back to `""` if nil (gate passes everything through). **No change needed.**
2. **Gate key write on non-duplicate only** — Confirmed correct: `lastDispatchedGateKey` only written when `!isDuplicateDispatch`. **No change needed.** (But see Round 2 #1 — this turned out to be in the wrong location.)
3. **Locale sensitivity risk on gate key fields** — Non-issue: `currentGlucose`, `trend`, `delta` are all `String?` on `WatchState` (pre-formatted). Epoch uses `String(Int(...))` (locale-safe). **No change needed.**
4. **Budget cycle reset — gate doesn't clear on new cycle** — Gate key persists in App Group UserDefaults indefinitely. After a budget cycle reset (~2.5h), if glucose hasn't changed, the first transfer of the new cycle would be suppressed. **Fix applied:** Added `lastDispatchedGateKey = ""` in `session(_:activationDidCompleteWith:)` so the first post-launch transfer always fires.
5. **`sendMessage` always fires** — Confirmed correct: gate only affects `transferCurrentComplicationUserInfo` and `transferUserInfo` paths. **No change needed.**
6. **Log noise from gate-skip on reachable/missing-epoch paths** — `isDuplicateDispatch` log fires even when complication transfer would have been suppressed by other conditions. Acceptable for debugging. **No change needed.**

**Code review feedback — Round 2 (ChatGPT, critical bug found):**

1. **🚨 Gate key advanced on sendMessage-only (reachable) path** — `lastDispatchedGateKey = gateKey` was written unconditionally before the reachability check. When the watch is in foreground (`isReachable == true`), `sendMessage` fires but no complication transfer occurs — yet the gate key is consumed. When the watch later goes to background for the same reading, the gate sees "duplicate" and suppresses the complication transfer. This directly undermines freshness during the foreground→background transition that users actually hit. **Fix applied:** Moved `lastDispatchedGateKey = gateKey` to immediately after each actual enqueue call (`transferCurrentComplicationUserInfo` and `transferUserInfo`), so the persisted key truly means "we successfully attempted a complication transfer." Gate key computation and duplicate check remain unconditional for logging/debugging. Placement after (not before) the enqueue is a defensive measure — if a future refactor adds an early return in the block, the gate key won't be prematurely consumed.
2. **Activation clear is a blunt instrument** — Clearing the gate on every activation effectively resets persistence across restarts. Accepted tradeoff: the gate's primary value is preventing duplicate transfers *within a session*, not across restarts. A TTL-based approach could be added later if needed.
3. **Suite instability** — `appGroupIDCandidate()` returns a deterministic value from Info.plist or bundle ID. Won't change between calls in the same app lifecycle. Non-issue.
4. **Gate key write placement: after enqueue, not top of block** — Reinforced that the write should be immediately after the actual `transferCurrentComplicationUserInfo` / `transferUserInfo` call, not at the top of the conditional block. This ensures the persisted key reflects an actual transfer attempt, making the code robust against future refactors that might add early returns.
5. **`!isReachable` gate on complication transfers** — Questioned whether gating complication transfers on `!session.isReachable` is intentional. **Confirmed as deliberate budget conservation:** when the watch app is foregrounded (`isReachable == true`), `sendMessage` updates the watch UI for free and the complication is not visible to the user. Firing `transferCurrentComplicationUserInfo` would waste budget on invisible updates. `transferCurrentComplicationUserInfo` works regardless of reachability (not an API limitation), but calling it only when not reachable is the correct design choice. Added explicit code comment documenting this rationale.

**Observation:** The Round 2 bug (#1) was the most critical finding across both reviews. The failure mode (foreground `sendMessage` consumes the gate, suppressing the first background complication transfer for the same reading) would have been triggered on every foreground→background transition where the reading hadn't changed — a common real-world scenario.

**Next gate:** Build + deploy, then observe 48h BetterStack data for `complication_transfer_gate_skipped` frequency and avg C/reading.

---

### Builds 137-138 — Cloud logging pipeline fixes (2026-03-12/13)

**Scope:** Logging pipeline fixes — not a complication-freshness step, but directly impacts Step 4 decision gate.
**Design doc:** `docs/completed/logging-fixes/logging-fixes-design-doc.md` v1.11
**Implementation plan:** `docs/completed/logging-fixes/logging-fixes-implementation-plan.md` v1.14
**Patches:** `06-cloud-logging.patch` and `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --from-feature-branch`

**Build 137 (Phase 1, 2026-03-12):** Embed `[b:BUILD]` in all log lines, parser/uploader extraction, retention reduction (7d→48h, 20→10 files), upgrade-time flush on both watch and phone, app launch sentinels, drain file ACK fix (`batchAck` dispatch in WatchState + `transferUserInfo`-based confirmation).

**Build 138 (Phase 2, 2026-03-13):** Cleanup observability (`[CLEANUP]` tags on all 7 deletion sites, `[INVENTORY]` daily health check, inline metrics with cached counts, retention summaries), `DateFormatter` caching in SimpleLogReporter and WatchLogger, watch debug view LOG FILES section, `flushToPhone` crash-safety fix (write-before-send durability).

**Impact on complication-freshness observation:**
- Before build 137, avg C per build was unreliable: `CloudLogUploader.buildCommonAttributes()` stamped `build` from `Bundle.main` at upload time. Backlogged watch logs (drain files up to 7 days old, pending payloads) were attributed to the uploading build, not the originating build. This was discovered when build 136 avg C data included events from March 10-11 with `dt` predating deployment.
- Build 137+ embeds the true build in each log line at write time. `parseWatch()` and `parseIOS()` extract it; `CloudLogUploader` uses parsed build when present, falls back to `Bundle.main` for old-format lines.
- The Step 4 decision gate (avg C > 1.3?) should query build >= 137 data only. Earlier builds have contaminated build attribution.

**Next gate:** Observe 48h from build 137 deployment (2026-03-12). Run avg C query ~2026-03-15. If avg C <= 1.3: skip Step 4, proceed to Step 5 (R4). If avg C > 1.3: implement Step 4 (R2d).

---

### Build 140 — Step 7: R6 HealthKit Background Delivery (2026-03-14)

**Commits:** `1b1c2d10d` (R6 implementation), `f1cadf3e2` (HKUnit fix + NSHealthUpdateUsageDescription) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick 1b1c2d10d,f1cadf3e2`
**Build:** 140 (v0.6.0) — deployed to TestFlight

**R6a — Background delivery registration:** Confirmed working. `hk_background_delivery_registered success=true` logged at 15:45:19 UTC on first watch app launch after install.

**R6b — Observer query:** Confirmed working. `hk_observer_fired` events observed at 15:45:20, 15:52:54, 15:54:15 UTC with correct glucose values (110, 111) and derived deltas (-9, -2).

**R6c — Sample fetch + snapshot save:** Confirmed working. Glucose extracted from HealthKit samples, delta derived from 2-sample comparison, snapshot saved to App Group via `TrioComplicationDataStore.shared.save()`.

**Unplanned remediations (2 issues discovered during build/deploy):**

1. **`HKUnit.milligramsPerDeciliter` unavailable on watchOS:** Build error — `type 'HKUnit' has no member 'milligramsPerDeciliter'`. The convenience property is a custom extension in `LoopKit/MockKitUI`, linked only to the iOS target. **Fix:** Replaced with `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))` inline in `WatchState.swift`.

2. **`NSHealthUpdateUsageDescription` required by App Store Connect:** Upload to TestFlight rejected (ITMS-90683) despite `toShare: nil`. Apple requires both HealthKit usage description keys whenever the `com.apple.developer.healthkit` entitlement is present, regardless of actual API usage. Developer forums confirm this is a blanket validation rule affecting both read-only and write-only apps. **Fix:** Added `NSHealthUpdateUsageDescription` to `Trio Watch App/Info.plist`. The string does not grant additional capability — the authorization request remains read-only (`toShare: nil`).

**Observation:** Both remediations were discovered during the build/deploy cycle, not during the code review phase. The `HKUnit` issue was a watchOS target linkage gap that Xcode doesn't surface until compilation. The `NSHealthUpdateUsageDescription` requirement was a runtime App Store validation rule not documented in Apple's HealthKit authorization guide — only discoverable via actual upload attempt or developer forum reports.

**Next gate:** Observe 48h `hk_observer_fired` events. Validate: (a) cadence matches CGM interval (~5 min), (b) `save_age` p90 < 300s, (c) events continue during budget-exhaustion windows, (d) dual-delivery dedup behavior matches plan §R6 expectations.