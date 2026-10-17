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
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "build/artifacts/ci-local-build-20261016-193200.log: all 12 patches (01-06, 08-10, 13-15) applied on dev 826bf8a23 in the Patch Application stage; scripts/patch-test.sh with patch-audit passed on the same stack earlier today"
met_at = 2026-10-16
met_ts = "2026-10-16T19:47:28+02:00"
met_by = "unknown"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"

[[acceptance]]
id = "AC-2"
text = "Uploaded to TestFlight and release recorded (build 232), with this epic's Contains list complete before launch"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "build/artifacts/ci-local-build-20261016-193200.log: build 232 uploaded to TestFlight 19:39:56; release https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.2-232-localCI (private draft backup in trio-builds-private); Contains list complete before launch"
met_at = 2026-10-16
met_ts = "2026-10-16T19:47:28+02:00"
met_by = "unknown"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"

[[acceptance]]
id = "AC-3"
text = "Installed on phone and watch; app reports 1.0.2 (232)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "operator"
evidence = "Operator in chat 2026-10-16: \"Deployed to phone and watch.\" BetterStack (source 1659391) confirms appVersion 1.0.2 build 232 from ios since 18:04:21 UTC and watchos since 18:08:54 UTC"
met_at = 2026-10-16
met_ts = "2026-10-16T20:20:27+02:00"
met_by = "charlie"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"

[[acceptance]]
id = "AC-4"
text = "BetterStack shows build 232 logging from the phone, including a 'Home pull-to-refresh Nightscout backfill' line after a pull-to-refresh"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-16
evidence_kind = "query"
evidence = "BetterStack source 1659391, build=232: ios 534 lines 18:04-18:19 UTC; 2026-10-16 18:06:20 UTC 'Home pull-to-refresh Nightscout backfill passed 288 Nightscout reading(s) to backfill (deduplicated against stored glucose)'"
met_at = 2026-10-16
met_ts = "2026-10-16T20:20:27+02:00"
met_by = "unknown"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
build = "01a14459-1abb-73ba-9248-679079504c8e"

[[acceptance]]
id = "AC-5"
text = "Operator pushes dev (agents do not push)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "operator"
evidence = "Operator in chat 2026-10-16: \"Local dev is pushed to origin\". git fetch confirms origin/dev = dev = 826bf8a23 (the build 232 source)"
met_at = 2026-10-16
met_ts = "2026-10-16T20:21:05+02:00"
met_by = "charlie"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
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
- TRIO-077 — Glucose fetched from Nightscout is stored as already uploaded, so Share gap-fills are no longer echoed back and stripped of `device` (5a65d702c, patch 15)
- TRIO-040 — Cloud logging caps each upload pass at entry boundaries, so stack traces and other multi-line entries are no longer split across two Better Stack events (2ff4c78e5, patch 06)

## Known issues carried
- TRIO-067: phone logs settings/temptargets.json DecodingError.typeMismatch since build 226.
- TRIO-068: replyHandler envelope path records and ACKs even when nothing was handled.


## Attempt 2026-10-16 19:32 local

- Command: `./ci/local-build.sh --task TRIO-076 --no-sync-upstream`
- Log: `build/artifacts/ci-local-build-20261016-193200.log`
- Base ref: `dev`
- dev: `826bf8a23`
- upstream/dev: `1bacd86fb`
- Xcode: Xcode 27.1


- Outcome: success (ended 2026-10-16 19:46)
- Build number: 232
- TestFlight: uploaded at 19:39:56
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.2-232-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.2-232-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 1s |
| Worktree Setup | 18s |
| Certificates & Config | 8s |
| Patch Application | 2s |
| Ruby Dependencies | 0s |
| Build IPA | 5m 15s |
| TestFlight Upload | 8m 20s |
| Record Release | 29s |
| TOTAL (Success) | 14m 33s |
