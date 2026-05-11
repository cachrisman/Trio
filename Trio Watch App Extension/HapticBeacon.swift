import Foundation
import WatchKit

/// Cadence-aware haptic beacon for the watch app. Predicts when the next G7 EGV will arrive
/// (5-min cadence anchored on receipt time) and signals the user via haptics:
///
/// - **Pre-EGV ramp** (T-3s, T-2s, T-1s): `.click` → `.start` → `.notification` (increasing intensity).
/// - **Success** (on EGV reception): `.success` × 2, ~150 ms apart.
/// - **Miss** (T+20s past expected with no EGV): `.retry` once.
///
/// Foreground delivery uses `WKInterfaceDevice.current().play(_:)` only. A later revision may
/// prefer `WKExtendedRuntimeSession.notifyUser(haptic:)` when an extended session is active,
/// falling back to the device.
///
/// **Adapter stopped:** When `G7WatchSensorAdapter.shared.isIntentionallyStopped` is true, the
/// beacon stays silent — pending timers are cancelled and any incoming `play(_:)` is suppressed
/// with a `haptic_skipped` log line. This avoids false-positive miss buzzes after extended-session
/// invalidation or manual stop. The adapter’s `isStopped` flag is authoritative; the published
/// `g7DirectBleStatus` mirror defaults to `.off` at cold start and would incorrectly suppress the
/// first EGV after launch if used for this check.
///
/// **Extended session:** The beacon does not cache `WKExtendedRuntimeSession`. The adapter may
/// replace the session from `stop()`, `renewSessionIfNeeded()`, or
/// `extendedRuntimeSessionWillExpire`; future background haptics should re-query
/// `currentExtendedSession` at delivery time rather than holding a reference.
///
/// **Reserved haptic types:** `.failure`, `.directionUp`, `.directionDown`, and `.stop` are left
/// for a possible future clinical alerter and are not used in this beacon’s palette.
@MainActor
final class HapticBeacon {
    static let shared = HapticBeacon()

    // MARK: - Tuning constants

    /// G7 nominal cadence (5 min). Mirrors `ComplicationDebugView.expectedReadingCadence`.
    private static let expectedCadence: TimeInterval = 300
    /// Ramp begins this far before expected EGV.
    private static let rampLeadTime: TimeInterval = 3
    /// Time after expected EGV before declaring a miss.
    private static let missGracePeriod: TimeInterval = 20
    /// Do not rearm if last receipt was older than this — system is likely down or stale.
    private static let staleThreshold: TimeInterval = 600
    /// Inter-buzz spacing for the success pair.
    private static let successInterBuzzInterval: TimeInterval = 0.150
    /// Leeway for `DispatchSourceTimer` schedules. 500 ms is forgiving on Apple Watch SE and older
    /// hardware; tighten if observed fire jitter exceeds expectations.
    private static let timerLeeway: DispatchTimeInterval = .milliseconds(500)

    // MARK: - Persistence

    private enum Keys {
        static let isEnabled = "HapticBeacon.isEnabled"
    }

    /// Opt-in toggle backed by `UserDefaults.standard`; default off when the key is absent.
    /// Stored in the watch extension only (not App Group). Read on each access; `setEnabled(_:)`
    /// is the sole writer so toggles stay coherent with persisted state.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    // MARK: - Timer state (touched only on `@MainActor`)

    /// Serial queue for `DispatchSourceTimer` scheduling. Matches the adapter’s timer-queue pattern.
    /// Handlers hop back to `@MainActor` via `Task { @MainActor in … }` before touching beacon state
    /// or playing haptics.
    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.haptic.timers", qos: .utility)

    private var rampTimer: DispatchSourceTimer?
    /// Generation id paired with `rampTimer`. Timer callbacks capture this UUID; the handler runs only
    /// if `rampTimerID` still matches — so a stale callback cannot clear or replace a *new* timer after
    /// cancel-and-reschedule (e.g. fresh EGV arriving just after the ramp deadline fired). Same idea as
    /// UUID keys on `rampSubTimers`.
    private var rampTimerID: UUID?
    /// Three ramp sub-timers at +0s/+1s/+2s from ramp trigger. Dictionary keyed by UUID so each firing
    /// removes its entry; after all three fire the map is empty and cancellation telemetry reflects only
    /// genuinely pending sub-haptics. Count at cancel time feeds `pending_count` for logs.
    private var rampSubTimers: [UUID: DispatchSourceTimer] = [:]
    private var missTimer: DispatchSourceTimer?
    /// Generation id paired with `missTimer`; same stale-handler semantics as `rampTimerID`.
    private var missTimerID: UUID?
    /// Second `.success` buzz after `successInterBuzzInterval`. Tracked so `cancelAllTimers()` can drop
    /// it within the 150 ms window and so a new EGV in that window does not stack an orphaned second buzz.
    private var successTimer: DispatchSourceTimer?
    /// Generation id paired with `successTimer`; same stale-handler semantics as `rampTimerID`.
    private var successTimerID: UUID?

    /// Receipt time of the last `noteEGVReceived` call. Cadence anchor.
    private var lastReceiptAt: Date?

    private init() {}

    // MARK: - Public API

    /// Idempotent hook for foreground entry; arms only via `noteEGVReceived` from the adapter today.
    func start() {
        log("start", "is_enabled=\(isEnabled)")
    }

    /// Idempotent. Cancels timers and clears `lastReceiptAt`. Not used on background transition today
    /// (BLE keeps running); kept for symmetry and future lifecycle policy.
    func stop() {
        cancelAllTimers()
        lastReceiptAt = nil
        log("stop")
    }

    /// Persisted toggle. Disabling cancels in-flight timers so a mid-ramp toggle does not keep buzzing.
    ///
    /// Enabling may **warm-arm**: if `WatchState.shared.bleLastEGVDate` is recent, use it as a synthetic
    /// anchor and schedule ramp/miss without waiting for the next live EGV. No success haptics on warm-arm
    /// — no reading is arriving at toggle time.
    ///
    /// **Anchor vs receipt time:** `bleLastEGVDate` is the sensor `readingDate`, not watch receipt time.
    /// Typical drift is a few seconds; warm-arm is approximate. A precise anchor would need receipt time
    /// plumbed through state or persisting `lastReceiptAt`.
    ///
    /// **Gate:** Warm-arm runs only when anchor age is below `expectedCadence + missGracePeriod` (320 s).
    /// Older anchors skip with `warm_arm_skipped reason=cycle_already_expired`. Between ~297 s and ~319 s,
    /// the ramp deadline may already be past while the miss deadline is still ahead; `rearm(after:)` skips
    /// only the overdue phase (logs `rearm_skipped reason=deadline_passed phase=ramp`) and still arms miss
    /// — partial warm-arm for “EGV overdue” without an immediate stale ramp burst.
    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        guard enabled != wasEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: Keys.isEnabled)
        if !enabled {
            cancelAllTimers()
            // Clear the anchor so a later re-enable starts from the first-EGV-after-launch path
            // instead of comparing the next live EGV to a hours-old or days-old prior receipt
            // (which would correctly but confusingly emit `rearm_skipped reason=stale_gap`).
            lastReceiptAt = nil
            log("setEnabled", "enabled=false action=cancelled_pending_timers")
            return
        }

        log("setEnabled", "enabled=true")

        // Each early return below logs `warm_arm_skipped` with a distinct `reason` so analysts
        // can tell "no warm-arm because of X" apart from "warm-arm logic never ran" when reading
        // the trail after `setEnabled enabled=true`.
        guard !isAdapterStopped() else {
            log("warm_arm_skipped", "reason=adapter_stopped")
            return
        }
        guard let bleLastEGV = WatchState.shared.bleLastEGVDate,
              bleLastEGV != .distantPast
        else {
            log("warm_arm_skipped", "reason=no_anchor")
            return
        }
        let age = Date().timeIntervalSince(bleLastEGV)
        guard age >= 0 else {
            log("warm_arm_skipped", "reason=anchor_in_future anchor_age_s=\(Int(age))")
            return
        }
        guard age < Self.expectedCadence + Self.missGracePeriod else {
            log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))")
            return
        }

        cancelAllTimers()
        lastReceiptAt = bleLastEGV
        rearm(after: bleLastEGV)
        log("warm_armed", "anchor_age_s=\(Int(age))")
    }

    /// Single hook when an EGV is received. Non-BLE sources are ignored until wired separately.
    func noteEGVReceived(at receiptDate: Date, source: TrioComplicationDataSource) {
        guard isEnabled else { return }
        guard source == .g7DirectBLE else {
            return
        }
        guard !isAdapterStopped() else {
            // Unlikely while stopped; drop quietly if a delegate races teardown.
            cancelAllTimers()
            log("haptic_skipped", "reason=adapter_stopped phase=success source=\(source.rawValue)")
            return
        }

        // Compare gap between consecutive receipts for stale-gap logic — not freshness of this receipt alone.
        let priorReceiptAt = lastReceiptAt

        cancelAllTimers()
        lastReceiptAt = receiptDate
        fireSuccess()

        if let prior = priorReceiptAt {
            let gap = receiptDate.timeIntervalSince(prior)
            if gap > Self.staleThreshold {
                // Recovery after long outage: success already fired; skip prediction until cadence restabilizes.
                log("rearm_skipped", "reason=stale_gap gap_s=\(Int(gap))")
                return
            }
        }

        rearm(after: receiptDate)
    }

    // MARK: - Internal: scheduling

    /// Schedules ramp and miss one-shots from `receiptDate`. Stale-gap skipping lives in `noteEGVReceived`.
    ///
    /// Each deadline is evaluated against `now` before scheduling. Live EGVs use `receiptDate == now`, so
    /// both deadlines are ~297–320 s ahead. Warm-arm with an older synthetic anchor may skip only ramp or
    /// only miss when that deadline is already past — avoids `scheduleRampTimer` firing immediately on a
    /// stale ramp instant. Skips log `rearm_skipped reason=deadline_passed` with phase and anchor age;
    /// analysts should treat that as expected partial warm-arm, not necessarily a failure.
    private func rearm(after receiptDate: Date) {
        let now = Date()
        let rampAt = receiptDate.addingTimeInterval(Self.expectedCadence - Self.rampLeadTime)
        let missAt = receiptDate.addingTimeInterval(Self.expectedCadence + Self.missGracePeriod)
        let anchorAgeSeconds = Int(now.timeIntervalSince(receiptDate))

        if rampAt > now {
            scheduleRampTimer(at: rampAt)
            log("haptic_armed", "phase=ramp expected_at=\(Int(rampAt.timeIntervalSince1970)) source=ble")
        } else {
            log("rearm_skipped", "reason=deadline_passed phase=ramp anchor_age_s=\(anchorAgeSeconds)")
        }

        if missAt > now {
            scheduleMissTimer(at: missAt)
            log("haptic_armed", "phase=miss expected_at=\(Int(missAt.timeIntervalSince1970)) source=ble")
        } else {
            log("rearm_skipped", "reason=deadline_passed phase=miss anchor_age_s=\(anchorAgeSeconds)")
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

    /// Second half of the success pair; `id` must match `successTimerID` for the same generation rule.
    private func playSecondSuccessBuzz(id: UUID) {
        guard successTimerID == id else { return }
        successTimerID = nil
        successTimer = nil
        play(.success, label: "success")
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
            (0.0, .click, "ramp_click"),
            (1.0, .start, "ramp_start"),
            (2.0, .notification, "ramp_notif"),
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

    private func fireSuccess() {
        play(.success, label: "success")
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.successInterBuzzInterval)
        let id = UUID()
        timer.setEventHandler {
            Task { @MainActor in
                HapticBeacon.shared.playSecondSuccessBuzz(id: id)
            }
        }
        successTimer = timer
        successTimerID = id
        timer.resume()
    }

    private func fireMiss() {
        play(.retry, label: "retry")
    }

    /// Single choke point for playing haptics and logging delivery. Uses `WKInterfaceDevice` only for
    /// now; a future path can prefer `WKExtendedRuntimeSession.notifyUser(haptic:)` when
    /// `G7WatchSensorAdapter.shared.currentExtendedSession` is non-nil, with device fallback. Keep
    /// clinical-scale alerting logic out of here so this stays a shared dispatcher if another subsystem
    /// adds alerts later.
    private func play(_ type: WKHapticType, label: String) {
        guard isEnabled else { return }
        guard !isAdapterStopped() else {
            log("haptic_skipped", "reason=adapter_stopped type=\(label)")
            return
        }
        WKInterfaceDevice.current().play(type)
        log("haptic_fired", "type=\(label) delivered_via=device")
    }

    // MARK: - Internal: housekeeping

    /// Cancels all timers and clears paired generation ids so stale callbacks no-op. Emits
    /// `haptic_cancelled` only for phases that were still scheduled (including `pending_count` for
    /// mid-ramp sub-timers). Suppresses the second success buzz without a cancel line — it is a companion
    /// to the first, not a separately “armed” prediction.
    private func cancelAllTimers() {
        if rampTimer != nil {
            rampTimer?.cancel()
            rampTimer = nil
            rampTimerID = nil
            log("haptic_cancelled", "phase=ramp source=ble")
        }
        if !rampSubTimers.isEmpty {
            let pendingCount = rampSubTimers.count
            rampSubTimers.values.forEach { $0.cancel() }
            rampSubTimers.removeAll()
            log("haptic_cancelled", "phase=ramp_sub pending_count=\(pendingCount) source=ble")
        }
        if missTimer != nil {
            missTimer?.cancel()
            missTimer = nil
            missTimerID = nil
            log("haptic_cancelled", "phase=miss source=ble")
        }
        if successTimer != nil {
            successTimer?.cancel()
            successTimer = nil
            successTimerID = nil
        }
    }

    /// Uses the adapter’s intentional stop flag; avoids the BLE status mirror defaulting to `.off` at launch.
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
