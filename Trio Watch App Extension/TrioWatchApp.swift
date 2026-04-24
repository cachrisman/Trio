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
                G7DirectBLEObserver.shared.scenePhaseChanged(.active)
            } else if newPhase == .background || newPhase == .inactive {
                WatchState.shared.handleForegroundInactiveOrBackground()
                // Deliberately a no-op for the observer — brief .inactive
                // transitions (Digital Crown detour, notifications) must
                // not tear down a healthy session. Design §13 / anti-
                // patterns item 1.
                G7DirectBLEObserver.shared.scenePhaseChanged(.inactive)
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
