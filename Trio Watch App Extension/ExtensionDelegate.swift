import G7SensorKit
import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // C-208-9: start the telemetry ring drainer first — emitters can enqueue from any point
        // below (synchronously, no Task-per-event) and nothing is lost pre-drainer either.
        WatchTelemetryRing.shared.startDrainer()

        // C-209-5 (B6): enable battery monitoring at launch. WatchKit populates level/state
        // asynchronously after enabling, so the previous lazy enable-on-first-log returned
        // unknown/unknown for the first read of every process. (The per-file enable guards in
        // WatchLogger/ComplicationLogBuffer stay — they're idempotent.)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true

        // C-208-7 (1.8): assign the telemetry sink BEFORE constructing the adapter (whose init
        // creates the `CBCentralManager`) so no BLE callback can race the closure publication.
        // C-208-9: the sink is now a synchronous ring enqueue using emit-time session context
        // (kept in sync by the adapter) — no MainActor hop on the BLE path.
        // Fork-level G7SensorKit telemetry (`G7TelemetryPayload`) → ring → WatchLogger →
        // BetterStack (same downstream pipeline as BLE logs).
        G7Telemetry.emit = { payload in
            WatchTelemetryRing.shared.enqueueCoreTelemetry(payload: payload)
        }

        // D6: force-instantiate the BLE adapter (and its `CBCentralManager`, created with the
        // `CBCentralManagerOptionRestoreIdentifierKey`) synchronously at launch so the OS can
        // deliver `willRestoreState` on a background relaunch (M2 telemetry pending — per Apple
        // docs, state restoration may not exist on watchOS at all).
        // WKApplicationDelegate callbacks run on the main thread, so assumeIsolated is safe.
        MainActor.assumeIsolated { _ = G7WatchSensorAdapter.shared }

        // Only set in Watch App Extension; complication extension has no WatchLogger so forwarder stays nil.
        TrioComplicationDataStore.setLogForwarder { msg in Task { await WatchLogger.shared.log(msg) } }
        // C-217 V-2b: bridge the extension-local rolling glucose history into saved snapshots so the
        // widget's accessoryRectangular sparkline can read it. Only the extension can see the history
        // store; the widget process never sets this (it reads snapshots, never saves).
        TrioComplicationDataStore.shared.recentReadingsProvider = { WatchGlucoseHistoryStore.shared.recentReadingsCompact() }
        WatchState.shared.scheduleBackgroundLaunchDisarmIfNeeded()
        Task {
            await WatchLogger.shared.log(
                "event=watch_extension_launched source=wk_application_delegate "
                    + "method=applicationDidFinishLaunching",
                force: false
            )
            // Emit App Group diagnostics early, before any snapshot reads/writes.
            let diagnostics = TrioComplicationDataStore.shared.diagnosticsSummary(
                context: "applicationDidFinishLaunching"
            )
            await WatchLogger.shared.log(diagnostics, force: false)
        }
        WatchState.shared.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        WatchState.shared.handleForegroundActiveEntry()
        // C-210-9 (scan #3): recover an unserviced complication reload that the in-memory grace
        // timer missed because the app was suspended before it fired. Cheap App-Group generation
        // compare; re-requests at most once per rate-limit window.
        TrioComplicationDataStore.shared.reconcileUnservicedReloadOnLaunch()
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
        // Semantically `.inactive` — losing active status (often before SwiftUI reports `.background`).
        WatchState.shared.handleForegroundInactiveOrBackground(phase: "inactive")
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
