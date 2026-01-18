import Foundation

enum CloudLogPlatform: String {
    case ios
    case watchos
}

struct CloudParsedLogLine {
    let dt: String?
    let category: String?
    let level: String?
    let message: String
    let file: String?
    let method: String?
    let lineNumber: String?
}

enum CloudLogLineParser {
    // iPhone format:
    // <TIMESTAMP> [CATEGORY] <File.swift> - <function> - <line> - <LEVEL>: <message>
    static func parseIOS(_ entry: String) -> CloudParsedLogLine? {
        let trimmedEntry = entry.trimmingCharacters(in: .newlines)
        guard !trimmedEntry.isEmpty else { return nil }

        let lines = trimmedEntry.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = lines.first ?? trimmedEntry
        let continuation = lines.dropFirst().joined(separator: "\n")

        // Timestamp = first token
        let tokens = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let rawTs = tokens.first.map(String.init)
        let dt = rawTs.flatMap(normalizeTimestamp)

        // Category = first [...] after timestamp
        var category: String?
        if let range = header.range(of: #"^\S+\s+\[([^\]]+)\]"#, options: [.regularExpression]) {
            // Extract using a second regex capture to keep code simple.
            if let match = header[range].range(of: #"\[([^\]]+)\]"#, options: .regularExpression) {
                let bracketed = String(header[match])
                category = bracketed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            }
        }

        // Extract file, method, and line number
        // Format: [CATEGORY] <File.swift> - <function> - <line> - <LEVEL>:
        // Example: [Nightscout] NightscoutManager.swift - uploadNonCoreDataTreatments(_:) - 999 - DEV:
        var file: String?
        var method: String?
        var lineNumber: String?

        // Pattern: \] (.+\.swift) - (.+?) - (\d+) - (<LEVEL>):
        // Method name can contain special chars like (_:), so we match everything between the delimiters.
        // Level can vary depending on logger implementation ("DEV", "DEBUG", "WARN", "WARNING", ...),
        // so keep it permissive to avoid losing file/method/line parsing.
        let fileMethodLineRegex = #"\]\s+([^\s]+\.swift)\s+-\s+(.+?)\s+-\s+(\d+)\s+-\s+([A-Z]+):"#
        if let regex = try? NSRegularExpression(pattern: fileMethodLineRegex) {
            let nsHeader = header as NSString
            let range = NSRange(location: 0, length: nsHeader.length)
            if let regexMatch = regex.firstMatch(in: header, range: range), regexMatch.numberOfRanges >= 5 {
                // Group 1: file, Group 2: method, Group 3: line number
                let fileRange = regexMatch.range(at: 1)
                let methodRange = regexMatch.range(at: 2)
                let lineRange = regexMatch.range(at: 3)

                if fileRange.location != NSNotFound {
                    file = nsHeader.substring(with: fileRange)
                }
                if methodRange.location != NSNotFound {
                    method = nsHeader.substring(with: methodRange)
                }
                if lineRange.location != NSNotFound {
                    lineNumber = nsHeader.substring(with: lineRange)
                }
            }
        }

        // Level = delimiter-aware: " - (DEV|INFO|WARN|ERR):"
        let levelRegex = #"\s-\s([A-Z]+):\s"#
        guard let levelMatch = header.range(of: levelRegex, options: .regularExpression) else {
            // If we can't confidently parse, still return the original line as message.
            let msg = continuation.isEmpty ? header : "\(header)\n\(continuation)"
            return CloudParsedLogLine(dt: dt, category: category, level: nil, message: msg, file: file, method: method, lineNumber: lineNumber)
        }

        // Extract the actual level token and normalize
        let levelToken = String(header[levelMatch])
            .replacingOccurrences(of: " - ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedLevel: String?
        switch levelToken {
        case "DEV", "DEBUG": normalizedLevel = "debug"
        case "INFO": normalizedLevel = "info"
        case "WARN", "WARNING": normalizedLevel = "warn"
        case "ERR", "ERROR": normalizedLevel = "error"
        default: normalizedLevel = nil
        }

        // Message = everything after "<LEVEL>: "
        let messageStart = header.index(levelMatch.upperBound, offsetBy: 0)
        let parsedFirstLineMessage = String(header[messageStart...]).trimmingCharacters(in: .newlines)
        let firstLineMessage = parsedFirstLineMessage.isEmpty ? header : parsedFirstLineMessage
        let fullMessage = continuation.isEmpty ? firstLineMessage : "\(firstLineMessage)\n\(continuation)"

        // Apply message-based level detection to upgrade levels when appropriate
        let finalLevel = detectLevelFromMessage(fullMessage, originalLevel: normalizedLevel)

        return CloudParsedLogLine(
            dt: dt,
            category: category,
            level: finalLevel,
            message: fullMessage,
            file: file,
            method: method,
            lineNumber: lineNumber
        )
    }

    // Watch format:
    // [<TIMESTAMP>] [<File.swift>:<line>] <function>() → <message>
    static func parseWatch(_ entry: String) -> CloudParsedLogLine? {
        let trimmedEntry = entry.trimmingCharacters(in: .newlines)
        guard !trimmedEntry.isEmpty else { return nil }

        let lines = trimmedEntry.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = lines.first ?? trimmedEntry
        let continuation = lines.dropFirst().joined(separator: "\n")

        // Timestamp = first [...] token
        var dt: String?
        if let tsRange = header.range(of: #"^\[([^\]]+)\]"#, options: [.regularExpression]) {
            let bracketed = String(header[tsRange])
            let raw = bracketed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            dt = normalizeTimestamp(raw)
        }

        // Category = filename from "[File.swift:line]" (without .swift extension)
        var category: String?
        category = extractWatchCategory(from: header)

        // Extract file, line number, and function name
        // Format: [TIMESTAMP] [File.swift:line] function() → message
        var file: String?
        var lineNumber: String?
        var method: String?

        // Extract file + line independent of method parsing, since watch log methods can be:
        // - finalizePendingData()            (trailing "()")
        // - scheduleUIUpdate(with:)         (no trailing "()", includes signature)
        // - session(_:didReceiveUserInfo:)  (no trailing "()", includes signature)
        let fileLineRegex = #"\[[^\]]+\]\s+\[([^\]:]+\.swift):(\d+)\]"#
        if let regex = try? NSRegularExpression(pattern: fileLineRegex) {
            let nsHeader = header as NSString
            let range = NSRange(location: 0, length: nsHeader.length)
            if let regexMatch = regex.firstMatch(in: header, range: range), regexMatch.numberOfRanges >= 3 {
                let fileRange = regexMatch.range(at: 1)
                let lineRange = regexMatch.range(at: 2)
                if fileRange.location != NSNotFound {
                    file = nsHeader.substring(with: fileRange)
                }
                if lineRange.location != NSNotFound {
                    lineNumber = nsHeader.substring(with: lineRange)
                }
            }
        }

        let arrowRange = header.range(of: "→") ?? header.range(of: "->")
        if let arrowRange {
            // Method = substring between the second closing bracket and the arrow
            if let firstClose = header.firstIndex(of: "]") {
                let afterFirst = header.index(after: firstClose)
                if let secondClose = header[afterFirst...].firstIndex(of: "]") {
                    var start = header.index(after: secondClose)
                    while start < header.endIndex, header[start].isWhitespace {
                        start = header.index(after: start)
                    }
                    let candidate = String(header[start..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        method = candidate.hasSuffix("()") ? String(candidate.dropLast(2)) : candidate
                    }
                }
            }
        }

        // Message = everything after the arrow
        let fullMessage: String
        if let arrowRange {
            let msg = header[arrowRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLineMessage = msg.isEmpty ? header : String(msg)
            fullMessage = continuation.isEmpty ? firstLineMessage : "\(firstLineMessage)\n\(continuation)"
        } else {
            fullMessage = continuation.isEmpty ? header : "\(header)\n\(continuation)"
        }

        // Apply message-based level detection to upgrade levels when appropriate
        let finalLevel = detectLevelFromMessage(fullMessage, originalLevel: nil)

        return CloudParsedLogLine(dt: dt, category: category, level: finalLevel, message: fullMessage, file: file, method: method, lineNumber: lineNumber)
    }

    /// Normalizes "yyyy-MM-dd'T'HH:mm:ssZ" like "...+0100" into "...+01:00" if possible.
    /// Returns nil if normalization is not possible.
    static func normalizeTimestamp(_ raw: String) -> String? {
        // Only normalize if it ends with "+HHMM" or "-HHMM"
        let tzRegex = #"([+-]\d{2})(\d{2})$"#
        guard let tzRange = raw.range(of: tzRegex, options: .regularExpression) else {
            return nil
        }

        let tz = raw[tzRange]
        let tzStr = String(tz)
        guard tzStr.count == 5 else { return nil }

        let hh = tzStr.prefix(3) // +01
        let mm = tzStr.suffix(2) // 00
        let normalized = raw.replacingCharacters(in: tzRange, with: "\(hh):\(mm)")
        return normalized
    }

    private static func extractWatchCategory(from line: String) -> String? {
        let pattern = #"^\[[^\]]+\]\s+\[([^\]:]+)\.swift:\d+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 2 else { return nil }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else { return nil }
        return nsLine.substring(with: capture)
    }

    /// Detects log level from message content, upgrading the level when error/warning patterns are detected.
    /// This helps classify logs that were incorrectly logged with `debug()` but contain error/warning indicators.
    ///
    /// - Parameters:
    ///   - message: The log message to analyze
    ///   - originalLevel: The level parsed from the log prefix (e.g., "debug", "info", "warn", "error")
    /// - Returns: The detected level, or the original level if no patterns match
    private static func detectLevelFromMessage(_ message: String, originalLevel: String?) -> String? {
        let lowercased = message.lowercased()

        // Error patterns (critical failures) - check first
        if lowercased.contains("failed to retrieve file") ||
           lowercased.contains("error domain=diskerrordomain") ||
           lowercased.contains("could not find an existing file") ||
           lowercased.contains("unable to") && (lowercased.contains("file") || lowercased.contains("disk")) {
            return "error"
        }

        // Warning patterns (issues needing attention, not critical)
        if message.contains("❌ Error sending watch state") ||
           lowercased.contains("error domain=wcerrordomain") ||
           lowercased.contains("warning:") {
            return "warn"
        }

        // Info patterns (informational, expected conditions)
        if lowercased.contains("error domain=cberrordomain") ||
           lowercased.contains("pod disconnected") ||
           lowercased.contains("sensor disconnected") ||
           lowercased.contains("skipping") ||
           lowercased.contains("device message:") ||
           lowercased.contains("device manager for") ||
           lowercased.contains("not reachable") ||
           lowercased.contains("failed to send") {
            return "info"
        }

        // If no pattern matches, return the original level
        return originalLevel
    }
}
