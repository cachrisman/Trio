# Idea: Use Watch Notification Action Handlers to Refresh the Complication

**Status:** Backlog  
**Created:** 2026-03-13

---

## What we're optimizing for

When any notification reaches the watch, the system may not run our app code just on delivery. But the moment the user interacts with that notification (Snooze, tap, or dismiss), watchOS will invoke our notification action handler — and that's the reliable hook where we can apply a fresh complication snapshot immediately.

**The feature:** On watch notification interaction, extract a `TrioComplicationSnapshot` from the notification's `userInfo`, save it to the complication data store, and reload the complication timeline.

No "request refresh" flow. No additional WatchConnectivity dependence.

---

## User interaction triggers

All go through `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` on watchOS:

1. **Snooze action (20 min)** — User taps Snooze → handler runs → apply snapshot → reload complication → then send snooze command to phone.
2. **Default tap (open / view notification)** — User taps the notification itself → handler runs → apply snapshot → reload.
3. **Dismiss (custom dismiss action)** — We register the notification category with `.customDismissAction`. User dismisses → handler runs with `UNNotificationDismissActionIdentifier` → apply snapshot → reload.

Practically: any meaningful interaction updates the complication.

(We're not trying to update purely on delivery, since that usually doesn't execute code unless the app is already foreground.)

---

## Data model: reuse TrioComplicationSnapshot schema in notification userInfo

### On iOS (when creating the notification)

- When building the low-glucose `UNMutableNotificationContent`, attach a dictionary into `content.userInfo` that matches the existing `TrioComplicationSnapshot` payload schema (property-list safe: strings/numbers/dates/arrays/dicts).
- This snapshot represents only the most recent complication snapshot (not full `WatchState`).

**Key point:** No "second representation" of complication data — reuse the existing snapshot schema so parsing is shared and stable.

### On watchOS: apply snapshot, nothing else

Inside the watch notification handler:

1. Extract snapshot dict from `response.notification.request.content.userInfo`
2. Parse into `TrioComplicationSnapshot`
3. Save to `TrioComplicationDataStore` (overwrite "latest snapshot")
4. Trigger complication reload (`WidgetCenter.reloadTimelines(ofKind:)` / existing reload path)

No merging into `WatchState`. No `pendingData`. No UI state updates. Just "snapshot → store → reload".

---

## Freshness/staleness safety

Include a single canonical timestamp (epoch or `Date`) in the snapshot and gate:

- If snapshot is missing timestamp or is clearly stale beyond a chosen threshold → skip applying (or apply but log it as stale; whichever fits current gating philosophy).

This prevents "late interaction on an old notification" from overwriting the current complication with ancient data.

---

## Metrics + logging

Add lightweight, structured logging and metrics on watchOS to prove impact.

### Suggested events

- `event=notif_snapshot_apply action=snooze|default|dismiss result=applied|skipped_missing|skipped_stale age_seconds=...`
- `event=notif_snapshot_parse_failed reason=...`
- `event=notif_snapshot_reload_requested kind=...`

### Suggested counters

- `notif_snapshot_applied_count` by action type
- `notif_snapshot_skipped_missing_count`
- `notif_snapshot_skipped_stale_count`
- `notif_snapshot_parse_failed_count`
- Optionally timing: `notif_snapshot_apply_latency_ms` (start handler → save+reload call)

### What this tells us

- How often users interact vs just ignore
- Whether snapshot data is consistently present
- Whether reload requests correlate with improved freshness

---

## Scope boundaries

- **In scope:** Notification interaction is the trigger (Snooze / tap / custom dismiss)
- **In scope:** Custom dismiss action included
- **In scope:** Reuse `TrioComplicationSnapshot` schema in `userInfo`
- **In scope:** Only updates "latest complication snapshot", not full `WatchState`
- **In scope:** Add logging/metrics to validate
- **Out of scope:** No request-refresh fallback
- **Out of scope:** No WatchConnectivity dependence
- **Out of scope:** No delivery-time code execution (unreliable without foreground app)
