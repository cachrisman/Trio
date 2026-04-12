# Instrumentation report: Watch — Dexcom G7 direct BLE eavesdrop

**Version:** v1.17  
**Status:** Adopted (normative for Tier 1–3 instrumentation work; implementation may trail this spec)  
**Created:** 2026-04-12 12:52 CET  
**Last updated:** 2026-04-13 00:03 CET  

**Design:** [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md)  
**Implementation plan:** [watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md)  
**Code (Trio worktree):** `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/WatchState.swift`; iPhone: `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, `Trio/Sources/Models/WatchMessageKeys.swift` ( **`active_g7_peripheral_name`** field )

**Note on versioning:** The **Version** field in this document’s header is the **controlled edition**; revisions **v1.1+** are **feedback-driven** updates documented in the [Changelog](#changelog). Informal drafts of this spec existed before the initiative file.

---

## Purpose

This report defines **Better Stack / `WatchLogger`-friendly** instrumentation for the **G7 direct BLE** path so operators can **reconstruct stalls**, **attribute timeouts**, and **separate BLE issues from normal watch lifecycle** transitions — **without** turning the watch extension into a general-purpose app logger.

**Scope boundary:** **BLE manager + narrow lifecycle correlation** only. Not an app-wide logging expansion.

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
| **Notify readiness** | `g7_ble_notify_state char=auth\|control\|backfill notifying=true` | **Met** |
| **Write OK** | `g7_ble_write_ok write=auth_init\|egv_request` | **Met** |
| **Timing** | `ms_since_discover` on `g7_ble_connected` | **Met** |
| **Timeouts** | `awaiting_connect` / `awaiting_gatt_setup` / `awaiting_first_egv`; `g7_ble_timeout` + teardown + dedupe; **GATT setup** timer clears when **control** and **backfill** notify are both enabled (not only auth) | **Principles** in [Timeout principles](#timeout-principles); tune durations in code constants |
| **Lifecycle correlation** | `g7_ble_lifecycle`: `phase=active` after **`applyForegroundActiveEntry`** ( **`g7_session`** when allocated or carried over ); **`phase=inactive`** + **`reason=scenePhase_change`** + **`ble_continues=true`** + **`active_window_s`** + **`active_window_ms`** — **no** implicit BLE stop; **`phase=background`** only when **scene** is **`.background`**, with **`ble_continues=true`**; **`reason=stop_requested`** is **not** emitted from scene phase (reserve for explicit **`stop()`** / future product off-switch) | **Met** — do **not** emit `phase=background` on inactive-only transitions |
| **Reconnect** | `g7_ble_reconnect_scheduled delay_s=7` | **Met** (Tier 2 line) |
| **Non-`0x4E` control** | `g7_ble_control_opcode` rate-limited | **Met** (Tier 3) |
| **WatchState manager** | `@ObservationIgnored private let g7DirectBLEManager`; `handleForegroundInactiveOrBackground(scenePhase:)` — **leave-active** invoked from **`TrioWatchApp`** SwiftUI **`ScenePhase`** only (not **`ExtensionDelegate`**); **does not** call **`stop()`** | Unchanged storage; **`ScenePhase.inactive`** / **`.background`** from **one** UI entry point |
| **Tier 1 follow-on (post–`b4dd0d7dd`)** | **`g7_ble_connect_failed`** (`error_domain` / `error_code` / `error_desc`); **`rssi=`** on **`g7_ble_peripheral_discovered`**; **`g7_ble_peripheral_skipped`** (`reason=not_active_sensor`) when **`activePeripheralName`** filters; **`WKExtendedRuntimeSession`** lifecycle lines; **`g7_ble_session_outcome`**; historical **`g7_ble_stop_deferred`** in older builds only | **Met** where implemented — see **Implementation plan** **Record — Tier 1 follow-on** |
| **Phone → watch G7 name (WC)** | **`event=g7_ble_active_name_applied filtered=true`** when **`applyForegroundActiveEntry`** applies a non-nil phone-supplied name (does **not** log raw peripheral name). **`g7_ble_foreground_reentry_skipped`** when a full **`startScanning()`** restart was skipped. **iPhone** sends **`active_g7_peripheral_name`** in nested **`watchState`** (see **Implementation plan** **Record — iPhone → watch active G7 peripheral name**) | **Met** — correlates filter use without **PHI** in logs |
| **Extended session — foreground re-entry renewal** | When UI was away **(0, 3600)s**, **`renewExtendedRuntimeSessionAfterForegroundReentry`** may run: **`g7_ble_ext_session_ended reason=foreground_reentry_renewal`**, then **`g7_ble_ext_session_renewal reason=foreground_reentry away_s=<n>`**, **`g7_ble_ext_session_started`**. If away ≥ 3600s: **`g7_ble_ext_session_renewal_skipped reason=away_not_under_1h away_s=<n>`**. **`didInvalidateWith`** / **`willExpire`** use session **identity** — **`didInvalidateWith`** captures **current** session **before** clearing the pointer so **`g7_ble_ext_session_invalidated`** + **`error != nil`** still allows **`ext_session_invalidated`** teardown — see **design** § **Connection state model** | **Met** — see **design** **v1.15**, **Implementation plan** **v1.25** |

**Events already emitted (manager + watch state, non-exhaustive):** `g7_ble_scan_started`, `g7_ble_error` (variants), `g7_ble_connect_failed` ( **`didFailToConnect` only** — not `g7_ble_error`), `g7_ble_peripheral_discovered` (incl. **`rssi=`**), `g7_ble_peripheral_skipped`, `g7_ble_connected`, `g7_ble_auth_request_sent`, `g7_ble_auth_challenge_received`, `g7_ble_authenticated`, `g7_ble_egv_received`, `g7_ble_snapshot_saved`, `g7_ble_disconnected`, `g7_ble_session_outcome`, `g7_ble_ext_session_started`, `g7_ble_ext_session_expiring`, `g7_ble_ext_session_ended`, `g7_ble_ext_session_invalidated`, **`g7_ble_ext_session_renewal`**, **`g7_ble_ext_session_renewal_skipped`**, `g7_ble_foreground_reentry_skipped`, `g7_ble_write_error_nonfatal`, **`g7_ble_active_name_applied`** (**`applyForegroundActiveEntry`** — **`filtered=true`** when a non-nil iPhone-supplied name is applied). Historical builds may still show **`g7_ble_stop_deferred`**.

---

## Diagnosis

The gap is **not** “no logs,” but **missing reconstructable stage transitions**, **explicit stalls**, **cleanup tied to timeouts**, and **enough context to separate BLE stalls from normal watch lifecycle** (active / inactive / background / teardown). This document is written so an implementer can follow it **without** defaulting to “log more everywhere.”

---

## Keep vs adjust

| Keep | Adjust |
|------|--------|
| **`g7_session`** on **`g7_ble_*`** lines in a cycle | No full peripheral UUID on every line; session id is the primary correlation key |
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
   - **Notify:** `g7_ble_notify_state` with compact `char=auth|control|backfill`, `notifying=true|false`.
   - **Write:** `g7_ble_write_ok` with compact `write=auth_init|egv_request` (no raw bytes).

6. **`ms_since_discover`** on **`didConnect`** (or equivalent connect milestone).

7. **`g7_ble_timeout stage=<awaited_stage>`** — include **`g7_session`**, plus **teardown** per **Timeout principles**. **Usually** this means an **expected CoreBluetooth (or session) callback did not arrive within the threshold** for that awaited phase.

8. **Timeout dedupe:** at **most one** `g7_ble_timeout` per **awaited stage** per **`g7_session`**.

9. **Watch lifecycle — Tier 1 (explicit)** — **must** be present for correlating **BLE stalls** vs **normal** watch **active / inactive / background** transitions; **not** optional “extra” logging. **`g7_session`** on lifecycle lines follows **item 1** above ( **`phase=active`** includes **`g7_session`** after allocation — see coupling rule there).

   - **Event shape (compact, Better Stack–friendly):** **`event=g7_ble_lifecycle`** with **`phase=active|inactive|background`** and **`reason=scenePhase_change|…`** ( **`stop_requested`** reserved for **explicit** **`stop()`** / future off-switch — **not** scene phase).
   - **Emit at least one line for each of:**
     - **App/scene became active** (e.g. foreground entry → **`applyForegroundActiveEntry`** path, which may or may not call **`startScanning()`**).
     - **App/scene resigned active / became inactive** — **`phase=inactive`** only (SwiftUI **`ScenePhase.inactive`**). Include **`ble_continues=true`** — scene phase **does not** stop BLE. **Do not** log **`phase=background`** on this transition.
     - **Entered background** — **`phase=background`** only when the scene phase is **actually `.background`** (e.g. a **separate** SwiftUI transition after inactive). Include **`ble_continues=true`**. Plain inactive (notification shade, etc.) **must not** emit a background line.
   - **Timing fields (where useful):**
     - **`active_window_s`** and **`active_window_ms`** — duration of the **foreground UI active segment** (wall time from segment start to leave-active), on **`phase=inactive`** with **`reason=scenePhase_change`** (same metric in seconds and milliseconds; **not** a BLE teardown marker).
   - **Placement / single source of truth:** Emit lifecycle lines from **`handleForegroundActiveEntry()`** and **`handleForegroundInactiveOrBackground(scenePhase:)`**. For **leave-active** (**`inactive`** / **`background`**), use **one** OS entry path into **`WatchState`**: **`TrioWatchApp`** **`.onChange(of: scenePhase)`** (pass **`ScenePhase.inactive`** or **`.background`**). **Do not** also call **`handleForegroundInactiveOrBackground`** from **`WKApplicationDelegate.applicationWillResignActive`** — duplicates callbacks into the same hook and breaks correlation. **`ExtensionDelegate`** may still emit other logs (e.g. **`watch_app_resigning_active`**); those are **not** **`g7_ble_lifecycle`**.

   **Scope (read carefully):** These lines correlate **UI active / inactive / background** with **`g7_session`** — **inactive/background no longer imply BLE teardown** (**`ble_continues=true`**). Use them to separate **normal scene churn** from **BLE stalls** and **timeout/teardown** lines. They are **not** for broad app, scene, or UI logging — **BLE/manager-focused** correlation only, **not** an app-wide lifecycle expansion.

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
- **`awaiting_gatt_setup`:** Cancel when **notify enablement** for the **data-path** channels is complete — minimally when **control** and **backfill** notifications are both **on** (not when **authentication** notify alone turns on; auth is necessary but not sufficient for “GATT setup done” for this path).
- **Success goal for this feature:** **first successful EGV handled and persisted** (`g7_ble_snapshot_saved` path) — cancel **awaiting-EGV**-related timers when appropriate.
- Exact durations = **named constants** (tunable); this report states **principles**, not fixed second values.

**Protocol logging:** **bounded** — **opcode + length only** for unknown / non-EGV control inspection; **no** payload dumps.

---

## Approval checklist

1. **`g7_session`** on all **`g7_ble_*`** lines in-cycle + lifecycle lines per **item 1** / **item 9** (**`phase=active`** includes **`g7_session`** after allocation — **no** divergent first-line behavior).
2. **`stage=`** transition-only, milestone-backed.
3. **Discover → connect** timing (**`ms_since_discover`**).
4. **Timeouts** = missing **expected** callback within threshold + **teardown** + **per-stage-per-session** dedupe.
5. **`g7_ble_lifecycle`** — active / inactive / background / **`stop_requested`**, with **`active_window_s`** / **`active_window_ms`** (segment duration) where useful; **purpose = correlation**, not broad chatter.
6. Structured error codes where cheap.
7. **Opcode + length** only for unknowns; **no** dumps.

---

## Explicit rejections

Payload hex dumps; full peripheral UUID spam; timers on every conceptual “stage” without a real async wait; **timeout lines without** cleanup; **app-wide** lifecycle logging beyond this BLE path.

---

## Bottom line

Tier 1 adds **session id**, **stage transition discipline**, **discovery / notify / write milestones**, **timing**, **timeouts + teardown**, **lifecycle correlation**, and **dedupe** — while keeping **`stage`** as **description**, not a shadow state machine, and **timeouts** attached only to **real** async boundaries.

---

## Changelog

### v1.17 (2026-04-13 00:03 CET)
- **`didInvalidateWith` vs teardown:** Snapshot **Extended session — foreground re-entry renewal** row — identity **pre-capture** before nil-ing **`extendedSession`** so **`error != nil`** path reaches **`teardownSession`** (ChatGPT / Claude). **Design** **v1.15**; **Implementation plan** **v1.25**.
- **Reason:** Operator-visible **`g7_ble_ext_session_invalidated`** must correlate with actual BLE teardown when the OS invalidates the **current** extended session with an error.

### v1.16 (2026-04-12 23:55 CET)
- **Extended session — foreground re-entry renewal:** Snapshot table row + **Events already emitted** — **`g7_ble_ext_session_renewal`**, **`g7_ble_ext_session_renewal_skipped`**; cross-link **design** § **Connection state model** for **`G7BLEConnectionState`** vs **G7SensorKit** / DiaBLE. **Design** **v1.14**; **Implementation plan** **v1.24**.
- **Reason:** Operators need grep targets for re-anchored **`WKExtendedRuntimeSession`**; connection-state note prevents misinterpreting renewal guards as “per-packet” states.

### v1.15 (2026-04-12 23:40 CET)
- **Lifecycle (Tier 1) — scene phase does not stop BLE:** Snapshot table **Lifecycle** / **WatchState** / **Tier 1 follow-on** / **Phone → watch** rows; **Events already emitted** — add **`g7_ble_foreground_reentry_skipped`**, drop scene-phase **`g7_ble_stop_deferred`**; **Tier 1 item 1** coupling (**`applyForegroundActiveEntry`** may skip **`startScanning()`**); **Tier 1 item 9** — **`ble_continues=true`**, combined **`active_window_*`** on inactive, **no** lifecycle-**`stop_requested`**, placement text without **`stop()`** on **`handleForegroundInactiveOrBackground`**. **Design** **v1.13**; **Implementation plan** **v1.23**.
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
- **Single driver for leave-active:** Normative text + snapshot — **`TrioWatchApp`** SwiftUI **`ScenePhase`** only for **`handleForegroundInactiveOrBackground`**; **do not** duplicate via **`applicationWillResignActive`** (see **Placement / single source of truth** in Tier 1 **item 9**).
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
