#!/usr/bin/env bash

#===============================================================================
# mid-stack-update.sh — Automate mid-stack patch updates (v1.10)
#
# CHANGELOG:
#   v1.10 - --scope-from-extra-files-only (with --from-feature-branch): build patch
#           scope from --extra-files only, ignoring paths listed in the committed patch.
#           Use when shrinking patch scope (e.g. drop project.pbxproj from a patch).
#         - --drift-exclude-regex: extended-regex paths to omit from the drift-check
#           "missing from patch" list (intentional exclusions).
#   v1.9  - After applying baseline patches, run `submodule sync` + `submodule update`
#           so gitlink commits match checked-out submodule SHAs (avoids spurious
#           submodule reversals when using --from-feature-branch with `git add -A`).
#         - --from-feature-branch: stage only PATCH_SCOPE_FILES instead of `git add -A`
#           so unrelated dirty submodule working trees cannot be committed.
#         - Detect paths on feature branch with `git ls-tree` (not `git show ref:path`),
#           which fails for submodule gitlinks ("bad object") and incorrectly deleted them.
#   v1.8  - --extra-files: trim leading/trailing whitespace only when
#           normalizing paths. Previously `tr -d '[:space:]'` removed ALL
#           spaces, breaking paths like `Trio Watch App Extension/Foo.swift`.
#   v1.7  - Auto-restore dirty target patch: when the target patch has
#           uncommitted modifications (common after a prior regeneration
#           was rolled back), restore the committed version automatically
#           instead of refusing to proceed. Untracked target patches still
#           error (mid-stack-update operates on existing patches only).
#         - Cherry-pick candidate auto-detection: when --cherry-pick is
#           omitted, enumerate commits on the feature branch since merge-base
#           with dev and print a suggested --cherry-pick command. Automates
#           the pre-flight step from AGENTS.md.
#         - Bash 3.2 empty-array safety: use ${arr[@]+"${arr[@]}"} pattern
#           for EXISTING_FILES, PATCH_SCOPE_FILES, and VERIFIABLE_FILES to
#           prevent "unbound variable" errors with set -u on empty arrays.
#   v1.6  Dirty baseline preservation: when baseline patches (01..N-1) have
#         uncommitted modifications, save them before stashing and restore
#         after so the baseline is built from the working-tree versions.
#         Without this, --from-feature-branch (and cherry-pick mode) would
#         build the baseline from stale committed patches, producing a patch
#         with wrong context lines that conflicts during full-stack apply.
#         Additional fixes:
#         - Clean only specific dirty patch files after baseline (not all of
#           patches/) to avoid clobbering unrelated changes.
#         - Clean dirty patches in main flow after validation, not just in
#           the trap handler, so stash pop doesn't conflict. Use
#           git checkout HEAD -- (commit, not index) for robustness.
#         - --from-feature-branch delete path: fall back to rm -f for
#           untracked files that git rm can't remove.
#         - Drift check: compare blob hashes (git rev-parse) instead of
#           loading full file contents into shell variables.
#         - Replace || true on git add -A with die on failure.
#         - Fix bash 3.2 empty-array expansion for EXTRA_FILE_LIST.
#   v1.5  Add --from-feature-branch: build update from feature branch tree
#         (checkout/delete patch-scope files) instead of apply patch + cherry-pick.
#         Use when patch baseline and feature branch have diverged (merge, rebase, amend).
#   v1.4  (previous)
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
#   --from-feature-branch
#       Build the update branch from the current state of the feature branch
#       (checkout or delete patch-scope files) instead of applying the current
#       patch and cherry-picking. Use when the patch baseline and feature branch
#       have diverged (e.g. merge into feature, then rebase/amend). Requires
#       --feature-branch or auto-detect. Ignores --cherry-pick. New files on the
#       feature branch that belong in this patch must be added via --extra-files.
#
#   --scope-from-extra-files-only
#       With --from-feature-branch and --extra-files: use ONLY the --extra-files
#       paths as patch scope (deduplicated). Ignores the file list from the current
#       patch on disk. Requires non-empty --extra-files.
#
#   --drift-exclude-regex <extended-regex>
#       During drift check, do not treat paths matching this regex as "missing from
#       patch" when they appear in dev...feature. Use for intentional omissions
#       (e.g. '^Trio\\.xcodeproj/project\\.pbxproj|^Trio/Sources/Modules/AppDiagnostics/').
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
#   --exclude-from-stash <paths>
#       Comma-separated paths to KEEP in the working tree (not stashed) for the
#       duration of the run, preserving their uncommitted state. Everything else is
#       stashed/restored as usual. Use when iterating on the tooling scripts
#       themselves (e.g. scripts/generate-patch.sh): the script otherwise stashes
#       your uncommitted edits, so the generate-patch.sh subprocess would run the
#       committed version. Intended for the dev worktree, where uncommitted changes
#       are tooling/docs/patches that don't conflict with the source git operations.
#       Example: --exclude-from-stash "scripts/generate-patch.sh,scripts/mid-stack-update.sh"
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
#   # Regenerate from current feature branch (no cherry-pick) after merge/amend
#   ./scripts/mid-stack-update.sh --patch 09 --from-feature-branch \
#       --feature-branch feature/watch-complication-improvements
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

# True if path exists at ref (submodules included). `git show ref:path` fails for
# gitlink paths ("bad object") on many Git versions; use ls-tree instead.
path_exists_in_tree() {
    local ref="$1" path="$2"
    [ -n "$(git ls-tree "$ref" -- "$path" 2>/dev/null)" ]
}

# Leading/trailing whitespace only — paths may contain internal spaces.
strip_outer_whitespace() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

#===============================================================================
# Argument parsing
#===============================================================================

PATCH_NUM=""
CHERRY_PICKS=""
EXTRA_FILES=""
FEATURE_BRANCH=""
FROM_FEATURE_BRANCH=false
SCOPE_FROM_EXTRA_FILES_ONLY=false
DRIFT_EXCLUDE_REGEX=""
NO_DRIFT_CHECK=false
DRY_RUN=false
SKIP_TEST=false
ALLOW_BEHIND_ORIGIN=false   # forwarded to generate-patch.sh to bypass its behind-origin guard
EXCLUDE_FROM_STASH=""       # comma-separated paths kept in the working tree (not stashed) during the run

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
        --from-feature-branch)
            FROM_FEATURE_BRANCH=true
            shift
            ;;
        --scope-from-extra-files-only)
            SCOPE_FROM_EXTRA_FILES_ONLY=true
            shift
            ;;
        --drift-exclude-regex)
            DRIFT_EXCLUDE_REGEX="$2"
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
        --allow-behind-origin)
            ALLOW_BEHIND_ORIGIN=true
            shift
            ;;
        --exclude-from-stash)
            EXCLUDE_FROM_STASH="$2"
            shift 2
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

# Cherry-pick requirement is checked later (after PATCH_DESC is available)
# so we can auto-detect candidates from the feature branch.
CHERRY_PICK_DEFERRED_CHECK=false
if [ "$DRY_RUN" = false ] && [ -z "$CHERRY_PICKS" ] && [ "$FROM_FEATURE_BRANCH" = false ]; then
    CHERRY_PICK_DEFERRED_CHECK=true
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
for f in ${EXISTING_FILES[@]+"${EXISTING_FILES[@]}"}; do
    echo "    $f"
done

# --- Provenance helpers (deterministic cherry-pick via recorded patch-ids) -----
# Stable patch-id of a single commit's diff (empty on failure). A patch-id hashes the
# diff content, so it is stable across rebase/amend — the canonical identity for
# "is this change already represented in the patch?".
_patch_id() {
    git show --no-color "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}'
}

# Extract patch-ids recorded in a patch file under the `Trio-Patch-Source-PatchIds:`
# trailer (one indented hex id per line until the block ends). Empty if none recorded.
_recorded_patch_ids() {
    awk '
        /^Trio-Patch-Source-PatchIds:[[:space:]]*$/ { cap=1; next }
        cap && /^[[:space:]]+[0-9a-f]{7,}[[:space:]]*$/ { gsub(/[[:space:]]/,""); print; next }
        cap { cap=0 }
    ' "$1" 2>/dev/null
}

# Branch name recorded in the patch's `Trio-Patch-Source-Branch:` trailer (empty if none).
_recorded_source_branch() {
    awk -F': ' '/^Trio-Patch-Source-Branch:[[:space:]]/ { print $2; exit }' "$1" 2>/dev/null
}

# When --cherry-pick is not provided, try to enumerate candidates from the
# feature branch. This automates the "pre-flight" step agents must otherwise
# do manually (see AGENTS.md § "Pre-flight: enumerate ALL new commits").
if [ "$CHERRY_PICK_DEFERRED_CHECK" = true ]; then
    _auto_branch=""
    if [ -n "$FEATURE_BRANCH" ]; then
        _auto_branch="$FEATURE_BRANCH"
    else
        _candidate="feature/$PATCH_DESC"
        if git rev-parse --verify "$_candidate" >/dev/null 2>&1; then
            _auto_branch="$_candidate"
        else
            # Canonical fallback: the branch recorded in the patch's provenance trailer.
            _rec_branch=$(_recorded_source_branch "$PATCH_FILE")
            if [ -n "$_rec_branch" ] && git rev-parse --verify "$_rec_branch" >/dev/null 2>&1; then
                _auto_branch="$_rec_branch"
            fi
        fi
    fi

    if [ -n "$_auto_branch" ]; then
        _merge_base=$(git merge-base dev "$_auto_branch" 2>/dev/null || true)
        if [ -n "$_merge_base" ]; then
            _all_shas=$(git log --reverse --format='%H' "$_merge_base..$_auto_branch" 2>/dev/null || true)
            if [ -n "$_all_shas" ]; then
                _recorded=$(_recorded_patch_ids "$PATCH_FILE")
                if [ -n "$_recorded" ]; then
                    # Deterministic: the new commits are exactly those on the feature branch
                    # whose patch-id is NOT already recorded in the patch (stable across rebase).
                    _new_shas=()
                    while read -r _c; do
                        [ -n "$_c" ] || continue
                        _pid=$(_patch_id "$_c")
                        if [ -n "$_pid" ] && printf '%s\n' "$_recorded" | grep -qx "$_pid"; then
                            continue
                        fi
                        _new_shas+=("$_c")
                    done <<< "$_all_shas"
                    echo ""
                    if [ "${#_new_shas[@]}" -eq 0 ]; then
                        print_success "Patch '$PATCH_BASENAME' is already up to date with '$_auto_branch' (0 new commits by patch-id). Nothing to cherry-pick."
                        exit 0
                    fi
                    print_info "New commits on '$_auto_branch' not yet in the patch (computed from recorded patch-id provenance):"
                    echo ""
                    for _c in "${_new_shas[@]}"; do echo "    $(git log -1 --format='%h %s' "$_c")"; done
                    echo ""
                    _shas=$(for _c in "${_new_shas[@]}"; do git rev-parse --short "$_c"; done | paste -sd, -)
                    print_info "Suggested command (new commits only, earliest first):"
                    echo "  ./scripts/mid-stack-update.sh --patch $PATCH_NUM --cherry-pick $_shas"
                    echo ""
                    die "Re-run with the --cherry-pick above (computed from the patch's recorded provenance)."
                fi
                # Legacy patch with no recorded provenance: list all; the human prunes.
                echo ""
                print_info "No --cherry-pick specified, and the patch has no recorded provenance. Commits on '$_auto_branch' since merge-base with dev:"
                echo ""
                git log --oneline --reverse "$_merge_base..$_auto_branch" 2>/dev/null | sed 's/^/    /'
                echo ""
                _shas=$(while read -r _c; do [ -n "$_c" ] && git rev-parse --short "$_c"; done <<< "$_all_shas" | paste -sd, -)
                print_info "Suggested command (ALL commits, earliest first — prune any already in the patch):"
                echo "  ./scripts/mid-stack-update.sh --patch $PATCH_NUM --cherry-pick $_shas"
                echo ""
                die "Review the commits above and provide --cherry-pick. Tip: regenerate this patch once with --from-feature-branch to record provenance and make future detection automatic."
            fi
        fi
    fi

    die "Missing required --cherry-pick <sha>. Use --dry-run to preview without changes,
  or --from-feature-branch to regenerate from feature branch state."
fi

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

if [ "$SCOPE_FROM_EXTRA_FILES_ONLY" = true ]; then
    [ "$FROM_FEATURE_BRANCH" = true ] || die "--scope-from-extra-files-only requires --from-feature-branch"
    [ ${#EXTRA_FILE_LIST[@]} -gt 0 ] || die "--scope-from-extra-files-only requires a non-empty --extra-files list"
fi

# Resolve feature branch for drift check (and for --from-feature-branch)
if [ "$NO_DRIFT_CHECK" = true ] && [ "$FROM_FEATURE_BRANCH" = false ]; then
    FEATURE_BRANCH=""
    print_info "Drift check: disabled (--no-drift-check)"
elif [ -z "$FEATURE_BRANCH" ]; then
    # Auto-detect: try feature/<patch-description>, then the recorded provenance branch.
    candidate="feature/$PATCH_DESC"
    _rec_b=$(_recorded_source_branch "$PATCH_FILE")
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
        FEATURE_BRANCH="$candidate"
        print_info "Drift check: auto-detected feature branch '$FEATURE_BRANCH'"
    elif [ -n "$_rec_b" ] && git rev-parse --verify "$_rec_b" >/dev/null 2>&1; then
        FEATURE_BRANCH="$_rec_b"
        print_info "Drift check: using feature branch '$FEATURE_BRANCH' from patch provenance"
    else
        if [ "$FROM_FEATURE_BRANCH" = true ]; then
            die "When using --from-feature-branch, a feature branch is required. Specify --feature-branch <branch> or ensure branch '$candidate' exists."
        fi
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

if [ "$FROM_FEATURE_BRANCH" = true ] && [ -n "$CHERRY_PICKS" ]; then
    print_info "Ignoring --cherry-pick when using --from-feature-branch."
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
    if [ "$FROM_FEATURE_BRANCH" = true ]; then
        echo "Mode:               --from-feature-branch (feature branch: ${FEATURE_BRANCH:-<required>})"
    fi
    echo ""
    echo "Planned steps:"
    echo "  1. Stash uncommitted changes (if any)"
    echo "  2. Create tmp/${PATCH_DESC}-baseline from dev + patches 01-$(printf '%02d' $((10#$PATCH_NUM - 1)))"
    if [ "$FROM_FEATURE_BRANCH" = true ]; then
        echo "  3. Create tmp/${PATCH_DESC}-update from baseline; checkout/delete patch-scope files from $FEATURE_BRANCH; single commit"
        echo "  4. git checkout dev"
        echo "  5. generate-patch.sh -n -s tmp/${PATCH_DESC}-update -t tmp/${PATCH_DESC}-baseline \\"
    else
        echo "  3. Create tmp/${PATCH_DESC}-update from baseline + $PATCH_BASENAME"
        if [ "${#CHERRY_PICK_SHAS[@]}" -gt 0 ]; then
            echo "  4. Cherry-pick ${#CHERRY_PICK_SHAS[@]} commit(s) and squash"
        fi
        echo "  5. git checkout dev"
        echo "  6. generate-patch.sh -n -s tmp/${PATCH_DESC}-update -t tmp/${PATCH_DESC}-baseline \\"
    fi
    extra_count=${#EXTRA_FILE_LIST[@]}
    echo "       -o patches/$PATCH_BASENAME --include-files <${#EXISTING_FILES[@]}+${extra_count} files> -y"
    echo "  $([ "$FROM_FEATURE_BRANCH" = true ] && echo "6" || echo "7"). patch-test.sh"
    if [ -n "$FEATURE_BRANCH" ]; then
        echo "  $([ "$FROM_FEATURE_BRANCH" = true ] && echo "7" || echo "8"). Drift check: compare patch files against $FEATURE_BRANCH"
    fi
    echo "  $([ "$FROM_FEATURE_BRANCH" = true ] && echo "8" || echo "9"). Cleanup tmp branches, pop stash"
    echo ""
    echo "Include-files list (${#EXISTING_FILES[@]} from patch + ${extra_count} extra):"
    for f in ${EXISTING_FILES[@]+"${EXISTING_FILES[@]}"}; do echo "    $f"; done
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
DIRTY_PATCHES_DIR=""
OWNED_OTHER_SNAPSHOT=""   # files owned by sibling patches (working-tree snapshot, taken pre-stash)
OWNED_PRIOR_SNAPSHOT=""   # subset owned by prior (baseline) patches
ORIGINAL_BRANCH="$CURRENT_BRANCH"

cleanup() {
    local exit_code=$?
    set +e

    cd "$REPO_ROOT" 2>/dev/null || true
    rm -f "${OWNED_OTHER_SNAPSHOT:-}" "${OWNED_PRIOR_SNAPSHOT:-}" 2>/dev/null || true

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

    # Revert dirty baseline patches before stash pop to avoid conflicts.
    # On the success path this was already done (DIRTY_PATCHES_DIR=""), so
    # this block only fires on early exit / die. Use HEAD to guarantee
    # restoration from the commit, not the index.
    if [ -n "${DIRTY_PATCHES_DIR:-}" ] && [ -d "${DIRTY_PATCHES_DIR:-}" ]; then
        for dp in "$DIRTY_PATCHES_DIR"/*.patch; do
            [ -f "$dp" ] || continue
            git checkout HEAD -- "patches/$(basename "$dp")" 2>/dev/null || true
        done
        rm -rf "$DIRTY_PATCHES_DIR"
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

# Handle uncommitted changes to the target patch file.
# The script will regenerate this file, so its current content doesn't matter —
# but stash-pop would conflict if the dirty version is in the stash.
PATCH_RELPATH="patches/$PATCH_BASENAME"
TARGET_PATCH_STATUS=$(git status --porcelain -- "$PATCH_RELPATH" 2>/dev/null || true)
if echo "$TARGET_PATCH_STATUS" | grep -qE '^.M|^M'; then
    # Modified (tracked): restore committed version so stash won't include it.
    # This is the common case when a prior regeneration was rolled back per
    # patch lifecycle (patches stay uncommitted on dev).
    print_info "Target patch has uncommitted changes (prior regeneration rolled back?)"
    print_info "Restoring committed version before proceeding..."
    git checkout -- "$PATCH_RELPATH" || die "Failed to restore committed version of $PATCH_RELPATH"
    print_success "Restored committed version of $PATCH_BASENAME"
elif echo "$TARGET_PATCH_STATUS" | grep -qE '^\?\?'; then
    # Untracked (new file): this is a new patch that was never committed.
    # mid-stack-update operates on existing patches; an untracked target is
    # unexpected. Die with a clear message.
    die "Target patch file is untracked (new): $PATCH_RELPATH
  mid-stack-update.sh updates existing patches. For a new patch that was
  previously generated but never committed, remove or move it aside first,
  then re-run."
fi

# Snapshot patch-ownership from the WORKING-TREE patch files BEFORE the stash reverts any
# uncommitted ones (e.g. an as-yet-uncommitted sibling phone patch). The drift check (P2a)
# and P2b consult these so files owned by an uncommitted sibling patch are attributed
# correctly — not false-flagged as "missing" or mis-poached. Cleaned up in cleanup().
OWNED_OTHER_SNAPSHOT=$(mktemp)
OWNED_PRIOR_SNAPSHOT=$(mktemp)
for _snp in "${ALL_PATCHES[@]}"; do
    _snpb=$(basename "$_snp")
    _snpv=$((10#${_snpb:0:2}))
    if [ "$_snpv" -eq "$((10#$PATCH_NUM))" ]; then continue; fi
    grep -E '^diff --git a/' "$_snp" 2>/dev/null | sed -E 's|^diff --git a/.+ b/(.+)$|\1|' >> "$OWNED_OTHER_SNAPSHOT" || true
    if [ "$_snpv" -lt "$((10#$PATCH_NUM))" ]; then
        grep -E '^diff --git a/' "$_snp" 2>/dev/null | sed -E 's|^diff --git a/.+ b/(.+)$|\1|' >> "$OWNED_PRIOR_SNAPSHOT" || true
    fi
done
sort -u "$OWNED_OTHER_SNAPSHOT" -o "$OWNED_OTHER_SNAPSHOT"
sort -u "$OWNED_PRIOR_SNAPSHOT" -o "$OWNED_PRIOR_SNAPSHOT"

# Build pathspec exclusions for --exclude-from-stash so the named files keep their
# working-tree state across the whole run (e.g. uncommitted edits to the tooling scripts
# themselves, which the generate-patch.sh subprocess reads fresh from disk — stashing them
# would silently revert the edits mid-run). Intended for the dev worktree, where uncommitted
# changes are tooling/docs/patches that don't conflict with the source-file git operations.
STASH_EXCLUDE_PATHSPECS=()
if [ -n "$EXCLUDE_FROM_STASH" ]; then
    IFS=',' read -ra _excl_list <<< "$EXCLUDE_FROM_STASH"
    for _e in "${_excl_list[@]}"; do
        _e="$(printf '%s' "$_e" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$_e" ] && STASH_EXCLUDE_PATHSPECS+=(":(exclude)$_e")
    done
    [ ${#STASH_EXCLUDE_PATHSPECS[@]} -gt 0 ] && print_info "Keeping in working tree (excluded from stash): $EXCLUDE_FROM_STASH"
fi

# "Stashable" = uncommitted changes remaining AFTER the exclusions. If only excluded files
# are dirty, there is nothing to stash and we proceed with them left in place.
if [ ${#STASH_EXCLUDE_PATHSPECS[@]} -gt 0 ]; then
    _stashable=$(git status --porcelain -- . "${STASH_EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true)
else
    _stashable=$(git status --porcelain 2>/dev/null || true)
fi

if [ -n "$_stashable" ]; then
    # Save dirty baseline patches BEFORE stashing. The stash reverts them to
    # committed state, but the baseline must use the working-tree versions so
    # the generated patch has correct context lines against the current stack.
    if [ ${#BASELINE_PATCHES[@]} -gt 0 ]; then
        for _bp in "${BASELINE_PATCHES[@]}"; do
            _bpname=$(basename "$_bp")
            _bprpath="patches/$_bpname"
            if git status --porcelain -- "$_bprpath" 2>/dev/null | grep -q .; then
                if [ -z "$DIRTY_PATCHES_DIR" ]; then
                    DIRTY_PATCHES_DIR=$(mktemp -d)
                    print_info "Saving dirty baseline patches for correct baseline build..."
                fi
                cp "$_bprpath" "$DIRTY_PATCHES_DIR/$_bpname"
                print_info "  Saved: $_bpname"
            fi
        done
    fi

    print_info "Stashing uncommitted changes..."
    if [ ${#STASH_EXCLUDE_PATHSPECS[@]} -gt 0 ]; then
        # Stash everything under the repo root EXCEPT the excluded pathspecs.
        git stash push -u -m "mid-stack-update: WIP before updating patch $PATCH_NUM" -- . "${STASH_EXCLUDE_PATHSPECS[@]}" || die "Failed to stash"
    else
        git stash -u -m "mid-stack-update: WIP before updating patch $PATCH_NUM" || die "Failed to stash"
    fi
    DID_STASH=true
    STASH_SHA=$(git rev-parse stash@{0} 2>/dev/null)
    print_success "Changes stashed (ref: ${STASH_SHA:0:8})"

    # Restore dirty baseline patches so baseline creation uses them
    if [ -n "$DIRTY_PATCHES_DIR" ] && [ -d "$DIRTY_PATCHES_DIR" ]; then
        for _dp in "$DIRTY_PATCHES_DIR"/*.patch; do
            [ -f "$_dp" ] || continue
            cp "$_dp" "patches/$(basename "$_dp")"
        done
        print_success "Restored dirty baseline patches into working tree"
    fi
elif [ ${#STASH_EXCLUDE_PATHSPECS[@]} -gt 0 ]; then
    print_success "Working tree is clean (after exclusions)"
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

# Baseline patches may update submodule gitlinks; ensure checkouts match the
# index so later `git add` cannot record a stale submodule HEAD (common when
# --from-feature-branch uses a narrow file list but `git add -A` was used).
if [ -f .gitmodules ]; then
    print_info "Syncing submodule checkouts after baseline patches..."
    git submodule sync --recursive 2>&1 | sed 's/^/    /' || true
    if ! git submodule update --init --recursive 2>&1 | sed 's/^/    /'; then
        print_warning "Submodule update after baseline failed; verify submodule SHAs before committing."
    fi
fi

# Clean up dirty baseline patches from the working tree now that git am has
# consumed their content. If left dirty, they leak into the baseline→update
# diff and get included in the generated patch as spurious changed files.
if [ -n "$DIRTY_PATCHES_DIR" ] && [ -d "$DIRTY_PATCHES_DIR" ]; then
    for _dp in "$DIRTY_PATCHES_DIR"/*.patch; do
        [ -f "$_dp" ] || continue
        git checkout HEAD -- "patches/$(basename "$_dp")" 2>/dev/null || true
    done
fi

#===============================================================================
# Step 3: Create update branch (baseline + current patch + cherry-picks, OR from feature branch)
#===============================================================================

print_step "Create update branch: $UPDATE_BRANCH"

git checkout -b "$UPDATE_BRANCH" "$BASELINE_BRANCH" || die "Failed to create $UPDATE_BRANCH"

if [ "$FROM_FEATURE_BRANCH" = true ]; then
    # Build update from current feature branch state for patch-scope files only
    # Use EXTRA_FILE_LIST (already parsed); ensure defined when --extra-files wasn't passed
    [ -z "${EXTRA_FILE_LIST+set}" ] && EXTRA_FILE_LIST=()
    if [ "$SCOPE_FROM_EXTRA_FILES_ONLY" = true ]; then
        PATCH_SCOPE_FILES=()
        _scope_seen=""
        for ef in "${EXTRA_FILE_LIST[@]}"; do
            ef_trimmed=$(strip_outer_whitespace "$ef")
            [ -n "$ef_trimmed" ] || continue
            case "$_scope_seen" in
                *"|$ef_trimmed|") continue ;;
            esac
            _scope_seen="${_scope_seen}|${ef_trimmed}|"
            PATCH_SCOPE_FILES+=("$ef_trimmed")
        done
        [ ${#PATCH_SCOPE_FILES[@]} -gt 0 ] || die "--scope-from-extra-files-only produced an empty path list"
        print_info "Patch scope (--scope-from-extra-files-only): ${#PATCH_SCOPE_FILES[@]} path(s); ignoring ${#EXISTING_FILES[@]} path(s) from current patch file list"
    else
        PATCH_SCOPE_FILES=(${EXISTING_FILES[@]+"${EXISTING_FILES[@]}"})
        if [ ${#EXTRA_FILE_LIST[@]} -gt 0 ]; then
            for ef in "${EXTRA_FILE_LIST[@]}"; do
                ef_trimmed=$(strip_outer_whitespace "$ef")
                [ -n "$ef_trimmed" ] && PATCH_SCOPE_FILES+=("$ef_trimmed")
            done
        fi

        # P2b: auto-include BRAND-NEW files added on the feature branch that no other patch
        # owns — so genuinely new source files aren't silently dropped (the build-206 class)
        # without needing --extra-files. Conservative on purpose: only files ABSENT on dev
        # (unambiguously new) are auto-added; files that exist on dev but were dropped stay
        # ambiguous and are caught fail-closed by the drift check (P2a).
        _p2b_feat_tmp=$(mktemp)
        git diff --name-only dev..."$FEATURE_BRANCH" 2>/dev/null > "$_p2b_feat_tmp" || true
        _p2b_added=0
        while IFS= read -r _ff; do
            [ -n "$_ff" ] || continue
            if git cat-file -e "dev:$_ff" 2>/dev/null; then continue; fi   # exists on dev → not brand-new
            _p2b_seen=false
            for _sf in ${PATCH_SCOPE_FILES[@]+"${PATCH_SCOPE_FILES[@]}"}; do
                if [ "$_sf" = "$_ff" ]; then _p2b_seen=true; break; fi
            done
            if [ "$_p2b_seen" = true ]; then continue; fi
            if grep -qxF "$_ff" "$OWNED_OTHER_SNAPSHOT"; then continue; fi   # owned by another patch (pre-stash snapshot)
            if is_infra_path "$_ff"; then continue; fi
            if [ -n "$DRIFT_EXCLUDE_REGEX" ] && printf '%s\n' "$_ff" | grep -Eq "$DRIFT_EXCLUDE_REGEX"; then continue; fi
            PATCH_SCOPE_FILES+=("$_ff")
            print_info "  Auto-included new feature-branch file (absent on dev): $_ff"
            _p2b_added=$((_p2b_added + 1))
        done < "$_p2b_feat_tmp"
        rm -f "$_p2b_feat_tmp"
        if [ "$_p2b_added" -gt 0 ]; then
            print_success "P2b: auto-included $_p2b_added new file(s) from $FEATURE_BRANCH (no --extra-files needed)"
        fi
    fi
    print_info "Syncing ${#PATCH_SCOPE_FILES[@]} file(s) from $FEATURE_BRANCH (checkout or delete)"
    for f in ${PATCH_SCOPE_FILES[@]+"${PATCH_SCOPE_FILES[@]}"}; do
        [ -n "$f" ] || continue
        if path_exists_in_tree "$FEATURE_BRANCH" "$f"; then
            git checkout "$FEATURE_BRANCH" -- "$f" 2>/dev/null || die "Failed to checkout $FEATURE_BRANCH -- $f"
            echo "    ✓ $f (checkout)"
        else
            if [ -f "$f" ] || git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
                if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
                    git rm -f "$f" 2>/dev/null || true
                else
                    rm -f "$f" 2>/dev/null || true
                fi
                echo "    ✓ $f (removed — deleted on feature branch)"
            fi
        fi
    done
    if git diff --staged --quiet 2>/dev/null && git diff --quiet 2>/dev/null; then
        die "No changes: patch-scope files already match $FEATURE_BRANCH. Nothing to regenerate."
    else
        # Stage only patch-scope paths (do not use `git add -A`: a submodule whose
        # working tree was never `submodule update`d can look "modified" vs the
        # new gitlink and would incorrectly be committed.)
        for f in ${PATCH_SCOPE_FILES[@]+"${PATCH_SCOPE_FILES[@]}"}; do
            [ -n "$f" ] || continue
            if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
                git add -f -- "$f" 2>/dev/null || die "Failed to stage: $f"
            fi
        done
        git commit -m "feat: $PATCH_DESC" || die "Failed to commit from-feature-branch state"
        print_success "Committed current state of patch-scope files from $FEATURE_BRANCH"
    fi
else
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
  Resolve the conflict interactively on the feature branch, then re-run.
  If the feature branch was merged or rebased/amended and no longer matches the patch baseline, re-run with --from-feature-branch and --feature-branch <branch> to regenerate the patch from the current feature branch state."
            else
                die "Failed to cherry-pick: $short"
            fi
        fi
        echo "    ✓ $short"
    done

    print_success "Cherry-picked ${#CHERRY_PICK_SHAS[@]} commit(s)"
fi

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
# EXTRA_FILE_LIST may be unset when --from-feature-branch was used without --extra-files
set +u
[ -z "${EXTRA_FILE_LIST+set}" ] && EXTRA_FILE_LIST=()
set -u
if [ ${#EXTRA_FILE_LIST[@]} -gt 0 ]; then
    for ef in "${EXTRA_FILE_LIST[@]}"; do
        ef_trimmed=$(strip_outer_whitespace "$ef")
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

# Build provenance trailers so the regenerated patch records exactly what feature-branch
# content it represents (source branch/base/tip + per-commit SHA and patch-id). This makes
# the next mid-stack update's cherry-pick set deterministic (see _recorded_patch_ids).
GEN_TRAILERS_FILE=""
GEN_TRAILERS_ARG=()
if [ -n "$FEATURE_BRANCH" ]; then
    _prov_mb=$(git merge-base dev "$FEATURE_BRANCH" 2>/dev/null || true)
    _prov_tip=$(git rev-parse "$FEATURE_BRANCH" 2>/dev/null || true)
    if [ -n "$_prov_mb" ] && [ -n "$_prov_tip" ]; then
        GEN_TRAILERS_FILE=$(mktemp)
        {
            echo "Trio-Patch-Source-Branch: $FEATURE_BRANCH"
            echo "Trio-Patch-Base: $_prov_mb"
            echo "Trio-Patch-Feature-Tip: $_prov_tip"
            echo "Trio-Patch-Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Trio-Patch-Source-Commits:"
            git log --reverse --format=' %H %s' "$_prov_mb..$_prov_tip" 2>/dev/null
            echo "Trio-Patch-Source-PatchIds:"
            git log --reverse --format='%H' "$_prov_mb..$_prov_tip" 2>/dev/null | while read -r _pc; do
                [ -n "$_pc" ] || continue
                _ppid=$(_patch_id "$_pc")
                [ -n "$_ppid" ] && echo " $_ppid"
            done
        } > "$GEN_TRAILERS_FILE"
        GEN_TRAILERS_ARG=(--message-trailers-file "$GEN_TRAILERS_FILE")
        print_info "Provenance: recording $(git rev-list --count "$_prov_mb..$_prov_tip" 2>/dev/null || echo '?') source commit(s) from '$FEATURE_BRANCH'."
    fi
fi

GEN_ALLOW_BEHIND=()
[ "$ALLOW_BEHIND_ORIGIN" = true ] && GEN_ALLOW_BEHIND=(--allow-behind-origin)
if ! "$REPO_ROOT/scripts/generate-patch.sh" -n \
    -s "$UPDATE_BRANCH" \
    -t "$BASELINE_BRANCH" \
    -d "$PATCH_DESC" \
    -o "$PATCH_OUTPUT_ABS" \
    --include-files "$INCLUDE_FILES_ARG" \
    ${GEN_ALLOW_BEHIND[@]+"${GEN_ALLOW_BEHIND[@]}"} \
    ${GEN_TRAILERS_ARG[@]+"${GEN_TRAILERS_ARG[@]}"} \
    -y; then
    rm -f "$GEN_TRAILERS_FILE"
    die "generate-patch.sh failed. Check output above for details."
fi
rm -f "$GEN_TRAILERS_FILE"

print_success "Patch regenerated: $PATCH_BASENAME"

# P2c: file-count regression note — surface when the regenerated patch touches fewer files
# than the committed version (a cheap "something may have been dropped" signal; the hard
# guarantee is the fail-closed drift check below).
_p2c_prev=$(git show "HEAD:patches/$PATCH_BASENAME" 2>/dev/null | grep -cE '^diff --git a/') || _p2c_prev=0
_p2c_new=$(grep -cE '^diff --git a/' "patches/$PATCH_BASENAME" 2>/dev/null) || _p2c_new=0
if [ "$_p2c_new" -lt "$_p2c_prev" ]; then
    print_warning "File count dropped: regenerated patch has $_p2c_new file(s) vs $_p2c_prev committed — verify nothing was unintentionally omitted (the drift check below fails closed on dropped files)."
else
    print_info "File count: $_p2c_new (committed: $_p2c_prev)"
fi

#===============================================================================
# Step 7: Validate full patch stack
#===============================================================================

if [ "$SKIP_TEST" = true ]; then
    print_step "Validate patch stack (SKIPPED — not recommended)"
    print_warning "Patch validation was skipped. Run manually: scripts/patch-test.sh"
else
    print_step "Validate full patch stack"

    # Re-restore dirty baseline patches so patch-test.sh (which copies from
    # patches/) validates the full stack with the correct baseline patches.
    # They were cleaned from the working tree after baseline creation to avoid
    # leaking into the generated patch.
    if [ -n "$DIRTY_PATCHES_DIR" ] && [ -d "$DIRTY_PATCHES_DIR" ]; then
        for _dp in "$DIRTY_PATCHES_DIR"/*.patch; do
            [ -f "$_dp" ] || continue
            cp "$_dp" "patches/$(basename "$_dp")"
        done
    fi

    if ! "$REPO_ROOT/scripts/patch-test.sh"; then
        die "Patch validation failed! The updated patch does not apply cleanly in the full stack.
  Check the output above for which patch failed and why."
    fi

    print_success "All ${#ALL_PATCHES[@]} patches apply cleanly"
fi

# Clean up re-restored dirty baseline patches now that validation is done.
# Must happen here (not just in cleanup handler) so the working tree is clean
# when stash pop runs — otherwise the dirty patch files conflict with the
# stash's version of the same files.
if [ -n "$DIRTY_PATCHES_DIR" ] && [ -d "$DIRTY_PATCHES_DIR" ]; then
    for _dp in "$DIRTY_PATCHES_DIR"/*.patch; do
        [ -f "$_dp" ] || continue
        git checkout HEAD -- "patches/$(basename "$_dp")" 2>/dev/null || true
    done
    rm -rf "$DIRTY_PATCHES_DIR"
    DIRTY_PATCHES_DIR=""
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
    # Use the pre-stash working-tree ownership snapshots (Step 1) so uncommitted sibling
    # patches are attributed correctly — post-stash, on-disk siblings can be stale committed
    # versions. See OWNED_OTHER_SNAPSHOT / OWNED_PRIOR_SNAPSHOT.
    OTHER_PATCH_FILES_SORTED=$(cat "$OWNED_OTHER_SNAPSHOT" 2>/dev/null || true)
    PRIOR_PATCH_FILES_SORTED=$(cat "$OWNED_PRIOR_SNAPSHOT" 2>/dev/null || true)

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
        # Skip paths intentionally excluded from this patch (narrower scope)
        if [ -n "$DRIFT_EXCLUDE_REGEX" ] && printf '%s\n' "$ff" | grep -Eq "$DRIFT_EXCLUDE_REGEX"; then
            continue
        fi
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
    for f in ${VERIFIABLE_FILES[@]+"${VERIFIABLE_FILES[@]}"}; do
        update_blob=$(git rev-parse "$UPDATE_BRANCH:$f" 2>/dev/null) || continue
        feature_blob=$(git rev-parse "$FEATURE_BRANCH:$f" 2>/dev/null) || continue
        if [ "$update_blob" != "$feature_blob" ]; then
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
            diff_summary=$(git diff "$UPDATE_BRANCH" "$FEATURE_BRANCH" -- "$f" 2>/dev/null | head -5 || true)
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
        print_warning "Drift detected. Review the warnings above before committing."
    fi

    # P2a: FAIL CLOSED on genuinely-dropped files. A file the feature branch changed that is
    # absent from the regenerated patch (and not --drift-exclude'd / owned by another patch /
    # infra) is the build-206 failure class — never let it ship silently.
    if [ ${#MISSING_FILES[@]} -gt 0 ]; then
        echo ""
        _extra_suggest=$(printf '%s,' "${MISSING_FILES[@]}" | sed 's/,$//')
        die "FATAL (fail-closed): ${#MISSING_FILES[@]} file(s) changed on $FEATURE_BRANCH are MISSING from the regenerated patch (see the ⚠ list above).
  The regenerated patch is INCOMPLETE — do NOT commit it. Re-run with one of:
    - include them:            --extra-files \"$_extra_suggest\"
    - intentionally narrower:  --drift-exclude-regex '<regex>'
    - skip the check:          --no-drift-check
  (tmp branches are preserved for investigation.)"
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
if [ "$FROM_FEATURE_BRANCH" = true ]; then
    echo "  Source:            feature branch ($FEATURE_BRANCH)"
else
    echo "  Cherry-picked:     ${#CHERRY_PICK_SHAS[@]} commit(s)"
fi
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
