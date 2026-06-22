# AGENTS.md — v19

Instructions for AI agents working in this repository.

This repo is a personal fork that maintains a patch stack in `./patches/` applied on top of upstream `dev`. Agents should optimize for repeatable patch application and safe builds.

Read first:
- `docs/process/feature-branch-workflow-optimization.md`

## Non-negotiable safety rules

1) **Never upload to TestFlight unless explicitly instructed.**
   - When the user requests a build, ask for flags — do not assume `--build-only` or any other flag (see "When the user instructs a build").
   - Do not run `fastlane release` unless explicitly requested.

2) **Never print or inspect secrets** (including `.trio-env`, signing secrets, API keys, tokens).

3) **Do not perform destructive submodule cleanup** (no `git clean` / `git reset` inside submodules) unless explicitly instructed.

4) **Do not change bundle IDs, signing, or Fastlane lanes** unless explicitly instructed.

5) **Do not hand-edit patch files to fix apply failures.**
   - Fix code and regenerate the patch.

6) **Do not modify Xcode project files or run project sync from an agent session.**
	-	Do not manually edit `Trio.xcodeproj/project.pbxproj`.
	-	Do not run `scripts/sync_project_files.rb` or invoke it indirectly from an agent session, including via ruby, shell commands, editor tasks, wrapper scripts, or other automation.
	-	Canonical Xcode project updates occur only through the repository’s normal build/sync workflow. Agents must not force project regeneration.
	-	When adding files, put them in the correct repo location and update `scripts/sync_project_files_config.rb` (e.g. `TARGET_GLOBS`, `TARGET_BUILD_SETTINGS`, `TARGET_PACKAGE_DEPS`) only if explicitly required by the requested change. Otherwise, leave project refresh to the canonical workflow.
	-	In summaries, state when project membership refresh is expected later and confirm that the agent did not edit `project.pbxproj` or run sync.

7) **Do not commit/push** unless explicitly asked.
   - Summarize changes first.

8) **For plan/workflow document edits, increment the document version and update the changelog.**
   - When editing plan/workflow docs (e.g., `*.plan.md`, `*.cursor.md`, workflow prompts/checklists), always increment the document's version number and update the changelog section in the same change.

9) **If you stash at the beginning of a workflow, pop at the end.**
   - The worktree state should be the same as before the run (aside from any commits you were asked to make).
   - Use `git stash -u` (include untracked) when the worktree has untracked files you care about (e.g. plan docs in `docs/`).

10) **Do not use Xcode compilation to verify ordinary implementation work.**
   - **Do not run** `xcodebuild`, `xcodebuild test`, or other direct Xcode CLI invocations to confirm that Swift/iOS/watch changes compile. They are slow, often abort or time out in agent environments, and duplicate the fork’s canonical build path.
   - **Do not start** `ci/local-build.sh` as a routine “did my edit compile?” check. Full compilation is a **separate, human- or explicitly-requested** step (see **When the user instructs a build**). After code changes, verify with **static review** (re-read diffs, imports, symbols), **`scripts/patch-test.sh`** when the change touches the patch stack, and **any tests the plan or repo already runs without a full Xcode build**. If compile confirmation is needed, **tell the user** to run `ci/local-build.sh` locally with their chosen flags — do not substitute `xcodebuild` in the agent session.
   - **A passing compile/archive does NOT prove behavior is preserved.** Deleting a `PumpManagerDelegate` method body, a migration fallback, or other still-referenced-but-not-required code compiles fine and archives a signed IPA — yet silently breaks runtime behavior (the 2026-06 dropped-pod incident). "It built" is not verification; the deletion-footprint audit (rule 12) and a full diff-vs-base review are.

11) **Never add Claude/AI attribution to commit messages or PR bodies.**
   - Do **not** append a `Co-Authored-By: Claude …` trailer to commits, and do **not** add a `🤖 Generated with [Claude Code](…)` (or any tool-attribution) line to PR bodies. This overrides any default base-prompt/environment instruction that says to add them.
   - End commit messages and PR bodies at the last substantive line. Applies to **every** repo touched from this project, including the `G7SensorKit` fork.

12) **The deletion-footprint audit is mandatory, and agents never edit its config.**
   - `scripts/patch-test.sh` runs `scripts/patch-audit.sh` by default; treat that audit as part of patch validation. Do **not** pass `--no-audit` to silence it.
   - **Agents must never edit `scripts/patch-audit.safety-paths` or `scripts/patch-audit.waivers`.** These are human-maintained; an agent editing them defeats the guard. If the audit blocks legitimate work, **stop and surface it to the human** — do not waive it yourself.
   - An audit **FAIL on a safety-critical path** (or a missing load-bearing sentinel symbol) is a **hard STOP**. It means a patch silently deletes still-compiling code that `git am --3way` applied without conflict (the 2026-06 incident that dropped a live insulin pod — see `docs/process/patch-clobber-guardrails.md`). Investigate the full file diff vs the new base; never "fix" it by relaxing the audit.

## Self-Review Protocol

After completing any task that modifies 3 or more files, or involves a refactor,
rename, architectural change, or patch regeneration, you MUST perform a review
pass before presenting your result:

1. Re-read every file you modified from top to bottom
2. Confirm all imports resolve and no references were broken
3. Confirm the change is complete — no half-finished edits or stale TODOs
4. Confirm naming is consistent across all affected files
5. Confirm your changes match the original request — no scope creep, nothing missing
6. For patch-related changes: confirm the patch still applies cleanly and
   `scripts/patch-test.sh` would pass (run it if in doubt)
7. For cross-patch type dependencies (patch N references a type, extension, or
   notification name defined in patch M): verify the referenced symbol doesn't
   collide with any in-scope protocol, typealias, or module-level name. Common
   shadowed names in this codebase: `NotificationCenter` (shadowed by a protocol
   in `Trio/Sources/Services/Notifications/NotificationCenter.swift`). When in
   doubt, use fully qualified names (e.g., `Foundation.NotificationCenter.default`).
8. If you find an issue, fix it silently and restart the review from step 1
9. Only present your result once the review passes cleanly

Never present a result from a multi-file or patch-modifying change without first
completing this protocol.

## Verification discipline (avoid confidently-wrong conclusions)

- **Verify OS / SDK facts against the authoritative source before acting on them** — especially raw enum values seen in logs or telemetry. A raw `WKExtendedRuntimeSessionState(rawValue: 2)` was read as `.invalid` from memory + a stale in-code comment; it is actually `.running` (the enum is `notStarted=0, scheduled=1, running=2, invalid=3`). That single misread produced a wrong user-facing diagnosis and a misguided "fix". Grep the SDK header instead of trusting memory/comments: `find /Applications/Xcode.app -name '<Type>.h'`. And prefer logging a **mapped name**, never `String(describing:)` of an imported `NS_ENUM` (it prints the opaque `Type(rawValue: N)`).
- **When data/telemetry contradicts your hypothesis, doubt the hypothesis first**, not the data. (An `ext_session_active=true` + `rawValue 2` + readings-still-flowing heartbeat was the tell that the session was running — it was initially explained away.)
- **Don't propagate an unverified interpretation across steps or subagents.** A claim that "every event is logged twice → halve the counts" was actually an s3-query artifact; it spread into multiple analyses before being caught. State assumptions as assumptions and verify the load-bearing ones before building on them.

## Untracked files and clean / reset

- **`git clean -fd` (or scripts that run it) removes untracked files.** Procedures that "reset to clean dev" or "test patches from clean state" often run `git reset --hard` and `git clean -fd` in the repo. Any untracked file (e.g. `docs/in-progress/<initiative>/02-implementation-plan.md`) will be **permanently removed** unless it was stashed or committed elsewhere.
- **Before running patch-test or any workflow that might clean the worktree:** Stash untracked files with `git stash -u -m "WIP untracked before clean"` so they can be restored with `git stash pop` afterward.
- **Mid-stack patch update:** Step 0 in `docs/process/feature-branch-workflow-optimization.md` uses `git stash -u`; after step 6 (cleanup), run `git stash pop` to restore stashed changes including untracked files.
- **Untracked patch files and stash-pop conflicts:** When a new patch file (e.g. `patches/10-name.patch`) exists as an untracked file and you need to stash before a workflow that regenerates it, move the untracked patch to `/tmp/` before `git stash -u` and restore it afterward. Otherwise, `git stash pop` will fail with "already exists, no checkout" because the regenerated file conflicts with the stashed untracked version.

## Tracking docs on `dev` (docs are committed with completed patch work)

Plan/design docs and prompts live in `docs/` on the **`dev`** branch. During active work, docs may be edited freely and kept uncommitted as WIP, but they must be **committed alongside the final patch(es)** when a feature is completed.

### Rules of thumb

- **WIP is fine uncommitted**, but protect it from clean/reset workflows (stash untracked + tracked changes as needed).
- **When the feature is complete:** commit the docs update in the same completion set as the patch change:
  - Either one commit that includes both docs + patch updates, or two adjacent commits (docs + patch) pushed together.
- **Docs should reflect reality** at completion time: final plan, implementation log, effectiveness analysis (if applicable), and any important decisions/tradeoffs.

## Patch commit lifecycle

Regenerated and new patch files follow the same lifecycle as docs: **keep them as uncommitted modifications on `dev` during development.** The build system (`ci/local-build.sh`) picks up uncommitted patch changes via stash reapply when you run from `dev`.

**Do not commit patch files to `dev` until the user explicitly requests it.** The commit to `dev` is the "milestone complete" step — only after:
1. Build succeeds (`ci/local-build.sh --base-branch dev --build-only`)
2. Deploy happens (TestFlight upload)
3. BetterStack verification confirms expected behavior in production

As of v1.7, `mid-stack-update.sh` auto-restores the committed version of a dirty target patch (no manual intervention needed). If a tooling precondition still requires a commit (rare), **ask the user** before committing. Do not commit patches to satisfy script preconditions without permission.

## Non-negotiable rules for working with patches

1) **Keep patch filenames and ordering deterministic.**
   - Numeric prefix `NN-` defines ordering; ordering is alphabetical by filename.

2) **`generate-patch.sh` remains the canonical patch generator post-cutover.**
   - It will emit mailbox patches suitable for `git am` (temporary `*.am.patch` during cutover, then `*.patch` steady-state).

## Key invariant

A clean checkout of fork `dev` (synced to upstream) must be able to apply all patches in `./patches/` in order using `git am`.

## Working with git worktrees

This repo uses two worktrees pointing to the same underlying git repo:

- `Trio-dev` — canonical location for patch tooling, build scripts, and dev branch work.
- `Trio` — worktree for feature branch development and code changes.

**Critical:** A branch checked out in one worktree cannot be created, deleted, or checked out in the other. If you get `fatal: a branch named '...' already exists`, switch the other worktree to a different branch first.

### Run from dev

These commands **must** be run from the **Trio-dev** worktree with **`dev`** checked out (so the current branch is `dev`, not a tmp or feature branch):

- `ci/local-build.sh --base-branch dev` (and variants: `--build-only`, etc.)
- `./scripts/generate-patch.sh` whenever it writes into `./patches/` (new or updated patch)

Use `-s` / `-t` to specify source and target branches; the important part is that the worktree is on `dev` when the script runs. For mid-stack patch updates, run `git checkout dev` in Trio-dev before invoking `generate-patch.sh` (see `docs/process/feature-branch-workflow-optimization.md`).

## `git am --3way` for overlapping patches

When a patch modifies a file that an earlier patch also modified, plain `git am` may fail because the context lines don't match the post-earlier-patches state. Use `git am --3way` to fall back to 3-way merge. Always review the merge result. The build script (`ci/local-build.sh`) uses `--3way` internally.

**A conflict-free `git am --3way` apply is NOT verification.** When reconciling or regenerating a patch against a changed base, `--3way` happily applies hunks that delete code, with no conflict, as long as the deleted lines still exist in the base. Reviewing only the *conflicting* hunks misses these — which is exactly how the 2026-06 incident shipped (a telemetry patch silently deleting the Omnipod migration fallback from `DeviceDataManager.swift`). After any reconcile/regenerate:
- Review the **complete diff of every touched file vs the new base** (`git diff <base>..HEAD -- <file>`), **deletions especially** — not just the conflict markers.
- A patch's footprint must match its stated purpose. A patch named for telemetry that deletes pump-manager logic is a **defect**, not a merge artifact.
- Let `scripts/patch-test.sh` run (it invokes the deletion-footprint audit — see safety rule 12). A safety-path FAIL is a hard STOP.

## Agent sandbox notes

`ci/local-build.sh` requires unrestricted filesystem/process access (it creates worktrees, runs Xcode builds, accesses signing certificates). In sandboxed agent environments (e.g., Cursor), request `all` permissions before running build commands.

**Verification vs. builds:** Even with permissions, **do not** run `xcodebuild` (or ad-hoc scheme builds) to validate edits. Use review + `patch-test.sh` + plan-specified non-Xcode checks. Reserve `ci/local-build.sh` for when the **user** asked you to run a build (see **When the user instructs a build**).

## Local build environment gotchas

`ci/local-build.sh` runs fastlane/`gym` and (for deploys) talks to Apple. Two environment issues bite non-interactive or freshly-spawned shells:

- **UTF-8 locale required.** If `LANG`/`LC_ALL` are empty (locale `C`), fastlane/`gym` throw `Encoding::InvalidByteSequenceError ("… on UTF-16")` during pre-flight detection — before any compile. `ci/local-build.sh` now defaults `LANG=en_US.UTF-8`; if you invoke fastlane/`gym`/`xcodebuild` directly, export a UTF-8 locale first.
- **Local network filters (e.g. Little Snitch) can silently block the TestFlight / `match` steps.** Homebrew's unsigned `ruby` may be prompted or denied when reaching `api.appstoreconnect.apple.com`; headless, it times out as `Net::OpenTimeout`. Signed tools like `curl` are unaffected — so **do not** conclude "the network works" from a `curl` test. Allow `ruby → apple.com` persistently.
- **Full deploy vs build-only:** `ci/local-build.sh` with **no** `--build-only` builds *and* runs `fastlane release` (TestFlight upload) + GitHub release recording. Use `--build-only` to stop before upload.

## Common workflows

### Build current branch (no patches, no upload)
```bash
ci/local-build.sh --build-current --build-only
```

### Simulate CI build: dev + patch stack (no upload)
```bash
ci/local-build.sh --base-branch dev --build-only
```
**Important:** Run this from the `Trio-dev` worktree with `dev` checked out. If the current branch is not `dev`, the build script sets `REAPPLY_STASH=0` and silently excludes uncommitted changes to patch files. If you must build from a non-dev branch, add `--reapply-stash` explicitly.

## When the user instructs a build

When asked to run a build, do the following.

### 1) Upstream sync (automatic)

- For `--base-branch dev` builds, `local-build.sh` automatically fetches
  `upstream/dev`, merges if behind, and pushes to `origin/dev`. No manual
  steps needed. The script logs sync status; merge failures are non-fatal
  (it aborts and continues with current `dev`).
- To skip: `--no-sync-upstream`. To force for non-dev base branches: `--sync-upstream`.
- If you see the build log report a merge conflict, tell the user — they may
  want to resolve it before rebuilding.

### 2) Ask the user for build flags

- **Do not assume flags.** Ask the user what command and flags to use (e.g. `--build-only`, `--include-untracked`, build+deploy, etc.) rather than defaulting to `--build-only`. If the user provides a specific command, use it exactly.

### 3) Run the build in the background

- Invoke `ci/local-build.sh` with the user's chosen flags as a **background process**. Do not run it in the foreground so the agent can continue to monitor and respond.
- **Do not** capture or redirect log output yourself. The script already writes all output to a timestamped log file under `build/artifacts/`.

### 4) Provide a command to watch the build log

- The build script creates a log file at `build/artifacts/ci-local-build-YYYYMMDD-HHMMSS.log` (e.g. `ci-local-build-20260303-115620.log`).
- After starting the build, either list `build/artifacts/` to get the new log filename, or give the user a command that works for the latest log. Example (from repo root):

  ```bash
  tail -f build/artifacts/ci-local-build-YYYYMMDD-HHMMSS.log
  ```

  Or to follow the most recent build log:

  ```bash
  tail -f $(ls -t build/artifacts/ci-local-build-*.log 2>/dev/null | head -1)
  ```

- Tell the user they can run that command in a terminal to watch the build output live.

### 5) Monitor build progress

- Periodically check the build log (or process status) to see when the build completes or fails.
- If the build is still running, you can report progress based on the log (e.g. "Build in progress, currently running …").

### 6) If an error is detected

- **Investigate immediately:** Read the relevant part of the log (e.g. around failure messages, ❌ markers, or "error:" / "ARCHIVE FAILED") to identify the cause.
- **The failed build's worktree is preserved by default** (`ci/local-build.sh`
  keeps it on any non-zero exit and prints `Preserving worktree at <path>`). It
  holds the applied patch stack + build state — `cd` there to inspect the actual
  failure (e.g. `git -C <path> status`, the build log). Remove it when done with
  `git worktree remove --force <path>`, or prune accumulated leftovers with
  `scripts/cleanup-build-leftovers.sh` (dry-run by default; `--apply` to delete).
  Pass `--no-preserve-on-error` to `local-build.sh` to opt out of preservation.
- **Propose a fix** and, if the fix is **relatively minor** (e.g. a clear typo, one-file change, or small logic fix):
  - Implement the fix on the appropriate branch **in the Trio worktree** (feature branch or, for patch-stack builds, the branch that the patch was generated from).
  - Regenerate the patch using `mid-stack-update.sh --cherry-pick` (see "Update an existing patch (mid-stack)" above). **Important:** the fix commit is rarely the only new commit on the feature branch. Follow the pre-flight step to enumerate ALL commits not yet in the patch and include them all in `--cherry-pick`, earliest first.
  - Run `scripts/patch-test.sh` to validate the patch stack.
  - If patch test passes, start a **new** build in the background and again give the user a `tail -f` command for the new log.
- If the fix is not minor (e.g. architectural or multi-file), report the findings and proposed fix to the user and do not automatically implement or start a new build unless asked.

### Validate patch stack (authoritative)
```bash
scripts/patch-test.sh
```
This applies the full stack and then runs `scripts/patch-audit.sh` (the
deletion-footprint guard — see safety rule 12 and
`docs/process/patch-clobber-guardrails.md`). A non-zero audit fails the
validation. Do not bypass with `--no-audit`.

### Generate a NEW patch (appending to the stack)

Run from **Trio-dev** with **`dev`** checked out (see "Run from dev" above):

```bash
./scripts/generate-patch.sh -n -d "short-description" \
  --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"
```

Prefer `--include-files` over `--all-files` when only specific files changed.

#### When the new patch modifies files also changed by earlier patches

`generate-patch.sh -n -t dev` produces a patch whose context lines match raw
`dev`. If earlier patches also modify those files, the context won't match the
post-prior-patches state and `patch-test.sh` will fail.

Correct workflow:

1. **Rebase the feature branch** (in the Trio worktree) onto the feature branch
   of the highest-numbered overlapping patch. This gives the feature branch the
   correct cumulative file state. Resolve conflicts during the rebase — this is
   the right place for conflict resolution, not in tmp branches in Trio-dev.

2. **Build a tmp baseline branch** in Trio-dev (dev + patches 01 through N-1):
   ```bash
   git checkout -b tmp/<name>-baseline dev
   for p in patches/0[1-9]-*.patch; do git am --3way "$p" || break; done
   ```

3. **Generate the patch against the baseline** (from `dev`):
   ```bash
   git checkout dev
   ./scripts/generate-patch.sh -n \
     -s feature/<name> \
     -t tmp/<name>-baseline \
     -d "short-description" \
     -o patches/NN-short-description.patch \
     --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"
   ```

4. **Clean up** the tmp baseline branch:
   ```bash
   git branch -D tmp/<name>-baseline
   ```

5. **Validate** the full stack: `scripts/patch-test.sh`

Feature branches for patches that overlap with earlier patches **must** include
the earlier patches' changes in their history (via rebase). Feature branches
that only touch new files can remain branched from raw `dev`.

### Update an existing patch (mid-stack) — MANDATORY

**You MUST use `mid-stack-update.sh` for all mid-stack patch updates.** Do not
manually create baseline branches, run `generate-patch.sh` directly, or
replicate the workflow steps by hand. The manual workflow exists in the docs
only as a reference for understanding what the script does internally.

#### Pre-flight: enumerate ALL new commits

As of v1.7, **the script auto-detects candidates** when `--cherry-pick` is
omitted. Run without `--cherry-pick` to see all commits on the feature branch
since merge-base with dev, plus a suggested `--cherry-pick` command:

```bash
# From Trio-dev worktree, on dev branch:
./scripts/mid-stack-update.sh --patch <NN>
# → prints candidate commits and a suggested --cherry-pick command, then exits
```

**As of v17 the candidate list is exact.** Patches carry `Trio-Patch-Source-*`
provenance trailers (written automatically on every regen). When present, the script
computes the **exact** set of new commits by diffing the feature branch's `git patch-id`s
against the recorded ones (stable across rebase/amend), auto-resolves the feature branch
from `Trio-Patch-Source-Branch`, and prints just those commits (or "already up to date") —
so `mid-stack-update.sh --patch <NN>` with no other flags is enough. A legacy patch with no
provenance falls back to listing ALL candidates (prune manually). Either way: include only
commits added since the last update, earliest first. A common mistake is cherry-picking only
a fix commit while forgetting the feature commit it modifies — this guarantees a conflict.

```bash
# After reviewing candidates, run with the SHAs you want:
./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>[,<sha>,...]
```

#### Choosing `--cherry-pick` vs `--from-feature-branch`

| Scenario | Mode | Why |
|----------|------|-----|
| Added new commits to the feature branch | `--cherry-pick` | Default ~95% of the time. Cherry-picks onto the existing patch baseline. |
| Previous regeneration was rolled back; need to redo with more commits | `--cherry-pick` | Restore committed version first (see "Dirty patch file" below), then cherry-pick ALL commits since that version. |
| Feature branch was rebased, force-pushed, or had commits amended/squashed | `--from-feature-branch` | Commit history no longer aligns with the patch baseline. Last resort only. |

**Quick test:** if `git log --oneline <feature-branch>` still contains the
original commits that were cherry-picked into the patch, use `--cherry-pick`.
If those commits are gone (rebase/amend), use `--from-feature-branch`.

**This is now enforced by the tool (v1.11), not just advice.** When you pass
`--from-feature-branch`, `mid-stack-update.sh` reconciles the patch's recorded
patch-id provenance against the feature branch and:
- **refuses** when cherry-pick would apply cleanly (history aligned) — and prints
  the exact `--cherry-pick <shas>` command for you;
- **refuses** when the patch has no provenance to verify (legacy patch);
- **allows** `--from-feature-branch` automatically only when history has genuinely
  diverged (a recorded commit is no longer on the branch by patch-id).

Do not reach for `--from-feature-branch` to avoid enumerating commits — the script
already computes the cherry-pick SHAs, so cherry-pick is *less* work, not more. To
override the gate (only when cherry-pick genuinely cannot apply), pass
`--force-from-feature-branch "<reason>"`; the reason is logged for audit. Forcing
without a real divergence reason is a process violation — it can sweep unrelated
tree state into the patch (the failure mode behind the watch Info.plist drops and
the 2026-06 patch-13 clobber).

If the script fails, **fix the script or report the error** — do not fall back
to the manual workflow. Common failure causes and fixes:
- **Dirty patch file:** As of v1.7, `mid-stack-update.sh` **auto-restores**
  the committed version of a modified target patch before proceeding (the most
  common case — a prior regeneration was rolled back per patch lifecycle). No
  manual `git checkout --` needed. **Untracked** target patches (new files
  never committed) still require manual intervention: move it aside
  (`mv patches/NN-name.patch /tmp/`) before running the script.
  Do NOT use `--from-feature-branch` just because the working-tree patch is
  dirty — that's not a baseline divergence.
- **Branch checked out in other worktree:** switch the other worktree to a
  different branch.
- **Cherry-pick conflict:** Do NOT fall back to manual patch generation.
  Diagnose the root cause before retrying:
  1. The most common cause is **missing intermediate commits**. If the commit
     being cherry-picked has parent B, but B was never incorporated into the
     patch, the cherry-pick fails because its context lines reference B's
     state while the patched state reflects an earlier version. Compare the
     file at the parent commit (`git show <parent>:<file>`) against the
     patched state to confirm the divergence.
  2. Fix by including all missing commits in `--cherry-pick`:
     `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <missing>,<new>`
     Commits are applied in the order listed, so put earlier commits first.
  3. Re-run the script. Do not manually create baseline branches or generate
     patches by hand as a workaround unless explicitly told to do so.
- **Patch baseline diverged (merge/rebase/amend on feature branch):** If the
  feature branch was merged into or rebased/amended so the patch no longer
  matches, cherry-pick will conflict. Use `--from-feature-branch` with
  `--feature-branch <branch>` to regenerate the patch from the current feature
  branch state; no rebase required.
  **`--from-feature-branch` is a last resort, not an escape hatch.** Only use
  it when diagnosis confirms the baseline has actually diverged (merge, rebase,
  or amend on the feature branch). Do NOT use it to work around cherry-pick
  conflicts caused by missing intermediate commits — that masks the real
  problem and skips the cherry-pick workflow's provenance tracking. The gate
  (above) blocks the lazy case automatically; if it blocks you, the right
  response is almost always to run the `--cherry-pick` command it printed, not to
  reach for `--force-from-feature-branch`.

#### Patches that ADD new files

When the patch being updated **adds new files** (not present on `dev`), you MUST pass them to `--extra-files` (comma-separated). With `--from-feature-branch`, regeneration scopes from the committed patch's file list, which does **not** include never-before-committed files, so they are **silently dropped**:

```bash
./scripts/mid-stack-update.sh --patch <NN> --from-feature-branch \
  --feature-branch feature/<name> \
  --extra-files "Trio Watch App Extension/NewA.swift,Trio Watch App Extension/NewB.swift"
```

**Red flag:** the `Files in patch: N` line drops vs. the previous patch (build 206: 17 → 15). Because the watch target uses a **synchronized file group**, a dropped `.swift` file does **not** fail at patch-apply or `patch-test` — it fails only at build time as `cannot find <Type> in scope`.

**As of v17 the tooling enforces this automatically:**
- **Brand-new files** (added on the feature branch, absent on `dev`, owned by no other patch) are **auto-included** — `--extra-files` is no longer required for them.
- **Fail-closed drift check:** any feature-branch file missing from the regenerated patch now **aborts** (non-zero) with the exact `--extra-files "<list>"` to re-run. Ambiguous modified-existing files that get dropped hit this — the abort tells you precisely what to add.
- **Orphan files from abandoned patches:** if the feature branch was stacked on a now-removed patch (e.g. the abandoned crashlytics / `AppDiagnostics` work), its files show as "missing" forever — acknowledge with `--drift-exclude-regex '<path-regex>'`.
- **Sibling attribution is stash-safe:** ownership of files by *other* patches is snapshotted from the working tree **before** the stash, so files owned by an as-yet-uncommitted sibling patch aren't false-flagged.
- **Iterating on the tooling scripts themselves:** pass `--exclude-from-stash "scripts/generate-patch.sh,scripts/mid-stack-update.sh"` so uncommitted script edits aren't stashed (and reverted to committed) mid-run.

See `./scripts/mid-stack-update.sh -h` for all options.

**Do NOT** manually run `generate-patch.sh -s feature/<name> -t dev` for
mid-stack updates. That compares against raw `dev` and produces a patch
containing ALL differences from every earlier patch — not just the changes
for the patch being updated.

## How a change actually reaches a build (mental model)

A build is **`dev` + the patch stack**, never a feature branch directly. A commit
on `feature/<name>` does **not** ship until it is folded into a patch. When a
build misbehaves, the question is always "is this change in a patch, and is that
patch in the build?" — not "is it on the branch?".

- **Feature-branch commit → patch:** fold via `mid-stack-update.sh --patch <NN>
  --cherry-pick <sha>` (see above).
- **Build → branch mapping:** CI builds are tagged/branched as
  `origin/ci-build/trio-vX.Y.Z-NNN-local-*` (NNN = build number). To see exactly
  what shipped in a build, inspect that ref, not `dev` HEAD.
- **Regression hunting across builds:** diff the *patches* between two build refs,
  not just the source. A key that silently disappears between builds (e.g. an
  Info.plist key) is usually a **patch regeneration scope** change, not a source
  edit — see the watch Info.plist note below for a real instance.

## Shared submodules and the iPhone north star (G7SensorKit)

`G7SensorKit` is a **shared** dependency: the iPhone app (`G7CGMManager`) and the
watch (`G7WatchSensorAdapter`) use the **same** submodule with **no platform
conditionals** in the BLE state machine. Two consequences:

- **North star = iPhone behavior.** The iPhone G7 path is reliable in production.
  Diverge from it on the watch only with a specific, justified reason, and say why
  in the commit/plan. Notably: the iPhone app has **no connect timeout** and relies
  on CoreBluetooth's own retry — do **not** add a watch-only connect timeout, and do
  **not** change `scanAfterDelay` (the delayed-rescan path), which is intended shared
  behavior. Prefer fixes that make the watch match the iPhone (e.g. seeding
  `G7Sensor(sensorID:)` from persisted identity, deduping redundant connects).
- **Submodule change procedure — use `scripts/repin-g7.sh`.** Trio's build
  **clones G7SensorKit from GitHub** (the `cachrisman` fork), it is not built from
  a local tree. So a fork edit only reaches a build after the fork commit is pushed
  **and** patch 02 is repinned to the new SHA. **Do this with the script, never by
  hand-editing patch 02** (the SHA lives in two places that must agree — the
  `+Subproject commit` line and the `index ..` after-abbrev — and hand-editing a
  patch is forbidden by the patch rules):
  1. Commit your change in the **standalone** G7SensorKit clone
     (`~/Code/personal/health/diabetes/G7SensorKit`, on `main`) — never in the
     submodule checkout inside Trio/Trio-dev.
  2. From `Trio-dev`: `./scripts/repin-g7.sh`. It pushes the fork, asserts the new
     SHA is on origin, rewrites both SHA sites in patch 02, runs `patch-test.sh`,
     and prints the diff. It does **not** commit — review the diff, then commit
     patch 02. Use `--dry-run` to preview; `--allow-dirty-patch` if patch 02
     already has uncommitted repin rounds.
  3. Build (dev + patches). An un-pushed fork commit or un-bumped patch 02 means the
     build silently uses the **old** G7SensorKit — `repin-g7.sh` guards against
     both (it refuses to pin a SHA that isn't on origin).

## Watch app Info.plist (generated + merged) — regression guard

The `Trio Watch App` target uses `GENERATE_INFOPLIST_FILE = YES`. Custom keys
(e.g. `WKBackgroundModes`, `UIBackgroundModes`, `AppGroupID`) live in the on-disk
`Trio Watch App/Info.plist` and are **merged** into the generated plist via
`INFOPLIST_FILE`. `INFOPLIST_KEY_*` build settings are **unreliable for array keys**
(WKBackgroundModes etc.) — keep array keys in the on-disk plist, not in
`sync_project_files_config.rb`.

- **`WKBackgroundModes` is load-bearing for the watch G7 observer.** Without the
  relevant value (`physical-therapy`), every `WKExtendedRuntimeSession.start()`
  immediately invalidates before `didStart`, so the direct-BLE observer never holds
  a runtime session. A missing entry manifests downstream as a *connect storm*,
  `configuration_failed`, and churning sensor UUIDs — symptoms, not the cause.
- **Regression guard:** when regenerating the watch feature patch (patch `12`),
  the regen scope **MUST include `Trio Watch App/Info.plist`**. Build 203 broke
  because the keys lived only in the *old* direct-BLE patch (`11-...patch`, now
  `.skipped`); when the feature migrated to the active patch `12`, the Info.plist
  hunk was not carried over, so the built watch app had no `WKBackgroundModes`
  even though the branch source file did. Verify the key is present in the *built*
  app's Info.plist, not just the on-disk merge file or the feature branch.

## Upstream sync (local)

```bash
git remote add upstream https://github.com/nightscout/Trio.git   # if not present
git checkout dev
git fetch upstream
git merge upstream/dev
git push origin dev
```

After syncing, re-run the patch validation.

## Optional: convert git-apply patch to git-am mailbox patch (provenance)

## Reporting template

- Goal
- Changes made (file-by-file)
- Commands run
- Result
- If failure: top error excerpt + likely cause + next step
- If success: next step (patch gen, patch validation, build)

---

## Better Stack MCP Usage

**Read first:** `docs/process/betterstack-guide.md` — comprehensive guide covering metrics extraction API, dashboard import/export, MCP tool capabilities and limitations, and query patterns.

Agents use the Better Stack MCP server (`user-better-stack`) to query Trio and Nightscout logs via ClickHouse SQL. For direct REST API calls (metrics creation, dashboard import), the API token is stored in `.trio-env` as `BETTERSTACK_API_TOKEN`. The same token is configured in Cursor’s MCP settings. If `telemetry_list_teams_tool` returns "No teams available" or `telemetry_query` returns 401 / "Failed to obtain ClickHouse credentials", the token is missing or invalid — the user must add or refresh it in the Better Stack MCP config and/or `.trio-env`. See [Better Stack API token docs](https://betterstack.com/docs/logs/api/getting-started/#obtaining-a-logtail-api-token).

**Never log, echo, persist, or summarize credentials** returned by `telemetry_create_cloud_connection_tool` or from `.trio-env`.

### How agents should search logs (do this every time)

1. **Create cloud connection (use defaults first)**  
   Call `telemetry_create_cloud_connection_tool` with **team_id `491594`** and **source_id `1659391`** (Trio) unless you need Nightscout logs, in which case use source_id `1659378`.  
   This must run before any query; it establishes the session. Do not echo or store the credentials in the response.  
   **If this fails** (e.g. "No team found", 401): then call `telemetry_list_teams_tool` with `{}`, note the team ID from the response, call `telemetry_list_sources_tool` with `{"team_id": <that_id>}`, note the source_id for Trio or Nightscout, and retry create_cloud_connection with those IDs.

2. **Run queries**  
   `telemetry_query` with three arguments:
   - **query**: ClickHouse SQL string (see query format below).
   - **table**: For Trio use `t491594.trio`; for Nightscout use `t491594.nightscout_chrisman_io`. If you had to discover team/source in step 1, use `t<team_id>.<source_slug>` (slug from source name: lowercase, underscores for spaces).
   - **source_id**: For Trio use `1659391`; for Nightscout use `1659378`. If you had to discover IDs in step 1, use the source_id from list_sources.

3. **Optional: schema / query help**  
   `telemetry_get_query_instructions_tool` with `{"id": <source_id>, "source_type": "logs"}` returns collection names, `raw` JSON fields, and example SQL. Use `1659391` for Trio (or the source_id you discovered).

### Query format (Trio logs)

- **ClickHouse CTE syntax**: `WITH alias AS (expr)` does **not** work in this ClickHouse version for scalar expressions. Either inline expressions directly in the SELECT, or use a subquery to define aliases: `SELECT extract(msg, ...) FROM (SELECT dt, JSONExtract(raw, 'message', 'Nullable(String)') AS msg FROM ...) WHERE ...`. This avoids repeated `JSONExtract` calls while keeping the query valid.

- **Hot buffer vs full history**: `remote(t491594_trio_logs)` holds only the **last ~30–40 minutes** of data (hot tier). Querying e.g. “last 40 HOUR” with only `FROM remote(...)` will return only that recent slice, not 40 hours. For **yesterday and today** or any real historical window, include S3:  
  `FROM remote(t491594_trio_logs) WHERE dt >= ... AND dt < ... UNION ALL SELECT ... FROM s3Cluster(primary, t491594_trio_s3) WHERE _row_type = 1 AND dt >= ... AND dt < ...`  
  (same time bounds in both branches). Use `t<team_id>_trio_logs` / `t<team_id>_trio_s3` if you discovered a different team_id.
- **Recent data (hot only)**: For the last few minutes to ~1 hour, `FROM remote(t491594_trio_logs)` with `WHERE dt > now() - INTERVAL N HOUR` (e.g. 1, 6). If you had to discover team_id, use `t<team_id>_trio_logs`.
- **Message / category**: Stored in the `raw` JSON column. Use `JSONExtract(raw, 'message', 'Nullable(String)')`, `JSONExtract(raw, 'category', 'Nullable(String)')`, etc.
- **High-volume patterns**: Column `_pattern` groups similar lines. Use `GROUP BY _pattern ORDER BY count(*) DESC` to find dominant patterns.
- **Always**: Use a time bound (e.g. `INTERVAL 18 HOUR`) and a reasonable `LIMIT` to avoid oversized results.

### Attributing events to build and platform (iPhone vs watch)

The Trio source mixes **iPhone and watch** telemetry in one table. Several G7/BLE
event strings (e.g. `connect_called`, `did_connect`) are emitted by the **shared**
G7SensorKit on **both** platforms, so a raw count conflates them. To attribute
correctly:

- **Build:** `JSONExtract(raw, 'build', 'Nullable(String)')` (the build number, e.g. `203`).
- **Platform:** `JSONExtract(raw, 'platform', 'Nullable(String)')` — values are
  `ios` and `watchos`. **Always `GROUP BY build, platform`** when investigating G7/BLE
  behavior; a watch-only regression is invisible if iPhone events are summed in.
  (Real example: build 203's "connect storm" was `platform=watchos` only — the
  `connect_called` volume that looked alarming in aggregate was mostly `platform=ios`
  from the reliable iPhone path.)
- **Event matching:** match structured event strings with `position(raw, '...') > 0`
  (substring presence), not a `module=`/`category=` filter — the module prefix has
  changed across builds (e.g. `event=g7_ble_ios` → `module=g7_core`) and an
  over-specific filter silently returns zero rows.
- **Historical window needs S3:** `remote(t491594_trio_logs)` is hot-tier only
  (~30–40 min). For yesterday/today or any real window, `UNION ALL` with
  `s3Cluster(primary, t491594_trio_s3) WHERE _row_type = 1` (same time bounds in both
  branches). `_row_type = 1` is **required** on the s3Cluster branch.

### Example queries (Trio, last 18h)

Use with `table: "t491594.trio"` and `source_id: 1659391` (replace with your team/source if different):

- **Volume**: `SELECT count(*) AS events_18h, sum(length(raw)) AS bytes_18h FROM remote(t491594_trio_logs) WHERE dt > now() - INTERVAL 18 HOUR`
- **PersistedProperty count (expect 0 after filter)**: `SELECT count(*) FROM remote(t491594_trio_logs) WHERE dt > now() - INTERVAL 18 HOUR AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%[PersistedProperty:%' AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%Saved value successfully%'`
- **Watch received data (check trim)**: `SELECT length(JSONExtract(raw, 'message', 'Nullable(String)')) AS len, JSONExtract(raw, 'message', 'Nullable(String)') AS msg FROM remote(t491594_trio_logs) WHERE dt > now() - INTERVAL 18 HOUR AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%Watch received data%' ORDER BY len DESC LIMIT 5`
- **Top patterns**: `SELECT _pattern, count(*) AS cnt FROM remote(t491594_trio_logs) WHERE dt > now() - INTERVAL 18 HOUR GROUP BY _pattern ORDER BY cnt DESC LIMIT 20`

### Suggested asks (natural language)

- "Show errors and warnings from Trio in the last 6 hours."
- "List Nightscout anomalies or ingestion issues in the last 24 hours."
- "Were there any data gaps or missing entries longer than 20 minutes in the last day?"
- "Summarize repeated warnings or unusual patterns since midnight."

### Interpretation & summarization

- Summarize in plain language before citing timestamps or log excerpts.
- State when no relevant events are found for the time window.
- Prefer concise summaries over raw dumps unless the user asks for details.

---

## Diabetes & Nightscout Safety Guardrails

- Treat all Nightscout and Trio data as **observational telemetry**, not medical guidance.
- Do not infer intent, causality, or clinical meaning beyond what is directly supported by logs.
- When summarizing BG-related events, use neutral phrasing such as:
  - "A rapid rise was observed"
  - "Data indicates a gap or ingestion delay"
  - "No anomalies were detected in the logs"

**Goal:** Help the user quickly answer "what happened?" by turning Better Stack logs into clear, time-scoped, non-speculative summaries while maintaining strict safety and privacy boundaries.

---

## Changelog

### v19 (2026-06-22 CET)
- **Patch/build tooling hardening.** Cherry-pick gate: `mid-stack-update.sh` (v1.11) now **enforces** the cherry-pick-vs-`--from-feature-branch` choice — `--from-feature-branch` is refused when recorded provenance shows cherry-pick applies cleanly (or when the patch has no provenance), and allowed automatically only when history has genuinely diverged; override with the audited `--force-from-feature-branch "<reason>"`. New **`scripts/repin-g7.sh`** automates the G7SensorKit fork push + patch-02 SHA repin (both SHA sites, validated by `patch-test.sh`) so patch 02 is never hand-edited. `ci/local-build.sh`: derives the submodule-change list from `.gitmodules` (was a drifting hardcoded list that omitted OmnipodKit/MedtrumKit); **preserves the worktree on a failed build** by default for investigation (`--no-preserve-on-error` to opt out). New **`scripts/cleanup-build-leftovers.sh`** prunes stale build worktrees/logs/`ci-build/*` remote branches (dry-run by default; remote deletion opt-in); invoked logs-only after a successful deploy. Design/decision log: `docs/in-progress/patch-build-tooling-hardening/01-design.md`.

### v18 (2026-06-18 CET)
- **Patch clobber guardrails (Model B):** New **safety rule 12** — the deletion-footprint audit (`scripts/patch-audit.sh`, run by `patch-test.sh`) is mandatory; agents must never edit `scripts/patch-audit.safety-paths` / `.waivers`; a safety-path FAIL or missing sentinel symbol is a hard STOP. Amended **rule 10** (a passing compile/archive does not prove behavior preserved). Expanded the **`git am --3way`** section (conflict-free apply ≠ verification; review the full diff vs base, deletions especially; footprint must match patch purpose). Annotated the authoritative validate-stack command. Distilled from the 2026-06 incident where patch 13 silently deleted the Omnipod migration fallback from `DeviceDataManager.swift` and dropped a live insulin pod. Full design/decision log: `docs/process/patch-clobber-guardrails.md`. Also fixed `ci/local-build.sh` false-success exit-code bugs (failed fastlane build/release now exits non-zero; missing IPA is fatal).

### v17 (2026-06-07 CET)
- **Patch provenance + deterministic cherry-pick:** patches carry `Trio-Patch-Source-*` trailers (branch/base/tip + per-commit SHA & `patch-id`); `mid-stack-update.sh` computes the exact new-commit set by patch-id (rebase-stable), auto-resolves the feature branch from the trailer, and runs with no flags. See the Pre-flight section.
- **Fail-closed drift + auto-include + orphans:** dropped files abort with the exact `--extra-files`; brand-new files auto-include; sibling ownership is snapshotted pre-stash; orphan files from abandoned patches use `--drift-exclude-regex`; new `--exclude-from-stash` for iterating on the tooling scripts. See "Patches that ADD new files".

### v16 (2026-06-07 CET)
- **Verification discipline:** New section — verify OS/SDK enum raw values against the SDK header before acting (the `WKExtendedRuntimeSessionState(rawValue: 2)` = `.running`, not `.invalid`, miss), prefer mapped names over `String(describing:)` of imported `NS_ENUM`s, doubt the hypothesis when data contradicts it, and don't propagate unverified interpretations across subagents. Distilled from the build 206 watch-G7 BLE work.
- **Patches that ADD new files:** mid-stack section now documents that new files must be passed via `--extra-files` (else silently dropped under `--from-feature-branch`); the `Files in patch: N` drop is the red flag; synchronized-group files fail only at build time as `cannot find <Type> in scope`.
- **Local build environment gotchas:** New section — UTF-8 locale required for fastlane/gym (now defaulted in `local-build.sh`); local network filters (Little Snitch) can block TestFlight/`match` via unsigned `ruby` (don't infer connectivity from `curl`); full-deploy vs `--build-only`.

### v15 (2026-05-31 CET)
- **How a change reaches a build (mental model):** New section making explicit that a build is `dev` + the patch stack, that feature-branch commits don't ship until folded into a patch, the `origin/ci-build/trio-vX.Y.Z-NNN-local-*` build→branch mapping, and that cross-build regressions are usually patch-scope changes (diff patches, not just source). Distilled from the build 203 watch-G7 BLE investigation.
- **Shared submodules and the iPhone north star (G7SensorKit):** New section — G7SensorKit is shared by iPhone and watch with no platform conditionals; iPhone behavior is the north star (no watch-only connect timeout, don't touch `scanAfterDelay`); documents the 3-step submodule change procedure (commit+push fork → repin patch 02 SHA → build) and that an un-pushed/un-bumped change silently uses the old framework.
- **Watch app Info.plist regression guard:** New section — generated-plist + `INFOPLIST_FILE` merge mechanism, `INFOPLIST_KEY_*` unreliable for array keys, `WKBackgroundModes` is load-bearing for `WKExtendedRuntimeSession`, and patch 12 regen scope MUST include `Trio Watch App/Info.plist` (the exact build 203 regression).
- **Telemetry: build/platform attribution:** New "Attributing events to build and platform" subsection under Better Stack query format — `JSONExtract(raw,'build'|'platform',...)` (`ios`/`watchos`), always `GROUP BY build, platform` for shared G7/BLE events, match events via `position(raw,'...')>0` rather than module/category filters (prefix drifts across builds), and `_row_type = 1` required on the `s3Cluster` historical branch.

### v14 (2026-04-08 12:21 CET)
- **Xcode project file modification:** New safety rule **6** — agents must not edit `Trio.xcodeproj/project.pbxproj` or run `scripts/sync_project_files.rb` directly or indirectly from an agent session. Canonical project refresh occurs only through the normal build/sync workflow; agents must not force project regeneration.

### v13 (2026-04-03 22:49 CET)
- **Agent verification vs. compilation:** New safety rule **10** — do not run `xcodebuild` or other Xcode CLI builds to verify ordinary implementation work; do not start `ci/local-build.sh` as a routine post-change compile check. Verification is static review, `scripts/patch-test.sh` when applicable, and tests that do not require a full Xcode build; direct users to `local-build.sh` for compile confirmation. **Agent sandbox notes** updated to reinforce this (builds only when the user requested a build).

### v12 (2026-03-20)
- **`mid-stack-update.sh` v1.7 — auto-restore and auto-detect:** Updated "Dirty patch file" bullet — script now auto-restores the committed version of modified target patches (no manual `git checkout --` needed). Updated "Pre-flight" section — script now auto-detects cherry-pick candidates when `--cherry-pick` is omitted, printing all feature branch commits since merge-base with a suggested command. Updated dirty-patch precondition note in "Patch commit lifecycle" to reflect the automation.
- **`local-build.sh` upstream sync now built-in:** Replaced manual "Check for upstream updates" pre-build step with "Upstream sync (automatic)" noting the script handles fetch/merge/push for `--base-branch dev` by default. Documented `--sync-upstream` / `--no-sync-upstream` flags. Source patch hashes are now logged before worktree setup.
- **Bash 3.2 empty-array safety:** `mid-stack-update.sh` and `generate-patch.sh` fixed to use `${arr[@]+"${arr[@]}"}` pattern for empty arrays under `set -u` (8 sites total).

### v11 (2026-03-20)
- **Dirty target patch workflow:** Expanded the "Dirty patch file" bullet under mid-stack updates with a concrete 3-step workflow: restore committed version, move untracked aside, then `--cherry-pick` all new commits. Explicitly warns against using `--from-feature-branch` for stale committed versions.
- **`--cherry-pick` vs `--from-feature-branch` decision tree:** New table and quick-test heuristic for choosing the correct mid-stack-update mode. `--cherry-pick` is the default ~95% of the time; `--from-feature-branch` only when commit history has diverged (rebase/amend/force-push).
- **Pre-build upstream sync:** New step 1 in "When the user instructs a build" — fetch `upstream/dev` and merge if ahead, unless user declines. Ensures builds test against the latest upstream state.
- **Ask for build flags:** "When the user instructs a build" now starts with "Ask the user for build flags" (step 2) instead of assuming `--build-only`. Safety rule 1 updated to match — agents ask for flags rather than defaulting to `--build-only`.
- **Cross-patch type shadowing check:** New self-review step (7) for cross-patch type dependencies. Documents the `NotificationCenter` protocol shadowing issue in this codebase and instructs agents to use fully qualified names when referencing Foundation types that have in-scope shadows.
- **Untracked patch stash-pop conflicts:** New bullet in "Untracked files and clean/reset" documenting the pattern of moving untracked patch files to `/tmp/` before stashing to prevent stash-pop conflicts after regeneration.

### v10 (2026-03-20)
- **Patch commit lifecycle:** New section. Regenerated/new patches remain uncommitted on `dev` during development. The commit to `dev` is the "milestone complete" step — only after build, deploy, and BetterStack verification, and only when the user explicitly requests it. Agents must ask before committing patches to satisfy tooling preconditions.
- **Generate a NEW patch with overlapping files:** New subsection under "Generate a NEW patch" documenting the correct workflow when the new patch modifies files also changed by earlier patches: rebase the feature branch onto the highest overlapping feature branch, build a tmp baseline (dev + prior patches), and use `generate-patch.sh` with `-t tmp/baseline` directly. Avoids the placeholder + mid-stack-update workaround.
- **Dirty-patch guidance softened:** The `mid-stack-update.sh` dirty-patch bullet now references the patch lifecycle rule and instructs agents to ask the user before committing, rather than reflexively committing.

### v9 (2026-03-14)
- **Mid-stack cherry-pick pre-flight:** Added mandatory pre-flight step to "Update an existing patch (mid-stack)" — before running `--cherry-pick`, enumerate ALL new commits on the feature branch not yet in the patch and include them all, earliest first. Prevents the common mistake of cherry-picking only a fix commit while forgetting the feature commit it modifies.
- **Build-fix workflow references `mid-stack-update.sh`:** Updated "If an error is detected" (section 4) to reference `mid-stack-update.sh --cherry-pick` instead of `generate-patch.sh`, and explicitly warns that the fix commit is rarely the only new commit.
- **`--from-feature-branch` gated as last resort:** Added explicit warning that `--from-feature-branch` must only be used when the baseline has actually diverged (merge/rebase/amend), not as a workaround for cherry-pick conflicts caused by missing intermediate commits.

### v8 (2026-03-12)
- **Docs on `dev`; docs branch removed:** Plan/design docs and prompts now live in `docs/` on the `dev` branch and are committed with completed patch work. Removed the dedicated "Tracking plan and design docs (dedicated `docs` branch)" section and replaced it with "Tracking docs on `dev`" and rules of thumb (WIP uncommitted OK; commit docs with patch at completion; docs reflect reality at completion).
- **Doc paths updated:** "Read first" and all cross-references now point to `docs/process/feature-branch-workflow-optimization.md`, `docs/completed/feature-branch-workflow-optimization-patch-migration.md`, and `docs/process/betterstack-guide.md`. Mid-stack bullet in "Untracked files and clean / reset" updated to reference the process path.
- **Untracked-files example:** Example untracked path updated to `docs/in-progress/<initiative>/02-implementation-plan.md` to align with current docs layout (see `docs/README.md`).

### v7 (2026-03-12)
- **`mid-stack-update.sh` v1.5 — `--from-feature-branch`:** When the patch baseline and feature branch have diverged (e.g. merge into feature, then amend), use `--from-feature-branch` with `--feature-branch` to regenerate the patch from the current feature branch state instead of apply + cherry-pick. Documented in "Update an existing patch (mid-stack)" and script help.

### v6 (2026-03-10)
- **Cherry-pick conflict diagnosis:** Expanded the cherry-pick conflict bullet under "Update an existing patch (mid-stack)" from a one-liner ("resolve on the feature branch") to a 3-step diagnostic procedure. Root cause is almost always missing intermediate commits — commits on the feature branch that were never cherry-picked into the patch, causing context-line mismatches. Agents must diagnose the divergence and include missing commits in `--cherry-pick`, not fall back to manual workarounds.

### v5 (2026-03-08)
- **`mid-stack-update.sh` is now MANDATORY** for all mid-stack patch updates. Changed from "PREFERRED" to "MANDATORY" with explicit instruction to fix the script (not fall back to manual) if it fails. Added common failure causes and fixes inline.
- **Bash 3.2 compatibility fix** in `mid-stack-update.sh` v1.3: replaced `declare -A` (bash 4+ associative arrays) with string-based seen list for macOS compatibility.

### v4 (2026-03-08)
- **`mid-stack-update.sh` v1.2:** Updated safety feature list — drift check now uses three-dot diff (`dev...feature`) for accurate merge-base comparison, missing-files check excludes files belonging to any patch in the stack (not just prior patches), cherry-pick conflicts are explicitly aborted at the failure site before cleanup, stash pop failures report the exact stash ref for manual resolution.

### v3 (2026-03-08)
- **`mid-stack-update.sh` as preferred mid-stack workflow:** Replaced ambiguous "Generate a patch / Update an existing patch" sections with split "Generate a NEW patch" and "Update an existing patch (mid-stack) — PREFERRED" entries. The latter documents `mid-stack-update.sh` and its safety features (dirty-patch refusal, abort-before-checkout, worktree branch detection, drift check, tmp branch preservation).
- **Removed manual `git format-patch` example** from Common workflows — the scripts should always be used instead.

### v2 (2026-03-07)
- **Checkout conflict (untracked files):** Added warning to "Tracking plan and design docs" section — when `git checkout docs` fails due to untracked plan docs on `dev`, delete the untracked copies first; do not edit plan docs while on `dev`.
- **Update an existing patch (mid-stack):** Added to "Common workflows" with explicit warning against using `generate-patch.sh -s feature/<name> -t dev` for mid-stack updates (includes all preceding patches' diffs). Must use `tmp/` baseline branches.
- **ClickHouse CTE syntax:** Added note to "Query format (Trio logs)" — `WITH alias AS (expr)` does not work; use subqueries or inline expressions.

### v1
- Initial version (no changelog tracked).
