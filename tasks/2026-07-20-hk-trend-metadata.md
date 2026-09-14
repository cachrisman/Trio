+++
uid = "019f8141-e117-77db-9216-aad36bc5e71b"
key = "TRIO-010"
title = "Add HK trend metadata to iPhone glucose writes"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L150"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness", "healthkit"]
+++

## Intent

Add `"com.trio.trend": glucoseSample.direction?.rawValue ?? ""` to HealthKit metadata in
`uploadGlucose(_:)`. Eliminates a transient trend regression (`""` overwriting real trend) during
dual-delivery normal operation. Specced in
`docs/in-progress/complication-freshness/alternative-delivery/alternative-delivery-design.md` §R6.

## Acceptance criteria

- [ ] `uploadGlucose(_:)` includes `com.trio.trend` metadata key on every HK write
- [ ] Verify HealthKit consumer apps before shipping (per doc note)
- [ ] No regression to existing HK trend consumers
