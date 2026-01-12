# Release Recording Automation Proposal

## Current State

- **local-build.sh**: No release recording
- **GitHub Actions workflow**: No release recording
- **Documentation**: Specifies minimum viable release record (lines 265-285 in `feature-branch-workflow-optimization.md`)

## Requirements (from docs)

Minimum viable release record:
- Base upstream commit SHA (upstream `dev` synced from)
- Fork `dev` commit SHA (used for build)
- List of patch filenames applied (in order)
- SHA256 of each patch file
- Timestamp
- Build number/version (from Fastlane)

## Options

### Option 1: Standalone script called by local-build.sh

**Implementation:**
- Create `scripts/record-release.sh`
- Call it from `local-build.sh` after successful build (before/after TestFlight upload)
- Also callable manually: `scripts/record-release.sh --build-dir <path>`
- Output: JSON file in `releases/YYYY-MM-DD-HHMMSS-<build-number>.json`

**Pros:**
- Reusable across local and CI
- Easy to test independently
- Can be run manually for retroactive recording
- Clear separation of concerns

**Cons:**
- Requires passing build context (dir, build number) between scripts
- Need to extract build number from Fastlane output or Xcode project

**Risks:**
- Low - script can fail gracefully without breaking build
- Need to handle worktree paths correctly

**Missing:**
- Mechanism to extract build number from Fastlane/Xcode
- Upstream commit SHA detection (may need git remote tracking)

---

### Option 2: Integrated into local-build.sh

**Implementation:**
- Add release recording function directly in `local-build.sh`
- Execute after successful build, before TestFlight upload
- Output: Same JSON format in `releases/` directory

**Pros:**
- All build logic in one place
- Direct access to build context variables
- No script invocation overhead

**Cons:**
- Harder to reuse in CI (would need to duplicate logic)
- Makes `local-build.sh` longer/more complex
- Less testable in isolation

**Risks:**
- Medium - if recording fails, could break build flow (mitigate with `set +e`)

**Missing:**
- Same build number extraction challenge
- Upstream SHA detection

---

### Option 3: Fastlane action/plugin

**Implementation:**
- Create Fastlane action `record_release` or Ruby script
- Call from `fastlane/Fastfile` after `build_trio` lane
- Output: JSON in `releases/` or `artifacts/`

**Pros:**
- Natural integration point (Fastlane already has build number)
- Works in both local and CI contexts
- Can access Fastlane context (build number, version)

**Cons:**
- Requires Ruby knowledge for maintenance
- Less flexible for manual runs
- Fastlane context may not have all git info needed

**Risks:**
- Low - Fastlane actions can fail gracefully
- Need to ensure git operations work in CI environment

**Missing:**
- Upstream commit SHA detection (git remote logic)
- Patch SHA256 calculation

---

### Option 4: Hybrid: Script + Fastlane integration

**Implementation:**
- Create `scripts/record-release.sh` (standalone, reusable)
- Call from `local-build.sh` after build
- Also call from Fastlane `build_trio` lane (via `sh()`)
- Fastlane passes build number as env var

**Pros:**
- Best of both worlds: reusable script + natural integration
- Works in local-build.sh and CI
- Fastlane provides build number easily
- Script handles git/patch logic

**Cons:**
- Slightly more complex setup
- Need to coordinate between Fastlane and script

**Risks:**
- Low - script can be made robust with error handling

**Missing:**
- Upstream commit SHA detection (needs git remote logic)

---

### Option 5: GitHub Releases (via API/CLI)

**Implementation:**
- Create `scripts/record-release.sh` that generates JSON metadata
- Script also creates GitHub Release via `gh release create` or GitHub API
- Release notes contain formatted metadata (markdown)
- JSON file attached as release asset
- Tag created: `build-<build-number>` or `v<version>-build-<build-number>`
- Only create release after successful TestFlight upload (not for every build)

**Pros:**
- **Discoverable**: Visible in GitHub UI, searchable, linked to commits
- **Integrated**: Native GitHub feature, works well with GitHub Actions
- **Artifacts**: Can attach JSON metadata file, IPA, dSYMs as release assets
- **Automation-friendly**: `gh` CLI or GitHub API easy to use (GH_PAT already available)
- **No repo clutter**: Releases don't create files in repo (unlike `releases/` directory)
- **Versioning**: Natural fit for tracking builds over time
- **Access control**: Can be draft/prerelease until ready

**Cons:**
- **Tag creation**: Creates tags in repo (could clutter if every build gets a release)
- **GitHub dependency**: Requires GitHub API access (GH_PAT), local builds need auth
- **Decision needed**: Which builds get releases? Only TestFlight uploads? Every build?
- **Complexity**: More moving parts than just writing JSON file
- **Retroactive**: Harder to create releases for old builds (need to tag old commits)
- **Local builds**: Need GitHub auth configured locally (may be barrier)
- **Rate limits**: GitHub API has rate limits (unlikely to hit, but possible)

**Risks:**
- **Medium**: If release creation fails, need graceful fallback (don't break build)
- **Tag conflicts**: If tag already exists, release creation fails (need handling)
- **Auth issues**: Local builds fail if GH_PAT not configured (mitigate with optional flag)

**Missing:**
- Decision on release naming/tagging strategy
- Handling of draft vs published releases
- What to do if release creation fails (fallback to local JSON?)

**Implementation sketch:**
```bash
# scripts/record-release.sh --github-release
# Generate JSON metadata
# Create tag: build-<build-number>
# Create GitHub Release with:
#   - Tag: build-<build-number>
#   - Title: "Build <build-number>"
#   - Body: Formatted markdown with metadata
#   - Assets: release-metadata.json
#   - Draft: false (or true for local builds?)
```

```yaml
# In GitHub Actions (after TestFlight upload):
- name: Create GitHub Release
  if: success()
  run: |
    scripts/record-release.sh \
      --build-dir "${{ github.workspace }}" \
      --build-number "$BUILD_NUMBER" \
      --github-release \
      --tag "build-$BUILD_NUMBER"
  env:
    GH_TOKEN: ${{ secrets.GH_PAT }}
```

---

## Recommendation: **Option 5 (GitHub Releases) with Option 4 fallback**

**Reasoning:**
1. **Discoverability**: GitHub Releases are visible, searchable, and linked to commits - much better than files in a `releases/` directory
2. **Integration**: Works naturally with GitHub Actions (you're already using GH_PAT)
3. **Artifacts**: Can attach JSON metadata, IPA, dSYMs - useful for debugging
4. **No repo clutter**: Doesn't create files that need to be committed/managed
5. **Versioning**: Natural fit for tracking builds over time with tags

**However**, I recommend a **hybrid approach**:
- **Primary**: Create GitHub Release after successful TestFlight upload
- **Fallback**: Also write JSON to `releases/` directory (or `build/artifacts/`) for:
  - Local builds without GitHub auth
  - Retroactive recording
  - Backup if release creation fails

**Decision points:**
1. **Which builds get releases?**
   - **Recommendation**: Only builds that upload to TestFlight (not `--build-only`)
   - Rationale: Avoids cluttering releases with every local test build

2. **Tag naming:**
   - **Recommendation**: `build-<build-number>` (e.g., `build-1234`)
   - Alternative: `v<version>-build-<build-number>` if you want version grouping
   - Rationale: Simple, unique, sortable

3. **Draft vs Published:**
   - **Recommendation**: Published releases (not drafts)
   - Rationale: These are real TestFlight builds, should be visible
   - Could add `--draft` flag for local builds if desired

4. **Local builds:**
   - **Recommendation**: Make GitHub release optional with `--github-release` flag
   - Default: Write JSON only (no release)
   - If `--github-release` set and GH_PAT available: Create release
   - If `--github-release` set but no GH_PAT: Warn and write JSON only

**Weak points to address:**
1. **Tag conflicts**: If tag exists, release creation fails
   - Solution: Check if tag exists, skip release creation (or use `--force` carefully)
   - Or: Use unique tag format like `build-<build-number>-<timestamp>`

2. **Local GitHub auth**: Users need `gh` CLI or GH_PAT configured
   - Solution: Make it optional, fallback to JSON-only
   - Document in README/AGENTS.md

3. **Retroactive releases**: Hard to create for old builds
   - Solution: Script can create release from existing JSON file
   - Or: Accept that old builds won't have releases (document limitation)

4. **Rate limits**: GitHub API has limits
   - Solution: Unlikely to hit (1000/hour), but add retry logic if needed

**Why not just Option 4?**
- Option 4 (local JSON files) is simpler but less discoverable
- GitHub Releases provide better visibility and integration
- You already have GH_PAT, so the infrastructure is there
- The hybrid approach gives you both: releases for visibility, JSON for backup/flexibility

## Revised Recommendation: **Option 5 (GitHub Releases) with Option 4 fallback**

**Final evaluation:**

After reconsidering GitHub Releases, I believe it's the better choice for your use case:

**Why GitHub Releases wins:**
1. **You're already on GitHub** - GH_PAT is available, infrastructure is there
2. **Discoverability** - Much better than files in a directory (visible in UI, searchable)
3. **Integration** - Natural fit with GitHub Actions workflow
4. **Artifacts** - Can attach JSON, IPA, dSYMs for debugging
5. **No repo clutter** - Doesn't create files that need git management

**Why the hybrid approach:**
- **Primary**: GitHub Release for visibility and integration
- **Fallback**: Local JSON file for:
  - Local builds without GitHub auth
  - Retroactive recording
  - Backup if release creation fails
  - Offline/air-gapped scenarios

**Tradeoffs I'm being honest about:**
- **Tag creation**: Creates tags in repo (but only for TestFlight builds, not every build)
- **Local auth**: Requires `gh` CLI or GH_PAT (but can be optional with fallback)
- **Complexity**: More moving parts than just JSON file (but better UX)

**If you want simpler**: Option 4 (local JSON) is perfectly valid and easier to maintain. GitHub Releases add value but also complexity.

## Next Steps (Option 5 + fallback)

1. Create `scripts/record-release.sh` with:
   - Git commit SHA detection (fork dev)
   - Upstream commit SHA detection (with fallback)
   - Patch enumeration and SHA256 calculation
   - Build number from env var
   - JSON output generation (always)
   - GitHub Release creation (optional, via `--github-release` flag)
   - Tag creation: `build-<build-number>`
   - Release notes: Formatted markdown with metadata

2. Integrate into `local-build.sh`:
   - Extract build number (from project or Fastlane output)
   - Call script after successful TestFlight upload (not for `--build-only`)
   - Pass `--github-release` only if GH_PAT available and not `--build-only`

3. Integrate into Fastlane:
   - Add call to script in `release` lane (after TestFlight upload)
   - Pass build number as env var
   - Use `--github-release` flag

4. Add to GitHub Actions:
   - Add step after TestFlight upload to call script
   - Use `--github-release` flag (GH_PAT already available)
   - Ensure git context is available

5. Test:
   - Local build with `--build-only` (JSON only, no release)
   - Local build with TestFlight upload + GH_PAT (JSON + release)
   - Local build with TestFlight upload but no GH_PAT (JSON only, warn)
   - CI build (GitHub Actions) - should create release
   - Tag conflict scenario (skip release if tag exists)
