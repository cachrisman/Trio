+++
uid = "01a0cb09-a12c-764a-ab60-aa3c13b162e4"
key = "TRIO-062"
title = "Build — Trio 1.0.1 (upstream 1.0.1.5) + patch stack, TestFlight 2026-09-22"
status = "done"
kind = "epic"
source = "human"
created = 2026-09-22
updated = 2026-09-24
touched = 2026-09-24
closed = 2026-09-24
first_closed = 2026-09-24
accepted_by = "Charlie"
accepted_at = 2026-09-24
owner = "me"
tags = ["build", "testflight", "upstream-sync"]

[[sessions]]
host = "claude-code"
ref = "d713caa8-60d9-4a65-b340-a2915779613a"
model_family = "ollama"
started = 2026-09-23
role = "author"
started_at = "2026-09-22T22:20:45+00:00"

[[sessions]]
host = "claude-code"
ref = "cd48b896-af5e-4293-ab5e-111ecd60e310"
model_family = "ollama"
started = 2026-09-23
role = "author"
started_at = "2026-09-22T22:20:45+00:00"
+++

## Intent

Sync fork `dev` with upstream `dev` (1.0.0.7 → 1.0.1.5, v1.0.1 release), reconcile the patch stack, and ship a TestFlight build.

## Pre-sync analysis (2026-09-22)

Trial `git am --3way` of all 10 patches onto `upstream/dev` in a throwaway worktree:

- Clean: 01, 05, 06, 08, 14, 15.
- **02 g7-reading-time-with-seconds** — gitlink conflict: upstream bumped G7SensorKit 1486241 → loopandlearn c2abb4f (translations-only, 2 `Localizable.xcstrings`, 9 lines).
- **09 watch-g7** — content conflict in `Trio Watch Complication/TrioWatchComplication.swift`: upstream f63fcf06e wrapped the stub corner complication in `#if os(watchOS)` for local iOS compiles; our patch replaces that code (corner/inline/rectangular families).
- 10, 13 — failed only as a cascade of 09; apply cleanly once 09 resolves.
- Upstream alarm changes (not-looping escalation ladder, time-sensitive snooze fix, device alarms default silent except Critical) touch no patch-scoped file; patch 15 applies cleanly. The device-alarm default change is seed/decode-only — existing configuration is untouched.

## Decisions

- **Commits in this `deny` repo:** operator clarified — agent runs plain `git commit` under the operator identity, operator approves via 1Password Touch ID. No agent key, no stage-and-handoff.
- **No pushes.** Build runs with `--no-sync-upstream` (the auto-sync pushes `origin/dev`).
- **Regeneration route: feature-branch merge + `mid-stack-update.sh`** (route A), not manual `generate-patch.sh` (route B). Deciding fact: provenance trailers (`Trio-Patch-Source-*`) are written only by `mid-stack-update.sh` (`scripts/mid-stack-update.sh:1315`); route B would ship 02/09 without provenance and break the next cherry-pick computation. Matches the 1.0.0.3 precedent (TRIO-059).
- **Patch 02 via `scripts/repin-g7.sh`** (operator direction) — it re-derives the base pin from `dev:G7SensorKit`. Keep fork pin 0013c90; upstream's c2abb4f is translations only.
- **Patch 09 complication:** keep the feature branch's complication; upstream's guard only covered the old stub corner view.
- **Patch 09 `AppleWatchManager.swift`:** keep branch's weak-self handling + upstream's new override/temp-target guard on the invalid-data branch.
- **`AppDelegate.swift`** (outside 09's scope) on `feature/watch-g7`: take `feature/cloud-logging`'s 1.0.0.3 resolution (7cc707240), which is what patch 06 ships. Operator directed: offload per the task-relay gate, no bypass.

## Issues encountered

- Local `dev` was 25 behind `origin/dev` (upstream ≤1.0.0.7 already merged there as c1cfd21e7) — fast-forwarded before merging upstream.
- `repin-g7.sh` always invokes `git push` on the G7 fork (a no-op here: fork HEAD 0013c90 == origin/main), which conflicts with the never-push rule — operator directed using it anyway.
- `feature/g7sensorkit-timestamp-seconds` pins G7SensorKit 7232e55 while patch 02 ships 0013c90 — `repin-g7.sh` updates the patch, never the branch. A merge of dev into that branch (7b259641f) was made before switching to repin-g7.
- Merging dev into `feature/watch-g7` conflicts in 4 paths (complication, AppleWatchManager, AppDelegate, G7SensorKit), not just the 1 seen at patch level — the branch carries an older cloud-logging snapshot.
- git rerere auto-resolved the complication and AppleWatchManager from recorded resolutions; both verified against the sides before accepting.
- task-relay gate blocked writing `AppDelegate.swift` from a git blob (a file-version take, not authored code).

## Progress

- `dev` merged with upstream/dev: 460a35322 (signed, local only).

## Acceptance criteria

_Authoritative list, updated 2026-09-24. The later checklist sections are dated snapshots of progress; this list is the final status._

- [x] Patch 02 re-pinned via `repin-g7.sh` (v1.1); base pin c2abb4f matches `dev:G7SensorKit`, fork pin 0013c90 unchanged
- [x] Patch 09 regenerated via `mid-stack-update.sh --force-from-feature-branch` with fresh provenance trailers (base 460a35322, tip a61265484)
- [x] Full old-vs-new diff reviewed for 02 and 09, deletions especially. 02: only the base pin changed. 09: 28/29 files byte-identical, including every `AppleWatchManager.swift` hunk; the upstream guard that the patch-level 3-way merge added now sits in the `dev` base, and the patch applies around it. Only `TrioWatchComplication.swift` changed (branch complication kept).
- [x] `patch-test.sh` incl. `patch-audit.sh` passes: 32 warnings (the +1 vs 31 is patch 15, predating this sync), pump-migration sentinel ✓, drift CLEAN
- [x] Build + TestFlight upload succeeded with `--no-sync-upstream`: build 227, uploaded 2026-09-22 23:59, release trio-v1.0.1-227-localCI
- [x] Patches 02/09 + `scripts/repin-g7.sh` committed after the operator installed build 227: b18da9419, 92ab21640
- [x] `dev`, `feature/watch-g7` and `feature/g7sensorkit-timestamp-seconds` pushed (fast-forwards) on operator authorization, 2026-09-23
- [x] BetterStack verification of build 227 in production: two windows, 2026-09-23 00:07 → 2026-09-24 00:12 CEST. Loop and not-looping ladder OK, no crashes; the complication "gaps" were late-upload ingestion artifacts (see Correction section).

## Progress — 2026-09-22 (cont.)

- **Patch 02 re-pinned** via `repin-g7.sh --skip-test`: base `-Subproject` 1486241 → c2abb4f (matches `dev:G7SensorKit`), fork pin 0013c90 unchanged; fork push was a no-op ("Everything up-to-date"). Uncommitted, per the patch lifecycle.
- **`repin-g7.sh` bug found and fixed (v1.1):** the early exit fired whenever the fork pin was unchanged, so the base-side refresh (its header's point 3 — exactly the upstream-bump case) could never run; and the post-rewrite sanity check died on a base-only refresh because old == new pin. Both fixed via ollama offloads (notes `20260922-233346-86359`, `20260922-233621-90196`, both PASSED); diff reviewed. `--skip-test` was needed because the script rolls the repin back when `patch-test.sh` fails, and it will fail until 09 is regenerated.
- **`feature/watch-g7` merge** in progress in a scratch worktree: complication (= branch version, via rerere) and `AppleWatchManager.swift` (branch `self?` + upstream guard) resolved and verified; G7SensorKit to keep branch pin 509994f.

## Issues (cont.)

- **AppDelegate offload — three attempts, none landed:** (1) ollama surgical: the conflict's `=======` line collides with the SEARCH/REPLACE delimiter → FAILED; (2) codex: edited a clean checkout of HEAD rather than the mid-merge file → diff did not apply; (3) ollama `--edit-format whole`: resolution correct but a leading space added to ~60 untouched lines → discarded. Target is known exactly: `feature/cloud-logging`'s blob 7cc707240.
- **Gate does not see notes written in a scratch worktree** (`wg7/.task-relay/notes`); it checks only `Trio-dev/.task-relay/notes` and `~/.task-relay/notes/<project-id>`. So even a successful offload there would not unlock the follow-up write. Blocked on operator decision.
- `feature/g7sensorkit-timestamp-seconds` carries the merge 7b259641f from before the switch to `repin-g7.sh`; harmless (pin 0013c90 = patch 02), left in place pending operator call.

## Patch regeneration — 2026-09-22

- `AppDelegate.swift` written from blob 7cc707240 by the operator (the gate did not see the scratch-worktree offload notes); `feature/watch-g7` merge committed as **a61265484**.
- **Patch 09** regenerated: `mid-stack-update.sh --patch 09 --force-from-feature-branch "<upstream 1.0.1.5 sync; cherry-pick mode cannot apply the old 09>"` — same route as patch 02 in the 0.8.4.106 sync (TRIO-052). Result: all 10 patches apply, `patch-audit: PASSED (32 warnings)`, pump-migration sentinel ✓, drift CLEAN (23/23 verifiable files match the branch), 29 files (unchanged). Fresh trailers: base 460a35322, tip a61265484.
- **Old-vs-new review, patch 09:** 28 of 29 per-file sections byte-identical (ignoring `index`/`@@` lines), including every `AppleWatchManager.swift` hunk. Only `TrioWatchComplication.swift` differs — the new patch additionally deletes upstream f63fcf06e's `#if os(watchOS)` guards / `supportedFamilies` helper, restoring the branch's complication (verified equal by the drift check).
- **Old-vs-new review, patch 02:** only the base `-Subproject` line and `index` before-abbrev changed (1486241 → c2abb4f).
- Audit count 31 → 32 is not from this sync: 31 was recorded at build 224, before patch 15 existed; patch 15's `GlucoseAlertCoordinator.swift` (+20/−6) is the 32nd.


## Attempt 2026-09-22 23:51 local

- Command: `./ci/local-build.sh --no-sync-upstream --include-untracked --task TRIO-062`
- Log: `build/artifacts/ci-local-build-20260922-235133.log`
- Base ref: `dev`
- dev: `460a35322`
- upstream/dev: `e41c9db37`
- Xcode: Xcode 27.0


- Outcome: success (ended 2026-09-23 00:05)
- Build number: 227
- TestFlight: uploaded at 23:59:12
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.1-227-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.1-227-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 21s |
| Certificates & Config | 7s |
| Patch Application | 2s |
| Ruby Dependencies | 0s |
| Build IPA | 5m 16s |
| TestFlight Upload | 7m 34s |
| Record Release | 28s |
| TOTAL (Success) | 13m 48s |

## Acceptance criteria (status 2026-09-23)

- [x] Patch 02 re-pinned via `repin-g7.sh` (v1.1); base pin c2abb4f matches `dev:G7SensorKit`
- [x] Patch 09 regenerated via `mid-stack-update.sh` with fresh provenance trailers (tip a61265484)
- [x] Full old-vs-new diff reviewed for 02 and 09; `AppleWatchManager` hunks byte-identical to the old patch
- [x] `patch-test.sh` incl. `patch-audit.sh` passes (32 warnings, sentinel ✓, drift CLEAN)
- [x] Build 227 (Trio 1.0.1) built and uploaded to TestFlight 2026-09-22 23:59; release trio-v1.0.1-227-localCI
- [x] Operator: BetterStack verification of build 227, then commit patches 02/09 + `scripts/repin-g7.sh` — committed b18da9419/92ab21640 after install; BetterStack verification completed 2026-09-24 (see below)
- [x] Operator pushes `dev` (26 ahead), `feature/watch-g7`, `feature/g7sensorkit-timestamp-seconds` — pushed 2026-09-23 on operator authorization

## Close-out — 2026-09-23

- Operator installed build 227 on phone + watch and authorized commit and push.
- Commits (operator-signed via Touch ID): b18da9419 `repin-g7.sh` v1.1; 92ab21640 patches 02/09 + this task file.
- Pushed (fast-forwards): `dev` c1cfd21e7..92ab21640, `feature/watch-g7` 9546444a5..a61265484, `feature/g7sensorkit-timestamp-seconds` fc24f3972..7b259641f.
- Offload sessions recorded (ollama, author): notes 20260922-233346-86359, 20260922-233621-90196.

## Remaining

- [x] Commit patches 02/09 + `scripts/repin-g7.sh` — b18da9419, 92ab21640
- [x] Push `dev` and both feature branches
- [x] BetterStack verification of build 227 in production — done in two windows, 2026-09-23 and 2026-09-24 (see the sections below)

## BetterStack verification — build 227 (2026-09-23)

**Verdict: concerns.** The not-looping ladder behaved as described: it armed on every loop, time-sensitive steps covered two gaps and recovery retracted the rest, and no Critical was reached. No crashes were found. Needs attention: (a) the watch complication stopped being refreshed by WidgetKit from 06:15 CEST (`rate_limited`); (b) a 45-min loop gap at 05:07–05:52 CEST during a CGM `temporarySensorIssue` that followed a steep fall in readings, with no Trio low alarm (by design with G7). Window: 2026-09-23 00:07 → ~08:00 CEST, Trio source 1659391, all times in CEST. Observational telemetry only.

- **Build 227 reporting from both devices:** yes. iPhone (`ios`): 11,875 events from 00:07:20 CEST. Watch (`watchos`): 5,053 events from 00:08. The last build-226 events were 00:07 (iPhone) and 00:05 (watch). The iPhone app launched once (00:07, the install). The watch extension launched twice (00:10 and 00:32); both were `applicationDidFinishLaunching` background launches.
- **Loop cadence:** 74 `Loop succeeded` lines (00:09 → 07:52), about one every 5 min. Two gaps were ≥ 20 min:
  - **00:42:17 → 01:03:35 (~21 min).** iPhone-side G7 BLE `command_timeout` / `auth_notify_failed` at 00:47 and 00:52, and no EGV from 00:42 to 01:02. Readings resumed at 01:02:13 and the loop ran at 01:03:35.
  - **05:07:20 → 05:52:21 (45 min).** The G7 reported `algorithm_state=18` (`temporarySensorIssue`) from 05:12 to 05:47, which gave `CGM PLUGIN - unable to read CGM result` and so no loop. The sensor returned `state=ok` at 05:52:11 and the loop ran at 05:52:21.
- **Not-looping ladder (PR #1552):** consistent with the description.
  - **Arming:** every successful loop logged `TrioAlertManager.issueAlert` for `loop.notActive.w1…w5` at `level=timeSensitive` and one `loop.notActive` at `level=critical`. That is 370 warnings and 74 criticals, exactly 5 warnings plus 1 critical per loop.
  - **No 20-min Critical:** the only Critical arm is the 120-min step.
  - **No drops:** there were no `dropped`, `muted` or `throttled` lines for any `trio.aps` alert.
  - **Steps that came due:**
    - Gap 1: **w1** (time-sensitive) was due at about **01:02:17**, ~80 s before recovery. Recovery at 01:03 re-armed the ladder (retract then re-issue), so w2–w5 and the Critical never came due.
    - Gap 2: **w1 at ~05:27:20** and **w2 at ~05:47:20** (both time-sensitive) came due. Recovery at 05:52:21 retracted and re-armed, so w3–w5 and the Critical never came due.
  - **Delivery not observable:** the steps are OS-owned `UNTimeIntervalNotificationTrigger`s, so telemetry cannot confirm they were actually delivered. Nothing in the logs contradicts the described ladder. The operator can confirm from the lock screen or Notification Center.
- **Glucose / CGM alarms:**
  - **Forecast-low:** Trio issued `Trio.glucose.forecastedLow` (time-sensitive) 5 times: 01:52, 02:42, 02:52, 03:47 and 04:27. They were spaced 10–55 min apart, so this is not a re-delivery storm. Snooze and suppression lines: none.
  - **Readings:** the sensor showed a steep fall in the reported values: 62 (04:52), 55 (04:57), 27 (05:02), 18 raw (05:07; Trio showed 40). Then came `temporarySensorIssue`, then a rapid rise to 146 by 05:52.
  - **No Trio low or urgent-low alarm:** none was issued. This is by design: `CGMManagerAlertOwnership` hands reading-based glucose alarms to the Dexcom app when the CGM is a G7, unless `forceTrioAlertsWhenCGMProvidesOwn` is set. That gating predates 1.0.1.5 (ecee548dc, 2026-06-20), so it is not new in build 227. Whether the Dexcom app alarmed is not visible here.
- **Crashes / errors vs build 226:**
  - **No crash signatures:** no crash, fatal or termination lines, and no unexpected iPhone relaunch.
  - **New only at startup:** `[LiveActivityManager]: Error creating new activity: visibility` (5 lines, 00:07, launch only).
  - **Cloud-log upload timeouts:** 2 (00:57 and 01:02), transient.
  - **G7 BLE rates:** `connect_timeout` and `auth_notify_failed` counts rose against the previous night. But the G7 sensor and the watch were both replaced on 09-22 at 21:30 CEST. Against build 226 on the new hardware (21:30 → 00:07), build 227's hourly rates are the same or lower: iPhone `connect_called` ~35/h vs ~52/h, watch ~36/h vs ~40/h, `connect_timeout` ~13/h vs ~15–17/h. No connect storm on either platform.
- **Watch:**
  - **Direct-BLE G7 readings** arrived intermittently: about 5–7 readings an hour until 03:37, then only every 20–35 min from 03:37 to 06:02, when normal cadence resumed. There were repeated `stale_sensor_binding_suspected` and `pre_egv_disconnect` lines, and 2 `ext_session_did_invalidate` events (03:30 and 07:09).
  - **Complication, concern:** the regenerated complication was serviced normally until **06:15 CEST**. That was the last `complication_get_timeline_called`, 74 overnight. From 06:19 onward every `complication_reload_requested` came back `complication_reload_unserviced … action=rate_limited` or `re_request`, and there were no more timeline calls through the last log at 07:52. So the face may have shown stale data from 06:15. Build 226 on the old watch showed no `rate_limited` on previous nights, but the watch hardware changed as well, so the cause (build 227 complication vs new watch) can't be separated yet. Build 227 requested 131 reload generations overnight, about one every 5 min.

## BetterStack follow-up — build 227 (2026-09-23 08:00 → 2026-09-24 00:12 CEST)

**Verdict: OK, except one open question.** Loop health, the not-looping ladder, alarms and crashes are all clean. **Correction to the 2026-09-23 run:** the complication was *not* stale from 06:15 CEST. `complication_get_timeline_called` continued every 5 min after 06:15. That run most likely queried S3 before the most recent hour had been uploaded. The open question is a *different*, later gap (see Watch). Window times are CEST; source 1659391; observational telemetry only.

- **Loop:** 178 `Loop succeeded` (08:02 → 00:12), all build 227, iPhone. Only one gap ≥ 20 min: **21:02 → 21:31 (28.7 min), a pod change**. `Omni:pumpFault` 0x18 "Reservoir empty or exceeded maximum pulse delivery" fired at 21:02:41 (time-sensitive), then `noPodPaired` loop failures 21:07–21:27, then the loop resumed at 21:31 on the new pod. Leading up to it: `Omni.podExpiring` at 15:37 and `Omni.lowReservoir` at 20:22. The same fault code fired at the same level on build 226 (2026-09-20), so it is not a change in 1.0.1.5. Pairing on the bumped OmnipodKit succeeded.
- **Not-looping ladder:** still armed on every loop: exactly 178 × (w1–w5 time-sensitive + 1 critical). During the pod change, w1 was due at ~21:22 and recovery at 21:31 retracted the rest. No Critical step was reached.
- **Glucose alarms:** `forecastedLow` ×4 (first 09:27, last 22:47) and `carbsRequired` ×4 (first 09:22, last 22:42), all time-sensitive. No re-delivery storm.
- **Crashes:** no crash, fatal or unexpected-termination lines on either platform.
- **Watch complication:**
  - `rate_limited` refusals of *extra* reload requests came in clusters (~10–12 and ~20–21), but timeline service continued on its 5-min schedule. These are harmless.
  - **Open:** the extension restarted at 20:25:38 (`provider_restart=true`, new provider instance, a burst of timeline calls), and **no `complication_get_timeline_called` or any other extension event has appeared since 20:27:16**. The watch app keeps saving snapshots and requesting reloads through 00:07. The pattern is consistent with the watch face being edited or switched (complication removed from the active face), but the logs can't confirm it → **operator to check the active watch face.**
- **Watch direct-BLE G7:** own EGVs every hour through ~23:00. From ~22:30: repeated `pre_egv` disconnects, `phantom_disconnect`, `stale_sensor_binding_suspected`, `ble_gated reason=no_runtime`, `ext_session_active=false`. Phone-relayed readings are still reaching the watch. This is the same shape as the known watch G7 behaviour; nothing ties it to build 227 (new watch hardware since 2026-09-22).

## Correction — complication (2026-09-24 00:20 CEST)

The "no `complication_get_timeline_called` since 20:27" finding above was also an ingestion artifact, not a real gap. The watch uploads logs in batches with their original timestamps, so recent-but-late rows sit in the hot tier (`remote(t491594_trio_logs)`) even when they are hours old. The query bounded the hot leg at `dt >= 21:17:21 UTC`, which excluded them. Re-run with the hot leg covering the whole window (`s3 dt < 18:32:15 UTC` + `remote dt >= 18:32:15 UTC`): timeline calls continued without a break, 21 in the 21:00 CEST hour, 32 at 22:00, 32 at 23:00, 8 by 00:10. The operator confirmed the complication was current on the watch face (screenshot, 2026-09-24).

**Query lesson for watch telemetry:** don't bound the hot leg by S3's upload horizon alone. Include the hot tier over the whole window and dedupe the overlap, or late watch uploads will look like gaps.

**Verification verdict for build 227: OK.** No open concerns from the BetterStack checks.

- [x] BetterStack verification of build 227 in production — two windows (2026-09-23 00:07–08:00 and 08:00–2026-09-24 00:12 CEST); the complication concerns from both passes were ingestion artifacts, not real faults

## Follow-ups filed (2026-09-24)

- TRIO-064 — `repin-g7.sh` always runs `git push` on the G7SensorKit fork, even when the SHA is already on origin.
- TR-553 (task-relay) — the offload gate ignores notes written from a different worktree, so offloads run in a scratch worktree can never satisfy it (sibling of TR-355).
- TR-554 (task-relay) — `implement` cannot resolve a mid-merge file: conflict markers break surgical S/R, codex edits a clean HEAD copy, and whole-file mode drifts indentation.
