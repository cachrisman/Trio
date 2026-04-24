import CoreBluetooth
import Foundation

/// Watch-only G7 eavesdrop observer. Dexcom G7 watch app owns the session; Trio attaches via same-device CoreBluetooth
/// (G7SensorKit `G7BluetoothManager.swift`, DiaBLE `BluetoothDelegate.swift`).
final class G7DirectBLEManager: NSObject {
    static let shared = G7DirectBLEManager()

    private let queue = DispatchQueue(label: "com.trio.g7directble", qos: .userInitiated)
    private var central: CBCentralManager!
    private weak var watchState: WatchState?

    // BLE thread (queue) state
    private var shouldRun = false
    private var connectBackoff: TimeInterval = 0.5
    private var sessionStart: Date?
    private var receivedEGVThisSession = false
    private var egvRequestTimer: DispatchSourceTimer?
    private var authWatchdog: DispatchSourceTimer?
    private var isScanning = false

    private var targetPeripheral: CBPeripheral?
    private var connectSourceTag = ""
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var backfillCharacteristic: CBCharacteristic?
    private var activationDate: Date?
    private var authReady = false
    private var controlNotifying = false
    private var lastConnectAttempt: Date?
    private let connectAttemptTimeout: TimeInterval = 25
    private let authWatchdogTimeout: TimeInterval = 90

    private let userDefaults = UserDefaults.standard
    private let kLastPeripheralUUIDKey = "g7directble.lastPeripheralUUID"

    private override init() {
        super.init()
        queue.sync { [self] in
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [
                    CBCentralManagerOptionShowPowerAlertKey: true,
                    CBCentralManagerOptionRestoreIdentifierKey: kG7DirectBLERestoreIdentifier
                ]
            )
        }
    }

    func bind(watchState: WatchState) {
        self.watchState = watchState
    }

    /// Call from `MainActor` / SwiftUI when the watch scene is active.
    func start() {
        queue.async { [self] in
            self.shouldRun = true
            self.sessionStart = Date()
            self.receivedEGVThisSession = false
            self.connectBackoff = 0.5
            G7BLELog.log("event=g7_ble_lifecycle phase=start shouldRun=true")
            self.performWorkAfterAttach(reason: "scene_active")
        }
    }

    /// Hard off (tests / product), not from `ScenePhase` baseline.
    func stop() {
        queue.async { [self] in
            if self.receivedEGVThisSession {
                if let s = self.sessionStart {
                    let duration = Int(Date().timeIntervalSince(s) * 1000)
                    G7BLELog.log("event=g7_ble_session_outcome outcome=success final_stage=egv duration_ms=\(duration) g7_session=watch_observer")
                }
            } else {
                if let s = self.sessionStart {
                    let duration = Int(Date().timeIntervalSince(s) * 1000)
                    G7BLELog.log("event=g7_ble_session_outcome outcome=incomplete final_stage=stop duration_ms=\(duration) g7_session=watch_observer")
                }
            }
            self.shouldRun = false
            self.cancelTimers()
            self.central?.stopScan()
            self.isScanning = false
            if let p = self.targetPeripheral { self.central?.cancelPeripheralConnection(p) }
        }
        G7BLELog.log("event=g7_ble_lifecycle phase=stop")
        Task { @MainActor in
            self.watchState?.g7DirectBLEStatus = .off
            self.watchState?.g7DirectBLEStatusLabel = "off"
        }
    }

    // MARK: - Work loop

    private func performWorkAfterAttach(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard shouldRun, let c = central else { return }
        if c.state != .poweredOn {
            G7BLELog.log("event=g7_ble_blocked_unavailable reason=cb_state_\(c.state.rawValue) detail=\(reason)")
            return
        }

        if let p = targetPeripheral, p.state == .connecting, let start = lastConnectAttempt,
           Date().timeIntervalSince(start) > connectAttemptTimeout
        {
            G7BLELog.log("event=g7_ble_connect_failed source=\(connectSourceTag) error_desc=connect_attempt_timeout_s=\(Int(connectAttemptTimeout))")
            c.cancelPeripheralConnection(p)
        }

        if let p = targetPeripheral, p.state == .connected { return }
        if let p = targetPeripheral, p.state == .connecting { return }

        if let idStr = userDefaults.string(forKey: kLastPeripheralUUIDKey), let u = UUID(uuidString: idStr) {
            let list = c.retrievePeripherals(withIdentifiers: [u])
            if let p = list.first, self.nameMatchesG7(p.name) {
                connectSourceTag = "retrieved_identifier"
                beginConnect(p)
                return
            }
        }

        for p in c.retrieveConnectedPeripherals(withServices: [G7BLEAdvertisement.febc]) {
            if nameMatchesG7(p.name) {
                connectSourceTag = "retrieved_febc"
                beginConnect(p)
                return
            }
        }
        for p in c.retrieveConnectedPeripherals(withServices: [G7BLEService.cgm]) {
            if nameMatchesG7(p.name) {
                connectSourceTag = "retrieved_data_service"
                beginConnect(p)
                return
            }
        }

        startScanIfNeeded()
    }

    private func startScanIfNeeded() {
        guard let c = central, !c.isScanning, targetPeripheral == nil else { return }
        c.registerForConnectionEvents(
            options: [CBConnectionEventMatchingOption.serviceUUIDs: [G7BLEAdvertisement.febc, G7BLEService.cgm]]
        )
        c.scanForPeripherals(withServices: [G7BLEAdvertisement.febc], options: [CBCentralManagerOptionAllowDuplicatesKey: true])
        isScanning = true
        connectSourceTag = "scan"
        G7BLELog.log("event=g7_ble_scan_start allow_duplicates=true service=FEBC")
        Task { @MainActor in
            self.watchState?.g7DirectBLEStatus = .searching
            self.watchState?.g7DirectBLEStatusLabel = "searching"
        }
    }

    private func stopScanIfConnected() {
        central?.stopScan()
        isScanning = false
        G7BLELog.log("event=g7_ble_scan_stopped")
    }

    // MARK: - Name filter (DiaBLE-style, tolerant)

    private func nameMatchesG7(_ name: String?) -> Bool {
        guard let n = name, !n.isEmpty else { return true }
        let u = n.uppercased()
        if u.hasPrefix("DXCM") { return n.count >= 2 }
        if u.hasPrefix("DX02") { return n.count >= 2 }
        if u.hasPrefix("DX01") { return n.count >= 2 }
        if u.hasPrefix("DEXCOM") { return n.count >= 2 }
        return true
    }

    // MARK: - Connect

    private func beginConnect(_ peripheral: CBPeripheral) {
        lastConnectAttempt = Date()
        targetPeripheral = peripheral
        peripheral.delegate = self
        G7BLELog.log(
            "event=g7_ble_connect_attempt source=\(connectSourceTag) peripheral_id=\(peripheral.identifier) name=\(peripheral.name ?? "nil")"
        )
        Task { @MainActor in
            self.watchState?.g7DirectBLEStatus = .connecting
            self.watchState?.g7DirectBLEStatusLabel = "connecting"
        }
        let opts: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ]
        central?.connect(peripheral, options: opts)
    }

    private func increaseBackoff() {
        connectBackoff = min(30, connectBackoff * 1.5)
    }

    private func resetBackoff() {
        connectBackoff = 0.5
    }

    private func scheduleReconnect() {
        let delay = min(8, connectBackoff)
        G7BLELog.log("event=g7_ble_lifecycle schedule_reconnect after_s=\(String(format: "%.1f", delay))")
        increaseBackoff()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performWorkAfterAttach(reason: "reconnect")
        }
    }

    // MARK: - GATT

    private func onConnected() {
        dispatchPrecondition(condition: .onQueue(queue))
        receivedEGVThisSession = false
        authReady = false
        controlNotifying = false
        authCharacteristic = nil
        controlCharacteristic = nil
        backfillCharacteristic = nil
        if let p = targetPeripheral {
            G7BLELog.log("event=g7_ble_did_connect peripheral_id=\(p.identifier) name=\(p.name ?? "nil") source=\(connectSourceTag)")
            resetBackoff()
            p.discoverServices([G7BLEService.cgm, G7BLEService.serviceB])
        }
    }

    private func startAuthWatchdog() {
        authWatchdog?.cancel()
        let t = DispatchSource.makeTimer(queue: queue)
        t.schedule(deadline: .now() + authWatchdogTimeout)
        t.setEventHandler { [weak self] in
            guard let self, !self.authReady, self.shouldRun else { return }
            G7BLELog.log("event=g7_ble_blocked_auth_incomplete reason=watchdog_s=\(Int(self.authWatchdogTimeout))")
            Task { @MainActor in
                self.watchState?.g7DirectBLEStatus = .stalled
                self.watchState?.g7DirectBLEStatusLabel = "stalled"
            }
        }
        t.resume()
        authWatchdog = t
    }

    private func subscribeAuth() {
        guard let a = authCharacteristic, let p = targetPeripheral else { return }
        p.setNotifyValue(true, for: a)
        G7BLELog.log("event=g7_ble_auth_notify_enabling char=\(a.uuid)")
        startAuthWatchdog()
    }

    private func onAuthPayload(_ data: Data) {
        guard !data.isEmpty else { return }
        G7BLELog.log(
            "event=g7_ble_auth_payload_received opcode=0x\(String(format: "%02x", data[0])) len=\(data.count) hex_preview=\(data.prefix(32).map { String(format: "%02x", $0) }.joined())"
        )
        if let m = G7AuthChallengeRxMessage(data: data), m.isBonded, m.isAuthenticated {
            if !authReady {
                G7BLELog.log("event=g7_ble_auth_ready bonded=true auth=true")
                authReady = true
                authWatchdog?.cancel()
            }
            enableControlNotifyIfReady()
            sendEGVRequest(reason: "auth_0x05")
            scheduleEGVRequestTimer()
        }
    }

    private func enableControlNotifyIfReady() {
        guard let c = controlCharacteristic, let p = targetPeripheral, authReady, !c.isNotifying else { return }
        p.setNotifyValue(true, for: c)
        G7BLELog.log("event=g7_ble_control_notify_enabling char=\(c.uuid)")
    }

    private func sendEGVRequest(reason: String) {
        guard let ctrl = controlCharacteristic, let p = targetPeripheral, authReady else {
            G7BLELog.log("event=g7_ble_blocked_control_write reason=not_ready")
            return
        }
        p.writeValue(Data([G7Opcode.glucoseTx.rawValue]), for: ctrl, type: .withResponse)
        G7BLELog.log("event=g7_ble_egv_request_sent reason=\(reason) write_type=withResponse opcode=0x4e")
    }

    private func scheduleEGVRequestTimer() {
        egvRequestTimer?.cancel()
        let t = DispatchSource.makeTimer(queue: queue)
        t.schedule(deadline: .now() + 4 * 60 + 50, repeating: 4 * 60 + 50)
        t.setEventHandler { [weak self] in
            self?.sendEGVRequest(reason: "timer_4m50s")
        }
        t.resume()
        egvRequestTimer = t
    }

    private func handleControlData(_ data: Data) {
        guard !data.isEmpty, data[0] == G7Opcode.glucoseTx.rawValue else { return }
        if let m = G7GlucoseMessage(data: data) {
            receivedEGVThisSession = true
            G7BLELog.log(
                "event=g7_ble_egv_received seq=\(m.sequence) glucose=\(m.glucose.map { String($0) } ?? "nil") alg=\(m.algorithmState.rawValue) ts=\(m.messageTimestamp) age_s=\(m.age)"
            )
            applyGlucose(m)
        } else {
            G7BLELog.log("event=g7_ble_egv_parse_fail len=\(data.count)")
        }
    }

    private func applyGlucose(_ m: G7GlucoseMessage) {
        if activationDate == nil, let p = targetPeripheral {
            activationDate = Date().addingTimeInterval(-TimeInterval(m.messageTimestamp))
            userDefaults.set(p.identifier.uuidString, forKey: kLastPeripheralUUIDKey)
        }
        guard let act = activationDate, let g = m.glucose, m.hasReliableGlucose else {
            G7BLELog.log("event=g7_ble_egv_skipped reason=no_value_or_warmup alg=\(m.algorithmState.rawValue)")
            return
        }
        let reading = act.addingTimeInterval(TimeInterval(m.glucoseTimestamp))
        let s = min(max(g, G7GlucoseLimits.minimum), G7GlucoseLimits.maximum)
        let tStr = m.trendString
        let snap = TrioComplicationSnapshot(
            glucoseDisplay: String(s),
            trendArrow: tStr,
            readingDate: reading,
            ingestDate: Date(),
            dataSource: .g7DirectBLE
        )
        let colorHex = colorHexForGlucose(mgPerDl: Int(s))
        Task { @MainActor in
            G7ComplicationDeltaState.previousGlucose = nil
            self.watchState?.lastG7DirectBLEEventDate = reading
            self.watchState?.applyG7DirectSnapshot(snap, colorHex: colorHex)
            G7BLELog.log("event=g7_ble_snapshot_saved source=g7DirectBLE reading_date=\(reading) glucose=\(s)")
        }
    }

    private func colorHexForGlucose(mgPerDl: Int) -> String {
        if mgPerDl < 80 { return "#ff8c00" }
        if mgPerDl < 200 { return "#4cd964" }
        if mgPerDl < 250 { return "#ffcc00" }
        return "#ff3b30"
    }

    private func cancelTimers() {
        egvRequestTimer?.cancel()
        egvRequestTimer = nil
        authWatchdog?.cancel()
        authWatchdog = nil
    }

}

// MARK: - CBCentral

extension G7DirectBLEManager: CBCentralManagerDelegate {
    func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let pList = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = pList.first {
            G7BLELog.log("event=g7_ble_lifecycle will_restore_state peripherals=\(pList.count) first_id=\(p.identifier)")
            targetPeripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            G7BLELog.log("event=g7_ble_lifecycle cb=powered_on")
            performWorkAfterAttach(reason: "powered_on")
        } else {
            G7BLELog.log("event=g7_ble_blocked_unavailable state=\(c.state.rawValue)")
            Task { @MainActor in
                self.watchState?.g7DirectBLEStatus = .unavailable
                self.watchState?.g7DirectBLEStatusLabel = "unavailable"
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.prefix(4).map { String(format: "%02x", $0) }
            .joined() ?? "nil"
        G7BLELog.log(
            "event=g7_ble_peripheral_discovered name=\(peripheral.name ?? "nil") id=\(peripheral.identifier) rssi=\(RSSI) mfg=\(mfg) adv_keys=\(advertisementData.keys.sorted().joined(separator: ","))"
        )
        if !nameMatchesG7(peripheral.name) {
            G7BLELog.log("event=g7_ble_peripheral_skipped name=\(peripheral.name ?? "nil") reason=name_pattern")
            return
        }
        if targetPeripheral == nil {
            connectSourceTag = "scan"
            beginConnect(peripheral)
        }
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopScanIfConnected()
        targetPeripheral = peripheral
        onConnected()
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let n = error as NSError?
        G7BLELog.log(
            "event=g7_ble_connect_failed source=\(connectSourceTag) error_domain=\(n?.domain ?? "nil") error_code=\(n?.code ?? -1) error_desc=\(n?.localizedDescription ?? "unknown")"
        )
        targetPeripheral = nil
        scheduleReconnect()
        Task { @MainActor in
            self.watchState?.g7DirectBLEStatus = .stalled
            self.watchState?.g7DirectBLEStatusLabel = "stalled"
        }
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        G7BLELog.log("event=g7_ble_did_disconnect peripheral=\(peripheral.identifier) err=\(error.map { $0.localizedDescription } ?? "none")")
        let run = shouldRun
        cancelTimers()
        authReady = false
        controlNotifying = false
        targetPeripheral = nil
        if run { scheduleReconnect() }
        Task { @MainActor in
            if run {
                self.watchState?.g7DirectBLEStatus = .stalled
                self.watchState?.g7DirectBLEStatusLabel = "disconnect"
            }
        }
    }
}

// MARK: - Peripheral

extension G7DirectBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let e = error {
            G7BLELog.log("event=g7_ble_services_discovered error=\(e.localizedDescription)")
            return
        }
        for s in peripheral.services ?? [] {
            if s.uuid == G7BLEService.cgm {
                G7BLELog.log("event=g7_ble_services_discovered uuid=\(s.uuid) label=cgm")
                peripheral.discoverCharacteristics(nil, for: s)
            } else if s.uuid == G7BLEService.serviceB {
                G7BLELog.log("event=g7_ble_services_discovered uuid=\(s.uuid) label=serviceB_jpake")
                peripheral.discoverCharacteristics([G7BLECharacteristic.serviceB_E, G7BLECharacteristic.serviceB_F], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let e = error {
            G7BLELog.log("event=g7_ble_characteristics_discovered err=\(e.localizedDescription)")
            return
        }
        for ch in service.characteristics ?? [] {
            G7BLELog.log("event=g7_ble_characteristics_discovered uuid=\(ch.uuid) props=\(ch.properties.rawValue)")
            switch ch.uuid {
            case G7BLECharacteristic.authentication: authCharacteristic = ch
            case G7BLECharacteristic.control: controlCharacteristic = ch
            case G7BLECharacteristic.backfill: backfillCharacteristic = ch
            case G7BLECharacteristic.serviceB_E, G7BLECharacteristic.serviceB_F:
                G7BLELog.log("event=g7_ble_jpake_discovered char=\(ch.uuid) (no_notify_safety)")
            default: break
            }
        }
        if service.uuid == G7BLEService.cgm, let a = authCharacteristic, let c = controlCharacteristic {
            G7BLELog.log("event=g7_ble_services_ready auth=\(a.uuid) control=\(c.uuid) backfill=\(backfillCharacteristic != nil)")
            subscribeAuth()
        } else if service.uuid == G7BLEService.cgm, authCharacteristic == nil || controlCharacteristic == nil {
            G7BLELog.log("event=g7_ble_blocked_missing_chars auth=\(authCharacteristic != nil) control=\(controlCharacteristic != nil)")
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let e = error {
            G7BLELog.log("event=g7_ble_error char=\(characteristic.uuid) \(e.localizedDescription)")
        }
        guard let v = characteristic.value, !v.isEmpty else { return }
        if characteristic.uuid == G7BLECharacteristic.authentication {
            onAuthPayload(v)
        } else if characteristic.uuid == G7BLECharacteristic.control {
            handleControlData(v)
        } else if characteristic.uuid == G7BLECharacteristic.backfill {
            G7BLELog.log("event=g7_ble_backfill_ignored len=\(v.count)")
        }
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if characteristic.uuid == G7BLECharacteristic.authentication {
            G7BLELog.log("event=g7_ble_auth_notify_enabled success=\(error == nil) notifying=\(characteristic.isNotifying)")
        }
        if characteristic.uuid == G7BLECharacteristic.control, characteristic.isNotifying {
            controlNotifying = true
            G7BLELog.log("event=g7_ble_control_notify_enabled success=\(error == nil)")
            Task { @MainActor in
                self.watchState?.g7DirectBLEStatus = .active
                self.watchState?.g7DirectBLEStatusLabel = "active"
                self.watchState?.lastG7DirectBLEEventDate = Date()
            }
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if characteristic.uuid == G7BLECharacteristic.control, let e = error {
            G7BLELog.log("event=g7_ble_connect_failed source=control_write error_desc=\(e.localizedDescription)")
        }
    }
}
