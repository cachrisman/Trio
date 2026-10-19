+++
uid = "01a0139a-f2b6-73f5-b766-49d229721b4b"
key = "TRIO-048"
title = "TRIO-043 motivation comments are imprecise about which payload types the watch retains"
status = "ready"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-043#codex-run-2cc2d70f"
created = 2026-08-18
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "comments", "accuracy", "low"]

[[acceptance]]
id = "AC-1"
text = "Claim 1 reworded to make clear it describes the ordering this change replaced, not current behaviour"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Claim 2 distinguishes `watchLogs` (real retained payload) from `watchError` (metadata only, pending [[TRIO-042]])"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Mirrored identically across patches 05, 09 and 10 — the shared region must stay byte-identical or the stack stops applying"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Best done **alongside** [[TRIO-042]] or [[TRIO-047]], both of which touch this same function, so one cascade and one review round covers all of it"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Two sentences in the [[TRIO-043]] comment block in
`Trio/Sources/Services/WatchManager/AppleWatchManager.swift` are imprecise. Raised as a P2 by codex
(run `2cc2d70f`) on an otherwise **passing** review of `patches/05-watch-error-reporting.patch`.
Deliberately not fixed before build 222 — see the judgement below.

## The two claims

1. **"If the app terminates after the ACK but before this block runs, the report is lost."** True of
   the *old* ordering, which is why the change was made — but written in present tense inside a block
   whose ACK is now the last statement, so that termination window no longer exists. Reads as a
   description of current behaviour rather than of the bug being fixed.

2. **"the watch deletes its retained payload once it sees the ACK."** Accurate for `watchLogs`, whose
   payloads carry a real `filePath`. For `watchError` the watch never retains a resendable envelope
   before `sendMessage` — only `{payloadId, filePath: nil}` metadata after a failure ([[TRIO-042]]).

## Why it did not block the build

Claim 2 is imprecise rather than false. On ACK the watch does run both
`clearSavedContextForPayload(payloadId)` and `removePendingPayload(payloadId)`, so it genuinely
discards retained state for errors as well as logs. What it lacks is a *resendable* envelope, which is
[[TRIO-042]] — and the surrounding comment already names [[TRIO-042]] explicitly.

The load-bearing false guarantee in this block ("keep the payload retained for a retry", which
promised a retry path that does not exist) was a **P1** and was fixed before the build, in
`fb198cc95` / `dd3e08ce4` / `d0efd426a`.

The cost of fixing these two is not the edit — it is that every wording change to this region must be
mirrored across patches 05, 09 and 10 and invalidates all three diverse reviews, forcing a full
re-review round. That is not worth spending on motivation prose that is imprecise rather than
misleading.

## Notes carried over from acceptance criteria
