import Foundation

/// Coarse state of the G7 direct-BLE observer, for UI consumption. The
/// 5-state palette is documented in
/// `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` §14.
///
/// Transitions are one-way from `.off` through attach states and back on
/// disconnect. `.unavailable` is a sink while BT is off / unauthorized and
/// clears once the central reports `.poweredOn`.
public enum G7DirectBLEObserverStatus: String, Equatable, Sendable {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable
}

public extension G7DirectBLEObserverStatus {
    /// Short lowercase label used in the main view status row.
    var shortLabel: String { rawValue }
}

/// Aggregate struct surfaced by the observer to `WatchState`. `status`
/// and `lastEGVAt` drive the UI.
public struct G7DirectBLEObserverSnapshot: Equatable, Sendable {
    public var status: G7DirectBLEObserverStatus
    public var lastEGVAt: Date?

    public init(status: G7DirectBLEObserverStatus = .off, lastEGVAt: Date? = nil) {
        self.status = status
        self.lastEGVAt = lastEGVAt
    }
}
