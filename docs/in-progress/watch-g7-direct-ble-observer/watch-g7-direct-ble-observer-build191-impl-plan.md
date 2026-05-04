# Build 191 — Implementation Plan (v1.7)

## 1. Document metadata

| Field | Value |
|---|---|
| Title | Build 191 — Implementation Plan |
| Version | 1.7 |
| Timestamp | 2026-05-02 19:00 CET |
| Branch | `feature/watch-g7-direct-ble-observer-synthesis` |
| Baseline | Build 190 (`G7DirectBLEObserver.swift` @ `d6f9cce87`) |
| Target build | 191 |
| Status | Implementation-ready |

## 2. What build 191 is

A **correctness, timing, and scheduling build.** It fixes correctness gaps in CB callback handling, restores hygiene guards lost in the 185 rollback, replaces exponential backoff with a two-mode deterministic scheduler, and tightens timing constants. It also changes post-success runtime behavior: after a successful EGV and disconnect, the scheduler calls `scheduleNextAttempt(reason: "post_egv_disconnect")` — a 2s fast retry — rather than the prior exponential backoff. Inter-window sleep (H2) is deferred to build 192 and replaces this specific post-success path when it ships.

It does not introduce inter-window sleep (H2) or the CB fast-path connect (D); those are deferred to build 192.

**Feature branch commits:** All 10 commits in this build touch only `Trio Watch App Extension/G7DirectBLEObserver.swift` and are isolated for attribution.

**Prerequisite (outside this branch):** The `06-cloud-logging.patch` cloud logging dedup fix is developed in `feature/cloud-logging` and regenerated before build 191 work begins. After it ships and a midnight rotation occurs, counts for duplicated watch-log events should drop by roughly half — not a regression.

## 3. State machine

```
                    ┌──────────────────────────────────────────────────────┐
                    │              CB peer_connected                       │
                    │         (interrupts any non-WINDOW_ACTIVE state)     │
                    └─────────────────────┬────────────────────────────────┘
                                          │
        ┌────────┐  foreground/powered_on ▼
        │  IDLE  │ ──────────────────► RETRIEVING
        └────────┘                        │
             ▲               ┌────────────┤
             │               │ retrieve   │ not found
             │               │ connected  ▼
         hard│               │       SCANNING ──(15s timeout)──┐
         stop│               │           │                     │
             │               │  found    │ found               │ fail
             │               └──────┐    │                     │
             │                     ▼    ▼                      │
             │                   CONNECTING ◄──────────────────┘
             │                   (8s timeout)
             │                        │ didConnect
             │                        ▼
             │                  WINDOW_ACTIVE
             │          (15s discovery watchdog)
             │                        │
             │        ┌───────────────┤
             │        │ 0x05 or 2s    │ failure or
             │        │ fallback      │ post-success disconnect
             │        │               ▼
             │        │          FAST_RETRY ──(×5)──► MODERATE_WAIT
             │        │          (2s fixed)            (15s fixed)
             │        │               ▲                     │
             │        │               └─────────────────────┘
             │        │          (after moderate wait)
             │        │ EGV received + disconnect [Build 191]
             │        ├──────────────────────────────────────► FAST_RETRY (2s)
             └────────┴──────────────────────────────────► [Build 192]
                                                      INTER_WINDOW_SLEEP
```

### States

| State | Code stage | Description |
|---|---|---|
| IDLE | `.idle` | Waiting; no active session or timer |
| RETRIEVING | `.retrieving` | Attach ladder: checking OS peripheral cache |
| SCANNING | `.scanning` | Active BLE scan; no cached peripheral found |
| CONNECTING | `.connecting` | `centralManager.connect()` in flight; 8s timeout |
| WINDOW_ACTIVE | `.discoveringServices` `.discoveringCharacteristics` `.observingAuth` `.enablingControl` `.requestingEGV` `.receivingEGV` | Inside a live sensor session; 15s discovery watchdog running |
| FAST_RETRY | `.idle` + `schedulerMode=.fastRetry` | Entered after failure **or post-success disconnect**; 2s fixed delay; no backoff |
| MODERATE_WAIT | `.idle` + `schedulerMode=.moderateWait` | 5 consecutive scheduler retries since last EGV; 15s fixed delay; counter reset |

### Generation semantics

`currentSessionGeneration` increments only on `didConnect` and the `willRestoreState` connected path. Retries scheduled before the first successful connect intentionally share the same generation; a new generation begins only once a connect succeeds. `cancelTransientTimers()` at the start of every `scheduleNextAttempt` cancels the previous reconnect work item before scheduling a new one, ensuring only one outstanding reconnect at any time. The stale-gen guard on reconnect work items protects against a delayed work item firing after a new session has started.

## 4. Lifecycle ownership rules

### 4.1 `connectInFlight`

| Event | Action | Note |
|---|---|---|
| `connect()` called | Set `true` | Only set site |
| `didConnect` — matching peripheral | Clear `false` | Normal success |
| `didConnect` — mismatched peripheral | **DO NOT clear** | Active connect still in flight |
| `didFailToConnect` — matching peripheral | Clear `false` | |
| `didFailToConnect` — mismatched peripheral | DO NOT clear | |
| Connect timeout fires → `cancelPeripheralConnection` | **Clear `false` before cancelling** | See note below |
| `didDisconnectPeripheral` — matching peripheral | Clear `false` if set (idempotent) | See note below |
| `hardStopOnQueue` | Clear `false` | |

**Connect timeout note:** After the timeout fires and `cancelPeripheralConnection` is called, CB is expected to deliver `didDisconnectPeripheral` or `didFailToConnect` for the matching peripheral. However, if CB fails to deliver either callback in an edge case, leaving `connectInFlight = true` would permanently wedge future connects. Defensively clear `connectInFlight = false` in the connect timeout closure before calling `cancelPeripheralConnection`, accepting the small risk of a redundant clear in `didDisconnectPeripheral`.

**Disconnect note:** `didDisconnectPeripheral` clears `connectInFlight` if set. During a live non-connecting session this clear is semantically unnecessary but harmless — treat as idempotent cleanup.

Never cleared in mismatch guard early-return paths.

### 4.2 `isDiscoveringServices`

| Event | Action |
|---|---|
| `discoverServicesIfNeeded` first call | Set `true` |
| `hardStopOnQueue` / teardown | Clear `false` |
| `didDisconnectPeripheral` (matching) | Clear `false` |
| `didFailToConnect` (matching) | Clear `false` — defensive cleanup; discovery should not have started if connect failed, but clearing is harmless |
| Mid-session phase transitions | **Never clear** |

### 4.3 Timer ownership

Cancelled by `cancelTransientTimers()`:
- `authFallbackWorkItem`, `discoveryTimeoutWorkItem`, `connectTimeoutWorkItem`, `scanTimeoutWorkItem`, `egvRequestWorkItem`, `controlWriteRetryWorkItem`

**Not** in `cancelTransientTimers` — must be cancelled explicitly:
- `reconnectWorkItem` — cancelled by `cancelReconnect()` and at the start of `scheduleNextAttempt`

### 4.4 `fastRetryCount`

Tracks **consecutive scheduler retries since last EGV** — not purely consecutive failures. Failures increment it; post-success disconnect also starts a new retry streak from 1 after the EGV reset.

| Event | Action |
|---|---|
| Retry enters `scheduleNextAttempt` (failure or post-success disconnect) | Increment before mode selection |
| Count ≥ 5 (checked after increment) | Reset to 0; schedule moderate wait; log `countAtDecision=5` |
| EGV received in `handleGlucose` | Reset to 0 |
| Hard stop | No reset needed |

`fastRetryCount` does **not** reset on `didConnect`. A session that connects but fails to deliver an EGV is not a success and does not reset the counter.

## 5. Changes, in commit order

**Prerequisite:** The BetterStack log deduplication fix (`CloudLogUploader.uploadRotatingPair()`) is delivered via `feature/cloud-logging` and will be reflected in `06-cloud-logging.patch` before any build 191 work begins. No action required in this branch.

### Change 1 — Peripheral-identity guards in CB callbacks

**State machine role:** Prevents phantom state transitions from stale or mismatched CB callbacks during restore/cancel races.

Not a newly discovered issue — flagged in earlier static review as optional hardening. Promoted to in-scope correctness guard because it is cheap and protects all subsequent changes.

```swift
// didConnect
guard peripheral.identifier == activePeripheral?.identifier else {
    log("event=g7_ble_did_connect_ignored reason=peripheral_mismatch peripheral_id=\(peripheral.identifier.uuidString) gen=\(currentSessionGeneration)")
    // DO NOT clear connectInFlight — active connect still in flight
    return
}

// didFailToConnect
guard peripheral.identifier == activePeripheral?.identifier else {
    log("event=g7_ble_did_fail_to_connect_ignored reason=peripheral_mismatch peripheral_id=\(peripheral.identifier.uuidString) gen=\(currentSessionGeneration)")
    return
}

// didDisconnectPeripheral
guard peripheral.identifier == activePeripheral?.identifier else {
    log("event=g7_ble_disconnect_ignored reason=peripheral_mismatch peripheral_id=\(peripheral.identifier.uuidString) gen=\(currentSessionGeneration)")
    // DO NOT cancel any timers — active session timers stay running
    return
}
```

### Change 2 — `connectInFlight` guard

**State machine role:** Prevents CONNECTING re-entry.

Build 190 logs show duplicate simultaneous `attach_ladder_start` and `connect_attempt` events at startup. The complete set of clear points in §4.1 must be implemented together or this guard can wedge future connects.

```swift
private var connectInFlight = false

// Top of connect():
guard !connectInFlight else {
    log("event=g7_ble_connect_skipped reason=already_connecting source=\(source) gen=\(currentSessionGeneration)")
    return
}
connectInFlight = true
```

In `scheduleConnectTimeout`, the closure must clear `connectInFlight = false` **before** calling `centralManager.cancelPeripheralConnection(peripheral)` as a defensive measure against missed CB callbacks:

```swift
self.connectInFlight = false
self.pendingTerminalReason = "connect_timeout"
self.log("event=g7_ble_connect_failed reason=timeout peripheral_id=\(id.uuidString) gen=\(self.currentSessionGeneration)")
self.centralManager.cancelPeripheralConnection(peripheral)
```

### Change 3 — `isDiscoveringServices` gate

**State machine role:** Prevents discovery re-entry within WINDOW_ACTIVE.

Without this flag, `resume_connected` or a stale CB callback can call `discoverServicesIfNeeded` on an already-discovering peripheral. The complete set of clear points in §4.2 must be implemented together.

```swift
private var isDiscoveringServices = false

// Top of discoverServicesIfNeeded():
guard !isDiscoveringServices else {
    log("event=g7_ble_discovery_skipped reason=already_in_progress peripheral_id=\(peripheral.identifier.uuidString) gen=\(currentSessionGeneration)")
    return
}
isDiscoveringServices = true
```

### Change 4 — `retrieveConnectedPeripherals` first in `beginAttachLadder`

**State machine role:** RETRIEVING → CONNECTING without scan for non-CB-triggered ladders.

Before the stored-identifier lookup, call `retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])`. Logs `source=retrieved_data_service` to distinguish from `source=retrieved_identifier`. Scan remains a valid fallback — build 190 had zero scan-based attempts, but that reflects current conditions, not an invariant.

```swift
private func beginAttachLadder(reason: String) {
    stage = .retrieving
    noteStatus(.searching)
    log("event=g7_ble_lifecycle action=attach_ladder_start reason=\(reason) gen=\(currentSessionGeneration)")

    // 1. OS-connected peripheral
    for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService]) {
        if shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: "retrieved_data_service") {
            connect(peripheral, source: "retrieved_data_service")
            return
        }
    }

    // 2. Stored identifier
    if let identifier = persistedPeripheralIdentifier,
       let peripheral = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first,
       shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: "retrieved_identifier") {
        connect(peripheral, source: "retrieved_identifier")
        return
    }

    // 3. Scan (always valid fallback)
    startScanning(reason: reason)
}
```

### Change 5 — Named timing constants + `connectTimeout` 8s

**State machine role:** CONNECTING → FAST_RETRY timeout duration. Named constants make Tier 0 verification unambiguous.

```swift
private let connectTimeout: TimeInterval = 8             // was 20
private let authFallbackDelay: TimeInterval = 2          // was 6 — see Change 7
private let discoveryTimeoutInterval: TimeInterval = 15  // was 30 — see Change 8
```

`scheduleDiscoveryTimeout` must use `discoveryTimeoutInterval` rather than a literal. These are tuning targets based on build 190 soak data.

### Change 6 — `authFallbackDelay` 6s → 2s

**State machine role:** observingAuth → enablingControl fallback timing within WINDOW_ACTIVE.

Applied via named constant in Change 6. `0x05` typically arrives within ~1s in successful sessions; 2s is the tuning target.

### Change 7 — `discoveryTimeoutInterval` 30s → 15s

**State machine role:** WINDOW_ACTIVE discovery watchdog duration.

Applied via named constant in Change 6. 15s is the tuning target; adjust based on build 191 soak data if needed.

### Change 8 — Unified scheduler: fast retry + moderate wait (H1)

**State machine role:** Implements FAST_RETRY and MODERATE_WAIT states. Replaces exponential backoff entirely. Adds `lastCBEventAt` and `lastSuccessfulEGVAt` storage for H2 (build 192) without implementing H2 logic.

**New state:**

```swift
private var fastRetryCount: Int = 0
private var lastCBEventAt: Date?           // set on every CB peer_connected
private var lastSuccessfulEGVAt: Date?     // set in handleGlucose

enum SchedulerMode: String {
    case fastRetry    = "fast_retry"
    case moderateWait = "moderate_wait"
}
private var schedulerMode: SchedulerMode = .fastRetry
```

**`scheduleNextAttempt` — replaces all `scheduleReconnect(reason:)` call sites.**

Before implementing, enumerate every `scheduleReconnect(reason:)` call site and confirm none relies on side effects beyond delay selection.

```swift
private func scheduleNextAttempt(reason: String) {
    guard !isHardStopped else { return }
    cancelTransientTimers()
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil

    if activePeripheral?.state == .connected {
        log("event=g7_ble_reconnect_skipped reason=already_connected trigger=\(reason) gen=\(currentSessionGeneration)")
        return
    }

    // Increment before deciding mode; capture for log before possible reset
    fastRetryCount += 1
    let countAtDecision = fastRetryCount

    let (delay, mode): (TimeInterval, SchedulerMode) = {
        if fastRetryCount >= 5 {
            fastRetryCount = 0   // reset; log will show countAtDecision=5
            return (15.0, .moderateWait)
        }
        return (2.0, .fastRetry)
    }()

    schedulerMode = mode
    stage = .idle
    noteStatus(.searching)
    log("event=g7_ble_scheduler mode=\(mode.rawValue) delay_s=\(Int(delay)) fast_retry_count=\(countAtDecision) reason=\(reason) gen=\(currentSessionGeneration)")

    let gen = currentSessionGeneration
    let workItem = DispatchWorkItem { [weak self] in
        guard let self, self.currentSessionGeneration == gen else {
            self?.log("event=g7_ble_reconnect_skipped reason=stale_gen scheduled_gen=\(gen) current_gen=\(self?.currentSessionGeneration ?? 0) trigger=\(reason)")
            return
        }
        self.startOrResume(reason: "scheduler_\(mode.rawValue)_\(reason)")
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
}
```

**`lastCBEventAt`** — in `connectionEventDidOccur`, for all `peerConnected` events including self-ignored:

```swift
if event == .peerConnected {
    lastCBEventAt = Date()
    // ... existing self-loop guard
}
```

**`lastSuccessfulEGVAt` and `fastRetryCount` reset** — in `handleGlucose`, after `sessionEGVCount += 1`:

```swift
lastSuccessfulEGVAt = reading.readingDate  // sensor reading time; typically lags wall clock by seconds
fastRetryCount = 0
```

Do **not** increment `failedAttempts` on `connect_timeout` — that counter serves scan-retry logic, not OS scheduling delays.

### Change 9 — Re-register `registerForConnectionEvents` on foreground entry

**State machine role:** Belt-and-suspenders ensuring CB peer_connected events reliably interrupt any state.

```swift
// In applyForegroundActiveEntry, on queue, before startOrResume:
if centralManager.state == .poweredOn {
    centralManager.registerForConnectionEvents(options: [
        CBConnectionEventMatchingOption.serviceUUIDs: [
            G7BLEUUID.advertisement,
            G7BLEUUID.dataService
        ]
    ])
    log("event=g7_ble_connection_events_registered reason=foreground_active gen=\(currentSessionGeneration)")
}
```

Build 191 has four registration sites: `.poweredOn`, `connect()`, `startScanning()`, foreground entry.

### Change 10 — Daily counters UI

**State machine role:** None — observability only.

Restore `bleConnectsToday`, `bleEGVsToday`, `bleConnectionEventsToday` from builds 186/187. UserDefaults-backed with midnight reset, mirrored to `WatchState` for the debug UI. No protocol impact.

```swift
private var bleConnectsToday: Int = 0
private var bleEGVsToday: Int = 0
private var bleConnectionEventsToday: Int = 0

private func loadDailyCounters() { ... }                  // called in init()
private func persistDailyCounters() { ... }               // called after each increment
private func loadDailyCountersIfNewCalendarDay() { ... }  // called in applyForegroundActiveEntry
```

## 6. Commit order and pre-ship actions

### Feature branch commits (all touch only `G7DirectBLEObserver.swift`)

| # | Change |
|---|---|
| 1 | Peripheral-identity guards |
| 2 | `connectInFlight` guard |
| 3 | `isDiscoveringServices` gate |
| 4 | `retrieveConnectedPeripherals` in ladder |
| 5 | Named constants + `connectTimeout` 8s |
| 6 | `authFallbackDelay` 2s |
| 7 | `discoveryTimeoutInterval` 15s |
| 8 | Unified scheduler H1 |
| 9 | Re-register on foreground entry |
| 10 | Daily counters UI |

### Pre-ship actions (outside this feature branch)

Before tagging build 191:

**Prerequisite:** Confirm `06-cloud-logging.patch` has been regenerated from `feature/cloud-logging` before tagging this build.

## 7. Tier 0 invariants

Run after every commit. Grep checks require the reviewer to inspect actual output counts and locations — exit code alone is not sufficient.

```bash
# Timing constants — exactly one declaration each
grep 'let connectTimeout: TimeInterval = 8'              # exactly one match
grep 'let authFallbackDelay: TimeInterval = 2'            # exactly one match
grep 'let discoveryTimeoutInterval: TimeInterval = 15'    # exactly one match

# Scheduler — verify presence
grep 'scheduleNextAttempt'         # PRESENT — multiple call sites; confirm count matches
                                   # every former scheduleReconnect call site
grep 'g7_ble_scheduler'            # PRESENT — at least one log call site
grep 'fastRetryCount'              # PRESENT
grep 'lastCBEventAt'               # PRESENT
grep 'lastSuccessfulEGVAt'         # PRESENT

# fastRetryCount = 0: exactly two sites
grep -n 'fastRetryCount = 0'       # exactly two matches; verify one in handleGlucose,
                                   # one in moderateWait branch of scheduleNextAttempt

# Removed patterns — zero matches each
grep 'Double(2 << min(failedAttempts'     # ABSENT
grep 'postEGVBackoffWorkItem'              # ABSENT
grep 'scheduleInterWindowSleep'            # ABSENT
grep 'lastSessionWasSuccess'               # ABSENT
grep 'scheduleReconnect'                   # ABSENT

# Correctness guards — verify presence and locations
grep -n 'connectInFlight'          # PRESENT; verify set in connect(), cleared in connect
                                   # timeout closure, didConnect (matching),
                                   # didFailToConnect (matching), didDisconnect (matching),
                                   # hardStopOnQueue — exactly these sites
grep -n 'isDiscoveringServices'    # PRESENT; verify set in discoverServicesIfNeeded,
                                   # cleared in hardStop, didDisconnect, didFailToConnect
grep -c 'peripheral_mismatch'      # exactly 3 matches — one per CB callback guard

# Carried from build 190
grep 'auth_notify_enabled_observer'       # ABSENT — Option C
grep 'scheduleObservingAuthStageTimeout'  # ABSENT
grep "options: nil"                        # PRESENT — notification flag removed
grep 'reason=powered_on'                   # PRESENT — MOD-E registration
```

**BetterStack dedup verification (companion patch):** After `06-cloud-logging.patch` ships and a midnight rotation occurs, pick a known single-occurrence event (e.g., `g7_ble_connection_events_registered reason=powered_on` at a specific timestamp) and confirm it appears exactly once in BetterStack, not twice. The verification window must span a midnight rotation.

## 8. Expected log signatures

**Fast retry cycle:**
```
event=g7_ble_session_outcome terminal_reason=connect_timeout gen=N
event=g7_ble_scheduler mode=fast_retry delay_s=2 fast_retry_count=1 reason=connect_timeout gen=N
event=g7_ble_lifecycle action=attach_ladder_start reason=scheduler_fast_retry_connect_timeout
```

**Moderate wait triggered (5th consecutive scheduler retry):**
```
event=g7_ble_session_outcome terminal_reason=R gen=N
event=g7_ble_scheduler mode=moderate_wait delay_s=15 fast_retry_count=5 reason=R gen=N
event=g7_ble_lifecycle action=attach_ladder_start reason=scheduler_moderate_wait_R
```
`fast_retry_count=5` is logged because `countAtDecision` is captured before the reset to 0.

**EGV success + post-success retry (build 191 without H2):**
```
event=g7_ble_egv_received glucose=N gen=N
event=g7_ble_session_outcome outcome=success terminal_reason=egv_received gen=N
event=g7_ble_disconnect peripheral_id=X gen=N
event=g7_ble_scheduler mode=fast_retry delay_s=2 fast_retry_count=1 reason=post_egv_disconnect gen=N
```
`fast_retry_count=1`: reset to 0 on EGV, then incremented to 1 in `scheduleNextAttempt`. In build 191, post-success retry uses the same scheduler path as failure recovery; H2 replaces this specific path in build 192.

**Peripheral mismatch (should be infrequent):**
```
event=g7_ble_disconnect_ignored reason=peripheral_mismatch peripheral_id=X gen=N
```

## 9. Success criteria

| Tier | Criterion |
|---|---|
| Tier 0 | All §7 invariants pass before tagging |
| Tier 0 | `06-cloud-logging.patch` updated and patch stack regenerates cleanly |
| Tier 1 (2h) | `g7_ble_scheduler` events appear with both `mode=fast_retry` and `mode=moderate_wait` visible |
| Tier 1 | Zero duplicate `connect_attempt` events at the same timestamp |
| Tier 1 (soak expectation, not hard gate) | `g7_ble_auth_payload_received opcode=0x05` expected within the first soak window as the EGV path is confirmed working |
| Tier 2 (24h) | `g7_ble_scheduler mode=moderate_wait fast_retry_count=5` appears — confirms 5th-retry threshold fires correctly |
| Tier 2 | `connect_timeout` session durations substantially lower than build 190 and typically around 8s, with some variance from callback and logging lag |
| Tier 2 | CB `peer_connected` events continue across process restarts with no multi-hour gaps |
| Tier 2 | `auth_fallback_no_egv` average session duration drops relative to build 190's 518s baseline |
| Tier 2 (post-midnight) | Counts for duplicated watch-log events drop by roughly half after a post-midnight validation window — expected from dedup fix, not a regression |
| Tier 3 (24h) | `egv_received` rate increases relative to build 190's baseline (~2 EGVs per 10 hours), measured over a comparable window |

**Regression signals:**
- `g7_ble_scheduler mode=fast_retry` events cycling continuously with `fast_retry_count` incrementing toward and past 5 but `mode=moderate_wait` never appearing = scheduler threshold logic bug.
- Zero `egv_received` for 6+ waking hours = revert to build 190.

## 10. Deferred to build 192

**H2 — Inter-window sleep.** `lastSuccessfulEGVAt` and `lastCBEventAt` are stored in build 191 and ready to use. Anchor hierarchy:

```swift
let anchor = lastSuccessfulEGVAt ?? lastCBEventAt
if let anchor = anchor {
    let elapsed = Date().timeIntervalSince(anchor)
    if elapsed < 300 {
        let sleep = max(10, 300 - elapsed - 30)
        log("event=g7_ble_scheduler mode=inter_window_sleep delay_s=\(Int(sleep)) elapsed_s=\(Int(elapsed)) gen=\(currentSessionGeneration)")
        scheduleInterWindowSleep(delay: sleep)
    } else {
        // Stale anchor — fall back to retry scheduler
        scheduleNextAttempt(reason: "stale_anchor")
    }
} else {
    scheduleNextAttempt(reason: "no_anchor")
}
```

`lastSuccessfulEGVAt` is `reading.readingDate` — sensor-reported time, typically lagging wall clock by seconds. Reasonable proxy for window timing.

**D — CB fast-path connect.** `connectionEventDidOccur(.peerConnected)` → `retrieveConnectedPeripherals` → `connect()` immediately, skipping the attach ladder. Isolated in build 192 for clean attribution.

**WKExtendedRuntimeSession.** Build 193 or later.

## 11. Change log

| Version | Timestamp | Changes |
|---|---|---|
| 1.0 | 2026-05-02 09:00 CET | Initial plan |
| 1.1 | 2026-05-02 10:00 CET | Fixed moderate-wait counter log; fixed success-path log example; added §4 lifecycle ownership rules; fixed connectInFlight mismatch path; exact-declaration Tier 0 greps; softened absolute claims; fixed H2 stale-anchor comment |
| 1.2 | 2026-05-02 11:00 CET | Change 4 fully specified following WatchLogger pipeline investigation |
| 1.3 | 2026-05-02 12:00 CET | Change 4 moved to 06-cloud-logging.patch; all 10 feature commits isolated to G7DirectBLEObserver.swift; commit table renumbered; pre-ship actions added to §6 |
| 1.4 | 2026-05-02 13:00 CET | Removed cloud logging fix implementation detail from plan body; Change 4 is a brief note only |
| 1.5 | 2026-05-02 14:00 CET | Fixed regression signal; added defensive connectInFlight clear in timeout closure; added idempotent qualifier to didDisconnectPeripheral clear; made generation semantics explicit; clarified post-success behavior in §2; split branch vs companion patch in §6; strengthened Tier 0 count checks; softened BetterStack count change wording |
| 1.6 | 2026-05-02 15:00 CET | FAST_RETRY state definition updated to include post-success disconnect consistently across state table, diagram, and prose. fastRetryCount reframed as "consecutive scheduler retries since last EGV" not "consecutive failures" — §4.4 updated, entry wording changed from "Failure enters" to "Retry enters", distinction between failure and post-success paths made explicit. didFailToConnect clearing isDiscoveringServices noted as defensive cleanup explicitly. Tier 0 checks given human-review qualifier. opcode=0x05 success criterion softened to soak expectation. connect_timeout duration criterion updated to "substantially lower than build 190 and typically around 8s, with some variance." §8 post-success log example given explicit clarifier that H2 replaces this path in build 192. |
| 1.7 | 2026-05-02 16:36 CET | Added prerequisite section to §2; clarified pre-ship actions in §6; added BetterStack dedup prerequisite to §2 |