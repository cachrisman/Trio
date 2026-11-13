import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

// MARK: - BackgroundTaskWindowCounter (Phase 2.2)

/// In-memory monotonic counter for correlating WKWatchConnectivityRefreshBackgroundTask wake windows with didReceiveUserInfo.
/// Watch app extension only; used by handleBackgroundTasks and WCSession delegate.
enum BackgroundTaskWindowCounter {
    private static let lock = NSLock()
    private static var lastWindowId = 0
    private static var lastReceivedAt: Date?

    /// Advance counter, record time, return (windowId, receivedAt). Thread-safe.
    static func next() -> (windowId: Int, receivedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastWindowId += 1
        let receivedAt = Date()
        lastReceivedAt = receivedAt
        return (lastWindowId, receivedAt)
    }

    /// Current window id only if last received was within 30s; else nil. Thread-safe.
    static func currentOrNil() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let at = lastReceivedAt else { return nil }
        return Date().timeIntervalSince(at) <= 30 ? lastWindowId : nil
    }
}

// Aligned with build 191 state machine (item 12).
// .stalled removed (was never called). .searching renamed .scanning.
// .fastRetry / .moderateWait added for scheduler states (wired in future build).
/// C-210-4: cross-source direct-BLE stall tier for the watch face. Distinct from `G7DirectBLEStatus`
/// (which reflects the BLE *engine* state); this reflects *freshness* — the direct EGV path is stale
/// while the phone path is fresh (so the complication is silently riding the phone relay).
enum DirectBleStallTier: String, Equatable {
    case none // direct path fresh (or not enough info)
    case stalled // soft: direct stale > ~12 min while phone fresh
    case unavailable // hard: direct stale > ~30 min while phone fresh
}

enum G7DirectBLEStatus: String, Equatable {
    case off // IDLE: no active session or timer
    case waiting // WAITING: armed between G7 advertisements; no active scan/connection (also the fork's post-disconnect settle and a C1-deferred-in-background scan). Renamed from `retrieving` (UI-207-2) — it almost never meant "checking OS peripheral cache".
    case scanning // SCANNING: active BLE scan; no cached peripheral found
    case connecting // CONNECTING: centralManager.connect() in flight
    case active // WINDOW_ACTIVE: inside a live sensor session
    case fastRetry // FAST_RETRY: 2s fixed delay after failure/post-success disconnect
    case moderateWait // MODERATE_WAIT: 15s delay after 5 consecutive scheduler retries
    case unavailable // Bluetooth off / unauthorized

    var badgeText: String {
        switch self {
        case .off: return "off"
        case .waiting: return "wait"
        case .scanning: return "scan"
        case .connecting: return "conn"
        case .active: return "ok"
        case .fastRetry: return "retry"
        case .moderateWait: return "wait"
        case .unavailable: return "n/a"
        }
    }

    var shortLabel: String { badgeText }
}

extension TrioComplicationDataSource {
    var watchBadgeText: String {
        switch self {
        case .watchConnectivity: return "Phone"
        case .healthKit: return "HK"
        case .g7DirectBLE: return "BLE"
        case .unknown: return "?"
        }
    }
}

/// WatchState manages the communication between the Watch app and the iPhone app using WatchConnectivity.
/// It handles glucose data synchronization and sending treatment requests (bolus, carbs) to the phone,
/// and owns the watch-side G7 direct-BLE, HealthKit fallback and complication pipelines.
@Observable final class WatchState: NSObject, WCSessionDelegate {
    static let shared = WatchState()

    // MARK: - WatchConnectivity

    /// The WatchConnectivity session instance used for communication
    var session: WCSession?
    /// Indicates if the paired iPhone is currently reachable
    var isReachable = false
    var lastWatchStateUpdate: Date?

    // MARK: - Main view metrics

    var currentGlucose: String = "--"
    /// Local bubble-hex store (build 205 / P2 + W5). Computed on-watch from `currentGlucoseMgDl` +
    /// cached color settings, not received from the phone. Defaults to white so "no data" never bakes red.
    var currentGlucoseColorString: String = "#ffffff"
    /// Canonical mg/dL of the current reading (build 205 / P2); `nil` when missing/invalid (< 25).
    var currentGlucoseMgDl: Int?
    var trend: String? = ""
    var delta: String? = "--"
    var glucoseValues: [(date: Date, glucose: Double, color: Color)] = []
    var minYAxisValue: Decimal = 39
    var maxYAxisValue: Decimal = 200
    var cob: String? = "--"
    var iob: String? = "--"
    var lastLoopTime: String? = "--"
    var displayedReadingSource: TrioComplicationDataSource = .unknown
    var g7DirectBleStatus: G7DirectBLEStatus = .off
    /// C-210-4: cross-source direct-BLE stall tier (UI indicator). Updated by the adapter's tick.
    var directBleStall: DirectBleStallTier = .none
    /// C-210-4: last time a phone/WatchConnectivity EGV was applied (phone-path freshness signal,
    /// independent of BLE/HK). Used to distinguish a direct-BLE stall from a system-wide gap.
    var lastPhoneEGVDate: Date?
    var g7DirectBleLastEventAt: Date?
    var g7DirectBleLastReadingAt: Date?
    var g7DirectBleLastEventAgeText: String {
        guard let g7DirectBleLastEventAt else { return "--" }
        let seconds = max(0, Int(Date().timeIntervalSince(g7DirectBleLastEventAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// G7 direct BLE: daily-persistent counters and debug (mirrored from observer; UserDefaults in observer).
    var bleConnectsToday: Int = 0
    var bleEGVsToday: Int = 0
    var bleLastConnectAt: Date?
    var bleLastEGVDate: Date?
    var bleLastEGVValue: Int?
    /// W7 slot accounting mirrored from `G7WatchSensorAdapter` for the debug denominator `N / (expected − gated)`.
    var gatedSlotsToday: Int = 0
    /// True when `CBCentralManager` had state restored this process (willRestoreState).
    var bleWasRestored: Bool = false
    // C-217-D5: timestamp companion to `bleWasRestored`, set alongside it from
    // `WatchTelemetryRing.enqueueCoreTelemetry`'s `will_restore_state` observer hook. UI-207-3's
    // deferred "Was restored" row — display wiring only, main-thread, mirrors `bleLastConnectAt`.
    var bleLastRestoreAt: Date?
    var lastLoopDate: Date?
    var glucoseBobbleComplicationSettings: GlucoseBobbleComplicationSettings?
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []
    var snoozeUntilDate: Date = .distantPast

    // MARK: - Treatment inputs

    /// used to store carbs for combined meal-bolus-treatments
    var carbsAmount: Int = 0
    var fatAmount: Int = 0
    var proteinAmount: Int = 0
    var bolusAmount: Double = 0.0
    var confirmationProgress: Double = 0.0
    /// Last time the user opened or changed a carbs/bolus entry; nil when no entry is in progress
    @ObservationIgnored private(set) var entryEditedAt: Date?
    /// An entry left alone for longer than this is cleared and never sent
    static let entryLifetime: TimeInterval = 2 * 60
    static let entryExpiredMessage = String(
        localized: "Entry expired after 2 minutes. Nothing was sent. Please enter it again.",
        comment: "Watch message when a carbs or bolus entry was too old to send"
    )

    // MARK: - Safety limits

    var maxBolus: Decimal = 10
    var maxCarbs: Decimal = 250
    var maxFat: Decimal = 250
    var maxProtein: Decimal = 250

    // MARK: - Pump-specific increments

    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // Forecast options
    var showForecast: Bool = false
    var isForecastCone: Bool = false
    var forecastStartDate: Date?
    var forecastConeMin: [Double] = []
    var forecastConeMax: [Double] = []
    var forecastLines: [String: [Double]] = [:] // "iob" / "cob" / "uam" / "zt" -> values

    // MARK: - Acknowledgment handling

    var showCommsAnimation: Bool = false
    var showAcknowledgmentBanner: Bool = false
    var acknowledgementStatus: AcknowledgementStatus = .pending
    var acknowledgmentMessage: String = ""
    var shouldNavigateToRoot: Bool = true
    @ObservationIgnored private var acknowledgmentTimeoutWorkItem: DispatchWorkItem?

    /// Long enough for a pump to accept a bolus, short enough that the user isn't left guessing
    static let acknowledgmentTimeout: TimeInterval = 15
    static let noAnswerMessage = String(
        localized: "No answer from iPhone. Check Trio on your iPhone before trying again.",
        comment: "Watch message when the phone did not confirm a request"
    )
    static let phoneUnreachableMessage = String(
        localized: "iPhone not reachable. Nothing was sent.",
        comment: "Watch message when a request could not be sent to the phone"
    )
    static let invalidBolusAmountMessage = String(
        localized: "Error! Bolus amount must be greater than 0 U.",
        comment: "Error message when a bolus of zero or less is requested"
    )

    // MARK: - Progress state

    var showBolusCalculationProgress: Bool = false
    var mealBolusStep: MealBolusStep = .savingCarbs
    var isMealBolusCombo: Bool = false
    var recommendedBolus: Decimal = 0

    /// Snapshots older than this are dropped at the top of the WC message path.
    private static let maxAcceptableMessageAgeInMinutes: TimeInterval = 15 * 60

    // MARK: - Debouncing and sync helpers

    private var pendingData: [String: Any] = [:]
    private var finalizeWorkItem: DispatchWorkItem?
    var showSyncingAnimation: Bool = false
    var syncTimeoutWorkItem: DispatchWorkItem?

    /// Connectivity background tasks held until userInfo processing finishes. Main queue only.
    private var pendingConnectivityTasks: [WKRefreshBackgroundTask] = []
    /// R5d — persisted via App Group UserDefaults for sleep-gap detection across process restarts.
    private var lastDataReceivedAt: Date? {
        get { TrioComplicationDataStore.shared.lastDataReceivedAt() }
        set {
            if let date = newValue {
                TrioComplicationDataStore.shared.setLastDataReceivedAt(date)
            }
        }
    }

    /// R5c — set in didReceiveUserInfo and passed through to saveComplicationSnapshot for decode_ms (reading_epoch there is derived from the payload being saved to avoid misattribution).
    private var lastUserInfoReceiveTimestamp: Date?
    private var quietWindowWorkItem: DispatchWorkItem?

    /// Effective CGM reading date for which `displayedReadingSource` was last set. In-memory only; nil on cold start.
    private var displayedReadingAttributedForDate: Date?
    /// G7 sequence for the attributed reading when known; nil when the winning channel did not carry sequence (e.g. HK).
    private var displayedReadingAttributedSequence: Int?

    /// Most recent payload build-time (`WatchMessageKeys.date`) that produced a successful
    /// `setActiveSensorName` application. In-memory only; resets on process restart. Suppresses
    /// stale WC payloads (out-of-order userInfo, queued message after a phone-side sensor swap)
    /// from rolling back the adapter's active G7 sensor identity. See
    /// `applyG7ActiveSensorNameFromWatchPayloadIfPresent`.
    private var lastAppliedG7SensorNamePayloadDate: Date?

    private var activationTimestamp: Date?
    private var forcedSinceActivation = false

    private var transferRetryCount = 0
    private let maxTransferRetries = 3
    private var retryWorkItem: DispatchWorkItem?

    // MARK: - Startup coordination

    private let startupWatchStateDelaySeconds: TimeInterval = 2.0
    private let startupHealthKitDelaySeconds: TimeInterval = 10.0
    private let startupLogDrainDelaySeconds: TimeInterval = 10.0

    private var startupActivationSequence = 0
    private var startupCurrentActivationSequence: Int?
    private var startupIsForegroundActive = false
    private var startupDeferredWatchStateWorkItem: DispatchWorkItem?
    private var startupDeferredHealthKitWorkItem: DispatchWorkItem?
    private var startupDeferredLogDrainWorkItem: DispatchWorkItem?
    private var startupFirstRefreshFiredActivationSequence: Int?
    private var startupFirstRefreshInFlight = false
    private var hasInitializedHealthKitSetupInProcess = false
    private var hasEnabledHealthKitBackgroundDeliveryInProcess = false

    /// Monotonic process launch time for HK_REG / HK_FIRE launch-context telemetry (TRIO-113).
    private let processLaunchUptime = ProcessInfo.processInfo.systemUptime

    /// Captured once at launch HK registration from `WKApplication.shared().applicationState` (TRIO-113).
    private var healthKitObserverLaunchContextTelemetry = "unknown"

    /// HK background-delivery watchdog allowance is 15s; complete the observer callback well inside that.
    private let healthKitObserverFetchTimeoutSeconds: TimeInterval = 10.0

    /// Resident memory sample budget — see `Helper/WatchResidentTelemetry.swift`.
    var residentTelemetryBudget = WatchResidentTelemetryBudget()

    /// Set when the root SwiftUI main view’s `.onAppear` ran before `startupCurrentActivationSequence` existed; flushed after the next foreground activation is established.
    private var pendingResidentSampleFirstMainView = false

    // MARK: - HealthKit (R6)

    private var healthKitStore: HKHealthStore?
    private var glucoseObserverQuery: HKObserverQuery?

    /// Path B4 — max samples for nil-anchor bootstrap (`HKSampleQuery`, descending). **64** ≈ enough for latest + delta/trend context within a dense CGM window while capping peak batch size vs unbounded anchored pulls.
    private static let hkBootstrapSampleLimit = 64

    private var backgroundRefreshCount = 0
    private var lastBackgroundRefreshDate: Date?

    /// Set when a `WKApplicationRefreshBackgroundTask` triggers `requestWatchStateUpdate()` and the
    /// resulting fresh data application should trigger `forceComplicationUpdate()`. Consumed (fired
    /// and cleared) in `finalizePendingData` once the WC reply has been processed and applied to
    /// UI state.
    ///
    /// **Two clearing paths exist**, both gated by `bgTaskComplicationUpdateWindow`:
    /// 1. `finalizePendingData` (fresh data arrived): fires `forceComplicationUpdate()` when
    ///    within window, or logs `"🔄 bgtask complication update flag expired"` if past it.
    /// 2. `DispatchQueue.main.asyncAfter` scheduled alongside the flag in the bgtask handler:
    ///    if the flag is still set with the **same timestamp** after the window elapses (no
    ///    data ever arrived), clears the flag and logs `"⌚️ bgTask complication update skipped:
    ///    flag stale"`. The timestamp match ensures a later bgtask's flag is not stolen.
    private var pendingBgTaskComplicationUpdateAt: Date?
    /// Staleness bound for `pendingBgTaskComplicationUpdateAt`. Matches the WC sync timeout in
    /// `requestWatchStateUpdate()` so any flag older than this is treated as expired.
    private let bgTaskComplicationUpdateWindow: TimeInterval = 30.0
    private var lastConnectivityTerminalAt: Date?
    private var lastConnectivityTerminalPath: String?
    private var deferredConnectivityCompletionWorkItem: DispatchWorkItem?
    private var deferredConnectivityCompletionDeadline: Date?
    private var deferredConnectivityCompletionPath: String?
    private var deferredConnectivityCompletionAttempt = 0
    private let connectivityLateTaskWindowSeconds: TimeInterval = 2.0
    private let connectivityDeferredRetryInitialDelaySeconds: TimeInterval = 0.2
    private let connectivityDeferredRetryMaxDelaySeconds: TimeInterval = 1.0
    private let connectivityDeferredRetryBudgetSeconds: TimeInterval = 4.0

    /// Guards against duplicate requestWatchStateUpdate() calls on cold start.
    /// Reset in noteAppBecameActive() on each active transition. Main-thread confined.
    private var hasRequestedInitialUpdate = false

    var deviceType = WatchSize.current

    private var isColdStart: Bool {
        guard let activationTimestamp = activationTimestamp else { return true }
        return Date().timeIntervalSince(activationTimestamp) < 60
    }

    override init() {
        super.init()
        setupSession()
        restoreCachedLoopMetrics()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forceComplicationUpdate()
            self.scheduleBackgroundRefresh()
        }
    }

    /// Build 205 / W3: restore IOB/COB/lastLoopTime from the 30-min cache on cold start so they aren't
    /// `--` until the first WC payload. Keyed on the cached WatchState build time (not write time):
    /// reject stale (> 30 min) AND future-dated (age < 0, clock-skew) caches — leave `--` in those cases.
    private func restoreCachedLoopMetrics() {
        let defaults = UserDefaults.standard
        guard let ts = defaults.object(forKey: "WatchState.cachedWCTimestamp") as? Double else { return }
        let age = Date().timeIntervalSince1970 - ts
        guard age >= 0, age <= 30 * 60 else { return }
        iob = defaults.string(forKey: "WatchState.cachedIOB") ?? "--"
        cob = defaults.string(forKey: "WatchState.cachedCOB") ?? "--"
        lastLoopTime = defaults.string(forKey: "WatchState.cachedLastLoopTime") ?? "--"
        lastWatchStateUpdate = Date(timeIntervalSince1970: ts)
    }

    func noteAppBecameActive() {
        assert(Thread.isMainThread, "noteAppBecameActive must be called on main thread")
        activationTimestamp = Date()
        forcedSinceActivation = false
        hasRequestedInitialUpdate = false
        startupFirstRefreshInFlight = false
    }

    @MainActor
    func handleForegroundActiveEntry() {
        assert(Thread.isMainThread, "handleForegroundActiveEntry must be called on main thread")
        guard !startupIsForegroundActive else { return }

        startupIsForegroundActive = true
        startupActivationSequence += 1
        let activationSequence = startupActivationSequence
        startupCurrentActivationSequence = activationSequence
        startupFirstRefreshFiredActivationSequence = nil
        residentTelemetryBudget.resetForNewActivation(activationSequence)
        flushPendingFirstMainViewResidentSampleIfNeeded()

        noteAppBecameActive()
        scheduleStartupSequenceOnMain(activationSequence: activationSequence)
        applyG7DirectBleScenePhase("active")
        G7WatchSensorAdapter.shared.applyForegroundActiveEntry()

        WatchLogger.shared.log(
            "event=watch_startup_grace_scheduled"
                + " activation_seq=\(activationSequence)"
                + " watch_state_delay_s=\(Int(startupWatchStateDelaySeconds))"
                + " healthkit_delay_s=\(Int(startupHealthKitDelaySeconds))"
                + " log_drain_delay_s=\(Int(startupLogDrainDelaySeconds))"
        )
    }

    /// Leaving the active foreground. **Dual path:** `TrioWatchApp`’s `scenePhase` `.onChange` passes
    /// `active` / `inactive` / `background` via `watchScenePhaseToken`; `ExtensionDelegate.applicationWillResignActive`
    /// passes `inactive` (resign-active precedes true background). Both can fire close together—duplicate
    /// `scene_phase=inactive` lines in logs are a known artifact, not necessarily duplicate work.
    @MainActor
    func handleForegroundInactiveOrBackground(phase: String) {
        assert(Thread.isMainThread, "handleForegroundInactiveOrBackground must be called on main thread")
        // Scene phase + adapter snapshot must update on every SwiftUI transition (`inactive` then `background`).
        // Startup teardown below runs at most once per activation, so phase notify stays **above** the guard.
        applyG7DirectBleScenePhase(phase)
        G7WatchSensorAdapter.shared.noteForegroundInactiveOrBackground(phase)

        guard startupIsForegroundActive else { return }

        pendingResidentSampleFirstMainView = false

        startupIsForegroundActive = false
        startupFirstRefreshInFlight = false
        let activationSequence = startupCurrentActivationSequence
        let pendingTasks = startupPendingTasksFieldOnMain()
        cancelStartupSequenceOnMain()
        startupCurrentActivationSequence = nil

        if let activationSequence, pendingTasks != "none" {
            WatchLogger.shared.log(
                "event=watch_startup_grace_canceled"
                    + " activation_seq=\(activationSequence)"
                    + " reason=left_active_before_fire"
                    + " pending=\(pendingTasks)"
            )
        }
    }

    /// Root main view (`TrioMainWatchView`) `.onAppear` — **main thread only.** Latches `first_main_view` until `startupCurrentActivationSequence` exists if needed.
    func noteMainWatchRootViewAppearedForResidentTelemetry() {
        assert(Thread.isMainThread, "noteMainWatchRootViewAppearedForResidentTelemetry must be called on main thread")
        guard WatchResidentTelemetryGate.isEnabled else { return }
        if let seq = startupCurrentActivationSequence {
            emitResidentMemorySample(checkpoint: "first_main_view", activationSequence: seq)
        } else {
            pendingResidentSampleFirstMainView = true
        }
    }

    /// Chart tab (page 1) became visible — **main thread only.**
    func noteChartTabBecameVisibleForResidentTelemetry() {
        assert(Thread.isMainThread, "noteChartTabBecameVisibleForResidentTelemetry must be called on main thread")
        emitResidentMemorySample(checkpoint: "chart_visible", activationSequence: startupCurrentActivationSequence)
    }

    private func flushPendingFirstMainViewResidentSampleIfNeeded() {
        assert(Thread.isMainThread, "flushPendingFirstMainViewResidentSampleIfNeeded must be called on main thread")
        guard pendingResidentSampleFirstMainView else { return }
        guard let seq = startupCurrentActivationSequence else { return }
        pendingResidentSampleFirstMainView = false
        emitResidentMemorySample(checkpoint: "first_main_view", activationSequence: seq)
    }

    private func scheduleStartupSequenceOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "scheduleStartupSequenceOnMain must be called on main thread")
        cancelStartupSequenceOnMain()

        let watchStateWorkItem = DispatchWorkItem { [weak self] in
            self?.fireDeferredStartupWatchStateRefreshOnMain(
                activationSequence: activationSequence
            )
        }
        startupDeferredWatchStateWorkItem = watchStateWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + startupWatchStateDelaySeconds,
            execute: watchStateWorkItem
        )

        let healthKitWorkItem = DispatchWorkItem { [weak self] in
            self?.fireDeferredStartupHealthKitSetupOnMain(
                activationSequence: activationSequence
            )
        }
        startupDeferredHealthKitWorkItem = healthKitWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + startupHealthKitDelaySeconds,
            execute: healthKitWorkItem
        )

        let logDrainWorkItem = DispatchWorkItem { [weak self] in
            self?.fireDeferredStartupLogDrainOnMain(
                activationSequence: activationSequence
            )
        }
        startupDeferredLogDrainWorkItem = logDrainWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + startupLogDrainDelaySeconds,
            execute: logDrainWorkItem
        )
    }

    private func cancelStartupSequenceOnMain() {
        assert(Thread.isMainThread, "cancelStartupSequenceOnMain must be called on main thread")
        startupDeferredWatchStateWorkItem?.cancel()
        startupDeferredWatchStateWorkItem = nil
        startupDeferredHealthKitWorkItem?.cancel()
        startupDeferredHealthKitWorkItem = nil
        startupDeferredLogDrainWorkItem?.cancel()
        startupDeferredLogDrainWorkItem = nil
    }

    private func startupPendingTasksFieldOnMain() -> String {
        assert(Thread.isMainThread, "startupPendingTasksFieldOnMain must be called on main thread")

        var pendingTasks: [String] = []
        if startupDeferredWatchStateWorkItem != nil {
            pendingTasks.append("watch_state")
        }
        if startupDeferredHealthKitWorkItem != nil {
            pendingTasks.append("healthkit")
        }
        if startupDeferredLogDrainWorkItem != nil {
            pendingTasks.append("log_drain")
        }

        return pendingTasks.isEmpty ? "none" : pendingTasks.joined(separator: "|")
    }

    private func fireDeferredStartupWatchStateRefreshOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "fireDeferredStartupWatchStateRefreshOnMain must be called on main thread")
        guard startupIsForegroundActive,
              startupCurrentActivationSequence == activationSequence
        else { return }

        startupDeferredWatchStateWorkItem = nil
        startupFirstRefreshFiredActivationSequence = activationSequence
        hasRequestedInitialUpdate = true
        startupFirstRefreshInFlight = true
        showSyncingAnimation = true

        WatchLogger.shared.log(
            "event=watch_startup_deferred_watch_state_refresh_fired"
                + " activation_seq=\(activationSequence)"
        )

        emitResidentMemorySample(
            checkpoint: "deferred_watch_state_fired",
            activationSequence: activationSequence
        )

        requestWatchStateUpdate()
    }

    private func fireDeferredStartupHealthKitSetupOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "fireDeferredStartupHealthKitSetupOnMain must be called on main thread")
        guard startupIsForegroundActive,
              startupCurrentActivationSequence == activationSequence
        else { return }

        startupDeferredHealthKitWorkItem = nil
        let alreadyInitialized = hasInitializedHealthKitSetupInProcess

        WatchLogger.shared.log(
            "event=watch_startup_deferred_healthkit_setup_fired"
                + " activation_seq=\(activationSequence)"
                + " already_initialized=\(alreadyInitialized)"
        )

        registerHealthKitGlucoseObserverIfNeeded(
            registrationPath: "deferred_foreground",
            requestAuthorizationIfNeeded: true
        )
    }

    // MARK: - HealthKit observer at launch (TRIO-113)

    /// Registers the glucose `HKObserverQuery` and background delivery at process launch (including
    /// background relaunches). Skips `requestAuthorization` — foreground deferred path handles first-time auth.
    @MainActor
    func registerHealthKitGlucoseObserverAtLaunchIfAuthorized() {
        assert(Thread.isMainThread, "registerHealthKitGlucoseObserverAtLaunchIfAuthorized must be called on main thread")
        let appState = WKApplication.shared().applicationState
        healthKitObserverLaunchContextTelemetry = appState == .background ? "background" : "foreground"
        registerHealthKitGlucoseObserverIfNeeded(
            registrationPath: "launch",
            requestAuthorizationIfNeeded: false
        )
    }

    private func healthKitLaunchContextTelemetryFields() -> String {
        let secondsSinceLaunch = Int(ProcessInfo.processInfo.systemUptime - processLaunchUptime)
        return "launch_context=\(healthKitObserverLaunchContextTelemetry) seconds_since_launch=\(secondsSinceLaunch)"
    }

    private func logHealthKitRegistration(
        registrationPath: String,
        outcome: String,
        detail: String = ""
    ) {
        var line =
            "event=HK_REG path=\(registrationPath)"
                + " \(healthKitLaunchContextTelemetryFields())"
                + " outcome=\(outcome)"
                + " already_initialized=\(hasInitializedHealthKitSetupInProcess)"
        if !detail.isEmpty {
            line += " \(detail)"
        }
        WatchLogger.shared.log(line)
    }

    private func registerHealthKitGlucoseObserverIfNeeded(
        registrationPath: String,
        requestAuthorizationIfNeeded: Bool
    ) {
        assert(Thread.isMainThread, "registerHealthKitGlucoseObserverIfNeeded must be called on main thread")

        if hasInitializedHealthKitSetupInProcess {
            if registrationPath == "deferred_foreground",
               !hasEnabledHealthKitBackgroundDeliveryInProcess,
               let store = healthKitStore,
               let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)
            {
                enableHealthKitBackgroundDelivery(
                    store: store,
                    sampleType: bgType,
                    registrationPath: "deferred_foreground_retry"
                )
            } else {
                logHealthKitRegistration(registrationPath: registrationPath, outcome: "skipped_duplicate")
            }
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            logHealthKitRegistration(registrationPath: registrationPath, outcome: "skipped_unavailable")
            return
        }
        guard let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            logHealthKitRegistration(registrationPath: registrationPath, outcome: "skipped_no_type")
            return
        }

        let store = HKHealthStore()
        store.getRequestStatusForAuthorization(toShare: [], read: Set([bgType])) { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.hasInitializedHealthKitSetupInProcess else {
                    self.logHealthKitRegistration(registrationPath: registrationPath, outcome: "skipped_duplicate")
                    return
                }
                if let error {
                    self.logHealthKitRegistration(
                        registrationPath: registrationPath,
                        outcome: "skipped_auth_status_unknown",
                        detail: "error=\(error.localizedDescription)"
                    )
                    return
                }
                switch status {
                case .unnecessary:
                    self.finishHealthKitGlucoseObserverRegistration(
                        store: store,
                        sampleType: bgType,
                        registrationPath: registrationPath
                    )
                case .shouldRequest:
                    guard requestAuthorizationIfNeeded else {
                        self.logHealthKitRegistration(
                            registrationPath: registrationPath,
                            outcome: "skipped_auth_not_determined"
                        )
                        return
                    }
                    store.requestAuthorization(toShare: nil, read: Set([bgType])) { [weak self] granted, authError in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard !self.hasInitializedHealthKitSetupInProcess else {
                                self.logHealthKitRegistration(
                                    registrationPath: registrationPath,
                                    outcome: "skipped_duplicate"
                                )
                                return
                            }
                            guard authError == nil else {
                                WatchLogger.shared.log(
                                    "❌ hk_authorization_failed granted=\(granted) error=\(authError?.localizedDescription ?? "nil")"
                                )
                                self.logHealthKitRegistration(
                                    registrationPath: registrationPath,
                                    outcome: "auth_denied"
                                )
                                return
                            }
                            self.finishHealthKitGlucoseObserverRegistration(
                                store: store,
                                sampleType: bgType,
                                registrationPath: registrationPath
                            )
                        }
                    }
                case .unknown:
                    self.logHealthKitRegistration(
                        registrationPath: registrationPath,
                        outcome: "skipped_auth_status_unknown"
                    )
                @unknown default:
                    self.logHealthKitRegistration(
                        registrationPath: registrationPath,
                        outcome: "skipped_auth_status_unknown",
                        detail: "request_status=\(status.rawValue)"
                    )
                }
            }
        }
    }

    private func enableHealthKitBackgroundDelivery(
        store: HKHealthStore,
        sampleType: HKQuantityType,
        registrationPath: String
    ) {
        assert(Thread.isMainThread, "enableHealthKitBackgroundDelivery must be called on main thread")
        store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let outcome: String
                var detail = ""
                if let error {
                    outcome = "failed"
                    detail = "error=\(error.localizedDescription)"
                    WatchLogger.shared.log(
                        "❌ hk_background_delivery_registration_failed error=\(error.localizedDescription)"
                    )
                } else if success {
                    outcome = "enabled"
                    self.hasEnabledHealthKitBackgroundDeliveryInProcess = true
                    WatchLogger.shared
                        .log(
                            "✅ hk_background_delivery_registered success=true low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        )
                } else {
                    outcome = "failed"
                    WatchLogger.shared
                        .log(
                            "⚠️ hk_background_delivery_registered success=false low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        )
                }
                var line =
                    "event=HK_REG phase=background_delivery path=\(registrationPath)"
                        + " \(self.healthKitLaunchContextTelemetryFields())"
                        + " outcome=\(outcome)"
                if !detail.isEmpty {
                    line += " \(detail)"
                }
                WatchLogger.shared.log(line)
            }
        }
    }

    private func finishHealthKitGlucoseObserverRegistration(
        store: HKHealthStore,
        sampleType: HKQuantityType,
        registrationPath: String
    ) {
        assert(Thread.isMainThread, "finishHealthKitGlucoseObserverRegistration must be called on main thread")
        guard !hasInitializedHealthKitSetupInProcess else {
            logHealthKitRegistration(registrationPath: registrationPath, outcome: "skipped_duplicate")
            return
        }

        setupGlucoseObserverQuery(store: store, sampleType: sampleType)
        enableHealthKitBackgroundDelivery(store: store, sampleType: sampleType, registrationPath: registrationPath)
        logHealthKitRegistration(
            registrationPath: registrationPath,
            outcome: "observer_installed",
            detail: "low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        )
    }

    // fork — TRIO-113: call HKObserverQuery completion exactly once per delivery (watchdog-safe).
    private final class HKObserverCompletionGate {
        private static let timeoutQueue = DispatchQueue(label: "com.trio.hk-observer-completion-gate-timeout")

        private let lock = NSLock()
        private var didComplete = false
        private let fireId: UUID
        private let enteredAtUptime: TimeInterval
        private let launchContextFields: String
        private let systemHandler: () -> Void
        private var timeoutWorkItem: DispatchWorkItem?

        init(
            fireId: UUID,
            enteredAtUptime: TimeInterval,
            launchContextFields: String,
            timeoutSeconds: TimeInterval,
            systemHandler: @escaping () -> Void
        ) {
            self.fireId = fireId
            self.enteredAtUptime = enteredAtUptime
            self.launchContextFields = launchContextFields
            self.systemHandler = systemHandler

            let work = DispatchWorkItem { [weak self] in
                self?.complete(outcome: "timeout")
            }
            timeoutWorkItem = work
            Self.timeoutQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        }

        func complete(outcome: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !didComplete else { return }
            didComplete = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil

            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - enteredAtUptime) * 1000)
            WatchLogger.shared.log(
                "event=HK_FIRE phase=completion fire_id=\(fireId)"
                    + " \(launchContextFields)"
                    + " elapsed_ms=\(elapsedMs) outcome=\(outcome)"
            )
            systemHandler()
        }
    }

    private func fireDeferredStartupLogDrainOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "fireDeferredStartupLogDrainOnMain must be called on main thread")
        guard startupIsForegroundActive,
              startupCurrentActivationSequence == activationSequence
        else { return }

        startupDeferredLogDrainWorkItem = nil

        WatchLogger.shared.log(
            "event=watch_startup_deferred_log_drain_fired"
                + " activation_seq=\(activationSequence)"
        )
        ComplicationLogForwarder.shared.drain()
        emitResidentMemorySample(
            checkpoint: "post_startup_flush",
            activationSequence: activationSequence
        )
    }

    private func shouldSuppressStartupSignalOnMain() -> Bool {
        assert(Thread.isMainThread, "shouldSuppressStartupSignalOnMain must be called on main thread")

        guard activationTimestamp != nil else { return true }

        guard startupIsForegroundActive,
              let activationSequence = startupCurrentActivationSequence
        else { return false }

        return startupFirstRefreshFiredActivationSequence != activationSequence
    }

    private func logStartupSignalSuppressedOnMain() {
        assert(Thread.isMainThread, "logStartupSignalSuppressedOnMain must be called on main thread")
        guard startupIsForegroundActive,
              let activationSequence = startupCurrentActivationSequence
        else { return }

        WatchLogger.shared.log(
            "event=watch_startup_transport_suppressed"
                + " activation_seq=\(activationSequence)"
                + " path=startup_signal"
                + " reason=startup_grace"
        )
    }

    private func requestWatchStateUpdateRespectingStartupGraceOnMain() {
        assert(Thread.isMainThread, "requestWatchStateUpdateRespectingStartupGraceOnMain must be called on main thread")
        if shouldSuppressStartupSignalOnMain() {
            logStartupSignalSuppressedOnMain()
            return
        }

        requestWatchStateUpdate()
    }

    func clearStartupFirstRefreshInFlightOnMain() {
        assert(Thread.isMainThread, "clearStartupFirstRefreshInFlightOnMain must be called on main thread")
        startupFirstRefreshInFlight = false
    }

    /// Configures the WatchConnectivity session if supported on the device
    private func setupSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            WatchLogger.shared.debug(.connectivity, "Session set up")
        } else {
            WatchLogger.shared.error(.connectivity, "Watch connectivity not supported on this device")
        }
    }

    // MARK: - Entry lifetime

    /// Starts or restarts the entry's clock. Call when an input screen appears and on every amount change.
    func markEntryEdited(at now: Date = Date()) {
        entryEditedAt = now
    }

    /// True only for an entry changed within `entryLifetime`; an entry with no recorded edit is never fresh
    func isEntryFresh(at now: Date = Date()) -> Bool {
        guard let entryEditedAt else { return false }
        return now.timeIntervalSince(entryEditedAt) <= Self.entryLifetime
    }

    /// Ends the entry: clears amounts, the recommendation and the confirmation progress
    func clearEntry() {
        bolusAmount = 0
        carbsAmount = 0
        fatAmount = 0
        proteinAmount = 0
        recommendedBolus = 0
        confirmationProgress = 0
        entryEditedAt = nil
    }

    /// Clears an entry older than `entryLifetime`. Returns true when it did, so the caller can
    /// leave the input screens.
    @discardableResult func expireStaleEntry(at now: Date = Date()) -> Bool {
        guard entryEditedAt != nil, !isEntryFresh(at: now) else { return false }
        WatchLogger.shared.info(.treatments, "Entry older than \(Int(Self.entryLifetime / 60)) min cleared")
        clearEntry()
        return true
    }

    // MARK: - HealthKit background delivery (R6)

    private func setupGlucoseObserverQuery(store: HKHealthStore, sampleType: HKQuantityType) {
        guard !hasInitializedHealthKitSetupInProcess else { return }
        healthKitStore = store
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            let fireId = UUID()
            let enteredAtUptime = ProcessInfo.processInfo.systemUptime
            let launchContextFields: String
            if let self {
                launchContextFields = self.healthKitLaunchContextTelemetryFields()
            } else {
                launchContextFields = "launch_context=unknown seconds_since_launch=-1"
            }
            WatchLogger.shared.log(
                "event=HK_FIRE phase=entered fire_id=\(fireId) \(launchContextFields)"
            )
            let completionGate = HKObserverCompletionGate(
                fireId: fireId,
                enteredAtUptime: enteredAtUptime,
                launchContextFields: launchContextFields,
                timeoutSeconds: self?.healthKitObserverFetchTimeoutSeconds ?? 10.0,
                systemHandler: completionHandler
            )
            guard error == nil else {
                WatchLogger.shared.log("❌ hk_observer_error fire_id=\(fireId) error=\(error!.localizedDescription)")
                completionGate.complete(outcome: "failed")
                return
            }
            guard let self else {
                completionGate.complete(outcome: "skipped")
                return
            }
            self.fetchLatestGlucoseFromHealthKit(fireId: fireId, completionGate: completionGate)
        }
        hasInitializedHealthKitSetupInProcess = true
        store.execute(query)
        glucoseObserverQuery = query
    }

    /// Path B4 — shared post-fetch processing for **both** bootstrap (`HKSampleQuery`) and incremental (`HKAnchoredObjectQuery`) paths. Persists `HKQueryAnchor` when `newAnchor` is non-nil (incremental path). Bootstrap anchor persistence is handled separately via `establishHealthKitGlucoseTimelineAnchorAfterBootstrap` after a successful sample query.
    private func finishHKGlucoseObserverFetch(
        fireId: UUID,
        anchorWasNil: Bool,
        samples: [HKQuantitySample]?,
        newAnchor: HKQueryAnchor?,
        error: Error?,
        mgDlUnit: HKUnit,
        completionGate: HKObserverCompletionGate,
        onSuccessAfterApply: (() -> Void)? = nil
    ) {
        let dataStore = TrioComplicationDataStore.shared
        let finishNonError: (String) -> Void = { outcome in
            if let onSuccessAfterApply {
                onSuccessAfterApply()
            } else {
                completionGate.complete(outcome: outcome)
            }
        }

        if let err = error {
            WatchLogger.shared.log("❌ hk_observer_query_error fire_id=\(fireId) error=\(err.localizedDescription)")
            completionGate.complete(outcome: "failed")
            return
        }

        let added = samples ?? []
        // Stable batch events: `hk_sample_query_batch` (bootstrap `HKSampleQuery`) vs `hk_anchored_query_batch` (incremental `HKAnchoredObjectQuery`) — split so Better Stack filters are not misleading (Claude review).
        let batchEventName = anchorWasNil ? "hk_sample_query_batch" : "hk_anchored_query_batch"
        WatchLogger.shared
            .log("event=\(batchEventName) fire_id=\(fireId) anchor_was_nil=\(anchorWasNil) samples_count=\(added.count)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.emitResidentMemorySample(
                checkpoint: "hk_batch",
                activationSequence: self.startupCurrentActivationSequence
            )
        }

        if let newAnchor,
           let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
        {
            dataStore.saveHKGlucoseAnchor(anchorData)
        }

        let sortedByDate = added.sorted { $0.startDate > $1.startDate }
        if sortedByDate.isEmpty {
            WatchLogger.shared.log("⚠️ hk_observer_no_new_samples fire_id=\(fireId)")
            finishNonError("skipped")
            return
        }

        let latest = sortedByDate[0]
        let latestEpoch = latest.startDate.timeIntervalSince1970
        let latestMgDl = latest.quantity.doubleValue(for: mgDlUnit)

        // C-210-10 (scan #6): skip only a true duplicate (same epoch AND same value). A same-epoch
        // *correction* (different value) must still be processed, not dropped. Preserves the
        // idempotency guard for the common re-fire of the newest already-seen sample.
        let knownEpoch = latestEpoch == dataStore.hkLastReceivedGlucoseEpoch()
        let sameValue = Int(latestMgDl.rounded()) == Int(dataStore.hkLastReceivedGlucoseValueMgDl().rounded())
        if knownEpoch, sameValue {
            WatchLogger.shared.log("⚠️ hk_observer_skipped_known_epoch fire_id=\(fireId) epoch=\(Int(latestEpoch))")
            finishNonError("skipped")
            return
        }

        var previousMgDl: Double?
        var previousEpoch: TimeInterval?
        if sortedByDate.count >= 2 {
            let prev = sortedByDate[1]
            previousMgDl = prev.quantity.doubleValue(for: mgDlUnit)
            previousEpoch = prev.startDate.timeIntervalSince1970
        } else {
            let storedEpoch = dataStore.hkLastReceivedGlucoseEpoch()
            if storedEpoch > 0 {
                previousEpoch = storedEpoch
                previousMgDl = dataStore.hkLastReceivedGlucoseValueMgDl()
            }
        }

        let timeDelta = previousEpoch.map { latestEpoch - $0 } ?? 0
        let plausibilityOK = timeDelta > 0 && timeDelta < 15 * 60

        var deltaString = "--"
        var trendString = ""
        var trendDerived = false

        if let prev = previousMgDl, plausibilityOK {
            let rawDeltaMgDl = latestMgDl - prev
            let deltaInt = Int(rawDeltaMgDl.rounded())
            // C-210-1: display the delta in the user's unit; keep the mg/dL deltaInt for the trend bucket.
            deltaString = WatchGlucoseColorComputer.shared.displayDeltaString(
                previousMgDl: Int(prev.rounded()),
                currentMgDl: Int(latestMgDl.rounded())
            )
            trendString = Self.hkTrendString(fromDeltaMgDl: deltaInt)
            trendDerived = true
        }

        dataStore.setHKLastReceivedGlucoseEpoch(latestEpoch)
        dataStore.setHKLastReceivedGlucoseValueMgDl(latestMgDl)

        let readingDate = latest.startDate
        let hkMgDl = Int(latestMgDl.rounded()) // canonical integer mg/dL (HK delivers integer-valued Double)
        let glucoseString = String(hkMgDl)
        let syncLag = Int(Date().timeIntervalSince(readingDate))

        // Stable tokens for validation / Better Stack: batch lines use `hk_sample_query_batch` | `hk_anchored_query_batch` above; `query_type` uses `sampleQuery_bootstrap` | `anchoredQuery`. Do not rename casually.
        let queryLabel = anchorWasNil ? "sampleQuery_bootstrap" : "anchoredQuery"
        WatchLogger.shared.log(
            "🏥 hk_observer_fired fire_id=\(fireId) reading_epoch=\(Int(readingDate.timeIntervalSince1970)) sync_lag=\(syncLag) glucose=\(glucoseString) delta=\(deltaString) trend=\(trendString) trend_derived=\(trendDerived) samples_in_batch=\(sortedByDate.count) query_type=\(queryLabel)"
        )

        let snapshot = TrioComplicationSnapshot(
            // C-210-1: bake the unit-correct display string (mmol users were seeing raw mg/dL).
            glucose: WatchGlucoseColorComputer.shared.displayString(forMgDl: hkMgDl),
            trend: trendString,
            delta: deltaString,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: WatchGlucoseColorComputer.shared.bubbleColorHex(for: hkMgDl), // W5: bake bubble hex
            source: .healthKit,
            // fork — bake the chart/scheme colour alongside the bubble colour.
            chartGlucoseColor: WatchGlucoseColorComputer.shared.chartColorHex(for: hkMgDl)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                if let onSuccessAfterApply {
                    onSuccessAfterApply()
                } else {
                    completionGate.complete(outcome: "skipped")
                }
                return
            }
            // Persist HK reading (W1) before the snapshot apply so the chart refresh includes it.
            WatchGlucoseHistoryStore.shared.insert(
                StoredGlucoseReading(
                    epochSeconds: Int(readingDate.timeIntervalSince1970),
                    glucoseMgDl: hkMgDl,
                    sequence: nil,
                    source: "hk"
                )
            )
            TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)
            self.applyHKSnapshot(snapshot, glucoseMgDl: hkMgDl)
            if let onSuccessAfterApply {
                onSuccessAfterApply()
            } else {
                completionGate.complete(outcome: "fetched")
            }
        }
    }

    /// Path B4 — After a successful bounded `HKSampleQuery` bootstrap, persist an `HKQueryAnchor` at the current timeline (“samples from `Date()` onward” + `.strictStartDate` is typically an **empty** forward window) so the next observer cycle uses incremental `HKAnchoredObjectQuery` instead of repeating bootstrap. Calls `completion` when the establishment query finishes (success or failure) so the HK observer callback is not released before the anchor write attempt.
    ///
    /// **Memory safety:** Uses `HKObjectQueryNoLimit`, but boundedness relies on the **predicate** yielding an effectively empty forward timeline—not on the limit parameter (ChatGPT review P2).
    private func establishHealthKitGlucoseTimelineAnchorAfterBootstrap(
        store: HKHealthStore,
        bgType: HKQuantityType,
        fireId: UUID,
        completionGate: HKObserverCompletionGate
    ) {
        let now = Date()
        let predicate = HKQuery.predicateForSamples(withStart: now, end: nil, options: .strictStartDate)
        let anchorQuery = HKAnchoredObjectQuery(
            type: bgType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit,
            resultsHandler: { _, samples, _, newAnchor, error in
                if let err = error {
                    WatchLogger.shared
                        .log("⚠️ hk_bootstrap_anchor_establish_failed fire_id=\(fireId) error=\(err.localizedDescription)")
                    completionGate.complete(outcome: "failed")
                    return
                }
                guard let newAnchor,
                      let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                else {
                    WatchLogger.shared.log("⚠️ hk_bootstrap_anchor_establish_no_anchor fire_id=\(fireId)")
                    completionGate.complete(outcome: "failed")
                    return
                }
                TrioComplicationDataStore.shared.saveHKGlucoseAnchor(anchorData)
                let n = (samples as? [HKQuantitySample])?.count ?? 0
                WatchLogger.shared
                    .log("✅ hk_bootstrap_anchor_established fire_id=\(fireId) timeline_predicate_samples_count=\(n)")
                completionGate.complete(outcome: "fetched")
            }
        )
        store.execute(anchorQuery)
    }

    private func fetchLatestGlucoseFromHealthKit(fireId: UUID, completionGate: HKObserverCompletionGate) {
        guard let store = healthKitStore,
              let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)
        else {
            WatchLogger.shared.log("❌ hk_observer_guard_failed fire_id=\(fireId) reason=nil_store_or_type")
            completionGate.complete(outcome: "failed")
            return
        }

        let dataStore = TrioComplicationDataStore.shared
        let mgDlUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

        // R6.1 — Load anchor; decode failure → nil + 24h cap
        var anchor: HKQueryAnchor?
        if let data = dataStore.hkGlucoseAnchor() {
            if let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
                anchor = decoded
            } else {
                WatchLogger.shared.log("⚠️ hk_anchor_decode_failed fire_id=\(fireId)")
            }
        } else {
            WatchLogger.shared.log("⚠️ hk_observer_nil_anchor fire_id=\(fireId)")
        }

        let anchorWasNil = (anchor == nil)

        // R6.1 — Nil anchor: cap to 24h. With anchor: no date cap. SyncIdentifier filter deferred (see plan §Source Predicate).
        let twentyFourHoursAgo = Date().addingTimeInterval(-24 * 3600)
        let bootstrapPredicate = HKQuery.predicateForSamples(withStart: twentyFourHoursAgo, end: nil, options: .strictStartDate)

        // Path B4 — No durable anchor: use descending `HKSampleQuery` so a positive limit still returns the *newest* samples (anchored queries enumerate oldest-first).
        if anchorWasNil {
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let sampleQuery = HKSampleQuery(
                sampleType: bgType,
                predicate: bootstrapPredicate,
                limit: Self.hkBootstrapSampleLimit,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, error in
                guard let self else {
                    completionGate.complete(outcome: "skipped")
                    return
                }
                if error != nil {
                    self.finishHKGlucoseObserverFetch(
                        fireId: fireId,
                        anchorWasNil: true,
                        samples: samples as? [HKQuantitySample],
                        newAnchor: nil,
                        error: error,
                        mgDlUnit: mgDlUnit,
                        completionGate: completionGate
                    )
                    return
                }
                let afterBootstrap: () -> Void = {
                    self.establishHealthKitGlucoseTimelineAnchorAfterBootstrap(
                        store: store,
                        bgType: bgType,
                        fireId: fireId,
                        completionGate: completionGate
                    )
                }
                self.finishHKGlucoseObserverFetch(
                    fireId: fireId,
                    anchorWasNil: true,
                    samples: samples as? [HKQuantitySample],
                    newAnchor: nil,
                    error: nil,
                    mgDlUnit: mgDlUnit,
                    completionGate: completionGate,
                    onSuccessAfterApply: afterBootstrap
                )
            }
            store.execute(sampleQuery)
            return
        }

        let query = HKAnchoredObjectQuery(
            type: bgType,
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit,
            resultsHandler: { [weak self] _, samples, _, newAnchor, error in
                guard let self else {
                    completionGate.complete(outcome: "skipped")
                    return
                }
                self.finishHKGlucoseObserverFetch(
                    fireId: fireId,
                    anchorWasNil: false,
                    samples: samples as? [HKQuantitySample],
                    newAnchor: newAnchor,
                    error: error,
                    mgDlUnit: mgDlUnit,
                    completionGate: completionGate
                )
            }
        )
        store.execute(query)
    }

    /// R6.1 — Same integer threshold semantics as BloodGlucose.Direction.init(trend:) (raw direction strings).
    private static func hkTrendString(fromDeltaMgDl delta: Int) -> String {
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

    static func trendString(fromDirectBleRate trendRate: Double?) -> String {
        guard let trendRate else { return "" }
        let fiveMinuteDelta = Int((trendRate * 5.0).rounded())
        return hkTrendString(fromDeltaMgDl: fiveMinuteDelta)
    }

    func applyG7DirectBleStatus(_ status: G7DirectBLEStatus) {
        assert(Thread.isMainThread, "applyG7DirectBleStatus must be called on main thread")
        g7DirectBleStatus = status
        g7DirectBleLastEventAt = Date()
    }

    /// D10: de-dup state for the lifecycle scene-phase log (collapses the double-fire from the
    /// SwiftUI `.onChange(scenePhase)` + `ExtensionDelegate.applicationWillResignActive` paths).
    private var lastG7ScenePhaseLogged: String?
    private var lastG7ScenePhaseLoggedAt: Date?

    func applyG7DirectBleScenePhase(_ phase: String) {
        assert(Thread.isMainThread, "applyG7DirectBleScenePhase must be called on main thread")
        g7DirectBleLastEventAt = Date()
        // D10: skip the duplicate emit when the same phase is reported twice within ~1s (the only
        // genuinely double-logged event — see I-1 investigation).
        let now = Date()
        if lastG7ScenePhaseLogged == phase, let last = lastG7ScenePhaseLoggedAt, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastG7ScenePhaseLogged = phase
        lastG7ScenePhaseLoggedAt = now
        Task {
            let sid = await G7WatchSensorAdapter.shared.adapterSessionID ?? "nil"
            let sensorName = await G7WatchSensorAdapter.shared.telemetrySensorName
            let line = G7StructuredTelemetryLogLine.formatBleModule(
                sensorName: sensorName,
                event: "lifecycle",
                fields: "scene_phase=\(phase) status=\(self.g7DirectBleStatus.rawValue)",
                g7Session: sid
            )
            WatchLogger.shared.log(line)
        }
    }

    /// Aligns attribution watermarks from a complication snapshot unless that would regress a newer in-memory reading (e.g. store lagging BLE).
    /// Also call when hydrating the main watch UI from `latestSnapshot()` (`onAppear`) so `tryAttributeDisplayedReadingSource` gates match the screen.
    func alignDisplayedReadingAttributionWithComplicationSnapshot(_ snapshot: TrioComplicationSnapshot) {
        assert(Thread.isMainThread, "alignDisplayedReadingAttributionWithComplicationSnapshot must be called on main thread")
        if let attributed = displayedReadingAttributedForDate,
           snapshot.readingDate <= attributed
        {
            return
        }
        displayedReadingSource = snapshot.source ?? .unknown
        displayedReadingAttributedForDate = snapshot.readingDate
        displayedReadingAttributedSequence = snapshot.sequence
    }

    func applyG7DirectBleSnapshot(_ snapshot: TrioComplicationSnapshot, glucoseMgDl: Int) {
        assert(Thread.isMainThread, "applyG7DirectBleSnapshot must be called on main thread")
        g7DirectBleLastEventAt = Date()
        g7DirectBleLastReadingAt = snapshot.readingDate
        if snapshot.source == .g7DirectBLE {
            g7DirectBleStatus = .active
        }
        showSyncingAnimation = false
        syncTimeoutWorkItem?.cancel()
        syncTimeoutWorkItem = nil // W11: match processRawDataForWatchState timeout hygiene

        guard tryAttributeDisplayedReadingSource(
            snapshot.source ?? .g7DirectBLE,
            forReadingDate: snapshot.readingDate,
            sequence: snapshot.sequence
        ) else { return }

        currentGlucose = snapshot.glucose
        trend = snapshot.trend
        delta = snapshot.delta
        if let glucoseColor = snapshot.glucoseColor {
            currentGlucoseColorString = glucoseColor
        }
        // C-210-1: snapshot.glucose is now the unit-formatted display string (mmol → "5.6"), so it
        // can't be parsed back to mg/dL. Track the canonical mg/dL passed in by the producer instead,
        // so the bubble/complication bake stays consistent (build 205 / P2). Refresh the chart from the
        // store (W2) — the adapter inserted this reading just before calling us, so it's included.
        currentGlucoseMgDl = glucoseMgDl
        glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
            colorComputer: WatchGlucoseColorComputer.shared
        )
        lastWatchStateUpdate = snapshot.readingDate
    }

    func applyHKSnapshot(_ snapshot: TrioComplicationSnapshot, glucoseMgDl: Int) {
        assert(Thread.isMainThread, "applyHKSnapshot must be called on main thread")
        guard tryAttributeDisplayedReadingSource(
            .healthKit,
            forReadingDate: snapshot.readingDate,
            sequence: snapshot.sequence
        ) else { return }
        currentGlucose = snapshot.glucose
        trend = snapshot.trend
        delta = snapshot.delta
        // P2/W5: HK snapshot carries the baked bubble hex; track it.
        if let glucoseColor = snapshot.glucoseColor {
            currentGlucoseColorString = glucoseColor
        }
        // C-210-1: snapshot.glucose is now the unit-formatted display string; track the canonical
        // mg/dL passed in by the producer instead of parsing the string.
        currentGlucoseMgDl = glucoseMgDl
        glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
            colorComputer: WatchGlucoseColorComputer.shared
        )
        lastWatchStateUpdate = snapshot.readingDate
    }

    /// Must be called on main thread. Sequence matches same reading across channels; date orders readings globally.
    @discardableResult
    private func tryAttributeDisplayedReadingSource(
        _ source: TrioComplicationDataSource,
        forReadingDate date: Date,
        sequence: Int? = nil
    ) -> Bool {
        assert(Thread.isMainThread)
        if let seq = sequence,
           let attributedSeq = displayedReadingAttributedSequence,
           seq == attributedSeq
        {
            // Same G7 reading as already attributed. Allow promotion to a higher-priority
            // source (e.g. phone-relayed snapshot rendered first, direct BLE arrived after
            // for the same sequence — BLE should win the display). Mirrors the sequence-
            // equality logic in `TrioComplicationDataStore.shouldUpdate` so the complication
            // store and live UI agree about which source owns the visible reading.
            if source.priority > displayedReadingSource.priority {
                displayedReadingSource = source
                // Date may differ slightly across channels for the same sensor reading;
                // advance the watermark so subsequent monotonic checks remain consistent.
                displayedReadingAttributedForDate = date
                return true
            }
            return false
        }
        if let attributed = displayedReadingAttributedForDate, date <= attributed {
            return false
        }
        displayedReadingSource = source
        displayedReadingAttributedForDate = date
        displayedReadingAttributedSequence = sequence
        return true
    }

    private func intForWatchMessageKey(_ key: String, in message: [String: Any]) -> Int? {
        if let n = message[key] as? NSNumber { return n.intValue }
        return message[key] as? Int
    }

    /// Path B1 — Summarize inbound WC messages without stringifying nested `glucoseValues` (avoids large transient `String` allocations).
    private static func watchConnectivityInboundSummary(_ message: [String: Any]) -> String {
        let topKeys = message.keys.sorted().joined(separator: ",")
        var parts = ["event=watch_wc_inbound channel=message top_level_keys=\(topKeys)"]
        if let ws = message[WatchMessageKeys.watchState] as? [String: Any] {
            let gv = ws[WatchMessageKeys.glucoseValues]
            let gvCount: Int
            if let arr = gv as? [Any] {
                gvCount = arr.count
            } else if gv != nil {
                gvCount = -1
            } else {
                gvCount = 0
            }
            let epoch = (ws[WatchMessageKeys.readingEpoch] as? TimeInterval).map { Int($0) } ?? -1
            let wsKeys = ws.keys.sorted().joined(separator: ",")
            parts.append("watchState_keys=\(wsKeys) glucoseValues_count=\(gvCount) reading_epoch=\(epoch)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: – Handle Acknowledgement Messages FROM Phone

    /// Shows "Processing…" and starts the clock for the phone's answer
    func beginAwaitingAcknowledgment(timeout: TimeInterval = WatchState.acknowledgmentTimeout) {
        acknowledgmentTimeoutWorkItem?.cancel()
        acknowledgementStatus = .pending
        showCommsAnimation = true

        let workItem = DispatchWorkItem { [weak self] in
            self?.handleMissingAcknowledgment()
        }
        acknowledgmentTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    /// No answer arrived in time, or sending reported an error. Sending can report an error and
    /// still deliver the request, so this tells the user to check the phone rather than claiming
    /// the request failed.
    func handleMissingAcknowledgment() {
        guard showCommsAnimation else { return }
        WatchLogger.shared.warning(.treatments, "No answer from the phone for the last request")
        handleAcknowledgment(success: false, message: Self.noAnswerMessage)
    }

    /// The request was refused on the watch and never sent
    func handleRequestNotSent(_ message: String) {
        handleAcknowledgment(success: false, message: message)
    }

    func handleAcknowledgment(success: Bool, message: String, isFinal: Bool = true) {
        acknowledgmentTimeoutWorkItem?.cancel()
        acknowledgmentTimeoutWorkItem = nil

        if success {
            acknowledgementStatus = .success
            acknowledgmentMessage = message

            // Hide progress animation
            DispatchQueue.main.async {
                self.showCommsAnimation = false
            }
        } else {
            // Hide progress animation
            DispatchQueue.main.async {
                self.showCommsAnimation = false
            }
            acknowledgementStatus = .failure
            acknowledgmentMessage = "\(message)"
        }

        if isFinal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.showAcknowledgmentBanner = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showAcknowledgmentBanner = false
                self.showSyncingAnimation = false // Just ensure this is 100% set to false
            }
        }
    }

    // MARK: - WCSessionDelegate

    /// Called when the session has completed activation
    /// Updates the reachability status and logs the activation state
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                WatchLogger.shared.error(.connectivity, "Session activation failed", error: error)
                return
            }

            if activationState == .activated {
                WatchLogger.shared.info(.connectivity, "Session activated, phone reachable: \(session.isReachable)")

                _ = self.forceConditionalWatchStateUpdate()

                self.isReachable = session.isReachable
            }
        }
    }

    /// Handles incoming messages from the paired iPhone when Phone is in the foreground
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        if WatchLogger.shared.handlePhoneMessage(message) { return }

        // Ack at top level — no `watchState` wrapper, no staleness check.
        if let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
           let ackMessage = message[WatchMessageKeys.message] as? String,
           let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String
        {
            if acknowledged {
                WatchLogger.shared.info(.treatments, "Phone confirmed request (\(ackCodeRaw)): \(ackMessage)")
            } else {
                WatchLogger.shared.warning(.treatments, "Phone rejected request (\(ackCodeRaw)): \(ackMessage)")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            processWatchMessage(message)
            return
        }

        // Recommended bolus is also not part of the WatchState message.
        if let recommendedBolus = message[WatchMessageKeys.recommendedBolus] as? NSNumber {
            WatchLogger.shared.debug(.bolus, "Bolus recommendation of \(recommendedBolus) U received")
            DispatchQueue.main.async {
                self.recommendedBolus = recommendedBolus.decimalValue
                self.showBolusCalculationProgress = false
            }
            return
        }

        WatchLogger.shared.log(Self.watchConnectivityInboundSummary(message))
        handleIncomingWatchStateMessage(message)
    }

    /// Message path for watch-state payloads. Enforces the upstream freshness contract (15 min
    /// wall-clock gate plus on-disk monotonicity dedup); G7 sensor identity syncs before any gate
    /// so a skipped payload still carries a sensor swap.
    private func handleIncomingWatchStateMessage(_ message: [String: Any]) {
        // R5b — `message` is the sendMessage envelope [WatchMessageKeys.watchState: fullMessage]; the inner
        // payload has the same shape as the iPhone fullMessage so readingEpoch is correct for end-to-end timing.
        guard let payload = message[WatchMessageKeys.watchState] as? [String: Any] else {
            WatchLogger.shared.warning(.data, "Watch state payload missing, skipped")
            DispatchQueue.main.async {
                self.clearStartupFirstRefreshInFlightOnMain()
                self.showSyncingAnimation = false
                self.completePendingConnectivityTasksOnMain(
                    path: "message_invalid",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        DispatchQueue.main.async { @MainActor in
            self.applyG7ActiveSensorNameFromWatchPayloadIfPresent(payload)
        }

        guard let date = dateValue(from: payload[WatchMessageKeys.date]) else {
            WatchLogger.shared.warning(.data, "Watch state payload malformed, skipped")
            DispatchQueue.main.async {
                self.clearStartupFirstRefreshInFlightOnMain()
                self.showSyncingAnimation = false
                self.completePendingConnectivityTasksOnMain(
                    path: "message_invalid",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        // Wall-clock staleness gate. Drops the queued backlog cheaply when
        // the watch app wakes after long disuse; without it, every payload
        // schedules merge + UI work.
        guard date >= Date().addingTimeInterval(-Self.maxAcceptableMessageAgeInMinutes) else {
            if WatchLogger.shared.shouldLog("staleState") {
                WatchLogger.shared.debug(.data, "Stale watch state from \(date) skipped")
            }
            DispatchQueue.main.async {
                self.clearStartupFirstRefreshInFlightOnMain()
                self.showSyncingAnimation = false
                self.completePendingConnectivityTasksOnMain(
                    path: "message_outdated",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        // Monotonicity dedup.
        let lastProcessed = WatchStateSnapshot.loadLatestDateFromDisk()
        guard date > lastProcessed else {
            if WatchLogger.shared.shouldLog("duplicateState") {
                WatchLogger.shared.debug(.data, "Duplicate watch state from \(date) skipped")
            }
            DispatchQueue.main.async {
                self.completePendingConnectivityTasksOnMain(
                    path: "message_duplicate",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        WatchStateSnapshot.saveLatestDateToDisk(date)

        let extractedEpoch = (payload[WatchMessageKeys.readingEpoch] as? TimeInterval).map { Int($0) } ?? -1
        WatchLogger.shared.log("📬 didReceiveMessage reading_epoch=\(extractedEpoch) receive_wall=\(Date().timeIntervalSince1970)")
        WatchLogger.shared.log("Handling watchState from \(date)")
        processWatchMessage(message)
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if WatchLogger.shared.handlePhoneMessage(userInfo) { return }

        WatchLogger.shared.log("Received userInfo with keys: \(userInfo.keys.joined(separator: ", "))")

        let payload = (userInfo[WatchMessageKeys.watchState] as? [String: Any]) ?? userInfo

        DispatchQueue.main.async { @MainActor [weak self] in
            self?.applyG7ActiveSensorNameFromWatchPayloadIfPresent(payload)
        }
        storeG7WatchAcquisitionArmIfPresent(payload)

        // Read-only check: never saveLatestDateToDisk here. Equal dates must pass, because the phone sends the full
        // state by sendMessage and a reduced complication payload by userInfo with the same state date; both must apply.
        if let payloadDate = payload[WatchMessageKeys.date] as? TimeInterval,
           Date(timeIntervalSince1970: payloadDate) < WatchStateSnapshot.loadLatestDateFromDisk()
        {
            WatchLogger.shared.log("event=user_info_older_than_processed_skipped state_epoch=\(Int(payloadDate))")
            DispatchQueue.main.async { [weak self] in
                self?.completePendingConnectivityTasksOnMain(
                    path: "user_info_older",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        let readingDate: Date
        switch resolveEffectiveCGMReadingDate(from: payload) {
        case let .found(date):
            readingDate = date
        case .rejectedDateOnly:
            WatchLogger.shared.log(
                "Invalid snapshot received: no CGM reading timestamp"
                    + " (top-level date is state/snapshot time only — not used as reading)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.completePendingConnectivityTasksOnMain(
                    path: "invalid_no_pending",
                    requiresNoPendingContent: true
                )
            }
            return
        case .missing:
            WatchLogger.shared.log(
                "Invalid snapshot received: no valid CGM reading timestamp"
                    + " (no reading_epoch, glucoseValues samples, or parseable date)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.completePendingConnectivityTasksOnMain(
                    path: "invalid_no_pending",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        // Log using already-decoded readingDate (no extra decode); epoch only when we have it.
        let readingDateEpoch = Int(readingDate.timeIntervalSince1970)
        // C-208-6 (1.7): capture the wall clock here (WC delegate queue) but assign the
        // main-confined property inside the main hop below — the previous direct write raced
        // main-thread reads/clears of the same field.
        let userInfoReceiveWallClock = Date()
        let queueFlushLag = dateValue(from: payload[WatchMessageKeys.transferEnqueuedAt])
            .map { Int(userInfoReceiveWallClock.timeIntervalSince($0)) } ?? -1
        WatchLogger.shared
            .log(
                "event=complication_did_receive_user_info window_id=\(BackgroundTaskWindowCounter.currentOrNil() ?? -1) reading_date_epoch=\(readingDateEpoch) queue_flush_lag_seconds=\(queueFlushLag)"
            )

        // Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
        // state is not populated here (defaults to nil) because no call site currently sets it.
        // If state is ever set during snapshot construction, add it here too — otherwise this
        // fingerprint will always differ from the saved one, defeating dedup for this path.
        let tempSnapshot = TrioComplicationSnapshot(
            glucose: payload[WatchMessageKeys.currentGlucose] as? String ?? "--",
            trend: payload[WatchMessageKeys.trend] as? String ?? "",
            delta: payload[WatchMessageKeys.delta] as? String ?? "",
            readingDate: readingDate,
            date: Date(),
            source: .watchConnectivity,
            sequence: intForWatchMessageKey(WatchMessageKeys.g7Sequence, in: payload)
        )
        if TrioComplicationDataStore.shared.shouldSkipPreDispatch(for: tempSnapshot, handler: "userInfo") {
            DispatchQueue.main.async { [weak self] in
                self?.completePendingConnectivityTasksOnMain(
                    path: "dedup_no_pending",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        DispatchQueue.main.async { @MainActor [self] in
            lastUserInfoReceiveTimestamp = userInfoReceiveWallClock // C-208-6: main-confined write
            // R5d: compute gap BEFORE updating timestamp
            let gap = lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let isSleepGap = gap > 600

            // R5d ordering: when a sleep gap is detected, save the snapshot synchronously
            // so forceWidgetReloadIfStale reads fresh App Group data. Normal-cadence
            // deliveries use the deferred path; shouldUpdate dedup prevents double-writes.
            if isSleepGap {
                saveComplicationSnapshot(from: payload)
            }

            if pendingConnectivityTasks.isEmpty {
                let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
                WatchLogger.shared
                    .log(
                        "event=complication_userinfo_no_pending_tasks window_id=\(wid) reading_date_epoch=\(readingDateEpoch) note=race_or_foreground"
                    )
                scheduleUIUpdate(
                    with: payload,
                    fromUserInfo: true,
                    userInfoReceiveTimestamp: lastUserInfoReceiveTimestamp,
                    pendingConnectivityCompletionPath: "fast"
                )
            } else {
                pendingData.merge(payload) { _, new in new }
                quietWindowWorkItem?.cancel()
                finalizeWorkItem?.cancel()
                let receiveTs = lastUserInfoReceiveTimestamp
                let work = DispatchWorkItem { [self] in
                    finalizePendingData(
                        fromUserInfo: true,
                        userInfoReceiveTimestamp: receiveTs,
                        pendingConnectivityCompletionPath: "fast"
                    )
                }
                quietWindowWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }

            // R5d: update timestamp AFTER save
            lastDataReceivedAt = Date()

            // R5d: sleep-gap forced reload (snapshot already saved synchronously above)
            if isSleepGap {
                let gapDisplay = gap.isInfinite ? "first_receive" : "\(Int(gap))"
                WatchLogger.shared.log("💤 sleep_gap_detected gap_seconds=\(gapDisplay)")
                forceWidgetReloadIfStale(receivedGap: gap)
            }
        }
    }

    func session(_: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        WatchLogger.shared.transferFinished(fileTransfer, error: error)
    }

    func session(_: WCSession, didFinish _: WCSessionUserInfoTransfer, error: (any Error)?) {
        // TRIO-025
        if let error = error {
            let attempt = transferRetryCount < maxTransferRetries
                ? "\(transferRetryCount + 1)/\(maxTransferRetries)"
                : "giving_up"
            WatchLogger.shared.warning(.connectivity, "User info transfer to the phone failed (retry \(attempt))", error: error)

            if transferRetryCount < maxTransferRetries {
                transferRetryCount += 1
                let retryDelay = TimeInterval(transferRetryCount * 2)

                retryWorkItem?.cancel()
                retryWorkItem = DispatchWorkItem { [weak self] in
                    self?.requestWatchStateUpdateRespectingStartupGraceOnMain()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retryWorkItem!)
            } else {
                transferRetryCount = 0
                // C-208-6 (1.7): this delegate runs on the WC queue; the fallback reads
                // main-confined attribution state before its own internal main hop.
                DispatchQueue.main.async {
                    self.loadFallbackDataFromComplication()
                }
            }
        } else {
            transferRetryCount = 0
            WatchLogger.shared.debug(.connectivity, "userinfo_transfer_finished outcome=success")
        }
    }

    /// Called when the reachability status of the paired iPhone changes
    /// Updates the local reachability status
    func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        DispatchQueue.main.async {
            self.handleReachabilityChange(isReachable: isReachable)
        }
    }

    /// Reachability flips on every wrist raise, so this must leave entries in progress alone:
    /// clearing `bolusAmount` here turned a confirmed bolus into a 0 U request.
    /// The main view resets the entry fields when it appears.
    func handleReachabilityChange(isReachable: Bool) {
        if WatchLogger.shared.shouldLog("reachability", state: "\(isReachable)") {
            WatchLogger.shared.debug(.connectivity, "Phone reachable: \(isReachable)")
        }

        self.isReachable = isReachable

        if isReachable, isColdStart, !forcedSinceActivation {
            _ = forceConditionalWatchStateUpdate()
        }
    }

    // R4: applicationContext safety net — parallel delivery channel from iOS during budget exhaustion.
    // R5d: integrated sleep-gap detection (same three-constraint ordering as didReceiveUserInfo).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        WatchLogger.shared.log("📦 didReceiveApplicationContext")
        guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else {
            return
        }
        let readingResolution = resolveEffectiveCGMReadingDate(from: payload)
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self else { return }
            self.applyG7ActiveSensorNameFromWatchPayloadIfPresent(payload)
            let gap = self.lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            self.saveComplicationSnapshot(from: payload)
            if case .found = readingResolution {
                self.scheduleUIUpdate(with: payload)
            }
            self.lastDataReceivedAt = Date()
            if gap > 600 {
                let gapDisplay = gap.isInfinite ? "first_receive" : "\(Int(gap))"
                WatchLogger.shared.log("💤 sleep_gap_detected_context gap_seconds=\(gapDisplay)")
                self.forceWidgetReloadIfStale(receivedGap: gap)
            }
            let completionPath: String
            let requiresNoPendingContent: Bool
            switch readingResolution {
            case .found:
                completionPath = "application_context"
                requiresNoPendingContent = false
            case .rejectedDateOnly, .missing:
                completionPath = "application_context_invalid"
                requiresNoPendingContent = true
            }
            self.completePendingConnectivityTasksOnMain(
                path: completionPath,
                requiresNoPendingContent: requiresNoPendingContent,
                recordMarkerWithoutPendingTasks: !requiresNoPendingContent
            )
        }
    }

    /// Conditionally triggers a watch state update if the last known update was too long ago or has never occurred.
    ///
    /// Shows a syncing animation and requests a new watch state update from the iPhone app when
    ///  - there has never been an update (once per activation), or
    ///  - more than 15 seconds have passed since the last one, or the app is in its cold-start window.
    ///
    /// Suppressed during the startup grace period and while the first deferred refresh is in flight.
    @discardableResult
    private func forceConditionalWatchStateUpdate() -> Bool {
        assert(Thread.isMainThread, "forceConditionalWatchStateUpdate must be called on main thread")
        if shouldSuppressStartupSignalOnMain() {
            logStartupSignalSuppressedOnMain()
            return false
        }

        guard !startupFirstRefreshInFlight else {
            return false
        }

        guard let lastUpdateTimestamp = lastWatchStateUpdate else {
            guard !hasRequestedInitialUpdate else { return false }
            hasRequestedInitialUpdate = true
            WatchLogger.shared.debug(.data, "No watch state yet, requesting one")
            showSyncingAnimation = true
            requestWatchStateUpdate()
            forcedSinceActivation = true
            return true
        }

        let now = Date()
        let secondsSinceUpdate = now.timeIntervalSince(lastUpdateTimestamp)

        if secondsSinceUpdate > 15 || isColdStart {
            WatchLogger.shared.debug(.data, "Watch state \(Int(secondsSinceUpdate)) s old, requesting update")
            showSyncingAnimation = true
            requestWatchStateUpdate()
            forcedSinceActivation = true
            return true
        }

        return false
    }

    private func connectivitySessionHasPendingContent() -> Bool {
        if let session {
            return session.hasContentPending
        }
        guard WCSession.isSupported() else { return false }
        return WCSession.default.hasContentPending
    }

    private func canonicalConnectivityTerminalPath(_ path: String) -> String {
        var basePath = path
        let suffix = "_late_task"
        while basePath.hasSuffix(suffix) {
            basePath.removeLast(suffix.count)
        }
        return basePath.isEmpty ? path : basePath
    }

    private func clearDeferredConnectivityCompletionRetryOnMain() {
        assert(Thread.isMainThread, "clearDeferredConnectivityCompletionRetryOnMain must be called on main thread")
        deferredConnectivityCompletionWorkItem?.cancel()
        deferredConnectivityCompletionWorkItem = nil
        deferredConnectivityCompletionDeadline = nil
        deferredConnectivityCompletionPath = nil
        deferredConnectivityCompletionAttempt = 0
    }

    private func scheduleDeferredConnectivityCompletionRetryOnMain(path: String) {
        assert(Thread.isMainThread, "scheduleDeferredConnectivityCompletionRetryOnMain must be called on main thread")

        guard !pendingConnectivityTasks.isEmpty else {
            clearDeferredConnectivityCompletionRetryOnMain()
            return
        }

        let now = Date()
        if deferredConnectivityCompletionPath != path {
            deferredConnectivityCompletionWorkItem?.cancel()
            deferredConnectivityCompletionWorkItem = nil
            deferredConnectivityCompletionPath = path
            deferredConnectivityCompletionDeadline = now.addingTimeInterval(connectivityDeferredRetryBudgetSeconds)
            deferredConnectivityCompletionAttempt = 0
        } else if deferredConnectivityCompletionWorkItem != nil {
            return
        }

        let attempt = deferredConnectivityCompletionAttempt + 1
        let delay = min(
            connectivityDeferredRetryInitialDelaySeconds * pow(2.0, Double(max(attempt - 1, 0))),
            connectivityDeferredRetryMaxDelaySeconds
        )

        deferredConnectivityCompletionWorkItem?.cancel()
        let work = DispatchWorkItem { [self] in
            deferredConnectivityCompletionWorkItem = nil
            deferredConnectivityCompletionAttempt = attempt

            guard !pendingConnectivityTasks.isEmpty else {
                clearDeferredConnectivityCompletionRetryOnMain()
                return
            }

            let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
            if !connectivitySessionHasPendingContent() {
                WatchLogger.shared.log(
                    "event=complication_bgtask_completion_retry_ready path=\(path)"
                        + " window_id=\(wid)"
                        + " attempt=\(attempt)"
                        + " pending_content=false"
                )
                _ = completePendingConnectivityTasksOnMain(
                    path: path,
                    requiresNoPendingContent: true
                )
                return
            }

            guard let deadline = deferredConnectivityCompletionDeadline,
                  Date() < deadline
            else {
                WatchLogger.shared.log(
                    "event=complication_bgtask_completion_retry_expired path=\(path)"
                        + " window_id=\(wid)"
                        + " attempt=\(attempt)"
                        + " pending_count=\(pendingConnectivityTasks.count)"
                        + " pending_content=true"
                )
                clearDeferredConnectivityCompletionRetryOnMain()
                return
            }

            WatchLogger.shared.log(
                "event=complication_bgtask_completion_retry_pending path=\(path)"
                    + " window_id=\(wid)"
                    + " attempt=\(attempt)"
                    + " pending_count=\(pendingConnectivityTasks.count)"
                    + " pending_content=true"
            )
            scheduleDeferredConnectivityCompletionRetryOnMain(path: path)
        }
        deferredConnectivityCompletionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recentConnectivityTerminalBasePathOnMain() -> String? {
        assert(Thread.isMainThread, "recentConnectivityTerminalBasePathOnMain must be called on main thread")

        guard let terminalAt = lastConnectivityTerminalAt,
              let terminalPath = lastConnectivityTerminalPath else { return nil }

        guard Date().timeIntervalSince(terminalAt) <= connectivityLateTaskWindowSeconds else {
            lastConnectivityTerminalAt = nil
            lastConnectivityTerminalPath = nil
            return nil
        }

        return terminalPath
    }

    @discardableResult
    private func completePendingConnectivityTasksOnMain(
        path: String,
        requiresNoPendingContent: Bool = false,
        recordMarkerWithoutPendingTasks: Bool = false
    ) -> Int {
        assert(Thread.isMainThread, "completePendingConnectivityTasksOnMain must be called on main thread")

        let pendingCount = pendingConnectivityTasks.count
        let hasPendingContent = connectivitySessionHasPendingContent()
        if requiresNoPendingContent, hasPendingContent {
            let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
            WatchLogger.shared.log(
                "event=complication_bgtask_completion_deferred path=\(path)"
                    + " window_id=\(wid)"
                    + " task_type=WKWatchConnectivityRefreshBackgroundTask"
                    + " pending_count=\(pendingCount)"
                    + " pending_content=true"
            )
            if pendingCount > 0 {
                scheduleDeferredConnectivityCompletionRetryOnMain(path: path)
            }
            return 0
        }

        // Successful terminal paths need a short-lived marker even when the task
        // arrives after processing completed. Guarded/no-pending paths use
        // requiresNoPendingContent instead.
        if pendingCount > 0 || requiresNoPendingContent || recordMarkerWithoutPendingTasks {
            lastConnectivityTerminalAt = Date()
            lastConnectivityTerminalPath = canonicalConnectivityTerminalPath(path)
        }

        guard pendingCount > 0 else {
            let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
            if recordMarkerWithoutPendingTasks {
                WatchLogger.shared.log(
                    "event=complication_bgtask_terminal_marker path=\(canonicalConnectivityTerminalPath(path))"
                        + " window_id=\(wid)"
                        + " pending_count=0"
                )
            }
            return 0
        }

        let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
        WatchLogger.shared.log(
            "event=complication_bgtask_completing path=\(path)"
                + " window_id=\(wid)"
                + " task_type=WKWatchConnectivityRefreshBackgroundTask"
                + " completed_count=\(pendingCount)"
                + " pending_content=\(hasPendingContent)"
                + " 📡 BGTask completing (\(path)) window_id=\(wid) count=\(pendingCount)"
        )

        clearDeferredConnectivityCompletionRetryOnMain()

        // Keep `false` here: complication freshness is driven by the save/reload path,
        // and changing snapshot semantics is outside the scope of this task-lifecycle fix.
        for task in pendingConnectivityTasks {
            task.setTaskCompletedWithSnapshot(false)
        }
        pendingConnectivityTasks.removeAll()
        return pendingCount
    }

    /// Phase C — sync G7 sensor identity from iPhone watch payload into `G7WatchSensorAdapter`.
    ///
    /// **Freshness gate (P1 fix):** patch 13 sends `g7_active_sensor_name` on every state
    /// payload (using `""` when no G7 is active). WatchConnectivity is best-effort and can
    /// deliver an older queued userInfo / message *after* a newer payload has already updated
    /// the watch's view of the phone state. Without gating, the older payload's stale sensor
    /// name (possibly empty after a swap, or the previous identity) would force a rescan via
    /// `setActiveSensorName(oldName/nil)` and reset BLE session state.
    ///
    /// Gate by `WatchMessageKeys.date` (payload build time on the phone — documented as
    /// "BUILD TIME, not CGM reading time"). Only apply identity changes when the incoming
    /// build-time is at least as new as the last applied one. Payloads without a parseable
    /// `date` fall through and apply (defensive — keeps cold-start / malformed-payload paths
    /// from silently dropping identity sync; the inner `name != knownSensorName` check in
    /// `applyNewSensorName` is the no-op guard for redundant re-applies).
    @MainActor
    private func applyG7ActiveSensorNameFromWatchPayloadIfPresent(_ payload: [String: Any]) {
        guard payload[WatchMessageKeys.g7ActiveSensorName] != nil else { return }

        let payloadDate = dateValue(from: payload[WatchMessageKeys.date])
        if let payloadDate,
           let lastApplied = lastAppliedG7SensorNamePayloadDate,
           payloadDate < lastApplied
        {
            WatchLogger.shared.log(
                "⚠️ g7_active_sensor_name suppressed: stale_payload"
                    + " payload_date=\(Int(payloadDate.timeIntervalSince1970))"
                    + " last_applied=\(Int(lastApplied.timeIntervalSince1970))"
            )
            return
        }

        let raw = payload[WatchMessageKeys.g7ActiveSensorName]
        let name: String?
        if let s = raw as? String {
            name = s.isEmpty ? nil : s
        } else {
            name = nil
        }

        if let payloadDate { lastAppliedG7SensorNamePayloadDate = payloadDate }

        // C2: pair the name with its activation epoch (Int64 seconds, NSNumber-safe). Absent ⇒ legacy
        // name-only identity; nil name = clear. The adapter runs the accept/quarantine decision.
        if let name {
            // Normalize a 0 epoch to nil (legacy/missing) — the phone omits it when 0, but guard a
            // stray `g7_activation_epoch: 0` from being treated as a real epoch (review low).
            let epoch = ((payload[WatchMessageKeys.g7ActivationEpoch] as? NSNumber)?.int64Value).flatMap { $0 == 0 ? nil : $0 }
            G7WatchSensorAdapter.shared.setActiveSensorIdentity(
                G7WatchSensorAdapter.SensorIdentity(name: name, activationEpochSeconds: epoch)
            )
        } else {
            G7WatchSensorAdapter.shared.setActiveSensorName(nil)
        }
    }

    /// Stores the phone's "upstream G7 watch acquisition" toggle for the adapter, which reads it once
    /// at the next watch app launch. Only acts when the payload carries the key as a Bool.
    private func storeG7WatchAcquisitionArmIfPresent(_ message: [String: Any]) {
        guard let enabled = message[WatchMessageKeys.g7WatchAcquisitionArm] as? Bool else { return }

        let defaults = UserDefaults.standard
        let previous = defaults.bool(forKey: G7WatchSensorAdapter.acquisitionArmDefaultsKey)
        defaults.set(enabled, forKey: G7WatchSensorAdapter.acquisitionArmDefaultsKey)

        if enabled != previous {
            WatchLogger.shared.info(
                .g7,
                "event=g7_acquisition_arm_setting_changed enabled=\(enabled) applies=next_launch"
            )
        }
    }

    private func processWatchMessage(_ message: [String: Any]) {
        DispatchQueue.main.async { @MainActor in
            if let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
               let ackMessage = message[WatchMessageKeys.message] as? String,
               let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String,
               let ackCode = AcknowledgmentCode(rawValue: ackCodeRaw)
            {
                DispatchQueue.main.async {
                    self.showSyncingAnimation = false
                }

                WatchLogger.shared.log("Received acknowledgment: \(ackMessage), success: \(acknowledged)")

                switch ackCode {
                case .savingCarbs:
                    self.isMealBolusCombo = true
                    self.mealBolusStep = .savingCarbs
                    self.showCommsAnimation = true
                    self.handleAcknowledgment(success: acknowledged, message: ackMessage, isFinal: false)
                case .enactingBolus:
                    self.isMealBolusCombo = true
                    self.mealBolusStep = .enactingBolus
                    self.showCommsAnimation = true
                    self.handleAcknowledgment(success: acknowledged, message: ackMessage, isFinal: false)
                case .comboComplete:
                    self.isMealBolusCombo = false
                    self.handleAcknowledgment(success: acknowledged, message: ackMessage, isFinal: true)
                default:
                    self.isMealBolusCombo = false
                    self.handleAcknowledgment(success: acknowledged, message: ackMessage, isFinal: true)
                }
            }

            if let watchStateData = message[WatchMessageKeys.watchState] as? [String: Any] {
                let completionPath = self.pendingConnectivityTasks.isEmpty ? nil : "message"
                self.scheduleUIUpdate(
                    with: watchStateData,
                    fromUserInfo: false,
                    pendingConnectivityCompletionPath: completionPath
                )
            }
        }
    }

    /// Accumulate new data, set isSyncing, and debounce final update
    @MainActor
    private func scheduleUIUpdate(
        with newData: [String: Any],
        fromUserInfo: Bool = false,
        userInfoReceiveTimestamp: Date? = nil,
        pendingConnectivityCompletionPath: String? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { @MainActor [self] in
                scheduleUIUpdate(
                    with: newData,
                    fromUserInfo: fromUserInfo,
                    userInfoReceiveTimestamp: userInfoReceiveTimestamp,
                    pendingConnectivityCompletionPath: pendingConnectivityCompletionPath
                )
            }
            return
        }

        applyG7ActiveSensorNameFromWatchPayloadIfPresent(newData)

        guard let incomingDate = dateValue(from: newData[WatchMessageKeys.date]) else {
            WatchLogger.shared.log("Invalid date format in WatchState data")
            if let pendingConnectivityCompletionPath {
                completePendingConnectivityTasksOnMain(
                    path: "\(pendingConnectivityCompletionPath)_invalid",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        if let lastTimestamp = lastWatchStateUpdate,
           incomingDate <= lastTimestamp
        {
            WatchLogger.shared.log("Skipping UI update — outdated WatchState (\(incomingDate))")
            if let pendingConnectivityCompletionPath {
                completePendingConnectivityTasksOnMain(
                    path: "\(pendingConnectivityCompletionPath)_outdated",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        DispatchQueue.main.async {
            self.showSyncingAnimation = true
        }

        WatchLogger.shared.log("Merging new WatchState data with keys: \(newData.keys.joined(separator: ", "))")

        pendingData.merge(newData) { _, newVal in newVal }

        finalizeWorkItem?.cancel()

        let fromUserInfoCapture = fromUserInfo
        let userInfoTsCapture = userInfoReceiveTimestamp
        let completionPathCapture = pendingConnectivityCompletionPath
        let workItem = DispatchWorkItem { [self] in
            WatchLogger.shared.log("Debounced update fired")
            self.finalizePendingData(
                fromUserInfo: fromUserInfoCapture,
                userInfoReceiveTimestamp: userInfoTsCapture,
                pendingConnectivityCompletionPath: completionPathCapture
            )
        }
        finalizeWorkItem = workItem
        let delay: TimeInterval = isColdStart ? 0.2 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Apply any buffered WC payload to UI state, then fire the **conditional** complication
    /// refresh that a background-task-driven `requestWatchStateUpdate()` is waiting on.
    ///
    /// **Invariant (Bug #6):** `forceComplicationUpdate()` runs at most **once** per pending bgtask,
    /// and only when *fresh* data has actually been applied (we entered this method with a
    /// non-empty `pendingData`). Empty-payload finalizes do **not** trigger the complication
    /// refresh — they simply hide the syncing animation and let the existing complication state
    /// remain. The flag is also auto-cleared when stale (older than `bgTaskComplicationUpdateWindow`).
    private func finalizePendingData(
        fromUserInfo: Bool = false,
        userInfoReceiveTimestamp: Date? = nil,
        pendingConnectivityCompletionPath: String? = nil
    ) {
        guard !pendingData.isEmpty else {
            WatchLogger.shared.log("finalizePendingData called with empty data")

            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            if let pendingConnectivityCompletionPath {
                completePendingConnectivityTasksOnMain(
                    path: "\(pendingConnectivityCompletionPath)_empty",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        WatchLogger.shared.log("Finalizing pending data")

        processRawDataForWatchState(pendingData, fromUserInfo: fromUserInfo, userInfoReceiveTimestamp: userInfoReceiveTimestamp)
        pendingData.removeAll()

        DispatchQueue.main.async {
            self.showSyncingAnimation = false
        }

        WatchLogger.shared.log("Watch UI update complete")

        // Consume the bgtask-driven complication-update flag once fresh data has been applied.
        // Stale flags (older than `bgTaskComplicationUpdateWindow`) are dropped silently so a
        // foreground refresh long after a failed bgtask cannot trigger a spurious complication
        // update.
        if let bgTaskRequestedAt = pendingBgTaskComplicationUpdateAt {
            pendingBgTaskComplicationUpdateAt = nil
            if Date().timeIntervalSince(bgTaskRequestedAt) <= bgTaskComplicationUpdateWindow {
                forceComplicationUpdate()
            } else {
                WatchLogger.shared.log("🔄 bgtask complication update flag expired; skipping forceComplicationUpdate")
            }
        }

        guard let pendingConnectivityCompletionPath else { return }
        let pendingCountBeforeCompletion = pendingConnectivityTasks.count
        let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
        if pendingCountBeforeCompletion > 0 {
            WatchLogger.shared.log("event=complication_finalize_begin window_id=\(wid) pending_count=\(pendingCountBeforeCompletion)")
        } else {
            WatchLogger.shared.log(
                "event=complication_finalize_no_pending_tasks window_id=\(wid)"
                    + " path=\(pendingConnectivityCompletionPath)"
            )
        }
        let clearedCount = completePendingConnectivityTasksOnMain(
            path: pendingConnectivityCompletionPath,
            recordMarkerWithoutPendingTasks: true
        )
        if clearedCount > 0 {
            WatchLogger.shared.log("event=complication_finalize_end window_id=\(wid) cleared_count=\(clearedCount)")
        }
    }

    /// Updates the UI properties
    private func processRawDataForWatchState(_ message: [String: Any], fromUserInfo: Bool = false, userInfoReceiveTimestamp: Date? = nil) {
        WatchLogger.shared.log("Processing raw WatchState data with keys: \(message.keys.joined(separator: ", "))")

        startupFirstRefreshInFlight = false

        syncTimeoutWorkItem?.cancel()
        syncTimeoutWorkItem = nil

        let effectiveReading = resolveEffectiveCGMReadingDate(from: message)
        let sequence = intForWatchMessageKey(WatchMessageKeys.g7Sequence, in: message)

        let shouldApplyCGMFields: Bool
        if case let .found(readingDate) = effectiveReading {
            shouldApplyCGMFields = tryAttributeDisplayedReadingSource(
                .watchConnectivity,
                forReadingDate: readingDate,
                sequence: sequence
            )
        } else {
            shouldApplyCGMFields = (displayedReadingAttributedForDate == nil)
        }

        // Apply glucose color settings + display units pushed by the phone (build 205 / P2). Unconditional
        // (settings, not a CGM reading) and cached by the computer in UserDefaults so colors survive a
        // restart before the first payload arrives.
        applyColorSettingsFromPayloadIfPresent(message)
        applyGlucoseBobbleComplicationInputsFromPayload(message)

        if shouldApplyCGMFields {
            if let currentGlucose = message[WatchMessageKeys.currentGlucose] as? String {
                self.currentGlucose = currentGlucose
            }

            // currentGlucoseMgDl is the canonical reading; the bubble color is computed locally (P2/W5).
            // Validity-gated (>= 25) so a sentinel/decode-failure never bakes a (low) color. Missing ⇒
            // leave currentGlucoseColorString at its prior value (default white) — never red for no data.
            if let mgDlNumber = message[WatchMessageKeys.currentGlucoseMgDl] as? NSNumber, mgDlNumber.intValue >= 25 {
                let mgDl = mgDlNumber.intValue
                currentGlucoseMgDl = mgDl
                currentGlucoseColorString = WatchGlucoseColorComputer.shared.bubbleColorHex(for: mgDl)
            } else {
                currentGlucoseMgDl = nil
                // No valid current reading ⇒ neutral bubble; never leave a stale (possibly red) color (review #4).
                currentGlucoseColorString = "#ffffff"
            }

            if let trend = message[WatchMessageKeys.trend] as? String {
                self.trend = trend
            }

            if let delta = message[WatchMessageKeys.delta] as? String {
                self.delta = delta
            }
        }

        // lastWatchStateUpdate uses WatchMessageKeys.date (delivery/snapshot time), not CGM reading time.
        // BLE/HK paths set it from readingDate. The 15s fallback guard uses this field — semantics differ per channel.
        if let date = dateValue(from: message[WatchMessageKeys.date]) {
            lastWatchStateUpdate = date
            forcedSinceActivation = false
        }

        if let iob = message[WatchMessageKeys.iob] as? String {
            self.iob = iob
        }

        if let cob = message[WatchMessageKeys.cob] as? String {
            self.cob = cob
        }

        if let lastLoopTime = message[WatchMessageKeys.lastLoopTime] as? String {
            self.lastLoopTime = lastLoopTime
        }

        if let glucoseData = message[WatchMessageKeys.glucoseValues] as? [[String: Any]] {
            // P2: canonical mg/dL entries (no color). Decode via the single StoredGlucoseReading path,
            // batch-insert into the rolling history store (W1), then rebuild the chart from the store
            // so it carries the full 24h window, not just this payload's ~2h (P1).
            let readings = glucoseData.compactMap { StoredGlucoseReading.from(wcEntry: $0, source: "wc") }
            WatchGlucoseHistoryStore.shared.insert(readings)
            glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
                colorComputer: WatchGlucoseColorComputer.shared
            )
        }

        if let minYAxisValue = message[WatchMessageKeys.minYAxisValue],
           let decimalValue = (minYAxisValue as? NSNumber)?.decimalValue
        {
            self.minYAxisValue = decimalValue
        }

        if let maxYAxisValue = message[WatchMessageKeys.maxYAxisValue],
           let decimalValue = (maxYAxisValue as? NSNumber)?.decimalValue
        {
            self.maxYAxisValue = decimalValue
        }

        if let overrideData = message[WatchMessageKeys.overridePresets] as? [[String: Any]] {
            overridePresets = overrideData.compactMap { data in
                guard let name = data["name"] as? String,
                      let isEnabled = data["isEnabled"] as? Bool
                else { return nil }
                return OverridePresetWatch(name: name, isEnabled: isEnabled)
            }
        }

        if let tempTargetData = message[WatchMessageKeys.tempTargetPresets] as? [[String: Any]] {
            tempTargetPresets = tempTargetData.compactMap { data in
                guard let name = data["name"] as? String,
                      let isEnabled = data["isEnabled"] as? Bool
                else { return nil }
                return TempTargetPresetWatch(name: name, isEnabled: isEnabled)
            }
        }

        if let maxBolusValue = message[WatchMessageKeys.maxBolus],
           let decimalValue = (maxBolusValue as? NSNumber)?.decimalValue
        {
            maxBolus = decimalValue
        }

        if let maxCarbsValue = message[WatchMessageKeys.maxCarbs],
           let decimalValue = (maxCarbsValue as? NSNumber)?.decimalValue
        {
            maxCarbs = decimalValue
        }

        if let maxFatValue = message[WatchMessageKeys.maxFat],
           let decimalValue = (maxFatValue as? NSNumber)?.decimalValue
        {
            maxFat = decimalValue
        }

        if let maxProteinValue = message[WatchMessageKeys.maxProtein],
           let decimalValue = (maxProteinValue as? NSNumber)?.decimalValue
        {
            maxProtein = decimalValue
        }

        if let bolusIncrement = message[WatchMessageKeys.bolusIncrement],
           let decimalValue = (bolusIncrement as? NSNumber)?.decimalValue
        {
            // limit minimum to 0.05 to avoid dealing with 0.025 increments
            self.bolusIncrement = max(decimalValue, 0.05)
        }

        if let confirmBolusFaster = message[WatchMessageKeys.confirmBolusFaster] as? Bool {
            self.confirmBolusFaster = confirmBolusFaster
        }

        // Build 205 / W3: cache IOB/COB/lastLoopTime keyed to lastWatchStateUpdate (the phone's
        // WatchState build time), so a cold open within 30 min restores them. Caching the build time
        // (not Date()) preserves correct staleness — a payload built 20 min ago stays 20 min old.
        UserDefaults.standard.set(iob, forKey: "WatchState.cachedIOB")
        UserDefaults.standard.set(cob, forKey: "WatchState.cachedCOB")
        UserDefaults.standard.set(lastLoopTime, forKey: "WatchState.cachedLastLoopTime")
        UserDefaults.standard.set(lastWatchStateUpdate?.timeIntervalSince1970, forKey: "WatchState.cachedWCTimestamp")

        // Forecast fields must be applied on the raw-data path, not in
        // saveComplicationSnapshot: that function returns early on the
        // pre-dispatch complication dedup, which normally fires for the
        // full-state payload (the phone sends a complication-only payload
        // first), so the forecast would be dropped on most cycles.
        if let showForecast = message[WatchMessageKeys.showForecastWatch] as? Bool {
            self.showForecast = showForecast
        }

        if let isForecastCone = message[WatchMessageKeys.isForecastCone] as? Bool {
            self.isForecastCone = isForecastCone
        }

        if let snoozeTimestamp = message[WatchMessageKeys.snoozeUntilDate] as? TimeInterval {
            snoozeUntilDate = Date(timeIntervalSince1970: snoozeTimestamp)
        }

        if let forecastPayload = message[WatchMessageKeys.forecastData] as? [String: Any] {
            if let startTimestamp = forecastPayload[WatchMessageKeys.forecastStartDate] as? TimeInterval {
                forecastStartDate = Date(timeIntervalSince1970: startTimestamp)
            }
            forecastConeMin = forecastPayload[WatchMessageKeys.forecastConeMin] as? [Double] ?? []
            forecastConeMax = forecastPayload[WatchMessageKeys.forecastConeMax] as? [Double] ?? []
            forecastLines = forecastPayload[WatchMessageKeys.forecastLines] as? [String: [Double]] ?? [:]
        }

        saveComplicationSnapshot(from: message, fromUserInfo: fromUserInfo, userInfoReceiveTimestamp: userInfoReceiveTimestamp)

        storeG7WatchAcquisitionArmIfPresent(message)
        DispatchQueue.main.async { @MainActor in
            G7WatchSensorAdapter.shared.noteAcquisitionWake(reason: "phone_context")
        }

        emitResidentMemorySample(
            checkpoint: "first_watch_state_apply",
            activationSequence: startupCurrentActivationSequence
        )
    }

    // fork — Phase C: parse the Glucose Bobble inputs from any payload shape and persist them. Called at
    // the top of both processRawDataForWatchState and saveComplicationSnapshot (like the colour settings),
    // because the background application-context and sleep-gap paths save the snapshot — and so reload
    // the complication — before processRawDataForWatchState runs. The background channels carry
    // lastLoopDate in their allowlisted subset but not lastLoopTime, so take the date whenever it is
    // present; clear it only on a full watch-state message (lastLoopTime present) that omits it, which is
    // how the phone says "no loop in a day".
    private func applyGlucoseBobbleComplicationInputsFromPayload(_ message: [String: Any]) {
        if let lastLoopEpoch = message[WatchMessageKeys.lastLoopDate] as? TimeInterval {
            lastLoopDate = Date(timeIntervalSince1970: lastLoopEpoch)
        } else if message[WatchMessageKeys.lastLoopTime] != nil {
            lastLoopDate = nil
        }

        if let settingsData = message[WatchMessageKeys.glucoseBobbleComplicationSettings] as? Data,
           let decodedSettings = try? JSONDecoder().decode(GlucoseBobbleComplicationSettings.self, from: settingsData)
        {
            glucoseBobbleComplicationSettings = decodedSettings
        }

        publishGlucoseBobbleComplicationInputs()
    }

    // fork — Phase C: persist the phone-configured Glucose Bobble settings and last loop date to
    // the App Group so the circular complication (a separate process, reading them back through
    // GlucoseComplicationSnapshot) picks them up. A new loop date rides the store's next reading-driven
    // reload (loops follow readings), so only a settings change — rare — spends an extra reload, and
    // only on the circular complication's kind.
    private func publishGlucoseBobbleComplicationInputs() {
        if lastLoopDate != GlucoseComplicationSnapshot.storedLastLoopDate() {
            GlucoseComplicationSnapshot.storeLastLoopDate(lastLoopDate)
        }

        if let glucoseBobbleComplicationSettings,
           glucoseBobbleComplicationSettings != GlucoseBobbleComplicationSettings.load()
        {
            glucoseBobbleComplicationSettings.save()
            WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.glucoseBobbleComplicationKind)
        }
    }

    /// Build 205 / review #5: apply the phone's glucose color settings + display units to the color
    /// computer when present in the payload. Called from both `processRawDataForWatchState` and
    /// `saveComplicationSnapshot` so a background complication bake never uses stale cached settings
    /// after a threshold/scheme change. No-op when the payload doesn't carry the settings.
    private func applyColorSettingsFromPayloadIfPresent(_ message: [String: Any]) {
        guard let low = (message[WatchMessageKeys.lowGlucoseThreshold] as? NSNumber)?.intValue,
              let high = (message[WatchMessageKeys.highGlucoseThreshold] as? NSNumber)?.intValue,
              let target = (message[WatchMessageKeys.glucoseTarget] as? NSNumber)?.intValue
        else { return }
        let dynamic = (message[WatchMessageKeys.glucoseColorSchemeDynamic] as? NSNumber)?.boolValue ?? false
        let unitsRaw = (message[WatchMessageKeys.units] as? String) ?? WatchGlucoseColorComputer.shared.cachedUnitsRaw
        WatchGlucoseColorComputer.shared.apply(low: low, high: high, target: target, dynamic: dynamic, unitsRaw: unitsRaw)
    }

    private func saveComplicationSnapshot(from message: [String: Any], fromUserInfo: Bool = false, userInfoReceiveTimestamp: Date? = nil) {
        WatchLogger.shared.log("📸 saveComplicationSnapshot called with keys: \(message.keys.joined(separator: ", "))")

        // Ensure the bake below uses the freshest settings even on a complication-only path that didn't
        // run processRawDataForWatchState (review #5).
        applyColorSettingsFromPayloadIfPresent(message)
        // fork — Phase C: same for the Glucose Bobble inputs, so the reload this save triggers sees them.
        applyGlucoseBobbleComplicationInputsFromPayload(message)

        // R3: effective CGM reading time (shared resolver; see `resolveEffectiveCGMReadingDate`)
        let readingDate: Date
        switch resolveEffectiveCGMReadingDate(from: message) {
        case let .found(date):
            readingDate = date
        case .rejectedDateOnly:
            WatchLogger.shared.log(
                "⚠️ saveComplicationSnapshot: no reading_epoch or glucoseValues;"
                    + " top-level date is state snapshot time only — refusing as CGM reading — skipping save"
            )
            return
        case .missing:
            WatchLogger.shared.log(
                "📸 saveComplicationSnapshot SKIPPED: no valid CGM reading timestamp"
                    + " (no reading_epoch, glucoseValues, or parseable date)"
            )
            return
        }

        let glucoseValue = message[WatchMessageKeys.currentGlucose] as? String ?? currentGlucose
        let trendValue = message[WatchMessageKeys.trend] as? String ?? trend ?? ""
        let deltaValue = message[WatchMessageKeys.delta] as? String ?? delta ?? ""
        // Bake the bubble hex from currentGlucoseMgDl + cached color settings (build 205 / P2 + W5).
        // Missing/invalid (< 25) ⇒ nil (never a baked color, never red); the widget falls back on nil.
        let glucoseColorValue: String? = {
            if let mgDlNumber = message[WatchMessageKeys.currentGlucoseMgDl] as? NSNumber, mgDlNumber.intValue >= 25 {
                return WatchGlucoseColorComputer.shared.bubbleColorHex(for: mgDlNumber.intValue)
            }
            return nil
        }()
        // fork — same gating as glucoseColorValue above, chart/scheme colour instead of the bubble colour.
        let chartGlucoseColorValue: String? = {
            if let mgDlNumber = message[WatchMessageKeys.currentGlucoseMgDl] as? NSNumber, mgDlNumber.intValue >= 25 {
                return WatchGlucoseColorComputer.shared.chartColorHex(for: mgDlNumber.intValue)
            }
            return nil
        }()

        WatchLogger.shared.log("📸 Saving snapshot: glucose=\(glucoseValue), trend=\(trendValue), delta=\(deltaValue), readingDate=\(readingDate)")
        WatchLogger.shared
            .log(
                "🔍 Debug: glucoseValue source - message: \(message[WatchMessageKeys.currentGlucose] as? String ?? "nil"), currentGlucose: \(currentGlucose)"
            )

        let snapshot = TrioComplicationSnapshot(
            glucose: glucoseValue,
            trend: trendValue,
            delta: deltaValue,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: glucoseColorValue,
            source: .watchConnectivity,
            sequence: intForWatchMessageKey(WatchMessageKeys.g7Sequence, in: message),
            // fork — bake the chart/scheme colour alongside the bubble colour.
            chartGlucoseColor: chartGlucoseColorValue
        )

        // Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
        if TrioComplicationDataStore.shared.shouldSkipPreDispatch(for: snapshot, handler: "message") {
            return
        }

        TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)
        lastPhoneEGVDate = readingDate // C-210-4: phone-path freshness for direct-BLE stall detection

        // R5c — log decode latency and reading_epoch for the payload we just saved (avoids misattribution when overlapping userInfo deliveries).
        // Use only the threaded userInfoReceiveTimestamp; no fallback to instance state so attribution stays unambiguous.
        if fromUserInfo, let start = userInfoReceiveTimestamp {
            let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
            let readingEpoch = Int(readingDate.timeIntervalSince1970)
            WatchLogger.shared.log("⏱️ userInfo_decoded reading_epoch=\(readingEpoch) decode_ms=\(decodeMs)")
        }
        if fromUserInfo {
            lastUserInfoReceiveTimestamp = nil
        }
    }

    func forceComplicationUpdate() {
        WatchLogger.shared.log("🔄 forceComplicationUpdate called")

        guard !currentGlucose.isEmpty,
              !currentGlucose.contains("??"),
              !currentGlucose.localizedCaseInsensitiveContains("error")
        else {
            WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: invalid glucose '\(currentGlucose)'")
            return
        }

        if let glucoseValue = Double(currentGlucose.replacingOccurrences(of: " mg/dL", with: "")) {
            // `currentGlucose` is the phone-formatted DISPLAY string, so the sanity bounds must be
            // unit-aware — mmol/L (~2.2–22.2) would otherwise fail the mg/dL 40–400 range and skip the
            // refresh for mmol/L users (review #2).
            let isMmolL = WatchGlucoseColorComputer.shared.isMmolL
            let lowerBound = isMmolL ? 2.0 : 40.0
            let upperBound = isMmolL ? 22.5 : 400.0
            guard glucoseValue >= lowerBound, glucoseValue <= upperBound else {
                WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: glucose out of range")
                return
            }
        }

        guard let effectiveReadingDate = TrioComplicationDataStore.lastValidTimestamp else {
            WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: no valid CGM reading timestamp")
            return
        }

        let snapshot = TrioComplicationSnapshot(
            glucose: currentGlucose,
            trend: trend ?? "",
            delta: delta ?? "",
            readingDate: effectiveReadingDate,
            date: Date(),
            // Bake the locally-computed bubble hex only when we have a valid mg/dL; nil otherwise (never red).
            glucoseColor: currentGlucoseMgDl != nil ? currentGlucoseColorString : nil,
            source: displayedReadingSource,
            sequence: displayedReadingAttributedSequence,
            // fork — same gating as glucoseColor above, chart/scheme colour instead of the bubble colour.
            chartGlucoseColor: currentGlucoseMgDl.map { WatchGlucoseColorComputer.shared.chartColorHex(for: $0) }
        )

        WatchLogger.shared.log("🔄 forceComplicationUpdate: glucose=\(currentGlucose), readingDate=\(effectiveReadingDate)")

        TrioComplicationDataStore.shared.save(snapshot, triggerReload: false)
        TrioComplicationDataStore.shared.forceReload(scheduleRetry: false)
    }

    /// R5d: after a detected sleep gap, force a widget reload. Rate-limited to 5 minutes.
    /// Stale-backlog detection is diagnostic only — the reload always fires.
    private func forceWidgetReloadIfStale(receivedGap: TimeInterval) {
        let store = TrioComplicationDataStore.shared

        // Rate limiter: 5-minute minimum between forced reloads
        if let lastReload = store.lastWidgetReloadAt(),
           Date().timeIntervalSince(lastReload) < 300
        {
            WatchLogger.shared
                .log("💤 sleep_gap_reload_skipped reason=rate_limited last_reload_ago=\(Int(Date().timeIntervalSince(lastReload)))s")
            return
        }

        // Diagnostic snapshot read: measures I/O latency and detects stale-backlog scenarios.
        // No snapshot-age guard — callers save before calling this, so latestSnapshot() reflects
        // just-saved data. A freshness guard would block the reload in precisely the scenario
        // this function exists for. The rate limiter above is the correct storm guard.
        let readStart = CFAbsoluteTimeGetCurrent()
        let snapshot = store.latestSnapshot()
        let snapshotReadMs = Int((CFAbsoluteTimeGetCurrent() - readStart) * 1000)
        let snapshotEpoch = snapshot.map { Int($0.readingDate.timeIntervalSince1970) } ?? -1
        let snapshotAgeSeconds = snapshot.map { Int(Date().timeIntervalSince($0.readingDate)) }
        let snapshotAgeDisplay = snapshotAgeSeconds.map { "\($0)s" } ?? "no_snapshot"
        let gapDisplay = receivedGap.isInfinite ? "first_receive" : "\(Int(receivedGap))"

        let isStaleBacklog: Bool
        if let age = snapshotAgeSeconds, !receivedGap.isInfinite {
            isStaleBacklog = age > Int(receivedGap - 60)
        } else {
            isStaleBacklog = true
        }
        if isStaleBacklog {
            WatchLogger.shared
                .log(
                    "⚠️ sleep_gap_reload_stale_backlog reading_epoch=\(snapshotEpoch) snapshot_age=\(snapshotAgeDisplay) gap=\(gapDisplay)s read_ms=\(snapshotReadMs)"
                )
        } else {
            WatchLogger.shared
                .log(
                    "💤 sleep_gap_reload_firing reading_epoch=\(snapshotEpoch) snapshot_age=\(snapshotAgeDisplay) gap=\(gapDisplay)s read_ms=\(snapshotReadMs)"
                )
        }

        store.setLastWidgetReloadAt(Date())
        store.forceReload(scheduleRetry: false)
    }

    #if os(watchOS)
        func scheduleBackgroundRefresh() {
            let hasRecentData = lastWatchStateUpdate != nil &&
                Date().timeIntervalSince(lastWatchStateUpdate!) < 300

            let nextInterval: TimeInterval
            if isReachable {
                nextInterval = hasRecentData ? 300 : 180
            } else {
                nextInterval = hasRecentData ? 900 : 600
            }

            let refreshDate = Date().addingTimeInterval(nextInterval)
            WKExtension.shared().scheduleBackgroundRefresh(withPreferredDate: refreshDate, userInfo: nil) { error in
                if let error = error {
                    WatchLogger.shared.log("Failed to schedule background refresh: \(error)")
                } else {
                    WatchLogger.shared.log("Scheduled background refresh at \(refreshDate)")
                }
            }
        }

        func handleBackgroundTasks(_ tasks: Set<WKRefreshBackgroundTask>) {
            WatchLogger.shared.log("Handling background tasks: \(tasks.count)")

            for task in tasks {
                if let refreshTask = task as? WKApplicationRefreshBackgroundTask {
                    backgroundRefreshCount += 1
                    lastBackgroundRefreshDate = Date()

                    if isReachable {
                        // Defer `forceComplicationUpdate()` to the data-application success path
                        // (`finalizePendingData`) instead of firing unconditionally after 2s. Avoids
                        // refreshing the complication with stale `currentGlucose` when the WC reply
                        // is slow or never arrives — see Bug #6 / `pendingBgTaskComplicationUpdateAt`.
                        let requestedAt = Date()
                        pendingBgTaskComplicationUpdateAt = requestedAt
                        requestWatchStateUpdate()
                        // Stale-flag detector: if `finalizePendingData` never fires within the
                        // window (WC unreachable, dropped reply, retries exhausted), the deferred
                        // complication update is silently skipped. Emit one log line so the
                        // bgtask → complication-update path is observable in telemetry.
                        // The timestamp check ensures we only clear / log our **own** flag —
                        // a later bgtask that re-set the flag with a fresh timestamp is untouched.
                        let window = bgTaskComplicationUpdateWindow
                        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
                            guard let self = self else { return }
                            guard self.pendingBgTaskComplicationUpdateAt == requestedAt else { return }
                            self.pendingBgTaskComplicationUpdateAt = nil
                            WatchLogger.shared.log("⌚️ bgTask complication update skipped: flag stale (no data within \(Int(window))s)")
                        }
                    } else {
                        loadFallbackDataFromComplication()
                        forceComplicationUpdate()
                    }

                    refreshTask.setTaskCompletedWithSnapshot(false)
                    scheduleBackgroundRefresh()
                } else if task is WKWatchConnectivityRefreshBackgroundTask {
                    let (bgTaskWindowId, receivedAt) = BackgroundTaskWindowCounter.next()
                    WatchLogger.shared
                        .log(
                            "event=complication_bgtask_received window_id=\(bgTaskWindowId) task_type=WKWatchConnectivityRefreshBackgroundTask 📡 BGTask received: WKWatchConnectivityRefreshBackgroundTask window_id=\(bgTaskWindowId)"
                        )
                    // Hold until userInfo processing completes (quiet-window or 5s safety timeout). All access on main.
                    // Multiple tasks in one wake are all stored; multiple didReceiveUserInfo reset the 300ms quiet window; last timer runs, then one finalize and complete all. If handle(_:backgroundTasks:) is delivered after the terminal path already fired (userInfo/context first, then task), the short-lived terminal marker rescues the late task; the 5s timeout remains the final fallback.
                    DispatchQueue.main.async { [self] in
                        pendingConnectivityTasks.append(task)
                        let pendingCount = pendingConnectivityTasks.count
                        WatchLogger.shared
                            .log(
                                "event=complication_bgtask_enqueued window_id=\(bgTaskWindowId) task_type=WKWatchConnectivityRefreshBackgroundTask pending_count=\(pendingCount)"
                            )
                        if let terminalPath = recentConnectivityTerminalBasePathOnMain() {
                            let lateCompletionPath = "\(terminalPath)_late_task"
                            let clearedCount = completePendingConnectivityTasksOnMain(
                                path: lateCompletionPath,
                                requiresNoPendingContent: true
                            )
                            if clearedCount > 0 { return }
                        }
                        let taskToComplete = task
                        let windowId = bgTaskWindowId
                        let receivedAtCapture = receivedAt
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [self] in
                            if let idx = pendingConnectivityTasks.firstIndex(where: { $0 === taskToComplete }) {
                                pendingConnectivityTasks.remove(at: idx)
                                if pendingConnectivityTasks.isEmpty {
                                    clearDeferredConnectivityCompletionRetryOnMain()
                                }
                                let completionDelayMs = Int(Date().timeIntervalSince(receivedAtCapture) * 1000)
                                WatchLogger.shared
                                    .log(
                                        "event=complication_bgtask_completing path=timeout window_id=\(windowId) task_type=WKWatchConnectivityRefreshBackgroundTask completion_delay_ms=\(completionDelayMs) completed_count=1 📡 BGTask completing (timeout) window_id=\(windowId)"
                                    )
                                taskToComplete.setTaskCompletedWithSnapshot(false)
                            }
                        }
                    }
                } else {
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
    #endif

    func loadFallbackDataFromComplication() {
        guard let snapshot = TrioComplicationDataStore.shared.latestSnapshot() else {
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        // Don't regress watermark / UI from store if in-memory reading is already newer (matches alignDisplayedReadingAttributionWithComplicationSnapshot).
        if let attributed = displayedReadingAttributedForDate,
           snapshot.readingDate <= attributed
        {
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        if let lastUpdate = lastWatchStateUpdate,
           Date().timeIntervalSince(lastUpdate) <= 15
        {
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        DispatchQueue.main.async {
            // Re-check after deferral: BLE may have advanced the watermark before this block runs.
            if let attributed = self.displayedReadingAttributedForDate,
               snapshot.readingDate <= attributed
            {
                self.showSyncingAnimation = false
                return
            }
            self.currentGlucose = snapshot.glucose
            self.trend = snapshot.trend
            self.delta = snapshot.delta
            if let glucoseColor = snapshot.glucoseColor {
                self.currentGlucoseColorString = glucoseColor
            }
            self.lastWatchStateUpdate = snapshot.readingDate
            self.alignDisplayedReadingAttributionWithComplicationSnapshot(snapshot)
            self.showSyncingAnimation = false
            self.syncTimeoutWorkItem?.cancel()
        }
    }

    private func dateValue(from value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return nil
    }

    private func latestGlucoseDate(from message: [String: Any]) -> Date? {
        guard let glucoseData = message[WatchMessageKeys.glucoseValues] as? [[String: Any]] else {
            return nil
        }

        let dates = glucoseData.compactMap { data in
            dateValue(from: data["date"])
        }
        return dates.max()
    }

    private enum EffectiveCGMReadingDateResolution {
        case found(Date)
        case rejectedDateOnly
        case missing
    }

    /// Resolves the CGM reading timestamp from a watch state / complication payload.
    /// Uses `dateValue(from:)` for `reading_epoch` so bridged `NSNumber` / `Date` / `TimeInterval` match other timestamp fields.
    /// Order: `reading_epoch` (R1a), then newest `glucoseValues` sample.
    /// The top-level `date` key is **build/state snapshot time**, not the CGM reading time; if that is the only
    /// parseable timestamp, the result is `.rejectedDateOnly` so callers never treat it as a reading.
    private func resolveEffectiveCGMReadingDate(from message: [String: Any]) -> EffectiveCGMReadingDateResolution {
        if let d = dateValue(from: message[WatchMessageKeys.readingEpoch]) {
            return .found(d)
        }
        if let d = latestGlucoseDate(from: message) {
            return .found(d)
        }
        if dateValue(from: message[WatchMessageKeys.date]) != nil {
            return .rejectedDateOnly
        }
        return .missing
    }
}
