import Foundation
import G7SensorKit
import WatchKit

/// Thin watch-specific wrapper around `G7Sensor` (build 195). Replaces `G7DirectBLEObserver` BLE stack;
/// sensor identity and daily counters remain compatible with existing App Group / WatchState keys.
///
/// **Peripheral match / `suffix(2)`:** There is no `attachIntent` symbol in G7SensorKit. Dexcom advertising names are
/// accepted in `G7Sensor.bluetoothManager(_:shouldConnectPeripheral:)` (`G7SensorKit/.../G7Sensor.swift`): when
/// `sensorID` is set, connection uses `name.suffix(2) == sensorName.suffix(2)`; when nil, `.connect` for DXCM/DX02.
/// Watch adapter mirrors the phone (`G7CGMManager`): one `G7Sensor` per process; identity changes go through
/// `sensor.scanForNewSensor()` and `didDiscoverNewSensor` (name-gated) instead of reconstructing the sensor.
///
/// **Discovery:** `didDiscoverNewSensor` returns `true` only when the discovered peripheral's name suffix matches
/// `expectedSensorName` (phone-pushed via WC). With no expected name, all discoveries are rejected.
@MainActor
final class G7WatchSensorAdapter: NSObject {
    static let shared = G7WatchSensorAdapter()

    /// One `G7Sensor` instance per process. Mirrors `G7CGMManager` on the phone: identity changes
    /// happen via `sensor.scanForNewSensor()` (clears the sensor's internal `sensorID` and starts a
    /// new scan), not by reconstructing this reference. Reconstructing leaked CBCentralManager state.
    private let sensor: G7Sensor

    /// Name of the peripheral the live `G7Sensor` is currently bound to. Tracks the sensor's
    /// internal `sensorID` (which is `private` on `G7Sensor`) by being set in `sensorDidConnect`
    /// and cleared whenever we call `sensor.scanForNewSensor()`. Exposed for debug UI.
    private(set) var boundSensorName: String?

    /// Transient flag set by `performScanForNewSensor()`; cleared either by the next
    /// `handleSensorDisconnected` (when the rescan triggers a downstream disconnect) or by a
    /// 2s auto-clear (when no downstream disconnect comes — e.g., we weren't connected). The
    /// disconnect handler reads this to skip the pre-EGV counter increment for self-inflicted
    /// disconnects (sensor swap, EOS teardown, stale-binding rebind).
    private var isScanningForNewSensor = false

    private var extendedSession: WKExtendedRuntimeSession?
    /// Session for which `start()` was called but `extendedRuntimeSessionDidStart` has not yet run.
    /// `extendedSession` is assigned **only** in `extendedRuntimeSessionDidStart` so it always refers to a started session.
    private var sessionPendingDidStart: WKExtendedRuntimeSession?
    /// D8: timestamp of the last foreground session-start request, used to debounce repeat requests
    /// (rapid `.start()` churn invites watchOS throttling).
    private var lastStartRequestAt: Date?
    /// C-212-5 (BUG-E): wall-clock the current extended session started. Drives the near-expiry
    /// re-anchor: a foreground-active open while the running session is older than `sessionReanchorAge`
    /// invalidates it and starts a fresh ~1h session, so coverage re-anchors from the open instead of
    /// lapsing minutes later (often in the background, where it cannot restart). Set on didStart / adopt;
    /// cleared whenever the session reference is cleared.
    private var sessionStartedAt: Date?
    /// Wall-clock of the most recent non-intentional session invalidation. Drives the heartbeat's
    /// session_dead_since_s. Set in didInvalidateWith (real-death path) and the reanchor-failure
    /// paths; cleared on every session-start path.
    private var sessionInvalidatedAt: Date?
    /// One-shot guard so ext_session_nearing_expiry fires at most once per session across the
    /// 5-min heartbeat ticks in the 55–60 min window. Reset on every session-start path.
    private var sessionNearExpiryLogged = false
    /// C-212-5: only re-anchor a running session at least this old (a fresh one already covers ~1h).
    /// Build 215: lowered 45→40 min — widens the reanchor window to 20 min vs 15 min. Coverage is
    /// app-open-gated, so this only adds reanchor opportunities; the replacement starts a fresh ~1h clock.
    private static let sessionReanchorAge: TimeInterval = 40 * 60
    /// C-212-5 v2: compile-time flag for the inline re-anchor experiment (default on for soak; flip + rebuild to disable).
    private static let reanchorEnabled = true
    /// C-212-5 v2: the replacement session started INLINE by the re-anchor. Object-identity attribution
    /// in the delegate callbacks (`WKExtendedRuntimeSession` has no userTag; subclassing it is unstable).
    private var pendingReanchorSession: WKExtendedRuntimeSession?
    /// C-212-5 v2: true while a swap is between invalidate() and the replacement resolving — blocks re-entry.
    private var reanchorSwapInFlight = false
    /// C-212-5 v2: per-attempt context for the in-flight swap (logged + drives the single 200ms retry).
    private var reanchorSid: String?
    private var reanchorArmDelayMs: Int = 0
    private var reanchorDidRetry = false
    /// C-212-5 v2: consecutive arm-A (0ms) TRUE failures (first attempt AND retry both failed); 5 → disable A.
    private var armAConsecFailures = 0
    private var armADisabled = false
    /// C-212-5 v2 UserDefaults keys: A/B/C round-robin counter + persisted true session-start epoch (§8.7).
    private static let reanchorCounterKey = "C212.reanchorAttemptCounter"
    private static let sessionStartEpochKey = "C212.sessionStartEpoch"

    /// Identities of `WKExtendedRuntimeSession`s that the adapter intentionally invalidated and
    /// whose `didInvalidateWith` callback has not yet been delivered. The delegate consults this
    /// set at the top of `extendedRuntimeSession(_:didInvalidateWith:)` and short-circuits with an
    /// `ext_session_intentional_invalidation` log if the incoming `session` matches.
    ///
    /// Insertion sites — every place that calls `invalidate()` on a session we owned must add the
    /// session's `ObjectIdentifier` here first. C-212-5 (BUG-E) is the current inserter: the
    /// near-expiry re-anchor in `renewSessionIfNeeded()`. The set classifies the resulting callback
    /// as intentional (clean-up + restart) instead of falling through to the error/teardown branch.
    ///
    /// Removal sites: the early-return in `extendedRuntimeSession(_:didInvalidateWith:)`
    /// (consumes the entry) and a defensive `remove` in `extendedRuntimeSessionDidStart`
    /// (keeps the set bounded if a session somehow started despite being marked for invalidation).
    private var invalidatingSessionIDs = Set<ObjectIdentifier>()

    /// Read-only accessor for the currently started extended runtime session.
    ///
    /// The adapter may replace this reference from several paths (`renewSessionIfNeeded()`'s
    /// `didStart`, the invalidation handler), so callers
    /// must re-query on every use — never cache the returned reference.
    var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }

    // MARK: - Debug-UI accessors

    /// Current pre-EGV disconnect streak count (for `WatchDiagnosticsView`).
    var consecutivePreEGVDisconnectsCount: Int { consecutivePreEGVDisconnects }

    /// C-216 (Task D): user-initiated recovery marker, logged when the debug-screen button is
    /// tapped after the user manually restarts the app/watch to fix a stalled signal. Telemetry-only
    /// — correlates a self-reported "I restarted to fix it" moment against the surrounding BLE state.
    func logManualRecoveryMarker() {
        log("manual_recovery_marker", "source=debug_button")
    }

    /// Human-readable description of `extendedSession.state`
    /// (`notStarted`/`scheduled`/`running`/`invalid`) or "nil" when no session is held. Use alongside
    /// `extSessionLastKnownActive` for diagnosis.
    var extSessionState: String {
        if let s = extendedSession {
            return describeState(s.state)
        }
        return "nil"
    }

    /// Whether the adapter last observed an active extended runtime session. Fallback signal for
    /// debug UI when `extendedSession.state` is not informative (e.g. session reference cleared
    /// during teardown).
    var extSessionLastKnownActive: Bool { lastKnownExtSessionActive }

    /// C-217-D4: seconds since the current extended runtime session started, via `trueSessionAge()`
    /// (persisted-epoch first, in-memory fallback — survives adoption/resurrection, §8.7). `nil`
    /// when no session-start stamp is known.
    var extSessionAgeSeconds: Int? { trueSessionAge().map(Int.init) }

    /// C-217-D4: true when the C-212-5 near-expiry re-anchor in `renewSessionIfNeeded()` would
    /// consider the live session eligible right now — `.running` and at least `sessionReanchorAge`
    /// old. Debug-only mirror of that branch's own guards; reading it never triggers a re-anchor.
    var isReanchorEligibleNow: Bool {
        guard extendedSession?.state == .running else { return false }
        return (trueSessionAge() ?? 0) >= Self.sessionReanchorAge
    }

    /// C-217-D1: read-only mirror of `consecutiveConnectingTicks` (C-216 W-7a/Task B) for the
    /// debug "BLE link" row's `ticks:<n>` suffix.
    var connectingTicksCount: Int { consecutiveConnectingTicks }

    /// C-217-D1/D2: BLE diagnostics snapshot for the debug screen. `sensor.diagnosticsSnapshot()`
    /// is a BLOCKING `managerQueue.sync` hop — the debug UI must poll this at <= 0.2 Hz (the
    /// existing 5s tick), never at the 1 Hz tick used for `now`/countdown re-rendering.
    func bleDiagnostics() -> G7BLEDiagnosticsSnapshot { sensor.diagnosticsSnapshot() }

    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.g7WatchAdapter.timers", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var expectedWindowTimer: DispatchSourceTimer?
    private var expectedWindowNextEpoch: Int?

    /// `start()` re-entry gate. Set true on entry to `start()`; never cleared. Build 208 removed
    /// `stop()` (its only caller was the session-invalidation teardown), so `start()` is one-shot
    /// per process and foreground re-entries no-op. Replaces the previous `sensor.isConnected`
    /// check (which crossed `bluetoothManager.managerQueue.sync`).
    private var isStarted = false
    private var bleConnectsToday: Int = 0
    private var bleEGVsToday: Int = 0
    // C-209-1 (B1): the "possible chances" denominator is computed ANALYTICALLY at display time
    // (elapsed 5-min slots since midnight − ineligible − gated; see `dailySlotStats`). The old
    // timer-accumulated `expectedSlotsToday` froze during background suspension — exactly the
    // outage the ratio exists to expose. The only tracked quantity is ineligible wall-clock
    // time, and its one trigger is `expectedSensorName` nil/non-nil (every terminal sensor path
    // funnels through `performEndOfSessionTeardown`, and the adapter has no stop() since
    // C-208-1). Edge-event-driven — no timer to suspend. DRIFT: warmup counts as eligible
    // (identity present, readings arriving but unreliable) — bounded ~25 min per sensor cycle.
    private var gatedSlotsToday: Int = 0 // mirror of gatedSlotEpochsToday.count for display
    private var gatedSlotEpochsToday: Set<Int> = []
    private var ineligibleSecondsToday: Double = 0
    private var ineligibleSince: Date? // open ineligible interval start (nil while eligible)

    // C1 runtime gate: scans are allowed only when the scene is active OR a runtime session is
    // confirmed `.running`; otherwise the scan is deferred (kind preserved) and the slot recorded as
    // gated. `.newSensor` takes precedence over `.resume` across a deferral.
    private enum ScanKind { case resume, newSensor }
    private var deferredScanKind: ScanKind?
    private var isRuntimeEligible: Bool {
        lastKnownScenePhase == "active" || extendedSession?.state == .running
    }

    // C2: in-memory quarantine of the identity torn down at EOS, so a phone re-push of the same
    // (name, epoch) doesn't revive the dead sensor. Cleared on app restart (the intended escape hatch).
    private var quarantine: SensorIdentity?
    /// Set by the C2 accept-swap path so `applyNewSensorName` tears down the (definitively dead) binding
    /// immediately rather than deferring the clear to `performScanForNewSensor` (the C1 routine-rebind rule).
    private var pendingSensorSwap = false
    /// Bound sensor activation epoch (Int64 seconds), persisted. nil = legacy name-only (pre-epoch).
    private var storedActivationEpochSeconds: Int64? {
        get { (UserDefaults.standard.object(forKey: Keys.activationEpochSeconds) as? NSNumber)?.int64Value }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Keys.activationEpochSeconds) }
            else { UserDefaults.standard.removeObject(forKey: Keys.activationEpochSeconds) }
        }
    }
    private var sessionConnectAt: Date?
    /// C-210-5: true once we've notified for the current direct-BLE stall episode (reset on recovery).
    private var stallNotifiedThisEpisode = false
    private var centralReinitThisEpisode = false
    /// C-217 D-7: last computed C-210-8 stall fault ("dexcom_side"/"trio_side") for the diagnostics
    /// Stall row. Set when a stall is detected; nil when the direct path is fresh or ineligible.
    private(set) var lastDirectBleStallFault: String?
    /// C-216 (W-7a/Task B): consecutive heartbeat ticks observing `activePeripheralStateRaw == 1`
    /// (CBPeripheralState.connecting). Sizes the duration of the unwatched-wedge fingerprint
    /// (`active_peripheral_state=1` + `connect_pending_age_s=-1`, 06-30 deep-gap class).
    private var consecutiveConnectingTicks = 0

    /// Set on `sensorDidConnect`, cleared on `sensorDisconnected`; read from telemetry / ExtensionDelegate.
    var adapterSessionID: String?

    /// UserDefaults is thread-safe; exposed for debug UI without `nonisolated(unsafe)`.
    var telemetrySensorName: String {
        UserDefaults.standard.string(forKey: Keys.sensorName) ?? "nil"
    }

    private var sessionPhase: AdapterSessionPhase = .preEGV
    private var consecutivePreEGVDisconnects = 0
    private var hadEGVThisSession = false
    private var loggedTimeToFirstEGVForSession = false

    private var lastKnownScenePhase: String = "unknown" { didSet { syncTelemetryRingContext() } }

    private var lastKnownExtSessionActive = false { didSet { syncTelemetryRingContext() } }

    private var lastReadingSequence: UInt16?
    private var lastSavedGlucoseValue: Int?
    private var sessionActivationDate: Date?

    private enum Keys {
        // W13: unified under the G7WatchAdapter.* convention. `sensorName` migrates from the legacy
        // key (below); the daily-counter keys self-heal (a one-time reset of today's counts on upgrade).
        static let sensorName = "G7WatchAdapter.sensorName"
        static let lastEGVEpoch = "G7WatchAdapter.lastEGVEpoch"
        static let calendarDay = "G7WatchAdapter.bleCountersCalendarDay"
        static let connects = "G7WatchAdapter.bleConnectsToday"
        static let egvs = "G7WatchAdapter.bleEGVsToday"
        // W7 slot accounting (C-209-1: analytical denominator — only gated slots + ineligible time persist).
        static let gatedSlotEpochs = "G7WatchAdapter.gatedSlotEpochsToday" // persisted as [Int]
        static let ineligibleSeconds = "G7WatchAdapter.ineligibleSecondsToday"
        static let ineligibleSinceEpoch = "G7WatchAdapter.ineligibleSinceEpoch" // Double epoch; 0 = none
        // C2: bound sensor activation epoch (Int64 seconds), persisted so a post-restart swap is detectable.
        static let activationEpochSeconds = "G7WatchAdapter.activationEpochSeconds"
        // Legacy key for the one-time W13 sensorName migration only.
        static let legacySensorName = "G7DirectBLEObserver.sensorName"
        // C-217 D-7: watch-local kill-switch persistence. The fork's G7BackgroundHints escalation
        // flags default ON in-memory every process, so a persisted OFF must be re-applied at launch.
        // The diagnostics view's @AppStorage toggles use these exact key strings.
        static let killSwitchWedgeEscalation = "G7WatchAdapter.killSwitch.connectWedgeEscalation"
        static let killSwitchCentralReinit = "G7WatchAdapter.killSwitch.centralReinit"
    }

    /// C2 sensor identity = name + activation epoch (Int64 seconds; nil = legacy name-only).
    struct SensorIdentity: Equatable {
        let name: String
        let activationEpochSeconds: Int64?
    }

    private enum AdapterSessionPhase: String {
        case preEGV = "pre_egv"
        case postEGV = "post_egv"
    }

    /// Phone-pushed sensor identity used to gate `didDiscoverNewSensor`. `nil` means idle (no
    /// expected sensor) or post-EOS (we deliberately reject all discoveries until the phone
    /// pushes a new name). UserDefaults-backed so it persists across launches and so the
    /// `nonisolated` discovery callback can read it synchronously from G7Sensor's `delegateQueue`.
    nonisolated var expectedSensorName: String? {
        get { UserDefaults.standard.string(forKey: Keys.sensorName) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sensorName) }
    }

    /// W13 one-time migration: carry the bound sensor name forward from the legacy
    /// `G7DirectBLEObserver.sensorName` key so the upgrade doesn't lose the binding and force a fresh
    /// scan. UserDefaults-only (no `self`) so it is legal before `super.init()`.
    private static func migrateLegacySensorNameKeyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.sensorName)?.isEmpty ?? true,
              let legacy = defaults.string(forKey: Keys.legacySensorName), !legacy.isEmpty
        else { return }
        defaults.set(legacy, forKey: Keys.sensorName)
        defaults.removeObject(forKey: Keys.legacySensorName)
    }

    private override init() {
        Self.migrateLegacySensorNameKeyIfNeeded()
        // Seed the persisted sensor identity (mirrors the iPhone app's `G7Sensor(sensorID:
        // state.sensorID)`) so a known sensor reconnects directly instead of forcing a fresh
        // scan-and-discover cycle. Read UserDefaults directly rather than via
        // `expectedSensorName`, whose getter touches `self` and is illegal before `super.init`.
        // The value is nil on first launch / post-EOS, in which case this is identical to
        // constructing in scan mode.
        // BLE scanning is started by `start()` only, never from `init()` — kicking off scans
        // before any WKExtendedRuntimeSession is established starves the session and lets the
        // system reclaim BLE while the watch is in the background.
        sensor = G7Sensor(sensorID: UserDefaults.standard.string(forKey: Keys.sensorName))
        super.init()
        sensor.delegate = self
        loadDailyCounters()
        syncTelemetryRingContext() // C-208-9: seed emit-time context before any BLE callback
    }

    /// Begin (or no-op resume) the G7 BLE pipeline.
    ///
    /// **Re-entry invariant:** `isStarted` guards the body so multiple foreground re-entries
    /// (scene-phase flicker, redundant `applyForegroundActiveEntry` calls) collapse into a single
    /// setup pass per process. (C-209-1: the old retroactive `expected_window` replay and its
    /// `hasAnchored` gate are gone — the tick is pure telemetry, wall-aligned.)
    func start() {
        guard !isStarted else { return }
        isStarted = true
        // C-216 (Task D): one-shot per process — a recovery marker distinguishing a genuine cold
        // launch from other events in the telemetry stream.
        log("cold_launch", "reason=process_start")
        applyKillSwitchesFromDefaults() // C-217 D-7: re-apply persisted kill-switch choices
        stopTimers() // defensive only — start() is one-shot per process as of build 208
        loadDailyCountersIfNewCalendarDay()
        startHeartbeatTimer()
        refreshIneligibilityClock() // C-209-1: seed the clock (covers launching with no identity)
        guard let name = expectedSensorName else {
            log("start_skipped_no_sensor")
            return
        }
        // If the live sensor isn't bound to our expected name (cold start, post-EOS, or sensor
        // swap), forget any cached peripheral and start a fresh scan. `didDiscoverNewSensor`
        // gates the rebind by `expectedSensorName` suffix.
        // C1: route scan entries through the runtime gate. Don't clear boundSensorName here —
        // performScanForNewSensor clears it only when the scan actually proceeds, so a still-valid
        // binding isn't stranded for a scan that gets gated in the background.
        if boundSensorName != name {
            beginScanIfEligible(.newSensor)
        }
        // C-209-1: the expected-window tick is pure telemetry now (no slot counting, no
        // retroactive replay) — align to the next wall-clock 5-min boundary and free-run.
        scheduleNextExpectedWindowTick()
        beginScanIfEligible(.resume)
        drainPendingEGVTailIfAny() // C-208-10: launch replay (process died mid-tail)
        // Status publish AFTER the replay (verification finding): the replayed snapshot sets
        // `.active` inside applyG7DirectBleSnapshot; publishing the real fork state afterwards
        // corrects a stale-replay `.active` immediately instead of letting it stand.
        publishConnectionStatus()
    }

    /// C-217 D-7: restore the watch-local kill-switch choices into the fork's in-memory
    /// G7BackgroundHints flags (which default ON every process). Registers ON as the default so an
    /// untoggled install matches the fork default. Called once per process from `start()`.
    private func applyKillSwitchesFromDefaults() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Keys.killSwitchWedgeEscalation: true,
            Keys.killSwitchCentralReinit: true,
        ])
        G7BackgroundHints.isConnectWedgeEscalationEnabled = d.bool(forKey: Keys.killSwitchWedgeEscalation)
        G7BackgroundHints.isCentralReinitEnabled = d.bool(forKey: Keys.killSwitchCentralReinit)
    }

    /// C-217 D-7: emit a marker when the user flips a kill-switch in the diagnostics view so soak
    /// analysis can see exactly when Task-2/Task-4 behavior changed. The view's @AppStorage onChange
    /// also pushes the value into the fork's G7BackgroundHints flag live (next-cycle effect).
    func logKillSwitchToggled(_ name: String, enabled: Bool) {
        log("kill_switch_toggled", "switch=\(name) enabled=\(enabled)")
    }

    // Build 208: `stop()` removed. Its only caller was the session-invalidation error branch
    // (see `extendedRuntimeSession(_:didInvalidateWith:)`), there is no user-facing BLE-off
    // feature on the watch, and the teardown was half-effective anyway — the fork's
    // `scanAfterDelay()` auto-rescan resurrected scanning while the adapter's timers/status
    // stayed dead. The watch now mirrors the iPhone model: the BLE pipeline, once started,
    // runs for the life of the process.

    func applyForegroundActiveEntry() {
        lastKnownScenePhase = "active"
        G7BackgroundHints.isHostBackgrounded = false // C-209-11: resume full GATT config in foreground
        start()
        renewSessionIfNeeded()
        consumeDeferredScanIfNeeded() // C1: scene-active is a runtime-eligible transition
        drainPendingEGVTailIfAny() // C-208-10: foreground replay (suspension hit mid-tail)
    }

    func noteForegroundInactiveOrBackground(_ phase: String) {
        lastKnownScenePhase = phase
        // C-209-11: tell the fork to skip non-essential GATT round-trips (backfill subscribe,
        // extended-version request) while not frontmost — scene phase isn't visible to the fork.
        G7BackgroundHints.isHostBackgrounded = true
    }

    /// D8: a `WKExtendedRuntimeSession` is only granted while the app is frontmost. This previously
    /// fired on every BLE reconnect (`recordSessionConnect`), so ~95% of requests were made in the
    /// background and denied before `didStart` — and the churn invited system throttling. Gate
    /// strictly on the active scene phase, skip if one is already running/pending, and debounce.
    private func renewSessionIfNeeded() {
        guard lastKnownScenePhase == "active" else {
            log("ext_session_renew_skipped", "reason=not_active scene=\(lastKnownScenePhase)")
            return
        }
        // C-212-5 v2: a swap is in flight (between invalidate() and the replacement resolving) — block
        // re-entry so a delayed (B/C) start or the 200ms retry can't collide with a fresh normal start.
        guard !reanchorSwapInFlight else {
            log("ext_session_renew_skipped", "reason=reanchor_swap_in_flight scene=\(lastKnownScenePhase)")
            return
        }
        // C-212-5 v2 (BUG-E): re-anchor a near-expiry running session with an INLINE swap — invalidate the
        // old session and start the replacement immediately (arm A) or after a small A/B/C delay (B/C),
        // WITHOUT waiting on the slow/unreliable didInvalidate callback that broke v1 (see the v2 design doc).
        if let current = extendedSession, current.state == .running {
            guard Self.reanchorEnabled else { log("ext_session_renew_skipped", "reason=reanchor_disabled scene=\(lastKnownScenePhase)"); return }
            guard sessionPendingDidStart == nil, pendingReanchorSession == nil else {
                log("ext_session_renew_skipped", "reason=pending_start scene=\(lastKnownScenePhase)")
                return
            }
            guard let age = trueSessionAge() else {
                // No start stamp — seed it so the session ages toward the threshold instead of being skipped.
                let now = Date(); sessionStartedAt = now; persistSessionStart(now)
                log("ext_session_renew_skipped", "reason=running_no_start_ts_seeded scene=\(lastKnownScenePhase)")
                return
            }
            guard age >= Self.sessionReanchorAge else {
                log("ext_session_renew_skipped", "reason=running_not_near_expiry scene=\(lastKnownScenePhase)")
                return
            }
            let counter = bumpReanchorCounter()
            let delayMs = armADisabled ? [100, 300][counter % 2] : [0, 100, 300][counter % 3]
            let sid = shortReanchorID()
            reanchorSid = sid
            reanchorArmDelayMs = delayMs
            reanchorDidRetry = false
            reanchorSwapInFlight = true
            log("reanchor_attempt", "delay_ms=\(delayMs) sid=\(sid) age_s=\(Int(age)) old_state_before=\(describeState(current.state)) arm_a_disabled=\(armADisabled)")
            // #4: global swap backstop — force-clear swap-in-flight if the whole sequence ever stalls, so
            // renewals can't wedge behind reason=reanchor_swap_in_flight for the life of the process.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.reanchorSwapInFlight, self.reanchorSid == sid else { return }
                self.log("reanchor_swap_backstop_cleared", "sid=\(sid)")
                self.clearReanchorContext()
                self.recoverSessionAfterFailedReanchor()
            }

            invalidatingSessionIDs.insert(ObjectIdentifier(current))
            current.invalidate()
            let oldStateAfter = current.state
            extendedSession = nil
            sessionStartedAt = nil
            clearPersistedSessionStart()
            log("reanchor_invalidated", "delay_ms=\(delayMs) sid=\(sid) old_state_after=\(describeState(oldStateAfter))")
            // Marks the no-session window; correlate with the EGV stream for BLE-sever (#10 / design §6).
            log("reanchor_in_swap", "delay_ms=\(delayMs) sid=\(sid)")

            if delayMs == 0 {
                issueReanchorStart(delayMs: delayMs, sid: sid)
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    self?.issueReanchorStart(delayMs: delayMs, sid: sid)
                }
            }
            return
        }
        guard sessionPendingDidStart == nil else {
            // C-208-2/5.4: previously a silent return, indistinguishable from the debounce —
            // which made the pending-start wedge (3.1) invisible in telemetry.
            log("ext_session_renew_skipped", "reason=pending_start scene=\(lastKnownScenePhase)")
            return
        }
        if let last = lastStartRequestAt, Date().timeIntervalSince(last) < 30 {
            log("ext_session_renew_skipped", "reason=debounced scene=\(lastKnownScenePhase)")
            return
        }
        lastStartRequestAt = Date()
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        sessionPendingDidStart = session
        session.start()
        log("ext_session_start_requested_foreground", "scene_phase=\(lastKnownScenePhase)")
        // C-208-2 (3.1): pending-start watchdog. If watchOS never delivers didStart OR
        // didInvalidate for this start() (request silently dropped during a rapid scene flip),
        // `sessionPendingDidStart` would block all future renewals for the life of the process.
        // Identity-guarded — didStart / the pending-invalidation branch clear the field, making
        // this a no-op in every normal flow.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.sessionPendingDidStart === session else { return }
            if session.state == .running {
                // Verification finding: running-but-still-pending means the session IS live but
                // `didStart` was never delivered — the exact pathological class this watchdog
                // targets. Adopt it (mirror `extendedRuntimeSessionDidStart`) instead of leaving
                // the pending slot wedged for process life.
                self.sessionPendingDidStart = nil
                self.extendedSession = session
                let adoptedAt = Date(); self.sessionStartedAt = adoptedAt; self.persistSessionStart(adoptedAt) // C-212-5 v2
                self.lastKnownExtSessionActive = true
                self.sessionInvalidatedAt = nil
                self.sessionNearExpiryLogged = false
                self.log("ext_session_start_timeout", "state=running adopted=true")
                self.consumeDeferredScanIfNeeded()
            } else {
                self.sessionPendingDidStart = nil
                self.log("ext_session_start_timeout", "state=\(self.describeState(session.state))")
            }
        }
    }

    // MARK: - C-212-5 v2 inline re-anchor helpers

    /// Issue the replacement session for an inline re-anchor (arm A immediately; B/C after the delay).
    /// `start()` called while `.active` is the only OS requirement; `scene_at_start` is logged to measure it.
    private func issueReanchorStart(delayMs: Int, sid: String) {
        guard reanchorSwapInFlight, reanchorSid == sid else { // #4: a stale delayed task whose swap was cleared
            log("reanchor_start_stale", "delay_ms=\(delayMs) sid=\(sid)")
            return
        }
        guard lastKnownScenePhase == "active" else {
            lastKnownExtSessionActive = false
            sessionInvalidatedAt = Date()
            log("reanchor_abandoned", "reason=left_active phase=start delay_ms=\(delayMs) sid=\(sid)")
            recordReanchorFailure(delayMs: delayMs)
            clearReanchorContext()
            recoverSessionAfterFailedReanchor()
            return
        }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        pendingReanchorSession = s
        sessionPendingDidStart = s
        s.start()
        log("reanchor_start_issued", "delay_ms=\(delayMs) sid=\(sid) scene_at_start=\(lastKnownScenePhase)")
        startReanchorPendingWatchdog(s, sid: sid, delayMs: delayMs)
    }

    /// 15s backstop for a re-anchor replacement: watchOS IPC can black-hole start() (no didStart/didInvalidate).
    /// Identity-guarded; adopts a running-but-silent session, else clears the slot so renewals aren't wedged.
    private func startReanchorPendingWatchdog(_ session: WKExtendedRuntimeSession, sid: String, delayMs: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.pendingReanchorSession === session else { return }
            if session.state == .running {
                self.extendedSession = session
                let now = Date(); self.sessionStartedAt = now; self.persistSessionStart(now)
                self.lastKnownExtSessionActive = true
                self.sessionInvalidatedAt = nil
                self.sessionNearExpiryLogged = false
                self.armAConsecFailures = 0
                self.log("reanchor_replacement_started", "delay_ms=\(delayMs) sid=\(sid) adopted=true")
                self.consumeDeferredScanIfNeeded() // C-215: C1 parity with didStart + the normal start-timeout watchdog
            } else {
                self.lastKnownExtSessionActive = false
                self.sessionInvalidatedAt = Date()
                self.log("reanchor_pending_timeout", "state=\(self.describeState(session.state)) delay_ms=\(delayMs) sid=\(sid)")
                self.recordReanchorFailure(delayMs: delayMs)
            }
            self.pendingReanchorSession = nil
            if self.sessionPendingDidStart === session { self.sessionPendingDidStart = nil }
            self.clearReanchorContext()
            self.recoverSessionAfterFailedReanchor()
        }
    }

    /// Arm-A circuit-breaker: only the 0ms arm feeds it, on any true failure of an attempt — an overlap
    /// rejection that survives the 200ms retry, a black-holed start (pending-timeout), or an abandon.
    /// 5 consecutive → drop arm A from rotation for the rest of this process (resets on any A success).
    private func recordReanchorFailure(delayMs: Int) {
        guard delayMs == 0 else { return }
        armAConsecFailures += 1
        if armAConsecFailures >= 5, !armADisabled {
            armADisabled = true
            log("reanchor_armA_disabled", "consec_failures=\(armAConsecFailures)")
        }
    }

    private func clearReanchorContext() {
        reanchorSid = nil
        reanchorArmDelayMs = 0
        reanchorDidRetry = false
        reanchorSwapInFlight = false
    }

    /// #2: after a re-anchor swap fails (old session already gone), start a fresh normal session in the
    /// SAME foreground visit instead of waiting for the next open. No-op if a session is live/pending or
    /// the app is no longer active.
    private func recoverSessionAfterFailedReanchor() {
        guard lastKnownScenePhase == "active", extendedSession == nil,
              pendingReanchorSession == nil, sessionPendingDidStart == nil else { return }
        log("reanchor_recover_session", "")
        lastStartRequestAt = nil // #3: bypass the 30s start debounce — coverage was just lost, start now
        renewSessionIfNeeded()
    }

    /// True session age from the persisted didStart epoch (survives adoption/resurrection, §8.7),
    /// falling back to the in-memory stamp. nil when neither is known.
    private func trueSessionAge() -> TimeInterval? {
        let epoch = UserDefaults.standard.double(forKey: Self.sessionStartEpochKey)
        if epoch > 0 {
            let age = Date().timeIntervalSince1970 - epoch
            if age >= 0, age < 2 * 3600 { return age } // a real session never exceeds ~1h; discard a stale epoch
            clearPersistedSessionStart()
        }
        if let started = sessionStartedAt { return Date().timeIntervalSince(started) }
        return nil
    }

    private func persistSessionStart(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.sessionStartEpochKey)
    }

    private func clearPersistedSessionStart() {
        UserDefaults.standard.removeObject(forKey: Self.sessionStartEpochKey)
    }

    /// A/B/C round-robin counter, persisted so the arm sequence survives restarts.
    private func bumpReanchorCounter() -> Int {
        let next = UserDefaults.standard.integer(forKey: Self.reanchorCounterKey) &+ 1
        UserDefaults.standard.set(next, forKey: Self.reanchorCounterKey)
        return next
    }

    private func shortReanchorID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    /// Phone relay (WatchConnectivity): persist peripheral name and rescan. Logs **`sensor_name_set_from_phone`** when the stored name changes (dedupes overlapping WC paths).
    func setActiveSensorName(_ name: String?) {
        let willMutate = name != expectedSensorName
        if let name {
            setActiveSensorIdentity(SensorIdentity(name: name, activationEpochSeconds: nil))
        } else {
            applyNewSensorName(nil) // clear
        }
        guard willMutate else { return }
        log("sensor_name_set_from_phone", "name=\(name ?? "nil")")
    }

    /// C2 — the quarantine-aware identity entry point. Accepts/rejects an incoming (name, epoch),
    /// promotes a legacy (name-only) binding to epoch-bearing, and on an accepted swap does the full
    /// reset (immediate teardown + gated rescan). Sits behind the watch reader's build-time freshness gate.
    func setActiveSensorIdentity(_ incoming: SensorIdentity) {
        let currentName = expectedSensorName
        let currentEpoch = storedActivationEpochSeconds

        // 1. Quarantine gate.
        if let q = quarantine, isQuarantined(incoming, against: q) {
            log(
                "identity_quarantined",
                "reason=\(incoming.activationEpochSeconds == nil ? "missing_epoch_same_name" : "revived") "
                    + "name=\(incoming.name) incoming_epoch=\(incoming.activationEpochSeconds.map(String.init) ?? "nil") "
                    + "quarantine_epoch=\(q.activationEpochSeconds.map(String.init) ?? "nil")"
            )
            return
        }
        if incoming.activationEpochSeconds == nil {
            log("identity_epoch_missing", "name=\(incoming.name)")
        }

        // 2. Change type.
        let isSwap: Bool
        if incoming.name != currentName {
            isSwap = true
        } else if let inE = incoming.activationEpochSeconds, let curE = currentEpoch, inE > curE {
            isSwap = true // same name, strictly newer epoch = sensor restart/replacement
        } else {
            isSwap = false
        }

        // 3. No swap: promote a legacy binding to epoch-bearing if the epoch just arrived; else no-op.
        if !isSwap {
            if currentEpoch == nil, let inE = incoming.activationEpochSeconds, incoming.name == currentName {
                storedActivationEpochSeconds = inE
                log("identity_promoted", "name=\(incoming.name) epoch=\(inE)")
            }
            return
        }

        // 4. Accepted swap: persist the new identity, tear down immediately, gated rescan.
        log(
            "identity_accepted",
            "reason=swap name=\(incoming.name) incoming_epoch=\(incoming.activationEpochSeconds.map(String.init) ?? "nil") "
                + "prev_name=\(currentName ?? "nil") prev_epoch=\(currentEpoch.map(String.init) ?? "nil")"
        )
        storedActivationEpochSeconds = incoming.activationEpochSeconds
        pendingSensorSwap = true
        applyNewSensorName(incoming.name, force: true)
        pendingSensorSwap = false
    }

    /// Quarantine match: same name blocks unless the incoming epoch is strictly newer; a different name
    /// escapes; an epoch-bearing payload against a name-only quarantine is accepted (promotion); a
    /// missing-epoch payload with the same name as ANY quarantine is blocked.
    private func isQuarantined(_ incoming: SensorIdentity, against q: SensorIdentity) -> Bool {
        guard incoming.name == q.name else { return false }
        guard let inE = incoming.activationEpochSeconds else { return true }
        guard let qE = q.activationEpochSeconds else { return false }
        return inE <= qE
    }

    /// Called when WatchConnectivity (or another owner) pushes a new Dexcom peripheral name.
    /// Updates `expectedSensorName`; if the name changed, drops
    /// any current binding and starts a fresh scan via `sensor.scanForNewSensor()`. The single
    /// `G7Sensor` instance is preserved across name changes (mirrors phone `G7CGMManager`).
    func applyNewSensorName(_ name: String?, force: Bool = false) {
        let oldName = expectedSensorName
        guard force || name != oldName else { return } // force: same-name newer-epoch swap (C2)
        loadDailyCountersIfNewCalendarDay()
        let wasNil = (oldName == nil)
        expectedSensorName = name
        syncTelemetryRingContext() // C-208-9
        refreshIneligibilityClock() // C-209-1: identity arrived/changed/cleared — flip the clock
        if isStarted, expectedWindowTimer == nil { scheduleNextExpectedWindowTick() } // C-209-1: identity-after-launch
        if name == nil { storedActivationEpochSeconds = nil } // C2: clearing the binding clears its epoch
        consecutivePreEGVDisconnects = 0
        // Clear session-scoped EGV state so the first reading from the new sensor is not
        // deduped against the previous sensor's last sequence, does not compute delta
        // against the previous sensor's glucose value, and does not reuse the previous
        // sensor's activation date for the reading timestamp. `handleSensorDisconnected`
        // (which fires when `performScanForNewSensor()` cancels the active peripheral)
        // does not clear these fields — only `performEndOfSessionTeardown` does, and a
        // phone-pushed sensor swap can happen without an EOS-marked EGV arriving first.
        lastReadingSequence = nil
        lastSavedGlucoseValue = nil
        sessionActivationDate = nil
        mirrorDailyCountersToWatchState()
        // C2 accepted swap: the old binding is definitively dead — tear it down NOW even if the
        // scan is gated (deferred). Routine rebind leaves boundSensorName for performScanForNewSensor.
        if pendingSensorSwap { boundSensorName = nil }
        beginScanIfEligible(.newSensor) // C1-gated; performScanForNewSensor clears boundSensorName when it runs
        if wasNil, name != nil { log("start_recovered_from_nil_sensor") }
        if name == nil {
            log("sensor_name_cleared")
        }
        publishConnectionStatus()
    }

    // MARK: - Logging

    private func log(_ eventName: String, _ fields: String = "") {
        let sid = adapterSessionID ?? "nil"
        let sensorName = expectedSensorName ?? "nil"
        // C-212-4 (BUG-F): every g7_ble event carries scene_phase + ext_session_active so
        // foreground/background attribution is exact. Several call sites previously omitted one or
        // both (e.g. pre_egv_disconnect had ext_session_active but not scene_phase). Append here only
        // when the caller did not already include the field inline (avoids duplicate tokens).
        var stamped = fields
        // Token-boundary guard (review): match the field only at start-of-string or after a space, so
        // a value like `last_known_ext_session_active=` doesn't suppress the canonical stamp.
        if !(stamped.hasPrefix("scene_phase=") || stamped.contains(" scene_phase=")) {
            stamped += (stamped.isEmpty ? "" : " ") + "scene_phase=\(lastKnownScenePhase)"
        }
        if !(stamped.hasPrefix("ext_session_active=") || stamped.contains(" ext_session_active=")) {
            stamped += " ext_session_active=\(lastKnownExtSessionActive)"
        }
        // C-208-9: synchronous ring enqueue — no Task spawn / actor suspension per event on the
        // hot path. The ring's drainer feeds WatchLogger downstream.
        WatchTelemetryRing.shared.enqueue(
            G7StructuredTelemetryLogLine.formatBleModule(
                sensorName: sensorName,
                event: eventName,
                fields: stamped,
                g7Session: sid
            )
        )
    }

    /// C-208-9 / C-212-4 pt2: keep the ring's emit-time context (used for fork `module=g7_core`
    /// lines) in sync with the adapter — session identity (sensor name + adapter session id) AND
    /// scene_phase + ext_session_active. Called wherever `adapterSessionID`/sensor name change, and
    /// (via `didSet`) whenever `lastKnownScenePhase`/`lastKnownExtSessionActive` change.
    private func syncTelemetryRingContext() {
        WatchTelemetryRing.shared.setContext(
            sensorName: expectedSensorName ?? "nil",
            g7Session: adapterSessionID ?? "nil",
            scenePhase: lastKnownScenePhase,
            extSessionActive: lastKnownExtSessionActive
        )
    }

    // MARK: - Timers

    private func stopTimers() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        expectedWindowTimer?.cancel()
        expectedWindowTimer = nil
        expectedWindowNextEpoch = nil
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.cancel()
        let interval: TimeInterval = 5 * 60
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.emitHeartbeat()
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func emitHeartbeat() {
        let extStateRaw: String
        if let s = extendedSession {
            extStateRaw = describeState(s.state)
        } else {
            extStateRaw = "nil"
        }
        let sessionLive = lastKnownExtSessionActive || extendedSession?.state == .running
        let ageS = sessionLive ? (trueSessionAge().map(Int.init) ?? -1) : -1
        let deadSinceS = (!sessionLive && sessionInvalidatedAt != nil)
            ? Int(Date().timeIntervalSince(sessionInvalidatedAt!))
            : -1

        // C-216 (W-7a/Task B): BLE diagnostics snapshot on the heartbeat. `active_peripheral_state=1`
        // (CBPeripheralState.connecting) together with `connect_pending_age_s=-1` is the unwatched-wedge
        // fingerprint (06-30 deep-gap class) — a connect that never completes and has no this-process
        // pending-connect marker; `connecting_ticks` sizes how long that state has persisted.
        let diag = sensor.diagnosticsSnapshot()
        if diag.activePeripheralStateRaw == 1 {
            consecutiveConnectingTicks += 1
        } else {
            consecutiveConnectingTicks = 0
        }

        log(
            "heartbeat",
            "ext_session_active=\(lastKnownExtSessionActive) ext_session_state=\(extStateRaw) session_age_s=\(ageS) session_dead_since_s=\(deadSinceS) central_state=\(diag.centralStateRaw) scan_active=\(diag.isScanning) active_peripheral_state=\(diag.activePeripheralStateRaw ?? -1) connect_pending_age_s=\(diag.connectPendingAgeS ?? -1) s_since_discover=\(diag.secondsSinceLastDiscover ?? -1) last_rssi=\(diag.lastDiscoverRSSI ?? 127) connecting_ticks=\(consecutiveConnectingTicks)"
        )

        if !sessionNearExpiryLogged,
           extendedSession?.state == .running,
           let age = trueSessionAge(),
           age >= 55 * 60,
           lastKnownScenePhase != "active" {
            sessionNearExpiryLogged = true
            log("ext_session_nearing_expiry", "age_s=\(Int(age)) scene_phase=\(lastKnownScenePhase)")
        }
    }

    /// C-209-1: schedule the next `expected_window` telemetry tick at the next wall-clock
    /// 5-min boundary. Pure telemetry — slot counting is analytical now (`dailySlotStats`), so
    /// the old EGV-anchored re-anchor / retroactive-replay machinery (with its `>50` cap and
    /// `hasAnchored` gate) is deleted.
    private func scheduleNextExpectedWindowTick() {
        expectedWindowTimer?.cancel()
        let nowEpoch = Int(Date().timeIntervalSince1970)
        let nextEpoch = nowEpoch - (nowEpoch % 300) + 300
        expectedWindowNextEpoch = nextEpoch
        let delay = max(1.0, Double(nextEpoch) - Date().timeIntervalSince1970)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + delay, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fireExpectedWindowTick()
            }
        }
        timer.resume()
        expectedWindowTimer = timer
    }

    private func fireExpectedWindowTick() {
        guard let epoch = expectedWindowNextEpoch else { return }
        emitExpectedWindowTick(epoch: epoch)
        evaluateDirectBleStall()
        scheduleNextExpectedWindowTick()
    }

    // MARK: - C-210-4/5/8: direct-BLE stall detection (cross-source freshness)

    private enum StallThreshold {
        static let softMin = 12      // soft stall: direct stale > 12 min
        static let hardMin = 30      // hard stall: direct stale > 30 min
        static let phoneFreshSec = 7 * 60  // phone counts as "fresh" within 7 min
        static let connectRecentSec = 15 * 60 // a connect window within 15 min => Trio-side (has windows)
    }

    /// C-210-4: classify a direct-BLE stall from cross-source freshness and surface it (UI tier +
    /// telemetry + a conservative notification). Direct path stale while the phone path is fresh =>
    /// the complication is silently riding the phone relay. Both stale => system-wide (not flagged).
    /// Runs on the ~300s expected-window tick (@MainActor).
    private func evaluateDirectBleStall(now: Date = Date()) {
        guard isStarted else { return }
        // No expected sensor => warmup / sessionEnded / no-sensor: ineligible, not a stall.
        guard expectedSensorName != nil else { clearDirectBleStallIfNeeded(); return }
        let staleMin = minutesSinceLastEGV()
        guard staleMin >= 0 else { return } // never had a direct EGV (cold launch) — nothing to compare

        let phoneFresh: Bool = {
            guard let p = WatchState.shared.lastPhoneEGVDate else { return false }
            return now.timeIntervalSince(p) < Double(StallThreshold.phoneFreshSec)
        }()

        // Direct still fresh, or phone also stale (system-wide gap) => not a direct-BLE stall.
        guard staleMin >= StallThreshold.softMin, phoneFresh else { clearDirectBleStallIfNeeded(); return }

        let tier: DirectBleStallTier = staleMin >= StallThreshold.hardMin ? .unavailable : .stalled

        // C-210-8: fault classification via connection-event recency. Recent connect window but no
        // EGV => Trio-side (extraction wedged; self-healable). No recent window => Dexcom-side (its
        // direct link is down; Trio can only observe). sessionConnectAt is the last did_connect.
        let sinceConnectS: Int = sessionConnectAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        let dexcomSide = sinceConnectS < 0 || sinceConnectS > StallThreshold.connectRecentSec
        lastDirectBleStallFault = dexcomSide ? "dexcom_side" : "trio_side" // C-217 D-7: expose for the diagnostics Stall row

        // C-216 (Task A): stamp last-seen RSSI + its age onto the stall event. This tick runs at most
        // every ~5 min, so one snapshot call here is cheap; `rssi_age_s=-1` means no didDiscover has
        // happened yet this process (secondsSinceLastDiscover nil), `last_rssi=127` = BT-spec "RSSI not available".
        let diag = sensor.diagnosticsSnapshot()
        let rssiAgeS = diag.secondsSinceLastDiscover ?? -1
        log(
            "direct_ble_stall_detected",
            "tier=\(tier.rawValue) direct_stale_min=\(staleMin) phone_fresh=\(phoneFresh) fault=\(dexcomSide ? "dexcom_side" : "trio_side") since_connect_s=\(sinceConnectS) last_rssi=\(diag.lastDiscoverRSSI ?? 127) rssi_age_s=\(rssiAgeS)"
        )

        if WatchState.shared.directBleStall != tier { WatchState.shared.directBleStall = tier }

        // C-210-5: notify ONLY on a sustained HARD Dexcom-side stall (Trio cannot self-heal that),
        // once per episode. Trio-side stalls self-recover; soft stalls stay silent. Alarm-fatigue
        // guards are non-negotiable for a glucose app.
        if tier == .unavailable, dexcomSide, !stallNotifiedThisEpisode {
            stallNotifiedThisEpisode = true
            WatchNotificationHandler.shared.postDirectBleStallNotification()
            log("direct_ble_stall_notified", "tier=\(tier.rawValue) since_connect_s=\(sinceConnectS)")
        }

        // C-217 Task 4: attempt a CoreBluetooth central re-init once per sustained hard Dexcom-side episode — the connect_called=0 deep-gap class that Task-2 wedge escalation cannot reach. Bounded by the fork isCentralReinitEnabled kill-switch + 120s guard.
        if tier == .unavailable, dexcomSide, !centralReinitThisEpisode {
            centralReinitThisEpisode = true
            sensor.requestCentralReinit(reason: "dexcom_side_episode")
        }
    }

    /// Reset the stall indicator and the per-episode notification latch once the direct path recovers
    /// (or becomes ineligible). A later genuine stall can then notify again.
    private func clearDirectBleStallIfNeeded() {
        stallNotifiedThisEpisode = false
        centralReinitThisEpisode = false
        lastDirectBleStallFault = nil // C-217 D-7
        if WatchState.shared.directBleStall != .none { WatchState.shared.directBleStall = .none }
    }

    /// C-209-1: pure telemetry — per-5-min eligibility sampling for the COV dashboards. The
    /// `retroactive=` field is gone with the replay machinery; consumers keyed on
    /// reason/eligible are unaffected. Slot counting lives in `dailySlotStats`.
    private func emitExpectedWindowTick(epoch: Int) {
        let lastSuccess = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int ?? -1
        let eligible = expectedSensorName != nil
        let reason = eligible ? "ok" : "no_sensor"
        advanceDayIfNeeded() // forward-only, keyed on real time
        log(
            "expected_window",
            "tick_epoch=\(epoch) last_success_epoch=\(lastSuccess) eligible=\(eligible) reason=\(reason) ext_session_active=\(lastKnownExtSessionActive)"
        )
    }

    // MARK: - Daily counters (Task B2 — parity with `G7DirectBLEObserver`; keys `G7DirectBLEObserver.bleCountersCalendarDay` / `bleConnectsToday` / `bleEGVsToday`)

    private func loadDailyCounters() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: Keys.calendarDay)
        if storedDay != dayStart {
            resetDailyCountersInMemory()
            UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
            persistDailyCounters()
        } else {
            bleConnectsToday = UserDefaults.standard.integer(forKey: Keys.connects)
            bleEGVsToday = UserDefaults.standard.integer(forKey: Keys.egvs)
            gatedSlotEpochsToday = Set((UserDefaults.standard.array(forKey: Keys.gatedSlotEpochs) as? [Int]) ?? [])
            gatedSlotsToday = gatedSlotEpochsToday.count
            ineligibleSecondsToday = UserDefaults.standard.double(forKey: Keys.ineligibleSeconds)
            let sinceEpoch = UserDefaults.standard.double(forKey: Keys.ineligibleSinceEpoch)
            ineligibleSince = sinceEpoch > 0 ? Date(timeIntervalSince1970: sinceEpoch) : nil
        }
        mirrorDailyCountersToWatchState()
    }

    /// In-memory reset of ALL daily counters (shared by load + rollover). W7: also clears the slot
    /// high-water and the gated set. Does not touch UserDefaults — callers persist.
    private func resetDailyCountersInMemory() {
        bleConnectsToday = 0
        bleEGVsToday = 0
        gatedSlotEpochsToday = []
        gatedSlotsToday = 0
        // C-209-1: zero the closed ineligible time; keep `ineligibleSince` — an open ineligible
        // stretch continues across midnight and clamps to startOfToday at read time.
        ineligibleSecondsToday = 0
    }

    private func persistDailyCounters() {
        UserDefaults.standard.set(bleConnectsToday, forKey: Keys.connects)
        UserDefaults.standard.set(bleEGVsToday, forKey: Keys.egvs)
        UserDefaults.standard.set(Array(gatedSlotEpochsToday), forKey: Keys.gatedSlotEpochs)
        UserDefaults.standard.set(ineligibleSecondsToday, forKey: Keys.ineligibleSeconds)
        UserDefaults.standard.set(ineligibleSince?.timeIntervalSince1970 ?? 0, forKey: Keys.ineligibleSinceEpoch)
    }

    /// Forward-only daily rollover keyed on real wall-clock. Resets all daily counters + the slot
    /// high-water + gated set when the local day has advanced; never rolls backward. Invoked from the
    /// expected-window tick AND the C1 scan gate (which can be the first counter activity after
    /// midnight while the expected-window timer is suspended in the background).
    private func advanceDayIfNeeded() {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let storedDay = UserDefaults.standard.double(forKey: Keys.calendarDay)
        guard dayStart > storedDay else { return } // forward-only
        resetDailyCountersInMemory()
        UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
    }

    private func loadDailyCountersIfNewCalendarDay() {
        advanceDayIfNeeded()
    }

    private func mirrorDailyCountersToWatchState() {
        WatchState.shared.bleConnectsToday = bleConnectsToday
        WatchState.shared.bleEGVsToday = bleEGVsToday
        WatchState.shared.gatedSlotsToday = gatedSlotsToday
    }

    /// C-209-1 (B1): edge-event ineligibility clock. Called whenever `expectedSensorName`
    /// flips nil/non-nil (identity push, EOS teardown) and once at start(). No timer — correct
    /// across any background suspension.
    private func refreshIneligibilityClock() {
        advanceDayIfNeeded()
        let eligible = expectedSensorName != nil
        if eligible, let since = ineligibleSince {
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let from = max(since, startOfToday)
            ineligibleSecondsToday += max(0, Date().timeIntervalSince(from))
            ineligibleSince = nil
            persistDailyCounters()
        } else if !eligible, ineligibleSince == nil {
            ineligibleSince = Date()
            persistDailyCounters()
        }
    }

    /// C-209-1 (B1): analytical inputs for the debug view's "captured / possible" ratio.
    /// `elapsedSlots` is pure wall-clock (correct across suspension); ineligible and gated
    /// subtract from it. `eligibleSlots` clamps ≥0 by construction.
    struct DailySlotStats {
        let egvs: Int
        let elapsedSlots: Int
        let ineligibleSlots: Int
        let gatedSlots: Int
        var eligibleSlots: Int { max(0, elapsedSlots - ineligibleSlots - gatedSlots) }
    }

    func dailySlotStats(now: Date = Date()) -> DailySlotStats {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let elapsed = max(0, Int(now.timeIntervalSince(startOfToday)) / 300)
        var ineligible = ineligibleSecondsToday
        if let since = ineligibleSince {
            let from = max(since, startOfToday)
            ineligible += max(0, now.timeIntervalSince(from))
        }
        return DailySlotStats(
            egvs: bleEGVsToday,
            elapsedSlots: elapsed,
            ineligibleSlots: Int(ineligible) / 300,
            gatedSlots: gatedSlotsToday
        )
    }

    /// Minutes since the last persisted EGV epoch (`Keys.lastEGVEpoch`). Returns -1 when no EGV
    /// has been observed. Internal access so the debug view can render it.
    func minutesSinceLastEGV() -> Int {
        guard let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int else {
            return -1
        }
        let now = Int(Date().timeIntervalSince1970)
        return max(0, (now - epoch) / 60)
    }

    /// Calls `sensor.scanForNewSensor()` with `isScanningForNewSensor` set so the downstream
    /// disconnect callback (if any) skips the pre-EGV counter increment.
    ///
    /// **Auto-clear:** `bluetoothManager.disconnect()` only fires a callback when an active
    /// peripheral exists. When we initiate a rescan while not connected (cold start, inside a
    /// disconnect-driven path), no callback comes and a sticky `true` flag would suppress the
    /// next legitimate disconnect. Clearing after a short timeout bounds that window.
    /// C1 — the only way the **adapter** initiates scanning/connecting; every adapter-side scan
    /// entry routes here. C-209-10 (review 2.4): this is NOT the only scan source overall — the
    /// fork's `scanAfterDelay()` self-reschedules scans after disconnects (visible as
    /// `rescan_scheduled` since build 208), so `ble_gated`-derived denominators must not assume
    /// C1 sees every scan.
    /// Allows the scan when scene-active or runtime `.running`; otherwise defers it (preserving the
    /// kind) and records the slot as gated. Timers/counters keep running outside this — `start()`
    /// is never gated wholesale. "Gate, don't recover-harder": the only deferral is
    /// background-with-no-session, exactly when a scan would fail with `reason=-1` anyway.
    /// Returns `true` if a scan actually started, `false` if it was C1-gated/deferred (lets callers
    /// avoid advertising `.scanning` when nothing started — UI-207-2).
    @discardableResult
    private func beginScanIfEligible(_ kind: ScanKind) -> Bool {
        advanceDayIfNeeded() // gate can be the first counter activity after midnight (timers suspended)
        guard isRuntimeEligible else {
            // Preserve the kind across the deferral — a pending .newSensor must not be downgraded.
            deferredScanKind = (deferredScanKind == .newSensor || kind == .newSensor) ? .newSensor : .resume
            // Count the slot as gated only when also identity-eligible (same predicate as expected).
            let identityEligible = expectedSensorName != nil
            let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            let nowSlot = Int(Date().timeIntervalSince1970)
            let slotEpoch = nowSlot - (nowSlot % 300)
            if identityEligible, slotEpoch >= startOfToday, gatedSlotEpochsToday.insert(slotEpoch).inserted {
                gatedSlotsToday = gatedSlotEpochsToday.count
                persistDailyCounters()
                mirrorDailyCountersToWatchState()
            }
            log(
                "ble_gated",
                "reason=no_runtime kind=\(kind) slot=\(slotEpoch) identity_eligible=\(identityEligible) "
                    + "scene_phase=\(lastKnownScenePhase) runtime_eligible=false "
                    + "ext_session_state=\(extendedSession.map { describeState($0.state) } ?? "nil") "
                    + "last_known_ext_session_active=\(lastKnownExtSessionActive)"
            )
            return false
        }
        switch kind {
        case .resume: sensor.resumeScanning()
        case .newSensor: performScanForNewSensor()
        }
        return true
    }

    /// Consume a deferred scan when runtime becomes eligible (scene-active or session `.running`).
    /// Clear BEFORE re-issuing: if still ineligible, `beginScanIfEligible` re-stashes the kind.
    private func consumeDeferredScanIfNeeded() {
        let kind = deferredScanKind
        deferredScanKind = nil
        if let kind { beginScanIfEligible(kind) }
    }

    /// The real new-sensor scan body. Clears the binding here (not at the call site) so a still-valid
    /// `boundSensorName` is torn down only when the scan actually proceeds (C1 deferred-clear).
    private func performScanForNewSensor() {
        boundSensorName = nil
        isScanningForNewSensor = true
        sensor.scanForNewSensor()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.isScanningForNewSensor = false
        }
    }

    private func publishConnectionStatus() {
        let s = sensor
        let status: G7DirectBLEStatus
        if s.isConnected {
            status = .active
        } else if s.isScanning {
            status = .scanning
        } else {
            // UI-207-2: armed but not connected/scanning — the idle wait between G7
            // advertisements (incl. the fork's 2s post-disconnect settle and a C1-deferred scan),
            // not an OS-cache "retrieving" operation. Build 208: `.off` is no longer reachable
            // from here (`stop()` removed); it remains only as WatchState's pre-first-event default.
            status = .waiting
        }
        WatchState.shared.applyG7DirectBleStatus(status)
    }

    private func triggerEndOfSessionFromEGV(reason: String, message: G7GlucoseMessage) {
        // Adapter is `@MainActor`; this path runs only after delegate hop — safe to read battery on-device.
        let battery: Int = {
            let device = WKInterfaceDevice.current()
            guard device.isBatteryMonitoringEnabled else { return -1 }
            let level = device.batteryLevel
            guard level >= 0 else { return -1 }
            return Int(round(level * 100))
        }()
        let sensorAgeSeconds = Int(Double(message.messageTimestamp) - Double(message.age))
        log(
            "eos_detected",
            "reason=\(reason) battery_level_percent=\(battery) state=\(message.algorithmState.rawValue) sensor_age_s=\(sensorAgeSeconds)"
        )
        performEndOfSessionTeardown()
    }

    /// Shared post-EOS state teardown. Clears the expected/bound names, resets the disconnect
    /// counter and session-scoped state, and asks the live `G7Sensor` to forget its peripheral
    /// and start a fresh scan. With `expectedSensorName == nil`, `didDiscoverNewSensor` rejects
    /// every discovery until the phone pushes a new name. Status is published as `.scanning`
    /// (we are actively scanning, just for nothing the adapter will accept yet).
    private func performEndOfSessionTeardown() {
        // C2: quarantine the dying identity BEFORE clearing it, so a phone re-push of the same
        // (name, epoch) after EOS is rejected (no reconnect storm). In-memory; cleared on app restart.
        if let name = expectedSensorName {
            quarantine = SensorIdentity(name: name, activationEpochSeconds: storedActivationEpochSeconds)
            log("identity_quarantined", "reason=eos name=\(name) epoch=\(storedActivationEpochSeconds.map(String.init) ?? "nil")")
        }
        expectedSensorName = nil
        storedActivationEpochSeconds = nil
        syncTelemetryRingContext() // C-208-9
        refreshIneligibilityClock() // C-209-1: identity cleared — ineligible until the phone re-pushes
        boundSensorName = nil
        consecutivePreEGVDisconnects = 0
        lastReadingSequence = nil
        lastSavedGlucoseValue = nil
        sessionActivationDate = nil
        mirrorDailyCountersToWatchState()
        sessionPhase = .preEGV
        // UI-207-2: only advertise `.scanning` if the C1-gated scan actually started; otherwise the
        // adapter is armed-but-waiting (deferred until runtime-eligible), not scanning.
        let didStartScan = beginScanIfEligible(.newSensor) // C1-gated
        WatchState.shared.applyG7DirectBleStatus(didStartScan ? .scanning : .waiting)
    }
}

// MARK: - G7SensorDelegate (G7SensorKit invokes these on `delegateQueue`; nonisolated stubs hop to `@MainActor` adapter.)

extension G7WatchSensorAdapter: G7SensorDelegate {
    nonisolated func sensorDidConnect(_ sensor: G7Sensor, name: String) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidConnect(name: name)
        }
    }

    nonisolated func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDisconnected(suspectedEndOfSession: suspectedEndOfSession)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didError error: Error) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.log("sensor_error", "error=\(String(describing: error))")
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, logComms comms: String) {
        _ = comms
    }

    nonisolated func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidRead(glucose: glucose)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.handleSensorDidReadBackfill(backfill: backfill)
        }
    }

    nonisolated func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool {
        _ = activatedAt
        // This callback runs on G7Sensor's `delegateQueue`, not MainActor — so we can't go through
        // `G7WatchSensorAdapter.shared` synchronously. Read the same UserDefaults key that backs
        // `expectedSensorName` directly (thread-safe). With no expected name, reject all discoveries.
        guard let expected = UserDefaults.standard.string(forKey: Keys.sensorName) else { return false }
        return name.suffix(2) == expected.suffix(2)
    }

    nonisolated func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        _ = extendedVersion
    }

    nonisolated func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {
        Task { @MainActor in
            G7WatchSensorAdapter.shared.publishConnectionStatus()
        }
    }

    private func handleSensorDidConnect(name: String) {
        recordSessionConnect(name: name, source: "did_connect_callback")
    }

    /// Shared connect bookkeeping. Called from `handleSensorDidConnect` (normal reconnect path,
    /// fired by `G7Sensor` once `sensorID` is set) **and** from `handleSensorDidRead` when a
    /// first-discovery cycle delivers a glucose message without a prior `sensorDidConnect`.
    ///
    /// **Why a first-read bootstrap exists:** `G7Sensor.bluetoothManager(_:readied:)` only fires
    /// `sensorDidConnect` when `sensorID != nil` at the time the peripheral is readied. On the
    /// initial discovery cycle for a new sensor identity (post-`scanForNewSensor()`), `sensorID`
    /// is nil at readied time. `G7Sensor` then sets `sensorID` itself inside `handleGlucoseMessage`
    /// after `didDiscoverNewSensor` returns true, and calls `didRead` directly. From the adapter's
    /// perspective, that means the first reading arrives without a preceding connect callback —
    /// so we treat the first reading as the connect event and run the same bookkeeping.
    private func recordSessionConnect(name: String, source: String) {
        // Record the peripheral name the sensor bound to. Mirrors `G7Sensor.sensorID` (private)
        // and is used by the debug UI and `start()`'s mismatch check. Setting this on the
        // first-read path also prevents `start()` from calling `performScanForNewSensor()`
        // again (which would disconnect the freshly-bound peripheral).
        boundSensorName = name
        sessionPhase = .preEGV
        adapterSessionID = String(UUID().uuidString.prefix(8))
        syncTelemetryRingContext() // C-208-9
        sessionConnectAt = Date()
        hadEGVThisSession = false
        loggedTimeToFirstEGVForSession = false
        bleConnectsToday += 1
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        let connectAt = Date()
        WatchState.shared.bleLastConnectAt = connectAt
        let nameProvenance = (source == "first_discovery_path") ? "expected" : "peripheral"
        log(
            "did_connect",
            "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) source=\(source) name_provenance=\(nameProvenance)"
        )
        // D8: do NOT request a session here. Connects happen mostly in the background, where the
        // request is denied before `didStart` (and hammering it invites throttling). Session
        // renewal is driven solely by the foreground-active entry (`renewSessionIfNeeded`).
        publishConnectionStatus()
        startEGVWatchdog(sessionToken: adapterSessionID)
    }

    /// C-208-4 (2.3): connected-but-silent backstop. **15s** > max-ever observed connect→EGV
    /// (13s across 1,400+ sessions); normal connections are ended by the transmitter at 6–10s,
    /// so on a healthy build this never fires. It exists for the configuration-dead-end class
    /// (~600s zombie connections on builds 204/205; C3 fixed the cause, C-208-11 escalates the
    /// residual) and doubles as that class's regression detector. NOT a connect timeout — the
    /// CoreBluetooth connect attempt is untouched (prohibited per AGENTS.md); this covers the
    /// post-`did_connect`→EGV span only. Identity-guarded by `adapterSessionID`; an EGV or a
    /// disconnect invalidates it implicitly (no cancellation bookkeeping needed).
    private func startEGVWatchdog(sessionToken: String?) {
        guard let token = sessionToken else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.adapterSessionID == token, !self.hadEGVThisSession else { return }
            self.log("egv_watchdog_fired", "since_connect_s=15")
            self.sensor.stopScanning() // disconnect; the fork re-attaches via its normal path
        }
    }

    private func handleSensorDisconnected(suspectedEndOfSession: Bool) {
        let sinceConnectS: Int = {
            guard let t = sessionConnectAt else { return -1 }
            return Int(Date().timeIntervalSince(t))
        }()
        let durationS = sinceConnectS

        // A disconnect that we ourselves initiated via `sensor.scanForNewSensor()` (which calls
        // `bluetoothManager.disconnect()` under the hood). Skip counter logic so self-rebinds,
        // sensor swaps, and EOS teardowns do not register as stale-binding failures.
        let initiatedScan = isScanningForNewSensor
        if initiatedScan {
            isScanningForNewSensor = false
        }

        log(
            "disconnect",
            "phase=\(sessionPhase.rawValue) since_did_connect_s=\(sinceConnectS) had_egv=\(hadEGVThisSession) session_duration_s=\(durationS) suspected_eos=\(suspectedEndOfSession) initiated_scan=\(initiatedScan) scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive)"
        )

        // D7: the fork's `suspectedEndOfSession` (pendingAuth && wasRemoteDisconnect) is a *phone*
        // heuristic. On the watch's ~5-min connect/auth/disconnect cadence it misfires on routine
        // reconnect churn (111 of 112 EOS in a week were false) and used to trigger a destructive
        // teardown — clearing the binding and leaving the watch dark until a phone re-push. Log it
        // for telemetry but do NOT tear down. A real session end is detected only from the
        // authoritative EGV-path signals in `handleSensorDidRead` (algorithmState.sensorFailed /
        // .sessionEnded / age ceiling), or from a phone-pushed sensor swap.
        if !initiatedScan, suspectedEndOfSession {
            log(
                "disconnect_suspected_eos_ignored",
                "had_egv=\(hadEGVThisSession) minutes_since_last_egv=\(minutesSinceLastEGV())"
            )
        }

        // NOTE: do not clear `boundSensorName` here. It mirrors `G7Sensor.sensorID`, which is only
        // cleared by `scanForNewSensor()` — not by transient disconnects (auto-reconnects expect
        // the binding to remain). The teardown paths that DO clear sensorID also clear bound here.

        if initiatedScan {
            // Skip counter logic — we caused this disconnect.
        } else if sessionPhase == .preEGV {
            consecutivePreEGVDisconnects += 1
            let minutesSinceEGV = minutesSinceLastEGV()
            // C-216 (W-6): sinceConnectS < 0 means no `sessionConnectAt` existed for this disconnect —
            // i.e. no preceding adapter-level connect. These are watchdog-cancel fallout (measured at
            // 67% of the old pre_egv_disconnect metric), not a real pre-EGV auth failure — split the
            // event name only; all fields and counter/stale-binding logic below are unchanged.
            let eventName = sinceConnectS < 0 ? "phantom_disconnect" : "pre_egv_disconnect"
            log(
                eventName,
                "since_connect_s=\(sinceConnectS) consecutive_count=\(consecutivePreEGVDisconnects) suspected_eos=\(suspectedEndOfSession) minutes_since_last_egv=\(minutesSinceEGV) ext_session_active=\(lastKnownExtSessionActive)"
            )
            // Gate the diagnostic / remediation thresholds on `minutesSinceLastEGV` too: a high
            // consecutive count while EGVs are still fresh means BLE noise, not stale binding.
            if consecutivePreEGVDisconnects >= 3 && minutesSinceEGV > 10 {
                log(
                    "stale_sensor_binding_suspected",
                    "consecutive_pre_egv_disconnects=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceEGV)"
                )
            }
            if consecutivePreEGVDisconnects >= 5 && minutesSinceEGV > 15 {
                log(
                    "stale_sensor_reinit",
                    "count=\(consecutivePreEGVDisconnects) minutes_since_last_egv=\(minutesSinceEGV)"
                )
                // Reset BEFORE scanning so the downstream disconnect callback (which sees
                // `isScanningForNewSensor=true`) skips counter increment cleanly. C1-gated;
                // performScanForNewSensor nils boundSensorName when the scan proceeds.
                consecutivePreEGVDisconnects = 0
                beginScanIfEligible(.newSensor)
            }
        } else {
            consecutivePreEGVDisconnects = 0
        }

        sessionPhase = .preEGV
        adapterSessionID = nil
        syncTelemetryRingContext() // C-208-9
        sessionConnectAt = nil
        hadEGVThisSession = false
        loggedTimeToFirstEGVForSession = false
        publishConnectionStatus()
    }

    private func handleSensorDidRead(glucose: G7GlucoseMessage) {
        // C-208-10: drain any undrained tail from a previous (suspended) cycle BEFORE this
        // reading can overwrite the single-record slot — its history entry must not be lost.
        drainPendingEGVTailIfAny()
        // First-read connect bootstrap. On the initial discovery cycle for a new sensor identity,
        // `G7Sensor` accepts the peripheral via `didDiscoverNewSensor` and calls `didRead` without
        // firing `sensorDidConnect` (see `recordSessionConnect` docs). Detect that case via
        // `boundSensorName == nil` and run the connect bookkeeping inline before any of the
        // glucose-message validation paths below. EOS / unreliable / dedup early-returns still
        // run after this; that's intentional — the sensor *did* connect, even if this particular
        // message is unusable, so the connect counter / log lines / session ID should reflect it.
        if boundSensorName == nil, let expected = expectedSensorName {
            recordSessionConnect(name: expected, source: "first_discovery_path")
        }
        if glucose.algorithmState.sensorFailed {
            triggerEndOfSessionFromEGV(reason: "algorithm_state", message: glucose)
            return
        }
        if glucose.algorithmState == .known(.sessionEnded) {
            triggerEndOfSessionFromEGV(reason: "algorithm_state", message: glucose)
            return
        }

        let sensorAgeSeconds = Double(glucose.messageTimestamp) - Double(glucose.age)
        if sensorAgeSeconds > G7Sensor.defaultLifetime + G7Sensor.gracePeriod {
            triggerEndOfSessionFromEGV(reason: "sensor_age_ceiling", message: glucose)
            return
        }

        guard glucose.hasReliableGlucose else {
            log(
                "egv_unreliable",
                "algorithm_state=\(glucose.algorithmState.rawValue) sequence=\(glucose.sequence) glucose=\(glucose.glucose.map(String.init) ?? "nil")"
            )
            return
        }

        if let lastSeq = lastReadingSequence, lastSeq == glucose.sequence {
            // C-208-4 guard (verification finding): the sensor demonstrably delivered an EGV on
            // this connection even though it's a duplicate — mark it so the 15s connect→EGV
            // watchdog cannot false-fire on a healthy duplicate-only reconnection.
            hadEGVThisSession = true
            log("egv_dedup", "glucose=\(glucose.glucose.map(String.init) ?? "nil") sequence=\(glucose.sequence)")
            return
        }

        // Anchor the session activation before the missing-value guard so a reading without a
        // glucose value still establishes the date basis for any backfill arriving in the same
        // connection (its own entries carry good values and need the anchor to be placed).
        if sessionActivationDate == nil {
            sessionActivationDate = Date().addingTimeInterval(-TimeInterval(glucose.messageTimestamp))
        }

        guard let gMgDl = glucose.glucose else {
            log("egv_missing_glucose_value", "sequence=\(glucose.sequence) state=\(glucose.algorithmState.rawValue)")
            return
        }
        let glucoseValue = Int(gMgDl)

        lastReadingSequence = glucose.sequence

        sessionPhase = .postEGV
        consecutivePreEGVDisconnects = 0
        hadEGVThisSession = true

        guard let activation = sessionActivationDate else { return }

        let readingDate = activation.addingTimeInterval(TimeInterval(glucose.glucoseTimestamp))
        let readingEpoch = Int(readingDate.timeIntervalSince1970)
        UserDefaults.standard.set(readingEpoch, forKey: Keys.lastEGVEpoch)
        scheduleNextExpectedWindowTick() // C-209-1: tick re-alignment only (slot counting is analytical now)

        // W7: if C1 gated this 5-min slot in the background but we then captured an EGV in it, it is
        // NOT a gated loss — remove it from the set so the denominator (expected − gated) doesn't
        // subtract a window that also counts toward the numerator (which would let the ratio exceed 100%).
        let capturedSlotEpoch = readingEpoch - (readingEpoch % 300)
        if gatedSlotEpochsToday.remove(capturedSlotEpoch) != nil {
            gatedSlotsToday = gatedSlotEpochsToday.count
            persistDailyCounters()
            mirrorDailyCountersToWatchState()
        }

        loadDailyCountersIfNewCalendarDay()

        bleEGVsToday += 1
        let currentSequence = Int(glucose.sequence)
        persistDailyCounters()
        mirrorDailyCountersToWatchState()
        let delta: String = {
            // C-210-2 (#2b): prefer the in-memory baseline; fall back to the cross-source history store
            // so a cold start / sensor swap (lastSavedGlucoseValue == nil) still yields a real delta
            // instead of "--". C-210-1: format in the user's display unit.
            let previous = lastSavedGlucoseValue
                ?? WatchGlucoseHistoryStore.shared.mostRecentMgDl(before: readingEpoch)
            guard let previous else { return "--" }
            return WatchGlucoseColorComputer.shared.displayDeltaString(previousMgDl: previous, currentMgDl: glucoseValue)
        }()
        lastSavedGlucoseValue = glucoseValue

        let trend = WatchState.trendString(fromDirectBleRate: glucose.trend)

        if !loggedTimeToFirstEGVForSession, let connectAt = sessionConnectAt {
            loggedTimeToFirstEGVForSession = true
            let ms = Int(Date().timeIntervalSince(connectAt) * 1000)
            log(
                "egv_received",
                "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) sequence=\(glucose.sequence) glucose=\(glucoseValue) time_to_first_egv_ms=\(ms)"
            )
        } else {
            log(
                "egv_received",
                "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) sequence=\(glucose.sequence) glucose=\(glucoseValue)"
            )
        }

        // C-208-10: "first write secures the capture." The hot path ends here — the reading is
        // already durable (`Keys.lastEGVEpoch` above) and the full display/persistence cascade
        // (history JSON write, complication bake + WidgetKit reload, WC context send) becomes a
        // replayable tail. If the OS suspends us anywhere in the tail, the pending record
        // replays on the next wake (launch / foreground entry / next EGV); the failure mode is
        // one cycle of display staleness, never a lost capture.
        persistPendingEGVTail(PendingEGVTail(
            readingEpoch: readingEpoch,
            glucoseMgDl: glucoseValue,
            sequence: currentSequence,
            trend: trend,
            delta: delta
        ))
        drainPendingEGVTailIfAny()

        publishConnectionStatus()
    }

    // MARK: - C-208-10: deferred EGV tail

    /// Everything needed to replay the post-capture cascade after a suspension or process death.
    struct PendingEGVTail: Codable {
        let readingEpoch: Int
        let glucoseMgDl: Int
        let sequence: Int
        let trend: String
        let delta: String
    }

    private static let pendingTailKey = "G7WatchAdapter.pendingEGVTail"

    private func persistPendingEGVTail(_ tail: PendingEGVTail) {
        // Single-record slot. A previous undrained tail is drained by the caller BEFORE the new
        // record is written (`handleSensorDidRead` calls drain → persist → drain), so overwrite
        // here can only race process death — in which case the newer reading wins, which is the
        // intended coalescing policy for display; history receives whatever drains.
        if let data = try? JSONEncoder().encode(tail) {
            UserDefaults.standard.set(data, forKey: Self.pendingTailKey)
        }
    }

    /// Drains the pending post-capture cascade, preserving the W1/W2 ordering invariant
    /// (history insert BEFORE the snapshot apply so the chart refresh includes the reading).
    /// Idempotent: complication-store dedup and the history store's sequence/epoch dedup make a
    /// double-replay harmless. Call sites: end of `handleSensorDidRead` (immediate attempt),
    /// `start()` (launch replay), `applyForegroundActiveEntry()`, and the top of the next
    /// `handleSensorDidRead` via `start()`'s ordering — the slot never holds more than one.
    private func drainPendingEGVTailIfAny() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingTailKey),
              let tail = try? JSONDecoder().decode(PendingEGVTail.self, from: data)
        else { return }

        let readingDate = Date(timeIntervalSince1970: TimeInterval(tail.readingEpoch))

        // History first (W1), so the chart rebuild inside applyG7DirectBleSnapshot sees it (W2).
        WatchGlucoseHistoryStore.shared.insert(
            StoredGlucoseReading(
                epochSeconds: tail.readingEpoch,
                glucoseMgDl: tail.glucoseMgDl,
                sequence: tail.sequence,
                source: "ble"
            )
        )

        let snapshot = TrioComplicationSnapshot(
            // C-210-1: bake the unit-correct display string (mmol users were seeing raw mg/dL).
            glucose: WatchGlucoseColorComputer.shared.displayString(forMgDl: tail.glucoseMgDl),
            trend: tail.trend,
            delta: tail.delta,
            readingDate: readingDate,
            date: Date(),
            state: nil,
            glucoseColor: WatchGlucoseColorComputer.shared.bubbleColorHex(for: tail.glucoseMgDl), // W5
            source: .g7DirectBLE,
            sequence: tail.sequence
        )

        TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)
        WatchState.shared.applyG7DirectBleSnapshot(snapshot, glucoseMgDl: tail.glucoseMgDl)
        WatchState.shared.bleLastEGVDate = readingDate
        WatchState.shared.bleLastEGVValue = tail.glucoseMgDl

        // Clear AFTER the cascade so a mid-tail death replays on the next wake (idempotent).
        UserDefaults.standard.removeObject(forKey: Self.pendingTailKey)
    }

    private func handleSensorDidReadBackfill(backfill: [G7BackfillMessage]) {
        for msg in backfill {
            log(
                "backfill_entry",
                "timestamp=\(msg.timestamp) glucose=\(msg.glucose.map(String.init) ?? "nil") algorithm_state=\(msg.algorithmState.rawValue) display_only=\(msg.glucoseIsDisplayOnly) trend=\(msg.trend.map { String(format: "%.1f", $0) } ?? "nil")"
            )
        }

        // TRIO-029: persist to the history store — HISTORY ONLY.
        //
        // Deliberately does NOT touch the complication store, the WatchState snapshot, or
        // bleLastEGVDate/Value. Backfill entries are historical by definition and must never be
        // promoted to the currently-displayed reading; the live EGV path owns those. The accepted
        // trade-off is that a reading recovered only via backfill refreshes the chart but not the
        // displayed value.

        // Reading times use the same anchor as the EGV path: the session activation date plus the
        // message's glucose-relative timestamp (`G7BackfillMessage.timestamp` is on the same basis
        // as `G7GlucoseMessage.glucoseTimestamp`). Backfill can arrive before any live reading in a
        // fresh process; without the anchor the timestamps cannot be placed, so skip the batch.
        guard let activation = sessionActivationDate else {
            log("backfill_persist_skipped", "reason=no_activation_anchor count=\(backfill.count)")
            return
        }

        var toStore: [StoredGlucoseReading] = []
        var skipped = 0

        for msg in backfill {
            // Reliability gate — mirrors the phone-side manager's backfill filter.
            guard msg.hasReliableGlucose else {
                log("backfill_entry_skipped", "reason=unreliable_state timestamp=\(msg.timestamp) algorithm_state=\(msg.algorithmState.rawValue)")
                skipped += 1
                continue
            }
            guard let glucoseValue = msg.glucose else {
                log("backfill_entry_skipped", "reason=missing_glucose_value timestamp=\(msg.timestamp) algorithm_state=\(msg.algorithmState.rawValue)")
                skipped += 1
                continue
            }

            // Store the raw Int value unmodified. The history store's logging canary
            // diagnoses implausible readings rather than rewriting them, and the live EGV
            // path in this file likewise stores raw values.
            let rawValue = Int(glucoseValue)

            let readingDate = activation.addingTimeInterval(TimeInterval(msg.timestamp))

            toStore.append(StoredGlucoseReading(
                epochSeconds: Int(readingDate.timeIntervalSince1970),
                glucoseMgDl: rawValue,
                // nil, NOT 0. `sequencesMatch` treats a nil on either side as a match, so a
                // backfilled record dedups against the live EGV holding the same timestamp. A
                // literal 0 would compare unequal to the real sequence and store a duplicate.
                sequence: nil,
                source: "backfill"
            ))
        }

        // Dedup, prune and persist are the store's job. "backfill" falls through `priority` to 0,
        // below "hk"/"wc"/"ble", so a live reading for the same timestamp always wins the merge.
        if !toStore.isEmpty {
            WatchGlucoseHistoryStore.shared.insert(toStore)
            // The loader takes the store's serial queue synchronously while the insert is
            // asynchronous on that same queue, so the reload is ordered after the insert and
            // observes the new entries. Refresh only the chart array — not the current glucose
            // value or the last-watch-state-update timestamp (those are owned by the live
            // snapshot paths).
            WatchState.shared.glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
                colorComputer: WatchGlucoseColorComputer.shared
            )
        }

        // toStore.count is the candidate count (entries that passed the reliability/value gates
        // before the store's async merge); the store emits its own insert telemetry carrying the
        // true appended figure.
        log("backfill_persist_summary", "arrived=\(backfill.count) candidate=\(toStore.count) skipped=\(skipped)")
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension G7WatchSensorAdapter: WKExtendedRuntimeSessionDelegate {
    /// D9: human-readable name for the invalidation reason. `reason.rawValue` alone is uninformative
    /// (it logged `-1` in practice); the real signal is the reason case plus the discarded NSError.
    private func describeReason(_ r: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch r {
        case .none: return "none(0)"
        case .sessionInProgress: return "sessionInProgress(1)"
        case .expired: return "expired(2)"
        case .resignedFrontmost: return "resignedFrontmost(3)"
        case .suppressedBySystem: return "suppressedBySystem(4)"
        @unknown default: return "unknown(\(r.rawValue))"
        }
    }

    /// DS1: human-readable `WKExtendedRuntimeSessionState`. `String(describing:)` on the imported
    /// NS_ENUM prints the opaque `WKExtendedRuntimeSessionState(rawValue: N)`, so the debug row and
    /// heartbeat showed e.g. `rawValue: 2` instead of `running`. Raw values per the watchOS SDK header:
    /// notStarted=0, scheduled=1, running=2, invalid=3.
    private func describeState(_ s: WKExtendedRuntimeSessionState) -> String {
        switch s {
        case .notStarted: return "notStarted"
        case .scheduled: return "scheduled"
        case .running: return "running"
        case .invalid: return "invalid"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    /// D9: surfaces the discarded `NSError` (domain/code/description) behind a session denial.
    private func describeError(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "nil" }
        let desc = e.localizedDescription.replacingOccurrences(of: " ", with: "_")
        return "domain=\(e.domain) code=\(e.code) desc=\(desc)"
    }

    /// D1: chaining removed. Apple only grants a `WKExtendedRuntimeSession` while the app is
    /// frontmost, so renewing from `willExpire` (background) was always denied (100% in telemetry).
    /// Just note the expiry and let the session end; a new one is started on the next foreground
    /// entry via `renewSessionIfNeeded`. The held reference is cleared in `didInvalidate` (D2).
    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        // C-212-5 v2 #4: only the *current* live session expiring flips the flag; a late willExpire on an
        // old (re-anchored) session must not clear it while the replacement is running or mid-swap.
        if session === extendedSession { lastKnownExtSessionActive = false }
        log("ext_session_will_expire")
    }

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        // C-215: reject a late didStart we no longer expect when a DIFFERENT session is already live and
        // running. The pending-watchdog (line ~421) clears the pending slot WITHOUT invalidating an
        // orphaned start, so without this guard that orphan's late didStart would clobber a newer live
        // session. Tear the orphan down (mark intentional so its didInvalidate is classified clean).
        // Mirrors the ownership guard in extendedRuntimeSession(_:didInvalidateWith:).
        let isExpected = session === sessionPendingDidStart
            || session === pendingReanchorSession
            || session === extendedSession
            || extendedSession == nil
        if !isExpected, let live = extendedSession, live !== session, live.state == .running {
            invalidatingSessionIDs.insert(ObjectIdentifier(session))
            session.invalidate()
            log("ext_session_unowned_did_start", "state=\(describeState(session.state)) live_state=\(describeState(live.state))")
            return
        }
        // Defensive cleanup: a started session should not be in the intentional-invalidation set,
        // but if it somehow is, remove it so the set stays bounded.
        invalidatingSessionIDs.remove(ObjectIdentifier(session))
        lastKnownExtSessionActive = true
        sessionInvalidatedAt = nil
        sessionNearExpiryLogged = false
        extendedSession = session
        let now = Date()
        sessionStartedAt = now
        persistSessionStart(now) // C-212-5 v2 true-age clock (§8.7)
        // C-212-5 v2: attribute the inline re-anchor's replacement by object identity.
        if session === pendingReanchorSession {
            let sid = reanchorSid ?? "?"
            if reanchorDidRetry {
                log("reanchor_retry_succeeded", "delay_ms=\(reanchorArmDelayMs) sid=\(sid)")
            } else {
                log("reanchor_replacement_started", "delay_ms=\(reanchorArmDelayMs) sid=\(sid)")
            }
            armAConsecFailures = 0 // any success resets the breaker
            pendingReanchorSession = nil
            clearReanchorContext()
        }
        if session === sessionPendingDidStart {
            sessionPendingDidStart = nil
        }
        log("ext_session_started")
        consumeDeferredScanIfNeeded() // C1: a confirmed .running session is a runtime-eligible transition
    }

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let id = ObjectIdentifier(session)
        let detail = "reason=\(reason.rawValue) reason_name=\(describeReason(reason)) error=\(describeError(error))"
        // C-208-3 (3.2): never act on sessions we don't currently own. A superseded session's
        // late/duplicate callback previously fell through to the error branch; post-C-208-1 the
        // blast radius is only state/log noise, but the guard is correct hygiene and insurance
        // against any future reintroduction of action in this handler. Ownership is computed
        // BEFORE the reference clear below.
        let isCurrentSession = session === extendedSession
        let isPendingSession = session === sessionPendingDidStart
        if !isCurrentSession, !isPendingSession, !invalidatingSessionIDs.contains(id) {
            log("ext_session_unowned_invalidation", detail)
            return
        }
        // D2: a session that invalidates is no longer the live session — clear the held reference so
        // the debug UI reflects reality instead of pinning to a stale `invalid` object.
        if isCurrentSession { extendedSession = nil; sessionStartedAt = nil; clearPersistedSessionStart() } // C-212-5 v2

        // C-212-5 v2: the inline re-anchor's replacement session, attributed by object identity.
        if session === pendingReanchorSession {
            let sid = reanchorSid ?? "?"
            let delayMs = reanchorArmDelayMs
            if isPendingSession { sessionPendingDidStart = nil }
            pendingReanchorSession = nil
            if reason == .sessionInProgress, !reanchorDidRetry {
                // Overlap: the daemon hadn't finished tearing down the old session. Retry start() once
                // ~200ms later (the old session is gone by then). The first-attempt signal stays distinct.
                reanchorDidRetry = true
                log("reanchor_replacement_rejected", "\(detail) delay_ms=\(delayMs) sid=\(sid)")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self else { return }
                    guard self.reanchorSid == sid, self.reanchorDidRetry else { return } // #4: stale retry guard
                    guard self.lastKnownScenePhase == "active" else {
                        self.lastKnownExtSessionActive = false
                        self.sessionInvalidatedAt = Date()
                        self.log("reanchor_abandoned", "reason=left_active phase=retry delay_ms=\(delayMs) sid=\(sid)")
                        self.recordReanchorFailure(delayMs: delayMs)
                        self.clearReanchorContext()
                        self.recoverSessionAfterFailedReanchor()
                        return
                    }
                    let s2 = WKExtendedRuntimeSession()
                    s2.delegate = self
                    self.pendingReanchorSession = s2
                    self.sessionPendingDidStart = s2
                    s2.start()
                    self.log("reanchor_retry", "delay_ms=\(delayMs) sid=\(sid)")
                    self.startReanchorPendingWatchdog(s2, sid: sid, delayMs: delayMs)
                }
            } else {
                // Retry also rejected, or a non-overlap invalidation of the replacement → a real gap.
                lastKnownExtSessionActive = false
                sessionInvalidatedAt = Date()
                log(reason == .sessionInProgress ? "reanchor_retry_rejected" : "reanchor_replacement_invalidated",
                    "\(detail) delay_ms=\(delayMs) sid=\(sid)")
                recordReanchorFailure(delayMs: delayMs)
                clearReanchorContext()
                recoverSessionAfterFailedReanchor()
            }
            return
        }

        if invalidatingSessionIDs.contains(id) {
            invalidatingSessionIDs.remove(id)
            // C-212-5 v2 (#7): during an inline swap, don't flip the continuity flag on the OLD session's
            // teardown — the replacement's didStart sets it true (or its failure sets it false), keeping
            // the baseline ext_session_active metric clean across the swap window.
            if !reanchorSwapInFlight, extendedSession?.state != .running { lastKnownExtSessionActive = false } // C-212-5 v2 #1/#5: don't flip during a swap or when the replacement is already running
            if isPendingSession { sessionPendingDidStart = nil }
            log("ext_session_intentional_invalidation", detail)
            // C-212-5 v2: the replacement was already started INLINE (not here) — this is just the old
            // session's teardown confirmation; no restart on this path anymore.
            return
        }
        lastKnownExtSessionActive = false
        let hasError = (error != nil)
        log("ext_session_did_invalidate", "\(detail) scene_phase=\(lastKnownScenePhase)")

        // Foreground session that never reached didStart — do not tear down BLE.
        if session === sessionPendingDidStart {
            sessionPendingDidStart = nil
            log("ext_session_pending_start_invalidated", "\(detail) scene_phase=\(lastKnownScenePhase)")
            return
        }

        sessionInvalidatedAt = Date()

        if hasError {
            // Build 208: session invalidation no longer tears down BLE. The error branch
            // previously called stop() here — but that teardown was half-effective (the fork's
            // scanAfterDelay() auto-rescan resurrected scanning while the adapter's timers and
            // status stayed dead), its 5s foreground-gated recovery was skipped in 58 of 59
            // firings (builds 204–206 telemetry), and 73% of EGV captures arrive with no active
            // session at all (build 206) — the session is wakeup substrate, not the delivery
            // path. Session invalidation now means session cleanup only: the references were
            // cleared above, renewal happens on the next foreground entry via
            // renewSessionIfNeeded(), and BLE + timers run on (iPhone model).
            //
            // C-207-1's RBS distinction survives as telemetry labeling only. RunningBoard kills
            // the foreground-only session every time the app leaves the active scene, so a
            // background RBS error is routine, not a failure. Match on the NSError domain, not
            // reason.rawValue (lastKnownScenePhase is a String).
            let isBackgroundRBSAssertion = (error as NSError?)?.domain == "RBSAssertionErrorDomain"
                && lastKnownScenePhase != "active"
            if isBackgroundRBSAssertion {
                log("ext_session_bg_invalidation_ble_kept", detail)
            } else {
                log("ext_session_unexpected_invalidation", "triggering_teardown=false \(detail)")
            }
        } else {
            log("ext_session_natural_or_unknown_expiry", detail)
        }
    }
}
