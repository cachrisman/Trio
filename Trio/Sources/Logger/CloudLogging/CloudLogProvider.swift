import Foundation

extension CloudLogQueue.Cursor: CustomStringConvertible {
    var description: String { "\(segment):\(offset)" }
}

protocol CloudLogProvider {
    /// Uploads a batch of events.
    ///
    /// - Important: Must only treat HTTP 202 as success.
    func upload(events: [CloudLogEvent]) async -> Result<Void, CloudLogUploadError>
}

enum CloudLogUploadError: Error, CustomStringConvertible {
    case notConfigured
    case invalidURL
    case transport(Error)
    case invalidResponse
    case unexpectedStatus(code: Int, bodyPreview: String?)
    case encoding(Error)

    var description: String {
        switch self {
        case .notConfigured:
            return "Cloud logging not configured"
        case .invalidURL:
            return "Invalid cloud logging URL"
        case let .transport(error):
            return "Transport error: \(error)"
        case .invalidResponse:
            return "Invalid HTTP response"
        case let .unexpectedStatus(code, bodyPreview):
            return "Unexpected HTTP status: \(code) body: \(bodyPreview ?? "<nil>")"
        case let .encoding(error):
            return "Encoding error: \(error)"
        }
    }
}

struct CloudLogCommonAttributes {
    let build: String
    let appVersion: String
    let env: String

    static let current: CloudLogCommonAttributes = {
        let info = Bundle.main.infoDictionary
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
        return CloudLogCommonAttributes(
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            env: env
        )
    }()
}

struct CloudLogEvent: Encodable {
    let message: String
    let dt: String?
    let attributes: [String: String]?

    // Custom encoding to flatten attributes to top-level fields
    enum CodingKeys: String, CodingKey {
        case message
        case dt
        case platform
        case build
        case category
        case appVersion
        case env
        case level
        case severity
        case file
        case method
        case lineNumber
        case source
        case event
        case windowId = "window_id"
        case taskType = "task_type"
    }

    private static let maxMessageBytes = 64 * 1024
    private static let truncationSuffix = "…[truncated]"

    private static let eventRegex = try? NSRegularExpression(pattern: #"\bevent=([^ ]+)"#)
    private static let windowIdRegex = try? NSRegularExpression(pattern: #"\bwindow_id=(-?[0-9]+)"#)
    private static let taskTypeRegex = try? NSRegularExpression(pattern: #"\btask_type=([^ ]+)"#)
    private static let complicationRegex = try? NSRegularExpression(pattern: #"\bsrc=complication\b"#)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        if let dt = dt {
            try container.encode(dt, forKey: .dt)
        }

        // Flatten attributes to top-level fields
        if let attrs = attributes {
            if let platform = attrs["platform"] {
                try container.encode(platform, forKey: .platform)
            }
            if let build = attrs["build"] {
                try container.encode(build, forKey: .build)
            }
            if let category = attrs["category"] {
                try container.encode(category, forKey: .category)
            }
            if let appVersion = attrs["appVersion"] {
                try container.encode(appVersion, forKey: .appVersion)
            }
            if let env = attrs["env"] {
                try container.encode(env, forKey: .env)
            }
            if let level = attrs["level"] {
                try container.encode(level, forKey: .level)
            }
            if let severity = attrs["severity"] {
                try container.encode(severity, forKey: .severity)
            }
            if let file = attrs["file"] {
                try container.encode(file, forKey: .file)
            }
            if let method = attrs["method"] {
                try container.encode(method, forKey: .method)
            }
            if let lineNumber = attrs["lineNumber"] {
                try container.encode(lineNumber, forKey: .lineNumber)
            }
            if let source = attrs["source"] {
                try container.encode(source, forKey: .source)
            }
        }

        if let value = Self.extractToken(from: message, regex: Self.eventRegex) {
            try container.encode(value, forKey: .event)
        }
        if let value = Self.extractToken(from: message, regex: Self.windowIdRegex),
           let intValue = Int(value)
        {
            try container.encode(intValue, forKey: .windowId)
        }
        if let value = Self.extractToken(from: message, regex: Self.taskTypeRegex) {
            try container.encode(value, forKey: .taskType)
        }
    }

    static func make(from record: LogRecord, common: CloudLogCommonAttributes) -> CloudLogEvent {
        let isWatch = record.category.hasPrefix("Watch/")

        let legacyLevel: String
        let severity: String
        switch record.level {
        case .debug:
            legacyLevel = "debug"
            severity = "debug"
        case .info:
            legacyLevel = "info"
            severity = "info"
        case .notice:
            legacyLevel = "info"
            severity = "notice"
        case .warning:
            legacyLevel = "warn"
            severity = "warning"
        case .error:
            legacyLevel = "error"
            severity = "error"
        case .fault:
            legacyLevel = "error"
            severity = "fault"
        }

        let source: String
        if matches(complicationRegex, in: record.message) {
            source = "complication"
        } else if isWatch {
            source = "watch"
        } else {
            source = "phone"
        }

        var attributes: [String: String] = [
            "platform": isWatch ? "watchos" : "ios",
            "build": common.build,
            "category": record.category,
            "appVersion": common.appVersion,
            "env": common.env,
            "level": legacyLevel,
            "severity": severity,
            "source": source
        ]
        if !record.file.isEmpty, record.file != "Watch", !record.function.isEmpty, record.line > 0 {
            attributes["file"] = record.file
            attributes["method"] = record.function
            attributes["lineNumber"] = String(record.line)
        }

        return CloudLogEvent(
            message: truncated(record.message),
            dt: isoString(from: record.timestamp),
            attributes: attributes
        )
    }

    static func dropped(count: UInt64, common: CloudLogCommonAttributes) -> CloudLogEvent {
        CloudLogEvent(
            message: "event=cloud_log_dropped count=\(count) CloudLogQueue dropped rows before upload",
            dt: isoString(from: Date()),
            attributes: [
                "platform": "ios",
                "build": common.build,
                "category": "CloudLogging",
                "appVersion": common.appVersion,
                "env": common.env,
                "level": "warn",
                "severity": "warning",
                "source": "phone"
            ]
        )
    }

    static func rowDropped(
        status: String,
        rows: UInt64,
        rangeStart: CloudLogQueue.Cursor,
        rangeEnd: CloudLogQueue.Cursor,
        common: CloudLogCommonAttributes
    ) -> CloudLogEvent {
        CloudLogEvent(
            message: "event=cloud_log_row_dropped status=\(status) rows=\(rows) range=\(rangeStart)..\(rangeEnd)",
            dt: isoString(from: Date()),
            attributes: [
                "platform": "ios",
                "build": common.build,
                "category": "CloudLogging",
                "appVersion": common.appVersion,
                "env": common.env,
                "level": "warn",
                "severity": "warning",
                "source": "phone"
            ]
        )
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func truncated(_ message: String) -> String {
        guard message.utf8.count > maxMessageBytes else { return message }
        let budget = maxMessageBytes - truncationSuffix.utf8.count
        var result = ""
        var used = 0
        for character in message {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + truncationSuffix
    }

    private static func matches(_ regex: NSRegularExpression?, in string: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func extractToken(from string: String, regex: NSRegularExpression?) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return String(string[range])
    }
}
