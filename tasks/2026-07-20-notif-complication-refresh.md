+++
uid = "019f8141-e117-77db-9216-aac84d9c5565"
key = "TRIO-015"
title = "Notification-interaction complication refresh (Snooze/tap/dismiss)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/backlog/notif-complication-refresh/notif-complication-refresh-idea.md#L4"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness", "watch"]
+++

## Intent

When a notification reaches the watch, delivery alone doesn't reliably run app code — only user
interaction (Snooze, tap, or custom dismiss) does. This feature uses that interaction as a
deterministic, budget-free trigger to refresh the complication from a `TrioComplicationSnapshot`
carried in the notification payload, without adding new WatchConnectivity flows. Full design in
`docs/backlog/notif-complication-refresh/notif-complication-refresh-idea.md`.

## Acceptance criteria

- [ ] `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` on watchOS handles Snooze, default tap, and custom-dismiss interactions uniformly
- [ ] iOS attaches a `TrioComplicationSnapshot`-shaped payload to `content.userInfo` for notifications that should refresh the complication
- [ ] Watch handler applies staleness gating on a canonical timestamp before overwriting `TrioComplicationDataStore`
- [ ] Handler updates only the complication data store and requests a timeline reload — no WatchState/pendingData/UI merge
- [ ] Structured logging/metrics per design §4.4 (applied/skipped/parse-failed counts)
- [ ] Late interaction on an old notification does not overwrite the complication with stale data
