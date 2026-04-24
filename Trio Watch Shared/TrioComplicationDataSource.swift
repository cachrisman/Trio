import Foundation

enum TrioComplicationDataSource: String, Codable, Equatable {
    case unknown
    case watchConnectivity
    case healthKit
    case directBLE
}
