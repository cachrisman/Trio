# Build 190 — Implementation log

**Version:** 1.2  
**Status:** Complete (code landed; soak Tiers 1–3 pending)  
**Branch:** `feature/watch-g7-direct-ble-observer-synthesis`  
**Created:** 2026-05-01 20:37 CET  
**Last updated:** 2026-05-01 20:57 CET  

**Plan:** [watch-g7-direct-ble-observer-build190-impl-plan.md](watch-g7-direct-ble-observer-build190-impl-plan.md) (v1.0)  

**Baseline SHA (build 185):** `30cbf49b70d00eaeb3b13074bb1d71e550e77d5c` (`trio-v0.7.0-185-local`)

---

## Commits

| Order | SHA | Message |
|-------|-----|---------|
| 1 | `849d8d505` | `revert: reset G7DirectBLEObserver.swift to build 185 baseline` — Item 0 only |
| 2 | `d6f9cce87` | `feat(watch-g7): build 190 — MOD-E hardening, session generation, discovery timeout` — Items 1–9 |
| 3 | — | `fix(watch-g7): restore connect timeout from connect(), disconnect_failure terminal reason` — post-review corrections *(SHA: `git log -1 --oneline` on this branch)* |
| 4 | — | `fix(watch-g7): red-team — resume_connected discovery timeout; skip disconnect emit after hardStop` |

---

## Item 0

- **Action:** `git checkout 30cbf49b70d00eaeb3b13074bb1d71e550e77d5c -- "Trio Watch App Extension/G7DirectBLEObserver.swift"`
- **Verification:** `git diff` vs baseline empty after checkout; Tier 0 greps confirmed absence of `scheduleObservingAuthStageTimeout`, Option C notify-advance block, `postEGVBackoffWorkItem`, `discovery_skipped`.

---

## Items 1–9 (single file)

**File:** `Trio Watch App Extension/G7DirectBLEObserver.swift`

### Item 1 — Session generation

- Added `currentSessionGeneration`; bumps in `didConnect` and `willRestoreState` (connected restore path only), with `g7_ble_session_generation_bumped` logs.
- Auth fallback: `cancelAuthFallback(reason:)`, generation capture in `DispatchWorkItem`, skip logs for stale gen / already advanced.
- `scheduleReconnect`: generation-checked work item with `g7_ble_reconnect_skipped reason=stale_gen` when applicable.
- **`scheduleConnectTimeout`:** armed from **`connect()`** after `centralManager.connect(...)` (not from `didConnect`). Closure uses active-peripheral identity + `peripheral.state != .connected` only (no generation guard). On fire: sets `pendingTerminalReason = "connect_timeout"`, logs timeout, `cancelPeripheralConnection` — **reconnect only via `didDisconnectPeripheral`** (commit 3 removed duplicate `scheduleReconnect` from the timeout closure). **`didConnect` cancels** the connect-timeout work item when connection succeeds.
- Added `gen=` on many critical-path logs (services, characteristics, notify state, auth payload, disconnect, connect failure, EGV, etc.).

### Item 2 — MOD-E registration on `.poweredOn`

- In `centralManagerDidUpdateState`, `.poweredOn` registers connection events before existing attach logic; log `g7_ble_connection_events_registered reason=powered_on`.

### Item 2 (belt) — Registration on `connect()`

- Plan Tier 0 expects registration in both `.poweredOn` and `connect()`. Build **185** only registered in `startScanning`; **`connect()` now also registers** with `reason=connect` (matches plan §6 item 6).

### Item 3 — Connection-event observability

- `connectionEventDidOccur`: unified audit line `event=g7_ble_connection_event ... type=peer_connected|peer_disconnected gen=...` for BetterStack metric matching (`%peer_connected%`).

### Item 4 — Self-loop guard

- For `.peerConnected`, if `activePeripheral?.identifier` matches, log `g7_ble_connection_event_self_ignored` and skip `startOrResume`; always emit the `g7_ble_connection_event` line afterward.

### Item 5 — Discovery timeout (30s, generation-checked)

- `discoveryTimeoutWorkItem`, `scheduleDiscoveryTimeout(for:)`, scheduled from `didConnect`, restore-connected path, and **`startOrResume` `resume_connected`** (commit 4 — red-team; closes gap when already-connected peripheral re-enters discovery without a fresh `didConnect`).
- Cancelled on successful `didDiscoverServices` (success branch), `didDisconnectPeripheral`, and `cancelTransientTimers` / teardown.

### Item 6 — Persist sensor ID on `didConnect`

- After generation bump: optional `g7_ble_sensor_changed`; always `g7_ble_peripheral_id_persisted reason=did_connect`.

### Item 7 — Session outcome `terminal_reason`

- Added `pendingTerminalReason`, `lastAuthAdvanceReason`, `resolveTerminalReason(...)`.
- Extended `g7_ble_session_outcome` log with `terminal_reason=` and `gen=`.
- `hardStopOnQueue` sets `pendingTerminalReason = "hard_stopped"` before teardown emit.
- **`didFailToConnect`:** sets `pendingTerminalReason = "connect_failed"` and calls **`emitSessionOutcome(outcome: "failure")`** so failed connects produce an outcome row (not in build 185 — see deviation).
- Codes implemented: `egv_received`, `connect_failed`, `connect_timeout` (matches plan §7 / Item 7 table), `discovery_timeout`, `discovery_failed`, `auth_stall`, `auth_fallback_no_egv`, `auth_payload_success`, `hard_stopped`, `incomplete`, plus **`disconnect_failure`** for `rawOutcome == "failure"` when no `pendingTerminalReason` (commit 3 — BetterStack-distinguishable from other outcomes).

### Item 8 — Option C tripwire

- After `guard opcode == authStatusReply`, if `hasAdvancedBeyondAuth`, log `g7_ble_auth_payload_post_advance` with opcode / authenticated / bonded / gen.

### Item 9 — Disconnect notification flag

- `centralManager.connect(peripheral, options: nil)`.

### Supporting hygiene

- `connect()` clears `pendingTerminalReason` on new session attempt to avoid leakage across attempts.
- `cancelTransientTimers` cancels discovery timeout and uses `cancelAuthFallback(reason: "transient_teardown")`.
- **`didDisconnectPeripheral` when `isHardStopped`:** early return after cancelling discovery/connect-timeout work items — avoids duplicate `g7_ble_session_outcome` and `scheduleReconnect` after `hardStopOnQueue` already emitted teardown (commit 4 — red-team).

---

## Tier 0 (§6) — pre-commit 2

Executed from repo root:

- `git diff 30cbf49b70d00eaeb3b13074bb1d71e550e77d5c -- "Trio Watch App Extension/G7DirectBLEObserver.swift"` — changes confined to intended file; forbidden patterns absent.
- `scheduleObservingAuthStageTimeout`, Option C advance-on-notify, `postEGVBackoffWorkItem`, `discovery_skipped` — **absent**.
- `centralManager.connect(peripheral, options: nil)` — **present**.
- `registerForConnectionEvents` — **3 sites** (`startScanning`, `.poweredOn`, `connect()`).
- `authFallbackDelay = 6` — **present**.
- `currentSessionGeneration`, bump sites, `scheduleDiscoveryTimeout`, tripwire — **present**.
- **`scheduleConnectTimeout` called from `connect()`** (not `didConnect`); `scheduleDiscoveryTimeout` from `didConnect` + restore-connected + **`resume_connected`** — **verified** (commits 3–4).

---

## Deviations / assumptions

1. **`didFailToConnect` session outcome:** Emits `g7_ble_session_outcome` with `terminal_reason=connect_failed` to avoid dangling `pendingTerminalReason` and to align BetterStack session rows with immediate connect failures (unchanged from build 190 landing).
2. **`disconnect_failure` terminal code:** Not explicitly listed in plan §7 table; introduced for generic error disconnects (`rawOutcome == "failure"` with no pending reason) so soak queries can separate them from other paths (commit 3).

---

## Red-team review (prompt 05)

**Spec:** build 190 implementation plan v1.0 (same folder). **Branch reviewed:** `feature/watch-g7-direct-ble-observer-synthesis` @ `d6f9cce87`.

### Iteration 1

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| R1.1 | major | Connect timeout `DispatchWorkItem` captured `currentSessionGeneration` while still scheduled from `connect()` **before** `didConnect` bumped generation → timeout always treated as stale. | **Fixed:** arm connect timeout only from **`didConnect`** after generation bump. |
| R1.2 | major | `pendingTerminalReason = "connect_failed"` in `didFailToConnect` without `emitSessionOutcome` could leak pending into a later disconnect’s outcome. | **Fixed:** clear `pendingTerminalReason` at start of `connect()`; **emit** outcome in `didFailToConnect`. |

### Iteration 2

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| R2.1 | minor | Generic `terminal_reason=failure` not in plan §7 table. | **Deferred:** document only; optional rename (e.g. `disconnect_failure`) in a later build. |
| R2.2 | minor | `scheduleReconnect` still invoked from connect-timeout work item while `didDisconnect` also schedules reconnect (185-era duplication). | **Accepted:** behavior preserved to avoid scope creep; monitor logs for duplicate `reconnect_scheduled`. |

### Iteration 3

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| R3.1 | minor | `controlWriteRetryWorkItem` closure has no generation guard (plan singled out auth fallback / reconnect). | **Residual risk:** low; peripheral-id guards remain. Optional hardening later. |

### Iteration 4 — External / post-review (2026-05-01)

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| E4.1 | **blocker** | `scheduleConnectTimeout` armed from `didConnect` while the closure required `peripheral.state != .connected` — always “already_connected”; no protection when `didConnect` never fires. | **Fixed (commit 3):** arm from `connect()`; drop gen guard on connect-timeout closure; remove `scheduleReconnect` from timeout closure (reconnect only via `didDisconnectPeripheral`). |
| E4.2 | major | Generic `terminal_reason=failure` weakens BetterStack taxonomy. | **Fixed (commit 3):** `disconnect_failure` in `resolveTerminalReason`. |
| E4.3 | — | Confirm `connect_timeout` pending string matches plan Item 7 table. | **Verified:** `pendingTerminalReason = "connect_timeout"`; returned via pending branch — matches plan (`connect_timeout` \| Connect attempt timed out). |

*Historical note:* Iteration 1 (R1.1) and Iteration 2 (R2.1/R2.2) reflected an earlier connect-timeout placement; commit 3 supersedes that trajectory.

### Iteration 5 — Prompt 05 pass (2026-05-01)

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| RT1.1 | major | `resume_connected` called `discoverServicesIfNeeded` without `scheduleDiscoveryTimeout` — Item 5 watchdog bypassed when re-attaching without new `didConnect`. | **Fixed (commit 4):** `scheduleDiscoveryTimeout(for:)` before `discoverServicesIfNeeded` on that branch. |
| RT1.2 | major | `didDisconnectPeripheral` ran after `hardStopOnQueue` → duplicate `emitSessionOutcome` + unnecessary `scheduleReconnect`. | **Fixed (commit 4):** if `isHardStopped`, cancel dangling timeout work items and return before emit/reconnect. |
| RT2.1 | minor | `currentSessionGeneration` comment overstated “all deferred work items.” | **Fixed (commit 4):** comment narrowed to discovery-timeout, auth-fallback, reconnect (connect timeout has no gen guard by design). |

### Final status (red team)

- **Verdict:** **Clean with minor nits** — E4.1/E4.2 addressed in commit 3; RT1.1/RT1.2/RT2.1 addressed in commit 4 (iteration 5).
- **Residual risks:** `controlWriteRetryWorkItem` without gen guard (R3.1); `disconnect_failure` is an app-defined extension vs strict plan §7 enum (documented under deviations).

### Coverage check

| Area | Result |
|------|--------|
| Core logic / passive observer contract | Pass — Option C absent; tripwire present |
| State / lifecycle | Pass — gen bumps at connect + restore-connected |
| Persistence | Pass — peripheral ID on `didConnect` |
| Observability | Pass — MOD-E registration logs, `type=peer_connected`, extended outcome |
| Rollback | Pass — revert commit isolates 185 file baseline |

---

## Validation not run (per AGENTS.md)

- No `xcodebuild` / `ci/local-build.sh`
- No automated tests for Watch extension BLE observer

**Recommended user follow-up:** `ci/local-build.sh` (with chosen flags) from Trio-dev worktree; Tier 1–3 soak per plan §10.

---

## Open / remaining items

- **Soak:** Tier 1–3 criteria in plan §10 (BetterStack dashboard 914638, discovery hang stats, EGV rate).
- **Patch stack:** If this branch is folded into Trio-dev `patches/`, regenerate the relevant patch with `generate-patch.sh` / `mid-stack-update.sh` per fork workflow (not done in this session).

---

## Changelog

### v1.2 (2026-05-01 20:57 CET)

- Documented commit 4 (red-team iteration 5): `resume_connected` discovery timeout; `didDisconnect` early exit when `isHardStopped`; `currentSessionGeneration` comment correction. Commits table row 4; Item 5 / Supporting hygiene / Tier 0 / red-team sections updated.

### v1.1 (2026-05-01 20:52 CET)

- Documented commit 3: connect-timeout restoration from `connect()`, removal of gen guard + duplicate reconnect from timeout closure, `disconnect_failure` rename; updated Item 1 / Item 7 / Tier 0 / deviations / red-team iteration 4 (external review).

### v1.0 (2026-05-01 20:37 CET)

- Initial implementation log for build 190: Item 0 revert commit, Items 1–9 feature commit, Tier 0 summary, deviations, red-team iterations, open items.
