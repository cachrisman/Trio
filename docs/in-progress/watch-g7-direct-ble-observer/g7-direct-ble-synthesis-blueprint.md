# Trio Watch G7 Direct BLE Observer — synthesis blueprint (v2)

**Goal:** combine the strongest implementation choices across the 5 surviving variants (24, 25, 26, 29, 30) into a single composite implementation with the highest chance of reliably observing the Dexcom G7 watch app's BLE session and delivering sustained EGV reads.

This is **synthesis, not selection**. Each domain is evaluated separately; the final composite records which variant donates which piece, with explicit compatibility analysis and concrete file-level provenance.

**Change from v1:** previous version recommended PR 30 as base with 5 transplants. This version uses **PR 29 as base** with targeted PR 30 transplants. The destination is similar; the starting point is smaller and more debuggable.

---

## Phase 0: Fatal-flaw sweep

Three correctness bugs surfaced during code review. They disqualify the affected subsystems from being donors but do not disqualify the variants entirely.

### Bug F1: PR 26 EGV cadence is one-shot per connect cycle
PR 26's design admits: *"EGV cadence: one request per connect/auth-ready cycle."* No periodic timer, no auth-transition trigger. Mission-critical bug for sustained delivery.
**Disqualifies:** PR 26 cadence subsystem.

### Bug F2: PR 26 EGV parser uses Unix epoch for `messageTimestamp`
```swift
let readingDate = Date(timeIntervalSince1970: TimeInterval(messageTimestamp - UInt32(age)))
```
`messageTimestamp` is **seconds since sensor pairing**, not Unix epoch seconds. Computed `readingDate` would be in 1970.
**Disqualifies:** PR 26 parser.

### Bug F3: PR 25 EGV parser has wrong byte offsets
Reads glucose at bytes 1-2, age at byte 15 as UInt8. Correct offsets per G7SensorKit `G7GlucoseMessage.swift`: glucose at bytes 12-13 (UInt16), age at bytes 10-11 (UInt16). Will produce garbage glucose values.
**Disqualifies:** PR 25 parser.

### No fatal flaws in PR 24, PR 29, PR 30
PR 29 has a minor activation-date drift in its parser (recomputes activation per message instead of anchoring once) — sub-second drift, fixable in one line.

---

## Phase 1: Per-domain comparison

| Domain | Winner | Runner-up | Notes |
|---|---|---|---|
| Central allocation & lifecycle | PR 30 | PR 29 | PR 30 has explicit `primeCentral()` from ExtensionDelegate |
| Attach / retrieval ladder | PR 30 | PR 29 | PR 30 most complete; PR 29 same shape, simpler |
| Peripheral filtering | PR 29 | PR 24 | PR 29 accepts retrieval-path peripherals via `source.hasPrefix("retrieved_")` |
| Discovery breadth | All except PR 24 | — | `nil`/`nil` mirrors DiaBLE; PR 24's targeted approach is the failed-prior-Trio pattern |
| Auth advance condition | PR 30 | PR 29 | PR 30: prefer-strict, fall back permissive after 6s. PR 29: permissive-only with 8s fallback |
| EGV request cadence | PR 30 (by a lot) | — | Multi-trigger: first connect + auth transition + 5m30s fallback + write retry. Critical donor. |
| Backfill | PR 30 | PR 29 | PR 30 parses backfill, doesn't store |
| Reconnect & session stability | PR 29 | PR 30 | PR 29 has cleanest state model; both correctly avoid scene-gating |
| Source attribution | PR 30 model + PR 24 winner rule | — | PR 30: snapshot mirror pattern. PR 24: source-priority tie-break |
| Local delta computation | PR 30 | PR 29 | PR 30's cache survives reconnect cycles; PR 29 recomputes per cycle |
| Observability | PR 30 | PR 29 | PR 30: structured emit + negative-proof events. PR 29: high pre-connect detail |
| Scaffolding integration | All correct | — | All 5 extend the existing store rather than reinvent (post-baseline-fix) |

---

## Phase 2: Why PR 29 is the implementation base (not PR 30)

PR 30 wins more domains. PR 29 wins as base. These are not contradictory.

**The right question is "easier to port mechanics into the simpler base, or extract simplicity from the larger base?"** The mechanics from PR 30 are surgical and named (cadence model, auth fallback, session-outcome logging). They lift cleanly. Extracting simplicity from PR 30 — removing layers of indirection, helper types, abstractions — is harder and easier to break.

Practical considerations:

- **PR 29: 972 swift LoC. PR 30: 1919 swift LoC.** Roughly 2x for similar functional surface.
- **You will iterate.** First flash will likely fail somewhere subtle. Every extra layer in the base is something to read past while debugging a BetterStack log.
- **PR 29 reconnect discipline is native.** If you base on PR 30, you adopt PR 30's reconnect (which is also fine). If you base on PR 29, you keep its model. Either way no transplant needed for reconnect.
- **PR 29's parser has a minor bug.** PR 30's is more rigorous. But the bug is a one-line fix.
- **The riskiest transplants are mechanical (cadence, auth gate).** Those go from PR 30 into any base. Doesn't favor either choice.

The tradeoff that decides it: maintainability during iteration matters more than the convenience of PR 30's mechanics being "already there."

---

## Phase 3: Why we keep PR 29's guarded scan timeout (not PR 30's no-timeout design)

This is the most contested choice in the synthesis. PR 30 designed out the scan timeout entirely — the philosophy is "any timer that can tear down state is a footgun, and the safest timer is one that doesn't exist."

I considered transplanting PR 30's no-scan-timeout model to the PR 29 base. After re-reading both implementations carefully, I'm leaving PR 29's guarded scan timeout in place. Reasoning:

**1. PR 29's scan timeout is correctly guarded.**

```swift
let workItem = DispatchWorkItem { [weak self] in
    guard let self else { return }
    guard self.activePeripheral?.state != .connected else {
        self.log("event=g7_ble_scan_timeout_ignored reason=already_connected")
        return
    }
    self.log("event=g7_ble_scan_stopped reason=timeout timeout_s=\(Int(self.scanTimeout))")
    self.centralManager.stopScan()
    self.stage = .idle
    self.scheduleReconnect(reason: "scan_timeout")
}
```

The check `activePeripheral?.state != .connected` is the exact protection that the prompt's anti-pattern guidance demands. The timer cannot tear down a healthy connected session. It only fires if scan has been running 15s without connecting.

**2. The downside of PR 30's no-timeout design is real.**

If `central.scanForPeripherals(...)` is running and no candidate ever appears (Dexcom watch app paused, sensor dropped, Bluetooth glitching), PR 30 has no mechanism to escape. `kickAttachIfNeeded` won't be called again until:
- Central state changes (`centralManagerDidUpdateState`)
- Foreground re-entry (`scenePhaseChanged(.active)`)
- A connect event fires (`centralManager(_:connectionEventDidOccur:for:)` — only if registered)
- An external `start()` call

In a steady-state failure mode where scan is up but receives nothing, none of those naturally fire. You're stuck in `.searching` until something changes. PR 29's bounded scan triggers a re-attach through the ladder, which is exactly what you want.

**3. The "no timer is a safer timer" philosophy is principled but premature here.**

PR 30's design is correct in the sense that *every* timer is a potential anti-pattern source. But the anti-pattern the prompt warned about was specifically "timer fires after successful connect and tears down a healthy session." PR 29's guarded version explicitly cannot do that. The principle is satisfied without removing the safety net.

**4. The cost of keeping PR 29's scan timeout is essentially zero.**

It's already there. It's already correctly guarded. Removing it requires editing PR 29's state machine and verifying no code path now depends on the scheduled work item. Net effort to remove: real. Net effort to keep: zero. Net mission risk of keeping: zero (because guarded). Net mission risk of removing: small but nonzero (loss of recovery from no-candidate scan stalls).

**5. We can revisit on device data.**

If BetterStack shows the scan timeout firing aggressively without need, dial up the timeout or remove it then. If it shows scan stalls being recovered by the timeout, vindicated. We don't need to make this call before first flash.

**Decision: keep PR 29's 15s guarded scan timeout. Do not transplant PR 30's no-timeout design.**

This is the only place I diverge from "PR 30 wins the mechanics." The cost/benefit doesn't favor the transplant.

---

## Phase 4: Composite blueprint

### Base implementation: PR 29

Use PR 29's full file structure, state model, and reconnect/scene discipline. Files:
- `Trio Watch App Extension/G7DirectBLEObserver.swift` (single 816-line file)
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` (UI integration)
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` (UI integration)
- `Trio Watch App Extension/WatchState.swift` (status fields)
- `Trio Watch Shared/TrioComplicationDataStore.swift` (extends existing)

PR 29 already does these things correctly — keep them as-is:
- Eager restoration-backed `CBCentralManager` on dedicated serial queue
- Attach ladder: persisted identifier → `retrieveConnectedPeripherals` (cgmService and FEBC) → broad scan
- Broad discovery (`nil`/`nil`)
- Scene model: `.active` resumes, `.inactive`/`.background` are no-op
- Reconnect with capped exponential backoff, never gated on scene state
- `isHardStopped` separate from `isForegroundActive` — clean state semantics
- Guarded scan timeout (15s) that re-attaches without teardown
- Scaffolding extension via `TrioComplicationSnapshot.source` and store extension
- Standalone tolerant peripheral filtering with retrieval-path bypass for nil names
- Source attribution through `WatchState.applyG7DirectBleSnapshot`
- Verbose pre-connect logging
- Session-outcome logging on disconnect

### Modifications grafted from PR 30

Five surgical modifications. Each names the specific donor PR and the problem it solves.

#### MOD-A: Multi-trigger EGV cadence (donor: PR 30)

**Problem solved:** PR 29's flat 60s EGV request cadence is too aggressive. The G7 sensor only emits fresh EGVs every ~5 minutes; requesting every 60s produces 5x the BLE traffic with the same data, increases sensor write load unnecessarily, and creates more opportunities for write failures. A multi-trigger cadence aligned with the sensor's natural cycle is more reliable and more battery-friendly.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Changes:**
- Replace `egvRequestInterval: TimeInterval = 60` with `egvFallbackTimerSeconds: TimeInterval = 330` (5m30s, matching PR 30).
- Modify `handleAuthPayload(_:)` so that when an `authenticated && bonded` auth challenge is observed *after* `hasAdvancedBeyondAuth == true`, it triggers another EGV request (the auth-transition trigger). Today PR 29 only triggers from `advanceToControl` once.
- Modify `sendEGVRequest(reason:)` callers: keep the initial trigger from `handleNotificationState` when control notify enables. Add the auth-transition trigger from `handleAuthPayload`. Keep the periodic timer but at 330s instead of 60s, fired by `scheduleEGVRequest`.
- Add control-write retry: when `peripheral(_:didWriteValueFor:error:)` reports a non-nil error on the control characteristic, schedule a retry after 10s with a per-cycle attempt cap of 3. Currently PR 29's path on write failure is `scheduleReconnect` — keep that for unrecoverable errors, but for the typical "sensor not ready" transient, retry the write before tearing down the connection.

**Verification:** the auth handler is already re-entrant (called per characteristic-value-update). The request timer is already cancellable (`egvRequestWorkItem?.cancel()`). The control-write retry needs a new `controlWriteAttemptThisCycle` counter.

#### MOD-B: Auth advance with prefer-strict-then-permissive-fallback (donor: PR 30)

**Problem solved:** PR 29 advances on `authenticated == true` regardless of the bonded bit, with an 8s fallback to advance-anyway. PR 30's gate is more conservative: prefer `authenticated && bonded` when observable, fall back permissively after 6s. The risk PR 29 carries is that "authenticated but not bonded" may indicate a transient state that the sensor hasn't fully committed to; advancing then writing `0x4e` could fail. Walking through it: even if PR 29 advances "too early" the worst case is the EGV write fails and we retry — so the practical difference is small. But PR 30's choice produces less log noise and less write traffic on transient half-states.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Changes:**
- In `handleAuthPayload(_:)`: change the advance trigger from `if authenticated` to `if authenticated && bonded`. If `authenticated && !bonded`, log `g7_ble_blocked_auth_partial` and do not advance.
- The 8s fallback timer (`scheduleAuthFallback`) already handles the case where neither flag becomes observable. Reduce to 6s to match PR 30's experience-based constant.
- Keep the fallback timer's behavior (advance to control after timeout regardless of observed state) — that's the permissive escape valve.

#### MOD-C: Activation-date anchoring fix (donor: PR 30 protocol)

**Problem solved:** PR 29's `parseGlucose(_:)` recomputes `activationDate = Date() - messageTimestamp` on every message. Wall-clock drift between consecutive readings means each computed `activationDate` differs slightly, so consecutive `readingDate`s for the same sensor minute won't be exactly equal. Sub-second issue, but creates noise in dedup logic and in BetterStack log analysis. PR 30 anchors `activationDate` per cycle and reuses; PR 24 anchors once and persists.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Changes:**
- Add a `private var sessionActivationDate: Date?` field, reset in `connect(_:source:)` and on disconnect.
- In `parseGlucose(_:)`: if `sessionActivationDate == nil`, compute and assign; otherwise reuse. Stay computed-from-message rather than persisted across cycles — sensor pairing changes, sensor swaps, and watch reboots all invalidate the anchor.

This is a one-block change in `parseGlucose`. ~5 lines net.

#### MOD-D: Source-priority dedup tie-break in the data store (donor: PR 24)

**Problem solved:** when direct BLE and HealthKit (or WatchConnectivity) both deliver readings for the same sensor minute, the existing dedup based on readingDate alone leaves the within-1s race unresolved — whichever arrived first wins. The mission says direct BLE is the reliability path; when it's available, it should consistently win against the others.

**Caveat from ChatGPT's converge blueprint:** "must remain a thin decision rule, not a second arbitration framework." If this becomes more than ~30 lines, drop it.

**File:** `Trio Watch Shared/TrioComplicationDataStore.swift`

**Changes:** in the existing dedup logic (the function that decides whether to persist an incoming snapshot):

```swift
// Existing rule: newer readingDate wins by minInterval bucket.
// Addition: within ±1 second AND same value, higher-priority source replaces.

private func sourcePriority(_ source: TrioComplicationDataSource?) -> Int {
    switch source {
    case .g7DirectBLE: return 3
    case .watchConnectivity: return 2
    case .healthKit: return 1
    case .none, .unknown: return 0
    }
}

// In the dedup decision:
let dt = new.readingDate.timeIntervalSince(existing.readingDate)
if dt > 1.0 { return /* replace */ }
if dt < -1.0 { return /* keep existing */ }
let sameValue = (existing.glucose == new.glucose
                && existing.trend == new.trend)
if sameValue && sourcePriority(new.source) > sourcePriority(existing.source) {
    return /* replace */
}
return /* default keep-newer */
```

Net additional code: ~15 lines including the helper function. Within the "thin decision rule" budget.

#### MOD-E: `registerForConnectionEvents` as additional attach trigger (donor: PR 24)

**Problem solved:** when the Dexcom watch app reconnects to its sensor after a brief drop (BLE interference, sensor cycling, etc.), Trio's observer would normally wait for the next reconnect-backoff timer to fire before retrying the attach ladder. `registerForConnectionEvents` lets watchOS notify Trio immediately when a peripheral matching the registered services becomes connected. Free reliability win for sustained delivery.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Changes:**
- After `central.scanForPeripherals(...)` in `startScanning(reason:)`:

```swift
centralManager.registerForConnectionEvents(options: [
    CBConnectionEventMatchingOption.serviceUUIDs: [
        G7BLEUUID.advertisement,
        G7BLEUUID.dataService
    ]
])
```

- Add the delegate method:

```swift
func centralManager(
    _ central: CBCentralManager,
    connectionEventDidOccur event: CBConnectionEvent,
    for peripheral: CBPeripheral
) {
    log("event=g7_ble_connection_event peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") event=\(event == .peerConnected ? "peer_connected" : "peer_disconnected")")
    // When the Dexcom watch app (re)connects to its sensor, retry the
    // attach ladder — retrieval will now find the peripheral.
    if event == .peerConnected, !isHardStopped {
        startOrResume(reason: "connection_event_peer_connected")
    }
}
```

Net additional code: ~15 lines including registration and delegate handler.

### Optional modification: better session-outcome categorization (PR 30)

PR 29 already emits `g7_ble_session_outcome` with `outcome=` and `final_stage=`. PR 30 adds more diagnostic categorization (success / failure / incomplete / cancelled / timeout). Consider tightening PR 29's existing logic to use the same vocabulary so BetterStack queries can compare apples-to-apples across implementations. Low priority; do this only if it's <10 lines of change in `emitSessionOutcome`.

### Pieces explicitly rejected

- **PR 26 cadence** (Bug F1): one-shot.
- **PR 26 parser** (Bug F2): wrong epoch.
- **PR 25 parser** (Bug F3): wrong byte offsets.
- **PR 24 strict `authenticated && bonded` only auth gate** (no fallback): too stall-prone.
- **PR 24 targeted service discovery**: matches the failed prior Trio pattern.
- **PR 26 `nil` central queue**: PR 29's dedicated serial queue is safer.
- **PR 30 entire base**: more code to maintain during debug iteration; donor mechanics are surgical anyway.
- **PR 30 no-scan-timeout design** (see Phase 3): PR 29's guarded version is correct, costs nothing to keep, and recovers from a real failure mode that no-timeout doesn't.

---

## Phase 5: Compatibility analysis

### Composable cleanly

- **MOD-A multi-trigger cadence + PR 29 base.** PR 29's auth handler is already re-entrant and the request timer is already cancellable. The retry-on-write-failure adds a new counter but no state-machine changes.
- **MOD-B auth gate change + PR 29 base.** Single conditional change in `handleAuthPayload`. The fallback timer already exists.
- **MOD-C activation anchor + PR 29 parser.** Local change in `parseGlucose`. No external dependencies.
- **MOD-D source-priority dedup + PR 29 store extension.** Adds rule in store, doesn't touch observer. Lives in `TrioComplicationDataStore.swift`.
- **MOD-E `registerForConnectionEvents` + PR 29 base.** New delegate method, new call after scan. PR 29's `startOrResume` is the right re-entry point.

### Needs careful integration

- **MOD-A retry path interacts with MOD-B auth gate.** If auth gate is strict and write fails, the retry will fail too. Retry budget (3 per cycle) + reconnect on write failure is the safety net — the budget exhausted state should escalate to reconnect. Verify in the retry path: after 3 failed retries, call `scheduleReconnect(reason: "control_write_retries_exhausted")`.

### No real conflicts

The 5 modifications were chosen specifically because they're orthogonal. Each touches a different code area:
- A: cadence/timer logic
- B: auth handler conditional
- C: parser local
- D: data store dedup
- E: scan/delegate hookup

---

## Phase 6: Concrete implementation plan

### Branch
`feature/watch-g7-direct-ble-observer-synthesis`.

###  PR 29's commits
PR 29's commits are already in the branch.

### Apply MOD-A through MOD-E as separate commits
One per modification. Commit messages cite the donor PR:
- `MOD-A: multi-trigger EGV cadence with control-write retry (donor: PR 30)`
- `MOD-B: prefer-strict auth gate with permissive fallback (donor: PR 30)`
- `MOD-C: anchor activation date per cycle to fix sub-second drift (donor: PR 30)`
- `MOD-D: source-priority dedup tie-break in TrioComplicationDataStore (donor: PR 24)`
- `MOD-E: registerForConnectionEvents as additional attach trigger (donor: PR 24)`

### Update design doc
Create v2 of `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` documenting:
- Synthesis decisions and provenance
- Why PR 29 is the base
- Why PR 29's guarded scan timeout is preserved (Phase 3)
- The 5 modifications, by name and donor

### Verify before flashing
- `nameMatchesG7` accepts nil from retrieval paths (PR 29 already does this — no work needed).
- The cadence change replaces `60s` with `330s` and adds the auth-transition trigger.
- Auth advance gate flips from `if authenticated` to `if authenticated && bonded`.
- Activation date is anchored per cycle.
- Source-priority dedup composes with existing `minInterval: 5` behavior.
- `connectionEventDidOccur` calls `startOrResume` only on `.peerConnected` and only when not hard-stopped.

### Flash to device, observe BetterStack
Look for:
- `g7_ble_session_outcome` distribution: success / failure / incomplete ratio
- `g7_ble_egv_request_sent reason=auth_transition` vs `reason=fallback_timer_330s` — which trigger actually fires more?
- `g7_ble_connection_event` events: does `registerForConnectionEvents` actually fire on watchOS? (Open question.)
- `g7_ble_scan_stopped reason=timeout` events: how often does the scan timeout fire vs successful attach?

---

## Phase 7: Open questions to resolve on device

1. **Auth-challenge observation rate.** Does the sensor emit auth challenges to our observer subscriber regularly, or are we always falling back to the timer? If always timer, the strict gate is dead code and we should simplify to the permissive path with timer.

2. **EGV cadence trigger distribution.** If `auth_transition` always fires before `fallback_timer_330s`, the fallback is dead code. If frequently dead, simplify to auth-transition-only (which would match the sensor's natural cadence with no extra timer).

3. **`connection_event` firing on watchOS.** Documentation is silent on whether `registerForConnectionEvents` works in `CBCentralManager` on watchOS. If it doesn't fire, MOD-E is harmless dead code. If it does fire, it's a meaningful reliability boost.

4. **Scan vs retrieval success ratio.** Which `connect_attempt source=*` tag produces more `did_connect` events? If `retrieved_data_service` always wins, scan is dead code. If `scan` always wins, retrieval is broken.

5. **Source-priority dedup impact.** Does MOD-D actually change observable behavior? If BLE and HK never race (e.g. HK is always 30+ seconds late), the rule is dead code. If they regularly race, the rule resolves real ambiguity.

These are diagnostic signals to look for in the first 24h of operation. Not blockers for the first flash.

---

## Phase 8: What this synthesis does not address

- **`WKExtendedRuntimeSession`:** all 5 implementations skipped this. Synthesis preserves that — foreground-active is the baseline.
- **Backfill data forwarding:** PR 30 parses backfill but doesn't store. PR 29 logs only. Synthesis matches PR 29 (log only). Future enhancement once live EGV delivery is proven.
- **iPhone-bridged peripheral filter:** all 5 chose standalone matching. Synthesis preserves that.
- **Comparison against the broken incumbent:** Phase 2 of the overall workflow. Once this synthesis is implemented and the first device test happens, do a delta analysis against the existing failed implementation.

---

## Summary

**Base:** PR 29.

**Modifications (5):**
- MOD-A: multi-trigger EGV cadence with control-write retry (PR 30)
- MOD-B: prefer-strict auth gate with permissive fallback (PR 30)
- MOD-C: anchor activation date per cycle (PR 30)
- MOD-D: source-priority dedup tie-break in TrioComplicationDataStore (PR 24)
- MOD-E: `registerForConnectionEvents` as additional attach trigger (PR 24)

**Net result:** PR 29's clean state model, scene discipline, and reconnect properties, plus the four pieces from PR 30 that materially improve sustained-delivery reliability and log quality, plus two pieces from PR 24 that close concrete gaps. Approximate final size: ~1100 swift LoC (PR 29's 972 + ~150 net additions).

The composite is small enough to debug iteratively, mechanically robust enough to deliver sustained EGV reads, and observable enough that the first device test will produce useful BetterStack signal regardless of outcome.

This is the artifact to either implement directly or hand to another agent as a converge prompt.
