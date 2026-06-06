enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date" // ⚠️ BUILD TIME, not CGM reading time — use readingEpoch for CGM timestamp
    static let units = "units"
    static let requestWatchUpdate = "requestWatchUpdate"
    static let watchState = "watchState"
    static let acknowledged = "acknowledged"
    static let ackCode = "ackCode"
    static let message = "message"

    // Treatment Keys
    static let bolus = "bolus"
    static let carbs = "carbs"
    static let cancelBolus = "cancelBolus"
    static let bolusCanceled = "bolusCanceled"
    static let bolusProgress = "bolusProgress"
    static let activeBolusAmount = "activeBolusAmount"
    static let deliveredAmount = "deliveredAmount"
    static let bolusProgressTimestamp = "bolusProgressTimestamp"

    // Recommendation Keys
    static let requestBolusRecommendation = "requestBolusRecommendation"
    static let recommendedBolus = "recommendedBolus"

    // Override Keys
    static let cancelOverride = "cancelOverride"
    static let activateOverride = "activateOverride"

    // Temp Target Keys
    static let cancelTempTarget = "cancelTempTarget"
    static let activateTempTarget = "activateTempTarget"

    // Watch State Data Keys
    static let currentGlucose = "currentGlucose"
    static let currentGlucoseColorString = "currentGlucoseColorString"
    static let trend = "trend"
    static let delta = "delta"
    static let iob = "iob"
    static let cob = "cob"
    static let lastLoopTime = "lastLoopTime"
    static let glucoseValues = "glucoseValues"
    static let minYAxisValue = "minYAxisValue"
    static let maxYAxisValue = "maxYAxisValue"
    static let overridePresets = "overridePresets"
    static let tempTargetPresets = "tempTargetPresets"

    // Glucose color settings (build 205 / W5 + P2): canonical INTEGER mg/dL thresholds so the watch
    // computes colors locally and the payload no longer carries per-reading color strings.
    static let lowGlucoseThreshold = "low_glucose_threshold" // Int, mg/dL
    static let highGlucoseThreshold = "high_glucose_threshold" // Int, mg/dL
    static let glucoseTarget = "glucose_target" // Int, mg/dL
    static let glucoseColorSchemeDynamic = "glucose_color_dynamic" // Bool
    static let currentGlucoseMgDl = "current_glucose_mgdl" // Int, mg/dL (for bubble color)

    // Transfer Metadata Keys
    static let readingEpoch = "reading_epoch"
    /// G7 EGV sequence (same-reading identity with watch direct BLE); optional.
    static let g7Sequence = "g7_sequence"
    /// G7 peripheral/sensor name for `G7WatchSensorAdapter`; empty string means clear (sent whenever key is present).
    static let g7ActiveSensorName = "g7_active_sensor_name"
    /// G7 sensor activation epoch as Int64 seconds; pairs with `g7ActiveSensorName` for sensor identity (build 205 / C2).
    static let g7ActivationEpoch = "g7_activation_epoch"
    static let transferEnqueuedAt = "transfer_enqueued_at"

    // Limits and Settings Keys
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let maxFat = "maxFat"
    static let maxProtein = "maxProtein"
    static let bolusIncrement = "bolusIncrement"
    static let confirmBolusFaster = "confirmBolusFaster"

    // Notification Actions
    static let snoozeDuration = "snoozeDuration"
}
