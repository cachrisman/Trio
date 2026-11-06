import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
        WatchLogger.shared.info(.lifecycle, "App launched")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = WKInterfaceDevice.current().systemVersion
        WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build) os_version=\(osVersion)")

        // Read before anything sets the flag; .active (below) sets it. Not set here: the app also launches in the background (BLE relaunch, complication refresh), and a later background kill is not a crash.
        let previousRunWasForeground = WatchErrorReporter.previousRunWasForeground
        // Clear the stale flag now, before `.active` sets it for this run, so a background-only run can't re-report it
        WatchErrorReporter.markEnteredBackgroundOrInactiveImmediately()
        Task { await WatchErrorReporter.shared.startup(previousRunWasForeground: previousRunWasForeground) }
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
                // Desaturate the whole face when NOT foreground-active, so a passive
                // Return-to-Clock glance (.inactive, where the OS won't start an extended session)
                // is visually distinct from an active open (.active).
                .grayscale(scenePhase == .active ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: scenePhase)
        }
        .onChange(of: scenePhase) { oldPhase, newScenePhase in
            let oldToken = watchScenePhaseToken(oldPhase)
            let newToken = watchScenePhaseToken(newScenePhase)

            if newScenePhase == .active {
                WatchErrorReporter.markBecameActiveImmediately()
                WatchState.shared.handleForegroundActiveEntry()
            }
            if newScenePhase == .background || newScenePhase == .inactive {
                WatchErrorReporter.markEnteredBackgroundOrInactiveImmediately()
                WatchState.shared.handleForegroundInactiveOrBackground(phase: newToken)
            }
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
                ComplicationLogForwarder.shared.drain()
            }

            WatchLogger.shared.log(
                "event=watch_scene_phase_transition old=\(oldToken) new=\(newToken) source=swiftui_environment",
                force: newScenePhase != .active
            )
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
