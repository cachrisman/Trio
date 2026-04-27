import Foundation

/// Provenance of the glucose value saved to the complication data store.
enum TrioComplicationDataSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// iPhone / WatchConnectivity watchState path.
    case watchConnectivityPhone
    /// Direct G7 eavesdrop on the watch.
    case g7DirectBLE
    /// R6 HealthKit path.
    case healthKit
    /// Unset.
    case unknown
}
