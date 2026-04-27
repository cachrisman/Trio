import Foundation

/// Structured logging for the G7 direct BLE observer. Forwards call-site context to `WatchLogger` so
/// BetterStack shows the syntactic caller, not this helper. See `docs/in-progress/watch-g7-direct-ble-observer/01-design.md`.
enum G7BLELog {
    static func log(
        _ message: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        Task {
            await WatchLogger.shared.log(
                message,
                function: function,
                file: file,
                line: line
            )
        }
    }
}
