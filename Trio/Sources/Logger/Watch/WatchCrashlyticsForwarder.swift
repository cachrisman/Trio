import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// Forwards watch `.error` / `.fault` log entries received by `WatchLogIngest` to Crashlytics.
///
/// Every forwarded entry is added to the Crashlytics breadcrumb log; a non-fatal is recorded
/// at most once per distinct level + category + message prefix per throttle window.
/// Does nothing when Firebase was not configured or the user opted out of Crashlytics sharing.
enum WatchCrashlyticsForwarder {
    private static let throttleWindow: TimeInterval = 10 * 60
    private static let messagePrefixLength = 80
    private static let errorDomain = "Trio.Watch"

    private static let lock = NSLock()
    private static var lastRecorded: [String: Date] = [:]

    static func forward(_ entries: [WatchLogEntry]) {
        let relevant = entries.filter { $0.level == .error || $0.level == .fault }
        guard !relevant.isEmpty else { return }

        // Never touch Crashlytics when Firebase was not configured (opted out at launch)
        guard FirebaseApp.app() != nil,
              PropertyPersistentFlags.shared.crashlyticsSharingEnabled ?? true
        else { return }

        let crashlytics = Crashlytics.crashlytics()
        let formatter = ISO8601DateFormatter()

        for entry in relevant {
            crashlytics.log("watch \(entry.level.rawValue) \(entry.category.rawValue): \(entry.message)")

            guard shouldRecord(entry) else { continue }

            let error = NSError(
                domain: errorDomain,
                code: entry.level == .fault ? 2 : 1,
                userInfo: [
                    NSLocalizedDescriptionKey: entry.message,
                    "category": entry.category.rawValue,
                    "seq": entry.seq,
                    "watchDate": formatter.string(from: entry.date)
                ]
            )
            crashlytics.record(error: error)
        }
    }

    private static func shouldRecord(_ entry: WatchLogEntry) -> Bool {
        let key = "\(entry.level.rawValue)|\(entry.category.rawValue)|\(entry.message.prefix(messagePrefixLength))"
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if let last = lastRecorded[key], now.timeIntervalSince(last) < throttleWindow {
            return false
        }
        lastRecorded[key] = now
        lastRecorded = lastRecorded.filter { now.timeIntervalSince($0.value) < throttleWindow }
        return true
    }
}
