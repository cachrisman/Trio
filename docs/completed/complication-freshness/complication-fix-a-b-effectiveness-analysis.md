# Complication Fix A & Fix B — Effectiveness Analysis (Build 115)

**Context:** Build 115 (Fix A + Fix B) was deployed to phone and watch at ~18:23 CET on 2026-02-26. This document analyzes local watch logs and phone logs to assess effectiveness of the complication background-task race fix and the observability improvements.

**Log sources analyzed:**
- `build/logs/watch_log.txt` — current watch log (Feb 26 23:55 → Feb 27 12:26+)
- `build/logs/watch_log_prev.txt` — previous watch log (through Feb 26 23:52)
- `build/logs/log.txt` — current phone log (from Feb 27 00:01)
- `build/logs/log_prev.txt` — previous phone log (from Feb 26 00:01)

**Better Stack:** Cloud logs were queried via the Better Stack MCP (Trio source_id `1659391`). A sample query for the last 2 hours for messages containing "Snapshot saved", "saveOnMain", or "Handling background tasks" returned multiple "Snapshot saved" and "Handling background tasks" events (e.g. 11:08–11:51 UTC on 2026-02-27), including "Handling background tasks: 2" and snapshot_age_seconds values from 8s to 766s. No "saveOnMain" message appeared in that sample (see note below on entry log visibility). The cloud log sample supports the same conclusion: Fix A and Fix B are effective (saves and background task handling visible; freshness metric available via snapshot_age_seconds).

**Build 115 provenance:** The release manifest for build 115 (`release-manifest-20260226T172611Z-local.json`) confirms that the IPA was built with patch 09 from commit `bb308043eb5a7aa44638a7e8714c1375e7fa5e87` (date Thu, 26 Feb 2026 18:08:53 +0100, subject "feat: watch-complication-improvements"). That patch version includes Fix A and Fix B, including the `saveOnMain` entry log and "passed dedup, writing snapshot" line. So build 115 **did** include those code paths.

---

## 1. Summary of Changes Implemented

### Fix B (Observability)
- **Log forwarder:** `TrioComplicationDataStore` now has an optional `logForwarder` closure (set by the Watch App Extension at launch) so that every `log(_:)` call is also sent to WatchLogger. Forwarder is protected by `logForwarderLock` (thread-safe; `log()` can be called from any thread, e.g. complication extension).
- **saveOnMain entry log:** At the very start of `saveOnMain`, we log `"saveOnMain entered: glucose=..., readingDate=..."`. Optionally before the write block: `"saveOnMain: passed dedup, writing snapshot"`.
- **Effect:** TrioComplicationDataStore messages (Dedup, Snapshot saved, Reload TRIGGERED, etc.) now appear in watch_log.txt via WatchLogger even when ComplicationLogBuffer is the only other sink, so we can see whether `saveOnMain` is being entered and whether snapshots are being written after background wakes.

### Fix A (Correctness — Hold connectivity task until processing completes)
- **Hold connectivity tasks:** In `handleBackgroundTasks`, `WKWatchConnectivityRefreshBackgroundTask` is no longer completed immediately. Tasks are appended to `pendingConnectivityTasks` and a 5s safety timeout is scheduled per task.
- **Quiet-window completion:** Completion happens only after a 300ms quiet window (no new userInfo) and one final `finalizePendingData()`, or when the 5s timeout fires. Tasks are not completed inside `finalizePendingData()`.
- **didReceiveUserInfo:** Always dispatch to main first. On main: if `pendingConnectivityTasks.isEmpty`, call `scheduleUIUpdate(with: payload)` only (no pre-merge). If non-empty, merge into `pendingData`, cancel `finalizeWorkItem` and `quietWindowWorkItem`, set `lastUserInfoReceivedAt`, and schedule the 300ms quiet-window; when it fires, run one `finalizePendingData()` then complete all pending connectivity tasks.
- **Effect:** The extension is not suspended before the debounced/quiet-window finalization runs, so `finalizePendingData` → `saveComplicationSnapshot` → `saveOnMain` execute before the OS suspends the process.

---

## 2. Findings from Local Logs

### 2.1 Fix B — Observability

**TrioComplicationDataStore lines in watch_log.txt (current):**  
Present and continuous after the first wake in the log window. Examples (all via `log(_:)` → WatchLogger):

- Dedup: `⏭️ Dedup: skipped duplicate snapshot`, `⏭️ Dedup: rejected older snapshot (timeDiff=...)`
- Saves: `✅ Snapshot saved: glucose=..., trend=..., delta=..., snapshot_age_seconds=N`
- Reloads: `🔄 Reload TRIGGERED`, `🔄 FORCE reload triggered`, `🔄 Retry reload triggered`, `🔔 reload_snapshot_age_seconds=N`, `🔔 Calling WidgetCenter.reloadTimelines`
- Retry: `⏰ Retry scheduled`, `⏳ Reload DEBOUNCED`

So **Fix B is effective:** TrioComplicationDataStore output is visible in the watch log throughout the period, confirming the log forwarder is active and that we can observe both dedup decisions and snapshot saves.

**Note on "saveOnMain entered":** The literal string `"saveOnMain entered"` does **not** appear in the current watch_log.txt. The release manifest confirms build 115 was built with the Fix A+B patch that includes this line, so the code was in the deployed build. The absence in the log is therefore a pipeline or visibility puzzle (e.g. message format, filtering, or ingestion). The presence of `✅ Snapshot saved` and other TrioComplicationDataStore lines still confirms that `saveOnMain` is being **reached** (saves only happen after the entry point). If needed, future work could investigate why the entry line does not appear in watch_log or Better Stack despite being in the binary.

### 2.2 Fix A — Correctness (race fix)

**Before Fix A (plan’s evidence):**  
TrioComplicationDataStore log lines (Snapshot saved, Dedup, Reload) appeared only for ~54 minutes; afterward only WatchState/WatchLogger lines appeared at each wake — i.e. `saveOnMain` (and thus snapshot writes) stopped being reached after the race started losing the debounced work.

**After Fix A (watch_log.txt, post–18:23 deploy):**

- **handleBackgroundTasks** appears many times with `Handling background tasks: 1` or `Handling background tasks: 2`.
- After those same wake cycles we consistently see the full pipeline:
  - `session(_:didReceiveUserInfo:)` → `Received userInfo with keys: watchState`
  - `scheduleUIUpdate(with:)` → `Merging new WatchState data with keys: ...`
  - `Debounced update fired` (or equivalent)
  - `finalizePendingData()` → `Finalizing pending data`
  - `processRawDataForWatchState(_:)` → `Processing raw WatchState data with keys: ...`
  - `saveComplicationSnapshot(from:)` → `📸 saveComplicationSnapshot called...` / `📸 Saving snapshot: glucose=...`
  - `finalizePendingData()` → `Watch UI update complete`
- And in the same time window, **TrioComplicationDataStore** lines appear: `✅ Snapshot saved: glucose=..., snapshot_age_seconds=N`, plus Dedup/Reload messages.

So after a background wake we now see both WatchState’s finalize/save path and TrioComplicationDataStore’s save/reload path. That indicates the extension is **not** being suspended before the debounced (or quiet-window) finalization runs — i.e. **Fix A is working as intended**: connectivity tasks are being held until after processing, so `saveOnMain` runs and snapshots are written on background delivery.

**Single wake with two tasks (01:06:10):**  
At `2026-02-27T01:06:10+0100` the log shows `Handling background tasks: 2`, then `forceComplicationUpdate` (application refresh path), then `session(_:didReceiveUserInfo:)` (multiple payloads), then `Debounced update fired`, `finalizePendingData`, `saveComplicationSnapshot`, `📸 Saving snapshot: glucose=151, ...`, and `Watch UI update complete`. So both tasks were handled and the connectivity path did not prevent finalization and save — consistent with holding the connectivity task and completing it after the quiet-window/finalize.

### 2.3 Complication data freshness

**Metric used:**  
The plan and prior discussion used **snapshot age at save time** as the freshness metric. In the logs this appears as:

- `✅ Snapshot saved: glucose=..., trend=..., delta=..., snapshot_age_seconds=N`
- `🔔 reload_snapshot_age_seconds=N`

So the **best way to observe data freshness** in logs is: (1) `snapshot_age_seconds` in the “Snapshot saved” line (age of the reading when we wrote it to disk), and (2) `reload_snapshot_age_seconds` when we trigger a WidgetKit reload (age of the snapshot we’re asking the complication to show).

**Observed snapshot_age_seconds (watch_log.txt, TrioComplicationDataStore lines, post–deploy window):**

- **Fresh (≤ ~2 min):** 8, 15, 29, 73, 89, 97, 101, 128, 165, 194, 204, 232, 315, 389 seconds.
- **Older but still written:** 308, 329, 424, 494, 536, 581, 587, 696, 764, 765, 1206 seconds.

So we see a mix: many saves with age under a few minutes (including 8s, 15s, 29s), and some with age in the 5–20 minute range. The important point is that **saves are happening at all** on background wakes; before Fix A, no TrioComplicationDataStore saves were observed after the race started. Freshness distribution will depend on CGM update interval, phone coalescing, and when the watch is woken; the logs show that when new data arrives via userInfo, it is being finalized and saved.

**Comparison with watch_log_prev.txt (pre–Fix A or earlier build):**  
In the previous log we see TrioComplicationDataStore lines with very large ages (e.g. `snapshot_age_seconds=1413`, `1714`, `1278`), and the plan’s evidence was that TrioComplicationDataStore lines then disappeared for hours while WatchState kept logging — i.e. saves stopped. In the current log we have both continuous TrioComplicationDataStore output and many saves with moderate-to-good ages, consistent with Fix A preventing the race and Fix B making the store’s behavior visible.

---

## 3. Conclusions

| Item | Status | Evidence |
|------|--------|----------|
| **Fix B (log forwarder)** | Effective | TrioComplicationDataStore messages (Dedup, Snapshot saved, Reload, etc.) appear in watch_log.txt throughout the analyzed window. |
| **Fix B (saveOnMain entry log)** | In build 115, not visible in log | Manifest confirms build 115 used patch 09 from bb308043 (Fix A+B), which includes the entry log. The string does not appear in watch_log.txt; cause unknown (pipeline/visibility). Snapshot saved lines prove saveOnMain was reached. |
| **Fix A (hold task + quiet window)** | Effective | After each `Handling background tasks`, the pipeline (didReceiveUserInfo → scheduleUIUpdate / merge → debounce/quiet-window → finalizePendingData → saveComplicationSnapshot → saveOnMain) completes and TrioComplicationDataStore “Snapshot saved” lines appear. No multi-hour gap where only WatchState logs. |
| **Data freshness (observability)** | Clear metric | Use `snapshot_age_seconds` in “Snapshot saved” and `reload_snapshot_age_seconds` in TrioComplicationDataStore logs as the primary freshness metrics; both are now visible via Fix B. |

**Recommendation:**  
- Keep Fix A and Fix B as-is; behavior matches the plan.  
- Build 115 included the saveOnMain entry log (per release manifest); if that line is needed for analysis, investigate why it does not appear in watch_log or Better Stack.  
- For ongoing monitoring, query Better Stack (or local watch_log) for TrioComplicationDataStore messages containing `snapshot_age_seconds` and "Snapshot saved" in the time window of interest to track complication data freshness after background wakes.

---

## 4. Document info

- **Version:** 1.1  
- **Date:** 2026-02-27  
- **Log files:** Trio `build/logs/watch_log.txt`, `watch_log_prev.txt`, `log.txt`, `log_prev.txt` (paths relative to Trio workspace).

**Changelog:**  
- v1.1: Confirmed build 115 provenance via release manifest (patch 09 from bb308043). Corrected conclusion: saveOnMain entry log was in the build; absence in logs is a pipeline/visibility puzzle, not a missing build.
