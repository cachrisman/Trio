+++
uid = "019f8141-e117-77db-9216-aacfef43c223"
key = "TRIO-005"
title = "Close out dev-sync-branch-cleanup optional follow-ups"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/dev-sync-branch-cleanup/00-plan.md#L171"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["housekeeping", "patch-tooling"]

[[acceptance]]
id = "AC-1"
text = "Run full TestFlight deploy + BetterStack verification (only build-only was run; `./ci/local-build.sh --base-branch dev` for the full path)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Push the remaining ~10 reconstructed feature branches to origin (only `dev` and `feature/cloud-logging` are pushed so far)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Rewrite living-doc banners into full inline updates (review / upstream-PR plan / 209 plan / complication-freshness README currently only have banners)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Clean up scratch worktree `.trio-worktrees/fb-rebase-20260615` and the detached `../Trio` checkout at `7776d8cff`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Confirm and remove the 26 `safety/*` recovery tags once fully confirmed unneeded"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

The dev-sync + feature-branch cleanup initiative's main track (Phases 0-5) is complete and
committed (`c21092055`, force-pushed to `origin/dev` 2026-06-16). The plan's changelog explicitly
lists a remainder of deferred, optional, non-blocking follow-ups that were never closed out.

## Notes carried over from acceptance criteria
