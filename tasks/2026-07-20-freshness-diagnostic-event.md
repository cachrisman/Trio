+++
uid = "019f8141-e117-77db-9216-aad9a23adcb6"
key = "TRIO-008"
title = "Add synthesized freshness-state diagnostic log event"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L166"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "observability"]

[[acceptance]]
id = "AC-1"
text = "New roll-up log event emitted at snapshot save and/or reload time"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Includes source, reading_epoch, receive lag, snapshot age, reload age, queue depth, remaining budget, replaced-older-data flag"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Add one roll-up event at snapshot save and/or reload time with: source, `reading_epoch`, receive
lag, snapshot age, reload age, queue depth, remaining complication budget, and whether the new
snapshot replaced older data. Makes transport vs. WidgetKit debugging much faster than correlating
narrow logs.

## Notes carried over from acceptance criteria
