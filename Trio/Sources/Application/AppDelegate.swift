import FirebaseCore
import FirebaseCrashlytics
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        FirebaseApp.configure()

        // Default to `true` if the key doesn't exist
        let crashReportingEnabled: Bool = PropertyPersistentFlags.shared.diagnosticsSharingEnabled ?? true

        // The docs say that changes to this don't take effect until
        // the next app boot, but this is fine since the app will need
        // to boot after a crash
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(crashReportingEnabled)
        Crashlytics.crashlytics().setCustomValue(Bundle.main.appDevVersion ?? "unknown", forKey: "app_dev_version")

        // Check for unexpected termination from previous launch, then mark this launch.
        // Note: AppTerminationTracker uses UserDefaults for state persistence. In rare cases
        // (ultra-rapid termination <1s), the state may not be synced before iOS kills the app.
        // If this becomes a problem, consider: (A) file-based atomic writes, (B) hybrid
        // UserDefaults + file approach. For now, UserDefaults is sufficient for most cases.
        AppTerminationTracker.shared.checkForUnexpectedTermination()
        AppTerminationTracker.shared.markAppLaunched(launchOptions: launchOptions)

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AppTerminationTracker.shared.markAppBecameActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        AppTerminationTracker.shared.markAppWillResignActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppTerminationTracker.shared.markAppEnteredBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        AppTerminationTracker.shared.markAppWillEnterForeground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppTerminationTracker.shared.markAppWillTerminate()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppTerminationTracker.shared.handleMemoryWarning()
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        debug(.remoteControl, "Received notification")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
            let encryptedMessage = try JSONDecoder().decode(EncryptedPushMessage.self, from: jsonData)

            Task {
                do {
                    try await TrioRemoteControl.shared.handleRemoteNotification(encryptedData: encryptedMessage.encryptedData)
                    completionHandler(.newData)
                } catch {
                    debug(
                        .default,
                        "\(DebuggingIdentifiers.failed) failed to handle remote notification with error: \(error)"
                    )
                    completionHandler(.failed)
                }
            }
        } catch {
            debug(.remoteControl, "Error decoding push message shell: \(error)")
            completionHandler(.failed)
        }
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()

        Task {
            do {
                try await TrioRemoteControl.shared.handleAPNSChanges(deviceToken: token)
            } catch {
                debug(
                    .remoteControl,
                    "\(DebuggingIdentifiers.failed) failed to register for remote notifications: \(error)"
                )
            }
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        debug(.remoteControl, "Failed to register for remote notifications: \(error)")
    }
}
