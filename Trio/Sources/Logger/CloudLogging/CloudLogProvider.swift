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
}

