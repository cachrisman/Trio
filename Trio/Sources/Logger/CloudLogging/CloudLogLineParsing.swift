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
    static func parseIOS(_ line: String) -> CloudParsedLogLine? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }

        // Timestamp = first token
        let tokens = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let rawTs = tokens.first.map(String.init)
        let dt = rawTs.flatMap(normalizeTimestamp)

        // Category = first [...] after timestamp
        var category: String?
        if let range = trimmed.range(of: #"^\S+\s+\[([^\]]+)\]"#, options: [.regularExpression]) {
            // Extract using a second regex capture to keep code simple.
            if let match = trimmed[range].range(of: #"\[([^\]]+)\]"#, options: .regularExpression) {
                let bracketed = String(trimmed[match])
                category = bracketed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            }
        }

        // Level = delimiter-aware: " - (DEV|INFO|WARN|ERR):"
        let levelRegex = #"\s-\s(DEV|INFO|WARN|ERR):\s"#
        guard let levelMatch = trimmed.range(of: levelRegex, options: .regularExpression) else {
            // If we can't confidently parse, still return the original line as message.
            return CloudParsedLogLine(dt: dt, category: category, level: nil, message: trimmed)
        }

        // Extract the actual level token and normalize
        let levelToken = String(trimmed[levelMatch])
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
        let messageStart = trimmed.index(levelMatch.upperBound, offsetBy: 0)
        let parsedMessage = String(trimmed[messageStart...]).trimmingCharacters(in: .newlines)

        return CloudParsedLogLine(
            dt: dt,
            category: category,
            level: normalizedLevel,
            message: parsedMessage.isEmpty ? trimmed : parsedMessage
        )
    }

    // Watch format:
    // [<TIMESTAMP>] [<File.swift>:<line>] <function>() → <message>
    static func parseWatch(_ line: String) -> CloudParsedLogLine? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }

        // Timestamp = first [...] token
        var dt: String?
        if let tsRange = trimmed.range(of: #"^\[([^\]]+)\]"#, options: [.regularExpression]) {
            let bracketed = String(trimmed[tsRange])
            let raw = bracketed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            dt = normalizeTimestamp(raw)
        }

        // Category = filename from "[File.swift:line]"
        // Regex: ^\[[^\]]+\]\s+\[([^\]:]+)\.swift:\d+\]
        var category: String?
        category = extractWatchCategory(from: trimmed)

        // Message = everything after the arrow
        if let arrowRange = trimmed.range(of: "→") {
            let msg = trimmed[arrowRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return CloudParsedLogLine(dt: dt, category: category, level: nil, message: msg.isEmpty ? trimmed : String(msg))
        }

        return CloudParsedLogLine(dt: dt, category: category, level: nil, message: trimmed)
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

