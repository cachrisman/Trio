# Design: Cloud Logging Pipeline — Build Mislabeling & Drain Cleanup

Version: 1.11
Date: 2026-03-13
Status: COMPLETE. Phase 1 deployed (build 137), Phase 2 deployed (build 138). All phases verified in production.

## Problem

Every uploaded log event is stamped with the build number read at **upload time** (`Bundle.main.infoDictionary?["CFBundleVersion"]` in `CloudLogUploader.buildCommonAttributes(platform:)`). Neither watch nor iOS log lines embed the build number at write time, so backlogged lines — written on an older build but uploaded after an upgrade — are attributed to the wrong build in BetterStack. This makes build-scoped queries unreliable and masks regressions.

A secondary problem amplifies the first: complication drain files persist far longer than they should (up to 7 days) because deletion depends on a synchronous ACK round-trip that rarely succeeds. The phone sends proactive `batchAck` messages via `sendMessage(…, replyHandler: nil)` but the watch-side `WCSessionDelegate` (`WatchState.session(_:didReceiveMessage:)`) does not process them for file cleanup. Combined with the 7-day retention cap and 20-file payload limit, stale drain files accumulate and are eventually re-sent with the wrong build number.

## Context / Current State

### Log write → upload pipeline

| Component | Role | Format |
|---|---|---|
| `WatchLogger` (actor) | Watch app log writer + phone sender | `[timestamp] [File.swift:line] function → message battery_context` |
| `ComplicationLogBuffer` (static enum) | Complication extension file writer → App Group `complication_log.txt` | Same as WatchLogger (via `appendToFile`) |
| `SimpleLogReporter` | iOS log writer → `logs/log.txt` | `timestamp [CATEGORY] File.swift - function - line - message` |
| `CloudLogUploader` (actor) | Tails iOS + watch log files, parses, uploads | Reads files written by above; stamps `build` from `Bundle.main` |
| `CloudLogLineParsing` | Parsers: `parseIOS()`, `parseWatch()` | Produces `CloudParsedLogLine` (no `build` field today) |
| `CloudLogUploadService` | 5-min timer + lifecycle triggers → `uploadNow()` | Owns `CloudLogUploader`; registered via DI in `ServiceAssembly` |

### Watch → phone delivery pathways

1. **In-memory flush** (`WatchLogger.flushToPhone()`): joins logs, writes to per-payload file (`watch_log_<UUID>.txt`), sends via `sendMessage` or `transferUserInfo`. ACK deletes the file.
2. **Complication drain** (`WatchLogger.drainComplicationLogs()`): atomically renames `complication_log.txt` to `complication_log.drain.<UUID>.txt`, sends content via `sendLogContentFromFile`. Orphan drain files are retried oldest-first, subject to `maxFileAge` (7d) and `maxPerPayloadFiles` (20).

### Why drain files linger

- `sendMessage` ACK requires: watch reachable, watch app running when reply arrives.
- `transferUserInfo` has no reply channel; phone calls `storePendingAck` and later sends `batchAck` via `sendMessage(…, replyHandler: nil)`.
- On the watch, `WatchState.session(_:didReceiveMessage:)` handles `watchState` and legacy messages but does **not** dispatch incoming `batchAck` for file cleanup. The only cleanup path for drain files is the 7-day retention cap.

### Key architectural constraint

App Group containers are shared among targets on the **same device** (e.g., watch app + complication widget). They are **not** shared between iPhone and Apple Watch. Phone → watch signaling must use WatchConnectivity.

## Constraints / Requirements

- All changes ship in a single build (parser + writer + uploader together). Parser must be backward-compatible with old-format lines (`build` = nil).
- No changes to BetterStack source/team IDs, upload endpoints, complication timeline rendering, WidgetKit reload scheduling, or `avg C` query logic.
- `commonAttributes["build"]` (the `Bundle.main` fallback) must remain for old-format lines.
- `ComplicationLogBuffer` stays a static `enum`; do not refactor to class/struct.
- Drain file cleanup must not depend on App Group UserDefaults shared across devices (impossible).
- Sentinel log lines flow through the normal pipeline (existing format + `[b:BUILD]` token); no special upload path.

## Decision

### Recommended approach

Four coordinated changes, all shipping in one build:

1. **Embed `[b:BUILD]` in every log line at write time.** Each writer caches `Bundle.main` build once. Parsers extract it; uploader uses it when present.
2. **Reduce retention windows + add upgrade-time flush.** `maxFileAge` 7d → 48h, `maxPerPayloadFiles` 20 → 10. Build-change detection triggers immediate drain/upload on both sides.
3. **App launch sentinel lines.** Structured `event=app_launch` / `event=watch_app_launch` messages at launch for BetterStack build-timeline queries.
4. **Fix drain file ACK gap.** Wire `batchAck` dispatch in `WatchState`; add `transferUserInfo`-based confirmation pathway from phone → watch for reliable cleanup without reachability.

### Why this tradeoff

- Embedding build at write time is the only approach that eliminates mislabeling for all backlog scenarios (cross-upgrade, stalled uploads, long-lived drain files).
- Reducing retention and adding upgrade-time flush limits blast radius without requiring perfect ACK delivery.
- The `transferUserInfo` confirmation pathway is preferred over `applicationContext` because it queues individual confirmation messages that survive app termination and are delivered in order. `applicationContext` is latest-state-wins and risks overwriting undelivered confirmations.
- Sentinel lines reuse the existing pipeline and require no upload-side changes; BetterStack queries can reconstruct build timelines with `WHERE message LIKE '%event=app_launch%'`. On iOS, the sentinel uses `debug(.service, ...)` which produces category `service` and prepends `DEV:` to the message; `[DEPLOY]` is a message-level prefix for grep-ability, not a log category.

## Functional behavior

### User flows / triggers

- **Normal operation**: every log line now carries `[b:BUILD]`. Uploader extracts it per-line. No user-visible change.
- **Build upgrade**: on first launch after upgrade, both watch and phone detect the build change and immediately flush/upload backlogs stamped with the *old* build. After this flush, `lastKnownBuild` is updated.
- **Drain file cleanup**: when phone receives a watch log payload, it sends a `watchLogConfirm` confirmation via `transferUserInfo`. The watch processes confirmations when delivered (often on next activation, but can also arrive while running in background/foreground) and deletes the corresponding drain files.

### Data model (conceptual)

**New field on `CloudParsedLogLine`:**
```swift
let build: String? // nil for old-format lines
```

**New log line formats (new token shown in bold context):**
- Watch/complication: `[timestamp] [b:BUILD] [File.swift:line] function → message battery_context`
- iOS: `timestamp [b:BUILD] [CATEGORY] File.swift - function - line - message`

**Build detection storage:**
- Watch: `lastKnownBuild` in watch-local `UserDefaults` (not App Group). Only `WatchLogger.flushPersistedLogs()` needs build-change detection; the complication extension process does not flush or send logs, so cross-process agreement is unnecessary.
- Phone: `lastKnownBuild` in `UserDefaults.standard` (read by `CloudLogUploadService`).

**Drain file confirmation (phone → watch):**
- Phone sends: `{ "type": "watchLogConfirm", "payloadIds": [...] }` via `transferUserInfo`. One confirmation per received payload for simplicity; watch deduplicates.
- Watch receives in `WatchState.session(_:didReceiveUserInfo:)`, deletes matching drain files, optionally maintains a small local "recently confirmed" set (capped at 200, 48h TTL) for idempotency.

**payloadId semantics:**
- For complication drain files, the payloadId equals the UUID from the drain filename: `complication_log.drain.<UUID>.txt` → payloadId = `<UUID>` (derived via `WatchLogger.payloadIdFromDrainFile()`). For in-memory flush payloads, the payloadId is a fresh `UUID().uuidString` assigned at flush time.
- The phone must confirm this exact payloadId (the one it received in the `watchLogs` envelope), not any other identifier.

**Idempotency rules for deletion:**
- Deletion of drain files must tolerate: (a) file already deleted (by retention, `batchAck`, or prior confirmation), (b) multiple confirmations for the same payloadId (duplicate `transferUserInfo` deliveries), (c) overlapping `batchAck` and `watchLogConfirm` for the same payloadId.
- All deletion calls use `do/catch` around `FileManager.default.removeItem`: success → `outcome=deleted`; catch `NSCocoaErrorDomain` code 4 (`NSFileNoSuchFileError`) → `outcome=missing result=ok`; catch other → `outcome=error result=err`. (Phase 1 used `try?`; Phase 2 E1 upgrades to `do/catch` for observability.)
- `removePendingPayload` is also idempotent (removes from array; no error if absent).
- **Pending record safety:** `removePendingPayload` is only called when the corresponding file deletion succeeds (`outcome=deleted` or `outcome=missing`). On `outcome=error`, the pending record is kept so `resendPendingPayloads` can retry on the next activation. This prevents orphaning files that failed to delete.
- **Write-before-send durability:** In `flushToPhone`, the pending record is stored immediately after writing the per-payload file to disk, *before* calling `sendMessage`. This ensures crash recovery: if the app is killed between file write and send completion, `resendPendingPayloads` will find the record and retry. Both the reachable (sendMessage) and unreachable (transferUserInfo) paths follow this order.

### Edge cases

- **Mixed old/new format lines in same file**: parser returns `build: nil` for old lines → uploader falls back to `Bundle.main`. No data loss.
- **Sentinel line logged before CloudLogUploadService starts**: line is written to file; uploaded on next cycle. No special handling needed.
- **Confirmation arrives after drain file already deleted by 48h retention**: deletion attempt is a no-op (file doesn't exist). Idempotent.
- **Watch receives `batchAck` via `sendMessage` AND `watchLogConfirm` via `transferUserInfo` for same payloadId**: both paths attempt deletion; second is a no-op. Safe.
- **`transferUserInfo` queue grows large**: one confirmation per payload keeps messages small; the existing `isProcessed(payloadId)` check in `AppleWatchManager` naturally prevents duplicate confirmations.
- **Bundle.main returns nil for CFBundleVersion**: writers use `"unknown"` fallback. Parser extracts `"unknown"` as the build string.

### Non-functional (perf, privacy, reliability)

- **Performance**: build string is cached once per process lifetime. No per-log-line Bundle lookups. `[b:BUILD]` adds ~10-15 bytes per line; negligible vs. typical line length.
- **Privacy**: build number is already uploaded as a common attribute. No new PII.
- **Reliability**: all changes are additive and backward-compatible. Old-format lines continue to work with `Bundle.main` fallback.

### Observability expectations

- BetterStack queries filtering `build=X` will accurately reflect the build that *wrote* each line, not the build that *uploaded* it.
- `event=app_launch` and `event=watch_app_launch` queries reconstruct build timelines.
- Drain file age distribution should shift from days to hours after deployment.

### Parsing strategy

Both `parseWatch()` and `parseIOS()` should process the header in strict left-to-right order: timestamp bracket → optional `[b:BUILD]` bracket → remaining tokens. The recommended approach is to consume and strip the `[b:...]` token from the header first, then hand the remainder to existing parsing logic unchanged. This avoids modifying existing regexes (category extraction, file/line extraction) and handles backward compatibility naturally — if the token is absent, the header is unmodified.

**Positional safety:** The `[b:...]` check uses a `^`-anchored regex on the remaining text after the timestamp bracket, so it only matches at that fixed position. A `[b:...]` substring appearing in message content (after `→`) is never scanned by the parser. This is why message-body collisions are not a concern — the extraction is positional, not a global search.

The "function" token in watch log lines should be treated as "everything between the file/line bracket and `→`", not matched with a regex requiring `()`. Real function names include `session(_:didReceiveUserInfo:)`, `handle(_:)`, `applicationDidFinishLaunching()`, etc.

### Rollout / backward compatibility

- Ship all four changes in a single build. Parser backward compatibility means a staged rollout is possible but not necessary.
- If staged: parser/uploader support must ship **before or with** the write-format change, never after. Otherwise the new `[b:BUILD]` token would be included in the raw message text without extraction.
- Old clients (pre-change) continue working: their lines lack `[b:BUILD]`, parser returns `nil`, uploader uses `Bundle.main`. No degradation.

## Phase 2: Cleanup Observability

### Problem

Phase 1 implemented drain file cleanup via three code paths (ACK reply, queryAcks, confirm/batchAck) plus retention. However, only one of three active cleanup paths (`deleteFilesForPayloadIds`) logs "Cleaned up", and it fires least frequently (requires `watchLogConfirm`/`batchAck` delivery from phone). The most common path (ACK reply) logs different text ("Logs ACK received"), and the queryAcks path logs nothing at all. Retention deletions are also silent. This makes it impossible to verify cleanup is working via BetterStack queries.

### Decision

Add a unified `[CLEANUP]` event schema across all deletion paths, a daily `[INVENTORY]` health check, and inline metrics on existing log lines. Additionally, enhance the watch debug view (on the complication improvements branch) with a LOG FILES section showing file counts and sizes.

### Event schema: `[CLEANUP]`

Two distinct event shapes:

**Single-delete shape** (one artifact per event):
```
⌚️ [CLEANUP] path=<path> flow=<flow> artifact=<type> payloadId=<id> outcome=<deleted|missing> result=<ok|err> [error=<short>]
```

**Batch/retention shape** (multiple artifacts per event):
```
⌚️ [CLEANUP] path=<path> artifact=<type> count=<n> [deleted=<n> remaining=<n> oldest_age_hours=<h>] [sample_ids=<id1>|<id2>|<id3>] result=<ok|err>
```

Key fields:
- `path`: `ack_reply` | `query_acks` | `confirm` | `retention` — which code path triggered deletion
- `flow`: `flush` | `resend` | `drain` — discriminates the 3 ACK reply sites (only for `path=ack_reply`)
- `artifact`: `watch_log` | `drain` | `pending_record` — artifact type (file or UserDefaults record)
- `payloadId`: for single-delete events only (never multi-value)
- `outcome`: `deleted` | `missing` — for single-delete events only; distinguishes actual cleanup from idempotent no-ops
- `count`: for batch events; `deleted`/`remaining`/`oldest_age_hours` for retention events
- `sample_ids`: pipe-delimited, max 3 IDs — for batch confirm events only (optional, bounded)
- `result`: `ok` | `err` — whether operation succeeded
- `error`: sanitized token (≤50 chars, no spaces/newlines) — present only on failure. For `NSError`, prefer `<domain>_<code>`. Never emit raw `localizedDescription`

**Canonical per-path field mapping:**

| `path` | Required fields | Optional fields | Never present |
|--------|----------------|-----------------|---------------|
| `ack_reply` | `flow`, `artifact`, `payloadId`, `outcome`, `result` | `error` | `count`, `deleted`, `remaining`, `oldest_age_hours`, `sample_ids` |
| `query_acks` | `artifact`, `count`, `result` | `error` | `flow`, `payloadId`, `outcome`, `deleted`, `remaining`, `oldest_age_hours`, `sample_ids` |
| `confirm` | `artifact`, `count`, `result` | `sample_ids`, `error` | `flow`, `payloadId`, `outcome`, `deleted`, `remaining`, `oldest_age_hours` |
| `retention` | `artifact`, `deleted`, `remaining`, `oldest_age_hours`, `result` | `error` | `flow`, `payloadId`, `outcome`, `count`, `sample_ids` |

**Artifact type separation:** The `confirm` path emits one `[CLEANUP]` event per artifact type (`watch_log`, `pending_record`, `drain`) so partial failures are attributable. For `ack_reply` paths, file deletion and associated pending record removal are treated as a single atomic operation — `artifact=` reflects the primary artifact (the file).

Stable tags (`[CLEANUP]`, `[INVENTORY]`) enable simple BetterStack substring queries independent of surrounding message format.

### Event schema: `[INVENTORY]`

```
⌚️ [INVENTORY] watch_logs_count=3 watch_logs_bytes=12288 drains_count=2 drains_bytes=8192 pending_count=5
```

- Rate-limited to once per 24 hours (UserDefaults timestamp check)
- Dual trigger: `flushPersistedLogs()` + `flushToPhone()` — best-effort daily when the watch app runs at least once per day
- Uses file attribute metadata for sizes (never reads file contents)

### Inline metrics

Existing flush/ack log lines enriched with cached file counts (`pending=<n> drains=<n>`). Counts managed via `updateCachedCountsIfStale()` with a 10-second TTL — recomputed only when stale, so ACK-driven log lines outside the flush cycle get reasonably fresh counts without per-event directory scans.

### Watch debug view

New "LOG FILES" section in `ComplicationDebugView` showing:
- Watch log files: count + total bytes (from `Documents/logs/watch_log_*.txt`)
- Drain files: count + total bytes (from shared container `logs/complication_log.drain.*.txt`)
- Pending payloads: count (from WatchLogger pending records)

Data loaded asynchronously into `@State` on view appear. No filesystem access during SwiftUI body recomputation. In-flight guard (`isLoadingLogFiles`) disables refresh button during load to prevent overlapping scans.

### Performance constraints

- File sizes via `FileAttributeKey.size` metadata, never `Data(contentsOf:)`
- WatchLogger is an actor — all filesystem access runs on its serial queue (off-main)
- Inline metrics via `updateCachedCountsIfStale()` with 10s TTL — no per-event directory scans
- Debug view loads data async into `@State` with in-flight guard; no IO during body recompute

### Branch strategy

- E1–E3 on `feature/cloud-logging` → patch 06
- E4 on `feature/watch-complication-improvements` → patch 09
- **Coordination:** E4 depends on `WatchLogger.shared.getPendingPayloads()` and directory layout. E1–E3 don't change these APIs, but if they did, E4 would need rebasing. Commit E1–E3 and regenerate patch 06 before implementing E4.

## Alternatives considered (and why rejected)

| Alternative | Why rejected |
|---|---|
| **Stamp build only at upload time with offset-based heuristics** | Unreliable; can't determine which build wrote a line if multiple upgrades occurred between uploads. |
| **Use App Group UserDefaults for phone → watch cleanup signaling** | App Group containers are not shared across devices. Would silently fail. |
| **Use `applicationContext` for confirmations** | Latest-state-wins semantics risk overwriting undelivered confirmations. `transferUserInfo` preserves delivery order. |
| **Refactor `ComplicationLogBuffer` to a class for init-time caching** | Unnecessary; `private static let` achieves the same result without changing the type's API surface or concurrency model. |
| **Add build detection + flush to `SimpleLogReporter`** | `SimpleLogReporter` is a pure file writer with no uploader reference. Build-change flush belongs in `CloudLogUploadService` which owns the upload timer and `CloudLogUploader`. |
| **Handle `batchAck` in `WatchLogger`** | `WatchLogger` is not the `WCSessionDelegate`. The delegate is `WatchState`; dispatch must originate there. |

## Risks / Open questions

| Risk | Mitigation |
|---|---|
| `transferUserInfo` queue saturation if phone processes many payloads rapidly | One confirmation per payload; each message is small. The existing `isProcessed(payloadId)` check prevents duplicate processing, so duplicate confirmations are naturally avoided. If queue depth becomes a concern, batch into fewer messages in a future iteration. |
| Watch may not receive confirmations for extended periods | 48h retention backstop deletes stale drain files regardless of confirmation delivery. Confirmations are delivered opportunistically (foreground, background, or activation); prolonged inactivity is the edge case, not the norm. |
| Regex change in parsers could break on unexpected line formats | Backward-compatible: new token is optional. Existing tests (if any) continue passing. New test cases cover both old and new formats. |
| `lastKnownBuild` comparison races with concurrent flush | Build comparison + `lastKnownBuild` update is the first operation in the flush path, before any async work. Set-then-proceed is safe. |

## Success criteria (verifiable)

1. New-format lines from all three writers contain `[b:BUILD]` in the correct position.
2. `parseWatch()` and `parseIOS()` extract `build` from new-format lines and return `nil` for old-format lines.
3. `CloudLogUploader` uses `parsed.build` when present; falls back to `Bundle.main` when `nil`.
4. After a simulated build upgrade, backlogged lines in BetterStack carry the old (correct) build number.
5. `maxFileAge` is 48h and `maxPerPayloadFiles` is 10.
6. Incoming `batchAck` on the watch triggers drain file deletion (wired in `WatchState`).
7. Phone sends `watchLogConfirm` via `transferUserInfo` after processing watch log payloads.
8. Watch consumes confirmations and deletes drain files without requiring live reachability.
9. `event=app_launch` and `event=watch_app_launch` are findable in BetterStack.

## Changelog

### v1.11 (2026-03-13)
- **Project complete.** Phase 1 deployed build 137, Phase 2 deployed build 138. All features verified in BetterStack (events flowing, pending files draining). Moved to `docs/completed/`.

### v1.10 (2026-03-13)
- Write-before-send durability: `flushToPhone` reachable path now stores pending record before `sendMessage` (was only in errorHandler). Crash between file write and callback no longer orphans the file.

### v1.9 (2026-03-13)
- `outcome` field extended to `deleted | missing | error` — on unexpected `removeItem` errors, `outcome=error` (not `deleted`).
- Pending record safety: `removePendingPayload` only called after successful file deletion; prevents orphaning files on failure.
- Status updated to reflect Phase 2 implementation.

### v1.8 (2026-03-13)
- Parsing strategy: added positional safety note — `[b:...]` regex is `^`-anchored after timestamp, not a global search.
- Idempotency rules: updated from `try?` to `do/catch` with `NSFileNoSuchFileError` catch for `outcome=missing` determination (Phase 2 E1 upgrade).
- Branch strategy: added E4 cross-branch coordination note.

### v1.7 (2026-03-13)
- Error field sanitization: `error=` must be a machine-parseable token (≤50 chars, no spaces/newlines); never raw `localizedDescription`.
- Confirm path emits per-artifact-type events for partial-failure attribution.
- Documented `ack_reply` file+record atomic pairing.

### v1.6 (2026-03-12)
- Phase 2 schema tightening: renamed `file=` to `artifact=`, defined explicit single-delete vs batch event shapes, added canonical per-path field mapping table, replaced multi-ID `payloadId` with bounded `sample_ids=`, added `outcome=deleted|missing` sub-field, defined `updateCachedCountsIfStale()` with 10s TTL, added debug view in-flight guard.

### v1.5 (2026-03-12)
- Added Phase 2: Cleanup Observability section — unified `[CLEANUP]` event schema, daily `[INVENTORY]` health check, inline metrics, watch debug view LOG FILES section.
- Documented performance constraints (metadata-only file sizes, actor isolation, cached counts, async @State loading).
- Documented branch strategy for Phase 2 (E1–E3 on cloud-logging, E4 on watch-complication-improvements).
- Status changed from "Proposed" to "Phase 1 implemented, Phase 2 proposed".

### v1.4 (2026-03-12)
- Edge cases: aligned `transferUserInfo` queue entry to use `isProcessed(payloadId)` language (was still using stale "phone deduplicates to avoid resending" phrasing from pre-v1.3).

### v1.3 (2026-03-12)
- Risks table: replaced "phone deduplicates (skips if already confirmed)" with precise explanation — existing `isProcessed(payloadId)` check prevents duplicate processing, so duplicate confirmations are naturally avoided.

### v1.2 (2026-03-12)
- Unified confirmation policy to one-per-payload everywhere: removed stale "cap 50 IDs per message" from edge cases and risks table.
- Clarified watch delivery timing in risks table: confirmations are opportunistic (foreground/background/activation), not activation-gated.

### v1.1 (2026-03-12)
- Clarified `transferUserInfo` delivery timing: processed when received, not only at activation.
- Added "Parsing strategy" section: ordered tokenization, strip `[b:...]` first, function token = everything before `→`.
- Clarified `lastKnownBuild` storage: watch-local UserDefaults only; complication process doesn't need it.
- Added explicit payloadId semantics (drain file UUID) and idempotency rules for deletion.
- Fixed sentinel description: iOS sentinel uses `debug(.service, ...)` → category is `service`, message includes `DEV:` prefix; `[DEPLOY]` is a message-level prefix, not a log category.
- Committed to one-per-payload confirmation strategy for simplicity.

### v1.0 (2026-03-12)
- Initial version. Covers build mislabeling root cause analysis, embedded-build design, parser/uploader override, upgrade-time flush, sentinel logs, and WatchConnectivity-based drain file confirmation pathway.
