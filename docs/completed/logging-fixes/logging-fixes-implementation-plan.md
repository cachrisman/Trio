# Implementation Plan: Cloud Logging Pipeline — Build Mislabeling & Drain Cleanup

Version: 1.14
Date: 2026-03-13
Status: COMPLETE. Phase 1 (A–D) deployed build 137. Phase 2 (E + A3b) deployed build 138. All phases verified in production.
Design reference: `docs/completed/logging-fixes/logging-fixes-design-doc.md`

## Scope

- Embed `[b:BUILD]` token in every log line at write time (WatchLogger, ComplicationLogBuffer, SimpleLogReporter).
- Update parsers (`parseWatch`, `parseIOS`) and uploader to extract and use embedded build.
- Reduce drain file retention (48h / 10 files) and add upgrade-time flush on both watch and phone.
- Add app launch sentinel log lines on both platforms.
- Wire `batchAck` dispatch in `WatchState` and add `transferUserInfo`-based confirmation pathway for drain file cleanup.
- Cache `DateFormatter` in `SimpleLogReporter` (deferred performance fix from Phase A).
- **(Phase 2)** Unified cleanup observability: `[CLEANUP]` tags on all deletion paths, daily `[INVENTORY]` log, inline metrics, retention summaries, watch debug view LOG FILES section.

## Out of scope

- BetterStack source/team IDs, upload endpoints, auth configuration.
- Complication timeline rendering, WidgetKit reload scheduling.
- `avg C` query logic.
- Refactoring `ComplicationLogBuffer` from enum to class/struct.
- Changes to `SimpleLogReporter`'s upload capability (it has none; upload-side logic stays in `CloudLogUploadService`).

## Dependencies

- All writers, parsers, and uploader changes ship together in the same build.
- No external library dependencies.
- `WatchState.swift` is the watch-side `WCSessionDelegate`; all WatchConnectivity dispatch changes go there.
- `CloudLogUploadService` is resolved via DI in `ServiceAssembly`; build-change detection hooks into its `init()` or `start()`.

## Sequencing + ship boundaries

### Phase list
- Phase A: Embed build + parser/uploader support — **✅ complete** (A1–A7 implemented, A3b pending) — shippable? yes (backward-compatible; old-format lines fall back to `Bundle.main`)
- Phase B: Retention reduction + upgrade-time flush — **✅ complete** — shippable? yes (standalone safety improvement)
- Phase C: App launch sentinels — **✅ complete** — shippable? yes (additive log lines, no behavioral change)
- Phase D: Drain file ACK fix — **✅ complete** — shippable? yes (improves cleanup; 48h retention from Phase B is the backstop)
- Phase E: Cleanup observability — **✅ complete** (deployed build 138) — shippable? yes (additive logging/UI only)

Phases A–D shipped in build 137 (2026-03-12). Phase E + A3b shipped in build 138 (2026-03-13). All phases verified in production.

## Shared conventions

- This plan conforms to: n/a (no `standards-observability.md` exists yet)
- Any plan-specific deviations: none

---

## Phase A: Embed build in log lines + parser/uploader support — ✅ Complete (A3b pending)

**Status:** Tasks A1–A7 implemented and committed on `feature/cloud-logging` (2026-03-12). Deployed as build 137. Task A3b (dateFormatter caching) is pending — ships with Phase E.
**Ship gate:** safe to ship alone? yes — parser is backward-compatible; uploader falls back to `Bundle.main` for old-format lines.
**Rollback:** revert the commit. Old-format lines continue working. No persistent state changes.

### Task A1 — Cache build number in WatchLogger

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Add a stored property that caches the build string once at init time.
- Steps:
  1. Read the file and locate the `private init()` and property declarations (lines 8-28).
  2. Add `private let build: String` initialized from `Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"` in the property declaration (using a default value or in `init`).
  3. In `log()` (line 114), change the entry format from:
     `"[\(timestamp)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)"`
     to:
     `"[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)"`
- Acceptance:
  - A log line from `WatchLogger.log()` contains `[b:BUILD]` between the timestamp and file tokens.
  - `build` property is read once, not per-call.
- Observability checks: search BetterStack for `[b:` in watch log lines after deployment.
- Notes / pitfalls:
  - `WatchLogger` is an `actor` with `static let shared = WatchLogger()`. The `private init()` runs once per process. Safe to cache build there or as a default-initialized `let`.
  - Keep the Unicode arrow `→`. Do not change to `->`.

### Task A2 — Cache build number in ComplicationLogBuffer

- Files: `Trio Watch Shared/ComplicationLogBuffer.swift`
- Change: Add a `private static let build` and inject `[b:BUILD]` into the file-append format string.
- Steps:
  1. Read the file. Note that `ComplicationLogBuffer` is a static `enum` (line 16). There is no `init`.
  2. Add near the existing static properties (around line 24):
     `private static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"`
  3. In `appendToFile(message:file:line:function:batteryContext:)` (line 225), change the entry format from:
     `"[\(timestamp)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)\n"`
     to:
     `"[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)\n"`
- Acceptance:
  - Lines written to `complication_log.txt` contain `[b:BUILD]` in the correct position.
  - `ComplicationLogBuffer` remains an `enum`.
- Observability checks: drain files forwarded to phone contain `[b:` prefix in each line.
- Notes / pitfalls:
  - `appendToFile` is `#if WIDGET_EXTENSION` only. The `build` static let should be outside the `#if` block (accessible to all targets) but the format change is only inside `appendToFile`.
  - The complication extension has its own `Bundle.main` which should match the watch app build.

### Task A3 — Cache build number in SimpleLogReporter

- Files: `Trio/Sources/Logger/IssueReporter/SimpleLogReporter.swift`
- Change: Add a cached build property and inject `[b:BUILD]` into the iOS log line format.
- Steps:
  1. Read the file. `SimpleLogReporter` is a `final class` (line 4).
  2. Add a stored property:
     `private let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"`
  3. In `log()` (line 45), change the format from:
     `"\(dateFormatter.string(from: now)) [\(category)] \(file.file) - \(function) - \(line) - \(message)\n"`
     to:
     `"\(dateFormatter.string(from: now)) [b:\(build)] [\(category)] \(file.file) - \(function) - \(line) - \(message)\n"`
- Acceptance:
  - iOS log lines in `logs/log.txt` contain `[b:BUILD]` immediately after the timestamp.
- Observability checks: search BetterStack for `[b:` in iOS log lines after deployment.
- Notes / pitfalls:
  - `SimpleLogReporter` is a plain class, not an actor. `build` as a `let` is safe for concurrent reads.
  - The `dateFormatter` computed property (lines 7-11) is re-created every call — fixed in Task A3b below.

### Task A3b — Cache dateFormatter in SimpleLogReporter — ⏳ Pending

- Files: `Trio/Sources/Logger/IssueReporter/SimpleLogReporter.swift`
- Change: Convert the `dateFormatter` computed property to a `private static let` so the formatter is created once per process instead of on every `log()` call.
- Steps:
  1. Replace the computed property (lines 8-12):
     ```swift
     private var dateFormatter: DateFormatter {
         let dateFormatter = DateFormatter()
         dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
         return dateFormatter
     }
     ```
     with a static stored property:
     ```swift
     private static let dateFormatter: DateFormatter = {
         let formatter = DateFormatter()
         formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
         return formatter
     }()
     ```
  2. Update the call site in `log()` (line 46) from `dateFormatter.string(from: now)` to `SimpleLogReporter.dateFormatter.string(from: now)`.
- Acceptance:
  - `DateFormatter` is allocated once per process, not per `log()` call.
  - Log line timestamps are identical in format (verify the format string is unchanged).
- Notes / pitfalls:
  - `DateFormatter` is thread-safe on iOS 7+ / macOS 10.9+ (Apple documentation). A static `let` shared across concurrent `log()` calls is safe.
  - `SimpleLogReporter` is a `final class`, not an actor. `log()` may be called from multiple threads. The static `let` is initialized exactly once via Swift's thread-safe lazy initialization for static properties.
  - This is a performance fix, not a functional change. Every `log()` call currently allocates and initializes a new `DateFormatter`, which is expensive (locale/calendar setup, thread-local caches). On high-frequency logging paths, this contributes to unnecessary CPU and memory pressure.
- Ships with: Phase E work on `feature/cloud-logging` branch.

### Task A4 — Add `build` field to CloudParsedLogLine

- Files: `Trio/Sources/Logger/CloudLogging/CloudLogLineParsing.swift`
- Change: Add `let build: String?` to `CloudParsedLogLine`.
- Steps:
  1. Read the file. `CloudParsedLogLine` is a struct (line 8).
  2. Add `let build: String?` to the struct (e.g., after `source`).
  3. Update all existing call sites that construct `CloudParsedLogLine` to pass `build: nil` — there are two in `parseIOS()` (lines 84, 111) and one in `parseWatch()` (line 203). Verify no other constructors exist.
- Acceptance:
  - Code compiles. Existing call sites pass `build: nil`.
- Notes / pitfalls:
  - Swift structs use memberwise initializers. Adding a new field without a default value breaks all existing construction sites. Either give it a default (`build: String? = nil`) or update every call site.
  - Using a default value (`= nil`) is simpler and avoids touching call sites that don't yet extract build.

### Task A5 — Update parseWatch() to extract [b:BUILD]

- Files: `Trio/Sources/Logger/CloudLogging/CloudLogLineParsing.swift`
- Change: After extracting the timestamp from the first `[...]` bracket, check if the next token is `[b:...]`. If so, extract the build string; otherwise leave `build = nil`.
- Steps:
  1. In `parseWatch()` (line 125), after the timestamp extraction block (lines 134-139):
     - Determine the remaining header text after the timestamp bracket.
     - Check for a `[b:...]` token using a regex like `^\[b:([^\]]+)\]` on the remaining text.
     - If matched, capture the build string and advance past the token for subsequent parsing.
     - If not matched, set `build = nil` and leave subsequent parsing unchanged.
  2. Pass the extracted `build` to the `CloudParsedLogLine` constructor (line 203).
- Acceptance:
  - `parseWatch("[2026-03-12T10:00:00+0000] [b:42] [Foo.swift:10] bar() → msg battery_level_percent=85 battery_state=unplugged")` returns `build: "42"`, method: `bar`.
  - `parseWatch("[2026-03-12T10:00:00+0000] [b:42] [WatchState.swift:286] session(_:didReceiveUserInfo:) → Received userInfo battery_level_percent=92 battery_state=charging")` returns `build: "42"`, method: `session(_:didReceiveUserInfo:)`.
  - `parseWatch("[2026-03-12T10:00:00+0000] [Foo.swift:10] bar() → msg battery_level_percent=85 battery_state=unplugged")` returns `build: nil`.
  - Additional real codebase signatures that must parse correctly:
    - `applicationDidFinishLaunching()` → method: `applicationDidFinishLaunching`
    - `handle(_:)` → method: `handle(_:)`
    - `flushIfNeeded(force:)` → method: `flushIfNeeded(force:)`
- Notes / pitfalls:
  - The `[b:BUILD]` token uses the same `[...]` bracket syntax as `[File.swift:line]`. The parser must differentiate by the `b:` prefix before consuming the token.
  - The existing `fileLineRegex` (line 155) matches `[File.swift:line]` by requiring `.swift:` inside the brackets. The `[b:BUILD]` token won't match this regex, so it's safe. But the category extraction (`extractWatchCategory`) also looks for `[...].swift:` — verify it skips `[b:...]` correctly.
  - The simplest approach: consume `[b:...]` first, then strip it from the header before handing to existing parsing. This avoids modifying existing regexes.
  - **Positional safety:** The `^\[b:([^\]]+)\]` regex is anchored (`^`) to the position immediately after the timestamp bracket. It does NOT scan the full line. A `[b:...]` token appearing in message content (after `→`) is never reached by the parser. This is why message-body collisions are not a concern — the check is positional, not a global search.

### Task A6 — Update parseIOS() to extract [b:BUILD]

- Files: `Trio/Sources/Logger/CloudLogging/CloudLogLineParsing.swift`
- Change: After extracting the timestamp token, check if the next token is `[b:...]`. If so, extract build; otherwise `nil`.
- Steps:
  1. In `parseIOS()` (line 23), after the timestamp split (line 32):
     - The remainder (after timestamp) currently starts with ` [CATEGORY] ...`.
     - Check if the remainder starts with ` [b:...]` instead. If so, extract build and re-split to get the category token.
     - If not (old format), leave `build = nil`.
  2. Pass extracted `build` to the `CloudParsedLogLine` constructor (lines 84, 111).
- Acceptance:
  - `parseIOS("2026-03-12T10:00:00+0000 [b:42] [WatchManager] Foo.swift - bar - 10 - DEV: msg")` returns `build: "42"`, `category: "WatchManager"`.
  - `parseIOS("2026-03-12T10:00:00+0000 [WatchManager] Foo.swift - bar - 10 - DEV: msg")` returns `build: nil`, `category: "WatchManager"`.
  - Old-format line without level token: `parseIOS("2026-03-12T10:00:00+0000 [service] TrioApp.swift - setupServices - 84 - some message without level prefix")` returns `build: nil`, level detection falls through to message-based heuristics.
- Notes / pitfalls:
  - The `DEV:` / `INFO:` / `WARN:` / `ERR:` prefix is part of the message content, prepended by `Logger.debug()` / `.info()` / `.warning()` / `.error()` before reaching `SimpleLogReporter.log()`. It is not a separate format element. The parser's level regex `\s-\s([A-Z]+):\s` matches it within the message. Lines logged via other paths may lack a level prefix entirely — the parser must handle both cases (it already does: returns `nil` level and falls through to `detectLevelFromMessage`).
  - The iOS format has `[CATEGORY]` as the first bracketed token after timestamp. With the new format, `[b:BUILD]` comes first. The category regex (line 38) matches `^\S+\s+\[([^\]]+)\]` — this would match `[b:BUILD]` instead of `[CATEGORY]` on new-format lines. Must extract `[b:...]` *before* the category regex runs, or adjust the category regex to skip `[b:...]`.
  - Same approach as A5: strip the `[b:BUILD]` token from the header first, then run existing parsing on the remainder.

### Task A7 — Use parsed.build in CloudLogUploader

- Files: `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift`
- Change: In the event assembly loop inside `uploadNewContent()`, use `parsed.build` when present to override `commonAttributes["build"]`.
- Steps:
  1. In `uploadNewContent()` (line 139), inside the `entries.compactMap` closure:
     - After `let parsed = parser(entry)`, when `parsed` is non-nil:
     - If `parsed.build` is non-nil, set `attrs["build"] = parsed.build`.
  2. Do NOT remove the `build` from `buildCommonAttributes` — it remains the fallback.
- Acceptance:
  - An event from a new-format line carries the embedded build number, not `Bundle.main`.
  - An event from an old-format line (where `parsed.build` is nil) carries `Bundle.main` build.
- Notes / pitfalls:
  - The override must happen per-event inside the loop, not globally. Different lines in the same file may have different builds (e.g., lines written before and after an upgrade in the same `log.txt`).

---

## Phase B: Retention reduction + upgrade-time flush — ✅ Complete

**Status:** Tasks B1–B3 implemented and committed on `feature/cloud-logging` (2026-03-12). Deployed as build 137.
**Ship gate:** safe to ship alone? yes — purely reduces blast radius. Independent of build embedding.
**Rollback:** revert the commit. Retention returns to 7d/20. No persistent state corruption.

### Task B1 — Reduce WatchLogger retention constants

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Adjust two constants.
- Steps:
  1. Change `maxFileAge` (line 17) from `7 * 24 * 60 * 60` to `48 * 60 * 60`.
  2. Change `maxPerPayloadFiles` (line 16) from `20` to `10`.
- Acceptance:
  - `maxFileAge` equals 172800 (48 hours).
  - `maxPerPayloadFiles` equals 10.
- Notes / pitfalls:
  - These constants apply to both per-payload files (in `flushPersistedLogs`) and drain files (in `drainComplicationLogs`). Verify both paths reference the same constants — they do.
  - Also update the `storePendingPayload` cleanup filter (line 421) which uses `7 * 24 * 60 * 60` independently. Change to `48 * 60 * 60` to match, or reference the `maxFileAge` constant.

### Task B2 — Upgrade-time flush on watch

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Detect build change at the start of `flushPersistedLogs()` and log it. Note: `flushPersistedLogs()` already calls `drainComplicationLogs()` as its first operation, so the drain already happens on every flush. The primary value of this task is (a) `lastKnownBuild` bookkeeping for observability, (b) logging the build-change event, and (c) ensuring the drain runs before any early-return paths that might be added in the future.
- Steps:
  1. Add a `UserDefaults` key for `lastKnownBuild` (watch-local `UserDefaults.standard`, not App Group — only `WatchLogger` in the watch app extension process needs build-change detection; the complication extension doesn't flush or send logs).
  2. At the top of `flushPersistedLogs()` (line 234), before `await drainComplicationLogs()`:
     - (a) Read current build from the cached `build` property (from Task A1).
     - (b) Read `lastKnownBuild` from `UserDefaults`.
     - (c) If they differ (or `lastKnownBuild` is nil):
       - Log a message indicating build change detected (e.g., `"[UPGRADE] build changed from \(lastKnownBuild ?? "nil") to \(build)"`).
       - **(d) Write `lastKnownBuild` to `UserDefaults` immediately** — before the drain call. If the process is interrupted during the subsequent drain/flush, the next launch will not redundantly re-trigger build-change logic.
     - If they match: proceed normally (drain still happens via the existing call).
  3. Ensure the logic is idempotent — once `lastKnownBuild` is set, subsequent calls within the same build don't re-trigger.
- Acceptance:
  - On first launch after upgrade, `flushPersistedLogs()` logs a build-change message.
  - `lastKnownBuild` is updated before the drain call.
  - On subsequent calls within the same build, no extra logging or bookkeeping occurs.
- Notes / pitfalls:
  - First-install case: `lastKnownBuild` is nil → treat as "changed" → log + set. This is harmless (drain runs anyway).

### Task B3 — Upgrade-time flush on phone

- Files: `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift`
- Change: Detect build change on initialization and trigger an immediate upload before the first timer tick.
- Steps:
  1. Add a `UserDefaults` key for `lastKnownBuild` (e.g., `"cloudLogUploadService.lastKnownBuild"`).
  2. In `init()` (line 24) or `start()` (line 121), after setting up the timer:
     - Read current build from `Bundle.main.infoDictionary?["CFBundleVersion"]`.
     - Compare to stored `lastKnownBuild`.
     - If different: call `uploadNow()` immediately, then update `lastKnownBuild`.
  3. Ensure this runs before the first 5-minute timer tick.
- Acceptance:
  - On first launch after upgrade, an upload is triggered immediately.
  - `lastKnownBuild` is updated after the upload call.
- Notes / pitfalls:
  - `CloudLogUploadService.init()` calls `start()` which sets up timer and lifecycle observers. The build-change check should happen inside `start()` after observer setup, so lifecycle triggers are wired before the manual upload.
  - `uploadNow()` is a no-op if the token is not configured. Safe to call unconditionally.

---

## Phase C: App launch sentinels — ✅ Complete

**Status:** Tasks C1–C2 implemented and committed on `feature/cloud-logging` (2026-03-12). Deployed as build 137. C2 deviated from plan (see implementation log).
**Ship gate:** safe to ship alone? yes — purely additive log lines. No behavioral change.
**Rollback:** revert the commit. Sentinel lines stop appearing in future builds.

### Task C1 — iOS launch sentinel

- Files: `Trio/Sources/Application/TrioApp.swift`
- Change: Write a structured log line at app launch via `debug(.service, ...)`.
- Steps:
  1. Insertion point: `TrioApp.swift`, in the DI setup path, immediately after `_ = resolver.resolve(CloudLogUploadService.self)!` (line 84). At this point the logging infrastructure is fully initialized.
  2. Add:
     ```swift
     let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
     debug(.service, "[DEPLOY] event=app_launch platform=ios build=\(build)")
     ```
  3. `debug(.service, ...)` is a global function (defined in `Logger.swift` line 12) available throughout the iOS target. It prepends `"DEV: "` to the message, then calls `SimpleLogReporter.log()` with category `"service"`.
- Acceptance:
  - After app launch, BetterStack contains a line matching `event=app_launch platform=ios`.
- Notes / pitfalls:
  - The resulting log line will look like: `2026-03-12T10:00:00+0000 [b:42] [service] TrioApp.swift - setupServices - 84 - DEV: [DEPLOY] event=app_launch platform=ios build=42`. The BetterStack `category` attribute will be `service`, not `DEPLOY`. The `[DEPLOY]` prefix and `event=app_launch` are in the message body, which is what BetterStack queries match on.
  - Do not use `info(...)` — it calls `showAlert()` which would display a user-visible notification on every launch.

### Task C2 — Watch launch sentinel

- Files: `Trio Watch App Extension/ExtensionDelegate.swift`
- Change: Write a structured log line at watch app launch.
- Steps:
  1. In `applicationDidFinishLaunching()` (line 4), after the existing `WatchLogger.shared.log("Watch extension launched", force: true)` call:
     ```swift
     let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
     await WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build)", force: true)
     ```
  2. Or combine with the existing launch log line if preferred.
- Acceptance:
  - After watch app launch, BetterStack contains a line matching `event=watch_app_launch platform=watchos`.
- Notes / pitfalls:
  - `WatchLogger.log()` wraps the message in the standard format with timestamp, `[b:BUILD]`, file/line, arrow, and battery context. The `[DEPLOY]` prefix is part of the message content, not a category bracket. This is fine for BetterStack querying.
  - The `force: true` parameter ensures the sentinel is flushed promptly.

---

## Phase D: Drain file ACK fix — ✅ Complete

**Status:** Tasks D1–D3 implemented and committed on `feature/cloud-logging` (2026-03-12). Deployed as build 137. D2 deviated from plan (see implementation log).
**Ship gate:** safe to ship alone? yes — improves cleanup reliability. 48h retention from Phase B is the backstop.
**Rollback:** revert the commit. Drain files fall back to retention-based cleanup only.

### Task D1 — Handle unsolicited batchAck in WatchState

- Files: `Trio Watch App Extension/WatchState.swift`
- Change: In the `session(_:didReceiveMessage:)` delegate (no-reply-handler variant, line 230), add dispatch for incoming `batchAck` messages.
- Steps:
  1. In `session(_:didReceiveMessage:)`, before the existing `watchState` and legacy message handling:
     - Check if `message["type"] as? String == "batchAck"`.
     - If so, extract `ackIds` from `message["ackIds"] as? [String]`.
     - Call a cleanup helper on `WatchLogger` to delete matching drain files: `await WatchLogger.shared.deleteFilesForPayloadIds(ackIds)`.
     - Log the cleanup: count and a truncated summary of payloadIds.
     - `return` to avoid falling through to watchState processing.
  2. Implement `deleteFilesForPayloadIds(_ ids: [String])` on `WatchLogger`:
     - For each id:
       (a) Check `getPendingPayloads()` for a matching record with `filePath`. Delete the file at `filePath` if it exists (`try? FileManager.default.removeItem` — no-op if missing). Call `removePendingPayload(id)`.
       (b) Check the App Group `logs/` directory (from `ComplicationLogBuffer.sharedContainerURL()?.appendingPathComponent("logs")`) for a drain file matching **exactly** `complication_log.drain.<id>.txt` where `<id>` equals the payloadId. Delete if present. Do not use substring matching or recursive directory scanning — match the exact filename only.
     - All deletions are idempotent: tolerate missing files, duplicate calls, and overlap between `batchAck` and `watchLogConfirm` paths.
- Acceptance:
  - When the phone sends a `batchAck` via `sendMessage(…, replyHandler: nil)` and the watch app is running, the corresponding drain files are deleted.
  - If the files are already deleted, no error occurs.
- Notes / pitfalls:
  - `WatchState.session(_:didReceiveMessage:)` runs on a WatchConnectivity background thread. `WatchLogger` is an actor, so calls are `await`-ed. Always dispatch deletion via `Task { await WatchLogger.shared.deleteFilesForPayloadIds(ackIds) }` and return from the delegate method immediately — do not block the WCSession callback thread while awaiting actor work. Use `Task {}`, NOT `Task.detached {}` — `WatchState` is `@Observable final class WatchState: NSObject, WCSessionDelegate` (a class, not an actor), so `Task {}` does not inherit any actor executor. `Task.detached` would be functionally identical but semantically misleading, implying isolation concerns that don't exist.
  - The existing phone-side `sendPendingAcksIfReachable()` (in `AppleWatchManager`, line 964) sends `batchAck` with `replyHandler: nil` and then immediately clears pending ACKs. This means the phone is fire-and-forget. The watch must tolerate receiving the same `batchAck` payloadIds more than once.

### Task D2 — Phone sends confirmations via transferUserInfo

- Files: `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
- Change: After recording a watchLog payload as processed, send a `watchLogConfirm` message to the watch via `transferUserInfo`.
- Steps:
  1. Locate the `session(_:didReceiveMessage:replyHandler:)` handler where `type == "watchLogs"` payloads are processed (around line 1035). After `recordProcessed(payloadId)`:
     - Accumulate the payloadId for confirmation.
  2. Similarly, in `session(_:didReceiveUserInfo:)` (line 1215) where `type == "watchLogs"` is processed (line 1231): accumulate the payloadId.
  3. After processing, send a confirmation to the watch:
     ```swift
     let confirm: [String: Any] = [
         "type": "watchLogConfirm",
         "payloadIds": [payloadId]
     ]
     session?.transferUserInfo(confirm)
     ```
  4. **Batching policy: one confirmation per received payload.** This is simple, correct, and produces small messages. The watch deduplicates. Do not accumulate or batch across payloads — `transferUserInfo` messages are individually queued and small enough that one-per-payload is not a concern.
  5. Also in `session(_:didReceiveMessage:)` (no-reply-handler variant, around line 1059) where `type == "watchLogs"` is handled: same logic.
- Acceptance:
  - After the phone processes a watchLog payload, `transferUserInfo` is called with a `watchLogConfirm` message.
  - The confirmation includes the payloadId(s).
- Observability checks: phone-side debug log should mention sending `watchLogConfirm`.
- Notes / pitfalls:
  - `transferUserInfo` is queued and delivered eventually. It survives app termination on both sides. Preferred over `sendMessage` for reliability.
  - The phone already calls `recordProcessed(payloadId)` before `storePendingAck`. The confirmation should be sent at the same point.
  - `BaseWatchManager` (the actual class in `AppleWatchManager.swift`) has access to `session` via its `WCSessionDelegate` conformance.

### Task D3 — Watch receives confirmations and cleans up

- Files: `Trio Watch App Extension/WatchState.swift`, `Trio Watch App Extension/WatchLogger.swift`
- Change: Handle incoming `watchLogConfirm` messages in the watch `WCSessionDelegate` and delete confirmed drain files.
- Steps:
  1. In `WatchState.session(_:didReceiveUserInfo:)` (line 286), add a check at the top:
     - If `userInfo["type"] as? String == "watchLogConfirm"`, extract `payloadIds` from `userInfo["payloadIds"] as? [String]`.
     - Call `await WatchLogger.shared.deleteFilesForPayloadIds(payloadIds)` (same helper from Task D1).
     - Log the confirmation processing.
     - `return` to avoid falling through to watchState payload processing.
  2. Optionally, maintain a small "recently confirmed" set in `WatchLogger` (capped at 200 entries, 48h TTL) to handle out-of-order or duplicate deliveries. When a drain file is about to be sent in `drainComplicationLogs()`, skip it if its payloadId is in the recently-confirmed set. This is a nice-to-have optimization, not required for correctness — without it, `drainComplicationLogs()` will attempt to send already-deleted drain files, which harmlessly no-ops at the `guard fm.fileExists` / `guard let data = try? Data(contentsOf:)` checks in `sendLogContentFromFile()`. The phone also deduplicates via `isProcessed(payloadId)`.
- Acceptance:
  - When the phone sends `watchLogConfirm` via `transferUserInfo` and the confirmation is delivered to the watch (foreground, background, or activation), the corresponding drain files are deleted.
  - If files are already gone (deleted by `batchAck` or retention), no error occurs.
  - Works without live reachability — delivery is opportunistic, typically on next activation but may arrive while already running.
- Notes / pitfalls:
  - `session(_:didReceiveUserInfo:)` can receive multiple types of messages: watchState, watchLogConfirm, and legacy watchLogs. The `type` check must be early to avoid interference.
  - The existing `didReceiveUserInfo` handler processes envelope messages (line 1217 in phone, line 286 in watch). On the watch side, ensure `watchLogConfirm` is recognized before the handler tries to treat it as a watchState payload.
  - Same threading rule as D1: dispatch via `Task { await WatchLogger.shared.deleteFilesForPayloadIds(payloadIds) }` and return from the delegate method immediately — do not block the WCSession callback thread.

---

## Phase E: Cleanup Observability — ⏳ Pending

**Status:** Tasks E1–E4 pending. Ships on `feature/cloud-logging` (E1–E3) and `feature/watch-complication-improvements` (E4). Task A3b ships alongside E1–E3.
**Ship gate:** safe to ship alone? yes — additive logging/UI only. No behavioral change to cleanup logic.
**Rollback:** revert the commit. Cleanup continues working silently as before.

### Background

WatchLogger has 5 distinct file deletion sites plus retention-based deletions. Only 3 of 5 log anything, and none use consistent terminology. The most common cleanup path (ACK reply) doesn't log "Cleaned up", making it impossible to query BetterStack for "all cleanup events" or verify that cleanup is functioning. Retention deletions are completely silent.

### Current state: deletion sites in WatchLogger.swift

| Line | What's deleted | Current log | Path |
|------|----------------|-------------|------|
| 152 | `watch_log_*.txt` via flushToPhone ACK reply | "Logs ACK received from phone" | ACK reply (flush) |
| 259 | `watch_log_*.txt` via queryAcks reply | **None** | queryAcks reply |
| 331 | Pending file via resendPendingPayloads ACK | "Resent logs ACK received" | ACK reply (resend) |
| 408/414 | Pending file + drain file via deleteFilesForPayloadIds | "Cleaned up N payload(s)" | confirm/batchAck handler |
| 538 | Drain file via sendLogContentFromFile ACK | **None** | ACK reply (drain) |
| 218/231 | Age/count retention for watch_log files | **None** | Retention |
| 450/457 | Age/count retention for drain files | **None** | Retention |

### Event schema

All cleanup events use the `[CLEANUP]` tag. There are two distinct event shapes:

**Single-delete shape** (one artifact per event):

```
⌚️ [CLEANUP] path=<path> flow=<flow> artifact=<type> payloadId=<id> outcome=<deleted|missing> result=<ok|err> [error=<short>]
```

**Batch/retention shape** (multiple artifacts per event):

```
⌚️ [CLEANUP] path=<path> artifact=<type> count=<n> [deleted=<n> remaining=<n> oldest_age_hours=<h>] [sample_ids=<id1>|<id2>|<id3>] result=<ok|err>
```

| Field | Values | Required by | Purpose |
|-------|--------|-------------|---------|
| `path` | `ack_reply`, `query_acks`, `confirm`, `retention` | All events | Which code path triggered the deletion |
| `flow` | `flush`, `resend`, `drain` | `path=ack_reply` only | Discriminates the 3 ACK reply sites |
| `artifact` | `watch_log`, `drain`, `pending_record` | All events | What type of artifact was deleted (file or UserDefaults record) |
| `payloadId` | UUID string | Single-delete only | Correlates with flush/send log lines |
| `outcome` | `deleted`, `missing`, `error` | Single-delete only | Whether file was removed (`deleted`), already gone (`missing`), or removal failed (`error`) |
| `count` | integer | Batch/retention | How many items were processed |
| `deleted` | integer | `path=retention` only | How many were actually removed |
| `remaining` | integer | `path=retention` only | Files remaining after cleanup |
| `oldest_age_hours` | integer | `path=retention` only | Age of oldest deleted file |
| `sample_ids` | `id1\|id2\|id3` (max 3, pipe-delimited) | `path=confirm` only (optional) | Bounded sample for correlation |
| `result` | `ok`, `err` | All events | Whether the operation succeeded |
| `error` | sanitized token (≤50 chars, no spaces/newlines) | Only when `result=err` | What went wrong; machine-parseable (see sanitization note) |

**Error sanitization:** The `error` field must be a machine-parseable token: replace spaces with underscores, strip special characters, truncate to 50 characters, no newlines. For `NSError`, prefer `<domain>_<code>` (e.g., `NSCocoaErrorDomain_4`). Fallback: sanitize `localizedDescription`. Never emit raw `localizedDescription` — it can contain spaces, quotes, and newlines that break key=value parsing and BetterStack filters. Implement a `sanitizeError(_ error: Error) -> String` helper in WatchLogger.

**Artifact type separation (`confirm` path):** `deleteFilesForPayloadIds` processes multiple artifact types per call (watch_log files, pending records, drain files). To ensure partial failures are attributable, the `confirm` path emits **one `[CLEANUP]` event per artifact type** rather than one combined event. If watch_log deletes succeed but pending record removal fails, the per-type events make this visible.

**Artifact pairing (`ack_reply` paths):** For `ack_reply` paths, the pending record is only removed when file deletion succeeds (including `outcome=missing`). On `outcome=error`, the pending record is **kept** so `resendPendingPayloads` can retry. This prevents orphaning files when deletion fails unexpectedly. The `artifact=` value reflects the primary artifact (the file); no separate `artifact=pending_record` event — the pairing is always 1:1.

**Pending record safety (`confirm` path):** Same principle — `deleteFilesForPayloadIds` only removes the pending record for a given payloadId when the corresponding watch_log file deletion succeeds. If the file delete fails, the record is preserved for retry on the next activation cycle. Drain file deletions are independent of pending records (drain files are tracked by filename convention, not by pending records).

**Canonical per-path field mapping:**

| `path` | Required fields | Optional fields | Never present |
|--------|----------------|-----------------|---------------|
| `ack_reply` | `flow`, `artifact`, `payloadId`, `outcome`, `result` | `error` | `count`, `deleted`, `remaining`, `oldest_age_hours`, `sample_ids` |
| `query_acks` | `artifact`, `count`, `result` | `error` | `flow`, `payloadId`, `outcome`, `deleted`, `remaining`, `oldest_age_hours`, `sample_ids` |
| `confirm` | `artifact`, `count`, `result` | `sample_ids`, `error` | `flow`, `payloadId`, `outcome`, `deleted`, `remaining`, `oldest_age_hours` |
| `retention` | `artifact`, `deleted`, `remaining`, `oldest_age_hours`, `result` | `error` | `flow`, `payloadId`, `outcome`, `count`, `sample_ids` |

**BetterStack query patterns:**
- All cleanup: `LIKE '%[CLEANUP]%'`
- Failures only: `LIKE '%[CLEANUP]%' AND LIKE '%result=err%'`
- By path: `LIKE '%[CLEANUP] path=ack_reply%'`
- By flow: `LIKE '%flow=drain%'`
- Retention activity: `LIKE '%[CLEANUP] path=retention%'`
- No-ops (file already gone): `LIKE '%outcome=missing%'`

### Task E1 — Unified `[CLEANUP]` logging

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Add or update log messages at all deletion sites using the event schema above. Convert `try?` to `do/catch` at deletion sites to capture failures. Add `outcome=deleted|missing` tracking at single-delete sites via attempt-then-catch (not `fileExists` pre-check).

| Site (line) | Current | New |
|-------------|---------|-----|
| 152 (flushToPhone ACK) | "Logs ACK received from phone for payloadId: ..." | `[CLEANUP] path=ack_reply flow=flush artifact=watch_log payloadId=<id> outcome=<deleted\|missing> result=ok` |
| 259 (queryAcks) | **None** | `[CLEANUP] path=query_acks artifact=watch_log count=<n> result=ok` |
| 331 (resend ACK) | "Resent logs ACK received for payloadId: ..." | `[CLEANUP] path=ack_reply flow=resend artifact=<type> payloadId=<id> outcome=<deleted\|missing> result=ok` |
| 408/414 (deleteFilesForPayloadIds) | "Cleaned up N payload(s)" | One `[CLEANUP] path=confirm artifact=<type> count=<n> result=ok` per artifact type (`watch_log`, `pending_record`, `drain`) |
| 538 (drain ACK) | **None** | `[CLEANUP] path=ack_reply flow=drain artifact=drain payloadId=<id> outcome=<deleted\|missing> result=ok` |
| 218/231 (watch_log retention) | **None** | `[CLEANUP] path=retention artifact=watch_log deleted=<n> remaining=<n> oldest_age_hours=<h> result=ok` (only when deleted > 0) |
| 450/457 (drain retention) | **None** | `[CLEANUP] path=retention artifact=drain deleted=<n> remaining=<n> oldest_age_hours=<h> result=ok` (only when deleted > 0) |

- Acceptance:
  - Every deletion site emits a `[CLEANUP]` log line.
  - Failed deletions log `result=err error=<sanitized>` (convert `try?` to `do/catch`; use `sanitizeError()` helper).
  - Single-delete paths report `outcome=deleted` or `outcome=missing` via attempt-then-catch: attempt `removeItem`; success → `outcome=deleted`; catch `NSCocoaErrorDomain` code 4 → `outcome=missing result=ok`; catch other → `result=err`.
  - Retention summary only emits when `deleted > 0`.
  - `confirm` path emits separate events per artifact type (`watch_log`, `pending_record`, `drain`).
  - `ack_reply` paths cover both file and associated pending record in one event (atomic pairing).
  - BetterStack query `LIKE '%[CLEANUP]%'` returns all cleanup events.
- Notes / pitfalls:
  - Retention logs are per-pass summaries, not per-file. One line for watch_log retention, one for drain retention.
  - The `oldest_age_hours` field helps detect whether retention is the only cleanup mechanism firing (suggests ACK/confirm paths are broken).
  - The `outcome=missing` case is informational, not an error. It means an earlier path (retention, ACK, or confirm) already cleaned up the file. Frequent `outcome=missing` on the `confirm` path is expected and healthy — it means ACK replies are working.

### Task E2 — Daily `[INVENTORY]` log

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Add `logFileInventory()` function, rate-limited to once per 24 hours, that logs file counts and sizes.
- Format:
  ```
  ⌚️ [INVENTORY] watch_logs_count=3 watch_logs_bytes=12288 drains_count=2 drains_bytes=8192 pending_count=5
  ```
- Steps:
  1. Add `private let lastInventoryKey = "WatchLogger.lastInventoryTimestamp"` constant.
  2. Implement `logFileInventory()`:
     - Check `UserDefaults.standard.double(forKey: lastInventoryKey)`. Skip if < 24 hours elapsed.
     - Scan `Documents/logs/` for `watch_log_*.txt` files: count + sum of `FileAttributeKey.size`.
     - Scan `ComplicationLogBuffer.sharedContainerURL()/logs/` for `complication_log.drain.*.txt`: count + sum of sizes.
     - Count pending payload records from `getPendingPayloads()`.
     - Emit structured log line.
     - Update `lastInventoryTimestamp`.
  3. Call from `flushPersistedLogs()` (runs on app activation) and `flushToPhone()` (runs on flush timer) — best-effort daily when the watch app runs at least once per day.
- Acceptance:
  - Inventory log appears approximately once per day in BetterStack.
  - BetterStack query `LIKE '%[INVENTORY]%'` returns daily snapshots.
  - File sizes computed from metadata attributes, never from reading file contents.
- Notes / pitfalls:
  - WatchLogger is an actor — all filesystem access runs on its serial queue (already off-main).
  - `flushPersistedLogs` runs when the watch app becomes active and on various error paths. `flushToPhone` runs on the 3-minute flush timer. Between the two, daily coverage is best-effort. If the watch app isn't opened for an extended period, inventory won't run — acceptable since there's nothing to observe.
  - Use `FileAttributeKey.size` (metadata read), not `Data(contentsOf:)` (content read).

### Task E3 — Inline metrics on existing log lines

- Files: `Trio Watch App Extension/WatchLogger.swift`
- Change: Enrich existing flush/ack log lines with cached file counts for passive observability. Define cache lifecycle with TTL-based staleness.
- Steps:
  1. Add actor properties: `private var cachedPendingCount: Int = 0`, `private var cachedDrainsCount: Int = 0`, `private var cachedCountsTimestamp: Date = .distantPast`.
  2. Implement `updateCachedCountsIfStale()`:
     - If `Date().timeIntervalSince(cachedCountsTimestamp) < 10` (10-second TTL), return immediately.
     - Otherwise, scan directories for counts, update cached values and timestamp.
  3. Call `updateCachedCountsIfStale()` at the start of `flushPersistedLogs()` and `flushToPhone()`.
  4. Append `watch_log_files=<n> drain_files=<n>` to the "Logs queued for background delivery" log message. Field names reflect what's actually counted (files in directories), not pending records.
- Acceptance:
  - Existing log lines in BetterStack carry file count annotations.
  - No additional filesystem IO per log line beyond the 10s TTL check.
  - ACK-driven log lines (outside the flush cycle) use reasonably fresh counts.
- Notes / pitfalls:
  - The 10s TTL means counts can be up to 10 seconds stale. Acceptable for observability — exact counts are available via the daily inventory.
  - The TTL prevents repeated directory scans when multiple ACK replies arrive in quick succession (e.g., `flushPersistedLogs` triggers several resends that ACK within seconds).

### Task E4 — Watch debug view LOG FILES section

- Files: `Trio Watch App Extension/Views/ComplicationDebugView.swift`
- Branch: `feature/watch-complication-improvements` (NOT `feature/cloud-logging`)
- Change: Add a "LOG FILES" section showing file counts and sizes from both log directories.
- Steps:
  1. Add `@State` properties: `watchLogCount`, `watchLogBytes`, `drainCount`, `drainBytes`, `pendingCount`, `isLoadingLogFiles`.
  2. Add async helper `loadLogFileStats()` that:
     - Sets `isLoadingLogFiles = true` (disables refresh button)
     - Scans both directories using file attributes
     - Calls `WatchLogger.shared.getPendingPayloads()` for pending count
     - Updates `@State` properties
     - Sets `isLoadingLogFiles = false`
  3. Call `loadLogFileStats()` from `.onAppear` and from the existing "Refresh View" button action.
  4. Disable "Refresh View" button while `isLoadingLogFiles == true` (in-flight guard against overlapping scans).
  5. Add new section in the ScrollView between the existing APP GROUP section and RELOAD STATUS:
     ```
     LOG FILES
     Watch Logs:        3 files, 12 KB
     Drain Files:       2 files, 8 KB
     Pending Payloads:  5
     ```
- Acceptance:
  - Debug view shows accurate file counts and byte sizes.
  - No filesystem access during SwiftUI body recomputation — data loaded async into @State.
  - Refresh button is disabled while loading (no overlapping scans).
  - Refreshes on view appear and manual refresh tap.
- Notes / pitfalls:
  - The existing "Container Files: 5" counts files in the App Group container root (non-recursive). It includes the `logs/` directory as one item but doesn't show its contents. The new LOG FILES section provides the useful breakdown.
  - WatchLogger per-payload files are in `Documents/logs/` (separate from the shared container). The debug view must access both paths.
  - `WatchLogger.shared.getPendingPayloads()` is an actor method — must be called from a `Task { }` context.
  - **Cross-branch dependency:** E4 depends on `WatchLogger.shared.getPendingPayloads()` and the directory layout (`Documents/logs/`, shared container `logs/`). E1–E3 (on `feature/cloud-logging`) do not change these APIs or paths. If a future E1–E3 change modifies the pending payload storage format or directory structure, E4 must be rebased after E1–E3 lands. Commit E1–E3 and regenerate patch 06 before implementing E4.

---

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Parser regex breaks on edge-case log lines | Low | Medium (lines uploaded unparsed) | Backward-compatible: `build` defaults to `nil`. Add test cases for old/new format, function params, battery suffix. |
| `transferUserInfo` queue grows large on phone | Low | Low (memory) | One confirmation per payload; each message is small. The existing `isProcessed(payloadId)` check in `AppleWatchManager` prevents duplicate processing, so duplicate confirmations are naturally avoided — no separate confirmation-level dedup is needed. Batch into fewer messages in a future iteration if queue depth becomes a concern. |
| Watch doesn't receive confirmations for extended period | Medium | Low | 48h retention backstop deletes stale drain files. Confirmations are delivered opportunistically (foreground, background, or activation); prolonged inactivity is the edge case. |
| Build-change detection false-positive on first install | Certain | None | First install: `lastKnownBuild` is nil → treated as changed → immediate flush/upload. Harmless no-op if no backlog exists. |
| `storePendingPayload` TTL and `maxFileAge` diverge | Low | Low | Task B1 aligns both to 48h. |
| E2 inventory doesn't run if watch app never opens | Low | Low | Dual trigger (flushPersistedLogs + flushToPhone). If the app isn't opened, there's nothing to observe. |
| E3 inline metrics become stale within a flush cycle | Certain | None | `updateCachedCountsIfStale()` with 10s TTL. Exact counts available via daily inventory. |
| E4 debug view causes UI jank from sync filesystem access | Medium | Medium | Mitigated: async load into @State, in-flight guard on refresh button, no IO during body recomputation. |
| E1 `do/catch` at deletion sites causes log noise from expected failures | Low | Low | Missing-file deletions are `outcome=missing result=ok` (informational). Only unexpected errors log `result=err`. |
| E4 rapid refresh taps cause overlapping directory scans | Low | Low | `isLoadingLogFiles` guard disables button during load. |

## Hypotheses / expectations (NOT acceptance)

- After deployment, BetterStack queries filtered by `build` will show correct attribution for lines written post-deployment. Lines from builds prior to this change will continue showing `Bundle.main` build (acceptable).
- Drain file accumulation should drop significantly: most files cleaned up within one watch activation cycle instead of waiting for 7-day retention.
- `event=app_launch` sentinel density should approximate 1 per app launch (iOS) and 1 per watch activation (watchOS). Useful for build timeline reconstruction.

## Implementation log

### Implementation date: 2026-03-12

Branch: `feature/cloud-logging` (Trio worktree)
Patch: `06-cloud-logging.patch` (to be regenerated via `mid-stack-update.sh`)

### Files modified (10)

| File | Phase | Summary |
|---|---|---|
| `Trio Watch App Extension/WatchLogger.swift` | A1, B1, B2, D1 | Cached `build` property, `[b:BUILD]` in `log()` format, reduced `maxFileAge` to 48h and `maxPerPayloadFiles` to 10, aligned `storePendingPayload` cleanup to `maxFileAge`, `lastKnownBuild` detection in `flushPersistedLogs()`, `deleteFilesForPayloadIds()` helper |
| `Trio Watch Shared/ComplicationLogBuffer.swift` | A2 | Static `build` property, `[b:BUILD]` in `append()` format |
| `Trio/Sources/Logger/IssueReporter/SimpleLogReporter.swift` | A3 | Cached `build` property, `[b:BUILD]` in `log()` format |
| `Trio/Sources/Logger/CloudLogging/CloudLogLineParsing.swift` | A4, A5, A6 | `var build: String? = nil` on `CloudParsedLogLine`, `[b:BUILD]` extraction in `parseWatch()` and `parseIOS()` |
| `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift` | A7 | Per-event `attrs["build"]` override from `parsed.build` |
| `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift` | B3 | `lastKnownBuild` detection in `start()`, immediate `uploadNow()` on build change |
| `Trio/Sources/Application/TrioApp.swift` | C1 | iOS launch sentinel after `CloudLogUploadService` resolution |
| `Trio Watch App Extension/TrioWatchApp.swift` | C2 | Watch launch sentinel in `init()` (adapted — see deviations) |
| `Trio Watch App Extension/WatchState.swift` | D1, D3 | `batchAck` dispatch in `didReceiveMessage`, `watchLogConfirm` dispatch in `didReceiveUserInfo` |
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | D2 | `watchLogConfirm` via `transferUserInfo` after `recordProcessed()` in all three handler paths, `isProcessed()` guard added to no-reply path |

### Deviations from plan

1. **C2 — Watch sentinel placed in `TrioWatchApp.init()` instead of `ExtensionDelegate.applicationDidFinishLaunching()`.**
   `ExtensionDelegate.swift` does not exist on the `feature/cloud-logging` branch; it is introduced by patch 09 (watch-complication-improvements). `TrioWatchApp.init()` is the equivalent entry point on this branch.

2. **A4 — Used `var build: String? = nil` instead of `let build: String? = nil`.**
   In Swift, a `let` property with a default value is excluded from the compiler-synthesized memberwise initializer, so call sites cannot pass `build: extractedBuild`. Using `var` with a default keeps the parameter in the initializer while allowing callers that don't extract a build to omit it.

3. **D2 — Added `isProcessed()` / `recordProcessed()` to no-reply `didReceiveMessage` path.**
   Not specified in the plan, but added during code review for consistency with the other two handler paths (both of which already guard with `isProcessed()`). See code review round 2 below.

### Code review

Two rounds of external review (Claude, ChatGPT) were conducted against the `git diff` before committing.

#### Round 1

| # | Source | Issue | Verdict | Rationale |
|---|---|---|---|---|
| 1 | Claude | `CloudLogUploader`: verify `commonAttributes` merge ordering — if merged after per-line attrs, `parsed.build` is silently clobbered | **Verified correct** | `var attrs = commonAttributes` is set first (line 141), per-line fields override after (lines 143-149). Ordering is correct; `parsed.build` overwrites `Bundle.main` value. |
| 2 | Claude + ChatGPT | `deleteFilesForPayloadIds`: `getPendingPayloads()` and `logsDir` recomputed inside loop on every iteration | **Accepted — fixed** | Hoisted both out of the loop. Built a `[payloadId: filePath]` dictionary for O(1) lookup. |
| 3 | Claude | `CloudLogUploadService`: swap `uploadNow()` / `UserDefaults.set` ordering to "write first, then flush" | **Rejected** | Plan v1.5 B3 explicitly says "call `uploadNow()` immediately, then update `lastKnownBuild`." Code matches plan. Claude's stated "documented intent" is incorrect. |
| 4 | Claude | `TrioWatchApp`: sentinel duplicates build in message body — `WatchLogger.log()` already embeds `[b:BUILD]` | **Rejected** | Design doc explicitly specifies `build=\(build)` in sentinel message for BetterStack grep-ability. The `[b:BUILD]` token is extracted into the `build` attribute; the `build=42` in the message body is for `WHERE message LIKE '%event=watch_app_launch%build=42%'` queries. Complementary, not redundant. |
| 5 | Claude | `WatchLogger` upgrade sentinel ordering is intentional (informational) | **Acknowledged** | No change needed. |
| 6 | ChatGPT | Watch sentinel should be in `ExtensionDelegate.applicationDidFinishLaunching()` per plan C2 | **Rejected** | `ExtensionDelegate.swift` does not exist on `feature/cloud-logging`. See deviation #1 above. |
| 7 | ChatGPT | Phone sends duplicate confirms — should centralize into `confirmWatchLogReceiptIfNeeded` helper | **Rejected** | The three handler paths are mutually exclusive per delivery. Paths 1 and 3 already guard with `isProcessed()`. Path 2 (no-reply) is a rare fallback that doesn't receive the same payload through normal flow. Centralizing is over-engineering. (Path 2 hardening accepted separately in round 2.) |
| 8 | ChatGPT | Parser `[b:...]` regex should be anchored to position after timestamp | **Rejected (already anchored)** | The regex `^\[b:([^\]]+)\]` is applied to the remaining text after the timestamp bracket — the `^` anchor ensures it only matches at that position. Message-body `[b:...]` tokens (after `→`) are never scanned. The implementation is already positional; adding additional anchoring is unnecessary. |
| 9 | ChatGPT | Watch upgrade-time flush may need explicit "force" if `flushPersistedLogs` is throttled | **Rejected** | `flushPersistedLogs()` already calls `drainComplicationLogs()` first and processes all pending payload files exhaustively. No throttle or gate exists. |

#### Round 2

| # | Source | Issue | Verdict | Rationale |
|---|---|---|---|---|
| 1 | Claude | `UserDefaults.set` silent failure (low-storage) would cause repeated `[UPGRADE]` sentinels | **Acknowledged** | Informational only. `UserDefaults` failures are vanishingly rare and the repeated sentinels would be harmless noise. No change. |
| 2 | ChatGPT | No-reply `didReceiveMessage` (Path 2) lacks `isProcessed()` guard — inconsistent with Paths 1 and 3 | **Accepted — fixed** | Added `isProcessed()` check and `recordProcessed()` call to Path 2 for consistency. Minimal hardening: one guard + one record call. See deviation #3 above. |
| 3 | ChatGPT | Unanchored `[b:...]` regex could match in message content | **Rejected** | Same reasoning as round 1 #8. Risk is theoretical; anchoring adds complexity that could introduce its own bugs. |

### Phase E + A3b implementation date: 2026-03-13

Branch: `feature/cloud-logging` (E1–E3, A3b), `feature/watch-complication-improvements` (E4)
Patch: `06-cloud-logging.patch` (sha256:223908408c56) and `09-watch-complication-improvements.patch` (sha256:36c0ab3c402f) — regenerated via `mid-stack-update.sh --from-feature-branch`

#### Files modified (3)

| File | Task | Summary |
|---|---|---|
| `Trio/Sources/Logger/IssueReporter/SimpleLogReporter.swift` | A3b | Converted `dateFormatter` computed property to `private static let` (one allocation per process). Updated call site to `SimpleLogReporter.dateFormatter`. |
| `Trio Watch App Extension/WatchLogger.swift` | A3b, E1, E2, E3 | Converted `dateFormatter` to `private static let`. Added `RemoveResult` struct + `removeFileTracked`/`removeFileQuietly`/`sanitizeError` static helpers. Added `logCleanup` helper for ack_reply paths. Added `[CLEANUP]` logging at all 7 deletion sites. Added `applyWatchLogRetention()` and `applyDrainRetention()` extracted helpers. Added `updateCachedCountsIfStale()` (10s TTL). Added `logFileInventory()` (24h rate limit). Pending record removal conditioned on file deletion success (prevents orphans). `flushToPhone` reachable path: moved `storePendingPayload` before `sendMessage` for crash safety (pre-existing bug fix). |
| `Trio Watch App Extension/Views/ComplicationDebugView.swift` | E4 | Added LOG FILES section with `@State` properties, async `loadLogFileStats()`, `formatBytes()` helper. Wired into `.onAppear` and "Refresh View" with `isLoadingLogFiles` guard. |

#### Deviations from plan

1. **WatchLogger dateFormatter also converted to `private static let`** (not specified in A3b). Same performance issue as SimpleLogReporter — computed property allocated a new formatter on every `log()` call. Fixed opportunistically since WatchLogger was already being modified for E1–E3.

2. **`outcome=error` added as a third value.** Plan specified `outcome=deleted|missing`. Code review identified that on unexpected `removeItem` errors, the file was NOT deleted — reporting `outcome=deleted` was misleading. Added `outcome=error` for honesty.

3. **Pending record removal conditioned on file deletion success.** Plan's "artifact pairing" section described file+record as atomic. Code review identified that unconditional `removePendingPayload` after a failed file delete orphans the file — no retry mechanism would find it. Fixed: pending record is only removed when file is confirmed gone (`deleted` or `missing`).

4. **Inline metric field names changed from `pending=`/`drains=` to `watch_log_files=`/`drain_files=`.** Plan E3 specified `pending=<n> drains=<n>`. Code review identified `pending` is misleading — the count is of files in a directory, not `UserDefaults` pending records (these can diverge). Renamed for clarity.

5. **E3 `remaining_pending=` on ACK lines not implemented.** Plan E3 step 4 mentioned appending `remaining_pending=<n>` to `[CLEANUP]` messages. This was dropped — the `[CLEANUP]` format is already well-defined by E1 and adding inline metrics to it conflates cleanup observability with inventory. The daily `[INVENTORY]` log (E2) serves this purpose.

6. **`flushToPhone` reachable path: `storePendingPayload` moved before `sendMessage` (pre-existing bug fix).** The original code only stored the pending record in the `sendMessage` `errorHandler`. If the app crashed between writing the file and the callback firing, the file was orphaned with no pending record — `resendPendingPayloads` wouldn't find it, and retention would silently delete it after 48h. Now both the reachable and unreachable paths follow "write file → store pending → attempt send" order. The ACK handler removes the pending record on success (already guarded by `res.succeeded`).

#### Code review

One round of external review (ChatGPT) conducted against Phase E diff before committing.

##### Round 3

| # | Source | Issue | Verdict | Rationale |
|---|---|---|---|---|
| 1 | ChatGPT | `removeFileTracked` returns `outcome=deleted` on unexpected errors — misleading since file likely wasn't deleted | **Accepted — fixed** | Changed to `outcome=error`. Added `succeeded` computed property to `RemoveResult` for clean conditional checks. |
| 2 | ChatGPT | Pending record removed even when file deletion fails → orphans the file (no retry) | **Accepted — fixed** | All paths now condition `removePendingPayload` on `res.succeeded` (ack_reply) or `removeFileQuietly` return value (query_acks). `deleteFilesForPayloadIds` tracks per-id `watchLogFailed` flag. |
| 3 | ChatGPT | `SimpleLogReporter.dateFormatter` shared static is a concurrency hazard | **Rejected** | `DateFormatter` is thread-safe on iOS 7+ per Apple documentation (confirmed in prior review round by Claude). `SimpleLogReporter` is a `final class` — the `private static let` is initialized once via Swift's thread-safe lazy static initialization. No lock needed. |
| 4 | ChatGPT | `pending=` field name counts files, not pending records — misleading | **Accepted — fixed** | Renamed to `watch_log_files=` and `drain_files=`. Clear about what's counted. |
| 5 | ChatGPT | `flushToPhone` reachable path stores pending record only in `errorHandler` — crash between file write and callback orphans the file | **Accepted — fixed** | Moved `storePendingPayload` to immediately after file write, before `sendMessage`. Both reachable and unreachable paths now follow write-before-send durability posture. Pre-existing bug, not introduced by Phase E. |

### Production verification (build 138, 2026-03-13)

Deployed to device via TestFlight/local build. Verified in BetterStack and on-device debug view:

| Check | Result |
|-------|--------|
| Build 138 events in BetterStack | 71 events in first hour (iOS + watchOS) |
| `[DEPLOY] event=app_launch platform=ios build=138` | Confirmed |
| `[UPGRADE] build changed from 137 to 138` | Confirmed — upgrade-time flush fired |
| `[INVENTORY]` daily log | `watch_logs_count=14 watch_logs_bytes=115397 drains_count=0 drains_bytes=0 pending_count=18` |
| Inline metrics (E3) | `watch_log_files=14 drain_files=0` on flush lines |
| Debug view (E4) LOG FILES section | Displayed watch logs, drain files, pending counts correctly |
| Pending payload drain | Started at 22, drained to 0 within minutes — ACK mechanism working |
| Category distribution | 14 categories across iOS/watchOS (WatchState, CoreData, TrioComplicationDataStore, etc.) |

All Phase E features operational. No errors or anomalies observed. Pending backlog from build 137→138 transition resolved by existing retry/ACK mechanisms.

## Changelog (vPrev → vThis)

### v1.14 (2026-03-13)
- **Project complete.** All phases deployed and verified in production.
- Phase 2 commits: `feature/cloud-logging` (`a49bf06a7`), `feature/watch-complication-improvements` (`63abe736e`).
- Patches regenerated: `06-cloud-logging.patch` (sha256:223908408c56), `09-watch-complication-improvements.patch` (sha256:36c0ab3c402f) via `mid-stack-update.sh --from-feature-branch`.
- Build 138 deployed and verified: [DEPLOY], [UPGRADE], [INVENTORY], [CLEANUP] events confirmed in BetterStack; debug view operational; pending files draining to 0.
- Added production verification log with BetterStack confirmation data.
- Status updated to COMPLETE. Moved to `docs/completed/logging-fixes/`.

### v1.13 (2026-03-13)
- `flushToPhone` crash-safety fix: moved `storePendingPayload` before `sendMessage` in the reachable path. Pre-existing bug: crash between file write and `errorHandler` callback orphaned the file with no pending record and no retry path. Now both reachable and unreachable paths follow write-before-send durability order.
- Implementation log updated: 6 deviations (was 5), code review round 3 now has 5 items (was 4; 3 accepted+fixed, 1 rejected, 1 accepted+renamed).

### v1.12 (2026-03-13)
- Phase E + A3b implementation log added: 3 files modified, 5 deviations, 1 round of code review (4 items; 2 accepted+fixed, 1 rejected, 1 accepted+renamed).
- `outcome` field extended: `deleted | missing | error`. On unexpected `removeItem` errors, `outcome=error` (was incorrectly `outcome=deleted`).
- Pending record safety: all paths now condition `removePendingPayload` on file deletion success. Prevents orphaning files when deletion fails.
- E3 inline metric field names: `pending=` → `watch_log_files=`, `drains=` → `drain_files=` (counts files, not UserDefaults records).
- E3 `remaining_pending=` on ACK lines dropped (conflates cleanup and inventory concerns; daily `[INVENTORY]` covers this).
- Phase E status updated to ✅ implemented (pending commit).

### v1.11 (2026-03-13)
- Added Task A3b: cache `DateFormatter` in `SimpleLogReporter` as a `private static let`. Currently a computed property that allocates a new formatter on every `log()` call — performance fix for the hot path. Ships with Phase E on `feature/cloud-logging`.
- Added status markers to all phases and tasks (A–D ✅ complete, E ⏳ pending). Updated top-level status and phase list to reflect implementation log.
- Broader performance optimization audit tracked in `docs/backlog/perf-optimizations/`.

### v1.10 (2026-03-13)
- E1 outcome tracking: replaced `fileExists` pre-check with attempt-then-catch pattern — attempt `removeItem`, catch `NSFileNoSuchFileError` (code 4) as `outcome=missing result=ok`. Simpler (one filesystem call) and eliminates redundant pre-check.
- A5: added positional safety note — `[b:...]` regex is `^`-anchored to position after timestamp, not a global search; message-body collisions impossible.
- Code review #8 (round 1): updated verdict from "Rejected" to "Rejected (already anchored)" with clarified reasoning.
- E4: added cross-branch dependency note — E1–E3 don't change storage APIs, but E4 must rebase if they do.

### v1.9 (2026-03-13)
- Error field sanitization: `error=` must be a machine-parseable token (spaces→underscores, ≤50 chars, no newlines). Added `sanitizeError()` helper requirement. Prevents `localizedDescription` from breaking key=value parsing.
- Confirm path emits per-artifact-type events: `deleteFilesForPayloadIds` now produces separate `[CLEANUP]` events for `watch_log`, `pending_record`, and `drain` artifacts. Ensures partial failures are attributable per type.
- Documented `ack_reply` file+record atomic pairing: file deletion and associated pending record removal treated as one operation; no separate `artifact=pending_record` event for ACK paths.

### v1.8 (2026-03-12)
- Phase E schema tightening (round 2 review):
  - Renamed `file=` to `artifact=` — semantically cleaner since it covers both filesystem files and UserDefaults records.
  - Defined two explicit event shapes: single-delete (with `payloadId`, `outcome`) and batch/retention (with `count`, `deleted`, `remaining`).
  - Added canonical per-path field mapping table — prevents drift by declaring required/optional/never-present fields per path.
  - Replaced multi-ID `payloadId=ABCD,EF56` with bounded `sample_ids=id1|id2|id3` (max 3, pipe-delimited) for batch events.
  - Added `outcome=deleted|missing` sub-field for single-delete paths — distinguishes actual cleanup from idempotent no-ops.
- E3: replaced "cached per flush cycle" with `updateCachedCountsIfStale()` using 10s TTL — ACK-driven log lines outside the flush cycle now get reasonably fresh counts.
- E4: added `isLoadingLogFiles` in-flight guard — disables refresh button while loading to prevent overlapping scans.
- Updated risks table for new Phase E items.

### v1.7 (2026-03-12)
- Added Phase E: Cleanup observability (E1–E4). Unified `[CLEANUP]` event schema with `path=`/`flow=`/`artifact=`/`result=` fields. Daily `[INVENTORY]` log with rate limiting. Inline metrics on existing log lines (cached with TTL). Watch debug view LOG FILES section (async load).
- Incorporates external code review feedback: split `path=ack_reply` into `flow=flush/resend/drain` for granularity, add retention summary logging (emit only when deleted > 0), convert `try?` to `do/catch` for failure visibility, enforce off-main/cached IO for performance, require async @State loading for debug view.
- Status changed to "Phase 1 complete, Phase 2 pending".
- Added Phase E risks to risks table.

### v1.6 (2026-03-12)
- Added implementation log section: files modified, deviations from plan, two rounds of code review with verdicts.
- Status changed from "Draft" to "Implemented (pending commit + patch regeneration)".

### v1.5 (2026-03-12)
- D1: documented explicit rejection of `Task.detached` — `WatchState` is a class (`@Observable final class ... NSObject, WCSessionDelegate`), not an actor, so `Task {}` has no executor inheritance. `Task.detached` would be functionally identical but semantically misleading.

### v1.4 (2026-03-12)
- D3: added threading callout (same `Task { await ... }` + return immediately pattern as D1) for consistency.

### v1.3 (2026-03-12)
- A5: added full sample log line with parameterized function token (`session(_:didReceiveUserInfo:)`) to acceptance examples.
- D1: made `Task { await ... }` guidance concrete — return immediately from delegate method, do not block WCSession callback thread.
- B2: made `lastKnownBuild` write-before-drain ordering explicit (step d) with interruption rationale.
- D2/risks: replaced "phone deduplicates" with precise explanation — existing `isProcessed(payloadId)` check naturally prevents duplicate confirmations.
- D3: clarified recently-confirmed set is a nice-to-have optimization, not required for correctness — `sendLogContentFromFile()` no-ops on missing files, and phone deduplicates via `isProcessed`.

### v1.2 (2026-03-12)
- Aligned risks table to one-per-payload confirmation policy (removed stale "cap 50 IDs" mitigation).
- D3 acceptance: clarified delivery is opportunistic (foreground/background/activation), not activation-gated.

### v1.1 (2026-03-12)
- A5: added real codebase function signatures (`session(_:didReceiveUserInfo:)`, `handle(_:)`, etc.) to acceptance criteria.
- A6: added note that `DEV:` / `INFO:` prefixes are part of message content (prepended by `Logger`), not a separate format element. Added old-format example without level prefix.
- B2: clarified that drain already happens first in `flushPersistedLogs()`; primary value of this task is bookkeeping + observability logging.
- C1: locked insertion point to `TrioApp.swift` after `CloudLogUploadService` resolution. Clarified that `debug(.service, ...)` produces category `service` (not `DEPLOY`), message includes `DEV:` prefix, and `info(...)` must not be used (triggers user-visible alert).
- D1: added exact filename matching rule (`complication_log.drain.<id>.txt`), directory scope (App Group `logs/`), and explicit no-recursive-scan / no-substring-match constraints.
- D2: committed to one-per-payload confirmation strategy (no batching).

### v1.0 (2026-03-12)
- Initial version. Covers all four changes from the logging-fixes idea doc.
