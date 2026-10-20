+++
uid = "019f8141-e117-77db-9216-aadc9e9985c8"
key = "TRIO-004"
title = "Add data-age readout to watch debug view"
status = "done"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L178"
created = 2026-07-20
updated = 2026-10-19
touched = 2026-10-19
closed = 2026-10-19
first_closed = 2026-10-19
accepted_by = "charlie"
accepted_at = 2026-10-19
accepted_ts = "2026-10-19T21:18:12+02:00"
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
evidence = "a679782ba (feature/watch-g7) — WatchDiagnosticsView 'Last data:' row from lastDataReceivedAt; re-verified 2026-10-19: all 24 added lines present in current patches/09-watch-g7.patch, full-stack patch-test passed"
met_at = 2026-10-19
met_ts = "2026-10-19T21:16:08+02:00"
met_by = "claude-code"
met_commit = "31f8b6ff96843994b960a004a1d90bf88e3b535f"

[[acceptance]]
id = "AC-2"
text = "Shown on the watch: the Diagnostics 'Last data' row ticks up live and matches the time since the last background phone delivery (didReceiveUserInfo or didReceiveApplicationContext, the R5d lastDataReceivedAt timestamp); live sendMessage deliveries while the app is open do not reset it"
owner = "operator"
phase = "post-deploy"
state = "met"
added_at = 2026-10-16
evidence_kind = "operator"
evidence = "Verified by charlie on the board"
met_at = 2026-10-16
met_ts = "2026-10-16T20:58:23+02:00"
met_by = "charlie"
met_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"

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

[[reviews]]
run_id = "73054422-851e-4fec-baf2-3121f3f09fca"
model_family = "codex"
verdict = "pass"
reviewed_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-10-16T00:00:00+00:00"
+++

## Intent

"Last updated Xs ago" backed by `lastDataReceivedAt`, shown in the debug screen — handy for
on-device validation after R5d without requiring a BetterStack round-trip.

## Notes carried over from acceptance criteria

## What shipped

Commit a679782ba on feature/watch-g7, carried in patches/09-watch-g7.patch for build 232 (TRIO-076). The watch Diagnostics screen gets a "Last data:" row under "Last reload:". It reads the R5d sleep-gap timestamp `lastDataReceivedAt` (`dataStore.lastDataReceivedAt()`), as the original spec asked, and shows its age as "42s ago", "3m 5s ago" or "1h 12m ago", coloured with the same age colours as the rows around it, and "—" when it was never set. A timestamp in the future clamps to 0s rather than showing a negative age. The row is read-only and changes no data flow.

That timestamp is set only by background phone deliveries: `didReceiveUserInfo` (when the payload is not a duplicate of a stored reading) and `didReceiveApplicationContext`. Live `didReceiveMessage` deliveries, which the phone uses while the watch app is open, do not reset it, so with the app in the foreground the row keeps counting up even though data is arriving. That is intended: the row exists to check the sleep-gap logic on the wrist, not as a general "last phone data" indicator. The a679782ba commit message ("how long ago the last phone data arrived") overstates this.

Checked on build 232, 2026-10-16: at 20:43:17 CEST the row read "54m 20s ago"; the watch's last userInfo delivery in BetterStack was 17:48:57 UTC (19:48:57 CEST), exactly 54m 20s earlier, and the 93 deliveries after it were all live messages.

## Release note

Watch: the Diagnostics screen now shows how long ago the watch last received a background update from the phone (the timestamp the sleep-gap refresh uses). Live updates while the watch app is open don't reset it.

Shipped in build 232 (TRIO-076), TestFlight 2026-10-16.


## Review 2026-10-16 (codex, patch 09 at dev 826bf8a23)

Fresh diverse review of the TRIO-004 hunks in `patches/09-watch-g7.patch` (note `.task-relay/notes/20261016-212047-58147-codex-review.md`, run 73054422, gpt-5.6-terra high), replacing the stale feature-branch pass. Verdict NEEDS-FIX with one MEDIUM for this task: a `didReceiveUserInfo` that the pre-dispatch dedup skips returns before `lastDataReceivedAt` is set, so a re-delivered duplicate does not refresh the row. Triage: matches the spec as accepted (AC-2 defines the row as the R5d `lastDataReceivedAt` timestamp, which is assigned after that early return by design); a deduplicated duplicate carries no new data. Not a defect against this task, recorded as a pass. If the row should instead count any delivery including duplicates, that is a spec change for a new task.
