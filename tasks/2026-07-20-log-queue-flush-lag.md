+++
uid = "019f8141-e117-77db-9216-aad634eed8db"
key = "TRIO-012"
title = "Log queue flush lag per complication delivery"
status = "review"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L163"
created = 2026-07-20
updated = 2026-10-19
touched = 2026-10-19
owner = "me"
tags = ["complication-freshness", "observability"]
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"

[[acceptance]]
id = "AC-1"
text = "`queue_flush_lag_seconds` field added to `complication_did_receive_user_info` log line"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "7d45514f5 — queue_flush_lag_seconds on complication_did_receive_user_info (feature/watch-g7); patch 09 regenerated via mid-stack-update, stack PASSED; codex-work review PASS 0d4a6893"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:27+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[sessions]]
host = "claude-code"
ref = "730d23fc-7303-4bc8-924a-d37da046a25d"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:22:10+00:00"

[[reviews]]
run_id = "0d4a6893-ce2d-436b-9cfe-3fdbf983d6ed"
model_family = "codex"
verdict = "pass"
reviewed_commit = "73372979f6cd99a226d3ad221ac2db2b6129dcb1"
reviewed_paths = ["Trio Watch App Extension/WatchState.swift"]
recorded_at = "2026-10-19T19:31:47+00:00"
+++

## Intent

Add `queue_flush_lag_seconds` to the existing `complication_did_receive_user_info` log line — a
direct per-delivery WC queue dwell-time measurement, one-liner.

## Change (2026-10-19)

On the watch, `WatchState` now records the wall clock as soon as a userInfo transfer arrives. It subtracts the phone's `transferEnqueuedAt` stamp, which is already sent in the payload. The result goes on the `complication_did_receive_user_info` line as `queue_flush_lag_seconds`, or `-1` when the stamp is missing. That is how long WatchConnectivity held the transfer before delivering it. Lines from different builds can now be compared on queue dwell time without reconstructing it from phone-side and watch-side logs. Commit 7d45514f5 on `feature/watch-g7`, carried in patch 09.

## Notes carried over from acceptance criteria
