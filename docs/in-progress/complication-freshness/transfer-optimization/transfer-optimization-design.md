# Transfer Optimization — Design (R1 + R2 + R3)

**Version:** v1.3
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-04-08 22:26 CET
**Status:** COMPLETED — all steps shipped (builds 132-138); reachability-gate bug fix shipped (build 142)

## Overview

R1, R2, and R3 all reduce unnecessary complication transfers via WatchConnectivity. R1 enables R2's gate. R3 shipped with R2a. These form a continuous improvement sequence:

- **R1** — Add reading epoch to payload + cancel stale queue
- **R2** — Reduce redundant triggers (coalescer attribution, dispatch gate, age gate, authoritative-source gating)
- **R3** — Strip oversized payload from complication transfers

See [problem-and-strategy.md](../problem-and-strategy.md) for overall context.

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
// (reuses APP_GROUP_SUITE constant, same suite as lastDataReceivedAt / R5d gap detection)
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

Gate **only** the budget-consuming path (`transferCurrentComplicationUserInfo`) on "current complication age > T". Do not gate `sendMessage`: that path is budget-free and keeps the watch app UI fresh; gating it would stale the UI for no benefit. The fallback `transferUserInfo` path (when budget is exhausted) remains unchanged — still allowed when not duplicate, so the queue continues to receive one representative transfer per reading during exhaustion.

- **Complication age on iOS:** In the helper (see code sketch), use this exact pattern: `guard let suiteName = appGroupIDCandidate().value, let defaults = UserDefaults(suiteName: suiteName) else { return .infinity }`; then `let lastValid = defaults.object(forKey: "TrioComplication_lastValidTimestamp") as? Date`; `if lastValid == nil { return .infinity }`; else `return max(0, Date().timeIntervalSince(lastValid!))`. Same key as `TrioComplicationDataStore.lastValidTimestamp` (watch).
- **Threshold:** T = 600 seconds (10 minutes) as initial value. Data-driven from BetterStack (48h window): reload_age proxy p90 ≈ 10.3m; counts per day for staleness >10m ≈ 79/day, >12m ≈ 40/day, >15m ≈ 14/day. T=10m targets the worst staleness while leaving room to tune (e.g. 12m if budget still drains too fast, 8m if budget remains high and staleness is acceptable).
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

**Skip-log taxonomy (BetterStack):** Three queryable categories. Step 3b age-gate skip: `skip_reason=age_gate`. R2b duplicate skip: document as `skip_reason=duplicate_gate` (even if the current log line doesn't include the literal yet). Missing readingEpoch: its own case. Queries can filter by: age_gate, duplicate_gate, missing readingEpoch.

#### Validation

| Metric | Signal | Pass threshold | Falsified if |
|---|---|---|---|
| Budget spread | Daily complication transfers / remaining budget over time | Budget no longer drains in first 2–3h after reset; some budget remains into afternoon | Budget still exhausted within 3h of reset |
| Staleness | `complication_reload_age` / (future) `timeline_built snapshot_age` | Fewer events with age >15m; p90 age stable or improved | Increase in >15m outliers |
| Gate behavior | `complication_transfer_age_gate_skipped` count; transfer logs with `complication_age_seconds` | Age gate applies ONLY to transferCurrentComplicationUserInfo (budget-consuming); NOT sendMessage, NOT userInfo fallback. Transfers when age > T; skips when age ≤ T. Budget not exhausted in first 2–3h after reset. | Transfers when age < threshold; no age-gate skips when fresh; or budget still exhausted in 3h |

#### Sequence

Step 3b is implemented and deployed **after** Step 3 (R2b) and **before** Step 4 (R2d). The 48h observation after Step 3 can include Step 3b in the same build, or Step 3b can ship as a follow-on PR after R2b data is collected.

**Implementation status (2026-03-12):** Step 3b code complete in `AppleWatchManager.swift`. Verified: `currentComplicationAgeSeconds()` (exact 4-step pattern, no Watch Shared import), `complicationAgeGateThresholdSeconds = 600`, age gate applied only when `remaining > 0`; budget-exhausted fallback ungated; `lastDispatchedGateKey` set only on actual enqueue; skip/success logs include `skip_reason=age_gate`, `reading_date_epoch_seconds`, `complication_age_seconds`. Observe 48h (budget spread, age-gate skip volume) before Step 4.

**Logging pipeline fixes (2026-03-13):** Builds 137-138 deployed with cloud logging pipeline fixes (see `docs/completed/logging-fixes/`). These fixes are directly relevant to the Step 4 decision gate because they resolve the build-mislabeling problem that made avg C per-build measurements unreliable. Before build 137, `CloudLogUploader` stamped all events with the phone's `Bundle.main` build at upload time — backlogged watch/complication logs (up to 7 days old) were attributed to the wrong build. Key fixes: `[b:BUILD]` embedded in every log line at write time; drain retention reduced from 7d to 48h; upgrade-time flush on both watch and phone; drain file ACK gap fixed via `transferUserInfo`-based confirmation pathway. The reliable observation window for the Step 4 avg C gate starts from build 137 deployment (2026-03-12).

### Bug fix: `transferUserInfo` fallback gated behind `!isReachable`

**Discovered:** 2026-03-19 (code audit of `sendDataToWatch`)

#### Problem

The Step 3b code sketch above (and the shipped implementation) nests the budget-exhausted `transferUserInfo` fallback inside the `!isReachable` compound condition:

```swift
if !session.isReachable, readingEpochPresent, !isDuplicateDispatch {
    if session.remainingComplicationUserInfoTransfers > 0 {
        // age gate -> transferCurrentComplicationUserInfo
    } else {
        // budget-exhausted -> transferUserInfo   <-- UNREACHABLE when isReachable == true
    }
}
```

The `!isReachable` gate is correct for the budgeted `transferCurrentComplicationUserInfo` path (when the watch is foregrounded, the complication isn't visible, so budget should be conserved). But the budget-exhausted fallback serves a different purpose: ensuring *some* background delivery is queued for complication refresh even when budget is zero. Gating it on `!isReachable` means that when the watch is reachable and budget is exhausted, `sendMessage` fires (updating the foreground app) but no `transferUserInfo` is enqueued. Once the watch wrist-drops, the complication has no pending delivery.

#### Evidence

An audit of `sendDataToWatch` traced the execution for `isReachable == true, remaining == 0, !isDuplicateDispatch`:

1. `sendMessage(fullMessage)` fires (budget-free)
2. Log: `complication_transfer_skipped_reachable remaining=0`
3. `if !session.isReachable` — FALSE, entire complication block skipped
4. No `transferUserInfo` enqueued. No `lastDispatchedGateKey` update.
5. The `complication_transfer_skipped_reachable` log was misleading — it said "skipped" for the budget-exhausted case as if skipping were intentional, when in fact no fallback was available.

#### Corrected design

Extract the budget-exhausted fallback into an independent block that runs regardless of reachability. The budgeted path stays inside `!isReachable`:

```swift
// Budgeted complication transfer — only when unreachable + budget available
if !session.isReachable, readingEpochPresent, !isDuplicateDispatch, budgetSnapshot > 0 {
    // age gate -> transferCurrentComplicationUserInfo (unchanged)
}

// Budget-exhausted fallback — runs regardless of reachability
if budgetSnapshot == 0, readingEpochPresent, !isDuplicateDispatch {
    cancelStaleQueuedTransfers()
    session.transferUserInfo([WatchMessageKeys.watchState: complicationMessage])
    lastDispatchedGateKey = gateKey
}
```

Split the `complication_transfer_skipped_reachable` log into two cases:

| Condition | Log |
|---|---|
| reachable + budget > 0 | `complication_transfer_skipped_reachable remaining=N` |
| reachable + budget == 0 | `complication_budget_exhausted_reachable remaining=0 — userInfo fallback will enqueue` |

**Behavior matrix (post-fix):**

| Scenario | `sendMessage` | `transferCurrentComplicationUserInfo` | `transferUserInfo` | `lastDispatchedGateKey` updated |
|---|---|---|---|---|
| reachable + budget > 0 | yes | no | no | no |
| reachable + budget == 0 | yes | no | yes | yes |
| unreachable + budget > 0 | no | yes (if age gate passes) | no | only if age gate passes |
| unreachable + budget == 0 | no | no | yes | yes |

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

> **Status:** SKIPPED — gate evaluation (2026-03-17) confirmed avg C ≤ 1.3 on build 141 data (1.06 overall, 0.77 budget-ok). R2d criterion not triggered. See [implementation plan Step 4 Gate](transfer-optimization-implementation-plan.md) for the full analysis.
>
> *Original gate criteria:* Implement if R2a attribution data shows either (a) non-glucose publishers causing >30% of multi-C readings, or (b) R2b alone does not reduce avg C/reading below 1.3x within 48h of shipping. This is the most reliable structural path from 2.85x → ~1.0x.

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

## Changelog

### v1.3 (2026-04-08 22:26 CET)

- R2b pseudocode comment: `lastUserInfoReceivedAt` → `lastDataReceivedAt` (R5d rename, build 143).
- Reason: symbol name accuracy in cross-reference to App Group persistence.

### v1.2 (2026-03-19 15:08 CET)

- Updated status to reflect build 142 deployment and BetterStack validation.
- Reason: fix was shipped in build 142 and confirmed working in production logs.

### v1.1 (2026-03-19 15:03 CET)

- Added "Bug fix: `transferUserInfo` fallback gated behind `!isReachable`" section after Step 3b.
- Reason: document the bug where the budget-exhausted fallback was unreachable when `isReachable == true`, the audit evidence, and the corrected two-block design.

### v1.0 (2026-03-19 11:33 CET)

- Extracted from complication-freshness-remediation-plan.md v1.56 during docs reorganization.
