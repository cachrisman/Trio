import WatchKit
import WidgetKit

/// Handles lifecycle and background refresh events for the Trio Watch app.
/// Ensures complication updates occur periodically and when the app becomes active.
class ExtensionDelegate: NSObject, WKApplicationDelegate {
    /// Called when the watch app launches or awakens in the background.
    func applicationDidFinishLaunching() {
        Task {
            await WatchLogger.shared.log("⌚️ ExtensionDelegate launched")
        }
        // Schedule first background refresh
        WatchState.shared.scheduleBackgroundRefresh()
    }

    /// Called when the app becomes active (e.g., user raises wrist or opens the app).
    func applicationDidBecomeActive() {
        Task {
            await WatchLogger.shared.log("⌚️ Watch app became active — forcing timeline reload")
        }
        WatchState.shared.noteAppBecameActive()

        // Always request fresh data when app becomes active
        WatchState.shared.requestWatchStateUpdate()

        // Trigger a timeline reload to show most recent data immediately
        TrioComplicationDataStore.shared.reloadTimeline()
        WatchState.shared.forceComplicationUpdate()
    }

    /// Called when the app enters background.
    func applicationWillResignActive() {
        Task {
            await WatchLogger.shared.log("⌚️ App entering background")
        }
    }

    /// Handles background refresh and snapshot tasks.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchState.shared.handleBackgroundTasks(backgroundTasks)
    }
}
