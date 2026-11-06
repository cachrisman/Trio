import Foundation

/// Picks a predicted-glucose value at a fixed horizon across the available
/// `Determination.predictions` curves (IOB / COB / UAM / ZT).
///
/// Mirrors the multi-curve selection in the oref-swift port
/// (`ForecastGenerator.blendForecasts`) but at a single index instead of
/// across the post-peak window. The Trio determination JSON already holds
/// every curve at 5-min increments, so index 4 ≈ +20 min.
///
/// Reduction is `min` of available curves at the horizon — conservative for
/// low detection. oref-swift's own blender uses `max` because it feeds SMB
/// dosing safety; flipping to `min` for an alarm uses the same input set but
/// with the inverted intent.
enum ForecastedGlucoseEvaluator {
    static let defaultHorizonMinutes = 20

    enum Curve: String { case iob, cob, uam, zt }

    struct Result: Equatable {
        let predictedGlucose: Decimal
        let horizonMinutes: Int
        let curvesUsed: Set<Curve>
        let perCurve: [Curve: Decimal]
    }

    static func evaluate(
        determination: Determination,
        horizonMinutes: Int = defaultHorizonMinutes
    ) -> Result? {
        let index = horizonMinutes / 5
        guard let predictions = determination.predictions else { return nil }

        var samples: [Curve: Decimal] = [:]
        if let v = sample(predictions.iob, at: index) { samples[.iob] = v }
        if let v = sample(predictions.cob, at: index) { samples[.cob] = v }
        if let v = sample(predictions.uam, at: index) { samples[.uam] = v }
        if let v = sample(predictions.zt, at: index) { samples[.zt] = v }
        guard let minSample = samples.values.min() else { return nil }

        return Result(
            predictedGlucose: minSample,
            horizonMinutes: horizonMinutes,
            curvesUsed: Set(samples.keys),
            perCurve: samples
        )
    }

    struct WindowResult: Equatable {
        let lowestPredicted: Decimal
        let firstCrossingMinutes: Int?
    }

    /// Looks at every 5-min point from +5 up to the horizon (index 0 is "now" and is skipped),
    /// taking the min across curves at each point. `evaluate` only sees the last point, so a dip
    /// below the threshold at +10 that recovers by +20 was never alerted, although the settings
    /// text promises an alert "within the next 20 minutes".
    static func evaluateWindow(
        determination: Determination,
        thresholdMgDL: Decimal,
        horizonMinutes: Int = defaultHorizonMinutes
    ) -> WindowResult? {
        guard let predictions = determination.predictions else { return nil }

        var lowest: Decimal?
        var firstCrossing: Int?
        for index in 1 ... max(horizonMinutes / 5, 1) {
            let samples = [predictions.iob, predictions.cob, predictions.uam, predictions.zt]
                .compactMap { sample($0, at: index) }
            guard let pointMin = samples.min() else { continue }
            lowest = min(lowest ?? pointMin, pointMin)
            if firstCrossing == nil, pointMin <= thresholdMgDL { firstCrossing = index * 5 }
        }
        guard let lowest else { return nil }
        return WindowResult(lowestPredicted: lowest, firstCrossingMinutes: firstCrossing)
    }

    private static func sample(_ array: [Int]?, at index: Int) -> Decimal? {
        guard let array, array.indices.contains(index) else { return nil }
        return Decimal(array[index])
    }
}
