import Foundation

enum TrioComplicationDataSource: String, Codable {
    case watchConnectivity
    case healthKit
    case directBLE
    case unknown

    var shortLabel: String {
        switch self {
        case .watchConnectivity: return "PHONE"
        case .healthKit: return "HK"
        case .directBLE: return "BLE"
        case .unknown: return "?"
        }
    }
}
