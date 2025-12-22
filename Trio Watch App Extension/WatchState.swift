//
//  WatchState.swift
//
//  This file defines the WatchState class, which manages all communication and data
//  synchronization between the Watch app and the paired iPhone using WatchConnectivity.
//  It handles receiving glucose and loop state data, managing treatment inputs
//  (bolus, carbs, overrides), updating the UI and complication, and sending requests
//  to the iPhone. WatchState ensures robust state management for all watch glucose
//  display and treatment features and is the central source of truth for the app’s UI.
//
import Foundation
import SwiftUI
import WatchConnectivity
import WidgetKit

/// Manages communication and synchronization between the Watch app and the paired iPhone using WatchConnectivity.
/// Handles glucose data, loop status, treatment requests, and updates to the complication and UI.
@Observable final class WatchState: NSObject, WCSessionDelegate {
    /// Shared singleton instance for background and UI access.
    static let shared = WatchState()

    // MARK: - Properties

    // MARK: - WatchConnectivity

    /// The WatchConnectivity session instance used for communication.
    var session: WCSession?
    /// Indicates if the paired iPhone is currently reachable.
    var isReachable = false

    var lastWatchStateUpdate: Date?

    /// Defines the keys used in WatchConnectivity payloads to ensure consistency.
    private enum WatchPayloadKey {
        static let snapshot = "watchState"
        static let glucose = "currentGlucose"
        static let trend = "trend"
        static let delta = "delta"
        static let date = "date"
        static let state = "state"
        static let glucoseColor = "currentGlucoseColorString"
    }

    // MARK: - Glucose and Loop Data

    /// The current glucose value as a string, shown in the main UI and complication.
    var currentGlucose: String = "--"
    /// The hex color string for the current glucose, used for display color.
    var currentGlucoseColorString: String = "#ffffff"
    /// The trend string (e.g. "Flat", "SingleUp").
    var trend: String? = ""
    /// The delta string (change since last reading).
    var delta: String? = "--"
    /// Array of past glucose readings for graph display, each with a timestamp, value, and display color.
    var glucoseValues: [(date: Date, glucose: Double, color: Color)] = []
    /// Minimum and maximum Y-axis values for the glucose graph.
    var minYAxisValue: Decimal = 39
    var maxYAxisValue: Decimal = 200
    /// Current Carbs On Board (COB) and Insulin On Board (IOB) values as strings.
    var cob: String? = "--"
    var iob: String? = "--"
    /// The time of the last successful loop as a display string.
    var lastLoopTime: String? = "--"
    /// Override and temp target presets available for quick selection.
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []

    // MARK: - Treatment Inputs (Bolus, Carbs, Fat, Protein)

    /// Amount of carbs to deliver (for combined meal-bolus treatments).
    var carbsAmount: Int = 0
    var fatAmount: Int = 0
    var proteinAmount: Int = 0
    var bolusAmount: Double = 0.0
    var confirmationProgress: Double = 0.0

    // MARK: - Safety Limits and Dosing

    /// Safety limits for bolus, carbs, fat, and protein entry.
    var maxBolus: Decimal = 10
    var maxCarbs: Decimal = 250
    var maxFat: Decimal = 250
    var maxProtein: Decimal = 250

    /// Pump-specific bolus increment value.
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // MARK: - Acknowledgment and UI Feedback

    /// Controls for showing communication animations and banners after sending treatments.
    var showCommsAnimation: Bool = false
    var showAcknowledgmentBanner: Bool = false
    var acknowledgementStatus: AcknowledgementStatus = .pending
    var acknowledgmentMessage: String = ""
    var shouldNavigateToRoot: Bool = true

    private var activationTimestamp: TimeInterval?
    private var forcedSinceActivation = false

    /// Indicates whether the app is within the "cold start" window after activation.
    private var isColdStart: Bool {
        guard let activationTimestamp else { return true }
        return Date().timeIntervalSince1970 - activationTimestamp < 60 // 1-min window
    }

    /// Marks that the app became active; used to detect cold start windows.
    func noteAppBecameActive() {
        activationTimestamp = Date().timeIntervalSince1970
        forcedSinceActivation = false
        Task { await WatchLogger.shared.log("⌚️ Cold start window active for 60 s") }
    }

    /// Controls display of bolus calculation progress.
    var showBolusCalculationProgress: Bool = false

    // MARK: - Meal Bolus Stepper

    /// Current step in the meal bolus workflow.
    var mealBolusStep: MealBolusStep = .savingCarbs
    var isMealBolusCombo: Bool = false

    var recommendedBolus: Decimal = 0

    // MARK: - Debouncing and batch processing helpers

    /// Temporary storage for new data arriving via WatchConnectivity, used to debounce UI updates.
    private var pendingData: [String: Any] = [:]

    /// Work item to schedule finalizing the pending data for debounced UI updates.
    private var finalizeWorkItem: DispatchWorkItem?

    /// Work item for sync timeout mechanism.
    var syncTimeoutWorkItem: DispatchWorkItem?

    /// A flag to tell the UI we're still updating (syncing).
    var showSyncingAnimation: Bool = false

    /// Background refresh statistics for monitoring
    private var backgroundRefreshCount = 0
    private var lastBackgroundRefreshDate: Date?

    var deviceType = WatchSize.current

    override init() {
        super.init()
        setupSession()

        // Force an initial complication update after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forceComplicationUpdate()
            self.scheduleBackgroundRefresh()
        }
    }

    /// Configures and activates the WatchConnectivity session if supported on the device.
    /// Sets self as the delegate and logs activation.
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
                await WatchLogger.shared.log("⚠️ WCSession is not supported on this device")
            }
        }
    }

    // MARK: – Handle Acknowledgement Messages FROM Phone

    /// Handles acknowledgment messages from the iPhone for treatments or requests.
    /// Updates UI banners, comms animation, and logs the result.
    /// - Parameters:
    ///   - success: Whether the action was acknowledged as successful.
    ///   - message: The message to display to the user.
    ///   - isFinal: Whether this is the final acknowledgment in a sequence (combo).
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
                await WatchLogger.shared.log("⚠️ Acknowledgment failed: \(message)")
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

    /// Called when the WatchConnectivity session completes activation.
    /// Updates the reachability status and logs the activation state.
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                Task {
                    await WatchLogger.shared.log("⚠️ Watch session activation failed: \(error)", force: true)
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

    /// Handles incoming messages from the paired iPhone when the phone is in the foreground.
    /// Processes WatchState updates, acknowledgments, and recommended bolus messages.
    /// - Parameters:
    ///   - session: The WCSession instance (unused).
    ///   - message: The message dictionary received from the phone.
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        Task {
            await WatchLogger.shared.log("⌚️ Watch received data: \(message)")
        }

        // If the message has a nested "watchState" dictionary with date
        if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any],
           let date = watchStateDict[WatchMessageKeys.date] as? Date
        {
            Task {
                await WatchLogger.shared.log("📱 Received WatchState data:")
                await WatchLogger.shared.log("   📅 Date: \(date)")
                await WatchLogger.shared
                    .log("   🩸 Glucose: \(watchStateDict[WatchMessageKeys.currentGlucose] as? String ?? "--")")
                await WatchLogger.shared.log("   📈 Trend: \(watchStateDict[WatchMessageKeys.trend] as? String ?? "--")")
                await WatchLogger.shared.log("   📊 Delta: \(watchStateDict[WatchMessageKeys.delta] as? String ?? "--")")
            }

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
                await WatchLogger.shared.log("⚠️ Faulty data. Skipping...")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task {
            await WatchLogger.shared.log("📱 Received userInfo with keys: \(userInfo.keys.joined(separator: ", "))")
        }

        // 1. Look for the nested 'watchState' dictionary first.
        guard let snapshot = userInfo[WatchPayloadKey.snapshot] as? [String: Any] else {
            Task {
                let keys = userInfo.keys.map { $0 }.joined(separator: ", ")
                let types = userInfo.values.map { "\(type(of: $0))" }.joined(separator: ", ")
                await WatchLogger.shared.log(
                    "❌ Invalid snapshot received. Expected 'watchState' key. Got keys: \(keys). Types: \(types)"
                )
            }
            return
        }

        // 2. Extract values from the nested snapshot dictionary using the new keys.
        Task {
            await WatchLogger.shared.log("📱 Parsing snapshot data:")
            await WatchLogger.shared.log("   📅 Date: \(snapshot[WatchPayloadKey.date] ?? "nil")")
            await WatchLogger.shared.log("   🩸 Glucose: \(snapshot[WatchPayloadKey.glucose] ?? "nil")")
            await WatchLogger.shared.log("   📈 Trend: \(snapshot[WatchPayloadKey.trend] ?? "nil")")
            await WatchLogger.shared.log("   📊 Delta: \(snapshot[WatchPayloadKey.delta] ?? "nil")")
            await WatchLogger.shared.log("   🎨 Glucose Color: \(snapshot[WatchPayloadKey.glucoseColor] ?? "nil")")
        }

        guard let glucose = snapshot[WatchPayloadKey.glucose] as? String,
              let trend = snapshot[WatchPayloadKey.trend] as? String,
              let delta = snapshot[WatchPayloadKey.delta] as? String,
              let readingDate = snapshot[WatchPayloadKey.date] as? Date
        else {
            Task {
                await WatchLogger.shared.log("❌ Snapshot dictionary is missing required fields.")
                await WatchLogger.shared.log("   📅 Date type: \(type(of: snapshot[WatchPayloadKey.date] ?? "nil"))")
                await WatchLogger.shared.log("   🩸 Glucose type: \(type(of: snapshot[WatchPayloadKey.glucose] ?? "nil"))")
                await WatchLogger.shared.log("   📈 Trend type: \(type(of: snapshot[WatchPayloadKey.trend] ?? "nil"))")
                await WatchLogger.shared.log("   📊 Delta type: \(type(of: snapshot[WatchPayloadKey.delta] ?? "nil"))")
            }
            return
        }

        let state = snapshot[WatchPayloadKey.state] as? String
        let date = Date()

        // 1. Check if we have a previously saved snapshot.
        if let lastSnapshot = TrioComplicationDataStore.shared.latestSnapshot() {
            // 2. Compare the reading date AND glucose value to detect true duplicates.
            // Only skip if both timestamp and glucose value are identical.
            if lastSnapshot.readingDate == readingDate && lastSnapshot.glucose == glucose {
                Task {
                    await WatchLogger.shared
                        .log("⏭️ Skipping duplicate snapshot with date: \(readingDate) and glucose: \(glucose)")
                }
                // If both timestamp and glucose are the same, we assume the data is old.
                return
            } else if lastSnapshot.readingDate == readingDate && lastSnapshot.glucose != glucose {
                Task {
                    await WatchLogger.shared
                        .log("🔄 Same timestamp but different glucose - updating: \(lastSnapshot.glucose) → \(glucose)")
                }
            }
        }

        Task {
            await WatchLogger.shared.log("✅ Parsed and accepted new snapshot: \(glucose) \(trend) at \(date)")
        }

        // 3. Save the parsed data.
        let glucoseColor = snapshot[WatchPayloadKey.glucoseColor] as? String
        let complicationSnapshot = TrioComplicationSnapshot(
            glucose: glucose,
            trend: trend,
            delta: delta,
            readingDate: readingDate,
            date: date,
            state: state,
            glucoseColor: glucoseColor
        )

        TrioComplicationDataStore.shared.save(complicationSnapshot)
    }

    /// Retry count for failed transfers
    private var transferRetryCount = 0
    private let maxTransferRetries = 3
    private var retryWorkItem: DispatchWorkItem?

    func session(_: WCSession, didFinish _: WCSessionUserInfoTransfer, error: (any Error)?) {
        if let error = error {
            Task {
                await WatchLogger.shared.log("⚠️ transferUserInfo failed with error: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }

            // Implement retry logic for failed transfers
            if transferRetryCount < maxTransferRetries {
                transferRetryCount += 1
                let retryDelay = TimeInterval(transferRetryCount * 2) // Exponential backoff: 2s, 4s, 6s

                Task {
                    await WatchLogger.shared
                        .log("🔄 Scheduling retry \(transferRetryCount)/\(maxTransferRetries) in \(retryDelay)s")
                }

                retryWorkItem?.cancel()
                retryWorkItem = DispatchWorkItem { [weak self] in
                    self?.requestWatchStateUpdate()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retryWorkItem!)
            } else {
                Task {
                    await WatchLogger.shared.log("❌ Max retries reached, using fallback data")
                }
                transferRetryCount = 0 // Reset for next attempt
                loadFallbackDataFromComplication()
            }
        } else {
            // Success - reset retry count
            transferRetryCount = 0
            Task {
                await WatchLogger.shared.log("✅ transferUserInfo completed successfully")
            }
        }
    }

    /// Called when the reachability status of the paired iPhone changes.
    /// Updates the local reachability status and may trigger a state update.
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            Task {
                await WatchLogger.shared.log("⌚️ Watch reachability changed: \(session.isReachable)")
            }

            if session.isReachable {
                if self.isColdStart, !self.forcedSinceActivation {
                    self.forceConditionalWatchStateUpdate()
                    self.forcedSinceActivation = true
                }

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
    /// have elapsed since the last update under the following conditions:
    ///  - If `lastWatchStateUpdate` is `nil` (meaning there has never been an update), or
    ///  - If more than 30 seconds have passed, or
    ///  - If we're in the cold start window
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
            forcedSinceActivation = true
            return
        }

        let now = Date()
        let secondsSinceUpdate = now.timeIntervalSince(lastUpdateTimestamp)
        Task {
            await WatchLogger.shared.log("Time since last update: \(secondsSinceUpdate) seconds")
        }

        // More aggressive update request - reduce threshold to 15s for better responsiveness
        // Also always request if we're in cold start window
        if secondsSinceUpdate > 15 || isColdStart {
            showSyncingAnimation = true
            requestWatchStateUpdate()
            forcedSinceActivation = true
            return
        }
    }

    /// Handles incoming messages that either contain an acknowledgement or fresh watchState data (<15 min).
    /// Updates UI and state as appropriate.
    /// - Parameter message: The message dictionary received from the phone.
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

    /// Accumulates new data, sets syncing flag, and debounces the final UI update.
    /// Used to batch process rapid incoming updates for smoother UI.
    /// - Parameter newData: The new state data to merge and eventually apply.
    private func scheduleUIUpdate(with newData: [String: Any]) {
        guard let incomingDate = newData[WatchMessageKeys.date] as? Date else {
            Task {
                await WatchLogger.shared.log("❌ Invalid date format in WatchState data")
            }
            return
        }

        if let lastTimestamp = lastWatchStateUpdate,
           incomingDate <= lastTimestamp
        {
            Task {
                await WatchLogger.shared.log("⏭️ Skipping UI update — outdated WatchState (\(incomingDate))")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("📱 Processing WatchState update:")
            await WatchLogger.shared.log("   📅 Incoming date: \(incomingDate)")
            await WatchLogger.shared.log("   🩸 Glucose: \(newData[WatchMessageKeys.currentGlucose] as? String ?? "--")")
            await WatchLogger.shared.log("   📈 Trend: \(newData[WatchMessageKeys.trend] as? String ?? "--")")
            await WatchLogger.shared.log("   📊 Delta: \(newData[WatchMessageKeys.delta] as? String ?? "--")")
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
        let coldStartWindow: TimeInterval = 60 // 1 min
        let sinceActivation = activationTimestamp.map { Date().timeIntervalSince1970 - $0 } ?? .greatestFiniteMagnitude
        let delay: TimeInterval = isColdStart ? 0.2 : 0.1 // Reduced delays for faster updates
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Applies all pending data to the watch state in one shot.
    /// Only called after debouncing; updates UI properties and triggers complication update.
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.forceComplicationUpdate()
        }

        Task {
            await WatchLogger.shared.log("✅ Watch UI update complete")
        }
    }

    /// Updates the main UI properties from the raw WatchState data dictionary.
    /// Also saves a complication snapshot.
    /// - Parameter message: The raw data dictionary received from the phone.
    private func processRawDataForWatchState(_ message: [String: Any]) {
        Task {
            await WatchLogger.shared.log("Processing raw WatchState data with keys: \(message.keys.joined(separator: ", "))")
        }

        if let date = message[WatchMessageKeys.date] as? Date {
            lastWatchStateUpdate = date
            forcedSinceActivation = false
            Task {
                await WatchLogger.shared.log("📅 Updated lastWatchStateUpdate: \(date)")
            }
        } else {
            Task {
                await WatchLogger.shared.log("❌ Missing or invalid date in WatchState data")
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
                      let colorString = data["color"] as? String
                else {
                    Task {
                        await WatchLogger.shared.log("❌ Invalid glucose data format: \(data)")
                    }
                    return nil
                }

                // Handle both Date and TimeInterval formats for better compatibility
                let date: Date
                if let dateValue = data["date"] as? Date {
                    date = dateValue
                } else if let timestamp = data["date"] as? TimeInterval {
                    date = Date(timeIntervalSince1970: timestamp)
                } else {
                    Task {
                        await WatchLogger.shared.log("❌ Invalid date format in glucose data: \(data["date"] ?? "nil")")
                    }
                    return nil
                }

                return (date: date, glucose: glucose, color: colorString.toColor())
            }
            .sorted { $0.date < $1.date }

            Task {
                await WatchLogger.shared.log("📊 Processed \(glucoseValues.count) glucose values for chart")
            }
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
                // limit minimum to 0.05 to avoid dealing with 0.025 increments
                self.bolusIncrement = max(decimalValue, 0.05)
            }
        }

        if let confirmBolusFaster = message[WatchMessageKeys.confirmBolusFaster] {
            if let booleanValue = confirmBolusFaster as? Bool {
                self.confirmBolusFaster = booleanValue
            }
        }

        saveComplicationSnapshot(from: message)
    }

    /// Saves a complication snapshot from the current or provided WatchState data.
    /// Triggers a timeline reload to update the complication.
    /// - Parameter message: The data dictionary to use for the snapshot.
    private func saveComplicationSnapshot(from message: [String: Any]) {
        guard let readingDateValue = message[WatchMessageKeys.date] as? Date else {
            Task {
                await WatchLogger.shared.log("❌ Invalid date format in complication snapshot data")
            }
            return
        }

        let dateValue = Date()

        Task {
            await WatchLogger.shared.log("💾 Saving complication snapshot:")
            await WatchLogger.shared.log("   📅 Reading date: \(readingDateValue)")
            await WatchLogger.shared.log("   📅 Snapshot date: \(dateValue)")
            await WatchLogger.shared.log("   🩸 Glucose: \(message[WatchMessageKeys.currentGlucose] as? String ?? "--")")
        }

        let glucoseValue = message[WatchMessageKeys.currentGlucose] as? String ?? currentGlucose
        let trendValue = message[WatchMessageKeys.trend] as? String ?? trend ?? ""
        let deltaValue = message[WatchMessageKeys.delta] as? String ?? delta ?? ""
        let glucoseColorValue = message[WatchMessageKeys.currentGlucoseColorString] as? String

        let snapshot = TrioComplicationSnapshot(
            glucose: glucoseValue,
            trend: trendValue,
            delta: deltaValue,
            readingDate: readingDateValue,
            date: dateValue,
            glucoseColor: glucoseColorValue
        )

        TrioComplicationDataStore.shared.save(snapshot)
        TrioComplicationDataStore.shared.coalescedReload()
        Task {
            await WatchLogger.shared
                .log(
                    "⌚️ Saved complication snapshot - glucose: \(snapshot.glucose), trend: \(snapshot.trend), delta: \(snapshot.delta)"
                )
        }
    }

    /// Manually triggers a complication update using the current state.
    /// Saves a new snapshot and reloads the complication timeline.
    func forceComplicationUpdate() {
        Task {
            await WatchLogger.shared.log("⌚️ Forcing complication update with current state:")
            await WatchLogger.shared.log("   🩸 Glucose: \(currentGlucose)")
            await WatchLogger.shared.log("   📈 Trend: \(trend ?? "--")")
            await WatchLogger.shared.log("   📊 Delta: \(delta ?? "--")")
        }

        // ✅ Skip placeholder data - more lenient validation for fallback scenarios
        guard !currentGlucose.isEmpty,
              !currentGlucose.contains("??"),
              !currentGlucose.contains("Error"),
              !currentGlucose.contains("error")
        else {
            Task {
                await WatchLogger.shared.log("⚠️ Skipping placeholder snapshot (invalid values)")
                await WatchLogger.shared.log("   🩸 Glucose: '\(currentGlucose)'")
                await WatchLogger.shared.log("   📊 Delta: '\(delta ?? "")'")
            }
            return
        }

        // ✅ Additional validation for numeric glucose values
        if let glucoseValue = Double(currentGlucose.replacingOccurrences(of: " mg/dL", with: "")) {
            guard glucoseValue > 0 && glucoseValue < 1000 else {
                Task {
                    await WatchLogger.shared.log("⚠️ Skipping invalid glucose value: \(glucoseValue)")
                }
                return
            }
        }

        let effectiveReadingDate = TrioComplicationDataStore.lastValidTimestamp ?? .distantPast
        let effectiveTimestamp = Date()

        let snapshot = TrioComplicationSnapshot(
            glucose: currentGlucose,
            trend: trend ?? "",
            delta: delta ?? "",
            readingDate: effectiveReadingDate,
            date: effectiveTimestamp
        )

        TrioComplicationDataStore.shared.save(snapshot)
        // Timeline reload is now handled automatically in TrioComplicationDataStore.save()
    }

    // MARK: - Background Refresh Scheduling and Handling

    #if os(watchOS)
        /// Schedules a background refresh task for the app to update complications.
        /// This should be called after each background refresh and after initial setup.
        /// Adaptive scheduling based on connectivity and data freshness
        func scheduleBackgroundRefresh() {
            // More aggressive scheduling when we have recent data
            let hasRecentData = lastWatchStateUpdate != nil &&
                Date().timeIntervalSince(lastWatchStateUpdate!) < 300 // 5 minutes

            let nextInterval: TimeInterval = if WatchState.shared.isReachable {
                hasRecentData ? 300 : 180 // 5 min if recent data, 3 min if not recent (more aggressive)
            } else {
                hasRecentData ? 900 : 600 // 15 min if recent data, 10 min if not recent (more aggressive)
            }

            let refreshDate = Date().addingTimeInterval(nextInterval)
            WKExtension.shared().scheduleBackgroundRefresh(withPreferredDate: refreshDate, userInfo: nil) { error in
                Task {
                    if let error = error {
                        await WatchLogger.shared.log("⚠️ Failed to schedule background refresh: \(error)")
                    } else {
                        await WatchLogger.shared
                            .log("⌚️ Scheduled background refresh at \(refreshDate) (interval: \(nextInterval)s)")
                    }
                }
            }
        }

        /// Handles background tasks, processes new data and reloads complication timeline.
        /// Should be called from ExtensionDelegate's handle(_:)
        func handleBackgroundTasks(_ tasks: Set<WKRefreshBackgroundTask>) {
            Task {
                await WatchLogger.shared.log("⌚️ Handling background tasks: \(tasks.count)")
            }

            for task in tasks {
                if let refreshTask = task as? WKApplicationRefreshBackgroundTask {
                    // Update background refresh statistics
                    backgroundRefreshCount += 1
                    lastBackgroundRefreshDate = Date()

                    Task {
                        await WatchLogger.shared
                            .log("⌚️ Background refresh triggered at \(Date()) (count: \(backgroundRefreshCount))")
                    }

                    // Try to get fresh data from phone first
                    if isReachable {
                        requestWatchStateUpdate()
                        // Wait a bit for response, then force update
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.forceComplicationUpdate()
                        }
                    } else {
                        // Use fallback immediately if not reachable
                        loadFallbackDataFromComplication()
                        forceComplicationUpdate()
                    }

                    refreshTask.setTaskCompletedWithSnapshot(false)
                    scheduleBackgroundRefresh()
                } else {
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
    #endif

    // MARK: - Fallback Data Loading

    /// Loads fallback data from the complication data store when WatchConnectivity fails.
    /// Only uses fallback if we don't have recent data from the phone.
    func loadFallbackDataFromComplication() {
        guard let snapshot = TrioComplicationDataStore.shared.latestSnapshot() else {
            Task {
                await WatchLogger.shared.log("🔄 No complication snapshot available for fallback")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        // Only use fallback if we don't have recent data (reduced threshold for better responsiveness)
        guard let lastUpdate = lastWatchStateUpdate,
              Date().timeIntervalSince(lastUpdate) > 15
        else {
            Task {
                await WatchLogger.shared.log("🔄 Recent data available, skipping fallback")
            }
            DispatchQueue.main.async {
                self.showSyncingAnimation = false
            }
            return
        }

        Task {
            await WatchLogger.shared.log("🔄 Loading fallback data from complication snapshot")
            await WatchLogger.shared.log("   🩸 Glucose: \(snapshot.glucose)")
            await WatchLogger.shared.log("   📈 Trend: \(snapshot.trend)")
            await WatchLogger.shared.log("   📊 Delta: \(snapshot.delta)")
        }

        // Update WatchState with complication data
        DispatchQueue.main.async {
            self.currentGlucose = snapshot.glucose
            self.trend = snapshot.trend
            self.delta = snapshot.delta
            self.lastWatchStateUpdate = snapshot.readingDate
            self.showSyncingAnimation = false

            // Cancel any pending timeout
            self.syncTimeoutWorkItem?.cancel()
        }
    }
}
