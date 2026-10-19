+++
uid = "01a00ee7-e761-7471-8621-6c97ba0d1b43"
key = "TRIO-039"
title = "CloudLogUploader: a permanently-rejected batch stalls uploads forever (durable 4xx)"
status = "ready"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-032#known-limitation-1"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["logging", "cloud-logging", "betterstack", "ios"]

[[acceptance]]
id = "AC-1"
text = "Decide the policy: after how many consecutive failures on the same offset is a batch skipped, and is a durable 4xx distinguished from a transient error by status code rather than by count"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Skipping emits telemetry naming what was dropped (offset range, line count, last status), so a silent skip can never look like a successful drain"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Consecutive-failure state is durable, not in-memory — a relaunch must not reset the counter and re-stall on the same batch"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "A poison batch cannot block the batches behind it"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Covered by a test that injects a permanent 4xx and asserts the uploader makes forward progress rather than looping"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Split out of [[TRIO-032]]'s "Known limitations, deliberately not fixed in 221" (limitation 1, rated
High, unobserved). Recorded as its own task on 2026-08-17 so it does not leave the board when
TRIO-032 is accepted and archived.

If the provider returns a **durable 4xx** for a batch, that batch's offset never advances and the
uploader retries it forever — the same permanent-stall outcome as the 2026-08-16 outage, reached
through a different door.

## Why 221's fix does not cover this

[[TRIO-032]] fixed the stall caused by *transient* failure: each pass now reads at most
`maxEventsPerRequest` lines and yields exactly one batch, so progress is banked under any temporary
error. That works because a transient failure eventually succeeds on retry.

A durable rejection never succeeds. Every failure in the 2026-08-16 evidence was transport-layer
(`-1001` timeout, `-1003` DNS, `-1005` lost, `-1009` offline), i.e. all transient — which is why this
mode has never been observed and why it was correctly judged out of scope for the 221 hotfix.

## Why it was deferred rather than fixed

Fixing it requires a skip-after-N-consecutive-failures policy, and skipping means **deliberately
discarding log lines**. That is a design decision about acceptable data loss, not a patch — which is
the right reason to have deferred it, and the reason this task starts with a decision rather than an
implementation.

## Notes carried over from acceptance criteria
