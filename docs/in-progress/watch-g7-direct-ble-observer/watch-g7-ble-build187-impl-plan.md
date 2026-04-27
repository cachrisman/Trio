# Implementation plan: Build 187 / 188

**Version:** v1.10
**Created:** 2026-04-26
**Last updated:** 2026-04-27 11:52 CEST
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`

---

## Build 187 — SHIPPED ✅

All tasks complete. Key outcomes:
- **Task A** confirmed working: `connection_events_registered reason=powered_on` fires on every process start including post-UUID-persist restarts. MOD-E is now reliable.
- **Task B** confirmed: `options: nil` on connect. Notifications suppressed.
- **Tasks E + F**: BLE counters, glanceable status line, debug screen section — all shipped.

**Outstanding UI issues from build 187 (addressed in build 188):**
- Debug screen scrolls to top on every 5s refresh tick — caused by `.id(refreshTrigger)` on the whole scroll view
- Debug screen refreshes snapshot and log stats at the same 5s cadence — should be decoupled (1s / 10s)
- "Refresh View" button exists — remove it
- Main watch view BLE status is too small, on a separate line, and the existing `Phone · BLE:scan 0s` third line is confusing and hidden behind the action button
- Horizontal tab layout not yet implemented (chart / main / debug)
- Complication `· BLE` second line not implemented

**Validated in build 187:**
- Build 188 can remove the scan-path `registerForConnectionEvents` call (redundant defense confirmed no longer needed)
- Build 188 can remove the redundant `bleWasRestored` write from `centralManagerDidUpdateState`

---

## Build 188 scope

### Priority order

1. **Auth timing fix** — highest impact, every EGV is currently failing
2. **Debug screen + tab layout** — needed for overnight validation visibility
3. **Main watch view** — usability
4. **Complication** — investigate and fix
5. **Observability additions** — logging improvements
6. **Stage timeouts** — safety net
7. **Housekeeping** — cleanup

---

## Task A — Auth timing fix (Option C)

**Status of current problem:** Every G7 cycle in build 187 fails with `outcome=failure final_stage=requestingEGV`. The 6-second `authFallbackDelay` consumes most of the sensor's ~7-10 second session window. The EGV write lands at ~6-7s; the sensor closes at ~7-10s. Not enough margin for the response to arrive.

**Primary hypothesis (high confidence):** Reducing the time from connect to EGV write will move the write inside the window. The 6s fallback is the leading suspect. Not proven until Option C ships and we observe success.

**Why Option C and not A or B:**
- Option A (reduce timer to 2s): simpler but still timer-driven. An arbitrary 2s constant is still arbitrary.
- Option B (skip auth subscribe entirely): loses diagnostic visibility; slightly more aggressive toward sensor protocol expectations.
- Option C: advances on a real CB event (`auth_notify_enabled` fires at ~1s reliably), keeps auth subscription live for diagnostic and future-proofing, uses 30s as a pure watchdog.

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Change 1** — Line 114, reduce watchdog delay:
````swift
private let authFallbackDelay: TimeInterval = 30  // watchdog only; primary trigger is auth_notify_enabled
````

**Change 2** — In `handleNotificationState`, in the `case G7BLEUUID.authentication:` branch, after the existing log line, add:
````swift
if characteristic.isNotifying, !hasAdvancedBeyondAuth {
    authFallbackWorkItem?.cancel()
    advanceToControl(reason: "auth_notify_enabled_observer")
}
````

**Change 3** — Add phase timestamps to `session_outcome` log. Store timestamps at key moments during the session (connect, auth_notify_enabled, control_notify_enabled, egv_write, egv_write_ack, disconnect) and emit derived intervals in the `session_outcome` log line:
````
event=g7_ble_session_outcome outcome=success ... connect_to_auth_notify_ms=950 auth_notify_to_control_ms=120 control_to_egv_write_ms=80 egv_write_to_ack_ms=45 total_ms=1195
````
This makes every future session instantly diagnosable from one log line.

**Change 4** — Log whether auth payload arrives after Option C advance. In `handleAuthPayload`, if `hasAdvancedBeyondAuth == true` when the payload arrives, log it explicitly:
````
event=g7_ble_auth_payload_post_advance opcode=0x05 authenticated=<bool> bonded=<bool>
````
This tells us whether 0x05 ever arrives on the watch (key data for the "late subscriber misses auth payload" hypothesis).

**Success criteria (ship/no-ship gate for this task):**
- `control_notify_enable_requested reason=auth_notify_enabled_observer` appears at ~1s after connect (not ~6s)
- `session_outcome outcome=success` with `connect_to_egv_write_ms` in the 1000-2500ms range
- Repeated EGV delivery across multiple consecutive cycles — not just one

**Falsification criteria (if these occur, Option C is not the full answer):**
- `auth_notify_enabled_observer` fires at ~1s, `0x4E` goes out at ~1.5s, sessions still die before EGV reply → timing is not the only problem; something else is gating the sensor's response
- Total connect→write time is <2s but EGVs still fail → investigate control notify/write ordering or whether the observer is missing another readiness signal

**If Option C is ambiguous:** a follow-up build with just `authFallbackDelay = 2` (Option A) isolates "earlier" from "event-driven" as the benefit.

---

## Task B — Debug screen overhaul

**File:** `Trio Watch App Extension/Views/ComplicationDebugView.swift`

### B1 — Fix scroll-to-top on refresh

Remove `.id(refreshTrigger)` from the root scroll view or the top-level VStack. The `G7DirectBleDebugSection` is `@Observable`-tracked and auto-updates without forced invalidation. The `.id()` trick is only needed for the DATA STORE and LOG FILES sections which use local `@State` vars.

Apply `.id(refreshTrigger)` only to the `dataStoreStateView` and `reloadStatusView` subviews, not to the whole scroll view.

### B2 — Decouple refresh cadences

Replace the current single `.task` loop (5s for everything) with two separate loops:

````swift
// 1s cadence for snapshot/BLE values
.task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        loadSnapshot()
    }
}
// 10s cadence for log file stats (expensive on watch)
.task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        loadLogFileStats()
        refreshTrigger = UUID()  // force @State subview refresh
    }
}
````

Remove `import Combine` if it was only added for the timer.

### B3 — Remove "Refresh View" button

Remove the button from `actionsView`. The periodic refresh makes it redundant.

---

## Task C — Horizontal tab layout

**Context:** Previous implementation had chart / main / debug as horizontal swipe tabs. Current implementation is vertical scroll. Switch back to horizontal.

**Files:** Identify the top-level watch app view (likely `TrioApp.swift` or `ContentView.swift` for the watch extension) and the tab container.

**Change:** Use `TabView` with `tabViewStyle(.page)` (horizontal swipe). Order: chart (left) → main (center) → debug (right). Match the previous implementation's structure exactly — the agent should read the git history or the skipped patch to identify the prior tab container structure.

---

## Task D — Main watch view single status line

**File:** `Trio Watch App Extension/Views/GlucoseTrendView.swift` (or wherever the recency and BLE lines are rendered)

**Current state (wrong):**
- Line 1: recency (`5 min`)
- Line 2: BLE count (`BLE: 0 EGVs / 5 conn`) — different font size, separate line
- Line 3: `Phone · BLE:scan 0s` — hidden behind action button, confusing

**Target state (correct):**
- Single line: `5 min · BLE · 1/3` when `bleConnectsSinceLaunch > 0`
- Single line: `5 min` only when `bleConnectsSinceLaunch == 0` and source is not BLE
- Same font size as the current recency text
- Remove lines 2 and 3 entirely

**Format rules:**
- `[recency] · BLE · [egvs]/[conns]` when `bleConnectsSinceLaunch > 0` (regardless of source)
- `[recency] · BLE` when source is `g7DirectBLE` but `bleConnectsSinceLaunch == 0` (edge case)
- `[recency]` when source is not BLE and `bleConnectsSinceLaunch == 0`
- `bleEmphasis`: primary color when `bleEGVsSinceLaunch > 0`, secondary when `bleConnectsSinceLaunch > 0` but `bleEGVsSinceLaunch == 0`
- Drop `scan 0s` and all connection state detail entirely — not meaningful to users

---

## Task E — Complication `· BLE` second line

**Investigation required first.** Open `TrioWatchComplication.swift` and identify where the complication second line content is set. The complication template has a header and a body line — find the body line source.

Once identified:
- When `TrioComplicationDataStore.shared.latestSnapshot()?.source == .g7DirectBLE`, append `· BLE` to the second line
- Otherwise leave exactly as before
- If the second line is constructed from a function or computed property, add the conditional there

---

## Task F — Observability additions

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

### F1 — Consecutive failure counter (D1 from Phase 2 plan)

````swift
private var consecutiveConnectFailures = 0
// Reset in centralManager(_:didConnect:) alongside failedAttempts = 0
// Increment in scheduleConnectTimeout work item and in didFailToConnect
// Log: add consecutive_failures=\(consecutiveConnectFailures) to existing timeout log line
````

### F2 — `mode_e_total` log field (D2)

`connectionEventsSinceLaunch` already exists from Build 187. Add `mode_e_total=\(connectionEventsSinceLaunch)` to the existing `connection_event` log line in `connectionEventDidOccur`.

### F3 — Peripheral ID persistence log (D3)

In `handleGlucose(_:)`, immediately after `persistedPeripheralIdentifier = activePeripheral?.identifier`:
````swift
log("event=g7_ble_peripheral_id_persisted peripheral_id=\(activePeripheral?.identifier.uuidString ?? "nil") sequence=\(reading.sequence)")
````

---

## Task G — Stage-level timeouts

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

**Note:** Less urgent now that Option C should bring sessions to ~1-2s. Still worth having as a safety net to prevent a rogue session from draining battery.

**New property:** `private var stageTimeoutWorkItem: DispatchWorkItem?` — add to `cancelTransientTimers()`.

**Service discovery timeout (30s):** After `peripheral.discoverServices(nil)`:
````swift
let workItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .discoveringServices else { return }
    self.log("event=g7_ble_stage_timeout stage=discoveringServices")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = workItem
queue.asyncAfter(deadline: .now() + 30, execute: workItem)
````

**Auth observation timeout (10s):** When entering `observingAuth`, cancel discovery timeout and arm auth timeout. A single `stageTimeoutWorkItem` serves both — cancel and replace on stage transition:
````swift
stageTimeoutWorkItem?.cancel()
let authWorkItem = DispatchWorkItem { [weak self] in
    guard let self, self.stage == .observingAuth else { return }
    self.log("event=g7_ble_stage_timeout stage=observingAuth")
    self.centralManager.cancelPeripheralConnection(peripheral)
}
stageTimeoutWorkItem = authWorkItem
queue.asyncAfter(deadline: .now() + 10, execute: authWorkItem)
````

**Additional cancellation** (beyond `cancelTransientTimers()`):
- In `handleAuthPayload` when auth gate fires and session advances past `observingAuth`
- In `peripheral(_:didDiscoverServices:error:)` when `error != nil`
- In `peripheral(_:didDiscoverCharacteristicsFor:service:error:)` when `error != nil`

**Note:** With Option C in place, `authFallbackDelay` fires at ~1s (via `auth_notify_enabled_observer`), then the 10s auth stage timeout is a backstop. These are independent timers.

---

## Task H — Housekeeping

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

### H1 — Remove redundant `bleWasRestored` write from `centralManagerDidUpdateState`

`willRestoreState` already sets `WatchState.shared.bleWasRestored = true` directly. The write in `centralManagerDidUpdateState` is redundant (for cold launches it's a no-op write of the default `false`; for restoration it duplicates `willRestoreState`). Remove it.

### H2 — Remove scan-path `registerForConnectionEvents`

Task A from Build 187 is validated. The scan-path call with the "redundant defensive call" comment is no longer needed. Remove it entirely.

---

## Commit sequence for Build 188

1. `fix: advance to control on auth_notify_enabled, 30s watchdog (Task A)`
2. `feat: phase timing ladder in session_outcome log (Task A)`
3. `feat: log auth payload arrival after Option C advance (Task A)`
4. `fix: debug screen scroll, decoupled timers, remove refresh button (Task B)`
5. `feat: horizontal tab layout chart/main/debug (Task C)`
6. `fix: main watch view single status line (Task D)`
7. `fix: complication · BLE second line (Task E)`
8. `feat: consecutive failure counter, mode_e_total, peripheral ID log (Task F)`
9. `feat: stage-level timeouts (Task G)`
10. `chore: remove redundant bleWasRestored write, remove scan-path registration (Task H)`

---

## Build 188 overnight validation checklist

Check BetterStack in the morning for:

1. `connection_events_registered reason=powered_on` on every process start ✓ (Build 187 already confirmed — just verify it's still there)
2. `control_notify_enable_requested reason=auth_notify_enabled_observer` at ~1s after connect (not ~6s)
3. `session_outcome outcome=success` with `connect_to_egv_write_ms` in 1000-2500ms range
4. `post_egv_backoff_scheduled` → `post_egv_backoff_cancelled reason=connection_event` — B2 sleep working
5. `peripheral_id_persisted` fired once this process lifetime (D3)
6. Whether any `auth_payload_post_advance` events appear (did 0x05 ever arrive after advance?)
7. Consecutive EGV delivery across multiple cycles — not just one success
8. Zero "accessory disconnected" system notifications (Build 187 fix still holding)

---

## Confidence levels (for context, not for debate)

| Claim | Confidence |
|---|---|
| 6s fallback is harming EGV success rate | High |
| Option C will fix it | Medium-high (strong hypothesis, not proven) |
| Late subscribers miss the 0x05 auth payload | Medium |
| Private entitlement is the best-known structural long-term fix | Medium (watchOS behavior not guaranteed to match iOS exactly) |

---

## Implementation log (Build 188)

Execution followed **Trio-dev** `docs/prompts/04-execute-implementation-plan.md` on branch **`feature/watch-g7-direct-ble-observer-synthesis`** (Trio worktree). Verification: static re-read of each change; no `xcodebuild` / `ci/local-build.sh` per AGENTS.md rule 10. Post-ship, **code review** adjusted ladder `t0` semantics, debug `.id` targets, and connect-failure metric deduplication (see table rows below after Task H).

| Commit / step | What was done | Files | Acceptance |
|---------------|---------------|-------|------------|
| Task A (1/3) | `authFallbackDelay = 30`; advance on `auth_notify_enabled_observer` in `handleNotificationState` | `G7DirectBLEObserver.swift` | Matches plan Option C; fallback remains watchdog-only. |
| Task A (2/3) | Phase timestamps + extended `g7_ble_session_outcome` ladder; `sessionPhaseEgvAckAt` on control EGV write ack | `G7DirectBLEObserver.swift` | Ladder uses `-1` for missing segments; `connect_to_egv_ack_total_ms` falls back to `duration_ms` when no ack. **Review fix:** `sessionPhaseConnectAt = Date()` is taken **immediately before** `centralManager.connect(…)` so `connect_to_*_ms` is connect-**attempt** → phase, not `didConnect` → phase. |
| Task A (3/3) | `g7_ble_auth_payload_post_advance` when `hasAdvancedBeyondAuth` and opcode 0x05 | `G7DirectBLEObserver.swift` | Diagnostic only; no control-flow change. |
| Task B | 1s + 10s `.task` loops; scoped `.id(refreshTrigger)` on **data store** + **log files** sections; removed **Refresh** button; root `ScrollView` not `.id`’d | `ComplicationDebugView.swift` | 10s path bumps `refreshTrigger` for `@State` log counts; **reload status** has no `.id` (reads `TrioComplicationDataStore` directly). G7 block observes `WatchState` without forced identity. |
| Task C | `TabView` order chart (0) → main (1) → debug (2); `.page`; default page 1; telemetry `newPage == 0` for chart | `TrioMainWatchView.swift` | Horizontal swipe; long-press still jumps to debug (2). |
| Task D | Single recency line with `· BLE · egvs/conns` rules and `g7DirectBLE` edge case | `GlucoseTrendView.swift` | Removed phone/BLE detail line; font matches recency. |
| Task E | `source` on `TrioWatchComplicationEntry`; `· BLE` on corner second line when `source == .g7DirectBLE`; timeline copies `source` | `TrioWatchComplication.swift` | Placeholder/fallback entries keep `source == nil` → unchanged. |
| Task F | `consecutiveConnectFailures`; `mode_e_total` on connection event (after increment); `peripheral_id_persisted` log | `G7DirectBLEObserver.swift` | **Review fix:** `connectFailureMetricCountedThisAttempt` so timeout + `didFailToConnect` for the same attempt increment **once**; counter reset in `didConnect` **and** flag cleared in `didConnect` for clarity. |
| Task G | `stageTimeoutWorkItem`: 30s discovering services, 10s observing auth; cancel in `cancelTransientTimers`, service/char errors, success paths, `advanceToControl` | `G7DirectBLEObserver.swift` | `advanceToControl` cancels auth stage timeout only **after** control characteristic guard (red-team). |
| Task H | Removed `bleWasRestored` write from `centralManagerDidUpdateState`; removed scan-path `registerForConnectionEvents` | `G7DirectBLEObserver.swift` | Restoration still set in `willRestoreState`. |
| Red-team (G) | Moved `stageTimeoutWorkItem` cancel in `advanceToControl` to after control characteristic guard | `G7DirectBLEObserver.swift` | Avoids dropping auth timeout on early return. |
| Plan doc | Implementation log (this section) + plan v1.9 in repo | `watch-g7-ble-build187-impl-plan.md` | Changelog and table capture Build 188 execution. |

**Short SHAs (Build 188 + follow-ups, 7 hex):** 937b3c5, cfea7aa, fcd21f9, e9364da, 3033f06, 49c02aa, 38397d2, b74718d, 711570a, 169c6e7, 3e124f1, ced1888, 8d49aaa, cccc747

---

## Changelog

### v1.10 (2026-04-27 11:52 CEST)
- **Implementation log table** updated: Task B and Task A(2) rows match **as-built** (`.id` on data store + **log files**, not reload; `sessionPhaseConnectAt` at **`connect()`** for honest `connect_to_*` intervals); Task F row includes **deduped** connect-failure metric and **`didConnect`** flag reset; short SHA list; plan doc as its own row.
- Pointers: pair doc **`watch-g7-ble-build187-impl-log.md`** (v1.2) for narrative Build 188 notes.

### v1.9 (2026-04-27 00:44 CEST)
- **Build 188 executed:** ten plan commits + one red-team fix commit on `feature/watch-g7-direct-ble-observer-synthesis`; **Implementation log** section added above.

### v1.8 (2026-04-27)
Consolidated into Build 187 (done) + Build 188 (tonight). Major additions:
- Auth timing fix (Option C) as highest-priority Build 188 task with full evidence, success/falsification criteria, confidence table
- Phase timing ladder added to session_outcome log (ChatGPT suggestion — high value)
- Auth payload post-advance logging (ChatGPT suggestion — key diagnostic)
- Debug screen split into 1s/10s cadences, scroll fix, remove Refresh button
- Horizontal tab layout added to scope
- Main watch view collapsed to single status line `5 min · BLE · 1/3`
- Complication investigation task added
- Housekeeping: remove redundant bleWasRestored write, remove scan-path registration call
- Status language corrected throughout per review: "primary hypothesis" not "root cause confirmed"

### v1.7 (2026-04-26)
Three small fixes: WatchState access instruction consolidated; validation wording consistent; duplicate Last BLE EGV table rows collapsed.

### v1.6 (2026-04-26)
Periodic refresh timer added to Task F. WatchState is @Observable so BLE section auto-updates; timer handles DATA STORE / LOG FILES @State vars.

### v1.5 (2026-04-26)
Seven fixes: Last BLE EGV uses dedicated WatchState properties (not latestSnapshot()); queue name corrected to `queue`; eventual consistency note; counter persistence through observer stop/restart; data race fix (capture before Task dispatch); WatchState access pattern specified; stageTimeoutWorkItem double-duty clarified.

### v1.4 (2026-04-26)
Counter ownership model clarified; Task D2 overlap fixed; Task F file targeting precise (ComplicationDebugView.swift); Task A acceptance softened.

### v1.3 (2026-04-26)
Build 187 scope explicitly acknowledged as including observer-side debug state mirroring; Task C cancellation hole fixed; bleWasRestored validation corrected; in-memory note added.

### v1.2 (2026-04-26)
Build 187/188 split. B0-B3 minimum shippable. Threading rule explicit. consecutiveConnectFailures semantics corrected. Scan-path registration preserved as redundant defense.

### v1.1 (2026-04-26)
Red team + code verification. foreground gate constraint exact. UUID constants corrected. cancelTransientTimers hook. Exact reset/increment locations for D1.

### v1.0 (2026-04-26)
Initial build 187 plan.