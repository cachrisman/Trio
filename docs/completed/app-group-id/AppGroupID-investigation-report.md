# AppGroupID Investigation Report – Watch Complication & App

**Date:** 2026-02-24  
**Version:** 4  
**Context:** Trio v0.6.0 builds 108/109/110; watch complication and app; cloud logging pipeline; build 111 preparation.

### Changelog

- **v4 (2026-02-24):** Updated with implementation progress: patches 05/06/09 regenerated; Config.xcconfig removed from patch 09; ComplicationLogBuffer added for complication cloud logging; queryAcks guard fix in patch 05; checklist updated with completion status; outstanding items identified.
- **v3 (2026-02-24):** Added Cursor transcript findings from UserData/cursor_cloud_logging_functionality_issu.md: watch app launch-then-quit, APP_GROUP_ID inconsistency root cause, Top 5 watch failure causes, cloud logging transport errors, fix path (standardize on TRIO_APP_GROUP_ID).
- **v2 (2026-02-24):** Added build 110 IPA findings (AppGroupID confirmed in Watch App); log file analysis (NSLog vs WatchLogger); 108→110 diff; cloud logging impact; proposed next steps.
- **v1 (2026-02-24):** Initial report for build 108.

---

## Root Cause Analysis

### What the Code Expects

1. **Info.plist** – Watch app and complication must have `AppGroupID` set to a runtime value like `group.org.nightscout.<TEAM>.trio.trio-app-group`.
2. **Entitlements** – Both must include `com.apple.security.application-groups` with the same identifier so `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` returns a valid URL.
3. **Build-time substitution** – `$(TRIO_APP_GROUP_ID)` in Info.plist and entitlements is resolved from `Config.xcconfig`, which uses `$(DEVELOPMENT_TEAM)`.

### Findings from the Codebase

| Item | Status |
|------|--------|
| **Main Trio target** | Uses `baseConfigurationReference` → `Config.xcconfig` ✓ |
| **Watch targets** | Do not have `baseConfigurationReference`; they rely on project-level inheritance |
| **Project config** | Project Debug/Release (388E5965/66) include `Config.xcconfig` ✓ |
| **Inheritance** | Targets inherit from project config by configuration name (Debug/Release), so `TRIO_APP_GROUP_ID` is expected to flow to watch targets |
| **sync_project_files_config.rb** | Adds `INFOPLIST_KEY_AppGroupID`, `INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS` for "Trio Watch App" and "Trio Watch Complication Extension" ✓ |
| **Patch 09** | Adds Info.plist entries, entitlement files, and `TrioComplicationDataStore`; Config.xcconfig change **removed** (v4); entitlements handled via sync_project_files_config.rb |

### Likely Failure Modes

1. **Watch entitlements not applied** – If `CODE_SIGN_ENTITLEMENTS` is not set for the watch targets before build, the app group entitlement is missing and `containerURL(...)` returns nil even if Info.plist has `AppGroupID`.
2. **Build setting resolution** – If `TRIO_APP_GROUP_ID` or `DEVELOPMENT_TEAM` are empty for the watch targets, substitution yields an invalid group ID or empty string.
3. **Sync vs. base project** – `sync_project_files.rb` injects entitlements/Info.plist settings. If sync does not run (e.g. some local/CI paths), or if `project.pbxproj` is overwritten before build, the watch targets can lose these settings.
4. **Config.xcconfig patch** – Patch 09 changes `Config.xcconfig` (adds `CODE_SIGN_ENTITLEMENTS[sdk=watchos*]`), which causes the known `git am --3way` failure (`sha1 information is lacking or useless`) because of frequently changing `Config.xcconfig` (e.g. `APP_DEV_VERSION`).

---

## 3 Proposed Resolutions

### Option 1: Explicit baseConfigurationReference for Watch Targets (Recommended)

**Goal:** Make watch targets explicitly depend on `Config.xcconfig` so they reliably get `TRIO_APP_GROUP_ID` and related variables.

**Steps:**
1. Add `baseConfigurationReference = 38F3783A2613555C009DB701 /* Config.xcconfig */` to the build configurations of:
   - Trio Watch App (Debug + Release)
   - Trio Watch Complication Extension (Debug + Release)
2. Implement by:
   - Patching `project.pbxproj` in patch 09 (or a dedicated patch)
   - Or extending `sync_project_files.rb` to set `baseConfigurationReference` for these targets
3. Do **not** add or keep Config.xcconfig changes that touch volatile lines (e.g. `APP_DEV_VERSION`, new entitlements line). Prefer injecting entitlements via the existing sync script.

**Pros:** Clear, explicit inheritance; reduces dependency on project-level config behavior.  
**Cons:** Requires project file edits; sync changes need to remain consistent.

---

### Option 2: Ensure Entitlements + Info.plist via Sync Only (No Config.xcconfig Changes)

**Goal:** Resolve AppGroupID entirely through sync and project changes, without modifying Config.xcconfig.

**Steps:**
1. Remove the `Config.xcconfig` part from patch 09 to avoid `git am` failures.
2. Rely on `sync_project_files_config.rb` for:
   - `INFOPLIST_KEY_AppGroupID` = `"$(TRIO_APP_GROUP_ID)"`
   - `CODE_SIGN_ENTITLEMENTS[sdk=watchos*]` = `"Trio Watch App/TrioWatchApp.entitlements"` and `"Trio Watch Complication/TrioWatchComplication.entitlements"` (already present).
3. Ensure sync runs before every build (Fastlane and `ci/local-build.sh` already call it).
4. Add Option 1’s `baseConfigurationReference` to watch targets if `TRIO_APP_GROUP_ID` is still not resolving.

**Pros:** No Config.xcconfig edits; avoids CI patch failure; sync is already the intended mechanism.  
**Cons:** Depends on sync running and on project-level config for variable resolution.

---

### Option 3: Runtime Fallback + Hardened Resolution Logic

**Goal:** Improve robustness when build-time configuration fails.

**Steps:**
1. In `TrioComplicationDataStore.resolveAppGroupID(bundle:)`, enhance fallbacks:
   - Prefer `Info.plist` AppGroupID.
   - If missing or invalid, derive from `WKCompanionAppBundleIdentifier`.
   - If that fails, derive from bundle identifier.
   - Optionally add a development-only fallback (e.g. environment variable or compiled constant) for local debugging.
2. Add a build-time assertion or diagnostic log when `AppGroupID` is missing or malformed so failures are easier to trace.
3. Keep Options 1 and 2 as the primary fix; use this as a safety net.

**Pros:** App is more resilient to config mistakes; easier to debug.  
**Cons:** Does not fix the underlying build configuration; fallbacks can mask setup errors.

---

## Recommended Path

1. **Short term:** Apply **Option 2** – remove Config.xcconfig from patch 09 so CI and `git am` succeed. Confirm sync injects the needed entitlements and Info.plist settings.
2. **Validation:** Add **Option 1** – set `baseConfigurationReference` for watch targets (via sync or a small project patch) so `TRIO_APP_GROUP_ID` is guaranteed.
3. **Hardening:** Implement **Option 3** – strengthen `resolveAppGroupID` fallbacks and logging for diagnostics.

---

## Config.xcconfig and Patch 09

- **Do not** keep Config.xcconfig in patch 09 in its current form; it causes `git am --3way` failures because of changing blob hashes (e.g. `APP_DEV_VERSION`).
- **Do** move the entitlements configuration to `sync_project_files_config.rb` (already done for per-target entitlements).
- The line `CODE_SIGN_ENTITLEMENTS[sdk=watchos*] = Trio/Resources/TrioWatch.entitlements` in Config.xcconfig is redundant if sync sets per-target entitlements (`TrioWatchApp.entitlements`, `TrioWatchComplication.entitlements`).

---

## Better Stack Log Findings (2026-02-24)

**Queries run (after authentication via `telemetry_create_cloud_connection_tool`):**

1. **AppGroupID / ComplicationDataStore / container / suite** – No results. The `TrioComplicationDataStore` NSLog messages (`[ComplicationDataStore] ❌ AppGroupID unresolved`, `✓ Resolved AppGroupID`, etc.) do not appear in Better Stack. Those use `NSLog`, which may not be in the cloud logging pipeline.

2. **watchOS logs (platform = watchos)** – Present. Observed:
   - `saveComplicationSnapshot called` – iPhone writes state for the complication
   - `forceComplicationUpdate: glucose=--` vs `glucose=93` – Sometimes `--` (fallback), sometimes a real value
   - `Watch received data` – Watch app receives full `watchState` via WCSession with `currentGlucose`, etc.

3. **Interpretation:**
   - **iPhone → Watch via WCSession works** – Watch receives data when the app is active
   - **Complication sees `--` often** – Complication runs in a separate process and reads from the shared App Group container. When it gets `--`, the shared container or UserDefaults lookup is likely failing
   - **ComplicationDataStore logs missing** – `NSLog` from the complication extension may not be sent to Better Stack. Consider routing those through `WatchLogger` for cloud visibility

---

## IPA Investigation – Trio-v0.6.0-108-local.ipa (2026-02-24)

### Info.plist

| Bundle | AppGroupID | WKCompanionAppBundleIdentifier |
|--------|------------|--------------------------------|
| **Trio.app** (main) | ✓ `group.org.nightscout.5QE6TMMEH2.trio.trio-app-group` | — |
| **Trio Watch Complication Extension.appex** | ✓ `group.org.nightscout.5QE6TMMEH2.trio.trio-app-group` | — |
| **Trio Watch App.app** | ❌ **Not present** | ✓ `org.nightscout.5QE6TMMEH2.trio` |

### Findings

1. **Complication Extension** – Info.plist includes AppGroupID; the complication process can resolve and use it.
2. **Watch App** – Info.plist does **not** include AppGroupID. The Watch App has `WKCompanionAppBundleIdentifier`, so `resolveAppGroupID` can derive the ID, but the bundle itself has no explicit key.
3. **ComplicationDebugView** runs in the **Watch App** process (Trio Watch App.app). It sees Bundle.main = Watch App, which has no AppGroupID key.
4. **Entitlements** – No `.entitlements` files in the IPA; they are embedded in the code signature. `codesign -d --entitlements` did not succeed on the extracted bundles. If the Watch App or Complication Extension lack the `com.apple.security.application-groups` entitlement, `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` returns nil even when AppGroupID is correct.

### Root cause (IPA-based)

The Watch App’s Info.plist does not contain AppGroupID. The Watch App can derive the ID from `WKCompanionAppBundleIdentifier`, but:

- If the Watch App **does not** have the app group entitlement, `UserDefaults(suiteName: ...)` and `containerURL(...)` return nil → "AppGroupID: Not Found" / "Container: No URL".
- Adding AppGroupID to the Watch App Info.plist (via patch/sync) ensures it is explicitly available and supports entitlement verification.

**Recommendation:** Add AppGroupID to `Trio Watch App/Info.plist` and ensure both Watch App and Complication Extension are built with the app group entitlement (TrioWatchApp.entitlements, TrioWatchComplication.entitlements).

---

## IPA Investigation – Trio-v0.6.0-110-local.ipa (2026-02-24)

### Info.plist

| Bundle | AppGroupID | WKCompanionAppBundleIdentifier |
|--------|------------|--------------------------------|
| **Trio Watch App.app** | ✓ `group.org.nightscout.5QE6TMMEH2.trio.trio-app-group` | ✓ `org.nightscout.5QE6TMMEH2.trio` |

### Findings

**Build 110 fixes the Watch App AppGroupID gap.** The Watch App Info.plist now includes `AppGroupID` explicitly. This was the key fix that was missing in build 108.

---

## Log File Analysis – build/logs (Trio worktree)

Inspected `build/logs/log.txt`, `log_prev.txt`, `watch_log.txt`, `watch_log_prev.txt` to determine whether `NSLog` / `[ComplicationDataStore]` output appears in the cloud log pipeline.

### Log formats

| File | Format | Source |
|------|--------|--------|
| **log.txt** / **log_prev.txt** | `YYYY-MM-DDTHH:mm:ss+ZZZZ [Category] File.swift - function - line - LEVEL: message` | Trio phone app (SimpleLogReporter) |
| **watch_log.txt** / **watch_log_prev.txt** | `[YYYY-MM-DDTHH:mm:ss+ZZZZ] [File.swift:line] function() → message` | Watch app (WatchLogger) |

### NSLog and ComplicationDataStore

- **TrioComplicationDataStore** previously used `NSLog("[ComplicationDataStore] …")` exclusively. Its `log()` helper called `NSLog`.
- **NSLog** goes to the unified logging system (os_log / Console). It is **not** written to `log.txt` or `watch_log.txt`.
- **watch_log.txt** is written by **WatchLogger** in the Watch App extension. The **Complication Extension** is a separate process and cannot use WatchLogger directly (WCSession is unavailable).
- **Fix (v4):** `TrioComplicationDataStore.log()` now routes through `ComplicationLogBuffer.append()`, which writes to an App Group file (`logs/complication_log.txt`). The Watch App's `WatchLogger.drainComplicationLogs()` atomically renames and sends this file to the iPhone, where it enters the cloud logging pipeline with `source=complication` tagging for BetterStack filtering. The `defaultSharedContainerURL()` diagnostic NSLog calls remain as-is since they fire during App Group resolution (before the buffer is usable).

### Sample lines found

- **log.txt:** `[Nightscout] FetchTreatmentsManager.swift - subscribe() - 29 - DEV: FetchTreatmentsManager heartbeat`
- **watch_log.txt:** `[WatchState.swift:662] forceComplicationUpdate() → forceComplicationUpdate: glucose=--, readingDate=...`

These match the formats parsed by `CloudLogLineParser.parseIOS` and `parseWatch`.

---

## Build 108 vs 110: What Changed

Git diff between `ci-build/trio-v0.6.0-108-local` and `ci-build/trio-v0.6.0-110-local`:

| Area | Change |
|------|--------|
| **Trio Watch App/Info.plist** | AppGroupID added ✓ |
| **TrioComplicationDataStore** | Added `resolveAppGroupID()` with fallbacks (Info.plist → WKCompanionAppBundleIdentifier → bundleIdentifier); improved `appGroupDefaults`; **NSLog kept** (no cloud-logging replacement) |
| **patches/06-cloud-logging.patch** | Parser relaxed: level regex `(DEV\|INFO\|WARN\|ERR)` → `([A-Z]+)`; added DEBUG/WARNING/ERROR aliases; `parseWatch` no longer requires method to end with `()` (now handles `session(_:didReceiveUserInfo:)` etc.) |
| **Patches 09, sync script** | App Group config for watch targets |

### Cloud logging parser (108→110)

- Parser changes are **more permissive**, not stricter.
- They should parse more lines (e.g. methods without trailing `()`), so they are unlikely to be the cause of the pipeline breaking.
- If cloud logging “stopped working” after 110, other causes are more plausible (token/config, network, WCSession delivery, settings, or app state).

---

## Cloud Logging Pipeline Impact

### Pipeline flow

1. **Phone:** TrioLogger → `Documents/logs/log.txt`
2. **Watch:** WatchLogger → local file → WCSession transfer → phone appends to `Documents/logs/watch_log.txt`
3. **Phone:** CloudLogUploadService reads `log.txt` and `watch_log.txt` → uploads to Better Stack

### Possible causes of “pipeline stopped working”

1. **Token/config:** Cloud logging disabled, token missing/expired, or ingestion URL wrong.
2. **Watch → phone delivery:** WatchLogger payloads not reaching the phone (WCSession reachability, background limits).
3. **App group / UserDefaults:** CloudLogUploadService reads settings from UserDefaults; if app group or defaults changed, behavior could differ.
4. **Different interpretation:** “Stopped working” might mean “no ComplicationDataStore logs in Better Stack” – those were never in the pipeline (NSLog only).

### Recommendation

- Re-check cloud logging settings (Settings → Cloud Logging) and that a valid token is set.
- Confirm watch logs are still written to `watch_log.txt` on the device (e.g. via Xcode or device logs).
- Add a short test: enable cloud logging, use the app briefly, and verify uploads in Better Stack.
- If uploads succeed but ComplicationDataStore logs are missing, that is expected; add routing through WatchLogger or a similar mechanism for cloud visibility.

---

## Cursor Transcript Findings (2026-01-18 / builds 109–110)

Findings from [UserData/cursor_cloud_logging_functionality_issu.md](../UserData/cursor_cloud_logging_functionality_issu.md), captured during debugging of cloud logging and watch app issues.

### Watch app launch-then-quit (build 109/110)

- **watch_log.txt:** No explicit crash marker; `applicationDidBecomeActive` immediately followed by `applicationWillResignActive` (same-second)
- **wcd connectivity:** Occasional `connection to service named com.apple.wcd` failures
- **Phone reports:** "Trio Watch app is not installed", "isPaired: false", "Phone not reachable" during install window
- **watch_log gap:** No entries written during the period from build 109 install until downgrade to 108 – watch → phone log delivery pipeline stopped

### Root cause – APP_GROUP_ID inconsistency

Patch 09 used **`$(APP_GROUP_ID)`** in `Trio/Resources/TrioWatch.entitlements` and some plists while **`$(TRIO_APP_GROUP_ID)`** was used elsewhere. When watch targets did not inherit `APP_GROUP_ID` in their build config, substitution failed → entitlements and Info.plist ended up with unresolved placeholders or empty values.

**Fix applied in transcript:** Standardized on `$(TRIO_APP_GROUP_ID)` everywhere; updated `sync_project_files_config.rb` to force watch targets to have `APP_GROUP_ID = $(TRIO_APP_GROUP_ID)` and per-target entitlements.

### Top 5 watch failure causes (from transcript analysis)

1. **Watch app Info.plist "merge file" risk** – Minimal plist may lack required WatchKit keys if used as sole plist; watch app can launch, show snapshot, then be killed
2. **`CODE_SIGN_ENTITLEMENTS[sdk=watchos*]` in Config.xcconfig** – Project-level override can clobber per-target entitlements; also causes `git am --3way` failure
3. **`setupWatchState` callers guard on `isReachable`** – When watch is not reachable (e.g. after crash), phone never builds/sends WatchState; `transferUserInfo` (background delivery) is never triggered
4. **watchOS 10-only `.containerBackground(..., for: .widget)`** – Unguarded usage on watchOS &lt; 10 can prevent complication from loading
5. **Date serialization change (TimeInterval → Date)** – If watch-side `dateValue(from:)` does not handle Date, `saveComplicationSnapshot` skips persistence

### Cloud logging transport errors (build 109)

- **BetterStackLogtailProvider:** NSURLErrorDomain -1005 (connection lost), -1001 (timeout)
- **CloudLogUploader:** "upload failed … offset not advanced" for log.txt and log_prev.txt
- **Test Connection button:** Works (single small foreground request); background/batched uploader fails during lifecycle transitions (e.g. during TestFlight install)
- **Build 108 restored:** Cloud logging worked again after downgrading; patch 09’s increased watch log volume/churn likely pushed uploader into timeouts

---

## Proposed Next Steps

### 1. AppGroupID / complication (build 110) — RESOLVED

- Build 110 fixed the Watch App Info.plist AppGroupID.
- Build 111 patches further standardize on `$(TRIO_APP_GROUP_ID)` and remove Config.xcconfig from patch 09.

### 2. Cloud logging — MOSTLY RESOLVED

- **Done:** ComplicationDataStore logs now route through `ComplicationLogBuffer` → Watch App drain → iPhone → BetterStack (with `source=complication` tag).
- **Done:** queryAcks guard fix in patch 05 unblocks pending payload retry protocol.
- **Done:** Red-team fixes applied: UTF-8 safe truncation, stable payloadId per drain file, upsert pending records.
- **Action:** Verify pipeline end-to-end after build 111: token, Settings UI, and Better Stack ingestion (including complication-sourced logs).
- **Optional:** Add simple upload-success/failure logging in CloudLogUploadService for debugging.

### 3. Patch stack / CI — RESOLVED

- **Done:** Config.xcconfig removed from patch 09.
- **Done:** Entitlements handled via `sync_project_files_config.rb` (per-target `CODE_SIGN_ENTITLEMENTS` and `APP_GROUP_ID`).
- **Done:** `ComplicationLogBuffer.swift` added to sync config for Trio, Watch App, and Complication Extension targets.
- **Done:** All 9 patches validate cleanly with `patch-test.sh`.
- **Action:** Commit updated patches (05, 06, 09) and sync config to `dev` in Trio-dev before build.

### 4. Checklist

- [x] Patch 09 does not modify Config.xcconfig.
- [x] `sync_project_files.rb` is invoked before the build (Fastlane and local-build.sh already call it).
- [ ] `baseConfigurationReference` for watch targets is set (Option 1 or equivalent). *Currently relying on project-level inheritance; not yet explicitly set per-target.*
- [x] `TrioWatchApp.entitlements` and `TrioWatchComplication.entitlements` exist and contain the app group.
- [x] Watch `Info.plist` files include `AppGroupID` with `$(TRIO_APP_GROUP_ID)`.
- [x] `ComplicationLogBuffer.swift` in sync config for all three watch-related targets.
- [x] queryAcks protocol fixed (patch 05) — iPhone-side guard no longer rejects queryAcks envelopes.

---

## IPA and Log Inspection (Optional)

To verify what is in the built app:

```bash
# Inspect watch app bundle
unzip -l Trio-v0.6.0-108-local.ipa | grep -i watch

# Inspect entitlements (after extracting)
unzip -p Trio-v0.6.0-108-local.ipa "Payload/Trio.app/Watch/*/Trio\\ Watch\\ App.app/PlugIns/*.appex" 2>/dev/null | ...
# Or use: codesign -d --entitlements :- path/to/App.app
```

Better Stack queries (after authentication):

- `AppGroupID`, `AppGroup`, `container`, `complication`, `watch` in Trio logs.
- Errors/warnings in the last 24h for `Trio`.

---

## Checklist Before Next Build

(Same as Proposed Next Steps §4; kept for reference.)

- [x] Patch 09 does not modify Config.xcconfig.
- [x] `sync_project_files.rb` is invoked before the build.
- [ ] `baseConfigurationReference` for watch targets is set (Option 1 or equivalent). *Outstanding — relying on project-level inheritance.*
- [x] `TrioWatchApp.entitlements` and `TrioWatchComplication.entitlements` exist and contain the app group.
- [x] Watch `Info.plist` files include `AppGroupID` with `$(TRIO_APP_GROUP_ID)`.
- [ ] Commit updated patches (05, 06, 09) and `sync_project_files_config.rb` to `dev` in Trio-dev.
- [ ] Sync Trio-dev with upstream/dev (if not already current).
- [ ] Run `patch-test.sh` one final time after commit.
- [ ] Verify cloud logging pipeline end-to-end after build 111 (including `source=complication` logs in BetterStack).
