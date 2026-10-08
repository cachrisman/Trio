+++
uid = "01a0d37b-b484-7392-bca6-ca5f9a2a55b2"
key = "TRIO-066"
title = "Build 229 — Trio 1.0.1 (upstream 1.0.1.5) + Glucose Bobble complication v2, settings and telemetry, TestFlight 2026-09-24"
status = "done"
kind = "project"
source = "human"
created = 2026-09-24
updated = 2026-09-24
touched = 2026-09-24
closed = 2026-09-24
first_closed = 2026-09-24
accepted_by = "Charlie"
accepted_at = 2026-09-24
owner = "me"
tags = ["build", "testflight"]
+++

## Intent

Build epic (AGENTS.md 'Build tasks'). Operator-requested build and TestFlight deploy (2026-09-24) of the circular complication's second version: the on-device feedback round from build 228 (TRIO-065), Phase C phone settings, and fork telemetry for the circular complication.

## Build facts
- Source: dev 7559720bd = upstream 1.0.1.5 (upstream/dev e41c9db37, no commits newer than build 228's base) + patches 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15
- Changed since build 228: 03 (inside-ring arrow placement, solid ring colour), 04 (bigger bobble, content background, minute-aligned age, rename, Phase C settings), 09 (fork adaptation and circular-complication telemetry), 13 (regenerated on top of 04's watch-state sender lines; background allowlist gains the loop date and settings)
- Command: ./ci/local-build.sh --base-branch dev --no-sync-upstream --task <this key>
- --no-sync-upstream: upstream/dev has no commits that dev lacks, so the sync would merge nothing. It would still push dev's unpushed commits, and pushing is the operator's.
- Verification before build: patch-test 12/12 applied, patch-audit PASSED (39 warnings); watchOS typechecks of both watch targets; codex reviews CLEAN on the upstream-shaped and fork branches (TRIO-063).

## Contains (child tasks)
- TRIO-063 — circular Glucose Bobble complication, second version, Phase C settings, and telemetry (patches 03, 04, 09, 13). The task continued after this build and is now a child of build 230 (TRIO-069), so it is not a child of this epic.

## Acceptance criteria
- [x] Uploaded to TestFlight, release recorded (15:09:40; releases trio-v1.0.1-229-localCI)
- [x] Installed on phone and watch; circular complication bigger with the tinted background visible; renamed "Trio Glucose Bobble" (operator) [build 229, operator, 2026-09-24: installed, bigger bobble, new name and settings verified; the tint showed grey in range, which was the Dynamic colour bug under Known issues, fixed and verified on build 230 (TRIO-069)]
- [x] Settings > Apple Watch > Complications > Glucose Bobble Complication changes reach the watch (operator, 2026-09-24: Ring set to Loop Status, updated within a minute or two)
- [x] BetterStack: build 229 on both platforms; event=glucose_bobble_complication_timeline lines present with kind=TrioGlucoseBobbleComplication (phone 229 from 13:16:39 UTC, watch from 13:19:37; first circular timeline line 13:19:37, snapshot line with is_preview=true 13:19:50)
- [x] Operator: push dev to origin (2026-09-24; origin/dev = dev = c8276fa0b, pushed at the operator's request)


## Attempt 2026-09-24 14:59 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --task TRIO-066`
- Log: `build/artifacts/ci-local-build-20260924-145948.log`
- Base ref: `dev`
- dev: `7559720bd`
- upstream/dev: `e41c9db37`
- Xcode: Xcode 27.0


- Outcome: success (ended 2026-09-24 15:16)
- Build number: 229
- TestFlight: uploaded at 15:09:40
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.1-229-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.1-229-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 27s |
| Certificates & Config | 8s |
| Patch Application | 2s |
| Ruby Dependencies | 1s |
| Build IPA | 7m 13s |
| TestFlight Upload | 8m 9s |
| Record Release | 33s |
| TOTAL (Success) | 16m 33s |


## Known issues

- **Dynamic colour showed white in range** (operator, 2026-09-24, on device). The complication used the watch's reading-bubble colour, which the phone sends as white whenever the reading is in range, instead of the scheme colour the contact image's Glucose Bobble uses. Fixed in TRIO-063 (patches 04 and 09, dev 48f898155; cursor review CLEAN); ships in the next build.
- **Phone settings change reaching the watch: resolved, not a bug** (operator, 2026-09-24). The operator changed Ring to Loop Status and the complication updated within a minute or two. The earlier "not after 150 s" was watchOS reload pacing. Every watch payload since 13:22 UTC carries the settings and the loop date.
