import Foundation
import G7SensorKit
import WatchKit

/// Thin watch-specific wrapper around `G7Sensor` (build 195). Replaces `G7DirectBLEObserver` BLE stack;
/// sensor identity and daily counters remain compatible with existing App Group / WatchState keys.
///
/// **Peripheral match / `suffix(2)`:** There is no `attachIntent` symbol in G7SensorKit. Dexcom advertising names are
/// accepted in `G7Sensor.bluetoothManager(_:shouldConnectPeripheral:)` (`G7SensorKit/.../G7Sensor.swift`): when
/// `sensorID` is set, connection uses `name.suffix(2) == sensorName.suffix(2)`; when nil, `.connect` for DXCM/DX02.
/// Watch adapter mirrors the phone (`G7CGMManager`): one `G7Sensor` per process; identity changes go through
/// `sensor.scanForNewSensor()` and `didDiscoverNewSensor` (name-gated) instead of reconstructing the sensor.
///
/// **Discovery:** `didDiscoverNewSensor` returns `true` only when the discovered peripheral's name suffix matches
/// `expectedSensorName` (phone-pushed via WC). With no expected name, all discoveries are rejected.
@MainActor
final class G7WatchSensorAdapter: NSObject {
    static let shared = G7WatchSensorAdapter()

    /// One `G7Sensor` instance per process. Mirrors `G7CGMManager` on the phone: identity changes
    /// happen via `sensor.scanForNewSensor()` (clears the sensor's internal `sensorID` and starts a
    /// new scan), not by reconstructing this reference. Reconstructing leaked CBCentralManager state.
    private let sensor: G7Sensor

    /// Name of the peripheral the live `G7Sensor` is currently bound to. Tracks the sensor's
    /// internal `sensorID` (which is `private` on `G7Sensor`) by being set in `sensorDidConnect`
    /// and cleared whenever we call `sensor.scanForNewSensor()`. Exposed for debug UI.
    private(set) var boundSensorName: String?

    /// Transient flag set by `initiateScanForNewSensor()`; cleared either by the next
    /// `handleSensorDisconnected` (when the rescan triggers a downstream disconnect) or by a
    /// 2s auto-clear (when no downstream disconnect comes — e.g., we weren't connected). The
    /// disconnect handler reads this to skip the pre-EGV counter increment for self-inflicted
    /// disconnects (sensor swap, EOS teardown, stale-binding rebind).
    private var isScanningForNewSensor = false

    private var extendedSession: WKExtendedRuntimeSession?
    private var pendingChainSession: WKExtendedRuntimeSession?
    /// Session for which `start()` was called but `extendedRuntimeSessionDidStart` has not yet run.
    /// `extendedSession` is assigned **only** in `extendedRuntimeSessionDidStart` so it always refers to a started session.
    private var sessionPendingDidStart: WKExtendedRuntimeSession?

    /// Identities of `WKExtendedRuntimeSession`s that the adapter intentionally invalidated and
    /// whose `didInvalidateWith` callback has not yet been delivered. The delegate consults this
    /// set at the top of `extendedRuntimeSession(_:didInvalidateWith:)` and short-circuits with an
    /// `ext_session_intentional_invalidation` log if the incoming `session` matches, so a stale
    /// invalidation callback from a session we already tore down cannot fall through to the
    /// `stop()` call in the error branch and clobber a freshly-requested `sessionPendingDidStart`.
    ///
    /// Insertion sites — every place we call `invalidate()` on a session we owned must add the
    /// session's `ObjectIdentifier` here first:
    ///   1. `stop()` — when tearing down `extendedSession`, `pendingChainSession`, `sessionPendingDidStart`.
    ///   2. `extendedRuntimeSessionWillExpire` — when displacing a prior `pendingChainSession` /
    ///      `sessionPendingDidStart` ahead of a new chain attempt.
    ///   3. The chain-attempt timeout in `extendedRuntimeSessionWillExpire` — when the 10s
    ///      timeout fires and we invalidate the never-started chain session.
    ///   4. `extendedRuntimeSessionDidStart` — when an unexpected old `extendedSession` is
    ///      replaced (the `ext_session_replaced_unexpectedly` path).
    ///
    /// Removal sites: the early-return in `extendedRuntimeSession(_:didInvalidateWith:)`
    /// (consumes the entry) and a defensive `remove` in `extendedRuntimeSessionDidStart`
    /// (keeps the set bounded if a session somehow started despite being marked for invalidation).
    private var invalidatingSessionIDs = Set<ObjectIdentifier>()

    /// Read-only accessor for the currently started extended runtime session.
    ///
    /// The adapter may replace this reference from several paths (`stop()`,
    /// `renewSessionIfNeeded()`, chain inside `extendedRuntimeSessionWillExpire`), so callers
    /// must re-query on every use — never cache the returned reference.
    var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }

    /// Read-only mirror of the adapter's authoritative `isStopped` flag.
    ///
    /// Use this instead of `WatchState.shared.g7DirectBleStatus == .off` when an external
    /// subsystem needs to know whether the adapter was intentionally stopped. The published
    /// status mirror defaults to `.off` at cold start (until `publishConnectionStatus()` runs)
    /// and would falsely report "stopped" before the first BLE event. `isStopped` is mutated
    /// only by `start()` (false) and `stop()` (true), so this accessor reflects intentional
    /// lifecycle exactly.
    var isIntentionallyStopped: Bool { isStopped }

    // MARK: - Debug-UI accessors

    /// Current pre-EGV disconnect streak count (for `ComplicationDebugView`).
    var consecutivePreEGVDisconnectsCount: Int { consecutivePreEGVDisconnects }

    /// Human-readable description of `extendedSession.state` ("notStarted", "running", "invalid")
    /// or "nil" when no session is held. Use alongside `extSessionLastKnownActive` for diagnosis.
    var extSessionState: String {
        if let s = extendedSession {
            return String(describing: s.state)
        }
        return "nil"
    }

    /// Whether the adapter last observed an active extended runtime session. Fallback signal for
    /// debug UI when `extendedSession.state` is not informative (e.g. session reference cleared
    /// during teardown).
    var extSessionLastKnownActive: Bool { lastKnownExtSessionActive }

    /// Whether a chain-renewal `WKExtendedRuntimeSession` is currently awaiting `didStart`.
    var hasPendingChainSession: Bool { pendingChainSession != nil }

    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.g7WatchAdapter.timers", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var expectedWindowTimer: DispatchSourceTimer?
    private var expectedWindowNextEpoch: Int?

    private var isStopped = false
    /// `start()` re-entry gate. Set true on entry to `start()`, cleared in `stop()`. Replaces the
    /// previous `sensor.isConnected` check (which crossed `bluetoothManager.managerQueue.sync`).
    /// Multiple foreground re-entries collapse into a single setup pass per stop/start cycle.
    private var isStarted = false
    private var recoveryScheduled = false
    /// `start()` idempotency flag. Gates the retroactive `expected_window` tick replay
    /// in `reanchorExpectedWindowTimer(coldStart: true)` so it runs **once** per process /
    /// stop-recovery cycle, not on every foreground active entry. Reset to `false` in `stop()`.
    private var hasAnchored = false
    private var bleConnectsToday: Int = 0
    private var bleEGVsToday: Int = 0
    /// G7 sequence of the first EGV observed today; nil until the first EGV of the calendar day.
    /// Used to derive `expected readings since first observed today` as the denominator for the
    /// `Connects:` / `EGVs:` debug rows. Reset on day rollover and on sensor swap (sequence regression).
    private var bleFirstSequenceToday: Int?
    private var sessionConnectAt: Date?

    /// Set on `sensorDidConnect`, cleared on `sensorDisconnected`; read from telemetry / ExtensionDelegate.
    var adapterSessionID: String?

    /// UserDefaults is thread-safe; exposed for debug UI without `nonisolated(unsafe)`.
    var telemetrySensorName: String {
        UserDefaults.standard.string(forKey: Keys.sensorName) ?? "nil"
    }

    private var sessionPhase: AdapterSessionPhase = .preEGV
    private var consecutivePreEGVDisconnects = 0
    private var hadEGVThisSession = false
    private var loggedTimeToFirstEGVForSession = false

    private var lastKnownScenePhase: String = "unknown"

    private var lastKnownExtSessionActive = false

    private var lastReadingSequence: UInt16?
    private var lastSavedGlucoseValue: Int?
    private var sessionActivationDate: Date?

    private enum Keys {
        static let sensorName = "G7DirectBLEObserver.sensorName"
        static let lastEGVEpoch = "G7WatchAdapter.lastEGVEpoch"
        static let calendarDay = "G7DirectBLEObserver.bleCountersCalendarDay"
        static let connects = "G7DirectBLEObserver.bleConnectsToday"
        static let egvs = "G7DirectBLEObserver.bleEGVsToday"
        static let firstSequenceToday = "G7WatchAdapter.bleFirstSequenceToday"
    }

    private enum AdapterSessionPhase: String {
        case preEGV = "pre_egv"
        case postEGV = "post_egv"
    }

    /// Phone-pushed sensor identity used to gate `didDiscoverNewSensor`. `nil` means idle (no
    /// expected sensor) or post-EOS (we deliberately reject all discoveries until the phone
    /// pushes a new name). UserDefaults-backed so it persists across launches and so the
    /// `nonisolated` discovery callback can read it synchronously from G7Sensor's `delegateQueue`.
    nonisolated var expectedSensorName: String? {
        get { UserDefaults.standard.string(forKey: Keys.sensorName) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sensorName) }
    }

    private override init() {
        // Seed the persisted sensor identity (mirrors the iPhone app's `G7Sensor(sensorID:
        // state.sensorID)`) so a known sensor reconnects directly instead of forcing a fresh
        // scan-and-discover cycle. Read UserDefaults directly rather than via
        // `expectedSensorName`, whose getter touches `self` and is illegal before `super.init`.
        // The value is nil on first launch / post-EOS, in which case this is identical to
        // constructing in scan mode.
        // BLE scanning is started by `start()` only, never from `init()` — kicking off scans
        // before any WKExtendedRuntimeSession is established starves the session and lets the
        // system reclaim BLE while the watch is in the background.
        sensor = G7Sensor(sensorID: UserDefaults.standard.string(forKey: Keys.sensorName))
        super.init()
        sensor.delegate = self
        loadDailyCounters()
    }

    /// Begin (or no-op resume) the G7 BLE pipeline.
    ///
    /// **Re-entry invariant:** `isStarted` guards the body so multiple foreground re-entries
    /// (scene-phase flicker, redundant `applyForegroundActiveEntry` calls) collapse into a single
    /// setup pass per stop/start cycle. The retroactive `expected_window` replay is further
    /// gated by `hasAnchored` so it runs once per process / stop-recovery cycle.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        stopTimers()
        isStopped = false
        recoveryScheduled = false
        loadDailyCountersIfNewCalendarDay()
        startHeartbeatTimer()
        guard let name = expectedSensorName else {
            log("start_skipped_no_sensor")
            return
        }
        // If the live sensor isn't bound to our expected name (cold start, post-EOS, or sensor
        // swap), forget any cached peripheral and start a fresh scan. `didDiscoverNewSensor`
        // gates the rebind by `expectedSensorName` suffix.
        if boundSensorName != name {
            boundSensorName = nil
            initiateScanForNewSensor()
        }
        if !hasAnchored, let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int {
            reanchorExpectedWindowTimer(fromEpoch: epoch, coldStart: true)
            hasAnchored = true
        }
        sensor.resumeScanning()
        publishConnectionStatus()
    }

    /// Tear down the G7 BLE pipeline.
    ///
    /// **Invariant:** clearing `hasAnchored` here ensures the next `start()` after a real stop
    /// re-runs the retroactive `expected_window` tick replay (e.g., post-recovery from an
    /// extended-runtime invalidation error). Foreground re-entries that did **not** go through
    /// `stop()` continue to skip the replay.
    func stop() {
        isStopped = true
        isStarted = false
        lastKnownExtSessionActive = false
        hasAnchored = false
        if let s = extendedSession {
            invalidatingSessionIDs.insert(ObjectIdentifier(s))
            s.invalidate()
        }
        if let s = pendingChainSession {
            invalidatingSessionIDs.insert(ObjectIdentifier(s))
            s.invalidate()
        }
        if let s = sessionPendingDidStart {
            invalidatingSessionIDs.insert(ObjectIdentifier(s))
            s.invalidate()
        }
        extendedSession = nil
        pendingChainSession = nil
        sessionPendingDidStart = nil
        stopTimers()
        sensor.stopScanning()
        WatchState.shared.applyG7DirectBleStatus(.off)
    }

    func applyForegroundActiveEntry() {
        lastKnownScenePhase = "active"
        start()
        renewSessionIfNeeded()
    }

    func noteForegroundInactiveOrBackground(_ phase: String) {
        lastKnownScenePhase = phase
    }

    private func renewSessionIfNeeded() {
        guard extendedSession?.state != .running, sessionPendingDidStart == nil else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        sessionPendingDidStart = session
        session.start()
        log("ext_session_start_requested_foreground")
    }

    /// Phone relay (WatchConnectivity): persist peripheral name and rescan. Logs **`sensor_name_set_from_phone`** when the stored name changes (dedupes overlapping WC paths).
    func setActiveSensorName(_ name: String?) {
        let willMutate = name != expectedSensorName
        applyNewSensorName(name)
        guard willMutate else { return }
        log("sensor_name_set_from_phone", "name=\(name ?? "nil")")
    }

    /// Called when WatchConnectivity (or another owner) pushes a new Dexcom peripheral name.
    /// Updates `expectedSensorName`; if the name changed and the adapter is not stopped, drops
    /// any current binding and starts a fresh scan via `sensor.scanForNewSensor()`. The single
    /// `G7Sensor` instance is preserved across name changes (mirrors phone `G7CGMManager`).
    func applyNewSensorName(_ name: String?) {
        let oldName = expectedSensorName
        guard name != oldName else { return }
        loadDailyCountersIfNewCalendarDay()
        let wasNil = (oldName == nil)
        expectedSensorName = name
        consecutivePreEGVDisconnects = 0
        // Clear session-scoped EGV state so the first reading from the new sensor is not
        // deduped against the previous sensor's last sequence, does not compute delta
        // against the previous sensor's glucose value, and does not reuse the previous
        // sensor's activation date for the reading timestamp. `handleSensorDisconnected`
        // (which fires when `initiateScanForNewSensor()` cancels the active peripheral)
        // does not clear these fields — only `performEndOfSessionTeardown` does, and a
        // phone-pushed sensor swap can happen without an EOS-marked EGV arriving first.
        lastReadingSequence = nil
        lastSavedGlucoseValue = nil
        sessionActivationDate = nil
        // Clear the per-day denominator anchor for the debug "Connects: X / Y" and "EGVs: X / Y"
        // rows. The existing regression check in `handleSensorDidRead` only resets the anchor
        // when the new sensor's first sequence is *lower* than the previous anchor — a new G7's
        // starting sequence can land above the old anchor, in which case the denominator would
        // misleadingly straddle two sensors. `applyNewSensorName` is the authoritative sensor-
        // identity transition, so reset the anchor here regardless.
        bleFirstSequenceToday = nil
        UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
        mirrorDailyCountersToWatchState()
        if !isStopped {
            boundSensorName = nil
            initiateScanForNewSensor()
            if wasNil, name != nil { log("start_recovered_from_nil_sensor") }
        }
        if name == nil {
            log("sensor_name_cleared")
        }
        publishConnectionStatus()
    }

    // MARK: - Logging

    private func log(_ eventName: String, _ fields: String = "") {
        let sid = adapterSessionID ?? "nil"
        let sensorName = expectedSensorName ?? "nil"
        Task {
            await WatchLogger.shared.log(
                G7StructuredTelemetryLogLine.formatBleModule(
                    sensorName: sensorName,
                    event: eventName,
                    fields: fields,
                    g7Session: sid
                )
            )
        }
    }

    // MARK: - Timers

    private func stopTimers() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        expectedWindowTimer?.cancel()
        expectedWindowTimer = nil
        expectedWindowNextEpoch = nil
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.cancel()
        let interval: TimeInterval = 5 * 60
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.emitHeartbeat()
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func emitHeartbeat() {
        let extStateRaw: String
        if let s = extendedSession {
            extStateRaw = String(describing: s.state)
        } else {
            extStateRaw = "nil"
        }
        let active = lastKnownExtSessionActive
        log("heartbeat", "ext_session_active=\(active) ext_session_state=\(extStateRaw)")
    }

    private func reanchorExpectedWindowTimer(fromEpoch lastEpoch: Int, coldStart: Bool) {
        let nowEpoch = Int(Date().timeIntervalSince1970)
        var missedCount = 0
        var lastMissed: Int?
        var e = lastEpoch + 300
        while e < nowEpoch {
            missedCount += 1
            lastMissed = e
            e += 300
        }

        let retro: [Int]
        if coldStart, missedCount > 50 {
            let skip = missedCount - 50
            let startEpoch = lastEpoch + 300 + skip * 300
            retro = Array(stride(from: startEpoch, to: nowEpoch, by: 300))
        } else if missedCount > 0 {
            retro = Array(stride(from: lastEpoch + 300, to: nowEpoch, by: 300))
        } else {
            retro = []
        }
        for epoch in retro {
            emitExpectedWindowTick(epoch: epoch, retroactive: true)
        }

        var nextEpoch: Int
        if let lm = lastMissed {
            nextEpoch = lm + 300
        } else {
            nextEpoch = lastEpoch + 300
        }
        while nextEpoch < nowEpoch {
            nextEpoch += 300
        }
        let delay = max(1.0, Double(nextEpoch) - Date().timeIntervalSince1970)
        scheduleWindowTick(deadline: .now() + delay, nextEpoch: nextEpoch)
    }

    private func scheduleWindowTick(deadline: DispatchTime, nextEpoch: Int) {
        expectedWindowTimer?.cancel()
        expectedWindowNextEpoch = nextEpoch
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: deadline, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fireExpectedWindowTick()
            }
        }
        timer.resume()
        expectedWindowTimer = timer
    }

    private func fireExpectedWindowTick() {
        guard let epoch = expectedWindowNextEpoch else { return }
        emitExpectedWindowTick(epoch: epoch, retroactive: false)
        reanchorExpectedWindowTimer(fromEpoch: epoch, coldStart: false)
    }

    private func emitExpectedWindowTick(epoch: Int, retroactive: Bool) {
        let lastSuccess = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int ?? -1
        let eligible = !isStopped && expectedSensorName != nil
        let reason = eligible ? "ok" : (isStopped ? "stopped" : "no_sensor")

        log(
            "expected_window",
            "tick_epoch=\(epoch) last_success_epoch=\(lastSuccess) eligible=\(eligible) reason=\(reason) retroactive=\(retroactive) ext_session_active=\(lastKnownExtSessionActive)"
        )
    }

    // MARK: - Daily counters (Task B2 — parity with `G7DirectBLEObserver`; keys `G7DirectBLEObserver.bleCountersCalendarDay` / `bleConnectsToday` / `bleEGVsToday`)

    private func loadDailyCounters() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: Keys.calendarDay)
        if storedDay != dayStart {
            bleConnectsToday = 0
            bleEGVsToday = 0
            bleFirstSequenceToday = nil
            UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
            UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
            persistDailyCounters()
        } else {
            bleConnectsToday = UserDefaults.standard.integer(forKey: Keys.connects)
            bleEGVsToday = UserDefaults.standard.integer(forKey: Keys.egvs)
            bleFirstSequenceToday = UserDefaults.standard.object(forKey: Keys.firstSequenceToday) as? Int
        }
        mirrorDailyCountersToWatchState()
    }

    private func persistDailyCounters() {
        UserDefaults.standard.set(bleConnectsToday, forKey: Keys.connects)
        UserDefaults.standard.set(bleEGVsToday, forKey: Keys.egvs)
    }

    private func loadDailyCountersIfNewCalendarDay() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: Keys.calendarDay)
        guard storedDay != dayStart else { return }
        bleConnectsToday = 0
        bleEGVsToday = 0
        bleFirstSequenceToday = nil
        UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
        UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
    }

    private func mirrorDailyCountersToWatchState() {
        WatchState.shared.bleConnectsToday = bleConnectsToday
        WatchState.shared.bleEGVsToday = bleEGVsToday
        WatchState.shared.bleFirstSequenceToday = bleFirstSequenceToday
    }

    /// Minutes since the last persisted EGV epoch (`Keys.lastEGVEpoch`). Returns -1 when no EGV
    /// has been observed. Internal access so the debug view can render it.
    func minutesSinceLastEGV() -> Int {
        guard let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int else {
            return -1
        }
        let now = Int(Date().timeIntervalSince1970)
        return max(0, (now - epoch) / 60)
    }

    /// Calls `sensor.scanForNewSensor()` with `isScanningForNewSensor` set so the downstream
    /// disconnect callback (if any) skips the pre-EGV counter increment.
    ///
    /// **Auto-clear:** `bluetoothManager.disconnect()` only fires a callback when an active
    /// peripheral exists. When we initiate a rescan while not connected (cold start, inside a
    /// disconnect-driven path), no callback comes and a sticky `true` flag would suppress the
    /// next legitimate disconnect. Clearing after a short timeout bounds that window.
    private func initiateScanForNewSensor() {
        isScanningForNewSensor = true
        sensor.scanForNewSensor()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.isScanningForNewSensor = false
        }
    }

    private func publishConnectionStatus() {
        let s = sensor
        let status: G7DirectBLEStatus
        if s.isConnected {
            status = .active
        } else if s.isScanning {
            status = .scanning
        } else if isStopped {
            status = .off
        } else {
            status = .retrieving
        }
        WatchState.shared.applyG7DirectBleStatus(status)
    }

    private func triggerEndOfSessionFromEGV(reason: String, message: G7GlucoseMessage) {
        // Adapter is `@MainActor`; this path runs only after delegate hop — safe to read battery on-device.
        let battery: Int = {
            let device = WKInterfaceDevice.current()
            guard device.isBatteryMonitoringEnabled else { return -1 }
            let level = device.batteryLevel
            guard level >= 0 else { return -1 }
            return Int(round(level * 100))
        }()
        let sensorAgeSeconds = Int(Double(message.messageTimestamp) - Double(message.age))
        log(
            "eos_detected",
            "reason=\(reason) battery_level_percent=\(battery) state=\(message.algorithmState.rawValue) sensor_age_s=\(sensorAgeSeconds)"
        )
        performEndOfSessionTeardown()
    }

    /// Disconnect-path EOS: triggered when the sensor disconnects with `suspectedEndOfSession=true`
    /// from `G7Sensor.peripheralDidDisconnect` (normal remote disconnect without auth — the G7 app
    /// stopped the session). No `G7GlucoseMessage` is available here, so battery/age fields are omitted.
    private func triggerEndOfSessionFromDisconnect() {
        log("eos_detected", "reason=disconnect_suspected_eos")
        performEndOfSessionTeardown()
    }

    /// Shared post-EOS state teardown. Clears the expected/bound names, resets the disconnect
    /// counter and session-scoped state, and asks the live `G7Sensor` to forget its peripheral
    /// and start a fresh scan. With `expectedSensorName == nil`, `didDiscoverNewSensor` rejects
    /// every discovery until the phone pushes a new name. Status is published as `.scanning`
    /// (we are actively scanning, just for nothing the adapter will accept yet).
    private func performEndOfSessionTeardown() {
        expectedSensorName = nil
        boundSensorName = nil
        consecutivePreEGVDisconnects = 0
        lastReadingSequence = nil
        lastSavedGlucoseValue = nil
        sessionActivationDate = nil
        // Same reasoning as `applyNewSensorName`: EOS ends the current sensor's contribution to
        // the daily denominator. Without this, a watch process that restarts between EOS and a
        // new sensor name being pushed could read a stale `Keys.firstSequenceToday` and use it
        // against the next sensor's sequences.
        bleFirstSequenceToday = nil
        UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
        mirrorDailyCountersToWatchState()
        sessionPhase = .preEGV
        initiateScanForNewSensor()
        WatchState.shared.applyG7DirectBleStatus(.scanning)
    }
}

// MARK: - G7SensorDelegate (G7SensorKit invokes these on `delegateQueue`; nonisolated stubs hop to `@MainActor` adapter.)

extension G7WatchSensorAdapter: G7SensorDelegate {
    nonisolated func sensorDidConnect(_ sensor: G7Sensor, name: String) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidConnect(name: name)
        }
    }

    nonisolated func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDisconnected(suspectedEndOfSession: suspectedEndOfSession)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didError error: Error) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.log("sensor_error", "error=\(String(describing: error))")
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, logComms comms: String) {
        _ = comms
    }

    nonisolated func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidRead(glucose: glucose)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidReadBackfill(backfill: backfill)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool {
        _ = activatedAt
        // This callback runs on G7Sensor's `delegateQueue`, not MainActor — so we can't go through
        // `G7WatchSensorAdapter.shared` synchronously. Read the same UserDefaults key that backs
        // `expectedSensorName` directly (thread-safe). With no expected name, reject all discoveries.
        guard let expected = UserDefaults.standard.string(forKey: Keys.sensorName) else { return false }
        return name.suffix(2) == expected.suffix(2)
    }

    nonisolated func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        _ = extendedVersion
    }

    nonisolated func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.publishConnectionStatus()
        }
    }

    private func handleSensorDidConnect(name: String) {
        recordSessionConnect(name: name, source: "did_connect_callback")
    }

    /// Shared connect bookkeeping. Called from `handleSensorDidConnect` (normal reconnect path,
    /// fired by `G7Sensor` once `sensorID` is set) **and** from `handleSensorDidRead` when a
    /// first-discovery cycle delivers a glucose message without a prior `sensorDidConnect`.
    ///
    /// **Why a first-read bootstrap exists:** `G7Sensor.bluetoothManager(_:readied:)` only fires
    /// `sensorDidConnect` when `sensorID != nil` at the time the peripheral is readied. On the
    /// initial discovery cycle for a new sensor identity (post-`scanForNewSensor()`), `sensorID`
    /// is nil at readied time. `G7Sensor` then sets `sensorID` itself inside `handleGlucoseMessage`
    /// after `didDiscoverNewSensor` returns true, and calls `didRead` directly. From the adapter's
    /// perspective, that means the first reading arrives without a preceding connect callback —
    /// so we treat the first reading as the connect event and run the same bookkeeping.
    private func recordSessionConnect(name: String, source: String) {
        // Record the peripheral name the sensor bound to. Mirrors `G7Sensor.sensorID` (private)
        // and is used by the debug UI and `start()`'s mismatch check. Setting this on the
        // first-read path also prevents `start()` from calling `initiateScanForNewSensor()`
        // again (which would disconnect the freshly-bound peripheral).
        boundSensorName = name
        sessionPhase = .preEGV
        adapterSessionID = String(UUID().uuidString.prefix(8))
        sessionConnectAt = Date()
        hadEGVThisSession = false
        loggedTimeToFirstEGVForSession = false
        bleConnectsToday += 1
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        let connectAt = Date()
        WatchState.shared.bleLastConnectAt = connectAt
        log(
            "did_connect",
            "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) source=\(source)"
        )
        renewSessionIfNeeded()
        publishConnectionStatus()
    }

    private func handleSensorDisconnected(suspectedEndOfSession: Bool) {
        let sinceConnectS: Int = {
            guard let t = sessionConnectAt else { return -1 }
            return Int(Date().timeIntervalSince(t))
        }()
        let durationS = sinceConnectS

        // A disconnect that we ourselves initiated via `sensor.scanForNewSensor()` (which calls
        // `bluetoothManager.disconnect()` under the hood). Skip counter logic so self-rebinds,
        // sensor swaps, and EOS teardowns do not register as stale-binding failures.
        let initiatedScan = isScanningForNewSensor
        if initiatedScan {
            isScanningForNewSensor = false
        }

        log(
            "disconnect",
            "phase=\(sessionPhase.rawValue) since_did_connect_s=\(sinceConnectS) had_egv=\(hadEGVThisSession) session_duration_s=\(durationS) suspected_eos=\(suspectedEndOfSession) initiated_scan=\(initiatedScan) scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive)"
        )

        // NOTE: do not clear `boundSensorName` here. It mirrors `G7Sensor.sensorID`, which is only
        // cleared by `scanForNewSensor()` — not by transient disconnects (auto-reconnects expect
        // the binding to remain). The teardown paths that DO clear sensorID also clear bound here.

        if initiatedScan {
            // Skip counter logic — we caused this disconnect.
        } else if suspectedEndOfSession {
            // Phone-side parity: a clean remote disconnect without auth signals the G7 app stopped
            // the session. Treat as a genuine EOS, not as a pre-EGV failure.
            triggerEndOfSessionFromDisconnect()
        } else if sessionPhase == .preEGV {
            consecutivePreEGVDisconnects += 1
            let minutesSinceEGV = minutesSinceLastEGV()
            log(
                "pre_egv_disconnect",
                "since_connect_s=\(sinceConnectS) consecutive_count=\(consecutivePreEGVDisconnects) suspected_eos=\(suspectedEndOfSession) minutes_since_last_egv=\(minutesSinceEGV) ext_session_active=\(lastKnownExtSessionActive)"
            )
            // Gate the diagnostic / remediation thresholds on `minutesSinceLastEGV` too: a high
            // consecutive count while EGVs are still fresh means BLE noise, not stale binding.
            if consecutivePreEGVDisconnects >= 3 && minutesSinceEGV > 10 {
                log(
                    "stale_sensor_binding_suspected",
                    "consecutive_pre_egv_disconnects=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceEGV)"
                )
            }
            if consecutivePreEGVDisconnects >= 5 && minutesSinceEGV > 15 {
                log(
                    "stale_sensor_reinit",
                    "count=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceEGV)"
                )
                // Reset BEFORE `initiateScanForNewSensor()` so the downstream disconnect callback
                // (which sees `isScanningForNewSensor=true`) skips counter increment cleanly.
                consecutivePreEGVDisconnects = 0
                boundSensorName = nil
                initiateScanForNewSensor()
            }
        } else {
            consecutivePreEGVDisconnects = 0
        }

        sessionPhase = .preEGV
        adapterSessionID = nil
        sessionConnectAt = nil
        hadEGVThisSession = false
        loggedTimeToFirstEGVForSession = false
        publishConnectionStatus()
    }

    private func handleSensorDidRead(glucose: G7GlucoseMessage) {
        // First-read connect bootstrap. On the initial discovery cycle for a new sensor identity,
        // `G7Sensor` accepts the peripheral via `didDiscoverNewSensor` and calls `didRead` without
        // firing `sensorDidConnect` (see `recordSessionConnect` docs). Detect that case via
        // `boundSensorName == nil` and run the connect bookkeeping inline before any of the
        // glucose-message validation paths below. EOS / unreliable / dedup early-returns still
        // run after this; that's intentional — the sensor *did* connect, even if this particular
        // message is unusable, so the connect counter / log lines / session ID should reflect it.
        if boundSensorName == nil, let expected = expectedSensorName {
            recordSessionConnect(name: expected, source: "first_discovery_path")
        }
        if glucose.algorithmState.sensorFailed {
            triggerEndOfSessionFromEGV(reason: "algorithm_state", message: glucose)
            return
        }
        if glucose.algorithmState == .known(.sessionEnded) {
            triggerEndOfSessionFromEGV(reason: "algorithm_state", message: glucose)
            return
        }

        let sensorAgeSeconds = Double(glucose.messageTimestamp) - Double(glucose.age)
        if sensorAgeSeconds > G7Sensor.defaultLifetime + G7Sensor.gracePeriod {
            triggerEndOfSessionFromEGV(reason: "sensor_age_ceiling", message: glucose)
            return
        }

        guard glucose.hasReliableGlucose else {
            log(
                "egv_unreliable",
                "algorithm_state=\(glucose.algorithmState.rawValue) sequence=\(glucose.sequence) glucose=\(glucose.glucose.map(String.init) ?? "nil")"
            )
            return
        }

        if let lastSeq = lastReadingSequence, lastSeq == glucose.sequence {
            log("egv_dedup", "glucose=\(glucose.glucose.map(String.init) ?? "nil") sequence=\(glucose.sequence)")
            return
        }

        guard let gMgDl = glucose.glucose else {
            log("egv_missing_glucose_value", "sequence=\(glucose.sequence) state=\(glucose.algorithmState.rawValue)")
            return
        }
        let glucoseValue = Int(gMgDl)

        lastReadingSequence = glucose.sequence

        sessionPhase = .postEGV
        consecutivePreEGVDisconnects = 0
        hadEGVThisSession = true

        if sessionActivationDate == nil {
            sessionActivationDate = Date().addingTimeInterval(-TimeInterval(glucose.messageTimestamp))
        }
        guard let activation = sessionActivationDate else { return }

        let readingDate = activation.addingTimeInterval(TimeInterval(glucose.glucoseTimestamp))
        let readingEpoch = Int(readingDate.timeIntervalSince1970)
        UserDefaults.standard.set(readingEpoch, forKey: Keys.lastEGVEpoch)
        reanchorExpectedWindowTimer(fromEpoch: readingEpoch, coldStart: false)

        loadDailyCountersIfNewCalendarDay()

        bleEGVsToday += 1
        let currentSequence = Int(glucose.sequence)
        if let anchor = bleFirstSequenceToday {
            if currentSequence < anchor {
                bleFirstSequenceToday = currentSequence
                UserDefaults.standard.set(currentSequence, forKey: Keys.firstSequenceToday)
            }
        } else {
            bleFirstSequenceToday = currentSequence
            UserDefaults.standard.set(currentSequence, forKey: Keys.firstSequenceToday)
        }
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        let delta: String = {
            guard let previous = lastSavedGlucoseValue else { return "--" }
            return String(format: "%+d", glucoseValue - previous)
        }()
        lastSavedGlucoseValue = glucoseValue

        let trend = WatchState.trendString(fromDirectBleRate: glucose.trend)

        if !loggedTimeToFirstEGVForSession, let connectAt = sessionConnectAt {
            loggedTimeToFirstEGVForSession = true
            let ms = Int(Date().timeIntervalSince(connectAt) * 1000)
            log(
                "egv_received",
                "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) sequence=\(glucose.sequence) glucose=\(glucoseValue) time_to_first_egv_ms=\(ms)"
            )
        } else {
            log(
                "egv_received",
                "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) sequence=\(glucose.sequence) glucose=\(glucoseValue)"
            )
        }

        let snapshot = TrioComplicationSnapshot(
            glucose: "\(glucoseValue)",
            trend: trend,
            delta: delta,
            readingDate: readingDate,
            date: Date(),
            state: nil,
            glucoseColor: nil,
            source: .g7DirectBLE,
            sequence: Int(glucose.sequence)
        )

        TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
        WatchState.shared.applyG7DirectBleSnapshot(snapshot)
        WatchState.shared.bleLastEGVDate = readingDate
        WatchState.shared.bleLastEGVValue = glucoseValue
        WatchState.shared.bleLastEGVSequence = currentSequence

        publishConnectionStatus()
    }

    private func handleSensorDidReadBackfill(backfill: [G7BackfillMessage]) {
        for msg in backfill {
            log(
                "backfill_entry",
                "timestamp=\(msg.timestamp) glucose=\(msg.glucose.map(String.init) ?? "nil") algorithm_state=\(msg.algorithmState.rawValue) display_only=\(msg.glucoseIsDisplayOnly) trend=\(msg.trend.map { String(format: "%.1f", $0) } ?? "nil")"
            )
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension G7WatchSensorAdapter: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        lastKnownExtSessionActive = false
        log("ext_session_will_expire")
        let newSession = WKExtendedRuntimeSession()
        newSession.delegate = self
        // Invalidate any prior pending session(s) before overwriting the slots, so we don't leak
        // a started-or-starting WKExtendedRuntimeSession when willExpire fires while a previous
        // chain attempt is still in flight. Track the IDs in `invalidatingSessionIDs` so the
        // stale `didInvalidateWith` callback from the displaced prior session is treated as an
        // intentional invalidation rather than falling through to the `stop()` error branch.
        if let prior = pendingChainSession, prior !== session {
            invalidatingSessionIDs.insert(ObjectIdentifier(prior))
            prior.invalidate()
        }
        if let prior = sessionPendingDidStart, prior !== session {
            invalidatingSessionIDs.insert(ObjectIdentifier(prior))
            prior.invalidate()
        }
        pendingChainSession = newSession
        sessionPendingDidStart = newSession
        newSession.start()
        log("ext_session_chain_attempted")
        Task { @MainActor [weak self, weak newSession] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, let newSession else { return }
            if self.pendingChainSession === newSession {
                // Timeout: explicitly invalidate before nilling the slot so the system reclaims
                // the never-started session (otherwise it can persist as a dangling delegate).
                // Track the ID so the eventual `didInvalidateWith` callback is treated as
                // intentional rather than falling through to the `stop()` error branch.
                self.invalidatingSessionIDs.insert(ObjectIdentifier(newSession))
                newSession.invalidate()
                self.pendingChainSession = nil
                if self.sessionPendingDidStart === newSession {
                    self.sessionPendingDidStart = nil
                }
                self.log("ext_session_chain_timeout")
            }
        }
    }

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        // Defensive cleanup: a session that successfully started should not be sitting in the
        // intentional-invalidation set (stop() would have invalidated it before it could start),
        // but if it somehow is, remove it so the set stays bounded across long-running processes.
        invalidatingSessionIDs.remove(ObjectIdentifier(session))
        lastKnownExtSessionActive = true
        // Defensive: if an older `extendedSession` is still held (e.g. unexpected double-start
        // without an intervening willExpire/invalidate), invalidate it before replacing. Leaking
        // a started session keeps a CBCentralManager-backed runtime alive in the background.
        // Track the ID so the displaced session's `didInvalidateWith` is short-circuited as
        // intentional and never reaches the `stop()` error branch.
        if let old = extendedSession, old !== session {
            invalidatingSessionIDs.insert(ObjectIdentifier(old))
            old.invalidate()
            log("ext_session_replaced_unexpectedly")
        }
        extendedSession = session
        if session === pendingChainSession {
            pendingChainSession = nil
            log("ext_session_chain_started")
        } else {
            log("ext_session_started")
        }
        if session === sessionPendingDidStart {
            sessionPendingDidStart = nil
        }
    }

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let id = ObjectIdentifier(session)
        if invalidatingSessionIDs.contains(id) {
            invalidatingSessionIDs.remove(id)
            lastKnownExtSessionActive = false
            log(
                "ext_session_intentional_invalidation",
                "reason=\(reason.rawValue) has_error=\(error != nil)"
            )
            return
        }
        lastKnownExtSessionActive = false
        let hasError = (error != nil)
        log("ext_session_did_invalidate", "reason=\(reason.rawValue) has_error=\(hasError)")

        if session === pendingChainSession {
            pendingChainSession = nil
            if session === sessionPendingDidStart {
                sessionPendingDidStart = nil
            }
            log("ext_session_chain_denied", "has_error=\(hasError)")
            return
        }

        // Renew / foreground session that never reached didStart — do not tear down BLE.
        if session === sessionPendingDidStart {
            sessionPendingDidStart = nil
            log("ext_session_pending_start_invalidated", "has_error=\(hasError)")
            return
        }

        if hasError {
            log("ext_session_unexpected_invalidation", "triggering_teardown=true")
            stop()
            guard !recoveryScheduled else { return }
            recoveryScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                guard self.lastKnownScenePhase == "active" else {
                    self.log("recovery_skipped", "reason=not_active scene=\(self.lastKnownScenePhase)")
                    self.recoveryScheduled = false
                    return
                }
                self.log("post_stop_recovery_attempt")
                self.start()
            }
        } else {
            log("ext_session_natural_or_unknown_expiry")
        }
    }
}
