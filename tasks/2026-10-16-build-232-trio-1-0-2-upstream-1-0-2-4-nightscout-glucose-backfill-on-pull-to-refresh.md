+++
uid = "01a14459-1abb-73ba-9248-679079504c8e"
key = "TRIO-076"
title = "Build 232 — Trio 1.0.2 (upstream 1.0.2.4) + Nightscout glucose backfill on pull-to-refresh"
status = "open"
kind = "project"
source = "human"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
tags = ["build", "testflight"]

[[acceptance]]
id = "AC-1"
text = "Patch stack validated on the build base: scripts/patch-test.sh applies every patch and patch-audit passes"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-2"
text = "Uploaded to TestFlight and release recorded (build 232), with this epic's Contains list complete before launch"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-3"
text = "Installed on phone and watch; app reports 1.0.2 (232)"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-4"
text = "BetterStack shows build 232 logging from the phone, including a 'Home pull-to-refresh Nightscout backfill' line after a pull-to-refresh"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-5"
text = "Operator pushes dev (agents do not push)"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-16
+++

## Intent

Build epic (AGENTS.md 'Build tasks'). Ships the pull-to-refresh Nightscout glucose backfill (TRIO-074, new patch 15) on top of upstream/dev 1.0.2.4, which brings upstream's own carb-edit freeze fix (nightscout/Trio#1595), the glucose badge refresh (#1624), and the glucose-alarm retract-scope change (#1573), which replaces the old patch 15.

## Build facts
- Source (planned): dev, which already contains upstream/dev 1bacd86fb (1.0.2.4; commits in upstream not in dev: 0). Upstream merge 7e91aaea0 (operator, pushed to origin/dev). Local dev is ahead of origin/dev by c8851ce78 (TRIO-075 patch tooling temp files under TMPDIR), d459fd2c5 (retire old patch 15, TRIO-055) and 8f192f13f (TRIO-075 task file); the operator pushes dev.
- Upstream since build 231 (32ded6428..1bacd86fb, non-merge, excluding version bumps): carb-edit UI freeze and lost entry fix (#1595), glucose app badge refresh on settings change (#1624), forecast/carbs-required alarms kept when the CGM owns alerts (#1573, our former patch 15).
- App version: APP_VERSION 1.0.2, APP_DEV_VERSION 1.0.2.4
- Patch stack (planned): 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15 (15 is now ns-backfill-on-pull; the old 15-glucose-alarm-retract-scope was retired because upstream has it byte-identical)
- G7SensorKit: unchanged since build 231 (fork main 1f12fea, patch 02 pin)
- Command: to be chosen by the operator (AGENTS.md: ask for flags). `local-build.sh`'s upstream sync pushes origin/dev, so an agent-launched build uses `--no-sync-upstream`.

## Contains (child tasks)

- TRIO-074 — Pull-to-force-loop backfills Nightscout glucose (last 24h, 10s cap) before forcing the loop (patch 15)
- TRIO-004 — Watch Diagnostics shows "Last data: Xs ago" for the last phone delivery (a679782ba, patch 09)
- TRIO-025 — Watch logs `userinfo_transfer_finished` with outcome and retry position for every userInfo transfer (73372979f, patch 09)

## Known issues carried
- TRIO-067: phone logs settings/temptargets.json DecodingError.typeMismatch since build 226.
- TRIO-068: replyHandler envelope path records and ACKs even when nothing was handled.
