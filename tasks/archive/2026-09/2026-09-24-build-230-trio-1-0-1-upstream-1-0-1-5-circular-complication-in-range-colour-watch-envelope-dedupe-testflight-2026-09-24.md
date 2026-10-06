+++
uid = "01a0d44e-082f-736d-a5a8-255316285327"
key = "TRIO-069"
title = "Build 230 — Trio 1.0.1 (upstream 1.0.1.5) + circular complication in-range colour, watch envelope dedupe, TestFlight 2026-09-24"
status = "done"
kind = "epic"
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

Build epic (AGENTS.md 'Build tasks'). Follow-up to build 229 (TRIO-066) for what the operator found on device, plus two small fixes the operator chose to include (2026-09-24).

## Build facts
- Source: dev c8276fa0b (code identical to 243acc121; the one later commit archives task files) = upstream 1.0.1.5 (upstream/dev e41c9db37; commits in upstream not in dev: 0) + patches 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15
- Changed since build 229:
  - 04: the watch hands the circular complication the chart colour instead of the white-in-range reading colour.
  - 09: the fork bakes the chart colour into store snapshots; the circular complication keeps recording only an existing reload generation; the reload log line names both complications.
  - 10: the no-replyHandler envelope path deduplicates again (TRIO-047).
- Command: ./ci/local-build.sh --base-branch dev --no-sync-upstream --task <this key>
- --no-sync-upstream: upstream/dev has no commits that dev lacks, and the sync would push dev's unpushed commits, which is the operator's call.
- Verification before build: patch-test 12/12 applied, patch-audit PASSED (39 warnings). Watch targets type-checked against the watchOS SDK. Cursor reviews on each change, recorded on TRIO-063 and TRIO-047. TRIO-047 incremental application: the no-reply guard is present from 09 through 15.

## Contains (child tasks)
- TRIO-063 — circular Glucose Bobble complication: in-range colour for Dynamic, reload log line (patches 04, 09)
- TRIO-047 — no-replyHandler envelope path deduplicates again (patch 10)

## Acceptance criteria
- [x] Uploaded to TestFlight, release recorded (20:29:00; releases trio-v1.0.1-230-localCI)
- [x] Installed on phone and watch; with Glucose Color set to Dynamic, the in-range reading and tint are coloured (green around target), not white or grey (operator) [operator screenshot 2026-09-24, Infograph face: 127 in range shown green-teal with a matching tinted disc, "NOW -14"]
- [x] BetterStack: build 230 on both platforms; reload log line names both kinds [phone 230 from 18:37:14 UTC, watch from 18:39:26; 5 "reloadTimelines for kinds TrioWatchComplication and TrioGlucoseBobbleComplication" lines by 18:53; circular timeline lines show loop_age_seconds 21-33 and the settings following the operator's changes (color_mode=white background=none at 18:47:49, color_mode=glucose background=glucoseTint at 18:52:47)]
- [x] Operator: push dev to origin (2026-09-24; origin/dev = dev = c8276fa0b, pushed at the operator's request)

## Known issues carried
- TRIO-067: phone logs settings/temptargets.json DecodingError.typeMismatch since build 226 (not fixed in this build).
- TRIO-068: replyHandler envelope path records and ACKs even when nothing was handled (found by the TRIO-047 review; needs a design decision).


## Attempt 2026-09-24 20:20 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --task TRIO-069`
- Log: `build/artifacts/ci-local-build-20260924-202016.log`
- Base ref: `dev`
- dev: `c8276fa0b`
- upstream/dev: `e41c9db37`
- Xcode: Xcode 27.0


- Outcome: success (ended 2026-09-24 20:35)
- Build number: 230
- TestFlight: uploaded at 20:29:00
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.1-230-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.1-230-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 23s |
| Certificates & Config | 8s |
| Patch Application | 2s |
| Ruby Dependencies | 0s |
| Build IPA | 6m 14s |
| TestFlight Upload | 8m 5s |
| Record Release | 30s |
| TOTAL (Success) | 15m 22s |
