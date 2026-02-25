import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task {
            await WatchLogger.shared.log("Watch extension launched", force: true)
            // Emit App Group diagnostics early, before any snapshot reads/writes.
            let diagnostics = TrioComplicationDataStore.shared.diagnosticsSummary(context: "applicationDidFinishLaunching")
            await WatchLogger.shared.log(diagnostics, force: true)
        }
        WatchState.shared.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        Task { await WatchLogger.shared.log("🟢 Watch app became active - requesting fresh data") }
        WatchState.shared.noteAppBecameActive()
        WatchState.shared.requestWatchStateUpdate()
        // Note: forceComplicationUpdate() is now called in finalizePendingData() after fresh data arrives
        // This prevents the race condition where stale data was saved before fresh data arrived
    }

    func applicationWillResignActive() {
        Task { await WatchLogger.shared.log("Watch app entering background") }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchState.shared.handleBackgroundTasks(backgroundTasks)
    }
}
