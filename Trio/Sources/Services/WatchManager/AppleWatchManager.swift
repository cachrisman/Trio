import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WatchConnectivity

/// Protocol defining the base functionality for Watch communication
protocol WatchManager {
    func setupWatchState() async -> WatchState
}

/// WCSessionDelegate implementation for BaseWatchManager
final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    private weak var watchManager: BaseWatchManager?

    init(watchManager: BaseWatchManager) {
        self.watchManager = watchManager
        super.init()
    }

    func session(_: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            await watchManager?.sessionActivationDidComplete(activationState: activationState, error: error)
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            await watchManager?.sessionDidReceiveMessage(message)
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            await watchManager?.sessionDidReceiveUserInfo(userInfo)
        }
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {
            Task { @MainActor in
                await watchManager?.sessionDidBecomeInactive()
            }
        }

        func sessionDidDeactivate(_: WCSession) {
            Task { @MainActor in
                await watchManager?.sessionDidDeactivate()
            }
        }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            await watchManager?.sessionReachabilityDidChange(isReachable: session.isReachable)
        }
    }
}

/// Main implementation of the Watch communication manager
/// Handles bidirectional communication between iPhone and Apple Watch
final actor BaseWatchManager: Injectable, WatchManager {
    private var session: WCSession?
    private var sessionDelegate: WatchSessionDelegate?

    @Injected() var broadcaster: Broadcaster!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var notificationsManager: UserNotificationsManager!

    private var units: GlucoseUnits = .mgdL
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor
    private var lowGlucose: Decimal = 70.0
    private var highGlucose: Decimal = 180.0
    private var currentGlucoseTarget: Decimal = 100.0
    private var activeBolusAmount: Double = 0.0

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseWatchManagerManager.queue", qos: .utility)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    typealias PumpEvent = PumpEventStored.EventType

    let backgroundContext = CoreDataStack.shared.newTaskContext()
    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        injectServices(resolver)
        setupWatchSession()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)

        // Initialize currentGlucoseTarget asynchronously
        Task { @MainActor in
            await self.initializeGlucoseTarget()
        }

        // Observer for OrefDetermination and adjustments
        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        // Observer for glucose and manual glucose
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { _ in
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable,
                      session.isWatchAppInstalled else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { _ in
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }
            .store(in: &subscriptions)

        registerHandlers()
    }

    private func registerHandlers() {
        coreDataPublisher?.filteredByEntityName("OrefDetermination").sink { _ in
            // Skip if no watch is paired or app not installed
            guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
            Task {
                let state = await self.setupWatchState()
                await self.sendDataToWatch(state)
            }
        }.store(in: &subscriptions)

        // Due to the Batch insert this only is used for observing Deletion of Glucose entries
        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { _ in
            // Skip if no watch is paired or app not installed
            guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
            Task {
                let state = await self.setupWatchState()
                await self.sendDataToWatch(state)
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("PumpEventStored").sink { _ in
            Task {
                await self.getActiveBolusAmount()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { _ in
            // Skip if no watch is paired or app not installed
            guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
            Task {
                let state = await self.setupWatchState()
                await self.sendDataToWatch(state)
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { _ in
            // Skip if no watch is paired or app not installed
            guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
            Task {
                let state = await self.setupWatchState()
                await self.sendDataToWatch(state)
            }
        }.store(in: &subscriptions)
    }

    /// Sets up the WatchConnectivity session if the device supports it
    private func setupWatchSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            self.sessionDelegate = WatchSessionDelegate(watchManager: self)
            session.delegate = sessionDelegate
            session.activate()
            self.session = session

            debug(.watchManager, "📱 Phone session setup - isPaired: \(session.isPaired)")
        } else {
            debug(.watchManager, "📱 WCSession is not supported on this device")
        }
    }

    /// Attempts to reestablish the Watch connection if it becomes unreachable
    private func retryConnection() {
        guard let session = session else { return }

        if !session.isReachable {
            debug(.watchManager, "📱 Attempting to reactivate session...")
            session.activate()
        }
    }

    /// Initializes the current glucose target asynchronously
    private func initializeGlucoseTarget() async {
        currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)
    }

    /// Prepares the current state data to be sent to the Watch
    /// - Returns: WatchState containing current glucose readings and trends and determination infos for displaying cob and iob in the view
    nonisolated func setupWatchState() async -> WatchState {
        await self.fetchInitialWatchState()
    }

    private func fetchInitialWatchState() async -> WatchState {
        // Skip if watch session is not activated
        guard let session = session, session.activationState == .activated else {
            debug(.watchManager, "⌚️❌ Skipping setupWatchState - Watch session not activated")
            return WatchState(date: .distantPast) // Placeholder date for debugging
        }

        do {
            // Get NSManagedObjectIDs
            let glucoseIds = try await fetchGlucose()
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let overridePresetIds = try await overrideStorage.fetchForOverridePresets()
            let tempTargetPresetIds = try await tempTargetStorage.fetchForTempTargetPresets()

            // Get NSManagedObjects
            let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: glucoseIds, context: backgroundContext)
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared
                .getNSManagedObject(with: determinationIds, context: backgroundContext)
            let overridePresetObjects: [OverrideStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: overridePresetIds, context: backgroundContext)
            let tempTargetPresetObjects: [TempTargetStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: tempTargetPresetIds, context: backgroundContext)

            // Take thread-safe snapshots to avoid capturing non-Sendable Core Data objects in @Sendable closure
            let glucoseSnapshot = glucoseObjects.map { $0 }
            let determinationSnapshot = determinationObjects.map { $0 }
            let overridePresetSnapshot = overridePresetObjects.map { $0 }
            // Instead of capturing tempTargetPresetObjects, map to a Sendable-safe array
            struct TempTargetInfo: Sendable {
                let name: String
                let enabled: Bool
            }
            let tempTargetSafe = tempTargetPresetObjects.map { TempTargetInfo(name: $0.name ?? "", enabled: $0.enabled) }

            return await backgroundContext.perform {
                // Use only thread-safe snapshots inside closure
                let glucoseObjects = glucoseSnapshot
                let determinationObjects = determinationSnapshot
                let overridePresetObjects = overridePresetSnapshot
                // tempTargetSafe is Sendable, so we use that instead of tempTargetPresetObjects
                var watchState = WatchState(date: .distantPast) // Will be updated with actual glucose date

                // Set lastLoopDate
                let lastLoopMinutes = Int((Date().timeIntervalSince(self.apsManager.lastLoopDate) - 30) / 60) + 1
                if lastLoopMinutes > 1440 {
                    watchState.lastLoopTime = "--"
                } else {
                    watchState.lastLoopTime = "\(lastLoopMinutes) min"
                }

                // Set IOB and COB from latest determination
                let iob = self.iobService.currentIOB ?? 0
                watchState.iob = Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob as NSNumber)

                if let latestDetermination = determinationObjects.first {
                    let cob = NSNumber(value: latestDetermination.cob)
                    watchState.cob = Formatter.integerFormatter.string(from: cob)
                }

                // Set override presets with their enabled status
                watchState.overridePresets = overridePresetObjects.map { override in
                    OverridePresetWatch(
                        name: override.name ?? "",
                        isEnabled: override.enabled
                    )
                }

                guard let latestGlucose = glucoseObjects.first else {
                    return watchState
                }

                // Set the WatchState date to the latest glucose reading date
                watchState.date = latestGlucose.date ?? .distantPast

                // Assign currentGlucose and its color
                /// Set current glucose with proper formatting
                if self.units == .mgdL {
                    watchState.currentGlucose = "\(latestGlucose.glucose)"
                } else {
                    let mgdlValue = Decimal(latestGlucose.glucose)
                    let latestGlucoseValue = mgdlValue.formattedAsMmolL
                    watchState.currentGlucose = "\(latestGlucoseValue)"
                }

                /// Calculate latest color
                let hardCodedLow = Decimal(55)
                let hardCodedHigh = Decimal(220)
                let isDynamicColorScheme = self.glucoseColorScheme == .dynamicColor

                let highGlucoseValue = isDynamicColorScheme ? hardCodedHigh : self.highGlucose
                let lowGlucoseValue = isDynamicColorScheme ? hardCodedLow : self.lowGlucose
                let highGlucoseColorValue = highGlucoseValue
                let lowGlucoseColorValue = lowGlucoseValue
                let targetGlucose = self.currentGlucoseTarget

                let currentGlucoseColor = Trio.getDynamicGlucoseColor(
                    glucoseValue: Decimal(latestGlucose.glucose),
                    highGlucoseColorValue: highGlucoseColorValue,
                    lowGlucoseColorValue: lowGlucoseColorValue,
                    targetGlucose: targetGlucose,
                    glucoseColorScheme: self.glucoseColorScheme
                )

                if Decimal(latestGlucose.glucose) <= self.lowGlucose || Decimal(latestGlucose.glucose) >= self.highGlucose {
                    watchState.currentGlucoseColorString = currentGlucoseColor.toHexString()
                } else {
                    watchState.currentGlucoseColorString = "#ffffff" // white when in range; colored when out of range
                }

                // Map glucose values
                watchState.glucoseValues = glucoseObjects.compactMap { glucose in
                    let glucoseValue = self.units == .mgdL
                        ? Double(glucose.glucose)
                        : Double(truncating: Decimal(glucose.glucose).asMmolL as NSNumber)

                    let glucoseColor = Trio.getDynamicGlucoseColor(
                        glucoseValue: Decimal(glucose.glucose),
                        highGlucoseColorValue: highGlucoseColorValue,
                        lowGlucoseColorValue: lowGlucoseColorValue,
                        targetGlucose: targetGlucose,
                        glucoseColorScheme: self.glucoseColorScheme
                    )

                    return WatchGlucoseObject(
                        date: glucose.date ?? Date(),
                        glucose: glucoseValue,
                        color: glucoseColor.toHexString()
                    )
                }
                .sorted { $0.date < $1.date }

                // Set axis domain: min and max Y-axis values
                // Apply unit parsing conditionally, if user uses mmol/L
                let maxGlucoseValue = Decimal(glucoseObjects.map { Int($0.glucose) }.max() ?? 200)
                var maxYValue = Decimal(200)

                if maxGlucoseValue > maxYValue, maxGlucoseValue <= 225 {
                    maxYValue = Decimal(250)
                } else if maxGlucoseValue > 225, maxGlucoseValue <= 275 {
                    maxYValue = Decimal(300)
                } else if maxGlucoseValue > 275, maxGlucoseValue <= 325 {
                    maxYValue = Decimal(350)
                } else if maxGlucoseValue > 325 {
                    maxYValue = Decimal(400)
                }

                if self.units == .mmolL {
                    maxYValue = Double(truncating: maxYValue as NSNumber).asMmolL
                }
                watchState.maxYAxisValue = maxYValue

                if self.units == .mmolL {
                    let minYValue = Double(truncating: watchState.minYAxisValue as NSNumber).asMmolL
                    watchState.minYAxisValue = minYValue
                }

                // Convert direction to trend string
                watchState.trend = latestGlucose.direction

                // Calculate delta if we have at least 2 readings
                if glucoseObjects.count >= 2 {
                    var deltaValue = Decimal(glucoseObjects[0].glucose - glucoseObjects[1].glucose)

                    if self.units == .mmolL {
                        deltaValue = Double(truncating: deltaValue as NSNumber).asMmolL
                    }

                    let formattedDelta = Formatter.glucoseFormatter(for: self.units)
                        .string(from: deltaValue as NSNumber) ?? "0"
                    watchState.delta = deltaValue < 0 ? "\(formattedDelta)" : "+\(formattedDelta)"
                }

                // Set temp target presets with their enabled status using the Sendable-safe array
                watchState.tempTargetPresets = tempTargetSafe.map { tempTarget in
                    TempTargetPresetWatch(
                        name: tempTarget.name,
                        isEnabled: tempTarget.enabled
                    )
                }

                // Set units
                watchState.units = self.units

                // Add limits and pump specific dosing increment settings values
                watchState.maxBolus = self.settingsManager.pumpSettings.maxBolus
                watchState.maxCarbs = self.settingsManager.settings.maxCarbs
                watchState.maxFat = self.settingsManager.settings.maxFat
                watchState.maxProtein = self.settingsManager.settings.maxProtein
                watchState.bolusIncrement = self.settingsManager.preferences.bolusIncrement
                watchState.confirmBolusFaster = self.settingsManager.settings.confirmBolusFaster

                debug(
                    .watchManager,
                    "📱 Setup WatchState - currentGlucose: \(watchState.currentGlucose ?? "nil"), trend: \(watchState.trend ?? "nil"), delta: \(watchState.delta ?? "nil"), values: \(watchState.glucoseValues.count)"
                )

                return watchState
            }
        } catch {
            debug(
                .watchManager,
                "\(DebuggingIdentifiers.failed) Error setting up watch state: \(error)"
            )
            // Return empty state in case of error
            return WatchState(date: .distantPast) // Placeholder date for debugging
        }
    }

    /// Fetches recent glucose readings from CoreData
    /// - Returns: Array of NSManagedObjectIDs for glucose readings
    private func fetchGlucose() async throws -> [NSManagedObjectID] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: backgroundContext,
            predicate: NSPredicate.glucose,
            key: "date",
            ascending: false,
            fetchLimit: 288
        )

        return try await backgroundContext.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID)
        }
    }

    /// Fetches last pump event that is a non-external bolus from CoreData
    /// - Returns: NSManagedObjectIDs for last bolus
    func fetchLastBolus() async throws -> NSManagedObjectID? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: backgroundContext,
            predicate: NSPredicate.lastPumpBolus,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1
        )

        return try await backgroundContext.perform {
            guard let fetchedResults = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID).first
        }
    }

    /// Gets the active bolus amount by fetching last (active) bolus.
    func getActiveBolusAmount() async {
        do {
            if let lastBolusObjectId = try await fetchLastBolus() {
                let lastBolusObject: [PumpEventStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: [lastBolusObjectId], context: viewContext)

                activeBolusAmount = lastBolusObject.first?.bolus?.amount?.doubleValue ?? 0.0
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Error getting active bolus amount: \(error)"
            )
        }
    }

    // MARK: - Send to Watch

    func watchStateToDictionary(from state: WatchState) -> [String: Any] {
        [
            WatchMessageKeys.date: state.date, // Send as Date for Watch compatibility
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? "",
            WatchMessageKeys.glucoseValues: state.glucoseValues.map { value in
                [
                    "glucose": value.glucose,
                    "date": value.date, // Use Date consistently
                    "color": value.color
                ]
            },
            WatchMessageKeys.minYAxisValue: state.minYAxisValue,
            WatchMessageKeys.maxYAxisValue: state.maxYAxisValue,
            WatchMessageKeys.overridePresets: state.overridePresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.tempTargetPresets: state.tempTargetPresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.maxBolus: state.maxBolus,
            WatchMessageKeys.maxCarbs: state.maxCarbs,
            WatchMessageKeys.maxFat: state.maxFat,
            WatchMessageKeys.maxProtein: state.maxProtein,
            WatchMessageKeys.bolusIncrement: state.bolusIncrement,
            WatchMessageKeys.confirmBolusFaster: state.confirmBolusFaster,
            WatchMessageKeys.units: state.units.rawValue
        ]
    }

    private func mirrorComplicationSnapshotForDebug(from state: WatchState) {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = TrioComplicationSnapshot(
                glucose: state.currentGlucose ?? "--",
                trend: state.trend ?? "",
                delta: state.delta ?? "",
                readingDate: state.date,
                date: Date(),
                glucoseColor: state.currentGlucoseColorString
            )
            TrioComplicationDataStore.shared.save(snapshot)
        }
    }

    /// Sends the state of type WatchState to the connected Watch
    /// - Parameter state: Current WatchState containing glucose data to be sent
    func sendDataToWatch(_ state: WatchState) async {
        guard let session = session else { return }

        guard session.isPaired else {
            debug(.watchManager, "⌚️❌ No Watch is paired")
            return
        }

        guard session.isWatchAppInstalled else {
            debug(.watchManager, "⌚️❌ Trio Watch app is not installed")
            return
        }

        guard session.activationState == .activated else {
            let activationStateString = "\(session.activationState)"
            debug(.watchManager, "⌚️ Watch session activationState = \(activationStateString). Reactivating...")
            session.activate()
            return
        }

        // Skip if we already sent this state or older
        let lastSent = WatchStateSnapshot.loadLatestDateFromDisk()
        guard lastSent < state.date else {
            debug(.watchManager, "🕐 Skipping push — newer or equal state already sent")
            return
        }

        let message: [String: Any] = watchStateToDictionary(from: state)

        // Debug logging for data being sent
        debug(.watchManager, "📤 Sending WatchState to Watch:")
        debug(.watchManager, "   📅 Date: \(state.date)")
        debug(.watchManager, "   🩸 Glucose: \(state.currentGlucose ?? "--")")
        debug(.watchManager, "   📈 Trend: \(state.trend ?? "--")")
        debug(.watchManager, "   📊 Delta: \(state.delta ?? "--")")
        debug(.watchManager, "   🔋 IOB: \(state.iob ?? "--")")
        debug(.watchManager, "   🍞 COB: \(state.cob ?? "--")")
        debug(.watchManager, "   📱 Session reachable: \(session.isReachable)")

        // if session is reachable, it means watch App is in the foreground -> send watchState as message
        // if session is not reachable, it means it's in background -> send watchState as userInfo
        if session.isReachable {
            debug(.watchManager, "📤 Sending via sendMessage (foreground)")
            session.sendMessage([WatchMessageKeys.watchState: message], replyHandler: nil) { error in
                debug(.watchManager, "❌ Error sending watch state: \(error)")
            }
            WatchStateSnapshot.saveLatestDateToDisk(state.date)
        } else {
            debug(.watchManager, "📤 Sending via transferUserInfo (background)")
            WatchStateSnapshot.saveLatestDateToDisk(state.date)
            session.transferUserInfo([WatchMessageKeys.watchState: message])
            debug(.watchManager, "📤 Transferred new WatchState snapshot via userInfo")
        }

        mirrorComplicationSnapshotForDebug(from: state)
    }

    func sendAcknowledgment(toWatch success: Bool, message: String = "", ackCode: AcknowledgmentCode) {
        guard let session = session, session.isReachable else {
            debug(.watchManager, "⌚️ Watch not reachable for acknowledgment")
            return
        }

        let ackMessage: [String: Any] = [
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: ackCode.rawValue
        ]

        session.sendMessage(ackMessage, replyHandler: nil) { error in
            debug(.watchManager, "❌ Error sending acknowledgment: \(error)")
        }
    }

    // MARK: - WCSessionDelegate Methods (called via WatchSessionDelegate)

    func sessionActivationDidComplete(activationState: WCSessionActivationState, error: Error?) async {
        if let error = error {
            debug(.watchManager, "📱 Phone session activation failed: \(error)")
            return
        }

        debug(.watchManager, "📱 Phone session activated with state: \(activationState.rawValue)")
        guard let session = session else { return }
        debug(.watchManager, "📱 Phone isReachable after activation: \(session.isReachable)")

        // Try to send initial data after activation
        let state = await self.setupWatchState()
        await self.sendDataToWatch(state)
    }

    func sessionDidReceiveMessage(_ message: [String: Any]) async {
        if let logs = message["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }

        if let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
           requestWatchUpdate == WatchMessageKeys.watchState
        {
            debug(.watchManager, "📱 Watch requested watch state data update.")
            // Skip if no watch is paired or app not installed
            guard let session = session, session.isPaired, session.isReachable,
                  session.isWatchAppInstalled else { return }
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
            return
        }

        if let snoozeMinutes = message[WatchMessageKeys.snoozeDuration] as? Int {
            debug(.watchManager, "📱 Received snooze request from watch: \(snoozeMinutes) minutes")
            await MainActor.run {
                Task { @MainActor in
                    await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
                }
            }
            return
        } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                  message[WatchMessageKeys.carbs] == nil,
                  message[WatchMessageKeys.date] == nil
        {
            debug(.watchManager, "📱 Received bolus request from watch: \(bolusAmount)U")
            await self.handleBolusRequest(Decimal(bolusAmount))
        } else if let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                  let timestamp = message[WatchMessageKeys.date] as? TimeInterval,
                  message[WatchMessageKeys.bolus] == nil
        {
            let date = Date(timeIntervalSince1970: timestamp)
            debug(.watchManager, "📱 Received carbs request from watch: \(carbsAmount)g at \(date)")
            await self.handleCarbsRequest(carbsAmount, date)
        } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                  let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                  let timestamp = message[WatchMessageKeys.date] as? TimeInterval
        {
            let date = Date(timeIntervalSince1970: timestamp)
            debug(
                .watchManager,
                "📱 Received meal bolus combo request from watch: \(bolusAmount)U, \(carbsAmount)g at \(date)"
            )
            await self.handleCombinedRequest(bolusAmount: Decimal(bolusAmount), carbsAmount: Decimal(carbsAmount), date: date)
        } else if message[WatchMessageKeys.cancelOverride] as? Bool == true {
            debug(.watchManager, "📱 Received cancel override request from watch")
            await self.handleCancelOverride()
        } else if let presetName = message[WatchMessageKeys.activateOverride] as? String {
            debug(.watchManager, "📱 Received activate override request from watch for preset: \(presetName)")
            await self.handleActivateOverride(presetName)
        } else if let presetName = message[WatchMessageKeys.activateTempTarget] as? String {
            debug(.watchManager, "📱 Received activate temp target request from watch for preset: \(presetName)")
            await self.handleActivateTempTarget(presetName)
        } else if message[WatchMessageKeys.cancelTempTarget] as? Bool == true {
            debug(.watchManager, "📱 Received cancel temp target request from watch")
            await self.handleCancelTempTarget()
        } else {
            debug(.watchManager, "📱 Invalid or incomplete data received from watch. Received:  \(message)")
            // Acknowledge failure
            await self.sendAcknowledgment(
                toWatch: false,
                message: "Error! Invalid or incomplete data received from watch. Received:  \(message)",
                ackCode: .genericFailure
            )
        }

        if message[WatchMessageKeys.requestBolusRecommendation] as? Bool == true {
            let carbs = message[WatchMessageKeys.carbs] as? Int ?? 0

            var minPredBG: Decimal = 54

            do {
                // Fetch determination data
                let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                    predicate: NSPredicate.predicateFor30MinAgoForDetermination
                )
                let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                    with: determinationIds,
                    context: backgroundContext
                )

                minPredBG = determinationObjects.first?.minPredBGFromReason ?? 54

            } catch let error as CoreDataError {
                debug(.default, "Core Data error: \(error)")
            } catch {
                debug(.default, "Unexpected error: \(error)")
            }

            // Get recommendation from BolusCalculationManager
            let result = await bolusCalculationManager.handleBolusCalculation(
                carbs: Decimal(carbs),
                useFattyMealCorrection: false,
                useSuperBolus: false,
                lastLoopDate: apsManager.lastLoopDate,
                minPredBG: minPredBG,
                simulatedCOB: nil,
                isBackdated: false // we cannot backdate carbs via watch
            )

            // Send recommendation back to watch
            let recommendationMessage: [String: Any] = [
                WatchMessageKeys.recommendedBolus: NSDecimalNumber(decimal: result.insulinCalculated)
            ]

            if let session = session, session.isReachable {
                debug(.watchManager, "📱 Sending recommendedBolus: \(result.insulinCalculated)")
                session.sendMessage(recommendationMessage, replyHandler: nil)
            }
        }
    }

    func sessionDidReceiveUserInfo(_ userInfo: [String: Any]) {
        if let logs = userInfo["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }
    }

    #if os(iOS)
        func sessionDidBecomeInactive() {
            // No action needed
        }

        func sessionDidDeactivate() {
            guard let session = session else { return }
            session.activate()
        }
    #endif

    func sessionReachabilityDidChange(isReachable: Bool) async {
        debug(.watchManager, "📱 Phone reachability changed: \(isReachable)")

        if isReachable {
            // Try to send data when connection is established
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
        } else {
            // Try to reconnect after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task {
                    await self.retryConnection()
                }
            }
        }
    }

    /// Processes bolus requests received from the Watch
    /// - Parameter amount: The requested bolus amount in units
    private func handleBolusRequest(_ amount: Decimal) {
        Task {
            await apsManager.enactBolus(amount: Double(amount), isSMB: false) { success, message in
                // Acknowledge success or error of bolus
                self.sendAcknowledgment(
                    toWatch: success,
                    message: message,
                    ackCode: success == true ? .genericSuccess : .genericFailure
                )
            }
            debug(.watchManager, "📱 Enacted bolus via APS Manager: \(amount)U")
        }
    }

    /// Handles carbs entry requests received from the Watch
    /// - Parameters:
    ///   - amount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCarbsRequest(_ amount: Int, _ date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            await context.perform {
                let carbEntry = CarbEntryStored(context: context)
                carbEntry.id = UUID()
                carbEntry.carbs = Double(truncating: amount as NSNumber)
                carbEntry.date = date
                carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                carbEntry.isUploadedToNS = false

                do {
                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.watchManager, "📱 Saved carbs from watch: \(amount)g at \(date)")

                    // Acknowledge success
                    self.sendAcknowledgment(
                        toWatch: true,
                        message: String(
                            localized: "Carbs logged successfully.",
                            comment: "Success message sent to watch when carbs are logged successfully"
                        ),
                        ackCode: .carbsLogged
                    )
                } catch {
                    debug(.watchManager, "❌ Error saving carbs: \(error)")

                    // Acknowledge failure
                    self.sendAcknowledgment(toWatch: false, message: "Error logging carbs", ackCode: .genericFailure)
                }
            }
        }
    }

    /// Handles combined bolus and carbs entry requests received from the Watch.
    /// - Parameters:
    ///   - bolusAmount: The bolus amount in units
    ///   - carbsAmount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCombinedRequest(bolusAmount: Decimal, carbsAmount: Decimal, date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            do {
                // Notify Watch: "Saving carbs..."
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Saving Carbs...",
                        comment: "Successful message sent to watch when saving carbs"
                    ),
                    ackCode: .savingCarbs
                )

                // Save carbs entry in Core Data
                try await context.perform {
                    let carbEntry = CarbEntryStored(context: context)
                    carbEntry.id = UUID()
                    carbEntry.carbs = NSDecimalNumber(decimal: carbsAmount).doubleValue
                    carbEntry.date = date
                    carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                    carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                    carbEntry.isUploadedToNS = false

                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.watchManager, "📱 Saved carbs from watch: \(carbsAmount) g at \(date)")
                }

                // Notify Watch: "Enacting bolus..."
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Enacting bolus...",
                        comment: "Successful message sent to watch when enacting bolus"
                    ),
                    ackCode: .enactingBolus
                )

                // Enact bolus via APS Manager
                let bolusDouble = NSDecimalNumber(decimal: bolusAmount).doubleValue
                await apsManager.enactBolus(amount: bolusDouble, isSMB: false) { success, message in
                    // Acknowledge success or error of bolus
                    self.sendAcknowledgment(
                        toWatch: success,
                        message: message,
                        ackCode: success == true ? .genericSuccess : .genericFailure
                    )
                }
                debug(.watchManager, "📱 Enacted bolus from watch via APS Manager: \(bolusDouble) U")
                // Notify Watch: "Carbs and bolus logged successfully"
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs and Bolus logged successfully.",
                        comment: "Successful message sent to watch when logging carbs and bolus"
                    ),
                    ackCode: .comboComplete
                )

            } catch {
                debug(.watchManager, "❌ Error processing combined request: \(error)")
                sendAcknowledgment(toWatch: false, message: "Failed to log carbs and bolus", ackCode: .genericFailure)
            }
        }
    }

    private func handleCancelOverride() {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            if let overrideId = try await overrideStorage.fetchLatestActiveOverride() {
                let override = await context.perform {
                    context.object(with: overrideId) as? OverrideStored
                }

                await context.perform {
                    if let activeOverride = override {
                        activeOverride.enabled = false

                        do {
                            guard context.hasChanges else {
                                // Acknowledge failure
                                self.sendAcknowledgment(
                                    toWatch: false,
                                    message: "Error! Something went wrong when processing your request.",
                                    ackCode: .genericFailure
                                )
                                return
                            }
                            try context.save()
                            debug(.watchManager, "📱 Successfully stopped override")

                            // Send notification to update Adjustments UI
                            Foundation.NotificationCenter.default.post(
                                name: .didUpdateOverrideConfiguration,
                                object: nil
                            )

                            // Acknowledge cancellation success
                            self.sendAcknowledgment(
                                toWatch: true,
                                message: String(
                                    localized: "Stopped Override successfully.",
                                    comment: "Stopped Override successfully"
                                ),
                                ackCode: .overrideStopped
                            )
                        } catch {
                            debug(.watchManager, "❌ Error cancelling override: \(error)")
                            // Acknowledge cancellation error
                            self.sendAcknowledgment(toWatch: false, message: "Error stopping Override.", ackCode: .genericFailure)
                        }
                    }
                }
            } else {
                debug(.watchManager, "❌ No active override found.")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "No active override found.",
                    ackCode: .genericFailure
                )
                return
            }
        }
    }

    private func handleActivateOverride(_ presetName: String) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            debug(.watchManager, "📱 Fetching all override presets...")

            // Fetch all presets to find the one to activate
            let presetIds = try await overrideStorage.fetchForOverridePresets()
            let presets: [OverrideStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: presetIds, context: context)

            debug(.watchManager, "📱 Checking for active override...")

            do {
                // Check for active override
                if let activeOverrideId = try await overrideStorage.fetchLatestActiveOverride() {
                    let activeOverride = await context.perform {
                        context.object(with: activeOverrideId) as? OverrideStored
                    }

                    // Deactivate, if necessary
                    if let override = activeOverride {
                        await context.perform {
                            override.enabled = false
                        }
                    }
                } else {
                    debug(.watchManager, "📱 Currently no override is active... proceeding to activate override: \(presetName)")
                }
            } catch {
                debug(.watchManager, "❌ Error while checking for active override: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Failed to load active override.",
                    ackCode: .genericFailure
                )
                return
            }

            // Activate the selected preset
            await context.perform {
                guard let presetToActivate = presets
                    .first(where: { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == presetName })
                else {
                    debug(.watchManager, "❌ No matching preset found for name: \"\(presetName)\" in \(presets.map(\.name))")
                    self.sendAcknowledgment(
                        toWatch: false,
                        message: String(
                            localized: "Preset \"\(presetName)\" not found.",
                            comment: "Preset not found"
                        ),
                        ackCode: .genericFailure
                    )
                    return
                }

                presetToActivate.enabled = true
                presetToActivate.date = Date()

                do {
                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: String(
                                localized: "Error! Something went wrong when processing your request.",
                                comment: "Error message when activating override"
                            ),
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.watchManager, "📱 Successfully activated override: \(presetName)")

                    // Send notification to update Adjustments UI
                    Foundation.NotificationCenter.default.post(
                        name: .didUpdateOverrideConfiguration,
                        object: nil
                    )

                    // Acknowledge activation success
                    self.sendAcknowledgment(
                        toWatch: true,
                        message: String(
                            localized: "Started Override \"\(presetName)\" successfully.",
                            comment: "Start override with override name"
                        ),
                        ackCode: .overrideStarted
                    )
                } catch {
                    debug(.watchManager, "❌ Error activating override: \(error)")
                    // Acknowledge activation error
                    self.sendAcknowledgment(
                        toWatch: false,
                        message: "Error activating Override \"\(presetName)\".",
                        ackCode: .genericFailure
                    )
                }
            }
        }
    }

    private func handleActivateTempTarget(_ presetName: String) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            do {
                // Fetch preset IDs and active temp target IDs asynchronously outside of the Core Data context
                let presetIds = try await tempTargetStorage.fetchForTempTargetPresets()
                let activeTempTargetId = try await tempTargetStorage
                    .loadLatestTempTargetConfigurations(fetchLimit: 1)
                    .first

                // Fetch managed objects for presets outside the context
                let presets: [TempTargetStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: presetIds, context: context)

                // Perform Core Data work synchronously inside the context
                try await context.performAndWait {
                    do {
                        // Deactivate the currently active temp target if one exists
                        if let activeTempTargetId = activeTempTargetId,
                           let activeTempTarget = context.object(with: activeTempTargetId) as? TempTargetStored
                        {
                            activeTempTarget.enabled = false
                        }

                        // Find the preset to activate
                        guard let presetToActivate = presets.first(where: { $0.name == presetName }) else {
                            debug(.watchManager, "❌ No matching preset found for \(presetName)")
                            self.sendAcknowledgment(
                                toWatch: false,
                                message: "Preset \"\(presetName)\" not found.",
                                ackCode: .genericFailure
                            )
                            return
                        }

                        // Activate the preset
                        presetToActivate.enabled = true
                        presetToActivate.date = Date()

                        guard context.hasChanges else {
                            self.sendAcknowledgment(
                                toWatch: false,
                                message: "Error! Something went wrong.",
                                ackCode: .genericFailure
                            )
                            return
                        }

                        try context.save()
                        debug(.watchManager, "📱 Activated temp target: \(presetName)")

                        // Persist the change to storage
                        self.tempTargetStorage.saveTempTargetsToStorage([
                            TempTarget(
                                name: presetToActivate.name,
                                createdAt: Date(),
                                targetTop: presetToActivate.target?.decimalValue,
                                targetBottom: presetToActivate.target?.decimalValue,
                                duration: presetToActivate.duration?.decimalValue ?? 0,
                                enteredBy: TempTarget.local,
                                reason: TempTarget.custom,
                                isPreset: true,
                                enabled: true,
                                halfBasalTarget: presetToActivate.halfBasalTarget?.decimalValue
                                    ?? self.settingsManager.preferences.halfBasalExerciseTarget
                            )
                        ])

                        // Post update notification
                        Foundation.NotificationCenter.default.post(
                            name: .didUpdateTempTargetConfiguration,
                            object: nil
                        )

                        // Acknowledge success
                        self.sendAcknowledgment(
                            toWatch: true,
                            message: "Started Temp Target \"\(presetName)\" successfully.",
                            ackCode: .tempTargetStarted
                        )
                    } catch {
                        debug(.watchManager, "❌ Error activating temp target: \(error)")
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error activating Temp Target.",
                            ackCode: .genericFailure
                        )
                    }
                }
            } catch {
                debug(.watchManager, "❌ Async fetch failure: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Failed to load temp target presets or active target.",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleCancelTempTarget() {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            if let tempTargetId = try await tempTargetStorage.loadLatestTempTargetConfigurations(fetchLimit: 1).first {
                let tempTarget = await context.perform {
                    context.object(with: tempTargetId) as? TempTargetStored
                }

                await context.perform {
                    if let activeTempTarget = tempTarget {
                        activeTempTarget.enabled = false
                        do {
                            guard context.hasChanges else {
                                self.sendAcknowledgment(
                                    toWatch: false,
                                    message: "Error! Something went wrong when processing your request.",
                                    ackCode: .genericFailure
                                )
                                return
                            }
                            try context.save()
                            debug(.watchManager, "📱 Successfully cancelled temp target")
                            self.tempTargetStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date())])
                            Foundation.NotificationCenter.default.post(
                                name: .didUpdateTempTargetConfiguration,
                                object: nil
                            )
                            self.sendAcknowledgment(
                                toWatch: true,
                                message: String(
                                    localized: "Stopped Temp Target successfully.",
                                    comment: "Stopped Temp Target successfully."
                                ),
                                ackCode: .tempTargetStopped
                            )
                        } catch {
                            debug(.watchManager, "❌ Error stopping temp target: \(error)")
                            self.sendAcknowledgment(
                                toWatch: false,
                                message: "Error stopping Temp Target.",
                                ackCode: .genericFailure
                            )
                        }
                    }
                }
            }
        }
    }
}

// TODO: - is there a better approach than setting up the watch state every time a setting has changed?
extension BaseWatchManager: SettingsObserver, PumpSettingsObserver {
    // to update maxBolus
    nonisolated func pumpSettingsDidChange(_: PumpSettings) {
        Task {
            // Skip if no watch is paired or app not installed
            guard let session = await self.session, session.isPaired, session.isReachable,
                  session.isWatchAppInstalled else { return }
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
        }
    }

    // to update the rest
    nonisolated func settingsDidChange(_: TrioSettings) {
        Task {
            await self.updateSettingsFromManager()
        }
    }

    private func updateSettingsFromManager() async {
        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        // Skip if no watch is paired or app not installed
        guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }

        let state = await setupWatchState()
        await sendDataToWatch(state)
    }
}

extension BaseWatchManager {
    // MARK: - Debug Helpers for Watch Complication Snapshot

    /// Reads the snapshot.json from the shared App Group and logs its contents for debugging.
    func fetchComplicationSnapshot() {
        guard let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String else {
            debug(.watchManager, "❌ AppGroupID not found in Info.plist")
            return
        }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            debug(.watchManager, "❌ Could not resolve App Group container for \(appGroupID)")
            return
        }
        let fileURL = containerURL.appendingPathComponent("snapshot.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            debug(.watchManager, "⚠️ snapshot.json not found at \(fileURL.path)")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(TrioComplicationSnapshot.self, from: data)
            debug(
                .watchManager,
                "📄 Loaded complication snapshot → glucose: \(snapshot.glucose), trend: \(snapshot.trend), delta: \(snapshot.delta), time: \(snapshot.date)"
            )
        } catch {
            debug(.watchManager, "❌ Failed to decode snapshot.json: \(error)")
        }
    }

    /// Copies snapshot.json from the App Group to the Documents directory for inspection in the Files app.
    func syncComplicationSnapshotToDocuments() {
        guard let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else {
            debug(.watchManager, "❌ Could not resolve App Group or Documents directory.")
            return
        }

        let source = containerURL.appendingPathComponent("snapshot.json")
        let dest = documentsURL.appendingPathComponent("snapshot.json")

        guard FileManager.default.fileExists(atPath: source.path) else {
            debug(.watchManager, "⚠️ snapshot.json not found at \(source.path)")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            debug(.watchManager, "✅ snapshot.json copied to Documents: \(dest.path)")
        } catch {
            debug(.watchManager, "❌ Failed to copy snapshot.json: \(error)")
        }
    }

    /// Retrieves the current glucose target based on the time of day.
    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }
}

extension BaseWatchManager {
    enum AcknowledgmentCode: String, Codable {
        case savingCarbs = "saving_carbs"
        case enactingBolus = "enacting_bolus"
        case comboComplete = "combo_complete"
        case carbsLogged = "carbs_logged"
        case overrideStarted = "override_started"
        case overrideStopped = "override_stopped"
        case tempTargetStarted = "temp_target_started"
        case tempTargetStopped = "temp_target_stopped"
        case genericSuccess = "success"
        case genericFailure = "failure"
    }
}
