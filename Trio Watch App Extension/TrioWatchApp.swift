import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
                .task {
                    if scenePhase == .active {
                        G7DirectBLEObserver.shared.start()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            Task {
                await WatchLogger.shared.log("event=g7_ble_lifecycle scene_phase=\(String(describing: newScenePhase))")
            }

            if newScenePhase == .active {
                G7DirectBLEObserver.shared.start()
            } else if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}
