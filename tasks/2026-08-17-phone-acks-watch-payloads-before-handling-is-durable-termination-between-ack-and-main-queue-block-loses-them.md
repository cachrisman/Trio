+++
uid = "01a00eec-f0a8-707f-9482-20d0d06bb2ca"
key = "TRIO-043"
title = "Phone ACKs watch payloads before handling is durable - termination between ACK and main-queue block loses them"
status = "in-progress"
kind = "code"
source = "agent-discovered"
source_ref = "20260817-094712-codex-review#P2-premature-ack"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "error-reporting", "reliability", "ios"]

[[acceptance]]
id = "AC-1"
text = "The durable dedupe record is written only after handling is genuinely durable — either do the work synchronously before ACK, or persist the payload to disk first and record processed on completion"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "ACK semantics stated honestly in the code and comments — if ACK means \"persisted\", the write must precede it; the current \"received and queued\" comment describes an in-memory queue"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "A payload that was ACKed but not handled can still be recovered, or cannot exist by construction"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "The misleading `(durable enqueue)` comment removed or corrected"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Covered by a test that simulates termination between ACK and handling, asserting no silent loss"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Changed via the feature branch and patch 05 regenerated, never hand-edited"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-7"
text = "Durable dedupe record written only after handling — `recordProcessed` moved inside the block"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-8"
text = "ACK semantics honest in code and comments — the `(durable enqueue)` claim is removed, and the new comments state that neither promise precedes the work"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-9"
text = "An ACKed-but-unhandled payload cannot exist by construction on the deallocation path — the `guard let self` skips the reply so the watch retries"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-10"
text = "Misleading `(durable enqueue)` comment removed"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-11"
text = "Covered by a test simulating termination between ACK and handling. **Not met.** There is no test target covering `BaseWatchManager` in this stack, and simulating mid-dispatch termination needs process-level control the suite has no harness for. Accepted deliberately; the reordering is argued statically and confirmed by codex review, which is weaker than a test and should be recorded as such."
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "Covered by a test simulating termination between ACK and handling. **Not met.** There is no test target covering `BaseWatchManager` in this stack, and simulating mid-dispatch termination needs process-level control the suite has no harness for. Accepted deliberately; the reordering is argued statically and confirmed by codex review, which is weaker than a test and should be recorded as such."
closed_at = 2026-09-26

[[acceptance]]
id = "AC-12"
text = "Changed via the feature branches and patches regenerated, never hand-edited"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-13"
text = "No regression in watch->phone messaging on build 222 — 171 `watchos` log rows delivered through the reordered path in the first 30 minutes"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[sessions]]
host = "claude-code"
ref = "20260818-065319-claude-implement.md"
model_family = "claude"
started = 2026-08-18
role = "author"
started_at = "2026-08-18T06:43:16+00:00"

[[sessions]]
host = "claude-code"
ref = "20260818-070155-claude-implement.md"
model_family = "claude"
started = 2026-08-18
role = "author"
started_at = "2026-08-18T06:43:16+00:00"

[[reviews]]
run_id = "cdd6c179-328a-483a-a340-369ffca0bfc8"
model_family = "codex"
verdict = "fail"
reviewed_commit = "c1bf529d0c64ba765726b72afa9f1d30baf0e2f3"
reviewed_paths = ["patches/05-watch-error-reporting.patch"]
recorded_at = "2026-08-18T05:45:17+00:00"

[[reviews]]
run_id = "2cc2d70f-d1b8-4965-849e-6978972dc030"
model_family = "codex"
verdict = "pass"
reviewed_commit = "02ec6ada3bc5c470ab33fe945a07948b4e091e2d"
reviewed_paths = ["patches/05-watch-error-reporting.patch"]
recorded_at = "2026-08-18T06:41:46+00:00"
+++

## Intent

The phone tells the watch "received and queued" before the work is durable. If the app dies in the
gap, the payload is lost and the protocol actively prevents recovery.

Found by codex review of `e4e760ff9` (run `5aae6ce8`) on 2026-08-17; verified before filing. Split out
of TRIO-030.

## The defect

`patches/05-watch-error-reporting.patch:1126-1147` runs three steps in this order:

```swift
// New payload - record as processed (durable) BEFORE processing
recordProcessed(payloadId)

// Enqueue payload handling (durable enqueue)
DispatchQueue.main.async { [weak self] in
    if type == "watchLogs" { SimpleLogReporter.appendToWatchLog(logData) }
    else if type == "watchError" { self?.handleWatchError(errorData) }
}

// Reply ACK immediately (even if Crashlytics fails) - ACK means "received and queued"
replyHandler(ack)
```

The dedupe record is durable. The **work is not** — `DispatchQueue.main.async` is an in-memory queue.
The comment `// Enqueue payload handling (durable enqueue)` asserts a property the line does not have,
which is why this survived review.

Terminate between the ACK and that block executing and all three of these hold at once:

1. the watch received the ACK and deleted its retained payload / cleared saved context,
2. the phone persisted `recordProcessed(payloadId)`, so a resend short-circuits at the dedupe check
   (`replyHandler(ack); return`) without doing any work,
3. the queued block never ran, so the logs or error were never written.

The payload is unrecoverable, and step 2 is what makes it unrecoverable rather than merely delayed —
the dedupe record is doing its job against a payload that was never actually processed.

## Severity

Narrow window — one main-queue turn — so this needs a termination at an unlucky moment rather than
being a routine loss, and it has not been observed. But it is silent, and it defeats the exact
guarantee the ACK protocol was added to provide. The comment claiming durability makes it likely to
be re-introduced if it is ever refactored without this note.

## Notes carried over from acceptance criteria
## Relationship to the other patch-05 findings

Same patch and review as TRIO-042 (unrecoverable failed error reports) and TRIO-037 (the
`isUploadedToHealth` clobber, already shipped in 221). Independent defects — but note TRIO-042 and
this one compound: an error lost here is also not retryable there.


## Implemented 2026-08-18

`5a40d8ad6` on `feature/watch-error-reporting`, mirrored to `6c89bfb5b` on `feature/watch-g7` and
`dfe00a693` on `feature/watch-session-crash-guard`. Patches regenerated in `e6fe2b535` (05),
`4272b3614` (09) and `c1bf529d0` (10).

**The change:** `recordProcessed` and `replyHandler` both moved to the end of the
`DispatchQueue.main.async` block, after the handling. A `guard let self else { return }` means a
torn-down manager sends no ACK at all — the watch's `sendMessage` reply times out, its `errorHandler`
runs, and the payload stays retained for retry. The false `(durable enqueue)` comment is gone.

### Why this touched three patches

Patches 05, 09 and 10 **each create** the replyHandler variant of `didReceiveMessage`. The feature
branches are parallel stacks — each replays the earlier patches' content as its own commits under
different SHAs — so 09's and 10's copies are 05's copy plus additions in non-overlapping places.
Changing the shared region in 05 alone made the copies diverge and the stack stopped applying at 09,
then at 10. All three had to carry the identical change.

Cost: patch 09's comment about not sending reverse `transferUserInfo` confirms sat immediately before
the ACK, which is now inside the block. Keeping it there re-diverged the copies, so it was **dropped**
rather than relocated. Behaviour unchanged.

Both regenerations needed `--force-from-feature-branch` with an audited reason: the script bootstraps
by applying the *committed* patch onto the new baseline, which cannot work when that patch is the one
being replaced.

## Accepted consequences (both fail toward retry, not loss)

1. `isProcessed` is read on the delegate queue while `recordProcessed` now writes on the main queue,
   so two identical payloads arriving back-to-back may both be handled. A duplicate log append or
   Crashlytics record is harmless where a lost report is not.
2. The ACK now waits one main-queue hop, putting the WCSession reply timeout in play if the main queue
   is blocked. The watch then sees a send failure and retains the payload for resend.

Note (2) interacts with TRIO-042: for `watchError` payloads the watch's retry path stores
`filePath: nil` and has no consumer, so a timed-out ACK still loses the report. The window is much
narrower than the one this task closes, but it is not zero until TRIO-042 lands.

## Production evidence, build 222 (2026-08-20)

The reordered path is the one watch **log** payloads travel: `didReceiveMessage(_:replyHandler:)` with
envelope type `watchLogs`. In the first 30 minutes after install, **171 `watchos` rows reached Better
Stack**, which requires that path to accept, handle, record and ACK each payload. No log gap, no
duplicate storm, no stalled uploads.

Separately, a watch carb entry at 06:24:03 round-tripped in about one second
(`Sending carbs request` -> phone handling -> `Acknowledgment received … success: true, isFinal: true`).
That flow uses its own `ackCode: carbs_logged` mechanism rather than the payloadId envelope this task
changed, so it is corroborating rather than direct evidence.

Taken together: no regression in watch->phone messaging after moving `recordProcessed` and
`replyHandler` behind the handling work. The termination-window fix itself cannot be observed in
normal operation — it only matters when the app dies inside a one-main-queue-turn window — so this is
evidence of *no harm*, not proof the race is closed.
