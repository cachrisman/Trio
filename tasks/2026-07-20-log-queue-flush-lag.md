+++
uid = "019f8141-e117-77db-9216-aad634eed8db"
key = "TRIO-012"
title = "Log queue flush lag per complication delivery"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L163"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "observability"]

[[acceptance]]
id = "AC-1"
text = "`queue_flush_lag_seconds` field added to `complication_did_receive_user_info` log line"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Add `queue_flush_lag_seconds` to the existing `complication_did_receive_user_info` log line — a
direct per-delivery WC queue dwell-time measurement, one-liner.

## Notes carried over from acceptance criteria
