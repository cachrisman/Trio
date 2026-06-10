import G7SensorKit
import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // C-208-9: start the telemetry ring drainer first — emitters can enqueue from any point
        // below (synchronously, no Task-per-event) and nothing is lost pre-drainer either.
        WatchTelemetryRing.shared.startDrainer()

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
