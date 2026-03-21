# Implementation Plan: Watch Log Flush Observability

**Version:** 2.2
**Created:** 2026-03-21 14:26 CET
**Last updated:** 2026-03-21 21:36 CET
**Status:** Partially shipped (4A/4B/4C in build 143); 4D/4E/4F proposed
**Design reference:** `01-watch-log-flush-observability-design.md`

---

## Scope

Add truncation visibility, upload latency reduction, and a manual flush control to the watch-to-cloud logging pipeline (4A/4B/4C — shipped build 143). Then address the pervasive truncation revealed by production telemetry: raise the flush cap, add payload splitting, and simplify upload scheduling (4D/4E/4F — proposed).

## Out of Scope

- Modifying the 64 KB file drain path cap or its existing `[truncated]` marker
- Better Stack ingestion filter adjustments
- Watch-side flush interval changes (how often the watch flushes to the phone)

## Dependencies

- 4A/4B/4C: span three patches (`06-cloud-logging`, `09-watch-complication-improvements`, `10-watch-session-crash-guard`) — shipped
- 4D/4E/4F: all in `06-cloud-logging.patch` — proposed
- No new external dependencies

## Sequencing + Ship Boundaries

### Phase 1 (shipped — build 143)
4A, 4B, 4C are independent. Bundled into build 143.

### Phase 2 (proposed — build 144)
- **4D** (raise cap) should ship before or with **4E** (splitting). 4E is only needed for payloads that exceed the new cap.
- **4F** (30s timer) is independent of 4D/4E but should ship together to get the full latency improvement.
- All three can ship in one build. Phase A is safe to ship alone; Phase B is safe to ship alone.

---

## Task 4A — Truncation Logging in `WatchLogger.flushToPhone()`

**Patch:** `06-cloud-logging.patch`
**File:** `Trio Watch App Extension/WatchLogger.swift`

**Change:** When the joined in-memory payload exceeds `logSizeCap` (16,384 bytes), prepend a structured marker line to the truncated content.

**Steps:**
1. Before truncation, compute `originalUTF8Count` (total byte size of joined logs) and `lineCount` (number of log lines in the buffer).
2. Build the marker string: `⚠️ log_flush_truncated cap_bytes=\(logSizeCap) original_bytes=\(originalUTF8Count) lines_total=\(lineCount)`
3. Subtract the marker's byte cost (including newline) from the available content budget: `contentCap = max(0, logSizeCap - markerBytes)`
4. Truncate the joined content to `contentCap` bytes (UTF-8 prefix).
5. Prepend: `logsToSend = marker + "\n" + truncatedContent`

**Acceptance:**
- Every flush where `originalUTF8Count > logSizeCap` produces a `log_flush_truncated` line visible in Better Stack.
- Non-truncated flushes emit no marker.
- Total payload size stays within `logSizeCap`.

**Observability:**
- `⚠️ log_flush_truncated cap_bytes=16384 original_bytes=<N> lines_total=<M>` — searchable in Better Stack via `log_flush_truncated`.

---

## Task 4B — Phone-Side Upload Nudge

**Patches:** `06-cloud-logging.patch` (definition + observer), `09-watch-complication-improvements.patch` + `10-watch-session-crash-guard.patch` (posting)
**Files:** `CloudLogUploadService.swift`, `AppleWatchManager.swift`

### Step 1 — Define notification and observer (patch 06)

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift`

**Change:**
1. Add notification name extension:
   ```swift
   extension Notification.Name {
       static let trioWatchLogsAppended = Notification.Name("trioWatchLogsAppended")
   }
   ```
2. In `start()`, add an observer alongside existing lifecycle observers:
   ```swift
   observers.append(
       center.addObserver(
           forName: .trioWatchLogsAppended,
           object: nil,
           queue: .main
       ) { [weak self] _ in
           self?.uploadNow()
       }
   )
   ```

### Step 2 — Post notification from receive paths (patches 09 + 10)

**File:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`

**Change:** In all four watch-log receive paths, post `.trioWatchLogsAppended` after `SimpleLogReporter.appendToWatchLog` succeeds:

1. `session(_:didReceiveMessageData:replyHandler:)` — envelope `watchLogs`
2. `session(_:didReceiveMessage:)` — envelope `watchLogs`
3. `session(_:didReceiveMessage:)` — legacy `watchLogs` string
4. `session(_:didReceiveUserInfo:)` — `watchLogs` from `transferUserInfo`

Each site:
```swift
SimpleLogReporter.appendToWatchLog(logData)
Foundation.NotificationCenter.default.post(name: .trioWatchLogsAppended, object: nil)
```

Uses `Foundation.NotificationCenter` (fully qualified) to avoid shadowing by the custom `NotificationCenter` protocol in this codebase.

**Acceptance:**
- After watch logs land on the phone, `uploadNow()` is called (subject to existing cooldown and config guards).
- No feedback loops — notification is posted only when a watch log payload is appended, not on every log line.

**Notes:**
- The notification itself is not logged (fire-and-forget). Its effect is observable as reduced latency between watch flush and Better Stack ingestion.
- The posting lives in patches 09/10 rather than 06 because those patches modify `AppleWatchManager.swift` (the receive paths).

---

## Task 4C — "Flush Logs" Debug Button

**Patch:** `09-watch-complication-improvements.patch`
**File:** `Trio Watch App Extension/Views/ComplicationDebugView.swift`

**Change:** Replace the "Burst Save x14" button with a "Flush Logs" button.

**Steps:**
1. Remove the `runBurstSaveTest()` call and its associated button.
2. Add a new button with `square.and.arrow.up` icon, "Flush Logs" label, purple tint, bordered style.
3. Button handler (`flushWatchLogs()`):
   ```swift
   private func flushWatchLogs() {
       Task {
           await WatchLogger.shared.log("⌚️ DEBUG manual flush requested", force: true)
           await WatchLogger.shared.flushIfNeeded(force: true)
           await WatchLogger.shared.flushPersistedLogs()
           await MainActor.run {
               showConfirmation(message: "📤 Logs flushed")
           }
       }
   }
   ```

**Acceptance:**
- Tapping "Flush Logs" does not call `TrioComplicationDataStore.save`. It only exercises logging and drain paths.
- `⌚️ DEBUG manual flush requested` appears in Better Stack after the flush reaches the phone and is uploaded.
- A confirmation toast ("Logs flushed") appears on the watch screen.

**Observability:**
- `⌚️ DEBUG manual flush requested` — searchable in Better Stack to confirm manual flush usage.

---

## Task 4D — Raise `logSizeCap` to 64 KB

**Patch:** `06-cloud-logging.patch`
**File:** `Trio Watch App Extension/WatchLogger.swift`
**Status:** Proposed

**Change:** Increase `logSizeCap` from 16,384 to 65,536 bytes.

**Steps:**
1. Find the `logSizeCap` constant definition in `WatchLogger.swift`.
2. Change its value from `16_384` to `65_536`.
3. Update the truncation marker's `cap_bytes` output (it already uses the constant dynamically, so this should happen automatically).

**Acceptance:**
- `log_flush_truncated` events in production show `cap_bytes=65536` instead of `cap_bytes=16384`.
- Truncation frequency drops by ≥80% compared to the pre-4D baseline (~137 events/26h at 16 KB).
- No `WCError` or transfer failures attributable to the larger payload size.

**Observability:**
- Existing `log_flush_truncated` marker now shows `cap_bytes=65536` when truncation does occur.
- Monitor for WatchConnectivity errors in Better Stack after deployment.

**Notes:**
- This is a one-constant change. The file drain path already uses 64 KB (`sendLogContentFromFile`), so this aligns the two paths.
- WatchConnectivity practical limits: `sendMessage` ~65 KB, `transferUserInfo` ~100 KB. 64 KB is within bounds for both.
- **Wire overhead:** The 4A truncation marker (~70 bytes) and 4E chunk marker (~80 bytes) are prepended to content, so the effective wire payload is up to `logSizeCap + ~80 bytes` ≈ 65,616 bytes. This is within ~80 bytes of the reported `sendMessage` limit (65,536 for data dictionary values). Risk is low but monitor for `WCError` code 7002 after deployment.

---

## Task 4E — Split Oversized Payloads Into Chunks

**Patch:** `06-cloud-logging.patch`
**File:** `Trio Watch App Extension/WatchLogger.swift`
**Status:** Proposed

**Change:** When the joined payload exceeds `logSizeCap` (65,536 after 4D), split into sequential chunks instead of truncating.

**Steps:**
1. In `flushToPhone()`, after joining the in-memory buffer, check if `originalUTF8Count > logSizeCap`.
2. If so, generate a `payloadId` (UUID string) for traceability.
3. Compute the total number of chunks `N` up front: `N = min(ceil(originalUTF8Count / contentBudget), maxChunks)` where `contentBudget = logSizeCap - chunkMarkerBytes` (see step 5). All chunks must be computed eagerly before any are sent — the `chunk=M/N` marker requires knowing `N` in advance.
4. Split the joined content into `N` chunks of ≤ `contentBudget` bytes each (respecting UTF-8 character boundaries).
5. Cap at `maxChunks = 4` chunks (256 KB max total). If the payload exceeds 4× `logSizeCap`:
   - First 3 chunks: full `contentBudget` bytes of content.
   - 4th chunk: truncated to `contentBudget` with the existing `log_flush_truncated` marker (4A).
6. Prepend a chunk marker to each chunk. The marker's byte cost (including newline) is subtracted from the chunk's content budget so the total chunk payload stays within `logSizeCap` (same pattern as 4A's truncation marker):
   ```
   📦 log_flush_chunk chunk=1/3 payload_id=<uuid> lines_in_chunk=<k>
   ```
   The `lines_in_chunk` field counts the number of log lines in that chunk's content (after splitting). This enables verification that the sum across all chunks matches the pre-split total.
7. Send each chunk sequentially via the existing `sendMessage`/`transferUserInfo` path.

**Acceptance:**
- Payloads between 64 KB and 256 KB are split into 2–4 chunks, each ≤ `logSizeCap` bytes (including the chunk marker).
- Each chunk has a `log_flush_chunk` marker with `chunk=M/N`, `payload_id`, and `lines_in_chunk`.
- Sum of `lines_in_chunk` across all chunks of a `payload_id` matches the pre-split line count.
- Payloads exceeding 256 KB: first 3 chunks sent in full, 4th chunk truncated with `log_flush_truncated` marker.
- All chunks arrive in order on the phone (FIFO for both `sendMessage` and `transferUserInfo`).

**Observability:**
- `📦 log_flush_chunk chunk=M/N payload_id=<uuid> lines_in_chunk=<k>` — searchable in Better Stack. Group by `payload_id` to reconstruct full flush payloads; sum `lines_in_chunk` to verify completeness.
- `log_flush_truncated` only appears if the payload exceeds 4× cap (extremely rare based on production data — largest observed was 134 KB → 3 chunks).

**Notes:**
- UTF-8 boundary handling: when splitting at byte offset N, scan backward from N to find a valid UTF-8 character boundary. Use `String.UTF8View` prefix + conversion back to `String` for safe truncation.
- Phone-side `SimpleLogReporter.appendToWatchLog` already handles appending — each chunk is independently appendable with no reassembly logic.
- `transferUserInfo` queue: each chunk is a separate transfer in the watch's outgoing queue. Max 4 chunks per flush. Note: phone-side `cancelStaleQueuedTransfers()` (R1b) operates on phone-to-watch transfers only and cannot affect watch-to-phone log chunks — these are independent queues in different directions.

---

## Task 4F — Replace 5-Minute Timer + Cooldown With 30s Timer + Nudge-Resets-Timer

**Patch:** `06-cloud-logging.patch`
**Files:** `CloudLogUploadService.swift`, `CloudLogUploader.swift`
**Status:** Proposed

### Step 1 — Replace 5-minute timer with 30s timer (`CloudLogUploadService`)

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift`

**Change:**
1. Find the timer setup (currently 5-minute / 300s interval).
2. Change the interval to 30s.
3. Extract the timer setup into a helper method (e.g. `resetUploadTimer()`) that invalidates the existing timer and schedules a new 30s timer.

### Step 2 — Nudge triggers immediate upload and resets timer (`CloudLogUploadService`)

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift`

**Change:** Update the `trioWatchLogsAppended` observer (from 4B) to:
1. Call `uploadNow()` immediately.
2. Call `resetUploadTimer()` to restart the 30s countdown.

Update lifecycle observers (foreground/background) similarly:
1. Call `uploadNow()` (existing behavior).
2. Call `resetUploadTimer()` to restart the 30s countdown.

```swift
// Watch log nudge observer (updated from 4B)
observers.append(
    center.addObserver(
        forName: .trioWatchLogsAppended,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.uploadNow()
        self?.resetUploadTimer()
    }
)
```

### Step 3 — Remove `successCooldown` from `CloudLogUploader`

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift`

**Change:**
1. Remove the `lastSuccessfulUploadAt` property.
2. Remove the `successCooldown` constant (30s).
3. Remove the early-return guard that checks `Date().timeIntervalSince(lastSuccessfulUploadAt) < successCooldown`.
4. Keep the `isUploading` guard (prevents concurrent uploads).

After this change, `uploadNow()` has one guard: `isUploading`. The 30s timer interval in `CloudLogUploadService` is the de facto rate limit.

**Acceptance:**
- `CloudLogUploadService` fires `uploadNow()` every 30s (timer) or immediately on nudge/lifecycle.
- Timer resets on nudge and lifecycle triggers — no redundant upload shortly after a nudge.
- `CloudLogUploader.uploadNow()` no longer has a cooldown. Only the `isUploading` guard remains.
- Worst-case latency from `appendToWatchLog` to Better Stack upload attempt: 30s (nudge blocked by `isUploading`, timer fires later).
- Logs accumulated during idle periods (no nudges) are uploaded within 30s.

**Observability:**
- Existing upload success/failure logging in `CloudLogUploader` is unchanged.
- Timer interval change is not directly logged; observable via upload frequency in Better Stack (expect ~2×/min instead of ~0.2×/min during active periods).

**Notes:**
- The 30s timer fires even when there are no logs to upload. `CloudLogUploader.uploadNow()` should already handle the empty-file case efficiently (check file size, return early if empty). Verify this is the case; add an early return if not.
- **Thread safety:** `resetUploadTimer()` must be called on the main queue (same as the timer). This is enforced by the `trioWatchLogsAppended` observer registration: `queue: .main` in `addObserver(forName:object:queue:)` ensures the callback runs on main regardless of which thread the notification was posted from. The WCSession delegate callbacks (`didReceiveMessage`, `didReceiveUserInfo`) may fire on arbitrary threads, but the observer's `queue: .main` is the enforcement point — no additional dispatch needed.

---

## Risks & Mitigations

### Shipped (4A/4B/4C)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Truncation marker bytes reduce usable payload | Very low | Negligible | ~70 bytes out of 16,384. |
| Upload nudge increases ingestion rate | Low | Low | 30s cooldown + existing volume filters still apply. |
| Removing burst save loses debounce coverage | Low | Low | Complication freshness telemetry covers this since build 131. |
| `Foundation.NotificationCenter` shadowing causes compile error | Low | Low | All posting sites use fully qualified `Foundation.NotificationCenter.default`. |

### Proposed (4D/4E/4F)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| 64 KB payload exceeds WC limits | Low | Medium | `sendMessage` ~65 KB, `transferUserInfo` ~100 KB. 64 KB within bounds. Monitor for `WCError`. |
| Chunk splitting increases watch-side `transferUserInfo` queue depth | Low | Low | Max 4 chunks. Watch-side queue is independent of phone-side `cancelStaleQueuedTransfers()`. |
| 30s timer increases CPU wakes | Very low | Negligible | One file-size check per tick. Timer invalidated on service stop. |
| Removing `successCooldown` allows rapid uploads | Low | Low | Timer interval is the rate limit. `isUploading` prevents concurrent uploads. |
| 64 KB payload + marker overhead near `sendMessage` limit | Low | Low | Effective wire payload ~65,616 bytes vs ~65,536 limit. Monitor for `WCError` code 7002. |

---

## Changelog

### v2.2 (2026-03-21 21:36 CET)
- **4E:** Removed false `cancelStaleQueuedTransfers()` interaction concern and combined risk entry. Watch log chunks (watch-to-phone) and `cancelStaleQueuedTransfers()` (phone-to-watch) operate on independent `transferUserInfo` queues in different directions. Replaced with a clarifying note on queue independence.

### v2.1 (2026-03-21 15:45 CET)
- **4D:** Added wire overhead note — truncation/chunk markers add ~70–80 bytes on top of `logSizeCap`, putting effective wire payload near the `sendMessage` limit. Decision: accept and monitor.
- **4E:** Added `lines_in_chunk` to chunk marker format. Noted chunk marker byte cost is subtracted from content budget. Noted eager computation requirement. Added `cancelStaleQueuedTransfers()` interaction note and combined 4E+4F risk entry.
- **4F:** Referenced `queue: .main` observer registration as thread-safety enforcement for `resetUploadTimer()`.
- **Risks:** Added 4E+4F combined risk (mid-delivery chunk cancellation) and 64 KB wire overhead risk.

### v2.0 (2026-03-21 15:01 CET)
- Added tasks 4D (raise `logSizeCap` to 64 KB), 4E (payload splitting), 4F (30s timer + nudge-resets-timer).
- Updated scope, out-of-scope, dependencies, and sequencing for the two-phase model (shipped + proposed).
- Split risks table into shipped and proposed sections.
- Reason: production telemetry showed pervasive truncation (137 events/26h) at the 16 KB cap, and the 5-minute timer + cooldown model left a latency gap that the nudge (4B) couldn't fully close.

### v1.0 (2026-03-21 14:26 CET)
- Initial implementation plan, written retroactively after build 143 shipment.
- Reason: complete the documentation set for the watch-log-flush-observability feature alongside the design doc and implementation log.
