+++
uid = "01a1bd22-6fd9-75aa-9a2c-2f2abc9c9834"
key = "TRIO-108"
title = "Watch G7: re-anchor the extended runtime session on every app open older than ~10-15 min (sessionReanchorAge 40 min today)"
status = "dropped"
kind = "code"
source = "agent-start"
source_ref = "docs/in-progress/watch-g7-egv-capture/plan.md#W2"
created = 2026-11-08
updated = 2026-11-08
touched = 2026-11-08
closed = 2026-11-08
first_closed = 2026-11-08
tags = ["watch", "g7"]
parent = "01a1bd22-5e52-7284-a2e3-3b06fed3e6d9"
priority = 2
after = ["01a1bd22-5fa8-7543-ba29-95050bc3f332"]

[[acceptance]]
id = "AC-1"
text = "sessionReanchorAge lowered to 10-15 min (value and rationale in the commit); re-anchor gap stays instrumented"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-2"
text = "patch-test.sh clean and full diff vs base reviewed"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-3"
text = ">=2-day soak on one sensor: session coverage and live rate per ext_session_active stratum reported against the TRIO-106 baseline"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-11-08
+++

## Intent

Plan docs/in-progress/watch-g7-egv-capture/plan.md W2. Session running: 61/62 links read; no session: 28/55 (build 238, Nov 8). Coverage was ~5.8 of 10.3 h; each lapse was a normal ~60-min expiry with no app open after it. Opens at session ages 7-55 min bought nothing because re-anchor needs age >= 40 min (adapter G7WatchSensorAdapter.swift:71). Lower it to ~10-15 min so each open buys a fresh hour; cost is the instrumented 200 ms re-anchor gap. The same split was seen in builds 210-212 (BUG-E, 98% vs 58%), when the age went 45 -> 40. Causality is not established; W1's process context is how to tell.
