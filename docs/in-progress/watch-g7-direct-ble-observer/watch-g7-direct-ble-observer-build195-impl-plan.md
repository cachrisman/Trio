# Implementation Plan: G7SensorKit watchOS Adaptation + Watch BLE Observer Rewrite

**Version:** 1.28
**Status:** Draft
**Created:** 2026-05-07 16:00 CET
**Last updated:** 2026-05-09 22:22 CET
**Design reference:** watch-direct-ble-cgm-07-g7sensorkit-watchos-design.md

---

## Scope

- Phase A: Modify G7SensorKit fork — two commits: instrumentation (A6) then watchOS gating (A2–A5)
- Phase B: Create `G7WatchSensorAdapter.swift` replacing `G7DirectBLEObserver`
- Phase C: Remove `G7DirectBLEObserver.swift` and update all call sites
- Phase D: Build verification + TestFlight + post-deploy validation

## Out of scope

- P1, P2, P6, P7 (WatchState/UI — deferred backlog)
- Backfill consumer (deferred to build 196)
- WatchConnectivity sensor name delivery changes
- Any changes to the iPhone BLE/CGM path
- HCI-level tracing

## Dependencies

- Existing G7SensorKit fork access
- G7Sensor public interface + fork telemetry API confirmed in Task A1 before writing adapter
- Existing `TrioComplicationDataStore`, `WatchState`, `WatchLogger`, `WKExtendedRuntimeSession` (unchanged)

---

## Sequencing + ship boundaries

- Phase A: G7SensorKit fork — two commits on main: A6 first, then A3/A4. After pushing, update Trio-dev/patches/02-g7-reading-time-with-seconds.patch to pin the new commit hash.
- Phase B: NOT shippable without Phase A
- Phase C: NOT shippable without Phase B
- Phase D: Ship gate

All phases are one build (build 195).

---

## Phase A: G7SensorKit fork

**Ship gate:** Safe to ship alone
**Rollback:** Revert fork changes, also revert the patch file commit in Trio-dev.


### Task A1 — Audit G7Sensor public interface + telemetry API (hard gate before Phase B)

Read-only audit. Do not proceed to Phase B without completing this.

1. Initializer signature — expect `G7Sensor(sensorID: String?)`
2. Every public method: `resumeScanning`, `stopScanning`, `scanForNewSensor` — purpose and when to call each
3. Full `G7SensorDelegate` protocol — every method, required vs optional, what triggers each
4. `CBCentralManager` restore identifier in `G7BluetoothManager` — must differ from `org.nightscout.trio.watch.g7DirectBLEObserver`
5. Threading model — which queue delegate callbacks fire on
6. Correct call sequence for cold start, foreground re-entry, graceful stop
7. **P4 check:** Does `G7BluetoothManager.centralManagerDidUpdateState` correctly cancel peripheral and clear state on `.poweredOff` / `.unauthorized`?
8. **Nil sensorID behavior:** What does `G7Sensor(sensorID: nil)` do when `resumeScanning()` is called?
9. **Telemetry API (confirmed accessible):** `emitG7Telemetry` is `internal` to the G7SensorKit module and therefore accessible from `G7BluetoothManager`, `G7PeripheralManager`, and `G7Sensor` without any new API. It already dispatches async through a dedicated serial utility queue — non-blocking by design. No new shared logger needed. Confirm this by locating `G7Telemetry.swift` in the fork and verifying `emitG7Telemetry` is declared `internal`.
10. **watchOS deployment version:** What is Trio's watch extension minimum deployment target? Use this for Task A2.

Cursor prompt:

````
Working directory: /Users/charliechrisman/Code/src/cachrisman/diabetes/G7SensorKit

Read G7Sensor.swift, G7BluetoothManager.swift, and G7PeripheralManager.swift.
For each item below, quote the relevant code. Do not make any changes.

1. Exact initializer signature(s) for G7Sensor
2. Every public method with its purpose
3. Full G7SensorDelegate protocol — every method, required vs optional, what triggers each
4. The CBCentralManager restore identifier string in G7BluetoothManager
5. Correct call sequence for: cold start, resume after foreground entry, graceful stop
6. Threading model — which queue do delegate callbacks fire on?
7. In centralManagerDidUpdateState: what happens on .poweredOff or .unauthorized?
8. What does G7Sensor(sensorID: nil) do when resumeScanning() is called?
9. Confirm emitG7Telemetry is defined as internal in G7Telemetry.swift and accessible
   from G7BluetoothManager and G7PeripheralManager without any changes.
10. What is the watchOS minimum deployment target in the Trio Xcode project?
````

Acceptance: Written answers to all 10 points before Phase B begins.

### Task A6 — G7SensorKit instrumentation (separate commit, before A2–A5)

**Ship gate:** Safe to ship alone — no logic changes
**Files:** `G7BluetoothManager.swift`, `G7PeripheralManager.swift`, `G7Sensor.swift` in fork

**Telemetry mechanism — `emitG7Telemetry` (confirmed):**
`emitG7Telemetry` is `internal` to the module and accessible from all three files. It
already dispatches async through a dedicated serial utility queue — non-blocking by design.
On iOS, Trio sets `G7Telemetry.emit` at startup to route to BetterStack. On watchOS, the
watch extension must do the same (see Task B0). Use `emitG7Telemetry` for all A6 calls —
do not use `os_log` or any other mechanism.

**Non-blocking invariant (enforced by `emitG7Telemetry` design):**
- The call itself (`emitG7Telemetry(...)`) is synchronous but returns immediately — string
  formatting and dispatch happen on the caller's thread only up to the `DispatchQueue.async` call
- Never `await` inside a BLE callback
- Never `DispatchQueue.sync` from a BLE callback
- Keep the argument string simple — avoid allocating large intermediate buffers
- **Exception:** payload hex formatting (`response.map { String(format: "%02X", $0) }.joined()`)
  is permitted only after the `response.count <= 8` guard, so the maximum allocation is 16 chars

**Prerequisites — changes to G7Telemetry.swift (same commit as A6):**

Change line 38 of `G7Telemetry.swift` in the fork:
```swift
// Before:
let formatted = "event=g7_ble_ios \(event)"
// After:
let formatted = "module=g7_core event=\(event)"
```
This namespaces all fork events as `module=g7_core`, distinguishing them cleanly from adapter
events (`module=g7_ble`) and enabling unambiguous BetterStack queries without string coincidence
matching. `g7_ble_ios` was a workaround from when G7SensorKit was iOS-only — it is now obsolete.
Update the comment on line 20 and 32 to reflect the new prefix.

**Events to add (4 groups — do NOT add suspected_end_of_session or auth_authenticated_bonded, already present):**

G7BluetoothManager.swift — `managerQueue_scanForPeripheral()` — attach path:

Actual code structure (read before adding calls):
- Path 1: `if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first`
- Path 1 miss: falls to else — no stored ID or no peripheral returned
- Path 2: `for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [...])`
- Path 3: `if activePeripheral == nil` → `scanForPeripherals` + `registerForConnectionEvents`

```
// Path 1 success (before handleDiscoveredPeripheral):
attach_path path=stored_id peripheral=<uuid> name=<name>

// Path 1 miss (start of else block, before path 2 loop):
attach_path path=miss has_identifier=<bool>

// Path 2 per peripheral (before handleDiscoveredPeripheral in loop):
attach_path path=connected_peripherals peripheral=<uuid> name=<name>

// Path 3 (before scanForPeripherals call):
attach_path path=scan
```

G7Sensor.swift — `bluetoothManager(_:didReceiveAuthenticationResponse:)` — auth_value_received
BEFORE the `AuthChallengeRxMessage` parse:
```
auth_value_received opcode=0x<hex> authenticated=<byte> bonded=<byte> payload_len=<n> payload=<hex> gate_passed=<bool>
```
`authenticated` and `bonded` are raw byte values. `payload_len=` is the total byte count;
`payload=` is the full value as uppercase hex (or `omitted` if `payload_len > 8`).
`gate_passed` is computed from `AuthChallengeRxMessage` once; the result is reused in both
the telemetry call and the if/else branch below.

`payload=` is intentionally retained. The G7 passive auth response is expected to be a 3-byte
protocol state record, typically `050101`. It is low-volume (once per connection attempt),
non-identifying, and diagnostically valuable for detecting unexpected byte values that booleans
would mask. Do not replace with a hash unless A1/A6 discovers larger or variable auth payloads.

**Payload length guard:** If `response.count > 8`, log `payload=omitted` instead of the hex
string. This caps log volume against any unexpected firmware variant with a longer response,
while preserving the diagnostic value for normal 3-byte responses.

G7Sensor.swift — `bluetoothManager(_:readied:)` — auth_notify_subscribed
AFTER `self.pendingAuth = true`:
```
auth_notify_subscribed peripheral=<uuid>
```

G7Sensor.swift — `bluetoothManager(_:didReceiveAuthenticationResponse:)` — control_notify_subscribed
AFTER `try peripheral.listenToCharacteristic(.control)` succeeds (inside do block):
```
control_notify_subscribed peripheral=<uuid>
```

Bonus fix — G7BluetoothManager.swift — CBManagerState extension copy-paste bug:
`case .poweredOn: return "poweredOff"` → `case .poweredOn: return "poweredOn"`

Acceptance:
- **No behavior changes.** Only two permitted code-structure changes: (1) CBManagerState
  description bug fix (typo), and (2) single-parse refactor of `AuthChallengeRxMessage` in
  `didReceiveAuthenticationResponse` — restructuring to call it once while keeping all existing
  branch behavior identical. No other logic or behavior changes.
- `suspected_end_of_session` and `auth_authenticated_bonded` NOT added (already present)
- All 4 new event groups present in diff
- All calls use `emitG7Telemetry` — no `os_log` or `WatchLogger` references
- Build compiles cleanly for iOS target (watchOS gating not yet applied)
- **Smoke test:** after deploying, confirm `module=g7_core event=did_connect`,
  `module=g7_core event=auth_value_received`, and `module=g7_core event=auth_authenticated_bonded`
  (or `auth_payload_ignored`) all appear in BetterStack after a real sensor connection

Cursor prompt:

````
Working directory: /Users/charliechrisman/Code/src/cachrisman/diabetes/G7SensorKit

Read G7BluetoothManager.swift and G7Sensor.swift in full before making any changes.

Add emitG7Telemetry() calls as specified. Do not modify any existing emitG7Telemetry calls.
Do not add suspected_end_of_session or auth_authenticated_bonded — both already exist.
One logic fix only: CBManagerState description bug noted at end.

emitG7Telemetry is internal to the module — call it directly. It is non-blocking.
Never await inside a BLE callback. Never DispatchQueue.sync from a BLE callback.

1. G7BluetoothManager.swift — managerQueue_scanForPeripheral() — add 4 attach_path calls:

   Inside `if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(...).first`,
   BEFORE handleDiscoveredPeripheral(peripheral):
     emitG7Telemetry("attach_path path=stored_id peripheral=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")

   At start of the else block, BEFORE the for loop:
     emitG7Telemetry("attach_path path=miss has_identifier=\(activePeripheralIdentifier != nil)")

   Inside `for peripheral in centralManager.retrieveConnectedPeripherals(...)`,
   BEFORE handleDiscoveredPeripheral(peripheral):
     emitG7Telemetry("attach_path path=connected_peripherals peripheral=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")

   Inside `if activePeripheral == nil`, BEFORE scanForPeripherals call:
     emitG7Telemetry("attach_path path=scan")

2. G7Sensor.swift — bluetoothManager(_:didReceiveAuthenticationResponse:) —
   Replace the existing auth handling with this single-parse version.
   Behavior is identical; we parse AuthChallengeRxMessage exactly once and avoid force unwrap:

     let opcode = response.first ?? 0xFF
     let authByte = response.count > 1 ? response[1] : 0xFF
     let bondByte = response.count > 2 ? response[2] : 0xFF
     let payloadHex = response.count <= 8
         ? response.map { String(format: "%02X", $0) }.joined()
         : "omitted"
     // payload_len is emitted separately as response.count
     guard let message = AuthChallengeRxMessage(data: response) else {
         emitG7Telemetry("auth_value_received opcode=0x\(String(format:"%02X",opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=false")
         emitG7Telemetry("auth_payload_ignored bytes=\(response.count)")
         log.debug("Ignoring authentication response: %{public}@", response.hexadecimalString)
         return
     }
     let gatePass = message.isAuthenticated && message.isBonded
     emitG7Telemetry("auth_value_received opcode=0x\(String(format:"%02X",opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=\(gatePass)")
     if gatePass {
         // Copy existing success-path code here (pendingAuth=false, auth_authenticated_bonded, listenToCharacteristic .control)
         // Remove only the outer if-let wrapper — all inner logic stays the same
     } else {
         emitG7Telemetry("auth_payload_ignored bytes=\(response.count)")
         log.debug("Ignoring authentication response: %{public}@", response.hexadecimalString)
     }
     // This block REPLACES the existing if-let block entirely.
     // REMOVE the old if-let (including its existing emitG7Telemetry("auth_payload_ignored") calls).
     // Before using early return: verify there is no code after the existing if-let in this function.
     // (Reading the source: the function ends immediately after the if-let — early return is safe.)

3. G7Sensor.swift — bluetoothManager(_:readied:) —
   AFTER `self.pendingAuth = true`:
     emitG7Telemetry("auth_notify_subscribed peripheral=\(peripheralID)")

4. G7Sensor.swift — bluetoothManager(_:didReceiveAuthenticationResponse:) —
   AFTER `try peripheral.listenToCharacteristic(.control)` in the do block:
     emitG7Telemetry("control_notify_subscribed peripheral=\(peripheralManager.peripheral.identifier.uuidString)")

5. G7PeripheralManager.swift — CBManagerState extension — fix copy-paste bug:
   Find: `case .poweredOn: return "poweredOff"`
   Replace with: `case .poweredOn: return "poweredOn"`
````

### Task A2 — N/A

- G7SensorKit has no Package.swift. Platform scoping for watchOS is handled via #if os(iOS) in A3/A4 only.

### Task A3 — G7CGMManagerState.swift: gate for iOS

- Wrap entire file body in `#if os(iOS)` / `#endif`
- Acceptance: `G7CGMManagerState` undefined on watchOS; both targets clean

### Task A4 — G7CGMManager.swift: gate for iOS

- Wrap entire file body in `#if os(iOS)` / `#endif`
- Verify `GlucoseDisplayable` extension on `G7GlucoseMessage` is inside this file (gated automatically)
- Acceptance: Both targets clean; no LoopKit import in any watchOS compilation unit

### Task A5 — N/A

- Standalone compile check is not possible without a Swift Package manifest. Compile verification happens via the Trio build after updating the patch file (see Task D1).


---

## Phase B: New watch adapter

**Ship gate:** Not independently shippable
**Rollback:** Delete `G7WatchSensorAdapter.swift`

### Task B0 — Set G7Telemetry.emit in watch extension startup

**Files:** Watch extension entry point (e.g. `TrioApp.swift` or `ExtensionDelegate.swift`)

`G7Telemetry.emit` is nil by default — a no-op. Trio iOS sets it at startup to route
`emitG7Telemetry` calls to BetterStack. The watch extension must do the same, or all
fork instrumentation events (Task A6) are silently dropped on watchOS.

Add at watch extension startup, before any G7SensorKit usage:

```swift
G7Telemetry.emit = { line in
    Task { await WatchLogger.shared.log(line) }
}
```

This routes fork-level telemetry (`auth_value_received`, `attach_path`, sub-phases) through
WatchLogger to BetterStack, in the same format as adapter events.

**Session ID injection (set after adapter is initialized):**

To correlate fork events with adapter session IDs, update the emit closure to inject
`g7_session=` from the adapter:

```swift
// watchOS watch extension startup
let adapter = G7WatchSensorAdapter.shared  // singleton — strong capture is correct
G7Telemetry.emit = { line in
    let sid = adapter.adapterSessionID ?? "nil"
    let sensorName = adapter.telemetrySensorName   // nonisolated(unsafe) — safe from G7Telemetry.queue
    Task { await WatchLogger.shared.log("g7_session=\(sid) sensor_name=\(sensorName) \(line)") }
}
```

The fork event already carries `module=g7_core event=<name>` from `G7Telemetry.swift`. The closure
appends `g7_session=` and `sensor_name=` so all watchOS events share the same BetterStack
pipeline and correlation fields (`g7_session=`, `sensor_name=`), regardless of module.

**iOS emit closure (update in Trio iOS at the same time):**
```swift
// Trio iOS startup — update alongside the fork change
G7Telemetry.emit = { [weak cgmManager] line in
    let sensorName = cgmManager?.sensorID ?? "nil"
    TrioLogger.shared.log("sensor_name=\(sensorName) \(line)")
}
```

On iOS there is no adapter session ID, but `sensor_name=` gives query parity with watchOS logs.

`adapterSessionID` must be declared `nonisolated(unsafe)` in the adapter (same pattern as
`lastKnownScenePhase`) since this closure runs on `G7Telemetry.queue`, not the BLE queue
or main thread. Note: strong capture of the singleton is correct — use `let adapter = G7WatchSensorAdapter.shared` before setting the closure, not `[weak adapter]`. Worst case of a torn read is a stale session ID in a log line — acceptable
for telemetry purposes.

Acceptance: `emitG7Telemetry` calls from G7BluetoothManager and G7Sensor appear in
BetterStack logs with `g7_session=` after a real sensor connection.

### Task B1 — Create G7WatchSensorAdapter.swift

#### Mandatory execution order (Cursor / agents)

**Step 0 — Before adding `G7WatchSensorAdapter.swift`:** Remove the stub `G7WatchSensorAdapter` type from `ExtensionDelegate.swift` (leave only `applicationDidFinishLaunching` and the `G7Telemetry.emit` closure that references `G7WatchSensorAdapter.shared`). If the full adapter file is added while that stub class remains in the same watch extension module, Swift fails with a duplicate type name.

**Step 1:** Add `Trio Watch App Extension/G7WatchSensorAdapter.swift` (and ensure target membership via `scripts/sync_project_files.rb` / your normal Xcode workflow — agents do not edit `project.pbxproj`).

**Step 2:** Wire foreground lifecycle to `G7WatchSensorAdapter.shared` (today still referenced from `WatchState`; Phase C removes `G7DirectBLEObserver` entirely).

#### Core structure

```swift
import CoreBluetooth
import Foundation
import WatchKit
import G7SensorKit  // watchOS-compiled post Phase A

final class G7WatchSensorAdapter: NSObject {
    static let shared = G7WatchSensorAdapter()

    private var sensor: G7Sensor
    @MainActor private var extendedSession: WKExtendedRuntimeSession?
    @MainActor private var pendingChainSession: WKExtendedRuntimeSession?
    private var heartbeatTimer: DispatchSourceTimer?
    private var expectedWindowTimer: DispatchSourceTimer?
    private var isStopped = false
    private var recoveryScheduled = false   // prevents duplicate stop() recovery dispatches
    private var bleConnectsToday: Int = 0
    private var bleEGVsToday: Int = 0
    private var sessionConnectAt: Date?
    nonisolated(unsafe) var adapterSessionID: String?   // read from G7Telemetry.queue in emit closure
    /// Read-only telemetry accessor — nonisolated(unsafe) so it is safe to call from
    /// G7Telemetry.queue without actor hopping. Reads directly from UserDefaults to avoid
    /// data races with the private knownSensorName computed property.
    nonisolated(unsafe) var telemetrySensorName: String {
        UserDefaults.standard.string(forKey: Self.sensorNameKey) ?? "nil"
    }
    private var sessionPhase: AdapterSessionPhase = .preEGV
    private var consecutivePreEGVDisconnects = 0
    private nonisolated(unsafe) var lastKnownScenePhase: String = "unknown"
    private nonisolated(unsafe) var lastKnownExtSessionActive: Bool = false

    private static let sensorNameKey = "G7WatchAdapter.sensorName"
    private static let lastEGVEpochKey = "G7WatchAdapter.lastEGVEpochKey"

    private enum AdapterSessionPhase: String {
        case preEGV  = "pre_egv"
        case postEGV = "post_egv"
    }

    private var knownSensorName: String? {
        get { UserDefaults.standard.string(forKey: Self.sensorNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sensorNameKey) }
    }

    private override init() {
        sensor = G7Sensor(sensorID: UserDefaults.standard.string(forKey: Self.sensorNameKey))
        super.init()
        sensor.delegate = self
    }

    func start() {
        stopTimers()   // idempotent: cancel any existing timers before starting new ones
        isStopped = false          // must reset before sensor guard so applyNewSensorName
        recoveryScheduled = false  // can resume scanning after a no-sensor skipped recovery
        loadDailyCountersIfNewCalendarDay()
        startHeartbeatTimer()
        guard knownSensorName != nil else {
            log("start_skipped_no_sensor")
            return
        }
        if let epoch = UserDefaults.standard.object(forKey: Self.lastEGVEpochKey) as? Int {
            reanchorExpectedWindowTimer(fromEpoch: epoch, coldStart: true)
        }
        sensor.resumeScanning()
    }

    func stop() {
        isStopped = true
        Task { @MainActor in extendedSession?.invalidate() }
        stopTimers()
        sensor.stopScanning()
    }

    func applyForegroundActiveEntry() {
        lastKnownScenePhase = "active"
        start()
        Task { @MainActor in renewSessionIfNeeded() }
    }

    func noteForegroundInactiveOrBackground(_ phase: String) { lastKnownScenePhase = phase }

    @MainActor
    private func renewSessionIfNeeded() {
        guard extendedSession?.state != .running else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        log("ext_session_renewed_on_foreground")
    }

    func applyNewSensorName(_ name: String?) {
        guard name != knownSensorName else { return }
        let wasNil = (knownSensorName == nil)
        knownSensorName = name
        sensor.stopScanning()
        sensor = G7Sensor(sensorID: name)
        sensor.delegate = self
        if !isStopped {
            sensor.resumeScanning()
            if wasNil { log("start_recovered_from_nil_sensor") }
        }
    }

    /// eventName: bare event identifier, e.g. "ext_session_chain_started"
    /// fields: additional key=value pairs, e.g. "reason=not_active scene=background"
    private func log(_ eventName: String, _ fields: String = "") {
        let sid = adapterSessionID ?? "nil"
        let sensorName = knownSensorName ?? "nil"
        let suffix = fields.isEmpty ? "" : " \(fields)"
        Task { await WatchLogger.shared.log("module=g7_ble event=\(eventName) g7_session=\(sid) sensor_name=\(sensorName)\(suffix)") }
    }
}
```

#### Thread safety

- `extendedSession` declared `@MainActor` — all reads/writes via `Task { @MainActor in ... }` or `await MainActor.run { ... }` from non-main contexts
- `pendingChainSession` declared `@MainActor` — all WKExtendedRuntimeSessionDelegate callbacks are main-thread; timeout `asyncAfter` dispatched to main queue
- The `WKExtendedRuntimeSessionDelegate` conformance extension must itself be `@MainActor` so Swift's strict concurrency allows synchronous access to `@MainActor` properties within delegate methods:
```swift
@MainActor
extension G7WatchSensorAdapter: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) { ... }
    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) { ... }
    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) { ... }
}
```
Without `@MainActor` on the extension, Swift will reject synchronous access to `extendedSession`
and `pendingChainSession` inside these methods even though WatchKit calls them on the main thread.
- `nonisolated(unsafe)` for scene-phase/ext-session bool: acceptable unsynchronized reads for telemetry-only use

#### H4 bug fix — stop() on natural expiry (confirmed)

```swift
func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                             didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                             error: Error?) {
    lastKnownExtSessionActive = false
    let hasError = (error != nil)
    log("ext_session_did_invalidate", "reason=\(reason.rawValue) has_error=\(hasError)")

    // Identity check FIRST — unconditionally, regardless of error.
    // Old session fires didInvalidateWith naturally after willExpire; must not be
    // misclassified as a chain denial or trigger teardown.
    if session === pendingChainSession {
        pendingChainSession = nil
        log("ext_session_chain_denied", "has_error=\(hasError)")
        return  // Never stop() on chain denial
    }

    if hasError {
        log("ext_session_unexpected_invalidation", "triggering_teardown=true")
        stop()
        // Guarded recovery: only one delayed restart scheduled at a time.
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        // Task { @MainActor } guarantees actor isolation — DispatchQueue.main.asyncAfter
        // does not satisfy Swift strict concurrency for @MainActor property access.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            guard self.lastKnownScenePhase == "active" else {
                self.log("recovery_skipped", "reason=not_active scene=\(self.lastKnownScenePhase)")
                self.recoveryScheduled = false
                return
            }
            self.log("post_stop_recovery_attempt")
            self.start()   // start() resets isStopped=false and recoveryScheduled=false
        }
    } else {
        log("ext_session_natural_or_unknown_expiry")
    }
}
```

#### H1 — session chaining (best-effort hypothesis, unverified)

```swift
func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
    lastKnownExtSessionActive = false
    log("ext_session_will_expire")
    let newSession = WKExtendedRuntimeSession()
    newSession.delegate = self
    pendingChainSession = newSession
    extendedSession = newSession   // assign BEFORE start() — eliminates identity race
    newSession.start()
    log("ext_session_chain_attempted")
    // 10s timeout: if watchOS silently drops start() with no callbacks, clear state.
    // Task { @MainActor } guarantees actor isolation for @MainActor property access.
    Task { @MainActor [weak self, weak newSession] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let self, let newSession else { return }
        if self.pendingChainSession === newSession {
            self.pendingChainSession = nil
            self.log("ext_session_chain_timeout")
        }
    }
}

func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
    lastKnownExtSessionActive = true
    if session === pendingChainSession {
        pendingChainSession = nil
        log("ext_session_chain_started")
    } else {
        log("ext_session_started")
    }
}
```

#### P3 fix — complication snapshots

All `TrioComplicationSnapshot` calls must have `state: nil`.

#### P4 — BT power state

If Task A1 confirms G7BluetoothManager handles `poweredOff` correctly: no adapter code needed.
If not: fork change required.

#### P10 — Trend arrow mapping

Use `G7GlucoseMessage` trend output directly. Do not re-implement.

#### G7SensorDelegate implementation

Per design doc delegate behavior table.
- `sensor(_:didDiscoverNewSensor:activatedAt:)` → always return `false`
- Never call `scanForNewSensor()` anywhere in the adapter
- `sensor(_:logComms:)` → no-op (hex dump; not needed by watch adapter)
- `sensor(_:didReceive:)` → no-op (extended version; not needed by watch adapter)

#### Telemetry — implemented from scratch

**Session ID** — `adapterSessionID = UUID().uuidString` set in `sensorDidConnect`,
cleared in `sensorDisconnected`. Propagated via `log()` helper as `g7_session=`.

**`g7_ble disconnect`** — `phase=`, `since_did_connect_s=`, `had_egv=`, `session_duration_s=`.

**`g7_ble auth_failed_inferred`** — when `sensorDisconnected` fires with `sessionPhase == .preEGV`:
```swift
if sessionPhase == .preEGV {
    consecutivePreEGVDisconnects += 1
    log("auth_failed_inferred", "since_connect_s=\(sinceConnectS) consecutive_count=\(consecutivePreEGVDisconnects)")
} else {
    consecutivePreEGVDisconnects = 0
}
sessionPhase = .preEGV  // reset for next session
```

**Stale sensor detection + fallback re-init:**
```swift
// After incrementing consecutivePreEGVDisconnects:
if consecutivePreEGVDisconnects >= 3 {
    log("stale_sensor_binding_suspected", "consecutive_pre_egv_disconnects=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceLastEGV)")
}
if consecutivePreEGVDisconnects >= 5 {
    log("stale_sensor_reinit", "count=\(consecutivePreEGVDisconnects)")
    consecutivePreEGVDisconnects = 0
    sensor.stopScanning()
    sensor = G7Sensor(sensorID: knownSensorName)  // same name, fresh CB state
    sensor.delegate = self
    sensor.resumeScanning()
}
```

**`g7_ble egv_received`** — `scene_phase=`, `ext_session_active=`, `sequence=\(message.sequence)`,
`glucose=\(message.glucose ?? -1)`. On first reliable glucose of session, also emit
`time_to_first_egv_ms=`. `sequence=` enables cross-referencing against fork `g7_core egv_received`
events for the same reading; `glucose=` provides a redundant sanity check alongside the fork value.

**`heartbeat`** — 5-min timer. `ext_session_active=`, `ext_session_state=`.
Read `extendedSession?.state` inside `await MainActor.run`.

**`expected_window`** — independent 5-min timer, phase-locked to EGV epochs.

Timer lifecycle:
- NOT cancelled by `sensorDisconnected` (normal BLE disconnect) — runs continuously across reconnect cycles
- Cancelled by `stop()` (error teardown only) — restored by the `start()` call in the recovery path
- `start()` calls `stopTimers()` first, so re-entry is idempotent

Anchoring algorithm — on each `egv_received`:
```swift
var nextEpoch = lastEGVEpoch + 300
let nowEpoch = Int(Date().timeIntervalSince1970)
while nextEpoch < nowEpoch {
    emitExpectedWindowTick(epoch: nextEpoch, retroactive: true)
    nextEpoch += 300
}
let delay = max(1.0, Double(nextEpoch) - Date().timeIntervalSince1970)
scheduleWindowTick(deadline: .now() + delay, nextEpoch: nextEpoch)
```
On cold start: cap retroactive emission at **50 ticks max** — emit only the 50 most
recent missed epochs. A clock jump (NTP, DST, resume from deep sleep) could otherwise
emit hundreds of events instantly even with a 24h window.
On each tick reschedule: run same catch-up loop to handle suspension gaps.

#### Acceptance criteria

- Compiles for watchOS target, zero errors
- All 9 `G7SensorDelegate` methods implemented, including `logComms` and `didReceive`.
- `G7CGMManager` not imported or referenced
- `scanForNewSensor()` does not appear anywhere in the file
- All complication snapshots have `state: nil`
- `didInvalidateWith` with `error == nil` does NOT call `stop()`
- `pendingChainSession` declared `@MainActor`
- `extendedSession` assigned before `newSession.start()` in `willExpire`
- `chain_started` / `chain_denied` / `chain_timeout` log events present and identity-correct
- `auth_failed_inferred` emitted when `sessionPhase == .preEGV` at disconnect; NOT on `.postEGV`
- `recoveryScheduled` guard prevents duplicate delayed restarts
- `start()` calls `stopTimers()` before `startHeartbeatTimer()`
- `expected_window` timer NOT cancelled by `sensorDisconnected`; IS cancelled by `stop()`
- `g7_session=` in every watchOS log line (injected by log() helper for adapter events,
  by B0 emit closure for fork events; iOS fork events carry `sensor_name=` only)
- Trend arrow logic not re-implemented
- After a `recovery_skipped` (scene not active), calling `applyForegroundActiveEntry()` must
  successfully call `start()` and clear `recoveryScheduled = false`. This is ensured by the
  existing design (`start()` resets `recoveryScheduled`) — verify in code review, not runtime.

### Task B2 — Daily counters and WatchState mirroring

- Port counter logic from `G7DirectBLEObserver` exactly
- Increment connect counter in `sensorDidConnect`
- Increment EGV counter in `sensor(_:didRead:)` when `hasReliableGlucose`
- Acceptance: `WatchState.shared.bleConnectsToday` and `bleEGVsToday` correct after one cycle

---

## Phase C: Remove G7DirectBLEObserver + wire callers

**Ship gate:** Not independently shippable

### Task C1 — Audit all call sites

- Search watch extension for `G7DirectBLEObserver`; list every file, line, method
- Acceptance: Complete list before any changes

### Task C2 — Update call sites to G7WatchSensorAdapter.shared

- Replace all references; wire `applyNewSensorName(_:)` in WC handler
- Acceptance: Zero remaining references to `G7DirectBLEObserver`

### Task C3 — Delete G7DirectBLEObserver.swift

- Remove from Xcode project
- Acceptance: Build succeeds, no orphaned references

---

## Phase D: Build verification + TestFlight

### Task D1 — Local build verification

- Clean build both targets; no LoopKit in watchOS compilation units; zero new warnings

### Task D2 — TestFlight deploy

- Follow standard patch-stack workflow

### Task D3 — Post-deploy BetterStack validation (24h soak)

**Smoke test (run immediately after first sensor connection, before 24h soak):**
Confirm the following events appear in BetterStack within minutes of a G7 connection:
- `module=g7_core event=did_connect` — fork instrumentation routing confirmed
- `module=g7_core event=auth_value_received` — A6 event present
- `module=g7_core event=auth_authenticated_bonded` OR `auth_payload_ignored` — gate event present
- `module=g7_ble event=egv_received` — adapter routing confirmed
- `g7_session=` and `sensor_name=` present in all watchOS lines

If any of these are absent, do not proceed to the 24h soak — diagnose the telemetry routing first.

**Primary — auth reliability:**

```sql
SELECT
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=did_connect%') AS did_connects,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=auth_authenticated_bonded%') AS auth_successes,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=auth_payload_ignored%') AS auth_failures,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=egv_received%') AS egvs,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=ext_session_unexpected_invalidation%') AS unexpected_invalidations,
    -- Primary: auth_authenticated_bonded / did_connect (same metric as build 194 baseline)
    round(countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=auth_authenticated_bonded%') * 100.0 /
          nullIf(countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=did_connect%'), 0), 1)
    AS auth_rate_pct,
    -- Secondary proxy (cross-check from adapter)
    round((1 - countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=disconnect%'
                       AND JSONExtractString(raw, 'message') LIKE '%phase=pre_egv%') * 1.0 /
           nullIf(countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=did_connect%'), 0)) * 100, 1)
    AS auth_proxy_rate_pct
FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE JSONExtractString(raw, 'platform') = 'watchos'
    AND JSONExtractString(raw, 'build') = '195'
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND JSONExtractString(raw, 'platform') = 'watchos'
    AND JSONExtractString(raw, 'build') = '195'
)
```

Primary: `auth_rate_pct = auth_authenticated_bonded / did_connect` — identical metric to
build 194 baseline (59%). Target: ≥ 75%. `auth_proxy_rate_pct` is a cross-check from the
adapter-side `phase=pre_egv` signal — should agree within a few percent.
`unexpected_invalidations = 0`. Note: `egvs` filtered to `module=g7_core` to count fork events
only (excludes adapter's `egv_received` which has different fields).

**Metric divergence guard:** If `auth_rate_pct`, `auth_proxy_rate_pct`, and
`auth_value_received gate_passed / did_connect` diverge by more than 5 percentage points,
treat the telemetry as suspect before drawing conclusions. Likely causes: instrumentation
placement bug in A6, double-counting, or `module=` prefix mismatch.

**Event ordering caveat:** Fork and adapter events are emitted asynchronously through
separate queues. Log order in BetterStack does not reliably reflect protocol order.
Correlate events by `g7_session=` + timestamp — never by strict log sequence.
Both `module=g7_core` and `module=g7_ble` events carry `g7_session=` (injected by the emit closure on watchOS).

**EGV opportunity success rate:**
```sql
SELECT
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=egv_received%') AS egvs,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=expected_window%'
            AND JSONExtractString(raw, 'message') LIKE '%eligible=true%') AS eligible_windows,
    round(countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=egv_received%') * 100.0 /
          nullIf(countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=expected_window%'
                         AND JSONExtractString(raw, 'message') LIKE '%eligible=true%'), 0), 1)
    AS egv_success_rate_pct
FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE JSONExtractString(raw, 'platform') = 'watchos'
    AND JSONExtractString(raw, 'build') = '195'
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND JSONExtractString(raw, 'platform') = 'watchos'
    AND JSONExtractString(raw, 'build') = '195'
)
```

**Overnight dead zone check:**
```sql
SELECT toStartOfHour(dt) AS hour,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=egv_received%') AS egvs,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_core event=did_connect%') AS connects,
    countIf(JSONExtractString(raw, 'message') LIKE '%module=g7_ble event=ext_session%') AS session_events
FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE JSONExtractString(raw, 'platform') = 'watchos' AND JSONExtractString(raw, 'build') = '195'
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND JSONExtractString(raw, 'platform') = 'watchos'
    AND JSONExtractString(raw, 'build') = '195'
)
GROUP BY hour ORDER BY hour ASC
```
Look for hours with `egvs = 0` and `connects = 0`. Report any such hour.
Improvement desired. Not a release blocker.

---

## Risks & mitigations

**CBCentralManager restore identifier conflict** — Checked in Task A1 item 4.

**G7SensorDelegate queue** — All callbacks on BLE queue. Adapter dispatches WatchState
and session calls to appropriate queues.

**G7Sensor cold-start entry point** — Confirmed in A1. Hard gate.

**`willExpire` session chaining viability** — Unverified Apple API use. Instrumented with
`chain_started` vs `chain_denied`. H4 fix (no stop() on natural expiry) confirmed regardless.

**Fork instrumentation timing** — Mitigated by `emitG7Telemetry` design: all A6
calls dispatch async through a serial utility queue — non-blocking on BLE callback paths
by construction. No sync dispatch, no awaiting.

**`emitG7Telemetry` backpressure** — Expected event volume is low (a handful per connection
cycle every few minutes). The serial utility queue drains near-instantly given the emit
closure cost. No backpressure mechanism is implemented; revisit if BetterStack telemetry
queue backlog is observed in practice.

**Duplicate timer start** — Mitigated by `start()` calling `stopTimers()` first.

**Duplicate recovery dispatch** — Mitigated by `recoveryScheduled` guard.

---

## Hypotheses / expectations (NOT acceptance criteria)

- The 40% auth failure rate is caused by protocol-level divergences. Replacing with G7Sensor
  should materially improve `auth_rate_pct` (auth_authenticated_bonded / did_connect) and
  `egv_success_rate_pct` (adapter egvs / eligible expected_window ticks).

- **H4:** Confirmed fixable. Measured by `unexpected_invalidations = 0` in build 195 logs.

- **H1:** Evaluated by `chain_started` events at 1-hour intervals and overnight diagnostic query.
  Not confirmed until build 195 data shows chaining succeeds.

- **H2/H5:** G7Sensor's persistent connection management hypothesized to improve background EGV
  delivery. Confirmed by `egv_success_rate_pct` vs build 194's ~20% overnight rate.

- `auth_value_received gate_passed` from fork instrumentation will reveal what the sensor was
  sending during the 40% auth failure cycles — diagnostic reference for HCI tracing if needed.

---

## Deferred backlog (not build 195)

| Bug | Files | Fix direction |
|-----|-------|--------------|
| P1: BLE readings shown stale when phone unreachable | TrioMainWatchView, WatchState | Drive staleness from `bleLastEGVDate` age when `source == .g7DirectBLE` |
| P2: Phone glucose shown fresh when CGM is stale | WatchState, AppleWatchManager | Drive staleness from `reading_epoch` / CGM sample timestamp |
| P6: Same-sequence dedup blocks phone delta | WatchState | Allow same-sequence updates when incumbent has missing display fields |
| P7: WC retry loop has no backoff | WatchState+Requests | Bounded exponential backoff; cancel on backgrounding; use `sessionReachabilityDidChange` |

---

## Changelog

| Version | Date | Notes |
|---------|------|-------|
| 1.28 | 2026-05-09 22:22 CET | Task B1: mandatory Step 0 — delete stub `G7WatchSensorAdapter` from `ExtensionDelegate.swift` before adding real adapter file (avoids duplicate-class compile error); note sync/project workflow |
| 1.27 | 2026-05-09 20:35 CET | Clean up payloadHex comment in Cursor prompt — remove interpolation from code block |
| 1.26 | 2026-05-09 15:17 CET | Replace DispatchQueue.main.asyncAfter with Task { @MainActor } + Task.sleep for actor-safe delayed closures |
| 1.25 | 2026-05-09 15:17 CET | Fix payloadHex omitted_len→omitted; fix hypotheses metric names; clarify g7_session= scope to watchOS only |
| 1.24 | 2026-05-09 15:17 CET | WKExtendedRuntimeSessionDelegate conformance must be in @MainActor extension — compile blocker |
| 1.23 | 2026-05-09 15:17 CET | Fix payloadLen undefined in Cursor prompt — replace with response.count directly |
| 1.22 | 2026-05-09 15:17 CET | Fix attach_path event names (path= field); bytes= → payload_len= in Cursor prompt; Swift escape fix; A6 acceptance wording; os_log → emitG7Telemetry |
| 1.21 | 2026-05-09 15:17 CET | Fix 5 blockers + 11 should-fixes: telemetrySensorName; log() call sites; start() guard ordering; query namespace; auth_payload_ignored; EGV/overnight queries; payload_len=; A6 string note; B0 wording |
| 1.20 | 2026-05-09 15:17 CET | Fix Cursor prompt — guard let single-parse, no force unwrap, payload length guard in code |
| 1.19 | 2026-05-09 15:17 CET | Apply missed red-team issues 1,2,3,5,9,12: A6 acceptance wording; guard let single-parse; payload >8 guard; date fix; recovery foreground acceptance; D3 smoke test |
| 1.18 | 2026-05-09 15:17 CET | module=g7_core/g7_ble log format; log() helper signature split; iOS emit closure; sensor_name= throughout; strong singleton capture in B0; updated queries to module= |
| 1.17 | 2026-05-09 15:17 CET | Strip g7_ble_ prefix from all adapter log() message strings; fix validation query filters |
| 1.16 | 2026-05-09 15:17 CET | event=g7_core prefix; sensor name injection; sequence= on egv; payload= rationale; recovery lifecycle gate; 50-tick cap; divergence guard; ordering caveat; backpressure note |
| 1.15 | 2026-05-08 06:10 CET | Rewrite A6 events to match actual code; add payload= to auth_value_received; restore auth_authenticated_bonded as primary validation metric; session ID injection to B0 with nonisolated(unsafe); adapterSessionID nonisolated(unsafe) |
| 1.14 | 2026-05-08 06:10 CET | A6 uses emitG7Telemetry (confirmed); revert auth_value_received to raw bytes; add Task B0 for G7Telemetry.emit watch startup; update A1 cursor prompt item 9 |
| 1.13 | 2026-05-08 06:10 CET | Non-blocking fork telemetry requirement; shared telemetry API in A1/A6; byte_count rename; @MainActor pendingChainSession; recoveryScheduled guard; start() calls stopTimers() first; expected-window timer invariant; success criteria updated to proxy metrics; A1 cursor prompt item 10 |
| 1.12 | 2026-05-08 06:10 CET | Add Task A6 G7SensorKit instrumentation; fix version numbering (2.x → 1.1x) |
| 1.11 | 2026-05-07 23:48 CET | Post-stop() recovery; pendingChainSession timeout; fallback re-init; overnight target wording; time_to_first_egv_ms + session_duration_s |
| 1.10 | 2026-05-07 23:44 CET | Nil sensor start recovery; extendedSession assignment before start(); catch-up loop |
| 1.9 | 2026-05-07 23:21 CET | pendingChainSession identity; renewSessionIfNeeded; start() nil guard; 24h tick cap |
| 1.8 | 2026-05-07 23:21 CET | pendingChainAttempt unconditional check; window timer anchoring; @MainActor extendedSession |
| 1.7 | 2026-05-07 22:07 CET | Fix acceptance criteria; conservative teardown; two-ratio metrics |
| 1.6 | 2026-05-07 22:07 CET | Fix phase enum; pendingChainAttempt; didInvalidateWith by reason; overnight = diagnostic only |
| 1.5 | 2026-05-07 21:52 CET | H4 confirmed, H1 hypothesis; chain telemetry; auth_failed_inferred; stale sensor detection |
| 1.4 | 2026-05-07 21:52 CET | One build; renumber to A–D |
| 1.3 | 2026-05-07 19:00 CET | Fix telemetry framing |
| 1.2 | 2026-05-07 18:30 CET | Add P3/P4/P10; H4/H1/P8; H2/H5; deferred backlog |
| 1.1 | 2026-05-07 17:30 CET | Initial telemetry phase; renumber |
| 1.0 | 2026-05-07 16:00 CET | Initial |