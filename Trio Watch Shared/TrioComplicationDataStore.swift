import Foundation

@MainActor
final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()

    private static let storeKey = "trio_complication_snapshot_v1"
    private(set) var lastSnapshot: TrioComplicationSnapshot?

    private init() {
        lastSnapshot = loadSnapshot()
    }

    func save(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool = true, minInterval _: TimeInterval = 5) {
        guard shouldSave(snapshot) else { return }
        lastSnapshot = snapshot
        persist(snapshot)
        if triggerReload {
            // Placeholder for future WidgetCenter / complication reload integration.
        }
    }

    private func shouldSave(_ newSnapshot: TrioComplicationSnapshot) -> Bool {
        guard let existing = lastSnapshot else { return true }
        return newSnapshot.readingDate >= existing.readingDate || newSnapshot.source == .directBLE
    }

    private func persist(_ snapshot: TrioComplicationSnapshot) {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.storeKey)
    }

    private func loadSnapshot() -> TrioComplicationSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey) else { return nil }
        return try? JSONDecoder().decode(TrioComplicationSnapshot.self, from: data)
    }
}
