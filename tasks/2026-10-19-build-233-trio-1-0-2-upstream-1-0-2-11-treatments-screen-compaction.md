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
- Source (planned): dev, after the operator reconciles local dev with origin/dev. On 2026-10-19 local dev was 4 ahead (31f8b6ff9, c693fdbf9, d9384f18e, 7a824204a: task triage, archives, patch 15 regenerated for TRIO-077) and 62 behind (744a74d04, the GH Action upstream sync of 2026-10-18 to 1.0.2.11). Since `local-build.sh`'s upstream sync pushes origin/dev, an agent-launched build uses `--no-sync-upstream`.
- App version: APP_VERSION 1.0.2, APP_DEV_VERSION 1.0.2.11 (planned)
- Patch stack (planned): 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15, 16 (16 = treatments-bolus-mode, new)
- Command: to be chosen by the operator (AGENTS.md: ask for flags).

## Contains (child tasks)

- TRIO-082: Treatments shows a segmented Reduced | Normal | Super bolus control with an "External" checkbox on one row (patch 16)

## Candidates under consideration (not yet committed to this build)

- Pull-to-refresh sometimes needs two pulls before a refresh starts (investigation 2026-10-19)
- Treatments: time row hosts a note button; the note row appears only on demand
- Live Activity: big-glucose layout option (design pending the operator's choices)

## Known issues carried
- TRIO-067: since build 226 the phone logs a DecodingError.typeMismatch for settings/temptargets.json.
- TRIO-068: the replyHandler envelope path records and ACKs even when nothing was handled.
