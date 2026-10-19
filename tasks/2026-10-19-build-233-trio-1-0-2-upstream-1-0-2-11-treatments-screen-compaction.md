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


## Attempt 2026-10-19 22:42 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --no-reapply-stash --task TRIO-083`
- Log: `build/artifacts/ci-local-build-20261019-224250.log`
- Base ref: `dev`
- dev: `3d2c78f7f`
- upstream/dev: `bcebda2f5`
- Xcode: Xcode 27.1


- Outcome: FAILED (exit 1) (ended 2026-10-19 22:43)
- Failed stage: Ruby Dependencies
- Last errors:

```
bundler: failed to load command: fastlane (/opt/homebrew/lib/ruby/gems/4.0.0/bin/fastlane)
First, try this link to see if there are any existing issue reports for this error:
[stage] ✗ Failed: Ruby Dependencies (3s)
```


Cause (attempt 2026-10-19 22:42): failed at Ruby Dependencies before any compile. The upstream sync bumped fastlane 2.236.1 -> 2.240.1 (6b9bd7e47), which adds rdoc 8.1.0. Installing it makes RubyGems rewrite /opt/homebrew/lib/ruby/gems/4.0.0/plugins/rdoc_plugin.rb, a symlink to a read-only (0444) file in the Homebrew Cellar (ruby 4.0.7), so the write fails with Errno::EACCES. This is a machine environment problem, not a patch-stack one; no task carries a code fix.


## Attempt 2026-10-19 22:47 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --no-reapply-stash --task TRIO-083`
- Log: `build/artifacts/ci-local-build-20261019-224701.log`
- Base ref: `dev`
- dev: `3d2c78f7f`
- upstream/dev: `bcebda2f5`
- Xcode: Xcode 27.1


- Outcome: success (ended 2026-10-19 23:02)
- Build number: 233
- TestFlight: uploaded at 22:55:20
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.2-233-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.2-233-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 18s |
| Certificates & Config | 11s |
| Patch Application | 2s |
| Ruby Dependencies | 0s |
| Build IPA | 5m 46s |
| TestFlight Upload | 8m 42s |
| Record Release | 30s |
| TOTAL (Success) | 15m 29s |


## Release notes gap (2026-10-19)

The GitHub release body lists every child task with its release note, but its "Patches:" list is empty. During Record Release the tag step printed `(error parsing patches: Expecting value: line 1 column 1 (char 0))`. The release manifest asset and the build log still record the 16 patches with their sha256 prefixes. Record Release also pushed temp branch `ci-build/trio-v1.0.2-233-localCI-20261019T210210Z` to cachrisman/Trio so the tag can point at the patched fork commit 0f51c8c9d, which is what the script normally does.
