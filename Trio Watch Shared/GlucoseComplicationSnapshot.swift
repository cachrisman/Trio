import Foundation

/// The latest glucose reading handed from the watch app to its complication through the shared
/// App Group, because the two are separate processes.
struct GlucoseComplicationSnapshot: Codable, Equatable {
    let glucose: String
    let trend: String?
    let delta: String?
    let glucoseColorHex: String
    let readingDate: Date

    static let defaultsKey = "glucoseComplicationSnapshot"

    static var sharedDefaults: UserDefaults? {
        guard let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !suiteName.isEmpty
        else {
            return nil
        }
        return UserDefaults(suiteName: suiteName)
    }

    // fork — TrioComplicationDataStore is the single source for every watch complication here
    // (it also holds watch-side G7 readings), so the circular complication reads it rather than
    // the upstream App Group key; save() is unused in this fork.
    static func load() -> GlucoseComplicationSnapshot? {
        guard let s = TrioComplicationDataStore.shared.latestSnapshot(),
              s.glucose != "--", s.glucose != "!!"
        else {
            return nil
        }
        return GlucoseComplicationSnapshot(
            glucose: s.glucose,
            trend: s.trend,
            delta: s.delta == "--" ? nil : s.delta,
            glucoseColorHex: s.glucoseColor ?? "",
            readingDate: s.readingDate
        )
    }

    func save() {
        guard let defaults = Self.sharedDefaults,
              let data = try? JSONEncoder().encode(self)
        else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
