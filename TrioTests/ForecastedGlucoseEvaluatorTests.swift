import Foundation
import Testing

@testable import Trio

@Suite("Trio Alerts: ForecastedGlucoseEvaluator") struct ForecastedGlucoseEvaluatorTests {
    /// Builds a `Determination` defaulting every non-predictions field, varying only `predictions`.
    private func makeDetermination(predictions: Predictions?) -> Determination {
        Determination(
            id: nil,
            reason: "",
            units: nil,
            insulinReq: nil,
            eventualBG: nil,
            sensitivityRatio: nil,
            rate: nil,
            duration: nil,
            iob: nil,
            cob: nil,
            predictions: predictions,
            deliverAt: nil,
            carbsReq: nil,
            temp: nil,
            bg: nil,
            reservoir: nil,
            isf: nil,
            timestamp: nil,
            tdd: nil,
            current_target: nil,
            minDelta: nil,
            expectedDelta: nil,
            minGuardBG: nil,
            minPredBG: nil,
            threshold: nil,
            carbRatio: nil,
            received: nil
        )
    }

    @Test("Reduces to min across all four curves at default horizon (+20min, index 4)") func minAcrossAllFourCurves() {
        let predictions = Predictions(
            iob: [100, 101, 102, 103, 104],
            zt: [130, 131, 132, 133, 99],
            cob: [110, 111, 112, 113, 90],
            uam: [120, 121, 122, 123, 95]
        )
        let determination = makeDetermination(predictions: predictions)

        let result = ForecastedGlucoseEvaluator.evaluate(determination: determination)
        #expect(result != nil)
        #expect(result?.predictedGlucose == Decimal(90))
        #expect(result?.horizonMinutes == 20)
        #expect(result?.curvesUsed == Set([.iob, .cob, .uam, .zt]))
        #expect(result?.perCurve[.iob] == Decimal(104))
        #expect(result?.perCurve[.cob] == Decimal(90))
        #expect(result?.perCurve[.uam] == Decimal(95))
        #expect(result?.perCurve[.zt] == Decimal(99))
    }

    @Test("nil predictions returns nil") func nilPredictionsReturnsNil() {
        let determination = makeDetermination(predictions: nil)
        #expect(ForecastedGlucoseEvaluator.evaluate(determination: determination) == nil)
    }

    @Test("All curves shorter than the horizon index returns nil") func indexOutOfBoundsAllShortReturnsNil() {
        let predictions = Predictions(
            iob: [100, 101, 102],
            zt: [130, 131, 132],
            cob: [110, 111, 112],
            uam: [120, 121, 122]
        )
        let determination = makeDetermination(predictions: predictions)
        #expect(ForecastedGlucoseEvaluator.evaluate(determination: determination) == nil)
    }

    @Test("Only one populated curve is used") func onlyOneCurvePopulated() {
        let predictions = Predictions(
            iob: [80, 81, 82, 83, 84],
            zt: nil,
            cob: nil,
            uam: nil
        )
        let determination = makeDetermination(predictions: predictions)

        let result = ForecastedGlucoseEvaluator.evaluate(determination: determination)
        #expect(result != nil)
        #expect(result?.predictedGlucose == Decimal(84))
        #expect(result?.curvesUsed == Set([.iob]))
    }

    @Test("Non-default horizon selects the matching index") func nonDefaultHorizonSelectsCorrectIndex() {
        let predictions = Predictions(
            iob: [100, 90, 80, 70],
            zt: nil,
            cob: [105, 95, 85, 75],
            uam: nil
        )
        let determination = makeDetermination(predictions: predictions)

        let result = ForecastedGlucoseEvaluator.evaluate(determination: determination, horizonMinutes: 10)
        #expect(result != nil)
        #expect(result?.predictedGlucose == Decimal(80))
        #expect(result?.curvesUsed == Set([.iob, .cob]))
        #expect(result?.horizonMinutes == 10)
    }

    @Test("Curves with differing lengths skip those missing the index") func differingLengthsSomeMissing() {
        let predictions = Predictions(
            iob: [100, 101, 102, 103, 104],
            zt: [130, 131, 132],
            cob: [110, 111],
            uam: [120, 121, 122, 123, 70]
        )
        let determination = makeDetermination(predictions: predictions)

        let result = ForecastedGlucoseEvaluator.evaluate(determination: determination)
        #expect(result != nil)
        #expect(result?.predictedGlucose == Decimal(70))
        #expect(result?.curvesUsed == Set([.iob, .uam]))
    }

    @Test("All-empty arrays return nil") func emptyArraysReturnNil() {
        let predictions = Predictions(iob: [], zt: [], cob: [], uam: [])
        let determination = makeDetermination(predictions: predictions)
        #expect(ForecastedGlucoseEvaluator.evaluate(determination: determination) == nil)
    }

    @Test("Window: a dip at +10 that recovers by +20 is caught") func windowCatchesRecoveredDip() {
        let predictions = Predictions(iob: [100, 90, 70, 85, 100], zt: nil, cob: nil, uam: nil)
        let result = ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: predictions), thresholdMgDL: 72
        )
        #expect(result?.lowestPredicted == Decimal(70))
        #expect(result?.firstCrossingMinutes == 10)
    }

    @Test("Window: no point at or below the threshold has no crossing") func windowNoCrossing() {
        let predictions = Predictions(iob: [100, 95, 90, 85, 80], zt: nil, cob: nil, uam: nil)
        let result = ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: predictions), thresholdMgDL: 72
        )
        #expect(result?.lowestPredicted == Decimal(80))
        #expect(result?.firstCrossingMinutes == nil)
    }

    @Test("Window: the lowest value is the minimum across curves and points") func windowMinimum() {
        let predictions = Predictions(
            iob: [100, 90, 80, 85, 95], zt: [100, 95, 92, 60, 99], cob: [100, 85, 88, 90, 91], uam: nil
        )
        let result = ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: predictions), thresholdMgDL: 62
        )
        #expect(result?.lowestPredicted == Decimal(60))
        #expect(result?.firstCrossingMinutes == 15)
    }

    @Test("Window: index 0 (now) is ignored") func windowIgnoresNow() {
        let predictions = Predictions(iob: [40, 90, 95, 100, 105], zt: nil, cob: nil, uam: nil)
        let result = ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: predictions), thresholdMgDL: 72
        )
        #expect(result?.lowestPredicted == Decimal(90))
        #expect(result?.firstCrossingMinutes == nil)
    }

    @Test("Window: curves of differing lengths use what each has") func windowDifferingLengths() {
        let predictions = Predictions(iob: [100, 95], zt: [100, 99, 98, 65], cob: nil, uam: [])
        let result = ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: predictions), thresholdMgDL: 72
        )
        #expect(result?.lowestPredicted == Decimal(65))
        #expect(result?.firstCrossingMinutes == 15)
    }

    @Test("Window: nil or empty predictions return nil") func windowNilPredictions() {
        #expect(ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: nil), thresholdMgDL: 72
        ) == nil)
        let empty = Predictions(iob: [], zt: [], cob: [], uam: [])
        #expect(ForecastedGlucoseEvaluator.evaluateWindow(
            determination: makeDetermination(predictions: empty), thresholdMgDL: 72
        ) == nil)
    }
}
