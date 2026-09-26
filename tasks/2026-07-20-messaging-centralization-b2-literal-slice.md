+++
uid = "019f8141-e117-77db-9216-aacd4d90496d"
key = "TRIO-014"
title = "Messaging centralization: extract envelope/ACK literal constants (early slice)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/watch-messaging-centralization/fable-advisory.md#L91"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "architecture"]

[[acceptance]]
id = "AC-1"
text = "All envelope/ACK string literals replaced with named constants shared between phone and watch targets"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "No behavior change; `patch-test.sh` stays green"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Small, low-conflict diff — does not require waiting on the main centralization initiative's placement decision"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Independent of the main watch-messaging-centralization initiative (which is waiting on upstream PR
sequencing), this is a mechanical, behavior-identical constants extraction: the entire envelope/ACK
wire protocol today is string literals (`"type"`, `"payloadId"`, `"payloadIds"`, `"data"`,
`"ackIds"`, `"pendingIds"`, `"watchLogs"`, `"watchError"`, `"ack"`, `"batchAck"`, `"queryAcks"`,
`"watchLogConfirm"`, `"complicationLastValidTimestamp"`, `"context_updated_at"`). Extending plan
Task B2 to cover these closes the biggest documented drift item cheaply, with low patch-conflict
surface. See fable-advisory.md §3.2(c) "Hybrid slices."

## Notes carried over from acceptance criteria
