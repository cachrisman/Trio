# Instrumentation report: Watch — Dexcom G7 direct BLE eavesdrop

**Version:** v1.35
**Status:** Adopted (observer-mode instrumentation baseline; Phase E build 162, Phase F / F1 build 163, Phase F / F2 build 164, Phase F / F3 build 165, Phase F / F4 build 166, and Phase F / F5 build 168 implemented / deployed in `Trio`. Build 168 is now live, and the new F5 instrumentation is confirmed in Better Stack: dual retrieval-result lines, explicit retrieval-source attribution, pre-connect state / identifier fields, and the new post-connect callback probes are all deployed. The current build-168 conclusion is narrower but clearer than the build-166 result: there are still no watch-side post-connect milestones in current volume because all observed build-168 connect attempts remain `source=scan`, while retrieval on both **data service** and **FEBC** has so far returned zero candidates. PacketLogger / raw capture remains deferred for now because the watch-only log trail is still yielding decision-grade attribution.)
**Created:** 2026-04-12 12:52 CET  
**Last updated:** 2026-04-18 10:05 CEST

**Design:** [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md)  
**Implementation plan:** [watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md)  
**Code (Trio worktree):** `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/WatchState.swift`; iPhone: `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, `Trio/Sources/Models/WatchMessageKeys.swift` ( **`active_g7_peripheral_name`** field )

**Note on versioning:** The **Version** field in this document’s header is the **controlled edition**; revisions **v1.1+** are **feedback-driven** updates documented in the [Changelog](#changelog). Informal drafts of this spec existed before the initiative file.

---

## Purpose

This report defines **Better Stack / `WatchLogger`-friendly** instrumentation for the **G7 direct BLE** path so operators can **reconstruct stalls**, **attribute timeouts**, and **separate BLE issues from normal watch lifecycle** transitions — **without** turning the watch extension into a general-purpose app logger.

**Scope boundary:** **BLE manager + narrow lifecycle correlation** only. Not an app-wide logging expansion.
**Mode boundary:** This report covers the **watch direct BLE observer** path only. The separate **phone-relay / WatchConnectivity** watch mode is outside this instrumentation contract except where WC arms the active-sensor-name filter for the direct BLE session.

**Alignment with design [v1.1+](watch-direct-ble-cgm-01-design.md):** The design requires structured `event=g7_ble_*` logs for critical transitions; this report **extends** that with session ids, stage transition discipline, timeout/teardown semantics, lifecycle correlation fields, and bounded protocol logging.

---

## Log line attribution (`WatchLogger`)

**Normative (manager):** `G7DirectBLEManager` logs through private **`logG7Ble`**, which appends **`g7_session=`** when needed and forwards **`#fileID`**, **`#line`**, and **`#function`** into **`WatchLogger.shared.log`**. Phone / Better Stack consumers that parse **`file`**, **`lineNumber`**, and **`method`** (or the bracketed prefix in **`raw`**) therefore see the **syntactic call site** of **`logG7Ble`**, not the helper’s definition.

**Expectations:**

- Calls from **`Task { await logG7Ble(...) }`** (typical for CoreBluetooth delegate callbacks) attribute the line of **`await logG7Ble`** **inside that task**, not the first line of the enclosing delegate method.
- **`async`** call sites that **`await logG7Ble`** directly (e.g. timeout handling) attribute that **`await`** line and function name.
- This does **not** change **`event=`** strings or **`g7_session`** rules elsewhere in this report; it only fixes **metadata** attribution for operators.

---

## Snapshot: current implementation vs this spec

As of **Task C3 Tier 1** + **Tier 1 follow-on** in the **`Trio`** worktree (see **[watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md)** — **Version** there is authoritative). **Gap column** below is **this report** when behavior still differs; many rows are **aligned** post–Tier 1.

| Area | Current behavior (post–Task C3 Tier 1) | This report (gap / stretch) |
|------|----------------------------------------|-----------------------------|
| **Session id** | `g7_session=<uuid>` per `startScanning()`; `logG7Ble` appends on `g7_ble_*` | **Met** — all `g7_ble_*` in-cycle + lifecycle lines with session |
| **Stage labels** | `event=g7_ble_stage` transition-only (`scanning` … `awaiting_egv`) | **Met** — milestone-backed; **`discovering_characteristics`** emitted **before** `discoverCharacteristics` (not after discovery completes) |
| **Milestone events** | Tier 1 discovery / notify / write / connect-attempt lines | Tier 2–3 extras where listed below still **stretch** |
| **Service/characteristic success path** | `g7_ble_services_discovered`, `g7_ble_characteristics_discovered` | **Met** |
| **Notify readiness** | `g7_ble_notify_state char=auth\|control\|backfill notifying=true`, plus explicit `g7_ble_auth_notify_enabled`, `g7_ble_jpake_skipped`, and `g7_ble_control_notify_enabled` | **Met** for the observer proof set; **F5** can still tighten per-characteristic entry / failure attribution |
| **Write OK** | `g7_ble_write_ok write=egv_request` | **Met** for observer mode; the only required watch-side proof write is the `0x4E` request |
| **Timing** | `ms_since_discover` on `g7_ble_connected` | **Met** |
| **Timeouts** | `awaiting_connect` / `awaiting_gatt_setup` / `awaiting_first_egv`; `g7_ble_timeout` + teardown + dedupe; **GATT setup** timer clears when **auth notify**, **`0x05 authenticated=true bonded=true`**, and **control notify** are all satisfied | **Met in code**; **F5** should add clearer arm / cancel attribution if the post-connect boundary remains ambiguous |
| **Lifecycle correlation** | `g7_ble_lifecycle`: `phase=active` after **`applyForegroundActiveEntry`** ( **`g7_session`** when allocated or carried over ); **`phase=inactive`** + **`reason=scenePhase_change`** + **`ble_continues=true`** + **`active_window_s`** + **`active_window_ms`** — **no** implicit BLE stop; **`phase=background`** only when **scene** is **`.background`**, with **`ble_continues=true`**; **`reason=stop_requested`** is **not** emitted from scene phase (reserve for explicit **`stop()`** / future product off-switch) | **Met** — do **not** emit `phase=background` on inactive-only transitions |
| **Observer auth ownership** | Current watch code stays observer-only: no watch-side auth-init / app-key / J-PAKE ownership write | **Met** |
| **J-PAKE observer proof** | Current watch code discovers the characteristic for attribution and emits `g7_ble_jpake_skipped` without subscribing to J-PAKE | **Met** |
| **Status gate** | Current watch code emits `g7_ble_status_reply authenticated=true bonded=true` and only progresses on both bits | **Met** |
| **Control readiness gate** | Current watch code cancels `awaiting_gatt_setup` when **auth notify**, **`0x05 authenticated=true bonded=true`**, and **control notify** are all satisfied; `backfill` is optional follow-up only | **Met in code**; keep this under audit only for attribution / timing, not as an active parity gap |
| **Pre-connect state (Phase E)** | `event=g7_ble_pre_connect` immediately before `connect()`; includes **`is_connectable`**, **`discover_count_for_target`**, **`peripheral_id_short`**, **`manager_fresh`** (see Tier 1 item 11) | **Met** — **`G7DirectBLEManager`** (Phase E execution) |
| **Retrieve on `.poweredOn` (Phase E)** | `event=g7_ble_retrieve_on_powered_on` in `centralManagerDidUpdateState(.poweredOn)`; includes **`peripheral_id_short`** | **Met** — same |
| **State restoration (Phase E)** | `CBCentralManagerOptionRestoreIdentifierKey` + `event=g7_ble_will_restore_state` | **Met** — same |
| **Reconnect** | `g7_ble_reconnect_scheduled delay_s=7` | **Met** (Tier 2 line) |
| **Non-`0x4E` control** | `g7_ble_control_opcode` rate-limited | **Met** (Tier 3) |
| **WatchState manager** | `@ObservationIgnored private let g7DirectBLEManager`; `handleForegroundInactiveOrBackground(scenePhase:)` — **leave-active** invoked from **`TrioWatchApp`** SwiftUI **`ScenePhase`** only (not **`ExtensionDelegate`**); **does not** call **`stop()`** | Unchanged storage; **`ScenePhase.inactive`** / **`.background`** from **one** UI entry point |
| **Tier 1 follow-on (post–`b4dd0d7dd`)** | **`g7_ble_connect_failed`** (`error_domain` / `error_code` / `error_desc`); **`rssi=`** on **`g7_ble_peripheral_discovered`**; **`g7_ble_peripheral_skipped`** (`reason=not_active_sensor`) when **`activePeripheralName`** filters; **`WKExtendedRuntimeSession`** lifecycle lines; **`g7_ble_session_outcome`**; historical **`g7_ble_stop_deferred`** in older builds only | **Met** where implemented — see **Implementation plan** **Record — Tier 1 follow-on** |
| **Phone → watch G7 name (WC)** | **`event=g7_ble_active_name_applied filtered=true`** when **`applyForegroundActiveEntry`** applies a non-nil phone-supplied name (does **not** log raw peripheral name). **`g7_ble_foreground_reentry_skipped`** when a full **`startScanning()`** restart was skipped. **iPhone** sends **`active_g7_peripheral_name`** in nested **`watchState`** (see **Implementation plan** **Record — iPhone → watch active G7 peripheral name**) | **Met** — correlates filter use without **PHI** in logs |
| **Active sensor gate** | Direct BLE attach is blocked unless the phone-provided active sensor identity / name filter is armed and the discovered peripheral matches it; blocked cases emit `g7_ble_attach_blocked` or `g7_ble_peripheral_skipped` | **Met** for the current strict watch contract; the remaining open question is name-normalization asymmetry, not missing filter enforcement |
| **Extended session — foreground re-entry renewal** | When UI was away **(0, 3600)s**, **`renewExtendedRuntimeSessionAfterForegroundReentry`** may run: **`g7_ble_ext_session_ended reason=foreground_reentry_renewal`**, then **`g7_ble_ext_session_renewal reason=foreground_reentry away_s=<n>`**, **`g7_ble_ext_session_started`**. If away ≥ 3600s: **`g7_ble_ext_session_renewal_skipped reason=away_not_under_1h away_s=<n>`**. **`didInvalidateWith`** / **`willExpire`** use session **identity** — **`didInvalidateWith`** captures **current** session **before** clearing the pointer so **`g7_ble_ext_session_invalidated`** + **`error != nil`** still allows **`ext_session_invalidated`** teardown — see **design** § **Connection state model** | **Met** — see **design** **v1.15**, **Implementation plan** **v1.25** |

**Events already emitted (manager + watch state, non-exhaustive, pre-alignment snapshot):** `g7_ble_scan_started`, `g7_ble_error` (variants), `g7_ble_connect_failed` ( **`didFailToConnect` only** — not `g7_ble_error`), `g7_ble_peripheral_discovered` (incl. **`rssi=`**), `g7_ble_peripheral_skipped`, `g7_ble_connected`, `g7_ble_auth_request_sent`, `g7_ble_auth_challenge_received`, `g7_ble_authenticated`, `g7_ble_egv_received`, `g7_ble_snapshot_saved`, `g7_ble_disconnected`, `g7_ble_session_outcome`, `g7_ble_ext_session_started`, `g7_ble_ext_session_expiring`, `g7_ble_ext_session_ended`, `g7_ble_ext_session_invalidated`, **`g7_ble_ext_session_renewal`**, **`g7_ble_ext_session_renewal_skipped`**, `g7_ble_foreground_reentry_skipped`, `g7_ble_write_error_nonfatal`, **`g7_ble_active_name_applied`** (**`applyForegroundActiveEntry`** — **`filtered=true`** when a non-nil iPhone-supplied name is applied), **`g7_ble_connect_timeout_armed`**, **`g7_ble_connect_timeout_canceled`**, **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, and **`g7_ble_did_disconnect`**. Historical builds may still show **`g7_ble_stop_deferred`**.

**Phase E / build 162 events (implemented):** **`g7_ble_pre_connect`** (full field set per Tier 1 item 11 / **implementation plan** **v1.37**), **`g7_ble_retrieve_on_powered_on`**, **`g7_ble_will_restore_state`**, bounded **`peripheral_id_short`** on discover / retrieve / pre-connect — see Tier 1 item 11 and **implementation plan** execution log.

**Phase F / F1 events (implemented / build 163):** additive connect-boundary closure lines — **`g7_ble_connect_timeout_armed timeout_s=30`**, **`g7_ble_connect_timeout_canceled reason=…`**, **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, and **`g7_ble_did_disconnect`** — while retaining the existing higher-level **`g7_ble_connected`**, **`g7_ble_connect_failed`**, **`g7_ble_disconnected`**, and **`g7_ble_timeout`** events for dashboard continuity. Build **163** closed the connect trail without surfacing a watch-side connect callback. See **implementation plan** **v1.46**.

**Phase F / F2 parity build (implemented / build 164):** **`CBCentralManager(delegate:queue:options:)`** now uses **`queue: nil`** with **no new `g7_ble_*` event names**. Build **164** is intentionally compared against the unchanged **F1** event vocabulary so queue parity is the only code delta under review. The expanded watch-only Better Stack re-check now covers **7** distinct connect attempts and still shows **no** watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, or **`g7_ble_connect_timeout_canceled`** before **`g7_ble_timeout stage=awaiting_connect`**. See **implementation plan** **v1.46**.

**Phase F / F3 parity build (implemented / build 165):** both watch **`scanForPeripherals`** call sites now omit **`CBCentralManagerScanOptionAllowDuplicatesKey: false`** by passing **`options: nil`**. The **FEBC** service filter is unchanged, and all existing **F1/F2** event names remain unchanged so **F3** is a one-change-only build. The completed watch-only Better Stack review for build **165** is negative: **9** observed connect attempts still show the same closed trail as earlier builds, ending at **`g7_ble_timeout stage=awaiting_connect`** with no watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`**. This did **not** require any new F4 telemetry; it only set the baseline for the next parity build. See **implementation plan** **v1.46**.

**Phase F / F4 parity build (implemented / build 166):** **`CBCentralManager`** is now allocated earlier in **`G7DirectBLEManager.init()`**, while **`startScanning()`** normally reuses the already-lived manager and keeps the current **`queue: nil`**, restore identifier, retrieval behavior, and existing event vocabulary unchanged. Build **166** is now live, and the watch-only Better Stack review shows the first positive connect-boundary movement in this initiative: **17** observed connect attempts include **1** watch-side **`g7_ble_did_connect`**, **1** **`g7_ble_connected`**, **1** **`g7_ble_connect_timeout_canceled reason=did_connect`**, and **1** retrieval-assisted session whose final outcome is **`final_stage=discovering_services`** with **`g7_ble_timeout stage=awaiting_gatt_setup`**. The remaining **16** build-166 sessions still terminate at **`awaiting_connect`**. There are still **no** build-166 watch-side **`g7_ble_services_discovered`**, **`g7_ble_characteristics_discovered`**, **`g7_ble_auth_notify_enabled`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_egv_request_sent`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`** events. The instrumentation conclusion is therefore narrow: build **166 / F4** moved the connect boundary at least once, but it did **not** yet prove post-connect GATT startup or an end-to-end watch CGM read. **PacketLogger / raw capture** remains a **deferred parallel diagnostic track** while the current watch-only logs are still yielding actionable boundary movement. See **implementation plan** **v1.48**.

**Phase F / F5 diagnostic build (implemented / build 168):** the watch now emits the expanded attribution / retrieval vocabulary added for F5, including **`g7_ble_retrieve_result retrieval_uuid=data_service|febc`**, explicit retrieval-derived source labels (**`source=retrieved_data_service`** / **`source=retrieved_febc`** when used), richer **`g7_ble_pre_connect`** fields, and the new post-connect callback probes intended to close the **`didConnect -> services -> characteristics`** trail. The current de-duplicated build-168 Better Stack review shows the new lines working, but it also sharpens the live diagnosis: **17** observed build-168 connect attempts remain **`source=scan`**, there are **18** zero-result retrieval observations for **data service** and **18** for **FEBC**, and there are still **0** watch-side **`g7_ble_did_connect`**, **`g7_ble_did_discover_services`**, **`g7_ble_did_discover_characteristics`**, **`g7_ble_auth_notify_enabled`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`** events in current build-168 volume. The instrumentation conclusion is therefore different from build **166**: the current live result is not “retrieved succeeded more often,” but “retrieval is presently absent, so all live attach attempts still fall back to scan and time out before `didConnect`.” See **implementation plan** **v1.48**.

**Build 166 review search set (watch-only Better Stack, 2026-04-16):**

- grouped **`g7_ble_*`** counts by **`build`** and **`event`** for **`platform=watchos`**
- grouped **`g7_ble_session_outcome`** by **`final_stage`**
- grouped **`g7_ble_timeout`** by **`stage`**
- grouped **`g7_ble_connect_attempt`** by **`source=scan|retrieved`**
- expanded the full event timeline for the only build-166 session that emitted **`g7_ble_did_connect`**

Those searches are enough to explain the current outcome without inventing new telemetry: build **166** is the first watch build in this cycle to cross **`didConnect`**, but the first unsatisfied gate has moved only as far as **service discovery / GATT setup**.

**Post-F5 sequencing (planned)**

- Keep **F5** live long enough to collect more watch-only build-168 evidence; the new instrumentation is deployed and functioning.
- **F9** remains an analysis track, not a default code build: keep watch-only searches split by **scan** vs retrieved-derived sources, but interpret build **168** primarily as **retrieval absent** rather than **retrieval advantaged**.
- Only after a later build-168-or-newer session actually reaches **`didConnect`** should a new discovery-scope parity build be selected:
  - choose **F6** if the newly exercised post-connect trail still leaves the first missing post-connect callback at service discovery / data-service presence
  - choose **F7** if service discovery succeeds and characteristic discovery remains the first missing gate
- **F8** is an audit / attribution task unless later evidence reveals a real runtime mismatch in the startup-ready or timeout-cancel rule.

---

## Diagnosis

The gap is **not** “no logs,” but **missing reconstructable stage transitions**, **explicit stalls**, **cleanup tied to timeouts**, and **enough context to separate BLE stalls from normal watch lifecycle** (active / inactive / background / teardown). This document is written so an implementer can follow it **without** defaulting to “log more everywhere.”

## DiaBLE Observer Proof Set (2026-04-13)

`watch-direct-ble-cgm-04-diaBLE-logs.md` is now the primary behavioral proof
set for the watch observer path. Trio instrumentation must make the following
ordered sequence easy to confirm:

1. `event=g7_ble_scan_started` / `event=g7_ble_peripheral_discovered` for the `FEBC`-advertised `DXCM*` peripheral
2. `event=g7_ble_auth_notify_enabled`
3. `event=g7_ble_jpake_skipped mode=observer`
4. `event=g7_ble_auth_challenge_received opcode=0x03`
5. `event=g7_ble_status_reply authenticated=true bonded=true`
6. `event=g7_ble_control_notify_enabled`
7. `event=g7_ble_egv_request_sent opcode=0x4E`
8. `event=g7_ble_egv_received`
9. `event=g7_ble_snapshot_saved`

Negative proof is part of the instrumentation contract:

- **Observer mode must not emit** `event=g7_ble_auth_request_sent`
- **Observer mode must not emit** `0x01 0x00` auth-init
- **Observer mode must not emit** a J-PAKE ownership write / enable line
- **`event=g7_ble_auth_request_sent` in observer mode is a review blocker**
- The absence of those lines is part of the review checklist, not an incidental side effect

Explicit stall-classifier events are also part of the observer contract:

- **`event=g7_ble_attach_blocked reason=missing_active_sensor_filter`** when direct BLE attach is intentionally withheld because the phone-provided active sensor filter has not been armed yet. Emit this as a bounded state-classifier, not once per advertisement.
- **`event=g7_ble_status_gate_blocked authenticated=<bool> bonded=<bool>`** when a `0x05` reply is received but the observer gate is not satisfied, so progression to control is intentionally withheld.
- **`event=g7_ble_egv_request_blocked reason=status_gate_not_satisfied|control_not_ready`** when Trio intentionally withholds the `0x4E` request because prerequisites are not met. This should make a deliberate hold-back distinguishable from simply never reaching the code path.

## Debug UI alignment

The watch debug UI should reflect the same observer milestones used in logging so an operator can see, without opening Better Stack, where the direct BLE observer flow is currently stalled.

Required alignment:

- Show the current observer stage compactly: `Idle`, `Scanning`, `Connecting`, `Awaiting auth`, `Awaiting control`, `Awaiting EGV`, `Connected`, or `Error`.
- Surface the same core milestones as the logs: auth notify enabled, J-PAKE skipped, `0x03` seen, `0x05 authenticated=true bonded=true`, control notify enabled, `0x4E` received, snapshot saved.
- Surface the same key diagnostic state used in logs: current `g7_session`, last disconnect reason, timeout stage, reconnect scheduled, extended-runtime active, last peripheral name / RSSI / discover time, and whether the phone-provided active sensor identity filter is armed.
- Make it clear when the phone-provided active sensor identity is absent; in that state the watch direct BLE observer path should be shown as not ready to attach rather than connect to a random Dexcom peripheral.
- Indicate whether the watch is currently using **direct BLE observer** mode or **phone relay** instead.

The debug UI should stay lightweight:

- Use compact status fields only.
- Do not render raw packet hex dumps or giant scrolling logs on-screen.

---

## Keep vs adjust

| Keep | Adjust |
|------|--------|
| **`g7_session`** on **`g7_ble_*`** lines in a cycle | No full peripheral UUID on every line; session id is the primary correlation key. **Exception (bounded):** **`peripheral_id_short=<last8>`** (last 8 hex digits of **`CBPeripheral.identifier`**, no dashes) on **`g7_ble_peripheral_discovered`**, **`g7_ble_retrieve_on_powered_on`**, and **`g7_ble_pre_connect`** only — correlates scan vs retrieve without UUID spam. |
| Compact **`char=` / `write=`** labels | No payload dumps; bounded unknown-opcode logging |
| Manager-first | **Watch lifecycle** logs are **narrow** and **correlation-oriented** (Tier 1 lifecycle item) |

---

## Tier 1 — ship as one unit

1. **`g7_session=<id>`** — **all `g7_ble_*` lines in that scan/connect cycle should include `g7_session=<id>`** once the session exists for that cycle. **Do not** use vague “every line” wording — the requirement is explicitly **`g7_ble_*` + `g7_session`**. **Coupling with lifecycle (normative — pick one product-wide rule):** **`g7_session` is allocated at the start of `startScanning()`** before other `g7_ble_*` traffic for that foreground cycle (or **carried over** when **`applyForegroundActiveEntry`** skips a full restart while a session is still **`scanning`…`connected`**). The **`g7_ble_lifecycle`** line for **`phase=active`** is emitted **only after** **`g7_session` exists** (e.g. **immediately after** **`applyForegroundActiveEntry`** returns in **`handleForegroundActiveEntry()`**, using the manager’s session id). **That `phase=active` line includes `g7_session=<id>`.** Do **not** emit **`phase=active`** earlier in the foreground path **without** **`g7_session`** — **one** active lifecycle line per foreground entry, **always** with **`g7_session`** under this rule (avoids inconsistent “first line” behavior in Better Stack).

2. **`stage=` on transitions only** — emit when the **stage string actually changes**, not on every log call.

3. **Stage transition line** — e.g. `event=g7_ble_stage stage=<name>` (or equivalent under existing `g7_ble_*` naming).

4. **`g7_ble_connect_attempt`** (or align naming with existing connect logs — **one** clear connect-attempt line per session).

5. **Success-path milestones** (split for scanning):

   - **Discovery:** `g7_ble_services_discovered`; `g7_ble_characteristics_discovered`.
   - **Notify:** `g7_ble_notify_state` with compact `char=auth|control|backfill`, `notifying=true|false`, plus explicit observer-proof lines for `g7_ble_auth_notify_enabled`, `g7_ble_jpake_skipped`, and `g7_ble_control_notify_enabled`. In observer mode there should be no `char=jpake notifying=true`.
   - **Write:** `g7_ble_egv_request_sent opcode=0x4E` (or equivalent compact success pair with `g7_ble_write_ok write=egv_request`). **Do not** emit `auth_init` in observer mode.

6. **Observer blocked-state classifiers** — emit compact, explicit block reasons when Trio intentionally does not progress:

   - `g7_ble_attach_blocked reason=missing_active_sensor_filter`
   - `g7_ble_status_gate_blocked authenticated=<bool> bonded=<bool>`
   - `g7_ble_egv_request_blocked reason=status_gate_not_satisfied|control_not_ready`

   These lines are meant to eliminate ambiguous “nothing happened” debugging. Emit them on the state transition into the blocked condition, not continuously while the condition remains true.

7. **`ms_since_discover`** on **`didConnect`** (or equivalent connect milestone).

8. **`g7_ble_timeout stage=<awaited_stage>`** — include **`g7_session`**, plus **teardown** per **Timeout principles**. **Usually** this means an **expected CoreBluetooth (or session) callback did not arrive within the threshold** for that awaited phase.

9. **Timeout dedupe:** at **most one** `g7_ble_timeout` per **awaited stage** per **`g7_session`**.

10. **Watch lifecycle — Tier 1 (explicit)** — **must** be present for correlating **BLE stalls** vs **normal** watch **active / inactive / background** transitions; **not** optional “extra” logging. **`g7_session`** on lifecycle lines follows **item 1** above ( **`phase=active`** includes **`g7_session`** after allocation — see coupling rule there).

   - **Event shape (compact, Better Stack–friendly):** **`event=g7_ble_lifecycle`** with **`phase=active|inactive|background`** and **`reason=scenePhase_change|…`** ( **`stop_requested`** reserved for **explicit** **`stop()`** / future off-switch — **not** scene phase).
   - **Emit at least one line for each of:**
     - **App/scene became active** (e.g. foreground entry → **`applyForegroundActiveEntry`** path, which may or may not call **`startScanning()`**).
     - **App/scene resigned active / became inactive** — **`phase=inactive`** only (SwiftUI **`ScenePhase.inactive`**). Include **`ble_continues=true`** — scene phase **does not** stop BLE. **Do not** log **`phase=background`** on this transition.
     - **Entered background** — **`phase=background`** only when the scene phase is **actually `.background`** (e.g. a **separate** SwiftUI transition after inactive). Include **`ble_continues=true`**. Plain inactive (notification shade, etc.) **must not** emit a background line.
   - **Timing fields (where useful):**
     - **`active_window_s`** and **`active_window_ms`** — duration of the **foreground UI active segment** (wall time from segment start to leave-active), on **`phase=inactive`** with **`reason=scenePhase_change`** (same metric in seconds and milliseconds; **not** a BLE teardown marker).
   - **Placement / single source of truth:** Emit lifecycle lines from **`handleForegroundActiveEntry()`** and **`handleForegroundInactiveOrBackground(scenePhase:)`**. For **leave-active** (**`inactive`** / **`background`**), use **one** OS entry path into **`WatchState`**: **`TrioWatchApp`** **`.onChange(of: scenePhase)`** (pass **`ScenePhase.inactive`** or **`.background`**). **Do not** also call **`handleForegroundInactiveOrBackground`** from **`WKApplicationDelegate.applicationWillResignActive`** — duplicates callbacks into the same hook and breaks correlation. **`ExtensionDelegate`** may still emit other logs (e.g. **`watch_app_resigning_active`**); those are **not** **`g7_ble_lifecycle`**.

   **Scope (read carefully):** These lines correlate **UI active / inactive / background** with **`g7_session`** — **inactive/background no longer imply BLE teardown** (**`ble_continues=true`**). Use them to separate **normal scene churn** from **BLE stalls** and **timeout/teardown** lines. They are **not** for broad app, scene, or UI logging — **BLE/manager-focused** correlation only, **not** an app-wide lifecycle expansion.

11. **Phase E — Pre-connect diagnostics (build 162)** — three new events targeting the `didConnect` stall:

   - **`event=g7_ble_pre_connect`** — emitted **once, immediately before** `central?.connect(peripheral, options:)`. Fields:
     - `peripheral_state=<CBPeripheral.state.rawValue>` (expected: `0` = disconnected)
     - `central_state=<CBCentralManager.state.rawValue>` (expected: `5` = poweredOn)
     - `source=scan|retrieved` (whether the peripheral came from `didDiscover` or `retrieveConnectedPeripherals`)
     - `first_attempt=true|false` (first connect since last `startScanning()`)
     - `preserved_session=true|false` (whether the `g7_session` was carried over from a prior foreground entry)
     - `is_connectable=true|false|unknown` — from **`CBAdvertisementDataIsConnectable`** when the connect path used a scan advertisement; **`unknown`** when the peripheral was attached from **`retrieveConnectedPeripherals`** (no advertisement on that path)
     - `discover_count_for_target=<n>` — number of **`didDiscover`** callbacks for the active-name-matched peripheral in this session before this connect (churn / rediscovery signal; reset at **`startScanning()`**)
     - `peripheral_id_short=<last8>` — last 8 hex digits of **`CBPeripheral.identifier`** (no dashes)
     - `cbcentral_allocated_in_start_scanning=true|false` — **`true`** only when **this** **`startScanning()`** call allocated **`CBCentralManager`** (**`central` was `nil`**). **`false`** on connect attempts that did not go through a new **`startScanning()`** (e.g. preserved BLE session). Not “fresh for this connect” in isolation.
     - Include **`g7_session=`** per item 1.

   - **`event=g7_ble_peripheral_discovered`** (existing) — also carries **`peripheral_id_short=<last8>`** on the same connect path as **`g7_ble_pre_connect`** (and **`g7_ble_connect_attempt`**), for correlation.

   - **`event=g7_ble_retrieve_on_powered_on`** — emitted inside `centralManagerDidUpdateState(.poweredOn)` after calling `retrieveConnectedPeripherals(withServices: [G7 GATT data service UUID])` — **not** the **`FEBC`** advertisement UUID used for **`scanForPeripherals`**. Fields:
     - `count=<n>` (number of peripherals returned)
     - `first_name=<name|unknown>` (first peripheral name, for filter matching)
     - `first_state=<rawValue>` (connection state of the first peripheral)
     - `peripheral_id_short=<last8|none>` (first peripheral’s short id, or **`none`** if the list is empty)
     - Include **`g7_session=`** when available.

   - **`event=g7_ble_will_restore_state`** — emitted from `centralManager(_:willRestoreState:)` (only fires when `CBCentralManagerOptionRestoreIdentifierKey` is set and CoreBluetooth has state to restore). Fields:
     - `keys=<sorted comma-separated key names>` (what CoreBluetooth is restoring)
     - This event fires **before** `centralManagerDidUpdateState` on restore, so `g7_session` may not yet exist.

12. **Phase F / F1 — Connect-boundary closure** — additive watch-only timer / delegate lines that make every connect attempt reconstructable without renaming the existing higher-level outcome events:

   - **`event=g7_ble_connect_timeout_armed timeout_s=30`** — emitted exactly when the `awaiting_connect` timeout work item is scheduled.
   - **`event=g7_ble_connect_timeout_canceled reason=did_connect|did_fail_to_connect|teardown|startScanning_rescan|stop_requested`** — emitted only when a live connect timeout was actually canceled.
   - **`event=g7_ble_did_connect`** — emitted at the top of `centralManager(_:didConnect:)` before service discovery work.
   - **`event=g7_ble_did_fail_to_connect`** — emitted at the top of `centralManager(_:didFailToConnect:error:)` with the same normalized error fields already used by `g7_ble_connect_failed`.
   - **`event=g7_ble_did_disconnect`** — emitted at the top of `centralManager(_:didDisconnectPeripheral:error:)` before any early return, including the intentional `startScanning_rescan` path.
   - The expected watch-only connect trail is now:
     **`g7_ble_connect_attempt -> g7_ble_connect_timeout_armed -> g7_ble_did_connect|g7_ble_did_fail_to_connect|g7_ble_timeout stage=awaiting_connect`**
     with **`g7_ble_did_disconnect`** logged whenever the disconnect delegate fires.

---

## Tier 2

Structured **`domain=` / `code=` / `att_code=`** on relevant errors where cheap; **`g7_ble_reconnect_scheduled delay_s=7`** when the 7s reconnect path runs (if not already obvious from existing logs).

---

## Tier 3

Bounded unknown auth opcode / non-`0x4E` control: **opcode + length only**; **no payload dumps**; rate-limit repeated opcode lines.

---

## Stage instrumentation rules

- **Instrumentation describes behavior; it does not replace `connectionState` or CoreBluetooth callbacks.**
- **`stage`** is **strictly transition-only** and tied to **real milestones** in the manager.
- **Do not** build a parallel finite-state machine that can drift from code paths.

---

## Timeout principles

- **Definition:** A timeout **should usually correspond to** an **expected callback not arriving within the threshold** for that awaited phase (CoreBluetooth delegate or other session completion you are waiting on). It is **not** a generic “slow stage” timer on every label.
- **Attach timers only to genuinely awaited async boundaries** (matches **actual** waits in code — not a timer on every conceptual stage).
- **In practice, a timeout usually means the expected callback for that phase did not arrive within the threshold** (e.g. discovery completion, notify enable, first EGV after request — only where the code **actually** awaits).
- **One outstanding timeout per awaited phase** at a time; **reset** on forward progress; **cancel** on teardown or when **session-complete conditions** are met.
- **On fire:** log **`g7_ble_timeout`**, then **structured teardown** so the runtime is not left half-alive.
- **Dedupe:** **at most one timeout event per awaited stage per `g7_session`.**

**Session goal / timer cancel (concrete):**

- **Explicit end:** **`stop()`** / teardown / disconnect — cancel timers.
- **`awaiting_gatt_setup`:** Cancel when the observer path has completed its required readiness sequence — minimally **auth notify enabled**, `0x05 authenticated=true bonded=true`, and **control notifications on**. `backfill` is optional follow-up for this path and must not keep the startup timer alive.
- **Observer startup happy path (normative):** For direct BLE observer mode, startup readiness is satisfied by **auth notify enabled**, `0x05 authenticated=true bonded=true`, and **control notify enabled**. `backfill` readiness is **not** part of the startup-complete contract and must not delay `0x4E` eligibility or `awaiting_gatt_setup` cancellation.
- **Success goal for this feature:** **first successful EGV handled and persisted** (`g7_ble_snapshot_saved` path) — cancel **awaiting-EGV**-related timers when appropriate.
- Exact durations = **named constants** (tunable); this report states **principles**, not fixed second values.

**Protocol logging:** **bounded** — **opcode + length only** for unknown / non-EGV control inspection; **no** payload dumps.

---

## Approval checklist

1. **`g7_session`** on all **`g7_ble_*`** lines in-cycle + lifecycle lines per **item 1** / **item 10** (**`phase=active`** includes **`g7_session`** after allocation — **no** divergent first-line behavior).
2. **`stage=`** transition-only, milestone-backed.
3. **Discover → connect** timing (**`ms_since_discover`**).
4. **Timeouts** = missing **expected** callback within threshold + **teardown** + **per-stage-per-session** dedupe.
5. **`g7_ble_lifecycle`** — active / inactive / background / **`stop_requested`**, with **`active_window_s`** / **`active_window_ms`** (segment duration) where useful; **purpose = correlation**, not broad chatter.
6. **Observer proof:** auth notify enabled, explicit J-PAKE skip, `0x03`, `0x05 authenticated+bonded`, control notify enabled, `0x4E` request / receive / save, **absence** of `g7_ble_auth_request_sent`, and no `char=jpake notifying=true`.
7. **Review blocker rule:** `event=g7_ble_auth_request_sent` in observer mode is a blocker, not just an undesirable signal.
8. **Active sensor gate:** direct BLE observer only attempts attach when the phone-provided active sensor identity / name filter is armed and matches the discovered peripheral.
9. **Blocked-state visibility:** Missing-filter, failed-`0x05`, and withheld-`0x4E` cases emit explicit blocked-state events rather than being inferred only from absent later milestones.
10. Structured error codes where cheap.
11. **Opcode + length** only for unknowns; **no** dumps.
12. **Phase E pre-connect diagnostics (build 162):** `g7_ble_pre_connect` with `peripheral_state` / `central_state` / `source` / `first_attempt` / `preserved_session` / `is_connectable` / `discover_count_for_target` / `peripheral_id_short` / `cbcentral_allocated_in_start_scanning` on every connect attempt; `g7_ble_retrieve_on_powered_on` (with `peripheral_id_short`) on every fresh `.poweredOn`; `g7_ble_will_restore_state` when state restoration fires; bounded **`peripheral_id_short`** on **`g7_ble_peripheral_discovered`** / **`g7_ble_connect_attempt`** on the connect path. Retrieval uses the **connected GATT data service** UUID (see Tier 1 item 11).
13. **Phase F / F1 connect-boundary closure:** every watch-side **`g7_ble_connect_attempt`** has one **`g7_ble_connect_timeout_armed`**; every armed timeout ends with exactly one of **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, or **`g7_ble_timeout stage=awaiting_connect`**; any disconnect emits **`g7_ble_did_disconnect`**, including intentional rescan paths.

---

## Explicit rejections

Payload hex dumps; full peripheral UUID spam; timers on every conceptual “stage” without a real async wait; **timeout lines without** cleanup; **app-wide** lifecycle logging beyond this BLE path; **observer-mode `0x01 0x00` auth-init / app-key / J-PAKE ownership writes**.

---

## Bottom line

Tier 1 adds **session id**, **stage transition discipline**, **discovery / notify / write milestones**, **timing**, **timeouts + teardown**, **lifecycle correlation**, and **dedupe** — while keeping **`stage`** as **description**, not a shadow state machine, and **timeouts** attached only to **real** async boundaries.

---

## Changelog

### v1.35 (2026-04-18 10:05 CEST)
- **F5 and build-168 live evidence recorded:** Updated the header status and Phase F narrative to reflect that the expanded F5 instrumentation is implemented, deployed, and visible in Better Stack on **build 168**.
- **Build-168 interpretation tightened:** Added the current de-duplicated live result: all observed build-168 connect attempts remain **`source=scan`**, both retrieval UUIDs currently return **zero** candidates, and there are still **no** post-connect watch milestones in current volume.
- **Post-F5 sequencing updated:** The report now keeps **F6/F7** explicitly conditional on a future real **`didConnect`** in build **168** or later, while **F9** is framed as the source-split analysis lane for interpreting ongoing scan-vs-retrieval results.

### v1.34 (2026-04-16 17:16 BST)
- **Post-F4 sequence added:** The active instrumentation plan now records **F5** as the next build, keeps **F9** as analysis context, and makes **F6/F7** conditional on what **F5** closes at the post-connect boundary. **F8** is now framed as an audit / attribution task unless **F5** exposes a real readiness bug.
- **Snapshot table corrected to match current code:** Updated the active “current behavior” rows so they no longer describe the old auth-init, missing J-PAKE skip, or backfill-coupled GATT-ready behavior. The table now reflects the shipped observer-only startup-ready rule and the current strict active-sensor gate.
- **PacketLogger deferral carried into the post-F4 cycle:** The active sequencing language now keeps PacketLogger / raw capture explicitly deferred while watch-only logs are still yielding new boundary movement.

### v1.33 (2026-04-16 16:11 BST)
- **Build 166 / F4 runtime result recorded without adding telemetry:** Header / status and the new **Phase F / F4** note now record build **166** as a live deployment with the first watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`** and one moved timeout boundary at **`awaiting_gatt_setup`** / **`final_stage=discovering_services`**, while explicitly keeping the downstream service / EGV / snapshot milestones at zero.
- **Build 165 baseline finalized:** The old “preliminary negative so far” wording is replaced with the completed build-165 watch-only review: **9** observed connect attempts, all still timing out at **`awaiting_connect`**.
- **Build 166 search method documented:** Added the exact watch-only Better Stack search set used to understand the outcome: grouped event counts by build, grouped final stages, grouped timeout stages, grouped connect sources, and the full timeline for the sole **`didConnect`** session.

### v1.32 (2026-04-15 19:26 BST)
- **Build 165 preliminary runtime result recorded without adding new telemetry:** Header / status and the Phase F / F3 note now record the current watch-only Better Stack read for build **165**: **2** observed connect attempts and the same callback-free **`awaiting_connect`** timeout pattern, with no watch-side connect / fail / disconnect or EGV / snapshot milestone.
- **F4 promoted to the active next build:** The report now advances from “F4 reserved if F3 is negative” to the current state: **F4** is the next code experiment after the preliminary negative **F3** read.
- **PacketLogger remains deferred after the F3 review:** Kept PacketLogger / raw capture framed as a deferred parallel diagnostic track rather than an immediate gate ahead of **F4**.

### v1.31 (2026-04-15 18:58 BST)
- **F3 build recorded without inventing new telemetry:** Header / status and the Phase F summary now record **build 165** as the active **F3** deployment, noting that the duplicate-suppression scan option was removed while the **FEBC** filter and all existing event names stayed unchanged.
- **F4 added as the documented fallback:** The report now states explicitly that **F4** is the next code experiment only if **F3** is negative.
- **PacketLogger reframed as deferred diagnostics:** Replaced the old “gates F3” wording with the current plan: **PacketLogger / raw capture** is a deferred parallel track to revisit only after **F3** and **F4** are both negative or if later evidence makes it necessary.

### v1.30 (2026-04-15 16:18 BST)
- **Build 164 watch-only analysis recorded:** Header / status and the Phase F / F2 note now record that the expanded Better Stack re-check found **7** distinct watch-side connect attempts in **build 164**, with no watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, or **`g7_ble_connect_timeout_canceled`** events before timeout.
- **F2 conclusion made explicit:** The Phase F / F2 note now states that **`queue: nil`** did **not** materially change the watch-side callback-free stall; the remaining gate before **F3** is the PacketLogger / raw-capture review, not more log reconstruction.
- **Implementation-plan reference updated:** The execution pointer now references **implementation plan v1.42**.

### v1.29 (2026-04-14 22:50 CEST)
- **Phase F builds recorded:** Header / status now reflect the completed sequence through **build 164**: **Phase E** build **162**, **Phase F / F1** build **163**, and **Phase F / F2** build **164**, with **F3** still pending watch-only review.
- **No new event names for F2:** Added a Phase F / F2 parity note clarifying that the **`queue: nil`** build intentionally reuses the **F1** connect-boundary event vocabulary so build **164** can be compared directly against build **163**.
- **Implementation-plan reference updated:** The Phase F execution pointers now reference **implementation plan v1.41**.

### v1.28 (2026-04-14 21:22 CEST)
- **Phase F / F1 connect-boundary observability:** Added Tier 1 item 12 for the new additive connect-boundary events — `g7_ble_connect_timeout_armed`, `g7_ble_connect_timeout_canceled`, `g7_ble_did_connect`, `g7_ble_did_fail_to_connect`, and `g7_ble_did_disconnect` — and defined the expected watch-only trail from `g7_ble_connect_attempt` through connect success / failure / timeout.
- **Approval checklist tightened:** New checklist item requires closed-trail connect accounting on the watch path, including intentional rescan disconnects.
- **Header/status:** Bumped the controlled version to **v1.28** and aligned the status line with implementation plan **v1.40**.

### v1.27 (2026-04-14 17:08 CEST)
- **Watch UI vs WC monotonic (implementation plan v1.39):** Main watch **`isWatchStateDated`** uses **`effectiveWatchUiFreshnessAt`** (`max` of phone **`lastWatchStateUpdate`** and direct-BLE / complication hydration wall time). No change to **`g7_ble_*`** log lines; cross-reference **implementation plan** **External review — feedback recorded** (Codex P1).

### v1.26 (2026-04-14 16:47 CEST)
- **Phase E field rename + retrieval UUID:** **`manager_fresh`** → **`cbcentral_allocated_in_start_scanning`** (only meaningful when **`startScanning()`** ran — avoids misread on preserved-session connects). **`retrieveConnectedPeripherals`** documented/implemented with **GATT data service** UUID, not **`FEBC`**. **Implementation plan** **v1.38**.

### v1.25 (2026-04-14 16:28 CEST)
- **Phase E connect-context fields:** Tier 1 item 11 — **`g7_ble_pre_connect`** extended with **`is_connectable`**, **`discover_count_for_target`**, **`peripheral_id_short`**, **`manager_fresh`**; **`g7_ble_retrieve_on_powered_on`** with **`peripheral_id_short`**; **`g7_ble_peripheral_discovered`** / **`g7_ble_connect_attempt`** with **`peripheral_id_short`**. **Keep vs adjust** table documents the bounded exception to “no full UUID” spam. Approval checklist item 12 updated. **Implementation plan** **v1.37**.

### v1.24 (2026-04-14 16:09 CEST)
- **Phase E implemented:** Snapshot rows for pre-connect / retrieve-on-powered-on / state restoration marked **Met**; “planned” Phase E line in **Events** updated to **implemented** with pointer to **implementation plan** execution log.

### v1.23 (2026-04-14 15:42 CEST)
- **Phase E pre-connect diagnostics (build 162):** Added three new events to Tier 1 item 11: `g7_ble_pre_connect` (peripheral/central state, source, first-attempt, preserved-session immediately before `connect()`), `g7_ble_retrieve_on_powered_on` (retrieval inside `.poweredOn` handler to match DiaBLE timing), `g7_ble_will_restore_state` (from `centralManager(_:willRestoreState:)` after adding `CBCentralManagerOptionRestoreIdentifierKey`). Snapshot table updated with three Phase E gap rows. Events-already-emitted section updated with planned build 162 events. Approval checklist item 12 added.

### v1.22 (2026-04-13 23:05 CEST)
- **Blocked-state events made explicit:** Added normative observer-mode events for missing active-sensor filter (`g7_ble_attach_blocked`), failed `0x05` gate (`g7_ble_status_gate_blocked`), and intentionally withheld `0x4E` requests (`g7_ble_egv_request_blocked`).
- **Observer startup-ready rule sharpened:** Added a standalone normative sentence that direct-BLE startup readiness is `auth notify enabled + 0x05 authenticated=true bonded=true + control notify enabled`, with `backfill` explicitly excluded from the startup-complete contract.
- **Approval checklist tightened:** Review now requires blocked-state visibility, not just success-path milestones and negative proof.

### v1.21 (2026-04-13 22:21 CEST)
- **Active sensor gate added:** Added an explicit snapshot gap and approval rule stating that watch direct BLE observer must only attempt attach when the phone-provided active sensor identity / name filter is armed and matched.
- **Auth-init made a review blocker:** The report now states bluntly that `event=g7_ble_auth_request_sent` in observer mode is a review blocker.
- **Debug UI alignment tightened:** The debug UI requirements now explicitly say the existing watch debug state should show whether the phone-provided filter is missing and should remain non-ready rather than attach to a random Dexcom peripheral.

### v1.20 (2026-04-13 22:10 CEST)
- **Debug UI alignment added:** Added a **Debug UI alignment** section requiring the watch debug UI to mirror the same observer milestones and diagnostic fields used in logging.
- **Operational UI guardrails added:** Documented that the on-watch debug view should remain compact, show direct BLE observer vs phone relay status, and avoid raw packet hex dumps or giant logs.

### v1.19 (2026-04-13 22:04 CEST)
- **Mode boundary clarified:** Added explicit scope wording that this report governs the **watch direct BLE observer** path only; the separate **phone-relay / WatchConnectivity** watch mode remains outside this contract except for active-name filter arming.
- **Observer negative proof tightened:** Review now explicitly forbids **`0x01 0x00` auth-init** in observer mode and requires that **J-PAKE never reaches `notifying=true`**.
- **J-PAKE wording sharpened:** The snapshot and Tier 1 notify guidance now say `J-PAKE` is discovered only for **skip/logging**, not for subscription/enablement.

### v1.18 (2026-04-13 21:46 CEST)
- **DiaBLE observer proof set added:** Promoted `watch-direct-ble-cgm-04-diaBLE-logs.md` to the primary watch observer proof source and added an explicit ordered proof sequence: auth notify enabled, J-PAKE skipped, `0x03`, `0x05 authenticated+bonded`, control notify enabled, `0x4E` request / receive / save.
- **Current observer gaps called out in the snapshot:** Added explicit rows for Trio’s remaining watch-path divergence: auth-init still sent, no J-PAKE skip log, bonded bit not enforced, and `backfill` still over-coupled to startup readiness.
- **Approval / rejection rules updated:** Review now requires **absence** of `g7_ble_auth_request_sent` in observer mode and explicitly rejects observer-mode auth-init / app-key / J-PAKE ownership writes.

### v1.17 (2026-04-13 00:03 CET)
- **`didInvalidateWith` vs teardown:** Snapshot **Extended session — foreground re-entry renewal** row — identity **pre-capture** before nil-ing **`extendedSession`** so **`error != nil`** path reaches **`teardownSession`** (ChatGPT / Claude). **Design** **v1.15**; **Implementation plan** **v1.25**.
- **Reason:** Operator-visible **`g7_ble_ext_session_invalidated`** must correlate with actual BLE teardown when the OS invalidates the **current** extended session with an error.

### v1.16 (2026-04-12 23:55 CET)
- **Extended session — foreground re-entry renewal:** Snapshot table row + **Events already emitted** — **`g7_ble_ext_session_renewal`**, **`g7_ble_ext_session_renewal_skipped`**; cross-link **design** § **Connection state model** for **`G7BLEConnectionState`** vs **G7SensorKit** / DiaBLE. **Design** **v1.14**; **Implementation plan** **v1.24**.
- **Reason:** Operators need grep targets for re-anchored **`WKExtendedRuntimeSession`**; connection-state note prevents misinterpreting renewal guards as “per-packet” states.

### v1.15 (2026-04-12 23:40 CET)
- **Lifecycle (Tier 1) — scene phase does not stop BLE:** Snapshot table **Lifecycle** / **WatchState** / **Tier 1 follow-on** / **Phone → watch** rows; **Events already emitted** — add **`g7_ble_foreground_reentry_skipped`**, drop scene-phase **`g7_ble_stop_deferred`**; **Tier 1 item 1** coupling (**`applyForegroundActiveEntry`** may skip **`startScanning()`**); **Tier 1 item 10** — **`ble_continues=true`**, combined **`active_window_*`** on inactive, **no** lifecycle-**`stop_requested`**, placement text without **`stop()`** on **`handleForegroundInactiveOrBackground`**. **Design** **v1.13**; **Implementation plan** **v1.23**.
- **Reason:** Product decision — CGM stream continues until extended runtime ends, not when the user leaves the app UI.

### v1.14 (2026-04-12 22:58 CET)
- **Initiative / `docs/code-review/` decoupling:** Removed **Code review** pointer from **v1.12** changelog entry (transient diff scratch docs are **not** initiative traceability). **Design** **v1.10**; **Implementation plan** **v1.20**.

### v1.13 (2026-04-12 22:57 CET)
- **Phone → watch G7 name:** Snapshot table row + **`g7_ble_active_name_applied`** in **Events already emitted**; **Code** header lists iPhone **`AppleWatchManager`** / **`WatchMessageKeys`**. **Design** **v1.9**; **Implementation plan** **v1.19** (**Record — iPhone → watch active G7 peripheral name**).
- **Reason:** Instrumentation spec should mention the **watch** log line used to confirm the active-name filter is armed without logging raw peripheral names.

### v1.12 (2026-04-12 21:53 CET)
- **Tier 1 follow-on (implementation):** Snapshot table row + expanded **Events already emitted** list — **`g7_ble_connect_failed`**, **`rssi=`**, **`g7_ble_peripheral_skipped`**, extended-runtime + **`g7_ble_stop_deferred`**, **`g7_ble_session_outcome`**. **Design** **v1.8**; **Implementation plan** **v1.18** (**Record — Tier 1 follow-on**); **Code review** **v1.4**.

### v1.11 (2026-04-12 14:00 CET)
- **Versioning note:** Removed stale “**v1.8** is the current controlled edition” — the header **Version** is authoritative.
- **Single driver for leave-active:** Normative text + snapshot — **`TrioWatchApp`** SwiftUI **`ScenePhase`** only for **`handleForegroundInactiveOrBackground`**; **do not** duplicate via **`applicationWillResignActive`** (see **Placement / single source of truth** in Tier 1 **item 10**).
- **Lifecycle bullet:** Dropped **`applicationWillResignActive`** as an alternate source for **`phase=inactive`**.

### v1.10 (2026-04-12 13:45 CET)
- **Snapshot table:** **Current behavior** column rewritten for **post–Task C3 Tier 1** implementation (session, stages, milestones, timeouts, lifecycle, Tier 2/3 lines). **Gap** column = spec stretch or remaining deltas.
- **Lifecycle:** Normative clarification — **`phase=background`** only when scene is **`.background`**; **`active_window_ms`** on **`stop_requested`** replaces misleading **`ms_since_last_active`** label for segment-duration; **`awaiting_gatt_setup`** cancel when **control + backfill** notify are on.
- **Stage:** **`discovering_characteristics`** timing documented (emit before `discoverCharacteristics`).
- **Checklist / Tier 1 timing bullets:** Aligned with field names above.

### v1.9 (2026-04-12 13:36 CET)
- **Log line attribution:** New section **Log line attribution (`WatchLogger`)** — documents **`logG7Ble` → `WatchLogger`** forwarding of **`#fileID` / `#line` / `#function`** and operator expectations for **`Task`**-wrapped vs direct **`await`** paths. Reason: align Tier 1 **`g7_ble_*`** event content with **accurate** file/line/method in Better Stack; no change to event vocabulary or session rules.

### v1.8 (2026-04-12 13:06 CET)
- **Cross-links:** Snapshot no longer cites a sibling **implementation plan** version number; link to **[watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md)** only — **Version** field there is authoritative.

### v1.7 (2026-04-12 13:02 CET)
- **Lifecycle / `g7_session`:** **Normative rule** — allocate **`g7_session`** at **`startScanning()`**; emit **`g7_ble_lifecycle`** **`phase=active`** only **after** the id exists (e.g. after **`startScanning()`** returns), **with** **`g7_session`**; **one** active line per entry — **no** early **`phase=active`** without session.
- **Hooks:** Lifecycle logging **must** use the **same** **`WatchState`** hooks as **`startScanning()`** / **`stop()`** (**`handleForegroundActiveEntry()`** / **`handleForegroundInactiveOrBackground()`**); **no** duplicate lifecycle sources.

### v1.6 (2026-04-12 12:57 CET)
- **Tier 1 lifecycle (explicit pass):** Expanded **Watch lifecycle** as a required Tier 1 item — **`event=g7_ble_lifecycle`**, **`phase=active|inactive|background`**, **`reason=scenePhase_change|stop_requested|…`**; explicit coverage list (active, inactive, background, **`stop()`** from teardown); **`g7_session`** on lifecycle lines when a session exists; timing **`active_window_s`**, **`ms_since_last_active`** toward **`stop_requested`**.
- **Scope:** Stated **BLE/manager correlation only** — not broad app/scene/UI chatter; answers stall vs normal lifecycle.
- **Wording:** Reaffirmed **all `g7_ble_*` lines** in-cycle include **`g7_session=<id>`** (including lifecycle); **Timeout principles** lead bullet — timeout = **expected callback not arriving within threshold**; **stage** transition-only + real milestones; timeout dedupe **unchanged**; **Tier 3** opcode + length, **no** payload dumps **unchanged**.

### v1.5 (2026-04-12 12:52 CET)
- **Controlled version:** Declared **v1.5** as the current document version (replacing the interim **v1.0** label on first publication).
- **Changelog:** Five revision entries (**v1.1–v1.5**) record the feedback-driven edits below in order.
- **Cross-reference:** Snapshot table points to **implementation plan v1.7** and **Task C3**.

### v1.4 (2026-04-12 12:52 CET)
- **Initiative file:** Published as **`watch-direct-ble-cgm-03-instrumentation-report.md`** under `docs/in-progress/watch-direct-ble-cgm/`.
- **Snapshot table:** Maps current **`G7DirectBLEManager`** / **`WatchState`** behavior to Tier 1–3 targets; documents **`@ObservationIgnored private let`** for the manager (not `lazy`).
- **Cross-links:** Design **v1.1**, implementation plan, **Task C3**.

### v1.3 (2026-04-12 12:52 CET)
- **Watch lifecycle (Tier 1):** **`event=g7_ble_lifecycle`** with **`phase=active|inactive|background`**, **`reason=scenePhase_change|stop_requested|…`** (compact, Better Stack–friendly).
- **Events to cover:** App/scene became active; resigned active / inactive; entered background; **`stop()`** from lifecycle teardown (e.g. **`handleForegroundInactiveOrBackground()`** → **`g7DirectBLEManager.stop()`**).
- **Timing:** **`active_window_s`** (or ms) where useful; **`ms_since_last_active`** (or similar) on **`stop_requested`**.
- **Intent:** Correlate **BLE stalls** with **normal** lifecycle transitions — **not** broad app/UI logging; tie **`g7_session`** when a G7 cycle is active.

### v1.2 (2026-04-12 12:52 CET)
- **`g7_session` wording:** All **`g7_ble_*` lines** in that scan/connect cycle should include **`g7_session=<id>`** (replacing looser “every line” wording).
- **Timeout semantics:** Stated that a timeout **usually** corresponds to an **expected callback not arriving within the threshold** for that awaited phase.
- **Reaffirmed:** **`stage=`** transition-only; **at most one** `g7_ble_timeout` per awaited stage per **`g7_session`**; Tier 3 **opcode + length** only, **no** payload dumps.

### v1.1 (2026-04-12 12:52 CET)
- **Tier 1:** **`stage=`** and **timeouts** called out explicitly; **`stage=` only on transitions** (not a shadow state machine).
- **Guardrail:** **Instrumentation describes behavior; it does not replace `connectionState` or CoreBluetooth callbacks.**
- **Timeouts:** Pair **`g7_ble_timeout`** with **structured teardown**; timers only on **genuinely awaited async boundaries**.
- **Session goal:** **First successful EGV persisted** or **explicit stop/teardown** cancels timers (concrete vs vague “session goal”).
- **Milestones:** Split into **discovery** / **notify** / **write** buckets for scanning.
- **Dedupe:** **At most one** timeout per **awaited stage** per **`g7_session`**.
- **Heading:** **Stage instrumentation rules**; tighter **approval checklist**.
