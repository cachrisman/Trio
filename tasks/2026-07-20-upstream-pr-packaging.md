+++
uid = "019f8141-e117-77db-9216-aacaa57468d7"
key = "TRIO-021"
title = "Package G7SensorKit + Trio watch work as upstream PRs"
status = "open"
kind = "project"
source = "human"
source_ref = "docs/backlog/upstream-pr-packaging/README.md#L1"
created = 2026-07-20
updated = 2026-10-19
touched = 2026-10-19
owner = "me"
tags = ["upstream", "g7sensorkit"]

[[acceptance]]
id = "AC-1"
text = "G7SensorKit PR A (watchOS support) opened upstream"
owner = "agent"
phase = "pre-review"
state = "moved"
added_at = 2026-09-26
reason = "TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR"
closed_at = 2026-10-19
closed_ts = "2026-10-19T22:01:36+02:00"
moved_to = "01a155c1-5685-7338-bf67-396ffaddcbea"

[[acceptance]]
id = "AC-2"
text = "G7SensorKit PR B (no-op telemetry seam) opened upstream"
owner = "agent"
phase = "pre-review"
state = "moved"
added_at = 2026-09-26
reason = "TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR"
closed_at = 2026-10-19
closed_ts = "2026-10-19T22:01:47+02:00"
moved_to = "01a155c1-82b8-7196-8004-2af722fe77b0"

[[acceptance]]
id = "AC-3"
text = "G7SensorKit PR C (thread-safety/reliability fixes, incl. the build-209 `Data.swift` bounded-read fix) opened upstream"
owner = "agent"
phase = "pre-review"
state = "moved"
added_at = 2026-09-26
reason = "TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR"
closed_at = 2026-10-19
closed_ts = "2026-10-19T22:01:48+02:00"
moved_to = "01a155c1-83c3-72af-8752-069054169259"

[[acceptance]]
id = "AC-4"
text = "Trio watch minimal-core PR opened upstream (after G7SensorKit PRs land)"
owner = "agent"
phase = "pre-review"
state = "moved"
added_at = 2026-09-26
reason = "TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR"
closed_at = 2026-10-19
closed_ts = "2026-10-19T22:01:48+02:00"
moved_to = "01a155c1-84bc-73c3-bcea-4331eb2161a6"

[[acceptance]]
id = "AC-5"
text = "Glucose Bobble circular complication PRs, moved from TRIO-063 (2026-09-24): upstream PR branches for patches 03 (shareable Glucose Bobble view: inside-ring arrow placement, solid ring colour) and 04 (circular complication, phone settings, watch-state fields), each cut from upstream/dev and containing only that patch's changes, with Xcode target membership in project.pbxproj for the new files: GlucoseBobbleComplicationSettings.swift (phone, watch app, complication), GlucoseBobbleComplicationSettingsView.swift (phone), GlucoseComplicationSnapshot.swift (watch app, complication), GlucoseBobbleContactView.swift and Triangle.swift (complication), plus the watch targets' App Group entitlements and AppGroupID build settings. The patches apply cleanly to upstream/dev, so the PR diffs are the patch diffs. project.pbxproj edits are the operator's."
owner = "operator"
phase = "pre-review"
state = "moved"
added_at = 2026-09-26
reason = "TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR"
closed_at = 2026-10-19
closed_ts = "2026-10-19T22:01:48+02:00"
moved_to = "01a155c1-85b6-7660-98f0-1b27baa9f8c4"
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

## Notes carried over from acceptance criteria


## Project (2026-10-19)

The operator turned this into a project on 2026-10-19. Each upstream PR now has its own task:

- TRIO-087: G7SensorKit PR A, watchOS support
- TRIO-088: G7SensorKit PR B, no-op telemetry seam (after 087)
- TRIO-089: G7SensorKit PR C, thread-safety and reliability fixes (after 088)
- TRIO-090: Trio watch minimal-core PR (depends on 087, 088 and 089 landing)
- TRIO-091: Glucose Bobble PRs for patches 03 and 04 (independent)

G7SensorKit PR D (behavioural changes, issue-first) has no task yet.
