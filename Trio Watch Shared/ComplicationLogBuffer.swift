import Foundation

/// In-memory ring buffer for complication-related log lines. Used by TrioComplicationDataStore.log().
/// Watch App Extension can set a forwarder on the data store so lines also go to WatchLogger; this buffer
/// just retains recent entries for debugging. Thread-safe.
enum ComplicationLogBuffer {
    private static let maxEntries = 200
    private static let lock = NSLock()
    private static var entries: [String] = []

    static func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(message)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
    }
}
