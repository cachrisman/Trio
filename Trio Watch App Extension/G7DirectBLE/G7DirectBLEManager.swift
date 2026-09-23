import CoreBluetooth
import Foundation

final class G7DirectBLEManager: NSObject {
    static let shared = G7DirectBLEManager()

    private let centralQueue = DispatchQueue(label: "trio.watch.g7.ble.central")
    private lazy var central = CBCentralManager(delegate: self, queue: centralQueue, options: [
        CBCentralManagerOptionRestoreIdentifierKey: "trio.watch.g7.ble.central"
    ])

    private var peripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var backfillCharacteristic: CBCharacteristic?

    private var isActiveScene = false
    private var isAuthReady = false
    private var connectAttemptStartedAt: Date?
    private var connectBackoff: TimeInterval = 2
    private var connectTimeoutTimer: DispatchSourceTimer?
    private var egvRequestTimer: DispatchSourceTimer?

    private let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    private let authCharacteristicID = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    private let controlCharacteristicID = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    private let backfillCharacteristicID = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    private let jpakeCharacteristicID = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")

    private let egvRequestOpcode: UInt8 = 0x4E

    override private init() {
        super.init()
    }

    func onSceneActive() {
        isActiveScene = true
        Task { await log("event=g7_ble_lifecycle scene=active") }
        centralQueue.async { [weak self] in
            self?.startIfPossible()
        }
    }

    func onSceneInactive() {
        isActiveScene = false
        Task { await log("event=g7_ble_lifecycle scene=inactive ble_continues=true") }
    }

    func stop() {
        centralQueue.async { [weak self] in
            guard let self else { return }
            self.isActiveScene = false
            self.cancelTimers()
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.authCharacteristic = nil
            self.controlCharacteristic = nil
            self.backfillCharacteristic = nil
            self.isAuthReady = false
            TrioComplicationDataStore.shared.setDirectBLEStatus(.off)
        }
    }

    private func startIfPossible() {
        guard isActiveScene else { return }

        guard central.state == .poweredOn else {
            Task { await log("event=g7_ble_blocked_unavailable state=\(central.state.rawValue)") }
            TrioComplicationDataStore.shared.setDirectBLEStatus(.unavailable)
            return
        }

        TrioComplicationDataStore.shared.setDirectBLEStatus(.searching)

        let retrieved = central.retrieveConnectedPeripherals(withServices: [dataService])
        if let candidate = retrieved.first {
            Task { await log("event=g7_ble_connect_attempt source=retrieved_data_service id=\(candidate.identifier.uuidString)") }
            connect(candidate)
            return
        }

        Task { await log("event=g7_ble_scan_start mode=allow_duplicates") }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectAttemptStartedAt = Date()
        TrioComplicationDataStore.shared.setDirectBLEStatus(.connecting)
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        armConnectTimeout()
    }

    private func armConnectTimeout() {
        connectTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: centralQueue)
        timer.schedule(deadline: .now() + 12)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.log("event=g7_ble_connect_failed error_domain=timeout error_code=1001 error_desc=connect_timeout") }
            self.handleReconnect(reason: "connect_timeout")
        }
        connectTimeoutTimer = timer
        timer.resume()
    }

    private func armEGVRequestTimer() {
        egvRequestTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: centralQueue)
        timer.schedule(deadline: .now() + 2, repeating: 120)
        timer.setEventHandler { [weak self] in
            self?.sendEGVRequest(reason: "timer")
        }
        egvRequestTimer = timer
        timer.resume()
    }

    private func sendEGVRequest(reason: String) {
        guard let peripheral, let controlCharacteristic else {
            Task { await log("event=g7_ble_blocked_control_not_ready reason=\(reason)") }
            return
        }

        let payload = Data([egvRequestOpcode])
        peripheral.writeValue(payload, for: controlCharacteristic, type: .withResponse)
        Task {
            await log("event=g7_ble_egv_request_sent opcode=0x4E reason=\(reason) write_type=with_response")
        }
    }

    private func handleReconnect(reason: String) {
        cancelTimers()
        authCharacteristic = nil
        controlCharacteristic = nil
        backfillCharacteristic = nil
        isAuthReady = false

        TrioComplicationDataStore.shared.setDirectBLEStatus(.stalled)

        connectBackoff = min(connectBackoff * 1.5, 15)
        let wait = connectBackoff

        Task { await log("event=g7_ble_retry_scheduled reason=\(reason) delay=\(Int(wait))") }

        centralQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.startIfPossible()
        }
    }

    private func cancelTimers() {
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
        egvRequestTimer?.cancel()
        egvRequestTimer = nil
    }

    private func handleAuthNotification(_ data: Data) {
        let bytes = [UInt8](data)
        let opcode = bytes.first ?? 0

        Task {
            await log("event=g7_ble_auth_payload_received opcode=0x\(String(format: "%02X", opcode)) bytes=\(bytes.count)")
        }

        if bytes.count > 1 {
            isAuthReady = true
            enableControlAndRequestIfReady(trigger: "auth_notify")
        }
    }

    private func enableControlAndRequestIfReady(trigger: String) {
        guard let peripheral, let service = peripheral.services?.first(where: { $0.uuid == dataService }) else {
            Task { await log("event=g7_ble_blocked_no_service trigger=\(trigger)") }
            return
        }

        guard isAuthReady else {
            Task { await log("event=g7_ble_blocked_auth_incomplete trigger=\(trigger)") }
            return
        }

        if let control = controlCharacteristic {
            peripheral.setNotifyValue(true, for: control)
            Task { await log("event=g7_ble_control_notify_enabled trigger=\(trigger)") }
            sendEGVRequest(reason: "auth_ready")
            armEGVRequestTimer()
            TrioComplicationDataStore.shared.setDirectBLEStatus(.active)
            return
        }

        peripheral.discoverCharacteristics(nil, for: service)
    }

    private func parseEGV(_ payload: Data) -> TrioComplicationSnapshot? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 10 else { return nil }

        let glucose = Int(bytes[2]) | (Int(bytes[3]) << 8)
        let trendRaw = Int8(bitPattern: bytes[6])
        let age = Int(bytes[8])

        let trend = mapTrend(rate: trendRaw)
        let readingDate = Date().addingTimeInterval(TimeInterval(-age * 60))

        return TrioComplicationSnapshot(
            glucose: "\(glucose)",
            trend: trend,
            readingDate: readingDate,
            date: Date(),
            source: .directBLE
        )
    }

    private func mapTrend(rate: Int8) -> String {
        switch rate {
        case 3...: return "DoubleUp"
        case 2: return "SingleUp"
        case 1: return "FortyFiveUp"
        case 0: return "Flat"
        case -1: return "FortyFiveDown"
        case -2: return "SingleDown"
        default: return "DoubleDown"
        }
    }

    private func snapshotSourceTag() -> String {
        if let source = TrioComplicationDataStore.shared.latestSnapshot()?.source {
            return source.rawValue
        }
        return "none"
    }

    private func log(_ message: String, function: String = #function, file: String = #fileID, line: Int = #line) async {
        await WatchLogger.shared.log(message, function: function, file: file, line: line)
    }
}

extension G7DirectBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { await log("event=g7_ble_central_state state=\(central.state.rawValue)") }
        if central.state == .poweredOn {
            startIfPossible()
        } else {
            TrioComplicationDataStore.shared.setDirectBLEStatus(.unavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { await log("event=g7_ble_restore keys=\(dict.keys.joined(separator: ","))") }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "unknown"
        let hasFebc = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(CBUUID(string: "FEBC")) == true
        let likelyG7 = name.lowercased().contains("dexcom") || name.uppercased().contains("DXCM") || hasFebc

        Task {
            await log("event=g7_ble_peripheral_discovered id=\(peripheral.identifier.uuidString) name=\(name) rssi=\(RSSI.intValue) has_febc=\(hasFebc)")
        }

        guard likelyG7 else {
            Task { await log("event=g7_ble_peripheral_skipped reason=name_advertisement_no_match") }
            return
        }

        central.stopScan()
        Task { await log("event=g7_ble_scan_stopped reason=candidate_found") }
        Task { await log("event=g7_ble_connect_attempt source=scan id=\(peripheral.identifier.uuidString)") }
        connect(peripheral)
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectBackoff = 2
        connectTimeoutTimer?.cancel()
        TrioComplicationDataStore.shared.setDirectBLEStatus(.connecting)

        let elapsed = connectAttemptStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        Task { await log("event=g7_ble_did_connect latency_ms=\(elapsed)") }

        peripheral.discoverServices(nil)
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        Task {
            await log(
                "event=g7_ble_connect_failed error_domain=\(nsError?.domain ?? "unknown") error_code=\(nsError?.code ?? -1) error_desc=\(nsError?.localizedDescription ?? "none") id=\(peripheral.identifier.uuidString)"
            )
        }
        handleReconnect(reason: "did_fail_to_connect")
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        let nsError = error as NSError?
        Task {
            await log("event=g7_ble_session_outcome outcome=incomplete final_stage=disconnect error=\(nsError?.localizedDescription ?? "none")")
        }
        handleReconnect(reason: "disconnect")
    }
}

extension G7DirectBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { await log("event=g7_ble_services_discovered status=error error=\(error.localizedDescription)") }
            handleReconnect(reason: "discover_services_error")
            return
        }

        let uuids = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "none"
        Task { await log("event=g7_ble_services_discovered status=ok services=\(uuids)") }

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Task { await log("event=g7_ble_characteristics_discovered status=error error=\(error.localizedDescription)") }
            return
        }

        let chars = service.characteristics ?? []
        let characteristicIDs = chars.map { $0.uuid.uuidString }.joined(separator: ",")
        Task { await log("event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) chars=\(characteristicIDs)") }

        for characteristic in chars {
            switch characteristic.uuid {
            case authCharacteristicID:
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                Task { await log("event=g7_ble_auth_notify_enabled") }
            case controlCharacteristicID:
                controlCharacteristic = characteristic
            case backfillCharacteristicID:
                backfillCharacteristic = characteristic
                Task { await log("event=g7_ble_backfill_discovered action=log_only") }
            case jpakeCharacteristicID:
                Task { await log("event=g7_ble_jpake_skipped reason=observer_only") }
            default:
                continue
            }
        }

        enableControlAndRequestIfReady(trigger: "characteristics_discovered")
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task { await log("event=g7_ble_notify_enable_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)") }
            return
        }

        Task {
            await log("event=g7_ble_notify_enabled char=\(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task { await log("event=g7_ble_update_value_error char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)") }
            return
        }

        guard let data = characteristic.value else { return }

        if characteristic.uuid == authCharacteristicID {
            handleAuthNotification(data)
            return
        }

        if characteristic.uuid == controlCharacteristicID {
            let opcode = data.first ?? 0
            Task { await log("event=g7_ble_control_payload_received opcode=0x\(String(format: "%02X", opcode)) bytes=\(data.count)") }

            guard opcode == egvRequestOpcode, let snapshot = parseEGV(data) else {
                return
            }

            TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
            TrioComplicationDataStore.shared.setDirectBLEStatus(.active)
            TrioComplicationDataStore.shared.setLastDirectBLEEvent(at: Date())

            Task {
                await log("event=g7_ble_egv_received glucose=\(snapshot.glucose) trend=\(snapshot.trend) reading_date=\(snapshot.readingDate.timeIntervalSince1970)")
                await log("event=g7_ble_snapshot_saved source=directBLE previous_source=\(snapshotSourceTag())")
            }

            Task { @MainActor in
                NotificationCenter.default.post(name: .g7DirectBLESnapshotSaved, object: snapshot)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task { await log("event=g7_ble_control_write_failed char=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)") }
            handleReconnect(reason: "control_write_failed")
            return
        }
        Task { await log("event=g7_ble_control_write_ok char=\(characteristic.uuid.uuidString)") }
        _ = peripheral
    }
}

extension Notification.Name {
    static let g7DirectBLESnapshotSaved = Notification.Name("g7DirectBLESnapshotSaved")
}
