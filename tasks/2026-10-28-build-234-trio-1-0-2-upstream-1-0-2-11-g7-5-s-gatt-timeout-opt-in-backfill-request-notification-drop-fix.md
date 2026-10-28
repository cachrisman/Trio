+++
uid = "01a18464-7f48-7364-8944-b13bdac2ec28"
key = "TRIO-095"
title = "Build 234 — Trio 1.0.2 (upstream 1.0.2.11) + G7 5 s GATT timeout, opt-in backfill request, notification-drop fix"
status = "open"
kind = "project"
source = "human"
created = 2026-10-28
updated = 2026-10-28
touched = 2026-10-28
tags = ["build", "testflight"]

[[acceptance]]
id = "AC-1"
text = "Patch 02 repinned to fork 7fa073c and scripts/patch-test.sh clean (patch-audit PASS, sentinel present)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "./scripts/repin-g7.sh 2026-10-28 (v1.2, no push): '7fa073c… is on origin (origin/main); no push needed', patch 02 rewritten dd91f465b..7fa073c2a, patch-test.sh: all 16 patches applied, patch-audit passed (47 warnings, pump-migration sentinel present) (patch 02 uncommitted for the operator)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-2"
text = "Build uploaded to TestFlight and release recorded (ci/local-build.sh --task TRIO-095)"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-28

[[acceptance]]
id = "AC-3"
text = "Installed on the operator's phone and watch; G7 readings flowing (egv_received on the new build number in BetterStack)"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28

[[acceptance]]
id = "AC-4"
text = "Child post-deploy checks run: TRIO-093 AC-6 (command_slow/command_timeout), TRIO-094 AC-9 (on/off windows), unmatched_notification_while_pending counts"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28
+++

## Intent

Build epic (AGENTS.md "Build tasks"; TRIO-059 is the template). Planned 2026-10-28 with the operator. Ships the G7SensorKit fork changes from the 2026-10-28 missed-readings investigation (`docs/investigations/2026-10-28-g7-phone-missed-readings/`), so they can be measured while the bad sensor DXCM8o is still on (it ends about 11-03, or 11-08 if it is a 15-day sensor). Also carries the patch 19 refresh that landed after build 233.

## Build facts
- Source: dev (478413770 at planning), on upstream base APP_DEV_VERSION 1.0.2.11 (merge-base 0bdd266c2), the same as build 233.
- G7SensorKit fork: `7fa073c` (TRIO-093 `a1f2474` + TRIO-094 `7fa073c`), pushed by the operator 2026-10-28. Patch 02 repinned to `7fa073c` on 2026-10-28 with repin-g7.sh v1.2 (no push). patch-test: all 16 applied, patch-audit passed. Patch 02 is uncommitted.
- Patch stack: 01, 02, 03, 04, 05, 06, 08, 09, 10, 13, 14, 15, 16, 17, 18, 19.
- Not compiled before the build: TRIO-093 and TRIO-094 have only been through static review.
- Command: to be chosen by the operator (AGENTS.md: ask for flags). Use `--no-sync-upstream` unless the operator decides to include the sync (see below).

## Contains (child tasks)

- TRIO-093: G7 foreground GATT op timeout 2 s → 5 s on phone and foreground watch, plus `command_slow` telemetry (fork `a1f2474`, patch 02)
- TRIO-094: opt-in "Request Missed Readings (Experimental)" G7 setting (active `0x59` backfill on a gap), plus the upstream fix so notifications are no longer dropped while a command is pending, on every path (fork `7fa073c`, patch 02)
- TRIO-086 (refresh, parent stays TRIO-083): Big Glucose Live Activity centred reading, 40/60 column split, 4 h compact chart (patch 19 refresh `2b6eb28dc`, after build 233)
- TRIO-092: Carbs Required notification shows current glucose, drops the 6 h snooze, adds a one-tap "Log N g" action on phone and watch (new patch; design decisions pending, operator AC-6)
- TRIO-064 (tooling, not in the app): repin-g7.sh never pushes; checks the SHA is on origin and stops with the push command if not
- TRIO-096 (tooling, not in the app): patch-audit.sh no longer inherits operator signing (a locked 1Password failed the audit)

## Upstream sync: deferred to build 235 (operator, 2026-10-28)

On 2026-10-28 upstream/dev was at 1.0.2.33 (`c6b47419e`), 163 commits ahead. A scratch-worktree merge conflicted only in `scripts/swiftformat.sh`, which is trivial. The patches still need real porting:
- Upstream replaced the logging stack: `TrioLogger`/os.Logger, a Core Data `AppLogStore`, watch log shipping, and Report a Problem. `SimpleLogReporter` and `IssueReporter` were deleted, and the `.service`/`.default`/`.watchManager`/`.deviceManager` categories are gone. That breaks patch 06 (cloud logging, modify/delete), patch 13 (`debug(.service, …)` no longer compiles), and probably patches 05, 09 and 10.
- Upstream re-pinned G7SensorKit to `f45545185` on `loopandlearn/G7SensorKit` `feat/trio-g7-direct` (Direct mode). The fork must merge that before patch 02 can be repinned on the new base.
- The estimate is a multi-day sync. Tracked separately.
