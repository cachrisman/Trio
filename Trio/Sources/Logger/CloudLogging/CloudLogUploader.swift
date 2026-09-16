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

    /// A file larger than this with no stored offset is assumed to be pre-existing history rather
    /// than new content, and is seeded to end-of-file instead of being queued for full re-upload.
    private let seedToEndOfFileThreshold: UInt64 = 1024 * 1024

    private var isUploading = false

    // MARK: - Better Stack ingestion filter (reduce volume; local logs unchanged)

    private var ingestionThrottleLastSent: [String: Date] = [:]
    private let ingestionThrottleInterval: TimeInterval = 60
    private let ingestionStorageErrorMaxChars = 300
    private let ingestionAutosensShortMaxChars = 15

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
        guard !isUploading else { return true }
        isUploading = true
        defer { isUploading = false }

        var allSucceeded = true
        for pair in pairs {
            let ok = await uploadRotatingPair(pair)
            if !ok { allSucceeded = false }
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

        // Seed to end-of-file for a large file we have no stored offset for. An app update can
        // migrate the data container, and although the offsets are now keyed by filename rather
        // than absolute path, a fresh install — or the first run after this change ships — still
        // arrives with no state. Starting such a file at 0 would queue its entire accumulated
        // history for re-upload, which over a poor link never completes. Files at or below the
        // threshold are small enough to upload in full, so they still start at 0.
        if loadStateIfPresent(for: pair.currentPath) == nil,
           let size = fileSize(currentURL), size > seedToEndOfFileThreshold
        {
            currentState.offset = size
            saveState(currentState, for: pair.currentPath)
        }
        if loadStateIfPresent(for: pair.previousPath) == nil,
           let size = fileSize(prevURL), size > seedToEndOfFileThreshold
        {
            prevState.offset = size
            saveState(prevState, for: pair.previousPath)
        }

        // Reset offsets if file shrank (rotation or truncation).
        if let currentSize = fileSize(currentURL), currentSize < currentState.offset {
            let offsetBeforeReset = currentState.offset
            currentState.offset = 0
            saveState(currentState, for: pair.currentPath)

            // Daily rotation moves `current` → `previous`; those bytes were already tailed under
            // `currentPath`. Seed `previousPath` offset so we do not re-upload the same range.
            if let prevSize = fileSize(prevURL) {
                prevState.offset = min(offsetBeforeReset, prevSize)
                saveState(prevState, for: pair.previousPath)
            }
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
                if let b = parsed.build { attrs["build"] = b }
                let msg = truncateMessage(parsed.message)
                return CloudLogEvent(message: msg, dt: parsed.dt, attributes: attrs, raw: entry)
            } else {
                let msg = truncateMessage(entry)
                return CloudLogEvent(message: msg, dt: nil, attributes: attrs, raw: entry)
            }
        }

        // Apply ingestion filter: drop/throttle/trim for Better Stack volume reduction (local logs unchanged).
        let eventsToUpload = applyIngestionFilter(events, now: Date())

        // Upload in batches with both count and byte-budget caps.
        // This helps avoid 413 errors regardless of log verbosity.
        let batches = buildBatches(events: eventsToUpload)
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

    /// Maximum number of bytes consumed per invocation of `readCompleteLines`.
    /// Bounding the read prevents a single pass from attempting to process an
    /// unbounded backlog, which would make one upload failure discard all progress.
    private let maxReadBytesPerPass = 512 * 1024

    /// Reads up to `maxReadBytesPerPass` bytes from startOffset and returns only complete
    /// lines (ending with '\n'). The returned `nextOffset` is the byte offset right after
    /// the last complete newline within the consumed slice.
    private func readCompleteLines(fileURL: URL, startOffset: UInt64) -> ([String], UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.read(upToCount: maxReadBytesPerPass) ?? Data()
            guard !data.isEmpty else { return ([], startOffset) }

            // Only advance to the last newline to avoid uploading a partial final line.
            guard let lastNewlineIdx = data.lastIndex(of: 0x0A) else {
                // No newline anywhere in the window. Two very different cases:
                //  - a short read: a partial final line is still being written, so wait for it.
                //  - a full window: this single line is longer than the read budget. Returning
                //    `startOffset` here would re-read the same bytes forever and never advance,
                //    reintroducing the permanent stall this bounded read exists to prevent.
                //    Skip the window instead. The skipped bytes are dropped for good; when a
                //    newline is finally reached only the trailing fragment of the entry surfaces
                //    (without its beginning), accepted as the price of guaranteed forward progress.
                guard data.count == maxReadBytesPerPass else { return ([], startOffset) }
                debug(
                    .service,
                    "CloudLogUploader: no newline in \(data.count)B window at offset \(startOffset), skipping over-long line"
                )
                return ([], startOffset + UInt64(data.count))
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

            // Cap the number of physical lines so the pass produces at most one upload batch.
            // Aggregation only merges physical lines into fewer logical entries, never more, so
            // capping physical lines guarantees at most one batch.
            if lines.count > maxEventsPerRequest {
                let kept = Array(lines.prefix(maxEventsPerRequest))
                // Each physical line contributes its UTF-8 byte count plus one byte for the
                // terminating newline (0x0A). The sum gives the exact consumed prefix length
                // for the kept lines only.
                let keptByteCount = kept.reduce(0) { $0 + $1.utf8.count + 1 }
                let nextOffset = startOffset + UInt64(keptByteCount)
                return (kept, nextOffset)
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

    // MARK: - Ingestion filter (Better Stack volume reduction)

    /// Drops or trims events before upload. Local log files are unchanged.
    private func applyIngestionFilter(_ events: [CloudLogEvent], now: Date) -> [CloudLogEvent] {
        var result: [CloudLogEvent] = []
        for event in events {
            // Rule 2: Drop all PersistedProperty "Saved value successfully".
            if event.message.contains("[PersistedProperty:") && event.message.contains("Saved value successfully.") {
                continue
            }

            // Rule 1: Throttle OpenAPS Dynamic ISF prediction lines (1 per 60s per subtype).
            if event.message.contains("Dynamic ISF (Logarithmic Formula)") {
                let key: String?
                if event.message.contains("adjusted predictions for IOB and ZT") { key = "openaps:IOB_ZT" }
                else if event.message.contains("adjusted prediction for UAM") { key = "openaps:UAM" }
                else { key = nil }
                if let key = key {
                    if let last = ingestionThrottleLastSent[key], now.timeIntervalSince(last) < ingestionThrottleInterval {
                        continue
                    }
                    ingestionThrottleLastSent[key] = now
                }
            }

            // Rule 5: Throttle short autosens.js lines (e.g. "autosens.js: 2g").
            if let autosensRange = event.message.range(of: "autosens.js:") {
                let rest = event.message[autosensRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.count <= ingestionAutosensShortMaxChars {
                    let key = "autosens:short"
                    if let last = ingestionThrottleLastSent[key], now.timeIntervalSince(last) < ingestionThrottleInterval {
                        continue
                    }
                    ingestionThrottleLastSent[key] = now
                }
            }

            // Rule 3: Trim "Watch received data" — drop from "glucoseValues = (" onward in message and raw.
            var message = event.message
            var raw = event.raw
            if message.contains("Watch received data") {
                message = trimWatchReceivedDataMessage(message)
                if let r = raw, r.contains("Watch received data") {
                    raw = trimWatchReceivedDataMessage(r)
                }
            }

            // Rule 4: Trim long storage/error messages (e.g. "Failed to retrieve file").
            if message.contains("Failed to retrieve file") && message.count > ingestionStorageErrorMaxChars {
                message = String(message.prefix(ingestionStorageErrorMaxChars)) + "…"
                raw = nil
            }

            if message != event.message || raw != event.raw {
                result.append(CloudLogEvent(message: message, dt: event.dt, attributes: event.attributes, raw: raw))
            } else {
                result.append(event)
            }
        }
        return result
    }

    /// Keeps content before `glucoseValues = (` (or `glucoseValues =     (` etc.); drops the rest to reduce Better Stack payload size.
    private func trimWatchReceivedDataMessage(_ text: String) -> String {
        // Match "glucoseValues =" followed by optional whitespace and "(" (watch state uses variable spacing).
        guard let keyRange = text.range(of: "glucoseValues =") else { return text }
        let afterKey = text[keyRange.upperBound...]
        guard afterKey.firstIndex(where: { $0 == "(" }) != nil else { return text }
        return String(text[..<keyRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - State store

    /// Reduces a file path to a stable identifier (its last path component) so that tail offsets
    /// survive iOS data-container migrations, which change the absolute path but not the filename.
    /// Named distinctly from the `stateKey` UserDefaults constant above to keep the two readable.
    private func tailStateKey(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func loadState(for path: String) -> TailState {
        loadStateIfPresent(for: path) ?? TailState(offset: 0)
    }

    /// Returns the stored `TailState` for the given path, or `nil` if none has been persisted.
    /// The `nil` case is distinct from a stored offset of 0 and is what lets a first run after a
    /// container migration seed to end-of-file rather than re-uploading the whole history.
    private func loadStateIfPresent(for path: String) -> TailState? {
        guard let data = userDefaults.data(forKey: stateKey),
              let dict = try? JSONDecoder().decode([String: TailState].self, from: data),
              let state = dict[tailStateKey(for: path)]
        else {
            return nil
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
        dict[tailStateKey(for: path)] = state
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
