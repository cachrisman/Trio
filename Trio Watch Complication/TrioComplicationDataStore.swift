#if os(iOS)
    import UIKit
#endif
import Foundation
#if canImport(WidgetKit)
    import WidgetKit
#endif

struct TrioComplicationSnapshot: Equatable {
    private enum Constants {
        static let fallbackGlucose = "--"
        static let fallbackDelta = "--"
    }

    let glucose: String
    let trend: String
    let delta: String
    let timestamp: Date
    let state: String?

    init(glucose rawGlucose: String, trend rawTrend: String, delta rawDelta: String, timestamp: Date, state: String? = nil) {
        glucose = TrioComplicationSnapshot.sanitizedGlucose(from: rawGlucose)
        trend = rawTrend.trimmingCharacters(in: .whitespacesAndNewlines)
        delta = TrioComplicationSnapshot.sanitizedDelta(from: rawDelta)
        self.timestamp = timestamp
        self.state = state
    }

    init?(dictionary: [String: Any]) {
        let timestampValue: Date
        if let date = dictionary["timestamp"] as? Date {
            timestampValue = date
        } else if let seconds = dictionary["timestamp"] as? TimeInterval {
            timestampValue = Date(timeIntervalSince1970: seconds)
        } else {
            return nil
        }

        let glucoseValue = dictionary["glucose"] as? String ?? Constants.fallbackGlucose
        let trendValue = dictionary["trend"] as? String ?? ""
        let deltaValue = dictionary["delta"] as? String ?? Constants.fallbackDelta
        let stateValue = dictionary["state"] as? String

        self.init(
            glucose: glucoseValue,
            trend: trendValue,
            delta: deltaValue,
            timestamp: timestampValue,
            state: stateValue
        )
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "glucose": glucose,
            "trend": trend,
            "delta": delta,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let state = state {
            dict["state"] = state
        }
        return dict
    }

    private static func sanitizedGlucose(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Constants.fallbackGlucose }
        if trimmed == Constants.fallbackGlucose { return Constants.fallbackGlucose }

        let digitsAndSeparators = CharacterSet(charactersIn: "0123456789.")
        let numericPortion = trimmed
            .components(separatedBy: digitsAndSeparators.inverted)
            .joined()

        if let doubleValue = Double(numericPortion), doubleValue > 0 {
            let rounded = Int(doubleValue.rounded())
            return String(rounded)
        }

        return trimmed
    }

    private static func sanitizedDelta(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Constants.fallbackDelta }
        if trimmed == Constants.fallbackDelta { return Constants.fallbackDelta }

        let allowed = CharacterSet(charactersIn: "+-0123456789.,")
        let filteredScalars = trimmed.unicodeScalars.filter { allowed.contains($0) }
        let normalized = String(filteredScalars).replacingOccurrences(of: ",", with: ".")

        guard !normalized.isEmpty, let numericValue = Double(normalized) else {
            return trimmed
        }

        let magnitude = abs(numericValue)
        let roundedMagnitude = magnitude.rounded()
        if abs(roundedMagnitude - magnitude) < 0.05 {
            let signedInt = Int(roundedMagnitude) * (numericValue >= 0 ? 1 : -1)
            return String(format: "%+d", signedInt)
        }

        return String(format: "%+.1f", numericValue)
    }
}

final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()
    static let complicationKind = "TrioWatchComplication"

    /// Returns the shared App Group container URL based on the AppGroupID in Info.plist
    var sharedContainerURL: URL? {
        guard let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String else {
            #if os(watchOS)
                Task {
                    await WatchLogger.shared.log("⚠️ AppGroupID not found in Info.plist.")
                }
            #else
                NSLog("⚠️ AppGroupID not found in Info.plist.")
            #endif
            return nil
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else {
            #if os(watchOS)
                Task {
                    await WatchLogger.shared.log("⚠️ Could not get container URL for App Group: \(suiteName)")
                }
            #else
                NSLog("⚠️ Could not get container URL for App Group: \(suiteName)")
            #endif
            return nil
        }
        return url
    }

    private var snapshotFileURL: URL? {
        sharedContainerURL?.appendingPathComponent("snapshot.json")
    }

    func save(glucose: String, trend: String?, delta: String?, timestamp: Date) {
        let snapshot = TrioComplicationSnapshot(
            glucose: glucose,
            trend: trend ?? "",
            delta: delta ?? "",
            timestamp: timestamp
        )
        save(snapshot)
    }

    func save(_ snapshot: TrioComplicationSnapshot) {
        guard let fileURL = snapshotFileURL else {
            saveDiagnosticSnapshot(message: "❌ Could not get snapshot file URL for saving.", state: "--")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(SnapshotCodable(snapshot: snapshot))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            do {
                try data.write(to: fileURL, options: [.atomic])
                #if os(watchOS)
                    Task {
                        await WatchLogger.shared.log("✅ Saved complication snapshot to \(fileURL.lastPathComponent)")
                    }
                #endif
                #if os(iOS)
                    AppGroupDebugExporter.exportSnapshotToDocuments()
                #endif
            } catch {
                saveDiagnosticSnapshot(message: "❌ Failed to write complication snapshot: \(error)", state: "xx")
            }
        } catch {
            saveDiagnosticSnapshot(message: "❌ Failed to encode complication snapshot: \(error)", state: "xx")
        }
    }

    func latestSnapshot() -> TrioComplicationSnapshot? {
        guard let fileURL = snapshotFileURL else {
            saveDiagnosticSnapshot(message: "❌ Could not get snapshot file URL for loading.", state: "--")
            return fallbackSnapshot(state: "--")
        }
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        if !fileExists {
            saveDiagnosticSnapshot(message: "❌ Snapshot file missing at \(fileURL.path)", state: "!!")
            return fallbackSnapshot(state: "!!")
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshotCodable = try decoder.decode(SnapshotCodable.self, from: data)
            // Return snapshot with no state indicator on successful decode
            return TrioComplicationSnapshot(
                glucose: snapshotCodable.snapshot.glucose,
                trend: snapshotCodable.snapshot.trend,
                delta: snapshotCodable.snapshot.delta,
                timestamp: snapshotCodable.snapshot.timestamp,
                state: nil
            )
        } catch {
            saveDiagnosticSnapshot(message: "❌ Failed to decode complication snapshot: \(error)", state: "??")
            return fallbackSnapshot(state: "??")
        }
    }

    private func fallbackSnapshot(state: String) -> TrioComplicationSnapshot {
        TrioComplicationSnapshot(
            glucose: "--",
            trend: "",
            delta: "--",
            timestamp: Date(),
            state: state
        )
    }

    /// Writes a diagnostic snapshot with a given message and state, and logs via WatchLogger.
    private func saveDiagnosticSnapshot(message: String, state: String) {
        #if os(watchOS)
            Task {
                await WatchLogger.shared.log(message)
            }
        #else
            NSLog("%@", message)
        #endif
        // Write a temporary fallback snapshot for clarity
        let diagnostic = TrioComplicationSnapshot(
            glucose: "--",
            trend: "",
            delta: "--",
            timestamp: Date(),
            state: state
        )
        if let fileURL = snapshotFileURL {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(SnapshotCodable(snapshot: diagnostic))
                try? data.write(to: fileURL, options: [.atomic])
            } catch {
                // Ignore further errors here
            }
        }
    }

    #if canImport(WidgetKit)
        func reloadTimeline() {
            let reloadBlock = {
                if #available(watchOS 10.0, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
                } else {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            if Thread.isMainThread {
                reloadBlock()
            } else {
                DispatchQueue.main.async(execute: reloadBlock)
            }
        }
    #endif
}

// MARK: - Codable bridge for TrioComplicationSnapshot

extension TrioComplicationSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case glucose
        case trend
        case delta
        case timestamp
        case state
    }
}

/// Wrapper to ensure compatibility with old code if needed
private struct SnapshotCodable: Codable {
    let snapshot: TrioComplicationSnapshot

    init(snapshot: TrioComplicationSnapshot) {
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        snapshot = try container.decode(TrioComplicationSnapshot.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(snapshot)
    }
}

#if os(iOS)
    /// Utility to export the App Group snapshot.json to the iOS Documents directory for debugging.
    enum AppGroupDebugExporter {
        /// Copies the App Group snapshot.json file to the iPhone’s Documents directory for inspection via Files app.
        static func exportSnapshotToDocuments() {
            // 1. Get App Group ID from Info.plist
            guard let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String else {
                print("❌ AppGroupDebugExporter: AppGroupID not found in Info.plist.")
                return
            }
            // 2. Get App Group container URL
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
                print("❌ AppGroupDebugExporter: Could not get container URL for App Group: \(appGroupID)")
                return
            }
            // 3. Source file: snapshot.json in App Group
            let sourceURL = containerURL.appendingPathComponent("snapshot.json")
            // 4. Destination: Documents directory on iPhone
            guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("❌ AppGroupDebugExporter: Could not resolve Documents directory.")
                return
            }
            let trioFolder = documentsURL.appendingPathComponent("Trio", isDirectory: true)
            let destURL = trioFolder.appendingPathComponent("snapshot.json")
            let fm = FileManager.default
            if !fm.fileExists(atPath: trioFolder.path) {
                do {
                    try fm.createDirectory(at: trioFolder, withIntermediateDirectories: true)
                } catch {
                    print("❌ AppGroupDebugExporter: Failed to create Trio folder in Documents: \(error)")
                }
            }
            // 5. Check if source exists
            guard fm.fileExists(atPath: sourceURL.path) else {
                print("❌ AppGroupDebugExporter: No snapshot.json found at \(sourceURL.path)")
                return
            }
            // 6. Remove existing destination file if present
            if fm.fileExists(atPath: destURL.path) {
                do {
                    try fm.removeItem(at: destURL)
                } catch {
                    print("❌ AppGroupDebugExporter: Failed to remove previous snapshot.json in Documents: \(error)")
                }
            }
            // 7. Copy to Documents
            do {
                try fm.copyItem(at: sourceURL, to: destURL)
                print("✅ AppGroupDebugExporter: snapshot.json exported to Documents: \(destURL.path)")
            } catch {
                print("❌ AppGroupDebugExporter: Failed to copy snapshot.json to Documents: \(error)")
            }
        }
    }
#endif
