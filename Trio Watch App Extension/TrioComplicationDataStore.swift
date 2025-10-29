//
//  TrioComplicationDataStore.swift
//  Trio Watch App Extension
//
//  Manages snapshot persistence and glucose-change detection for WidgetKit complication reload
//
import Foundation
import WidgetKit

/// Manages complication snapshot data persistence in App Group
enum TrioComplicationDataStore {
    /// App Group identifier (should match Info.plist)
    private static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }
    
    /// UserDefaults for App Group
    private static var sharedDefaults: UserDefaults? {
        guard let suiteName = appGroupIdentifier else { return nil }
        return UserDefaults(suiteName: suiteName)
    }
    
    /// File URL for snapshot JSON in App Group container
    private static var snapshotFileURL: URL? {
        guard let suiteName = appGroupIdentifier,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        else { return nil }
        
        return containerURL.appendingPathComponent("complication_snapshot.json")
    }
    
    /// File URL for glucose history JSON (24 hours)
    private static var historyFileURL: URL? {
        guard let suiteName = appGroupIdentifier,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        else { return nil }
        
        return containerURL.appendingPathComponent("complication_glucose_history.json")
    }
    
    // MARK: - Snapshot Management
    
    /// Save snapshot JSON for WidgetKit
    static func saveSnapshot(_ snapshot: [String: Any]) {
        guard let url = snapshotFileURL else {
            Task {
                await WatchLogger.shared.log("⚠️ Cannot save snapshot - no App Group URL")
            }
            return
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: snapshot, options: .prettyPrinted)
            try jsonData.write(to: url)
            Task {
                await WatchLogger.shared.log("✅ Saved complication snapshot")
            }
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Error saving snapshot: \(error)")
            }
        }
    }
    
    /// Load snapshot JSON
    static func loadSnapshot() -> [String: Any]? {
        guard let url = snapshotFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        
        return json
    }
    
    /// Get last glucose value from snapshot
    static func getLastGlucose() -> String? {
        guard let snapshot = loadSnapshot(),
              let currentGlucose = snapshot[WatchMessageKeys.currentGlucose] as? String
        else {
            return nil
        }
        
        return currentGlucose
    }
    
    // MARK: - Glucose Change Detection
    
    /// Check if glucose has changed compared to last snapshot
    static func hasGlucoseChanged(newGlucose: String?) -> Bool {
        let lastGlucose = getLastGlucose()
        
        // If no previous glucose, consider it changed
        guard let previous = lastGlucose else {
            return newGlucose != nil
        }
        
        // Compare current with previous
        return newGlucose != previous
    }
    
    // MARK: - Timeline Reload
    
    /// Reload complication timelines with throttling
    static func reloadTimelines(
        for family: WidgetFamily? = nil,
        throttleInterval: TimeInterval = 60.0,
        isColdStart: Bool = false
    ) {
        // Throttle during cold start
        if isColdStart {
            // Delay first reload slightly during cold start
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                WidgetCenter.shared.reloadTimelines(ofKind: "TrioWatchComplication")
                Task {
                    await WatchLogger.shared.log("🔄 Reloaded complication timeline (delayed for cold start)")
                }
            }
            return
        }
        
        // Normal reload - check throttle
        let lastReloadKey = "trio.complication.lastReloadTimestamp"
        let sharedDefaults = self.sharedDefaults
        
        if let lastReloadTimestamp = sharedDefaults?.double(forKey: lastReloadKey) {
            let timeSinceLastReload = Date().timeIntervalSince1970 - lastReloadTimestamp
            
            if timeSinceLastReload < throttleInterval {
                Task {
                    await WatchLogger.shared.log("⏸️ Skipping complication reload - throttled (\(Int(timeSinceLastReload))s < \(Int(throttleInterval))s)")
                }
                
                // Schedule backup reload if needed
                scheduleBackupReload(family: family)
                return
            }
        }
        
        // Perform reload
        WidgetCenter.shared.reloadTimelines(ofKind: "TrioWatchComplication")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: lastReloadKey)
        
        Task {
            await WatchLogger.shared.log("🔄 Reloaded complication timeline")
        }
        
        // Schedule backup reload
        scheduleBackupReload(family: family)
    }
    
    /// Schedule a backup reload after delay (default 10 seconds)
    private static func scheduleBackupReload(family: WidgetFamily?, delay: TimeInterval = 10.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            WidgetCenter.shared.reloadTimelines(ofKind: "TrioWatchComplication")
            Task {
                await WatchLogger.shared.log("🔄 Backup complication reload executed")
            }
        }
    }
    
    // MARK: - Glucose History Management (24 hours)
    
    /// Save glucose history for 24-hour chart
    static func saveGlucoseHistory(_ values: [WatchGlucoseObject]) {
        guard let url = historyFileURL else { return }
        
        // Filter to last 24 hours
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60)
        let recentValues = values.filter { $0.date >= cutoffDate }
        
        // Convert to JSON-serializable format
        let historyData = recentValues.map { value in
            [
                "date": value.date.timeIntervalSince1970,
                "glucose": value.glucose,
                "color": value.color
            ]
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: historyData, options: .prettyPrinted)
            try jsonData.write(to: url)
            Task {
                await WatchLogger.shared.log("✅ Saved glucose history (\(recentValues.count) values)")
            }
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Error saving glucose history: \(error)")
            }
        }
    }
    
    /// Load glucose history
    static func loadGlucoseHistory() -> [WatchGlucoseObject] {
        guard let url = historyFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let historyData = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        
        // Filter to last 24 hours
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60)
        
        return historyData.compactMap { data in
            guard let glucose = data["glucose"] as? Double,
                  let dateTimestamp = data["date"] as? TimeInterval,
                  let color = data["color"] as? String
            else { return nil }
            
            let date = Date(timeIntervalSince1970: dateTimestamp)
            guard date >= cutoffDate else { return nil }
            
            return WatchGlucoseObject(date: date, glucose: glucose, color: color)
        }
        .sorted { $0.date < $1.date }
    }
    
    /// Prune history older than 24 hours
    static func pruneHistory() {
        let history = loadGlucoseHistory()
        saveGlucoseHistory(history) // Re-save filters automatically
    }
}
