# Watch complication "NOW" vs getTimeline logging investigation

**Date:** 2026-03-15  
**Context:** Trio watch complication sometimes shows "NOW" (< 1 minute old data) after returning from the Watch app foreground, but the Better Stack sawtooth chart (built from `event=complication_get_timeline_called` log events) never shows drops below ~4 minutes.

This document captures where reload is triggered, where the complication reads its data, and why "NOW" can appear without a corresponding `getTimeline` log.

---

## 1. Does the Watch app call reloadTimelines after receiving fresh data?

**Yes.** The only place that calls WidgetKit reload is **`TrioComplicationDataStore.reloadTimeline()`**, which invokes `WidgetCenter.shared.reloadTimelines(ofKind:)` (watchOS 10+) or `reloadAllTimelines()`. There are **no** uses of `CLKComplicationServer` or `reloadComplicationDescriptors` in the codebase; the app is WidgetKit-only.

### Where `reloadTimeline()` is triggered

- **Save with triggerReload:** `saveOnMain(..., triggerReload: true)` → `coalescedReloadOnMain` → `reloadTimeline()`. Default is `triggerReload: true`, with 30s debounce.
- **Force reload:** `forceReload()` → `forceReloadOnMain()` → `reloadTimeline()`.

### Call sites

1. **WatchConnectivity receive (message)**  
   `didReceiveMessage` → `processWatchMessage` → `scheduleUIUpdate(with: watchStateData)` → debounce → `finalizePendingData()` → `processRawDataForWatchState` → **`TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)`** (triggerReload is default true) → coalesced reload → **`reloadTimeline()`**.

2. **WatchConnectivity receive (userInfo)**  
   `didReceiveUserInfo` → either:
   - **No pending BG tasks:** `scheduleUIUpdate(with: payload)` → same debounce → `finalizePendingData()` → `processRawDataForWatchState` → **`save(snapshot, minInterval: 5)`** → **`reloadTimeline()`**.
   - **Pending tasks:** payload merged, 0.3s quiet window → `finalizePendingData()` → same `processRawDataForWatchState` → **`save(...)`** → **`reloadTimeline()`**.

3. **App foreground**  
   **No.** `TrioWatchApp` only reacts to `scenePhase == .active` for `WatchErrorReporter` and `WatchLogger`; it does **not** call any complication reload or `forceComplicationUpdate()` when returning to foreground.

4. **Background refresh**  
   `handleBackgroundTasks` (e.g. `WKApplicationRefreshBackgroundTask`) → after 2s delay → **`forceComplicationUpdate()`** → **`save(..., triggerReload: false)` + `forceReload(scheduleRetry: false)`** → **`reloadTimeline()`**.

5. **Manual / debug**  
   `ComplicationDebugView`: `forceReload(scheduleRetry: false)` and `save(..., triggerReload: true, minInterval: 5)`.

So: **reload is triggered on Watch when fresh data is received via message/userInfo (after save) and on background refresh, but not on app foreground.**

---

## 2. What does the complication actually render when returning to the clock face?

**Entry point:** `TrioWatchComplicationProvider` in **`Trio Watch Complication/TrioWatchComplication.swift`** (TimelineProvider).

**Data source for both snapshot and timeline:**

- **`getSnapshot(in:context:completion:)`** (lines 144–149): if `context.isPreview` → placeholder; else → **`loadLatestEntry()`**.
- **`getTimeline(in:context:completion:)`** (lines 151–229): logs **`event=complication_get_timeline_called`**, then **`loadLatestEntry()`** and builds 30 entries from that snapshot.

**`loadLatestEntry()`** (231–244): calls **`TrioComplicationDataStore.shared.latestSnapshot()`** → reads from **App Group container file** (JSON snapshot file), not WatchConnectivity or in-memory state.

**Rendering:** `TrioWatchComplicationEntryView` (and the accessory views) take a single **`entry: TrioWatchComplicationEntry`**. There is **no** `@AppStorage`, `@StateObject`, or other live binding. The “time ago” label uses **`shortRelativeTime(from: entry.readingDate, now: entry.date)`** (line 277). So the complication **only** shows what WidgetKit gives it in the **entry** (from either `getSnapshot` or `getTimeline`).

**“NOW”** is shown when `shortRelativeTime` gets an interval < 60 seconds (line 387):

```swift
private func shortRelativeTime(from readingDate: Date, now: Date = Date()) -> String {
    if readingDate == .distantPast { return "--" }
    let interval = max(0, now.timeIntervalSince(readingDate))
    if interval < 60 { return "NOW" }
    // ...
}
```

So “NOW” appears when the **entry’s** `readingDate` is within 1 minute of the **entry’s** `date`. For a **getSnapshot**-sourced entry, `TrioWatchComplicationEntry(snapshot:)` sets `date: Date()` and `readingDate: snapshot.readingDate`, so “NOW” means the **snapshot on disk** had a reading < 1 minute old when **getSnapshot** ran.

---

## 3. Why the Better Stack sawtooth never drops below ~4 minutes

**Your chart is built only from `event=complication_get_timeline_called`.** That is logged **only in `getTimeline`**, not in `getSnapshot` (see `TrioComplicationDataStore.logWidgetGetTimelineInvocation`, called from the complication provider only in `getTimeline`).

**`getSnapshot` is never logged** and does not emit that event.

So:

- When the system calls **`getTimeline`**, you get a log and your chart can show that moment (and the latency you derive from it). Timeline requests are rate-limited and scheduled by WidgetKit (e.g. after `reloadTimelines`), so they may happen only every few minutes → your sawtooth rarely/never goes below ~4 minutes.
- When the system calls **`getSnapshot`** (e.g. for a quick update when returning to the watch face or during a transition), the complication can show a **fresh entry** built from the same App Group file. That entry can have `readingDate` < 1 minute old → **“NOW”**. No `getTimeline` runs, so **no `complication_get_timeline_called`** and no drop on your chart.

So: **“NOW” after returning from the Watch app can come from a getSnapshot-sourced entry (reading the same freshly written snapshot) without any getTimeline call, which is why the sawtooth never drops below ~4 minutes.**

---

## Summary table

| Question | Answer |
|----------|--------|
| Does Watch call `reloadTimelines` after fresh data? | **Yes** — on WCSession message/userInfo (after save) and on background refresh; **not** on app foreground. |
| Where is reload called? | Only in **TrioComplicationDataStore**: `reloadTimeline()` from `coalescedReloadOnMain` (after save) or `forceReloadOnMain`. |
| Complication data source? | **App Group snapshot file** via `latestSnapshot()` in both `getSnapshot` and `getTimeline`. |
| Any path that shows fresh data without `getTimeline`? | **Yes.** **`getSnapshot`** returns `loadLatestEntry()` (same disk snapshot) and is **not** logged. So the face can show “NOW” from a snapshot without any `complication_get_timeline_called` event. |
| Live UI path (@AppStorage, etc.)? | **No.** The complication view uses only the `entry` from WidgetKit. |

---

## Recommendation

To align metrics with what the user sees, add a dedicated log event when **getSnapshot** is used (e.g. `event=complication_get_snapshot_called`) and optionally include snapshot age or `readingDate` there. That will let you see when “NOW” is coming from snapshot-only refreshes and reconcile it with the getTimeline-based sawtooth.
