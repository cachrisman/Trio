import Foundation

enum LockScreenView: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }
    case simple
    case detailed
    case bigGlucose
    var displayName: String {
        switch self {
        case .simple:
            return String(localized: "Simple", comment: "")
        case .detailed:
            return String(localized: "Detailed", comment: "")
        case .bigGlucose:
            return String(localized: "Big Glucose", comment: "")
        }
    }
}
