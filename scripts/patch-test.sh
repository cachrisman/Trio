#!/bin/bash
# Removed set -e - we handle errors manually

# Save original directory BEFORE any cd operations
ORIGINAL_DIR=$(pwd)

# Create worktree
TEST_WORKTREE=$(mktemp -d /tmp/trio-patch-test-XXXXXX)
echo "Creating test worktree at: $TEST_WORKTREE"

# Clean up any existing branch/worktree from previous runs
git worktree remove tmp/patch-test 2>/dev/null || true
git branch -D tmp/patch-test 2>/dev/null || true
git branch -D tmp/test-apply-patches 2>/dev/null || true

git worktree add -b tmp/patch-test "$TEST_WORKTREE" dev

# Copy patches - clean the worktree patches dir first to avoid duplicates
mkdir -p "$TEST_WORKTREE/patches"
find "$TEST_WORKTREE/patches" -name "*.patch" -delete 2>/dev/null || true
cp patches/*.patch "$TEST_WORKTREE/patches/" 2>/dev/null || true

# Test in worktree
cd "$TEST_WORKTREE" || {
  echo "Failed to cd to worktree"
  cd "$ORIGINAL_DIR"
  git worktree remove "$TEST_WORKTREE" 2>/dev/null || true
  rm -rf "$TEST_WORKTREE" 2>/dev/null || true
  exit 1
}

git submodule update --init --recursive

# Clean up test branch if it exists in the worktree
git branch -D tmp/test-apply-patches 2>/dev/null || true
git checkout -b tmp/test-apply-patches

# Show which patches will be tested
echo ""
echo "Patches to test:"
ls -1 patches/*.patch 2>/dev/null | while read p; do echo "  - $(basename "$p")"; done || echo "  (no patches found)"
echo ""

failed=false
failed_patch=""

for p in patches/*.patch; do
  [ -f "$p" ] || continue
  echo ""
  echo "=========================================="
  echo "Testing: $(basename "$p")"
  echo "=========================================="
  
  if git apply --check "$p" 2>&1; then
    if git apply "$p" 2>&1; then
      echo "✅ Applied: $(basename "$p")"
    else
      echo "❌ FAILED to apply: $(basename "$p")"
      failed=true
      failed_patch="$p"
      break
    fi
  else
    echo "❌ FAILED check: $(basename "$p")"
    failed=true
    failed_patch="$p"
    break
  fi
done

# Cleanup - return to original directory
cd "$ORIGINAL_DIR" || cd ~

# Try to remove worktree and branch, but don't fail if they don't exist
git worktree remove "$TEST_WORKTREE" 2>/dev/null || true
git branch -D tmp/patch-test 2>/dev/null || true
git branch -D tmp/test-apply-patches 2>/dev/null || true
rm -rf "$TEST_WORKTREE" 2>/dev/null || true

# Prune any stale worktree references
git worktree prune 2>/dev/null || true

# Report results
echo ""
if [ "$failed" = true ]; then
  echo "❌ Patch validation failed at: $(basename "$failed_patch")"
else
  echo "✅ All patches applied successfully"
fi