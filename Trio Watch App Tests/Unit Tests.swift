import SwiftUICore
import Testing
@testable import Trio_Watch_App
import XCTest

@Suite("Watch App Tests") final class TrioWatchAppTests {
    var watchState = WatchState()

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
        #expect(watchState.maxCOB == Decimal(120))
    }

    @Test("Bolus cancellation resets all related values") func testBolusCancellation() throws {
        // Given
        watchState.bolusProgress = 0.5
        watchState.activeBolusAmount = 5.0
        watchState.isBolusCanceled = false

        // When
        watchState.sendCancelBolusRequest()

        // Then
        #expect(watchState.isBolusCanceled)
        #expect(watchState.bolusProgress == 0)
        #expect(watchState.activeBolusAmount == 0)
    }

    @Test("Meal bolus combo state transitions work correctly") func testMealBolusComboState() throws {
        // Given - Initial state
        #expect(!watchState.isMealBolusCombo)
        #expect(watchState.mealBolusStep == .savingCarbs)

        // When - Setup meal bolus combo
        watchState.carbsAmount = 30
        watchState.bolusAmount = 3.0

        // Then - Test state transitions
        watchState.handleAcknowledgment(success: true, message: "Saving carbs...", isFinal: false)
        #expect(watchState.isMealBolusCombo)
        #expect(watchState.mealBolusStep == .savingCarbs)

        watchState.handleAcknowledgment(success: true, message: "Enacting bolus...", isFinal: false)
        #expect(watchState.isMealBolusCombo)
        #expect(watchState.mealBolusStep == .enactingBolus)

        watchState.handleAcknowledgment(success: true, message: "Carbs and bolus logged successfully", isFinal: true)
        #expect(!watchState.isMealBolusCombo)
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

    @Test("Acknowledgment states transition correctly") func testAcknowledgmentStates() throws {
        // Given - Initial state
        #expect(watchState.acknowledgementStatus == .pending)
        #expect(!watchState.showAcknowledgmentBanner)

        // When/Then - Success acknowledgment
        watchState.handleAcknowledgment(success: true, message: "Success")
        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.showAcknowledgmentBanner)
        #expect(watchState.acknowledgmentMessage == "Success")

        // When/Then - Failure acknowledgment
        watchState.handleAcknowledgment(success: false, message: "Error")
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.showAcknowledgmentBanner)
        #expect(watchState.acknowledgmentMessage == "Error")
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
}
