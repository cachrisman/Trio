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
@MainActor
final class G7WatchSensorAdapter: NSObject {
    static let shared = G7WatchSensorAdapter()

    private var sensor: G7Sensor
    /// Identity of the `G7Sensor` instance; kept in sync with `knownSensorName` so `start()` cannot resume scanning on a stale sensor after WC/UserDefaults updates.
    private var currentSensorName: String?

    private var extendedSession: WKExtendedRuntimeSession?
    private var pendingChainSession: WKExtendedRuntimeSession?
    /// Session for which `start()` was called but `extendedRuntimeSessionDidStart` has not yet run.
    /// `extendedSession` is assigned **only** in `extendedRuntimeSessionDidStart` so it always refers to a started session.
    private var sessionPendingDidStart: WKExtendedRuntimeSession?

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

    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.g7WatchAdapter.timers", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var expectedWindowTimer: DispatchSourceTimer?
    private var expectedWindowNextEpoch: Int?

    private var isStopped = false
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

    /// Begin (or no-op resume) the G7 BLE pipeline.
    ///
    /// **Idempotency invariant:** when the sensor is already connected and we are not stopped,
    /// `start()` returns early without re-scanning, replaying retroactive `expected_window`
    /// ticks, or rebinding the sensor. This prevents single-cycle scene-phase flicker
    /// (active→inactive→active) from producing redundant `resumeScanning()` calls and tick
    /// log floods. The retroactive replay is further gated by `hasAnchored` so it runs only
    /// once per process / stop-recovery cycle.
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
        if !isStopped && sensor.isConnected {
            publishConnectionStatus()
            return
        }
        if currentSensorName != name {
            sensor.stopScanning()
            sensor = G7Sensor(sensorID: name)
            sensor.delegate = self
            currentSensorName = name
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
        lastKnownExtSessionActive = false
        hasAnchored = false
        extendedSession?.invalidate()
        pendingChainSession?.invalidate()
        sessionPendingDidStart?.invalidate()
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
        let eligible = !isStopped && knownSensorName != nil
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

        knownSensorName = nil
        currentSensorName = nil
        consecutivePreEGVDisconnects = 0
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
        return false
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
            "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive)"
        )
        renewSessionIfNeeded()
        publishConnectionStatus()
    }

    private func handleSensorDisconnected(suspectedEndOfSession: Bool) {
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
            "phase=\(sessionPhase.rawValue) since_did_connect_s=\(sinceConnectS) had_egv=\(hadEGVThisSession) session_duration_s=\(durationS) suspected_eos=\(suspectedEndOfSession) scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive)"
        )

        if sessionPhase == .preEGV {
            consecutivePreEGVDisconnects += 1
            log(
                "auth_failed_inferred",
                "since_connect_s=\(sinceConnectS) consecutive_count=\(consecutivePreEGVDisconnects) ext_session_active=\(lastKnownExtSessionActive)"
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
                sensor.stopScanning()
                sensor = G7Sensor(sensorID: name)
                sensor.delegate = self
                if !isStopped { sensor.resumeScanning() }
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

    private func handleSensorDidRead(glucose: G7GlucoseMessage) {
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
        HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)

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
        pendingChainSession = newSession
        sessionPendingDidStart = newSession
        newSession.start()
        log("ext_session_chain_attempted")
        Task { @MainActor [weak self, weak newSession] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, let newSession else { return }
            if self.pendingChainSession === newSession {
                self.pendingChainSession = nil
                if self.sessionPendingDidStart === newSession {
                    self.sessionPendingDidStart = nil
                }
                self.log("ext_session_chain_timeout")
            }
        }
    }

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        lastKnownExtSessionActive = true
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
