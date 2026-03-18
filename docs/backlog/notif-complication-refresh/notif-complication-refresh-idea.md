# Design: Notification Action Handlers to Refresh the Complication

**Version:** 1.2  
**Status:** Backlog  
**Created:** 2026-03-13  
**Last updated:** 2026-03-17 10:26 CET

---

## 1. Problem

**Bigger objective:** The Trio watchOS complication should show the latest CGM reading and recency within a few minutes of acquisition. Today that depends on WatchConnectivity (e.g. `transferCurrentComplicationUserInfo`), which is subject to a 50-transfer/day budget and may not run on notification delivery. When the complication is stale, the user may see outdated data on the watch face.

**This feature:** When a notification reaches the watch, the system often does not run our app code on delivery. The only reliable hook is when the user **interacts** with the notification (Snooze, tap, or dismiss). We use that interaction to refresh the complication with a snapshot carried in the notification payload — a budget-free, deterministic moment to apply fresh data — without adding WatchConnectivity flows or delivery-time logic.

---

## 2. Context / current state

- Complication data is today updated via WatchConnectivity and/or background paths. Delivery of a notification does not guarantee our code runs.
- `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` on watchOS is invoked when the user takes an action on a notification, providing a deterministic trigger.
- We already have a `TrioComplicationSnapshot` schema and `TrioComplicationDataStore`; the design reuses them.

---

## 3. Requirements and constraints

- **Trigger:** Refresh SHALL be triggered only by user interaction with a notification (action or dismiss), not by delivery.
- **No extra WC:** The feature SHALL NOT introduce a "request refresh" or additional WatchConnectivity dependence.
- **Single schema:** The notification payload SHALL use the existing `TrioComplicationSnapshot` schema (no second representation).
- **Narrow write:** On the watch, the handler SHALL update only the complication data store (latest snapshot) and request a timeline reload; it SHALL NOT merge into full WatchState, pendingData, or UI state.
- **Staleness:** The implementation SHALL gate application of the snapshot on a canonical timestamp and a staleness threshold; threshold value and configuration mechanism (e.g. build constant, plist) are left to implementation (see §6).

---

## 4. Functional behavior

### 4.1 User interaction triggers

All triggers SHALL be handled in `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` on watchOS. Supported interactions:

| Trigger | Description |
|--------|-------------|
| **Snooze action (20 min)** | User taps Snooze → handler runs → apply snapshot → reload complication → then send snooze command to phone. |
| **Default tap** | User taps the notification (open/view) → handler runs → apply snapshot → reload. |
| **Dismiss** | Notification category registered with `.customDismissAction`. User dismisses → handler runs with `UNNotificationDismissActionIdentifier` → apply snapshot → reload. |

Any notification that includes a complication snapshot in `userInfo` and belongs to a category with these actions SHALL trigger the same apply-and-reload flow when the user interacts. The category (with Snooze, default, and custom dismiss) is registered on the watch so the system can present these actions; the exact registration point is implementation-defined. (Applicable to all notification types currently defined in app.)

### 4.2 Data model

**iOS (when creating the notification)**  
When building `UNMutableNotificationContent` for any notification that should refresh the complication:

- Attach a dictionary in `content.userInfo` that matches the existing **`TrioComplicationSnapshot`** payload schema.
- Payload SHALL be property-list safe (strings, numbers, dates, arrays, dicts).
- The snapshot SHALL represent the most recent complication snapshot only (not full WatchState).
- No second representation of complication data: parsing and schema are shared with existing snapshot usage.

**watchOS (in the notification action handler)**  
The handler SHALL:

1. Extract the snapshot dictionary from `response.notification.request.content.userInfo`.
2. Parse it into `TrioComplicationSnapshot`. If parsing fails, do not update the store or request a reload; log (see 4.4) and call the completion handler, then return.
3. Apply staleness gating (see 4.3); if allowed, save to `TrioComplicationDataStore` (overwrite latest snapshot).
4. Trigger complication reload using the same path as existing complication updates (e.g. `WidgetCenter.reloadTimelines(ofKind:)`).

The handler SHALL NOT merge into WatchState, update pendingData, or perform UI state updates. Behavior is strictly: **snapshot → store → reload**.

### 4.3 Freshness / staleness safety (risk #1)

- The snapshot SHALL include a single canonical timestamp (e.g. epoch seconds or `Date`).
- If the snapshot is missing the timestamp or is older than the staleness threshold, the implementation SHALL skip applying it (or apply and log as stale); the choice is an implementation decision (see §6).
- This prevents a late interaction on an old notification from overwriting the current complication with stale data.

### 4.4 Metrics and logging (recommended)

Implement lightweight, structured logging and metrics on watchOS to validate impact.

**Suggested log events**

- `event=notif_snapshot_apply action=snooze|default|dismiss result=applied|skipped_missing|skipped_stale age_seconds=...`
- `event=notif_snapshot_parse_failed reason=...`
- `event=notif_snapshot_reload_requested kind=...`

**Suggested counters**

- `notif_snapshot_applied_count` (by action type)
- `notif_snapshot_skipped_missing_count`
- `notif_snapshot_skipped_stale_count`
- `notif_snapshot_parse_failed_count`
- Optional: `notif_snapshot_apply_latency_ms` (handler start → save + reload call)

These support answering: how often users interact vs ignore, whether snapshot data is present, and whether reloads correlate with improved freshness.

---

## 5. Scope boundaries

| In scope | Out of scope |
|----------|--------------|
| Notification interaction as trigger (Snooze, tap, custom dismiss) | Request-refresh fallback or extra WatchConnectivity |
| Any notification type that includes snapshot in `userInfo` | Delivery-time code execution (unreliable unless app foreground) |
| Custom dismiss action (`.customDismissAction` + `UNNotificationDismissActionIdentifier`) | |
| Reuse of `TrioComplicationSnapshot` schema in `userInfo` | |
| Updating only latest complication snapshot (not full WatchState) | |
| Logging and metrics to validate behavior | |

---

## 6. Risks and open questions

- **Staleness threshold:** Exact value (e.g. minutes), configuration mechanism (e.g. build constant or plist), and behavior when stale (skip vs apply-and-log) to be decided in implementation.

---

## 7. Success criteria (verifiable)

- User interaction (Snooze, tap, or dismiss) on a notification that carries a valid, non-stale snapshot results in the complication updating and timeline reload being requested.
- Late interaction on an old notification does not overwrite the complication with stale data (gating verified via logs/metrics).
- Logs and metrics (see 4.4) can be used to verify applied vs skipped (missing/stale) and optional latency; no new WC or request-refresh paths.

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.2     | 2026-03-17 10:26 CET | Design review: clarified staleness config deferral (§4.3, §6), reload path, parse-failure behavior, category registration, metrics vs success criteria, and "project gating policy" → §6. |
| 1.1     | 2026-03-17 | Problem statement: added bigger objective (complication freshness / latest reading within minutes; WC budget limits) and framed this feature as a budget-free refresh on notification interaction. |
| 1.0     | 2026-03-17 | Initial design spec. Scope: any notification (not limited to low glucose). Formalized triggers, data model, freshness gating, metrics, and scope boundaries. |
