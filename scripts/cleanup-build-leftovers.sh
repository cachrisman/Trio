#!/usr/bin/env bash

#===============================================================================
# cleanup-build-leftovers.sh — Prune accumulated build leftovers (v1.0)
#
# WHAT IT PRUNES
#   1. Build worktrees   — $WORKTREE_PARENT/ci-build-* (default ../.trio-worktrees),
#                          keeping the newest --keep-worktrees (default 3).
#   2. Build logs        — build/artifacts/ci-local-build-*.log, keeping the
#                          newest --keep-logs (default 10).
#   3. Remote branches   — origin ci-build/* branches (pushed by record-release.sh
#                          when a fork SHA isn't yet on GitHub) older than
#                          --branch-age-days (default 7). OPT-IN: only deleted when
#                          --prune-remote-branches is given (remote deletion is
#                          outward-facing and hard to reverse).
#
# SAFETY MODEL
#   - DRY-RUN BY DEFAULT. Pass --apply to actually delete.
#   - Worktrees are kept-by-recency, not by status: a failed build's worktree is
#     preserved by local-build.sh for investigation, so prune only once you are
#     done with it. Use --skip-worktrees to leave them all alone.
#   - Remote branch deletion never happens without BOTH --apply and
#     --prune-remote-branches.
#   - The remote-branch section runs `git fetch origin --prune` even in dry-run (to
#     compute accurate branch ages); this updates local remote-tracking refs. Use
#     --skip-branches for a strictly side-effect-free preview.
#
# TRIGGERS
#   - Primary: run manually, on demand.
#   - Secondary: local-build.sh invokes it (logs only) after a SUCCESSFUL full
#     deploy — i.e. --apply --skip-worktrees --skip-branches. Never on failure.
#
# USAGE
#   ./scripts/cleanup-build-leftovers.sh [--apply] [options]
#
# OPTIONS
#   --apply                    Perform deletions (default: dry-run preview only).
#   --keep-worktrees <N>       Keep newest N build worktrees (default 3).
#   --keep-logs <N>            Keep newest N build logs (default 10).
#   --branch-age-days <N>      Remote ci-build/* branches older than N days are
#                              candidates (default 7).
#   --prune-remote-branches    Allow deleting stale remote ci-build/* branches.
#   --skip-worktrees           Do not touch worktrees.
#   --skip-logs                Do not touch logs.
#   --skip-branches            Do not look at remote branches at all.
#   --worktree-parent <path>   Override worktree parent dir.
#   -h, --help                 Show this help.
#===============================================================================

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
print_error()   { echo "${RED}Error:${NC} $1" >&2; }
print_success() { echo "${GREEN}✓${NC} $1"; }
print_info()    { echo "${BLUE}ℹ${NC} $1"; }
print_warning() { echo "${YELLOW}⚠${NC} $1"; }
print_step()    { echo ""; echo "${BOLD}» $1${NC}"; }
die() { print_error "$1"; exit 1; }

APPLY=false
KEEP_WORKTREES=3
KEEP_LOGS=10
BRANCH_AGE_DAYS=7
PRUNE_REMOTE_BRANCHES=false
SKIP_WORKTREES=false
SKIP_LOGS=false
SKIP_BRANCHES=false
WORKTREE_PARENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --keep-worktrees) KEEP_WORKTREES="$2"; shift 2 ;;
        --keep-logs) KEEP_LOGS="$2"; shift 2 ;;
        --branch-age-days) BRANCH_AGE_DAYS="$2"; shift 2 ;;
        --prune-remote-branches) PRUNE_REMOTE_BRANCHES=true; shift ;;
        --skip-worktrees) SKIP_WORKTREES=true; shift ;;
        --skip-logs) SKIP_LOGS=true; shift ;;
        --skip-branches) SKIP_BRANCHES=true; shift ;;
        --worktree-parent) WORKTREE_PARENT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>=3 && /^#===/ {c++; if(c==2) exit} NR>=3 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
ROOT_DIR=$(git rev-parse --show-toplevel)
[ "$(basename "$ROOT_DIR")" = "Trio-dev" ] || die "Must be run from the Trio-dev worktree (currently in: $(basename "$ROOT_DIR"))."
[ -n "$WORKTREE_PARENT" ] || WORKTREE_PARENT="${ROOT_DIR}/../.trio-worktrees"

# Retention flags must be non-negative integers — a non-numeric value would
# otherwise surface as a confusing arithmetic/slice error mid-run (destructive op).
case "$KEEP_WORKTREES"  in ''|*[!0-9]*) die "--keep-worktrees must be a non-negative integer (got: '$KEEP_WORKTREES')." ;; esac
case "$KEEP_LOGS"       in ''|*[!0-9]*) die "--keep-logs must be a non-negative integer (got: '$KEEP_LOGS')." ;; esac
case "$BRANCH_AGE_DAYS" in ''|*[!0-9]*) die "--branch-age-days must be a non-negative integer (got: '$BRANCH_AGE_DAYS')." ;; esac
# Force base-10 so a leading-zero value (e.g. "08") isn't treated as invalid octal
# in the arithmetic below (which would abort under set -e with an opaque error).
KEEP_WORKTREES=$((10#$KEEP_WORKTREES))
KEEP_LOGS=$((10#$KEEP_LOGS))
BRANCH_AGE_DAYS=$((10#$BRANCH_AGE_DAYS))

if [ "$APPLY" = true ]; then
    print_warning "APPLY mode — deletions will be performed."
else
    print_info "DRY-RUN — no changes will be made (pass --apply to delete)."
fi

# Run a deletion command, or just describe it in dry-run.
_do() {  # $1 = human description; rest = command
    local desc="$1"; shift
    if [ "$APPLY" = true ]; then
        echo "  delete: $desc"
        "$@" || print_warning "failed: $desc"
    else
        echo "  would delete: $desc"
    fi
}

#-------------------------------------------------------------------------------
# 1. Build worktrees — keep newest N (by timestamp embedded in the name).
#-------------------------------------------------------------------------------
if [ "$SKIP_WORKTREES" = true ]; then
    print_step "Worktrees (skipped)"
else
    print_step "Build worktrees in $WORKTREE_PARENT (keep newest $KEEP_WORKTREES)"
    if [ -d "$WORKTREE_PARENT" ]; then
        # Names sort lexicographically = chronologically (ci-build-YYYYMMDD-HHMMSS).
        _wts=()
        while IFS= read -r _line; do [ -n "$_line" ] && _wts+=("$_line"); done \
            < <(find "$WORKTREE_PARENT" -maxdepth 1 -type d -name 'ci-build-*' 2>/dev/null | sort)
        _total=${#_wts[@]}
        if [ "$_total" -le "$KEEP_WORKTREES" ]; then
            print_info "$_total worktree(s) present; nothing to prune."
        else
            _prune_count=$(( _total - KEEP_WORKTREES ))
            print_info "$_total present; pruning oldest $_prune_count."
            for _wt in "${_wts[@]:0:$_prune_count}"; do
                if [ "$APPLY" = true ]; then
                    echo "  delete: worktree $_wt"
                    # Mirror ci/local-build.sh cleanup(): deregister via git, then make
                    # sure the directory is actually gone. Checking the path AFTER the
                    # remove covers both "git remove failed" and "git deregistered but
                    # left the directory" (e.g. a permission/sandbox block) — the exact
                    # half-state seen during the 2026-06 housekeeping run.
                    git -C "$ROOT_DIR" worktree remove --force "$_wt" 2>/dev/null \
                        || print_warning "git worktree remove reported an error for $_wt"
                    if [ -d "$_wt" ]; then
                        rm -rf "$_wt" || print_warning "failed to delete directory $_wt"
                    fi
                else
                    echo "  would delete: worktree $_wt"
                fi
            done
            [ "$APPLY" = true ] && git -C "$ROOT_DIR" worktree prune >/dev/null 2>&1 || true
        fi
    else
        print_info "No worktree parent dir; nothing to prune."
    fi
fi

#-------------------------------------------------------------------------------
# 2. Build logs — keep newest N.
#-------------------------------------------------------------------------------
if [ "$SKIP_LOGS" = true ]; then
    print_step "Build logs (skipped)"
else
    print_step "Build logs in build/artifacts (keep newest $KEEP_LOGS)"
    _logdir="$ROOT_DIR/build/artifacts"
    if [ -d "$_logdir" ]; then
        _logs=()
        while IFS= read -r _line; do [ -n "$_line" ] && _logs+=("$_line"); done \
            < <(find "$_logdir" -maxdepth 1 -type f -name 'ci-local-build-*.log' 2>/dev/null | sort)
        _total=${#_logs[@]}
        if [ "$_total" -le "$KEEP_LOGS" ]; then
            print_info "$_total log(s) present; nothing to prune."
        else
            _prune_count=$(( _total - KEEP_LOGS ))
            print_info "$_total present; pruning oldest $_prune_count."
            for _lg in "${_logs[@]:0:$_prune_count}"; do
                _do "log $(basename "$_lg")" rm -f "$_lg"
            done
        fi
    else
        print_info "No build/artifacts dir; nothing to prune."
    fi
fi

#-------------------------------------------------------------------------------
# 3. Remote ci-build/* branches older than the age threshold (OPT-IN deletion).
#-------------------------------------------------------------------------------
if [ "$SKIP_BRANCHES" = true ]; then
    print_step "Remote ci-build/* branches (skipped)"
else
    print_step "Remote ci-build/* branches older than $BRANCH_AGE_DAYS days"
    git -C "$ROOT_DIR" fetch origin --prune >/dev/null 2>&1 || print_warning "git fetch failed; remote branch list may be stale."
    _now=$(date +%s)
    _cutoff=$(( _now - BRANCH_AGE_DAYS * 86400 ))
    _found=0
    # Convert an embedded YYYYMMDDTHHMMSSZ stamp to epoch seconds (empty on failure).
    # macOS BSD date first, then a GNU fallback.
    _iso_basic_to_epoch() {
        date -j -u -f '%Y%m%dT%H%M%SZ' "$1" +%s 2>/dev/null \
          || date -u -d "${1:0:8} ${1:9:2}:${1:11:2}:${1:13:2}" +%s 2>/dev/null
    }
    while read -r _ref _ts; do
        [ -n "$_ref" ] || continue
        _found=$(( _found + 1 ))
        _branch="${_ref#origin/}"
        # Prefer the PUSH timestamp embedded in the branch name
        # (ci-build/<tag>-<YYYYMMDDTHHMMSSZ>): record-release.sh points these at fork
        # SHAs that may be far older than the push, so the tip commit date
        # (committerdate) understates the branch's true age and would make freshly
        # pushed branches look like deletion candidates. Fall back to committerdate
        # when the suffix isn't parseable.
        _suffix=$(printf '%s\n' "$_branch" | grep -oE '[0-9]{8}T[0-9]{6}Z' | tail -1)
        if [ -n "$_suffix" ]; then
            _pushts=$(_iso_basic_to_epoch "$_suffix")
            case "$_pushts" in ''|*[!0-9]*) ;; *) _ts="$_pushts" ;; esac
        fi
        _age_days=$(( (_now - _ts) / 86400 ))
        if [ "$_ts" -lt "$_cutoff" ]; then
            if [ "$PRUNE_REMOTE_BRANCHES" = true ]; then
                _do "remote branch $_branch (${_age_days}d old)" \
                    git -C "$ROOT_DIR" push origin --delete "$_branch"
            else
                echo "  candidate (not deleted; pass --prune-remote-branches): $_branch (${_age_days}d old)"
            fi
        fi
    done < <(git -C "$ROOT_DIR" for-each-ref \
                --format='%(refname:short) %(committerdate:unix)' \
                'refs/remotes/origin/ci-build/*' 2>/dev/null)
    [ "$_found" -eq 0 ] && print_info "No remote ci-build/* branches found."
fi

echo ""
if [ "$APPLY" = true ]; then
    print_success "Cleanup complete."
else
    print_info "Dry-run complete. Re-run with --apply to delete the items above."
fi
