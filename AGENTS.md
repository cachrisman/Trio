# AGENTS.md - AI Agent Instructions for Trio Development

This document describes the local development workflow for this repository to help AI agents assist effectively.

## Repository Overview

Trio is an iOS automated insulin delivery system app. This is a personal fork used for local development, testing, and deploying customized builds to TestFlight.

### Upstream Relationship

- **Origin (this fork)**: `https://github.com/cachrisman/Trio.git`
- **Upstream**: `https://github.com/nightscout/Trio.git`

To sync with upstream (run on `dev` only):
```bash
git fetch upstream
git checkout dev
git merge upstream/dev
```

When upstream `dev` updates, existing patches may need regeneration if they conflict.

## Agent Safety Rules (Read First)

1. **AI agents must never upload to TestFlight / App Store Connect.**
   - Always set `SKIP_RELEASE=1` for any build invocation.
   - Do not run `fastlane release` directly.
2. **Never print or inspect `.trio-env` contents.**
   - Do not `cat .trio-env`, echo secrets, or paste signing/auth logs into issues/PRs.
3. **Do not modify submodules unless explicitly instructed.**
4. **Do not change signing, bundle IDs, or Fastlane lanes unless the task explicitly requires it.**
5. **Do not manually change version/build numbers.**
   - Fastlane versioning/build-number logic is handled in the `Fastfile`.
6. **Do not commit unless explicitly instructed by the user.**
   - If asked to commit/push, summarize changes first and ask for confirmation.

## Development Workflow

### Canonical Feature Workflow (Agent-Friendly)

```
┌────────────────────────────────────────────────────────────────────────────┐
│  1. Create/checkout feature branch from `dev`                              │
│  2. Implement code changes on feature branch                               │
│  3. Generate/update patch file(s)                                          │
│     ./scripts/generate-patch.sh -n -d "short-description"                  │
│  4. Test patch application from a clean `dev` state (fast, no build)       │
│     (see "Testing Patches")                                                │
│  5. If patch application fails → CLEAN UP → fix code → restart from step 3 │
│     (do not edit patch files)                                              │
│  6. If patch application succeeds → verify app build (NO upload)           │
│     BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh              │
│  7. If build fails → CLEAN UP → fix code → restart from step 3             │
│  8. Optional: simulate dev-based build with patches (still NO upload)      │
│     BASE_BRANCH=dev SKIP_RELEASE=1 ./ci/local_build_script.sh              │
└────────────────────────────────────────────────────────────────────────────┘
```

## Patch-Based Workflow

The build system is **patch-based**. All fork-specific changes are packaged as `.patch` files that get applied to the `dev` branch during dev-based builds:

- **Patches directory**: `./patches/` - contains `.patch` files to be applied
- **Only `.patch` files are applied** - rename/remove patches that should not be applied
- Patches are applied to a **temporary branch** created from `dev` during builds
- The original working state is preserved and restored after build (success or failure)

### Patch Types (Important)

Multiple patches are normal. Patches generally fall into two categories:

- **Type A (Upstream-bound patches)**: Changes you plan (or hope) to contribute upstream but have not yet been accepted/merged into upstream `dev`. These should eventually be removable once merged upstream.
- **Type B (Long-lived patches)**: Changes rejected upstream (or intentionally divergent) that must continue to be applied on top of future upstream `dev` updates.

## Non-Negotiable Rules for Working With Patches

1. **Never edit `.patch` files directly to “fix” patch application.**
   - If a patch fails to apply, fix the underlying code on a branch and **regenerate** the patch.
2. **During patch testing, do not attempt to fix conflicts “mid-test.”**
   - If a patch fails: **stop → clean up → return to your feature branch → fix → regenerate → restart testing**.
3. **Always test patch application from a clean state before committing a new/updated patch.**
4. **Keep patch filenames and ordering deterministic.**
   - `generate-patch.sh` auto-assigns the next `XY-` prefix; ordering is alphabetical.

## Key Scripts

### `./scripts/generate-patch.sh`

Script to generate patch files by comparing git branches. Supports interactive mode and non-interactive mode (recommended for AI agents).

**What it does:**
1. Compares a source branch against a target branch (default: `dev`)
2. Lists all files that differ between the branches
3. Allows selection of which files to include in the patch
4. Generates a patch file with an **auto-incrementing two-digit prefix** (`XY-`)
5. Validates the patch using `git apply --check`

**Interactive mode:**
```bash
./scripts/generate-patch.sh
```

**Non-interactive examples:**
```bash
# Fully non-interactive with custom description (recommended)
./scripts/generate-patch.sh -n -d "fix-watch-crash"

# Generate patch from specific branches, include all files
./scripts/generate-patch.sh -s feature/my-feature -t dev -a -d "my-feature"

# Include uncommitted (staged + unstaged) changes
./scripts/generate-patch.sh -n -w -d "wip-changes"

# Include only specific files by path
./scripts/generate-patch.sh -n -d "my-fix" \
  --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"

# Exclude certain patterns
./scripts/generate-patch.sh -n -d "code-only" \
  --exclude-files "*.md,*.json,*Test*"
```

**Selected CLI options:**
- `-s, --source-branch <branch>`: source branch with changes (default: current branch)
- `-t, --target-branch <branch>`: target branch for patch (default: `dev`)
- `-d, --description <text>`: short description for filename
- `-a, --all-files`: include all changed files
- `--include-files <paths>`: comma-separated file paths/globs to include
- `--exclude-files <paths>`: comma-separated file paths/globs to exclude
- `-w, --include-worktree`: include uncommitted changes
- `-o, --output <path>`: custom output path
- `-n, --non-interactive`: non-interactive mode

**Patch naming:** The script automatically names patches with the next sequential `XY-` prefix based on existing patches in `./patches/`. No manual renaming needed.

### `./ci/local_build_script.sh`

Build script that compiles the app and can upload to TestFlight (unless disabled).

**Agent-safe build (compile only, no upload):**
```bash
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh
```

**Dev-based build simulation with patches (NO upload when SKIP_RELEASE=1):**
```bash
BASE_BRANCH=dev SKIP_RELEASE=1 ./ci/local_build_script.sh
```

**What it does (high level):**
1. Loads secrets from `.trio-env`
2. Runs certificate management (`./ci/local_create_certs.sh`)
3. Creates a temporary branch from base (usually `dev`)
4. Stashes any uncommitted changes
5. Applies all `*.patch` files from `./patches/` (unless building current branch state)
6. Runs `fastlane build_trio` to compile the app
7. Runs `fastlane release` to upload to TestFlight (unless `SKIP_RELEASE=1`)
8. Cleans up: deletes temp branch, restores original branch, restores stash

### `./ci/local_create_certs.sh`

Manages Apple certificates and provisioning profiles via Fastlane Match.

## Environment Setup

### Required: `.trio-env` file

Create a `.trio-env` file in the repo root with these secrets:
```bash
TEAMID=XXXXXXXXXX           # Apple Developer Team ID
GH_PAT=ghp_xxxxxxxxxxxx     # GitHub Personal Access Token
FASTLANE_KEY_ID=XXXXXXXXXX  # App Store Connect API Key ID
FASTLANE_ISSUER_ID=xxx-xxx  # App Store Connect Issuer ID
FASTLANE_KEY="-----BEGIN... (multi-line PEM string in quotes) ...END-----"
MATCH_PASSWORD=xxxxxxxxxx   # Password for Match encrypted certificates
```

**Note:** `.trio-env` is gitignored and must never be committed or printed.

### Build Output

- Build logs: `./build/artifacts/ci-local-build-*.log`
- Certificate logs: `./build/artifacts/ci-local-create-certs-*.log`
- IPA file: `./Trio.ipa` (after successful build)

### Build Time Expectations

- **Clean build**: ~10-15 minutes
- **Incremental build** (with derived data cache): ~3-8 minutes
- **Build with `SKIP_RELEASE`**: Same compile time (only skips the upload step at the end)

## Managing Patches

- **Enable a patch**: ensure it has `.patch` extension in `./patches/`
- **Disable a patch**: rename to `.patch.ignore` or remove from directory
- **Order matters**: patches are applied alphabetically; `generate-patch.sh` uses `XY-` prefixes for deterministic ordering
- **Do not hand-edit patches**: fix code and regenerate via `generate-patch.sh`

View current patches:
```bash
ls -1 patches/*.patch
```

## Creating or Updating a Patch (Complete Workflow)

This workflow exists because mistakes are common (especially trying to “fix” patches during testing). Follow the phases and failure-handling rules exactly.

### Phase 0: Preconditions

- You have a feature branch with the intended changes.
- You can compile successfully without upload:
  ```bash
  BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh
  ```
- If the build fails, fix code and re-run until it succeeds.

### Phase 1: Generate the patch file

Preferred approach (simple and usually sufficient):
```bash
./scripts/generate-patch.sh -n -d "short-description"
```

If you need explicit branches or want to include uncommitted changes:
```bash
./scripts/generate-patch.sh -s feature/my-feature -t dev -n -w -d "short-description"
```

**Important:** `generate-patch.sh` automatically assigns the next `XY-` prefix and validates the patch.

### Phase 2: Test patch application from a clean state (mandatory)

See "Testing Patches (Before Committing)". Do not skip this.

### Phase 3: If patch testing fails (mandatory failure handling)

If any patch fails to apply during testing:

1. **Stop testing immediately. Do not edit any patch file.**
2. **Clean up the test environment** (delete test branch, restore clean `dev` state).
3. Switch to your feature branch.
4. Fix the underlying code issue.
5. Regenerate the patch (`generate-patch.sh`).
6. Restart the full testing procedure from the beginning.

## Testing Patches (Before Committing)

Goal: verify all patches (including your new/updated patch) apply cleanly in order from a clean `dev` state.

### Step 1: Start from a clean `dev`

```bash
git checkout dev
git reset --hard HEAD
git clean -fd
git submodule update --init --recursive
```

If submodules appear dirty, see "Known Submodule Gotchas" before proceeding.

### Step 2: Create a fresh test branch

```bash
git branch -D test/apply-all-patches 2>/dev/null
git checkout -b test/apply-all-patches
```

### Step 3: Apply all patches in order (fail fast)

```bash
for patch in patches/*.patch; do
  [ -f "$patch" ] || continue
  echo "Applying $patch"
  git apply --check "$patch" && git apply "$patch" || {
    echo "Patch failed to apply: $patch"
    echo "STOP. Do not edit patch files. Clean up and regenerate."
    exit 1
  }
done
echo "All patches applied cleanly."
```

### Step 4: Optional compile test (recommended)

```bash
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh
```

If build fails:
- do not attempt to “fix” during this test branch
- clean up, switch back to feature branch, fix, regenerate, restart testing

### Step 5: Cleanup test branch

```bash
git checkout dev
git branch -D test/apply-all-patches
```

## Known Submodule Gotchas

Agents often struggle to restore submodules to a clean state when patch application or builds fail.

Recommended approach (from repo root):

```bash
git submodule sync --recursive
git submodule update --init --recursive

# If submodules are dirty and you need a clean slate:
git submodule foreach --recursive 'git reset --hard && git clean -fd'
git submodule update --init --recursive
```

If a specific submodule continues to show unexpected changes, report which submodule and `git status` output (without printing secrets), and ask the user for guidance before attempting more invasive fixes.

## Commit Practices (Only When Explicitly Instructed)

### Always Ask for Confirmation

Ask for confirmation before:
- committing
- amending
- rebasing
- pushing (especially force pushes)

### Preserving Commit Messages When Rewriting

- Always preserve the original commit message when amending or rewriting commits.
- If the original commit had a multi-line message, keep all of it.
- Only add to the commit message if the new changes deserve additional explanation.

### When to Create a New Commit vs Amend

- **Amend**: fixing the immediately previous commit (HEAD)
  - use `git commit --amend`
  - preserve the original full message
- **New commit**: different logical change, or commits exist in between
- **Rebase**: multiple commits need reorganization or fixes
  - use interactive rebase (`git rebase -i`)
  - preserve original messages when rewriting/squashing

### Clean Commit History Preference

- The repository owner is the only developer, so rewriting history is acceptable.
- Prefer clean, logical history over preserving “what happened”.
- Use `git push --force-with-lease` (or `--force`) when needed.

## AI Agent Build Verification

AI agents can verify that code changes compile successfully **without uploading to TestFlight** using `SKIP_RELEASE=1`.

```bash
# Optional preflight
git status
git submodule update --init --recursive

# Verify code compiles without uploading
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh

# If it fails, check for errors:
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs grep -A2 "❌"
```

Optional additional triage (if ❌ markers are missing/unhelpful):
```bash
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs egrep -n "error:|ARCHIVE FAILED|Exit status|Code signing|Provisioning"
```

## Progress Reporting Template (for AI Agents)

- **Goal**: <what was requested>
- **Changes made**:
  - <file1> — <summary>
  - <file2> — <summary>
- **Build command run**:
  - `BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh`
- **Result**:
  - Success / Failure
- **If failure**:
  - Top error snippet (short)
  - Likely cause
  - Proposed next step(s)
- **Next step (if success)**:
  - Generate patch: `./scripts/generate-patch.sh -n -d "<description>"`
  - Test patches: follow "Testing Patches (Before Committing)"

## Common Issues & Solutions

### Patch Fails to Apply (dev-based builds)

If a dev-based build fails with patch errors:
1. Check if `dev` has changed (`git fetch upstream && git checkout dev && git merge upstream/dev`)
2. Regenerate the patch from your feature branch (do not edit patch files)
3. Re-test patch application from a clean state

### Build Fails

1. Check `./build/artifacts/ci-local-build-*.log` for details
2. Look for ❌ emoji markers (fastlane error indicators)
3. Common issues:
   - Certificate/provisioning profile issues → run `./ci/local_create_certs.sh` (only if explicitly needed)
   - Missing dependencies → run `bundle install`
   - Code signing → check `Config.xcconfig` exists

### Stash Not Restored

If changes aren't restored after a failed build:
```bash
git stash list
git stash apply stash@{0}
```

## Code Style

There is no enforced SwiftLint or SwiftFormat configuration in this repo. Follow the existing code style in nearby files when making changes.

## Project Structure (Key Directories)

```
Trio/
├── ci/                           # Build scripts
│   ├── local_build_script.sh
│   └── local_create_certs.sh
├── scripts/                      # Development utilities
│   └── generate-patch.sh
├── patches/                      # Patch files (applied during dev-based builds)
├── fastlane/                     # Fastlane configuration
│   └── Fastfile
├── Trio/                         # App projects (phone + related targets)
│   └── Sources/                  # Main iPhone app source code
├── Model/                        # Shared data models used across the project
├── Trio Watch App/               # Watch app target
├── Trio Watch App Extension/     # Watch extension target
├── Trio Watch Complication/      # Watch complication target
├── LiveActivity/                 # Live Activity-related code
├── build/artifacts/              # Build logs (gitignored)
├── artifacts/                    # Additional artifacts (if present)
├── .trio-env                     # Secrets (gitignored, required)
├── Config.xcconfig               # Xcode config (generated)
└── ConfigOverride.xcconfig       # Team ID config
```

Notes:
- Submodules exist in the repo root. Agents generally should not modify submodule content unless explicitly asked.

## Tips for AI Agents

1. **Never upload**: Always include `SKIP_RELEASE=1` in builds.
2. **Don't modify `.trio-env`** and never print its contents.
3. **Code changes go on feature branches**, not `dev`.
4. **After a successful build**, generate patch via `./scripts/generate-patch.sh -n -d "description"`.
5. **Do not edit patch files directly**; regenerate instead.
6. **Patch naming is automatic** - the script assigns the next `XY-` prefix.
7. **Test patch application from a clean state** before committing.
8. **Submodules exist**; see "Known Submodule Gotchas" if submodules appear dirty.
9. **Build logs are in `./build/artifacts/`** and are the primary debugging source.
10. **Use non-interactive flags** (`-n`, `-a`, `-d`) when running `generate-patch.sh`.

## Quick Reference Commands

```bash
# Start new feature
git checkout dev
git pull
git checkout -b feature/my-feature

# Agent-safe local build (no upload)
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh

# Generate patch from feature branch (non-interactive, after successful build)
./scripts/generate-patch.sh -n -d "my-feature"

# Test all patches apply cleanly (from clean dev)
git checkout dev && git reset --hard HEAD && git clean -fd && git submodule update --init --recursive
git branch -D test/apply-all-patches 2>/dev/null
git checkout -b test/apply-all-patches
for patch in patches/*.patch; do git apply --check "$patch" && git apply "$patch" || exit 1; done

# Find errors in latest build log (fastlane ❌ markers)
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs grep -A2 "❌"

# Sync with upstream (run on dev)
git fetch upstream && git checkout dev && git merge upstream/dev

# Submodule cleanup (use with care)
git submodule sync --recursive
git submodule update --init --recursive
git submodule foreach --recursive 'git reset --hard && git clean -fd'

# Full generate-patch.sh help
./scripts/generate-patch.sh -h
```
