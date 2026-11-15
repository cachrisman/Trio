import Foundation
#if os(watchOS)
import WatchKit
#endif

/// Hybrid log buffer: in-memory ring (all targets) + optional App Group file (complication only, WIDGET_EXTENSION).
/// Used by TrioComplicationDataStore.log(). Watch App drains the file and forwards to Better Stack.
///
/// Contract:
/// - Single writer: only the complication extension appends to the file. Watch app drains (read, rename,
///   truncate, delete); must not append.
/// - Writer only ever writes to `complication_log.txt`; never to drain files (complication_log.drain.*).
/// - File format: newline-delimited UTF-8; same path/truncation as 06. Drain is race-safe (atomic
///   rename-then-read). Truncation is a full-file rewrite and can race with a concurrent drain rename;
///   we accept best-effort loss and possible rare corrupt chunk in that case.
/// - TRIO-119: every line the writer appends ends with ` seq=<n>`, a counter the writer persists in the App Group
///   defaults. The drain detects gaps (lost or truncated lines) from it. The watch app only reads the counter's
///   effects from the file; it never writes the counter.
enum ComplicationLogBuffer {
    // MARK: - Ring buffer (all targets)
    private static let maxEntries = 200
    private static var entries: [String] = []

    // MARK: - File (06 contract: same path, format, truncation)
    private static let logFileName = "complication_log.txt"
    private static let logsSubdir = "logs"
    /// Internal so the drain scheduler can derive its half-cap threshold from it.
    static let sizeCapBytes = 64 * 1024
    private static let truncateKeepBytes = 32 * 1024

    /// Single queue for ring + file within process. Drain uses atomic rename-then-read; best-effort delivery, rare corruption possible when truncation races with drain.
    private static let queue = DispatchQueue(label: "ComplicationLogBuffer.queue")

    #if os(watchOS)
    // Non-widget battery cache (Watch App Extension only; access/mutate only on queue or MainActor per below).
    // Queue-confined (access/mutate only on ComplicationLogBuffer.queue):
    private static var nonWidgetLastBatteryContext: String = "battery_level_percent=unknown battery_state=unknown"
    private static var nonWidgetLastBatteryRefreshEpoch: TimeInterval = 0
    private static var nonWidgetBatteryRefreshInFlight: Bool = false
    // MainActor-confined (access/mutate only on MainActor, inside nonWidgetBatteryContextOnMain()):
    private static var nonWidgetHasEnabledBatteryMonitoring: Bool = false

    @MainActor
    private static func nonWidgetBatteryContextOnMain() -> String {
        let device = WKInterfaceDevice.current()
        if !nonWidgetHasEnabledBatteryMonitoring {
            nonWidgetHasEnabledBatteryMonitoring = true
            device.isBatteryMonitoringEnabled = true
        }
        let levelText: String
        if device.batteryLevel >= 0 {
            levelText = String(Int((device.batteryLevel * 100).rounded()))
        } else {
            levelText = "unknown"
        }
        let stateText: String
        switch device.batteryState {
        case .unknown:
            stateText = "unknown"
        case .unplugged:
            stateText = "unplugged"
        case .charging:
            stateText = "charging"
        case .full:
            stateText = "full"
        @unknown default:
            stateText = "unknown_default"
        }
        return "battery_level_percent=\(levelText) battery_state=\(stateText)"
    }
    #endif

    #if WIDGET_EXTENSION
    private static var hasLoggedAppGroupUnavailable = false

    #if os(watchOS)
    private static var hasEnabledBatteryMonitoring = false

    @MainActor
    private static func batteryContextOnMain() -> String {
        let device = WKInterfaceDevice.current()
        if !hasEnabledBatteryMonitoring {
            hasEnabledBatteryMonitoring = true
            device.isBatteryMonitoringEnabled = true
        }
        let levelText: String
        if device.batteryLevel >= 0 {
            levelText = String(Int((device.batteryLevel * 100).rounded()))
        } else {
            levelText = "unknown"
        }
        let stateText: String
        switch device.batteryState {
        case .unknown:
            stateText = "unknown"
        case .unplugged:
            stateText = "unplugged"
        case .charging:
            stateText = "charging"
        case .full:
            stateText = "full"
        @unknown default:
            stateText = "unknown_default"
        }
        return "battery_level_percent=\(levelText) battery_state=\(stateText)"
    }

    // Queue-confined battery cache (access/mutate only on ComplicationLogBuffer.queue).
    private static var lastBatteryContext = "battery_level_percent=unknown battery_state=unknown"
    private static var lastBatteryRefreshEpoch: TimeInterval = 0
    private static var batteryRefreshInFlight = false
    #endif
    #endif
    private static var hasLoggedFileAppendStatus = false

    #if WIDGET_EXTENSION
    /// TRIO-119: persisted per-line sequence counter. Only the complication extension appends, so only it advances it.
    private static let sequenceCounter = ComplicationLogSequenceCounter(
        defaults: appGroupSuiteName().flatMap { UserDefaults(suiteName: $0) }
    )
    #endif

    private static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    /// Appends a log line. Ring in all targets; file append only when WIDGET_EXTENSION (complication target).
    /// In the complication process we use sync so the write completes before return (process may be short-lived).
    static func append(
        _ message: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        #if WIDGET_EXTENSION
        queue.sync {
            let now = Date().timeIntervalSince1970
            #if os(watchOS)
            // C-209-5 (B6): stale-first by design (short-lived widget process must not block);
            // `battery_src=` tags the cache so analysis can tell this lagging context apart
            // from the watch app's blocking-refresh one. TTL 60s → 15s to shrink the smear.
            let contextToUse = lastBatteryContext + " battery_src=clb_widget"
            if now - lastBatteryRefreshEpoch >= 15, !batteryRefreshInFlight {
                batteryRefreshInFlight = true
                Task {
                    // Defaults ensure we never write garbage if something goes sideways before refresh completes.
                    var fresh = lastBatteryContext
                    var refreshedAt = lastBatteryRefreshEpoch

                    defer {
                        ComplicationLogBuffer.queue.async {
                            lastBatteryContext = fresh
                            lastBatteryRefreshEpoch = refreshedAt
                            batteryRefreshInFlight = false
                        }
                    }

                    fresh = await MainActor.run { ComplicationLogBuffer.batteryContextOnMain() }
                    refreshedAt = Date().timeIntervalSince1970
                }

            }
            #else
            let contextToUse = "battery_level_percent=unsupported battery_state=unsupported"
            #endif
            doAppendWithBattery(message: message, file: file, line: line, function: function, batteryContext: contextToUse)
        }
        #else
        #if os(watchOS)
        queue.async {
            // Snapshot queue-confined state once (avoids inconsistent multi-reads).
            let cachedContext = nonWidgetLastBatteryContext
            let cachedRefreshedAt = nonWidgetLastBatteryRefreshEpoch
            let refreshInFlight = nonWidgetBatteryRefreshInFlight

            // C-209-5 (B6): same stale-first cache as the widget path — tag + 15s TTL.
            doAppendRingOnly(message: "\(message) \(cachedContext) battery_src=clb_ring")

            let now = Date().timeIntervalSince1970
            if now - cachedRefreshedAt >= 15, !refreshInFlight {
                nonWidgetBatteryRefreshInFlight = true

                Task {
                    // Defaults ensure we never write garbage if something goes sideways before refresh completes.
                    var fresh = cachedContext
                    var refreshedAt = cachedRefreshedAt

                    defer {
                        ComplicationLogBuffer.queue.async {
                            nonWidgetLastBatteryContext = fresh
                            nonWidgetLastBatteryRefreshEpoch = refreshedAt
                            nonWidgetBatteryRefreshInFlight = false
                        }
                    }

                    fresh = await MainActor.run { ComplicationLogBuffer.nonWidgetBatteryContextOnMain() }
                    refreshedAt = Date().timeIntervalSince1970
                }
            }
        }
        #else
        queue.async {
            doAppendRingOnly(message: message)
        }
        #endif
        #endif
    }

    private static func doAppendRingOnly(message: String) {
        entries.append(message)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        if !hasLoggedFileAppendStatus {
            hasLoggedFileAppendStatus = true
            let bid = Bundle.main.bundleIdentifier ?? "nil"
            NSLog("[ComplicationLogBuffer] file-append disabled; bundle id=%@", bid)
        }
    }

    #if WIDGET_EXTENSION
    private static func doAppendWithBattery(message: String, file: String, line: Int, function: String, batteryContext: String) {
        entries.append(message)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        if !hasLoggedFileAppendStatus {
            hasLoggedFileAppendStatus = true
            let bid = Bundle.main.bundleIdentifier ?? "nil"
            NSLog("[ComplicationLogBuffer] file-append enabled; bundle id=%@", bid)
        }
        appendToFile(message: message, file: file, line: line, function: function, batteryContext: batteryContext)
    }
    #endif

    #if WIDGET_EXTENSION
    // MARK: - File append (complication target only; same format/path/truncation as 06)
    private static func appendToFile(message: String, file: String, line: Int, function: String, batteryContext: String) {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let seq = sequenceCounter.next()
        let entry = "[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext) seq=\(seq)\n"

        guard let logURL = logFileURL() else {
            NSLog("[ComplicationLogBuffer] %@", String(entry.dropLast()))
            if !hasLoggedAppGroupUnavailable {
                hasLoggedAppGroupUnavailable = true
                NSLog("[ComplicationLogBuffer] App Group unavailable; using NSLog fallback")
            }
            return
        }

        do {
            let fileManager = FileManager.default
            let dirURL = logURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dirURL.path) {
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            }

            guard let data = entry.data(using: .utf8) else { return }

            if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()

                if let attrs = try? fileManager.attributesOfItem(atPath: logURL.path),
                   let size = attrs[.size] as? Int64,
                   size > sizeCapBytes {
                    truncateKeepingNewest(at: logURL)
                }
            } else {
                try data.write(to: logURL)
            }
        } catch {
            NSLog("[ComplicationLogBuffer] write failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Truncation (file only; same as 06)
    private static func truncateKeepingNewest(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var keptBytes = 0
        var keptLines: [String] = []
        for line in lines.reversed() {
            let lineBytes = (line + "\n").utf8.count
            if keptBytes + lineBytes > truncateKeepBytes { break }
            keptBytes += lineBytes
            keptLines.insert(line, at: 0)
        }

        let droppedCount = lines.count - keptLines.count
        let marker = "[dropped \(droppedCount) lines]\n"
        let newContent = marker + keptLines.map { $0 + "\n" }.joined()
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - File URLs (all targets; drain in Watch App needs these)
    /// Returns the log file URL in the App Group container, or nil if unavailable.
    static func logFileURL() -> URL? {
        guard let containerURL = sharedContainerURL() else { return nil }
        return containerURL
            .appendingPathComponent(logsSubdir, isDirectory: true)
            .appendingPathComponent(logFileName, isDirectory: false)
    }

    /// Returns the shared container URL. Used by append (Complication) and drain (Watch App).
    static func sharedContainerURL() -> URL? {
        guard let suiteName = appGroupSuiteName() else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    /// The resolved App Group ID (also the defaults suite name), or nil if unavailable.
    private static func appGroupSuiteName() -> String? {
        var bundle: Bundle = .main
        let classBundle = Bundle(for: _BundleAnchor.self)
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }
        return resolveAppGroupID(bundle: bundle).value
    }

    /// TRIO-119: the `seq=` value a line ends with, or nil when it has none (old lines, `[dropped N lines]` markers).
    static func sequenceNumber(inLine line: String) -> Int? {
        guard let range = line.range(of: " seq=", options: .backwards) else { return nil }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, tail.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(tail)
    }

    // MARK: - App Group Resolution (mirrors 06; same logic for drain compatibility)
    private static func appGroupID(forTeamID teamID: String) -> String {
        "group.org.nightscout.\(teamID).trio.trio-app-group"
    }

    private static func extractTeamID(fromBundleIdentifier bid: String?) -> String? {
        guard let bid, !bid.isEmpty else { return nil }
        let prefix = "org.nightscout."
        guard let prefixRange = bid.range(of: prefix) else { return nil }
        let after = bid[prefixRange.upperBound...]
        guard let trioRange = after.range(of: ".trio") else { return nil }
        let teamID = String(after[..<trioRange.lowerBound])
        return teamID.isEmpty ? nil : teamID
    }

    private static func resolveAppGroupID(bundle: Bundle) -> (value: String?, source: String) {
        if let value = bundle.object(forInfoDictionaryKey: "AppGroupID") as? String, !value.isEmpty {
            return (value, "Info.plist(AppGroupID)")
        }
        #if os(watchOS)
        if let companionID = Bundle.main.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String,
           let teamID = extractTeamID(fromBundleIdentifier: companionID)
        {
            return (appGroupID(forTeamID: teamID), "Derived(WKCompanionAppBundleIdentifier)")
        }
        #endif
        if let teamID = extractTeamID(fromBundleIdentifier: bundle.bundleIdentifier) {
            return (appGroupID(forTeamID: teamID), "Derived(bundleIdentifier)")
        }
        return (nil, "Unavailable")
    }
}

// MARK: - TRIO-119 sequence numbers

/// Monotonic per-line counter the log writer persists across extension launches (App Group defaults, or in memory
/// when the defaults are unavailable, in which case a relaunch restarts it and the drain reports a reset).
final class ComplicationLogSequenceCounter {
    static let defaultsKey = "ComplicationLogBuffer_seq"
    private let defaults: UserDefaults?
    private let key: String
    private let lock = NSLock()
    private var inMemory = 0

    init(defaults: UserDefaults?, key: String = ComplicationLogSequenceCounter.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Persists before returning, so a relaunch continues from here.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults else {
            inMemory += 1
            return inMemory
        }
        let value = defaults.integer(forKey: key) + 1
        defaults.set(value, forKey: key)
        return value
    }
}

/// Finds gaps between consecutive `seq=` values the drain reads. Keep the last value across drains.
struct ComplicationLogGapDetector: Equatable {
    enum Event: Equatable {
        /// No earlier value to compare with.
        case first
        case contiguous
        /// Same value again (a re-read line); not a loss.
        case duplicate
        /// `missing` lines between `from` (last seen) and `to`.
        case gap(from: Int, to: Int, missing: Int)
        /// The counter went backwards (extension data cleared): not a loss of `from - to` lines.
        case reset(from: Int, to: Int)
    }

    private(set) var lastSeq: Int?

    init(lastSeq: Int? = nil) {
        self.lastSeq = lastSeq
    }

    mutating func observe(_ seq: Int) -> Event {
        defer { lastSeq = seq }
        guard let last = lastSeq else { return .first }
        if seq == last { return .duplicate }
        if seq < last { return .reset(from: last, to: seq) }
        if seq == last + 1 { return .contiguous }
        return .gap(from: last, to: seq, missing: seq - last - 1)
    }
}

// MARK: - TRIO-119 drain scheduling

/// Decides when the watch app drains the complication log outside its lifecycle drains: at most once per
/// `minInterval`, and at once when the file passes half of `sizeCapBytes` (before a truncation can drop lines).
/// Reads the file size only; never appends. The clock, size source and drain action are injectable.
final class ComplicationLogDrainScheduler {
    static let minInterval: TimeInterval = 10 * 60
    static var sizeThresholdBytes: Int { ComplicationLogBuffer.sizeCapBytes / 2 }

    enum Trigger: String, Equatable {
        case interval
        case size
    }

    private let now: () -> Date
    private let fileSize: () -> Int?
    private let drain: () -> Void
    private let lock = NSLock()
    private var lastDrainAt: Date?

    init(
        now: @escaping () -> Date = { Date() },
        fileSize: @escaping () -> Int? = ComplicationLogDrainScheduler.currentFileSize,
        drain: @escaping () -> Void
    ) {
        self.now = now
        self.fileSize = fileSize
        self.drain = drain
    }

    /// Size of the live log file in bytes; nil when there is none or the App Group is unavailable.
    static func currentFileSize() -> Int? {
        guard let url = ComplicationLogBuffer.logFileURL(),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    /// Records a drain that happened elsewhere (lifecycle drains), which restarts the interval.
    func noteDrain() {
        lock.lock()
        lastDrainAt = now()
        lock.unlock()
    }

    /// Drains when due and returns why; nil when it is not due.
    @discardableResult
    func drainIfDue() -> Trigger? {
        lock.lock()
        let current = now()
        let trigger: Trigger?
        if let size = fileSize(), size > Self.sizeThresholdBytes {
            trigger = .size
        } else if let last = lastDrainAt, current.timeIntervalSince(last) >= 0,
                  current.timeIntervalSince(last) < Self.minInterval
        {
            trigger = nil
        } else {
            trigger = .interval
        }
        if trigger != nil { lastDrainAt = current }
        lock.unlock()

        if trigger != nil { drain() }
        return trigger
    }
}

/// How a reading reached the watch; the `via=` value on the save log line.
enum ComplicationDeliveryPath: String, Equatable {
    case message
    case userInfo
    case complicationUserInfo
    case applicationContext
    case ble
    case healthkit

    /// Maps a received userInfo to its path: a `true` top-level complication marker is `.complicationUserInfo`;
    /// anything else, including a missing marker from an old phone build, is `.userInfo`.
    /// The key literal must equal `WatchMessageKeys.complicationTransfer`; Watch Shared can't see that file.
    static func forUserInfo(_ userInfo: [String: Any]) -> ComplicationDeliveryPath {
        (userInfo["complicationTransfer"] as? Bool) == true ? .complicationUserInfo : .userInfo
    }
}

/// Anchor class for Bundle(for:) lookup since the enum has no instances.
private final class _BundleAnchor { }
