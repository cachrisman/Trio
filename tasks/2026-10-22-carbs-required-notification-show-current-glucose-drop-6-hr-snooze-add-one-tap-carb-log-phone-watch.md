+++
uid = "01a162c4-a774-76ed-b7d7-23de5830ba27"
key = "TRIO-092"
title = "Carbs Required notification: show current glucose, drop 6 hr snooze, add one-tap carb log (phone + watch)"
status = "backlog"
kind = "code"
source = "human"
created = 2026-10-22
updated = 2026-10-28
touched = 2026-10-28
parent = "01a18464-7f48-7364-8944-b13bdac2ec28"

[[acceptance]]
id = "AC-1"
text = "Carbs Required notification shows the current glucose value (user units, with trend) in its text on both iPhone and watch"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-2"
text = "Carbs Required notification no longer offers Snooze 6 hrs on iPhone or watch; other alert types keep their current snooze list unless the operator decides otherwise"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-3"
text = "Carbs Required notification has a first action 'Log <N> g' using the grams carried in the notification userInfo, which writes a carb entry through the existing carb-storage path"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-4"
text = "Watch registers the carbs-required category and forwards the log-carbs action to the phone; failure to reach the phone is surfaced, not dropped"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-5"
text = "Unit tests cover the new category's action list/order and the log-carbs response handler (amount from userInfo, no double-log on repeated tap)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-6"
text = "Operator decides the log-carbs action's safety options (authenticationRequired/foreground, duplicate guard) before implementation"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-22

[[acceptance]]
id = "AC-7"
text = "On device: a real Carbs Required alert on iPhone and watch shows glucose, has Log N g at top and no 6 hr snooze, and tapping Log records the carbs"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-22
+++

## Intent

The Carbs Required alert (phone and Apple Watch) currently reads "To prevent LOW required 26 g of carbs" and offers the same four snooze buttons as every other glucose alert (Snooze 15 min / 1 hr / 3 hrs / 6 hrs). The operator wants three changes, applied to **both the iPhone notification and the watch notification**:

1. **Show the current glucose value** in the notification text (e.g. alongside the carbs amount, in the user's units, ideally with trend arrow the way the glucose alert body already formats it).
2. **Remove the bottom snooze option (Snooze 6 hrs)** from this notification.
3. **Add a new action at the top of the list that logs the carbs named in the notification** — "Log 26 g" in the screenshot example — so the user can record the carbs they ate in one tap.

Reported from a watch screenshot at 10:35 on 2026-10-22 (title "Carbs Required", body "To prevent LOW required 26 g of carbs", actions Snooze 15 min, Snooze 1 hr, …).

## Where the code is

- `Trio/Sources/Models/NotificationIdentifiers.swift`: `NotificationResponseAction` (snooze15/1hr/3hr/6hr) and `NotificationCategoryFactory.createGlucoseCategory()`, which builds the single shared `Trio.alert` category. Every glucose alert type uses this category today, so removing 6 hrs for Carbs Required only means a **separate category for carbs-required** (with log-carbs + 15 min/1 hr/3 hrs), not editing the shared list. Whether the 6 hr removal should apply to all alert types is a question for the operator, not an assumption.
- `Trio/Sources/Models/GlucoseAlerts/GlucoseAlertType.swift` (`.carbsRequired`, title "Carbs Required") and `Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift` (the `.carbsRequired` case builds the notification content: where the glucose value and category id get set).
- `Trio Watch App Extension/Helper/WatchNotificationHandler.swift`: registers categories on the watch and forwards snooze actions to the phone over WatchConnectivity (`WatchMessageKeys.snoozeDuration`). The watch must register the new category and forward the log-carbs action too, otherwise the watch shows different buttons or the tap does nothing.
- Phone-side response handling: `UserNotificationsManager.userNotificationCenter(_:didReceive:)` resolves `NotificationResponseAction` from `actionIdentifier`; the log-carbs action needs its own handling path there.

## Design points to settle before implementing

- **The carb amount must travel with the notification**, in `userInfo`, not be re-read from the latest determination when the button is tapped: carbsReq can change between delivery and tap, and the user should log exactly the number they were shown.
- **Logging carbs feeds dosing.** A carb entry changes COB and the next determination (SMB/UAM behaviour), so a one-tap action from a lock screen or wrist is a dosing-adjacent input. Decide whether the action needs `.authenticationRequired` and/or `.foreground`, whether a duplicate-tap guard is needed (the alert can re-fire and the watch and phone can both deliver it), and that the entry goes through the same carb-storage path as the Add Carbs screen (no new write path). This does not touch insulin-dosing code itself, but the operator should sign off on the action's safety options.
- The watch tap should write the carbs through the phone (WatchConnectivity, the same way snooze does) and should report failure to the user if the phone is unreachable rather than silently dropping it.
- Button title is localized, includes the grams ("Log 26 g"), and the action is the first in the list.
