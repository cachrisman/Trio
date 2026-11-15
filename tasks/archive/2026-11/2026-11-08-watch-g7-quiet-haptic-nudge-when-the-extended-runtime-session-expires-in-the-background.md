+++
uid = "01a1bd22-7871-761d-ad2a-cdea908232e1"
key = "TRIO-109"
title = "Watch G7: quiet haptic nudge when the extended runtime session expires in the background"
status = "dropped"
kind = "code"
source = "agent-start"
source_ref = "docs/in-progress/watch-g7-egv-capture/plan.md#W3"
created = 2026-11-08
updated = 2026-11-08
touched = 2026-11-08
closed = 2026-11-08
first_closed = 2026-11-08
tags = ["watch", "g7"]
parent = "01a1bd22-5e52-7284-a2e3-3b06fed3e6d9"
priority = 3

[[acceptance]]
id = "AC-1"
text = "Reason for the 2026-05 HapticBeacon revert found (or recorded as not findable) before any code"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-2"
text = "Operator approves the nudge and its hours"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-3"
text = "Nudge fires at most once per background session expiry, respects the approved hours, and is logged"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08
+++

## Intent

Plan docs/in-progress/watch-g7-egv-capture/plan.md W3. When the session lapses in the background nothing tells the wearer; a rate-limited quiet notification would prompt the open that restarts it. Insertion point: adapter extendedRuntimeSession(_:didInvalidateWith:), WatchNotificationHandler.shared. Before building: find why the 2026-05 HapticBeacon was reverted (TRIO-009 records no reason), and get the operator's hours (plan Q3). Only if W2 shows the session effect is causal.
