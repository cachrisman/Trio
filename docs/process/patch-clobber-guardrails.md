# Patch clobber guardrails — design & implementation log

**Version:** 1.2 (2026-06-29)
**Status:** Implemented (Model B + `local-build.sh` exit-code fix)
**Owner:** Charlie
**Related:** [feature-branch-workflow-optimization.md](feature-branch-workflow-optimization.md),
[dev-sync-branch-cleanup/00-plan.md](../in-progress/dev-sync-branch-cleanup/00-plan.md)

> This doc exists so a future revisit doesn't require re-investigating from scratch. It records the
> incident, the root cause, **why Model B was chosen over Model A**, the implementation, and how to
> maintain it.

## The incident (2026-06-16/18) — a live insulin pod was dropped

During the upstream sync to 0.8.2.1, patch **13 (`phone-ble-observer-telemetry`)** was found to be
silently deleting load-bearing code from `Trio/Sources/APS/DeviceDataManager.swift`:

- `pumpManagerTypeByIdentifier(_:)`
- the **`managerIdentifier.hasPrefix("Omni")` migration fallback** — routes an old
  `Omnipod`/`Omnipod-DASH` (OmniBLE/OmniKit) pod identifier to the universal `Omni` (OmnipodKit)
  pump manager
- two `OmniPumpManager` reservoir / temp-basal / pod-age blocks

The patch's **only** legitimate change to that file was a one-line doc comment. Everything else was
out-of-scope Omni-removal scope creep carried in the patch's source branch since build 209.

**Why it shipped undetected:**
- The deletions applied via `git am --3way` **without conflict**, so reconciliation reviewed only the
  conflicting hunks and never saw them.
- It **compiled and archived a signed IPA** — deleting `PumpManagerDelegate` method bodies does not
  break compilation. "It built" was meaningless here.
- `local-build.sh` also printed `TOTAL (Success)` on a *failed* archive in a related run (separate
  exit-code bug; see Fixes below), reinforcing false confidence.

**Why it was catastrophic only now (latent landmine):** at build 209 the OmniBLE driver was still
*registered*, so the user's `Omnipod-DASH` pod resolved directly — the missing migration fallback was
never reached. The 0.8.2 sync pulled in upstream's removal of the OmniBLE/OmniKit drivers; the pod
then had **no direct manager AND no migration fallback** (deleted) → silently forgotten. Real-world
cost: a working pod dropped and wasted.

## Root cause

Both validation signals in use — **conflict-free `git am --3way`** and **successful compile/archive**
— are structurally blind to semantic deletions of still-compiling code. `AGENTS.md` rule 10 ("don't
build to verify") already existed and was still violated. **Conclusion: rules alone are weak; the
robust fix is an automated check that surfaces out-of-scope deletions regardless of operator
diligence.**

## Decision: Model B (chosen) vs Model A (rejected)

Reviewed with `codex-task review` (read-only; note `.claude/ollama-notes/20260618-084023-codex-review.md`).
Codex agreed with the root cause and the "automate, don't just write rules" direction, and surfaced
the `local-build.sh` exit-code bug + the `mid-stack-update.sh` provenance gap (below).

- **Model A — per-patch manifest with per-file deletion budgets (REJECTED).** Each patch declares
  allowed paths + budgets, relaxed via committed waivers. Rejected because the manifest **goes stale
  and creates churn**: every legitimate new deletion needs a human-authored waiver, and an agent
  regenerating patches constantly trips it and is tempted to "just update the manifest." A manifest an
  agent can edit is no guard at all.

- **Model B — safety-path list + generated audit, fail-closed on safety paths (CHOSEN).** The only
  human-maintained artifact is a short, rarely-changing **safety-critical path list**. The audit is
  **generated fresh each run** (nothing stored, nothing to drift): it **hard-fails** when a patch
  deletes pre-existing upstream code in a safety path, and **warns** (prints the footprint) elsewhere.
  Near-zero maintenance; nothing to keep in sync; catches the catastrophic class. **Agents are
  forbidden from editing the safety list / waivers** — that rule is what gives it teeth. If a
  *non-safety* clobber ever actually happens, add a per-file budget for that specific file then; do
  not pre-build the full budget manifest (it's the part most likely to rot).

## Implementation (Model B)

### 1. `scripts/patch-audit.sh` (new)
Per patch N, in stack order:
1. Build baseline `dev + patches < N` (reuse the patch-test/mid-stack worktree machinery).
2. `git am --3way` patch N onto the baseline.
3. `git diff-tree --numstat --find-renames HEAD^ HEAD` for patch N's commit.
4. Classify each touched path:
   - **created-by-this-patch** (new file in this patch) → deletions ignored.
   - **pre-existing-in-baseline / pre-existing-in-raw-dev** (`git cat-file -e dev:<path>`) → audit
     **deleted non-blank lines**.
5. **Fail-closed** if any deleted non-blank line falls in a **safety-critical path** (see config),
   unless a committed waiver covers it. **Warn** (print footprint: path, +/-, deleted hunks) for
   non-safety deletions of pre-existing code.
6. **Sentinel symbol check** (belt-and-suspenders for this exact incident): fail if the applied stack
   no longer contains `pumpManagerTypeByIdentifier`, `managerIdentifier.hasPrefix("Omni")`, or
   `OmniPumpManager` in `DeviceDataManager.swift`.
7. Emit a generated **audit artifact** (stdout): per-patch touched paths, ± counts, safety-path
   deletions, sentinel results.

### 2. Safety-critical path config (human-owned, rarely changes)
`scripts/patch-audit.safety-paths` (one glob per line). **As shipped** — a single
verified glob covering the entire closed-loop / pump-resolution subsystem:
```
Trio/Sources/APS/*
```
Matched with shell `case` globbing, where `*` spans `/`, so this covers all ~81
files under `Trio/Sources/APS/` (incl. `DeviceDataManager.swift`, `OpenAPS`,
`OpenAPSSwift`, `PumpManagerExtensions`, the CGM sources). The original proposal
listed five globs (`Trio/Sources/APS/**`, an explicit `DeviceDataManager.swift`,
`Trio/Sources/Services/**/*PumpManager*`, `Trio/Sources/Modules/Bolus/**`,
`OpenAPS/**`); these were dropped because (a) the `**` form isn't how `case`
globbing works, (b) the explicit file and the `OpenAPS/**` path are already inside
`Trio/Sources/APS/`, and (c) the Bolus / Services entries pointed at paths that
either don't carry the catastrophic class of bug or were unverified. Start narrow
and verified; widen only when a real non-APS clobber proves the need.
Waivers (rare): `scripts/patch-audit.waivers` — one line `patch=<NN> file=<path> allow_deleted=<n> reason="..."`.
**Only a human edits these two files.** AGENTS rule forbids agents from editing them.

### 3. Hook points
- `scripts/patch-test.sh` — call `patch-audit.sh` after the apply loop; non-zero audit = patch-test
  fails.
- `scripts/mid-stack-update.sh` — run the audit on the regenerated patch before declaring success
  (closes the gap below).

### 4. Fixes to existing tooling

#### `ci/local-build.sh` false success (fixed 2026-06-18)

**Incident:** On the first build-209 attempt, the IPA archive failed (Swift compiler crash in
G7SensorKit), yet `local-build.sh` printed `✅ TOTAL (Success)` and exited 0. The Build-IPA stage
logged `ARCHIVE FAILED` correctly; only the wrapper exit code and summary banner were wrong.

**Root cause:** `if ! capture_fastlane_errors ...; then rc=$?` captures the status of the `!`
expression (0 on failure), not the command's exit code. Same bug at all three fastlane call sites
(build, release, release-only).

**Current behavior (as of commit `f3e4978f7`):**
- All fastlane invocations use `cmd || rc=$?` so a failed archive/upload propagates a non-zero exit.
- The `cleanup` trap calls `print_stage_summary "failed"` (prints `❌ TOTAL (Failed)`) when
  `exit_code ≠ 0`; success banner only on exit 0.
- `stage_ipa_for_release` treats a missing IPA as a **hard failure** (`exit 1`), not a warning.
- Failure detection is exit-code based via fastlane; there is no separate log-line assertion for
  "Successfully uploaded" / Record Release (not deemed necessary once exit codes are correct).

**Verification markers:**
- Failed archive: `ARCHIVE FAILED`, `[build] ❌ Build step FAILED (exit code: 1)`,
  `[stage] ✗ Failed: Build IPA`, `❌ TOTAL (Failed)`, non-zero `EXIT_CODE`.
- Successful full deploy: `Build IPA … ✅`, `TestFlight Upload … ✅`, `Record Release … ✅`,
  `✅ TOTAL (Success)`, `EXIT_CODE=0`.

#### `mid-stack-update.sh` provenance gap (open)

Drift check compares the regenerated patch against the feature branch, so a bad deletion already in
the branch passes; provenance records `dev..feature` (not patch-local), so prior-patch commits
appear as a later patch's source. The audit hook (§3) closes the immediate safety gap;
provenance-scoping is tracked separately.

### 5. Doc rules
- **AGENTS.md:** the audit is mandatory and part of patch validation; agents never edit the
  safety-path list / waivers; an audit fail on a safety path is a hard STOP to surface to the human;
  conflict-free `git am --3way` is not verification (review the full file diff vs base); a passing
  build does not prove behavior preserved.
- **CLAUDE.md (Trio-dev):** agent verification = static review + `patch-test.sh` (which now runs the
  audit); builds only on explicit human request.

## How to maintain

- **Add/remove a safety-critical path:** edit `scripts/patch-audit.safety-paths` (human only). This is
  the rare maintenance.
- **Intentionally allow a safety-path deletion:** add a line to `scripts/patch-audit.waivers` (human
  only), with a reason. Reviewable in git diff.
- **Everything else is recomputed each run** — no per-patch manifest to update.

## Changelog

### v1.2 (2026-06-29 10:13 CET)
- Removed `docs/backlog/build-script-archive-exit-code/` (fix shipped; this doc is canonical).
- Expanded §4 with **current `local-build.sh` behavior** (exit-code propagation, failed summary
  banner, missing-IPA fatal) and verification markers from the original backlog write-up.
- Status → Implemented.

### v1.1 (2026-06-18)
- `scripts/patch-audit.sh` written (bash-3.2-safe) and **validated**:
  - PASSES on the current fixed stack (36 informational warnings — legitimate refactors in the
    watch/UI patches; patch 13's `DeviceDataManager.swift` is `+1/-0`, the comment only).
  - FAILS on the pre-fix clobbering patch 13 (`git show adc8b9508^:patches/13-…`) on **both**
    detectors: safety-path rule (`DeviceDataManager.swift +2/-56`) and the sentinel
    (`pumpManagerTypeByIdentifier`, `managerIdentifier.hasPrefix(OmniStr)` missing).
  - Sentinel string corrected to the real upstream form `managerIdentifier.hasPrefix(OmniStr)` (a
    `let OmniStr = "Omni"` variable, **not** a `"Omni"` string literal — the latter never existed).
- `scripts/patch-audit.safety-paths` shipped as the single verified glob `Trio/Sources/APS/*`
  (see §2 for why the original five-glob proposal was narrowed).
### v1.0 (2026-06-18)
- Initial design + decision record. Model B approved over Model A (codex-reviewed). Implementation of
  `patch-audit.sh` + hooks + `local-build.sh` fix + doc rules to follow.
