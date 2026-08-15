#!/usr/bin/env bash

#===============================================================================
# repin-g7.sh — Push the G7SensorKit fork and re-pin patch 02 to the new SHA (v1.0)
#
# WHY THIS EXISTS
#   Patch 02 (02-g7-reading-time-with-seconds.patch) pins the G7SensorKit
#   submodule to a commit on the cachrisman fork. That SHA appears in TWO places
#   in the patch that must stay in agreement:
#     1. the gitlink hunk's `+Subproject commit <sha>` line,
#     2. the `index <base>..<new> 160000` line's *after* abbreviation, and
#     3. (when dev's own G7SensorKit pointer has moved, e.g. an upstream bump) the
#        base `-Subproject commit <sha>` line + the index *before* abbreviation,
#        re-derived from `dev:G7SensorKit` — a stale base makes `git am --3way`
#        fail with an unresolvable submodule conflict.
#   Hand-editing the patch is against the "never hand-edit patch files" rule and
#   is easy to get half-right (update one site, miss the other). This script does
#   the edit mechanically, validates it with patch-test.sh (git am is strict and
#   rejects a malformed gitlink hunk), prints the diff for sign-off, and refuses
#   ambiguous states — the same justification that legitimized generate-patch.sh.
#
# WHAT IT DOES
#   1. Validates the standalone G7SensorKit clone (branch resolvable, origin is
#      the cachrisman fork).
#   2. Pushes the clone's committed HEAD to origin (skipped on --dry-run).
#   3. Asserts the new SHA is actually on origin (guards against pinning to an
#      unpushed local commit — the build would fail to fetch the submodule).
#   4. Rewrites both SHA sites in patch 02 to the new SHA (no-op if unchanged).
#   5. Runs patch-test.sh and prints the patch diff. Does NOT commit.
#
# USAGE
#   ./scripts/repin-g7.sh [--dry-run] [--allow-dirty-patch] [--skip-test]
#
# OPTIONS
#   --dry-run            Show what would be pushed and rewritten; make no changes.
#   --allow-dirty-patch  Proceed even if patch 02 already has uncommitted edits
#                        (the "several G7 rounds without committing patch 02
#                        between each" case). Without it: warn and stop.
#   --skip-test          Skip the patch-test.sh validation (not recommended).
#   -h, --help           Show this help.
#
# ENV OVERRIDES (rarely needed)
#   G7_CLONE   Path to the standalone G7SensorKit clone
#              (default: ~/Code/personal/health/diabetes/G7SensorKit).
#===============================================================================

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
print_error()   { echo "${RED}Error:${NC} $1" >&2; }
print_success() { echo "${GREEN}✓${NC} $1"; }
print_info()    { echo "${BLUE}ℹ${NC} $1"; }
print_warning() { echo "${YELLOW}⚠${NC} $1"; }
print_step()    { echo "${BOLD}» $1${NC}"; }
die() { print_error "$1"; exit 1; }

DRY_RUN=false
ALLOW_DIRTY_PATCH=false
SKIP_TEST=false
G7_CLONE="${G7_CLONE:-$HOME/Code/personal/health/diabetes/G7SensorKit}"
EXPECTED_FORK_HOST_PATH="cachrisman/G7SensorKit"   # origin must point at this fork

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --allow-dirty-patch) ALLOW_DIRTY_PATCH=true; shift ;;
        --skip-test) SKIP_TEST=true; shift ;;
        -h|--help)
            awk 'NR>=3 && /^#===/ {c++; if(c==2) exit} NR>=3 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

#-------------------------------------------------------------------------------
# Preconditions: must run from the Trio-dev worktree so patches/ resolves.
#-------------------------------------------------------------------------------
print_step "Preconditions"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
REPO_ROOT=$(git rev-parse --show-toplevel)
[ "$(basename "$REPO_ROOT")" = "Trio-dev" ] || die "Must be run from the Trio-dev worktree (currently in: $(basename "$REPO_ROOT"))."
[ -x "$REPO_ROOT/scripts/patch-test.sh" ] || die "scripts/patch-test.sh not found or not executable"

PATCH_FILE=$(ls -1 "$REPO_ROOT"/patches/02-*.patch 2>/dev/null | head -1)
[ -n "$PATCH_FILE" ] && [ -f "$PATCH_FILE" ] || die "Could not find patches/02-*.patch"
print_success "Patch file: $(basename "$PATCH_FILE")"

[ -d "$G7_CLONE/.git" ] || die "G7SensorKit clone not found at: $G7_CLONE
  (override with G7_CLONE=/path/to/clone)"

#-------------------------------------------------------------------------------
# Validate the clone: origin must be the cachrisman fork.
#-------------------------------------------------------------------------------
ORIGIN_URL=$(git -C "$G7_CLONE" remote get-url origin 2>/dev/null || true)
[ -n "$ORIGIN_URL" ] || die "Clone has no 'origin' remote: $G7_CLONE"
case "$ORIGIN_URL" in
    *"$EXPECTED_FORK_HOST_PATH"*) ;;
    *) die "Clone origin does not look like the expected fork.
  origin:   $ORIGIN_URL
  expected: ...$EXPECTED_FORK_HOST_PATH..." ;;
esac
print_success "Clone origin: $ORIGIN_URL"

# Cross-check: the patch's .gitmodules hunk must point at the same fork, so we
# never repin to a fork the build won't actually fetch from.
PATCH_FORK_URL=$(grep -E '^\+[[:space:]]*url = ' "$PATCH_FILE" | head -1 | sed -E 's/^\+[[:space:]]*url = //')
if [ -n "$PATCH_FORK_URL" ]; then
    case "$PATCH_FORK_URL" in
        *"$EXPECTED_FORK_HOST_PATH"*) ;;
        *) die "Patch 02 .gitmodules URL ($PATCH_FORK_URL) does not match the expected fork ($EXPECTED_FORK_HOST_PATH)." ;;
    esac
fi

CLONE_BRANCH=$(git -C "$G7_CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
[ "$CLONE_BRANCH" != "HEAD" ] || die "Clone is in detached HEAD; checkout the working branch before repinning."
[ "$CLONE_BRANCH" = "main" ] || print_warning "Clone is on '$CLONE_BRANCH', not 'main' (AGENTS.md: commit G7SensorKit changes on main). Pushing/pinning this branch anyway."
NEW_SHA=$(git -C "$G7_CLONE" rev-parse HEAD)
print_info "Clone branch: $CLONE_BRANCH @ $(git -C "$G7_CLONE" rev-parse --short HEAD)"

# Warn (do not silently include) if the clone has uncommitted work — only the
# committed HEAD is pushed/pinned.
if ! git -C "$G7_CLONE" diff --quiet || ! git -C "$G7_CLONE" diff --cached --quiet; then
    print_warning "Clone has uncommitted changes; only the committed HEAD ($(git -C "$G7_CLONE" rev-parse --short HEAD)) will be pushed/pinned."
fi

#-------------------------------------------------------------------------------
# Read the SHA currently pinned by the patch.
#-------------------------------------------------------------------------------
OLD_SHA=$(grep -E '^\+Subproject commit [0-9a-f]{40}' "$PATCH_FILE" | head -1 | awk '{print $3}')
[ -n "$OLD_SHA" ] || die "Could not read the pinned '+Subproject commit <sha>' from $PATCH_FILE"
print_info "Currently pinned: $OLD_SHA"
print_info "New (clone HEAD): $NEW_SHA"

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
    print_success "Patch 02 already pins the clone HEAD; nothing to do."
    exit 0
fi

#-------------------------------------------------------------------------------
# Guard: refuse to overwrite uncommitted patch edits unless allowed.
#-------------------------------------------------------------------------------
if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$PATCH_FILE"; then
    if [ "$ALLOW_DIRTY_PATCH" = true ]; then
        print_warning "Patch 02 has uncommitted edits; proceeding (--allow-dirty-patch)."
    else
        die "Patch 02 has uncommitted edits. If these are earlier G7 repin rounds you intend
  to build on, re-run with --allow-dirty-patch. Otherwise commit or revert them first."
    fi
fi

#-------------------------------------------------------------------------------
# Push the clone, then assert the new SHA is on origin.
#-------------------------------------------------------------------------------
print_step "Push fork"
if [ "$DRY_RUN" = true ]; then
    print_info "[dry-run] would: git -C $G7_CLONE push origin $CLONE_BRANCH"
else
    git -C "$G7_CLONE" push origin "$CLONE_BRANCH"
    git -C "$G7_CLONE" fetch origin >/dev/null 2>&1 || true
    if ! git -C "$G7_CLONE" branch -r --contains "$NEW_SHA" 2>/dev/null | grep -q 'origin/'; then
        die "After push, $NEW_SHA is not on any origin branch. Aborting before repin
  (a build would fail to fetch this submodule commit)."
    fi
    print_success "$NEW_SHA confirmed on origin."
fi

#-------------------------------------------------------------------------------
# Rewrite both SHA sites in the patch (gitlink '+Subproject commit' + 'index' after-abbrev).
#-------------------------------------------------------------------------------
print_step "Re-pin patch 02"

# Length of the existing 'index <base>..<after> 160000' after-abbreviation, so the
# rewritten abbreviation matches git's own formatting for this hunk.
ABBR_LEN=$(grep -E '^index [0-9a-f]+\.\.[0-9a-f]+ 160000' "$PATCH_FILE" | head -1 \
    | sed -E 's/^index [0-9a-f]+\.\.([0-9a-f]+) 160000.*/\1/' | awk '{print length}')
[ -n "$ABBR_LEN" ] && [ "$ABBR_LEN" -ge 7 ] || ABBR_LEN=9
NEW_ABBR=$(git -C "$G7_CLONE" rev-parse --short="$ABBR_LEN" "$NEW_SHA")

# The gitlink hunk's BASE ('-') side must match the submodule pointer on the target
# branch, or `git am --3way` hits an unresolvable submodule conflict. It goes stale
# whenever upstream bumps G7SensorKit on dev (first hit: 0.8.4 moved 4d0780d -> 0c87905,
# 2026-07-04). Re-derive it from dev's tree and rewrite the '-Subproject commit' line
# and the 'index <before>..' abbreviation when they differ.
PATCH_BASE_SHA=$(grep -E '^-Subproject commit [0-9a-f]{40}' "$PATCH_FILE" | head -1 | awk '{print $3}')
[ -n "$PATCH_BASE_SHA" ] || die "Could not read the base '-Subproject commit <sha>' from $PATCH_FILE"
BASE_SHA=$(git -C "$REPO_ROOT" rev-parse "dev:G7SensorKit") \
    || die "Could not resolve dev's G7SensorKit gitlink (dev:G7SensorKit)"
BASE_ABBR=${BASE_SHA:0:$ABBR_LEN}
if [ "$PATCH_BASE_SHA" != "$BASE_SHA" ]; then
    print_info "Base gitlink moved on dev: $PATCH_BASE_SHA -> $BASE_SHA (rewriting '-' side too)"
fi

if [ "$DRY_RUN" = true ]; then
    print_info "[dry-run] would rewrite:"
    print_info "    +Subproject commit $OLD_SHA  ->  $NEW_SHA"
    print_info "    index ..<after> abbrev       ->  ..$NEW_ABBR"
    exit 0
fi

# Back up the pre-rewrite patch so a later failure (bad rewrite OR a failing
# patch-test.sh) rolls patch 02 back to its committed state instead of leaving a
# half-applied repin on disk. Restored by the EXIT trap on any non-zero exit; the
# fork push is NOT reverted (it's already public, and re-pinning is idempotent).
_orig_backup="${PATCH_FILE}.repin.orig"
cp "$PATCH_FILE" "$_orig_backup"
_restore_on_fail() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -f "$_orig_backup" ]; then
        mv "$_orig_backup" "$PATCH_FILE"
        print_warning "Re-pin rolled back: patch 02 restored to its pre-repin state. The fork push (if it happened) is NOT reverted — re-run ./scripts/repin-g7.sh to retry (it is idempotent)."
    fi
    [ -f "$_orig_backup" ] && rm -f "$_orig_backup"
    [ -n "${tmp:-}" ] && [ -f "${tmp:-}" ] && rm -f "$tmp"
}
trap _restore_on_fail EXIT

# awk rewrite scoped to the G7SensorKit gitlink hunk: update the `index ..` after
# abbreviation and the `+Subproject commit` line. Leave the base ('-') side and
# the .gitmodules URL hunk untouched.
# Temp beside the patch (same filesystem; avoids mktemp, which the harness
# sandbox blocks — keeps the script runnable without disabling the sandbox).
tmp="${PATCH_FILE}.repin.tmp"
OLD_SHA="$OLD_SHA" NEW_SHA="$NEW_SHA" NEW_ABBR="$NEW_ABBR" \
PATCH_BASE_SHA="$PATCH_BASE_SHA" BASE_SHA="$BASE_SHA" BASE_ABBR="$BASE_ABBR" awk '
    /^diff --git a\/G7SensorKit b\/G7SensorKit/ { ing7=1 }
    ing7 && /^index [0-9a-f]+\.\.[0-9a-f]+ 160000/ {
        sub(/^index [0-9a-f]+/, "index " ENVIRON["BASE_ABBR"])
        sub(/\.\.[0-9a-f]+ 160000/, ".." ENVIRON["NEW_ABBR"] " 160000")
    }
    ing7 && $0 == "-Subproject commit " ENVIRON["PATCH_BASE_SHA"] {
        print "-Subproject commit " ENVIRON["BASE_SHA"]; next
    }
    ing7 && $0 == "+Subproject commit " ENVIRON["OLD_SHA"] {
        print "+Subproject commit " ENVIRON["NEW_SHA"]; next
    }
    /^-- $/ { ing7=0 }
    { print }
' "$PATCH_FILE" > "$tmp"
mv "$tmp" "$PATCH_FILE"

# Sanity: exactly the new SHA is now pinned, old gone; base side matches dev's gitlink.
grep -q "^+Subproject commit $NEW_SHA" "$PATCH_FILE" || die "Rewrite failed: new +Subproject commit line not present."
grep -q "^+Subproject commit $OLD_SHA" "$PATCH_FILE" && die "Rewrite failed: old +Subproject commit line still present."
grep -q "^-Subproject commit $BASE_SHA" "$PATCH_FILE" || die "Rewrite failed: base -Subproject commit line does not match dev's gitlink ($BASE_SHA)."
print_success "Patch 02 re-pinned to $NEW_SHA (index after-abbrev $NEW_ABBR)."

#-------------------------------------------------------------------------------
# Validate and show the diff for sign-off. Do NOT commit.
#-------------------------------------------------------------------------------
if [ "$SKIP_TEST" = true ]; then
    print_warning "Skipping patch-test.sh (--skip-test)."
else
    print_step "Validate stack (patch-test.sh)"
    "$REPO_ROOT/scripts/patch-test.sh"
fi

print_step "Patch diff (review before committing)"
git -C "$REPO_ROOT" --no-pager diff -- "$PATCH_FILE" || true
echo ""
print_success "Done. Patch 02 is re-pinned but NOT committed — review the diff above, then commit."
