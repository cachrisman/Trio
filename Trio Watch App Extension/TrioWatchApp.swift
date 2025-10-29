import SwiftUI

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFirstActivation = true

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .active {
                // Mark process start on first activation
                if isFirstActivation {
                    WatchSyncUtilities.markProcessStart()
                    isFirstActivation = false
                    Task {
                        await WatchLogger.shared.log("⌚️ App launched - cold start detected")
                    }
                }
            }
            
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}
