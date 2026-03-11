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
enum ComplicationLogBuffer {
    // MARK: - Ring buffer (all targets)

    private static let maxEntries = 200
    private static var entries: [String] = []

    // MARK: - File (06 contract: same path, format, truncation)

    private static let logFileName = "complication_log.txt"
    private static let logsSubdir = "logs"
    private static let sizeCapBytes = 64 * 1024
    private static let truncateKeepBytes = 32 * 1024

    /// Single queue for ring + file within process. Drain uses atomic rename-then-read; best-effort delivery, rare corruption possible when truncation races with drain.
    private static let queue = DispatchQueue(label: "ComplicationLogBuffer.queue")

    #if WIDGET_EXTENSION
    private static var hasLoggedAppGroupUnavailable = false
    #endif
    private static var hasLoggedFileAppendStatus = false

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
        func doAppend() {
            // Ring buffer (all targets)
            entries.append(message)
            if entries.count > maxEntries {
                entries = Array(entries.suffix(maxEntries))
            }

            // One-time runtime log so misconfig (WIDGET_EXTENSION on wrong target) is visible
            if !hasLoggedFileAppendStatus {
                hasLoggedFileAppendStatus = true
                let bid = Bundle.main.bundleIdentifier ?? "nil"
                #if WIDGET_EXTENSION
                NSLog("[ComplicationLogBuffer] file-append enabled; bundle id=%@", bid)
                #else
                NSLog("[ComplicationLogBuffer] file-append disabled; bundle id=%@", bid)
                #endif
            }

            #if WIDGET_EXTENSION
            appendToFile(message: message, file: file, line: line, function: function)
            #endif
        }

        #if WIDGET_EXTENSION
        // Sync so file write completes before return; complication process can be killed soon after.
        queue.sync(execute: doAppend)
        #else
        queue.async(execute: doAppend)
        #endif
    }

    #if WIDGET_EXTENSION
    // MARK: - File append (complication target only; same format/path/truncation as 06)

    private static func batteryLogContext() -> String {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true

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
        #else
        return "battery_level_percent=unsupported battery_state=unsupported"
        #endif
    }

    private static func appendToFile(message: String, file: String, line: Int, function: String) {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let batteryContext = batteryLogContext()
        let entry = "[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)\n"

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
                   size > sizeCapBytes
                {
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
        var bundle: Bundle = .main
        let classBundle = Bundle(for: _BundleAnchor.self)
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }

        guard let suiteName = resolveAppGroupID(bundle: bundle).value else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
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

/// Anchor class for Bundle(for:) lookup since the enum has no instances.
private final class _BundleAnchor {}
