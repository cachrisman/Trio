+++
uid = "019f8141-e117-77db-9216-aadba8bc7c56"
key = "TRIO-020"
title = "Add staleness visual indicator to circular complication"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L177"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness", "ux"]
+++

## Intent

Apply green/yellow/red recency color to glucose text in `TrioAccessoryCircularView`. The
corner-complication view already has this; the circular face has no age signal, and p90 `data_age`
runs 510s.

## Acceptance criteria

- [ ] `TrioAccessoryCircularView` glucose text colored by recency (green/yellow/red), matching corner view's existing scheme
