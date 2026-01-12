#!/usr/bin/env bash
set -euo pipefail

# record-release.sh
# Creates/updates GitHub Release for shipped builds (after TestFlight upload)

usage() {
  cat <<'USAGE'
Usage: scripts/record-release.sh

Records a shipped build by:
  - Extracting version/build from IPA
  - Generating manifest JSON
  - Creating/updating Git tag
  - Creating/updating GitHub Release
  - Uploading manifest as release asset

Environment variables:
  GH_PAT          - GitHub Personal Access Token (required)
  IPA_PATH       - Path to built IPA (auto-detected if not set)
  GITHUB_REPOSITORY - Repository in owner/name format (auto-detected in CI)
USAGE
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
    exit 1
  fi

  # Extract Info.plist from IPA
  # IPA structure: Payload/Trio.app/Info.plist
  # Quote the path to handle spaces
  if ! unzip -q -o "$ipa_path" -d "$temp_dir" "Payload/*/Info.plist" 2>/dev/null; then
    echo "ERROR: Failed to extract Info.plist from IPA" >&2
    exit 1
  fi

  local info_plist
  info_plist="$(find "$temp_dir" -name "Info.plist" -type f | head -n 1)"
  if [[ -z "$info_plist" || ! -f "$info_plist" ]]; then
    echo "ERROR: Info.plist not found in IPA" >&2
    exit 1
  fi

  # Extract version and build using plutil (macOS) or defaults
  local version build
  if command -v plutil >/dev/null 2>&1; then
    version="$(plutil -extract CFBundleShortVersionString raw "$info_plist" 2>/dev/null || echo "")"
    build="$(plutil -extract CFBundleVersion raw "$info_plist" 2>/dev/null || echo "")"
  elif command -v defaults >/dev/null 2>&1; then
    version="$(defaults read "$temp_dir/Payload"/*/Info.plist CFBundleShortVersionString 2>/dev/null || echo "")"
    build="$(defaults read "$temp_dir/Payload"/*/Info.plist CFBundleVersion 2>/dev/null || echo "")"
  else
    # Fallback: use Python to read plist
    version="$(python3 -c "
import plistlib
import sys
with open('$info_plist', 'rb') as f:
    plist = plistlib.load(f)
    print(plist.get('CFBundleShortVersionString', ''))
" 2>/dev/null || echo "")"
    build="$(python3 -c "
import plistlib
import sys
with open('$info_plist', 'rb') as f:
    plist = plistlib.load(f)
    print(plist.get('CFBundleVersion', ''))
" 2>/dev/null || echo "")"
  fi

  if [[ -z "$version" || -z "$build" ]]; then
    echo "ERROR: Failed to extract version or build from IPA" >&2
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

# Get upstream/dev SHA
get_upstream_dev_sha() {
  # Require upstream remote to be configured
  if ! git remote | grep -q "^upstream$"; then
    echo "ERROR: 'upstream' remote is not configured. Configure it with:" >&2
    echo "  git remote add upstream https://github.com/nightscout/Trio.git" >&2
    exit 1
  fi

  # Fetch and resolve upstream/dev
  if ! git fetch upstream dev >/dev/null 2>&1; then
    echo "ERROR: Failed to fetch upstream/dev. Check network connectivity and remote configuration." >&2
    exit 1
  fi

  local upstream_sha
  upstream_sha="$(git rev-parse "upstream/dev" 2>/dev/null || echo "")"
  if [[ -z "$upstream_sha" ]]; then
    echo "ERROR: Cannot resolve upstream/dev. Ensure the upstream remote points to the correct repository." >&2
    exit 1
  fi

  echo "$upstream_sha"
}

# Generate release description body
generate_release_body() {
  local version="$1"
  local build="$2"
  local context="$3"
  local tag="$4"
  local upstream_dev_sha="$5"
  local fork_sha="$6"
  local patches_json="$7"

  local body="Trio v${version} (${build}) ${context}

Tag: ${tag}

Built from:
- upstream/dev: ${upstream_dev_sha}
- fork: ${fork_sha}

Patches:"

  # Parse patches JSON and add to body
  if [[ "$patches_json" != "[]" && -n "$patches_json" ]]; then
    # Use Python to parse JSON and format patches (pass JSON via stdin to avoid quoting issues)
    echo "$patches_json" | python3 <<'PYTHON_EOF'
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
  else
    body+="
(none)"
  fi

  echo "$body"
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

  local version_build
  version_build="$(extract_ipa_info "$ipa_path")"
  local version build
  IFS='|' read -r version build <<< "$version_build"
  echo "[record-release] Version: $version, Build: $build"

  # Compute tag and release title
  local tag="trio-v${version}-${build}-${context}"
  local release_title="Trio v${version} (${build}) ${context}"

  # Get git SHAs
  local upstream_dev_sha fork_sha
  upstream_dev_sha="$(get_upstream_dev_sha)"
  fork_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  echo "[record-release] Upstream/dev SHA: ${upstream_dev_sha:0:12}"
  echo "[record-release] Fork SHA: ${fork_sha:0:12}"

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

  # Ensure we have a fork SHA to point the tag at
  if [[ -z "$fork_sha" ]]; then
    echo "ERROR: Unable to determine fork SHA (git rev-parse HEAD returned empty)." >&2
    exit 1
  fi

  # Create or force-update refs/tags/<tag> to point at fork_sha
  if gh api "repos/$repo_info/git/refs/tags/$tag" --silent >/dev/null 2>&1; then
    if ! gh api -X PATCH "repos/$repo_info/git/refs/tags/$tag" -f sha="$fork_sha" -f force=true --silent >/dev/null 2>&1; then
      echo "ERROR: Failed to update tag '$tag' via GitHub API." >&2
      echo "Release creation will not proceed." >&2
      echo "Likely causes:" >&2
      echo "  - Missing permissions: GH_PAT token lacks required repo permissions" >&2
      echo "  - Network issue: Cannot reach GitHub" >&2
      echo "To retry after fixing:" >&2
      echo "  GH_TOKEN=\"$GH_PAT\" IPA_PATH=\"$ipa_path\" scripts/record-release.sh" >&2
      exit 1
    fi
  else
    if ! gh api -X POST "repos/$repo_info/git/refs" -f ref="refs/tags/$tag" -f sha="$fork_sha" --silent >/dev/null 2>&1; then
      echo "ERROR: Failed to create tag '$tag' via GitHub API." >&2
      echo "Release creation will not proceed." >&2
      echo "Likely causes:" >&2
      echo "  - Missing permissions: GH_PAT token lacks required repo permissions" >&2
      echo "  - Network issue: Cannot reach GitHub" >&2
      echo "To retry after fixing:" >&2
      echo "  GH_TOKEN=\"$GH_PAT\" IPA_PATH=\"$ipa_path\" scripts/record-release.sh" >&2
      exit 1
    fi
  fi

  # Generate release body
  local release_body
  release_body="$(generate_release_body "$version" "$build" "$context" "$tag" "$upstream_dev_sha" "$fork_sha" "$patches_json")"

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

  # Upload manifest as asset (replace if exists)
  echo "[record-release] Uploading manifest as release asset..."
  gh release upload "$tag" \
    --repo "$repo_info" \
    "$manifest_path" \
    --clobber \
    >/dev/null 2>&1 || {
    echo "WARNING: Failed to upload manifest asset" >&2
  }

  # Print release URL
  local release_url
  release_url="https://github.com/$repo_info/releases/tag/$tag"
  echo ""
  echo "=========================================="
  echo "[record-release] ✅ Release recorded successfully"
  echo "=========================================="
  echo "Release URL: $release_url"
  echo "Tag: $tag"
  echo "Manifest: $manifest_path"
  echo ""
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
