import SwiftUI
import Testing
@testable import Trio_Watch_App

@Suite("Watch App Tests", .serialized) @MainActor final class TrioWatchAppTests {
    var watchState = WatchState()

    /// Lets main-queue work scheduled by WatchState (asyncAfter, async) run
    private func waitForMainQueue(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Color Conversion Tests

    @Test("Hex string to color conversion") func testHexStringToColor() throws {
        // Given
        let whiteHex = "#FFFFFF"
        let blackHex = "#000000"
        let redHex = "#FF0000"
        let invalidHex = "invalid"

        // Then
        #expect(whiteHex.toColor() == Color.white)
        #expect(blackHex.toColor() == Color.black)
        #expect(redHex.toColor() == Color(red: 1, green: 0, blue: 0))
        #expect(invalidHex.toColor() == Color.black)
    }

    // MARK: - WatchState Tests

    @Test("WatchState initialization with default values") func testWatchStateInitialization() throws {
        #expect(watchState.currentGlucose == "--")
        #expect(watchState.currentGlucoseColorString == "#ffffff")
        #expect(watchState.glucoseValues.isEmpty)
        #expect(watchState.iob == "--")
        #expect(watchState.cob == "--")
        #expect(watchState.lastLoopTime == "--")
    }

    @Test("Bolus limits have correct default values") func testBolusLimits() throws {
        #expect(watchState.maxBolus == Decimal(10))
        #expect(watchState.bolusIncrement == Decimal(0.05))
    }

    @Test("Carb limits have correct default values") func testCarbLimits() throws {
        #expect(watchState.maxCarbs == Decimal(250))
    }

    @Test("Acknowledgment states transition correctly") func testAcknowledgmentStates() async throws {
        // Given - Initial state
        #expect(watchState.acknowledgementStatus == .pending)
        #expect(!watchState.showAcknowledgmentBanner)

        // When/Then - Success acknowledgment
        watchState.handleAcknowledgment(success: true, message: "Success")
        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Success")
        try await waitForMainQueue(0.5)
        #expect(watchState.showAcknowledgmentBanner)

        // When/Then - Failure acknowledgment
        watchState.handleAcknowledgment(success: false, message: "Error")
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == "Error")
    }

    // MARK: - Reachability must not touch entries in progress

    @Test("Phone reconnecting keeps the bolus being confirmed") func testReconnectKeepsBolusEntry() throws {
        // Given - the user is on the confirm screen, partway through dialing the crown
        watchState.bolusAmount = 3.0
        watchState.carbsAmount = 20
        watchState.confirmationProgress = 0.5

        // When - raising the wrist reconnects the phone
        watchState.handleReachabilityChange(isReachable: false)
        watchState.handleReachabilityChange(isReachable: true)

        // Then - the confirmed amount is still the one the user entered, not 0 U
        #expect(watchState.bolusAmount == 3.0)
        #expect(watchState.carbsAmount == 20)
        #expect(watchState.confirmationProgress == 0.5)
    }

    // MARK: - Bolus requests that must not be sent

    @Test("Zero bolus is refused on the watch", arguments: [
        Decimal(0),
        Decimal(-1)
    ]) func testZeroBolusRefused(amount: Decimal) async throws {
        watchState.sendBolusRequest(amount)

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.invalidBolusAmountMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
        #expect(watchState.showAcknowledgmentBanner)
    }

    // MARK: - C-210-1: unit-aware display formatting parity (mmol users must see "5.6", not "100")

    @Test("displayString: mg/dL integer vs mmol/L one-decimal") func testDisplayStringUnits() throws {
        let c = WatchGlucoseColorComputer.shared
        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mg/dL")
        #expect(c.displayString(forMgDl: 100) == "100")
        #expect(c.displayString(forMgDl: 200) == "200")

        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mmol/L")
        #expect(c.displayString(forMgDl: 200) == "11.1") // 200 * 0.0555 = 11.1
        #expect(c.displayString(forMgDl: 100) == "5.6") //  100 * 0.0555 = 5.55 -> 5.6 (half away from zero)

        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mg/dL") // restore global state
    }

    @Test("displayDeltaString: signed, unit-aware, mmol converts each operand then subtracts")
    func testDisplayDeltaStringUnits() throws {
        let c = WatchGlucoseColorComputer.shared
        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mg/dL")
        #expect(c.displayDeltaString(previousMgDl: 100, currentMgDl: 110) == "+10")
        #expect(c.displayDeltaString(previousMgDl: 110, currentMgDl: 100) == "-10")
        #expect(c.displayDeltaString(previousMgDl: 100, currentMgDl: 100) == "+0")

        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mmol/L")
        #expect(c.displayDeltaString(previousMgDl: 100, currentMgDl: 200) == "+5.5") // 11.1 - 5.6
        #expect(c.displayDeltaString(previousMgDl: 200, currentMgDl: 100) == "-5.5") // 5.6 - 11.1

        c.apply(low: 70, high: 180, target: 100, dynamic: false, unitsRaw: "mg/dL") // restore global state
    }

    @Test("Bolus with the phone unreachable says nothing was sent") func testUnreachableBolus() async throws {
        watchState.session = nil

        watchState.sendBolusRequest(3)

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("Other treatment requests with the phone unreachable say nothing was sent") func testUnreachableTreatments() throws {
        watchState.session = nil
        let requests: [() -> Void] = [
            { self.watchState.sendCarbsRequest(20) },
            { self.watchState.sendCancelOverrideRequest() },
            { self.watchState.sendActivateOverrideRequest(presetName: "Exercise") },
            { self.watchState.sendCancelTempTargetRequest() },
            { self.watchState.sendActivateTempTargetRequest(presetName: "Eating soon") }
        ]

        for request in requests {
            watchState.acknowledgementStatus = .pending
            watchState.acknowledgmentMessage = ""
            request()
            #expect(watchState.acknowledgementStatus == .failure)
            #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        }
    }

    // MARK: - Waiting for the phone's answer

    @Test("Processing ends with a check-your-phone message when the phone never answers") func testAcknowledgmentTimeout() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 0.1)
        #expect(watchState.showCommsAnimation)
        #expect(watchState.acknowledgementStatus == .pending)

        try await waitForMainQueue(0.6)

        #expect(!watchState.showCommsAnimation)
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.noAnswerMessage)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("An answer from the phone cancels the timeout") func testAcknowledgmentCancelsTimeout() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 0.1)

        watchState.handleAcknowledgment(success: true, message: "Bolus enacted successfully.")
        try await waitForMainQueue(0.6)

        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Bolus enacted successfully.")
    }

    @Test("A send error ends processing with the check-your-phone message") func testSendErrorEndsProcessing() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 60)

        // What the sendMessage error handler does
        watchState.handleMissingAcknowledgment()

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.noAnswerMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
    }

    @Test("A late timeout does not overwrite an answer already shown") func testMissingAcknowledgmentAfterAnswer() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 60)
        watchState.handleAcknowledgment(success: true, message: "Bolus enacted successfully.")
        try await waitForMainQueue(0.3)

        watchState.handleMissingAcknowledgment()

        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Bolus enacted successfully.")
    }

    // MARK: - Entries expire after 2 minutes

    private let entryStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// An entry on the confirm screen: 20 g carbs and 3 U, last edited at `entryStart`
    private func enterMealBolus() {
        watchState.carbsAmount = 20
        watchState.bolusAmount = 3.0
        watchState.confirmationProgress = 0.5
        watchState.markEntryEdited(at: entryStart)
    }

    private func expectEntryCleared() {
        #expect(watchState.bolusAmount == 0)
        #expect(watchState.carbsAmount == 0)
        #expect(watchState.confirmationProgress == 0)
        #expect(watchState.entryEditedAt == nil)
    }

    @Test("An entry is fresh for 2 minutes after its last edit") func testEntryFreshness() throws {
        #expect(!watchState.isEntryFresh(at: entryStart), "no entry has been edited yet")

        watchState.markEntryEdited(at: entryStart)

        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(119)))
        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(120)))
        #expect(!watchState.isEntryFresh(at: entryStart.addingTimeInterval(121)))

        // Editing again restarts the clock
        watchState.markEntryEdited(at: entryStart.addingTimeInterval(100))
        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(200)))
    }

    @Test("Confirming an entry older than 2 minutes sends nothing and clears it")
    func testExpiredEntryNotSent() throws {
        enterMealBolus()

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart.addingTimeInterval(121))

        // The expired message, not "phone unreachable", shows nothing was attempted
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Confirming an entry with no recorded edit sends nothing") func testUneditedEntryNotSent() throws {
        watchState.bolusAmount = 3.0

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart)

        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Confirming a fresh entry sends it and clears it") func testFreshEntrySent() throws {
        enterMealBolus()
        // No phone in tests: reaching the "unreachable" refusal proves the send was attempted
        watchState.session = nil

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart.addingTimeInterval(60))

        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        expectEntryCleared()
    }

    @Test("Logging carbs older than 2 minutes sends nothing") func testExpiredCarbsNotSent() throws {
        watchState.markEntryEdited(at: entryStart)

        watchState.sendCarbsEntry(20, at: entryStart.addingTimeInterval(121))

        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Logging fresh carbs sends them") func testFreshCarbsSent() throws {
        watchState.markEntryEdited(at: entryStart)
        watchState.session = nil

        watchState.sendCarbsEntry(20, at: entryStart.addingTimeInterval(60))

        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        expectEntryCleared()
    }

    @Test("Returning to the app clears an entry older than 2 minutes") func testStaleEntryExpiresOnReturn() throws {
        enterMealBolus()

        #expect(!watchState.expireStaleEntry(at: entryStart.addingTimeInterval(120)))
        #expect(watchState.bolusAmount == 3.0)

        #expect(watchState.expireStaleEntry(at: entryStart.addingTimeInterval(121)))
        expectEntryCleared()
    }

    @Test("Returning to the app with no entry in progress changes nothing") func testNoEntryOnReturn() throws {
        #expect(!watchState.expireStaleEntry(at: entryStart))
    }

    // MARK: - C-210-2: completeness-aware arbitration (shouldUpdate)

    private func snap(
        _ glucose: String, _ trend: String, _ delta: String,
        at date: Date, source: TrioComplicationDataSource
    ) -> TrioComplicationSnapshot {
        TrioComplicationSnapshot(
            glucose: glucose, trend: trend, delta: delta, readingDate: date, date: date,
            state: nil, glucoseColor: nil, source: source, sequence: nil
        )
    }

    @Test("shouldUpdate: a barer payload never clobbers a complete one within the dedup window")
    func testArbitrationAntiClobber() throws {
        let store = TrioComplicationDataStore.shared
        let t = Date()
        let completeBLE = snap("120", "Flat", "+2", at: t, source: .g7DirectBLE)
        let barerWC = snap("120", "", "", at: t, source: .watchConnectivity) // delta "" -> "--", trend ""
        #expect(store.shouldUpdate(new: barerWC, current: completeBLE) == false) // barer must not win
        #expect(store.shouldUpdate(new: completeBLE, current: barerWC) == true) //  complete replaces barer
    }

    @Test("shouldUpdate: equal completeness -> higher-priority source wins, lower loses")
    func testArbitrationPriority() throws {
        let store = TrioComplicationDataStore.shared
        let t = Date()
        let bleC = snap("120", "Flat", "+2", at: t, source: .g7DirectBLE)
        let wcC = snap("120", "FortyFiveUp", "+3", at: t, source: .watchConnectivity)
        #expect(store.shouldUpdate(new: bleC, current: wcC) == true) //  BLE(3) > WC(2)
        #expect(store.shouldUpdate(new: wcC, current: bleC) == false) // WC(2) < BLE(3)
    }

    @Test("shouldUpdate: a newer reading (>1s) wins even if barer")
    func testArbitrationRecency() throws {
        let store = TrioComplicationDataStore.shared
        let t = Date()
        let older = snap("120", "Flat", "+2", at: t, source: .g7DirectBLE)
        let newer = snap("126", "", "", at: t.addingTimeInterval(300), source: .watchConnectivity)
        #expect(store.shouldUpdate(new: newer, current: older) == true)
    }

    @Test("V-2b: recentReadings survives Codable round-trip; a snapshot without it omits the key and decodes to nil")
    func testRecentReadingsCodableEvolution() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        // Direction 1 — round-trip WITH data preserves the series.
        let withData = TrioComplicationSnapshot(
            glucose: "120", trend: "Flat", delta: "+2", readingDate: t, date: t,
            state: nil, glucoseColor: nil, source: .g7DirectBLE, sequence: 42,
            recentReadings: [[1_700_000_000, 118], [1_700_000_300, 120]]
        )
        let roundTripped = try dec.decode(TrioComplicationSnapshot.self, from: enc.encode(withData))
        #expect(roundTripped.recentReadings ?? [] == [[1_700_000_000, 118], [1_700_000_300, 120]])

        // Direction 2 — a snapshot without the field omits the key (nil optional) and decodes to nil,
        // so an older writer's JSON (no key) is tolerated by the newer decoder.
        let withoutData = TrioComplicationSnapshot(
            glucose: "120", trend: "Flat", delta: "+2", readingDate: t, date: t,
            state: nil, glucoseColor: nil, source: .g7DirectBLE, sequence: 42
        )
        let json = try enc.encode(withoutData)
        let jsonString = String(data: json, encoding: .utf8) ?? ""
        #expect(!jsonString.contains("recentReadings"))
        let decoded = try dec.decode(TrioComplicationSnapshot.self, from: json)
        #expect(decoded.recentReadings == nil)
    }
}
