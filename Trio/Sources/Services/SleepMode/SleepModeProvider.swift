import Foundation

/// Phone-side sleep state. The Trio Focus Filter (attached to the Sleep Focus) reports on/off; until it has
/// reported once, a quiet window (default 22:00 to 06:00 local time) stands in. Foundation-only so it can be
/// unit tested outside the app. Not sent to the watch; the phone's watch transfer gate reads `isAsleep(now:)`.
final class SleepModeProvider {
    enum Source: String {
        case focusFilter = "focus_filter"
        case quietWindow = "quiet_window"
        case focusFilterStale = "focus_filter_stale"
    }

    enum Keys {
        static let filterReported = "Trio.sleepMode.filterReported"
        static let filterAsleep = "Trio.sleepMode.filterAsleep"
        static let filterReportedAt = "Trio.sleepMode.filterReportedAt"
        static let quietStartMinutes = "Trio.sleepMode.quietStartMinutes"
        static let quietEndMinutes = "Trio.sleepMode.quietEndMinutes"
    }

    static let defaultQuietStartMinutes = 22 * 60
    static let defaultQuietEndMinutes = 6 * 60
    /// An "asleep" filter report older than this no longer counts.
    static let filterStaleAfter: TimeInterval = 16 * 60 * 60

    private let defaults: UserDefaults
    private let calendar: () -> Calendar
    private let log: (String) -> Void
    private let lock = NSLock()
    private var lastLogged: Bool?
    private var lastSource: Source?

    init(
        defaults: UserDefaults = .standard,
        calendar: @escaping () -> Calendar = { Calendar.current },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.log = log
    }

    /// Minutes after local midnight (0..<1440) at which the quiet window starts.
    var quietStartMinutes: Int {
        get { minutes(forKey: Keys.quietStartMinutes, default: Self.defaultQuietStartMinutes) }
        set { defaults.set(Self.clamp(newValue), forKey: Keys.quietStartMinutes) }
    }

    /// Minutes after local midnight (0..<1440) at which the quiet window ends.
    var quietEndMinutes: Int {
        get { minutes(forKey: Keys.quietEndMinutes, default: Self.defaultQuietEndMinutes) }
        set { defaults.set(Self.clamp(newValue), forKey: Keys.quietEndMinutes) }
    }

    var hasFilterReported: Bool {
        defaults.bool(forKey: Keys.filterReported)
    }

    /// Called by the Focus Filter intent when the Sleep Focus turns on or off. All three writes and the
    /// evaluation happen under one lock, so a concurrent read sees a whole report.
    func reportFilter(isOn: Bool, at date: Date = Date()) {
        lock.lock()
        defaults.set(true, forKey: Keys.filterReported)
        defaults.set(isOn, forKey: Keys.filterAsleep)
        defaults.set(date.timeIntervalSince1970, forKey: Keys.filterReportedAt)
        let message = evaluateLocked(now: date)
        lock.unlock()
        emit(message)
    }

    /// The filter's last state once it has ever reported, otherwise the quiet window. An "asleep" filter report
    /// older than `filterStaleAfter` no longer counts (the Focus-off call may never have arrived), so the quiet
    /// window applies again. Logs a `sleep_mode` line when the result differs from the last evaluation.
    func isAsleep(now: Date = Date()) -> Bool {
        lock.lock()
        let asleep = resolveLocked(now: now)
        let message = logMessageLocked(asleep: asleep.asleep, source: asleep.source)
        lock.unlock()
        emit(message)
        return asleep.asleep
    }

    private func evaluateLocked(now: Date) -> String? {
        let result = resolveLocked(now: now)
        return logMessageLocked(asleep: result.asleep, source: result.source)
    }

    /// Caller holds `lock`.
    private func resolveLocked(now: Date) -> (asleep: Bool, source: Source) {
        guard defaults.bool(forKey: Keys.filterReported) else {
            return (isInQuietWindow(now: now), .quietWindow)
        }
        let filterAsleep = defaults.bool(forKey: Keys.filterAsleep)
        if filterAsleep, let reportedAt = defaults.object(forKey: Keys.filterReportedAt) as? Double,
           now.timeIntervalSince1970 - reportedAt > Self.filterStaleAfter
        {
            return (isInQuietWindow(now: now), .focusFilterStale)
        }
        return (filterAsleep, .focusFilter)
    }

    /// Caller holds `lock`. Updates `lastLogged` and returns the line to log, if any.
    private func logMessageLocked(asleep: Bool, source: Source) -> String? {
        let changed = lastLogged != asleep
        // The first evaluation of a process only logs when it is asleep, so a cold start while awake stays quiet.
        let shouldLog = changed && (lastLogged != nil || asleep)
        let sourceChanged = lastSource != source
        lastLogged = asleep
        lastSource = source
        // The stale fallback is logged on its own transition even when the awake/asleep value is unchanged.
        guard shouldLog || (source == .focusFilterStale && sourceChanged) else { return nil }
        return "sleep_mode state=\(asleep ? "asleep" : "awake") source=\(source.rawValue)"
    }

    private func emit(_ message: String?) {
        if let message { log(message) }
    }

    func isInQuietWindow(now: Date) -> Bool {
        let cal = calendar()
        let parts = cal.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let start = quietStartMinutes
        let end = quietEndMinutes
        if start == end { return false }
        if start < end { return minuteOfDay >= start && minuteOfDay < end }
        return minuteOfDay >= start || minuteOfDay < end
    }

    private func minutes(forKey key: String, default fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return Self.clamp(defaults.integer(forKey: key))
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 24 * 60 - 1)
    }
}
