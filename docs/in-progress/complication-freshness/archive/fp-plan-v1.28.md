# Watch Complication Freshness — Implementation Plan

**Version:** 1.28
**Date:** 2026-03-09
**Based on:** v1.27; Phase 3 complete (3.0–3.4 shipped, build 130). See changelog.

**Preferred order of attack:**

1. ✅ Instrument save-age vs reload-age delta + epoch correlation key (baseline — no behavior change). **Done — Phase 0.1/0.2.**
2. ✅ Ship "no retry after save" + forceReload call-site audit + doc corrections. **Done — Phase 1.**
3. ✅ Re-measure buckets. **Done — BetterStack analysis 2026-03-08. Key findings: WatchConnectivity queue flush = primary delay (p50 ~38s, p90 ~278s); WidgetKit scheduling = secondary (p50 ~101s, p90 ~440s); phone pipeline is fast (~13s p50 to transfer); receive→save ≈ 0s; save→reload ≈ 0s median.**
4. ✅ Phase 2.3 complete. **Done — all six sub-tasks shipped: 2.3.1 (build 128, iOS transfer join key), 2.3.2 (build 129, structured log fields), 2.3.3 (receive_lag dashboard), 2.3.4 (freshness decomposition dashboard + doc formula), 2.3.5 (sleep-gap classifier dashboard + query), 2.3.6 (Option A 4th criterion). No behavior changes.**
5. ✅ Phase 3 complete (build 130). **Done — dedup and lastValidTimestamp hardening shipped as a unit: 3.0 (pre-dispatch fingerprint dedup), 3.1 (saveOnMain invariants + log format), 3.2 (canonical shouldUpdate comparator, ±1s symmetric window), 3.3 (lastValidTimestamp monotonic guard, eventually-consistent doc), 3.4 (sanitization invariant in init). glucoseColor excluded from dedup fields (settings-dependent but stable within update cycle). Correctness-only; measure against reload_requested volume and generation association ratio, not save_age.**
6. Observability and SLA documentation (parallel with Phase 3).
7. Only if delivery-delay still dominates after (4)–(6): revisit background-fetch / transport (Phase 5 placeholder — do not implement now).

**Phase 2.1 status: Removed.** `WCSession.sessionReachabilityDidChange` is unreliable across watchOS 3–7. The expected platform behavior when queued `transferUserInfo` / `transferCurrentComplicationUserInfo` payloads are delivered after a reconnect is that watchOS wakes the watch app via `WKWatchConnectivityRefreshBackgroundTask`, `didReceiveUserInfo` fires, and the existing save path runs. This is **expected behavior that must be verified in logs**, not a guarantee. Phase 2.2 adds that logging.

**Phase 2.2 status: Complete.** BGTask logging, enqueue/finalize/race diagnostics, and BetterStack analysis all done. 72h analysis: 96.7% fast-path completions, 3.3% timeout (all explained by didReceiveUserInfo-before-enqueue race, no missed saves). Option A trigger criteria not met as of 2026-03-08.

**Phase 5 status:** Out of scope. BGTask pipeline is healthy; dominant delay is WatchConnectivity queue flush wait (how long until the task fires at all), not what happens inside it. `WKApplicationRefreshBackgroundTask` would not address queue flush wait. Placeholder only at end of document.

---

## Doc corrections (apply before implementation)

Apply these to `snapshot-age-improvements-suggestions.md` so they never reach code:


| Issue                       | Correction |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **POSIX `flock` in §3.5**   | Remove. On Darwin, `flock` does not provide cross-process mutual exclusion for App Group. Valid options: accept TOCTOU and document it, use `UserDefaults(suiteName:)` with documented eventual-consistency, or use `NSFileCoordinator` with awareness that it can block the complication provider and risk WidgetKit timeouts. Default is `UserDefaults` + monotonic guard. |
| **Reconnect signal (§3.1)** | Replace the reconnect-flag approach. `WCSession.sessionReachabilityDidChange` is unreliable across watchOS 3–7. The expected platform behavior after reconnect is delivery of queued payloads via `WKWatchConnectivityRefreshBackgroundTask`, which wakes the watch app and fires `didReceiveUserInfo`. This must be verified in logs — it is not guaranteed. If not occurring, investigate `WatchState.handleBackgroundTasks` and `hasContentPending` handling before considering any app-level reconnect signal. |
| **Bucket 1 scope (§1.1)**   | Add: "Some levers (WCSession queue behavior, system wake budget, iOS connectivity) are outside the app's full control; the app's contribution is robust queue drain on wake and not adding artificial delays." |
| **§3.4 getTimeline/budget** | Replace "only invoked on first reload after budget reset" with: "Under normal conditions, each `reloadTimelines` call should eventually result in a `getTimeline` call; a persistent large gap versus a baseline is the signal of exhaustion. Expect coalescing; measure match-rate and latency distribution against a known-good baseline, not raw 1:1 equality." |


---

## Log field naming convention

`reading_date_epoch` is **reserved exclusively for the CGM reading's timestamp** — `Int(snapshot.readingDate.timeIntervalSince1970)`. It is used in Phase 0.1 save and reload events and in Phase 3.0 fingerprint logging. It must never be used for any other timestamp (e.g. reload request time, fingerprint write time).

Other epoch fields used in this plan:

- `reload_requested_at_epoch` — when a `reloadTimelines` call was made (Phase 0.2 only).

**Phase 2.2 background task logs:** Prefer **dedicated structured fields** (e.g. in the same JSON/structured log shape as Phase 0.1): `event`, `window_id` (Int), and optionally `task_type`. That keeps BetterStack MCP queries stable when message text changes and allows Step 4b (window-safe) correlation. **If your logging pipeline cannot emit structured JSON fields** (e.g. it only stores a single string message), embed stable key-value tokens in the message so parsing is still reliable: e.g. `event=complication_bgtask_received window_id=42 task_type=WKWatchConnectivityRefreshBackgroundTask` — then queries can use `JSONExtract(raw,'message',...) LIKE '%event=complication_bgtask_received%'` and extract `window_id` via a consistent pattern. Document which approach you use.

Do not reuse field names across different semantic meanings. Any new epoch field introduced should be named after what it represents, not reuse `reading_date_epoch`.

**Log pipeline (Better Stack):** The in-repo cloud logging implementation (patch `06-cloud-logging`) sends logs to Better Stack as JSON: each event is a `CloudLogEvent` with top-level keys `message`, `dt`, `raw`, and a **whitelist of attributes** (platform, build, category, appVersion, env, level, file, method, lineNumber, source) flattened from `attributes`. So the pipeline **does support** structured JSON fields; Better Stack stores that payload and queries use `JSONExtract(raw, 'message', ...)`, `JSONExtract(raw, 'category', ...)`, etc. For Phase 2.2, `event`, `window_id`, and `task_type` are **not** currently in the encoder whitelist. To get them as first-class structured fields (Step 4b): extend the cloud logging patch so the watch format is parsed (e.g. from message tokens) and add `event`, `window_id`, `task_type` to the attributes whitelist in `CloudLogEvent.encode(to:)`. Otherwise use the message-embed fallback (same tokens, query via `message`); both approaches are valid.

---

## Shared definitions (referenced throughout)

### BackgroundTaskWindowCounter

Used in Phase 2.2 to correlate `WKWatchConnectivityRefreshBackgroundTask` wake windows with `didReceiveUserInfo` delivery.

- Must be **in-memory only** (no App Group writes) to avoid cross-process complexity.
- Implementation: a static monotonic Int counter plus a last-window-start timestamp; when a task is received, advance the counter and record the start time; expose a way to read the current window id only if the last start is within a short window (e.g. 30s) so "same wake" can be inferred.
- **Placement:** Define in the **watch app extension target only** (e.g. in or next to `WatchState.swift`) so both `WatchState.handleBackgroundTasks` and the WCSession delegate (`didReceiveUserInfo`) can access it. Do **not** add it to a shared module or the complication extension target — the complication extension must not import it; in-memory state is process-local and putting it in Shared would confuse intent.

---

### ComplicationSnapshotFingerprint

Used in Phase 3.0 for pre-dispatch dedup.

**Target membership:** Watch app extension target and `TrioComplicationDataStore.swift` only. This struct is NOT needed in the complication extension (which only reads `getTimeline` data, not dispatch decisions). Do not add it to the complication extension target or any shared framework unless the project already has a shared module — adding it to the wrong target wastes time and can produce duplicate definitions.

```swift
/// Fingerprint of the fields that affect complication display.
/// Stored in App Group to detect duplicate cross-path deliveries.
/// Phase 3.0 / v1.6
///
/// Before implementing:
/// - Verify property names from the actual TrioComplicationSnapshot model; do not guess.
/// - Ensure this fingerprint field set exactly matches the fields compared in
///   TrioComplicationSnapshot.shouldUpdate (or equivalent comparator). If the complication
///   renders a field, it must be included here; if it does not, do not include it.
/// - "state" below is an expected property name; confirm it exists
///   and is spelled correctly, or remove/replace as appropriate.
///
/// Optional model properties (String?): The fingerprint uses non-optional String so Equatable
/// is consistent. In init(from:), use a canonical default for nil. Defaulting to "" is correct
/// only if nil and "" are equivalent for display in your app. If nil means "unknown" and ""
/// means "empty but known" and that affects rendering, encode the distinction (e.g.
/// state = snapshot.state ?? "<nil>") so dedup does not treat different display meanings as equal.
struct ComplicationSnapshotFingerprint: Codable, Equatable {
    let readingDateEpoch: Int      // Int(snapshot.readingDate.timeIntervalSince1970)
    let glucose: String            // sanitized display string
    let trend: String              // sanitized trend string
    let delta: String              // sanitized delta string
    let state: String              // verify property name in TrioComplicationSnapshot
    // glucoseColor intentionally excluded: computed from glucose value
}
```

**Storage:** `UserDefaults(suiteName: APP_GROUP_SUITE)`, key `"complication_last_saved_fingerprint"`, JSON-encoded `Data`.
**Written by:** `saveOnMain` only, after a snapshot is accepted and written to the store. Never written by `didReceiveUserInfo` or `didReceiveMessage`.
**Read by:** Pre-dispatch check in `didReceiveUserInfo` and `didReceiveMessage`.

Add, remove, or rename fields to match the actual `TrioComplicationSnapshot` model. Field set must be identical to the fields used in `shouldUpdate` (Phase 3.2).

### Dedup serial queue

```swift
// In TrioComplicationDataStore — one instance, shared across the watch app extension.
// Phase 3.0 / v1.6
let dedupQueue = DispatchQueue(label: "com.trio.complication.dedup", qos: .utility)
```

**Usage pattern — decision-only sync, save dispatched outside:**

`dedupQueue.sync` is used only to make the read-and-decide step atomic between concurrent `didReceiveUserInfo` and `didReceiveMessage` calls. The call to `saveComplicationSnapshot` must happen **outside** the `sync` block:

```swift
var shouldSave = false
dedupQueue.sync {
    // Decision only — no heavy work, no save call inside this block.
    let defaults = UserDefaults(suiteName: APP_GROUP_SUITE)!
    let incoming = ComplicationSnapshotFingerprint(from: incomingSnapshot)
    guard let stored = storedFingerprint(defaults: defaults),
          stored == incoming else {
        shouldSave = true
        return
    }
    debugLog("⏭️ Pre-dispatch dedup: skipped ...")
}
if shouldSave {
    saveComplicationSnapshot(incomingSnapshot)  // called outside sync block
}
```

**Why save must be outside the sync block:** If `saveComplicationSnapshot` (or anything it calls synchronously) dispatches back to the main queue with `DispatchQueue.main.sync`, and `didReceiveUserInfo` / `didReceiveMessage` can arrive on the main queue, a deadlock results: main → `dedupQueue.sync` → `main.sync` → blocked. Keeping the sync block decision-only also prevents heavy work from monopolizing the dedup queue.

**Deadlock prevention rule for implementers:** Ensure that no code path reachable from `saveComplicationSnapshot` calls `dedupQueue.sync` (re-entry on a serial queue deadlocks) or `DispatchQueue.main.sync` from a non-main thread in a way that could chain back to the main queue holding `dedupQueue`. Use `main.async`, never `main.sync`, anywhere in the save path initiated from the pre-dispatch check.

**UserDefaults consistency:** The dedup queue serializes reads and the skip/dispatch decision. The fingerprint write in `saveOnMain` happens on the main queue — a different context. This is intentional and accepted: the pre-dispatch check is a best-effort optimization that reduces duplicate dispatches but cannot guarantee zero duplicates under concurrent bursts. `saveOnMain`'s own dedup gate handles the correctness case. `saveOnMain` must log clearly when it drops a duplicate (see Phase 3.1 acceptance) so the optimization's effectiveness can be measured. If stronger ordering is desired (at the cost of added complexity), an alternative is to initiate the fingerprint write from `saveOnMain` but dispatch it onto `dedupQueue.async` rather than writing directly on the main queue. The default plan uses the simpler approach (main-queue write, accepted best-effort).

---

## Spikes / verification required before specific phases


| Spike                                                  | Question                                                                                                                           | Required before                           | Outcome |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------- |
| **UUID/correlation (Phase 0.2)**                       | Ring buffer design: burst-safe, single-writer, eviction.                                                                           | Phase 0.2 (optional)                      | 16 entries; watch app writer only; estimate effort first. |
| **WKWatchConnectivityRefreshBackgroundTask confirmed** | Is the task actually received in `WatchState.handleBackgroundTasks` on a real device after BT reconnect (screen off, no app-open)? | Phase 2.2 (this is the verification task) | If never observed after Phase 2.2 logging is in place: follow investigation note. |


---

## Pre-implementation checklist

Verify in source before running any Cursor prompt.

- Confirm `saveOnMain` exact line in `TrioComplicationDataStore.swift` (~507).
- Confirm `reloadTimeline()` reload log line (~621–622).
- Confirm `coalescedReloadOnMain` (~593–594).
- Confirm `forceReloadOnMain` / `scheduleRetry` parameter (~615).
- Confirm `forceComplicationUpdate` / `forceReload(scheduleRetry: false)` in `WatchState.swift` (~694).
- Confirm `TrioComplicationSnapshot` init file and line. Verify glucose/delta sanitization is in init.
- Confirm exact property names on `TrioComplicationSnapshot` that affect display (especially: does `state` exist as named?). Update `ComplicationSnapshotFingerprint` and `shouldUpdate` fields before implementing Phase 3.0. **Process:** Update fingerprint and shouldUpdate together in the same commit; reviewer must diff the field lists to prevent drift.
- Confirm App Group suite name from project entitlements. Insert into Phase 3.0 and 0.2 Cursor prompts.
- Confirm `didReceiveUserInfo` and `didReceiveMessage` file and line in watch app extension.
- Confirm `WatchState.handleBackgroundTasks` — does it currently handle `WKWatchConnectivityRefreshBackgroundTask`? Note current completion behavior (e.g. fixed 5s delay) for Phase 2.2.
- Confirm current watchOS deployment target. Verify max background task runtime (typically 15–30s depending on task type and watchOS version). Use this to set the Phase 2.2 timeout safely below the platform limit.

---

## Phase 0: Baseline instrumentation (no behavior change)

**Goal:** Add structured logging with integer epoch join keys. No saves, reloads, or retries changed.

**Gate:** None. Do this first.

---

### 0.1 Structured save-age and reload-age logging

**Status: Complete.**

- **Where:** `TrioComplicationDataStore.swift` — `saveOnMain` (~~507); `reloadTimeline()` (~~621–622).
- **What:**
  - Stable event name: `complication_save_age` / `complication_reload_age`.
  - `age_seconds`: Int.
  - `reading_date_epoch`: **Int** — `Int(snapshot.readingDate.timeIntervalSince1970)` — primary join key. CGM reading time only; see log field naming convention above.
  - `reading_date`: ISO8601 string — human-readable only, not a join key.
- **Acceptance:** Both events queryable by stable name. Same `reading_date_epoch` value appears in both the save and reload events for the same CGM reading.
- **Do not:** Change behavior. Do not remove existing human-readable text.

#### Cursor prompt — Phase 0.1

```
Logging change only to TrioComplicationDataStore.swift. No behavior changes.

Context: Structured log fields for Better Stack. reading_date_epoch (Int) is the join
key; ISO8601 is human-readable only. Never use reading_date_epoch for anything other
than the CGM reading's timestamp.

Task:

1. In saveOnMain, after the successful-write log line, add:
   - event: "complication_save_age"
   - age_seconds: Int(ageSec)
   - reading_date_epoch: Int(snapshot.readingDate.timeIntervalSince1970)
   - reading_date: ISO8601 string of snapshot.readingDate  [human-readable only]

2. In reloadTimeline(), after the reload log line, add:
   - event: "complication_reload_age"
   - age_seconds: Int (existing age-in-seconds value)
   - reading_date_epoch: Int(lastTS.timeIntervalSince1970)
   - reading_date: ISO8601 string of lastTS  [human-readable only]

3. Do not remove existing human-readable log text.
4. No other changes.

Verify line numbers first: save log ~507, reload log ~621–622.
```

---

### 0.2 (Optional) Reload request → getTimeline correlation

Implement only after estimating effort. Defer if high.

- **Where:** Watch app — all `reloadTimelines(ofKind:)` call sites. Complication extension — `getTimeline` in `TrioWatchComplication.swift`.
- **What:** Ring buffer (64 entries, watch app writes only) in App Group. Log `reload_requested_at_epoch_seconds` (when the reload was requested — distinct from `reading_date_epoch` which is the CGM reading time). The complication extension only reads the ring buffer in `getTimeline`; it must not write to it.
- **Join key clarification:** In Phase 0.2 logging, use `reload_requested_at_epoch_seconds` for the reload request time. Do not use `reading_date_epoch` here — that field is reserved for the CGM reading's date (Phase 0.1). They are different timestamps and are not interchangeable.
- **Do not:** Use a single UUID (overwritten before `getTimeline` reads it). Do not write the ring buffer from the complication extension — the watch app writes; the complication extension only reads.

#### Cursor prompt — Phase 0.2

```
Optional instrumentation for general rollout.
Required if you want to investigate WidgetKit budget/coalescing by correlating reload requests to `getTimeline` executions (Phase 4.2). Only implement if effort estimate is acceptable.

App Group suite name: group.org.nightscout.5QE6TMMEH2.trio.trio-app-group

FIELD NAMING: reading_date_epoch is RESERVED for CGM reading timestamps (Phase 0.1).
Do NOT use it here. Use reload_requested_at_epoch_seconds for reload request timing.

1. Define:
   struct ComplicationReloadRecord: Codable {
       let id: UUID
       let requestedAtEpochSeconds: Int  // Int(Date().timeIntervalSince1970)
   }
   // NOTE: requestedAtEpochSeconds is the reload request time, not the CGM reading time.
   // These are different; do not log either as reading_date_epoch.

2. Ring buffer in UserDefaults(suiteName: suite), key "complication_reload_ring":
   - Capacity: 64 entries. On write: append; drop oldest if count > 64.
   - The watch app writes this buffer (before each reloadTimelines call).
   - The complication extension must NOT write to this buffer; it reads only.

3. In watch app, before each reloadTimelines(ofKind:) call:
   - Create ComplicationReloadRecord (new UUID, epochSeconds = Int(Date().timeIntervalSince1970)).
   - Append to ring buffer.
   - Log: event="complication_reload_requested"
          reload_id=<UUID>
          reload_requested_at_epoch_seconds=<requestedAtEpochSeconds>   // reload request time only

4. In getTimeline (TrioWatchComplication.swift):
   - Read ring buffer.
   - If ring buffer missing/empty/decoding fails:
       Log: event="complication_get_timeline_called"
            most_recent_reload_id="none"
            latency_seconds=-1
            reload_requested_at_epoch_seconds=-1
       Continue.
   - Else:
       let nowEpochSeconds = Int(Date().timeIntervalSince1970)
       let newest = newestRecord
       let latency = nowEpochSeconds - newest.requestedAtEpochSeconds
       Log: event="complication_get_timeline_called"
            most_recent_reload_id=<newest.id or "none">
            latency_seconds=<max(latency, 0) or -1>
            reload_requested_at_epoch_seconds=<newest.requestedAtEpochSeconds or -1>
       // Note: this is NOT reading_date_epoch; the getTimeline event does not know
       // the CGM reading time. Use reload_requested_at_epoch_seconds here only.

5. No behavior changes.
```

**Option A compile-time guard (recommended):** To guarantee the complication extension never writes the ring buffer, use a compile-time guard (`#if !WIDGET_EXTENSION` around the ring append in the watch app path). The sync scripts in this repo support per-configuration build settings: set `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the **Trio Watch Complication Extension** target in `scripts/sync_project_files_config.rb` (Debug: `DEBUG WIDGET_EXTENSION $(inherited)`, Release: `WIDGET_EXTENSION $(inherited)`), then run `ruby scripts/sync_project_files.rb` so the script writes the project; do not hand-edit `project.pbxproj`.

**Minimal acceptance check after running sync:** In the project, for the Trio Watch Complication Extension target: **Debug** — `SWIFT_ACTIVE_COMPILATION_CONDITIONS` contains both `DEBUG` and `WIDGET_EXTENSION`; **Release** — contains `WIDGET_EXTENSION` and does **not** contain `DEBUG`. If both are true, Option A is correctly implemented.

**Phase 0.2 log verification (do immediately after deploy):** Verify that both event types land in Better Stack for the same device. Within 24h of shipping Phase 0.2, run a query that checks for both `complication_reload_requested` (watch app, via `log(...)`) and `complication_get_timeline_called` (complication extension, via ComplicationLogBuffer file/drain) in the same time window. If `complication_get_timeline_called` is missing or redacted, the complication extension logs may not be ingested or may be privacy-redacted; correlation on reload_id (and reload_requested_at_epoch_seconds as fallback/sanity check) will fail until the pipeline is fixed.

**Phase 0.2 causality metrics extension (v1.19):** Phase 0.2 was extended with causality metrics documented in `docs/phase-0.2-causality-metrics-implementation-plan.md`. This adds: (a) `reload_generation` counter (App Group UserDefaults, watch-app-only writer) and `observed_reload_generation` / `generation_delta` on the provider side for reload→getTimeline match-rate measurement; (b) `latency_valid` boolean gate with a 600s validity window to exclude stale/sentinel latency values from metrics; (c) `provider_instance_id` and `provider_restart` for extension process lifecycle tracking; (d) `app_group_available` and `observed_generation_source` for App Group failure disambiguation. Eight Better Stack extraction rules and six dashboard panels (in "Causality Metrics (Phase 0.2)" section of dashboard 689533) provide generation delta distribution, gated latency percentiles, reload-association ratio, and provider restart rate. See the causality metrics plan for full specs, sentinel conventions, and acceptance criteria.

---

## Phase 1: No retry after save + doc corrections

**Goal:** Remove automatic retries on the save path and all unjustified `forceReload` retries. Apply doc corrections.

**Gate:** Phase 0.1 in place.

---

### 1.1 Apply doc corrections

- **Acceptance:** No `flock` for cross-process; §3.1 reconnect section describes expected platform behavior + verification requirement; Bucket 1 sentence present; §3.4 getTimeline wording corrected.

#### Cursor prompt — Phase 1.1

```
Apply these corrections to snapshot-age-improvements-suggestions.md.
Make only these changes; do not rewrite or reformat.

1. §3.5: Remove `flock` for cross-process App Group. Replace with:
   "On Darwin, `flock` does not provide cross-process mutual exclusion for App Group.
   Valid options: accept TOCTOU and document it; UserDefaults(suiteName:) with
   documented eventual-consistency; or NSFileCoordinator with the understanding that
   it can block the complication provider and risk WidgetKit timeouts. Default:
   UserDefaults + monotonic guard."

2. §3.1 (reconnect): Replace with:
   "WCSession.sessionReachabilityDidChange is unreliable across watchOS versions.
   Expected platform behavior after reconnect: queued transferUserInfo payloads are
   delivered, watchOS wakes the watch app via WKWatchConnectivityRefreshBackgroundTask,
   didReceiveUserInfo fires, save path triggers reload. Must be verified in logs —
   not guaranteed. If not observed: (1) Does WatchState.handleBackgroundTasks handle
   WKWatchConnectivityRefreshBackgroundTask? (2) Is setTaskCompleted() held until
   hasContentPending == false? (3) Is transferCurrentComplicationUserInfo used on iOS
   side? Do not build retry logic on WCSession reachability."

3. §1.1 (Bucket 1): Add:
   "Note: WCSession queue behavior, system wake budget, and iOS connectivity are
   outside the app's full control; the app's contribution is robust queue drain on
   wake and not adding artificial delays."

4. §3.4 (getTimeline): Replace "only invoked on first reload after budget reset" with:
   "Under normal conditions each reloadTimelines call should eventually produce a
   getTimeline call; a persistent large gap versus a known-good baseline is the signal
   of budget exhaustion. Expect coalescing; measure match-rate and latency distribution
   against baseline, not raw 1:1 equality."
```

---

### 1.2 No retry after save-triggered reload

- **Where:** `TrioComplicationDataStore.swift` — `coalescedReloadOnMain` (~~593); `saveOnMain` call site (~~509–510).
- **What:** Add `scheduleRetry: Bool = true` to `coalescedReloadOnMain`. Save path passes `false`.
- **Acceptance:** No "Retry scheduled" log entry after save-triggered reload. Initial reload still fires. Logs contain `"⏭️ Retry skipped: scheduleRetry=false (save path)"` when save path triggers reload.

#### Cursor prompt — Phase 1.2

```
Change: TrioComplicationDataStore.swift

Verify line numbers first: coalescedReloadOnMain ~593, saveOnMain call ~509–510.

1. Add scheduleRetry: Bool = true parameter to coalescedReloadOnMain(minInterval:)
   → coalescedReloadOnMain(minInterval:scheduleRetry:)

2. Inside coalescedReloadOnMain, wrap scheduleRetryAfterReloadOnMain:
   guard scheduleRetry else {
       log("⏭️ Retry skipped: scheduleRetry=false (save path)")
       return
   }

3. In saveOnMain: update call to pass scheduleRetry: false.

4. Other call sites without explicit scheduleRetry default to true — leave for Phase 1.3.

5. No other changes.
```

---

### 1.3 Audit and clean up forceReload call sites

- **Where:** All `forceReload(scheduleRetry:)` / `forceReloadOnMain(scheduleRetry:)` call sites in `TrioComplicationDataStore.swift` and `WatchState.swift`.
- **Acceptance:** All `scheduleRetry: true` have inline justification comment. `forceComplicationUpdate` (~WatchState:694) passes `false`. Audit in PR description.

#### Cursor prompt — Phase 1.3

```
Audit: TrioComplicationDataStore.swift and WatchState.swift.

1. Find every call site of forceReload(scheduleRetry:) and forceReloadOnMain(scheduleRetry:).

2. Inline comment per site:
   - false (or converting): // scheduleRetry: false — one-shot; no retry needed.
   - true with reason: // scheduleRetry: true — [reason].
   - true, no reason: convert to false: // scheduleRetry: false — no justification; Phase 1.3.

3. Confirm forceComplicationUpdate (~WatchState:694) passes scheduleRetry: false. Don't change.

4. In your response only (not source): list every call site and decision.
5. No other changes.
```

---

## Phase 2: Wake burst debounce + background delivery verification

**Goal:** (2.1) Confirm the existing 5s debounce coalesces wake bursts correctly with measurable logging. (2.2) Confirm `WKWatchConnectivityRefreshBackgroundTask` is actually received in `WatchState.handleBackgroundTasks` after BT reconnect. Both are verification tasks that confirm expected behavior, not behavior changes.

**Gate:** None. Parallel with Phase 1.

---

### 2.1 Wake burst: debounce logging and verification

- **Where:** `TrioComplicationDataStore.swift` — `coalescedReloadOnMain`.
- **What:** Add burst-window counter logging. Each burst window is identified by a `burst_window_id` (a monotonically incrementing counter or UUID reset when a reload fires) so window boundaries are mechanically identifiable in log queries, not just by timestamp proximity.
- **Acceptance (deterministic):** On a real device (not simulator), trigger ≥14 rapid `save()` calls within 1 second. Logs must show: exactly 1 `"🔄 Reload TRIGGERED burst_window_id=N"` event within the 5s window; ≥13 `"⏳ Reload DEBOUNCED burst_window_id=N suppressed=K"` entries all sharing the same `burst_window_id`. The same `burst_window_id` on all suppressed events and the trigger event is the verifiable boundary. Document result in PR description.
- **Do not:** Change debounce interval or add a second debounce mechanism.

#### Cursor prompt — Phase 2.1

```
Logging change only to TrioComplicationDataStore.swift — coalescedReloadOnMain.
No behavior changes.

1. Add a burst window counter (an Int property on the DataStore, or a static var):
   - Starts at 0. Increments each time a reload is triggered (i.e. when the debounce
     window opens). Used as burst_window_id in log messages.
   - A suppression counter (also Int, reset to 0 when a reload fires) tracks how many
     calls were debounced in the current window.

2. When coalescedReloadOnMain debounces (minInterval not elapsed):
   - Increment suppression counter.
   - Log: "⏳ Reload DEBOUNCED burst_window_id=\(windowId) suppressed=\(suppressCount)
          elapsed=\(elapsed)s min=\(minInterval)s"

3. When coalescedReloadOnMain fires a reload:
   - Log: "🔄 Reload TRIGGERED burst_window_id=\(windowId) suppressed=\(suppressCount)"
   - Increment windowId; reset suppressCount to 0.

4. No change to when reloads fire or the debounce interval.

5. After deploying, on a REAL DEVICE (not simulator): trigger ≥14 rapid save() calls
   within 1 second to validate coalescing + burst_window_id logging.

   To make this repeatable, wire an existing watch debug UI button (e.g. "Refresh View")
   to run a "Burst Save x14" action:
   - On tap, log a clear marker: "🧪 Burst Save Test START count=14"
   - Then call save() 14 times rapidly (back-to-back or tiny delay, but all within 1s),
     using the same code path a real update uses.

   Confirm in logs:
   - Exactly 1 TRIGGERED entry with a given burst_window_id within the 5s window.
   - ≥13 DEBOUNCED entries all sharing the same burst_window_id.
   Record test result (log snippet or screenshot) in PR description.
```

---

### 2.2 Background delivery logging: verify WKWatchConnectivityRefreshBackgroundTask

**Decision: Option B — logging only, keep existing 5s behavior.** The current code in `WatchState.handleBackgroundTasks` completes the task after a fixed 5-second delay without checking `hasContentPending`. This phase adds structured logging around the existing logic without changing it. The logging provides the evidence needed to decide whether Option A (hasContentPending wait) is ever justified. Implement Option A only if the log analysis in the BetterStack query below proves the 5s window is insufficient — not before.

**Code location:** `WatchState.handleBackgroundTasks` — **not** `ExtensionDelegate.handle`. Add logging there. Optionally add a single entry log in ExtensionDelegate if it forwards to WatchState, to make the full call path traceable.

- **Acceptance:** Simulate BT reconnect (watch screen off, do not open the app). Within ~60s of reconnect, logs must contain the required structured events (e.g. `complication_bgtask_received` and `complication_bgtask_completing` with `window_id`) and, if present, the human-readable strings from the prompt. If never observed after multiple attempts: follow the post-reconnect investigation note.
- **Do not:** Change the 5s delay, the completion logic, or anything that happens when `didReceiveUserInfo` fires.

#### Cursor prompt — Phase 2.2

```
Logging change only to WatchState.handleBackgroundTasks.
Do NOT change when or how the task is completed. Do NOT change the logic or behavior
of didReceiveUserInfo (save path, processing); the only change there is adding the
log line in step 4 below.

This is NOT ExtensionDelegate.handle — the actual background task handling is in
WatchState.handleBackgroundTasks. Add logging there. If ExtensionDelegate forwards
to WatchState, add a single log line at the ExtensionDelegate entry point too so
the full call path is visible.

STRUCTURED LOG FIELDS (required): Emit the same structured-field shape as Phase 0.1.
Do not rely only on free-text in message. Emit at least:
- event (e.g. "complication_bgtask_received" / "complication_bgtask_completing")
- window_id (Int)
- task_type (String, exactly "WKWatchConnectivityRefreshBackgroundTask")
Optional numeric field:
- completion_delay_ms (Int) on completing logs (computed from received->completing)

If the pipeline cannot emit structured JSON fields (only a single message string),
embed stable key-value tokens in the message, e.g.
event=complication_bgtask_received window_id=42 task_type=WKWatchConnectivityRefreshBackgroundTask
and keep that format stable.

BackgroundTaskWindowCounter:
- In-memory monotonic counter for next() window ids.
- Store lastWindowId + lastReceivedAt.
- currentOrNil() returns lastWindowId only if now - lastReceivedAt <= 30s, else nil.

1) At the point where WKWatchConnectivityRefreshBackgroundTask is matched/received,
   add BEFORE any existing logic:
   let bgTaskWindowId = BackgroundTaskWindowCounter.next()
   debugLog with structured fields:
     event="complication_bgtask_received"
     window_id=bgTaskWindowId
     task_type="WKWatchConnectivityRefreshBackgroundTask"
   Optionally message: "📡 BGTask received: WKWatchConnectivityRefreshBackgroundTask window_id=\(bgTaskWindowId)"

2) Immediately before the existing setTaskCompleted() call (inside the existing 5s delay block),
   add:
   debugLog with structured fields:
     event="complication_bgtask_completing"
     window_id=bgTaskWindowId
     task_type="WKWatchConnectivityRefreshBackgroundTask"
     completion_delay_ms=<ms between received and completing for this window>
   Optionally message: "📡 BGTask completing: WKWatchConnectivityRefreshBackgroundTask window_id=\(bgTaskWindowId)"

3) No other changes. Do not add a hasContentPending loop. Do not change the 5s delay.

4) In the watch WCSession delegate (didReceiveUserInfo), add a single log line.
   Structured fields where supported:
     event="complication_did_receive_user_info"
     window_id=<BackgroundTaskWindowCounter.currentOrNil() ?? -1>
     reading_date_epoch=<epoch seconds from decoded payload readingDate, else -1>
   IMPORTANT: Do not do extra decoding/parsing work here solely for logging. If readingDate
   is not already available at this log site without new work, log reading_date_epoch=-1.

After deploying:
- Disable BT on iPhone, wait 30s, re-enable BT, do NOT open the watch app.
- Wait up to 60s.
- Confirm both received and completing logs appear.
- Document the two lines + completion_delay_ms (or timestamp delta) in the PR description.
```

---

### 2.2 Option A trigger criteria and BetterStack analysis query

**When to implement Option A:** Only if the log analysis below produces at least one of these outcomes across a sustained observation period (minimum 3–5 days of normal use after Phase 2.2 ships):


| Signal                                                                                                                | Meaning                                                                                                        | Threshold |
| --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `didReceiveUserInfo` fires **after** `"📡 BGTask completing"` for the same background task wake                       | Data arrived after the task already completed — the 5s window was too short                                    | Any occurrence (zero tolerance) |
| `"📡 BGTask received"` appears but **no** `complication_save_age` or `complication_reload_age` log follows within 30s | Task was received but no save/reload happened — content may have been dropped when the extension suspended     | Persistent (>20% of reconnect events) |
| Reconnect scenario produces stale complication >10 min even though `"📡 BGTask received"` is logged                   | Background delivery is occurring but Phase 1+3 didn't fix the staleness — points to 5s completion as the cause | Consistent pattern across multiple reconnect events |
| For the **same `reading_date_epoch_seconds`**: `complication_did_receive_user_info` dt occurs **after** the `complication_bgtask_completing` dt for any window in the same reading's delivery chain | The watch received the data only after the BGTask safety window had already closed — the 5s window was too short for this reading | Any sustained occurrence (>5% of readings over a 7-day window); confirm with per-reading join query from Phase 2.3.4 |


**If none of these patterns appear:** The current 5s behavior is sufficient and Option A is unnecessary.

**If Option A is triggered:** File a follow-on task with the specific log evidence. The implementation should use a KVO or notification-based approach on `hasContentPending` (not the polling loop in v1.5) and a safety timeout set to `platform_limit_seconds - 5s` (verify the platform limit for the current deployment target first; `var completed = false` as the double-completion guard, not `task.isCompleted` which does not exist).

#### BetterStack MCP query prompt — Phase 2.2 log analysis

Run this with Cursor using the Better Stack MCP server after Phase 2.2 has been in production for at least 3 days:

```
Use the Better Stack MCP server to analyze Phase 2.2 background task delivery logs
for the Trio watch app. Follow the AGENTS.md query procedure.

Step 1 — Create cloud connection:
Call telemetry_create_cloud_connection_tool with team_id=491594 and source_id=1659391.
If that fails, call telemetry_list_teams_tool and telemetry_list_sources_tool to
discover the correct IDs, then retry.

Query convention — structured fields first:
Use JSONExtract(raw,'event','Nullable(String)'), JSONExtract(raw,'task_type','Nullable(String)'),
JSONExtract(raw,'window_id','Nullable(Int64)') for filtering whenever your pipeline
stores these in raw. Use message LIKE only when structured fields are not available
(see Fallback sections below).

Step 2 — Task receipt volume (last 72 hours, hot + S3):

Default (structured): filter by event and task_type.

SELECT
    toStartOfHour(dt) AS hour,
    countIf(JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask') AS received,
    countIf(JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_completing'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask') AS completing,
    received - completing AS hour_bucket_delta
FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE dt > now() - INTERVAL 72 HOUR
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
)
GROUP BY hour
ORDER BY hour DESC
LIMIT 72;

table: "t491594.trio"
source_id: 1659391

Note: hour_bucket_delta is not strict pairing — a received and its completing event
can straddle an hour boundary, so small deltas per bucket are normal. Persistent
large positive deltas suggest tasks received but not completing in the log window.

Optional — window_id pairing (when window_id is in raw): count received events that
have no completing event for the same window_id within 60s.

SELECT count(*) AS received_with_no_completing_same_window
FROM (
    SELECT
        JSONExtract(raw,'window_id','Nullable(Int64)') AS wid,
        dt AS received_dt
    FROM (
        SELECT dt, raw FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
        UNION ALL
        SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
    )
) AS recv
WHERE wid IS NOT NULL AND wid > 0
AND NOT EXISTS (
    SELECT 1 FROM (
        SELECT dt, JSONExtract(raw,'window_id','Nullable(Int64)') AS wid2 FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_completing'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
        UNION ALL
        SELECT dt, JSONExtract(raw,'window_id','Nullable(Int64)') AS wid2 FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_completing'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
    ) AS comp
    WHERE wid2 = recv.wid AND comp.dt >= recv.received_dt AND comp.dt <= recv.received_dt + INTERVAL 60 SECOND
);

table: "t491594.trio"
source_id: 1659391

Fallback (message only): if event/task_type are not in raw, use
  countIf(JSONExtract(raw,'message','Nullable(String)') LIKE '%BGTask received: WKWatchConnectivityRefreshBackgroundTask%')
  countIf(JSONExtract(raw,'message','Nullable(String)') LIKE '%BGTask completing: WKWatchConnectivityRefreshBackgroundTask%')
  and alias received - completing AS hour_bucket_delta.

Step 3 — Delivery timing: does data arrive after task completes?

Return columns: dt, event, task_type, window_id, message (if present). Correlate
received → completing → complication_save_age by (window_id + ~10s time window).

Default (structured):

SELECT
    dt,
    JSONExtract(raw,'event','Nullable(String)') AS event,
    JSONExtract(raw,'task_type','Nullable(String)') AS task_type,
    JSONExtract(raw,'window_id','Nullable(Int64)') AS window_id,
    JSONExtract(raw,'message','Nullable(String)') AS message
FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE dt > now() - INTERVAL 72 HOUR
    AND (
        JSONExtract(raw,'event','Nullable(String)') IN ('complication_bgtask_received','complication_bgtask_completing')
        OR JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
        OR JSONExtract(raw,'message','Nullable(String)') LIKE '%Watch received data%'
    )
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
    AND (
        JSONExtract(raw,'event','Nullable(String)') IN ('complication_bgtask_received','complication_bgtask_completing')
        OR JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
        OR JSONExtract(raw,'message','Nullable(String)') LIKE '%Watch received data%'
    )
)
ORDER BY dt ASC
LIMIT 500;

table: "t491594.trio"
source_id: 1659391

Guidance: For each wake, order by dt and look for received → completing → (optional)
complication_save_age. Pair by window_id when present; use a ~10s time window as
backstop (window_id can reset on process restart). If any complication_save_age
occurs AFTER a completing event for the same window_id (or within ~10s), that is
evidence the 5s window may be too short (Option A trigger).

Fallback: if event is not in raw, filter by message LIKE '%BGTask received%',
'%BGTask completing%', '%complication_save_age%', '%Watch received data%' and
return dt, message only.

Step 4 — Missing delivery: received but no save follows

Prefer window-safe correlation (join by window_id + 60s) when window_id is available.
Use time-only heuristic only when window_id is missing; it can produce false matches
(save from a different wake satisfying EXISTS).

(4a) Default — window-safe (when window_id in raw): count received events that have
no complication_save_age in the same window (same window_id, save within 60s of
received_dt). Requires event/window_id in raw.

SELECT count(*) AS received_with_no_save_same_window
FROM (
    SELECT
        JSONExtract(raw,'window_id','Nullable(Int64)') AS wid,
        dt AS received_dt
    FROM (
        SELECT dt, raw FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
        UNION ALL
        SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
        AND JSONExtract(raw,'task_type','Nullable(String)') = 'WKWatchConnectivityRefreshBackgroundTask'
    )
) AS recv
WHERE wid IS NOT NULL AND wid > 0
AND NOT EXISTS (
    SELECT 1 FROM (
        SELECT dt FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
        UNION ALL
        SELECT dt FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
    ) AS saves
    WHERE saves.dt >= recv.received_dt AND saves.dt <= recv.received_dt + INTERVAL 60 SECOND
);

(4b) Fallback — time-only (only when window_id missing): count "received" with no
complication_save_age within 30s by time only. Warning: a save from a different
wake can wrongly satisfy EXISTS and undercount; treat sustained >20% as evidence.

SELECT count(*) AS received_with_no_save_within_30s
FROM (
    SELECT dt AS task_received_dt
    FROM (
        SELECT dt, raw FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND (JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
             OR JSONExtract(raw,'message','Nullable(String)') LIKE '%BGTask received: WKWatchConnectivityRefreshBackgroundTask%')
        UNION ALL
        SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND (JSONExtract(raw,'event','Nullable(String)') = 'complication_bgtask_received'
             OR JSONExtract(raw,'message','Nullable(String)') LIKE '%BGTask received: WKWatchConnectivityRefreshBackgroundTask%')
    )
) AS tasks
WHERE NOT EXISTS (
    SELECT 1 FROM (
        SELECT dt FROM remote(t491594_trio_logs)
        WHERE dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
        UNION ALL
        SELECT dt FROM s3Cluster(primary, t491594_trio_s3)
        WHERE _row_type = 1 AND dt > now() - INTERVAL 72 HOUR
        AND JSONExtract(raw,'message','Nullable(String)') LIKE '%complication_save_age%'
    ) AS saves
    WHERE saves.dt BETWEEN tasks.task_received_dt AND tasks.task_received_dt + INTERVAL 30 SECOND
);

table: "t491594.trio"
source_id: 1659391

If received_with_no_save (4a or 4b) > 20% of total received (Step 2), treat as
evidence of dropped content. (4a) is reliable per wake; (4b) is heuristic.

Step 5 — Summarize findings:

Based on the queries above, answer:
1. Is WKWatchConnectivityRefreshBackgroundTask being received consistently after
   BT reconnect? (Step 2 volume)
2. Is data (complication_save_age) arriving AFTER the task completes? (Step 3)
3. Are there received-but-no-save events at >20% rate? (Step 4)
4. Recommendation: is Option A (hasContentPending wait) justified by the evidence?

Output: plain-language summary with the specific log evidence that supports or
refutes the Option A trigger criteria defined in Phase 2.2 of the implementation plan.
```

---

### Post-reconnect staleness: investigation note (not a task)

If Phase 2.2 log entries do not appear after BT reconnect with watch screen off:

1. `**WatchState.handleBackgroundTasks` not reached:** Confirm ExtensionDelegate correctly forwards background tasks to WatchState and that `WCSession.default.activate()` is called at extension init.
2. **Only first delivery generates a background task:** After the first `WKWatchConnectivityRefreshBackgroundTask`, subsequent deliveries in the same session go directly to the WCSession delegate. This is normal; `didReceiveUserInfo` still fires for subsequent deliveries.
3. `**transferCurrentComplicationUserInfo` vs `transferUserInfo`:** The complication-specific transfer has a dedicated daily budget and higher system priority. If the iOS side uses only `transferUserInfo`, switching for CGM payloads may improve wake reliability.
4. **File protection on underlying storage:** If the watch is locked when the background task fires, storage protected with restrictive file protection attributes may be inaccessible. This is not a `UserDefaults` API setting — it is a property of the underlying files. Investigate whether the files backing your snapshot and fingerprint storage (wherever they are persisted on disk) have restrictive NSFileProtection attributes set, using `NSFileManager.default.attributesOfItem(atPath:)` to check `FileAttributeKey.protectionKey`. The correct attribute for background-accessible storage is `.completeFileProtectionUntilFirstUserAuthentication` or lower. The actual storage mechanism determines where to look (UserDefaults backing plist, custom file, etc.).

---

---

## Phase 2.3: Cross-platform join key + structured log fields + freshness decomposition

**Goal:** Close the remaining observability gap between phone and watch logs. Enable per-reading end-to-end analysis without approximation. Formalize the freshness decomposition as a standing dashboard query. Tighten the Option A gate definition now that per-reading joins are possible.

**Gate:** Phases 0.1, 0.2, 2.2 complete. ✅

**Behavior changes:** None. All tasks are logging, pipeline, dashboard, or doc changes only.

**Deployment order (important):**
1. **2.3.1** — code change (iOS), one line. Ship as its own build. Verify in BetterStack within 24h before proceeding to 2.3.2.
2. **2.3.2** — code change (cloud logging encoder). Ship as its own build. Verify in BetterStack within 24h.
3. **2.3.3, 2.3.4, 2.3.5, 2.3.6** — no build required. Run in parallel after 2.3.1 data is flowing (some queries need the new field; dashboard panels can be drafted immediately).

---

### 2.3.1 Phone transfer log enrichment (cross-platform join key)

**Status: Complete.** Deployed in build 128 (2026-03-08). BetterStack verified: `reading_date_epoch_seconds` present on all iOS transfer events, cross-platform epoch join confirmed matching watch-side `reading_date_epoch`.

- **Where:** iOS `AppleWatchManager.swift` — the `"📤 Transferred new WatchState snapshot via userInfo"` log line.
- **What:** Append `reading_date_epoch_seconds=<Int>` to the existing log message. This must be the CGM reading's timestamp from the WatchState snapshot — not the transfer time (`Date()`). Same field name and semantic as watch-side Phase 0.1 events.
- **Why:** Currently the phone-to-watch dispatch is invisible in per-reading analysis. This single token enables BetterStack queries to join `Transferred via userInfo` (iOS, platform=ios) → `complication_did_receive_user_info` (watchOS) → `complication_save_age` → `complication_reload_age` on one epoch key, replacing stacked-median estimates with measured per-reading end-to-end latency.
- **Do not:** Log the current transfer time as `reading_date_epoch_seconds`. Log the reading's date. Do not rename the field — it must match the watch-side convention exactly. Do not add any other fields in this task.
- **Acceptance:** Within 24h of deploy, a BetterStack query filtering `raw LIKE '%Transferred new WatchState snapshot via userInfo%'` returns rows where `extract(message, 'reading_date_epoch_seconds=([0-9]+)')` is non-null and matches the corresponding watch-side `complication_did_receive_user_info reading_date_epoch=` for the same reading within the same minute.

#### Cursor prompt — Phase 2.3.1

```
Logging change only to AppleWatchManager.swift. No behavior changes. One line added.

Find the log line that emits "📤 Transferred new WatchState snapshot via userInfo".

1. Identify the WatchState snapshot (or equivalent struct) available at that call site.
   Verify the property name for the CGM reading's date (e.g. snapshot.readingDate or
   equivalent). Do not guess — check the actual model.

2. Append to the existing log message (do not replace it):
     reading_date_epoch_seconds=\(Int(snapshot.readingDate.timeIntervalSince1970))

   Final message should look like:
     "📤 Transferred new WatchState snapshot via userInfo reading_date_epoch_seconds=1772965953"

3. FIELD NAMING RULE: reading_date_epoch_seconds is the CGM reading's timestamp.
   Do NOT log Date() or any other timestamp here. This field must carry the same
   value that watch-side complication_save_age and complication_did_receive_user_info
   log as reading_date_epoch_seconds / reading_date_epoch — i.e. the epoch seconds
   of the glucose reading itself, not when the transfer occurred.

4. No other changes. Do not modify the transfer logic or any other log line.

After deploying, run a BetterStack spot query within 24h:
  SELECT
    dt,
    extract(JSONExtract(raw,'message','Nullable(String)'), 'reading_date_epoch_seconds=([0-9]+)') AS epoch
  FROM remote(t491594_trio_logs)
  WHERE dt > now() - INTERVAL 2 HOUR
    AND JSONExtract(raw,'platform','Nullable(String)') = 'ios'
    AND raw LIKE '%Transferred new WatchState snapshot via userInfo%'
  ORDER BY dt DESC LIMIT 20
Verify epoch is non-null and matches the reading shown in currentGlucose for that minute.
```

---

### 2.3.2 Structured log fields for Phase 2.2 events

**Status: Complete.** Deployed in build 129 (2026-03-08). BetterStack verified: `JSONExtract(raw,'event',...)`, `JSONExtract(raw,'window_id',...)`, and `JSONExtract(raw,'task_type',...)` return expected values for complication BGTask events.

- **Where:** `06-cloud-logging` patch — `CloudLogEvent.encode(to:)` and the watch-side log attribute whitelist.
- **What:** Extend the encoder to parse `event=`, `window_id=`, and `task_type=` tokens from the watch message and emit them as top-level JSON keys in the Better Stack payload. This eliminates the `message LIKE '%event=complication_bgtask_received%'` fallback queries and enables the Step 4b window-safe BetterStack correlations defined in Phase 2.2.
- **Why:** Carried as an open item since v1.11. Phase 2.2 analysis is complete and the query patterns are established. Promoting these to first-class fields is cleanup with no open design questions.
- **Scope:** `event` (String), `window_id` (Int), `task_type` (String). No other fields in this task.
- **Do not:** Remove the tokens from the message string. Existing `LIKE`-based dashboard queries must continue to work during and after the transition. This is an encoder change only — no log call site changes, no message text changes, no behavior changes.
- **Acceptance:** After deploy, `JSONExtract(raw, 'event', 'Nullable(String)')` returns the event name for complication log entries (e.g. `'complication_bgtask_received'`). Verify with a BetterStack spot query within 24h of deploy:
  ```sql
  SELECT dt,
    JSONExtract(raw,'event','Nullable(String)') AS event,
    JSONExtract(raw,'window_id','Nullable(Int64)') AS window_id
  FROM remote(t491594_trio_logs)
  WHERE dt > now() - INTERVAL 2 HOUR
    AND raw LIKE '%complication_bgtask%'
  ORDER BY dt DESC LIMIT 20
  ```
  Confirm `event` and `window_id` are non-null for bgtask rows.

#### Cursor prompt — Phase 2.3.2

```
Change: 06-cloud-logging patch (CloudLogEvent or equivalent encoder).
Logging pipeline change only. No behavior changes anywhere. No log call site changes.

Context: watch-side complication events are logged with stable key=value tokens
in the message string, e.g.:
  "event=complication_bgtask_received window_id=42 task_type=WKWatchConnectivityRefreshBackgroundTask"
These are currently parsed via LIKE queries in BetterStack. Goal: promote them
to top-level JSON fields in the raw payload so JSONExtract(raw,'event',...) works.

1. In the encoder (CloudLogEvent.encode or equivalent):
   After encoding the existing whitelisted attributes, parse the message string for
   these stable tokens using extract/regex on the message:
     event     = extract(message, 'event=([a-zA-Z0-9_]+)')
     window_id = Int(extract(message, 'window_id=([0-9-]+)'))  -- only if parseable as Int
     task_type = extract(message, 'task_type=([a-zA-Z0-9_.]+)')

   If a token is present and parseable, write it as a top-level key in the JSON
   payload alongside the existing whitelisted attributes.

2. Do NOT remove the tokens from the message string. Existing LIKE-based queries
   must continue to work. These new top-level fields are purely additive.

3. Scope: only these three fields (event, window_id, task_type) in this PR.
   Do not add other fields.

4. Acceptance (verify in BetterStack within 24h of deploy):
   For a log line containing "event=complication_bgtask_received window_id=5":
     JSONExtract(raw, 'event', 'Nullable(String)')    → 'complication_bgtask_received'
     JSONExtract(raw, 'window_id', 'Nullable(Int64)') → 5
   And the message LIKE '%event=complication_bgtask_received%' filter still works.
```

---

### 2.3.3 Receive_lag dashboard panel

**Status: Complete.** Dashboard 914638 section "End-to-End Freshness Decomposition (Phase 2.3)" contains: Receive Lag p50/p90/max line chart (30-min buckets, chart ID 8801948580), Receive Lag p50 number chart (8799383509), Receive Lag p90 number chart (8799383776).

- **Where:** BetterStack dashboard 914638. New panel in a "End-to-End Freshness Decomposition (Phase 2.3)" section.
- **What:** A named, standing chart for `receive_lag` — the delta between CGM reading time and when the watch receives the data (`complication_did_receive_user_info dt` minus `reading_date_epoch`). This is the most actionable single metric: it captures WatchConnectivity queue flush time per reading and will be the primary signal to watch after any session-activation improvements.
- **Why distinct from the full decomposition query (2.3.4):** The full join query is run on-demand. This is a standing hourly trend line so you can see receive_lag drift over time without running a manual query.
- **Baseline to verify against:** p50 ~38s, p90 ~278s (2026-03-08, watch-side 3-way join, n=16 — small sample; this panel will establish the definitive baseline with larger n).
- **Acceptance:** Panel exists in dashboard 914638 showing receive_lag p50/p90/max per hour. After Phase 2.3.1 deploys, companion phone-side panel added using iOS transfer epoch to get the full phone→watch span.

#### BetterStack MCP query — Phase 2.3.3 (receive_lag trend)

```
Use the Better Stack MCP server to compute per-hour receive_lag for the Trio
watch complication: time from CGM reading until watch did_receive_user_info fires.
This is the primary actionable metric for WatchConnectivity session activation.

SELECT
  toStartOfHour(dt) AS hour,
  count() AS n,
  quantile(0.5)(
    dateDiff('second',
      toDateTime(toInt64OrNull(extract(JSONExtract(raw,'message','Nullable(String)'),
        'reading_date_epoch=([0-9]+)'))),
      dt)
  ) AS p50_receive_lag_s,
  quantile(0.9)(
    dateDiff('second',
      toDateTime(toInt64OrNull(extract(JSONExtract(raw,'message','Nullable(String)'),
        'reading_date_epoch=([0-9]+)'))),
      dt)
  ) AS p90_receive_lag_s,
  max(
    dateDiff('second',
      toDateTime(toInt64OrNull(extract(JSONExtract(raw,'message','Nullable(String)'),
        'reading_date_epoch=([0-9]+)'))),
      dt)
  ) AS max_receive_lag_s
FROM (
  SELECT dt, raw FROM remote(t491594_trio_logs)
  WHERE dt > now() - INTERVAL 48 HOUR
  UNION ALL
  SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
  WHERE _row_type = 1 AND dt > now() - INTERVAL 48 HOUR
)
WHERE raw LIKE '%event=complication_did_receive_user_info%'
  AND toInt64OrNull(extract(JSONExtract(raw,'message','Nullable(String)'),
    'reading_date_epoch=([0-9]+)')) IS NOT NULL
  AND dateDiff('second',
    toDateTime(toInt64OrNull(extract(JSONExtract(raw,'message','Nullable(String)'),
      'reading_date_epoch=([0-9]+)'))),
    dt) BETWEEN 0 AND 1800
GROUP BY hour
ORDER BY hour DESC

table: "t491594.trio"
source_id: 1659391

Note: This query works today with existing did_receive_user_info events.
After Phase 2.3.1 deploys, add a companion phone-side panel using the same
reading_date_epoch_seconds field from iOS transfer logs to get the full
phone→watch span.
```

---

### 2.3.4 Freshness decomposition: standing query + dashboard panel

**Status: Complete.** Dashboard 914638 section "End-to-End Freshness Decomposition (Phase 2.3)" contains per-stage panels: Receive Lag (WC queue flush), Provider Latency (WidgetKit getTimeline), Save Age, Reload Age — all showing p50/p90/max at 30-min granularity. Freshness decomposition formula added to `snapshot-age-improvements-suggestions.md` §3.4 (v1.2).

- **Where:** BetterStack dashboard 914638. A new section "End-to-End Freshness Decomposition (Phase 2.3)."
- **What:**
  1. A canonical BetterStack MCP query that computes per-stage p50/p90 for each pipeline segment, joined on `reading_date_epoch_seconds`. Run on-demand or scheduled.
  2. A receive_lag panel: `did_receive_user_info dt - reading_date_epoch` per hour, showing p50/p90/max trend over time.
  3. A sleep-gap classifier panel (see 2.3.4).
- **Also:** Add the freshness decomposition formula to `snapshot-age-improvements-suggestions.md` §3.4 alongside the SLA targets (Phase 4.1 doc).

#### BetterStack MCP query — Phase 2.3.4 (freshness decomposition, run after 2.3.1 deployed)

```
Use the Better Stack MCP server to compute per-reading end-to-end freshness
decomposition for the Trio watch app. Run after Phase 2.3.1 is deployed and
reading_date_epoch_seconds appears in iOS transfer logs.

Create cloud connection: telemetry_create_cloud_connection_tool(team_id=491594, source_id=1659391)

For each reading_date_epoch_seconds, compute the first occurrence of each event
and derive per-stage deltas. Use a strict join — only include readings where
all stages are present. Report counts separately so sample size is visible.

WITH all_events AS (
  SELECT
    dt,
    JSONExtract(raw,'platform','Nullable(String)') AS platform,
    JSONExtract(raw,'message','Nullable(String)') AS msg
  FROM (
    SELECT dt, raw FROM remote(t491594_trio_logs)
    WHERE dt > now() - INTERVAL 24 HOUR
    UNION ALL
    SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
    WHERE _row_type = 1 AND dt > now() - INTERVAL 24 HOUR
  )
  WHERE
    raw LIKE '%Transferred new WatchState snapshot via userInfo%'
    OR raw LIKE '%event=complication_did_receive_user_info%'
    OR raw LIKE '%event=complication_save_age%'
    OR raw LIKE '%event=complication_reload_age%'
),
parsed AS (
  SELECT
    dt,
    platform,
    multiIf(
      msg LIKE '%Transferred new WatchState%',
        toInt64OrNull(extract(msg,'reading_date_epoch_seconds=([0-9]+)')),
      msg LIKE '%did_receive_user_info%',
        toInt64OrNull(extract(msg,'reading_date_epoch=([0-9]+)')),
      msg LIKE '%complication_save_age%' OR msg LIKE '%complication_reload_age%',
        toInt64(toUnixTimestamp(dt)) - toInt64OrNull(extract(msg,'age_seconds=([0-9]+)')),
      NULL
    ) AS reading_epoch,
    multiIf(
      msg LIKE '%Transferred new WatchState%', 'phone_transfer',
      msg LIKE '%did_receive_user_info%', 'watch_receive',
      msg LIKE '%complication_save_age%', 'watch_save',
      msg LIKE '%complication_reload_age%', 'watch_reload',
      NULL
    ) AS stage
  FROM all_events
  WHERE reading_epoch IS NOT NULL
),
per_reading AS (
  SELECT
    reading_epoch,
    minIf(dt, stage = 'phone_transfer') AS transfer_dt,
    minIf(dt, stage = 'watch_receive') AS receive_dt,
    minIf(dt, stage = 'watch_save') AS save_dt,
    minIf(dt, stage = 'watch_reload') AS reload_dt
  FROM parsed
  GROUP BY reading_epoch
)
SELECT
  countIf(transfer_dt IS NOT NULL AND receive_dt IS NOT NULL
          AND save_dt IS NOT NULL AND reload_dt IS NOT NULL) AS n_fully_joined,
  -- Stage 1: phone transfer → watch receive (WatchConnectivity queue flush)
  quantile(0.5)(if(transfer_dt IS NOT NULL AND receive_dt IS NOT NULL
    AND dateDiff('second',transfer_dt,receive_dt) BETWEEN 0 AND 1800,
    dateDiff('second',transfer_dt,receive_dt), NULL)) AS p50_wc_queue_flush,
  quantile(0.9)(if(transfer_dt IS NOT NULL AND receive_dt IS NOT NULL
    AND dateDiff('second',transfer_dt,receive_dt) BETWEEN 0 AND 1800,
    dateDiff('second',transfer_dt,receive_dt), NULL)) AS p90_wc_queue_flush,
  -- Stage 2: watch receive → save
  quantile(0.5)(if(receive_dt IS NOT NULL AND save_dt IS NOT NULL
    AND dateDiff('second',receive_dt,save_dt) BETWEEN 0 AND 600,
    dateDiff('second',receive_dt,save_dt), NULL)) AS p50_receive_to_save,
  quantile(0.9)(if(receive_dt IS NOT NULL AND save_dt IS NOT NULL
    AND dateDiff('second',receive_dt,save_dt) BETWEEN 0 AND 600,
    dateDiff('second',receive_dt,save_dt), NULL)) AS p90_receive_to_save,
  -- Stage 3: save → reload requested
  quantile(0.5)(if(save_dt IS NOT NULL AND reload_dt IS NOT NULL
    AND dateDiff('second',save_dt,reload_dt) BETWEEN 0 AND 600,
    dateDiff('second',save_dt,reload_dt), NULL)) AS p50_save_to_reload,
  quantile(0.9)(if(save_dt IS NOT NULL AND reload_dt IS NOT NULL
    AND dateDiff('second',save_dt,reload_dt) BETWEEN 0 AND 600,
    dateDiff('second',save_dt,reload_dt), NULL)) AS p90_save_to_reload,
  -- End-to-end: phone transfer → reload requested
  quantile(0.5)(if(transfer_dt IS NOT NULL AND reload_dt IS NOT NULL
    AND dateDiff('second',transfer_dt,reload_dt) BETWEEN 0 AND 1800,
    dateDiff('second',transfer_dt,reload_dt), NULL)) AS p50_transfer_to_reload,
  quantile(0.9)(if(transfer_dt IS NOT NULL AND reload_dt IS NOT NULL
    AND dateDiff('second',transfer_dt,reload_dt) BETWEEN 0 AND 1800,
    dateDiff('second',transfer_dt,reload_dt), NULL)) AS p90_transfer_to_reload
FROM per_reading

table: "t491594.trio"
source_id: 1659391

Note: n_fully_joined will be smaller than total readings because not every reading
produces all four events (e.g. some transfers are retries; some reloads are coalesced).
Report n_fully_joined alongside the percentiles so sample size is visible.
WidgetKit scheduling latency (reload_requested → getTimeline) is not in this query —
use the existing complication_get_timeline_called latency_seconds panel for that stage.
```

#### Doc update — Phase 2.3.4

```
Doc-only change: snapshot-age-improvements-suggestions.md §3.4.
Add the following block after the SLA targets. Do not reformat surrounding text.

---
**Freshness decomposition (empirically derived, 2026-03-08):**

  save_age        ≈ WatchConnectivity queue flush lag
                    (receive→save ≈ 0s; save_age is almost entirely the time
                    the data spends queued in WatchConnectivity before the
                    watch session activates and drains it)

  reload_age      ≈ save_age + save→reload delay
                    (save→reload ≈ 0s median; bounded by 5s coalescer)

  wrist freshness ≈ reload_age + WidgetKit scheduling latency
                    (provider latency: p50 ~101s, p90 ~440s; ~32% coalescing rate)

Observed baselines (12h, 2026-03-08, hot+S3):
  save_age:    p50 ~161s,  p90 ~437s
  reload_age:  p50 ~278s,  p90 ~543s
  WC reachability: 62–68% of transfers find watch not immediately reachable (active hours)

The dominant controllable lever is WatchConnectivity session activation latency.
WidgetKit scheduling is the secondary delay and is largely platform-constrained.
Use Phase 2.3 per-reading join queries to update these baselines after Phase 3 ships.
---
```

---

### 2.3.5 Sleep-gap classifier

**Status: Complete.** Dashboard 914638 chart "Sleep-Gap Classifier (provider-only hours)" (ID 8804994375) shows per-hour getTimeline calls, reload requests, and valid latency events. Sleep gaps appear as hours where only getTimeline has values (others at zero). Verified: 2026-03-08 03:00–04:00 UTC flagged as SLEEP_GAP (overnight, expected). On-demand query also verified (see Phase 2.3.5 query template below).

- **Where:** BetterStack — new dashboard panel or on-demand MCP query.
- **What:** Detect hourly periods where `complication_get_timeline_called > 0` but `complication_save_age = 0` AND `complication_reload_requested = 0` AND `complication_bgtask_received = 0`. These are provider-only periods: WidgetKit is polling but the watch app is not running, meaning the complication is serving a cached (stale) timeline.
- **Why:** Distinguishes "platform asleep" (acceptable) from "delivery broken" (actionable). Sleep gaps are expected overnight and produce the worst outliers (e.g. the 3201s max reload_age at 06:25 UTC observed 2026-03-08).
- **Acceptance:** Query returns one row per detected gap with start time and duration in minutes. Overnight gaps flagged as expected; any gap >30 min outside 01:00–06:00 local time warrants investigation.

#### BetterStack MCP query — Phase 2.3.5 (sleep-gap classifier)

```
Use the Better Stack MCP server to detect sleep-gap hours for the Trio watch
complication: hours where WidgetKit polls but the watch app is fully asleep.

Create cloud connection: telemetry_create_cloud_connection_tool(team_id=491594, source_id=1659391)

SELECT
  toStartOfHour(dt) AS hour,
  countIf(raw LIKE '%event=complication_get_timeline_called%') AS timeline_calls,
  countIf(raw LIKE '%event=complication_save_age%') AS save_events,
  countIf(raw LIKE '%event=complication_reload_requested%') AS reload_events,
  countIf(raw LIKE '%event=complication_bgtask_received%') AS bgtask_received,
  multiIf(
    countIf(raw LIKE '%event=complication_get_timeline_called%') > 0
    AND countIf(raw LIKE '%event=complication_save_age%') = 0
    AND countIf(raw LIKE '%event=complication_reload_requested%') = 0
    AND countIf(raw LIKE '%event=complication_bgtask_received%') = 0,
    'SLEEP_GAP',
    'OK'
  ) AS status
FROM (
  SELECT dt, raw FROM remote(t491594_trio_logs)
  WHERE dt > now() - INTERVAL 48 HOUR
  UNION ALL
  SELECT dt, raw FROM s3Cluster(primary, t491594_trio_s3)
  WHERE _row_type = 1 AND dt > now() - INTERVAL 48 HOUR
)
GROUP BY hour
HAVING status = 'SLEEP_GAP'
ORDER BY hour DESC

table: "t491594.trio"
source_id: 1659391

Interpret: each returned row is an hour where WidgetKit called getTimeline but
the watch app produced no data (no BGTask, no save, no reload request). These
are expected overnight. Any SLEEP_GAP hour outside 01:00–06:00 UTC (02:00–07:00 CET)
warrants investigation — it may indicate a delivery failure rather than normal sleep.
```

---

### 2.3.6 Tighten Option A gate definition

**Status: Complete.** Fourth trigger criterion added to the Option A table (§2.2): per-reading epoch join using `reading_date_epoch_seconds` to detect late `didReceiveUserInfo` after `bgtask_completing`. Re-evaluate after 2026-03-15 (2.3.1 +7 days in production).

- **Where:** Phase 2.2 "Option A trigger criteria" table in this document.
- **What:** Add a fourth trigger criterion that uses per-reading epoch joins (enabled by Phase 2.3.1) rather than time-window heuristics. The existing three criteria remain unchanged.

Update the trigger criteria table by adding this row:

| Signal | Meaning | Threshold |
| --- | --- | --- |
| For the **same `reading_date_epoch_seconds`**: `complication_did_receive_user_info` dt occurs **after** the `complication_bgtask_completing` dt for any window in the same reading's delivery chain | The watch received the data only after the BGTask safety window had already closed — the 5s window was too short for this reading | Any sustained occurrence (>5% of readings over a 7-day window); confirm with per-reading join query from Phase 2.3.3 |

**Note on current state (2026-03-08):** Phase 2.3.1 join key deployed (build 128, 2026-03-08). Re-evaluate Option A using criterion 4 after Phase 2.3.1 has been in production ≥7 days (target: 2026-03-15). The existing three criteria remain the active gate until then.

---

## Phase 3: Dedup and lastValidTimestamp hardening

**Goal:** Prevent duplicate saves/reloads when the same CGM reading arrives via both `didReceiveUserInfo` and `didReceiveMessage`. Harden `lastValidTimestamp`. Single sanitization point.

**Gate:** Ship Phase 3 as a unit. Tasks 3.0–3.4 touch interacting paths.

**Critical invariants:**

- Pre-dispatch check (3.0) must never suppress a same-timestamp correction (different glucose/trend/delta).
- Fingerprint written only in `saveOnMain`, after confirmed write.
  - "Confirmed write" means: the fingerprint write must occur at the **same layer** that performs the final persistence write (or in that write's **completion handler** if persistence is async). Not merely after logging "saved" — if persistence is asynchronous (e.g. file write on a queue), writing the fingerprint only after a log line can run before the write completes. So: either persistence is synchronous and you write the fingerprint immediately after it returns, or persistence is async and you write the fingerprint in the completion handler that runs when the write has actually completed.
- `saveOnMain` is the authoritative correctness gate. Pre-dispatch is a best-effort optimization.
- `dedupQueue.sync` block is decision-only; save is dispatched outside it (see Shared definitions).

---

### 3.0 Unify dedup key across didReceiveUserInfo and didReceiveMessage

- **Where:** Watch app extension — `didReceiveUserInfo`, `didReceiveMessage`. `TrioComplicationDataStore.swift` — `saveOnMain`.
- **What:**
  1. Define `ComplicationSnapshotFingerprint` (Shared definitions). Verify fields against actual model — especially `state` property name.
  2. In `didReceiveUserInfo` and `didReceiveMessage`: read stored fingerprint on `dedupQueue` (decision-only sync — see Shared definitions); if equal to incoming, skip; dispatch save outside the sync block.
  3. In `saveOnMain`, after confirmed write: write fingerprint to App Group. Only write site.
- **Cold-start:** Key absent → always dispatch.
- **TOCTOU:** Best-effort. Duplicate dispatches still possible; `saveOnMain` handles them.
- **Acceptance (deterministic tests):**
  1. **Test A — Duplicate suppression:** Same payload via both handlers within 1 second → at most one `saveOnMain` write, one reload in logs.
  2. **Test B — Correction not suppressed (CRITICAL — patient safety):**
    - Send payload A (readingDate=T, glucose="150"). Wait for `"✅ Fingerprint written"` log, or apply a 2-second fixed delay before step 2 — the fingerprint must be persisted before B arrives for the test to be valid.
    - Send payload B (readingDate=T, glucose="152", delta or trend differs).
    - Expected: logs show `"✅ Pre-dispatch: dispatching"` for B (not "skipped"), `saveOnMain` accepts B, one reload fires.
    - **Failure condition:** logs show "skipped" for payload B. This means corrections with the same readingDate are silently dropped. A CGM correction failing to update the complication is a patient-safety issue.
    - **Harness requirement (must implement once):**
      - **Where:** Debug-only sender in the **iOS app** (e.g. internal dev menu or debug build) or a small internal tool that can invoke the same WCSession transfer API. Specify in the PR where it lives.
      - **Transport(s):** Use the same transport(s) as production for complication data — e.g. `transferCurrentComplicationUserInfo` and/or `transferUserInfo` / `sendMessage` depending on which paths the app uses for complication payloads. Document which transport(s) the harness uses.
      - **Payload format:** Must match the format the watch expects (e.g. the same dictionary keys and types as production ComplicationInfo). Must support caller-specified readingDateEpoch (or readingDate) and glucose/trend/delta (and state/glucoseColor if applicable) so Payload A and Payload B can differ only in content, not timestamp.
      - Must support sending Payload A then Payload B with the **same** readingDateEpoch.
      - Must log the exact payload JSON on the sender and the received payload fields on the watch for auditability.
      - **Both paths:** If production uses both `didReceiveUserInfo` and `didReceiveMessage` for complication data, run Test B once for each path (e.g. trigger via userInfo only, then in a separate run via message only) and document that both paths were exercised.
- **Do not:** Write fingerprint in handlers. Use timestamp-only comparison. Call save inside `dedupQueue.sync`.

#### Cursor prompt — Phase 3.0

```
Task: watch app extension (didReceiveUserInfo, didReceiveMessage) and
TrioComplicationDataStore.swift (saveOnMain fingerprint write).

App Group suite name: Read from Info.plist key "AppGroupID" at runtime (pattern: group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group). Use the existing `Bundle.appGroupSuiteName` extension or the `resolveAppGroupID(bundle:)` pattern from ComplicationLogBuffer.swift — do NOT hardcode a team-specific string.
Fingerprint key: "complication_last_saved_fingerprint"  (JSON Data)

IMPORTANT — field name verification:
Verify property names from the actual TrioComplicationSnapshot model; do not guess.
Check the exact property name for "state" (or whatever the model
uses). If the actual name differs, update the struct and the init(from:) extension.
Do not leave unresolved property names — the code must compile cleanly.

TARGET MEMBERSHIP: ComplicationSnapshotFingerprint goes in the watch app extension
target and TrioComplicationDataStore.swift only. Do NOT add it to the complication
extension target.

--- STEP 1: Define struct ---

struct ComplicationSnapshotFingerprint: Codable, Equatable {
    let readingDateEpoch: Int
    let glucose: String
    let trend: String
    let delta: String
    let state: String       // verify exact property name before using
    // glucoseColor intentionally excluded: computed from glucose value
}

extension ComplicationSnapshotFingerprint {
    init(from snapshot: TrioComplicationSnapshot) {
        readingDateEpoch = Int(snapshot.readingDate.timeIntervalSince1970)
        glucose      = snapshot.glucose
        trend        = snapshot.trend
        delta        = snapshot.delta
        // REQUIRED — nil handling for optional model fields. Choose ONE and document:
        // (a) Sentinel (safest if unsure): state = snapshot.state ?? "<nil>"
        // (b) Optional in struct: make state String? and compare optionals in Equatable.
        // (c) Empty default ONLY if verified: state = snapshot.state ?? ""
        //     and add: // Verified: nil and empty string render identically; do not change without re-verifying.
        // Default below uses (a); replace with (b) or (c) if appropriate and add the required comment.
        state        = snapshot.state ?? "<nil>"
    }
}

--- STEP 2: Dedup serial queue (one instance, shared) ---

In TrioComplicationDataStore:
    let dedupQueue = DispatchQueue(label: "com.trio.complication.dedup", qos: .utility)

--- STEP 3: Fingerprint read helper ---

private func storedFingerprint(defaults: UserDefaults) -> ComplicationSnapshotFingerprint? {
    guard let data = defaults.data(forKey: "complication_last_saved_fingerprint"),
          let fp = try? JSONDecoder().decode(ComplicationSnapshotFingerprint.self, from: data)
    else { return nil }
    return fp
}

--- STEP 4: Pre-dispatch check (DECISION-ONLY sync; save outside) ---

In BOTH didReceiveUserInfo AND didReceiveMessage:

    let incoming = ComplicationSnapshotFingerprint(from: incomingSnapshot)
    var shouldSave = false

    dedupQueue.sync {
        // Decision only — no save call inside this block.
        // Calling saveComplicationSnapshot inside sync risks deadlock if the save path
        // dispatches back to the main queue synchronously.
        let defaults = UserDefaults(suiteName: APP_GROUP_SUITE)!
        if let stored = storedFingerprint(defaults: defaults), stored == incoming {
            debugLog(
                "⏭️ Pre-dispatch dedup: skipped reading_date_epoch=\(incoming.readingDateEpoch)"
                + " via \(handlerName)"
            )
            return
        }
        shouldSave = true
        debugLog(
            "✅ Pre-dispatch: dispatching reading_date_epoch=\(incoming.readingDateEpoch)"
            + " via \(handlerName)"
        )
    }

    // Save is called OUTSIDE the sync block.
    // Ensure no code path from here to saveOnMain calls dedupQueue.sync (re-entry
    // deadlock) or DispatchQueue.main.sync from a non-main context (chain deadlock).
    if shouldSave {
        saveComplicationSnapshot(incomingSnapshot)
    }

(handlerName = "userInfo" or "message" per handler)

--- STEP 5: Write fingerprint in saveOnMain AFTER confirmed write ---

In saveOnMain, write the fingerprint at the same layer as the final persistence write
(or in that write's completion handler if persistence is async). Not merely after a
"saved" log line — the write must have completed. AFTER the snapshot has been written to the data store:

    // Phase 3.0: written here and ONLY here.
    // Not written in didReceiveUserInfo or didReceiveMessage.
    if let data = try? JSONEncoder().encode(
        ComplicationSnapshotFingerprint(from: acceptedSnapshot))
    {
        UserDefaults(suiteName: APP_GROUP_SUITE)?
            .set(data, forKey: "complication_last_saved_fingerprint")
        debugLog(
            "✅ Fingerprint written: reading_date_epoch="
            + "\(Int(acceptedSnapshot.readingDate.timeIntervalSince1970))"
        )
    }

--- ACCEPTANCE TESTS ---

Test A — Duplicate suppression:
1. Trigger same payload via both didReceiveUserInfo and didReceiveMessage within 1s.
2. Expected: one "✅ Pre-dispatch: dispatching", one "⏭️ Pre-dispatch dedup: skipped",
   one "✅ Fingerprint written", one reload log.

Test B — Correction not suppressed (CRITICAL):
1. Send payload A: readingDate=T, glucose="150", delta="+0".
2. WAIT: either apply a 2-second fixed delay OR poll logs until "✅ Fingerprint written"
   appears for payload A. Do not send payload B until the fingerprint is persisted —
   otherwise the dedup check has nothing to compare against and Test B is invalid.
3. Send payload B: readingDate=T (same), glucose="152", delta="+2".
4. Expected: logs show "✅ Pre-dispatch: dispatching" for B (NOT "skipped"),
   saveOnMain accepts B, one reload fires.
5. FAILURE: logs show "skipped" for payload B. Debug immediately — this is a
   patient-safety issue.

Add comment at each change site: // Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
```

---

### 3.1 Single dedup gate in saveOnMain

- **Where:** `TrioComplicationDataStore.swift` — `saveOnMain`.
- **What:** Confirm all newer-wins and duplicate detection is in `saveOnMain`. Add missing log lines. Document invariants.
- **Acceptance (deterministic):** Send newer snapshot (T+10), then older (T). Logs must show `"⏭️ saveOnMain: rejected older snapshot"` for the second and no reload.

#### Cursor prompt — Phase 3.1

```
Review task: TrioComplicationDataStore.swift — saveOnMain (~line 432–453).

1. Confirm invariants:
   a. Future-skew guard.
   b. Cold-start seed: nil existing → accept.
   c. Newer-wins: timeDiff < -1.0s → reject.
   d. Duplicate skip: timeDiff ±1.0s AND all display fields match → skip.
   e. Otherwise: write and reload.

2. If any missing: add. If all present: add comment block:
   // saveOnMain invariants (Phase 3.1):
   // (a) future-skew  (b) cold-start  (c) newer-wins  (d) duplicate skip
   // Authoritative dedup gate. Phase 3.0 pre-dispatch is optimization only.

3. Add if missing (required for deterministic acceptance test):
   debugLog("⏭️ saveOnMain: rejected older snapshot (timeDiff=\(timeDiff)s)")

4. Add if missing (required to measure pre-dispatch optimization effectiveness):
   debugLog("⏭️ saveOnMain: duplicate skipped (same reading, same content)")

5. No second gate outside saveOnMain. Do not change 1s tolerance.
```

---

### 3.2 Canonical comparator (shouldUpdate)

- **Where:** `TrioComplicationDataStore.swift` — all comparison sites.
- **What:** One function `shouldUpdate(new:current:) -> Bool`. Field set must be identical to `ComplicationSnapshotFingerprint` fields.
- **Acceptance:** Same readingDate + different content → `true`. Same + identical → `false`. One implementation.

#### Cursor prompt — Phase 3.2

```
Task: TrioComplicationDataStore.swift

1. Define (adjust fields to match actual TrioComplicationSnapshot model):

   func shouldUpdate(
       new: TrioComplicationSnapshot,
       current: TrioComplicationSnapshot
   ) -> Bool {
       let timeDiff = new.readingDate.timeIntervalSince(current.readingDate)
       if timeDiff > 1.0  { return true }
       if timeDiff < -1.0 { return false }
       // Same timestamp: update only if content differs (corrections must not be blocked)
       return new.glucose     != current.glucose
           || new.trend       != current.trend
           || new.delta       != current.delta
           || new.state       != current.state       // verify property name
           // glucoseColor intentionally excluded: computed from glucose value
   }

   Field set must be IDENTICAL to ComplicationSnapshotFingerprint fields from Phase 3.0.
   If you rename a field in the fingerprint, rename it here too.
   For optional fields (state): use the same nil/empty convention as in
   the fingerprint init — e.g. if fingerprint uses snapshot.state ?? "", then compare
   (new.state ?? "") != (current.state ?? "") here so that "fingerprint equal" implies
   "saveOnMain would skip" and pre-dispatch never suppresses a payload saveOnMain would accept.

2. Replace all inline timestamp/content comparison logic in saveOnMain and any
   lastValidTimestamp update path with calls to shouldUpdate(new:current:).

3. Confirm exactly ONE implementation. Add:
   // Phase 3.2 — canonical comparator. Use shouldUpdate everywhere.

4. Document test cases:
   - Same timestamp, same content → false
   - Same timestamp, different glucose → true
   - Newer timestamp → true
   - Older timestamp → false
```

---

### 3.3 Monotonic lastValidTimestamp; no flock

- **Where:** All `lastValidTimestamp` write sites in `TrioComplicationDataStore.swift`.
- **What:** Guard every write with `shouldUpdate`. Use `UserDefaults(suiteName:)`. No `flock`, no `NSFileCoordinator` by default.
- **Acceptance:** `lastValidTimestamp` never decreases. No `flock` anywhere for this purpose. TOCTOU acceptance documented.

#### Cursor prompt — Phase 3.3

```
Task: TrioComplicationDataStore.swift — all lastValidTimestamp write sites.

1. Find every write to lastValidTimestamp (or its App Group key).

2. Guard each with shouldUpdate (Phase 3.2):
   - nil current → write (cold start).
   - false → skip: debugLog("⏭️ lastValidTimestamp: skipped non-monotonic ...")
   - true → write: debugLog("✅ lastValidTimestamp updated: \(new)")

3. Backing store: UserDefaults(suiteName: APP_GROUP_SUITE). Add comment:
   // Eventually consistent. Monotonic guard reduces but does not eliminate TOCTOU.
   // Accepted. Do not use NSFileCoordinator (blocks provider) or flock (invalid
   // cross-process on Darwin). Phase 3.3.

4. Search for flock, fcntl, NSFileCoordinator near lastValidTimestamp. Flag any found:
   // REMOVE: invalid cross-process App Group on Darwin. Phase 3.3.

5. No other changes.
```

---

### 3.4 Sanitization at model level

- **Where:** `TrioComplicationSnapshot` init. All call sites.
- **Acceptance:** All sanitization in init. No "153 mg/dL" vs "153" mismatch possible.

#### Cursor prompt — Phase 3.4

```
Review: TrioComplicationSnapshot init and all call sites.

1. Confirm glucose and delta sanitization is in init. If not, move it there.

2. Find all call sites (WatchState.swift + others). For each:
   - Raw strings passed directly to init (no pre-sanitization at call site).
   - No raw message fields compared to stored values outside init or saveOnMain.

3. If call site sanitizes before init: move to init, remove from call site.
   Add: // Sanitization in TrioComplicationSnapshot.init — Phase 3.4

4. Add to init:
   // INVARIANT (Phase 3.4): All display-field sanitization here.
   // Dedup always compares sanitized values.
```

---

## Phase 4: Observability and SLA

**Gate:** None. Doc-only. Parallel with Phases 2–3. **Phase 4.2 requires Phase 0.2** (reload→getTimeline correlation); Phase 0.2 is now complete including the causality metrics extension, so the baseline data exists.

### 4.1 Declare CGM cadence and tie SLAs

#### Cursor prompt — Phase 4.1

```
Doc-only: snapshot-age-improvements-suggestions.md §3.4

1. Add at top: "Assumed CGM update cadence: 5 minutes. All SLA targets below are
   multiples of this cadence."

2. SLA targets:
   - p95 save age: < 2× cadence (< 10 min). Stretch: < 1× cadence.
   - p95 reload age: < 2× cadence.
   - "< 2 min save age" is stretch only; background delivery makes this unreliable
     as a contract.
```

---

### 4.2 Reload→getTimeline baseline and interpretation

#### Cursor prompt — Phase 4.2

```
Doc-only: snapshot-age-improvements-suggestions.md §3.4

Add under "Complementary metric — reload requested vs timeline updated":

"Baseline and interpretation:
- Establish baseline in known-good period (Phase 1 shipped, Phase 0.2 active).
- WidgetKit coalesces; do not expect 1:1.
- Signal of exhaustion: persistent large divergence from your baseline.
- A persistent gap of >50% vs baseline warrants investigation.
- Do not interpret first-day or post-update metrics as evidence of exhaustion.
- Phase 0.2 causality metrics now provide direct reload→getTimeline match-rate
  via the 'Reload-Association Ratio' dashboard panel (generation_delta buckets)
  and latency distribution via 'Valid Latency Percentiles'. Use these as the
  primary baseline data source rather than raw log correlation."
```

---

## Summary: phase order and gates


| Phase   | Content                                                                                                   | Gate                                               | Cursor-ready? |
| ------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | --------------------- |
| 0.1     | Structured logging with `reading_date_epoch` Int join key (CGM reading only)                              | None — do first                                    | ✅ Complete |
| 0.2     | Ring-buffer reload→getTimeline correlation (`reload_requested_at_epoch`) + causality metrics extension (generation/delta, latency validity, provider restart, App Group availability) | Estimate effort; optional                          | ✅ Complete (incl. causality metrics) |
| 1.1     | Doc corrections                                                                                           | None                                               | ✅ Complete |
| 1.2     | No retry after save-triggered reload                                                                      | Phase 0.1 in place                                 | ✅ Complete |
| 1.3     | forceReload call-site audit                                                                               | Phase 1.2 done                                     | ✅ Complete |
| 2.1     | Wake burst debounce logging + `burst_window_id` + on-device test                                          | None                                               | ✅ Complete |
| 2.2     | Background delivery logging in `WatchState.handleBackgroundTasks` (Option B — logging only, 5s unchanged) | None                                               | ✅ Complete |
| 2.2-A   | Option A: `hasContentPending` wait — implement only if BetterStack analysis triggers criteria             | Phase 2.2 logs (min 3 days) + query shows evidence | ⛔ Blocked — criteria not met as of 2026-03-08; re-evaluate ≥2026-03-15 (2.3.1 +7 days) using criterion 4 |
| **2.3.1** | **Phone transfer log: add `reading_date_epoch_seconds` to `📤 Transferred via userInfo` (iOS, 1 line)** | **Phase 2.2 complete** | **✅ Complete (build 128, 2026-03-08)** |
| **2.3.2** | **Structured log fields: promote `event`/`window_id`/`task_type` to top-level JSON in cloud logging encoder** | **2.3.1 deployed + verified** | **✅ Complete (build 129, 2026-03-08)** |
| **2.3.3** | **Receive_lag dashboard panel: per-hour p50/p90/max of WC queue flush time** | **None** | **✅ Complete (dashboard 914638)** |
| **2.3.4** | **Freshness decomposition: per-reading join query + dashboard panel + doc formula** | **2.3.1 data flowing** | **✅ Complete (dashboard 914638 + doc §3.4)** |
| **2.3.5** | **Sleep-gap classifier: BetterStack query + dashboard panel** | **None** | **✅ Complete (dashboard 914638 + on-demand query)** |
| **2.3.6** | **Option A gate: add per-reading join criterion (plan text update only)** | **None** | **✅ Complete (4th criterion added)** |
| 3.0–3.4 | Dedup hardening — ship as unit. Note: correctness work; not expected to move save_age/reload_age metrics. | None; verify checklist first                       | ✅ Yes |
| 4.1–4.2 | CGM cadence + SLA + metric interpretation (4.3: freshness decomposition formula now part of Phase 2.3.3) | None; parallel                                     | ✅ Yes |


---

## Phase 5 (out of scope — placeholder only)

Do not implement. If delivery-delay dominates after Phases 2.3–4, revisit then.

- watchOS API: `WKApplicationRefreshBackgroundTask` — **not** `BGAppRefreshTask` (iOS-only).
- Requires dedicated spike: budget, permissions, reliability, API choice.
- **Current data rationale (2026-03-08):** BGTask pipeline is healthy (96.7% fast-path, zero missed saves in 72h analysis). The dominant delay is WatchConnectivity queue flush wait time — how long between when the phone enqueues a `transferUserInfo` and when the watch session activates to drain it. `WKApplicationRefreshBackgroundTask` does not address this; it would help only if the watch app needed to proactively pull data on a schedule, which is not the bottleneck. Revisit only if Phase 2.3 per-reading analysis reveals a different picture.

---

## Remaining open items

- **Phase 2.3 (all sub-tasks):** Complete. Dashboard panels, doc formula, sleep-gap classifier, and Option A gate criterion all done.
- **Phase 2.2-A (Option A):** Criteria not met as of 2026-03-08. Re-evaluate after Phase 2.3.1 has been in production ≥7 days using the per-reading join criterion (2.3.6). If 3.3% timeout rate increases or new missed-save evidence appears, re-examine.
- **TrioComplicationSnapshot field names:** Verify `state` property name before Phase 3.0. Update fingerprint and `shouldUpdate` field sets to match. They must be identical.
- **App Group suite name:** Insert into Phase 3.0 Cursor prompt. (Phase 0.2 causality metrics already resolved this — using `cachedAppGroupDefaults` / `resolveAppGroupDefaultsOnce()`.)
- **Line number verification:** Verify all approximate line numbers before running any prompt.
- **Phase 3.0 Test B (correction not suppressed):** Patient-safety concern. Run after Phase 3 ships and document result.
- **Phase 5:** `WKApplicationRefreshBackgroundTask` only. Spike required. Data now shows BGTask pipeline is healthy; dominant delay is WatchConnectivity queue flush wait, not BGTask interior behavior. Revisit only if Phase 3 + 2.3 measurements reveal a different picture.

---

## Implementation log


| Phase | Date       | Summary |
| ----- | ---------- | --- |
| 0.1   | 2026-03-02 | **Complete.** `TrioComplicationDataStore.swift`: In `saveOnMain`, after successful write, emit structured log `event=complication_save_age` with `age_seconds`, `reading_date_epoch_seconds`, `reading_date` (ISO8601). In `reloadTimeline()`, emit `event=complication_reload_age` with same field set (epoch from `lastTS`). Static `ISO8601DateFormatter` reuse; negative age clamped to 0; legacy `reload_snapshot_age_seconds` log line removed. Human-readable "Snapshot saved…" line retained. Join key: `reading_date_epoch_seconds` (Int). |
| 0.2   | 2026-03-02 | **Complete.** Reload→getTimeline correlation: `ComplicationReloadRecord` + 64-entry ring in App Group UserDefaults (`complication_reload_ring`). Watch app appends before each `reloadTimelines` and logs `event=complication_reload_requested` with `reload_id` (uuidString), `reload_requested_at_epoch_seconds`. Complication extension reads ring in `getTimeline`, logs `event=complication_get_timeline_called` with `most_recent_reload_id`, `latency_seconds`, `reload_requested_at_epoch_seconds` — os.Logger removed; routed through ComplicationLogBuffer (file/drain path) so complication extension logs reach Better Stack. Compile-time guard: `#if !WIDGET_EXTENSION` around ring append; sync scripts set per-config `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for Trio Watch Complication Extension (Debug: DEBUG + WIDGET_EXTENSION, Release: WIDGET_EXTENSION only). New file `ComplicationLogBuffer.swift` (in-memory ring for DataStore logs). Join keys: `reload_id` primary; `reload_requested_at_epoch_seconds` fallback/sanity. Post-deploy: verify both event types land in Better Stack within 24h. |
| 0.2 (shipped) | 2026-03-03 | **Phase 0.2 complete and shipped.** `ComplicationLogBuffer.swift`: hybrid buffer (in-memory ring all targets; file append only when `WIDGET_EXTENSION` / complication target). Sync file write in complication process so write completes before return. Contract: writer only `complication_log.txt`; best-effort delivery; rare corruption possible if truncation races drain. Built and deployed (patch 09). |
| 0.2 observability | 2026-03-04 | **Phase 0.2 dashboard and setup doc.** Better Stack dashboard ID 914638 "Trio • Complication Freshness (Phase 0.2)": Extract Metrics on Trio source (complication_reload_requested_count, complication_get_timeline_called_count, five latency buckets, complication_latency_seconds with avg/max/quantiles). 14 charts in 3 sections — Volume & Reload Efficiency (reload vs getTimeline line, 60–300s / >300s text, Max Latency, Reload efficiency, counts), Burstiness (reloads per 5‑min bucket line, P95 burstiness, Burst Windows Count, Max burst), Latency health (avg/max/P50/P90/P95 over time, latency buckets per hour, Complication Reload Latency bar). Queries use pre-aggregated columns (no `name` filter); 30‑min buckets for latency line; 1‑h for latency buckets bar. Setup doc `docs/better-stack-complication-dashboard-setup.md`: Step 1 Extract Metrics definitions, Step 2 query patterns, individual-latency note, full dashboard summary with current queries, limitations. |
| 1.1–1.3 | 2026-03-04 | **Phase 1 complete.** 1.1: snapshot-age-improvements-suggestions.md — §1.1 Bucket 1 scope (WCSession/wake budget note); §3.1 Reconnect/catch-up behavior; §3.4 getTimeline/budget characterization; §3.5 App Group locking (no flock; monotonic preferred). 1.2: TrioComplicationDataStore — coalescedReloadOnMain(minInterval:isRetry:scheduleRetry:), guard skips scheduleRetryAfterReloadOnMain when scheduleRetry=false; save path passes scheduleRetry: false. 1.3: ComplicationDebugView forceReload(scheduleRetry: false) with inline comment; WatchState.forceComplicationUpdate unchanged (already scheduleRetry: false). |
| 0.2 causality | 2026-03-05 | **Phase 0.2 causality metrics extension complete.** Code: `reload_generation` counter + `lastReloadRequestEpochSeconds` in App Group UserDefaults (writer: watch app); `ProviderProcessState` (instanceID, lastSeenGeneration, isFirstCall) + three-way App Group branch (unavailable/unset/set) in complication provider `getTimeline`; `logWidgetGetTimelineInvocation` expanded with `appGroupAvailable`, `observedGenerationSource`, `providerInstanceID`, `providerRestart`, `observedReloadGeneration`, `generationDelta`, `latencyValid` fields; `latencyValidityWindowSeconds = 600`. Better Stack: 8 extraction rules (generation_delta, provider_restart, latency_valid, latency_seconds_valid + 4 generation_delta buckets). Dashboard 914638: 6 new panels in "Causality Metrics (Phase 0.2)" section (Generation Delta Distribution, Valid Latency Percentiles, Max Valid Latency, Valid Latency Events, Reload-Association Ratio, Provider Restart Rate). Patch 09 regenerated, validated, and build-verified. See `docs/phase-0.2-causality-metrics-implementation-plan.md` for full specs. |
| 2.2 diagnostics | 2026-03-07 | **Phase 2.2 enqueue/finalize/race diagnostics.** `WatchState.swift`: (A) `complication_bgtask_enqueued` after `pendingConnectivityTasks.append(task)` with `pending_count`; (B) `complication_userinfo_no_pending_tasks` in `didReceiveUserInfo` when `pendingConnectivityTasks.isEmpty` (distinguishes race vs foreground); (C) `complication_finalize_begin`/`complication_finalize_end` around quiet-window task completion loop with `pending_count`/`cleared_count`; fast-path `completed_count` now uses captured `pendingCount`. Initial deploy (build 124) showed `completed_count=0` on all fast-path completions; one `path=timeout` event (window 85, completion_delay_ms=5298) confirmed safety net works. These diagnostics will reveal whether count=0 is a race (userInfo beats enqueue), early clear (prior finalize), or flush artifact. |
| 2.2 analysis | 2026-03-07 | **Phase 2.2 BetterStack analysis (72h, hot+S3).** 183 total completions: 177 fast (96.7%), 6 timeout (3.3%). Four timeout windows: build 124 windows 85 (5298ms) and 116 (5252ms) — no userInfo, no enqueued (pre-diagnostic build); build 125 windows 10 (5212ms) and 15 (5136ms) — both show `userinfo_no_pending_tasks` before `bgtask_enqueued`, confirming race (`didReceiveUserInfo` runs before task appended). Race-triggered timeout windows have no `finalize_begin`/`end` because empty-branch calls `scheduleUIUpdate` directly, bypassing quiet-window work item. Healthy fast-path ordering confirmed: forwarding → received → enqueued(pending=1) → userinfo → finalize_begin(pending=1) → completing(fast, count=1) → finalize_end(cleared=1). Build 124 `completed_count=0` resolved: `Task { }` closure evaluated `.count` after `removeAll()` ran synchronously; build 125 captures `pendingCount` before Task. No evidence userInfo arrives after timeout completion — 5s window not too short. Duplicate events (2–4x) are WatchLogger flush duplication. Option A gate: timeout rate 3.3%, but all timeouts still complete; complication data updated via `scheduleUIUpdate` in race path; no missed saves. Recommendation: no immediate need for Option A; continue monitoring. |


---

## Changelog


| Version | Date       | Changes |
| ------- | ---------- | --- |
| 1.0     | 2026-02-27 | Initial plan. |
| 1.1     | 2026-02-27 | Plan-review: triage; phase structure; canonical comparator; UserDefaults guidance; Phase 3 ship-as-unit. |
| 1.2     | 2026-02-27 | Correlation key; ring buffer; burst-window measurement; reconnect spike; BGAppRefreshTask correction. |
| 1.3     | 2026-02-27 | Phase 5 demoted. Pre-implementation checklist. Cursor prompt per task. |
| 1.4     | 2026-02-27 | Phase 2.1 removed (sessionReachabilityDidChange unreliable). Phase 2.2 renumbered. Post-reconnect investigation note added. |
| 1.5     | 2026-03-02 | ComplicationSnapshotFingerprint; fingerprint write after confirmed save; dedupQueue; reading_date_epoch Int join key; deterministic acceptance tests; reconnect framed as "expected; must verify." |
| 1.6     | 2026-03-02 | Eight issues from ChatGPT + Cursor review: (1) Phase 0.2 join key renamed reading_date_epoch → reload_requested_at_epoch; reading_date_epoch reserved for CGM reading time only; log field naming convention section added. (2) Phase 3.0 deadlock fixed: dedupQueue.sync is now decision-only; saveComplicationSnapshot dispatched outside sync block; explicit deadlock prevention rule for implementers added to Shared definitions. (3) Phase 3.0 target membership narrowed to watch app extension only; complication extension explicitly excluded. (4) Phase 3.0 UserDefaults consistency: reads-on-dedupQueue / writes-on-main explicitly accepted as best-effort; saveOnMain "duplicate skipped" log added to Phase 3.1 prompt for observability. (5) Phase 2.2 code location corrected to WatchState.handleBackgroundTasks; behavior change decision (Option A: hasContentPending / Option B: logging-only with 5s) surfaced explicitly; task.isCompleted removed (doesn't exist); replaced with var completed = false flag; platform timeout verification added to pre-implementation checklist; Phase 2.2 marked ⚠️ in summary table pending decision. (6) Phase 2.1 burst_window_id counter added; window boundary mechanically verifiable. (7) Post-reconnect file protection note corrected: removed incorrect claim that UserDefaults has a file protection setting; replaced with investigation item pointing to underlying file attributes and NSFileManager check. (8) Phase 3.0 Test B: concrete 2s wait strategy added; "state" property name verification note added. |
| 1.7     | 2026-03-02 | Phase 2.2 decision resolved: Option B selected (logging only, keep 5s delay). Rationale: must confirm task is received before changing completion strategy; Option A solves a problem that may not exist. Phase 2.2 rewritten as logging-only Cursor prompt. Option A trigger criteria defined as a structured table (late didReceiveUserInfo after task completion = zero tolerance; missing save after task >20% = investigate; post-reconnect staleness pattern). BetterStack MCP query prompt added to Phase 2.2 covering task receipt volume, delivery timing (Step 3 is the key Option A signal), and received-with-no-save rate. Summary table updated: 2.2 marked ✅ Yes; 2.2-A added as new blocked-on-evidence row. Remaining open items updated: Option A/B decision and platform timeout items removed; Phase 2.2 log analysis gate item added. |
| 1.8     | 2026-03-02 | Phase 2.2: BackgroundTaskWindowCounter (in-memory window id) added in Shared definitions; placement specified (watch app extension only, not Shared/complication extension). Phase 2.2 Cursor prompt now logs window_id on task received and completing; didReceiveUserInfo log step added with explicit rule: reading_date_epoch from decoded payload only, or omit/log -1 — do not log receive time. BetterStack Step 3: correlate by window_id when possible; keep time window as backstop (window_id can reset on process restart); window_id + time ordering together is strongest. Phase 3.0: "Confirmed write" clarified (after persistence and accept decision in saveOnMain). Phase 3.0 Test B: harness requirement added (debug iPhone sender for same readingDateEpoch A then B, with logging). ComplicationSnapshotFingerprint: comment block reordered and clarified (verify property names from actual model; do not guess; optional-field default: "" only if nil and "" equivalent for display, else use sentinel). Phase 3.0 Cursor prompt: init(from:) uses snapshot.state ?? "" and snapshot.glucoseColor ?? "" with note about sentinel when nil vs "" have different display meaning. Header "Based on" updated to v1.7. |
| 1.9     | 2026-03-02 | Phase 2.2: Structured log fields required (event, window_id, task_type) for BGTask logs so MCP queries are not brittle on message text; log field naming convention extended; Cursor prompt updated to emit structured fields. BetterStack: query convention added (prefer JSONExtract on event/window_id when available); Step 4 labeled as approximate heuristic when time-only; (4a) time-only variant and (4b) window-safe variant when structured data exists; interpretation tightened (e.g. >30% for heuristic). Phase 3.0: "Confirmed write" now requires fingerprint write at same layer as final persistence (or in its completion handler if async), not merely after logging "saved". Phase 3.0 fingerprint init: enforce one of (a) sentinel "", (b) optional fingerprint fields, or (c) explicit "verified nil and empty render identically" comment; prompt defaults to sentinel, no hardcoded ?? "" without choice. Phase 3.0 Test B harness: where it lives (iOS app vs internal tool), which transport(s), payload format, and requirement to run Test B for both didReceiveUserInfo and didReceiveMessage paths if both used in production. Phase 4: header states Phase 4.2 requires Phase 0.2; otherwise skip or adapt. |
| 1.10    | 2026-03-02 | Phase 2.2: Fallback for message-only pipelines — if structured JSON fields cannot be emitted, embed event= and window_id= (and task_type=) as stable key-value tokens in the message so parsing remains reliable; document which approach is used. Pre-implementation checklist: add process rule for Phase 3.0 — update fingerprint and shouldUpdate together in the same commit; reviewer must diff the field lists to prevent drift. |
| 1.11    | 2026-03-02 | Log pipeline: added "Log pipeline (Better Stack)" note — pipeline supports structured fields via CloudLogEvent top-level JSON; 06-cloud-logging patch currently whitelists a fixed attribute set; event/window_id/task_type require encoder+parser extension or message-embed fallback. Remaining open item for Phase 2.2 structured fields updated to reference this. |
| 1.12    | 2026-03-02 | Phase 0.1 marked complete. Implementation log section added. |
| 1.13    | 2026-03-02 | Phase 0.2: Option A compile-time guard via sync scripts (per-config SWIFT_ACTIVE_COMPILATION_CONDITIONS for Trio Watch Complication Extension); minimal acceptance check added (Debug: DEBUG + WIDGET_EXTENSION; Release: WIDGET_EXTENSION only, no DEBUG). |
| 1.14    | 2026-03-02 | Phase 0.2: os.Logger interpolations marked privacy: .public so correlation values are not redacted; explicit "Phase 0.2 log verification (do immediately after deploy)" step added — verify both event types land in Better Stack for same device within 24h. |
| 1.15    | 2026-03-02 | Phase 0.2 marked complete. Implementation log: added Phase 0.2 row (ring buffer, compile-time guard, ComplicationLogBuffer, join keys, post-deploy verification). Summary table: 0.2 Cursor-ready set to ✅ Complete. |
| 1.16    | 2026-03-03 | Implementation log: added 0.2 (shipped) row — ComplicationLogBuffer hybrid ring+file, sync write, contract; Phase 0.2 complete and shipped (patch 09). Header updated to v1.16. |
| 1.17    | 2026-03-04 | Implementation log: added 0.2 observability row — Better Stack dashboard (ID 914638), Extract Metrics, 14 charts in 3 sections, setup doc `better-stack-complication-dashboard-setup.md`. Header updated to v1.17. |
| 1.18    | 2026-03-04 | Phase 1 implemented: 1.1 doc corrections in snapshot-age-improvements-suggestions.md (§1.1 Bucket 1, §3.1 Reconnect/catch-up, §3.4 getTimeline/budget, §3.5 App Group locking); 1.2 coalescedReloadOnMain(scheduleRetry:), save path passes false, guard skips retry; 1.3 ComplicationDebugView forceReload(scheduleRetry: false) with comment. Implementation log Phase 1 row added. |
| 1.19    | 2026-03-05 | Phase 0.2 causality metrics extension cross-referenced: (a) Phase 0.2 section — added paragraph describing causality metrics extension with pointer to `phase-0.2-causality-metrics-implementation-plan.md`; (b) summary table — Phase 0.2 status updated to "✅ Complete (incl. causality metrics)"; (c) Phase 4.2 gate note updated (Phase 0.2 now complete; baseline data exists); Phase 4.2 prompt extended with guidance to use Reload-Association Ratio and Valid Latency Percentiles panels as primary baseline source; (d) remaining open items — App Group suite name note updated (resolved in causality metrics, only Phase 3.0 remains); (e) implementation log — added "0.2 causality" row with code changes, extraction rules (8), dashboard panels (6), patch status. |
| 1.20    | 2026-03-06 | Phase 2.1 burst_window_id semantics: treat burstWindowId as active debounce window; on TRIGGER path advance window and reset suppression before logging so TRIGGERED and all DEBOUNCED in the same burst share the same burst_window_id (deterministic acceptance). No behavior or timing changes. |
| 1.21    | 2026-03-06 | Phase 2.2 BetterStack MCP query prompt: (1) structured-field filtering (JSONExtract event/task_type/window_id) as default; message LIKE only in explicit Fallback sections. (2) Step 2: renamed unmatched→hour_bucket_delta with note on hour-boundary straddling; added optional window_id-based pairing query (received with no completing for same window_id within 60s). (3) Step 3: return dt, event, task_type, window_id, message; correlate received→completing→save_age by window_id + ~10s. (4) Step 4: window-safe (window_id + 60s) as preferred when window_id available; time-only heuristic only when window_id missing, with false-match warning. |
| 1.22    | 2026-03-06 | Phase 2.2: Added `path=fast` completing log on the quiet-window/finalizePendingData path (Path A) and `path=timeout` token on the 5s safety timeout path (Path B). Initial deploy showed only received+did_receive_user_info with no completing; tasks were always completed via the fast path before the 5s timeout fired. New `completed_count` field on both paths. Logging only; no behavior changes. |
| 1.23    | 2026-03-07 | Phase 2.2: Enqueue/finalize/race diagnostics. Three new log events: (A) `complication_bgtask_enqueued` with `pending_count` immediately after task append — reveals enqueue ordering relative to userInfo; (B) `complication_userinfo_no_pending_tasks` when `didReceiveUserInfo` sees empty `pendingConnectivityTasks` — directly confirms race (userInfo before enqueue) or foreground delivery; (C) `complication_finalize_begin`/`complication_finalize_end` with `pending_count`/`cleared_count` — reveals whether quiet-window work item finds tasks to complete. Motivated by build 124 observation: all fast-path completions showed `completed_count=0`; one `path=timeout` (window 85, 5298ms) confirmed safety net works. Implementation log row added. |
| 1.24    | 2026-03-07 | Phase 2.2 BetterStack analysis: 72h query across hot+S3 (183 completions). Timeout rate 3.3% (6/183). All 4 timeout windows correlate with race condition (`didReceiveUserInfo` before `bgtask_enqueued`). Build 124 `completed_count=0` explained (Task closure captured `.count` after `removeAll()`). No late userInfo after timeout — 5s safety net adequate. Option A gate: no trigger criteria met; continue monitoring. Implementation log row added. |
| 1.25    | 2026-03-08 | Phase 2.2 and earlier marked done. "Preferred order of attack" updated with empirical baselines. Phase 2.3 inserted (6 sub-tasks): 2.3.1 phone transfer log enrichment (iOS, 1 line, `reading_date_epoch_seconds` on `📤 Transferred via userInfo`); 2.3.2 structured log fields (promote `event`/`window_id`/`task_type` to top-level JSON in cloud logging encoder); 2.3.3 receive_lag standing dashboard panel (WC queue flush time per hour, p50/p90/max, works today); 2.3.4 freshness decomposition full join query + dashboard section + §3.4 doc formula; 2.3.5 sleep-gap classifier (hourly detector for provider-only periods); 2.3.6 Option A gate updated with per-reading join criterion (plan text only). Deployment order: 2.3.1 (code+deploy+verify 24h) → 2.3.2 (code+deploy+verify 24h) → 2.3.3–2.3.6 (no build, parallel). Phase 3 "dedup" renumbered but content unchanged. Phase 5 strengthened with data rationale. Remaining open items reorganized. |
| 1.26    | 2026-03-08 | Phase 2.3.1 complete (build 128): Added `reading_date_epoch_seconds` to iOS `📤 Transferred new WatchState snapshot via userInfo` log line in `AppleWatchManager.swift`. Uses `state.glucoseValues.last` (sorted ascending by `setupWatchState`) with `-1` sentinel when no reading present. BetterStack verified: epoch non-null and matches watch-side `reading_date_epoch`. Patch 09 updated. Phase 2.3.2 complete (build 129): Promoted `event`, `window_id`, `task_type` message tokens to top-level JSON fields in `CloudLogEvent.encode(to:)` (06-cloud-logging patch). Uses `NSRegularExpression` with `\b` word boundaries and `([^ ]+)` capture groups for robust extraction. Additive only — existing `LIKE`-based queries unchanged. BetterStack verified: `JSONExtract(raw,'event',...)` and `JSONExtract(raw,'window_id',...)` return expected values for complication BGTask events. Remaining open items updated (2.3.1/2.3.2 removed). Summary table and status fields updated. |
| 1.27    | 2026-03-08 | Phase 2.3 fully complete. 2.3.3: Receive_lag dashboard panel confirmed on dashboard 914638 (chart 8801948580 line + 8799383509/8799383776 number cards). 2.3.4: Freshness decomposition dashboard panels confirmed (Receive Lag, Provider Latency, Save Age, Reload Age at 30-min granularity); freshness decomposition formula block added to `snapshot-age-improvements-suggestions.md` §3.4 (v1.2). 2.3.5: Sleep-gap classifier chart added to dashboard 914638 (chart 8804994375, "Sleep-Gap Classifier (provider-only hours)" — shows getTimeline/reload/latency counts per hour; gaps visible when only getTimeline has values). On-demand query verified: 2026-03-08 03:00–04:00 UTC flagged as SLEEP_GAP (overnight, expected). 2.3.6: Fourth trigger criterion added to Option A table — per-reading epoch join using `reading_date_epoch_seconds` to detect late `didReceiveUserInfo` after `bgtask_completing`; re-evaluate after 2026-03-15 (2.3.1 +7 days). All statuses, summary table, remaining open items, and preferred order of attack updated. |
| 1.28    | 2026-03-09 | Phase 3 complete (build 130). All five sub-tasks shipped as a unit in patch 09: **3.0** Pre-dispatch dedup with `ComplicationSnapshotFingerprint` (content-based fingerprint in App Group UserDefaults, `shouldSkipPreDispatch` with `dedupQueue.sync` decision-only, fingerprint written in `saveOnMain` after confirmed write). **3.1** `saveOnMain` invariants confirmed and documented: (a) future-skew, (b) cold-start, (c) newer-wins, (d) duplicate skip; log prefixes updated to `saveOnMain:` for acceptance tests. **3.2** Canonical `shouldUpdate(new:current:)` comparator: field set matches fingerprint (glucose, trend, delta, state); `glucoseColor` excluded (settings-dependent but stable within update cycle — documented with invariant rationale); ±1s symmetric tolerance window; inline comparison in `saveOnMain` replaced. **3.3** `lastValidTimestamp` hardening: monotonic guard added to `latestSnapshot()` write site; `onMain` log moved inside closure; eventually-consistent comment added (no NSFileCoordinator/flock on Darwin). **3.4** Sanitization invariant: confirmed all display-field sanitization in `TrioComplicationSnapshot.init`; all 7 call sites pass raw strings; `INVARIANT (Phase 3.4)` comment added. Preferred order of attack item 5 marked complete. |