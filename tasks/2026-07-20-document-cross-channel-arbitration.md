+++
uid = "019f8141-e117-77db-9216-aad57682beae"
key = "TRIO-006"
title = "Document cross-channel complication arbitration rules"
status = "backlog"
kind = "docs"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L157"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "documentation"]

[[acceptance]]
id = "AC-1"
text = "Short reference doc describing the `saveOnMain` arbitration rule set"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Covers `shouldUpdate` + `lastValidTimestamp` fallback behavior"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

All complication delivery channels funnel into `saveOnMain`, which applies a channel-agnostic dedup
gate: newer wins (>1s), first-writer wins within ±1s unless content differs, older always loses.
The arbitration is already implemented (`shouldUpdate` + `lastValidTimestamp` fallback) but not
documented in one place. Write a short reference doc for future contributors.

## Notes carried over from acceptance criteria
