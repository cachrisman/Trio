+++
uid = "019f8141-e117-77db-9216-aad2b129f19e"
key = "TRIO-018"
title = "Post-dead-zone recovery: request refresh after stall drain"
status = "blocked"
kind = "code"
blocked_by = "019f8141-e117-77db-9216-aad18fed48dd"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L148"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness", "watch"]
+++

## Intent

In `didFinishUserInfoTransfer`'s success path, check staleness of `lastDataReceivedAt`; if still
stale, send `requestWatchUpdate`. Addresses the 66-minute dead-zone recovery gap observed
2026-03-17. This is Phase F of the proactive-transfer implementation plan
(`docs/in-progress/complication-freshness/proactive-transfer/proactive-transfer-02-implementation-plan.md`
§7.1/§12) — explicitly gated behind Phases A-E of `proactive-transfer-foreground-sync` shipping and
passing the Phase F gate.

## Acceptance criteria

- [ ] `proactive-transfer-foreground-sync` (Phases A-E) shipped and its Phase F gate passed
- [ ] `didFinishUserInfoTransfer` success path checks `lastDataReceivedAt` staleness
- [ ] If still stale, sends `requestWatchUpdate`
- [ ] 66-minute dead-zone-class gap no longer requires manual recovery
