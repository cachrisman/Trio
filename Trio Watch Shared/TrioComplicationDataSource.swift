import Foundation

enum TrioComplicationDataSource: String, Codable {
    case directBLE = "direct_ble"
    case watchConnectivity = "watch_connectivity"
    case healthKit = "healthkit"
    case unknown = "unknown"

    var shortLabel: String {
        switch self {
        case .directBLE: return "BLE"
        case .watchConnectivity: return "PHONE"
        case .healthKit: return "HK"
        case .unknown: return "?"
        }
    }
}
