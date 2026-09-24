import Foundation

/// The latest glucose reading and last loop date handed from the watch app to its complication
/// through the shared App Group, because the two are separate processes.
struct GlucoseComplicationSnapshot: Codable, Equatable {
    let glucose: String
    let trend: String?
    let delta: String?
    /// The reading's colour in the user's glucose colour scheme (as the chart and the contact
    /// image's Glucose Bobble draw it), not the white-in-range colour of the watch's reading bubble.
    let glucoseColorHex: String
    let readingDate: Date
    var lastLoopDate: Date? = nil

    static let defaultsKey = "glucoseComplicationSnapshot"

    static var sharedDefaults: UserDefaults? {
        guard let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !suiteName.isEmpty
        else {
            return nil
        }
        return UserDefaults(suiteName: suiteName)
    }

    // fork — Phase C: this fork's load() never decodes the Codable snapshot below (it reads
    // TrioComplicationDataStore instead — see load()), so the phone-configured last loop date is
    // stored under its own App Group key instead of riding inside that snapshot's own encoding.
    static let lastLoopDateKey = "glucoseComplicationLastLoopDate"

    static func storedLastLoopDate() -> Date? {
        guard let defaults = sharedDefaults, defaults.object(forKey: lastLoopDateKey) != nil else {
            return nil
        }
        return Date(timeIntervalSince1970: defaults.double(forKey: lastLoopDateKey))
    }

    static func storeLastLoopDate(_ date: Date?) {
        guard let defaults = sharedDefaults else { return }
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: lastLoopDateKey)
        } else {
            defaults.removeObject(forKey: lastLoopDateKey)
        }
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
            // fork — prefer the chart/scheme colour over the white-in-range bubble colour.
            glucoseColorHex: s.chartGlucoseColor ?? s.glucoseColor ?? "",
            readingDate: s.readingDate,
            lastLoopDate: storedLastLoopDate()
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
