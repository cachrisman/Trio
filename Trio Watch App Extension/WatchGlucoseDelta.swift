//
//  WatchGlucoseDelta.swift
//  Trio Watch App Extension
//
//  Delta payload for efficient watch state updates
//  Shared model for watch extension
//
import Foundation

/// Delta payload sent from phone to watch containing only new/changed data
struct WatchGlucoseDelta: Codable {
    /// Monotonic sequence number for ordering deltas
    let sequenceNumber: Int
    
    /// Correlation ID for request tracing and deduplication
    let correlationId: String
    
    /// New glucose readings since last update (typically last ~6 readings)
    let newReadings: [WatchGlucoseObject]
    
    /// Current glucose value
    let currentGlucose: String?
    
    /// Current trend direction
    let trend: String?
    
    /// Current delta (change from previous reading)
    let delta: String?
    
    /// Timestamp of this delta update
    let date: Date
    
    /// IOB (Insulin on Board)
    let iob: String?
    
    /// COB (Carbs on Board)
    let cob: String?
    
    /// Last loop time
    let lastLoopTime: String?
    
    /// Y-axis min value for chart
    let minYAxisValue: Decimal?
    
    /// Y-axis max value for chart
    let maxYAxisValue: Decimal?
    
    /// Active override preset name (if changed)
    let activeOverrideName: String?
    
    /// Active temp target preset name (if changed)
    let activeTempTargetName: String?
    
    /// Manual refresh flag
    let manualRefresh: Bool
    
    /// Manual refresh request ID (for correlation)
    let manualRefreshRequestId: String?
    
    /// Full initializer
    init(
        sequenceNumber: Int,
        correlationId: String,
        newReadings: [WatchGlucoseObject],
        currentGlucose: String?,
        trend: String?,
        delta: String?,
        date: Date,
        iob: String?,
        cob: String?,
        lastLoopTime: String?,
        minYAxisValue: Decimal?,
        maxYAxisValue: Decimal?,
        activeOverrideName: String?,
        activeTempTargetName: String?,
        manualRefresh: Bool,
        manualRefreshRequestId: String?
    ) {
        self.sequenceNumber = sequenceNumber
        self.correlationId = correlationId
        self.newReadings = newReadings
        self.currentGlucose = currentGlucose
        self.trend = trend
        self.delta = delta
        self.date = date
        self.iob = iob
        self.cob = cob
        self.lastLoopTime = lastLoopTime
        self.minYAxisValue = minYAxisValue
        self.maxYAxisValue = maxYAxisValue
        self.activeOverrideName = activeOverrideName
        self.activeTempTargetName = activeTempTargetName
        self.manualRefresh = manualRefresh
        self.manualRefreshRequestId = manualRefreshRequestId
    }
    
    /// Convert delta to dictionary for WatchConnectivity
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "sequenceNumber": sequenceNumber,
            "correlationId": correlationId,
            "date": date.timeIntervalSince1970,
            "manualRefresh": manualRefresh,
            "newReadings": newReadings.map { reading in
                [
                    "date": reading.date.timeIntervalSince1970,
                    "glucose": reading.glucose,
                    "color": reading.color
                ]
            }
        ]
        
        if let currentGlucose = currentGlucose {
            dict["currentGlucose"] = currentGlucose
        }
        if let trend = trend {
            dict["trend"] = trend
        }
        if let delta = delta {
            dict["delta"] = delta
        }
        if let iob = iob {
            dict["iob"] = iob
        }
        if let cob = cob {
            dict["cob"] = cob
        }
        if let lastLoopTime = lastLoopTime {
            dict["lastLoopTime"] = lastLoopTime
        }
        if let minYAxisValue = minYAxisValue {
            dict["minYAxisValue"] = minYAxisValue
        }
        if let maxYAxisValue = maxYAxisValue {
            dict["maxYAxisValue"] = maxYAxisValue
        }
        if let activeOverrideName = activeOverrideName {
            dict["activeOverrideName"] = activeOverrideName
        }
        if let activeTempTargetName = activeTempTargetName {
            dict["activeTempTargetName"] = activeTempTargetName
        }
        if let manualRefreshRequestId = manualRefreshRequestId {
            dict["manualRefreshRequestId"] = manualRefreshRequestId
        }
        
        return dict
    }
    
    /// Create delta from dictionary
    init?(from dictionary: [String: Any]) {
        guard let sequenceNumber = dictionary["sequenceNumber"] as? Int,
              let correlationId = dictionary["correlationId"] as? String,
              let timestamp = dictionary["date"] as? TimeInterval,
              let manualRefresh = dictionary["manualRefresh"] as? Bool
        else {
            return nil
        }
        
        self.sequenceNumber = sequenceNumber
        self.correlationId = correlationId
        self.date = Date(timeIntervalSince1970: timestamp)
        self.manualRefresh = manualRefresh
        
        // Parse new readings
        if let readingsData = dictionary["newReadings"] as? [[String: Any]] {
            self.newReadings = readingsData.compactMap { data in
                guard let glucose = data["glucose"] as? Double,
                      let dateTimestamp = data["date"] as? TimeInterval,
                      let color = data["color"] as? String
                else { return nil }
                return WatchGlucoseObject(
                    date: Date(timeIntervalSince1970: dateTimestamp),
                    glucose: glucose,
                    color: color
                )
            }
        } else {
            self.newReadings = []
        }
        
        self.currentGlucose = dictionary["currentGlucose"] as? String
        self.trend = dictionary["trend"] as? String
        self.delta = dictionary["delta"] as? String
        self.iob = dictionary["iob"] as? String
        self.cob = dictionary["cob"] as? String
        self.lastLoopTime = dictionary["lastLoopTime"] as? String
        
        if let minYAxisValue = dictionary["minYAxisValue"] {
            self.minYAxisValue = (minYAxisValue as? NSNumber)?.decimalValue
        } else {
            self.minYAxisValue = nil
        }
        
        if let maxYAxisValue = dictionary["maxYAxisValue"] {
            self.maxYAxisValue = (maxYAxisValue as? NSNumber)?.decimalValue
        } else {
            self.maxYAxisValue = nil
        }
        
        self.activeOverrideName = dictionary["activeOverrideName"] as? String
        self.activeTempTargetName = dictionary["activeTempTargetName"] as? String
        self.manualRefreshRequestId = dictionary["manualRefreshRequestId"] as? String
    }
}
