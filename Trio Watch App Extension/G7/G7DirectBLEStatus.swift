import Foundation

/// Glanceable observer state for the main watch face (see `01-design.md` § UI).
enum G7DirectBLEStatus: String, Sendable, Equatable {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable
}
