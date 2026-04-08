# AGENTS.md — v14

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

## Agent sandbox notes

`ci/local-build.sh` requires unrestricted filesystem/process access (it creates worktrees, runs Xcode builds, accesses signing certificates). In sandboxed agent environments (e.g., Cursor), request `all` permissions before running build commands.

**Verification vs. builds:** Even with permissions, **do not** run `xcodebuild` (or ad-hoc scheme builds) to validate edits. Use review + `patch-test.sh` + plan-specified non-Xcode checks. Reserve `ci/local-build.sh` for when the **user** asked you to run a build (see **When the user instructs a build**).

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

Review the candidates. Not all may need cherry-picking — some may already be
in the current patch. Include only commits added since the last patch update,
earliest first. A common mistake is cherry-picking only a fix commit while
forgetting the feature commit it modifies — this guarantees a conflict.

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
  problem and skips the cherry-pick workflow's provenance tracking.

See `./scripts/mid-stack-update.sh -h` for all options.

**Do NOT** manually run `generate-patch.sh -s feature/<name> -t dev` for
mid-stack updates. That compares against raw `dev` and produces a patch
containing ALL differences from every earlier patch — not just the changes
for the patch being updated.

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
