+++
uid = "01a1bd22-8b79-72ec-bfa1-ea38fe4437d7"
key = "TRIO-112"
title = "Watch G7: feasibility memo for direct read on the watch (Trio authenticates in the watch slot)"
status = "done"
kind = "docs"
source = "agent-start"
source_ref = "docs/in-progress/watch-g7-egv-capture/plan.md#W6"
created = 2026-11-08
updated = 2026-11-10
touched = 2026-11-10
closed = 2026-11-10
first_closed = 2026-11-10
accepted_by = "charlie"
accepted_at = 2026-11-10
accepted_ts = "2026-11-10T23:18:20+01:00"
tags = ["watch", "g7"]
parent = "01a1bd22-5e52-7284-a2e3-3b06fed3e6d9"
priority = 2

[[acceptance]]
id = "AC-1"
text = "Feasibility memo in docs/in-progress/watch-g7-egv-capture/ from the template: Trio-side gaps verified in code, phone eavesdrop + watch direct coexistence, phone-side effect of removing the Dexcom watch app, credential handling, experiment design with a link_summary success measure"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "note"
evidence = "docs/in-progress/watch-g7-egv-capture/direct-read-feasibility.md"
met_at = 2026-11-09
met_ts = "2026-11-09T06:32:06+01:00"
met_by = "claude-code"
met_commit = "cb42d9fa46a907f1d2241559cc53247dbb8a3e5c"

[[acceptance]]
id = "AC-2"
text = "Operator decision on removing the Dexcom watch app for direct read (plan Q4)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "operator"
evidence = "Operator in chat 2026-11-08, on plan Q4 (losing the Dexcom watch app): \"That's fine with me.\""
met_at = 2026-11-08
met_ts = "2026-11-08T23:08:42+01:00"
met_by = "charlie"
met_commit = "cb42d9fa46a907f1d2241559cc53247dbb8a3e5c"

[[sessions]]
host = "claude-code"
ref = "20261109-direct-feasibility-memo"
model_family = "claude"
started = 2026-11-09
role = "author"
started_at = "2026-11-09T05:32:04+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"
+++

## Intent

Plan docs/in-progress/watch-g7-egv-capture/plan.md W6. The only change that removes C5 (13-17% of links) at the root. Upstream G7SensorKit#80 and Loop#2605 do it; build 238 already contains upstream Trio's phone Direct mode (#1548, 1f1908034 is an ancestor of 81d7886); Trio lacks the supportsWatchDirectRead host hook (grep-level). Costs: the Dexcom watch app must go (same watch slot), pairing code per sensor, a credential on the watch, untested watchOS background EC-JPAKE here. Output a feasibility memo from docs/templates/feasibility-memo-template.md; no implementation until the operator decides plan Q4.
