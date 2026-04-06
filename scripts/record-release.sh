#!/usr/bin/env bash
set -euo pipefail

# record-release.sh
# Creates/updates GitHub Release for shipped builds (after TestFlight upload)
#
# Version: 1.3.1
#
# Changelog:
#   1.3.1 - Make upstream SHA lookup GitHub Actions-safe when no 'upstream' remote exists
#         - Resolve upstream branch SHA via UPSTREAM_REPO/UPSTREAM_BRANCH with git ls-remote fallback
#   1.3.0 - Upload dSYM zip to both public and private GitHub releases
#         - Add DSYM_PATH env var and auto-detection via find_dsym_path()
#         - dSYM upload is best-effort (warns but does not fail if missing)
#   1.2.0 - Add private backup release in cachrisman/trio-builds-private
#         - Creates/updates draft release with same tag/title/body as public release
#         - Uploads manifest JSON and IPA file as assets
#   1.1.0 - Auto-push temp branch when fork SHA doesn't exist on GitHub
#         - Stop swallowing GitHub API error details for better debugging
#   1.0.0 - Initial release

usage() {
  cat <<'USAGE'
Usage: scripts/record-release.sh

Records a shipped build by:
  - Extracting version/build from IPA
  - Generating manifest JSON
  - Creating/updating Git tag
  - Creating/updating GitHub Release (public)
  - Uploading manifest and dSYM as release assets
  - Creating/updating private backup release (draft) with manifest, IPA, and dSYM assets

Environment variables:
  GH_PAT                      - GitHub Personal Access Token (required)
  IPA_PATH                    - Path to built IPA (auto-detected if not set)
  DSYM_PATH                   - Path to dSYM zip (auto-detected if not set; optional)
  GITHUB_REPOSITORY           - Repository in owner/name format (auto-detected in CI)
  TRIO_BUILDS_PRIVATE_REPO    - Private backup repository (default: cachrisman/trio-builds-private)
USAGE
}

print_retry_hint() {
  local ipa_path="${1:-}"
  echo "To retry after fixing:" >&2
  if [[ -n "$ipa_path" ]]; then
    echo "  GH_PAT=\"<token>\" IPA_PATH=\"$ipa_path\" scripts/record-release.sh" >&2
  else
    echo "  GH_PAT=\"<token>\" scripts/record-release.sh" >&2
  fi
}

# Determine build context
determine_context() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "cloudCI"
  elif [[ "${LOCAL_CI:-}" == "1" ]]; then
    echo "localCI"
  else
    echo "local"
  fi
}

# Validate prerequisites
validate_prerequisites() {
  if [[ -z "${GH_PAT:-}" ]]; then
    echo "ERROR: GH_PAT environment variable is not set" >&2
    exit 1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' CLI is not installed" >&2
    echo "Install with: brew install gh" >&2
    exit 1
  fi

  export GH_TOKEN="$GH_PAT"
}

# Get repository owner/name
get_repo_info() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "$GITHUB_REPOSITORY"
    return
  fi

  # Derive from git remote
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$remote_url" ]]; then
    echo "ERROR: Cannot determine repository. Set GITHUB_REPOSITORY or ensure git remote 'origin' is configured" >&2
    exit 1
  fi

  # Extract owner/name from various remote URL formats
  if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  else
    echo "ERROR: Cannot parse repository from remote URL: $remote_url" >&2
    exit 1
  fi
}

# Extract version and build number from IPA
extract_ipa_info() {
  local ipa_path="$1"
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap "rm -rf '$temp_dir'" RETURN

  if [[ ! -f "$ipa_path" ]]; then
    echo "ERROR: IPA not found at: $ipa_path" >&2
    print_retry_hint "$ipa_path"
    exit 1
  fi

  # Extract top-level app Info.plist from IPA (avoid embedded bundles/frameworks)
  local plist_path_in_zip
  if plist_path_in_zip="$(unzip -Z1 "$ipa_path" 2>/dev/null | awk '/^Payload\/[^\/]+\.app\/Info\.plist$/ {print; exit}')"; then
    :
  else
    plist_path_in_zip=""
  fi
  if [[ -z "$plist_path_in_zip" ]]; then
    echo "ERROR: Info.plist not found at top-level app path in IPA" >&2
    print_retry_hint "$ipa_path"
    exit 1
  fi

  if ! unzip -q -o "$ipa_path" -d "$temp_dir" "$plist_path_in_zip" 2>/dev/null; then
    echo "ERROR: Failed to extract Info.plist from IPA" >&2
    print_retry_hint "$ipa_path"
    exit 1
  fi

  local info_plist
  info_plist="$temp_dir/$plist_path_in_zip"
  if [[ ! -f "$info_plist" ]]; then
    echo "ERROR: Extracted Info.plist not found at expected path" >&2
    print_retry_hint "$ipa_path"
    exit 1
  fi

  # Extract version and build using plutil (macOS) or defaults
  local version build
  if command -v plutil >/dev/null 2>&1; then
    if version="$(plutil -extract CFBundleShortVersionString raw "$info_plist" 2>/dev/null)"; then
      :
    else
      version=""
    fi
    if build="$(plutil -extract CFBundleVersion raw "$info_plist" 2>/dev/null)"; then
      :
    else
      build=""
    fi
  elif command -v defaults >/dev/null 2>&1; then
    if version="$(defaults read "$info_plist" CFBundleShortVersionString 2>/dev/null)"; then
      :
    else
      version=""
    fi
    if build="$(defaults read "$info_plist" CFBundleVersion 2>/dev/null)"; then
      :
    else
      build=""
    fi
  else
    # Fallback: use Python to read plist
    if version="$(python3 - "$info_plist" <<'PYTHON_EOF'
import plistlib
import sys

with open(sys.argv[1], 'rb') as f:
    plist = plistlib.load(f)
print(plist.get('CFBundleShortVersionString', ''))
PYTHON_EOF
    )"; then
      :
    else
      version=""
    fi
    if build="$(python3 - "$info_plist" <<'PYTHON_EOF'
import plistlib
import sys

with open(sys.argv[1], 'rb') as f:
    plist = plistlib.load(f)
print(plist.get('CFBundleVersion', ''))
PYTHON_EOF
    )"; then
      :
    else
      build=""
    fi
  fi

  if [[ -z "$version" || -z "$build" ]]; then
    echo "ERROR: Failed to extract version or build from IPA" >&2
    print_retry_hint "$ipa_path"
    exit 1
  fi

  echo "$version|$build"
}

# Find IPA path
find_ipa_path() {
  if [[ -n "${IPA_PATH:-}" ]]; then
    echo "$IPA_PATH"
    return
  fi

  # Try common locations (order matters: most specific first)
  local candidates=(
    "artifacts/Trio.ipa"
    "build/artifacts/Trio.ipa"
    "build/output/Trio.ipa"
    "Trio.ipa"
    "$(pwd)/artifacts/Trio.ipa"
    "$(pwd)/build/artifacts/Trio.ipa"
    "$(pwd)/build/output/Trio.ipa"
    "$(pwd)/Trio.ipa"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "ERROR: IPA not found. Set IPA_PATH or ensure Trio.ipa exists in expected location" >&2
  exit 1
}

# Find dSYM zip path (best-effort; returns empty string if not found)
find_dsym_path() {
  if [[ -n "${DSYM_PATH:-}" ]]; then
    if [[ -f "$DSYM_PATH" ]]; then
      echo "$DSYM_PATH"
    else
      echo "WARNING: DSYM_PATH set but file not found: $DSYM_PATH" >&2
    fi
    return
  fi

  local candidates=(
    "Trio.app.dSYM.zip"
    "build/output/Trio.app.dSYM.zip"
    "build/output/Trio.dSYM.zip"
    "artifacts/Trio.app.dSYM.zip"
    "build/artifacts/Trio.app.dSYM.zip"
    "$(pwd)/Trio.app.dSYM.zip"
    "$(pwd)/build/output/Trio.app.dSYM.zip"
    "$(pwd)/artifacts/Trio.app.dSYM.zip"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  # Not found — this is non-fatal
  echo ""
}

# Get patch metadata (same format as capture-build-details.sh)
get_patch_metadata() {
  local patches_dir="${1:-patches}"
  local patches_json="[]"

  if [[ ! -d "$patches_dir" ]]; then
    echo "$patches_json"
    return
  fi

  # Collect patches deterministically (same logic as build scripts)
  # Only consider .patch files (never .am.patch)
  local patch_list
  patch_list="$(cd "$patches_dir" 2>/dev/null && ls -1 *.patch 2>/dev/null | grep -v '\.am\.patch$' | sort | awk '
    /^[0-9][0-9]-/ {
      p=substr($0, 1, 2)
      if (!(p in chosen)) { chosen[p]=$0 }
    }
    END { for (p in chosen) print chosen[p] }
  ' | sort)"

  if [[ -z "$patch_list" ]]; then
    echo "$patches_json"
    return
  fi

  # Build JSON array of patches
  local patches_array=()
  while IFS= read -r patch_file; do
    [[ -z "$patch_file" ]] && continue
    local full_path="$patches_dir/$patch_file"
    [[ ! -f "$full_path" ]] && continue

    # Extract metadata from patch file (same as capture-build-details.sh)
    local patch_name patch_from_sha patch_date patch_subject
    patch_name="$(basename "$patch_file")"
    patch_from_sha="$(awk 'NR==1 {print $2; exit}' "$full_path" 2>/dev/null || echo "")"
    patch_date="$(awk -F 'Date: ' '/^Date: / {print $2; exit}' "$full_path" 2>/dev/null || echo "")"
    patch_subject="$(awk -F 'Subject: ' '/^Subject: / {print $2; exit}' "$full_path" 2>/dev/null || echo "")"

    # Escape JSON strings
    patch_name_escaped="$(printf '%s' "$patch_name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    patch_from_sha_escaped="$(printf '%s' "$patch_from_sha" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    patch_date_escaped="$(printf '%s' "$patch_date" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    patch_subject_escaped="$(printf '%s' "$patch_subject" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    patches_array+=("{\"name\":\"$patch_name_escaped\",\"from_sha\":\"$patch_from_sha_escaped\",\"date\":\"$patch_date_escaped\",\"subject\":\"$patch_subject_escaped\"}")
  done <<< "$patch_list"

  if [[ ${#patches_array[@]} -eq 0 ]]; then
    echo "$patches_json"
    return
  fi

  # Join array elements with commas
  local patches_str
  patches_str="$(IFS=,; echo "${patches_array[*]}")"
  echo "[$patches_str]"
}

# Get upstream branch SHA
get_upstream_dev_sha() {
  local upstream_branch upstream_sha upstream_repo upstream_url
  upstream_branch="${UPSTREAM_BRANCH:-dev}"
  upstream_sha=""

  # Preferred path: use configured upstream remote when available.
  if git remote get-url upstream >/dev/null 2>&1; then
    if ! git fetch upstream "$upstream_branch" >/dev/null 2>&1; then
      echo "ERROR: Failed to fetch upstream/$upstream_branch. Check network connectivity and remote configuration." >&2
      exit 1
    fi

    upstream_sha="$(git rev-parse "upstream/$upstream_branch" 2>/dev/null || echo "")"
    if [[ -n "$upstream_sha" ]]; then
      echo "$upstream_sha"
      return
    fi

    echo "ERROR: Cannot resolve upstream/$upstream_branch from configured upstream remote." >&2
    exit 1
  fi

  # GitHub Actions fallback: query upstream directly without requiring a local remote.
  upstream_repo="${UPSTREAM_REPO:-nightscout/Trio}"
  upstream_url="https://github.com/${upstream_repo}.git"
  upstream_sha="$(git ls-remote --heads "$upstream_url" "$upstream_branch" 2>/dev/null | awk 'NR==1 {print $1}')"

  if [[ -z "$upstream_sha" ]]; then
    echo "ERROR: Cannot resolve ${upstream_repo}:${upstream_branch} via ls-remote." >&2
    echo "Configure a local 'upstream' remote or set UPSTREAM_REPO/UPSTREAM_BRANCH correctly." >&2
    exit 1
  fi

  echo "$upstream_sha"
}

# Ensure a commit SHA exists on GitHub (push temp branch if needed)
ensure_sha_on_github() {
  local repo_info="$1"
  local sha="$2"
  local tag="$3"

  # If GitHub can already resolve this commit, we're good.
  if gh api "repos/$repo_info/git/commits/$sha" --silent >/dev/null 2>&1; then
    return 0
  fi

  echo "[record-release] NOTE: fork SHA not found on GitHub; pushing temp branch so tag can reference it..."

  # Create a unique, sortable branch name.
  local ts branch
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  branch="ci-build/${tag}-${ts}"

  # Push the commit object by creating a temporary branch.
  if ! git push origin "$sha:refs/heads/$branch"; then
    echo "ERROR: fork SHA $sha is not present on GitHub and pushing temp branch failed." >&2
    echo "Release creation will not proceed." >&2
    echo "To retry manually:" >&2
    echo "  git push origin $sha:refs/heads/$branch" >&2
    exit 1
  fi

  # Confirm GitHub can now resolve the commit.
  if ! gh api "repos/$repo_info/git/commits/$sha" --silent >/dev/null 2>&1; then
    echo "ERROR: Temp branch push succeeded, but GitHub still cannot resolve commit $sha." >&2
    exit 1
  fi

  echo "[record-release] Temp branch pushed: $branch"
}

# Read stage summary if available
get_stage_summary() {
  local summary_file="build/artifacts/stage-summary.txt"
  
  # Also check common locations
  local candidates=(
    "build/artifacts/stage-summary.txt"
    "../build/artifacts/stage-summary.txt"
    "$(pwd)/build/artifacts/stage-summary.txt"
  )
  
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      cat "$candidate"
      return
    fi
  done
  
  echo ""
}

# Generate release description body
generate_release_body() {
  local version="$1"
  local build="$2"
  local context="$3"
  local tag="$4"
  local upstream_branch="$5"
  local upstream_dev_sha="$6"
  local fork_sha="$7"
  local patches_json="$8"

  local body="Trio v${version} (${build}) ${context}

Tag: ${tag}

Built from:
- upstream/${upstream_branch}: ${upstream_dev_sha}
- fork: ${fork_sha}

Patches:"

  # Parse patches JSON and add to body
  if [[ "$patches_json" != "[]" && -n "$patches_json" ]]; then
    # Use Python to parse JSON and format patches (pass JSON via stdin to avoid quoting issues)
    body+="
$(echo "$patches_json" | python3 <<'PYTHON_EOF'
import json
import sys

try:
    patches = json.load(sys.stdin)
    for patch in patches:
        name = patch.get('name', 'Unknown')
        subject = patch.get('subject', '')
        from_sha = patch.get('from_sha', '')
        date = patch.get('date', '')
        # Format: - name — subject (from <sha>, <date>)
        parts = [f"- {name}"]
        if subject:
            parts.append(f" — {subject}")
        if from_sha or date:
            meta_parts = []
            if from_sha:
                meta_parts.append(f"from {from_sha[:12]}")
            if date:
                meta_parts.append(date)
            if meta_parts:
                parts.append(f" ({', '.join(meta_parts)})")
        print(''.join(parts))
except Exception as e:
    print(f"(error parsing patches: {e})", file=sys.stderr)
PYTHON_EOF
)"
  else
    body+="
(none)"
  fi

  # Add stage timing summary if available
  local stage_summary
  stage_summary="$(get_stage_summary)"
  if [[ -n "$stage_summary" ]]; then
    body+="

Build Stages:
\`\`\`
$stage_summary
\`\`\`"
  fi

  echo "$body"
}

# Create/update private backup release (draft) with manifest, IPA, and dSYM assets
record_private_backup_release() {
  local private_repo="$1"
  local tag="$2"
  local title="$3"
  local body="$4"
  local manifest_path="$5"
  local ipa_path="$6"
  local dsym_path="${7:-}"

  echo "[record-release] Creating/updating private backup release (draft)..."

  # Sanity check: ensure GH_TOKEN can access the private repo (fail fast)
  if ! gh api "repos/$private_repo" --silent >/dev/null 2>&1; then
    echo "ERROR: GH_TOKEN (from GH_PAT) cannot access repos/$private_repo. Verify GH_PAT permissions for this repo." >&2
    exit 1
  fi

  # Create or update draft release
  if gh release view "$tag" --repo "$private_repo" >/dev/null 2>&1; then
    if ! gh release edit "$tag" \
      --repo "$private_repo" \
      --title "$title" \
      --notes "$body" \
      --draft \
      >/dev/null 2>&1; then
      echo "ERROR: Failed to update private backup release" >&2
      exit 1
    fi
  else
    if ! gh release create "$tag" \
      --repo "$private_repo" \
      --title "$title" \
      --notes "$body" \
      --draft \
      >/dev/null 2>&1; then
      echo "ERROR: Failed to create private backup release" >&2
      exit 1
    fi
  fi

  # Build asset list: manifest + IPA + optional dSYM
  local assets=("$manifest_path" "$ipa_path")
  if [[ -n "$dsym_path" && -f "$dsym_path" ]]; then
    assets+=("$dsym_path")
  fi

  echo "[record-release] Uploading assets to private backup release..."
  if ! gh release upload "$tag" \
    --repo "$private_repo" \
    "${assets[@]}" \
    --clobber \
    >/dev/null 2>&1; then
    echo "ERROR: Failed to upload assets to private backup release" >&2
    exit 1
  fi

  # Return the release URL
  echo "https://github.com/$private_repo/releases/tag/$tag"
}

# Main execution
main() {
  local context
  context="$(determine_context)"
  echo "[record-release] Build context: $context"

  validate_prerequisites

  local repo_info
  repo_info="$(get_repo_info)"
  echo "[record-release] Repository: $repo_info"

  # Sanity check: ensure GH_TOKEN can access the target repo (fail fast)
  if ! gh api "repos/$repo_info" --silent >/dev/null 2>&1; then
    echo "ERROR: GH_TOKEN (from GH_PAT) cannot access repos/$repo_info. Verify GH_PAT permissions for this repo." >&2
    exit 1
  fi

  local ipa_path
  ipa_path="$(find_ipa_path)"
  echo "[record-release] IPA path: $ipa_path"

  local dsym_path
  dsym_path="$(find_dsym_path)"
  if [[ -n "$dsym_path" ]]; then
    echo "[record-release] dSYM path: $dsym_path"
  else
    echo "[record-release] WARNING: dSYM zip not found — release will not include debug symbols"
  fi

  local version_build
  version_build="$(extract_ipa_info "$ipa_path")"
  local version build
  IFS='|' read -r version build <<< "$version_build"
  echo "[record-release] Version: $version, Build: $build"

  # Compute tag and release title
  local tag="trio-v${version}-${build}-${context}"
  local release_title="Trio v${version} (${build}) ${context}"

  # Get git SHAs
  local upstream_branch upstream_dev_sha fork_sha
  upstream_branch="${UPSTREAM_BRANCH:-dev}"
  upstream_dev_sha="$(get_upstream_dev_sha)"
  fork_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  echo "[record-release] Upstream/${upstream_branch} SHA: ${upstream_dev_sha:0:12}"
  echo "[record-release] Fork SHA: ${fork_sha:0:12}"

  # Ensure we have a fork SHA to point the tag at
  if [[ -z "$fork_sha" ]]; then
    echo "ERROR: Unable to determine fork SHA (git rev-parse HEAD returned empty)." >&2
    exit 1
  fi
  
  # Ensure the fork SHA exists on GitHub; if not, push a temp branch so tagging works.
  ensure_sha_on_github "$repo_info" "$fork_sha" "$tag"

  # Get patch metadata
  local patches_json
  patches_json="$(get_patch_metadata)"
  echo "[record-release] Found patches: $(echo "$patches_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")"

  # Generate manifest JSON
  local timestamp_utc
  timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local manifest_filename="release-manifest-$(date -u +%Y%m%dT%H%M%SZ)-${context}.json"

  # Build context info
  local build_context_json
  build_context_json="{\"context\":\"$context\""
  if [[ "$context" == "cloudCI" ]]; then
    build_context_json+=",\"GITHUB_RUN_ID\":\"${GITHUB_RUN_ID:-}\",\"GITHUB_RUN_NUMBER\":\"${GITHUB_RUN_NUMBER:-}\",\"GITHUB_SHA\":\"${GITHUB_SHA:-}\",\"GITHUB_REF_NAME\":\"${GITHUB_REF_NAME:-}\""
  else
    local hostname username
    hostname="$(hostname 2>/dev/null || echo "")"
    username="$(whoami 2>/dev/null || echo "")"
    if [[ -n "$hostname" ]]; then
      build_context_json+=",\"hostname\":\"$hostname\""
    fi
    if [[ -n "$username" ]]; then
      build_context_json+=",\"username\":\"$username\""
    fi
  fi
  build_context_json+="}"

  # Create manifest JSON (use temp files to avoid quoting issues with JSON)
  local temp_patches_file temp_context_file
  temp_patches_file="$(mktemp)"
  temp_context_file="$(mktemp)"
  
  # Write patches and context JSON to temp files
  echo "$patches_json" > "$temp_patches_file"
  echo "$build_context_json" > "$temp_context_file"
  
  local manifest_json
  manifest_json="$(python3 <<PYTHON_EOF
import json

# Read patches and context from temp files
with open('$temp_patches_file', 'r') as f:
    patches = json.load(f)
with open('$temp_context_file', 'r') as f:
    build_context = json.load(f)

manifest = {
    "timestampUtc": "$timestamp_utc",
    "buildContext": build_context,
    "app": {
        "version": "$version",
        "buildNumber": "$build"
    },
    "base": {
        "upstreamDevSha": "$upstream_dev_sha",
        "forkSha": "$fork_sha"
    },
    "release": {
        "tag": "$tag",
        "title": "$release_title"
    },
    "patches": patches
}

print(json.dumps(manifest, indent=2))
PYTHON_EOF
)"
  
  rm -f "$temp_patches_file" "$temp_context_file"

  # Write manifest file
  local artifacts_dir="build/artifacts"
  mkdir -p "$artifacts_dir"
  local manifest_path="$artifacts_dir/$manifest_filename"
  echo "$manifest_json" > "$manifest_path"
  echo "[record-release] Manifest written: $manifest_path"

  # Create/update tag via GitHub API (uses GH_TOKEN/GH_PAT)
  echo "[record-release] Creating/updating tag: $tag"

  # Create or force-update refs/tags/<tag> to point at fork_sha
  if gh api -i "repos/$repo_info/git/refs/tags/$tag" >/dev/null; then
    if ! gh api -i -X PATCH "repos/$repo_info/git/refs/tags/$tag" -f sha="$fork_sha" -f force=true; then
      echo "ERROR: Failed to update tag '$tag' via GitHub API." >&2
      echo "Release creation will not proceed." >&2
      echo "Likely causes:" >&2
      echo "  - Missing permissions: GH_PAT token lacks required repo permissions" >&2
      echo "  - Network issue: Cannot reach GitHub" >&2
      echo "  - Tag ruleset/protection is blocking this tag pattern" >&2
      echo "  - Commit SHA not present on GitHub (should be handled by ensure_sha_on_github, but keep as a hint)" >&2
      echo "To retry after fixing:" >&2
      echo "  GH_PAT=\"<token>\" IPA_PATH=\"$ipa_path\" scripts/record-release.sh" >&2
      exit 1
    fi
  else
    if ! gh api -i -X POST "repos/$repo_info/git/refs" -f ref="refs/tags/$tag" -f sha="$fork_sha"; then
      echo "ERROR: Failed to create tag '$tag' via GitHub API." >&2
      echo "Release creation will not proceed." >&2
      echo "Likely causes:" >&2
      echo "  - Missing permissions: GH_PAT token lacks required repo permissions" >&2
      echo "  - Network issue: Cannot reach GitHub" >&2
      echo "  - Tag ruleset/protection is blocking this tag pattern" >&2
      echo "  - Commit SHA not present on GitHub (should be handled by ensure_sha_on_github, but keep as a hint)" >&2
      echo "To retry after fixing:" >&2
      echo "  GH_PAT=\"<token>\" IPA_PATH=\"$ipa_path\" scripts/record-release.sh" >&2
      exit 1
    fi
  fi

  # Generate release body
  local release_body
  release_body="$(generate_release_body "$version" "$build" "$context" "$tag" "$upstream_branch" "$upstream_dev_sha" "$fork_sha" "$patches_json")"

  # Create/update GitHub Release
  echo "[record-release] Creating/updating GitHub Release..."
  if gh release view "$tag" --repo "$repo_info" >/dev/null 2>&1; then
    gh release edit "$tag" \
      --repo "$repo_info" \
      --title "$release_title" \
      --notes "$release_body" \
      >/dev/null 2>&1 || {
      echo "WARNING: Failed to update release" >&2
    }
  else
    gh release create "$tag" \
      --repo "$repo_info" \
      --title "$release_title" \
      --notes "$release_body" \
      >/dev/null 2>&1 || {
      echo "ERROR: Failed to create release" >&2
      exit 1
    }
  fi

  # Build public release asset list: manifest + optional dSYM
  local public_assets=("$manifest_path")
  if [[ -n "$dsym_path" && -f "$dsym_path" ]]; then
    public_assets+=("$dsym_path")
  fi

  echo "[record-release] Uploading release assets..."
  gh release upload "$tag" \
    --repo "$repo_info" \
    "${public_assets[@]}" \
    --clobber \
    >/dev/null 2>&1 || {
    echo "WARNING: Failed to upload release assets" >&2
  }

  # Create/update private backup release (draft) with manifest, IPA, and dSYM
  local private_repo="${TRIO_BUILDS_PRIVATE_REPO:-cachrisman/trio-builds-private}"
  local private_release_url
  private_release_url="$(record_private_backup_release "$private_repo" "$tag" "$release_title" "$release_body" "$manifest_path" "$ipa_path" "$dsym_path")"

  # Print release URLs
  local release_url
  release_url="https://github.com/$repo_info/releases/tag/$tag"
  echo ""
  echo "=========================================="
  echo "[record-release] ✅ Release recorded successfully"
  echo "=========================================="
  echo "Public Release URL: $release_url"
  echo "Private Backup Release URL (draft): $private_release_url"
  echo "Tag: $tag"
  echo "Manifest: $manifest_path"
  echo ""
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
