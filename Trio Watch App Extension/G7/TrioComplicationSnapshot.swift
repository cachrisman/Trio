import Foundation

/// A single glucose point for the watch complication + main-view pipeline, with explicit source for UI attribution.
struct TrioComplicationSnapshot: Equatable, Sendable {
    /// String shown as BG (mg/dL as the user’s app is configured, same shape as `WatchState.currentGlucose`).
    var glucoseDisplay: String
    /// Nightscout-style trend string, e.g. "Flat" (matches `WatchState.trend` vocabulary).
    var trendArrow: String?
    /// When the sensor measured the sample (G7 `activationDate + glucoseTimestamp` per G7SensorKit).
    var readingDate: Date
    /// When this app ingested the sample.
    var ingestDate: Date
    /// Provenance of this reading for `GlucoseTrendView` and related UI.
    var dataSource: TrioComplicationDataSource
}
