> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Implementation plan: Watch G7 Direct BLE Observer — Phase 2

**Version:** v1.3
**Status:** Draft
**Created:** 2026-04-25
**Last updated:** 2026-04-25 18:30 CET

**Design reference:** [watch-g7-direct-ble-observer-01-design.md](watch-g7-direct-ble-observer-01-design.md) (v2)
**Synthesis blueprint:** [g7-direct-ble-synthesis-blueprint.md](g7-direct-ble-synthesis-blueprint.md) (v2)
**Prior implementation plan:** [watch-g7-direct-ble-observer-02-implementation-plan.md](watch-g7-direct-ble-observer-02-implementation-plan.md)
**Implementation log:** [watch-g7-direct-ble-observer-03-implementation-log.md](watch-g7-direct-ble-observer-03-implementation-log.md)
**Issue summary:** [g7-ble-build186-issue-summary.md](g7-ble-build186-issue-summary.md) (v1.1) — the authoritative source for Phase B task definitions, pseudocode, and acceptance criteria

Per-version notes live in the [Changelog](#changelog) below.

---

## Context

Build 185 proved the G7 direct BLE observer architecture is correct. 25 successful EGVs were delivered over ~6 hours of overnight operation, including 27 consecutive readings via MOD-E (`registerForConnectionEvents`) background delivery with no foreground activity required. The core mission — reliably observe the G7 session and deliver sustained EGV reads — is proven.

**What build 185 confirmed is working:**

- Persisted identifier retrieval is the dominant successful attach path (`retrieved_identifier`: 158 of 160 connect attempts)
- `registerForConnectionEvents` (MOD-E) is clearly contributing — 36 `peer_connected` events, each triggering a successful attach ladder run at the right moment
- EGV request triggered from `control_notify_enabled` is the mechanism driving all successful reads
- Reconnect backoff, scene semantics, and guarded scan timeout are all behaving correctly

**What build 185 day-two wear showed needs improvement:**

- Three "accessory disconnected" system notifications — consistent with unhandled `willRestoreState`
- After coming off charger, MOD-E stopped firing and session durations became anomalously long
- ~70% of session outcomes are `incomplete/idle` — observer hammers the sensor between G7 re-auth windows
- Parallel connect attempts from rapid scene transitions compound CB pressure
- Double-discovery causes triple `auth_notify_enabled` per cycle and redundant GATT traffic

This plan covers the next phase: observer lifecycle correctness and reliability improvements (Phase B), protocol additions (Phase C), and the watch-side glucose history store (Phase F). Branch surgery and UI work are a separate initiative (`watch-g7-ble-ui-01-impl-plan.md`).

---

## Critical constraint: do not disturb the winning mechanics

The following must not be disturbed by any change in this plan:

1. Persisted identifier retrieval path (`retrieved_identifier` source) — the dominant successful attach mechanism in the field
2. `registerForConnectionEvents` / MOD-E trigger — the mechanism delivering background reads overnight
3. EGV request from `control_notify_enabled` — currently the only cadence trigger producing successful reads

If any change in Phase B or C causes `session_outcome=success` rate to drop overnight, stop immediately. Do not proceed to subsequent phases until the regression is understood and resolved.

---

## State flag reset requirements

Several Phase B tasks introduce new boolean flags and work items. To prevent flags getting stuck, all new per-session state must be reset in every teardown path. The following flags are **per-session** (reset on disconnect, timeout, stop, hardStop, willRestoreState cancel path):

- `connectInFlight`
- `isDiscoveringServices`
- `lastSessionWasSuccess`
- `postEGVBackoffWorkItem`

The following flag is **per-manager-lifecycle** (reset only when the `CBCentralManager` is created, i.e., in `init()`; must NOT be reset in per-session teardown paths):

- `didReceiveWillRestoreState` — describes whether this process launch was a restoration relaunch; resetting it on disconnect or stop would corrupt the `was_restored` signal if `centralManagerDidUpdateState` fires again in the same process lifetime

---

## Scope

- **Phase B:** Observer lifecycle correctness and reliability — six tasks (B0–B5)
- **Phase C:** Protocol additions — backfill (three sub-steps), explicit 0x32 logging
- **Phase F:** Watch-side glucose history store and complication freshness (six independently shippable sub-tasks)

## Out of scope

- Branch surgery and UI corrections — separate initiative (`watch-g7-ble-ui-01-impl-plan.md`)
- `WKExtendedRuntimeSession` — deferred; MOD-E alone is delivering substantial overnight coverage
- Upstream PR preparation — follows after this plan is validated
- `WatchLogger` upstream adaptation (os_log transport) — deferred to PR prep phase
- iPhone-side changes except Phase F6 (WC suppression)

---

## Ship boundaries

| Phase | Description | Shippable alone? | Gate |
|---|---|---|---|
| B0–B3 | Lifecycle correctness + core reliability | Yes (minimum unit) | Deploy, run overnight, verify hard gates met |
| B4 | MOD-E re-registration (behaviour change) | Yes — isolated from B5 | Separate build from B5 if possible; separate commit minimum |
| B5 | Consecutive-failure counter (pure observability) | Yes | Separate build from B4 if possible; separate commit minimum |
| C | Protocol additions | Yes | Deploy, verify no regression vs B baseline |
| F1+F2 | History store model + BLE inserts | Yes (minimum unit) | Deploy, verify store persists correctly |
| F3 | WC and HK inserts | Yes | Deploy, verify multi-source merge |
| F4 | Chart wired to history store | Yes | Deploy, verify bootstrap precedence rule |
| F5 | Local complication reload | Yes | Deploy, verify complication freshness |
| F6 | Phone suppression | Last — phone-side changes | Validate all F1-F5 first; requires tighter protocol definition below |

**Go/no-go rule:** if any phase causes overnight success rate to drop below the build 185 baseline (25 successes over ~6h, ~100% of MOD-E cycles), stop and investigate before the next phase.

**B4 and B5 must be isolated into separate commits and ideally separate build iterations.** B4 changes CB registration behaviour; B5 adds a counter with no behaviour change. Grouping them would make it impossible to attribute any changes in MOD-E delivery to B4 specifically.

---

## Shared conventions

- All new log events: `event=g7_ble_*` prefix, `key=value` format, emitted via `WatchLogger`
- All new constants: named and placed with existing constants in the observer file
- No `.xcodeproj` or `project.pbxproj` edits — human step
- No reads from `docs/in-progress/watch-direct-ble-cgm/` — forbidden folder
- Forbidden: invent byte offsets for any BLE protocol parsing — stub with TODO instead
- No second dedup framework — any dedup additions must remain thin and consistent with the existing `sourcePriority` rule already in `TrioComplicationDataStore`

---

## Phase B: Observer lifecycle correctness and reliability

**Note:** Phase B was two tasks in v1.0. It is seven tasks in v1.2 following field findings from build 185 day-two wear. The issue summary (`g7-ble-build186-issue-summary.md` v1.1) is the authoritative source for task pseudocode and detailed acceptance criteria. This plan provides sequencing, ship gates, and success criteria for the phase as a whole.

**Ship gate:** B0–B3 are the minimum shippable unit.
**Rollback:** each task is a separate commit; revert individually.

### Phase success criteria

**Hard gates** (deterministic, measurable on first morning log read after overnight run):
- `event=g7_ble_will_restore_state` appears on restoration relaunches; `event=g7_ble_central_state was_restored=false` appears on cold launches — both are correct, neither is a bug
- `auth_notify_enable_requested` appears exactly once per session in logs — not 2-3
- `connect_skipped reason=already_connecting` appears when rapid scene transitions would have caused parallel connects
- `service_discovery_skipped reason=already_in_progress` appears on duplicate discovery attempts
- `session_outcome=success` rate per MOD-E `peer_connected` event no worse than build 185

**Expected outcomes** (not hard gates — depend on many factors; evaluate over multiple overnight runs):
- "Accessory disconnected" system notifications stop appearing (depends on OS behaviour and whether B0 correctly explains all three notifications)
- `incomplete/idle` sessions per successful EGV cycle drops from ~3-4 to ~1 or fewer
- `post_egv_backoff_cancelled reason=connection_event` appears before nearly every successful attach

### Task B0 — `willRestoreState` implementation

**Problem:** `centralManager(_:willRestoreState:)` is not logged anywhere in the build 185 data. Without correct handling, CB preserves its own pending `connect(DXCM08)` from the prior session while our code also issues a fresh one on central power-on, producing duplicate `didConnect`, triple `auth_notify_enabled`, and the "accessory disconnected" OS notification when DXCM08 disconnects. Plausible primary cause of all three notifications in build 185 day-two wear.

`willRestoreState` fires on restoration relaunches only — not on every cold launch. Absence on a cold launch is correct.

See `g7-ble-build186-issue-summary.md` §Issue 1 for full pseudocode.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Key requirements:**
  - Add `private var didReceiveWillRestoreState = false` — initialized to `false` in `init()`; set to `true` inside `willRestoreState` when the callback fires. Do NOT reset in teardown paths — see State flag reset requirements above
  - Implement `centralManager(_:willRestoreState:)`: log `event=g7_ble_will_restore_state`; set `didReceiveWillRestoreState = true`
  - For each restored peripheral: **cancel if `peripheral.state != .connected`** (i.e., cancel on `.connecting`, `.disconnected`, `.disconnecting`). Do NOT cancel if `.connected` — that tears down a live session. Log `event=g7_ble_restore_cancelled` or `event=g7_ble_restore_skipped_cancel reason=already_connected` accordingly
  - Do NOT issue `connect()` in this callback — let `centralManagerDidUpdateState` drive the attach ladder
  - In `centralManagerDidUpdateState`: log `event=g7_ble_central_state state=<n> was_restored=\(didReceiveWillRestoreState)` — makes cold vs restoration launch distinguishable in BetterStack

**Cancel policy (authoritative):** cancel if `peripheral.state != .connected`. This covers `.connecting` (CB preserved a pending attempt), `.disconnected` (no-op, safe), and `.disconnecting`. Do NOT cancel `.connected`. This is the policy in both the task text and the risk table — any prior wording saying "only `.connecting`" was incorrect.

### Task B1 — In-flight connect guard

**Problem:** Rapid `scenePhase=active` transitions (wrist raise, notifications) each trigger the full attach ladder, producing multiple simultaneous `connect(DXCM08)` calls. Observed as 3 simultaneous `connect_attempt` events within 1 second.

See `g7-ble-build186-issue-summary.md` §Issue 2 for full pseudocode.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Key requirements:**
  - Add `private var connectInFlight = false` (per-session flag — see reset list above)
  - Guard at top of connect function on `!connectInFlight` — log `event=g7_ble_connect_skipped reason=already_connecting` and return if true
  - Set `connectInFlight = true` immediately after the guard passes
  - Before calling `central.connect(peripheral, options:)`: if `peripheral.state == .connecting`, call `central.cancelPeripheralConnection(peripheral)` as defensive cleanup for stale pending connects. Do NOT call cancel if state is `.connected` — that tears down a live session
  - Clear `connectInFlight` in: `didConnect`, `didFailToConnect`, `didDisconnect`, any connect-timeout path, `stop()`, `hardStop()`

### Task B3 — Explicit `isDiscoveringServices` flag

**Problem:** Both `centralManager(_:didConnect:)` and `connectionEventDidOccur(.peerConnected)` trigger service discovery, producing triple `auth_notify_enabled` per cycle.

**Note on naming:** B3 matches the issue summary ordering, which places post-success sleep (B2) after these cheaper correctness fixes.

See `g7-ble-build186-issue-summary.md` §Issue 4 for full pseudocode.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Key requirements:**
  - Add `private var isDiscoveringServices = false` (per-session flag — see reset list above)
  - Guard at entry of service-discovery trigger function on `!isDiscoveringServices` — log `event=g7_ble_service_discovery_skipped reason=already_in_progress` and return
  - Set `isDiscoveringServices = true` immediately before calling `peripheral.discoverServices(...)`
  - **Do NOT use `peripheral.services == nil`** as the guard — unreliable; can be non-nil from cached prior-connection state
  - **Clear `isDiscoveringServices` only on full teardown paths** (disconnect, failure, `stop()`, `hardStop()`). Do NOT clear it on mid-session phase transition to characteristic discovery — late duplicate CB callbacks can still arrive after that point and would reopen the race. **This is intentional:** Phase B treats service discovery as a one-shot session gate. There is no legitimate need for a second discovery pass within the same connection lifecycle. If that assumption ever changes, this clearing policy must be explicitly revisited.

### Task B2 — Post-success sleep

**Problem:** After every successful EGV delivery (CBError 7), the observer immediately restarts its reconnect loop, issuing ~3-4 failed `connect()` calls per inter-window period (~5 minutes). The G7's re-auth window is ~20-30s wide every ~300s. All inter-window connect attempts fail.

See `g7-ble-build186-issue-summary.md` §Issue 3 for full pseudocode.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Key requirements:**
  - Add `private var postEGVBackoffWorkItem: DispatchWorkItem?` (per-session — see reset list)
  - Add `private var lastSessionWasSuccess = false` (per-session — reset to false on each new `connect()` call, set true when `egvCount > 0` at teardown)
  - In disconnect handler after session outcome logging: if `lastSessionWasSuccess`, schedule `postEGVBackoffWorkItem` for 290s; otherwise call existing `scheduleReconnect(reason: "disconnect")`
  - Work item body must include `guard self?.isRunning == true else { return }` before `kickAttachIfNeeded` — prevents racey late wakeups in a stopped observer
  - In `connectionEventDidOccur(.peerConnected)`: cancel `postEGVBackoffWorkItem`, nil it, and log `event=g7_ble_post_egv_backoff_cancelled reason=connection_event` before proceeding with attach
  - Also cancel in `stop()` and `hardStop()`

### Task B5 — Consecutive-failure counter (pure observability)

**Problem:** After many consecutive `connect_failed` events, session durations escalated from ~22s to 75-217s. Mechanism unknown. This is instrumentation only — no behaviour change.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** Add `private var consecutiveConnectFailures = 0`. Increment on each `didFailToConnect` / connect-timeout. Reset to 0 on each `didConnect` success. Log on each failure: `event=g7_ble_connect_failed reason=timeout consecutive_failures=<n> duration_ms=<n>`
- **No behaviour change.** Counter is logged only. Do not implement CB recreation.
- **Acceptance:** `consecutive_failures` visible in BetterStack; can be correlated with `duration_ms` to test whether session duration escalates with failure count.

### Task B4 — MOD-E re-registration on foreground-active + absence detector

**This is a behaviour change, not pure instrumentation.** Ship in a separate build from B5 so MOD-E delivery changes can be attributed to B4 specifically.

**Problem:** MOD-E fired reliably overnight but stopped after charger wake. Mechanism unknown — registration staleness and CB delivery suppression are both plausible. This task is an empirical intervention, not a confirmed fix.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Changes:**
  - In `handleForegroundActiveEntry`, call `centralManager.registerForConnectionEvents(options: [...])` with `advertisementServiceUUID` and `cgmServiceUUID`. Log `event=g7_ble_connection_events_registered reason=foreground_active`. Whether re-registering updates an existing registration or creates a duplicate registration is not confirmed in Apple documentation — treat this as an experiment
  - Add `private var lastConnectionEventReceivedAt: Date?` — set in `connectionEventDidOccur`
  - In the `postEGVBackoffWorkItem` body (B2), if the 290s timer fires without being cancelled by MOD-E, log: `event=g7_ble_connection_event_absent last_event_age_s=<n>`
- **Acceptance (empirical — measure, don't assert):**
  - `connection_events_registered reason=foreground_active` appears on each wrist raise / screen-on
  - `connection_event_absent` vs `post_egv_backoff_cancelled reason=connection_event` ratio over 24h gives the real MOD-E reliability rate
  - Whether B4 improves that ratio is the experiment — log it and report

---

## Phase C: Protocol additions

**Ship gate:** yes — entirely additive, no existing behaviour modified
**Rollback:** revert commits, regenerate patch 12

**Success criteria:**
- No regression in `session_outcome=success` rate vs Phase B baseline
- `g7_ble_sequence_gap detected=true` appears when consecutive sessions have non-consecutive sequences
- `g7_ble_backfill_requested` appears on small gaps (if C1b reached)
- `g7_ble_control_payload_unhandled opcode=0x32` appears consistently after EGV delivery

### Task C1 — Backfill (three sub-steps)

Proceed to each sub-step only if the prior sub-step produces clean, unambiguous device-log results.

#### C1a — Gap detection and logging only

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** Add `private var lastDeliveredSequence: UInt16?` — updated after each successful EGV snapshot save. After each successful EGV parse, compare sequences:

````swift
if let last = lastDeliveredSequence, newSequence > last + 1 {
    let gap = Int(newSequence) - Int(last) - 1
    log("event=g7_ble_sequence_gap detected=true gap_size=\(gap) last_seq=\(last) new_seq=\(newSequence)")
}
lastDeliveredSequence = newSequence
````

- **Acceptance:** `sequence_gap detected=true` appears when consecutive sessions have non-consecutive sequence numbers. Values match expected gaps from build 185 log analysis.

#### C1b — Backfill request on small gaps

Proceed only after C1a confirms gap detection is correct in device logs.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** After detecting a gap of 1-3, write opcode `0x59` to the control characteristic (same write-with-response pattern as `0x4E`). Reference DiaBLE `DexcomG7.swift` and G7SensorKit `G7BackfillMessage.swift` for exact payload format. Log: `event=g7_ble_backfill_requested gap_size=<n>`. Skip gaps > 3: `event=g7_ble_backfill_skipped reason=gap_too_large gap_size=<n>`.
- **Constraint:** If the `0x59` payload format is ambiguous in reference files, log `event=g7_ble_backfill_request_stubbed reason=payload_format_unclear` and stop. Do not guess at format.
- **Acceptance:** `g7_ble_backfill_requested` appears. Backfill packets arrive on characteristic F8083536.

#### C1c — Backfill parse and store

Proceed only after C1b confirms `0x59` triggers a response on the backfill characteristic.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** Parse backfill packets using G7SensorKit `G7BackfillMessage.swift` byte layout. For each parsed reading: skip if `readingDate` older than 15 minutes (`event=g7_ble_backfill_skipped reason=too_old age_s=<n>`); otherwise save `TrioComplicationSnapshot` with `source: .g7DirectBLE` (`event=g7_ble_backfill_saved glucose=<n> sequence=<n> age_s=<n>`).
- **Constraint:** If byte offsets are ambiguous, stub with `// TODO: parse backfill payload` and `event=g7_ble_backfill_parse_stubbed`. Do not invent byte offsets.
- **Acceptance:** `g7_ble_backfill_saved` appears with correct glucose values and historical reading dates.

### Task C2 — Opcode 0x32 explicit logging

**Problem:** Control characteristic delivers `opcode=0x32` packets (20 bytes) consistently after EGV delivery. Currently silently dropped.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:**

````swift
case 0x32:
    log("event=g7_ble_control_payload_unhandled opcode=0x32 byte_count=\(data.count) preview=\(data.prefix(8).hexadecimalString)")
````

- **Acceptance:** `g7_ble_control_payload_unhandled opcode=0x32` appears in BetterStack after EGV delivery. Log only — no parsing, no action.

---

## Phase F: Watch-side glucose history store and complication freshness

**Ship gate:** F1+F2 are the minimum shippable unit. F3-F6 each independently shippable after that.
**Rollback:** each sub-task is a separate commit; revert individually.

**No second dedup framework.** Source-priority logic added here must remain thin and consistent with the existing `sourcePriority` rule in `TrioComplicationDataStore`. Do not introduce a parallel arbitration layer.

### Task F1 — `GlucoseHistoryEntry` model and merge store

**Problem:** No unified 24h glucose history exists on the watch. Three sources write independently. BLE readings accumulated overnight disappear on next app open.

- **Files:** new `Trio Watch Shared/GlucoseHistoryEntry.swift`, `Trio Watch Shared/TrioComplicationDataStore.swift`
- **Change:**

````swift
struct GlucoseHistoryEntry: Codable {
    let readingDate: Date          // sensor timestamp — primary merge key
    let glucose: Int               // mg/dL
    let trend: TrendDirection?     // nil if HK-only
    let trendRate: Double?         // BLE only (mg/dL/min)
    let algorithmState: Int?       // BLE only; non-6 = warmup/uncertain → suppress in chart
    let displayOnly: Bool?         // BLE only; true = uncertain → suppress in chart
    let sequence: Int?             // BLE only; gap detection
    var sources: Set<GlucoseSource>
}

enum GlucoseSource: String, Codable {
    case ble
    case watchConnectivity
    case healthKit
}
````

Merge logic in `TrioComplicationDataStore`:
- BLE: match on `sequence` (exact). If match, union `sources`, fill nil BLE-native fields. BLE is authoritative for `algorithmState`, `displayOnly`, `trendRate`.
- WC or HK: match on `readingDate` within ±2 seconds. (±2s is empirically derived from observed max divergence between BLE `reading_epoch` and WC `reading_date_epoch_seconds` for the same physical reading.)
- No match: insert new entry.
- Cap at 288 entries (24h at 5-min cadence), drop oldest on overflow.
- Persist to App Group container alongside `TrioComplicationSnapshot`.

- **Acceptance:** History store persists and reloads correctly across app launches. Empty store on first launch does not crash.
- **Notes:** ±2s merge window is tunable. If duplicates appear in testing, tighten to ±1s.

### Task F2 — Wire BLE inserts to the history store

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** After each successful EGV parse and snapshot save, insert/merge into history store. Log: `event=g7_ble_history_merged source=ble sequence=<n> action=<inserted|merged>`
- **Acceptance:** After an overnight BLE run, history store contains the delivered readings, visible on next app open without a WC transfer.

### Task F3 — Wire WC and HK inserts to the history store

- **Files:** `WatchState.swift` (WC handler and HK handler)
- **Change:** After existing WC `didReceiveUserInfo`/`didReceiveApplicationContext` handling, insert/merge each reading from the `glucoseValues` array. After existing HK observer callback, insert/merge new readings as lowest-priority source. Log: `event=g7_history_merged source=<watchConnectivity|healthKit> reading_epoch=<n> action=<inserted|merged>`
- **Acceptance:** History store accumulates readings from all three sources. WC gaps not covered by BLE are filled.

### Task F4 — Wire chart to history store

- **Files:** chart view file (identify by searching codebase — likely `GlucoseChartView.swift` or equivalent)
- **Change:** Wire chart to read from App Group history store instead of `WatchState.glucoseValues`. `WatchState.glucoseValues` remains as in-memory mirror for other consumers.

**Bootstrap precedence rule (required):** Use the history store as the primary source. For any time range newer than the store's most recent `readingDate`, supplement with `WatchState.glucoseValues` entries that fall in that gap. This ensures no stale-store gap appears when the app opens and WC has delivered readings more recently than the last BLE cycle, while still showing overnight BLE data for older time ranges. When the store is fully empty, use `WatchState.glucoseValues` exclusively.

- **Mandatory:** test the empty-store path explicitly before shipping — chart must render without crashing when store is empty.
- Use `algorithmState` and `displayOnly` on each entry to suppress warmup/uncertain readings, matching phone chart behaviour.
- **Acceptance:** Chart populates on app open without a WC transfer, showing overnight BLE data. Chart renders correctly when store is empty. Chart shows no gap when WC data is fresher than the store.
- **Notes:** Highest-risk task in Phase F. Test all three bootstrap states (empty store, fully populated store, partially populated stale store) before shipping.

### Task F5 — Budget-free complication reload on fresh BLE data

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
- **Change:** After writing to the history store and saving the `TrioComplicationSnapshot`, call:

````swift
WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)
````

This is a local call — no transfer budget consumed. Verify this call already fires after WC and HK writes — if not, add it there too.

- **Acceptance:** Complication updates within ~1 second of BLE EGV receipt, without a phone-side transfer.

### Task F6 — Phone suppression of redundant complication transfers

**Note:** Only task in this plan that touches the iPhone target. Defer if F1-F5 are not yet stable.

**Problem:** When BLE already delivered a reading to the watch, the phone's next `transferCurrentComplicationUserInfo` is redundant and consumes transfer budget.

**Protocol definition (required before implementation):**

- **Dedup key:** `reading_epoch` — the sensor timestamp (seconds since sensor pairing), not wall clock. This is the stable identifier for a specific G7 reading regardless of which path delivered it.
- **Message payload:** `["event": "ble_egv_watch_confirmed", "reading_epoch": N]`
- **Validity window:** the phone must receive the confirmation within 10 minutes of the `reading_epoch`. Confirmations older than 10 minutes are expired and must not trigger a skip — a stale confirmation must not suppress a genuinely new reading.
- **Skip condition:** phone skips the next `transferCurrentComplicationUserInfo` only if all of these hold: (a) confirmation received within validity window, (b) pending transfer's `reading_epoch` ≤ confirmed `reading_epoch`, (c) the skip has not already been consumed this cycle. One-shot per confirmation — do not suppress subsequent transfers.
- **Out-of-order handling:** if the confirmation arrives after the phone has already sent the transfer for that `reading_epoch`, the confirmation is a no-op. The skip token is consumed only on the first suppression attempt.
- **Critical:** App Group `UserDefaults` cannot cross the device boundary. This coordination must go through WatchConnectivity only.

- **Files:** `Trio Watch App Extension/G7DirectBLEObserver.swift` (watch, sends message), `Trio/AppleWatchManager.swift` (phone, receives message)
- **Change:**
  - **Watch side:** after successful BLE EGV snapshot save, send the message via `sendMessage` if phone reachable, `transferUserInfo` as fallback.
  - **Phone side:** on receipt, validate the confirmation is within the 10-minute validity window. If valid, store `confirmedReadingEpoch` and a `confirmationReceivedAt` timestamp. In the next `transferCurrentComplicationUserInfo` call, apply the skip condition check above.
- **Acceptance:** `ble_egv_watch_confirmed` send events appear in BetterStack. Phone-side complication transfer count decreases on BLE-delivered cycles. No cases of fresh readings being incorrectly suppressed.

---

## What NOT to do yet

- **CB central manager recreation:** plausible hypothesis for the session duration escalation but mechanism unconfirmed. Implement B5 (failure counter) first and gather data across 2-3 builds before considering this medium-risk change.
- **`CBConnectPeripheralOptionNotifyOnDisconnectionKey: false`:** treats the symptom of the "accessory disconnected" notification, not the cause. If B0 is correctly implemented, the notification should stop. Do not add this until B0 is validated.
- **CB scan fallback after N failures:** scan is unlikely to find DXCM08 while it is in an active session with the Dexcom app. Complexity not justified without evidence.

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| B0: cancel `.connected` peripheral tears down live session | Low | State branch required — cancel only if `peripheral.state != .connected`; see task definition |
| B0: `willRestoreState` not called on all restoration relaunches | Low | `was_restored=false` in `centralManagerDidUpdateState` makes cold-launch absence visible without alarming |
| B0: `didReceiveWillRestoreState` reset incorrectly on teardown | Low | Per-manager-lifecycle flag — reset only in `init()`; see State flag reset requirements |
| B1: `connectInFlight` flag gets stuck on missed clear path | Low | Explicit per-session reset list; agent must implement all locations |
| B3: `isDiscoveringServices` cleared too early, race reopens | Low | Clear only on full teardown/disconnect — NOT on mid-session phase transition |
| B4: re-registration creates duplicate connection-event callbacks | Low | Treat as hypothesis; isolated build; measure via `connection_event_absent` rate |
| B2: post-success sleep misses a G7 window if MOD-E doesn't fire | Low | 290s fallback timer fires; worst case one missed cycle |
| C1: backfill `0x59` payload format ambiguous | Medium | Three sub-steps; stub C1b if unclear |
| F4: empty-store fallback not triggered in testing | Medium | Test all three bootstrap states before shipping |
| F4: stale store creates chart gap vs fresher WC data | Medium | Bootstrap precedence rule required — see task definition |
| F6: stale confirmation suppresses fresh reading | Low | 10-minute validity window + dedup key + one-shot semantics |
| F6: out-of-order arrival causes no-op suppression | Low | Out-of-order policy defined — no-op if transfer already sent |
| ±2s merge window produces duplicates | Low | Tighten to ±1s and retest if observed |

---

## Hypotheses and expectations

- B0 (`willRestoreState`) should eliminate the "accessory disconnected" notifications and the triple `did_connect` / triple `auth_notify_enabled` pattern — this is the plausible primary cause; validate empirically
- B1 (`connectInFlight`) should eliminate simultaneous parallel connect attempts
- B3 (`isDiscoveringServices`) combined with B0 should reduce `auth_notify_enable_requested` to exactly once per session
- B2 (post-success sleep) should reduce `incomplete/idle` from ~70% to ~10-15% of all outcomes; `post_egv_backoff_cancelled reason=connection_event` appearing before nearly every successful cycle confirms MOD-E is the primary trigger
- B5 (failure counter) is pure observation — no behavioural change expected; outcome is data for 2-3 build comparison
- B4 (MOD-E re-registration) is an experiment; outcome unknown; measured via `connection_event_absent` ratio
- `auth_transition` and `fallback_timer_330s` cadence triggers may remain dormant — `control_notify_enabled` is the only cadence trigger producing results given the current connect/disconnect-per-cycle pattern; this is expected
- Backfill will recover 1-3 missed readings per gap window; will not close multi-hour gaps where the Dexcom app went quiet
- History store will make the chart usable on first open without a WC transfer, showing overnight BLE data

---

## Observability improvements from Phase B

**State restoration vs cold launch (per startup):**
````sql
SELECT
    countIf(raw LIKE '%was_restored=true%') AS restoration_starts,
    countIf(raw LIKE '%was_restored=false%') AS cold_starts
FROM (... UNION ALL ...)
WHERE build = '186' AND platform = 'watchos'
  AND raw LIKE '%g7_ble_central_state%'
````

**MOD-E reliability rate:**
````sql
SELECT
    countIf(raw LIKE '%post_egv_backoff_cancelled reason=connection_event%') AS mode_cancels,
    countIf(raw LIKE '%connection_event_absent%') AS mode_absent,
    mode_cancels / (mode_cancels + mode_absent) AS mode_e_reliability
FROM (... UNION ALL ...)
WHERE build = '186' AND platform = 'watchos'
````

**Parallel connect guard firing rate:**
````sql
SELECT count() FROM ...
WHERE raw LIKE '%connect_skipped reason=already_connecting%'
````

**Consecutive failure vs session duration (from B5):**
````sql
SELECT
    JSONExtractUInt(raw, 'consecutive_failures') AS failures,
    toStartOfHour(dt) AS hour,
    count() AS occurrences
FROM ...
WHERE raw LIKE '%g7_ble_connect_failed%'
GROUP BY failures, hour
ORDER BY hour, failures
````

---

## Implementation log

**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`
**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`
**Executed:** 2026-04-25

### B0 — `willRestoreState` implementation (commit `7f7bc2a45`)

**What was done:**
- Added `private var didReceiveWillRestoreState = false` as a stored property (per-manager-lifecycle flag, not reset in per-session teardown). Comment documents the lifecycle constraint.
- Replaced the existing `willRestoreState` implementation (which was incorrectly assigning `activePeripheral` and calling `discoverServicesIfNeeded` for connected peripherals — the primary cause of triple `did_connect` / triple `auth_notify_enabled` in build 185). New implementation: sets `didReceiveWillRestoreState = true`, logs `event=g7_ble_will_restore_state restored_count=N`, and for each restored peripheral cancels via `cancelPeripheralConnection` if `peripheral.state != .connected`. Does NOT issue `connect()`.
- Updated `centralManagerDidUpdateState` log from `event=g7_ble_lifecycle action=central_state state=N` to `event=g7_ble_central_state state=N was_restored=\(didReceiveWillRestoreState)` to make cold vs restoration relaunches distinguishable in BetterStack.

**Acceptance:** Static review confirms cancel policy (state != .connected guard), no connect() in callback, and was_restored= log. Device-level acceptance (willRestoreState fires on restoration, was_restored=false on cold launch) requires a build.

### B1 — In-flight connect guard (commit `2c39f18f9`)

**What was done:**
- Added `private var connectInFlight = false` stored property.
- Added `guard !connectInFlight` at top of `connect()`, logging `event=g7_ble_connect_skipped reason=already_connecting source=\(source)` and returning. Sets `connectInFlight = true` immediately after the guard.
- Added defensive `cancelPeripheralConnection` before `centralManager.connect()` when `peripheral.state == .connecting`, logging `event=g7_ble_stale_connect_cancelled`.
- Cleared `connectInFlight = false` in: `centralManager(_:didConnect:)`, `centralManager(_:didFailToConnect:)`, `centralManager(_:didDisconnectPeripheral:)`, the connect-timeout work item body, and `hardStopOnQueue()`.

**Acceptance:** Static review confirms all clear paths. The timeout path explicitly clears before `cancelPeripheralConnection` (which would trigger `didDisconnectPeripheral` — double-clear is safe). Device-level acceptance (connect_skipped appears on rapid scene transitions) requires a build.

### B3 — Explicit `isDiscoveringServices` flag (commit `8a3641dd7`)

**What was done:**
- Added `private var isDiscoveringServices = false` stored property. Comment documents one-shot session gate intent and explains why `peripheral.services == nil` is not used.
- Added `guard !isDiscoveringServices` at entry of `discoverServicesIfNeeded()`, logging `event=g7_ble_service_discovery_skipped reason=already_in_progress peripheral_id=...` and returning. Sets `isDiscoveringServices = true` before `peripheral.discoverServices(nil)`.
- Cleared `isDiscoveringServices = false` in: `centralManager(_:didFailToConnect:)`, `centralManager(_:didDisconnectPeripheral:)`, and `hardStopOnQueue()`. NOT cleared on mid-session phase transition (characteristics discovered) — per plan, this is intentional to prevent late duplicate CB callbacks from reopening the race.

**Acceptance:** Static review confirms guard placement, true-before-discoverServices, and teardown-only clearing. Device-level acceptance (auth_notify_enable_requested exactly once per session) requires a build.

### B2 — Post-success sleep (commit `f1d1f4944`)

**What was done:**
- Added `private var postEGVBackoffWorkItem: DispatchWorkItem?` and `private var lastSessionWasSuccess = false`.
- In `connect()`: reset `lastSessionWasSuccess = false` and cancel/nil any lingering `postEGVBackoffWorkItem` (covers the case where a new connect overlaps with a scheduled backoff).
- In `centralManager(_:didDisconnectPeripheral:)`: set `lastSessionWasSuccess = sessionEGVCount > 0` after session outcome logging (while `sessionEGVCount` is still valid). If true: schedule `postEGVBackoffWorkItem` with 290s delay, log `event=g7_ble_post_egv_backoff_scheduled delay_s=290`. Work item body uses `guard let self, !self.isHardStopped else { return }` as the stop guard. If false: call existing `scheduleReconnect(reason: "disconnect")`.
- In `connectionEventDidOccur(.peerConnected)`: cancel and nil `postEGVBackoffWorkItem` only when it is non-nil, then log `event=g7_ble_post_egv_backoff_cancelled reason=connection_event`. Guard on non-nil prevents inflating the MOD-E reliability metric with spurious cancel events on cycles where no backoff was scheduled.
- In `hardStopOnQueue()`: cancel and nil `postEGVBackoffWorkItem` before `cancelTransientTimers()`.

**Deviation from pseudocode:** The issue summary pseudocode logs `post_egv_backoff_cancelled` unconditionally. We log only when the work item was actually non-nil. This is a deliberate improvement to keep the BetterStack ratio (`mode_cancels / (mode_cancels + mode_absent)`) accurate.

**Acceptance:** Static review confirms all cancel paths, isHardStopped guard, and metric accuracy. Device-level acceptance (post_egv_backoff_scheduled after each success, post_egv_backoff_cancelled before next successful attach, incomplete/idle drop) requires overnight build.

---

## Changelog

### v1.3 (2026-04-25)

Third ChatGPT review of v1.2. Four small fixes applied; no structural changes.

1. **B0 wording clarified.** "set in `init()`" was ambiguous — could be read as "set to `true` in `init()`." Now reads: "initialized to `false` in `init()`; set to `true` inside `willRestoreState`."

2. **B3 one-shot intent documented.** Added explicit statement: "This is intentional — Phase B treats service discovery as a one-shot session gate. There is no legitimate need for a second discovery pass within the same connection lifecycle. If that assumption ever changes, this clearing policy must be revisited." Prevents a future reader from treating the sticky flag as a bug.

3. **Task count corrected.** Scope section said "seven tasks (B0–B5 + C2 ordering note)" — B0–B5 is six tasks, and C2 lives in Phase C, not Phase B. Fixed to "six tasks (B0–B5)."

4. **B4/B5 ship boundary made consistent.** Table previously said "can follow B4 or ship simultaneously" for B5, contradicting the text's stricter guidance. Both rows now say "separate build if possible; separate commit minimum."

### v1.2 (2026-04-25)

Second ChatGPT review of v1.1 identified seven issues. All seven were agreed with and incorporated.

**Fixes applied:**

1. **`didReceiveWillRestoreState` lifecycle corrected.** Removed from the per-session reset list. Now documented as a per-manager-lifecycle flag — reset only in `init()`, not on disconnect/timeout/stop. Resetting it in per-session teardown paths would corrupt the `was_restored` signal if `centralManagerDidUpdateState` fires again in the same process lifetime.

2. **B0 cancel policy contradiction resolved.** v1.1 had "cancel if `state != .connected`" in the task text but "only if `.connecting`" in the risk table. The task text is correct and the risk table was wrong. Policy is now stated once, consistently: cancel if `peripheral.state != .connected` (covers `.connecting`, `.disconnected`, `.disconnecting`). Do NOT cancel `.connected`.

3. **B3 reset guidance tightened.** Removed "clear on clean phase transition to characteristics" — too risky because late duplicate CB callbacks can arrive after that transition and reopen the race. `isDiscoveringServices` now clears only on full teardown paths (disconnect, failure, stop, hardStop).

4. **B4 isolated from B5 in ship plan.** B4 changes CB registration behaviour; B5 is pure observability. Now in separate rows in the ship boundaries table with an explicit note that they must be in separate builds to attribute MOD-E delivery changes to B4 specifically.

5. **Phase success criteria split into hard gates and expected outcomes.** "Accessory disconnected notifications stop" and "incomplete/idle drops to ~1" are now explicitly labelled expected outcomes, not hard gates. Hard gates are deterministic events visible on the first morning log read.

6. **F4 bootstrap precedence rule added.** New "Bootstrap precedence rule" paragraph defines behaviour when the store is partially populated and stale while fresher in-memory/WC data exists. Three bootstrap states now explicitly listed for testing.

7. **F6 protocol definition added.** Concrete protocol now defines: dedup key (`reading_epoch` = sensor timestamp), 10-minute validity window with expiry, one-shot skip semantics, and out-of-order arrival handling.

### v1.1 (2026-04-25)
Phase B completely replaced based on field findings from build 185 day-two wear. Seven tasks added (B0-B5 + C2). Issue summary referenced as authoritative source for task pseudocode. State flag reset requirements section added. "What NOT to do yet" section added. First ChatGPT review incorporated.

### v1.0 (2026-04-25)
Initial Phase 2 implementation plan. Phase B had 2 tasks. Phases C and F introduced. Branch surgery and UI work separated to `watch-g7-ble-ui-01-impl-plan.md`.