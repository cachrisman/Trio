# Implementation plan: Build 187 / 188

**Version:** v1.7
**Created:** 2026-04-26
**Last updated:** 2026-04-26 15:00 CET
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`
**Predecessor:** Build 186 (B0–B3 reliability fixes)

---

## Context

Build 186 delivered B0–B3: `willRestoreState` handling, `connectInFlight` guard, `isDiscoveringServices` flag, and post-success sleep. Those are correct and stay unchanged.

**Build 187 is a validation build.** Its primary purpose is to test the MOD-E registration root-cause hypothesis. The build is kept minimal on behavior changes so the signal is unambiguous: if EGV delivery is restored after process restart with a persisted UUID, Task A is the fix. Tasks E and F (UI and debug screen) are included because they are additive and non-behavioral — they don't affect the signal from Task A and actively help with on-device validation.

**Build 188** adds the remaining behavior changes (stage timeouts, observability counters) only after Task A is validated.

**Issue summary and evidence:** `g7-ble-mode-issue-summary.md`

---

## Build 187 scope

| Task | Description | File(s) | Risk |
|---|---|---|---|
| A | `registerForConnectionEvents` in `.poweredOn` | `G7DirectBLEObserver.swift` | Very low |
| B | `CBConnectPeripheralOptionNotifyOnDisconnectionKey: nil` | `G7DirectBLEObserver.swift` | Very low |
| E | Main watch view BLE clarity | `TrioMainWatchView.swift`, `WatchState.swift` | Low |
| F | Debug screen — BLE section + remove app group ID | Debug screen file | Low |

## Build 188 scope

| Task | Description | File(s) | Risk |
|---|---|---|---|
| C | Stage-level timeouts | `G7DirectBLEObserver.swift` | Low-medium |
| D | Observability counters + peripheral ID log | `G7DirectBLEObserver.swift`, `WatchState.swift` | Very low |

---

## Build 187 scope note

**Build 187 is primarily a validation build for Task A, but it is not purely A/B in terms of observer-side code.** Task F requires adding writes to `WatchState` from inside `connectionEventDidOccur` (for `bleConnectionEventsSinceLaunch`) and `centralManagerDidUpdateState` (for `bleWasRestored`). These are observer-side code changes in the BLE path.

This is a deliberate tradeoff: the debug visibility from Task F is worth the small additional observer-side surface, and the additions are read-only state mirroring with no effect on BLE timing logic, connection behavior, or forced disconnects. Build 187 makes no changes to when or how the observer connects, disconnects, or times out — those changes belong to Build 188 (Task C).

The relevant distinction: **observer-side debug state mirroring (Build 187) vs. observer-side timing/disconnect changes (Build 188).**

---

## Threading / actor ownership rule

**All observer-originated WatchState writes must be marshalled onto the main actor.** The observer runs on a private `DispatchQueue` (BLE queue). `WatchState` properties that drive UI are `@Observable` or `@Published` and must be mutated on the main actor. The existing `noteStatus(_:)` function already demonstrates the correct pattern:

````swift
private func noteStatus(_ status: G7DirectBLEStatus) {
    Task { @MainActor in
        WatchState.shared.applyG7DirectBleStatus(status)
    }
}
````

Every new WatchState write introduced in Tasks E and F must follow this same pattern. This applies to:
- `bleConnectsSinceLaunch`
- `bleEGVsSinceLaunch`
- `bleLastConnectAt`
- `bleConsecutiveFailures`
- `bleConnectionEventsSinceLaunch`
- `bleWasRestored`

Failure to do this will cause mutations from the BLE queue to race with main-thread rendering.

---

## State flag reset requirements

**Per-session flags** (reset on `didDisconnect`, `didFailToConnect`, connect-timeout, `hardStopOnQueue`, `stop()`):
- `stageTimeoutWorkItem` (Build 188 / Task C)

**Per-manager-lifecycle observer counters** (live on the observer, reset only in `init()` — never in per-session teardown):
- `didReceiveWillRestoreState` — carried over from B0
- `connectionEventsSinceLaunch: Int` — authoritative MOD-E counter, owned by observer, incremented in `connectionEventDidOccur(.peerConnected)`
- `connectsSinceLaunch: Int` — authoritative connect counter, owned by observer, incremented in `didConnect`
- `egvsSinceLaunch: Int` — authoritative EGV counter, owned by observer, incremented in `handleGlucose`

**WatchState UI mirrors** (set via `Task { @MainActor in ... }` from observer — these are NOT authoritative counters):
- `bleConnectionEventsSinceLaunch: Int` — mirrors observer's `connectionEventsSinceLaunch`
- `bleConnectsSinceLaunch: Int` — mirrors observer's `connectsSinceLaunch`
- `bleEGVsSinceLaunch: Int` — mirrors observer's `egvsSinceLaunch`
- `bleLastConnectAt: Date?`
- `bleWasRestored: Bool`

The WatchState mirrors are in-memory only, reset to zero on process restart by definition. Do not persist them to disk.

Observer-side counters (`connectsSinceLaunch`, `egvsSinceLaunch`, `connectionEventsSinceLaunch`) are also in-memory only. They are **not cleared when the observer stops and restarts within the same process lifetime** (e.g., if `stop()` and then `start()` is called). They accumulate for the full process lifetime. If you want process-local analysis boundaries, reset them in `hardStopOnQueue` — but the current intent is full process-lifetime accumulation.

**Reset on `didConnect` success only** (NOT in every teardown — intentional accumulator):
- `consecutiveConnectFailures` (Build 188 / Task D) — measures failures across attempts until next success. Resetting on teardown would define a single-attempt counter, which is not the metric needed to test the session-duration escalation hypothesis.

---

## Build 187

### Task A — Root-cause fix: `registerForConnectionEvents` in `.poweredOn`

**Problem:** `registerForConnectionEvents` is only called inside `startScanning(reason:)`. Once a peripheral UUID is persisted after the first successful EGV, the attach ladder succeeds at `retrieved_identifier` and returns early — never reaching the scan path. MOD-E is never registered on any subsequent process start.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Code-verified placement:** The existing `.poweredOn` handler contains a hard foreground gate — `if hasReceivedForegroundEntry` — which defers `startOrResume` until the user has opened the app. `registerForConnectionEvents` must be placed before this gate so it fires unconditionally on every process start, including background state-restoration relaunches where `hasReceivedForegroundEntry` is false.

**Exact required structure** (insert between `noteStatus(.searching)` and the existing `if hasReceivedForegroundEntry` check):

````swift
case .poweredOn:
    noteStatus(.searching)
    // MUST be before hasReceivedForegroundEntry gate — registration is required
    // on every process lifetime regardless of foreground state, including
    // restoration relaunches where hasReceivedForegroundEntry is false.
    centralManager.registerForConnectionEvents(options: [
        CBConnectionEventMatchingOption.serviceUUIDs: [
            G7BLEUUID.advertisement,
            G7BLEUUID.dataService
        ]
    ])
    log("event=g7_ble_connection_events_registered reason=powered_on")
    if hasReceivedForegroundEntry {
        startOrResume(reason: "central_powered_on")
    } else {
        log("event=g7_ble_lifecycle action=central_powered_on_deferred reason=awaiting_foreground_active")
    }
````

**Do NOT remove the `registerForConnectionEvents` call from `startScanning(reason:)` in this build.** Keep it with a comment marking it as redundant defense:

````swift
// Redundant defensive call — .poweredOn is the load-bearing registration site.
// Remove after Task A is validated in build 187.
centralManager.registerForConnectionEvents(options: [...])
````

Removing it changes two things simultaneously (registration placement + number of registration sites), which weakens attribution of the fix. Remove it only in the build after Task A validation confirms the fix.

**Acceptance:**
- `event=g7_ble_connection_events_registered reason=powered_on` appears in BetterStack on every process start, including starts where `retrieved_identifier` succeeds immediately
- **Critical validation signal:** `connection_events_registered reason=powered_on` must appear even when `central_powered_on_deferred reason=awaiting_foreground_active` also appears in the same startup sequence — this proves registration is truly independent of foreground entry
- `connection_event peer_connected DXCM08` begins firing on subsequent G7 cycles after process start — not just on fresh install (the first cycle after startup may still be missed depending on timing)
- After first EGV: `post_egv_backoff_scheduled` → `post_egv_backoff_cancelled reason=connection_event` ~5 minutes later — the full healthy cycle confirmed

---

### Task B — UX fix: Suppress "accessory disconnected" notifications

**Problem:** `centralManager.connect(peripheral, options:)` passes `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true`. Every CBError 7 disconnect while backgrounded generates a watchOS system notification. 20+ notifications appeared in a single day.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Change:** Line ~319 in build 186:

````swift
centralManager.connect(peripheral, options: nil)
````

Trio handles disconnection in `centralManager(_:didDisconnectPeripheral:error:)` and does not need the OS notification.

**Acceptance:** Zero "accessory disconnected" system notifications.

---

### Task E — Main watch view: glanceable BLE status

**Problem:** The UI doesn't show whether BLE EGVs are actually being received. Connection state is visible but delivery success is not.

**Observer-side authoritative counters** (new properties on `G7DirectBLEObserver`, per-manager-lifecycle):

````swift
// On G7DirectBLEObserver — live on the observer, never on WatchState directly
private var connectsSinceLaunch = 0      // increment in didConnect
private var egvsSinceLaunch = 0          // increment in handleGlucose
````

**WatchState mirrors** — set from observer via `Task { @MainActor in ... }`:

````swift
// In WatchState — UI-facing mirrors only, not authoritative
var bleConnectsSinceLaunch: Int = 0
var bleEGVsSinceLaunch: Int = 0
````

Set by `G7DirectBLEObserver` — **capture the value before dispatching to avoid a cross-actor data race** (the Task executes on the main actor; reading `self.counter` inside it would be an unsynchronized cross-actor read):
- In `centralManager(_:didConnect:)` after `connectInFlight = false`:
  ```swift
  connectsSinceLaunch += 1
  let c = connectsSinceLaunch
  Task { @MainActor in WatchState.shared.bleConnectsSinceLaunch = c }
  ```
- In `handleGlucose(_:)` after `sessionEGVCount += 1`:
  ```swift
  egvsSinceLaunch += 1
  let e = egvsSinceLaunch
  Task { @MainActor in WatchState.shared.bleEGVsSinceLaunch = e }
  ```
This matches the existing pattern in the file (`applyG7DirectBleSnapshot` and `applyG7DirectBleStatus` are both called with self-contained values, not `self.property` references inside Task closures).

**UI display:** A single compact line below the existing recency line, shown only when `bleConnectsSinceLaunch > 0`:

```
BLE: 2 EGVs / 4 conn
```

- `bleEGVsSinceLaunch > 0`: normal text weight — working
- `bleEGVsSinceLaunch == 0` and `bleConnectsSinceLaunch > 0`: muted/secondary text — connecting but not delivering
- `bleConnectsSinceLaunch == 0`: line hidden entirely

**Files:** `G7DirectBLEObserver.swift` (increment counters), `WatchState.swift` (add properties), `TrioMainWatchView.swift` (render line)

**Acceptance:**
- After a successful EGV cycle: `BLE: 1 EGVs / 1 conn` appears below the recency line
- After failed connects with no EGV: `BLE: 0 EGVs / 4 conn` in muted style
- Before any connect: no BLE line shown

---

### Task F — Debug screen: BLE section + remove app group ID

**File:** `Trio Watch App Extension/ComplicationDebugView.swift` — the existing debug screen with sections DATA STORE, LOG FILES, RELOAD STATUS, and ACTIONS.

#### F1 — Remove app group ID section

Inside `private var dataStoreStateView`, remove the following block (lines ~120–199 in build 186):

````swift
Divider().padding(.vertical, 2)

// App Group ID Debug Section
sectionHeader("APP GROUP")

HStack { Text("AppGroupID:") ... }
HStack { Text("Container:") ... }
// and all subsequent HStacks (Container Path, Snapshot File, Container Files)
````

Keep the `HStack { Text("Path:") ... }` row immediately above this block — that is DATA STORE content, not APP GROUP.

#### F2 — Add G7 Direct BLE section

In `body`'s main VStack, add a new section after the existing RELOAD STATUS section, following the exact same pattern as existing sections:

````swift
Divider().padding(.vertical, 4)

sectionHeader("G7 DIRECT BLE")
g7BLEDebugView
````

Add a new computed property `private var g7BLEDebugView: some View` reading from `WatchState.shared`. Use the same `HStack { Text("Label:"); Spacer(); Text(value) }` pattern and `.font(.caption)` as `dataStoreStateView`.

**New WatchState properties required** (all set from observer via `Task { @MainActor in ... }`):

| Debug row label | WatchState property | Set in observer |
|---|---|---|
| Status | `g7DirectBLEStatus` (existing) | Existing `noteStatus()` |
| Last connect | `bleLastConnectAt: Date?` (new) | `centralManager(_:didConnect:)` |
| Last BLE EGV | `bleLastEGVDate: Date?` + `bleLastEGVValue: Int?` — pushed directly from observer, never inferred from `latestSnapshot()` | `handleGlucose(_:)` after successful save |
| Connects / launch | `bleConnectsSinceLaunch` (Task E) | `centralManager(_:didConnect:)` |
| EGVs / launch | `bleEGVsSinceLaunch` (Task E) | `handleGlucose(_:)` |
| MOD-E events | `bleConnectionEventsSinceLaunch: Int` (new) | `connectionEventDidOccur(.peerConnected)` |

The observer sets `bleLastEGVDate` and `bleLastEGVValue` in `handleGlucose(_:)` after the successful snapshot save, using the same capture-before-Task pattern:
```swift
let v = Int(reading.glucose)
let d = reading.readingDate
Task { @MainActor in
    WatchState.shared.bleLastEGVValue = v
    WatchState.shared.bleLastEGVDate = d
}
```
| Was restored | `bleWasRestored: Bool` (new) | `centralManagerDidUpdateState` — set from `didReceiveWillRestoreState` |

Note: `consecutiveConnectFailures` is a **Build 188 Task D** item. Do not include it here; leave a `// TODO: add consecutive failures after Build 188` comment placeholder if desired.

**Display rows:**

```
G7 DIRECT BLE
Status:             searching
Last connect:       --  or  12:34:05
Last BLE EGV:       --  or  12:34:07 · 122 mg/dL  (from bleLastEGVDate/bleLastEGVValue — never from latestSnapshot())
Connects / launch:  0
EGVs / launch:      0
MOD-E events:       0
Was restored:       No
```

Use `formatTime(_:)` (already defined in the file) for date display. Use `--` for nil/zero/distantPast values, matching the existing style.

**WatchState access pattern:** `g7BLEDebugView` reads `WatchState.shared` properties directly using standard Swift property access — no `@StateObject`, `@ObservedObject`, or `@EnvironmentObject` needed. Since `WatchState` is `@Observable`, SwiftUI auto-tracks these reads and re-renders the BLE section immediately whenever the observer pushes new values via `Task { @MainActor in ... }`.

**Periodic refresh timer:** The existing DATA STORE and LOG FILES sections use local `@State` vars loaded manually and won't auto-update from `@Observable`. Add a 5-second timer to keep all sections current — attach it alongside the existing `.onAppear`:

```swift
.onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
    loadSnapshot()
    refreshTrigger = UUID()
}
```

This gives the BLE section immediate auto-updates via `@Observable` tracking plus a periodic backstop, and keeps the existing sections fresh without the user needing to tap "Refresh View". The timer cancels automatically when the view disappears.

**Acceptance:**
- "G7 DIRECT BLE" section appears after RELOAD STATUS, before ACTIONS
- "APP GROUP" section and all its HStacks are gone
- All rows populate correctly on `.onAppear`
- `bleConnectionEventsSinceLaunch` matches BetterStack `connection_event peer_connected` count within the same process lifetime — allowing slight async lag from `Task { @MainActor in ... }` dispatch; verify after a view refresh or 5s timer tick

---

## Build 187 commit sequence

1. `fix: register connection events in .poweredOn unconditionally (Task A)`
2. `fix: suppress accessory-disconnected notification — options: nil (Task B)`
3. `feat: BLE connect/EGV counters on WatchState (Task E setup)`
4. `feat: main watch view BLE status line (Task E UI)`
5. `feat: debug screen BLE section, remove app group ID (Task F)`

---

## Build 187 validation

**Task A — the hypothesis test (evaluate first):**
- `connection_events_registered reason=powered_on` appears on every process start
- **Key proof:** `connection_events_registered reason=powered_on` appears in the same startup sequence as `central_powered_on_deferred reason=awaiting_foreground_active` — proves registration is foreground-independent
- After first EGV with persisted UUID: force-kill the app, restart it, confirm `connection_events_registered reason=powered_on` still appears and `connection_event peer_connected` fires within the next G7 cycle (~5 min)
- `post_egv_backoff_cancelled reason=connection_event` before every successful attach — MOD-E is driving

**Task B:**
- Zero "accessory disconnected" system notifications

**Tasks E and F:**
- Debug screen "G7 Direct BLE" section shows correct values
- `bleConnectionEventsSinceLaunch` matches BetterStack `connection_event peer_connected` count
- `bleWasRestored=false` on cold launches — verifiable on demand by force-killing and relaunching
- `bleWasRestored=true` when a restoration relaunch is actually observed — not a required overnight gate, since restoration relaunches are not under direct user control
- Main view `BLE: N EGVs / M conn` line visible and correct

---

## Build 188

### Task C — Stage-level timeouts

**Why deferred:** Stage timeouts introduce active forced disconnects in `discoveringServices` and `observingAuth` — exactly the phases where timing issues are being debugged. If included in Build 187, a session terminating at 30s cannot be unambiguously attributed to MOD-E fixing the attach timing vs the stage timeout cutting the failing session short.

**Problem:** No timeout exists on the `discoveringServices` or `observingAuth` phases. Trio connects to the sensor outside its re-auth window and can sit for up to ~10 minutes before CBError 7 closes the session.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**New property:** `private var stageTimeoutWorkItem: DispatchWorkItem?` — add to the existing `cancelTransientTimers()` function (which already cancels `scanTimeoutWorkItem`, `connectTimeoutWorkItem`, `authFallbackWorkItem`, `egvRequestWorkItem`, `controlWriteRetryWorkItem`). This propagates cancellation to all teardown paths since `hardStopOnQueue` calls `cancelTransientTimers()`.

**Service discovery timeout (30s):** In `discoverServicesIfNeeded`, after `peripheral.discoverServices(nil)`:

````swift
let workItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .discoveringServices else { return }
    self.log("event=g7_ble_stage_timeout stage=discoveringServices")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = workItem
queue.asyncAfter(deadline: .now() + 30, execute: workItem)  // use observer's existing `queue` symbol
````

**Auth observation timeout (10s):** When entering `observingAuth` (auth notify enabled), cancel the discovery timeout and arm the auth timeout. A single `stageTimeoutWorkItem` serves both timeouts in sequence — it is cancelled and replaced when transitioning from discovery to auth phase:

````swift
stageTimeoutWorkItem?.cancel()
let authWorkItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .observingAuth else { return }
    self.log("event=g7_ble_stage_timeout stage=observingAuth")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = authWorkItem
queue.asyncAfter(deadline: .now() + 10, execute: authWorkItem)  // use observer's existing `queue` symbol
````

**Additional cancellation required:**
- In `handleAuthPayload` (or equivalent) when the auth gate fires and the session advances past `observingAuth` — cancel `stageTimeoutWorkItem` before proceeding to enable control
- In `peripheral(_:didDiscoverServices:error:)` when `error != nil` — cancel `stageTimeoutWorkItem` before the error teardown path proceeds
- In `peripheral(_:didDiscoverCharacteristicsFor:service:error:)` when `error != nil` — cancel `stageTimeoutWorkItem` before the error teardown path proceeds

These failure callbacks precede the full teardown and `cancelTransientTimers()` call. Explicit cancellation here prevents a stale work item from firing a redundant `cancelPeripheralConnection` after teardown has already cleaned up.

**Relationship to auth fallback timer:** The 6s `auth_fallback` fires before the 10s stage timeout. These are independent timers. The stage timeout is a backstop if the fallback fires but control-enable still stalls.

**Acceptance:**
- `stage_timeout stage=discoveringServices` appears when Trio connects outside the re-auth window
- No `final_stage=discoveringServices` session outcome with `duration_ms` > 35,000
- Stage timeout does NOT fire on successful sessions (cancellation working correctly)

---

### Task D — Observability counters + peripheral ID persistence log

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

#### D1 — Consecutive failure counter

**Reset semantics:** This counter measures consecutive failures across attempts until the next successful connection. It is NOT a per-session counter and must NOT be reset in every teardown path. It resets only on `didConnect` success.

- Add `private var consecutiveConnectFailures = 0`
- Reset to 0 in `centralManager(_:didConnect:)` alongside the existing `failedAttempts = 0` reset
- Increment in two places: (1) inside the `scheduleConnectTimeout` work item closure, after the existing timeout log line; (2) in `centralManager(_:didFailToConnect:error:)` after the existing error log
- Add `consecutive_failures=\(consecutiveConnectFailures)` to the existing timeout log line

No behaviour change. Data collection only.

#### D2 — MOD-E event counter log field

The observer-side `connectionEventsSinceLaunch` counter was already added in Build 187 Task F (it drives `WatchState.bleConnectionEventsSinceLaunch` for the debug screen). Build 188 D2 only adds the log field — no new counter concept.

- In `connectionEventDidOccur` for `.peerConnected`, add `mode_e_total=\(connectionEventsSinceLaunch)` to the existing `connection_event` log line

That is the only change for D2.

#### D3 — Peripheral ID persistence log

The UUID save happens in `handleGlucose(_:)` at `persistedPeripheralIdentifier = activePeripheral?.identifier`. Add the log immediately after that line:

````swift
persistedPeripheralIdentifier = activePeripheral?.identifier
log("event=g7_ble_peripheral_id_persisted peripheral_id=\(activePeripheral?.identifier.uuidString ?? "nil") sequence=\(reading.sequence)")
````

**Acceptance:**
- `consecutive_failures` field in `connect_failed` events, correlatable with `duration_ms`
- `mode_e_total` incrementing in `connection_event` events
- `peripheral_id_persisted` appears once per fresh install after first successful EGV

---

## Build 188 commit sequence

1. `feat: stage-level timeouts for discoverServices and observingAuth (Task C)`
2. `feat: consecutive failure counter, MOD-E counter, peripheral ID log (Task D)`
3. Remove the now-redundant scan-path `registerForConnectionEvents` call (after Task A validated)

---

## What is NOT included

- B4 (MOD-E re-registration on `foreground_active`) — superseded by Task A
- Backfill (Phase C from Phase 2 impl plan) — deferred
- Watch-side glucose history store (Phase F from Phase 2 impl plan) — deferred
- WKExtendedRuntimeSession — deferred
- iPhone-side changes

---

## Open questions (do not block)

**`auth_fallback reason=no_status_reply` on every DXCM08 session:** The strict auth gate (`authenticated && bonded`) has never been observed firing on DXCM08. The fallback fires every time. Expected behaviour — Dexcom app already handled auth and Trio never receives the challenge. Not a bug; worth monitoring if sensor behaviour changes.

**`peer_connected` + `peer_disconnected` in same second:** Seen at 05:22 and 05:34 in post-reinstall data. Window opened and closed before the attach ladder could proceed. No action; Build 187's Task A (MOD-E fix) and Build 188's Task C (stage timeouts) both reduce the conditions where this matters.

---

## Changelog

### v1.7 (2026-04-26)

Three small fixes from final review.

1. **WatchState access instruction consolidated.** v1.6 had two slightly different instructions ("read directly" and "follow whatever pattern other views use"). v1.7 picks one: read `WatchState.shared` properties directly using standard Swift property access — no binding or StateObject needed. `@Observable` handles tracking automatically.

2. **Validation wording made consistent.** `bleConnectionEventsSinceLaunch` validation now uses the same "within the same process lifetime, allowing slight async lag" phrasing used for other counter validation criteria.

3. **Duplicate "Last BLE EGV" rows in Task F table collapsed.** Two rows (`Last BLE EGV` and `Last BLE EGV details`) carried the same content. Collapsed to one row with the key clarification inline: "never inferred from `latestSnapshot()`."

### v1.6 (2026-04-26)

Added periodic refresh timer to Task F. `WatchState` is `@Observable`, so the BLE section auto-updates immediately when the observer pushes new values — no timer needed for those. But the existing DATA STORE and LOG FILES sections use local `@State` vars loaded manually; a 5-second `Timer.publish` + `refreshTrigger = UUID()` keeps those fresh too. Matches the pattern used in a previous implementation of the debug screen. Timer cancels automatically on view disappear.

### v1.5 (2026-04-26)

Fourth ChatGPT review + self red-team. Seven targeted fixes.

**From ChatGPT review:**

1. **Task F "Last BLE EGV" ambiguity resolved.** Removed the `latestSnapshot()` lookup (which would return `--` if the latest snapshot is from WC/HK, not BLE). Observer now pushes dedicated `bleLastEGVDate: Date?` and `bleLastEGVValue: Int?` to WatchState directly in `handleGlucose(_:)`. The debug screen reads these properties, never `latestSnapshot()`.

2. **Task C queue name corrected.** `bleQueue` changed to `queue` throughout — the observer's actual private queue symbol confirmed at line 53 of `G7DirectBLEObserver.swift`. Added note to use the observer's existing `queue` symbol and not introduce a second queue name.

3. **Build 187 validation eventual consistency noted.** Counter validation now says "within the same process lifetime, after tapping Refresh View" — acknowledges that `Task { @MainActor in ... }` updates are asynchronous and may lag slightly behind BLE events.

4. **Counter persistence through observer stop/restart stated.** Observer counters are not cleared on `stop()`/`start()` within the same process — they accumulate for the full process lifetime. Documented with explicit note in the state flag section.

**From self red-team:**

5. **Data race in counter mirroring fixed (real hazard).** The plan had `Task { @MainActor in WatchState.shared.counter = self.counter }` — reading `self.counter` inside the Task closure is a cross-actor read without synchronization. Fixed to capture value before dispatch: `let c = counter; Task { @MainActor in WatchState.shared.counter = c }`. This matches the existing pattern in the file.

6. **WatchState access pattern in ComplicationDebugView specified.** The plan said "read from WatchState at render time" without saying how. Added note: follow whatever observation pattern other watch views use for WatchState; the existing "Refresh View" button forces a redraw that re-reads all values.

7. **Task C stageTimeoutWorkItem double-duty clarified.** Added explicit sentence: "A single `stageTimeoutWorkItem` serves both timeouts in sequence — it is cancelled and replaced when transitioning from discovery to auth phase." Prevents an agent from creating two separate properties.

### v1.4 (2026-04-26)

Fourth review (ChatGPT) identified three substantive issues and one nit. All addressed.

1. **Counter ownership model clarified.** v1.3 had a fuzzy boundary between observer-side counters and WatchState mirrors. v1.4 establishes a clear model: observer owns authoritative counters (`connectionEventsSinceLaunch`, `connectsSinceLaunch`, `egvsSinceLaunch`); WatchState holds UI-facing mirrors (`bleConnectionEventsSinceLaunch`, `bleConnectsSinceLaunch`, `bleEGVsSinceLaunch`). The reset section now separates "per-manager-lifecycle observer counters" from "WatchState UI mirrors" explicitly.

2. **Task D2 overlap fixed.** Build 187 already adds `connectionEventsSinceLaunch` on the observer (to drive the debug screen mirror). Build 188 D2 was redundantly re-adding the same counter concept. v1.4 clarifies that D2 only adds the `mode_e_total` log field to the existing `connection_event` log line — the observer counter was already established in Build 187.

3. **Task F file targeting made precise.** File is now named: `ComplicationDebugView.swift`. F1 specifies exactly which block to remove (the APP GROUP subsection inside `dataStoreStateView`, lines ~120–199, including the preceding Divider). F2 specifies the exact insertion point in `body` (after RELOAD STATUS, before ACTIONS), the computed property name (`g7BLEDebugView`), uses `formatTime(_:)` (already in the file), and uses `latestSnapshot()` (already exposed on `TrioComplicationDataStore.shared`) for last BLE EGV data.

4. **Task A acceptance nit fixed.** "fires every ~5 minutes" softened to "begins firing on subsequent G7 cycles — the first cycle after startup may still be missed depending on timing."

### v1.3 (2026-04-26)

Third review (ChatGPT) identified three substantive issues and one nit. All addressed.

1. **Build 187 scope explicitly acknowledged (user-directed).** Build 187 includes observer-side debug state mirroring from Task F (writes to WatchState in `connectionEventDidOccur` and `centralManagerDidUpdateState`), in addition to A/B. This is a deliberate tradeoff stated explicitly in a new "Build 187 scope note" section. The key distinction: debug state mirroring (Build 187) vs. timing/disconnect changes (Build 188).

2. **Task C cancellation hole fixed.** Added explicit `stageTimeoutWorkItem` cancellation in `peripheral(_:didDiscoverServices:error:)` and `peripheral(_:didDiscoverCharacteristicsFor:service:error:)` failure callbacks. These fire before full teardown; without explicit cancellation, a stale work item could fire a redundant `cancelPeripheralConnection` after teardown already cleaned up.

3. **`bleWasRestored` validation criteria corrected.** v1.2 treated `bleWasRestored=true` as a required overnight validation gate. Since restoration relaunches are not under user control, this is now correctly framed as an expected signal when observed — not a required criterion. `bleWasRestored=false` on cold launches is the verifiable gate.

4. **Task E in-memory clarification added.** Properties explicitly noted as "in-memory only — reset to zero on process restart by definition" to prevent future attempts to persist them.

### v1.2 (2026-04-26)

Second review (ChatGPT) identified four substantial issues. All four addressed, plus user adjustment (E+F included in Build 187):

1. **Build composition restructured.** v1.1 bundled A/B/C/D/E/F in one build. v1.2 splits into Build 187 (A+B+E+F — hypothesis validation + additive UI) and Build 188 (C+D — behavior changes after validation). Task C in particular introduces active forced disconnects in exactly the phases being debugged; including it in the validation build would prevent clean attribution of Task A's fix.

2. **`consecutiveConnectFailures` reset semantics corrected.** v1.1 had an internal contradiction: the per-session reset list at the top said "reset on didDisconnect, didFailToConnect, etc." while Task D1 said "reset on didConnect success only." These define two different metrics. For the escalation hypothesis, the accumulator (reset only on success) is correct. `consecutiveConnectFailures` is now explicitly excluded from the per-session reset list with the rationale stated.

3. **Threading / actor ownership rule added.** All observer-originated WatchState writes must be marshalled onto the main actor via `Task { @MainActor in ... }`. The pattern already exists in `noteStatus()`. v1.2 states this as an explicit rule with the full list of affected properties. This was a real implementation hazard, not a nit.

4. **Scan-path `registerForConnectionEvents` preserved as redundant defense in Build 187.** v1.1 said to remove it, which would change two things simultaneously (registration placement + number of sites), weakening attribution of the fix. v1.2 keeps it with a comment in Build 187 and defers removal to the Build 188 commit sequence after validation.

5. **Critical validation signal added to Task A acceptance.** `connection_events_registered reason=powered_on` must appear even when `central_powered_on_deferred reason=awaiting_foreground_active` also appears — this proves registration is foreground-independent, which is the specific property the fix depends on.

6. **User adjustment:** Tasks E and F included in Build 187 (not deferred to Build 189). Rationale: they are additive and non-behavioral — they don't affect the MOD-E signal and the debug screen is actively useful during the overnight validation run.

### v1.1 (2026-04-26)
Red team review + code verification against build 186 source. Foreground gate constraint added with exact variable name (`hasReceivedForegroundEntry`). UUID constants corrected (`G7BLEUUID` not `G7DirectBLEConstants`). `cancelTransientTimers()` identified as correct cancellation hook for Task C. Exact reset and increment locations for Task D1 specified. WatchState routing table added for Task F.

### v1.0 (2026-04-26)
Initial build 187 plan.
