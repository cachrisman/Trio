+++
uid = "019f8141-e117-77db-9216-aace7a5c2905"
key = "TRIO-024"
title = "Investigate watch-to-phone EGV backfill for phone-missed readings"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/backlog/watch-to-phone-reading-backfill/watch-to-phone-reading-backfill.md#L3"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["watch", "g7"]
+++

## Intent

With the watch running direct G7 BLE, the watch has picked up 1-2 EGV readings the phone missed
(phone had a gap the watch did not). Today this is one-directional — the phone is the sole source
of truth. Investigate what it would take to sync watch-legitimate readings back to the phone
(loop/treatment store, Nightscout, charts) when the phone has a genuine gap. Evidence window logged
for a concrete example: 2026-06-19T12:49:39Z–13:19:39Z UTC (pull from BetterStack).

## Acceptance criteria

- [ ] Resolve dedup/ordering: merge on sensor reading timestamp, not receipt time
- [ ] Define trust model: only backfill genuine phone gaps, never let watch override/race phone's own readings
- [ ] Decide transport: reuse existing watch-phone messaging vs. dedicated backfill channel
- [ ] Decide effect on loop: does a backfilled reading re-trigger a loop cycle, or is it display/log-only
- [ ] Sequence deliberately against watch-messaging-centralization (see that task's body) — don't let a new ad hoc payload family land mid-refactor
