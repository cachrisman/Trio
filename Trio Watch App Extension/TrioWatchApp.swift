import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
        WatchLogger.shared.info(.lifecycle, "App launched")

        // Read before anything sets the flag; .active (below) sets it. Not set here: the app also launches in the background (BLE relaunch, complication refresh), and a later background kill is not a crash.
        let previousRunWasForeground = WatchErrorReporter.previousRunWasForeground
        // Clear the stale flag now, before `.active` sets it for this run, so a background-only run can't re-report it
        WatchErrorReporter.markEnteredBackgroundOrInactiveImmediately()
        Task { await WatchErrorReporter.shared.startup(previousRunWasForeground: previousRunWasForeground) }
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .active {
                WatchErrorReporter.markBecameActiveImmediately()
            }
            if newScenePhase == .background || newScenePhase == .inactive {
                WatchErrorReporter.markEnteredBackgroundOrInactiveImmediately()
            }
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
            }
        }
    }
}
