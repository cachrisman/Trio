+++
uid = "01a0aa42-ff8d-77fe-9978-f6b2a37397b3"
key = "TRIO-059"
title = "Build 226 — Trio 1.0.0 (upstream 1.0.0.3) + patch stack, TestFlight 2026-09-16"
status = "done"
kind = "epic"
source = "human"
created = 2026-09-16
updated = 2026-09-23
touched = 2026-09-23
closed = 2026-09-23
first_closed = 2026-09-23
accepted_by = "Charlie"
accepted_at = 2026-09-23
owner = "me"
tags = ["build", "testflight"]
+++

## Intent

Build epic: one per TestFlight build (see AGENTS.md 'Build tasks'). Children are the tasks whose work ships in this build.

## Build facts
- Build number: 226 (Trio 1.0.0, APP_DEV_VERSION 1.0.0.3), Xcode 27.0 (27A266a) — first build on Xcode 27
- Source: dev 1095b0957 = upstream/dev cfba1ff18 (1.0.0.3) merged as 2516b23c4 + patch commits 690212d04 (add 15), 227d9cf28 (regen 06/10/13), 1095b0957 (regen 01)
- Patches applied (sha256 prefix from log): 01 b9e080c0d532, 02 6a51a9da66b2, 05 4272ccaa8262, 06 1b760f7dc511, 08 8302d86669ab, 09 9c7adc1c0632, 10 b901679eb839, 13 8524fbfb9ef9, 14 5a24bab7093b, 15 b128c37dd822
- Command: ./ci/local-build.sh --base-branch dev --no-sync-upstream (sync had been done by run 1)
- Log: build/artifacts/ci-local-build-20260916-131835.log
- GitHub release: https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.0-226-localCI (private backup, draft)
- TestFlight: uploaded 13:27 local; installed on phone + watch by operator 2026-09-16 ~14:10

## Attempts
1. 13:00 ci-local-build-20260916-130030.log — script sync merged+pushed dev, FAILED at patch 06 (expected; reconciliation TRIO-056)
2. 13:06 ci-local-build-20260916-130654.log — FAILED at increment_build_number: Xcode 27 licence not accepted (operator: sudo xcodebuild -license accept)
3. 13:09 ci-local-build-20260916-130957.log — ARCHIVE FAILED: NightscoutManager.swift:695 'closedLoop: s.closedLoop' (patch 01 vs #1511 DosingMode) → patch 01 regenerated
4. 13:18 ci-local-build-20260916-131835.log — SUCCESS

## Stage summary (attempt 4)
| Stage | Duration |
|---|---|
| Environment & Tool Validation | 1s |
| Worktree Setup | 41s |
| Certificates & Config | 8s |
| Patch Application | 3s |
| Ruby Dependencies | 0s |
| Build IPA | 5m 46s |
| TestFlight Upload | 7m 46s |
| Record Release | 31s |
| TOTAL (Success) | 14m 56s |

## Contains (child tasks)
- TRIO-055 — Low Glucose Soon / Carbs Required re-fire fix (patch 15; upstream PR branch fix/glucose-alarm-retract-scope)
- TRIO-056 — upstream 1.0.0.3 sync, patches 01/06/10/13 reconciled

## Known issues found on this build
- TRIO-058 — watch forecast applied only when the full-state message wins the reading race (pre-existing, patch 09)
- TRIO-057 — mid-stack-update provenance trailer truncation (tooling, pre-existing)

## Acceptance criteria
- [x] Uploaded to TestFlight, release recorded
- [x] Installed and running on phone and watch (operator, 2026-09-16)
- [x] BetterStack: forecastedLow / carbsRequired issueAlert no longer at loop cadence on build 226 (24 h: 8 / 8 issues, min gap 17 min vs 5 min on 225 — TRIO-055 "24h validation (2026-09-17)")
- [x] Operator: push dev 1095b0957 to origin (origin/dev at 5f14fe99a contains it, verified 2026-09-17)

## Validation (2026-09-17)

24 h BetterStack check on build 226 recorded on TRIO-055 ("24h validation (2026-09-17)"): forecastedLow 8 and carbsRequired 8 issues in 24 h, one per 10-min bucket, minimum same-UUID gap 17 min (225: same UUID every 5 min, 55/30 and 28/22 per day); 0 reading-driven issues, 0 throttled/muted lines; one recovery→re-breach sequence observed. dev 1095b0957 confirmed on origin/dev. All four criteria met; epic stays at review for operator acceptance (children TRIO-055 and TRIO-056 are at review, not yet accepted).
