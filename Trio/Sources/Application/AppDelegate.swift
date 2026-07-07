import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Default to `true` if the key doesn't exist — Trio is opt-out, not opt-in.
        // Read before touching Firebase: an explicit opt-out means we never
        // configure it, so no component can queue or upload anything.
        let crashReportingEnabled: Bool = PropertyPersistentFlags.shared.crashlyticsSharingEnabled ?? true
        CrashReportingGate.configureAtLaunch(enabled: crashReportingEnabled)

        // Telemetry: record this cold launch into the sliding 7-day window,
        // then drive cadence via three layered triggers — listed below in
        // priority of reliability:
        //
        //   1. SHA-change ping: build updated since last send. Awaited so
        //      the lastSentAt stamp is fresh before the overdue check.
        //   2. checkAndSendIfOverdue: covers the regular cold launch on the
        //      same build when >24h has passed since the last successful
        //      send. Together with the foreground-transition hook below
        //      (`applicationWillEnterForeground`), this keeps daily pings
        //      flowing on iOS.
        //   3. scheduleRecurring: best-effort fallback for the rare case
        //      where the app stays foregrounded for a full 24h.
        TelemetryClient.shared.recordColdLaunch()
        Task.detached {
            if TelemetryClient.shared.buildShaChangedSinceLastSend() {
                await TelemetryClient.shared.maybeSend()
            }
            TelemetryClient.shared.scheduleRecurring()
            TelemetryClient.shared.checkAndSendIfOverdue()
        }

        // Check for unexpected termination from previous launch, then mark this launch.
        // Note: AppTerminationTracker uses UserDefaults for state persistence. In rare cases
        // (ultra-rapid termination <1s), the state may not be synced before iOS kills the app.
        // If this becomes a problem, consider: (A) file-based atomic writes, (B) hybrid
        // UserDefaults + file approach. For now, UserDefaults is sufficient for most cases.
        AppTerminationTracker.shared.checkForUnexpectedTermination()
        AppTerminationTracker.shared.markAppLaunched(launchOptions: launchOptions)

        return true
    }

    func applicationDidBecomeActive(_: UIApplication) {
        AppTerminationTracker.shared.markAppBecameActive()
    }

    func applicationWillResignActive(_: UIApplication) {
        AppTerminationTracker.shared.markAppWillResignActive()
    }

    func applicationDidEnterBackground(_: UIApplication) {
        AppTerminationTracker.shared.markAppEnteredBackground()
    }

    /// Foreground-transition entry point. Drives telemetry cadence
    /// (re-evaluates the overdue window — `scheduleRecurring`'s GCD timer
    /// doesn't fire while suspended; no-op if a send landed within 24h)
    /// and notifies `AppTerminationTracker` so lifecycle state is fresh.
    func applicationWillEnterForeground(_: UIApplication) {
        TelemetryClient.shared.checkAndSendIfOverdue()
        AppTerminationTracker.shared.markAppWillEnterForeground()
    }

    func applicationWillTerminate(_: UIApplication) {
        AppTerminationTracker.shared.markAppWillTerminate()
    }

    func applicationDidReceiveMemoryWarning(_: UIApplication) {
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
