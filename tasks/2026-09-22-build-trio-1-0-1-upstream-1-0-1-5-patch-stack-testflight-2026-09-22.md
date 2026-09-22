+++
uid = "01a0cb09-a12c-764a-ab60-aa3c13b162e4"
key = "TRIO-062"
title = "Build — Trio 1.0.1 (upstream 1.0.1.5) + patch stack, TestFlight 2026-09-22"
status = "in-progress"
kind = "epic"
source = "human"
created = 2026-09-22
updated = 2026-09-23
touched = 2026-09-23
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

- [ ] Patch 02 re-pinned via `repin-g7.sh`; base pin matches `dev:G7SensorKit`
- [ ] Patch 09 regenerated via `mid-stack-update.sh` with fresh provenance trailers
- [ ] Full old-vs-new diff reviewed for 02 and 09 (deletions especially); `AppleWatchManager` hunk matches the clean patch-level 3-way result
- [ ] `patch-test.sh` (incl. `patch-audit.sh`) passes
- [ ] Build + TestFlight upload succeeds (`--no-sync-upstream`)
- [ ] Operator pushes `dev` and feature branches

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
- [ ] Operator: BetterStack verification of build 227, then commit patches 02/09 + `scripts/repin-g7.sh`
- [ ] Operator pushes `dev` (26 ahead), `feature/watch-g7`, `feature/g7sensorkit-timestamp-seconds`
