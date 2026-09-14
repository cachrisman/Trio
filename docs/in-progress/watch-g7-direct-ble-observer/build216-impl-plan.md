# Build 216 Watch EGV Improvements — Implementation Plan

**Version:** v0.6 (2026-07-04 — SHIPPED: build 216 (`0.8.4`) deployed to TestFlight as `trio-v0.8.4-216-localCI` after upstream-0.8.4 reconciliation (repin-g7 base-side fix, patch-13 fetchLimit reconcile). See `watch-g7-direct-ble-observer-build216-impl-log.md`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the recurring "Dexcom-side" signal-loss episodes **diagnosable and recoverable**. Today, when the watch's direct BLE link goes stale for multiple hours, the telemetry cannot tell us *why* (no signal strength, no scan-liveness), and Trio's own session restarts do not recover it — the user must manually force-restart both watch apps. This build adds the instrumentation to classify the failure mode and a first attempt at Trio-side self-recovery.

**Architecture:** Telemetry enrichment (RSSI, scan-liveness, recovery markers) + one bounded self-recovery path (CoreBluetooth central re-init on sustained Dexcom-side stall). No new EGV-decode logic.

**Tech Stack:** Swift, watchOS, WatchKit (WKExtendedRuntimeSession), CoreBluetooth, BetterStack telemetry via WatchTelemetryRing.

---

## ⚠️ Framing note: what is and is not established

The `fault=dexcom_side` label is a **recency heuristic** shipped in build 210 (C-210-8, commit `37d4882af`): "no recent direct EGV window + `phone_fresh=true` → classify Dexcom-side." It is **not** a statement of mechanism.

**Do NOT repeat the debunked theory** that the G7 "favors a single phone connection" or has a primary/secondary hierarchy. There is **no evidence** of connection favoring, and it is contradicted by this project's own premise — the watch observer connects to the *same* sensor the phone is already connected to, so the G7 plainly accepts concurrent centrals. The underlying cause of the Dexcom watch app dropping its direct link is **conjecture, explicitly labelled as outside Trio's code** — see [build209-impl-plan.md:109](watch-g7-direct-ble-observer-build209-impl-plan.md). Matching discipline: build 207's **"Do not claim 'all pending-auth'"** ([build207-impl-plan.md:135](watch-g7-direct-ble-observer-build207-impl-plan.md)).

Every task below is framed as **hypothesis → change → measurable pass/fail**, because the mechanism is genuinely unknown and the current data cannot distinguish the candidate causes.

---

## Evidence base (build 215 soak, BetterStack, 8-day window, sensor DXCMyu, n=1)

Established from the build-215 EGV status analysis (see [watch-egv-betterstack-status-prompt.md](watch-egv-betterstack-status-prompt.md)):

- **Stalls are 95% `fault=dexcom_side` and 100% `phone_fresh=true`** (123/129 dexcom_side; all with the phone receiving fresh readings). Only ~6 `trio_side` stalls over 114h — the app already attributes almost all stalls to the sensor/Dexcom side.
- **The blocking unknown:** during a deep gap (e.g. 06-30 09:00) the observer was awake (`heartbeat`=12, `expected_window`=12) but issued **`connect_called`=0**. We cannot currently tell whether (a) the OS suspended the scan, (b) the scan ran but no advertisement appeared, or (c) a candidate appeared and the connect timed out. All three look identical today, and **Trio logs no RSSI**.
- **Session/reanchor restarts do not recover episodes (Task E finding).** Multi-hour episodes persist unbroken across `ext_session_started` / reanchor-replacement boundaries — e.g. the 06-30 08:25→10:05 run continued through a full reanchor + new session at 09:05:49. Recovery of the 06-30 08:00–11:00 episode instead coincided with `will_restore_state` (Trio process relaunch), consistent with the user's manual restart being the recovery.
- **No evidence session churn triggers stalls.** Reanchors land mid-episode (near expiry), never as a lead-in; the ~5-min proximity of some onsets to `ext_session_started` is confounded by app-foregrounding + the 15-min staleness detector re-arming. Not a causal Trio-side signal.

---

## Global Constraints

- All **Trio app** code changes go in the `Trio` worktree on the feature branch; patch tooling runs from `Trio-dev` on `dev`.
- **G7WatchSensorAdapter / watch changes:** after each commit, `./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>` from `Trio-dev`.
- **G7SensorKit changes are fork-first:** edit + commit in the standalone clone `~/Code/personal/health/diabetes/G7SensorKit` on `main`, then `./scripts/repin-g7.sh` from `Trio-dev` (re-pins patch 02). Never commit fork work only inside `Trio/G7SensorKit`.
- Run `./scripts/patch-test.sh` after every patch update. A FAIL is a hard stop.
- Never hand-edit patch files. Never edit `scripts/patch-audit.safety-paths` or `.waivers`.
- No `Co-Authored-By: Claude` or `🤖 Generated with Claude Code` in any commit message or PR body.
- Static review + `patch-test.sh` are the verification tools; do not run builds as a verification step (AGENTS.md rules 10 & 12).

---

## Tasks

### Task A — RSSI logging (highest value; user-requested)

- [ ] Add RSSI to the watch BLE telemetry **if readily available** from CoreBluetooth: per-advertisement RSSI in `centralManager(_:didDiscover:advertisementData:rssi:)` during scan, and `peripheral.readRSSI()` while connected.
- [ ] Stamp `rssi=` onto `attach_path`, `did_connect`, `connect_timeout`, and `direct_ble_stall_detected` (and the scan-liveness heartbeat from Task B).
- **Hypothesis:** "Dexcom-side" stalls coincide with weak/absent advertisements (proximity/range) vs strong signal (a stack/logic issue).
- **Pass/fail:** RSSI present on those events so healthy-window vs stall-episode distributions are directly comparable in BetterStack.
- **Notes:** Trio logs no RSSI today — this is net-new. Keep it additive/diagnostic; no behavior change. Likely lives in `G7PeripheralManager.swift` (fork, patch 02) for the connected `readRSSI()` and in the watch adapter for scan-time discovery.

### Task B — Scan-liveness instrumentation (turns the core unknown into a decision tree)

- [ ] Add a periodic scan-liveness signal (fold into `heartbeat` or a new low-rate event) carrying: `scan_active` (bool), `seconds_since_last_didDiscover`, `candidates_seen_this_window`, and `CBCentralManager.state`.
- **Hypothesis:** the `connect_called=0` deep gaps are one of {OS-suspended scan, scan-running-no-candidate, candidate-seen-connect-failed}.
- **Pass/fail:** every ≥30-min zero-EGV episode can be assigned a definite bucket instead of "no attempts, cause unknown." Validate against a repeat of the 06-30 09:00-type gap.
- **Priority:** pair with Task A — together they make every future episode classifiable. Do these first.

### Task C — Trio-side self-recovery on sustained Dexcom-side stall

- [ ] On a sustained hard Dexcom-side stall (reuse the existing C-210-8 classifier + debounce; threshold N minutes, tune conservatively), perform a **CoreBluetooth central re-init / scan reset** — a real teardown+rebuild of the central, not merely a new extended-runtime session.
- **Hypothesis (evidence-backed by Task E):** a fresh `ext_session` / reanchor does **not** recover these episodes; a lower-level central reset might, reducing the need for the user's manual both-apps restart.
- **Pass/fail:** episodes recover **without** a preceding `will_restore_state` (manual relaunch); measure per-episode recovery-cause rate before/after (needs Task D markers).
- **Guardrails:** obey the documented alarm/behavior discipline — fire only on a sustained hard stall, once per episode, reset on recovery (mirror the C-210-8 notification guards). This is the one behavioral change in the build; keep it bounded and observable.

### Task D — Explicit recovery / restart markers

- [ ] Emit a `cold_launch` / `central_reinit` event with a `reason=` field (process launch vs Task-C self-reset vs manual).
- [ ] Add a debug marker (watch debug screen button) the user can tap: "restarted to fix signal loss," logged as a distinct event.
- **Hypothesis:** recovery cause is currently only *inferred* from `will_restore_state`.
- **Pass/fail:** each episode's recovery is unambiguously attributable to {Trio restart, Task-C self-reset, Dexcom-app restart (still invisible to us), self-heal} instead of inferred.

### Task E — Reanchor / session-churn co-factor analysis — ✅ DONE (analysis only, no code)

- [x] Query the 15 min before each stall-episode onset for Trio session churn (reanchor, `ext_session_did_invalidate`, `ext_session_started`) across the build-215 window.
- **Result:** **No evidence session churn triggers stall onset.** Reanchors occur mid-episode near session expiry, not as lead-ins; the ~5-min proximity of some onsets to `ext_session_started` is confounded by app-foregrounding + the 15-min staleness detector re-arming (staleness pre-dated the session start).
- **Higher-value finding:** stall episodes **persist unbroken across session/reanchor restarts** (e.g. 06-30 08:25→10:05 continued through a full reanchor + new session at 09:05:49). Session-level recovery is ineffective for these episodes → this is the evidence base for Task C and explains why a manual both-apps restart was required.
- **Disposition:** no controlled reanchor-on/off A/B is warranted from this signal; reanchor is not implicated. Fold the finding into Task C's justification.

---

## Suggested sequencing

1. **Tasks A + B** — instrumentation that makes every future episode classifiable (biggest diagnostic leverage; low risk, additive).
2. **Task D** — cheap supporting markers so recovery cause is measurable.
3. **Task C** — the one behavioral change; only meaningfully measurable once A/B/D are shipping. Reduces manual intervention if it works.
4. **Task E** — ✅ complete; no further action.

## Open questions (carry into soak review)

- Does RSSI actually vary between healthy and stall windows, or is it flat (arguing against proximity)? (Task A)
- In the `connect_called=0` gaps, is the scan running at all? (Task B) — this single answer redirects the whole investigation.
- Can a CoreBluetooth central re-init recover a Dexcom-side episode that a new session cannot? (Task C)

---

## Fable 5 candidate ideation (2026-07-04)

**Provenance:** ideation + feasibility-validation session (read-only; no code changes). Inputs: `egv-intervention-index.md` (incl. the 2026-07-04 culled candidate pool), builds 206/207/212 constraint docs, `trio-fable5-review.md`, the `watch-direct-ble-cgm` cross-implementation docs (05/06/07/09), fork code @ `3814758`, adapter @ `feature/watch-g7` (build 215), and fresh BetterStack pulls over the **full 182 h build-215 soak** (Jun 26 → Jul 4, sensor n=1). Build 216 has **not** shipped — no 216-A/B data exists yet.

### Fresh evidence this section rests on (full-soak build 215; supersedes the early-soak baseline above)

| # | Signal | Numbers |
|---|--------|---------|
| E1 | Two-layer funnel, post-connect cliffs now stage-attributed | `connect_called` 3708 → `did_connect` 1227 (33.1%) → `gatt_ready` 1226 → `auth_notify_subscribed` 1027 → `auth_authenticated_bonded` 727 → `control_notify_subscribed` 716 → `egv_received` 672. The −199 at gatt→auth-subscribe ≈ exactly the GATT command timeouts: `command_timeout op=discover_services` **102** + `op=set_notify_authentication` **91** + `op=discover_characteristics` 8 (fork runs these with a **2 s** timeout); plus `configure_block_skipped` 559, `configure_retry_scheduled` 146 / `abandoned` 83, `auth_notify_failed` 91. The −300 at the auth gate: `auth_value_received gate_passed=false` 586 — **all opcode `0x03` challenge packets** (random payload bytes; zero failed-`0x05` statuses), i.e. the sensor drops the passive observer before ever sending the `0x05` session status. |
| E2 | `pre_egv_disconnect` is ~67% phantom | 1051 of 1566 events carry `since_connect_s<0` (adapter disconnect handler ran with no preceding `did_connect` bookkeeping); 862 of those are stamped `ext_session_active=true`. These line up with the **1228 `connect_timeout`** watchdog cancels. True connected-then-dropped: ~515 (352 @ 0–2 s, 156 @ 3–10 s); `suspected_eos=true` 203 (13%). |
| E3 | The connect-watchdog cancel is ineffective ~30% of the time | `connect_timeout` age distribution: 857 @ 60–70 s (first tick), but **240 @ 201–400 s and 115 @ >400 s** — the same attempt re-cancelled every 60 s while CoreBluetooth stays `.connecting`. `connect_timeout_reissue` only 14. `cancelPeripheralConnection` on a wedged pending connect frequently does not clear it. |
| E4 | Dead-attempt hours dominate deep-gap hours 2.5:1 | Of 172 soak hours: 121 awake (heartbeat>0), 75 with ≥1 EGV, **33 with connect attempts but zero EGVs**, **13 awake with `connect_called`=0** (the Task-B deep-gap signature). Tasks A/B target the 13; nothing in the plan targets the 33. |
| E5 | Attach path & session split | `attach_path`: `stored_id` 2279 (88%), `miss` 140, `scan` 139, `connected_peripherals` 21. Session-active yield 92% (194/210) vs no-session 49% (478/981); full-soak session coverage ~26% of scene-attributable connects (down from 44% early-soak — app-open behavior, not code). Backfill: `backfill_finished` 78, `backfill_entry` 38, `background_gatt_skipped` 461. |

**Framing insight that killed several wake-flavored ideas:** the bound path attaches via a daemon-level *pending connect* (`stored_id`, 88%), which is armed ~continuously and completes without app CPU — CoreBluetooth itself wakes the app on `didConnect`. So "wake the watch at the right moment" ideas add nothing; the losses are (a) the pending connect not completing (67% of `connect_called`), and (b) connections dying between `gatt_ready` and EGV (45%).

### Ranked candidates (survivors)

#### W-1 — Raise the 2 s GATT command timeout on the watch (background-gated), with a state-stamped discriminator
- **Class:** NEW. Not in the index. (The B190/B191 `discoveryTimeout` entries concern the retired `G7DirectBLEManager` stack; the "no connect timeout" prohibition concerns the CB *connect attempt*, not GATT command waits.)
- **Attacks:** E1's −199 cliff (gatt_ready → auth_notify_subscribed), ≈201 lost connections/182 h ≈ 16% of all post-connect loss.
- **Hypothesis:** on a background-starved watch, GATT discovery/CCCD-write callbacks routinely land just past the fork's 2 s `runCommand` wait; the timeout converts a live connection into `configure_block_skipped` → retry-backoff churn that the ~6–10 s transmitter window can't absorb.
- **Change:** (1) *first*, stamp `peripheral_state=` + `central_state=` into `command_timeout` (one line in `G7PeripheralManager.runCommand`, `G7PeripheralManager.swift:380`) — discriminates dead-link timeouts (state ≠ connected ⇒ raising the timeout wins nothing) from starved-CPU timeouts; (2) raise `applyConfiguration(discoveryTimeout:)` (`G7PeripheralManager.swift:271`, default **2 s**) to ~6 s **watch-side only**, gated via the existing `G7BackgroundHints` pattern so iPhone behavior is untouched.
- **Feasibility evidence:** timeout literal and `runCommand(timeout:op:)` at `G7PeripheralManager.swift:271, 345–387`; `command_timeout op=` labels shipped in 215 (fork `3814758`) already isolate the ops. Lock-inversion that once made long waits dangerous was fixed (C-208-12, `queue.sync→async`).
- **Compliance:** passive; no protocol change; no reconnect-loop suppression; fork-first via `repin-g7.sh`, watch-gated.
- **Refutation attempt (survived):** "the 2 s expiry just means the link is already dead." Possible — that is exactly what step (1) measures before step (2) ships. Cost of being wrong is bounded: a longer wait on a dead link only delays the disconnect callback path, which arrives independently on `managerQueue`.
- **Pass/fail:** `command_timeout op=discover_services|set_notify_authentication` per 100 connects drops ≥50%; `gatt_ready→auth_notify_subscribed` conversion 84% → ≥92%; `egv_received`/`did_connect` does not regress. **Not blocked on 216-A/B.**
- **Category:** capture.

#### W-2 — Stall-scoped scan-while-bound: peripheral-identity refresh on hard Dexcom-side stall (refines Task C)
- **Class:** SUBTLE-VARIATION — of culled pool **#5** ("stale CBPeripheral-handle refresh", rejected because the handle is already re-retrieved and CB vends one instance per identifier) and of **NOT-1.0** ("CB scan fallback after N failures", rejected as contention + complexity). **Load-bearing differences:** (a) pool #5's rejection addressed *handle* refresh for the *same identifier* — it did not consider that the stored **identifier→address mapping itself** can go stale (BLE address rotation / bluetoothd db drift), for which re-retrieval by UUID is definitionally useless and only a *scan* can rediscover the sensor under a new identifier; (b) NOT-1.0's premise ("won't find the sensor while the Dexcom app holds a session") does not hold in this sub-case — the G7 demonstrably accepts concurrent centrals and advertises while phone-connected (the observer's entire premise), and during `fault=dexcom_side` episodes the Dexcom watch app's own direct link is *also* down. This is stall-scoped (once per ≥30 min hard episode), not failure-count-scoped.
- **Attacks:** the multi-hour dexcom_side episodes (E4's 33 dead-attempt hours; 95% of stalls; Task E showed session restarts don't recover them and recovery coincides with process relaunch) — plus E3's evidence that cancels don't clear the wedge.
- **Hypothesis:** during these episodes the bound path is structurally blind: `managerQueue_scanForPeripheral` scans **only when `activePeripheral == nil`** (`G7BluetoothManager.swift:326`), and a wedged `.connecting` peripheral keeps `activePeripheral` non-nil — so *no scan can ever run for the life of the episode*. If the sensor is reachable but under a rotated/changed identifier (the unbonded observer has no IRK; only the bonded phone resolves rotations → exactly `phone_fresh=true`), the pending connect waits forever on a dead address. A relaunch recovers because retrieval can `miss` (140 observed) → falls through to `connected_peripherals`/scan → rediscovers under the new UUID.
- **Change:** a fork hook (`scanForStallRecovery()` or similar) that starts a service-filtered scan *without* tearing down the pending connect, invoked by the adapter once per episode from the existing C-210-8 hard-stall classifier (`G7WatchSensorAdapter.swift:799–837`), logging `stall_scan_result uuid_changed=<bool> stored=<uuid> discovered=<uuid>`. The existing `.makeActive` re-bind machinery already handles an identifier change atomically (binding reset on differing identifier, `G7BluetoothManager.swift:592–602`; suffix-match accept `G7Sensor.swift:347–356`).
- **Feasibility evidence:** all cited code paths exist today; scanning while a connect is pending is legal CoreBluetooth; the re-bind path is soak-proven (C-210-6 review rounds).
- **Compliance:** passive (scan + connect only); does **not** suppress the reconnect loop (purely additive recovery); bounded (once per episode, hard-stall-gated, mirrors the C-210-5 alarm discipline); fork-first, watch-triggered.
- **Refutation attempt (survived):** "if the sensor simply isn't advertising (range/RF), the scan finds nothing." True — and then `uuid_changed` never fires and the scan is one bounded no-op per episode; the *negative* result still classifies the episode (complements 216-B) and definitively kills the stale-identity conjecture instead of leaving it conjecture. "Scan burns battery" — once per ≥30 min episode, bounded duration; negligible vs the 1228-cancel churn already running.
- **Pass/fail:** ≥1 episode recovering with `uuid_changed=true` without a preceding `will_restore_state` proves the mechanism (and makes Task C's re-init strategy identifier-aware); consistent `uuid_changed=false` + no discovery kills it cleanly. **Synergy with 216-A/B** (RSSI + scan-liveness would enrich classification) but **not blocked** — it generates its own discriminating signal.
- **Category:** capture (episode recovery) + resolves the plan's central unknown.

#### W-3 — Gap-conditional backfill subscribe in background
- **Class:** SUBTLE-VARIATION — of **C-209-11** ("skip backfill-subscribe + extended-version GATT in background", ✅ shipped as a battery/radio optimization). **Load-bearing difference:** C-209-11 is unconditional, and background is precisely where capture gaps accumulate — the optimization throws away the recovery mechanism exactly where it is needed. The narrow sub-case: keep the skip in steady state, but subscribe when the just-received EGV's `sequence` jumps >1 vs the binding's last-seen sequence (a known gap exists to fill).
- **Attacks:** E5 — coverage ≈50% of sequences; `background_gatt_skipped` 461 events/182 h are post-EGV background connections that never armed backfill; only 38 `backfill_entry` captured all soak.
- **Hypothesis:** a successful background connection after a missed window can recover the missed reading(s) via the sensor's push-based backfill, converting single-capture windows into gap-closing ones.
- **Change (fork):** track `lastSequence` in the binding-scoped state (`BindingBLEState`, `G7BluetoothManager.swift:140–163`) or in `G7Sensor`; in `handleGlucoseMessage` (`G7Sensor.swift:207–234`), replace `if skipBackgroundGATT` with `if skipBackgroundGATT && !sequenceGapDetected` for the backfill-subscribe branch only (extended-version stays skipped). Parsing/flush already shipped (B192: `G7Sensor.swift:395–425`).
- **Compliance:** subscribe-only, push-based, `0x59` terminates — no control write, fully inside the passive contract (the prohibited thing is *actively requesting* backfill, C-04-C1b; this is not that). Watch-gated by construction (`skipBackgroundGATT` is already the watch-only hint); iPhone path unchanged.
- **Refutation attempt (survived):** "the sensor may push little/nothing to a passive observer." Partially true — 78 `backfill_finished` vs 38 entries (≈0.5/subscribe) — but today's subscribes happen only in *foreground* connections where gaps are rare; the observed low yield is plausibly selection bias. Cost of being wrong: one extra CCCD subscribe on gap-following background connections only. "Backfill ≠ live reading" — correct; labeled honestly below. "Sequence tracking could false-fire across sensor swaps/reconnects" (second-model critique): fail-safe by construction — keep `lastSequence` in the **binding-scoped** `BindingBLEState` (reset on `forgetPeripheral` and on `.makeActive` re-bind to a different peripheral), so a fresh binding has no baseline and detects no gap → no subscribe; only a same-binding jump triggers.
- **Pass/fail:** `backfill_entry` count per gap-following background connection >0; distinct-sequence daily coverage (M1 metric) rises measurably; no `pre_egv_disconnect` increase on those connections. **Not blocked on 216-A/B.**
- **Category:** capture/coverage (history completeness) — **not** real-time display freshness; say so in any readout.

#### W-4 — Connect-watchdog escalation: stop the blind 60 s cancel loop
- **Class:** SUBTLE-VARIATION — of **C-212-1** itself (✅ shipped), respecting the index's rejection of *removing* bounded watchdogs ("naive connect timeout" is the rejected thing; C-212-1 is sanctioned). **Load-bearing difference:** C-212-1 assumed `cancelPeripheralConnection` works; E3 (240+115 timeouts at age >200 s) shows the cancel fails to clear a wedged `.connecting` ~30% of the time, so the watchdog degrades into a 60 s cancel/re-cancel loop that (a) never recovers the attempt and (b) manufactures the 1051 phantom disconnect callbacks (E2), each of which briefly tears at the daemon-level pending connect that is the bound path's only catch mechanism (E5: 88% `stored_id`).
- **Attacks:** E2 + E3; the residual low per-attempt connect success (33%).
- **Hypothesis:** after the first ineffective cancel, repeating the identical cancel is pure churn; escalating (W-2 scan / Task C central re-init) recovers wedges the cancel cannot, and stretching the re-cancel cadence toward the iPhone's no-timeout north star reduces churn without re-opening the build-211 multi-hour-stall hole (a 5-min escalation still bounds a wedge to one reading cycle).
- **Change (fork):** in `scheduleConnectTimeout` (`G7BluetoothManager.swift:542–578`), count consecutive ticks on the *same* `connectIssuedAt`; tick 1 = today's cancel; tick ≥2 while still `.connecting` = emit `connect_wedge_persistent` and escalate (invoke the W-2 scan hook and/or surface to the adapter for Task C's central re-init) instead of re-cancelling every 60 s.
- **Compliance:** keeps a bounded watchdog (no blocking timeout added, none removed); no reconnect-loop suppression; fork-first, behavior identical on iPhone unless the same wedge occurs there (in which case escalation is equally correct — but can be watch-gated if preferred).
- **Refutation attempt (survived):** "maybe repeated cancels eventually work." The age distribution says otherwise — 115 attempts still `.connecting` past 400 s (≥6 cancels). "Escalation could thrash": it is entered only after a proven-ineffective cancel, once per attempt, and Task C's re-init is already the plan's chosen hammer — this just aims it at a measured trigger instead of a 30-min stall classifier alone.
- **Pass/fail:** `connect_timeout` events with age >200 s → ~0; phantom `pre_egv_disconnect` (`since_connect_s<0`) drops materially from 1051; `did_connect`/`connect_called` rises above 33%. **Not blocked on 216-A/B** (pairs naturally with Task C/D markers).
- **Category:** capture.

#### W-5 — `CBConnectPeripheralOptionEnableAutoReconnect` experiment (bounded, after W-4)
- **Class:** NEW. Never appears in any project doc. **API verified against the watchOS SDK on this machine** (not from memory): `CBCentralManagerConstants.h:213–222` declares the option ("after peripheral device is connected, this will allow the system to initiate connect to the peer device automatically when link is dropped"), and `CBCentralManager.h:349–365` declares the paired `didDisconnectPeripheral:timestamp:isReconnecting:error:` delegate. Soak device runs watchOS **26.5** (`os_version` telemetry) — far past the introduction floor.
- **Attacks:** the re-arm dependency: today every post-EGV/remote disconnect needs app CPU (`scanAfterDelay` → reissue) to re-arm the pending connect; with auto-reconnect, bluetoothd re-arms itself and the app just receives `didConnect`.
- **Hypothesis:** daemon-owned reconnect (i) survives app suspension/death between disconnect and re-arm with no gap, and (ii) removes some of the cancel/reissue interplay implicated in E3's wedges.
- **Change (fork, watch-gated):** pass the option at the connect site (`G7BluetoothManager.swift:435`, currently `centralManager.connect(peripheral)` with no options) behind a `G7BackgroundHints`-style watch flag; implement the new delegate method and skip `scanAfterDelay()` when `isReconnecting == true` (system owns the retry) — the old callback path remains for non-auto-reconnect peers, so iPhone behavior is bit-identical.
- **Compliance:** passive; the fork's own loop is not suppressed — it is *superseded per-disconnect by the OS's stronger version of itself*, with the fallback intact; fork-first, watch-gated.
- **Adversarial (why it ranks low, honestly):** the incremental value over the existing ~always-re-armed pending connect may be near zero — the current re-arm already works whenever the app gets its disconnect callback (which `bluetooth-central` background mode grants). It also complicates C-212-1 bookkeeping (`connectIssuedAt` desyncs when the system reconnects unprompted) — which is why it must **follow** W-4, not accompany it. Kept because it is the only untried, API-real mechanism that changes *who owns* the reconnect, and the failure documented in E3 lives in exactly that machinery.
- **Pass/fail:** A/B across builds: `did_connect`/`connect_called`, wedge-age distribution, and no-session yield (49% floor) — any regression reverts the flag. **Not blocked on 216-A/B.**
- **Category:** capture (experimental).

#### W-6 — Telemetry: split phantom `pre_egv_disconnect` out of the metric
- **Class:** NEW (telemetry). **Attacks:** E2 — 67% of the plan's headline `pre_egv_disconnect` metric is watchdog-cancel fallout with no preceding connect, which has been silently inflating the "drops within seconds" narrative (the true 0–9 s population is ~515, not 1566).
- **Change (adapter):** in `handleSensorDisconnected` (`G7WatchSensorAdapter.swift:1233–1310`), when `sessionConnectAt == nil` emit `phantom_disconnect` (or stamp `had_connect=false`) instead of `pre_egv_disconnect`.
- **Compliance/refutation:** trivial, additive, no behavior. Survives by necessity: W-2/W-4's pass/fail criteria are unmeasurable while the metric conflates the two populations.
- **Pass/fail:** post-ship, `pre_egv_disconnect` ≈ true connected-then-dropped population; dashboards updated. **Category: telemetry only** (labeled honestly) — but it gates measuring W-2/W-4.

### Ranking rationale (impact × feasibility)

1. **W-1** — smallest change, precisely quantified target (~200 connections/week), self-discriminating rollout.
2. **W-2** — largest potential impact (the multi-hour episodes are the dominant coverage killer) *and* it resolves the plan's central unknown either way; medium effort.
3. **W-4** — direct response to the new E3 evidence; pairs with Task C/W-2; medium effort.
4. **W-3** — honest-label coverage recovery; small bounded fork change.
5. **W-6** — cheap; prerequisite for measuring 2–4.
6. **W-5** — real but speculative; run only after W-4 stabilizes the same machinery.

Non-candidate observation for the soak readout: full-soak session coverage fell to ~26% (vs 44% early-soak) with session-active yield steady at 92% — this is app-open/RTC user behavior, not a code regression; no code candidate exists (the reanchor + RTC levers are already documented).

### Validation update (2026-07-04, second-session cross-check of W-2)

A second session challenged W-2 with two claims. Both sets of **numbers verified**; both **inferences failed** verification against the code and the event stream. Recording all of it so neither the invalid arguments nor the original W-2 framing get re-tread.

**Claim 1 — "rotation ruled out: all 140 `attach_path=miss` events have `has_identifier=false`."** Numbers confirmed (140/140). The inference is invalid twice over: (a) `retrievePeripherals(withIdentifiers:)` resolves any UUID bluetoothd has ever seen — an address rotation does **not** purge the UUID record, so retrieval keeps succeeding against a stale mapping and `miss has_identifier=true` is not a rotation fingerprint; (b) `activePeripheralIdentifier` is in-memory (`Locked`, [G7BluetoothManager.swift:108–121](../../..//G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift)) and nil after every relaunch, so `has_identifier=true` misses are structurally near-impossible regardless of rotation. The test has ~zero discriminating power. **Rotation is untested by this data, not ruled out** — though one genuinely valid anti-rotation datum did surface below (same-UUID rediscovery by scan).

**Claim 2 — "the 06-30 09:00 deep gap shows zero `connect_timeout`, therefore no pending connect exists, therefore no wedge — just no advertisement."** Zero-counts confirmed (08:30–10:45: heartbeats + expected_window only; `connect_called`/`attach_path`/`connect_timeout`/`disconnect` all 0). The middle inference is **refuted by the gap-entry event stream** (raw pull, 2026-06-30 07:40–08:35 UTC):

- **07:49:04 / 07:59:17 / 08:19:08** — three process relaunches, each `will_restore_state restored_peripherals=4`, each immediately followed by `connect_called intent=makeActive` → **`connect_skipped reason=in_flight state=1`** (`.connecting`): CoreBluetooth preserved a *pending connect* across relaunch. The C-212-1 watchdog never arms for it — arming requires a this-process connect issue on the active binding (`connectIssuedAt` set at [G7BluetoothManager.swift:438–441](../../../G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift)); the skip branch adopt-clause covers `.connected` only (`:409–413`). **Zero `connect_timeout` therefore means "no *watched* pending connect," not "no pending connect."**
- **08:23:45** — app-open rebind path scanned and **`didDiscover` fired for the same UUID `F42CA099…`**: the sensor *was* advertising to the watch one minute before the silence (and `phone_fresh=true` throughout — the sensor was transmitting). This simultaneously (i) falsifies "no advertisement" as the gap-entry state and (ii) is the one *valid* anti-rotation datum: the scan rediscovered the sensor under the **same** identifier.
- **08:24:07** — fresh discovery-mode connect issued (`intent=connect`; unbound branch) — which **also never arms the watchdog** (C-212-1's documented accepted limitation E: no timeout for unbound discovery connects). It never completed; with a held `.connecting` peripheral, no callbacks, and no scan re-entry, every telemetry-emitting path goes structurally quiescent — exactly the observed 2-hour silence, ending only with the 11:00/11:45 relaunches (matching Task E's recovery-by-restart finding).

**Corrected dispositions:**
- **W-2 — downgraded to diagnostic-only, folded into W-4/W-7.** Its rotation motivation is weakened (untested + one valid same-UUID counter-datum), and the silent gaps are better explained by W-7 below. Its `uuid_changed` log survives as a cheap stamp on any W-7/Task-C recovery scan; do not build W-2 standalone.
- **The silent deep gaps are (at least sometimes) unwatched wedged pending connects, not proof of no-advertisement.** 216-B (scan-liveness) remains the right instrument to size how often each case occurs — but the 06-30 flagship gap itself is now positively identified.

**Third-session independent re-check (2026-07-04):** verified against the raw gap-entry stream (06-30 07:40–08:35) and the fork code, concurring with this section. Confirmed: the three `will_restore_state restored_peripherals=4` relaunches (07:49/07:59/08:19) each followed by `connect_called intent=makeActive F42CA099…` → `connect_skipped reason=in_flight state=1`; the 08:24:07 `connect_called intent=connect F42CA099` after a scan (sensor was advertising). Code confirms the blind spot: `connectIfNotInFlight` ([G7BluetoothManager.swift:399–441]) adopts only `.connected` in the in-flight-skip branch (`:409`) and arms `scheduleConnectTimeout` only on a freshly-issued connect matching `activePeripheralIdentifier` (`:438–440`) — so restored/unbound `.connecting` connects wedge with zero `connect_timeout`. The two prior "rotation ruled out" / "no-advertisement" conclusions are **withdrawn** (the `has_identifier` test is non-discriminating; the sensor was advertising). Two sessions concur on W-7.

#### W-7 — Close the C-212-1 watchdog blind spots: restored and discovery-mode pending connects are unwatched
- **Class:** NEW — surfaced by this validation pass; evidence-matched to the 06-30 08:25→10:45 flagship episode above.
- **Attacks:** the deep-gap hours (E4's 13 awake-no-connect hours) and the recovery-only-by-manual-restart pattern (Task E).
- **Hypothesis:** a pending connect that this process never issued (CB-restored `.connecting` across relaunch) or issued unbound (discovery `.connect` branch) has no watchdog, no timeout, and suppresses all downstream telemetry and scanning — a wedge that is *invisible by construction* and recoverable only by relaunch.
- **Change (fork):** either (a) **arm-on-adopt** — in the `connect_skipped reason=in_flight` branch, when the peripheral is `.connecting` and no `connectIssuedAt` is pending, seed `connectIssuedAt` + `scheduleConnectTimeout` so the standard escalation applies; or (b) **cancel-on-restore** — in `willRestoreState`, cancel CB-preserved *pending* (`.connecting`) connects before re-attaching — which is exactly the old stack's **C-04-B0** policy (index, ✅ build 04) that was never carried into the fork. Also extend watching to the unbound `.connect` branch (C-212-1's accepted limitation E, now measured at ≥1 two-hour episode).
- **Compliance:** bounded-watchdog family (sanctioned by C-212-1 precedent, not the rejected naive blocking timeout); no reconnect-loop suppression; fork-first; behavior on iPhone is the same fix for the same latent hole (or watch-gate if preferred).
- **Refutation attempt (survived):** "maybe the restored pending connect would eventually complete and watching it is redundant" — 06-30 shows it sat ≥2 h through three relaunches while the sensor was demonstrably discoverable by scan; the unwatched state is strictly worse than either cancel or watch. "Cancel-on-restore might drop a healthy about-to-complete connect" — cost is one reissued connect (the C-04-B0 policy ran for months in the old stack).
- **Pass/fail:** deep gaps with the fingerprint (`will_restore_state` → `connect_skipped state=1` → silence) disappear or convert into watched `connect_timeout`/escalation cycles; awake-no-connect hours shrink from 13; episode recovery no longer requires `will_restore_state`. **Not blocked on 216-A/B** (though 216-B corroborates).
- **Category:** capture — and it directly serves the plan's stated goal (self-recovery without manual restarts), sharpening Task C's trigger.

**Updated ranking:** W-7 slots at **#2** (evidence-matched to the flagship episode, small bounded change); W-2 drops out of the ranking (diagnostic stamp only); everything else unchanged: W-1, W-7, W-4, W-3, W-6, W-5.

### Build 216 manifest (2026-07-04 — supersedes "Suggested sequencing" above)

Discipline: **instrumentation-heavy, ONE behavioral change**, so the n=1 soak stays attributable (the property that made 206→215 diagnosable).

**Ship — instrumentation (additive, no control-flow change):**
- [x] **Task A** — RSSI: fork `did_discover` event (per-advertisement RSSI) + `rssi_read` on connected `readRSSI()`; `last_rssi=`/`rssi_age_s=` stamped onto `attach_path`, `connect_timeout`, and (adapter) `direct_ble_stall_detected`. *(Note: literal per-event RSSI on connectionless events is impossible — last-known + age is the honest form.)*
- [x] **Task B + W-7a** — BLE diagnostics on `heartbeat`: fork-exposed thread-safe snapshot (`central_state`, `scan_active`, `active_peripheral_state`, `connect_pending_age_s`, `s_since_discover`, `last_rssi`) + adapter-side `connecting_ticks` counter. Makes the 06-30 unwatched-wedge state visible per-heartbeat and buckets the deep gaps (Task B's decision tree). Subsumes W-2's diagnostic residue: `did_discover` logs peripheral UUID, so a stall-time rediscovery under a new identifier is directly queryable.
- [x] **Task D** — `cold_launch` marker (once per process) + debug-screen "restarted to fix signal" button → `manual_recovery_marker`. (`central_reinit` reason reserved; no re-init ships in 216 — see Task C re-scope.)
- [x] **W-6** — split phantom disconnects: `pre_egv_disconnect` with `since_connect_s<0` renamed to `phantom_disconnect` (fields/behavior identical; telemetry-only).
- [x] **W-1 stage 1** — `peripheral_state=`/`central_state=` stamped into `command_timeout` (decides the 217 timeout raise).

**Ship — the one behavioral change:**
- [x] **W-7** — arm the C-212-1 watchdog for adopted in-flight connects (restored `.connecting` peripherals skipped as `in_flight` on the active binding), plus a bounded watchdog for unbound discovery-mode connects (the C-212-1 accepted-limitation-E hole; both halves of the 06-30 fingerprint). Fable-implemented, full review loop — this is the same risk class as C-212-1 itself (5 review rounds).

**Task C re-scope:** W-7 **is** 216's self-recovery attempt — targeted at the measured wedge instead of a blunt central rebuild. The full central re-init moves to 217, gated on W-7's soak: if classified episodes still show unrecovered wedges (or `scan-running-no-candidate` buckets that a re-init could plausibly clear), build it then, keeping the C-210-8 hard-stall trigger + once-per-episode guard already specified above.

**Deferred (deliberately, one change per build):** W-4 (watchdog escalation — wants W-6/W-7a data), W-1 stage 2 (2s→6s raise — wants stage-1 data), W-3 (gap-conditional backfill — clean second change for 217), W-5 (auto-reconnect — after W-4 stabilizes the same machinery).

**Model assignment (implementation):** fork/adapter instrumentation → Sonnet subagents with a frontier-model full-diff review; W-7 + Task C re-scope + final review → Fable; patch mechanics (`repin-g7.sh`, `mid-stack-update.sh --patch 09`, `patch-test.sh`) scripted; soak analysis → Opus routine / Fable on verdict changes.

### Graveyard (generated this session, killed by validation — do not re-tread)

| Idea | One-line kill reason |
|---|---|
| Relax the auth gate to authenticated-only (DiaBLE-parity fallback, Synth-MOD-B revival) | **Killed by data:** all 586 `gate_passed=false` events are `0x03` challenge packets with random payload bytes; the authenticated-but-not-bonded `0x05` population is zero — there is nothing to admit. |
| Early control-notify subscribe (don't wait for `0x05`) | Deviates from the proven normative observer sequence (B189/DiaBLE); the −300 drops are sensor-initiated *before* `0x05`, and a CCCD write doesn't change the transmitter's decision to drop a silent peer. |
| Phone→watch WC wake (post-EGV or predictive pre-window) | The daemon-level pending connect is armed ~24/7 and CB itself wakes the app on `didConnect` — wake timing is not the failure mode; post-EGV wake is circular (culled pool #2's cousin); WC delivery latency is unbounded. |
| Shorten the connect watchdog (60 s → 15–25 s) | Backwards: E3 shows cancels are the ineffective/churny part; more cancels = more phantom disconnects, zero extra connects. |
| Scan-option tuning (allowDuplicates, broader UUIDs, second scan pass) | Bound path doesn't scan at all (88% `stored_id`); background scans coalesce advertisements; no target population. |
| Skip/trim the auth handshake on reconnect | Sensor-driven and required every connection — BUG-D refuted (build-212 log); handshake is fast (p90 1.4 s), not the bottleneck. |
| Window-anchored radio arm/disarm (epoch−30 s…epoch+5 min) | Culled pool #4: no quiescence primitive to disarm; the arm side is already effectively always-on via the fork loop. |
| Respond to `0x03` / bond the watch to the sensor | Active protocol participation — violates the passive-observer contract outright. |
| HKObserver / WKApplicationRefresh wake → connect | Constraint 1: neither can reliably host a fresh connect+auth; both already culled (pool #2/#3) with no new mechanism to cite. |
| Second `CBCentralManager`, link-parameter tuning, stay-connected between readings | API-impossible (central can't set link params; one restore-id central) or transmitter-side physics (post-EGV BLE shutdown is normal) — all in the Rejected/Prohibited table. |
| GATT-db pre-warm / forced OS-level caching | No API; CB caches per-connection at its own discretion (`servicesToDiscover(from:)` already exploits what exists). |
