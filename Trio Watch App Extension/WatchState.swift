import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity
import WatchKit

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

@Observable final class WatchState: NSObject, WCSessionDelegate {
    static let shared = WatchState()

    // MARK: - WatchConnectivity

    var session: WCSession?
    var isReachable = false
    var lastWatchStateUpdate: Date?

    // MARK: - Main view metrics

    var currentGlucose: String = "--"
    var currentGlucoseColorString: String = "#ffffff"
    var trend: String? = ""
    var delta: String? = "--"
    var glucoseValues: [(date: Date, glucose: Double, color: Color)] = []
    var minYAxisValue: Decimal = 39
    var maxYAxisValue: Decimal = 200
    var cob: String? = "--"
    var iob: String? = "--"
    var lastLoopTime: String? = "--"
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []

    // MARK: - Treatment inputs

    var carbsAmount: Int = 0
    var fatAmount: Int = 0
    var proteinAmount: Int = 0
    var bolusAmount: Double = 0.0
    var confirmationProgress: Double = 0.0

    // MARK: - Safety limits

    var maxBolus: Decimal = 10
    var maxCarbs: Decimal = 250
    var maxFat: Decimal = 250
    var maxProtein: Decimal = 250

    // MARK: - Pump-specific increments

    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // MARK: - Acknowledgment handling

    var showCommsAnimation: Bool = false
    var showAcknowledgmentBanner: Bool = false
    var acknowledgementStatus: AcknowledgementStatus = .pending
    var acknowledgmentMessage: String = ""
    var shouldNavigateToRoot: Bool = true

    // MARK: - Progress state

    var showBolusCalculationProgress: Bool = false
    var mealBolusStep: MealBolusStep = .savingCarbs
    var isMealBolusCombo: Bool = false
    var recommendedBolus: Decimal = 0

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

    private var activationTimestamp: Date?
    private var forcedSinceActivation = false

    private var transferRetryCount = 0
    private let maxTransferRetries = 3
    private var retryWorkItem: DispatchWorkItem?

    // MARK: - Startup coordination

    private let startupWatchStateDelaySeconds: TimeInterval = 2.0
    private let startupHealthKitDelaySeconds: TimeInterval = 10.0
    private let startupFlushDelaySeconds: TimeInterval = 10.0

    private var startupActivationSequence = 0
    private var startupCurrentActivationSequence: Int?
    private var startupIsForegroundActive = false
    private var startupBackgroundLaunchDisarmWorkItem: DispatchWorkItem?
    private var startupDeferredWatchStateWorkItem: DispatchWorkItem?
    private var startupDeferredHealthKitWorkItem: DispatchWorkItem?
    private var startupDeferredPersistedLogFlushWorkItem: DispatchWorkItem?
    private var startupFirstRefreshFiredActivationSequence: Int?
    private var startupFirstRefreshInFlight = false
    private var hasInitializedHealthKitSetupInProcess = false

    // MARK: - HealthKit (R6)

    private var healthKitStore: HKHealthStore?
    private var glucoseObserverQuery: HKObserverQuery?

    /// Path B4 — max samples for nil-anchor bootstrap (`HKSampleQuery`, descending). **64** ≈ enough for latest + delta/trend context within a dense CGM window while capping peak batch size vs unbounded anchored pulls.
    private static let hkBootstrapSampleLimit = 64

    private var backgroundRefreshCount = 0
    private var lastBackgroundRefreshDate: Date?
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forceComplicationUpdate()
            self.scheduleBackgroundRefresh()
        }
    }

    func noteAppBecameActive() {
        assert(Thread.isMainThread, "noteAppBecameActive must be called on main thread")
        activationTimestamp = Date()
        forcedSinceActivation = false
        hasRequestedInitialUpdate = false
        startupFirstRefreshInFlight = false
    }

    func scheduleBackgroundLaunchDisarmIfNeeded() {
        assert(Thread.isMainThread, "scheduleBackgroundLaunchDisarmIfNeeded must be called on main thread")
        startupBackgroundLaunchDisarmWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startupBackgroundLaunchDisarmWorkItem = nil
            guard !self.startupIsForegroundActive else { return }

            WatchStartupTransportGate.disarm()
            Task {
                await WatchLogger.shared.log(
                    "event=watch_startup_background_launch_disarm"
                        + " reason=no_foreground_entry"
                )
            }
        }

        startupBackgroundLaunchDisarmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func handleForegroundActiveEntry() {
        assert(Thread.isMainThread, "handleForegroundActiveEntry must be called on main thread")
        guard !startupIsForegroundActive else { return }

        startupIsForegroundActive = true
        startupActivationSequence += 1
        let activationSequence = startupActivationSequence
        startupCurrentActivationSequence = activationSequence
        startupFirstRefreshFiredActivationSequence = nil

        startupBackgroundLaunchDisarmWorkItem?.cancel()
        startupBackgroundLaunchDisarmWorkItem = nil
        WatchStartupTransportGate.arm(activationSequence: activationSequence)
        noteAppBecameActive()
        WatchErrorReporter.markBecameActiveImmediately()
        scheduleStartupSequenceOnMain(activationSequence: activationSequence)

        Task {
            await WatchLogger.shared.log(
                "event=watch_startup_grace_scheduled"
                    + " activation_seq=\(activationSequence)"
                    + " watch_state_delay_s=\(Int(startupWatchStateDelaySeconds))"
                    + " healthkit_delay_s=\(Int(startupHealthKitDelaySeconds))"
                    + " flush_delay_s=\(Int(startupFlushDelaySeconds))"
            )
            await WatchErrorReporter.shared.startup()
        }
    }

    func handleForegroundInactiveOrBackground() {
        assert(Thread.isMainThread, "handleForegroundInactiveOrBackground must be called on main thread")
        guard startupIsForegroundActive else { return }

        startupIsForegroundActive = false
        startupFirstRefreshInFlight = false
        let activationSequence = startupCurrentActivationSequence
        let pendingTasks = startupPendingTasksFieldOnMain()
        cancelStartupSequenceOnMain()
        startupCurrentActivationSequence = nil
        WatchErrorReporter.markEnteredBackgroundOrInactiveImmediately()

        if let activationSequence {
            WatchStartupTransportGate.disarm(activationSequence: activationSequence)
            if pendingTasks != "none" {
                Task {
                    await WatchLogger.shared.log(
                        "event=watch_startup_grace_canceled"
                            + " activation_seq=\(activationSequence)"
                            + " reason=left_active_before_fire"
                            + " pending=\(pendingTasks)"
                    )
                }
            }
        }
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

        let flushWorkItem = DispatchWorkItem { [weak self] in
            self?.fireDeferredStartupPersistedLogFlushOnMain(
                activationSequence: activationSequence
            )
        }
        startupDeferredPersistedLogFlushWorkItem = flushWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + startupFlushDelaySeconds,
            execute: flushWorkItem
        )
    }

    private func cancelStartupSequenceOnMain() {
        assert(Thread.isMainThread, "cancelStartupSequenceOnMain must be called on main thread")
        startupDeferredWatchStateWorkItem?.cancel()
        startupDeferredWatchStateWorkItem = nil
        startupDeferredHealthKitWorkItem?.cancel()
        startupDeferredHealthKitWorkItem = nil
        startupDeferredPersistedLogFlushWorkItem?.cancel()
        startupDeferredPersistedLogFlushWorkItem = nil
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
        if startupDeferredPersistedLogFlushWorkItem != nil {
            pendingTasks.append("flush")
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

        Task {
            await WatchLogger.shared.log(
                "event=watch_startup_deferred_watch_state_refresh_fired"
                    + " activation_seq=\(activationSequence)"
            )
        }

        requestWatchStateUpdate()
    }

    private func fireDeferredStartupHealthKitSetupOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "fireDeferredStartupHealthKitSetupOnMain must be called on main thread")
        guard startupIsForegroundActive,
              startupCurrentActivationSequence == activationSequence
        else { return }

        startupDeferredHealthKitWorkItem = nil
        let alreadyInitialized = hasInitializedHealthKitSetupInProcess

        Task {
            await WatchLogger.shared.log(
                "event=watch_startup_deferred_healthkit_setup_fired"
                    + " activation_seq=\(activationSequence)"
                    + " already_initialized=\(alreadyInitialized)"
            )
        }

        guard !alreadyInitialized else { return }

        hasInitializedHealthKitSetupInProcess = true
        setupHealthKitBackgroundDelivery()
    }

    private func fireDeferredStartupPersistedLogFlushOnMain(activationSequence: Int) {
        assert(Thread.isMainThread, "fireDeferredStartupPersistedLogFlushOnMain must be called on main thread")
        guard startupIsForegroundActive,
              startupCurrentActivationSequence == activationSequence
        else { return }

        startupDeferredPersistedLogFlushWorkItem = nil

        Task {
            await WatchLogger.shared.log(
                "event=watch_startup_deferred_persisted_log_flush_fired"
                    + " activation_seq=\(activationSequence)"
            )
            let didDisarm = WatchStartupTransportGate.disarm(
                activationSequence: activationSequence
            )
            await WatchLogger.shared.flushPersistedLogs(
                startupTransportSuppressedOverride: didDisarm ? false : nil
            )
        }
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

        Task {
            await WatchLogger.shared.log(
                "event=watch_startup_transport_suppressed"
                    + " activation_seq=\(activationSequence)"
                    + " path=startup_signal"
                    + " reason=startup_grace"
            )
        }
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

    private func setupSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            Task {
                await WatchLogger.shared.log("WCSession setup complete.")
            }
        } else {
            Task {
                await WatchLogger.shared.log("WCSession is not supported on this device")
            }
        }
    }

    // MARK: - HealthKit background delivery (R6)

    private func setupHealthKitBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        guard let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return }

        store.requestAuthorization(toShare: nil, read: Set([bgType])) { [weak self] granted, error in
            guard let self else { return }
            guard granted, error == nil else {
                Task {
                    await WatchLogger.shared.log("❌ hk_authorization_failed granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
                }
                return
            }

            store.enableBackgroundDelivery(for: bgType, frequency: .immediate) { success, error in
                if let error = error {
                    Task {
                        await WatchLogger.shared.log("❌ hk_background_delivery_registration_failed error=\(error.localizedDescription)")
                    }
                } else if success {
                    Task {
                        await WatchLogger.shared.log("✅ hk_background_delivery_registered success=true low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                    }
                } else {
                    Task {
                        await WatchLogger.shared.log("⚠️ hk_background_delivery_registered success=false low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                    }
                }
            }

            self.setupGlucoseObserverQuery(store: store, sampleType: bgType)
        }
    }

    private func setupGlucoseObserverQuery(store: HKHealthStore, sampleType: HKQuantityType) {
        healthKitStore = store
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            let fireId = UUID()
            guard error == nil else {
                Task {
                    await WatchLogger.shared.log("❌ hk_observer_error fire_id=\(fireId) error=\(error!.localizedDescription)")
                }
                completionHandler()
                return
            }
            guard let self else {
                completionHandler()
                return
            }
            self.fetchLatestGlucoseFromHealthKit(fireId: fireId, completionHandler: completionHandler)
        }
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
        completionHandler: @escaping () -> Void
    ) {
        let dataStore = TrioComplicationDataStore.shared
        if let err = error {
            Task {
                await WatchLogger.shared.log("❌ hk_observer_query_error fire_id=\(fireId) error=\(err.localizedDescription)")
            }
            completionHandler()
            return
        }

        let added = samples ?? []
        // Stable batch events: `hk_sample_query_batch` (bootstrap `HKSampleQuery`) vs `hk_anchored_query_batch` (incremental `HKAnchoredObjectQuery`) — split so Better Stack filters are not misleading (Claude review).
        let batchEventName = anchorWasNil ? "hk_sample_query_batch" : "hk_anchored_query_batch"
        Task {
            await WatchLogger.shared
                .log("event=\(batchEventName) fire_id=\(fireId) anchor_was_nil=\(anchorWasNil) samples_count=\(added.count)")
        }

        if let newAnchor,
           let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
            dataStore.saveHKGlucoseAnchor(anchorData)
        }

        let sortedByDate = added.sorted { $0.startDate > $1.startDate }
        if sortedByDate.isEmpty {
            Task {
                await WatchLogger.shared.log("⚠️ hk_observer_no_new_samples fire_id=\(fireId)")
            }
            completionHandler()
            return
        }

        let latest = sortedByDate[0]
        let latestEpoch = latest.startDate.timeIntervalSince1970
        let latestMgDl = latest.quantity.doubleValue(for: mgDlUnit)

        if latestEpoch == dataStore.hkLastReceivedGlucoseEpoch() {
            Task {
                await WatchLogger.shared.log("⚠️ hk_observer_skipped_known_epoch fire_id=\(fireId) epoch=\(Int(latestEpoch))")
            }
            completionHandler()
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
            deltaString = String(format: "%+d", deltaInt)
            trendString = Self.hkTrendString(fromDeltaMgDl: deltaInt)
            trendDerived = true
        }

        dataStore.setHKLastReceivedGlucoseEpoch(latestEpoch)
        dataStore.setHKLastReceivedGlucoseValueMgDl(latestMgDl)

        let readingDate = latest.startDate
        let glucoseString = String(Int(latestMgDl.rounded()))
        let syncLag = Int(Date().timeIntervalSince(readingDate))

        // Stable tokens for validation / Better Stack: batch lines use `hk_sample_query_batch` | `hk_anchored_query_batch` above; `query_type` uses `sampleQuery_bootstrap` | `anchoredQuery`. Do not rename casually.
        let queryLabel = anchorWasNil ? "sampleQuery_bootstrap" : "anchoredQuery"
        Task {
            await WatchLogger.shared.log(
                "🏥 hk_observer_fired fire_id=\(fireId) reading_epoch=\(Int(readingDate.timeIntervalSince1970)) sync_lag=\(syncLag) glucose=\(glucoseString) delta=\(deltaString) trend=\(trendString) trend_derived=\(trendDerived) samples_in_batch=\(sortedByDate.count) query_type=\(queryLabel)"
            )
        }

        let snapshot = TrioComplicationSnapshot(
            glucose: glucoseString,
            trend: trendString,
            delta: deltaString,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: nil
        )

        DispatchQueue.main.async {
            TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)
            completionHandler()
        }
    }

    /// Path B4 — After a successful bounded `HKSampleQuery` bootstrap, persist an `HKQueryAnchor` at the current timeline (“samples from `Date()` onward” + `.strictStartDate` is typically an **empty** forward window) so the next observer cycle uses incremental `HKAnchoredObjectQuery` instead of repeating bootstrap. Calls `completion` when the establishment query finishes (success or failure) so the HK observer callback is not released before the anchor write attempt.
    ///
    /// **Memory safety:** Uses `HKObjectQueryNoLimit`, but boundedness relies on the **predicate** yielding an effectively empty forward timeline—not on the limit parameter (ChatGPT review P2).
    private func establishHealthKitGlucoseTimelineAnchorAfterBootstrap(
        store: HKHealthStore,
        bgType: HKQuantityType,
        fireId: UUID,
        completion: @escaping () -> Void
    ) {
        let now = Date()
        let predicate = HKQuery.predicateForSamples(withStart: now, end: nil, options: .strictStartDate)
        let anchorQuery = HKAnchoredObjectQuery(
            type: bgType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit,
            resultsHandler: { _, samples, _, newAnchor, error in
                defer { completion() }
                if let err = error {
                    Task {
                        await WatchLogger.shared
                            .log("⚠️ hk_bootstrap_anchor_establish_failed fire_id=\(fireId) error=\(err.localizedDescription)")
                    }
                    return
                }
                guard let newAnchor,
                      let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                else {
                    Task {
                        await WatchLogger.shared.log("⚠️ hk_bootstrap_anchor_establish_no_anchor fire_id=\(fireId)")
                    }
                    return
                }
                TrioComplicationDataStore.shared.saveHKGlucoseAnchor(anchorData)
                let n = (samples as? [HKQuantitySample])?.count ?? 0
                Task {
                    await WatchLogger.shared
                        .log("✅ hk_bootstrap_anchor_established fire_id=\(fireId) timeline_predicate_samples_count=\(n)")
                }
            }
        )
        store.execute(anchorQuery)
    }

    private func fetchLatestGlucoseFromHealthKit(fireId: UUID, completionHandler: @escaping () -> Void) {
        guard let store = healthKitStore,
              let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            Task {
                await WatchLogger.shared.log("❌ hk_observer_guard_failed fire_id=\(fireId) reason=nil_store_or_type")
            }
            completionHandler()
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
                Task {
                    await WatchLogger.shared.log("⚠️ hk_anchor_decode_failed fire_id=\(fireId)")
                }
            }
        } else {
            Task {
                await WatchLogger.shared.log("⚠️ hk_observer_nil_anchor fire_id=\(fireId)")
            }
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
                    completionHandler()
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
                        completionHandler: completionHandler
                    )
                    return
                }
                let afterBootstrap: () -> Void = {
                    self.establishHealthKitGlucoseTimelineAnchorAfterBootstrap(
                        store: store,
                        bgType: bgType,
                        fireId: fireId,
                        completion: completionHandler
                    )
                }
                self.finishHKGlucoseObserverFetch(
                    fireId: fireId,
                    anchorWasNil: true,
                    samples: samples as? [HKQuantitySample],
                    newAnchor: nil,
                    error: nil,
                    mgDlUnit: mgDlUnit,
                    completionHandler: afterBootstrap
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
                    completionHandler()
                    return
                }
                self.finishHKGlucoseObserverFetch(
                    fireId: fireId,
                    anchorWasNil: false,
                    samples: samples as? [HKQuantitySample],
                    newAnchor: newAnchor,
                    error: error,
                    mgDlUnit: mgDlUnit,
                    completionHandler: completionHandler
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

    /// Path B1 — Summarize inbound WC messages without stringifying nested `glucoseValues` (avoids large transient `String` allocations).
    private static func watchConnectivityInboundSummary(_ message: [String: Any]) -> String {
        let topKeys = message.keys.sorted().joined(separator: ",")
        var parts = ["event=watch_wc_inbound channel=message top_level_keys=\(topKeys)"]
        if let type = message["type"] as? String {
            parts.append("type=\(type)")
        }
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

    // MARK: - Acknowledgement handling

    func handleAcknowledgment(success: Bool, message: String, isFinal: Bool = true) {
        Task {
            await WatchLogger.shared.log("Handling acknowledgment: \(message), success: \(success), isFinal: \(isFinal)")
        }

        if success {
            Task {
                await WatchLogger.shared.log("Acknowledgment received: \(message)")
            }
            acknowledgementStatus = .success
            acknowledgmentMessage = message
            DispatchQueue.main.async {
                self.showCommsAnimation = false
            }
        } else {
            Task {
                await WatchLogger.shared.log("Acknowledgment failed: \(message)")
            }
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
                self.showSyncingAnimation = false
                Task {
                    await WatchLogger.shared.log("Cleared ack banner and syncing animation")
                }
            }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                Task {
                    await WatchLogger.shared.log("Watch session activation failed: \(error)", force: true)
                    await WatchLogger.shared.log("Saving logs to disk as fallback.")
                    await WatchLogger.shared.flushPersistedLogs()
                }
                return
            }

            if activationState == .activated {
                Task {
                    await WatchLogger.shared.log("Watch session activated with state: \(activationState.rawValue)")
                }

                _ = self.forceConditionalWatchStateUpdate()
                self.isReachable = session.isReachable

                Task {
                    await WatchLogger.shared.log("Watch isReachable after activation: \(session.isReachable)")
                }
            }
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        if let type = message["type"] as? String, type == "batchAck" {
            let ackIds = WatchConnectivityPayloadIds.payloadIdStrings(
                from: message["ackIds"]
            )
            if !ackIds.isEmpty {
                Task { await WatchLogger.shared.deleteFilesForPayloadIds(ackIds) }
            }
            return
        }

        if let type = message["type"] as? String, type == "ack",
           let pid = WatchConnectivityPayloadIds.payloadIdString(message["payloadId"])
        {
            Task { await WatchLogger.shared.deleteFilesForPayloadIds([pid]) }
            return
        }

        Task {
            await WatchLogger.shared.log(Self.watchConnectivityInboundSummary(message))
        }

        // R5b — message is the sendMessage envelope [WatchMessageKeys.watchState: fullMessage]; watchStateDict is the inner payload (same shape as iPhone fullMessage) so readingEpoch is correct for end-to-end timing.
        if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any],
           let date = dateValue(from: watchStateDict[WatchMessageKeys.date])
        {
            if date >= Date().addingTimeInterval(-15 * 60) {
                let extractedEpoch = (watchStateDict[WatchMessageKeys.readingEpoch] as? TimeInterval).map { Int($0) } ?? -1
                Task {
                    await WatchLogger.shared.log("📬 didReceiveMessage reading_epoch=\(extractedEpoch) receive_wall=\(Date().timeIntervalSince1970)")
                }
                Task {
                    await WatchLogger.shared.log("Handling watchState from \(date)")
                }
                processWatchMessage(message)
            } else {
                Task {
                    await WatchLogger.shared.log("Received outdated watchState data (\(date))")
                }
                DispatchQueue.main.async {
                    self.clearStartupFirstRefreshInFlightOnMain()
                    self.showSyncingAnimation = false
                    self.completePendingConnectivityTasksOnMain(
                        path: "message_outdated",
                        requiresNoPendingContent: true
                    )
                }
            }
            return
        } else if
            let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
            let ackMessage = message[WatchMessageKeys.message] as? String,
            let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String
        {
            Task {
                await WatchLogger.shared
                    .log("Handling ack with message: \(ackMessage), success: \(acknowledged), ackCode: \(ackCodeRaw)")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            processWatchMessage(message)
            return
        } else if let recommendedBolus = message[WatchMessageKeys.recommendedBolus] as? NSNumber {
            Task {
                await WatchLogger.shared.log("Received recommended bolus: \(recommendedBolus)")
            }

            DispatchQueue.main.async {
                self.recommendedBolus = recommendedBolus.decimalValue
                self.showBolusCalculationProgress = false
            }
            return
        } else {
            Task {
                await WatchLogger.shared.log("Faulty data. Skipping.")
            }
            DispatchQueue.main.async {
                self.clearStartupFirstRefreshInFlightOnMain()
                self.showSyncingAnimation = false
                self.completePendingConnectivityTasksOnMain(
                    path: "message_invalid",
                    requiresNoPendingContent: true
                )
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let type = userInfo["type"] as? String, type == "watchLogConfirm" {
            let payloadIds = WatchConnectivityPayloadIds.payloadIdStrings(
                from: userInfo["payloadIds"]
            )
            if !payloadIds.isEmpty {
                Task { await WatchLogger.shared.deleteFilesForPayloadIds(payloadIds) }
            }
            DispatchQueue.main.async { [self] in
                completePendingConnectivityTasksOnMain(
                    path: "watch_log_confirm",
                    requiresNoPendingContent: true
                )
            }
            return
        }

        Task {
            await WatchLogger.shared.log("Received userInfo with keys: \(userInfo.keys.joined(separator: ", "))")
        }

        let payload = (userInfo[WatchMessageKeys.watchState] as? [String: Any]) ?? userInfo

        let readingDate: Date
        switch resolveEffectiveCGMReadingDate(from: payload) {
        case let .found(date):
            readingDate = date
        case .rejectedDateOnly:
            Task {
                await WatchLogger.shared.log(
                    "Invalid snapshot received: no CGM reading timestamp"
                        + " (top-level date is state/snapshot time only — not used as reading)"
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.completePendingConnectivityTasksOnMain(
                    path: "invalid_no_pending",
                    requiresNoPendingContent: true
                )
            }
            return
        case .missing:
            Task {
                await WatchLogger.shared.log(
                    "Invalid snapshot received: no valid CGM reading timestamp"
                        + " (no reading_epoch, glucoseValues samples, or parseable date)"
                )
            }
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
        lastUserInfoReceiveTimestamp = Date()
        Task {
            await WatchLogger.shared.log("event=complication_did_receive_user_info window_id=\(BackgroundTaskWindowCounter.currentOrNil() ?? -1) reading_date_epoch=\(readingDateEpoch)")
        }

        // Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
        // state is not populated here (defaults to nil) because no call site currently sets it.
        // If state is ever set during snapshot construction, add it here too — otherwise this
        // fingerprint will always differ from the saved one, defeating dedup for this path.
        let tempSnapshot = TrioComplicationSnapshot(
            glucose: payload[WatchMessageKeys.currentGlucose] as? String ?? "--",
            trend: payload[WatchMessageKeys.trend] as? String ?? "",
            delta: payload[WatchMessageKeys.delta] as? String ?? "",
            readingDate: readingDate,
            date: Date()
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

        DispatchQueue.main.async { [self] in
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
                Task {
                    await WatchLogger.shared.log("event=complication_userinfo_no_pending_tasks window_id=\(wid) reading_date_epoch=\(readingDateEpoch) note=race_or_foreground")
                }
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
                Task {
                    await WatchLogger.shared.log("💤 sleep_gap_detected gap_seconds=\(gapDisplay)")
                }
                forceWidgetReloadIfStale(receivedGap: gap)
            }
        }
    }

    func session(_: WCSession, didFinish _: WCSessionUserInfoTransfer, error: (any Error)?) {
        if let error = error {
            Task {
                await WatchLogger.shared.log("transferUserInfo failed with error: \(error)")
                await WatchLogger.shared.log("Saving logs to disk as fallback.")
                await WatchLogger.shared.flushPersistedLogs()
            }

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
                loadFallbackDataFromComplication()
            }
        } else {
            transferRetryCount = 0
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            Task {
                await WatchLogger.shared.log("Watch reachability changed: \(session.isReachable)")
            }

            self.isReachable = session.isReachable

            if session.isReachable {
                if self.isColdStart, !self.forcedSinceActivation {
                    _ = self.forceConditionalWatchStateUpdate()
                }

                self.bolusAmount = 0
                self.carbsAmount = 0
                self.confirmationProgress = 0
            }
        }
    }

    // R4: applicationContext safety net — parallel delivery channel from iOS during budget exhaustion.
    // R5d: integrated sleep-gap detection (same three-constraint ordering as didReceiveUserInfo).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { await WatchLogger.shared.log("📦 didReceiveApplicationContext") }
        guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else {
            return
        }
        let readingResolution = resolveEffectiveCGMReadingDate(from: payload)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let gap = self.lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            self.saveComplicationSnapshot(from: payload)
            if case .found = readingResolution {
                self.scheduleUIUpdate(with: payload)
            }
            self.lastDataReceivedAt = Date()
            if gap > 600 {
                let gapDisplay = gap.isInfinite ? "first_receive" : "\(Int(gap))"
                Task {
                    await WatchLogger.shared.log("💤 sleep_gap_detected_context gap_seconds=\(gapDisplay)")
                }
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
            Task {
                await WatchLogger.shared.log("Forcing initial WatchState update")
            }
            showSyncingAnimation = true
            requestWatchStateUpdate()
            forcedSinceActivation = true
            return true
        }

        let now = Date()
        let secondsSinceUpdate = now.timeIntervalSince(lastUpdateTimestamp)
        Task {
            await WatchLogger.shared.log("Time since last update: \(secondsSinceUpdate) seconds")
        }

        if secondsSinceUpdate > 15 || isColdStart {
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
                Task {
                    await WatchLogger.shared.log(
                        "event=complication_bgtask_completion_retry_ready path=\(path)"
                            + " window_id=\(wid)"
                            + " attempt=\(attempt)"
                            + " pending_content=false"
                    )
                }
                _ = completePendingConnectivityTasksOnMain(
                    path: path,
                    requiresNoPendingContent: true
                )
                return
            }

            guard let deadline = deferredConnectivityCompletionDeadline,
                  Date() < deadline else {
                Task {
                    await WatchLogger.shared.log(
                        "event=complication_bgtask_completion_retry_expired path=\(path)"
                            + " window_id=\(wid)"
                            + " attempt=\(attempt)"
                            + " pending_count=\(pendingConnectivityTasks.count)"
                            + " pending_content=true"
                    )
                }
                clearDeferredConnectivityCompletionRetryOnMain()
                return
            }

            Task {
                await WatchLogger.shared.log(
                    "event=complication_bgtask_completion_retry_pending path=\(path)"
                        + " window_id=\(wid)"
                        + " attempt=\(attempt)"
                        + " pending_count=\(pendingConnectivityTasks.count)"
                        + " pending_content=true"
                )
            }
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
            Task {
                await WatchLogger.shared.log(
                    "event=complication_bgtask_completion_deferred path=\(path)"
                        + " window_id=\(wid)"
                        + " task_type=WKWatchConnectivityRefreshBackgroundTask"
                        + " pending_count=\(pendingCount)"
                        + " pending_content=true"
                )
            }
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
                Task {
                    await WatchLogger.shared.log(
                        "event=complication_bgtask_terminal_marker path=\(canonicalConnectivityTerminalPath(path))"
                            + " window_id=\(wid)"
                            + " pending_count=0"
                    )
                }
            }
            return 0
        }

        let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
        Task {
            await WatchLogger.shared.log(
                "event=complication_bgtask_completing path=\(path)"
                    + " window_id=\(wid)"
                    + " task_type=WKWatchConnectivityRefreshBackgroundTask"
                    + " completed_count=\(pendingCount)"
                    + " pending_content=\(hasPendingContent)"
                    + " 📡 BGTask completing (\(path)) window_id=\(wid) count=\(pendingCount)"
            )
        }

        clearDeferredConnectivityCompletionRetryOnMain()

        // Keep `false` here: complication freshness is driven by the save/reload path,
        // and changing snapshot semantics is outside the scope of this task-lifecycle fix.
        for task in pendingConnectivityTasks {
            task.setTaskCompletedWithSnapshot(false)
        }
        pendingConnectivityTasks.removeAll()
        return pendingCount
    }

    private func processWatchMessage(_ message: [String: Any]) {
        DispatchQueue.main.async {
            if let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
               let ackMessage = message[WatchMessageKeys.message] as? String,
               let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String,
               let ackCode = AcknowledgmentCode(rawValue: ackCodeRaw)
            {
                DispatchQueue.main.async {
                    self.showSyncingAnimation = false
                }

                Task {
                    await WatchLogger.shared.log("Received acknowledgment: \(ackMessage), success: \(acknowledged)")
                }

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

    private func scheduleUIUpdate(
        with newData: [String: Any],
        fromUserInfo: Bool = false,
        userInfoReceiveTimestamp: Date? = nil,
        pendingConnectivityCompletionPath: String? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in
                scheduleUIUpdate(
                    with: newData,
                    fromUserInfo: fromUserInfo,
                    userInfoReceiveTimestamp: userInfoReceiveTimestamp,
                    pendingConnectivityCompletionPath: pendingConnectivityCompletionPath
                )
            }
            return
        }

        guard let incomingDate = dateValue(from: newData[WatchMessageKeys.date]) else {
            Task {
                await WatchLogger.shared.log("Invalid date format in WatchState data")
            }
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
            Task {
                await WatchLogger.shared.log("Skipping UI update — outdated WatchState (\(incomingDate))")
            }
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

        Task {
            await WatchLogger.shared.log("Merging new WatchState data with keys: \(newData.keys.joined(separator: ", "))")
        }

        pendingData.merge(newData) { _, newVal in newVal }

        finalizeWorkItem?.cancel()

        let fromUserInfoCapture = fromUserInfo
        let userInfoTsCapture = userInfoReceiveTimestamp
        let completionPathCapture = pendingConnectivityCompletionPath
        let workItem = DispatchWorkItem { [self] in
            Task {
                await WatchLogger.shared.log("Debounced update fired")
            }
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

    private func finalizePendingData(
        fromUserInfo: Bool = false,
        userInfoReceiveTimestamp: Date? = nil,
        pendingConnectivityCompletionPath: String? = nil
    ) {
        guard !pendingData.isEmpty else {
            Task {
                await WatchLogger.shared.log("finalizePendingData called with empty data")
            }

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

        Task {
            await WatchLogger.shared.log("Finalizing pending data")
        }

        processRawDataForWatchState(pendingData, fromUserInfo: fromUserInfo, userInfoReceiveTimestamp: userInfoReceiveTimestamp)
        pendingData.removeAll()

        DispatchQueue.main.async {
            self.showSyncingAnimation = false
        }

        Task {
            await WatchLogger.shared.log("Watch UI update complete")
        }

        guard let pendingConnectivityCompletionPath else { return }
        let pendingCountBeforeCompletion = pendingConnectivityTasks.count
        let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
        if pendingCountBeforeCompletion > 0 {
            Task {
                await WatchLogger.shared.log("event=complication_finalize_begin window_id=\(wid) pending_count=\(pendingCountBeforeCompletion)")
            }
        } else {
            Task {
                await WatchLogger.shared.log(
                    "event=complication_finalize_no_pending_tasks window_id=\(wid)"
                        + " path=\(pendingConnectivityCompletionPath)"
                )
            }
        }
        let clearedCount = completePendingConnectivityTasksOnMain(
            path: pendingConnectivityCompletionPath,
            recordMarkerWithoutPendingTasks: true
        )
        if clearedCount > 0 {
            Task {
                await WatchLogger.shared.log("event=complication_finalize_end window_id=\(wid) cleared_count=\(clearedCount)")
            }
        }
    }

    private func processRawDataForWatchState(_ message: [String: Any], fromUserInfo: Bool = false, userInfoReceiveTimestamp: Date? = nil) {
        Task {
            await WatchLogger.shared.log("Processing raw WatchState data with keys: \(message.keys.joined(separator: ", "))")
        }

        startupFirstRefreshInFlight = false

        if let date = dateValue(from: message[WatchMessageKeys.date]) {
            lastWatchStateUpdate = date
            forcedSinceActivation = false
        }

        syncTimeoutWorkItem?.cancel()
        syncTimeoutWorkItem = nil

        if let currentGlucose = message[WatchMessageKeys.currentGlucose] as? String {
            self.currentGlucose = currentGlucose
        }

        if let currentGlucoseColorString = message[WatchMessageKeys.currentGlucoseColorString] as? String {
            self.currentGlucoseColorString = currentGlucoseColorString
        }

        if let trend = message[WatchMessageKeys.trend] as? String {
            self.trend = trend
        }

        if let delta = message[WatchMessageKeys.delta] as? String {
            self.delta = delta
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
            glucoseValues = glucoseData.compactMap { data in
                guard let glucose = data["glucose"] as? Double,
                      let colorString = data["color"] as? String
                else { return nil }

                let dateValue = dateValue(from: data["date"])
                guard let date = dateValue else { return nil }

                return (date: date, glucose: glucose, color: colorString.toColor())
            }
            .sorted { $0.date < $1.date }
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
            self.bolusIncrement = max(decimalValue, 0.05)
        }

        if let confirmBolusFaster = message[WatchMessageKeys.confirmBolusFaster] as? Bool {
            self.confirmBolusFaster = confirmBolusFaster
        }

        saveComplicationSnapshot(from: message, fromUserInfo: fromUserInfo, userInfoReceiveTimestamp: userInfoReceiveTimestamp)
    }

    private func saveComplicationSnapshot(from message: [String: Any], fromUserInfo: Bool = false, userInfoReceiveTimestamp: Date? = nil) {
        Task {
            await WatchLogger.shared.log("📸 saveComplicationSnapshot called with keys: \(message.keys.joined(separator: ", "))")
        }

        // R3: effective CGM reading time (shared resolver; see `resolveEffectiveCGMReadingDate`)
        let readingDate: Date
        switch resolveEffectiveCGMReadingDate(from: message) {
        case let .found(date):
            readingDate = date
        case .rejectedDateOnly:
            Task {
                await WatchLogger.shared.log(
                    "⚠️ saveComplicationSnapshot: no reading_epoch or glucoseValues;"
                        + " top-level date is state snapshot time only — refusing as CGM reading — skipping save"
                )
            }
            return
        case .missing:
            Task {
                await WatchLogger.shared.log(
                    "📸 saveComplicationSnapshot SKIPPED: no valid CGM reading timestamp"
                        + " (no reading_epoch, glucoseValues, or parseable date)"
                )
            }
            return
        }

        let glucoseValue = message[WatchMessageKeys.currentGlucose] as? String ?? currentGlucose
        let trendValue = message[WatchMessageKeys.trend] as? String ?? trend ?? ""
        let deltaValue = message[WatchMessageKeys.delta] as? String ?? delta ?? ""
        let glucoseColorValue = (message[WatchMessageKeys.currentGlucoseColorString] as? String) ?? currentGlucoseColorString

        Task {
            await WatchLogger.shared.log("📸 Saving snapshot: glucose=\(glucoseValue), trend=\(trendValue), delta=\(deltaValue), readingDate=\(readingDate)")
            await WatchLogger.shared.log("🔍 Debug: glucoseValue source - message: \(message[WatchMessageKeys.currentGlucose] as? String ?? "nil"), currentGlucose: \(currentGlucose)")
        }

        let snapshot = TrioComplicationSnapshot(
            glucose: glucoseValue,
            trend: trendValue,
            delta: deltaValue,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: glucoseColorValue
        )

        // Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
        if TrioComplicationDataStore.shared.shouldSkipPreDispatch(for: snapshot, handler: "message") {
            return
        }

        TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)

        // R5c — log decode latency and reading_epoch for the payload we just saved (avoids misattribution when overlapping userInfo deliveries).
        // Use only the threaded userInfoReceiveTimestamp; no fallback to instance state so attribution stays unambiguous.
        if fromUserInfo, let start = userInfoReceiveTimestamp {
            let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
            let readingEpoch = Int(readingDate.timeIntervalSince1970)
            Task {
                await WatchLogger.shared.log("⏱️ userInfo_decoded reading_epoch=\(readingEpoch) decode_ms=\(decodeMs)")
            }
        }
        if fromUserInfo {
            lastUserInfoReceiveTimestamp = nil
        }
    }

    func forceComplicationUpdate() {
        Task {
            await WatchLogger.shared.log("🔄 forceComplicationUpdate called")
        }

        guard !currentGlucose.isEmpty,
              !currentGlucose.contains("??"),
              !currentGlucose.localizedCaseInsensitiveContains("error")
        else {
            Task {
                await WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: invalid glucose '\(currentGlucose)'")
            }
            return
        }

        if let glucoseValue = Double(currentGlucose.replacingOccurrences(of: " mg/dL", with: "")) {
            guard glucoseValue >= 40 && glucoseValue <= 400 else {
                Task {
                    await WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: glucose out of range")
                }
                return
            }
        }

        guard let effectiveReadingDate = TrioComplicationDataStore.lastValidTimestamp else {
            Task {
                await WatchLogger.shared.log("🔄 forceComplicationUpdate SKIPPED: no valid CGM reading timestamp")
            }
            return
        }

        let snapshot = TrioComplicationSnapshot(
            glucose: currentGlucose,
            trend: trend ?? "",
            delta: delta ?? "",
            readingDate: effectiveReadingDate,
            date: Date(),
            glucoseColor: currentGlucoseColorString
        )

        Task {
            await WatchLogger.shared.log("🔄 forceComplicationUpdate: glucose=\(currentGlucose), readingDate=\(effectiveReadingDate)")
        }

        TrioComplicationDataStore.shared.save(snapshot, triggerReload: false)
        TrioComplicationDataStore.shared.forceReload(scheduleRetry: false)
    }

    /// R5d: after a detected sleep gap, force a widget reload. Rate-limited to 5 minutes.
    /// Stale-backlog detection is diagnostic only — the reload always fires.
    private func forceWidgetReloadIfStale(receivedGap: TimeInterval) {
        let store = TrioComplicationDataStore.shared

        // Rate limiter: 5-minute minimum between forced reloads
        if let lastReload = store.lastWidgetReloadAt(),
           Date().timeIntervalSince(lastReload) < 300 {
            Task {
                await WatchLogger.shared.log("💤 sleep_gap_reload_skipped reason=rate_limited last_reload_ago=\(Int(Date().timeIntervalSince(lastReload)))s")
            }
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
            Task {
                await WatchLogger.shared.log("⚠️ sleep_gap_reload_stale_backlog reading_epoch=\(snapshotEpoch) snapshot_age=\(snapshotAgeDisplay) gap=\(gapDisplay)s read_ms=\(snapshotReadMs)")
            }
        } else {
            Task {
                await WatchLogger.shared.log("💤 sleep_gap_reload_firing reading_epoch=\(snapshotEpoch) snapshot_age=\(snapshotAgeDisplay) gap=\(gapDisplay)s read_ms=\(snapshotReadMs)")
            }
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
                Task {
                    if let error = error {
                        await WatchLogger.shared.log("Failed to schedule background refresh: \(error)")
                    } else {
                        await WatchLogger.shared.log("Scheduled background refresh at \(refreshDate)")
                    }
                }
            }
        }

        func handleBackgroundTasks(_ tasks: Set<WKRefreshBackgroundTask>) {
            Task {
                await WatchLogger.shared.log("Handling background tasks: \(tasks.count)")
            }

            for task in tasks {
                if let refreshTask = task as? WKApplicationRefreshBackgroundTask {
                    backgroundRefreshCount += 1
                    lastBackgroundRefreshDate = Date()

                    if isReachable {
                        requestWatchStateUpdate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.forceComplicationUpdate()
                        }
                    } else {
                        loadFallbackDataFromComplication()
                        forceComplicationUpdate()
                    }

                    refreshTask.setTaskCompletedWithSnapshot(false)
                    scheduleBackgroundRefresh()
                } else if task is WKWatchConnectivityRefreshBackgroundTask {
                    let (bgTaskWindowId, receivedAt) = BackgroundTaskWindowCounter.next()
                    Task {
                        await WatchLogger.shared.log("event=complication_bgtask_received window_id=\(bgTaskWindowId) task_type=WKWatchConnectivityRefreshBackgroundTask 📡 BGTask received: WKWatchConnectivityRefreshBackgroundTask window_id=\(bgTaskWindowId)")
                    }
                    // Hold until userInfo processing completes (quiet-window or 5s safety timeout). All access on main.
                    // Multiple tasks in one wake are all stored; multiple didReceiveUserInfo reset the 300ms quiet window; last timer runs, then one finalize and complete all. If handle(_:backgroundTasks:) is delivered after the terminal path already fired (userInfo/context first, then task), the short-lived terminal marker rescues the late task; the 5s timeout remains the final fallback.
                    DispatchQueue.main.async { [self] in
                        pendingConnectivityTasks.append(task)
                        let pendingCount = pendingConnectivityTasks.count
                        Task {
                            await WatchLogger.shared.log("event=complication_bgtask_enqueued window_id=\(bgTaskWindowId) task_type=WKWatchConnectivityRefreshBackgroundTask pending_count=\(pendingCount)")
                        }
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
                                Task {
                                    await WatchLogger.shared.log("event=complication_bgtask_completing path=timeout window_id=\(windowId) task_type=WKWatchConnectivityRefreshBackgroundTask completion_delay_ms=\(completionDelayMs) completed_count=1 📡 BGTask completing (timeout) window_id=\(windowId)")
                                }
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

        if let lastUpdate = lastWatchStateUpdate,
           Date().timeIntervalSince(lastUpdate) <= 15
        {
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        DispatchQueue.main.async {
            self.currentGlucose = snapshot.glucose
            self.trend = snapshot.trend
            self.delta = snapshot.delta
            if let glucoseColor = snapshot.glucoseColor {
                self.currentGlucoseColorString = glucoseColor
            }
            self.lastWatchStateUpdate = snapshot.readingDate
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
