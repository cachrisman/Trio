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
            await WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            let oldToken = watchScenePhaseToken(oldPhase)
            let newToken = watchScenePhaseToken(newPhase)

            if newPhase == .active {
                WatchState.shared.handleForegroundActiveEntry()
            } else if newPhase == .background || newPhase == .inactive {
                WatchState.shared.handleForegroundInactiveOrBackground(phase: watchScenePhaseToken(newPhase))
            }

            let forceFlush = newPhase != .active
            Task {
                // C-209-4: slow WC log shipping to 10 min while backgrounded. Set BEFORE the
                // forced flush below so the new cadence applies from this transition onward.
                await WatchLogger.shared.setBackgrounded(newPhase != .active)
                await WatchLogger.shared.log(
                    "event=watch_scene_phase_transition old=\(oldToken) new=\(newToken) source=swiftui_environment",
                    force: forceFlush
                )
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
