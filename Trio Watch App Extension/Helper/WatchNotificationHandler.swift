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
                Task { await WatchLogger.shared.log("event=notification_auth_failed error=\(error.localizedDescription)") }
            } else {
                Task { await WatchLogger.shared.log("event=notification_auth granted=\(granted)") }
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
                Task { await WatchLogger.shared.log("event=direct_ble_stall_notification_failed error=\(error.localizedDescription)") }
            }
        }
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        center.getNotificationCategories { existingCategories in
            let glucoseCategory = NotificationCategoryFactory.createGlucoseCategory()

            var categories = existingCategories
            categories.update(with: glucoseCategory)
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
        defer { completionHandler() }

        guard let action = NotificationResponseAction(rawValue: response.actionIdentifier) else { return }
        sendSnoozeRequest(for: action)
    }

    /// Sends snooze request to iPhone via WatchConnectivity.
    /// WCSession.transferUserInfo is thread-safe and can be called from any thread.
    /// Relies on the watch app's WCSession owner (e.g., WatchState) to handle
    /// session activation and delegate management.
    private func sendSnoozeRequest(for action: NotificationResponseAction) {
        guard WCSession.isSupported() else { return }

        let payload: [String: Any] = [WatchMessageKeys.snoozeDuration: action.minutes]
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
}
