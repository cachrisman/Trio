import Foundation
import WidgetKit

final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()

    private init() {}

    private let snapshotKey = "trio.complication.snapshot"
    private let lastReloadKey = "trio.complication.lastReload"
    private let lastGlucoseKey = "trio.complication.lastGlucoseString"

    /// Tunable throttle for timeline reloads (seconds)
    var timelineReloadThrottleInterval: TimeInterval = 60

    /// Persists a snapshot dictionary and reloads Widget timelines based on glucose change heuristics
    func saveSnapshotAndReloadIfNeeded(snapshot: [String: Any], isColdStart: Bool) {
        let defaults = appGroupDefaults()

        // Merge with existing snapshot to avoid dropping keys
        var merged = (defaults.dictionary(forKey: snapshotKey) ?? [:])
        merged.merge(snapshot) { _, new in new }
        defaults.set(merged, forKey: snapshotKey)

        // Heuristic: immediate reload on glucose change, otherwise schedule delayed backup reload
        let newGlucose = (merged[WatchMessageKeys.currentGlucose] as? String) ?? "--"
        let lastGlucose = defaults.string(forKey: lastGlucoseKey) ?? ""
        let now = Date()
        let lastReload = Date(timeIntervalSince1970: defaults.double(forKey: lastReloadKey))

        let shouldThrottle = now.timeIntervalSince(lastReload) < timelineReloadThrottleInterval

        if newGlucose != lastGlucose {
            defaults.set(newGlucose, forKey: lastGlucoseKey)
            if !shouldThrottle {
                WidgetCenter.shared.reloadAllTimelines()
                defaults.set(now.timeIntervalSince1970, forKey: lastReloadKey)
            }
        } else {
            // Schedule a backup reload after 10s if not throttled
            if !shouldThrottle {
                let delay: TimeInterval = isColdStart ? 10 : 10
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    let defaults = self.appGroupDefaults()
                    let lastReload = Date(timeIntervalSince1970: defaults.double(forKey: self.lastReloadKey))
                    let now = Date()
                    if now.timeIntervalSince(lastReload) >= self.timelineReloadThrottleInterval {
                        WidgetCenter.shared.reloadAllTimelines()
                        defaults.set(now.timeIntervalSince1970, forKey: self.lastReloadKey)
                    }
                }
            }
        }
    }

    /// Loads the last saved snapshot for use in complications
    func loadSnapshot() -> [String: Any]? {
        appGroupDefaults().dictionary(forKey: snapshotKey)
    }

    private func appGroupDefaults() -> UserDefaults {
        // Attempt to read from shared App Group if configured, else fall back to standard defaults
        if let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           let shared = UserDefaults(suiteName: suiteName) {
            return shared
        }
        return .standard
    }
}
