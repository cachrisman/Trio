import Foundation
import WidgetKit

/// In-memory store and throttled WidgetKit refresh for the watch complication; coordinates winner policy with
/// the main `WatchState` UI. Name matches the deliverable; lives in the watch app extension.
@MainActor
final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()

    private(set) var lastSnapshot: TrioComplicationSnapshot?
    private var lastComplicationPush: Date = .distantPast

    private init() {}

    /// Winner policy: prefer newer CGM `readingDate`; on tie, prefer `g7DirectBLE` (lowest-latency path) over phone, over unknown.
    func shouldApply(_ snapshot: TrioComplicationSnapshot) -> Bool {
        guard let last = lastSnapshot else { return true }
        if snapshot.readingDate > last.readingDate { return true }
        if snapshot.readingDate < last.readingDate { return false }
        // Tie in time — keep higher-priority source
        return priority(snapshot.dataSource) > priority(last.dataSource)
    }

    private func priority(_ s: TrioComplicationDataSource) -> Int {
        switch s {
        case .g7DirectBLE: 3
        case .watchConnectivityPhone: 2
        case .healthKit: 1
        case .unknown: 0
        }
    }

    /// Persists the snapshot, optionally reloads widget timelines, and returns whether this reading became the winner.
    @discardableResult
    func save(snapshot: TrioComplicationSnapshot, triggerReload: Bool, minInterval: TimeInterval) -> Bool {
        let winner = shouldApply(snapshot)
        if !winner { return false }

        lastSnapshot = snapshot

        if triggerReload, Date().timeIntervalSince(lastComplicationPush) >= minInterval {
            lastComplicationPush = Date()
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
        return true
    }
}
