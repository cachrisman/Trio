import Foundation

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

struct CloudLogEvent: Encodable {
    let message: String
    let dt: String?
    let attributes: [String: String]?
    let raw: String?

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
        case file
        case method
        case lineNumber
        case source
        case raw
        case event
        case windowId = "window_id"
        case taskType = "task_type"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        if let dt = dt {
            try container.encode(dt, forKey: .dt)
        }
        if let raw = raw {
            try container.encode(raw, forKey: .raw)
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

        if let value = Self.extractToken(from: message, pattern: #"\bevent=([^ ]+)"#) {
            try container.encode(value, forKey: .event)
        }
        if let value = Self.extractToken(from: message, pattern: #"\bwindow_id=(-?[0-9]+)"#),
           let intValue = Int(value)
        {
            try container.encode(intValue, forKey: .windowId)
        }
        if let value = Self.extractToken(from: message, pattern: #"\btask_type=([^ ]+)"#) {
            try container.encode(value, forKey: .taskType)
        }
    }

    private static func extractToken(from string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return String(string[range])
    }
}
