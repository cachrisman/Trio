import CoreBluetooth
import Foundation
import G7SensorKit
import WatchKit

/// Thin watch-specific wrapper around `G7Sensor` (build 195). Replaces `G7DirectBLEObserver` BLE stack;
/// sensor identity and daily counters remain compatible with existing App Group / WatchState keys.
///
/// **Peripheral match / `suffix(2)`:** There is no `attachIntent` symbol in G7SensorKit. Dexcom advertising names are
/// accepted in `G7Sensor.bluetoothManager(_:shouldConnectPeripheral:)` (`G7SensorKit/.../G7Sensor.swift`): when
/// `sensorID` is set, connection uses `name.suffix(2) == sensorName.suffix(2)`; when nil, `.connect` for DXCM/DX02.
/// Watch adapter supplies identity via `G7Sensor(sensorID:)` / UserDefaults — keep phone WC name aligned with that logic.
///
/// **Discovery:** `didDiscoverNewSensor` returns `false` — peripheral identity comes from phone/WC or persisted defaults only.
/// If WC is broken and storage is cleared, BLE discovery cannot bind without the phone (narrow but real failure mode).
final class G7WatchSensorAdapter: NSObject {
    static let shared = G7WatchSensorAdapter()

    private var sensor: G7Sensor
    /// Identity of the `G7Sensor` instance; kept in sync with `knownSensorName` so `start()` cannot resume scanning on a stale sensor after WC/UserDefaults updates.
    private var currentSensorName: String?

    @MainActor private var extendedSession: WKExtendedRuntimeSession?
    @MainActor private var pendingChainSession: WKExtendedRuntimeSession?

    /// Read-only accessor for the currently started extended runtime session.
    ///
    /// The adapter may replace this reference from several paths (`stop()`,
    /// `renewSessionIfNeeded()`, chain inside `extendedRuntimeSessionWillExpire`), so callers
    /// must re-query on every use — never cache the returned reference.
    @MainActor var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }

    /// Read-only mirror of the adapter's authoritative `isStopped` flag.
    ///
    /// Use this instead of `WatchState.shared.g7DirectBleStatus == .off` when an external
    /// subsystem needs to know whether the adapter was intentionally stopped. The published
    /// status mirror defaults to `.off` at cold start (until `publishConnectionStatus()` runs)
    /// and would falsely report "stopped" before the first BLE event. `isStopped` is mutated
    /// only by `start()` (false) and `stop()` (true), so this accessor reflects intentional
    /// lifecycle exactly.
    var isIntentionallyStopped: Bool { isStopped }

    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.g7WatchAdapter.timers", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var expectedWindowTimer: DispatchSourceTimer?
    private var expectedWindowNextEpoch: Int?

    private var isStopped = false
    private var recoveryScheduled = false
    private var bleConnectsToday: Int = 0
    private var bleEGVsToday: Int = 0
    private var sessionConnectAt: Date?

    /// BLE delegate vs lifecycle / ExtensionDelegate — protect with one lock (avoid `nonisolated(unsafe)` drift).
    private let crossThreadTelemetryLock = NSLock()
    private var lockedAdapterSessionID: String?
    private var lockedLastKnownScenePhase: String = "unknown"
    private var lockedLastKnownExtSessionActive: Bool = false

    private func syncTelemetry<T>(_ body: () -> T) -> T {
        crossThreadTelemetryLock.lock()
        defer { crossThreadTelemetryLock.unlock() }
        return body()
    }

    /// Set on `sensorDidConnect`, cleared on `sensorDisconnected`; read from telemetry / ExtensionDelegate.
    var adapterSessionID: String? {
        get { syncTelemetry { lockedAdapterSessionID } }
        set { syncTelemetry { lockedAdapterSessionID = newValue } }
    }

    /// UserDefaults is thread-safe; exposed for debug UI without `nonisolated(unsafe)`.
    var telemetrySensorName: String {
        UserDefaults.standard.string(forKey: Keys.sensorName) ?? "nil"
    }

    private var sessionPhase: AdapterSessionPhase = .preEGV
    private var consecutivePreEGVDisconnects = 0
    private var hadEGVThisSession = false
    private var loggedTimeToFirstEGVForSession = false

    private var lastKnownScenePhase: String {
        get { syncTelemetry { lockedLastKnownScenePhase } }
        set { syncTelemetry { lockedLastKnownScenePhase = newValue } }
    }

    private var lastKnownExtSessionActive: Bool {
        get { syncTelemetry { lockedLastKnownExtSessionActive } }
        set { syncTelemetry { lockedLastKnownExtSessionActive = newValue } }
    }

    private var lastReadingSequence: UInt16?
    private var lastSavedGlucoseValue: Int?
    private var sessionActivationDate: Date?

    private enum Keys {
        static let sensorName = "G7DirectBLEObserver.sensorName"
        static let lastEGVEpoch = "G7WatchAdapter.lastEGVEpoch"
        static let calendarDay = "G7DirectBLEObserver.bleCountersCalendarDay"
        static let connects = "G7DirectBLEObserver.bleConnectsToday"
        static let egvs = "G7DirectBLEObserver.bleEGVsToday"
    }

    private enum AdapterSessionPhase: String {
        case preEGV = "pre_egv"
        case postEGV = "post_egv"
    }

    private var knownSensorName: String? {
        get { UserDefaults.standard.string(forKey: Keys.sensorName) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sensorName) }
    }

    private override init() {
        let name = UserDefaults.standard.string(forKey: Keys.sensorName)
        currentSensorName = name
        sensor = G7Sensor(sensorID: name)
        super.init()
        sensor.delegate = self
        loadDailyCounters()
    }

    func start() {
        stopTimers()
        isStopped = false
        recoveryScheduled = false
        loadDailyCountersIfNewCalendarDay()
        startHeartbeatTimer()
        let name = knownSensorName
        guard let name else {
            log("start_skipped_no_sensor")
            return
        }
        if currentSensorName != name {
            sensor.stopScanning()
            sensor = G7Sensor(sensorID: name)
            sensor.delegate = self
            currentSensorName = name
        }
        if let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int {
            reanchorExpectedWindowTimer(fromEpoch: epoch, coldStart: true)
        }
        sensor.resumeScanning()
        publishConnectionStatus()
    }

    func stop() {
        isStopped = true
        lastKnownExtSessionActive = false
        Task { @MainActor in
            extendedSession?.invalidate()
            pendingChainSession?.invalidate()
            extendedSession = nil
            pendingChainSession = nil
        }
        stopTimers()
        sensor.stopScanning()
        Task { @MainActor in WatchState.shared.applyG7DirectBleStatus(.off) }
    }

    func applyForegroundActiveEntry() {
        lastKnownScenePhase = "active"
        start()
        Task { @MainActor in renewSessionIfNeeded() }
    }

    func noteForegroundInactiveOrBackground(_ phase: String) {
        lastKnownScenePhase = phase
    }

    @MainActor
    private func renewSessionIfNeeded() {
        guard extendedSession?.state != .running else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        log("ext_session_renewed_on_foreground")
    }

    /// Phone relay (WatchConnectivity): persist peripheral name and rescan. Logs **`sensor_name_set_from_phone`** when the stored name changes (dedupes overlapping WC paths).
    func setActiveSensorName(_ name: String?) {
        let willMutate = name != knownSensorName
        applyNewSensorName(name)
        guard willMutate else { return }
        log("sensor_name_set_from_phone", "name=\(name ?? "nil")")
    }

    /// Called when WatchConnectivity (or another owner) pushes a new Dexcom peripheral name.
    func applyNewSensorName(_ name: String?) {
        guard name != knownSensorName else { return }
        loadDailyCountersIfNewCalendarDay()
        let wasNil = (knownSensorName == nil)
        knownSensorName = name
        sensor.stopScanning()
        sensor = G7Sensor(sensorID: name)
        sensor.delegate = self
        currentSensorName = name
        if !isStopped, name != nil {
            sensor.resumeScanning()
            if wasNil { log("start_recovered_from_nil_sensor") }
        } else if name == nil {
            log("sensor_name_cleared_no_scan")
        }
        publishConnectionStatus()
    }

    // MARK: - Logging

    private func log(_ eventName: String, _ fields: String = "") {
        let sid = adapterSessionID ?? "nil"
        let sensorName = knownSensorName ?? "nil"
        let suffix = fields.isEmpty ? "" : " \(fields)"
        Task {
            await WatchLogger.shared.log(
                "module=g7_ble event=\(eventName) g7_session=\(sid) sensor_name=\(sensorName)\(suffix)"
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
        timer.setEventHandler { [weak self] in self?.emitHeartbeat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func emitHeartbeat() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let extStateRaw: String
            if let s = self.extendedSession {
                extStateRaw = String(describing: s.state)
            } else {
                extStateRaw = "nil"
            }
            let active = self.lastKnownExtSessionActive
            self.log("heartbeat", "ext_session_active=\(active) ext_session_state=\(extStateRaw)")
        }
    }

    private func reanchorExpectedWindowTimer(fromEpoch lastEpoch: Int, coldStart: Bool) {
        let nowEpoch = Int(Date().timeIntervalSince1970)
        var missed: [Int] = []
        var e = lastEpoch + 300
        while e < nowEpoch {
            missed.append(e)
            e += 300
        }

        let retro: [Int]
        if coldStart, missed.count > 50 {
            retro = Array(missed.suffix(50))
        } else {
            retro = missed
        }
        for epoch in retro {
            emitExpectedWindowTick(epoch: epoch, retroactive: true)
        }

        var nextEpoch: Int
        if let lastMissed = missed.last {
            nextEpoch = lastMissed + 300
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
        timer.setEventHandler { [weak self] in self?.fireExpectedWindowTick() }
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
        let eligible = !isStopped && knownSensorName != nil
        let reason = eligible ? "ok" : (isStopped ? "stopped" : "no_sensor")

        log(
            "expected_window",
            "tick_epoch=\(epoch) last_success_epoch=\(lastSuccess) eligible=\(eligible) reason=\(reason) retroactive=\(retroactive)"
        )
    }

    // MARK: - Daily counters (Task B2 — parity with `G7DirectBLEObserver`; keys `G7DirectBLEObserver.bleCountersCalendarDay` / `bleConnectsToday` / `bleEGVsToday`)

    private func loadDailyCounters() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: Keys.calendarDay)
        if storedDay != dayStart {
            bleConnectsToday = 0
            bleEGVsToday = 0
            UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
            persistDailyCounters()
        } else {
            bleConnectsToday = UserDefaults.standard.integer(forKey: Keys.connects)
            bleEGVsToday = UserDefaults.standard.integer(forKey: Keys.egvs)
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
        UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
    }

    private func mirrorDailyCountersToWatchState() {
        let connects = bleConnectsToday
        let egvs = bleEGVsToday
        Task { @MainActor in
            WatchState.shared.bleConnectsToday = connects
            WatchState.shared.bleEGVsToday = egvs
        }
    }

    private func minutesSinceLastEGV() -> Int {
        guard let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int else {
            return -1
        }
        let now = Int(Date().timeIntervalSince1970)
        return max(0, (now - epoch) / 60)
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
        Task { @MainActor in WatchState.shared.applyG7DirectBleStatus(status) }
    }

    private func triggerEndOfSessionFromEGV(reason: String, message: G7GlucoseMessage) {
        // WKInterfaceDevice.current() must run on the main thread; never use main.sync here — CoreBluetooth can deliver
        // on the main queue and would deadlock. Omit battery when off-main (-1 in log).
        let battery: Int = {
            guard Thread.isMainThread else { return -1 }
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

        knownSensorName = nil
        lastReadingSequence = nil
        lastSavedGlucoseValue = nil
        sessionActivationDate = nil
        sessionPhase = .preEGV
        sensor.stopScanning()
        sensor = G7Sensor(sensorID: nil)
        sensor.delegate = self
        publishConnectionStatus()
    }
}

// MARK: - G7SensorDelegate

extension G7WatchSensorAdapter: G7SensorDelegate {
    func sensorDidConnect(_ sensor: G7Sensor, name: String) {
        sessionPhase = .preEGV
        adapterSessionID = UUID().uuidString
        sessionConnectAt = Date()
        hadEGVThisSession = false
        loggedTimeToFirstEGVForSession = false
        bleConnectsToday += 1
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        let connectAt = Date()
        Task { @MainActor in WatchState.shared.bleLastConnectAt = connectAt }
        log("did_connect", "name=\(name)")
        Task { @MainActor in self.renewSessionIfNeeded() }
        publishConnectionStatus()
    }

    func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {
        let sinceConnectS: Int = {
            guard let t = sessionConnectAt else { return -1 }
            return Int(Date().timeIntervalSince(t))
        }()
        let durationS: Int = {
            guard let t = sessionConnectAt else { return -1 }
            return Int(Date().timeIntervalSince(t))
        }()
        log(
            "disconnect",
            "phase=\(sessionPhase.rawValue) since_did_connect_s=\(sinceConnectS) had_egv=\(hadEGVThisSession) session_duration_s=\(durationS) suspected_eos=\(suspectedEndOfSession)"
        )

        if sessionPhase == .preEGV {
            consecutivePreEGVDisconnects += 1
            log(
                "auth_failed_inferred",
                "since_connect_s=\(sinceConnectS) consecutive_count=\(consecutivePreEGVDisconnects)"
            )
            if consecutivePreEGVDisconnects >= 3 {
                log(
                    "stale_sensor_binding_suspected",
                    "consecutive_pre_egv_disconnects=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceLastEGV())"
                )
            }
            if consecutivePreEGVDisconnects >= 5 {
                log("stale_sensor_reinit", "count=\(consecutivePreEGVDisconnects)")
                consecutivePreEGVDisconnects = 0
                let name = knownSensorName
                self.sensor.stopScanning()
                self.sensor = G7Sensor(sensorID: name)
                self.sensor.delegate = self
                if !isStopped { self.sensor.resumeScanning() }
                publishConnectionStatus()
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

    func sensor(_ sensor: G7Sensor, didError error: Error) {
        log("sensor_error", "error=\(String(describing: error))")
    }

    func sensor(_ sensor: G7Sensor, logComms comms: String) {
        _ = comms
    }

    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage) {
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

        // Task B2 — mirrors `G7DirectBLEObserver.parseGlucose`: reliable + dedup + valid glucose bytes, then EGV counter.
        bleEGVsToday += 1
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

        Task { @MainActor in
            TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
            WatchState.shared.applyG7DirectBleSnapshot(snapshot)
            WatchState.shared.bleLastEGVDate = readingDate
            WatchState.shared.bleLastEGVValue = glucoseValue
        }
        Task { @MainActor in
            HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)
        }

        publishConnectionStatus()
    }

    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        for msg in backfill {
            log(
                "backfill_entry",
                "timestamp=\(msg.timestamp) glucose=\(msg.glucose.map(String.init) ?? "nil") algorithm_state=\(msg.algorithmState.rawValue) display_only=\(msg.glucoseIsDisplayOnly) trend=\(msg.trend.map { String(format: "%.1f", $0) } ?? "nil")"
            )
        }
    }

    func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool {
        _ = activatedAt
        return false
    }

    func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        _ = extendedVersion
    }

    func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {
        publishConnectionStatus()
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

@MainActor
extension G7WatchSensorAdapter: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        lastKnownExtSessionActive = false
        log("ext_session_will_expire")
        let newSession = WKExtendedRuntimeSession()
        newSession.delegate = self
        pendingChainSession = newSession
        extendedSession = newSession
        newSession.start()
        log("ext_session_chain_attempted")
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

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        lastKnownExtSessionActive = false
        let hasError = (error != nil)
        log("ext_session_did_invalidate", "reason=\(reason.rawValue) has_error=\(hasError)")

        if session === pendingChainSession {
            pendingChainSession = nil
            log("ext_session_chain_denied", "has_error=\(hasError)")
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
