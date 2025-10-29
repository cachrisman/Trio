import Foundation

struct WatchGlucoseDelta {
    let sequenceNumber: Int
    let correlationId: String
    let date: Date
    let currentGlucose: String
    let trend: String
    let delta: String
    let iob: String?
    let cob: String?
    let lastLoopTime: String?
    let minYAxisValue: Decimal
    let maxYAxisValue: Decimal
    let activeOverrideName: String?
    let activeTempTargetName: String?
    let newReadings: [Reading]

    struct Reading {
        let date: Date
        let glucose: Double
        let colorHex: String

        func toDictionary() -> [String: Any] {
            [
                "date": date.timeIntervalSince1970,
                "glucose": glucose,
                "color": colorHex
            ]
        }
    }

    func toDictionary() -> [String: Any] {
        [
            WatchMessageKeys.sequenceNumber: sequenceNumber,
            WatchMessageKeys.correlationId: correlationId,
            WatchMessageKeys.date: date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: currentGlucose,
            WatchMessageKeys.trend: trend,
            WatchMessageKeys.delta: delta,
            WatchMessageKeys.iob: iob as Any,
            WatchMessageKeys.cob: cob as Any,
            WatchMessageKeys.lastLoopTime: lastLoopTime as Any,
            WatchMessageKeys.minYAxisValue: minYAxisValue,
            WatchMessageKeys.maxYAxisValue: maxYAxisValue,
            WatchMessageKeys.activeOverrideName: activeOverrideName as Any,
            WatchMessageKeys.activeTempTargetName: activeTempTargetName as Any,
            WatchMessageKeys.newReadings: newReadings.map { $0.toDictionary() }
        ]
    }
}
