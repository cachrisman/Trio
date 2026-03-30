import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) var appDelegate
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            let oldToken = watchScenePhaseToken(oldPhase)
            let newToken = watchScenePhaseToken(newPhase)
            let forceFlush = newPhase != .active
            Task {
                await WatchLogger.shared.log(
                    "event=watch_scene_phase_transition old=\(oldToken) new=\(newToken) source=swiftui_environment",
                    force: forceFlush
                )
            }

            if newPhase == .active {
                Task {
                    // Check for crashes and mark as active
                    await WatchErrorReporter.shared.startup()
                    await WatchErrorReporter.shared.markBecameActive()
                    // Flush persisted logs (will query ACKs first, then resend pending payloads)
                    await WatchLogger.shared.flushPersistedLogs()
                }
            } else if newPhase == .background || newPhase == .inactive {
                Task {
                    await WatchErrorReporter.shared.markEnteredBackgroundOrInactive()
                }
            }
        }
    }
}

private func watchScenePhaseToken(_ phase: ScenePhase) -> String {
    switch phase {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
}
