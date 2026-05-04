# Build 190 — Implementation Plan (v1.0)

## 1. Document metadata

| Field | Value |
|---|---|
| Title | Build 190 — Implementation Plan |
| Version | 1.0 |
| Timestamp | 2026-05-01 16:00 CET |
| Baseline | Build 189 codebase (feature/watch-g7-direct-ble-observer-synthesis); first step is a hard reset of G7DirectBLEObserver.swift to the 185-tagged commit |
| Target build | 190 |
| Branch | `feature/watch-g7-direct-ble-observer-synthesis` |
| Status | Implementation-ready |
| Predecessor | Build 185-deux plan v3.1 — this is the additive build on top of confirmed-working 185 baseline |

## 2. Evidence summary

**Build 185 soak results (2026-04-28 04:38 → 2026-05-01 15:47, ~83 hours):**

| Metric | Count | Notes |
|---|---|---|
| Sessions (outcome rows) | 563 | ~2× WatchLogger duplication; ~280 unique |
| Successes | 23 | ~11-12 unique EGVs |
| `0x05` received | 24 | Tracks successes 1:1 |
| CB `peer_connected` events | **91** | **All on April 28 only — zero on days 2-4** |
| `discoveringServices` hangs | 177 | ~88 unique; avg 279s each |
| EGV rate (unique sessions) | ~4-8% | Below 185-initial's ~11.7% |

**The critical finding from the soak:** CB connection events (`registerForConnectionEvents`) fired 91 times on the first app process lifetime (April 28, 04:38–09:30 UTC) then stopped completely for the remaining 80 hours. This is a direct consequence of build 185 only registering inside `connect()` with no registration in `centralManagerDidUpdateState(.poweredOn)`. When the process restarts — which watchOS does regularly — the registration is lost and never recovers. Every EGV in the soak came from the window when CB events were alive. The subsequent coverage collapse is entirely explained by this single missing registration site.

**Build 185 happy-path sequence (confirmed working, must be preserved):**
```
auth_payload_received opcode=0x03   ← Dexcom app's auth-init (broadcast)
auth_payload_received opcode=0x05 authenticated=true bonded=true  ← sensor status
control_notify_enable_requested reason=auth_authenticated_bonded
egv_request_sent payload=4e
egv_received glucose=N sequence=N
```
Every `0x05` observation produced an EGV. Zero protocol failures on the happy path across 83 hours. The passive observer contract is sound.

## 3. What build 190 adds

Nine items, additive against the 185 protocol path. None alter how the auth or EGV sequence works.

Items 1-8 are the primary build. Item 9 (notification flag removal) ships in the same binary given the soak has confirmed the protocol path.

## 4. Items, with code-level specs

### Item 0 — Hard reset `G7DirectBLEObserver.swift` to build 185

**Why.** The current codebase is build 189 on branch `feature/watch-g7-direct-ble-observer-synthesis`. Items 1-9 are additive against the 185 protocol path. The first step is to revert the file to the known-good 185 commit, discarding all 186-189 changes to that file.

**Action.**
```bash
git checkout <185-commit-sha> -- "Trio Watch App Extension/G7DirectBLEObserver.swift"
```

**Verify.** Confirm the following are absent (per §6 Tier 0 invariants): Option C block, `scheduleObservingAuthStageTimeout`, 290s post-EGV backoff, `discovery_skipped` short-circuit. Confirm `willRestoreState` eager-attaches connected peripherals and `registerForConnectionEvents` is called in `connect()`.

**This is its own commit.** See §N (commit strategy).

### Item 1 — Session generation tagging (foundational)

**Why.** Stale `DispatchWorkItem` callbacks — delayed timers, discovery continuations, disconnect handlers — can fire for a long-dead session and interact incorrectly with a live one. Every async edge needs a generation identity check. This underpins Items 3 and 5.

**Add property.**
```swift
/// Incremented on every new session anchor (didConnect + willRestoreState connected path).
/// Captured at schedule time by all deferred work items; checked at execution time.
private var currentSessionGeneration: UInt64 = 0
```

**Bump sites (exactly two):**

1. In `centralManager(_:didConnect:)`, before `discoverServicesIfNeeded`:
```swift
currentSessionGeneration &+= 1
log("event=g7_ble_session_generation_bumped new_gen=\(currentSessionGeneration) reason=did_connect peripheral_id=\(peripheral.identifier.uuidString)")
```

2. In `centralManager(_:willRestoreState:)`, inside the `peripheral.state == .connected` branch, after `activePeripheral = peripheral`, before `discoverServicesIfNeeded`:
```swift
currentSessionGeneration &+= 1
log("event=g7_ble_session_generation_bumped new_gen=\(currentSessionGeneration) reason=restore_state peripheral_id=\(peripheral.identifier.uuidString)")
```

**Apply generation checks to all async edges:**

Every site that calls `authFallbackWorkItem?.cancel()` must first emit a cancel log:
```swift
if authFallbackWorkItem != nil {
    log("event=g7_ble_auth_fallback_cancelled reason=\(reason) gen=\(currentSessionGeneration)")
    authFallbackWorkItem?.cancel()
    authFallbackWorkItem = nil
}
```

The auth fallback work item closure must check generation:
```swift
let gen = currentSessionGeneration
let workItem = DispatchWorkItem { [weak self] in
    guard let self else { return }
    guard self.currentSessionGeneration == gen else {
        self.log("event=g7_ble_auth_fallback_skipped reason=stale_gen scheduled_gen=\(gen) current_gen=\(self.currentSessionGeneration)")
        return
    }
    guard !self.hasAdvancedBeyondAuth else {
        self.log("event=g7_ble_auth_fallback_skipped reason=already_advanced gen=\(gen)")
        return
    }
    self.log("event=g7_ble_auth_fallback reason=no_status_reply delay_s=\(Int(self.authFallbackDelay)) gen=\(gen)")
    self.advanceToControl(reason: "auth_fallback_no_status_reply")
}
```

Same generation-capture pattern applies to: `scheduleReconnect` work item, `reconnectWorkItem`.

**All async callbacks (didDiscoverServices, didDiscoverCharacteristics, didUpdateNotificationStateFor, didWriteValueFor, didDisconnectPeripheral) should log `gen=\(currentSessionGeneration)` on entry** so every event in the log is attributable to a specific session.

**Acceptance.** `g7_ble_session_generation_bumped` appears on every connect and connected-restore. Every fallback produces exactly one outcome log: `g7_ble_auth_fallback`, `g7_ble_auth_fallback_skipped`, or `g7_ble_auth_fallback_cancelled`. No silent timer disappearances.

---

### Item 2 — MOD-E registration hardening

**Why.** Build 185 registers `registerForConnectionEvents` inside `connect()` only. On process restart, a new `CBCentralManager` goes through `centralManagerDidUpdateState(.poweredOn)` — but at that point `connect()` hasn't been called yet, so registration doesn't happen. CB connection events stop firing until the next `connect()` call, which may be seconds or minutes later — by which time the sensor window has already passed. The soak confirmed: 91 CB events on day 1, **zero for the next 80 hours** across multiple process restarts.

**Change.** Add to `centralManager(_:didUpdateState:)` in the `.poweredOn` case, **before** any attach-ladder logic:

```swift
case .poweredOn:
    centralManager.registerForConnectionEvents(options: [
        CBConnectionEventMatchingOption.serviceUUIDs: [
            G7BLEUUID.advertisement,
            G7BLEUUID.dataService
        ]
    ])
    log("event=g7_ble_connection_events_registered reason=powered_on")
    // ... existing poweredOn handling continues
```

Keep the existing call inside `connect()` as well — belt and suspenders, idempotent with identical options.

**Acceptance.** `g7_ble_connection_events_registered reason=powered_on` appears once per process lifetime, within seconds of launch. `g7_ble_connection_event peer_connected` events appear continuously across process restarts, not only during the first app lifetime.

**Risk.** Low. Apple's docs document re-registration as idempotent when options are unchanged. This is exactly the call that was present across 185→187 and removed in 188.

---

### Item 3 — MOD-E observability counters

**Why.** The day-1 → day-2 CB event death was only discoverable by manual BetterStack queries. A BetterStack dashboard metric (created manually in the UI: `g7_ble_cb_peer_connected`, type Sum) and the chart already added to dashboard 914638 will make this immediately visible going forward. The app side needs to emit the right log fields for that metric to capture.

**Change.** In `centralManager(_:connectionEventDidOccur:for:)`, in the `peerConnected` branch, add:

```swift
// Already emit the connection_event log line — ensure it contains peer_connected clearly
log("event=g7_ble_connection_event peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") type=peer_connected gen=\(currentSessionGeneration)")
```

Ensure the existing connection event log line uses `type=peer_connected` (not an event string with a variable value) so the BetterStack metric SQL `LIKE '%peer_connected%'` matches it reliably.

**Acceptance.** Dashboard 914638 "G7 BLE — CB Connection Events vs EGVs" chart shows CB events and EGVs on the same axis. When registration works, CB events appear every ~5 minutes. When it breaks, the chart shows the gap immediately.

---

### Item 4 — Connection-event self-loop guard

**Why.** When Trio connects to the G7, CB also fires `connectionEventDidOccur(.peerConnected)` for that same peripheral. The current code unconditionally calls `startOrResume(reason: "connection_event_peer_connected")` for every peerConnected event, triggering a redundant attach ladder for the peripheral we just connected to.

**Change.** In `centralManager(_:connectionEventDidOccur:for:)`:

```swift
if event == .peerConnected {
    if let active = activePeripheral, active.identifier == peripheral.identifier {
        log("event=g7_ble_connection_event_self_ignored peripheral_id=\(peripheral.identifier.uuidString) state=\(active.state.rawValue) gen=\(currentSessionGeneration)")
        // Fall through to the connection_event log line for auditability, but skip startOrResume
    } else if !isHardStopped {
        startOrResume(reason: "connection_event_peer_connected")
    }
}
```

**Acceptance.** After every `g7_ble_did_connect`, exactly one `g7_ble_connection_event_self_ignored` appears. `startOrResume reason=connection_event_peer_connected` no longer fires for the peripheral Trio just connected to.

---

### Item 5 — 30-second service discovery timeout, generation-checked

**Why.** 177 raw `discoveringServices/failure` sessions in the soak at an average of 279 seconds each. These are successful connects where the `didDiscoverServices` CB callback never arrives because watchOS suspends the queue. Build 185 has no timeout — the session hangs until the sensor gives up and disconnects (sometimes 10+ minutes). A 30-second timeout allows 8-9 retry attempts within the same time window, each with a fresh chance at the sensor's bonded auth window.

This requires session generation (Item 1) to be safe — a stale timeout from a prior session must not cancel a live connection.

**Add helper function:**
```swift
private var discoveryTimeoutWorkItem: DispatchWorkItem?

private func scheduleDiscoveryTimeout(for peripheral: CBPeripheral) {
    discoveryTimeoutWorkItem?.cancel()
    let gen = currentSessionGeneration
    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard self.currentSessionGeneration == gen else {
            self.log("event=g7_ble_discovery_timeout_skipped reason=stale_gen gen=\(gen) current_gen=\(self.currentSessionGeneration)")
            return
        }
        guard self.stage == .discoveringServices || self.stage == .discoveringCharacteristics else {
            self.log("event=g7_ble_discovery_timeout_skipped reason=wrong_stage stage=\(self.stage.rawValue) gen=\(gen)")
            return
        }
        self.log("event=g7_ble_discovery_timeout_fired gen=\(gen) peripheral_id=\(peripheral.identifier.uuidString)")
        self.centralManager.cancelPeripheralConnection(peripheral)
    }
    discoveryTimeoutWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 30, execute: workItem)
    log("event=g7_ble_discovery_timeout_scheduled delay_s=30 gen=\(gen)")
}
```

**Call site.** In `centralManager(_:didConnect:)`, after the generation bump, call `scheduleDiscoveryTimeout(for: peripheral)`.

**Cancel sites.** Cancel `discoveryTimeoutWorkItem` in:
- `centralManager(_:didDiscoverServices:error:)` — discovery succeeded
- `centralManager(_:didDisconnectPeripheral:error:)` — session ending
- `stop()` / `hardStop()` — teardown

**Acceptance.** `g7_ble_discovery_timeout_fired` appears within 30s of any connect that doesn't receive `didDiscoverServices`. No `discovery_timeout_fired` should appear for a session where discovery already succeeded. `g7_ble_discovery_timeout_skipped reason=stale_gen` confirms generation safety is working.

**Risk.** Low with generation check in place. Without generation check (i.e. if Item 1 is missing), a stale timeout could cancel a live session — this is exactly what made build 188's un-guarded version dangerous. The gen check is mandatory.

---

### Item 6 — Persist sensor ID on `didConnect`

**Why.** Build 185 writes `persistedPeripheralIdentifier` only inside `handleGlucose` after a successful EGV. With a ~4-8% EGV catch rate, a new sensor can take many minutes before its ID gets persisted, during which time process restarts may try to reconnect to the old sensor.

**Change.** In `centralManager(_:didConnect:)`, after the generation bump, before `discoverServicesIfNeeded`:

```swift
if persistedPeripheralIdentifier != peripheral.identifier {
    log("event=g7_ble_sensor_changed old=\(persistedPeripheralIdentifier?.uuidString ?? "nil") new=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") gen=\(currentSessionGeneration)")
    persistedPeripheralIdentifier = peripheral.identifier
}
log("event=g7_ble_peripheral_id_persisted peripheral_id=\(peripheral.identifier.uuidString) reason=did_connect gen=\(currentSessionGeneration)")
```

**Acceptance.** First time a new sensor connects, `g7_ble_sensor_changed` fires. `g7_ble_peripheral_id_persisted reason=did_connect` fires on every connect. A sensor swap no longer requires a successful EGV to persist the new ID.

---

### Item 7 — Unified session outcome log

**Why.** Post-soak analysis has required manually querying `final_stage`, `outcome`, and duration across multiple log lines. A single terminal event per session attempt — with a clear machine-readable reason code — makes the next log review materially faster and the BetterStack charts more actionable.

Build 185 already has a `g7_ble_session_outcome` log line in `emitSessionOutcome`. Extend it with:
- `gen=` the session generation
- `terminal_reason=` one of the new reason codes below

**Reason codes to add:**

| Code | When |
|---|---|
| `egv_received` | Session produced ≥1 EGV (success) |
| `auth_payload_success` | Reached control via `0x05` path but no EGV (shouldn't happen, diagnostic) |
| `auth_fallback_no_egv` | Reached control via fallback path, no EGV |
| `discovery_timeout` | Cancelled by Item 5's 30s watchdog |
| `discovery_failed` | `didDiscoverServices` returned an error |
| `auth_stall` | `observingAuth` final stage — neither `0x05` nor fallback completed |
| `connect_timeout` | Connect attempt timed out |
| `connect_failed` | `didFailToConnect` |
| `self_cancelled` | `isSelfCancelling` path (not in 185 but anticipated) |
| `stale_gen_dropped` | Work item dropped due to generation mismatch |
| `hard_stopped` | Teardown during active session |

**Change.** In `emitSessionOutcome`, derive `terminal_reason` from `finalOutcome`, `stage`, and the new generation context, then append to the existing log line:

```swift
log("event=g7_ble_session_outcome outcome=\(finalOutcome) final_stage=\(stage.rawValue) terminal_reason=\(terminalReason) duration_ms=\(duration) gen=\(currentSessionGeneration) g7_session=\(sessionID.uuidString) egv_count=\(sessionEGVCount)")
```

**Acceptance.** Every session-outcome row in BetterStack has a `terminal_reason` field. A single query on that field replaces the multi-facet `final_stage + outcome` analysis currently required.

---

### Item 8 — Option C tripwire log

**Why.** Option C (advance to control immediately on `auth_notify_enabled` callback, before `0x05` arrives) was introduced in build 188 and was the documented regression that build 189 reverted. Any future accidental reintroduction should be detectable within one session.

**Change.** In `handleAuthPayload`, after the opcode check:

```swift
if hasAdvancedBeyondAuth, opcode == G7BLEOpcode.authStatusReply.byte {
    log("event=g7_ble_auth_payload_post_advance opcode=0x\(opcode.hexByte) authenticated=\(authenticated) bonded=\(bonded) gen=\(currentSessionGeneration)")
}
```

In the happy path `0x05` arrives before we've advanced, so this fires only if something advances us prematurely. **If this log line appears with `authenticated=true bonded=true` in the same session as an advance-via-fallback or advance-via-notify, Option C has been reintroduced.**

**Acceptance.** This log line never fires in normal operation. If it appears in BetterStack on a session where `control_notify_enable_requested reason=auth_notify_enabled_observer` also appears, that is an immediate build-abort signal.

---

### Item 9 — Remove "accessory disconnected" notification

**Why.** `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true` in `connect()` causes an OS-level "accessory disconnected / Open Trio to reconnect" notification on every G7 sensor disconnect — approximately every 5-8 minutes, ~288 times per day. The flag was intentionally removed at build 187 for this reason and its removal did not affect the in-process `didDisconnectPeripheral` callback. The 83-hour soak confirms the protocol path works with the flag present; removing it for user experience is safe.

**Change.** In `connect()`, replace:
```swift
centralManager.connect(
    peripheral,
    options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
)
```
with:
```swift
centralManager.connect(peripheral, options: nil)
```

**Acceptance.** No "accessory disconnected" OS notifications during normal sensor cycle disconnects. `g7_ble_disconnect` events continue appearing in BetterStack at normal cadence — confirming the in-process callback is unaffected.

**Falsification.** If `g7_ble_disconnect` events stop appearing after this change, the flag was affecting callback delivery on watchOS contrary to Apple's docs. Revert immediately.

## 5. Items deliberately deferred

| Item | Reason | Pull forward when |
|---|---|---|
| Phase timestamp ladder + first-stamp-only fix | 185 succeeds without it; adding the ladder requires adding first-stamp-only correctness as a pair | Timing investigation needed |
| Auth fallback delay re-anchor / shortening | 185's 6s fallback worked; both successful paths in the soak came through the `0x05` route, not fallback | Soak shows fallback path producing EGVs |
| `configureObserverCharacteristics` re-entry guard | 185 doesn't have the `discovery_skipped` short-circuit that creates Bug 1's surface in 189; no speculative guard needed | Duplicate auth-notify-enable events appear in 190 logs |
| `connectInFlight` / `isDiscoveringServices` flags | 186 introduced these; 185 worked without them | Parallel-connect storms visible in logs |
| Inter-window sleep / `lastConnectionEventAt` scheduling | Big change; 185's `scheduleReconnect` worked | Reconnect cadence is hammering sensor between windows |
| Per-commit bisection 185 → 186 | Not needed if 190 restores CB event continuity | 190's EGV rate doesn't improve materially over the soak |
| Packet capture | Not needed; protocol path confirmed working | 190 produces zero `0x05` after clean soak |
| `isSelfCancelling` guard | 189-introduced pattern; not in 185 baseline | Self-cancel disorder visible in logs |

## 6. Pre-build verification (Tier 0)

Grep `G7DirectBLEObserver.swift` before tagging:

0. `git diff <185-sha> "Trio Watch App Extension/G7DirectBLEObserver.swift"` shows **only** the changes introduced by Items 1-9. No other diff lines are present. If unexpected lines appear, the revert was incomplete.
1. `scheduleObservingAuthStageTimeout` — **not present** anywhere.
2. Option C block `if characteristic.isNotifying, !hasAdvancedBeyondAuth { authFallbackWorkItem?.cancel(); advanceToControl(reason: "auth_notify_enabled_observer") }` — **absent** from `handleNotificationState`.
3. 290s `postEGVBackoffWorkItem` — **absent** from `didDisconnectPeripheral`.
4. `discovery_skipped reason=already_discovered` short-circuit — **absent** from `discoverServicesIfNeeded`.
5. `centralManager.connect(peripheral, options: nil)` — **present** (notification flag removed per Item 9).
6. `centralManager.registerForConnectionEvents` call — **present in both** `centralManagerDidUpdateState(.poweredOn)` (Item 2) and `connect()` (existing).
7. `willRestoreState` eager-attach for `.connected` restored peripherals — **present** (185 baseline).
8. `authFallbackDelay = 6` — **present** (185 value, unchanged).
9. `currentSessionGeneration` property and both bump sites — **present** (Item 1).
10. `scheduleDiscoveryTimeout` — **present and called from `didConnect`** (Item 5).
11. Option C tripwire log in `handleAuthPayload` — **present** (Item 8).

If any of 1–4 reappear or 5–11 are missing, do not tag.

## 7. Implementation order

Land in this order. Item 0 is its own commit. Items 1-9 are a second commit (see §N).

**Commit 1 — Revert to 185 baseline:**
- Item 0: `git checkout <185-sha> -- "Trio Watch App Extension/G7DirectBLEObserver.swift"`

**Commit 2 — All additive changes:**
1. Item 1 — Session generation (foundational; all others depend on it)
2. Item 2 — MOD-E registration in `.poweredOn` (highest-yield fix)
3. Item 8 — Option C tripwire log (one-liner; add early)
4. Item 4 — Connection-event self-loop guard
5. Item 5 — 30-second discovery timeout (requires Item 1)
6. Item 6 — Persist sensor ID on `didConnect`
7. Item 3 — MOD-E observability log field alignment
8. Item 7 — Unified session outcome terminal reasons
9. Item 9 — Remove `CBConnectPeripheralOptionNotifyOnDisconnectionKey`

### N. Commit strategy

**Two commits, one build.**

**Commit 1 — `revert: reset G7DirectBLEObserver.swift to build 185 baseline`**

Just the file revert. Nothing else. Keeps the revert as a clean, identifiable point in history. If Items 1-9 somehow introduce a regression, `git revert HEAD` on commit 2 gets back to clean 185 without losing the revert.

**Commit 2 — `feat(watch-g7): build 190 — MOD-E hardening, session generation, discovery timeout`**

All of Items 1-9 together. Rationale: they're all additive changes to a single file, they ship in a single TestFlight build, and they've all been reviewed together as a unit. Splitting them into 9 commits would make the history noisy without improving causal attribution — any build 190 regression would be diagnosed via BetterStack logs (which now carry `gen=`, `terminal_reason=`, and the full outcome taxonomy), not via bisection of individual items.

**Exception:** if any item fails Tier 0 verification, fix it in the same commit 2 rather than adding a patch commit on top. The build should not be tagged until commit 2 passes all §6 invariants.

## 8. Logging additions

| Event | Trigger | Fields |
|---|---|---|
| `g7_ble_session_generation_bumped` | Item 1 — gen increment | `new_gen`, `reason`, `peripheral_id` |
| `g7_ble_auth_fallback_skipped` | Item 1 — stale gen or already advanced | `reason`, `scheduled_gen`, `current_gen` (or `gen`) |
| `g7_ble_auth_fallback_cancelled` | Item 1 — fallback cancel site | `reason`, `gen` |
| `g7_ble_connection_events_registered` | Item 2 — registration call | `reason` (`powered_on` or `connect`) |
| `g7_ble_connection_event_self_ignored` | Item 4 — own peripheral suppressed | `peripheral_id`, `state`, `gen` |
| `g7_ble_discovery_timeout_scheduled` | Item 5 — timeout armed | `delay_s`, `gen` |
| `g7_ble_discovery_timeout_fired` | Item 5 — timeout executed | `gen`, `peripheral_id` |
| `g7_ble_discovery_timeout_skipped` | Item 5 — stale gen or wrong stage | `reason`, `gen`, `current_gen`, `stage` |
| `g7_ble_sensor_changed` | Item 6 — identifier change on connect | `old`, `new`, `name`, `gen` |
| `g7_ble_peripheral_id_persisted` | Item 6 — ID written | `peripheral_id`, `reason`, `gen` |
| `g7_ble_auth_payload_post_advance` | Item 8 — Option C tripwire | `opcode`, `authenticated`, `bonded`, `gen` |
| `g7_ble_session_outcome` (extended) | Item 7 — terminal event | existing fields + `terminal_reason`, `gen` |

All existing `g7_ble_*` events in the critical path should have `gen=` appended.

## 9. BetterStack dashboard - COMPLETED

Chart "G7 BLE — CB Connection Events vs EGVs" has been added to dashboard 914638 (chart ID 12497699983). It requires two metrics to be created manually in the BetterStack UI (**Sources → Trio → Metrics → New Metric**):

**Metric 1 — `g7_ble_cb_peer_connected` (Sum)**
```sql
if(JSONExtractString(raw, 'message') LIKE '%g7_ble_connection_event%peer_connected%', 1, NULL)
```

**Metric 2 — `g7_ble_egv_received` (Sum)**
```sql
if(JSONExtractString(raw, 'message') LIKE '%g7_ble_egv_received%' AND JSONExtractString(raw, 'message') NOT LIKE '%dedup_skipped%', 1, NULL)
```

Note: metrics are not retroactive. They will begin capturing from creation time forward.

## 10. Success criteria

| Tier | Criterion | How to verify |
|---|---|---|
| Tier 0 | All §6 pre-build invariants pass | Grep before tagging |
| Tier 1 (within 2h) | `g7_ble_connection_events_registered reason=powered_on` appears after each process restart | BetterStack log query |
| Tier 1 (within 2h) | `g7_ble_connection_event type=peer_connected` events appear continuously — not limited to first process lifetime | Dashboard 914638 chart |
| Tier 1 (within 2h) | `g7_ble_session_generation_bumped` appears on every connect | Log query |
| Tier 1 (within 2h) | `auth_payload_received opcode=0x05` appears within first ~25 protocol-reaching sessions | Log query |
| Tier 2 (24h soak) | CB peer_connected events fire across multiple process restarts with no gaps longer than 15 min | Dashboard chart |
| Tier 2 (24h soak) | `g7_ble_discovery_timeout_fired` events appear (confirms Item 5 is working on hung sessions) | Log query |
| Tier 2 (24h soak) | Discovery hang average duration < 35s (down from 279s) | `avg(duration_ms) WHERE final_stage=discoveringServices` |
| Tier 3 (24h soak) | `egv_received` rate ≥ 10% of protocol-reaching sessions | Success/session ratio |
| Tier 3 (24h soak) | No overnight gap > 2 hours (was 9-10h in 185 soak) | EGV sequence gap analysis |
| Abort | `g7_ble_auth_payload_post_advance` appears with `authenticated=true bonded=true` AND same session shows `reason=auth_notify_enabled_observer` advance | Immediate revert |

## 11. Falsification

| Outcome | Implication | Next step |
|---|---|---|
| Tier 1 fails — `connection_events_registered reason=powered_on` not in logs | Item 2 didn't land in the right code path | Verify `centralManagerDidUpdateState` case `.poweredOn` is correct; check for Swift switch fallthrough |
| Tier 1 passes but CB peer_connected still dies after first process lifetime | Registration isn't sticking across restarts despite the `.poweredOn` call | Add registration in `applyForegroundActiveEntry` as an additional recovery site |
| Tier 2 passes but Tier 3 EGV rate < 10% | CB events working but something else is limiting yield | Analyse terminal_reason breakdown from Item 7's unified outcome log |
| Discovery timeouts fire but sessions still hang > 30s | `centralManager.cancelPeripheralConnection` isn't taking effect quickly; CB may queue the cancel | Log time between timeout fire and `didDisconnectPeripheral`; consider a secondary force-reset |
| `g7_ble_disconnect` events stop appearing after Item 9 (notification flag removal) | Flag affects in-process callback delivery on watchOS contrary to docs | Revert Item 9; re-add the flag |
| Option C tripwire (`auth_payload_post_advance authenticated=true`) fires | Option C has been reintroduced somewhere | **Abort build; identify and remove the advance-on-notify code path before re-shipping** |
| All tiers pass | Build 190 is solid baseline | Plan next round — WKExtendedRuntimeSession or complication-driven wake for overnight coverage |

## 12. Open questions

1. Will CB connection events remain alive across process restarts with the `.poweredOn` registration added? The soak will tell us definitively within 2 hours.
2. Does `centralManager.cancelPeripheralConnection` return fast enough in background to make the 30s discovery timeout effective, or does the cancel itself get suspended? Detectable from the gap between `discovery_timeout_fired` and `didDisconnectPeripheral`.
3. The overnight gap (9-10h of near-zero EGVs despite adequate battery) is not addressed by this build. If CB events fire continuously, does overnight coverage materially improve? Or does watchOS still throttle BLE connects even with events firing? This will be the primary question after the Tier 3 soak.

## 13. Change log

| Version | Timestamp | Author | Changes |
|---|---|---|---|
| 1.0 | 2026-05-01 20:28 CET | Charlie Chrisman | Initial build 190 plan. Synthesizes: (a) 83-hour build 185 soak evidence (23 EGVs, 91 CB events all on day 1 then zero, 177 discovery hangs); (b) v3.1 build 185-deux plan; (c) ChatGPT review feedback rounds 1-3; (d) full 185→186→187→188→189 diff analysis; (e) BetterStack dashboard additions. Nine items: session generation (foundational), MOD-E `.poweredOn` registration (highest-yield fix for CB event death), MOD-E observability, self-loop guard, 30s generation-checked discovery timeout, sensor ID on didConnect, unified session outcome log, Option C tripwire, notification flag removal. Primary evidence basis: CB peer_connected events fired 91× on April 28 then zero for 80 hours — directly attributable to 185's missing `.poweredOn` registration site and confirmed as the root cause of the soak's coverage collapse. **Corrections (2026-05-01):** Branch corrected to `feature/watch-g7-direct-ble-observer-synthesis`. Baseline clarified as build 189 codebase with an explicit hard-revert step (Item 0) as the first commit. §9 BetterStack removed — metrics already created in UI and chart already live on dashboard 914638. Commit strategy section added. |