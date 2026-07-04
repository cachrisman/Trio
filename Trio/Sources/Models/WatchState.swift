import Foundation
import SwiftUI

struct WatchState: Hashable, Equatable, Sendable, Encodable, Decodable {
    var date: Date
    var currentGlucose: String?
    /// Upstream field, no longer populated/sent (build 205 / P2) — the watch computes color locally.
    var currentGlucoseColorString: String?
    /// Canonical mg/dL of the current reading (build 205 / P2), so the watch can compute the bubble color.
    var currentGlucoseMgDl: Int?
    var trend: String?
    var delta: String?
    var glucoseValues: [WatchGlucoseObject] = []
    var minYAxisValue: Decimal = 39.0
    var maxYAxisValue: Decimal = 200.0
    var units: GlucoseUnits = .mgdL
    var iob: String?
    var cob: String?
    var lastLoopTime: String?
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []

    // Safety limits
    var maxBolus: Decimal = 10.0
    var maxCarbs: Decimal = 250.0
    var maxFat: Decimal = 250.0
    var maxProtein: Decimal = 250.0

    // Pump specific dosing increment
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    /// G7 EGV sequence when the active CGM is G7 and it matches `latestGlucose`; watch attribution only.
    var g7Sequence: Int?

    /// G7 peripheral name from the active `G7CGMManager` when applicable; `nil` encodes as empty over WC.
    var g7ActiveSensorName: String?
    /// G7 sensor activation epoch (Int64 seconds) pairing with `g7ActiveSensorName` for identity (build 205 / C2); 0 = none.
    var g7ActivationEpoch: Int64 = 0

    static func == (lhs: WatchState, rhs: WatchState) -> Bool {
        lhs.date == rhs.date &&
            lhs.currentGlucose == rhs.currentGlucose &&
            lhs.currentGlucoseMgDl == rhs.currentGlucoseMgDl &&
            lhs.trend == rhs.trend &&
            lhs.delta == rhs.delta &&
            lhs.glucoseValues.count == rhs.glucoseValues.count &&
            zip(lhs.glucoseValues, rhs.glucoseValues).allSatisfy {
                $0.0.date == $0.1.date && $0.0.glucose == $0.1.glucose
            } &&
            lhs.minYAxisValue == rhs.minYAxisValue &&
            lhs.maxYAxisValue == rhs.maxYAxisValue &&
            lhs.units == rhs.units &&
            lhs.iob == rhs.iob &&
            lhs.cob == rhs.cob &&
            lhs.lastLoopTime == rhs.lastLoopTime &&
            lhs.overridePresets == rhs.overridePresets &&
            lhs.tempTargetPresets == rhs.tempTargetPresets &&
            lhs.maxBolus == rhs.maxBolus &&
            lhs.maxCarbs == rhs.maxCarbs &&
            lhs.maxFat == rhs.maxFat &&
            lhs.maxProtein == rhs.maxProtein &&
            lhs.bolusIncrement == rhs.bolusIncrement &&
            lhs.confirmBolusFaster == rhs.confirmBolusFaster &&
            lhs.g7Sequence == rhs.g7Sequence &&
            lhs.g7ActiveSensorName == rhs.g7ActiveSensorName &&
            lhs.g7ActivationEpoch == rhs.g7ActivationEpoch
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(currentGlucose)
        hasher.combine(currentGlucoseMgDl)
        hasher.combine(trend)
        hasher.combine(delta)
        for value in glucoseValues {
            hasher.combine(value.date)
            hasher.combine(value.glucose)
        }
        hasher.combine(minYAxisValue)
        hasher.combine(maxYAxisValue)
        hasher.combine(units)
        hasher.combine(iob)
        hasher.combine(cob)
        hasher.combine(lastLoopTime)
        hasher.combine(overridePresets)
        hasher.combine(tempTargetPresets)
        hasher.combine(maxBolus)
        hasher.combine(maxCarbs)
        hasher.combine(maxFat)
        hasher.combine(maxProtein)
        hasher.combine(bolusIncrement)
        hasher.combine(confirmBolusFaster)
        hasher.combine(g7Sequence)
        hasher.combine(g7ActiveSensorName)
        hasher.combine(g7ActivationEpoch)
    }
}
