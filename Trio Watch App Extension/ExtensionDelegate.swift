import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Only set in Watch App Extension; complication extension has no WatchLogger so forwarder stays nil.
        TrioComplicationDataStore.setLogForwarder { msg in Task { await WatchLogger.shared.log(msg) } }
        Task {
            await WatchLogger.shared.log("Watch extension launched", force: true)
            // Emit App Group diagnostics early, before any snapshot reads/writes.
            let diagnostics = TrioComplicationDataStore.shared.diagnosticsSummary(context: "applicationDidFinishLaunching")
            await WatchLogger.shared.log(diagnostics, force: true)
        }
        WatchState.shared.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        Task { await WatchLogger.shared.log("event=watch_app_became_active context=foreground") }
        WatchState.shared.noteAppBecameActive()
        WatchState.shared.requestWatchStateUpdate()
        // Note: forceComplicationUpdate() is now called in finalizePendingData() after fresh data arrives
        // This prevents the race condition where stale data was saved before fresh data arrived
    }

    func applicationWillResignActive() {
        Task { await WatchLogger.shared.log("Watch app entering background") }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task {
            await WatchLogger.shared.log("event=complication_bgtask_forwarding count=\(backgroundTasks.count)")
        }
        WatchState.shared.handleBackgroundTasks(backgroundTasks)
    }
}
