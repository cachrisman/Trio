# G7 Direct BLE Observer — Issue Summary and Fix Proposal

**Version:** v1.1
**Created:** 2026-04-25
**Last updated:** 2026-04-25 15:30 CET
**Status:** Ready for agent review
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`
**Build:** 185

This document summarises observed issues in build 185, the evidence for each, and the proposed fixes. It is intended as the input to an implementation agent. All fixes are grounded in observed log evidence or documented CB behaviour. Conjectural hypotheses are labelled explicitly.

---

## Background

Build 185 proved the G7 direct BLE observer architecture is correct. In overnight testing (22:34–05:19 UTC), 25 successful EGVs were delivered. The dominant successful attach mechanism was `registerForConnectionEvents` (MOD-E), which fires when the G7 sensor opens its ~5-minute re-auth window with the Dexcom watch app.

After the watch came off the charger this morning (~10:24 UTC), reliability degraded significantly. One force kill of the app (at ~11:23 UTC) restored normal behaviour for approximately one cycle, then degraded again. Three "accessory disconnected" system notifications appeared today. These are the issues this document addresses.

---

## State flag reset requirements

Several fixes below introduce new boolean flags and work items. To prevent flags getting stuck, **all new state flags and work items must be reset in every one of these locations** unless the fix explicitly notes an exception:

- `start()` / app launch
- `stop()`
- `hardStop()`
- `centralManager(_:didDisconnectPeripheral:error:)`
- `centralManager(_:didFailToConnect:error:)`
- `willRestoreState` cancel path (B0)
- Any timeout path that tears down a session

This requirement applies to: `connectInFlight`, `isDiscoveringServices`, `lastSessionWasSuccess`, `postEGVBackoffWorkItem`.

---

## Issue 1: Unhandled `centralManager(_:willRestoreState:)`

### Severity: High — plausible primary cause of multiple other symptoms

### Evidence

Every startup sequence in the logs shows:

```
event=g7_ble_lifecycle action=foreground_active central_state=0
event=g7_ble_lifecycle action=start_waiting reason=foreground_active central_state=0
event=g7_ble_lifecycle action=central_state state=5
event=g7_ble_lifecycle action=attach_ladder_start reason=central_powered_on
```

There is no `willRestoreState` event logged anywhere. Either the delegate method is not implemented, or it is not being called on restoration relaunches. Both indicate incorrect state restoration handling.

Additionally, at 11:34:37 the following appears:

```
event=g7_ble_did_connect peripheral_id=360BC9F5 name=DXCM08
event=g7_ble_did_connect peripheral_id=360BC9F5 name=DXCM08   ← duplicate
event=g7_ble_auth_notify_enable_requested ...
event=g7_ble_auth_notify_enable_requested ...                  ← duplicate
event=g7_ble_auth_notify_enabled result=success ...
event=g7_ble_auth_notify_enabled result=success ...            ← duplicate
event=g7_ble_auth_notify_enabled result=success ...            ← third
```

Triple `did_connect` and triple `auth_notify` events on a single physical connection. This is most consistent with CB having a preserved pending connect from state restoration AND our code issuing a fresh `connect()` simultaneously — two connect paths completing for the same peripheral.

### What `willRestoreState` does

`centralManager(_:willRestoreState:)` is called on restoration relaunches — when the OS relaunches the app into the background because CB has preserved state (pending connects, active connections) from the prior process lifetime. It is **not** called on every cold launch. Absence on a cold launch is not a bug.

The `dict` parameter contains `CBCentralManagerRestoredStatePeripheralsKey` — peripherals that were connected or had pending connection attempts when the process was last suspended. If this callback is not handled, CB may keep a preserved pending `connect(DXCM08)` alive from the prior session while our code also issues a fresh one, producing duplicate `didConnect` callbacks.

### "Accessory disconnected" notification

The three notifications today are most consistent with three state-restoration-triggered connections that completed via CB's preserved connect path, without the implementation being aware. When DXCM08 disconnected normally (CBError 7), CB generated the OS notification because it considered the connection user-facing. This is a working hypothesis — we do not have Apple documentation confirming exactly when this notification is triggered.

State restoration itself is not the bug — it is the prerequisite for MOD-E background delivery. The gap is not handling `willRestoreState`, leaving CB managing connections the observer code does not know about.

### Proposed fix

**Task B0:** Implement `centralManager(_:willRestoreState:)` correctly.

In `G7DirectBLEObserver.swift`, add or correct the delegate method:

````swift
func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    log("event=g7_ble_will_restore_state restored_count=\(restored.count) peripherals=\(restored.map { $0.identifier.uuidString }.joined(separator: ","))")

    for peripheral in restored {
        // Cancel CB's preserved pending connection before our attach ladder
        // issues its own connect(). Without this, both paths can fire
        // simultaneously producing duplicate did_connect callbacks.
        // Only cancel if not already connected — cancelling a .connected
        // peripheral tears down a live session.
        if peripheral.state != .connected {
            central.cancelPeripheralConnection(peripheral)
            log("event=g7_ble_restore_cancelled peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") state=\(peripheral.state.rawValue)")
        } else {
            log("event=g7_ble_restore_skipped_cancel peripheral_id=\(peripheral.identifier.uuidString) reason=already_connected")
        }
    }

    // The normal attach ladder (triggered by centralManagerDidUpdateState)
    // will re-evaluate DXCM08 through the standard retrieved_identifier path.
    // Do NOT issue a new connect() here.
}
````

Also add a log line in `centralManagerDidUpdateState` that records whether restoration fired. This makes cold-launch vs restoration-relaunch distinguishable in BetterStack:

````swift
func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let wasRestored = didReceiveWillRestoreState  // new Bool property, set to true in willRestoreState, reset on each init
    log("event=g7_ble_central_state state=\(central.state.rawValue) was_restored=\(wasRestored)")
    // ... existing logic
}
````

**Acceptance criteria:**
- On restoration relaunches: `event=g7_ble_will_restore_state` appears before `event=g7_ble_central_state`
- On cold launches: `event=g7_ble_central_state was_restored=false` appears with no preceding `will_restore_state` — this is correct behaviour, not a bug
- Triple `did_connect` events disappear
- Triple `auth_notify_enabled` events disappear
- "Accessory disconnected" notifications stop appearing (working hypothesis — validate empirically)

**Notes:**
- Do NOT issue `connect()` in `willRestoreState` — let `centralManagerDidUpdateState` drive the attach ladder
- The `.connected` state branch is required — `cancelPeripheralConnection` on a live session tears it down

---

## Issue 2: Parallel `connect()` calls from scene/lifecycle churn

### Severity: Medium — exacerbates Issue 1, contributes to anomalous CB session durations

### Evidence

Multiple `foreground_active` events fire within seconds of each other, each triggering an `attach_ladder_start` and a `connect_attempt`:

```
10:50:14  action=foreground_active → attach_ladder_start → connect_attempt
10:50:15  action=foreground_active → attach_ladder_start → connect_attempt
10:50:15  action=foreground_active → attach_ladder_start → connect_attempt
```

Three simultaneous pending `connect(DXCM08)` calls from wrist-raise/lower and notification events each generating a `scenePhase=active` event in rapid succession.

### Proposed fix

**Task B1:** Add a `connectInFlight` boolean guard.

Using `activePeripheral?.state != .connecting` is unreliable because `CBPeripheral.state` can lag the actual in-flight state by the time the guard is evaluated. A dedicated flag is more reliable.

````swift
private var connectInFlight = false  // reset on didConnect, didFailToConnect, disconnect, stop, hardStop

// At top of the connect function:
guard !connectInFlight else {
    log("event=g7_ble_connect_skipped reason=already_connecting source=\(source)")
    return
}
connectInFlight = true
````

Before issuing `central.connect(peripheral, options:)`, defensively clear any stale pending connection. Branch on peripheral state — only cancel if NOT already connected, since cancelling a live `.connected` peripheral tears it down:

````swift
if peripheral.state == .connecting {
    central.cancelPeripheralConnection(peripheral)
    log("event=g7_ble_stale_connect_cancelled peripheral_id=\(peripheral.identifier.uuidString)")
}
central.connect(peripheral, options: nil)
````

Clear `connectInFlight` in:
- `centralManager(_:didConnect:)` — success
- `centralManager(_:didFailToConnect:error:)` — failure
- `centralManager(_:didDisconnectPeripheral:error:)` — teardown
- Any connect-timeout path
- `stop()` and `hardStop()`

**Notes:** The `cancelPeripheralConnection` here is defensive cleanup for a `.connecting` peripheral — not a blanket pre-connect cancel. The "documented best practice" language is removed; this is pragmatic defensive cleanup that is expected to be a no-op when no connection is pending.

**Acceptance criteria:**
- `connect_skipped reason=already_connecting` appears when rapid scene transitions fire
- No more than one `connect_attempt` per physical attach cycle in logs

---

## Issue 3: Post-success reconnect churn

### Severity: Medium — primary cause of battery drain and `incomplete/idle` session volume

### Evidence

After each CBError 7 success, the observer immediately restarted its reconnect loop:

```
10:34:37  session_outcome=success egv_count=1
10:34:41  connect_attempt → connect_failed reason=timeout (22s)
10:35:03  connect_attempt → connect_failed reason=timeout (22s)
10:35:34  connect_attempt → connect_failed reason=timeout (22s)
... continues ~5 minutes until next G7 window ...
10:39:31  connection_event peer_connected → success
```

25 successful EGVs, ~96 total session outcomes → ~71 `incomplete/idle` sessions. The G7's re-auth window is ~20-30 seconds wide every ~300 seconds. Between windows, every connect attempt fails.

### Proposed fix

**Task B2:** Post-success sleep with MOD-E cancellation.

````swift
private var postEGVBackoffWorkItem: DispatchWorkItem?
private var lastSessionWasSuccess = false  // reset on each connect() call

// In disconnect handler, after session outcome logging:
if lastSessionWasSuccess {
    let workItem = DispatchWorkItem { [weak self] in
        guard self?.isRunning == true else { return }  // guard against late wakeups
        self?.kickAttachIfNeeded(source: .retryBackoff)
    }
    postEGVBackoffWorkItem = workItem
    bleQueue.asyncAfter(deadline: .now() + 290, execute: workItem)
    log("event=g7_ble_post_egv_backoff_scheduled delay_s=290")
} else {
    scheduleReconnect(reason: "disconnect")
}

// In connectionEventDidOccur for .peerConnected, before attach:
postEGVBackoffWorkItem?.cancel()
postEGVBackoffWorkItem = nil
log("event=g7_ble_post_egv_backoff_cancelled reason=connection_event")
````

Cancel `postEGVBackoffWorkItem` also in `stop()` and `hardStop()`.

The `guard self?.isRunning == true` inside the work item prevents a racey late wakeup from calling into a stopped observer.

**Acceptance criteria:**
- `post_egv_backoff_scheduled` appears after each `session_outcome=success`
- `post_egv_backoff_cancelled reason=connection_event` appears before the next successful attach
- `incomplete/idle` session count between successes drops from 3-4 to 0-1

---

## Issue 4: Double service discovery from MOD-E + `didConnect` race

### Severity: Low-medium — causes redundant GATT traffic and dedup events

### Evidence

On each successful cycle:
```
event=g7_ble_auth_notify_enable_requested   ← first discovery path
event=g7_ble_auth_notify_enable_requested   ← second discovery path (duplicate)
event=g7_ble_egv_received action=dedup_skipped ...
```

Both `centralManager(_:didConnect:)` and `connectionEventDidOccur(.peerConnected)` trigger service discovery independently.

### Proposed fix

**Task B3:** Add an explicit `isDiscoveringServices` flag. Do NOT use `peripheral.services == nil` as the guard — `services` can be non-nil from cached prior-connection state, from completed discovery, or for other reasons unrelated to whether discovery is currently in progress. An explicit flag is required.

````swift
private var isDiscoveringServices = false  // reset on disconnect, teardown, stop, hardStop

// At entry of the service discovery trigger function:
guard !isDiscoveringServices else {
    log("event=g7_ble_service_discovery_skipped reason=already_in_progress")
    return
}
isDiscoveringServices = true
peripheral.discoverServices(nil)
````

Clear `isDiscoveringServices` when:
- Service discovery fails
- Session ends (disconnect, teardown)
- `stop()` / `hardStop()`
- Transitioning cleanly to the next phase (characteristics discovered)

**Acceptance criteria:**
- `auth_notify_enable_requested` appears exactly once per session
- `dedup_skipped` events on EGV disappear
- `service_discovery_skipped reason=already_in_progress` appears on the duplicate path

---

## Issue 5: Anomalous CB session durations after many consecutive failures

### Severity: Unknown — mechanism unconfirmed, symptom real

### Evidence (observed facts only)

Normal `connect_failed` session duration: 21-22 seconds consistently.

After many consecutive failures:
- 10:40–10:44: `duration_ms=216,987ms` (3.6 minutes)
- 11:29: `duration_ms=121,155ms` (2 minutes)
- 11:33: `duration_ms=75,208ms` (1.25 minutes)

CB held these connection attempts open far longer than normal. Force kill of the app reset this behaviour.

### Hypothesis (not confirmed)

CB may apply undocumented connection-attempt rate limiting after many consecutive failures to the same peripheral. Alternatively, CB may be patiently waiting longer for a peripheral it believes should be connectable. Both hypotheses produce identical log patterns. The mechanism is conjecture — the symptom is real.

### Proposed investigation

**Task B5:** Add `consecutive_connect_failures` counter. Log it on each failure:

```
event=g7_ble_connect_failed reason=timeout consecutive_failures=<N> duration_ms=<N>
```

Reset the counter on any `didConnect` success. Correlate in BetterStack: does `duration_ms` escalate as `consecutive_failures` rises? This turns a conjecture into a testable hypothesis over 2-3 builds.

**Do not implement CB recreation yet.** The evidence does not justify a medium-risk architectural change. Data first.

---

## Issue 6: MOD-E reliability after charger/lifecycle transitions

### Severity: High (when it occurs) — mechanism unknown

### Evidence

Last night: 36 `connection_event peer_connected` events across 6 hours, reliably every ~5 minutes.

After watch came off charger at ~10:24: zero `connection_event` events across 70+ minutes of logs.

### Hypotheses (neither confirmed)

- `registerForConnectionEvents` registration may become stale after charger wake or state restoration transitions, causing delivery to stop. Currently called once in the scan path — may need refreshing.
- CB may suppress connection-event delivery to processes that have been issuing many consecutive failed connection attempts. If so, fixing Issues 2 and 3 (parallel connects, post-success sleep) may restore MOD-E as a side effect.

Apple documentation does not address `registerForConnectionEvents` registration lifetime. Neither hypothesis is confirmed.

### Proposed fix

**Task B4:** Re-register on every `foreground_active` entry as an empirical hardening step. This is low-risk but its effect is uncertain — the goal is to gather data, not assume it will work.

````swift
// In handleForegroundActiveEntry:
centralManager.registerForConnectionEvents(options: [
    CBConnectionEventMatchingOption.serviceUUIDs: [
        G7DirectBLEConstants.advertisementServiceUUID,
        G7DirectBLEConstants.cgmServiceUUID
    ]
])
log("event=g7_ble_connection_events_registered reason=foreground_active")
````

Whether calling this repeatedly creates duplicate registrations or updates an existing one is not confirmed in Apple documentation. Treat this as an experiment — the log line lets us correlate registration calls with subsequent MOD-E delivery in BetterStack.

**Additionally:** add a MOD-E absence detector. Track `lastConnectionEventReceivedAt: Date?`. In the post-EGV backoff work item, if the backoff fires without being cancelled by MOD-E, log:

```
event=g7_ble_connection_event_absent last_event_age_s=<N>
```

**Acceptance criteria (empirical, not functional):**
- `connection_events_registered reason=foreground_active` appears on each wrist raise / screen-on
- `connection_event_absent` frequency vs `post_egv_backoff_cancelled reason=connection_event` frequency over 24h tells us the real MOD-E reliability rate after B2/B3 are in place
- Whether B4 reduces `connection_event_absent` frequency is the experiment — measure and report

---

## Opcode 0x32 logging (minor)

### Evidence

On every successful session, a `0x32` packet arrives on the control characteristic after EGV delivery. Currently silently dropped.

### Proposed fix

**Task C2:** Explicit log line in the control payload handler:

````swift
case 0x32:
    log("event=g7_ble_control_payload_unhandled opcode=0x32 byte_count=\(data.count) preview=\(data.prefix(8).hexadecimalString)")
````

Log only — no parsing, no action.

---

## Implementation order

| Task | Description | Risk | Prerequisite |
|---|---|---|---|
| B0 | `willRestoreState` + `was_restored` logging | Low-medium | None — do first |
| B1 | `connectInFlight` guard + conditional cancel | Very low | B0 |
| B3 | `isDiscoveringServices` flag | Very low | B0 |
| B2 | Post-success sleep with `isRunning` guard | Low | B1 |
| B5 | Consecutive-failure counter logging | Very low | None |
| B4 | MOD-E refresh on foreground_active + absence detector | Very low | B2 |
| C2 | Opcode 0x32 explicit logging | Very low | None |

B3 moved before B2 (vs v1.0 order) to de-noise results before evaluating B2 and B4.

---

## What NOT to do yet

- **CB central manager recreation:** plausible hypothesis for the session duration escalation but not confirmed. Implement B5 first and gather data across 2-3 builds.
- **`CBConnectPeripheralOptionNotifyOnDisconnectionKey: false`:** treats the symptom of the "accessory disconnected" notification, not the cause. If B0 is correctly implemented, the notification should stop. Do not add this until B0 is validated.
- **CB scan fallback after N failures:** scan is unlikely to find DXCM08 while it's in an active session with the Dexcom app. Complexity is not justified without evidence.

---

## Observability improvements from these fixes

**MOD-E reliability rate:**
````sql
SELECT
    countIf(raw LIKE '%post_egv_backoff_cancelled reason=connection_event%') AS mode_cancels,
    countIf(raw LIKE '%connection_event_absent%') AS mode_absent,
    mode_cancels / (mode_cancels + mode_absent) AS mode_e_reliability
FROM (... UNION ALL ...)
WHERE build = '186' AND platform = 'watchos'
````

**State restoration vs cold launch (per startup):**
````sql
SELECT
    countIf(raw LIKE '%was_restored=true%') AS restoration_starts,
    countIf(raw LIKE '%was_restored=false%') AS cold_starts
FROM (... UNION ALL ...)
WHERE build = '186' AND platform = 'watchos'
  AND raw LIKE '%g7_ble_central_state%'
````

**Parallel connect guard firing rate:**
````sql
SELECT count() FROM ...
WHERE raw LIKE '%connect_skipped reason=already_connecting%'
````

**Consecutive failure vs session duration (from B5):**
````sql
SELECT
    JSONExtractUInt(raw, 'consecutive_failures') AS failures,
    toStartOfHour(dt) AS hour,
    count() AS occurrences
FROM ...
WHERE raw LIKE '%connect_failed%'
GROUP BY failures, hour
ORDER BY hour, failures
````

---

## Changelog

### v1.1 (2026-04-25)

Reviewed against ChatGPT adversarial review. The following changes were made based on agreement with the review:

- **B3 guard replaced:** removed `peripheral.services == nil` as the "already discovering" signal — this is unreliable because `services` can be non-nil from cached prior-connection state, completed discovery, or for other reasons. Replaced with explicit `isDiscoveringServices` boolean flag per ChatGPT's recommendation.
- **B1 guard replaced:** removed `activePeripheral?.state != .connecting` — `CBPeripheral.state` can lag intent. Replaced with `connectInFlight` boolean per ChatGPT's recommendation.
- **cancelPeripheralConnection correctness fix:** added required state branch — do not call `cancelPeripheralConnection` on an already-`.connected` peripheral as this tears down a live session, not a pending connect. Applied in both B0 and B1. ChatGPT called this out correctly; v1.0 missed it.
- **cancelPeripheralConnection language softened:** removed "documented CB best practice" (no direct Apple citation). Replaced with "defensive cleanup, expected to be a no-op when no connection is pending."
- **B0 acceptance criteria corrected:** removed "appears at every process startup." `willRestoreState` fires on restoration relaunches only. Absence on cold launch is not a bug. Added `was_restored` boolean in `centralManagerDidUpdateState` (my addition, not in ChatGPT's review) to make cold-launch vs restoration-relaunch distinguishable in BetterStack.
- **B4 framing softened:** removed "idempotent" claim (no Apple docs citation). Reframed as "empirical hardening step — measure whether it correlates with restored MOD-E delivery, do not assume it will work."
- **B2 `isRunning` guard added:** added `guard self?.isRunning == true` in the post-EGV backoff work item before calling `kickAttachIfNeeded`. Prevents racey late wakeups in a stopped observer. Per ChatGPT's recommendation.
- **State reset requirements section added:** explicit list of all locations where new flags must reset, preventing agents from implementing flags that get stuck.
- **Wording adjustments throughout:** "likely root cause" → "plausible primary cause"; "consistent with" → "most consistent with"; "likely" softened to "most consistent with" on the notification hypothesis.
- **Implementation order adjusted:** B3 moved before B2 per ChatGPT's recommendation — cheaper correctness fix, de-noises results before evaluating B2 and B4.
- **"Accessory disconnected" notification framing:** labeled as "working hypothesis" rather than confirmed mechanism, as we do not have Apple documentation proving when exactly these notifications are triggered.

The following ChatGPT points were noted but not acted on as changes:
- ChatGPT suggested removing `cancelPeripheralConnection` entirely as a pre-connect step unless clearly justified. We retained a conditional version (cancel only on `.connecting` state) because the guard is genuinely useful for clearing stale CB state after parallel-connect scenarios, and the correctness issue (never cancel `.connected`) is now addressed by the state branch.

### v1.0 (2026-04-25)
Initial version.
