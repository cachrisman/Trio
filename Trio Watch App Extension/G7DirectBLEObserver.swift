import CoreBluetooth
import Foundation

// G7 BLE observer for watchOS, mirroring G7SensorKit's passive listening pattern.
// State machine: LISTEN -> CB delivers peripheral -> CONNECT (no timeout) -> CONNECTED -> SETTLE 2s -> LISTEN
// Auth: enable notify on .authentication, wait for 0x05 (no fallback timer).
// Glucose: enable notify on .control after 0x05, then JUST LISTEN. Sensor pushes 0x4E unsolicited.
// Backfill: enable notify on .backfill after first glucose, parse 9-byte messages, buffer, flush on
//   backfillFinished (0x59) or disconnect. Application of buffered backfill data deferred to build 193.
// Dedup: sequence-number equality.
// Sensor identity: stores full name; matches via suffix(2) (matches G7SensorKit byte-for-byte).
//   Identity locked on first reliable glucose, mirroring G7SensorKit's didDiscoverNewSensor flow.
// Safety: stall-style session watchdog (bumped on every meaningful CB callback). Discovery, value-update,
//   and auth/control notify failures cancel immediately for fast recovery.

private enum G7DailyCounterKeys {
    static let calendarDay = "G7DirectBLEObserver.bleCountersCalendarDay"
    static let connects = "G7DirectBLEObserver.bleConnectsToday"
    static let egvs = "G7DirectBLEObserver.bleEGVsToday"
    static let connectionEvents = "G7DirectBLEObserver.bleConnectionEventsToday"
}

private enum G7UUID {
    static let advertisement = CBUUID(string: "FEBC")
    static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
}

private enum G7Opcode {
    static let authChallengeRx: UInt8 = 0x05
    static let glucoseTx: UInt8 = 0x4E
    static let backfillFinished: UInt8 = 0x59
}

private enum G7AlgorithmState {
    /// Mirrors G7SensorKit's AlgorithmState.State.ok = 6, the only state where hasReliableGlucose is true.
    static let ok: UInt8 = 6
}

/// Mirrors G7SensorKit's PeripheralConnectionCommand. Distinguishes "this is my known sensor"
/// from "I have no known sensor yet, this is a new-sensor candidate."
private enum AttachIntent {
    case makeActive // suffix matches knownSensorName
    case connect // no knownSensorName, this candidate qualifies for new-sensor adoption
    case ignore
}

/// Backfill entry from G7SensorKit's 9-byte G7BackfillMessage layout.
private struct G7BackfillEntry {
    let timestamp: UInt32 // seconds since pairing
    let glucose: UInt16?
    let algorithmState: UInt8
    let displayOnly: Bool
    let trendRate: Double?
}

final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    private let queue = DispatchQueue(label: "org.nightscout.trio.watch.g7DirectBLE", qos: .utility)
    private var central: CBCentralManager!
    private var active: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var sessionActivationDate: Date?
    private var lastReadingSequence: UInt16?
    private var lastSavedGlucoseValue: Int?
    private var sessionWatchdog: DispatchWorkItem?
    private var backfillBuffer: [G7BackfillEntry] = []

    private var bleConnectsToday: Int = 0
    private var bleEGVsToday: Int = 0
    private var bleConnectionEventsToday: Int = 0

    /// True between successful auth notify enable and receipt of bonded+authenticated 0x05.
    /// On remote disconnect of the active known sensor while pendingAuth, treat as suspected
    /// end-of-session and clear sensor identity (mirrors G7SensorKit).
    private var pendingAuth = false

    private var isStopped = false

    /// Stall-style watchdog: bumped on every meaningful CB callback, fires on silence.
    /// Substitute for G7SensorKit's per-GATT-op 2s timeouts. 20s of silence with no progress
    /// indicates a real stall (successful sessions show progress every <2s in practice).
    /// Note: post-EGV backfill silence can trip this if no backfill payloads arrive within
    /// the window; this is acceptable since we already have the EGV and recovery is just a
    /// disconnect+re-attach.
    private let sessionWatchdogTimeout: TimeInterval = 20

    /// Full sensor name (e.g. "DXCMQU"). Mirrors G7SensorKit's `state.sensorID`.
    /// Matched against incoming peripheral names via suffix(2) to bridge advertisement-form
    /// (DXCMxx) vs full-name-form (Dexcomxx) of the same physical sensor.
    private var knownSensorName: String? {
        get { UserDefaults.standard.string(forKey: "G7DirectBLEObserver.sensorName") }
        set { UserDefaults.standard.set(newValue, forKey: "G7DirectBLEObserver.sensorName") }
    }

    /// CB peripheral identifier from the most recent successful connect.
    /// Always re-validated through attachIntent before reuse.
    private var persistedID: UUID? {
        get { UserDefaults.standard.string(forKey: "G7DirectBLEObserver.peripheralIdentifier").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "G7DirectBLEObserver.peripheralIdentifier") }
    }

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "org.nightscout.trio.watch.g7DirectBLEObserver"]
        )
        loadDailyCounters()
    }

    func applyForegroundActiveEntry() {
        start()
    }

    func noteForegroundInactiveOrBackground(_ phase: String) {
        log("foreground_inactive_or_background phase=\(phase) policy=no_teardown_stub")
    }

    func stop() {
        Task { @MainActor in
            WatchState.shared.applyG7DirectBleStatus(.off)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.cancelSessionWatchdog()
            self.flushBackfillBuffer(reason: "stop")
            if self.central.isScanning { self.central.stopScan() }
            if let p = self.active { self.central.cancelPeripheralConnection(p) }
            self.active = nil
            self.chars.removeAll()
            self.sessionActivationDate = nil
            self.pendingAuth = false
            self.lastSavedGlucoseValue = nil
            self.lastReadingSequence = nil
            self.log("stop_completed")
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.loadDailyCountersIfNewCalendarDay()
            self.scanForPeripheral()
        }
    }

    // MARK: - Daily counters

    private func loadDailyCounters() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: G7DailyCounterKeys.calendarDay)
        if storedDay != dayStart {
            bleConnectsToday = 0
            bleEGVsToday = 0
            bleConnectionEventsToday = 0
            UserDefaults.standard.set(dayStart, forKey: G7DailyCounterKeys.calendarDay)
            persistDailyCounters()
        } else {
            bleConnectsToday = UserDefaults.standard.integer(forKey: G7DailyCounterKeys.connects)
            bleEGVsToday = UserDefaults.standard.integer(forKey: G7DailyCounterKeys.egvs)
            bleConnectionEventsToday = UserDefaults.standard.integer(forKey: G7DailyCounterKeys.connectionEvents)
        }
        mirrorDailyCountersToWatchState()
    }

    private func persistDailyCounters() {
        UserDefaults.standard.set(bleConnectsToday, forKey: G7DailyCounterKeys.connects)
        UserDefaults.standard.set(bleEGVsToday, forKey: G7DailyCounterKeys.egvs)
        UserDefaults.standard.set(bleConnectionEventsToday, forKey: G7DailyCounterKeys.connectionEvents)
    }

    private func loadDailyCountersIfNewCalendarDay() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: G7DailyCounterKeys.calendarDay)
        guard storedDay != dayStart else { return }
        bleConnectsToday = 0
        bleEGVsToday = 0
        bleConnectionEventsToday = 0
        UserDefaults.standard.set(dayStart, forKey: G7DailyCounterKeys.calendarDay)
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
    }

    private func mirrorDailyCountersToWatchState() {
        Task { @MainActor in
            WatchState.shared.bleConnectsToday = bleConnectsToday
            WatchState.shared.bleEGVsToday = bleEGVsToday
            WatchState.shared.bleConnectionEventsToday = bleConnectionEventsToday
        }
    }

    private func noteStatus(_ status: G7DirectBLEStatus) {
        Task { @MainActor in
            WatchState.shared.applyG7DirectBleStatus(status)
        }
    }

    // MARK: - Attach ladder

    private func scanForPeripheral() {
        guard !isStopped, central.state == .poweredOn, active == nil else { return }

        // 1. Stored identifier (validated via attachIntent)
        if let id = persistedID,
           let p = central.retrievePeripherals(withIdentifiers: [id]).first,
           attachIntent(for: p) != .ignore {
            return handle(p)
        }

        // 2. OS-connected peripheral, both UUIDs (matches G7SensorKit)
        for p in central.retrieveConnectedPeripherals(withServices: [G7UUID.advertisement, G7UUID.dataService])
            where attachIntent(for: p) != .ignore { return handle(p) }

        // 3. Passive scan + connection events. CB will deliver via delegates.
        central.registerForConnectionEvents(options: [
            CBConnectionEventMatchingOption.serviceUUIDs: [G7UUID.advertisement, G7UUID.dataService]
        ])
        central.scanForPeripherals(withServices: [G7UUID.advertisement], options: nil)
        log("scan_started known_sensor=\(knownSensorName ?? "nil")")
        noteStatus(.searching)
    }

    /// 2-second settle delay before re-entering listen state. Mirrors G7SensorKit's scanAfterDelay.
    private func scanAfterDelay() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scanForPeripheral() }
    }

    /// Mirrors G7SensorKit's shouldConnectPeripheral byte-for-byte for candidate rules.
    /// Adoption flow (auto-accept first reliable EGV) differs from G7SensorKit's
    /// delegate-mediated flow — see summary table.
    private func attachIntent(for p: CBPeripheral) -> AttachIntent {
        guard let name = p.name else { return .ignore }
        guard name.hasPrefix("DXCM") || name.hasPrefix("DX02") else { return .ignore }

        if let known = knownSensorName, name.suffix(2) == known.suffix(2) {
            return .makeActive
        } else if knownSensorName == nil {
            return .connect
        }
        return .ignore
    }

    private func handle(_ p: CBPeripheral) {
        guard !isStopped else {
            log("connect_skipped reason=stopped peripheral=\(p.identifier.uuidString)")
            return
        }
        let intent = attachIntent(for: p)
        guard intent != .ignore, active == nil else { return }
        active = p
        p.delegate = self
        // Defensive cleanup of any leftover buffered backfill from prior abnormal teardown.
        backfillBuffer.removeAll()
        if central.isScanning { central.stopScan() }
        central.connect(p, options: nil) // No connect timeout. Let CB do its thing.
        bumpSessionWatchdog(progress: "connect_called")
        log("connect_called intent=\(intent) peripheral=\(p.identifier.uuidString) name=\(p.name ?? "nil")")
    }

    // MARK: - Stall-style session watchdog

    /// Re-arms the watchdog with a fresh deadline. Called after every meaningful CB callback
    /// so a healthy long-lived session never trips the timer; only true silence does.
    /// The progress label is captured into the watchdog closure so when the timer fires, the
    /// log identifies the LAST successful step before silence (not the cause of the stall).
    private func bumpSessionWatchdog(progress: String) {
        sessionWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.active else { return }
            self.log("session_watchdog_fired last_progress=\(progress) peripheral=\(p.identifier.uuidString)")
            self.central.cancelPeripheralConnection(p)
        }
        sessionWatchdog = work
        queue.asyncAfter(deadline: .now() + sessionWatchdogTimeout, execute: work)
    }

    private func cancelSessionWatchdog() {
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
    }

    // MARK: - Glucose parsing & save

    private func parseGlucose(_ data: Data) {
        guard data.count >= 19, data[1] == 0 else { return }
        let messageTimestamp = UInt32(littleEndian: data.integer(at: 2))
        let sequence = UInt16(littleEndian: data.integer(at: 6))
        let age = UInt16(littleEndian: data.integer(at: 10))
        let glucoseBytes = UInt16(littleEndian: data.integer(at: 12))
        let algorithmState = data[14]
        guard glucoseBytes != 0xffff else { return }
        let glucose = Int(glucoseBytes & 0x0fff)

        // Algorithm-state filtering: only state 6 (.ok) is "hasReliableGlucose".
        guard algorithmState == G7AlgorithmState.ok else {
            log("egv_unreliable algorithm_state=\(algorithmState) glucose=\(glucose) sequence=\(sequence)")
            return
        }

        // Sequence-based dedup (one per real reading).
        if let lastSeq = lastReadingSequence, lastSeq == sequence {
            log("egv_dedup glucose=\(glucose) sequence=\(sequence)")
            return
        }
        lastReadingSequence = sequence

        noteStatus(.active)

        bleEGVsToday += 1
        persistDailyCounters()
        mirrorDailyCountersToWatchState()

        if sessionActivationDate == nil {
            sessionActivationDate = Date().addingTimeInterval(-TimeInterval(messageTimestamp))
        }
        guard let activation = sessionActivationDate else { return }
        let readingTs = messageTimestamp >= UInt32(age) ? messageTimestamp - UInt32(age) : messageTimestamp
        let readingDate = activation.addingTimeInterval(TimeInterval(readingTs))
        let trendRate = data[15] == 0x7f ? nil : Double(Int8(bitPattern: data[15])) / 10.0
        let trend = trendArrow(trendRate)

        // Lock sensor identity on FIRST RELIABLE GLUCOSE. Mirrors G7SensorKit's
        // handleGlucoseMessage flow: identity is set when delegate accepts the new sensor,
        // not at auth completion. We auto-accept (no UI), so the moment we have a reliable
        // reading is the moment we lock.
        if knownSensorName == nil, let name = active?.name {
            knownSensorName = name
            log("sensor_name_locked name=\(name)")
        }

        // Lazy-enable backfill notify on first glucose (matches G7SensorKit ordering).
        if let p = active, let bf = chars[G7UUID.backfill], !bf.isNotifying {
            log("backfill_notify_requested")
            p.setNotifyValue(true, for: bf)
        }

        bumpSessionWatchdog(progress: "egv_received")

        let delta: String = {
            guard let previous = lastSavedGlucoseValue else { return "--" }
            return String(format: "%+d", glucose - previous)
        }()
        lastSavedGlucoseValue = glucose

        let snapshot = TrioComplicationSnapshot(
            glucose: "\(glucose)", trend: trend, delta: delta,
            readingDate: readingDate, date: Date(),
            state: "g7_direct_ble", glucoseColor: nil, source: .g7DirectBLE
        )
        log("egv_received glucose=\(glucose) delta=\(delta) sequence=\(sequence) trend=\(trend) algorithm_state=\(algorithmState) age_s=\(age) message_timestamp=\(messageTimestamp) reading_epoch=\(Int(readingDate.timeIntervalSince1970))")

        Task { @MainActor in
            TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
            WatchState.shared.applyG7DirectBleSnapshot(snapshot)
        }
    }

    private func trendArrow(_ rate: Double?) -> String {
        guard let r = rate else { return "" }
        switch r {
        case ..<(-2): return "DoubleDown"
        case ..<(-1): return "SingleDown"
        case ..<1: return "Flat"
        case ..<2: return "SingleUp"
        default: return "DoubleUp"
        }
    }

    // MARK: - Backfill

    /// Parses G7SensorKit's 9-byte G7BackfillMessage layout (verified byte-for-byte against
    /// G7BackfillMessage.swift). Layout:
    ///   bytes 0-2: timestamp (3 bytes, seconds since pairing)
    ///   byte  3:   unused/padding
    ///   bytes 4-5: glucose (UInt16, mask 0xfff if not 0xffff)
    ///   byte  6:   algorithm state
    ///   byte  7:   flags (bit 0x10 = glucoseIsDisplayOnly)
    ///   byte  8:   trend rate (Int8 / 10.0; 0x7f = nil)
    private func parseBackfill(_ data: Data) -> G7BackfillEntry? {
        guard data.count == 9 else { return nil }
        let timestamp = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16)
        let glucoseBytes = UInt16(littleEndian: data.integer(at: 4))
        let glucose: UInt16? = (glucoseBytes != 0xffff) ? (glucoseBytes & 0x0fff) : nil
        let algoState = data[6]
        let displayOnly = (data[7] & 0x10) != 0
        let trendRate = data[8] == 0x7f ? nil : Double(Int8(bitPattern: data[8])) / 10.0
        return G7BackfillEntry(
            timestamp: timestamp, glucose: glucose,
            algorithmState: algoState, displayOnly: displayOnly, trendRate: trendRate
        )
    }

    /// Mirrors G7SensorKit's flushBackfillBuffer. Triggered on backfillFinished (0x59) on control,
    /// or on disconnect (since backfillFinished may not arrive). Build 192: log only.
    /// Build 193 will route entries to a historical-readings consumer.
    private func flushBackfillBuffer(reason: String) {
        guard !backfillBuffer.isEmpty else { return }
        log("backfill_flush count=\(backfillBuffer.count) reason=\(reason)")
        for entry in backfillBuffer {
            log("backfill_entry timestamp=\(entry.timestamp) glucose=\(entry.glucose.map(String.init) ?? "nil") algorithm_state=\(entry.algorithmState) display_only=\(entry.displayOnly) trend=\(entry.trendRate.map { String(format: "%.1f", $0) } ?? "nil")")
        }
        backfillBuffer.removeAll()
    }

    private func log(_ msg: String) {
        Task { await WatchLogger.shared.log("event=g7_ble \(msg)") }
    }
}

// MARK: - Central delegate

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("central_state state=\(c.state.rawValue)")
        switch c.state {
        case .poweredOff, .unauthorized, .unsupported:
            if !isStopped { noteStatus(.unavailable) }
        default:
            break
        }
        if c.state == .poweredOn { scanForPeripheral() }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in restored where attachIntent(for: p) != .ignore { handle(p) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if attachIntent(for: p) != .ignore { handle(p) }
    }

    func centralManager(_ c: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for p: CBPeripheral) {
        if event == .peerConnected {
            bleConnectionEventsToday += 1
            persistDailyCounters()
            mirrorDailyCountersToWatchState()
        }
        if event == .peerConnected, active == nil, attachIntent(for: p) != .ignore { handle(p) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("did_connect peripheral=\(p.identifier.uuidString) name=\(p.name ?? "nil")")
        guard active?.identifier == p.identifier else {
            log("did_connect_ignored peripheral=\(p.identifier.uuidString) active=\(active?.identifier.uuidString ?? "nil")")
            return
        }
        noteStatus(.connecting)
        persistedID = p.identifier
        if c.isScanning { c.stopScan() }
        bumpSessionWatchdog(progress: "did_connect")
        bleConnectsToday += 1
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        log("discover_services_started services=[\(G7UUID.dataService)]")
        p.discoverServices([G7UUID.dataService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard active?.identifier == p.identifier else {
            log("did_fail_to_connect_ignored peripheral=\(p.identifier.uuidString)")
            return
        }
        log("connect_failed error=\(error?.localizedDescription ?? "nil")")
        teardownAndRescan(error: error, peripheral: p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard active?.identifier == p.identifier else {
            log("disconnect_ignored peripheral=\(p.identifier.uuidString)")
            return
        }
        log("disconnect error=\(error?.localizedDescription ?? "nil") pendingAuth=\(pendingAuth)")
        teardownAndRescan(error: error, peripheral: p)
    }

    /// Mirrors G7SensorKit's peripheralDidDisconnect: if the known sensor disconnected remotely
    /// while pendingAuth, the Dexcom app likely stopped the session. Clear identity so the next
    /// attach can adopt a new sensor.
    private func teardownAndRescan(error: Error?, peripheral: CBPeripheral) {
        cancelSessionWatchdog()
        flushBackfillBuffer(reason: "disconnect")

        let isRemoteDisconnect: Bool
        if let nsError = error as NSError?,
           nsError.domain == CBErrorDomain,
           nsError.code == CBError.peripheralDisconnected.rawValue {
            isRemoteDisconnect = true
        } else {
            isRemoteDisconnect = false
        }

        let disconnectedMatchedKnown: Bool = {
            guard let known = knownSensorName, let name = peripheral.name else { return false }
            return name.suffix(2) == known.suffix(2)
        }()

        if pendingAuth, isRemoteDisconnect, disconnectedMatchedKnown {
            log("suspected_end_of_session clearing_sensor_identity prior_name=\(knownSensorName ?? "nil")")
            knownSensorName = nil
            persistedID = nil
            // New sensor's sequence space is unrelated to the previous sensor's;
            // reset to avoid spurious dedup against a stale value.
            lastReadingSequence = nil
            lastSavedGlucoseValue = nil
        }

        active = nil
        chars.removeAll()
        sessionActivationDate = nil
        pendingAuth = false
        if !isStopped {
            scanAfterDelay()
        }
    }
}

// MARK: - Peripheral delegate

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("discover_services_failed error=\(error.localizedDescription)")
            central.cancelPeripheralConnection(p)
            return
        }
        bumpSessionWatchdog(progress: "services_discovered")
        for s in p.services ?? [] where s.uuid == G7UUID.dataService {
            log("discover_chars_started service=\(s.uuid)")
            p.discoverCharacteristics(
                [G7UUID.authentication, G7UUID.control, G7UUID.backfill],
                for: s
            )
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error {
            log("discover_chars_failed service=\(s.uuid) error=\(error.localizedDescription)")
            central.cancelPeripheralConnection(p)
            return
        }
        bumpSessionWatchdog(progress: "chars_discovered")
        for c in s.characteristics ?? [] { chars[c.uuid] = c }
        if let auth = chars[G7UUID.authentication], !auth.isNotifying {
            log("auth_notify_requested")
            p.setNotifyValue(true, for: auth)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("notify_state_failed char=\(c.uuid) error=\(error.localizedDescription)")
            // Auth and control notify failures are session-fatal. Cancel for fast re-attach.
            // Backfill notify failure is non-fatal.
            if c.uuid == G7UUID.authentication || c.uuid == G7UUID.control {
                central.cancelPeripheralConnection(p)
            }
            return
        }
        log("notify_state_ok char=\(c.uuid) notifying=\(c.isNotifying)")
        // Char-specific bump label so a watchdog firing in post-EGV backfill silence is identifiable.
        bumpSessionWatchdog(progress: "notify_state_ok_\(c.uuid)")

        // Mirror G7SensorKit: set pendingAuth only AFTER auth notify is actually enabled.
        if c.uuid == G7UUID.authentication, c.isNotifying {
            pendingAuth = true
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("value_update_failed char=\(c.uuid) error=\(error.localizedDescription)")
            // Auth and control value-update failures are session-fatal. Backfill failure non-fatal.
            if c.uuid == G7UUID.authentication || c.uuid == G7UUID.control {
                central.cancelPeripheralConnection(p)
            }
            return
        }
        guard let data = c.value, !data.isEmpty else { return }
        bumpSessionWatchdog(progress: "value_update_\(c.uuid)")
        switch c.uuid {
        case G7UUID.authentication:
            // 0x05 authChallengeRx: bytes [1]=authenticated, [2]=bonded
            if data.first == G7Opcode.authChallengeRx,
               data.count > 2, data[1] == 1, data[2] == 1,
               let control = chars[G7UUID.control], !control.isNotifying {
                pendingAuth = false
                log("auth_authenticated_bonded control_notify_requested")
                p.setNotifyValue(true, for: control)
            }
        case G7UUID.control:
            // Sensor pushes 0x4E glucose unsolicited. We never write to control.
            switch data.first {
            case G7Opcode.glucoseTx:
                parseGlucose(data)
            case G7Opcode.backfillFinished:
                log("backfill_finished bytes=\(data.count)")
                flushBackfillBuffer(reason: "backfillFinished")
            default:
                break
            }
        case G7UUID.backfill:
            if let entry = parseBackfill(data) {
                backfillBuffer.append(entry)
            } else {
                log("backfill_parse_failed bytes=\(data.count)")
            }
        default: break
        }
    }
}

// MARK: - Helpers

private extension Data {
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        subdata(in: offset ..< offset + MemoryLayout<T>.size)
            .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
