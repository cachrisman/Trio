import CoreBluetooth
import Foundation
import Observation
import WatchKit

// MARK: - UUIDs (Dexcom G7 data service — DiaBLE/Dexcom IPA verified)

private enum G7BLEUUID {
    /// Advertisement service for scanning
    static let advertisement = CBUUID(string: "FEBC")
    static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
}

// MARK: - Connection state

enum G7BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case authenticating
    case connected
    case disconnected(reason: String)
    case error(String)
}

/// Foreground-only direct BLE eavesdrop path to Dexcom G7 (no J-PAKE response).
@Observable
final class G7DirectBLEManager: NSObject {
    private(set) var connectionState: G7BLEConnectionState = .idle

    private var central: CBCentralManager?
    /// If set, `didDisconnect` uses this instead of the CB error string (e.g. user `stop()`).
    private var pendingDisconnectReason: String?
    private weak var peripheral: CBPeripheral?
    private var dataService: CBService?
    private var authenticationCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var backfillCharacteristic: CBCharacteristic?

    /// Wall-clock sensor activation inferred from the first successful EGV (`now - txTime`).
    private var storedActivationWallClock: Date?
    private var egvRequestSent = false
    private var controlNotificationsReady = false
    private var backfillNotificationsReady = false
    private var scanningStarted = false
    /// Prevents duplicate `g7_ble_scan_started` when both `startScanning` and `centralManagerDidUpdateState` run.
    private var loggedScanStartThisRequest = false
    /// Scheduled reconnect after unexpected teardown while foreground scanning is still desired.
    private var reconnectWorkItem: DispatchWorkItem?

    // MARK: - Instrumentation (report 03 Tier 1)

    /// New UUID string each `startScanning()` — all `g7_ble_*` lines append this when set.
    private var g7SessionID: String?
    /// Wall-clock when a peripheral was discovered (for `ms_since_discover` on connect).
    private var discoverWallClock: Date?
    /// Last `stage=` label emitted (`event=g7_ble_stage`); transition-only.
    private var lastInstrumentationStage: String?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var gattSetupTimeoutWorkItem: DispatchWorkItem?
    private var firstEgvTimeoutWorkItem: DispatchWorkItem?
    /// Dedupe: at most one `g7_ble_timeout` per stage string per session.
    private var timeoutEmittedKeys: Set<String> = []
    private var lastNonEgControlLogAt: Date?

    private enum G7BLEInstrumentation {
        static let connectTimeoutSeconds: TimeInterval = 30
        static let gattSetupTimeoutSeconds: TimeInterval = 60
        static let firstEgvTimeoutSeconds: TimeInterval = 90
        static let nonEgControlLogMinInterval: TimeInterval = 1.0
    }

    /// Exposed for `WatchState` `g7_ble_lifecycle` lines after `startScanning()`.
    var currentG7SessionId: String? { g7SessionID }

    /// When set, only connect to a peripheral whose `name` matches exactly (e.g. active `DXCMxx`). `nil` = first matching advertisement (legacy behavior).
    var activePeripheralName: String?

    private var extendedSession: WKExtendedRuntimeSession?
    private var sessionStartedAt: Date?
    private var egvReceivedThisSession = false
    /// Set when **`WatchState`** leaves **`ScenePhase.active`** so **`applyForegroundActiveEntry`** can renew **`WKExtendedRuntimeSession`** after a watch-face detour.
    private var lastSceneLeftActiveUiAt: Date?

    private enum G7BLEExtendedRuntime {
        /// Product: anchor ~1h extended-runtime budget from **last time the app UI was active** (renew on re-entry after inactive/background when still within this window).
        static let foregroundReentryRenewalMaxAwaySeconds: TimeInterval = 3600
    }

    // MARK: - Public API

    /// Record that the app UI left **`ScenePhase.active`** (Digital Crown / inactive). Enables extended-runtime renewal on the next **`applyForegroundActiveEntry`**.
    func noteSceneLeftActiveUi(at date: Date) {
        lastSceneLeftActiveUiAt = date
    }

    /// Called when `ScenePhase` becomes **`.active`**. Applies the phone-supplied **`activePeripheralName`** filter,
    /// **renews `WKExtendedRuntimeSession`** when returning from inactive/background within **`foregroundReentryRenewalMaxAwaySeconds`**
    /// so the ~1h budget can anchor to **last active UI**, then starts BLE only when there is no in-flight scan/connect/stream (**`scanning`…`connected`**).
    func applyForegroundActiveEntry(activePeripheralName: String?) {
        self.activePeripheralName = activePeripheralName
        if activePeripheralName != nil {
            Task {
                await logG7Ble("event=g7_ble_active_name_applied filtered=true")
            }
        }

        if let leftAt = lastSceneLeftActiveUiAt {
            lastSceneLeftActiveUiAt = nil
            let away = Date().timeIntervalSince(leftAt)
            let awaySec = max(0, Int(away.rounded(.down)))
            if awaySec > 0, away < G7BLEExtendedRuntime.foregroundReentryRenewalMaxAwaySeconds {
                renewExtendedRuntimeSessionAfterForegroundReentry(awaySeconds: awaySec)
            } else if awaySec > 0 {
                Task {
                    await logG7Ble(
                        "event=g7_ble_ext_session_renewal_skipped reason=away_not_under_1h away_s=\(awaySec)"
                    )
                }
            }
        }

        if shouldSkipFullStartScanningAfterForegroundReentry() {
            Task {
                await logG7Ble("event=g7_ble_foreground_reentry_skipped reason=ble_session_in_progress")
            }
            return
        }
        startScanning()
    }

    /// Begins (or restarts) scanning for G7 advertisements. Prefer **`applyForegroundActiveEntry`** from **`WatchState`**
    /// so returning to the app does not tear down an already-running session.
    func startScanning() {
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        guard let central else { return }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        scanningStarted = true
        g7SessionID = UUID().uuidString
        sessionStartedAt = Date()
        timeoutEmittedKeys.removeAll()
        lastInstrumentationStage = nil
        discoverWallClock = nil
        cancelInstrumentationTimeouts()
        loggedScanStartThisRequest = false
        connectionState = .scanning
        emitStageIfChanged("scanning")
        // Cancel any in-flight connection before clearing state — avoids orphan links if `startScanning` runs while connected (e.g. rescan / reconnect path).
        if let existing = peripheral {
            pendingDisconnectReason = "startScanning_rescan"
            central.cancelPeripheralConnection(existing)
        }
        peripheral = nil
        resetSessionState()
        central.stopScan()

        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: [G7BLEUUID.advertisement],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            loggedScanStartThisRequest = true
            Task {
                await logG7Ble("event=g7_ble_scan_started")
            }
        case .unknown:
            // `centralManagerDidUpdateState` starts the scan when powered on.
            break
        default:
            let reason = String(describing: central.state.rawValue)
            Task {
                await logG7Ble("event=g7_ble_error error=bluetooth_unavailable state=\(reason)")
            }
            connectionState = .error("Bluetooth unavailable (\(reason))")
            scanningStarted = false
        }
    }

    /// Explicit teardown: stop scanning, disconnect, invalidate **`WKExtendedRuntimeSession`**, and reset session state.
    /// **Not** invoked from **`ScenePhase`** — scene **`.inactive` / `.background`** do not end direct BLE; the OS ends the
    /// extended runtime window via **`WKExtendedRuntimeSessionDelegate`**. Reserve **`stop()`** for future explicit
    /// product controls (e.g. settings), tests, or emergency shutdown paths.
    func stop() {
        invalidateExtendedSession(reason: "stop_requested")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        scanningStarted = false
        central?.stopScan()
        pendingDisconnectReason = "stop_requested"
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        } else {
            pendingDisconnectReason = nil
            teardownSession(reason: "stop_requested", isFailure: false)
        }
    }

    /// When **`scanningStarted`** and the connection pipeline is still live, a full **`startScanning()`** would cancel the
    /// peripheral and reset **`g7_session`** — avoid that on foreground re-entry after the user viewed the watch face.
    private func shouldSkipFullStartScanningAfterForegroundReentry() -> Bool {
        guard scanningStarted else { return false }
        switch connectionState {
        case .scanning, .connecting, .authenticating, .connected:
            return true
        case .idle, .disconnected, .error:
            return false
        }
    }

    /// Invalidates any existing extended session, then starts a **new** `WKExtendedRuntimeSession` while BLE is still live so
    /// watchOS can grant a fresh budget (~1h from **this** foreground re-entry when within the renewal window).
    private func renewExtendedRuntimeSessionAfterForegroundReentry(awaySeconds: Int) {
        invalidateExtendedSession(reason: "foreground_reentry_renewal")
        startNewExtendedRuntimeSessionIfConnected(reason: "foreground_reentry", awaySeconds: awaySeconds)
    }

    /// After `didDiscover` or foreground re-entry while connected — `delegate` logs `g7_ble_ext_session_started`.
    private func beginExtendedRuntimeSession() {
        let ext = WKExtendedRuntimeSession()
        ext.delegate = self
        extendedSession = ext
        ext.start()
    }

    /// When already past discovery (connecting…connected), attach a new extended session (used after invalidating the prior session).
    private func startNewExtendedRuntimeSessionIfConnected(reason: String, awaySeconds: Int) {
        guard peripheral != nil else { return }
        switch connectionState {
        case .connecting, .authenticating, .connected:
            break
        default:
            return
        }
        beginExtendedRuntimeSession()
        Task {
            await logG7Ble("event=g7_ble_ext_session_renewal reason=\(reason) away_s=\(awaySeconds)")
        }
    }

    // MARK: - Session reset

    private func resetSessionState() {
        discoverWallClock = nil
        dataService = nil
        authenticationCharacteristic = nil
        controlCharacteristic = nil
        backfillCharacteristic = nil
        storedActivationWallClock = nil
        egvRequestSent = false
        controlNotificationsReady = false
        backfillNotificationsReady = false
        egvReceivedThisSession = false
    }

    private func invalidateExtendedSession(reason: String) {
        guard extendedSession != nil else { return }
        extendedSession?.invalidate()
        extendedSession = nil
        Task {
            await logG7Ble("event=g7_ble_ext_session_ended reason=\(reason)")
        }
    }

    private func mapSessionOutcome(reason: String, isFailure: Bool, egvReceived: Bool) -> String {
        if reason == "stop_requested" { return "cancelled" }
        if reason.hasPrefix("timeout_") { return "timeout" }
        if egvReceived, !isFailure { return "success" }
        if isFailure { return "failure" }
        return "incomplete"
    }

    /// - Parameter isFailure: When `true`, sets `connectionState` to `.error` (protocol / BLE failure). When `false`, uses `.disconnected` (clean stop or non-error teardown).
    private func teardownSession(reason: String, isFailure: Bool = true) {
        assert(Thread.isMainThread, "teardownSession must run on the main queue (CBCentralManager delegate queue)")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        cancelInstrumentationTimeouts()

        let outcomeSid = g7SessionID
        let startedAt = sessionStartedAt
        let egvDone = egvReceivedThisSession
        let finalStage = lastInstrumentationStage
        let durationMs: Int
        if let t0 = startedAt {
            durationMs = Int(Date().timeIntervalSince(t0) * 1000.0)
        } else {
            durationMs = 0
        }
        let outcome = mapSessionOutcome(reason: reason, isFailure: isFailure, egvReceived: egvDone)
        let stageField = finalStage ?? "none"

        invalidateExtendedSession(reason: reason)

        resetSessionState()
        sessionStartedAt = nil
        peripheral = nil
        connectionState = isFailure ? .error(reason) : .disconnected(reason: reason)
        Task {
            await logG7Ble(
                "event=g7_ble_disconnected reason=\(reason) failure=\(isFailure ? "true" : "false")"
            )
            await logG7Ble(
                "event=g7_ble_session_outcome outcome=\(outcome) final_stage=\(stageField) duration_ms=\(durationMs) g7_session=\(outcomeSid ?? "none")"
            )
        }
        // Reconnect only after non-failure teardowns (e.g. clean peripheral disconnect). Protocol / discovery failures (`isFailure == true`) skip the 7s rescan to avoid a deterministic connect → fail → loop when auth or GATT setup is broken.
        if scanningStarted, !isFailure {
            Task {
                await logG7Ble("event=g7_ble_reconnect_scheduled delay_s=7")
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.scanningStarted else { return }
                self.startScanning()
            }
            reconnectWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: work)
        }
    }

    // MARK: - Logging

    /// Appends `g7_session=` when the session id exists and the line does not already include it.
    /// Forwards `#fileID` / `#line` / `#function` into `WatchLogger` so log metadata reflects the **call site**, not this helper.
    private func logG7Ble(
        _ message: String,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        var out = message
        if let sid = g7SessionID, !out.contains("g7_session=") {
            out += " g7_session=\(sid)"
        }
        await WatchLogger.shared.log(out, function: function, file: file, line: line)
    }

    private func emitStageIfChanged(_ stage: String) {
        guard lastInstrumentationStage != stage else { return }
        lastInstrumentationStage = stage
        Task {
            await logG7Ble("event=g7_ble_stage stage=\(stage)")
        }
    }

    private func cancelInstrumentationTimeouts() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        gattSetupTimeoutWorkItem?.cancel()
        gattSetupTimeoutWorkItem = nil
        firstEgvTimeoutWorkItem?.cancel()
        firstEgvTimeoutWorkItem = nil
    }

    private func timeoutDedupeKey(stage: String) -> String {
        "\(g7SessionID ?? "none")-\(stage)"
    }

    private func shouldEmitTimeout(stage: String) -> Bool {
        let key = timeoutDedupeKey(stage: stage)
        guard !timeoutEmittedKeys.contains(key) else { return false }
        timeoutEmittedKeys.insert(key)
        return true
    }

    private func scheduleConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.handleTimeout(stage: "awaiting_connect") }
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + G7BLEInstrumentation.connectTimeoutSeconds,
            execute: work
        )
    }

    private func scheduleGattSetupTimeout() {
        gattSetupTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.handleTimeout(stage: "awaiting_gatt_setup") }
        }
        gattSetupTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + G7BLEInstrumentation.gattSetupTimeoutSeconds,
            execute: work
        )
    }

    private func scheduleFirstEgvTimeout() {
        firstEgvTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.handleTimeout(stage: "awaiting_first_egv") }
        }
        firstEgvTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + G7BLEInstrumentation.firstEgvTimeoutSeconds,
            execute: work
        )
    }

    private func handleTimeout(stage: String) async {
        guard scanningStarted else { return }
        guard shouldEmitTimeout(stage: stage) else { return }
        await logG7Ble("event=g7_ble_timeout stage=\(stage)")
        teardownSession(reason: "timeout_\(stage)", isFailure: true)
    }

    // MARK: - EGV parse & save

    private func handleEGVPayload(_ data: Data) {
        guard data.count >= 19 else {
            Task {
                await logG7Ble("event=g7_ble_error error=egv_short count=\(data.count)")
            }
            return
        }

        guard data[0] == 0x4E else {
            let now = Date()
            if lastNonEgControlLogAt == nil
                || now.timeIntervalSince(lastNonEgControlLogAt!) >= G7BLEInstrumentation.nonEgControlLogMinInterval
            {
                lastNonEgControlLogAt = now
                let op = data[0]
                Task {
                    await logG7Ble(
                        "event=g7_ble_control_opcode opcode=\(op) len=\(data.count)"
                    )
                }
            }
            return
        }

        firstEgvTimeoutWorkItem?.cancel()
        firstEgvTimeoutWorkItem = nil

        guard
            let txTime = data.readUInt32LE(offset: 2),
            let egvAge = data.readUInt16LE(offset: 10),
            let glucoseRaw = data.readUInt16LE(offset: 12)
        else {
            Task {
                await logG7Ble("event=g7_ble_error error=egv_parse_bounds")
            }
            return
        }

        let trendByte = data[15]

        let glucose: Int?
        if glucoseRaw == 0xFFFF {
            glucose = nil
        } else {
            glucose = Int(glucoseRaw & 0x0FFF)
        }

        let trendRate: Double?
        if trendByte == 0x7F {
            trendRate = nil
        } else {
            trendRate = Double(Int8(bitPattern: trendByte)) / 10.0
        }

        // Spec: activationDate ≈ now - txTime (first good EGV); readingDate = activation + (txTime - egvAge).
        // Delegate queue is main — `Date()` reflects EGV handling time, not a deferred Task hop.
        let activation: Date
        if let existing = storedActivationWallClock {
            activation = existing
        } else {
            guard txTime > 0 else {
                Task {
                    await logG7Ble("event=g7_ble_error error=egv_txtime_invalid tx_time=\(txTime)")
                }
                return
            }
            let computed = Date().addingTimeInterval(-TimeInterval(txTime))
            storedActivationWallClock = computed
            activation = computed
        }
        let readingDate = activation.addingTimeInterval(
            TimeInterval(Int64(txTime) - Int64(egvAge))
        )
        let readingEpoch = Int(readingDate.timeIntervalSince1970)
        let dataAgeSeconds = max(0, Int(Date().timeIntervalSince(readingDate)))

        let glucoseField = glucose.map { String($0) } ?? "nil"
        let trendField = trendRate.map { String($0) } ?? "nil"
        Task {
            await logG7Ble(
                "event=g7_ble_egv_received glucose=\(glucoseField)"
                    + " trend=\(trendField)"
                    + " reading_epoch=\(readingEpoch)"
                    + " data_age_seconds=\(dataAgeSeconds)"
            )
        }

        guard let glucose else { return }

        egvReceivedThisSession = true

        let trendString = Self.trendString(fromRateMgDlPerMin: trendRate)

        let snapshot = TrioComplicationSnapshot(
            glucose: String(glucose),
            trend: trendString,
            delta: "",
            readingDate: readingDate,
            date: Date(),
            glucoseColor: nil
        )

        // Synchronous save on main — same queue as CB delegate (`CBCentralManager` uses `.main`).
        TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)

        // Do not invalidate `WKExtendedRuntimeSession` here: product intent is to keep listening for subsequent
        // CGM samples and updating the complication store until `stop()` / teardown or the OS ends the session.

        Task {
            await logG7Ble("event=g7_ble_snapshot_saved glucose=\(glucose)")
        }
    }

    /// Converts G7 trend rate (mg/dL/min) to a ~5-minute delta and applies **R6.1** thresholds (parity with `WatchState.hkTrendString(fromDeltaMgDl:)`).
    private static func trendString(fromRateMgDlPerMin rate: Double?) -> String {
        guard let rate else { return "" }
        let delta5 = Int((rate * 5.0).rounded())
        return hkTrendStringFromDeltaMgDl(delta5)
    }

    /// R6.1 — Same integer threshold semantics as `WatchState.hkTrendString(fromDeltaMgDl:)`.
    private static func hkTrendStringFromDeltaMgDl(_ delta: Int) -> String {
        switch delta {
        case ...(-30): return "DoubleDown"
        case -29 ... (-20): return "SingleDown"
        case -19 ... (-10): return "FortyFiveDown"
        case -9 ..< 10: return "Flat"
        case 10 ..< 20: return "FortyFiveUp"
        case 20 ..< 30: return "SingleUp"
        default: return "DoubleUp"
        }
    }

    // MARK: - Auth / subscribe / EGV request

    private func sendAuthRequest() {
        guard let cbPeripheral = peripheral, let auth = authenticationCharacteristic else { return }
        emitStageIfChanged("authenticating")
        let payload = Data([0x01, 0x00])
        cbPeripheral.writeValue(payload, for: auth, type: .withResponse)
        connectionState = .authenticating
        Task {
            await logG7Ble("event=g7_ble_auth_request_sent")
        }
    }

    private func handleAuthenticationNotification(_ data: Data) {
        guard !data.isEmpty else { return }
        let opcode = data[0]

        switch opcode {
        case 0x03:
            Task {
                await logG7Ble("event=g7_ble_auth_challenge_received opcode=0x03")
            }
        // Eavesdrop: do not respond to the challenge.
        case 0x05:
            let authenticated = data.count >= 2 && data[1] == 1
            Task {
                await logG7Ble("event=g7_ble_authenticated authenticated=\(authenticated)")
            }
            guard authenticated else { return }
            guard let activePeripheral = self.peripheral else { return }
            emitStageIfChanged("connected")
            connectionState = .connected
            controlNotificationsReady = false
            backfillNotificationsReady = false
            if let control = controlCharacteristic {
                activePeripheral.setNotifyValue(true, for: control)
            }
            if let backfill = backfillCharacteristic {
                activePeripheral.setNotifyValue(true, for: backfill)
            }
        default:
            break
        }
    }

    private func trySendEGVRequestIfReady() {
        guard let cbPeripheral = peripheral, let control = controlCharacteristic else { return }
        // EGV is requested on control once control notifications are ready (DiaBLE sequence); backfill is separate.
        guard controlNotificationsReady, !egvRequestSent else { return }
        egvRequestSent = true
        emitStageIfChanged("awaiting_egv")
        scheduleFirstEgvTimeout()
        cbPeripheral.writeValue(Data([0x4E]), for: control, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension G7DirectBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard scanningStarted, central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(
            withServices: [G7BLEUUID.advertisement],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard !loggedScanStartThisRequest else { return }
        loggedScanStartThisRequest = true
        Task {
            await logG7Ble("event=g7_ble_scan_started")
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi: NSNumber
    ) {
        guard scanningStarted else { return }
        let name = peripheral.name ?? "unknown"
        if let active = activePeripheralName, !active.isEmpty, name != active {
            Task {
                await logG7Ble("event=g7_ble_peripheral_skipped peripheral=\(name) reason=not_active_sensor")
            }
            return
        }

        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        discoverWallClock = Date()
        emitStageIfChanged("connecting")

        // TODO: validate WKExtendedRuntimeSession honored for BLE-connect use case on device
        beginExtendedRuntimeSession()

        Task {
            await logG7Ble("event=g7_ble_peripheral_discovered peripheral=\(name) rssi=\(rssi.intValue)")
            await logG7Ble("event=g7_ble_connect_attempt peripheral=\(name)")
        }
        scheduleConnectTimeout()
        central?.connect(peripheral, options: nil)
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        gattSetupTimeoutWorkItem?.cancel()
        gattSetupTimeoutWorkItem = nil
        scheduleGattSetupTimeout()
        emitStageIfChanged("discovering_services")
        let name = peripheral.name ?? "unknown"
        let msDiscover: Int?
        if let t0 = discoverWallClock {
            msDiscover = Int(Date().timeIntervalSince(t0) * 1000.0)
        } else {
            msDiscover = nil
        }
        let msField = msDiscover.map { " ms_since_discover=\($0)" } ?? ""
        Task {
            await logG7Ble("event=g7_ble_connected peripheral=\(name)\(msField)")
        }
        peripheral.discoverServices([G7BLEUUID.dataService])
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        let name = peripheral.name ?? "unknown"
        if let err = error {
            let ns = err as NSError
            Task {
                await logG7Ble(
                    "event=g7_ble_connect_failed peripheral=\(name) error_domain=\(ns.domain) error_code=\(ns.code) error_desc=\(ns.localizedDescription)"
                )
            }
        } else {
            Task {
                await logG7Ble(
                    "event=g7_ble_connect_failed peripheral=\(name) error_domain=none error_code=-1 error_desc=none"
                )
            }
        }
        teardownSession(reason: "connect_failed", isFailure: true)
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        let override = pendingDisconnectReason
        pendingDisconnectReason = nil
        // Intentional cancel before a new scan — `startScanning` already reset state; skip teardown + reconnect scheduling.
        // Intentionally does not emit `g7_ble_session_outcome`: the session id is reset at the top of the next
        // `startScanning()`; correlating outcome lines to rescans would duplicate or confuse metrics.
        if override == "startScanning_rescan" {
            invalidateExtendedSession(reason: "startScanning_rescan")
            return
        }
        let reason = override ?? (error?.localizedDescription ?? "disconnected")
        let isFailure: Bool
        if override == "stop_requested" {
            isFailure = false
        } else if error != nil {
            isFailure = true
        } else {
            isFailure = false
        }
        Task {
            if error != nil {
                await logG7Ble("event=g7_ble_error error=\(reason)")
            }
        }
        teardownSession(reason: reason, isFailure: isFailure)
    }
}

// MARK: - CBPeripheralDelegate

extension G7DirectBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task {
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "discover_services")
            return
        }
        guard let services = peripheral.services else { return }
        guard let svc = services.first(where: { $0.uuid == G7BLEUUID.dataService }) else {
            Task {
                await logG7Ble("event=g7_ble_error error=data_service_missing")
            }
            teardownSession(reason: "no_data_service")
            return
        }
        dataService = svc
        Task {
            await logG7Ble("event=g7_ble_services_discovered")
        }
        emitStageIfChanged("discovering_characteristics")
        peripheral.discoverCharacteristics(
            [G7BLEUUID.authentication, G7BLEUUID.control, G7BLEUUID.backfill],
            for: svc
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Task {
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "discover_characteristics")
            return
        }
        guard let chars = service.characteristics else { return }

        for characteristic in chars {
            switch characteristic.uuid {
            case G7BLEUUID.authentication:
                authenticationCharacteristic = characteristic
            case G7BLEUUID.control:
                controlCharacteristic = characteristic
            case G7BLEUUID.backfill:
                backfillCharacteristic = characteristic
            default:
                break
            }
        }

        guard authenticationCharacteristic != nil,
              controlCharacteristic != nil,
              backfillCharacteristic != nil
        else {
            Task {
                await logG7Ble("event=g7_ble_error error=characteristics_incomplete")
            }
            teardownSession(reason: "characteristics_incomplete")
            return
        }

        Task {
            await logG7Ble("event=g7_ble_characteristics_discovered")
        }

        if let auth = authenticationCharacteristic {
            peripheral.setNotifyValue(true, for: auth)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task {
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "notification_state")
            return
        }

        guard characteristic.isNotifying else { return }

        let charName: String
        switch characteristic.uuid {
        case G7BLEUUID.authentication: charName = "auth"
        case G7BLEUUID.control: charName = "control"
        case G7BLEUUID.backfill: charName = "backfill"
        default: charName = "unknown"
        }
        Task {
            await logG7Ble("event=g7_ble_notify_state char=\(charName) notifying=true")
        }

        switch characteristic.uuid {
        case G7BLEUUID.authentication:
            sendAuthRequest()
        case G7BLEUUID.control:
            controlNotificationsReady = true
            trySendEGVRequestIfReady()
        case G7BLEUUID.backfill:
            backfillNotificationsReady = true
            trySendEGVRequestIfReady()
        default:
            break
        }

        cancelGattSetupTimeoutWhenNotifyChannelsReady()
    }

    /// Clears `awaiting_gatt_setup` timeout once **control** and **backfill** notifications are enabled (auth alone is not full GATT readiness for the data path).
    private func cancelGattSetupTimeoutWhenNotifyChannelsReady() {
        guard controlNotificationsReady, backfillNotificationsReady else { return }
        gattSetupTimeoutWorkItem?.cancel()
        gattSetupTimeoutWorkItem = nil
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task {
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case G7BLEUUID.authentication:
            handleAuthenticationNotification(data)
        case G7BLEUUID.control:
            handleEGVPayload(data)
        case G7BLEUUID.backfill:
            // Backfill deferred — optional follow-up.
            break
        default:
            break
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if characteristic.uuid == G7BLEUUID.authentication {
                Task {
                    await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
                }
                teardownSession(reason: "write_failed_auth", isFailure: true)
            } else {
                Task {
                    await logG7Ble(
                        "event=g7_ble_write_error_nonfatal characteristic=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)"
                    )
                }
            }
            return
        }
        switch characteristic.uuid {
        case G7BLEUUID.authentication:
            Task {
                await logG7Ble("event=g7_ble_write_ok write=auth_init")
            }
        case G7BLEUUID.control:
            Task {
                await logG7Ble("event=g7_ble_write_ok write=egv_request")
            }
        default:
            break
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension G7DirectBLEManager: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_: WKExtendedRuntimeSession) {
        Task {
            await logG7Ble("event=g7_ble_ext_session_started")
        }
    }

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard let ext = extendedSession, ext === session else { return }
            await logG7Ble("event=g7_ble_ext_session_expiring")
            teardownSession(reason: "ext_session_expired", isFailure: false)
        }
    }

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        // Resolve identity **before** clearing `extendedSession`: otherwise the teardown guard would see `nil` and skip
        // `teardownSession` for legitimate **error** invalidations of the current session (ChatGPT / Claude review).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isCurrentSession: Bool = {
                guard let ext = self.extendedSession else { return false }
                return ext === session
            }()
            if isCurrentSession {
                self.extendedSession = nil
            }
            let errDesc = error.map { $0.localizedDescription } ?? "none"
            await self.logG7Ble(
                "event=g7_ble_ext_session_invalidated reason=\(String(describing: reason)) error=\(errDesc)"
            )
            // Only tear down BLE on **error** invalidation for the **current** session — normal / renewal paths use other
            // `reason` values and must not disconnect here; stale delegates after renewal must not tear down either.
            guard reason == .error, isCurrentSession, self.scanningStarted, self.peripheral != nil else { return }
            self.teardownSession(reason: "ext_session_invalidated", isFailure: true)
        }
    }
}

// MARK: - Data + endian helpers

private extension Data {
    func readUInt16LE(offset: Int) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
