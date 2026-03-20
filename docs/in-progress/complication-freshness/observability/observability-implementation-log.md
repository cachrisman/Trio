# Observability Hardening — Implementation Log

**Version:** v1.1
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-20 22:10 CET

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

## Changelog

### v1.1 (2026-03-20 22:10 CET)
- R5d section: replaced "NOT YET IMPLEMENTED" with full implementation log for build 143. Includes rename/persist, three-constraint ordering, `forceWidgetReloadIfStale`, `didReceiveApplicationContext` upgrade, and red-team review fixes (RT-1/2/4/5).

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Reconstructed from commits on `feature/watch-complication-improvements`, remediation plan changelog v1.50–v1.51, and code inspection during docs reorganization.
