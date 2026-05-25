# CLAUDE.md — Trio-dev worktree

**Read this first before doing anything.**

This is the `Trio-dev` worktree — the canonical location for build scripts and patch tooling. Product code lives in the `Trio` worktree at `../Trio`.

## Required reading

- **`AGENTS.md`** (at `../Trio/AGENTS.md` or `diabetes/Trio/AGENTS.md`) — non-negotiable safety rules, full workflow for patches, builds, BetterStack. Read it in full before starting any task.
- **`docs/process/feature-branch-workflow-optimization.md`** — patch stack operating model, mid-stack update workflow, build commands.

## Quick orientation

- **Fix code** → edit files in the `Trio` worktree on the feature branch, commit there
- **Update a patch** → run `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>` from THIS worktree (`Trio-dev`) with `dev` checked out
- **Validate patch stack** → `./scripts/patch-test.sh`
- **Run a build** → `./ci/local-build.sh --include-untracked` (run in background; log goes to `build/artifacts/ci-local-build-*.log`)
- **Never** hand-edit patch files, run `generate-patch.sh` directly for mid-stack updates, or edit `project.pbxproj`

## Two-worktree model

| Worktree | Branch | Purpose |
|---|---|---|
| `Trio-dev` | `dev` | Patch tooling, build scripts, CI |
| `Trio` | `feature/<name>` | Product code changes |

A branch checked out in one worktree cannot be used in the other. Always run patch/build scripts from `Trio-dev` with `dev` checked out.

## When fixing a build error

1. Edit the source file in `Trio` worktree on the feature branch
2. Commit it to the feature branch
3. From `Trio-dev` (on `dev`): `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>`
4. `./scripts/patch-test.sh`
5. Restart the build in the background
