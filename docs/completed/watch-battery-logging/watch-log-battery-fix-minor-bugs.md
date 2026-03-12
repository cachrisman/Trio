# Cursor Prompt — Watch Log Battery Fix + Minor Bugs
**Version:** v1.5
**Files:** `WatchLogger.swift`, `ComplicationLogBuffer.swift`

---

## Changelog

- **v1.5** — Fix 1 step 1: explicitly name `nonWidgetLastBatteryContext` as the variable
  read for the message suffix; add sentence clarifying initial cache state (epoch=0 means
  stale immediately, triggering refresh on first log call — this is intentional); add
  sentence clarifying that `defer` must schedule the same single completion closure (not
  a separate clear-only `queue.async`)
- **v1.4** — Fix 1 step 2: split variable declarations into queue-confined vs
  MainActor-confined groups; verification checklist items 3–4 verify each group separately
- **v1.3** — Fix 1: drop "top-level"; add `nonWidgetHasEnabledBatteryMonitoring` one-time
  guard; add single-queue-async requirement for task completion mutation
- **v1.2** — Fix 1: declare battery cache vars at file scope, use `nonWidget*` names;
  replace "do not change widget behavior"; replace "log line" with "message string"
- **v1.1** — Fix 1: target ring-buffer messages not formatted lines; Fix 2: reframe as
  audit; Fix 3: preserve Task {} wrapper
- **v1.0** — Initial prompt

---

## Background

There are two watch log pipelines:

**Pipeline A — `WatchLogger`** (Watch App Extension): an `actor` that buffers log entries
and flushes them to the phone. Battery context is already fetched per line via
`batteryContextCached()`. `WatchLogger.log()` is `async`, so every internal call must be
properly awaited inside an async context or inside a `Task {}`.

**Pipeline B — `ComplicationLogBuffer`:**
- In the Widget/Complication Extension (`#if WIDGET_EXTENSION`), it appends fully
  formatted log lines to an App Group file. This path already appends battery context
  and is correct.
- In the Watch App Extension (non-`WIDGET_EXTENSION`), it appends raw `message` strings
  to an in-memory ring buffer via `doAppendRingOnly(message:)`. No battery context is
  appended today.

---

## Instructions

Read each instruction completely before making any edits. Make all changes silently with
no summarizing. Do not increment any version numbers. Implement ALL 3 fixes.

---

## Fix 1 — `ComplicationLogBuffer.swift`: append battery context to Watch App Extension ring-buffer message strings (watchOS only)

**Problem:** In the Watch App Extension (non-`WIDGET_EXTENSION`) target,
`ComplicationLogBuffer.append()` uses `doAppendRingOnly(message:)`, which stores raw
`message` strings in the ring buffer with no battery suffix.

**Goal:** On watchOS, ensure ring-buffer message strings in the non-`WIDGET_EXTENSION`
path also include the suffix `battery_level_percent=... battery_state=...` appended to
the stored message. Do NOT add timestamp/file/line formatting to the ring buffer — keep
existing ring semantics (plain message strings).

**Implementation:**

1. In the `#else` branch of the `#if WIDGET_EXTENSION` conditional inside `append()`
   (note: this conditional is inside `append()`, not at file scope), replace the current
   `queue.async { doAppendRingOnly(message: message) }` with a new code path that:
   - Runs on `queue.async`
   - On watchOS, reads `nonWidgetLastBatteryContext` and calls
     `doAppendRingOnly(message: "\(message) \(nonWidgetLastBatteryContext)")`
   - On non-watchOS, calls `doAppendRingOnly(message: message)` unchanged
   - On watchOS, when `nonWidgetLastBatteryRefreshEpoch` is stale (current time minus
     epoch ≥ 60 seconds) and `nonWidgetBatteryRefreshInFlight` is `false`, sets
     `nonWidgetBatteryRefreshInFlight = true`, then launches a `Task` that awaits
     `MainActor.run { nonWidgetBatteryContextOnMain() }`, and upon completion dispatches
     a **single** `queue.async` closure that atomically sets `nonWidgetLastBatteryContext`,
     `nonWidgetLastBatteryRefreshEpoch`, and `nonWidgetBatteryRefreshInFlight = false` —
     all three in one closure, not separate calls
   - Uses `defer` (installed before any `await`) inside the refresh `Task` to guarantee
     `nonWidgetBatteryRefreshInFlight` is always cleared. The `defer` block must schedule
     the same single completion `queue.async` closure described above — do not enqueue a
     separate clear-only closure alongside it

2. Declare the following at **file scope** (not inside a function or branch body),
   guarded by `#if os(watchOS)`, for use only in the non-`WIDGET_EXTENSION` path.

   **Queue-confined** (access/mutate only on `ComplicationLogBuffer.queue`):
   - `private static var nonWidgetLastBatteryContext: String = "battery_level_percent=unknown battery_state=unknown"`
   - `private static var nonWidgetLastBatteryRefreshEpoch: TimeInterval = 0`
   - `private static var nonWidgetBatteryRefreshInFlight: Bool = false`

   The initial value of `nonWidgetLastBatteryRefreshEpoch = 0` is intentional: it makes
   the cache immediately stale so the first `append()` call triggers a battery refresh.
   Do not change this default.

   **MainActor-confined** (access/mutate only on `MainActor`, inside
   `nonWidgetBatteryContextOnMain()`):
   - `private static var nonWidgetHasEnabledBatteryMonitoring: Bool = false`

   **Function:**
   - `@MainActor private static func nonWidgetBatteryContextOnMain() -> String` —
     same implementation as the widget-side `batteryContextOnMain()`, using
     `nonWidgetHasEnabledBatteryMonitoring` as the one-time guard so that
     `isBatteryMonitoringEnabled = true` is set exactly once per process, not on
     every refresh cycle

3. Non-watchOS non-`WIDGET_EXTENSION` behavior: call `doAppendRingOnly(message: message)`
   unchanged — no battery context, no new variables needed.

4. Do not change widget behavior, format, or any file-append logic. Add parallel
   non-widget logic only.

---

## Fix 2 — `WatchLogger.swift`: audit internal `Task {}` blocks for missing `await` on `WatchLogger.shared.log(...)` calls

**Problem:** `WatchLogger.log()` is `async` on an `actor`. Within `Task { }` blocks
inside `WatchLogger.swift`, any `WatchLogger.shared.log(...)` call must use `await`.

**Implementation:**

Audit every `WatchLogger.shared.log(...)` call inside `WatchLogger.swift`, specifically
within `Task { }` blocks in:
- `flushToPhone()` reply handler and error handler
- `sendLogContentFromFile()` and any `Task` blocks it creates
- `resendPendingPayloads()` and any `Task` blocks it creates
- `drainComplicationLogs()` and any `Task` blocks it creates

If any call is missing `await` inside an async context, add it. If everything already
uses `await` correctly, make no changes for Fix 2.

---

## Fix 3 — `WatchLogger.swift`: fix `batchAck` file deletion to use stored file paths

**Problem:** In `flushPersistedLogs()`, the `batchAck` reply handler deletes files by
reconstructing a path from the `ackId` using a hardcoded pattern:

```swift
let filePath = logDir.appendingPathComponent("watch_log_\(ackId).txt")
try? FileManager.default.removeItem(at: filePath)
```

This is fragile. The pending payload records already store the correct `filePath` per
`payloadId` — use that instead.

**Implementation:**

1. In `flushPersistedLogs()`, `let pendingPayloads` is already available before the
   `sendMessage(queryEnvelope, ...)` call. Ensure it is captured by the reply handler
   closure.

2. In the `batchAck` reply handler, preserve the existing `Task { ... }` wrapper (or
   add one if missing) so that `await` calls are valid inside it. Inside that `Task`,
   replace the hardcoded path deletion with a lookup from `pendingPayloads`:

   ```swift
   for ackId in ackIds {
       if let record = pendingPayloads.first(where: { $0["payloadId"] as? String == ackId }),
          let filePath = record["filePath"] as? String {
           let fileURL = URL(fileURLWithPath: filePath)
           try? FileManager.default.removeItem(at: fileURL)
       }
       await WatchLogger.shared.removePendingPayload(ackId)
   }
   ```

3. Remove the old reconstructed path line (`logDir.appendingPathComponent("watch_log_\(ackId).txt")`).

4. Do not change any other logic in `flushPersistedLogs()`.

---

## Verification Checklist (do not skip)

After all edits, verify:

1. In `ComplicationLogBuffer.append()` non-`WIDGET_EXTENSION` path on watchOS,
   ring-buffer message strings now include the suffix
   `battery_level_percent=... battery_state=...`
2. Non-watchOS non-`WIDGET_EXTENSION` builds compile cleanly — no `WKInterfaceDevice`
   references outside `#if os(watchOS)`
3. `nonWidgetHasEnabledBatteryMonitoring` is declared at file scope under `#if os(watchOS)`,
   is only accessed/mutated inside `@MainActor nonWidgetBatteryContextOnMain()`, and is
   not referenced on the queue
4. `nonWidgetLastBatteryContext`, `nonWidgetLastBatteryRefreshEpoch`, and
   `nonWidgetBatteryRefreshInFlight` are declared at file scope under `#if os(watchOS)`,
   and are only accessed/mutated on `ComplicationLogBuffer.queue`
5. `nonWidgetLastBatteryRefreshEpoch` is initialized to `0` (not `Date().timeIntervalSince1970`)
6. The battery cache refresh `Task` updates all three queue-confined vars in a single
   `queue.async` closure — no separate clear-only closure exists
7. Inside `WatchLogger.swift`, all `Task { }` blocks that call `WatchLogger.shared.log(...)`
   use `await` — or no changes were needed because they already did
8. The `batchAck` handler deletes files using stored `filePath` values from
   `pendingPayloads`, not reconstructed paths
9. Widget file-append behavior and format are unchanged
10. No logic changes beyond the three fixes above

---

## Implementation log

**Date:** 2026-03-11

**Fix 1 (ComplicationLogBuffer.swift):**
- Added `#if os(watchOS)` block at file scope with queue-confined vars (`nonWidgetLastBatteryContext`, `nonWidgetLastBatteryRefreshEpoch`, `nonWidgetBatteryRefreshInFlight`), MainActor-confined `nonWidgetHasEnabledBatteryMonitoring`, and `@MainActor nonWidgetBatteryContextOnMain()` (same logic as widget-side `batteryContextOnMain()` using the one-time guard).
- In the `#else` (non-`WIDGET_EXTENSION`) branch of `append()`, added `#if os(watchOS)` path: on queue, read `nonWidgetLastBatteryContext` and call `doAppendRingOnly(message: "\(message) \(contextToUse)")`. When cache is stale (≥60s) and `!nonWidgetBatteryRefreshInFlight`, set inFlight and launch a `Task` with a single `defer { queue.async { ... } }` that updates all three queue-confined vars. Non-watchOS path unchanged: `doAppendRingOnly(message: message)`.
- **Judgement call:** None; implemented per spec.

**Fix 1 follow-up (concurrency discipline):**
- **Bug:** The refresh `Task` was reading `nonWidgetLastBatteryContext` and `nonWidgetLastBatteryRefreshEpoch` inside the Task body. Those vars are queue-confined (access/mutate only on `ComplicationLogBuffer.queue`), so reading them off-queue in the Task violated the rule and could race.
- **Fix:** Capture the current cached values on the queue before creating the Task: `let defaultFresh = nonWidgetLastBatteryContext` and `let defaultRefreshedAt = nonWidgetLastBatteryRefreshEpoch` inside the same `queue.async` block, then pass them into the Task by initializing `var fresh = defaultFresh` and `var refreshedAt = defaultRefreshedAt` inside the Task. The Task no longer reads any queue-confined vars; it only writes them via the defer’s `queue.async` closure.
- **Import:** Confirmed `#if os(watchOS)` / `import WatchKit` / `#endif` remains at the top of `ComplicationLogBuffer.swift` so `nonWidgetBatteryContextOnMain()` compiles on watchOS.

**Fix 2 (WatchLogger.swift):**
- Audited every `WatchLogger.shared.log(...)` call inside `Task { }` blocks in `flushToPhone()` (reply and error handlers), `sendLogContentFromFile()` (reply and error handlers), `resendPendingPayloads()` (reply and error handlers), and `drainComplicationLogs()` (and Tasks it triggers via `sendLogContentFromFile`). All such calls already use `await`. No code changes.
- **Judgement call:** None.

**Fix 3 (WatchLogger.swift):**
- In `flushPersistedLogs()`, the `batchAck` reply handler now looks up each `ackId` in `pendingPayloads` (by `payloadId`), uses stored `filePath` from the record, and calls `FileManager.default.removeItem(at: fileURL)`; then `await WatchLogger.shared.removePendingPayload(ackId)` as before. Removed the reconstructed path `logDir.appendingPathComponent("watch_log_\(ackId).txt")`.
- **Judgement call:** The doc said “Ensure it is captured by the reply handler closure.” The closure already closes over `pendingPayloads` from the enclosing scope. I added an explicit capture list `[pendingPayloads]` in the reply handler so the closure holds the snapshot of pending payloads at the time of `sendMessage`, avoiding any ambiguity if the outer scope were to change before the reply is delivered.