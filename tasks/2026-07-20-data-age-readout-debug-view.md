+++
uid = "019f8141-e117-77db-9216-aadc9e9985c8"
key = "TRIO-004"
title = "Add data-age readout to watch debug view"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L178"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "ux"]

[[acceptance]]
id = "AC-1"
text = "Debug view shows \"Last updated Xs ago\" backed by `lastDataReceivedAt`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

"Last updated Xs ago" backed by `lastDataReceivedAt`, shown in the debug screen — handy for
on-device validation after R5d without requiring a BetterStack round-trip.

## Notes carried over from acceptance criteria
