+++
uid = "01a0d44d-54e7-72c8-b36d-e76a21f7bfa5"
key = "TRIO-068"
title = "Phone ACKs and records watch envelopes on the replyHandler path even when nothing was handled (unknown type or bad data)"
status = "ready"
kind = "code"
source = "human"
created = 2026-09-24
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["bug", "phone", "watch-connectivity"]

[[acceptance]]
id = "AC-1"
text = "Option chosen with the reason recorded here, weighing TRIO-043's handle-then-record-then-ACK ordering"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Fixed via the owning feature branch (patch 10's feature/watch-session-crash-guard or TRIO-043's, whichever owns the lines), patch regenerated, patch-test and audit pass"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Verified by incremental application, as for TRIO-047"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

The phone's replyHandler variant of `session(_:didReceiveMessage:replyHandler:)` in `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` records a watch envelope as processed and ACKs it after its `watchLogs` / `watchError` branches, even when neither branch handled anything: an unknown `type`, or missing or mistyped `data`. The ACK makes the watch drop its retained copy, so such a payload is lost with nothing ingested. This is the main delivery path; `WatchLogger` and `WatchErrorReporter` send with a reply handler when reachable.

Found by the cursor review of TRIO-047 (2026-09-24), which fixed the same shape on the no-replyHandler path by recording only a handled payload.

## Decision needed before fixing

On this path the ACK is also what stops the watch resending. Options:
- ACK and record only a handled payload; reply without an ACK otherwise. Risk: a newer watch sending a type this phone does not know resends indefinitely.
- ACK unknown types (so a newer watch does not storm) but not known types with missing or mistyped data.
- Keep ACKing everything, and log an event when nothing was handled, so the loss is visible.

## Notes carried over from acceptance criteria
