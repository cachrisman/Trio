import Foundation
import SwiftUI

/// One persisted glucose reading. Canonical **mg/dL** always (never display units).
struct StoredGlucoseReading: Codable {
    let epochSeconds: Int // Int(readingDate.timeIntervalSince1970)
    let glucoseMgDl: Int // canonical integer mg/dL
    let sequence: Int? // G7 EGV sequence when known; nil for HK / WC
    let source: String // "ble" | "wc" | "hk"

    /// Single P2 decode path for a WC chart entry dictionary (`{date, glucoseMgDl}`, no color).
    /// WC-bridging-safe: dates may arrive as `Date`/`TimeInterval`/`NSNumber`, numbers as `NSNumber`.
    /// Returns nil (skip, don't crash) on a malformed entry.
    static func from(wcEntry d: [String: Any], source: String) -> StoredGlucoseReading? {
        // NSNumber catches both Int and Double over WC; the bare Int/Double fallbacks guard an
        // in-process (non-bridged) caller (review low).
        let mgDl = (d["glucoseMgDl"] as? NSNumber)?.intValue
            ?? (d["glucoseMgDl"] as? Int)
            ?? (d["glucoseMgDl"] as? Double).map { Int($0) }
        guard let date = bridgedDate(from: d["date"]), let mgDl else { return nil }
        return StoredGlucoseReading(
            epochSeconds: Int(date.timeIntervalSince1970),
            glucoseMgDl: mgDl,
            sequence: nil,
            source: source
        )
    }

    /// Mirrors `WatchState.dateValue(from:)` (Foundation-only) so the store has no WatchState coupling.
    static func bridgedDate(from value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        return nil
    }
}

/// Rolling 24h glucose history persisted on the watch (build 205 / W1), so the chart is populated
/// from cached data on startup instead of waiting for the first WC payload.
///
/// **Serialization invariant:** every public method runs its load→merge→prune→sort→write cycle on a
/// private serial queue, so concurrent BLE / HK / WC / startup-load callers can't interleave (which
/// would lose writes). A serial queue (rather than `@MainActor`) is used because the watch's
/// `WatchState`/WC-delegate chain is not actor-isolated, and the BLE adapter calls in from its own
/// context — the queue makes the store safe from any caller without forcing actor cascades.
///
/// Storage: a JSON file in the app extension's Documents container (NOT App Group — the complication
/// consumes the baked snapshot color, not this history).
final class WatchGlucoseHistoryStore {
    static let shared = WatchGlucoseHistoryStore()

    private static let maxEntries = 288 // 24h at 5-min cadence
    private static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    private var entries: [StoredGlucoseReading] = []
    private let fileURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("glucose_history.json")

    /// Serializes all access. Public methods use `queue.sync`; private helpers assume they run on it.
    private let queue = DispatchQueue(label: "com.trio.watch.glucoseHistoryStore")

    private init() {
        loadFromDisk()
        pruneAndCap()
    }

    // MARK: - Source priority (mirrors TrioComplicationDataSource.priority)

    private func priority(_ source: String) -> Int {
        switch source {
        case "ble": return 3
        case "wc": return 2
        case "hk": return 1
        default: return 0
        }
    }

    // MARK: - Inserts

    /// Single-reading insert — BLE / HK (they arrive one at a time; one disk write each).
    func insert(_ reading: StoredGlucoseReading) {
        queue.sync {
            canary(reading)
            let didAppend = mergeInMemory(reading)
            pruneAndCap()
            writeToDisk()
            emitInsertTelemetry(source: reading.source, batch: 1, appended: didAppend ? 1 : 0)
        }
    }

    /// Batch insert — WC delivery (up to 24 readings at once; one prune/sort/write for the batch).
    func insert(_ readings: [StoredGlucoseReading]) {
        guard !readings.isEmpty else { return }
        queue.sync {
            var appended = 0
            for r in readings {
                canary(r)
                if mergeInMemory(r) { appended += 1 }
            }
            pruneAndCap()
            writeToDisk()
            emitInsertTelemetry(source: "wc", batch: readings.count, appended: appended)
        }
    }

    /// Dedup/replace/append only — no sort, no write. Returns true if the reading was appended (new),
    /// false if it deduped against an existing entry (replaced or no-op).
    @discardableResult
    private func mergeInMemory(_ reading: StoredGlucoseReading) -> Bool {
        if let idx = entries.firstIndex(where: {
            abs($0.epochSeconds - reading.epochSeconds) <= 1 && sequencesMatch($0.sequence, reading.sequence)
        }) {
            if priority(reading.source) > priority(entries[idx].source) {
                entries[idx] = reading // higher-priority source wins (ble > wc > hk)
            }
            return false
        }
        entries.append(reading)
        return true
    }

    /// "Either sequence nil" rule: sequence wins when both are present; otherwise the ±1s window is
    /// the key (so BLE(seq=X) and WC(nil) for the same physical EGV dedup correctly).
    private func sequencesMatch(_ a: Int?, _ b: Int?) -> Bool {
        if let a, let b { return a == b }
        return true
    }

    private func pruneAndCap() {
        let cutoff = Int(Date().timeIntervalSince1970 - Self.maxAgeSeconds)
        entries = entries
            .filter { $0.epochSeconds >= cutoff }
            .sorted { $0.epochSeconds < $1.epochSeconds }
        // Age-pruning alone does not guarantee <= 288 (dedup slips, HK backfill). Hard-cap newest 288.
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
    }

    // MARK: - Read

    /// `[StoredGlucoseReading]` → chart tuples. mg/dL → display units via the color computer's
    /// watch-local conversion (W5 deviation); color is always computed from **mg/dL**.
    func loadAsDisplayValues(colorComputer: WatchGlucoseColorComputer) -> [(date: Date, glucose: Double, color: Color)] {
        queue.sync {
            pruneAndCap() // drop >24h entries even if the process stayed alive without inserts (review low; in-memory only, no write)
            return entries.map { e in
                (
                    date: Date(timeIntervalSince1970: TimeInterval(e.epochSeconds)),
                    glucose: colorComputer.displayValue(forMgDl: e.glucoseMgDl),
                    color: colorComputer.chartColor(for: e.glucoseMgDl)
                )
            }
        }
    }

    // MARK: - Persistence (assume on-queue, except init)

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([StoredGlucoseReading].self, from: data) else { return }
        entries = decoded
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Task { await WatchLogger.shared.log("event=build205_w_history_write_failed error=\(error)") }
        }
    }

    // MARK: - Diagnostics

    /// Logged canary (not a stripped `assert`) against accidental display-unit values. Any realistic
    /// mmol/L value (<= ~22) trips it; `!= 0` allows a sentinel. Dexcom floors real readings at 40.
    private func canary(_ reading: StoredGlucoseReading) {
        if reading.glucoseMgDl != 0, reading.glucoseMgDl < 25 {
            Task {
                await WatchLogger.shared.log(
                    "event=units_suspicious mgdl=\(reading.glucoseMgDl) source=\(reading.source)"
                )
            }
        }
    }

    private func emitInsertTelemetry(source: String, batch: Int, appended: Int) {
        let total = entries.count
        Task {
            await WatchLogger.shared.log(
                "event=build205_w_history_insert source=\(source) batch=\(batch)"
                    + " appended=\(appended) deduped=\(batch - appended) total=\(total)"
            )
        }
    }
}
