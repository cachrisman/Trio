+++
uid = "01a162c4-a774-76ed-b7d7-23de5830ba27"
key = "TRIO-092"
title = "Carbs Required notification: show current glucose, drop 6 hr snooze, add one-tap carb log (phone + watch)"
status = "review"
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
state = "met"
added_at = 2026-10-22
evidence_kind = "commit"
evidence = "e446c7d6b — GlucoseAlertCoordinator caches the latest reading on evaluationQueue (also when the CGM app owns glucose alerts); carbsRequiredBody appends 'Glucose <value> <trend>' in user units when the reading is under 12 min old. The watch shows the phone-delivered notification. codex-work terra reviews 20261028-225317 (fail), -230239 (fail), -230559 (pass)"
met_at = 2026-10-28
met_ts = "2026-10-28T23:11:47+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-2"
text = "Carbs Required notification no longer offers Snooze 6 hrs on iPhone or watch; other alert types keep their current snooze list unless the operator decides otherwise"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-22
evidence_kind = "commit"
evidence = "e446c7d6b — new category Trio.alert.carbsRequired = [Log Carbs, Snooze 15m, 1h, 3h], registered on phone and watch; shared Trio.alert category unchanged (test covers both). codex-work terra reviews 20261028-225317 (fail), -230239 (fail), -230559 (pass)"
met_at = 2026-10-28
met_ts = "2026-10-28T23:11:47+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-3"
text = "Carbs Required notification has a first action 'Log Carbs' (static title; operator chose option A 2026-10-28) that logs the grams carried in the notification userInfo (the amount shown in the body) through the existing carb-storage path"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-22
evidence_kind = "commit"
evidence = "e446c7d6b — static 'Log Carbs' first action (.authenticationRequired, background); CarbsRequiredLogHandler logs the whole-gram amount from userInfo via carbsStorage.makeCarbEntry + storeCarbs(areFetchedFromRemote:false) + apsManager.determineBasalSync(), the Add Carbs path; refuses above Max Carbs. No bolus. codex-work terra reviews 20261028-225317 (fail), -230239 (fail), -230559 (pass)"
met_at = 2026-10-28
met_ts = "2026-10-28T23:11:48+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-4"
text = "Watch registers the carbs-required category and forwards the log-carbs action to the phone; failure to reach the phone is surfaced, not dropped"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-22
evidence_kind = "commit"
evidence = "e446c7d6b — WatchNotificationHandler registers the category and forwards the action with a reply handler; phone answers through a one-line hook in patch 05's reply-handler WCSession method. Unreachable / failed / alreadyLogged / exceedsMaxCarbs are surfaced as watch notifications. codex-work terra reviews 20261028-225317 (fail), -230239 (fail), -230559 (pass)"
met_at = 2026-10-28
met_ts = "2026-10-28T23:11:48+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-5"
text = "Unit tests cover the new category's action list/order and the log-carbs response handler (amount from userInfo, no double-log on repeated tap)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-22
evidence_kind = "commit"
evidence = "e446c7d6b — TrioTests/GlucoseAlertCoordinatorTests.swift CarbsRequiredNotification suite: category actions and order, shared category unchanged, amount from userInfo, repeat and concurrent dedup, zero/missing/fractional grams, above and equal to Max Carbs. Written and reviewed, NOT executed: no test run in this session."
met_at = 2026-10-28
met_ts = "2026-10-28T23:11:48+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-6"
text = "Operator decides the log-carbs action's safety options (authenticationRequired/foreground, duplicate guard) before implementation"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-22
evidence_kind = "operator"
evidence = "Operator in chat 2026-10-28: 'All Approved' to the proposed defaults: (1) iPhone 'Log N g' action is .authenticationRequired, runs in background (no .foreground); (2) watch tap forwards to the phone, which logs via the existing Add Carbs storage path, and the watch reports failure if the phone is unreachable; (3) per-alert duplicate guard: alert id + grams in userInfo, a second log for the same alert from either device is ignored and reported as already logged; (4) Snooze 6 hrs removed only from Carbs Required; (5) glucose value + trend arrow at alert time, in user units, in the notification text."
met_at = 2026-10-28
met_ts = "2026-10-28T22:39:50+01:00"
met_by = "charlie"
met_commit = "a4d59e0e4414dee795e7f6045ad2f97c6565df9e"

[[acceptance]]
id = "AC-7"
text = "On device: a real Carbs Required alert on iPhone and watch shows glucose, has Log Carbs at top and no 6 hr snooze, and tapping Log Carbs records the carbs"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-22

[[sessions]]
host = "claude-code"
ref = "b6e3304b-5e17-4b3f-ae69-ab16fddc8c9d"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:52:48+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "2b9b0383-08bc-45d0-91ac-8af63a5423af"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T22:00:16+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "20261028-231000-direct-e446c7d6b"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T22:10:02+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "20261028-232000-direct-69ead802b"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T22:18:22+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[reviews]]
run_id = "fe86c2ad-d3d9-446b-b6dd-b26f4a541cf0"
model_family = "codex"
verdict = "fail"
reviewed_commit = "6737274a9e432e76599fc24e2fe2c52775391092"
reviewed_paths = ["Trio/Sources/Models/NotificationIdentifiers.swift", "Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift", "Trio/Sources/Services/Alerts/TrioUserNotificationAlertScheduler.swift", "Trio/Sources/Services/UserNotifications/UserNotificationsManager.swift", "Trio Watch App Extension/Helper/WatchNotificationHandler.swift", "Trio/Sources/Models/WatchMessageKeys.swift", "Trio/Sources/Services/WatchManager/AppleWatchManager.swift", "TrioTests/GlucoseAlertCoordinatorTests.swift"]
recorded_at = "2026-10-28T22:05:45+00:00"

[[reviews]]
run_id = "e300a34b-1322-49f9-a788-ebfb7b25c1c7"
model_family = "codex"
verdict = "fail"
reviewed_commit = "08686d4ddcaae37bdbfcadc07c336f0e23c16e7e"
reviewed_paths = ["Trio Watch App Extension/Helper/WatchNotificationHandler.swift", "Trio/Sources/Models/NotificationIdentifiers.swift", "Trio/Sources/Models/WatchMessageKeys.swift", "Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift", "Trio/Sources/Services/Alerts/TrioUserNotificationAlertScheduler.swift", "Trio/Sources/Services/UserNotifications/UserNotificationsManager.swift", "Trio/Sources/Services/WatchManager/AppleWatchManager.swift", "TrioTests/GlucoseAlertCoordinatorTests.swift"]
recorded_at = "2026-10-28T22:05:47+00:00"

[[reviews]]
run_id = "12b675be-4db5-4605-8702-a8c4c02a7760"
model_family = "codex"
verdict = "pass"
reviewed_commit = "08686d4ddcaae37bdbfcadc07c336f0e23c16e7e"
reviewed_paths = ["Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift"]
recorded_at = "2026-10-28T22:06:34+00:00"
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

## Decisions (2026-10-28)

**AC-6:** the operator approved all five proposed defaults ("All Approved"):
- the iPhone action is `.authenticationRequired` and runs in the background;
- the watch forwards to the phone and reports failure;
- a per-alert duplicate guard;
- Snooze 6 hrs is removed only from Carbs Required;
- the glucose value and trend are shown as of the alert.

**Button title (decided 2026-10-28, option A):** `UNNotificationAction` titles are fixed per registered category, and the watch must register the same category ids. A per-alert "Log 26 g" therefore needs either a static title ("Log Carbs", with the grams in the body), or per-amount categories pre-registered on both devices (1–150 g, generic fallback above). The operator chose the static "Log Carbs" title, with the grams and glucose in the body ("1. a").

## Release note

Carbs Required alerts now show your current glucose and trend, and offer Log Carbs as the first action on iPhone and Apple Watch: one tap logs the amount shown in the alert, after Face ID or passcode on iPhone. Snooze 6 hrs is gone from this alert only. Each alert can be logged once; an amount above your Max Carbs is refused and you are asked to log in Trio.
