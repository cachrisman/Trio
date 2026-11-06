import Foundation

/// Reports watch crashes and errors through upstream's watch log pipeline.
///
/// Crash detection: a UserDefaults flag is set when the app becomes active and cleared when it
/// enters the background or becomes inactive. If the flag is still set on the next launch, the
/// previous run ended in the foreground without a clean transition, so it is logged as a
/// potential crash together with the context saved via `saveCrashContext`.
///
/// Delivery: everything is written to `WatchLogger` and shipped with `shipNow()`; the log ring and
/// file transfer take care of retries and acks. The phone forwards `.error` and `.fault` watch
/// entries to Crashlytics in `WatchCrashlyticsForwarder`.
actor WatchErrorReporter {
    static let shared = WatchErrorReporter()

    private static let lastRunWasForegroundKey = "watchLastRunWasForeground"
    private static let crashContextKey = "watchAppCrashContext"
    private static let lastActiveAtKey = "watchLastActiveAt"

    private init() {}

    static var previousRunWasForeground: Bool {
        UserDefaults.standard.bool(forKey: lastRunWasForegroundKey)
    }

    static func markBecameActiveImmediately() {
        UserDefaults.standard.set(true, forKey: lastRunWasForegroundKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastActiveAtKey)
    }

    static func markEnteredBackgroundOrInactiveImmediately() {
        UserDefaults.standard.set(false, forKey: lastRunWasForegroundKey)
    }

    func markBecameActive() async {
        Self.markBecameActiveImmediately()
    }

    func markEnteredBackgroundOrInactive() async {
        Self.markEnteredBackgroundOrInactiveImmediately()
    }

    func startup(previousRunWasForeground: Bool) async {
        guard previousRunWasForeground else { return }
        let defaults = UserDefaults.standard
        var context = defaults.dictionary(forKey: Self.crashContextKey) as? [String: String] ?? [:]
        if let lastActive = defaults.object(forKey: Self.lastActiveAtKey) as? TimeInterval {
            context["last_active_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: lastActive))
        }
        WatchLogger.shared.fault(.lifecycle, "event=watch_potential_crash" + Self.format(context))
        defaults.removeObject(forKey: Self.crashContextKey)
        // The flag itself is not touched here: the host clears the stale one synchronously at launch,
        // and by now `.active` may already have set it for this run.
        WatchLogger.shared.shipNow()
    }

    func saveCrashContext(_ context: [String: String]) async {
        UserDefaults.standard.set(context, forKey: Self.crashContextKey)
    }

    func reportError(_ error: Error, context: [String: String]? = nil) async {
        WatchLogger.shared.error(.lifecycle, "event=watch_error" + Self.format(context ?? [:]), error: error)
        WatchLogger.shared.shipNow()
    }

    func reportNonFatalIssue(_ message: String, context: [String: String]? = nil) async {
        WatchLogger.shared.warning(.lifecycle, "event=watch_nonfatal " + message + Self.format(context ?? [:]))
        WatchLogger.shared.shipNow()
    }

    // Sorted ` k=v` pairs with a leading space; values containing spaces are quoted
    private static func format(_ context: [String: String]) -> String {
        context.sorted { $0.key < $1.key }
            .map { key, value in " \(key)=" + (value.contains(" ") ? "\"\(value)\"" : value) }
            .joined()
    }
}
