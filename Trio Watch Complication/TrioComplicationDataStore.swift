#if os(iOS)
import UIKit
#endif
#if os(iOS)
import UIKit
#endif
//
//  TrioComplicationDataStore.swift
//
//  This file defines the data store for the Trio Watch complication. It manages
//  the saving, loading, and fallback logic for the most recent complication snapshot,
//  which contains glucose, trend, delta, and timestamp data. The data store ensures
//  that the complication always displays the latest available data, and provides
//  diagnostic and debugging support, including exporting data to the iOS Documents
//  directory for inspection. The store is designed for use with an App Group so
//  that the iPhone and Watch app can share the latest snapshot for WidgetKit and
//  complication display.
//
import Foundation
/// Represents a single snapshot of glucose, trend, and delta data for the Trio Watch complication.
/// This struct is used to persist and transfer the most recent state for display in the complication.
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
    
    /// Initializes a new complication snapshot, sanitizing glucose and delta values.
    init(glucose rawGlucose: String, trend rawTrend: String, delta rawDelta: String, timestamp: Date, state: String? = nil) {
        glucose = TrioComplicationSnapshot.sanitizedGlucose(from: rawGlucose)
        trend = rawTrend.trimmingCharacters(in: .whitespacesAndNewlines)
        delta = TrioComplicationSnapshot.sanitizedDelta(from: rawDelta)
        self.timestamp = timestamp
        self.state = state
    }
    
    /// Initializes a snapshot from a dictionary, validating timestamp and extracting values.
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
    
    /// Returns the dictionary representation of this snapshot for serialization.
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
    
    /// Sanitizes the glucose string into a displayable integer or fallback.
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
    
    /// Sanitizes the delta string into a displayable signed value or fallback.
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

/// The data store for the Trio Watch complication.
/// Handles saving, loading, and fallback logic for complication snapshots,
/// and supports exporting for debugging. Uses an App Group for cross-device sharing.
final class TrioComplicationDataStore {
    /// Singleton instance of the data store.
    static let shared = TrioComplicationDataStore()
    /// The WidgetKit complication kind string.
    static let complicationKind = "TrioWatchComplication"
    /// The last valid timestamp of a successful data save or decode, for recency.
    static var lastValidTimestamp: Date?
    
    private let sharedContainerURLProvider: () -> URL?
    private let fileManager: FileManager
    private let snapshotFilename: String
    private let shouldMirrorToDocuments: Bool
    
    /// The URL for the snapshot file in the shared App Group container.
    private var snapshotFileURL: URL? {
        sharedContainerURLProvider()?.appendingPathComponent(snapshotFilename)
    }
    
    /// Creates a new data store. Parameters allow for dependency injection in tests.
    /// - Parameters:
    ///   - sharedContainerURLProvider: Closure to return the App Group container URL.
    ///   - fileManager: The file manager used for file operations.
    ///   - snapshotFilename: The filename for the complication snapshot.
    ///   - shouldMirrorToDocuments: Whether to export snapshots to Documents (iOS only).
    init(
        sharedContainerURLProvider: @escaping () -> URL? = TrioComplicationDataStore.defaultSharedContainerURL,
        fileManager: FileManager = .default,
        snapshotFilename: String = "snapshot.json",
        shouldMirrorToDocuments: Bool = true
    ) {
        self.sharedContainerURLProvider = sharedContainerURLProvider
        self.fileManager = fileManager
        self.snapshotFilename = snapshotFilename
        self.shouldMirrorToDocuments = shouldMirrorToDocuments
    }
    
    /// Saves a new complication snapshot with the given glucose, trend, delta, and timestamp.
    /// - Parameters:
    ///   - glucose: The current glucose value as a string.
    ///   - trend: The trend string (optional).
    ///   - delta: The delta string (optional).
    ///   - timestamp: The timestamp of the reading.
    func save(glucose: String, trend: String?, delta: String?, timestamp: Date) {
        let snapshot = TrioComplicationSnapshot(
            glucose: glucose,
            trend: trend ?? "",
            delta: delta ?? "",
            timestamp: timestamp
        )
        save(snapshot)
    }
    
    /// Saves the given complication snapshot to the shared container.
    /// Also updates the last valid timestamp and optionally exports for debugging.
    /// - Parameter snapshot: The snapshot to save.
    func save(_ snapshot: TrioComplicationSnapshot) {
        if let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        {
#if os(watchOS)
            Task { await WatchLogger.shared.log("✅ App Group container found: \(url.path)") }
#else
            NSLog("✅ App Group container found: \(url.path)")
#endif
        }
        
        guard let fileURL = snapshotFileURL else {
            saveDiagnosticSnapshot(message: "❌ Could not get snapshot file URL for saving.", state: "--")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(SnapshotCodable(snapshot: snapshot))
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            do {
                try data.write(to: fileURL, options: [.atomic])
                // Save last valid timestamp after successful write
                Self.lastValidTimestamp = snapshot.timestamp
#if os(watchOS)
                Task {
                    await WatchLogger.shared.log("✅ Saved complication snapshot to \(fileURL.lastPathComponent)")
                }
#endif
#if os(iOS)
                if shouldMirrorToDocuments {
                    AppGroupDebugExporter.exportSnapshotToDocuments()
                }
#endif
            } catch {
                saveDiagnosticSnapshot(message: "❌ Failed to write complication snapshot: \(error)", state: "xx")
            }
        } catch {
            saveDiagnosticSnapshot(message: "❌ Failed to encode complication snapshot: \(error)", state: "xx")
        }
    }
    
    /// Loads and returns the most recent complication snapshot, or a fallback if not available.
    /// - Returns: The latest snapshot, or a fallback with error state if loading fails.
    func latestSnapshot() -> TrioComplicationSnapshot? {
        guard let fileURL = snapshotFileURL else {
            saveDiagnosticSnapshot(message: "❌ Could not get snapshot file URL for loading.", state: "--")
            return fallbackSnapshot(state: "--")
        }
        let fileExists = fileManager.fileExists(atPath: fileURL.path)
        if !fileExists {
            saveDiagnosticSnapshot(message: "❌ Snapshot file missing at \(fileURL.path)", state: "!!")
            return fallbackSnapshot(state: "!!")
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshotCodable = try decoder.decode(SnapshotCodable.self, from: data)
            // Save last valid timestamp after successful decode
            Self.lastValidTimestamp = snapshotCodable.snapshot.timestamp
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
    
    /// Returns a fallback snapshot with error state for use when loading or saving fails.
    /// - Parameter state: The error state code to include in the snapshot.
    /// - Returns: A fallback snapshot with placeholder values.
    private func fallbackSnapshot(state: String) -> TrioComplicationSnapshot {
        TrioComplicationSnapshot(
            glucose: "--",
            trend: "",
            delta: "--",
            timestamp: Self.lastValidTimestamp ?? Date(),
            state: state
        )
    }
    
    /// Writes a diagnostic snapshot with a given message and state, and logs via WatchLogger or NSLog.
    /// Only writes the fallback snapshot if the state is "--".
    /// - Parameters:
    ///   - message: The diagnostic message to log.
    ///   - state: The error state code for the snapshot.
    private func saveDiagnosticSnapshot(message: String, state: String) {
#if os(watchOS)
        Task {
            await WatchLogger.shared.log(message)
        }
#else
        NSLog("%@", message)
#endif
        // Write a temporary fallback snapshot for clarity
        guard state == "--", let fileURL = snapshotFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let diagnostic = TrioComplicationSnapshot(
                glucose: "--",
                trend: "",
                delta: "--",
                timestamp: Date(),
                state: state
            )
            let data = try encoder.encode(SnapshotCodable(snapshot: diagnostic))
            try? data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore further errors here
        }
    }
    
#if canImport(WidgetKit)
    /// Reloads the WidgetKit complication timeline for the Trio complication.
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
    
    /// Returns the default App Group container URL, using the AppGroupID from Info.plist.
    /// - Returns: The App Group URL, or nil if not available.
    private static func defaultSharedContainerURL() -> URL? {
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

/// Codable wrapper for TrioComplicationSnapshot for compatibility and
/// to allow for future extensibility or legacy bridging.
private struct SnapshotCodable: Codable {
    /// The underlying snapshot.
    let snapshot: TrioComplicationSnapshot
    
    /// Creates a wrapper from a snapshot.
    init(snapshot: TrioComplicationSnapshot) {
        self.snapshot = snapshot
    }
    
    /// Decodes the snapshot from a single value container.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        snapshot = try container.decode(TrioComplicationSnapshot.self)
    }
    
    /// Encodes the snapshot into a single value container.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(snapshot)
    }
}

#if os(iOS)
/// Utility for exporting complication snapshots from the App Group to the iOS Documents directory for debugging.
enum AppGroupDebugExporter {
    /// The name of the export folder inside Documents.
    private static let exportFolderName = "WatchComplicationData"
    
    /// Ensures the WatchComplicationData folder exists in Documents.
    static func ensureDocumentsFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ AppGroupDebugExporter: Could not resolve Documents directory.")
            return
        }
        let exportFolder = documentsURL.appendingPathComponent(exportFolderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportFolder.path) {
            do {
                try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)
                let keepURL = exportFolder.appendingPathComponent(".keep")
                fm.createFile(atPath: keepURL.path, contents: Data())
            } catch {
                print("❌ AppGroupDebugExporter: Failed to create \(exportFolderName) folder in Documents: \(error)")
            }
        }
    }
    
    /// Generates a timestamped filename for the exported snapshot, e.g. "snapshot_2025-10-11_23-59-59.json"
    /// - Returns: The filename for the exported snapshot.
    static func makeTimestampedFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let now = Date()
        var iso = formatter.string(from: now)
        // Replace forbidden filename characters (":" and ".") with safe ones
        iso = iso.replacingOccurrences(of: ":", with: "-")
        iso = iso.replacingOccurrences(of: ".", with: "-")
        // Optionally replace T and Z for clarity
        iso = iso.replacingOccurrences(of: "T", with: "_")
        iso = iso.replacingOccurrences(of: "Z", with: "")
        return "snapshot_\(iso).json"
    }
    
    /// Copies the App Group snapshot.json file to the iPhone’s Documents directory for inspection via Files app.
    static func exportSnapshotToDocuments() {
        ensureDocumentsFolder()
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
        let exportFolder = documentsURL.appendingPathComponent(exportFolderName, isDirectory: true)
        let timestampedFilename = makeTimestampedFilename()
        let destURL = exportFolder.appendingPathComponent(timestampedFilename)
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportFolder.path) {
            do {
                try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)
                let keepURL = exportFolder.appendingPathComponent(".keep")
                fm.createFile(atPath: keepURL.path, contents: Data())
            } catch {
                print("❌ AppGroupDebugExporter: Failed to create \(exportFolderName) folder in Documents: \(error)")
            }
        }
        // 5. Check if source exists
        guard fm.fileExists(atPath: sourceURL.path) else {
            print("❌ AppGroupDebugExporter: No snapshot.json found at \(sourceURL.path)")
            return
        }
        // 6. Copy to Documents with timestamped filename
        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            print("✅ AppGroupDebugExporter: snapshot exported to Documents/\(exportFolderName): \(destURL.lastPathComponent)")
        } catch {
            print("❌ AppGroupDebugExporter: Failed to copy snapshot to Documents: \(error)")
        }
    }
}
#endif
