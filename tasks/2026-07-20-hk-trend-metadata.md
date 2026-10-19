+++
uid = "019f8141-e117-77db-9216-aad36bc5e71b"
key = "TRIO-010"
title = "Add HK trend metadata to iPhone glucose writes"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L150"
created = 2026-07-20
updated = 2026-10-19
touched = 2026-10-19
owner = "me"
tags = ["complication-freshness", "healthkit"]

[[acceptance]]
id = "AC-1"
text = "`uploadGlucose(_:)` includes `com.trio.trend` metadata key on every HK write"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Verify HealthKit consumer apps before shipping (per doc note)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "No regression to existing HK trend consumers"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Add `"com.trio.trend": glucoseSample.direction?.rawValue ?? ""` to HealthKit metadata in
`uploadGlucose(_:)`. Eliminates a transient trend regression (`""` overwriting real trend) during
dual-delivery normal operation. Specced in
`docs/in-progress/complication-freshness/alternative-delivery/alternative-delivery-design.md` §R6.

## Notes carried over from acceptance criteria


## Deferred (2026-10-19)

Parked in backlog. The design doc says to defer this unless the watch's delta-derived trend arrow proves unreliable. The operator hasn't seen the watch arrow disagree with Dexcom's (2026-10-19), and a mismatch only lasts until the next WatchConnectivity update. Shipping it needs a new upstream HealthKit patch and a reader change in patch 09, and it has to be checked against Tidepool and other HealthKit consumers. Reopen it if the arrow is seen disagreeing.
