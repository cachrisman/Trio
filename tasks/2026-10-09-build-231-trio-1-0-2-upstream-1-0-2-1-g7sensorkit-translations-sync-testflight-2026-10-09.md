+++
uid = "01a11f7a-4c5b-74fd-b658-3b3095663cd1"
key = "TRIO-071"
title = "Build 231 — Trio 1.0.2 (upstream 1.0.2.1) + G7SensorKit translations sync, TestFlight 2026-10-09"
status = "open"
kind = "project"
source = "human"
created = 2026-10-09
updated = 2026-10-09
touched = 2026-10-09
tags = ["build", "testflight"]

[[acceptance]]
id = "AC-1"
text = "Uploaded to TestFlight and release recorded (build 231 at 09:22:46; trio-v1.0.2-231-localCI)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-09
evidence_kind = "run"
evidence = "build/artifacts/ci-local-build-20261009-090706.log: agvtool new-version 231; 'Successfully uploaded the new binary to App Store Connect' at 09:22:46; Record Release created trio-v1.0.2-231-localCI (public + private draft); stage summary TOTAL (Success) 23m 25s"
met_at = 2026-10-09
met_by = "unknown"
met_commit = "32ded642831a1f5c788f043be392137cc245dd2a"

[[acceptance]]
id = "AC-2"
text = "Installed on phone and watch; app reports 1.0.2 (231)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-09
evidence_kind = "operator"
evidence = "Operator in chat 2026-10-09: \"installed on both\" (phone and watch). Build 231 corroborated by BetterStack (AC-3)."
met_at = 2026-10-09
met_by = "Charlie Chrisman"
met_commit = "32ded642831a1f5c788f043be392137cc245dd2a"

[[acceptance]]
id = "AC-3"
text = "BetterStack shows build 231 reporting on both phone and watch"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-09
evidence_kind = "run"
evidence = "BetterStack source 1659391 hot tier (remote(t491594_trio_logs)), last 6h at 2026-10-09 ~09:35 UTC: every row is build 231. ios 1362 rows 08:44:44-09:35:21 UTC; watchos 398 rows 08:44:44-09:25:30 UTC; no build 230 rows. Watch launch sentinel 09:09:50 UTC '[DEPLOY] event=watch_app_launch platform=watchos build=231 os_version=27.0.1'."
met_at = 2026-10-09
met_by = "unknown"
met_commit = "32ded642831a1f5c788f043be392137cc245dd2a"
+++

## Intent

Build epic (AGENTS.md 'Build tasks'). Upstream sync to Trio 1.0.2 (upstream/dev 1.0.2.1) plus the G7SensorKit fork's LoopKit sync, with the patch stack otherwise unchanged since build 230. The Glucose Bobble complication redesign (TRIO-070) is deliberately held back for its own evaluation (operator, 2026-10-08).

## Build facts
- Source: dev 32ded6428 = upstream/dev fcd5c9a00 (1.0.2.1; commits in upstream not in dev: 0) + patches 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15
- Upstream merge: 3419c8aa5 "Merge upstream/dev (1.0.2.1) into dev". One conflict, scripts/swiftformat.sh exclude list: kept dev's build/DerivedData/worktree/SourcePackages/pb.swift excludes and quoting fixes, took upstream's LibreCRKit to RoundWhiteDiscKit swap and the new EversenseKit exclude. 32ded6428 merges origin/dev's GH Action sync commit 1b9fa08c3 with no tree change.
- G7SensorKit: fork cachrisman/G7SensorKit main 1f12fea = previous pin 0013c90 + LoopKit main dd91f46 (lokalise translations #69, #77, #81; no code change). Patch 02 re-pinned with scripts/repin-g7.sh in 87441ce8a (base dd91f46, the upstream pin).
- App version: APP_VERSION 1.0.2, APP_DEV_VERSION 1.0.2.1
- Patches (sha256 prefix): 01 b9e080c0d532, 02 8be7890420fd, 03 7011d2ce9bf7, 04 68c96a63bc86, 05 4272ccaa8262, 06 1b760f7dc511, 08 8302d86669ab, 09 0ccda23e9e94, 10 706f5cf1b723, 13 04a96020463f, 14 5a24bab7093b, 15 b128c37dd822
- Xcode 27.0 (27A266a)
- Command: ./ci/local-build.sh --base-branch dev --no-sync-upstream --task <this key>
- --no-sync-upstream: dev already contains upstream/dev, merged by hand because of the swiftformat.sh conflict.
- Verification before build: dry run on a scratch branch applied all 12 patches on the merged base, with a deletion review of the four files both upstream and the stack touch (TrioSettings, PluginSource, NightscoutManager, SettingItems): no upstream lines lost. Upstream's 1.0.2 diff touches no watch, complication, ContactImage or WatchConfig path. repin-g7.sh ran patch-test: 12/12 applied, patch-audit PASSED (39 warnings, same as build 230), pump-migration sentinel present.

## Contains (child tasks)

- TRIO-072 — upstream/dev 1.0.2.1 sync into dev (merge 3419c8aa5; scripts/swiftformat.sh conflict resolved)
- TRIO-073 — G7SensorKit fork: LoopKit dd91f46 translations merged as 1f12fea, patch 02 repinned (87441ce8a)

Added after the build (2026-10-09): the GitHub release body was rendered while this list said "None", so its "What's in this build" section is empty.

## Known issues carried
- TRIO-067: phone logs settings/temptargets.json DecodingError.typeMismatch since build 226.
- TRIO-068: replyHandler envelope path records and ACKs even when nothing was handled.
- TRIO-070: circular complication text and arrow too small on wrist (design in progress, not in this build).


## Attempt 2026-10-09 09:05 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --task TRIO-071`
- Log: `build/artifacts/ci-local-build-20261009-090529.log`
- Base ref: `dev`
- dev: `32ded6428`
- upstream/dev: `fcd5c9a00`
- Xcode: Xcode 27.0


- Outcome: FAILED (exit 1) (ended 2026-10-09 09:05)
- Failed stage: Ruby Dependencies
- Last errors:

```
    ?? tasks/2026-08-17-watcherrorreporter-loses-failed-error-reports-permanently-pending-list-has-no-consumer-and-stores-no-payload.md
[create_certs] bundle install failed; continuing (fastlane steps may fail).
[stage] ✗ Failed: Ruby Dependencies (1s)
```


- Cause (attempt 09:05, failed at Ruby Dependencies): Homebrew upgraded Ruby 4.0.6 to 4.0.7 on 2026-10-01 and left bundler 2.6.2 as an orphaned gemspec with no files, so `bundle _2.6.2_` raised LoadError on exe/bundle. Fixed with `gem install bundler:2.6.2`; `bundle _2.6.2_ check` then reported all Gemfile dependencies satisfied. Environment only, no code change. Preserved worktree ci-build-20261009-090531 removed.


## Attempt 2026-10-09 09:07 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --task TRIO-071`
- Log: `build/artifacts/ci-local-build-20261009-090706.log`
- Base ref: `dev`
- dev: `32ded6428`
- upstream/dev: `fcd5c9a00`
- Xcode: Xcode 27.0


- Outcome: success (ended 2026-10-09 09:30)
- Build number: 231
- TestFlight: uploaded at 09:22:46
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.2-231-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.2-231-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 1s |
| Worktree Setup | 19s |
| Certificates & Config | 9s |
| Patch Application | 2s |
| Ruby Dependencies | 1s |
| Build IPA | 12m 19s |
| TestFlight Upload | 10m 0s |
| Record Release | 34s |
| TOTAL (Success) | 23m 25s |
