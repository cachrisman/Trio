import Foundation
import Testing

@testable import Trio

@Suite("ComplicationTransferAgeGate") struct ComplicationTransferAgeGateTests {
    @Test("awake gate passes only strictly above 600 s", arguments: [
        (599.0, false), (600.0, false), (601.0, true), (900.0, true)
    ])
    func awakeBoundary(age: Double, passes: Bool) {
        let decision = ComplicationTransferAgeGate.evaluate(isAsleep: false, ageSeconds: age)
        #expect(decision.thresholdSeconds == 600)
        #expect(decision.passes == passes)
    }

    @Test("asleep gate passes only strictly above 1800 s", arguments: [
        (1799.0, false), (1800.0, false), (1801.0, true), (900.0, false)
    ])
    func asleepBoundary(age: Double, passes: Bool) {
        let decision = ComplicationTransferAgeGate.evaluate(isAsleep: true, ageSeconds: age)
        #expect(decision.thresholdSeconds == 1800)
        #expect(decision.passes == passes)
    }

    @Test("gate name and sleep state follow isAsleep")
    func names() {
        let awake = ComplicationTransferAgeGate.evaluate(isAsleep: false, ageSeconds: 0)
        #expect(awake.gateName == "awake")
        #expect(awake.sleepState == "awake")
        let asleep = ComplicationTransferAgeGate.evaluate(isAsleep: true, ageSeconds: 0)
        #expect(asleep.gateName == "asleep")
        #expect(asleep.sleepState == "asleep")
    }

    @Test("logValue renders non-finite ages as inf and truncates finite ones")
    func logValue() {
        #expect(ComplicationTransferAgeGate.logValue(.infinity) == "inf")
        #expect(ComplicationTransferAgeGate.logValue(.nan) == "inf")
        #expect(ComplicationTransferAgeGate.logValue(612.7) == "612")
    }

    @Test("cold-start unknown age passes the awake gate, reaching the log line")
    func coldStartPasses() {
        #expect(ComplicationTransferAgeGate.evaluate(isAsleep: false, ageSeconds: .infinity).passes)
    }

    @Test("unknown age (infinity) always passes")
    func infinity() {
        #expect(ComplicationTransferAgeGate.evaluate(isAsleep: true, ageSeconds: .infinity).passes)
        #expect(ComplicationTransferAgeGate.evaluate(isAsleep: false, ageSeconds: .infinity).passes)
    }
}
