+++
uid = "01a155c1-82b8-7196-8004-2af722fe77b0"
key = "TRIO-088"
title = "G7SensorKit PR B: no-op telemetry seam"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "019f8141-e117-77db-9216-aacaa57468d7#AC-2"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["upstream", "g7sensorkit"]
parent = "019f8141-e117-77db-9216-aacaa57468d7"
after = ["01a155c1-5685-7338-bf67-396ffaddcbea"]

[[acceptance]]
id = "AC-1"
text = "G7SensorKit PR B (no-op telemetry seam) opened upstream"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-19
moved_from = "019f8141-e117-77db-9216-aacaa57468d7#AC-2"
+++

Moved from TRIO-021 AC-2: G7SensorKit PR B (no-op telemetry seam) opened upstream

Reason: TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR


## Intent

Second G7SensorKit PR, after PR A: a no-op telemetry seam, so the fork's logging hooks can live upstream without changing behaviour. The plan is in `docs/in-progress/upstream-pr-packaging/01-g7sensorkit-pr-plan.md`. Part of the TRIO-021 project.
