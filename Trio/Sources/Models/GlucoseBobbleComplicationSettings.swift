import Foundation

/// Settings for the Trio Glucose Bobble watch complication. Edited on the phone, sent to the watch
/// in the watch-state message, and handed to the complication through the watch's App Group.
struct GlucoseBobbleComplicationSettings: Codable, Hashable, Sendable {
    enum ColorMode: String, Codable, CaseIterable, Sendable {
        case glucose
        case white
    }

    enum BackgroundStyle: String, Codable, CaseIterable, Sendable {
        case glucoseTint
        case system
        case none
    }

    enum RingStyle: String, Codable, CaseIterable, Sendable {
        case trendGradient
        case loopStatus
    }

    var colorMode: ColorMode = .glucose
    var showMinutesAgo: Bool = true
    var showDelta: Bool = true
    var backgroundStyle: BackgroundStyle = .glucoseTint
    var ringStyle: RingStyle = .trendGradient

    init(
        colorMode: ColorMode = .glucose,
        showMinutesAgo: Bool = true,
        showDelta: Bool = true,
        backgroundStyle: BackgroundStyle = .glucoseTint,
        ringStyle: RingStyle = .trendGradient
    ) {
        self.colorMode = colorMode
        self.showMinutesAgo = showMinutesAgo
        self.showDelta = showDelta
        self.backgroundStyle = backgroundStyle
        self.ringStyle = ringStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GlucoseBobbleComplicationSettings()

        colorMode = try container.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? defaults.colorMode
        showMinutesAgo = try container.decodeIfPresent(Bool.self, forKey: .showMinutesAgo) ?? defaults.showMinutesAgo
        showDelta = try container.decodeIfPresent(Bool.self, forKey: .showDelta) ?? defaults.showDelta
        backgroundStyle = try container.decodeIfPresent(BackgroundStyle.self, forKey: .backgroundStyle) ?? defaults
            .backgroundStyle
        ringStyle = try container.decodeIfPresent(RingStyle.self, forKey: .ringStyle) ?? defaults.ringStyle
    }

    static let defaultsKey = "glucoseBobbleComplicationSettings"

    static var sharedDefaults: UserDefaults? {
        guard let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !suiteName.isEmpty
        else {
            return nil
        }
        return UserDefaults(suiteName: suiteName)
    }

    static func load() -> GlucoseBobbleComplicationSettings? {
        guard let data = sharedDefaults?.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(GlucoseBobbleComplicationSettings.self, from: data)
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
