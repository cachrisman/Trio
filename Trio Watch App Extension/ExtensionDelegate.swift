import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Only set in Watch App Extension; complication extension has no WatchLogger so forwarder stays nil.
        TrioComplicationDataStore.setLogForwarder { msg in Task { await WatchLogger.shared.log(msg) } }
        WatchState.shared.scheduleBackgroundLaunchDisarmIfNeeded()
        // Eagerly allocate the G7 direct-BLE observer's `CBCentralManager`
        // so watchOS can restore its state before the first scene-active
        // entry (design §13). Does not start scanning — the actual attach
        // kicks on .poweredOn / .active.
        G7DirectBLEObserver.shared.primeCentral()
        Task {
            await WatchLogger.shared.log(
                "event=watch_extension_launched source=wk_application_delegate "
                    + "method=applicationDidFinishLaunching",
                force: false
            )
            // Emit App Group diagnostics early, before any snapshot reads/writes.
            let diagnostics = TrioComplicationDataStore.shared.diagnosticsSummary(context: "applicationDidFinishLaunching")
            await WatchLogger.shared.log(diagnostics, force: false)
        }
        WatchState.shared.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        WatchState.shared.handleForegroundActiveEntry()
        G7DirectBLEObserver.shared.start()
        Task {
            await WatchLogger.shared.log(
                "event=watch_app_became_active source=wk_application_delegate "
                    + "method=applicationDidBecomeActive context=foreground",
                force: false
            )
        }
        // Note: forceComplicationUpdate() is now called in finalizePendingData() after fresh data arrives
        // This prevents the race condition where stale data was saved before fresh data arrived
    }

    func applicationWillResignActive() {
        WatchState.shared.handleForegroundInactiveOrBackground()
        Task {
            await WatchLogger.shared.log(
                "event=watch_app_resigning_active source=wk_application_delegate "
                    + "method=applicationWillResignActive",
                force: false
            )
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task {
            await WatchLogger.shared.log(
                "event=complication_bgtask_forwarding source=wk_application_delegate count=\(backgroundTasks.count)"
            )
        }
        WatchState.shared.handleBackgroundTasks(backgroundTasks)
    }
}
