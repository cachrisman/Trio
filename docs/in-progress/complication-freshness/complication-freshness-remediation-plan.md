# Trio watchOS Complication — Freshness Remediation Plan

**Version:** 1.25 | **Date:** 2026-03-13
**Status:** ✅ Step 3b deployed (builds 137-138 include Step 3b + logging pipeline fixes); observing 48h from build 137 deploy (2026-03-12) before Step 4 decision gate
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
| **This document** | **R1 through R5** | Budget exhaustion, redundant triggers, payload size, reconnect safety net, observability |

When referencing the prior plan's work in code comments or PRs, use `FP-Phase`. When referencing this plan, use `R1`–`R5`.

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

## R4 — App Group Safety Net During Budget Exhaustion

**Priority:** P1 | **Effort:** 2–3 hrs | **Recommended:** Ship after R3
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

```swift
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

### R5c — didReceiveUserInfo decode latency

```swift
// WatchState.swift, didReceiveUserInfo (~line 286):
let receiveTimestamp = Date()
// ... existing processing ...
// After saveComplicationSnapshot returns:
let decodeMs = Int(Date().timeIntervalSince(receiveTimestamp) * 1000)
debug(.watchManager, "⏱️ userInfo_decoded reading_epoch=\(readingEpoch) decode_ms=\(decodeMs)")
```

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

### R5f — WidgetKit timeline validation logging

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
| #4 Proactive transfer on iOS app foreground | Not implemented | Defer until R2 ships; would add a 9th call site |
| #6 Log `isReachable` duration at transfer | Not implemented | Low effort; add `lastReachabilityChangeDate: Date?` to `AppleWatchManager` |
| #8 sendMessage latency instrumentation | Partial | R5b |
| #12 Coalescer trigger count + source logging | Not implemented | R5a / R2a |
| #13 Lightweight complication payload | Not implemented | R3 |
| #16 Sleep-gap forced reload | Not implemented | R5d |
| #19 `WKExtendedRuntimeSession` for urgent glucose | Not implemented | High value for urgent-low; significant effort; separate project |
| #21 `didReceiveUserInfo` decode latency | Not implemented | R5c |
| #24 Consistent `reading_epoch` across pipeline | Partial | Gaps at coalescer trigger and `didReceiveMessage`; closes with R5a + R5b |
| #28 WidgetKit `getTimeline` call clustering | Partial | Generation counter present; per-family clustering untracked; low priority |
| #30 Scheduled freshness alert | Not implemented | R5e |

---

## Implementation Sequence

```
R1a  (readingEpoch + transferEnqueuedAt keys in dict)  ─┐
R1b  (cancel stale queue — startup + before enqueue)    ├── one PR
R5e  (BetterStack exhaustion alert)                    ─┘

        ↓ deploy, collect 24h data

R5a / R2a  (coalescer source logging)    ← ship; collect 24h coalescer_fired data
R3         (allowlist complication msg,  ← parallel with R2a; no dependency
            watch-side prefer readingEpoch key)

        ↓ R2a data confirms publisher attribution

R2b  (epoch+fingerprint dispatch gate)               ← ship; observe 48h

Step 3b  (complication-age stale-first gate; T=600s) ← ship after R2b; observe 48h

        ↓ if avg C ≤ 1.3 after 48h → R2c (optional, low priority)
        ↓ if avg C > 1.3 after 48h → R2d (pipeline split)

R2c  (settings debounce — only if R2d not pursued)
R2d  (authoritative-source gating — if R2b insufficient; supersedes R2c)

R4   (updateApplicationContext iOS +     ← benefits from R3 payload being small
      didReceiveApplicationContext watch)

R5b + R5c + R5d  (observability)         ← opportunistic, ship with any PR
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
This gives `timeline_entry_epoch` and `snapshot_age` at timeline-build time — confirms WidgetKit is picking up fresh App Group data.

---

## Changelog

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

First draft of the Freshness Remediation Plan (R1–R5), synthesized from:
- BetterStack telemetry analysis (build 131, 2026-03-08/09)
- ChatGPT critique #1 of the Next-Steps Report
- Prior implementation plan `complication-freshness-implementation-plan.md` v1.27 (FP-Phase 0–3)

Established root-cause hierarchy (redundant triggers → budget burn → frozen queue → stale complication), defined R1–R5 phases, and set the implementation sequence.

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
