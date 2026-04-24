import Foundation

/// Identifies which path last supplied the glucose reading shown in the main watch UI / complication pipeline.
/// See `TrioComplicationDataStore` and `01-design.md`.
enum TrioComplicationDataSource: String, Sendable, Equatable, Codable {
    /// iPhone `WatchState` / WatchConnectivity debounced path (existing).
    case watchConnectivityPhone
    /// Direct G7 eavesdrop path (this feature).
    case g7DirectBLE
    /// Reserved if we later read CGM from HealthKit on-watch (not used by G7 direct BLE in this pass).
    case healthKit
    /// Unset / unknown (initial state, or no reading yet).
    case unknown
}
