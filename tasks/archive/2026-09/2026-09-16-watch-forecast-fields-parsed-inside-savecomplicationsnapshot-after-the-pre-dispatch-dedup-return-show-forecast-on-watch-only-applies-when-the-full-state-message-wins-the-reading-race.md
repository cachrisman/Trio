+++
uid = "01a0aa42-a0bd-7612-a986-b9f302369c63"
key = "TRIO-058"
title = "Watch: forecast fields parsed inside saveComplicationSnapshot after the pre-dispatch dedup return — Show Forecast on Watch only applies when the full-state message wins the reading race"
status = "done"
kind = "code"
source = "human"
created = 2026-09-16
updated = 2026-09-24
touched = 2026-09-24
closed = 2026-09-24
first_closed = 2026-09-24
accepted_by = "Charlie"
accepted_at = 2026-09-24
owner = "me"
tags = ["watch", "patch-09", "patch-clobber", "forecast"]
files = ["Trio Watch App Extension/WatchState.swift", "patches/09-watch-g7.patch"]
parent = "01a0d06c-b57e-7325-8192-4528931b8f7c"

[[sessions]]
host = "claude-code"
ref = "d5246626-9484-464a-b4d4-7125baaf79fd"
model_family = "claude"
started = 2026-09-23
role = "author"
started_at = "2026-09-23T18:26:51+00:00"

[[reviews]]
run_id = "71226c49-28fb-4e70-9bf5-6a1e4fab0557"
model_family = "codex"
verdict = "pass"
reviewed_commit = "92ab21640986a4d7e7c876e23e3811a6b178e7d0"
reviewed_paths = ["../../../../../../../private/tmp/claude-501/-Users-charlie-Code-personal-health-diabetes-Trio-dev/98f4daf1-40b8-4772-a530-24af0d9454ec/scratchpad/wt-watch-g7/Trio Watch App Extension/WatchState.swift"]
recorded_at = "2026-09-23T18:26:51+00:00"

[[reviews]]
run_id = "bfb478bc-8423-4b4e-a3d2-3e74f7dc4630"
model_family = "codex"
verdict = "pass"
reviewed_commit = "b1f2e41bfff2338284da6b0c94f6274c9fd79ceb"
reviewed_paths = ["Trio Watch App Extension/WatchState.swift"]
recorded_at = "2026-09-23T19:49:44+00:00"
+++

## Intent

Operator report 2026-09-16 (build 226): 'Show Forecast on Watch' enabled, chart page showed no forecast at 14:29, then the forecast appeared at 14:38 without any change.

## Root cause (fork-only; upstream is correct)
Upstream parses showForecastWatch / isForecastCone / forecastData at the tail of WatchState.processRawDataForWatchState (upstream dev WatchState.swift:571). Patch 09 (watch-g7) splits exactly that spot: it inserts the saveComplicationSnapshot(...) call, closes processRawDataForWatchState, adds applyColorSettingsFromPayloadIfPresent, and opens private func saveComplicationSnapshot. When upstream later appended the forecast parsing, git am --3way placed those lines after patch 09's inserted block — i.e. at the END of saveComplicationSnapshot (fork tree lines ~2368-2384). It compiles because both functions take message.

saveComplicationSnapshot has three early returns before that tail: two 'no valid CGM reading timestamp' cases and the Phase-3.0 pre-dispatch dedup (TrioComplicationDataStore.shouldSkipPreDispatch). The dedup fires whenever the reading in the message was already saved — normal on this fork, because the phone sends the complication-only payload immediately on each reading and the full watchState (the only carrier of forecast keys) only after the loop finishes 3-4 min later. So the forecast fields are applied only on cycles where the full-state message happens to be the first phone carrier of its reading.

## Evidence (BetterStack watchos, 2026-09-16 UTC)
- 12:29:46/47 full watchState x2 with showForecastWatch/isForecastCone/forecastData, reading 12:26:02 → '⏭️ Pre-dispatch dedup: skipped reading_date_epoch=1789561562' → forecast never applied (14:29 screenshot: axis ends at now; with showForecast true it would extend 2h even with no data).
- 12:35:13 full watchState with reading 12:31:02 → '✅ Pre-dispatch: dispatching' → function ran to the end → showForecast=true, forecastData applied (14:38 screenshot shows the IOB/COB/UAM/ZT lines).
- 12:38:06 two messages: first dispatched, second skipped.

## Consequences
- Feature looks dead until the first message that wins the race; afterwards the flag stays on but forecastData refreshes only on winning cycles, so the chart can show the PREVIOUS forecast (anchored at its old forecastStartDate) while looking current.
- Class of bug the guardrails cannot see: a 3-way apply that lands an upstream hunk at a function boundary a patch created. Not a deletion, so patch-audit.sh is blind to it; compiles; no conflict.

## Fix
On feature/watch-g7: move the three forecast parse blocks from the end of saveComplicationSnapshot to the end of processRawDataForWatchState (upstream's placement, before the saveComplicationSnapshot(...) call). Regenerate patch 09 (mid-stack-update.sh --force-from-feature-branch), patch-test.sh, ship the next build. Add the 'hunk lands at a patch-created function boundary' case to docs/process/patch-clobber-guardrails.md with this incident.

## Acceptance criteria
- [ ] Forecast parsing lives in processRawDataForWatchState in the fork tree; saveComplicationSnapshot ends at the fromUserInfo reset
- [ ] Patch 09 regenerated, old-vs-new line-set delta is only the moved lines; patch-test.sh + audit pass
- [ ] On device: chart extends into the future within one loop cycle of enabling the toggle; BetterStack shows forecast applied on cycles that log 'Pre-dispatch dedup: skipped'
- [ ] Guardrails doc updated with the boundary-hunk case


## Implementation (2026-09-23) — code change done, commit + patch regeneration parked

Bug re-confirmed present on the current `feature/watch-g7` (tip `a61265484`, the build-227 state): the three parse blocks were still at lines 2368–2384 inside `saveComplicationSnapshot`.

Change made in a scratch worktree of `feature/watch-g7`: the three blocks moved verbatim to the tail of `processRawDataForWatchState`, immediately before its `saveComplicationSnapshot(...)` call, with a 5-line comment explaining why they cannot live in the complication path. Diff is 22 insertions / 17 deletions — the 17 are the identical moved lines.

Verification:
- 0 forecast references remain inside `saveComplicationSnapshot`; 4 parse references now inside `processRawDataForWatchState`.
- No early `return`/`guard` exists in `processRawDataForWatchState` before the new location, so its tail always runs; the function has exactly one caller.
- SwiftFormat warning counts (by rule) byte-identical before and after — the move added none. The file carries many pre-existing warnings and has never been lint-clean.
- Codex review (`gpt-5.6-terra`, high), briefed on the two `saveComplicationSnapshot(from: payload)` call sites that bypass `processRawDataForWatchState`, threading, and ordering: **no findings**.

**Parked, needs 1Password unlocked:** the commit on `feature/watch-g7` and the patch 09 regeneration (`mid-stack-update.sh --cherry-pick <sha>`), then `patch-test.sh` and a build. The regeneration will also clean patch 09's legacy truncated provenance trailer, since it will run under the TRIO-057 fix. Worktree: scratchpad `wt-watch-g7`.


## Committed (2026-09-23)

- `feature/watch-g7` `b1f2e41bf` — the move, signed.
- Patch 09 regenerated via `mid-stack-update.sh --patch 09 --cherry-pick b1f2e41bf` (cherry-pick mode, 1 commit), committed to dev as `968c359ec`. File count unchanged at 29; `patch-test.sh` + audit PASSED.
- **Verified no clobber:** the regenerated patch drops a hunk that used to add the `recommendedBolus` branch. Confirmed benign rather than assumed — dev carries that code itself since the 1.0.1.5 merge (`recommendedBolus` appears 4× in both dev and the feature branch), and applying the full 10-patch stack produces a `WatchState.swift` **byte-identical** to the feature branch's file.

Remaining: build + deploy so the fix reaches the watch, then confirm on device that the forecast appears within one loop cycle of enabling "Show Forecast on Watch" (and check BetterStack shows the forecast applied even on cycles logging "Pre-dispatch dedup: skipped").


## Release note

"Show Forecast on Watch" now updates the watch chart reliably: the forecast is applied from every full watch-state update instead of only when that update happened to be the first to carry a new reading.


Shipped in build 228 (TRIO-065).
