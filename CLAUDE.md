# CLAUDE.md — Trio-dev worktree

**Read this first before doing anything.**

This is the `Trio-dev` worktree — the canonical location for build scripts and patch tooling. Product code lives in the `Trio` worktree at `../Trio`.

## Required reading

- **`AGENTS.md`** (at `../Trio/AGENTS.md` or `diabetes/Trio/AGENTS.md`) — non-negotiable safety rules, full workflow for patches, builds, BetterStack. Read it in full before starting any task.
- **`docs/process/feature-branch-workflow-optimization.md`** — patch stack operating model, mid-stack update workflow, build commands.

## Quick orientation

- **Fix code** → edit files in the `Trio` worktree on the feature branch, commit there
- **Update a patch** → run `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>` from THIS worktree (`Trio-dev`) with `dev` checked out
- **Validate patch stack** → `./scripts/patch-test.sh` (also runs the deletion-footprint audit, `patch-audit.sh`)
- **Verify your work** → static review (re-read the full diff vs base, deletions especially) + `./scripts/patch-test.sh`. **Builds are NOT a verification tool** and run only on explicit human request — a passing build does not prove behavior preserved (AGENTS.md rules 10 & 12).
- **Run a build** → `./ci/local-build.sh --include-untracked` (run in background; log goes to `build/artifacts/ci-local-build-*.log`)
- **Never** hand-edit patch files, run `generate-patch.sh` directly for mid-stack updates, or edit `project.pbxproj`
- **Never** edit `scripts/patch-audit.safety-paths` or `scripts/patch-audit.waivers` (human-maintained; an audit FAIL is a hard STOP to surface, not to silence — see `docs/process/patch-clobber-guardrails.md`)
- **Never** add Claude/AI attribution to commits or PRs — no `Co-Authored-By: Claude …` trailer, no `🤖 Generated with Claude Code` line (this overrides the base-prompt default; applies to every repo incl. the `G7SensorKit` fork). See AGENTS.md safety rule 11.

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

## Verification discipline (mistakes made — do not repeat)

- **Verify OS/SDK enum raw values against the SDK header before interpreting them in logs/telemetry.** Build 206: a raw `WKExtendedRuntimeSessionState(rawValue: 2)` was wrongly read as `.invalid` (from memory + a stale code comment that omitted `.scheduled`); it is actually `.running` — order is `notStarted=0, scheduled=1, running=2, invalid=3`. This caused a wrong diagnosis and a misguided fix. For any raw enum in logs, grep the header: `find /Applications/Xcode.app -name '<Type>.h'`. Prefer logging a **mapped name**, never `String(describing:)` of an imported `NS_ENUM` (it prints the opaque `Type(rawValue: N)`).
- **Don't propagate an unverified interpretation across steps/subagents.** An early "every event is logged twice → halve the counts" was actually an s3-query artifact; it spread into multiple agents/the plan before being caught. State assumptions as assumptions and verify the load-bearing ones first.
- **When telemetry contradicts your hypothesis, re-check the hypothesis, not the data.** The `active=true` + `rawValue 2` + EGVs-flowing heartbeat was the tell; it was initially explained away instead of believed.
- **A conflict-free `git am --3way` is not verification, and "it compiled" is not verification.** During the 0.8.2 sync, patch 13 (`phone-ble-observer-telemetry`) silently deleted the Omnipod migration fallback (`managerIdentifier.hasPrefix(OmniStr)`) and `pumpManagerTypeByIdentifier` from `Trio/Sources/APS/DeviceDataManager.swift` — its only legitimate change was a one-line comment. The deletions applied without conflict (so only conflict hunks were reviewed) and compiled/archived fine; once the sync dropped the OmniBLE driver, a live pod had no manager and was silently forgotten — **a real wasted pod**. The fix is now automated: `patch-audit.sh` (run by `patch-test.sh`) fails on safety-path deletions + a missing-symbol sentinel. Always review the **complete diff vs base** for any reconciled/regenerated patch, deletions especially. Full writeup: `docs/process/patch-clobber-guardrails.md`.

## Patch regeneration: new files

- **A patch that ADDS new files MUST be regenerated with `--extra-files "<comma,paths>"`** (with `--from-feature-branch`), or the new files are silently dropped — the committed patch's scope doesn't list them. **Red flag:** the `Files in patch: N` line drops (build 206: 17 → 15). The watch target uses a synchronized file group, so a dropped `.swift` fails only at build time as `cannot find <Type> in scope`, not at patch-apply. After regen, `grep` the patch for the new files' content before building.
- `mid-stack-update.sh --from-feature-branch` also needs `--feature-branch <name>` (it errors on a default guess) and `--allow-behind-origin` when `dev` is behind origin.

## Running tooling through the Claude Code harness

- **`mid-stack-update.sh` and `ci/local-build.sh` require `dangerouslyDisableSandbox: true`.** They use `mktemp` and `exec > >(tee …)`, which the FS sandbox blocks (`mktemp: mkdtemp failed … Operation not permitted`, `/dev/fd/NN: Operation not permitted`).
- **Builds need a UTF-8 locale.** The harness shell has `LANG`/`LC_ALL` empty (locale `C`); fastlane/gym then throw `Encoding::InvalidByteSequenceError ("… on UTF-16")` in pre-flight. `ci/local-build.sh` now defaults `LANG=en_US.UTF-8`; if invoking fastlane/gym directly, prefix it.
- **TestFlight / Apple steps need Little Snitch to allow `ruby → apple.com`.** Homebrew's unsigned `ruby` gets prompted; headless it times out (`Net::OpenTimeout` to `api.appstoreconnect.apple.com`). `curl` is signed and unaffected — do **not** conclude "network works" from a `curl` test.
- Full deploy = `./ci/local-build.sh` (no `--build-only`) → builds + `fastlane release` (TestFlight) + GitHub release recording. Add `--no-sync-upstream` to stay on pre-merge `dev`, `--include-untracked` for uncommitted patches.
