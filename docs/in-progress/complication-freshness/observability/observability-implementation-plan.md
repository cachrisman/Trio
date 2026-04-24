# Observability Hardening — Implementation Plan (Step 6)

**Version:** v1.2
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-04-08 22:09 CET
**Status:** COMPLETED — All R5 items shipped (R5b/R5c/R5f build 141; R5d build 143). Build 144 additions **4G/4H/4I** (unified R4 transfer log, `queue_depth` in budget check, fresh-snapshot retry skip) are recorded in [observability-implementation-log.md](observability-implementation-log.md), not in the Step 6 checklist below.

Design: [observability-design.md](observability-design.md)
Implementation log: [observability-implementation-log.md](observability-implementation-log.md)

---

### Step 6 — PR: R5 observability hardening (opportunistic, parallel-safe after Step 1)

**R5b:** Add `sendMessage` wall-clock timestamp on iOS send. On the watch, read `readingEpoch` from the **inner** payload (`message[WatchMessageKeys.watchState]`), not the outer envelope — see [observability-design.md §R5b](observability-design.md) "As implemented (post-review)" and the code comment in `WatchState.swift`.

**R5c:** Add `decode_ms` to `didReceiveUserInfo` (receive → `saveComplicationSnapshot` return). **Attribution must be threaded with the work, not shared state:** pass `fromUserInfo` and `userInfoReceiveTimestamp` through `scheduleUIUpdate` → `finalizePendingData` → `processRawDataForWatchState` → `saveComplicationSnapshot`. In `saveComplicationSnapshot`, log `reading_epoch` from the payload being saved and `decode_ms` from the threaded timestamp only (no fallback to instance state). In the pending-tasks path, capture the receive timestamp outside the `DispatchWorkItem` at creation time. See [observability-design.md §R5c](observability-design.md) "As implemented (post-review)" and [remediation plan changelog v1.51](../archive/remediation-plan-changelog-full.md) (ChatGPT + Claude follow-up).

**R5d — Sleep-gap forced reload (`WatchState.swift`):**
- Rename `lastUserInfoReceivedAt` → `lastDataReceivedAt`; persist to App Group `UserDefaults`
- `forceWidgetReloadIfStale(receivedGap: TimeInterval)` — rate limiter (5 min), diagnostic snapshot read, gap-relative stale detection (`snapshotAge > receivedGap - 60`)
- Kind string: use `TrioComplicationDataStore.complicationKind`
- `latestSnapshot()` confirmed main-safe — call as-is; move to background queue only if `snapshot_read_ms > 20ms` in production
- Full pseudocode in [observability-design.md §R5d](observability-design.md)

**R5f — Timeline validation logging (`TrioWatchComplication.swift`):**
```swift
// After entries array is built in getTimeline:
if let firstEntry = entries.first {
    debug(.complication, "📅 timeline_built entry_count=\(entries.count) reading_epoch=\(Int(firstEntry.readingDate.timeIntervalSince1970)) snapshot_age=\(Int(Date().timeIntervalSince(firstEntry.readingDate)))s")
}
```
This validates that WidgetKit is actually advancing the timeline, not just that the App Group store is fresh.

**R5f — WidgetKit entry-path events (R6.1 logging enhancement):** Both events are complication-extension / WidgetKit only (not HealthKit observer events). The complication can show fresh data from either `getTimeline` or `getSnapshot`; getTimeline-only logging does **not** reconstruct full visible recency.

**A. Timeline path — `event=complication_get_timeline_called`:**

- **`get_timeline_at_epoch_seconds`** — Unix epoch when getTimeline was invoked. Capture at log time (e.g. `Int(Date().timeIntervalSince1970)` at the start of getTimeline or immediately before the event is logged).
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to build the timeline. Compute **after** loading the snapshot that will be used to build the timeline: `max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))`. Use the snapshot that is passed to the timeline entries, not the most recent saved snapshot from another path. If there is no valid reading date (e.g. `.distantPast` or placeholder), emit the documented sentinel (e.g. `-1`).

**B. Snapshot path — `event=complication_get_snapshot_called`:**

- **`get_snapshot_at_epoch_seconds`** — Unix epoch when getSnapshot was invoked. Capture at log time.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to produce the snapshot entry. Compute **after** loading the snapshot that will be used to build the entry returned to WidgetKit on this path; use the same sentinel for invalid/placeholder reading dates.

In both paths, `data_age_seconds` must be from the snapshot **actually used to build the WidgetKit entry on that path** — not from another save/reload path or "latest known reading" in the abstract.

**Observability framing:** *Timeline-generation observability* = getTimeline events; *snapshot-generation observability* = getSnapshot events; *visible recency* = both paths matter. A chart from getTimeline only = **timeline-recency / timeline-refresh recency**; for actual **visible recency**, include getSnapshot in the analysis.

**Implementation note (getTimeline):** Compute both values after the timeline snapshot is loaded; pass them into the existing log call so the event carries the data age of the snapshot actually returned to WidgetKit.

**Implementation guidance (getSnapshot):** In `getSnapshot`, emit `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` captured at log time and `data_age_seconds` computed after loading the snapshot actually used to build the snapshot entry. Use the documented sentinel for invalid/placeholder reading dates. This is observability only and does not change WidgetKit behavior.

**Scope boundary:** R5f enhancement does not change reload logic, dedup logic, HealthKit behavior, trend/delta derivation, or WidgetKit scheduling; only improves observability of what WidgetKit rendered or prepared to render.

**Validation / query:** Timeline path fields support timeline-recency and timeline-refresh sawtooth reconstruction. A sawtooth built only from getTimeline is **not** a full visible-recency sawtooth — include getSnapshot events to better reconcile with cases where the face shows "NOW" without a logged getTimeline. Both events together support visible-recency analysis in Better Stack Explore. Standard metric-bucket dashboards may not support as-of / point-in-time reconstruction natively.

> **Post-review corrections (2026-03-15):** After implementation of R5b/R5c, a review identified (1) R5c attribution risk — a shared boolean could be overwritten before finalize ran. Fix: pass `fromUserInfo` and (for the userInfo path) `userInfoReceiveTimestamp` through the chain; capture the timestamp outside the work item in the pending-tasks path; in `saveComplicationSnapshot`, use only the threaded timestamp for `decode_ms` and derive `reading_epoch` from the payload being saved; no fallback to instance state; remove dead `lastUserInfoReadingEpoch`. (2) R5b verification — confirm watch-side epoch is read from the inner payload. Verified and documented in code. Follow-up reviews (ChatGPT, Claude) confirmed the shape and requested removal of the fallback and dead state. See [remediation plan changelog v1.50–v1.51](../archive/remediation-plan-changelog-full.md) and [observability-design.md §R5b/§R5c](observability-design.md) "As implemented (post-review)."

> ## 🛑 STOP — Code Review + Build/Deploy *(historical — R5d shipped build 143)*
> 1. **Code review** this PR — verify `forceWidgetReloadIfStale(receivedGap:)` signature matches all call sites, `lastDataReceivedAt` is updated in both `didReceiveUserInfo` and `didReceiveApplicationContext` (if Step 5/R4 has shipped; if not, verify only `didReceiveUserInfo` — the `didReceiveApplicationContext` update is part of Step 5), and rename is complete (no remaining `lastUserInfoReceivedAt` references)
> 2. **Build and deploy** to device
> 3. **Confirm in BetterStack:** `timeline_built snapshot_age` p90 < 600s after sleep gaps; `reload_with_stale_snapshot` events are rare

---

**Note:** Follow-on work **4G/4H/4I** (build 144) is documented in [observability-implementation-log.md](observability-implementation-log.md) and [build-144-plan.md](../build-144-plan.md).

---

## Changelog

### v1.2 (2026-04-08 22:09 CET)
- Status line: noted build 144 observability items (4G/4H/4I) with pointer to implementation log. Marked STOP block as historical; added cross-link to `build-144-plan.md`.
- Reason: avoid implying R5 is the latest observability work; align with epic README and problem-and-strategy.

### v1.1 (2026-03-21 15:17 CET)
- Status updated from IN PROGRESS to COMPLETED. R5d shipped in build 143.
- Reason: all R5 implementation tasks are complete and validated in production.

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted Step 6 (R5 observability hardening implementation) from complication-freshness-implementation-guide.md.
