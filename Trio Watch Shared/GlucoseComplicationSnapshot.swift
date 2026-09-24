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

    static func load() -> GlucoseComplicationSnapshot? {
        guard let data = sharedDefaults?.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(GlucoseComplicationSnapshot.self, from: data)
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
