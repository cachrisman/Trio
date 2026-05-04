# Trio Watch G7 Direct BLE Observer — Phase B Implementation Log

**Version:** v1  
**Status:** Complete — passed code review  
**Created:** 2026-04-25  
**Last updated:** 2026-04-25

**Implementation plan:** [watch-g7-direct-ble-observer-04-impl-plan.md](watch-g7-direct-ble-observer-04-impl-plan.md)  
**Issue summary:** [g7-ble-build186-issue-summary.md](g7-ble-build186-issue-summary.md) (v1.1)

---

## Branch and base

- Branch: current feature branch (same as prior observer work)
- Baseline commit: `19320f521` (`docs: clarify control-write retry; refresh log; fix WatchState observer API`)

---

## Scope

Phase B tasks B0–B3 (the minimum shippable unit per the impl plan), plus two post-review fix commits.

| Task | Description |
|---|---|
| B0 | `willRestoreState` — cancel CB-preserved pending connects on restoration relaunch |
| B1 | `connectInFlight` guard — block parallel `connect()` calls from rapid scene transitions |
| B3 | `isDiscoveringServices` gate — prevent triple `auth_notify_enabled` from duplicate service discovery |
| B2 | Post-success 290s sleep — stop inter-window reconnect churn |
| fix-1 | Post-review: backoff guard, teardown resets, logging split |
| fix-2 | Post-review: `isDiscoveringServices` in connect timeout; `stop()` stage verification |

---

## Commit log

| SHA | Description |
|---|---|
| `7f7bc2a45` | B0: implement willRestoreState to cancel CB-preserved pending connects |
| `2c39f18f9` | B1: add connectInFlight guard against parallel connect() calls |
| `8a3641dd7` | B3: add isDiscoveringServices flag to block duplicate service discovery |
| `f1d1f4944` | B2: post-success sleep to stop inter-window reconnect churn |
| `cf5cc8ded` | fix: post-review corrections to B0-B3 (backoff guard, teardown resets, logging) |
| `9652e1f84` | fix: verify stop stage transition; reset isDiscoveringServices on connect timeout |

All changes are in one file: `Trio Watch App Extension/G7DirectBLEObserver.swift`.

---

## Implementation detail

### B0 — `willRestoreState`

**Problem:** `willRestoreState` was implemented but incorrect — it was calling `discoverServicesIfNeeded` and assigning `activePeripheral` directly, which left CB's preserved pending `connect(DXCM08)` alive alongside the attach ladder's fresh `connect()`. This produced duplicate `didConnect` events, triple `auth_notify_enabled` per cycle, and the three "accessory disconnected" OS notifications observed in build 185 day-two wear.

**Implementation:**
- Added `private var didReceiveWillRestoreState = false` — per-manager-lifecycle flag, initialized in `init()`, set to `true` inside `willRestoreState`, never reset in per-session teardown paths (resetting it on disconnect would corrupt the `was_restored` signal if `centralManagerDidUpdateState` fires again in the same process lifetime).
- `willRestoreState` now: logs `event=g7_ble_will_restore_state`; sets `didReceiveWillRestoreState = true`; iterates restored peripherals and cancels any with `state != .connected`. Peripherals already in `.connected` state are logged and skipped — tearing down a live session is worse than letting the attach ladder reconcile from `centralManagerDidUpdateState`.
- `centralManagerDidUpdateState` now includes `was_restored=\(didReceiveWillRestoreState)` in the `g7_ble_central_state` log event, making cold launch vs restoration relaunch distinguishable in BetterStack.
- The attach ladder continues to be driven entirely by `centralManagerDidUpdateState` — no `connect()` or discovery call in `willRestoreState`.

**Cancel policy:** cancel if `peripheral.state != .connected`. This covers `.connecting` (CB-preserved pending attempt), `.disconnected` (no-op, safe), and `.disconnecting`. Blanket cancel was removed.

**One known open question:** if a restored peripheral is already `.connected`, the new code logs and does nothing. The old code explicitly called `discoverServicesIfNeeded(peripheral)`. In the new model, a `.connected` restored peripheral depends on `centralManagerDidUpdateState → kickAttachIfNeeded → retrieveConnectedPeripherals → connect() → didConnect → discoverServicesIfNeeded` to reconcile. This is a longer path with more failure points, but the old path was the root cause of the duplication bugs. Watch for a `.connected` restored peripheral that never gets adopted in post-deploy BetterStack traces.

---

### B1 — `connectInFlight` guard

**Problem:** Rapid `scenePhase=active` transitions (wrist raise, notifications) each triggered the full attach ladder independently, producing up to 3 simultaneous `connect_attempt` events within one second in build 185 logs.

**Implementation:**
- Added `private var connectInFlight = false` — per-session flag (reset in all teardown paths).
- Guard at top of `connect()`: if `connectInFlight`, log `event=g7_ble_connect_skipped reason=already_connecting` and return.
- `connectInFlight = true` set immediately after the guard passes — covers the full `connect()` execution including scan stop, state prep, and `central.connect(peripheral, options:)`.
- Cleared in: `didConnect`, `didFailToConnect`, `didDisconnectPeripheral`, connect-timeout work item, `hardStopOnQueue`.
- Defensive: before calling `central.connect(peripheral)`, if `peripheral.state == .connecting`, calls `cancelPeripheralConnection` to clear any stale CB-preserved pending connect that might race. Does NOT cancel if `.connected`.

---

### B3 — `isDiscoveringServices` gate

**Problem:** Both `centralManager(_:didConnect:)` and `connectionEventDidOccur(.peerConnected)` could trigger service discovery for the same physical connection independently, producing triple `auth_notify_enabled` per cycle in build 185 logs.

**Implementation:**
- Added `private var isDiscoveringServices = false` — per-session flag.
- Guard at entry of `discoverServicesIfNeeded()`: if `isDiscoveringServices`, log `event=g7_ble_service_discovery_skipped reason=already_in_progress` and return.
- `isDiscoveringServices = true` set immediately before `peripheral.discoverServices(...)`.
- Cleared only on full teardown paths (`didDisconnectPeripheral`, `didFailToConnect`, `hardStopOnQueue`) — NOT on mid-session phase transition to characteristic discovery, because late duplicate CB callbacks can still arrive after that point and would reopen the race window.
- `peripheral.services == nil` was explicitly rejected as a guard — unreliable; can be non-nil from cached prior-connection state.

**Note on task ordering:** The impl plan numbers B3 before B2 but B2 was listed second in the ordering because B3 (the duplicate-discovery gate) is a cheaper correctness fix than B2 (the post-success sleep). Both were implemented in this order per the plan.

---

### B2 — Post-success 290s sleep

**Problem:** After each successful EGV delivery (CBError 7 disconnect), the observer immediately restarted its reconnect loop, issuing ~3–4 failed `connect()` calls per inter-window period (~5 minutes). The G7 re-auth window is ~20–30s every ~300s; all inter-window connect attempts fail. This accounted for ~70% of `incomplete/idle` session outcomes in build 185.

**Implementation:**
- Added `private var postEGVBackoffWorkItem: DispatchWorkItem?` — per-session, cancelled and nil'd in `hardStopOnQueue` and `stop()`.
- Added `private var lastSessionWasSuccess = false` — per-session, reset at top of `connect()` and in `hardStopOnQueue`.
- In the disconnect handler: if `lastSessionWasSuccess`, schedule `postEGVBackoffWorkItem` for 290s instead of calling `scheduleReconnect(reason: "disconnect")`.
- Work item body guard: `self.stage != .stopped` (both `stop()` and `hardStopOnQueue` transition `stage` to `.stopped` — verified by grep; guard covers both teardown paths).
- `connectionEventDidOccur(.peerConnected)`: cancels `postEGVBackoffWorkItem` and nils it before logging `event=g7_ble_post_egv_backoff_cancelled reason=connection_event`. The cancel+log only fires if the work item was non-nil — avoids spurious log events on cycles where MOD-E doesn't arrive and the work item has already fired.
- `postEGVBackoffWorkItem` also cancelled in `stop()` and `hardStopOnQueue`.

**MOD-E interaction:** MOD-E (`peerConnected`) is expected to be the primary cancellation path in normal overnight operation, matching the "cancel early" expectation from the impl plan. The 290s work item fires as a fallback if MOD-E does not arrive.

---

## Post-review fixes

Two rounds of code review (ChatGPT + Claude) were conducted after initial B0–B3 implementation. Three issues were accepted and fixed in `cf5cc8ded`; two were accepted and fixed in `9652e1f84`.

### Round 1 fixes (`cf5cc8ded`)

**Fix 1 — Backoff guard broadened from `!isHardStopped` to `stage != .stopped`:**
Initial implementation guarded the `postEGVBackoffWorkItem` body with `!self.isHardStopped`. This missed the case where `stop()` was called without a hard stop. Confirmed that both `stop()` and `hardStopOnQueue()` transition `stage` to `.stopped` — `stop()` calls through to `hardStopOnQueue` at line 155. Guard changed to `self.stage != .stopped`.

**Fix 2 — `lastSessionWasSuccess` reset in `hardStopOnQueue`:**
Per-session flag was reset at the top of `connect()` but not in `hardStopOnQueue`. Added explicit reset for consistency with the state flag reset requirements in the impl plan.

**Fix 3 — Logging split: `g7_ble_did_connect` moved out of `discoverServicesIfNeeded`:**
`discoverServicesIfNeeded()` was logging `event=g7_ble_did_connect`, which became semantically incorrect once the function was also a duplicate-discovery gate. Moved `g7_ble_did_connect` to `centralManager(_:didConnect:)` where it belongs. Added `event=g7_ble_service_discovery_started` in `discoverServicesIfNeeded` after the `isDiscoveringServices` guard passes, immediately before `peripheral.discoverServices(...)`. The `service_discovery_skipped` log on the duplicate path was already in place from B3.

### Round 2 fixes (`9652e1f84`)

**Fix A — `stop()` stage transition verified (no edit):**
`stage = .stopped` appears only in `hardStopOnQueue` (line 724). `stop()` calls through at line 155. Guard is complete; no edit needed.

**Fix B — `isDiscoveringServices` reset in connect-timeout path:**
The connect timeout work item cleared `connectInFlight = false` but not `isDiscoveringServices`. Added `isDiscoveringServices = false` alongside `connectInFlight` in the timeout work item body. The timeout also indirectly triggers `didFailToConnect` (which clears the flag), but the explicit reset is defensive and keeps the pattern symmetric with all other teardown paths.

---

## Items intentionally deferred

- **B4** (MOD-E re-registration on foreground-active) — separate build to isolate behaviour change attribution
- **B5** (consecutive-failure counter) — separate build from B4
- **Restored `.connected` peripheral explicit adoption** — absent by design; watch in BetterStack after first overnight run
- **`CBConnectPeripheralOptionNotifyOnDisconnectionKey: true`** — pre-existing, not introduced here; evaluate after B0 is proven in field logs

---

## Validation performed

- Static source review of all 6 commits.
- Two rounds of external code review (ChatGPT, Claude) — all accepted changes are incorporated.
- `stage = .stopped` coverage verified by grep across full file.
- `stop()` → `hardStopOnQueue` call chain verified by line number inspection.
- No `xcodebuild`, `ci/local-build.sh`, or Xcode project-file edit was run.

---

## Ship gate

Per the impl plan, the hard gates for this build are:

- `event=g7_ble_will_restore_state` appears on restoration relaunches; `event=g7_ble_central_state was_restored=false` appears on cold launches
- `auth_notify_enable_requested` appears exactly once per session (not 2–3)
- `connect_skipped reason=already_connecting` appears when rapid scene transitions would have caused parallel connects
- `service_discovery_skipped reason=already_in_progress` appears on duplicate discovery attempts
- `session_outcome=success` rate no worse than build 185 baseline

---

## Changelog

### v1 (2026-04-25)
- Initial log covering B0–B3 implementation and two rounds of post-review fixes.
