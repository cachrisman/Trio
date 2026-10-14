import Foundation
import WidgetKit

public final class TrioComplicationDataStore {
    public static let shared = TrioComplicationDataStore()
    public static let complicationKind = "TrioWatchComplication"

    private let defaults: UserDefaults?
    private let snapshotKey = "trio.complication.snapshot.v1"
    private let lastWriteKey = "trio.complication.last.write.v1"

    public var appGroupID: String? { "group.com.trio.watch" }

    private init() {
        if let appGroupID {
            defaults = UserDefaults(suiteName: appGroupID)
        } else {
            defaults = UserDefaults.standard
        }
    }

    @MainActor
    public func save(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool = true, minInterval: TimeInterval = 5) {
        let now = Date()
        let lastWrite = defaults?.object(forKey: lastWriteKey) as? Date
        if let lastWrite, now.timeIntervalSince(lastWrite) < minInterval {
            return
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults?.set(data, forKey: snapshotKey)
            defaults?.set(now, forKey: lastWriteKey)
            if triggerReload {
                WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
            }
        } catch {
            print("Failed to save TrioComplicationSnapshot: \(error)")
        }
    }

    public func latestSnapshot() -> TrioComplicationSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(TrioComplicationSnapshot.self, from: data)
    }
}
