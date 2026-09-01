import CoreBluetooth
import Foundation

@MainActor
final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    enum Status: String {
        case off
        case searching
        case connecting
        case active
        case stalled
        case unavailable
    }

    private enum Constants {
        // G7 service/characteristic UUIDs based on G7SensorKit BluetoothServices + DiaBLE DexcomG7 references.
        static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
        static let authenticationCharacteristic = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
        static let controlCharacteristic = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
        static let backfillCharacteristic = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
        static let jpakeCharacteristic = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")

        // EGV request opcode from G7SensorKit Messages/G7Opcode.swift.
        static let egvRequestOpcode: UInt8 = 0x4E
        static let scanWindow: TimeInterval = 12
        static let reconnectDelay: TimeInterval = 4
    }

    private(set) var status: Status = .off
    private(set) var lastDirectBLEEventAt: Date?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var connectSource: String = "unknown"
    private var scanTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var didObserveAuthTraffic = false
    private var didPersistEGV = false

    var onStatusChange: ((Status, Date?) -> Void)?
    var onSnapshot: ((TrioComplicationSnapshot) -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.trio.watch.g7observer"
        ])
    }

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.trio.watch.g7observer"
            ])
        }

        log("event=g7_ble_lifecycle action=start")
        driveStartIfReady()
    }

    func stop(reason: String = "manual") {
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()
        scanTimeoutTask = nil
        reconnectTask = nil

        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }

        peripheral = nil
        authCharacteristic = nil
        controlCharacteristic = nil
        setStatus(.off)
        log("event=g7_ble_lifecycle action=stop reason=\(reason)")
    }

    private func driveStartIfReady() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            setStatus(.unavailable)
            log("event=g7_ble_blocked_central_not_ready state=\(central.state.rawValue)")
            return
        }

        setStatus(.searching)
        attemptRetrieveThenScan()
    }

    private func attemptRetrieveThenScan() {
        guard let central else { return }

        let connected = central.retrieveConnectedPeripherals(withServices: [Constants.dataService])
        if let candidate = connected.first {
            connect(to: candidate, source: "retrieved_data_service")
            return
        }

        log("event=g7_ble_scan_start reason=no_retrieved_match")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.scanWindow * 1_000_000_000))
            guard let self else { return }
            self.central?.stopScan()
            self.log("event=g7_ble_scan_stopped reason=timeout")
            self.scheduleReconnect(reason: "scan_timeout")
        }
    }

    private func connect(to candidate: CBPeripheral, source: String) {
        guard let central else { return }
        connectSource = source
        peripheral = candidate
        candidate.delegate = self
        setStatus(.connecting)
        log("event=g7_ble_connect_attempt source=\(source) identifier=\(candidate.identifier.uuidString) name=\(candidate.name ?? "nil")")
        central.stopScan()
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect(reason: String) {
        reconnectTask?.cancel()
        setStatus(.stalled)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("event=g7_ble_reconnect_scheduled reason=\(reason) delay_s=\(Constants.reconnectDelay)")
            try? await Task.sleep(nanoseconds: UInt64(Constants.reconnectDelay * 1_000_000_000))
            guard self.status != .off else { return }
            self.attemptRetrieveThenScan()
        }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        onStatusChange?(status, lastDirectBLEEventAt)
    }

    private func markDirectBLEEvent() {
        lastDirectBLEEventAt = Date()
        onStatusChange?(status, lastDirectBLEEventAt)
    }

    private func requestEGV() {
        guard let peripheral, let controlCharacteristic else {
            log("event=g7_ble_blocked_control_not_ready")
            return
        }
        let payload = Data([Constants.egvRequestOpcode])
        peripheral.writeValue(payload, for: controlCharacteristic, type: .withResponse)
        log("event=g7_ble_egv_request_sent bytes=\(payload.hexString)")
    }

    private func parseEGV(_ data: Data) -> TrioComplicationSnapshot? {
        // Lightweight parse aligned with G7SensorKit G7GlucoseMessage structure.
        guard data.count >= 4 else { return nil }

        let messageType = data[0]
        guard messageType == 0x4E || messageType == 0x4F else { return nil }

        let glucoseValue = Int(data[2]) | (Int(data[3]) << 8)
        guard glucoseValue > 20, glucoseValue < 500 else { return nil }

        let trendCode = data.count > 4 ? Int8(bitPattern: data[4]) : 0
        let trend = trendCodeToArrow(trendCode)

        let now = Date()
        return TrioComplicationSnapshot(
            glucose: String(glucoseValue),
            trend: trend,
            delta: nil,
            readingDate: now,
            date: now,
            source: .directBLE
        )
    }

    private func trendCodeToArrow(_ rate: Int8) -> String {
        switch rate {
        case let x where x >= 3: return "DoubleUp"
        case 2: return "SingleUp"
        case 1: return "FortyFiveUp"
        case 0: return "Flat"
        case -1: return "FortyFiveDown"
        case -2: return "SingleDown"
        default: return "DoubleDown"
        }
    }

    private func log(_ message: String, function: String = #function, file: String = #fileID, line: Int = #line) {
        Task {
            await WatchLogger.shared.log(message, function: function, file: file, line: line)
        }
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("event=g7_ble_lifecycle action=central_state state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            driveStartIfReady()
        } else {
            setStatus(.unavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log("event=g7_ble_lifecycle action=will_restore peripherals=\(restored.count)")
        if let restoredPeripheral = restored.first {
            connect(to: restoredPeripheral, source: "restored")
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        let isMatch = name.uppercased().contains("DXCM") || name.uppercased().contains("DEXCOM")

        log("event=g7_ble_peripheral_discovered name=\(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI) adv=\(advertisementData)")

        guard isMatch else {
            log("event=g7_ble_peripheral_skipped reason=name_mismatch name=\(name)")
            return
        }

        connect(to: peripheral, source: "scan")
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didObserveAuthTraffic = false
        didPersistEGV = false
        setStatus(.active)
        log("event=g7_ble_did_connect source=\(connectSource) id=\(peripheral.identifier.uuidString)")
        peripheral.discoverServices(nil)
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_connect_failed source=\(connectSource) id=\(peripheral.identifier.uuidString) error_domain=\(nsError?.domain ?? "none") error_code=\(nsError?.code ?? -1) error_desc=\(nsError?.localizedDescription ?? "nil")")
        scheduleReconnect(reason: "connect_failed")
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_session_outcome outcome=\(didPersistEGV ? "success" : "incomplete") final_stage=disconnect source=\(connectSource) error_domain=\(nsError?.domain ?? "none") error_code=\(nsError?.code ?? -1)")
        scheduleReconnect(reason: "disconnected")
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("event=g7_ble_services_discovered result=failure error=\(error.localizedDescription)")
            scheduleReconnect(reason: "service_discovery_error")
            return
        }

        log("event=g7_ble_services_discovered result=success services=\(peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "none")")
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("event=g7_ble_characteristics_discovered result=failure service=\(service.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        let uuids = service.characteristics?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "none"
        log("event=g7_ble_characteristics_discovered result=success service=\(service.uuid.uuidString) chars=\(uuids)")

        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case Constants.authenticationCharacteristic:
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_auth_notify_enabled")
            case Constants.controlCharacteristic:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_control_notify_enabled")
            case Constants.jpakeCharacteristic:
                log("event=g7_ble_jpake_skipped uuid=\(characteristic.uuid.uuidString)")
            case Constants.backfillCharacteristic:
                log("event=g7_ble_backfill_skipped uuid=\(characteristic.uuid.uuidString)")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_notify_state_updated result=failure uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        log("event=g7_ble_notify_state_updated result=success uuid=\(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying)")

        if characteristic.uuid == Constants.controlCharacteristic, characteristic.isNotifying {
            requestEGV()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_value_update result=failure uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            log("event=g7_ble_value_update result=empty uuid=\(characteristic.uuid.uuidString)")
            return
        }

        if characteristic.uuid == Constants.authenticationCharacteristic {
            didObserveAuthTraffic = true
            log("event=g7_ble_auth_payload_received bytes=\(data.hexString)")
            if controlCharacteristic != nil {
                requestEGV()
            }
            return
        }

        if characteristic.uuid == Constants.controlCharacteristic {
            log("event=g7_ble_control_payload_received bytes=\(data.hexString)")
            if let snapshot = parseEGV(data) {
                didPersistEGV = true
                markDirectBLEEvent()
                onSnapshot?(snapshot)
                log("event=g7_ble_egv_received glucose=\(snapshot.glucose) trend=\(snapshot.trend ?? "none")")
            }
            return
        }

        log("event=g7_ble_value_update uuid=\(characteristic.uuid.uuidString) bytes=\(data.hexString)")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_control_write_failed uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            scheduleReconnect(reason: "control_write_failure")
            return
        }

        log("event=g7_ble_control_write_ack uuid=\(characteristic.uuid.uuidString)")
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
