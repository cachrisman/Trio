import Foundation

enum TrioReadingSource: String, Codable {
    case directBLE = "direct_ble"
    case watchConnectivity = "watch_connectivity"
    case healthKit = "healthkit"
    case unknown = "unknown"

    var shortLabel: String {
        switch self {
        case .directBLE: "BLE"
        case .watchConnectivity: "Phone"
        case .healthKit: "HK"
        case .unknown: "--"
        }
    }
}

struct TrioComplicationSnapshot: Codable {
    let glucose: String
    let trend: String
    let readingDate: Date
    let date: Date
    let source: TrioReadingSource

    var recencyText: String {
        let minutes = max(0, Int(Date().timeIntervalSince(readingDate) / 60))
        return "\(minutes) min"
    }
}
