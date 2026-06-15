import Foundation
import SwiftUI

enum Adjustments {
    enum Config {}

    enum Tab: String, Hashable, Identifiable, CaseIterable {
        case tempTargets
        case overrides

        var id: String { rawValue }

        var name: String {
            switch self {
            case .tempTargets:
                return String(localized: "Temp Targets", comment: "Selected Tab")
            case .overrides:
                return String(localized: "Overrides", comment: "Selected Tab")
            }
        }
    }
}

protocol AdjustmentsProvider: Provider {}
