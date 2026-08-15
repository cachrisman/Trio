#!/bin/bash
#
# patch-audit.sh — Model B deletion guard for the patch stack.
#
# Applies ./patches/*.patch sequentially onto a throwaway worktree of `dev` and,
# per patch, flags deletions of pre-existing upstream code:
#   - FAIL  : deletions in a safety-critical path (scripts/patch-audit.safety-paths)
#             unless covered by scripts/patch-audit.waivers (fail-closed).
#   - WARN  : deletions of pre-existing code in non-safety files (informational).
#   - ignore: files created by the patch itself.
# Plus a sentinel check that the load-bearing pump-migration symbols survive.
#
# See docs/process/patch-clobber-guardrails.md. Run from the Trio-dev worktree.
# bash 3.2 compatible.

set -u

REPO="$(git rev-parse --show-toplevel)"
PATCH_DIR="$REPO/patches"
SAFETY_FILE="$REPO/scripts/patch-audit.safety-paths"
WAIVERS_FILE="$REPO/scripts/patch-audit.waivers"

SENTINEL_FILE="Trio/Sources/APS/DeviceDataManager.swift"
# Symbols the 2026-06 incident silently deleted (pump-manager migration).
# NB: upstream routes via `let OmniStr = "Omni"` then `hasPrefix(OmniStr)` —
# match the variable form, not a "Omni" string literal.
SENTINEL_SYMBOLS='func pumpManagerTypeByIdentifier|managerIdentifier.hasPrefix(OmniStr)|as? OmniPumpManager'

errors=0
warnings=0

# --- load safety globs (bash 3.2: no readarray) -----------------------------
SAFETY_GLOBS=()
if [ -f "$SAFETY_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    SAFETY_GLOBS+=("$line")
  done < "$SAFETY_FILE"
fi

is_safety_path() {
  local p="$1" g
  for g in ${SAFETY_GLOBS[@]+"${SAFETY_GLOBS[@]}"}; do
    case "$p" in
      $g) return 0 ;;
    esac
  done
  return 1
}

# waiver line: patch=<NN> file=<path> allow_deleted=<n> reason="..."
is_waived() {
  local patch_no="$1" file="$2" deleted="$3" line allow
  [ -f "$WAIVERS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|'') continue ;; esac
    case "$line" in
      *"patch=$patch_no "*"file=$file "*)
        allow="$(printf '%s\n' "$line" | sed -n 's/.*allow_deleted=\([0-9][0-9]*\).*/\1/p')"
        [ -n "$allow" ] && [ "$deleted" -le "$allow" ] && return 0
        ;;
    esac
  done < "$WAIVERS_FILE"
  return 1
}

# --- throwaway worktree ------------------------------------------------------
WT="$(mktemp -d "${TMPDIR:-/tmp}/patch-audit.XXXXXX")"
cleanup() {
  cd "$REPO" 2>/dev/null || cd / 2>/dev/null
  git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT" 2>/dev/null
  git worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree remove --force "$WT" >/dev/null 2>&1 || true
git -c submodule.recurse=false worktree add --detach "$WT" dev >/dev/null 2>&1 || {
  echo "patch-audit: failed to create worktree" >&2; exit 2; }
cd "$WT"

# --- apply + audit each patch in order --------------------------------------
shopt -s nullglob
PATCHES=()
for f in "$PATCH_DIR"/*.patch; do PATCHES+=("$f"); done
# sort by filename (numeric prefix)
IFS=$'\n' PATCHES=($(printf '%s\n' "${PATCHES[@]}" | sort)); unset IFS

echo "=== patch-audit: ${#PATCHES[@]} patches, safety globs: ${SAFETY_GLOBS[*]} ==="

for PATCH_FILE in ${PATCHES[@]+"${PATCHES[@]}"}; do
  PATCH_NAME="$(basename "$PATCH_FILE")"
  PATCH_NO="$(printf '%s' "$PATCH_NAME" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
  echo ""
  echo "--- $PATCH_NAME ---"

  if ! git -c submodule.recurse=false am --3way --quiet "$PATCH_FILE" >/tmp/pa-am.log 2>&1; then
    echo "  ERROR: failed to apply (git am): see below"
    sed 's/^/    /' /tmp/pa-am.log | tail -8
    git am --abort >/dev/null 2>&1 || true
    errors=$((errors + 1))
    break
  fi

  NEW_FILES="$(git diff-tree --name-status -r HEAD^ HEAD | awk -F'\t' '$1 ~ /^A/ {print $2}')"

  while IFS=$'\t' read -r added deleted path; do
    [ -z "${path:-}" ] && continue
    case "${deleted:-0}" in ''|'-') deleted=0 ;; esac
    case "${added:-0}"   in ''|'-') added=0 ;; esac

    if printf '%s\n' "$NEW_FILES" | grep -Fxq "$path"; then
      echo "  + $path (new file, +$added) — created by patch, deletions ignored"
      continue
    fi

    [ "$deleted" -le 0 ] 2>/dev/null && { [ "$added" -gt 0 ] 2>/dev/null && echo "  ~ $path (+$added/-0)"; continue; }

    if is_safety_path "$path"; then
      if is_waived "$PATCH_NO" "$path" "$deleted"; then
        echo "  ! $path (+$added/-$deleted) — SAFETY deletion, WAIVED"
      else
        echo "  ✗ $path (+$added/-$deleted) — FAIL: deletes from safety-critical path"
        errors=$((errors + 1))
      fi
    else
      echo "  ⚠ $path (+$added/-$deleted) — WARN: deletes pre-existing upstream code"
      warnings=$((warnings + 1))
    fi
  done <<EOF
$(git diff-tree --numstat -r HEAD^ HEAD)
EOF
done

# --- sentinel: load-bearing pump-migration symbols must survive --------------
echo ""
echo "--- sentinel: $SENTINEL_FILE ---"
if [ "$errors" -eq 0 ] || true; then
  if git show "HEAD:$SENTINEL_FILE" >/tmp/pa-ddm.swift 2>/dev/null; then
    missing=0
    IFS='|'
    for sym in $SENTINEL_SYMBOLS; do
      if ! grep -Fq "$sym" /tmp/pa-ddm.swift; then
        echo "  ✗ MISSING required symbol: $sym"
        missing=1
      fi
    done
    unset IFS
    if [ "$missing" -eq 0 ]; then
      echo "  ✓ all pump-migration symbols present"
    else
      errors=$((errors + 1))
    fi
  else
    echo "  ✗ $SENTINEL_FILE not present in applied stack"
    errors=$((errors + 1))
  fi
fi

echo ""
if [ "$errors" -gt 0 ]; then
  echo "=== patch-audit: FAILED ($errors error(s), $warnings warning(s)) ==="
  exit 1
fi
echo "=== patch-audit: PASSED ($warnings warning(s)) ==="
exit 0
