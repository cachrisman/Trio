+++
uid = "019f8141-e117-77db-9216-aadd79cb455d"
key = "TRIO-002"
title = "Investigate WKApplicationRefreshBackgroundTask feasibility for watch"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L184"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "watch", "future-work"]

[[acceptance]]
id = "AC-1"
text = "Feasibility assessment of `WKApplicationRefreshBackgroundTask` as a fallback pull trigger"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Decision recorded: pursue, defer further, or reject"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Investigate a scheduled wake-up to proactively pull data from the phone when all delivery channels
(WCSession, HK observer, applicationContext) have gone silent. The App Group is written by the
watch app process, so "check for fresh data already in App Group" is not the use case — the value
is a fallback pull trigger when no push has arrived. Heavier and more speculative than the R4/R5d
follow-ups; explicitly deferred until product priority.

## Notes carried over from acceptance criteria
