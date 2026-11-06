import Foundation
import SwiftUI
import Testing
@testable import Trio

@Suite("Loop Indicator") struct LoopIndicatorTests {
    private func color(
        _ automation: AutomationLevel,
        deviceIssue: Bool = false,
        enacted: Bool = true,
        secondsSinceLoop: TimeInterval = 60,
        manualTempBasal: Bool = false
    ) -> Color {
        LoopView.ringColor(
            automation: automation,
            manualTempBasal: manualTempBasal,
            hasDeviceIssue: deviceIssue,
            hasEnactedDetermination: enacted,
            secondsSinceLastLoop: secondsSinceLoop
        )
    }

    @Test("Open loop is green while devices are reporting, whatever the loop age") func openLoopIsGreen() {
        #expect(color(.off) == .loopGreen)
        // Stale loop age must not colour the ring: nothing is being enacted anyway.
        #expect(color(.off, secondsSinceLoop: 60 * 60) == .loopGreen)
    }

    @Test("Open loop goes red only on a device issue") func openLoopDeviceIssue() {
        #expect(color(.off, deviceIssue: true) == .loopRed)
    }

    @Test("Open loop no longer greys out when nothing was enacted") func openLoopIgnoresEnactment() {
        // The old behaviour returned .secondary here, which is what made the pill permanently grey.
        #expect(color(.off, enacted: false) == .loopGreen)
    }

    @Test("Dosing modes keep loop freshness colouring") func dosingModesUseFreshness() {
        for automation in [AutomationLevel.full, .reductionsOnly, .hypoSuspendOnly] {
            #expect(color(automation, secondsSinceLoop: 60) == .loopGreen)
            #expect(color(automation, secondsSinceLoop: 8 * 60) == .loopYellow)
            #expect(color(automation, secondsSinceLoop: 20 * 60) == .loopRed)
            #expect(color(automation, enacted: false) == .secondary)
            // A device issue alone must not mask loop staleness when Trio is dosing.
            #expect(color(automation, deviceIssue: true, secondsSinceLoop: 60) == .loopGreen)
        }
    }

    @Test("A manual temp basal wins over every mode") func manualTempBasalWins() {
        for automation in AutomationLevel.allTestCases {
            #expect(color(automation, manualTempBasal: true) == .loopManualTemp)
        }
    }

    @Test("Only full automation closes the ring") func onlyFullAutomationClosesRing() {
        #expect(LoopView.ringGap(automation: .full, manualTempBasal: false) == 0)
        for automation in [AutomationLevel.off, .reductionsOnly, .hypoSuspendOnly] {
            #expect(LoopView.ringGap(automation: automation, manualTempBasal: false) == LoopView.openRingGap)
        }
    }

    @Test("A manual temp basal opens the ring even in closed loop") func manualTempBasalOpensRing() {
        #expect(LoopView.ringGap(automation: .full, manualTempBasal: true) == LoopView.openRingGap)
    }

    @Test("Only closed loop keeps the time caption") func captionOnlyInClosedLoop() {
        #expect(LoopView.showsCaption(automation: .full))
        for automation in [AutomationLevel.off, .reductionsOnly, .hypoSuspendOnly] {
            #expect(LoopView.showsCaption(automation: automation) == false)
        }
    }

    @Test("Constrained modes carry a centre symbol, plain open and closed loop do not") func centerSymbols() {
        #expect(LoopView.centerSymbol(automation: .full) == nil)
        #expect(LoopView.centerSymbol(automation: .off) == nil)
        #expect(LoopView.centerSymbol(automation: .reductionsOnly) == "hand.raised.fill")
        #expect(LoopView.centerSymbol(automation: .hypoSuspendOnly) == "waveform")
    }
}

private extension AutomationLevel {
    static var allTestCases: [AutomationLevel] { [.off, .hypoSuspendOnly, .reductionsOnly, .full] }
}

@Suite("Home Nightscout backfill") struct HomeNightscoutBackfillTests {
    private actor StoreRecorder {
        private(set) var calls: [[BloodGlucose]] = []
        private var error: Error?

        func throwing(_ error: Error) {
            self.error = error
        }

        func store(_ readings: [BloodGlucose]) async throws {
            calls.append(readings)
            if let error { throw error }
        }
    }

    private func reading(id: String = UUID().uuidString, offset: TimeInterval = 0) -> BloodGlucose {
        BloodGlucose(
            id: id,
            sgv: 120,
            direction: .flat,
            date: 1_700_000_000_000 + Decimal(offset * 1000),
            dateString: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            type: "sgv"
        )
    }

    @Test("Non-empty fetch stores readings") func nonEmptyFetchStores() async {
        let a = reading(offset: 0)
        let b = reading(offset: 300)
        let recorder = StoreRecorder()
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .seconds(5),
            fetch: { [a, b] },
            store: { try await recorder.store($0) }
        )
        #expect(outcome == .stored(2))
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].map(\.id) == [a.id, b.id])
    }

    @Test("storeBatches groups singletons then peels multi-member clusters") func storeBatchesGroupsSingletonsThenPeelsClusters() {
        let at0 = reading(id: "0", offset: 0)
        let at20 = reading(id: "20", offset: 20)
        let at300 = reading(id: "300", offset: 300)
        let at305 = reading(id: "305", offset: 305)
        let at900 = reading(id: "900", offset: 900)
        let at1500 = reading(id: "1500", offset: 1500)
        let at1700 = reading(id: "1700", offset: 1700)
        let at1850 = reading(id: "1850", offset: 1850)
        let expectedIds = [["900"], ["0"], ["20"], ["300"], ["305"], ["1500"], ["1700"], ["1850"]]

        let shuffled = [at305, at1700, at900, at20, at1850, at0, at1500, at300]
        let batches = HomeNightscoutBackfill.storeBatches(shuffled)
        #expect(batches.map { $0.map(\.id) } == expectedIds)
    }

    @Test("run stores storeBatches in order") func runStoresBatchesInOrder() async {
        let at0 = reading(id: "0", offset: 0)
        let at20 = reading(id: "20", offset: 20)
        let at300 = reading(id: "300", offset: 300)
        let at305 = reading(id: "305", offset: 305)
        let at900 = reading(id: "900", offset: 900)
        let at1500 = reading(id: "1500", offset: 1500)
        let at1700 = reading(id: "1700", offset: 1700)
        let at1850 = reading(id: "1850", offset: 1850)
        let recorder = StoreRecorder()
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .seconds(5),
            fetch: { [at305, at1700, at900, at20, at1850, at0, at1500, at300] },
            store: { try await recorder.store($0) }
        )
        #expect(outcome == .stored(8))
        let calls = await recorder.calls
        #expect(calls.map { $0.map(\.id) } == [["900"], ["0"], ["20"], ["300"], ["305"], ["1500"], ["1700"], ["1850"]])
    }

    @Test("Store outliving the timeout still records .stored") func storeOutlivingTimeoutStillStores() async {
        let recorder = StoreRecorder()
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .milliseconds(200),
            fetch: { [reading()] },
            store: { readings in
                try await Task.sleep(for: .milliseconds(400))
                try await recorder.store(readings)
            }
        )
        #expect(outcome == .stored(1))
        let calls = await recorder.calls
        #expect(calls.count == 1)
    }

    @Test("Empty fetch does not store") func emptyFetchSkipsStore() async {
        let recorder = StoreRecorder()
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .seconds(5),
            fetch: { [] },
            store: { try await recorder.store($0) }
        )
        #expect(outcome == .empty)
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }

    @Test("Timeout wins over a slow fetch") func timeoutCancelsStore() async {
        let recorder = StoreRecorder()
        let start = Date()
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .milliseconds(200),
            fetch: {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                        cont.resume()
                    }
                }
                return [reading()]
            },
            store: { try await recorder.store($0) }
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome == .timedOut)
        #expect(elapsed < 1.0)
        try? await Task.sleep(for: .milliseconds(1800))
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }

    @Test("Store throwing yields failed") func storeThrowingFails() async {
        struct Boom: Error {}
        let recorder = StoreRecorder()
        await recorder.throwing(Boom())
        let outcome = await HomeNightscoutBackfill.run(
            timeout: .seconds(5),
            fetch: { [reading()] },
            store: { try await recorder.store($0) }
        )
        #expect(outcome == .failed)
    }
}
