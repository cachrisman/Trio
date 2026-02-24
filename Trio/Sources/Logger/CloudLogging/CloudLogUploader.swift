import Foundation

/// iPhone-only log tailer/uploader.
///
/// - Keeps file-based logs as the source of truth.
/// - Tails files using byte offsets (no buffering).
/// - Handles daily rotation where `*_log.txt` is moved to `*_log_prev.txt`.
actor CloudLogUploader {
    struct RotatingPair {
        let currentPath: String
        let previousPath: String
        let platform: CloudLogPlatform
        let parser: (String) -> CloudParsedLogLine?
    }

    private struct TailState: Codable {
        var offset: UInt64
    }

    private let provider: CloudLogProvider
    private let pairs: [RotatingPair]
    private let userDefaults: UserDefaults
    private let stateKey = "cloudLogUploader.tailState.v1"

    private var isUploading = false
    private var lastSuccessfulUploadAt: Date?
    private let successCooldown: TimeInterval = 30

    init(
        provider: CloudLogProvider,
        pairs: [RotatingPair],
        userDefaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.pairs = pairs
        self.userDefaults = userDefaults
    }

    /// Returns true if this run completed without provider failures.
    @discardableResult
    func uploadNow() async -> Bool {
        if let last = lastSuccessfulUploadAt, Date().timeIntervalSince(last) < successCooldown {
            return true
        }

        // Coalesce to avoid overlapping uploads on lifecycle + timer.
        guard !isUploading else { return true }
        isUploading = true
        defer { isUploading = false }

        var allSucceeded = true
        for pair in pairs {
            let ok = await uploadRotatingPair(pair)
            if !ok { allSucceeded = false }
        }
        if allSucceeded {
            lastSuccessfulUploadAt = Date()
        }
        return allSucceeded
    }

    // MARK: - Rotation + tail logic

    private func uploadRotatingPair(_ pair: RotatingPair) async -> Bool {
        let currentURL = URL(fileURLWithPath: pair.currentPath)
        let prevURL = URL(fileURLWithPath: pair.previousPath)

        var currentState = loadState(for: pair.currentPath)
        var prevState = loadState(for: pair.previousPath)
        var succeeded = true

        // Reset offsets if file shrank (rotation or truncation).
        if let currentSize = fileSize(currentURL), currentSize < currentState.offset {
            currentState.offset = 0
            saveState(currentState, for: pair.currentPath)
        }
        if let prevSize = fileSize(prevURL), prevSize < prevState.offset {
            prevState.offset = 0
            saveState(prevState, for: pair.previousPath)
        }

        // Upload current tail.
        let okCurrent = await uploadNewContent(
            fileURL: currentURL,
            filePathKey: pair.currentPath,
            startOffset: currentState.offset,
            platform: pair.platform,
            parser: pair.parser
        )
        if !okCurrent { succeeded = false }

        // Upload previous tail as well (best-effort for late rotation or missed uploads).
        let okPrev = await uploadNewContent(
            fileURL: prevURL,
            filePathKey: pair.previousPath,
            startOffset: prevState.offset,
            platform: pair.platform,
            parser: pair.parser
        )
        if !okPrev { succeeded = false }

        return succeeded
    }

    private func uploadNewContent(
        fileURL: URL,
        filePathKey: String,
        startOffset: UInt64,
        platform: CloudLogPlatform,
        parser: (String) -> CloudParsedLogLine?
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        guard let size = fileSize(fileURL), size > startOffset else { return true }

        guard let (lines, nextOffset) = readCompleteLines(fileURL: fileURL, startOffset: startOffset) else {
            return true
        }
        guard !lines.isEmpty else {
            saveState(TailState(offset: nextOffset), for: filePathKey)
            return true
        }

        let entries = aggregateEntries(physicalLines: lines, platform: platform)
        guard !entries.isEmpty else {
            saveState(TailState(offset: nextOffset), for: filePathKey)
            return true
        }

        let commonAttributes = buildCommonAttributes(platform: platform)

        // Build events (best-effort parsing; always upload the line).
        let events: [CloudLogEvent] = entries.compactMap { entry in
            let parsed = parser(entry)
            var attrs = commonAttributes
            if let parsed {
                if let c = parsed.category { attrs["category"] = c }
                if let l = parsed.level { attrs["level"] = l }
                if let f = parsed.file { attrs["file"] = f }
                if let m = parsed.method { attrs["method"] = m }
                if let ln = parsed.lineNumber { attrs["lineNumber"] = ln }
                if let s = parsed.source { attrs["source"] = s }
                let msg = truncateMessage(parsed.message)
                return CloudLogEvent(message: msg, dt: parsed.dt, attributes: attrs, raw: entry)
            } else {
                let msg = truncateMessage(entry)
                return CloudLogEvent(message: msg, dt: nil, attributes: attrs, raw: entry)
            }
        }

        // Upload in batches with both count and byte-budget caps.
        // This helps avoid 413 errors regardless of log verbosity.
        let batches = buildBatches(events: events)
        for batch in batches {
            switch await provider.upload(events: batch) {
            case .success:
                continue
            case .failure:
                // Critical: do NOT advance offsets.
                debug(.service, "CloudLogUploader: upload failed for \(filePathKey), offset not advanced")
                return false
            }
        }

        // Only advance the file offset after the final batch succeeds.
        var state = loadState(for: filePathKey)
        state.offset = nextOffset
        saveState(state, for: filePathKey)
        return true
    }

    /// Reads from startOffset to EOF and returns only complete lines (ending with '\n').
    /// The returned `nextOffset` is the byte offset right after the last complete newline.
    private func readCompleteLines(fileURL: URL, startOffset: UInt64) -> ([String], UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return ([], startOffset) }

            // Only advance to the last newline to avoid uploading a partial final line.
            guard let lastNewlineIdx = data.lastIndex(of: 0x0A) else {
                return ([], startOffset)
            }

            let completeData = data.prefix(upTo: data.index(after: lastNewlineIdx))
            let text = String(decoding: completeData, as: UTF8.self)

            var lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // Because `text` ends with '\n', split(...) includes a final empty element; drop it.
            if lines.last == "" {
                lines.removeLast()
            }

            let nextOffset = startOffset + UInt64(completeData.count)
            return (lines, nextOffset)
        } catch {
            return nil
        }
    }

    private func aggregateEntries(physicalLines: [String], platform: CloudLogPlatform) -> [String] {
        let pattern: String
        switch platform {
        case .ios:
            pattern = #"^\d{4}-\d{2}-\d{2}T"#
        case .watchos:
            pattern = #"^\[\d{4}-\d{2}-\d{2}T"#
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Fallback to line-by-line if regex compilation fails (shouldn't happen).
            return physicalLines
        }

        return CloudLogEntryAggregator.aggregate(lines: physicalLines, startPattern: regex)
    }

    // MARK: - Attributes

    private func buildCommonAttributes(platform: CloudLogPlatform) -> [String: String] {
        var attrs: [String: String] = [:]
        attrs["platform"] = platform.rawValue

        let env: String
        if BuildDetails.shared.isTestFlightBuild() {
            env = "testflight"
        } else {
            #if DEBUG
                env = "debug"
            #else
                env = "release"
            #endif
        }
        attrs["env"] = env

        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            attrs["appVersion"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            attrs["build"] = build
        }

        return attrs
    }

    // MARK: - State store

    private func loadState(for path: String) -> TailState {
        guard let data = userDefaults.data(forKey: stateKey),
              let dict = try? JSONDecoder().decode([String: TailState].self, from: data),
              let state = dict[path]
        else {
            return TailState(offset: 0)
        }
        return state
    }

    private func saveState(_ state: TailState, for path: String) {
        var dict: [String: TailState] = [:]
        if let data = userDefaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode([String: TailState].self, from: data)
        {
            dict = decoded
        }
        dict[path] = state
        if let encoded = try? JSONEncoder().encode(dict) {
            userDefaults.set(encoded, forKey: stateKey)
        }
    }

    // MARK: - File helpers

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    // MARK: - Request sizing helpers

    private let maxMessageBytes = 256 * 1024
    private let maxRequestBytes = 8 * 1024 * 1024
    private let maxEventsPerRequest = 250

    private func truncateMessage(_ message: String) -> String {
        guard message.utf8.count > maxMessageBytes else { return message }
        let data = message.data(using: .utf8) ?? Data()
        return truncateUTF8(data: data, maxBytes: maxMessageBytes)
    }

    private func buildBatches(events: [CloudLogEvent]) -> [[CloudLogEvent]] {
        guard !events.isEmpty else { return [] }

        var result: [[CloudLogEvent]] = []
        var current: [CloudLogEvent] = []
        var currentBytes = 2 // "[]"
        let encoder = JSONEncoder()

        for event in events {
            let eventBytes = (try? encoder.encode(event).count) ?? Int.max
            let additionalBytes = current.isEmpty ? eventBytes : (1 + eventBytes) // comma for non-first

            let wouldExceedCount = current.count >= maxEventsPerRequest
            let wouldExceedBytes = (currentBytes + additionalBytes) > maxRequestBytes

            if wouldExceedCount || wouldExceedBytes {
                if !current.isEmpty {
                    result.append(current)
                }
                current = [event]
                currentBytes = 2 + eventBytes

                // If a single event still exceeds the request budget (should be rare due to truncation),
                // upload it alone to avoid an infinite loop.
                if currentBytes > maxRequestBytes {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                    currentBytes = 2
                }
            } else {
                current.append(event)
                currentBytes += additionalBytes
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    /// Truncate UTF-8 data without emitting replacement characters.
    private func truncateUTF8(data: Data, maxBytes: Int) -> String {
        guard data.count > maxBytes else {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }

        var truncated = data.prefix(maxBytes)

        // If we're mid-codepoint, drop trailing bytes until valid UTF-8.
        // Worst-case UTF-8 sequence length is 4, so this loop should be short,
        // but we keep it safe for malformed input.
        while !truncated.isEmpty {
            if let s = String(data: truncated, encoding: .utf8) {
                return s
            }
            truncated = truncated.dropLast(1)
        }

        return ""
    }
}
