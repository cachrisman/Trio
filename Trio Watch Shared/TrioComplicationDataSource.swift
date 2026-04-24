import Foundation

enum TrioComplicationDataSource: String, Codable {
    case watchConnectivity
    case healthKit
    case directBLE
    case unknown

    var shortLabel: String {
        switch self {
        case .watchConnectivity: "Phone"
        case .healthKit: "HK"
        case .directBLE: "BLE"
        case .unknown: "?"
        }
    }
}
