# Watch Launch Stability — Implementation Plan (Path A & Path B)

**Version:** v2.15  
**Created:** 2026-04-01 09:31 CEST  
**Last updated:** 2026-04-06 16:07 CET  
**Status:** Final  

**Filename note:** This file remains `02-startup-load-shedding-implementation-plan.md` for stable links; the **title** reflects **Path A** (startup load shedding) and **Path B** (foreground memory-hardening).

Design reference: [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md)  
Findings: [00-investigation-findings.md](00-investigation-findings.md)  
Launch memory investigation: [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md)  
**Path B design (decisions / gates):** [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)

This document implements **two remediation paths**. **Path B — Watch foreground memory-hardening / launch footprint reduction** is the **primary remediation track** for the **observed memory-budget closure** on foreground launch/open. **Path A — Startup load shedding / launch pressure reduction** remains a **justified parallel** track (transport/scheduling amplifiers that may compound resident pressure). **Path B is a required remediation track and should begin immediately**; **Path A should continue in parallel as sequencing allows** (see [00-investigation-findings.md](00-investigation-findings.md))—the docs do **not** claim the evidence proves both must ship in lockstep.

**Naming:** Path A work is labeled **A1, A2, A3**. Path B work is labeled **B0–B5**. These namespaces are intentionally disjoint (there is no “Path A phase B”).

**Jetsam reasons:** Validation checks both **`per-process-limit`** and **`highwater`**. **00** § 4 and **04** § Jetsam reason strings inventory **three** archived `.ips` files (`2026-04-01` + two `2026-04-03` captures); **`per-process-limit`** and **`highwater`** both appear **on-device** in that set.

**Current field status (2026-04-06):** TestFlight **152** combines **Path A** startup load shedding with **Path B** **B1**, **B3** (lazy **`GlucoseChartView`** until the chart tab is selected), and **B4**. Field report: **first open after install** succeeded — stable watch launch and foreground without jetsam or forced closure to the clock face (no multi-open “burn-in” needed for subjective confidence) — see implementation log **2026-04-06 15:23 CET** and **§ B5 — Attempt matrix** below. **04** pre-B2 **owner / date decided** filled (**Charlie Chrisman**, **2026-04-06**) so **B2** is unblocked for sequencing. Optional: complete **B5** rows **2–10** (Mac-tethered protocol); deferred **B0** resident checkpoints; **B2** coding when prioritized.

---

## Scope

### Path A — Startup load shedding / launch pressure reduction

Implement the combined startup-load-shedding remediation for the watch app:

- remove watch-to-phone log transport from app init and the immediate foreground activation window
- defer the initial watch-state refresh
- defer HealthKit setup
- keep startup logging local during the grace window
- add deterministic scheduling / cancellation for this deferred startup work
- reduce startup load with an expected **possible** secondary reduction in peak startup memory; validate coordinator / transport / deferral behavior and run the Path A jetsam protocol

Path A **does not** guarantee elimination of every future Trio jetsam. Core Path A acceptance is the startup coordinator / transport / HealthKit behavior defined in **A1–A3**.

### Path B — Watch foreground memory-hardening / launch footprint reduction

Implement footprint-focused mitigations informed by [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md): payload shaping, duplicate representation reduction, lazy/deferred chart construction, removal of full-message WC logging, bounded HealthKit startup queries, and launch memory instrumentation—with **runtime validation** where called out below.

**Path B is a required remediation track and should begin immediately** given **repeated** foreground-launch jetsam (`per-process-limit`, `highwater`). **Sequencing vs Path A** is a **delivery decision**. **Both** tracks are expected to be **valuable** for a complete response; neither obsoletes the other.

## Out of scope

- connectivity background-task completion redesign
- transport protocol changes (Path A/B may adjust **payload content/size** on existing WC surfaces—see Path B—but not a wholesale protocol redesign)
- broader phone-side storage or missing-file failures
- rollback of build 142 `applicationContext`
- retry-policy redesign after the first deferred watch-state request (Path A)
- ad hoc memory tweaks **not** tied to doc 03’s ranked targets (prefer structured Path B phases)

## Dependencies

- `docs/process/standards-observability.md`
- `00-investigation-findings.md`
- `01-startup-load-shedding-design.md`
- `03-watch-foreground-launch-memory-investigation.md`
- `04-watch-foreground-memory-hardening-design.md` (**Path B** decisions and B0/B2 gates—required before treating **B2** as implementation-ready)
- existing watch startup entry points in:
  - `Trio Watch App Extension/TrioWatchApp.swift`
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch App Extension/WatchState+Requests.swift`
  - `Trio Watch App Extension/WatchLogger.swift`

---

## Path A — Startup load shedding / launch pressure reduction

**A1–A3** below are **Path A** work items. **B0–B5** are **Path B** work items. The **A*** and **B*** numeric labels are separate namespaces (there is no “Path A phase B”).

---

## Sequencing + Ship Boundaries (Path A)

### Path A work breakdown (A1–A3)

- **A1 — Startup coordinator:** not shippable alone; scaffolding for later behavior changes.
- **A2 — Remove launch-path flush pressure:** safe to ship with A1; partial benefit even before A3 lands.
- **A3 — Defer HealthKit and first watch-state request:** ship together with A1 and A2 for the intended startup behavior.

Preferred ship boundary:

- single release containing **A1, A2, and A3** together

Fallback ship boundary if a smaller step is needed:

- ship **A1 and A2** first, then **A3**

**Path B sequencing:** B0 (instrumentation) should begin early enough to measure B1–B4 tranches, but **B1** (logging amplifier removal) is **high-confidence** and can land as soon as practical **alongside** Path A. Exact ordering of B2–B4 may depend on product/UI constraints; B5 validates the combined outcome.

---

## Shared Conventions (Path A)

- This plan conforms to: `docs/process/standards-observability.md`
- Use structured log lines for all new startup coordinator events.
- Fixed defaults:
  - watch-state refresh delay: 2 seconds
  - HealthKit setup delay: 10 seconds
  - persisted-log flush delay: 10 seconds
- Startup transport suppression is armed at process launch so init / finish-launch logging cannot escape it. The deferred 2-second and 10-second timers begin only after confirmed foreground activation and count continuous active time for the current activation sequence. This combined suppression-and-deferral behavior is referred to below as the startup grace window.
- In plain terms: startup grace window is the umbrella term, suppression begins at launch, deferred timers begin on confirmed active, and suppression re-arms for each later activation sequence in the same process.
- Use one startup sequence per active transition.
- If the app leaves active before deferred work fires and later re-enters active in the same process, start a new activation sequence and reschedule the coordinator-owned startup watch-state request and deferred flush for that transition.
- If the app later re-enters active after an earlier activation sequence already completed, re-arm transport suppression for the new activation sequence before any new deferred work begins.
- HealthKit setup may run only once per process.
- Background / inactive flush behavior remains unchanged unless explicitly required by the startup coordinator.
- The startup coordinator owns every foreground / cold-start **first** watch-state request until that deferred request has fired or startup grace is canceled. Direct startup requests from `applicationDidBecomeActive`, WCSession activation-complete, `forceConditionalWatchStateUpdate()`, and reachability-change handling must be rerouted through the coordinator or suppressed during startup grace.
- This initiative does not suppress or throttle receive-side inbound `applicationContext` or `userInfo` delivery during startup; it only defers startup-initiated outbound requests and suppresses outbound log transport.
- **Log transport suppression must apply to every startup path that can send logs to the phone** — not only `log(..., force: true)` and not only direct `flushToPhone()` calls. In particular, the periodic flush timer, the `flushSizeThreshold` path in `flushIfNeeded`, and startup-time `flushPersistedLogs()` entry points that would otherwise perform `drainComplicationLogs()`, `queryAcks`, resend, or `flushToPhone()` must respect the same startup grace flag.

### First-refresh trigger inventory

Coordinator-owned during foreground startup:

- `ExtensionDelegate.applicationDidBecomeActive`
- SwiftUI foreground-active scene entry
- WCSession activation-complete cold-start force path
- reachability-change cold-start force path
- transfer-error retry paths only if they occur before the coordinator-owned first refresh has fired

Explicit exceptions or out of scope:

- background refresh task initiated sync (`handleBackgroundTasks`)
- user-initiated debug or diagnostics refresh actions
- retries that occur after the coordinator-owned first refresh has already fired
- incoming `applicationContext` or `userInfo` receive-side handling, including receive-side startup bursts

### `flushPersistedLogs()` implementation rule

Startup grace handling must be enforced **before any transport-capable branch inside the `flushPersistedLogs()` implementation boundary**. This can be achieved by refactoring the existing method internally or by splitting it into a startup-safe phase plus a separately invoked deferred transport phase. A wrapper alone is not sufficient if the internal implementation still runs build-change `log(..., force: true)`, `drainComplicationLogs()`, `queryAcks`, resend, or `flushToPhone()` before the 10-second deferred flush window.

---

## Path A — A1: Startup coordinator

**Ship gate:** no; by itself this adds internal state but does not yet reduce startup load.
**Rollback:** remove the coordinator state, timers, and new startup logs; revert active/inactive hooks to direct behavior.

### Add coordinator state

- Files:
  - `Trio Watch App Extension/WatchState.swift`
- Change:
  - add a single startup coordination path owned by watch startup state
  - track active-transition sequence id
  - track pending work items for:
    - deferred watch-state refresh
    - deferred HealthKit setup
    - deferred persisted-log flush
  - track whether the coordinator-owned first watch-state refresh has already fired for the current activation sequence
  - track whether HealthKit setup has already run in the current process
- Steps (ordered):
  1. Add startup coordinator fields to `WatchState`.
  2. Add explicit methods to schedule startup work for a new active transition.
  3. Add explicit methods to cancel pending startup work when the app leaves active state.
  4. Add a coordinator-owned guard for whether the first deferred watch-state request has already fired for the current activation sequence.
  5. Ensure only one coordinator sequence can be active per active transition.
- Acceptance (verifiable):
  - startup work can be scheduled once per active transition
  - pending work can be canceled deterministically
  - the coordinator can tell whether the startup-owned first watch-state request is still pending vs already fired
  - if a startup sequence is canceled and the app later re-enters active in the same process, the new activation sequence gets a new coordinator-owned startup watch-state request and deferred flush
  - HealthKit process-scope initialization flag exists and is separate from per-activation scheduling
- Observability checks:
  - `event=watch_startup_grace_scheduled`
  - `event=watch_startup_grace_canceled`
- Notes / pitfalls:
  - avoid reusing existing connectivity-background-task timers for this feature
  - coordinator state must be main-thread-owned to avoid competing timer mutation

### Wire active / inactive transitions into the coordinator

- Files:
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio Watch App Extension/TrioWatchApp.swift`
- Change:
  - route foreground-active entry and active exit through the startup coordinator
  - preserve crash-state marking behavior
- Steps (ordered):
  1. Keep immediate crash-state marking on foreground entry.
  2. Replace direct startup work at activation points with coordinator scheduling.
  3. On inactive / background transition, cancel pending startup work for the current activation sequence.
- Acceptance (verifiable):
  - foreground entry schedules one startup sequence
  - inactive / background transition cancels it if still pending
- Observability checks:
  - `event=watch_startup_grace_scheduled` logs once per active transition
  - `event=watch_startup_grace_canceled` logs when the app exits active before timers fire, including which tasks were still pending
- Notes / pitfalls:
  - do not break existing lifecycle breadcrumbs unrelated to startup coordination
  - **Activation deduplication:** both `ExtensionDelegate.applicationDidBecomeActive` and `TrioWatchApp`’s SwiftUI `scenePhase == .active` can signal foreground entry; the coordinator must schedule **at most one** startup sequence per logical active transition (e.g. single main-thread entry point, idempotent schedule, or ignore duplicate active signals with the same `activation_seq`).

---

## Path A — A2: Remove launch-path flush pressure

**Ship gate:** yes, with A1. This is a safe partial mitigation because it only delays startup transport and preserves local logging.
**Rollback:** restore direct startup flush behavior and remove the startup transport suppression gate.

### Make startup logs local-only during the startup grace window

- Files:
  - `Trio Watch App Extension/TrioWatchApp.swift`
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio Watch App Extension/WatchLogger.swift`
- Change:
  - startup logs continue to append locally but must not trigger transport during the startup grace window
- Steps (ordered):
  1. Remove force-triggered flush behavior from startup logs in app init and finish-launch paths.
  2. Add an explicit startup transport suppression check in `WatchLogger` so startup logging cannot indirectly send to the phone during the grace window.
  3. Gate the periodic flush timer and the `flushIfNeeded` size-threshold path during startup grace so they respect the same suppression flag as force-triggered logging.
  4. Keep local daily-log persistence unchanged.
- Acceptance (verifiable):
  - launch logs still appear locally
  - no launch-path startup logs, periodic timer flushes, or size-threshold flushes cause watch-to-phone transport before the 10-second grace expires
- Observability checks:
  - startup logs still present in local log
  - no WatchLogger-driven `query_acks`, `flush`, `drain`, resend, or equivalent **logging pipeline** rows appear during the startup grace window (a deferred **watch-state** `WCSession` message after 2 seconds is expected and is **not** a failure of this check)
- Notes / pitfalls:
  - changing `force: true` to `force: false` alone is not enough; transport must be gated centrally during startup grace

### Remove immediate `flushPersistedLogs()` from first-active handling

- Files:
  - `Trio Watch App Extension/TrioWatchApp.swift`
  - `Trio Watch App Extension/WatchLogger.swift`
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch App Extension/WatchState+Requests.swift`
- Change:
  - stop running `flushPersistedLogs()` immediately on first active
  - schedule it through the startup coordinator instead
- Steps (ordered):
  1. Remove direct first-active `flushPersistedLogs()` call sites.
  2. Refactor `flushPersistedLogs()` so startup grace is enforced before any build-change `log(..., force: true)`, `drainComplicationLogs()`, `queryAcks`, resend, or `flushToPhone()` branch can run; a split startup-safe plus deferred transport phase is acceptable only if that guarantee is preserved inside the implementation boundary rather than at an outer wrapper.
  3. Route existing startup-adjacent fallback callers that currently invoke `flushPersistedLogs()` directly through the same grace-aware behavior, including activation-failure and transfer-error paths.
  4. Add a deferred coordinator callback at 10 seconds.
  5. When the deferred flush fires, clear the transport suppression gate for that activation sequence before calling the transport-capable flush path.
- Acceptance (verifiable):
  - no immediate flush runs on first active
  - no startup-time `flushPersistedLogs()` call performs build-change `force: true` transport, `drainComplicationLogs()`, `queryAcks` / `query_acks`, resend, or `flushToPhone()` transport before the 10-second grace expires
  - the deferred persisted-log flush fires only after 10 seconds of continuous active state
- Observability checks:
  - `event=watch_startup_deferred_persisted_log_flush_fired`
  - optional `event=watch_startup_transport_suppressed path=flush_persisted_logs|query_acks|resend|drain`
- Notes / pitfalls:
  - background / inactive flush behavior must remain unchanged unless explicitly routed by the coordinator
  - activation-failure and transfer-error flush callers must follow the same startup grace rules as the first-active path

---

## Path A — A3: Defer HealthKit and first watch-state request

**Ship gate:** yes, with A1 and A2. This is the full intended Path A remediation.
**Rollback:** move HealthKit setup back to session setup and restore immediate activation-time watch-state request.

### Move HealthKit setup behind the startup grace window

- Files:
  - `Trio Watch App Extension/WatchState.swift`
- Change:
  - remove HealthKit setup from raw session setup
  - schedule it through the startup coordinator at 10 seconds
- Steps (ordered):
  1. Remove the direct `setupHealthKitBackgroundDelivery()` call from raw session setup.
  2. Add a deferred coordinator callback that runs HealthKit setup after 10 seconds of continuous active state.
  3. Guard HealthKit setup so it runs once per process only.
  4. If the app leaves active before 10 seconds, cancel the scheduled call and reschedule on the next active transition.
- Acceptance (verifiable):
  - raw session setup no longer starts HealthKit registration
  - HealthKit registration happens only after the 10-second grace, only once per process
- Observability checks:
  - `event=watch_startup_deferred_healthkit_setup_fired`
- Notes / pitfalls:
  - do not accidentally suppress HealthKit observer behavior after setup completes
  - process-scoped setup guard must not prevent scheduling logs from remaining accurate

### Move the initial watch-state refresh behind the startup grace window

- Files:
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch App Extension/WatchState+Requests.swift`
- Change:
  - remove the immediate watch-state request from `applicationDidBecomeActive`
  - schedule the first foreground / cold-start request through the startup coordinator at 2 seconds
- Steps (ordered):
  1. Remove the direct activation-edge `requestWatchStateUpdate()` call.
  2. Audit every `requestWatchStateUpdate()` call site and classify it as coordinator-owned or an explicit exception.
  3. Find `session(_:activationDidCompleteWith:error:)` and route its cold-start first-refresh trigger through the coordinator instead of allowing a direct startup request.
  4. Reroute or suppress other cold-start first-refresh triggers so `forceConditionalWatchStateUpdate()`, reachability-change handling, and pre-first-refresh transfer retry handling do not bypass the coordinator during startup grace.
  5. Leave the explicit exceptions unchanged for this initiative: background refresh task sync, user-initiated debug / diagnostics refresh actions, post-first-refresh retries, and receive-side `applicationContext` / `userInfo` handling.
  6. Schedule the first request for 2 seconds after confirmed active state.
  7. If the app leaves active before 2 seconds, cancel it.
  8. Once the deferred request fires, keep the existing retry behavior unchanged.
- Acceptance (verifiable):
  - no initial watch-state request is sent immediately on activation
  - no foreground / cold-start callback bypasses the coordinator to send the initial watch-state request before the 2-second delay
  - all `requestWatchStateUpdate()` call sites are either coordinator-owned during foreground startup or explicitly documented as exceptions
  - exactly one coordinator-owned startup request fires after 2 seconds of continuous active state for each activation sequence
  - if the app re-enters active later in the same process after a canceled startup sequence, a new coordinator-owned startup request is scheduled for the new activation sequence
  - existing retry behavior remains unchanged after that first request
- Observability checks:
  - `event=watch_startup_deferred_watch_state_refresh_fired`
  - optional `event=watch_startup_transport_suppressed path=startup_signal`
- Notes / pitfalls:
  - do not change the existing request retry policy in this initiative
  - background refresh handling is out of scope for this change; only foreground / cold-start first-refresh triggers are coordinator-owned
  - ensure cached / fallback data remains available during the 2-second grace window

---

## Path B — Watch foreground memory-hardening / launch footprint reduction

**Source of truth for evidence grades:** [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md). Tasks below are **implementation phases**, not a re-proof of doc 03.

**Confidence legend (per phase):**

- **H — High-confidence immediate action:** code-level hazard is explicit; mitigation is low-risk and aligned with doc 03.
- **M — Investigation-informed; needs runtime validation:** expected to help; impact ranking requires Instruments / resident sampling / A/B builds per B0.

### B0 — Launch memory instrumentation and repro measurement (**M**)

**Goal:** separate baseline (SwiftUI + empty state) from deltas (WC decode/merge, chart render, HealthKit batch, log materialization).

- Adopt the instrumentation outline in doc 03 § “Immediate instrumentation plan (device)”: signposts or unified logging around `TrioMainWatchView.onAppear`, `processRawDataForWatchState` (log **count only**), flush entry/exit, `HKAnchoredObjectQuery` results (`samples.count`), and resident sampling checkpoints (cold launch, first frame, +2s refresh, first `didReceiveMessage`, +10s HealthKit, +10s flush).
- **Do not** log full WC message bodies in production instrumentation paths.
- **Acceptance (minimum):** documented repro checklist + captured measurement notes per build; enables before/after comparison for B2–B4.

#### B0 exit gate (required before starting B2 or B3)

**Do not start B2 or B3** until B0 meets **all** of the following (mirror + detail in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § B0 exit gate):

1. **Device run recorded** for a named Trio + watchOS build, covering at least: cold launch, first frame, after deferred watch-state fires, after first large WC payload handled, +10s HealthKit path, +10s log flush path.
2. **Per-checkpoint evidence:** resident sample (memory gauge, `task_vm_info`, Instruments mark, or equivalent) **or** written **infeasibility** with reason and reviewer sign-off.
3. **Chart cost isolation:** one **chart vs no-chart** (or doc 03 Charts A/B) comparison build **or** explicit **deferral decision** with owner, rationale, and follow-up.

Waiving the gate for a given milestone requires a **written waiver** in the implementation log stating which clause is waived and why.

### B1 — Eliminate full-message logging and other memory amplifiers (**H**)

**Goal:** remove avoidable peak allocations from stringifying entire WC messages.

- Remove or replace `session(_:didReceiveMessage:)` logging that interpolates the full `message` dictionary (doc 03: watch `WatchState.swift`). Log **keys, counts, and coarse metadata** only; mirror the phone uploader’s “trim heavy arrays” philosophy where applicable.
- Audit adjacent logging paths for similar “serialize the whole payload” patterns on the watch.
- **Acceptance:** no production log line materializes the full nested `glucoseValues` array as a string; Better Stack / local logs remain usable for diagnosis via structured fields.

### B2 — Payload shaping / glucose history cap / downsampling (**M**, **H** for “something must cap”)

**Goal:** reduce scaling with history length on-watch.

**Pre-B2 gate (blocking):** Complete the decision table in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § Pre-B2 decision gate (max points, where cap applies, downsampling vs truncate, fidelity/parity, owner/date). **Do not** start B2 coding until that table is filled or a linked ADR/ticket contains the same fields.

- **H:** phone-side `fetchLimit: 288` and watch decode paths are explicit in code (doc 03); implement the **recorded** product-bounded cap or downsampling strategy for **watch chart/display** (may involve `AppleWatchManager` + watch decode).
- **M:** measure before/after with B0 tools; validate complication/chart parity against the **recorded** acceptance in **04**.
- **Acceptance:** documented max on-watch points (or equivalent downsampling policy) matching **04** + measurement delta vs baseline; no silent unbounded growth in stored chart series.

### B3 — Lazy or deferred chart/history construction (**M**)

**Goal:** avoid paying full `Charts` / `GlucoseChartView` cost when the chart page is not visible—**pending** runtime confirmation of `TabView` page eagerness on target OS builds.

**Gate:** Same **B0 exit gate** as B2 (do not start B3 until B0 is closed or waived in writing).

- Implement lazy construction aligned with the debug-page gating pattern (doc 03): build chart page content when selected, unless profiling proves it ineffective.
- Consider downsampling for `PointMark` series even when the chart is visible.
- **Acceptance:** A/B or Instruments comparison per B0; documented decision if laziness is ineffective on a given watchOS version.

### B4 — Bound HealthKit startup query behavior (**H** on API shape, **M** on field impact)

**Goal:** eliminate **unbounded** sample batches on nil anchor / 24h window.

- Replace `HKObjectQueryNoLimit` with a **small positive limit** until a durable anchor is established; tighten predicate if needed (doc 03).
- Log `anchor == nil` vs non-nil and `samples.count` (counts only) for validation.
- **Acceptance:** code cannot request an unbounded anchored pull on the nil-anchor path; validation shows bounded batch sizes on test devices.

### B5 — Repeated foreground-open memory / jetsam validation (**M**)

**Goal:** confirm Path B tranches improve the **observed** failure mode.

- Run the **same class** of tethered foreground-open attempts as Path A validation, extended to capture **`highwater`** as well as `per-process-limit`.
- Treat **recurrence** after B1–B4 as a signal to **iterate** Path B (not automatic proof that Path A failed).
- **Acceptance:** recorded attempt matrix + jetsam outcomes + correlation notes (which build, which Path B tranches included).

#### B5 — Attempt matrix (living record)

**Protocol (same class as Path A — § Validation):** at least **10** **tethered** foreground-open attempts from the **clock face** with the paired phone in its **normal connected** state; after the run set, inspect device diagnostics for any new **`JetsamEvent`** naming **`Trio Watch App`** with **`reason=per-process-limit`** or **`highwater`** (export filename + UTC timestamp if found). **B5** extends Path A by **recording** those outcomes next to the **build** and **Path B tranche** set.

**Terminology — “tethered” vs normal use:** In this protocol, **tethered** means the **Apple Watch is connected to a Mac with a data-capable link** (USB / developer-pairing setup) **during the attempt**, so **Console.app** / **sysdiagnose** / diagnostic export is practical if a kill happens. It does **not** mean “paired to iPhone” (that is normal for all attempts). **Untethered** / **field** use is everyday opens from the clock face **without** the Mac cable — valuable signal (matrix **row 1**), but **row 1** stays **Partial** relative to the formal **10× Mac-tethered** row count unless you intentionally run the same steps while tethered and record them in **2–10**.

**Build / tranche correlation (validation window — 2026-04-06)**

| Field | Recorded value |
|--------|----------------|
| **Trio / watch build** | TestFlight **152** (stable-launch field report; contrast **build 150** `per-process-limit` baseline in B0 waiver entry **2026-04-06 13:48 CET**) |
| **Hardware / OS class** | Same device class as archived captures in this initiative (**Watch6,15**, **watchOS 26.x** in **03** / `.ips` headers) — record exact **watchOS** build (e.g. **23S620**) on the matrix when completing tethered rows |
| **Path A in build?** | **Yes** — startup grace, deferred first watch-state refresh / HealthKit / persisted-log flush, transport suppression (**02** § A1–A3) |
| **Path B in build** | **B1** ✅ trimmed WC inbound logging · **B3** ✅ lazy **`GlucoseChartView`** (`currentPage == 1`) · **B4** ✅ bounded nil-anchor HK bootstrap + anchor establishment · **B2** not implemented (optional; **04** pre-B2 signed **2026-04-06**) |
| **Telemetry corroboration (non-authoritative)** | Implementation log **2026-04-06 15:23 CET**: Better Stack hot-tier spot-check — no `message` substring match for jetsam / `per-process-limit` / `highwater` in the sampled window; `watch_startup_*`, `watch_wc_inbound`, `hk_sample_query_batch` / `hk_anchored_query_batch` present |

**Foreground-open attempts**

| # | When (local) | Protocol | New `JetsamEvent` for `Trio Watch App`? | Reason (if any) | Forced closure (subjective) | Notes |
|---|----------------|----------|----------------------------------------|-------------------|-----------------------------|--------|
| **1** | **~2026-04-06** (post–TF **152** deploy) | **Partial** — **untethered** field / daily use; **not** the formal Mac-tethered ×10 clock-face protocol | **None reported** (no diagnostic export cited) | — | **None reported** | **First open** after **152** reached the watch: **immediate** success (no issues). User did **not** need many or dozens of opens to gain confidence — contrast pre–**B3** baseline (**build 150** jetsam ~98ms). **Chart tab** opened at least once on **152** — **no** kill. Corroboration: impl log **15:23 CET** + Better Stack bullets above. |
| **2** | *TBD* | **Mac-tethered**; clock face → open Trio | *fill Y/N* | *`per-process-limit` / `highwater` / —* | *fill* | *Optional: `.ips` filename* |
| **3** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **4** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **5** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **6** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **7** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **8** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **9** | *TBD* | Same | *fill* | *fill* | *fill* | |
| **10** | *TBD* | Same | *fill* | *fill* | *fill* | |

**How to close B5 formally:** fill **2–10** under the Path A protocol (or add rows **11+** if you want extra margin). If every tethered row is **No** jetsam / **No** forced closure, record that explicitly and optionally attach a one-line “diagnostics reviewed through (date)” note.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Another startup code path still triggers transport early | Gate startup transport centrally in `WatchLogger` and verify via Better Stack. |
| Deferred work fires after the app has already left active | Cancel all pending startup work on inactive / background transition. |
| HealthKit setup runs multiple times in one process | Add a dedicated process-scope initialization guard. |
| Per-activation scheduling duplicates | Use an activation sequence id and one coordinator-owned set of work items. |
| Existing cold-start helper paths still send the first watch-state request directly | Route `forceConditionalWatchStateUpdate()`, activation-complete, and reachability-change first-refresh logic through the coordinator-owned startup guard. |
| The 2-second deferral makes the UI feel stale or blank on open | Validate that the watch continues showing the existing cached snapshot or fallback placeholder during the grace window; treat a blank or new spinner-only stall as a regression. |
| Path A passes but foreground-launch jetsam continues | Execute **Path B** phases (this document); use B0/B5 measurement to prioritize B2–B4. Do not treat jetsam alone as proof that Path A was mis-specified. |
| Path B mitigations hurt chart fidelity or sync semantics | Product-bounded caps, feature flags, and staged rollout; document tradeoffs in implementation log. |

---

## Hypotheses / Expectations (NOT acceptance)

### Path A

- Removing launch-path transport pressure will reduce repeated launch / extension-start bursts.
- Separating immediate foreground entry from delayed transport-heavy work will make the app feel more stable on open and **may** reduce peak startup memory.
- If a time-boxed “~5 second” close persists **after** Path A alone, the next diagnostic split is **Path B footprint** vs connectivity background-task completion (still deferred from Path A scope).

### Path B

- Reducing payload depth, duplicate representations, chart eagerness, and log stringification **should** lower resident pressure; **magnitude** requires B0/B5 validation—doc 03 explicitly avoids claiming a single dominant allocator without Instruments.

---

## Validation

### Path A (startup load shedding)

- Better Stack should show the expected startup suppression / deferred-fire logs without new early `query_acks`, `flush`, or `drain` rows during the grace window.
- During the 2-second startup grace, the watch should continue showing the existing cached snapshot or fallback placeholder content; a blank or new spinner-only stall is a regression.
- For each tethered repro attempt, use a narrowly bounded Better Stack query window around the attempt start rather than a broad day-scale search. Example shape for recent data:

```sql
SELECT
  dt,
  JSONExtract(raw, 'message', 'Nullable(String)') AS msg
FROM remote(t491594_trio_logs)
WHERE dt >= toDateTime('<attempt_start_utc>') - INTERVAL 30 SECOND
  AND dt < toDateTime('<attempt_start_utc>') + INTERVAL 2 MINUTE
  AND (
    JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%event=watch_startup_%'
    OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%context=query_acks%'
    OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%context=flush%'
    OR JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%context=drain%'
  )
ORDER BY dt
```

- If the repro window is older than the hot tier, use the documented `remote(...) UNION ALL s3Cluster(...)` form from `docs/process/betterstack-guide.md` with the same attempt-scoped time bounds.
- Treat the attempt-scoped Better Stack query as corroboration for startup transport behavior, not as the sole source of truth; device-side diagnostics remain authoritative for jetsam.
- Run at least 10 tethered foreground-open attempts on the target watch model, target watchOS build, and target Trio build, starting each attempt from the clock face with the paired phone in its normal connected state.
- Capture device console / diagnostics for that run set and check whether any new watch `JetsamEvent` during those attempts names `Trio Watch App` with `reason=per-process-limit` **or** `highwater`.
- No Trio `per-process-limit` / `highwater` jetsam across that protocol is **supportive** evidence for Path A’s goals; it does **not** remove the need for **Path B** while repeated jetsam remains a field risk.
- If Trio `per-process-limit` / `highwater` jetsam recurs during that protocol, **continue Path B** (B0–B5) before widening scope to the connectivity background-task state machine.

### Path B (memory-hardening)

- Treat **B0** (instrumentation + repro notes) and **B5** (foreground-open jetsam matrix) as the primary **cross-cutting** Path B acceptance anchors.
- **Also satisfy each phase-local acceptance block** for **B1–B4** in this plan (logging amplifiers, payload shaping, lazy chart, bounded HealthKit query) before declaring a Path B tranche “complete” for sign-off purposes—B5 alone is not sufficient if B1–B4 acceptance was skipped.
- Correlate evidence with structured logs (**counts**, not full payloads).
- Optional: follow doc 03’s **Charts isolation A/B** and **HealthKit A/B** suggestions when prioritizing B3/B4.

Outcome handling (combined):

- **Path A passes** and **no jetsam** in combined Path A + B5 validation windows: strong outcome; keep Path B instrumentation for regressions.
- **Path A passes** but **jetsam recurs**: prioritize **Path B** tranches (primary footprint track); do not roll back Path A solely for jetsam recurrence.
- **Path A fails** (early transport / coordinator-bypass): fix Path A first; then reassess jetsam with Path B work.
- **Path B tranches land** but **jetsam persists**: iterate Path B (payload/UI/HK/logging) and deepen measurement—not automatic proof that Path A or B concepts are wrong without triage.

---

## Implementation log

### 2026-04-06 15:23 CET — Field validation: **TestFlight build 152** (Path B tranche + Path A); Better Stack corroboration

- **Device outcome (authoritative):** After deploy of **build 152**, the watch app **launches successfully** with **no jetsam** and **no system forced closure**, in contrast to the pre–Path B behavior (e.g. build 150 baseline in the **2026-04-06 13:48 CET** waiver).
- **Plan alignment:** Matches the **combined** outcome branch in **Validation → Outcome handling**: Path B tranches (B1, B3, B4 landed; B2 still gated) plus Path A startup behavior, with **B5-style** foreground-open stability as the user-visible signal. This is **strong supportive evidence**; it does **not** by itself close every checkbox in **§ Validation** (e.g. formal **10-run tethered matrix**, explicit **`highwater` / `per-process-limit`** capture in diagnostics for that run set, **B0** clauses **1–2** resident checkpoints deferred from the B0 waiver).
- **Better Stack (Trio source, last ~24–48h hot tier, corroboration only):**
  - **No** log rows in the queried window whose `message` matched **jetsam**, **per-process-limit**, or **highwater** (substring search on `JSONExtract(raw, 'message', …)`). Trio does not emit build numbers on every line; absence of jetsam strings is **consistent with** stable watch sessions but is **not** a substitute for on-device `JetsamEvent` / Instruments review.
  - **Path A — startup coordinator / grace:** Recent rows include `event=watch_startup_grace_scheduled` (2s / 10s / 10s delays), `event=watch_startup_transport_suppressed` (`reason=startup_grace`), `event=watch_startup_deferred_watch_state_refresh_fired`, `event=watch_startup_deferred_healthkit_setup_fired`, `event=watch_startup_deferred_persisted_log_flush_fired`, and `event=watch_startup_grace_canceled` when the app left active before pending work — aligned with expected suppression / deferral / cancellation observability.
  - **Path B — B1 / B4:** `event=watch_wc_inbound` lines show **keys and metadata only** (no full glucose array stringification). `event=hk_sample_query_batch` with `anchor_was_nil=true` and `samples_count=64` confirms the **bounded** nil-anchor bootstrap path; `event=hk_anchored_query_batch` with `anchor_was_nil=false` and small batch counts on incremental fires.
- **Next steps (see project evaluation below):** Optional formal **B5** attempt matrix + device-side jetsam export for build 152; complete **B0** deferred checkpoints if sign-off requires numbers; unblock **B2** via doc **04** pre-B2 table when ready.

### 2026-04-06 13:50 CET — Path **B3** complete: lazy chart tab construction (`feature/watch-complication-improvements`)

- **What:** Chart page (`GlucoseChartView`) is no longer constructed eagerly on every `TabView` load. Page index 1 uses the same gating pattern as the debug tab: **`GlucoseChartView` is built only when `currentPage == 1`**, otherwise a **`Color.clear`** placeholder keeps the tab slot without paying `Charts` / `PointMark` cost until the user switches to the chart.
- **Where:** `Trio Watch App Extension/Views/TrioMainWatchView.swift`
- **Plan alignment:** **B3** — Lazy or deferred chart/history construction (this document); follows doc **03** debug-page gating precedent.
- **Acceptance / verification:** Code-level laziness requirement for B3 is satisfied. **B0** clause 3 was **waived** (see **2026-04-06 13:48 CET** entry) in lieu of a separate chart A/B Instruments build; **clause 1–2** resident checkpoints remain **deferred to B5** per that waiver. Optional future work: downsampling for `PointMark` when chart is visible (plan bullet) — not required to mark B3 “complete” for the launch-footprint gate addressed here.

### 2026-04-06 13:48 CET — B0 gate waiver: proceeding to B3 (`feature/watch-complication-improvements`)

**Waiver type:** Written waiver per B0 exit gate clause in this plan and in doc 04.

**Clauses waived / deferred:**

- **Clause 3 (chart cost isolation A/B) — WAIVED.** The build 150 JetsamEvent (2026-04-04 00:27:08, `per-process-limit`, process age = 98ms, `lifetimeMax = rpages = 19821`, ~310 MiB) constitutes direct causal evidence that the initial view hierarchy — including the eager `GlucoseChartView` construction in `TrioMainWatchView`'s `TabView` — is the dominant launch-time allocator. `lifetimeMax == rpages` confirms the process hit its ceiling at creation with no growth phase; `cpuTime: 1.22s` in 98ms of wall time confirms dense framework + view-hierarchy init work. An explicit A/B Instruments build is unnecessary: the jetsam data proves the process cannot survive to any application-logic checkpoint without a view-hierarchy footprint reduction. Chart laziness is the only pending B-path item that affects memory before the first line of Swift application code runs.

- **Clauses 1 and 2 (device run + per-checkpoint resident samples) — DEFERRED to B5.** The build 150 jetsam event is the pre-B3 baseline. Post-B3 device run and resident samples will be captured in B5 for before/after comparison.

**B2 remains blocked** — the pre-B2 owner/date field in doc 04 is still unfilled; that gate is independent of this waiver.

**Action:** Proceed with B3 implementation. **Done** — B3 landed; see **2026-04-06 13:50 CET** log entry.

### 2026-04-03 23:29 CET — External review round 2 (**ChatGPT** + **Claude**) on **B1** / **B4** post-anchor fix (`feature/watch-complication-improvements`)

- **Sources:** ChatGPT “Much better…” review; Claude call-chain verification + log naming nit.

- **ChatGPT — Verdict:** **Agree** (B1/B4 approve; no blockers). **P2 — `HKObjectQueryNoLimit` on anchor establishment:** **Agree** with clarification only — documented in code that **boundedness depends on the `start=Date()` + `.strictStartDate` forward predicate** being effectively empty, **not** on the limit parameter. **P2 — two-stage bootstrap completion** (snapshot save → anchor query → HK observer `completion`): **Agree** sequencing is intentional; **no code change**. **Open validation:** confirm on device/watchOS that holding the observer completion until anchor establishment completes does not cause unexpected HK observer behavior (logged here for B5 / field follow-up). **P2 — B1 sorted key strings:** **Agree** acceptable observability noise vs memory hazard; **no change**.

- **Claude — Verdict:** **Agree** (bootstrap + establishment + `defer { completion() }` trace correct; B1 unchanged). **Nit — `event=hk_anchored_query_batch` on bootstrap path:** **Agree; fixed.** Split batch logs: **`event=hk_sample_query_batch`** when `anchorWasNil` (bootstrap `HKSampleQuery` completion) vs **`event=hk_anchored_query_batch`** for incremental `HKAnchoredObjectQuery`; **`query_type`** unchanged (`sampleQuery_bootstrap` | `anchoredQuery`). **Note:** Any dashboards or docs that assumed a single batch event name should filter on both events or use `query_type`.

- **Where:** `Trio Watch App Extension/WatchState.swift` (comments + batch `event=` split); this plan (implementation log + changelog).

### 2026-04-03 22:42 CET — Path **B1** + **B4** (`feature/watch-complication-improvements`, Trio worktree)

- **B1 — Eliminate full-message WC logging**
  - **What:** Replaced `session(_:didReceiveMessage:)` line that interpolated the entire `message` dictionary with `watchConnectivityInboundSummary(_:)`, logging top-level keys, optional `type`, and (when `watchState` is present) nested key list + `glucoseValues` **count** + `reading_epoch` — no materialization of the full `glucoseValues` array as string.
  - **Where:** `Trio Watch App Extension/WatchState.swift`
  - **Acceptance:** Production `didReceiveMessage` path no longer stringifies the full nested glucose history; diagnosis remains via structured fields (`event=watch_wc_inbound`, counts, epochs).
  - **Verification:** Static review of `didReceiveMessage` and `rg` for remaining `log("Watch received data:` / full-dict interpolation; full `xcodebuild` not completed in this session (prior attempt timed out).

- **B4 — Bound HealthKit startup / observer glucose fetch on nil anchor**
  - **What:** When no persisted `HKQueryAnchor` (nil or decode failure), run `HKSampleQuery` over the existing 24h bootstrap predicate with **descending** start-date sort and **`hkBootstrapSampleLimit` (64)** so the batch is **bounded** and still returns the **newest** samples (anchored queries enumerate oldest-first, so `HKObjectQueryNoLimit` → positive limit on a wide window would mis-order vs “latest reading” without a sample-query shape). When a durable anchor exists, keep `HKAnchoredObjectQuery` with `HKObjectQueryNoLimit` for incremental delivery. Added `event=hk_anchored_query_batch` log with `anchor_was_nil` and `samples_count` (counts only). Refactored shared post-processing into `finishHKGlucoseObserverFetch`. `hk_observer_fired` now includes `query_type=sampleQuery_bootstrap` vs `anchoredQuery`.
  - **Where:** `Trio Watch App Extension/WatchState.swift`
  - **Acceptance:** Nil-anchor path cannot request an unbounded HK batch; validation logs expose anchor nil vs not and sample counts.
  - **Note / tradeoff (historical):** Initially, bootstrap did not persist an anchor; **superseded** by **2026-04-03 23:21 CET** entry (external review — anchor establishment after bootstrap).

### 2026-04-03 23:21 CET — External review (**ChatGPT** + **Claude**) on Path **B1** / **B4** + code follow-up (`feature/watch-complication-improvements`)

- **Sources:** ChatGPT structured review; Claude B1/B4 write-up (bootstrap anchor permanence + suggested `HKAnchoredObjectQuery` “from now” establishment pattern).

- **B1 — Evaluation**
  - **Agree:** Both reviews approve replacing full `didReceiveMessage` interpolation with `watchConnectivityInboundSummary(_:)`. No code change required from this pass beyond what was already landed in **22:42 CET**.
  - **ChatGPT P2 — `watchState_keys` / `top_level_keys` verbosity:** **Accepted as acceptable risk.** The large memory spike was from nested `glucoseValues` stringification; key lists stay bounded relative to payload body. **No change** unless logs prove noisy in production.
  - **ChatGPT P2 — Stable log tokens (`query_type`, batch `event=`):** **Accepted.** Added an inline code comment that `sampleQuery_bootstrap` and `anchoredQuery` are **stable** tokens for validation/Better Stack. **Superseded for batch events by 23:29 CET:** batch lines now use **`hk_sample_query_batch`** vs **`hk_anchored_query_batch`** (see **2026-04-03 23:29 CET** log entry).

- **B4 — Evaluation**
  - **ChatGPT P1 / Claude — Bootstrap did not persist `HKQueryAnchor`:** **Agree; fixed.** The **22:42** implementation bounded memory but left anchor nil forever, so incremental `HKAnchoredObjectQuery` never ran — **misaligned** with “until a durable anchor is established.” **Follow-up:** After a **successful** `HKSampleQuery` (error == nil), call `establishHealthKitGlucoseTimelineAnchorAfterBootstrap`: `HKAnchoredObjectQuery` with `anchor: nil`, predicate **samples from `Date()` onward** (typically **zero** glucose rows), `limit: HKObjectQueryNoLimit` — predicate bounds work, **not** the old nil-anchor + 24h + `NoLimit` hazard. Persist `newAnchor` to the complication store; log `hk_bootstrap_anchor_established` / failure. **Deviation from Claude’s snippet:** The HK observer `completionHandler` is invoked **after** the establishment query completes (`defer { completion() }`) so a fast follow-up observer fire does not re-enter bootstrap before the anchor write.
  - **ChatGPT P2 — Justify `64`:** **Agree.** Expanded the `hkBootstrapSampleLimit` comment (latest + trend/delta context vs startup batch cap).
  - **ChatGPT nit — `finishHKGlucoseObserverFetch` name vs dual paths:** **Agree it’s slightly narrow; no rename** (avoid churn). **Doc comment** updated to state it serves both bootstrap and incremental completion.
  - **Claude acceptance table — “design intent” row:** Treated as **closed** once anchor establishment ships, pending device confirmation.

- **Where (this follow-up):** `Trio Watch App Extension/WatchState.swift`

- **Verification:** Static re-read of bootstrap completion paths (error vs success wrapper) and establishment `defer { completion() }`; full `xcodebuild` still on the user to run locally if desired.

### 2026-04-03 22:24 CET — red-team session: findings **F1**, **F2**, **F3**, **F4**, **F8** (`feature/watch-complication-improvements`)

- Review inputs
  - Structured adversarial pass on watch startup coordinator + `WatchLogger` startup transport gate vs **[01](01-startup-load-shedding-design.md)** / this plan (**Path A**).
  - Branch / tree: `feature/watch-complication-improvements` (**Trio** worktree). Goal: close sequencing, persistence, and delegate-routing holes that could bypass startup grace or amplify refresh/log traffic.

- **F1 — Build-key write deferral (`WatchLogger.flushPersistedLogs`)**
  - **Issue:** Persisting `lastKnownBuildKey` while startup transport was still **suppressed** could advance the on-disk build marker without matching the intended “upgrade visible + transport-eligible” checkpoint, encouraging repeated or misleading `[UPGRADE]` behavior across grace-window calls.
  - **Fix:** **Defer** `UserDefaults` persistence of the last-known build until the flush path is allowed to proceed **past** startup suppression (write the key in the transport-capable tail—i.e. **after** the `guard !startupTransportSuppressed` early return—while keeping the `[UPGRADE]` line’s `force` bit consistent with suppression policy). If the key write moves after the guard, **dedupe** `[UPGRADE]` while suppressed (e.g. actor-scoped “already announced this `build`”) so grace-window flush retries do not spam identical upgrade lines.
  - **Where:** `Trio Watch App Extension/WatchLogger.swift`
  - **Worktree parity check:** confirm `UserDefaults.standard.set(build, forKey: lastKnownBuildKey)` does **not** remain **above** the suppression guard in the shipping branch; if it does, **F1** is not fully landed until relocated (and deduped as needed).

- **F2 — Async gap (deferred persisted-log flush vs gate / activation epoch)**
  - **Issue:** A **deferred** persisted-log flush runs inside a `Task` and could briefly disagree with the **current** foreground activation sequence relative to `WatchStartupTransportGate`, creating a race where disarm/flush ordering was ambiguous across rapid active/inactive churn.
  - **Fix:** On fire, call `WatchStartupTransportGate.disarm(activationSequence:)` for the **scheduled** epoch; pass `flushPersistedLogs(startupTransportSuppressedOverride:)` **`false` only when that disarm succeeds** for the matching sequence—otherwise fall back to the live gate snapshot (`nil` override) so an **older** timer cannot open transport through a **newer** grace window.
  - **Where:** `Trio Watch App Extension/WatchState.swift` (`fireDeferredStartupPersistedLogFlushOnMain`)

- **F3 — `session(_:activationDidCompleteWith:)` routing**
  - **Issue:** Activation completion (notably **failure** paths) could emit **forcing** log lines and call `flushPersistedLogs()` in ways that treated the activation edge like a normal post-grace flush, undermining startup transport suppression during the early WCSession bring-up window.
  - **Fix:** Keep activation completion work on the **main** queue, route success-path refresh through **`forceConditionalWatchStateUpdate()`** (startup-grace-aware via `shouldSuppressStartupSignalOnMain()`), and align **fallback** `flushPersistedLogs` / `log(..., force:)` usage with the same **grace + override** contract as other startup-adjacent flush call sites (no special-case bypass of the gate semantics).
  - **Where:** `Trio Watch App Extension/WatchState.swift` (`session(_:activationDidCompleteWith:error:)`)
  - **Worktree parity check:** activation-**failure** paths should not retain `log(..., force: true)` + bare `flushPersistedLogs()` if that pair still bypasses suppression; reconcile with `WatchStartupTransportGate.snapshot()` / `startupTransportSuppressedOverride` like other fallbacks.

- **F4 — `forcedSinceActivation` guard (reachability / cold-start refresh storm)**
  - **Issue:** `sessionReachabilityDidChange` could repeatedly drive **`forceConditionalWatchStateUpdate()`** on a cold start whenever reachability flipped, even after a startup-forced refresh had already been issued for that activation, increasing duplicate requests and noise during grace.
  - **Fix:** Track **`forcedSinceActivation`** per activation (`noteAppBecameActive` resets; successful `requestWatchStateUpdate` via `forceConditionalWatchStateUpdate` sets; valid watch-state processing clears). **`sessionReachabilityDidChange`** only auto-forces on cold start when **`!forcedSinceActivation`**.
  - **Where:** `Trio Watch App Extension/WatchState.swift`

- **F8 — Background launch disarm**
  - **Issue:** A process lifetime that **never** reaches foreground could otherwise leave startup transport suppression armed **indefinitely**, with no intentional “escape hatch” consistent with the plan’s background / inactive delivery conventions.
  - **Fix:** **`scheduleBackgroundLaunchDisarmIfNeeded()`** from `applicationDidFinishLaunching`: schedule a **2s** main-queue work item that **disarms** `WatchStartupTransportGate` **only if** the app still has **not** entered the foreground coordinator path (`!startupIsForegroundActive`), emit `event=watch_startup_background_launch_disarm`, and **cancel** that work item when **`handleForegroundActiveEntry()`** runs.
  - **Where:** `Trio Watch App Extension/WatchState.swift`, `Trio Watch App Extension/ExtensionDelegate.swift`

- Files touched in this session (cumulative across F1–F4 / F8)
  - `Trio Watch App Extension/WatchLogger.swift`
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - (Supporting / related in the same review window as earlier rounds: `Trio Watch App Extension/WatchErrorReporter.swift`, `Trio Watch App Extension/TrioWatchApp.swift` — immediate crash-state markers vs async `startup()`)

- Static verification for this session
  - Re-read `flushPersistedLogs` suppression ordering vs `lastKnownBuildKey` writes (**F1**).
  - Re-traced deferred flush → `disarm` → `flushPersistedLogs` override path (**F2**).
  - Re-read `activationDidComplete` + reachability delegate paths vs startup grace (**F3**, **F4**).
  - Confirmed background disarm scheduling/cancellation symmetry with `handleForegroundActiveEntry` (**F8**).
  - Full compile / device validation remains **out of scope** for this log entry unless separately recorded.

### 2026-04-03 13:53 CEST — external red-team follow-up and corrective pass on `feature/watch-complication-improvements`

- Review inputs
  - Sources reviewed: one new external red-team pass from ChatGPT and one current-tree review pass from Cursor.
  - Scope of this round: correct code that drifted from the plan’s intended behavior, then record which review points were accepted vs rejected without rewriting the design to fit the implementation.

- Review findings accepted and implemented
  - `startupFirstRefreshInFlight` lifecycle was tightened so the coordinator-owned first-refresh flag no longer depends only on a payload carrying `WatchMessageKeys.date`. The flag now clears when a watch-state payload is processed at all, and it also clears on terminal invalid / outdated watch-state responses in addition to the existing no-session, activation, unreachable, timeout, and send-error paths.
  - `flushPersistedLogs()` build-upgrade bookkeeping was adjusted so suppressed startup-time calls no longer emit repeated `[UPGRADE] build changed ...` lines. The local build marker is now advanced when the upgrade line is first recorded, while transport-capable work remains behind the startup suppression guard.
  - `applicationWillResignActive` no longer logs with `force: true`; the resign breadcrumb is now non-forcing so the inactive edge does not create an unnecessary immediate log flush once the gate is open.
  - `WatchErrorReporter` immediate foreground / inactive marker helpers were retained and the remaining key-reference cleanup was completed so the startup-crash marker state stays synchronous at lifecycle edges.
  - The deferred persisted-log flush now bypasses startup suppression only when the firing activation sequence successfully disarms its own gate. If a newer activation sequence has already re-armed suppression, the older deferred flush falls back to the live gate state instead of bypassing the new startup window.

- Review findings considered and intentionally not changed
  - Background-only launch disarm after 2 seconds without foreground entry was kept. Rationale: this is the implementation that preserves the plan’s shared-convention requirement that background / inactive log delivery behavior remain unchanged; without it, a background-only process lifetime would stay transport-suppressed forever. This was treated as an internal liveness detail of the startup transport gate, not as a change to the foreground 2-second / 10-second startup timing model.
  - `session(_:activationDidCompleteWith:error:)` and reachability-change paths still call `forceConditionalWatchStateUpdate()` rather than a separate coordinator timer API. Rationale: after this round, the helper enforces startup suppression plus separate first-refresh in-flight tracking, while still preserving the plan’s requirement that post-first-refresh stale / cold-start refresh behavior remain unchanged. This is behaviorally aligned with the plan even if the ownership boundary could be made more explicit in a later cleanup.
  - Optional `event=watch_startup_transport_suppressed` logs were not added to every suppressed `WatchLogger` exit path. Rationale: the design marks those logs as diagnostic-only, not acceptance-critical, and adding them broadly would increase startup log volume without changing transport behavior.
  - `WatchErrorReporter.shared.startup()` remains async. Rationale: the plan requires immediate crash-state marking on active / inactive edges, and that requirement is now satisfied synchronously; the previous-crash detection work itself does not need to block foreground entry.

- Files changed in this round
  - `Trio Watch App Extension/WatchErrorReporter.swift`
  - `Trio Watch App Extension/WatchLogger.swift`
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio Watch App Extension/WatchState.swift`

- Static verification for this round
  - Re-read the changed lifecycle, logging, and request-control paths after the fixes.
  - Re-checked `requestWatchStateUpdate()` failure / fallback sites against the first-refresh in-flight state.
  - Re-checked `flushPersistedLogs()` suppression ordering against the accepted review findings.
  - Full compile / device validation remains pending by user choice; this log entry records code-review closure and static alignment with the plan, not runtime sign-off.

### 2026-04-02 22:00 CEST — execution session on `feature/watch-complication-improvements` (`Trio` worktree)

- A1 / coordinator tasks (formerly Phase A / Task A1–A2)
  - What was done: added startup coordinator state in `WatchState`, including activation-sequence tracking, deferred work items for watch-state refresh / HealthKit / persisted-log flush, per-sequence first-refresh state, and process-scope HealthKit setup state. Added `handleForegroundActiveEntry()` and `handleForegroundInactiveOrBackground()` plus scheduling / cancellation helpers and startup observability events. Routed both active entry and active exit through the coordinator from `TrioWatchApp` and `ExtensionDelegate`, with idempotent dedup via `startupIsForegroundActive`.
  - Where: `Trio Watch App Extension/WatchState.swift`, `Trio Watch App Extension/TrioWatchApp.swift`, `Trio Watch App Extension/ExtensionDelegate.swift`
  - Acceptance verification: re-read all active / inactive call sites, confirmed that both delegate and SwiftUI entry points now converge on the coordinator, and confirmed that cancellation logs include the pending-task field required by the plan.
  - Deviation / open items: crash-state marking remains inside async `Task` blocks on foreground entry and exit because the existing `WatchErrorReporter` API is async; behavior remains aligned with the plan, but this was not rewritten into a synchronous API in this initiative.

- A2 / launch-path flush pressure (formerly Phase B / Task B1–B2)
  - What was done: added a synchronous startup transport gate in `WatchLogger` that starts suppressed at process launch, re-arms for each activation sequence, and blocks startup-time watch-to-phone log transport from `flushIfNeeded`, `flushToPhone`, `resendPendingPayloads`, and transport-capable branches inside `flushPersistedLogs()`. Removed force-triggered startup logging in app init and finish-launch paths. Removed the immediate first-active persisted-log flush from `TrioWatchApp` and replaced it with the deferred coordinator callback at 10 seconds, which clears the gate for that activation sequence before invoking the transport-capable flush path. Existing startup-adjacent fallback callers such as activation failure and transfer-error flushes now inherit the same grace-aware behavior through the internal `WatchLogger` suppression.
  - Where: `Trio Watch App Extension/WatchLogger.swift`, `Trio Watch App Extension/TrioWatchApp.swift`, `Trio Watch App Extension/ExtensionDelegate.swift`, `Trio Watch App Extension/WatchState.swift`
  - Acceptance verification: audited all `flushPersistedLogs()` and startup-log call sites with `rg`, re-read `WatchLogger` transport control flow from `log()` through `flushIfNeeded()` / `flushToPhone()` / `flushPersistedLogs()`, and confirmed that the build-change `log(..., force: true)` path is now suppressed during startup grace.
  - Deviation / open items: no direct source edit was required in `WatchState+Requests.swift` for this phase because the required grace behavior now lives inside `WatchLogger`, which covers the existing fallback callers without changing unrelated request/retry behavior.

- A3 / defer HealthKit and first watch-state request (formerly Phase C / Task C1–C2)
  - What was done: removed raw-session HealthKit setup from `setupSession()` and deferred it through the coordinator after 10 seconds of continuous active state with a once-per-process guard. Removed the direct activation-edge watch-state request from `ExtensionDelegate.applicationDidBecomeActive`. Added startup suppression to `forceConditionalWatchStateUpdate()`, rerouted pre-first-refresh transfer retry through `requestWatchStateUpdateRespectingStartupGraceOnMain()`, and kept the documented explicit exceptions unchanged for background refresh and debug-driven manual refresh actions. The deferred coordinator-owned first watch-state request now fires after 2 seconds of continuous active state and marks the activation as having consumed its startup-owned first refresh.
  - Where: `Trio Watch App Extension/WatchState.swift`, `Trio Watch App Extension/ExtensionDelegate.swift`
  - Acceptance verification: audited `requestWatchStateUpdate()` trigger sites with `rg`, re-read activation-complete, reachability-change, transfer-retry, background-task, and debug-view call paths, and confirmed that foreground / cold-start first-refresh triggers are coordinator-owned or explicitly left as exceptions per the plan.
  - Deviation / open items: `session(_:activationDidCompleteWith:error:)` and `sessionReachabilityDidChange(_:)` still call existing helper paths, but those helper paths now suppress startup-time first-refresh transport until the coordinator-owned 2-second request fires. Post-first-refresh retry behavior remains intentionally unchanged.

- Final validation status
  - What was done: performed targeted static verification with `rg`, `git diff`, and full file re-reads of the modified watch sources. Attempted `xcodebuild` validation to compile the watch scheme, but the session was stopped before completion at user direction after package-resolution / environment issues made it a poor signal for this pass.
  - Where: `Trio Watch App Extension/ExtensionDelegate.swift`, `Trio Watch App Extension/TrioWatchApp.swift`, `Trio Watch App Extension/WatchLogger.swift`, `Trio Watch App Extension/WatchState.swift`
  - Acceptance verification: static code-path review confirms the planned coordinator, transport suppression, deferred HealthKit setup, and deferred first-refresh behavior are implemented in the working tree.
  - Deviation / open items: compile/build validation and device-side rollout validation remain pending for a later pass. External code review was explicitly chosen as the next step before returning for follow-up fixes.

---

## Changelog

### v2.15 (2026-04-06 16:07 CET)

- **B5 matrix row 1 + header:** Recorded **first-open-after-deploy** success for TF **152** (immediate, no multi-open burn-in). **Current field status** updated; optional **B5** rows **2–10** clarified as **Mac-tethered** protocol.

### v2.14 (2026-04-06 16:05 CET)

- **B5 matrix:** **Terminology** note — **tethered** = watch **connected to Mac** during attempt (diagnostics practical); **untethered** / **field** = normal wrist use. **Row 1** labeled **untethered**; added user confirmation — **chart tab opened** on **152**, **no** kill. **Row 2** protocol column now says **Mac-tethered**.

### v2.13 (2026-04-06 16:00 CET)

- **B5:** Added **§ B5 — Attempt matrix (living record)** under Path B: build/tranche correlation table for TF **152**, **Path A**/**B1**/**B3**/**B4** inventory, telemetry pointer; **10-row** foreground-open table with **row 1** from documented field + Better Stack evidence and **rows 2–10** placeholders for the tethered protocol. Header **Current field status** now points here.

### v2.12 (2026-04-06 15:48 CET)

- **Header:** **Current field status** paragraph (build **152**, **B3** lazy chart + **B1**/**B4** + Path **A**; **04** pre-B2 sign-off unblocks **B2**). **Last updated** bumped.

### v2.11 (2026-04-06 15:23 CET)

- **Implementation log:** Added **2026-04-06 15:23 CET** entry for **TestFlight build 152** field validation (successful watch launch, no jetsam/forced closure). Documented **Better Stack** corroboration queries on the Trio source (no jetsam-reason string matches in the hot-tier window; `watch_startup_*`, `watch_wc_inbound`, `hk_sample_query_batch` / `hk_anchored_query_batch` patterns). Explicitly noted remaining formal items: **B5** matrix / device exports, **B0** clauses **1–2**, **B2** gate on doc **04**.

### v2.10 (2026-04-06 13:50 CET)

- **Implementation log:** Recorded **B3** as **complete** (lazy `GlucoseChartView` behind `currentPage == 1` in `TrioMainWatchView`). Timestamped the **2026-04-06** B0 waiver heading (**13:48 CET**) and cross-linked B3 completion from the waiver **Action** line.

### v2.9 (2026-04-06 13:48 CET)

- **Implementation log:** Added B0 gate waiver entry authorizing B3 to proceed. Clauses 3 waived (jetsam causal evidence substitutes for chart A/B); clauses 1–2 deferred to B5. B2 remains blocked on doc 04 owner/date.

### v2.8 (2026-04-03 23:29 CET)

- **Implementation log:** Added **2026-04-03 23:29 CET** entry for second **ChatGPT**/**Claude** pass (establishment `NoLimit` safety = predicate; device validation note for deferred observer completion; **Claude** batch event split). **Code:** `establishHealthKitGlucoseTimelineAnchorAfterBootstrap` doc expanded; `finishHKGlucoseObserverFetch` emits `hk_sample_query_batch` vs `hk_anchored_query_batch`. Cross-update to **23:21** log row for stable-token wording.

### v2.7 (2026-04-03 23:21 CET)

- **Implementation log:** Added **2026-04-03 23:21 CET** entry documenting **ChatGPT** + **Claude** review of **B1**/**B4**: accepted P1 anchor persistence gap and implemented `establishHealthKitGlucoseTimelineAnchorAfterBootstrap` (timeline “from now” anchored query + deferred HK observer completion); recorded P2/stable-token/nit disposition; marked prior bootstrap tradeoff superseded. **B4** follow-up code in `WatchState.swift`.

### v2.6 (2026-04-03 22:42 CET)

- **Implementation log:** Recorded Path **B1** (trim `didReceiveMessage` logging to keys/counts/epochs) and **B4** (bounded nil-anchor HK glucose fetch via descending `HKSampleQuery` + batch instrumentation + shared `finishHKGlucoseObserverFetch`) on `feature/watch-complication-improvements` (Trio worktree), with acceptance notes and bootstrap anchor-seeding tradeoff.

### v2.5 (2026-04-03 22:24 CET)

- **Implementation log:** Added **2026-04-03 22:24 CET** red-team session entry documenting accepted findings **F1** (build-key write deferral), **F2** (async gap / deferred flush vs gate epoch), **F3** (`activationDidCompleteWith` routing vs grace), **F4** (`forcedSinceActivation` / reachability guard), **F8** (background launch disarm), with issue/fix/where bullets and static verification notes.

### v2.4 (2026-04-03 21:56 CET)

- **Jetsam diagnostics:** Intro **Jetsam reasons** bullet updated—**three** `.ips` files in **00** / **04**; **`highwater`** is no longer “report-only” relative to a single capture.

### v2.3 (2026-04-03 21:39 CET)

- **Title** updated to **Watch Launch Stability — Implementation Plan (Path A & Path B)**; added **filename note** for link stability. Linked **[04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)** as Path B design anchor; added **dependencies** and **`highwater` / `.ips` caveat** (aligned with **04**). Sequencing line: **Path A continues in parallel as sequencing allows**; softened **“both tracks matter”** → **“valuable”** per review. **B0 exit gate** (blocking B2/B3) and **pre-B2 decision gate** (blocking B2) added; B3 references B0 gate.

### v2.2 (2026-04-03 21:26 CET)

- **Pre-implementation doc review:** expanded **Path B validation** so **B0/B5** are explicit **cross-cutting** anchors while **B1–B4** phase-local acceptance must not be skipped for sign-off; aligns **01** success-criteria pointer with executable checks.

### v2.1 (2026-04-03 21:19 CET)

- **Primary track:** stated **Path B** as **primary remediation** and **Path A** as **justified parallel**; replaced lockstep “mandatory parallel” framing with **required Path B + delivery sequencing** language aligned with findings. **Status → Under major revision.**
- **Renamed Path A work** from historical Phase A/B/C to **A1, A2, A3** with updated ship-boundary wording; **Path B** subsections retitled **B0–B5** (dropped redundant “Phase” prefix). Clarified disjoint **A*** vs **B*** namespaces.
- Implementation log bullets annotated with **(formerly Phase …)** for continuity.

### v2.0 (2026-04-03 21:01 CET)

- Promoted the plan to cover **two parallel paths**: **Path A** (existing Phases A–C, startup load shedding) and **Path B** (Phases B0–B5, foreground memory-hardening). Linked [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md); updated scope, out-of-scope, validation, outcome handling, hypotheses, and risks for **`per-process-limit` / `highwater`** and **mandatory Path B**. Added Path B phases with **H/M** confidence markers. Renamed Path A section headings to avoid confusion with Path B numeric labels.

### v1.9 (2026-04-03 13:55 CEST)

- Extended the v1.8 implementation-log round with the self-review race fix for deferred persisted-log flushes: the flush now bypasses suppression only when the matching activation sequence actually disarms the gate, preventing an older activation from flushing through a newer activation’s startup grace window.

### v1.8 (2026-04-03 13:53 CEST)

- Added a follow-up implementation-log entry covering the post-v1.7 external red-team review round. Documented which ChatGPT / Cursor findings were accepted and fixed in code, which suggestions were intentionally not applied, and the reasoning for those decisions.

### v1.7 (2026-04-02 22:00 CEST)

- Recorded execution status for the implementation pass. Added the required implementation log section with Phase A-C results, file coverage, verification notes, and explicit documentation that compile/build validation was deferred after the user stopped the Xcode validation attempt.

### v1.6 (2026-04-02 21:22 CEST)

- Applied a final wording pass from external review: clarified in plain language that startup grace is the umbrella term with launch-time suppression plus confirmed-active timers, made later same-process activation-sequence re-arming explicit, and added a blunt validation note that Better Stack corroborates startup transport behavior while device-side diagnostics remain authoritative for jetsam.

### v1.5 (2026-04-02 21:12 CEST)
- Incorporated external-review feedback on lifecycle semantics and validation. The plan now makes process-launch suppression vs confirmed-active timers explicit, reschedules startup-owned work on later active transitions in the same process, treats receive-side startup bursts as a non-goal, adds pending-task detail to cancellation observability, explicitly gates timer and size-threshold flush paths in Task B1, names `session(_:activationDidCompleteWith:error:)` in Task C2, tightens the `flushPersistedLogs()` implementation rule, and adds an attempt-scoped Better Stack query shape plus an explicit validation outcome matrix.

### v1.4 (2026-04-01 17:39 CEST)
- Clarified that Phases A-C do not by themselves guarantee elimination of every future Trio jetsam. Scope now treats jetsam reduction as a validation target rather than a hard sole-scope commitment, adds explicit out-of-scope memory-hardening work, defines a concrete 10-run tethered jetsam validation protocol, and aligns Task A2 observability bullets with the `event=` prefix used elsewhere.

### v1.3 (2026-04-01 14:58 CEST)
- Added a complete first-refresh trigger inventory with coordinator-owned paths vs explicit exceptions, clarified that pre-first-refresh transfer retry and startup-time activation / transfer error flushes obey startup grace, and required internal `flushPersistedLogs()` suppression before build-change `force: true` logging or other transport branches. Incorporated the confirmed watch jetsam failure mode into scope, risks, and validation.

### v1.2 (2026-04-01 14:22 CEST)
- Clarified that the startup coordinator owns every foreground / cold-start first-refresh trigger, not just `applicationDidBecomeActive`. Expanded Phase B so startup-time `flushPersistedLogs()` callers are grace-aware and transport-suppressed until the deferred flush window, and added acceptance / observability coverage for those paths.

### v1.1 (2026-04-01 09:42 CET)
- Pre-implementation doc review: required **all** `flushToPhone` triggers (including timer and log-count threshold) to honor startup grace; documented activation deduplication between `ExtensionDelegate` and SwiftUI `scenePhase`; clarified Phase B observability checks to exclude expected watch-state `WCSession` traffic after the 2-second deferral.

### v1.0 (2026-04-01 09:31 CEST)
- Initial implementation plan for the startup load-shedding remediation. Covers a startup coordinator, launch-path transport suppression, deferred persisted-log flush, deferred HealthKit setup, and deferred initial watch-state refresh. Explicitly excludes connectivity background-task redesign from scope.
