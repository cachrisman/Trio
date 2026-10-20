+++
uid = "01a14492-db80-724d-8362-57ca264a6800"
key = "TRIO-077"
title = "Mark Nightscout-fetched glucose as already uploaded so Share gap-fills are not echoed back and stripped of device"
status = "done"
kind = "code"
source = "agent-discovered"
source_ref = "side-2332fe6b/share-echo-isUploadedToNS"
created = 2026-10-16
updated = 2026-10-17
touched = 2026-10-17
closed = 2026-10-17
first_closed = 2026-10-17
accepted_by = "charlie"
accepted_at = 2026-10-17
accepted_ts = "2026-10-17T14:40:07+02:00"
tags = ["nightscout", "glucose", "share", "patch-16"]
files = ["Trio/Sources/APS/Storage/GlucoseStorage.swift", "Trio/Sources/Modules/NightscoutConfig/NightscoutConfigStateModel.swift"]
priority = 2
parent = "01a14459-1abb-73ba-9248-679079504c8e"

[[acceptance]]
id = "AC-1"
text = "After a pull-to-refresh that stores a Share fill, that reading's Nightscout doc still has device: dexcom-share and an unchanged _id"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "2026-10-17, build 232 (dev 826bf8a23, patch 15 carrying 5a65d702c): pull-to-refresh backfills at 05:54:46 UTC and 08:11:07-08:11:33 UTC (phone logs 'passed 287 Nightscout reading(s)'; Nightscout logs Trio GET /api/v1/entries/sgv.json 05:55:12 and 4x 08:11). Baseline = the 12 dexcom-share docs inserted after the deploy (18:04 UTC 10-16), e.g. 6ad2a584f71fc149723a2a9d (22:28:48 UTC, 106) through 6ad2f9e2f71fc149723a4ad2 (04:28:48 UTC, 118), all inside the 05:55 pull's 24h lookback. Raw read-only GET of /api/v1/entries.json at 08:12 UTC (2h17m after the 05:55 pull): 12/12 still device=dexcom-share, same _id and sgv, only Share fields (no filtered/unfiltered/glucose/id), one doc per timestamp. Before the deploy, 11 of 12 cron-phase Share docs in the prior 24h had been stripped. Not directly observable: how many of the 287 readings Trio actually stored after its 3.5-minute dedupe."
met_at = 2026-10-17
met_ts = "2026-10-17T10:13:10+02:00"
met_by = "claude-code"
met_commit = "31f8b6ff96843994b960a004a1d90bf88e3b535f"

[[acceptance]]
id = "AC-2"
text = "No Trio POST /api/v1/entries carries a reading that came from a Nightscout fetch (BetterStack source 2518064)"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "2026-10-17: across all build-232 pulls (10-16 18:06, 22:25; 10-17 05:55, 08:11 UTC), no Share doc was overwritten. Raw entries 10-16 08:00 to 10-17 08:08 UTC: of the 169 docs inserted since the deploy, 0 cron-phase (Share-insert signature) docs are untagged, against 11 stripped in the 24h before the deploy. BetterStack source 2518064 shows Trio entries POSTs at the usual roughly 5-minute cadence, 7-37 ms, with no burst after any pull. Request logs carry no payloads, so this is inferred from the docs' state, not from POST bodies."
met_at = 2026-10-17
met_ts = "2026-10-17T10:13:11+02:00"
met_by = "claude-code"
met_commit = "31f8b6ff96843994b960a004a1d90bf88e3b535f"

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
text = "Both Nightscout fetch call sites (HomeStateModel pull-to-refresh backfill and NightscoutConfigStateModel manual backfill) store as already uploaded only when the fetch came from the remote Nightscout (alreadyUploadedToNightscout = !useLocalGlucoseSource); local-glucose-source readings stay eligible for upload; the BLE backfill path in FetchGlucoseManager is unchanged"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "commit"
evidence = "8707a351b - HomeStateModel.backfillGlucoseFromNightscout and NightscoutConfigStateModel.backfillGlucose compute alreadyUploaded = !settingsManager.settings.useLocalGlucoseSource and pass it to backfillGlucose(_:alreadyUploadedToNightscout:); FetchGlucoseManager still calls the unlabeled backfillGlucose(_:) (forwards false); storeGlucose unchanged"
met_at = 2026-10-16
met_ts = "2026-10-16T21:43:16+02:00"
met_by = "unknown"
met_commit = "7a824204a6b2ba7c11591699bcb2a9f2c519fd87"

[[acceptance]]
id = "AC-6"
text = "Change is folded into patches/15-ns-backfill-on-pull.patch, regenerated with generate-patch.sh, and scripts/patch-test.sh passes with the audit on"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "2026-10-16: scripts/generate-patch.sh -n -s feature/ns-backfill-on-pull -t dev -d ns-backfill-on-pull --include-files <the 8 patch files> regenerated patches/15 (Feature-Tip 8707a351b; diff vs the previous copy is only the two call-site changes, a swiftformat reflow and provenance). scripts/patch-test.sh (audit on): patches 01-15 applied, patch-audit PASSED (40 warnings). Committed on dev as 7a824204a."
met_at = 2026-10-16
met_ts = "2026-10-16T21:43:16+02:00"
met_by = "unknown"
met_commit = "7a824204a6b2ba7c11591699bcb2a9f2c519fd87"

[[sessions]]
host = "claude-code"
ref = "a19adebd-d9f4-4831-9a8a-ae8401e614ce"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:14:09+00:00"

[[sessions]]
host = "claude-code"
ref = "bfef79d9-1742-4894-8fe8-7ce2e624f98a"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T00:00:00+00:00"

[[reviews]]
run_id = "2b450dda-1a27-4866-8cc7-7891f9da8608"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "c59e5b077ab35784390cf02e632ec94613c2b17c"
reviewed_paths = ["Trio/Sources/APS/Storage/GlucoseStorage.swift", "Trio/Sources/Modules/NightscoutConfig/NightscoutConfigStateModel.swift", "TrioTests/CoreDataTests/GlucoseStorageTests.swift", "Trio/Sources/Modules/Home/HomeStateModel.swift"]
recorded_at = "2026-10-16T12:19:07+00:00"

[[reviews]]
run_id = "76d6600f-c06c-4d89-86c0-4ed26f647f01"
model_family = "codex"
verdict = "fail"
reviewed_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
reviewed_paths = ["patches/15-ns-backfill-on-pull.patch"]
recorded_at = "2026-10-16T00:00:00+00:00"

[[reviews]]
run_id = "b881115a-87ef-4d95-867b-19e09fb001ce"
model_family = "codex"
verdict = "fail"
reviewed_commit = "7a824204a6b2ba7c11591699bcb2a9f2c519fd87"
reviewed_paths = ["patches/15-ns-backfill-on-pull.patch"]
recorded_at = "2026-10-16T00:00:00+00:00"

[[reviews]]
run_id = "waived-operator-20261016-p15-race"
model_family = "none"
verdict = "waived"
reviewed_commit = "7a824204a6b2ba7c11591699bcb2a9f2c519fd87"
reviewed_paths = ["patches/15-ns-backfill-on-pull.patch"]
recorded_at = "2026-10-16T00:00:00+00:00"
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


Shipped in build 232 (TRIO-076), TestFlight 2026-10-16.


## Review 2026-10-16 (codex, patch 15 at dev 826bf8a23): fail

Fresh diverse review of the whole `patches/15-ns-backfill-on-pull.patch` (note `.task-relay/notes/20261016-211821-37667-codex-review.md`, run 76d6600f, gpt-5.6-terra high), replacing the stale feature-branch passes. Verdict NEEDS-FIX, recorded as a fail on TRIO-074 and TRIO-077. Triage:

- HIGH, confirmed: both backfill call sites (HomeStateModel pull-to-refresh and NightscoutConfigStateModel manual backfill) pass `alreadyUploadedToNightscout: true` unconditionally, but `NightscoutManager.fetchGlucose` reads from `http://127.0.0.1:<localGlucosePort>` when `useLocalGlucoseSource` is on (default off). In that configuration the readings come from a local source, not the remote Nightscout, and are now never uploaded to it, a regression for the upstream manual backfill. Likely fix: pass `alreadyUploadedToNightscout: !settings.useLocalGlucoseSource`.
- HIGH, out of scope as written: with Nightscout as the CGM source, `FetchGlucoseManager` still stores fetched readings with `isUploadedToNS = false`, so they can be re-uploaded. That is unchanged upstream behaviour which TRIO-077 AC-5 deliberately left alone (the operator's CGM is G7 over BLE). Possible follow-up, not a defect of this patch.
- MEDIUM, TRIO-074: the ~10s cap bounds only the Nightscout fetch; once the fetch wins, storing the batches has no deadline and `forceLoop()` waits for it before the heartbeat. Low risk for a 24h window (288 readings), but it is unbounded.


## Review waiver 2026-10-16 (patch 15 at 7a824204a)

Codex review b881115a (gpt-5.6-terra, high; note .task-relay/notes/20261016-214243-90090-codex-review.md) confirmed the earlier HIGH is fixed by 8707a351b (both call sites pass alreadyUploadedToNightscout = !useLocalGlucoseSource), returned NEEDS-FIX with 0 high, 1 medium, 1 low, and was recorded as a fail.

- MEDIUM: the call sites read useLocalGlucoseSource before the fetch starts, and NightscoutManager.fetchGlucose reads it again on its own. If the setting is toggled in between, the upload flag can disagree with the source actually fetched. Closing it fully means passing the source choice into fetchGlucose, which changes the shared NightscoutManager protocol and its other callers.
- LOW: no test covers the useLocalGlucoseSource == true case at either call site.

Operator decision in chat 2026-10-16, after the trade-off was explained: "Accept". Accepted as a known residual race: it needs the local glucose source setting to be switched during a pull-to-refresh fetch (10s cap at most), the worst case is some readings not uploading to Nightscout or being uploaded twice, and no dosing path is involved. The LOW test gap is accepted with it. Review recorded as waived.
