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
        // `initial: true` covers cold start when the scene is already `.active` before any phase *change* is observed.
        .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
            let oldToken = watchScenePhaseToken(oldPhase)
            let newToken = watchScenePhaseToken(newPhase)

            if newPhase == .active {
                WatchState.shared.handleForegroundActiveEntry()
            } else if newPhase == .background || newPhase == .inactive {
                WatchState.shared.handleForegroundInactiveOrBackground(scenePhase: newPhase)
            }

            let forceFlush = newPhase != .active
            Task {
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
