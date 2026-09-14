# Patch & build tooling hardening — design & decisions

**Version:** v1.1
**Status:** In review (changes A–F landed; G/H deferred)
**Date:** 2026-06-22

## Goal

Close the manual, error-prone seams *between* the existing patch/build scripts —
the places where agents still make load-bearing decisions by hand and sometimes
get them wrong. The guiding principle is the same one that produced
`generate-patch.sh` and `mid-stack-update.sh`: **if a step is mechanical and a
wrong choice is costly, a deterministic script should make the choice, not the
agent.**

## Non-goals

- Re-litigating already-solved problems. `patch-audit.sh` (safety-path deletion
  + missing-symbol sentinel), provenance trailers, and auto-detect of new
  files/cherry-pick candidates already exist and work. We build on them.
- Changing the patch-stack model, the two-worktree model, or the build/deploy
  flow. These are hardening changes, not redesigns.
- Anything that weakens a safety guardrail (`patch-audit.safety-paths`,
  `patch-audit.waivers` remain human-maintained and untouched).

## Background: the stumbles motivating each change

| # | Stumble | Where it bit us | Fix in this initiative |
|---|---------|-----------------|------------------------|
| 1 | Agents reach for `--from-feature-branch` to avoid enumerating cherry-pick commits, even though the tool now auto-computes them. `--from-feature-branch` can sweep in unrelated tree state (the mechanism behind the Info.plist drops and the patch-13 clobber). | Recurring across many mid-stack updates | **A. Cherry-pick gate** |
| 2 | Re-pinning the G7SensorKit submodule SHA in patch 02 is a frequent, simple, two-site edit that today is done by hand — against the "never hand-edit patch files" rule. | Frequent (every G7SensorKit change) | **B. `repin-g7.sh`** |
| 3 | `local-build.sh`'s submodule-change detector uses a hardcoded list that has drifted (lists removed `OmniKit`/`OmniBLE`, missing real `OmnipodKit`/`MedtrumKit`). Latent: a future patch repinning `OmnipodKit` by SHA alone would have its worktree submodule update silently skipped. | Latent (not yet triggered) | **C. Derive submodule list from `.gitmodules`** |
| 4 | On build failure the worktree is often cleaned up, destroying the evidence needed to investigate. | Recurring during build debugging | **D. Preserve worktree on error** |
| 5 | Stale build worktrees, old build logs, and `ci-build/*` temp branches (pushed by `record-release.sh`) accumulate with no GC. | Recurring housekeeping | **E. `cleanup-build-leftovers.sh`** |
| 6 | Guidance for the above lives only in prose; agents rationalize around prose. | — | **F. AGENTS.md + process-doc updates** |
| 7 (P2) | No local structured per-build provenance for `--build-only` runs (released builds already get a manifest via `record-release.sh` + `BuildDetails.plist`). | Debugging convenience | **G. `build-<N>.json` (follow-up)** |
| 8 (P2) | `generate-patch.sh` doesn't reject output paths outside `patches/`; drift-exclude regexes aren't persisted. | Minor sharp edges | **H. small guards (follow-up)** |

## Change A — Cherry-pick gate in `mid-stack-update.sh`

### Problem
`mid-stack-update.sh` already auto-computes the exact `--cherry-pick` SHAs from
recorded patch-id provenance and prints a ready-to-paste command. The agent's
historical rationalization ("figuring out the commits is more work, and
`--from-feature-branch` does the same thing") is now **factually false**. But
`--from-feature-branch` is still presented as a friction-free co-equal, so the
lazy path persists. AGENTS.md already documents it as a "last resort" — prose
alone has not changed behavior. **The lever must be the tool.**

### Design
Invert the friction so the lazy path costs *more* than the correct one.

New flag: `--force-from-feature-branch "<reason>"`
- Implies `--from-feature-branch`.
- Requires a non-empty `<reason>` (a conscious, audited act).
- The reason is echoed to stdout (captured in the build/run log).

When `--from-feature-branch` is requested **without** the force flag, run the
existing provenance reconciliation (reuse `_recorded_patch_ids` + `_patch_id`)
and branch on the result:

1. **Provenance present, history aligned** (every recorded patch-id is still
   present among the feature branch's commits): cherry-pick is viable by
   construction. **Refuse.** Print the computed `--cherry-pick <shas>` command and
   the `--force-from-feature-branch "<reason>"` escape hatch.
2. **Provenance present, history diverged** (one or more recorded patch-ids are
   no longer on the branch → rebase / squash / amend): cherry-pick can't cleanly
   map. **Allow** `--from-feature-branch` and print *why* it was allowed.
3. **No provenance** (legacy patch): we cannot verify viability. **Refuse**
   pending `--force-from-feature-branch "<reason>"`, which both blocks the lazy
   default and forces a written justification. (Nudge: regenerate once to record
   provenance.)

`--dry-run` exercises the gate too, so the verdict is visible before any change.

### Why this design (alternatives rejected)
- **Prose-only ("last resort")** — already tried; agents rationalize around it.
- **Hard-block `--from-feature-branch` entirely** — breaks the genuine
  rebase/squash case the user explicitly wants to keep available.
- **Full dry cherry-pick to test viability** — most accurate but heaviest and
  riskiest to wire in. The patch-id alignment check is a deterministic proxy that
  reuses existing helpers and distinguishes exactly the cases that matter
  (clean history vs rewritten history). If it ever mis-allows, the downstream
  `patch-test.sh` still validates the result.

### Acceptance
- `--from-feature-branch` on a clean, provenance-bearing patch with new commits
  → refuses, prints the cherry-pick command.
- Same patch with `--force-from-feature-branch "rebased"` → proceeds, logs reason.
- A patch whose feature branch was squashed → `--from-feature-branch` is allowed
  with a printed rationale.

## Change B — `repin-g7.sh` (new)

### Problem
Patch `02-g7-reading-time-with-seconds.patch` pins the G7SensorKit submodule SHA
in **two** places that must agree: the `+Subproject commit <sha>` line and the
`index <old>..<new> 160000` after-side abbreviation. Updating it by hand is both
against the rules and easy to get half-right.

### Design
`scripts/repin-g7.sh` (G7-specific by default; structured for a future
`--submodule <name>`):

1. Validate the standalone clone at
   `~/Code/personal/health/diabetes/G7SensorKit`: branch resolvable, `origin`
   points at the `cachrisman` fork.
2. Push committed HEAD to `origin`; `NEW=$(git rev-parse HEAD)`.
3. **Assert `NEW` is on `origin`** (`git branch -r --contains $NEW`) — guards
   against repinning to an unpushed local commit (the build would fail to fetch
   the submodule).
4. Read patch 02's current `+Subproject commit` (OLD). If `NEW == OLD`, no-op exit.
5. Rewrite both SHA sites to `NEW` (preserving the existing abbreviation length of
   the index line; leave the `-` base side and the `.gitmodules` URL untouched).
6. Verify the patch's `.gitmodules` hunk fork URL matches the clone's `origin`
   (catches a wrong-fork repin).
7. Run `patch-test.sh` — the real safety net; `git am` is strict and will reject a
   malformed gitlink hunk.
8. Print the diff for human/agent sign-off. **Do not commit** (leaves the patch
   staged-but-uncommitted, consistent with the no-auto-commit rule).

Flags:
- `--allow-dirty-patch` — proceed when patch 02 already has uncommitted edits
  (the "multiple G7 rounds without committing patch 02 between each" case). Without
  it: **warn and stop**, not refuse outright. (Per user feedback — a warning the
  agent can consciously override, not a hard block.)
- `--dry-run` — show what would be pushed and rewritten without doing it (push is
  the only irreversible step).

### Why this respects the "never hand-edit patches" rule
The edit is mechanical, validated by `patch-test.sh`, auditable (prints its diff),
and refuses ambiguous states — the same justification that legitimized
`generate-patch.sh`. It is *not* a free-hand edit.

## Change C — derive submodule list from `.gitmodules` (`local-build.sh`)

Replace the hardcoded
`G7SensorKit|CGMBLEKit|DanaKit|OmniKit|OmniBLE|...` alternation (the
post-patch submodule-change detector) with a regex built at runtime from
`.gitmodules` submodule paths (`git config -f .gitmodules --get-regexp '^submodule\..*\.path$'`).
Keep the existing `.gitmodules`-changed check. This closes the latent
wrong-SHA-build hole and prevents future drift.

## Change D — preserve worktree on error (`local-build.sh`)

On failure **at or after** the patch-apply/build stage, skip worktree removal and
print its path prominently (`Worktree preserved for investigation: <path>`). On
**success** or **pre-build** failures (arg validation, missing branch, preflight),
clean up as today. Add `--no-preserve-on-error` and a retention cap so preserved
worktrees don't pile up (cleaned by Change E).

## Change E — `cleanup-build-leftovers.sh` (new)

One housekeeping command, **dry-run by default** (`--apply` to act):
- Prune stale build worktrees (keep last 3).
- Delete old `build/artifacts/` logs (keep last 10).
- Delete `ci-build/*` remote branches older than 7 days (left by `record-release.sh`).

Triggers:
- **Primary: manual, on demand.**
- **Secondary: auto-tail of a successful full deploy** — `local-build.sh` invokes
  it (prune-to-retention) only after a successful `fastlane release`, i.e. exactly
  when the state it prunes is known-good and superseded. **Never on failure**
  (that's when Change D wants the leftovers kept).

Retention values are documented constants, overridable by flag.

## Change F — docs

- **AGENTS.md** (both `../Trio/AGENTS.md` and `Trio-dev/AGENTS.md` if diverged):
  rewrite the "Choosing `--cherry-pick` vs `--from-feature-branch`" section to
  document the *enforced* behavior and the `--force-from-feature-branch "<reason>"`
  escape; add `repin-g7.sh` to the G7SensorKit submodule section; note
  preserve-on-error + `cleanup-build-leftovers.sh`. Bump version + changelog.
- **`docs/process/feature-branch-workflow-optimization.md`**: update the mid-stack
  section to match enforcement; add the G7 repin and cleanup workflows. Bump version.

## Change G / H — follow-ups (lower priority)
- `build-<N>.json` local provenance for every build (released builds already get
  a manifest + `BuildDetails.plist`; this is a *local* convenience artifact).
- `generate-patch.sh` reject output paths outside `patches/`; persist
  drift-exclude regexes in a checked-in `.patch-drift-excludes`.

## Verification plan (per repo discipline — builds are NOT verification)
- `bash -n` + `shellcheck` on every changed/new script.
- `repin-g7.sh`: dry-run, then a real no-op run (NEW==OLD path), then confirm
  `patch-test.sh` stays green; manual diff review.
- Cherry-pick gate: exercise all three branches (aligned/refuse,
  diverged/allow, no-provenance/force) with `--dry-run` against real patches.
- `cleanup-build-leftovers.sh`: dry-run output inspected before any `--apply`.
- Full `patch-test.sh` (includes `patch-audit.sh`) green after all changes.

## Implementation checklist
- [x] A. Cherry-pick gate (`mid-stack-update.sh`) — implemented v1.11; all 4 verdict paths verified in dry-run.
- [x] B. `repin-g7.sh` — implemented; validation/no-op/synthetic-rewrite/lint verified. Live push path untested by design.
- [x] C. Submodule-list derivation (`local-build.sh`) — implemented; derivation + matching verified.
- [x] D. Preserve worktree on error (`local-build.sh`) — implemented; `--no-preserve-on-error` added; syntax verified.
- [x] E. `cleanup-build-leftovers.sh` + deploy-tail hook — implemented; dry-run verified (logs/worktrees/remote-branches).
- [x] F. AGENTS.md (v19) + `feature-branch-workflow-optimization.md` (v17) updates.
- [ ] G/H. Follow-ups (as time permits)

## Changelog
### v1.1 (2026-06-22)
- Changes A–F implemented and verified (see checklist). Validation: all four
  scripts pass `bash -n` + `shellcheck`; the cherry-pick gate's four verdict
  paths exercised in dry-run; `repin-g7.sh` validation/no-op/synthetic-rewrite
  verified; `cleanup-build-leftovers.sh` dry-run verified; `patch-test.sh` exits 0
  with the deletion audit passing. G/H deferred as a separate focused pass.
### v1.0 (2026-06-22)
- Initial design + decision record for the patch/build tooling hardening initiative.
