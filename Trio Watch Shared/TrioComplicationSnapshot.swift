import Foundation

public enum TrioReadingSource: String, Codable, Sendable {
    case directBLE = "direct_ble"
    case phoneRelay = "phone_relay"
    case healthKit = "healthkit"
    case unknown = "unknown"
}

public struct TrioComplicationSnapshot: Codable, Sendable {
    public let glucose: String
    public let trend: String?
    public let delta: String?
    public let readingDate: Date
    public let date: Date
    public let source: TrioReadingSource
}
