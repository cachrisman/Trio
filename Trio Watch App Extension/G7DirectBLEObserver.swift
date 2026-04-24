import CoreBluetooth
import Foundation

final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    private enum Constants {
        static let restoreID = "org.nightscout.trio.watch.g7-observer"
        static let service = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
        static let febcService = CBUUID(string: "FEBC")
        static let authCharacteristic = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
        static let controlCharacteristic = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
        static let backfillCharacteristic = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
        static let jpakeCharacteristic = CBUUID(string: "F8084533-849E-531C-C594-30F1F86A4EA5")
        static let glucoseRequestOpcode = UInt8(0x4e)
        static let scanTimeout: TimeInterval = 12
        static let reconnectDelay: TimeInterval = 2
        static let authAdvanceFallback: TimeInterval = 4
        static let requestCadence: TimeInterval = 295
    }

    private let queue = DispatchQueue(label: "org.nightscout.trio.watch.g7-observer")
    private lazy var central: CBCentralManager = {
        CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionRestoreIdentifierKey: Constants.restoreID])
    }()

    private var shouldRun = false
    private var scanning = false
    private var connectedPeripheral: CBPeripheral?
    private var candidatePeripherals: [UUID: CBPeripheral] = [:]
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var activationBaseDate: Date?
    private var hasSentRequest = false
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var requestWorkItem: DispatchWorkItem?
    private var authFallbackWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
        _ = central
    }

    func handleSceneDidBecomeActive() {
        queue.async {
            self.shouldRun = true
            self.transitionStatus(.searching)
            self.startAttachCycle(trigger: "scene_active")
        }
    }

    func handleSceneDidResignActive() {
        queue.async {
            if self.shouldRun {
                self.transitionStatus(.searching)
            }
        }
    }

    func stop() {
        queue.async {
            self.shouldRun = false
            self.cancelTimers()
            if let peripheral = self.connectedPeripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.stopScanIfNeeded(reason: "stop")
            self.connectedPeripheral = nil
            self.transitionStatus(.off)
        }
    }

    private func startAttachCycle(trigger: String) {
        guard shouldRun else { return }
        guard central.state == .poweredOn else {
            log("event=g7_ble_blocked_central_state state=\(central.state.rawValue) trigger=\(trigger)")
            transitionStatus(.unavailable)
            return
        }

        cancelTimers()
        hasSentRequest = false
        authCharacteristic = nil
        controlCharacteristic = nil

        let retrieved = central.retrieveConnectedPeripherals(withServices: [Constants.service])
        if let peripheral = choosePeripheral(from: retrieved) {
            connect(peripheral, source: "retrieved_data_service")
            return
        }

        let febcRetrieved = central.retrieveConnectedPeripherals(withServices: [Constants.febcService])
        if let peripheral = choosePeripheral(from: febcRetrieved) {
            connect(peripheral, source: "retrieved_febc")
            return
        }

        startScan()
    }

    private func choosePeripheral(from candidates: [CBPeripheral]) -> CBPeripheral? {
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { lhs, rhs in
            (lhs.name ?? "") < (rhs.name ?? "")
        }
        return sorted.first { candidate in
            let name = (candidate.name ?? "").uppercased()
            return name.contains("DXCM") || name.contains("DEXCOM") || name.contains("G7")
        } ?? sorted.first
    }

    private func startScan() {
        guard !scanning else { return }
        scanning = true
        transitionStatus(.searching)
        log("event=g7_ble_scan_start allow_duplicates=true")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            if self.connectedPeripheral != nil {
                self.log("event=g7_ble_scan_timeout_ignored reason=already_connected")
                return
            }
            self.log("event=g7_ble_scan_timeout reconnect=true")
            self.stopScanIfNeeded(reason: "timeout")
            self.scheduleReconnect(reason: "scan_timeout")
        }
        scanTimeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Constants.scanTimeout, execute: work)
    }

    private func stopScanIfNeeded(reason: String) {
        guard scanning else { return }
        scanning = false
        central.stopScan()
        log("event=g7_ble_scan_stopped reason=\(reason)")
    }

    private func connect(_ peripheral: CBPeripheral, source: String) {
        stopScanIfNeeded(reason: "connect_attempt")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        transitionStatus(.connecting)
        log("event=g7_ble_connect_attempt source=\(source) name=\(peripheral.name ?? "nil") id=\(peripheral.identifier.uuidString)")
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect(reason: String) {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            self.log("event=g7_ble_reconnect_fired reason=\(reason)")
            self.startAttachCycle(trigger: "reconnect")
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + Constants.reconnectDelay, execute: work)
    }

    private func transitionStatus(_ status: G7DirectBLEStatus) {
        Task { @MainActor in
            WatchState.shared.updateDirectBLEStatus(status)
        }
    }

    private func log(_ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        Task {
            await WatchLogger.shared.log(message, file: file, line: line, function: function)
        }
    }

    private func cancelTimers() {
        scanTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        requestWorkItem?.cancel()
        authFallbackWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        reconnectWorkItem = nil
        requestWorkItem = nil
        authFallbackWorkItem = nil
    }

    private func enableControlAndRequest(reason: String) {
        guard let controlCharacteristic, let peripheral = connectedPeripheral else {
            log("event=g7_ble_blocked_control_not_ready reason=\(reason)")
            return
        }

        if !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        }

        sendEGVRequest(reason: reason)
    }

    private func sendEGVRequest(reason: String) {
        guard let controlCharacteristic, let peripheral = connectedPeripheral else { return }
        let payload = Data([Constants.glucoseRequestOpcode])
        peripheral.writeValue(payload, for: controlCharacteristic, type: .withResponse)
        hasSentRequest = true
        log("event=g7_ble_egv_request_sent reason=\(reason) opcode=0x4e")

        let work = DispatchWorkItem { [weak self] in
            self?.enableControlAndRequest(reason: "cadence")
        }
        requestWorkItem?.cancel()
        requestWorkItem = work
        queue.asyncAfter(deadline: .now() + Constants.requestCadence, execute: work)
    }

    private func parseAndStoreEGV(_ data: Data) {
        guard data.count >= 16 else { return }
        guard data.first == Constants.glucoseRequestOpcode else { return }

        let glucose = Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
        let trendRaw = Int16(bitPattern: UInt16(data[9]) | (UInt16(data[10]) << 8))
        let messageTimestamp = UInt32(data[11]) | (UInt32(data[12]) << 8) | (UInt32(data[13]) << 16) | (UInt32(data[14]) << 24)
        let ageSeconds = Int(data[15])

        if activationBaseDate == nil {
            activationBaseDate = Date().addingTimeInterval(-TimeInterval(messageTimestamp))
        }

        let readingDate: Date
        if let base = activationBaseDate {
            readingDate = base.addingTimeInterval(TimeInterval(messageTimestamp - UInt32(max(ageSeconds, 0))))
        } else {
            readingDate = Date().addingTimeInterval(-TimeInterval(ageSeconds))
        }

        let trend = trendArrow(for: Double(trendRaw) / 100.0)
        let snapshot = TrioComplicationSnapshot(
            glucose: String(glucose),
            trend: trend,
            delta: "--",
            readingDate: readingDate,
            date: Date(),
            source: .directBLE
        )

        Task { @MainActor in
            TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
            WatchState.shared.currentGlucose = String(glucose)
            WatchState.shared.trend = trend
            WatchState.shared.delta = "--"
            WatchState.shared.currentReadingSource = .directBLE
            WatchState.shared.recordDirectBLEReading(readingDate)
        }

        transitionStatus(.active)
        log("event=g7_ble_egv_received glucose=\(glucose) trend_raw=\(trendRaw) reading_epoch=\(Int(readingDate.timeIntervalSince1970))")
    }

    private func trendArrow(for mgdlPerMinute: Double) -> String {
        switch mgdlPerMinute {
        case let x where x <= -3: return "↓↓↓"
        case let x where x <= -2: return "↓↓"
        case let x where x <= -1: return "↓"
        case let x where x < 1: return "→"
        case let x where x < 2: return "↑"
        case let x where x < 3: return "↑↑"
        default: return "↑↑↑"
        }
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("event=g7_ble_lifecycle central_state=\(central.state.rawValue)")
        guard shouldRun else { return }
        startAttachCycle(trigger: "state_update")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("event=g7_ble_lifecycle restore_state keys=\(dict.keys.sorted().joined(separator: ","))")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard shouldRun else { return }
        let name = (peripheral.name ?? "") + " " + (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
        let upper = name.uppercased()
        let matched = upper.contains("DXCM") || upper.contains("DEXCOM") || upper.contains("G7")
        log("event=g7_ble_peripheral_discovered matched=\(matched) name=\(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI) adv=\(advertisementData)")
        guard matched else {
            return
        }
        candidatePeripherals[peripheral.identifier] = peripheral
        connect(peripheral, source: "scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard shouldRun else { return }
        log("event=g7_ble_did_connect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")
        transitionStatus(.connecting)
        stopScanIfNeeded(reason: "did_connect")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_connect_failed error_domain=\(nsError?.domain ?? "nil") error_code=\(nsError?.code ?? -1) error_desc=\(nsError?.localizedDescription ?? "nil")")
        transitionStatus(.stalled)
        scheduleReconnect(reason: "did_fail_to_connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        log("event=g7_ble_session_outcome outcome=incomplete final_stage=disconnect error_domain=\(nsError?.domain ?? "nil") error_code=\(nsError?.code ?? -1)")
        connectedPeripheral = nil
        authCharacteristic = nil
        controlCharacteristic = nil
        transitionStatus(.stalled)
        scheduleReconnect(reason: "did_disconnect")
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("event=g7_ble_services_discovered success=false error=\(error.localizedDescription)")
            scheduleReconnect(reason: "discover_services_error")
            return
        }
        log("event=g7_ble_services_discovered success=true service_count=\(peripheral.services?.count ?? 0)")
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("event=g7_ble_characteristics_discovered success=false service=\(service.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid
            if uuid == Constants.authCharacteristic {
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("event=g7_ble_auth_notify_enabled")
                authFallbackWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.enableControlAndRequest(reason: "auth_fallback_timeout")
                }
                authFallbackWorkItem = work
                queue.asyncAfter(deadline: .now() + Constants.authAdvanceFallback, execute: work)
            } else if uuid == Constants.controlCharacteristic {
                controlCharacteristic = characteristic
                log("event=g7_ble_control_characteristic_found")
                if hasSentRequest {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if uuid == Constants.backfillCharacteristic {
                log("event=g7_ble_backfill_skipped")
            } else if uuid == Constants.jpakeCharacteristic {
                log("event=g7_ble_jpake_skipped")
            }
        }

        log("event=g7_ble_characteristics_discovered success=true service=\(service.uuid.uuidString) count=\(service.characteristics?.count ?? 0)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_notify_state_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Constants.controlCharacteristic {
            log("event=g7_ble_control_notify_enabled")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_update_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        if characteristic.uuid == Constants.authCharacteristic {
            log("event=g7_ble_auth_payload_received bytes=\(data as NSData)")
            enableControlAndRequest(reason: "auth_payload")
        } else if characteristic.uuid == Constants.controlCharacteristic {
            parseAndStoreEGV(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("event=g7_ble_control_write_failed error=\(error.localizedDescription)")
            scheduleReconnect(reason: "write_failed")
            return
        }
        log("event=g7_ble_control_write_ok")
    }
}
