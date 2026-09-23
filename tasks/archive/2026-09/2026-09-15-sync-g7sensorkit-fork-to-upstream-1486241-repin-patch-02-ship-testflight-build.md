+++
uid = "01a0a2b6-e640-72b6-911b-9a5689b3a696"
key = "TRIO-053"
title = "Sync G7SensorKit fork to upstream 1486241, repin patch 02, ship TestFlight build"
status = "done"
kind = "code"
source = "human"
created = 2026-09-15
updated = 2026-09-15
touched = 2026-09-15
closed = 2026-09-15
first_closed = 2026-09-15
accepted_by = "Charlie"
accepted_at = 2026-09-15
owner = "me"
tags = ["g7sensorkit", "submodule", "patches", "build"]

[[sessions]]
host = "claude-code"
ref = "98f4daf1-40b8-4772-a530-24af0d9454ec"
model_family = "claude"
started = 2026-09-15
role = "author"
started_at = "2026-09-15T01:38:10+00:00"

[[reviews]]
run_id = "waived-operator-2026-09-15-trio-053"
model_family = "none"
verdict = "waived"
reviewed_commit = "1900ad76c"
recorded_at = "2026-09-15T02:07:24+00:00"
+++

## Intent

Operator request 2026-09-15 (morning after TRIO-052): "Do the G7SensorKit fork sync and rebuild trio and deploy to TestFlight." Build 224 shipped with the fork pinned at 7232e55, three commits behind the G7SensorKit pointer upstream Trio 0.8.4.106 uses (1486241: #62 "Defer forgetting sensor on suspected session end", two lokalise translation commits). Same shape as TRIO-049.

## Plan

1. In the canonical clone (~/Code/personal/health/diabetes/G7SensorKit, main) merge upstream's 1486241 into main; inspect the merge (BLE state machine is shared iPhone/watch; the fork has 53 commits of telemetry/backfill work on top).
2. Push to origin — operator's action per the standing rule; stop and ask.
3. `scripts/repin-g7.sh --allow-dirty-patch` (patch 02 already carries last night's uncommitted base re-derivation).
4. `scripts/patch-test.sh`, then `./ci/local-build.sh --base-branch dev --no-sync-upstream` (full deploy).

## Acceptance criteria

- [x] Fork `main` contains 1486241 — merge `0013c90`, 54 ahead of upstream; both conflicts explained in the commit and above; `poweredOn` verified; all fork telemetry preserved
- [x] Pushed to origin — operator authorized in chat; `repin-g7.sh` confirmed `0013c90` on origin
- [x] Patch 02 repinned via `repin-g7.sh` (7232e55 → 0013c90, both SHA sites); build worktree checked out `0013c90`
- [x] `patch-test.sh` PASSED, audit 31 warnings (unchanged), sentinel ✓
- [x] Build + TestFlight upload succeeded — **build 225** (0.8.4), `ci-local-build-20260915-034537`, 21m14s; https://github.com/cachrisman/Trio/releases/tag/trio-v0.8.4-225-localCI

## Progress 2026-09-15

- Fork merge `0013c90` (54 ahead of upstream; `upstream/main` 1486241 is an ancestor). Conflicts: `G7CGMManager.sensorDisconnected` → upstream's grace-period mechanism replaces the fork's C-212-3 heuristic (the fork's early return never re-evaluated after a real session end following a fresh reading); `G7Sensor` → upstream DI initializers with the fork's `Locked` sensorID + four `.debug → .default` log promotions, all telemetry kept. `swiftc -parse` clean; `poweredOn` string intact. Offload runs ce5563ab / f3428998 produced plans but skipped writes (conflicted-file guard); edits applied under their notes.
- Push: operator authorized in chat ("I authorize you try push to GitHub for this"); `repin-g7.sh` pushed and confirmed `0013c90` on origin.
- Patch 02 re-pinned 7232e55 → 0013c90 (both sites). `patch-test.sh` PASSED, audit 31 warnings, sentinel ✓.
- Build 225 shipped 03:53 (Build IPA 5m04s, upload 15m11s). Patch 02 re-pin staged alongside last night's regenerated 02/05/06/10/13 — commit still parked on BetterStack verification (see TRIO-052's proposed message; add the 0013c90 pin to it).

Reviews: waived for the merge itself — a dependency sync with two hand-resolved conflicts, both described line-by-line above and compiled into build 225; no diverse-family review was run.
