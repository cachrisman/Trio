//
//  TrioComplicationDataStore.swift
//  Trio Watch App Extension
//
//  Manages complication data persistence and timeline reload logic
//

import Foundation
import WidgetKit

/// Manages complication snapshot persistence and intelligent reload logic
@MainActor
final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()
    
    // MARK: - App Group Configuration
    
    private let appGroupIdentifier = "group.com.trio-app"
    private let snapshotFileName = "ComplicationSnapshot.json"
    private let historyFileName = "GlucoseHistory24h.json"
    
    private var appGroupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    private var snapshotFileURL: URL? {
        appGroupURL?.appendingPathComponent(snapshotFileName)
    }
    
    private var historyFileURL: URL? {
        appGroupURL?.appendingPathComponent(historyFileName)
    }
    
    // MARK: - State Tracking
    
    /// Last glucose value that triggered a complication reload
    private var lastReloadGlucose: String?
    
    /// Timestamp of last complication reload
    private var lastReloadTime: Date?
    
    /// Throttle interval between complication reloads (tunable)
    private var timelineReloadThrottleInterval: TimeInterval {
        UserDefaults.standard.double(forKey: "trio.watch.complication.throttleInterval").ifZero(60)
    }
    
    /// Task for backup delayed reload
    private var backupReloadTask: Task<Void, Never>?
    
    /// Flag indicating if we're in cold-start (set externally by WatchState)
    var isColdStart: Bool = false
    
    // MARK: - Snapshot Management
    
    struct ComplicationSnapshot: Codable {
        let timestamp: Date
        let currentGlucose: String
        let currentGlucoseColor: String
        let trend: String?
        let delta: String?
        let iob: String?
        let cob: String?
        let lastLoopTime: String?
        let minYAxis: Double
        let maxYAxis: Double
    }
    
    /// Saves current state snapshot for complication display
    func saveSnapshot(
        currentGlucose: String,
        currentGlucoseColor: String,
        trend: String?,
        delta: String?,
        iob: String?,
        cob: String?,
        lastLoopTime: String?,
        minYAxis: Double,
        maxYAxis: Double
    ) {
        let snapshot = ComplicationSnapshot(
            timestamp: Date(),
            currentGlucose: currentGlucose,
            currentGlucoseColor: currentGlucoseColor,
            trend: trend,
            delta: delta,
            iob: iob,
            cob: cob,
            lastLoopTime: lastLoopTime,
            minYAxis: minYAxis,
            maxYAxis: maxYAxis
        )
        
        Task {
            await WatchLogger.shared.log("📊 Saving complication snapshot: glucose=\(currentGlucose)")
        }
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            
            guard let url = snapshotFileURL else {
                Task {
                    await WatchLogger.shared.log("⚠️ App Group URL not available for snapshot save")
                }
                return
            }
            
            try data.write(to: url, options: .atomic)
            
            // Trigger intelligent reload logic
            reloadComplicationIfNeeded(newGlucose: currentGlucose)
            
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Failed to save complication snapshot: \(error)")
            }
        }
    }
    
    /// Loads the latest snapshot from disk
    func loadSnapshot() -> ComplicationSnapshot? {
        guard let url = snapshotFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(ComplicationSnapshot.self, from: data)
            return snapshot
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Failed to load complication snapshot: \(error)")
            }
            return nil
        }
    }
    
    // MARK: - Glucose History (24h)
    
    struct GlucoseHistoryEntry: Codable {
        let date: Date
        let glucose: Double
        let color: String
    }
    
    /// Saves 24-hour glucose history to App Group storage
    func saveGlucoseHistory(_ values: [(date: Date, glucose: Double, color: String)]) {
        // Filter to last 24 hours
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let filtered = values
            .filter { $0.date >= cutoff }
            .map { GlucoseHistoryEntry(date: $0.date, glucose: $0.glucose, color: $0.color) }
        
        Task {
            await WatchLogger.shared.log("📊 Saving glucose history: \(filtered.count) entries")
        }
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(filtered)
            
            guard let url = historyFileURL else {
                Task {
                    await WatchLogger.shared.log("⚠️ App Group URL not available for history save")
                }
                return
            }
            
            try data.write(to: url, options: .atomic)
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Failed to save glucose history: \(error)")
            }
        }
    }
    
    /// Loads 24-hour glucose history from disk
    func loadGlucoseHistory() -> [GlucoseHistoryEntry]? {
        guard let url = historyFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let history = try decoder.decode([GlucoseHistoryEntry].self, from: data)
            
            // Prune to 24 hours on load
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            return history.filter { $0.date >= cutoff }
        } catch {
            Task {
                await WatchLogger.shared.log("❌ Failed to load glucose history: \(error)")
            }
            return nil
        }
    }
    
    // MARK: - Intelligent Reload Logic
    
    /// Determines if complication should be reloaded based on glucose change and throttling
    private func reloadComplicationIfNeeded(newGlucose: String) {
        let shouldReload = shouldReloadComplication(newGlucose: newGlucose)
        
        if shouldReload {
            Task {
                await WatchLogger.shared.log("📊 Complication reload: IMMEDIATE (glucose changed: \(lastReloadGlucose ?? "nil") → \(newGlucose))")
            }
            
            // Immediate reload
            reloadComplicationTimeline()
            
            // Update tracking
            lastReloadGlucose = newGlucose
            lastReloadTime = Date()
            
        } else {
            Task {
                await WatchLogger.shared.log("📊 Complication reload: SCHEDULED BACKUP (+10s)")
            }
            
            // Cancel any pending backup reload
            backupReloadTask?.cancel()
            
            // Schedule backup reload after 10 seconds
            backupReloadTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                
                guard !Task.isCancelled else { return }
                
                await WatchLogger.shared.log("📊 Executing backup complication reload")
                reloadComplicationTimeline()
                lastReloadTime = Date()
            }
        }
    }
    
    /// Checks if complication should reload immediately based on glucose change
    private func shouldReloadComplication(newGlucose: String) -> Bool {
        // During cold-start, optionally throttle/delay first reload
        if isColdStart {
            Task {
                await WatchLogger.shared.log("📊 Cold-start active: throttling complication reload")
            }
            return false
        }
        
        // Check if glucose value changed
        guard let lastGlucose = lastReloadGlucose else {
            // First reload
            return true
        }
        
        // Reload if glucose changed
        if newGlucose != lastGlucose {
            return true
        }
        
        // Check throttle interval
        if let lastTime = lastReloadTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < timelineReloadThrottleInterval {
                Task {
                    await WatchLogger.shared.log("📊 Throttling: last reload \(Int(elapsed))s ago (throttle: \(Int(timelineReloadThrottleInterval))s)")
                }
                return false
            }
        }
        
        // Time-based reload (exceeded throttle interval)
        return true
    }
    
    /// Reloads all complication timelines
    private func reloadComplicationTimeline() {
        WidgetCenter.shared.reloadAllTimelines()
        
        Task {
            await WatchLogger.shared.log("📊 ✅ Reloaded all complication timelines")
        }
    }
    
    // MARK: - Manual Reload
    
    /// Forces an immediate complication reload (used for manual refresh)
    func forceReload() {
        Task {
            await WatchLogger.shared.log("📊 🔄 Force reloading complication timeline")
        }
        
        reloadComplicationTimeline()
        lastReloadTime = Date()
    }
}

// MARK: - Helper Extension

private extension Double {
    func ifZero(_ defaultValue: Double) -> Double {
        self == 0 ? defaultValue : self
    }
}
