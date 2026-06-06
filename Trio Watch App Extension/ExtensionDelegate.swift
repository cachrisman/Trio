import G7SensorKit
import WatchKit

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Fork-level G7SensorKit telemetry (`G7TelemetryPayload`) → WatchLogger → BetterStack
        // (same pipeline as BLE logs).
        G7Telemetry.emit = { payload in
            Task { @MainActor in
                let sid = G7WatchSensorAdapter.shared.adapterSessionID ?? "nil"
                let sensorName = G7WatchSensorAdapter.shared.telemetrySensorName
                let line = G7StructuredTelemetryLogLine.formatCoreTelemetry(
                    sensorName: sensorName,
                    payload: payload,
                    g7Session: sid
                )
                await WatchLogger.shared.log(line)
            }
        }

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
