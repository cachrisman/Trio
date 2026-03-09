#!/usr/bin/env bash

#===============================================================================
# mid-stack-update.sh — Automate mid-stack patch updates (v1.4)
#
# DESCRIPTION:
#   Automates the mid-stack patch update workflow documented in
#   docs/feature-branch-workflow-optimization.md. This script exists to
#   eliminate common mistakes AI agents make when performing this process
#   manually, including:
#     - Using -t dev instead of -t tmp/<name>-baseline
#     - Forgetting to git checkout dev before running generate-patch.sh
#     - Using -a (all files) instead of --include-files
#     - Leaving tmp branches behind
#     - Running generate-patch.sh from the wrong branch
#     - Stash-popping over a regenerated patch file
#     - Omitting earlier feature branch commits from the patch
#
# WORKFLOW (automated by this script):
#   1. Precondition checks (worktree, branch, clean state)
#   2. Stash if needed (popped on exit)
#   3. Create tmp/<name>-baseline (dev + patches 01..N-1)
#   4. Create tmp/<name>-update (baseline + patch N + cherry-picked commits)
#   5. Squash into single commit
#   6. Switch to dev, run generate-patch.sh with --include-files
#   7. Run patch-test.sh to validate full stack
#   8. Drift check: compare patch output against feature branch to catch
#      accidentally omitted commits (requires --feature-branch or auto-detect)
#   9. Cleanup tmp branches
#
# USAGE:
#   ./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>[,<sha>...]
#   ./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha> [--extra-files <paths>]
#   ./scripts/mid-stack-update.sh --patch <NN> --dry-run
#
# OPTIONS:
#   -p, --patch <NN>
#       Patch number to update (e.g., 09). Required.
#       Matched against patches/NN-*.patch files.
#
#   -c, --cherry-pick <sha>[,<sha>,...]
#       Comma-separated list of commit SHAs to cherry-pick onto the update
#       branch after applying the current patch. Required (unless --dry-run).
#
#   --extra-files <paths>
#       Comma-separated list of additional file paths to include in the patch
#       beyond those already in the existing patch. Useful when the cherry-picked
#       commits introduce new files not in the current patch.
#
#   -b, --feature-branch <branch>
#       Feature branch to compare against after regeneration. Enables the
#       "drift check" that verifies the regenerated patch contains ALL
#       changes from the feature branch, not just the cherry-picked ones.
#       Catches the case where an earlier commit was accidentally omitted.
#       If not specified, the script tries feature/<patch-description> as
#       a default. Use --no-drift-check to skip entirely.
#
#   --no-drift-check
#       Skip the feature branch drift check entirely.
#
#   --dry-run
#       Show what would happen without making changes. Lists the patch file,
#       the baseline patches, and (if --cherry-pick given) the commits.
#
#   --skip-test
#       Skip the patch-test.sh validation step (not recommended).
#
#   -h, --help
#       Show this help message.
#
# EXAMPLES:
#   # Update patch 09, cherry-picking one commit from the feature branch
#   ./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234
#
#   # Update patch 06, cherry-picking two commits
#   ./scripts/mid-stack-update.sh --patch 06 --cherry-pick abc1234,def5678
#
#   # Explicit feature branch for drift check
#   ./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234 \
#       --feature-branch feature/watch-complication-improvements
#
#   # Dry run to see what would happen
#   ./scripts/mid-stack-update.sh --patch 09 --dry-run
#
#   # Include extra files not in the current patch
#   ./scripts/mid-stack-update.sh --patch 09 --cherry-pick abc1234 \
#       --extra-files "Trio/NewFile.swift,Trio/AnotherNew.swift"
#
# REQUIREMENTS:
#   - Must be run from the Trio-dev worktree
#   - Must be on the dev branch (or script will offer to switch)
#   - generate-patch.sh and patch-test.sh must exist in scripts/
#
# SEE ALSO:
#   - docs/feature-branch-workflow-optimization.md § "Updating an existing patch"
#   - AGENTS.md § "Common workflows"
#   - scripts/generate-patch.sh
#   - scripts/patch-test.sh
#
#===============================================================================

set -euo pipefail

# Make arrays behave similarly in zsh
if [ -n "${ZSH_VERSION-}" ]; then
    setopt KSH_ARRAYS
fi

#===============================================================================
# Colors and output helpers
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step_num=0

print_error()   { echo -e "${RED}Error:${NC} $1" >&2; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_step()    { step_num=$((step_num + 1)); echo -e "\n${BOLD}[Step ${step_num}]${NC} $1"; }

die() { print_error "$1"; exit 1; }

# Infrastructure paths: committed directly to dev, never shipped via patches.
# The drift check uses this to suppress false-positive "missing file" warnings
# for files the feature branch touches but that don't belong in any patch.
is_infra_path() {
    case "$1" in
        patches/*|scripts/*|ci/*|.github/*|fastlane/*|build/*|docs/*|.cursor/*)
            return 0 ;;
        AGENTS.md|.trio-env)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

#===============================================================================
# Argument parsing
#===============================================================================

PATCH_NUM=""
CHERRY_PICKS=""
EXTRA_FILES=""
FEATURE_BRANCH=""
NO_DRIFT_CHECK=false
DRY_RUN=false
SKIP_TEST=false

show_help() {
    awk '
        NR >= 3 && /^#===/ { count++; if (count == 2) exit }
        NR >= 3 { sub(/^# ?/, ""); print }
    ' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--patch)
            PATCH_NUM="$2"
            shift 2
            ;;
        -c|--cherry-pick)
            CHERRY_PICKS="$2"
            shift 2
            ;;
        --extra-files)
            EXTRA_FILES="$2"
            shift 2
            ;;
        -b|--feature-branch)
            FEATURE_BRANCH="$2"
            shift 2
            ;;
        --no-drift-check)
            NO_DRIFT_CHECK=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-test)
            SKIP_TEST=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            die "Unknown option: $1. Use -h for help."
            ;;
    esac
done

[ -n "$PATCH_NUM" ] || die "Missing required --patch <NN>. Use -h for help."

# Normalize patch number to 2 digits
PATCH_NUM=$(printf '%02d' "$((10#$PATCH_NUM))")

if [ "$DRY_RUN" = false ] && [ -z "$CHERRY_PICKS" ]; then
    die "Missing required --cherry-pick <sha>. Use --dry-run to preview without changes."
fi

#===============================================================================
# Precondition checks
#===============================================================================

print_step "Precondition checks"

# Must be in a git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"

REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_BASENAME=$(basename "$REPO_ROOT")

# Must be in Trio-dev worktree
if [ "$REPO_BASENAME" != "Trio-dev" ]; then
    die "Must be run from the Trio-dev worktree (currently in: $REPO_BASENAME).
  Run from: cd ../Trio-dev && ./scripts/mid-stack-update.sh ..."
fi

# Required scripts must exist
[ -x "$REPO_ROOT/scripts/generate-patch.sh" ] || die "scripts/generate-patch.sh not found or not executable"
[ -x "$REPO_ROOT/scripts/patch-test.sh" ] || die "scripts/patch-test.sh not found or not executable"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)

# Must be on dev (or offer to switch)
if [ "$CURRENT_BRANCH" != "dev" ]; then
    if [ "$DRY_RUN" = true ]; then
        print_warning "Not on dev (on '$CURRENT_BRANCH'). Dry run continues but real run requires dev."
    else
        die "Must be on the dev branch (currently on: $CURRENT_BRANCH).
  Run: git checkout dev"
    fi
fi

# Find the target patch file
PATCHES_DIR="$REPO_ROOT/patches"
PATCH_FILE=$(ls -1 "$PATCHES_DIR"/${PATCH_NUM}-*.patch 2>/dev/null | head -1)

if [ -z "$PATCH_FILE" ] || [ ! -f "$PATCH_FILE" ]; then
    die "No patch file found matching: patches/${PATCH_NUM}-*.patch
  Available patches:"$'\n'"$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | sed 's/^/    /')"
fi

PATCH_BASENAME=$(basename "$PATCH_FILE")
PATCH_NAME="${PATCH_BASENAME%.patch}"
PATCH_DESC="${PATCH_NAME#${PATCH_NUM}-}"

print_success "Patch file: $PATCH_BASENAME"

# Check for duplicate numeric prefixes (same check as generate-patch.sh)
dupes=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null \
    | xargs -I{} basename {} \
    | sed -E 's/^([0-9]{2})-.*/\1/' \
    | sort | uniq -d)
if [ -n "$dupes" ]; then
    die "Duplicate patch prefix(es) detected: $dupes
  Each NN- prefix must be unique. Fix by renaming or removing duplicates."
fi

# Collect patches deduplicated by numeric prefix (aligned with patch-test.sh).
# Uses a string-based seen list for bash 3.2 compatibility (no associative arrays).
ALL_PATCHES=()
BASELINE_PATCHES=()
_seen_prefixes=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    pbase=$(basename "$p")
    pnum="${pbase:0:2}"
    # Take only the first patch per numeric prefix (alphabetical order)
    case "$_seen_prefixes" in
        *":$pnum:"*) continue ;;
    esac
    _seen_prefixes="${_seen_prefixes}:${pnum}:"
    ALL_PATCHES+=("$p")
    if [ "$((10#$pnum))" -lt "$((10#$PATCH_NUM))" ]; then
        BASELINE_PATCHES+=("$p")
    fi
done < <(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | sort)

print_info "Total patches in stack: ${#ALL_PATCHES[@]}"
print_info "Baseline patches (01-$((10#$PATCH_NUM - 1))): ${#BASELINE_PATCHES[@]}"

# Extract file list from the existing patch
EXISTING_FILES=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    EXISTING_FILES+=("$f")
done < <(
    grep -E '^diff --git a/' "$PATCH_FILE" \
    | sed -E 's|^diff --git a/.+ b/(.+)$|\1|' \
    | sort -u
)

print_info "Files in current patch: ${#EXISTING_FILES[@]}"
for f in "${EXISTING_FILES[@]}"; do
    echo "    $f"
done

# Parse cherry-pick SHAs
CHERRY_PICK_SHAS=()
if [ -n "$CHERRY_PICKS" ]; then
    IFS=',' read -ra CHERRY_PICK_SHAS <<< "$CHERRY_PICKS"
    print_info "Commits to cherry-pick: ${#CHERRY_PICK_SHAS[@]}"
    for sha in "${CHERRY_PICK_SHAS[@]}"; do
        if git rev-parse --verify "$sha^{commit}" >/dev/null 2>&1; then
            short=$(git log -1 --format='%h %s' "$sha" 2>/dev/null || echo "$sha")
            echo "    $short"
        else
            if [ "$DRY_RUN" = false ]; then
                die "Invalid commit SHA: $sha"
            else
                print_warning "Cannot verify commit: $sha (may be in another worktree)"
            fi
        fi
    done
fi

# Parse extra files
EXTRA_FILE_LIST=()
if [ -n "$EXTRA_FILES" ]; then
    IFS=',' read -ra EXTRA_FILE_LIST <<< "$EXTRA_FILES"
    print_info "Extra files to include: ${#EXTRA_FILE_LIST[@]}"
    for f in "${EXTRA_FILE_LIST[@]}"; do
        echo "    $f"
    done
fi

# Resolve feature branch for drift check
if [ "$NO_DRIFT_CHECK" = true ]; then
    FEATURE_BRANCH=""
    print_info "Drift check: disabled (--no-drift-check)"
elif [ -z "$FEATURE_BRANCH" ]; then
    # Auto-detect: try feature/<patch-description>
    candidate="feature/$PATCH_DESC"
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
        FEATURE_BRANCH="$candidate"
        print_info "Drift check: auto-detected feature branch '$FEATURE_BRANCH'"
    else
        print_info "Drift check: no feature branch found (tried '$candidate'). Use --feature-branch to specify."
    fi
else
    if ! git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = false ]; then
            die "Feature branch not found: $FEATURE_BRANCH"
        else
            print_warning "Feature branch not found: $FEATURE_BRANCH"
        fi
    else
        print_info "Drift check: using feature branch '$FEATURE_BRANCH'"
    fi
fi

#===============================================================================
# Dry run: show plan and exit
#===============================================================================

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${BOLD}=== DRY RUN — no changes will be made ===${NC}"
    echo ""
    echo "Patch to update:    $PATCH_BASENAME"
    echo "Baseline patches:   ${#BASELINE_PATCHES[@]} (01 through $(printf '%02d' $((10#$PATCH_NUM - 1))))"
    echo "Cherry-pick SHAs:   ${CHERRY_PICKS:-<none>}"
    echo "Extra files:        ${EXTRA_FILES:-<none>}"
    echo ""
    echo "Planned steps:"
    echo "  1. Stash uncommitted changes (if any)"
    echo "  2. Create tmp/${PATCH_DESC}-baseline from dev + patches 01-$(printf '%02d' $((10#$PATCH_NUM - 1)))"
    echo "  3. Create tmp/${PATCH_DESC}-update from baseline + $PATCH_BASENAME"
    if [ "${#CHERRY_PICK_SHAS[@]}" -gt 0 ]; then
        echo "  4. Cherry-pick ${#CHERRY_PICK_SHAS[@]} commit(s) and squash"
    fi
    echo "  5. git checkout dev"
    echo "  6. generate-patch.sh -n -s tmp/${PATCH_DESC}-update -t tmp/${PATCH_DESC}-baseline \\"
    extra_count=${#EXTRA_FILE_LIST[@]}
    echo "       -o patches/$PATCH_BASENAME --include-files <${#EXISTING_FILES[@]}+${extra_count} files> -y"
    echo "  7. patch-test.sh"
    if [ -n "$FEATURE_BRANCH" ]; then
        echo "  8. Drift check: compare patch files against $FEATURE_BRANCH"
    fi
    echo "  9. Cleanup tmp branches, pop stash"
    echo ""
    echo "Include-files list (${#EXISTING_FILES[@]} from patch + ${extra_count} extra):"
    for f in "${EXISTING_FILES[@]}"; do echo "    $f"; done
    if [ "$extra_count" -gt 0 ]; then
        for f in "${EXTRA_FILE_LIST[@]}"; do echo "    $f (extra)"; done
    fi
    echo ""
    exit 0
fi

#===============================================================================
# Branch name setup
#===============================================================================

BASELINE_BRANCH="tmp/${PATCH_DESC}-baseline"
UPDATE_BRANCH="tmp/${PATCH_DESC}-update"

#===============================================================================
# Cleanup handler
#===============================================================================

DID_STASH=false
STASH_SHA=""
ORIGINAL_BRANCH="$CURRENT_BRANCH"

cleanup() {
    local exit_code=$?
    set +e

    cd "$REPO_ROOT" 2>/dev/null || true

    # Abort any in-progress operations that would block checkout
    git cherry-pick --abort 2>/dev/null || true
    git am --abort 2>/dev/null || true
    git merge --abort 2>/dev/null || true

    # Always try to get back to dev
    current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [ "$current" != "dev" ]; then
        git checkout dev 2>/dev/null || true
    fi

    # Preserve tmp branches when drift was detected (needed for investigation)
    if [ "${DRIFT_DETECTED:-false}" = true ]; then
        :
    else
        git branch -D "$UPDATE_BRANCH" 2>/dev/null || true
        git branch -D "$BASELINE_BRANCH" 2>/dev/null || true
    fi

    # Pop the exact stash we created (matched by SHA, not message)
    if [ "$DID_STASH" = true ] && [ -n "$STASH_SHA" ]; then
        local _i=0 _found=""
        while git rev-parse --verify --quiet "stash@{$_i}" >/dev/null 2>&1; do
            if [ "$(git rev-parse "stash@{$_i}" 2>/dev/null)" = "$STASH_SHA" ]; then
                _found="stash@{$_i}"
                break
            fi
            _i=$((_i + 1))
        done
        if [ -n "$_found" ]; then
            print_info "Restoring stashed changes ($_found)..."
            if ! git stash pop "$_found" 2>/dev/null; then
                print_warning "Stash pop had conflicts. Your stash is preserved at: $_found"
                print_warning "Resolve conflicts, then: git stash drop $_found"
            fi
        else
            print_warning "Could not find our stash (SHA: $STASH_SHA). Check: git stash list"
        fi
    fi

    if [ $exit_code -ne 0 ]; then
        echo ""
        print_error "Mid-stack update failed. Worktree restored to dev."
    fi

    exit $exit_code
}

trap cleanup EXIT INT TERM

#===============================================================================
# Step 1: Stash uncommitted changes
#===============================================================================

print_step "Check for uncommitted changes"

# Refuse to proceed if the target patch file has uncommitted modifications.
# Stash-pop after regeneration would conflict with or overwrite the new patch.
PATCH_RELPATH="patches/$PATCH_BASENAME"
if git status --porcelain -- "$PATCH_RELPATH" 2>/dev/null | grep -q .; then
    die "Target patch file has uncommitted changes: $PATCH_RELPATH
  Commit or discard those changes first, then re-run.
  (Stash-pop after regeneration would overwrite the newly generated patch.)"
fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    print_info "Stashing uncommitted changes..."
    git stash -u -m "mid-stack-update: WIP before updating patch $PATCH_NUM" || die "Failed to stash"
    DID_STASH=true
    STASH_SHA=$(git rev-parse stash@{0} 2>/dev/null)
    print_success "Changes stashed (ref: ${STASH_SHA:0:8})"
else
    print_success "Working tree is clean"
fi

#===============================================================================
# Step 2: Create baseline branch (dev + patches 01..N-1)
#===============================================================================

print_step "Create baseline: $BASELINE_BRANCH (dev + patches 01-$(printf '%02d' $((10#$PATCH_NUM - 1))))"

# Clean up any leftover tmp branches from prior failed runs
for _br in "$BASELINE_BRANCH" "$UPDATE_BRANCH"; do
    git branch -D "$_br" 2>/dev/null || true
    if git rev-parse --verify "$_br" >/dev/null 2>&1; then
        # Branch still exists after deletion attempt — likely checked out elsewhere
        _wt=$(git worktree list --porcelain 2>/dev/null \
            | awk -v b="refs/heads/$_br" '$1=="worktree"{p=$2} $1=="branch" && $2==b{print p}')
        if [ -n "$_wt" ]; then
            die "Cannot delete branch '$_br' — it is checked out in worktree: $_wt
  Switch that worktree to a different branch first, then re-run."
        else
            die "Branch '$_br' exists and could not be deleted. Remove it manually:
  git branch -D $_br"
        fi
    fi
done

git checkout -b "$BASELINE_BRANCH" dev || die "Failed to create $BASELINE_BRANCH"

if [ ${#BASELINE_PATCHES[@]} -gt 0 ]; then
    for p in "${BASELINE_PATCHES[@]}"; do
        pname=$(basename "$p")
        if ! git am --3way --keep-cr --whitespace=nowarn "$p" 2>/dev/null; then
            git am --abort 2>/dev/null || true
            die "Failed to apply baseline patch: $pname
  This means the patch stack has a problem before patch $PATCH_NUM.
  Fix the earlier patch first, then retry."
        fi
        echo "    ✓ $pname"
    done
    print_success "Applied ${#BASELINE_PATCHES[@]} baseline patches"
else
    print_success "No baseline patches to apply (updating the first patch)"
fi

#===============================================================================
# Step 3: Create update branch (baseline + current patch + cherry-picks)
#===============================================================================

print_step "Create update branch: $UPDATE_BRANCH"

git checkout -b "$UPDATE_BRANCH" "$BASELINE_BRANCH" || die "Failed to create $UPDATE_BRANCH"

# Apply the current patch
if ! git am --3way --keep-cr --whitespace=nowarn "$PATCH_FILE" 2>/dev/null; then
    git am --abort 2>/dev/null || true
    die "Failed to apply current patch: $PATCH_BASENAME
  The patch may need regeneration against the current baseline."
fi
print_success "Applied current patch: $PATCH_BASENAME"

#===============================================================================
# Step 4: Cherry-pick new commits
#===============================================================================

print_step "Cherry-pick ${#CHERRY_PICK_SHAS[@]} commit(s)"

for sha in "${CHERRY_PICK_SHAS[@]}"; do
    sha_trimmed=$(echo "$sha" | tr -d '[:space:]')
    short=$(git log -1 --format='%h %s' "$sha_trimmed" 2>/dev/null || echo "$sha_trimmed")

    if ! git cherry-pick "$sha_trimmed" 2>/dev/null; then
        # Capture conflict info before aborting
        conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    /')
        git cherry-pick --abort 2>/dev/null || true
        if [ -n "$conflict_files" ]; then
            die "Cherry-pick conflict on: $short
  Conflicting files:
$conflict_files
  The cherry-pick has been aborted and tmp branches cleaned up.
  Resolve the conflict interactively on the feature branch, then re-run."
        else
            die "Failed to cherry-pick: $short"
        fi
    fi
    echo "    ✓ $short"
done

print_success "Cherry-picked ${#CHERRY_PICK_SHAS[@]} commit(s)"

#===============================================================================
# Step 5: Squash into single commit
#===============================================================================

print_step "Squash into single commit"

# Count commits from baseline to HEAD
commit_count=$(git rev-list --count "$BASELINE_BRANCH".."$UPDATE_BRANCH")

if [ "$commit_count" -gt 1 ]; then
    # Soft reset to baseline keeping all changes staged
    git reset --soft "$BASELINE_BRANCH" || die "Failed to soft reset for squash"
    git commit -m "feat: $PATCH_DESC" || die "Failed to create squashed commit"
    print_success "Squashed $commit_count commits into one"
else
    print_success "Already a single commit (no squash needed)"
    print_info "Commit message preserved from original patch (no squash occurred)"
fi

#===============================================================================
# Step 6: Determine file list and regenerate patch
#===============================================================================

print_step "Regenerate patch: $PATCH_BASENAME"

# Discover all files in the diff (existing + any new from cherry-picks)
DIFF_FILES=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    DIFF_FILES+=("$f")
done < <(git diff --name-only "$BASELINE_BRANCH".."$UPDATE_BRANCH" | sort -u)

# Add extra files if specified (dedup against diff files)
if [ ${#EXTRA_FILE_LIST[@]} -gt 0 ]; then
    for ef in "${EXTRA_FILE_LIST[@]}"; do
        ef_trimmed=$(echo "$ef" | tr -d '[:space:]')
        already=false
        for df in "${DIFF_FILES[@]}"; do
            if [ "$df" = "$ef_trimmed" ]; then
                already=true
                break
            fi
        done
        if [ "$already" = false ]; then
            DIFF_FILES+=("$ef_trimmed")
        fi
    done
fi

if [ ${#DIFF_FILES[@]} -eq 0 ]; then
    die "No files found in diff between $BASELINE_BRANCH and $UPDATE_BRANCH. Nothing to patch."
fi

print_info "Files to include in patch: ${#DIFF_FILES[@]}"
for f in "${DIFF_FILES[@]}"; do
    echo "    $f"
done

# Build the comma-separated include-files string
INCLUDE_FILES_ARG=""
for f in "${DIFF_FILES[@]}"; do
    if [ -z "$INCLUDE_FILES_ARG" ]; then
        INCLUDE_FILES_ARG="$f"
    else
        INCLUDE_FILES_ARG="$INCLUDE_FILES_ARG,$f"
    fi
done

# CRITICAL: Must be on dev to run generate-patch.sh
# Save the patch output path (absolute) so it persists across branch switches
PATCH_OUTPUT_ABS="$REPO_ROOT/patches/$PATCH_BASENAME"

git checkout dev || die "Failed to switch to dev for patch generation"

print_info "Running generate-patch.sh..."
print_info "  -s $UPDATE_BRANCH"
print_info "  -t $BASELINE_BRANCH"
print_info "  -d $PATCH_DESC"
print_info "  -o patches/$PATCH_BASENAME"
print_info "  --include-files <${#DIFF_FILES[@]} files>"

if ! "$REPO_ROOT/scripts/generate-patch.sh" -n \
    -s "$UPDATE_BRANCH" \
    -t "$BASELINE_BRANCH" \
    -d "$PATCH_DESC" \
    -o "$PATCH_OUTPUT_ABS" \
    --include-files "$INCLUDE_FILES_ARG" \
    -y; then
    die "generate-patch.sh failed. Check output above for details."
fi

print_success "Patch regenerated: $PATCH_BASENAME"

#===============================================================================
# Step 7: Validate full patch stack
#===============================================================================

if [ "$SKIP_TEST" = true ]; then
    print_step "Validate patch stack (SKIPPED — not recommended)"
    print_warning "Patch validation was skipped. Run manually: scripts/patch-test.sh"
else
    print_step "Validate full patch stack"

    if ! "$REPO_ROOT/scripts/patch-test.sh"; then
        die "Patch validation failed! The updated patch does not apply cleanly in the full stack.
  Check the output above for which patch failed and why."
    fi

    print_success "All ${#ALL_PATCHES[@]} patches apply cleanly"
fi

#===============================================================================
# Step 8: Drift check — verify patch completeness against feature branch
#===============================================================================

DRIFT_DETECTED=false
INFRA_SKIP_FILES=()

if [ -n "$FEATURE_BRANCH" ]; then
    print_step "Verify patch completeness against $FEATURE_BRANCH"

    # Collect files modified by OTHER patches (01..N-1 and N+1..end)
    # Used to suppress false-positive "missing file" warnings for files that
    # belong to a different patch in the stack, not this one.
    OTHER_PATCH_FILES_TMP=$(mktemp)
    PRIOR_PATCH_FILES_TMP=$(mktemp)
    for p in "${ALL_PATCHES[@]}"; do
        pbase=$(basename "$p")
        pnum="${pbase:0:2}"
        pnum_val=$((10#$pnum))
        target_val=$((10#$PATCH_NUM))
        if [ "$pnum_val" -eq "$target_val" ]; then
            continue
        fi
        grep -E '^diff --git a/' "$p" \
            | sed -E 's|^diff --git a/.+ b/(.+)$|\1|' \
            >> "$OTHER_PATCH_FILES_TMP" 2>/dev/null || true
        if [ "$pnum_val" -lt "$target_val" ]; then
            grep -E '^diff --git a/' "$p" \
                | sed -E 's|^diff --git a/.+ b/(.+)$|\1|' \
                >> "$PRIOR_PATCH_FILES_TMP" 2>/dev/null || true
        fi
    done
    OTHER_PATCH_FILES_SORTED=$(sort -u "$OTHER_PATCH_FILES_TMP")
    PRIOR_PATCH_FILES_SORTED=$(sort -u "$PRIOR_PATCH_FILES_TMP")
    rm -f "$OTHER_PATCH_FILES_TMP" "$PRIOR_PATCH_FILES_TMP"

    # Categorize this patch's files
    VERIFIABLE_FILES=()
    OVERLAP_FILES=()

    for f in "${DIFF_FILES[@]}"; do
        if echo "$PRIOR_PATCH_FILES_SORTED" | grep -qxF "$f"; then
            OVERLAP_FILES+=("$f")
        else
            VERIFIABLE_FILES+=("$f")
        fi
    done

    # --- Check 1: files the feature branch modifies but the patch doesn't touch ---
    # Three-dot diff: compare from merge-base(dev, feature) to feature tip.
    # This shows only what the feature branch actually changed, excluding any
    # files that changed on dev since the feature branch diverged.
    FEATURE_FILES_TMP=$(mktemp)
    git diff --name-only dev..."$FEATURE_BRANCH" 2>/dev/null | sort -u > "$FEATURE_FILES_TMP"

    MISSING_FILES=()
    while IFS= read -r ff; do
        [ -n "$ff" ] || continue
        # Skip files already in this patch
        in_patch=false
        for df in "${DIFF_FILES[@]}"; do
            if [ "$df" = "$ff" ]; then
                in_patch=true
                break
            fi
        done
        [ "$in_patch" = true ] && continue
        # Skip files covered by any other patch in the stack — they belong elsewhere
        if echo "$OTHER_PATCH_FILES_SORTED" | grep -qxF "$ff"; then
            continue
        fi
        # Infrastructure files are committed directly to dev, never via patches
        if is_infra_path "$ff"; then
            INFRA_SKIP_FILES+=("$ff")
            continue
        fi
        MISSING_FILES+=("$ff")
    done < "$FEATURE_FILES_TMP"
    rm -f "$FEATURE_FILES_TMP"

    # --- Check 2: content comparison for non-overlapping files ---
    # For files ONLY this patch modifies, the update branch and feature branch
    # should produce identical content (both start from dev for these files).
    CONTENT_DRIFT_FILES=()
    for f in "${VERIFIABLE_FILES[@]}"; do
        update_content=$(git show "$UPDATE_BRANCH:$f" 2>/dev/null) || continue
        feature_content=$(git show "$FEATURE_BRANCH:$f" 2>/dev/null) || continue
        if [ "$update_content" != "$feature_content" ]; then
            CONTENT_DRIFT_FILES+=("$f")
        fi
    done

    # --- Report ---
    echo ""

    if [ ${#MISSING_FILES[@]} -gt 0 ]; then
        DRIFT_DETECTED=true
        print_warning "FILES MODIFIED BY FEATURE BRANCH BUT NOT IN PATCH: ${#MISSING_FILES[@]}"
        print_info "These files were changed on $FEATURE_BRANCH but are not in $PATCH_BASENAME."
        print_info "If they belong in this patch, add them via --extra-files or cherry-pick the missing commit."
        for f in "${MISSING_FILES[@]}"; do
            echo "    ⚠ $f"
        done
        echo ""
    fi

    if [ ${#INFRA_SKIP_FILES[@]} -gt 0 ]; then
        print_info "Skipped ${#INFRA_SKIP_FILES[@]} infrastructure file(s) from drift check (not shipped via patches):"
        for f in "${INFRA_SKIP_FILES[@]}"; do
            echo "    ℹ $f"
        done
        echo ""
    fi

    if [ ${#CONTENT_DRIFT_FILES[@]} -gt 0 ]; then
        DRIFT_DETECTED=true
        print_warning "CONTENT DRIFT: ${#CONTENT_DRIFT_FILES[@]} file(s) differ between patch and feature branch"
        print_info "The patch produces different content than $FEATURE_BRANCH for these files."
        print_info "This likely means a feature branch commit was not cherry-picked into the patch."
        for f in "${CONTENT_DRIFT_FILES[@]}"; do
            echo "    ⚠ $f"
            diff_summary=$(diff \
                <(git show "$UPDATE_BRANCH:$f" 2>/dev/null) \
                <(git show "$FEATURE_BRANCH:$f" 2>/dev/null) \
                2>/dev/null | head -5 || true)
            if [ -n "$diff_summary" ]; then
                echo "$diff_summary" | sed 's/^/        /'
            fi
        done
        echo ""
        print_info "To see the full diff for a drifted file:"
        print_info "  git diff $UPDATE_BRANCH $FEATURE_BRANCH -- <file>"
    fi

    if [ ${#OVERLAP_FILES[@]} -gt 0 ]; then
        print_info "Cannot auto-verify ${#OVERLAP_FILES[@]} file(s) also modified by prior patches:"
        for f in "${OVERLAP_FILES[@]}"; do
            echo "    ℹ $f (also in patches 01-$(printf '%02d' $((10#$PATCH_NUM - 1))))"
        done
        echo ""
    fi

    verified_count=${#VERIFIABLE_FILES[@]}
    drift_count=${#CONTENT_DRIFT_FILES[@]}
    clean_count=$((verified_count - drift_count))

    if [ "$DRIFT_DETECTED" = false ]; then
        if [ "$verified_count" -gt 0 ]; then
            print_success "All $clean_count verifiable file(s) match $FEATURE_BRANCH — no drift detected"
        else
            print_info "All patch files overlap with prior patches — manual verification recommended"
        fi
    else
        print_warning "Drift detected. The patch may be missing feature branch changes."
        print_info "Review the warnings above. The patch was still generated and validated,"
        print_info "but you should investigate before committing."
    fi
else
    # No feature branch — skip drift check
    :
fi

#===============================================================================
# Step 9: Cleanup (handled by trap, but confirm here)
#===============================================================================

print_step "Cleanup"

SAVED_UPDATE_BRANCH="$UPDATE_BRANCH"
SAVED_BASELINE_BRANCH="$BASELINE_BRANCH"

if [ "$DRIFT_DETECTED" = true ]; then
    print_info "Keeping tmp branches for drift investigation (delete manually after):"
    echo "    $UPDATE_BRANCH"
    echo "    $BASELINE_BRANCH"
    echo "    To delete: git branch -D $UPDATE_BRANCH $BASELINE_BRANCH"
    # Prevent the trap from deleting them too
    UPDATE_BRANCH=""
    BASELINE_BRANCH=""
else
    git branch -D "$UPDATE_BRANCH" 2>/dev/null && echo "    Deleted $UPDATE_BRANCH" || true
    git branch -D "$BASELINE_BRANCH" 2>/dev/null && echo "    Deleted $BASELINE_BRANCH" || true
fi

# Pop our exact stash and mark as handled so trap doesn't double-pop
if [ "$DID_STASH" = true ] && [ -n "$STASH_SHA" ]; then
    _i=0; _found=""
    while git rev-parse --verify --quiet "stash@{$_i}" >/dev/null 2>&1; do
        if [ "$(git rev-parse "stash@{$_i}" 2>/dev/null)" = "$STASH_SHA" ]; then
            _found="stash@{$_i}"
            break
        fi
        _i=$((_i + 1))
    done
    if [ -n "$_found" ]; then
        if git stash pop "$_found"; then
            print_success "Restored stashed changes"
        else
            print_warning "Stash pop had conflicts. Your stash is preserved at: $_found"
            print_warning "Resolve conflicts, then: git stash drop $_found"
        fi
    fi
    DID_STASH=false
fi

if [ "$DRIFT_DETECTED" = true ]; then
    print_info "Cleanup complete (tmp branches preserved for drift investigation)"
else
    print_success "Cleanup complete (tmp branches deleted)"
fi

#===============================================================================
# Summary
#===============================================================================

echo ""
echo -e "${BOLD}=== Mid-stack update complete ===${NC}"
echo ""
echo "  Updated patch:     $PATCH_BASENAME"
echo "  Cherry-picked:     ${#CHERRY_PICK_SHAS[@]} commit(s)"
echo "  Files in patch:    ${#DIFF_FILES[@]}"
echo "  Stack validation:  $([ "$SKIP_TEST" = true ] && echo "SKIPPED" || echo "PASSED")"
echo "  Cleanup:           $([ "$DRIFT_DETECTED" = true ] && echo "BRANCHES PRESERVED (drift investigation)" || echo "COMPLETE (tmp branches deleted)")"
if [ -n "$FEATURE_BRANCH" ]; then
    if [ "$DRIFT_DETECTED" = true ]; then
        echo "  Drift check:       ⚠ DRIFT DETECTED — review warnings above"
    elif [ ${#INFRA_SKIP_FILES[@]} -gt 0 ]; then
        echo "  Drift check:       CLEAN (${#INFRA_SKIP_FILES[@]} infra file(s) excluded)"
    else
        echo "  Drift check:       CLEAN"
    fi
else
    echo "  Drift check:       SKIPPED (no feature branch specified)"
fi
echo ""
echo "  Next steps:"
echo "    1. Review: git diff patches/$PATCH_BASENAME"
if [ "$DRIFT_DETECTED" = true ]; then
    echo "    2. INVESTIGATE DRIFT: git diff $SAVED_UPDATE_BRANCH $FEATURE_BRANCH -- <file>"
    echo "    3. If drift is a bug: cherry-pick the missing commit and re-run this script"
    echo "    4. If drift is expected: proceed to commit"
else
    echo "    2. Commit: git add patches/$PATCH_BASENAME && git commit -m \"patches: update $PATCH_NAME\""
    echo "    3. Build:  ci/local-build.sh --base-branch dev --build-only"
fi
echo ""
