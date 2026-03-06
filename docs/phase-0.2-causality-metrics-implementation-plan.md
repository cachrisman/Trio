# Implementation Plan: Phase 0.2 Causality Metrics

**Version:** 1.8  
**Date:** 2026-03-06  
**Status:** ✅ Complete — all phases implemented, verified, and dashboard finalized  
**Design reference:** `docs/phase-0.2-causality-metrics-design-v1.2.md`

## Scope

Implement generation/delta + latency validity window + provider_instance_id + restart flag + minimal context marker logging. Update Better Stack Extract Metrics and dashboard queries.

---

## Feedback crosswalk (v1.3 → v1.4)

| # | Normalized issue | Raised by | Disposition | Rationale | Where |
|---|-----------------|-----------|-------------|-----------|-------|
| 1 | A1: `integer(forKey:)` returns 0 for unset key → first write produces generation 1. Document write/read asymmetry with A3 reader (`object(forKey:)` → nil). | Both | **APPLIED** | Both reviewers agree the asymmetry is correct but undocumented. Write path silently treats "unset" as 0 via `integer(forKey:)`, reader explicitly returns nil. Compatible by design — first write produces 1, which is the first non-nil value the reader sees. | Task A1 Edit 3+4 note, A1 acceptance |
| 2 | A1: Coalescing test "10 quick BGM entries" is ambiguous — clarify what actually triggers `reloadTimeline()` | R2 | **APPLIED** | Engineer may not know which user actions trigger `reloadTimeline()`. Reworded to describe the mechanism. | Task A1 acceptance |
| 3 | A4: Add explicit acceptance/failure-mode check for "App Group unavailable" — latency_valid always false, reload_generation=-1 on reload side, delta=0 on provider side | R1 | **APPLIED** | Diagnosability improvement. The failure-mode signature ties together reload-side and provider-side signals into a single coherent picture. | New "Failure-mode signatures" section |
| 4 | A4: Add acceptance note: "verify no negative deltas in normal operation; if seen, treat as bug" | R1 | **APPLIED** | Not a code change (still rejecting `generation_reset=true` field) but a useful acceptance criterion that promotes negative deltas from "only in risks table" to an explicit check. | Task A4 acceptance |
| 5 | A4: When App Group unavailable, observedGeneration locks at 0 → delta=0 forever. Document as expected degraded behavior. | R1 | **APPLIED** | Correct behavior under the failure mode, but previously undocumented. Added to A4 key behaviors and the failure-mode signatures section. | Task A4 key behaviors, Failure-mode signatures |
| 6 | B1/B4: Better Stack extraction filter syntax for boolean fields (string match `"false"` vs boolean equality) may differ — add verification note | R2 | **APPLIED** | Operational unknown that can't be resolved in the plan but should be called out before Phase B configuration. | Phase B, new note |
| 7 | B1/C1: Metrics table reference is still `<placeholder>` — need concrete schema or at minimum a Phase B → Phase C handoff step | R1 (R2 says placeholder is fine) | **APPLIED (partial)** | R1 is right that an engineer needs more guidance. However, the actual table/column names are determined at Phase B configuration time — we can't know them before then. Added a Phase B → Phase C handoff step and an expected schema pattern. The `<placeholder>` remains because the concrete name is TBD. | Phase B handoff step, Phase C preamble |
| 8 | Phase B: Zero-row smoke test "within 1 hour" could fail if device is idle — tighten to "within 1 hour of a confirmed reload event" | R2 | **APPLIED** | Prevents spurious failures when watch is charging/idle. | Phase B acceptance |
| 9 | C1: Trailing space in `LIKE '%generation_delta=0 %'` is correct but could confuse — add explanatory note | R2 | **APPLIED** | Trailing space acts as field delimiter since `generation_delta` is followed by `provider_instance_id` in the log format. Without it, `generation_delta=0` would also match `generation_delta=01` etc. | Task C1 Explore query note |
| 10 | Cross-cutting: Line numbers may be stale if other PRs merged — add handoff note | R2 | **APPLIED** | Line references were validated at v1.1 against the worktree. If code changes land before implementation, they may shift. | Phase A header note |

---

## Sentinel and validity conventions

All integer sentinel values use `-1`. All validity gates use explicit boolean fields. Extraction rules filter on both.

| Log field | Sentinel | Meaning | Extraction handling |
|-----------|----------|---------|-------------------|
| `reload_generation` (reload event) | `-1` | App Group unavailable; generation write skipped | Not extracted (reload event, not getTimeline) |
| `observed_reload_generation` (getTimeline) | `-1` (unavailable) or `0` (unset) | `-1`: App Group unavailable — provider enters full sentinel mode. `0`: App Group available but key unset (pre-first-reload); via `?? 0` fallback. Values `≥ 1` are normal. | `-1` excluded by `app_group_available=true` filter; `0` extracted as-is |
| `generation_delta` | `-1` | Provider restart (first call) or App Group unavailable — sentinel | Filtered by `provider_restart=false AND generation_delta >= 0` |
| `latency_seconds` | `-1` | Latency invalid (missing epoch, out of window, restart, or App Group unavailable) | Filtered by `latency_valid=true AND latency_seconds >= 0` |
| `reload_requested_at_epoch_seconds` (getTimeline) | `-1` | No reload epoch available | Not directly extracted; gated by `latency_valid` |

| Boolean field | `true` | `false` |
|---------------|--------|---------|
| `app_group_available` | App Group UserDefaults resolved successfully at process init | App Group unavailable (resolution failed) — all generation/latency fields are sentinels |
| `provider_restart` | First `getTimeline` call after extension process start | Subsequent calls within same process |
| `latency_valid` | Elapsed time within window and epoch is present | Missing epoch, stale, or out-of-window |

| String field | Values | Meaning |
|--------------|--------|---------|
| `observed_generation_source` | `set`, `unset`, `unavailable` | `set`: App Group available, generation key exists. `unset`: App Group available, key not yet written. `unavailable`: App Group resolution failed. |

---

## Constants and key definitions

| Name | Value | Notes |
|------|-------|-------|
| `reloadGenerationKey` | `"TrioComplication_reloadGeneration"` | `Int`, App Group UserDefaults. Watch-app-only writer. |
| `lastReloadRequestEpochSecondsKey` | `"TrioComplication_lastReloadRequestEpochSeconds"` | `Int`, App Group UserDefaults. Watch-app-only writer. |
| `latencyValidityWindowSeconds` | `600` (10 min) | Conservative initial value. Tune after observing distributions. |
| `ProviderProcessState.instanceID` | `UUID()` (static let) | Generated once per extension process lifetime. |
| `ProviderProcessState.lastSeenGeneration` | `Int?` (static var, initially nil) | Process-local; tracks last observed generation for delta computation. Only updated when App Group is available. |
| `ProviderProcessState.isFirstCall` | `Bool` (static var, initially true) | Process-local; true on first `getTimeline` call, false thereafter. Decouples restart detection from `lastSeenGeneration`. |

---

## Sequencing

Three phases, each independently shippable:

- **Phase A** — Code logging (no dashboard dependency). Ship and verify logs appear in Better Stack before proceeding.
- **Phase B** — Better Stack Extract Metrics configuration. Requires Phase A logs flowing. If configured before Phase A ships, extraction rules produce zero rows silently (no error).
- **Phase C** — Dashboard panels. Requires Phase B extraction rules active.

**Phase A atomic shipping:** All five Phase A tasks (A1–A5) must ship together in a single build. A4 depends on A2 (`ProviderProcessState`) and A3 (new log method signature). A1 must be present or `currentReloadGeneration()` always returns nil. No individual task within Phase A is safe to ship in isolation.

**Rollback:** Phase A is observability-only — no changes to the CGM data path, complication rendering, or user-facing behavior. Revert is safe at any time.

---

## Phase A: Code logging

**Engineer handoff note:** Line numbers referenced below were validated against the Trio worktree at v1.1 (2026-03-05). If other changes have landed since then, verify line numbers against `HEAD` before applying edits. Function names and code snippets are more durable anchors than line numbers.

### Task A1 — Write `reload_generation` + epoch on each reload request

**File:** `Trio Watch Shared/TrioComplicationDataStore.swift`

**Edit 1 — Add UserDefaults key constants** (after existing keys near line 175):

```swift
private static let reloadGenerationKey = "TrioComplication_reloadGeneration"
private static let lastReloadRequestEpochSecondsKey = "TrioComplication_lastReloadRequestEpochSeconds"
```

**Edit 2 — Add latency validity window constant** (near the key constants):

```swift
static let latencyValidityWindowSeconds = 600
```

**Edit 3+4 — Increment, persist, and log in `reloadTimeline()`** (around lines 679–686):

The existing code:

```swift
private func reloadTimeline() {
    let requestedAtEpochSeconds = Int(Date().timeIntervalSince1970)
    let record = ComplicationReloadRecord(id: UUID(), requestedAtEpochSeconds: requestedAtEpochSeconds)
    #if !WIDGET_EXTENSION
    if let suiteName = appGroupID {
        ComplicationReloadRing.append(record, suiteName: suiteName)
    }
    #endif
    log("event=complication_reload_requested reload_id=\(record.id.uuidString) reload_requested_at_epoch_seconds=\(record.requestedAtEpochSeconds)")
```

Becomes:

```swift
private func reloadTimeline() {
    let requestedAtEpochSeconds = Int(Date().timeIntervalSince1970)
    let record = ComplicationReloadRecord(id: UUID(), requestedAtEpochSeconds: requestedAtEpochSeconds)
    var reloadGeneration: Int = -1
    #if !WIDGET_EXTENSION
    if let suiteName = appGroupID {
        ComplicationReloadRing.append(record, suiteName: suiteName)
    }
    if let defaults = appGroupDefaults {
        let current = defaults.integer(forKey: Self.reloadGenerationKey)
        reloadGeneration = current + 1
        defaults.set(reloadGeneration, forKey: Self.reloadGenerationKey)
        defaults.set(requestedAtEpochSeconds, forKey: Self.lastReloadRequestEpochSecondsKey)
    }
    #endif
    log("event=complication_reload_requested reload_generation=\(reloadGeneration) reload_requested_at_epoch_seconds=\(record.requestedAtEpochSeconds) reload_id=\(record.id.uuidString)")
```

`reloadGeneration` is initialized to `-1` (sentinel for "App Group unavailable"). If the write succeeds, it holds the authoritative new value — no read-back from UserDefaults.

**Write/read asymmetry note:** `defaults.integer(forKey:)` returns 0 when the key has never been set, so the first-ever write produces `0 + 1 = 1`. This is intentional — the reader method in A3 uses `object(forKey:)` nil-check and returns `nil` for unset keys, while the write path treats "unset" as 0 via `integer(forKey:)`. These are compatible: the first write produces generation 1, which is the first non-nil value the reader will ever see.

**Acceptance:**
- The first successful write produces `reload_generation=1`. Subsequent writes increment monotonically when `reload_generation != -1`.
- `reload_generation=-1` indicates App Group was unavailable (correlate with existing `AppGroupDiagnostics` log at startup).
- Value survives watch app kill and relaunch (manual test: note `reload_generation` value before killing watch app, reopen, trigger reload, verify counter is greater than its pre-kill value).
- **Optional coalescing calibration:** Trigger 10 rapid complication reloads (any action that calls `reloadTimeline()` — e.g., new CGM reading arrival, manual BG entry, settings change that triggers `forceComplicationUpdate()`) and verify `reload_generation` increments by 10. On the provider side, observe resulting `generation_delta` values to calibrate burst expectations.

---

### Task A2 — Add provider-local process state

**File:** `Trio Watch Complication/TrioWatchComplication.swift`

**Edit — Add `ProviderProcessState`** at file scope, just before `TrioWatchComplicationProvider` (line 125):

```swift
private enum ProviderProcessState {
    static let instanceID = UUID()
    static var lastSeenGeneration: Int?
    static var isFirstCall = true
}
```

`instanceID` is a static `let` — initialized once when the extension process loads the type. `lastSeenGeneration` starts as `nil` and is only updated when App Group is available. `isFirstCall` decouples restart detection from `lastSeenGeneration`; on process kill + relaunch all three statics reset.

`TrioWatchComplicationProvider` is a struct (value type), so mutable per-call state cannot live on the provider itself. WidgetKit runs the complication extension as a single process; statics persist across `getTimeline` invocations within that process.

**Acceptance:**
- `ProviderProcessState.instanceID` stays constant across multiple `getTimeline` calls (verify via `provider_instance_id` in logs).
- After force-killing the complication extension, the next `getTimeline` call logs a new `provider_instance_id` value.
- `provider_restart=true` appears exactly once per process lifetime (first `getTimeline` call), even when App Group is unavailable.

---

### Task A3 — Add App Group reader methods and update log signature

**File:** `Trio Watch Shared/TrioComplicationDataStore.swift`

**Edit 1 — Add reader methods** (near `newestReloadRecord()`, around line 568):

```swift
func currentReloadGeneration() -> Int? {
    guard let defaults = appGroupDefaults else { return nil }
    return defaults.object(forKey: Self.reloadGenerationKey) != nil
        ? defaults.integer(forKey: Self.reloadGenerationKey)
        : nil
}

func lastReloadRequestEpochSeconds() -> Int? {
    guard let defaults = appGroupDefaults else { return nil }
    return defaults.object(forKey: Self.lastReloadRequestEpochSecondsKey) != nil
        ? defaults.integer(forKey: Self.lastReloadRequestEpochSecondsKey)
        : nil
}
```

Uses `object(forKey:)` nil-check to distinguish "key unset" (fresh install) from "value is 0." `integer(forKey:)` alone returns 0 for unset keys, which would conflate "never written" with "generation 0."

**Edit 1b — Add App Group availability check** (near the reader methods):

```swift
func isAppGroupAvailable() -> Bool {
    appGroupDefaults != nil
}
```

Since `appGroupDefaults` is cached at init (via `cachedAppGroupDefaults = resolveAppGroupDefaultsOnce()`), this reflects the durable App Group state for the process lifetime.

**Edit 2 — Replace `logWidgetGetTimelineInvocation`** (line 800, inside `#if WIDGET_EXTENSION`):

Current:
```swift
#if WIDGET_EXTENSION
func logWidgetGetTimelineInvocation(mostRecentReloadId: String, latencySeconds: Int, reloadRequestedAtEpochSeconds: Int) {
    log("event=complication_get_timeline_called most_recent_reload_id=\(mostRecentReloadId) latency_seconds=\(latencySeconds) reload_requested_at_epoch_seconds=\(reloadRequestedAtEpochSeconds)")
}
#endif
```

New:
```swift
#if WIDGET_EXTENSION
func logWidgetGetTimelineInvocation(
    appGroupAvailable: Bool,
    observedGenerationSource: String,
    observedReloadGeneration: Int,
    generationDelta: Int,
    providerInstanceId: String,
    providerRestart: Bool,
    latencyValid: Bool,
    latencySeconds: Int,
    reloadRequestedAtEpochSeconds: Int,
    mostRecentReloadId: String
) {
    log(
        "event=complication_get_timeline_called"
        + " app_group_available=\(appGroupAvailable)"
        + " observed_generation_source=\(observedGenerationSource)"
        + " observed_reload_generation=\(observedReloadGeneration)"
        + " generation_delta=\(generationDelta)"
        + " provider_instance_id=\(providerInstanceId)"
        + " provider_restart=\(providerRestart)"
        + " latency_valid=\(latencyValid)"
        + " latency_seconds=\(latencySeconds)"
        + " reload_requested_at_epoch_seconds=\(reloadRequestedAtEpochSeconds)"
        + " most_recent_reload_id=\(mostRecentReloadId)"
    )
}
#endif
```

Note: `latency_seconds` is `Int` with sentinel `-1`. The value `-1` appears in raw logs but is excluded from metric extraction by the `latency_valid=true AND latency_seconds >= 0` filter in B4.

**Acceptance:**
- `currentReloadGeneration()` returns `nil` on fresh install, then the correct Int after the first reload request.
- `lastReloadRequestEpochSeconds()` returns `nil` until the first reload, then a recent epoch.
- `isAppGroupAvailable()` returns `true` when App Group resolved, `false` otherwise. Value is stable for the process lifetime.
- Log line contains all expected key=value fields per the sentinel conventions table, including `app_group_available` and `observed_generation_source`.

---

### Task A4 — Update `getTimeline` to compute and log all fields

**File:** `Trio Watch Complication/TrioWatchComplication.swift`

**Edit — Replace the instrumentation block** in `getTimeline()` (lines 146–164):

Current:
```swift
func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
    // Instrumentation: log so reload→getTimeline correlation can be checked in Better Stack (Phase 0.2).
    // Verify both event types (complication_reload_requested from watch app, complication_get_timeline_called here) appear for the same device so joins on reload_id (and reload_requested_at_epoch_seconds as fallback/sanity check) are valid.
    let nowEpochSeconds = Int(Date().timeIntervalSince1970)
    if let newest = TrioComplicationDataStore.shared.newestReloadRecord() {
        let latency = max(0, nowEpochSeconds - newest.requestedAtEpochSeconds)
        TrioComplicationDataStore.shared.logWidgetGetTimelineInvocation(
            mostRecentReloadId: newest.id.uuidString,
            latencySeconds: latency,
            reloadRequestedAtEpochSeconds: newest.requestedAtEpochSeconds
        )
    } else {
        TrioComplicationDataStore.shared.logWidgetGetTimelineInvocation(
            mostRecentReloadId: "none",
            latencySeconds: -1,
            reloadRequestedAtEpochSeconds: -1
        )
    }

    let snapshot = loadLatestEntry()
    // ... timeline construction ...
```

New:
```swift
func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
    let store = TrioComplicationDataStore.shared
    let nowEpochSeconds = Int(Date().timeIntervalSince1970)
    let appGroupAvailable = store.isAppGroupAvailable()

    let observedGeneration: Int
    let generationSource: String
    if !appGroupAvailable {
        observedGeneration = -1
        generationSource = "unavailable"
    } else if let gen = store.currentReloadGeneration() {
        observedGeneration = gen
        generationSource = "set"
    } else {
        observedGeneration = 0
        generationSource = "unset"
    }

    let lastReloadEpoch = store.lastReloadRequestEpochSeconds()

    let isRestart = ProviderProcessState.isFirstCall
    ProviderProcessState.isFirstCall = false

    let generationDelta: Int
    if !appGroupAvailable {
        generationDelta = -1
    } else if let lastSeen = ProviderProcessState.lastSeenGeneration {
        generationDelta = observedGeneration - lastSeen
    } else {
        generationDelta = -1
    }

    if appGroupAvailable {
        ProviderProcessState.lastSeenGeneration = observedGeneration
    }

    let latencyValid: Bool
    let latencySeconds: Int
    if let epoch = lastReloadEpoch {
        let elapsed = nowEpochSeconds - epoch
        latencyValid = elapsed >= 0 && elapsed <= TrioComplicationDataStore.latencyValidityWindowSeconds
        latencySeconds = latencyValid ? elapsed : -1
    } else {
        latencyValid = false
        latencySeconds = -1
    }

    let reloadId = store.newestReloadRecord()?.id.uuidString ?? "none"

    store.logWidgetGetTimelineInvocation(
        appGroupAvailable: appGroupAvailable,
        observedGenerationSource: generationSource,
        observedReloadGeneration: observedGeneration,
        generationDelta: generationDelta,
        providerInstanceId: ProviderProcessState.instanceID.uuidString,
        providerRestart: isRestart,
        latencyValid: latencyValid,
        latencySeconds: latencySeconds,
        reloadRequestedAtEpochSeconds: lastReloadEpoch ?? -1,
        mostRecentReloadId: reloadId
    )

    let snapshot = loadLatestEntry()
    // ... timeline construction unchanged ...
```

**Key behaviors:**
- **Three-way `observedGeneration` branch.** `isAppGroupAvailable()` checks whether `appGroupDefaults` was resolved at init. If unavailable (`false`), `observedGeneration = -1` (sentinel) and all downstream fields are sentinels. If available but key unset (`currentReloadGeneration()` returns nil), `observedGeneration = 0` — preserving the original "no perpetual restart" design. If available and key set, `observedGeneration` is the actual value. The `observed_generation_source` log field (`unavailable` / `unset` / `set`) makes each state self-documenting.
- **`isFirstCall` decouples restart detection from `lastSeenGeneration`.** Previously, `provider_restart` was derived from `lastSeenGeneration == nil`. Since `lastSeenGeneration` is now only updated when App Group is available, a separate `isFirstCall` flag ensures `provider_restart=true` appears exactly once per process lifetime regardless of App Group state.
- `generation_delta = -1` on first call (restart sentinel) or when App Group is unavailable; subsequent calls with available App Group compute `observed - lastSeen`.
- **Conditional `lastSeenGeneration` update.** `ProviderProcessState.lastSeenGeneration` is only set when App Group is available. This prevents a fallback sentinel (-1) or collapsed zero from poisoning future delta computations.
- **Negative deltas** (e.g., from a hypothetical App Group reset) flow through to the raw log for debugging. They are excluded from metrics by the `generation_delta >= 0` filter in B1. This scenario should not occur in practice — `reload_generation` persists in App Group across app restarts. The A1 acceptance criterion includes a manual persistence test.
- **Negative elapsed (clock skew):** If `nowEpochSeconds < epoch` (e.g., NTP correction on device), `elapsed` is negative, producing `latency_valid=false` and `latency_seconds=-1`. Low probability on watchOS but the behavior is correct — the measurement is meaningless. Visible in raw logs for debugging.
- **App Group unavailable (degraded state):** If App Group is unavailable, all provider-side fields are sentinels: `app_group_available=false`, `observed_generation_source=unavailable`, `observed_reload_generation=-1`, `generation_delta=-1`, `latency_valid=false`, `latency_seconds=-1`. `lastSeenGeneration` is not updated. This is a durable state for the process (since `appGroupDefaults` is cached at init). The provider still runs — timeline construction proceeds normally with whatever snapshot is available.
- `latency_valid = false` when `lastReloadRequestEpochSeconds` is nil (fresh install / no reload yet / App Group unavailable) or elapsed > 600s.
- `latency_seconds = -1` when invalid — prevents stale values from polluting metrics.
- `provider_instance_id` is logged for raw-log debugging but **must not be extracted** into metrics labels (high cardinality).
- `most_recent_reload_id` kept for transition parity; **must not be extracted**. **Deprecation candidate:** This field exists solely for ring-buffer-era compatibility. Schedule removal alongside ring buffer retirement (see "Ring buffer retirement" below).

**Acceptance:**
- `provider_restart=true` appears exactly once per extension process lifetime (first `getTimeline` call after process start), regardless of App Group availability.
- `generation_delta=1` dominates under normal 1:1 reload→provider flow.
- `generation_delta=0` appears for system-driven refreshes (no reload request between two provider calls).
- `generation_delta>1` appears during bursts (multiple reloads coalesced into one provider call).
- **No negative `generation_delta` values in normal operation** (excluding the `-1` restart/unavailable sentinel). If a negative delta appears with `provider_restart=false` and `app_group_available=true`, treat as a bug — investigate App Group reset or mismatch.
- `latency_valid=false` + `latency_seconds=-1` when no reload has ever occurred, App Group unavailable, or elapsed > 600s.
- `latency_valid=true` + `latency_seconds=<small int>` when provider runs shortly after a reload request.
- **App Group unavailable failure-mode signature:** reload logs show `reload_generation=-1`; provider logs show `app_group_available=false` + `observed_generation_source=unavailable` + `observed_reload_generation=-1` + `generation_delta=-1` + `latency_valid=false` + `latency_seconds=-1`; `lastSeenGeneration` is not updated (subsequent calls are NOT `provider_restart=true`).
- `observed_generation_source=unset` appears only before the first reload (App Group available but no reload has occurred yet).
- `observed_generation_source=set` appears during normal operation with active reloads.

---

### Task A5 — Minimal context marker logging

**File:** `Trio Watch App Extension/ExtensionDelegate.swift`

**Edit — Replace log line** in `applicationDidBecomeActive()` (line 17):

Current:
```swift
func applicationDidBecomeActive() {
    Task { await WatchLogger.shared.log("🟢 Watch app became active - requesting fresh data") }
    WatchState.shared.noteAppBecameActive()
    WatchState.shared.requestWatchStateUpdate()
    // Note: forceComplicationUpdate() is now called in finalizePendingData() after fresh data arrives
    // This prevents the race condition where stale data was saved before fresh data arrived
}
```

New:
```swift
func applicationDidBecomeActive() {
    Task { await WatchLogger.shared.log("event=watch_app_became_active context=foreground") }
    WatchState.shared.noteAppBecameActive()
    WatchState.shared.requestWatchStateUpdate()
    // Note: forceComplicationUpdate() is now called in finalizePendingData() after fresh data arrives
    // This prevents the race condition where stale data was saved before fresh data arrived
}
```

This emits a time-correlatable marker for "user opened the watch app." Time-based correlation between `watch_app_became_active` and subsequent reload/getTimeline events is sufficient per the design doc.

**Known gap:** This does not distinguish "notification tap" from "normal open." Notification-specific context (e.g., `context=notification_tap`) would require a `UNUserNotificationCenterDelegate` or `userInfo` inspection — deferred to a future spike if time-correlation proves insufficient.

**Acceptance:**
- `event=watch_app_became_active` appears in Better Stack logs each time the watch app transitions to foreground.
- Timestamps can be correlated with nearby `complication_reload_requested` events.

---

### Phase A summary: files changed

| File | Nature of change |
|------|-----------------|
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Add 2 UserDefaults keys, 1 constant, 2 reader methods, 1 availability check (`isAppGroupAvailable`); update `reloadTimeline()` to write scalars + log generation; replace `logWidgetGetTimelineInvocation` signature (10 params, +`appGroupAvailable`, +`observedGenerationSource`) and log format. |
| `Trio Watch Complication/TrioWatchComplication.swift` | Add `ProviderProcessState` enum (with `isFirstCall`); rewrite `getTimeline` instrumentation block with three-way generation branch and conditional `lastSeenGeneration` update. |
| `Trio Watch App Extension/ExtensionDelegate.swift` | Replace log line in `applicationDidBecomeActive()`. |

---

### Failure-mode signatures

These are cross-component patterns to look for when diagnosing specific failure modes in raw logs:

| Failure mode | Reload-side signature | Provider-side signature | How to confirm |
|---|---|---|---|
| **App Group unavailable** | `reload_generation=-1` on every `complication_reload_requested` | `app_group_available=false`, `observed_generation_source=unavailable`, `observed_reload_generation=-1`, `generation_delta=-1`, `latency_valid=false`, `latency_seconds=-1` on every `complication_get_timeline_called`. `lastSeenGeneration` not updated. | Check for `AppGroupDiagnostics` startup log indicating unavailability |
| **Fresh install / pre-first-reload** | No `complication_reload_requested` events yet | `observed_reload_generation=0`, `generation_delta=-1` (first call, restart), then `delta=0` (system-driven) until first reload. `latency_valid=false`. | Normal for the first few minutes after install; resolves once first CGM data triggers a reload. |
| **Provider restart** | (no change on reload side) | `provider_restart=true`, `generation_delta=-1`, new `provider_instance_id` | Single occurrence per process lifetime; subsequent calls show `provider_restart=false`. |

---

## Phase B: Better Stack Extract Metrics

All rules target `event=complication_get_timeline_called` log lines from the Trio source (source_id `1659391`).

**Verify before configuring:** Better Stack extraction filter syntax for boolean fields (`provider_restart=false`, `latency_valid=true`) may require string matching (`"false"`, `"true"`) rather than boolean equality, depending on how the log message fields are parsed. Confirm the correct comparison syntax in Better Stack's extraction rule UI before creating B1–B4 rules.

### Task B1 — `generation_delta` metric

- **Extract from:** `generation_delta=<int>` field in `event=complication_get_timeline_called` lines.
- **Filter:** `provider_restart=false AND generation_delta >= 0` (exclude restart sentinel `-1` and any negative anomalies).
- **Metric type:** Numeric (gauge). Extract the raw integer value.
- **Note:** Bucketing (0, 1, 2–5, >5) is performed at query time in Phase C ClickHouse queries, not at extraction time. Better Stack extraction emits the raw numeric; dashboard queries apply `countIf` buckets.

### Task B2 — `provider_restart` metric

- **Extract from:** `provider_restart=true|false` field.
- **Metric type:** Count metric with label value `true` or `false`.
- **Usage:** standalone restart-rate tracking; also used as filter predicate in B1/B4.

### Task B3 — `latency_valid` metric

- **Extract from:** `latency_valid=true|false` field.
- **Metric type:** Count metric with label value `true` or `false`.
- **Usage:** compute "% valid-latency provider runs"; filter predicate for B4.

### Task B4 — `latency_seconds` metric (gated)

- **Extract from:** `latency_seconds=<int>` field.
- **Filter:** `latency_valid=true AND provider_restart=false AND latency_seconds >= 0`. The `latency_valid` boolean is the primary gate. The `latency_seconds >= 0` guard is belt-and-suspenders insurance against sentinel `-1` values leaking through if `latency_valid` were ever missing from a log line.
- **Metric type:** Numeric (gauge).
- **Aggregations:** p50, p90, p95, p99, max, count.

### Important: do NOT extract

- `provider_instance_id` — high cardinality (UUID per process lifetime).
- `most_recent_reload_id` — high cardinality (UUID per reload request).

Both remain in raw logs for debugging only.

**New log fields (v1.5):** `app_group_available` and `observed_generation_source` are included in `complication_get_timeline_called` log lines for raw-log diagnostics. Extraction is optional — the existing B1 filter (`generation_delta >= 0`) already excludes App Group unavailable rows (which have `generation_delta=-1`). If explicit filtering is desired, add `app_group_available=true` to B1/B4 extraction predicates.

### Phase B acceptance criteria

- [x] All four extraction rules active in Better Stack.
- [x] `generation_delta` metric data points match raw log field values (spot-check 10 rows).
- [x] `generation_delta` metric contains no negative values (verify `generation_delta >= 0` filter working).
- [x] `latency_seconds` metric contains **only** rows where `latency_valid=true` in the raw log.
- [x] No extraction rules exist for `provider_instance_id` or `most_recent_reload_id`.
- [x] **Zero-row smoke test:** Within 1 hour of a confirmed reload event (verify a `complication_reload_requested` log exists in the window), verify at least 1 row is extracted for each of the four metrics. Zero rows indicates misconfigured extraction rules or Phase A logs not flowing. Use an active period — not a window where the watch was idle/charging.

### Phase B → Phase C handoff

After configuring extraction rules, record the concrete metrics table names and column names for each metric. Better Stack names these based on the extraction rule configuration. Expected schema shape (exact names TBD at configuration time):

| Metric | Expected table/column pattern | Merge function |
|--------|-------------------------------|----------------|
| `generation_delta` (B1) | Numeric gauge — a column containing the raw integer value. | Depends on Better Stack's materialized view: likely `avg` or `anyLast` for gauge-type metrics. Dashboard queries use `countIf` buckets, not aggregate merge functions. |
| `provider_restart` (B2) | Count metric with label `true`/`false`. | `sum` / `count` over label values. |
| `latency_valid` (B3) | Count metric with label `true`/`false`. | `sum` / `count` over label values. |
| `latency_seconds` (B4) | Numeric gauge — a column containing the raw integer value. | Percentile queries use `quantile(0.5)(col)`, `quantile(0.9)(col)`, etc. `max(col)` for the max panel. |

**Action:** Substitute the actual table/column names into the Phase C dashboard queries (replacing `<generation_delta_metrics_table>`, `<latency_seconds_metrics_table>`, etc.) before creating dashboard panels.

---

## Phase C: Dashboard updates

**Prerequisite:** Complete the Phase B → Phase C handoff above. All `<..._metrics_table>` placeholders in the queries below must be replaced with the actual table/column names recorded during Phase B configuration.

### Task C1 — Delta distribution panel

- **Query:** Bucket counts for `generation_delta` values: `0`, `1`, `2–5`, `>5`.
- **Filter:** `provider_restart=false AND generation_delta >= 0` (matches B1 extraction filter).
- **Shows:** system-driven (delta=0) vs reload-associated (delta=1) vs coalesced (delta>1).

**Dashboard query** (metrics table — use this for actual dashboard panels):

```sql
SELECT
  countIf(generation_delta = 0)              AS system_driven,
  countIf(generation_delta = 1)              AS reload_1to1,
  countIf(generation_delta BETWEEN 2 AND 5)  AS coalesced_2_5,
  countIf(generation_delta > 5)              AS coalesced_gt5
FROM <generation_delta_metrics_table>
WHERE time > now() - INTERVAL 24 HOUR
```

The exact metrics table name is determined by the B1 extraction rule name configured in Better Stack. The B1 extraction filter (`provider_restart=false AND generation_delta >= 0`) is applied at extraction time, so the dashboard query does not need to re-filter.

**Explore-only validation query** (raw logs — use in Better Stack Explore, not in dashboard panels):

```sql
SELECT
  countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%generation_delta=0 %') AS system_driven,
  countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%generation_delta=1 %') AS reload_1to1
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 24 HOUR
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%complication_get_timeline_called%'
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%provider_restart=false%'
  AND JSONExtract(raw, 'message', 'Nullable(String)') NOT LIKE '%generation_delta=-1%'
```

**Note:** The raw-log query uses `LIKE` pattern matching which is simpler and more portable than `extractAllGroupsHorizontal` regex (whose behavior varies across ClickHouse versions). The trailing space in `'%generation_delta=0 %'` is intentional — it acts as a field delimiter (the next field in the log line is `provider_instance_id`) to prevent `generation_delta=0` from matching `generation_delta=01` etc. Use raw-log queries only for Explore validation; all dashboard panels must use the extracted metrics table.

### Task C2 — Latency panels (filtered)

Three sub-panels using the B4 extracted `latency_seconds` metrics table (extraction already filters `latency_valid=true AND provider_restart=false AND latency_seconds >= 0`):

1. **Percentile panel:** p50, p90, p95, p99 of `latency_seconds`.
2. **Tail count panel:** count where `latency_seconds > 60` and `> 300`.
3. **Max latency panel:** max `latency_seconds` over time.

**Expected result:** After Phase C, the "hours-old" spikes that previously dominated p99/max disappear entirely because validity gating excludes them.

**Operational note:** By construction, max `latency_seconds` under `latency_valid=true` should never exceed `latencyValidityWindowSeconds` (600s). If the max exceeds ~620s (allowing minor clock-skew tolerance), the extraction filter in B4 is likely broken — investigate immediately.

### Task C3 — Reload-association ratio panel

- **Metric:** `countIf(generation_delta > 0) / count(*)` from the B1 extracted `generation_delta` metrics table. Extraction already filters `provider_restart=false AND generation_delta >= 0`.
- **Shows:** % of provider runs that are reload-associated vs system-driven.

### Task C4 — Provider restart rate panel

- **Metric:** count of `provider_restart=true` events over time.
- **Shows:** How often WidgetKit kills and restarts the extension process.
- **Use:** Correlate restart frequency with system pressure, time of day, or watchOS updates.

### Hypotheses / initial expectations

These are priors for initial calibration, **not** pass/fail acceptance criteria:

- Reload-association ratio (C3): expect ~60–90% reload-associated under normal operation. If significantly lower, investigate whether system-driven refreshes dominate or reload requests aren't reaching App Group.
- Delta distribution (C1): expect majority delta=1, some delta=0, occasional delta>1 during bursts.
- Provider restart rate (C4): expect restarts correlating with system pressure (low memory) or daily patterns.

### Phase C acceptance criteria

- [x] Delta distribution panel renders and shows non-zero counts in at least two buckets (delta=0 and delta=1).
- [x] Latency percentile panel renders; p50 and p90 are within the 0–600s range.
- [x] Latency max panel value does not exceed 620s (validates validity window gating). *(Max is now included in the Valid Latency chart.)*
- [x] Reload-association ratio panel renders and produces a non-trivial ratio (neither 0% nor 100%). *(Now a single "Reload-associated %" number card.)*
- [x] Provider restart panel renders and shows events. *(Removed during dashboard v2 — restart events are visible in raw logs and Generation Delta Distribution already excludes them via `provider_restart=false` filter. Separate panel was not actionable.)*
- [x] All panels update with new data within the expected extraction pipeline latency.

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **UserDefaults coalescing during bursts** | Occasional `delta=0` where `delta>0` expected; generation counter may appear to skip values from the provider's perspective. | Accept as non-transactional. Rely on aggregate distribution trends, not individual events. Document in dashboard annotations. CGM cadence (~5min) is well below coalescing threshold. |
| **Provider process restarts** | First call after restart has `generation_delta=-1` (sentinel). If not filtered, pollutes delta aggregates. | All delta and latency metrics/dashboard queries filter `provider_restart=false AND generation_delta >= 0`. Monitor restart rate separately (Task C4). |
| **App Group unavailable** | Generation reads return nil → `?? 0` fallback; writes skipped (`reload_generation=-1` in log). `latency_valid=false` always. | Existing `logAppGroupDiagnosticsOnce` fires at startup. Graceful fallback: log `observed_reload_generation=0`, `latency_valid=false`, `latency_seconds=-1`. |
| **Negative generation delta (App Group reset)** | If watch app's counter somehow resets, `observed < lastSeen` produces negative delta. | `generation_delta >= 0` filter in B1 excludes these from metrics. Visible in raw logs for debugging. Should not occur — App Group persists across restarts. A1 acceptance includes manual persistence test. |
| **WINDOW too small (600s)** | Drops legitimate but delayed reload-associated latency values. | Start conservative. If data shows valid-latency events clustering near the 600s boundary, increase to 1200–1800s. |
| **WINDOW too large** | Reintroduces stale-correlation artifacts in latency tails. | 600s is well under the multi-hour spikes we want to eliminate. Can decrease if needed. |
| **Ring buffer + scalar keys diverge** | Two sources of "last reload info" may confuse future code readers. | Keep ring buffer temporarily for transition. See "Ring buffer retirement" section below for concrete trigger. |
| **`integer(forKey:)` returns 0 for unset key** | Could conflate "never set" with "generation 0." | Reader methods use `object(forKey:) != nil` guard to distinguish unset from zero. Call site `?? 0` collapses intentionally — documented in Task A4. |

---

## Ring buffer retirement

The ring buffer (`ComplicationReloadRing`) and the `most_recent_reload_id` / `newestReloadRecord()` call in Task A4 are kept for transition parity only. Retirement removes a cross-process App Group read from every `getTimeline` call and simplifies the data model.

**Concrete trigger:** After 2 weeks of Phase B `generation_delta` metrics flowing with no regressions (no missing data, extraction rules stable, dashboard panels populated), file a task to:
1. Remove the `newestReloadRecord()` call and `reloadId` / `most_recent_reload_id` field from `getTimeline` and the log method.
2. Remove `ComplicationReloadRing.append(...)` from `reloadTimeline()`.
3. Remove `ComplicationReloadRing` and `ComplicationReloadRecord` types if no other consumers remain.
4. Regenerate affected patches.

---

## Better Stack validation queries

**Phase A — verify new log fields present:**

```sql
SELECT
  JSONExtract(raw, 'message', 'Nullable(String)') AS msg
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 6 HOUR
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%complication_get_timeline_called%'
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%generation_delta%'
ORDER BY dt DESC
LIMIT 20
```

**Phase B — verify extraction health:**

```sql
SELECT
  count(*) AS total,
  countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%latency_valid=true%') AS valid,
  countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%latency_valid=false%') AS invalid,
  countIf(JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%provider_restart=true%') AS restarts
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 24 HOUR
  AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%complication_get_timeline_called%'
```

**Phase C — verify validity gating eliminates stale tails:**

Confirm `latency_seconds` max under the `latency_valid=true AND provider_restart=false` filter stays within the 600s window (with minor clock-skew tolerance). A max > 620s indicates a broken extraction filter.

---

## Anomaly triage queries (Better Stack Explore)

Use these when dashboard metrics look odd or when validating edge cases. These are raw-log queries for Explore (not dashboard SQL).

**1. Generation reset / negative delta** (should be ~0 in normal operation)

Find provider runs where generation appears to move backwards:

```
event=complication_get_timeline_called AND generation_delta < 0 AND provider_restart=false AND app_group_available=true
```

Interpretation: App Group counter reset/cleared or suite mismatch. Treat as a bug.

**2. App Group unavailable in provider** (hard failure mode)

```
event=complication_get_timeline_called AND app_group_available=false
```

Expected accompanying signature:
- `observed_reload_generation=-1`
- `observed_generation_source=unavailable`
- `generation_delta=-1`
- `latency_valid=false`

**3. Generation key unset** (first-run / pre-rollout / key cleared)

```
event=complication_get_timeline_called AND app_group_available=true AND observed_generation_source=unset
```

Interpretation: provider can read App Group, but the generation key hasn't been written yet (or was cleared). After first reload request write, this should transition to `observed_generation_source=set`.

**4. Latency invalid** (timestamp missing or outside window)

```
event=complication_get_timeline_called AND latency_valid=false
```

Interpretation: either `last_reload_request_epoch_seconds` missing, clock skew (negative elapsed), or elapsed > WINDOW.

**5. Restart artifacts** (exclude from latency/delta distributions)

```
event=complication_get_timeline_called AND provider_restart=true
```

Interpretation: first call in provider process lifetime; exclude from distributions as planned.

---

## Self-review summary (v1.0 → v1.1)

Performed full self-review protocol: re-read the implementation plan top-to-bottom, cross-referenced every line number, code snippet, method name, access modifier, and compile-time guard against the actual source files in the Trio worktree. Three issues found and fixed:

1. **Task A2 — wrong line reference.** The plan said to place `ProviderProcessState` "after line 10" (which is the end of the `ComplicationDefaults` enum, far from the provider struct). Fixed to say "just before `TrioWatchComplicationProvider` (line 125)" — which is where the enum logically belongs since the provider is its only consumer.

2. **Task A4 — incomplete "current" snippet.** The before-state was missing the two instrumentation comment lines at actual lines 147–148 (`// Instrumentation: log so reload→getTimeline correlation...` and `// Verify both event types...`). Added them so the engineer can do an exact match when locating the code to replace.

3. **Task A5 — "current" and "new" snippets both dropped existing comments.** The actual `applicationDidBecomeActive()` has a two-line comment block explaining why `forceComplicationUpdate()` is not called there (lines 20–21). Both the before and after snippets omitted it, which would cause the engineer to silently delete those comments. Fixed both snippets to preserve the comment.

Additionally verified (no issues found):
- All `#if !WIDGET_EXTENSION` / `#if WIDGET_EXTENSION` guards are correct for the single-writer invariant.
- `latencyValidityWindowSeconds` is `static let` (not `private`) so it's accessible from `TrioWatchComplication.swift` — matches the cross-file reference in Task A4.
- Reader methods use `object(forKey:)` nil-check before `integer(forKey:)` — correctly handles the "never set" vs "value is 0" ambiguity.
- `logWidgetGetTimelineInvocation` call site (Task A4) parameter names exactly match the declaration (Task A3 Edit 2) — all 8 parameters align.
- `appGroupDefaults` is `private` but all reads/writes are within `TrioComplicationDataStore` methods — access is valid.
- `ProviderProcessState` static vars are safe given WidgetKit serializes `getTimeline` calls per kind.
- Both source files (`Trio Watch Shared/`, `Trio Watch Complication/`) are compiled into the complication target, confirming cross-file references resolve.

---

## Implementation log

| Date | Phase | Action | Details |
|------|-------|--------|---------|
| 2026-03-05 | A | Implemented all 5 tasks (A1–A5) | 3 files changed, 118 insertions, 20 deletions. Branch: `feature/watch-complication-improvements` in `Trio` worktree. |
| 2026-03-05 | A | v1.5 refinement applied during implementation | Re-evaluated nil→0 decision for `observed_reload_generation`. Added three-way branch (unavailable/unset/set), `isFirstCall` for restart decoupling, `isAppGroupAvailable()`, and two new log fields (`app_group_available`, `observed_generation_source`). |
| 2026-03-05 | A | Self-review passed (2 rounds) | All 7 edit points verified against plan: constants, sentinels, access modifiers, compile-time guards, parameter names/types/ordering, log field names/ordering, cross-file references. 0 issues found. |
| 2026-03-05 | A | Build verified (dev + patches) | Patch 09 regenerated via tmp branch workflow (`tmp/09-baseline` + `tmp/09-update`). `patch-test.sh` passed (all 9 patches). `ci/local-build.sh --base-branch dev --build-only` succeeded in 12m 35s. |
| 2026-03-05 | A | First log verified in Better Stack | `complication_get_timeline_called` log confirmed with correct field values for first-call/post-deploy/pre-first-reload state: `app_group_available=true`, `observed_generation_source=unset`, `observed_reload_generation=0`, `generation_delta=-1`, `provider_restart=true`, `latency_valid=false`. |
| 2026-03-05 | B | Created 4 extraction rules via REST API | `generation_delta` (m-14603171, int64_delta, avg/count/max/min/p50-p99), `provider_restart` (g-14603172, string_low_cardinality), `latency_valid` (g-14603173, string_low_cardinality), `latency_seconds_valid` (m-14603174, int64_delta, avg/count/max/min/p50-p99). Filters: B1 `provider_restart=false AND >= 0`; B4 `latency_valid=true AND provider_restart=false AND >= 0`. |
| 2026-03-05 | B | Created 4 bucket extraction rules for C1/C3 | `generation_delta_eq0` (m-14603331), `generation_delta_eq1` (m-14603332), `generation_delta_2_5` (m-14603333), `generation_delta_gt5` (m-14603334). All int64_delta with sum aggregation. Same event+restart filter as B1. |
| 2026-03-05 | C | Created 6 dashboard panels | Added "Causality Metrics (Phase 0.2)" section to dashboard 689533. Charts: Generation Delta Distribution (stacked bar), Valid Latency Percentiles (line, p50/p90/p95/p99), Max Valid Latency (line), Valid Latency Events (number), Reload-Association Ratio (line, 0–100%), Provider Restart Rate (bar). All use `{{source}}` variable. |
| 2026-03-06 | B/C | Acceptance verification complete | All Phase B and C acceptance criteria verified with live data. Extraction rules producing correct values; dashboard panels rendering and showing expected data patterns. |
| 2026-03-06 | C | Dashboard v2 improvements (reviewer feedback) | (a) Fixed Provider Restart Rate % denominator (was all log events, now complication events only). (b) Reload-Association converted to stacked bar (30m) + companion Association Rate + Total Calls line chart. (c) SLO panels (≤60s, ≤300s) using existing complication_latency_* bucket metrics; newly created extraction rules are NOT retroactive in Better Stack. (d) Added Latency Validity Rate % panel. (e) Generation Delta Distribution % widened to 60m. (f) Dashboard Notes static text added. (g) App Group canary confirmed. Self-review caught restart-rate denominator bug. |
| 2026-03-06 | C | Dashboard v3 — consolidation and finalization | (a) Combined Generation Delta Distribution into single chart: 1h buckets, stacked absolute counts, 4 series (Δ=0, Δ=1, Δ2-5, Δ>5). (b) Merged max into Valid Latency chart (p50/p90/p95/p99/max). (c) Removed 5 redundant/low-value charts: Max Valid Latency, Reload-Association (30m), Provider Restart Rate, Gen Delta Distribution %, Association Rate %. (d) Added Reload-associated % number card. (e) Fixed Dashboard Notes rendering (query→static_text). (f) Set `explanation` field on all charts via export/import workflow. (g) Documented learnings in `docs/betterstack-guide.md`, updated `AGENTS.md`. Final Causality section: 9 charts. |

---

## Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-03-05 | Initial implementation plan: Phase A (code logging — 5 tasks across 3 files), Phase B (Better Stack extract metrics — 4 extraction rules), Phase C (dashboard panels — 4 panels). Includes file-level edit specifications with before/after code, risks/mitigations table, Better Stack validation queries, and per-phase acceptance criteria. |
| 1.1 | 2026-03-05 | Self-review pass: fixed Task A2 line reference (line 10 → line 125), added missing comment lines in Task A4 current-state snippet, preserved existing comments in Task A5 before/after snippets. See "Self-review summary" section. |
| 1.2 | 2026-03-05 | Reviewer feedback round 1 (R1: ChatGPT, R2: Claude). Key changes: (a) Task A1 — log `newGeneration` directly instead of UserDefaults read-back, restructured to hoist var; (b) Task A4 — documented `?? 0` as intentional, rejected "keep optional" (would cause perpetual restart detection); (c) Task B1 — added `generation_delta >= 0` belt-and-suspenders filter; (d) Task B4 — added `latency_seconds >= 0` guard; (e) Added "Sentinel and validity conventions" section; (f) Task C3 — moved "60–90%" from acceptance criteria to hypothesis; (g) Task C1 — replaced placeholder query with concrete ClickHouse pattern; (h) Added Phase A atomic shipping + rollback notes; (i) Task A1 — added persistence manual test to acceptance; (j) Task C2 — added 620s alert threshold note; (k) Added negative-delta row to risks table. |
| 1.3 | 2026-03-05 | Reviewer feedback round 2 (R1: ChatGPT, R2: Claude). 12 normalized issues; 8 applied, 2 rejected, 2 partially applied. Key changes: (a) A1 acceptance — scoped "monotonically" to non-sentinel, tightened persistence test wording, added optional coalescing stress test; (b) A4 — documented clock-skew and App Group degraded behavior, marked `newestReloadRecord()` for deprecation; (c) C1 — dashboard queries target metrics table, raw-log query demoted to Explore-only; (d) Phase B acceptance — added zero-row smoke test; (e) Sentinel table — noted `observed_reload_generation=0` is `?? 0` fallback; (f) New "Ring buffer retirement" section. |
| 1.4 | 2026-03-05 | Reviewer feedback round 3 — final (R1: ChatGPT, R2: Claude). 10 normalized issues; 9 applied, 1 partially applied, 0 rejected. Key changes: (a) A1 — documented `integer(forKey:)` write/read asymmetry with A3 reader, first write produces generation 1; clarified coalescing test trigger mechanism; (b) A4 — documented App Group unavailable degraded state (delta=0 forever), added negative-delta acceptance check; (c) New "Failure-mode signatures" table; (d) Phase B — added boolean filter syntax verification note, tightened zero-row smoke test, added Phase B → Phase C handoff step; (e) Phase C — added prerequisite note, explained C1 trailing-space delimiter; (f) Phase A — added engineer handoff note about line number staleness. |
| 1.5 | 2026-03-05 | Disambiguate "App Group unavailable" from "key unset" in provider-side logging. Key changes: (a) A2 — added `isFirstCall` to `ProviderProcessState`; (b) A3 — added `isAppGroupAvailable()`, `appGroupAvailable` and `observedGenerationSource` parameters and log fields; (c) A4 — three-way branch for `observedGeneration`, conditional `lastSeenGeneration` update; (d) Updated sentinel/boolean/string/constants tables, failure-mode signatures, and Phase B notes. |
| 1.6 | 2026-03-05 | Implementation complete — all three phases done. Phase A: build verified (dev + 9 patches). Phase B: 8 extraction rules via REST API. Phase C: 6 dashboard panels in new "Causality Metrics (Phase 0.2)" section. |
| 1.7 | 2026-03-06 | Dashboard v2 improvements. Fixed Provider Restart Rate % denominator. Reload-Association converted to stacked bar. SLO panels using existing complication_latency_* metrics (extraction rules NOT retroactive). Added Latency Validity Rate %. Gen Delta Distribution % widened to 60m. Dashboard Notes static text. App Group canary confirmed. |
| 1.8 | 2026-03-06 | ✅ Final close-out. Dashboard v3 consolidation: combined Gen Delta Distribution (1h, 4 series), merged max into Valid Latency, removed 5 redundant charts, added Reload-associated % number card. Set `explanation` on all charts. All Phase B and C acceptance criteria marked complete. Documented Better Stack learnings in `docs/betterstack-guide.md`. Updated `AGENTS.md` with guide reference and token storage. |
