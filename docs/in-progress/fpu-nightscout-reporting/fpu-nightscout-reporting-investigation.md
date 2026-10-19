# FPU / Nightscout Treatment Reporting — Investigation

**Version:** v2.1  
**Status:** Investigation complete; corrected after code re-verification + nightscout-nextjs review + cursor review  
**Created:** 2026-07-09 10:16 CET  
**Last updated:** 2026-07-09 13:22 CEST

---

## Summary

Trio distinguishes **meal entries** from **delayed fat/protein carb-equivalents (FPU)** internally via `isFPU` and `fpuID`, and shows them differently in the History UI. Both types upload to Nightscout as `eventType: "Carb Correction"` with no distinguishing metadata. **Nightscout cannot tell them apart today.**

Parent meals **do** upload `fat` and `protein` correctly. FPU delayed chunks upload with `carbs` = the equivalent grams and `fat`/`protein` fields **present but `0`** (they are emitted, not omitted — the stored FPU row has `fat=0`, `protein=0`), and carry no `isFPU` or `fpuID` metadata.

The one **live, user-visible bug** in the current path is upload-status bookkeeping (FPU rows are never marked uploaded → re-uploaded every cycle). The originally-suspected "duplicate `id` overwrites chunks in Nightscout" is **not a real server bug** (see Correction 1).

---

## Observed data (user example, 2026-07-09 breakfast)

### Parent meal (07:53 local)

```json
{
  "eventType": "Carb Correction",
  "created_at": "2026-07-09T05:53:39.184Z",
  "carbs": 45,
  "fat": 20,
  "protein": 25,
  "enteredBy": "Trio",
  "id": "A46A6283-33DD-4874-AAE4-7DF7A0AD70A8",
  "foodType": "",
  "utcOffset": 0
}
```

### FPU delayed equivalent (08:53 local, +60 min)

```json
{
  "eventType": "Carb Correction",
  "created_at": "2026-07-09T06:53:39.184Z",
  "carbs": 16,
  "fat": 0,
  "protein": 0,
  "enteredBy": "Trio",
  "id": "FA5D9A31-2DD1-4D58-AA61-D0BF8C889D67",
  "utcOffset": 0
}
```

In Trio's History UI the second entry appears as **"Fat / Protein 16 g"** (orange icon). That label refers to **carb-equivalent grams** from FPU conversion, not raw fat/protein grams.

The +60 minute offset matches Trio's default FPU delay setting. This particular meal produced a **single** 16 g chunk (< 33 g), so no multi-chunk behavior is exercised here.

> Note: the observed FPU JSON's `id` (`FA5D9A31…`) is the meal's shared `fpuID`, not the FPU row's own entry UUID. All chunks of a meal share this value by design (see Correction 1).

---

## Internal Trio model

Trio stores two kinds of `CarbEntryStored` rows, linked by `fpuID`:

| Type | `isFPU` | Stored values | History UI |
|------|---------|---------------|------------|
| **Meal entry** | `false` | Actual carbs + fat + protein | "Carbs N g" (yellow) |
| **Delayed equivalent** | `true` | Carb-equivalent grams only (`fat=0`, `protein=0`) | "Fat / Protein N g" (orange) |

### FPU generation (`CarbsStorage.processFPU`)

Generation is gated **only on stored macros** — `saveCarbEquivalents` runs `processFPU` whenever a stored meal entry has `fat > 0 || protein > 0`. The `useFPUconversion` setting governs UI entry paths (Add Carbs, presets, etc.), **not** the storage pipeline. So any stored entry with fat/protein produces FPU chunks:

1. A parent carb entry is stored with actual macros (own `id` UUID; `fpuID` set to the shared meal `fpuID` when fat & protein are present).
2. Fat/protein are converted to carb equivalents: `(protein×4 + fat×9) / 10 × adjustment`, floored (`Int()`), capped at 99 g, split into up to 3 entries (max 33 g each, min 10 g total guard).
3. Delayed entries are scheduled: first at `delay` minutes (default 60), then spaced by `minuteInterval` (default 30).
4. Generated FPU entries have `isFPU = true`, `carbs` only (`fat=0`, `protein=0`), their **own** `id` UUID, and share the parent's `fpuID` (`commonFPUID`).

Relevant source: `Trio/Sources/APS/Storage/CarbsStorage.swift`

### History display

History distinguishes entries via `meal.isFPU`:

- `Trio/Sources/Modules/History/View/HistoryRootView+Meals.swift`

---

## Nightscout upload behavior

Both carb and FPU upload paths use `eventType: .nsCarbCorrection` ("Carb Correction"). They are uploaded via **two separate** `uploadCarbs(_:)` calls (`NightscoutManager.swift`), each followed by its own `updateCarbsAsUploaded` pass.

### Regular carbs (`getCarbsNotYetUploadedToNightscout`)

- Uploads `carbs`, `fat`, `protein`, `notes`, `id` (entry UUID).
- Also sets `foodType: result.note` (same source as `notes` — redundant; see Correction 3).
- Does **not** set `isFPU`, and does **not** populate the `fpuID` JSON field.

### FPU equivalents (`getFPUsNotYetUploadedToNightscout`)

- Uploads `carbs` (equivalent grams), and `fat`/`protein` **as `0`** (fields are emitted, mapped from `result.fat`/`result.protein`, which are stored `0`).
- Uses `eventType: .nsCarbCorrection` — same as regular carbs.
- Sets `id: result.fpuID?.uuidString` — the **shared** meal link ID, not the FPU row's own UUID. This is **intentional**: the batch-insert comment says "all fpus should only get ONE id per batch insert to be able to delete them referencing the fpuID," and deletion queries by it (see below).
- Does **not** set `isFPU` or populate the `fpuID` JSON field.

### `NightscoutTreatment` struct

- Has `fpuID` in `CodingKeys` (encoded via synthesized `encodeIfPresent`) but it is never populated on upload.
- Has **no** `isFPU` field at all.
- `Equatable`/`Hashable` are defined on `createdAt` **alone**.

Relevant source: `Trio/Sources/Models/NightscoutTreatment.swift`, `Trio/Sources/APS/Storage/CarbsStorage.swift`

### How Nightscout stores/dedups treatments (confirmed)

Treatment upload is a plain `POST /api/v1/treatments` with no `identifier` field. Nightscout **upserts by `created_at` + `eventType`**, not by the client `id` field (confirmed in `cgm-remote-monitor/lib/server/treatments.js` and mirrored by `nightscout-nextjs`). Unknown fields (`fat`, `protein`, `foodType`, `id`, and any new `isFPU`/`fpuID`) pass through to storage as-is. Consequences:

- FPU chunks at distinct `created_at` values are stored as **distinct documents** even though they share the same client `id`. They do **not** overwrite each other.
- Re-uploading the same FPU row (same `created_at`) **upserts the same document** — so the bookkeeping bug below produces wasted POSTs, not visible duplicates.

### Pre-existing upload-timing behavior (out of Tier 1 scope, noted for accuracy)

- **FPU chunks upload immediately, not at their scheduled time.** `fpusNotYetUploadedToNightscout` has no `date <= now` filter, so all pending (future-dated) FPU rows POST on the next upload cycle after the meal is saved — not when the +60/+90/+120 min slot arrives. NS therefore receives future-dated carb corrections up front. Tier 1 metadata does not change this.
- **~24 h upload window.** Both carb and FPU upload predicates require `date >= oneDayAgo`. An entry older than ~24 h still flagged `isUploadedToNS == false` is never uploaded. This is unrelated to the bookkeeping bug (Correction 2) and is **not** fixed by Tier 1 — don't conflate the two.

### Local oref export (contrast)

OpenAPS carb history JSON **does** include `isFPU` via `CarbEntryStored` encoding (`Model/Helper/CarbEntryStored+helper.swift`, `container.encode(isFPU…)`). The metadata exists locally but is dropped at the Nightscout upload layer.

### Import from Nightscout

`JSONImporter.importCarbHistory` explicitly **skips** FPU entries (filter `(isFPU ?? false) == false`). This runs **once at onboarding** (`importCarbHistoryIfNeeded`, 24 h window) — it is not a continuous round-trip sync. Even if `isFPU` were added to NS uploads, restoring FPU rows would need additional importer work.

---

## Bugs in the current upload path (corrected)

### Correction 1 — "FPU upload ID collision" is NOT a real Nightscout bug

The v1 investigation claimed the shared FPU `id` causes chunks to overwrite each other in Nightscout. **This is incorrect**, on two independent grounds, both now verified:

- **Server side:** Nightscout upserts on `created_at` + `eventType`, not on the client `id`. Chunks have distinct timestamps → distinct documents. (Confirmed against `cgm-remote-monitor` and `nightscout-nextjs`.)
- **Trio side, by design:** the shared `id` is deliberate. `saveFPUToCoreDataAsBatchInsert` assigns one `commonFPUID` per meal specifically so deletion can remove all chunks in one call, and `deleteCarbs(withId:)` issues `find[id][$eq]=<fpuID>` (`NightscoutAPI.swift`). Changing FPU uploads to per-entry IDs would **break** this one-call batch delete.

**Implication for Tier 1:** do **not** change the FPU upload `id`, and no deletion rewrite is required. (This removes two files and one "Medium" step from the v1 plan.)

### Correction 2 — Upload-status bookkeeping is the real, live bug (severity raised)

`updateCarbsAsUploaded` marks rows via `NSPredicate(format: "id IN %@", ids)` where `ids` are the uploaded treatments' `id`s (`NightscoutManager.swift`). For FPU treatments `treatment.id == fpuID`, but the FPU `CarbEntryStored` row's `id` is its **own** UUID with `fpuID` in a separate attribute. **No FPU row ever matches**, so `isUploadedToNS` stays `false`, and the `fpusNotYetUploadedToNightscout` predicate (`isUploadedToNS == false AND isFPU == true`) re-selects them **every upload cycle**.

Net effect: FPU rows are re-POSTed indefinitely (server-deduped by `created_at`, so invisible to the user — which is why only one entry appears). This is the one behavior Tier 1 must fix, and it is fixable **without** touching the upload `id`: mark FPU rows by `fpuID`/`isFPU` rather than by `id`.

### Correction 3 — `foodType` and `notes` both map to `result.note`

Both upload paths set `notes: result.note` and `foodType: result.note` — the same source. For FPU rows `note == nil`, so both are omitted. (Only relevant if a human-readable label is ever desired; not part of Tier 1.)

---

## Ecosystem context

- **Nightscout** accepts `fat` and `protein` on `Carb Correction` treatments. The Care Portal can display `carbs/protein/fat` when carbs > 0. An FPU chunk with `carbs:16, fat:0, protein:0` renders as a plain **"16 g"** carb correction — exactly the ambiguity described.
- **NS built-in reports** (e.g. Day-to-day) sum **all** `treatment.carbs` with no FPU awareness. Parent carbs + FPU-equivalent carbs therefore read as double-counting in NS reports today. Tier 1's `isFPU` field makes consumer-side filtering **possible** but does not itself change any NS built-in report.
- **AAPS** uses `duration` (minutes) on `Carb Correction` for extended carbs (eCarbs) — a different model than Trio's point-in-time FPU chunks. AAPS does not use an `isFPU` field in the standard NSClient schema.
- **Nightscout `preBolus`** splits a bolus treatment into a delayed second carb entry server-side — conceptually similar timing, but tied to bolus event types, not standalone `Carb Correction` rows.
- **iAPS** recently fixed uploading fat/protein on parent entries (they had been dropped); FPU spread entries remain `fat:0 / protein:0` and are unaffected.

Trio's FPU chunks are intentionally **future-dated carb corrections** for COB timing. Uploading them as `Carb Correction` is semantically correct for loop/COB purposes; the gap is **missing metadata** to distinguish them from immediate carbs. `isFPU`/`fpuID` are a **Trio-specific extension** — compatible with Nightscout's passthrough storage, but not a standard NS ecosystem convention.

---

## Proposal — Tier 1: minimal metadata (the plan being pursued)

**Goal:** Make FPU equivalents machine-distinguishable and linkable in Nightscout, and fix the live bookkeeping bug — without changing COB semantics, the upload `id`, or deletion.

**Recommended design (Design A — preserve shared `id` + batch delete):**

| Change | Detail |
|--------|--------|
| Add `isFPU: Bool?` to `NightscoutTreatment` | New field + `CodingKey`; `fpuID` field already exists |
| Populate `fpuID` JSON field on **both** parent and FPU uploads | Enables grouping/linking; the useful part of linking |
| Set `isFPU: true` on FPU uploads, `isFPU: false` on parent (optional) | Machine-distinguishable; parent flag is harmless/redundant |
| **Keep** FPU upload `id = fpuID` | Preserves one-call batch delete via `find[id][$eq]` — do **not** change |
| Fix `updateCarbsAsUploaded` bookkeeping | Mark FPU rows by `fpuID` (not `id`); this fixes Correction 2 |

**Not required for Tier 1** (contrary to v1): changing the FPU upload `id`, and any Nightscout deletion / `NightscoutAPI` change. Both are consequences of the misdiagnosed Correction 1 and are dropped.

**Example Mongo shape after Tier 1:**

```json
{
  "eventType": "Carb Correction",
  "carbs": 45, "fat": 20, "protein": 25,
  "isFPU": false, "fpuID": "abc-123",
  "id": "entry-uuid-1", "enteredBy": "Trio"
}
```

```json
{
  "eventType": "Carb Correction",
  "carbs": 16, "fat": 0, "protein": 0,
  "isFPU": true, "fpuID": "abc-123",
  "id": "abc-123", "enteredBy": "Trio"
}
```

MongoDB / nightscout-nextjs accept extra fields (passthrough). Nightscout UI will not label them "Fat / Protein" without custom work, but queries like `isFPU == true` and grouping by `fpuID` become possible, and reports can filter FPU carbs out of totals.

**Scope:** ~3 files, small patch, low risk. No Nightscout server changes required to *store* the metadata (nightscout-nextjs passes unknown fields through). A separate, optional nightscout-nextjs change can *formally support* and *use* the fields (see companion plan).

**Files (Trio):**

- `Trio/Sources/Models/NightscoutTreatment.swift`
- `Trio/Sources/APS/Storage/CarbsStorage.swift`
- `Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift`

See `fpu-nightscout-reporting-trio-impl-plan.md` and `fpu-nightscout-reporting-nightscout-nextjs-impl-plan.md` for step-by-step plans.

---

## Speculative future ideas (NOT being pursued)

These are recorded for context only. None are part of the current work.

- **Human-readable NS Care Portal label.** Set a standard `notes` (e.g. `"FPU equivalent (from fat/protein)"`) or `foodType: "FPU"` on FPU rows. Note FPU rows currently carry no `note`, so this needs populating at generation or upload; and `notes`/`foodType` currently share `result.note`. Tradeoff: visible in NS UI but may clutter.
- **Don't upload FPU equivalents.** Upload only the parent meal (carbs + fat + protein); keep FPU scheduling local. Cleaner NS history, but NS COB loses the delayed-absorption schedule and diverges from how the local loop uses FPU entries.
- **AAPS-style eCarbs.** Redesign FPU as a single extended `Carb Correction` with `duration` instead of 1–3 point-in-time entries. Closer to the cross-app NS delayed-carb convention, but a large Trio/OpenAPS behavior change.

---

## Implementation checklist (Tier 1, corrected)

| Step | Effort | Files |
|------|--------|-------|
| Add `isFPU` to `NightscoutTreatment` + populate `isFPU`/`fpuID` on upload | Small | `NightscoutTreatment.swift`, `CarbsStorage.swift` |
| Fix `updateCarbsAsUploaded` to mark FPU rows by `date` (1:1 with uploaded chunks; not `fpuID`) | Small | `NightscoutManager.swift` |
| Unit tests for upload payload shape + FPU upload-status marking | Small | `CarbsStorageTests` / NS upload tests |
| (nightscout-nextjs) document + test `isFPU`/`fpuID` passthrough | Small | see companion plan |
| (nightscout-nextjs, optional) FPU-aware carb totals in reports | Medium | see companion plan |

**Patch workflow:** Feature branch in `Trio` → `mid-stack-update.sh` on the patch that owns NS upload → `scripts/patch-test.sh`.

**Verification:** Static review of upload JSON shape; query NS/Mongo for `isFPU` + `fpuID` after a test meal with fat/protein; confirm FPU rows flip `isUploadedToNS = true` (no repeated re-uploads).

---

## Bottom line

- Parent meals **do** report fat/protein to Nightscout.
- FPU delayed chunks are reported as indistinguishable carb corrections — no `isFPU`, no populated `fpuID`.
- Trio's History UI distinction is driven by internal `isFPU`, which never reaches Nightscout.
- The **only live bug** is upload-status bookkeeping (Correction 2): FPU rows are never marked uploaded and re-POST every cycle (invisible due to server upsert-by-`created_at`).
- The v1 "ID collision/overwrite" concern is **not** real (Correction 1); the shared `id` is intentional for batch delete and must be preserved.
- **Tier 1 (Design A)** is the right first step: ~3 files, backward-compatible, machine-distinguishable, fixes the real bookkeeping bug, and requires no Nightscout server change to store the metadata.

---

## Changelog

### v2.1 (2026-07-09 13:22 CEST)
- Corrections from a cursor review of v2 (all verified against code):
  - Fixed FPU-generation wording: generation gates only on stored `fat/protein > 0` (`saveCarbEquivalents`), **not** on the `useFPUconversion` setting (which governs UI entry paths).
  - Added pre-existing upload-timing notes (FPU chunks upload immediately, not at scheduled time; ~24 h upload window) as explicit out-of-scope caveats so they aren't misread as fixed by Tier 1.
- No change to the core findings or Tier 1 design. Companion Trio plan updated to match FPU rows by `date` (not `fpuID`) for bookkeeping — see that doc's v1.1.

### v2 (2026-07-09 12:34 CEST)
- Corrected after full code re-verification and a nightscout-nextjs code review.
- **Correction 1:** removed the "FPU upload ID collision overwrites in Nightscout" bug — Nightscout upserts on `created_at`+`eventType`, and the shared FPU `id` is intentional for one-call batch delete. Tier 1 no longer changes the upload `id` or NS deletion (drops 2 files + 1 step).
- **Correction 2:** raised severity of the upload-status bug — FPU rows are *never* marked uploaded and re-POST every cycle (server-deduped by `created_at`).
- **Correction 3:** noted `notes` and `foodType` both map to `result.note`.
- Clarified FPU upload emits `fat`/`protein` as `0` (not omitted); added confirmed NS upsert/passthrough behavior; noted NS report double-counting caveat; clarified import is onboarding-only.
- Relabeled former Tiers 2/3/4 as "Speculative future ideas (not pursued)."
- Added pointers to companion Trio and nightscout-nextjs implementation plans.
- Reason: align the investigation with verified code behavior before implementation planning.

### v1 (2026-07-09 10:16 CET)
- Initial investigation documenting Trio's internal FPU model, Nightscout upload gaps, related bugs, ecosystem context, and tiered implementation proposal. Reason: capture findings from codebase review and user MongoDB examples for future implementation planning.
