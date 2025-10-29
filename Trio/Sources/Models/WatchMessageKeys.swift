enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date"
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

    // Delta Update Keys
    static let watchStateDelta = "watchStateDelta"
    static let sequenceNumber = "sequenceNumber"
    static let correlationId = "correlationId"
    static let lastProcessedSequence = "lastProcessedSequence"
    static let activeOverrideName = "activeOverrideName"
    static let activeTempTargetName = "activeTempTargetName"
    static let manualRefresh = "manualRefresh"
    static let manualRefreshRequestId = "manualRefreshRequestId"
    static let requestFullRefresh = "requestFullRefresh"

    // Control Message Keys
    static let action = "action"
    static let presetName = "presetName"
    static let startOverride = "startOverride"
    static let startTempTarget = "startTempTarget"
    static let cancelOverride = "cancelOverride"
    static let cancelTempTargetAction = "cancelTempTarget"

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

    // Limits and Settings Keys
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let maxFat = "maxFat"
    static let maxProtein = "maxProtein"
    static let bolusIncrement = "bolusIncrement"
    static let confirmBolusFaster = "confirmBolusFaster"
}
