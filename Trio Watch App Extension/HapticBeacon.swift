import Foundation
import WatchKit

/// Cadence-aware haptic beacon for the watch app. Predicts when the next G7 EGV will arrive
/// (5-min cadence anchored on receipt time) and signals the user via haptics:
///
/// - **Pre-EGV ramp:** seven beats from T-5s through ~T-0.5s — paired `.click`, paired `.start`,
///   triple `.notification` (escalating intensity clusters ending right before the expected reading).
///   Each beat carries a unique telemetry label (`ramp_click_1`, `ramp_click_2`, …).
/// - **Success (BLE only):** `.success` × 3 at 0 ms, 200 ms, 350 ms (accelerating spacing). The first
///   beat plays synchronously so a fresh EGV cancelling its own predicted-miss can't drop the
///   confirmation. The remaining beats are sub-timers (`success_2`, `success_3`).
/// - **Relayed-source arrival:** WC / HealthKit deliveries that pass the precedence and dedup gates
///   fire a single `.click` (`relayed_confirm`) — *not* the BLE success triple. Relayed payloads
///   are inherently late, batched, or replayed, so the strong "fresh reading" confirmation is
///   reserved for direct BLE.
/// - **Miss:** `.retry` × 2 at 0 ms and 300 ms after the grace deadline. Same synchronous-first-beat
///   pattern as success; second beat is a sub-timer (`retry_2`).
///
/// Delivery prefers `WKExtendedRuntimeSession.notifyUser(hapticType:)` when
/// `G7WatchSensorAdapter.shared.currentExtendedSession` is non-nil and `.running` (the only
/// state in which `notifyUser` is documented to deliver), and falls back to
/// `WKInterfaceDevice.current().play(_:)` otherwise. The two paths are distinguished in
/// telemetry by `delivered_via=extended_session|device` so on-device verification can correlate
/// "haptic felt at the wrist" with "session was running at fire time" event by event.
///
/// **Adapter stopped:** When `G7WatchSensorAdapter.shared.isIntentionallyStopped` is true, the
/// beacon stays silent — pending timers are cancelled and any incoming `play(_:label:)` is suppressed
/// with a `haptic_skipped` log line. This avoids false-positive miss buzzes after extended-session
/// invalidation or manual stop. The adapter's `isStopped` flag is authoritative; the published
/// `g7DirectBleStatus` mirror defaults to `.off` at cold start and would incorrectly suppress the
/// first EGV after launch if used for this check.
///
/// **Extended session:** The beacon does not cache `WKExtendedRuntimeSession`. The adapter may
/// replace the session from `stop()`, `renewSessionIfNeeded()`, or
/// `extendedRuntimeSessionWillExpire`, so `play(_:label:)` re-queries `currentExtendedSession`
/// on every fire rather than holding a reference.
///
/// **Source policy:**
/// - `.ble` (default): only `.g7DirectBLE` arms cycles; WC / HK are silently dropped with
///   `egv_ignored reason=source_filtered`.
/// - `.bleAndRelayedFallback`: WC / HK arm cycles **only** when no recent BLE EGV exists. BLE
///   always wins — a relayed delivery cannot displace an active BLE cycle. When BLE is stale or
///   never seen this process, a relayed reading arms cadence and fires the quiet relayed-confirm
///   click. Telemetry tags every `armed` / `cancelled` / `fired` line with the source.
/// - **Dedup:** every accepted reading carries a `readingDate`. A reading whose `readingDate` is
///   not strictly newer than the last accepted reading is rejected as a duplicate (`egv_ignored
///   reason=duplicate`). This catches HK ↔ WC ↔ BLE replay overlap and rapid batched WC deliveries
///   that arrive pre-debounce (the data store's `minInterval=5` does not cover the beacon).
///
/// **Reserved haptic types:** `.failure`, `.directionUp`, `.directionDown`, and `.stop` are left
/// for a possible future clinical alerter and are not used in this beacon's palette.
@MainActor
final class HapticBeacon {
    static let shared = HapticBeacon()

    // MARK: - Tuning constants

    /// G7 nominal cadence (5 min). Mirrors `ComplicationDebugView.expectedReadingCadence`.
    private static let expectedCadence: TimeInterval = 300
    /// Ramp begins this far before expected EGV. Five-second window covers the seven-beat sequence.
    private static let rampLeadTime: TimeInterval = 5
    /// Time after expected EGV before declaring a miss.
    private static let missGracePeriod: TimeInterval = 20
    /// Do not rearm if last receipt was older than this — system is likely down or stale.
    private static let staleThreshold: TimeInterval = 600
    /// BLE freshness window for source precedence. While a BLE receipt is younger than this,
    /// relayed (WC / HK) deliveries are dropped with `egv_ignored reason=ble_recent` so they cannot
    /// displace an active BLE cycle. Set just above one cadence + grace (320 s) so a single missed
    /// BLE cycle still counts as "BLE recent"; two consecutive BLE misses opens the relayed path.
    private static let bleFreshnessWindow: TimeInterval = 360
    /// Maximum sensor-to-watch latency a relayed (WC / HK) reading may have to be eligible for
    /// rearming cadence after a stale-gap recovery. After a long outage (`gap > staleThreshold`),
    /// BLE deliveries always log `rearm_skipped reason=stale_gap` and stop at the confirmation;
    /// relayed deliveries instead consult this gate. A relayed reading whose `receiptDate −
    /// readingDate` is below this threshold is treated as a fresh sensor reading good enough to
    /// re-anchor cadence (so fallback mode actually restores prediction after a BLE outage); a
    /// relayed reading older than this is assumed to be a batched / catch-up payload that would
    /// produce a wrong "next cadence" prediction, so it logs `rearm_skipped
    /// reason=stale_gap_relayed_not_fresh` and stops at the confirmation. 30 s comfortably covers
    /// healthy WC hop latency (typically < 5 s) without admitting old HK batch syncs.
    private static let relayedFreshnessForRearmAfterGap: TimeInterval = 30
    /// Success triple-buzz delays (BLE only). Spacing tightens (200 ms then 150 ms). The first beat
    /// (`success_1`) is played synchronously by `fireSuccess()`; only `success_2` and `success_3` are
    /// scheduled as sub-timers.
    private static let successBuzzSteps: [(TimeInterval, WKHapticType, String)] = [
        (0.0, .success, "success_1"),
        (0.2, .success, "success_2"),
        (0.35, .success, "success_3"),
    ]

    /// Miss double-buzz delays. First beat (`retry_1`) plays synchronously; only `retry_2` is
    /// scheduled as a sub-timer.
    private static let missRetrySteps: [(TimeInterval, WKHapticType, String)] = [
        (0.0, .retry, "retry_1"),
        (0.3, .retry, "retry_2"),
    ]
    /// Leeway for `DispatchSourceTimer` schedules. 500 ms is forgiving on Apple Watch SE and older
    /// hardware; tighten if observed fire jitter exceeds expectations.
    private static let timerLeeway: DispatchTimeInterval = .milliseconds(500)

    // MARK: - Persistence

    private enum Keys {
        static let isEnabled = "HapticBeacon.isEnabled"
        static let sourceFilter = "HapticBeacon.sourceFilter"
    }

    /// Which provenance sources are accepted by `noteEGVReceived`.
    /// - `.ble`: only `.g7DirectBLE` arms cycles. Default.
    /// - `.bleAndRelayedFallback`: BLE always wins; WC / HK only arm when no recent BLE EGV (see
    ///   `bleFreshnessWindow`). Relayed deliveries fire a single quiet click (`relayed_confirm`),
    ///   not the BLE success triple.
    enum SourceFilter: String {
        case ble
        case bleAndRelayedFallback = "ble_relayed_fallback"
    }

    /// Opt-in toggle backed by `UserDefaults.standard`; default off when the key is absent.
    /// Stored in the watch extension only (not App Group). Read on each access; `setEnabled(_:)`
    /// is the sole writer so toggles stay coherent with persisted state.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    /// Persisted source filter. Read on each access; `setSourceFilter(_:)` is the sole writer.
    /// Default `.ble` when the key is absent or holds an unrecognized rawValue. Migrates the
    /// historical `"all"` value to `.bleAndRelayedFallback` so users who toggled the old enum keep
    /// their preference (with the new precedence semantics applied).
    var sourceFilter: SourceFilter {
        guard let raw = UserDefaults.standard.string(forKey: Keys.sourceFilter) else { return .ble }
        if let value = SourceFilter(rawValue: raw) { return value }
        if raw == "all" { return .bleAndRelayedFallback }
        return .ble
    }

    // MARK: - Timer state (touched only on `@MainActor`)

    /// Serial queue for `DispatchSourceTimer` scheduling. Matches the adapter's timer-queue pattern.
    /// Handlers hop back to `@MainActor` via `Task { @MainActor in … }` before touching beacon state
    /// or playing haptics.
    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.haptic.timers", qos: .utility)

    private var rampTimer: DispatchSourceTimer?
    /// Generation id paired with `rampTimer`. Timer callbacks capture this UUID; the handler runs only
    /// if `rampTimerID` still matches — so a stale callback cannot clear or replace a *new* timer after
    /// cancel-and-reschedule (e.g. fresh EGV arriving just after the ramp deadline fired). Same idea as
    /// UUID keys on `rampSubTimers`.
    private var rampTimerID: UUID?
    /// Ramp sub-timers from `fireRamp()` (seven beats). Dictionary keyed by UUID so each firing
    /// removes its entry; when empty, ramp playback finished. Count at cancel time feeds `pending_count`.
    private var rampSubTimers: [UUID: DispatchSourceTimer] = [:]
    private var missTimer: DispatchSourceTimer?
    /// Generation id paired with `missTimer`; same stale-handler semantics as `rampTimerID`.
    private var missTimerID: UUID?
    /// Companion sub-timers for the success triple (`success_2`, `success_3`). The first beat
    /// (`success_1`) plays synchronously in `fireSuccess()` and is never tracked here, so a
    /// `phase=success_sub` cancellation log describes lost *companion* beats — not a missed
    /// confirmation of EGV arrival. Treat as "post-confirmation polish was interrupted", not as
    /// a prediction-reliability signal.
    private var successSubTimers: [UUID: DispatchSourceTimer] = [:]
    /// Companion sub-timer for the miss double (`retry_2`). Same companion semantics as
    /// `successSubTimers` — the first retry plays synchronously in `fireMiss()`.
    private var missSubTimers: [UUID: DispatchSourceTimer] = [:]

    /// Receipt time of the last accepted `noteEGVReceived` call. Cadence anchor.
    private var lastReceiptAt: Date?

    /// `readingDate` of the last accepted EGV (any source). Drives duplicate-suppression: a reading
    /// whose `readingDate <= lastAcceptedReadingDate` is dropped before any state mutation. Catches
    /// HK / WC / BLE replay overlap, rapid batched WC deliveries (pre-debounce), and same-snapshot
    /// echoes across channels.
    ///
    /// **Warm-arm exception:** `attemptBLEWarmArm` *does* seed this with the synthetic anchor
    /// (`bleLastEGVDate`). That anchor is the sensor `readingDate` of the last BLE reading the watch
    /// already received, so any same-`readingDate` echo through WC / HK after warm-arm is correctly
    /// dropped as a duplicate. The next live BLE EGV arrives with a strictly newer `readingDate`
    /// (the G7 BLE adapter dedups same-`sequence` deliveries before they reach `noteEGVReceived`,
    /// so no two `noteEGVReceived` calls share a `readingDate` from the live BLE path) and is
    /// accepted normally — warm-arm seeding does not suppress the next real BLE success triple.
    private var lastAcceptedReadingDate: Date?

    /// Receipt time of the last accepted *BLE* EGV. Drives source precedence: while younger than
    /// `bleFreshnessWindow`, relayed (WC / HK) deliveries are rejected with `reason=ble_recent`.
    ///
    /// **Only real BLE deliveries write this slot.** `attemptBLEWarmArm` deliberately leaves it
    /// alone: warm-arm uses a sensor `readingDate` as a synthetic cadence anchor, not a watch
    /// receipt time, so storing it here would conflate the two clocks and slightly skew the
    /// freshness gate. After warm-arm and before the first real BLE EGV, `lastBLEReceiptAt` is
    /// either nil (fresh process) or whatever a prior live arrival left behind, and the
    /// precedence gate behaves accordingly. This is the desired behavior — warm-arm advertises
    /// "I think a BLE cycle is in flight" without falsely advertising "BLE just delivered."
    private var lastBLEReceiptAt: Date?

    /// Source of the cycle currently anchored on `lastReceiptAt`. Used so `armed`, `cancelled`, and
    /// `fired` log lines can carry a `source=ble|hk|wc|unknown` tag matching the EGV that armed
    /// them. `cancelAllTimers()` does **not** touch this slot; teardown callers (`stop`,
    /// `setEnabled(false)`, `setSourceFilter` narrowing) use `clearCurrentCycle()` instead, which
    /// cancels timers *and* nils this. Rearm callers (`noteEGVReceived`, warm-arm) call
    /// `cancelAllTimers()` and then immediately reassign this to the new cycle's source.
    private var lastCycleSource: TrioComplicationDataSource?

    private init() {}

    // MARK: - Public API

    /// Idempotent hook for foreground entry. Arming happens only via `noteEGVReceived` from the
    /// adapter (BLE) or `WatchState` (WC / HK). The `source_filter=` field captures the persisted
    /// `sourceFilter` value at startup so analysts can correlate later `egv_ignored` lines with the
    /// active policy without scanning back for the most recent `setSourceFilter` event.
    func start() {
        log("start", "is_enabled=\(isEnabled) source_filter=\(sourceFilter.rawValue)")
    }

    /// Idempotent. Cancels timers and clears cycle state. Not used on background transition today
    /// (BLE keeps running); kept for symmetry and future lifecycle policy.
    func stop() {
        clearCurrentCycle()
        lastReceiptAt = nil
        log("stop")
    }

    /// Persisted source filter writer.
    /// - Narrowing `.bleAndRelayedFallback` → `.ble` while a non-BLE cycle is armed cancels in-flight
    ///   timers (the WC / HK cycle is no longer trusted under the new policy), then attempts a BLE
    ///   warm-arm so the user is not left without a beacon. If `bleLastEGVDate` is recent the cycle
    ///   re-arms on BLE; otherwise the standard `warm_arm_skipped` reasons apply.
    /// - Widening `.ble` → `.bleAndRelayedFallback` is a no-op for any active BLE cycle (it would
    ///   not be displaced even by a relayed reading per the precedence rules); the next non-BLE
    ///   EGV during a BLE-stale window will arm a fresh cycle.
    func setSourceFilter(_ filter: SourceFilter) {
        let previous = sourceFilter
        guard filter != previous else { return }
        UserDefaults.standard.set(filter.rawValue, forKey: Keys.sourceFilter)
        if filter == .ble,
           let cycleSource = lastCycleSource,
           cycleSource != .g7DirectBLE
        {
            let priorTag = Self.shortTag(for: cycleSource)
            clearCurrentCycle()
            lastReceiptAt = nil
            log("setSourceFilter", "value=\(filter.rawValue) action=cancelled_pending_timers prior_cycle_source=\(priorTag)")
            attemptBLEWarmArm(trigger: "source_filter_narrow")
            return
        }
        log("setSourceFilter", "value=\(filter.rawValue)")
    }

    /// Persisted toggle. Disabling cancels in-flight timers so a mid-ramp toggle does not keep buzzing.
    ///
    /// Enabling may **warm-arm** (BLE only): if `WatchState.shared.bleLastEGVDate` is recent, use it as a
    /// synthetic anchor and schedule ramp/miss without waiting for the next live EGV. No success / relayed
    /// haptics on warm-arm — no reading is arriving at toggle time.
    ///
    /// **Anchor vs receipt time:** `bleLastEGVDate` is the sensor `readingDate`, not watch receipt time.
    /// Typical drift is a few seconds; warm-arm is approximate. A precise anchor would need receipt time
    /// plumbed through state or persisting `lastReceiptAt`.
    ///
    /// **Gate:** Warm-arm runs only when anchor age is below `expectedCadence + missGracePeriod` (320 s).
    /// Older anchors skip with `warm_arm_skipped reason=cycle_already_expired`. Between ~295 s and ~319 s,
    /// the ramp deadline may already be past while the miss deadline is still ahead; `rearm(after:)` skips
    /// only the overdue phase (logs `rearm_skipped reason=deadline_passed phase=ramp`) and still arms miss
    /// — partial warm-arm (with the 5 s ramp window: ramp skipped, miss still armed).
    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        guard enabled != wasEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: Keys.isEnabled)
        if !enabled {
            clearCurrentCycle()
            // Clear the anchor so a later re-enable starts from the first-EGV-after-launch path
            // instead of comparing the next live EGV to an hours-old or days-old prior receipt
            // (which would correctly but confusingly emit `rearm_skipped reason=stale_gap`).
            lastReceiptAt = nil
            lastBLEReceiptAt = nil
            // Clearing dedup means a disable / re-enable inside a single 5-min cycle could let a
            // replay of the just-seen reading arm a second cycle. Acceptable for the current
            // debug-only beacon toggle (used during on-device verification, not part of normal UX).
            // If this becomes user-facing, consider preserving dedup across enable toggles within
            // process lifetime so toggle-thrash cannot replay haptics.
            lastAcceptedReadingDate = nil
            log("setEnabled", "enabled=false action=cancelled_pending_timers")
            return
        }

        log("setEnabled", "enabled=true")
        attemptBLEWarmArm(trigger: "setEnabled")
    }

    /// Single hook when an EGV is received. Honors `sourceFilter`, dedups by `readingDate`, and
    /// enforces source precedence (BLE always wins; relayed sources only when BLE is stale or
    /// absent). Rejected deliveries always log a single `egv_ignored reason=…` line so analysts
    /// can size each gate's volume.
    ///
    /// Parameters:
    /// - `receiptDate`: when the watch received the payload (used as the cadence anchor — the
    ///   sensor `readingDate` is what gets cached and shipped through WC / HK and so already
    ///   carries unknown latency by the time we see it).
    /// - `readingDate`: the sensor reading instant (used for dedup only; **not** the cadence
    ///   anchor — see `receiptDate`).
    /// - `source`: provenance for filter, precedence, and per-cycle telemetry.
    func noteEGVReceived(at receiptDate: Date, readingDate: Date, source: TrioComplicationDataSource) {
        guard isEnabled else { return }
        let sourceTag = Self.shortTag(for: source)
        let activeFilter = sourceFilter

        if !accepts(source: source, under: activeFilter) {
            log("egv_ignored", "reason=source_filtered source=\(sourceTag) filter=\(activeFilter.rawValue)")
            return
        }
        guard !isAdapterStopped() else {
            // Unlikely while stopped; drop quietly if a delegate races teardown.
            clearCurrentCycle()
            log("haptic_skipped", "reason=adapter_stopped phase=success source=\(sourceTag)")
            return
        }

        // Dedup by `readingDate <= lastAcceptedReadingDate` assumes the sensor reading clock is
        // monotonic across all accepted sources (live BLE, WC echoes, HK reads). In steady state
        // each new sensor reading has a strictly newer `glucoseTimestamp`, so the assumption
        // holds. If a future source reorders deliveries, the worst case is a real reading being
        // dropped as `duplicate` (silent, no haptic) rather than a false haptic — the
        // `reading_age_s` and `last_reading_age_s` fields below let analysts spot ordering issues
        // by comparing per-source ages on the dropped events.
        if let last = lastAcceptedReadingDate, readingDate <= last {
            let readingAge = Int(receiptDate.timeIntervalSince(readingDate))
            let lastReadingAge = Int(receiptDate.timeIntervalSince(last))
            log(
                "egv_ignored",
                "reason=duplicate source=\(sourceTag) reading_age_s=\(readingAge) last_reading_age_s=\(lastReadingAge)"
            )
            return
        }

        let isBLE = (source == .g7DirectBLE)
        if !isBLE, let lastBLE = lastBLEReceiptAt {
            let bleAge = receiptDate.timeIntervalSince(lastBLE)
            if bleAge < Self.bleFreshnessWindow {
                log("egv_ignored", "reason=ble_recent source=\(sourceTag) ble_age_s=\(Int(bleAge))")
                return
            }
        }

        // Compare gap between consecutive receipts for stale-gap logic — not freshness of this receipt alone.
        let priorReceiptAt = lastReceiptAt

        // Tear down the prior cycle's timers but leave `lastCycleSource` set so cancellation
        // telemetry still tags the *prior* cycle. The new cycle's source is assigned immediately
        // below before any new log line is emitted.
        cancelAllTimers()
        lastReceiptAt = receiptDate
        lastCycleSource = source
        lastAcceptedReadingDate = readingDate

        if isBLE {
            lastBLEReceiptAt = receiptDate
            fireSuccess()
        } else {
            fireRelayedConfirm()
        }

        if let prior = priorReceiptAt {
            let gap = receiptDate.timeIntervalSince(prior)
            if gap > Self.staleThreshold {
                // Stale-gap policy is split by source so fallback mode can actually restore cadence
                // after a long BLE outage:
                // - BLE: confirm only. The success triple already played; cadence prediction stays
                //   off until the next BLE EGV proves the cycle is stable. A long-gap BLE EGV is
                //   often the recovery edge of an outage, not a steady-state cadence anchor.
                // - Relayed (WC / HK): allowed to rearm only if the *relayed reading itself* is
                //   fresh (sensor-to-watch latency below `relayedFreshnessForRearmAfterGap`). This
                //   lets fallback mode re-anchor cadence on a real-time relayed reading after BLE
                //   has been quiet for >10 minutes; late HK / WC payloads (batched sync from
                //   minutes or hours ago) are still skipped so they cannot predict a wrong "next"
                //   cadence. See the constant's doc comment for the rationale on the 30 s gate.
                if isBLE {
                    log("rearm_skipped", "reason=stale_gap gap_s=\(Int(gap)) source=\(sourceTag)")
                    return
                }
                let relayedLatency = receiptDate.timeIntervalSince(readingDate)
                if relayedLatency >= Self.relayedFreshnessForRearmAfterGap {
                    log(
                        "rearm_skipped",
                        "reason=stale_gap_relayed_not_fresh gap_s=\(Int(gap)) reading_age_s=\(Int(relayedLatency)) source=\(sourceTag)"
                    )
                    return
                }
                // Fall through to `rearm(after:)`. Distinct event so analysts can size how often
                // fallback recovers cadence and at what latency, without confusing it with normal
                // (no-stale-gap) rearms.
                log(
                    "rearm_after_stale_gap",
                    "reason=relayed_fresh gap_s=\(Int(gap)) reading_age_s=\(Int(relayedLatency)) source=\(sourceTag)"
                )
            }
        }

        rearm(after: receiptDate)
    }

    private func accepts(source: TrioComplicationDataSource, under filter: SourceFilter) -> Bool {
        switch filter {
        case .ble:
            return source == .g7DirectBLE
        case .bleAndRelayedFallback:
            return source == .g7DirectBLE || source == .watchConnectivity || source == .healthKit
        }
    }

    /// Short tag for `source=` log fields. Stable shape (`ble|wc|hk|unknown`) so Better Stack
    /// queries can group by provenance without mapping the raw enum strings each time.
    private static func shortTag(for source: TrioComplicationDataSource) -> String {
        switch source {
        case .g7DirectBLE: return "ble"
        case .watchConnectivity: return "wc"
        case .healthKit: return "hk"
        case .unknown: return "unknown"
        }
    }

    private func currentSourceTag() -> String {
        Self.shortTag(for: lastCycleSource ?? .unknown)
    }

    // MARK: - Internal: warm-arm

    /// Shared BLE warm-arm helper. Used by `setEnabled(true)` and `setSourceFilter(.ble)` when
    /// narrowing displaces a non-BLE cycle. Each silent early-return emits a `warm_arm_skipped`
    /// line with a distinct `reason` and a `trigger=` tag so analysts can tell why warm-arm did or
    /// didn't run after a given user action.
    private func attemptBLEWarmArm(trigger: String) {
        guard !isAdapterStopped() else {
            log("warm_arm_skipped", "reason=adapter_stopped trigger=\(trigger)")
            return
        }
        guard let bleLastEGV = WatchState.shared.bleLastEGVDate,
              bleLastEGV != .distantPast
        else {
            log("warm_arm_skipped", "reason=no_anchor trigger=\(trigger)")
            return
        }
        let age = Date().timeIntervalSince(bleLastEGV)
        guard age >= 0 else {
            log("warm_arm_skipped", "reason=anchor_in_future anchor_age_s=\(Int(age)) trigger=\(trigger)")
            return
        }
        guard age < Self.expectedCadence + Self.missGracePeriod else {
            log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age)) trigger=\(trigger)")
            return
        }

        cancelAllTimers()
        lastReceiptAt = bleLastEGV
        lastCycleSource = .g7DirectBLE
        // Seed dedup with the synthetic anchor so a same-`readingDate` echo via WC / HK after
        // warm-arm is dropped as a duplicate (otherwise a relayed mirror of the BLE reading we
        // already saw would arm a redundant cycle). The next live BLE EGV has a strictly newer
        // `readingDate` (G7 adapter same-`sequence` dedup happens before `noteEGVReceived`), so
        // this seeding does not suppress the next real BLE success triple. See the
        // `lastAcceptedReadingDate` doc comment for the full invariant.
        lastAcceptedReadingDate = bleLastEGV
        // Note: `lastBLEReceiptAt` is intentionally *not* seeded — it tracks watch receipt time
        // of real BLE arrivals, while `bleLastEGV` is a sensor reading time. See its doc comment.
        rearm(after: bleLastEGV)
        log("warm_armed", "anchor_age_s=\(Int(age)) source=\(Self.shortTag(for: .g7DirectBLE)) trigger=\(trigger)")
    }

    // MARK: - Internal: scheduling

    /// Schedules ramp and miss one-shots from `receiptDate`. Stale-gap skipping lives in `noteEGVReceived`.
    ///
    /// Each deadline is evaluated against `now` before scheduling. Live EGVs use `receiptDate == now`, so
    /// both deadlines are ~295–320 s ahead. Warm-arm with an older synthetic anchor may skip only ramp or
    /// only miss when that deadline is already past — avoids `scheduleRampTimer` firing immediately on a
    /// stale ramp instant. Skips log `rearm_skipped reason=deadline_passed` with phase and anchor age;
    /// analysts should treat that as expected partial warm-arm, not necessarily a failure.
    private func rearm(after receiptDate: Date) {
        let now = Date()
        let rampAt = receiptDate.addingTimeInterval(Self.expectedCadence - Self.rampLeadTime)
        let missAt = receiptDate.addingTimeInterval(Self.expectedCadence + Self.missGracePeriod)
        let anchorAgeSeconds = Int(now.timeIntervalSince(receiptDate))

        let sourceTag = currentSourceTag()

        if rampAt > now {
            scheduleRampTimer(at: rampAt)
            log("haptic_armed", "phase=ramp expected_at=\(Int(rampAt.timeIntervalSince1970)) source=\(sourceTag)")
        } else {
            log("rearm_skipped", "reason=deadline_passed phase=ramp anchor_age_s=\(anchorAgeSeconds) source=\(sourceTag)")
        }

        if missAt > now {
            scheduleMissTimer(at: missAt)
            log("haptic_armed", "phase=miss expected_at=\(Int(missAt.timeIntervalSince1970)) source=\(sourceTag)")
        } else {
            log("rearm_skipped", "reason=deadline_passed phase=miss anchor_age_s=\(anchorAgeSeconds) source=\(sourceTag)")
        }
    }

    private func scheduleRampTimer(at fireDate: Date) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        // `rearm` only calls here when `fireDate > now`; still clamp so the deadline stays non-negative if
        // wall-clock moves between the check and this call (or if this helper gains other callers later).
        let interval = max(0, fireDate.timeIntervalSinceNow)
        timer.schedule(deadline: .now() + interval, leeway: Self.timerLeeway)
        let id = UUID()
        timer.setEventHandler {
            Task { @MainActor in
                HapticBeacon.shared.rampFired(id: id)
            }
        }
        rampTimer = timer
        rampTimerID = id
        timer.resume()
    }

    private func scheduleMissTimer(at fireDate: Date) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let interval = max(0, fireDate.timeIntervalSinceNow)
        timer.schedule(deadline: .now() + interval, leeway: Self.timerLeeway)
        let id = UUID()
        timer.setEventHandler {
            Task { @MainActor in
                HapticBeacon.shared.missFired(id: id)
            }
        }
        missTimer = timer
        missTimerID = id
        timer.resume()
    }

    // MARK: - Internal: fire-handler wrappers (identity-token guard)

    /// Invoked when the ramp one-shot fires. `id` must match `rampTimerID` so a queued handler from an
    /// earlier generation does not run after `cancelAllTimers` + new `scheduleRampTimer` (same slot,
    /// new UUID).
    private func rampFired(id: UUID) {
        guard rampTimerID == id else { return }
        rampTimerID = nil
        rampTimer = nil
        fireRamp()
    }

    private func missFired(id: UUID) {
        guard missTimerID == id else { return }
        missTimerID = nil
        missTimer = nil
        fireMiss()
    }

    /// One success companion-step (`success_2` / `success_3`). The first `.success` is played
    /// synchronously by `fireSuccess()` and never reaches this path.
    private func successSubTimerFired(id: UUID, type: WKHapticType, label: String) {
        guard successSubTimers[id] != nil else { return }
        successSubTimers.removeValue(forKey: id)
        play(type, label: label)
    }

    /// One miss companion-step (`retry_2`). The first `.retry` is played synchronously by
    /// `fireMiss()`.
    private func missSubTimerFired(id: UUID, type: WKHapticType, label: String) {
        guard missSubTimers[id] != nil else { return }
        missSubTimers.removeValue(forKey: id)
        play(type, label: label)
    }

    /// One ramp sub-step. Remove dictionary entry before playing so cancellation only counts pending steps.
    private func rampSubTimerFired(id: UUID, type: WKHapticType, label: String) {
        guard rampSubTimers[id] != nil else { return }
        rampSubTimers.removeValue(forKey: id)
        play(type, label: label)
    }

    // MARK: - Internal: firing

    private func fireRamp() {
        // If `fireRamp` is ever entered with leftover entries (should not happen via `rampFired` alone),
        // clear before rebuilding so sub-timers do not leak across generations.
        rampSubTimers.values.forEach { $0.cancel() }
        rampSubTimers.removeAll()

        let steps: [(TimeInterval, WKHapticType, String)] = [
            (0.0, .click, "ramp_click_1"),
            (0.5, .click, "ramp_click_2"),
            (1.5, .start, "ramp_start_1"),
            (2.0, .start, "ramp_start_2"),
            (3.5, .notification, "ramp_notif_1"),
            (4.0, .notification, "ramp_notif_2"),
            (4.5, .notification, "ramp_notif_3"),
        ]
        var newSubs: [UUID: DispatchSourceTimer] = [:]
        for (delay, type, label) in steps {
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler {
                Task { @MainActor in
                    HapticBeacon.shared.rampSubTimerFired(id: id, type: type, label: label)
                }
            }
            newSubs[id] = timer
            timer.resume()
        }
        rampSubTimers = newSubs
    }

    /// Fires the BLE-only success triple. The first beat plays synchronously so a near-immediate
    /// cancel cannot drop the confirmation. Subsequent beats (`success_2`, `success_3`) are
    /// scheduled as sub-timers and may be cancelled by a competing event — those are companion
    /// beats, not the confirmation itself.
    private func fireSuccess() {
        successSubTimers.values.forEach { $0.cancel() }
        successSubTimers.removeAll()

        // `successBuzzSteps` is a non-empty static constant by construction, so `first` is
        // never nil. The `guard` is kept as a defensive safety net so the synchronous-first /
        // companion-rest pattern is locally obvious — `first` plays now, `dropFirst()` schedules.
        guard let firstStep = Self.successBuzzSteps.first else { return }
        play(firstStep.1, label: firstStep.2)

        var newSubs: [UUID: DispatchSourceTimer] = [:]
        for (delay, type, label) in Self.successBuzzSteps.dropFirst() {
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler {
                Task { @MainActor in
                    HapticBeacon.shared.successSubTimerFired(id: id, type: type, label: label)
                }
            }
            newSubs[id] = timer
            timer.resume()
        }
        successSubTimers = newSubs
    }

    /// Quiet single `.click` for relayed-source arrivals. Distinct from BLE success because relayed
    /// payloads are inherently uncertain (latency, replay, batching). Logged as
    /// `haptic_fired type=relayed_confirm`.
    private func fireRelayedConfirm() {
        play(.click, label: "relayed_confirm")
    }

    private func fireMiss() {
        missSubTimers.values.forEach { $0.cancel() }
        missSubTimers.removeAll()

        // Same defensive-guard rationale as `fireSuccess` — `missRetrySteps` is non-empty by
        // construction; the `guard` makes the sync-first / companion-rest pattern obvious here.
        guard let firstStep = Self.missRetrySteps.first else { return }
        play(firstStep.1, label: firstStep.2)

        var newSubs: [UUID: DispatchSourceTimer] = [:]
        for (delay, type, label) in Self.missRetrySteps.dropFirst() {
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler {
                Task { @MainActor in
                    HapticBeacon.shared.missSubTimerFired(id: id, type: type, label: label)
                }
            }
            newSubs[id] = timer
            timer.resume()
        }
        missSubTimers = newSubs
    }

    /// Single choke point for playing haptics and logging delivery. Prefers
    /// `WKExtendedRuntimeSession.notifyUser(hapticType:)` when `currentExtendedSession` exists and
    /// `state == .running`; otherwise uses `WKInterfaceDevice.current().play(_:)`. Re-queries the
    /// session on every call — never cache it. Keep clinical-scale alerting logic out of here so this
    /// stays a shared dispatcher if another subsystem adds alerts later.
    private func play(_ type: WKHapticType, label: String) {
        guard isEnabled else { return }
        let sourceTag = currentSourceTag()
        guard !isAdapterStopped() else {
            log("haptic_skipped", "reason=adapter_stopped type=\(label) source=\(sourceTag)")
            return
        }
        if let session = G7WatchSensorAdapter.shared.currentExtendedSession,
           session.state == .running {
            // Read the state once and reuse so the log line cannot disagree with the gate (the
            // session could transition between the guard and the log read otherwise).
            let stateAtPlay = session.state.rawValue
            session.notifyUser(hapticType: type)
            log("haptic_fired", "type=\(label) delivered_via=extended_session session_state=\(stateAtPlay) source=\(sourceTag)")
        } else {
            WKInterfaceDevice.current().play(type)
            let stateDesc = G7WatchSensorAdapter.shared.currentExtendedSession.map { "\($0.state.rawValue)" } ?? "nil"
            log("haptic_fired", "type=\(label) delivered_via=device reason_no_session=\(stateDesc) source=\(sourceTag)")
        }
    }

    // MARK: - Internal: housekeeping

    /// Cancels all timers and clears paired generation ids so stale callbacks no-op. Emits
    /// `haptic_cancelled` only for phases that were still scheduled (including `pending_count` for
    /// mid-sequence sub-timers: ramp, success companions, miss companion).
    ///
    /// **Side-effect contract:** This method does *not* clear `lastCycleSource`. Cancellation
    /// telemetry describes the prior cycle (the source still set here); callers that immediately
    /// rearm (`noteEGVReceived`, warm-arm) reassign the source right after. Teardown callers
    /// (`stop`, `setEnabled(false)`, `setSourceFilter` narrowing) call `clearCurrentCycle()`
    /// instead, which adds the `lastCycleSource = nil` step.
    private func cancelAllTimers() {
        let sourceTag = currentSourceTag()
        if rampTimer != nil {
            rampTimer?.cancel()
            rampTimer = nil
            rampTimerID = nil
            log("haptic_cancelled", "phase=ramp source=\(sourceTag)")
        }
        if !rampSubTimers.isEmpty {
            let pendingCount = rampSubTimers.count
            rampSubTimers.values.forEach { $0.cancel() }
            rampSubTimers.removeAll()
            log("haptic_cancelled", "phase=ramp_sub pending_count=\(pendingCount) source=\(sourceTag)")
        }
        if !successSubTimers.isEmpty {
            let pendingCount = successSubTimers.count
            successSubTimers.values.forEach { $0.cancel() }
            successSubTimers.removeAll()
            log("haptic_cancelled", "phase=success_sub pending_count=\(pendingCount) source=\(sourceTag)")
        }
        if missTimer != nil {
            missTimer?.cancel()
            missTimer = nil
            missTimerID = nil
            log("haptic_cancelled", "phase=miss source=\(sourceTag)")
        }
        if !missSubTimers.isEmpty {
            let pendingCount = missSubTimers.count
            missSubTimers.values.forEach { $0.cancel() }
            missSubTimers.removeAll()
            log("haptic_cancelled", "phase=miss_sub pending_count=\(pendingCount) source=\(sourceTag)")
        }
    }

    /// Teardown helper: cancel timers and forget the cycle source. Use from `stop()`,
    /// `setEnabled(false)`, and `setSourceFilter(.ble)` narrowing — anywhere the cycle is being
    /// abandoned rather than rearmed.
    private func clearCurrentCycle() {
        cancelAllTimers()
        lastCycleSource = nil
    }

    /// Uses the adapter's intentional stop flag; avoids the BLE status mirror defaulting to `.off` at launch.
    private func isAdapterStopped() -> Bool {
        G7WatchSensorAdapter.shared.isIntentionallyStopped
    }

    // MARK: - Telemetry

    private func log(_ event: String, _ fields: String = "") {
        let suffix = fields.isEmpty ? "" : " \(fields)"
        Task {
            await WatchLogger.shared.log("module=haptic_beacon event=\(event)\(suffix)")
        }
    }
}
