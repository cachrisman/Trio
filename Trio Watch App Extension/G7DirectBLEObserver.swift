import CoreBluetooth
import Foundation

enum G7DirectBLEStatus: String {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable
}

@MainActor
final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    private let reconnectDelaySeconds: TimeInterval = 3
    private let scanTimeoutSeconds: TimeInterval = 12

    private lazy var centralManager: CBCentralManager = {
        CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "Trio.G7DirectBLEObserver"
        ])
    }()

    private var currentPeripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var hasRequestedEGVForCurrentConnection = false
    private var hasReceivedEGVForCurrentConnection = false
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var activeSessionID = UUID().uuidString

    private override init() {
        super.init()
        _ = centralManager
    }

    func start() {
        isRunning = true
        updateStatus(.searching, note: "start")
        Task {
            await WatchLogger.shared.log("event=g7_ble_lifecycle action=start")
        }
        attemptAttach(reason: "start")
    }

    func stop() {
        isRunning = false
        scanTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        if let peripheral = currentPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        currentPeripheral = nil
        updateStatus(.off, note: "stop")
        Task {
            await WatchLogger.shared.log("event=g7_ble_lifecycle action=stop")
        }
    }

    private func attemptAttach(reason: String) {
        guard isRunning else { return }
        guard centralManager.state == .poweredOn else {
            updateStatus(.unavailable, note: "central_not_powered_on")
            return
        }

        if let connected = centralManager.retrieveConnectedPeripherals(withServices: [G7BLEServiceUUID.cgmService]).first(where: isLikelyG7) {
            connect(to: connected, source: "retrieved_data_service")
            return
        }

        updateStatus(.searching, note: reason)
        startScan(reason: reason)
    }

    private func startScan(reason: String) {
        guard isRunning else { return }
        if centralManager.isScanning {
            centralManager.stopScan()
        }

        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Task {
            await WatchLogger.shared.log("event=g7_ble_scan_start reason=\(reason)")
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.currentPeripheral != nil { return }
            self.centralManager.stopScan()
            Task {
                await WatchLogger.shared.log("event=g7_ble_scan_stopped reason=timeout")
            }
            self.scheduleReconnect(reason: "scan_timeout")
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: workItem)
    }

    private func connect(to peripheral: CBPeripheral, source: String) {
        guard isRunning else { return }
        scanTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()

        if centralManager.isScanning {
            centralManager.stopScan()
            Task {
                await WatchLogger.shared.log("event=g7_ble_scan_stopped reason=did_connect_attempt")
            }
        }

        currentPeripheral = peripheral
        peripheral.delegate = self
        hasRequestedEGVForCurrentConnection = false
        hasReceivedEGVForCurrentConnection = false
        authCharacteristic = nil
        controlCharacteristic = nil
        updateStatus(.connecting, note: source)

        Task {
            await WatchLogger.shared.log(
                "event=g7_ble_connect_attempt source=\(source) name=\(peripheral.name ?? "unknown") id=\(peripheral.identifier.uuidString)"
            )
        }

        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect(reason: String) {
        guard isRunning else { return }
        reconnectWorkItem?.cancel()
        updateStatus(.stalled, note: reason)

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.attemptAttach(reason: "reconnect_\(reason)")
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelaySeconds, execute: item)

        Task {
            await WatchLogger.shared.log("event=g7_ble_lifecycle action=reconnect_scheduled reason=\(reason) delay_s=\(Int(reconnectDelaySeconds))")
        }
    }

    private func isLikelyG7(_ peripheral: CBPeripheral) -> Bool {
        let name = (peripheral.name ?? "").uppercased()
        return name.contains("DXCM") || name.contains("DEXCOM") || name.contains("G7")
    }

    private func handleEGVData(_ data: Data) {
        guard let reading = G7GlucoseParser.parse(data) else { return }

        let snapshot = TrioComplicationSnapshot(
            glucose: String(reading.glucose),
            trend: reading.trendString,
            delta: "--",
            readingDate: reading.readingDate,
            date: Date(),
            source: .directBLE,
            state: "g7_direct_ble"
        )

        TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)

        WatchState.shared.currentGlucose = snapshot.glucose
        WatchState.shared.trend = snapshot.trend
        WatchState.shared.delta = snapshot.delta
        WatchState.shared.lastWatchStateUpdate = snapshot.readingDate
        WatchState.shared.complicationSource = .directBLE
        WatchState.shared.g7BLELastReadingAt = Date()

        hasReceivedEGVForCurrentConnection = true
        updateStatus(.active, note: "egv_received")

        Task {
            await WatchLogger.shared.log(
                "event=g7_ble_snapshot_saved glucose=\(snapshot.glucose) trend=\(snapshot.trend) reading_epoch=\(Int(snapshot.readingDate.timeIntervalSince1970))"
            )
        }
    }

    private func updateStatus(_ status: G7DirectBLEStatus, note: String) {
        WatchState.shared.g7BLEStatus = status
        if status == .active || status == .stalled || status == .searching {
            WatchState.shared.g7BLELastEventAt = Date()
        }
        Task {
            await WatchLogger.shared.log("event=g7_ble_lifecycle status=\(status.rawValue) note=\(note)")
        }
    }
}

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                await WatchLogger.shared.log("event=g7_ble_lifecycle central_state=powered_on")
                if self.isRunning {
                    self.attemptAttach(reason: "powered_on")
                }
            case .poweredOff:
                self.updateStatus(.unavailable, note: "powered_off")
            case .unauthorized:
                self.updateStatus(.unavailable, note: "unauthorized")
            default:
                self.updateStatus(.unavailable, note: "state_\(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task {
            await WatchLogger.shared.log("event=g7_ble_lifecycle action=restore_state keys=\(dict.keys.joined(separator: ","))")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let hasFEBc = serviceUUIDs.contains(G7BLEServiceUUID.advertisement)
            let candidate = self.isLikelyG7(peripheral) || hasFEBc

            await WatchLogger.shared.log(
                "event=g7_ble_peripheral_discovered name=\(peripheral.name ?? "unknown") id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) services=\(serviceUUIDs.map(\.uuidString).joined(separator: ","))"
            )

            guard candidate else {
                await WatchLogger.shared.log("event=g7_ble_peripheral_skipped reason=not_g7_like id=\(peripheral.identifier.uuidString)")
                return
            }

            self.connect(to: peripheral, source: hasFEBc ? "scan_febc" : "scan")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            await WatchLogger.shared.log("event=g7_ble_did_connect id=\(peripheral.identifier.uuidString)")
            self.activeSessionID = UUID().uuidString
            self.scanTimeoutWorkItem?.cancel()
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            await WatchLogger.shared.log("event=g7_ble_connect_failed id=\(peripheral.identifier.uuidString) error_desc=\((error as NSError?)?.localizedDescription ?? "unknown")")
            self.currentPeripheral = nil
            self.scheduleReconnect(reason: "did_fail_to_connect")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            await WatchLogger.shared.log(
                "event=g7_ble_session_outcome outcome=\(self.hasReceivedEGVForCurrentConnection ? "success" : "incomplete")"
                    + " final_stage=disconnect g7_session=\(self.activeSessionID)"
            )
            await WatchLogger.shared.log("event=g7_ble_lifecycle action=did_disconnect error_desc=\((error as NSError?)?.localizedDescription ?? "none")")
            self.currentPeripheral = nil
            self.scheduleReconnect(reason: "did_disconnect")
        }
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            await WatchLogger.shared.log(
                "event=g7_ble_services_discovered id=\(peripheral.identifier.uuidString) count=\(peripheral.services?.count ?? 0)"
            )
            guard error == nil else {
                self.scheduleReconnect(reason: "discover_services_error")
                return
            }
            peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                self.scheduleReconnect(reason: "discover_characteristics_error")
                return
            }

            await WatchLogger.shared.log(
                "event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) chars=\(service.characteristics?.map(\.uuid.uuidString).joined(separator: ",") ?? "none")"
            )

            guard let chars = service.characteristics else { return }
            for characteristic in chars {
                switch characteristic.uuid {
                case G7BLECharacteristicUUID.authentication:
                    self.authCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    await WatchLogger.shared.log("event=g7_ble_auth_notify_enabled")
                case G7BLECharacteristicUUID.control:
                    self.controlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    await WatchLogger.shared.log("event=g7_ble_control_notify_enabled")
                case G7BLECharacteristicUUID.jpake:
                    await WatchLogger.shared.log("event=g7_ble_jpake_skipped")
                case G7BLECharacteristicUUID.backfill:
                    await WatchLogger.shared.log("event=g7_ble_backfill_skipped")
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task {
            await WatchLogger.shared.log(
                "event=g7_ble_notify_state uuid=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying) error=\((error as NSError?)?.localizedDescription ?? "none")"
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil, let data = characteristic.value else { return }

            if characteristic.uuid == G7BLECharacteristicUUID.authentication {
                await WatchLogger.shared.log(
                    "event=g7_ble_auth_payload_received payload=\(data.hexPreview)"
                )
                if let auth = G7AuthState(data: data), auth.isAuthenticated {
                    guard let control = self.controlCharacteristic else {
                        await WatchLogger.shared.log("event=g7_ble_blocked_control_not_ready")
                        return
                    }
                    if !self.hasRequestedEGVForCurrentConnection {
                        self.hasRequestedEGVForCurrentConnection = true
                        peripheral.writeValue(Data([G7BLEOpcode.glucoseTx]), for: control, type: .withResponse)
                        await WatchLogger.shared.log("event=g7_ble_egv_request_sent opcode=0x4e")
                    }
                }
                return
            }

            if characteristic.uuid == G7BLECharacteristicUUID.control {
                await WatchLogger.shared.log("event=g7_ble_egv_received payload=\(data.hexPreview)")
                self.handleEGVData(data)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                await WatchLogger.shared.log("event=g7_ble_blocked_control_write_failed error=\((error as NSError).localizedDescription)")
                self.hasRequestedEGVForCurrentConnection = false
                self.scheduleReconnect(reason: "control_write_failed")
            }
        }
    }
}
