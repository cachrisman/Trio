//
//  WatchGlucoseDelta.swift
//  Trio
//
//  Delta update payload for efficient watch synchronization
//

import Foundation

/// Delta update containing only changed/new data since last full state
struct WatchGlucoseDelta: Hashable, Equatable, Sendable, Encodable, Decodable {
    /// Monotonic sequence number for delta ordering
    let sequenceNumber: Int
    
    /// Unique correlation ID for deduplication
    let correlationId: String
    
    /// New glucose readings since last update (typically last 6)
    let newReadings: [WatchGlucoseObject]
    
    /// Current glucose display value
    let currentGlucose: String?
    
    /// Current trend arrow
    let trend: String?
    
    /// Delta from previous reading
    let delta: String?
    
    /// Timestamp of this update
    let date: Date
    
    /// Current IOB
    let iob: String?
    
    /// Current COB
    let cob: String?
    
    /// Last loop time
    let lastLoopTime: String?
    
    /// Current glucose color
    let currentGlucoseColorString: String?
    
    /// Y-axis range (may change based on readings)
    let minYAxisValue: Decimal?
    let maxYAxisValue: Decimal?
    
    /// Active override name (if changed)
    let activeOverrideName: String?
    
    /// Active temp target name (if changed)
    let activeTempTargetName: String?
    
    /// Flag indicating this is a manual refresh response
    let manualRefresh: Bool
    
    /// Original request ID if responding to manual refresh
    let manualRefreshRequestId: String?
    
    /// Creates a delta update from current and previous state
    static func create(
        from currentState: WatchState,
        previousState: WatchState?,
        sequenceNumber: Int,
        correlationId: String = UUID().uuidString,
        manualRefresh: Bool = false,
        manualRefreshRequestId: String? = nil
    ) -> WatchGlucoseDelta {
        // Get new readings (last 6 or all if no previous state)
        let previousGlucoseCount = previousState?.glucoseValues.count ?? 0
        let newReadings = currentState.glucoseValues.suffix(min(6, currentState.glucoseValues.count - previousGlucoseCount))
        
        // Determine active override name
        let activeOverride = currentState.overridePresets.first { $0.isEnabled }
        let activeOverrideName = activeOverride?.name
        
        // Determine active temp target name
        let activeTempTarget = currentState.tempTargetPresets.first { $0.isEnabled }
        let activeTempTargetName = activeTempTarget?.name
        
        return WatchGlucoseDelta(
            sequenceNumber: sequenceNumber,
            correlationId: correlationId,
            newReadings: Array(newReadings),
            currentGlucose: currentState.currentGlucose,
            trend: currentState.trend,
            delta: currentState.delta,
            date: currentState.date,
            iob: currentState.iob,
            cob: currentState.cob,
            lastLoopTime: currentState.lastLoopTime,
            currentGlucoseColorString: currentState.currentGlucoseColorString,
            minYAxisValue: currentState.minYAxisValue,
            maxYAxisValue: currentState.maxYAxisValue,
            activeOverrideName: activeOverrideName,
            activeTempTargetName: activeTempTargetName,
            manualRefresh: manualRefresh,
            manualRefreshRequestId: manualRefreshRequestId
        )
    }
}
