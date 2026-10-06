+++
uid = "01a00bb7-e56c-701d-b587-2bb0ec1bcf65"
key = "TRIO-032"
title = "CloudLogUploader never recovers after an app-container path change (phone logs stop uploading)"
status = "done"
kind = "code"
source = "human"
created = 2026-08-16
updated = 2026-10-06
touched = 2026-10-06
closed = 2026-10-06
first_closed = 2026-10-06
accepted_by = "Charlie"
accepted_at = 2026-10-06
owner = "me"
tags = ["logging", "betterstack", "cloud-logging", "ios"]

[[acceptance]]
id = "AC-1"
text = "Tail state keyed by a **stable identifier** (e.g. `log.txt`) rather than the absolute path, so a container migration preserves the offset — done in `fa09b10ee`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-2"
text = "Offset advances **per successful batch**, not only after the final one, so a flaky link makes forward progress and already-uploaded batches are not re-sent — done in `a892be0ff`, by the equivalent route: each pass reads at most `maxEventsPerRequest` lines and therefore yields exactly one batch, which collapses \"advance after all batches\" and \"advance per batch\" into the same thing. Progress is banked under any transient failure."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-3"
text = "A missing offset for an already-large file seeds to **EOF**, not 0 — a fresh install or migration must not attempt to backfill the entire log history — done in `fa09b10ee`, `seedToEndOfFileThreshold = 1 MiB`. Files under the threshold still start at 0, since they upload in full in one pass."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-4"
text = "Existing `log_prev.txt` stall drains or is abandoned deliberately rather than retried forever — **abandoned deliberately.** `fa09b10ee` applies the same seed-to-EOF rule to `pair.previousPath`, so the stalled ~12 MB `log_prev.txt` is seeded to its own size and never re-queued. The lines already lost to the 2026-08-16 outage stay lost; the alternative was retrying a 170-POST pass forever."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-5"
text = "Verified across a real TestFlight update: phone logs continue with no gap and no duplicate burst — **confirmed on the 220 → 221 update**, 2026-08-16 20:13Z, which crossed exactly the container migration that caused the outage. iOS rows per hour from the update through 07:00Z: 1063, 1352, 1421, 1295, 1579, 1443, 1506, 1632, 1533, 1673, 1476 — **unbroken, no hour missing**, first 221 row 5 minutes after the upload completed. Compare the original failure, where the 219 → 220 update produced 2 iOS rows against 4,555 watchOS rows."
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
ref = "20260816-204717-60601-ollama-implement.md"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T18:57:22+00:00"

[[reviews]]
run_id = "4886487a-2fb0-470d-bd0c-e16b6586f435"
model_family = "claude"
verdict = "pass"
reviewed_commit = "fa09b10ee7f168d71e36f448ee097e7a071ed2d0"
reviewed_paths = ["Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift"]
recorded_at = "2026-08-16T18:57:22+00:00"

[[reviews]]
run_id = "1dff2536-4017-4104-969b-897020ca1f2f"
model_family = "codex"
verdict = "pass"
reviewed_commit = "a892be0ffa576436437b8e69c2cc5cb2e8370a11"
reviewed_paths = ["Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift"]
recorded_at = "2026-08-16T19:10:31+00:00"

[[reviews]]
run_id = "waiver-20261006-operator-trio032"
model_family = "none"
verdict = "waived"
reviewed_commit = "b6ce8ceb87ebc265a9638494a80159488b5b9b43"
reviewed_paths = ["Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift"]
recorded_at = "2026-10-06T20:21:57+00:00"
+++

## Intent

The phone stopped uploading its own logs to Better Stack at **2026-08-16 16:06:51 CEST** and had still
uploaded nothing 3.5 hours later, despite the app running normally and several hours on solid WiFi.
The watch's logs kept flowing the whole time. Two independent defects in
`Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift` combine to make this unrecoverable.

### Defect 1 — tail offset is keyed by absolute path, which is not stable

```swift
var currentState = loadState(for: pair.currentPath)   // absolute path as a persistent key
```

`pair.currentPath` contains the iOS Data-container UUID. Installing build 220 over 219 migrated the
container **with contents intact** but under a new UUID:

| build | container |
|---|---|
| 219 (00:06 → 16:06:53) | `319D9650-C1F4-48E9-99F7-0DE2060A9B90` |
| 220 (16:11:33 → …) | `875F4DC8-CEE8-459F-97C0-96B7F9ECE347` |

The same `log.txt` holds 37,684 `[b:219]` lines and 5,593 `[b:220]` lines, so the file survived — only
its path changed. `loadState` therefore returned **offset 0** and the uploader tried to re-send the
entire ~12 MB file from byte 0.

`getDocumentsDirectory()` correctly re-resolves the path each launch; the bug is persisting that
resolved path as a durable key. Container paths are explicitly not stable across installs.

The existing shrink-detection reset cannot help — it fires only on `currentSize < currentState.offset`,
and the offset is already 0.

### Defect 2 — batch loop is all-or-nothing, so progress is never recorded

```swift
for batch in batches {
    case .failure:
        // Critical: do NOT advance offsets.
        return false
}
state.offset = nextOffset   // only after EVERY batch succeeds
```

With `maxEventsPerRequest = 250`, ~42,000 phone lines is **~170 sequential HTTP POSTs**. A single
failure anywhere discards all progress from that pass, and the batches that *did* succeed are
re-uploaded next cycle (duplicate ingestion, still no progress).

This is the defect that makes the state unrecoverable: **hours on good WiFi did not fix it**, which
rules out bandwidth as the cause. 12 MB over WiFi is seconds; 170 consecutive round trips without a
single failure is the actual bar, and it is not being cleared.

### Why the watch was unaffected

`uploadRotatingPair` handles `log.txt`, `log_prev.txt`, `watch_log.txt`, `watch_log_prev.txt`.
`watch_log.txt` is small enough that its from-zero re-upload completes in one pass. Better Stack over
the outage: **4,555 `watchos` rows, 2 `ios` rows** (and those 2 were a manual Test Connection).

## Evidence

- Local log `a393ff9d-log.txt`, 47,985 lines, 12 MB, 00:01 → 18:11 CEST 2026-08-16
- 28 transport errors on b:220 in 2 hours vs 13 on b:219 across the whole day
- Failure modes are all network-layer: `-1001` timeout, `-1003` DNS, `-1005` lost, `-1009` offline
- One error carries `interface: pdp_ip0[lte] … expensive, uses cell, estimated upload: 65536Bps, LQM: minimal`
- Better Stack ingestion metrics: 14:00 UTC hour = 214 logs; 15:00 UTC hour = no row

Review waiver (2026-10-06): the claude (fa09b10) and codex (a892be0) passing reviews are not stale. Those commits live on feature/cloud-logging-pre-rebuild and ship through patch 06, not dev, where CloudLogUploader.swift does not exist; so the staleness check against dev reports the file as changed. CloudLogUploader.swift at a892be0 is identical to build 230 (d44ca7609, "feat: cloud-logging"), so the reviewed code is the shipped code. Waived by the operator on that basis.

## Not a regression from build 220

The 219→220 delta touches only `G7SensorKit` and two watch `.swift` files — no entitlements, no
`Info.plist`, no `AppGroupID`. `06-cloud-logging.patch` applied cleanly. The container UUID change is
ordinary iOS behaviour on update. This latent bug has most likely fired on **every** prior update and
self-healed at the following midnight rotation, so a gap from update-time to midnight was never
noticed. It was noticed this time only because Better Stack was under active observation for
[[TRIO-028]] / [[TRIO-029]].

## Self-healing behaviour (why this is not urgent, but is real)

Rotation (`SimpleLogReporter`, `creationDate < startOfDay`) moves `log.txt` → `log_prev.txt` and
creates an empty `log.txt` at the first write after midnight. The new file uploads from offset 0
trivially, so **phone logging resumes on its own at the next midnight**. `log_prev.txt` inherits the
~12 MB at offset 0 and will retry it forever without ever succeeding — wasteful but non-blocking,
since current is uploaded before previous and each is an independent call.

Cost each time: every phone log line between the update and the next midnight is lost to Better Stack.

## Notes carried over from acceptance criteria

      No duplicate burst: exact `(timestamp, message)` collisions run 113–181 per hour evenly across
      all eleven hours, including the first hour after the update. A re-upload burst would concentrate
      in one hour; a flat distribution is ordinary same-second repetition of heartbeat lines.
## Implemented 2026-08-16 (build 221) — and what deliberately remains

Commits on `feature/cloud-logging`: `fa09b10ee` (keying + seed-to-EOF + bounded read) and
`a892be0ff` (one-batch-per-pass). Reviewed by claude and twice by codex/gpt-5.6-sol at high effort.

**Fixed:** offsets keyed by filename so a container migration no longer resets them; a file >1 MB
with no stored state seeds to EOF instead of queueing its whole history; each pass reads at most
`maxEventsPerRequest` lines so it yields exactly one batch, making "advance after all batches" and
"advance per batch" equivalent — progress is banked under any transient failure.

Two defects were found in my own work during review and fixed before shipping: a >512 KB line with
no newline would have re-read the same window forever (reintroducing the stall), and the first fix
only bounded the read without making progress unconditional, which the first gpt-5.6-sol review
correctly rated High.

### Known limitations, deliberately not fixed in 221

1. **Permanently-rejected batch still stalls (High, unobserved).** If the provider returns a durable
   4xx for a batch, its offset never advances and it retries forever. Every failure in the
   2026-08-16 evidence was transport-layer (`-1001/-1003/-1005/-1009`), i.e. transient, so this is a
   different mode from the one that caused the outage. Fixing it needs a skip-after-N-consecutive-
   failures policy, which means deliberately discarding logs — a design decision, not a patch.

2. **Multiline entries split ~10× more often (Medium, a regression from this work).** The cap cuts
   at physical line 250, which can fall inside a stack trace or table. Previously splits happened
   only at 512 KB boundaries (~every 2,700 lines). The fix is to cap at *entry* boundaries after
   aggregation rather than at physical lines: `CloudLogEntryAggregator` joins with `"\n"`, so an
   entry's consumed byte length is exactly `entry.utf8.count + 1` and the arithmetic stays exact.
   Not done in 221 because it moves offset computation into `uploadNewContent`, and offset
   arithmetic is where two errors already occurred in this task; a wrong offset loses or duplicates
   logs, whereas a split entry is cosmetic.

3. **Throughput ceiling (Medium, ample headroom).** 250 lines per 30 s timer = 8.3 lines/s capacity
   against 0.73 lines/s measured on 2026-08-16 — 11× headroom. A full-day 42,000-line backlog
   drains in ~84 minutes. Worth re-checking if log volume grows materially.
