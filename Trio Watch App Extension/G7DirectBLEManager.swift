import CoreBluetooth
import Foundation
import Observation
import WatchKit

// MARK: - UUIDs (Dexcom G7 data service — DiaBLE/Dexcom IPA verified)

private enum G7BLEUUID {
    /// Advertisement service for scanning (`scanForPeripherals` filter — Dexcom G7 advertises this UUID).
    static let advertisement = CBUUID(string: "FEBC")
    /// Primary GATT service on an established G7 connection. Phase H uses this together with `advertisement`
    /// for connection-event matching and connected-peripheral retrieval, mirroring G7SensorKit's attach path.
    static let dataService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let communication = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    static let jPake = CBUUID(string: "F8083538-849E-531C-C594-30F1F86A4EA5")
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

struct G7BLECycleSeedContext {
    let complicationSnapshotReadingDate: Date?
    let phoneRelayReadingDate: Date?
}

private enum G7BLEExtendedRuntimeState: String {
    case idle
    case starting
    case active
    case expiring
    case invalidated
}

private enum G7BLERuntimeGateResult {
    case active
    case starting
    case unavailable
}

/// Foreground-only direct BLE eavesdrop path to Dexcom G7 (no J-PAKE response).
@Observable
final class G7DirectBLEManager: NSObject {
    private static let activePeripheralIdentifierAppGroupKey = "g7_active_peripheral_identifier"
    private static let connectedAttachServiceUUIDs = [G7BLEUUID.dataService, G7BLEUUID.advertisement]
    private static let cycleLeadWindowSeconds: TimeInterval = 20
    private static let cycleWarmupLeadSeconds: TimeInterval = 30
    private static let cycleCadenceSeconds: TimeInterval = 5 * 60
    private static let cycleFallbackDelayAfterExpectedSeconds: TimeInterval = 5
    private static let cycleHardStopAfterExpectedSeconds: TimeInterval = 25
    private static let cycleGraceAfterExpectedSeconds: TimeInterval = 35
    private static let sameCycleRetryDelaySeconds: TimeInterval = 3
    private static let minimumRetryRemainingSeconds: TimeInterval = 3

    private(set) var connectionState: G7BLEConnectionState = .idle

    private var central: CBCentralManager?
    /// If set, `didDisconnect` uses this instead of the CB error string (e.g. user `stop()`).
    private var pendingDisconnectReason: String?
    private weak var peripheral: CBPeripheral?
    private var dataService: CBService?
    private var communicationCharacteristic: CBCharacteristic?
    private var authenticationCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var backfillCharacteristic: CBCharacteristic?
    private var jPakeCharacteristic: CBCharacteristic?

    /// Wall-clock sensor activation inferred from the first successful EGV (`now - txTime`).
    private var storedActivationWallClock: Date?
    private var passiveObservationArmed = false
    private var fallbackEgvRequestSent = false
    private var pendingControlWriteLogKind: String?
    private(set) var authNotificationsReady = false
    private(set) var communicationNotificationsReady = false
    private(set) var controlNotificationsReady = false
    private(set) var jpakeSkippedInObserver = false
    private(set) var observerAuthenticated = false
    private(set) var observerBonded = false
    private(set) var passiveObservationGateSatisfied = false
    private(set) var lastAuthOpcodeSeen: UInt8?
    private(set) var awaitingFirstEgv = false
    private var scanningStarted = false
    private var isForegroundActive = false
    /// Prevents duplicate `g7_ble_scan_started` when both `startScanning` and `centralManagerDidUpdateState` run.
    private var loggedScanStartThisRequest = false
    /// Phase E: `first_attempt` on `g7_ble_pre_connect` — reset in `startScanning()`.
    private var connectAttemptsSinceStartScanning = 0
    /// Phase E: `preserved_session` on `g7_ble_pre_connect` — set when `applyForegroundActiveEntry` skips a full `startScanning()`; cleared when `startScanning()` runs.
    private var sessionPreservedAcrossForegroundReentry = false
    /// Phase E: `cbcentral_allocated_in_start_scanning` on `g7_ble_pre_connect` — `true` only when this **`startScanning()`** call allocated `CBCentralManager` (`central` was `nil`). Not “fresh for this connect” on preserved-session paths that skip `startScanning()`.
    private var centralManagerAllocatedInLastStartScanning = false
    /// Phase E: `discover_count_for_target` — increments on each `didDiscover` for the active-name filter match; reset in `startScanning()`.
    private var discoverCountForActiveTarget = 0
    /// F5: suppress duplicate `connect()` attempts when multiple retrieval paths surface the same peripheral within
    /// one attach cycle. Here "attach cycle" means one `startScanning()` session / `g7_session`; the set is cleared
    /// when a new scan cycle begins. This is an intentional diagnostic tradeoff for F5: a later re-sighting of the
    /// same peripheral in the same attach cycle will be suppressed rather than retried automatically.
    private var attemptedConnectPeripheralIdentifiers: Set<UUID> = []
    /// Scheduled same-cycle retry after a classified cycle miss.
    private var cycleRetryWorkItem: DispatchWorkItem?
    private(set) var cycleRetryScheduled = false

    // MARK: - Phase G cadence scheduler

    private var latestComplicationSnapshotReadingDate: Date?
    private var latestPhoneRelayReadingDate: Date?
    private var lastSuccessfulDirectBleReadingDate: Date?
    private var currentCycleID: String?
    private var currentCycleGeneration = 0
    private var currentCycleAnchorSource: String?
    private var currentCycleAnchorDate: Date?
    private var currentCycleExpectedReadingDate: Date?
    private var currentCycleWarmupDate: Date?
    private var currentCycleLeadWindowDate: Date?
    private var currentCycleFallbackDate: Date?
    private var currentCycleHardStopDate: Date?
    private var currentCycleGraceCloseDate: Date?
    private var currentCycleStartedAt: Date?
    private var currentCycleBootstrap = false
    private var currentCycleNoConnectRetryCount = 0
    private var currentCyclePostConnectRetryCount = 0
    private var cycleWarmupWorkItem: DispatchWorkItem?
    private var cycleStartWorkItem: DispatchWorkItem?
    private var cycleRuntimeActivationWorkItem: DispatchWorkItem?

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
    private var passiveObservationFallbackWorkItem: DispatchWorkItem?
    /// Dedupe: at most one `g7_ble_timeout` per stage string per session.
    private var timeoutEmittedKeys: Set<String> = []
    private var lastNonEgControlLogAt: Date?
    /// Dedupe for blocked-state classifiers (`attach_blocked`, `passive_gate_blocked`, `passive_observation_blocked`).
    private var blockedStateEmittedKeys: Set<String> = []
    private(set) var activeTimeoutStage: String?
    private(set) var lastTimedOutStage: String?

    // MARK: - Debug view state

    private(set) var lastSeenPeripheralName: String?
    private(set) var lastSeenPeripheralRSSI: Int?
    private(set) var lastSeenPeripheralAt: Date?
    private(set) var lastEgvReceivedAt: Date?
    private(set) var lastGlucoseValue: Int?
    private(set) var lastReadingDate: Date?
    private(set) var lastSequenceNumber: Int?
    private(set) var lastSnapshotSaveResult: String?
    private(set) var lastSnapshotSaveAt: Date?
    private(set) var lastDisconnectReason: String?
    private(set) var lastPassiveObservationBlockedReason: String?
    private(set) var lastBlockedReason: String?
    private(set) var lastAttachSource: String?
    private(set) var lastTerminalOutcome: String?
    private(set) var lastTerminalReason: String?
    private(set) var lastTerminalStage: String?
    private(set) var lastTerminalAt: Date?
    private(set) var lastStageTransitionAt: Date?
    private(set) var lastRetrievedIdentifierCount: Int?
    private(set) var lastRetrievedConnectedCount: Int?
    private(set) var lastPersistedPeripheralIdentifierShort: String?
    private(set) var lastIdentifierRetrievalSkipReason: String?
    private(set) var lastIdentifierRetrievalPeripheralName: String?
    private(set) var lastPreConnectPeripheralState: Int?
    private(set) var lastPreConnectCentralState: Int?
    private(set) var lastPreConnectIsConnectable: String?
    private(set) var lastPreConnectPreservedSession: Bool?
    private(set) var lastPreConnectAllocatedCentralInStartScanning: Bool?
    private(set) var lastBlockerCategory: String?
    private(set) var lastBlockerSource: String?
    private(set) var lastBlockerReasonRaw: String?
    private(set) var lastBlockerAt: Date?
    private(set) var latestSessionFilterArmed = false
    private(set) var latestSessionTargetMatched = false
    private(set) var latestSessionPreConnectSane = false
    private(set) var latestSessionConnectAttempted = false
    private(set) var latestSessionDidConnect = false
    private(set) var latestSessionServicesDiscovered = false
    private(set) var latestSessionCharacteristicsCallbackReturned = false
    private(set) var latestSessionRequiredCharacteristicsPresent = false
    private(set) var latestSessionAuthNotifyEnabled = false
    private(set) var latestSessionJpakeSkipped = false
    private(set) var latestSessionSawAuthChallenge03 = false
    private(set) var latestSessionAuthenticated = false
    private(set) var latestSessionBonded = false
    private(set) var latestSessionCommunicationNotifyEnabled = false
    private(set) var latestSessionControlNotifyEnabled = false
    private(set) var latestSessionPassiveObservationArmed = false
    private(set) var latestSessionFallbackEgvRequestSent = false
    private(set) var latestSessionEgvResponseReceived = false
    private(set) var latestSessionSnapshotSaved = false

    private enum G7BLEInstrumentation {
        static let connectTimeoutSeconds: TimeInterval = 30
        static let gattSetupTimeoutSeconds: TimeInterval = 60
        static let firstEgvTimeoutSeconds: TimeInterval = 90
        // Leave most of the first-EGV window to the passive path; fallback should be rescue behavior, not default.
        static let passiveObservationFallbackSeconds: TimeInterval = 60
        static let nonEgControlLogMinInterval: TimeInterval = 1.0
    }

    /// Exposed for `WatchState` `g7_ble_lifecycle` lines after `startScanning()`.
    var currentG7SessionId: String? { g7SessionID }

    /// When set, only connect to a peripheral whose `name` matches exactly (e.g. active `DXCMxx`).
    /// `nil` means scan/readiness may continue, but attach is blocked until the phone supplies the active sensor filter.
    var activePeripheralName: String?

    var hasActivePeripheralNameFilter: Bool {
        guard let activePeripheralName else { return false }
        return !activePeripheralName.isEmpty
    }

    var isExtendedRuntimeSessionActive: Bool { runtimeState == .active || runtimeState == .expiring }

    var lastAuthOpcodeHex: String? {
        guard let lastAuthOpcodeSeen else { return nil }
        return String(format: "0x%02X", lastAuthOpcodeSeen)
    }

    var debugConnectionStageLabel: String {
        switch connectionState {
        case .idle, .disconnected:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .connecting:
            return "Connecting"
        case .authenticating:
            if passiveObservationGateSatisfied && !controlNotificationsReady {
                return "Awaiting control"
            }
            return "Awaiting auth"
        case .connected:
            return awaitingFirstEgv ? "Awaiting EGV" : "Connected"
        case .error:
            return "Error"
        }
    }

    var debugTimeoutStage: String? {
        activeTimeoutStage ?? lastTimedOutStage
    }

    var debugRuntimeStateLabel: String {
        Self.debugDisplayLabel(for: runtimeState.rawValue)
    }

    var debugCycleStatusLabel: String {
        guard currentCycleExpectedReadingDate != nil else { return "No scheduled cycle" }

        if cycleRetryScheduled {
            return "Same-cycle retry scheduled"
        }

        switch runtimeState {
        case .starting:
            return "Awaiting runtime activation"
        case .invalidated:
            return "Runtime invalidated"
        default:
            break
        }

        let now = Date()
        if let leadWindowDate = currentCycleLeadWindowDate, now < leadWindowDate {
            return "Waiting for lead window"
        }
        if scanningStarted || connectionState == .connecting || connectionState == .authenticating {
            return "Executing attach window"
        }
        if connectionState == .connected {
            return awaitingFirstEgv ? "Awaiting EGV" : "Connected in cycle"
        }
        if let graceCloseDate = currentCycleGraceCloseDate, now >= graceCloseDate {
            return "Cycle overdue"
        }
        return "Cycle armed"
    }

    var debugCurrentCycleID: String? {
        currentCycleID
    }

    var debugCurrentCycleAnchorSource: String? {
        currentCycleAnchorSource
    }

    var debugCurrentCycleExpectedReadingDate: Date? {
        currentCycleExpectedReadingDate
    }

    var debugCurrentCycleLeadWindowDate: Date? {
        currentCycleLeadWindowDate
    }

    var debugCurrentCycleGraceCloseDate: Date? {
        currentCycleGraceCloseDate
    }

    var debugCurrentCycleBootstrap: Bool? {
        currentCycleExpectedReadingDate == nil ? nil : currentCycleBootstrap
    }

    var debugCurrentProtocolStageLabel: String {
        if let activeTimeoutStage {
            return Self.debugDisplayLabel(for: activeTimeoutStage)
        }
        if let terminalLabel = debugTerminalLifecycleLabel {
            return terminalLabel
        }
        if connectionState == .connected, egvReceivedThisSession {
            return "Waiting for next reading"
        }
        if let lastInstrumentationStage {
            return Self.debugDisplayLabel(for: lastInstrumentationStage)
        }
        return debugConnectionStageLabel
    }

    var debugTerminalLifecycleLabel: String? {
        guard let outcome = lastTerminalOutcome else { return nil }
        switch outcome {
        case "timeout":
            if let stage = lastTerminalStage {
                return "Timed out: \(Self.debugDisplayLabel(for: stage))"
            }
            return "Timed out"
        case "failed":
            if let reason = lastTerminalReason {
                return "Failed: \(Self.humanizeDebugReason(reason))"
            }
            return "Failed"
        case "disconnected":
            if let reason = lastTerminalReason {
                return "Disconnected: \(Self.humanizeDebugReason(reason))"
            }
            return "Disconnected"
        case "completed":
            if let reason = lastTerminalReason {
                return "Completed: \(Self.humanizeDebugReason(reason))"
            }
            return "Completed"
        default:
            return Self.debugDisplayLabel(for: outcome)
        }
    }

    private var extendedSession: WKExtendedRuntimeSession?
    private var runtimeState: G7BLEExtendedRuntimeState = .idle
    private var sessionStartedAt: Date?
    private var egvReceivedThisSession = false

    // MARK: - Public API

    override init() {
        super.init()
        _ = ensureCentralManagerInitialized()
        lastPersistedPeripheralIdentifierShort = loadPersistedPeripheralIdentifier().map {
            boundedPeripheralShortList([$0], maxCount: 1)
        }
    }

    /// Record that the app UI left **`ScenePhase.active`**. Phase G keeps existing BLE work alive when possible, but
    /// new runtime acquisition is scheduler-owned and should not assume the app is still active after this point.
    func noteSceneLeftActiveUi(at _: Date) {
        isForegroundActive = false
    }

    /// Called when `ScenePhase` becomes **`.active`**. Phase G uses this as a thin scheduler-entry wrapper:
    /// apply the phone-supplied sensor filter, refresh cadence anchors, and let the cadence scheduler decide whether
    /// to bootstrap immediately, continue an in-flight cycle, or wait for the next predicted window.
    func applyForegroundActiveEntry(
        activePeripheralName: String?,
        cycleSeedContext: G7BLECycleSeedContext
    ) {
        isForegroundActive = true
        if scanningStarted || connectionState == .connecting || connectionState == .authenticating || connectionState == .connected {
            sessionPreservedAcrossForegroundReentry = true
        }
        _ = setActivePeripheralName(activePeripheralName, logIfChanged: true)
        updateCycleSeedContext(cycleSeedContext)
        refreshCadenceScheduler(trigger: "foreground_entry")
    }

    /// Updates the phone-supplied active peripheral name while the watch is already running so a late WatchConnectivity
    /// payload can arm the filter and refresh cadence planning without waiting for another foreground transition.
    func updatePhoneActivePeripheralName(_ activePeripheralName: String?) {
        let hadFilter = hasActivePeripheralNameFilter
        let changed = setActivePeripheralName(activePeripheralName, logIfChanged: true)
        guard changed else { return }
        if let currentPeripheral = peripheral,
           let activePeripheralName = self.activePeripheralName
        {
            let currentName = currentPeripheral.name ?? lastSeenPeripheralName ?? "unknown"
            guard currentName != activePeripheralName else { return }
            Task {
                await logG7Ble(
                    "event=g7_ble_peripheral_skipped peripheral=\(currentName) reason=not_active_sensor source=phone_filter_update"
                )
            }
            if scanningStarted {
                startScanning()
            } else {
                refreshCadenceScheduler(trigger: "phone_filter_update")
            }
            return
        }
        guard hasActivePeripheralNameFilter, (!hadFilter || peripheral == nil) else { return }
        if scanningStarted {
            return
        }
        refreshCadenceScheduler(trigger: "phone_filter_update")
    }

    /// Begins (or restarts) scanning for G7 advertisements. Prefer **`applyForegroundActiveEntry`** from **`WatchState`**
    /// so returning to the app does not tear down an already-running session.
    func startScanning() {
        let allocatedNewCentral = ensureCentralManagerInitialized()
        guard let central else { return }
        centralManagerAllocatedInLastStartScanning = allocatedNewCentral

        cycleRetryWorkItem?.cancel()
        cycleRetryWorkItem = nil

        let priorSessionID = g7SessionID
        let canceledConnectTimeoutForRescan = peripheral != nil && cancelConnectTimeoutIfNeeded()
        _ = cancelGattSetupTimeoutIfNeeded(
            reason: "startScanning_rescan",
            sessionID: priorSessionID
        )
        if canceledConnectTimeoutForRescan {
            Task {
                await logG7Ble(
                    "event=g7_ble_connect_timeout_canceled reason=startScanning_rescan",
                    sessionID: priorSessionID
                )
            }
        }

        scanningStarted = true
        sessionPreservedAcrossForegroundReentry = false
        connectAttemptsSinceStartScanning = 0
        discoverCountForActiveTarget = 0
        attemptedConnectPeripheralIdentifiers.removeAll()
        g7SessionID = UUID().uuidString
        sessionStartedAt = Date()
        timeoutEmittedKeys.removeAll()
        blockedStateEmittedKeys.removeAll()
        lastInstrumentationStage = nil
        lastStageTransitionAt = nil
        discoverWallClock = nil
        cancelInstrumentationTimeouts()
        loggedScanStartThisRequest = false
        cycleRetryScheduled = false
        resetLatestSessionGateProgress(filterArmed: hasActivePeripheralNameFilter)
        resetDebugSessionContext()
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

        // Attach to a G7 already connected at the watchOS level (e.g. Dexcom Watch app) without waiting for an advertisement.
        _ = attemptRetrievedAttachIfAvailable(
            central: central,
            retrievalEvent: "g7_ble_retrieve_result",
            blockedSource: "scan_start"
        )

        switch central.state {
        case .poweredOn:
            registerForConnectionEventsIfNeeded(on: central)
            central.scanForPeripherals(
                withServices: [G7BLEUUID.advertisement],
                options: nil
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
        cycleRetryWorkItem?.cancel()
        cycleRetryWorkItem = nil
        cancelCycleScheduling()
        clearCurrentCycleState()
        isForegroundActive = false
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

    func clearStoredPeripheralIdentifier() {
        clearPersistedPeripheralIdentifier(reason: "manual_clear")
        if scanningStarted {
            startScanning()
        }
    }

    private func ensureCentralManagerInitialized() -> Bool {
        guard central == nil else { return false }
        central = CBCentralManager(
            delegate: self,
            // F2 parity experiment: match DiaBLE's `CBCentralManager` init while keeping delegate work on the main queue.
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: false,
                CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"
            ]
        )
        return true
    }

    private func registerForConnectionEventsIfNeeded(on central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.registerForConnectionEvents(options: [
            CBConnectionEventMatchingOption.serviceUUIDs: Self.connectedAttachServiceUUIDs
        ])
    }

    func notePhoneRelayReadingDate(_ readingDate: Date?) {
        guard let readingDate else { return }
        let advanced: Bool
        if let existing = latestPhoneRelayReadingDate {
            latestPhoneRelayReadingDate = max(existing, readingDate)
            advanced = readingDate > existing
        } else {
            latestPhoneRelayReadingDate = readingDate
            advanced = true
        }
        guard advanced else { return }
        refreshCadenceScheduler(trigger: "phone_relay_update")
    }

    private func updateCycleSeedContext(_ cycleSeedContext: G7BLECycleSeedContext) {
        if let complicationSnapshotReadingDate = cycleSeedContext.complicationSnapshotReadingDate {
            if let existing = latestComplicationSnapshotReadingDate {
                latestComplicationSnapshotReadingDate = max(existing, complicationSnapshotReadingDate)
            } else {
                latestComplicationSnapshotReadingDate = complicationSnapshotReadingDate
            }
        }

        if let phoneRelayReadingDate = cycleSeedContext.phoneRelayReadingDate {
            if let existing = latestPhoneRelayReadingDate {
                latestPhoneRelayReadingDate = max(existing, phoneRelayReadingDate)
            } else {
                latestPhoneRelayReadingDate = phoneRelayReadingDate
            }
        }
    }

    private func selectedCycleAnchor(now: Date) -> (source: String, anchorDate: Date, nextExpectedDate: Date, bootstrap: Bool) {
        if let directBle = lastSuccessfulDirectBleReadingDate {
            let nextExpectedDate = rolledForwardExpectedDate(after: directBle, now: now)
            return ("direct_ble", directBle, nextExpectedDate, false)
        }
        if let complicationSnapshot = latestComplicationSnapshotReadingDate {
            let nextExpectedDate = rolledForwardExpectedDate(after: complicationSnapshot, now: now)
            return ("snapshot", complicationSnapshot, nextExpectedDate, false)
        }
        if let phoneRelay = latestPhoneRelayReadingDate {
            let nextExpectedDate = rolledForwardExpectedDate(after: phoneRelay, now: now)
            return ("phone_relay", phoneRelay, nextExpectedDate, false)
        }
        return ("bootstrap", now, now, true)
    }

    private func rolledForwardExpectedDate(after anchorDate: Date, now: Date) -> Date {
        var nextExpectedDate = anchorDate.addingTimeInterval(Self.cycleCadenceSeconds)
        while nextExpectedDate <= now {
            nextExpectedDate.addTimeInterval(Self.cycleCadenceSeconds)
        }
        return nextExpectedDate
    }

    private func cancelCycleScheduling() {
        cycleRetryWorkItem?.cancel()
        cycleRetryWorkItem = nil
        cycleWarmupWorkItem?.cancel()
        cycleWarmupWorkItem = nil
        cycleStartWorkItem?.cancel()
        cycleStartWorkItem = nil
        cycleRuntimeActivationWorkItem?.cancel()
        cycleRuntimeActivationWorkItem = nil
        cycleRetryScheduled = false
    }

    private func clearCurrentCycleState() {
        currentCycleID = nil
        currentCycleAnchorSource = nil
        currentCycleAnchorDate = nil
        currentCycleExpectedReadingDate = nil
        currentCycleWarmupDate = nil
        currentCycleLeadWindowDate = nil
        currentCycleFallbackDate = nil
        currentCycleHardStopDate = nil
        currentCycleGraceCloseDate = nil
        currentCycleStartedAt = nil
        currentCycleBootstrap = false
        currentCycleNoConnectRetryCount = 0
        currentCyclePostConnectRetryCount = 0
    }

    private func refreshCadenceScheduler(trigger: String, forceReschedule: Bool = false) {
        let now = Date()

        if !forceReschedule,
           let cycleGraceCloseDate = currentCycleGraceCloseDate,
           now < cycleGraceCloseDate,
           (scanningStarted || connectionState == .connecting || connectionState == .authenticating || connectionState == .connected)
        {
            Task {
                await logG7Ble(
                    "event=g7_ble_cycle_scheduled trigger=\(trigger) action=keep_inflight expected_epoch=\(Int((currentCycleExpectedReadingDate ?? now).timeIntervalSince1970))"
                )
            }
            return
        }

        let anchor = selectedCycleAnchor(now: now)
        scheduleCycle(
            expectedReadingDate: anchor.nextExpectedDate,
            anchorSource: anchor.source,
            anchorDate: anchor.anchorDate,
            bootstrap: anchor.bootstrap,
            trigger: trigger
        )
    }

    private func scheduleCycle(
        expectedReadingDate: Date,
        anchorSource: String,
        anchorDate: Date,
        bootstrap: Bool,
        trigger: String
    ) {
        cancelCycleScheduling()

        let now = Date()
        currentCycleGeneration += 1
        let generation = currentCycleGeneration
        let cycleID = UUID().uuidString
        let warmupDate = bootstrap ? now : expectedReadingDate.addingTimeInterval(-Self.cycleWarmupLeadSeconds)
        let leadWindowDate = bootstrap ? now : expectedReadingDate.addingTimeInterval(-Self.cycleLeadWindowSeconds)
        let fallbackDate = expectedReadingDate.addingTimeInterval(Self.cycleFallbackDelayAfterExpectedSeconds)
        let hardStopDate = expectedReadingDate.addingTimeInterval(Self.cycleHardStopAfterExpectedSeconds)
        let graceCloseDate = expectedReadingDate.addingTimeInterval(Self.cycleGraceAfterExpectedSeconds)

        clearCurrentCycleState()
        currentCycleID = cycleID
        currentCycleAnchorSource = anchorSource
        currentCycleAnchorDate = anchorDate
        currentCycleExpectedReadingDate = expectedReadingDate
        currentCycleWarmupDate = warmupDate
        currentCycleLeadWindowDate = leadWindowDate
        currentCycleFallbackDate = fallbackDate
        currentCycleHardStopDate = hardStopDate
        currentCycleGraceCloseDate = graceCloseDate
        currentCycleBootstrap = bootstrap

        Task {
            await logG7Ble(
                "event=g7_ble_cycle_anchor source=\(anchorSource) anchor_epoch=\(Int(anchorDate.timeIntervalSince1970)) next_expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
            )
            await logG7Ble(
                "event=g7_ble_cycle_scheduled trigger=\(trigger) bootstrap=\(bootstrap) warmup_epoch=\(Int(warmupDate.timeIntervalSince1970)) lead_window_epoch=\(Int(leadWindowDate.timeIntervalSince1970)) hard_stop_epoch=\(Int(hardStopDate.timeIntervalSince1970)) grace_close_epoch=\(Int(graceCloseDate.timeIntervalSince1970))",
                sessionID: nil
            )
        }

        let warmupDelay = warmupDate.timeIntervalSince(now)
        if warmupDelay <= 0 {
            beginCycleWarmupIfNeeded(generation: generation, trigger: trigger)
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                self?.beginCycleWarmupIfNeeded(generation: generation, trigger: "scheduled_warmup")
            }
            cycleWarmupWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + warmupDelay, execute: workItem)
        }

        let startDelay = leadWindowDate.timeIntervalSince(now)
        if startDelay <= 0 {
            startScheduledCycleIfNeeded(generation: generation, trigger: trigger)
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                self?.startScheduledCycleIfNeeded(generation: generation, trigger: "lead_window_open")
            }
            cycleStartWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: workItem)
        }
    }

    private func beginCycleWarmupIfNeeded(generation: Int, trigger: String) {
        guard generation == currentCycleGeneration else { return }
        guard let expectedReadingDate = currentCycleExpectedReadingDate else { return }
        _ = ensureRuntimeForCurrentCycle(trigger: trigger, expectedReadingDate: expectedReadingDate)
    }

    private func startScheduledCycleIfNeeded(generation: Int, trigger: String) {
        guard generation == currentCycleGeneration else { return }
        guard let expectedReadingDate = currentCycleExpectedReadingDate else { return }

        currentCycleStartedAt = Date()
        Task {
            await logG7Ble(
                "event=g7_ble_cycle_started trigger=\(trigger) bootstrap=\(currentCycleBootstrap) expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
            )
        }

        switch ensureRuntimeForCurrentCycle(trigger: "cycle_start", expectedReadingDate: expectedReadingDate) {
        case .active:
            continueCurrentCycleExecution(trigger: trigger)
        case .starting:
            Task {
                await logG7Ble(
                    "event=g7_ble_cycle_started trigger=\(trigger) action=await_runtime_activation expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
        case .unavailable:
            let category = "runtime"
            Task {
                await logG7Ble("event=g7_ble_cycle_missed category=\(category) reason=runtime_unavailable")
            }
            scheduleNextCycleAfterMiss(reason: "runtime_unavailable", category: category)
        }
    }

    private func continueCurrentCycleExecution(trigger: String) {
        if connectionState == .connected,
           passiveObservationGateSatisfied,
           controlNotificationsReady
        {
            armPassiveObservationIfReady(forceCycleRearm: true)
            return
        }

        if scanningStarted || connectionState == .connecting || connectionState == .authenticating {
            Task {
                await logG7Ble("event=g7_ble_cycle_started trigger=\(trigger) action=continue_existing_attempt")
            }
            return
        }

        startScanning()
    }

    private func resumeCurrentCycleAfterRuntimeActivation(trigger: String) {
        guard let expectedReadingDate = currentCycleExpectedReadingDate else { return }
        let now = Date()

        guard let graceCloseDate = currentCycleGraceCloseDate, now < graceCloseDate else {
            Task {
                await logG7Ble(
                    "event=g7_ble_runtime_gate trigger=\(trigger) state=active_after_cycle_closed expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            scheduleNextCycleAfterMiss(reason: "runtime_unavailable", category: "runtime")
            return
        }

        if let leadWindowDate = currentCycleLeadWindowDate, now < leadWindowDate {
            Task {
                await logG7Ble(
                    "event=g7_ble_runtime_gate trigger=\(trigger) state=active_waiting_for_lead_window expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            return
        }

        Task {
            await logG7Ble(
                "event=g7_ble_runtime_gate trigger=\(trigger) state=active expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
            )
        }
        continueCurrentCycleExecution(trigger: "runtime_active")
    }

    private func armRuntimeActivationDeadlineIfNeeded(generation: Int, expectedReadingDate: Date) {
        cycleRuntimeActivationWorkItem?.cancel()
        cycleRuntimeActivationWorkItem = nil

        guard runtimeState != .active else { return }
        guard let hardStopDate = currentCycleHardStopDate else { return }

        let delay = hardStopDate.timeIntervalSinceNow
        if delay <= 0 {
            Task {
                await logG7Ble(
                    "event=g7_ble_runtime_gate trigger=runtime_activation_deadline state=activation_timeout expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            scheduleNextCycleAfterMiss(reason: "runtime_unavailable", category: "runtime")
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.currentCycleGeneration else { return }
            guard self.runtimeState != .active else { return }
            Task {
                await self.logG7Ble(
                    "event=g7_ble_runtime_gate trigger=runtime_activation_deadline state=activation_timeout expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            self.scheduleNextCycleAfterMiss(reason: "runtime_unavailable", category: "runtime")
        }
        cycleRuntimeActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func ensureRuntimeForCurrentCycle(trigger: String, expectedReadingDate: Date) -> G7BLERuntimeGateResult {
        if extendedSession != nil {
            let state = runtimeState
            Task {
                await logG7Ble(
                    "event=g7_ble_runtime_gate trigger=\(trigger) state=\(state.rawValue) expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            if state == .active || state == .expiring {
                cycleRuntimeActivationWorkItem?.cancel()
                cycleRuntimeActivationWorkItem = nil
                return .active
            }
            armRuntimeActivationDeadlineIfNeeded(
                generation: currentCycleGeneration,
                expectedReadingDate: expectedReadingDate
            )
            return .starting
        }

        guard isForegroundActive else {
            Task {
                await logG7Ble(
                    "event=g7_ble_runtime_gate trigger=\(trigger) state=blocked_app_inactive expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
            }
            return .unavailable
        }

        Task {
            await logG7Ble(
                "event=g7_ble_runtime_gate trigger=\(trigger) state=starting expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
            )
        }
        beginExtendedRuntimeSession()
        armRuntimeActivationDeadlineIfNeeded(
            generation: currentCycleGeneration,
            expectedReadingDate: expectedReadingDate
        )
        return .starting
    }

    private func scheduleRetryWithinCurrentCycle(reason: String, category: String, postConnect: Bool) {
        guard let graceCloseDate = currentCycleGraceCloseDate else { return }
        let remaining = graceCloseDate.timeIntervalSinceNow
        guard remaining >= Self.minimumRetryRemainingSeconds else {
            scheduleNextCycleAfterMiss(reason: reason, category: category)
            return
        }

        if postConnect {
            guard currentCyclePostConnectRetryCount == 0 else {
                scheduleNextCycleAfterMiss(reason: reason, category: category)
                return
            }
            currentCyclePostConnectRetryCount += 1
        } else {
            guard currentCycleNoConnectRetryCount == 0 else {
                scheduleNextCycleAfterMiss(reason: reason, category: category)
                return
            }
            currentCycleNoConnectRetryCount += 1
        }

        cycleRetryWorkItem?.cancel()
        let retryCycleID = currentCycleID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard retryCycleID == self.currentCycleID else { return }
            if let graceCloseDate = self.currentCycleGraceCloseDate,
               graceCloseDate.timeIntervalSinceNow < Self.minimumRetryRemainingSeconds
            {
                self.scheduleNextCycleAfterMiss(reason: reason, category: category)
                return
            }
            guard let expectedReadingDate = self.currentCycleExpectedReadingDate else { return }
            switch self.ensureRuntimeForCurrentCycle(trigger: "same_cycle_retry", expectedReadingDate: expectedReadingDate) {
            case .active:
                break
            case .starting:
                self.cycleRetryScheduled = false
                Task {
                    await self.logG7Ble(
                        "event=g7_ble_cycle_started trigger=same_cycle_retry action=await_runtime_activation expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                    )
                }
                return
            case .unavailable:
                self.scheduleNextCycleAfterMiss(reason: "runtime_unavailable", category: "runtime")
                return
            }
            self.cycleRetryScheduled = false
            self.startScanning()
        }
        cycleRetryWorkItem = workItem
        cycleRetryScheduled = true
        Task {
            await logG7Ble(
                "event=g7_ble_cycle_missed category=\(category) reason=\(reason) action=retry_same_cycle retry_delay_s=\(Int(Self.sameCycleRetryDelaySeconds))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sameCycleRetryDelaySeconds, execute: workItem)
    }

    private func scheduleNextCycleAfterMiss(reason: String, category: String) {
        cancelCycleScheduling()

        if currentCycleBootstrap,
           lastSuccessfulDirectBleReadingDate == nil,
           latestComplicationSnapshotReadingDate == nil,
           latestPhoneRelayReadingDate == nil
        {
            Task {
                await logG7Ble(
                    "event=g7_ble_cycle_missed category=\(category) reason=\(reason) action=hold_after_bootstrap_no_anchor"
                )
            }
            scanningStarted = false
            clearCurrentCycleState()
            return
        }

        scanningStarted = false
        clearCurrentCycleState()
        refreshCadenceScheduler(trigger: "cycle_miss_\(reason)", forceReschedule: true)
    }

    private func resetObservationStateForCycleRearm() {
        passiveObservationArmed = false
        fallbackEgvRequestSent = false
        pendingControlWriteLogKind = nil
        awaitingFirstEgv = false
        clearPassiveObservationBlockedReason(
            resolvedReasons: [
                "passive_gate_not_satisfied",
                "authenticated_false",
                "control_notify_not_enabled"
            ]
        )
    }

    /// After `didDiscover` or foreground re-entry while connected — `delegate` logs `g7_ble_ext_session_started`.
    private func beginExtendedRuntimeSession() {
        let ext = WKExtendedRuntimeSession()
        ext.delegate = self
        extendedSession = ext
        runtimeState = .starting
        ext.start()
    }

    // MARK: - Session reset

    private func resetSessionState() {
        discoverWallClock = nil
        dataService = nil
        communicationCharacteristic = nil
        authenticationCharacteristic = nil
        controlCharacteristic = nil
        backfillCharacteristic = nil
        jPakeCharacteristic = nil
        storedActivationWallClock = nil
        passiveObservationArmed = false
        fallbackEgvRequestSent = false
        pendingControlWriteLogKind = nil
        authNotificationsReady = false
        communicationNotificationsReady = false
        controlNotificationsReady = false
        jpakeSkippedInObserver = false
        observerAuthenticated = false
        observerBonded = false
        passiveObservationGateSatisfied = false
        lastAuthOpcodeSeen = nil
        awaitingFirstEgv = false
        activeTimeoutStage = nil
        egvReceivedThisSession = false
        lastPassiveObservationBlockedReason = nil
    }

    private func resetDebugSessionContext() {
        lastAttachSource = nil
        lastTerminalOutcome = nil
        lastTerminalReason = nil
        lastTerminalStage = nil
        lastTerminalAt = nil
        lastRetrievedIdentifierCount = nil
        lastRetrievedConnectedCount = nil
        lastIdentifierRetrievalSkipReason = nil
        lastIdentifierRetrievalPeripheralName = nil
        lastPreConnectPeripheralState = nil
        lastPreConnectCentralState = nil
        lastPreConnectIsConnectable = nil
        lastPreConnectPreservedSession = nil
        lastPreConnectAllocatedCentralInStartScanning = nil
        clearBlockerDebugState()
    }

    private func clearBlockedReasonIfResolved(_ resolvedReason: String) {
        guard let lastBlockedReason else { return }
        switch resolvedReason {
        case "passive_gate_not_satisfied":
            guard lastBlockedReason.hasPrefix("passive_gate_not_satisfied") else { return }
        case "authenticated_false":
            guard lastBlockedReason == "authenticated_false" else { return }
        case "notify_failed_auth":
            guard lastBlockedReason.hasPrefix("notify_failed (char=auth") else { return }
        case "notify_failed_communication":
            guard lastBlockedReason.hasPrefix("notify_failed (char=communication") else { return }
        case "notify_failed_control":
            guard lastBlockedReason.hasPrefix("notify_failed (char=control") else { return }
        case "control_notify_not_enabled":
            guard lastBlockedReason == "control_notify_not_enabled" else { return }
        default:
            guard lastBlockedReason == resolvedReason else { return }
        }
        self.lastBlockedReason = nil
        clearBlockerDebugState()
    }

    private func clearPassiveObservationBlockedReason(resolvedReason: String? = nil) {
        clearPassiveObservationBlockedReason(resolvedReasons: resolvedReason.map { [$0] } ?? [])
    }

    private func clearPassiveObservationBlockedReason(resolvedReasons: [String]) {
        guard !resolvedReasons.isEmpty else {
            lastPassiveObservationBlockedReason = nil
            return
        }
        for resolvedReason in resolvedReasons {
            if lastPassiveObservationBlockedReason == resolvedReason {
                lastPassiveObservationBlockedReason = nil
            }
            clearBlockedReasonIfResolved(resolvedReason)
        }
    }

    private func resetLatestSessionGateProgress(filterArmed: Bool) {
        latestSessionFilterArmed = filterArmed
        latestSessionTargetMatched = false
        latestSessionPreConnectSane = false
        latestSessionConnectAttempted = false
        latestSessionDidConnect = false
        latestSessionServicesDiscovered = false
        latestSessionCharacteristicsCallbackReturned = false
        latestSessionRequiredCharacteristicsPresent = false
        latestSessionAuthNotifyEnabled = false
        latestSessionJpakeSkipped = false
        latestSessionSawAuthChallenge03 = false
        latestSessionAuthenticated = false
        latestSessionBonded = false
        latestSessionCommunicationNotifyEnabled = false
        latestSessionControlNotifyEnabled = false
        latestSessionPassiveObservationArmed = false
        latestSessionFallbackEgvRequestSent = false
        latestSessionEgvResponseReceived = false
        latestSessionSnapshotSaved = false
        lastBlockedReason = nil
    }

    private func setTerminalDebugState(outcome: String, reason: String, stage: String?) {
        lastTerminalOutcome = outcome
        lastTerminalReason = reason
        lastTerminalStage = stage
        lastTerminalAt = Date()
    }

    private func setBlockerDebugState(category: String, source: String?, reason: String) {
        lastBlockerCategory = category
        lastBlockerSource = source
        lastBlockerReasonRaw = reason
        lastBlockerAt = Date()
    }

    private func clearBlockerDebugState() {
        lastBlockerCategory = nil
        lastBlockerSource = nil
        lastBlockerReasonRaw = nil
        lastBlockerAt = nil
    }

    private func noteLatestSessionFilterArmedIfNeeded(_ filterArmed: Bool) {
        guard filterArmed, scanningStarted || peripheral != nil else { return }
        latestSessionFilterArmed = true
        clearBlockedReasonIfResolved("missing_active_sensor_filter")
    }

    private func invalidateExtendedSession(reason: String) {
        guard extendedSession != nil else { return }
        extendedSession?.invalidate()
        extendedSession = nil
        runtimeState = .idle
        cycleRuntimeActivationWorkItem?.cancel()
        cycleRuntimeActivationWorkItem = nil
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

    private func cycleMissCategory(reason: String, finalStage: String?) -> String {
        switch reason {
        case "timeout_awaiting_connect", "connect_failed":
            return "timing"
        case "ext_session_invalidated":
            return "runtime"
        case "timeout_awaiting_gatt_setup", "discover_services", "no_data_service", "discover_characteristics", "characteristics_incomplete", "notification_state":
            return "gatt"
        case "timeout_awaiting_first_egv":
            return "observation"
        default:
            if finalStage == "awaiting_egv" {
                return "observation"
            }
            if finalStage == "discovering_services" || finalStage == "discovering_characteristics" || finalStage == "authenticating" {
                return "gatt"
            }
            return latestSessionDidConnect ? "gatt" : "timing"
        }
    }

    /// - Parameter isFailure: When `true`, sets `connectionState` to `.error` (protocol / BLE failure). When `false`, uses `.disconnected` (clean stop or non-error teardown).
    private func teardownSession(reason: String, isFailure: Bool = true) {
        assert(Thread.isMainThread, "teardownSession must run on the main queue (CBCentralManager delegate queue)")
        cycleRetryWorkItem?.cancel()
        cycleRetryWorkItem = nil
        let connectTimeoutCancelReason = reason == "stop_requested" ? "stop_requested" : "teardown"
        let canceledConnectTimeout = cancelConnectTimeoutIfNeeded()
        let outcomeSid = g7SessionID
        _ = cancelGattSetupTimeoutIfNeeded(reason: "teardown_\(reason)", sessionID: outcomeSid)
        cancelInstrumentationTimeouts()

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
        let missCategory = cycleMissCategory(reason: reason, finalStage: finalStage)
        let shouldAttemptSameCycleRetry = reason != "stop_requested" && reason != "startScanning_rescan"
        let isPostConnectFailure = latestSessionDidConnect || finalStage == "discovering_services" || finalStage == "discovering_characteristics" || finalStage == "authenticating" || finalStage == "awaiting_egv"
        switch outcome {
        case "timeout":
            break
        case "failure":
            setTerminalDebugState(outcome: "failed", reason: reason, stage: finalStage)
        case "cancelled", "incomplete":
            setTerminalDebugState(outcome: "disconnected", reason: reason, stage: finalStage)
        case "success":
            setTerminalDebugState(outcome: "completed", reason: "snapshot_saved", stage: finalStage)
        default:
            break
        }

        invalidateExtendedSession(reason: reason)

        resetSessionState()
        sessionStartedAt = nil
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        lastDisconnectReason = reason
        scanningStarted = false
        cycleRetryScheduled = false
        connectionState = isFailure ? .error(reason) : .disconnected(reason: reason)
        Task {
            if canceledConnectTimeout {
                await logG7Ble("event=g7_ble_connect_timeout_canceled reason=\(connectTimeoutCancelReason)")
            }
            await logG7Ble(
                "event=g7_ble_disconnected reason=\(reason) failure=\(isFailure ? "true" : "false")"
            )
            await logG7Ble(
                "event=g7_ble_session_outcome outcome=\(outcome) final_stage=\(stageField) duration_ms=\(durationMs) g7_session=\(outcomeSid ?? "none")"
            )
        }

        if outcome == "success" {
            refreshCadenceScheduler(trigger: "cycle_success")
            return
        }

        guard shouldAttemptSameCycleRetry else {
            if reason != "stop_requested" && reason != "startScanning_rescan" {
                scheduleNextCycleAfterMiss(reason: reason, category: missCategory)
            } else {
                clearCurrentCycleState()
            }
            return
        }

        if isFailure {
            scheduleRetryWithinCurrentCycle(
                reason: reason,
                category: missCategory,
                postConnect: isPostConnectFailure
            )
        } else {
            scheduleNextCycleAfterMiss(reason: reason, category: missCategory)
        }
    }

    // MARK: - Logging

    /// Appends `g7_session=` when the session id exists and the line does not already include it.
    /// Forwards `#fileID` / `#line` / `#function` into `WatchLogger` so log metadata reflects the **call site**, not this helper.
    private func logG7Ble(
        _ message: String,
        sessionID: String? = nil,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        var out = message
        if let sid = sessionID ?? g7SessionID, !out.contains("g7_session=") {
            out += " g7_session=\(sid)"
        }
        if let cycleID = currentCycleID, !out.contains("g7_cycle=") {
            out += " g7_cycle=\(cycleID)"
        }
        await WatchLogger.shared.log(out, function: function, file: file, line: line)
    }

    private func emitStageIfChanged(_ stage: String) {
        guard lastInstrumentationStage != stage else { return }
        lastInstrumentationStage = stage
        lastStageTransitionAt = Date()
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
        passiveObservationFallbackWorkItem?.cancel()
        passiveObservationFallbackWorkItem = nil
        activeTimeoutStage = nil
    }

    private func cycleRelativeDelay(until targetDate: Date?, fallback: TimeInterval) -> TimeInterval {
        guard let targetDate else { return fallback }
        return max(0.1, targetDate.timeIntervalSinceNow)
    }

    private func loggedSeconds(_ interval: TimeInterval) -> Int {
        max(1, Int(interval.rounded(.up)))
    }

    private func cancelConnectTimeoutIfNeeded() -> Bool {
        guard connectTimeoutWorkItem != nil else { return false }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        if activeTimeoutStage == "awaiting_connect" {
            activeTimeoutStage = nil
        }
        return true
    }

    @discardableResult
    private func cancelGattSetupTimeoutIfNeeded(reason: String, sessionID: String? = nil) -> Bool {
        let hadTimer = gattSetupTimeoutWorkItem != nil || activeTimeoutStage == "awaiting_gatt_setup"
        guard hadTimer else { return false }
        gattSetupTimeoutWorkItem?.cancel()
        gattSetupTimeoutWorkItem = nil
        if activeTimeoutStage == "awaiting_gatt_setup" {
            activeTimeoutStage = nil
        }
        Task {
            await logG7Ble(
                "event=g7_ble_gatt_setup_timeout_canceled reason=\(reason)",
                sessionID: sessionID
            )
        }
        return true
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
        activeTimeoutStage = "awaiting_connect"
        let generation = currentCycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.currentCycleGeneration else { return }
            Task { @MainActor in
                await self.handleTimeout(stage: "awaiting_connect")
            }
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + cycleRelativeDelay(
                until: currentCycleHardStopDate,
                fallback: G7BLEInstrumentation.connectTimeoutSeconds
            ),
            execute: work
        )
        Task {
            await logG7Ble(
                "event=g7_ble_connect_timeout_armed timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleHardStopDate, fallback: G7BLEInstrumentation.connectTimeoutSeconds)))"
            )
        }
    }

    private func scheduleGattSetupTimeout() {
        gattSetupTimeoutWorkItem?.cancel()
        activeTimeoutStage = "awaiting_gatt_setup"
        let generation = currentCycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.currentCycleGeneration else { return }
            Task { @MainActor in
                await self.handleTimeout(stage: "awaiting_gatt_setup")
            }
        }
        gattSetupTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + cycleRelativeDelay(
                until: currentCycleHardStopDate,
                fallback: G7BLEInstrumentation.gattSetupTimeoutSeconds
            ),
            execute: work
        )
        Task {
            await logG7Ble(
                "event=g7_ble_gatt_setup_timeout_armed timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleHardStopDate, fallback: G7BLEInstrumentation.gattSetupTimeoutSeconds)))"
            )
        }
    }

    private func scheduleFirstEgvTimeout() {
        firstEgvTimeoutWorkItem?.cancel()
        activeTimeoutStage = "awaiting_first_egv"
        let generation = currentCycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.currentCycleGeneration else { return }
            Task { @MainActor in
                await self.handleTimeout(stage: "awaiting_first_egv")
            }
        }
        firstEgvTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + cycleRelativeDelay(
                until: currentCycleGraceCloseDate,
                fallback: G7BLEInstrumentation.firstEgvTimeoutSeconds
            ),
            execute: work
        )
        Task {
            await logG7Ble(
                "event=g7_ble_first_egv_timeout_armed timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleGraceCloseDate, fallback: G7BLEInstrumentation.firstEgvTimeoutSeconds)))"
            )
        }
    }

    private func schedulePassiveObservationFallback() {
        passiveObservationFallbackWorkItem?.cancel()
        let generation = currentCycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.currentCycleGeneration else { return }
            Task { @MainActor in
                self.triggerFallbackEgvRequestIfNeeded(trigger: "passive_timeout")
            }
        }
        passiveObservationFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + cycleRelativeDelay(
                until: currentCycleFallbackDate,
                fallback: G7BLEInstrumentation.passiveObservationFallbackSeconds
            ),
            execute: work
        )
        Task {
            await logG7Ble(
                "event=g7_ble_passive_fallback_armed delay_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleFallbackDate, fallback: G7BLEInstrumentation.passiveObservationFallbackSeconds))) first_egv_timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleGraceCloseDate, fallback: G7BLEInstrumentation.firstEgvTimeoutSeconds)))"
            )
        }
    }

    @MainActor
    private func handleTimeout(stage: String) async {
        guard scanningStarted else { return }
        guard shouldEmitTimeout(stage: stage) else { return }
        switch stage {
        case "awaiting_connect":
            connectTimeoutWorkItem = nil
        case "awaiting_gatt_setup":
            gattSetupTimeoutWorkItem = nil
        case "awaiting_first_egv":
            firstEgvTimeoutWorkItem = nil
        default:
            break
        }
        activeTimeoutStage = nil
        lastTimedOutStage = stage
        setTerminalDebugState(outcome: "timeout", reason: "timeout_\(stage)", stage: stage)
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

        latestSessionEgvResponseReceived = true
        firstEgvTimeoutWorkItem?.cancel()
        firstEgvTimeoutWorkItem = nil
        passiveObservationFallbackWorkItem?.cancel()
        passiveObservationFallbackWorkItem = nil
        awaitingFirstEgv = false
        if activeTimeoutStage == "awaiting_first_egv" {
            activeTimeoutStage = nil
        }

        guard
            let txTime = data.readUInt32LE(offset: 2),
            let sequenceNumber = data.readUInt16LE(offset: 6),
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
        lastReadingDate = readingDate
        lastSuccessfulDirectBleReadingDate = readingDate
        if let existingSnapshotDate = latestComplicationSnapshotReadingDate {
            latestComplicationSnapshotReadingDate = max(existingSnapshotDate, readingDate)
        } else {
            latestComplicationSnapshotReadingDate = readingDate
        }
        lastSequenceNumber = Int(sequenceNumber)
        lastEgvReceivedAt = Date()
        lastGlucoseValue = glucose

        let glucoseField = glucose.map { String($0) } ?? "nil"
        let trendField = trendRate.map { String($0) } ?? "nil"
        let receivePath = fallbackEgvRequestSent ? "after_fallback_request" : "passive_before_fallback"
        Task {
            await logG7Ble(
                "event=g7_ble_egv_received glucose=\(glucoseField)"
                    + " trend=\(trendField)"
                    + " reading_epoch=\(readingEpoch)"
                    + " data_age_seconds=\(dataAgeSeconds)"
                    + " path=\(receivePath)"
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
        WatchState.shared.applyDirectBleSnapshot(snapshot)

        // Do not invalidate `WKExtendedRuntimeSession` here: product intent is to keep listening for subsequent
        // CGM samples and updating the complication store until `stop()` / teardown or the OS ends the session.

        Task {
            await logG7Ble("event=g7_ble_snapshot_saved glucose=\(glucose)")
            await logG7Ble("event=g7_ble_watch_state_updated glucose=\(glucose) reading_epoch=\(readingEpoch)")
        }
        latestSessionSnapshotSaved = true
        lastSnapshotSaveResult = "saved"
        lastSnapshotSaveAt = Date()

        let nextExpectedDate = rolledForwardExpectedDate(after: readingDate, now: Date())
        Task {
            await logG7Ble(
                "event=g7_ble_cycle_completed reading_epoch=\(readingEpoch) next_expected_epoch=\(Int(nextExpectedDate.timeIntervalSince1970))"
            )
        }
        refreshCadenceScheduler(trigger: "direct_ble_reading_saved", forceReschedule: true)
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

    private static func debugDisplayLabel(for rawValue: String) -> String {
        rawValue
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func humanizeDebugReason(_ rawValue: String) -> String {
        switch rawValue {
        case "snapshot_saved":
            return "Snapshot saved"
        case "startScanning_rescan":
            return "Rescan"
        case "stop_requested":
            return "Stop requested"
        case "discover_services":
            return "Service discovery"
        case "discover_characteristics":
            return "Characteristic discovery"
        case "no_data_service":
            return "No data service"
        default:
            let humanized = rawValue.replacingOccurrences(of: "_", with: " ")
            guard let first = humanized.first else { return rawValue }
            return first.uppercased() + humanized.dropFirst()
        }
    }

    private func errorLogFields(_ error: Error?) -> String {
        guard let error else {
            return "error_domain=none error_code=-1 error_desc=none"
        }
        let ns = error as NSError
        return "error_domain=\(ns.domain) error_code=\(ns.code) error_desc=\(ns.localizedDescription)"
    }

    private func characteristicLogName(for uuid: CBUUID) -> String {
        switch uuid {
        case G7BLEUUID.communication:
            return "communication"
        case G7BLEUUID.authentication:
            return "auth"
        case G7BLEUUID.control:
            return "control"
        case G7BLEUUID.backfill:
            return "backfill"
        case G7BLEUUID.jPake:
            return "jpake"
        default:
            return "unknown"
        }
    }

    private func missingRequiredCharacteristicSummary(
        authPresent: Bool,
        controlPresent: Bool
    ) -> String {
        var missing: [String] = []
        if !authPresent {
            missing.append("auth")
        }
        if !controlPresent {
            missing.append("control")
        }
        return missing.isEmpty ? "none" : missing.joined(separator: ",")
    }

    private func boundedServiceUUIDList(_ uuids: [CBUUID], maxCount: Int = 8) -> String {
        guard !uuids.isEmpty else { return "none" }
        let list = uuids.prefix(maxCount).map(\.uuidString)
        let suffix = uuids.count > maxCount ? ",more" : ""
        return list.joined(separator: ",") + suffix
    }

    private func boundedPeripheralShortList(_ identifiers: [UUID], maxCount: Int = 4) -> String {
        guard !identifiers.isEmpty else { return "none" }
        let shorts = identifiers.prefix(maxCount).map { identifier in
            let hex = identifier.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return String(hex.suffix(8))
        }
        let suffix = identifiers.count > maxCount ? ",more" : ""
        return shorts.joined(separator: ",") + suffix
    }

    private func doesPeripheralMatchActiveFilter(_ peripheral: CBPeripheral) -> Bool {
        guard let active = activePeripheralName else { return false }
        return (peripheral.name ?? "unknown") == active
    }

    private func isRetrievedAttachSource(_ source: String) -> Bool {
        source == "connection_event" || source.hasPrefix("retrieved_")
    }

    private func selectIdentifierRetrievedPeripheralForAttach(
        _ peripherals: [CBPeripheral]
    ) -> (peripheral: CBPeripheral, name: String, source: String)? {
        guard hasActivePeripheralNameFilter else { return nil }
        if let peripheral = peripherals.first(where: { doesPeripheralMatchActiveFilter($0) }),
           let name = peripheral.name
        {
            return (peripheral, name, "retrieved_identifier")
        }
        return nil
    }

    private func selectConnectedRetrievedPeripheralForAttach(
        _ peripherals: [CBPeripheral]
    ) -> (peripheral: CBPeripheral, name: String, source: String)? {
        guard hasActivePeripheralNameFilter else { return nil }
        if let peripheral = peripherals.first(where: { doesPeripheralMatchActiveFilter($0) }) {
            let name = peripheral.name ?? "unknown"
            return (peripheral, name, "retrieved_connected")
        }
        return nil
    }

    private func logIdentifierRetrievalDiagnostics(
        storedIdentifier: UUID?,
        peripherals: [CBPeripheral]
    ) {
        lastRetrievedIdentifierCount = peripherals.count
        lastPersistedPeripheralIdentifierShort = storedIdentifier.map {
            boundedPeripheralShortList([$0], maxCount: 1)
        }
        let storedIdShort = storedIdentifier.map { boundedPeripheralShortList([$0], maxCount: 1) } ?? "none"
        let firstPeripheral = peripherals.first
        let firstName = firstPeripheral?.name ?? "unknown"
        let firstState = firstPeripheral.map { Int($0.state.rawValue) } ?? -1
        let firstIdShort = firstPeripheral.map { peripheralIdShort($0) } ?? "none"
        Task {
            await logG7Ble(
                "event=g7_ble_retrieve_identifier_result stored_id_short=\(storedIdShort) count=\(peripherals.count) first_name=\(firstName) first_state=\(firstState) peripheral_id_short=\(firstIdShort)"
            )
        }
    }

    private func logConnectedRetrievalDiagnostics(
        event: String,
        peripherals: [CBPeripheral]
    ) {
        lastRetrievedConnectedCount = peripherals.count
        let firstPeripheral = peripherals.first
        let firstName = firstPeripheral?.name ?? "unknown"
        let firstState = firstPeripheral.map { Int($0.state.rawValue) } ?? -1
        let firstIdShort = firstPeripheral.map { peripheralIdShort($0) } ?? "none"
        Task {
            await logG7Ble(
                "event=\(event) retrieval_uuid=connected_services count=\(peripherals.count) matched_service_uuids=data_service,febc first_name=\(firstName) first_state=\(firstState) peripheral_id_short=\(firstIdShort)"
            )
        }
    }

    private func logConnectedRetrievedPeripheralSkipsIfNeeded(_ peripherals: [CBPeripheral]) {
        if !hasActivePeripheralNameFilter {
            if let retrieved = peripherals.first {
                let name = retrieved.name ?? "unknown"
                lastIdentifierRetrievalSkipReason = nil
                lastIdentifierRetrievalPeripheralName = nil
                setBlockerDebugState(
                    category: "attach",
                    source: "retrieved_connected",
                    reason: "missing_active_sensor_filter"
                )
                Task {
                    await logG7Ble(
                        "event=g7_ble_peripheral_skipped peripheral=\(name) reason=missing_active_sensor_filter source=retrieved_connected"
                    )
                }
            }
            return
        }
        if let retrieved = peripherals.first,
           !doesPeripheralMatchActiveFilter(retrieved)
        {
            let name = retrieved.name ?? "unknown"
            lastIdentifierRetrievalSkipReason = nil
            lastIdentifierRetrievalPeripheralName = nil
            setBlockerDebugState(
                category: "attach",
                source: "retrieved_connected",
                reason: "not_active_sensor"
            )
            Task {
                await logG7Ble(
                    "event=g7_ble_peripheral_skipped peripheral=\(name) reason=not_active_sensor source=retrieved_connected"
                )
            }
        }
    }

    @discardableResult
    private func beginRetrievedOrEventAttachIfEligible(
        _ peripheral: CBPeripheral,
        source: String,
        expectedCycleGeneration: Int
    ) -> Bool {
        guard scanningStarted else { return false }
        guard expectedCycleGeneration == currentCycleGeneration else {
            Task {
                await logG7Ble(
                    "event=g7_ble_attach_suppressed reason=stale_cycle_generation source=\(source) expected_generation=\(expectedCycleGeneration) current_generation=\(currentCycleGeneration)"
                )
            }
            return false
        }
        if emitAttachBlockedIfNeeded(source: source) {
            return false
        }
        let name = peripheral.name ?? "unknown"
        guard doesPeripheralMatchActiveFilter(peripheral) else {
            setBlockerDebugState(category: "attach", source: source, reason: "not_active_sensor")
            Task {
                await logG7Ble(
                    "event=g7_ble_peripheral_skipped peripheral=\(name) reason=not_active_sensor source=\(source)"
                )
            }
            return false
        }
        updateLastSeenPeripheral(name: name, rssi: nil)
        lastIdentifierRetrievalSkipReason = nil
        lastIdentifierRetrievalPeripheralName = nil
        if source.hasPrefix("retrieved_") {
            Task {
                await logG7Ble(
                    "event=g7_ble_retrieved_attach_selected peripheral=\(name) source=\(source)"
                )
            }
        }
        beginConnectToG7Peripheral(
            peripheral,
            name: name,
            rssi: 0,
            source: source,
            isConnectableAdvertisement: "unknown",
            discoverCountForTarget: discoverCountForActiveTarget
        )
        return true
    }

    @discardableResult
    private func attemptRetrievedAttachIfAvailable(
        central: CBCentralManager,
        retrievalEvent: String,
        blockedSource: String
    ) -> Bool {
        let expectedCycleGeneration = currentCycleGeneration
        let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: Self.connectedAttachServiceUUIDs)
        logConnectedRetrievalDiagnostics(
            event: retrievalEvent,
            peripherals: connectedPeripherals
        )

        _ = emitAttachBlockedIfNeeded(source: blockedSource)
        if let selected = selectConnectedRetrievedPeripheralForAttach(connectedPeripherals),
           beginRetrievedOrEventAttachIfEligible(
               selected.peripheral,
               source: selected.source,
               expectedCycleGeneration: expectedCycleGeneration
           )
        {
            return true
        }

        logConnectedRetrievedPeripheralSkipsIfNeeded(connectedPeripherals)

        let storedIdentifier = loadPersistedPeripheralIdentifier()
        let retrievedIdentifierPeripherals = retrievePeripheralsByIdentifierIfAvailable(central)
        logIdentifierRetrievalDiagnostics(
            storedIdentifier: storedIdentifier,
            peripherals: retrievedIdentifierPeripherals
        )
        if let selected = selectIdentifierRetrievedPeripheralForAttach(retrievedIdentifierPeripherals),
           beginRetrievedOrEventAttachIfEligible(
                selected.peripheral,
                source: selected.source,
                expectedCycleGeneration: expectedCycleGeneration
           )
        {
            return true
        }

        if let retrieved = retrievedIdentifierPeripherals.first {
            let name = retrieved.name ?? "unknown"
            let reason: String
            if !hasActivePeripheralNameFilter {
                reason = "missing_active_sensor_filter"
            } else if retrieved.name == nil {
                reason = "missing_name_for_exact_match"
            } else {
                reason = "not_active_sensor"
            }
            lastIdentifierRetrievalSkipReason = reason
            lastIdentifierRetrievalPeripheralName = name
            setBlockerDebugState(category: "attach", source: "retrieved_identifier", reason: reason)
            Task {
                await logG7Ble(
                    "event=g7_ble_peripheral_skipped peripheral=\(name) reason=\(reason) source=retrieved_identifier"
                )
            }
        }

        return false
    }

    private func setNotifyBlockedReasonIfNeeded(
        charName: String,
        reason: String,
        criticalOnly: Bool = true
    ) {
        if criticalOnly, charName != "auth" && charName != "control" {
            return
        }
        lastBlockedReason = "notify_failed (char=\(charName), reason=\(reason))"
        setBlockerDebugState(category: "gatt", source: lastAttachSource, reason: lastBlockedReason ?? reason)
    }

    // MARK: - Auth / subscribe / passive observation

    private func handleAuthenticationNotification(_ data: Data) {
        guard !data.isEmpty else { return }
        let opcode = data[0]
        lastAuthOpcodeSeen = opcode

        switch opcode {
        case 0x03:
            latestSessionSawAuthChallenge03 = true
            Task {
                await logG7Ble("event=g7_ble_auth_challenge_received opcode=0x03")
            }
        // Eavesdrop: do not respond to the challenge.
        case 0x05:
            let authenticated = data.count >= 2 && data[1] == 1
            let bonded = data.count >= 3 && data[2] == 1
            observerAuthenticated = authenticated
            observerBonded = bonded
            if authenticated {
                latestSessionAuthenticated = true
            }
            if bonded {
                latestSessionBonded = true
            }
            Task {
                await logG7Ble(
                    "event=g7_ble_status_reply authenticated=\(authenticated) bonded=\(bonded)"
                )
            }
            guard authenticated else {
                emitPassiveGateBlocked(authenticated: authenticated, bonded: bonded)
                emitPassiveObservationBlockedIfNeeded(reason: "authenticated_false")
                return
            }
            clearPassiveObservationBlockedReason(
                resolvedReasons: ["passive_gate_not_satisfied", "authenticated_false", "control_notify_not_enabled"]
            )
            guard let activePeripheral = self.peripheral else { return }
            passiveObservationGateSatisfied = true
            Task {
                await logG7Ble(
                    "event=g7_ble_passive_gate_satisfied gate=authenticated_only bonded=\(bonded)"
                )
            }
            requestCommunicationObservationIfNeeded(peripheral: activePeripheral)
            guard !controlNotificationsReady else {
                cancelGattSetupTimeoutWhenObserverReady()
                armPassiveObservationIfReady()
                return
            }
            if let control = controlCharacteristic {
                activePeripheral.setNotifyValue(true, for: control)
                emitPassiveObservationBlockedIfNeeded(reason: "control_notify_not_enabled")
            }
            cancelGattSetupTimeoutWhenObserverReady()
        default:
            break
        }
    }

    private func requestCommunicationObservationIfNeeded(peripheral: CBPeripheral) {
        guard let communication = communicationCharacteristic else { return }
        if !communicationNotificationsReady && !communication.isNotifying {
            peripheral.setNotifyValue(true, for: communication)
        }
        Task {
            await logG7Ble(
                "event=g7_ble_communication_observation_requested action=notify_only blocking=false"
            )
        }
    }

    private func armPassiveObservationIfReady(forceCycleRearm: Bool = false) {
        guard passiveObservationGateSatisfied else {
            if !observerAuthenticated {
                emitPassiveObservationBlockedIfNeeded(reason: "authenticated_false")
            } else {
                emitPassiveObservationBlockedIfNeeded(reason: "passive_gate_not_satisfied")
            }
            return
        }
        guard controlNotificationsReady else {
            emitPassiveObservationBlockedIfNeeded(reason: "control_notify_not_enabled")
            return
        }
        if passiveObservationArmed, !forceCycleRearm {
            return
        }
        if forceCycleRearm {
            resetObservationStateForCycleRearm()
        }
        clearPassiveObservationBlockedReason(
            resolvedReasons: [
                "passive_gate_not_satisfied",
                "authenticated_false",
                "control_notify_not_enabled"
            ]
        )
        passiveObservationArmed = true
        latestSessionPassiveObservationArmed = true
        awaitingFirstEgv = true
        emitStageIfChanged("awaiting_egv")
        // `firstEgvTimeout` is the total wait budget; the fallback timer only uses the tail end of that window.
        scheduleFirstEgvTimeout()
        schedulePassiveObservationFallback()
        Task {
            await logG7Ble(
                "event=g7_ble_passive_observation_armed gate=authenticated_only cycle_rearm=\(forceCycleRearm) fallback_delay_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleFallbackDate, fallback: G7BLEInstrumentation.passiveObservationFallbackSeconds))) first_egv_timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleGraceCloseDate, fallback: G7BLEInstrumentation.firstEgvTimeoutSeconds)))"
            )
        }
    }

    @MainActor
    private func triggerFallbackEgvRequestIfNeeded(trigger: String) {
        guard let cbPeripheral = peripheral, let control = controlCharacteristic else { return }
        guard passiveObservationArmed, awaitingFirstEgv, controlNotificationsReady else { return }
        guard !fallbackEgvRequestSent else { return }
        fallbackEgvRequestSent = true
        latestSessionFallbackEgvRequestSent = true
        pendingControlWriteLogKind = "egv_fallback_request"
        Task {
            await logG7Ble(
                "event=g7_ble_egv_fallback_sent opcode=0x4E trigger=\(trigger) timeout_s=\(loggedSeconds(cycleRelativeDelay(until: currentCycleFallbackDate, fallback: G7BLEInstrumentation.passiveObservationFallbackSeconds)))"
            )
        }
        cbPeripheral.writeValue(Data([0x4E]), for: control, type: .withResponse)
    }

    /// Last 8 hex digits of the peripheral UUID (no dashes) — bounded correlation without full UUID spam.
    private func peripheralIdShort(_ peripheral: CBPeripheral) -> String {
        let hex = peripheral.identifier.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.suffix(8))
    }

    private func identifierDefaults() -> UserDefaults? {
        guard let suiteName = TrioComplicationDataStore.shared.appGroupID else { return nil }
        return UserDefaults(suiteName: suiteName)
    }

    private func loadPersistedPeripheralIdentifier() -> UUID? {
        guard let defaults = identifierDefaults(),
              let rawValue = defaults.string(forKey: Self.activePeripheralIdentifierAppGroupKey)
        else {
            return nil
        }
        guard let identifier = UUID(uuidString: rawValue) else {
            clearPersistedPeripheralIdentifier(reason: "invalid_uuid")
            return nil
        }
        return identifier
    }

    private func persistPeripheralIdentifier(_ identifier: UUID, reason: String) {
        guard let defaults = identifierDefaults() else { return }
        defaults.set(identifier.uuidString, forKey: Self.activePeripheralIdentifierAppGroupKey)
        let idShort = boundedPeripheralShortList([identifier], maxCount: 1)
        lastPersistedPeripheralIdentifierShort = idShort
        Task {
            await logG7Ble(
                "event=g7_ble_identifier_persisted peripheral_id_short=\(idShort) reason=\(reason)"
            )
        }
    }

    private func clearPersistedPeripheralIdentifier(reason: String) {
        guard let defaults = identifierDefaults(),
              let rawValue = defaults.string(forKey: Self.activePeripheralIdentifierAppGroupKey)
        else {
            return
        }
        defaults.removeObject(forKey: Self.activePeripheralIdentifierAppGroupKey)
        let idShort = UUID(uuidString: rawValue).map { boundedPeripheralShortList([$0], maxCount: 1) } ?? "none"
        lastPersistedPeripheralIdentifierShort = nil
        Task {
            await logG7Ble(
                "event=g7_ble_identifier_cleared peripheral_id_short=\(idShort) reason=\(reason)"
            )
        }
    }

    private func retrievePeripheralsByIdentifierIfAvailable(_ central: CBCentralManager) -> [CBPeripheral] {
        guard let identifier = loadPersistedPeripheralIdentifier() else { return [] }
        return central.retrievePeripherals(withIdentifiers: [identifier])
    }

    /// `CBAdvertisementDataIsConnectable` when present; otherwise `unknown` (for `g7_ble_pre_connect` `is_connectable=`).
    private func isConnectableFromAdvertisement(_ advertisementData: [String: Any]) -> String {
        guard let n = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber else {
            return "unknown"
        }
        return n.boolValue ? "true" : "false"
    }

    /// Shared path for advertisement discovery, connected-peripheral retrieval, and connection-event attach.
    private func beginConnectToG7Peripheral(
        _ peripheral: CBPeripheral,
        name: String,
        rssi: Int,
        source: String?,
        isConnectableAdvertisement: String,
        discoverCountForTarget: Int
    ) {
        if attemptedConnectPeripheralIdentifiers.contains(peripheral.identifier) {
            let idShort = peripheralIdShort(peripheral)
            Task {
                await logG7Ble(
                    "event=g7_ble_connect_suppressed reason=duplicate_peripheral_in_attach_cycle source=\(source ?? "scan") peripheral=\(name) peripheral_id_short=\(idShort)"
                )
            }
            return
        }
        attemptedConnectPeripheralIdentifiers.insert(peripheral.identifier)
        let idShort = peripheralIdShort(peripheral)
        // central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        let now = Date()
        discoverWallClock = now
        lastSeenPeripheralName = name
        lastSeenPeripheralRSSI = rssi
        lastSeenPeripheralAt = now
        lastAttachSource = source ?? "scan"
        emitStageIfChanged("connecting")
        Task {
            if let source {
                await logG7Ble(
                    "event=g7_ble_peripheral_discovered peripheral=\(name) rssi=\(rssi) source=\(source) peripheral_id_short=\(idShort)"
                )
                await logG7Ble(
                    "event=g7_ble_connect_attempt peripheral=\(name) source=\(source) peripheral_id_short=\(idShort)"
                )
            } else {
                await logG7Ble(
                    "event=g7_ble_peripheral_discovered peripheral=\(name) rssi=\(rssi) peripheral_id_short=\(idShort)"
                )
                await logG7Ble("event=g7_ble_connect_attempt peripheral=\(name) peripheral_id_short=\(idShort)")
            }
        }
        let firstAttempt = connectAttemptsSinceStartScanning == 0
        connectAttemptsSinceStartScanning += 1
        let preConnectSource = source ?? "scan"
        let peripheralState = peripheral.state.rawValue
        let centralState = central?.state.rawValue ?? -1
        let preserved = sessionPreservedAcrossForegroundReentry
        let cbCentralAllocatedInStartScanning = centralManagerAllocatedInLastStartScanning
        let preConnectSane = (
            peripheralState == CBPeripheralState.disconnected.rawValue
                || (isRetrievedAttachSource(preConnectSource)
                    && peripheralState == CBPeripheralState.connected.rawValue)
        )
            && centralState == CBManagerState.poweredOn.rawValue
            && isConnectableAdvertisement != "false"
        lastPreConnectPeripheralState = peripheralState
        lastPreConnectCentralState = centralState
        lastPreConnectIsConnectable = isConnectableAdvertisement
        lastPreConnectPreservedSession = preserved
        lastPreConnectAllocatedCentralInStartScanning = cbCentralAllocatedInStartScanning
        noteLatestSessionFilterArmedIfNeeded(hasActivePeripheralNameFilter)
        latestSessionTargetMatched = true
        latestSessionPreConnectSane = preConnectSane
        latestSessionConnectAttempted = true
        Task {
            await logG7Ble(
                "event=g7_ble_pre_connect peripheral_state=\(peripheralState) central_state=\(centralState) source=\(preConnectSource) first_attempt=\(firstAttempt) preserved_session=\(preserved) is_connectable=\(isConnectableAdvertisement) discover_count_for_target=\(discoverCountForTarget) peripheral_id_short=\(idShort) cbcentral_allocated_in_start_scanning=\(cbCentralAllocatedInStartScanning)"
            )
        }
        central?.connect(peripheral, options: nil)
        scheduleConnectTimeout()
    }
}

// MARK: - CBCentralManagerDelegate

extension G7DirectBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard scanningStarted, central.state == .poweredOn else { return }
        guard connectionState == .scanning else { return }
        central.stopScan()

        // Phase H: prefer a live system-connected peripheral before falling back to identifier retrieval or scan,
        // but keep connection events and FEBC scan running in parallel for the same cycle.
        _ = attemptRetrievedAttachIfAvailable(
            central: central,
            retrievalEvent: "g7_ble_retrieve_on_powered_on",
            blockedSource: "powered_on_retrieve"
        )

        registerForConnectionEventsIfNeeded(on: central)
        central.scanForPeripherals(
            withServices: [G7BLEUUID.advertisement],
            options: nil
        )
        guard !loggedScanStartThisRequest else { return }
        loggedScanStartThisRequest = true
        Task {
            await logG7Ble("event=g7_ble_scan_started")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let keys = dict.keys.sorted().joined(separator: ",")
        Task {
            await logG7Ble("event=g7_ble_will_restore_state keys=\(keys)")
        }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        guard scanningStarted, central.state == .poweredOn else { return }
        guard event == .peerConnected else { return }
        let expectedCycleGeneration = currentCycleGeneration
        let name = peripheral.name ?? "unknown"
        let idShort = peripheralIdShort(peripheral)
        let alreadyAttempted = attemptedConnectPeripheralIdentifiers.contains(peripheral.identifier)
        Task {
            await logG7Ble(
                "event=g7_ble_connection_event_fired peripheral=\(name) peripheral_id_short=\(idShort) source=connection_event already_attempted=\(alreadyAttempted)"
            )
        }
        _ = beginRetrievedOrEventAttachIfEligible(
            peripheral,
            source: "connection_event",
            expectedCycleGeneration: expectedCycleGeneration
        )
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard scanningStarted else { return }
        let name = peripheral.name ?? "unknown"
        updateLastSeenPeripheral(name: name, rssi: rssi.intValue)
        guard hasActivePeripheralNameFilter else {
            _ = emitAttachBlockedIfNeeded(source: "did_discover")
            return
        }
        if let active = activePeripheralName, name != active {
            Task {
                await logG7Ble("event=g7_ble_peripheral_skipped peripheral=\(name) reason=not_active_sensor")
            }
            return
        }

        discoverCountForActiveTarget += 1
        let isConn = isConnectableFromAdvertisement(advertisementData)
        // TODO: validate WKExtendedRuntimeSession honored for BLE-connect use case on device
        beginConnectToG7Peripheral(
            peripheral,
            name: name,
            rssi: rssi.intValue,
            source: "scan",
            isConnectableAdvertisement: isConn,
            discoverCountForTarget: discoverCountForActiveTarget
        )
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        persistPeripheralIdentifier(peripheral.identifier, reason: "did_connect")
        let canceledConnectTimeout = cancelConnectTimeoutIfNeeded()
        gattSetupTimeoutWorkItem?.cancel()
        gattSetupTimeoutWorkItem = nil
        scheduleGattSetupTimeout()
        latestSessionDidConnect = true
        emitStageIfChanged("discovering_services")
        let name = peripheral.name ?? "unknown"
        let idShort = peripheralIdShort(peripheral)
        let cachedServices = peripheral.services
        let servicesCached = cachedServices != nil
        let cachedServiceCount = cachedServices?.count ?? 0
        let cachedHasDataService = cachedServices?.contains(where: { $0.uuid == G7BLEUUID.dataService }) ?? false
        let msDiscover: Int?
        if let t0 = discoverWallClock {
            msDiscover = Int(Date().timeIntervalSince(t0) * 1000.0)
        } else {
            msDiscover = nil
        }
        let msField = msDiscover.map { " ms_since_discover=\($0)" } ?? ""
        Task {
            await logG7Ble(
                "event=g7_ble_did_connect peripheral=\(name) peripheral_id_short=\(idShort) services_cached=\(servicesCached) cached_service_count=\(cachedServiceCount) cached_has_data_service=\(cachedHasDataService)"
            )
            if canceledConnectTimeout {
                await logG7Ble("event=g7_ble_connect_timeout_canceled reason=did_connect")
            }
            await logG7Ble("event=g7_ble_connected peripheral=\(name)\(msField)")
        }
        peripheral.discoverServices([G7BLEUUID.dataService])
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let canceledConnectTimeout = cancelConnectTimeoutIfNeeded()
        let name = peripheral.name ?? "unknown"
        let idShort = peripheralIdShort(peripheral)
        if let err = error {
            let ns = err as NSError
            Task {
                await logG7Ble(
                    "event=g7_ble_did_fail_to_connect peripheral=\(name) peripheral_id_short=\(idShort) error_domain=\(ns.domain) error_code=\(ns.code) error_desc=\(ns.localizedDescription)"
                )
                if canceledConnectTimeout {
                    await logG7Ble("event=g7_ble_connect_timeout_canceled reason=did_fail_to_connect")
                }
                await logG7Ble(
                    "event=g7_ble_connect_failed peripheral=\(name) error_domain=\(ns.domain) error_code=\(ns.code) error_desc=\(ns.localizedDescription)"
                )
            }
        } else {
            Task {
                await logG7Ble(
                    "event=g7_ble_did_fail_to_connect peripheral=\(name) peripheral_id_short=\(idShort) error_domain=none error_code=-1 error_desc=none"
                )
                if canceledConnectTimeout {
                    await logG7Ble("event=g7_ble_connect_timeout_canceled reason=did_fail_to_connect")
                }
                await logG7Ble(
                    "event=g7_ble_connect_failed peripheral=\(name) error_domain=none error_code=-1 error_desc=none"
                )
            }
        }
        teardownSession(reason: "connect_failed", isFailure: true)
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let override = pendingDisconnectReason
        pendingDisconnectReason = nil
        let cancelReason = override == "stop_requested" ? "stop_requested" : "teardown"
        let canceledConnectTimeout = cancelConnectTimeoutIfNeeded()
        // Intentional cancel before a new scan — `startScanning` already reset state; skip teardown + reconnect scheduling.
        // Intentionally does not emit `g7_ble_session_outcome`: the session id is reset at the top of the next
        // `startScanning()`; correlating outcome lines to rescans would duplicate or confuse metrics.
        let reason = override ?? (error?.localizedDescription ?? "disconnected")
        let name = peripheral.name ?? lastSeenPeripheralName ?? "unknown"
        let idShort = peripheralIdShort(peripheral)
        let isFailure: Bool
        if override == "stop_requested" {
            isFailure = false
        } else if error != nil {
            isFailure = true
        } else {
            isFailure = false
        }
        if let err = error {
            let ns = err as NSError
            Task {
                await logG7Ble(
                    "event=g7_ble_did_disconnect peripheral=\(name) peripheral_id_short=\(idShort) reason=\(reason) error_domain=\(ns.domain) error_code=\(ns.code) error_desc=\(ns.localizedDescription)"
                )
                if canceledConnectTimeout {
                    await logG7Ble("event=g7_ble_connect_timeout_canceled reason=\(cancelReason)")
                }
                await logG7Ble("event=g7_ble_error error=\(reason)")
            }
        } else {
            Task {
                await logG7Ble(
                    "event=g7_ble_did_disconnect peripheral=\(name) peripheral_id_short=\(idShort) reason=\(reason) error_domain=none error_code=-1 error_desc=none"
                )
                if canceledConnectTimeout {
                    await logG7Ble("event=g7_ble_connect_timeout_canceled reason=\(cancelReason)")
                }
            }
        }
        if override == "startScanning_rescan" {
            invalidateExtendedSession(reason: "startScanning_rescan")
            return
        }
        teardownSession(reason: reason, isFailure: isFailure)
    }
}

// MARK: - CBPeripheralDelegate

extension G7DirectBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let serviceCount = services.count
        let hasDataService = services.contains(where: { $0.uuid == G7BLEUUID.dataService })
        let serviceUUIDs = boundedServiceUUIDList(services.map(\.uuid))
        let errorFields = errorLogFields(error)
        if error == nil {
            latestSessionServicesDiscovered = true
        }
        Task {
            await logG7Ble(
                "event=g7_ble_did_discover_services_entered service_count=\(serviceCount) has_data_service=\(hasDataService) service_uuids=\(serviceUUIDs) \(errorFields)"
            )
        }
        if let error {
            lastBlockedReason = "service_discovery_failed"
            setBlockerDebugState(category: "gatt", source: lastAttachSource, reason: "service_discovery_failed")
            Task {
                await logG7Ble(
                    "event=g7_ble_services_discovery_failed service_count=\(serviceCount) has_data_service=\(hasDataService) service_uuids=\(serviceUUIDs) \(errorFields)"
                )
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "discover_services")
            return
        }
        guard let svc = services.first(where: { $0.uuid == G7BLEUUID.dataService }) else {
            lastBlockedReason = "no_data_service"
            setBlockerDebugState(category: "gatt", source: lastAttachSource, reason: "no_data_service")
            Task {
                await logG7Ble(
                    "event=g7_ble_services_discovery_failed service_count=\(serviceCount) has_data_service=false service_uuids=\(serviceUUIDs) \(errorFields)"
                )
                await logG7Ble("event=g7_ble_error error=data_service_missing")
            }
            teardownSession(reason: "no_data_service")
            return
        }
        dataService = svc
        Task {
            await logG7Ble(
                "event=g7_ble_services_discovered service_count=\(serviceCount) has_data_service=true service_uuids=\(serviceUUIDs)"
            )
        }
        emitStageIfChanged("discovering_characteristics")
        peripheral.discoverCharacteristics(
            [
                G7BLEUUID.communication,
                G7BLEUUID.authentication,
                G7BLEUUID.control,
                G7BLEUUID.backfill,
                G7BLEUUID.jPake
            ],
            for: svc
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        let characteristicCount = characteristics.count
        let communicationPresent = characteristics.contains(where: { $0.uuid == G7BLEUUID.communication })
        let authPresent = characteristics.contains(where: { $0.uuid == G7BLEUUID.authentication })
        let controlPresent = characteristics.contains(where: { $0.uuid == G7BLEUUID.control })
        let backfillPresent = characteristics.contains(where: { $0.uuid == G7BLEUUID.backfill })
        let jpakePresent = characteristics.contains(where: { $0.uuid == G7BLEUUID.jPake })
        let missingRequired = missingRequiredCharacteristicSummary(
            authPresent: authPresent,
            controlPresent: controlPresent
        )
        let errorFields = errorLogFields(error)
        if error == nil {
            latestSessionCharacteristicsCallbackReturned = true
        }
        Task {
            await logG7Ble(
                "event=g7_ble_did_discover_characteristics_entered service_uuid=\(service.uuid.uuidString) characteristic_count=\(characteristicCount) communication_present=\(communicationPresent) auth_present=\(authPresent) control_present=\(controlPresent) backfill_present=\(backfillPresent) jpake_present=\(jpakePresent) missing=\(missingRequired) \(errorFields)"
            )
        }
        if let error {
            lastBlockedReason = "characteristic_discovery_failed"
            setBlockerDebugState(category: "gatt", source: lastAttachSource, reason: "characteristic_discovery_failed")
            Task {
                await logG7Ble(
                    "event=g7_ble_characteristics_discovery_failed service_uuid=\(service.uuid.uuidString) characteristic_count=\(characteristicCount) communication_present=\(communicationPresent) auth_present=\(authPresent) control_present=\(controlPresent) backfill_present=\(backfillPresent) jpake_present=\(jpakePresent) missing=\(missingRequired) \(errorFields)"
                )
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "discover_characteristics")
            return
        }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case G7BLEUUID.communication:
                communicationCharacteristic = characteristic
            case G7BLEUUID.authentication:
                authenticationCharacteristic = characteristic
            case G7BLEUUID.control:
                controlCharacteristic = characteristic
            case G7BLEUUID.backfill:
                backfillCharacteristic = characteristic
            case G7BLEUUID.jPake:
                jPakeCharacteristic = characteristic
            default:
                break
            }
        }

        guard authenticationCharacteristic != nil,
              controlCharacteristic != nil
        else {
            lastBlockedReason = "no_required_characteristic (missing=\(missingRequired))"
            setBlockerDebugState(
                category: "gatt",
                source: lastAttachSource,
                reason: lastBlockedReason ?? "no_required_characteristic"
            )
            Task {
                await logG7Ble(
                    "event=g7_ble_characteristics_incomplete service_uuid=\(service.uuid.uuidString) characteristic_count=\(characteristicCount) communication_present=\(communicationPresent) auth_present=\(authPresent) control_present=\(controlPresent) backfill_present=\(backfillPresent) jpake_present=\(jpakePresent) missing=\(missingRequired)"
                )
                await logG7Ble("event=g7_ble_error error=characteristics_incomplete")
            }
            teardownSession(reason: "characteristics_incomplete")
            return
        }

        latestSessionRequiredCharacteristicsPresent = true
        Task {
            await logG7Ble(
                "event=g7_ble_characteristics_discovered service_uuid=\(service.uuid.uuidString) characteristic_count=\(characteristicCount) communication_present=\(communicationPresent) auth_present=\(authPresent) control_present=\(controlPresent) backfill_present=\(backfillPresent) jpake_present=\(jpakePresent) missing=none"
            )
        }
        jpakeSkippedInObserver = true
        latestSessionJpakeSkipped = true
        Task {
            await logG7Ble(
                "event=g7_ble_jpake_skipped mode=observer available=\(jPakeCharacteristic != nil)"
            )
        }

        if let auth = authenticationCharacteristic {
            peripheral.setNotifyValue(true, for: auth)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let charName = characteristicLogName(for: characteristic.uuid)
        let errorFields = errorLogFields(error)
        Task {
            await logG7Ble(
                "event=g7_ble_did_update_notification_state_entered char=\(charName) notifying=\(characteristic.isNotifying) \(errorFields)"
            )
        }
        if let error {
            if characteristic.uuid == G7BLEUUID.communication {
                // Communication is optional observer context, not part of the passive-ready gate.
                Task {
                    await logG7Ble(
                        "event=g7_ble_communication_notify_state notifying=\(characteristic.isNotifying) success=false blocking=false \(errorFields)"
                    )
                }
                return
            }
            setNotifyBlockedReasonIfNeeded(charName: charName, reason: "error", criticalOnly: false)
            Task {
                await logG7Ble(
                    "event=g7_ble_notify_state char=\(charName) notifying=\(characteristic.isNotifying) success=false \(errorFields)"
                )
                await logG7Ble("event=g7_ble_error error=\(error.localizedDescription)")
            }
            teardownSession(reason: "notification_state")
            return
        }

        Task {
            if characteristic.uuid == G7BLEUUID.communication {
                await logG7Ble(
                    "event=g7_ble_communication_notify_state notifying=\(characteristic.isNotifying) success=\(characteristic.isNotifying) blocking=false \(errorFields)"
                )
            } else {
                await logG7Ble(
                    "event=g7_ble_notify_state char=\(charName) notifying=\(characteristic.isNotifying) success=\(characteristic.isNotifying) \(errorFields)"
                )
            }
        }
        guard characteristic.isNotifying else {
            if characteristic.uuid == G7BLEUUID.communication {
                return
            }
            setNotifyBlockedReasonIfNeeded(charName: charName, reason: "notifying_false")
            return
        }

        switch characteristic.uuid {
        case G7BLEUUID.communication:
            clearBlockedReasonIfResolved("notify_failed_communication")
            communicationNotificationsReady = true
            latestSessionCommunicationNotifyEnabled = true
            Task {
                await logG7Ble("event=g7_ble_communication_notify_enabled blocking=false")
            }
        case G7BLEUUID.authentication:
            clearBlockedReasonIfResolved("notify_failed_auth")
            authNotificationsReady = true
            latestSessionAuthNotifyEnabled = true
            connectionState = .authenticating
            emitStageIfChanged("authenticating")
            Task {
                await logG7Ble("event=g7_ble_auth_notify_enabled")
            }
        case G7BLEUUID.control:
            clearBlockedReasonIfResolved("notify_failed_control")
            controlNotificationsReady = true
            latestSessionControlNotifyEnabled = true
            clearPassiveObservationBlockedReason(resolvedReason: "control_notify_not_enabled")
            connectionState = .connected
            Task {
                await logG7Ble("event=g7_ble_control_notify_enabled")
            }
            cancelGattSetupTimeoutWhenObserverReady()
            armPassiveObservationIfReady()
        case G7BLEUUID.backfill:
            break
        case G7BLEUUID.jPake:
            break
        default:
            break
        }

        cancelGattSetupTimeoutWhenObserverReady()
    }

    /// Clears `awaiting_gatt_setup` once the passive observer path is startup-ready:
    /// auth notifications enabled, `0x05 authenticated=true`, and control notifications enabled.
    private func cancelGattSetupTimeoutWhenObserverReady() {
        guard authNotificationsReady, passiveObservationGateSatisfied, controlNotificationsReady else { return }
        _ = cancelGattSetupTimeoutIfNeeded(reason: "observer_ready")
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
        case G7BLEUUID.communication:
            Task {
                await logG7Ble(
                    "event=g7_ble_communication_value_received len=\(data.count)"
                )
            }
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
            let writeKind = pendingControlWriteLogKind ?? "control_write"
            if characteristic.uuid == G7BLEUUID.control {
                pendingControlWriteLogKind = nil
            }
            Task {
                await logG7Ble(
                    "event=g7_ble_write_error_nonfatal char=\(characteristicLogName(for: characteristic.uuid)) write=\(writeKind) error=\(error.localizedDescription)"
                )
            }
            return
        }
        switch characteristic.uuid {
        case G7BLEUUID.control:
            let writeKind = pendingControlWriteLogKind ?? "control_write"
            pendingControlWriteLogKind = nil
            Task {
                await logG7Ble("event=g7_ble_write_ok char=control write=\(writeKind)")
            }
        default:
            break
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension G7DirectBLEManager: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let ext = self.extendedSession, ext === session else { return }
            self.runtimeState = .active
            self.cycleRuntimeActivationWorkItem?.cancel()
            self.cycleRuntimeActivationWorkItem = nil
            await self.logG7Ble("event=g7_ble_ext_session_started")
            self.resumeCurrentCycleAfterRuntimeActivation(trigger: "ext_session_started")
        }
    }

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard let ext = extendedSession, ext === session else { return }
            runtimeState = .expiring
            await logG7Ble("event=g7_ble_ext_session_expiring action=await_invalidation")
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
                self.runtimeState = .invalidated
            }
            self.cycleRuntimeActivationWorkItem?.cancel()
            self.cycleRuntimeActivationWorkItem = nil
            let errDesc = error.map { $0.localizedDescription } ?? "none"
            await self.logG7Ble(
                "event=g7_ble_ext_session_invalidated reason=\(String(describing: reason)) error=\(errDesc)"
            )
            guard reason == .error, isCurrentSession else { return }
            guard let leadWindowDate = self.currentCycleLeadWindowDate,
                  let expectedReadingDate = self.currentCycleExpectedReadingDate
            else {
                if self.scanningStarted, self.peripheral != nil {
                    self.teardownSession(reason: "ext_session_invalidated", isFailure: true)
                }
                return
            }

            if Date() < leadWindowDate,
               self.currentCycleGraceCloseDate?.timeIntervalSinceNow ?? 0 > Self.minimumRetryRemainingSeconds
            {
                // Phase G same-cycle runtime reacquire is intentionally foreground-only.
                // `ensureRuntimeForCurrentCycle` will refuse to start a new runtime
                // session once the app has already left active UI.
                await self.logG7Ble(
                    "event=g7_ble_runtime_gate trigger=runtime_invalidated state=reacquire_same_cycle expected_epoch=\(Int(expectedReadingDate.timeIntervalSince1970))"
                )
                switch self.ensureRuntimeForCurrentCycle(trigger: "runtime_invalidated", expectedReadingDate: expectedReadingDate) {
                case .active, .starting:
                    return
                case .unavailable:
                    break
                }
            }

            if self.scanningStarted || self.peripheral != nil {
                self.teardownSession(reason: "ext_session_invalidated", isFailure: true)
            }
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

private extension G7DirectBLEManager {
    func setActivePeripheralName(_ activePeripheralName: String?, logIfChanged: Bool) -> Bool {
        let normalized = Self.normalizedPeripheralName(activePeripheralName)
        let previous = self.activePeripheralName
        let changed = previous != normalized
        if let previous, previous != normalized {
            let reason = normalized == nil ? "active_name_removed" : "active_name_changed"
            clearPersistedPeripheralIdentifier(reason: reason)
        }
        self.activePeripheralName = normalized
        noteLatestSessionFilterArmedIfNeeded(normalized != nil)
        guard changed, logIfChanged else { return changed }
        let filtered = normalized != nil
        Task {
            await logG7Ble("event=g7_ble_active_name_applied filtered=\(filtered)")
        }
        return changed
    }

    static func normalizedPeripheralName(_ activePeripheralName: String?) -> String? {
        let trimmed = activePeripheralName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func updateLastSeenPeripheral(name: String, rssi: Int?) {
        lastSeenPeripheralName = name
        lastSeenPeripheralRSSI = rssi
        lastSeenPeripheralAt = Date()
    }

    @discardableResult
    func emitAttachBlockedIfNeeded(source: String) -> Bool {
        guard !hasActivePeripheralNameFilter else { return false }
        lastBlockedReason = "missing_active_sensor_filter"
        setBlockerDebugState(category: "attach", source: source, reason: "missing_active_sensor_filter")
        return emitBlockedStateIfNeeded(
            key: "attach:missing_active_sensor_filter:\(source)",
            message: "event=g7_ble_attach_blocked reason=missing_active_sensor_filter source=\(source)"
        )
    }

    func emitPassiveGateBlocked(authenticated: Bool, bonded: Bool) {
        if !authenticated {
            lastBlockedReason = "authenticated_false"
        } else {
            lastBlockedReason = "passive_gate_not_satisfied (auth=\(authenticated), bond=\(bonded))"
        }
        setBlockerDebugState(
            category: "auth",
            source: lastAttachSource,
            reason: lastBlockedReason ?? "passive_gate_not_satisfied"
        )
        _ = emitBlockedStateIfNeeded(
            key: "passive_gate:\(authenticated):\(bonded)",
            message:
            "event=g7_ble_passive_gate_blocked authenticated=\(authenticated) bonded=\(bonded) gate=authenticated_only"
        )
    }

    func emitPassiveObservationBlockedIfNeeded(reason: String) {
        lastPassiveObservationBlockedReason = reason
        if !((reason == "passive_gate_not_satisfied"
            && (lastBlockedReason?.hasPrefix("passive_gate_not_satisfied") ?? false))
            || (reason == "authenticated_false" && lastBlockedReason == "authenticated_false")
            || (reason == "control_notify_not_enabled" && lastBlockedReason == "control_notify_not_enabled"))
        {
            lastBlockedReason = reason
        }
        setBlockerDebugState(category: "observation", source: lastAttachSource, reason: reason)
        _ = emitBlockedStateIfNeeded(
            key: "passive_observation:\(reason)",
            message: "event=g7_ble_passive_observation_blocked reason=\(reason)"
        )
    }

    @discardableResult
    func emitBlockedStateIfNeeded(key: String, message: String) -> Bool {
        guard !blockedStateEmittedKeys.contains(key) else { return false }
        blockedStateEmittedKeys.insert(key)
        Task {
            await logG7Ble(message)
        }
        return true
    }
}
