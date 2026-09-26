+++
uid = "019f8141-e117-77db-9216-aac84d9c5565"
key = "TRIO-015"
title = "Notification-interaction complication refresh (Snooze/tap/dismiss)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/backlog/notif-complication-refresh/notif-complication-refresh-idea.md#L4"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "watch"]

[[acceptance]]
id = "AC-1"
text = "`UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` on watchOS handles Snooze, default tap, and custom-dismiss interactions uniformly"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "iOS attaches a `TrioComplicationSnapshot`-shaped payload to `content.userInfo` for notifications that should refresh the complication"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Watch handler applies staleness gating on a canonical timestamp before overwriting `TrioComplicationDataStore`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Handler updates only the complication data store and requests a timeline reload — no WatchState/pendingData/UI merge"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Structured logging/metrics per design §4.4 (applied/skipped/parse-failed counts)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Late interaction on an old notification does not overwrite the complication with stale data"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

When a notification reaches the watch, delivery alone doesn't reliably run app code — only user
interaction (Snooze, tap, or custom dismiss) does. This feature uses that interaction as a
deterministic, budget-free trigger to refresh the complication from a `TrioComplicationSnapshot`
carried in the notification payload, without adding new WatchConnectivity flows. Full design in
`docs/backlog/notif-complication-refresh/notif-complication-refresh-idea.md`.

## Notes carried over from acceptance criteria
