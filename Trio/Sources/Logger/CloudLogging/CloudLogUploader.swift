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
        var creationDateEpoch: TimeInterval?
    }

    private let provider: CloudLogProvider
    private let pairs: [RotatingPair]
    private let userDefaults: UserDefaults
    private let stateKey = "cloudLogUploader.tailState.v1"

    private var isUploading = false

    init(
        provider: CloudLogProvider,
        pairs: [RotatingPair],
        userDefaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.pairs = pairs
        self.userDefaults = userDefaults
    }

    func uploadNow() async {
        // Coalesce to avoid overlapping uploads on lifecycle + timer.
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        for pair in pairs {
            await uploadRotatingPair(pair)
        }
    }

    // MARK: - Rotation + tail logic

    private func uploadRotatingPair(_ pair: RotatingPair) async {
        let currentURL = URL(fileURLWithPath: pair.currentPath)
        let prevURL = URL(fileURLWithPath: pair.previousPath)

        var currentState = loadState(for: pair.currentPath)
        var prevState = loadState(for: pair.previousPath)

        // Reset offsets if file shrank (rotation or truncation).
        if let currentSize = fileSize(currentURL), currentSize < currentState.offset {
            currentState.offset = 0
        }
        if let prevSize = fileSize(prevURL), prevSize < prevState.offset {
            prevState.offset = 0
        }

        // Detect rotation: if current creationDate changed, the previous file likely holds the prior content.
        let currentCreationEpoch = fileCreationEpoch(currentURL)
        if let storedEpoch = currentState.creationDateEpoch,
           let currentCreationEpoch,
           storedEpoch != currentCreationEpoch
        {
            // Map the old current offset onto the previous file so we don't re-upload already-uploaded bytes.
            // (Rotation moves current -> previous, and creates a new current file.)
            let oldCurrentOffset = currentState.offset
            if let prevSize = fileSize(prevURL), prevSize > 0 {
                prevState.offset = max(prevState.offset, min(oldCurrentOffset, prevSize))
                prevState.creationDateEpoch = fileCreationEpoch(prevURL)
                saveState(prevState, for: pair.previousPath)
            }

            // Best-effort: upload missed tail from previous file using the old offset.
            if let prevSize = fileSize(prevURL), prevSize > 0 {
                let startOffset = min(oldCurrentOffset, prevSize)
                _ = await uploadNewContent(
                    fileURL: prevURL,
                    filePathKey: pair.previousPath,
                    startOffset: startOffset,
                    platform: pair.platform,
                    parser: pair.parser
                )

                // Regardless of whether the upload succeeded, keep prevState stable.
                // Only advance on success is handled in uploadNewContent.
            }

            // Reset current state for the new day (new file).
            currentState.offset = 0
            currentState.creationDateEpoch = currentCreationEpoch
            saveState(currentState, for: pair.currentPath)
        } else {
            // Persist current creation date if we don't have it yet.
            if currentState.creationDateEpoch == nil {
                currentState.creationDateEpoch = currentCreationEpoch
                saveState(currentState, for: pair.currentPath)
            }
        }

        // Upload current tail.
        _ = await uploadNewContent(
            fileURL: currentURL,
            filePathKey: pair.currentPath,
            startOffset: loadState(for: pair.currentPath).offset,
            platform: pair.platform,
            parser: pair.parser
        )

        // Upload previous tail as well (best-effort for late rotation or missed uploads).
        _ = await uploadNewContent(
            fileURL: prevURL,
            filePathKey: pair.previousPath,
            startOffset: loadState(for: pair.previousPath).offset,
            platform: pair.platform,
            parser: pair.parser
        )
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
            saveState(TailState(offset: nextOffset, creationDateEpoch: fileCreationEpoch(fileURL)), for: filePathKey)
            return true
        }

        let commonAttributes = buildCommonAttributes(platform: platform)

        // Build events (best-effort parsing; always upload the line).
        let events: [CloudLogEvent] = lines.compactMap { line in
            let parsed = parser(line)
            var attrs = commonAttributes
            if let parsed {
                if let c = parsed.category { attrs["category"] = c }
                if let l = parsed.level { attrs["level"] = l }
                attrs["raw"] = line
                return CloudLogEvent(message: parsed.message, dt: parsed.dt, attributes: attrs)
            } else {
                attrs["raw"] = line
                return CloudLogEvent(message: line, dt: nil, attributes: attrs)
            }
        }

        switch await provider.upload(events: events) {
        case .success:
            var state = loadState(for: filePathKey)
            state.offset = nextOffset
            if state.creationDateEpoch == nil {
                state.creationDateEpoch = fileCreationEpoch(fileURL)
            }
            saveState(state, for: filePathKey)
            return true
        case .failure:
            // Critical: do NOT advance offsets.
            return false
        }
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

            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .newlines) }

            let nextOffset = startOffset + UInt64(completeData.count)
            return (lines, nextOffset)
        } catch {
            return nil
        }
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
            return TailState(offset: 0, creationDateEpoch: nil)
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

    private func fileCreationEpoch(_ url: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.creationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }
}

