# HapticBeacon — implementation plan v1.9

**Status:** Cut 1 + R2 + R3 + R4 + R5 review fixes implemented; awaiting build / on-device verification.
**Owner:** Watch app extension.
**Related code:** `Trio Watch App Extension/G7WatchSensorAdapter.swift`, `Trio Watch App Extension/Views/ComplicationDebugView.swift`, `Trio Watch App Extension/TrioWatchApp.swift`, `Trio Watch App Extension/WatchState.swift`.

## 1. Goal

A foreground/background haptic beacon for the watch app that:

1. **Pre-EGV ramp:** signals an upcoming expected reading 3 s before it arrives (3 quick buzzes of increasing intensity).
2. **Success:** signals a received EGV (two `.success` haptics, ~150 ms apart).
3. **Miss:** signals an expected EGV that did not arrive (one `.failure` haptic) after a small grace window.

Primary use cases:

- **Foreground (app active):** remind the user that an EGV is about to arrive without looking at the watch.
- **Background (Cut 2 spike):** discover whether `WKExtendedRuntimeSession.notifyUser(haptic:)` actually delivers haptics on a `.physicalTherapy` session with the screen asleep.

Out of scope for this plan: using haptic delivery as a proxy for measuring the watch app's BLE EGV success rate. Existing telemetry already covers that.

## 2. Constraints baked in (from investigation feedback)

These four constraints are non-negotiable for the implementation:

1. **Adapter exposes the live extended session via a `@MainActor` accessor; the beacon never caches.** Three replacement paths exist on the adapter (`stop()`, `renewSessionIfNeeded()`, and the chain inside `extendedRuntimeSessionWillExpire`), so any cached `WKExtendedRuntimeSession` reference can go stale silently. The beacon must re-query the accessor on every `play(_:)` call.
2. **Timer/main-actor split mirrors the adapter.** Use a private serial `DispatchQueue` (`.utility`) for `DispatchSourceTimer` scheduling; jump back to `@MainActor` via `Task { @MainActor in … }` before reading state, calling the accessor, or invoking `WKInterfaceDevice.current().play(_:)`.
3. **BLE-only is the first-class case.** `WatchState.shared.bleLastEGVDate` is set only on the BLE path (`G7WatchSensorAdapter.swift:612`). Phone-relayed (`WatchState.swift` `saveComplicationSnapshot`) and HealthKit (`WatchState.swift` `applyHKSnapshot`) paths do **not** maintain it. Cut 1 only hooks BLE. Cut 3 adds explicit hooks for the other paths and is gated on Cut 2 outcome.
4. **Cut 2 is a spike with a binary pass/fail criterion.** `notifyUser(haptic:)` is unvalidated in this codebase (zero call sites). Treat background haptic delivery as an unknown until the spike measures it.

## 3. Architecture

### 3.1 New type

`Trio Watch App Extension/HapticBeacon.swift` — `@MainActor final class HapticBeacon` singleton.

Properties:
- `static let shared = HapticBeacon()`.
- `var isEnabled: Bool` — computed read of `UserDefaults.standard.bool(forKey: "HapticBeacon.isEnabled")`. **Default OFF (opt-in)** — confirmed by user. Single mutation site is `setEnabled(_:)`.
- `private let timerQueue: DispatchQueue` — label `org.nightscout.trio.watch.haptic.timers`, qos `.utility`. Mirrors the adapter's `timerQueue` pattern.
- `private var rampTimer: DispatchSourceTimer?` — fires once at `lastReceiptAt + (expectedCadence - rampLeadTime)` and triggers the three sub-step plays.
- `private var rampTimerID: UUID?` — **R4 fix (ChatGPT blocker):** identity token paired with `rampTimer`. The fire wrapper checks `rampTimerID == id` (not `rampTimer != nil`) so a stale handler raced by a fresh schedule (cancel + reschedule between handler invocation and Task execution) returns without touching the new timer's state.
- `private var rampSubTimers: [UUID: DispatchSourceTimer] = [:]` — **R3 fix (ChatGPT #1):** UUID-keyed dictionary so each sub-timer can remove itself when it fires. After all three fire, the dictionary is empty and `cancelAllTimers()`'s `!isEmpty` check honestly means "mid-ramp cancellation"; `count` at cancellation time gives the exact `pending_count` for telemetry (R3 fix, GPT #6).
- `private var missTimer: DispatchSourceTimer?` — fires at `lastReceiptAt + (expectedCadence + missGracePeriod)`.
- `private var missTimerID: UUID?` — **R4 fix.** See `rampTimerID`.
- `private var successTimer: DispatchSourceTimer?` — **R2 fix (Claude #2 / GPT #1+#2):** paired second-success buzz tracked so `cancelAllTimers()` can suppress it within the 150 ms window.
- `private var successTimerID: UUID?` — **R4 fix.** See `rampTimerID`. Tightens an already narrow race window (150 ms).
- `private var lastReceiptAt: Date?` — receipt time (`Date()` at hook), not sensor `readingDate`. **Confirmed by user.**

Constants:
- `expectedCadence: TimeInterval = 300` — 5 min G7 cadence (matches `ComplicationDebugView.expectedReadingCadence`).
- `rampLeadTime: TimeInterval = 3`.
- `missGracePeriod: TimeInterval = 20`.
- `staleThreshold: TimeInterval = 600` — do not rearm if **gap between consecutive receipts** > 10 min (R2 fix, Claude #1; not the freshness of the current receipt).
- `successInterBuzzInterval: TimeInterval = 0.150`.
- `timerLeeway: DispatchTimeInterval = .milliseconds(500)` — governs `DispatchSourceTimer` fire jitter, **not** anchor accuracy (R3 fix, GPT #3).

Public API (all `@MainActor`):
- `func start()` — install observers / wire-up; called once from `TrioWatchApp` on launch and on every `.active` scene phase transition. Idempotent. Cut 1 just logs `event=start is_enabled=<bool>`; future cuts may add observer registration here.
- `func stop()` — cancel pending timers; clear `lastReceiptAt`; emit `event=stop`. Idempotent. Currently uncalled from production code paths (BLE keeps running across scene-phase transitions per §3.3).
- `func setEnabled(_ enabled: Bool)` — flip persisted flag and react. **Disabling** cancels in-flight timers, **clears `lastReceiptAt = nil`** (R5 fix — without this, a re-enable hours/days later would emit a confusing `rearm_skipped reason=stale_gap` on the recovery EGV, since the new EGV would be compared against a stale prior anchor), and emits `event=setEnabled enabled=false action=cancelled_pending_timers`. **Enabling** emits `event=setEnabled enabled=true`, then attempts a **warm-arm** (R2 fix, GPT medium): if `WatchState.shared.bleLastEGVDate` is non-nil and < `expectedCadence + missGracePeriod` (320 s, R4 fix loosen from 300 s for partial-warm-arm reachability), synthesize a cadence anchor and call `rearm(after:)`. R4-2 push of the past-deadline check inside `rearm()` makes warm-arm in the 297–319 s window schedule only the still-future miss timer (with `rearm_skipped reason=deadline_passed phase=ramp` log). The success buzz is intentionally suppressed on warm-arm — no live EGV is arriving at toggle time. **Each silent early-return in the warm-arm path now emits a distinct `warm_arm_skipped reason=<…>` line** (R5 fix — analysts couldn't previously distinguish "no warm-arm because adapter stopped" from "no warm-arm because no anchor" from "warm-arm logic never ran"): `reason=adapter_stopped` (adapter `isStopped`), `reason=no_anchor` (`bleLastEGVDate` nil or `.distantPast`), `reason=anchor_in_future` (negative age — clock skew), `reason=cycle_already_expired` (age ≥ 320 s, the existing pre-R5 case).
- `func noteEGVReceived(at receiptDate: Date, source: TrioComplicationDataSource)` — single hook the rest of the codebase calls. Filters by source (Cut 1: BLE only; Cut 3 will add `sourceFilter`). Captures the prior `lastReceiptAt` for the stale-gap guard (R2 fix), cancels pending timers, updates `lastReceiptAt`, fires the success pair, then `rearm(after: receiptDate)` — *unless* the gap from the prior receipt exceeds `staleThreshold` (R2 fix), in which case emits `event=rearm_skipped reason=stale_gap gap_s=<n>` and waits for the next EGV to re-establish cadence.

Internal:
- `private func rearm(after receiptDate: Date)` — **schedule-only** (R2 fix) with **per-deadline past-skip** (R4-2 fix). Computes `rampAt = receiptDate + (expectedCadence - rampLeadTime)` and `missAt = receiptDate + (expectedCadence + missGracePeriod)`. For each, if the deadline is in the future, schedule and emit `haptic_armed phase=ramp|miss expected_at=<epoch>`. If the deadline has passed (warm-arm with stale anchor; never happens for live EGVs at age=0), emit `rearm_skipped reason=deadline_passed phase=ramp|miss anchor_age_s=<n>` and skip that timer. Cancellation of pending timers happens in callers (`noteEGVReceived`, `setEnabled`), not here.
- `private func fireRamp()` — **R4-3 (ChatGPT #3):** defensive `cancel + removeAll` of any existing `rampSubTimers` entries before assigning a new dictionary (load-bearing protection lives in R4-1's identity-token guard on `rampFired(id:)`, but the explicit cleanup makes the invariant obvious). Then schedules three UUID-keyed sub-timers on `timerQueue` (R3 fix, ChatGPT #1) at deadlines `.now() + 0`, `+1`, `+2`. Each handler routes through `rampSubTimerFired(id:type:label:)` which guards on `rampSubTimers[id] != nil`, removes the entry, then calls `play(_:label:)`. Self-removal on fire means `rampSubTimers.isEmpty` after a successful ramp; `cancelAllTimers()` only sees genuinely-pending sub-timers.
- `private func rampFired(id: UUID)` / `missFired(id: UUID)` / `playSecondSuccessBuzz(id: UUID)` — **R4-1 (ChatGPT blocker):** identity-token wrappers (replacing the R3 `slot != nil` guards). Each checks `xxxTimerID == id` before nilling both `<slot>` and `<slot>ID` and calling the inner action. The R3 guard closed the cancel-only race; the identity check additionally closes the cancel-and-reschedule race where a stale handler can find a *new* timer in the slot from a fresh `noteEGVReceived` cycle. With the identity check, the stale handler returns without touching the new timer's state.
- `private func rampSubTimerFired(id: UUID, type: WKHapticType, label: String)` — sub-timer wrapper from R3-2. Guards on `rampSubTimers[id] != nil`, removes the entry, then calls `play(_:label:)`. Race-safe by construction (each entry has its own UUID key).
- `private func fireSuccess()` — `.success`, then schedules a `successTimer` for `+successInterBuzzInterval` (150 ms). Captures a fresh UUID into `successTimerID` (R4-1) and routes the handler through `playSecondSuccessBuzz(id:)`.
- `private func fireMiss()` — `.retry` once. (Was `.failure`; reserved for future clinical alerts. See §11.)
- `private func play(_ type: WKHapticType, label: String)` — Cut 1: `WKInterfaceDevice.current().play(type)` only. Cut 2: switch to the dual-path described in §5. **Single choke point intentionally** — when a clinical alerter is added later, both classes route through this method (or an extracted `HapticDispatcher`) so priority, isEnabled checks, extended-session routing, and telemetry live in one place. Do not grow this method with beacon-specific logic that would block extraction. Gates on `isEnabled` and `isAdapterStopped()`; emits `haptic_skipped` for either suppression.
- `private func cancelAllTimers()` — cancels and nils each slot **and** its paired identity token (R4-1) so the next stale handler that runs sees `xxxTimerID == oldID` is false. Emits `haptic_cancelled phase=ramp|ramp_sub|miss` only for slots that were *truly pending* (R2 + R3 fix). For `phase=ramp_sub`, includes a `pending_count=N` field (R3 fix, ChatGPT #6) derived from the dictionary count. The success second-buzz slot is cancelled silently (paired companion; not interesting telemetry).
- `private func isAdapterStopped()` — reads `G7WatchSensorAdapter.shared.isIntentionallyStopped` (R2 fix, GPT #3). The accessor mirrors the adapter's authoritative `isStopped` flag, immune to the cold-start race in the published `g7DirectBleStatus` mirror.
- `private func log(_ event: String, _ fields: String = "")` — wraps `WatchLogger.shared.log` with `module=haptic_beacon` prefix to match adapter conventions.

### 3.2 Adapter changes (Cut 1)

Two surgical changes in `Trio Watch App Extension/G7WatchSensorAdapter.swift`:

**Change A — accessor for the beacon.** Add near line 23 (where `extendedSession` is declared):

> A new `@MainActor` computed property `currentExtendedSession: WKExtendedRuntimeSession?` that returns `extendedSession`. Internal access level is sufficient (singletons are in the same module). No setter. No caching by callers.

**Change B — beacon hook on EGV.** Inside the existing `Task { @MainActor in }` block at lines 609–615 of `sensor(_:didRead glucose:)`, append a single call:

> `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)`

Notes:
- Pass `Date()` (receipt time), not `readingDate` (sensor's reading-time, derived from `glucose.glucoseTimestamp`). The cadence anchor for "when does the next EGV arrive at the watch" is receipt time. **Confirmed by user.**
- Place the call **after** the existing three `WatchState.shared.*` writes so beacon never sees inconsistent state if the user adds future hooks that read those.

### 3.3 App lifecycle wire-up

`Trio Watch App Extension/TrioWatchApp.swift` already has `.onChange(of: scenePhase)` (lines 21–38) with a `newPhase == .active` branch.

**Change:** Add `HapticBeacon.shared.start()` to the `.active` branch alongside the existing `WatchState.shared.handleForegroundActiveEntry()` call. Do **not** call `stop()` on inactive/background — direct BLE keeps running per existing watch lifecycle policy, so the beacon should stay armed too. `start()` is idempotent.

(Optional in Cut 1, deferrable: also call once from `init()` so a cold launch with the watch face becoming active in the same tick still arms the beacon.)

### 3.4 Debug UI

`Trio Watch App Extension/Views/ComplicationDebugView.swift` — add a new button to the ACTIONS section (just below "Flush Logs"):

- Label: "Haptic Beacon: ON" when enabled, "Haptic Beacon: OFF" otherwise.
- Tap calls `HapticBeacon.shared.setEnabled(!HapticBeacon.shared.isEnabled)`.
- Use `.bordered` button style with `.tint(.pink)` (visually distinct from existing blue/orange/purple buttons).
- Show a one-shot confirmation toast via the existing `triggerConfirmation(message:)` helper. (Verified at `Trio Watch App Extension/Views/ComplicationDebugView.swift:427` — already used by Force Reload, Request Data, and Flush Logs buttons.)

No countdown row or status row in Cut 1 — keep the diagnostic surface minimal until the mechanism is validated.

## 4. Telemetry

All lines emit via `WatchLogger.shared.log(_:)` with the prefix `module=haptic_beacon event=<name>`. The surface area below is the **operational contract** for Cut 1 + R2; goal is to confirm the beacon itself is firing as designed and explain every suppression / cancellation, **not** to track BLE success rate.

### 4.1 Predictive lifecycle (the core two)

```
event=haptic_armed phase=ramp|miss expected_at=<unix_epoch> source=ble
event=haptic_fired type=ramp_click|ramp_start|ramp_notif|success|retry delivered_via=device
```

In Cut 2, `delivered_via` becomes `device|extended_session` and a `reason_no_session` field is added when falling back to device.

### 4.2 Cancellation telemetry (R2 fix, Claude #3; R3 fix, ChatGPT #6)

```
event=haptic_cancelled phase=ramp source=ble
event=haptic_cancelled phase=ramp_sub pending_count=<int> source=ble
event=haptic_cancelled phase=miss source=ble
```

Emitted by `cancelAllTimers()` only for slots that are *truly pending* (post null-on-fire). `phase=ramp_sub` indicates a mid-ramp cancellation (at least one of the three ramp sub-haptics had not yet played); `pending_count` reports the exact count (1, 2, or 3) of sub-haptics that were cancelled — derived from the UUID-keyed `rampSubTimers` dictionary at cancellation time (R3 fix, ChatGPT #6). The success second-buzz slot is cancelled silently — it's a paired companion, not a predicted haptic, and an unfired second of a pair is not interesting telemetry.

### 4.3 Lifecycle and toggle audit

```
event=start is_enabled=<bool>
event=stop
event=setEnabled enabled=<bool> [action=cancelled_pending_timers]
event=warm_armed anchor_age_s=<int>
```

`warm_armed` is emitted (R2 fix, GPT medium) when `setEnabled(true)` finds a recent `WatchState.shared.bleLastEGVDate` (< `expectedCadence + missGracePeriod` = 320 s, R4-3 fix loosen from 300 s) and synthesizes a cadence anchor without waiting for the next live EGV. The success buzz is intentionally suppressed in this path — only ramp / miss are scheduled. **In the 297–319 s window, only the still-future miss is scheduled** (R4-2): `warm_armed` will be paired with a `rearm_skipped reason=deadline_passed phase=ramp` event, then a single `haptic_armed phase=miss`.

### 4.4 Suppression / skip reasons

```
event=haptic_skipped reason=adapter_stopped phase=success source=<src>           # noteEGVReceived skip
event=haptic_skipped reason=adapter_stopped type=<label>                          # play(_:) skip
event=rearm_skipped reason=stale_gap gap_s=<int>                                  # R2 fix (Claude #1)
event=rearm_skipped reason=deadline_passed phase=ramp|miss anchor_age_s=<int>     # R4-2 fix (GPT #1)
event=warm_arm_skipped reason=adapter_stopped                                     # R5 fix (silent guard → log)
event=warm_arm_skipped reason=no_anchor                                           # R5 fix (silent guard → log)
event=warm_arm_skipped reason=anchor_in_future anchor_age_s=<int>                 # R5 fix (silent guard → log)
event=warm_arm_skipped reason=cycle_already_expired anchor_age_s=<int>            # R3 fix (GPT #2), R4-3 threshold loosen
```

- `haptic_skipped reason=adapter_stopped`: gated by `G7WatchSensorAdapter.shared.isIntentionallyStopped` (R2 fix, GPT #3). At `noteEGVReceived` entry the skip carries `phase=success source=<src>`; at `play(_:)` time the skip carries `type=<label>`.
- `rearm_skipped reason=stale_gap` (was `reason=stale_receipt` in v1.5; renamed because the v1.5 implementation never actually fired): emitted when the gap between the previous and current receipt exceeds `staleThreshold` (600 s). The success buzz still fires (confirms recovery), but no ramp/miss is scheduled — the cadence is unreliable until it re-stabilizes, and the next EGV will rearm normally. **R5 note:** because R5 also clears `lastReceiptAt` on `setEnabled(false)`, this event no longer fires on the first live EGV after a long disable period (which previously produced a correct-but-confusing `stale_gap` log on what was actually a normal recovery).
- `rearm_skipped reason=deadline_passed` (R4-2 fix, GPT #1): emitted **per deadline** when `rearm()` finds that `rampAt <= now` or `missAt <= now`. Carries `phase=ramp|miss` and `anchor_age_s`. For the live-EGV path (age=0) this never fires; for the warm-arm path with stale anchor (age 297–319 s) `phase=ramp` fires while `phase=miss` is still scheduled normally; for warm-arm at age ≥ 320 s the upstream `warm_arm_skipped` gate fires and `rearm()` is never reached. Different `reason` and field shape from `stale_gap` (`anchor_age_s` vs `gap_s`).
- `warm_arm_skipped reason=adapter_stopped|no_anchor|anchor_in_future|cycle_already_expired` — emitted from `setEnabled(true)` whenever the warm-arm guard chain rejects the toggle. Each silent early-return that pre-R5 produced no log now emits one of these distinct reasons:
  - `reason=adapter_stopped` (R5): adapter's `isIntentionallyStopped` returned true at toggle time; warm-arm and live arming both deferred until the next non-stopped state. No `anchor_age_s` field.
  - `reason=no_anchor` (R5): `WatchState.shared.bleLastEGVDate` is nil or `.distantPast`. Cold-launch case before any BLE EGV has been received. No `anchor_age_s` field. The next live EGV will arm normally via `noteEGVReceived`.
  - `reason=anchor_in_future` (R5): `Date().timeIntervalSince(bleLastEGV) < 0`. Clock skew between watch and sensor (or wall-clock movement). Carries `anchor_age_s` (will be negative). Rare; analysts seeing this should investigate clock state.
  - `reason=cycle_already_expired` (R3 fix, GPT #2; R4-3 threshold loosen to 320 s): the BLE anchor is older than `expectedCadence + missGracePeriod` (320 s). The next live EGV will rearm normally; warm-arming a fully-expired cycle would replay an immediate ramp burst plus immediate miss, which is bad UX.

### 4.5 Telemetry analysis methodology (R3 fix, GPT #5 — split miss vs ramp)

Critical for analyzing whether haptics are actually being delivered. The miss cycle has a clean 1:1 armed-to-fired mapping; the ramp cycle has a 1:N mapping (one armed, up to three fired sub-events). Treat them separately.

#### 4.5.1 Miss-cycle accounting (1:1)

```
count(haptic_armed phase=miss)
  ≈ count(haptic_cancelled phase=miss)
  + count(haptic_fired type=retry)
  + count(haptic_skipped reason=adapter_stopped type=retry)
  + (residue: in-flight at query time)
```

In steady state, almost every armed miss is cancelled by the next EGV (which arrives within the grace window). `haptic_fired type=retry` is the actual missed-EGV count — do **not** use `haptic_armed phase=miss` as a proxy for misses.

#### 4.5.2 Ramp-cycle accounting (1:N)

One `haptic_armed phase=ramp` triggers `rampFired`, which calls `fireRamp`, which schedules three sub-timers. So:

```
count(haptic_armed phase=ramp)
  ≈ count(haptic_cancelled phase=ramp)         # cancelled before rampFired ran
  + count(haptic_fired type=ramp_click)         # rampFired ran — .click is the canonical "ramp triggered" indicator
  + count(haptic_skipped reason=adapter_stopped type=ramp_click)
  + race-residue (small; see §4.5.4)
```

Within ramps that triggered:

```
count(haptic_fired type=ramp_click)
  ≈ count(haptic_fired type=ramp_start) + count(haptic_cancelled phase=ramp_sub | pending_count >= 2)
count(haptic_fired type=ramp_start)
  ≈ count(haptic_fired type=ramp_notif) + count(haptic_cancelled phase=ramp_sub | pending_count == 1)
```

Or more simply, the total sub-haptics that didn't fire because of mid-ramp cancellation is `sum(haptic_cancelled phase=ramp_sub | pending_count)`.

#### 4.5.3 Operational queries

- **Did a haptic fire?** `count(haptic_fired group by type)`. Source of truth.
- **Why was a haptic suppressed?** `count(haptic_skipped group by reason)`.
- **Did the user disable the beacon?** `count(setEnabled enabled=false)`.
- **Did the beacon fail to rearm after a long outage?** `count(rearm_skipped reason=stale_gap)`.
- **Did warm-arm trigger or skip?** `count(warm_armed)` vs `count(warm_arm_skipped group by reason)` — the `reason` breakdown distinguishes the four R5-distinguished cases (`adapter_stopped`, `no_anchor`, `anchor_in_future`, `cycle_already_expired`).

#### 4.5.4 Race-residue caveat (R3 fix, Claude)

In rare cases, `haptic_cancelled phase=ramp` (or `phase=miss`) may log without a corresponding "actual cancellation": the timer's event handler ran on `timerQueue` and dispatched a `Task @MainActor`, then `cancelAllTimers()` ran on `@MainActor` *before* that Task executed. The cancellation log fires (slot was non-nil at log time), and the queued Task's `guard slot != nil else { return }` then suppresses the haptic. So *behavior* is correct (no spurious ramp/miss); *log* slightly over-counts cancellations. Race window is the dispatch latency (microseconds). Ignore single-digit residual counts during analysis.

### 4.6 Why the surface area expanded vs v1.5

v1.5 said "two log lines, no more." Implementation diverged for operational debuggability:
- Lifecycle visibility (`start`, `stop`) makes "is the beacon installed?" answerable from logs alone.
- Toggle audit (`setEnabled`) makes "did the user turn this off?" trivially queryable.
- Suppression reasons (`haptic_skipped`, `rearm_skipped`) explain every non-fire — without them, "the haptic didn't buzz" requires source-code inspection to debug.
- Cancellation telemetry (`haptic_cancelled`, R2 fix) makes the predictive lifecycle queries above mathematically sound.
- `warm_armed` (R2 fix) confirms the warm-arm path triggered.

All R2 events are bounded — at most one per state transition, never per-tick. Total event volume in steady state is ≈ 5 events per 5-min cadence cycle (one armed pair, one cancelled miss, one success pair fired).

## 5. Cut 2 — `notifyUser(haptic:)` spike

Treat as a separate, time-boxed validation step. Keeps the Cut 1 surface area stable while the unknown is measured.

### 5.1 Goal

Determine whether `WKExtendedRuntimeSession.notifyUser(haptic:)` delivers haptics on a `.physicalTherapy` session when:

- the watch face is asleep (wrist down), and
- the Trio app is not the foreground app.

`physical-therapy` is confirmed in `Trio Watch App/Info.plist:23–26`. The Swift initializer is parameterless (`WKExtendedRuntimeSession()`); `physicalTherapy` is a session **type** declared via Info.plist `WKBackgroundModes`, not a constructor argument.

### 5.2 Code change (only `play(_:)`)

(`G7WatchSensorAdapter.shared` verified at `Trio Watch App Extension/G7WatchSensorAdapter.swift:17` — `static let shared = G7WatchSensorAdapter()`. Singleton access is sound; the new `currentExtendedSession` accessor sits next to it.)

Replace the Cut 1 implementation with:

```
@MainActor
private func play(_ type: WKHapticType) {
    if let session = G7WatchSensorAdapter.shared.currentExtendedSession,
       session.state == .running {
        session.notifyUser(haptic: type)
        log("haptic_fired", "type=\(name(of: type)) delivered_via=extended_session session_state=\(session.state.rawValue)")
    } else {
        WKInterfaceDevice.current().play(type)
        let stateDesc = G7WatchSensorAdapter.shared.currentExtendedSession.map { "\($0.state.rawValue)" } ?? "nil"
        log("haptic_fired", "type=\(name(of: type)) delivered_via=device reason_no_session=\(stateDesc)")
    }
}
```

No other code changes. The accessor (Change A above) is the only surface the beacon needs.

### 5.3 Spike protocol

1. Enable HapticBeacon via debug toggle. Confirm one full success / ramp / miss cycle works in foreground (sanity check).
2. Lock the screen (or wait for it to dim) ≥ 30 s before next expected EGV.
3. Wait through the next expected reading window (5 min).
4. Note whether ramp / success / miss are felt at the wrist with screen off.
5. Repeat for **5 cycles** to capture variability.
6. After the run, query Better Stack for `event=haptic_fired` lines from the spike window and tally `delivered_via=extended_session` vs `delivered_via=device`, and cross-reference with subjective feel.

### 5.4 Pass / fail

| Result | Felt cycles (of 5) | Decision |
|---|---|---|
| **Pass** | ≥ 4 of 5 felt with screen off, telemetry confirms `delivered_via=extended_session` | Cut 2 is the keeper. Document `.physicalTherapy` works for haptics. Proceed to Cut 3. |
| **Partial** | 2–3 of 5 | Investigate `session.state` at fire time. Possibly add observer for session invalidation between arming and firing. Re-spike before Cut 3. |
| **Fail** | ≤ 1 of 5 | Document the limitation. Decide whether foreground-only is acceptable or whether to escalate to a different background mode (would require entitlement / Info.plist changes — explicit ask back to the user). Cut 3 deferred indefinitely. **Note (§11 implication):** a fail also means a future clinical alerter cannot rely on `notifyUser(haptic:)` for background delivery — it would need to route through `UNNotification` (likely with the `com.apple.developer.usernotifications.critical-alerts` entitlement). Cut 2 fail is therefore a wider product signal, not just a beacon limitation. |

## 6. Cut 3 — phone / HealthKit source coverage (gated on Cut 2 = pass)

Two new hooks, each one line:

- `WatchState.swift` end of `applyHKSnapshot(_:)` (currently line 990): 
  `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .healthKit)`
- `WatchState.swift` after the `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` call inside `saveComplicationSnapshot(...)` (currently around line 2079): 
  `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .watchConnectivity)`

Beacon API change:
- Add `var sourceFilter: SourceFilter = .ble` with cases `.ble`, `.all`. Persisted in `UserDefaults.standard` key `HapticBeacon.sourceFilter`.
- `noteEGVReceived` ignores non-BLE sources unless `.all` is selected.
- Add a second debug-view button: "Source: BLE only" / "Source: All" toggle.

Telemetry: `source=ble|hk|wc` on both `armed` and `fired` lines.

Why deferred:
- Phone- and HK-relayed readings can arrive late, batched, or out of cadence — they will produce false misses on the beacon. Validating the underlying BLE delivery mechanism first (Cut 2) is the prerequisite for deciding whether the noise is acceptable.
- Adding plumbing to two more code paths before Cut 2 confirms background haptics work would be wasted work if Cut 2 fails.

## 7. Risks and mitigations

1. **`session.state` lies after `extendedRuntimeSessionWillExpire` chain.** Apple's docs are vague on what `.running` means after the chain swap inside `extendedRuntimeSessionWillExpire(_:)` (`G7WatchSensorAdapter.swift:647–654`). Mitigation: log `session.state.rawValue` at fire time; reconcile against adapter telemetry (`event=ext_session_chain_started` etc.) during Cut 2 spike analysis.
2. **Timer drift on older hardware.** `DispatchSourceTimer` with `.seconds(2)` leeway is fine for 5-min cadence; if observed drift > 5 s, reduce leeway to `.seconds(1)` and accept the small battery cost. Do not switch to `Timer.scheduledTimer` (dies if the run loop blocks).
3. **Receipt-time vs sensor-time anchor.** `readingDate = activation.addingTimeInterval(TimeInterval(glucose.glucoseTimestamp))` is the sensor's idea of when the reading occurred; `Date()` at the hook is when the watch received it. The cadence anchor for "when does the next EGV arrive at the watch" is closer to receipt time, so the beacon uses `Date()`. (Resolved in §11 Q2.)
4. **Stop/start across worktree restart.** `start()` must be idempotent: if called twice (e.g. cold launch + first scene-active), the second call must not double-arm or duplicate timers. Implementation detail: gate on `lastReceiptAt == nil` for the cold-start path; rely on `noteEGVReceived` cancellation logic for hot-arm paths.
5. **`isEnabled` storage.** `UserDefaults.standard`, **not** the App Group. The complication target does not need to read this state; keeping it local to the watch extension avoids App Group write contention with `TrioComplicationDataStore`.

## 8. Project file membership

Per Trio AGENTS.md safety rule 6: do **not** edit `Trio.xcodeproj/project.pbxproj` or run `scripts/sync_project_files.rb`. Place the new file at `Trio Watch App Extension/HapticBeacon.swift`. The existing target glob in `scripts/sync_project_files_config.rb:15` (`"Trio Watch App Extension/**/*.{swift,m,mm}"`) already covers it; project membership refresh will happen via the canonical build/sync workflow.

## 9. Per-cut deliverables and validation

### Cut 1 (BLE-only foreground beacon)

Files added/modified:
- New: `Trio Watch App Extension/HapticBeacon.swift`
- Modified: `Trio Watch App Extension/G7WatchSensorAdapter.swift` (Change A: accessor; Change B: hook)
- Modified: `Trio Watch App Extension/TrioWatchApp.swift` (one line in `.active` branch)
- Modified: `Trio Watch App Extension/Views/ComplicationDebugView.swift` (toggle button)

Done criteria:
- [ ] Toggle in debug view persists across app relaunch (`UserDefaults`).
- [ ] When enabled and BLE EGV arrives in foreground: success buzz fires within 1 s.
- [ ] Ramp fires at `expected − 3 s`, `−2 s`, `−1 s` with three perceptibly different haptics.
- [ ] Miss fires at `expected + 20 s` if no EGV; cancelled by an EGV arriving in the grace window.
- [ ] No haptics when `isEnabled = false`.
- [ ] No timer leaks across stop / start cycles (verify by toggling off → on → off → on with EGVs in flight).
- [ ] `event=haptic_armed` and `event=haptic_fired` appear in Better Stack with the documented field shape.

### Cut 2 (background spike)

Files modified:
- `Trio Watch App Extension/HapticBeacon.swift` (replace `play(_:)` body only).

Done criteria:
- [ ] Spike protocol §5.3 executed for 5 cycles; results recorded in `docs/in-progress/haptic-beacon/haptic-beacon-cut2-spike.md`.
- [ ] Decision per §5.4 (pass / partial / fail) recorded with telemetry citations.

### Cut 3 (phone / HK coverage; gated on Cut 2 = pass)

Files modified:
- `Trio Watch App Extension/HapticBeacon.swift` (add `SourceFilter`, persist, second toggle button hook).
- `Trio Watch App Extension/WatchState.swift` (two one-line hooks).
- `Trio Watch App Extension/Views/ComplicationDebugView.swift` (second toggle button).

Done criteria:
- [ ] With `Source: BLE only` selected, behavior identical to Cut 1.
- [ ] With `Source: All` selected, beacon fires on phone-relayed and HK-relayed EGVs.
- [ ] False-miss rate on non-BLE sources documented (subjective + telemetry).

## 10. Future considerations: clinical alerts (out of scope, but design-affecting)

This beacon is a debug feature for cadence prediction. The user has flagged that the same haptic surface might later host **user-facing clinical alerts** (impending low, current high, etc.). Clinical alerts are **explicitly out of scope for v1.x** — they have entirely different requirements (value-driven triggers, snooze state, regulatory considerations, possibly critical-alerts entitlement). However, four design decisions are worth making now to avoid expensive refactors later:

### 10.1 Reserved haptic vocabulary

WatchKit ships nine haptic types and they are not all perceptually distinct. Burning the most intense ones on cadence diagnostics would leave clinical alerts with nothing strong enough to differentiate "urgent low" from "missed BLE reading". Reservation list:

| Type | Owner | Use |
|---|---|---|
| `.click` | HapticBeacon | Ramp T-3s |
| `.start` | HapticBeacon | Ramp T-2s |
| `.notification` | HapticBeacon | Ramp T-1s |
| `.success` | HapticBeacon | EGV arrival (×2) |
| `.retry` | HapticBeacon | Missed expected EGV |
| `.failure` | **Reserved** | Future: urgent low (most intense type) |
| `.directionUp` | **Reserved** | Future: high glucose alert |
| `.directionDown` | **Reserved** | Future: impending low alert |
| `.stop` | **Reserved** | Future: manual override / dismissal |

This is why §3.1 changes the miss haptic from `.failure` to `.retry` — `.retry` is intense and signals "investigate" without claiming "danger". When clinical alerts arrive, `.failure` will already be free.

### 10.2 Single `play(_:)` choke point

Already documented in §3.1. The point is structural: a future `ClinicalAlerter` (sibling type, value-driven) should route haptics through the same delivery path so priority, isEnabled gating, extended-session routing, and telemetry live in one place. Either keep beacon's `play(_:)` extractable into a shared `HapticDispatcher`, or have the clinical alerter call `HapticBeacon.shared.play(_:)` directly (and rename later if the responsibility split warrants). Either path requires no Cut 1 changes — just don't add beacon-specific assumptions inside `play(_:)`.

### 10.3 Critical alerts entitlement may be needed

Clinical alerts that need to fire while the watch is in silent mode / Do Not Disturb / Theater Mode require the `com.apple.developer.usernotifications.critical-alerts` entitlement (Apple-approved special-use entitlement). HapticBeacon does **not** need this — it should always honor user mute. But if Cut 2 fails and clinical alerts later need background delivery via `UNNotification`, the entitlement question becomes important. Out of scope to obtain now; flagged so future planning is not surprised.

### 10.4 Things that do NOT need to change now

- **Naming:** "HapticBeacon" specifically means cadence beacon; clinical alerts would be a separate type.
- **File location:** Flat in `Trio Watch App Extension/` matches existing convention. If the haptic surface grows past 2–3 related files, move them into a `Haptics/` subdirectory then.
- **Telemetry namespace:** `module=haptic_beacon` is appropriate for cadence beacon. Future `module=clinical_alerts` would coexist naturally; both can use `WatchLogger.shared.log(_:)`.
- **`UserDefaults` keys:** Flat namespace (`HapticBeacon.isEnabled`) — adding `ClinicalAlerts.isEnabled` etc. later requires zero migration.
- **Glucose value access:** Already in `WatchState.shared.currentGlucose / trend / delta`. No new plumbing needed for value-driven alerts.

## 11. Open questions

### Resolved

1. **Default `isEnabled` state:** OFF (opt-in). ✅ (v1.1)
2. **Receipt-time vs sensor-time anchor:** receipt-time (`Date()` at hook). ✅ (v1.1)
3. **Behavior when adapter is `isStopped`:** **Option A** — beacon checks `WatchState.shared.g7DirectBleStatus == .off` at `noteEGVReceived` and `play(_:)` time; cancels in-flight timers and logs `event=haptic_skipped reason=adapter_stopped`. Zero false buzzes after a stop event. No new accessor needed (status is already published via `publishConnectionStatus`). ✅ (v1.3)
4. **Telemetry destination:** `WatchLogger.shared.log(_:)`. ✅ (v1.1)

### Open

None — ready to implement Cut 1.

## Changelog

### v1.9 (2026-05-11 14:26 CET)
- **Cut 1 review round 5** (in-session red-team pass over the post-R4 surface). Three findings: one comment-cleanup followup miss in `G7WatchSensorAdapter.swift` (the two new haptic-beacon accessors still carried "Cut 2 spike" / "R2 fix, GPT #3" framing — the R4 comment-cleanup pass only touched `HapticBeacon.swift`); one minor semantic gap (`setEnabled(false)` left `lastReceiptAt` set, causing a correct-but-confusing `rearm_skipped reason=stale_gap` log on the first EGV after a long disable period); one telemetry hole (three silent `guard` returns in the `setEnabled(true)` warm-arm path produced no log, so analysts couldn't tell why warm-arm didn't run after `setEnabled enabled=true`). Full per-finding evaluation in [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"Cut 1 — review round 5".
  - **§3.1 method docs updated** for `setEnabled(_:)`: documents the new disable-clears-anchor invariant (R5) and the four `warm_arm_skipped` reasons (R5).
  - **§4.4 suppression reasons** now enumerates all four `warm_arm_skipped reason=…` values (`adapter_stopped`, `no_anchor`, `anchor_in_future`, `cycle_already_expired`) with field shapes. Added cross-reference under `rearm_skipped reason=stale_gap` noting that R5's disable-clears-anchor change suppresses spurious post-disable stale-gap logs.
  - **§4.5.3 operational queries** updated: warm-arm skip count is now broken down by `reason` group rather than just `cycle_already_expired`.
  - Code-side R5 changes: (a) audited and rewrote the two haptic-beacon-related comments in `Trio Watch App Extension/G7WatchSensorAdapter.swift` (`currentExtendedSession`, `isIntentionallyStopped`) to describe behavior/rationale from the code context only — no review-round/reviewer/process language, matching the R4 cleanup standard already applied to `HapticBeacon.swift`; (b) `setEnabled(false)` clears `lastReceiptAt = nil` to match `stop()` semantics; (c) three new `warm_arm_skipped reason=<…>` log lines, one per silent guard branch in `setEnabled(true)`. No new lint diagnostics; the two pre-existing SourceKit `No such module` false-positives are unchanged.

### v1.8 (2026-05-11 13:30 CET)
- **Cut 1 review round 4** (Claude + ChatGPT). Reviewer verdicts diverged: Claude said "ship it" (no new bugs); ChatGPT escalated a real blocker plus three medium findings. ChatGPT was correct on the blocker — the R3 `slot != nil` guards close the cancel-only race but not the cancel-and-reschedule race. Five fixes implemented; full per-finding evaluation in [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"Cut 1 — review round 4".
  - **§3.1 Properties block rewritten** (R4-5, ChatGPT second pass). `rampSubTimers: [DispatchSourceTimer] = []` updated to `[UUID: DispatchSourceTimer] = [:]`; `successTimer` slot added (R2 fix that was missing from §3.1); three new R4-1 identity-token slots (`rampTimerID`, `missTimerID`, `successTimerID`) added with rationale. Constants section includes `successInterBuzzInterval` and `timerLeeway` (with corrected scope: governs fire jitter, NOT anchor accuracy).
  - **§3.1 method docs updated** to reflect R4-1 identity-token wrappers (`rampFired(id:)` / `missFired(id:)` / `playSecondSuccessBuzz(id:)`); R4-2 per-deadline past-skip in `rearm()`; R4-3 defensive cleanup at top of `fireRamp()`; R4-3 loosened `setEnabled` gate to `expectedCadence + missGracePeriod` (320 s).
  - **§4.4 suppression reasons** new event: `event=rearm_skipped reason=deadline_passed phase=ramp|miss anchor_age_s=<int>` (R4-2). Distinguishes from existing `reason=stale_gap` by `reason` value and field shape (`anchor_age_s` vs `gap_s`). `warm_arm_skipped` threshold loosened to 320 s with corresponding doc update.
  - **§4.3 lifecycle audit** updated to note that `warm_armed` may be paired with `rearm_skipped reason=deadline_passed phase=ramp` for partial warm-arm in the 297–319 s window.
  - Code-side R4 changes (in `Trio Watch App Extension/HapticBeacon.swift`): R4-1 identity tokens for the three single-timer slots (closes cancel-and-reschedule race that R3 missed); R4-2 per-deadline past-skip inside `rearm()` (warm-arm 297–319 s window now schedules only the still-future miss timer); R4-3 `setEnabled` gate loosened from 300 s to 320 s; R4-4 defensive cancel + remove at top of `fireRamp()`.

### v1.7 (2026-05-11 12:50 CET)
- **Cut 1 review round 3** (Claude + ChatGPT). Seven fixes implemented; full per-finding evaluation in [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"Cut 1 — review round 3".
  - **§3.1 stale API docs corrected** (ChatGPT #4). `setEnabled(_:)` now describes the R2 warm-arm behavior (not "no-op if enabling") and the R3 tightened gate (300 s, not 600 s). `rearm(after:)` now describes the R2 schedule-only behavior (cancellation moved to `noteEGVReceived`). New internal-method bullets added for `rampFired`/`missFired`/`playSecondSuccessBuzz`/`rampSubTimerFired` (R3 race-safe wrappers), `cancelAllTimers` (R2/R3 truly-pending semantics + `pending_count`), `isAdapterStopped` (R2 accessor switch).
  - **§4.2 cancellation telemetry** updated with `pending_count=<int>` field on `phase=ramp_sub` (R3 fix, ChatGPT #6).
  - **§4.4 suppression reasons** updated with new `event=warm_arm_skipped reason=cycle_already_expired` (R3 fix, ChatGPT #2).
  - **§4.5 telemetry methodology** rewritten end-to-end. Split into 4.5.1 miss-cycle accounting (1:1, simple), 4.5.2 ramp-cycle accounting (1:N, includes inter-sub-haptic relations), 4.5.3 operational queries, 4.5.4 race-residue caveat (R3 fix, Claude — `haptic_cancelled` may slightly over-count when guard-before-act suppresses a queued Task that races cancellation).
  - Code-side R3 changes (in `Trio Watch App Extension/HapticBeacon.swift`): guard-before-act in `rampFired`/`missFired`/`playSecondSuccessBuzz`; `rampSubTimers` converted to `[UUID: DispatchSourceTimer]` with `rampSubTimerFired(id:type:label:)` wrapper; warm-arm gate from `staleThreshold` (600 s) → `expectedCadence` (300 s) with `warm_arm_skipped` log; honest `bleLastEGVDate` rationale (drift is NOT < leeway — leeway governs fire jitter, not anchor accuracy).

### v1.6 (2026-05-11 12:25 CET)
- **Cut 1 review round 2** (Claude + ChatGPT). Six fixes implemented; full per-finding evaluation in [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"Cut 1 — review round 2".
  - **§4 telemetry rebless.** Rewritten end-to-end to enumerate the actual operational contract (nine event names across 5 sub-sections). v1.5's "two log lines, no more" was aspirational; the implementation intentionally diverged for operational debuggability. New events from this round: `haptic_cancelled phase=ramp|ramp_sub|miss source=ble`, `warm_armed anchor_age_s=<int>`. Renamed: `rearm_skipped reason=stale_receipt` → `reason=stale_gap` (the v1.5 reason label described code that never actually fired).
  - **§4.5 telemetry analysis methodology** added so reviewers / Cut 2 spike analysts know which counts are meaningful proxies for which questions. Key correction: `haptic_armed phase=miss` is NOT a proxy for "missed EGVs" — use `haptic_fired type=retry`.
  - Adapter-stopped invariant now reads `G7WatchSensorAdapter.shared.isIntentionallyStopped` (new accessor) rather than `WatchState.shared.g7DirectBleStatus == .off` mirror — avoids a confirmed cold-start race where the mirror defaults to `.off` until `publishConnectionStatus()` runs.
  - Stale-gap guard relocated from `rearm()` (where it was dead code — checked the freshness of the just-arrived receipt, always ~0 ms) to `noteEGVReceived` (where it correctly compares the gap between consecutive receipts).
  - Second success buzz tracked in a new `successTimer` slot and cancelled deterministically by `cancelAllTimers()`.
  - Warm-arm in `setEnabled(true)` synthesizes a cadence anchor from a recent `bleLastEGVDate`, so a tester enabling the beacon mid-cycle gets ramp + miss buzzes on the very next cycle without waiting up to 5 minutes.

### v1.5 (2026-05-11 11:16 CET)
- Stale-reference cleanup. §4 telemetry table updated `failure` → `retry` to match the §3.1 / §10.1 vocabulary reservation (miss haptic uses `.retry`, not `.failure`). §7 Risk 3 cross-reference to "Open Q2" updated to "Resolved in §11 Q2" since Q2 is no longer open.

### v1.4 (2026-05-11 11:14 CET)
- Pre-implementation review pass. Verified `G7WatchSensorAdapter.shared` exists at `Trio Watch App Extension/G7WatchSensorAdapter.swift:17` — added confirmation note to §5.2 so reviewers don't re-flag. Verified `triggerConfirmation(message:)` exists at `Trio Watch App Extension/Views/ComplicationDebugView.swift:427` and is already used by three buttons in the same view — added confirmation note to §3.4. Restructured `fireRamp()` to schedule three `DispatchSourceTimer` sub-timers on `timerQueue` (stored in `rampSubTimers: [DispatchSourceTimer]`) instead of `DispatchQueue.main.asyncAfter`, so mid-ramp cancellation (kill-switch toggle, fresh EGV arrival) actually cancels the in-flight `.start` and `.notification` plays. Updated §3.1 properties and method-body description accordingly.

### v1.3 (2026-05-11 11:10 CET)
- Resolved Open Q3 to **Option A** (beacon stays silent when `WatchState.shared.g7DirectBleStatus == .off`; cancels in-flight timers and logs `event=haptic_skipped reason=adapter_stopped`). Status moved from "ready to implement once Q3 resolved" to "ready to implement Cut 1". No new adapter accessor required — status is already published via `publishConnectionStatus`.

### v1.2 (2026-05-11 11:05 CET)
- Added §10 "Future considerations: clinical alerts" capturing the user's flagged possibility that the haptic surface might host user-facing clinical alerts (impending low, high glucose, etc.) later. Reserved haptic vocabulary table — moved cadence-miss haptic from `.failure` to `.retry` to free `.failure` for future urgent-low use; reserved `.failure`, `.directionUp`, `.directionDown`, `.stop` for future clinical alerter. Documented `play(_:)` as a single choke point intentionally extractable to a shared `HapticDispatcher`. Flagged `com.apple.developer.usernotifications.critical-alerts` entitlement as a possible future need if Cut 2 fails. Listed structural decisions that explicitly do **not** need to change now (naming, file location, telemetry namespace, UserDefaults keys, glucose value access). Cut 2 fail criterion now also notes the wider product implication for future clinical alerts. Renumbered open-questions section from §10 to §11.

### v1.1 (2026-05-11 10:51 CET)
- Resolved Open Q1 (default `isEnabled = OFF` / opt-in), Q2 (receipt-time anchor `Date()` at hook), and Q4 (`WatchLogger.shared.log(_:)` is the telemetry sink) per user confirmation. Q3 (adapter-stopped behavior) restructured into Option A / Option B with explicit recommendation for Option A and rationale (status already published to `WatchState`, so no new accessor is needed).

### v1 (2026-05-11 10:36 CET)
- Initial plan. Incorporates investigation findings on `extendedSession` access, EGV hook surface, concurrency model, and `notifyUser(haptic:)` validation status. Three-cut delivery: foreground BLE → background spike → phone/HK coverage.
