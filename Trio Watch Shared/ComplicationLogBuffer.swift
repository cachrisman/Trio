import Foundation

/// Append-only log buffer for the Complication Extension, written to App Group storage.
/// The Watch App drains this file and sends raw lines via watchLogs envelope.
/// Format matches WatchLogger: `[timestamp] [File.swift:line] function → message`
/// ComplicationLogBuffer is used as the file/category so the parser can tag source=complication.
enum ComplicationLogBuffer {
    private static let logFileName = "complication_log.txt"
    private static let logsSubdir = "logs"
    private static let sizeCapBytes = 64 * 1024
    private static let truncateKeepBytes = 32 * 1024

    private static let queue = DispatchQueue(label: "ComplicationLogBuffer.queue")
    private static var hasLoggedAppGroupUnavailable = false

    private static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    /// Appends a formatted log line to the App Group buffer.
    /// Falls back to NSLog if App Group is unavailable (throttled warning).
    static func append(
        _ message: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        queue.async {
            let shortFile = (file as NSString).lastPathComponent
            let timestamp = dateFormatter.string(from: Date())
            let entry = "[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message)\n"

            guard let logURL = logFileURL() else {
                NSLog("[ComplicationLogBuffer] %@", String(entry.dropLast()))
                if !hasLoggedAppGroupUnavailable {
                    hasLoggedAppGroupUnavailable = true
                    NSLog("[ComplicationLogBuffer] App Group unavailable; using NSLog fallback")
                }
                return
            }

            do {
                let fm = FileManager.default
                let dirURL = logURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: dirURL.path) {
                    try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }

                guard let data = entry.data(using: .utf8) else { return }

                if fm.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()

                    if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
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
    }

    // MARK: - Truncation

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

    // MARK: - File URLs (also used by drain logic in Watch App)

    /// Returns the log file URL in the App Group container, or nil if unavailable.
    static func logFileURL() -> URL? {
        guard let containerURL = sharedContainerURL() else { return nil }
        return containerURL
            .appendingPathComponent(logsSubdir, isDirectory: true)
            .appendingPathComponent(logFileName, isDirectory: false)
    }

    /// Returns the shared container URL. Used by both append (Complication) and drain (Watch App).
    static func sharedContainerURL() -> URL? {
        var bundle: Bundle = .main
        let classBundle = Bundle(for: _BundleAnchor.self)
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }

        guard let suiteName = resolveAppGroupID(bundle: bundle).value else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    // MARK: - App Group Resolution (mirrors TrioComplicationDataStore)

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
