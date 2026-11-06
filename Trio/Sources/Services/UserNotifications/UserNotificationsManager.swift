import Combine
import CoreData
import Foundation
import LoopKit
import SwiftUI
import Swinject
import UserNotifications

protocol UserNotificationsManager {
    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void)
    func requestNotificationPermissions(completion: @escaping (Bool) -> Void)
    @MainActor func applySnooze(for duration: TimeInterval) async
    /// Shared by the iPhone notification action and the watch-forwarded request.
    func logCarbsRequired(grams: Decimal?, alertID: String?) async -> CarbsRequiredLogOutcome
}

// MARK: - SnoozeObserver Protocol

protocol SnoozeObserver {
    @MainActor func snoozeDidChange(_ untilDate: Date)
}

final class BaseUserNotificationsManager: NSObject, UserNotificationsManager, Injectable {
    enum Identifier: String {
        case carbsRequiredNotification = "Trio.carbsRequiredNotification"
    }

    @Injected() var alertPermissionsChecker: AlertPermissionsChecker!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var trioAlertManager: TrioAlertManager!

    @Persisted(key: "UserNotificationsManager.snoozeUntilDate") private var snoozeUntilDate: Date = .distantPast

    private let notificationCenter = UNUserNotificationCenter.current()

    // The amount comes from the notification's userInfo, never the latest determination: carbsReq
    // can change between delivery and tap, and the user logs the number they were shown.
    // Created eagerly in `init` (not lazily) so it can't race; the duplicate guard it uses is
    // process-wide (see `UserDefaultsLoggedCarbsAlertStore`).
    private var carbsRequiredLogHandler: CarbsRequiredLogHandler!

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseUserNotificationsManager.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        super.init()
        notificationCenter.delegate = self
        injectServices(resolver)
        carbsRequiredLogHandler = CarbsRequiredLogHandler(
            store: UserDefaultsLoggedCarbsAlertStore(),
            maxCarbs: { [weak self] in self?.settingsManager.settings.maxCarbs ?? 0 },
            storeCarbs: { [weak self] grams in
                guard let self else { throw CancellationError() }
                // Same path as Treatments `saveMeal()` / Quick-Pick carbs: `CarbsStorage.storeCarbs`,
                // then a determine-basal sync. No bolus.
                let entry = self.carbsStorage.makeCarbEntry(carbs: grams, date: Date())
                try await self.carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
                // `storeCarbs` swallows Core Data save errors, so read the row back to confirm it exists.
                // Only a successful fetch that finds nothing proves the save failed. If the id can't be
                // parsed or the fetch itself throws, the save may have succeeded, and throwing would let
                // a retry store the carbs twice (more insulin), so treat that case as saved.
                if let handle = UUID(uuidString: entry.id ?? "") {
                    do {
                        if try await self.carbsStorage.fetchMealRoot(handle: handle) == nil {
                            throw CarbsRequiredLogError.carbEntryNotSaved
                        }
                    } catch let error as CarbsRequiredLogError {
                        throw error
                    } catch {
                        warning(.treatments, "Log Carbs could not confirm the saved carb entry", error: error)
                    }
                } else {
                    warning(.treatments, "Log Carbs could not confirm the saved carb entry")
                }
                do {
                    try await self.apsManager.determineBasalSync()
                } catch {
                    warning(.treatments, "Log Carbs determine basal sync failed", error: error)
                }
            }
        )
        broadcaster.register(SettingsObserver.self, observer: self)

        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        Task { await updateGlucoseBadge() }
        configureNotificationCategories()
        clearLegacyCarbsRequiredNotification()
        clearLegacyLoopNotifications()
        subscribeGlucoseUpdates()
    }

    private func configureNotificationCategories() {
        notificationCenter.getNotificationCategories { [weak self] existingCategories in
            guard let self else { return }

            let glucoseCategory = NotificationCategoryFactory.createGlucoseCategory()

            var categories = existingCategories
            categories.update(with: glucoseCategory)
            categories.update(with: NotificationCategoryFactory.createCarbsRequiredCategory())
            // UNUserNotificationCenter methods should be called on main thread
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notificationCenter.setNotificationCategories(categories)
            }
        }
    }

    /// Subscribes to the two sources that signal a glucose change so the app
    /// icon badge stays current:
    /// - `coreDataPublisher` filtered to `GlucoseStored` — catches deletions
    ///   (batch inserts don't fire normal Core Data save notifications, so
    ///   inserts come through `updatePublisher` below).
    /// - `glucoseStorage.updatePublisher` — fires on every new reading.
    private func subscribeGlucoseUpdates() {
        coreDataPublisher?.filteredByEntityName("GlucoseStored")
            .sink { [weak self] _ in Task { await self?.updateGlucoseBadge() } }
            .store(in: &subscriptions)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in Task { await self?.updateGlucoseBadge() } }
            .store(in: &subscriptions)
    }

    private func addAppBadge(glucose: Int?) {
        guard let glucose = glucose, settingsManager.settings.glucoseBadge else {
            DispatchQueue.main.async {
                self.notificationCenter.setBadgeCount(0) { error in
                    guard let error else {
                        return
                    }
                    warning(.alerts, "Setting app badge failed", error: error)
                }
            }
            return
        }

        let badge: Int
        if settingsManager.settings.units == .mmolL {
            badge = Int(round(Double((glucose * 10).asMmolL)))
        } else {
            badge = glucose
        }

        DispatchQueue.main.async {
            self.notificationCenter.setBadgeCount(badge) { error in
                guard let error else {
                    return
                }
                warning(.alerts, "Setting app badge failed", error: error)
            }
        }
    }

    /// Removes any `Trio.carbsRequiredNotification` UN still sitting in the
    /// system from a pre-pipeline install. Safe no-op when none exist.
    private func clearLegacyCarbsRequiredNotification() {
        let id = Identifier.carbsRequiredNotification.rawValue
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Purges the two "Last loop was X min ago" UNs the legacy
    /// `scheduleMissingLoopNotifiactions` path scheduled. Their identifiers
    /// aren't known to `NotLoopingMonitor`, so without this cleanup they'd
    /// fire once each after upgrade — https://github.com/nightscout/Trio/issues/1296
    private func clearLegacyLoopNotifications() {
        let ids = ["Trio.noLoopFirstNotification", "Trio.noLoopSecondNotification"]
        notificationCenter.removePendingNotificationRequests(withIdentifiers: ids)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func fetchGlucoseIDs() async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchGlucoseIDs"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateFor20MinAgo,
            key: "date",
            ascending: false,
            fetchLimit: 3
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID)
        }
    }

    /// Refreshes the Trio app icon badge from the latest stored glucose
    /// reading. Glucose alarm emission has moved to `GlucoseAlertCoordinator`
    /// (urgent-low / low / forecasted-low / high are issued via
    /// `TrioAlertManager` based on the user-configured `[GlucoseAlert]` list).
    @MainActor private func updateGlucoseBadge() async {
        do {
            addAppBadge(glucose: nil)
            let glucoseIDs = try await fetchGlucoseIDs()
            let latest = try glucoseIDs.compactMap { id in
                try viewContext.existingObject(with: id) as? GlucoseStored
            }.first?.glucose
            addAppBadge(glucose: latest.map { Int($0) })
        } catch {
            warning(.alerts, "Updating glucose app badge failed", error: error)
        }
    }

    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) {
        notificationCenter.getNotificationSettings { settings in
            DispatchQueue.main.async {
                completionHandler(settings)
            }
        }
    }

    func requestNotificationPermissions(completion: @escaping (Bool) -> Void) {
        debug(.alerts, "Requesting notification permission")
        notificationCenter.requestAuthorization(options: [.badge, .sound, .alert]) { granted, error in
            if granted {
                info(.alerts, "Notification permission granted")
                DispatchQueue.main.async {
                    completion(granted)
                }
            } else {
                warning(.alerts, "Notification permission not granted", error: error)
            }
        }
    }

    /// Forwards to the canonical snooze entry point on `TrioAlertManager`.
    /// All snooze surfaces (this method via UN actions / Watch / Snooze
    /// module / in-app banner) converge there so persistent state, mute
    /// window, and observers stay in sync.
    @MainActor func applySnooze(for duration: TimeInterval) async {
        await trioAlertManager.applySnooze(for: duration)
    }

    func logCarbsRequired(grams: Decimal?, alertID: String?) async -> CarbsRequiredLogOutcome {
        await carbsRequiredLogHandler.log(grams: grams, alertID: alertID)
    }

    private func handleLogCarbsResponse(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { [weak self] in
            defer { completion() }
            guard let self else { return }
            let payload = CarbsRequiredNotification.payload(from: userInfo)
            let outcome = await self.logCarbsRequired(grams: payload.grams, alertID: payload.alertID)
            switch outcome {
            case .alreadyLogged,
                 .logged:
                if userInfo[AlertUserInfoKey.managerIdentifier.rawValue] is String {
                    self.trioAlertManager.handleNotificationResponse(response)
                }
            case .exceedsMaxCarbs:
                self.postLogCarbsExceedsMax(grams: payload.grams)
            case .failed,
                 .invalidRequest:
                // Leave the alert up so the user can retry, and say why nothing was logged.
                self.postLogCarbsFailure()
            }
        }
    }

    private func postLogCarbsExceedsMax(grams: Decimal?) {
        let maxCarbs = settingsManager.settings.maxCarbs
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't log carbs", comment: "Title when the Log Carbs notification action fails")
        content.body = String(
            format: String(
                localized: "Not logged: %d g is above your Max Carbs (%d g). Open Trio to log carbs.",
                comment: "Log Carbs rejected: amount above Max Carbs"
            ),
            NSDecimalNumber(decimal: grams ?? 0).intValue,
            NSDecimalNumber(decimal: maxCarbs).intValue
        )
        notificationCenter.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func postLogCarbsFailure() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't log carbs", comment: "Title when the Log Carbs notification action fails")
        content.body = String(
            localized: "The carbs were not saved. Open Trio to add them.",
            comment: "Body when the Log Carbs notification action fails"
        )
        notificationCenter.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension BaseUserNotificationsManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if userInfo[AlertUserInfoKey.managerIdentifier.rawValue] is String {
            completionHandler([.badge, .sound, .list])
            return
        }
        completionHandler([.banner, .badge, .sound, .list])
    }

    /// UNUserNotificationCenterDelegate method called when user interacts with a notification.
    /// This can be called off the main thread, so we ensure all work happens on @MainActor.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Completes after the carbs are written so iOS doesn't suspend the app mid-write.
        if response.actionIdentifier == CarbsRequiredNotification.logCarbsActionIdentifier {
            handleLogCarbsResponse(response, completion: completionHandler)
            return
        }

        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        if userInfo[AlertUserInfoKey.managerIdentifier.rawValue] is String {
            trioAlertManager.handleNotificationResponse(response)
            return
        }

        // Handle quick snooze actions (from notification action buttons).
        if let quickAction = NotificationResponseAction(rawValue: response.actionIdentifier) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applySnooze(for: quickAction.duration)
            }
        }
    }
}

extension BaseUserNotificationsManager: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        Task { await updateGlucoseBadge() }
    }
}

// MARK: - Carbs Required "Log Carbs"

private enum CarbsRequiredLogError: Error {
    case carbEntryNotSaved
}

enum CarbsRequiredLogOutcome: String, Equatable {
    case logged
    case alreadyLogged
    case invalidRequest
    /// The amount in the alert is above the current Max Carbs; nothing is logged or marked.
    case exceedsMaxCarbs
    case failed
}

/// Remembers which Carbs Required alerts were already logged, so a repeated tap or
/// the watch and phone both delivering the action can't store the carbs twice.
protocol LoggedCarbsAlertStore {
    /// Atomically records `alertID`. Returns false if it was already recorded.
    func markLogged(_ alertID: String, now: Date) -> Bool
    func unmark(_ alertID: String)
}

final class UserDefaultsLoggedCarbsAlertStore: LoggedCarbsAlertStore {
    private let defaults: UserDefaults
    private let key: String
    private let retention: TimeInterval
    /// Shared by every instance: the iPhone action and the watch message each build their own
    /// store, and the check-and-mark must be atomic across both.
    private static let lock = NSLock()
    private var lock: NSLock { Self.lock }

    init(
        defaults: UserDefaults = .standard,
        key: String = "CarbsRequiredLog.loggedAlerts",
        retention: TimeInterval = 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.key = key
        self.retention = retention
    }

    func markLogged(_ alertID: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var logged = (defaults.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
        let cutoff = now.timeIntervalSince1970 - retention
        logged = logged.filter { $0.value >= cutoff }
        guard logged[alertID] == nil else {
            defaults.set(logged, forKey: key)
            return false
        }
        logged[alertID] = now.timeIntervalSince1970
        defaults.set(logged, forKey: key)
        return true
    }

    func unmark(_ alertID: String) {
        lock.lock()
        defer { lock.unlock() }
        var logged = (defaults.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
        logged[alertID] = nil
        defaults.set(logged, forKey: key)
    }
}

final class CarbsRequiredLogHandler {
    private let store: LoggedCarbsAlertStore
    private let maxCarbs: () -> Decimal
    private let storeCarbs: (Decimal) async throws -> Void
    private let now: () -> Date

    init(
        store: LoggedCarbsAlertStore,
        maxCarbs: @escaping () -> Decimal,
        storeCarbs: @escaping (Decimal) async throws -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.maxCarbs = maxCarbs
        self.storeCarbs = storeCarbs
        self.now = now
    }

    func log(grams: Decimal?, alertID: String?) async -> CarbsRequiredLogOutcome {
        guard let grams, grams > 0, Decimal(NSDecimalNumber(decimal: grams).intValue) == grams, let alertID, !alertID.isEmpty
        else { return .invalidRequest }
        // Never log a different number than the one the user was shown.
        guard grams <= maxCarbs() else { return .exceedsMaxCarbs }
        guard store.markLogged(alertID, now: now()) else { return .alreadyLogged }
        do {
            try await storeCarbs(grams)
            return .logged
        } catch {
            // A failed write must not block a retry of the same alert.
            store.unmark(alertID)
            warning(.treatments, "Log Carbs failed to save carbs", error: error)
            return .failed
        }
    }
}
