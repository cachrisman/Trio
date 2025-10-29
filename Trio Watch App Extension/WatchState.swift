import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit

/// WatchState manages the communication between the Watch app and the iPhone app using WatchConnectivity.
/// It handles glucose data synchronization and sending treatment requests (bolus, carbs) to the phone.
@Observable final class WatchState: NSObject, WCSessionDelegate {
    // MARK: - Properties

    /// The WatchConnectivity session instance used for communication
    var session: WCSession?
    /// Indicates if the paired iPhone is currently reachable
    var isReachable = false

    var lastWatchStateUpdate: TimeInterval?

    /// main view relevant metrics
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

    /// treatments inputs
    /// used to store carbs for combined meal-bolus-treatments
    var carbsAmount: Int = 0
    var fatAmount: Int = 0
    var proteinAmount: Int = 0
    var bolusAmount: Double = 0.0
    var confirmationProgress: Double = 0.0

    // Safety limits
    var maxBolus: Decimal = 10
    var maxCarbs: Decimal = 250
    var maxFat: Decimal = 250
    var maxProtein: Decimal = 250

    // Pump specific dosing increment
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // Acknowlegement handling
    var showCommsAnimation: Bool = false
    var showAcknowledgmentBanner: Bool = false
    var acknowledgementStatus: AcknowledgementStatus = .pending
    var acknowledgmentMessage: String = ""
    var shouldNavigateToRoot: Bool = true

    // Bolus calculation progress
    var showBolusCalculationProgress: Bool = false

    // Meal bolus-specific properties
    var mealBolusStep: MealBolusStep = .savingCarbs
    var isMealBolusCombo: Bool = false

    var recommendedBolus: Decimal = 0

    // MARK: - Cold start window

    /// Indicates if the app is within the initial cold-start window after process start
    var isColdStartWindowActive: Bool = true
    /// Tunable cold-start window duration in seconds
    var coldStartWindowSeconds: TimeInterval = 60
    private var coldStartWorkItem: DispatchWorkItem?

    // MARK: - Debouncing and batch processing helpers

    /// Temporary storage for new data arriving via WatchConnectivity.
    private var pendingData: [String: Any] = [:]

    /// Work item to schedule finalizing the pending data.
    private var finalizeWorkItem: DispatchWorkItem?

    /// A flag to tell the UI we’re still updating.
    var showSyncingAnimation: Bool = false

    var deviceType = WatchSize.current

    // MARK: - Correlation ID dedupe for acks
    private var recentAckCorrelationIds: [String] = []
    private let ackCapacity = 50
    private func shouldProcessAck(correlationId: String?) -> Bool {
        guard let id = correlationId, !id.isEmpty else { return true }
        if recentAckCorrelationIds.contains(id) { return false }
        recentAckCorrelationIds.append(id)
        if recentAckCorrelationIds.count > ackCapacity {
            recentAckCorrelationIds.removeFirst(recentAckCorrelationIds.count - ackCapacity)
        }
        return true
    }

    override init() {
        super.init()
        setupSession()
        startColdStartWindow()
    }

    /// Configures the WatchConnectivity session if supported on the device
    private func setupSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            Task {
                await WatchLogger.shared.log("⌚️ WCSession setup complete.")
            }
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ WCSession is not supported on this device")
            }
        }
    }

    private func startColdStartWindow() {
        isColdStartWindowActive = true
        coldStartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isColdStartWindowActive = false
        }
        coldStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coldStartWindowSeconds, execute: work)
    }

    // MARK: – Handle Acknowledgement Messages FROM Phone

    func handleAcknowledgment(success: Bool, message: String, isFinal: Bool = true) {
        Task {
            await WatchLogger.shared.log("Handling acknowledgment: \(message), success: \(success), isFinal: \(isFinal)")
        }

        if success {
            Task {
                await WatchLogger.shared.log("⌚️ Acknowledgment received: \(message)")
            }
            acknowledgementStatus = .success
            acknowledgmentMessage = message

            // Hide progress animation
            DispatchQueue.main.async {
                self.showCommsAnimation = false
            }
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ Acknowledgment failed: \(message)")
            }

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
                Task {
                    await WatchLogger.shared.log("Cleared ack banner and syncing animation")
                }
            }
        }
    }

    // MARK: - WCSessionDelegate

    /// Called when the session has completed activation
    /// Updates the reachability status and logs the activation state
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                Task {
                    await WatchLogger.shared.log("⌚️ Watch session activation failed: \(error)", force: true)
                    await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                    await WatchLogger.shared.persistLogsLocally()
                }
                return
            }

            if activationState == .activated {
                Task {
                    await WatchLogger.shared.log("⌚️ Watch session activated with state: \(activationState.rawValue)")
                }

                // Begin cold-start window on first activation
                self.startColdStartWindow()
                self.forceConditionalWatchStateUpdate()

                self.isReachable = session.isReachable

                Task {
                    await WatchLogger.shared.log("⌚️ Watch isReachable after activation: \(session.isReachable)")
                }
            }
        }
    }

    /// Handles incoming messages from the paired iPhone when Phone is in the foreground
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        Task {
            await WatchLogger.shared.log("⌚️ Watch received data: \(message)")
        }

        // If the message has a nested "watchState" dictionary with date as TimeInterval
        if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any],
           let timestamp = watchStateDict[WatchMessageKeys.date] as? TimeInterval
        {
            let date = Date(timeIntervalSince1970: timestamp)

            // Check if it's not older than 15 min
            if date >= Date().addingTimeInterval(-15 * 60) {
                Task {
                    await WatchLogger.shared.log("⌚️ Handling watchState from \(date)")
                }
                processWatchMessage(message)
            } else {
                Task {
                    await WatchLogger.shared.log("⌚️ Received outdated watchState data (\(date))")
                }
                DispatchQueue.main.async {
                    self.showSyncingAnimation = false
                }
            }
            return
        }

        // Delta update
        if let deltaDict = message[WatchMessageKeys.deltaUpdate] as? [String: Any] {
            processDeltaUpdate(deltaDict)
            return
        }

        // Config update
        if let config = message[WatchMessageKeys.config] as? [String: Any] {
            processConfigUpdate(config)
            return
        }

        // Else if the message is an "ack" at the top level
        // e.g. { "acknowledged": true, "message": "Started Temp Target...", "date": Date(...) }
        else if
            let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
            let ackMessage = message[WatchMessageKeys.message] as? String,
            let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String
        {
            let corrId = message[WatchMessageKeys.correlationId] as? String
            if !self.shouldProcessAck(correlationId: corrId) {
                Task {
                    await WatchLogger.shared.log("⌚️ Duplicate ack ignored (correlationId=\(corrId ?? "nil"))")
                }
                return
            }
            Task {
                await WatchLogger.shared
                    .log("⌚️ Handling ack with message: \(ackMessage), success: \(acknowledged), ackCode: \(ackCodeRaw)")
            }
            DispatchQueue.main.async {
                // For ack messages, we do NOT show “Syncing...”
                self.showSyncingAnimation = false
            }
            processWatchMessage(message)
            return

                    // Recommended bolus is also not part of the WatchState message, hence the extra condition here
        } else if
            let recommendedBolus = message[WatchMessageKeys.recommendedBolus] as? NSNumber
        {
            Task {
                await WatchLogger.shared.log("⌚️ Received recommended bolus: \(recommendedBolus)")
            }

            DispatchQueue.main.async {
                self.recommendedBolus = recommendedBolus.decimalValue
                self.showBolusCalculationProgress = false
            }

            return
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ Faulty data. Skipping...")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
        }
    }

    // MARK: - Delta processing
    private func processDeltaUpdate(_ delta: [String: Any]) {
        // Gate on activation and cold start
        guard let session = session, session.activationState == .activated else { return }
        if isColdStartWindowActive {
            requestWatchStateUpdate(manual: false)
            return
        }

        let lastSeq = UserDefaults.standard.integer(forKey: "trio.watch.lastProcessedSequence")
        guard let seq = delta[WatchMessageKeys.sequenceNumber] as? Int, seq > lastSeq else {
            Task { await WatchLogger.shared.log("⌚️ Ignoring delta: seq <= lastProcessed (") }
            return
        }

        // Optional: gap handling
        if seq - lastSeq > 20 {
            Task { await WatchLogger.shared.log("⌚️ Large sequence gap detected; requesting full refresh") }
            UserDefaults.standard.set(0, forKey: "trio.watch.lastProcessedSequence")
            requestWatchStateUpdate(manual: false)
            return
        }

        // Apply minimal fields
        var updated: [String: Any] = [:]
        if let timestamp = delta[WatchMessageKeys.date] as? TimeInterval {
            lastWatchStateUpdate = timestamp
            updated[WatchMessageKeys.date] = timestamp
        }
        if let cg = delta[WatchMessageKeys.currentGlucose] as? String { currentGlucose = cg; updated[WatchMessageKeys.currentGlucose] = cg }
        if let t = delta[WatchMessageKeys.trend] as? String { trend = t; updated[WatchMessageKeys.trend] = t }
        if let d = delta[WatchMessageKeys.delta] as? String { delta = d; updated[WatchMessageKeys.delta] = d }
        if let i = delta[WatchMessageKeys.iob] as? String { iob = i; updated[WatchMessageKeys.iob] = i }
        if let c = delta[WatchMessageKeys.cob] as? String { cob = c; updated[WatchMessageKeys.cob] = c }
        if let ll = delta[WatchMessageKeys.lastLoopTime] as? String { lastLoopTime = ll; updated[WatchMessageKeys.lastLoopTime] = ll }
        if let minY = (delta[WatchMessageKeys.minYAxisValue] as? NSNumber)?.decimalValue { minYAxisValue = minY; updated[WatchMessageKeys.minYAxisValue] = minY }
        if let maxY = (delta[WatchMessageKeys.maxYAxisValue] as? NSNumber)?.decimalValue { maxYAxisValue = maxY; updated[WatchMessageKeys.maxYAxisValue] = maxY }

        // Merge new readings
        if let readings = delta[WatchMessageKeys.newReadings] as? [[String: Any]] {
            let newValues: [(date: Date, glucose: Double, color: Color)] = readings.compactMap { r in
                guard let ts = r["date"] as? TimeInterval, let g = r["glucose"] as? Double, let colorHex = r["color"] as? String else { return nil }
                return (Date(timeIntervalSince1970: ts), g, colorHex.toColor())
            }
            let merged = mergeGlucoseValues(existing: glucoseValues, newValues: newValues)
            glucoseValues = pruneTo24Hours(merged)
        }

        // Update active presets if we have names
        if let overrideName = delta[WatchMessageKeys.activeOverrideName] as? String {
            overridePresets = overridePresets.map { OverridePresetWatch(name: $0.name, isEnabled: $0.name == overrideName) }
        }
        if let tempName = delta[WatchMessageKeys.activeTempTargetName] as? String {
            tempTargetPresets = tempTargetPresets.map { TempTargetPresetWatch(name: $0.name, isEnabled: $0.name == tempName) }
        }

        // Persist sequence
        UserDefaults.standard.set(seq, forKey: "trio.watch.lastProcessedSequence")

        // Persist snapshot and reload complication
        TrioComplicationDataStore.shared.saveSnapshotAndReloadIfNeeded(snapshot: updated, isColdStart: isColdStartWindowActive)

        // Schedule next background refresh adaptively
        scheduleNextBackgroundRefresh()
    }

    private func mergeGlucoseValues(
        existing: [(date: Date, glucose: Double, color: Color)],
        newValues: [(date: Date, glucose: Double, color: Color)]
    ) -> [(date: Date, glucose: Double, color: Color)] {
        var map = Dictionary(uniqueKeysWithValues: existing.map { ($0.date.timeIntervalSince1970, $0) })
        for nv in newValues {
            map[nv.date.timeIntervalSince1970] = nv
        }
        return map.values.sorted { $0.date < $1.date }
    }

    private func pruneTo24Hours(_ values: [(date: Date, glucose: Double, color: Color)]) -> [(date: Date, glucose: Double, color: Color)] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return values.filter { $0.date >= cutoff }
    }

    private func processConfigUpdate(_ cfg: [String: Any]) {
        if let overrideData = cfg[WatchMessageKeys.overridePresets] as? [[String: Any]] {
            overridePresets = overrideData.compactMap { data in
                guard let name = data["name"] as? String,
                      let isEnabled = data["isEnabled"] as? Bool
                else { return nil }
                return OverridePresetWatch(name: name, isEnabled: isEnabled)
            }
        }
        if let tempTargetData = cfg[WatchMessageKeys.tempTargetPresets] as? [[String: Any]] {
            tempTargetPresets = tempTargetData.compactMap { data in
                guard let name = data["name"] as? String,
                      let isEnabled = data["isEnabled"] as? Bool
                else { return nil }
                return TempTargetPresetWatch(name: name, isEnabled: isEnabled)
            }
        }

        if let maxBolusValue = cfg[WatchMessageKeys.maxBolus] as? NSNumber { maxBolus = maxBolusValue.decimalValue }
        if let maxCarbsValue = cfg[WatchMessageKeys.maxCarbs] as? NSNumber { maxCarbs = maxCarbsValue.decimalValue }
        if let maxFatValue = cfg[WatchMessageKeys.maxFat] as? NSNumber { maxFat = maxFatValue.decimalValue }
        if let maxProteinValue = cfg[WatchMessageKeys.maxProtein] as? NSNumber { maxProtein = maxProteinValue.decimalValue }
        if let bolusInc = cfg[WatchMessageKeys.bolusIncrement] as? NSNumber { bolusIncrement = bolusInc.decimalValue }
        if let confirmFaster = cfg[WatchMessageKeys.confirmBolusFaster] as? Bool { confirmBolusFaster = confirmFaster }
        if let minY = (cfg[WatchMessageKeys.minYAxisValue] as? NSNumber)?.decimalValue { minYAxisValue = minY }
        if let maxY = (cfg[WatchMessageKeys.maxYAxisValue] as? NSNumber)?.decimalValue { maxYAxisValue = maxY }

        // Save into snapshot and reload complication
        TrioComplicationDataStore.shared.saveSnapshotAndReloadIfNeeded(snapshot: cfg, isColdStart: isColdStartWindowActive)
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let cfg = userInfo[WatchMessageKeys.config] as? [String: Any] {
            processConfigUpdate(cfg)
            return
        }
        guard let snapshot = WatchStateSnapshot(from: userInfo) else {
            Task {
                await WatchLogger.shared.log("⌚️ Invalid snapshot received", force: true)
            }
            return
        }

        let lastProcessed = WatchStateSnapshot.loadLatestDateFromDisk()

        guard snapshot.date > lastProcessed else {
            Task {
                await WatchLogger.shared.log("⌚️ Ignoring outdated or duplicate WatchState snapshot", force: true)
            }
            return
        }

        WatchStateSnapshot.saveLatestDateToDisk(snapshot.date)

        DispatchQueue.main.async {
            self.scheduleUIUpdate(with: snapshot.payload)
        }
    }

    func session(_: WCSession, didFinish _: WCSessionUserInfoTransfer, error: (any Error)?) {
        if let error = error {
            Task {
                await WatchLogger.shared.log("⌚️ transferUserInfo failed with error: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }
    }

    /// Called when the reachability status of the paired iPhone changes
    /// Updates the local reachability status
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            Task {
                await WatchLogger.shared.log("⌚️ Watch reachability changed: \(session.isReachable)")
            }

            if session.isReachable {
                self.forceConditionalWatchStateUpdate()

                // reset input amounts
                self.bolusAmount = 0
                self.carbsAmount = 0

                // reset auth progress
                self.confirmationProgress = 0
            }
        }
    }

    // MARK: - Background refresh scheduling
    private func scheduleNextBackgroundRefresh() {
        #if os(watchOS)
            let extensionApp = WKExtension.shared()
            let interval = nextRefreshInterval()
            let preferredDate = Date().addingTimeInterval(interval)
            extensionApp.scheduleBackgroundRefresh(withPreferredDate: preferredDate, userInfo: nil) { error in
                Task {
                    await WatchLogger.shared.log("⌚️ Scheduled background refresh in \(interval)s (error: \(String(describing: error)))")
                }
            }
        #endif
    }

    private func nextRefreshInterval() -> TimeInterval {
        let now = Date().timeIntervalSince1970
        let stale = (now - (lastWatchStateUpdate ?? 0)) > 25 * 60
        if session?.isReachable == true {
            return stale ? 180 : 300 // 3 min when stale, 5 min otherwise
        } else {
            return 12 * 60 // 12 minutes when unreachable
        }
    }

    /// Conditionally triggers a watch state update if the last known update was too long ago or has never occurred.
    ///
    /// This method checks the `lastWatchStateUpdate` timestamp to determine how many seconds
    /// have elapsed since the last update under the following conditions
    ///  - If `lastWatchStateUpdate` is `nil` (meaning there has never been an update), or
    ///  - If more than 15 seconds have passed,
    ///
    /// it will show a syncing animation and request a new watch state update from the iPhone app.
    private func forceConditionalWatchStateUpdate() {
        guard let lastUpdateTimestamp = lastWatchStateUpdate else {
            Task {
                await WatchLogger.shared.log("Forcing initial WatchState update")
            }

            // If there's no recorded timestamp, we must force a fresh update immediately.
            showSyncingAnimation = true
            requestWatchStateUpdate(manual: false)
            return
        }

        let now = Date().timeIntervalSince1970
        let secondsSinceUpdate = now - lastUpdateTimestamp
        Task {
            await WatchLogger.shared.log("Time since last update: \(secondsSinceUpdate) seconds")
        }

        // If more than 15 seconds have elapsed since the last update, force an(other) update.
        if secondsSinceUpdate > 15 {
            showSyncingAnimation = true
            requestWatchStateUpdate(manual: false)
            return
        }
    }

    /// Handles incoming messages that either contain an acknowledgement or fresh watchState data  (<15 min)
    private func processWatchMessage(_ message: [String: Any]) {
        DispatchQueue.main.async {
            // 1) Acknowledgment logic
            if let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
               let ackMessage = message[WatchMessageKeys.message] as? String,
               let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String,
               let ackCode = AcknowledgmentCode(rawValue: ackCodeRaw)
            {
                DispatchQueue.main.async {
                    self.showSyncingAnimation = false
                }

                Task {
                    await WatchLogger.shared.log("⌚️ Received acknowledgment: \(ackMessage), success: \(acknowledged)")
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

            // 2) Raw watchState data
            if let watchStateData = message[WatchMessageKeys.watchState] as? [String: Any] {
                self.scheduleUIUpdate(with: watchStateData)
            }
        }
    }

    /// Accumulate new data, set isSyncing, and debounce final update
    private func scheduleUIUpdate(with newData: [String: Any]) {
        if let incomingTimestamp = newData[WatchMessageKeys.date] as? TimeInterval,
           let lastTimestamp = lastWatchStateUpdate,
           incomingTimestamp <= lastTimestamp
        {
            Task {
                await WatchLogger.shared.log("Skipping UI update — outdated WatchState (\(incomingTimestamp))")
            }
            return
        }

        // 1) Mark as syncing
        DispatchQueue.main.async {
            self.showSyncingAnimation = true
        }

        Task {
            await WatchLogger.shared.log("Merging new WatchState data with keys: \(newData.keys.joined(separator: ", "))")
        }

        // 2) Merge data into our pendingData
        pendingData.merge(newData) { _, newVal in newVal }

        // 3) Cancel any previous finalization
        finalizeWorkItem?.cancel()

        // 4) Create and schedule a new finalization
        let workItem = DispatchWorkItem { [self] in
            Task {
                await WatchLogger.shared.log("⏳ Debounced update fired")
            }
            self.finalizePendingData()
        }
        finalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    /// Applies all pending data to the watch state in one shot
    private func finalizePendingData() {
        guard !pendingData.isEmpty else {
            Task {
                await WatchLogger.shared.log("⚠️ finalizePendingData called with empty data")
            }

            // If we have no actual data, just end syncing
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Finalizing pending data")
        }

        // Actually set your main UI properties here
        processRawDataForWatchState(pendingData)

        // Persist snapshot for complication and trigger reloads with throttling
        TrioComplicationDataStore.shared.saveSnapshotAndReloadIfNeeded(
            snapshot: pendingData,
            isColdStart: isColdStartWindowActive
        )

        // Clear
        pendingData.removeAll()

        // Done - hide sync animation
        DispatchQueue.main.async {
            self.showSyncingAnimation = false
        }

        Task {
            await WatchLogger.shared.log("✅ Watch UI update complete")
        }
    }

    /// Updates the UI properties
    private func processRawDataForWatchState(_ message: [String: Any]) {
        Task {
            await WatchLogger.shared.log("Processing raw WatchState data with keys: \(message.keys.joined(separator: ", "))")
        }

        if let timestamp = message[WatchMessageKeys.date] as? TimeInterval {
            lastWatchStateUpdate = timestamp
            Task {
                await WatchLogger.shared.log("Updated lastWatchStateUpdate: \(timestamp)")
            }
        }

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
                      let timestamp = data["date"] as? TimeInterval,
                      let colorString = data["color"] as? String
                else { return nil }

                return (
                    Date(timeIntervalSince1970: timestamp),
                    glucose,
                    colorString.toColor() // Convert colorString to Color
                )
            }
            .sorted { $0.date < $1.date }
        }

        if let minYAxisValue = message[WatchMessageKeys.minYAxisValue] {
            if let decimalValue = (minYAxisValue as? NSNumber)?.decimalValue {
                self.minYAxisValue = decimalValue
            }
        }

        if let maxYAxisValue = message[WatchMessageKeys.maxYAxisValue] {
            if let decimalValue = (maxYAxisValue as? NSNumber)?.decimalValue {
                self.maxYAxisValue = decimalValue
            }
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

        if let maxBolusValue = message[WatchMessageKeys.maxBolus] {
            if let decimalValue = (maxBolusValue as? NSNumber)?.decimalValue {
                maxBolus = decimalValue
            }
        }

        if let maxCarbsValue = message[WatchMessageKeys.maxCarbs] {
            if let decimalValue = (maxCarbsValue as? NSNumber)?.decimalValue {
                maxCarbs = decimalValue
            }
        }

        if let maxFatValue = message[WatchMessageKeys.maxFat] {
            if let decimalValue = (maxFatValue as? NSNumber)?.decimalValue {
                maxFat = decimalValue
            }
        }

        if let maxProteinValue = message[WatchMessageKeys.maxProtein] {
            if let decimalValue = (maxProteinValue as? NSNumber)?.decimalValue {
                maxProtein = decimalValue
            }
        }

        if let bolusIncrement = message[WatchMessageKeys.bolusIncrement] {
            if let decimalValue = (bolusIncrement as? NSNumber)?.decimalValue {
                self.bolusIncrement = decimalValue
            }
        }

        if let confirmBolusFaster = message[WatchMessageKeys.confirmBolusFaster] {
            if let booleanValue = confirmBolusFaster as? Bool {
                self.confirmBolusFaster = booleanValue
            }
        }
    }
}
