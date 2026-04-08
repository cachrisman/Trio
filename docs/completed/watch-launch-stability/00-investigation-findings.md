# Watch Launch Stability — Investigation Findings

**Version:** v1.14
**Created:** 2026-04-01 09:31 CEST
**Last updated:** 2026-04-08 21:45 CEST
**Status:** Updated — primary foreground-launch jetsam symptom mitigated in field (TestFlight **152**+); **153+** ships **B6** field resident telemetry; **Path B** **B5** and **B0** exit gates **closed** in **02** / **04** (**2026-04-08** — implementation log **2026-04-08 21:33 CEST** / **21:45 CET**). Optional **B2** payload-shaping work remains **when prioritized** ( **04** pre-B2 signed **2026-04-06**).

Design: [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md)
Implementation plan: [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md)
Launch memory investigation: [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md)
Path B design (gates / decisions): [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)

---

## Executive Summary

Repeated, reproducible watch `JetsamEvent` diagnostics on **foreground launch/open** show **`Trio Watch App` as the largest active/frontmost process at kill**, with termination reasons that include **`per-process-limit`** and **`highwater`**. That pattern establishes **watchOS memory-budget closure** as the **primary observed mechanism** for the forced return to the clock face. It is **not** adequately explained as “only” connectivity, logging-timeout, or transport-contention noise—those factors can still **compound** resident pressure, but **jetsam is the observed closure**.

**Path B — Watch foreground memory-hardening / launch footprint reduction** is the **primary remediation track**: it directly targets **resident footprint** and **launch object-graph size** implied by that closure. A **completed code-level launch-memory investigation** ([03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md)) supplies **best-ranked memory consumers and mitigation targets** with explicit **evidence vs inference** discipline—especially: **large WatchConnectivity watch-state payload / history depth** (e.g. up to **288** glucose points from the phone in the reviewed build), **duplicate stacked in-memory representations**, **eager chart-related UI cost**, **payload-stringifying logging**, and **unbounded or oversized HealthKit startup batch risk**. Those are **investigation outputs** with graded confidence in doc 03; they are **not** a verified Instruments allocation profile and **must not** be read as naming a single proven “the root cause.”

**Path A — Startup load shedding / launch pressure reduction** remains a **justified parallel track**. It is **not** obsolete: it removes **launch-time transport and scheduling amplifiers** that **may compound** resident pressure (and matched the historical “~5s” / `WCSession` timeout narrative). Strongest **direct** evidence for Path A in the **original** investigation window remains:

- an explicit 5-second `WCSession` reply timeout added in `2e3db70f5`
- launch-path and first-active logging / flush behavior in the **baseline** watch app (pre–Path A implementation)
- Better Stack rows on 2026-04-01 showing repeated build 148 launch / extension-start events and timeout rows for `query_acks`, `flush`, and `drain`

Path A **does not** by itself cap large resident object graphs once a full watch-state payload arrives.

**Sequencing:** **Path B is now a required remediation track and should begin immediately**; **Path A should continue in parallel as sequencing allows**; **ordering between the two tracks remains a delivery decision**. The evidence supports **urgency** for Path B and **continued value** for Path A; it does **not** prove that both must ship in **lockstep**.

The connectivity background-task state machine remains a real follow-up candidate **outside** the current Path A design/plan scope and **outside** the Path B plan as initially framed in the implementation plan.

### Field validation summary (2026-04-06)

After shipping **Path B** **B3** — lazy **`GlucoseChartView`** construction (chart page built only when the user selects that **`TabView`** page) — together with **Path A** startup load shedding and **Path B** **B1** / **B4** (trimmed WC inbound logging; bounded nil-anchor HealthKit bootstrap and anchor establishment), **TestFlight build 152** is reported to **launch and stay in the foreground** without **jetsam** or a forced return to the clock face — the failure mode captured in **§ 4** and the April **2026** timeline. That outcome **supports** the investigation thread that **eager `Charts` / chart-page construction at first frame** was a major contributor to **launch-time resident pressure** alongside large WC payloads and logging amplifiers. **B5** (foreground-open / jetsam validation) and **B0** (measurement / repro gate) are **documented closed** for this initiative — see [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) implementation log (**2026-04-08 21:33 CEST**, **2026-04-08 21:45 CET**) and [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § **B5** / **B0** closure. Optional **B2** implementation remains **when prioritized** ([04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) pre-B2 table **2026-04-06**).

### Field telemetry note (2026-04-08)

**TestFlight 153+** includes **Path B** **B6** — in-process **`TASK_VM_INFO.phys_footprint`** samples via **`event=watch_resident_sample`** / **`phys_footprint_mib`** (default **on** on TestFlight / sandbox receipt per **04** § **B6**). Better Stack spot-checks show resident-sample lines in the hot tier — see [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) implementation log (**2026-04-08 18:02 CEST**). **B6** supported **B0** clause **2** numeric evidence; **B5** and the full **B0** checklist are **closed** in **02** / **04** (**2026-04-08** — **2026-04-08 21:33 CEST** / **21:45 CET**).

---

## Evidence Sources

### 1. Repo history / commit review

Reviewed the watch-related first-parent history from build 142 onward in `feature/watch-complication-improvements`, with emphasis on:


| Commit      | Date       | Relevance                                                                                |
| ----------- | ---------- | ---------------------------------------------------------------------------------------- |
| `30f166c5a` | 2026-03-18 | Build 142 baseline. Adds watch-side `applicationContext` safety net.                     |
| `c6b273d78` | 2026-03-14 | Adds HealthKit background delivery registration and observer setup during watch startup. |
| `2e3db70f5` | 2026-03-28 | Adds explicit 5-second `WatchLogger` `sendMessage` wait.                                 |
| `07175b577` | 2026-03-30 | Introduces terminal-path-aware connectivity task completion.                             |
| `58f706a0f` | 2026-03-30 | Adds deferred retry logic around connectivity task completion.                           |
| `fdd94106b` | 2026-03-31 | Adjusts confirm-only connectivity wake handling.                                         |


### 2. Code-path review

Reviewed the launch and immediate-foreground flow **in the baseline code reviewed during the original investigation** (i.e. before Path A implementation landed in the working tree):

- `Trio Watch App Extension/TrioWatchApp.swift`
- `Trio Watch App Extension/ExtensionDelegate.swift`
- `Trio Watch App Extension/WatchLogger.swift`
- `Trio Watch App Extension/WatchState.swift`
- `Trio Watch App Extension/WatchState+Requests.swift`

The main code findings **in that baseline** were:

- `WatchLogger` had a 5-second actor-side `WCSession` wait (`wcSessionSendTimeoutNs = 5 * 1_000_000_000`).
- startup logs in `TrioWatchApp.init` and `applicationDidFinishLaunching` used forced logging paths
- first active performed crash-state marking and `flushPersistedLogs()`
- `WatchState.setupSession()` activated `WCSession` and immediately started HealthKit setup
- `applicationDidBecomeActive()` immediately requested watch state from the phone

**Note:** the **Path A** design/plan addresses this baseline behavior; the present **product tree** may already reflect coordinator / deferral / transport suppression. When correlating code to symptoms, distinguish **investigation-time baseline** from **post–Path A** behavior.

### 3. Better Stack evidence

Used Better Stack telemetry queries against the Trio logs source. The most important query-derived observations were:

- repeated build 148 launch / extension-start rows on 2026-04-01
- timeout rows for `query_acks`, `flush`, and `drain`
- daily completion-path counts showing that the Mar 30 connectivity-task changes produced many `timeout` completions on 2026-03-30, but those counts dropped sharply on 2026-03-31

Important caveats:

- `event=watch_app_launch` is logged from app init, so it includes non-user launches and extension wakes.
- Better Stack historical queries required the documented hot-tier plus S3 union pattern; broader single-source queries returned partial or empty results.
- Some later MCP calls were unstable, so not every exploratory query was reproduced twice in the same session.

### 4. Diagnostic log / jetsam evidence

Reviewed the watch diagnostic artifacts in this folder:

- `JetsamEvent-2026-04-01-143500.ips`
- `JetsamEvent-2026-04-03-164956.ips`
- `JetsamEvent-2026-04-03-165709.ips`

The most important findings across those reports (and consistent with reproducible foreground-open jetsam) were:

- `largestProcess` was `Trio Watch App` in each capture
- the `Trio Watch App` process entries were **`active`** (and in the `2026-04-03-164956` capture, **`frontmost`** as well)
- **captured** termination reasons on the Trio process entry include **`per-process-limit`** and **`highwater`** (exact strings are diagnostic metadata per event; inventory in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § Jetsam reason strings)
- the **2026-04-01** capture: `rpages=19465` with `pageSize=16384` implies roughly **304 MiB** resident pages at kill time; system free pages were `2475`, or roughly **38.7 MiB** free
- the **2026-04-03-164956** capture: Trio `reason` **`highwater`**, `rpages` **21356** (~333 MiB at 16 KiB pages)
- the **2026-04-03-165709** capture: Trio `reason` **`per-process-limit`** on the listed Trio process entry (`rpages` on the order of **~19.5k** pages in that snapshot)

**Category attribution:** `per-process-limit` vs `highwater` vs other reasons still does **not** identify the specific allocation site, and **does not** by itself prove a single dominant mechanism (spike vs steady)—see [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md) open questions. The diagnostics **do** materially narrow the symptom: “open app, then forced return to clock face” includes **jetsam** kills, not only Swift exception crashes or timeouts.

---

## Consolidated Timeline


| Date       | Commit / Build                   | What changed                                                    | Relevance to this issue                                                           |
| ---------- | -------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 2026-03-14 | `c6b273d78` / pre-build-142 context | HealthKit background delivery registration and observer setup move into watch startup | Pre-build-142 change, but still operationally relevant because it adds startup work that compounds the later log-transport issue. |
| 2026-03-18 | `30f166c5a` / build 142          | `applicationContext` watch safety net                           | Important baseline, but not the leading suspect for the current 5-second close.   |
| 2026-03-20 | `e459a2008` / build 143 patch-09 | R5d sleep-gap integration, more watch-side startup / save logic | Adds startup-adjacent work but not the cleanest symptom match.                    |
| 2026-03-21 | `90fdcabbb` / build 144          | observability and retry optimization                            | Small follow-on change; not the primary regression point.                         |
| 2026-03-28 | `2e3db70f5`                      | hardens `WatchLogger` send path with explicit 5-second wait     | Strong match for a user-visible "closes after ~5 seconds" complaint.              |
| 2026-03-30 | `07175b577`                      | aligns connectivity task completion with terminal paths         | Major lifecycle change; produced noisy completion-path behavior.                  |
| 2026-03-30 | `58f706a0f`                      | adds deferred retry logic to connectivity completion            | Adds more task-lifecycle complexity during wake / resume windows.                 |
| 2026-03-31 | `fdd94106b`                      | avoids confirm-only connectivity wake timeouts                  | Improves the Mar 30 behavior, but does not eliminate all launch instability risk. |
| 2026-04-01 | `JetsamEvent-2026-04-01-143500.ips` | watchOS kills `Trio Watch App` while active for **`per-process-limit`** | First archived capture in-folder; ~304 MiB `rpages` at kill (see § 4). |
| 2026-04-03 | `JetsamEvent-2026-04-03-164956.ips` | watchOS kills `Trio Watch App` while **`active` / `frontmost`** for **`highwater`** | Confirms **`highwater`** appears in **device** diagnostics, not only narrative reports. |
| 2026-04-03 | `JetsamEvent-2026-04-03-165709.ips` | watchOS kills `Trio Watch App` for **`per-process-limit`** | Second same-day capture; reinforces **`per-process-limit`** alongside **`highwater`** as observed reason strings. |
| (ongoing) | Reproducible foreground-open jetsam (same class of symptom) | `per-process-limit` / `highwater` (and potentially others) | Confirms memory-budget termination is a **repeatable** manifestation of the user-reported forced return to the clock face; establishes **Path B** as the **primary** footprint track and keeps **Path A** as a **parallel pressure-reduction** track. |
| 2026-04-06 | TestFlight **152** / **B3** lazy chart + **B1**/**B4** + Path **A** in tree | Field report: stable watch **launch and foreground** without jetsam/forced closure | **Supportive** validation for the **eager chart at launch** hypothesis; **B5** / **B0** formally **closed** **2026-04-08** (see **02** implementation log **21:33** / **21:45 CET**). |


---

## Codex and Cursor Findings

### Areas of agreement


| Topic                                                                   | Codex                                      | Cursor                                         | Synthesis                                                                |
| ----------------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------- | ------------------------------------------------------------------------ |
| Build 142 `applicationContext` is not the best first target             | Agreed                                     | Agreed                                         | Do not start by reverting `30f166c5a`.                                   |
| `2e3db70f5` is a top suspect                                            | Strongly implicated                        | Strongly implicated                            | Highest-confidence **Path A / ~5s timeout–symptom** lead; **Path B** remains the **primary** track for **jetsam footprint** (see executive summary). |
| Jetsam is a confirmed failure mode once the device diagnostic is included | Agreed                                     | Agreed                                         | Treat `per-process-limit` / `highwater` jetsam as confirmed manifestations of the symptom, not a competing theory to Path A. |
| Startup is too busy                                                     | Explicitly identified as launch contention | Explicitly identified as cold-start contention | Combine items 1 and 2 into **Path A** (startup load shedding).            |
| HealthKit on launch is plausible but secondary                          | Credible amplifier                         | Credible amplifier                             | Include it in the combined startup fix rather than as a separate theory. |
| Connectivity background-task changes are real but not necessarily first | Candidate, especially Mar 30               | Candidate, but weaker than launch transport    | Defer item 3 from the current design and plan.                           |


### Areas where evidence is partial or weaker


| Topic                                                                                          | Direct evidence                                                                         | Inference                                                                                              |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Early crash before full lifecycle settles                                                      | Missing normal active / scene rows in queried windows                                   | Could indicate early death, but Better Stack delivery gaps can also hide breadcrumbs.                  |
| Phone-side `settings/model.json` and `determine_basal.js` failures as direct watch-close cause | Logs exist near launch windows                                                          | Supports "bad startup state" more than a proven watch process termination.                             |
| Connectivity task timeout as current top cause                                                 | Strong on 2026-03-30, much weaker on 2026-03-31 and absent in the April 1 slice queried | Suggests the issue class is real, but probably not the best first remediation for the current symptom. |


### Cursor-specific evidence retained

Cursor independently confirmed:

- the explicit 5-second `WatchLogger` timeout in code
- launch / first-active log and flush pressure in the watch startup path
- at least one recent Better Stack `query_acks` timeout row in its own MCP session

Cursor did not independently reproduce the full day-by-day Better Stack timeline because later MCP calls became unstable and broader historical queries were affected by hot-tier / query-shape limitations. That narrower reproduction does not conflict with the Codex timeline; it should be treated as partial supporting evidence rather than a competing account.

### Direct evidence vs inference

#### Direct evidence

(Where behavior is launch-path specific, these statements describe the **baseline tree at investigation time**; Path A implementation may have changed some call patterns.)

- `WatchLogger` contains an explicit 5-second reply wait.
- first-active handling called `flushPersistedLogs()` in the **baseline** review.
- `WatchState.setupSession()` started HealthKit setup immediately in the **baseline** review.
- Better Stack returned repeated build 148 launch / extension-start rows on 2026-04-01.
- Better Stack returned timeout rows for `query_acks`, `flush`, and `drain`.

#### Inference

- repeated launch rows within short windows may indicate restart / relaunch behavior, but do not by themselves prove a crash
- the combined startup workload is likely sufficient to destabilize launch, but the only captured device-side termination evidence in this investigation was a jetsam diagnostic, not a Swift exception crash log
- the phone-side missing-file errors likely worsen the launch path, but were not proven to be the immediate killer

---

## Better Stack Findings

The following observations come from Better Stack query results collected during this investigation.

### Concrete timestamped rows

Launch / extension-start rows observed on 2026-04-01:

- `2026-04-01 05:19:23` — `[DEPLOY] event=watch_app_launch platform=watchos build=148`
- `2026-04-01 05:19:36` — `[DEPLOY] event=watch_app_launch platform=watchos build=148`
- `2026-04-01 05:19:36` — `event=watch_extension_launched source=wk_application_delegate method=applicationDidFinishLaunching`
- `2026-04-01 05:24:43` — `[DEPLOY] event=watch_app_launch platform=watchos build=148`
- `2026-04-01 05:24:44` — `event=watch_extension_launched source=wk_application_delegate method=applicationDidFinishLaunching`
- `2026-04-01 06:24:44` — `event=watch_extension_launched source=wk_application_delegate method=applicationDidFinishLaunching`

Timeout rows observed on 2026-04-01:

- `2026-04-01 03:59:44` — `WCSession sendMessage timed out context=query_acks`
- `2026-04-01 05:12:10` — `WCSession sendMessage timed out context=drain`
- `2026-04-01 05:12:11` — `WCSession sendMessage timed out context=flush`

Other launch-window rows observed near 2026-04-01 05:19-05:24:

- `WCSession setup complete.`
- `hk_background_delivery_registered success=true`
- `Logs queued for background delivery`
- phone-side file retrieval failures for `settings/model.json` and `middleware/determine_basal.js` (typically emitted from **iPhone** ingestion / storage paths in Trio logs; correlate by source / message shape — not necessarily watch-originated lines)

### Completion-path counts

Querying `event=complication_bgtask_completing path=`* from 2026-03-30 onward showed:

- total counts: `fast=571`, `message=277`, `timeout=226`, `fast_late_task=122`
- by day:
  - 2026-03-30: `timeout=198`
  - 2026-03-31: `timeout=28`
  - 2026-04-01 queried slice: no `timeout` rows returned

Interpretation:

- the connectivity background-task issue was severe on 2026-03-30
- the Mar 31 follow-up fixes materially reduced the timeout path
- this makes item 3 a valid follow-up, but weaker than the startup transport theory for the current report

### Query caveats

- Some broad searches returned no rows until the documented `remote(...) UNION ALL s3Cluster(...)` pattern was used.
- Historical windows need the S3 union because the hot tier is short-lived.
- MCP session stability degraded during later queries, so this dataset should be treated as strong directional evidence, not a complete incident timeline.

---

## Diagnostic Log Findings

The jetsam evidence materially changes the certainty level of this investigation.

Direct takeaways:

- this was not only a "mysterious close" or an abstract startup timeout problem
- reproducible watchOS jetsam on foreground launch/open while the app was **active**, with reasons including **`per-process-limit`** and **`highwater`**
- the user-visible effect of that kill would be a forced return to the clock face

Interpretation:

- **Path A** (launch-path load shedding) remains **justified in parallel** because it reduces startup contention and **may** reduce some peak pressure; it is **not** the **primary** track for footprint
- **Path B** (foreground memory-hardening) is the **primary** track for **resident footprint** and **launch object-graph size** suggested by repeated jetsam
- the Better Stack timeout rows remain relevant as **part of startup overload**, not as the sole observed failure mode
- validation must include **device-side memory / jetsam evidence**, not Better Stack alone; Path B work adds **instrumentation and repro measurement** expectations detailed in the implementation plan

---

## Ranked Candidates

The ranked candidates below shaped **Path A** (startup load shedding). They remain plausible **contributors** to launch instability and pressure. **Jetsam** (`per-process-limit`, `highwater`) is the **observed foreground-launch closure mechanism**; it is not a “competing theory” to Path A, but it **does** establish **Path B** as the **primary remediation track** for footprint while **Path A** remains a **parallel pressure-reduction** track. See [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md) for **code-level, confidence-graded** ranking of **resident-memory** contributors (payload size, duplication, Charts, logging stringification, HealthKit batch risk).

### 1. Launch-time WatchLogger transport and forced flush pressure

**Why it ranks first (Path A lens)**

- cleanest historical match to a "~5 seconds" symptom tied to `WCSession` reply timing
- direct code evidence in `2e3db70f5`
- direct Better Stack evidence from `query_acks`, `flush`, and `drain` timeout rows

**Decision impact**

This is the **lead Path A** problem to implement first.

### 2. Cold-start contention from concurrent startup work

**Why it ranks second (Path A lens)**

- in the **pre–Path A baseline**, startup performed logging, crash-state work, persisted-log flush, HealthKit setup, and immediate watch-state refresh
- Better Stack showed HealthKit registration immediately after launch in the original investigation window
- this likely amplifies the launch-path transport problem even if it is not independently fatal

**Decision impact**

This belongs in the **same Path A** remediation as candidate 1.

### 3. Connectivity background-task completion state machine

**Why it ranks third**

- direct code changes on 2026-03-30 and 2026-03-31
- direct Better Stack evidence that the issue class was real
- weaker fit for the current symptom after the Mar 31 reductions

**Decision impact**

Document as a deferred follow-up only. Do not include it in the current design or implementation plan.

---

## Final Recommendation

### Path A — Startup load shedding / launch pressure reduction (parallel, justified)

Implement the startup coordinator and grace model that combines:

1. removal of watch-to-phone **log / telemetry transport** from app init and the immediate foreground activation window
2. deferral of HealthKit setup and the initial watch-state refresh until after a foreground-settle grace period
3. deferral of persisted-log flush on the same schedule

To make Path A faithful to the current codebase, implementation must also:

- centralize all foreground / cold-start first-refresh triggers under one startup coordinator so activation-complete and reachability callbacks cannot bypass the deferred 2-second request
- treat startup-time `flushPersistedLogs()` callers as grace-aware and transport-suppressed so they do not run `drain`, `query_acks`, resend, or `flushToPhone()` before the 10-second window expires

Do not include ranked candidate **3** (connectivity background-task state machine) in the Path A design or Path A implementation scope.

Do not start by reverting build 142 `applicationContext`.

### Path B — Watch foreground memory-hardening / launch footprint reduction (primary track)

Execute the **Path B** phases in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md), grounded in [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md). **B0** exit and **B5** validation are **closed** for this initiative (**02** / **04**, **2026-04-08**). **Pre-B2** product decisions remain in [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) for **B2** coding **when prioritized**. Path B directly targets **resident footprint** and **launch object-graph size**: payload shaping / history limits, reduction of duplicate on-watch state, lazy or deferred chart and heavy detail surfaces, elimination of payload-stringifying logging amplifiers, bounded HealthKit startup batch behavior, and **launch memory instrumentation** to validate impact.

**Path B is a required remediation track and should begin immediately**; **Path A should continue in parallel as sequencing allows**; **ordering between tracks remains a delivery decision**. Repeated foreground-launch jetsam with **`per-process-limit` / `highwater`** establishes **urgency**; it does **not** by itself prove a unique mandatory lockstep ship order with Path A. **Path A** remains valuable in parallel because it reduces **launch-time transport/scheduling amplifiers** that may compound pressure.

### Validation and outcome handling

Validation must not rely on Better Stack alone. Use the **device-side jetsam protocols** in the design and implementation plan for **Path A** and **Path B**.

- **Path A** acceptance is defined by coordinator / transport / deferral criteria. **Recurring jetsam after Path A acceptance** does **not** mean Path A was mis-specified; it means **prioritizing Path B** footprint reductions (and may require re-ordering delivery).
- **Path B** acceptance includes **bounded foreground-open repro** with jetsam checks and, where noted in the plan, **runtime validation** of mitigation impact—without treating code-level investigation as a substitute for measurement.

If Trio still hits **`per-process-limit` or `highwater`** jetsam after Path B tranches land, treat that as a signal to **iterate Path B** (and widen instrumentation), not as automatic proof that Path A was wrong.

---

## External Review Disposition

External review from ChatGPT and Claude materially improved the docs and was adopted in `v1.5` and `v1.6`.

Accepted clarifications:

- startup grace is now defined more plainly as one umbrella concept: suppression begins at launch, deferred timers begin on confirmed active, and later activation sequences in the same process re-arm suppression
- same-process re-entry, cached/fallback UI expectations, cancellation observability, and the acceptance-outcome matrix are now explicit
- the implementation plan now names the periodic timer, size-threshold flush path, and WCSession activation-complete callback as concrete places where the coordinator / suppression rules must apply
- the validation section now includes an attempt-scoped Better Stack query shape and states more bluntly that device-side diagnostics are authoritative for jetsam

Retained modified positions:

- suppression still begins at process launch, not only at confirmed foreground activation, because init / finish-launch logging is part of the suspected problem
- `flushPersistedLogs()` does not require one mandated internal shape; a split startup-safe plus deferred transport phase is acceptable as long as suppression is enforced before any transport-capable branch runs

No additional substantive disagreements were introduced by the latest ChatGPT / Claude pass beyond those retained positions.

---

## Changelog

### v1.14 (2026-04-08 21:45 CET)

- **Initiative closure alignment:** **Status**, **§ Field validation summary**, **§ Field telemetry note**, **Consolidated timeline** (**2026-04-06** row), and **Path B recommendation** updated so **B5** / **B0** are **not** described as open; pointers to **02** implementation log **2026-04-08 21:33 CEST** / **21:45 CET** and **04** § **B5** / **B0** closure. Optional **B2** called out explicitly.

### v1.13 (2026-04-08 18:02 CEST)

- **Field telemetry:** **§ Field telemetry note (2026-04-08)** — TestFlight **153**, **B6** **`watch_resident_sample`** / **`phys_footprint_mib`** live on TF/sandbox (pointer to **02** implementation log **2026-04-08 18:02 CEST**). **Status** line notes **153** + **B6**; does not claim **B5**/**B0** closed.

### v1.12 (2026-04-06 15:48 CET)

- **Field validation:** Added **§ Field validation summary (2026-04-06)** for TestFlight **152** (lazy chart **B3** + **B1**/**B4** + Path **A**); **Consolidated timeline** row for **2026-04-06**. **Status** updated to reflect mitigated primary symptom while **02**/**04** gates remain.

### v1.11 (2026-04-03 21:56 CET)

- **Jetsam diagnostics:** Added **`JetsamEvent-2026-04-03-164956.ips`** (`highwater`, frontmost) and **`JetsamEvent-2026-04-03-165709.ips`** (`per-process-limit`) to § 4 and the consolidated timeline. Replaced the prior “`highwater` only in reports / single `.ips`” paragraph with **three-file** evidence + **category attribution** note (still open in **03**). **[04](04-watch-foreground-memory-hardening-design.md)** § Jetsam reason strings now holds the canonical file/reason table.

### v1.10 (2026-04-03 21:39 CET)

- Linked **[04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)**; sequencing aligned with design doc (**Path A continues in parallel as sequencing allows**). Added **`highwater` vs single `.ips`** caveat with pointers to **03** / **04**. Path B recommendation now cites **B0 / pre-B2 gates**.

### v1.9 (2026-04-03 21:26 CET)

- **Pre-implementation doc review** (`docs/prompts/03-pre-implementation-doc-review.md`): aligned **Codex synthesis** for `2e3db70f5` with **Path B primary / Path A parallel** framing; fixed **baseline vs current** wording in ranked candidate 2; softened validation language so recurring jetsam **prioritizes Path B** without implying Path A was wrong.

### v1.8 (2026-04-03 21:19 CET)

- **Primary vs parallel tracks:** positioned **Path B** as the **primary remediation track** and **Path A** as a **justified parallel pressure-reduction** track (not obsolete). Replaced “mandatory in parallel / lockstep” phrasing with: **Path B is a required remediation track and should begin immediately; sequencing relative to Path A remains a delivery decision.** **Status** set to **Under major revision** while planning docs are refactored.
- **Time framing:** code-path review now describes the **baseline at original investigation time** (pre–Path A) and notes the live tree may already implement Path A.
- Executive summary, diagnostic interpretation, ranked-candidate preamble, and final recommendation updated accordingly; **evidence vs inference** boundaries preserved.

### v1.7 (2026-04-03 21:01 CET)

- Reframed remediation as **two required paths**: **Path A — Startup load shedding / launch pressure reduction** (original startup transport + deferral conclusions) and **Path B — Watch foreground memory-hardening / launch footprint reduction** (driven by the completed [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md)). Stated that **repeated foreground-launch jetsam** with **`per-process-limit`** and **`highwater`** makes **memory-budget closure** the **primary observed** forced-return mechanism; Path A remains justified for contention/pressure but is not the whole story. Updated ranked candidates, diagnostic interpretation, final recommendation, and validation/outcome language to preserve **evidence vs inference** boundaries and to mark Path B **mandatory**, not optional.

### v1.6 (2026-04-02 21:22 CEST)

- Incorporated a final external-review wording pass. Shortened the external-review disposition into a more durable rationale section, recorded that no new substantive disagreements were introduced beyond the previously retained positions, and aligned the findings summary with the design/plan clarifications around startup-grace wording and validation authority.

### v1.5 (2026-04-02 21:12 CEST)
- Incorporated ChatGPT and Claude external-review feedback. Updated the findings recommendation to point at the bounded device-side jetsam validation protocol, added an explicit external-review disposition section documenting accepted changes, and recorded the two modified disagreements: process-launch suppression is still required even though timers start on confirmed active, and `flushPersistedLogs()` may use a split startup-safe/deferred implementation as long as suppression is enforced before any transport-capable branch.

### v1.4 (2026-04-01 17:39 CEST)
- Updated the findings framing after doc review: the Codex/Cursor agreement table now includes jetsam as a confirmed failure mode, the stale "no device crash log" line now distinguishes Swift exception crashes from the captured jetsam diagnostic, and the recommendation now states that persistent jetsam after this initiative implies follow-up memory-hardening work rather than invalidating the startup load-shedding plan.

### v1.3 (2026-04-01 14:58 CEST)
- Incorporated the 2026-04-01 watch jetsam diagnostic showing `Trio Watch App` killed while active for `per-process-limit`, added that event to the timeline, and reframed the startup investigation around a confirmed memory-budget termination rather than only Better Stack timeout symptoms.

### v1.2 (2026-04-01 14:22 CEST)
- Added the pre-build-142 `c6b273d78` HealthKit startup change to the consolidated timeline and clarified two implementation-critical constraints from doc review: startup coordinator ownership of all foreground / cold-start first-refresh triggers, and startup-time `flushPersistedLogs()` paths remaining transport-suppressed until the grace window expires.

### v1.1 (2026-04-01 09:42 CET)

- Pre-implementation doc review: clarified that phone-side `settings/model.json` / `determine_basal.js` failure lines are typically **iPhone-originated** in Trio telemetry when correlating launch windows.

### v1.0 (2026-04-01 09:31 CEST)

- Initial investigation findings doc for the watch launch stability issue. Consolidates Codex and Cursor findings, records direct Better Stack evidence, ranks the top three candidates, and recommends combining launch-path log-transport reduction with startup work deferral while deferring connectivity background-task redesign.
