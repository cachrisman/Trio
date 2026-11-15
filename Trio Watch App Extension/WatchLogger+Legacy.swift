import Foundation

// Keeps the old patch 09 call sites working on top of the upstream WatchLogger pipeline.
extension WatchLogger {
    func log(
        _ message: String,
        force: Bool = false,
        function _: String = #function,
        file _: String = #fileID,
        line _: Int = #line
    ) {
        let category: WatchLogEntry.Category = message.hasPrefix("module=g7_") ? .g7 : .lifecycle
        info(category, message)
        if force {
            shipNow()
        }
    }
}
