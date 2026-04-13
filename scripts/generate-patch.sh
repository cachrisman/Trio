#!/usr/bin/env bash

#===============================================================================
# generate-patch.sh - Generate patch files by comparing git branches
#
# DESCRIPTION:
#   This script generates patch files by comparing two git branches. It supports
#   both interactive mode (prompts for all options) and non-interactive mode
#   (via command-line flags).
#
#   The script:
#   1. Compares a source branch against a target branch (default: dev)
#   2. Lists all files that differ between the branches
#   3. Allows selection of which files to include in the patch
#   4. Generates a patch file with an auto-incrementing two-digit prefix (XY-)
#   5. Validates the patch file using git apply --check
#
#   Patch files are named using the format: XY-<description>.patch
#   where XY is the next sequential two-digit number after existing patches.
#
# USAGE:
#   Interactive mode (default):
#     ./generate-patch.sh
#
#   Non-interactive mode (specify options via flags):
#     ./generate-patch.sh [OPTIONS]
#
# OPTIONS:
#   -s, --source-branch <branch>
#       Source branch containing changes to include in patch.
#       Default: current branch (if not 'dev'), or most recent non-dev branch.
#
#   -t, --target-branch <branch>
#       Target branch where patch will be applied.
#       Default: 'dev'
#
#   -d, --description <text>
#       Short description for the patch filename (e.g., "fix-crash").
#       Spaces and special characters are converted to dashes.
#       Default: prompts interactively or uses source branch name.
#
#   --all-files
#       Include all changed files in the patch (skip file selection prompt).
#       Must be specified explicitly (not implied by -n).
#
#   -f, --files <selection>
#       [Interactive mode] Specify files by number (e.g., "1 3 5-7" or "all").
#       Default: prompts interactively.
#
#   --include-files <paths>
#       [Non-interactive mode] Comma-separated list of file paths to include.
#       Only these files will be included in the patch (must be in the diff).
#       Supports glob patterns (e.g., "*.swift,Model/*.swift").
#       Example: --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"
#
#   --exclude-files <paths>
#       Comma-separated list of file paths/patterns to exclude from the patch.
#       Applied after --include-files or --all-files. Supports glob patterns.
#       Example: --exclude-files "*.md,*.json,*Test*"
#
#   -w, --include-worktree
#       Include uncommitted (staged + unstaged) changes in the patch.
#       Only valid when source branch is the current branch.
#
#   -W, --no-include-worktree
#       Exclude uncommitted changes (only include committed changes).
#
#   -o, --output <path>
#       Full output path for the patch file.
#       Overrides automatic naming with XY- prefix.
#
#   -y, --yes
#       Auto-confirm prompts (e.g., overwrite existing files).
#
#   -n, --non-interactive
#       Run in fully non-interactive mode. Uses defaults for any
#       unspecified options. Sets -W (no worktree changes) and -y (auto-confirm).
#       Requires one of: --all-files, --include-files, or --exclude-files.
#
#   -h, --help
#       Show this help message and exit.
#
# EXAMPLES:
#   # Interactive mode - prompts for everything
#   ./generate-patch.sh
#
#   # Generate patch from feature branch to dev, include all files
#   ./generate-patch.sh -s feature/my-feature -t dev --all-files -d "my-feature"
#
#   # Fully non-interactive with custom description (all files)
#   ./generate-patch.sh -n --all-files -d "fix-watch-crash"
#
#   # Include uncommitted changes, auto-confirm overwrites
#   ./generate-patch.sh -w -y -d "wip-changes"
#
#   # [Interactive] Specify files by number
#   ./generate-patch.sh -f "1 3 5-7" -d "selected-fixes"
#
#   # [Non-interactive/AI Agent] Include specific files by path
#   ./generate-patch.sh -n -d "my-fix" \
#       --include-files "Trio/Sources/Foo.swift,Model/Bar.swift"
#
#   # [Non-interactive/AI Agent] All files except certain patterns
#   ./generate-patch.sh -n -d "code-only" \
#       --exclude-files "*.md,*.json,*Test*"
#
# PATCH NAMING:
#   Patches are automatically named with a two-digit prefix (XY-) that
#   increments based on existing patches in ./patches/. For example:
#     - If no patches exist: 01-<description>.patch
#     - If 01-foo.patch exists: 02-<description>.patch
#     - If 05-bar.patch is highest: 06-<description>.patch
#
#   The prefix ensures deterministic alphabetical ordering when patches
#   are applied during builds.
#
# OUTPUT:
#   - Patch file saved to ./patches/XY-<description>.patch (or custom -o path)
#   - Validation results showing if patch applies cleanly
#
# SEE ALSO:
#   - AGENTS.md for patch workflow documentation
#   - ./ci/local_build_script.sh for how patches are applied during builds
#
#===============================================================================

# TODO: Consider dropping or de-emphasizing the "patch starts with diff/---/+++" format check since `git apply --check` is the authoritative validation.

set -euo pipefail

ORIGINAL_ARGS=("$@")

# Make arrays behave similarly in zsh
if [ -n "${ZSH_VERSION-}" ]; then
    setopt KSH_ARRAYS
fi

#===============================================================================
# Command-line argument parsing
#===============================================================================

# Default values for flags
FLAG_SOURCE_BRANCH=""
FLAG_TARGET_BRANCH=""
FLAG_DESCRIPTION=""
FLAG_ALL_FILES=false
FLAG_FILES_SELECTION=""      # For interactive mode (numbers like "1 3 5-7")
FLAG_INCLUDE_FILES=""        # For non-interactive mode (comma-separated paths)
FLAG_EXCLUDE_FILES=""        # Exclusion patterns (comma-separated)
FLAG_INCLUDE_WORKTREE=""     # "" = prompt, "true" = yes, "false" = no
FLAG_OUTPUT_PATH=""
FLAG_YES=false
FLAG_NON_INTERACTIVE=false

show_help() {
    # Extract and display the header documentation
    # Start at line 3 (opening #===), stop at the closing #=== line
    # Use awk for portability (BSD head doesn't support negative line counts)
    awk '
        NR >= 3 && /^#===/ { 
            count++
            if (count == 2) exit
        }
        NR >= 3 { sub(/^# ?/, ""); print }
    ' "$0"
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source-branch)
            FLAG_SOURCE_BRANCH="$2"
            shift 2
            ;;
        -t|--target-branch)
            FLAG_TARGET_BRANCH="$2"
            shift 2
            ;;
        -d|--description)
            FLAG_DESCRIPTION="$2"
            shift 2
            ;;
        --all-files)
            FLAG_ALL_FILES=true
            shift
            ;;
        -f|--files)
            FLAG_FILES_SELECTION="$2"
            shift 2
            ;;
        --include-files)
            FLAG_INCLUDE_FILES="$2"
            shift 2
            ;;
        --exclude-files)
            FLAG_EXCLUDE_FILES="$2"
            shift 2
            ;;
        -w|--include-worktree)
            FLAG_INCLUDE_WORKTREE="true"
            shift
            ;;
        -W|--no-include-worktree)
            FLAG_INCLUDE_WORKTREE="false"
            shift
            ;;
        -o|--output)
            FLAG_OUTPUT_PATH="$2"
            shift 2
            ;;
        -y|--yes)
            FLAG_YES=true
            shift
            ;;
        -n|--non-interactive)
            FLAG_NON_INTERACTIVE=true
            FLAG_INCLUDE_WORKTREE="false"
            FLAG_YES=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
    esac
done

#===============================================================================
# Helper functions
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Die function for error handling
die() {
    print_error "$1"
    exit 1
}

shell_quote_args() {
  local out=""
  local arg
  for arg in "$@"; do
    out+=" $(printf '%q' "$arg")"
  done
  printf '%s' "$out"
}

# Check for required commands
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Function to get the next patch prefix number
get_next_patch_prefix() {
    local patches_dir="$1"
    local highest=0
    
    if [ -d "$patches_dir" ]; then
        # Find the highest existing two-digit prefix
        for patch_file in "$patches_dir"/*.patch; do
            [ -f "$patch_file" ] || continue
            local basename=$(basename "$patch_file")
            # Extract leading two-digit prefix if present
            if [[ "$basename" =~ ^([0-9]{2})- ]]; then
                local num="${BASH_REMATCH[1]}"
                # Remove leading zeros for comparison
                num=$((10#$num))
                if [ "$num" -gt "$highest" ]; then
                    highest="$num"
                fi
            fi
        done
    fi
    
    # Return next number, zero-padded to 2 digits
    printf '%02d' $((highest + 1))
}

assert_unique_patch_prefixes() {
  local patches_dir="$1"
  [ -d "$patches_dir" ] || return 0
  local dupes
  dupes=$(ls -1 "$patches_dir"/*.patch 2>/dev/null \
    | sed -E 's#.*/([0-9]{2})-.*\\.patch$#\\1#' \
    | awk 'NF{c[$1]++} END{for (k in c) if (c[k]>1) print k":"c[k]}' \
    | sort || true)
  if [ -n "$dupes" ]; then
    print_error "Duplicate patch number(s) detected (multiple files share the same NN- prefix)."
    echo "$dupes" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      nn=${line%%:*}
      print_info "Files with prefix ${nn}-:"
      ls -1 "$patches_dir/${nn}-"*.patch 2>/dev/null || true
    done
    print_info "Fix by renaming/removing duplicates so each NN prefix is unique."
    exit 1
  fi
}

# Function to sanitize a string for use in filename
sanitize_for_filename() {
    local input="$1"
    # Replace spaces, slashes, and other special chars with dashes
    # Remove leading/trailing dashes, collapse multiple dashes
    printf '%s' "$input" | \
        sed 's#[^A-Za-z0-9._-]#-#g' | \
        sed 's/--*/-/g' | \
        sed 's/^-//' | \
        sed 's/-$//'
}

# Function to check if a file path matches a pattern (supports simple globs)
# Returns 0 if match, 1 if no match
path_matches_pattern() {
    local path="$1"
    local pattern="$2"
    
    # Handle exact match first
    if [ "$path" = "$pattern" ]; then
        return 0
    fi
    
    # Use bash pattern matching for glob support
    # shellcheck disable=SC2254
    case "$path" in
        $pattern) return 0 ;;
    esac
    
    # Also try matching just the basename
    local basename
    basename=$(basename "$path")
    # shellcheck disable=SC2254
    case "$basename" in
        $pattern) return 0 ;;
    esac
    
    return 1
}

# Function to check if a path should be included based on include/exclude patterns
# Args: path, include_patterns (comma-sep), exclude_patterns (comma-sep)
# Returns 0 if should include, 1 if should exclude
should_include_path() {
    local path="$1"
    local include_patterns="$2"
    local exclude_patterns="$3"
    
    # If include patterns specified, path must match at least one
    if [ -n "$include_patterns" ]; then
        local matched=false
        IFS=',' read -ra patterns <<< "$include_patterns"
        for pattern in "${patterns[@]}"; do
            # Trim whitespace
            pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$pattern" ] && continue
            if path_matches_pattern "$path" "$pattern"; then
                matched=true
                break
            fi
        done
        if [ "$matched" = false ]; then
            return 1
        fi
    fi
    
    # Check exclude patterns
    if [ -n "$exclude_patterns" ]; then
        IFS=',' read -ra patterns <<< "$exclude_patterns"
        for pattern in "${patterns[@]}"; do
            # Trim whitespace
            pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$pattern" ] && continue
            if path_matches_pattern "$path" "$pattern"; then
                return 1
            fi
        done
    fi
    
    return 0
}

#===============================================================================
# Validate: non-interactive mode requires explicit file selection
#===============================================================================

if [ "$FLAG_NON_INTERACTIVE" = true ] && [ "$FLAG_ALL_FILES" = false ] \
    && [ -z "$FLAG_INCLUDE_FILES" ] && [ -z "$FLAG_EXCLUDE_FILES" ]; then
    print_error "Non-interactive mode (-n) requires explicit file selection."
    echo "" >&2
    echo "  Use one of:" >&2
    echo "    --all-files                Include all changed files" >&2
    echo "    --include-files <paths>    Include specific files (comma-separated paths/globs)" >&2
    echo "    --exclude-files <paths>    Exclude specific files (comma-separated paths/globs)" >&2
    echo "" >&2
    echo "  Examples:" >&2
    echo "    ./scripts/generate-patch.sh -n -d \"my-fix\" --all-files" >&2
    echo "    ./scripts/generate-patch.sh -n -d \"my-fix\" --include-files \"Trio/Sources/Foo.swift\"" >&2
    echo "    ./scripts/generate-patch.sh -n -d \"my-fix\" --exclude-files \"*.md,*.json\"" >&2
    echo "" >&2
    exit 1
fi

#===============================================================================
# Main script
#===============================================================================

need_cmd git
need_cmd awk
need_cmd sed
need_cmd mktemp
need_cmd date

# Check if we're in a git repository
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
git rev-parse --verify "HEAD^{commit}" >/dev/null 2>&1 || die "HEAD is not a commit"

# Enforce dev worktree execution to avoid stale tooling
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_BASENAME=$(basename "$REPO_ROOT")
if [ "$REPO_BASENAME" != "Trio-dev" ]; then
  print_error "This script must be run from the dev worktree (recommended path: ../Trio-dev)."
  print_info "Re-run from the dev worktree with the same arguments:"
  echo ""
  echo "  cd ../Trio-dev && ./scripts/generate-patch.sh$(shell_quote_args ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"})"
  echo ""
  exit 1
fi

# Ensure dev baseline is current
if ! git fetch origin dev >/dev/null 2>&1; then
  print_error "Failed to fetch origin/dev (required to ensure dev baseline is current)."
  print_info "Run: git fetch origin dev"
  exit 1
fi
behind_count=$(git rev-list --count dev..origin/dev 2>/dev/null || echo 0)
if [ "$behind_count" -gt 0 ]; then
  print_error "Local dev is behind origin/dev by ${behind_count} commit(s)."
  print_info "Update the dev worktree and retry:"
  echo ""
  echo "  git checkout dev && git pull --ff-only origin dev"
  echo ""
  exit 1
fi

# Get work branch (where script is running / HEAD)
WORK_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
if [ "$WORK_BRANCH" = "HEAD" ]; then
    die "Detached HEAD; switch to a branch"
fi

print_info "Current branch (where script is running): ${WORK_BRANCH}"

# Initialize branch variables
TARGET_BRANCH=""
SOURCE_BRANCH=""

# Handle target branch (from flag or interactive)
if [ -n "$FLAG_TARGET_BRANCH" ]; then
    TARGET_BRANCH="$FLAG_TARGET_BRANCH"
    git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" || die "Target branch not found: $TARGET_BRANCH"
fi

# Handle source branch (from flag or interactive)
if [ -n "$FLAG_SOURCE_BRANCH" ]; then
    SOURCE_BRANCH="$FLAG_SOURCE_BRANCH"
    git show-ref --verify --quiet "refs/heads/$SOURCE_BRANCH" || die "Source branch not found: $SOURCE_BRANCH"
fi

# If both branches specified via flags, skip interactive selection
if [ -n "$TARGET_BRANCH" ] && [ -n "$SOURCE_BRANCH" ]; then
    print_info "Using branches from command line flags"
elif [ "$FLAG_NON_INTERACTIVE" = true ]; then
    # Non-interactive mode: use defaults
    if [ -z "$TARGET_BRANCH" ]; then
        TARGET_BRANCH="dev"
        git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" || die "Default target branch 'dev' not found"
    fi
    if [ -z "$SOURCE_BRANCH" ]; then
        if [ "$WORK_BRANCH" != "dev" ]; then
            SOURCE_BRANCH="$WORK_BRANCH"
        else
            SOURCE_BRANCH=$(git for-each-ref --sort=-committerdate refs/heads/ \
                --format='%(refname:short)' \
                | awk '$0 != "dev"' \
                | head -1)
            [ -n "$SOURCE_BRANCH" ] || die "No non-dev branch found for source"
        fi
    fi
    print_info "Non-interactive mode: source='${SOURCE_BRANCH}', target='${TARGET_BRANCH}'"
else
    # Interactive branch selection (original logic)
    if [ -z "$TARGET_BRANCH" ] && [ -z "$SOURCE_BRANCH" ]; then
        if [ "$WORK_BRANCH" = "dev" ]; then
            default_target="dev"
            candidate_source=$(git for-each-ref --sort=-committerdate refs/heads/ \
                --format='%(refname:short)' \
                | awk '$0 != "dev"' \
                | head -1)
            
            if [ -n "$candidate_source" ]; then
                echo ""
                print_info "On dev; assuming target '${default_target}' and source '${candidate_source}'."
                read -p "Use these branches? [Y/n]: " use_defaults
                if [[ ! "$use_defaults" =~ ^[nN]$ ]]; then
                    TARGET_BRANCH="$default_target"
                    SOURCE_BRANCH="$candidate_source"
                fi
            else
                print_warning "No other branches found besides dev; select branches manually."
            fi
        else
            default_target="dev"
            candidate_target=""
            if git show-ref --verify --quiet "refs/heads/${default_target}"; then
                candidate_target="$default_target"
            fi
            if [ -n "$candidate_target" ]; then
                echo ""
                print_info "Assuming source '${WORK_BRANCH}' (current) and target '${candidate_target}'."
                read -p "Use these branches? [Y/n]: " use_defaults
                if [[ ! "$use_defaults" =~ ^[nN]$ ]]; then
                    SOURCE_BRANCH="$WORK_BRANCH"
                    TARGET_BRANCH="$candidate_target"
                fi
            else
                print_warning "Target branch 'dev' not found; select branches manually."
            fi
        fi
    fi

    # Interactive target branch selection if not set
    if [ -z "$TARGET_BRANCH" ]; then
        echo ""
        print_info "Select target branch:"
        echo ""
        
        ALL_BRANCHES=$(git for-each-ref --sort=-committerdate refs/heads/ \
            --format='%(refname:short)')
        
        TARGET_BRANCH_ARRAY=()
        while IFS= read -r branch; do
            [ -n "$branch" ] || continue
            TARGET_BRANCH_ARRAY+=("$branch")
        done <<< "$ALL_BRANCHES"
        
        if [ "${#TARGET_BRANCH_ARRAY[@]}" -eq 0 ]; then
            print_error "No local branches found"
            exit 1
        fi
        
        select target_choice in "${TARGET_BRANCH_ARRAY[@]}" "Enter another local branch…"; do
            if [ -z "${target_choice-}" ]; then
                print_error "Invalid selection"
                continue
            fi
            if [ "$target_choice" = "Enter another local branch…" ]; then
                printf 'Enter local branch name: '
                IFS= read -r target_choice
                target_choice="${target_choice//[$'\r\n']/}"
            fi
            break
        done
        
        [ -n "${target_choice-}" ] || die "No target branch selected"
        git show-ref --verify --quiet "refs/heads/$target_choice" || die "Not a local branch: $target_choice"
        
        TARGET_BRANCH="$target_choice"
    fi

    # Interactive source branch selection if not set
    if [ -z "$SOURCE_BRANCH" ]; then
        print_info "Fetching branches..."
        ALL_BRANCHES=$(git for-each-ref --sort=-committerdate refs/heads/ \
            --format='%(refname:short)' \
            | awk -v target="$TARGET_BRANCH" '$0 != target')
        
        if [ -z "$ALL_BRANCHES" ]; then
            print_error "No other branches found to compare"
            exit 1
        fi
        
        echo ""
        print_info "Select source branch (branch with changes to include in patch):"
        print_info "Target branch: ${TARGET_BRANCH} (where patch will be applied)"
        echo ""
        
        BRANCH_ARRAY=()
        while IFS= read -r branch; do
            [ -n "$branch" ] || continue
            BRANCH_ARRAY+=("$branch")
        done <<< "$ALL_BRANCHES"
        
        select base in "${BRANCH_ARRAY[@]}" "Enter another local branch…"; do
            if [ -z "${base-}" ]; then
                print_error "Invalid selection"
                continue
            fi
            if [ "$base" = "Enter another local branch…" ]; then
                printf 'Enter local branch name: '
                IFS= read -r base
                base="${base//[$'\r\n']/}"
            fi
            break
        done
        
        [ -n "${base-}" ] || die "No source branch selected"
        SOURCE_BRANCH="$base"
    fi
fi

git show-ref --verify --quiet "refs/heads/$SOURCE_BRANCH" || die "Not a local branch: $SOURCE_BRANCH"
[ "$SOURCE_BRANCH" != "$TARGET_BRANCH" ] || die "Source branch equals target branch; nothing to patch"

print_info "Target branch set to: ${TARGET_BRANCH}"
print_info "Selected source branch: ${SOURCE_BRANCH}"

# Handle include worktree option
include_worktree="false"
if [ "$WORK_BRANCH" = "$SOURCE_BRANCH" ]; then
    status_output=$(git status --porcelain=v1 --untracked-files=all)
    has_uncommitted="false"
    has_untracked="false"
    if [ -n "$status_output" ]; then
        has_uncommitted="true"
    fi
    if printf '%s\n' "$status_output" | grep -q '^?? '; then
        has_untracked="true"
    fi

    if [ -n "$FLAG_INCLUDE_WORKTREE" ]; then
        # Use flag value
        include_worktree="$FLAG_INCLUDE_WORKTREE"
        if [ "$include_worktree" = "true" ] && [ "$has_uncommitted" = "false" ]; then
            print_warning "No uncommitted changes to include, but proceeding with worktree mode"
        fi
    else
        # Interactive prompt
        echo ""
        if [ "$has_uncommitted" = "true" ]; then
            if [ "$has_untracked" = "true" ]; then
                print_info "Working tree has uncommitted changes (including untracked files)"
            else
                print_info "Working tree has uncommitted changes (staged and/or unstaged)"
            fi
        else
            print_info "Working tree is clean (no uncommitted or untracked changes)"
        fi
        read -p "Include staged + unstaged changes in the patch? [Y/n]: " ans
        case "${ans:-}" in
            ""|y|Y|yes|YES) 
                if [ "$has_uncommitted" = "false" ]; then
                    print_warning "No uncommitted changes to include, but proceeding with worktree mode"
                fi
                include_worktree="true" 
                ;;
            *) 
                include_worktree="false" 
                ;;
        esac
    fi
else
    if [ "$FLAG_INCLUDE_WORKTREE" = "true" ]; then
        print_warning "Cannot include worktree changes: current branch (${WORK_BRANCH}) differs from source branch (${SOURCE_BRANCH})"
    fi
    print_info "Cannot include uncommitted changes because current branch (${WORK_BRANCH}) differs from source branch (${SOURCE_BRANCH})"
fi

if [ "$include_worktree" = "true" ] && [ "$WORK_BRANCH" != "$SOURCE_BRANCH" ]; then
    print_warning "Falling back to committed-only changes because script is not running on source branch"
    include_worktree="false"
fi

# Build diff commands based on whether to include worktree
# We want a patch from SOURCE_BRANCH that can be applied to TARGET_BRANCH
# Correct diff direction:
# - Committed-only: TARGET_BRANCH..SOURCE_BRANCH (what's in SOURCE that's not in TARGET)
# - Include worktree: Only if on SOURCE_BRANCH, compare TARGET to working tree
#                     Otherwise, same as committed-only
if [ "$include_worktree" = "true" ] && [ "$WORK_BRANCH" = "$SOURCE_BRANCH" ]; then
    diff_desc="${TARGET_BRANCH} -> working tree (includes staged+unstaged on ${SOURCE_BRANCH})"
    # Compare TARGET_BRANCH to working tree (HEAD + staged + unstaged)
    diff_name_cmd=(git diff --name-status -z -M --find-renames "$TARGET_BRANCH")
    diff_patch_cmd=(git diff --binary --full-index -M --find-renames "$TARGET_BRANCH")
else
    diff_desc="${SOURCE_BRANCH} -> ${TARGET_BRANCH} (committed only)"
    # Compare TARGET_BRANCH to SOURCE_BRANCH
    diff_name_cmd=(git diff --name-status -z -M --find-renames "${TARGET_BRANCH}..${SOURCE_BRANCH}")
    diff_patch_cmd=(git diff --binary --full-index -M --find-renames "${TARGET_BRANCH}..${SOURCE_BRANCH}")
fi

print_info "Comparing files (${diff_desc})..."

diff_stdout=$(mktemp)
diff_stderr=$(mktemp)
if ! "${diff_name_cmd[@]}" >"$diff_stdout" 2>"$diff_stderr"; then
    diff_err_out=$(cat "$diff_stderr")
    rm -f "$diff_stdout" "$diff_stderr"
    print_error "Failed to compute diff:"
    [ -n "$diff_err_out" ] && echo "$diff_err_out" >&2
    exit 1
fi
if diff_err_out=$(cat "$diff_stderr"); then
    [ -n "$diff_err_out" ] && echo "$diff_err_out" >&2
fi
rm -f "$diff_stderr"

DIFF_TOKENS=()
while IFS= read -r -d '' tok; do
    DIFF_TOKENS+=("$tok")
done < "$diff_stdout"
rm -f "$diff_stdout"

DISPLAY_ITEMS=()
ENTRY_OFFSETS=()
ENTRY_LENGTHS=()
PATHS_FLAT=()
UNTRACKED_PATHS=()

if [ "$include_worktree" = "true" ] && [ "$WORK_BRANCH" = "$SOURCE_BRANCH" ]; then
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        UNTRACKED_PATHS+=("$path")
    done < <(git ls-files --others --exclude-standard -z)
fi

add_diff_entry() {
    local display="$1"
    shift
    local start=${#PATHS_FLAT[@]}
    ENTRY_OFFSETS+=("$start")
    ENTRY_LENGTHS+=("$#")
    PATHS_FLAT+=("$@")
    DISPLAY_ITEMS+=("$display")
}

token_count=${#DIFF_TOKENS[@]}
i=0
while [ "$i" -lt "$token_count" ]; do
    status=${DIFF_TOKENS[$i]}
    i=$((i+1))
    [ -n "$status" ] || continue
    case "$status" in
        R*|C*)
            [ "$i" -lt "$token_count" ] || break
            old_path=${DIFF_TOKENS[$i]}
            i=$((i+1))
            if [ "$i" -lt "$token_count" ]; then
                new_path=${DIFF_TOKENS[$i]}
                i=$((i+1))
            else
                new_path="$old_path"
            fi
            symbol=${status:0:1}
            add_diff_entry "[$symbol] $old_path -> $new_path" "$old_path" "$new_path"
            ;;
        *)
            [ "$i" -lt "$token_count" ] || break
            file_path=${DIFF_TOKENS[$i]}
            i=$((i+1))
            symbol=${status:0:1}
            add_diff_entry "[$symbol] $file_path" "$file_path"
            ;;
    esac
done

if [ "$include_worktree" = "true" ] && [ "$WORK_BRANCH" = "$SOURCE_BRANCH" ] && [ "${#UNTRACKED_PATHS[@]}" -gt 0 ]; then
    for path in "${UNTRACKED_PATHS[@]}"; do
        add_diff_entry "[?] $path (untracked)" "$path"
    done
fi

if [ "${#DISPLAY_ITEMS[@]}" -eq 0 ]; then
    print_warning "No differences found between the branches"
    exit 0
fi

# Count files/items
FILE_COUNT="${#DISPLAY_ITEMS[@]}"
print_info "Found ${FILE_COUNT} file(s) with differences"

# Display list of files
echo ""
print_info "Files with differences:"
echo ""
for ((idx=0; idx<FILE_COUNT; idx++)); do
    DISPLAY_TEXT="${DISPLAY_ITEMS[$idx]}"
    printf '  %2d) %s\n' $((idx+1)) "$DISPLAY_TEXT"
done
echo ""

# File selection - three modes:
# 1. Path-based selection (--include-files/--exclude-files) for non-interactive/AI use
# 2. Number-based selection (-f "1 3 5-7") for interactive use
# 3. All files (--all-files)

want=()

if [ -n "$FLAG_INCLUDE_FILES" ] || [ -n "$FLAG_EXCLUDE_FILES" ]; then
    # Path-based selection mode (for AI agents/non-interactive use)
    print_info "Using path-based file selection..."
    
    for ((idx=0; idx<FILE_COUNT; idx++)); do
        # Check ALL paths for this entry (handles renames: old + new path)
        start=${ENTRY_OFFSETS[$idx]}
        len=${ENTRY_LENGTHS[$idx]}
        matched=false
        for ((pi=0; pi<len; pi++)); do
            path="${PATHS_FLAT[$((start + pi))]}"
            if should_include_path "$path" "$FLAG_INCLUDE_FILES" "$FLAG_EXCLUDE_FILES"; then
                matched=true
                break
            fi
        done
        if [ "$matched" = true ]; then
            want+=("$idx")
        fi
    done
    
    if [ "${#want[@]}" -eq 0 ]; then
        print_warning "No files matched the include/exclude patterns"
        print_info "Include patterns: ${FLAG_INCLUDE_FILES:-<none>}"
        print_info "Exclude patterns: ${FLAG_EXCLUDE_FILES:-<none>}"
        exit 1
    fi
    
    print_info "Matched ${#want[@]} file(s) based on patterns"
    
elif [ "$FLAG_ALL_FILES" = true ]; then
    # All files mode
    for ((i=0; i<FILE_COUNT; i++)); do
        want+=("$i")
    done
    
elif [ -n "$FLAG_FILES_SELECTION" ]; then
    # Number-based selection from flag
    selection="$FLAG_FILES_SELECTION"
    sel_norm=$(printf '%s' "$selection" | tr ',' ' ')
    if printf '%s' "$sel_norm" | grep -Eiq '^(all|a)$'; then
        for ((i=0; i<FILE_COUNT; i++)); do
            want+=("$i")
        done
    else
        for tok in $sel_norm; do
            if printf '%s' "$tok" | grep -Eq '^[0-9]+-[0-9]+$'; then
                start="${tok%-*}"
                end="${tok#*-}"
                [ "$start" -le "$end" ] || die "Bad range: $tok"
                for ((k=start; k<=end; k++)); do
                    idx=$((k-1))
                    [ "$idx" -ge 0 ] && [ "$idx" -lt "$FILE_COUNT" ] && want+=("$idx")
                done
            elif printf '%s' "$tok" | grep -Eq '^[0-9]+$'; then
                idx=$((tok-1))
                [ "$idx" -ge 0 ] && [ "$idx" -lt "$FILE_COUNT" ] && want+=("$idx")
            else
                die "Unrecognized token: $tok"
            fi
        done
    fi
    
else
    # Interactive file selection
    echo ""
    print_info "Select files to include in the patch:"
    echo ""
    printf 'Enter file numbers (e.g. "1 3 5-7", "all"). Enter = all: '
    IFS= read -r selection
    selection="${selection:-all}"
    
    sel_norm=$(printf '%s' "$selection" | tr ',' ' ')
    if printf '%s' "$sel_norm" | grep -Eiq '^(all|a)$'; then
        for ((i=0; i<FILE_COUNT; i++)); do
            want+=("$i")
        done
    else
        for tok in $sel_norm; do
            if printf '%s' "$tok" | grep -Eq '^[0-9]+-[0-9]+$'; then
                start="${tok%-*}"
                end="${tok#*-}"
                [ "$start" -le "$end" ] || die "Bad range: $tok"
                for ((k=start; k<=end; k++)); do
                    idx=$((k-1))
                    [ "$idx" -ge 0 ] && [ "$idx" -lt "$FILE_COUNT" ] && want+=("$idx")
                done
            elif printf '%s' "$tok" | grep -Eq '^[0-9]+$'; then
                idx=$((tok-1))
                [ "$idx" -ge 0 ] && [ "$idx" -lt "$FILE_COUNT" ] && want+=("$idx")
            else
                die "Unrecognized token: $tok"
            fi
        done
    fi
fi

# Deduplicate indices
[ ${#want[@]} -gt 0 ] || die "No files selected (empty selection)"
idx_tmp=$(mktemp)
printf '%s\n' "${want[@]}" | awk '!seen[$0]++' > "$idx_tmp"

# Build selected files list (expanding rename/copy pairs into both paths)
SELECTED_INDICES=()
while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    SELECTED_INDICES+=("$idx")
done < "$idx_tmp"

rm -f "$idx_tmp"

SELECTED_PATHS=()
for idx in ${SELECTED_INDICES[@]+"${SELECTED_INDICES[@]}"}; do
    start=${ENTRY_OFFSETS[$idx]}
    len=${ENTRY_LENGTHS[$idx]}
    for ((k=0; k<len; k++)); do
        path_idx=$((start + k))
        SELECTED_PATHS+=("${PATHS_FLAT[$path_idx]}")
    done
done

[ "${#SELECTED_PATHS[@]}" -gt 0 ] || die "No files selected"

SELECTED_COUNT="${#SELECTED_INDICES[@]}"
print_info "Selected ${SELECTED_COUNT} item(s)"

dedup_tmp=$(mktemp)
printf '%s\n' "${SELECTED_PATHS[@]}" | awk '!seen[$0]++' > "$dedup_tmp"

DIFF_FILES=()
while IFS= read -r path; do
    [ -n "$path" ] || continue
    DIFF_FILES+=("$path")
done < "$dedup_tmp"
rm -f "$dedup_tmp"

[ "${#DIFF_FILES[@]}" -gt 0 ] || die "No files selected"

TRACKED_FILES=()
UNTRACKED_SELECTED=()

if [ "$include_worktree" = "true" ] && [ "$WORK_BRANCH" = "$SOURCE_BRANCH" ]; then
    for path in "${DIFF_FILES[@]}"; do
        if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            TRACKED_FILES+=("$path")
        else
            UNTRACKED_SELECTED+=("$path")
        fi
    done
else
    TRACKED_FILES=("${DIFF_FILES[@]}")
fi

# Check that we have files to patch
if [ "${#TRACKED_FILES[@]}" -eq 0 ] && [ "${#UNTRACKED_SELECTED[@]}" -eq 0 ]; then
    print_error "No files selected for patch generation"
    exit 1
fi

# Determine description early (needed for commit message)
# Ensure patches directory exists first
PATCHES_DIR="${REPO_ROOT}/patches"
if [ ! -d "$PATCHES_DIR" ]; then
    mkdir -p "$PATCHES_DIR" || die "Cannot create patches directory: $PATCHES_DIR"
fi
assert_unique_patch_prefixes "$PATCHES_DIR"

# Determine description for commit message and filename
if [ -n "$FLAG_DESCRIPTION" ]; then
    PATCH_DESC=$(sanitize_for_filename "$FLAG_DESCRIPTION")
elif [ "$FLAG_NON_INTERACTIVE" = true ]; then
    # Use source branch name as description in non-interactive mode
    PATCH_DESC=$(sanitize_for_filename "$SOURCE_BRANCH")
else
    # Interactive: prompt for description
    NEXT_PREFIX=$(get_next_patch_prefix "$PATCHES_DIR")
    echo ""
    print_info "Enter a short description for the patch filename."
    print_info "This will be used as: ${NEXT_PREFIX}-<description>.patch"
    safe_source=$(sanitize_for_filename "$SOURCE_BRANCH")
    print_info "Default: ${safe_source}"
    read -p "Description (Enter = default): " user_desc
    if [ -n "$user_desc" ]; then
        PATCH_DESC=$(sanitize_for_filename "$user_desc")
    else
        PATCH_DESC="$safe_source"
    fi
fi

# Generate mailbox patch using temporary worktree
echo ""
print_info "Generating mailbox patch file..."
print_info "Patch direction: ${diff_desc}"
echo ""

# Create temporary worktree for patch generation
TEMP_WORKTREE=$(mktemp -d)
cleanup_worktree() {
  if [ -n "$TEMP_WORKTREE" ] && [ -d "$TEMP_WORKTREE" ]; then
    cd "$REPO_ROOT" 2>/dev/null || true
    git worktree remove --force "$TEMP_WORKTREE" 2>/dev/null || true
    rm -rf "$TEMP_WORKTREE" 2>/dev/null || true
  fi
}
trap cleanup_worktree EXIT

# Create worktree from target branch
if ! git worktree add --detach "$TEMP_WORKTREE" "$TARGET_BRANCH" >/dev/null 2>&1; then
  print_error "Failed to create temporary worktree"
  exit 1
fi

cd "$TEMP_WORKTREE" || {
  print_error "Failed to cd to temporary worktree"
  exit 1
}

# Apply tracked file changes
if [ "${#TRACKED_FILES[@]}" -gt 0 ]; then
  # --index is required so submodule gitlink updates (mode 160000) are recorded; without it,
  # git apply reports success but the index/worktree may omit the gitlink change and the
  # synthetic commit can drop paths like G7SensorKit.
  if ! "${diff_patch_cmd[@]}" -- "${TRACKED_FILES[@]}" | git apply --index --whitespace=fix; then
    print_error "Failed to apply diff in temporary worktree"
    exit 1
  fi
fi

# Handle untracked files (copy them to worktree)
if [ "${#UNTRACKED_SELECTED[@]}" -gt 0 ]; then
  for path in "${UNTRACKED_SELECTED[@]}"; do
    mkdir -p "$(dirname "$path")"
    cp "$REPO_ROOT/$path" "$path"
  done
fi

# Stage only the explicit selected files (not global -A)
# Use -A with explicit pathspec so deletions are included but nothing else is staged
if [ "${#TRACKED_FILES[@]}" -gt 0 ] || [ "${#UNTRACKED_SELECTED[@]}" -gt 0 ]; then
  if [ "${#TRACKED_FILES[@]}" -gt 0 ] && [ "${#UNTRACKED_SELECTED[@]}" -gt 0 ]; then
    git add -A -- "${TRACKED_FILES[@]}" "${UNTRACKED_SELECTED[@]}"
  elif [ "${#TRACKED_FILES[@]}" -gt 0 ]; then
    git add -A -- "${TRACKED_FILES[@]}"
  elif [ "${#UNTRACKED_SELECTED[@]}" -gt 0 ]; then
    git add -A -- "${UNTRACKED_SELECTED[@]}"
  fi
fi

# Commit the changes
if ! git commit -m "feat: ${PATCH_DESC}"; then
  print_error "Failed to create commit in temporary worktree"
  exit 1
fi

# Generate mailbox patch to temp file
TEMP_PATCH=$(mktemp)
if ! git format-patch -1 --stdout HEAD > "$TEMP_PATCH"; then
  print_error "Failed to generate mailbox patch"
  exit 1
fi

# Return to repo root
cd "$REPO_ROOT" || exit 1

# Cleanup worktree
cleanup_worktree
trap - EXIT

# Move temp patch to final location (critical: must write to $PATCH_PATH)
if [ ! -s "$TEMP_PATCH" ]; then
  print_error "Generated patch is empty"
  rm -f "$TEMP_PATCH"
  exit 1
fi

# Determine patch filename (PATCH_DESC already set above)
if [ -n "$FLAG_OUTPUT_PATH" ]; then
    # Use explicit output path
    PATCH_PATH="$FLAG_OUTPUT_PATH"
else
    # Generate filename with XY- prefix
    NEXT_PREFIX=$(get_next_patch_prefix "$PATCHES_DIR")
    
    # Mailbox format patches use .patch extension
    DEFAULT_PATCH_NAME="${PATCHES_DIR}/${NEXT_PREFIX}-${PATCH_DESC}.patch"
    
    if [ "$FLAG_NON_INTERACTIVE" = true ]; then
        PATCH_PATH="$DEFAULT_PATCH_NAME"
    else
        echo ""
        print_info "Where should the patch be saved?"
        print_info "Default: ${DEFAULT_PATCH_NAME}"
        read -p "Path (Enter = default): " user_path
        PATCH_PATH="${user_path:-$DEFAULT_PATCH_NAME}"
    fi
fi

# Expand ~ and resolve relative paths
PATCH_PATH="${PATCH_PATH/#\~/$HOME}"

# Resolve output directory and check writability
outdir=$(cd "$(dirname "$PATCH_PATH")" 2>/dev/null && pwd -P) || die "Cannot access output directory"
[ -w "$outdir" ] || die "Output directory is not writable: $outdir"

# Check if file exists and handle overwrite
if [ -f "$PATCH_PATH" ]; then
    if [ "$FLAG_YES" = true ]; then
        print_warning "Overwriting existing file: ${PATCH_PATH}"
    else
        print_warning "File already exists: ${PATCH_PATH}"
        read -p "Overwrite? (y/N): " OVERWRITE
        if [[ ! "$OVERWRITE" =~ ^[yY]$ ]]; then
            print_info "Aborted"
            # TEMP_PATCH may not exist if we're here from interactive prompt
            [ -f "$TEMP_PATCH" ] && rm -f "$TEMP_PATCH"
            exit 0
        fi
    fi
fi

# Move temp patch to final location (critical fix)
mv "$TEMP_PATCH" "$PATCH_PATH"

print_success "Patch file created: ${PATCH_PATH}"

# Validate the patch
echo ""
print_info "Validating patch file..."

VALIDATION_PASSED=true
stat_ran=false

# Check 1: Check if patch file is not empty
if [ ! -s "$PATCH_PATH" ]; then
    print_error "Patch file is empty"
    VALIDATION_PASSED=false
else
    print_success "Patch file is not empty"
fi

# Check 2: Check if patch has valid format (mailbox format starts with "From")
if ! head -1 "$PATCH_PATH" | grep -qE "^From "; then
    print_warning "Patch file may not have valid mailbox format (doesn't start with 'From')"
else
    print_success "Patch file has valid mailbox format"
fi

# Check 3: Try to apply the patch with git am (in disposable worktree)
# The patch is generated from SOURCE_BRANCH that can be applied to TARGET_BRANCH
# so it should be tested on TARGET_BRANCH (where it will be applied)
print_info "Testing patch application (dry run) on target branch '${TARGET_BRANCH}'..."

# Get absolute path to patch file for use in worktree
PATCH_ABS_PATH=$(cd "$(dirname "$PATCH_PATH")" && pwd -P)/$(basename "$PATCH_PATH")

# Use worktree for safe validation
if git help worktree >/dev/null 2>&1; then
    wt_dir=$(mktemp -d)
    cleanup() {
        set +e
        git worktree remove -f "$wt_dir" >/dev/null 2>&1 || true
        rm -rf "$wt_dir" >/dev/null 2>&1 || true
        set -e
    }
    trap cleanup EXIT
    
    if git worktree add -q --detach "$wt_dir" "$TARGET_BRANCH" >/dev/null 2>&1; then
        stat_ran=true
        apply_result=$(mktemp)
        apply_error=$(mktemp)
        (
            cd "$wt_dir"
            print_info "Patch summary (git apply --stat) on target branch '${TARGET_BRANCH}':"
            git apply --stat "$PATCH_ABS_PATH" 2>&1 || true
            if git -c user.name="Trio Patch Bot" -c user.email="patch-bot@users.noreply.github.com" \
              am --3way --keep-cr --whitespace=nowarn "$PATCH_ABS_PATH" >/dev/null 2>&1; then
                echo "SUCCESS" > "$apply_result"
                # Reset to clean state before removing worktree (no abort needed on success)
                git reset --hard "$TARGET_BRANCH" >/dev/null 2>&1 || true
            else
                echo "FAILED" > "$apply_result"
                git am --abort >/dev/null 2>&1 || true
                git -c user.name="Trio Patch Bot" -c user.email="patch-bot@users.noreply.github.com" \
                  am --3way --keep-cr --whitespace=nowarn "$PATCH_ABS_PATH" 2>&1 | head -10 > "$apply_error" || true
            fi
        )
        
        if [ "$(cat "$apply_result")" = "FAILED" ]; then
            print_error "Patch cannot be applied (tested on ${TARGET_BRANCH})"
            VALIDATION_PASSED=false
            [ -s "$apply_error" ] && cat "$apply_error"
        else
            print_success "Patch can be applied successfully (tested on ${TARGET_BRANCH})"
            print_success "  - git am (target branch)"
        fi
        rm -f "$apply_result" "$apply_error"
        
        cleanup
        trap - EXIT
    else
        print_warning "Could not create worktree for testing, skipping apply check"
        cleanup
        trap - EXIT
    fi
else
    stat_ran=true
    print_warning "git worktree not available; skipping mailbox patch validation"
fi

if [ "$stat_ran" = false ]; then
    echo ""
    print_info "Patch summary (git am --stat):"
    git am --stat "$PATCH_PATH" 2>&1 || true
fi

# Final summary
echo ""
if [ "$VALIDATION_PASSED" = true ]; then
    print_success "Patch validation passed!"
    print_info "Patch file: ${PATCH_PATH}"
    print_info "To apply this patch, run: git am ${PATCH_PATH}"
else
    print_warning "Patch validation had issues. Review the patch file before applying."
    print_info "Patch file: ${PATCH_PATH}"
fi

echo ""
print_info "Done."
