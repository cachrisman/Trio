import Foundation

/// Identifies which ingestion path delivered the currently-displayed
/// complication / watch snapshot. Shared across the watch app extension,
/// the complication extension, and (future) iPhone-side code.
///
/// Stored as a short lowercase string so it stays stable across archive /
/// unarchive cycles even if this enum is extended.
///
/// Introduced for the G7 direct-BLE watch observer POC — see
/// `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` §15.
public enum TrioComplicationDataSource: String, Codable, Equatable, Sendable {
    /// Delivered from the iPhone via WatchConnectivity (message, user info,
    /// or application context).
    case watchConnectivity = "wc"

    /// Delivered via the watch's local HealthKit anchored observer.
    case healthKit = "hk"

    /// Delivered directly over BLE by eavesdropping on the Dexcom G7 watch
    /// app's active sensor session (same-device CoreBluetooth sharing).
    case g7DirectBLE = "ble"
}

public extension TrioComplicationDataSource {
    /// Short label for the main-watch-view status row (UI §14).
    var shortLabel: String { rawValue }
}
