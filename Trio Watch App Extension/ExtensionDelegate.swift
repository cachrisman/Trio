import Foundation
import WatchKit
import WatchConnectivity

final class ExtensionDelegate: NSObject, WKExtensionDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let appRefresh as WKApplicationRefreshBackgroundTask:
                // Try to request a lightweight update
                let session = WCSession.default
                if session.activationState != .activated {
                    session.activate()
                }
                if session.isReachable {
                    let message: [String: Any] = [
                        WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState
                    ]
                    session.sendMessage(message, replyHandler: nil, errorHandler: nil)
                }
                appRefresh.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        // Schedule next refresh in case nothing else does
        WKExtension.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(6 * 60), userInfo: nil, scheduledCompletion: { _ in })
    }
}
