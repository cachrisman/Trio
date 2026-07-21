+++
uid = "019f8141-e117-77db-9216-aacbb4e00f7e"
key = "TRIO-022"
title = "Fix: watch debug BLE daily counters don't persist across app upgrade"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/backlog/watch-debug-counter-persistence/watch-debug-counter-persistence-idea.md#L4"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["bug", "watch"]
+++

## Intent

The watch Complication Debug View's BLE daily totals (connects, EGVs) reset on an in-place app
upgrade instead of persisting through the calendar day. Diagnostics-only bug, no closed-loop
impact. Code pointers: `Trio Watch App Extension/G7WatchSensorAdapter.swift` daily-counter block
(~L616–680), keyed in `UserDefaults.standard` under `G7WatchAdapter.bleConnectsToday` /
`bleEGVsToday` / `bleCountersCalendarDay`. Verified 2026-07-20: current code still uses
`UserDefaults.standard` (not the shared app-group container), so the bug is still live. Leading
hypothesis: `UserDefaults.standard` may not survive the watch app's upgrade/reinstall path
reliably; consider moving these keys to the app-group container already used by
`TrioComplicationDataStore` / `ComplicationLogBuffer`.

## Acceptance criteria

- [ ] Confirm root cause: `UserDefaults.standard` durability vs. an upgrade-triggered reset path vs. midnight-rollover coincidence
- [ ] Install build N with non-zero same-day connects/EGVs, upgrade to build N+1 mid-day → debug view and status line still show accumulated totals, not 0
- [ ] Local-midnight rollover still zeroes counters exactly once per day
