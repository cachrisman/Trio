+++
uid = "019f8141-e117-77db-9216-aadc9e9985c8"
key = "TRIO-004"
title = "Add data-age readout to watch debug view"
status = "review"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L178"
created = 2026-07-20
updated = 2026-10-16
touched = 2026-10-16
owner = "me"
tags = ["complication-freshness", "ux"]
parent = "01a14459-1abb-73ba-9248-679079504c8e"

[[acceptance]]
id = "AC-1"
text = "Debug view shows \"Last updated Xs ago\" backed by `lastDataReceivedAt`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "a679782ba — WatchDiagnosticsView adds a 'Last data:' row (label differs from the AC's 'Last updated' wording) showing 'Ns ago' / 'Nm Ns ago' / 'Nh Nm ago' from dataStore.lastDataReceivedAt(), age-coloured; carried in patches/09-watch-g7.patch, patch-test passed"
met_at = 2026-10-16
met_ts = "2026-10-16T13:54:00+02:00"
met_by = "unknown"
met_commit = "8f192f13f3e66a4662cd8894db3e33c0e49be9d8"

[[acceptance]]
id = "AC-2"
text = "Shown on the watch: the Diagnostics row updates live and matches the time since the last phone update"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-16

[[sessions]]
host = "claude-code"
ref = "94939997-a781-4ec9-bacc-7f59c2ad834f"
model_family = "cursor"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T00:00:00+00:00"

[[sessions]]
host = "claude-code"
ref = "20261016-140000-direct-a679782ba"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T11:51:43+00:00"

[[reviews]]
run_id = "f7814326-0e47-4ae3-9af4-edb79212b50e"
model_family = "codex"
verdict = "pass"
reviewed_commit = "9523b7a2630005d6040ad295a98b23daf0cb1c1a"
reviewed_paths = ["Trio Watch App Extension/WatchState.swift"]
recorded_at = "2026-10-16T11:50:20+00:00"
+++

## Intent

"Last updated Xs ago" backed by `lastDataReceivedAt`, shown in the debug screen — handy for
on-device validation after R5d without requiring a BetterStack round-trip.

## Notes carried over from acceptance criteria

## What shipped

Commit a679782ba on feature/watch-g7, carried in patches/09-watch-g7.patch for build 232 (TRIO-076). The watch Diagnostics screen gets a "Last data:" row under "Last reload:". It shows how long ago the phone last delivered data (`dataStore.lastDataReceivedAt()`), as "42s ago", "3m 5s ago" or "1h 12m ago", coloured with the same age colours as the rows around it, and "—" when nothing has arrived yet. A timestamp in the future clamps to 0s rather than showing a negative age. The row is read-only and changes no data flow. Operator check after install (AC-2): open Diagnostics on the watch and confirm the row ticks up live and resets when the phone pushes an update.

## Release note

Watch: the Diagnostics screen now shows how long ago the watch last received data from the phone.
