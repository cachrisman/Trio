import Foundation
import SwiftUI
import WatchConnectivity

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

    // MARK: - Debouncing and batch processing helpers

    /// Temporary storage for new data arriving via WatchConnectivity.
    private var pendingData: [String: Any] = [:]

    /// Work item to schedule finalizing the pending data.
    private var finalizeWorkItem: DispatchWorkItem?

    /// A flag to tell the UI we’re still updating.
    var showSyncingAnimation: Bool = false

    var deviceType = WatchSize.current

    override init() {
        super.init()
        setupSession()
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
        // Check session readiness
        guard let session = session, session.activationState == .activated else {
            Task {
                await WatchLogger.shared.log("⌚️❌ Session not ready - skipping message")
            }
            return
        }
        
        Task {
            await WatchLogger.shared.log("⌚️ Watch received data: \(message)")
        }

        // Handle delta update
        if let deltaDict = message[WatchMessageKeys.watchStateDelta] as? [String: Any] {
            Task {
                await WatchLogger.shared.log("⌚️ Received delta update")
            }
            processDeltaUpdate(deltaDict)
            return
        }

        // If the message has a nested "watchState" dictionary with date as TimeInterval (full update)
        if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any],
           let timestamp = watchStateDict[WatchMessageKeys.date] as? TimeInterval
        {
            let date = Date(timeIntervalSince1970: timestamp)

            // Check if it's not older than 15 min
            if date >= Date().addingTimeInterval(-15 * 60) {
                Task {
                    await WatchLogger.shared.log("⌚️ Handling watchState from \(date)")
                }
                
                // Process full update - reset sequence on watch side
                processFullUpdate(watchStateDict)
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

        // Else if the message is an "ack" at the top level
        // e.g. { "acknowledged": true, "message": "Started Temp Target...", "date": Date(...) }
        else if
            let acknowledged = message[WatchMessageKeys.acknowledged] as? Bool,
            let ackMessage = message[WatchMessageKeys.message] as? String,
            let ackCodeRaw = message[WatchMessageKeys.ackCode] as? String
        {
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

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Check session readiness
        guard let session = session, session.activationState == .activated else {
            Task {
                await WatchLogger.shared.log("⌚️❌ Session not ready - skipping userInfo")
            }
            return
        }
        
        // Handle delta update from userInfo
        if let deltaDict = userInfo[WatchMessageKeys.watchStateDelta] as? [String: Any] {
            Task {
                await WatchLogger.shared.log("⌚️ Received delta update via userInfo")
            }
            processDeltaUpdate(deltaDict)
            return
        }
        
        // Handle full update from userInfo
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
        
        // Process full update - reset sequence
        processFullUpdate(snapshot.payload)
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
            requestWatchStateUpdate()
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
            requestWatchStateUpdate()
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
    
    // MARK: - Delta Processing
    
    /// Process delta update with sequence validation and deduplication
    private func processDeltaUpdate(_ deltaDict: [String: Any]) {
        // Parse delta
        guard let delta = WatchGlucoseDelta(from: deltaDict) else {
            Task {
                await WatchLogger.shared.log("⌚️❌ Failed to parse delta update")
            }
            logDecision(action: "skip_delta", reason: "parse_failed")
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        Task {
            await WatchLogger.shared.log("⌚️ Processing delta: seq=\(delta.sequenceNumber), correlationId=\(delta.correlationId)")
        }
        
        // Check for cold start - request full refresh if in cold start window
        let isColdStart = WatchSyncUtilities.isColdStart(withinSeconds: 60.0)
        if isColdStart {
            Task {
                await WatchLogger.shared.log("⌚️ Cold start detected - requesting full refresh")
            }
            logDecision(action: "request_full", reason: "cold_start")
            requestFullRefresh()
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        // Deduplication: check correlation ID
        if WatchSyncUtilities.isCorrelationIdSeen(delta.correlationId) {
            Task {
                await WatchLogger.shared.log("⌚️ Skipping duplicate delta (correlationId: \(delta.correlationId))")
            }
            logDecision(action: "skip_delta", reason: "duplicate_correlation_id", details: "correlationId: \(delta.correlationId)")
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        // Sequence validation
        let lastProcessedSeq = WatchSyncUtilities.getLastProcessedSequence()
        let sequenceGap = delta.sequenceNumber - lastProcessedSeq
        
        // Handle sequence gaps
        if delta.sequenceNumber <= lastProcessedSeq {
            Task {
                await WatchLogger.shared.log("⌚️⚠️ Out-of-order or duplicate delta: seq=\(delta.sequenceNumber) <= lastSeq=\(lastProcessedSeq)")
            }
            logDecision(action: "skip_delta", reason: "out_of_order", details: "seq: \(delta.sequenceNumber), lastSeq: \(lastProcessedSeq)")
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        // If gap > 20, reset and request full refresh
        if sequenceGap > 20 {
            Task {
                await WatchLogger.shared.log("⌚️⚠️ Large sequence gap (\(sequenceGap)) - requesting full refresh")
            }
            logDecision(action: "request_full", reason: "large_sequence_gap", details: "gap: \(sequenceGap)")
            WatchSyncUtilities.resetLastProcessedSequence()
            requestFullRefresh()
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        // Check staleness (> 25 minutes) - request full refresh
        if WatchSyncUtilities.isLastUpdateStale() {
            Task {
                await WatchLogger.shared.log("⌚️⚠️ Stale data detected - requesting full refresh")
            }
            logDecision(action: "request_full", reason: "stale_data")
            WatchSyncUtilities.resetLastProcessedSequence()
            requestFullRefresh()
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }
        
        // Apply delta update
        logDecision(action: "apply_delta", reason: "valid", details: "seq: \(delta.sequenceNumber), gap: \(sequenceGap)")
        DispatchQueue.main.async {
            self.applyDelta(delta)
            WatchSyncUtilities.setLastProcessedSequence(delta.sequenceNumber)
            self.showSyncingAnimation = false
        }
        
        Task {
            await WatchLogger.shared.log("⌚️✅ Delta processed successfully (seq: \(delta.sequenceNumber))")
        }
    }
    
    /// Process full state update (resets sequence)
    private func processFullUpdate(_ watchStateDict: [String: Any]) {
        Task {
            await WatchLogger.shared.log("⌚️ Processing full update - resetting sequence")
        }
        
        logDecision(action: "apply_full", reason: "full_update_received")
        
        // Reset sequence on full update
        WatchSyncUtilities.resetLastProcessedSequence()
        
        // Update UI
        DispatchQueue.main.async {
            self.scheduleUIUpdate(with: watchStateDict)
        }
    }
    
    /// Apply delta to current state
    @MainActor private func applyDelta(_ delta: WatchGlucoseDelta) {
        // Update current glucose values if provided
        if let currentGlucose = delta.currentGlucose {
            self.currentGlucose = currentGlucose
        }
        
        if let trend = delta.trend {
            self.trend = trend
        }
        
        if let deltaValue = delta.delta {
            self.delta = deltaValue
        }
        
        if let iob = delta.iob {
            self.iob = iob
        }
        
        if let cob = delta.cob {
            self.cob = cob
        }
        
        if let lastLoopTime = delta.lastLoopTime {
            self.lastLoopTime = lastLoopTime
        }
        
        // Merge new glucose readings (avoid duplicates)
        if !delta.newReadings.isEmpty {
            var existingDates = Set(glucoseValues.map { $0.date })
            let newReadings = delta.newReadings.filter { !existingDates.contains($0.date) }
            
            glucoseValues.append(contentsOf: newReadings.map { (date: $0.date, glucose: $0.glucose, color: $0.color.toColor()) })
            glucoseValues.sort { $0.date < $1.date }
            
            // Prune to 24 hours
            let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60)
            glucoseValues = glucoseValues.filter { $0.date >= cutoffDate }
        }
        
        // Update axis values if provided
        if let minYAxisValue = delta.minYAxisValue {
            self.minYAxisValue = minYAxisValue
        }
        
        if let maxYAxisValue = delta.maxYAxisValue {
            self.maxYAxisValue = maxYAxisValue
        }
        
        // Update active preset names if provided
        if let activeOverrideName = delta.activeOverrideName {
            // Find and update override preset
            if let index = overridePresets.firstIndex(where: { $0.name == activeOverrideName }) {
                var updatedPresets = overridePresets
                updatedPresets[index] = OverridePresetWatch(name: activeOverrideName, isEnabled: true)
                // Disable all others
                updatedPresets = updatedPresets.map { preset in
                    OverridePresetWatch(name: preset.name, isEnabled: preset.name == activeOverrideName)
                }
                overridePresets = updatedPresets
            }
        }
        
        if let activeTempTargetName = delta.activeTempTargetName {
            // Find and update temp target preset
            if let index = tempTargetPresets.firstIndex(where: { $0.name == activeTempTargetName }) {
                var updatedPresets = tempTargetPresets
                updatedPresets[index] = TempTargetPresetWatch(name: activeTempTargetName, isEnabled: true)
                // Disable all others
                updatedPresets = updatedPresets.map { preset in
                    TempTargetPresetWatch(name: preset.name, isEnabled: preset.name == activeTempTargetName)
                }
                tempTargetPresets = updatedPresets
            }
        }
        
        // Save snapshot for complication
        saveComplicationSnapshot()
    }
    
    /// Save snapshot for complication with glucose-change detection
    private func saveComplicationSnapshot() {
        var snapshot: [String: Any] = [:]
        snapshot[WatchMessageKeys.date] = Date().timeIntervalSince1970
        snapshot[WatchMessageKeys.currentGlucose] = currentGlucose
        snapshot[WatchMessageKeys.currentGlucoseColorString] = currentGlucoseColorString
        snapshot[WatchMessageKeys.trend] = trend ?? ""
        snapshot[WatchMessageKeys.delta] = delta ?? ""
        snapshot[WatchMessageKeys.iob] = iob ?? ""
        snapshot[WatchMessageKeys.cob] = cob ?? ""
        snapshot[WatchMessageKeys.lastLoopTime] = lastLoopTime ?? ""
        
        // Check if glucose changed
        let glucoseChanged = TrioComplicationDataStore.hasGlucoseChanged(newGlucose: currentGlucose)
        let isColdStart = WatchSyncUtilities.isColdStart(withinSeconds: 60.0)
        
        // Save snapshot
        TrioComplicationDataStore.saveSnapshot(snapshot)
        
        // Save glucose history
        let historyValues = glucoseValues.map { value in
            WatchGlucoseObject(date: value.date, glucose: value.glucose, color: value.color.toHexString())
        }
        TrioComplicationDataStore.saveGlucoseHistory(historyValues)
        
        // Log complication action
        Task {
            await WatchLogger.shared.log("📊 Complication Action: glucoseChanged=\(glucoseChanged), isColdStart=\(isColdStart), currentGlucose=\(currentGlucose)")
        }
        
        // Reload complication timeline
        if glucoseChanged {
            TrioComplicationDataStore.reloadTimelines(isColdStart: isColdStart)
        } else {
            // Schedule backup reload
            TrioComplicationDataStore.reloadTimelines(isColdStart: isColdStart)
        }
    }
    
    /// Request full refresh from phone
    private func requestFullRefresh() {
        guard let session = session, session.activationState == .activated, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cannot request full refresh - session not ready")
            }
            logSessionState(reason: "cannot_request_full_refresh")
            return
        }
        
        Task {
            await WatchLogger.shared.log("⌚️ Requesting full refresh from phone")
        }
        
        debug(.watchManager, "📊 Background Refresh Trigger: watch_requested_full_refresh")
        
        let message: [String: Any] = [
            WatchMessageKeys.requestFullRefresh: true
        ]
        
        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error requesting full refresh: \(error)")
            }
        }
    }
    
    /// Log session state for telemetry (watch side)
    private func logSessionState(reason: String, details: String? = nil) {
        guard let session = session else {
            Task {
                await WatchLogger.shared.log("📊 Session State (watch): reason=\(reason), session=nil")
            }
            return
        }
        
        var stateInfo = "reason=\(reason), isPaired=\(session.isPaired), isReachable=\(session.isReachable), isWatchAppInstalled=\(session.isWatchAppInstalled), activationState=\(session.activationState)"
        if let details = details {
            stateInfo += ", details=\(details)"
        }
        
        Task {
            await WatchLogger.shared.log("📊 Session State (watch): \(stateInfo)")
        }
    }
    
    /// Log decision points for telemetry (watch side)
    private func logDecision(action: String, reason: String, details: String? = nil) {
        var decisionInfo = "action=\(action), reason=\(reason)"
        if let details = details {
            decisionInfo += ", details=\(details)"
        }
        
        Task {
            await WatchLogger.shared.log("📊 Decision (watch): \(decisionInfo)")
        }
    }
}

// MARK: - String Extension for Color Conversion

extension String {
    func toColor() -> Color {
        // Parse hex color string to Color
        guard self.hasPrefix("#"), self.count >= 7 else {
            return .white
        }
        
        let hexString = String(self.dropFirst())
        guard let hexValue = UInt64(hexString, radix: 16) else {
            return .white
        }
        
        let red = Double((hexValue & 0xFF0000) >> 16) / 255.0
        let green = Double((hexValue & 0xFF00) >> 8) / 255.0
        let blue = Double(hexValue & 0xFF) / 255.0
        
        return Color(red: red, green: green, blue: blue)
    }
    
    func toHexString() -> String {
        // If already hex, return as is
        if self.hasPrefix("#") {
            return self
        }
        return self
    }
}

extension Color {
    func toHexString() -> String {
        // Simplified - default to white
        return "#ffffff"
    }
}
