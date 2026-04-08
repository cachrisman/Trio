# Watch Launch Stability — Startup Load Shedding Design

**Version:** v1.14
**Created:** 2026-04-01 09:31 CEST
**Last updated:** 2026-04-08 21:45 CEST
**Status:** Final

Findings: [00-investigation-findings.md](00-investigation-findings.md)
Implementation plan: [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md)
Launch memory investigation: [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md)
Path B design (gates / decisions): [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)

### What this document contains

- **Path A — Startup load shedding / launch pressure reduction** is **fully specified** here (grace model, coordinator ownership, observability, success criteria).
- **Path B — Watch foreground memory-hardening / launch footprint reduction** is summarized here at **design intent** only (commitments and open questions **without** implementation-shaped specifics).
- **Path B decisions and gates** (B0 exit, pre-B2 product table, jetsam diagnostic inventory) live in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) and are **execution-linked** from [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md).
- **Detailed Path B evidence** (code pointers, confidence grades, ranked consumers) lives in [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md).
- **Executable Path B phases** (B0–B5) and **Path A tasks** (A1–A3) live in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md).

---

## Remediation paths (watch launch stability)

Remediation is intentionally **two tracks**: **Path B primary** for the **observed memory-budget closure**, **Path A parallel and justified** for **launch pressure**.

| Path | Name | Primary lever | Role |
| ---- | ---- | ------------- | ---- |
| **B** | Watch foreground memory-hardening / launch footprint reduction | **How large** the launch object graph is: reduce on-watch history depth / duplicate state, bound startup HealthKit batch size, eliminate payload-stringifying logging amplifiers, lazy/defer chart and heavy detail surfaces, add instrumentation | **Primary remediation track** for resident footprint / launch graph size given repeated foreground-launch jetsam (`per-process-limit`, `highwater` — see **Jetsam reason note** below) |
| **A** | Startup load shedding / launch pressure reduction | **When** startup does work; suppress outbound **log transport**; defer first watch-state refresh, HealthKit setup, persisted-log flush | **Parallel pressure-reduction** track; removes transport/scheduling amplifiers that **may compound** resident pressure; does **not** replace Path B |

**Sequencing:** Path B **should begin immediately**; **Path A should continue in parallel as sequencing allows**; ordering between tracks is a **delivery decision** (see [00-investigation-findings.md](00-investigation-findings.md) and [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md)).

**Jetsam reason note:** Archived `.ips` files in **00** § 4 (three captures: **2026-04-01** + two **2026-04-03**) show **`per-process-limit`** and **`highwater`** on the `Trio Watch App` process entry. Validation still treats **both** reason strings as in-scope; see [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § Jetsam reason strings for the file/reason table.

---

## Problem (Path A scope)

**Path A problem statement (baseline before Path A implementation):** watch startup performed too much work before the foreground session had settled:

- launch and finish-launch logs could trigger immediate watch-to-phone transport
- first active performed persisted-log flush behavior
- `WCSession` activation, HealthKit setup, and the initial watch-state request all happened at or near foreground entry

That creates a launch path where cross-device messaging, local disk work, and startup diagnostics compete with initial UI stabilization.

The observed user-visible symptom includes a forced return to the clock face. **Repeated** watch `JetsamEvent` diagnostics on foreground launch/open show `Trio Watch App` as the largest active process at kill, with reasons including **`per-process-limit`** and **`highwater`**—i.e. **memory-budget closure** is the **primary observed** mechanism. **Path B** is the **primary** response to that footprint; **Path A** remains **parallel and justified** because it removes **launch-time transport/scheduling amplifiers** that **may compound** pressure.

The Path A design goal is not to redesign all watch lifecycle behavior. It is to reduce the amount of **startup-initiated** work during the first foreground seconds after launch so the app can render cached or fallback content first and only then begin transport-heavy work.

Path A does **not** claim to eliminate every possible cause of watch jetsam by itself. The core Path A commitment is to remove identified **startup load** from the critical path. **Path B** addresses **resident footprint** even when Path A acceptance passes.

---

## Context / Baseline state (Path A targets)

The bullets below describe the **pre–Path A baseline** this design was written to remediate (the live tree may already implement parts of Path A):

- `WatchLogger` persists locally and can also send logs to the phone for upload / cleanup.
- `TrioWatchApp.init` and `applicationDidFinishLaunching` emitted startup logs that could flush immediately.
- foreground activation performed crash-state marking and persisted-log flushing.
- `WatchState.setupSession()` activated `WCSession` and immediately called HealthKit setup.
- `applicationDidBecomeActive()` immediately requested watch state from the phone.
- other foreground-startup-adjacent paths could also request watch state, including the WCSession activation-complete callback, reachability-change handling, and cold-start helper logic in `WatchState`.
- `flushPersistedLogs()` performed transport-related work internally, including build-change logging with `force: true`, `drainComplicationLogs()`, ACK querying, and resend behavior.

The issue investigated here is the combined effect of:

1. launch-path log transport / forced flush pressure
2. cold-start contention from startup work

Explicitly out of scope **for Path A** (this document):

- redesign of the connectivity background-task completion state machine
- reverting build 142 `applicationContext`
- fixing broader phone-side storage / file retrieval problems in the same change

**Path B** (memory-hardening) is **in scope for the overall initiative** but is **not** fully specified here—see [Path B — Watch foreground memory-hardening](#path-b--watch-foreground-memory-hardening--launch-footprint-reduction) and the implementation plan.

---

## Constraints / Requirements

- No watch-to-phone **log / telemetry transport** (WatchLogger-driven upload: flush, drain, `query_acks`, resend, and related logging pipeline traffic) during app init or the startup grace window defined below. This is **distinct from** application sync messages such as the deferred **watch-state refresh** (`requestWatchStateUpdate`), which is intentionally allowed after its own shorter delay.

**Startup grace model:** transport suppression is armed at process launch so app-init and finish-launch work cannot escape it. The 2-second and 10-second deferred timers begin only after confirmed foreground activation and count **continuous** active time for the current activation sequence. Leaving active cancels pending work; a later re-entry starts a new activation sequence with newly scheduled deferred work. This combined suppression-and-deferral behavior is referred to below as the startup grace window.

In plain terms: "startup grace window" is the umbrella term, transport suppression begins at launch, deferred timers begin on confirmed active, and suppression re-arms for each later activation sequence in the same process.

- Startup logs must still be written locally.
- Crash-state marking remains immediate on first active.
- Cached snapshot / fallback display remains available immediately.
- Initial watch-state refresh is still required, but not at the earliest activation edge.
- The startup coordinator must own the first foreground / cold-start watch-state refresh. Startup callbacks such as `applicationDidBecomeActive`, the WCSession activation-complete callback (`session(_:activationDidCompleteWith:error:)`), reachability-change handling, and cold-start helper logic must not send a direct `requestWatchStateUpdate()` during the startup grace window.
- HealthKit setup is still required, but should not run during raw session setup.
- This initiative does not suppress or throttle receive-side inbound `applicationContext` or `userInfo` delivery during startup. It only suppresses startup-initiated outbound log transport and defers outbound first-refresh behavior.
- The remediation must be deterministic and observable.

---

## Decision (Path A)

### Recommended approach

Adopt a two-stage startup grace model owned by watch startup state.

### Stage 1: immediate foreground entry

Immediate foreground entry is intentionally light:

- local-only startup logging is allowed
- crash-state marking runs immediately
- cached snapshot / fallback display behavior remains unchanged
- no log transport, no persisted-log flush transport, no HealthKit setup, and no initial phone watch-state request run in this stage
- startup lifecycle / reachability / activation callbacks may signal the coordinator, but they do not bypass it to send foreground-startup sync directly

### Stage 2: deferred startup work after foreground settle

If the app remains foreground-active long enough, deferred startup work runs in a fixed order:

1. initial watch-state refresh after 2 seconds
2. HealthKit setup after 10 seconds
3. persisted-log flush after 10 seconds

The deferred sequence is canceled if the app leaves active state before a scheduled item fires.

---

## Functional Behavior

### Startup grace model

Use one startup sequence per active transition.

Defaults:

- defer initial watch-state refresh by 2 seconds after confirmed foreground activation
- defer HealthKit setup by 10 seconds after confirmed foreground activation
- defer persisted-log flush by 10 seconds after confirmed foreground activation
- cancel deferred work if the app leaves active state before the corresponding timer fires
- allow only one deferred startup sequence per active transition
- if the app leaves active before deferred work fires and later re-enters active in the same process, schedule a new coordinator-owned startup watch-state refresh and deferred flush for that new activation sequence
- if the app later re-enters active after an earlier activation sequence already completed, transport suppression still re-arms for that new activation sequence before any new deferred work begins
- allow HealthKit setup only once per process unless the process restarts

### Local-only logging during startup

Startup logs still append to the local daily log and in-memory buffers, but they do not trigger transport during the startup grace window.

This means:

- launch / finish-launch logging remains available for diagnosis
- immediate transport-side operations such as flush, query-acks, resend, or drain do not run during the startup grace window
- direct startup-time calls into `flushPersistedLogs()` may record deferred work or preserve local state, but they do not execute `drainComplicationLogs()`, `queryAcks`, resend, or `flushToPhone()` transport until startup grace has expired
- that suppression must happen inside `flushPersistedLogs()` itself, or inside a split transport-capable phase of that API, before any internal build-change `log(..., force: true)` branch can trigger transport

### Deferred watch-state refresh

The first phone watch-state request moves out of the immediate activation edge.

The app should:

- enter foreground
- mark crash-state / active state
- display cached or fallback data if present
- wait 2 seconds of continuous active state
- then send the first watch-state refresh request

Retry behavior after that first deferred request remains unchanged.

Exactly one coordinator-owned startup watch-state request fires per activation sequence after the 2-second delay. If the app leaves active before that request fires and later re-enters active in the same process, the new activation sequence schedules its own startup-owned request. Background refresh paths and post-first-request retry behavior remain unchanged.

The coordinator owns all first-refresh startup triggers. Existing cold-start helpers and callbacks that **would otherwise** force an early request (as in the **pre–Path A baseline**), including WCSession activation-complete and reachability-change handling, must either delegate to the coordinator or become no-ops until the first deferred request has fired or startup grace has been canceled.

### First-refresh call-site inventory and exceptions

Coordinator-owned during foreground startup:

- `applicationDidBecomeActive`
- SwiftUI foreground-active scene entry
- WCSession activation-complete cold-start force path
- reachability-change cold-start force path
- transfer-error retry paths only if they occur before the coordinator-owned first refresh has fired

Explicit exceptions or out of scope for this initiative:

- background refresh task initiated sync (`handleBackgroundTasks`)
- user-initiated debug or diagnostics refresh actions
- retries that occur after the coordinator-owned first refresh has already fired
- incoming `applicationContext` or `userInfo` receive-side handling, including receive-side startup bursts, which are not request triggers and are not throttled by this initiative

### Deferred HealthKit setup

HealthKit background delivery registration and observer setup no longer happen inside raw session setup.

Instead:

- a process-scoped guard tracks whether HealthKit setup has already completed in this process
- if not yet completed, startup schedules HealthKit setup for 10 seconds after confirmed active state
- if the app leaves active before the timer fires, the scheduled work is canceled and will be rescheduled on the next active transition

### Deferred persisted-log flush

`flushPersistedLogs()` no longer runs immediately on first active.

Instead:

- foreground entry schedules it for 10 seconds after confirmed active state
- the scheduled flush is canceled if the app leaves active before firing
- any startup-time fallback path that calls `flushPersistedLogs()` before the 10-second point is grace-aware and transport-suppressed; it may only preserve local state or mark deferred work
- startup-time activation-failure and transfer-error flush paths follow the same grace rules as the normal first-active path
- background and inactive flush behavior is otherwise left unchanged

### Non-functional expectations

- startup should perform less **log / telemetry** cross-device traffic during the first 10 foreground seconds (application watch-state sync at 2 seconds is expected and is not counted as log transport)
- initial UI should rely on cached snapshot / fallback content rather than immediate phone round-trips
- startup behavior should be deterministic across repeated active/inactive transitions
- observability must clearly show whether deferred work was scheduled, canceled, or fired

---

## Observability Expectations

Add startup-specific structured logs:

- `event=watch_startup_grace_scheduled`  
Fields: `activation_seq`, `watch_state_delay_s=2`, `healthkit_delay_s=10`, `flush_delay_s=10`
- `event=watch_startup_grace_canceled`  
Fields: `activation_seq`, `reason=left_active_before_fire`, `pending=watch_state|healthkit|flush|none`
- `event=watch_startup_deferred_watch_state_refresh_fired`  
Fields: `activation_seq`
- `event=watch_startup_deferred_healthkit_setup_fired`  
Fields: `activation_seq`, `already_initialized=false|true`
- `event=watch_startup_deferred_persisted_log_flush_fired`  
Fields: `activation_seq`

Optional diagnostic log:

- `event=watch_startup_transport_suppressed`  
Fields: `activation_seq`, `path=flush_to_phone|flush_persisted_logs|query_acks|resend|drain|startup_signal`, `reason=startup_grace`

Terminology note:

- use `queryAcks` when referring to the outbound envelope key
- use `query_acks` when referring to the existing WatchLogger log context string

The required logs above are sufficient for acceptance; the optional suppression log is diagnostic only.

---

## Alternatives Considered (and Rejected)

### 1. Fix item 3 in the same change

Rejected for this initiative.

Reason:

- the connectivity background-task state machine is a separate subsystem
- it had a strong signal on 2026-03-30, but the evidence is weaker for the current report after the 2026-03-31 fixes
- changing it now would reduce attribution for the higher-confidence launch-path hypothesis

### 2. Revert build 142 `applicationContext`

Rejected.

Reason:

- the investigation did not show build 142 `applicationContext` as the leading regression point
- the stronger regression cluster is late March
- reverting `30f166c5a` would remove a fallback path without addressing the startup contention evidence

### 3. Move all startup work to background-only

Rejected.

Reason:

- the watch still needs a deterministic foreground recovery path
- a pure background-only approach would make fresh-state recovery dependent on later wakes
- the correct fix is to defer startup work, not eliminate it from foreground completely

---

## Risks / Open Questions


| Risk                                                                                                                                      | Impact        | Mitigation                                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delayed first fresh state update feels slower than current behavior                                                                       | Low to Medium | Keep the watch-state delay short at 2 seconds and rely on cached / fallback data immediately.                                                                                          |
| Deferred flush delays startup telemetry availability                                                                                      | Low           | Acceptable tradeoff; local logs remain preserved.                                                                                                                                      |
| HealthKit setup deferred too aggressively could delay HK-based freshness recovery                                                         | Medium        | Limit the delay to 10 seconds and only for startup, not for the rest of the session.                                                                                                   |
| Another code path still triggers **log** transport during startup grace (including timer-driven or size-threshold flush in `WatchLogger`) | Medium        | Gate **all** `flushToPhone` entry points (forced flush, periodic timer, size threshold) on the same suppression flag; add observability for scheduled / fired / canceled startup work. |
| Existing cold-start watch-state callbacks still bypass the coordinator                                                                    | Medium        | Route `applicationDidBecomeActive`, WCSession activation-complete, and reachability-triggered first-refresh behavior through the same coordinator-owned startup sequence.              |
| Path A reduces transport contention but jetsam persists                                                                                  | Medium        | Prioritize **Path B** (primary footprint track) per the implementation plan—not as proof that Path A was mis-specified. Path A validation still matters to catch coordinator / transport regressions. |


Open question retained for later work:

- whether the connectivity background-task completion state machine should be simplified after startup load shedding is validated

---

## Success Criteria (Verifiable)

**Applies to:** Path A only (startup load shedding). Path B success evidence is defined in the implementation plan (**B0–B5**); **B0** (instrumentation/repro) and **B5** (jetsam matrix) are the primary **cross-cutting** anchors, and **B1–B4** each carry **phase-local acceptance** in the plan.

- No watch-to-phone **log / telemetry transport** (WatchLogger pipeline: flush, drain, `query_acks`, resend, and equivalent) occurs during app init or the first 10 seconds of a continuous foreground activation. **Application** watch-state sync traffic after the 2-second deferred refresh is allowed and must not be interpreted as a failure of this criterion.
- Startup logs still appear in the local daily log.
- The first watch-state refresh is sent only after 2 seconds of continuous active state.
- No foreground-startup callback bypasses the coordinator to send the initial watch-state request before the 2-second delay.
- All `requestWatchStateUpdate()` call sites are either coordinator-owned during foreground startup or explicitly documented as exceptions.
- For each activation sequence, exactly one coordinator-owned startup watch-state request fires after 2 seconds of continuous active state.
- HealthKit setup is not called from raw session setup and fires only after 10 seconds of continuous active state.
- Persisted-log flush does not run immediately on first active and instead fires only after the 10-second grace window.
- Startup-time calls into `flushPersistedLogs()` do not perform build-change `force: true` transport, drain, `queryAcks` / `query_acks`, resend, or `flushToPhone()` transport before the 10-second grace window expires.
- Leaving active before scheduled work fires cancels the pending startup sequence and logs the cancellation.
- During the 2-second startup grace window, the watch continues showing existing cached snapshot or fallback placeholder content rather than regressing to a blank or spinner-only screen.
- Item 3, the connectivity background-task state machine, remains unchanged by this remediation.

---

## Device-Side Jetsam Validation

### Path A validation (startup load shedding)

This protocol is a **Path A** validation signal. It is **not** a guarantee that Path A alone eliminates every memory-budget kill.

Minimal protocol:

- run at least 10 tethered foreground-open attempts on the target watch model, target watchOS build, and target Trio build
- begin each attempt from the clock face with the paired phone in its normal connected state
- capture device console / diagnostics for the run set
- check whether any new `JetsamEvent` during those attempts names `Trio Watch App` with `reason=per-process-limit` **or** `highwater` (record the diagnostic reason string as emitted)

Interpretation:

- no Trio `per-process-limit` / `highwater` jetsam across that protocol is **supportive** evidence for Path A’s goals; it does **not** permanently prove Path B is unnecessary if other repro windows still show jetsam
- recurrence of Trio jetsam with **`per-process-limit` / `highwater`** during that protocol does **not** by itself mean Path A acceptance failed; it means **Path B** (primary footprint track) should **proceed**—**sequencing vs Path A** remains a delivery decision
- recurrence of early outbound `query_acks`, `flush`, `drain`, or another coordinator-bypass before the deferred windows **does** mean the **Path A** acceptance criteria failed and should be fixed before attributing remaining jetsam to Path B alone

### Path B validation (memory-hardening)

Path B carries **additional** repro and instrumentation expectations in the implementation plan (e.g. launch memory measurement, A/B isolation of chart and HealthKit paths). Treat Path B validation as **orthogonal** to Path A transport checks: Path A can pass while Path B work is still required.

---

## Path B — Watch foreground memory-hardening / launch footprint reduction

This section records **design-level commitments and open questions** for Path B. It **does not** duplicate the full evidence table from [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md). That investigation establishes **code-level** allocators/retainers and **graded confidence**; it explicitly **does not** replace an Instruments allocation profile.

### Motivation (observed vs inferred)

- **Observed (device diagnostics):** repeated foreground-launch/open jetsam with `Trio Watch App` frontmost/active; reasons include `per-process-limit` and `highwater`.
- **Inferred (engineering, per investigation doc):** the combination of large WC watch-state delivery, duplicate in-memory representations, eager chart UI, logging stringification, and unbounded HealthKit batch risk is a **plausible** explanation for **resident pressure**; individual items have **different confidence grades** in doc 03.

### Design commitments (Path B) — intent only

Exact APIs, file touch lists, and acceptance tests belong in the **implementation plan** (02) and investigation artifact (03). At design level, Path B commits to:

- **Bound startup HealthKit batch size** so launch cannot pull unbounded samples on cold/reset anchor paths.
- **Reduce on-watch history depth / duplicate state** for the same logical data (fewer stacked full copies in memory).
- **Eliminate payload-stringifying logging amplifiers** (no logging patterns that materialize entire large dictionaries/messages as strings).
- **Lazy/defer chart and heavy detail surfaces** until needed, so launch does not always pay full chart/history UI cost up front.
- **Add launch memory instrumentation and repro discipline** so mitigations are validated with measurement, not assumed from code inspection alone.

### Still open (explicit non-commitments)

- Exact caps, downsampling rules, and product fidelity tradeoffs (pre-B2 table in **04** is signed off **2026-04-06** — **B2** implementation still encodes those choices in code).
- Whether lazy chart construction is sufficient on **all** target watchOS versions: **partially validated** on the TestFlight **152** deploy target; broader OS/hardware matrix remains optional.
- Relative impact ranking of mitigations without Instruments/resident samples (doc 03 avoids overclaiming).

### Field outcome note (2026-04-06)

**TestFlight build 152** (see [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) implementation log): **`GlucoseChartView` is built only when the chart `TabView` page is selected** (**B3**), matching the lazy pattern called out in doc **03**. Together with **Path A** startup deferral/suppression and **B1**/**B4** mitigations, the watch app is reported to **launch and remain stable in the foreground** without the prior **jetsam / forced return to the clock face**. **Pre-B2** product sign-off (**Charlie Chrisman**, **2026-04-06**) is recorded in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md). **B5** and **B0** are **closed** for this initiative (**02** implementation log **2026-04-08 21:33 CEST** / **21:45 CET**). Optional **B2** payload-shaping work remains **when prioritized** (**02** / **04**).

### Field outcome note (2026-04-08)

**TestFlight 153+** ships **Path B** **B6** — field **`TASK_VM_INFO.phys_footprint`** samples via **`event=watch_resident_sample`** / **`phys_footprint_mib`** (default **on** on TestFlight / sandbox receipt; **04** § **B6**). See [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) implementation log **2026-04-08 18:02 CEST**. **B6** supported **B0** clause **2**; **B5** and **B0** are **closed** (**2026-04-08** — **02** **2026-04-08 21:33 CEST** / **21:45 CET**).

---

## Changelog

### v1.14 (2026-04-08 21:45 CET)

- **Path B — field outcomes:** **§ Field outcome note (2026-04-06)** and **§ Field outcome note (2026-04-08)** — **B5** / **B0** no longer described as open; optional **B2** called out; **153+** wording.

### v1.13 (2026-04-08 18:02 CEST)

- **Path B:** **§ Field outcome note (2026-04-08)** — TestFlight **153**, **B6** resident telemetry live; pointer to **02** implementation log **2026-04-08 18:02 CEST**.

### v1.12 (2026-04-06 15:48 CET)

- **Path B:** Added **§ Field outcome note (2026-04-06)** (build **152**, lazy chart **B3**, stable launch). **Still open:** narrowed lazy-chart bullet to **partial** multi-OS validation; noted **04** pre-B2 sign-off.

### v1.11 (2026-04-03 21:56 CET)

- **Jetsam diagnostics:** **Jetsam reason note** updated for **three** archived `.ips` files (**`per-process-limit`** and **`highwater`** both captured on-device). “What this document contains” now refers to **04**’s **jetsam diagnostic inventory** (not the prior single-file caveat).

### v1.10 (2026-04-03 21:39 CET)

- Linked **[04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)** in header and “What this document contains.” **Sequencing** aligned with **00** (**Path A continues in parallel as sequencing allows**). **Jetsam reason note** for **`highwater`** vs single `.ips` artifact.

### v1.9 (2026-04-03 21:26 CET)

- **Pre-implementation doc review:** replaced **“currently force”** coordinator wording with **pre–Path A baseline / “would otherwise force”** to match the rest of the doc set; clarified Path B success evidence as **B0–B5** with **B0/B5** as cross-cutting anchors and **B1–B4** phase-local acceptance in **02**.

### v1.8 (2026-04-03 21:19 CET)

- **Track positioning:** **Path B primary**, **Path A parallel and justified**; softened lockstep “mandatory parallel” language in favor of **required Path B + delivery sequencing**. **Status → Under major revision.**
- **Document roles:** stated explicitly that this file **fully specifies Path A**, **summarizes Path B at design intent**, and points **evidence** to 03 and **executable phases** to 02.
- **Path B design:** raised abstraction—commitments now read as **bound HK batch**, **reduce history/duplicate state**, **eliminate stringifying log amplifiers**, **lazy/defer heavy UI**, **instrumentation**; removed implementation-shaped API/file specifics from the design section.
- **Baseline wording:** Problem and context sections now describe **pre–Path A baseline** where appropriate to avoid implying the old launch path is still “current” in tree.

### v1.7 (2026-04-03 21:01 CET)

- Introduced **Path A** vs **Path B** framing: this document remains the authoritative **Path A** (startup load shedding) spec; added **Path B — Watch foreground memory-hardening** design commitments and open questions grounded in [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md). Clarified that repeated **`per-process-limit` / `highwater`** jetsam makes memory-budget closure the **primary observed** mechanism; Path A is necessary but not the sole remediation. Split jetsam validation into Path A vs Path B interpretations; updated the risks table to require **Path B** when jetsam recurs after Path A.

### v1.6 (2026-04-02 21:22 CEST)

- Tightened wording after an additional external-review pass: added one plain-language sentence defining the startup grace window as the umbrella term, clarified that transport suppression re-arms for later activation sequences in the same process, and improved the readability of the coordinator-owned startup watch-state success criterion.

### v1.5 (2026-04-02 21:12 CEST)

- Clarified the startup grace model after external review: transport suppression is armed at process launch while deferred timers are keyed to confirmed foreground activation, re-entry in the same process starts a new activation sequence, receive-side inbound startup bursts remain an explicit non-goal, cancellation logs now record pending tasks, and success criteria now spell out one coordinator-owned startup request per activation sequence plus expected cached/fallback UI during the 2-second grace.

### v1.4 (2026-04-01 17:39 CEST)

- Split core startup-load-shedding acceptance from device-side jetsam validation. Added explicit language that no-jetsam is a high-priority validation signal rather than a guaranteed sole-scope outcome, and defined a concrete tethered repro protocol plus follow-up path if `per-process-limit` jetsam persists.

### v1.3 (2026-04-01 14:58 CEST)

- Added call-site inventory rules for first-refresh coordinator ownership vs explicit exceptions, clarified that startup-time transfer-error and activation-failure flushes obey startup grace, and required internal `flushPersistedLogs()` suppression before build-change `force: true` logging or other transport branches. Incorporated the watch jetsam evidence and added device-side no-jetsam validation to success criteria.

### v1.2 (2026-04-01 14:22 CEST)

- Clarified that the startup coordinator owns all foreground / cold-start first-refresh triggers, including activation-complete and reachability-driven startup signals. Defined startup-time `flushPersistedLogs()` as grace-aware and transport-suppressed until the 10-second window expires, and expanded success criteria / observability accordingly.

### v1.1 (2026-04-01 09:42 CET)

- Pre-implementation doc review: defined **log / telemetry transport** vs application watch-state sync; aligned success criteria and non-functional expectations so the 2-second deferred watch-state request is not a false failure of the “no transport in first 10s” criterion. Added explicit startup grace window definition for log transport and expanded the “another code path” risk to include timer- and size-threshold flushes in `WatchLogger`.

### v1.0 (2026-04-01 09:31 CEST)

- Initial design for the watch launch stability remediation. Defines a two-stage startup grace model that combines launch-path log transport reduction with deferral of HealthKit setup and the initial watch-state refresh, while explicitly excluding connectivity background-task redesign from scope.
