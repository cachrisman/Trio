+++
uid = "01a0d06c-b57e-7325-8192-4528931b8f7c"
key = "TRIO-065"
title = "Build 228 — Trio 1.0.1 (upstream 1.0.1.5) + circular Glucose Bobble complication, TestFlight 2026-09-24"
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

Build epic (AGENTS.md 'Build tasks'). Built unattended in run .unattended-run/2026-09-23 (TRIO-063 phases A+B).

## Build facts
- Source: dev 1a1c3311d = upstream 1.0.1.5 (as of build 227) + patches 01, 02, 03 (new), 04 (new), 05, 06, 08, 09 (regenerated), 10, 13, 14, 15
- Command: ./ci/local-build.sh --base-branch dev --no-sync-upstream --task <this key>
- --no-sync-upstream because the script's upstream sync pushes origin/dev, and pushing is not an unattended action; this build therefore carries no upstream commits newer than build 227's base.

## Contains (child tasks)
- TRIO-058 — watch forecast applied from every full watch-state update (patch 09)
- TRIO-063 — circular Glucose Bobble complication, phases A and B (patches 03, 04, 09). The task continued after this build and is now a child of build 229 (TRIO-066), so it is not a child of this epic.

## Acceptance criteria
- [x] Uploaded to TestFlight, release recorded
- [x] Installed on phone and watch; circular complication selectable and rendering (operator, 2026-09-24; see Deployment verification)
- [x] Operator: push dev to origin (2026-09-24; origin/dev = dev = 24adf027c)


## Attempt 2026-09-24 00:40 local

- Command: `./ci/local-build.sh --base-branch dev --no-sync-upstream --task TRIO-065`
- Log: `build/artifacts/ci-local-build-20260924-004007.log`
- Base ref: `dev`
- dev: `1a1c3311d`
- upstream/dev: `e41c9db37`
- Xcode: Xcode 27.0


- Outcome: success (ended 2026-09-24 00:55)
- Build number: 228
- TestFlight: uploaded at 00:48:37
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.1-228-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.1-228-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 22s |
| Certificates & Config | 8s |
| Patch Application | 2s |
| Ruby Dependencies | 1s |
| Build IPA | 5m 47s |
| TestFlight Upload | 8m 21s |
| Record Release | 27s |
| TOTAL (Success) | 15m 8s |

## Deployment verification (2026-09-24)

**Installed on both devices (BetterStack, source 1659391, hot table plus S3, UTC):**

| Platform | Build 227 last seen | Build 228 first seen | Build 228 last seen | Build 228 lines |
|---|---|---|---|---|
| iPhone (ios) | 23:07:21 | 23:08:08 | 12:39:20 (still reporting) | 21,922 |
| Watch (watchos) | 23:12:19 | 23:12:25 | 12:39:15 (still reporting) | 6,743 |

No build 227 lines after the 228 cutover on either device.

**Circular complication selectable and rendering (operator, on device).** The operator's screenshots show the new circular complication on two faces. On the Infograph face, 01:0x CEST, it read 52 and "6 m -1", with the trend arrow on the ring. On the Modular face, 01:27 CEST, it read 48 and "5 m -2". Telemetry cannot confirm this independently: the circular complication writes no per-kind log line, only its reload-generation bookkeeping. The complication extension itself was active on 228: 191 `complication_get_timeline_called` lines from the corner provider, 162 reload requests and 36 sleep-gap reloads.

**Health on 228 (23:08 to 12:39 UTC):** 3 iOS errors and 17 warnings. None is new in this build.
- 1 expected "app was unexpectedly terminated" at the 228 install (23:08:08).
- The rest are WatchConnectivity 7007 "not reachable" warnings.
- 3 `settings/temptargets.json` DecodingError.typeMismatch errors. These are pre-existing: 21 on build 226 (since 2026-09-17) and 9 on 227. Not a 228 regression; worth its own task.

**What 228 does not yet contain.** The on-device feedback round and Phase C (TRIO-063, 2026-09-24):
- Inside-ring bigger bobble.
- Background drawn as content: the tint did not paint on 228.
- Rename to "Trio Glucose Bobble".
- Corner-complication age logic.
- Phone-configurable settings.

These are in patches 03, 04, 09 and 13 on dev and need the next build.
