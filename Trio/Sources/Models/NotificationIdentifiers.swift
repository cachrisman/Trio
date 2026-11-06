import Foundation
import UserNotifications

enum NotificationCategoryIdentifier: String {
    case trioAlert = "Trio.alert"
    case carbsRequired = "Trio.alert.carbsRequired"
}

enum NotificationResponseAction: String, CaseIterable {
    case snooze15 = "Trio.snooze15"
    case snooze1hr = "Trio.snooze1hr"
    case snooze3hr = "Trio.snooze3hr"
    case snooze6hr = "Trio.snooze6hr"

    var duration: TimeInterval {
        TimeInterval(minutes) * 60
    }

    var minutes: Int {
        switch self {
        case .snooze15:
            return 15
        case .snooze1hr:
            return 60
        case .snooze3hr:
            return 180
        case .snooze6hr:
            return 360
        }
    }

    var localizedTitle: String {
        switch self {
        case .snooze15:
            return String(localized: "Snooze 15 min", comment: "Snooze glucose alerts for 15 minutes")
        case .snooze1hr:
            return String(localized: "Snooze 1 hr", comment: "Snooze glucose alerts for 1 hour")
        case .snooze3hr:
            return String(localized: "Snooze 3 hrs", comment: "Snooze glucose alerts for 3 hours")
        case .snooze6hr:
            return String(localized: "Snooze 6 hrs", comment: "Snooze glucose alerts for 6 hours")
        }
    }
}

// MARK: - CarbsRequiredNotification

/// Action id and userInfo payload of the Carbs Required notification. Shared by the
/// iPhone and watch delegates. Kept apart from `NotificationResponseAction` because
/// that enum's `allCases` also drives the snooze sheet and the in-app banner.
enum CarbsRequiredNotification {
    static let logCarbsActionIdentifier = "Trio.logCarbs"
    static let gramsKey = "trio.carbsRequired.grams"
    static let alertIDKey = "trio.carbsRequired.alertID"

    /// No 6 hr snooze here; the shared `Trio.alert` category keeps all four.
    static let snoozeActions: [NotificationResponseAction] = [.snooze15, .snooze1hr, .snooze3hr]

    static var logCarbsTitle: String {
        String(localized: "Log Carbs", comment: "Notification action that logs the carbs a Carbs Required alert asked for")
    }

    static func userInfo(grams: Int, alertID: String) -> [AnyHashable: Any] {
        [gramsKey: grams, alertIDKey: alertID]
    }

    static func payload(from userInfo: [AnyHashable: Any]) -> (grams: Decimal?, alertID: String?) {
        let grams = (userInfo[gramsKey] as? NSNumber)?.decimalValue
        return (grams, userInfo[alertIDKey] as? String)
    }
}

// MARK: - NotificationCategoryFactory

enum NotificationCategoryFactory {
    static func createGlucoseCategory() -> UNNotificationCategory {
        let snoozeActions = NotificationResponseAction.allCases.map { action in
            UNNotificationAction(
                identifier: action.rawValue,
                title: action.localizedTitle,
                options: []
            )
        }

        // `.customDismissAction` — otherwise iOS swallows swipes silently and
        // the in-app banner outlives the notification.
        return UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.trioAlert.rawValue,
            actions: snoozeActions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    static func createCarbsRequiredCategory() -> UNNotificationCategory {
        // `.authenticationRequired`: the action feeds COB and dosing, so a locked
        // phone must not allow it from the lock screen. No `.foreground`; it runs
        // in the background.
        let logCarbs = UNNotificationAction(
            identifier: CarbsRequiredNotification.logCarbsActionIdentifier,
            title: CarbsRequiredNotification.logCarbsTitle,
            options: [.authenticationRequired]
        )
        let snoozes = CarbsRequiredNotification.snoozeActions.map { action in
            UNNotificationAction(identifier: action.rawValue, title: action.localizedTitle, options: [])
        }
        return UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.carbsRequired.rawValue,
            actions: [logCarbs] + snoozes,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
