+++
uid = "01a14492-db80-724d-8362-57ca264a6800"
key = "TRIO-077"
title = "Mark Nightscout-fetched glucose as already uploaded so Share gap-fills are not echoed back and stripped of device"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "side-2332fe6b/share-echo-isUploadedToNS"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
tags = ["nightscout", "glucose", "share", "patch-16"]
files = ["Trio/Sources/APS/Storage/GlucoseStorage.swift", "Trio/Sources/Modules/NightscoutConfig/NightscoutConfigStateModel.swift"]
priority = 2
parent = "01a14459-1abb-73ba-9248-679079504c8e"

[[acceptance]]
id = "AC-1"
text = "After a pull-to-refresh that stores a Share fill, that reading's Nightscout doc still has device: dexcom-share and an unchanged _id"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-2"
text = "No Trio POST /api/v1/entries carries a reading that came from a Nightscout fetch (BetterStack source 2518064)"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-3"
text = "Operator decides whether Nightscout-fetched glucose is also marked uploaded to Apple Health and Tidepool"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "operator"
evidence = "Operator answered in chat 2026-10-16 (AskUserQuestion, Health/Tidepool question): \"Nightscout only (Recommended)\" — mark Nightscout-fetched glucose uploaded to Nightscout only; Apple Health and Tidepool uploads stay as upstream."
met_at = 2026-10-16
met_ts = "2026-10-16T14:11:55+02:00"
met_by = "charlie"
met_commit = "3db1ef7a0830763bbe9b1f8428f3eabb4b4a627a"

[[acceptance]]
id = "AC-4"
text = "Swift Testing case: Nightscout-sourced backfill (batch and single-row paths) is stored with isUploadedToNS = true and is not returned by getGlucoseNotYetUploadedToNightscout, while a plain (BLE) backfill still is; the case fails without the fix"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "2026-10-16, operator-run xcodebuild test (scheme 'Trio Tests', iPhone 17 simulator) in a throwaway tree = dev 1b2c55b93 + patches 01-14 + regenerated patch 15 carrying 5a65d702c, project synced like the Fastfile. With the fix: 14 passed, 0 failed, 1 skipped (pre-disabled 'Test glucose alarms'), incl. 'Nightscout-fetched backfill is stored as already uploaded to Nightscout' and all 7 Home Nightscout backfill tests (xcresult Test-Trio Tests-2026.10.16_15-09-15). Mutation run with configureGlucoseEntry forced to isUploadedToNS = false: only that test failed ('Expectation failed: nightscoutEntries?.allSatisfy { $0.isUploadedToNS } == true'), other 6 passed (xcresult 2026.10.16_16-19-11)."
met_at = 2026-10-16
met_ts = "2026-10-16T16:29:34+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[acceptance]]
id = "AC-5"
text = "Both Nightscout fetch call sites (HomeStateModel pull-to-refresh backfill and NightscoutConfigStateModel manual backfill) store via the Nightscout-marked path; the BLE backfill path in FetchGlucoseManager is unchanged"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "commit"
evidence = "5a65d702c — HomeStateModel.backfillGlucoseFromNightscout and NightscoutConfigStateModel manual backfill call backfillGlucose(_:alreadyUploadedToNightscout: true); FetchGlucoseManager still calls the unlabeled backfillGlucose(_:) (forwards false); storeGlucose unchanged"
met_at = 2026-10-16
met_ts = "2026-10-16T14:24:46+02:00"
met_by = "unknown"
met_commit = "3db1ef7a0830763bbe9b1f8428f3eabb4b4a627a"

[[acceptance]]
id = "AC-6"
text = "Change is folded into patches/15-ns-backfill-on-pull.patch, regenerated with generate-patch.sh, and scripts/patch-test.sh passes with the audit on"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "2026-10-16: operator ran scripts/generate-patch.sh -n -s feature/ns-backfill-on-pull -t dev -o patches/15-ns-backfill-on-pull.patch (8 files); header carries generate-patch-written provenance (Feature-Tip 5a65d702c, Source-Commits c59e5b077 + 5a65d702c, two Source-PatchIds). Applied to a dev index, all 8 blobs match feature/ns-backfill-on-pull:5a65d702c. scripts/patch-test.sh (audit on) exit 0: all patches 01-15 applied, patch-audit PASSED (40 warnings), GlucoseStorage.swift safety deletion WAIVED by the operator-added patch=15 waiver. Patch stays untracked on dev."
met_at = 2026-10-16
met_ts = "2026-10-16T16:34:48+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[sessions]]
host = "claude-code"
ref = "a19adebd-d9f4-4831-9a8a-ae8401e614ce"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:14:09+00:00"

[[reviews]]
run_id = "2b450dda-1a27-4866-8cc7-7891f9da8608"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "c59e5b077ab35784390cf02e632ec94613c2b17c"
reviewed_paths = ["Trio/Sources/APS/Storage/GlucoseStorage.swift", "Trio/Sources/Modules/NightscoutConfig/NightscoutConfigStateModel.swift", "TrioTests/CoreDataTests/GlucoseStorageTests.swift", "Trio/Sources/Modules/Home/HomeStateModel.swift"]
recorded_at = "2026-10-16T12:19:07+00:00"
+++

## Intent

Glucose that Trio fetches from Nightscout is stored as if Trio had read it locally, so Trio uploads it straight back to Nightscout. When the reading is a Dexcom Share gap-fill, the round trip overwrites the Share doc and strips its provenance. Mark Nightscout-fetched glucose as already uploaded to Nightscout so it is never re-uploaded.

## Evidence (2026-10-16, side session of the TRIO-074 planning session)

- `GlucoseStorage.storeGlucoseInCoreData` (GlucoseStorage.swift:259–262) sets `isUploadedToNS = false` (plus Health and Tidepool) for every stored reading. Both `storeGlucose` and `backfillGlucose` go through it.
- The existing manual backfill (`NightscoutConfigStateModel.swift:145–152`, `fetchGlucose` over 1 day → `storeGlucose`) and TRIO-074's pull-to-refresh (`HomeStateModel.backfillGlucoseFromNightscout` → `backfillGlucose`) both store fetched readings this way.
- nightscout-next's v1 entries upsert is `replaceOne({sysTime, type}, doc, {upsert: true})` (nightscout-nextjs `lib/db/mongo/client.ts`). Share docs carry millisecond timestamps, so Trio's echo has exactly the same `sysTime`. The Share doc is replaced in place: the cron's `_id` survives, `device: dexcom-share` and `trend` are dropped, and Trio's `id`/`filtered`/`unfiltered`/`glucose` are added.
- Measured over 8 days:
  - 257 Share docs were converted to Trio-shaped docs. 256 of them fall inside the 24h window of one of the 8 Nightscout fetches Trio made in those 8 days.
  - 66 of 69 still-tagged Share docs fall outside every fetch window.
  - The same path produced 52 near-duplicate Trio↔Trio pairs (1–12s apart) under `storeGlucose`'s 1s dedupe.
- Because the Share tag is lost, capture analysis counted echoes as Bluetooth readings. Real capture for the week of Oct 5 was 82.0% against 92.4% apparent.
- **TRIO-074 multiplies this.** Every pull-to-refresh fetches 24h, so every Share fill in the last day gets echoed and stripped.
- Full write-up: side-session notes `missed-g7-readings-findings.md` §1 (session group local_a178e450).

## Scope

- Store Nightscout-fetched glucose with `isUploadedToNS = true`. A natural shape is a flag or a sibling of `backfillGlucose` used by both Nightscout fetch call sites.
- Decide for Health and Tidepool separately (operator call). Marking them uploaded avoids writing Dexcom-sourced readings into Apple Health as Trio's when the Dexcom app already writes there. Leaving them unmarked keeps Trio's Health history complete.
- Optional server-side belt-and-braces in nightscout-nextjs: the v1 upsert refuses to replace a `device: dexcom-share` doc with a device-less doc, or merges the two. Track separately if wanted.

## Release note

Nightscout: glucose Trio fetches from Nightscout (pull-to-refresh and the manual backfill) is no longer uploaded back, so Dexcom Share gap-fill readings keep their source.
