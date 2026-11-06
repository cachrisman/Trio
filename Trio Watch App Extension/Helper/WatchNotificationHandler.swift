import Foundation
import UserNotifications
import WatchConnectivity

final class WatchNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationHandler()

    override private init() {
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // C-210-5: request alert/sound auth so the watch can fire its own inferred direct-BLE stall
        // notification (the Dexcom app notifies from a CB callback; Trio must infer + notify).
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                WatchLogger.shared.warning(
                    .lifecycle,
                    "event=notification_auth_failed error=\(error.localizedDescription)"
                )
            } else {
                WatchLogger.shared.info(.lifecycle, "event=notification_auth granted=\(granted)")
            }
        }
        registerCategories(on: center)
    }

    /// C-210-5: inferred direct-BLE stall notification. Trio is observer-only — it cannot restart the
    /// Dexcom Watch app, so on a sustained Dexcom-side stall it nudges the user to do so. The caller
    /// (`G7WatchSensorAdapter`) enforces the alarm-fatigue guards (hard stall, Dexcom-side, once per
    /// episode); this just posts.
    func postDirectBleStallNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Watch sensor link interrupted"
        content.body = "On phone relay. If glucose stops updating on your watch, reopen the Dexcom Watch app."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "trio_direct_ble_stall",
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                WatchLogger.shared.warning(
                    .lifecycle,
                    "event=direct_ble_stall_notification_failed error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        center.getNotificationCategories { existingCategories in
            let glucoseCategory = NotificationCategoryFactory.createGlucoseCategory()

            var categories = existingCategories
            categories.update(with: glucoseCategory)
            categories.update(with: NotificationCategoryFactory.createCarbsRequiredCategory())
            // UNUserNotificationCenter methods should be called on main thread
            Task { @MainActor in
                center.setNotificationCategories(categories)
            }
        }
    }

    /// UNUserNotificationCenterDelegate method called when user interacts with a notification on watch.
    /// This can be called off the main thread. WCSession.transferUserInfo is thread-safe.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Held open until the phone answers so the reply (or failure) isn't lost to suspension.
        if response.actionIdentifier == CarbsRequiredNotification.logCarbsActionIdentifier {
            sendLogCarbsRequest(userInfo: response.notification.request.content.userInfo, completion: completionHandler)
            return
        }

        defer { completionHandler() }

        guard let action = NotificationResponseAction(rawValue: response.actionIdentifier) else { return }
        sendSnoozeRequest(minutes: action.minutes)
    }

    /// Sends snooze request to iPhone via WatchConnectivity.
    /// WCSession.transferUserInfo is thread-safe and can be called from any thread.
    /// Relies on the watch app's WCSession owner (e.g., WatchState) to handle
    /// session activation and delegate management.
    /// A duration of 0 ends the active snooze.
    func sendSnoozeRequest(minutes: Int) {
        guard WCSession.isSupported() else { return }

        let payload: [String: Any] = [WatchMessageKeys.snoozeDuration: minutes]
        let session = WCSession.default

        // Try sendMessage first if session is reachable and activated (faster, immediate delivery)
        // Fall back to transferUserInfo if not reachable or if sendMessage fails
        if session.isReachable, session.activationState == .activated {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Fallback to transferUserInfo if sendMessage fails
                session.transferUserInfo(payload)
            }
        } else {
            // Session not reachable or not activated - use transferUserInfo (queued delivery)
            session.transferUserInfo(payload)
        }
    }

    /// Asks the phone to log the carbs in `userInfo`. Deliberately has no
    /// `transferUserInfo` fallback: a queued request could log carbs long after the user
    /// was told it failed. Every outcome is surfaced as a local notification.
    private func sendLogCarbsRequest(userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        let payload = CarbsRequiredNotification.payload(from: userInfo)
        guard let grams = payload.grams, grams > 0, let alertID = payload.alertID else {
            notifyLogCarbs(String(localized: "Couldn't log carbs: invalid alert", comment: "Watch Log Carbs failure"))
            completion()
            return
        }

        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            notifyLogCarbs(String(localized: "Couldn't log carbs: iPhone not reachable", comment: "Watch Log Carbs failure"))
            completion()
            return
        }

        let message: [String: Any] = [
            WatchMessageKeys.logCarbsGrams: NSDecimalNumber(decimal: grams).intValue,
            WatchMessageKeys.logCarbsAlertID: alertID
        ]
        session.sendMessage(message, replyHandler: { [weak self] reply in
            switch reply[WatchMessageKeys.logCarbsResult] as? String {
            case "logged":
                self?.notifyLogCarbs(String(localized: "Carbs logged", comment: "Watch Log Carbs success"))
            case "alreadyLogged":
                self?.notifyLogCarbs(String(localized: "Carbs already logged", comment: "Watch Log Carbs duplicate"))
            case "exceedsMaxCarbs":
                let maxCarbs = (reply[WatchMessageKeys.maxCarbs] as? NSNumber)?.intValue
                let requested = NSDecimalNumber(decimal: grams).intValue
                self?.notifyLogCarbs(maxCarbs.map {
                    String(
                        format: String(
                            localized: "Not logged: %d g is above your Max Carbs (%d g). Open Trio to log carbs.",
                            comment: "Watch Log Carbs rejected: amount above Max Carbs"
                        ),
                        requested,
                        $0
                    )
                } ?? String(localized: "Not logged: above your Max Carbs. Open Trio to log carbs.", comment: "Watch Log Carbs rejected: amount above Max Carbs"))
            default:
                self?.notifyLogCarbs(String(localized: "Couldn't log carbs", comment: "Watch Log Carbs failure"))
            }
            completion()
        }, errorHandler: { [weak self] _ in
            self?.notifyLogCarbs(String(localized: "Couldn't log carbs: iPhone not reachable", comment: "Watch Log Carbs failure"))
            completion()
        })
    }

    private func notifyLogCarbs(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
