import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
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
