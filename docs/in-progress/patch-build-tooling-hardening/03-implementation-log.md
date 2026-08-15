# Patch & build tooling hardening — implementation log

**Version:** v1.3
**Status:** In review (changes A–F + post-review fixes landed; ready to commit)
**Date:** 2026-06-22

Records what was actually built for this initiative (design: `01-design.md`),
the validation performed, and the external-review cycle.

## Scope delivered (changes A–F)

### A. Cherry-pick-viability gate — `scripts/mid-stack-update.sh` (→ v1.11)
- New flag `--force-from-feature-branch "<reason>"` (implies `--from-feature-branch`;
  requires a non-empty reason; reason echoed to the run log for audit).
- New gate block: when `--from-feature-branch` is used without the force flag, the
  script reconciles the patch's recorded patch-id provenance against the resolved
  feature branch and:
  - **refuses** when history is aligned and cherry-pick applies cleanly (prints the
    computed `--cherry-pick <shas>` command);
  - **refuses** when the patch has no recorded provenance to verify;
  - **allows** automatically only when a recorded commit is no longer present on the
    branch by patch-id (genuine rebase/squash/amend divergence).
- Reuses existing helpers `_recorded_patch_ids` / `_patch_id` (no refactor of the
  proven deferred-detection block).
- Help text + top-of-file changelog updated.

### B. `scripts/repin-g7.sh` (new)
- Pushes the standalone G7SensorKit clone's committed HEAD to the `cachrisman`
  fork, asserts the new SHA is on origin, then rewrites **both** SHA sites in
  `patches/02-g7-reading-time-with-seconds.patch` (the `+Subproject commit` line and
  the `index ..` after-abbrev), runs `patch-test.sh`, prints the diff, and does NOT
  commit.
- Guards: origin-is-fork check, patch `.gitmodules` fork-URL cross-check, no-op when
  already pinned, `--allow-dirty-patch` (warn-and-proceed, not refuse) for the
  multi-round case, `--dry-run`, `--skip-test`.
- Writes its temp beside the patch (no `mktemp`) so it runs without disabling the
  harness sandbox.

### C. Submodule-list derivation — `ci/local-build.sh`
- Replaced the hardcoded `G7SensorKit|CGMBLEKit|DanaKit|OmniKit|OmniBLE|...`
  alternation (which had drifted — listed removed OmniKit/OmniBLE, omitted real
  OmnipodKit/MedtrumKit) with a list derived at runtime from `.gitmodules`
  (`git config -f .gitmodules --get-regexp '^submodule\..*\.path$'`), matched via
  `grep -qxF -f`.

### D. Preserve worktree on error — `ci/local-build.sh`
- New default `NO_PRESERVE_ON_ERROR=0` + flag `--no-preserve-on-error` + usage line.
- `cleanup()` now keeps the worktree on any non-zero exit (prints the path + a
  removal/cleanup hint) unless `--no-preserve-on-error`. Explicit `--preserve-worktree`
  and the record-release-retry path still force-keep. Pre-build failures never reach
  this code (no worktree yet), so they still clean up.

### E. `scripts/cleanup-build-leftovers.sh` (new) + deploy-tail hook
- Dry-run by default (`--apply` to delete). Prunes build worktrees (keep newest
  `--keep-worktrees`, default 3), build logs (keep newest `--keep-logs`, default 10),
  and remote `ci-build/*` branches older than `--branch-age-days` (default 7).
- Remote branch deletion is **opt-in** (`--prune-remote-branches`) — outward-facing,
  hard to reverse; otherwise candidates are only listed.
- `--skip-worktrees` / `--skip-logs` / `--skip-branches` for partial runs.
- `ci/local-build.sh` invokes it **logs-only** (`--apply --skip-worktrees
  --skip-branches`, non-fatal) after a successful full deploy. Never on failure (so a
  preserved-on-error worktree survives).
- bash-3.2 safe (no `mapfile`).

### F. Docs
- `AGENTS.md` → v19: rewrote "Choosing `--cherry-pick` vs `--from-feature-branch`"
  to document the enforced gate + `--force-from-feature-branch`; rewrote the
  G7SensorKit submodule procedure to mandate `repin-g7.sh`; added preserved-worktree
  guidance to the build-error step; changelog entry.
- `docs/process/feature-branch-workflow-optimization.md` → v17: gate subsection +
  new "Re-pinning the G7SensorKit submodule" and "Cleaning up build leftovers"
  sections; changelog entry.

## Validation performed (repo discipline: builds are NOT verification)
- `bash -n` + `shellcheck` clean on all four scripts
  (`mid-stack-update.sh`, `repin-g7.sh`, `cleanup-build-leftovers.sh`,
  `ci/local-build.sh`). No new shellcheck warnings (the 5 in `mid-stack-update.sh`
  are pre-existing, outside the new block).
- Cherry-pick gate, all four verdict paths exercised in `--dry-run`:
  aligned/up-to-date exit (patch 01); empty-reason rejection; force-bypass with audit
  line then proceed; no-provenance refusal (patch 03).
- `repin-g7.sh`: validation + no-op path against real state (clone HEAD already
  pinned); synthetic awk-rewrite test (both SHA sites updated; base side and
  `.gitmodules` fork URL untouched).
- Submodule derivation: produces all 11 real submodule paths; flags a simulated
  OmnipodKit repin the old hardcoded list would have missed; no false positive on a
  source-only change.
- `cleanup-build-leftovers.sh`: dry-run verified (49 logs → prune 39 keep 10, oldest
  first; 1 worktree present, under keep-3 so retained; remote branch candidates
  listed, not deleted without the opt-in flag).
- `patch-test.sh` (incl. `patch-audit.sh`): **PASS, exit 0**, sentinel symbols intact,
  36 pre-existing informational deletion warnings (no safety-path FAIL).

## External review cycle

### gemini-task — BLOCKED (backend unavailable)
- `gemini-task` (the `agy` / Antigravity CLI reviewer) returned empty output for
  every file; direct `agy --print` probes returned len-0 / exit-0 across all models
  (global quota-lockout / session-auth state). No findings collected via this tool.
- Sandbox note: `gemini-task` writes a lock under `~/.gemini/antigravity-cli/`, which
  the harness FS sandbox blocks; run it with the sandbox disabled.

### cursor-task — COMPLETED
Reviewed the four changed code files via `cursor-task review <file>` (Cursor cloud
backend; one focused review per file). Notes saved under `.claude/ollama-notes/`.
Findings below are triaged; **nothing applied yet** (pending user go-ahead).

**Verified FALSE POSITIVE (no action):**
- *cleanup-build-leftovers.sh "High": `${arr[@]:0:N}` is bash 4+.* Wrong — tested
  directly on `/bin/bash` 3.2.57 (arm64), the slice works (exit 0). Array
  offset/length slicing has been in bash since 3.0. No change needed.

**Recommended fixes (genuine), prioritized:**
- **P1 — Gate wrong-branch false-divergence (`mid-stack-update.sh`, High).** The gate
  allows `--from-feature-branch` whenever `_missing > 0`, but a *wrong* resolved
  branch (typo, stale `feature/$PATCH_DESC`, unrelated branch) makes *all* recorded
  patch-ids look missing → mis-allowed FFB — the exact failure the gate prevents.
  Fix: allow only on **partial** overlap (≥1 recorded id present AND ≥1 missing);
  **zero overlap → refuse** (wrong branch / no shared history → require force). This
  also subsumes the "patch-id extraction failed → mis-allow" Medium.
- **P2 — `--force-from-feature-branch` swallows a flag as its reason
  (`mid-stack-update.sh`, Medium).** `--force-from-feature-branch --dry-run` sets the
  reason to `--dry-run` and bypasses the gate. Fix: reject a reason that is empty or
  begins with `--`.
- **P2 — repin-g7 dirty-patch guard misses staged edits (Medium).** `git diff
  --quiet -- "$PATCH_FILE"` ignores staged-only changes. Fix: `git diff --quiet HEAD
  -- "$PATCH_FILE"`.
- **P2 — repin-g7 leaves patch 02 modified if `patch-test.sh` fails after rewrite
  (Medium).** Fix: back up the original patch text, restore it on a patch-test
  failure (trap), so a failed validation doesn't leave a half-applied repin.
- **P2 — cleanup-build-leftovers.sh: no `rm -rf` fallback when `git worktree remove`
  fails (Medium; also hit live during the housekeeping run).** Mirror
  `ci/local-build.sh` cleanup(): on failure, `rm -rf` the dir then `git worktree
  prune`.
- **P2 — preserve-on-error hint can nuke other investigation worktrees
  (`ci/local-build.sh`, Low).** The printed hint `cleanup-build-leftovers.sh --apply`
  (line ~982) omits `--skip-worktrees`, so following it could prune *other* preserved
  failure worktrees (keep-3 default). Fix: add `--skip-worktrees` to the hint.

**Consider (lower priority / judgment):**
- **Remote branch age uses commit date, not push timestamp (cleanup, High-rated).**
  `ci-build/<tag>-<ts>` branches point at possibly-old fork SHAs, so `committerdate`
  can be far older than the branch → premature candidates. Deletion is opt-in +
  dry-run-previewed, so low risk; a correctness fix parses the embedded
  `YYYYMMDDTHHMMSSZ` suffix for age.
- **Gate reads working-tree patch before v1.7 dirty auto-restore (Medium).** Uncommitted
  provenance edits could skew the gate verdict vs what the run actually uses. Pre-existing
  ordering quirk shared with the deferred-detection preflight.
- **repin-g7 no-op exit doesn't re-sync a stale `index ..` abbrev (High-rated).** Only
  reachable via a prior hand-edit (which the script exists to prevent); low real risk.
- **Deploy-tail log prune doesn't run on `--release-only` (local-build, Medium).**
  Confirmed: `--release-only` exits at line 753, before the hook at 1549. Logs
  accumulate on that path until a full deploy or manual cleanup.
- **Numeric-flag validation in cleanup-build-leftovers.sh (Medium);** dry-run still
  runs `git fetch --prune` (Medium, minor side-effect).

**Acceptable by design (won't fix):** substring fork-identity match; `git push`
without interactive confirm; `--skip-test` foot-gun (documented);
`feature/$PATCH_DESC` resolution precedence (pre-existing, matches preflight);
"success" tail on record-release failure (pre-existing exit-0 pattern).

### Fixes applied (post-review, 2026-06-22)
Applied P1 + all five P2s, plus three of the "consider" items (cheap correctness in
destructive paths). Deferred two as documented.

- **P1 (applied):** gate now counts how many recorded patch-ids are *present* on the
  resolved branch. `present==0` → **refuse** (wrong branch / full-squash ambiguity →
  require `--force`); `0<present<total` → diverged → allow; `present==total` → aligned
  → refuse with cherry-pick suggestion. Verified: zero-overlap branches
  (`feature/patch-metadata`, `feature/temp-target-default-tab`) now refuse; partial
  overlap allows; aligned/up-to-date unchanged.
  - *Residual limitation (documented, not a regression):* a branch that coincidentally
    shares ≥1 patch-id with the patch is classified diverged→allow even if otherwise
    wrong. Far narrower than the old "any-missing→allow", and dry-run prints
    "N of M recorded still on \<branch>" so a human can spot it. A genuine *full*
    squash also lands in zero-overlap and now needs `--force "<reason>"` — the correct
    safe default for that ambiguous case.
- **P2 (applied):** flag-shaped `--force-from-feature-branch` reason rejected;
  repin-g7 dirty guard uses `git diff HEAD`; repin-g7 restores patch 02 via EXIT trap
  if the rewrite/patch-test fails; cleanup-build-leftovers.sh `rm -rf` fallback on
  failed `git worktree remove`; preserve-on-error hint reworded (removes THIS worktree
  precisely; warns that bare bulk `--apply` can prune others).
- **Consider → applied:** remote-branch age now parsed from the embedded
  `YYYYMMDDTHHMMSSZ` push timestamp (fallback to committerdate); numeric-flag
  validation in cleanup-build-leftovers.sh; `--release-only` now runs the logs-only
  deploy-tail prune.
- **Consider → deferred (documented):** gate reads working-tree patch before v1.7
  dirty auto-restore (pre-existing ordering, shared with preflight; higher-risk to
  reorder); repin-g7 no-op doesn't re-sync a stale `index ..` abbrev (only reachable
  via a prior hand-edit the script exists to prevent); dry-run still runs
  `git fetch --prune` for the branch section (needed for accurate ages; benign).
- **Validation:** all four scripts `bash -n` + `shellcheck` clean; gate paths
  re-exercised in dry-run (wrong-branch/diverged/aligned/up-to-date/flag-reason/
  valid-force); repin-g7 no-op leaves no temp/backup files; cleanup numeric guard +
  push-timestamp age verified; `patch-test.sh` exit 0.
### Second cursor-task review (post-fix) + final refinements
All four files re-reviewed via `cursor-task`. **No Critical/High remained** in any
file; reviewers validated the P1 three-state logic in a truth table (no off-by-one)
and confirmed each P2 fix correct. A handful of small post-fix edge cases were
surfaced and applied in a final batch (verified directly, no third review round):

- **cleanup-build-leftovers.sh:** leading-zero flag values (`08`) normalized with
  `10#` (they passed the digit check but broke `$(( ))` as octal); worktree removal
  now `rm -rf`s whenever the directory *remains* after `git worktree remove` (covers
  the "deregistered but dir left" sandbox half-state, not just outright failure);
  help notes that the branch section runs `git fetch` even in dry-run.
- **repin-g7.sh:** rollback warning now tells the operator to re-run (the fork push
  isn't reverted; repin is idempotent); EXIT trap also clears a leftover `.repin.tmp`;
  soft-warns if the clone isn't on `main`.
- **ci/local-build.sh:** Ruby PATH pin now covers Intel Homebrew
  (`/usr/local/opt/ruby/bin`) as well as Apple Silicon (twice-flagged; this machine
  is arm64 so it was latent, but it's in the same diff).

**Deferred after second review (documented, no action):** gate reads working-tree
patch before v1.7 auto-restore; full-squash zero-overlap now needs `--force` (correct
safe default for the ambiguous case); narrow partial-overlap residual; single-dash
(`-foo`) force-reason accepted (harmless); submodule detection's post-patch
`.gitmodules` dependency (removal/rename edge); `--build-only` doesn't run log cleanup
(intentional asymmetry); conflicting `--preserve-worktree` + `--no-preserve-on-error`
precedence (documented).

**Final validation:** all scripts `bash -n` + `shellcheck` clean; leading-zero flag,
ruby-path loop, and repin no-op re-tested; `patch-test.sh` exit 0; no leftover
temp/backup files.

## Build housekeeping run (2026-06-22)
- Ran `cleanup-build-leftovers.sh --apply --keep-worktrees 0 --skip-branches`
  (scoped to build folder + ci worktrees, per request; remote branches untouched).
- **Logs:** 49 → 10 (`ci-local-build-*.log`), newest retained. ✓
- **Worktree:** the single stale leftover
  `.trio-worktrees/ci-build-20260618-154638` (detached HEAD, build-210 era, dirty
  only with build-applied patch artifacts) was removed; `.trio-worktrees` is now
  empty and `git worktree list` shows only `Trio` + `Trio-dev`. ✓
- **Harness-sandbox note:** under the FS sandbox, `git worktree remove --force`
  deregistered the worktree but could not delete its *directory* (sibling
  `../.trio-worktrees` is outside the sandbox's writable paths → "Operation not
  permitted"); completed the dir removal with the sandbox disabled. Not a script
  bug — but see the finding below.

## Self-review finding (discovered during the housekeeping run)
- **`cleanup-build-leftovers.sh` lacks an `rm -rf` fallback** when
  `git worktree remove --force` fails. It prints `failed:` and leaves the orphaned
  directory behind. `ci/local-build.sh`'s `cleanup()` already handles this
  (falls back to `rm -rf "$WORKTREE_DIR"` then `git worktree prune`). Suggested fix:
  mirror that fallback in the worktree-prune loop (on remove failure, `rm -rf` the
  dir, then `git worktree prune`). **Not applied** — pending the user's go-ahead.
  Severity: low (cosmetic leftover; the next run re-attempts).

## Status / not committed
- All changes are **uncommitted** in the `Trio-dev` worktree on `dev`, pending review
  + explicit commit instruction. `patches/02` and `patches/09` were already modified
  before this work and are untouched by it.

## Changelog
### v1.3 (2026-06-22)
- Applied P1 + all five P2 fixes + three "consider" items; deferred two (documented).
  Second `cursor-task` review of all four files came back with no Critical/High;
  applied a final batch of small edge-case refinements (leading-zero flags, robust
  worktree dir removal, repin rollback hint/tmp cleanup/main-branch warn, Intel Ruby
  path). All scripts lint clean; `patch-test.sh` exit 0.
### v1.2 (2026-06-22)
- Ran the external review via `cursor-task` (gemini-task backend was down). Recorded
  consolidated, triaged findings: 1 verified false positive (bash-3.2 slice), 6
  recommended fixes (1 P1 gate logic gap + 5 P2), and several lower-priority/consider
  items. Nothing applied yet.
### v1.1 (2026-06-22)
- Recorded the build-housekeeping run (logs 49→10; stale worktree removed). Added a
  self-review finding: `cleanup-build-leftovers.sh` should fall back to `rm -rf` when
  `git worktree remove` fails (not yet applied).
### v1.0 (2026-06-22)
- Initial implementation log for changes A–F; external review blocked by agy backend
  outage; build housekeeping pending.
