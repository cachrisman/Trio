import Foundation

/// Pure decisions for the phone-side complication fast path (TRIO-124).
///
/// A new glucose reading schedules a separate work item at `maxDelaySeconds` that sends only the
/// reduced complication payload, while the full watch state stays on the 2 s / 5 s coalescer.
/// No WCSession or timers here; the caller owns scheduling and transport.
enum ComplicationFastPathPolicy {
    /// Maximum wait from the first eligible trigger a fast work item serves.
    static let maxDelaySeconds: TimeInterval = 1.0

    /// Reading epoch value meaning "state has no reading".
    static let noEpoch = -1

    /// Whether a trigger source is complication-eligible and so schedules a fast item.
    static func qualifies(source: String, eligibleSources: Set<String>) -> Bool {
        eligibleSources.contains(source)
    }

    /// Delay for the fast work item, or nil when the pending coalescer send fires no later than the
    /// fast item would (a separate fast send would add nothing).
    /// - Parameters:
    ///   - elapsedSinceFirstEligible: seconds since the first eligible trigger this fast item serves (0 for the first)
    ///   - coalescerFireIn: seconds until the pending coalescer send fires, nil when none is pending
    static func delay(elapsedSinceFirstEligible: TimeInterval, coalescerFireIn: TimeInterval?) -> TimeInterval? {
        let fastDelay = max(0.0, maxDelaySeconds - max(0.0, elapsedSinceFirstEligible))
        if let coalescerFireIn, coalescerFireIn <= fastDelay {
            return nil
        }
        return fastDelay
    }

    /// Whether the state's newest reading epoch is newer than the last epoch sent by either path.
    /// A state with no reading (`noEpoch`, or any negative value) never fast-paths.
    static func isNewer(stateEpoch: Int, lastSentEpoch: Int) -> Bool {
        guard stateEpoch >= 0 else { return false }
        return stateEpoch > lastSentEpoch
    }
}
