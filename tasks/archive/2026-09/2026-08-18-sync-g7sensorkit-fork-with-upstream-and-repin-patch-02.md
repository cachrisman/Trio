+++
uid = "01a0150f-05c3-76d0-9d9c-2bb76994abd9"
key = "TRIO-049"
title = "Sync G7SensorKit fork with upstream and repin patch 02"
status = "done"
kind = "code"
source = "human"
source_ref = "operator-request-2026-08-18-g7sensorkit-upstream-sync"
created = 2026-08-18
updated = 2026-09-12
touched = 2026-09-12
closed = 2026-09-12
first_closed = 2026-09-12
accepted_by = "Charlie"
accepted_at = 2026-09-12
owner = "me"
tags = ["g7sensorkit", "submodule", "patches", "upstream-sync"]

[[sessions]]
host = "claude-code"
ref = "b584381d-b4ef-42f5-abed-d048aa8af79d"
model_family = "claude"
started = 2026-08-18
role = "author"
started_at = "2026-08-18T13:35:44+00:00"

[[reviews]]
run_id = "waived-operator-2026-08-18-trio-049"
model_family = "none"
verdict = "waived"
reviewed_commit = "3b5008641"
reviewed_paths = ["patches/02-g7-reading-time-with-seconds.patch"]
recorded_at = "2026-08-18T13:35:47+00:00"
+++

## Intent


## Intent

Operator request, 2026-08-18: bring `cachrisman/G7SensorKit` up to date with `LoopKit/G7SensorKit`,
push the merge to `origin`, and repin patch 02 to the resulting SHA.

Reviews **waived by the operator** for this task — it is a dependency sync plus a repin, not new logic.

## Survey before starting

Standalone clone at `~/Code/personal/health/diabetes/G7SensorKit`, on `main` at `50c76a7`, working
tree clean. `origin` = `cachrisman/G7SensorKit`, `upstream` = `LoopKit/G7SensorKit`. Per
[[g7sensorkit-canonical-edit-location]] this clone is the only place the fork is edited — never the
Trio/Trio-dev submodule checkouts.

**The pin lives in patch 02** (`02-g7-reading-time-with-seconds.patch`), the only patch carrying
`Subproject commit` lines. Patches 09, 10 and 13 mention G7SensorKit but do not pin it.

### What upstream has that we do not — 2 commits

| SHA | Subject |
|---|---|
| `aeaec95` | Fix manager state string rep |
| `6abff7c` | Add MIT license (#60) |

Our fork is **52 commits ahead** of upstream (all the TRIO-028/033/034 telemetry and backfill work).

### `aeaec95` is a real bug fix — that we already have

```diff
 G7SensorKit/G7CGMManager/G7PeripheralManager.swift
         case .poweredOn:
-            return "poweredOff"
+            return "poweredOn"
```

`CBManagerState.description` returned `"poweredOff"` for `.poweredOn` — a state string that lies. Had
we inherited it, our BLE telemetry would have reported a powered-on manager as off, and this is exactly
the failure class CLAUDE.md's verification rule exists for (build 206's `WKExtendedRuntimeSessionState`
misreading).

**We are not exposed.** Our fork already returns `"poweredOn"` (verified in the working tree) — that
extension was rewritten during the telemetry work. Since both sides made the same change from the same
base, the 3-way merge should resolve without conflict.

Conflict risk is otherwise low but **not zero**: our fork has 9 commits touching
`G7PeripheralManager.swift`, so the merge must be inspected rather than assumed clean.

## Plan

1. Merge `upstream/main` into `main` in the standalone clone; resolve any conflict.
2. Push to `origin` — **requires operator authorization**, see below.
3. Repin patch 02 to the merge SHA via the established re-pin procedure (never hand-edit the patch).
4. `patch-test.sh`, then verify against the fully stacked tree.

## Blocked on: push authorization

The operator asked for the push explicitly. Standing instruction in the global CLAUDE.md is
nonetheless *"Never `git push`. Pushing is mine in every repo, without exception."* Raising it once
rather than assuming the explicit request overrides a rule written in absolute terms. Everything up to
the push proceeds regardless; the repin is genuinely blocked, because a patch pinning a SHA that does
not exist on `origin` would break any clean clone or CI build.

## Acceptance criteria

- [ ] `upstream/main` merged into the fork's `main`, conflicts (if any) resolved and explained
- [ ] Merge inspected rather than assumed — confirm `CBManagerState.description` still returns
      `"poweredOn"` afterwards, and that no fork telemetry work was reverted
- [ ] Pushed to `origin` (operator-authorized)
- [ ] Patch 02 repinned to the new SHA via `mid-stack-update.sh`, never hand-edited
- [ ] `patch-test.sh` passes and the stacked tree carries the new pin
- [ ] Reviews waived — recorded as `waived` with this task as the reason, not skipped silently

## Done 2026-08-18

| Step | Result |
|---|---|
| Merge `upstream/main` → fork `main` | `7232e55`, auto-merged, **no conflicts** |
| Pushed to `origin` | `50c76a7..7232e55` fast-forward, verified on remote |
| Patch 02 repinned | `3b5008641`, via `scripts/repin-g7.sh` |
| `patch-test.sh` | PASSED, 31 warnings (unchanged), sentinel intact |
| Stacked tree pin | `7232e55785a636d4a0a001cae40ec9e9b2ac60f7` ✅ |

Post-merge sanity confirmed rather than assumed: `CBManagerState.description` still returns
`"poweredOn"`, the fork retains all its commits (53 ahead of upstream), and the four build-222 markers
(TRIO-037 flags = 2, TRIO-043 = 1, TRIO-045 = 1, TRIO-041 = 3) are unchanged in the stacked tree.

`scripts/repin-g7.sh` was the right tool — it rewrites **both** SHA sites (the `Subproject commit`
line and the `index ..<after>` abbreviation), which is exactly where a hand-edit goes half-right.

The signing failure partway through was the expected 1Password-locked case, not a fault: `git merge`
reaches for the operator key. Completed with `agent-commit` (this repo is `agent.signing = allow`),
and the merge commit is signed by `agent@chrisman.io`.

### Reviews waived

Operator waived reviews for this task explicitly. Recorded as `waived` rather than skipped, per the
never-fabricate-evidence rule.

### Note on build 222

This changes the pin build 222 would ship, from `50c76a7` — the SHA all five of its tasks were
reviewed and compile-verified against — to `7232e55`. **The operator decided not to re-review**, on
the basis that the only functional delta is a LICENSE file (the one real upstream fix was already
present in the fork). Recorded here so the divergence between "what was reviewed" and "what ships" is
visible rather than silent.

## Acceptance criteria

- [x] `upstream/main` merged, no conflicts (both sides had made the same `poweredOn` change)
- [x] Merge inspected — `poweredOn` intact, no fork telemetry work reverted, 53 commits ahead
- [x] Pushed to `origin` (operator-authorized, raised once against the standing never-push rule)
- [x] Patch 02 repinned via `scripts/repin-g7.sh`, never hand-edited
- [x] `patch-test.sh` passes; stacked tree carries `7232e55`
- [x] Reviews recorded as `waived`, not silently skipped
