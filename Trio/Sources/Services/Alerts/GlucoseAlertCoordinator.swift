import Combine
import CoreData
import Foundation
import LoopKit
import Swinject

/// Evaluates user-configured `GlucoseAlert`s on every new CGM reading and every
/// new determination, then issues / retracts alerts via `TrioAlertManager`.
/// Mirrors the LoopFollow alarm-list model — multiple alarms of the same type
/// are allowed, each with its own threshold / schedule / sound.
///
/// Lookup flow:
///   1. CGM update → fetch latest `GlucoseStored` + prior readings.
///      For each enabled alarm matching the current day/night window:
///        - urgentLow / low: latest ≤ threshold (+ optional persistence)
///        - high: latest ≥ threshold (+ optional persistence)
///   2. Determination update → blend forecast at the alarm's predictive horizon
///      (forecastedLow: every 5-min point up to +20 min) and compare to threshold.
///
/// Throttling + snooze are inherited from `TrioAlertManager.issueAlert`. The
/// coordinator additionally tracks per-alarm firing state so it can retract
/// the alert when the condition recovers (no flap-spam).
final class GlucoseAlertCoordinator: Injectable {
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!

    private let evaluationQueue = DispatchQueue(label: "GlucoseAlertCoordinator.queue")
    struct LatestReading {
        let mgdl: Decimal
        let direction: BloodGlucose.Direction?
        /// mg/dL per minute versus the previous reading, nil when there is no usable previous one.
        let deltaPerMinute: Decimal?
        let date: Date
    }

    /// Most recent reading seen by the reading path. Only touched on `evaluationQueue`, so the
    /// carbs-required evaluation can use it without an async fetch (which would let evaluations
    /// of consecutive determinations run out of order).
    private var cachedReading: LatestReading?

    private var firingAlertIDs: Set<UUID> = []
    private var subscriptions = Set<AnyCancellable>()
    @SyncAccess private var alertsSnapshot: [GlucoseAlert] = []
    @SyncAccess private var configurationSnapshot = GlucoseAlertConfiguration()

    /// 5 mg/dL recovery margin before we retract a fired alert. Prevents flap
    /// at the threshold boundary.
    static let recoveryMarginMgDL: Decimal = 5

    /// Pure breach predicate. Low family (low/urgentLow/forecastedLow) breaches
    /// when the value is at or below threshold; high breaches at or above.
    /// `carbsRequired` is determination-driven and evaluated separately.
    /// Extracted for unit testing — the instance evaluators call through here.
    static func breached(type: GlucoseAlertType, latestMgDL: Decimal, thresholdMgDL: Decimal) -> Bool {
        switch type {
        case .forecastedLow,
             .low,
             .urgentLow:
            return latestMgDL <= thresholdMgDL
        case .high:
            return latestMgDL >= thresholdMgDL
        case .carbsRequired:
            return false
        }
    }

    /// Pure retract predicate. A fired low-family alert retracts once the value
    /// recovers to threshold + margin; a high alert once it falls to
    /// threshold - margin. Extracted for unit testing.
    static func shouldRetract(
        type: GlucoseAlertType,
        latestMgDL: Decimal,
        thresholdMgDL: Decimal,
        recoveryMarginMgDL: Decimal = recoveryMarginMgDL
    ) -> Bool {
        switch type {
        case .forecastedLow,
             .low,
             .urgentLow:
            return latestMgDL >= thresholdMgDL + recoveryMarginMgDL
        case .high:
            return latestMgDL <= thresholdMgDL - recoveryMarginMgDL
        case .carbsRequired:
            return false
        }
    }

    static func alarmsToRetractWhenCGMOwnsAlerts(firing: Set<UUID>, in alarms: [GlucoseAlert]) -> [GlucoseAlert] {
        alarms.filter { firing.contains($0.id) && $0.type.isReadingDriven }
    }

    /// Readings older than this are considered stale and won't drive new
    /// alarms — matches `APSManager`'s loop-input freshness gate (12 min,
    /// allowing for one missed CGM transmission on a 5-min schedule).
    /// Without this gate, force-quitting the app and reopening it after a
    /// CGM blackout could fire an alarm based on a 19-min-old reading.
    private static let readingFreshnessWindow: TimeInterval = 12 * 60

    /// Largest gap between the latest and previous reading for which a per-minute delta is shown.
    private static let maxDeltaGap: TimeInterval = 15 * 60

    /// Suppresses evaluations for a short window after launch. `firingAlertIDs`
    /// isn't persisted across relaunches, so without this quiet window the
    /// first reading after launch would re-fire any in-flight alarm whose
    /// glucose is still past threshold. UN throttle dedupes the lock-screen
    /// notification (5-min window), but the in-app banner can re-pop. Skipping
    /// the first ~30s lets the picture settle.
    private static let launchQuietWindow: TimeInterval = 30
    private let launchedAt = Date()
    private var isInLaunchQuietWindow: Bool {
        Date().timeIntervalSince(launchedAt) < Self.launchQuietWindow
    }

    private var effectiveTrioAlertsEnabled: Bool {
        if configurationSnapshot.forceTrioAlertsWhenCGMProvidesOwn { return true }
        return !CGMManagerAlertOwnership.providesOwnGlucoseAlerts(
            manager: fetchGlucoseManager?.cgmManager,
            sourceType: fetchGlucoseManager?.cgmGlucoseSourceType ?? .none
        )
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        let store = GlucoseAlertsStore.shared
        alertsSnapshot = store.alerts
        configurationSnapshot = store.configuration
        store.$alerts
            .sink { [weak self] new in self?.alertsSnapshot = new }
            .store(in: &subscriptions)
        store.$configuration
            .sink { [weak self] new in self?.configurationSnapshot = new }
            .store(in: &subscriptions)
        broadcaster.register(DeterminationObserver.self, observer: self)
        broadcaster.register(SnoozeObserver.self, observer: self)
        broadcaster.register(GlucoseSnoozeObserver.self, observer: self)
        glucoseStorage.updatePublisher
            .sink { [weak self] _ in
                Task { [weak self] in await self?.evaluateGlucoseAlarms() }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Reading-based evaluation

    /// Two-stage: async-fetch the latest value (Core Data perform), then hop
    /// onto `evaluationQueue` to mutate `firingAlertIDs` safely.
    private func evaluateGlucoseAlarms() async {
        guard !isInLaunchQuietWindow else { return }
        guard effectiveTrioAlertsEnabled else {
            retractReadingDrivenFiringAlarms()
            // Carbs Required stays active when the CGM app owns glucose alerts; its body reads this cache.
            if let latestReading = await fetchLatestReading() {
                evaluationQueue.async { [weak self] in self?.cachedReading = latestReading }
            }
            return
        }
        guard let latestReading = await fetchLatestReading() else { return }
        let snapshot = alertsSnapshot
        let configuration = configurationSnapshot
        let now = Date()
        evaluationQueue.async { [weak self] in
            self?.cachedReading = latestReading
            self?.applyReadingBasedEvaluation(
                reading: latestReading,
                snapshot: snapshot,
                configuration: configuration,
                now: now
            )
        }
    }

    private func applyReadingBasedEvaluation(
        reading: LatestReading,
        snapshot: [GlucoseAlert],
        configuration: GlucoseAlertConfiguration,
        now: Date
    ) {
        dispatchPrecondition(condition: .onQueue(evaluationQueue))
        // Iterate in type priority order so we can suppress lesser low-family
        // alarms when a more severe one is firing (urgent low > low). Without
        // this, glucose=60 with both urgent-low (54) AND low (70) configured
        // would surface two in-app alerts for the same low event.
        let sorted = snapshot.sorted { $0.type.priority < $1.type.priority }
        var urgentLowFiring = false
        for alarm in sorted where alarm.type.isReadingDriven {
            if alarm.type == .low, urgentLowFiring {
                retractIfFiring(alarm)
                continue
            }
            evaluateReadingBased(alarm, reading: reading, now: now, configuration: configuration)
            if alarm.type == .urgentLow, firingAlertIDs.contains(alarm.id) {
                urgentLowFiring = true
            }
        }
    }

    private func evaluateReadingBased(
        _ alarm: GlucoseAlert,
        reading: LatestReading,
        now: Date,
        configuration: GlucoseAlertConfiguration
    ) {
        guard alarm.shouldEvaluate, !isAlarmSnoozed(alarm, at: now),
              isActive(alarm, at: now, configuration: configuration)
        else {
            retractIfFiring(alarm)
            return
        }

        if alarm.type == .forecastedLow {
            return // handled via determinationDidUpdate
        }
        let latestMgDL = reading.mgdl
        let breached = Self.breached(
            type: alarm.type,
            latestMgDL: latestMgDL,
            thresholdMgDL: alarm.thresholdMgDL
        )

        if breached {
            fireIfNeeded(alarm, valueMgDL: latestMgDL, configuration: configuration, reading: reading)
        } else if shouldRetract(alarm, latestMgDL: latestMgDL) {
            retractIfFiring(alarm)
        }
    }

    // MARK: - Forecast-based evaluation

    private func evaluateForecast(_ determination: Determination, reading: LatestReading?) {
        guard !isInLaunchQuietWindow else { return }
        // No CGM-ownership guard here, unlike the reading path: a CGM app can
        // alarm on the current reading, but it cannot compute Trio's oref
        // forecast, so it can never cover this alarm. Same reasoning as
        // `evaluateCarbsRequired`, and it matches what the settings screen
        // shows the user — only reading-driven types move into the
        // "Handled by CGM App" section.
        let snapshot = alertsSnapshot
        let configuration = configurationSnapshot
        let now = Date()

        // Suppress forecasted-low if any urgent-low or low alarm is already
        // firing — the forecast came true (or worse), no point preempting
        // it with a second alert.
        let lowFamilyFiring = snapshot.contains { alarm in
            (alarm.type == .urgentLow || alarm.type == .low)
                && firingAlertIDs.contains(alarm.id)
        }

        for alarm in snapshot where alarm.type == .forecastedLow {
            if lowFamilyFiring {
                retractIfFiring(alarm)
                continue
            }
            evaluateForecastBased(alarm, determination: determination, reading: reading, now: now, configuration: configuration)
        }
    }

    private func evaluateForecastBased(
        _ alarm: GlucoseAlert,
        determination: Determination,
        reading: LatestReading?,
        now: Date,
        configuration: GlucoseAlertConfiguration
    ) {
        guard alarm.shouldEvaluate, !isAlarmSnoozed(alarm, at: now),
              isActive(alarm, at: now, configuration: configuration),
              let result = ForecastedGlucoseEvaluator.evaluateWindow(
                  determination: determination,
                  thresholdMgDL: alarm.thresholdMgDL
              )
        else {
            retractIfFiring(alarm)
            return
        }

        if result.lowestPredicted <= alarm.thresholdMgDL {
            fireIfNeeded(
                alarm,
                valueMgDL: result.lowestPredicted,
                configuration: configuration,
                reading: reading,
                minutesToLow: result.firstCrossingMinutes
            )
        } else if shouldRetract(alarm, latestMgDL: result.lowestPredicted) {
            retractIfFiring(alarm)
        }
    }

    // MARK: - Carbs-required evaluation

    /// Mirrors `evaluateForecast` for the carbs-required alarms. The alarm
    /// threshold (grams, stored in `thresholdMgDL`) is independent from the
    /// tab badge's threshold — surfaces are configured separately so the
    /// user can have a low-threshold badge for awareness and a higher-
    /// threshold alarm for active interruption.
    private func evaluateCarbsRequired(_ determination: Determination, reading: LatestReading?) {
        guard !isInLaunchQuietWindow else { return }
        let snapshot = alertsSnapshot
        let configuration = configurationSnapshot
        let now = Date()
        let carbsReq: Decimal? = determination.carbsReq

        for alarm in snapshot where alarm.type == .carbsRequired {
            guard alarm.shouldEvaluate, !isAlarmSnoozed(alarm, at: now),
                  isActive(alarm, at: now, configuration: configuration)
            else {
                retractIfFiring(alarm)
                continue
            }
            guard let carbs = carbsReq, carbs >= alarm.thresholdMgDL else {
                retractIfFiring(alarm)
                continue
            }
            fireIfNeeded(alarm, valueMgDL: carbs, configuration: configuration, reading: reading)
        }
    }

    // MARK: - Issue / retract bookkeeping

    /// Called only from the evaluation queue (forecast + reading paths both
    /// dispatch through `evaluationQueue` before invoking the evaluators),
    /// so `firingAlertIDs` is serialized without an extra `.sync` hop.
    private func fireIfNeeded(
        _ alarm: GlucoseAlert,
        valueMgDL: Decimal,
        configuration: GlucoseAlertConfiguration,
        reading: LatestReading? = nil,
        minutesToLow: Int? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(evaluationQueue))
        guard !firingAlertIDs.contains(alarm.id) else { return }
        firingAlertIDs.insert(alarm.id)

        let title = alarm.name.isEmpty ? alarm.type.displayName : alarm.name
        let body = bodyText(
            for: alarm,
            valueMgDL: valueMgDL,
            configuration: configuration,
            reading: reading,
            minutesToLow: minutesToLow
        )
        if alarm.type == .carbsRequired {
            CarbsRequiredPayloads.shared.set(
                grams: NSDecimalNumber(decimal: valueMgDL).intValue,
                alertID: UUID().uuidString,
                for: alertID(for: alarm).alertIdentifier
            )
        }
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: alertID(for: alarm),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: alarm.overridesSilenceAndDND ? .critical : .timeSensitive,
            sound: alarm.playsSound ? .sound(name: alarm.soundFilename) : nil
        )
        trioAlertManager.issueAlert(alert)
    }

    private func retractIfFiring(_ alarm: GlucoseAlert) {
        dispatchPrecondition(condition: .onQueue(evaluationQueue))
        guard firingAlertIDs.contains(alarm.id) else { return }
        firingAlertIDs.remove(alarm.id)
        trioAlertManager.retractAlert(identifier: alertID(for: alarm))
    }

    private func retractReadingDrivenFiringAlarms() {
        evaluationQueue.async { [weak self] in
            guard let self, !self.firingAlertIDs.isEmpty else { return }
            let toRetract = Self.alarmsToRetractWhenCGMOwnsAlerts(
                firing: self.firingAlertIDs,
                in: self.alertsSnapshot
            )
            for alarm in toRetract {
                self.retractIfFiring(alarm)
            }
        }
    }

    private func shouldRetract(_ alarm: GlucoseAlert, latestMgDL: Decimal) -> Bool {
        dispatchPrecondition(condition: .onQueue(evaluationQueue))
        guard firingAlertIDs.contains(alarm.id) else { return false }
        return Self.shouldRetract(
            type: alarm.type,
            latestMgDL: latestMgDL,
            thresholdMgDL: alarm.thresholdMgDL
        )
    }

    private func alertID(for alarm: GlucoseAlert) -> Alert.Identifier {
        let typeSlug: String
        switch alarm.type {
        case .urgentLow: typeSlug = "urgentLow"
        case .low: typeSlug = "low"
        case .forecastedLow: typeSlug = "forecastedLow"
        case .high: typeSlug = "high"
        case .carbsRequired: typeSlug = "carbsRequired"
        }
        return Alert.Identifier(
            managerIdentifier: BaseTrioAlertManager.managerIdentifier,
            alertIdentifier: "glucose.\(typeSlug).\(alarm.id.uuidString)"
        )
    }

    private func bodyText(
        for alarm: GlucoseAlert,
        valueMgDL: Decimal,
        configuration: GlucoseAlertConfiguration,
        reading: LatestReading?,
        minutesToLow: Int?
    ) -> String {
        let units = settingsManager.settings.units
        switch alarm.type {
        case .high,
             .low,
             .urgentLow:
            // The alarm's own glucose is always shown; the toggles only add delta and trend.
            let clause = Self.readingClause(
                mgdl: valueMgDL,
                deltaPerMinute: reading?.deltaPerMinute,
                direction: reading?.direction,
                units: units,
                showDelta: configuration.showGlucoseDelta,
                showTrend: configuration.showTrendDescription
            )
            return String(format: String(localized: "Glucose %1$@."), clause)
        case .forecastedLow:
            return Self.forecastedLowBody(
                minutes: minutesToLow ?? ForecastedGlucoseEvaluator.defaultHorizonMinutes,
                thresholdMgDL: alarm.thresholdMgDL,
                reading: reading,
                configuration: configuration,
                units: units
            )
        case .carbsRequired:
            return Self.carbsRequiredBody(
                grams: Int(NSDecimalNumber(decimal: valueMgDL).intValue),
                reading: reading,
                configuration: configuration,
                units: units
            )
        }
    }

    /// "102 mg/dL (-4.6/min), falling slowly"; delta and trend are optional.
    static func readingClause(
        mgdl: Decimal,
        deltaPerMinute: Decimal?,
        direction: BloodGlucose.Direction?,
        units: GlucoseUnits,
        showDelta: Bool,
        showTrend: Bool
    ) -> String {
        var clause = mgdl.formatted(withUnits: units)
        if showDelta, let deltaPerMinute {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.positivePrefix = "+"
            let digits = units == .mmolL ? 2 : 1
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            // Not `asMmolL`: it rounds to 1 digit, which would flatten a per-minute delta.
            let value = units == .mmolL ? deltaPerMinute * GlucoseUnits.exchangeRate : deltaPerMinute
            if let signed = formatter.string(from: value as NSDecimalNumber) {
                clause += " (" + String(format: String(localized: "%@/min"), signed) + ")"
            }
        }
        if showTrend, let word = trendWord(direction) {
            clause += ", " + word
        }
        return clause
    }

    private static func trendWord(_ direction: BloodGlucose.Direction?) -> String? {
        switch direction {
        case .doubleUp,
             .tripleUp:
            return String(localized: "rising quickly", comment: "Accessibility: glucose trend")
        case .singleUp:
            return String(localized: "rising", comment: "Accessibility: glucose trend")
        case .fortyFiveUp:
            return String(localized: "rising slowly", comment: "Accessibility: glucose trend")
        case .flat:
            return String(localized: "steady", comment: "Accessibility: glucose trend")
        case .fortyFiveDown:
            return String(localized: "falling slowly", comment: "Accessibility: glucose trend")
        case .singleDown:
            return String(localized: "falling", comment: "Accessibility: glucose trend")
        case .doubleDown,
             .tripleDown:
            return String(localized: "falling quickly", comment: "Accessibility: glucose trend")
        default:
            return nil
        }
    }

    /// With "Show Current Glucose" on and a fresh reading, the prediction is prefixed by the
    /// glucose, and replaced by "already below" when the reading is under the threshold.
    static func forecastedLowBody(
        minutes: Int,
        thresholdMgDL: Decimal,
        reading: LatestReading?,
        configuration: GlucoseAlertConfiguration,
        units: GlucoseUnits
    ) -> String {
        let limitString = thresholdMgDL.formatted(withUnits: units)
        let prediction = String(
            format: String(localized: "Your glucose may go below %2$@ in %1$d min."),
            minutes, limitString
        )
        guard configuration.showCurrentGlucose, let reading else { return prediction }
        let clause = readingClause(
            mgdl: reading.mgdl,
            deltaPerMinute: reading.deltaPerMinute,
            direction: reading.direction,
            units: units,
            showDelta: configuration.showGlucoseDelta,
            showTrend: configuration.showTrendDescription
        )
        let current = String(format: String(localized: "Glucose %1$@."), clause)
        let outlook = reading.mgdl < thresholdMgDL
            ? String(format: String(localized: "Your glucose is already below %@."), limitString)
            : prediction
        return current + " " + outlook
    }

    /// The grams here are the ones the "Log Carbs" action records, so the user sees
    /// exactly what a tap will log. The glucose is appended only with "Show Current Glucose" on.
    static func carbsRequiredBody(
        grams: Int,
        reading: LatestReading?,
        configuration: GlucoseAlertConfiguration,
        units: GlucoseUnits
    ) -> String {
        let required = String(format: String(localized: "To prevent LOW required %d g of carbs"), grams)
        guard configuration.showCurrentGlucose, let reading else { return required }
        let clause = readingClause(
            mgdl: reading.mgdl,
            deltaPerMinute: reading.deltaPerMinute,
            direction: reading.direction,
            units: units,
            showDelta: configuration.showGlucoseDelta,
            showTrend: configuration.showTrendDescription
        )
        return required + ". " + String(format: String(localized: "Glucose %1$@."), clause)
    }

    // MARK: - Helpers

    private func isAlarmSnoozed(_ alarm: GlucoseAlert, at date: Date) -> Bool {
        guard let until = alarm.snoozedUntil else { return false }
        return until > date
    }

    private func isActive(_ alarm: GlucoseAlert, at date: Date, configuration: GlucoseAlertConfiguration) -> Bool {
        switch alarm.activeOption {
        case .always: return true
        case .day: return !configuration.isNight(at: date)
        case .night: return configuration.isNight(at: date)
        }
    }

    /// Async fetch matching Trio's standard Core Data pattern — never blocks
    /// the caller's thread, never lets a `GlucoseStored` managed object cross
    /// queue boundaries (would otherwise trip
    /// `_PFAssertSafeMultiThreadedAccess_impl`).
    private func fetchLatestReading() async -> LatestReading? {
        // The previous reading may be up to `maxDeltaGap` older than the latest, which itself
        // must be inside the freshness window; only the latest is gated on freshness below.
        let freshnessCutoff = Date().addingTimeInterval(-Self.readingFreshnessWindow)
        let cutoff = freshnessCutoff.addingTimeInterval(-Self.maxDeltaGap)
        let predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "GlucoseAlertCoordinator.fetchLatestReading"
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: predicate,
                key: "date",
                ascending: false,
                fetchLimit: 2
            )
            return await context.perform {
                guard let readings = results as? [GlucoseStored], let latest = readings.first,
                      let latestDate = latest.date, latestDate >= freshnessCutoff
                else { return nil }
                var deltaPerMinute: Decimal?
                if readings.count > 1, let previousDate = readings[1].date {
                    let minutes = Decimal(latestDate.timeIntervalSince(previousDate) / 60)
                    if minutes >= 1, minutes <= Decimal(Self.maxDeltaGap / 60) {
                        deltaPerMinute = (Decimal(latest.glucose) - Decimal(readings[1].glucose)) / minutes
                    }
                }
                return LatestReading(
                    mgdl: Decimal(latest.glucose),
                    direction: latest.directionEnum,
                    deltaPerMinute: deltaPerMinute,
                    date: latestDate
                )
            }
        } catch {
            warning(.alerts, "Fetching latest glucose for glucose alerts failed", error: error)
            return nil
        }
    }
}

extension GlucoseAlertCoordinator: DeterminationObserver {
    func determinationDidUpdate(_ determination: Determination) {
        evaluationQueue.async { [weak self] in
            let reading = self?.freshCachedReading()
            self?.evaluateForecast(determination, reading: reading)
            self?.evaluateCarbsRequired(determination, reading: reading)
        }
    }
}

extension GlucoseAlertCoordinator {
    /// The cached reading, or nil once it is older than the freshness window; the alert body
    /// then omits the glucose.
    private func freshCachedReading() -> LatestReading? {
        dispatchPrecondition(condition: .onQueue(evaluationQueue))
        guard let reading = cachedReading,
              reading.date >= Date().addingTimeInterval(-Self.readingFreshnessWindow)
        else { return nil }
        return reading
    }
}

extension GlucoseAlertCoordinator: SnoozeObserver {
    /// Global snooze (Snooze module / lock-screen action). Clear all firing
    /// IDs so the post-snooze evaluation can re-fire fresh if any condition
    /// still breaches.
    func snoozeDidChange(_ untilDate: Date) {
        // Mirror the global snooze onto per-alarm snoozedUntil: alarms with
        // "Override Silence & DnD" are issued .critical and pierce the
        // AlertMuter, so the shared mute window alone can't hold them. A
        // shorter per-type snooze (e.g. a 15-min swipe) would otherwise
        // resurface them mid-window. Urgent low keeps its 15-minute safety
        // floor and is never bulk-snoozed. An ended snooze (.distantPast)
        // clears the stamps the same way.
        for type in GlucoseAlertType.allCases where type != .urgentLow {
            snoozeGlucoseType(type, until: untilDate)
        }
        guard untilDate > Date() else { return }
        evaluationQueue.async { [weak self] in
            self?.firingAlertIDs.removeAll()
        }
    }
}

extension GlucoseAlertCoordinator: GlucoseSnoozeObserver {
    /// Per-type snooze from an in-app banner tap / swipe / menu choice.
    /// Stamps `snoozedUntil` on every matching `GlucoseAlert`, retracts every
    /// in-flight alert of that type (so a stacked deck of multiple low
    /// alarms dismisses as one unit), and drops matching entries from
    /// `firingAlertIDs` so the next post-snooze reading evaluates fresh.
    func snoozeGlucoseType(_ type: GlucoseAlertType, until untilDate: Date) {
        DispatchQueue.main.async {
            let store = GlucoseAlertsStore.shared
            var updated = store.alerts
            var matchingAlarms: [GlucoseAlert] = []
            for index in updated.indices where updated[index].type == type {
                updated[index].snoozedUntil = untilDate
                matchingAlarms.append(updated[index])
            }
            guard !matchingAlarms.isEmpty else { return }
            store.alerts = updated
            for alarm in matchingAlarms {
                self.trioAlertManager.retractAlert(identifier: self.alertID(for: alarm))
            }
            let ids = Set(matchingAlarms.map(\.id))
            self.evaluationQueue.async { [weak self] in
                self?.firingAlertIDs.subtract(ids)
            }
        }
    }
}
