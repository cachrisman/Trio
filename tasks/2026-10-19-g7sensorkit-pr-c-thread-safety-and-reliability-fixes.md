+++
uid = "01a155c1-83c3-72af-8752-069054169259"
key = "TRIO-089"
title = "G7SensorKit PR C: thread-safety and reliability fixes"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "019f8141-e117-77db-9216-aacaa57468d7#AC-3"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["upstream", "g7sensorkit"]
parent = "019f8141-e117-77db-9216-aacaa57468d7"
after = ["01a155c1-82b8-7196-8004-2af722fe77b0"]

[[acceptance]]
id = "AC-1"
text = "G7SensorKit PR C (thread-safety/reliability fixes, incl. the build-209 `Data.swift` bounded-read fix) opened upstream"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-19
moved_from = "019f8141-e117-77db-9216-aacaa57468d7#AC-3"
+++

Moved from TRIO-021 AC-3: G7SensorKit PR C (thread-safety/reliability fixes, incl. the build-209 `Data.swift` bounded-read fix) opened upstream

Reason: TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR


## Intent

Third G7SensorKit PR, after PR B: the verifiable thread-safety and reliability fixes, including the build-209 `Data.swift` bounded-read fix. This is the credibility PR in the chain. The plan is in `docs/in-progress/upstream-pr-packaging/01-g7sensorkit-pr-plan.md`. Part of the TRIO-021 project.

PR D (behavioural changes, issue-first) comes after this one in the plan and has no task yet.
