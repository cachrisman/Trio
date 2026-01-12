# GitHub Release Recording Implementation Summary

**Date:** 2026-01-12  
**Feature:** Automated GitHub Release recording for shipped builds  
**Status:** ✅ Implemented

## Overview

This implementation adds automated GitHub Release recording for all builds that are successfully uploaded to TestFlight. The system creates/updates Git tags, GitHub Releases, and generates timestamped manifest JSON files that serve as the source of truth for shipped builds.

## Requirements Met

✅ **Source of truth:** GitHub Releases  
✅ **Manifest JSON:** Timestamped files in `build/artifacts/`  
✅ **Git tags:** Created/updated for each shipped build  
✅ **GitHub Releases:** Created/updated with full metadata  
✅ **Release assets:** Manifest JSON uploaded as asset  
✅ **Authentication:** Uses `GH_PAT` environment variable  
✅ **Patch metadata:** Reuses existing patch metadata format from `scripts/capture-build-details.sh`  
✅ **Build context:** Distinguishes local/localCI/cloudCI contexts  
✅ **Deterministic tags:** Collision-proof format `trio-v<version>-b<build>-<context>`  
✅ **Release descriptions:** Includes all required information (version, build, context, SHAs, patches)

## Files Changed

### New Files

1. **`scripts/record-release.sh`** (468 lines)
   - Main script that orchestrates release recording
   - Executable bash script with comprehensive error handling
   - Handles IPA extraction, metadata collection, tag/release creation

### Modified Files

1. **`ci/local-build.sh`**
   - Added `LOCAL_CI` auto-detection logic (lines 306-318)
   - Added release recording call after TestFlight upload in normal mode (lines 930-968)
   - Added release recording call after TestFlight upload in `--release-only` mode (lines 353-375)

2. **`.github/workflows/build_trio.yml`**
   - Added "Record release" step after TestFlight upload (lines 292-332)
   - Installs `gh` CLI if missing
   - Sets required environment variables

## Implementation Details

### Build Context Detection

The system distinguishes three build contexts:

- **`local`**: Human-triggered build from terminal (interactive TTY)
- **`localCI`**: Locally-run automation/agent/CI-like process (non-interactive or `TRIO_AGENT=1`)
- **`cloudCI`**: GitHub Actions (`GITHUB_ACTIONS=true`)

### Tag Format

```
trio-v<version>-b<build>-<context>
```

Example: `trio-v0.6.0.41-b99-local`

### Release Title Format

```
Trio v<version> (<build>) <context>
```

Example: `Trio v0.6.0.41 (99) local`

### Manifest File Format

**Filename:** `release-manifest-YYYYMMDDTHHMMSSZ.json`  
**Location:** `build/artifacts/`  
**Example:** `release-manifest-20260112T214455Z.json`

**Manifest Structure:**
```json
{
  "timestampUtc": "2026-01-12T21:44:55Z",
  "buildContext": {
    "context": "local|localCI|cloudCI",
    "GITHUB_RUN_ID": "...",  // cloudCI only
    "GITHUB_RUN_NUMBER": "...",  // cloudCI only
    "GITHUB_SHA": "...",  // cloudCI only
    "GITHUB_REF_NAME": "...",  // cloudCI only
    "hostname": "...",  // local/localCI only
    "username": "..."  // local/localCI only
  },
  "app": {
    "version": "0.6.0.41",
    "buildNumber": "99"
  },
  "base": {
    "upstreamDevSha": "49feb37f2287059e5733c769a4936242f444a4e8",
    "forkSha": "e7c9f5e64..."
  },
  "release": {
    "tag": "trio-v0.6.0.41-b99-local",
    "title": "Trio v0.6.0.41 (99) local"
  },
  "patches": [
    {
      "name": "01-ns-richer-settings.patch",
      "from_sha": "f8d29f172c35ebb23f2d25e1e939e44c954edb8c",
      "date": "Sat, 10 Jan 2026 21:50:26 +0100",
      "subject": "[PATCH] feat(nightscout): richer algorithm settings"
    },
    ...
  ]
}
```

### Release Description Format

```
Trio v<version> (<build>) <context>

Tag: <tag>

Built from:
- upstream/dev: <upstreamDevSha>
- fork: <forkSha>

Patches:
- <patch-name> — <subject> (from <sha>, <date>)
- ...
```

### Integration Points

#### Local Builds (`ci/local-build.sh`)

1. **Auto-detection:** After loading environment, detects `LOCAL_CI=1` if:
   - stdin is not a TTY, OR
   - `TERM` is empty, OR
   - `TRIO_AGENT=1` is set

2. **Recording trigger:** After successful TestFlight upload:
   - Determines IPA path (checks `BUILD_DIR`, `ROOT_DIR`, `GYM_OUTPUT_DIR`)
   - Changes to build directory (where patches are applied)
   - Calls `scripts/record-release.sh` with `IPA_PATH` set
   - Returns to root directory

#### GitHub Actions (`.github/workflows/build_trio.yml`)

1. **Prerequisites:** 
   - Installs `gh` CLI if missing
   - Sets `GH_TOKEN` from `GH_PAT`
   - Sets `GITHUB_REPOSITORY` from GitHub context

2. **Recording trigger:** After successful TestFlight upload:
   - Finds IPA path (checks `Trio.ipa`, `artifacts/Trio.ipa`)
   - Calls `scripts/record-release.sh` with `IPA_PATH` set

### Key Functions in `record-release.sh`

- **`determine_context()`**: Detects build context (local/localCI/cloudCI)
- **`validate_prerequisites()`**: Checks for `GH_PAT` and `gh` CLI
- **`get_repo_info()`**: Derives repository owner/name from git remote or `GITHUB_REPOSITORY`
- **`extract_ipa_info()`**: Extracts version and build number from IPA's Info.plist
- **`find_ipa_path()`**: Auto-detects IPA location with fallbacks
- **`get_patch_metadata()`**: Collects patch metadata (reuses logic from `capture-build-details.sh`)
- **`get_upstream_dev_sha()`**: Gets SHA of `upstream/dev` or `origin/dev`
- **`generate_release_body()`**: Formats release description with patch list
- **`main()`**: Orchestrates entire release recording process

### Error Handling

- **Non-fatal warnings:** Tag push failures, release update failures, asset upload failures
- **Fatal errors:** Missing `GH_PAT`, missing `gh` CLI, IPA not found, version/build extraction failure, release creation failure
- **Graceful degradation:** Build/upload success is not affected by recording failures (warnings only)

### Dependencies

- **`gh` CLI**: GitHub CLI tool (installed via `brew install gh` on macOS)
- **`GH_PAT`**: GitHub Personal Access Token with `repo` scope
- **Python 3**: For JSON parsing and manifest generation
- **Standard tools**: `git`, `unzip`, `plutil`/`defaults` (macOS), `awk`, `sed`

## Testing Recommendations

1. **Local interactive build:**
   ```bash
   ./ci/local-build.sh --base-branch dev
   ```
   Should create release with context `local`

2. **Local non-interactive build:**
   ```bash
   TRIO_AGENT=1 ./ci/local-build.sh --base-branch dev
   ```
   Should create release with context `localCI`

3. **GitHub Actions:**
   - Trigger workflow manually or via schedule
   - Should create release with context `cloudCI`

4. **Verification:**
   - Check GitHub Releases page for new release
   - Verify tag exists and points to correct commit
   - Download manifest JSON asset and validate structure
   - Verify release description includes all patches

## Future Enhancements

- Add release notes template support
- Add release draft option for review before publishing
- Add release changelog generation from git commits
- Add release artifact uploads (IPA, dSYMs) as optional assets
- Add release webhook notifications

## Notes

- The script assumes `upstream/dev` remote exists or `origin/dev` can be used as fallback
- Patch metadata extraction matches the format used in `scripts/capture-build-details.sh`
- Manifest JSON uses temp files to avoid shell quoting issues with complex JSON
- All timestamps are in UTC
- Tag creation is idempotent (deletes and recreates if exists locally, force-pushes to remote)
