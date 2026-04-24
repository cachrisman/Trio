import CoreBluetooth
import Foundation
import WatchKit

/// Watch-side direct-BLE observer for the Dexcom G7. Attaches to the BLE
/// session owned by the official Dexcom G7 watch app on the same device via
/// same-device CoreBluetooth peripheral sharing, observes the auth handshake,
/// writes the EGV-request opcode on the control characteristic, parses EGV
/// responses, and persists them to `TrioComplicationDataStore`.
///
/// Observer-only: never writes any J-PAKE / app-key / auth-init bytes. The
/// only write this class issues is `[0x4e]` on the control characteristic,
/// which is a data request through an already-authenticated link.
///
/// See `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` for the
/// full protocol model and design decisions. Reference implementations:
/// `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`,
/// `G7SensorKit/G7CGMManager/G7Sensor.swift`, and
/// `DiaBLE/BluetoothDelegate.swift`.
final class G7DirectBLEObserver: NSObject {

    // MARK: - Public singleton

    static let shared = G7DirectBLEObserver()

    // MARK: - Public API (main actor only)

    /// Eagerly allocate the `CBCentralManager`. Call from
    /// `ExtensionDelegate.applicationDidFinishLaunching` so the central is
    /// alive before the first scene-active entry (and so `willRestoreState`
    /// can land).
    func primeCentral() {
        ensureCentralManager()
    }

    /// Called on scene transition to `.active` and on app become-active.
    /// Idempotent; safe to call repeatedly. Starts the attach ladder if
    /// not connected. Never tears down a healthy session.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        if !hasStartedAtLeastOnce {
            hasStartedAtLeastOnce = true
            G7BLELog.emit(
                G7DirectBLEConstants.Event.lifecycle,
                fields: [("phase", "start")]
            )
        } else {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.lifecycle,
                fields: [("phase", "start_reentry")]
            )
        }
        ensureCentralManager()
        bleQueue.async { [weak self] in
            self?.kickAttachIfNeeded(source: .resume)
        }
    }

    /// Explicit hard-off surface for tests / product off-switch.
    /// **Not** wired to scene-phase transitions — scene changes never
    /// call this (design §13).
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        G7BLELog.emit(
            G7DirectBLEConstants.Event.lifecycle,
            fields: [("phase", "stop")]
        )
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.isExplicitlyStopped = true
            self.stopScanOnQueue(reason: "explicit_stop")
            if let peripheral = self.activePeripheral {
                self.centralManager?.cancelPeripheralConnection(peripheral)
            }
            self.resetPerCycleStateOnQueue(outcome: "cancelled", finalStage: self.stageLabel())
            self.publishStatusOnQueue(.off)
        }
    }

    /// Scene-phase propagation. `.active` resumes attach; `.inactive` /
    /// `.background` are deliberately no-ops (design §13).
    enum ScenePhaseSignal { case active, inactive }
    func scenePhaseChanged(_ signal: ScenePhaseSignal) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch signal {
        case .active:
            bleQueue.async { [weak self] in
                self?.isExplicitlyStopped = false
            }
            G7BLELog.emit(
                G7DirectBLEConstants.Event.lifecycle,
                fields: [("phase", "scene_active")]
            )
            start()
        case .inactive:
            G7BLELog.emit(
                G7DirectBLEConstants.Event.lifecycle,
                fields: [("phase", "scene_inactive")]
            )
        }
    }

    // MARK: - Central manager / queue

    /// Dedicated serial queue for CoreBluetooth callbacks. `WatchState`
    /// and complication-data-store writes hop to `MainActor`.
    private let bleQueue = DispatchQueue(
        label: "com.trio.watch.g7.ble",
        qos: .userInitiated
    )

    /// Isolated to `bleQueue`.
    private var centralManager: CBCentralManager?

    /// Isolated to `bleQueue`.
    private var activePeripheral: CBPeripheral?

    /// Isolated to `bleQueue`. Most recent candidate we tried to connect.
    private var pendingPeripheralIdentifier: UUID?

    /// Per-cycle GATT handles. `bleQueue` only.
    private var authenticationCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var backfillCharacteristic: CBCharacteristic?
    private var jpakeCharacteristic: CBCharacteristic?

    /// Session / cycle bookkeeping. `bleQueue` only.
    private var cycleStartedAt: Date?
    private var cycleEGVCount: Int = 0
    /// Kept for a future backfill-forwarding path (design §11 future
    /// work). Currently written but not read; do not remove without
    /// revisiting the backfill integration plan.
    private var sensorActivationDate: Date?
    private var controlWriteAttemptThisCycle: Int = 0
    private var authAdvanceTimer: DispatchSourceTimer?
    private var authAdvanced: Bool = false
    private var egvFallbackTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttemptIndex: Int = 0
    private var consecutiveFailuresForPreferredIdentifier: Int = 0
    private var lastEGVMessageTimestampLogged: UInt32?

    /// Process-wide cache for local delta computation (design §DQ15).
    /// Survives reconnect cycles since we want the "previous BLE reading"
    /// to be relative to the last observed EGV, not per-cycle. Accessed
    /// only from `bleQueue`.
    private var lastBLEGlucoseCache: (Int, Date)?

    // MARK: - Main-actor observable fields (mirrors)

    /// Latched on main. UI reads `WatchState.g7ObserverSnapshot`.
    private var latestPublishedSnapshot = G7DirectBLEObserverSnapshot()

    // MARK: - Lifecycle flags

    /// Main-thread only.
    private var hasStartedAtLeastOnce = false
    /// `bleQueue`-isolated. Updated only via the hop in `stop()` and
    /// `scenePhaseChanged(.active)`.
    private var isExplicitlyStopped = false

    private override init() {
        super.init()
    }

    // MARK: - Central manager allocation

    /// Main-only flag — toggled under `bleQueue.sync` and read from main
    /// to avoid re-doing allocation work.
    private var hasAllocatedCentralManager = false

    private func ensureCentralManager() {
        dispatchPrecondition(condition: .onQueue(.main))
        if hasAllocatedCentralManager { return }
        G7BLELog.emit(
            G7DirectBLEConstants.Event.lifecycle,
            fields: [("phase", "prime")]
        )
        // `bleQueue.sync` hop so all delegate callbacks are off-main
        // (design §6) and the initializer runs on the same queue CB will
        // deliver on.
        bleQueue.sync {
            guard self.centralManager == nil else { return }
            let options: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey:
                    G7DirectBLEConstants.centralRestorationIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: self.bleQueue,
                options: options
            )
        }
        hasAllocatedCentralManager = true
    }

    // MARK: - Attach ladder (bleQueue)

    private enum KickSource { case resume, disconnect, retryBackoff, poweredOn, restored }

    private func kickAttachIfNeeded(source: KickSource) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard !isExplicitlyStopped else { return }
        guard let central = centralManager else { return }

        switch central.state {
        case .poweredOn:
            break
        case .poweredOff, .unauthorized, .unsupported:
            publishStatusOnQueue(.unavailable)
            return
        case .resetting, .unknown:
            publishStatusOnQueue(.searching)
            return
        @unknown default:
            publishStatusOnQueue(.searching)
            return
        }

        // Healthy-session guard. Any path that gets here for an already-
        // connected+ready peripheral does nothing — the teardown path is
        // only ever driven by CB disconnect / error.
        if let peripheral = activePeripheral, peripheral.state == .connected {
            return
        }

        publishStatusOnQueue(.searching)

        // 1) Persisted identifier.
        if let persisted = persistedPreferredPeripheralIdentifier(),
           let peripheral = central.retrievePeripherals(withIdentifiers: [persisted]).first {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralDiscovered,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", peripheral.name ?? "nil"),
                    ("source", G7DirectBLEConstants.ConnectSource.retrievedIdentifier.rawValue)
                ]
            )
            if evaluatePeripheral(peripheral,
                                  source: .retrievedIdentifier,
                                  kickSource: source) {
                return
            }
        }

        // 2) Connected by the system, matching the G7 data service.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [
            G7DirectBLEConstants.cgmServiceUUID
        ]) {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralDiscovered,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", peripheral.name ?? "nil"),
                    ("source", G7DirectBLEConstants.ConnectSource.retrievedDataService.rawValue)
                ]
            )
            if evaluatePeripheral(peripheral,
                                  source: .retrievedDataService,
                                  kickSource: source) {
                return
            }
        }

        // 3) Connected by the system, matching the advertisement service.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [
            G7DirectBLEConstants.advertisementServiceUUID
        ]) {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralDiscovered,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", peripheral.name ?? "nil"),
                    ("source", G7DirectBLEConstants.ConnectSource.retrievedFebc.rawValue)
                ]
            )
            if evaluatePeripheral(peripheral,
                                  source: .retrievedFebc,
                                  kickSource: source) {
                return
            }
        }

        // 4) Scan.
        if central.isScanning { return }
        G7BLELog.emit(
            G7DirectBLEConstants.Event.scanStart,
            fields: [("kick_source", String(describing: source))]
        )
        central.scanForPeripherals(
            withServices: [
                G7DirectBLEConstants.advertisementServiceUUID,
                G7DirectBLEConstants.cgmServiceUUID
            ],
            options: nil
        )
        publishStatusOnQueue(.searching)
        G7BLELog.emit(
            G7DirectBLEConstants.Event.blockedNoPeripheral,
            fields: [("stage", "post_retrieval")]
        )
    }

    /// Returns true if we committed to this peripheral (connect issued).
    private func evaluatePeripheral(
        _ peripheral: CBPeripheral,
        source: G7DirectBLEConstants.ConnectSource,
        kickSource: KickSource
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(bleQueue))

        // Filter by name. `nil` names are accepted from retrieval paths
        // (the system-connected peripheral may not advertise a name to us
        // until characteristics are discovered).
        if let name = peripheral.name, !G7DirectBLEConstants.nameMatchesG7(name) {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralSkipped,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", name),
                    ("reason", "name_mismatch")
                ]
            )
            return false
        }

        peripheral.delegate = self
        activePeripheral = peripheral
        pendingPeripheralIdentifier = peripheral.identifier

        cycleStartedAt = Date()
        cycleEGVCount = 0
        controlWriteAttemptThisCycle = 0
        authAdvanced = false
        clearEGVFallbackTimerOnQueue()
        clearAuthAdvanceTimerOnQueue()
        lastEGVMessageTimestampLogged = nil

        stopScanOnQueue(reason: "connect_initiated")

        G7BLELog.emit(
            G7DirectBLEConstants.Event.connectAttempt,
            fields: [
                ("identifier", peripheral.identifier.uuidString),
                ("name", peripheral.name ?? "nil"),
                ("source", source.rawValue),
                ("kick_source", String(describing: kickSource))
            ]
        )
        publishStatusOnQueue(.connecting)
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        return true
    }

    // MARK: - Scan control

    private func stopScanOnQueue(reason: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let central = centralManager, central.isScanning else { return }
        central.stopScan()
        G7BLELog.emit(
            G7DirectBLEConstants.Event.scanStopped,
            fields: [("reason", reason)]
        )
    }

    // MARK: - Reconnect / backoff

    private func scheduleReconnectOnQueue(reason: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard !isExplicitlyStopped else { return }
        reconnectWorkItem?.cancel()

        let idx = min(
            reconnectAttemptIndex,
            G7DirectBLEConstants.reconnectBackoffSeconds.count - 1
        )
        let delay = G7DirectBLEConstants.reconnectBackoffSeconds[idx]
        reconnectAttemptIndex += 1

        G7BLELog.emit(
            G7DirectBLEConstants.Event.lifecycle,
            fields: [
                ("phase", "reconnect_scheduled"),
                ("reason", reason),
                ("delay_s", Int(delay)),
                ("attempt_index", idx)
            ]
        )

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.kickAttachIfNeeded(source: .retryBackoff)
        }
        reconnectWorkItem = work
        bleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetReconnectBackoffOnQueue() {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        reconnectAttemptIndex = 0
    }

    // MARK: - Auth advance timer

    private func startAuthAdvanceFallbackTimerOnQueue() {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        clearAuthAdvanceTimerOnQueue()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(
            deadline: .now() + G7DirectBLEConstants.authAdvanceFallbackSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.authAdvanced else { return }
            G7BLELog.emit(
                G7DirectBLEConstants.Event.advanceReady,
                fields: [("reason", "timer_fallback")]
            )
            self.advanceToControlOnQueue(cadence: "first_connect")
        }
        timer.resume()
        authAdvanceTimer = timer
    }

    private func clearAuthAdvanceTimerOnQueue() {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        authAdvanceTimer?.cancel()
        authAdvanceTimer = nil
    }

    // MARK: - EGV fallback timer

    private func startOrResetEGVFallbackTimerOnQueue() {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        clearEGVFallbackTimerOnQueue()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(
            deadline: .now() + G7DirectBLEConstants.egvFallbackTimerSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let peripheral = self.activePeripheral,
                  peripheral.state == .connected,
                  self.controlCharacteristic != nil
            else { return }
            self.writeEGVRequestOnQueue(cadence: "fallback_timer")
            self.startOrResetEGVFallbackTimerOnQueue()
        }
        timer.resume()
        egvFallbackTimer = timer
    }

    private func clearEGVFallbackTimerOnQueue() {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        egvFallbackTimer?.cancel()
        egvFallbackTimer = nil
    }

    // MARK: - Advance to control characteristic

    private func advanceToControlOnQueue(cadence: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let control = controlCharacteristic
        else {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.blockedControlNotReady,
                fields: [("cadence", cadence)]
            )
            return
        }
        if !authAdvanced {
            authAdvanced = true
            clearAuthAdvanceTimerOnQueue()
        }
        if !control.isNotifying {
            peripheral.setNotifyValue(true, for: control)
            // Continue even if notify-enable is pending; the sensor will
            // buffer the response until CCCD flips. In practice iOS/watchOS
            // serialize the notify enable before the write.
        }
        if let backfill = backfillCharacteristic, !backfill.isNotifying {
            peripheral.setNotifyValue(true, for: backfill)
        }
        writeEGVRequestOnQueue(cadence: cadence)
        startOrResetEGVFallbackTimerOnQueue()
    }

    // MARK: - Control write

    /// **Observer-only safety contract:** this helper is the ONLY path that
    /// writes anything to the G7 peripheral. It only ever writes the EGV
    /// request opcode to the control characteristic. Any future caller
    /// attempting a different opcode must add a new helper with an
    /// explicit safety review — see design §3 observer-only constraints.
    private func writeEGVRequestOnQueue(cadence: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let control = controlCharacteristic
        else { return }
        controlWriteAttemptThisCycle += 1
        let attempt = controlWriteAttemptThisCycle
        let payload = Data([G7DirectBLEConstants.egvRequestOpcode])
        G7BLELog.emit(
            G7DirectBLEConstants.Event.egvRequestSent,
            fields: [
                ("cadence", cadence),
                ("attempt", attempt),
                ("opcode", "0x4e")
            ]
        )
        peripheral.writeValue(payload, for: control, type: .withResponse)
    }

    private func scheduleControlWriteRetryOnQueue(reason: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard controlWriteAttemptThisCycle <
                G7DirectBLEConstants.maxControlWriteRetriesPerCycle
        else {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.egvRequestWriteFailed,
                fields: [("attempt", controlWriteAttemptThisCycle),
                         ("action", "retries_exhausted"),
                         ("reason", reason)]
            )
            return
        }
        let delay = G7DirectBLEConstants.controlWriteRetryDelaySeconds
        G7BLELog.emit(
            G7DirectBLEConstants.Event.egvRequestWriteFailed,
            fields: [("attempt", controlWriteAttemptThisCycle),
                     ("action", "retry_scheduled"),
                     ("reason", reason),
                     ("delay_s", Int(delay))]
        )
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let peripheral = self.activePeripheral,
                  peripheral.state == .connected,
                  self.controlCharacteristic != nil
            else { return }
            self.writeEGVRequestOnQueue(cadence: "retry")
        }
    }

    // MARK: - Per-cycle teardown

    private func resetPerCycleStateOnQueue(outcome: String, finalStage: String) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let start = cycleStartedAt
        let egvCount = cycleEGVCount

        activePeripheral = nil
        authenticationCharacteristic = nil
        controlCharacteristic = nil
        backfillCharacteristic = nil
        jpakeCharacteristic = nil
        clearAuthAdvanceTimerOnQueue()
        clearEGVFallbackTimerOnQueue()
        authAdvanced = false
        controlWriteAttemptThisCycle = 0
        lastEGVMessageTimestampLogged = nil
        cycleStartedAt = nil
        cycleEGVCount = 0
        sensorActivationDate = nil

        let durationMs: Int
        if let start { durationMs = Int(Date().timeIntervalSince(start) * 1000) }
        else { durationMs = 0 }
        G7BLELog.emit(
            G7DirectBLEConstants.Event.sessionOutcome,
            fields: [
                ("outcome", outcome),
                ("final_stage", finalStage),
                ("duration_ms", durationMs),
                ("egv_count", egvCount)
            ]
        )
    }

    /// Textual label for the current high-level stage, for outcome logs.
    private func stageLabel() -> String {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        if activePeripheral == nil { return "idle" }
        if controlCharacteristic == nil { return "discovering" }
        if !authAdvanced { return "awaiting_auth" }
        if cycleEGVCount == 0 { return "awaiting_egv" }
        return "streaming"
    }

    // MARK: - UserDefaults (preferred identifier)

    private func persistedPreferredPeripheralIdentifier() -> UUID? {
        guard let s = UserDefaults.standard.string(
            forKey: G7DirectBLEConstants.preferredPeripheralIdentifierKey
        ) else { return nil }
        return UUID(uuidString: s)
    }

    private func setPersistedPreferredPeripheralIdentifier(_ uuid: UUID?) {
        if let uuid {
            UserDefaults.standard.set(
                uuid.uuidString,
                forKey: G7DirectBLEConstants.preferredPeripheralIdentifierKey
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: G7DirectBLEConstants.preferredPeripheralIdentifierKey
            )
        }
    }

    // MARK: - Status publish

    private func publishStatusOnQueue(_ status: G7DirectBLEObserverStatus) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let latestEGV = latestPublishedSnapshot.lastEGVAt
        let effective: G7DirectBLEObserverStatus
        if status == .active,
           let latestEGV,
           Date().timeIntervalSince(latestEGV)
            > G7DirectBLEConstants.uiStalledThresholdSeconds {
            effective = .stalled
        } else {
            effective = status
        }
        let snapshot = G7DirectBLEObserverSnapshot(
            status: effective,
            lastEGVAt: latestEGV
        )
        if snapshot == latestPublishedSnapshot { return }
        latestPublishedSnapshot = snapshot
        Task { @MainActor in
            WatchState.shared.applyG7ObserverSnapshot(snapshot)
        }
    }

    private func publishEGVTimestampOnQueue(_ date: Date) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let snapshot = G7DirectBLEObserverSnapshot(
            status: .active,
            lastEGVAt: date
        )
        latestPublishedSnapshot = snapshot
        Task { @MainActor in
            WatchState.shared.applyG7ObserverSnapshot(snapshot)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension G7DirectBLEObserver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let stateLabel: String
        switch central.state {
        case .poweredOn: stateLabel = "poweredOn"
        case .poweredOff: stateLabel = "poweredOff"
        case .unauthorized: stateLabel = "unauthorized"
        case .unsupported: stateLabel = "unsupported"
        case .resetting: stateLabel = "resetting"
        case .unknown: stateLabel = "unknown"
        @unknown default: stateLabel = "unknown_default"
        }
        G7BLELog.emit(
            G7DirectBLEConstants.Event.centralState,
            fields: [("state", stateLabel)]
        )
        switch central.state {
        case .poweredOn:
            resetReconnectBackoffOnQueue()
            kickAttachIfNeeded(source: .poweredOn)
        case .poweredOff, .unauthorized, .unsupported:
            publishStatusOnQueue(.unavailable)
        case .resetting, .unknown:
            publishStatusOnQueue(.searching)
        @unknown default:
            publishStatusOnQueue(.searching)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral]) ?? []
        G7BLELog.emit(
            G7DirectBLEConstants.Event.willRestoreState,
            fields: [("restored_count", peripherals.count)]
        )
        for peripheral in peripherals {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralDiscovered,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", peripheral.name ?? "nil"),
                    ("source", G7DirectBLEConstants.ConnectSource.restored.rawValue)
                ]
            )
            _ = evaluatePeripheral(peripheral,
                                   source: .restored,
                                   kickSource: .restored)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let advertKeys = advertisementData.keys.sorted().joined(separator: "|")
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        G7BLELog.emit(
            G7DirectBLEConstants.Event.peripheralDiscovered,
            fields: [
                ("identifier", peripheral.identifier.uuidString),
                ("name", peripheral.name ?? "nil"),
                ("local_name", localName ?? "nil"),
                ("rssi", RSSI.intValue),
                ("advert_keys", advertKeys),
                ("source", G7DirectBLEConstants.ConnectSource.scan.rawValue)
            ]
        )
        let effectiveName = peripheral.name ?? localName
        if !G7DirectBLEConstants.nameMatchesG7(effectiveName) {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.peripheralSkipped,
                fields: [
                    ("identifier", peripheral.identifier.uuidString),
                    ("name", peripheral.name ?? "nil"),
                    ("local_name", localName ?? "nil"),
                    ("reason", "name_mismatch")
                ]
            )
            return
        }
        _ = evaluatePeripheral(peripheral,
                               source: .scan,
                               kickSource: .poweredOn)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        G7BLELog.emit(
            G7DirectBLEConstants.Event.didConnect,
            fields: [
                ("identifier", peripheral.identifier.uuidString),
                ("name", peripheral.name ?? "nil")
            ]
        )
        setPersistedPreferredPeripheralIdentifier(peripheral.identifier)
        consecutiveFailuresForPreferredIdentifier = 0
        resetReconnectBackoffOnQueue()
        stopScanOnQueue(reason: "did_connect")
        publishStatusOnQueue(.connecting)
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let nsError = error as NSError?
        G7BLELog.emit(
            G7DirectBLEConstants.Event.connectFailed,
            fields: [
                ("identifier", peripheral.identifier.uuidString),
                ("error_domain", nsError?.domain ?? "nil"),
                ("error_code", nsError?.code ?? -1),
                ("error_desc", nsError?.localizedDescription ?? "nil")
            ]
        )
        if pendingPeripheralIdentifier == peripheral.identifier {
            consecutiveFailuresForPreferredIdentifier += 1
            if consecutiveFailuresForPreferredIdentifier >=
                G7DirectBLEConstants.preferredPeripheralClearAfterConsecutiveFailures {
                setPersistedPreferredPeripheralIdentifier(nil)
                consecutiveFailuresForPreferredIdentifier = 0
                G7BLELog.emit(
                    G7DirectBLEConstants.Event.lifecycle,
                    fields: [("phase", "preferred_identifier_cleared"),
                             ("reason", "consecutive_failures")]
                )
            }
        }
        resetPerCycleStateOnQueue(
            outcome: "failure",
            finalStage: "connect_failed"
        )
        scheduleReconnectOnQueue(reason: "didFailToConnect")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let nsError = error as NSError?
        let wasStreaming = cycleEGVCount > 0
        G7BLELog.emit(
            G7DirectBLEConstants.Event.didDisconnect,
            fields: [
                ("identifier", peripheral.identifier.uuidString),
                ("error_domain", nsError?.domain ?? "nil"),
                ("error_code", nsError?.code ?? -1),
                ("error_desc", nsError?.localizedDescription ?? "nil"),
                ("was_streaming", wasStreaming)
            ]
        )
        let outcome = wasStreaming ? "success" : "incomplete"
        resetPerCycleStateOnQueue(
            outcome: outcome,
            finalStage: "did_disconnect"
        )
        // Reconnect aggressively — the G7 app's session persists.
        scheduleReconnectOnQueue(reason: "didDisconnectPeripheral")
    }
}

// MARK: - CBPeripheralDelegate

extension G7DirectBLEObserver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let services = peripheral.services ?? []
        let uuids = services.map { $0.uuid.uuidString }.joined(separator: "|")
        G7BLELog.emit(
            G7DirectBLEConstants.Event.servicesDiscovered,
            fields: [
                ("count", services.count),
                ("uuids", uuids),
                ("error", (error as NSError?)?.localizedDescription ?? "nil")
            ]
        )
        if error != nil {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let chars = service.characteristics ?? []
        let uuids = chars.map { $0.uuid.uuidString }.joined(separator: "|")
        G7BLELog.emit(
            G7DirectBLEConstants.Event.characteristicsDiscovered,
            fields: [
                ("service", service.uuid.uuidString),
                ("count", chars.count),
                ("uuids", uuids),
                ("error", (error as NSError?)?.localizedDescription ?? "nil")
            ]
        )
        for characteristic in chars {
            let uuid = characteristic.uuid
            if uuid == G7DirectBLEConstants.authenticationCharacteristicUUID {
                authenticationCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if uuid == G7DirectBLEConstants.controlCharacteristicUUID {
                controlCharacteristic = characteristic
                // Notify is enabled at advance time, not here, to avoid
                // any pre-auth control-notify behavior the sensor might
                // treat specially. We cache the handle only.
            } else if uuid == G7DirectBLEConstants.backfillCharacteristicUUID {
                backfillCharacteristic = characteristic
            } else if uuid == G7DirectBLEConstants.jpakeCharacteristicUUID {
                jpakeCharacteristic = characteristic
                G7BLELog.emit(
                    G7DirectBLEConstants.Event.jpakeSkipped,
                    fields: [("uuid", uuid.uuidString)]
                )
                // Observer-only: never subscribe.
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        if uuid == G7DirectBLEConstants.authenticationCharacteristicUUID, isNotifying {
            G7BLELog.emit(G7DirectBLEConstants.Event.authNotifyEnabled)
            startAuthAdvanceFallbackTimerOnQueue()
        } else if uuid == G7DirectBLEConstants.controlCharacteristicUUID, isNotifying {
            G7BLELog.emit(G7DirectBLEConstants.Event.controlNotifyEnabled)
        } else if uuid == G7DirectBLEConstants.backfillCharacteristicUUID, isNotifying {
            G7BLELog.emit(G7DirectBLEConstants.Event.backfillNotifyEnabled)
        }
        if let error {
            G7BLELog.log(
                "g7_ble_notify_error uuid=\(uuid.uuidString) error=\(error.localizedDescription)"
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        if let error {
            G7BLELog.log(
                "g7_ble_update_value_error uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)"
            )
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let uuid = characteristic.uuid
        if uuid == G7DirectBLEConstants.authenticationCharacteristicUUID {
            handleAuthPayloadOnQueue(data)
        } else if uuid == G7DirectBLEConstants.controlCharacteristicUUID {
            handleControlPayloadOnQueue(data)
        } else if uuid == G7DirectBLEConstants.backfillCharacteristicUUID {
            handleBackfillPayloadOnQueue(data)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard characteristic.uuid == G7DirectBLEConstants.controlCharacteristicUUID
        else { return }
        if let error {
            let nsErr = error as NSError
            G7BLELog.emit(
                G7DirectBLEConstants.Event.egvRequestWriteFailed,
                fields: [
                    ("attempt", controlWriteAttemptThisCycle),
                    ("error_domain", nsErr.domain),
                    ("error_code", nsErr.code),
                    ("error_desc", nsErr.localizedDescription)
                ]
            )
            scheduleControlWriteRetryOnQueue(reason: "write_error")
        }
    }

    // MARK: - Payload dispatch

    private func handleAuthPayloadOnQueue(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let challenge = G7DirectAuthChallenge(data: data) else { return }
        G7BLELog.emit(
            G7DirectBLEConstants.Event.authPayloadReceived,
            fields: [
                ("hex_prefix", challenge.rawHexPrefix),
                ("authenticated", challenge.isAuthenticated),
                ("bonded", challenge.isBonded)
            ]
        )
        if challenge.isAuthenticated && challenge.isBonded {
            if !authAdvanced {
                G7BLELog.emit(
                    G7DirectBLEConstants.Event.advanceReady,
                    fields: [("reason", "auth_gate")]
                )
                advanceToControlOnQueue(cadence: "first_connect")
            } else {
                // Observed re-auth post-advance: sensor's ~5-min re-auth
                // cycle. Request another EGV on this transition (§9).
                G7BLELog.emit(
                    G7DirectBLEConstants.Event.advanceReady,
                    fields: [("reason", "auth_transition")]
                )
                writeEGVRequestOnQueue(cadence: "auth_transition")
                startOrResetEGVFallbackTimerOnQueue()
            }
        } else if !authAdvanced {
            let elapsed: Int
            if let start = cycleStartedAt {
                elapsed = Int(Date().timeIntervalSince(start) * 1000)
            } else {
                elapsed = -1
            }
            G7BLELog.emit(
                G7DirectBLEConstants.Event.blockedAuthIncomplete,
                fields: [("elapsed_ms", elapsed)]
            )
        }
    }

    private func handleControlPayloadOnQueue(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let prefix = data.first ?? 0x00
        if prefix == G7DirectBLEConstants.egvRequestOpcode,
           let message = G7DirectGlucoseMessage(data: data) {
            processEGVMessageOnQueue(message, raw: data)
        } else {
            // Observed but not handled (version/battery/session stop).
            G7BLELog.log(
                "g7_ble_control_other prefix=0x\(String(format: "%02x", prefix)) len=\(data.count) hex=\(G7DirectBLEDataReader.hexPrefix(data))"
            )
        }
    }

    private func handleBackfillPayloadOnQueue(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        if let msg = G7DirectBackfillMessage(data: data) {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.backfillPacket,
                fields: [
                    ("length", data.count),
                    ("timestamp", msg.timestamp),
                    ("glucose", msg.glucose.map { String($0) } ?? "nil"),
                    ("parsed", true)
                ]
            )
        } else {
            G7BLELog.emit(
                G7DirectBLEConstants.Event.backfillPacket,
                fields: [
                    ("length", data.count),
                    ("hex_prefix", G7DirectBLEDataReader.hexPrefix(data)),
                    ("parsed", false)
                ]
            )
        }
        // Not forwarded to the complication store in this POC (§11).
    }

    private func processEGVMessageOnQueue(_ message: G7DirectGlucoseMessage, raw: Data) {
        dispatchPrecondition(condition: .onQueue(bleQueue))

        // Activation date inferred from the message itself.
        // See `G7SensorKit/G7CGMManager/G7Sensor.swift.handleGlucoseMessage`
        // for the same computation.
        let now = Date()
        let activationDate = now.addingTimeInterval(
            -TimeInterval(message.messageTimestamp)
        )
        sensorActivationDate = activationDate
        let readingDate = message.readingDate(activationDate: activationDate)

        // Rate-limit the parse log to one entry per unique message_timestamp
        // per process launch (verbose enough for diagnosis, bounded volume).
        if lastEGVMessageTimestampLogged != message.messageTimestamp {
            lastEGVMessageTimestampLogged = message.messageTimestamp
            G7BLELog.emit(
                G7DirectBLEConstants.Event.egvReceived,
                fields: [
                    ("glucose", message.glucose.map { String($0) } ?? "nil"),
                    ("trend_rate_mgdl_per_min", message.trendRate.map { String(format: "%.2f", $0) } ?? "nil"),
                    ("algorithm_state", message.algorithmState),
                    ("sequence", message.sequence),
                    ("message_timestamp", message.messageTimestamp),
                    ("age_s", message.age),
                    ("reading_date_epoch", Int(readingDate.timeIntervalSince1970))
                ]
            )
        }

        guard let glucoseValue = message.glucose else {
            // Display-only / unknown — skip snapshot, keep session going.
            return
        }

        cycleEGVCount += 1

        let glucoseString = String(glucoseValue)
        let trendString = message.nightscoutArrowString
        let readingEpoch = Int(readingDate.timeIntervalSince1970)

        let snapshotBuild = { (previous: (Int, Date)?) -> TrioComplicationSnapshot in
            let deltaString: String
            if let (prevValue, _) = previous {
                let delta = Int(glucoseValue) - prevValue
                deltaString = String(format: "%+d", delta)
            } else {
                deltaString = "--"
            }
            return TrioComplicationSnapshot(
                glucose: glucoseString,
                trend: trendString,
                delta: deltaString,
                readingDate: readingDate,
                date: now,
                glucoseColor: nil,
                source: .g7DirectBLE
            )
        }

        let lastStored = lastBLEGlucoseCache
        let snapshot = snapshotBuild(lastStored)

        // Update cache before publishing so subsequent reads see the new
        // delta basis.
        lastBLEGlucoseCache = (Int(glucoseValue), readingDate)

        publishEGVTimestampOnQueue(readingDate)

        G7BLELog.emit(
            G7DirectBLEConstants.Event.snapshotSaved,
            fields: [
                ("glucose", glucoseString),
                ("trend", trendString),
                ("reading_date_epoch", readingEpoch),
                ("source", TrioComplicationDataSource.g7DirectBLE.shortLabel)
            ]
        )

        Task { @MainActor in
            TrioComplicationDataStore.shared.save(
                snapshot,
                triggerReload: true,
                minInterval: 5
            )
            WatchState.shared.applyBLEObservedReading(
                glucose: glucoseString,
                trend: trendString,
                delta: snapshot.delta,
                readingDate: readingDate
            )
        }
    }

}
