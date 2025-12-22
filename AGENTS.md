# AGENTS.md - AI Agent Instructions for Trio Development

This document describes the local development workflow for this repository to help AI agents assist effectively.

## Repository Overview

Trio is an iOS automated insulin delivery system app. This is a personal fork used for local development, testing, and deploying customized builds to TestFlight.

### Upstream Relationship

- **Origin (this fork)**: `https://github.com/cachrisman/Trio.git`
- **Upstream**: `https://github.com/nightscout/Trio.git`

To sync with upstream:
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

## Development Workflow

### 1. Canonical Feature Workflow (Agent-Friendly)

```
┌───────────────────────────────────────────────────────────────────────┐
│  1. Create/checkout feature branch from `dev`                         │
│  2. Implement code changes on feature branch                          │
│  3. Verify the code compiles locally (NO upload)                      │
│     BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh         │
│  4. If build fails → fix issues → repeat step 3                       │
│  5. If build succeeds → generate/update patch file(s)                 │
│     ./scripts/generate-patch.sh -n -d "description"                   │
└───────────────────────────────────────────────────────────────────────┘
```

### 2. Patch-Based Workflow

The build system is **patch-based**. All fork-specific changes are packaged as `.patch` files that get applied to the `dev` branch during dev-based builds:

- **Patches directory**: `./patches/` - contains `.patch` files to be applied
- **Only `.patch` files are applied** - rename/remove patches that should not be applied
- Patches are applied to a **temporary branch** created from `dev` during builds
- The original working state is preserved and restored after build (success or failure)

#### Patch Types (Important)

Multiple patches are normal. Patches generally fall into two categories:

- **Type A (Upstream-bound patches)**: Changes you plan (or hope) to contribute upstream but have not yet been accepted/merged into upstream `dev`. These should eventually be removable once merged upstream.
- **Type B (Long-lived patches)**: Changes rejected upstream (or intentionally divergent) that must continue to be applied on top of future upstream `dev` updates.

### 3. Key Scripts

#### `./scripts/generate-patch.sh`

Script to generate patch files by comparing git branches. Supports both interactive mode (prompts for all options) and non-interactive mode (via command-line flags).

**What it does:**
1. Compares a source branch against a target branch (default: `dev`)
2. Lists all files that differ between the branches
3. Allows selection of which files to include in the patch
4. Generates a patch file with an **auto-incrementing two-digit prefix** (`XY-`)
5. Validates the patch file using `git apply --check`

**Interactive mode (default):**
```bash
./scripts/generate-patch.sh
```

**Non-interactive mode (for AI agents):**
```bash
# Fully non-interactive with custom description
./scripts/generate-patch.sh -n -d "fix-watch-crash"

# Generate patch from specific branches, include all files
./scripts/generate-patch.sh -s feature/my-feature -t dev -a -d "my-feature"

# Include uncommitted (staged + unstaged) changes
./scripts/generate-patch.sh -n -w -d "wip-changes"

# Include only specific files by path
./scripts/generate-patch.sh -n -d "my-fix" \
    --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"

# All files except certain patterns
./scripts/generate-patch.sh -n -d "code-only" \
    --exclude-files "*.md,*.json,*Test*"
```

**Key CLI options:**

| Flag | Description |
|------|-------------|
| `-s, --source-branch <branch>` | Source branch with changes (default: current branch) |
| `-t, --target-branch <branch>` | Target branch for patch (default: `dev`) |
| `-d, --description <text>` | Short description for filename (e.g., "fix-crash") |
| `-a, --all-files` | Include all changed files (skip file selection) |
| `--include-files <paths>` | Comma-separated file paths/globs to include |
| `--exclude-files <paths>` | Comma-separated file paths/globs to exclude |
| `-w, --include-worktree` | Include uncommitted changes |
| `-W, --no-include-worktree` | Exclude uncommitted changes (committed only) |
| `-o, --output <path>` | Custom output path (overrides auto-naming) |
| `-y, --yes` | Auto-confirm prompts (e.g., overwrite) |
| `-n, --non-interactive` | Non-interactive mode (equivalent to `-a -W -y`) |
| `-h, --help` | Show full help message |

**Patch naming:** The script automatically names patches with the next sequential `XY-` prefix based on existing patches in `./patches/`. No manual renaming needed.

#### `./ci/local_build_script.sh`

Build script that compiles the app and can upload to TestFlight (unless disabled).

**Agent-safe build (compile only, no upload):**
```bash
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh
```

**Interactive (owner use; may upload):**
```bash
./ci/local_build_script.sh
# Prompts:
#   1) Start from dev, apply patches, then build (default)
#   2) Build the current branch state (skip patches)
```

**Environment variables:**
```bash
# Force dev-based build with patches (owner use)
BASE_BRANCH=dev ./ci/local_build_script.sh

# Build current branch state (skip patches)
BUILD_CURRENT=1 ./ci/local_build_script.sh

# Dev + patches + reapply your stashed changes (owner use)
BASE_BRANCH=dev REAPPLY_STASH=1 ./ci/local_build_script.sh

# Build only, skip TestFlight upload (required for agents)
SKIP_RELEASE=1 ./ci/local_build_script.sh

# AI agent / CI validation: compile current branch without uploading
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh
```

**What it does:**
1. Loads secrets from `.trio-env`
2. Runs certificate management (`./ci/local_create_certs.sh`)
3. Creates a temporary branch from base (usually `dev`)
4. Stashes any uncommitted changes
5. Applies all `*.patch` files from `./patches/` (unless building current branch state)
6. Runs `fastlane build_trio` to compile the app
7. Runs `fastlane release` to upload to TestFlight (unless `SKIP_RELEASE=1`)
8. Cleans up: deletes temp branch, restores original branch, restores stash

#### `./ci/local_create_certs.sh`

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

## Working with Patches

### Patch Naming and Ordering

Patches are automatically named by `generate-patch.sh` with the format: `XY-<description>.patch`

- `XY` is the next sequential two-digit number after existing patches
- Examples: `01-fix-watch-crash.patch`, `02-add-feature.patch`
- The prefix ensures deterministic alphabetical ordering when patches are applied

**View current patches:**
```bash
ls -1 patches/*.patch
```

**Find the highest existing prefix:**
```bash
ls patches/*.patch 2>/dev/null | sed -E 's#.*/([0-9]{2})-.*#\1#' | sort -n | tail -1
```

### Creating a New Patch (After a Successful Build)

```bash
# 1. Be on your feature branch with changes
git checkout feature/my-feature

# 2. Verify the code compiles without uploading
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh

# 3. If build succeeded, generate the patch (non-interactive for agents)
./scripts/generate-patch.sh -n -d "my-feature-description"

# The script automatically:
#   - Detects source (current branch) and target (dev) branches
#   - Assigns the next XY- prefix
#   - Validates the patch applies cleanly
#   - Saves to ./patches/XY-<description>.patch
```

### Managing Patches

- **Enable a patch**: Ensure it has `.patch` extension in `./patches/`
- **Disable a patch**: Rename to `.patch.ignore` or remove from directory
- **Order matters**: Patches apply alphabetically; the `XY-` prefix controls order

## AI Agent Build Verification

AI agents can verify that code changes compile successfully **without uploading to TestFlight** using `SKIP_RELEASE=1`.

### Recommended Workflow for AI Agents

```bash
# (Optional) minimal preflight to reduce false failures
git status
git submodule update --init --recursive

# Verify code compiles without uploading
BUILD_CURRENT=1 SKIP_RELEASE=1 ./ci/local_build_script.sh

# If it fails, check for errors:
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs grep -A2 "❌"
```

Notes:
- The build process typically takes ~5–15 minutes depending on cache state.
- Swift compiler errors usually appear as `file.swift:line:column` in the logs.

### Understanding Build Output

- **Exit code 0**: Build succeeded, IPA created at `./Trio.ipa`
- **Non-zero exit code**: Build failed, check logs for details
- **Logs location**: `./build/artifacts/ci-local-build-*.log`

Optional additional triage (if ❌ markers are missing/unhelpful):
```bash
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs egrep -n "error:|ARCHIVE FAILED|Exit status|Code signing|Provisioning"
```

## Common Issues & Solutions

### Patch Fails to Apply (dev-based builds)

If a dev-based build fails with patch errors:
1. Check if `dev` has changed (`git fetch upstream && git checkout dev && git merge upstream/dev`)
2. Regenerate the patch from your feature branch
3. Review patch conflicts manually if needed

### Build Fails

1. Check `./build/artifacts/ci-local-build-*.log` for details
2. Look for ❌ emoji markers (fastlane error indicators)
3. Common issues:
   - Certificate/provisioning profile issues → run `./ci/local_create_certs.sh` (only if explicitly needed)
   - Missing dependencies → run `bundle install`
   - Code signing → check `Config.xcconfig` exists

### Stash Not Restored

If your changes aren't restored after a failed build:
```bash
git stash list                    # Find your stash
git stash apply stash@{0}         # Apply the most recent stash
```

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

## Code Style

There is no enforced SwiftLint or SwiftFormat configuration in this repo. Follow the existing code style in nearby files when making changes.

## Tips for AI Agents

1. **Never upload**: Always include `SKIP_RELEASE=1` in builds.
2. **Don't modify `.trio-env`** and never print its contents.
3. **Code changes go on feature branches**, not `dev`.
4. **After a successful build**, generate patch via `./scripts/generate-patch.sh -n -d "description"`.
5. **Patches are the deployment mechanism** - direct commits to `dev` aren't built in the patch-based flow.
6. **Patch naming is automatic** - the script assigns the next `XY-` prefix.
7. **The app is Swift/SwiftUI**; main phone app source is in `./Trio/Sources/`. Watch/complication/live activity folders are also relevant.
8. **Submodules exist**; avoid editing them unless asked.
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

# Find errors in latest build log (fastlane ❌ markers)
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs grep -A2 "❌"

# Optional: broader error scan if needed
ls -lt build/artifacts/ci-local-build-*.log | head -1 | xargs egrep -n "error:|ARCHIVE FAILED|Exit status|Code signing|Provisioning"

# Generate patch from feature branch (non-interactive, after successful build)
./scripts/generate-patch.sh -n -d "my-feature"

# Generate patch with specific files only
./scripts/generate-patch.sh -n -d "targeted-fix" --include-files "Trio/Sources/Foo.swift"

# Generate patch excluding certain files
./scripts/generate-patch.sh -n -d "code-only" --exclude-files "*.md,*.json"

# View active patches
ls -1 patches/*.patch

# Sync with upstream (when needed)
git fetch upstream && git checkout dev && git merge upstream/dev

# Check certificate status (only if explicitly needed)
./ci/local_create_certs.sh

# View latest build log
ls -lt build/artifacts/*.log | head -1 | xargs less

# Full generate-patch.sh help
./scripts/generate-patch.sh -h
```
