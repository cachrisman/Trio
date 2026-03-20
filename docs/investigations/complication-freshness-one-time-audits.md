# Complication Freshness — One-Time Audits

**Version:** v1
**Created:** 2026-03-19 16:16 CET
**Last updated:** 2026-03-19 16:16 CET

Three one-time investigations performed against the Trio codebase and BetterStack logs on 2026-03-19, referenced from `docs/in-progress/complication-freshness/problem-and-strategy.md` backlog items.

---

## 1. NSFileProtection on App Group container (watch side)

**Finding: Safe. No action needed.**

### Storage mechanism

`TrioComplicationDataStore` (from patch `09-watch-complication-improvements`) uses two storage mechanisms:

| Storage | Mechanism | Explicit protection set? |
|---|---|---|
| UserDefaults | `UserDefaults(suiteName:)` with App Group suite (`TRIO_APP_GROUP_ID`) | No |
| File-based | `snapshot.json` in App Group container, via `Data.write(to:options:[.atomic])` | No |

Directory creation passes `attributes: nil`. File writes specify no protection options. `ComplicationLogBuffer` similarly creates directories and writes files with no protection attributes.

### Entitlements

| File | App Group |
|---|---|
| `Trio Watch App/TrioWatchApp.entitlements` | `$(TRIO_APP_GROUP_ID)` |
| `Trio Watch Complication/TrioWatchComplication.entitlements` | `$(TRIO_APP_GROUP_ID)` |

`TRIO_APP_GROUP_ID` resolves to `group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group` via `Config.xcconfig`.

### Effective protection level

No code sets `FileProtectionType` or `protectionKey` anywhere in watch-side complication code. The effective level is the **platform default for App Group containers on watchOS: `completeUntilFirstUserAuthentication` (Class C)**.

The iOS-side `PersistedProperty` (`.none`) and `FileProtectionFixer` do not touch the watch complication's App Group storage.

### Class C behavior on locked watch

Class C allows reads and writes after the first unlock, even when the watch is subsequently locked. Background tasks (`WKWatchConnectivityRefreshBackgroundTask`, WidgetKit timeline requests) can access storage on a locked watch as long as it has been unlocked at least once since boot.

The only failure scenario is post-reboot/pre-first-unlock. This is extremely narrow on Apple Watch: WatchConnectivity requires the watch to be on-wrist (Bluetooth-connected), and wrist-on triggers unlock when wrist detection is enabled.

### Verdict

Safe. The default Class C protection is compatible with all complication background write scenarios. No remediation needed.

---

## 2. CGM-only `readingDate` invariant

**Finding: Invariant violated in 3 meaningful code paths. Follow-up action needed.**

### Invariant under test

`readingDate` (the CGM reading timestamp used by the complication) must always come from the actual CGM sample time, never from wall-clock time (`Date()`).

### All code paths that set `readingDate`

| # | File | Location | Value assigned | Violation? |
|---|---|---|---|---|
| 1 | `WatchState.swift` | `saveComplicationSnapshot` primary (~L913) | `Date(timeIntervalSince1970: readingEpoch)` from message | No (CGM epoch) |
| 2 | `WatchState.swift` | `saveComplicationSnapshot` fallback 1 (~L915) | `latestGlucoseDate(from: message)` — max date from glucoseValues | No (CGM dates) |
| 3 | `WatchState.swift` | `saveComplicationSnapshot` fallback 2 (~L917-921) | `message[WatchMessageKeys.date]` — iOS build time | **Yes** |
| 4 | `WatchState.swift` | `didReceiveUserInfo` (~L518) | `latestGlucoseDate ?? payload[WatchMessageKeys.date]` | **Yes** (when primary is nil) |
| 5 | `WatchState.swift` | HealthKit observer (~L341) | `latest.startDate` from `HKQuantitySample` | No |
| 6 | `WatchState.swift` | `forceComplicationUpdate` (~L1003) | `TrioComplicationDataStore.lastValidTimestamp` | No (prior CGM-derived) |
| 7 | `TrioComplicationDataStore` | `fallbackSnapshot` | `lastValidTimestamp ?? .distantPast` | No |
| 8 | `TrioWatchComplication.swift` | Placeholder (~L137) | `Date()` | **Yes** (UI preview only) |
| 9 | `AppleWatchManager.swift` | `setupWatchState` glucoseValues (~L347) | `glucose.date ?? Date()` | **Yes** (when glucose.date is nil) |

### Violations

**Violation 1 — `saveComplicationSnapshot` fallback 2 (L917-921):** If both `readingEpoch` and `latestGlucoseDate` fail, falls back to `WatchMessageKeys.date`. This key is documented with the warning `"⚠️ BUILD TIME, not CGM reading time"` — it is set to `Date()` when the iOS side assembles the state dictionary.

**Violation 2 — `didReceiveUserInfo` (L518):** Same pattern. When `latestGlucoseDate(from: payload)` returns nil (empty glucoseValues), falls back to `payload[WatchMessageKeys.date]` (build time).

**Violation 3 — `setupWatchState` glucoseValues (L347):** `glucose.date ?? Date()` replaces a nil glucose date with wall-clock time. This value propagates into `glucoseValues` and can reach `latestGlucoseDate(from: message)`, infecting fallback 1 in `saveComplicationSnapshot`.

**Violation 4 — Placeholder (L137):** `readingDate: Date()` in the SwiftUI placeholder. Non-persisted, UI-only, but semantically wrong.

### Impact on complication freshness

When these fallbacks fire, `readingDate` is biased toward "now" (build time), making the snapshot look artificially fresh. The complication displays a stale reading but reports a recent `data_age_seconds`, masking the actual staleness from both the user and from telemetry.

### Recommended fixes

1. **`saveComplicationSnapshot` fallback 2:** Do not save a snapshot when both `readingEpoch` and `latestGlucoseDate` fail. Return early and log the failure instead of using build time.
2. **`didReceiveUserInfo`:** Treat nil `latestGlucoseDate` as invalid — return early rather than falling back to build time for `readingDate`.
3. **`setupWatchState`:** Skip glucose entries with nil dates rather than substituting `Date()`, or log and mark them as invalid.
4. **Placeholder:** Replace `readingDate: Date()` with `.distantPast` for semantic correctness.

### Verdict

Invariant is violated. Violations 1-3 can mask real staleness in production telemetry. Fix recommended as part of the next complication patch.

---

## 3. WidgetKit `getTimeline` clustering per widget family

**Finding: Per-family clustering does NOT explain the reload-to-getTimeline ratio. `widget_family` is not currently logged.**

### 48-hour totals (2026-03-17 16:16 CET to 2026-03-19 16:16 CET)

| Event | Count |
|---|---|
| `reloadTimelines` | 553 |
| `complication_get_timeline_called` | 307 |
| **Ratio** | **1.80:1** |

### Per-generation analysis

Each `reloadTimelines` call increments a generation counter. Grouping `getTimeline` events by `observed_reload_generation`:

| Distinct provider instances per generation | Generations | Total getTimeline calls |
|---|---|---|
| 1 instance | 149 | 301 |
| 2 instances | 1 | 6 |

Only **1 out of 150 generations** saw multiple widget instances respond. The vast majority (99.3%) have a single provider instance handling the reload.

### Provider instance churn

12 distinct `provider_instance_id` values observed over 48 hours. WidgetKit recycles instances frequently. 18 of 307 calls had `provider_restart=true` (generation_delta = -1).

| Instance ID | Calls |
|---|---|
| `5DD12857...` | 112 |
| `8A5B37FF...` | 54 |
| `406458A5...` | 48 |
| `F4B1AB46...` | 20 |
| `1CF2E31F...` | 18 |
| `FF8058BC...` | 16 |
| (6 others) | 1-10 each |

### What explains the 1.80:1 ratio

Per-family double-invocation is **not** the explanation. The ratio is driven by two factors:

1. **~45% of `reloadTimelines` calls never produce a `getTimeline` call.** WidgetKit coalesces or throttles rapid successive reloads. When Trio fires `reloadTimelines` every ~5 minutes but WidgetKit has recently refreshed or is already processing, it silently drops the request.

2. **Some generations produce 2-6 `getTimeline` calls to the same instance.** This is WidgetKit's internal retry or multi-entry behavior, not different widget families.

### `widget_family` field status

The `complication_get_timeline_called` event contains `provider_instance_id` but does **not** log `widget_family`. Adding it would confirm whether the single 2-instance generation (gen 3376) is truly two different families, but the data already shows this is not the dominant pattern.

### Verdict

The 553:307 ratio is a WidgetKit throttling artifact, not a per-family clustering issue. Adding `widget_family` logging is unnecessary — the question is answered without it.

---

## Changelog

### v1 (2026-03-19 16:16 CET)
- Initial creation: recorded findings from three one-time investigations (NSFileProtection, readingDate invariant, getTimeline clustering).
- Reason: preserve investigation results for future reference; close out one-time audit items from `problem-and-strategy.md` backlog.
