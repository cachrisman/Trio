---
name: Watch Battery Logging Refactor
overview: Refactor watchOS battery logging so battery monitoring is enabled once per process, battery context is cached and refreshed at most every 60 seconds, and all WKInterfaceDevice reads happen on the MainActor. Log format unchanged; battery fields remain on every log line.
todos:
  - id: mainactor-helper
    content: Add @MainActor battery read helper (once-enabled monitoring, same format)
    status: completed
  - id: watchlogger-cache
    content: "WatchLogger: actor cache + batteryContextCached() + use in log()"
    status: completed
  - id: complication-cache-actor
    content: "ComplicationLogBuffer: BatteryContextCache actor + async append path"
    status: completed
  - id: datastore-await
    content: "TrioComplicationDataStore: make log() async, add await at call sites"
    status: completed
  - id: version-changelog
    content: Confirm plan version in header and add/update Changelog + Implementation Log section
    status: completed
isProject: false
---

# Watch Battery Logging Refactor — Plan v1.4

**Version:** 1.4  
**Scope:** [Trio Watch App Extension/WatchLogger.swift](Trio Watch App Extension/WatchLogger.swift), [Trio Watch Shared/ComplicationLogBuffer.swift](Trio Watch Shared/ComplicationLogBuffer.swift), and minimal call-site changes. This plan does not modify the complication remediation plan, implementation guide, or the complication freshness Cursor plan (those documents live in Trio-dev).

**Goals:**

1. Enable `WKInterfaceDevice` battery monitoring **once per process** (guarded).
2. **Cache/sampling:** refresh battery level/state at most once every 60 seconds; append the **cached** string to every log line (never omit battery fields).
3. **Thread safety:** perform all WatchKit battery reads on the **MainActor** (main thread).

**Constraints:**

- Log format unchanged: every line still ends with `battery_level_percent=... battery_state=...`.
- Do not change log parsing or other formatting.
- Non–watchOS behavior in ComplicationLogBuffer: keep returning `"battery_level_percent=unsupported battery_state=unsupported"`.
- Minimal, tight, safe edits only.
- **Never await inside `queue.sync` or `queue.async` blocks;** always prefetch battery context before entering the queue.

---

## A) MainActor-only battery read helper

Add a single helper that is explicitly `@MainActor` and returns the formatted context string:

- Set `WKInterfaceDevice.current().isBatteryMonitoringEnabled = true` **once** (e.g. guarded by a static `hasEnabledBatteryMonitoring` or equivalent so it runs only on first call).
- Read `batteryLevel` and `batteryState`; format exactly as today:
  - **Level:** percent integer if `>= 0`, else `"unknown"`.
  - **State:** `unknown` / `unplugged` / `charging` / `full`; `@unknown default` → `"unknown_default"`.
- Return `"battery_level_percent=\(levelText) battery_state=\(stateText)"`.

Prefer **duplicating the @MainActor helper in each file** (WatchLogger.swift and ComplicationLogBuffer.swift) to avoid cross-target linking and target membership issues. Do not add a new shared file unless absolutely necessary.

---

## B) WatchLogger.swift (actor)

- **State:** Add actor-isolated cache:
  - `private var lastBatteryContext = "battery_level_percent=unknown battery_state=unknown"`
  - `private var lastBatteryRefreshEpoch: TimeInterval = 0`
- **Method:** `private func batteryContextCached(now: TimeInterval = Date().timeIntervalSince1970) async -> String`
  - **Only when stale:** If `now - lastBatteryRefreshEpoch >= 60`, hop to MainActor via `await MainActor.run { ... }`, call the MainActor battery helper, then update `lastBatteryContext` and `lastBatteryRefreshEpoch`. When not stale, return the cached string without calling MainActor.
  - Return `lastBatteryContext`. (Epoch seconds is fine; keep it simple.)
- **Call site:** In `log(...)`, replace the current `Self.batteryLogContext()` call with `await batteryContextCached()` and append the result to the log entry as today.

Remove the existing non–MainActor `batteryLogContext()` (or replace it by the MainActor helper used inside `MainActor.run`).

---

## C) ComplicationLogBuffer.swift (static, background queues)

- **Cache actor:** Add a small private actor, e.g. `private actor BatteryContextCache`, with:
  - `var lastContext: String`
  - `var lastRefreshEpoch: TimeInterval`
  - `func get() async -> String`: on watchOS, if refresh needed (≥ 60s), `await MainActor.run { ... }` to call the MainActor battery helper, update cache, return cached string; off watchOS, return `"battery_level_percent=unsupported battery_state=unsupported"` immediately.
- **Static instance:** `private static let batteryCache = BatteryContextCache()`.
- **WIDGET_EXTENSION file path:** Today `appendToFile(message:file:line:function:)` is synchronous and calls `batteryLogContext()` directly. To use the cache and MainActor:
  - **Must:** `append(_:file:line:function:)` becomes `async`. **Prefetch** `let batteryContext = await batteryCache.get()` **before** entering `queue.sync`. Never await inside `queue.sync` or `queue.async`; always prefetch battery context before entering the queue.
  - **Flow:** In `append`, first `let batteryContext = await batteryCache.get()`, then inside `queue.sync { ... }` call a sync helper (e.g. `appendToFile(message:file:line:function:batteryContext:)`) that builds the entry with the provided `batteryContext`. The write still completes before return for the short-lived complication process. Cache returns a sane default immediately (unknown/unknown or unsupported/unsupported) so short-lived widget processes are fine.
- **Caller:** [Trio Watch Shared/TrioComplicationDataStore.swift](Trio Watch Shared/TrioComplicationDataStore.swift) has a single call site: `private func log(_ message: String)` which calls `ComplicationLogBuffer.append(message)`. Change `log` to `private func log(_ message: String) async` and add `await` before `ComplicationLogBuffer.append(...)`. Update all internal call sites of `log(...)` to use `await log(...)` (many are already in async contexts; add `await` where needed).

---

## D) File and call-site summary


| File                                                                                                   | Change                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Trio Watch App Extension/WatchLogger.swift](Trio Watch App Extension/WatchLogger.swift)               | MainActor helper (or use of it), actor cache + `batteryContextCached()`, use in `log()`; remove old `batteryLogContext()`                                                            |
| [Trio Watch Shared/ComplicationLogBuffer.swift](Trio Watch Shared/ComplicationLogBuffer.swift)         | MainActor helper (same format), `BatteryContextCache` actor, `append` async, `appendToFile(..., batteryContext:)` with pre-fetched string, `queue.sync { doAppend(batteryContext) }` |
| [Trio Watch Shared/TrioComplicationDataStore.swift](Trio Watch Shared/TrioComplicationDataStore.swift) | `log(_:)` → `log(_:) async`, `await ComplicationLogBuffer.append(...)`; all call sites of `log(...)` use `await log(...)`                                                            |


---

## E) Version and Changelog

- This plan is **v1.4**; confirm the version in the header and add/update the **Changelog** and **Implementation Log** sections at the end when making plan edits.

---

## Changelog

### v1.4 — 2026-03-11 | Task lifecycle and in-flight clearing fixes

- **WatchLogger:** Waiter path no longer clears `batteryRefreshTask` or always updates cache. If an existing task exists, await it and return; only update `lastBatteryContext` / `lastBatteryRefreshEpoch` when cache is still stale after the await (`currentNow - lastBatteryRefreshEpoch >= 60`). Creator path alone creates the task, defers clearing `batteryRefreshTask`, and uses completion-time epoch. Avoids racy clearing by waiters.
- **ComplicationLogBuffer:** Removed `withTaskCancellationHandler` (invalid/fragile with await in operation). Single `defer { queue.async { ... } }` that updates `lastBatteryContext`, `lastBatteryRefreshEpoch`, and sets `batteryRefreshInFlight = false`. `fresh` and `refreshedAt` default to current cache so cancellation or early exit leaves cache unchanged and still clears the flag. No await inside queue blocks.

### v1.3 — 2026-03-11 | Harden battery cache: in-flight always cleared; single refresh per minute (WatchLogger)

- **ComplicationLogBuffer:** `batteryRefreshInFlight` is always cleared. Fire-and-forget Task uses `withTaskCancellationHandler`: on normal completion, `queue.async` updates cache (if fresh is non-nil) and sets `batteryRefreshInFlight = false`; on cancel, `onCancel` runs `queue.async { batteryRefreshInFlight = false }`. No await inside queue blocks.
- **WatchLogger:** Actor reentrancy fix. Added `batteryRefreshTask: Task<String, Never>?`. In `batteryContextCached`: if cache fresh (<60s) return cached; if existing refresh task, await it, update cache and epoch, clear task (defer), return; else create new task, store it, defer clear, await, update cache and epoch, return. At most one in-flight refresh; concurrent callers reuse the same task.
- Log format unchanged; DataStore remains sync.

### v1.2 — 2026-03-11 | Remove async ripple; queue-confined cache; DataStore sync

- **ComplicationLogBuffer:** `append(...)` reverted to synchronous. Removed `BatteryContextCache` actor. Battery cache state is queue-confined (`lastBatteryContext`, `lastBatteryRefreshEpoch`, `batteryRefreshInFlight`); access/mutate only on `ComplicationLogBuffer.queue`. Stale refresh is fire-and-forget: inside `queue.sync` return cached context for current line; if stale and not in-flight, set `batteryRefreshInFlight = true` and launch a `Task` that runs `await MainActor.run { batteryContextOnMain() }` then updates cache via `queue.async { ... }` and clears `batteryRefreshInFlight`. No await inside queue.sync/async.
- **TrioComplicationDataStore:** `log(_:)` reverted to synchronous. Removed all `await log(...)` and `Task { await log(...) }`. `saveOnMain`, `coalescedReloadOnMain`, `forceReloadOnMain`, `reloadTimeline`, `scheduleRetryAfterReloadOnMain` reverted to synchronous. No new `Task { ... }` around stateful main-thread methods.
- **WatchLogger.swift:** Unchanged (actor cache approach retained).
- Invariants preserved: battery fields on every log line; same format; no await inside queue blocks.

### v1.1 — 2026-03-11 | Guardrails and clarity

- **Todo:** version-changelog todo updated to "Confirm plan version in header and add/update Changelog + Implementation Log section".
- **Constraint:** Explicit rule added: never await inside `queue.sync` or `queue.async`; always prefetch battery context before entering the queue.
- **Section A:** Prefer duplicating the @MainActor helper in each file (WatchLogger, ComplicationLogBuffer) to avoid cross-target linking and target membership issues; no new shared file unless necessary.
- **Section B:** Explicit that WatchLogger only hops to MainActor when cache is stale (≥60s); when not stale, return cached string without calling MainActor. Epoch seconds kept for simplicity.
- **Section C:** Must-prefetch and flow tightened: append becomes async, prefetch `batteryContext` before `queue.sync`; sane default for short-lived widget process. Hard rule: never await inside queue.
- **Section E:** Single bullet: confirm version in header and add/update Changelog and Implementation Log when editing the plan.

### v1.0 — 2026-03-11 | Initial version

- Initial plan: MainActor-only battery read, enable monitoring once, 60s cache, battery on every log line. WatchLogger actor cache; ComplicationLogBuffer cache actor and async append path with pre-fetched battery context to avoid await inside `queue.sync`. TrioComplicationDataStore `log` made async with await at all call sites.

---

## Implementation Log

When implementation is complete:

- Mark all todos as completed.
- Append a new entry here with:
  - Date
  - Branch + commit(s)
  - Files changed
  - Summary of implementation (MainActor helper, caching behavior)
  - Validation performed (build targets, any runtime smoke test notes)

### 2026-03-11 | Refactor: sync append, queue-confined cache, DataStore reverted to sync

- **Branch/commits:** (fill when committed)
- **Files changed:**
  - `Trio Watch Shared/ComplicationLogBuffer.swift` — Removed `BatteryContextCache` actor and async `append`. Added queue-confined `lastBatteryContext`, `lastBatteryRefreshEpoch`, `batteryRefreshInFlight`. `append(...)` is sync again; inside `queue.sync` use cached battery context for the current line and, if stale and not in-flight, start a fire-and-forget `Task` that reads on MainActor and updates cache via `queue.async`. Non-watchOS still returns `battery_level_percent=unsupported battery_state=unsupported`.
  - `Trio Watch Shared/TrioComplicationDataStore.swift` — `log(_:)` sync again; all `await log(...)` and `Task { await log(...) }` removed. `saveOnMain`, `coalescedReloadOnMain`, `forceReloadOnMain`, `reloadTimeline`, `scheduleRetryAfterReloadOnMain` reverted to synchronous.
- **Summary:** MainActor helper and once-per-process monitoring unchanged. WatchLogger unchanged. ComplicationLogBuffer uses queue-only cache and fire-and-forget refresh so the log path stays sync and file write still completes before return. DataStore logging API is sync; no async ripple.
- **Validation:** (run watch app + complication targets; confirm logs still show battery fields on every line.)

### 2026-03-11 | Harden: batteryRefreshInFlight always cleared; WatchLogger single in-flight refresh

- **Files changed:**
  - `Trio Watch Shared/ComplicationLogBuffer.swift` — Task body now uses `withTaskCancellationHandler`. On completion: `queue.async` updates cache when `fresh` is non-nil and sets `batteryRefreshInFlight = false`. On cancel: `onCancel` runs `queue.async { batteryRefreshInFlight = false }`. Ensures the flag is always cleared even if the task is cancelled or fails before the main path runs.
  - `Trio Watch App Extension/WatchLogger.swift` — Added `batteryRefreshTask: Task<String, Never>?`. `batteryContextCached` now: return cached if fresh (<60s); else if existing task, await it, update cache/epoch, `defer { batteryRefreshTask = nil }`, return; else create task, store it, `defer { batteryRefreshTask = nil }`, await, update cache/epoch, return. Prevents multiple concurrent refreshes (actor reentrancy).
- **Validation:** Battery suffix on every log line (unchanged). No await inside ComplicationLogBuffer queue.sync/async. WatchLogger runs at most one refresh at a time; concurrent callers reuse same task.

### 2026-03-11 | Fix: batteryRefreshTask lifecycle; ComplicationLogBuffer in-flight clearing without withTaskCancellationHandler

- **Branch/commits:** `feature/watch-complication-improvements` — 6fab38c5d
- **Files changed:**
  - `Trio Watch App Extension/WatchLogger.swift` — **Waiter path:** no longer clears `batteryRefreshTask` or unconditionally updates cache. If `batteryRefreshTask` exists, await `existing.value`; then only if cache is still stale (`currentNow - lastBatteryRefreshEpoch >= 60`) update `lastBatteryContext` and `lastBatteryRefreshEpoch`; return result. **Creator path:** only path that creates the task, assigns it, uses `defer { batteryRefreshTask = nil }`, awaits, updates cache with completion-time epoch, returns. Avoids racy clearing of the task by waiters.
  - `Trio Watch Shared/ComplicationLogBuffer.swift` — Replaced `withTaskCancellationHandler` with a single `defer { queue.async { ... } }`. Defer block updates `lastBatteryContext`, `lastBatteryRefreshEpoch`, and sets `batteryRefreshInFlight = false`. `fresh` and `refreshedAt` are initialized to current cache values so if the task is cancelled before the MainActor read completes, the defer still runs and writes those defaults (cache unchanged) and clears the flag. After `await MainActor.run { batteryContextOnMain() }`, assign `fresh` and `refreshedAt`; defer then writes them and clears in-flight. All cache state remains queue-confined; no await inside queue.sync/async.
  - `Trio Watch Shared/TrioComplicationDataStore.swift` — No behavioral change; sync `log(_:)` retained.
- **Summary:** Log format unchanged. DataStore remains sync. Battery fields on every log line.
- **Validation:** (build; confirm battery suffix format unchanged; no await in queue blocks.)
