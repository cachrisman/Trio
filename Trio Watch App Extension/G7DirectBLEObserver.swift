import CoreBluetooth
import Foundation

@MainActor
protocol G7DirectBLEObserverDelegate: AnyObject {
    func g7ObserverDidUpdateStatus(_ status: WatchState.G7BLEStatus)
    func g7ObserverDidReceiveEGV(glucose: String, trend: String, delta: String, readingDate: Date)
    func g7ObserverDidRecordDirectEvent(at date: Date)
}

final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    private enum C {
        static let restoreID = "org.nightscout.trio.watch.g7observer"
        static let dexcomAdvertisementService = CBUUID(string: "FEBC")
        static let dexcomDataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
        static let controlCharacteristic = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
        static let authCharacteristic = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
        static let backfillCharacteristic = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
        static let jpakeCharacteristic = CBUUID(string: "F8084533-849E-531C-C594-30F1F86A4EA5")
        static let egvRequestOpcode = Data([0x4e])
    }

    weak var delegate: G7DirectBLEObserverDelegate?

    private let central: CBCentralManager
    private var shouldRun = false
    private var sceneActive = false

    private var peripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var lastGlucose: Int?
    private var authSeen = false
    private var requestTimer: Timer?
    private var scanTimeoutTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0

    override init() {
        central = CBCentralManager(
            delegate: nil,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: C.restoreID]
        )
        super.init()
        central.delegate = self
    }

    func start(sceneActive: Bool) {
        shouldRun = true
        self.sceneActive = sceneActive
        log("event=g7_ble_lifecycle action=start scene_active=\(sceneActive)")
        guard sceneActive else {
            updateStatus(.off)
            return
        }
        evaluateAttachPath(reason: "start")
    }

    func updateScene(active: Bool) {
        sceneActive = active
        log("event=g7_ble_lifecycle action=scene_update active=\(active)")
        if active, shouldRun {
            reconnectAttempts = 0
            evaluateAttachPath(reason: "scene_active")
        }
    }

    func stop() {
        shouldRun = false
        requestTimer?.invalidate()
        requestTimer = nil
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        authCharacteristic = nil
        controlCharacteristic = nil
        authSeen = false
        central.stopScan()
        updateStatus(.off)
        log("event=g7_ble_lifecycle action=stop")
    }

    private func evaluateAttachPath(reason: String) {
        guard shouldRun, sceneActive else { return }
        guard central.state == .poweredOn else {
            updateStatus(.unavailable)
            log("event=g7_ble_blocked_state reason=central_not_powered state=\(central.state.rawValue)")
            return
        }

        if let current = peripheral {
            if current.state == .connected {
                updateStatus(.active)
                return
            }
        }

        let connected = central.retrieveConnectedPeripherals(withServices: [C.dexcomDataService])
        if let candidate = connected.first {
            connect(candidate, source: "retrieved_data_service")
            return
        }

        scan(reason: reason)
    }

    private func scan(reason: String) {
        guard shouldRun else { return }
        updateStatus(.searching)
        log("event=g7_ble_scan_start reason=\(reason)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.peripheral == nil else {
                    self.log("event=g7_ble_scan_timeout_ignored reason=connected")
                    return
                }
                self.log("event=g7_ble_scan_timeout action=reconnect")
                self.central.stopScan()
                self.scheduleReconnect(reason: "scan_timeout")
            }
        }
    }

    private func connect(_ candidate: CBPeripheral, source: String) {
        guard shouldRun else { return }
        peripheral = candidate
        candidate.delegate = self
        updateStatus(.connecting)
        log("event=g7_ble_connect_attempt source=\(source) id=\(candidate.identifier.uuidString) name=\(candidate.name ?? "nil")")
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect(reason: String) {
        guard shouldRun, sceneActive else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 20)
        updateStatus(.stalled)
        log("event=g7_ble_reconnect_scheduled reason=\(reason) delay_s=\(Int(delay))")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.evaluateAttachPath(reason: "reconnect")
            }
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func updateStatus(_ status: WatchState.G7BLEStatus) {
        delegate?.g7ObserverDidUpdateStatus(status)
    }

    private func startEGVTimer() {
        requestTimer?.invalidate()
        requestTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sendEGVRequest(reason: "timer")
            }
        }
    }

    private func sendEGVRequest(reason: String) {
        guard shouldRun, authSeen, let peripheral, let controlCharacteristic else {
            log("event=g7_ble_blocked_egv_request reason=not_ready")
            return
        }
        peripheral.writeValue(C.egvRequestOpcode, for: controlCharacteristic, type: .withResponse)
        log("event=g7_ble_egv_request_sent reason=\(reason) write_type=withResponse")
    }

    private func decodeEGV(from data: Data) -> (glucose: Int, trend: String, readingDate: Date)? {
        // Clean-room parser, aligned to G7 control message shape from G7SensorKit Messages.
        guard data.count >= 11 else { return nil }

        let glucose = Int(UInt16(data[2]) | (UInt16(data[3]) << 8))
        guard (40...400).contains(glucose) else { return nil }

        let trendRateRaw = Int8(bitPattern: data[4])
        let trend: String
        switch trendRateRaw {
        case ..<(-6): trend = "↘︎"
        case -6..<(-2): trend = "↘"
        case -2...2: trend = "→"
        case 3...6: trend = "↗"
        default: trend = "↗︎"
        }

        let sensorSeconds = UInt32(data[5])
            | (UInt32(data[6]) << 8)
            | (UInt32(data[7]) << 16)
            | (UInt32(data[8]) << 24)
        let ageSeconds = UInt16(data[9]) | (UInt16(data[10]) << 8)
        let readingDate = Date(timeIntervalSinceNow: -TimeInterval(ageSeconds == 0 ? 0 : ageSeconds))
        _ = sensorSeconds
        return (glucose, trend, readingDate)
    }

    private func handleControlPayload(_ data: Data) {
        log("event=g7_ble_control_payload_received bytes=\(data.count)")
        guard let parsed = decodeEGV(from: data) else {
            return
        }
        let previous = lastGlucose
        lastGlucose = parsed.glucose
        let delta = previous.map { String(format: "%+d", parsed.glucose - $0) } ?? "--"

        delegate?.g7ObserverDidRecordDirectEvent(at: Date())
        delegate?.g7ObserverDidReceiveEGV(
            glucose: String(parsed.glucose),
            trend: parsed.trend,
            delta: delta,
            readingDate: parsed.readingDate
        )
        updateStatus(.active)
        log("event=g7_ble_egv_received glucose=\(parsed.glucose) trend=\(parsed.trend) reading_epoch=\(Int(parsed.readingDate.timeIntervalSince1970))")
    }

    private func log(
        _ message: String,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) {
        Task {
            await WatchLogger.shared.log(message, function: function, file: file, line: line)
        }
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("event=g7_ble_central_state state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            evaluateAttachPath(reason: "state_update")
        } else {
            updateStatus(.unavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("event=g7_ble_restore_state keys=\(dict.keys.joined(separator: ","))")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        log("event=g7_ble_peripheral_discovered name=\(peripheral.name ?? "nil") rssi=\(RSSI.intValue) id=\(peripheral.identifier.uuidString) ad=\(advertisementData)")

        let candidateName = (peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "").lowercased()
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matched = candidateName.contains("dexcom") || candidateName.contains("dxcm") || serviceUUIDs.contains(C.dexcomAdvertisementService)

        guard matched else {
            log("event=g7_ble_peripheral_skipped reason=filter_miss name=\(candidateName)")
            return
        }

        central.stopScan()
        connect(peripheral, source: "scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        updateStatus(.connecting)
        log("event=g7_ble_did_connect id=\(peripheral.identifier.uuidString)")
        peripheral.discoverServices(nil)
        central.stopScan()
        scanTimeoutTimer?.invalidate()
        startEGVTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let ns = error as NSError?
        log("event=g7_ble_connect_failed error_domain=\(ns?.domain ?? "nil") error_code=\(ns?.code ?? -1) error_desc=\(ns?.localizedDescription ?? "nil")")
        self.peripheral = nil
        scheduleReconnect(reason: "did_fail_to_connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let ns = error as NSError?
        log("event=g7_ble_disconnected error_domain=\(ns?.domain ?? "nil") error_code=\(ns?.code ?? -1) error_desc=\(ns?.localizedDescription ?? "nil")")
        self.peripheral = nil
        authCharacteristic = nil
        controlCharacteristic = nil
        authSeen = false
        scheduleReconnect(reason: "disconnect")
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("event=g7_ble_services_discovered count=\(peripheral.services?.count ?? 0)")
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        log("event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) count=\(service.characteristics?.count ?? 0)")
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case C.authCharacteristic:
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_auth_notify_enabled")
            case C.controlCharacteristic:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_control_notify_enabled")
            case C.jpakeCharacteristic:
                log("event=g7_ble_jpake_skipped")
            case C.backfillCharacteristic:
                log("event=g7_ble_backfill_skipped")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == C.authCharacteristic {
            authSeen = true
            log("event=g7_ble_auth_payload_received bytes=\(value.count)")
            sendEGVRequest(reason: "auth_payload")
        } else if characteristic.uuid == C.controlCharacteristic {
            handleControlPayload(value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_control_write_failed error=\(error.localizedDescription)")
            scheduleReconnect(reason: "control_write_failed")
        }
    }
}
