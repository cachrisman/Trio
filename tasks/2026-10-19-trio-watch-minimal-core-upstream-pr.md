+++
uid = "01a155c1-84bc-73c3-bcea-4331eb2161a6"
key = "TRIO-090"
title = "Trio watch minimal-core upstream PR"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "019f8141-e117-77db-9216-aacaa57468d7#AC-4"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["upstream", "g7sensorkit"]
parent = "019f8141-e117-77db-9216-aacaa57468d7"
depends_on = ["01a155c1-5685-7338-bf67-396ffaddcbea", "01a155c1-82b8-7196-8004-2af722fe77b0", "01a155c1-83c3-72af-8752-069054169259"]

[[acceptance]]
id = "AC-1"
text = "Trio watch minimal-core PR opened upstream (after G7SensorKit PRs land)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-19
moved_from = "019f8141-e117-77db-9216-aacaa57468d7#AC-4"
+++

Moved from TRIO-021 AC-4: Trio watch minimal-core PR opened upstream (after G7SensorKit PRs land)

Reason: TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR


## Intent

The Trio watch minimal-core PR to nightscout/Trio (about 2,300 to 2,600 lines). It can only open after the G7SensorKit PRs land, because a public Trio PR can't point the submodule at the personal fork. The plan is in `docs/in-progress/upstream-pr-packaging/02-trio-watch-pr-plan.md`. Part of the TRIO-021 project.
