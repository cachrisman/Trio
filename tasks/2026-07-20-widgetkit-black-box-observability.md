+++
uid = "019f8141-e117-77db-9216-aada363de9c8"
key = "TRIO-026"
title = "Improve WidgetKit reload dispatch-to-callback observability"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L167"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "observability"]

[[acceptance]]
id = "AC-1"
text = "Design a correlation mechanism between reload-dispatch generation and `getTimeline` invocation"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Re-measure the ~45% uncorrelated-dispatch rate after instrumentation lands"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Local reload management is well-instrumented (`coalescedReloadOnMain` logs debounce, trigger, retry
skip/cancel), but the blind spot is after dispatch: whether `WidgetCenter.reloadTimelines()`
actually caused WidgetKit to call `getTimeline`, or was silently dropped/deferred. A 2026-03-19
investigation found ~45% of logged reload dispatches were not followed by a corresponding
`getTimeline` callback in a sampled 48h window (see `docs/investigations/`). Improve correlation
between reload generation and `getTimeline` invocation to distinguish "fresh snapshot, stale UI"
from "reload silently ignored by platform."

## Notes carried over from acceptance criteria
