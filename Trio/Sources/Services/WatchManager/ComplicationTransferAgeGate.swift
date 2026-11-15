import Foundation

/// Decides whether the phone may spend a budgeted complication transfer, based on how stale
/// the watch complication is. The threshold is longer while the user is asleep.
/// Foundation-only so it can be unit tested outside the app.
enum ComplicationTransferAgeGate {
    static let awakeThresholdSeconds: TimeInterval = 600
    static let asleepThresholdSeconds: TimeInterval = 1800

    struct Decision: Equatable {
        /// Threshold chosen for this decision, in seconds.
        let thresholdSeconds: TimeInterval
        /// True when the complication is strictly older than the threshold.
        let passes: Bool
        /// "awake" or "asleep"; the gate name and the sleep state always agree.
        let gateName: String
        let sleepState: String
    }

    /// Log-safe rendering of an age: "inf" when unknown (infinite or NaN), else whole seconds.
    /// `Int(_:)` traps on non-finite values, so log lines must not convert an age directly.
    static func logValue(_ seconds: TimeInterval) -> String {
        seconds.isFinite ? String(Int(seconds)) : "inf"
    }

    static func evaluate(isAsleep: Bool, ageSeconds: TimeInterval) -> Decision {
        let threshold = isAsleep ? asleepThresholdSeconds : awakeThresholdSeconds
        let name = isAsleep ? "asleep" : "awake"
        return Decision(
            thresholdSeconds: threshold,
            passes: ageSeconds > threshold,
            gateName: name,
            sleepState: name
        )
    }
}
