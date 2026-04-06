Here's the revised doc:

---

# Watch foreground memory-hardening — design (Path B)

**Version:** v1.3
**Created:** 2026-04-03 21:39 CET
**Last updated:** 2026-04-06 15:48 CET
**Status:** Final

**Purpose:** Path **B** design anchor for implementation — **decisions**, **gates**, and **constraints** that are not fully specified in the investigation artifact (**03**) or the high-level intent blurb in **01**. Executable phases remain in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md).

---

## Document map

| Doc | Role |
|-----|------|
| [00-investigation-findings.md](00-investigation-findings.md) | Findings, track positioning, validation outcomes |
| [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md) | **Path A** full spec; **Path B** intent summary |
| [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) | **A1–A3** and **B0–B5** tasks, acceptance, sequencing |
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

## B0 exit gate (before starting B2 or B3)

**Authoritative checklist:** [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) § **B0** (this doc does not duplicate the full steps).

**Closure rule:** B0 is **complete** when all of the following are true:

1. **Device run recorded** with notes tied to a specific Trio/watchOS build, covering at least these **checkpoints** from doc 03's instrumentation outline: cold launch, first frame, after deferred watch-state fires, after first large WC payload handled (counts/metadata only — no full payload logs), +10s HealthKit path, +10s log flush path.
2. **Resident or Instruments evidence** at each checkpoint: either a **numeric sample** (e.g. memory gauge / `task_vm_info` / Instruments mark) **or** a written **"infeasible on this device/OS, because …"** with reviewer sign-off.
3. **Chart isolation:** at least one **A/B** or **feature-flag** comparison that **isolates chart cost** (per doc 03), **or** an **explicit written decision** to defer that A/B with rationale and a named follow-up date/owner.

Until this gate is satisfied, **B2** and **B3** remain **planning-only** (implementation prompts must not start them as "greenfield" without a written waiver in the implementation log stating which clause is waived and why).

**B0 is also the primary validation checkpoint for the canonical-representation hypothesis in the pre-B2 table below.** If B0 data shows that a single canonical 288-point representation still produces resident pressure near jetsam thresholds, the upstream trimming row in that table must be revisited before B2 implementation proceeds.

---

## Pre-B2 decision gate (blocking)

**B2** requires a **product-bounded** history policy. Before B2 implementation starts, **fill the table below** (or link an ADR / ticket that contains the same fields). The **Owner and date decided** row was a **hard blocker** while empty — **filled 2026-04-06** (**Charlie Chrisman**); do not start B2 coding without the policy rows above matching your intent (or an explicit superseding ADR).

**Default Path B assumption (hypothesis, not a concluded fact):** retaining up to **288** glucose points on-watch is acceptable *if* they exist as a **single canonical long-lived representation**. The primary memory risk is **not the raw point count by itself**, but **duplicate stacked representations, payload/string duplication, and eager chart/render/logging work** around that data. Doc 03 ranks the 288-point payload as a "Primary" consumer (#1 and #2 in the ranked list) — that ranking reflects the combined effect of duplication and downstream work, not an assertion that the canonical array size alone is the jetsam trigger. **B2** should therefore target **ownership and duplication first**. **This assumption is what B0 is instrumenting to validate.** If B0 evidence contradicts it — i.e., a single canonical 288-point representation still keeps resident footprint near jetsam thresholds even after B1/B3/B4 are applied — the upstream trimming decision below must be reopened before B2 is considered done.

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

## Changelog

### v1.3 (2026-04-06 15:48 CET)

- **Pre-B2 gate:** **Owner** (**Charlie Chrisman**) and **date decided** (**2026-04-06**) filled; gate paragraph updated so empty-row blocker is **historical**. **Pre-B2 table** last row records sign-off; **B2** may proceed per **02** sequencing and acceptance.

### v1.2 (2026-04-03 22:15 CET)

- **Pre-B2 table:** Strengthened **Owner / date decided** row from "TBD" to an explicit hard blocker with ⚠️ marker. Relabeled the **Default Path B assumption** paragraph as a **hypothesis, not a concluded fact**, with explicit cross-reference to doc 03's #1/#2 primary consumer ranking. Added a sentence making clear that **B0 is the validation checkpoint for this hypothesis** and that contradicting B0 evidence reopens the upstream trimming row before B2 is considered done.
- **B0 exit gate:** Added a closing paragraph linking B0 back to the canonical-representation hypothesis so the gate's purpose is unambiguous.

### v1.1 (2026-04-03 21:56 CET)

- **Jetsam diagnostics:** Documented **three** archived `.ips` files (`2026-04-01` + two `2026-04-03`); **`highwater`** is now **on-disk** in `JetsamEvent-2026-04-03-164956.ips`, not report-only. Replaced the prior "single `.ips` / reports" caveat with a **table** and clarified validation + **03** open questions.

### v1.0 (2026-04-03 21:39 CET)

- Initial Path B design scaffold: document map, Path B intent pointer, **B0 exit gate** closure rule, **pre-B2 decision table**, pre-B3 notes, `highwater` vs captured diagnostic caveat. Created per review feedback to give Cursor/owners a single Path B design anchor before B2/B3.