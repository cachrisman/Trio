# FPU / Nightscout Reporting — Trio Implementation Plan (Tier 1)

**Version:** v1.1  
**Status:** Draft plan (revised after cursor review)  
**Created:** 2026-07-09 12:34 CEST  
**Last updated:** 2026-07-09 13:22 CEST

Companion to `fpu-nightscout-reporting-investigation.md` (v2) and `fpu-nightscout-reporting-nightscout-nextjs-impl-plan.md`.

---

## Goal

Make FPU carb-equivalent uploads machine-distinguishable and linkable in Nightscout, and fix the live upload-status bookkeeping bug — **without** changing the upload `id`, COB semantics, or Nightscout deletion.

This is **Design A** from the investigation: preserve the shared FPU `id` (needed for one-call batch delete), add `isFPU`/`fpuID` metadata, and fix bookkeeping by matching FPU rows on `fpuID` instead of `id`.

---

## Design decisions (locked)

1. **Do not change the FPU upload `id`.** It stays `= fpuID`. The shared value is intentional — `deleteCarbs(withId:)` removes all chunks of a meal in one call via `find[id][$eq]=<fpuID>`. Changing it would break deletion for multi-chunk meals.
2. **No Nightscout deletion / `NightscoutAPI` change.** Deletion already works and is out of scope.
3. **Metadata is additive.** Nightscout upserts on `created_at`+`eventType` and passes unknown fields through, so adding `isFPU`/`fpuID` enriches existing/new documents and cannot duplicate or overwrite them.

---

## Changes

### 1. `Trio/Sources/Models/NightscoutTreatment.swift`

- Add a new stored property: `var isFPU: Bool?`.
- Add `case isFPU` to the `CodingKeys` enum. (`fpuID` is already a property and already in `CodingKeys`; no change needed there.)
- Synthesized `encodeIfPresent` will omit both when `nil`, so non-FPU/non-linked treatments are unchanged on the wire.

### 2. `Trio/Sources/APS/Storage/CarbsStorage.swift`

Update the two upload builders to populate the new metadata. **Keep the `id` arguments exactly as they are today.**

- `getCarbsNotYetUploadedToNightscout()` — in the `NightscoutTreatment(...)` init:
  - `isFPU: false` (harmless/explicit; enables `isFPU == false` queries).
  - `fpuID: result.fpuID?.uuidString` (populates the link on parent meals that have fat+protein; `nil` → omitted for plain carbs).
  - `id: result.id?.uuidString` — **unchanged** (per-entry UUID).
- `getFPUsNotYetUploadedToNightscout()` — in the `NightscoutTreatment(...)` init:
  - `isFPU: true`.
  - `fpuID: result.fpuID?.uuidString` (same shared meal ID; now also carried in its own field).
  - `id: result.fpuID?.uuidString` — **unchanged** (shared `fpuID`, required for batch delete).

> After this, an FPU treatment carries `id == fpuID == <shared>` plus `isFPU: true`. The parent carries its own `id`, `isFPU: false`, and `fpuID == <shared>`. Grouping by `fpuID` links them.

### 3. `Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift` — fix bookkeeping (the live bug)

`updateCarbsAsUploaded(_ treatments:)` currently marks rows with `NSPredicate(format: "id IN %@", ids)`. FPU treatments send `id == fpuID`, but FPU `CarbEntryStored` rows have their own `id` (with `fpuID` in a separate attribute), so they never match and never flip `isUploadedToNS`.

Fix by partitioning treatments using the new `isFPU` flag and matching each group on the correct attribute:

- Non-FPU treatments (`isFPU != true`): match `CarbEntryStored` by `id IN <their ids>` (unchanged).
- FPU treatments (`isFPU == true`): match `CarbEntryStored` by **`date IN <their createdAt values>` AND `isFPU == true`**.
- Set `isUploadedToNS = true` on the union and save.

**Why `date`, not `fpuID`, for FPU rows (cursor-review catch):** all chunks of a meal share one `fpuID`, so matching by `fpuID` would mark *every* chunk of the meal uploaded — even a sibling chunk that was **not** in this POST batch (e.g. dropped at the ~24 h window's lower bound, or any future partial-batch path). That silently flips `isUploadedToNS = true` on a row that was never sent, with no retry. Each treatment's `createdAt` is exactly `result.date` for the row it came from, so `date IN <uploaded createdAts>` marks a **1:1** set — precisely the rows that shipped. In practice FPU chunks are future-dated and always co-upload, so today the two approaches behave the same; `date` matching is the robust choice that survives the edge and any future change.

Implementation notes:
- The two upload calls are already separate (`uploadCarbs(getCarbs…)` then `uploadCarbs(getFPUs…)`), so each `updateCarbsAsUploaded` batch is homogeneous. Partitioning still keeps the function correct if that ever changes.
- The treatment `createdAt` values are the same in-memory `Date` objects as the rows' `date` (no serialization between fetch and mark), so `date IN` equality holds. Mirror the existing `NSPredicate(format: "date IN %@", …)` style.
- Guard against `nil` ids / dates (skip them), as today.
- If you prefer defense-in-depth, `fpuID IN <ids> AND date IN <createdAts> AND isFPU == true` is equivalent-or-tighter; `date` alone is sufficient.

---

## Explicitly out of scope (per investigation corrections)

- Changing the FPU upload `id` to a per-entry UUID.
- Any change to `deleteCarbs` / `HistoryStateModel+Carbs` / `NightscoutAPI`.
- Tier 2/3/4 ideas (`notes`/`foodType` labels, not-uploading FPU, eCarbs `duration`).
- Importer changes (`JSONImporter` still skips FPU; round-trip restore is separate future work).
- **Pre-existing upload-timing behavior** (do not "fix" as part of Tier 1): FPU chunks upload immediately rather than at their scheduled time (no `date <= now` filter), and the ~24 h `date >= oneDayAgo` upload window drops entries older than a day. These are unchanged by Tier 1; the bookkeeping fix only stops the re-upload loop, it does not alter which entries are eligible.

---

## Tests

- **Upload payload shape** (`CarbsStorageTests` or a new NS-upload test):
  - Parent meal with fat+protein → treatment has `isFPU == false`, `fpuID == <shared>`, `id == entry UUID`, `fat`/`protein` populated.
  - FPU chunk → treatment has `isFPU == true`, `fpuID == <shared>`, `id == <shared>`, `carbs == equivalent`, `fat == 0`, `protein == 0`.
  - Plain carb entry (no fat/protein) → `isFPU == false`, `fpuID` absent, otherwise unchanged. (Explicitly assert plain carbs still encode as before — `isFPU:false` is a new key on every carb correction.)
- **Encoding**: `nil` `isFPU`/`fpuID` are omitted from JSON (no regression for existing consumers). No custom `Codable` exists today, so synthesized encoding suffices; if any path later *decodes* treatments, add decode coverage for the new key.
- **Bookkeeping — single-chunk**: after an FPU upload, the corresponding FPU row flips `isUploadedToNS = true`; `fpusNotYetUploadedToNightscout` no longer returns it (no re-upload loop).
- **Bookkeeping — multi-chunk (the important one)**: a 2–3 chunk meal (fat+protein large enough to split). Assert **each chunk's** `isUploadedToNS` independently after upload. Then simulate a partial batch (only a subset of the meal's chunks passed to `updateCarbsAsUploaded`) and assert the **un-sent** chunk is still `isUploadedToNS == false` — this is the regression the `date`-based match (vs `fpuID`) prevents.

---

## Verification (manual)

1. Log a meal with fat + protein on a test build; wait for the FPU delay.
2. Query NS/Mongo (or nightscout-nextjs) for the treatments: confirm parent has `isFPU:false` + `fpuID`, FPU chunk(s) have `isFPU:true` + `fpuID`, grouped by the shared `fpuID`.
3. Confirm the FPU chunk is **not** re-POSTed on subsequent upload cycles (check that `isUploadedToNS` stuck).
4. Delete the meal in Trio History → confirm all chunks disappear from NS (batch delete still works, since `id == fpuID` was preserved).

---

## Patch workflow (Trio-dev tooling)

1. Make edits on a `feature/<name>` branch in the `Trio` worktree; commit there.
2. From `Trio-dev` (on `dev`): `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>` for the patch that owns the NS upload path.
3. `./scripts/patch-test.sh` (includes the deletion-footprint audit).
4. Static review of the full diff vs base (deletions especially) before any build.

---

## Risk

Low. Additive fields (omitted when `nil`), no change to `id`/deletion/COB, and the one behavioral change (bookkeeping) strictly reduces redundant uploads. Main review focus: the `updateCarbsAsUploaded` predicate change (ensure FPU rows match by `fpuID` and non-FPU rows still match by `id`).

---

## Changelog

### v1.1 (2026-07-09 13:22 CEST)
- Revised after a cursor review of the plan:
  - **Bookkeeping now matches FPU rows by `date` (createdAt), not `fpuID`** — matching by `fpuID` would over-mark a meal's chunks (all share one `fpuID`) if only a subset was POSTed. `date IN <uploaded createdAts>` marks a 1:1 set. This is the one substantive change.
  - Added multi-chunk / partial-batch bookkeeping tests and a plain-carb encoding assertion.
  - Added out-of-scope note for pre-existing upload-timing behavior (immediate upload of future-dated chunks; ~24 h window) so they aren't conflated with the bookkeeping fix.
  - Noted decode coverage is only needed if a path decodes treatments.

### v1 (2026-07-09 12:34 CEST)
- Initial Trio Tier 1 implementation plan (Design A): add `isFPU`, populate `fpuID`, keep shared FPU `id`, fix `updateCarbsAsUploaded` bookkeeping. Reason: turn the corrected investigation into an actionable, minimal patch scoped to 3 files.
