+++
uid = "019f8141-e117-77db-9216-aae2fdc2f958"
key = "TRIO-009"
title = "Revisit: haptic beacon for G7 BLE EGV cadence (built then reverted)"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md#L3"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["watch", "g7", "revisit"]
+++

## Intent

A cadence-aware haptic beacon for the G7 BLE EGV cycle (multi-source with BLE precedence, dedup,
staleness-gated rearm) was implemented across Cuts 1-4 + R2-R8 review passes on 2026-05-11, but was
then deliberately deleted twelve days later (`4f512547d`/`3a394e717`, 2026-05-23: "Deletes
HapticBeacon.swift and the call sites... G7 BLE observer and telemetry wiring remain intact"). No
branch currently contains `HapticBeacon.swift`, and the docs
(`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`, `-impl-log.md`) were never updated
after the removal — they still describe it as "implemented in worktree, awaiting on-device
verification." The reason for the revert was not found in the commit message or these docs. This
task exists to revisit the idea if wanted, not to imply the old work is ready to resume as-is.

## Acceptance criteria

- [ ] Determine why the 2026-05-23 revert happened (ask Charlie / check for context outside these docs)
- [ ] Decide: re-land the reverted implementation, redesign, or drop permanently
- [ ] If re-landing: re-verify the old Cut 1-4 + R2-R8 design against current `G7WatchSensorAdapter.swift`/`WatchState.swift` (grown since May)
