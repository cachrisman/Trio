#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./ci/local-build.sh [options]

Build Modes:
  --build-only               Build IPA + dSYMs only (skip TestFlight upload)
  --release-only             Upload existing IPA to TestFlight (no build, no patches)
                             Requires --ipa-path or Trio.ipa in repo root

Options:
  --base-branch <name>       Base branch to build from (default: dev)
  --build-current            Build current branch state (skip patches)
  --skip-patches             Skip patch application
  --reapply-stash            Apply local tracked changes into the worktree
  --no-reapply-stash         Do not apply local tracked changes
  --include-untracked        Copy untracked files into the worktree
  --include-project-file     Include Trio.xcodeproj/project.pbxproj from local changes
  --ipa-path <path>          Path to existing IPA file (used with --release-only)
  --sync-all                 Allow sync_project_files.rb to scan full globs
  --sync-explicit-only       Only sync explicit file list (default)
  --sync-upstream            Fetch upstream/dev and merge before building
                             (automatic for --base-branch dev, use this flag
                             to enable for other base branches)
  --no-sync-upstream         Skip upstream sync even for --base-branch dev
  --worktree-parent <path>   Parent dir for temporary worktrees
  --preserve-worktree        Preserve worktree after build (for debugging)
  -h, --help                 Show this help

Examples:
  # Build only (no TestFlight upload)
  ./ci/local-build.sh --build-only

  # Upload existing IPA from default location (./Trio.ipa)
  ./ci/local-build.sh --release-only

  # Upload IPA from custom path
  ./ci/local-build.sh --release-only --ipa-path /path/to/Trio.ipa

  # Full build + upload from dev with patches
  ./ci/local-build.sh --base-branch dev
USAGE
}

BUNDLER_VERSION="2.6.2"

BASE_BRANCH="dev"
BASE_BRANCH_SET=false
BUILD_CURRENT=0
SKIP_PATCHES=0
BUILD_ONLY=0
RELEASE_ONLY=0
REAPPLY_STASH=""
INCLUDE_UNTRACKED=0
WORKTREE_PARENT=""
INCLUDE_PROJECT_FILE=0
SYNC_EXPLICIT_ONLY=""
IPA_PATH=""
PRESERVE_WORKTREE=0
SYNC_UPSTREAM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-branch=*)
      BASE_BRANCH="${1#*=}"
      BASE_BRANCH_SET=true
      ;;
    --base-branch)
      shift
      BASE_BRANCH="${1:-}"
      BASE_BRANCH_SET=true
      ;;
    --build-current)
      BUILD_CURRENT=1
      ;;
    --skip-patches)
      SKIP_PATCHES=1
      ;;
    --reapply-stash)
      REAPPLY_STASH=1
      ;;
    --no-reapply-stash)
      REAPPLY_STASH=0
      ;;
    --include-untracked)
      INCLUDE_UNTRACKED=1
      ;;
    --include-project-file)
      INCLUDE_PROJECT_FILE=1
      ;;
    --build-only)
      BUILD_ONLY=1
      ;;
    --release-only)
      RELEASE_ONLY=1
      ;;
    --ipa-path=*)
      IPA_PATH="${1#*=}"
      ;;
    --ipa-path)
      shift
      IPA_PATH="${1:-}"
      ;;
    --sync-all)
      SYNC_EXPLICIT_ONLY=0
      ;;
    --sync-explicit-only)
      SYNC_EXPLICIT_ONLY=1
      ;;
    --worktree-parent)
      shift
      WORKTREE_PARENT="${1:-}"
      ;;
    --sync-upstream)
      SYNC_UPSTREAM=1
      ;;
    --no-sync-upstream)
      SYNC_UPSTREAM=0
      ;;
    --preserve-worktree)
      PRESERVE_WORKTREE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

########################################
# Argument validation
########################################

# Check for conflicting options
if [[ "$RELEASE_ONLY" = "1" && "$BUILD_ONLY" = "1" ]]; then
  echo ""
  echo "[build] ⚠️  WARNING: --release-only and --build-only are mutually exclusive."
  echo "[build]    --release-only uploads an existing IPA (no build)"
  echo "[build]    --build-only builds an IPA (no upload)"
  echo ""
  usage
  exit 1
fi

# Check for --ipa-path without --release-only
if [[ -n "$IPA_PATH" && "$RELEASE_ONLY" != "1" ]]; then
  echo ""
  echo "[build] ⚠️  WARNING: --ipa-path requires --release-only."
  echo "[build]    The --ipa-path option specifies an existing IPA to upload."
  echo ""
  echo "[build]    Usage: ./ci/local-build.sh --release-only --ipa-path /path/to/Trio.ipa"
  echo ""
  usage
  exit 1
fi

# Check for conflicting build options
if [[ "$BUILD_CURRENT" = "1" && "$BASE_BRANCH_SET" = "true" ]]; then
  echo ""
  echo "[build] ⚠️  WARNING: --build-current and --base-branch are typically not used together."
  echo "[build]    --build-current: builds current branch state"
  echo "[build]    --base-branch: specifies which branch to start from"
  echo ""
  echo "[build]    Continuing with --build-current behavior (ignoring --base-branch)..."
  echo ""
fi

########################################
# helper / state
########################################
ROOT_DIR="$(pwd)"
PATCHES_DIR=""
BUILD_DIR="$ROOT_DIR"
WORKTREE_DIR=""
WORKTREE_CREATED=false
WORKTREE_PATCH_DIR=""
EXPLICIT_SYNC_FILE=""
orig_branch=""
orig_commit=""
cleanup_enabled=false
cleanup_in_progress=false
preserve_worktree=false
staged_summary=""
unstaged_summary=""
untracked_summary=""

########################################
# Stage timing infrastructure
########################################
STAGE_NAMES=()
STAGE_DURATIONS=()
STAGE_START_TIMESTAMPS=()
STAGE_END_TIMESTAMPS=()
STAGE_START_TIME=""
STAGE_START_TIMESTAMP=""
CURRENT_STAGE=""
BUILD_START_TIME=""

stage_start() {
  local stage_name="$1"
  CURRENT_STAGE="$stage_name"
  STAGE_START_TIME=$(date +%s)
  STAGE_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  echo ""
  echo "────────────────────────────────────────"
  echo "[stage] ▶ Starting: $stage_name"
  echo "────────────────────────────────────────"
}

stage_end() {
  local status="${1:-success}"
  if [[ -z "$STAGE_START_TIME" || -z "$CURRENT_STAGE" ]]; then
    return
  fi
  
  local end_time=$(date +%s)
  local end_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local duration=$((end_time - STAGE_START_TIME))
  
  STAGE_NAMES+=("$CURRENT_STAGE")
  STAGE_DURATIONS+=("$duration")
  STAGE_START_TIMESTAMPS+=("$STAGE_START_TIMESTAMP")
  STAGE_END_TIMESTAMPS+=("$end_timestamp")
  
  local formatted_duration
  formatted_duration=$(format_duration "$duration")
  
  if [[ "$status" == "success" ]]; then
    echo "[stage] ✓ Completed: $CURRENT_STAGE ($formatted_duration)"
  else
    echo "[stage] ✗ Failed: $CURRENT_STAGE ($formatted_duration)"
  fi
  
  STAGE_START_TIME=""
  STAGE_START_TIMESTAMP=""
  CURRENT_STAGE=""
}

format_duration() {
  local seconds="$1"
  if [[ $seconds -lt 60 ]]; then
    echo "${seconds}s"
  elif [[ $seconds -lt 3600 ]]; then
    local mins=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${mins}m ${secs}s"
  else
    local hours=$((seconds / 3600))
    local mins=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    echo "${hours}h ${mins}m ${secs}s"
  fi
}

print_stage_summary() {
  local final_status="${1:-success}"
  local total_duration=0
  local build_end_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  if [[ -n "$BUILD_START_TIME" ]]; then
    local end_time=$(date +%s)
    total_duration=$((end_time - BUILD_START_TIME))
  fi
  
  # Calculate column widths
  local max_name_len=30
  for name in "${STAGE_NAMES[@]}"; do
    local len=${#name}
    if [[ $len -gt $max_name_len ]]; then
      max_name_len=$len
    fi
  done
  
  # Total width: "║  " (3) + name (max_name_len) + "  " (2) + duration (10) + "  ║" (3) = max_name_len + 18
  local inner_width=$((max_name_len + 14))
  local total_width=$((inner_width + 4))
  
  # Build the box
  local top_border="╔$(printf '═%.0s' $(seq 1 $inner_width))╗"
  local mid_border="╠$(printf '═%.0s' $(seq 1 $inner_width))╣"
  local bot_border="╚$(printf '═%.0s' $(seq 1 $inner_width))╝"
  
  # Center the title
  local title="BUILD STAGE SUMMARY"
  local title_len=${#title}
  local title_padding=$(( (inner_width - title_len) / 2 ))
  local title_line="║$(printf ' %.0s' $(seq 1 $title_padding))${title}$(printf ' %.0s' $(seq 1 $((inner_width - title_padding - title_len))))║"
  
  echo ""
  echo "$top_border"
  echo "$title_line"
  echo "$mid_border"
  
  local i=0
  for name in "${STAGE_NAMES[@]}"; do
    local duration="${STAGE_DURATIONS[$i]}"
    local formatted
    formatted=$(format_duration "$duration")
    printf "║  %-${max_name_len}s  %8s  ║\n" "$name" "$formatted"
    i=$((i + 1))
  done
  
  echo "$mid_border"
  
  local total_formatted
  total_formatted=$(format_duration "$total_duration")
  
  if [[ "$final_status" == "success" ]]; then
    printf "║  %-${max_name_len}s  %8s  ║\n" "✅ TOTAL (Success)" "$total_formatted"
  else
    printf "║  %-${max_name_len}s  %8s  ║\n" "❌ TOTAL (Failed)" "$total_formatted"
  fi
  
  echo "$bot_border"
  echo ""
  
  # Write detailed timestamps to log file only (bypass tee)
  if [[ -n "$LOGFILE" && -f "$LOGFILE" ]]; then
    {
      echo ""
      echo "=== DETAILED STAGE TIMING (with timestamps) ==="
      echo ""
      printf "%-32s  %-20s  %-20s  %10s\n" "Stage" "Start" "End" "Duration"
      printf "%-32s  %-20s  %-20s  %10s\n" "-----" "-----" "---" "--------"
      
      local j=0
      for name in "${STAGE_NAMES[@]}"; do
        local duration="${STAGE_DURATIONS[$j]}"
        local start_ts="${STAGE_START_TIMESTAMPS[$j]}"
        local end_ts="${STAGE_END_TIMESTAMPS[$j]}"
        local formatted
        formatted=$(format_duration "$duration")
        printf "%-32s  %-20s  %-20s  %10s\n" "$name" "$start_ts" "$end_ts" "$formatted"
        j=$((j + 1))
      done
      
      echo ""
      printf "%-32s  %-20s  %-20s  %10s\n" "TOTAL" "" "$build_end_timestamp" "$total_formatted"
      echo ""
    } >> "$LOGFILE"
  fi
  
  # Write plain-text stage summary for release recording (no timestamps, simple format)
  local summary_file="$ROOT_DIR/build/artifacts/stage-summary.txt"
  mkdir -p "$(dirname "$summary_file")"
  {
    local k=0
    for name in "${STAGE_NAMES[@]}"; do
      local duration="${STAGE_DURATIONS[$k]}"
      local formatted
      formatted=$(format_duration "$duration")
      printf "%-32s  %10s\n" "$name" "$formatted"
      k=$((k + 1))
    done
    echo "--------------------------------  ----------"
    if [[ "$final_status" == "success" ]]; then
      printf "%-32s  %10s\n" "TOTAL (Success)" "$total_formatted"
    else
      printf "%-32s  %10s\n" "TOTAL (Failed)" "$total_formatted"
    fi
  } > "$summary_file"
}

normalize_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$path"
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
    return
  fi
  echo "$path"
}

# ensure artifacts dir exists before we create the logfile reference
mkdir -p "$ROOT_DIR/build/artifacts"
umask 0022
LOGFILE="$ROOT_DIR/build/artifacts/ci-local-build-$(date +%Y%m%d-%H%M%S).log"

# capture all output to logfile and stdout (once, safely)
# this prevents intermittent 'tee: ... No such file or directory' caused by race/dir absence
exec > >(tee -a "$LOGFILE") 2>&1

# Silence Fastlane & Bundler noise globally for this build
export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_DONT_STORE_PASSWORD=1

export BUNDLE_SILENCE_ROOT_WARNING=1
export BUNDLE_DISABLE_VERSION_CHECK=true

# Prevent interactive prompts during git operations (but allow SSH for fastlane operations)
export GIT_TERMINAL_PROMPT=0

# Write a log header
echo "=== ci/local-build.sh starting at $(date -u) ==="
BUILD_START_TIME=$(date +%s)

########################################
# Helper function to capture and display fastlane errors
########################################

extract_xcodebuild_error_excerpt() {
  local raw_log_path="${1:-}"
  local max_matches="${2:-20}"
  local context_lines="${3:-2}"

  [[ -n "$raw_log_path" ]] || return 0
  [[ -f "$raw_log_path" ]] || return 0

  echo ""
  echo "=========================================="
  echo "[build] 🔎 Extracting compiler errors from raw xcodebuild log"
  echo "=========================================="
  echo "[build] Source: $raw_log_path"
  echo ""

  # Find the first N error lines. We intentionally match the Swift-style ": error:" format.
  # This is a best-effort extraction; the authoritative log remains the raw xcodebuild log.
  local match_lines
  match_lines="$(grep -nE '(^|: )fatal error:|(^|: )error:' "$raw_log_path" 2>/dev/null | head -n "$max_matches" | cut -d: -f1 || true)"

  if [[ -z "$match_lines" ]]; then
    echo "[build] No 'error:' lines found in raw xcodebuild log."
    echo ""
    return 0
  fi

  echo "=== Extracted compiler errors (first ${max_matches} matches, ±${context_lines} lines) ==="
  echo ""

  while IFS= read -r line_num; do
    [[ -n "$line_num" ]] || continue

    local start_line=$((line_num - context_lines))
    local end_line=$((line_num + context_lines))
    if [[ "$start_line" -lt 1 ]]; then
      start_line=1
    fi

    echo "---- context around line ${line_num} ----"

    if command -v nl >/dev/null 2>&1; then
      sed -n "${start_line},${end_line}p" "$raw_log_path" 2>/dev/null | nl -ba -w6 -s'| ' -v "$start_line" || true
    else
      # Fallback (no line numbers) if nl is unavailable.
      sed -n "${start_line},${end_line}p" "$raw_log_path" 2>/dev/null || true
    fi

    echo ""
  done <<< "$match_lines"

  echo "=== End extracted compiler errors ==="
  echo ""
}

capture_fastlane_errors() {
  local command="$1"
  local step_name="$2"
  local temp_output_file
  temp_output_file="$(mktemp)"

  echo "[build] Running '$command'..."

  set +e
  {
    eval "$command"
  } 2>&1 | tee "$temp_output_file"
  local exit_code="${PIPESTATUS[0]}"
  set -e

  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo "=========================================="
    echo "[build] ❌ $step_name FAILED (exit code: $exit_code)"
    echo "=========================================="
    echo ""
    echo "[build] Extracting error details from fastlane output..."
    echo ""

    local error_line_nums
    error_line_nums="$(grep -n "❌" "$temp_output_file" 2>/dev/null | cut -d: -f1 | sort -nu || echo "")"

    local error_sections=""
    if [[ -n "$error_line_nums" ]]; then
      while IFS= read -r line_num; do
        [[ -z "$line_num" ]] && continue
        local end_line=$((line_num + 2))
        local error_block
        error_block="$(sed -n "${line_num},${end_line}p" "$temp_output_file" 2>/dev/null || echo "")"
        if [[ -n "$error_block" ]]; then
          error_sections+="$error_block"$'\n'
          error_sections+="---"$'\n'
        fi
      done <<< "$error_line_nums"
    fi

    if [[ -n "$error_sections" ]]; then
      echo "=== Fastlane Error Details (❌ and next 2 lines) ==="
      echo "$error_sections"
      echo ""
    else
      echo "[build] No error lines with ❌ emoji found in output."
      echo "[build] Showing last 20 lines for context:"
      echo ""
      tail -n 20 "$temp_output_file" 2>/dev/null || echo ""
      echo ""
    fi

    # Option A: If xcodebuild failed, xcpretty sometimes hides the underlying Swift compiler diagnostics.
    # Fastlane usually writes the raw xcodebuild output to a log file via `tee`. We extract the first few
    # `error:` lines from that raw log so the *real* compiler error surfaces in this main build log.
    local raw_xcodebuild_log=""
    raw_xcodebuild_log="$(grep -Eo '/[^[:space:]]+/build/buildlog/LoopKit-Trio\.log' "$temp_output_file" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "$raw_xcodebuild_log" && -n "${BUILD_DIR:-}" ]]; then
      # Best-effort fallback (matches our local-build worktree layout).
      raw_xcodebuild_log="$BUILD_DIR/build/buildlog/LoopKit-Trio.log"
    fi
    extract_xcodebuild_error_excerpt "$raw_xcodebuild_log"

    echo "=========================================="
    echo "[build] Full build log available at: $LOGFILE"
    echo "=========================================="
    echo ""

    rm -f "$temp_output_file"
    return "$exit_code"
  fi

  rm -f "$temp_output_file"
  return 0
}

########################################
# 0. Load local env / secrets
########################################

if [[ -f "$ROOT_DIR/.trio-env" ]]; then
  echo "[build] Loading environment from .trio-env"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.trio-env"
  set +a
fi

########################################
# 0.5. Early prompt (before heavy work)
########################################

if git rev-parse --git-dir >/dev/null 2>&1; then
  orig_branch="$(git rev-parse --abbrev-ref HEAD || echo "HEAD")"

  if [[ "$BUILD_CURRENT" != "1" && "$BASE_BRANCH_SET" = false && "$orig_branch" != "dev" ]]; then
    if [[ -t 0 && -z "${CI:-}" && -e /dev/tty ]]; then
      echo ""
      echo "[build] You are on a non-dev branch: $orig_branch"
      echo "[build] Choose how to build:"
      echo "  1) Start from dev, apply patches, then build (default)"
      echo "  2) Build the current branch state (skip patches)"
      # stdout is piped to tee; use /dev/tty to ensure prompt is visible
      printf "[build] Enter 1 or 2 (default: 1): " > /dev/tty
      read -r build_choice < /dev/tty

      case "$build_choice" in
        2|b|B)
          BUILD_CURRENT=1
          SKIP_PATCHES=1
          BASE_BRANCH="$orig_branch"
          REAPPLY_STASH=1
          ;;
        1|a|A|"")
          BASE_BRANCH="dev"
          REAPPLY_STASH=0
          ;;
        *)
          echo "[build] Unrecognized choice; defaulting to build current state."
          BUILD_CURRENT=1
          SKIP_PATCHES=1
          BASE_BRANCH="$orig_branch"
          REAPPLY_STASH=1
          ;;
      esac
    else
      echo "[build] Non-dev branch and non-interactive; defaulting to build current state."
      BUILD_CURRENT=1
      SKIP_PATCHES=1
      BASE_BRANCH="$orig_branch"
      REAPPLY_STASH=1
    fi

    # Mark as set so we don't re-prompt later.
    BASE_BRANCH_SET=true
  fi
fi

for var in TEAMID GH_PAT FASTLANE_KEY_ID FASTLANE_ISSUER_ID FASTLANE_KEY MATCH_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "[build] ERROR: Environment variable $var is not set. Configure it in .trio-env or your shell."
    exit 1
  fi
done

if [[ -z "${GITHUB_WORKSPACE:-}" ]]; then
  export GITHUB_WORKSPACE="$ROOT_DIR"
fi

if [[ -z "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
  export GITHUB_REPOSITORY_OWNER="cachrisman"  # adjust if needed
fi

########################################
# Auto-detect LOCAL_CI context
########################################

# Auto-detect LOCAL_CI=1 when appropriate (for release recording)
# Heuristic: if CI=true or GITHUB_ACTIONS=true, do nothing (record-release will classify as cloudCI)
# For local runs: if stdin is not a TTY OR TERM is empty OR TRIO_AGENT=1 => LOCAL_CI=1
if [[ "${CI:-}" != "true" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
  if [[ ! -t 0 ]] || [[ -z "${TERM:-}" ]] || [[ "${TRIO_AGENT:-}" == "1" ]]; then
    export LOCAL_CI=1
    echo "[build] Auto-detected LOCAL_CI=1 (non-interactive or agent context)"
  fi
fi

########################################
# RELEASE-ONLY MODE (no build)
########################################

if [[ "$RELEASE_ONLY" = "1" ]]; then
  echo "[build] RELEASE_ONLY=1 — skipping worktree, patches, and build."

  stage_start "Setup (Release-Only)"

  # Determine IPA path: use --ipa-path if provided, otherwise default to $ROOT_DIR/Trio.ipa
  RELEASE_IPA_PATH="${IPA_PATH:-$ROOT_DIR/Trio.ipa}"

  if [[ ! -f "$RELEASE_IPA_PATH" ]]; then
    echo ""
    echo "[build] ❌ ERROR: IPA file not found at: $RELEASE_IPA_PATH"
    echo ""
    if [[ -n "$IPA_PATH" ]]; then
      echo "[build]    The specified --ipa-path does not exist."
      echo "[build]    Check the path and try again."
    else
      echo "[build]    No IPA found at the default location ($ROOT_DIR/Trio.ipa)."
      echo "[build]    Options:"
      echo "[build]      1. Build first:  ./ci/local-build.sh --build-only"
      echo "[build]      2. Specify path: ./ci/local-build.sh --release-only --ipa-path /path/to/Trio.ipa"
    fi
    echo ""
    exit 1
  fi

  echo "[build] Using IPA: $RELEASE_IPA_PATH"

  # Copy IPA to expected location if using custom path
  if [[ "$RELEASE_IPA_PATH" != "$ROOT_DIR/Trio.ipa" ]]; then
    echo "[build] Copying IPA to $ROOT_DIR/Trio.ipa for fastlane..."
    cp -f "$RELEASE_IPA_PATH" "$ROOT_DIR/Trio.ipa"
  fi

  echo "[build] Running bundle _${BUNDLER_VERSION}_ install (safe)..."
  bundle _${BUNDLER_VERSION}_ install

  if [[ "${FASTLANE_KEY:-}" == *"\\n"* ]]; then
    printf '%s\n' "[build] Detected '\\n' sequences in FASTLANE_KEY; converting to real newlines..."
    FASTLANE_KEY="$(printf '%b' "$FASTLANE_KEY")"
    export FASTLANE_KEY
  else
    echo "[build] FASTLANE_KEY appears to be multi-line already."
  fi

  stage_end

  cd "$ROOT_DIR"

  stage_start "TestFlight Upload"
  if ! capture_fastlane_errors "bundle _${BUNDLER_VERSION}_ exec fastlane release" "Release step"; then
    release_exit_code=$?
    exit $release_exit_code
  fi
  stage_end

  echo "[build] TestFlight upload finished successfully."

  ########################################
  # Record release (after successful TestFlight upload)
  ########################################

  stage_start "Record Release"
  echo "[build] Recording release to GitHub..."

  if [[ -f "$ROOT_DIR/Trio.ipa" ]]; then
    if IPA_PATH="$ROOT_DIR/Trio.ipa" "$ROOT_DIR/scripts/record-release.sh"; then
      echo "[build] Release recorded successfully."
    else
      echo "[build] WARNING: Release recording failed, but build/upload succeeded."
    fi
  else
    echo "[build] WARNING: Could not find IPA for release recording."
  fi
  stage_end

  print_stage_summary "success"
  exit 0
fi

########################################
# 1. Sanity checks for tools
########################################

stage_start "Environment & Tool Validation"

echo "[build] Checking required tools..."

for cmd in xcodebuild ruby git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[build] ERROR: '$cmd' is not installed or not on PATH."
    exit 1
  fi
done

if ! command -v bundle >/dev/null 2>&1; then
  echo "[build] ERROR: 'bundle' is not installed or not on PATH."
  echo "[build] Install Bundler ${BUNDLER_VERSION}, e.g.:"
  echo "  gem install --user-install bundler:${BUNDLER_VERSION}"
  exit 1
fi

echo "[build] Ruby:    $(ruby -v)"
echo "[build] Bundler: $(bundle _${BUNDLER_VERSION}_ -v || echo 'bundler not found for this version')"
echo "[build] Xcode:   $(xcode-select -p)"
xcodebuild -version || true

stage_end

########################################
# 2. (Optional) Select Xcode version
########################################
# sudo xcode-select --switch /Applications/Xcode_16.4.app/Contents/Developer || true

########################################
# WORKTREE + PATCH APPLY / CLEANUP
########################################

copy_untracked_files() {
  local src_root="$1"
  local dst_root="$2"
  local files="$3"
  local copied=0

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if should_exclude_untracked "$path"; then
      continue
    fi
    copied=$((copied + 1))
    mkdir -p "$dst_root/$(dirname "$path")"
    cp -a "$src_root/$path" "$dst_root/$path"
  done <<< "$files"

  echo "[build] Copied $copied untracked file(s) into worktree."
}

should_exclude_untracked() {
  local path="$1"

  if [[ "$INCLUDE_PROJECT_FILE" != "1" && "$path" = "Trio.xcodeproj/project.pbxproj" ]]; then
    return 0
  fi

  return 1
}

apply_local_changes_to_worktree() {
  if [[ "$REAPPLY_STASH" != "1" ]]; then
    return 0
  fi

  if [[ -z "$staged_summary" && -z "$unstaged_summary" && -z "$untracked_summary" ]]; then
    echo "[build] No local changes to apply to worktree."
    return 0
  fi

  WORKTREE_PATCH_DIR="$(mktemp -d "${ROOT_DIR}/build/worktree-patches-XXXXXX")"
  local staged_patch="$WORKTREE_PATCH_DIR/staged.patch"
  local unstaged_patch="$WORKTREE_PATCH_DIR/unstaged.patch"

  local excluded=()
  if [[ "$INCLUDE_PROJECT_FILE" != "1" ]]; then
    excluded+=("Trio.xcodeproj/project.pbxproj")
  fi

  local exclude_specs=()
  for path in "${excluded[@]}"; do
    exclude_specs+=(":(exclude)$path")
  done
  git -C "$ROOT_DIR" diff --cached --binary -- . "${exclude_specs[@]}" > "$staged_patch"
  git -C "$ROOT_DIR" diff --binary -- . "${exclude_specs[@]}" > "$unstaged_patch"

  if [[ -s "$staged_patch" ]]; then
    echo "[build] Applying staged changes to worktree..."
    git -C "$WORKTREE_DIR" apply --whitespace=nowarn "$staged_patch"
  fi

  if [[ -s "$unstaged_patch" ]]; then
    echo "[build] Applying unstaged changes to worktree..."
    git -C "$WORKTREE_DIR" apply --whitespace=nowarn "$unstaged_patch"
  fi

  if [[ -n "$untracked_summary" ]]; then
    if [[ "$INCLUDE_UNTRACKED" = "1" ]]; then
      echo "[build] Copying untracked files into worktree (INCLUDE_UNTRACKED=1)..."
      copy_untracked_files "$ROOT_DIR" "$WORKTREE_DIR" "$untracked_summary"
    else
      echo "[build] Untracked files not copied to worktree."
      echo "[build] Set --include-untracked to include them."
    fi
  fi
}

prepare_explicit_sync_list() {
  if [[ "$REAPPLY_STASH" != "1" ]]; then
    return 0
  fi

  if [[ -z "$staged_summary" && -z "$unstaged_summary" && -z "$untracked_summary" ]]; then
    return 0
  fi

  mkdir -p "$BUILD_DIR/build"
  local raw_file
  local filtered_file
  raw_file="$(mktemp "$BUILD_DIR/build/explicit-sync-raw-XXXXXX.txt")"
  filtered_file="$(mktemp "$BUILD_DIR/build/explicit-sync-filtered-XXXXXX.txt")"
  : > "$raw_file"

  if [[ -n "$staged_summary" ]]; then
    git -C "$ROOT_DIR" diff --cached --name-only -- >> "$raw_file"
  fi
  if [[ -n "$unstaged_summary" ]]; then
    git -C "$ROOT_DIR" diff --name-only -- >> "$raw_file"
  fi
  if [[ "$INCLUDE_UNTRACKED" = "1" && -n "$untracked_summary" ]]; then
    git -C "$ROOT_DIR" ls-files --others --exclude-standard >> "$raw_file"
  fi

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ "$INCLUDE_PROJECT_FILE" != "1" && "$path" = "Trio.xcodeproj/project.pbxproj" ]]; then
      continue
    fi
    if [[ -f "$BUILD_DIR/$path" ]]; then
      echo "$path" >> "$filtered_file"
    fi
  done < "$raw_file"

  rm -f "$raw_file"

  if [[ ! -s "$filtered_file" ]]; then
    rm -f "$filtered_file"
    return 0
  fi

  EXPLICIT_SYNC_FILE="$(mktemp "$BUILD_DIR/build/explicit-sync-files-XXXXXX.txt")"
  LC_ALL=C sort -u "$filtered_file" > "$EXPLICIT_SYNC_FILE"
  rm -f "$filtered_file"

  export SYNC_EXPLICIT_FILE_LIST="$EXPLICIT_SYNC_FILE"
  local count
  count=$(wc -l < "$EXPLICIT_SYNC_FILE" | tr -d ' ')
  echo "[build] Passing explicit sync file list with $count file(s)."
}

cleanup() {
  local exit_code=$?
  # Disable exit-on-error in cleanup to ensure we try all cleanup steps
  set +e
  
  if [[ "$cleanup_in_progress" = true ]]; then
    exit "$exit_code"
  fi
  cleanup_in_progress=true

  # End any in-progress stage
  if [[ -n "$CURRENT_STAGE" ]]; then
    stage_end "failed"
  fi

  # Print stage summary if we have any stages recorded
  if [[ ${#STAGE_NAMES[@]} -gt 0 ]]; then
    if [[ $exit_code -eq 0 ]]; then
      print_stage_summary "success"
    else
      print_stage_summary "failed"
    fi
  fi

  if [[ "$cleanup_enabled" != true ]]; then
    echo "=== cleanup invoked (exit code: $exit_code) ==="
    echo "[cleanup] Cleanup not initialized; skipping git cleanup"
    echo "=== cleanup complete ==="
    exit "$exit_code"
  fi

  echo "=== cleanup invoked (exit code: $exit_code) ==="

  if [[ "$WORKTREE_CREATED" = true && -n "$WORKTREE_DIR" ]]; then
    normalized_worktree="$(normalize_path "$WORKTREE_DIR")"
    if [[ "$preserve_worktree" = true || "$PRESERVE_WORKTREE" = "1" ]]; then
      echo "[cleanup] Preserving worktree at $normalized_worktree"
    else
      echo "[cleanup] Removing worktree at $normalized_worktree"
      cd "$ROOT_DIR" >/dev/null 2>&1 || true
      if ! git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1; then
        echo "[cleanup] Warning: failed to remove worktree via git; deleting directory"
        rm -rf "$WORKTREE_DIR"
      fi
      git worktree prune >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "$WORKTREE_PATCH_DIR" && -d "$WORKTREE_PATCH_DIR" ]]; then
    rm -rf "$WORKTREE_PATCH_DIR"
  fi
  if [[ -n "$EXPLICIT_SYNC_FILE" && -f "$EXPLICIT_SYNC_FILE" ]]; then
    rm -f "$EXPLICIT_SYNC_FILE"
  fi
  if [[ -n "${BUILD_KC:-}" ]]; then
    echo "[cleanup] Removing ephemeral build keychain: $BUILD_KC"
    security delete-keychain "$BUILD_KC" 2>/dev/null || true
  fi

  echo "=== cleanup complete ==="
  exit "$exit_code"
}

trap cleanup EXIT

stage_start "Worktree Setup"

# prepare git state
if git rev-parse --git-dir >/dev/null 2>&1; then
  orig_branch="$(git rev-parse --abbrev-ref HEAD || echo "HEAD")"
  orig_commit="$(git rev-parse --verify HEAD || true)"
  echo "[build] Git original branch: $orig_branch"
  echo "[build] Git original commit: $orig_commit"

  if [[ "$BUILD_CURRENT" = "1" ]]; then
    SKIP_PATCHES=1
    if [[ -n "$orig_branch" && "$orig_branch" != "HEAD" ]]; then
      BASE_BRANCH="$orig_branch"
    fi
    if [[ -z "$REAPPLY_STASH" ]]; then
      REAPPLY_STASH=1
    fi
  fi

  if [[ "$BASE_BRANCH_SET" = false ]]; then
    if [[ -n "$orig_branch" && "$orig_branch" != "HEAD" ]]; then
      BASE_BRANCH="$orig_branch"
    else
      BASE_BRANCH="dev"
    fi
  fi

  base_ref="$BASE_BRANCH"
  if [[ -z "$base_ref" || "$base_ref" = "HEAD" ]]; then
    base_ref="$orig_commit"
  fi
  if [[ -z "$base_ref" ]]; then
    echo "[build] ERROR: Unable to determine a base ref for the build."
    exit 1
  fi
  if [[ "$base_ref" != "$orig_commit" ]]; then
    if ! git show-ref --verify --quiet "refs/heads/$base_ref"; then
      echo "[build] ERROR: Base branch '$base_ref' does not exist locally."
      exit 1
    fi
  fi
  echo "[build] Base ref for build: $base_ref"

  # Upstream sync: for --base-branch dev, default to syncing upstream/dev.
  # For other base branches, only sync if --sync-upstream is explicitly set.
  # Skip entirely for --build-current or detached HEAD.
  _do_sync=false
  if [[ "$SYNC_UPSTREAM" = "1" ]]; then
    _do_sync=true
  elif [[ -z "$SYNC_UPSTREAM" && "$base_ref" = "dev" && "$BUILD_CURRENT" != "1" ]]; then
    _do_sync=true
  fi

  if [[ "$_do_sync" = true && "$base_ref" != "$orig_commit" ]]; then
    if git remote get-url upstream >/dev/null 2>&1; then
      echo "[build] Fetching upstream/dev..."
      if git fetch upstream dev 2>&1 | sed 's/^/    /'; then
        _local_dev=$(git rev-parse dev 2>/dev/null || true)
        _upstream_dev=$(git rev-parse upstream/dev 2>/dev/null || true)
        if [[ -n "$_local_dev" && -n "$_upstream_dev" && "$_local_dev" != "$_upstream_dev" ]]; then
          _behind=$(git rev-list --count "dev..upstream/dev" 2>/dev/null || echo "?")
          echo "[build] Local dev is $_behind commit(s) behind upstream/dev. Merging..."
          if git merge upstream/dev --no-edit 2>&1 | sed 's/^/    /'; then
            echo "[build] ✅ Merged upstream/dev into local dev"
            echo "[build] Pushing updated dev to origin..."
            git push origin dev 2>&1 | sed 's/^/    /' || {
              echo "[build] ⚠️  Push to origin failed (non-fatal, continuing build)"
            }
          else
            echo "[build] ❌ Merge of upstream/dev failed. Aborting merge and continuing with current dev."
            git merge --abort 2>/dev/null || true
          fi
        else
          echo "[build] ✅ Local dev is up-to-date with upstream/dev"
        fi
      else
        echo "[build] ⚠️  Failed to fetch upstream (non-fatal, continuing with current dev)"
      fi
    else
      echo "[build] ⚠️  No 'upstream' remote configured; skipping sync"
    fi
  elif [[ "$SYNC_UPSTREAM" = "0" ]]; then
    echo "[build] Upstream sync: disabled (--no-sync-upstream)"
  fi

  # Log source patch hashes for provenance (before worktree setup).
  # Even if worktree creation fails, the log records which patches were on disk.
  _src_patches_dir="$ROOT_DIR/patches"
  if [[ -d "$_src_patches_dir" && "$SKIP_PATCHES" != "1" ]]; then
    _src_patch_list=$(cd "$_src_patches_dir" 2>/dev/null && ls -1 *.patch 2>/dev/null | sort)
    if [[ -n "$_src_patch_list" ]]; then
      echo "[build] Source patches (on-disk at build start):"
      echo ""
      printf "  %-45s  %s\n" "PATCH" "SHA256"
      printf "  %-45s  %s\n" "-----" "------"
      while IFS= read -r _sp; do
        [[ -n "$_sp" ]] || continue
        _sp_path="$_src_patches_dir/$_sp"
        _sp_hash="$(shasum -a 256 "$_sp_path" 2>/dev/null | cut -c1-12)"
        _sp_dirty=""
        if git status --porcelain -- "patches/$_sp" 2>/dev/null | grep -q .; then
          _sp_dirty=" (modified)"
        fi
        printf "  %-45s  %s%s\n" "$_sp" "$_sp_hash" "$_sp_dirty"
      done <<< "$_src_patch_list"
      echo ""
    fi
  fi

  cleanup_enabled=true
  status_summary="$(git status --short 2>/dev/null || echo "")"
  staged_summary="$(git diff --cached --name-status 2>/dev/null || echo "")"
  unstaged_summary="$(git diff --name-status 2>/dev/null || echo "")"
  untracked_summary="$(git ls-files --others --exclude-standard 2>/dev/null || echo "")"

  if [[ -n "$status_summary" ]]; then
    echo "[build] Detected local changes in current worktree:"
    echo "$status_summary" | sed 's/^/    /' || true
  else
    echo "[build] No uncommitted changes."
  fi

  planned_reapply="$REAPPLY_STASH"
  if [[ -z "$planned_reapply" ]]; then
    if [[ "$base_ref" = "$orig_branch" || "$base_ref" = "$orig_commit" ]]; then
      planned_reapply=1
    else
      planned_reapply=0
    fi
  fi
  REAPPLY_STASH="$planned_reapply"

  if [[ "$REAPPLY_STASH" = "1" ]]; then
    echo "[build] Local changes will be applied to the worktree."
    if [[ -n "$untracked_summary" && "$INCLUDE_UNTRACKED" != "1" ]]; then
      echo "[build] Note: untracked files will not be copied unless --include-untracked is set."
    fi
  else
    echo "[build] Local changes will NOT be applied to the worktree."
  fi

  if [[ -z "$WORKTREE_PARENT" ]]; then
    WORKTREE_PARENT="${ROOT_DIR}/../.trio-worktrees"
  fi
  mkdir -p "$WORKTREE_PARENT"
  worktree_suffix="$(date +%Y%m%d-%H%M%S)"
  WORKTREE_DIR="${WORKTREE_PARENT}/ci-build-${worktree_suffix}"
  if [[ -e "$WORKTREE_DIR" ]]; then
    WORKTREE_DIR="${WORKTREE_PARENT}/ci-build-${worktree_suffix}-$$"
  fi

  echo "[build] Creating worktree at $WORKTREE_DIR from $base_ref"
  if ! git worktree add --detach "$WORKTREE_DIR" "$base_ref" >/dev/null 2>&1; then
    echo "[build] ERROR: failed to create worktree from $base_ref."
    exit 1
  fi
  WORKTREE_CREATED=true
  BUILD_DIR="$WORKTREE_DIR"
  export GITHUB_WORKSPACE="$BUILD_DIR"

  if [[ -f "$WORKTREE_DIR/.gitmodules" ]]; then
    echo "[build] Initializing submodules in worktree..."
    git -C "$WORKTREE_DIR" submodule update --init --recursive 2>&1 | sed 's/^/    /' || {
      echo "[build] Warning: submodule init failed; build may fail if submodules are required."
    }
  fi

  apply_local_changes_to_worktree
  prepare_explicit_sync_list

  cd "$BUILD_DIR"
else
  echo "[build] WARNING: not in a git repo; skipping patch apply / worktree logic"
  BUILD_DIR="$ROOT_DIR"
  export GITHUB_WORKSPACE="$ROOT_DIR"
fi

PATCHES_DIR="$BUILD_DIR/patches"

stage_end

########################################
# 3. Ensure certs and Config.xcconfig (delegates to safe helper)
########################################

stage_start "Certificates & Config"

echo "[build] Running local_create_certs.sh to ensure certificates / config..."
# local_create_certs.sh should NOT call this script (avoid recursion). Fail fast if helper fails.
certs_script="$BUILD_DIR/ci/local_create_certs.sh"
if [[ ! -x "$certs_script" ]]; then
  certs_script="$ROOT_DIR/ci/local_create_certs.sh"
fi

if [[ ! -x "$certs_script" ]]; then
  echo "[build] ERROR: local_create_certs.sh not found in build root or repo root."
  exit 1
fi

(cd "$ROOT_DIR" && "$certs_script") || {
  echo "[build] ERROR: local_create_certs.sh failed; aborting."
  exit 1
}

# If Fastlane's cert lanes don't create Config.xcconfig, fail clearly here
if [[ ! -f "$BUILD_DIR/Config.xcconfig" && ! -f "/Config.xcconfig" ]]; then
  echo ""
  echo "[build] ERROR: Config.xcconfig not found in build root or at /Config.xcconfig."
  echo "[build] If upstream expects this file to exist, either:"
  echo "  - check it into the repo, or"
  echo "  - inspect the Fastfile's 'parse_xcconfig_file' to see where it expects"
  echo "    the file and what it should contain."
  echo ""
  exit 1
fi

stage_end

########################################
# 4. Customize Trio (patch application)
########################################

stage_start "Patch Application"

echo "[build] Running 'Customize Trio' step (patches)..."

if [[ "$SKIP_PATCHES" = "1" ]]; then
  echo "[build] Skipping patch application."
elif [[ -d "$PATCHES_DIR" ]]; then
  # Configure git identity for git am operations (local repo only)
  git -C "$BUILD_DIR" config user.name "Trio Build Bot" || true
  git -C "$BUILD_DIR" config user.email "build-bot@users.noreply.github.com" || true
  git -C "$BUILD_DIR" config commit.gpgsign false || true

  # Collect patches deterministically (bash 3.2 compatible)
  PATCH_LIST_FILE=$(mktemp)
  (cd "$PATCHES_DIR" 2>/dev/null && ls -1 *.patch 2>/dev/null | sort) \
  | awk '
      /^[0-9][0-9]-/ {
        p=substr($0, 1, 2)
        if (!(p in chosen)) { chosen[p]=$0 }
      }
      END { for (p in chosen) print p "\t" chosen[p] }
    ' \
  | sort \
  | awk -v dir="$PATCHES_DIR" '{ print dir "/" $2 }' > "$PATCH_LIST_FILE"

  if [[ -s "$PATCH_LIST_FILE" ]]; then
    echo "[build] Found patches to apply:"
    echo ""
    printf "  %-45s  %-12s  %s\n" "PATCH" "SHA256" "FROM"
    printf "  %-45s  %-12s  %s\n" "-----" "------" "----"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      _pname="$(basename "$p")"
      _phash="$(shasum -a 256 "$p" 2>/dev/null | cut -c1-12)"
      _pfrom="$(head -1 "$p" 2>/dev/null | sed 's/^From \([a-f0-9]*\).*/\1/' | cut -c1-12)"
      printf "  %-45s  %-12s  %s\n" "$_pname" "$_phash" "$_pfrom"
    done < "$PATCH_LIST_FILE"
    echo ""

    pre_patch_head="$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || true)"

    while IFS= read -r patch; do
      [[ -n "$patch" ]] || continue
      _pname="$(basename "$patch")"
      _phash="$(shasum -a 256 "$patch" 2>/dev/null | cut -c1-12)"
      echo "[build] Applying: $_pname (sha256:$_phash)"
      if git am --3way --keep-cr --whitespace=nowarn "$patch" >/dev/null 2>&1; then
        echo "[build] ✅ Applied: $_pname"
      else
        echo "[build] ❌ Failed to apply patch: $patch"
        git am --abort >/dev/null 2>&1 || true
        git am --3way --keep-cr --whitespace=nowarn "$patch" 2>&1 | sed 's/^/    /' || true
        rm -f "$PATCH_LIST_FILE"
        exit 1
      fi
    done < "$PATCH_LIST_FILE"
    rm -f "$PATCH_LIST_FILE"

    # After patches are applied, check if any submodule references were modified
    # and update submodules if needed
    if [[ -f "$BUILD_DIR/.gitmodules" ]]; then
      # Check if .gitmodules or any submodule directory was modified in this patch set
      SUBMODULE_MODIFIED=false
      if [[ -n "$pre_patch_head" ]]; then
        patch_changes="$(git -C "$BUILD_DIR" diff --name-only "$pre_patch_head" HEAD)"
        if printf '%s\n' "$patch_changes" | grep -q "^\.gitmodules$"; then
          SUBMODULE_MODIFIED=true
        fi
        # Check if any submodule commit reference was modified
        if printf '%s\n' "$patch_changes" | grep -qE '^(G7SensorKit|CGMBLEKit|DanaKit|OmniKit|OmniBLE|MinimedKit|LibreTransmitter|TidepoolService|RileyLinkKit|LoopKit|dexcom-share-client-swift)$'; then
          SUBMODULE_MODIFIED=true
        fi
      else
        SUBMODULE_MODIFIED=true
      fi

      if [[ "$SUBMODULE_MODIFIED" == "true" ]]; then
        echo "[build] Detected submodule changes in patches, updating submodules..."
        # Sync submodule URLs from .gitmodules
        git -C "$BUILD_DIR" submodule sync --recursive 2>&1 | sed 's/^/    /' || {
          echo "[build] Warning: submodule sync failed"
        }
        # Update submodules to match the commit references in the index
        git -C "$BUILD_DIR" submodule update --init --recursive 2>&1 | sed 's/^/    /' || {
          echo "[build] Warning: submodule update after patches failed"
        }
      fi
    fi
  else
    echo "[build] No patches found in ./patches directory"
    rm -f "$PATCH_LIST_FILE"
  fi
else
  echo "[build] No patches directory found"
fi

stage_end

########################################
# 5. Ensure dependencies (safe even if already installed)
########################################

stage_start "Ruby Dependencies"

echo "[build] Running bundle _${BUNDLER_VERSION}_ install (again, safe)..."
bundle _${BUNDLER_VERSION}_ install

stage_end

########################################
# 6. Prepare FASTLANE_KEY (handle '\n' case)
########################################

if [[ "${FASTLANE_KEY:-}" == *"\\n"* ]]; then
  printf '%s\n' "[build] Detected '\\n' sequences in FASTLANE_KEY; converting to real newlines..."
  FASTLANE_KEY="$(printf '%b' "$FASTLANE_KEY")"
  export FASTLANE_KEY
else
  echo "[build] FASTLANE_KEY appears to be multi-line already."
fi


stage_ipa_for_release() {
  local ipa_source="$GYM_OUTPUT_DIR/Trio.ipa"
  local ipa_dest="$BUILD_DIR/Trio.ipa"

  if [[ -f "$ipa_source" ]]; then
    cp -f "$ipa_source" "$ipa_dest"
    if [[ "$BUILD_ONLY" = "1" ]]; then
      cp -f "$ipa_source" "$ROOT_DIR/Trio.ipa"
    fi
  else
    echo "[build] Warning: IPA not found at $ipa_source"
  fi
}

stage_dsym_for_release() {
  local dsym_source=""
  if [[ -f "$GYM_OUTPUT_DIR/Trio.app.dSYM.zip" ]]; then
    dsym_source="$GYM_OUTPUT_DIR/Trio.app.dSYM.zip"
  elif [[ -f "$GYM_OUTPUT_DIR/Trio.dSYM.zip" ]]; then
    dsym_source="$GYM_OUTPUT_DIR/Trio.dSYM.zip"
  fi

  if [[ -z "$dsym_source" ]]; then
    echo "[build] Warning: dSYM zip not found in $GYM_OUTPUT_DIR"
    return
  fi

  local dsym_dest="$BUILD_DIR/Trio.app.dSYM.zip"
  cp -f "$dsym_source" "$dsym_dest"
  if [[ "$BUILD_ONLY" = "1" ]]; then
    cp -f "$dsym_source" "$ROOT_DIR/Trio.app.dSYM.zip"
  fi
}

########################################
# 7. Build signed Trio IPA
########################################

BUILD_OUTPUT_DIR="$BUILD_DIR/build"
DERIVED_DATA_PATH="$BUILD_OUTPUT_DIR/DerivedData"
ARCHIVE_DIR="$BUILD_OUTPUT_DIR/Archives"
ARCHIVE_PATH="$ARCHIVE_DIR/Trio.xcarchive"
GYM_OUTPUT_DIR="$BUILD_OUTPUT_DIR/output"
mkdir -p "$DERIVED_DATA_PATH" "$ARCHIVE_DIR" "$GYM_OUTPUT_DIR"

export GYM_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
export GYM_ARCHIVE_PATH="$ARCHIVE_PATH"
export GYM_OUTPUT_DIRECTORY="$GYM_OUTPUT_DIR"

if [[ -z "${SYNC_EXPLICIT_ONLY:-}" ]]; then
  # When building current state, process all globs to ensure all files are synced
  # When building with patches, use explicit-only to avoid syncing files that don't exist yet
  if [[ "$BUILD_CURRENT" = "1" ]]; then
    SYNC_EXPLICIT_ONLY=0
  else
    SYNC_EXPLICIT_ONLY=1
  fi
fi
export SYNC_EXPLICIT_ONLY

# --- Ephemeral build keychain (for non-CI / non-login-session builds) ---
if [[ "${GITHUB_ACTIONS:-}" != "true" && -z "${MATCH_KEYCHAIN_NAME:-}" ]]; then
  BUILD_KC="trio-build-$$.keychain-db"
  BUILD_KC_PASS="$(uuidgen)"
  echo "[build] Creating ephemeral build keychain: $BUILD_KC"
  security create-keychain -p "$BUILD_KC_PASS" "$BUILD_KC"
  security set-keychain-settings -lut 21600 "$BUILD_KC"
  security unlock-keychain -p "$BUILD_KC_PASS" "$BUILD_KC"
  # Prepend to user keychain list without removing existing keychains
  EXISTING_KCS=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
  security list-keychains -d user -s "$BUILD_KC" $EXISTING_KCS
  export MATCH_KEYCHAIN_NAME="$BUILD_KC"
  export MATCH_KEYCHAIN_PASSWORD="$BUILD_KC_PASS"
  # Cleanup handled by cleanup() function via existing 'trap cleanup EXIT'
fi

stage_start "Build IPA"

if ! capture_fastlane_errors "bundle _${BUNDLER_VERSION}_ exec fastlane build_trio" "Build step"; then
  build_exit_code=$?
  exit $build_exit_code
fi

stage_ipa_for_release
stage_dsym_for_release

stage_end

########################################
# 8. Upload to TestFlight (with confirmation)
########################################

echo ""
echo "=========================================="
echo "[build] ✅ Build completed successfully!"
echo "=========================================="
echo ""

if [[ "$BUILD_ONLY" = "1" ]]; then
  echo "[build] BUILD_ONLY=1 — skipping TestFlight upload."
  echo "[build] Build verification complete. IPA available at: $ROOT_DIR/Trio.ipa"
  echo ""
  print_stage_summary "success"
  echo "[build] Local build finished successfully (no upload)."
  exit 0
fi

echo "[build] Ready to upload to TestFlight."
# echo "[build] Press Enter to continue with upload, or Ctrl+C to cancel..."
# read -r

stage_start "TestFlight Upload"

if ! capture_fastlane_errors "bundle _${BUNDLER_VERSION}_ exec fastlane release" "Release step"; then
  release_exit_code=$?
  exit $release_exit_code
fi

stage_end

echo "[build] TestFlight upload finished successfully."

########################################
# 9. Record release (after successful TestFlight upload)
########################################

stage_start "Record Release"

echo "[build] Recording release to GitHub..."

# Determine IPA path for record-release.sh
ipa_path_for_release=""
if [[ -f "$BUILD_DIR/Trio.ipa" ]]; then
  ipa_path_for_release="$BUILD_DIR/Trio.ipa"
elif [[ -f "$ROOT_DIR/Trio.ipa" ]]; then
  ipa_path_for_release="$ROOT_DIR/Trio.ipa"
elif [[ -n "${GYM_OUTPUT_DIR:-}" && -f "$GYM_OUTPUT_DIR/Trio.ipa" ]]; then
  ipa_path_for_release="$GYM_OUTPUT_DIR/Trio.ipa"
fi

# Determine dSYM path for record-release.sh
# Only check BUILD_DIR and GYM_OUTPUT_DIR (not ROOT_DIR, which may have a stale dSYM from a previous --build-only run)
dsym_path_for_release=""
if [[ -f "$BUILD_DIR/Trio.app.dSYM.zip" ]]; then
  dsym_path_for_release="$BUILD_DIR/Trio.app.dSYM.zip"
elif [[ -n "${GYM_OUTPUT_DIR:-}" && -f "$GYM_OUTPUT_DIR/Trio.app.dSYM.zip" ]]; then
  dsym_path_for_release="$GYM_OUTPUT_DIR/Trio.app.dSYM.zip"
elif [[ -n "${GYM_OUTPUT_DIR:-}" && -f "$GYM_OUTPUT_DIR/Trio.dSYM.zip" ]]; then
  dsym_path_for_release="$GYM_OUTPUT_DIR/Trio.dSYM.zip"
fi

if [[ -n "$ipa_path_for_release" ]]; then
  # Ensure we're in the build directory (where patches are applied)
  cd "$BUILD_DIR"
  
  # Run record-release.sh (it will handle errors internally)
  if IPA_PATH="$ipa_path_for_release" DSYM_PATH="$dsym_path_for_release" "$ROOT_DIR/scripts/record-release.sh"; then
    echo "[build] Release recorded successfully."
  else
    echo "[build] WARNING: Release recording failed, but build/upload succeeded."
    preserve_worktree=true
    if [[ -n "$WORKTREE_DIR" ]]; then
      echo "[build] Preserving worktree for retry: $WORKTREE_DIR"
    fi
    echo "[build] See record-release output above for retry instructions."
  fi
  
  cd "$ROOT_DIR"
else
  echo "[build] WARNING: Could not find IPA for release recording."
fi

stage_end

print_stage_summary "success"
echo "[build] Local build + TestFlight upload finished successfully."
exit 0
