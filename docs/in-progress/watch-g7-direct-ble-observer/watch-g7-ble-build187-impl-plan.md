# Implementation plan: Build 187 / 188

**Version:** v1.14
**Created:** 2026-04-26
**Last updated:** 2026-04-27 16:56 CEST
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`

---

## Build 189 — code complete (not yet shipped / TestFlight)

**Status:** Implemented on `feature/watch-g7-direct-ble-observer-synthesis` in five commits (see [Implementation log (Build 189)](#implementation-log-build-189)). **Ship / validate** per Build 189 BetterStack section below; no `xcodebuild` in this session (AGENTS.md / prompt 04).
**Note on structure:** Tasks A and C are the core protocol regression revert. Tasks B and D are bundled in the same build but are logically independent improvements — B is a new scheduler policy, D is observability. If build 189 fails to restore reads, the investigation should first rule out A/C issues before attributing anything to B.

---

### Diagnosis

Build 188 introduced **Option C**: advancing to control on the `auth_notify_enabled` CoreBluetooth callback, before the sensor has emitted any auth payload. Both reference implementations (xdripswift iOS observer; DiaBLE eavesdrop mode) confirm the correct observer contract: enable auth notify, then wait passively for the sensor-emitted `0x05 0x01 0x01`, then advance to control. Build 185 followed this contract and received many EGVs. Build 188 breaks it.

The xdripswift issue #494 debug logs show `0x05 0x01 0x01` arriving ~170ms after auth notify is enabled when the Dexcom app's session is active. Build 188's Option C fires at the `auth_notify_enabled` callback before the sensor has emitted any auth payload, sets up control notify and sends `0x4E` against a non-live session, and by the time `0x05` arrives `hasAdvancedBeyondAuth` is already `true`, so the correct `advanceToControl` path in `handleAuthPayload` is bypassed.

BetterStack build 188 analysis (2026-04-26 23:29 – 2026-04-27 12:37, 2517 log events) confirmed zero EGVs and two distinct failure modes: (1) connect-timeout storms between 5-minute windows — `consecutive_failures` reaching 9 across a single inter-window gap; (2) three sessions reached auth notify, all fired Option C immediately, all received write ACKs for `0x4E`, none received EGV responses. Session machine churn (duplicate attach ladders, duplicate service discovery) also confirmed in production.

---

## 189A — Core regression revert

### Task A — Remove Option C; restore passive observer contract

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Change 1 — Delete Option C from `handleNotificationState`**

In the `case G7BLEUUID.authentication:` branch, remove the block added in Build 188:

````swift
// DELETE — this was Build 188's Option C
if characteristic.isNotifying, !hasAdvancedBeyondAuth {
    authFallbackWorkItem?.cancel()
    advanceToControl(reason: "auth_notify_enabled_observer")
}
````

After removal, the case should only log:

````swift
case G7BLEUUID.authentication:
    authNotifyEnabled = characteristic.isNotifying
    log("event=g7_ble_auth_notify_enabled result=success notifying=\(characteristic.isNotifying)")
    // Wait passively for sensor-emitted 0x05 0x01 0x01
````

**Change 2 — Restore `authFallbackDelay` to 6 seconds**

````swift
private let authFallbackDelay: TimeInterval = 6
````

Restoring build 185's value exactly. When the Dexcom app's session is active, `0x05` arrives in ~170ms and the fallback never fires. The fallback is purely a missed-window recovery path. 6s is what worked in build 185; tune in a later build once reads are confirmed restored.

**Change 3 — Remove `scheduleObservingAuthStageTimeout`**

Build 188 added a 10-second auth-stage timeout. With `authFallbackDelay = 6`, the fallback fires first and the 10s timeout is redundant. Remove `scheduleObservingAuthStageTimeout` and its call in `configureObserverCharacteristics`. The outer `connectTimeout` (20s) remains as the session-level backstop. The service-discovery `stageTimeoutWorkItem` (30s) is unrelated — keep it.

---

### Task C — Session machine: parallel connect suppression and self-disconnect guard

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

Confirmed in production build 188 logs: duplicate attach ladders firing simultaneously, duplicate service discovery for the same connection, and self-induced disconnects scheduling redundant reconnect timers. Fixing these makes build 189 results trustworthy and clean to read.

**C1 — Connect-in-flight guard**

In `beginAttachLadder`, before launching a new connect:
````swift
guard activePeripheral?.state != .connecting else {
    log("event=g7_ble_attach_skipped reason=connect_in_flight")
    return
}
````

**C2 — Service discovery dedupe**

In `discoverServicesIfNeeded`, guard against re-discovering if services are already present:
````swift
guard peripheral.services == nil else {
    log("event=g7_ble_discovery_skipped reason=already_discovered")
    configureObserverCharacteristics(peripheral)
    return
}
````

**C3 — Self-induced disconnect guard**

Track self-cancels with an explicit flag:
````swift
private var isSelfCancelling = false
````

Set `isSelfCancelling = true` immediately before every `centralManager.cancelPeripheralConnection(peripheral)` call. In `didDisconnectPeripheral`:
````swift
if isSelfCancelling {
    isSelfCancelling = false
    log("event=g7_ble_disconnect reason=self_cancelled")
    return  // caller already scheduled the next action
}
````

---

### 189A acceptance criteria

- `g7_ble_auth_notify_enabled` with no subsequent `advanceToControl` until `g7_ble_auth_payload_received authenticated=true bonded=true`
- No control notify enable prior to authenticated/bonded auth payload (`g7_ble_control_notify_enable_requested` must not precede `g7_ble_auth_payload_received authenticated=true bonded=true` in any session)
- `control_notify_enable_requested reason=auth_authenticated_bonded` (not `auth_notify_enabled_observer`)
- `g7_ble_egv_received` within the same session
- `session_outcome outcome=success` timing consistent with build 185
- No `g7_ble_auth_payload_post_advance` events
- No duplicate attach or discovery events per session

### 189A falsification criteria

If build 189 does not restore EGVs, investigate in this order before escalating:

1. **Did Option C removal land correctly?** Check for absence of `advanceToControl reason=auth_notify_enabled_observer`. If it still appears, the code change didn't take.
2. **Did `0x05` arrive at all?** Check for `g7_ble_auth_payload_received`. If absent: either the session window was already closed when the watch connected, or Task C churn is still masking sessions. Check session machine logs first.
3. **Did `advanceToControl` fire?** If `0x05` arrived but control was never enabled, there's a guard condition blocking it.
4. **Did `0x4E` get a response?** If control was enabled and `0x4E` sent but no EGV arrived, Option C was not the only blocker — the sensor is ignoring the request for another reason. At this point escalate to packet capture and DiaBLE author outreach.
5. **Are remaining 185-era session machine issues contributing?** willRestoreState reliability, excessive hammering outside detected windows — these remain deferred but may surface if 189A fails.

---

## 189B — Bundled optimizations

*These are included in the same build as 189A but are logically independent. If 189A fails to restore reads, do not attribute the failure to 189B without first working through the 189A falsification steps above.*

---

### Task B — Connection-event-anchored inter-window sleep

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Problem:** The watch hammers 20s connect timeouts continuously between sensor windows — confirmed in production as `consecutive_failures` 1–9 across a single 5-minute gap. This is the same connect-loop pattern identified in xdripswift #494 as a battery-drain risk. The fix must work from bootstrap (before any EGV is received), so it cannot be keyed purely on EGV success.

**Key signal:** `connectionEventDidOccur(.peerConnected)` fires each time the Dexcom watch app connects to the sensor, anchoring approximately T=0 of each 5-minute window. Recording this timestamp gives the best available anchor for the sensor cycle — not a proven-reliable 300s clock, but the best signal the observer has access to without sensor-direct communication.

**New properties:**
````swift
private var lastConnectionEventAt: Date?
private var isInterWindowSleeping = false
private let windowCycleDuration: TimeInterval = 300
private let preWindowLeadTime: TimeInterval = 30
````

**Record timing** in `connectionEventDidOccur` for `peer_connected`:
````swift
lastConnectionEventAt = Date()
log("event=g7_ble_connection_event_anchor dt=\(Int(Date().timeIntervalSince1970))")
````

**Inter-window sleep helper:**
````swift
private func scheduleInterWindowSleep(reason: String) {
    guard let anchor = lastConnectionEventAt else {
        // No anchor yet — fall back to exponential backoff
        scheduleReconnect(reason: reason)
        return
    }
    let elapsed = Date().timeIntervalSince(anchor)
    guard elapsed < windowCycleDuration else {
        // Stale anchor — fall back
        scheduleReconnect(reason: reason)
        return
    }
    let sleepDuration = max(10, windowCycleDuration - elapsed - preWindowLeadTime)
    isInterWindowSleeping = true
    log("event=g7_ble_inter_window_sleep delay_s=\(Int(sleepDuration)) elapsed_s=\(Int(elapsed)) reason=\(reason)")
    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.isInterWindowSleeping = false
        self.startOrResume(reason: "inter_window_sleep_expired")
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + sleepDuration, execute: workItem)
}
````

**`cancelReconnect` — add `isInterWindowSleeping` reset:**
````swift
private func cancelReconnect() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    isInterWindowSleeping = false
}
````

**In `didDisconnectPeripheral`:** replace `lastSessionWasSuccess` / `postEGVBackoffWorkItem` logic:
````swift
scheduleInterWindowSleep(reason: "disconnect")
````

This call is unconditional, but `scheduleInterWindowSleep` self-falls-back to `scheduleReconnect` when no valid anchor exists (first launch) or the anchor is stale (elapsed ≥ 300s). No special-casing at the call site required.

Connect timeouts during a known inter-window gap should also call `scheduleInterWindowSleep` instead of `scheduleReconnect`.

**Foreground entry during sleep — preserve the sleep:**
````swift
func applyForegroundActiveEntry() {
    queue.async { [weak self] in
        guard let self else { return }
        self.isForegroundActive = true
        self.hasReceivedForegroundEntry = true
        self.isHardStopped = false
        if self.isInterWindowSleeping {
            self.log("event=g7_ble_lifecycle action=foreground_active_sleep_preserved")
            return  // sensor window not open; UI reads from WatchState cache
        }
        self.failedAttempts = 0
        self.startOrResume(reason: "foreground_active")
    }
}
````

Opening the watch face during an inter-window gap reads from WatchState cache. The BLE connection runs on the sensor's schedule, not on app-open events.

**Correctness checks:**
- `hardStopOnQueue` → `cancelReconnect()` cancels sleep and resets `isInterWindowSleeping` ✓
- `connectionEventDidOccur peerConnected` → `startOrResume` → `cancelReconnect()` → sleep cancelled, `isInterWindowSleeping = false`, attach ladder fires for live window ✓
- Foreground entry during sleep → no-op (sleep preserved, UI reads cache) ✓
- No anchor yet (first launch) → falls back to `scheduleReconnect` until first `peer_connected` anchors the rhythm ✓
- Stale anchor (elapsed ≥ 300s) → falls back to `scheduleReconnect` ✓
- `failedAttempts` reset to 0 in `didConnect` → exponential backoff restarts fresh after sleep-wake ✓
- `isSelfCancelling` (Task C) does not interact with sleep timer — sleep fires `startOrResume`, eventual `cancelPeripheralConnection` sets `isSelfCancelling=true`, timeout handler calls `scheduleInterWindowSleep` ✓

**Future improvement (not in build 189):** compute sleep precisely from EGV `readingDate`: `max(10, readingDate + windowCycleDuration - preWindowLeadTime - now)`. Handles sensor clock drift and late-arriving EGVs. Track as follow-up.

---

### Task D — Daily-persistent debug counters

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`, `WatchState.swift`, `Views/ComplicationDebugView.swift`

**Problem:** In-memory counters (`bleConnectsSinceLaunch`, `bleEGVsSinceLaunch`, `connectionEventsSinceLaunch`) reset on every process restart. On watchOS this is frequent — jetsam, memory pressure, charger plug-in, post-update restart. Confirmed in production: `was_restored=false` after 12-hour gap, all counters zero. The debug screen shows near-zero numbers during active sessions.

**New counter properties (replace existing in-memory ones):**
````swift
private var bleConnectsToday: Int = 0
private var bleEGVsToday: Int = 0
private var bleConnectionEventsToday: Int = 0
````

**Persistence helpers:**
````swift
private func loadDailyCounters() {
    let today = Calendar.current.startOfDay(for: Date())
    let stored = UserDefaults.standard.object(forKey: "G7BLE.countsDate") as? Date
    if let stored, Calendar.current.isDate(stored, inSameDayAs: today) {
        bleConnectsToday         = UserDefaults.standard.integer(forKey: "G7BLE.connectsToday")
        bleEGVsToday             = UserDefaults.standard.integer(forKey: "G7BLE.egvsToday")
        bleConnectionEventsToday = UserDefaults.standard.integer(forKey: "G7BLE.connectionEventsToday")
    } else {
        bleConnectsToday = 0; bleEGVsToday = 0; bleConnectionEventsToday = 0
        UserDefaults.standard.set(today, forKey: "G7BLE.countsDate")
        persistDailyCounters()
    }
}

private func persistDailyCounters() {
    UserDefaults.standard.set(bleConnectsToday,         forKey: "G7BLE.connectsToday")
    UserDefaults.standard.set(bleEGVsToday,             forKey: "G7BLE.egvsToday")
    UserDefaults.standard.set(bleConnectionEventsToday, forKey: "G7BLE.connectionEventsToday")
}
````

Call `loadDailyCounters()` in `init()`. Call `persistDailyCounters()` after each increment. Mirror to `WatchState` as before. Rename `WatchState` fields from `bleConnectsSinceLaunch` / `bleEGVsSinceLaunch` / `connectionEventsSinceLaunch` to `bleConnectsToday` / `bleEGVsToday` / `bleConnectionEventsToday`. Audit downstream consumers of these `WatchState` fields — `ComplicationDebugView` (`G7DirectBleDebugSection`) and `GlucoseTrendView` (status line) — and update all label strings and field references in both files.

**`bleWasRestored`:** persist as `UserDefaults.standard.bool(forKey: "G7BLE.wasRestored")`. Set `true` in `willRestoreState`. Reset to `false` on new-day rollover in `loadDailyCounters()`.

**UI/log consistency:** remove all "since launch" wording. Use "today" in debug section labels and in log events. Avoid mixed terminology.

---

### What is NOT in build 189

| Item | Reason excluded |
|---|---|
| `willRestoreState` reliability fixes | Not implicated in 185→188 regression; revisit if 189A fails |
| Owner mode investigation | Separate architectural track |
| Packet capture | Last-resort escalation; see 189A falsification criteria |
| Phase timing ladder / session outcome logs | Keep from build 188 |
| Consecutive failure counter, `mode_e_total`, `peripheral_id_persisted` | Keep — orthogonal observability |
| Tab layout, status line, complication `· BLE` | Keep — UI, no protocol impact |
| Precision EGV-date sleep calculation | Future improvement noted in Task B |

---

### Commit sequence for build 189

1. `fix: remove Option C; restore passive auth observer contract (Task A)`
2. `fix: restore 6s authFallbackDelay; remove auth-stage timeout (Task A)`
3. `fix: connect-in-flight guard, discovery dedupe, self-disconnect guard (Task C)`
4. `feat: connection-event-anchored inter-window sleep (Task B)`
5. `feat: daily-persistent debug counters, midnight reset (Task D)`

---

### Build 189 BetterStack validation

**189A (protocol regression):**
1. No `advanceToControl reason=auth_notify_enabled_observer`
2. `g7_ble_auth_payload_received opcode=0x05 authenticated=true bonded=true` within ~300ms of auth notify enabled
3. `control_notify_enable_requested reason=auth_authenticated_bonded`
4. `g7_ble_egv_received` within the same session
5. `session_outcome outcome=success` timing consistent with build 185
6. No `g7_ble_auth_payload_post_advance` events
7. No duplicate attach or discovery per session (Task C)

**189B (optimizations):**
8. `g7_ble_inter_window_sleep` appears after sessions; no sustained connect-timeout storms between windows
9. `g7_ble_lifecycle action=foreground_active_sleep_preserved` appears on app-open during sleep
10. Sleep cancelled correctly by `peer_connected` events; when anchor timing is stable, sleep expiry occurs with roughly 30s lead time relative to the next observed `peer_connected` anchor (correlate `inter_window_sleep_expired` against subsequent `g7_ble_connection_event_anchor` timestamps to verify)
11. Debug counters survive process restarts within the same day; no "since launch" labels

---

## Build 188 — SHIPPED & LIVE (production) ✅

Build 188 is **built, released, and live** in production. The spec sections below (Tasks A–H) are the **as-designed / as-implemented** record. **Production / BetterStack** is the locus for ongoing success-criteria and hypothesis checks (replaces ad-hoc “next morning” / overnight phrasing in older draft text).

---

## Build 187 — SHIPPED ✅

All tasks complete. Key outcomes:
- **Task A** confirmed working: `connection_events_registered reason=powered_on` fires on every process start including post-UUID-persist restarts. MOD-E is now reliable.
- **Task B** confirmed: `options: nil` on connect. Notifications suppressed.
- **Tasks E + F**: BLE counters, glanceable status line, debug screen section — all shipped.

**Build 188 resolved the former 187 “outstanding” list (all shipped, live):** debug scroll/refresh (scoped identity + 1s/10s cadence; redundant Refresh removed); horizontal chart / main / debug; single main status line; corner complication `· BLE` for `g7DirectBLE` snapshots; plus full Tasks A–H including **removal** of scan-path `registerForConnectionEvents` and the redundant `bleWasRestored` write in `centralManagerDidUpdateState` (restoration still set in `willRestoreState`).

**From build 187 (pre-188):** confirmed MOD-E at `.poweredOn` stable enough to drop the scan re-registration; redundant `bleWasRestored` in `didUpdateState` was a safe 188 removal.

---

## Build 188 scope (delivered — see Tasks A–H)

The following was the **delivery order / priority** for Build 188. All items **shipped and are live in production** (see [Implementation log (Build 188)](#implementation-log-build-188)).

1. **Auth timing fix (Option C)**  
2. **Debug screen + tab layout**  
3. **Main watch view** (single status line)  
4. **Complication** (corner `· BLE` when `source == .g7DirectBLE`)  
5. **Observability** (counters, ladder, `mode_e_total`, `peripheral_id_persisted`)  
6. **Stage timeouts** (safety net)  
7. **Housekeeping** (H1/H2)  

**Post-implementation** (same branch): code-review tweaks to session ladder `t0`, debug `.id` placement, and `connectFailureMetricCountedThisAttempt` (see implementation log table).

---

## Task A — Auth timing fix (Option C)

*Below: problem statement and spec from design time (build 187 / pre-188). **Build 188 is live;** use production / BetterStack to assess Option C and success/falsification criteria.*

**Status of current problem (historical, build 187):** G7 cycles were failing with `outcome=failure final_stage=requestingEGV` under the 6s auth fallback. The 6-second `authFallbackDelay` consumes most of the sensor's ~7-10 second session window. The EGV write lands at ~6-7s; the sensor closes at ~7-10s. Not enough margin for the response to arrive.

**Primary hypothesis (high confidence):** Reducing the time from connect to EGV write will move the write inside the window. The 6s fallback was the leading suspect. **With build 188 live,** confirm or falsify in **production / BetterStack** (see success criteria below).

**Why Option C and not A or B:**
- Option A (reduce timer to 2s): simpler but still timer-driven. An arbitrary 2s constant is still arbitrary.
- Option B (skip auth subscribe entirely): loses diagnostic visibility; slightly more aggressive toward sensor protocol expectations.
- Option C: advances on a real CB event (`auth_notify_enabled` fires at ~1s reliably), keeps auth subscription live for diagnostic and future-proofing, uses 30s as a pure watchdog.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Change 1** — Line 114, reduce watchdog delay:
````swift
private let authFallbackDelay: TimeInterval = 30  // watchdog only; primary trigger is auth_notify_enabled
````

**Change 2** — In `handleNotificationState`, in the `case G7BLEUUID.authentication:` branch, after the existing log line, add:
````swift
if characteristic.isNotifying, !hasAdvancedBeyondAuth {
    authFallbackWorkItem?.cancel()
    advanceToControl(reason: "auth_notify_enabled_observer")
}
````

**Change 3** — Add phase timestamps to `session_outcome` log. Store timestamps at key moments during the session (connect, auth_notify_enabled, control_notify_enabled, egv_write, egv_write_ack, disconnect) and emit derived intervals in the `session_outcome` log line:
````
event=g7_ble_session_outcome outcome=success ... connect_to_auth_notify_ms=950 auth_notify_to_control_ms=120 control_to_egv_write_ms=80 egv_write_to_ack_ms=45 total_ms=1195
````
This makes every future session instantly diagnosable from one log line.

**Change 4** — Log whether auth payload arrives after Option C advance. In `handleAuthPayload`, if `hasAdvancedBeyondAuth == true` when the payload arrives, log it explicitly:
````
event=g7_ble_auth_payload_post_advance opcode=0x05 authenticated=<bool> bonded=<bool>
````
This tells us whether 0x05 ever arrives on the watch (key data for the "late subscriber misses auth payload" hypothesis).

**Success criteria (verify in production / BetterStack; build 188 is live):**
- `control_notify_enable_requested reason=auth_notify_enabled_observer` appears at ~1s after connect (not ~6s)
- `session_outcome outcome=success` with `connect_to_egv_write_ms` in the 1000-2500ms range
- Repeated EGV delivery across multiple consecutive cycles — not just one

**Falsification criteria (if these occur, Option C is not the full answer):**
- `auth_notify_enabled_observer` fires at ~1s, `0x4E` goes out at ~1.5s, sessions still die before EGV reply → timing is not the only problem; something else is gating the sensor's response
- Total connect→write time is <2s but EGVs still fail → investigate control notify/write ordering or whether the observer is missing another readiness signal

**If Option C is ambiguous:** a follow-up build with just `authFallbackDelay = 2` (Option A) isolates "earlier" from "event-driven" as the benefit.

---

## Task B — Debug screen overhaul

**File:** `Trio Watch App Extension/Views/ComplicationDebugView.swift`

### B1 — Fix scroll-to-top on refresh

Remove `.id(refreshTrigger)` from the root scroll view or the top-level VStack. The `G7DirectBleDebugSection` is `@Observable`-tracked and auto-updates without forced invalidation. The `.id()` trick is only needed for the DATA STORE and LOG FILES sections which use local `@State` vars.

Apply `.id(refreshTrigger)` only to the `dataStoreStateView` and `reloadStatusView` subviews, not to the whole scroll view.

### B2 — Decouple refresh cadences

Replace the current single `.task` loop (5s for everything) with two separate loops:

````swift
// 1s cadence for snapshot/BLE values
.task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        loadSnapshot()
    }
}
// 10s cadence for log file stats (expensive on watch)
.task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        loadLogFileStats()
        refreshTrigger = UUID()  // force @State subview refresh
    }
}
````

Remove `import Combine` if it was only added for the timer.

### B3 — Remove "Refresh View" button

Remove the button from `actionsView`. The periodic refresh makes it redundant.

---

## Task C — Horizontal tab layout

**Context:** Previous implementation had chart / main / debug as horizontal swipe tabs. Current implementation is vertical scroll. Switch back to horizontal.

**Files:** Identify the top-level watch app view (likely `TrioApp.swift` or `ContentView.swift` for the watch extension) and the tab container.

**Change:** Use `TabView` with `tabViewStyle(.page)` (horizontal swipe). Order: chart (left) → main (center) → debug (right). Match the previous implementation's structure exactly — the agent should read the git history or the skipped patch to identify the prior tab container structure.

---

## Task D — Main watch view single status line

**File:** `Trio Watch App Extension/Views/GlucoseTrendView.swift` (or wherever the recency and BLE lines are rendered)

**Current state (wrong):**
- Line 1: recency (`5 min`)
- Line 2: BLE count (`BLE: 0 EGVs / 5 conn`) — different font size, separate line
- Line 3: `Phone · BLE:scan 0s` — hidden behind action button, confusing

**Target state (correct):**
- Single line: `5 min · BLE · 1/3` when `bleConnectsSinceLaunch > 0`
- Single line: `5 min` only when `bleConnectsSinceLaunch == 0` and source is not BLE
- Same font size as the current recency text
- Remove lines 2 and 3 entirely

**Format rules:**
- `[recency] · BLE · [egvs]/[conns]` when `bleConnectsSinceLaunch > 0` (regardless of source)
- `[recency] · BLE` when source is `g7DirectBLE` but `bleConnectsSinceLaunch == 0` (edge case)
- `[recency]` when source is not BLE and `bleConnectsSinceLaunch == 0`
- `bleEmphasis`: primary color when `bleEGVsSinceLaunch > 0`, secondary when `bleConnectsSinceLaunch > 0` but `bleEGVsSinceLaunch == 0`
- Drop `scan 0s` and all connection state detail entirely — not meaningful to users

---

## Task E — Complication `· BLE` second line

**Investigation required first.** Open `TrioWatchComplication.swift` and identify where the complication second line content is set. The complication template has a header and a body line — find the body line source.

Once identified:
- When `TrioComplicationDataStore.shared.latestSnapshot()?.source == .g7DirectBLE`, append `· BLE` to the second line
- Otherwise leave exactly as before
- If the second line is constructed from a function or computed property, add the conditional there

---

## Task F — Observability additions

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

### F1 — Consecutive failure counter (D1 from Phase 2 plan)

````swift
private var consecutiveConnectFailures = 0
// Reset in centralManager(_:didConnect:) alongside failedAttempts = 0
// Increment in scheduleConnectTimeout work item and in didFailToConnect
// Log: add consecutive_failures=\(consecutiveConnectFailures) to existing timeout log line
````

### F2 — `mode_e_total` log field (D2)

`connectionEventsSinceLaunch` already exists from Build 187. Add `mode_e_total=\(connectionEventsSinceLaunch)` to the existing `connection_event` log line in `connectionEventDidOccur`.

### F3 — Peripheral ID persistence log (D3)

In `handleGlucose(_:)`, immediately after `persistedPeripheralIdentifier = activePeripheral?.identifier`:
````swift
log("event=g7_ble_peripheral_id_persisted peripheral_id=\(activePeripheral?.identifier.uuidString ?? "nil") sequence=\(reading.sequence)")
````

---

## Task G — Stage-level timeouts

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Note:** Less urgent now that Option C should bring sessions to ~1-2s. Still worth having as a safety net to prevent a rogue session from draining battery.

**New property:** `private var stageTimeoutWorkItem: DispatchWorkItem?` — add to `cancelTransientTimers()`.

**Service discovery timeout (30s):** After `peripheral.discoverServices(nil)`:
````swift
let workItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .discoveringServices else { return }
    self.log("event=g7_ble_stage_timeout stage=discoveringServices")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = workItem
queue.asyncAfter(deadline: .now() + 30, execute: workItem)
````

**Auth observation timeout (10s):** When entering `observingAuth`, cancel discovery timeout and arm auth timeout. A single `stageTimeoutWorkItem` serves both — cancel and replace on stage transition:
````swift
stageTimeoutWorkItem?.cancel()
let authWorkItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .observingAuth else { return }
    self.log("event=g7_ble_stage_timeout stage=observingAuth")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = authWorkItem
queue.asyncAfter(deadline: .now() + 10, execute: authWorkItem)
````

**Additional cancellation** (beyond `cancelTransientTimers()`):
- In `handleAuthPayload` when auth gate fires and session advances past `observingAuth`
- In `peripheral(_:didDiscoverServices:error:)` when `error != nil`
- In `peripheral(_:didDiscoverCharacteristicsFor:service:error:)` when `error != nil`

**Note:** With Option C in place, `authFallbackDelay` fires at ~1s (via `auth_notify_enabled_observer`), then the 10s auth stage timeout is a backstop. These are independent timers.

---

## Task H — Housekeeping

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

### H1 — Remove redundant `bleWasRestored` write from `centralManagerDidUpdateState`

`willRestoreState` already sets `WatchState.shared.bleWasRestored = true` directly. The write in `centralManagerDidUpdateState` is redundant (for cold launches it's a no-op write of the default `false`; for restoration it duplicates `willRestoreState`). Remove it.

### H2 — Remove scan-path `registerForConnectionEvents`

Task A from Build 187 is validated. The scan-path call with the "redundant defensive call" comment is no longer needed. Remove it entirely.

---

## Commit sequence for Build 188

1. `fix: advance to control on auth_notify_enabled, 30s watchdog (Task A)`
2. `feat: phase timing ladder in session_outcome log (Task A)`
3. `feat: log auth payload arrival after Option C advance (Task A)`
4. `fix: debug screen scroll, decoupled timers, remove refresh button (Task B)`
5. `feat: horizontal tab layout chart/main/debug (Task C)`
6. `fix: main watch view single status line (Task D)`
7. `fix: complication · BLE second line (Task E)`
8. `feat: consecutive failure counter, mode_e_total, peripheral ID log (Task F)`
9. `feat: stage-level timeouts (Task G)`
10. `chore: remove redundant bleWasRestored write, remove scan-path registration (Task H)`

---

## Build 188 production / BetterStack validation (ongoing)

*Draft checklist from pre-release; with **build 188 live,** use this as a recurring pass in **BetterStack** (or equivalent) rather than a one-time “next morning” window.*

1. `connection_events_registered reason=powered_on` on every process start ✓ (Build 187; confirm it remains after 188)
2. `control_notify_enable_requested reason=auth_notify_enabled_observer` at ~1s after connect (not ~6s)
3. `session_outcome outcome=success` with `connect_to_egv_write_ms` in 1000-2500ms range
4. `post_egv_backoff_scheduled` → `post_egv_backoff_cancelled reason=connection_event` (post-EGV backoff + MOD-E)
5. `peripheral_id_persisted` (see observability / D3 intent)
6. `auth_payload_post_advance` where relevant (0x05 after advance hypothesis)
7. Consecutive EGV delivery across multiple cycles
8. Zero "accessory disconnected" system notifications (regression check vs Build 187 connect options)

---

## Confidence levels (for context, not for debate)

| Claim | Confidence |
|---|---|
| 6s fallback is harming EGV success rate | High |
| Option C will fix it | Medium-high (strong hypothesis, not proven) |
| Late subscribers miss the 0x05 auth payload | Medium |
| Private entitlement is the best-known structural long-term fix | Medium (watchOS behavior not guaranteed to match iOS exactly) |

---

## Implementation log (Build 188)

**Build 188 is shipped and live in production;** the table is the as-built record. Execution followed **Trio-dev** `docs/prompts/04-execute-implementation-plan.md` on branch **`feature/watch-g7-direct-ble-observer-synthesis`** (Trio worktree). **Pre-release** verification: static re-read; no `xcodebuild` / `ci/local-build.sh` (AGENTS.md). **Post-merge code review** adjusted ladder `t0` semantics, debug `.id` targets, and connect-failure metric deduplication (table rows and SHAs below).

| Commit / step | What was done | Files | Acceptance |
|---------------|---------------|-------|------------|
| Task A (1/3) | `authFallbackDelay = 30`; advance on `auth_notify_enabled_observer` in `handleNotificationState` | `G7DirectBLEObserver.swift` | Matches plan Option C; fallback remains watchdog-only. |
| Task A (2/3) | Phase timestamps + extended `g7_ble_session_outcome` ladder; `sessionPhaseEgvAckAt` on control EGV write ack | `G7DirectBLEObserver.swift` | Ladder uses `-1` for missing segments; `connect_to_egv_ack_total_ms` falls back to `duration_ms` when no ack. **Review fix:** `sessionPhaseConnectAt = Date()` is taken **immediately before** `centralManager.connect(…)` so `connect_to_*_ms` is connect-**attempt** → phase, not `didConnect` → phase. |
| Task A (3/3) | `g7_ble_auth_payload_post_advance` when `hasAdvancedBeyondAuth` and opcode 0x05 | `G7DirectBLEObserver.swift` | Diagnostic only; no control-flow change. |
| Task B | 1s + 10s `.task` loops; scoped `.id(refreshTrigger)` on **data store** + **log files** sections; removed **Refresh** button; root `ScrollView` not `.id`’d | `ComplicationDebugView.swift` | 10s path bumps `refreshTrigger` for `@State` log counts; **reload status** has no `.id` (reads `TrioComplicationDataStore` directly). G7 block observes `WatchState` without forced identity. |
| Task C | `TabView` order chart (0) → main (1) → debug (2); `.page`; default page 1; telemetry `newPage == 0` for chart | `TrioMainWatchView.swift` | Horizontal swipe; long-press still jumps to debug (2). |
| Task D | Single recency line with `· BLE · egvs/conns` rules and `g7DirectBLE` edge case | `GlucoseTrendView.swift` | Removed phone/BLE detail line; font matches recency. |
| Task E | `source` on `TrioWatchComplicationEntry`; `· BLE` on corner second line when `source == .g7DirectBLE`; timeline copies `source` | `TrioWatchComplication.swift` | Placeholder/fallback entries keep `source == nil` → unchanged. |
| Task F | `consecutiveConnectFailures`; `mode_e_total` on connection event (after increment); `peripheral_id_persisted` log | `G7DirectBLEObserver.swift` | **Review fix:** `connectFailureMetricCountedThisAttempt` so timeout + `didFailToConnect` for the same attempt increment **once**; counter reset in `didConnect` **and** flag cleared in `didConnect` for clarity. |
| Task G | `stageTimeoutWorkItem`: 30s discovering services, 10s observing auth; cancel in `cancelTransientTimers`, service/char errors, success paths, `advanceToControl` | `G7DirectBLEObserver.swift` | `advanceToControl` cancels auth stage timeout only **after** control characteristic guard (red-team). |
| Task H | Removed `bleWasRestored` write from `centralManagerDidUpdateState`; removed scan-path `registerForConnectionEvents` | `G7DirectBLEObserver.swift` | Restoration still set in `willRestoreState`. |
| Red-team (G) | Moved `stageTimeoutWorkItem` cancel in `advanceToControl` to after control characteristic guard | `G7DirectBLEObserver.swift` | Avoids dropping auth timeout on early return. |
| Plan doc | Implementation log (this section) + plan v1.9 in repo | `watch-g7-ble-build187-impl-plan.md` | Changelog and table capture Build 188 execution. |

**Short SHAs (Build 188 + follow-ups, 7 hex):** 937b3c5, cfea7aa, fcd21f9, e9364da, 3033f06, 49c02aa, 38397d2, b74718d, 711570a, 169c6e7, 3e124f1, ced1888, 8d49aaa, cccc747

---

## Implementation log (Build 189)

Execution per **Trio-dev** `docs/prompts/04-execute-implementation-plan.md` on branch **`feature/watch-g7-direct-ble-observer-synthesis`**. **Verification (this session):** static re-read of `G7DirectBLEObserver.swift` and related watch views; `rg` for renamed `WatchState` properties; no `xcodebuild` / `ci/local-build.sh` (AGENTS.md safety rule 10).

| Commit (short) | What was done | Files | How acceptance was checked |
|----------------|---------------|-------|----------------------------|
| a10c7e1 | Removed Option C (`advanceToControl` on `auth_notify_enabled`); passive wait comment in `handleNotificationState` | `G7DirectBLEObserver.swift` | Grep: no `auth_notify_enabled_observer` in auth branch. |
| 4de4576 | `authFallbackDelay = 6`; removed `scheduleObservingAuthStageTimeout` and its call from `configureObserverCharacteristics` | `G7DirectBLEObserver.swift` | 30s auth-only timeout removed; 6s fallback + 20s connect backstop only. |
| d789403 | `beginAttachLadder` connect-in-flight guard; `discoverServicesIfNeeded` `services == nil` dedupe → `configureObserverCharacteristics`; `isSelfCancelling` before all `cancelPeripheralConnection`, `didDisconnect` self path + `scheduleInterWindowSleep` for self-induced disconnects (see note) | `G7DirectBLEObserver.swift` | Re-read; self path schedules inter-window sleep so stage-timeout cancel still triggers a retry. |
| ab34db2 | `lastConnectionEventAt` / `g7_ble_connection_event_anchor`; `scheduleInterWindowSleep` + `scheduleReconnect` → `scheduleReconnectAfterBackoff` fallback; removed `postEGVBackoffWorkItem` / `lastSessionWasSuccess`; `applyForegroundActiveEntry` sleep preserved; `didFailToConnect` and non-self `didDisconnect` use inter-window path; connect timeout defers sleep to `didDisconnect` self path | `G7DirectBLEObserver.swift` | Re-read call graph; `cancelReconnect` clears `isInterWindowSleeping`. |
| f6e11f8 | Daily `UserDefaults` keys `G7BLE.*`; `loadDailyCounters`/`persistDailyCounters` in `init` + after increments; `bleWasRestored` in `G7BLE.wasRestored`; renames: `bleConnectsToday` / `bleEGVsToday` / `bleConnectionEventsToday` on `WatchState` and UI | `G7DirectBLEObserver.swift`, `WatchState.swift`, `ComplicationDebugView.swift`, `GlucoseTrendView.swift` | Grep: no `*SinceLaunch` for BLE fields; labels say “/ today”. |

**Deviations / follow-ups (not blockers for merge review):** Day boundary without process restart does not re-run `loadDailyCounters` (midnight in same run — could add a calendar check on foreground if needed). `scheduleInterWindowSleep` calls `cancelTransientTimers` at start (stricter than plan’s bare snippet) to match prior reconnect cleanup.

---

## Changelog

### v1.14 (2026-04-27 16:56 CEST)
- **Build 189 executed** — five ordered commits; new **Implementation log (Build 189)** table; Build 189 banner set to “code complete (not yet shipped)”. v1.13 **\[TIME\]** placeholder normalized in the replaced changelog row context.

### v1.13 (2026-04-27 16:50 CEST)
- Version bump per post-review polish pass. Task B: clarified `scheduleInterWindowSleep` unconditional call with explicit fallback note. Task B validation item 10 reworded to remove overclaim about exact timing. Task D: explicitly named `WatchState` field renames and downstream consumers (`ComplicationDebugView`, `GlucoseTrendView`). 189A acceptance criteria: added explicit "no control notify enable prior to authenticated/bonded auth payload" line. Diagnosis: tightened "before the sensor has emitted anything" to "any auth payload".

### v1.12 (2026-04-27 14:00 CEST)
- **Build 189 planned:** protocol-sequencing regression revert + session hygiene. Tasks: (A) remove Option C, restore 6s authFallbackDelay, remove 10s auth-stage timeout; (B) MOD-E-anchored inter-window sleep — records `lastConnectionEventAt` on each `peer_connected`, sleeps until 30s before next expected window regardless of EGV count (fixes bootstrap + inter-window hammering); (C) connect-in-flight guard, discovery dedupe, self-induced disconnect guard; (D) daily-persistent debug counters with midnight reset via UserDefaults. Diagnosis from BetterStack build 188 analysis: zero EGVs, two failure modes (connect-timeout storms between windows; Option C→0x4E with no EGV response), session machine churn and duplicate discovery confirmed in production.

### v1.11 (2026-04-27 13:25 CEST)
- **Build 188: built, shipped, and live in production** — banner section; 187 “outstanding” list reframed as **delivered**; “Build 188 scope” as **delivered** priority list; Task A / success / hypothesis / validation checklist reworded for **production / BetterStack** (no “tonight / next morning” draft framing); implementation log intro states **live** status. v1.8 changelog line “(tonight)” is historical **draft** wording; 188 is **released** (v1.9+ execution).

### v1.10 (2026-04-27 11:52 CEST)
- **Implementation log table** updated: Task B and Task A(2) rows match **as-built** (`.id` on data store + **log files**, not reload; `sessionPhaseConnectAt` at **`connect()`** for honest `connect_to_*` intervals); Task F row includes **deduped** connect-failure metric and **`didConnect`** flag reset; short SHA list; plan doc as its own row.
- Pointers: pair doc **`watch-g7-ble-build187-impl-log.md`** (v1.2) for narrative Build 188 notes.

### v1.9 (2026-04-27 00:44 CEST)
- **Build 188 executed:** ten plan commits + one red-team fix commit on `feature/watch-g7-direct-ble-observer-synthesis`; **Implementation log** section added above.

### v1.8 (2026-04-27)
Consolidated into Build 187 (done) + Build 188 (planned; **now shipped** — see v1.9–v1.11). Major additions:
- Auth timing fix (Option C) as highest-priority Build 188 task with full evidence, success/falsification criteria, confidence table
- Phase timing ladder added to session_outcome log (ChatGPT suggestion — high value)
- Auth payload post-advance logging (ChatGPT suggestion — key diagnostic)
- Debug screen split into 1s/10s cadences, scroll fix, remove Refresh button
- Horizontal tab layout added to scope
- Main watch view collapsed to single status line `5 min · BLE · 1/3`
- Complication investigation task added
- Housekeeping: remove redundant bleWasRestored write, remove scan-path registration call
- Status language corrected throughout per review: "primary hypothesis" not "root cause confirmed"

### v1.7 (2026-04-26)
Three small fixes: WatchState access instruction consolidated; validation wording consistent; duplicate Last BLE EGV table rows collapsed.

### v1.6 (2026-04-26)
Periodic refresh timer added to Task F. WatchState is @Observable so BLE section auto-updates; timer handles DATA STORE / LOG FILES @State vars.

### v1.5 (2026-04-26)
Seven fixes: Last BLE EGV uses dedicated WatchState properties (not latestSnapshot()); queue name corrected to `queue`; eventual consistency note; counter persistence through observer stop/restart; data race fix (capture before Task dispatch); WatchState access pattern specified; stageTimeoutWorkItem double-duty clarified.

### v1.4 (2026-04-26)
Counter ownership model clarified; Task D2 overlap fixed; Task F file targeting precise (ComplicationDebugView.swift); Task A acceptance softened.

### v1.3 (2026-04-26)
Build 187 scope explicitly acknowledged as including observer-side debug state mirroring; Task C cancellation hole fixed; bleWasRestored validation corrected; in-memory note added.

### v1.2 (2026-04-26)
Build 187/188 split. B0-B3 minimum shippable. Threading rule explicit. consecutiveConnectFailures semantics corrected. Scan-path registration preserved as redundant defense.

### v1.1 (2026-04-26)
Red team + code verification. foreground gate constraint exact. UUID constants corrected. cancelTransientTimers hook. Exact reset/increment locations for D1.

### v1.0 (2026-04-26)
Initial build 187 plan.

