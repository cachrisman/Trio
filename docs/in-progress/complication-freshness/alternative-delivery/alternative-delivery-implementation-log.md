# Alternative Delivery — Implementation Log

**Version:** 1.4
**Date:** 2026-03-19 11:33 CET
**Last updated:** 2026-04-06 17:27 CET

---

### Build 146 — Step 5.1 first-pass background-task completion alignment (2026-03-30)

**Status:** Deployed in build 146. Partially effective only — the user-visible 5-second dismissal persisted.
**Branch:** `feature/watch-complication-improvements`
**Commits:** `07175b5773e68d95f23b691c08d61243a93c305b` (`fix(watch): align connectivity task completion with terminal paths`)
**Patch:** `09-watch-complication-improvements.patch` regenerated and deployed in build 146
**Build:** 146 — deployed

**Production findings after build 146:**

1. **Early completion paths do run.**
   - observed: `path=fast`, `path=application_context`, `path=application_context_late_task`
2. **`path=timeout` still dominates many wake windows.**
   - completion delays remain clustered around ~5.0–5.2 seconds
3. **Deferred completions had no follow-up retry.**
   - `complication_bgtask_completion_deferred ... pending_content=true` often fell through to timeout
4. **Late-task marker chaining bug confirmed.**
   - production logs showed `fast_late_task_late_task`

**Conclusion:** the first-pass fix was not a no-op, but it did not materially change the dominant timeout behavior. The original diagnosis was only partially sufficient; a second pass was required to fix marker canonicalization and to retry deferred completions before the 5-second watchdog won.

### Post-build-146 second-pass follow-up — deferred completion retry and canonical late marker (2026-03-30)

**Status:** Committed in `Trio`, patch-regenerated in `Trio-dev`. **Production telemetry (Better Stack, Trio source, queried 2026-04-06)** shows the second-pass log lines (`complication_bgtask_terminal_marker`, `complication_bgtask_completion_retry_*`, etc.), so a build containing this follow-up is on-device — the exact TestFlight build number was not pinned in this documentation pass.
**Branch:** `feature/watch-complication-improvements`
**Commits:** `58f706a0ff4dd781d4636b9fd4688d64b0b6bf77` (`fix(watch): retry deferred connectivity task completion`)
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --from-feature-branch --feature-branch feature/watch-complication-improvements`
**Build:** not recorded here (see Better Stack snapshot below for observational validation)

**Files touched in this second pass:**
- `Trio Watch App Extension/WatchState.swift`

**What changed in `WatchState.swift`:**

1. Added `canonicalConnectivityTerminalPath(_:)` so terminal markers store a base path and late rescue appends `_late_task` only once.
2. Widened the late-task rescue window from 1.0 seconds to 2.0 seconds.
3. Added bounded deferred-completion retry state:
   - `deferredConnectivityCompletionWorkItem`
   - `deferredConnectivityCompletionDeadline`
   - `deferredConnectivityCompletionPath`
   - `deferredConnectivityCompletionAttempt`
4. When completion is deferred because `hasContentPending == true`, pending tasks now schedule a main-thread retry loop:
   - exponential backoff starting at 0.2 seconds
   - capped at 1.0 second
   - overall retry budget of 4.0 seconds
5. `scheduleUIUpdate` now re-enters on main before touching completion helpers or debounce state.
6. Added extra lifecycle telemetry:
   - `complication_bgtask_terminal_marker`
   - `complication_finalize_no_pending_tasks`
   - `complication_bgtask_completion_retry_pending`
   - `complication_bgtask_completion_retry_ready`
   - `complication_bgtask_completion_retry_expired`
7. Tightened retry attempt semantics:
   - repeated defers for the same path no longer burn retry attempts or cancel/recreate the same scheduled retry
8. Hardened canonicalization to avoid producing an empty path if a malformed string ever consisted only of `_late_task` fragments.

**Key implementation decisions kept:**

- **`hasContentPending` remains the correctness gate.**
  The follow-up adds retry, not permission to complete a wake while buffered session content still exists.

- **Timeout remains the final fallback.**
  If `hasContentPending` stays true through the retry budget, the task still falls back to the existing 5-second watchdog completion.

- **No snapshot/UI changes.**
  `setTaskCompletedWithSnapshot(false)` stays unchanged, and no stale-data / syncing UI behavior was modified.

- **No watch-state-specific pending tracker yet.**
  Still deferred because it is a larger lifecycle model, not a small observability tweak.

**Validation targets (still partially subjective / baseline-dependent):**

1. App no longer returns to the clock face at about 5 seconds after launch from the complication or app menu — **requires on-device UX check**; not inferable from logs alone.
2. `event=complication_bgtask_completing path=timeout` drops relative to the build-146 baseline — **needs a pinned pre/post build comparison**; see Better Stack snapshot for a 7-day aggregate only.
3. No `..._late_task_late_task` chaining in production logs — **still failing intermittently** in the 2026-04-06 window (see snapshot).
4. Deferred wakes that drain in time show `complication_bgtask_completion_retry_ready` — **observed** (see snapshot).
5. Residual deferred wakes that do not drain in time show `complication_bgtask_completion_retry_expired` — **not observed in the 7-day window** below (zero events); continue to watch when `hasContentPending` stays true past the retry budget.
6. No sign that later watch-state updates are lost when both `applicationContext` and `transferUserInfo` participate in the same wake — **ongoing** qualitative monitoring.

### Better Stack — production snapshot (queried 2026-04-06)

**Scope:** Trio log source; rolling **7-day** window; `remote(t491594_trio_logs)` ∪ `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1` (same pattern as `docs/process/betterstack-guide.md`). Counts are observational telemetry, not clinical measures.

**R4 (iOS `applicationContext` gate health):** Among lines containing `context_`, `context_attempted` = `context_succeeded` = **4196**; **`context_failed` = 0** over 7d.

**R6 (`hk_observer_fired`):** Daily event counts (UTC `toDate(dt)`): 2026-03-30 **6**, 03-31 **89**, 04-01 **41**, 04-02 **50**, 04-03 **71**, 04-06 **3** (partial day in window). **262** lines in 7d matched `hk_observer_fired` with `sync_lag=` (R6.1 field name; build 140 used `save_age=` — see design §R6 validation). **p50 `sync_lag` ≈ 604s**, **p90 ≈ 1016s** (~17 min). High tails correlate with bootstrap / catch-up (`query_type=sampleQuery_bootstrap`, large `samples_in_batch` in samples), not a single “bad” steady state.

**Step 5.1 — `complication_bgtask_completing` path tokens (7d, parsed `path=`):** Dominant: `fast` **1832**, `application_context` **531**, `fast_late_task` **239**, `application_context_late_task` **142**, `timeout` **43** (plus smaller buckets). **Double `_late_task` suffix still appears rarely:** **4** lines matched `late_task_late_task` in 7d (canonicalization not yet zero in production).

**Second-pass telemetry volume (7d):** `complication_bgtask_terminal_marker` **1161**; `complication_bgtask_completion_retry_ready` **33**; `complication_bgtask_completion_retry_pending` **31**; `complication_bgtask_completion_retry_expired` **0**; `complication_finalize_no_pending_tasks` **249**. Lines with `complication_bgtask_completion_deferred` and `pending_content=true`: **437** in 7d — still material; correlate with retry and timeout paths over time.

### Build 140 — Step 7: R6 HealthKit Background Delivery (2026-03-14)

**Commits:** `1b1c2d10d` (R6 implementation), `f1cadf3e2` (HKUnit fix + NSHealthUpdateUsageDescription) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick 1b1c2d10d,f1cadf3e2`
**Build:** 140 (v0.6.0) — deployed to TestFlight

**R6a — Background delivery registration:** Confirmed working. `hk_background_delivery_registered success=true` logged at 15:45:19 UTC on first watch app launch after install.

**R6b — Observer query:** Confirmed working. `hk_observer_fired` events observed at 15:45:20, 15:52:54, 15:54:15 UTC with correct glucose values (110, 111) and derived deltas (-9, -2).

**R6c — Sample fetch + snapshot save:** Confirmed working. Glucose extracted from HealthKit samples, delta derived from 2-sample comparison, snapshot saved to App Group via `TrioComplicationDataStore.shared.save()`.

**Unplanned remediations (2 issues discovered during build/deploy):**

1. **`HKUnit.milligramsPerDeciliter` unavailable on watchOS:** Build error — `type 'HKUnit' has no member 'milligramsPerDeciliter'`. The convenience property is a custom extension in `LoopKit/MockKitUI`, linked only to the iOS target. **Fix:** Replaced with `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))` inline in `WatchState.swift`.

2. **`NSHealthUpdateUsageDescription` required by App Store Connect:** Upload to TestFlight rejected (ITMS-90683) despite `toShare: nil`. Apple requires both HealthKit usage description keys whenever the `com.apple.developer.healthkit` entitlement is present, regardless of actual API usage. Developer forums confirm this is a blanket validation rule affecting both read-only and write-only apps. **Fix:** Added `NSHealthUpdateUsageDescription` to `Trio Watch App/Info.plist`. The string does not grant additional capability — the authorization request remains read-only (`toShare: nil`).

**Observation:** Both remediations were discovered during the build/deploy cycle, not during the code review phase. The `HKUnit` issue was a watchOS target linkage gap that Xcode doesn't surface until compilation. The `NSHealthUpdateUsageDescription` requirement was a runtime App Store validation rule not documented in Apple's HealthKit authorization guide — only discoverable via actual upload attempt or developer forum reports.

**Ongoing observation (updated 2026-04-06):** Validate in Better Stack: (a) `hk_observer_fired` continues on a CGM-consistent cadence when the watch is active — daily volumes in **Better Stack — production snapshot** (second-pass section above) are consistent with intermittent delivery, not silence; (b) **latency:** for build **141+** use **`sync_lag=`** in `hk_observer_fired` (same semantics as build 140’s `save_age=`); do not expect a single p90 threshold to hold across bootstrap, low power, and multi-sample catch-up — segment by `query_type` / `samples_in_batch` when investigating tails; (c) events continue during budget-exhaustion windows (correlate with `budget_exhausted` / transfer metrics in the same hours); (d) dual-delivery dedup behavior matches plan §R6 / R6.1 expectations.

---

### Build 142 — Step 5: R4 applicationContext safety net (2026-03-19)

**Commits:** `a33ddc4b6` (transferUserInfo fallback fix), `5ba994fcb` (R4 implementation) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick a33ddc4b6,5ba994fcb`
**Build:** 142 (v0.6.0) — deployed to TestFlight

**R4 — applicationContext safety net:** Validated. All three signals confirmed:

1. **iOS sends (Signal 1):** `context_attempted` and `context_succeeded` events logged every ~5 minutes during budget-exhausted windows (evening hours). 100% success rate — zero `context_failed` events.

2. **Watch receives (Signal 2):** Over 50 `didReceiveApplicationContext` events observed on the watch side during the budget-exhausted and overnight period.

3. **Freshness improvement (Signal 3):** `complication_reload_age` p90 = 384s during the evening budget-exhausted R4-active period. This is a significant improvement over the overnight average (621s) and the dormant morning hours (609-1211s).

**Morning freshness paradox:** Morning hours showed higher `complication_reload_age` values (609-1211s) despite healthy budget (R4 dormant). This is attributable to watchOS sleep-time throttling and low battery state (`battery_level_percent=50 battery_state=unplugged` in morning logs). During sleep/low battery, watchOS aggressively defers WCSession deliveries and WidgetKit `getTimeline` calls. This is normal watchOS power management behavior, not an R4 comparison issue.

**Next step:** R5b-d observability hardening (Step 6).

---

### Build 143 — R4 handler upgrade with R5d integration (2026-03-19/20)

**Commits:** `eea6d5ba3` (build 143 patch-09 changes) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` (mid-stack update)
**Build:** 143 (v0.6.0) — deployed to TestFlight 2026-03-19 ~21:09 UTC

**What was done:**

The standalone R4 `didReceiveApplicationContext` handler shipped in build 142 was upgraded with R5d three-constraint ordering:

1. Compute `gap` from `lastDataReceivedAt` BEFORE updating the timestamp
2. `saveComplicationSnapshot(from: payload)` — save the incoming data
3. Update `lastDataReceivedAt = Date()`
4. If `gap > 600` → log `sleep_gap_detected_context gap_seconds=<n>` and call `forceWidgetReloadIfStale(receivedGap:)`

This brings `didReceiveApplicationContext` to parity with `didReceiveUserInfo` — both channels now participate in sleep-gap detection and forced reload. The `forceWidgetReloadIfStale` helper (shared with `didReceiveUserInfo`) provides the 5-minute rate limiter and snapshot diagnostic read.

**Files touched:**
- `Trio Watch App Extension/WatchState.swift` — R4 handler upgrade (lines ~633-642 replaced with ~15-line R5d-integrated version)

**Deviations from build 142:** None — the build 142 handler was additive (standalone `saveComplicationSnapshot` call). The upgrade wraps the same save in the R5d gap-detection pattern, adding only the gap computation, timestamp update, and conditional forced reload.

---

### Step 5 / R4 — applicationContext safety net (2026-03-18 22:54 CET)

**Status:** Code review passed. Deployed as build 142 — see entry above for validation results.

**What was done:**

1. **iOS side (`AppleWatchManager.swift`):** Added R4 `updateApplicationContext` safety net at the END of `sendDataToWatch()`, after all existing transfer/sendMessage calls and the R1b queue-deep drain block. Four-step flow:
   - `sessionIsReadyForTransfer()` guard — logs `context_skipped` with all three readiness conditions on failure.
   - Budget/queue gate — `budgetExhausted || queueDeep`; silent return when budget is healthy (no log event).
   - Builds `ctx` dictionary wrapping `complicationMessage` under `WatchMessageKeys.watchState` with `context_updated_at` timestamp. Logs `context_attempted`.
   - `try session.updateApplicationContext(ctx)` — logs `context_succeeded` on success, `context_failed` on error.

2. **Watch side (`WatchState.swift`):** Added standalone R4 `didReceiveApplicationContext` handler after `sessionReachabilityDidChange` (~line 633). Handler logs receipt via `WatchLogger.shared.log`, extracts `WatchMessageKeys.watchState` payload, and calls `saveComplicationSnapshot(from:)` on the main queue. Dedup handled by `saveOnMain` (FP-Phase 3.1) automatically. No R5d dependencies (`lastDataReceivedAt`, `forceWidgetReloadIfStale` — those are Step 6).

**Files touched:**
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — R4 iOS side (lines 861–882)
- `Trio Watch App Extension/WatchState.swift` — R4 watch side (lines 633–642)

**Acceptance verification:**
- `sessionIsReadyForTransfer()` confirmed to NOT check `isReachable` (checks `activationState`, `isPaired`, `isWatchAppInstalled` only) — `updateApplicationContext` is valuable when watch is not reachable.
- `complicationMessage` is in scope (built unconditionally by R3 at top of `sendDataToWatch`), wrapped under `WatchMessageKeys.watchState`.
- Watch-side handler uses `Task { await WatchLogger.shared.log(...) }` (watch-side pattern), not `debug(.watchManager, ...)`.
- No new linter errors introduced (all 66 warnings/errors in WatchState.swift are pre-existing).
- No scope creep — only R4 code added, no other changes.
- Existing iOS `didReceiveApplicationContext` handler (line 1269 — receives `complicationLastValidTimestamp` from watch) is a separate data flow (watch→iOS) and is not affected.

**Deviations:** None.

---

## Changelog

### v1.4 (2026-04-06 17:27 CET)
- Recorded Better Stack production snapshot (7d): R4 context send health, R6 `hk_observer_fired` daily counts and `sync_lag` distribution, Step 5.1 completion-path mix and residual `late_task_late_task` volume, second-pass retry/marker telemetry counts, and deferred `pending_content=true` volume. Updated second-pass status from “not yet built” to “telemetry confirms on-device” while leaving TestFlight build number unpinned (supersedes the v1.3 “pending redeploy” expectation for that follow-up). Replaced the rigid R6 “save_age p90 < 300s” next gate with R6.1-aligned `sync_lag` guidance and segmentation notes. Softened second-pass “expected validation” into explicit pass/fail vs on-device/unknown items.

### v1.3 (2026-03-30 22:46 CEST)
- Replaced the obsolete “staged only” Step 5.1 note with two concrete records: build 146 first-pass deployment findings, and the committed second-pass follow-up (`58f706a0f`) that adds canonical late-task markers, bounded deferred-completion retries, widened rescue window, and new lifecycle telemetry. Also recorded that patch 09 has been regenerated from `feature/watch-complication-improvements` and is pending redeploy.

### v1.2 (2026-03-30 13:20 CET)
- Added a staged-not-yet-built implementation record for the post-build-143 background-task completion follow-up in `WatchState.swift`. Logged the terminal-marker design, the reason `hasContentPending` remains the late-task rescue gate, the explicit deferral of watch-state-specific pending-work tracking, and the supporting observability-only staged changes in `ExtensionDelegate.swift` and `TrioWatchApp.swift`.

### v1.1 (2026-03-20 22:10 CET)
- Added build 143 entry: R4 handler upgrade with R5d three-constraint ordering integration (gap detection, forced reload).

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted build 140 (R6) log entry from `complication-freshness-remediation-plan.md` and Step 5/R4 implementation log entry from `complication-freshness-implementation-guide.md`. Added new build 142 entry documenting R4 validation results. Reason: docs reorganization — consolidate alternative delivery channel implementation log entries into a standalone document.
