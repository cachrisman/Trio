# Bug: Watch complication debug view — connects & EGVs daily counters not persistent across upgrades

**Version:** 1.0
**Status:** Backlog (target: build 212)
**Created:** 2026-06-18
**Reported by:** Charlie (observed after a build 211 deploy)

---

## 1. Problem

The watch **Complication Debug View** shows BLE daily totals — **connects** and **EGVs** (the
same `· BLE · egvs/conns` pair surfaced on the glucose-bubble status line). After an **app
upgrade** (installing a new build), these lines do **not** persist — the connects/EGVs counts
reset rather than carrying the day's running totals across the upgrade.

Expected: within the same calendar day, an in-place upgrade should preserve the day's connect/EGV
totals (they are "daily totals," reset only at local-midnight rollover — not on every build install).

This is a **diagnostics/observability** bug (the counters are debug-surface only); no closed-loop or
delivery impact. Low severity, file-and-fix.

## 2. Current state / code pointers

- **Display:** `Trio Watch App Extension/Views/ComplicationDebugView.swift:589` reads
  `WatchState.shared.bleEGVsToday` (connects line adjacent); also surfaced in
  `Trio Watch App Extension/Views/GlucoseTrendView.swift` status line.
- **Source of truth:** `Trio Watch App Extension/G7WatchSensorAdapter.swift` daily-counter block
  (~L616–680): `bleConnectsToday` / `bleEGVsToday`, persisted to **`UserDefaults.standard`** under
  keys `G7WatchAdapter.bleConnectsToday` / `…bleEGVsToday` / `…bleCountersCalendarDay`, with a
  forward-only local-midnight rollover (`loadDailyCounters`, `persistDailyCounters`,
  `advanceDayIfNeeded`) and `mirrorDailyCountersToWatchState()`.
- The calendar-day gate keys on `Calendar.current.startOfDay(...)`; same-day load restores the
  stored ints, so within-day persistence is intended.

## 3. Hypotheses to investigate (build 212)

- **`UserDefaults.standard` durability on watchOS upgrade.** Confirm whether the watch app's
  standard `UserDefaults` actually survives the build's upgrade/reinstall path in this setup, or
  whether the watch-app container is being wiped (fresh-install semantics) — which would zero the
  counters legitimately from storage.
- **App-group vs standard defaults.** The complication/data store uses the shared app group
  (`TRIO_APP_GROUP_ID`); these counters use `UserDefaults.standard`. If standard defaults don't
  survive upgrade reliably, consider persisting the daily counters in the **app-group** container
  (shared, and already used by `TrioComplicationDataStore` / `ComplicationLogBuffer`) so the
  debug view and complication read durable state.
- **Upgrade-triggered reset path.** Rule out any build-change handler resetting counter keys on
  upgrade (cf. `WatchLogger` `lastKnownBuildKey` `[UPGRADE]` logic) — confirm nothing clears the
  `G7WatchAdapter.*` keys on version change.
- **Confirm it's actually an upgrade reset, not midnight rollover** coinciding with the deploy.

## 4. Scope

| In scope | Out of scope |
|----------|--------------|
| Make connects/EGVs (and sibling daily counters) survive an in-place upgrade within the same day | Changing what the counters mean or how they're computed |
| Pick durable storage (app-group vs standard) + verify across an actual build upgrade | Non-debug UI redesign |
| Keep the local-midnight daily rollover behavior intact | Phone-side `G7DirectBLEObserver` parity changes (unless trivially shared) |

## 5. Success criteria

- Install build N with non-zero same-day connects/EGVs, upgrade to build N+1 mid-day → the debug
  view (and status line) still show the day's accumulated connects/EGVs, not 0.
- Local-midnight rollover still zeroes them exactly once per day.

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-06-18 | Initial bug filing from build-211 observation. Code pointers + hypotheses for build-212 impl. |
