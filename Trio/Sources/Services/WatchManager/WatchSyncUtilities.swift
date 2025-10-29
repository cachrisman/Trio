//
//  WatchSyncUtilities.swift
//  Trio
//
//  Utilities for watch sync: sequence tracking, correlation IDs, state hashing
//
import Foundation

/// Utilities for watch synchronization
enum WatchSyncUtilities {
    // MARK: - Sequence Number Management
    
    /// Get the next delta sequence number (phone side)
    static func nextDeltaSequenceNumber() -> Int {
        let key = "trio.iphone.deltaSequence"
        let current = UserDefaults.standard.integer(forKey: key)
        let next = current + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }
    
    /// Reset sequence number (phone side)
    static func resetDeltaSequenceNumber() {
        UserDefaults.standard.set(0, forKey: "trio.iphone.deltaSequence")
    }
    
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
    
    // MARK: - State Hash & Debouncing (Phone Side)
    
    private static let lastSentStateHashKey = "trio.iphone.lastSentStateHash"
    private static let lastSentTimestampKey = "trio.iphone.lastSentTimestamp"
    private static let debounceIntervalSeconds: TimeInterval = 30.0
    
    /// Calculate state hash for debouncing
    static func calculateStateHash(from state: WatchState) -> String {
        var hasher = Hasher()
        hasher.combine(state.date.timeIntervalSince1970)
        hasher.combine(state.currentGlucose)
        hasher.combine(state.trend)
        hasher.combine(state.delta)
        hasher.combine(state.iob)
        hasher.combine(state.cob)
        hasher.combine(state.glucoseValues.count > 0 ? state.glucoseValues.last?.date.timeIntervalSince1970 : 0)
        hasher.combine(state.activeOverrideName ?? "")
        hasher.combine(state.activeTempTargetName ?? "")
        return String(hasher.finalize())
    }
    
    /// Check if state should be sent (not debounced)
    static func shouldSendState(_ state: WatchState) -> Bool {
        let currentHash = calculateStateHash(from: state)
        let lastHash = UserDefaults.standard.string(forKey: lastSentStateHashKey)
        let lastTimestamp = UserDefaults.standard.double(forKey: lastSentTimestampKey)
        
        // If hash changed, always send
        if currentHash != lastHash {
            return true
        }
        
        // If hash is same but more than debounce interval has passed, allow send
        let timeSinceLastSend = Date().timeIntervalSince1970 - lastTimestamp
        if timeSinceLastSend >= debounceIntervalSeconds {
            return true
        }
        
        // Otherwise, skip (debounced)
        return false
    }
    
    /// Mark state as sent (update hash and timestamp)
    static func markStateAsSent(_ state: WatchState) {
        UserDefaults.standard.set(calculateStateHash(from: state), forKey: lastSentStateHashKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSentTimestampKey)
    }
    
    /// Get last sent timestamp
    static func getLastSentTimestamp() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastSentTimestampKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    
    // MARK: - Full vs Delta Decision
    
    /// Determine if should send full update or delta
    /// - Returns: true for full update, false for delta
    static func shouldSendFullUpdate(isStabilizationMode: Bool = false) -> Bool {
        // Phase A: Stabilization mode - always send full
        if isStabilizationMode {
            return true
        }
        
        // Phase B: Decision rule
        // Send full if:
        // 1. Never sent before (no last timestamp)
        // 2. Last sent > 25 minutes ago
        guard let lastSent = getLastSentTimestamp() else {
            return true // Never sent
        }
        
        let minutesSinceLastSend = Date().timeIntervalSince(lastSent) / 60.0
        return minutesSinceLastSend > 25.0
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

// MARK: - WatchState Extensions for Active Presets

extension WatchState {
    /// Get active override preset name
    var activeOverrideName: String? {
        overridePresets.first(where: { $0.isEnabled })?.name
    }
    
    /// Get active temp target preset name
    var activeTempTargetName: String? {
        tempTargetPresets.first(where: { $0.isEnabled })?.name
    }
}
