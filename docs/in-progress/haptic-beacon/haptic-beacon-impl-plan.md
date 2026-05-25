# HapticBeacon — implementation plan v1.15

**Status:** Cuts 1–4 + R2–R5 review fixes + R6 multi-source safety pass + R7 warm-arm invariant tightening + **R8 stale-gap-relayed recovery + dedup log enrichment** implemented; awaiting build / on-device verification.
**Owner:** Watch app extension.
**Related code:** `Trio Watch App Extension/G7WatchSensorAdapter.swift`, `Trio Watch App Extension/Views/ComplicationDebugView.swift`, `Trio Watch App Extension/TrioWatchApp.swift`, `Trio Watch App Extension/WatchState.swift`.

## 1. Goal

A foreground/background haptic beacon for the watch app that:

1. **Pre-EGV ramp:** seven beats over the last **5 s** before expected EGV — paired `.click`, paired `.start`, triple `.notification` (escalating clusters). Each beat carries a unique telemetry label (`ramp_click_1`/`_2`, `ramp_start_1`/`_2`, `ramp_notif_1`/`_2`/`_3`).
2. **Success (BLE only):** triple `.success` at 0 ms, 200 ms, and 350 ms from hook receipt (accelerating spacing). The first beat plays synchronously so a near-immediate cancel cannot drop the confirmation; the remaining beats are sub-timers (`success_2`, `success_3`).
3. **Relayed-source arrival (R6):** WC / HealthKit deliveries that pass the precedence and dedup gates fire a single `.click` (`relayed_confirm`) — *not* the BLE success triple. Relayed payloads are inherently late, batched, or replayed, so the strong "fresh reading" confirmation is reserved for direct BLE.
4. **Miss:** double `.retry` at 0 ms and 300 ms after the grace deadline fires. First beat synchronous; second beat sub-timer (`retry_2`).

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
- `private var rampTimer: DispatchSourceTimer?` — fires once at `lastReceiptAt + (expectedCadence - rampLeadTime)` and triggers **seven** ramp sub-steps (Cut 4; was three steps / 3 s lead).
- `private var rampTimerID: UUID?` — **R4 fix (ChatGPT blocker):** identity token paired with `rampTimer`. The fire wrapper checks `rampTimerID == id` (not `rampTimer != nil`) so a stale handler raced by a fresh schedule (cancel + reschedule between handler invocation and Task execution) returns without touching the new timer's state.
- `private var rampSubTimers: [UUID: DispatchSourceTimer] = [:]` — **R3 fix (ChatGPT #1):** UUID-keyed dictionary so each sub-timer can remove itself when it fires. After all **seven** fire (Cut 4), the dictionary is empty and `cancelAllTimers()`'s `!isEmpty` check honestly means "mid-ramp cancellation"; `count` at cancellation time gives the exact `pending_count` for telemetry (R3 fix, GPT #6).
- `private var missTimer: DispatchSourceTimer?` — fires at `lastReceiptAt + (expectedCadence + missGracePeriod)`.
- `private var missTimerID: UUID?` — **R4 fix.** See `rampTimerID`.
- `private var successSubTimers: [UUID: DispatchSourceTimer] = [:]` — **Cut 4:** triple `.success` at 0 / 200 / 350 ms (`success_1` … `success_3`). Replaces the Cut 1–3 `successTimer` / `successTimerID` pair.
- `private var missSubTimers: [UUID: DispatchSourceTimer] = [:]` — **Cut 4:** double `.retry` at 0 / 300 ms (`retry_1`, `retry_2`) scheduled when the outer `missTimer` fires.
- `private var lastReceiptAt: Date?` — receipt time (`Date()` at hook), not sensor `readingDate`. Cadence anchor.
- `private var lastAcceptedReadingDate: Date?` — **R6 fix (ChatGPT blocker #1):** the sensor `readingDate` of the last accepted EGV (any source). Drives duplicate-suppression: a reading whose `readingDate <= lastAcceptedReadingDate` is rejected before any state mutation. Catches HK / WC / BLE replay overlap, rapid batched WC deliveries that arrive pre-debounce, and same-snapshot echoes across channels. **R7 note:** `attemptBLEWarmArm` *does* seed this with the synthetic anchor (`bleLastEGVDate`) — that is the sensor `readingDate` of the last BLE reading the watch already saw, so any same-`readingDate` echo via WC / HK after warm-arm is correctly dropped as a duplicate. The next live BLE EGV arrives with a strictly newer `readingDate` (the G7 BLE adapter dedups same-`sequence` deliveries before they reach `noteEGVReceived`, so two `noteEGVReceived` calls cannot share a `readingDate` from the live BLE path), so the seeding does not suppress the next real BLE success triple.
- `private var lastBLEReceiptAt: Date?` — **R6 fix (ChatGPT blocker #2):** receipt time of the last accepted BLE EGV. Drives source precedence: while younger than `bleFreshnessWindow`, relayed deliveries are rejected with `egv_ignored reason=ble_recent`. **R7 invariant (ChatGPT R7 medium #1):** *only real BLE deliveries* write this slot. `attemptBLEWarmArm` deliberately leaves it alone — warm-arm uses a sensor `readingDate` as a synthetic cadence anchor, not a watch receipt time, so storing it here would conflate the two clocks and slightly skew the freshness gate. After warm-arm and before the first real BLE EGV, `lastBLEReceiptAt` is either nil (fresh process) or whatever a prior live arrival left behind, and the precedence gate behaves accordingly.

Constants:
- `expectedCadence: TimeInterval = 300` — 5 min G7 cadence (matches `ComplicationDebugView.expectedReadingCadence`).
- `rampLeadTime: TimeInterval = 5` — Ramp arms at `receipt + 295 s`.
- `missGracePeriod: TimeInterval = 20`.
- `staleThreshold: TimeInterval = 600` — do not rearm if **gap between consecutive receipts** > 10 min (R2 fix, Claude #1; not the freshness of the current receipt).
- `bleFreshnessWindow: TimeInterval = 360` — **R6:** while `lastBLEReceiptAt` is younger than this, WC / HK deliveries are dropped with `egv_ignored reason=ble_recent`. Set just above one cadence + grace (320 s) so a single missed BLE cycle still counts as "BLE recent"; two consecutive BLE misses opens the relayed path.
- `relayedFreshnessForRearmAfterGap: TimeInterval = 30` — **R8:** when `gap > staleThreshold` (long BLE outage) AND the accepted source is relayed (WC / HK), this gate decides whether to rearm cadence on the relayed reading. Relayed readings whose sensor-to-watch latency (`receiptDate − readingDate`) is below this threshold are treated as fresh enough to re-anchor cadence (so fallback mode actually restores prediction after a BLE outage); older relayed readings (batched HK sync, late WC catch-up) log `rearm_skipped reason=stale_gap_relayed_not_fresh` and stop at the confirmation. 30 s comfortably covers healthy WC hop latency (typically < 5 s) without admitting old HK batch syncs. BLE source bypasses this gate entirely — long-gap BLE EGVs always log `rearm_skipped reason=stale_gap` and stop at the confirmation, because a long-gap BLE EGV is usually the recovery edge of an outage rather than a steady-state cadence anchor.
- `successBuzzSteps` and `missRetrySteps` — static `[(TimeInterval, WKHapticType, String)]` literals in `fireSuccess()` / `fireMiss()`. Per **R6 (ChatGPT #5)** the first step plays synchronously; only `dropFirst()` are scheduled as sub-timers.
- `timerLeeway: DispatchTimeInterval = .milliseconds(500)` — governs `DispatchSourceTimer` fire jitter, **not** anchor accuracy (R3 fix, GPT #3).

Public API (all `@MainActor`):
- `func start()` — install observers / wire-up; called once from `TrioWatchApp` on launch and on every `.active` scene phase transition. Idempotent. Logs `event=start` with `is_enabled` and (Cut 3+) `source_filter`.
- `func stop()` — cancel pending timers; clear `lastReceiptAt`; emit `event=stop`. Idempotent. Currently uncalled from production code paths (BLE keeps running across scene-phase transitions per §3.3).
- `func setEnabled(_ enabled: Bool)` — flip persisted flag and react. **Disabling** calls `clearCurrentCycle()` (R6 split: cancels timers + nils `lastCycleSource`), additionally clears `lastReceiptAt`, `lastBLEReceiptAt`, `lastAcceptedReadingDate` (R5 + R6 — without this, a re-enable hours/days later would emit a confusing `rearm_skipped reason=stale_gap` on the recovery EGV, and dedup state would block a stale `readingDate`), and emits `event=setEnabled enabled=false action=cancelled_pending_timers`. **Enabling** emits `event=setEnabled enabled=true`, then calls `attemptBLEWarmArm(trigger: "setEnabled")` (R6 helper).
- `func setSourceFilter(_ filter: SourceFilter)` — persists the new value. **Narrowing `.bleAndRelayedFallback` → `.ble`** while a non-BLE cycle is armed: cancels via `clearCurrentCycle()`, clears `lastReceiptAt`, then calls `attemptBLEWarmArm(trigger: "source_filter_narrow")` (R6 — ChatGPT #9: the user is not left without a beacon if BLE is recent enough). Widening `.ble` → `.bleAndRelayedFallback` is a no-op (precedence rules already prevent relayed displacement of a BLE cycle).
- `func noteEGVReceived(at receiptDate: Date, readingDate: Date, source: TrioComplicationDataSource)` — single hook the rest of the codebase calls. **R6 signature change (ChatGPT blocker #1):** `readingDate` is now required for dedup. Pipeline (in order):
  1. Filter gate (`accepts(source:under:)`) → `egv_ignored reason=source_filtered` on reject.
  2. Adapter-stopped gate → `clearCurrentCycle()` + `haptic_skipped reason=adapter_stopped phase=success` on reject.
  3. **Dedup gate (R6):** `readingDate <= lastAcceptedReadingDate` → `egv_ignored reason=duplicate reading_age_s=<int>`.
  4. **Source-precedence gate (R6, BLE-only sources skip this):** if `lastBLEReceiptAt` is younger than `bleFreshnessWindow` (360 s), reject relayed delivery with `egv_ignored reason=ble_recent ble_age_s=<int>`. BLE always wins.
  5. Capture prior `lastReceiptAt` for stale-gap math; `cancelAllTimers()` (does NOT clear `lastCycleSource`); update `lastReceiptAt`, `lastCycleSource`, `lastAcceptedReadingDate`; for BLE also update `lastBLEReceiptAt`.
  6. **Fire confirmation:** BLE → `fireSuccess()` (triple). Relayed → `fireRelayedConfirm()` (single quiet `.click` — **R6 product decision**).
  7. **R8 source-split stale-gap check** (`gap > staleThreshold`):
     - **BLE source:** always `rearm_skipped reason=stale_gap` and return (confirmation already played; cadence prediction stays off until the next BLE EGV proves the cycle is stable).
     - **Relayed source AND `receiptDate − readingDate >= relayedFreshnessForRearmAfterGap`:** `rearm_skipped reason=stale_gap_relayed_not_fresh` and return (batched / late relayed payload — would predict a wrong "next" cadence).
     - **Relayed source AND fresh:** `rearm_after_stale_gap reason=relayed_fresh` (info), then fall through to `rearm(after:)` so fallback mode actually restores cadence.
     - **No stale gap:** straight to `rearm(after: receiptDate)`.

Internal:
- `private func rearm(after receiptDate: Date)` — **schedule-only** (R2 fix) with **per-deadline past-skip** (R4-2 fix). Computes `rampAt = receiptDate + (expectedCadence - rampLeadTime)` and `missAt = receiptDate + (expectedCadence + missGracePeriod)`. For each, if the deadline is in the future, schedule and emit `haptic_armed phase=ramp|miss expected_at=<epoch>`. If the deadline has passed (warm-arm with stale anchor; never happens for live EGVs at age=0), emit `rearm_skipped reason=deadline_passed phase=ramp|miss anchor_age_s=<n>` and skip that timer. Cancellation of pending timers happens in callers (`noteEGVReceived`, `setEnabled`), not here.
- `private func fireRamp()` — defensive `cancel + removeAll` (R4-3) of any existing `rampSubTimers` entries before assigning a new dictionary. Then schedules **seven** UUID-keyed sub-timers per § Cut 4 table. **R6 (ChatGPT #6):** each beat carries a unique label (`ramp_click_1`/`_2`, `ramp_start_1`/`_2`, `ramp_notif_1`/`_2`/`_3`) so analysts can see which beat fired or was cancelled without grouping by `expected_at` window.
- `private func rampFired(id: UUID)` / `missFired(id: UUID)` — **R4-1 (ChatGPT blocker):** identity-token wrappers for the **outer** ramp and miss one-shots only.
- `private func rampSubTimerFired(id: UUID, type: WKHapticType, label: String)` — sub-timer wrapper. Guards on `rampSubTimers[id] != nil`, removes the entry, then calls `play(_:label:)`.
- `private func successSubTimerFired(id: UUID, type: WKHapticType, label: String)` / `private func missSubTimerFired(id: UUID, type: WKHapticType, label: String)` — same pattern for the **companion** beats (success_2 / success_3 / retry_2). The first beat plays synchronously and never reaches these wrappers.
- `private func fireSuccess()` — **R6 sync first beat (ChatGPT #5):** plays `success_1` synchronously through `play(_:label:)`, then schedules `successBuzzSteps.dropFirst()` as sub-timers. A near-immediate cancel (e.g. cancellation racing the haptic) cannot drop the confirmation. BLE-only — relayed sources route through `fireRelayedConfirm()` instead.
- `private func fireMiss()` — same sync-first-beat pattern: plays `retry_1` synchronously, then schedules `missRetrySteps.dropFirst()`.
- `private func fireRelayedConfirm()` — **R6 (product decision #5):** single quiet `.click` (`relayed_confirm`) for WC / HK arrivals. Distinct from the BLE success triple so the user can perceive provenance through haptic feel, not just a debug label.
- `private func attemptBLEWarmArm(trigger: String)` — **R6 helper:** factored out of `setEnabled(true)` so `setSourceFilter(.ble)` can reuse the same warm-arm path. Each silent guard logs `warm_arm_skipped reason=… trigger=<setEnabled|source_filter_narrow>`. Reassigns `lastReceiptAt`, `lastCycleSource = .g7DirectBLE`, and `lastAcceptedReadingDate` to the BLE anchor (the latter so a live BLE EGV with the same `readingDate` — or a WC / HK echo of it — is recognized as the warm-arm anchor's own arrival rather than firing a redundant cycle), then calls `rearm(after:)`. **R7 (ChatGPT R7 medium #1):** does **not** write `lastBLEReceiptAt` — the warm-arm anchor is a sensor reading time, not a watch receipt time, and `lastBLEReceiptAt` is documented as the latter. After warm-arm and before the first real BLE EGV, the precedence gate uses whatever `lastBLEReceiptAt` was already set to (typically nil on a fresh process), which means a fresh relayed reading with a newer `readingDate` is allowed to arm — appropriate, because the warm-arm anchor is a hand-wave, not a real BLE arrival. See the property doc comments and the R7 narrative for the full rationale.
- `private func play(_ type: WKHapticType, label: String)` — prefers `currentExtendedSession.notifyUser(haptic:)` when the session exists and `state == .running`; otherwise `WKInterfaceDevice.current().play(type)`. **R6 (Claude #3):** captures `session.state.rawValue` once before logging so the gate and the `session_state=` log field cannot disagree if the session transitions mid-call. Logs `delivered_via=extended_session|device`. Gates on `isEnabled` and `isAdapterStopped()`; emits `haptic_skipped` for either suppression.
- `private func cancelAllTimers()` — **R6 split (ChatGPT #3):** cancels timers **only**; does **not** touch `lastCycleSource`. Cancellation telemetry tags the prior cycle (still set when this runs); rearm callers (`noteEGVReceived`, `attemptBLEWarmArm`) reassign immediately. Emits `haptic_cancelled` for `phase=ramp|ramp_sub|success_sub|miss|miss_sub` when non-empty / pending with `pending_count`.
- `private func clearCurrentCycle()` — **R6 split:** wraps `cancelAllTimers()` and additionally clears `lastCycleSource = nil`. Used by every teardown caller (`stop`, `setEnabled(false)`, `setSourceFilter` narrowing). Keeps the side-effect of "I'm forgetting the cycle" out of the generic timer helper.
- `private func isAdapterStopped()` — reads `G7WatchSensorAdapter.shared.isIntentionallyStopped` (R2 fix, GPT #3). The accessor mirrors the adapter's authoritative `isStopped` flag, immune to the cold-start race in the published `g7DirectBleStatus` mirror.
- `private func log(_ event: String, _ fields: String = "")` — wraps `WatchLogger.shared.log` with `module=haptic_beacon` prefix to match adapter conventions.

### 3.2 Adapter changes (Cut 1)

Two surgical changes in `Trio Watch App Extension/G7WatchSensorAdapter.swift`:

**Change A — accessor for the beacon.** Add near line 23 (where `extendedSession` is declared):

> A new `@MainActor` computed property `currentExtendedSession: WKExtendedRuntimeSession?` that returns `extendedSession`. Internal access level is sufficient (singletons are in the same module). No setter. No caching by callers.

**Change B — beacon hook on EGV.** Inside the existing `Task { @MainActor in }` block at lines 609–615 of `sensor(_:didRead glucose:)`, append a single call:

> `HapticBeacon.shared.noteEGVReceived(at: Date(), readingDate: readingDate, source: .g7DirectBLE)`

Notes:
- Pass `Date()` as `at:` (receipt time, the cadence anchor) and the existing `readingDate` local (sensor reading-time) as `readingDate:` for **R6** dedup.
- Place the call **after** the existing three `WatchState.shared.*` writes so beacon never sees inconsistent state if the user adds future hooks that read those.
- The adapter is `@MainActor`, so the call is direct (no `Task` hop needed). The two `WatchState` hooks need a `Task { @MainActor in … }` wrapper because `WatchState` is not `@MainActor`.

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
event=haptic_armed phase=ramp|miss expected_at=<unix_epoch> source=ble|wc|hk|unknown
event=haptic_fired type=ramp_click_1|ramp_click_2|ramp_start_1|ramp_start_2|ramp_notif_1|ramp_notif_2|ramp_notif_3|success_1|success_2|success_3|retry_1|retry_2|relayed_confirm delivered_via=device|extended_session [session_state=<int>] [reason_no_session=<state_or_nil>] source=ble|wc|hk|unknown
```

Cut 2: `delivered_via=extended_session` includes `session_state=<rawValue>` when `notifyUser(haptic:)` is used. Device fallback includes `reason_no_session=<state_or_nil>` (extended session missing, or present but not `.running`).

**R6:** `type=` is now per-beat (each ramp/success/miss step has a distinct label, ChatGPT #6) and gains `relayed_confirm` for the single `.click` fired when a WC / HK source arms a cycle (BLE-only sources fire `success_1` / `_2` / `_3` instead). The pre-R6 collapsed labels (`ramp_click`, `success`, `retry`) **no longer appear** — historical queries should treat them as `ramp_click_*`, `success_*`, `retry_*`.

Cut 3: `source` is no longer hardcoded to `ble`. It reflects the provenance of the EGV that armed the active cycle — the beacon's private `lastCycleSource` slot — captured at every fire. `unknown` should never appear in steady state; if it does, treat it as a logic-gap signal (cycle armed without recording the source).

### 4.2 Cancellation telemetry (R2 fix, Claude #3; R3 fix, ChatGPT #6)

```
event=haptic_cancelled phase=ramp source=ble|wc|hk|unknown
event=haptic_cancelled phase=ramp_sub pending_count=<int> source=ble|wc|hk|unknown
event=haptic_cancelled phase=success_sub pending_count=<int> source=ble|wc|hk|unknown
event=haptic_cancelled phase=miss source=ble|wc|hk|unknown
event=haptic_cancelled phase=miss_sub pending_count=<int> source=ble|wc|hk|unknown
```

Emitted by `cancelAllTimers()` only for slots that are *truly pending* (post null-on-fire). `phase=ramp_sub` indicates a mid-ramp cancellation (up to seven sub-haptics; `pending_count` is 1…7).

**R6 (success_sub / miss_sub semantics):** because the first beat of success / miss now plays synchronously (`success_1`, `retry_1`), a `phase=success_sub` cancellation describes lost **companion** beats (`success_2` / `success_3`) — *not* a missed confirmation of EGV arrival. `pending_count` is 1…2 for success_sub and 0…1 for miss_sub. Treat as "post-confirmation polish was interrupted"; do not include in prediction-reliability math.

Cut 3: `source=` reflects the *prior* cycle being torn down — `cancelAllTimers()` captures `currentSourceTag()` at the top. **R6:** `cancelAllTimers()` no longer clears `lastCycleSource` (that moved to `clearCurrentCycle()`); rearm callers reassign it immediately after. Behavior unchanged for telemetry.

### 4.3 Lifecycle and toggle audit

```
event=start is_enabled=<bool> source_filter=<ble|ble_relayed_fallback>
event=stop
event=setEnabled enabled=<bool> [action=cancelled_pending_timers]
event=setSourceFilter value=<ble|ble_relayed_fallback> [action=cancelled_pending_timers prior_cycle_source=<tag>]
event=warm_armed anchor_age_s=<int> source=ble trigger=<setEnabled|source_filter_narrow>
event=egv_ignored reason=source_filtered source=<tag> filter=<value>
event=egv_ignored reason=duplicate source=<tag> reading_age_s=<int>
event=egv_ignored reason=ble_recent source=<tag> ble_age_s=<int>
```

`setSourceFilter` emits with `value=` always; `action=cancelled_pending_timers prior_cycle_source=<tag>` appears only when narrowing to `.ble` cancels a non-BLE cycle in flight. **R6:** when narrowing displaces a non-BLE cycle, the `setSourceFilter` line is followed by either a `warm_armed trigger=source_filter_narrow` (BLE anchor recent enough) or a `warm_arm_skipped reason=… trigger=source_filter_narrow` line.

**R6 — new `egv_ignored` reasons:**
- `reason=duplicate`: incoming `readingDate` is `<=` the last accepted `readingDate`. Carries `reading_age_s` (`receiptDate − readingDate`). Expected on HK ↔ WC overlap and rapid batched WC deliveries.
- `reason=ble_recent`: relayed (WC / HK) source rejected because BLE was accepted within `bleFreshnessWindow` (360 s). Carries `ble_age_s`. Expected at steady state when both BLE and phone are healthy.

`warm_armed` is emitted when `setEnabled(true)` or `setSourceFilter(.ble)` (after narrowing displaces a non-BLE cycle) finds a recent `WatchState.shared.bleLastEGVDate` (< `expectedCadence + missGracePeriod` = 320 s) and synthesizes a cadence anchor without waiting for the next live EGV. The success sequence is intentionally suppressed in this path — only ramp / miss are scheduled. The `trigger=` field (R6) distinguishes the two paths.

### 4.4 Suppression / skip reasons

```
event=haptic_skipped reason=adapter_stopped phase=success source=<tag>            # noteEGVReceived skip; source = incoming EGV
event=haptic_skipped reason=adapter_stopped type=<label> source=<tag>             # play(_:label:) skip; source = active cycle (or unknown)
event=rearm_skipped reason=stale_gap gap_s=<int> source=<tag>                     # R2 fix (Claude #1); Cut 3 added source
event=rearm_skipped reason=deadline_passed phase=ramp|miss anchor_age_s=<int> source=<tag>  # R4-2 fix (GPT #1); Cut 3 added source
event=warm_arm_skipped reason=adapter_stopped trigger=<setEnabled|source_filter_narrow>                            # R5 + R6 trigger
event=warm_arm_skipped reason=no_anchor trigger=<setEnabled|source_filter_narrow>                                  # R5 + R6 trigger
event=warm_arm_skipped reason=anchor_in_future anchor_age_s=<int> trigger=<setEnabled|source_filter_narrow>        # R5 + R6 trigger
event=warm_arm_skipped reason=cycle_already_expired anchor_age_s=<int> trigger=<setEnabled|source_filter_narrow>   # R3 + R4-3 + R6 trigger
```

**R6:** every `warm_arm_skipped` line now carries a `trigger=` field (`setEnabled` or `source_filter_narrow`) so analysts can attribute the skip to the user action that raised it.

- `haptic_skipped reason=adapter_stopped`: gated by `G7WatchSensorAdapter.shared.isIntentionallyStopped` (R2 fix, GPT #3). At `noteEGVReceived` entry the skip carries `phase=success source=<src>`; at `play(_:label:)` time the skip carries `type=<label>`.
- `rearm_skipped reason=stale_gap` (was `reason=stale_receipt` in v1.5; renamed because the v1.5 implementation never actually fired): emitted when the gap between the previous and current receipt exceeds `staleThreshold` (600 s). The success buzz still fires (confirms recovery), but no ramp/miss is scheduled — the cadence is unreliable until it re-stabilizes, and the next EGV will rearm normally. **R5 note:** because R5 also clears `lastReceiptAt` on `setEnabled(false)`, this event no longer fires on the first live EGV after a long disable period (which previously produced a correct-but-confusing `stale_gap` log on what was actually a normal recovery).
- `rearm_skipped reason=deadline_passed` (R4-2 fix, GPT #1): emitted **per deadline** when `rearm()` finds that `rampAt <= now` or `missAt <= now`. Carries `phase=ramp|miss` and `anchor_age_s`. For the live-EGV path (age=0) this never fires; for the warm-arm path with stale anchor (**Cut 4:** age **295–319 s**) `phase=ramp` fires while `phase=miss` is still scheduled normally; for warm-arm at age ≥ 320 s the upstream `warm_arm_skipped` gate fires and `rearm()` is never reached. Different `reason` and field shape from `stale_gap` (`anchor_age_s` vs `gap_s`).
- `warm_arm_skipped reason=adapter_stopped|no_anchor|anchor_in_future|cycle_already_expired` — emitted from `setEnabled(true)` whenever the warm-arm guard chain rejects the toggle. Each silent early-return that pre-R5 produced no log now emits one of these distinct reasons:
  - `reason=adapter_stopped` (R5): adapter's `isIntentionallyStopped` returned true at toggle time; warm-arm and live arming both deferred until the next non-stopped state. No `anchor_age_s` field.
  - `reason=no_anchor` (R5): `WatchState.shared.bleLastEGVDate` is nil or `.distantPast`. Cold-launch case before any BLE EGV has been received. No `anchor_age_s` field. The next live EGV will arm normally via `noteEGVReceived`.
  - `reason=anchor_in_future` (R5): `Date().timeIntervalSince(bleLastEGV) < 0`. Clock skew between watch and sensor (or wall-clock movement). Carries `anchor_age_s` (will be negative). Rare; analysts seeing this should investigate clock state.
  - `reason=cycle_already_expired` (R3 fix, GPT #2; R4-3 threshold loosen to 320 s): the BLE anchor is older than `expectedCadence + missGracePeriod` (320 s). The next live EGV will rearm normally; warm-arming a fully-expired cycle would replay an immediate ramp burst plus immediate miss, which is bad UX.

### 4.5 Telemetry analysis methodology (R3 fix, GPT #5 — split miss vs ramp)

Critical for analyzing whether haptics are actually being delivered. The miss cycle has a clean 1:1 armed-to-fired mapping for the **outer** miss timer; **Cut 4** fires **two** `.retry` sub-haptics per delivered miss (`retry_1`, `retry_2`). The ramp cycle has a 1:N mapping (one armed, **up to seven** fired sub-events in Cut 4). Treat them separately.

#### 4.5.1 Miss-cycle accounting (1:1 outer; 1:2 fired)

```
count(haptic_armed phase=miss)
  ≈ count(haptic_cancelled phase=miss)
  + count(haptic_fired type=retry_1)
  + count(haptic_skipped reason=adapter_stopped type=retry_1)
  + (residue: in-flight at query time)
```

**Cut 4:** For each delivered miss, expect **`retry_2`** shortly after **`retry_1`** (`count(retry_1) ≈ count(retry_2)` when the companion sub-timer wasn't cancelled). Use `retry_1` count as a 1:1 proxy for **miss cycles** (the first beat plays synchronously — R6 — so it cannot be lost to cancellation). `retry_2` count is `retry_1` minus mid-sequence cancellations.

#### 4.5.2 Ramp-cycle accounting (1:7, Cut 4 + R6 unique labels)

One `haptic_armed phase=ramp` triggers `rampFired`, which calls `fireRamp`, which schedules **seven** sub-timers. **R6:** each beat now carries a unique label (`ramp_click_1`, `ramp_click_2`, …) so cancellation attribution and "which beat fired" are answerable directly from the log without grouping by `expected_at`.

```
count(haptic_armed phase=ramp)
  ≈ count(haptic_cancelled phase=ramp)
  + count(haptic_fired type=ramp_click_1)        # R6: first beat per ramp; 1:1 proxy for completed-or-partial ramps
  + count(haptic_skipped reason=adapter_stopped type=ramp_click_1)
  + race-residue (small; see §4.5.4)
```

For partial-ramp diagnosis: count gaps between `ramp_click_1`/`_2`/`ramp_start_1`/`_2`/`ramp_notif_1`/`_2`/`_3` per `expected_at` window. Alternatively: `sum(haptic_cancelled phase=ramp_sub | pending_count)` totals the sub-haptics that didn't fire because of mid-ramp cancellation; `pending_count` ranges 1…7.

#### 4.5.3 Operational queries

- **Did a haptic fire?** `count(haptic_fired group by type)`. Source of truth.
- **Why was a haptic suppressed?** `count(haptic_skipped group by reason)`.
- **Did the user disable the beacon?** `count(setEnabled enabled=false)`.
- **Did the beacon fail to rearm after a long outage?** `count(rearm_skipped reason=stale_gap)`.
- **Did warm-arm trigger or skip?** `count(warm_armed)` vs `count(warm_arm_skipped group by reason, trigger)` — the `reason` breakdown distinguishes the four R5-distinguished cases (`adapter_stopped`, `no_anchor`, `anchor_in_future`, `cycle_already_expired`); the **R6** `trigger` breakdown attributes each skip to `setEnabled` or `source_filter_narrow`.
- **R6: did source precedence drop a relayed reading?** `count(egv_ignored reason=ble_recent)` per source.
- **R6: did dedup catch a replay?** `count(egv_ignored reason=duplicate)` per source — high counts on `wc` or `hk` are expected when the same reading echoes across channels.

#### 4.5.4 Race-residue caveat (R3 fix, Claude)

In rare cases, `haptic_cancelled phase=ramp` (or `phase=miss`) may log without a corresponding "actual cancellation": the timer's event handler ran on `timerQueue` and dispatched a `Task @MainActor`, then `cancelAllTimers()` ran on `@MainActor` *before* that Task executed. The cancellation log fires (slot was non-nil at log time), and the queued Task's `guard slot != nil else { return }` then suppresses the haptic. So *behavior* is correct (no spurious ramp/miss); *log* slightly over-counts cancellations. Race window is the dispatch latency (microseconds). Ignore single-digit residual counts during analysis.

### 4.6 Why the surface area expanded vs v1.5

v1.5 said "two log lines, no more." Implementation diverged for operational debuggability:
- Lifecycle visibility (`start`, `stop`) makes "is the beacon installed?" answerable from logs alone.
- Toggle audit (`setEnabled`) makes "did the user turn this off?" trivially queryable.
- Suppression reasons (`haptic_skipped`, `rearm_skipped`) explain every non-fire — without them, "the haptic didn't buzz" requires source-code inspection to debug.
- Cancellation telemetry (`haptic_cancelled`, R2 fix) makes the predictive lifecycle queries above mathematically sound.
- `warm_armed` (R2 fix) confirms the warm-arm path triggered.

All R2 events are bounded — at most one per state transition, never per-tick. **Cut 4** raises steady-state `haptic_fired` volume versus Cut 1–3 (up to **seven** ramp lines, **three** success lines, **two** miss lines per respective phase). Nominal healthy cadence still centers on one `haptic_armed` pair per cycle plus cancellations when the next EGV arrives before miss.

## 5. Cut 2 — `notifyUser(haptic:)` spike

Treat as a separate, time-boxed validation step. Keeps the Cut 1 surface area stable while the unknown is measured. **Code path (§5.2) is implemented in v1.10**; on-device spike protocol §5.3 and pass/fail §5.4 remain **manual validation**.

### 5.1 Goal

Determine whether `WKExtendedRuntimeSession.notifyUser(haptic:)` delivers haptics on a `.physicalTherapy` session when:

- the watch face is asleep (wrist down), and
- the Trio app is not the foreground app.

`physical-therapy` is confirmed in `Trio Watch App/Info.plist:23–26`. The Swift initializer is parameterless (`WKExtendedRuntimeSession()`); `physicalTherapy` is a session **type** declared via Info.plist `WKBackgroundModes`, not a constructor argument.

### 5.2 Code change (only `play(_:label:)`)

(`G7WatchSensorAdapter.shared` verified at `Trio Watch App Extension/G7WatchSensorAdapter.swift:17` — `static let shared = G7WatchSensorAdapter()`. Singleton access is sound; the `currentExtendedSession` accessor sits next to it.)

Replace the Cut 1 body with the dual path below. **Deviation from the v1.9 draft snippet:** telemetry uses the existing `label` argument (`ramp_click`, `success`, …) instead of `name(of: type)` — same contract, clearer queries.

```
@MainActor
private func play(_ type: WKHapticType, label: String) {
    guard isEnabled else { return }
    guard !isAdapterStopped() else {
        log("haptic_skipped", "reason=adapter_stopped type=\(label)")
        return
    }
    if let session = G7WatchSensorAdapter.shared.currentExtendedSession,
       session.state == .running {
        session.notifyUser(haptic: type)
        log("haptic_fired", "type=\(label) delivered_via=extended_session session_state=\(session.state.rawValue)")
    } else {
        WKInterfaceDevice.current().play(type)
        let stateDesc = G7WatchSensorAdapter.shared.currentExtendedSession.map { "\($0.state.rawValue)" } ?? "nil"
        log("haptic_fired", "type=\(label) delivered_via=device reason_no_session=\(stateDesc)")
    }
}
```

No other code changes for Cut 2. The accessor (§3.2 Change A) is the only adapter surface the beacon needs.

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

## 6. Cut 3 — phone / HealthKit source coverage

**Status (plan v1.11): code landed.** Cut 2 spike validation (§5.3 / §5.4) has not yet been executed on-device, so the gate "Cut 2 = pass" has been **explicitly deferred** rather than satisfied. The user directed Cut 3 implementation in advance of the spike — see [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) Cut 3 section for the deviation note. If Cut 2 fails, the source-filter UI and telemetry still work in foreground; the filter widening to `.all` simply gives the user a switch they may not benefit from with the screen off.

Two new hooks, each one line:

- `WatchState.swift` end of `applyHKSnapshot(_:)` (after `lastWatchStateUpdate = snapshot.readingDate`):
  `Task { @MainActor in HapticBeacon.shared.noteEGVReceived(at: Date(), readingDate: hkReadingDate, source: .healthKit) }`
  **R6 (Claude #1):** `WatchState` is not `@MainActor`; the call is wrapped in `Task { @MainActor in … }` to satisfy isolation unambiguously. **R6 (ChatGPT blocker #1):** the snapshot's `readingDate` is captured into a local and passed through so dedup state can reject same-reading replays across HK / WC / BLE channels.
- `WatchState.swift` after the `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` call inside `saveComplicationSnapshot(...)`:
  `Task { @MainActor in HapticBeacon.shared.noteEGVReceived(at: Date(), readingDate: wcReadingDate, source: .watchConnectivity) }`
  **R6 (Claude #2):** the hook fires *before* the data store's `minInterval=5` debounce (the data-store guard does not cover the beacon). Beacon-side `lastAcceptedReadingDate` dedup is what protects against rapid batched WC deliveries — a comment at the call site documents this so future maintainers don't assume the data-store debounce covers the beacon.

Beacon API:
- `enum SourceFilter: String { case ble; case bleAndRelayedFallback = "ble_relayed_fallback" }` (R6 rename — see §R6 below) and `var sourceFilter: SourceFilter` (default `.ble` when `UserDefaults.standard["HapticBeacon.sourceFilter"]` is absent or unrecognized; **migrates the historical `"all"` raw value to `.bleAndRelayedFallback`**).
- `func setSourceFilter(_:)` persists the new value. **Narrowing to `.ble`** while a non-BLE cycle is armed cancels via `clearCurrentCycle()` and **R6:** attempts a BLE warm-arm (`attemptBLEWarmArm(trigger: "source_filter_narrow")`) so the user is not left without a beacon. Widening to `.bleAndRelayedFallback` is a no-op (precedence prevents relayed displacement of a BLE cycle).
- `noteEGVReceived(at:readingDate:source:)` rejects sources not admitted by the active filter and logs `egv_ignored reason=source_filtered source=<tag> filter=<value>` for analyst visibility. **R6 (ChatGPT blockers #1/#2/#10):** also enforces dedup via `lastAcceptedReadingDate` (logs `reason=duplicate`) and source precedence via `lastBLEReceiptAt` (logs `reason=ble_recent`); BLE-only sources fire the success triple, relayed sources fire `relayed_confirm`.

Per-cycle telemetry tagging:
- The cycle's anchor source (`.g7DirectBLE | .watchConnectivity | .healthKit`) is stored in a private `lastCycleSource` slot, captured on `noteEGVReceived` accept and on warm-arm (always `.g7DirectBLE` because `bleLastEGVDate` is BLE-only). Cleared by `cancelAllTimers()` (which captures the tag for cancellation logs *before* clearing).
- All `armed`, `cancelled`, and `fired` log lines now carry `source=ble|wc|hk|unknown`. `unknown` should never appear in steady state — its presence indicates a logic gap (`lastCycleSource` was nil while a timer was armed).
- `start` log now also carries `source_filter=<value>` so analysts can see the active filter at session start without scanning back for the most recent `setSourceFilter`.

Debug UI:
- Second `Button` in `actionsView` immediately below the existing Haptic Beacon toggle. Label: "Source: BLE only" / "Source: All". `.bordered` + `.tint(.pink)` matches the beacon button. Confirmation toast and SF Symbol distinguishes the two states (`dot.radiowaves.left.and.right` vs `antenna.radiowaves.left.and.right`).

Why this was deferred (now overridden):
- Phone- and HK-relayed readings can arrive late, batched, or out of cadence — they will produce false misses on the beacon. Validating the underlying BLE delivery mechanism first (Cut 2) was meant to be the prerequisite for deciding whether the extra noise is acceptable. Cut 3 now ships the *option* and lets the user opt in once they form an opinion.
- Background haptic delivery (Cut 2 spike) is independent of source provenance — Cut 3 does not move that needle either way.

## Cut 4 — richer cadence haptics (UX tuning)

**Goal:** Make ramp, success, and miss patterns easier to perceive without adding new `WKHapticType` values — only constants, step arrays, and sub-timer plumbing inside `HapticBeacon.swift`.

**Ramp**
- `rampLeadTime`: **3 s → 5 s**. First ramp sub-beat still aligns with “five minutes minus lead” from the anchor receipt: ramp **arms** at `receipt + (300 − 5) = receipt + 295 s` (was +297 s).
- Replace the three single beats at `+0 / +1 / +2 s` from the ramp trigger with **seven** beats on the schedule below (offsets are seconds **from the ramp trigger instant**, i.e. when `rampFired` calls `fireRamp()`). Same `rampSubTimers` dictionary + `rampSubTimerFired` pattern; no new haptic types.

| Offset (s) | `WKHapticType` | `type=` in logs (R6 unique labels) |
|---:|---|---|
| 0.0 | `.click` | `ramp_click_1` |
| 0.5 | `.click` | `ramp_click_2` |
| 1.5 | `.start` | `ramp_start_1` |
| 2.0 | `.start` | `ramp_start_2` |
| 3.5 | `.notification` | `ramp_notif_1` |
| 4.0 | `.notification` | `ramp_notif_2` |
| 4.5 | `.notification` | `ramp_notif_3` |

**Success**
- Replace the `successTimer` / `successTimerID` second-buzz slot with **`successSubTimers: [UUID: DispatchSourceTimer]`** (same UUID remove-on-fire pattern as ramp).
- Triple `.success` at **0 ms, 200 ms, 350 ms** from the hook (`success_1`, `success_2`, `success_3`). Spacing accelerates (200 ms then 150 ms).

**Miss**
- When the outer `missTimer` fires, `fireMiss()` schedules **`missSubTimers`** with double `.retry` at **0 ms and 300 ms** (`retry_1`, `retry_2`).

**Telemetry**
- `haptic_fired type=` union gains `success_1|success_2|success_3` and `retry_1|retry_2` (ramp labels unchanged but repeated rows share the same `type=` string per beat).
- `cancelAllTimers()` may emit `haptic_cancelled phase=success_sub|miss_sub pending_count=<n>` when tearing down mid-sequence (same analyst pattern as `ramp_sub`).

**Warm-arm:** Partial warm-arm window where only miss arms shifts to anchor ages **~295–319 s** (ramp deadline already passed, miss still future).

**Files modified:** `Trio Watch App Extension/HapticBeacon.swift` only.

## R6 — multi-source safety and UX polish (review pass — landed plan v1.13)

External review of the R5+Cut2+Cut3+Cut4 worktree (Claude + ChatGPT) and a follow-up product decision pass surfaced multi-source safety blockers in Cuts 2/3 and a set of UX / telemetry refinements for Cut 4. R6 implements all of them in `Trio Watch App Extension/HapticBeacon.swift` plus the WatchState hook sites.

### R6 product decisions (authoritative)

1. **Success haptic = BLE only.** The triple `.success` confirms a fresh **direct BLE** reading. WC / HealthKit relayed deliveries do **not** fire it.
2. **Relayed-source miss suppression:** allowed, but only when the relayed payload is genuinely new (passes the dedup gate) and BLE is stale enough (passes the precedence gate).
3. **Relayed-source cadence arming:** fallback only. BLE remains the primary cadence anchor; relayed deliveries can arm only when no recent BLE EGV exists (`bleFreshnessWindow = 360 s`).
4. **Debug UI label:** rename "All" to "BLE + relayed". The persisted enum case becomes `.bleAndRelayedFallback` (raw value `"ble_relayed_fallback"`); historical `"all"` raw value migrates to it.
5. **Different feel by source:** relayed cycles fire a single quiet `.click` (`relayed_confirm`), not the BLE success triple. The user can perceive provenance through haptic feel.

### R6 fix list (disposition)

| # | Source | Severity | Fix | Code surface |
|---|---|---|---|---|
| 1 | ChatGPT blocker — WC/HK call `noteEGVReceived(at: Date())` without dedup | Blocker | **Fix:** add `readingDate` to signature; track `lastAcceptedReadingDate`; reject `readingDate <= last` with `egv_ignored reason=duplicate` | `noteEGVReceived`, BLE call site, both WatchState hooks |
| 2 | ChatGPT blocker — `.all` lets relayed sources displace BLE | Blocker | **Fix:** track `lastBLEReceiptAt`; reject relayed source while `lastBLEReceiptAt` is younger than `bleFreshnessWindow` (360 s) with `egv_ignored reason=ble_recent` | `noteEGVReceived` |
| 3 | ChatGPT — `cancelAllTimers()` clearing `lastCycleSource` is risky in a generic helper | Conceptual | **Fix:** split into `cancelAllTimers()` (timers only) and `clearCurrentCycle()` (timers + cycle source). Teardown callers use the latter; rearm callers use the former and reassign immediately. | `cancelAllTimers`, `clearCurrentCycle`, `stop`, `setEnabled(false)`, `setSourceFilter` narrowing |
| 4 | ChatGPT — `success_sub` cancellation telemetry semantics need clarification | High | **Fix-in-doc + sync first beat:** play `success_1` synchronously so `phase=success_sub` describes companion-beat cancellation, not lost confirmation. Document in §4.2. | `fireSuccess`, plan §4.2 |
| 5 | ChatGPT — 0.0 sub-timer can be cancelled before first haptic plays | High | **Fix:** play first beat of success/miss synchronously through `play(_:label:)`; sub-timers schedule from `steps.dropFirst()` | `fireSuccess`, `fireMiss` |
| 6 | ChatGPT — duplicate ramp labels lose event-level visibility | High | **Fix:** unique labels `ramp_click_1`/`_2`, `ramp_start_1`/`_2`, `ramp_notif_1`/`_2`/`_3`; update §4.1 / §4.5 / Cut 4 table | `fireRamp`, plan §§4.1, 4.5, Cut 4 table |
| 7 | ChatGPT — code comments reintroduced "Cut 4" references | Medium | **Fix:** rewrite source-doc comments behavior-focused (no review-round / cut references in code) | `HapticBeacon.swift` headers + inline comments |
| 8 | ChatGPT + product decision — "All" label is misleading | Medium | **Fix:** rename `SourceFilter.all` → `.bleAndRelayedFallback` (raw `"ble_relayed_fallback"`); migrate `"all"`; update debug button to "BLE + relayed" | `HapticBeacon`, `ComplicationDebugView` |
| 9 | ChatGPT — `setSourceFilter(.ble)` cancels but does not warm-arm | Medium | **Fix:** factor warm-arm into `attemptBLEWarmArm(trigger:)`; `setSourceFilter(.ble)` calls it after cancel (with `trigger="source_filter_narrow"`) | `attemptBLEWarmArm`, `setSourceFilter`, `setEnabled` |
| 10 | ChatGPT — WC + HK can double-fire on same reading | Blocker (fixed by #1) | Same fix as #1 — dedup by `readingDate` catches cross-channel echoes | (covered by #1) |
| Claude #1 | WatchState hook thread safety | Minor (verify) | **Fix:** wrap WatchState calls in `Task { @MainActor in … }` (matches the other 7+ uses in the file); BLE adapter call site stays direct because the adapter is already `@MainActor` | both WatchState hook sites |
| Claude #2 | WC hook fires regardless of `minInterval=5` debounce | Minor | **Fix:** add comment at call site documenting that beacon-side dedup is what protects against pre-debounce batches; the data-store guard does not | WC hook site comment |
| Claude #3 | `session.state` read twice in `play()` | Cosmetic | **Fix:** capture `session.state.rawValue` once before `notifyUser` and reuse for the log line | `play(_:label:)` |

### R6 telemetry contract changes (for analyst awareness)

- `haptic_fired type=`: pre-R6 collapsed labels (`ramp_click`, `success`, `retry`) **no longer appear**. New union: `ramp_click_1|ramp_click_2|ramp_start_1|ramp_start_2|ramp_notif_1|ramp_notif_2|ramp_notif_3|success_1|success_2|success_3|retry_1|retry_2|relayed_confirm`.
- `egv_ignored reason=`: new values `duplicate` (with `reading_age_s`) and `ble_recent` (with `ble_age_s`) join the existing `source_filtered`.
- `warm_armed` / `warm_arm_skipped`: gain `trigger=setEnabled|source_filter_narrow`.
- `setSourceFilter value=`: enum raw values change from `ble|all` to `ble|ble_relayed_fallback`. Historical `all` rows pertain to the same policy, now under the new name.
- `start source_filter=`: same value-set change as `setSourceFilter`.

### R6 done criteria

- [ ] WC or HK delivery with the same `readingDate` as a prior BLE accept logs `egv_ignored reason=duplicate` and does not fire any haptic.
- [ ] WC or HK delivery while `lastBLEReceiptAt` is < 360 s old logs `egv_ignored reason=ble_recent`.
- [ ] In `.bleAndRelayedFallback` mode with BLE quiet (no BLE accept ≥ 360 s), a fresh WC / HK delivery fires a single `haptic_fired type=relayed_confirm` and arms a relayed cycle (no `success_*` beats).
- [ ] `setSourceFilter(.ble)` while a non-BLE cycle is armed emits `setSourceFilter value=ble action=cancelled_pending_timers prior_cycle_source=<wc|hk>` followed by either `warm_armed trigger=source_filter_narrow` (BLE recent) or `warm_arm_skipped reason=… trigger=source_filter_narrow` (BLE not recent).
- [ ] Each ramp beat is identifiable by a unique `type=` label in Better Stack.
- [ ] Mid-success-triple cancellation logs `phase=success_sub pending_count=1|2`; mid-miss-double cancellation logs `phase=miss_sub pending_count=1`. Neither indicates a missed confirmation (first beat of each was synchronous).
- [ ] Historical `"all"` source-filter preference still loads the new policy (no `UserDefaults` reset required).

## R7 — warm-arm invariant tightening (review pass — landed plan v1.14)

A second external review pass on the R6 worktree (Claude round 2 + ChatGPT round 3) surfaced one shared concern around the warm-arm path's interaction with the new dedup / precedence state. The two reviewers disagreed on whether the current behavior is a blocker (ChatGPT) or correct (Claude). R7 sides with Claude on the literal blocker scenario after verifying it cannot occur, but adopts ChatGPT's deeper invariant point about clean separation of synthetic vs real anchors.

### R7 reviewer disposition (with rationale)

| # | Reviewer | Severity claimed | Disposition | Rationale |
|---|---|---|---|---|
| 1 | ChatGPT — "blocker 1": warm-arm seeds `lastAcceptedReadingDate = bleLastEGV`, so the next real BLE EGV with the same `readingDate` is dropped as duplicate, suppressing success triple | Blocker | **Disagree, no code change.** Verified in `G7WatchSensorAdapter.swift:578–580`: the adapter dedups same-`sequence` deliveries before they reach `noteEGVReceived`. Same `sequence` ⇒ same `glucoseTimestamp` ⇒ same `readingDate`, so two `noteEGVReceived` calls cannot share a `readingDate` from the live BLE path. Claude's analysis is correct. The invariant is now spelled out in the `lastAcceptedReadingDate` doc comment so future readers do not re-litigate it. |
| 2 | ChatGPT — "blocker 2": dedup by `readingDate <= lastAcceptedReadingDate` can drop newer-source recovery after stale BLE if the dedup state is poisoned by warm-arm | Blocker (conditional on #1) | **Resolved by #4 + #5.** Once warm-arm only writes `lastAcceptedReadingDate` (not `lastBLEReceiptAt`), and the property doc comment explicitly defines what "accepted" means, dedup behavior is the documented, intended one. `lastAcceptedReadingDate` may be either a real arrival's `readingDate` or a warm-arm anchor — the comment now lists both cases and explains why neither produces the failure mode ChatGPT described. |
| 3 | ChatGPT — "high-risk": relayed fallback fires a confirmation haptic; user may not understand "click = relayed fallback, not BLE healthy" | High | **No code change; intent affirmed.** Already covered by R6 product decision #5 (different feel for relayed sources) — the click is a deliberate quiet acknowledgement, distinguishable from the BLE success triple. Explicitly noted here so on-device validation testers know to expect the click and that it is not a BLE-confirmation signal. |
| 4 | ChatGPT — "medium 1": `lastBLEReceiptAt = bleLastEGV` in warm-arm conflates sensor reading time with watch receipt time, slightly skewing the freshness gate | Medium | **Adopted.** `attemptBLEWarmArm` no longer writes `lastBLEReceiptAt`. Property doc comment updated to make the "only real BLE deliveries write this slot" invariant explicit. After warm-arm and before the first live BLE EGV, the precedence gate uses whatever a prior live arrival left behind (or nil for a fresh process). A fresh relayed reading with a newer `readingDate` is allowed to arm during this window, which is appropriate: warm-arm is a synthetic recovery, not a guarantee that BLE just delivered. |
| 5 | ChatGPT — "medium 1 invariant": dedup-state writers should be limited to real-EGV-acceptance paths | Medium | **Partially adopted.** `lastAcceptedReadingDate` is still written by warm-arm — Claude's defense is correct that this blocks WC / HK echoes of the warm-arm anchor from arming a redundant cycle. The doc comment now lists warm-arm as a documented exception with the precise invariant ("warm-arm seeds with the synthetic anchor; live BLE arrivals will be strictly newer"). |
| 6 | ChatGPT — "medium 2": `setEnabled(false)` clears `lastAcceptedReadingDate`, so a disable / re-enable inside one cycle could let a replay arm a second cycle | Medium | **No code change; documented.** Acceptable for the current debug-only beacon toggle. Inline comment added at the clear site noting that, if the toggle becomes user-facing, dedup state should survive enable cycles within the process lifetime. |
| 7 | ChatGPT — "medium 3": file-level docstrings are very long (becoming a mini design doc) | Medium | **Deferred (acknowledged).** Active development; the docstrings serve as the local source of truth. Pre-upstream-PR cleanup task — not blocking on-device validation. |
| 8 | ChatGPT — "medium 4": pre-existing `R5c —` comment in `WatchState.swift` violates the same source-comment-hygiene principle | Medium | **Out of scope.** That comment belongs to the watch G7 BLE observer initiative, not the haptic beacon. Tracked separately in that initiative's docs (see `Trio-dev/docs/in-progress/watch-g7-direct-ble-observer/`). |
| 9 | Claude — minor observation: `guard let firstStep = Self.successBuzzSteps.first` is a defensive guard on a non-empty static; cosmetic inconsistency with `fireRamp` which has no equivalent guard | Cosmetic | **Documented in code.** Inline comments in `fireSuccess` and `fireMiss` now explain the array is non-empty by construction and the guard exists to make the synchronous-first / companion-rest pattern locally obvious to a future maintainer. Behavior unchanged. |

### R7 code changes

All in `Trio Watch App Extension/HapticBeacon.swift` (no other files touched):

1. **Removed** `lastBLEReceiptAt = bleLastEGV` from `attemptBLEWarmArm`.
2. **Tightened doc comments** for `lastAcceptedReadingDate` (warm-arm exception spelled out, with the adapter-dedup citation that makes it safe) and `lastBLEReceiptAt` (only-real-BLE invariant).
3. **Inline rationale** at the warm-arm assignment site explaining what is *and is not* seeded and why.
4. **Defensive-guard comments** in `fireSuccess` and `fireMiss` explaining the static array is non-empty and the guard is a readability anchor for the sync-first pattern.
5. **`setEnabled(false)`** comment noting that clearing `lastAcceptedReadingDate` is acceptable for a debug toggle but should be revisited if the toggle becomes user-facing.

### R7 done criteria

- [ ] On `setEnabled(true)` while `WatchState.shared.bleLastEGVDate` is recent, a `warm_armed` line appears, and the *next live BLE EGV* (different `sequence`, hence different `readingDate`) fires the full success triple — i.e., no `egv_ignored reason=duplicate` line precedes it.
- [ ] On `setEnabled(true)` followed by a WC or HK delivery whose `readingDate` exactly matches `bleLastEGVDate`, an `egv_ignored reason=duplicate` line appears and no haptic fires (warm-arm seeded dedup blocks the echo).
- [ ] After `setEnabled(true)` warm-arm on a fresh process (no prior live BLE arrivals), a fresh WC / HK delivery with a strictly newer `readingDate` arms a relayed cycle and fires `relayed_confirm` (no `ble_recent` rejection because warm-arm did not seed `lastBLEReceiptAt`).
- [ ] Better Stack search across the validation window confirms zero `haptic_fired type=success_1` lines preceded by `egv_ignored reason=duplicate` for the same source — i.e., warm-arm seeding never suppresses a real BLE success.

## R8 — stale-gap-relayed recovery + dedup log enrichment (review pass — landed plan v1.15)

A third external review pass on the R7 worktree (ChatGPT round 4) was largely a "close to bless" with one remaining product-behavior concern around the stale-gap rule applying uniformly to all sources, plus three explicitly non-blocking notes. R8 adopts ChatGPT's recommended option (allow relayed fallback to rearm after a long BLE outage when the relayed reading is itself fresh) with a freshness gate that protects against batched / late relayed payloads, and includes one small telemetry enrichment that aids future debugging of the dedup gate.

### R8 product decision (authoritative)

**Stale-gap rearm on relayed fallback (`gap > staleThreshold`):**

- **BLE source:** strict — confirm only, no rearm. A long-gap BLE EGV is usually the recovery edge of an outage; cadence prediction stays off until the next BLE EGV proves the cycle is stable. Same as pre-R8.
- **Relayed source AND fresh (`receiptDate − readingDate < relayedFreshnessForRearmAfterGap = 30 s`):** rearm cadence on the relayed reading. Fallback mode exists specifically to provide cadence haptics when BLE is unavailable; refusing to rearm after a long BLE outage would force the user to wait for *two* relayed readings (≥ 5 minutes apart) before fallback provided any cadence value.
- **Relayed source AND not fresh (sensor-to-watch latency ≥ 30 s):** strict — confirm only, no rearm. Late HK / WC payloads (batched sync from minutes or hours ago) would predict a wrong "next" cadence based on when the *batch* arrived rather than when the *next sensor reading* will land.

The 30 s freshness gate comfortably covers healthy WC hop latency (typically < 5 s) without admitting old HK batch syncs. If on-device validation shows the gate is too tight or too loose, tune `relayedFreshnessForRearmAfterGap` rather than the policy structure.

### R8 reviewer disposition

| # | Reviewer | Severity claimed | Disposition | Rationale |
|---|---|---|---|---|
| 1 | ChatGPT — `stale_gap` applies to relayed fallback too; first relayed reading after a long BLE outage just confirms but does not rearm, so fallback only restores cadence on the *second* relayed reading | Product call (close-to-bless) | **Adopted ChatGPT's recommended option.** New constant `relayedFreshnessForRearmAfterGap = 30 s`; stale-gap check in `noteEGVReceived` is split by source per the product decision above. New telemetry events `rearm_skipped reason=stale_gap_relayed_not_fresh` and `rearm_after_stale_gap reason=relayed_fresh` (both carry `gap_s` + `reading_age_s`). |
| 2 | ChatGPT — non-blocking #1: dedup log line could include both ages for ordering debug | Non-blocking | **Adopted (small enrichment).** `egv_ignored reason=duplicate` now also carries `last_reading_age_s` (age of the previously-accepted reading, in seconds at receipt time) so analysts can spot ordering anomalies by comparing the two ages on the same log line. Inline comment near the dedup gate also documents the cross-source monotonicity assumption. |
| 3 | ChatGPT — non-blocking #2: `relayed_confirm` may still confuse end users; consider opt-out for user-facing release | Non-blocking | **No change.** Already covered by R6 product decision #5 (different feel by source). Bench-mark on-device validation; revisit before any user-facing rollout per R7 finding #6 follow-up note. |
| 4 | ChatGPT — non-blocking #3: source comments getting long again; trim before upstream PR | Non-blocking | **Deferred.** Active development; same pre-PR cleanup task already noted in R7 finding #7. |
| 5 | ChatGPT — non-blocking #4: pre-existing `R5c —` comment in `WatchState.swift` violates source-comment hygiene | Non-blocking | **Out of scope.** Same as R7 finding #8 — that comment belongs to the watch G7 BLE observer initiative, tracked separately. |

### R8 telemetry contract changes (for analyst awareness)

- **New event:** `rearm_after_stale_gap reason=relayed_fresh gap_s=<int> reading_age_s=<int> source=<wc|hk>` — emitted (informational) when a relayed reading restores cadence after a `gap > staleThreshold` outage. Pairs with the existing `haptic_fired type=relayed_confirm` line that fires immediately before it. Use this to size how often fallback recovers cadence and at what relayed-latency.
- **New `rearm_skipped reason=`:** `stale_gap_relayed_not_fresh` (with `gap_s` + `reading_age_s`). Distinct from `stale_gap` (BLE long-outage path) so analysts can size how many late relayed payloads were correctly suppressed without conflating them with BLE outage recoveries.
- **`egv_ignored reason=duplicate`** now carries `last_reading_age_s=<int>` in addition to `reading_age_s`. Intended for ordering-anomaly debugging if a future source ever reorders deliveries.

### R8 done criteria

- [ ] After ≥ 10 minutes with no accepted EGV, in `.bleAndRelayedFallback` mode: a fresh WC / HK reading (relayed latency < 30 s) emits `haptic_fired type=relayed_confirm` immediately followed by `rearm_after_stale_gap reason=relayed_fresh` and then `haptic_armed phase=ramp` + `haptic_armed phase=miss`.
- [ ] After ≥ 10 minutes with no accepted EGV, in `.bleAndRelayedFallback` mode: a stale relayed reading (relayed latency ≥ 30 s, e.g. an HK batch sync) emits `haptic_fired type=relayed_confirm` followed by `rearm_skipped reason=stale_gap_relayed_not_fresh gap_s=<n> reading_age_s=<m>` — no ramp / miss arm.
- [ ] After ≥ 10 minutes with no accepted EGV: a long-gap BLE EGV emits `haptic_fired type=success_1` (+ companions) followed by `rearm_skipped reason=stale_gap` — pre-R8 behavior preserved for BLE.
- [ ] In normal steady state (no stale gap), neither `rearm_skipped reason=stale_gap_relayed_not_fresh` nor `rearm_after_stale_gap` should appear — both events are stale-gap-recovery-only.
- [ ] `egv_ignored reason=duplicate` log lines now carry both `reading_age_s` and `last_reading_age_s` fields.

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
- [ ] Ramp fires per Cut 4 — **5 s** lead, **seven** beats (see plan § Cut 4 table).
- [ ] Success fires **three** `.success` beats; miss fires **two** `.retry` beats when triggered.
- [ ] Miss fires at `expected + 20 s` if no EGV; cancelled by an EGV arriving in the grace window.
- [ ] No haptics when `isEnabled = false`.
- [ ] No timer leaks across stop / start cycles (verify by toggling off → on → off → on with EGVs in flight).
- [ ] `event=haptic_armed` and `event=haptic_fired` appear in Better Stack with the documented field shape.

### Cut 2 (background spike)

Files modified:
- `Trio Watch App Extension/HapticBeacon.swift` (replace `play(_:label:)` body only — landed plan v1.10).

Done criteria:
- [ ] Spike protocol §5.3 executed for 5 cycles; results recorded in `docs/in-progress/haptic-beacon/haptic-beacon-cut2-spike.md`.
- [ ] Decision per §5.4 (pass / partial / fail) recorded with telemetry citations.

### Cut 3 (phone / HK coverage; Cut 2 gate explicitly deferred per user direction — landed plan v1.11)

Files modified:
- `Trio Watch App Extension/HapticBeacon.swift` — `SourceFilter` enum, persisted `sourceFilter`, `setSourceFilter(_:)`, `lastCycleSource` slot, `accepts(source:under:)` / `shortTag(for:)` / `currentSourceTag()` helpers, source-tagged `armed`/`cancelled`/`fired`/`rearm_skipped`/`haptic_skipped` log lines, new `egv_ignored` and `setSourceFilter` events, `start` now logs `source_filter`.
- `Trio Watch App Extension/WatchState.swift` — `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .healthKit)` at end of `applyHKSnapshot`; `… source: .watchConnectivity` after `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` in `saveComplicationSnapshot`.
- `Trio Watch App Extension/Views/ComplicationDebugView.swift` — `@State hapticBeaconSourceFilter`, init in `.onAppear`, second toggle button. **R6:** label is "Source: BLE only" / "Source: BLE + relayed".

Done criteria:
- [ ] With `Source: BLE only` selected, behavior identical to Cut 1+2 (only BLE EGVs arm cycles).
- [ ] With `Source: BLE + relayed` selected, beacon fires `relayed_confirm` (single click) on phone-relayed / HK-relayed EGVs **only when BLE is stale** (no BLE accept within `bleFreshnessWindow`).
- [ ] `egv_ignored reason=source_filtered` log volume in `.ble` mode roughly matches the number of non-BLE EGVs received during the window.
- [ ] In `.bleAndRelayedFallback` mode with healthy BLE, `egv_ignored reason=ble_recent` lines appear for every WC / HK delivery (precedence working).
- [ ] Narrowing to `.ble` while a wc/hk cycle is armed cancels the in-flight timers and emits `setSourceFilter ... action=cancelled_pending_timers prior_cycle_source=<wc|hk>` followed by either `warm_armed trigger=source_filter_narrow` or `warm_arm_skipped reason=… trigger=source_filter_narrow`.
- [ ] False-miss rate on non-BLE sources documented (subjective + telemetry).

### Cut 4 (richer ramp / success / miss sequences — landed plan v1.12)

Files modified:
- `Trio Watch App Extension/HapticBeacon.swift` only — tuning constants (`rampLeadTime`, step arrays), `successSubTimers` / `missSubTimers`, `successSubTimerFired` / `missSubTimerFired`, extended `cancelAllTimers()` phases.

Done criteria:
- [ ] With beacon enabled, ramp spans **5 s** before expected EGV and delivers **seven** perceptible beats in the § Cut 4 grouping (two click pairs → two start pairs → three notification beats).
- [ ] Success delivers **three** `.success` haptics at ~0 / 200 / 350 ms.
- [ ] Miss delivers **two** `.retry` haptics at ~0 / 300 ms after the grace deadline when no EGV arrives.
- [ ] Better Stack shows new `type=` labels (`success_*`, `retry_*`) and, when interrupted mid-sequence, `haptic_cancelled phase=success_sub|miss_sub`.

## 10. Future considerations: clinical alerts (out of scope, but design-affecting)

This beacon is a debug feature for cadence prediction. The user has flagged that the same haptic surface might later host **user-facing clinical alerts** (impending low, current high, etc.). Clinical alerts are **explicitly out of scope for v1.x** — they have entirely different requirements (value-driven triggers, snooze state, regulatory considerations, possibly critical-alerts entitlement). However, four design decisions are worth making now to avoid expensive refactors later:

### 10.1 Reserved haptic vocabulary

WatchKit ships nine haptic types and they are not all perceptually distinct. Burning the most intense ones on cadence diagnostics would leave clinical alerts with nothing strong enough to differentiate "urgent low" from "missed BLE reading". Reservation list:

| Type | Owner | Use |
|---|---|---|
| `.click` | HapticBeacon | Ramp paired clicks in T-5s window **and** R6 `relayed_confirm` (single quiet click for relayed-source arrivals) |
| `.start` | HapticBeacon | Ramp paired |
| `.notification` | HapticBeacon | Ramp triple finale |
| `.success` | HapticBeacon | BLE-only EGV arrival (×3 beats; R6 product decision: relayed sources do **not** use this) |
| `.retry` | HapticBeacon | Missed expected EGV (×2 beats) |
| `.failure` | **Reserved** | Future: urgent low (most intense type) |
| `.directionUp` | **Reserved** | Future: high glucose alert |
| `.directionDown` | **Reserved** | Future: impending low alert |
| `.stop` | **Reserved** | Future: manual override / dismissal |

This is why §3.1 changes the miss haptic from `.failure` to `.retry` — `.retry` is intense and signals "investigate" without claiming "danger". When clinical alerts arrive, `.failure` will already be free.

### 10.2 Single `play(_:label:)` choke point

Already documented in §3.1. The point is structural: a future `ClinicalAlerter` (sibling type, value-driven) should route haptics through the same delivery path so priority, isEnabled gating, extended-session routing, and telemetry live in one place. Either keep beacon's `play(_:label:)` extractable into a shared `HapticDispatcher`, or have the clinical alerter call `HapticBeacon.shared.play(_:label:)` directly (and rename later if the responsibility split warrants). Either path requires no further beacon changes beyond §5 — just don't add beacon-specific assumptions inside `play(_:label:)`.

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

None — implementation spans Cuts 1–4; remaining validation is on-device / Cut 2 spike per §5.

## Changelog

### v1.15 (2026-05-11 23:08 CET)
- **R8 — stale-gap-relayed recovery + dedup log enrichment (review pass).** Third external review (ChatGPT round 4) on the post-R7 worktree. "Close to bless" with one product-behavior call: pre-R8 stale-gap rule applied uniformly to all sources, so `.bleAndRelayedFallback` mode required *two* relayed readings ≥ 5 minutes apart before fallback restored cadence after a long BLE outage. Authoritative product decision now splits the rule: BLE remains strict (confirm only after long gap); relayed sources may rearm after long gap if the relayed reading itself is fresh (`receiptDate − readingDate < 30 s`); stale relayed payloads (batched HK / late WC) still confirm-only. New constant `relayedFreshnessForRearmAfterGap = 30`. New telemetry events `rearm_after_stale_gap reason=relayed_fresh` (fall-through info) and `rearm_skipped reason=stale_gap_relayed_not_fresh`. New section **"R8 — stale-gap-relayed recovery + dedup log enrichment"** before §7 captures the product decision, 5-row reviewer disposition, telemetry contract changes, and five new done criteria for on-device validation.
  - Adopted ChatGPT non-blocking #1: `egv_ignored reason=duplicate` now carries `last_reading_age_s` in addition to `reading_age_s` for ordering-anomaly debugging. Inline comment near the dedup gate documents the cross-source monotonicity assumption.
  - **§3.1 constants** add `relayedFreshnessForRearmAfterGap`. **§3.1 `noteEGVReceived` pipeline** step 7 split into BLE / relayed-not-fresh / relayed-fresh / no-stale-gap branches.
  - Code-side R8 changes (in `Trio Watch App Extension/HapticBeacon.swift` only): added `relayedFreshnessForRearmAfterGap` constant; restructured stale-gap check in `noteEGVReceived` per the source-split product decision (with inline comment block explaining the policy); dedup log enriched with `last_reading_age_s`; monotonicity-assumption comment added near the dedup gate. See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"R8 — stale-gap-relayed recovery + dedup log enrichment (review pass)" for per-finding evaluation.

### v1.14 (2026-05-11 23:00 CET)
- **R7 — warm-arm invariant tightening (review pass).** Second external review (Claude round 2 + ChatGPT round 3) on the R6 worktree disagreed on the warm-arm path's interaction with dedup / precedence state. Verified ChatGPT's literal blocker against the G7 adapter source (`G7WatchSensorAdapter.swift:578–580` dedups same-`sequence` deliveries before they reach `noteEGVReceived`, so the adapter cannot deliver the same `readingDate` twice via the live BLE path) and sided with Claude on it. Adopted ChatGPT's deeper invariant point: warm-arm should not write `lastBLEReceiptAt` because the warm-arm anchor is a sensor reading time and `lastBLEReceiptAt` is a watch receipt time. New section **"R7 — warm-arm invariant tightening"** before §7 captures the per-finding disposition (9 rows), code changes, and four new done criteria for on-device validation.
  - **§3.1 properties** updated: `lastAcceptedReadingDate` doc gains an explicit warm-arm exception with the adapter-dedup citation; `lastBLEReceiptAt` doc gains an explicit "only real BLE deliveries write this slot" invariant.
  - **§3.1 method docs** updated: `attemptBLEWarmArm` no longer claims to write `lastBLEReceiptAt`; the rationale for what is *and is not* seeded is spelled out at the call site.
  - Code-side R7 changes (in `Trio Watch App Extension/HapticBeacon.swift` only): removed `lastBLEReceiptAt = bleLastEGV` from `attemptBLEWarmArm`; tightened `lastAcceptedReadingDate` / `lastBLEReceiptAt` property doc comments; inline rationale at the warm-arm assignment site; defensive-guard comments in `fireSuccess` / `fireMiss` explaining the static array is non-empty and the guard is a readability anchor (Claude's minor); inline comment on `setEnabled(false)` dedup clearing acknowledging the debug-feature trade-off (ChatGPT R7 medium #2). See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"R7 — warm-arm invariant tightening (review pass)" for per-finding evaluation.

### v1.13 (2026-05-11 22:55 CET)
- **R6 — multi-source safety + UX polish (review pass).** Consolidates Claude + ChatGPT external review of the R5+Cut2+Cut3+Cut4 worktree plus authoritative product decisions on multi-source policy. New section **"R6 — multi-source safety and UX polish"** before §7 captures the five product decisions (BLE-only success, conditional relayed miss-suppression, BLE-priority cadence arming, "BLE + relayed fallback" UI label, distinct relayed haptic feel) and the 13-row fix-list disposition.
  - **§1 Goal** rewritten to reflect BLE-only success triple, new `relayed_confirm` for relayed sources, sync first-beat invariant, and unique ramp labels.
  - **§3.1 Properties** + **method docs** updated for `lastAcceptedReadingDate`, `lastBLEReceiptAt`, `bleFreshnessWindow=360`, new `noteEGVReceived(at:readingDate:source:)` 7-step pipeline, `setSourceFilter` warm-arm reuse, `attemptBLEWarmArm(trigger:)` helper, `cancelAllTimers` / `clearCurrentCycle` split, sync first beat in `fireSuccess`/`fireMiss`, new `fireRelayedConfirm`, `play()` single state-read.
  - **§3.2 BLE call site** signature updated to pass `readingDate`. **§3.3** unchanged. **§6 Cut 3 hooks** rewritten to show `Task { @MainActor in … }` wrappers and `readingDate` plumbing per Claude #1, #2 + ChatGPT blocker #1.
  - **§4.1 telemetry** `type=` union expanded with unique ramp labels and `relayed_confirm`; pre-R6 collapsed labels deprecated. **§4.2** documents `phase=success_sub` / `phase=miss_sub` semantics under sync-first-beat (companion-only). **§4.3** adds `egv_ignored reason=duplicate|ble_recent` and `trigger=` on `warm_armed`. **§4.4** adds `trigger=` on every `warm_arm_skipped`. **§4.5.1** updates miss accounting (`retry_1` is the 1:1 proxy now); **§4.5.2** rewritten for unique ramp labels. **§4.5.3** adds R6 operational queries.
  - **§ Cut 4 ramp table** updated with unique labels. **§9 Cut 3 deliverables** updated for new label / new criterion. **§10.1 vocabulary table** notes `.click` doubles as `relayed_confirm`.
  - Code-side R6 changes (in `Trio Watch App Extension/HapticBeacon.swift` + `WatchState.swift` + `ComplicationDebugView.swift` + `G7WatchSensorAdapter.swift`): added `lastAcceptedReadingDate` / `lastBLEReceiptAt` / `bleFreshnessWindow`; new `noteEGVReceived(at:readingDate:source:)` signature; `egv_ignored reason=duplicate|ble_recent` paths; `fireRelayedConfirm()` + sync-first-beat in `fireSuccess`/`fireMiss`; unique ramp labels; `cancelAllTimers` / `clearCurrentCycle` split; `attemptBLEWarmArm(trigger:)` helper used by `setEnabled(true)` and `setSourceFilter(.ble)`; `SourceFilter.all → .bleAndRelayedFallback` rename with `"all"` raw-value migration; debug button label "BLE + relayed"; `play()` reads `session.state.rawValue` once; WatchState calls wrapped in `Task { @MainActor in … }`. Removed `Cut 4` references from source comments. See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) §"R6 — multi-source safety + UX polish" for per-finding evaluation.

### v1.12 (2026-05-11 22:26 CET)
- **Cut 4 — richer cadence haptics:** `rampLeadTime` 3→**5** s; **seven** ramp sub-steps per § Cut 4 table; triple `.success` via `successSubTimers` (`success_1`…`success_3`); double `.retry` via `missSubTimers` (`retry_1`, `retry_2`). Removes `successTimer`/`successTimerID` pair. `cancelAllTimers()` emits `phase=success_sub|miss_sub` with `pending_count`. §3.1, §4.1–§4.3, §4.5, §4.6, §10.1 table, § Cut 4 narrative, §9 Cut 4 deliverables updated. See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) Cut 4 section.

### v1.11 (2026-05-11 22:15 CET)
- **Cut 3 code deliverable:** Source-filter (`.ble` default, `.all` opt-in) persisted to `UserDefaults`; `setSourceFilter(_:)` cancels in-flight timers when narrowing while a non-BLE cycle is armed. Two new hooks in `WatchState.swift` (`applyHKSnapshot` end / `saveComplicationSnapshot` after data-store save). Per-cycle source tagging: `lastCycleSource` slot drives `source=ble|wc|hk|unknown` on `armed`, `cancelled`, `fired`, and `rearm_skipped` log lines (replaces the hardcoded `source=ble`). New events: `setSourceFilter`, `egv_ignored reason=source_filtered`. `start` event now also carries `source_filter=`. Second toggle button in debug view (`Source: BLE only` / `Source: All`). §4.1, §4.2, §4.3, §4.4 updated; §6 rewritten as "code landed; Cut 2 gate explicitly deferred per user direction." See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) Cut 3 section for the gate-deviation note.

### v1.10 (2026-05-11 22:09 CET)
- **Cut 2 code deliverable:** `play(_:label:)` now prefers `WKExtendedRuntimeSession.notifyUser(haptic:)` when `currentExtendedSession?.state == .running`, else `WKInterfaceDevice.current().play(_:)`. Telemetry: `delivered_via=extended_session` with `session_state`, or `delivered_via=device` with `reason_no_session`. Implementation uses the existing `label` parameter for `type=` fields (plan §5.2 draft used `name(of:)` — equivalent contract). §4.1 example lines updated. §5 notes code landed; §5.3–5.4 spike remains manual. See [`haptic-beacon-impl-log.md`](haptic-beacon-impl-log.md) Cut 2 section.

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
