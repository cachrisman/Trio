import CoreBluetooth
import Foundation

@MainActor
final class G7DirectBLEObserver: NSObject {
    enum Status: String {
        case off, searching, connecting, active, stalled, unavailable

        var shortLabel: String {
            switch self {
            case .off: return "off"
            case .searching: return "search"
            case .connecting: return "conn"
            case .active: return "active"
            case .stalled: return "stalled"
            case .unavailable: return "unavail"
            }
        }
    }

    private enum UUIDs {
        static let advertisement = CBUUID(string: "FEBC")
        static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
        static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
        static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
        static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
        static let jpake = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5")
    }

    private enum Opcode {
        static let glucose = UInt8(0x4E)
        static let authStatus = UInt8(0x05)
    }

    private let onReading: (TrioComplicationSnapshot) -> Void
    private let onStatus: (Status, Date?) -> Void

    private lazy var central = CBCentralManager(
        delegate: self,
        queue: nil,
        options: [CBCentralManagerOptionRestoreIdentifierKey: "org.nightscout.trio.watch.g7observer"]
    )

    private var activePeripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var authReady = false
    private var controlReady = false
    private var seenAuthenticatedState = false
    private var reconnectTask: Task<Void, Never>?
    private var isRunning = false
    private var lastDirectBLEEventAt: Date?
    private var lastEGVDate: Date?

    init(onReading: @escaping (TrioComplicationSnapshot) -> Void, onStatus: @escaping (Status, Date?) -> Void) {
        self.onReading = onReading
        self.onStatus = onStatus
        super.init()
        _ = central
    }

    func start() {
        isRunning = true
        Task { await log("event=g7_ble_lifecycle action=start") }
        attemptAttach()
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let activePeripheral {
            central.cancelPeripheralConnection(activePeripheral)
        }
        updateStatus(.off)
        Task { await log("event=g7_ble_lifecycle action=stop") }
    }

    func sceneDidBecomeActive() {
        guard isRunning else { return }
        reconnectTask?.cancel()
        attemptAttach()
    }

    func sceneDidResignActive() {
        guard isRunning else { return }
        Task { await log("event=g7_ble_lifecycle action=scene_inactive note=no_forced_disconnect") }
    }

    private func attemptAttach() {
        guard isRunning else { return }
        guard central.state == .poweredOn else {
            updateStatus(.unavailable)
            return
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: [UUIDs.dataService]).first {
            Task { await log("event=g7_ble_connect_attempt source=retrieved_data_service id=\(connected.identifier.uuidString) name=\(connected.name ?? "nil")") }
            connect(to: connected)
            return
        }

        updateStatus(.searching)
        Task { await log("event=g7_ble_scan_start mode=febc") }
        central.scanForPeripherals(withServices: [UUIDs.advertisement], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(to peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        updateStatus(.connecting)
        central.stopScan()
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect(reason: String) {
        guard isRunning else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await log("event=g7_ble_reconnect_scheduled reason=\(reason) delay_s=3")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self.attemptAttach()
        }
    }

    private func updateStatus(_ newStatus: Status) {
        onStatus(newStatus, lastDirectBLEEventAt)
    }

    private func requestEGV(trigger: String) {
        guard let activePeripheral, let controlCharacteristic else {
            Task { await log("event=g7_ble_blocked_request reason=control_not_ready") }
            return
        }
        activePeripheral.writeValue(Data([Opcode.glucose]), for: controlCharacteristic, type: .withResponse)
        Task { await log("event=g7_ble_egv_request_sent trigger=\(trigger) opcode=0x4E") }
    }

    private func maybePromoteToActive() {
        if authReady, controlReady, seenAuthenticatedState {
            updateStatus(.active)
            requestEGV(trigger: "auth_ready")
        }
    }

    private func parseEGV(_ data: Data) -> TrioComplicationSnapshot? {
        guard data.count >= 14 else { return nil }
        let opcode = data[0]
        guard opcode == Opcode.glucose else { return nil }

        let glucose = Int(data.readUInt16LE(at: 1) & 0x0FFF)
        let trendRaw = Int(Int8(bitPattern: data[3]))
        let txTime = Int(data.readUInt32LE(at: 4))
        let age = Int(data.readUInt16LE(at: 10))
        let now = Date()

        let activationDate: Date
        if let lastEGVDate {
            activationDate = lastEGVDate.addingTimeInterval(TimeInterval(-max(age, 0)))
        } else {
            activationDate = now.addingTimeInterval(TimeInterval(-txTime))
        }
        let readingDate = activationDate.addingTimeInterval(TimeInterval(txTime - age))

        let delta = "--"
        let trend = Self.arrow(for: trendRaw)

        return TrioComplicationSnapshot(
            glucose: String(glucose),
            trend: trend,
            delta: delta,
            readingDate: readingDate,
            date: now,
            glucoseColor: nil,
            source: .directBLE
        )
    }

    private static func arrow(for trend: Int) -> String {
        switch trend {
        case ..<(-3): return "↓↓"
        case -3 ..< -1: return "↓"
        case -1 ... 1: return "→"
        case 2 ... 3: return "↑"
        default: return "↑↑"
        }
    }

    private func log(_ line: String, file: String = #fileID, function: String = #function, lineNumber: Int = #line) async {
        await WatchLogger.shared.log(line, file: file, function: function, line: lineNumber)
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await log("event=g7_ble_central_state state=\(central.state.rawValue)")
            if self.isRunning {
                self.attemptAttach()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor [weak self] in
            await self?.log("event=g7_ble_restore keys=\(dict.keys.joined(separator: ","))")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = peripheral.name ?? "nil"
            await log("event=g7_ble_peripheral_discovered id=\(peripheral.identifier.uuidString) name=\(name) rssi=\(RSSI.intValue) adv=\(advertisementData)")
            guard name.lowercased().contains("dexcom") || name.uppercased().hasPrefix("DX") else {
                await log("event=g7_ble_peripheral_skipped reason=name_filter name=\(name)")
                return
            }
            await log("event=g7_ble_connect_attempt source=scan id=\(peripheral.identifier.uuidString) name=\(name)")
            self.connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await log("event=g7_ble_did_connect id=\(peripheral.identifier.uuidString)")
            self.updateStatus(.connecting)
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await log("event=g7_ble_disconnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "nil")")
            self.authCharacteristic = nil
            self.controlCharacteristic = nil
            self.authReady = false
            self.controlReady = false
            self.seenAuthenticatedState = false
            if self.isRunning {
                self.updateStatus(.stalled)
                self.scheduleReconnect(reason: "disconnect")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let nserr = error as NSError?
            await log("event=g7_ble_connect_failed error_domain=\(nserr?.domain ?? "nil") error_code=\(nserr?.code ?? -1) error_desc=\(error?.localizedDescription ?? "nil")")
            self.updateStatus(.stalled)
            self.scheduleReconnect(reason: "connect_failed")
        }
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await log("event=g7_ble_services_discovered id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "nil")")
            peripheral.services?.forEach { service in
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await log("event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) error=\(error?.localizedDescription ?? "nil")")

            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case UUIDs.authentication:
                    self.authCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case UUIDs.control:
                    self.controlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case UUIDs.backfill:
                    await log("event=g7_ble_backfill_skipped")
                case UUIDs.jpake:
                    await log("event=g7_ble_jpake_skipped mode=observer")
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if characteristic.uuid == UUIDs.authentication {
                self.authReady = (error == nil)
                await log("event=g7_ble_auth_notify_enabled ok=\(error == nil)")
            }
            if characteristic.uuid == UUIDs.control {
                self.controlReady = (error == nil)
                await log("event=g7_ble_control_notify_enabled ok=\(error == nil)")
            }
            self.maybePromoteToActive()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil, let data = characteristic.value else {
                await log("event=g7_ble_update_value_error char=\(characteristic.uuid.uuidString) error=\(error?.localizedDescription ?? "nil")")
                return
            }

            if characteristic.uuid == UUIDs.authentication {
                await log("event=g7_ble_auth_payload_received bytes=\(data.map { String(format: "%02X", $0) }.joined())")
                if data.first == Opcode.authStatus, data.count > 1, data[1] > 0 {
                    self.seenAuthenticatedState = true
                    self.maybePromoteToActive()
                }
                return
            }

            if characteristic.uuid == UUIDs.control {
                if let snapshot = self.parseEGV(data) {
                    self.lastDirectBLEEventAt = Date()
                    self.lastEGVDate = snapshot.readingDate
                    self.onReading(snapshot)
                    self.onStatus(.active, self.lastDirectBLEEventAt)
                    await log("event=g7_ble_egv_received glucose=\(snapshot.glucose) reading_epoch=\(Int(snapshot.readingDate.timeIntervalSince1970))")
                } else {
                    await log("event=g7_ble_control_payload_received bytes=\(data.map { String(format: "%02X", $0) }.joined())")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                await log("event=g7_ble_control_write_failed error=\(error.localizedDescription)")
                self.scheduleReconnect(reason: "control_write_failed")
            } else {
                await log("event=g7_ble_write_ok char=\(characteristic.uuid.uuidString)")
            }
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
