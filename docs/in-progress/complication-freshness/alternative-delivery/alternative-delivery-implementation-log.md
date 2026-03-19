# Alternative Delivery — Implementation Log

**Version:** 1.0
**Date:** 2026-03-19 11:33 CET

---

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

**Next gate:** Observe 48h `hk_observer_fired` events. Validate: (a) cadence matches CGM interval (~5 min), (b) `save_age` p90 < 300s, (c) events continue during budget-exhaustion windows, (d) dual-delivery dedup behavior matches plan §R6 expectations.

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

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted build 140 (R6) log entry from `complication-freshness-remediation-plan.md` and Step 5/R4 implementation log entry from `complication-freshness-implementation-guide.md`. Added new build 142 entry documenting R4 validation results. Reason: docs reorganization — consolidate alternative delivery channel implementation log entries into a standalone document.
