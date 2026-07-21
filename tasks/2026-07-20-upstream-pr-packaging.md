+++
uid = "019f8141-e117-77db-9216-aacaa57468d7"
key = "TRIO-021"
title = "Package G7SensorKit + Trio watch work as upstream PRs"
status = "in-progress"
kind = "code"
source = "human"
source_ref = "docs/backlog/upstream-pr-packaging/README.md#L1"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["upstream", "g7sensorkit"]
+++

## Intent

Package the watch G7 direct-BLE work and G7SensorKit fork fixes as upstream PRs. This is a
dependency chain: G7SensorKit must land upstream (LoopKit) before the Trio watch PR can open (a
public Trio PR can't repoint the submodule at the personal fork). Sequence: G7SensorKit A (watchOS
support) → B (no-op telemetry seam) → C (verifiable thread-safety/reliability fixes — the
credibility PR) → D (behavioral changes, issue-first); then the Trio watch minimal-core cut
(~2,300–2,600 lines). Full phase plans: `docs/in-progress/upstream-pr-packaging/01-g7sensorkit-pr-plan.md`
and `02-trio-watch-pr-plan.md`.

Verified 2026-07-20 via `gh api`: no PR has been filed yet to `nightscout/Trio` or
`LoopKit/G7SensorKit` from this fork's owner — "in progress" refers to prep/staging work, not a
submitted PR awaiting review.

## Acceptance criteria

- [ ] G7SensorKit PR A (watchOS support) opened upstream
- [ ] G7SensorKit PR B (no-op telemetry seam) opened upstream
- [ ] G7SensorKit PR C (thread-safety/reliability fixes, incl. the build-209 `Data.swift` bounded-read fix) opened upstream
- [ ] Trio watch minimal-core PR opened upstream (after G7SensorKit PRs land)
