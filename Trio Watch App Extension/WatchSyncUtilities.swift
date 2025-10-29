//
//  WatchSyncUtilities.swift
//  Trio Watch App Extension
//
//  Utilities for watch synchronization (watch extension version)
//
import Foundation

/// Utilities for watch synchronization (watch side)
enum WatchSyncUtilities {
    // MARK: - Sequence Number Management
    
    /// Get last processed sequence number (watch side)
    static func getLastProcessedSequence() -> Int {
        UserDefaults.standard.integer(forKey: "trio.watch.lastProcessedSequence")
    }
    
    /// Set last processed sequence number (watch side)
    static func setLastProcessedSequence(_ sequence: Int) {
        UserDefaults.standard.set(sequence, forKey: "trio.watch.lastProcessedSequence")
    }
    
    /// Reset last processed sequence number (watch side)
    static func resetLastProcessedSequence() {
        UserDefaults.standard.set(0, forKey: "trio.watch.lastProcessedSequence")
    }
    
    // MARK: - Correlation ID Management
    
    /// Generate a new correlation ID
    static func generateCorrelationId() -> String {
        UUID().uuidString
    }
    
    /// Track seen correlation IDs for deduplication (ring buffer, size ~50)
    private static let correlationIdsKey = "trio.watch.seenCorrelationIds"
    private static let maxCorrelationIds = 50
    
    /// Check if correlation ID has been seen (and add it)
    static func isCorrelationIdSeen(_ id: String) -> Bool {
        var seenIds = Set<String>(
            UserDefaults.standard.stringArray(forKey: correlationIdsKey) ?? []
        )
        
        if seenIds.contains(id) {
            return true
        }
        
        // Add to seen set
        seenIds.insert(id)
        
        // Maintain ring buffer size
        if seenIds.count > maxCorrelationIds {
            let sortedArray = Array(seenIds).sorted(by: >)
            seenIds = Set(sortedArray.prefix(maxCorrelationIds))
        }
        
        UserDefaults.standard.set(Array(seenIds), forKey: correlationIdsKey)
        return false
    }
    
    /// Clear correlation ID tracking
    static func clearCorrelationIds() {
        UserDefaults.standard.removeObject(forKey: correlationIdsKey)
    }
    
    // MARK: - Watch Cold Start Detection
    
    private static let processStartTimeKey = "trio.watch.processStartTime"
    
    /// Mark process start time (called on app launch)
    static func markProcessStart() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: processStartTimeKey)
    }
    
    /// Check if we're in cold start window (default 60 seconds)
    static func isColdStart(withinSeconds seconds: Double = 60.0) -> Bool {
        let startTime = UserDefaults.standard.double(forKey: processStartTimeKey)
        guard startTime > 0 else {
            // No start time recorded, assume cold start
            markProcessStart()
            return true
        }
        
        let elapsed = Date().timeIntervalSince1970 - startTime
        return elapsed < seconds
    }
    
    /// Clear cold start state (force exit)
    static func clearColdStart() {
        UserDefaults.standard.removeObject(forKey: processStartTimeKey)
    }
    
    // MARK: - Staleness Check
    
    /// Check if last update is stale (>25 minutes)
    static func isLastUpdateStale() -> Bool {
        let lastUpdate = WatchStateSnapshot.loadLatestDateFromDisk()
        let minutesSinceUpdate = Date().timeIntervalSince(lastUpdate) / 60.0
        return minutesSinceUpdate > 25.0
    }
}
