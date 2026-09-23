+++
uid = "01a0a959-25fb-76f6-b8df-5f630eefe019"
key = "TRIO-055"
title = "Investigate: low-glucose-soon notifications dedup (PR #807) bypassed by something in upstream 0.8.4.78→0.8.4.106"
status = "done"
kind = "code"
source = "human"
created = 2026-09-16
updated = 2026-09-23
touched = 2026-09-23
closed = 2026-09-23
first_closed = 2026-09-23
accepted_by = "Charlie"
accepted_at = 2026-09-23
owner = "me"
tags = ["notifications", "glucose-alerts", "upstream-sync", "regression"]
parent = "01a0aa42-ff8d-77fe-9978-f6b2a37397b3"

[[sessions]]
host = "claude-code"
ref = "4a107cf2-b5ad-488b-9236-ae68953aae8e"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T10:42:39+00:00"

[[sessions]]
host = "claude-code"
ref = "18f7a8fa-a707-43c7-997c-fe54816c638b"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T10:42:39+00:00"

[[reviews]]
run_id = "6cff2985-6918-4500-b464-cb97890ec87a"
model_family = "codex"
verdict = "pass"
reviewed_commit = "cfba1ff18b012037fd094a0826119cf718d26977"
reviewed_paths = ["Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift", "TrioTests/GlucoseAlertCoordinatorTests.swift"]
recorded_at = "2026-09-16T10:42:39+00:00"

[tldr]
source_digest = "sha256:6ab8f03ac1e846301386c2bd55e7635fd5786ca6501971981552333628896b05"
prompt_version = 2
purpose = "Fixes: CGM reading updates retract forecastedLow alarms, re-delivering \"Low Glucose Soon\" every loop cycle."
generated = "2026-09-16T10:44:00.179325+00:00"
+++

## TL;DR

- **Fixes:** CGM reading updates retract forecastedLow alarms, re-delivering "Low Glucose Soon" every loop cycle.
- **State:** review. Authored by claude. 1 review: codex pass.
- **Open:** All 3 criteria resolved; needs review or acceptance

<!-- prose -->
The fix for CGM updates retracting forecastedLow alarms and re-delivering "Low Glucose Soon" every loop cycle is in review. All three criteria are met, and codex has passed the review.
<!-- /tldr -->

## Intent

Operator report 2026-09-16: after the upstream sync (0.8.4.78 → 0.8.4.106, TRIO-052, builds 224/225) "low glucose soon" notifications behave as if something new has **gone around** the deduplication the operator added in upstream PR https://github.com/nightscout/Trio/pull/807 (accepted earlier). Find what changed upstream in that range around low-glucose-soon / predictive-low notifications and why #807's dedup no longer covers it.

## Where to look

- The 0.8.4.78→.106 range (`git log 9e841b138..9a648bf7c`) for anything touching glucose alerts / notifications: `Trio/Sources/Services/Notifications/`, `GlucoseAlertCoordinator`, `UserNotificationsManager`, `NotLoopingMonitor`, alarm gating/volume PR #1510 (`trioneer-dev/fix/alarm-gating-and-volume`), device-alarm-sounds PR #1375, glucose display-only gate #1512.
- Re-read #807's diff to pin exactly which code path it dedups (identifier/threadIdentifier? a "last notified" timestamp? a suppression window?) and confirm whether that path still exists at .106 or was refactored around (a new notification producer, a new category/identifier, or a second sender that never went through the dedup).
- Cross-check with BetterStack: notification-send events on builds 224/225 vs 223 (`GROUP BY build, platform`) to see the duplicate pattern in production.

## Acceptance criteria

- [x] The upstream commit(s) that introduced the new low-glucose-soon path identified, with the reason #807's dedup does not apply
- [x] Reproduction described (what sequence of readings triggers the duplicates)
- [x] Fix proposed: as a fork patch and/or an upstream PR extending #807's dedup to the new path


## Findings (2026-09-16)

### Premise correction: #807's dedup was not bypassed — it no longer exists

#807's dedup (`lastGlucoseAlertToken` in `BaseUserNotificationsManager.sendGlucoseNotification`) was deleted upstream on 2026-06-12 in `380c672d8` "Glucose Alarms: user-configurable list of alarms", which moved every glucose alarm (urgentLow / low / forecastedLow / high / carbsRequired) into `GlucoseAlertCoordinator` → `TrioAlertManager`. That commit first shipped in the fork at build 217, so it was already gone at 0.8.4.78 (build 223). The coordinator has its own dedup: an in-memory `firingAlertIDs` set (fire once, no re-fire until retracted) plus `AlertThrottler` (5-min minimum per alert identifier, **reset on retract**). No fork patch touches any of this — patches 10/13 only change DI resolution.

### What changed .78 → .106: `22dbce076` "Fire forecast-low when the CGM owns glucose alerts" (fixes #1428)

At .78 `evaluateForecast` had the same CGM-ownership guard as the reading path, so on the fork's G7 (`G7CGMManager` → `CGMManagerAlertOwnership.providesOwnGlucoseAlerts == true`, "Use CGM App Alerts" on) **Low Glucose Soon never fired at all** — BetterStack shows 0 `forecastedLow` issues on build 223 across 8 days. `22dbce076` removed that guard from `evaluateForecast` only. It left the reading path's `guard effectiveTrioAlertsEnabled else { retractAllFiringIfNeeded(); return }` (`GlucoseAlertCoordinator.swift:132-133`) untouched.

### Root cause: the reading path retracts *every* firing alarm on *every* CGM reading when the CGM owns alerts

Per 5-minute cycle on the fork (G7, CGM owns reading alerts):

1. New reading stored → `glucoseStorage.updatePublisher` → `evaluateGlucoseAlarms()` → `effectiveTrioAlertsEnabled == false` → `retractAllFiringIfNeeded()` retracts **all** firing alarms including forecastedLow and carbsRequired: delivered notification removed, in-app modal dismissed, `firingAlertIDs` cleared, `AlertThrottler` reset. (The coalescer log shows `glucoseStored` ×3 per cycle, so this runs several times.)
2. ~3 s later the loop's determination → `evaluateForecast` → forecast still ≤ threshold → `fireIfNeeded` → fresh `issueAlert` → new notification with sound + new modal.

Net effect: while the +20 min forecast stays below threshold, "Low Glucose Soon" is re-delivered every loop cycle. The 5-min throttle never engages because retract resets it. `carbsRequired` has had the identical cycle since 380c672d8 (it never had the guard) — build 223 shows 8–48 `carbsRequired` issues/day, same mechanism.

### Evidence (BetterStack `t491594.trio`, `message LIKE '%TrioAlertManager%'`)

- Build 225, 2026-09-16 05:33 → 08:51: `issueAlert Trio.glucose.forecastedLow.9015DFB9-…` (same alarm UUID) at 05:33, 05:51, 05:56, 06:01, 06:06, 06:11, 06:16, 06:21, 06:26, 06:31, … 08:51 — every ~5 min, aligned a few seconds after each `egv_received`. Zero `TrioAlertManager throttled` / `muted` lines → each issue was delivered, and the throttler can only have been reset by `retractAlert`.
- Per day: build 223 → forecastedLow 0/day, carbsRequired 8–48/day; build 225 → forecastedLow 55 (9/15), 30 (9/16 by 09:16), carbsRequired 28 / 22.
- No app relaunch in the window (continuous G7 BLE observer events, no lifecycle lines), ruling out the "firingAlertIDs not persisted across launch" explanation.
- `trio.aps.loop.notActive` every 5 min is NotLoopingMonitor re-arming a `.delayed` alert (arm, not delivery) — unrelated.
- Upstream `dev` as of 2026-09-16 (66 commits past .106) has not changed `GlucoseAlertCoordinator.swift`; no upstream issue reports the repeat (only closed #1428).

### Reproduction

Any CGM in `CGMManagerAlertOwnership` (Dexcom G5/G6/G7, Libre, xDrip) with "Use CGM App Alerts" left on (the default), one enabled Low Glucose Soon alarm, and a forecast whose min(IOB/COB/UAM/ZT) at +20 min stays ≤ threshold for more than one loop cycle. Expected: one alert until recovery (≥ threshold + 5) or snooze. Actual: alert re-delivered on every loop cycle. Same for Carbs Required while `carbsReq` stays ≥ threshold.

### Proposed fix

**Upstream PR (root cause, one site):** in `evaluateGlucoseAlarms()` (`GlucoseAlertCoordinator.swift:132-133`), when the CGM owns reading alerts, retract only the firing alarms whose `type.isReadingDriven` is true instead of calling `retractAllFiringIfNeeded()`. Forecast and carbs-required alarms are determination-driven and must keep their firing state across reading updates — the same reasoning `22dbce076` used to un-guard `evaluateForecast`. `retractAllFiringIfNeeded()` then has no remaining caller and can be deleted (or kept for snooze). Add a test that a firing forecastedLow / carbsRequired survives a reading-path evaluation under CGM ownership, alongside the existing `CGMOwnershipSuppressionScopeTests`. This also fixes the pre-existing carbsRequired repeat.

**Fork patch (until merged):** same commit on a feature branch → new patch (`14-forecast-low-retract-scope` or similar) via the normal patch-stack workflow; no interaction with existing patches (none touch `Services/Alerts/`).

**Not proposed:** re-adding #807-style token dedup — the coordinator's `firingAlertIDs` already is the dedup; it is being cleared, not bypassed. Changing `retractAlert`'s throttler reset would mask the bug and break legitimate retract→re-issue on real recovery.

### Secondary observation (not a bug, for the PR discussion)

With the reading path suppressed, `lowFamilyFiring` in `evaluateForecast` is always false, so Trio's "may go below X in 20 min" can sit alongside the Dexcom app's actual-low alarm. Acceptable per #1428's design; mention only.


## Implementation (2026-09-16)

- Clean worktree on `upstream/dev` (`cfba1ff18`, 66 commits past .106): scratchpad `trio-upstream-fix`, branch `fix/glucose-alarm-retract-scope`, commit `eb1777fb5` — coordinator retracts only `isReadingDriven` alarms under CGM ownership via new static `alarmsToRetractWhenCGMOwnsAlerts(firing:in:)`; `retractAllFiringIfNeeded` removed (no other caller); 3 tests in `CGMOwnershipSuppressionScopeTests`. No fork content in the branch or commit message.
- Authored via `task-relay implement --backend claude` (2 runs, PASSED); codex review `gpt-5.6-terra` high: 0 high / 0 medium / 1 low (tests cover the helper only — accepted, matches the file's existing static-test pattern; noted in PR body). SwiftFormat `--lint` with `scripts/swiftformat.sh` rules: clean.
- Fork carrier: `patches/15-glucose-alarm-retract-scope.patch` committed to dev at `690212d04`; `patch-test.sh` + `patch-audit.sh` PASSED.
- Not run: unit tests / build (submodules not initialised in the clean worktree; upstream CI runs `Trio Tests` on the PR).
- PR body drafted at scratchpad `pr-body-glucose-alarm-retract-scope.md`. Operator: amend author/signature to own identity before pushing (commit is agent-signed as agent@chrisman.io), push branch to own GitHub fork, open PR against `nightscout/Trio:dev`. Fix both Low Glucose Soon and Carbs Required per operator instruction.


Shipped in build 226 (TRIO-059).


## Validation on build 226 (2026-09-16)

Same scenario that repeated on build 225 (90 g meal + bolus 14:3x local, forecast diving below threshold; `minPredBG` 12 → 9 → 12 → −3 across loops at 12:34 / 12:36 / 12:41 / 12:46 UTC):

- `issueAlert Trio.glucose.carbsRequired.88DC2F38…` at 12:34:21 UTC — **once**; not re-issued on the 12:36, 12:41, 12:46 loops although carbs stayed required. On 225 this alarm re-fired every loop.
- `issueAlert Trio.glucose.forecastedLow.9015DFB9…` at 12:46:13 UTC — **once**; operator received exactly one "Low Glucose Soon" notification (reported 15:00 local) and no repeats over the following three loop cycles with the forecast still below threshold. On 225 this alarm re-fired every loop.
- Zero `TrioAlertManager throttled/muted` lines; zero reading-driven (`low`/`urgentLow`/`high`) issues — CGM-ownership suppression of the reading path is intact.
- Caveat: phone log upload is batched; loop lines after 12:46 UTC were not yet in BetterStack at 13:01 UTC. The operator's on-device observation covers that window; the 24 h check below closes it.

## Acceptance criteria — validation

- [x] Build 226 on device: one notification per breach episode for Low Glucose Soon and Carbs Required, no per-loop repeats (operator, 2026-09-16 15:00 local; BetterStack 12:34–12:46 UTC)
- [x] 24 h on build 226 (query `message LIKE '%issueAlert Trio.glucose.%'` grouped by alarm UUID and 10-min bucket): number of `forecastedLow` / `carbsRequired` issues per day is in the single digits and each corresponds to a distinct breach episode (a recovery ≥ threshold + 5 or a snooze between consecutive issues), vs 30–55/day on 225
- [x] 24 h on build 226: reading-driven issues stay at 0 with "Use CGM App Alerts" on
- [x] Retraction on recovery still works: after a low episode ends, the next breach produces a fresh notification (i.e. the alarm was retracted, not stuck in `firingAlertIDs`) — observe one recovery→re-breach sequence


## Release note

Low Glucose Soon and Carbs Required alarms no longer re-alert on every loop cycle when the CGM app owns glucose alerts (Dexcom G6/G7, Libre, xDrip); one alert per breach episode, retracted on recovery or snooze.

## 24h validation (2026-09-17)

Scheduled run, BetterStack `t491594.trio`, iOS, `message LIKE '%TrioAlertManager.issueAlert Trio.glucose.%'`, window 2026-09-16 11:30 → 2026-09-17 ~11:35 UTC. Only build 226 logged in the window (no 226 issues before 11:30 on 9/16; the 9/16 build-225 rows below are from before the upgrade).

**Per-day issue counts (last 10 days, all builds):**

| day | build | forecastedLow | carbsRequired |
|---|---|---|---|
| 09-09 … 09-14 | 223 | 0 | 40 / 21 / 17 / 48 / 30 / 13 |
| 09-15 | 225 | 55 | 28 |
| 09-16 (→ ~09:20 UTC) | 225 | 30 | 22 |
| 09-16 (11:30 → 24:00 UTC) | 226 | 5 | 5 |
| 09-17 (→ 11:35 UTC) | 226 | 3 | 3 |

24 h on 226: forecastedLow 8, carbsRequired 8. Every 10-minute bucket holds exactly one issue; no bucket has two.

**Every 226 issue (UTC), one alarm UUID per type throughout (`forecastedLow.9015DFB9-…`, `carbsRequired.88DC2F38-…`):**

- forecastedLow: 09-16 12:46:13, 15:56:21, 16:31:06, 17:51:11, 19:16:13; 09-17 05:46:09, 06:06:12, 11:06:09 → gaps 190 / 35 / 80 / 85 / 630 / 20 / 300 min.
- carbsRequired: 09-16 12:34:21, 16:06:14, 18:01:11, 19:11:13, 19:31:11; 09-17 06:31:13, 11:03:49, 11:21:08 → gaps 212 / 115 / 70 / 20 / 660 / 272 / 17 min.

Minimum gap 17 min; on 225 the same UUID was issued every 5 min. The three sub-30-min gaps (forecastedLow 05:46→06:06, carbsRequired 19:11→19:31 and 11:03→11:21) match the documented dismissal path: swiping / dismissing the modal is an ack **plus a 15-min per-type snooze** (`TrioAlertManager.swift` lines 163 and 391), the coordinator retracts a snoozed alarm (`evaluateForecast` / `evaluateCarbsRequired` guard `!isAlarmSnoozed`) and re-fires fresh on the first evaluation after the snooze ends — 15 min + the next 5-min loop = 17–20 min. Neither snooze nor retract is logged, so this is inference from code + timing, not a logged event; the loop lines confirm the condition was still breached at re-issue in all three cases (e.g. minPredBG −121 … −96 across 19:11→19:31, −438 … −297 across 11:03→11:21).

**Throttled / muted:** 0 `TrioAlertManager throttled` and 0 `TrioAlertManager muted` lines on 226 in the window — nothing is re-issuing and being suppressed by the 5-min throttle.

**Reading-driven alarms on 226:** 0 issues of `low` / `urgentLow` / `high` — CGM-ownership suppression of the reading path intact.

**Recovery → re-breach:** forecastedLow issued 16:31:06 → loop lines 16:41–17:26 show recovery (currentBG 54 → 134, minPredBG 53 → 153, well above threshold + 5 for 45 min) → forecast dives again 17:31–17:51 (minPredBG −46 … −131) → fresh issue 17:51:11. Same shape for carbsRequired 18:01 → recovery 18:11–18:21 (minPredBG 105–143) → 19:11 re-issue. The alarm was retracted and re-fired, not stuck in `firingAlertIDs`. Caveat: because retract isn't logged, the log can't tell whether that specific retraction was the recovery margin or a 15-min dismissal snooze that happened to precede the recovery; either way the retract → fresh-fire path works, and a snooze alone can't explain an 80-min gap (the snooze ends at 15 min and the condition would have re-fired if still breached).

**Verdict:** per-loop re-delivery is gone on 226. forecastedLow 55/30 per day (225) → 8 per 24 h (226); carbsRequired 28/22 → 8. Criterion 2 met, criterion 3 met, criterion 4 met (observed, with the retract-attribution caveat above).


## 7-day validation (2026-09-23) — evidence for the upstream PR

BetterStack `t491594.trio`, iOS, `TrioAlertManager.issueAlert Trio.glucose.*`, 2026-09-15 → 2026-09-23 (builds 225 pre-fix, 226/227 post-fix).

**Same-day before/after, one `forecastedLow` alarm id, 2026-09-16 (build swapped mid-day, UTC):**
- 225, 05:33–08:51 → 30 issues: 05:33, 05:51, 05:56, 06:01, 06:06, 06:11, 06:16, 06:21, 06:26, 06:31, 06:36, 06:41, 06:46, 06:51, 06:56, 07:01, 07:06, 07:11, 07:16, 07:21, 07:26, 07:31, 07:36, 07:46, 07:51, 08:01, 08:21, 08:41, 08:46, 08:51 (one per loop cycle, single episode)
- 226, 12:46–23:59 → 5 issues: 12:46, 15:56, 16:31, 17:51, 19:16 (separate episodes)

**Gap between consecutive issues of the same alarm id:**

| alarm | version | pairs | ≤6 min | median gap | min gap |
|---|---|---|---|---|---|
| forecastedLow | 225 (pre) | 49 | 40 (81.6%) | 5 min | 5 min |
| forecastedLow | 226/227 (post) | 52 | 0 (0%) | 90 min | 10 min |
| carbsRequired | 225 (pre) | 30 | 25 (83.3%) | 5 min | 5 min |
| carbsRequired | 226/227 (post) | 40 | 0 (0%) | 135 min | 18 min |

**Per-day issues (post-fix):** forecastedLow 5/10/8/8/1/5/11/1/7, carbsRequired 5/8/6/8/4/3/7/0/3 across 09-16→09-23, vs 20 and 30 forecastedLow on 09-15/09-16 under 225.

More post-fix pairs (52/40 over 7 days) than pre-fix (49/30 over 2) → the alarms are not silenced, and since a re-fire requires a prior retract, recovery→re-breach demonstrably still works (no alarm stuck in `firingAlertIDs`). Reading-driven issues (`low`/`urgentLow`/`high`) 0 throughout → CGM-ownership suppression of the reading path intact. Zero `throttled` lines → every issue was a real delivery, not a suppressed duplicate.

**PR readiness:** branch `fix/glucose-alarm-retract-scope` = `042188e0e` (single commit, Charlie Chrisman <charlie.chrisman@gmail.com>, signed), 2 files (coordinator + tests), pushed to origin. `upstream/dev` has advanced 49 commits since the branch point but touched neither file — `git merge-tree` reports no conflict. No fork content in the branch or message. PR body: scratchpad `pr-body-glucose-alarm-retract-scope.md`.


**Upstream PR opened 2026-09-23:** https://github.com/nightscout/Trio/pull/1573 (base `dev`, head `fix/glucose-alarm-retract-scope` @ `042188e0e`, mergeable, signature verified on GitHub, 2 files +57/-6). CI: "Run Unit Tests" and "Algorithm Package (swift test)" running at open.
