+++
uid = "01a15586-fff9-75c4-abeb-b659b6d0ce09"
key = "TRIO-084"
title = "Pull-to-force-loop swallows the next pull after a forced loop (re-arm skipped while forcing)"
status = "done"
kind = "code"
source = "human"
created = 2026-10-19
updated = 2026-10-20
touched = 2026-10-20
closed = 2026-10-20
first_closed = 2026-10-20
accepted_by = "charlie"
accepted_at = 2026-10-20
accepted_ts = "2026-10-20T22:19:33+02:00"
tags = ["upstream-pr", "home", "bug"]
files = ["Trio/Sources/Modules/Home/View/HomeRootView+Refresh.swift"]
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"
priority = 2

[[acceptance]]
id = "AC-1"
text = "handlePullChange clears isRefreshArmed whenever offset <= 1, including while isForcingLoop is true; trigger threshold, haptic and forceLoop behaviour otherwise unchanged; diff limited to HomeRootView+Refresh.swift"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "27f6071a0 (fix/pull-to-loop-rearm) moves the offset<=1 disarm above the isForcingLoop guard; 1+/2- in HomeRootView+Refresh.swift only, no added comments"
met_at = 2026-10-19
met_ts = "2026-10-19T21:03:37+02:00"
met_by = "claude-code"
met_commit = "31f8b6ff96843994b960a004a1d90bf88e3b535f"

[[acceptance]]
id = "AC-2"
text = "Branch fix/pull-to-loop-rearm is one commit on upstream/dev, ready for a PR to nightscout/Trio dev"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "27f6071a0 (fix/pull-to-loop-rearm) single commit on upstream/dev bcebda2f5"
met_at = 2026-10-19
met_ts = "2026-10-19T21:03:37+02:00"
met_by = "claude-code"
met_commit = "31f8b6ff96843994b960a004a1d90bf88e3b535f"

[[acceptance]]
id = "AC-3"
text = "On device: pull to force loop, release while 'Forcing loop…' shows; after it clears, the very next pull forces a loop (haptic + spinner) every time"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "operator"
evidence = "Verified by charlie on the board"
met_at = 2026-10-20
met_ts = "2026-10-20T22:19:14+02:00"
met_by = "charlie"
met_commit = "fdf3fa954535e983bb1c9d51f6f9e3a71ffa441f"

[[sessions]]
host = "claude-code"
ref = "45d7f367-9c77-4b74-ad8e-29925f87d5bc"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T18:58:45+00:00"

[[sessions]]
host = "claude-code"
ref = "20261019-210500-direct-27f6071a0"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:03:30+00:00"

[[reviews]]
run_id = "7f7f328b-a307-41b7-aa2d-29304f2187f8"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "bcebda2f5881b5835cecdade8593f951493ac899"
reviewed_paths = ["Trio/Sources/Modules/Home/View/HomeRootView+Refresh.swift"]
recorded_at = "2026-10-19T19:01:25+00:00"
+++

## Intent

## Problem

Pull-down-to-force-loop on Home often needs two pulls. In upstream's `handlePullChange` (`Trio/Sources/Modules/Home/View/HomeRootView+Refresh.swift`, from nightscout/Trio#1329), the `offset <= 1` disarm sits *after* `guard canForceLoop, !isForcingLoop`. A pull arms and fires `forceLoop()`, which holds `isForcingLoop` for >=1 s (up to ~33 s). The user releases during that window, so the settle-to-0 events are swallowed by the guard and `isRefreshArmed` stays `true`. Nothing fires at rest, so the next pull crosses the threshold while still armed and is a no-op (no haptic, no spinner); its release disarms, and the third pull works. Patch 15's Nightscout backfill (up to 10 s) widens the window but does not cause it.

## Fix

Disarm whenever the pull settles, regardless of `isForcingLoop`: move the `offset <= 1` re-arm above the guard. A user still holding past the threshold when the loop finishes stays armed and does not re-trigger.

## Upstream

Separate branch `fix/pull-to-loop-rearm` off `upstream/dev` so the operator can open a PR to nightscout/Trio `dev`. Possibly related: nightscout/Trio#1410 (open, stale; maintainer attributed it to the 3-minute loop gate). No existing PR addresses it (searched 2026-10-19). For build 233 it ships as its own patch, dropped once upstream merges.


## Release note

Pulling down to force a loop now works on the very next pull after a forced loop finishes. Before, that pull was sometimes ignored and you had to pull twice.


Shipped in build 233 (TRIO-083), uploaded to TestFlight 2026-10-19 22:55.
