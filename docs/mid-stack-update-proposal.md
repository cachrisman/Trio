# mid-stack-update.sh — Proposal & Review Package

**Version:** 1.2
**Date:** 2026-03-09
**Status:** Implemented (script at v1.4)

---

## Table of Contents

1. [Script Overview](#1-script-overview)
2. [Failure Modes Addressed](#2-failure-modes-addressed)
3. [Drift Check: Detecting Omitted Commits](#3-drift-check-detecting-omitted-commits)
4. [Proposed Changes to AGENTS.md](#4-proposed-changes-to-agentsmd)
5. [Proposed Changes to feature-branch-workflow-optimization.md](#5-proposed-changes-to-feature-branch-workflow-optimizationmd)
6. [Red Team Review Prompt](#6-red-team-review-prompt)
7. [Implementation Log](#7-implementation-log)

---

## 1. Script Overview

`scripts/mid-stack-update.sh` automates the multi-step mid-stack patch update workflow that AI agents consistently get wrong when performing manually. It wraps `generate-patch.sh` and `patch-test.sh` internally, eliminating the most common failure modes observed across multiple agent sessions.

### What it does

| Step | Description |
|------|-------------|
| 1 | **Precondition checks** — enforces Trio-dev worktree, `dev` branch, finds the target patch |
| 2 | **Stash** — saves uncommitted changes (auto-popped on exit, even on failure) |
| 3 | **Baseline branch** — creates `tmp/<name>-baseline` from `dev` + patches 01..N-1 |
| 4 | **Update branch** — creates `tmp/<name>-update` from baseline, applies the current patch, cherry-picks specified commits |
| 5 | **Squash** — squashes all commits into a single commit for clean patch generation |
| 6 | **File list extraction** — automatically extracts the file list from `git diff` between baseline and update (never uses `-a`) |
| 7 | **Patch regeneration** — switches to `dev` and runs `generate-patch.sh` with `--include-files` and `-t tmp/<name>-baseline` |
| 8 | **Validation** — runs `patch-test.sh` to validate the full stack |
| 9 | **Drift check** — compares the regenerated patch against the feature branch to catch accidentally omitted commits |
| 10 | **Cleanup** — deletes tmp branches (preserved on drift), pops stash, prints next-step guidance |

### Usage

```bash
# Update patch 09, cherry-picking one commit from the feature branch
./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234

# Multiple cherry-picks
./scripts/mid-stack-update.sh --patch 06 --cherry-pick abc1234,def5678

# Explicit feature branch for drift check
./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234 \
    --feature-branch feature/watch-complication-improvements

# Dry run — preview what would happen
./scripts/mid-stack-update.sh --patch 09 --dry-run

# Include extra files not in the current patch
./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234 \
    --extra-files "Trio/NewFile.swift,Trio/AnotherNew.swift"

# Skip drift check entirely
./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234 --no-drift-check
```

### Options

| Flag | Description |
|------|-------------|
| `-p, --patch <NN>` | Patch number to update (e.g., 09). Required. |
| `-c, --cherry-pick <sha>[,<sha>,...]` | Commit SHAs to cherry-pick. Required unless `--dry-run`. |
| `--extra-files <paths>` | Additional file paths to include beyond the existing patch. |
| `-b, --feature-branch <branch>` | Feature branch for drift comparison. Auto-detected from patch name if omitted. |
| `--no-drift-check` | Skip the feature branch drift check. |
| `--dry-run` | Show plan without making changes. |
| `--skip-test` | Skip `patch-test.sh` validation (not recommended). |
| `-h, --help` | Show help. |

### What it intentionally does NOT do

- Does not commit the updated patch (per AGENTS.md rule 7 — no commit unless asked)
- Does not build or deploy (leaves that to the user or the build workflow)
- Does not touch feature branches (only creates/destroys `tmp/` branches)

---

## 2. Failure Modes Addressed

These failures were observed across two agent transcript sessions during Phase 2 implementation work.

| Transcript Mistake | How the Script Prevents It |
|---|---|
| Using `-t dev` instead of `-t tmp/baseline` | Hard-coded to use `-t $BASELINE_BRANCH` |
| Using `-a` instead of `--include-files` | Always computes file list from diff, never passes `-a` |
| Forgetting `git checkout dev` before `generate-patch.sh` | Explicit `git checkout dev` before invocation |
| Patch file written to tmp branch instead of dev | Switches to dev first, uses absolute output path |
| Leaving tmp branches behind | Cleanup trap on EXIT/INT/TERM |
| Stash not popped | Cleanup handler always pops stash |
| Comparing feature branch directly against dev | Not possible — only operates via baseline+update branches |
| Omitting a feature branch commit from the patch | Drift check compares patch output against feature branch |

---

## 3. Drift Check: Detecting Omitted Commits

### The problem

Feature branch has commits A, B, C, D. The patch was generated from A and B. A mid-stack update cherry-picks only D (the latest), missing C. The update takes the existing patch (A+B) + cherry-pick D = patch now has A+B+D. Commit C's changes are silently missing. Nobody notices because the patch applies cleanly and the build works.

### How the drift check works

The drift check runs after patch regeneration and validation (step 9), before cleanup. It requires knowing the feature branch — either auto-detected from the patch name (e.g., patch `09-watch-complication-improvements` → `feature/watch-complication-improvements`) or explicitly via `--feature-branch`.

**Check 1 — Missing files.** Diffs the feature branch against `dev` (three-dot, from merge-base) to get every file the feature branch modifies. Files already covered by other patches in the stack are excluded. Infrastructure files (paths matching `patches/`, `scripts/`, `ci/`, `.github/`, `fastlane/`, `build/`, `docs/`, `.cursor/`, `AGENTS.md`, `.trio-env`) are excluded — these are committed directly to `dev`, never via patches. Remaining files not in the patch trigger a warning. This catches the case where a commit introduced a new file that never made it into the patch.

**Check 2 — Content drift.** For each file in the patch that is **not** also modified by a prior patch (01..N-1), it compares the file content on the `tmp/<name>-update` branch against the feature branch. Since neither prior patches nor the feature branch have modified these files from `dev`, the only changes in both come from this patch/feature respectively. If they differ, it means the patch is missing some feature branch changes for that file.

**Overlap handling.** Files modified by both this patch and prior patches can't be directly compared (the update branch has prior-patch changes the feature branch doesn't). These are flagged as "cannot auto-verify" and listed for manual review.

### When drift is detected

- Keeps the tmp branches alive (instead of deleting them) so you can investigate with `git diff`
- Prints a per-file diff summary
- Changes the "next steps" guidance to prioritize investigation
- Does NOT fail — the patch was generated and validated, it's just possibly incomplete

### Limitations

- Files modified by both this patch AND prior patches cannot be auto-verified (flagged for manual review)
- The auto-detection heuristic (`feature/<patch-description>`) may not match all naming conventions
- Drift in overlapping files requires manual `git diff` inspection
- Infrastructure path exclusion is pattern-based; if app code is placed in an infra directory (unlikely), it would be silently skipped

---

## 4. Proposed Changes to AGENTS.md

### Addition: Replace the "Generate a patch" common workflow

**Remove** the current entry:

```markdown
### Generate a patch (preferred)
```bash
./scripts/generate-patch.sh -n -d "short-description"
```

Manual (single commit):
```bash
# Steady state (post-cutover): mailbox patch with .patch extension
git format-patch -1 --stdout HEAD > patches/NN-short-description.patch
git am --check patches/NN-short-description.patch
```
```

**Replace with** two separate entries:

```markdown
### Generate a NEW patch (appending to the stack)
```bash
./scripts/generate-patch.sh -n -d "short-description" \
  --include-files "path/to/File1.swift,path/to/File2.swift"
```

### Update an existing patch (mid-stack) — PREFERRED
```bash
./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>[,<sha>,...]
```
This script automates the full mid-stack update workflow: baseline creation,
cherry-pick, squash, patch regeneration (with `--include-files`), validation,
drift check, and cleanup. See `./scripts/mid-stack-update.sh -h` for options.

**Do NOT** manually run `generate-patch.sh -s feature/<name> -t dev` for
mid-stack updates. That compares against raw `dev` and produces a patch
containing ALL differences from every earlier patch — not just the changes
for the patch being updated.

For the full manual workflow (rarely needed), see
`docs/feature-branch-workflow-optimization.md` § "Updating an existing patch".
```

### Rationale

The current entry is ambiguous about mid-stack vs. new patches and includes a manual `git format-patch` example that shouldn't normally be used. Splitting into two entries with the automated script as the preferred path for updates eliminates the most common source of agent errors.

---

## 5. Proposed Changes to feature-branch-workflow-optimization.md

### Addition: After the "Worktree considerations" subsection

Add immediately after the existing "Worktree considerations" paragraph in the "Updating an existing patch (mid-stack)" section:

```markdown
### Automated mid-stack update (preferred)

The manual workflow above is automated by `scripts/mid-stack-update.sh`. Use it
instead of running the steps by hand:

```bash
# From Trio-dev worktree, on dev branch
./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>[,<sha>,...]

# Preview what would happen (no changes)
./scripts/mid-stack-update.sh --patch <NN> --dry-run
```

The script handles: stash, baseline creation, patch application, cherry-pick,
squash, file list extraction, `generate-patch.sh` invocation (with
`--include-files`, against `tmp/<name>-baseline`), `patch-test.sh` validation,
feature branch drift check, and cleanup. It does NOT commit the updated
patch — do that after reviewing.

### Common mistakes (mid-stack updates)

| Mistake | Consequence | Prevention |
|---------|-------------|------------|
| Using `-t dev` instead of `-t tmp/<name>-baseline` | Patch contains ALL differences from every patch, not just this one | Use `mid-stack-update.sh` (hardcodes correct target) |
| Using `-a` instead of `--include-files` | May include unintended files | Use `mid-stack-update.sh` (extracts file list from diff) |
| Running `generate-patch.sh` from tmp branch | Patch file written to wrong location | Use `mid-stack-update.sh` (switches to dev first) |
| Comparing feature branch directly against `dev` | 150+ file diff instead of ~16 | Use `mid-stack-update.sh` (only compares update vs baseline) |
| Forgetting to delete tmp branches | Branch pollution, worktree conflicts | Use `mid-stack-update.sh` (cleanup on exit, including failures) |
| Omitting a feature branch commit | Silent functionality loss in patch | Use `mid-stack-update.sh` drift check (auto-compares against feature branch) |
| Editing docs on `dev` instead of `docs` branch | Edits to untracked copy; lost on branch switch | Plan docs live on `docs` branch — `git checkout docs` first |
```

### Version bump

Increment the document version and add a changelog entry describing:
- Addition of `mid-stack-update.sh` as preferred automated workflow
- Addition of "Common mistakes" table
- Reference to drift check for omitted commit detection

---

## 6. Red Team Review Prompt

The following prompt should be given to another AI agent to perform a red team review of the script.

```
You are reviewing a new shell script (scripts/mid-stack-update.sh) and proposed
documentation changes for a git-based patch-stack workflow. Your job is to
RED TEAM the script: find bugs, edge cases, race conditions, failure modes,
and logic errors. Confirm that it operates as intended, or report issues.

CONTEXT
-------
This repo maintains a stack of mailbox patches (patches/01-*.patch through
patches/09-*.patch) applied on top of a `dev` branch. The repo uses two git
worktrees (Trio-dev for patch tooling, Trio for feature development) pointing
at the same underlying git repo.

The script automates a "mid-stack patch update" — updating an existing patch
(e.g. 09) by:
  1. Creating a baseline branch (dev + patches 01..N-1)
  2. Creating an update branch (baseline + current patch N + cherry-picked commits)
  3. Squashing into a single commit
  4. Running generate-patch.sh with --include-files against the baseline
  5. Running patch-test.sh to validate the full stack
  6. Drift check: comparing each patch file's content on the update branch
     against the feature branch to detect accidentally omitted commits
  7. Cleaning up tmp branches and restoring stash

The drift check works by:
  - Categorizing patch files into "verifiable" (only this patch touches them)
    and "overlap" (also modified by prior patches 01..N-1)
  - For verifiable files: direct content comparison between update branch and
    feature branch (should be identical since both start from dev for these files)
  - For overlap files: cannot auto-verify, flagged for manual review
  - Also checks for files the feature branch modifies but the patch doesn't
    include at all (missing files)

The script delegates to two existing tools:
  - scripts/generate-patch.sh: creates mailbox patches by diffing two branches
  - scripts/patch-test.sh: validates all patches apply cleanly from dev

FILES TO REVIEW
---------------
Read these files in order:
  1. scripts/mid-stack-update.sh (the new script)
  2. scripts/generate-patch.sh (existing, called internally)
  3. scripts/patch-test.sh (existing, called internally)
  4. docs/feature-branch-workflow-optimization.md §"Updating an existing patch"
  5. AGENTS.md §"Common workflows"

REVIEW CHECKLIST
----------------
For each item, report PASS or FAIL with explanation:

A) CORRECTNESS
  - Does the baseline branch correctly include patches 01..N-1 and exclude N+?
  - Does the update branch correctly include the current patch + cherry-picks?
  - Is the squash logic correct (soft reset to baseline, commit)?
  - Does the file list for --include-files capture all changed files?
  - Is -t set to the baseline branch (NOT dev)?
  - Is generate-patch.sh run from dev (NOT from a tmp branch)?
  - Does the output path point to the correct location on dev?

B) FAILURE HANDLING
  - If cherry-pick has conflicts, does the script fail gracefully?
  - If generate-patch.sh fails, are tmp branches cleaned up?
  - If patch-test.sh fails, is the worktree restored to dev?
  - If the script is interrupted (Ctrl-C), are tmp branches cleaned up?
  - Is the stash popped in all exit paths (success, failure, interrupt)?
  - Can the cleanup handler run correctly from any point in the script?

C) EDGE CASES
  - Updating the FIRST patch (01): no baseline patches to apply. Does it handle
    empty BASELINE_PATCHES array?
  - Updating the LAST patch: all other patches are baseline. Does this work?
  - Patch file has spaces in its path (e.g. from file names with spaces).
  - Cherry-pick SHA doesn't exist or is invalid.
  - Worktree is dirty with untracked files.
  - A tmp branch from a previous failed run already exists.
  - generate-patch.sh's internal `git fetch origin dev` fails (offline).
  - The existing patch file in the diff has renamed files (R status).

D) DRIFT CHECK CORRECTNESS
  - Does the categorization of "verifiable" vs "overlap" files work correctly?
  - For a file only in this patch, is the content comparison between the update
    branch and the feature branch the right check? (Both diverge from dev for
    these files, so identical content = no drift.)
  - For a file also in prior patches, is skipping auto-verify the right call?
    Could there be a better heuristic?
  - Does the "missing files" check (feature branch files not in the patch)
    correctly identify files that should be in the patch?
  - Could there be false positives? (e.g., the feature branch has WIP changes
    not intended for this patch yet)
  - Could there be false negatives? (e.g., drift in overlapping files that goes
    undetected because they're skipped)
  - When drift is detected, are the tmp branches correctly preserved for
    investigation? Does the trap handler respect the preservation?
  - Is the auto-detection heuristic (feature/<patch-description>) reasonable?

E) INTERACTION WITH generate-patch.sh
  - Does generate-patch.sh accept -s and -t pointing to tmp branches?
  - Does generate-patch.sh's worktree enforcement (must be Trio-dev) pass
    when run from our script on dev?
  - Does the --include-files list format match what generate-patch.sh expects?
  - Does generate-patch.sh's internal validation (git am --check) work
    against the baseline branch?

F) DOCUMENTATION CONSISTENCY
  - Do the proposed AGENTS.md changes accurately describe the script's behavior?
  - Do the proposed workflow doc changes match the script's actual steps?
  - Is the "Common mistakes" table accurate?
  - Are there mistakes from the transcripts that the script does NOT prevent?

G) SECURITY / SAFETY
  - Does the script ever force-push, modify dev history, or delete non-tmp branches?
  - Does the script touch the feature branch in the Trio worktree?
  - Could the stash pop silently overwrite the regenerated patch file?
  - Could the drift check's `git show` commands leak sensitive data?

EXPECTED OUTPUT
---------------
For each section (A-G), provide:
  - PASS/FAIL per sub-item
  - For FAILs: specific line number, description of issue, suggested fix
  - An overall PASS/FAIL verdict
  - Any suggested improvements (even if overall PASS)
```

---

## 7. Implementation Log

Tracks what was implemented, when, and why. Each entry corresponds to a script version.

### Script v1.0 (2026-03-08)
- Initial implementation of `scripts/mid-stack-update.sh`
- Core workflow: stash → baseline → update → cherry-pick → squash → regenerate → validate → drift check → cleanup
- Drift check with missing-files and content-drift detection
- Auto-detect feature branch from patch name

### Script v1.1 (2026-03-08)
First red-team review (findings A-G). Fixes applied:
- **(A)** `generate-patch.sh`: fixed rename handling in `--include-files` filter to check both old and new paths
- **(B)** Cherry-pick conflict: `cleanup()` now defensively runs `git cherry-pick --abort`, `git am --abort`, `git merge --abort` before `git checkout dev`
- **(C)** Drift check missing-files: now excludes files covered by prior patches (`PRIOR_PATCH_FILES_SORTED`)
- **(D)** Drift preservation: `cleanup()` checks `${DRIFT_DETECTED:-false}` immediately to preserve tmp branches on Ctrl-C
- **(E)** Stash-pop safety: refuses to run if target patch file has uncommitted changes
- **(F)** Tmp branch cleanup: detects branches stuck in other worktrees with actionable error messages
- **(G)** Documentation: AGENTS.md and workflow doc updated with script behavior and common mistakes table

### Script v1.2 (2026-03-08)
Second red-team review. Fixes applied:
- Duplicate patch prefix rejection (aligned with `patch-test.sh` `collect_patches`)
- SHA-based stash tracking (`STASH_SHA`) instead of message-based matching
- Cherry-pick conflict message updated to reflect auto-abort behavior
- Three-dot diff (`dev...$FEATURE_BRANCH`) for more accurate drift check
- Missing-files check now excludes files from ALL other patches (N+1..end), not just prior (01..N-1)
- Bash 3.2 compatibility: replaced `declare -A` with string-based seen list

### Script v1.3 (2026-03-08)
- Cleanup trap stash-pop error handling aligned with success-path messaging (two-line actionable warning)

### Script v1.4 (2026-03-09)
Infrastructure file drift noise elimination. Triggered by observing consistent agent behavior: every `mid-stack-update.sh` run flagged `AGENTS.md`, `scripts/generate-patch.sh`, and `patches/09-*.patch` as "missing from patch," causing `DRIFT_DETECTED=true`, which prevented auto-cleanup of tmp branches. Agents had to manually delete branches after every run.

**Root cause:** Feature branches accumulate infrastructure file commits (agents modify AGENTS.md, scripts, etc. as part of their workflow). These files are committed directly to `dev` and never belong in patches, but the drift check had no concept of "infrastructure vs app code."

**Changes:**
- Added `is_infra_path()` function — bash 3.2-compatible `case` matcher for paths never shipped via patches: `patches/`, `scripts/`, `ci/`, `.github/`, `fastlane/`, `build/`, `docs/`, `.cursor/`, `AGENTS.md`, `.trio-env`
- Missing-files loop now diverts infra files to `INFRA_SKIP_FILES` instead of `MISSING_FILES` — they no longer set `DRIFT_DETECTED=true`
- New reporting block lists skipped infra files as informational (`ℹ`) instead of warnings (`⚠`)
- Cleanup message is now conditional: "tmp branches deleted" vs "tmp branches preserved for drift investigation"
- Summary section adds `Cleanup:` status line and shows infra exclusion count in drift check result (e.g., `CLEAN (3 infra file(s) excluded)`)

**Effect:** Clean runs with only infrastructure drift now auto-cleanup tmp branches and report `CLEAN` instead of `DRIFT DETECTED`. Real app-code drift still triggers preservation and warnings.

---

## Changelog

### v1.2 (2026-03-09)
- Added implementation log (section 7) tracking all script versions v1.0–v1.4
- Updated drift check description to reflect v1.4 infrastructure path exclusion and three-dot diff
- Added infrastructure path exclusion limitation note
- Updated status to "Implemented (script at v1.4)"

### v1.1 (2026-03-08)
- **Red team review implemented:** All proposed documentation changes and code fixes from findings A-G have been applied to the actual files (scripts/mid-stack-update.sh, scripts/generate-patch.sh, AGENTS.md v3, feature-branch-workflow-optimization.md v11). This document now serves as the historical record of the proposal and review.

### v1.0 (2026-03-08)
- Initial proposal document
- Script overview and usage documentation
- Failure modes analysis from agent transcript review
- Drift check design and limitations
- Proposed AGENTS.md changes (replace ambiguous "Generate a patch" with split new/update entries)
- Proposed feature-branch-workflow-optimization.md changes (automated workflow + common mistakes table)
- Red team review prompt (sections A-G covering correctness, failure handling, edge cases, drift check, generate-patch interaction, documentation consistency, and safety)
