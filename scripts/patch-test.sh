#!/bin/bash
# Removed set -e - we handle errors manually

print_usage() {
  cat <<'EOF'
Usage: scripts/patch-test.sh [options]

Options:
  --with-submodules               Initialize all submodules (default: skip).
  --include-submodules <list>     Comma-separated submodules to init; excludes others.
  --skip-patch <id|filename>      Skip a patch by number (e.g. 02) or full filename.
  -h, --help                      Show this help.

By default, submodules are skipped to speed up patch validation.
EOF
}

with_submodules=false
include_submodules=()
skip_patches=()

while [ $# -gt 0 ]; do
  case "$1" in
    --with-submodules)
      with_submodules=true
      ;;
    --include-submodules)
      shift
      if [ -z "${1-}" ]; then
        echo "Missing value for --include-submodules"
        print_usage
        exit 1
      fi
      IFS=',' read -r -a include_submodules <<< "$1"
      ;;
    --skip-patch)
      shift
      if [ -z "${1-}" ]; then
        echo "Missing value for --skip-patch"
        print_usage
        exit 1
      fi
      skip_patches+=("$1")
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      print_usage
      exit 1
      ;;
  esac
  shift
done

if [ "$with_submodules" = true ] && [ ${#include_submodules[@]} -gt 0 ]; then
  echo "Cannot combine --with-submodules with --include-submodules"
  exit 1
fi

should_skip_patch() {
  local filename="$1"
  local base="${filename##*/}"
  local base_no_ext="${base%.patch}"
  local entry

  for entry in "${skip_patches[@]}"; do
    if [ "$entry" = "$base" ] || [ "$entry" = "$base_no_ext" ]; then
      return 0
    fi
    if [[ "$entry" =~ ^[0-9][0-9]$ ]] && [[ "$base" == "$entry"-* ]]; then
      return 0
    fi
  done

  return 1
}

# Collect patches by numeric prefix (bash 3.2 compatible)
# Ordering: numeric prefix determines order; ties broken lexicographically
collect_patches() {
  local patches_dir="$1"
  (cd "$patches_dir" 2>/dev/null && ls -1 *.patch 2>/dev/null | sort) \
  | awk '
      /^[0-9][0-9]-/ {
        p=substr($0, 1, 2)
        if (!(p in chosen)) { chosen[p]=$0 }
      }
      END { for (p in chosen) print p "\t" chosen[p] }
    ' \
  | sort \
  | awk -v dir="$patches_dir" '{ print dir "/" $2 }'
}

# Save original directory BEFORE any cd operations
ORIGINAL_DIR=$(pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
TEST_WORKTREE=""
failed=false
failed_patch=""

cleanup() {
  cd "$REPO_ROOT" 2>/dev/null || cd "$ORIGINAL_DIR" 2>/dev/null || cd ~

  if [ -n "$TEST_WORKTREE" ] && [ -d "$TEST_WORKTREE" ]; then
    git worktree remove --force "$TEST_WORKTREE" 2>/dev/null || true
    rm -rf "$TEST_WORKTREE" 2>/dev/null || true
  fi

  git branch -D tmp/patch-test 2>/dev/null || true
  git branch -D tmp/test-apply-patches 2>/dev/null || true
  git worktree prune 2>/dev/null || true

  cd "$ORIGINAL_DIR" 2>/dev/null || cd ~
}

trap cleanup EXIT INT TERM

if [ -z "$REPO_ROOT" ]; then
  echo "Failed to determine repo root"
  exit 1
fi

cd "$REPO_ROOT" || {
  echo "Failed to cd to repo root"
  exit 1
}

# Create worktree
TEST_WORKTREE=$(mktemp -d /tmp/trio-patch-test-XXXXXX)
echo "Creating test worktree at: $TEST_WORKTREE"

# Clean up any existing branch/worktree from previous runs
existing_worktree_path=$(git worktree list --porcelain 2>/dev/null | awk '
  $1 == "worktree" {path = $2}
  $1 == "branch" && $2 == "refs/heads/tmp/patch-test" {print path}
')
if [ -n "$existing_worktree_path" ]; then
  git worktree remove --force "$existing_worktree_path" 2>/dev/null || true
fi
git branch -D tmp/patch-test 2>/dev/null || true
git branch -D tmp/test-apply-patches 2>/dev/null || true

if ! git worktree add -b tmp/patch-test "$TEST_WORKTREE" dev; then
  echo "Failed to create worktree"
  exit 1
fi

# Copy patches - clean the worktree patches dir first to avoid duplicates
mkdir -p "$TEST_WORKTREE/patches"
# Fix: use proper glob expansion instead of find -o
rm -f "$TEST_WORKTREE/patches"/*.patch 2>/dev/null || true

# Collect patches (deduplicated, deterministic order)
PATCH_LIST_FILE=$(mktemp)
collect_patches "$REPO_ROOT/patches" > "$PATCH_LIST_FILE"

# Copy collected patches to worktree
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp "$p" "$TEST_WORKTREE/patches/$(basename "$p")"
done < "$PATCH_LIST_FILE"
rm -f "$PATCH_LIST_FILE"

# Test in worktree
cd "$TEST_WORKTREE" || {
  echo "Failed to cd to worktree"
  exit 1
}

if [ ${#include_submodules[@]} -gt 0 ]; then
  echo "Initializing specific submodules: ${include_submodules[*]}"
  if ! git submodule update --init --recursive -- "${include_submodules[@]}"; then
    echo "Submodule update failed (include list)"
    exit 1
  fi
elif [ "$with_submodules" = true ]; then
  echo "Initializing all submodules (--with-submodules)"
  if ! git submodule update --init --recursive; then
    echo "Submodule update failed"
    exit 1
  fi
else
  echo "Skipping submodule init (default; use --with-submodules to include)"
fi

# Clean up test branch if it exists in the worktree
git branch -D tmp/test-apply-patches 2>/dev/null || true
if ! git checkout -b tmp/test-apply-patches; then
  echo "Failed to create test branch"
  exit 1
fi

# Configure git identity for git am operations
git config user.name "Trio Patch Bot" || true
git config user.email "patch-bot@users.noreply.github.com" || true

# Show which patches will be tested
echo ""
echo "Patches to test:"
found_patch=false
PATCH_LIST_FILE=$(mktemp)
collect_patches "$TEST_WORKTREE/patches" > "$PATCH_LIST_FILE"
while IFS= read -r p; do
  [ -f "$p" ] || continue
  found_patch=true
  patch_name=$(basename "$p")
  if should_skip_patch "$patch_name"; then
    echo "  - $patch_name (skipped)"
  else
    echo "  - $patch_name"
  fi
done < "$PATCH_LIST_FILE"
rm -f "$PATCH_LIST_FILE"
if [ "$found_patch" = false ]; then
  echo "  (no patches found)"
fi
echo ""

PATCH_LIST_FILE=$(mktemp)
collect_patches "$TEST_WORKTREE/patches" > "$PATCH_LIST_FILE"
while IFS= read -r p; do
  [ -f "$p" ] || continue
  patch_name=$(basename "$p")
  if should_skip_patch "$patch_name"; then
    echo ""
    echo "Skipping: $patch_name"
    continue
  fi
  
  echo ""
  echo "=========================================="
  echo "Testing: $patch_name"
  echo "=========================================="
  
  # Apply mailbox patch using git am
  if git am --3way --keep-cr --whitespace=nowarn "$p" 2>&1; then
    echo "✅ Applied: $patch_name"
  else
    echo "❌ FAILED to apply: $patch_name"
    git am --abort 2>/dev/null || true
    failed=true
    failed_patch="$p"
    rm -f "$PATCH_LIST_FILE"
    break
  fi
done < "$PATCH_LIST_FILE"
rm -f "$PATCH_LIST_FILE"

# Report results
echo ""
if [ "$failed" = true ]; then
  echo "❌ Patch validation failed at: $(basename "$failed_patch")"
  exit 1
else
  echo "✅ All patches applied successfully"
  exit 0
fi
