import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var watchState = WatchState()

    init() {
        WatchNotificationHandler.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView(state: watchState)
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            watchState.handleScenePhaseChange(newScenePhase)
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}
