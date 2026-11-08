import Foundation

/// Drains the complication log files from the App Group container into the upstream `WatchLogger`.
///
/// This replaces the drain that lived in the pre-upstream `WatchLogger`. The complication process
/// remains the only writer of `complication_log.txt`; this class only renames, reads and deletes.
final class ComplicationLogForwarder: @unchecked Sendable {
    static let shared = ComplicationLogForwarder()

    private static let drainPrefix = "complication_log.drain."
    private static let drainSuffix = ".txt"
    private static let maxFileAge: TimeInterval = 48 * 3600
    private static let maxDrainFiles = 10
    private static let tailLimit = 64 * 1024

    /// Serial queue that confines all mutable state and file work.
    private let queue = DispatchQueue(label: "com.trio.watch.complication-log-forwarder", qos: .utility)
    private var drainQueued = false

    private init() {}

    /// Returns immediately; the work runs on the private queue.
    /// Calls arriving while a drain is already queued are coalesced.
    func drain() {
        queue.async { [self] in
            guard !drainQueued else { return }
            drainQueued = true
            queue.async { [self] in
                drainQueued = false
                performDrain()
            }
        }
    }

    // MARK: - Work (runs on `queue`)

    private func performDrain() {
        guard let containerURL = ComplicationLogBuffer.sharedContainerURL() else { return }
        let logsDir = containerURL.appendingPathComponent("logs", isDirectory: true)
        let fileManager = FileManager.default

        var filesDeleted = 0
        var retentionDeleted = 0
        var filesForwarded = 0
        var linesForwarded = 0

        if let allFiles = try? fileManager.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.creationDateKey]
        ) {
            var drainFiles = allFiles
                .filter {
                    $0.lastPathComponent.hasPrefix(Self.drainPrefix)
                        && $0.lastPathComponent.hasSuffix(Self.drainSuffix)
                }
                .map { (url: $0, created: Self.creationDate(of: $0)) }
                .sorted { $0.created < $1.created }

            // Retention: drop files older than 48 hours, then keep only the newest 10.
            let now = Date()
            var survivors: [(url: URL, created: Date)] = []
            for entry in drainFiles {
                if now.timeIntervalSince(entry.created) > Self.maxFileAge {
                    if remove(entry.url) { retentionDeleted += 1 }
                } else {
                    survivors.append(entry)
                }
            }
            if survivors.count > Self.maxDrainFiles {
                let excess = survivors.count - Self.maxDrainFiles
                for entry in survivors.prefix(excess) where remove(entry.url) {
                    retentionDeleted += 1
                }
                survivors = Array(survivors.suffix(Self.maxDrainFiles))
            }
            drainFiles = survivors

            for entry in drainFiles {
                if let lines = forward(fileAt: entry.url) {
                    linesForwarded += lines
                    filesForwarded += 1
                    if remove(entry.url) { filesDeleted += 1 }
                }
            }
        }

        let logFile = logsDir.appendingPathComponent("complication_log.txt")
        if fileManager.fileExists(atPath: logFile.path) {
            let drainURL = logsDir.appendingPathComponent(
                "\(Self.drainPrefix)\(UUID().uuidString)\(Self.drainSuffix)"
            )
            do {
                try fileManager.moveItem(at: logFile, to: drainURL)
                if let lines = forward(fileAt: drainURL) {
                    linesForwarded += lines
                    filesForwarded += 1
                    if remove(drainURL) { filesDeleted += 1 }
                }
            } catch {
                WatchLogger.shared.warning(
                    .data,
                    "event=complication_log_drain_move_failed error=\(error.localizedDescription)"
                )
            }
        }

        if filesForwarded > 0 || filesDeleted > 0 || retentionDeleted > 0 {
            WatchLogger.shared.info(
                .data,
                "event=complication_log_drain files=\(filesForwarded) lines=\(linesForwarded)"
                    + " retention_deleted=\(retentionDeleted)"
            )
        }
    }

    /// Forwards the tail (at most 64 KB) of a file line by line. Returns the number of lines
    /// forwarded, or nil when the file could not be read (so the caller keeps it).
    private func forward(fileAt url: URL) -> Int? {
        let data: Data
        var tailed = false
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let limit = UInt64(Self.tailLimit)
            if size > limit {
                try handle.seek(toOffset: size - limit)
                tailed = true
            } else {
                try handle.seek(toOffset: 0)
            }
            data = try handle.readToEnd() ?? Data()
        } catch {
            WatchLogger.shared.warning(
                .data,
                "event=complication_log_read_failed file=\(url.lastPathComponent) error=\(error.localizedDescription)"
            )
            return nil
        }

        var text = String(decoding: data, as: UTF8.self)
        if tailed, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            WatchLogger.shared.info(.data, "src=complication \(trimmed)")
            count += 1
        }
        return count
    }

    private func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            WatchLogger.shared.warning(
                .data,
                "event=complication_log_delete_failed file=\(url.lastPathComponent) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private static func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
