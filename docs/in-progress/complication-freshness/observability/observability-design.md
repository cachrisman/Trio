# Observability Hardening — Design (R5)

**Version:** v1.0
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 11:33 CET
**Status:** IN PROGRESS — R5a shipped (build 133 with R2a), R5e shipped (build 132 with R1), R5b/R5c/R5f shipped (build 141). Only R5d (sleep-gap forced reload) remains pending.

See [problem-and-strategy.md](../problem-and-strategy.md) for overall context.
Implementation plan: [observability-implementation-plan.md](observability-implementation-plan.md)
Implementation log: [observability-implementation-log.md](observability-implementation-log.md)

---

## R5 — Observability Hardening

**Priority:** P1 (parallel — ship opportunistically) | **Effort:** 2–3 hrs total

### R5a — Coalescer trigger-source logging

Described in R2a — **prerequisite for R2b**. Ships as the first step in the R2 series.

### R5b — sendMessage latency instrumentation

Cursor confirmed: no wall-clock timestamps on either end of the `sendMessage` path.

```swift
// AppleWatchManager.swift, sendMessage branch:
debug(.watchManager, "📨 sendMessage_sent reading_epoch=\(readingEpoch) send_wall=\(Date().timeIntervalSince1970)")

// WatchState.swift (watch side), didReceiveMessage (~line 230):
// extractedEpoch parsed from message using WatchMessageKeys.readingEpoch (R1a):
debug(.watchManager, "📬 didReceiveMessage reading_epoch=\(extractedEpoch) receive_wall=\(Date().timeIntervalSince1970)")
```

**As implemented (post-review):** The send payload is `[WatchMessageKeys.watchState: fullMessage]`; `fullMessage` is the inner watch-state dict (from `watchStateToDictionary`) and contains `readingEpoch`. On the watch, we only enter the R5b log block after `if let watchStateDict = message[WatchMessageKeys.watchState] as? [String: Any], ...`, so `watchStateDict` is that inner payload. Reading `watchStateDict[WatchMessageKeys.readingEpoch]` is therefore correct for end-to-end timing. A code comment in `WatchState.swift` documents this so future changes do not read epoch from the wrong level.

### R5c — didReceiveUserInfo decode latency

```swift
// WatchState.swift, didReceiveUserInfo (~line 286):
let receiveTimestamp = Date()
// ... existing processing ...
// After saveComplicationSnapshot returns:
let decodeMs = Int(Date().timeIntervalSince(receiveTimestamp) * 1000)
debug(.watchManager, "⏱️ userInfo_decoded reading_epoch=\(readingEpoch) decode_ms=\(decodeMs)")
```

**As implemented (post-review):** Attribution must not depend on shared mutable state, because both the userInfo path and the sendMessage path use the same `pendingData` / `finalizePendingData` machinery and overlapping userInfo deliveries can overwrite instance state before a save runs. Attribution is **threaded with the work** in two ways: (1) **Path flag:** `scheduleUIUpdate(with:fromUserInfo:)` and `finalizePendingData(fromUserInfo:)` take a `fromUserInfo` parameter; the userInfo path passes `true`, the sendMessage path passes `false`; the debounced work item captures it and passes it through so the run that processes the payload decides whether to log `userInfo_decoded`. (2) **Timestamp and epoch:** The receive timestamp is passed as `userInfoReceiveTimestamp` through `scheduleUIUpdate` → `finalizePendingData` → `processRawDataForWatchState` → `saveComplicationSnapshot`. In the pending-tasks path, `receiveTs = lastUserInfoReceiveTimestamp` is captured **outside** the `DispatchWorkItem` at creation time so a second delivery cannot overwrite it before the work runs. In `saveComplicationSnapshot`, `reading_epoch` is taken from the payload being saved (`Int(readingDate.timeIntervalSince1970)` from the same `message` that produced `readingDate`), not from instance state. **No fallback:** When `fromUserInfo` is true, only the threaded `userInfoReceiveTimestamp` is used for `decode_ms`; there is no fallback to `lastUserInfoReceiveTimestamp`, so attribution stays unambiguous if a call path ever omitted the parameter. The former `lastUserInfoReadingEpoch` property was removed as dead state after the log was switched to payload-derived epoch. (Post-review follow-up: ChatGPT suggested removing the fallback and dead state; Claude confirmed the threading shape and noted the fallback had already been removed.)

### R5d — Sleep-gap forced reload

> ✅ **`latestSnapshot()` confirmed safe on main (Cursor Round 2 — Prompt R5d-snapshot).** The method performs synchronous file I/O (~200 bytes, JSON decode) but is already used from multiple threads in production and is safe to call on main at this payload size. `snapshot_read_ms` is logged on every reload call — if it ever exceeds 20ms in production, move the read to a background queue. No pre-implementation gating required.

`lastUserInfoReceivedAt: Date?` already exists at line ~102 (in-memory). Cursor confirmed it is **not persisted** — process restarts reset it to `nil`, which would produce a false infinite-gap on first receive after restart.

**Fix: persist to App Group UserDefaults and rename to `lastDataReceivedAt`:**

The property is renamed from `lastUserInfoReceivedAt` to `lastDataReceivedAt` — it must be updated by both the `didReceiveUserInfo` and `didReceiveApplicationContext` paths. Using the name `lastUserInfoReceivedAt` in the applicationContext handler is semantically wrong and easy to miss.

```swift
// Replace the in-memory property with a computed property backed by App Group UserDefaults.
// Renamed from lastUserInfoReceivedAt → lastDataReceivedAt — updated by BOTH receive paths.
private var lastDataReceivedAt: Date? {
    get {
        let epoch = UserDefaults(suiteName: APP_GROUP_SUITE)?.double(forKey: "lastDataReceivedAt") ?? 0
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
    set {
        UserDefaults(suiteName: APP_GROUP_SUITE)?.set(
            newValue?.timeIntervalSince1970 ?? 0,
            forKey: "lastDataReceivedAt"
        )
    }
}
```

Sleep-gap detection in `didReceiveUserInfo` — snapshot gap first, then save, update timestamp, then reload:

```swift
// ORDERING IS LOAD-BEARING — three constraints must all be satisfied:
// (1) gap must be computed BEFORE updating lastDataReceivedAt, or it always reads ~0ms
// (2) save must happen BEFORE forceWidgetReloadIfStale(receivedGap:), so WidgetKit reads fresh data
// (3) lastDataReceivedAt must be updated BEFORE the gap check fires the reload,
//     so subsequent deliveries don't also see a large gap
let gap = lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
self.saveComplicationSnapshot(from: userInfo)
self.lastDataReceivedAt = Date()
if gap > 600 {
    Task { await WatchLogger.shared.log("💤 sleep_gap_detected gap_seconds=\(Int(gap))") }
    forceWidgetReloadIfStale(receivedGap: gap)
}
```

Add the same ordering to `didReceiveApplicationContext` (R4). During budget exhaustion, `didReceiveUserInfo` may not fire at all, so the applicationContext path needs its own gap detection — and **must update `lastDataReceivedAt`** so subsequent deliveries don't see an infinitely growing gap:

```swift
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { await WatchLogger.shared.log("📦 didReceiveApplicationContext") }
    guard let payload = applicationContext[WatchMessageKeys.watchState] as? [String: Any] else { return }
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Same three-constraint ordering as didReceiveUserInfo:
        // (1) snapshot gap BEFORE updating lastDataReceivedAt
        // (2) save BEFORE reload so WidgetKit reads fresh data
        // (3) update lastDataReceivedAt so subsequent context deliveries don't re-trigger
        let gap = self.lastDataReceivedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        self.saveComplicationSnapshot(from: payload)
        self.lastDataReceivedAt = Date()
        if gap > 600 {
            Task { await WatchLogger.shared.log("💤 sleep_gap_detected_context gap_seconds=\(Int(gap))") }
            self.forceWidgetReloadIfStale(receivedGap: gap)
        }
    }
}
```

**WidgetKit reload helper** — rate-limited, with diagnostic snapshot read:

```swift
// In WatchState.swift (watch app extension):
// receivedGap: the gap that triggered this call — used to detect stale backlog slippage
// (snapshotAge ≈ receivedGap means we reloaded with data that predates the gap itself).
private func forceWidgetReloadIfStale(receivedGap: TimeInterval) {
    // Rate limiter: don't reload more than once per 5 minutes.
    let minReloadInterval: TimeInterval = 300
    let lastReloadKey = "lastWidgetReloadAt"
    let lastReloadEpoch = UserDefaults(suiteName: APP_GROUP_SUITE)?.double(forKey: lastReloadKey) ?? 0
    let timeSinceLastReload = Date().timeIntervalSince1970 - lastReloadEpoch
    guard timeSinceLastReload > minReloadInterval else {
        debug(.watchManager, "🔄 widgetCenter_reload_rate_limited time_since_last=\(Int(timeSinceLastReload))s")
        return
    }

    // No snapshot age guard. Callers save before calling this function, so latestSnapshot()
    // always reflects just-saved data — a post-save age guard reads ~fresh and blocks the
    // reload in precisely the scenario this function is designed for (first fresh reading
    // after a sleep gap). The stale-backlog concern that motivated the guard is addressed
    // upstream by R1b's queue draining. The rate limiter above is the correct backstop
    // against reload storms.

    // Read snapshot for diagnostics BEFORE triggering reload — measures the actual I/O
    // latency on this call path, not a post-reload cold read.
    let snapshotReadStart = Date()
    let reloadSnapshot = TrioComplicationDataStore.shared.latestSnapshot()
    let snapshotReadMs = Int(Date().timeIntervalSince(snapshotReadStart) * 1000)
    let reloadSnapshotEpoch = reloadSnapshot.map { Int($0.readingDate.timeIntervalSince1970) } ?? -1
    let snapshotAge = reloadSnapshot.map { Date().timeIntervalSince($0.readingDate) } ?? .infinity
    // snapshotReadMs expected <5ms (confirmed ~200 bytes, Cursor Round 2). If >20ms, move to background queue.

    // Stale-backlog detection: the signature is snapshotAge ≈ receivedGap, meaning the snapshot
    // barely advanced relative to the gap that triggered this reload — the first delivery after
    // reconnect was old backlog, not fresh data. A fixed threshold (e.g. 600s) would misclassify
    // legitimate sensor warmup gaps (>10 min without a reading). Using gap - 60 as the threshold
    // only flags cases where the snapshot is nearly as old as the gap itself.
    let isStaleBacklog = snapshotAge > (receivedGap - 60)
    if isStaleBacklog {
        debug(.watchManager, "⚠️ reload_with_stale_snapshot reading_epoch=\(reloadSnapshotEpoch) snapshot_age=\(Int(snapshotAge))s received_gap=\(Int(receivedGap))s snapshot_read_ms=\(snapshotReadMs) — reload still firing; rate limiter prevents storm")
    } else {
        debug(.watchManager, "🔄 widgetCenter_reload_triggered reading_epoch=\(reloadSnapshotEpoch) snapshot_age=\(Int(snapshotAge))s received_gap=\(Int(receivedGap))s snapshot_read_ms=\(snapshotReadMs)")
    }

    // WidgetCenter is the correct API for WidgetKit-based complications.
    // CLKComplicationServer is for legacy ClockKit and will not work here.
    // Kind string confirmed by Cursor Round 2: TrioComplicationDataStore.complicationKind = "TrioWatchComplication"
    UserDefaults(suiteName: APP_GROUP_SUITE)?.set(Date().timeIntervalSince1970, forKey: lastReloadKey)
    WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)
}
```

> **Why no snapshot age guard:** Callers save before calling this function, so `latestSnapshot().readingDate` always reflects just-saved data — a `> 300s` guard would always block the reload in the primary scenario (fresh reading arriving after a sleep gap). R1b's queue draining eliminates stale-backlog deliveries upstream. The 5-minute rate limiter is the correct storm guard. The `reload_with_stale_snapshot` warning log catches the rare reconnect-ordering edge where a stale userInfo slips through before R1b drains the queue.

> **`latestSnapshot()` thread safety (confirmed):** Safe to call on main — ~200 bytes, already multi-thread-safe in production. No background queue needed. If `snapshot_read_ms` ever logs >20ms in production, move the read to a background queue.

> **Process-restart behaviour:** With App Group persistence, the gap survives extension restarts. The rate limiter's `lastWidgetReloadAt` also persists, so a fresh restart won't cause a reload storm.

### R5e — BetterStack budget exhaustion alert

```sql
SELECT count() AS exhausted_count
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 30 MINUTE
  AND JSONExtract(raw,'message','Nullable(String)') LIKE '%budget_exhausted=true%'
  AND JSONExtract(raw,'message','Nullable(String)') LIKE '%via=userInfo%'
  AND JSONExtract(raw,'platform','Nullable(String)') = 'ios'
HAVING exhausted_count > 5
```

Set severity: **Warning** — `transferUserInfo` fallback still delivers data, just with latency.

### R5f — WidgetKit timeline and snapshot validation logging

The complication can render fresh data from **both** WidgetKit entry paths: `getTimeline` and `getSnapshot`. Both load from the App Group snapshot via `latestSnapshot()`. A chart based only on `complication_get_timeline_called` is **not** a complete visible-recency chart — the face can show fresh data from `getSnapshot` without any `getTimeline` call. R5f specifies observability for both entry points (complication extension / WidgetKit only; not HealthKit observer events).

Add to `getTimeline(in:completion:)` in `Trio Watch Complication/TrioWatchComplication.swift` after building entries (~line 229):

```swift
// R5f: timeline_entry_epoch — validates WidgetKit is picking up fresh App Group data.
// Confirmed by Cursor Round 2: TrioWatchComplicationEntry.readingDate is the CGM reading
// timestamp; date is the WidgetKit display time (distinct). All 30 entries share the same
// readingDate but have different date values (1 per minute).
if let firstEntry = entries.first {
    debug(.complication, "📅 timeline_built entry_count=\(entries.count) reading_epoch=\(Int(firstEntry.readingDate.timeIntervalSince1970)) snapshot_age=\(Int(Date().timeIntervalSince(firstEntry.readingDate)))s")
}
```

This gives `reading_epoch` and `snapshot_age` at timeline-build time. If `save_age` is fresh but `snapshot_age` here is stale, WidgetKit is not picking up the App Group writes — indicates the complication kind string is wrong or the App Group container is mismatched.

**WidgetKit entry-path events (R6.1 logging enhancement):**

**A. Timeline path — `event=complication_get_timeline_called`** (emitted when `getTimeline` is invoked):

- **`get_timeline_at_epoch_seconds`** — Unix epoch seconds when `getTimeline` was invoked or when the event is logged. Intended computation: `Int(Date().timeIntervalSince1970)` at the start of `getTimeline` or immediately before the event is logged.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to build the timeline. Intended computation: after loading the snapshot that will be returned to WidgetKit for this timeline, `max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))`. If there is no valid reading date (e.g. placeholder or fallback), use a sentinel such as `-1`. This must be based on the snapshot actually returned to WidgetKit for that timeline, not on the most recent saved snapshot from some other code path.

**B. Snapshot path — `event=complication_get_snapshot_called`** (emitted when `getSnapshot` is invoked):

- **`get_snapshot_at_epoch_seconds`** — Unix epoch seconds when `getSnapshot` was invoked or when the event is logged.
- **`data_age_seconds`** — Age in seconds of the snapshot actually used to produce the snapshot entry. Compute from the snapshot loaded and used to build the entry returned to WidgetKit on this path. Use the same sentinel (e.g. `-1`) when there is no valid reading date.

In both A and B, `data_age_seconds` must be computed from the snapshot **actually used to build the WidgetKit entry returned on that path** — not from some other save/reload path, and not from "latest known reading" in the abstract.

**Observability framing:**

- **Timeline-generation observability** — driven by `event=complication_get_timeline_called`; measures when timelines are built and with what data age.
- **Snapshot-generation observability** — driven by `event=complication_get_snapshot_called`; measures when snapshots are produced and with what data age.
- **Visible recency** — to approximate what the user actually saw, **both** paths matter. getTimeline logging alone does **not** reconstruct all visible refreshes; getSnapshot can show fresh data without any getTimeline call. getTimeline logging is still useful and should be kept for timeline-refresh analysis.

**Rationale:** These events and fields make timeline and snapshot generation directly queryable and support better reconstruction of visible recency in Better Stack Explore when both events are used. They avoid inferring visibility solely from `complication_save_age` or reload events.

**Scope boundary:** This R5f enhancement does not change reload logic, dedup logic, HealthKit behavior, trend/delta derivation, or WidgetKit scheduling. It only improves observability of what WidgetKit rendered or prepared to render on each entry path.

**Better Stack / sawtooth:** A sawtooth built only from `complication_get_timeline_called` is a **timeline-refresh sawtooth**, not a full visible-recency sawtooth. To better reconcile charts with cases where the face shows "NOW" without a logged getTimeline, snapshot logging is also needed. Better Stack Explore can use both events to better understand actual visible freshness. This may still not translate cleanly to standard metric-bucket dashboards because of as-of / point-in-time reconstruction limits.

**Chart naming / interpretation:** A chart based only on `complication_get_timeline_called` should be interpreted as **timeline-recency** or **timeline-refresh recency**. If the goal is actual **visible recency**, include `complication_get_snapshot_called` in the analysis as well.

---

## Changelog

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Extracted R5 (Observability Hardening) design content from complication-freshness-remediation-plan.md.
