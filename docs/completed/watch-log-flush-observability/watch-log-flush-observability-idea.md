# Backlog: Watch log flush UX + phone upload trigger + truncation observability

**Version:** v2  
**Status:** Shipped (build 143) — see `01-*-design.md`, `02-*-implementation-plan.md`, `03-*-implementation-log.md`  
**Created:** 2026-03-19 22:17 CET  
**Last updated:** 2026-03-21 14:26 CET

---

## 1. Problem / goal

Watch logs reach the iPhone via `WatchLogger` (`sendMessage` when reachable, else `transferUserInfo`) and are appended to `watch_log.txt` on the phone. Better Stack uploads are driven only by `CloudLogUploadService` (foreground/background + **5-minute timer**), so flushed watch logs can sit on disk for minutes before upload.

Separately, **`WatchLogger.flushToPhone()` silently truncates** joined in-memory logs to **16 KB** per payload with **no marker** — under burst logging (e.g. flush at 100 entries with long lines), tail lines can be dropped without any signal in Better Stack or local files.

This backlog item bundles three improvements:

1. **Watch debug screen** — Replace the **Burst Save x14** test action with a **Flush logs** action that uses the existing watch-side flush APIs (no dependency on new phone code for “get logs off the watch”).
2. **Phone-side upload nudge** — After watch log payloads are appended on the phone, **trigger** `CloudLogUploadService.uploadNow()` (subject to existing token/config guards and uploader cooldown) so Better Stack sees fresh watch lines sooner.
3. **Truncation observability** — When size caps trim payload content, **log structured, countable signals** (bytes/lines before/after, cap name) so investigations can confirm or rule out silent loss.

---

## 2. Context (code touchpoints)

| Area | Location (Trio app repo) | Notes |
|------|--------------------------|--------|
| Watch debug UI | `Trio Watch App Extension/Views/ComplicationDebugView.swift` | Today: **Burst Save x14** → `runBurstSaveTest()` (14× `dataStore.save` for debounce testing). |
| Watch flush | `Trio Watch App Extension/WatchLogger.swift` | `flushIfNeeded(force:)`, `flushPersistedLogs()` (drains complication log file + pending payload retry path). |
| Phone receive | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | `watchLogs` → `SimpleLogReporter.appendToWatchLog(_:)`. |
| Cloud upload | `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift` | `uploadNow()`; lifecycle + 5 min timer today. |
| Complication file buffer | `Trio Watch Shared/ComplicationLogBuffer.swift` | File cap already emits `[dropped N lines]` on truncate. |
| Drain send path | `WatchLogger.sendLogContentFromFile` | Uses **64 KB** cap with `[truncated]` marker; differs from **16 KB** in-memory flush cap. |

Implementation lives in the **Trio** worktree / patch stack; this doc is tracking only in **Trio-dev** `docs/backlog/`.

---

## 3. Proposed work

### 3.1 Watch debug screen: “Flush logs” instead of “Burst Save x14”

- **Remove or relocate** the burst-save test from the primary ACTIONS row if it is no longer the default debug action (option: keep behind a secondary control or remove entirely if superseded by automated tests).
- **New button:** e.g. **Flush logs** (icon e.g. `arrow.up.doc` or `paperplane`).
- **Behavior (async):**
  - `await WatchLogger.shared.flushIfNeeded(force: true)` — push in-memory buffer to phone (or queue).
  - `await WatchLogger.shared.flushPersistedLogs()` — drain complication log file + retry pending payloads per existing logic.
  - Optional: one **forced** `log(..., force: true)` line such as `⌚️ DEBUG manual flush requested` so the flush itself is visible in the next payload.
- **Confirmation copy:** Clarify that delivery depends on reachability / background WC; “check phone logs / Better Stack” not instantaneous for cloud.

**Acceptance:** Tapping the control does not call `TrioComplicationDataStore.save` in a loop; it only exercises logging/drain paths.

### 3.2 Phone: notification (or equivalent) to trigger `uploadNow()` after watch logs land

- **Define a single notification name**, e.g. `Notification.Name.trioWatchLogsAppended` (exact name to be chosen at implementation; document in code comment).
- **Post** from the central `watchLogs` handling path in `AppleWatchManager` **after** `SimpleLogReporter.appendToWatchLog` succeeds (all code paths: `didReceiveMessage` with reply, without reply, `didReceiveUserInfo`, including envelope + legacy formats if still used).
- **Observe** in `CloudLogUploadService.start()`: on notification, call `uploadNow()` on the **main** queue (or the same queue `uploadNow` already expects).
- **Constraints to preserve:**
  - Respect existing `tokenProvider` / `ingestionURLProvider` guards (no-op if disabled).
  - `CloudLogUploader` already has **30s success cooldown** and coalesces overlapping runs — acceptable; no need to bypass.
  - Avoid feedback loops: posting must not run on every unrelated log line — only when a **watch log payload** is appended.

**Acceptance:** After a watch flush reaches the phone, the next upload attempt can run without waiting for the 5-minute timer (still subject to cooldown and config).

### 3.3 Log truncation: explicit logging when caps cut content

**3.3.1 `WatchLogger.flushToPhone()` — 16 KB `logSizeCap`**

- Before truncation: compute `originalUTF8Count`, `lineCount` (or approximate).
- If `originalUTF8Count > logSizeCap`:
  - Emit a **single** structured log line **before** clearing the buffer, e.g.  
    `⌚️ log_flush_truncated cap_bytes=16384 original_bytes=<n> lines_total=<n> lines_estimated_kept=<n> payload_id=<uuid>`  
    (exact fields negotiable; must be grep-friendly in Better Stack.)
  - Consider **splitting into multiple payloads** in a follow-up if truncation remains common (out of scope for minimal change; note as future).

**3.3.2 Align mental model with drain path**

- Document in code comment that **in-memory flush** uses 16 KB and **drain file send** uses 64 KB + `[truncated]` — intentional asymmetry unless unified.

**3.3.3 Optional: retention / file-cap warnings**

- When `maxPerPayloadFiles` or `maxFileAge` pruning deletes files, consider a **rate-limited** warning log (avoid spam) so near-cap conditions (e.g. 18/20 files) are explainable from logs.

**Acceptance:** Any silent byte-level truncation of the in-memory flush payload produces at least one explicit log line with cap identity and size metrics.

---

## 4. Risks / non-goals

- **Better Stack ingestion filter** (`CloudLogUploader.applyIngestionFilter`) still drops/throttles some **phone-ingested** lines for volume — unrelated to watch→phone delivery; do not confuse with truncation on the watch.
- **WatchConnectivity** payload limits: if Apple rejects oversize `userInfo`, that is a separate failure mode from in-app 16 KB cap; truncation logging does not replace WC error handling.
- **Burst save regression testing:** If the burst test is removed from the UI, ensure debounce/`burst_window_id` behavior is still covered elsewhere (unit/UI test or rare debug gesture).

---

## 5. Suggested implementation order

1. Truncation logging (low risk, improves forensics immediately).
2. Notification + `CloudLogUploadService` observer (phone-only, small surface).
3. Watch debug **Flush logs** button (user-facing; depends on product preference for keeping burst test).

---

## 6. References

- Prior discussion: watch flush APIs, phone upload scheduling, 16 KB vs 64 KB caps, `watch_log_files=` inline metrics (patch `06-cloud-logging` / logging-fixes work).
- Related backlog: `docs/backlog/notif-complication-refresh/` (different feature — notification-driven complication refresh).

---

## Changelog

### v2 (2026-03-21 14:26 CET)
- Status updated from Backlog to Shipped (build 143). Added references to full design, implementation plan, and implementation log docs.
- Reason: all three proposed items (§3.1, §3.2, §3.3.1) shipped in build 143. §3.3.3 (retention/file-cap warnings) was not implemented and is tracked as a follow-up.

### v1 (2026-03-19 22:17 CET)
- Initial backlog idea: watch debug **Flush logs**, `NotificationCenter` hook to call `CloudLogUploadService.uploadNow()` after `appendToWatchLog`, and explicit logging for in-memory flush truncation (16 KB) plus optional retention warnings.
