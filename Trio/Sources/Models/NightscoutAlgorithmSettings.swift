import Foundation

struct NightscoutAlgorithmSettings: Codable {
    // Meta
    let schemaVersion: Int? // = 1
    let algorithmVersion: String?
    let units: String? // "mg/dL" or "mmol/L"
    let preferencesTimestamp: Date?

    // Loop & SMB/UAM
    let closedLoop: Bool?
    let enableUAM: Bool?
    let enableSMBAlways: Bool?
    let enableSMBWithCOB: Bool?
    let enableSMBAfterCarbs: Bool?
    let enableSMBWithTemptarget: Bool?
    let allowSMBWithHighTemptarget: Bool?
    let enableSMB_high_bg: Bool?
    let enableSMB_high_bg_target: Decimal?
    let smbDeliveryRatio: Decimal?
    let smbInterval: Decimal?
    let maxSMBBasalMinutes: Decimal?
    let maxUAMSMBBasalMinutes: Decimal?

    // Sensitivity / targets
    let autosensMax: Decimal?
    let autosensMin: Decimal?
    let rewindResetsAutosens: Bool?
    let highTemptargetRaisesSensitivity: Bool?
    let lowTemptargetLowersSensitivity: Bool?
    let sensitivityRaisesTarget: Bool?
    let resistanceLowersTarget: Bool?
    let advTargetAdjustments: Bool?
    let wideBGTargetRange: Bool?
    let a52RiskEnable: Bool?

    // Safety rails
    let maxIOB: Decimal?
    let maxCOB: Decimal?
    let maxDailySafetyMultiplier: Decimal?
    let currentBasalSafetyMultiplier: Decimal?

    // Insulin model
    let curve: String? // Preferences.InsulinCurve rawValue
    let useCustomPeakTime: Bool?
    let insulinPeakTime: Decimal?
    let insulinActionCurve: Decimal? // Pump reality
    let bolusIncrement: Decimal?

    // Exercise / temp targets
    let exerciseMode: Bool?
    let halfBasalExerciseTarget: Decimal?

    // Carb absorption / UAM
    let maxMealAbsorptionTime: Decimal?
    let min5mCarbimpact: Decimal?
    let remainingCarbsFraction: Decimal?
    let remainingCarbsCap: Decimal?

    // Heuristics & advanced math
    let adjustmentFactor: Decimal?
    let adjustmentFactorSigmoid: Decimal?
    let sigmoid: Bool?
    let useNewFormula: Bool?
    let useWeightedAverage: Bool?
    let weightPercentage: Decimal?
    let tddAdjBasal: Bool?
    let updateInterval: Decimal?
    let maxDeltaBGthreshold: Decimal?
    let noisyCGMTargetMultiplier: Decimal?
    let carbsReqThreshold: Decimal?
    let threshold_setting: Decimal?
    let suspendZerosIOB: Bool?
    let unsuspendIfNoTemp: Bool?
    let skipNeutralTemps: Bool?
    let autotuneISFAdjustmentFraction: Decimal?

    // Food processing helpers
    let useFPUconversion: Bool?
    let fattyMeals: Bool?
    let fattyMealFactor: Decimal?
    let sweetMeals: Bool?
    let sweetMealFactor: Decimal?
    let overrideFactor: Decimal?
    let individualAdjustmentFactor: Decimal?
    let timeCap: Decimal?
    let minuteInterval: Decimal?
    let delay: Decimal?

    // Pump hard limits
    let maxBolus: Decimal?
    let maxBasal: Decimal?
}
