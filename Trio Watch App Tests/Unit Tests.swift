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

    // MARK: - TRIO-118: trailing reload after a debounced save

    /// Isolated store with a manual clock, a captured scheduler and a counting reload sink.
    private final class TrailingHarness {
        let store: TrioComplicationDataStore
        var clock = Date()
        var reloads = 0
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        /// TRIO-120: isolated app-group defaults (nil for the TRIO-118 tests), and captured store logs.
        let defaults: UserDefaults?
        private let suiteName: String?
        var logs: [String] = []
        var bobbleKindReloads = 0

        init(isolatedDefaults: Bool = false) {
            let dir = self.dir
            let suiteName = isolatedDefaults ? "trio120-\(UUID().uuidString)" : nil
            let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) }
            self.suiteName = suiteName
            self.defaults = defaults
            TrioComplicationDataStore.lastValidTimestamp = nil
            store = TrioComplicationDataStore(
                sharedContainerURLProvider: { dir },
                appGroupDefaultsProvider: { defaults }
            )
            store.nowProvider = { [unowned self] in clock }
            store.reloadSink = { [unowned self] in reloads += 1 }
            store.kindReloadSink = { [unowned self] _ in bobbleKindReloads += 1 }
            store.scheduleDelayedWork = { [unowned self] delay, work in scheduled.append((delay, work)) }
            // Never ask WidgetKit in tests: the installed set is unknown until a test says otherwise.
            store.installedKindsSource = { $0(nil) }
            TrioComplicationDataStore.setLogForwarder { [weak self] in self?.logs.append($0) }
        }

        deinit {
            TrioComplicationDataStore.setLogForwarder(nil)
            try? FileManager.default.removeItem(at: dir)
            if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        }

        static let mainKind = TrioComplicationDataStore.complicationKind
        static let bobbleKind = TrioComplicationDataStore.glucoseBobbleComplicationKind

        func setInstalled(_ kinds: Set<String>?) {
            store.installedKindsSource = { $0(kinds) }
            store.refreshInstalledKinds()
        }

        /// Seeds the persisted requested generation (the reload sink replaces the code that bumps it).
        func setRequestedGeneration(_ generation: Int) {
            defaults?.set(generation, forKey: "TrioComplication_reloadGeneration")
        }

        func skipLogs(caller: String) -> [String] {
            logs.filter { $0.contains("event=complication_reload_skipped") && $0.contains("caller=\(caller)") }
        }

        func snapshot(
            glucose: String, age: TimeInterval, source: TrioComplicationDataSource = .g7DirectBLE,
            glucoseColor: String? = nil, chart: String? = nil, recent: [[Int]]? = nil, sequence: Int? = nil
        ) -> TrioComplicationSnapshot {
            let d = Date().addingTimeInterval(-age)
            return TrioComplicationSnapshot(
                glucose: glucose, trend: "Flat", delta: "+1", readingDate: d, date: d,
                state: nil, glucoseColor: glucoseColor, source: source, sequence: sequence,
                recentReadings: recent, chartGlucoseColor: chart
            )
        }

        /// Saves a reading `age` seconds before real now (the future-skew guard uses the real clock).
        func save(glucose: String, age: TimeInterval) {
            let d = Date().addingTimeInterval(-age)
            store.save(
                TrioComplicationSnapshot(
                    glucose: glucose, trend: "Flat", delta: "+1", readingDate: d, date: d,
                    state: nil, glucoseColor: nil, source: .g7DirectBLE, sequence: nil
                )
            )
        }

        /// Runs every pending (non-cancelled) delayed item, as the interval expiring would.
        func runScheduled() {
            let items = scheduled
            scheduled.removeAll()
            items.forEach { $0.work.perform() }
        }
    }

    @Test("TRIO-118 AC-1: save debounced after an earlier reload -> exactly one trailing reload at expiry")
    func testTrailingReloadAfterCoalescedReload() throws {
        let h = TrailingHarness()
        h.save(glucose: "100", age: 300) // not debounced (lastReload distantPast) -> reload 1
        #expect(h.reloads == 1)
        #expect(h.scheduled.isEmpty)
        h.clock.addTimeInterval(2)
        h.save(glucose: "110", age: 10) // newer reading within 30s -> debounced
        #expect(h.reloads == 1)
        #expect(h.scheduled.count == 1)
        #expect(abs(h.scheduled[0].delay - 28.5) < 0.01) // 30 - 2 + 0.5 margin
        h.clock.addTimeInterval(28.5)
        h.runScheduled()
        #expect(h.reloads == 2)
        #expect(h.scheduled.isEmpty)
    }

    @Test("TRIO-118 AC-1: a force reload just before the save does not cover it -> trailing reload still fires")
    func testTrailingReloadAfterForceReloadBeforeSave() throws {
        let h = TrailingHarness()
        h.save(glucose: "100", age: 300)
        #expect(h.reloads == 1)
        h.clock.addTimeInterval(1)
        h.store.forceReload(scheduleRetry: false) // fires before the newer snapshot exists
        #expect(h.reloads == 2)
        h.clock.addTimeInterval(1)
        h.save(glucose: "110", age: 10)
        #expect(h.reloads == 2) // debounced
        #expect(h.scheduled.count == 1)
        h.clock.addTimeInterval(29)
        h.runScheduled()
        #expect(h.reloads == 3)
    }

    @Test("TRIO-118 AC-2: two debounced saves inside the window -> still exactly one trailing reload")
    func testTrailingReloadAtMostOnePending() throws {
        let h = TrailingHarness()
        h.save(glucose: "100", age: 300)
        h.clock.addTimeInterval(2)
        h.save(glucose: "110", age: 20)
        h.clock.addTimeInterval(2)
        h.save(glucose: "120", age: 5)
        #expect(h.reloads == 1)
        #expect(h.scheduled.count == 1)
        h.clock.addTimeInterval(30)
        h.runScheduled()
        #expect(h.reloads == 2)
        #expect(h.scheduled.isEmpty)
    }

    @Test("TRIO-118 AC-2: a reload that fires after the newest save absorbs the pending trailing reload")
    func testTrailingReloadAbsorbedByLaterReload() throws {
        let h = TrailingHarness()
        h.save(glucose: "100", age: 300)
        h.clock.addTimeInterval(2)
        h.save(glucose: "110", age: 10)
        #expect(h.scheduled.count == 1)
        h.clock.addTimeInterval(1)
        h.store.forceReload(scheduleRetry: false) // after the newest save -> covers it
        #expect(h.reloads == 2)
        h.clock.addTimeInterval(40)
        h.runScheduled() // cancelled item: perform() is a no-op
        #expect(h.reloads == 2)
    }

    @Test("TRIO-118: no trailing reload when the save's reload was not debounced")
    func testNoTrailingReloadWhenNotDebounced() throws {
        let h = TrailingHarness()
        h.save(glucose: "100", age: 300)
        h.clock.addTimeInterval(31)
        h.save(glucose: "110", age: 10)
        #expect(h.reloads == 2)
        #expect(h.scheduled.isEmpty)
    }

    // MARK: - TRIO-120: reload only when the face content changes

    @Test("TRIO-120 AC-1: a duplicate-skipped save then forceComplicationUpdate requests no reload and logs why")
    func testForceAfterDuplicateSaveRequestsNoReload() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        let s1 = h.snapshot(glucose: "100", age: 300)
        h.store.save(s1)
        #expect(h.reloads == 1)

        h.clock.addTimeInterval(40)
        h.store.save(s1) // duplicate skipped: no write, no reload
        h.store.forceComplicationReload(s1)
        #expect(h.reloads == 1)
        let skips = h.skipLogs(caller: "force_update")
        #expect(skips.count == 1)
        #expect(skips.first?.contains("reason=no_new_content") == true)
    }

    @Test("TRIO-120 AC-1: save reload then force reload for the same reading -> exactly one reload")
    func testSaveThenForceSameReadingOneReload() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        let s1 = h.snapshot(glucose: "100", age: 300)
        h.store.save(s1)
        #expect(h.reloads == 1)

        h.clock.addTimeInterval(0.008)
        h.store.forceComplicationReload(s1)
        #expect(h.reloads == 1)
        #expect(h.skipLogs(caller: "force_update").first?.contains("reason=already_requested") == true)

        // A genuinely newer reading still goes through the force path.
        h.clock.addTimeInterval(60)
        h.store.forceComplicationReload(h.snapshot(glucose: "110", age: 5))
        #expect(h.reloads == 2)
    }

    @Test("TRIO-120 AC-2: sleep-gap reload fires only for a newer epoch or an unserviced last request")
    func testSleepGapReloadGate() throws {
        // Serviced last request, no newer epoch -> skipped, rate limiter not consumed.
        let a = TrailingHarness(isolatedDefaults: true)
        a.store.save(a.snapshot(glucose: "100", age: 300))
        var fired = false
        a.store.requestSleepGapReload(onFired: { fired = true })
        #expect(a.reloads == 1)
        #expect(!fired)
        let skips = a.skipLogs(caller: "sleep_gap")
        #expect(skips.count == 1)
        #expect(skips.first?.contains("reason=no_newer_epoch") == true)

        // The store holds a newer epoch than the last request -> fires.
        a.clock.addTimeInterval(60)
        a.store.save(a.snapshot(glucose: "110", age: 5), triggerReload: false)
        a.store.requestSleepGapReload(onFired: { fired = true })
        #expect(a.reloads == 2)
        #expect(fired)

        // Last request unserviced (generation 7 requested, main kind saw 6) -> fires without a newer epoch.
        let b = TrailingHarness(isolatedDefaults: true)
        b.setInstalled([TrailingHarness.mainKind])
        b.store.save(b.snapshot(glucose: "100", age: 300))
        b.setRequestedGeneration(7)
        b.store.recordWidgetObservedGeneration(6, kind: TrailingHarness.mainKind)
        b.store.requestSleepGapReload()
        #expect(b.reloads == 2)
        b.store.recordWidgetObservedGeneration(7, kind: TrailingHarness.mainKind)
        b.store.requestSleepGapReload()
        #expect(b.reloads == 2) // serviced now, nothing newer
    }

    @Test("TRIO-120 AC-3: unserviced re-request, launch reconcile, debug Force Reload and Bobble settings reload ignore the gate")
    func testBypassingReloadsIgnoreContentGate() throws {
        func harness() -> TrailingHarness {
            let h = TrailingHarness(isolatedDefaults: true)
            h.store.save(h.snapshot(glucose: "100", age: 300))
            #expect(h.reloads == 1) // content now remembered; nothing changes below
            return h
        }

        let unserviced = harness()
        unserviced.setRequestedGeneration(9)
        unserviced.store.recordWidgetObservedGeneration(8, kind: TrailingHarness.mainKind)
        unserviced.store.performUnservicedCheckOnMain(generation: 9)
        #expect(unserviced.reloads == 2)

        let launch = harness()
        launch.setRequestedGeneration(9)
        launch.store.recordWidgetObservedGeneration(8, kind: TrailingHarness.mainKind)
        launch.store.reconcileUnservicedReloadOnLaunch()
        #expect(launch.reloads == 2)

        let debug = harness()
        debug.store.forceReload(scheduleRetry: false) // WatchDiagnosticsView's Force Reload
        #expect(debug.reloads == 2)

        let bobble = harness()
        bobble.store.reloadGlucoseBobbleKind()
        #expect(bobble.bobbleKindReloads == 1)
        #expect(bobble.reloads == 1) // only the Bobble kind, through its own sink
    }

    @Test("TRIO-120 AC-5: serviced only when every installed kind observed the generation")
    func testPerKindServicing() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        let both: Set<String> = [TrailingHarness.mainKind, TrailingHarness.bobbleKind]
        h.setInstalled(both)
        h.store.save(h.snapshot(glucose: "100", age: 300))
        h.setRequestedGeneration(5)

        // Main ran, Bobble was deferred -> unserviced, and the re-request fires.
        h.store.recordWidgetObservedGeneration(5, kind: TrailingHarness.mainKind)
        h.store.recordWidgetObservedGeneration(4, kind: TrailingHarness.bobbleKind)
        #expect(!h.store.isGenerationServiced(5))
        h.store.performUnservicedCheckOnMain(generation: 5)
        #expect(h.reloads == 2)

        // Both observed -> serviced.
        h.store.recordWidgetObservedGeneration(5, kind: TrailingHarness.bobbleKind)
        #expect(h.store.isGenerationServiced(5))
        #expect(h.store.widgetObservedGeneration(kind: TrailingHarness.mainKind) == 5)
        #expect(h.store.widgetObservedGeneration(kind: TrailingHarness.bobbleKind) == 5)
        // The legacy shared key is still written.
        #expect(h.defaults?.integer(forKey: "TrioComplication_widgetObservedReloadGeneration") == 5)
        #expect(h.store.widgetObservedGeneration() == 5)

        // A face with only the main kind never waits on the Bobble.
        let single = TrailingHarness(isolatedDefaults: true)
        single.setInstalled([TrailingHarness.mainKind])
        single.store.recordWidgetObservedGeneration(3, kind: TrailingHarness.mainKind)
        #expect(single.store.isGenerationServiced(3))

        // Unknown or empty installed set: the old rule (any kind observing counts via the legacy key).
        for unknown in [nil, Set<String>()] as [Set<String>?] {
            let u = TrailingHarness(isolatedDefaults: true)
            u.setInstalled(unknown)
            u.store.recordWidgetObservedGeneration(4, kind: TrailingHarness.bobbleKind)
            #expect(u.store.isGenerationServiced(4)) // only Bobble observed
            #expect(!u.store.isGenerationServiced(5))
        }
    }

    @Test("TRIO-120 AC-5: an installed-kinds set delivered asynchronously re-checks servicing and re-requests once")
    func testAsyncInstalledKindsRecheck() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        h.store.save(h.snapshot(glucose: "100", age: 300))
        #expect(h.reloads == 1)
        var pending: [(Set<String>?) -> Void] = []
        h.store.installedKindsSource = { pending.append($0) }
        h.setRequestedGeneration(5)
        // Bobble ran first, main last: the shared legacy key then holds main's 5.
        h.store.recordWidgetObservedGeneration(4, kind: TrailingHarness.bobbleKind)
        h.store.recordWidgetObservedGeneration(5, kind: TrailingHarness.mainKind)

        // Cache still nil: the check falls back to the any-kind rule and sees N serviced.
        h.store.performUnservicedCheckOnMain(generation: 5)
        #expect(h.reloads == 1)
        #expect(pending.count == 1)

        // The refresh then reports both kinds installed: Bobble never observed N -> re-request.
        let both: Set<String> = [TrailingHarness.mainKind, TrailingHarness.bobbleKind]
        pending.removeFirst()(both)
        #expect(h.reloads == 2)
        #expect(h.logs.contains { $0.contains("trigger=installed_kinds_changed") && $0.contains("action=re_request") })

        // An unchanged set delivered later triggers nothing more.
        h.store.refreshInstalledKinds()
        #expect(pending.count == 1)
        pending.removeFirst()(both)
        #expect(h.reloads == 2)
    }

    @Test("TRIO-120 AC-6: a field one kind displays lets a gated request through; a field neither displays does not")
    func testContentKeyPerKind() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        h.setInstalled([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        var loopDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
        var settings = "glucose,true,true,glucoseTint,trendGradient"
        h.store.bobbleLastLoopDateProvider = { loopDate }
        h.store.bobbleSettingsKeyProvider = { settings }

        let base = h.snapshot(
            glucose: "100", age: 300, source: .watchConnectivity, glucoseColor: "#FFFFFF", chart: "#00FF00",
            recent: [[1_700_000_000, 98], [1_700_000_300, 100]], sequence: 1
        )
        var current = base
        h.store.gateSnapshotOverride = { current }
        h.store.save(base)
        #expect(h.reloads == 1)

        func gated() { h.store.forceComplicationReload(base) }

        // Fields neither kind displays: sequence, save date, a non-BLE source swap (WC vs HK).
        let hk = TrioComplicationSnapshot(
            glucose: base.glucose, trend: base.trend, delta: base.delta, readingDate: base.readingDate,
            date: base.date.addingTimeInterval(99), state: nil, glucoseColor: "#FFFFFF", source: .healthKit,
            sequence: 77, recentReadings: base.recentReadings, chartGlucoseColor: "#00FF00"
        )
        #expect(TrioComplicationDataStore.mainContentKey(for: base) == TrioComplicationDataStore.mainContentKey(for: hk))
        #expect(
            TrioComplicationDataStore.bobbleContentKey(for: base, lastLoopDate: loopDate, settingsKey: settings)
                == TrioComplicationDataStore.bobbleContentKey(for: hk, lastLoopDate: loopDate, settingsKey: settings)
        )
        current = hk
        h.clock.addTimeInterval(60)
        gated()
        #expect(h.reloads == 1)
        #expect(h.skipLogs(caller: "force_update").count == 1)

        // Only the Bobble's chart colour changed: Bobble key moves, main key does not.
        var changed = TrioComplicationSnapshot(
            glucose: base.glucose, trend: base.trend, delta: base.delta, readingDate: base.readingDate,
            date: base.date, state: nil, glucoseColor: "#FFFFFF", source: .watchConnectivity, sequence: 1,
            recentReadings: base.recentReadings, chartGlucoseColor: "#FF0000"
        )
        #expect(TrioComplicationDataStore.mainContentKey(for: changed) == TrioComplicationDataStore.mainContentKey(for: base))
        #expect(
            TrioComplicationDataStore.bobbleContentKey(for: changed, lastLoopDate: loopDate, settingsKey: settings)
                != TrioComplicationDataStore.bobbleContentKey(for: base, lastLoopDate: loopDate, settingsKey: settings)
        )
        current = changed
        gated()
        #expect(h.reloads == 2)

        // With only the main kind installed the Bobble key is not compared.
        h.setInstalled([TrailingHarness.mainKind])
        changed.chartGlucoseColor = "#0000FF"
        current = changed
        gated()
        #expect(h.reloads == 2)
        h.setInstalled([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        gated()
        #expect(h.reloads == 3)

        // Bobble inputs outside the snapshot: loop date and settings.
        loopDate = Date(timeIntervalSince1970: 1_700_000_600)
        gated()
        #expect(h.reloads == 4)
        settings = "white,true,true,glucoseTint,loopStatus"
        gated()
        #expect(h.reloads == 5)
        gated()
        #expect(h.reloads == 5) // nothing changed since the last request

        // Main-only fields: bubble colour (the chart colour wins for the Bobble), state and recent readings.
        func mainDiffers(_ s: TrioComplicationSnapshot) -> Bool {
            TrioComplicationDataStore.mainContentKey(for: s) != TrioComplicationDataStore.mainContentKey(for: changed)
        }
        func bobbleDiffers(_ s: TrioComplicationSnapshot) -> Bool {
            TrioComplicationDataStore.bobbleContentKey(for: s, lastLoopDate: loopDate, settingsKey: settings)
                != TrioComplicationDataStore.bobbleContentKey(for: changed, lastLoopDate: loopDate, settingsKey: settings)
        }
        func variant(
            glucoseColor: String? = "#FFFFFF", state: String? = nil, source: TrioComplicationDataSource = .watchConnectivity,
            recent: [[Int]]? = base.recentReadings
        ) -> TrioComplicationSnapshot {
            TrioComplicationSnapshot(
                glucose: base.glucose, trend: base.trend, delta: base.delta, readingDate: base.readingDate,
                date: base.date, state: state, glucoseColor: glucoseColor, source: source, sequence: 1,
                recentReadings: recent, chartGlucoseColor: "#0000FF"
            )
        }
        #expect(mainDiffers(variant(glucoseColor: "#FF8800")) && !bobbleDiffers(variant(glucoseColor: "#FF8800")))
        #expect(mainDiffers(variant(state: "Old")))
        #expect(mainDiffers(variant(source: .g7DirectBLE)) && !bobbleDiffers(variant(source: .g7DirectBLE))) // BLE marker appears
        #expect(mainDiffers(variant(recent: [[1_700_000_000, 98]])) && !bobbleDiffers(variant(recent: [[1_700_000_000, 98]])))
        current = variant(glucoseColor: "#FF8800")
        gated()
        #expect(h.reloads == 6)
    }

    @Test("TRIO-120 AC-7: provider runs record seconds since the previous run of that kind and a newer reading")
    func testProviderRunTelemetry() throws {
        let h = TrailingHarness(isolatedDefaults: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let main = TrailingHarness.mainKind
        #expect(h.store.recordProviderRun(kind: main, readingEpoch: 1_000, now: t0)
            == .init(sincePrevRunSeconds: -1, newerReading: false))
        #expect(h.store.recordProviderRun(kind: main, readingEpoch: 1_300, now: t0.addingTimeInterval(60))
            == .init(sincePrevRunSeconds: 60, newerReading: true))
        #expect(h.store.recordProviderRun(kind: main, readingEpoch: 1_300, now: t0.addingTimeInterval(360))
            == .init(sincePrevRunSeconds: 300, newerReading: false))
        // Kinds are independent.
        #expect(h.store.recordProviderRun(kind: TrailingHarness.bobbleKind, readingEpoch: 1_300, now: t0.addingTimeInterval(400))
            == .init(sincePrevRunSeconds: -1, newerReading: false))
    }

    // MARK: - TRIO-126: open and close refresh

    /// Store with both kinds installed, an injected newest snapshot and a fixed clock.
    private final class OpenHarness {
        let h = TrailingHarness(isolatedDefaults: true)
        var current: TrioComplicationSnapshot
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        init() {
            current = h.snapshot(glucose: "100", age: 600)
            h.clock = t0
            h.setInstalled([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
            h.store.gateSnapshotOverride = { [unowned self] in current }
        }

        var epoch: Int { Int(current.readingDate.timeIntervalSince1970) }

        /// A provider run that rendered `rendered` (default: the store's current snapshot), recording its content key.
        func providerRun(
            _ kind: String, at offset: TimeInterval, epoch: Int? = nil, rendered: TrioComplicationSnapshot? = nil
        ) -> TrioComplicationDataStore.ProviderRunInfo {
            let snapshot = rendered ?? current
            return h.store.recordProviderRun(
                kind: kind, readingEpoch: epoch ?? Int(snapshot.readingDate.timeIntervalSince1970),
                renderedContentKey: h.store.contentKey(forKind: kind, snapshot: snapshot),
                now: t0.addingTimeInterval(offset)
            )
        }

        /// Same reading date, different glucose: the content key changes but the epoch does not.
        func sameReadingNewGlucose(_ glucose: String) -> TrioComplicationSnapshot {
            TrioComplicationSnapshot(
                glucose: glucose, trend: current.trend, delta: current.delta, readingDate: current.readingDate,
                date: current.date, state: nil, glucoseColor: nil, source: .g7DirectBLE, sequence: nil
            )
        }

        func lines(_ event: String) -> [String] { h.logs.filter { $0.contains("event=\(event)") } }
    }

    @Test("TRIO-126 AC-1: open with one kind behind -> one immediate reload, not debounced after another reload")
    func testOpenRefreshRequestsForKindBehind() throws {
        let o = OpenHarness()
        // A reload that covers the newest reading, then only the Bobble renders it.
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        #expect(o.h.reloads == 1)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 1)
        _ = o.providerRun(TrailingHarness.mainKind, at: 1, epoch: o.epoch - 300) // main ran with an older reading

        o.h.store.requestOpenRefresh() // same clock instant as the reload: inside the 5 s debounce
        #expect(o.h.reloads == 2)
        let open = try #require(o.lines("complication_open_refresh").first)
        #expect(open.contains("caller=open_refresh") && open.contains("action=requested") && open.contains("behind=main"))
        #expect(open.contains("store_epoch=\(o.epoch)") && open.contains("main_rendered_epoch=\(o.epoch - 300)"))
        #expect(open.contains("bobble_rendered_epoch=\(o.epoch)") && open.contains("bobble_key_changed=false"))
        #expect(o.h.skipLogs(caller: "open_refresh").isEmpty)
    }

    @Test("TRIO-126 AC-1: open with every kind current -> no reload, skip logged")
    func testOpenRefreshSkipsWhenCurrent() throws {
        let o = OpenHarness()
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = o.providerRun(TrailingHarness.mainKind, at: 1)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 1)

        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1)
        #expect(try #require(o.lines("complication_open_refresh").first).contains("action=skipped"))
        #expect(o.h.skipLogs(caller: "open_refresh").count == 1)
    }

    @Test("TRIO-126 AC-1: open saves the newest reading it holds and requests for a kind whose content changed")
    func testOpenRefreshSavesNewestReading() throws {
        let o = OpenHarness()
        o.h.store.gateSnapshotOverride = nil
        let newest = o.h.snapshot(glucose: "140", age: 30)
        o.h.store.requestOpenRefresh(newest: newest)
        #expect(o.h.store.latestSnapshot()?.glucose == "140")
        #expect(o.h.reloads == 1)
        #expect(try #require(o.lines("complication_open_refresh").first).contains("action=requested"))
    }

    @Test("TRIO-126 AC-2: open requested, no provider run -> close requests once more; a second close does not")
    func testCloseRefreshRequestsWhenNoProviderRun() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh() // nothing ever rendered: both kinds behind
        #expect(o.h.reloads == 1)

        o.h.store.requestCloseRefresh()
        #expect(o.h.reloads == 2)
        let close = try #require(o.lines("complication_close_refresh").first)
        #expect(close.contains("caller=close_refresh") && close.contains("action=requested") && close.contains("pending=main+bobble"))

        o.h.store.requestCloseRefresh() // dual path: resign active, then background
        #expect(o.h.reloads == 2)
        #expect(o.lines("complication_close_refresh").count == 1)
    }

    @Test("TRIO-126 AC-2: every kind ran since the open request -> close requests nothing; only the idle kind is named otherwise")
    func testCloseRefreshSkipsWhenKindsRan() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1)
        _ = o.providerRun(TrailingHarness.mainKind, at: 3)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 4)
        o.h.store.requestCloseRefresh()
        #expect(o.h.reloads == 1)
        #expect(try #require(o.lines("complication_close_refresh").first).contains("action=skipped"))

        // Next foreground session: only the Bobble ran, so only it is pending.
        o.h.clock = o.t0.addingTimeInterval(100)
        o.current = o.h.snapshot(glucose: "110", age: 60)
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 2)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 105)
        o.h.store.requestCloseRefresh()
        #expect(o.h.reloads == 3)
        #expect(try #require(o.lines("complication_close_refresh").last).contains("pending=main "))
    }

    @Test("TRIO-126 AC-2: a second open in the same foreground session and a close after a skipped open request nothing")
    func testOpenIsIdempotentPerSession() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh()
        o.h.store.requestOpenRefresh() // scene phase and ExtensionDelegate both fire
        #expect(o.h.reloads == 1)
        #expect(o.lines("complication_open_refresh").count == 1)

        let skipped = OpenHarness()
        skipped.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = skipped.providerRun(TrailingHarness.mainKind, at: 1)
        _ = skipped.providerRun(TrailingHarness.bobbleKind, at: 1)
        skipped.h.store.requestOpenRefresh()
        skipped.h.store.requestCloseRefresh()
        #expect(skipped.h.reloads == 1)
        #expect(skipped.lines("complication_close_refresh").isEmpty)
    }

    @Test("TRIO-126 AC-3: open_to_run latency appears on the first provider run of each kind after an open only")
    func testOpenToRunLatencyOncePerKindPerOpen() throws {
        let o = OpenHarness()
        // Before any open there is no latency.
        #expect(o.providerRun(TrailingHarness.mainKind, at: -50).openToRunSeconds == nil)

        o.h.store.requestOpenRefresh()
        let open = try #require(o.lines("complication_open_refresh").first)
        #expect(open.contains("open_at_epoch=\(Int(o.t0.timeIntervalSince1970))"))

        #expect(o.providerRun(TrailingHarness.mainKind, at: 7).openToRunSeconds == 7)
        #expect(o.providerRun(TrailingHarness.mainKind, at: 20).openToRunSeconds == nil)
        #expect(o.providerRun(TrailingHarness.bobbleKind, at: 12).openToRunSeconds == 12)
        #expect(o.providerRun(TrailingHarness.bobbleKind, at: 30).openToRunSeconds == nil)

        // A later open starts a new measurement for each kind.
        o.h.store.requestCloseRefresh()
        o.h.clock = o.t0.addingTimeInterval(1_000)
        o.h.store.requestOpenRefresh()
        #expect(o.providerRun(TrailingHarness.mainKind, at: 1_004).openToRunSeconds == 4)
        #expect(o.providerRun(TrailingHarness.mainKind, at: 1_010).openToRunSeconds == nil)
        #expect(o.providerRun(TrailingHarness.bobbleKind, at: 1_009).openToRunSeconds == 9)
    }

    @Test("TRIO-126 review 1: a dropped reload advances the requested key but not the rendered one -> open still requests")
    func testOpenComparesRenderedKeyNotRequestedKey() throws {
        let o = OpenHarness()
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = o.providerRun(TrailingHarness.mainKind, at: 1)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 1)

        // Same reading, new content; the reload for it is requested but WidgetKit drops it (no provider run).
        o.current = o.sameReadingNewGlucose("123")
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        #expect(o.h.reloads == 2)

        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 3)
        let open = try #require(o.lines("complication_open_refresh").first)
        #expect(open.contains("action=requested") && open.contains("behind=main+bobble"))
    }

    @Test("TRIO-126 review 1: a kind with no recorded run key counts as behind")
    func testOpenTreatsMissingRenderedKeyAsBehind() throws {
        let o = OpenHarness()
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = o.h.store.recordProviderRun(kind: TrailingHarness.mainKind, readingEpoch: o.epoch, now: o.t0) // no key
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 1)
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 2)
        #expect(try #require(o.lines("complication_open_refresh").first).contains("behind=main"))
    }

    @Test("TRIO-126 review 2: a Bobble that shows up in the installed-kinds refresh during the open session is requested once")
    func testOpenRechecksWhenInstalledKindsArrive() throws {
        let o = OpenHarness()
        o.h.setInstalled([TrailingHarness.mainKind]) // stale cache: the Bobble was added while inactive
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = o.providerRun(TrailingHarness.mainKind, at: 1)

        var arrive: ((Set<String>?) -> Void)?
        o.h.store.installedKindsSource = { arrive = $0 }
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1) // main is current: nothing requested at open
        #expect(try #require(o.lines("complication_open_refresh").first).contains("action=skipped"))

        arrive?([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        #expect(o.h.reloads == 2)
        let recheck = try #require(o.lines("complication_open_refresh").last)
        #expect(recheck.contains("trigger=installed_kinds") && recheck.contains("evaluated=bobble") && recheck.contains("behind=bobble"))

        arrive?([TrailingHarness.mainKind, TrailingHarness.bobbleKind]) // once per kind per session
        #expect(o.h.reloads == 2)
    }

    @Test("TRIO-126 review 2: unknown set at open -> kinds already requested at open are not requested again")
    func testOpenRecheckDoesNotDoubleRequest() throws {
        let o = OpenHarness()
        o.h.setInstalled(nil)
        var arrive: ((Set<String>?) -> Void)?
        o.h.store.installedKindsSource = { arrive = $0 }
        o.h.store.requestOpenRefresh() // nothing rendered: both behind, requested at open
        #expect(o.h.reloads == 1)
        arrive?([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        #expect(o.h.reloads == 1)
    }

    @Test("TRIO-126 re-review 1: a Bobble found after the open's own reload is covered by it, not requested again")
    func testOpenRecheckCoveredByOpenReload() throws {
        let o = OpenHarness()
        o.h.setInstalled([TrailingHarness.mainKind]) // stale cache, main behind
        var arrive: ((Set<String>?) -> Void)?
        o.h.store.installedKindsSource = { arrive = $0 }
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1)
        arrive?([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        #expect(o.h.reloads == 1)
        #expect(try #require(o.lines("complication_open_refresh").last).contains("action=covered"))
    }

    @Test("TRIO-126 re-review 5: a behind kind found and reloaded by the installed-kinds refresh is still rechecked at close")
    func testCloseRechecksKindReloadedByInstalledKindsRefresh() throws {
        let o = OpenHarness()
        o.h.setInstalled([TrailingHarness.mainKind]) // stale cache: the Bobble was added while inactive
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        #expect(o.h.reloads == 1)
        o.h.setRequestedGeneration(5) // an unserviced generation: only main observed it
        _ = o.providerRun(TrailingHarness.mainKind, at: 1)
        o.h.store.recordWidgetObservedGeneration(5, kind: TrailingHarness.mainKind)
        o.h.clock = o.t0.addingTimeInterval(10)

        var arrive: ((Set<String>?) -> Void)?
        o.h.store.installedKindsSource = { arrive = $0 }
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1) // main is current: nothing requested at open
        #expect(try #require(o.lines("complication_open_refresh").first).contains("action=skipped"))

        arrive?([TrailingHarness.mainKind, TrailingHarness.bobbleKind])
        #expect(o.h.reloads == 2) // the refresh's own installed_kinds_changed re-request
        #expect(o.h.logs.contains { $0.contains("trigger=installed_kinds_changed") && $0.contains("action=re_request") })
        let recheck = try #require(o.lines("complication_open_refresh").last)
        #expect(recheck.contains("trigger=installed_kinds ") && recheck.contains("action=covered") && recheck.contains("behind=bobble"))

        // Main renders after the open; WidgetKit never runs the Bobble provider, so the close must still request.
        _ = o.providerRun(TrailingHarness.mainKind, at: 12)
        o.h.clock = o.t0.addingTimeInterval(15)
        o.h.store.requestCloseRefresh()
        #expect(o.h.reloads == 3)
        let close = try #require(o.lines("complication_close_refresh").first)
        #expect(close.contains("pending=bobble") && close.contains("action=requested"))
    }

    @Test("TRIO-126 re-review 4: a failed installed-kinds refresh during the open session evaluates every kind")
    func testOpenRecheckFailedRefreshEvaluatesAllKinds() throws {
        let o = OpenHarness()
        o.h.setInstalled([TrailingHarness.mainKind]) // stale cache: the Bobble was added while inactive
        o.h.store.forceReload(scheduleRetry: false, caller: "test")
        _ = o.providerRun(TrailingHarness.mainKind, at: 1)
        var arrive: ((Set<String>?) -> Void)?
        o.h.store.installedKindsSource = { arrive = $0 }
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1) // main is current: nothing requested at open
        arrive?(nil) // getCurrentConfigurations failed: unknown means every kind
        #expect(o.h.reloads == 2)
        let recheck = try #require(o.lines("complication_open_refresh").last)
        #expect(recheck.contains("trigger=installed_kinds") && recheck.contains("evaluated=bobble") && recheck.contains("behind=bobble"))
    }

    @Test("TRIO-126 re-review 3: the launch-time forced update 1 s after the open reload does not reload again")
    func testLaunchForceUpdateDuringOpenDoesNotReloadAgain() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1)
        o.h.clock = o.t0.addingTimeInterval(1) // unserviced: no provider has run yet
        o.h.store.forceComplicationReload(o.current)
        #expect(o.h.reloads == 1)
        o.current = o.sameReadingNewGlucose("101") // the harness gate reads `current`
        o.h.store.forceComplicationReload(o.current) // new content still reloads
        #expect(o.h.reloads == 2)
    }

    @Test("TRIO-126 re-review 2: a provider run after the open request that rendered old content does not satisfy the close")
    func testCloseRefreshChecksRenderedContent() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh()
        #expect(o.h.reloads == 1)
        let old = o.h.snapshot(glucose: "90", age: 900) // loaded before the open saved the newest reading
        _ = o.providerRun(TrailingHarness.mainKind, at: 3, rendered: old)
        _ = o.providerRun(TrailingHarness.bobbleKind, at: 4, rendered: old)
        o.h.store.requestCloseRefresh()
        #expect(o.h.reloads == 2)
        #expect(try #require(o.lines("complication_close_refresh").first).contains("pending=main+bobble"))
    }

    @Test("TRIO-126 review 3: an unserviced open request is rechecked at 120 s and re-requested once")
    func testUnservicedOpenRequestGetsRecheck() throws {
        let o = OpenHarness()
        o.h.store.requestOpenRefresh() // first request, not marked as an unserviced retry
        #expect(o.h.reloads == 1)
        o.h.setRequestedGeneration(1) // the reload sink stands in for the code that bumps it; no provider observes it

        // Launch reconcile right after the open must not double the request.
        o.h.store.reconcileUnservicedReloadOnLaunch()
        #expect(o.h.reloads == 1)

        // The 120 s unserviced check: not rate-limited by the open, so it re-requests.
        o.h.store.performUnservicedCheckOnMain(generation: 1)
        #expect(o.h.reloads == 2)
        #expect(o.lines("complication_reload_unserviced").last?.contains("action=re_request") == true)

        // Its usual 15 min rate limit still applies.
        o.h.store.performUnservicedCheckOnMain(generation: 1)
        #expect(o.h.reloads == 2)
        #expect(o.lines("complication_reload_unserviced").last?.contains("action=rate_limited") == true)
    }

    // MARK: - TRIO-119: provider log drain scheduling, sequence numbers, delivery path

    private final class DrainHarness {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var size: Int? = 0
        var drains = 0
        lazy var scheduler = ComplicationLogDrainScheduler(
            now: { [unowned self] in now },
            fileSize: { [unowned self] in size },
            drain: { [unowned self] in drains += 1 }
        )
    }

    @Test("TRIO-119: drain(completion:) calls each completion once, including coalesced back-to-back calls")
    func testDrainCompletionRunsOncePerCall() async {
        let counts = LockedCounts()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ComplicationLogForwarder.shared.drain(completion: { counts.bump(0) })
            ComplicationLogForwarder.shared.drain(completion: {
                counts.bump(1)
                continuation.resume()
            })
        }
        // Serial queue: the second completion ran after the first.
        #expect(counts.values == [1, 1])
    }

    @Test("TRIO-119: afterPendingWork runs once, after a drain(completion:) issued just before it")
    func testAfterPendingWorkRunsAfterQueuedDrain() async {
        let order = LockedOrder()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ComplicationLogForwarder.shared.drain(completion: { order.append("drain") })
            ComplicationLogForwarder.shared.afterPendingWork {
                order.append("after")
                continuation.resume()
            }
        }
        #expect(order.values == ["drain", "after"])
    }

    private final class LockedOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class LockedCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [0, 0]
        func bump(_ i: Int) { lock.lock(); storage[i] += 1; lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("TRIO-119 AC-1: the first request drains, then none within 10 min, then one again")
    func testDrainRateLimit() {
        let h = DrainHarness()
        #expect(h.scheduler.drainIfDue() == .interval)
        #expect(h.drains == 1)

        h.now = h.now.addingTimeInterval(ComplicationLogDrainScheduler.minInterval - 1)
        #expect(h.scheduler.drainIfDue() == nil)
        h.now = h.now.addingTimeInterval(0.5)
        #expect(h.scheduler.drainIfDue() == nil)
        #expect(h.drains == 1)

        h.now = h.now.addingTimeInterval(1)
        #expect(h.scheduler.drainIfDue() == .interval)
        #expect(h.drains == 2)
    }

    @Test("TRIO-119 AC-1: a file past half the cap drains at once, ignoring the rate limit")
    func testDrainAtHalfCap() {
        let h = DrainHarness()
        _ = h.scheduler.drainIfDue()
        #expect(h.drains == 1)

        // Exactly half the cap is not past it.
        h.now = h.now.addingTimeInterval(5)
        h.size = ComplicationLogBuffer.sizeCapBytes / 2
        #expect(h.scheduler.drainIfDue() == nil)

        h.size = ComplicationLogBuffer.sizeCapBytes / 2 + 1
        #expect(h.scheduler.drainIfDue() == .size)
        #expect(h.drains == 2)

        // The file was drained away; the next request is back under the interval rule.
        h.size = 100
        h.now = h.now.addingTimeInterval(30)
        #expect(h.scheduler.drainIfDue() == nil)
        #expect(h.drains == 2)
    }

    @Test("TRIO-119 AC-1: a drain done elsewhere restarts the interval; a clock step back counts as due")
    func testNoteDrainAndClockStep() {
        let h = DrainHarness()
        h.scheduler.noteDrain()
        h.now = h.now.addingTimeInterval(60)
        #expect(h.scheduler.drainIfDue() == nil)

        h.now = h.now.addingTimeInterval(-3600)
        #expect(h.scheduler.drainIfDue() == .interval)
        #expect(h.drains == 1)
    }

    @Test("TRIO-119 AC-4: seq= is read from the end of a line, and only there")
    func testSequenceNumberParsing() {
        let line = "[2026-11-14T10:00:00+0100] [b:240] [X.swift:1] getTimeline → event=x battery_level_percent=80 seq=42"
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: line) == 42)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: line + "  ") == 42)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "[dropped 12 lines]") == nil)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "a line from before seq numbers") == nil)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "x seq=12 and then more") == nil)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "x seq=") == nil)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "x seq=-3") == nil)
        #expect(ComplicationLogBuffer.sequenceNumber(inLine: "x seq=99999999999999999999999") == nil)
    }

    @Test("TRIO-119 AC-4: the counter continues across instances (extension launches)")
    func testSequenceCounterPersists() {
        let suite = "trio119-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = ComplicationLogSequenceCounter(defaults: UserDefaults(suiteName: suite))
        let firstRun: [Int] = [first.next(), first.next(), first.next()]
        #expect(firstRun == [1, 2, 3])

        let relaunched = ComplicationLogSequenceCounter(defaults: UserDefaults(suiteName: suite))
        #expect(relaunched.next() == 4)

        // Without defaults it counts in memory and restarts at 1 on the next launch.
        let memory = ComplicationLogSequenceCounter(defaults: nil)
        let memoryRun: [Int] = [memory.next(), memory.next()]
        #expect(memoryRun == [1, 2])
        #expect(ComplicationLogSequenceCounter(defaults: nil).next() == 1)
    }

    @Test("TRIO-119 AC-4: contiguous values are not gaps")
    func testGapDetectorNoGap() {
        var d = ComplicationLogGapDetector()
        #expect(d.observe(10) == .first)
        #expect(d.observe(11) == .contiguous)
        #expect(d.observe(12) == .contiguous)
        // A re-read line is not a loss.
        #expect(d.observe(12) == .duplicate)
        #expect(d.lastSeq == 12)
    }

    @Test("TRIO-119 AC-4: a gap reports the last seen value, the new one and the missing count")
    func testGapDetectorGap() {
        var d = ComplicationLogGapDetector(lastSeq: 5)
        #expect(d.observe(6) == .contiguous)
        #expect(d.observe(10) == .gap(from: 6, to: 10, missing: 3))
        #expect(d.observe(11) == .contiguous)
    }

    @Test("TRIO-119 AC-4: a gap across two drains is found from the remembered last seq")
    func testGapDetectorAcrossDrains() {
        var firstDrain = ComplicationLogGapDetector()
        for seq in 1...20 { _ = firstDrain.observe(seq) }

        // The next drain starts from what the first one persisted; lines 21-29 were truncated away.
        var secondDrain = ComplicationLogGapDetector(lastSeq: firstDrain.lastSeq)
        #expect(secondDrain.observe(30) == .gap(from: 20, to: 30, missing: 9))
        #expect(secondDrain.observe(31) == .contiguous)

        // No loss between drains: the first line of the next drain continues the count.
        var thirdDrain = ComplicationLogGapDetector(lastSeq: secondDrain.lastSeq)
        #expect(thirdDrain.observe(32) == .contiguous)
    }

    @Test("TRIO-119 AC-4: a counter reset is reported as a reset, not a huge gap, and counting resumes")
    func testGapDetectorReset() {
        var d = ComplicationLogGapDetector(lastSeq: 48_210)
        #expect(d.observe(1) == .reset(from: 48_210, to: 1))
        #expect(d.observe(2) == .contiguous)
        #expect(d.observe(5) == .gap(from: 2, to: 5, missing: 2))
    }

    @Test("TRIO-119 AC-2: the via= values are the delivery paths this code has")
    func testDeliveryPathValues() {
        #expect(ComplicationDeliveryPath.message.rawValue == "message")
        #expect(ComplicationDeliveryPath.userInfo.rawValue == "userInfo")
        #expect(ComplicationDeliveryPath.complicationUserInfo.rawValue == "complicationUserInfo")
        #expect(ComplicationDeliveryPath.applicationContext.rawValue == "applicationContext")
        #expect(ComplicationDeliveryPath.ble.rawValue == "ble")
        #expect(ComplicationDeliveryPath.healthkit.rawValue == "healthkit")
    }

    @Test("TRIO-119 AC-2: the top-level complication marker picks the userInfo path")
    func testDeliveryPathForUserInfo() {
        let payload: [String: Any] = ["watchState": [String: Any]()]
        #expect(ComplicationDeliveryPath.forUserInfo(payload.merging(["complicationTransfer": true]) { $1 }) == .complicationUserInfo)
        #expect(ComplicationDeliveryPath.forUserInfo(payload.merging(["complicationTransfer": false]) { $1 }) == .userInfo)
        #expect(ComplicationDeliveryPath.forUserInfo(payload) == .userInfo)
        #expect(ComplicationDeliveryPath.forUserInfo(["watchState": ["complicationTransfer": true]]) == .userInfo)
    }
}
