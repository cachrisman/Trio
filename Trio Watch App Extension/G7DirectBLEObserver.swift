import CoreBluetooth
import Foundation
import SwiftUI

enum G7BLEObserverStatus: String {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable
}

struct G7DirectBLEReading {
    let glucose: String
    let trend: String
    let readingDate: Date
}

private enum G7UUID {
    static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let authCharacteristic = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    static let controlCharacteristic = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let backfillCharacteristic = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let jpakeCharacteristic = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
}

private enum G7Opcode {
    static let glucose = UInt8(0x4E)
}

final class G7DirectBLEObserver: NSObject {
    var onStatus: (@MainActor (G7BLEObserverStatus) -> Void)?
    var onReading: (@MainActor (G7DirectBLEReading) -> Void)?
    var onDirectEvent: (@MainActor (Date) -> Void)?

    private lazy var central: CBCentralManager = {
        CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.trio.watch.g7observer"])
    }()

    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var authCharacteristic: CBCharacteristic?
    private var connectSource = "none"
    private var active = false
    private var authReady = false
    private var backoffSeconds: TimeInterval = 3
    private var retryWorkItem: DispatchWorkItem?

    func start() {
        active = true
        _ = central
        log("event=g7_ble_lifecycle phase=active action=start_requested")
        if central.state == .poweredOn {
            beginAttachSweep()
        }
    }

    func stop() {
        active = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        setStatus(.off)
        log("event=g7_ble_lifecycle phase=manual action=stop_requested")
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            start()
        case .inactive:
            log("event=g7_ble_lifecycle phase=inactive action=tolerated")
        case .background:
            log("event=g7_ble_lifecycle phase=background action=no_proactive_teardown")
        @unknown default:
            break
        }
    }

    private func beginAttachSweep() {
        guard active else { return }
        setStatus(.searching)
        connectSource = "retrieved_data_service"
        let connected = central.retrieveConnectedPeripherals(withServices: [G7UUID.dataService])
        if let candidate = connected.first {
            connect(candidate)
            return
        }

        log("event=g7_ble_scan_start reason=no_connected_service_match")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(_ candidate: CBPeripheral) {
        guard active else { return }
        if peripheral?.identifier == candidate.identifier { return }
        peripheral = candidate
        candidate.delegate = self
        central.stopScan()
        setStatus(.connecting)
        log("event=g7_ble_connect_attempt source=\(connectSource) id=\(candidate.identifier.uuidString) name=\(candidate.name ?? "nil")")
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleRetry(reason: String) {
        guard active else { return }
        retryWorkItem?.cancel()
        let delay = backoffSeconds
        let workItem = DispatchWorkItem { [weak self] in
            self?.beginAttachSweep()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        setStatus(.stalled)
        log("event=g7_ble_retry_scheduled reason=\(reason) delay_s=\(Int(delay))")
        backoffSeconds = min(backoffSeconds * 1.5, 20)
    }

    private func setStatus(_ status: G7BLEObserverStatus) {
        Task { @MainActor in
            await onStatus?(status)
        }
    }

    private func sendEGVRequestIfReady() {
        guard authReady, let peripheral, let controlCharacteristic else {
            log("event=g7_ble_blocked_control_write reason=auth_or_control_not_ready")
            return
        }

        let data = Data([G7Opcode.glucose])
        peripheral.writeValue(data, for: controlCharacteristic, type: .withResponse)
        log("event=g7_ble_egv_request_sent opcode=0x4E write_type=with_response")
    }

    private func parseEGV(_ payload: Data) -> G7DirectBLEReading? {
        guard payload.count >= 11 else { return nil }
        let mgdl = Int(payload[2]) | (Int(payload[3]) << 8)
        let trendRaw = Int(Int8(bitPattern: payload[4]))
        let ageSec = Int(payload[5]) * 60
        let readingDate = Date().addingTimeInterval(TimeInterval(-ageSec))
        let trend: String
        switch trendRaw {
        case ..<(-3): trend = "⇊"
        case -3..<(-1): trend = "↘"
        case -1...1: trend = "→"
        case 2...3: trend = "↗"
        default: trend = "⇈"
        }
        return G7DirectBLEReading(glucose: "\(mgdl)", trend: trend, readingDate: readingDate)
    }

    private func log(_ message: String, function: String = #function, file: String = #fileID, line: Int = #line) {
        Task {
            await WatchLogger.shared.log(message, function: function, file: file, line: line)
        }
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("event=g7_ble_state_update state=\(central.state.rawValue)")
        guard active else { return }

        switch central.state {
        case .poweredOn:
            backoffSeconds = 3
            beginAttachSweep()
        case .unsupported, .unauthorized, .poweredOff:
            setStatus(.unavailable)
        default:
            setStatus(.stalled)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log("event=g7_ble_restore peripherals=\(restored.count)")
        if let restoredFirst = restored.first {
            connectSource = "retrieved_identifier"
            connect(restoredFirst)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active else { return }
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let isMatch = localName.uppercased().contains("DXCM") || localName.uppercased().contains("DEXCOM")
        log("event=g7_ble_peripheral_discovered id=\(peripheral.identifier.uuidString) name=\(localName) rssi=\(RSSI.intValue) matched=\(isMatch)")
        guard isMatch else { return }
        connectSource = "scan"
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        backoffSeconds = 3
        authReady = false
        log("event=g7_ble_did_connect source=\(connectSource)")
        setStatus(.active)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_connect_failed error_domain=\(nsError?.domain ?? "nil") error_code=\(nsError?.code ?? -1) error_desc=\(nsError?.localizedDescription ?? "unknown")")
        scheduleRetry(reason: "did_fail_to_connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_disconnected error_domain=\(nsError?.domain ?? "nil") error_code=\(nsError?.code ?? -1)")
        self.peripheral = nil
        self.controlCharacteristic = nil
        self.authCharacteristic = nil
        scheduleRetry(reason: "did_disconnect")
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("event=g7_ble_services_discovered failure=1 error=\(error.localizedDescription)")
            scheduleRetry(reason: "discover_services_failed")
            return
        }
        let uuids = peripheral.services?.compactMap { $0.uuid.uuidString }.joined(separator: ",") ?? "none"
        log("event=g7_ble_services_discovered failure=0 services=\(uuids)")
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) failure=1 error=\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case G7UUID.authCharacteristic:
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_auth_notify_enabled")
            case G7UUID.controlCharacteristic:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_control_notify_enabled")
            case G7UUID.backfillCharacteristic:
                log("event=g7_ble_backfill_discovered action=log_only")
            case G7UUID.jpakeCharacteristic:
                log("event=g7_ble_jpake_skipped")
            default:
                continue
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_notify_update_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        if characteristic.uuid == G7UUID.controlCharacteristic {
            sendEGVRequestIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_characteristic_update_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        guard let payload = characteristic.value else { return }

        if characteristic.uuid == G7UUID.authCharacteristic {
            let preview = payload.prefix(8).map { String(format: "%02X", $0) }.joined()
            log("event=g7_ble_auth_payload_received bytes=\(payload.count) preview=\(preview)")
            authReady = true
            sendEGVRequestIfReady()
            return
        }

        if characteristic.uuid == G7UUID.controlCharacteristic {
            let preview = payload.prefix(12).map { String(format: "%02X", $0) }.joined()
            log("event=g7_ble_egv_received bytes=\(payload.count) preview=\(preview)")
            guard let reading = parseEGV(payload) else { return }
            Task { @MainActor in
                await onReading?(reading)
                await onDirectEvent?(Date())
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_control_write_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            scheduleRetry(reason: "control_write_failed")
            return
        }
        log("event=g7_ble_control_write_confirmed char=\(characteristic.uuid.uuidString)")
    }
}
