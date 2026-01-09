# AGENTS.md

Instructions for AI agents working in this repository.

This repo is a personal fork that maintains a **patch stack** in `./patches/` applied on top of upstream `dev`. Agents must optimize for **repeatable patch application**, **safe local builds**, and **minimal drift from the defined workflow**.

Read first:
- `docs/feature-branch-workflow-optimization.md`
- `docs/feature-branch-workflow-optimization-patch-migration.md` (only during migration/cutover work)

---

## Non-negotiable safety rules

1) **Never upload to TestFlight unless explicitly instructed.**
   - Default to **build-only** (no upload).
   - Do not run `fastlane release` unless explicitly requested.

2) **Never print, inspect, or exfiltrate secrets**
   - Includes `.trio-env`, signing secrets, API keys/tokens, App Store Connect keys, Match password, etc.

3) **Do not modify submodules** unless explicitly instructed.
   - If submodules exist, only run safe commands like `git submodule update --init --recursive` unless told otherwise.

4) **Do not change bundle IDs, signing settings, or Fastlane lanes** unless explicitly instructed.

5) **Do not hand-edit patch files to fix apply failures.**
   - Fix code and **regenerate** the patch.

6) **Do not commit or push** unless explicitly asked.
   - Summarize changes first.

7) **For plan/workflow document edits, increment the document version and update the changelog.**
   - When editing workflow docs/prompts/checklists, increment the version and update the changelog in the same change.

---

## Core invariants (must remain true)

1) A clean checkout of fork `dev` (synced to upstream) must be able to apply **all patches** in `./patches/` **in order**.

2) **Target patch application mechanism:** `git am` (mailbox patches).
   - During transition: patches may use `*.am.patch`
   - Long-term steady state: patches become `*.patch` but still mailbox-format and applied with `git am`

3) **Local shipping is authoritative.**
   - Weekly CI is for upstream sync + patch apply + build/deploy.
   - Day-to-day manual build/deploy is done locally using `ci/local-build.sh`.

---

## Patch rules (mailbox patch target)

- **One feature → one patch file** (deterministic ordering via numeric prefix `NN-`).
- Patch order is alphabetical (numeric prefix controls order).
- Prefer generating patches from a single squashed commit on `ready/<name>`.

### File naming / extension
- During cutover: `patches/NN-short-desc.am.patch`
- After cutover: `patches/NN-short-desc.patch` (mailbox-format; still applied with `git am`)

---

## Common workflows (agent-safe)

### A) Build current branch state (no patches) — no upload
```bash
ci/local-build.sh --build-current --build-only

B) Simulate “dev + patch stack” build — no upload (default)

ci/local-build.sh --base-branch dev --build-only

C) Build dev + patches + reapply local tracked changes (only if explicitly requested)

ci/local-build.sh --base-branch dev --reapply-stash --include-untracked --build-only

D) Upload to TestFlight (explicit only)

Two-phase local ship is preferred:
	1.	Build-only first (validates compilation/signing)

ci/local-build.sh --base-branch dev --build-only

	2.	Release-only second (fast upload using existing IPA)

ci/local-build.sh --release-only

Notes:
	•	--release-only expects ./Trio.ipa to exist in repo root.

⸻

Patch stack validation (target behavior: git am)

Run from a clean working tree:

git checkout dev
git reset --hard
git clean -fd
git submodule update --init --recursive

git branch -D tmp/test-am 2>/dev/null || true
git checkout -b tmp/test-am

for p in patches/*.am.patch; do
  [ -f "$p" ] || continue
  git am "$p" || exit 1
done

git checkout dev
git branch -D tmp/test-am

After cutover rename, update the glob to patches/*.patch (still git am).

⸻

Generate / publish a mailbox patch (one feature)

Agent should follow the workflow doc, but the practical “publish” steps are:
	1.	Create ready/<name> from feature branch and squash to one commit.
	2.	Export mailbox patch:

git format-patch -1 --stdout HEAD > patches/NN-short-desc.am.patch

	3.	Sanity check:

git am --check patches/NN-short-desc.am.patch

	4.	Patch files are committed to fork dev only when explicitly instructed to commit.

⸻

Upstream sync (local)

Only do this if explicitly requested:

git remote add upstream https://github.com/nightscout/Trio.git   # if not present
git fetch upstream
git checkout dev
git pull origin dev
git merge upstream/dev
git push origin dev

Then re-run patch stack validation.

⸻

Build system changes vs product changes
	•	Product changes (app code): shipped via patch files in ./patches/.
	•	Build/infra changes (Fastfile, ci/local-build.sh, CI workflow YAML, helper scripts, docs): normal commits to fork dev (not patches), unless explicitly directed otherwise.

⸻

Reporting template (required)
	•	Goal
	•	Files changed (by path)
	•	Commands run (exact)
	•	Result
	•	If failure: top error excerpt + likely cause + next recommended step
	•	If success: next step (patch regen / patch-stack validation / build-only / release-only)

