+++
uid = "019f8141-e117-77db-9216-aacfef43c223"
key = "TRIO-005"
title = "Close out dev-sync-branch-cleanup optional follow-ups"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/dev-sync-branch-cleanup/00-plan.md#L171"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["housekeeping", "patch-tooling"]
+++

## Intent

The dev-sync + feature-branch cleanup initiative's main track (Phases 0-5) is complete and
committed (`c21092055`, force-pushed to `origin/dev` 2026-06-16). The plan's changelog explicitly
lists a remainder of deferred, optional, non-blocking follow-ups that were never closed out.

## Acceptance criteria

- [ ] Run full TestFlight deploy + BetterStack verification (only build-only was run; `./ci/local-build.sh --base-branch dev` for the full path)
- [ ] Push the remaining ~10 reconstructed feature branches to origin (only `dev` and `feature/cloud-logging` are pushed so far)
- [ ] Rewrite living-doc banners into full inline updates (review / upstream-PR plan / 209 plan / complication-freshness README currently only have banners)
- [ ] Clean up scratch worktree `.trio-worktrees/fb-rebase-20260615` and the detached `../Trio` checkout at `7776d8cff`
- [ ] Confirm and remove the 26 `safety/*` recovery tags once fully confirmed unneeded
