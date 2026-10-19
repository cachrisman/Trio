+++
uid = "01a00eec-f044-75ad-a129-97a2b134acad"
key = "TRIO-042"
title = "WatchErrorReporter loses failed error reports permanently - pending list has no consumer and stores no payload"
status = "ready"
kind = "code"
source = "agent-discovered"
source_ref = "20260817-094712-codex-review#P1-error-replay"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "error-reporting", "reliability", "crashlytics"]

[[acceptance]]
id = "AC-1"
text = "Failed error payloads persist enough to actually be resent — envelope on disk, mirroring `WatchLogger`'s `filePath` approach, rather than an ID with `filePath: nil`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "A replay consumer exists and is wired to the same triggers `WatchLogger.resendPendingPayloads()` uses (reachability / activation), so pending errors drain on reconnect"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Pending records are pruned on ACK and bounded in count/age, so a permanently-unreachable phone cannot grow the list without limit"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "`clearSavedContextForPayload` honours its `payloadId` and clears only that payload's context"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Covered by a test: force `sendMessage` failure, assert the report survives and is resent on the next reachable session rather than silently dropped"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Changed via the feature branch and patch 05 regenerated, never hand-edited"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

When `sendMessage` fails, a watch error report is lost permanently. The retry bookkeeping exists but
is inert: nothing ever reads the pending list, and the error envelope was never saved in the first
place.

Found by codex review of `e4e760ff9` (run `5aae6ce8`) on 2026-08-17; verified by reading both classes
before filing. Split out of [[TRIO-030]], which is the sync task, not the owner of this code.

## The defect — retry machinery for logs, none for errors

`patches/05-watch-error-reporting.patch` implements two payload paths that look symmetric and are not:

| | `WatchLogger` | `WatchErrorReporter` |
|---|---|---|
| pending key | `watchLoggerPendingPayloads` (`:442`) | `watchPendingPayloads` (`:75`) |
| stores payload content | **yes** — real `filePath` (`:555`, `:561`) | **no** — `filePath: nil` (`:413`, `:421`) |
| `getPendingPayloads()` | `:806` | `:367` |
| `resendPendingPayloads()` | `:694`, called from `:666`, `:674`, `:681` | **does not exist** |

So the `errorHandler` on `sendMessage` (`:413`) and the `transferUserInfo` fallback (`:421`) both
append `{payloadId, type: "watchError", filePath: nil}` to `watchPendingPayloads` — a list with **no
consumer anywhere in the patch**. Even if a consumer existed there would be nothing to resend: only
the ID and type were persisted, never the envelope.

`clearSavedContextForPayload` does not cover this. It manages the capped crash *context* dictionary,
not the error payload.

Net effect: a transport failure, or app termination before the reply handler runs, permanently loses
the crash/error report — which is the exact scenario this reporter exists for.

## Second defect in the same actor

`clearSavedContextForPayload(_ payloadId: String)` (`:260`) **ignores its parameter**. It removes the
global `crashContextKey` and its `_metadata` sibling unconditionally, so an ACK for one payload clears
the saved context belonging to every other pending payload. The signature promises per-payload
scoping the body does not implement.

Found while verifying the above; not part of the codex review. Grouped here because it is the same
actor and the same edit.

## Notes carried over from acceptance criteria
## Relationship to the other patch-05 findings

Same patch and same review as [[TRIO-043]] (premature ACK) and [[TRIO-037]] (the
`isUploadedToHealth` clobber). All three are independent defects; [[TRIO-037]] is the most severe and
is already shipped in build 221.


## Dropped from build 222 (2026-08-18) — and why the second defect is smaller than it looks

Picked up for [[TRIO-044]] as "the second half only", on the assumption that making
`clearSavedContextForPayload` honour its `payloadId` was a small scoped fix. **It is not.** Verified
before writing any code:

```
$ grep -n "saveCrashContext" patches/*.patch
patches/05-watch-error-reporting.patch:246:+    func saveCrashContext(_ context: [String: String]) async {
```

That is the only mention **anywhere in the stack** — one definition, zero callers. So:

- `crashContextKey` is never written, and neither is its `_metadata` sibling.
- `clearSavedContextForPayload` *is* reachable (the ACK handler calls it at `:341`), but every call
  removes `UserDefaults` keys that are always absent. It is a no-op against real state.
- The parameter-ignoring bug is therefore real but **currently cannot misbehave** — there is no saved
  context for it to over-clear.

The deeper obstacle: there is **no payload→context association in the data model at all**.
`saveCrashContext` writes one global dictionary plus a `key → timestamp` metadata map; no payloadId
appears in either. Honouring the parameter means designing that association first — in code nothing
calls. That is speculative work, not a scoped fix, so it was dropped from 222 rather than built.

### When this is picked up

Do the two halves together. The first half (persist the envelope, add a replay consumer) is what gives
`saveCrashContext` a real caller and gives the context a payload to be scoped to; fixing the signature
before that would be designing against no requirement. Options considered and deliberately not taken
now, recorded so the decision is not re-litigated from scratch:

1. **Drop the unused parameter** or document the clear as global — honest, tiny, zero behaviour change.
   Reasonable interim step if the first half stays unscheduled for long.
2. **Build the per-payload association ahead of a caller** — rejected for 222; correct only once the
   replay consumer defines what a "payload's context" actually is.

Either way, `saveCrashContext` having no callers is itself worth resolving: it is either dead code to
delete, or a capability that was built and never wired up. Decide which before adding to it.
