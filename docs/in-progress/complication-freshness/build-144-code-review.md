# Build 144 — Code Review Diff

**Date:** 2026-03-21
**Branches:** `feature/cloud-logging` (4D/4E/4F), `feature/watch-complication-improvements` (4G/4H/4I)
**Plan:** `docs/in-progress/complication-freshness/build-144-plan.md` v1.3

---

## Patch 06 — `feature/cloud-logging` (4D / 4E / 4F)

### 4D — Raise `logSizeCap` to 64 KB

**File:** `Trio Watch App Extension/WatchLogger.swift`

```diff
     // Size caps
-    private let logSizeCap = 16 * 1024 // 16 KB
+    private let logSizeCap = 64 * 1024 // 64 KB
```

One-constant change. Aligns in-memory flush cap with the file drain path's existing 64 KB cap.

---

### 4E — Split oversized payloads into sequential chunks

**File:** `Trio Watch App Extension/WatchLogger.swift`

**Summary:** Replaced the truncate-only path in `flushToPhone()` with line-boundary-aware chunk splitting. Extracted sending logic into a new `sendLogPayload(_:)` helper.

#### `flushToPhone()` — before (truncation only)

```diff
-        var logsToSend = logs.joined(separator: "\n")
-
-        // logSizeCap (16KB) limits in-memory flush payloads sent via WCSession.
-        // Per-payload drain files can be up to 64KB (maxDrainFileSize).
-        let originalUTF8Count = logsToSend.utf8.count
-        let lineCount = logs.count
-
-        if originalUTF8Count > logSizeCap {
-            let marker = "⚠️ log_flush_truncated cap_bytes=\(logSizeCap) ..."
-            ...
-            logsToSend = marker + "\n" + truncatedContent
-        }
-
-        let payloadId = UUID().uuidString
-        ... (file write, envelope build, sendMessage/transferUserInfo) ...
-
-        logs.removeAll()
-        lastFlush = Date()
```

#### `flushToPhone()` — after (split into chunks)

```diff
+        let allContent = logs.joined(separator: "\n")
+        let originalUTF8Count = allContent.utf8.count
+        let totalLineCount = logs.count
+        let originalLines = logs
+
+        logs.removeAll()
+        lastFlush = Date()
+
+        // Single payload fits within cap — send directly
+        if originalUTF8Count <= logSizeCap {
+            await sendLogPayload(allContent)
+            return
+        }
+
+        // 4E: Split oversized payloads into sequential chunks (max 4 × logSizeCap)
+        let maxChunks = 4
+        let groupId = UUID().uuidString
+
+        // Content budget per chunk: logSizeCap minus worst-case chunk marker overhead.
+        let worstCaseMarker = "📦 log_flush_chunk chunk=\(maxChunks)/\(maxChunks) payload_id=\(groupId) lines_in_chunk=\(totalLineCount)"
+        let markerOverhead = worstCaseMarker.utf8.count + 1
+        let contentBudget = max(1, logSizeCap - markerOverhead)
+
+        // Pack lines greedily into chunks (line-boundary-aware)
+        var chunks: [(content: String, lineCount: Int)] = []
+        var currentLines: [String] = []
+        var currentBytes = 0
+        var lineIndex = 0
+
+        while lineIndex < originalLines.count {
+            let line = originalLines[lineIndex]
+            let addedBytes = (currentLines.isEmpty ? 0 : 1) + line.utf8.count
+
+            if currentBytes + addedBytes > contentBudget && !currentLines.isEmpty {
+                chunks.append((
+                    content: currentLines.joined(separator: "\n"),
+                    lineCount: currentLines.count
+                ))
+                currentLines = []
+                currentBytes = 0
+
+                if chunks.count >= maxChunks - 1 {
+                    // Last allowed chunk — pack all remaining lines
+                    let remaining = Array(originalLines[lineIndex...])
+                    let remainingContent = remaining.joined(separator: "\n")
+
+                    if remainingContent.utf8.count <= contentBudget {
+                        chunks.append((content: remainingContent, lineCount: remaining.count))
+                    } else {
+                        // 4A truncation on the last chunk
+                        let truncMarker = "⚠️ log_flush_truncated cap_bytes=\(logSizeCap) ..."
+                        let truncMarkerBytes = truncMarker.utf8.count + 1
+                        let truncBudget = max(0, contentBudget - truncMarkerBytes)
+
+                        var truncLines: [String] = []
+                        var truncBytes = 0
+                        for rl in remaining {
+                            let added = (truncLines.isEmpty ? 0 : 1) + rl.utf8.count
+                            if truncBytes + added > truncBudget { break }
+                            truncLines.append(rl)
+                            truncBytes += added
+                        }
+
+                        let truncContent = truncMarker + "\n" + truncLines.joined(separator: "\n")
+                        chunks.append((content: truncContent, lineCount: truncLines.count))
+                    }
+                    lineIndex = originalLines.count
+                    break
+                }
+                continue
+            }
+
+            currentLines.append(line)
+            currentBytes += addedBytes
+            lineIndex += 1
+        }
+
+        if !currentLines.isEmpty {
+            chunks.append((
+                content: currentLines.joined(separator: "\n"),
+                lineCount: currentLines.count
+            ))
+        }
+
+        let totalChunks = chunks.count
+
+        for (index, chunk) in chunks.enumerated() {
+            let chunkNumber = index + 1
+            let chunkMarker = "📦 log_flush_chunk chunk=\(chunkNumber)/\(totalChunks) payload_id=\(groupId) lines_in_chunk=\(chunk.lineCount)"
+            let finalContent = chunkMarker + "\n" + chunk.content
+            await sendLogPayload(finalContent)
+        }
```

#### New `sendLogPayload(_:)` helper (extracted from old `flushToPhone`)

```diff
+    /// Sends a single log payload (or chunk) to the phone via WCSession.
+    private func sendLogPayload(_ content: String) async {
+        let payloadId = UUID().uuidString
+        ... (identical file write, envelope build, sendMessage/transferUserInfo as before)
+    }
```

**Key design decisions:**
- **Line-boundary splitting:** Lines are never split mid-line. Each chunk contains whole log entries, so `lines_in_chunk` sums correctly across chunks.
- **Eager chunk computation:** All chunks are computed before any are sent — `chunk=M/N` is accurate.
- **Budget math:** `contentBudget = logSizeCap - (chunk marker bytes + 1)`. Truncation marker bytes are additionally subtracted from the 4th chunk's budget. The `worstCaseMarker` uses `totalLineCount` for the `lines_in_chunk` field, which overestimates by a few bytes (actual chunk line count is smaller) — conservative and harmless.
- **`continue` retries the current line in a fresh chunk.** When a chunk boundary is hit: the full chunk is saved, `currentLines`/`currentBytes` are reset, but `lineIndex` is NOT incremented. The `continue` restarts the loop with the same `lineIndex`. On retry, `currentLines` is empty so the `!currentLines.isEmpty` guard is false, the overflow check is skipped, and the line falls through to `append`. No lines are dropped.
- **Moved `logs.removeAll()` + `lastFlush = Date()` before sending:** Content is captured in `originalLines` first. Sending failure is handled by per-payload files + retry (existing behavior).
- **Each chunk gets its own `payloadId`** for independent ACK tracking. The `groupId` in the chunk marker ties them together in Better Stack.

---

### 4F — Replace 5-min timer + cooldown with 30s timer + nudge-resets-timer

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift`

```diff
 /// - Periodic trigger: every 30 seconds while app is running
+/// - Watch log nudge: immediate upload + timer reset when watch logs arrive
 final class CloudLogUploadService {
```

```diff
     private func start() {
         ...
             ) { [weak self] _ in
                 self?.uploadNow()
+                self?.resetUploadTimer()
             }
         )
         ...
             ) { [weak self] _ in
                 self?.uploadNow()
+                self?.resetUploadTimer()
             }
         )

-        // Watch log nudge: upload promptly when watch logs arrive
+        // Watch log nudge: immediate upload + timer reset.
+        // queue: .main ensures resetUploadTimer() runs on the main thread
+        // regardless of which thread the notification was posted from.
         ...
             ) { [weak self] _ in
                 self?.uploadNow()
+                self?.resetUploadTimer()
             }
         )

-        // Periodic trigger (while running)
-        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { ... }
+        resetUploadTimer()
     }

+    private func resetUploadTimer() {
+        timer?.invalidate()
+        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
+            self?.uploadNow()
+        }
+    }
```

**File:** `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift`

```diff
     private var isUploading = false
-    private var lastSuccessfulUploadAt: Date?
-    private let successCooldown: TimeInterval = 30

     func uploadNow() async -> Bool {
-        if let last = lastSuccessfulUploadAt, Date().timeIntervalSince(last) < successCooldown {
-            return true
-        }
-
-        // Coalesce to avoid overlapping uploads on lifecycle + timer.
         guard !isUploading else { return true }
         isUploading = true
         defer { isUploading = false }
         ...
-        if allSucceeded {
-            lastSuccessfulUploadAt = Date()
-        }
         return allSucceeded
     }
```

**Key design decisions:**
- **`resetUploadTimer()`** invalidates the old timer and creates a fresh 30s timer. Called on start, and after every nudge/lifecycle event.
- **Nudge = immediate upload + timer reset.** If a nudge fires at T=10s into the timer, the upload happens immediately and the next timer tick is at T+30s (not T+20s).
- **`successCooldown` removed entirely.** The 30s timer interval is the de facto rate limit. Only `isUploading` guard remains to prevent concurrent uploads.
- **Thread safety:** All observers use `queue: .main`, so `resetUploadTimer()` always runs on main (where `Timer.scheduledTimer` expects to be called).
- **Timer reset on lifecycle events** is new behavior (old code only called `uploadNow()`). Resetting the timer avoids a redundant timer-triggered upload shortly after a lifecycle upload. Rapid foreground/background cycling would repeatedly push the timer out, but since `uploadNow()` fires immediately on each event, no upload is actually delayed.

---

## Patch 09 — `feature/watch-complication-improvements` (4G / 4H / 4I)

### 4G — Unified `Transferred` log for `updateApplicationContext`

**File:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`

```diff
         do {
             try session.updateApplicationContext(ctx)
             debug(.watchManager, "📦 context_succeeded reading_epoch=\(readingEpoch)")
+            debug(.watchManager, "📤 Transferred new WatchState snapshot via=updateApplicationContext reading_date_epoch_seconds=\(readingEpoch) userinfo_budget_exhausted=\(budgetExhausted) queue_depth=\(session.outstandingUserInfoTransfers.count)")
         } catch {
```

Emits the `📤 Transferred new WatchState snapshot via=...` sentence shape that Better Stack's `transfer_via` extraction rule matches. The `userinfo_budget_exhausted` field is contextual (why this path was taken), not a constraint on this transfer.

---

### 4H — Add `queue_depth` to `complication_budget_check`

**File:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`

```diff
-        debug(.watchManager, "🔍 complication_budget_check remaining=\(budgetSnapshot) isReachable=\(session.isReachable) readingEpochPresent=\(readingEpochPresent) isDuplicate=\(isDuplicateDispatch)")
+        debug(.watchManager, "🔍 complication_budget_check remaining=\(budgetSnapshot) isReachable=\(session.isReachable) readingEpochPresent=\(readingEpochPresent) isDuplicate=\(isDuplicateDispatch) queue_depth=\(session.outstandingUserInfoTransfers.count)")
```

Makes queue depth visible every cycle. Field name `queue_depth` is consistent with existing `📤 Transferred` and `context_attempted` log lines — no aliasing needed in Better Stack queries.

---

### 4I — Skip retry scheduling when snapshot is fresh

**File:** `Trio Watch Shared/TrioComplicationDataStore.swift`

```diff
         if !isRetry {
+            let freshnessThreshold: TimeInterval = 60
+            if let snapshot = latestSnapshot(), Date().timeIntervalSince(snapshot.readingDate) < freshnessThreshold {
+                let age = String(format: "%.1f", Date().timeIntervalSince(snapshot.readingDate))
+                log("⏭️ Retry skipped: snapshot fresh (age=\(age)s < \(Int(freshnessThreshold))s)")
+                return
+            }
             scheduleRetryAfterReloadOnMain(minInterval: minInterval)
         }
```

"Fresh" = `Date().timeIntervalSince(snapshot.readingDate) < freshnessThreshold` — the glucose reading timestamp is less than 60 seconds old. When fresh, WidgetKit just rendered current data and the retry is wasted. The regular delivery cycle handles subsequent updates. Threshold is extracted to `freshnessThreshold` so the condition and log line stay in sync. If `latestSnapshot()` returns nil (no snapshot on disk yet), the `if let` falls through to `scheduleRetryAfterReloadOnMain` — the correct behavior.

---

## File Summary

| File | Items | Lines changed |
|------|-------|---------------|
| `WatchLogger.swift` | 4D, 4E | +110 −37 |
| `CloudLogUploadService.swift` | 4F | +23 −15 |
| `CloudLogUploader.swift` | 4F | +0 −10 |
| `AppleWatchManager.swift` | 4G, 4H | +2 −1 |
| `TrioComplicationDataStore.swift` | 4I | +6 −0 |
| **Total** | | **+141 −63** |
