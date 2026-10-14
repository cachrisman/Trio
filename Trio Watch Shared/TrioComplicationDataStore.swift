import Foundation
import WidgetKit

public enum TrioReadingSource: String, Codable {
    case watchConnectivity
    case healthKit
    case directBLE
}

public enum G7DirectBLEStatus: String, Codable {
    case off
    case searching
    case connecting
    case active
    case stalled
    case unavailable
}

public struct TrioComplicationSnapshot: Codable, Equatable {
    public var glucose: String
    public var trend: String
    public var readingDate: Date
    public var date: Date
    public var source: TrioReadingSource
    public var delta: String?

    public init(
        glucose: String,
        trend: String,
        readingDate: Date,
        date: Date,
        source: TrioReadingSource,
        delta: String? = nil
    ) {
        self.glucose = glucose
        self.trend = trend
        self.readingDate = readingDate
        self.date = date
        self.source = source
        self.delta = delta
    }
}

public final class TrioComplicationDataStore {
    public static let shared = TrioComplicationDataStore()

    public static let complicationKind = "TrioWatchComplication"

    private let queue = DispatchQueue(label: "TrioComplicationDataStore.queue")
    private let defaults = UserDefaults.standard

    private let latestSnapshotKey = "trio.complication.snapshot.latest"
    private let lastSaveKey = "trio.complication.snapshot.lastSave"
    private let lastDirectBLEEventKey = "trio.complication.directBLE.lastEvent"
    private let directBLEStatusKey = "trio.complication.directBLE.status"

    private init() {}

    public func latestSnapshot() -> TrioComplicationSnapshot? {
        queue.sync {
            guard let data = defaults.data(forKey: latestSnapshotKey) else { return nil }
            return try? JSONDecoder().decode(TrioComplicationSnapshot.self, from: data)
        }
    }

    public func save(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool = true, minInterval: TimeInterval = 30) {
        let now = Date()

        queue.async {
            let lastSaveInterval = self.defaults.double(forKey: self.lastSaveKey)
            let lastSave = Date(timeIntervalSince1970: lastSaveInterval)
            let elapsed = now.timeIntervalSince(lastSave)

            if elapsed < minInterval {
                return
            }

            guard let encoded = try? JSONEncoder().encode(snapshot) else {
                return
            }

            self.defaults.set(encoded, forKey: self.latestSnapshotKey)
            self.defaults.set(now.timeIntervalSince1970, forKey: self.lastSaveKey)

            if snapshot.source == .directBLE {
                self.defaults.set(now.timeIntervalSince1970, forKey: self.lastDirectBLEEventKey)
            }

            guard triggerReload else { return }
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
            }
        }
    }

    public func setDirectBLEStatus(_ status: G7DirectBLEStatus) {
        defaults.set(status.rawValue, forKey: directBLEStatusKey)
    }

    public func directBLEStatus() -> G7DirectBLEStatus {
        guard let raw = defaults.string(forKey: directBLEStatusKey),
              let status = G7DirectBLEStatus(rawValue: raw)
        else {
            return .off
        }
        return status
    }

    public func setLastDirectBLEEvent(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: lastDirectBLEEventKey)
    }

    public func lastDirectBLEEventAt() -> Date? {
        let value = defaults.double(forKey: lastDirectBLEEventKey)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
