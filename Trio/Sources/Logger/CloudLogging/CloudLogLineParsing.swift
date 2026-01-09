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

        // Level = delimiter-aware: " - (DEV|INFO|WARN|ERR):"
        let levelRegex = #"\s-\s(DEV|INFO|WARN|ERR):\s"#
        guard let levelMatch = header.range(of: levelRegex, options: .regularExpression) else {
            // If we can't confidently parse, still return the original line as message.
            let msg = continuation.isEmpty ? header : "\(header)\n\(continuation)"
            return CloudParsedLogLine(dt: dt, category: category, level: nil, message: msg)
        }

        // Extract the actual level token and normalize
        let levelToken = String(header[levelMatch])
            .replacingOccurrences(of: " - ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedLevel: String?
        switch levelToken {
        case "DEV": normalizedLevel = "debug"
        case "INFO": normalizedLevel = "info"
        case "WARN": normalizedLevel = "warn"
        case "ERR": normalizedLevel = "error"
        default: normalizedLevel = nil
        }

        // Message = everything after "<LEVEL>: "
        let messageStart = header.index(levelMatch.upperBound, offsetBy: 0)
        let parsedFirstLineMessage = String(header[messageStart...]).trimmingCharacters(in: .newlines)
        let firstLineMessage = parsedFirstLineMessage.isEmpty ? header : parsedFirstLineMessage
        let fullMessage = continuation.isEmpty ? firstLineMessage : "\(firstLineMessage)\n\(continuation)"

        return CloudParsedLogLine(
            dt: dt,
            category: category,
            level: normalizedLevel,
            message: fullMessage
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

        // Category = filename from "[File.swift:line]"
        // Regex: ^\[[^\]]+\]\s+\[([^\]:]+)\.swift:\d+\]
        var category: String?
        category = extractWatchCategory(from: header)

        // Message = everything after the arrow
        if let arrowRange = header.range(of: "→") {
            let msg = header[arrowRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLineMessage = msg.isEmpty ? header : String(msg)
            let fullMessage = continuation.isEmpty ? firstLineMessage : "\(firstLineMessage)\n\(continuation)"
            return CloudParsedLogLine(dt: dt, category: category, level: nil, message: fullMessage)
        }

        let fallbackMessage = continuation.isEmpty ? header : "\(header)\n\(continuation)"
        return CloudParsedLogLine(dt: dt, category: category, level: nil, message: fallbackMessage)
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
}

