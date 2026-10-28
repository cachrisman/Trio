import Foundation
import Testing
import UserNotifications

@testable import Trio

@Suite("Trio Alerts: GlucoseAlertCoordinator breach/retract") struct GlucoseAlertCoordinatorTests {
    @Test("low breaches at or below threshold 70") func lowBreach() {
        #expect(GlucoseAlertCoordinator.breached(type: .low, latestMgDL: 70, thresholdMgDL: 70))
        #expect(!GlucoseAlertCoordinator.breached(type: .low, latestMgDL: 71, thresholdMgDL: 70))
    }

    @Test("low retracts only at threshold + margin (70 + 5)") func lowRetract() {
        #expect(!GlucoseAlertCoordinator.shouldRetract(
            type: .low, latestMgDL: 74, thresholdMgDL: 70, recoveryMarginMgDL: 5
        ))
        #expect(GlucoseAlertCoordinator.shouldRetract(
            type: .low, latestMgDL: 75, thresholdMgDL: 70, recoveryMarginMgDL: 5
        ))
    }

    @Test("urgentLow breaches at or below threshold 54") func urgentLowBreach() {
        #expect(GlucoseAlertCoordinator.breached(type: .urgentLow, latestMgDL: 54, thresholdMgDL: 54))
        #expect(!GlucoseAlertCoordinator.breached(type: .urgentLow, latestMgDL: 55, thresholdMgDL: 54))
    }

    @Test("high breaches at or above threshold 270") func highBreach() {
        #expect(GlucoseAlertCoordinator.breached(type: .high, latestMgDL: 270, thresholdMgDL: 270))
        #expect(!GlucoseAlertCoordinator.breached(type: .high, latestMgDL: 269, thresholdMgDL: 270))
    }

    @Test("high retracts only at threshold - margin (270 - 5)") func highRetract() {
        #expect(!GlucoseAlertCoordinator.shouldRetract(
            type: .high, latestMgDL: 266, thresholdMgDL: 270, recoveryMarginMgDL: 5
        ))
        #expect(GlucoseAlertCoordinator.shouldRetract(
            type: .high, latestMgDL: 265, thresholdMgDL: 270, recoveryMarginMgDL: 5
        ))
    }

    @Test("type priority order: urgentLow < low < forecastedLow < high < carbsRequired") func priorityOrder() {
        #expect(GlucoseAlertType.urgentLow.priority == 0)
        #expect(GlucoseAlertType.low.priority == 1)
        #expect(GlucoseAlertType.forecastedLow.priority == 2)
        #expect(GlucoseAlertType.high.priority == 3)
        #expect(GlucoseAlertType.carbsRequired.priority == 4)
        #expect(GlucoseAlertType.urgentLow.priority < GlucoseAlertType.low.priority)
    }

    @Test("shouldRetract uses the default 5 mg/dL margin when omitted") func defaultMarginWiring() {
        #expect(GlucoseAlertCoordinator.shouldRetract(type: .low, latestMgDL: 75, thresholdMgDL: 70))
        #expect(!GlucoseAlertCoordinator.shouldRetract(type: .low, latestMgDL: 74, thresholdMgDL: 70))
    }

    // MARK: - Carbs Required predicates (mg/dL-based gates are no-ops)

    /// Carbs Required is determination-driven (`evaluateCarbsRequired(_:)`),
    /// not reading-driven. The shared mg/dL `breached` predicate must never
    /// return true for it, regardless of value / threshold combination.
    @Test("carbsRequired never breaches via the mg/dL predicate") func carbsRequiredNeverBreaches() {
        #expect(!GlucoseAlertCoordinator.breached(type: .carbsRequired, latestMgDL: 0, thresholdMgDL: 0))
        #expect(!GlucoseAlertCoordinator.breached(type: .carbsRequired, latestMgDL: 200, thresholdMgDL: 10))
        #expect(!GlucoseAlertCoordinator.breached(type: .carbsRequired, latestMgDL: 10, thresholdMgDL: 200))
    }

    @Test("carbsRequired never retracts via the mg/dL predicate") func carbsRequiredNeverRetractsViaMgDL() {
        #expect(!GlucoseAlertCoordinator.shouldRetract(
            type: .carbsRequired, latestMgDL: 100, thresholdMgDL: 10, recoveryMarginMgDL: 5
        ))
        #expect(!GlucoseAlertCoordinator.shouldRetract(
            type: .carbsRequired, latestMgDL: 0, thresholdMgDL: 50, recoveryMarginMgDL: 5
        ))
    }
}

/// Guards the #1428 invariant: "Use CGM App Alerts" suppression applies to
/// reading-driven alarms only. A CGM app can alarm on the current reading,
/// but it cannot compute Trio's oref forecast or carbsReq, so those alarms
/// must stay armed — which is also what the settings screen shows the user,
/// since only reading-driven types move into the "Handled by CGM App" section.
@Suite("Trio Alerts: CGM-ownership suppression scope") struct CGMOwnershipSuppressionScopeTests {
    @Test("Forecast and carbs-required alarms are not reading-driven") func determinationDrivenTypes() {
        #expect(!GlucoseAlertType.forecastedLow.isReadingDriven)
        #expect(!GlucoseAlertType.carbsRequired.isReadingDriven)
    }

    @Test("Only high/low/urgentLow are reading-driven") func readingDrivenSetIsExact() {
        let readingDriven = Set(GlucoseAlertType.allCases.filter(\.isReadingDriven))
        #expect(readingDriven == [.high, .low, .urgentLow])
    }

    @Test("CGM-owned retraction keeps determination-driven alarms firing") func retractsOnlyReadingDrivenAlarms() {
        let urgentLow = GlucoseAlert(type: .urgentLow)
        let low = GlucoseAlert(type: .low)
        let forecastedLow = GlucoseAlert(type: .forecastedLow)
        let high = GlucoseAlert(type: .high)
        let carbsRequired = GlucoseAlert(type: .carbsRequired)
        let alarms = [urgentLow, low, forecastedLow, high, carbsRequired]
        let firing = Set(alarms.map(\.id))

        let result = GlucoseAlertCoordinator.alarmsToRetractWhenCGMOwnsAlerts(firing: firing, in: alarms)

        #expect(result.map(\.id) == [urgentLow.id, low.id, high.id])
        #expect(!result.contains(forecastedLow))
        #expect(!result.contains(carbsRequired))
    }

    @Test("CGM-owned retraction skips reading-driven alarms that are not firing") func skipsNonFiringReadingDrivenAlarms() {
        let low = GlucoseAlert(type: .low)
        let high = GlucoseAlert(type: .high)

        let result = GlucoseAlertCoordinator.alarmsToRetractWhenCGMOwnsAlerts(firing: [high.id], in: [low, high])

        #expect(result == [high])
    }

    @Test("CGM-owned retraction with empty firing set returns nothing") func emptyFiringSetReturnsNothing() {
        let alarms = [GlucoseAlert(type: .urgentLow), GlucoseAlert(type: .low), GlucoseAlert(type: .high)]

        let result = GlucoseAlertCoordinator.alarmsToRetractWhenCGMOwnsAlerts(firing: [], in: alarms)

        #expect(result.isEmpty)
    }
}

@Suite("Trio Alerts: Carbs Required notification") struct CarbsRequiredNotificationTests {
    private final class Spy {
        var stored: [Decimal] = []
        var shouldThrow = false
    }

    private func makeHandler(spy: Spy, maxCarbs: Decimal = 100) -> CarbsRequiredLogHandler {
        let suite = "CarbsRequiredNotificationTests.\(UUID().uuidString)"
        return CarbsRequiredLogHandler(
            store: UserDefaultsLoggedCarbsAlertStore(defaults: UserDefaults(suiteName: suite)!),
            maxCarbs: { maxCarbs },
            storeCarbs: { grams in
                if spy.shouldThrow { throw CancellationError() }
                spy.stored.append(grams)
            }
        )
    }

    @Test("category lists Log Carbs first, then 15 min / 1 hr / 3 hrs, no 6 hr") func categoryActions() {
        let category = NotificationCategoryFactory.createCarbsRequiredCategory()
        #expect(category.identifier == NotificationCategoryIdentifier.carbsRequired.rawValue)
        #expect(category.actions.map(\.identifier) == [
            CarbsRequiredNotification.logCarbsActionIdentifier,
            NotificationResponseAction.snooze15.rawValue,
            NotificationResponseAction.snooze1hr.rawValue,
            NotificationResponseAction.snooze3hr.rawValue
        ])
        #expect(category.actions.first?.options.contains(.authenticationRequired) == true)
        #expect(category.actions.first?.options.contains(.foreground) == false)
    }

    @Test("shared category keeps all four snoozes and no Log Carbs") func sharedCategoryUnchanged() {
        let category = NotificationCategoryFactory.createGlucoseCategory()
        #expect(category.identifier == NotificationCategoryIdentifier.trioAlert.rawValue)
        #expect(category.actions.map(\.identifier) == [
            NotificationResponseAction.snooze15.rawValue,
            NotificationResponseAction.snooze1hr.rawValue,
            NotificationResponseAction.snooze3hr.rawValue,
            NotificationResponseAction.snooze6hr.rawValue
        ])
    }

    @Test("body shows grams, glucose and trend in the user's units") func bodyText() {
        let mgdl = GlucoseAlertCoordinator.carbsRequiredBody(grams: 26, glucoseMgDL: 75, trendSymbol: "↘︎", units: .mgdL)
        #expect(mgdl.contains("26"))
        #expect(mgdl.contains("75 ↘︎ mg/dL"))
        let noReading = GlucoseAlertCoordinator.carbsRequiredBody(grams: 26, glucoseMgDL: nil, trendSymbol: nil, units: .mgdL)
        #expect(noReading.contains("26"))
        #expect(!noReading.contains("mg/dL"))
    }

    @Test("amount and alert id round-trip through userInfo") func payloadRoundTrip() {
        let info = CarbsRequiredNotification.userInfo(grams: 26, alertID: "abc")
        let payload = CarbsRequiredNotification.payload(from: info)
        #expect(payload.grams == 26)
        #expect(payload.alertID == "abc")
    }

    @Test("logs the amount from the notification") func logsAmount() async {
        let spy = Spy()
        let outcome = await makeHandler(spy: spy).log(grams: 26, alertID: "a1")
        #expect(outcome == .logged)
        #expect(spy.stored == [26])
    }

    @Test("a repeated log with the same alert id is stored once") func duplicateIgnored() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)
        _ = await handler.log(grams: 26, alertID: "a1")
        #expect(await handler.log(grams: 26, alertID: "a1") == .alreadyLogged)
        #expect(await handler.log(grams: 15, alertID: "a2") == .logged)
        #expect(spy.stored == [26, 15])
    }

    @Test("missing or zero grams, or no alert id, is rejected") func invalidRejected() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)
        #expect(await handler.log(grams: nil, alertID: "a1") == .invalidRequest)
        #expect(await handler.log(grams: 0, alertID: "a1") == .invalidRequest)
        #expect(await handler.log(grams: 26, alertID: nil) == .invalidRequest)
        #expect(spy.stored.isEmpty)
    }

    @Test("a failed write does not block a retry of the same alert") func failedWriteAllowsRetry() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)
        spy.shouldThrow = true
        #expect(await handler.log(grams: 26, alertID: "a1") == .failed)
        spy.shouldThrow = false
        #expect(await handler.log(grams: 26, alertID: "a1") == .logged)
        #expect(spy.stored == [26])
    }

    @Test("amount above Max Carbs is rejected: not stored, alert not marked") func exceedsMaxCarbsRejected() async {
        let spy = Spy()
        let suite = UserDefaults(suiteName: "CarbsRequiredNotificationTests.\(UUID().uuidString)")!
        var max: Decimal = 20
        let handler = CarbsRequiredLogHandler(
            store: UserDefaultsLoggedCarbsAlertStore(defaults: suite),
            maxCarbs: { max },
            storeCarbs: { spy.stored.append($0) }
        )
        #expect(await handler.log(grams: 26, alertID: "a1") == .exceedsMaxCarbs)
        #expect(spy.stored.isEmpty)
        // Not marked: once the limit allows it, the same alert can still be logged, at the exact amount.
        max = 30
        #expect(await handler.log(grams: 26, alertID: "a1") == .logged)
        #expect(spy.stored == [26])
    }

    @Test("amount equal to Max Carbs is logged unchanged") func atMaxCarbsLogged() async {
        let spy = Spy()
        #expect(await makeHandler(spy: spy, maxCarbs: 20).log(grams: 20, alertID: "a1") == .logged)
        #expect(spy.stored == [20])
    }

    @Test("fractional grams are rejected") func fractionalRejected() async {
        let spy = Spy()
        #expect(await makeHandler(spy: spy).log(grams: 12.5, alertID: "a1") == .invalidRequest)
        #expect(spy.stored.isEmpty)
    }

    @Test("two handler entry points sharing a defaults suite dedupe the same alert") func guardSharedAcrossHandlers() async {
        let spy = Spy()
        let defaults = UserDefaults(suiteName: "CarbsRequiredNotificationTests.\(UUID().uuidString)")!
        func make() -> CarbsRequiredLogHandler {
            CarbsRequiredLogHandler(
                store: UserDefaultsLoggedCarbsAlertStore(defaults: defaults),
                maxCarbs: { 100 },
                storeCarbs: { spy.stored.append($0) }
            )
        }
        let phone = make()
        let watch = make()
        async let first = phone.log(grams: 26, alertID: "a1")
        async let second = watch.log(grams: 26, alertID: "a1")
        let outcomes = await [first, second]
        #expect(outcomes.filter { $0 == .logged }.count == 1)
        #expect(outcomes.filter { $0 == .alreadyLogged }.count == 1)
        #expect(spy.stored == [26])
    }

    @Test("logged alert ids persist and expire after 24 h") func storePersistsAndPrunes() {
        let defaults = UserDefaults(suiteName: "CarbsRequiredNotificationTests.\(UUID().uuidString)")!
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(UserDefaultsLoggedCarbsAlertStore(defaults: defaults).markLogged("a1", now: t0))
        let reopened = UserDefaultsLoggedCarbsAlertStore(defaults: defaults)
        #expect(!reopened.markLogged("a1", now: t0.addingTimeInterval(60)))
        #expect(reopened.markLogged("a1", now: t0.addingTimeInterval(25 * 60 * 60)))
    }
}
