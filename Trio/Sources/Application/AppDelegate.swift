import FirebaseCore
import FirebaseCrashlytics
import SwiftUI
import UIKit
import UserNotifications
import WatchConnectivity
import WidgetKit

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    // Debounce & dedupe for watch complication pushes
    private var complicationDebounceItem: DispatchWorkItem?
    private var pendingComplicationPayload: [String: Any]?
    private var lastSentComplicationCore: (glucose: String, trend: String, delta: String, glucoseColor: String?)?

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        FirebaseApp.configure()
        AppGroupDebugExporter.ensureDocumentsFolder()

        // Default to `true` if the key doesn't exist
        let crashReportingEnabled: Bool = PropertyPersistentFlags.shared.diagnosticsSharingEnabled ?? true

        // The docs say that changes to this don't take effect until
        // the next app boot, but this is fine since the app will need
        // to boot after a crash
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(crashReportingEnabled)
        Crashlytics.crashlytics().setCustomValue(Bundle.main.appDevVersion ?? "unknown", forKey: "app_dev_version")

        return true
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        debug(.remoteControl, "📩 Received remote notification with keys: \(userInfo.keys)")
        debug(.remoteControl, "📩 Full userInfo: \(userInfo)")

        // 1️⃣ Determine notification type
        let isComplicationPush = userInfo["currentGlucose"] != nil ||
            userInfo["trend"] != nil ||
            userInfo["delta"] != nil

        debug(.remoteControl, "📨 Notification type: \(isComplicationPush ? "Complication" : "Firebase")")

        if isComplicationPush {
            // --- WATCH COMPLICATION UPDATE BRANCH ---

            let glucose = (userInfo["currentGlucose"] as? String) ?? "--"
            let trend = (userInfo["trend"] as? String) ?? ""
            let delta = (userInfo["delta"] as? String) ?? "--"
            let glucoseColor = (userInfo["currentGlucoseColorString"] as? String)

            debug(.remoteControl, "📱 Processing complication push: \(glucose) \(trend) \(delta) color:\(glucoseColor ?? "nil")")

            let now = Date()
            let serverDate: Date
            if let serverTS = userInfo["date"] as? TimeInterval {
                serverDate = Date(timeIntervalSince1970: serverTS)
            } else if let serverDateDirect = userInfo["date"] as? Date {
                serverDate = serverDateDirect
            } else {
                serverDate = now
            }

            debug(.remoteControl, "📅 Date handling: serverTS=\(userInfo["date"] ?? "nil"), serverDate=\(serverDate)")

            // Construct payload
            var payload: [String: Any] = [
                WatchMessageKeys.currentGlucose: glucose,
                WatchMessageKeys.trend: trend,
                WatchMessageKeys.delta: delta,
                WatchMessageKeys.date: serverDate // ✅ Send Date, not TimeInterval
            ]

            // Add glucose color if available
            if let glucoseColor = glucoseColor {
                payload[WatchMessageKeys.currentGlucoseColorString] = glucoseColor
            }

            debug(.remoteControl, "📤 Final payload: \(payload)")
            sendComplicationUpdateDebounced(payload)
            completionHandler(.newData)
            return
        } else {
            // --- FIREBASE / ENCRYPTED PUSH BRANCH ---
            debug(.remoteControl, "📦 Handling encrypted Firebase push notification")

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
                let encryptedMessage = try JSONDecoder().decode(EncryptedPushMessage.self, from: jsonData)

                Task {
                    do {
                        try await TrioRemoteControl.shared.handleRemoteNotification(encryptedData: encryptedMessage.encryptedData)
                        completionHandler(.newData)
                    } catch {
                        debug(.default, "❌ Failed to handle Firebase remote notification: \(error)")
                        completionHandler(.failed)
                    }
                }
            } catch {
                debug(.remoteControl, "❌ Error decoding Firebase push payload: \(error)")
                completionHandler(.failed)
            }
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

    private func sendComplicationUpdateDebounced(_ payload: [String: Any]) {
        pendingComplicationPayload = payload
        complicationDebounceItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let latest = self.pendingComplicationPayload else { return }
            self.pendingComplicationPayload = nil
            self.actuallySendComplicationPayload(latest)
        }
        complicationDebounceItem = work
        // Coalesce for 2s to swallow startup bursts
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func actuallySendComplicationPayload(_ payload: [String: Any]) {
        debug(.remoteControl, "📤 Actually sending complication payload: \(payload)")
        guard WCSession.isSupported() else {
            debug(.remoteControl, "🚫 WatchConnectivity not supported on this device.")
            return
        }
        // Dedupe: skip if no meaningful change
        if let g = payload[WatchMessageKeys.currentGlucose] as? String,
           let t = payload[WatchMessageKeys.trend] as? String,
           let d = payload[WatchMessageKeys.delta] as? String
        {
            let c = payload[WatchMessageKeys.currentGlucoseColorString] as? String
            let core = (g, t, d, c)
            if let last = lastSentComplicationCore, last == core {
                debug(.remoteControl, "⏭️ Skipping duplicate complication payload (no meaningful change)")
                return
            }
            lastSentComplicationCore = core
        }

        let session = WCSession.default
        if session.activationState != .activated {
            session.activate()
            // Small grace for activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if session.isReachable {
                    session.sendMessage(payload, replyHandler: nil) { error in
                        debug(.remoteControl, "❌ Complication sendMessage error: \(error)")
                    }
                    debug(.remoteControl, "✅ Sent complication update (reachable post-activate)")
                } else {
                    session.transferUserInfo(payload)
                    debug(.remoteControl, "ℹ️ Queued complication update via transferUserInfo (post-activate)")
                }
            }
        } else {
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { error in
                    debug(.remoteControl, "❌ Complication sendMessage error: \(error)")
                }
                debug(.remoteControl, "✅ Sent complication update (reachable)")
            } else {
                session.transferUserInfo(payload)
                debug(.remoteControl, "ℹ️ Queued complication update via transferUserInfo")
            }
        }
    }
}
