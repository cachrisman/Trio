+++
uid = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"
key = "TRIO-083"
title = "Build 233 — Trio 1.0.2 (upstream 1.0.2.11) + Treatments screen compaction"
status = "open"
kind = "project"
source = "human"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["build", "testflight"]
+++

## Intent

Build epic (AGENTS.md "Build tasks"; TRIO-059 is the template). Planned 2026-10-19 with the operator. Rebases the patch stack onto the fork's latest upstream sync (origin/dev 744a74d04, upstream APP_DEV_VERSION 1.0.2.11). Ships the operator's Treatments-screen compaction plus the fixes picked for this build.

## Build facts
- Source: dev. On 2026-10-19 local dev was merged with origin/dev (9f7f9560b, signed) and is now 0 behind origin/dev; the local-only commits (task ledger, patch regenerations, scripts/patch-audit.sh) are not pushed yet. Since `local-build.sh`'s upstream sync pushes origin/dev, an agent-launched build uses `--no-sync-upstream`.
- App version: APP_VERSION 1.0.2, APP_DEV_VERSION 1.0.2.11
- Patch stack: 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15, 16, 17, 18, 19. scripts/patch-test.sh on dev 9f7f9560b (2026-10-19): all applied, patch-audit PASSED (47 warnings), sentinel present.
- Not compiled before the build: patches 16 to 19 have not been through xcodebuild.
- Command: to be chosen by the operator (AGENTS.md: ask for flags).

## Contains (child tasks)

- TRIO-082: segmented Reduced | Normal | Super bolus control with an "External" checkbox on one row (patch 16)
- TRIO-085: add-treatment time row hosts a note button; the note row appears only on demand (patch 16)
- TRIO-084: pull-to-force-loop re-arms after a forced loop, so the next pull isn't swallowed (patch 17)
- TRIO-067: FileStorage.append no longer logs an error for its expected single-object probe (patch 18)
- TRIO-086: Big Glucose Lock Screen Live Activity style, layout B2 (patch 19)
- TRIO-012: watch logs how long each userInfo transfer waited in the queue (patch 09)
- TRIO-081: patch-audit sentinel checks every declared symbol (scripts only, not in the app)

## After the build
- On-device operator checks: TRIO-082 AC-4, TRIO-084 AC-3, TRIO-085 AC-2, TRIO-086 AC-8 and AC-9.
- BetterStack: TRIO-067 AC-4, no temptargets.json typeMismatch lines on this build across a morning window.

## Known issues carried
- TRIO-068: the replyHandler envelope path records and ACKs even when nothing was handled.
