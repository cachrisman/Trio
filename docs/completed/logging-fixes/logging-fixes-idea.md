# Logging Fixes Implementation Plan v1.0

We need to make four related improvements to the cloud logging pipeline to solve the build mislabeling problem and improve drain file cleanup. Read the relevant source files before making any changes.

IMPORTANT ARCHITECTURE NOTE:
- App Group containers are NOT shared between iPhone and Apple Watch (different devices, different filesystems).
- The App Group is only shared among targets on the SAME device (e.g., watch app extension + watch complication extension).
- Therefore: any phone→watch confirmation / cleanup signal MUST use WatchConnectivity (sendMessage / transferUserInfo / applicationContext), not App Group UserDefaults.

---

## Background: the build mislabeling problem

CloudLogUploader currently stamps every uploaded log event with `build` read at upload time via:
`Bundle.main.infoDictionary?["CFBundleVersion"]` in `buildCommonAttributes(platform:)`.

Neither watch log lines nor iOS log lines currently embed build numbers, so backlogged log lines written on an older build but uploaded after an upgrade are attributed to the wrong build in BetterStack.

There are two delivery pathways:
- Watch pathway: ComplicationLogBuffer writes to complication_log.txt in the watch App Group container. WatchLogger drains those via drainComplicationLogs() inside flushPersistedLogs(). Orphan drain files are retained and resent oldest-first.
- Phone pathway: SimpleLogReporter writes to log.txt (and rotates to log_prev.txt). CloudLogUploader tails by byte offset. If uploads stall across an upgrade, old entries can be stamped with the new build.

Goal: embed the true build at WRITE time, parse it at UPLOAD time, and improve cleanup so old data doesn’t linger.

---

## Change 1: Embed build number in every log line at write time (both pathways)

Goal: Make the true build permanently part of each log line so the uploader can use it instead of Bundle.main at upload time.

### Watch/complication pathway

WatchLogger.swift:
- In the log() function, change the log line format from:
  `[timestamp] [File.swift:line] function → message <batteryContext>`
  to:
  `[timestamp] [b:BUILD] [File.swift:line] function → message <batteryContext>`

Notes:
- Keep the unicode arrow `→` (do NOT change it to `->`).
- Preserve the trailing battery context as-is.
- Retrieve build via `Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"`.
- Cache build as a stored property on WatchLogger created once (e.g., `private let build: String`) — do not look it up on every log write.

ComplicationLogBuffer.swift:
- ComplicationLogBuffer is a static enum (no instances). Do NOT refactor it into a class/struct just to cache build.
- Add a `private static let build: String = ...` and inject `[b:BUILD]` into the file line format in the function that actually builds the string (private appendToFile / entry formatting), not by inventing a new public API.
- The public API is `append(...)` (NOT write()).

### Phone pathway

SimpleLogReporter.swift:
- Insert the `[b:BUILD]` token immediately after the timestamp in each line.
- Cache build once (e.g., `private let build: String` or `static let build`) rather than reading Bundle every log call.

Keep the rest of SimpleLogReporter’s line structure intact; do NOT try to force the line to match any simplified example.

---

## Change 1b: Parser updates to extract embedded build, backward-compatible

CloudLogLineParsing.swift:
- Add a `build: String?` field to CloudParsedLogLine.
- Update parseWatch() to detect and extract `[b:BUILD]` token if present immediately after the timestamp bracket.
  - Backward compatible: if absent, parsed.build = nil.
  - IMPORTANT: watch log lines include trailing battery context and use `→`. Parsers must tolerate both.
  - IMPORTANT: the function token may include parameters (e.g., `foo(bar:)`), not just `foo()`. Avoid regex assumptions that require literal `()`.

- Update parseIOS() similarly:
  - Extract `[b:BUILD]` if present immediately after timestamp token.
  - Backward compatible: parsed.build = nil if absent.
  - IMPORTANT: do NOT require a ` - (DEV|INFO|WARN|ERR):` level token unless the iOS writer actually emits it. The parser must match the existing SimpleLogReporter format (timestamp, [category], file - function - line - message).

CloudLogUploader.swift:
- When assembling events:
  - Use parsed.build if non-nil as the event’s build attribute.
  - Otherwise fall back to commonAttributes["build"] (Bundle.main) for old-format lines.

Do NOT rename or remove the existing commonAttributes["build"] — it remains the fallback.

Deployment sequencing:
- Prefer to ship parser/uploader support in the same build as the write-format change.
- If staged, parser/uploader support must ship BEFORE or alongside the write-format change, never after.

---

## Change 2: Reduce retention windows and add upgrade-time flush (blast-radius reduction)

WatchLogger.swift:
- Reduce maxFileAge for complication drain files from 7 days to 48 hours.
- Reduce maxPerPayloadFiles from 20 to 10.
- (Optional but recommended) Ensure deletion/retention is applied consistently across drain files and pending payload files; document any differences.

Upgrade-time flush on watch:
- Store lastKnownBuild in watch-local persistent storage (watch UserDefaults or watch App Group if it’s used only among watch targets).
- At the start of flushPersistedLogs(), compare current build to lastKnownBuild.
  - If different: immediately call drainComplicationLogs() and flush in-memory pending payloads before the normal flush cycle.
  - Then update lastKnownBuild.
- Ensure this logic is idempotent and does not loop (e.g., set lastKnownBuild once per new build).

Phone side upgrade-time flush:
- Implement build-change detection in CloudLogUploadService (or the owner of CloudLogUploader), not in SimpleLogReporter.
- On app launch: if current build != lastKnownBuild, trigger an immediate uploadNow() before the first timer tick, then update lastKnownBuild.

SimpleLogReporter:
- Do NOT attempt to “final upload” from SimpleLogReporter itself; it’s a file writer and has no uploader reference.
- If additional “upload before rotate/overwrite” behavior is needed, implement it in CloudLogUploadService / CloudLogUploader where offsets and file tail state exist.

---

## Change 3: App launch sentinel log line (build timeline breadcrumbs)

Goal: Embed a build timeline into the stream itself for BetterStack queries.

iOS launch sentinel:
- At app startup (SwiftUI app entrypoint, e.g., TrioApp / onAppear / initialization path that runs once per launch), write a structured log message via SimpleLogReporter:
  category: "DEPLOY"
  message: "event=app_launch platform=ios build=<BUILD>"
- Do not attempt to match an oversimplified string format; SimpleLogReporter will include timestamp, [DEPLOY], file/function/line fields, and the new [b:BUILD] token from Change 1. That is expected.

Watch launch sentinel:
- On watch app activation/launch in ExtensionDelegate (or the appropriate lifecycle hook that is guaranteed to fire), write via WatchLogger:
  category/message equivalent: include "event=watch_app_launch platform=watchos build=<BUILD>"
- Again: accept the logger’s normal formatting (file/function/line, arrow, battery context). The key is the structured message substring for searching.

Verification query expectation:
- Searching BetterStack for `event=app_launch` and `event=watch_app_launch` should find these messages regardless of surrounding metadata.

---

## Change 4: More robust drain file deletion (fix the ACK gap properly)

Context:
- Drain files persist too long because deletion is gated on synchronous ACK but delivery uses transferUserInfo (async, no reply handler).
- Phone also sends proactive batchAck messages via sendMessage with no reply handler; currently these are not acted upon on watch.

Fix plan (WatchConnectivity-based, not App Group based):

### 4a) Handle unsolicited batchAck on watch in the correct WCSession delegate

- The watch-side WCSessionDelegate that receives `session(_:didReceiveMessage:)` is NOT WatchLogger.
- Implement processing of batchAck messages in the actual delegate (e.g., WatchState.swift, where didReceiveMessage lives).
- When a batchAck arrives:
  - Extract payloadIds.
  - Call into WatchLogger (or a dedicated cleanup helper) to delete matching drain files by payloadId.
  - Ensure this cleanup is safe to call even if the file was already deleted (idempotent).
  - Log a line indicating batchAck cleanup occurred (include count and payloadIds truncated/summarized).

### 4b) Add a robust “phone-confirms-then-watch-cleans” mechanism using WatchConnectivity

Because sendMessage is not reliable (reachability, app running), use an async, persisted channel:
- Phone side: when it receives a watchLogs payload (transferUserInfo) and records it as processed, enqueue the payloadId as “confirmed for deletion”.
- Deliver confirmations to watch using transferUserInfo (preferred) or applicationContext:
  - transferUserInfo is queued and delivered opportunistically; good for eventual delivery.
  - applicationContext is latest-state only; good if you can store a set and resend full state.

Recommendation:
- Use transferUserInfo for confirmed payloadIds as discrete messages:
  `{ "type": "watchLogConfirm", "payloadIds": [ ... ] }`
- Cap payloadIds per message (e.g., 50) and dedupe on phone before sending.

Watch side:
- In the WCSession delegate `session(_:didReceiveUserInfo:)` (or equivalent), on receiving a confirmation message:
  - Delete matching drain files immediately.
  - Optionally store a small local “recently confirmed” set (cap e.g. 200, TTL e.g. 48h) to make cleanup idempotent and to handle out-of-order deliveries.
  - Log confirmation processing.

Do NOT use App Group UserDefaults for phone→watch signaling.

Retention cleanup:
- 48-hour retention remains the backstop.

---

## What NOT to change

- Do not change BetterStack source ID, team ID, upload endpoints, or auth configuration.
- Do not change complication timeline rendering logic or WidgetKit reload scheduling.
- Do not change avg C query logic.
- Do not remove or rename the commonAttributes["build"] fallback.
- Do not refactor ComplicationLogBuffer enum into a class/struct just for caching.

---

## Verification checklist (must be demonstrable)

1) WatchLogger.log() produces `[timestamp] [b:BUILD] [File:line] function → message ...battery...`
2) ComplicationLogBuffer.append(...) produces lines with `[b:BUILD]` in the same position.
3) SimpleLogReporter.log() produces timestamp then `[b:BUILD]` then `[category] ...`.
4) parseWatch() extracts build from new-format lines and returns nil for old-format lines; tolerates arrow `→`, battery suffix, and function params.
5) parseIOS() extracts build from new-format lines and returns nil for old-format lines; matches actual iOS log line structure (no assumed level token unless present).
6) CloudLogUploader uses parsed.build when present, falls back to Bundle.main build when nil.
7) WatchLogger maxFileAge = 48 hours and maxPerPayloadFiles = 10.
8) batchAck messages received on watch trigger drain file deletion (wired in the actual WCSession delegate).
9) Phone side sends confirmed payloadIds via WatchConnectivity (transferUserInfo or applicationContext) after receipt/processing.
10) Watch side consumes confirmations and deletes drain files without requiring reachability or immediate message replies.
11) DEPLOY sentinels appear in BetterStack under searches for `event=app_launch` and `event=watch_app_launch`.

---

## Documentation / changelog

Do NOT add app code changes to AGENTS.md (it tracks agent/tooling workflow changes).
Instead:
- Add a short entry to an app-appropriate changelog location (e.g., docs/completed/cloud-logging.md or a dedicated CHANGELOG.md in the app/docs area if it exists).
- The entry must describe: build mislabeling root cause, embedded-build fix, parser/uploader override behavior, upgrade-time flush, sentinel logs, and the new confirmation-based cleanup path.