+++
uid = "019f8141-e117-77db-9216-aad44db3fe36"
key = "TRIO-001"
title = "Adaptive complication-budget throttling"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L151"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["complication-freshness"]
+++

## Intent

Dynamically increase the stale-first gate threshold T as remaining complication budget depletes,
using remaining budget, time-of-day/projected burn, and current snapshot age as inputs. Example: if
40/50 transfers are used by noon, stretch T from 600s to 900-1200s to avoid exhaustion. Extends the
budget-ok window without sacrificing early-day freshness.

## Acceptance criteria

- [ ] Design the throttling function (inputs: remaining budget, projected burn rate, snapshot age)
- [ ] Implement dynamic T adjustment in the stale-first gate
- [ ] Verify budget exhaustion rate drops without early-day freshness regression
