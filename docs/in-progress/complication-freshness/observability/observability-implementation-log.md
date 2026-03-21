# Observability Hardening — Implementation Log

**Version:** v1.2
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-21 23:58 CET

---

### R5a — Coalescer trigger-source logging (build 133, 2026-03-10)

**Shipped with:** R2a (Step 2). R5a is described in R2a — they are the same code change (adding `source` parameter to `scheduleWatchStateUpdate` with source tags on all 8 call sites).

**Commit:** `4bb1018f3` ("feat: R2a + R3 — coalescer attribution and complication payload allowlist") on `feature/watch-complication-improvements`

**What was done:** Added `source: String = "unknown"` parameter to `scheduleWatchStateUpdate`, along with `coalescerTriggerCount`, `coalescerSources`, `lastEligibleSourceAt`, and `complicationEligibleSources` properties. All 8 call sites tagged with source identifiers (`glucoseUpdate`, `iobUpdate`, `orefDetermination`, `glucoseStored`, `overrideStored`, `tempTargetStored`, `pumpSettings`, `settingsChanged`). Coalescer fire log includes `trigger_count`, `sources`, `last_eligible_at`.

**Validation:** BetterStack confirmed coalescer attribution logging working — trigger/fire events with source tags visible within first hour of deployment.

---

### R5e — BetterStack budget exhaustion alert (build 132, 2026-03-09)

**Shipped with:** R1a + R1b (Step 1).

**Commit:** Alert configured directly in BetterStack UI (no code commit — configuration only).

**What was done:** Created BetterStack alert on query: `budget_exhausted=true AND via=userInfo > 5 in 30 min`. Warning severity. SQL from remediation plan R5e.

---

### R5b — sendMessage latency instrumentation (build 141, 2026-03-15/16)

**Commit:** `44d7a7579` ("fix: R5c attribution with work item; R5b inner-payload comment; R6.1/R5f logging") on `feature/watch-complication-improvements`

**What was done:**

- **iOS side (`AppleWatchManager.swift`):** Added `sendMessage_sent reading_epoch=... send_wall=...` log line after `sendMessage` call (line 806).
- **Watch side (`WatchState.swift`):** Added `didReceiveMessage reading_epoch=... receive_wall=...` log line in `didReceiveMessage` handler (line 462). Reads `readingEpoch` from the **inner** payload (`message[WatchMessageKeys.watchState]`), not the outer sendMessage envelope — verified during review and documented with a code comment.

**Post-review verification (v1.50):** Reviewer requested confirmation that the watch-side R5b log reads epoch from the inner payload. Verified: the R5b block is entered only after extracting `watchStateDict = message[WatchMessageKeys.watchState]`; that is the inner payload matching iPhone's `fullMessage`. Code comment added.

---

### R5c — didReceiveUserInfo decode latency (build 141, 2026-03-15/16)

**Commit:** `44d7a7579` (same commit as R5b/R5f/R6.1)

**What was done:**

Added `userInfo_decoded reading_epoch=... decode_ms=...` logging that measures the time from `didReceiveUserInfo` entry to `saveComplicationSnapshot` completion.

**Attribution design (as implemented after review corrections):** Attribution is threaded with the work, not via shared state. The `fromUserInfo` and `userInfoReceiveTimestamp` parameters are passed through the full chain:

1. `didReceiveUserInfo` sets `lastUserInfoReceiveTimestamp = Date()` and passes it to `scheduleUIUpdate(with:fromUserInfo:true, userInfoReceiveTimestamp:)`
2. `scheduleUIUpdate` captures both values before creating the `DispatchWorkItem`
3. `finalizePendingData(fromUserInfo:, userInfoReceiveTimestamp:)` passes them through
4. `processRawDataForWatchState(_:fromUserInfo:, userInfoReceiveTimestamp:)` passes them through
5. `saveComplicationSnapshot(from:fromUserInfo:, userInfoReceiveTimestamp:)` logs `decode_ms` using only the threaded timestamp (no fallback to instance state) and derives `reading_epoch` from the payload being saved

In the pending-tasks path, `receiveTs` is captured outside the `DispatchWorkItem` at creation time so a second delivery cannot overwrite it before the work runs.

**Post-review corrections (v1.50–v1.51):**

- **v1.50 — R5c (major fix):** Attribution was originally implemented with a shared boolean `userInfoTriggeredThisFinalize` set/cleared by `didReceiveUserInfo` and `didReceiveMessage`. In mixed traffic, the path that last touched the flag could differ from the payload actually being finalized. Fix: replaced with threaded `fromUserInfo` parameter as described above.
- **v1.51 — ChatGPT + Claude follow-up:** (1) Removed the fallback `userInfoReceiveTimestamp ?? lastUserInfoReceiveTimestamp` so attribution uses only the threaded timestamp. (2) Removed the unused `lastUserInfoReadingEpoch` property (dead state). Both reviewers confirmed the threading shape.

---

### R5f — WidgetKit timeline and snapshot validation logging (build 141, 2026-03-15/16)

**Commit:** `44d7a7579` (same commit as R5b/R5c/R6.1)

**What was done:**

Added two structured log events in `TrioComplicationDataStore.swift` and their call sites in `TrioWatchComplication.swift`:

1. **Timeline path — `event=complication_get_timeline_called`:** Emitted from `getTimeline` (line 220 in `TrioWatchComplication.swift`). Fields include `get_timeline_at_epoch_seconds` and `data_age_seconds` (age of the snapshot actually used to build the timeline entries returned to WidgetKit).

2. **Snapshot path — `event=complication_get_snapshot_called`:** Emitted from `getSnapshot` (line 156 in `TrioWatchComplication.swift`). Fields include `get_snapshot_at_epoch_seconds` and `data_age_seconds` (age of the snapshot actually used to produce the entry).

Both events are complication-extension / WidgetKit only (not HealthKit observer events). The `data_age_seconds` field is computed from the snapshot actually used to build the WidgetKit entry on that path. A chart from `getTimeline` only is timeline-recency; for actual visible recency, both events must be included.

---

### R5d — Sleep-gap forced reload (build 143, 2026-03-19/20)

**Commits:** `eea6d5ba3` (build 143 patch-09 changes), `b26136f0e` (red-team review fixes) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick eea6d5ba3,b26136f0e,f5b30820a`
**Build:** 143 (v0.6.0) — deployed to TestFlight 2026-03-19 ~21:09 UTC

**What was done:**

1. **Rename + persist `lastDataReceivedAt`:** Removed `private var lastUserInfoReceivedAt: Date?` (in-memory). Added computed property `lastDataReceivedAt` backed by App Group UserDefaults (`double(forKey: "lastDataReceivedAt")`). Survives app restart and WCSession reconnection.

2. **Three-constraint ordering in `didReceiveUserInfo`:** In the main-queue block: (a) compute gap BEFORE updating timestamp, (b) `saveComplicationSnapshot`, (c) update `lastDataReceivedAt = Date()`, (d) if `gap > 600` → log `sleep_gap_detected` and call `forceWidgetReloadIfStale(receivedGap:)`.

3. **`forceWidgetReloadIfStale(receivedGap:)`:** New private method with: 5-minute rate limiter via persisted `lastWidgetReloadAt`, snapshot diagnostic read with `snapshotReadMs` timing, `WidgetCenter.shared.reloadTimelines(ofKind:)` dispatch, structured logging (`forced_widget_reload_after_gap` or `forced_reload_skipped_rate_limit`).

4. **`didReceiveApplicationContext` upgrade:** Same three-constraint ordering as `didReceiveUserInfo`. Logs `sleep_gap_detected_context` when gap > 600s.

**Red-team review fixes (applied in `b26136f0e`):**

- **RT-1 (blocker):** Removed stale-backlog guard from `forceWidgetReloadIfStale` that inverted the design by suppressing reload when snapshot was fresh.
- **RT-2 (ordering):** Added synchronous `saveComplicationSnapshot` in `didReceiveUserInfo` sleep-gap path so `forceWidgetReloadIfStale` reads fresh App Group data.
- **RT-4 (crash):** Safe-formatted all `Int(gap)` / `Int(snapshotAge)` to prevent `Int(.infinity)` crash when `lastDataReceivedAt` is nil on first-ever receive.
- **RT-5 (logging):** Use `fromUserInfo:false` for pre-branch save to avoid double R5c logging.

**Design:** See [observability-design.md §R5d](observability-design.md#r5d--sleep-gap-forced-reload) for the full spec.

---

### 4G — Unified `Transferred` log for `updateApplicationContext` (build 144, 2026-03-21)

**Commit:** `8ab401dfc` on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick 8ab401dfc`

**What was done:** Added a `📤 Transferred new WatchState snapshot via=updateApplicationContext reading_date_epoch_seconds=... userinfo_budget_exhausted=... queue_depth=...` log line after `session.updateApplicationContext(ctx)` succeeds. This emits the `📤 Transferred` sentence shape that Better Stack's `transfer_via` extraction rule matches, making R4 transfers visible in the "Transfers / bucket" dashboard.

Uses `userinfo_budget_exhausted` (not `budget_exhausted`) because `updateApplicationContext` doesn't consume the complication userInfo budget — the field is contextual, not a constraint.

**File:** `AppleWatchManager.swift`

---

### 4H — `queue_depth` in `complication_budget_check` (build 144, 2026-03-21)

**Commit:** `8ab401dfc` (same commit as 4G)
**Patch:** `09-watch-complication-improvements.patch`

**What was done:** Appended `queue_depth=\(session.outstandingUserInfoTransfers.count)` to the existing `complication_budget_check` debug log in `sendDataToWatch`. Makes queue depth visible every cycle — prerequisite for dead-zone stall alerting. Field name `queue_depth` is consistent with existing `📤 Transferred` and `context_attempted` log lines.

**File:** `AppleWatchManager.swift`

---

### 4I — Skip retry scheduling when snapshot is fresh (build 144, 2026-03-21)

**Commit:** `8ab401dfc` (same commit as 4G/4H)
**Patch:** `09-watch-complication-improvements.patch`

**What was done:** In `TrioComplicationDataStore.coalescedReloadOnMain`, added a freshness check before `scheduleRetryAfterReloadOnMain`: if `Date().timeIntervalSince(snapshot.readingDate) < freshnessThreshold` (60s), skip the retry. The `freshnessThreshold` constant keeps the condition and log message in sync. If `latestSnapshot()` returns nil, falls through to schedule the retry (correct behavior for no-data-yet case).

Reduces WidgetKit budget pressure by eliminating unnecessary retries when the complication just rendered fresh data.

**File:** `TrioComplicationDataStore.swift`

---

### Build 143 +48h gate metrics (recorded 2026-03-21 ~22:40 UTC)

Full observation window: 49.5h since build 143 deployment (~21:09 UTC 2026-03-19).

| Metric | n | p50 | p90 | p95 | max | Threshold | Result |
|--------|---|-----|-----|-----|-----|-----------|--------|
| `save_age` | 445 | 104s | 324s | 518s | 14,173s | p90 < 300s | Marginal fail (+8%) |
| `reload_age` | 537 | 208s | 608s | 647s | 14,173s | p90 < 600s | Marginal fail (+1.3%) |
| `receive_lag` | 194 | 0.09s | 0.77s | 2.3s | 128s | p50<10s, p90<30s | **Pass** |
| `data_age` at getTimeline | 230 | 322s | 761s | 1,313s | 14,296s | p90 < 600s | Fail (+27%) |

**Assessment:** Transport layer healthy. Marginal failures driven by WidgetKit scheduling latency (p50=244s, p90=504s) — outside our control. The 14,000s+ outliers are overnight sleep gaps. `receive_lag` confirms sub-second phone-to-watch delivery via `sendMessage`.

### R5d post-sleep-gap recovery (validated)

8 `sleep_gap_detected_context` events in the 49.5h window (all via `didReceiveApplicationContext` — no `didReceiveUserInfo` gaps). 7 `sleep_gap_reload_firing` events (1 `stale_backlog` on first receive). No rate-limited skips.

Post-gap `data_age_seconds` at first `complication_get_timeline_called`:

| Gap time | Gap (s) | data_age (s) | WidgetKit latency (s) |
|----------|---------|--------------|----------------------|
| Mar 20 20:53 | 646 | 141 | 0 |
| Mar 21 01:41 | 730 | 269 | 260 |
| Mar 21 18:08 | 701 | 203 | 128 |
| Mar 21 18:54 | 771 | 194 | 85 |

**Result:** All post-gap data ages well under 600s (p90 ~248s). R5d forced reload mechanism is working — complication recovers with fresh data after sleep gaps.

**Note:** All gaps detected via `didReceiveApplicationContext`, none via `didReceiveUserInfo`. This is expected: during sleep, complication budget is exhausted, so the phone falls back to `updateApplicationContext`. The `didReceiveApplicationContext` path correctly triggers both gap detection and forced reload (since build 143).

---

## Changelog

### v1.2 (2026-03-22 00:10 CET)
- Added 4G (unified Transferred log for updateApplicationContext), 4H (queue_depth in complication_budget_check), 4I (skip retry when snapshot fresh) — all build 144.
- Added build 143 +48h gate metrics table (49.5h window). Transport healthy; marginal fails driven by WidgetKit latency.
- Added R5d post-sleep-gap recovery validation: 4 correlated gap→getTimeline pairs, all data_age < 270s. Forced reload mechanism confirmed working.

### v1.1 (2026-03-20 22:10 CET)
- R5d section: replaced "NOT YET IMPLEMENTED" with full implementation log for build 143. Includes rename/persist, three-constraint ordering, `forceWidgetReloadIfStale`, `didReceiveApplicationContext` upgrade, and red-team review fixes (RT-1/2/4/5).

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Reconstructed from commits on `feature/watch-complication-improvements`, remediation plan changelog v1.50–v1.51, and code inspection during docs reorganization.
