import Foundation
import Testing

@testable import Trio

@Suite("ComplicationFastPathPolicy") struct ComplicationFastPathPolicyTests {
    private let eligible: Set<String> = ["glucoseStored", "glucoseUpdate"]

    @Test("only eligible sources qualify") func qualifies() {
        #expect(ComplicationFastPathPolicy.qualifies(source: "glucoseStored", eligibleSources: eligible))
        #expect(ComplicationFastPathPolicy.qualifies(source: "glucoseUpdate", eligibleSources: eligible))
        #expect(!ComplicationFastPathPolicy.qualifies(source: "iobUpdate", eligibleSources: eligible))
        #expect(!ComplicationFastPathPolicy.qualifies(source: "unknown", eligibleSources: eligible))
    }

    @Test("first eligible trigger with a 2 s coalescer waits 1 s") func firstTrigger() {
        let d = ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0, coalescerFireIn: 2.0)
        #expect(d == 1.0)
    }

    @Test("later trigger never waits past 1 s from the first") func cappedFromFirst() {
        let d = ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0.4, coalescerFireIn: 2.0)
        #expect(d != nil)
        #expect(abs((d ?? 0) - 0.6) < 0.0001)
    }

    @Test("elapsed beyond 1 s fires immediately") func overdue() {
        #expect(ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 3, coalescerFireIn: 2.0) == 0)
    }

    @Test("no pending coalescer still schedules") func noCoalescer() {
        #expect(ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0, coalescerFireIn: nil) == 1.0)
    }

    @Test("skips when the coalescer fires sooner or at the same time") func coalescerSooner() {
        #expect(ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0, coalescerFireIn: 0.5) == nil)
        #expect(ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0, coalescerFireIn: 1.0) == nil)
        #expect(ComplicationFastPathPolicy.delay(elapsedSinceFirstEligible: 0, coalescerFireIn: 1.01) == 1.0)
    }

    @Test("epoch newness") func isNewer() {
        #expect(ComplicationFastPathPolicy.isNewer(stateEpoch: 200, lastSentEpoch: 100))
        #expect(!ComplicationFastPathPolicy.isNewer(stateEpoch: 100, lastSentEpoch: 100))
        #expect(!ComplicationFastPathPolicy.isNewer(stateEpoch: 99, lastSentEpoch: 100))
        #expect(ComplicationFastPathPolicy.isNewer(stateEpoch: 100, lastSentEpoch: ComplicationFastPathPolicy.noEpoch))
    }

    @Test("no-epoch state never fast-paths") func noEpoch() {
        #expect(!ComplicationFastPathPolicy.isNewer(stateEpoch: -1, lastSentEpoch: -1))
        #expect(!ComplicationFastPathPolicy.isNewer(stateEpoch: -1, lastSentEpoch: 100))
        #expect(!ComplicationFastPathPolicy.isNewer(stateEpoch: -1, lastSentEpoch: -5))
    }
}
