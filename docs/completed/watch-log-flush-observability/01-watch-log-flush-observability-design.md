# Design: Watch Log Flush Observability

**Version:** 2.2
**Created:** 2026-03-21 14:26 CET
**Last updated:** 2026-03-21 22:43 CET
**Status:** Partially shipped (4A/4B/4C in build 143); 4D/4E/4F proposed

---

## Problem

Watch logs reach the iPhone via `WatchLogger` (`sendMessage` when reachable, `transferUserInfo` otherwise) and are appended to `watch_log.txt` on the phone. Three gaps existed in the watch-to-cloud logging pipeline:

1. **Silent truncation.** `WatchLogger.flushToPhone()` truncates joined in-memory logs to 16 KB per payload with no marker. Under burst logging (e.g. 50+ lines with verbose complication/HealthKit entries), tail lines are silently dropped — no signal in Better Stack or local files that data was lost.

2. **Upload latency.** `CloudLogUploadService` uploads on a 5-minute timer (plus foreground/background lifecycle triggers). Watch logs flushed to the phone can sit on disk for minutes before reaching Better Stack, creating a blind spot for real-time investigation.

3. **No manual flush control.** The watch debug screen's primary action was "Burst Save x14" (14× `dataStore.save` for debounce testing) — useful during complication dedup development but not for on-demand log retrieval. No way for the user to force watch logs to the phone without waiting for the automatic flush interval.

### Severity

These gaps are observability issues, not functional bugs. They delay or obscure diagnostic data without affecting glucose delivery, complication freshness, or any patient-facing behavior. However, they materially slow down incident investigation — silent truncation can make log-based root cause analysis inconclusive, and upload latency delays real-time monitoring.

---

## Context / Current State

| Area | Location | Notes |
|------|----------|-------|
| Watch flush | `Trio Watch App Extension/WatchLogger.swift` | `flushIfNeeded(force:)` joins in-memory buffer, truncates to 16 KB (`logSizeCap`), sends via `sendMessage` or `transferUserInfo`. Separate drain path (`flushPersistedLogs()`) uses 64 KB cap with `[truncated]` marker. |
| Phone receive | `AppleWatchManager.swift` | Four receive paths: `didReceiveMessageData` with reply, `didReceiveMessage` (envelope + legacy), `didReceiveUserInfo`. All call `SimpleLogReporter.appendToWatchLog`. |
| Cloud upload | `CloudLogUploadService.swift` | `uploadNow()` triggered by foreground, background lifecycle, and 5-minute timer. `CloudLogUploader` has 30s success cooldown. |
| Watch debug UI | `ComplicationDebugView.swift` | "Burst Save x14" button calls `runBurstSaveTest()` (14× `dataStore.save`). |
| Complication file buffer | `ComplicationLogBuffer.swift` | File cap already emits `[dropped N lines]` on its own truncate path. |

### Asymmetry between flush paths

The in-memory flush (16 KB) and the file drain path (64 KB + `[truncated]` marker) have different caps and different truncation signaling. The in-memory path is the primary one for real-time watch logs; it is the one that was silent.

---

## Decision

Three targeted changes, aligned with the backlog idea doc (`watch-log-flush-observability-idea.md` §3):

### Change 4A: Truncation logging in `WatchLogger.flushToPhone()`

When the joined in-memory log payload exceeds `logSizeCap` (16 KB), prepend a structured marker line to the truncated payload:

```
⚠️ log_flush_truncated cap_bytes=16384 original_bytes=<N> lines_total=<M>
```

The marker is included in the payload itself (not a separate log call), so it survives the same delivery path as the truncated content and appears in Better Stack alongside the logs it describes. The marker's byte cost is subtracted from the available content budget so the total payload stays within `logSizeCap`.

### Change 4B: Phone-side upload nudge via `trioWatchLogsAppended` notification

Define a `Notification.Name.trioWatchLogsAppended` notification. Post it from all four watch-log receive paths in `AppleWatchManager` after `SimpleLogReporter.appendToWatchLog` succeeds. Observe it in `CloudLogUploadService.start()` and call `uploadNow()` on the main queue.

This does not bypass existing guards — `CloudLogUploader`'s 30s success cooldown and token/config checks still apply. The notification is fire-and-forget; if the uploader is mid-run or cooling down, the nudge is effectively a no-op (the next timer tick or lifecycle event will pick up the logs).

### Change 4C: "Flush Logs" debug button on watch

Replace the "Burst Save x14" button in `ComplicationDebugView` with a "Flush Logs" button that:
1. Logs `⌚️ DEBUG manual flush requested` (force: true, so it enters the buffer even if at capacity)
2. Calls `flushIfNeeded(force: true)` to push the in-memory buffer to the phone
3. Calls `flushPersistedLogs()` to drain the complication log file and retry pending payloads
4. Shows a confirmation toast ("Logs flushed")

### Why this tradeoff (4A/4B/4C)

- **4A** makes truncation visible without changing the truncation policy. Changing the cap or splitting into multiple payloads is a larger change deferred to follow-up.
- **4B** is the minimal phone-side change to reduce upload latency. The existing cooldown prevents over-uploading. No new infrastructure needed — just a `NotificationCenter` post and observer.
- **4C** replaces an obsolete test action with a directly useful diagnostic tool. The burst save test's purpose (debounce validation) is covered by automated complication freshness telemetry since build 131.

---

## Post-Build-143 Findings

Production telemetry (26h post-deployment) revealed that truncation is pervasive: **137 `log_flush_truncated` events**, roughly one every 11 minutes. Typical payloads are 47–134 KB of watch log content truncated to the 16 KB cap — 65–88% of log lines dropped per flush. The truncation marker (4A) made this visible; three follow-up changes address it.

---

## Proposed Changes (build 144)

### Change 4D: Raise `logSizeCap` from 16 KB to 64 KB

Raise the in-memory flush cap in `WatchLogger.flushToPhone()` from 16,384 to 65,536 bytes, aligning it with the existing 64 KB cap used by the file drain path (`sendLogContentFromFile`).

Based on production data, most flush payloads are 47–95 KB. Raising to 64 KB eliminates truncation for the majority of flushes. The ~5% of flushes that exceed 64 KB (130+ KB bursts) are handled by 4E.

**WatchConnectivity payload limits and wire overhead:** `sendMessage` is commonly reported at ~65 KB (65,536 bytes) practical limit for data dictionary values; `transferUserInfo` at ~100 KB. A 64 KB content cap stays within safe bounds for both paths. However, the 4A truncation marker (~70 bytes) and the 4E chunk marker (~80 bytes) are prepended to the content, so the effective wire payload is up to `logSizeCap + ~80 bytes` ≈ 65,616 bytes. This is within ~80 bytes of the reported `sendMessage` limit. The risk is low — Apple's 65,536 limit typically applies to the message data dictionary value, and the overhead is well within serialization margin — but monitor for `WCError` code 7002 (payload too large) after deployment. `transferUserInfo` has ~35 KB of headroom and is not a concern.

### Change 4E: Split oversized payloads into sequential chunks

When the joined payload exceeds `logSizeCap` (now 64 KB) after 4D, split it into sequential chunks of ≤ `logSizeCap` bytes each instead of truncating. Each chunk is sent as a separate `sendMessage`/`transferUserInfo` call.

- **Eager computation:** All chunks must be computed before any are sent. The total chunk count `N` is needed for each chunk's `chunk=M/N` marker, so lazy/streaming chunk generation is not viable.
- **Max chunks:** Capped at 4 (256 KB total). If the payload exceeds 4× `logSizeCap`, the last chunk is truncated with the existing `log_flush_truncated` marker (4A still applies as a last resort).
- **Chunk marker:** Each chunk prepends a marker line whose byte cost is subtracted from the chunk's content budget (same pattern as 4A's truncation marker). Format:
  ```
  📦 log_flush_chunk chunk=M/N payload_id=<uuid> lines_in_chunk=<k>
  ```
  The `lines_in_chunk` field enables per-chunk line accounting so the total across all chunks of a `payload_id` can be verified against the pre-split line count.
- **Phone-side handling:** `SimpleLogReporter.appendToWatchLog` already handles appending. Chunks arrive in order when sent via `sendMessage` (synchronous session). For `transferUserInfo` (queued), ordering is FIFO per Apple docs. No reassembly logic needed — each chunk is independently appendable.
- **Truncation marker interaction:** If splitting produces a final chunk that itself needs truncation (payload > 4× cap), only the last chunk gets the `log_flush_truncated` marker.
- **No `cancelStaleQueuedTransfers()` interaction:** `cancelStaleQueuedTransfers()` runs on the **phone** and operates on `session.outstandingUserInfoTransfers`, which returns only **phone-to-watch** transfers (WatchState complication data). Watch log chunks are sent from the **watch** via `session.transferUserInfo` — these are **watch-to-phone** transfers in the watch's own outgoing queue. The phone cannot see or cancel them. These are independent queues in different directions, so no interaction exists.

### Change 4F: Replace 5-minute timer + cooldown with 30s upload timer + nudge-resets-timer

Replace the current upload scheduling model (`CloudLogUploadService`'s 5-minute repeating timer + `CloudLogUploader`'s 30s `successCooldown`) with a simpler model:

**New model:**
- A single 30s repeating timer in `CloudLogUploadService`.
- On each tick: call `uploadNow()`. If there are logs to upload, upload them. If not, no-op.
- The `trioWatchLogsAppended` nudge (4B) triggers an **immediate** `uploadNow()` call and **resets the 30s timer**. This prevents a redundant upload from the timer firing seconds later.
- Remove the 30s `successCooldown` from `CloudLogUploader`. The timer interval is the rate limit.
- Keep the `isUploading` guard in `CloudLogUploader` to prevent concurrent uploads. If a nudge arrives while an upload is in flight, it's a no-op — the timer will pick up any remaining content within 30s.
- Lifecycle triggers (foreground/background) remain and also reset the timer.
- **Thread safety:** `resetUploadTimer()` must be called on the main queue (same as the timer). This is guaranteed by the `trioWatchLogsAppended` observer registration: `queue: .main` in the `addObserver(forName:object:queue:)` call ensures the callback (and therefore `resetUploadTimer()`) runs on main regardless of which thread the notification was posted from. The `didReceiveMessage`/`didReceiveUserInfo` WCSession delegate callbacks may fire on arbitrary threads, but the `queue: .main` observer registration is the enforcement point.

**Why this replaces the existing model:**
The 5-minute timer + 30s cooldown + nudge notification was three interacting mechanisms. The nudge could be blocked by the cooldown, leaving watch logs on disk for up to 5 minutes. The new model is simpler: one 30s timer as the backstop, nudges for immediate delivery, timer reset to avoid redundancy. Worst-case latency drops from ~5 minutes to ~30 seconds.

**Worst-case gap analysis:**
1. **Nudge during active upload:** A nudge arrives while `isUploading` is true. The in-flight upload started reading before the new logs were appended, so it doesn't include them. The nudge is a no-op (but still resets the timer). Next upload is when the 30s timer fires. Max wait: 30s.
2. **Logs arrive during upload:** A nudge triggers `uploadNow()`, which reads the file and starts uploading. While the upload is in flight, more watch logs arrive and are appended. The in-flight upload doesn't include these new logs. The nudge from the new logs resets the timer to T+30s. The new logs wait until the timer fires. Max wait: 30s.

Both cases converge on the same bound: ≤30s worst-case latency for any log data that arrives while an upload is already in progress. This is acceptable.

### Why this tradeoff (4D/4E/4F)

- **4D** is a one-constant change that eliminates ~80% of truncation events based on production data. Low risk — aligned with the existing file drain path cap, within WatchConnectivity payload limits.
- **4E** handles the remaining ~20% of flushes (130+ KB bursts) without data loss. The max-chunk cap prevents unbounded queue growth during extreme bursts. The truncation marker from 4A remains as a last-resort signal.
- **4F** simplifies the upload scheduling model while reducing worst-case latency from ~5 minutes to ~30 seconds. Removes the `successCooldown` complexity entirely. The 30s polling cost is negligible (one file-empty check per tick during idle periods).

---

## Functional Behavior

### Triggers and flows (4A/4B/4C — shipped)

- **Normal watch log flush (changed — 4A):** Truncation now produces a visible marker line. Non-truncated flushes are unaffected.
- **Phone-side log receive (changed — 4B):** After appending watch logs, a notification triggers `uploadNow()`. The upload may or may not execute depending on cooldown state.
- **Watch debug screen (changed — 4C):** "Flush Logs" button replaces "Burst Save x14". Tapping it exercises the logging/drain paths, not the data store.

### Triggers and flows (4D/4E/4F — proposed)

- **Normal watch log flush (changed — 4D/4E):** Most flushes fit within the new 64 KB cap (no truncation). Oversized flushes are split into sequential chunks instead of truncated. Payloads exceeding 4× cap are truncated at the last chunk with the 4A marker.
- **Phone-side upload scheduling (changed — 4F):** 30s timer replaces 5-minute timer. Nudges trigger immediate upload and reset the timer. No more `successCooldown` in `CloudLogUploader`.

### Edge cases

- **Payload exactly at 64 KB (4D):** No truncation, no splitting — sent as a single payload.
- **Payload between 64 KB and 256 KB (4E):** Split into 2–4 chunks, each ≤ 64 KB. All chunks delivered in order.
- **Payload exceeding 256 KB (4E):** First 3 chunks sent in full; 4th chunk truncated with `log_flush_truncated` marker. Extremely rare based on production data (largest observed: 134 KB → 3 chunks).
- **Nudge while upload in flight (4F):** `isUploading` guard blocks the nudge. Next upload is ≤30s away (timer).
- **Flush when watch is unreachable:** Logs are queued via `transferUserInfo` for background delivery (existing behavior, unchanged). Each chunk becomes a separate `transferUserInfo` entry.

---

## Patch Assignment

| Change | Patch | Status |
|--------|-------|--------|
| 4A — Truncation logging | `06-cloud-logging.patch` (`WatchLogger.swift`) | Shipped (143) |
| 4B — Notification definition + observer | `06-cloud-logging.patch` (`CloudLogUploadService.swift`) | Shipped (143) |
| 4B — Notification posting from receive paths | `09-watch-complication-improvements.patch` + `10-watch-session-crash-guard.patch` (`AppleWatchManager.swift`) | Shipped (143) |
| 4C — Flush Logs button | `09-watch-complication-improvements.patch` (`ComplicationDebugView.swift`) | Shipped (143) |
| 4D — Raise `logSizeCap` to 64 KB | `06-cloud-logging.patch` (`WatchLogger.swift`) | Proposed |
| 4E — Payload splitting | `06-cloud-logging.patch` (`WatchLogger.swift`) | Proposed |
| 4F — 30s timer + nudge-resets-timer | `06-cloud-logging.patch` (`CloudLogUploadService.swift`, `CloudLogUploader.swift`) | Proposed |

The split across patches 06/09/10 is a consequence of the patch stack ordering: the notification infrastructure lives in the cloud-logging patch, while the posting call sites are in the files modified by the complication-improvements and crash-guard patches. All three new changes (4D/4E/4F) live in patch 06.

---

## Risks

### Shipped (4A/4B/4C)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Truncation marker consumes payload bytes that could carry log content | Very low | Negligible | Marker is ~70 bytes out of 16,384. Content cap is reduced by marker size. |
| Upload nudge increases Better Stack ingestion volume | Low | Low | Cooldown (30s) and existing volume filters still apply. Effect is faster upload of already-captured content, not more content. |
| Removing Burst Save x14 loses debounce test coverage | Low | Low | Debounce behavior is validated by complication-freshness telemetry (build 131+). |

### Proposed (4D/4E/4F)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| 64 KB payload exceeds WatchConnectivity practical limits | Low | Medium | `sendMessage` commonly reported at ~65 KB; `transferUserInfo` at ~100 KB. 64 KB is within safe bounds for both. Monitor for `WCError` after deployment. |
| Payload splitting increases watch-side `transferUserInfo` queue depth | Low | Low | Max 4 chunks per flush. Watch-side queue is independent of phone-side `cancelStaleQueuedTransfers()` (different transfer directions). |
| 30s timer increases CPU wake frequency | Very low | Negligible | One no-op file check per tick. Timer is invalidated when upload service stops. |
| Removing `successCooldown` allows rapid uploads | Low | Low | 30s timer interval acts as rate limit. `isUploading` guard prevents concurrent uploads. Lifecycle triggers (foreground/background) can fire closer together but are infrequent. |

---

## Success Criteria

### Shipped (4A/4B/4C)

1. **Truncation is visible:** Every flush that exceeds the cap produces a `log_flush_truncated` line in Better Stack with `cap_bytes`, `original_bytes`, and `lines_total`. **Pass** — 137 events in 26h.
2. **Upload nudge reduces latency:** Watch logs appear in Better Stack sooner after flush. **Pass** (qualitative).
3. **Flush Logs button works:** Tapping the button on the watch debug screen produces a `DEBUG manual flush requested` line in Better Stack and triggers a flush cycle. **Pass** — 1 event confirmed.
4. **No regressions:** Normal watch log delivery, cloud upload scheduling, and complication updates are unaffected. **Pass** — 26h clean.

### Proposed (4D/4E/4F)

5. **Truncation frequency drops:** `log_flush_truncated` events drop by ≥80% compared to pre-4D baseline (~137/26h). Remaining events should show `cap_bytes=65536`.
6. **No data loss on split:** `log_flush_chunk` markers appear in Better Stack when splitting occurs. Sum of `lines_in_chunk` across all chunks of a `payload_id` matches the pre-split line count. All `chunk=M/N` markers for a given `payload_id` are present (no gaps). **Note:** With 4D raising the cap to 64 KB, most observed payloads (47–95 KB) will fit without splitting. Splitting only triggers for burst events (130+ KB, ~5% of flushes at the 16 KB baseline). This criterion may not fire in the initial observation window — do not gate the build ship on it. Validate opportunistically when a burst occurs, or trigger one via the manual flush button after a period of log accumulation.
7. **Upload latency ≤30s:** Upload attempt occurs within 30s of `appendToWatchLog` for nudge-triggered uploads, ≤60s for timer-triggered uploads. Measured via upload-attempt log lines in `CloudLogUploader` as a proxy (direct measurement would require a `watch_logs_appended` log event at `appendToWatchLog` time, which is not yet instrumented — add if tighter verification is needed post-deployment).
8. **No WatchConnectivity errors:** No `WCError` or transfer failures attributable to the 64 KB payload size.

---

## Changelog

### v2.3 (2026-03-21 22:43 CET)
- **Success criterion 6:** Added note that splitting may not trigger in the initial observation window (most payloads fit within the new 64 KB cap). Criterion should not gate ship — validate opportunistically on burst events or via manual flush.

### v2.2 (2026-03-21 21:36 CET)
- **4E:** Removed false `cancelStaleQueuedTransfers()` interaction concern. `cancelStaleQueuedTransfers()` runs on the phone and operates on phone-to-watch transfers (WatchState complication data). Watch log chunks are watch-to-phone transfers in the watch's outgoing queue — independent queues in different directions. No interaction exists. Replaced the accepted-gap bullet with a clarifying note.
- **Risks:** Removed the 4E+4F `cancelStaleQueuedTransfers()` collision risk entry (false premise). Updated the `transferUserInfo` queue depth risk to note queue independence.

### v2.1 (2026-03-21 15:45 CET)
- **4D:** Added explicit note on `sendMessage` wire overhead — truncation/chunk markers add ~70–80 bytes on top of `logSizeCap`, putting effective wire payload at ~65,616 bytes (within ~80 bytes of the reported 65,536 limit). Decision: accept and monitor for `WCError` code 7002.
- **4E:** Added `cancelStaleQueuedTransfers()` interaction analysis — mid-delivery chunk cancellation is an accepted gap for `transferUserInfo` path. Added `lines_in_chunk` to chunk marker format for per-chunk line accounting. Noted chunk marker byte cost is subtracted from content budget (same pattern as 4A). Noted eager chunk computation requirement (total count `N` needed before sending).
- **4F:** Expanded worst-case gap analysis to cover "logs arrive during active upload" case (second 30s-bounded scenario). Referenced `queue: .main` observer registration as the thread-safety enforcement for `resetUploadTimer()`.
- **Cross-cutting:** Added 4E+4F `cancelStaleQueuedTransfers()` collision risk entry to Proposed risks table.
- **Success criteria:** Fixed criterion 6 to use `lines_in_chunk` sum instead of `lines_total` (which only exists in truncation markers). Softened criterion 7 to use upload-attempt log lines as proxy; noted that direct measurement requires a `watch_logs_appended` instrumentation point not yet added.

### v2.0 (2026-03-21 15:01 CET)
- Added proposed changes 4D (raise cap to 64 KB), 4E (payload splitting), 4F (30s timer + nudge-resets-timer) based on post-build-143 production telemetry showing pervasive truncation (137 events in 26h).
- Added "Post-Build-143 Findings" section documenting the truncation rate that motivated 4D/4E/4F.
- Split functional behavior, edge cases, risks, and success criteria into shipped (4A/4B/4C) and proposed (4D/4E/4F) sections.
- Updated patch assignment table with proposed changes and status column.
- Reason: production data revealed that 4A's truncation visibility exposed a much larger problem than expected. 4D/4E address the root cause (cap too low, no splitting). 4F simplifies upload scheduling and closes the latency gap left by 4B's cooldown limitation.

### v1.0 (2026-03-21 14:26 CET)
- Initial design document, written retroactively after build 143 shipment.
- Reason: complete the documentation set for the watch-log-flush-observability feature alongside the implementation plan and log.
