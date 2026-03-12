import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
        Task {
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            await WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build)", force: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .active {
                Task {
                    // Check for crashes and mark as active
                    await WatchErrorReporter.shared.startup()
                    await WatchErrorReporter.shared.markBecameActive()
                    // Flush persisted logs (will query ACKs first, then resend pending payloads)
                    await WatchLogger.shared.flushPersistedLogs()
                }
            } else if newScenePhase == .background || newScenePhase == .inactive {
                Task {
                    await WatchErrorReporter.shared.markEnteredBackgroundOrInactive()
                }
            }
        }
    }
}
