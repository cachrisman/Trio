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
    
    // MARK: - Cold-start & Sync Management
    
    /// Tracks if this is the first activation after process start
    private var isFirstActivation: Bool = true
    
    /// Tracks if we're in cold-start window
    var isColdStart: Bool = false
    
    /// Cold-start window duration (seconds) - can be tuned from 60 → 10-15 once stable
    private let coldStartWindowSeconds: TimeInterval = 60
    
    /// Task to end cold-start window
    private var coldStartTask: Task<Void, Never>?
    
    /// Last processed sequence number for delta updates
    private var lastProcessedSequence: Int {
        get { UserDefaults.standard.integer(forKey: "trio.watch.lastProcessedSequence") }
        set { UserDefaults.standard.set(newValue, forKey: "trio.watch.lastProcessedSequence") }
    }
    
    /// Ring buffer for correlation ID deduplication (size ~50)
    private var processedCorrelationIds: [String] = []
    private let correlationIdBufferSize = 50
    
    /// Complication data store
    private let complicationStore = TrioComplicationDataStore.shared
    
    // MARK: - Manual Refresh State
    
    /// Indicates if manual refresh is in progress
    var isManualRefreshing: Bool = false
    
    /// Manual refresh result message
    var manualRefreshMessage: String = ""
    
    /// Show manual refresh success overlay
    var showManualRefreshSuccess: Bool = false

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
    
    // MARK: - Session Readiness
    
    /// Checks if the WatchConnectivity session is ready for receiving/sending data
    private func isSessionReady() -> Bool {
        guard let session = session else {
            Task {
                await WatchLogger.shared.log("⌚️❌ No session available")
            }
            return false
        }
        
        guard session.activationState == .activated else {
            Task {
                await WatchLogger.shared.log("⌚️ Session not activated (state: \(session.activationState.rawValue))")
            }
            
            // Try to activate if needed
            if session.activationState == .notActivated {
                Task {
                    await WatchLogger.shared.log("⌚️ Attempting to activate session...")
                }
                session.activate()
            }
            return false
        }
        
        return true
    }
    
    // MARK: - Cold-Start Management
    
    /// Marks the start of a cold-start window (called on first activation after process start)
    func startColdStartWindow() {
        guard isFirstActivation else { return }
        
        isFirstActivation = false
        isColdStart = true
        
        // Sync cold-start state to complication store
        complicationStore.isColdStart = true
        
        Task {
            await WatchLogger.shared.log("⌚️ 🥶 Cold-start window began (\(Int(coldStartWindowSeconds))s)")
        }
        
        // Start timer to end cold-start window
        coldStartTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(coldStartWindowSeconds * 1_000_000_000))
            
            await MainActor.run {
                self.isColdStart = false
                self.complicationStore.isColdStart = false
                Task {
                    await WatchLogger.shared.log("⌚️ ✅ Cold-start window ended")
                }
            }
        }
    }
    
    /// Checks if data is stale (>25 min since last update)
    private func isDataStale() -> Bool {
        guard let lastUpdate = lastWatchStateUpdate else {
            return true // Never received data
        }
        
        let now = Date().timeIntervalSince1970
        let staleness = now - lastUpdate
        let staleThreshold: TimeInterval = 25 * 60 // 25 minutes
        
        return staleness > staleThreshold
    }
    
    /// Resets sequence tracking (used for full refresh or manual refresh)
    func resetSequenceTracking() {
        lastProcessedSequence = 0
        Task {
            await WatchLogger.shared.log("⌚️ 🔄 Reset sequence tracking")
        }
    }
    
    /// Checks if a correlation ID has already been processed (deduplication)
    private func hasProcessedCorrelationId(_ id: String) -> Bool {
        processedCorrelationIds.contains(id)
    }
    
    /// Marks a correlation ID as processed
    private func markCorrelationIdProcessed(_ id: String) {
        processedCorrelationIds.append(id)
        
        // Maintain ring buffer size
        if processedCorrelationIds.count > correlationIdBufferSize {
            processedCorrelationIds.removeFirst()
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
                    await WatchLogger.shared.log("⌚️ isPaired: \(session.isPaired), isWatchAppInstalled: \(session.isWatchAppInstalled)")
                }
                
                // Start cold-start window on first activation
                self.startColdStartWindow()
                
                // Check if data is stale and request full refresh if needed
                if self.isDataStale() {
                    Task {
                        await WatchLogger.shared.log("⌚️ Data is stale (>25 min), requesting full refresh and resetting sequence")
                    }
                    self.resetSequenceTracking()
                    self.forceConditionalWatchStateUpdate()
                } else {
                    self.forceConditionalWatchStateUpdate()
                }

                self.isReachable = session.isReachable

                Task {
                    await WatchLogger.shared.log("⌚️ Watch isReachable after activation: \(session.isReachable)")
                }
            }
        }
    }

    /// Handles incoming messages from the paired iPhone when Phone is in the foreground
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        // Gate: Check session readiness
        guard isSessionReady() else {
            Task {
                await WatchLogger.shared.log("⌚️ Ignoring message: session not ready")
            }
            return
        }
        
        // Extract correlation ID if present
        let correlationId = message[WatchMessageKeys.correlationId] as? String
        
        Task {
            await WatchLogger.shared.log("⌚️ Watch received data (correlationId: \(correlationId ?? "nil")): \(message.keys.joined(separator: ", "))")
        }
        
        // Dedupe: Check if we've already processed this correlation ID
        if let corrId = correlationId, hasProcessedCorrelationId(corrId) {
            Task {
                await WatchLogger.shared.log("⌚️ Ignoring duplicate message (correlationId: \(corrId))")
            }
            return
        }
        
        // Mark correlation ID as processed
        if let corrId = correlationId {
            markCorrelationIdProcessed(corrId)
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
        // Gate: Check session readiness
        guard isSessionReady() else {
            Task {
                await WatchLogger.shared.log("⌚️ Ignoring userInfo: session not ready")
            }
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
        
        // Save to complication data store
        saveToComplicationStore()
    }
    
    // MARK: - Complication Integration
    
    /// Saves current state to complication data store for widget display
    private func saveToComplicationStore() {
        Task { @MainActor in
            complicationStore.saveSnapshot(
                currentGlucose: self.currentGlucose,
                currentGlucoseColor: self.currentGlucoseColorString ?? "#ffffff",
                trend: self.trend,
                delta: self.delta,
                iob: self.iob,
                cob: self.cob,
                lastLoopTime: self.lastLoopTime,
                minYAxis: Double(truncating: self.minYAxisValue as NSNumber),
                maxYAxis: Double(truncating: self.maxYAxisValue as NSNumber)
            )
            
            // Save glucose history (24h)
            complicationStore.saveGlucoseHistory(self.glucoseValues)
        }
    }
    
    // MARK: - Manual Refresh
    
    /// Triggers a manual full refresh (resets sequences and requests fresh data)
    func triggerManualRefresh() {
        Task {
            await WatchLogger.shared.log("⌚️ 🔄 Manual refresh triggered")
        }
        
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Manual refresh aborted: session not reachable")
            }
            
            DispatchQueue.main.async {
                self.manualRefreshMessage = "Phone not reachable"
                self.isManualRefreshing = false
                self.showManualRefreshSuccess = true
                
                // Auto-dismiss after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.showManualRefreshSuccess = false
                }
            }
            return
        }
        
        DispatchQueue.main.async {
            self.isManualRefreshing = true
            self.showSyncingAnimation = true
        }
        
        Task {
            await WatchLogger.shared.log("⌚️ Resetting sequence tracking for manual refresh")
        }
        
        // Reset sequence tracking
        resetSequenceTracking()
        
        // Request fresh data
        requestWatchStateUpdate()
        
        // Set success state after a short delay (data will arrive separately)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.manualRefreshMessage = "Refreshing..."
            self.isManualRefreshing = false
            self.showManualRefreshSuccess = true
            
            // Reload complication
            self.complicationStore.forceReload()
            
            // Auto-dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showManualRefreshSuccess = false
            }
        }
    }
}
