import Foundation

struct BetterStackSettings: Decodable {
    let BetterStackSourceToken: String?
    let BetterStackIngestionUrl: String?
}

enum BetterStackSettingsStore {
    static let relativePath = "settings/BetterStack.json"

    /// Loads Better Stack settings from the app group container (preferred) and falls back to app documents.
    static func load() -> BetterStackSettings? {
        // Prefer the configured AppGroupID (Info.plist key "AppGroupID") if present.
        if let suite = Bundle.main.appGroupSuiteName, !suite.isEmpty {
            if let settings = load(from: .sharedContainer(appGroupName: suite)) {
                return settings
            }
        }

        // Fallback: some builds use a short app group name like "Trio".
        if let settings = load(from: .sharedContainer(appGroupName: "Trio")) {
            return settings
        }

        // Fallback to local documents directory (useful for simulator/dev environments).
        return load(from: .documents)
    }

    private static func load(from directory: Disk.Directory) -> BetterStackSettings? {
        guard let data = try? Disk.retrieve(relativePath, from: directory, as: Data.self) else {
            return nil
        }
        return try? JSONDecoder().decode(BetterStackSettings.self, from: data)
    }
}
