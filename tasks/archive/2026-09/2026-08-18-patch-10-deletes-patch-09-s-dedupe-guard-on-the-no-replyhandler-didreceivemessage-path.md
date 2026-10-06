+++
uid = "01a0134a-14f4-7297-be8b-d2919a981abd"
key = "TRIO-047"
title = "Patch 10 deletes patch 09's dedupe guard on the no-replyHandler didReceiveMessage path"
status = "done"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-043#patch05-regen-conflict"
created = 2026-08-18
updated = 2026-09-24
touched = 2026-09-24
closed = 2026-09-24
first_closed = 2026-09-24
accepted_by = "Charlie"
accepted_at = 2026-09-24
owner = "me"
tags = ["watch", "patches", "patch-clobber", "dedupe", "ios"]
parent = "01a0d44e-082f-736d-a5a8-255316285327"

[[sessions]]
host = "claude-code"
ref = "98f4daf1-40b8-4772-a530-24af0d9454ec"
model_family = "claude"
started = 2026-09-24
role = "author"
started_at = "2026-09-24T16:41:56+00:00"

[[reviews]]
run_id = "ceb5161b-d9e4-4ab3-a7a1-289d44796cb2"
model_family = "cursor"
verdict = "fail"
reviewed_commit = "2c64315b7d1609aa152e7c64abaa94d9637e0d2e"
reviewed_paths = ["Trio/Sources/Services/WatchManager/AppleWatchManager.swift"]
recorded_at = "2026-09-24T16:41:56+00:00"

[[reviews]]
run_id = "8b29fd44-51f1-4c68-8871-3daa2f9b37b3"
model_family = "cursor"
verdict = "fail"
reviewed_commit = "dab5ecb8c6ba1bb9b9478fa0cfe1eccdf800e2f7"
reviewed_paths = ["Trio/Sources/Services/WatchManager/AppleWatchManager.swift"]
recorded_at = "2026-09-24T16:43:53+00:00"

[[reviews]]
run_id = "af4ea6a9-07d3-4b42-ac56-580eab28b5f6"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "dab5ecb8c6ba1bb9b9478fa0cfe1eccdf800e2f7"
reviewed_paths = ["Trio/Sources/Services/WatchManager/AppleWatchManager.swift"]
recorded_at = "2026-09-24T16:46:31+00:00"

[[reviews]]
run_id = "f5d9507f-6dea-4e1a-812e-24fdfdd540c4"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "243acc1216bb02fe696063c1897586cf560e5169"
reviewed_paths = ["patches/09-watch-g7.patch", "patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-09-24T16:48:35+00:00"
+++

## Intent


## Intent

Patch 10 removes the deduplication that patch 09 adds to the **no-`replyHandler`** variant of
`session(_:didReceiveMessage:)` in `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`,
leaving that path with no duplicate suppression at all. **Live in build 221.**

Found 2026-08-18 while regenerating patch 05 for TRIO-043 — the regeneration failed on an
unrelated conflict, and tracing that conflict through the stack surfaced this.

## Proof — incremental application, marker counted after each patch

```
09-watch-g7                    dedupe_guard=1  background_wakes=1
10-watch-session-crash-guard   dedupe_guard=0  background_wakes=0
13-phone-ble-observer-telemetry dedupe_guard=0 background_wakes=0
14-temp-target-default-tab     dedupe_guard=0  background_wakes=0
```

Present after 09, gone after 10, never restored. Patch 10 carries it as an explicit deletion, not a
merge artifact (`patches/10-watch-session-crash-guard.patch:313`):

```diff
             if let type = message["type"] as? String,
                let payloadId = message["payloadId"] as? String {
-                if self?.isProcessed(payloadId) == true { return }
-                self?.recordProcessed(payloadId)
-
+                // This is an envelope message but no replyHandler - handle it
```

## Consequence

Every `watchLogs` / `watchError` payload arriving on the no-reply path is handled unconditionally.
The watch retries payloads it believes unacknowledged, so redelivery is a normal occurrence, not a
rare one — the result is duplicate log appends and duplicate Crashlytics records.

Severity is **duplicate processing, not loss** — the opposite and much safer direction from
TRIO-043, which deliberately accepts possible duplicates to avoid losing a report. It is a
regression rather than a hazard, but an unintended one: nothing in patch 10's stated purpose
(watch session crash guard) calls for removing dedupe.

## What is NOT a defect here

Patch 10 also deletes patch 09's `sessionReachabilityDidChange` body (`pendingSendWorkItem?.cancel()`,
the coalescer reset, and an inline `setupWatchState`/`sendDataToWatch` task). **That one is fine** — it
is replaced by a newer implementation calling `scheduleDelegateTriggeredUpdate(source:)` and
`sendPendingAcksIfReachable()`. A deliberate supersede, verified present in the stacked tree. Do not
"restore" it.

Patch 10 likewise rewrites the envelope guard at the top of the replyHandler variant. The stacked
result keeps the correct type-first form (`guard let type` before the `queryAcks` branch, so a
`queryAcks` message with no `payloadId` is not rejected). Verified in the stacked tree — no action.

## The audit warned, and the warning was invisible — again

`patch-audit.sh` flags this file in patch 10 as
`⚠ AppleWatchManager.swift (+46/-63) — WARN: deletes pre-existing upstream code`. It is one of **31**
such warnings, so the signal was present and unread. This is the second time that has happened, after
TRIO-037; see `docs/process/patch-clobber-guardrails.md`. Worth reconsidering whether a
warning-count that high can function as a signal at all.

## Acceptance criteria

- [x] The no-`replyHandler` `didReceiveMessage` path deduplicates again, by whatever mechanism is
      correct once TRIO-043's reordering has landed — do not blindly restore the deleted two lines [feature/watch-session-crash-guard 2c64315b7; patch 10 regenerated in dev 966b40e0c]
      without checking they still make sense against the new handle-then-record-then-ACK ordering
- [x] Decide deliberately whether `recordProcessed` on this path should precede or follow handling, and
      record why — TRIO-043 establishes that ordering matters, and this path has no ACK to anchor it [follows handling: see Fix below]
- [x] Verified by incremental application (marker counted after each patch), not by reading patch 10
      alone — reading the patch in isolation is what let this ship [guard present from 09 through 15, see Fix below]
- [x] Changed via the feature branch and the patch regenerated, never hand-edited [mid-stack-update.sh --patch 10 --cherry-pick 2c64315b7]
- [x] Confirm no other patch-09 addition is silently deleted by a later patch: diff the post-09 tree
      against the post-14 tree for this file and account for every difference [all 60 lines accounted for, see Fix below; post-15 used as the end state, a superset of post-14]

## Related

Same defect class as TRIO-037 (patch 05's upstream initializers) and the 0.8.2 patch-13 Omnipod
clobber. TRIO-043 touches the sibling replyHandler variant of this same function.

## Fix (2026-09-24, build 230)

The guard is restored inside the no-replyHandler path's existing main-queue block (feature/watch-session-crash-guard 2c64315b7 and dab5ecb8c): skip a payload already processed, handle it, then `recordProcessed`, and record only a payload that was actually handled, so an unknown type or missing data cannot block a later valid delivery of the same payloadId (from cursor review). Recording follows handling, the same order the replyHandler variant uses after TRIO-043, so a termination mid-handling yields a duplicate on resend rather than a loss. There is no ACK on this path to anchor. The check and the record both run on the main queue here, and a torn-down manager (`guard let self`) handles and records nothing.

**Incremental application.** Patches applied one at a time from a clean dev tree, counting the guard and the record inside the no-reply `didReceiveMessage` after each. Patch 09 adds them as `self?.isProcessed(payloadId) == true` / `self?.recordProcessed(payloadId)`; from patch 10 onward they are the rewritten `self.isProcessed(payloadId)` / `self.recordProcessed(payloadId)`, present through 15. Before the fix, 10 removed them.

**Patch-09 lines removed by later patches** (60 non-comment lines present after 09 but absent at the end of the stack), all accounted for:
- Phone-side glucose colour computation and the white-in-range rule (`getDynamicGlucoseColor`, hard-coded 55/220, `currentGlucoseColorString`, `WatchGlucoseObject` colour): removed by patch 13 for build 205 P2. The watch computes colours from canonical mg/dL.
- `g7Sequence` assignment and dictionary lines: re-implemented by patch 13.
- `sessionReachabilityDidChange` body and the replyHandler envelope guard: deliberate supersedes by patch 10, as noted above.
- `retryConnection()` and its call: removed by patch 10 (session crash guard); guarded `session.activate()` calls remain.
- `complication_budget_check` log: still present, reworded.
- `updateApplicationContext` transfer log: replaced by patch 10's `context_attempted` / `context_succeeded` / `context_failed` lines.
- The glucose fetch predicate: narrowed to a 2-hour window by build 205 P1; the watch keeps the full 24 hours locally.

## Release note

Watch log and error reports that the watch resends are no longer recorded twice on the phone.
