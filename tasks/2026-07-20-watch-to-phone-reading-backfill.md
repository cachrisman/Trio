+++
uid = "019f8141-e117-77db-9216-aace7a5c2905"
key = "TRIO-024"
title = "Investigate watch-to-phone EGV backfill for phone-missed readings"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/backlog/watch-to-phone-reading-backfill/watch-to-phone-reading-backfill.md#L3"
created = 2026-07-20
updated = 2026-10-16
touched = 2026-10-16
owner = "me"
tags = ["watch", "g7"]

[[acceptance]]
id = "AC-1"
text = "Resolve dedup/ordering: merge on sensor reading timestamp, not receipt time"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Define trust model: only backfill genuine phone gaps, never let watch override/race phone's own readings"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Decide transport: reuse existing watch-phone messaging vs. dedicated backfill channel"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Decide effect on loop: does a backfilled reading re-trigger a loop cycle, or is it display/log-only"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Sequence deliberately against watch-messaging-centralization (see that task's body) — don't let a new ad hoc payload family land mid-refactor"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

With the watch running direct G7 BLE, the watch has picked up 1-2 EGV readings the phone missed
(phone had a gap the watch did not). Today this is one-directional — the phone is the sole source
of truth. Investigate what it would take to sync watch-legitimate readings back to the phone
(loop/treatment store, Nightscout, charts) when the phone has a genuine gap. Evidence window logged
for a concrete example: 2026-06-19T12:49:39Z–13:19:39Z UTC (pull from BetterStack).

**Evidence update 2026-10-16 (side session 2332fe6b).** Still happening, measured over 8 days of BetterStack against raw Nightscout. The watch received 28 backfill records. 5 of them are readings the phone never got: Nightscout holds them only as Dexcom Share gap-fills. The watch now keeps backfill in its own history (`WatchGlucoseHistoryStore` logs `build205_w_history_insert source=backfill appended=1 deduped=2`) but never sends it to the phone. That is about 0.6 readings a day, and Share already covers all of them, so this stays low value while TRIO-074's Nightscout pull is in place. It matters only when Share is unavailable.

## Notes carried over from acceptance criteria
