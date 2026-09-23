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
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            switch newScenePhase {
            case .active:
                G7DirectBLEManager.shared.onSceneActive()
            case .inactive:
                G7DirectBLEManager.shared.onSceneInactive()
            case .background:
                G7DirectBLEManager.shared.onSceneInactive()
            @unknown default:
                break
            }

            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}
