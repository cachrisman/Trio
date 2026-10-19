# FPU / Nightscout Reporting — nightscout-nextjs Implementation Plan (Tier 1 support)

**Version:** v1  
**Status:** Draft plan (no code investigation performed — layout only)  
**Created:** 2026-07-09 12:34 CEST  
**Last updated:** 2026-07-09 12:34 CEST

Companion to `fpu-nightscout-reporting-investigation.md` (v2) and `fpu-nightscout-reporting-trio-impl-plan.md`.

> This plan describes what would change in `nightscout-nextjs` to *support and use* the `isFPU` / `fpuID` metadata Trio's Tier 1 adds. It is written from the investigation + the nightscout-nextjs reviewer's notes, **without** a fresh code audit — file paths are indicative and should be confirmed against the repo.

---

## Context

- Nightscout (legacy and `nightscout-nextjs`) upserts treatments on **`created_at` + `eventType`** and **passes unknown fields through** to storage. So Trio's new `isFPU`/`fpuID` fields are **stored automatically with no server change**.
- Therefore this plan is about **formalizing** support (schema docs/validation, fixtures, tests) and **optionally using** the metadata (FPU-aware carb reporting/filters). None of it blocks Trio's Tier 1.

---

## Change set

### A. Formalize the fields (low effort, recommended)

Goal: make `isFPU`/`fpuID` first-class known fields rather than incidental passthrough, so they're documented, validated, and covered by tests.

1. **Treatment schema / captured-fields note** (`lib/schemas/treatment.ts` or equivalent):
   - Add `isFPU` (boolean, optional) and `fpuID` (string, optional) to the recognized/pass-through Trio fields alongside the already-documented `targetTop`/`targetBottom`/`fat`/`protein`/`foodType`/`id`.
   - Keep them optional and non-authoritative (do not reject treatments lacking them).
2. **Fixtures**: add captured Trio FPU payloads (parent with `isFPU:false`+`fpuID`, chunk with `isFPU:true`+`fpuID`, `fat:0`,`protein:0`) to the treatment fixtures used by tests.
3. **Tests**: extend the existing passthrough tests (which already pin `fat`/`protein`/`foodType`/`id`) to assert `isFPU`/`fpuID` round-trip through validation and storage unchanged, and that upsert-by-`created_at`+`eventType` still stores the two chunks of a meal as distinct documents.

### B. FPU-aware carb reporting / filtering (optional, medium effort)

Goal: address the double-counting caveat — NS report/aggregation code sums **all** `treatment.carbs`, so parent carbs + FPU-equivalent carbs read as inflated totals.

Options (pick per product intent; not required for Trio Tier 1):

1. **Filter helper**: add a shared predicate (e.g. `isFPUTreatment(t) => t.isFPU === true` with fallback heuristics) and expose an option in carb-sum / COB / day-to-day style aggregations to **exclude** FPU-equivalent carbs from "eaten carbs" totals while still counting them for COB where appropriate.
2. **Grouping/link surface**: where treatments are listed or charted, allow grouping delayed chunks with their parent via shared `fpuID` (e.g. a "fat/protein equivalent" affordance), without changing the stored `eventType`.
3. **Display label** (if a UI treatment renderer exists): optionally badge `isFPU:true` carb corrections distinctly (e.g. "FPU 16 g") instead of a plain carb label. This is the nextjs analog of the Tier 2 idea and is **explicitly optional**.

### C. Backward/forward compatibility guarantees (verification, not code)

- Treatments **without** `isFPU`/`fpuID` (older Trio, other apps, AAPS) must behave exactly as today — new logic must treat missing fields as "not FPU / not linked."
- No change to upsert identity (`created_at`+`eventType`).
- No new required fields; all additions optional.

---

## Out of scope

- Any `isFPU`/`fpuID` write path (Nightscout does not author these — Trio does).
- AAPS `duration` eCarbs handling, `preBolus` changes, or round-trip export of OpenAPS FPU semantics.
- Changing how Trio uploads (covered by the Trio plan).

---

## Tests / verification summary

- Passthrough test: POST a Trio parent+FPU pair → both stored with `isFPU`/`fpuID` intact; two distinct documents (distinct `created_at`).
- Re-POST test: re-POST the same FPU chunk (same `created_at`,`eventType`) → upsert updates the same document (no duplicate) — mirrors Trio's re-upload behavior pre-bookkeeping-fix and confirms the server side is robust to it.
- (If B implemented) Aggregation test: a meal's parent + FPU carbs are not double-counted in the "eaten carbs" total when FPU filtering is enabled; totals unchanged when disabled/absent.

---

## Sequencing with Trio

- **A (formalize fields)** can land independently and before/after Trio Tier 1 — it only affects docs/validation/tests, and storage already works.
- **B (reporting)** is only worthwhile once real Trio `isFPU`/`fpuID` data is flowing; land after Trio Tier 1 ships and data is observable.

---

## Changelog

### v1 (2026-07-09 12:34 CEST)
- Initial nightscout-nextjs support plan for Trio's `isFPU`/`fpuID` Tier 1 metadata: formalize passthrough fields + fixtures + tests (recommended), optional FPU-aware carb reporting/filtering to avoid double-counting, and compatibility guarantees. Reason: document the (minimal) NS-side work needed to fully support the Trio changes; storage requires no change. No fresh code audit performed — file paths indicative.
