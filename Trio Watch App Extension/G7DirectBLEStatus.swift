import Foundation

enum G7DirectBLEStatus: String {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable

    var shortLabel: String {
        switch self {
        case .off: return "OFF"
        case .searching: return "SEARCH"
        case .connecting: return "CONN"
        case .active: return "ACTIVE"
        case .stalled: return "STALL"
        case .unavailable: return "UNAV"
        }
    }
}
