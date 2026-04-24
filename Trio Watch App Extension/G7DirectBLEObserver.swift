import CoreBluetooth
import Foundation

private enum G7BLEUUID {
    static let advertisement = CBUUID(string: "FEBC")
    static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let communication = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    static let jPake = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5")
}

private enum G7BLEOpcode: UInt8 {
    case authStatusReply = 0x05
    case egv = 0x4e
    case backfillFinished = 0x59

    var byte: UInt8 { rawValue }
}

private enum G7ObserverStage: String {
    case idle
    case waitingForBluetooth
    case retrieving
    case scanning
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case observingAuth
    case enablingControl
    case requestingEGV
    case receivingEGV
    case stopped
}

private struct G7ObservedGlucose {
    let glucose: UInt16
    let predicted: UInt16?
    let glucoseIsDisplayOnly: Bool
    let messageTimestamp: UInt32
    let sequence: UInt16
    let trendRate: Double?
    let age: UInt16
    let algorithmState: UInt8
    let readingDate: Date
    let activationDate: Date
}

final class G7DirectBLEObserver: NSObject {
    static let shared = G7DirectBLEObserver()

    private let queue = DispatchQueue(label: "org.nightscout.trio.watch.g7DirectBLEObserver", qos: .utility)
    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var sourceForPeripheral: [UUID: String] = [:]
    private var persistedPeripheralIdentifier: UUID? {
        get {
            guard let value = UserDefaults.standard.string(forKey: "G7DirectBLEObserver.peripheralIdentifier") else { return nil }
            return UUID(uuidString: value)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: "G7DirectBLEObserver.peripheralIdentifier")
        }
    }

    private var stage: G7ObserverStage = .idle
    private var isForegroundActive = false
    private var hasReceivedForegroundEntry = false
    private var isHardStopped = false
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var egvRequestWorkItem: DispatchWorkItem?
    private var controlWriteRetryWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var sessionStartDate: Date?
    private var sessionID = UUID()
    private var sessionEGVCount = 0
    private var failedAttempts = 0
    private var controlNotifyEnabled = false
    private var authNotifyEnabled = false
    private var authFallbackWorkItem: DispatchWorkItem?
    private var hasAdvancedBeyondAuth = false
    private var lastSavedGlucose: (value: Int, date: Date)?
    /// Anchored once per connect cycle so consecutive EGV parses share the same activation instant (sub-second drift fix).
    private var sessionActivationDate: Date?
    private var controlWriteConsecutiveFailures = 0

    private let scanTimeout: TimeInterval = 15
    private let connectTimeout: TimeInterval = 20
    private let authFallbackDelay: TimeInterval = 6
    /// Fallback EGV request cadence when auth-transition triggers are sparse (~sensor EGV period).
    private let egvFallbackTimerSeconds: TimeInterval = 330
    /// Shorter reschedule when control notify is not yet enabled (preserves responsiveness vs 330s fallback).
    private let egvControlNotReadyRetryDelay: TimeInterval = 60
    private let controlWriteRetryDelay: TimeInterval = 10
    /// Consecutive failed control EGV **write acks** before `control_write_retries_exhausted` reconnect.
    /// **4** means the **fourth** failure ends the cycle: one initial failed write plus **three** retries at
    /// `controlWriteRetryDelay` (synthesis MOD-A / blueprint “cap of 3” = three retry attempts, not three total failures).
    private let maxConsecutiveControlWriteFailuresBeforeReconnect = 4
    private let minimumSavedReadingSpacing: TimeInterval = 60

    private override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "org.nightscout.trio.watch.g7DirectBLEObserver"]
        )
    }

    func applyForegroundActiveEntry() {
        WatchState.shared.applyG7DirectBleStatus(.searching)
        log("event=g7_ble_lifecycle action=foreground_active central_state=\(centralManager.state.rawValue)")
        queue.async { [weak self] in
            guard let self else { return }
            self.isForegroundActive = true
            self.hasReceivedForegroundEntry = true
            self.isHardStopped = false
            self.failedAttempts = 0
            self.startOrResume(reason: "foreground_active")
        }
    }

    func noteForegroundInactiveOrBackground(_ phase: String) {
        log("event=g7_ble_lifecycle action=scene_non_active phase=\(phase) policy=no_teardown stage=\(stage.rawValue)")
        queue.async { [weak self] in
            self?.isForegroundActive = false
        }
    }

    func stop() {
        WatchState.shared.applyG7DirectBleStatus(.off)
        queue.async { [weak self] in
            guard let self else { return }
            self.isHardStopped = true
            self.isForegroundActive = false
            self.hardStopOnQueue(reason: "explicit_stop")
        }
    }

    private func startOrResume(reason: String) {
        guard !isHardStopped else {
            log("event=g7_ble_lifecycle action=start_blocked reason=hard_stopped")
            return
        }

        guard centralManager.state == .poweredOn else {
            stage = .waitingForBluetooth
            noteStatus(.unavailable)
            log("event=g7_ble_lifecycle action=start_waiting reason=\(reason) central_state=\(centralManager.state.rawValue)")
            return
        }

        if let peripheral = activePeripheral, peripheral.state == .connected {
            log("event=g7_ble_lifecycle action=resume_connected reason=\(reason) peripheral_id=\(peripheral.identifier.uuidString)")
            noteStatus(sessionEGVCount > 0 ? .active : .connecting)
            discoverServicesIfNeeded(peripheral)
            return
        }

        cancelReconnect()
        beginAttachLadder(reason: reason)
    }

    private func beginAttachLadder(reason: String) {
        stage = .retrieving
        noteStatus(.searching)
        log("event=g7_ble_lifecycle action=attach_ladder_start reason=\(reason)")

        if let identifier = persistedPeripheralIdentifier,
           let peripheral = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first,
           shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: "retrieved_identifier") {
            connect(peripheral, source: "retrieved_identifier")
            return
        }

        var retrievedAny = false
        var seenIdentifiers = Set<UUID>()
        for (service, source) in [
            (G7BLEUUID.dataService, "retrieved_data_service"),
            (G7BLEUUID.advertisement, "retrieved_febc")
        ] {
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [service]) {
                guard !seenIdentifiers.contains(peripheral.identifier) else { continue }
                seenIdentifiers.insert(peripheral.identifier)
                retrievedAny = true
                if shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: source) {
                    connect(peripheral, source: source)
                    return
                }
            }
        }

        if !retrievedAny {
            let combinedServices = [G7BLEUUID.dataService, G7BLEUUID.advertisement]
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: combinedServices) {
                guard !seenIdentifiers.contains(peripheral.identifier) else { continue }
                seenIdentifiers.insert(peripheral.identifier)
                retrievedAny = true
                let source = sourceForRetrievedService(peripheral)
                if shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: source) {
                    connect(peripheral, source: source)
                    return
                }
            }
        }

        log("event=g7_ble_blocked_no_retrieved_candidate retrieved_any=\(retrievedAny)")
        startScanning(reason: "attach_ladder_no_retrieved_candidate")
    }

    private func sourceForRetrievedService(_ peripheral: CBPeripheral) -> String {
        if let services = peripheral.services?.map(\.uuid), services.contains(G7BLEUUID.dataService) {
            return "retrieved_data_service"
        }
        return "retrieved_febc"
    }

    private func startScanning(reason: String) {
        guard centralManager.state == .poweredOn else {
            log("event=g7_ble_blocked_scan central_state=\(centralManager.state.rawValue)")
            noteStatus(.unavailable)
            return
        }
        guard activePeripheral?.state != .connected else {
            log("event=g7_ble_scan_start_skipped reason=already_connected")
            return
        }

        stage = .scanning
        noteStatus(.searching)
        log("event=g7_ble_scan_start reason=\(reason) services=nil")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        centralManager.registerForConnectionEvents(options: [
            CBConnectionEventMatchingOption.serviceUUIDs: [
                G7BLEUUID.advertisement,
                G7BLEUUID.dataService
            ]
        ])
        scheduleScanTimeout()
    }

    private func scheduleScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activePeripheral?.state != .connected else {
                self.log("event=g7_ble_scan_timeout_ignored reason=already_connected")
                return
            }
            self.log("event=g7_ble_scan_stopped reason=timeout timeout_s=\(Int(self.scanTimeout))")
            self.centralManager.stopScan()
            self.stage = .idle
            self.scheduleReconnect(reason: "scan_timeout")
        }
        scanTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + scanTimeout, execute: workItem)
    }

    private func connect(_ peripheral: CBPeripheral, source: String) {
        scanTimeoutWorkItem?.cancel()
        if centralManager.isScanning {
            centralManager.stopScan()
            log("event=g7_ble_scan_stopped reason=connect_candidate")
        }

        activePeripheral = peripheral
        sourceForPeripheral[peripheral.identifier] = source
        peripheral.delegate = self
        stage = .connecting
        sessionID = UUID()
        sessionStartDate = Date()
        sessionEGVCount = 0
        controlNotifyEnabled = false
        authNotifyEnabled = false
        hasAdvancedBeyondAuth = false
        sessionActivationDate = nil
        controlWriteConsecutiveFailures = 0
        controlWriteRetryWorkItem?.cancel()
        controlWriteRetryWorkItem = nil
        characteristics.removeAll()
        noteStatus(.connecting)
        log("event=g7_ble_connect_attempt source=\(source) peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")
        centralManager.connect(
            peripheral,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        )
        scheduleConnectTimeout(for: peripheral)
    }

    private func scheduleConnectTimeout(for peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        let id = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activePeripheral?.identifier == id, peripheral.state != .connected else {
                self.log("event=g7_ble_connect_timeout_ignored reason=already_connected peripheral_id=\(id.uuidString)")
                return
            }
            self.log("event=g7_ble_connect_failed reason=timeout peripheral_id=\(id.uuidString)")
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.scheduleReconnect(reason: "connect_timeout")
        }
        connectTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + connectTimeout, execute: workItem)
    }

    private func shouldConnect(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]?,
        rssi: NSNumber?,
        source: String
    ) -> Bool {
        let name = peripheral.name ?? advertisementData?[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (advertisementData?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let manufacturerData = advertisementData?[CBAdvertisementDataManufacturerDataKey] as? Data
        let isConnectable = (advertisementData?[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let hasG7Name = name.map { $0.hasPrefix("DXCM") || $0.hasPrefix("DX02") || $0.hasPrefix("DX01") || $0.hasPrefix("Dexcom") } ?? false
        let hasG7Service = serviceUUIDs.contains(G7BLEUUID.advertisement) || serviceUUIDs.contains(G7BLEUUID.dataService)
        let matched = isConnectable && (hasG7Name || hasG7Service || source.hasPrefix("retrieved_") || source == "restored_state")
        let details = "source=\(source) peripheral_id=\(peripheral.identifier.uuidString) name=\(name ?? "nil") rssi=\(rssi?.stringValue ?? "nil") is_connectable=\(isConnectable) services=\(serviceUUIDs.map(\.uuidString).joined(separator: ",")) manufacturer=\(manufacturerData?.hexString ?? "nil")"

        if matched {
            log("event=g7_ble_peripheral_discovered matched=true \(details)")
        } else {
            log("event=g7_ble_peripheral_skipped matched=false reason=no_g7_name_or_service \(details)")
        }
        return matched
    }

    private func discoverServicesIfNeeded(_ peripheral: CBPeripheral) {
        stage = .discoveringServices
        log("event=g7_ble_did_connect peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")
        peripheral.discoverServices(nil)
    }

    private func handleServiceDiscovery(for peripheral: CBPeripheral, error: Error?) {
        if let error {
            logError(event: "g7_ble_services_discovered", error: error, extra: "result=failure")
            scheduleReconnect(reason: "service_discovery_error")
            return
        }

        let services = peripheral.services ?? []
        log("event=g7_ble_services_discovered result=success services=\(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        stage = .discoveringCharacteristics
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    private func handleCharacteristicDiscovery(for peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error {
            logError(event: "g7_ble_characteristics_discovered", error: error, extra: "service=\(service.uuid.uuidString) result=failure")
            scheduleReconnect(reason: "characteristic_discovery_error")
            return
        }

        let discovered = service.characteristics ?? []
        for characteristic in discovered {
            characteristics[characteristic.uuid] = characteristic
        }

        log("event=g7_ble_characteristics_discovered service=\(service.uuid.uuidString) characteristics=\(discovered.map { "\($0.uuid.uuidString):\($0.properties.rawValue)" }.joined(separator: ","))")

        if discovered.contains(where: { $0.uuid == G7BLEUUID.jPake }) {
            log("event=g7_ble_jpake_skipped reason=observer_auth_posture")
        }

        guard allServicesFinishedDiscovering(peripheral) else { return }
        configureObserverCharacteristics(peripheral)
    }

    private func allServicesFinishedDiscovering(_ peripheral: CBPeripheral) -> Bool {
        guard let services = peripheral.services, !services.isEmpty else { return false }
        return services.allSatisfy { $0.characteristics != nil }
    }

    private func configureObserverCharacteristics(_ peripheral: CBPeripheral) {
        guard let auth = characteristics[G7BLEUUID.authentication] else {
            log("event=g7_ble_blocked_auth_missing")
            scheduleReconnect(reason: "auth_characteristic_missing")
            return
        }

        stage = .observingAuth
        peripheral.setNotifyValue(true, for: auth)
        log("event=g7_ble_auth_notify_enable_requested characteristic=\(auth.uuid.uuidString)")
        scheduleAuthFallback(peripheral)
    }

    private func scheduleAuthFallback(_ peripheral: CBPeripheral) {
        authFallbackWorkItem?.cancel()
        let id = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activePeripheral?.identifier == id, !self.hasAdvancedBeyondAuth else { return }
            self.log("event=g7_ble_auth_fallback reason=no_status_reply delay_s=\(Int(self.authFallbackDelay))")
            self.advanceToControl(reason: "auth_fallback_no_status_reply")
        }
        authFallbackWorkItem = workItem
        queue.asyncAfter(deadline: .now() + authFallbackDelay, execute: workItem)
    }

    private func handleNotificationState(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            let event = characteristic.uuid == G7BLEUUID.control ? "g7_ble_control_notify_enabled" : "g7_ble_auth_notify_enabled"
            logError(event: event, error: error, extra: "result=failure characteristic=\(characteristic.uuid.uuidString)")
            if characteristic.uuid == G7BLEUUID.control {
                scheduleReconnect(reason: "control_notify_error")
            }
            return
        }

        switch characteristic.uuid {
        case G7BLEUUID.authentication:
            authNotifyEnabled = characteristic.isNotifying
            log("event=g7_ble_auth_notify_enabled result=success notifying=\(characteristic.isNotifying)")
        case G7BLEUUID.control:
            controlNotifyEnabled = characteristic.isNotifying
            log("event=g7_ble_control_notify_enabled result=success notifying=\(characteristic.isNotifying)")
            if characteristic.isNotifying {
                sendEGVRequest(reason: "control_notify_enabled")
            }
        case G7BLEUUID.backfill:
            log("event=g7_ble_backfill_notify_enabled result=success notifying=\(characteristic.isNotifying)")
        default:
            log("event=g7_ble_notification_state characteristic=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying)")
        }
    }

    private func handleValueUpdate(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logError(event: "g7_ble_value_update", error: error, extra: "characteristic=\(characteristic.uuid.uuidString)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else {
            log("event=g7_ble_value_update_empty characteristic=\(characteristic.uuid.uuidString)")
            return
        }

        switch characteristic.uuid {
        case G7BLEUUID.authentication:
            handleAuthPayload(data)
        case G7BLEUUID.control:
            handleControlPayload(data)
        case G7BLEUUID.backfill:
            log("event=g7_ble_backfill_payload_received byte_count=\(data.count) preview=\(data.hexPreview)")
        case G7BLEUUID.jPake:
            log("event=g7_ble_jpake_payload_ignored byte_count=\(data.count) preview=\(data.hexPreview)")
        default:
            log("event=g7_ble_payload_received characteristic=\(characteristic.uuid.uuidString) byte_count=\(data.count) preview=\(data.hexPreview)")
        }
    }

    private func handleAuthPayload(_ data: Data) {
        let opcode = data.first ?? 0
        let authenticated = data.count > 1 ? data[1] == 1 : false
        let bonded = data.count > 2 ? data[2] == 1 : false
        log("event=g7_ble_auth_payload_received opcode=0x\(opcode.hexByte) authenticated=\(authenticated) bonded=\(bonded) byte_count=\(data.count) preview=\(data.hexPreview)")

        guard opcode == G7BLEOpcode.authStatusReply.byte else { return }
        if authenticated && bonded {
            if hasAdvancedBeyondAuth {
                sendEGVRequest(reason: "auth_transition")
            } else {
                advanceToControl(reason: "auth_authenticated_bonded")
            }
        } else if authenticated && !bonded {
            log("event=g7_ble_blocked_auth_partial authenticated=true bonded=false byte_count=\(data.count)")
        } else {
            log("event=g7_ble_blocked_auth_incomplete authenticated=false bonded=\(bonded)")
        }
    }

    private func advanceToControl(reason: String) {
        guard !hasAdvancedBeyondAuth else { return }
        guard let peripheral = activePeripheral, peripheral.state == .connected else {
            log("event=g7_ble_blocked_control_enable reason=no_connected_peripheral")
            return
        }
        guard let control = characteristics[G7BLEUUID.control] else {
            log("event=g7_ble_blocked_control_missing reason=\(reason)")
            scheduleReconnect(reason: "control_characteristic_missing")
            return
        }

        hasAdvancedBeyondAuth = true
        authFallbackWorkItem?.cancel()
        stage = .enablingControl
        log("event=g7_ble_control_notify_enable_requested reason=\(reason) characteristic=\(control.uuid.uuidString)")
        peripheral.setNotifyValue(true, for: control)

        if let backfill = characteristics[G7BLEUUID.backfill] {
            peripheral.setNotifyValue(true, for: backfill)
            log("event=g7_ble_backfill_notify_enable_requested reason=log_only_gap_recovery_candidate")
        } else {
            log("event=g7_ble_backfill_skipped reason=characteristic_missing")
        }
    }

    private func sendEGVRequest(reason: String) {
        egvRequestWorkItem?.cancel()
        controlWriteRetryWorkItem?.cancel()
        controlWriteRetryWorkItem = nil
        guard let peripheral = activePeripheral, peripheral.state == .connected else {
            log("event=g7_ble_blocked_egv_request reason=no_connected_peripheral trigger=\(reason)")
            scheduleReconnect(reason: "egv_request_no_peripheral")
            return
        }
        guard controlNotifyEnabled, let control = characteristics[G7BLEUUID.control] else {
            log("event=g7_ble_blocked_egv_request reason=control_not_ready trigger=\(reason)")
            scheduleEGVRequest(reason: "control_not_ready")
            return
        }

        stage = .requestingEGV
        let payload = Data([G7BLEOpcode.egv.byte])
        peripheral.writeValue(payload, for: control, type: .withResponse)
        log("event=g7_ble_egv_request_sent reason=\(reason) write_type=withResponse payload=\(payload.hexString)")
        if reason == "control_not_ready" {
            scheduleEGVRequest(reason: "control_not_ready")
        }
    }

    private func scheduleEGVRequest(reason: String) {
        egvRequestWorkItem?.cancel()
        let delay: TimeInterval
        let fireReason: String
        if reason == "control_not_ready" {
            delay = egvControlNotReadyRetryDelay
            fireReason = "control_not_ready"
        } else {
            delay = egvFallbackTimerSeconds
            fireReason = "fallback_timer_330s"
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.sendEGVRequest(reason: fireReason)
        }
        egvRequestWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func handleControlPayload(_ data: Data) {
        let opcode = data.first ?? 0
        log("event=g7_ble_control_payload_received opcode=0x\(opcode.hexByte) byte_count=\(data.count) preview=\(data.hexPreview)")
        switch opcode {
        case G7BLEOpcode.egv.byte:
            guard let reading = parseGlucose(data) else {
                log("event=g7_ble_blocked_egv_parse payload=\(data.hexPreview)")
                return
            }
            handleGlucose(reading)
        case G7BLEOpcode.backfillFinished.byte:
            log("event=g7_ble_backfill_finished payload=\(data.hexPreview)")
        default:
            break
        }
    }

    private func parseGlucose(_ data: Data) -> G7ObservedGlucose? {
        guard data.count >= 19, data[1] == 0 else { return nil }
        let messageTimestamp = UInt32(littleEndian: data.integer(at: 2))
        let age = UInt16(littleEndian: data.integer(at: 10))
        let glucoseBytes = UInt16(littleEndian: data.integer(at: 12))
        guard glucoseBytes != 0xffff else { return nil }
        let glucose = glucoseBytes & 0x0fff
        if sessionActivationDate == nil {
            sessionActivationDate = Date().addingTimeInterval(-TimeInterval(messageTimestamp))
        }
        guard let activationDate = sessionActivationDate else { return nil }
        let readingTimestamp = messageTimestamp >= UInt32(age) ? messageTimestamp - UInt32(age) : messageTimestamp
        let readingDate = activationDate.addingTimeInterval(TimeInterval(readingTimestamp))
        let predictionBytes = UInt16(littleEndian: data.integer(at: 16))
        let predicted = predictionBytes == 0xffff ? nil : predictionBytes & 0x0fff
        let trendRate = data[15] == 0x7f ? nil : Double(Int8(bitPattern: data[15])) / 10.0

        return G7ObservedGlucose(
            glucose: glucose,
            predicted: predicted,
            glucoseIsDisplayOnly: (data[18] & 0x10) > 0,
            messageTimestamp: messageTimestamp,
            sequence: UInt16(littleEndian: data.integer(at: 6)),
            trendRate: trendRate,
            age: age,
            algorithmState: data[14],
            readingDate: readingDate,
            activationDate: activationDate
        )
    }

    private func handleGlucose(_ reading: G7ObservedGlucose) {
        let value = Int(reading.glucose)
        if let last = lastSavedGlucose,
           last.value == value,
           abs(reading.readingDate.timeIntervalSince(last.date)) < minimumSavedReadingSpacing {
            log("event=g7_ble_egv_received action=dedup_skipped glucose=\(value) reading_epoch=\(Int(reading.readingDate.timeIntervalSince1970)) previous_epoch=\(Int(last.date.timeIntervalSince1970))")
            return
        }

        sessionEGVCount += 1
        failedAttempts = 0
        stage = .receivingEGV
        noteStatus(.active)
        persistedPeripheralIdentifier = activePeripheral?.identifier

        let previous = lastSavedGlucose
        lastSavedGlucose = (value, reading.readingDate)
        let trend = trendArrowString(from: reading.trendRate)
        let delta = previous.map { String(format: "%+d", value - $0.value) } ?? "--"
        let snapshot = TrioComplicationSnapshot(
            glucose: "\(value)",
            trend: trend,
            delta: delta,
            readingDate: reading.readingDate,
            date: Date(),
            state: "g7_direct_ble",
            glucoseColor: nil,
            source: .g7DirectBLE
        )

        log("event=g7_ble_egv_received glucose=\(value) trend_rate=\(reading.trendRate.map { String($0) } ?? "nil") trend=\(trend) delta=\(delta) sequence=\(reading.sequence) message_timestamp=\(reading.messageTimestamp) age_s=\(reading.age) reading_epoch=\(Int(reading.readingDate.timeIntervalSince1970)) activation_epoch=\(Int(reading.activationDate.timeIntervalSince1970)) algorithm_state=\(reading.algorithmState) display_only=\(reading.glucoseIsDisplayOnly)")

        Task { @MainActor in
            TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
            WatchState.shared.applyG7DirectBleSnapshot(snapshot)
            await WatchLogger.shared.log(
                "event=g7_ble_snapshot_saved glucose=\(snapshot.glucose) reading_epoch=\(Int(snapshot.readingDate.timeIntervalSince1970)) source=\(snapshot.source?.rawValue ?? "nil")"
            )
        }
    }

    private func trendArrowString(from trendRate: Double?) -> String {
        guard let trendRate else { return "" }
        switch trendRate {
        case let x where x <= -3.0: return "DoubleDown"
        case let x where x <= -2.0: return "DoubleDown"
        case let x where x <= -1.0: return "SingleDown"
        case let x where x < 1.0: return "Flat"
        case let x where x < 2.0: return "SingleUp"
        case let x where x < 3.0: return "DoubleUp"
        default: return "DoubleUp"
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isHardStopped else { return }
        cancelTransientTimers()
        if activePeripheral?.state == .connected {
            log("event=g7_ble_reconnect_skipped reason=already_connected trigger=\(reason)")
            return
        }

        failedAttempts += 1
        let delay = min(30.0, Double(2 << min(failedAttempts, 4)))
        stage = .idle
        noteStatus(.searching)
        log("event=g7_ble_reconnect_scheduled reason=\(reason) attempts=\(failedAttempts) delay_s=\(Int(delay)) foreground_active=\(isForegroundActive)")
        let workItem = DispatchWorkItem { [weak self] in
            self?.startOrResume(reason: "reconnect_\(reason)")
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hardStopOnQueue(reason: String) {
        cancelTransientTimers()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if centralManager.isScanning {
            centralManager.stopScan()
            log("event=g7_ble_scan_stopped reason=\(reason)")
        }
        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        emitSessionOutcome(outcome: "cancelled")
        activePeripheral = nil
        characteristics.removeAll()
        stage = .stopped
        log("event=g7_ble_lifecycle action=stopped reason=\(reason)")
    }

    private func cancelTransientTimers() {
        scanTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem?.cancel()
        authFallbackWorkItem?.cancel()
        egvRequestWorkItem?.cancel()
        controlWriteRetryWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        connectTimeoutWorkItem = nil
        authFallbackWorkItem = nil
        egvRequestWorkItem = nil
        controlWriteRetryWorkItem = nil
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func emitSessionOutcome(outcome: String) {
        let duration = sessionStartDate.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let finalOutcome = sessionEGVCount > 0 && outcome != "cancelled" ? "success" : outcome
        log("event=g7_ble_session_outcome outcome=\(finalOutcome) final_stage=\(stage.rawValue) duration_ms=\(duration) g7_session=\(sessionID.uuidString) egv_count=\(sessionEGVCount)")
    }

    private func noteStatus(_ status: G7DirectBLEStatus) {
        Task { @MainActor in
            WatchState.shared.applyG7DirectBleStatus(status)
        }
    }

    private func logError(event: String, error: Error, extra: String = "") {
        let nsError = error as NSError
        log("event=\(event) \(extra) error_domain=\(nsError.domain) error_code=\(nsError.code) error_desc=\(nsError.localizedDescription)")
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
        log("event=g7_ble_lifecycle action=central_state state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            noteStatus(.searching)
            if hasReceivedForegroundEntry {
                startOrResume(reason: "central_powered_on")
            } else {
                log("event=g7_ble_lifecycle action=central_powered_on_deferred reason=awaiting_foreground_active")
            }
        case .poweredOff, .unauthorized, .unsupported:
            noteStatus(.unavailable)
            cancelTransientTimers()
            if central.isScanning {
                central.stopScan()
                log("event=g7_ble_scan_stopped reason=central_unavailable")
            }
        case .resetting, .unknown:
            noteStatus(.stalled)
        @unknown default:
            noteStatus(.unavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log("event=g7_ble_lifecycle action=will_restore_state restored_peripherals=\(restored.map { $0.identifier.uuidString }.joined(separator: ","))")
        for peripheral in restored {
            peripheral.delegate = self
            if shouldConnect(peripheral: peripheral, advertisementData: nil, rssi: nil, source: "restored_state") {
                activePeripheral = peripheral
                sourceForPeripheral[peripheral.identifier] = "restored_state"
                if peripheral.state == .connected {
                    discoverServicesIfNeeded(peripheral)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if shouldConnect(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI, source: "scan") {
            connect(peripheral, source: "scan")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        connectionEventDidOccur event: CBConnectionEvent,
        for peripheral: CBPeripheral
    ) {
        log("event=g7_ble_connection_event peripheral_id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") event=\(event == .peerConnected ? "peer_connected" : "peer_disconnected")")
        if event == .peerConnected, !isHardStopped {
            startOrResume(reason: "connection_event_peer_connected")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        failedAttempts = 0
        discoverServicesIfNeeded(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        if let error {
            logError(event: "g7_ble_connect_failed", error: error, extra: "peripheral_id=\(peripheral.identifier.uuidString)")
        } else {
            log("event=g7_ble_connect_failed peripheral_id=\(peripheral.identifier.uuidString) error_desc=nil")
        }
        scheduleReconnect(reason: "connect_failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            logError(event: "g7_ble_disconnect", error: error, extra: "peripheral_id=\(peripheral.identifier.uuidString)")
            emitSessionOutcome(outcome: sessionEGVCount > 0 ? "success" : "failure")
        } else {
            log("event=g7_ble_disconnect peripheral_id=\(peripheral.identifier.uuidString) error_desc=nil")
            emitSessionOutcome(outcome: sessionEGVCount > 0 ? "success" : "incomplete")
        }

        activePeripheral = nil
        characteristics.removeAll()
        controlNotifyEnabled = false
        authNotifyEnabled = false
        hasAdvancedBeyondAuth = false
        sessionActivationDate = nil
        controlWriteConsecutiveFailures = 0
        controlWriteRetryWorkItem?.cancel()
        controlWriteRetryWorkItem = nil
        noteStatus(sessionEGVCount > 0 ? .stalled : .searching)
        scheduleReconnect(reason: "disconnect")
    }
}

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handleServiceDiscovery(for: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handleCharacteristicDiscovery(for: peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        handleNotificationState(characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        handleValueUpdate(characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == G7BLEUUID.control {
            if let error {
                logError(event: "g7_ble_control_write_failed", error: error, extra: "characteristic=\(characteristic.uuid.uuidString)")
                egvRequestWorkItem?.cancel()
                egvRequestWorkItem = nil
                controlWriteConsecutiveFailures += 1
                if controlWriteConsecutiveFailures >= maxConsecutiveControlWriteFailuresBeforeReconnect {
                    controlWriteRetryWorkItem?.cancel()
                    controlWriteRetryWorkItem = nil
                    scheduleReconnect(reason: "control_write_retries_exhausted")
                    return
                }
                log("event=g7_ble_control_write_retry_scheduled attempt=\(controlWriteConsecutiveFailures) delay_s=\(Int(controlWriteRetryDelay))")
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard self.activePeripheral?.identifier == peripheral.identifier,
                          peripheral.state == .connected,
                          self.controlNotifyEnabled,
                          let control = self.characteristics[G7BLEUUID.control] else {
                        self.scheduleReconnect(reason: "control_write_retry_aborted")
                        return
                    }
                    self.stage = .requestingEGV
                    let payload = Data([G7BLEOpcode.egv.byte])
                    peripheral.writeValue(payload, for: control, type: .withResponse)
                    self.log("event=g7_ble_egv_request_sent reason=control_write_retry attempt=\(self.controlWriteConsecutiveFailures) write_type=withResponse payload=\(payload.hexString)")
                }
                controlWriteRetryWorkItem = workItem
                queue.asyncAfter(deadline: .now() + controlWriteRetryDelay, execute: workItem)
                return
            }
            controlWriteConsecutiveFailures = 0
            controlWriteRetryWorkItem?.cancel()
            controlWriteRetryWorkItem = nil
            log("event=g7_ble_control_write_ack characteristic=\(characteristic.uuid.uuidString)")
            scheduleEGVRequest(reason: "fallback_timer_330s")
            return
        }
        if let error {
            logError(event: "g7_ble_control_write_failed", error: error, extra: "characteristic=\(characteristic.uuid.uuidString)")
            scheduleReconnect(reason: "control_write_failed")
        } else {
            log("event=g7_ble_control_write_ack characteristic=\(characteristic.uuid.uuidString)")
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var hexPreview: String {
        let prefix = self.prefix(40).hexString
        return count > 40 ? "\(prefix)...\(count)b" : prefix
    }

    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        subdata(in: offset ..< offset + MemoryLayout<T>.size).withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
}

private extension UInt8 {
    var hexByte: String {
        String(format: "%02x", self)
    }
}
