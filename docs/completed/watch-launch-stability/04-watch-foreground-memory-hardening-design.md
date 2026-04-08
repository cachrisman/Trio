# Watch foreground memory-hardening — design (Path B)

**Version:** v1.14
**Created:** 2026-04-03 21:39 CET
**Last updated:** 2026-04-08 21:54 CEST
**Status:** Final

**Purpose:** Path **B** design anchor for implementation — **decisions**, **gates**, and **constraints** that are not fully specified in the investigation artifact (**03**) or the high-level intent blurb in **01**. Executable phases remain in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md).

---

## Document map

| Doc | Role |
|-----|------|
| [00-investigation-findings.md](00-investigation-findings.md) | Findings, track positioning, validation outcomes |
| [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md) | **Path A** full spec; **Path B** intent summary |
| [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) | **A1–A3** and **B0–B6** tasks, acceptance, sequencing |
| [03-watch-foreground-launch-memory-investigation.md](03-watch-foreground-launch-memory-investigation.md) | Evidence, confidence grades, code pointers (**not** a design spec) |
| **This file (04)** | Path B **product/engineering decisions**, **B0 exit**, **pre-B2 gate** record |

---

## Design commitments (Path B) — intent

Aligned with [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md) § Path B:

- **Bound startup HealthKit batch size** on cold / nil-anchor paths.
- **Reduce on-watch history depth / duplicate state** for the same logical data.
- **Eliminate payload-stringifying logging amplifiers**.
- **Lazy/defer chart and heavy detail surfaces** where runtime validation supports it.
- **Launch memory instrumentation and repro discipline** (details and exit gate in **02** § B0).

---

## B0 exit gate (before starting B2 or **new** B3-class chart work — **closed** **2026-04-08** for this initiative)

**Authoritative checklist:** [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) § **B0** (this doc does not duplicate the full steps).

**Closure rule:** B0 is **complete** when all of the following are true:

1. **Device run recorded** with notes tied to a specific Trio/watchOS build, covering at least these **checkpoints** from doc 03's instrumentation outline: cold launch, first frame, after deferred watch-state fires, after first large WC payload handled (counts/metadata only — no full payload logs), +10s HealthKit path, +10s log flush path.
2. **Resident or Instruments evidence** at each checkpoint: either a **numeric sample** (e.g. memory gauge / `task_vm_info` / Instruments mark) **or** a written **"infeasible on this device/OS, because …"** with reviewer sign-off.
3. **Chart isolation:** at least one **A/B** or **feature-flag** comparison that **isolates chart cost** (per doc 03), **or** an **explicit written decision** to defer that A/B with rationale and a named follow-up date/owner.

**Closure (2026-04-08):** **B0 is closed** for the watch-launch-stability initiative — **2026-04-08 21:45 CET** — implementation log [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) **2026-04-08 21:45 CET** ( **Clause 1–2** device run + **B6** `phys_footprint_mib` table; **Clause 3** chart A/B **deferred** per **2026-04-06 13:48 CET** waiver + **B3** lazy chart shipped).

Until this gate is satisfied **for a future initiative or re-opened scope**, treat **B2** coding and **new** Path B footprint work that **requires** a fresh **B0**-style measurement record as **planning-only** without a written waiver or a fresh **B0** closure (implementation prompts must not start them as "greenfield" without a written waiver in the implementation log stating which clause is waived and why). **B3** (lazy chart) is **already shipped** for this initiative — future chart/footprint changes are not covered by the historical **B0** closure unless explicitly scoped.

**B0 is also the primary validation checkpoint for the canonical-representation hypothesis in the pre-B2 table below.** If B0 data shows that a single canonical 288-point representation still produces resident pressure near jetsam thresholds, the upstream trimming row in that table must be revisited before B2 implementation proceeds.

---

## Pre-B2 decision gate (blocking)

**B2** requires a **product-bounded** history policy. Before B2 implementation starts, **fill the table below** (or link an ADR / ticket that contains the same fields). The **Owner and date decided** row was a **hard blocker** while empty — **filled 2026-04-06** (**Charlie Chrisman**); do not start B2 coding without the policy rows above matching your intent (or an explicit superseding ADR).

**Default Path B assumption (hypothesis, not a concluded fact):** retaining up to **288** glucose points on-watch is acceptable *if* they exist as a **single canonical long-lived representation**. The primary memory risk is **not the raw point count by itself**, but **duplicate stacked representations, payload/string duplication, and eager chart/render/logging work** around that data. Doc 03 ranks the 288-point payload as a "Primary" consumer (#1 and #2 in the ranked list) — that ranking reflects the combined effect of duplication and downstream work, not an assertion that the canonical array size alone is the jetsam trigger. **B2** should therefore target **ownership and duplication first**. **This assumption is what the B0 measurement gate was intended to validate** ( **closed** **2026-04-08** — [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) implementation log **2026-04-08 21:45 CET**). If future **B6** / field evidence **contradicts** it — i.e., a single canonical 288-point representation still keeps resident footprint near jetsam thresholds even after B1/B3/B4 are applied — the upstream trimming decision below must be reopened before B2 is considered done.

| Decision | Record |
|----------|--------|
| Maximum glucose points (or equivalent) delivered/stored for **watch chart** | **288 points** |
| **Where** cap/trim applies (phone fetch, WC payload, watch decode, or combination) | **No additional trim below 288 by default.** Enforce a **single canonical on-watch representation** and avoid duplicate long-lived copies. Revisit upstream trimming only if **B0/B5** shows memory pressure remains after duplication, logging, and chart-eagerness fixes. |
| Downsampling algorithm vs hard truncate (if any) | **No required downsampling for canonical storage.** Optional **derived display downsampling** may be used for chart rendering only if needed for render/memory performance; do **not** create a second long-lived full copy for chart use. |
| **Fidelity / parity** acceptance (complication vs chart, min visible history) | **Complication and primary trend display must remain correct.** The watch may retain the full **288-point canonical history** if chart rendering uses derived/lazy data rather than another always-resident full representation. Any chart-specific reduction must preserve agreed minimum visible history and product-acceptable fidelity. |
| **Owner** and **date decided** | **Owner:** Charlie Chrisman. **Date decided:** 2026-04-06. Accepts the policy rows above (288-point canonical representation, single long-lived copy, optional display-only downsampling, parity expectations). **B2** coding may proceed per sequencing in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md); this sign-off does not waive phase-local acceptance or **B5** validation there. |

---

## Pre-B3 notes (non-blocking unless B0 defers chart A/B)

- If B0 **did** run chart A/B, attach the **outcome** here or link results (lazy chart worth it vs not on target OS).
- If B0 **deferred** chart A/B, B3 planning must restate **assumptions** being made without that data.
- **B0 closure (2026-04-08):** Chart **A/B** was **not** run; clause **3** was satisfied by **2026-04-06 13:48 CET** waiver (**`build=150`** jetsam causal evidence) and **B3** lazy **`GlucoseChartView`** (tab-selected construction). **Assumption for footprint work without chart isolation:** same as **04** pre-B2 hypothesis — primary risk is **duplicate representations + eager chart/render/logging**, not point count alone; **B3** avoids paying **`Charts`** cost until the user opens the chart tab (see **02** implementation log **2026-04-06 13:50 CET** / **2026-04-08 21:45 CET**).

---

## B6 — Field resident memory telemetry (optional; Path B)

**Why B6 (not “Path C”):** **B6** is **optional measurement infrastructure** under **Path B**. It does **not** define a third parallel remediation track alongside **Path A** (startup load shedding) and **Path B** (footprint mitigations). **Path C** would imply a new initiative with separate scope; **B6** only **samples** a **single defined Mach metric** to close or support **B0** exit gate clause **2** and for regression visibility.

**Problem:** **B0** clause **2** calls for **numeric resident memory evidence** (memory gauge, `task_vm_info`, Instruments, or equivalent) at defined checkpoints. **Mac-tethered Instruments** on the **same** binary the user runs day-to-day is often **impractical** when the daily driver is **TestFlight** and installing a local Xcode build would **replace** that install.

**Metric (precise):** Use Mach **`task_info`** with flavor **`TASK_VM_INFO`** on the **current task**. Log the **`phys_footprint`** field from the returned structure (bytes), converted to **MiB** (mebibytes; **1024 × 1024** bytes per MiB), and emit it as **`phys_footprint_mib=<value>`** on each line. **Do not** mix in other `task_info` flavors or informal “resident” labels without naming them — later comparisons depend on **one** stable definition. **`phys_footprint`** is not interchangeable with every other “resident” or gauge reading; document that **B6** uses **`TASK_VM_INFO.phys_footprint` → MiB** only.

**Event name (final):** **`event=watch_resident_sample`** — no alternate `event=` names in plan text.

**Correlation field (`activation_seq`):** Include **`activation_seq=<n>`** on every line **when** the watch app’s current **startup / foreground activation sequence** is defined (all normal startup-path checkpoints). **Optional** only for rare **process-scoped** samples that can occur **outside** an activation context (if any are ever added); default implementation should pass **`activation_seq` whenever `WatchState` has a current sequence** — see **02** § **B6**.

**Rollout / gating:** **B6** is **not** implied to be unrestricted always-on **production App Store** telemetry. **Default on:** **DEBUG** builds; **TestFlight** (and other installs whose App Store receipt URL is the **sandbox** receipt — `lastPathComponent == "sandboxReceipt"`). **Default off:** **production App Store** (non-sandbox receipt) unless **`UserDefaults`** opt-in **`com.trio.watch.residentTelemetryEnabled`** is **true**. **Intended:** field measurement on TF / DEBUG without requiring a separate toggle; App Store remains opt-in. Document the actual gate in the implementation log when shipping.

**Field status (2026-04-08):** TestFlight **153+** ships **B6** enabled on **sandbox/TestFlight** builds per the gate above. Aggregation (e.g. Better Stack) hot-tier spot-checks show **`event=watch_resident_sample`** with **`phys_footprint_mib`**, named **`checkpoint`**, and **`activation_seq`** (when applicable). **B0** and **B5** are **closed** for this initiative (**02** implementation log **2026-04-08 21:45 CET** / **21:33 CET**); **B6** was the **`TASK_VM_INFO` equivalent** used in the **B0** clause **2** table for **TestFlight 154** (same subsection in **02**).

**Sampling budget (hard):**

- **At most one** `event=watch_resident_sample` per **`checkpoint`** value **per** `activation_seq` (current startup activation sequence).
- **At most six** emissions per activation **total** (one per **listed** checkpoint token — **six** tokens — see **02** § **B6**). Process-scoped **`hk_batch`** without **`activation_seq`** does not count toward this per-activation cap.
- **`hk_batch`:** **first** HK observer batch completion **after** deferred HealthKit setup for this **process** only (**conservative** budget — avoids repeated HK telemetry on long sessions). **Do not** re-emit on every later HK fire in the same process unless the spec is revised. If the first qualifying batch occurs when **`activation_seq`** is **not** yet defined, emit **one** process-scoped line **without** **`activation_seq`**; if **`activation_seq`** already exists at first batch, include **`activation_seq`**. **At most one `hk_batch` line per process** in all cases.
- **`chart_visible`:** at most **once** per activation when the user navigates to the chart tab.

**Approach (design):**

- **No** full payload logging — only structured **`WatchLogger`** lines (phone upload / aggregation such as Better Stack).
- **Checkpoint semantics** (high level): **`first_main_view`** = **root-view appearance checkpoint** (earliest practical “UI is up” hook — e.g. **`TrioMainWatchView`** `.onAppear` — used as a **first-frame proxy**, not a guarantee of GPU frame timing). **`deferred_watch_state_fired`** measures **around** the coordinator firing the deferred refresh (**before** payload apply); **`first_watch_state_apply`** measures **after** the first applied watch-state payload for that activation (**post-decode / post-merge** — memory-relevant); **`post_startup_flush`** measures **after** the deferred `flushPersistedLogs` **async work completes locally** (transport to phone may still finish later). Full token list and ordering: [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) § **B6**.
- **Spam control:** per-activation / first-apply flags so WC-heavy paths never emit on every message; **hard budget** above is authoritative.
- **Transport timing:** Startup grace may **delay** phone-side flush of ring-buffer lines; samples remain valid for **B0** closure if analysis uses **attempt-scoped** or **wide enough** time windows (see **02** § Validation and implementation log).
- **B0 clause 2:** A documented run that captures these **`phys_footprint_mib`** lines for a **named** Trio/watchOS build counts as **`task_vm_info` / TASK_VM_INFO equivalent** for gate purposes, alongside an implementation-log note of **repro method** (e.g. force quit vs warm resume). **As of TestFlight 153**, **B6** is **field-shipped** on **sandbox/TestFlight** (default **on** per **Rollout / gating** above). If **B6** were **not** available, clause **2** could still be satisfied by **written infeasibility** + sign-off per **04** § B0 exit gate.

---

## Jetsam reason strings (`per-process-limit` vs `highwater`)

**Archived device diagnostics** in this initiative's folder (same directory as **00–04**) now include **three** `JetsamEvent` captures for the same device class (`Watch6,15`, watchOS 26.3). Each names **`Trio Watch App`** as `largestProcess` and records a `reason` on the Trio process entry (exact strings are diagnostic metadata per event):

| File | Trio `reason` (process entry) | Notes (from the JSON body) |
|------|-------------------------------|----------------------------|
| [JetsamEvent-2026-04-01-143500.ips](JetsamEvent-2026-04-01-143500.ips) | `per-process-limit` | `active`; `rpages` ≈ **19465** (~304 MiB at 16 KiB pages) — detailed in **00** § 4 |
| [JetsamEvent-2026-04-03-164956.ips](JetsamEvent-2026-04-03-164956.ips) | `highwater` | `active` / `frontmost`; `rpages` **21356** |
| [JetsamEvent-2026-04-03-165709.ips](JetsamEvent-2026-04-03-165709.ips) | `per-process-limit` | Trio entries include `per-process-limit` (this snapshot's `processes` array can list Trio more than once across generations; treat the emitted `reason` as authoritative per line) |

**Validation protocols** in **00 / 01 / 02** check **both** `per-process-limit` and `highwater` because **both** have been observed in captured diagnostics. **03** keeps finer **category attribution** (e.g. spike vs steady resident as the dominant trigger) as an open question — reason strings alone do not replace allocation profiling.

---

## B5 — Foreground-open / jetsam validation (closure)

**Status:** **Closed — conclusive — 2026-04-08 21:33 CEST.**

The **10× Mac-tethered** attempt protocol described in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) § **B5** / **§ Validation** is **waived** as **infeasible** (reliable **watch↔Mac** tether for scripted repeats not practical for owner validation). **Substitute evidence accepted:** **10× untethered** session **S2** (**2026-04-08**), attempt matrix rows **2–11**, **Better Stack** corroboration, **no** new Watch diagnostic exports — per implementation log **2026-04-08 21:33 CEST** and **02** § **B5 — Mac-tether waiver**.

---

## Changelog

### v1.14 (2026-04-08 21:54 CET)

- **§ B0 exit gate heading:** Clarified **B2** / **new** B3-class work vs **closed** initiative; avoids implying **B3** (shipped) is still gated.

### v1.13 (2026-04-08 21:45 CET)

- **§ B0 exit gate:** **Closed** for watch-launch-stability — pointer to **02** implementation log **2026-04-08 21:45 CET**; **Until** paragraph scoped to future / re-opened work and clarified vs shipped **B3**. **§ Pre-B3 notes:** **B0 closure** bullet (chart A/B deferred; assumption restatement). **§ B6 field status:** Wording updated now that **B0** / **B5** are **closed**. **Default Path B assumption:** Tense updated — **B0** closed **2026-04-08 21:45 CET**.

### v1.11 (2026-04-08 21:33 CEST)

- **§ B5 closure:** **Mac-tether** protocol **waived**; **untethered** **S2** **10×** accepted as **conclusive**; cross-ref **02** implementation log **2026-04-08 21:33 CEST**.

### v1.10 (2026-04-08 18:02 CEST)

- **B6 field status:** TestFlight **153** deployed; resident samples visible in aggregation (hot-tier spot-check); **B0** clause **2** wording updated now that **B6** is field-shipped on TF/sandbox.

### v1.9 (2026-04-08 13:05 CEST)

- **B6 sampling cap:** **Six** listed checkpoints → **at most six** emissions per activation (was seven); aligned with code **`maxSamplesPerActivation = 6`**.

### v1.8 (2026-04-08 12:55 CEST)

- **B6 `hk_batch`:** Sampling bullet clarifies **process-scoped** line **without** **`activation_seq`** when the first qualifying batch occurs **before** a startup sequence exists; still **one `hk_batch` per process** (code + **02** aligned).

### v1.7 (2026-04-08 12:40 CEST)

- **B6 rollout:** **TestFlight / sandbox receipt** — default **on**; **production App Store** — default **off** unless **`UserDefaults`** opt-in. Aligns implementation with TF field measurement (no separate toggle required for TF).

### v1.6 (2026-04-08 11:17 CET)

- **B6:** External review — **`hk_batch`** throttle fixed to **first per process** (removed per-activation alternative). **`activation_seq`:** **required** when activation context exists; optional only for process-scoped-outside-activation samples. **`first_main_view`** wording softened (root-view appearance / first-frame proxy). Cross-ref **02** § **B6**.

### v1.5 (2026-04-08 11:10 CET)

- **B6:** External review — pin metric to **`TASK_VM_INFO.phys_footprint` → `phys_footprint_mib` (MiB only)**; finalize **`event=watch_resident_sample`**; add **rollout** (default **off** in App Store Release unless explicitly enabled); **hard sampling budget** (one per checkpoint per `activation_seq`, max seven per activation; **hk_batch** / **chart_visible** throttles); sharpen **checkpoint semantics** (deferred fire vs first apply vs post-flush). **B0** equivalence wording updated to name **TASK_VM_INFO**.

### v1.4 (2026-04-08 10:24 CET)

- **B6 — Field resident memory telemetry:** New § for optional **Path B** in-process **task_info**-backed resident samples via **`WatchLogger`** (not a new “Path C”). Links **B0** clause **2**, checkpoint alignment with **03**, spam control, transport delay caveat. **Document map** → **02** lists **B0–B6**.

### v1.3 (2026-04-06 15:48 CET)

- **Pre-B2 gate:** **Owner** (**Charlie Chrisman**) and **date decided** (**2026-04-06**) filled; gate paragraph updated so empty-row blocker is **historical**. **Pre-B2 table** last row records sign-off; **B2** may proceed per **02** sequencing and acceptance.

### v1.2 (2026-04-03 22:15 CET)

- **Pre-B2 table:** Strengthened **Owner / date decided** row from "TBD" to an explicit hard blocker with ⚠️ marker. Relabeled the **Default Path B assumption** paragraph as a **hypothesis, not a concluded fact**, with explicit cross-reference to doc 03's #1/#2 primary consumer ranking. Added a sentence making clear that **B0 is the validation checkpoint for this hypothesis** and that contradicting B0 evidence reopens the upstream trimming row before B2 is considered done.
- **B0 exit gate:** Added a closing paragraph linking B0 back to the canonical-representation hypothesis so the gate's purpose is unambiguous.

### v1.1 (2026-04-03 21:56 CET)

- **Jetsam diagnostics:** Documented **three** archived `.ips` files (`2026-04-01` + two `2026-04-03`); **`highwater`** is now **on-disk** in `JetsamEvent-2026-04-03-164956.ips`, not report-only. Replaced the prior "single `.ips` / reports" caveat with a **table** and clarified validation + **03** open questions.

### v1.0 (2026-04-03 21:39 CET)

- Initial Path B design scaffold: document map, Path B intent pointer, **B0 exit gate** closure rule, **pre-B2 decision table**, pre-B3 notes, `highwater` vs captured diagnostic caveat. Created per review feedback to give Cursor/owners a single Path B design anchor before B2/B3.