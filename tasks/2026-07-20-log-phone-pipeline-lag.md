+++
uid = "019f8141-e117-77db-9216-aad7247b9ad2"
key = "TRIO-011"
title = "Log phone-side HK-write-to-transfer pipeline lag"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L164"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness", "observability"]
+++

## Intent

Add `hk_write_epoch_seconds` to the existing transfer log line — measures phone-side HK write →
heartbeat → transfer latency, currently invisible.

## Acceptance criteria

- [ ] `hk_write_epoch_seconds` field added to the transfer log line
