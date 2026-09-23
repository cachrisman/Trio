+++
uid = "01a00bb7-e5c6-7547-aad2-717e06c67db5"
key = "TRIO-033"
title = "G7 20-byte mod9=2 backfill-characteristic stream floods the log with full payload hex"
status = "done"
kind = "code"
source = "human"
created = 2026-08-16
updated = 2026-09-12
touched = 2026-09-12
closed = 2026-09-12
first_closed = 2026-09-12
accepted_by = "Charlie"
accepted_at = 2026-09-12
owner = "me"
tags = ["g7", "ble", "telemetry", "logging"]

[[sessions]]
host = "claude-code"
ref = "20260816-211112-43634-ollama-implement.md"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T19:14:29+00:00"

[[reviews]]
run_id = "9f3286a0-9edc-4925-8fbc-5d1e0a206f5e"
model_family = "codex"
verdict = "pass"
reviewed_commit = "125424e990ee3c61c11bcf2a2adeac79779d26e1"
reviewed_paths = ["G7SensorKit/G7CGMManager/G7Sensor.swift"]
recorded_at = "2026-08-17T07:46:26+00:00"
+++

## Intent

`backfill_len_rejected` logs a full payload hex dump for every notification on the backfill
characteristic that is not a whole multiple of 9 bytes. A recurring 20-byte stream trips this
constantly:

```
backfill_len_rejected bytes=20 mod9=2 truncated=false payload=9A2D50CE3AD1ACEF88B6628FA304FB670BE78AC5
```

Measured over one day of phone logs (`a393ff9d-log.txt`, 2026-08-16):

| | count |
|---|---|
| total log lines | 47,985 |
| `backfill_len_rejected` | 3,961 (**8.3%**) |
| of which `bytes=20 mod9=2` | **3,951** |
| genuine `bytes=18 mod9=0` | 2 (both b:219, before the parser fix) |

It arrives in bursts of ~600, roughly every two hours (01h, 03h, 05h, 07h, 09h, 11h, 16h). Each line
carries 40 characters of hex plus the standard prefix, ≈ 1.2 MB/day.

## The diagnostic value is real but already extracted

This is **not** a request to log nothing. The stream is still formally unidentified and
[[TRIO-028]]'s follow-on criterion ("identify what the 20-byte high-entropy stream is, or positively
exclude it from the backfill path") remains open, so going blind would be wrong.

What has already been established from this data:

- 20 bytes, `mod9=2` — cannot be a whole number of 9-byte `G7BackfillMessage` records
- Shannon entropy ≈ 7.803 vs ≈ 3.777 for confirmed backfill payloads — effectively random
- Fails xDrip's backfill sentinel (`byte[5]`/`[9]`/`[17] == 0x00`)
- Stable burst cadence, ~600 per burst, ~2 h apart

The 3,951st identical-shaped sample adds nothing the first few did not. **Sample it, do not drop it.**

## Correction to an earlier assessment

This flood was initially cited as a significant contributor to the [[TRIO-032]] upload stall. That
was overstated. At ~10% of log volume, removing it takes the file from ~12 MB to ~11 MB — it does not
change the outcome. [[TRIO-032]]'s all-or-nothing batching (~170 sequential POSTs, any one failure
discarding the whole pass) is the actual cause. This task is worth doing on its own merits — log
volume, battery, upload cost — not as a fix for that.

## Acceptance criteria

- [x] Payload hex retained for the first N occurrences per connection/session, then suppressed with a
      running count (target: ≥95% volume reduction, full diagnostic capability preserved) — **done in
      `50c76a7`**, N=3 per `(bytes, mod9)` signature. Measured on build 221 over 11 h
      (2026-08-16 20:18Z → 2026-08-17 07:00Z): 7 full-payload `backfill_len_rejected` + 12
      `backfill_len_rejected_suppressed` = **19 lines for a running total of 1,400 rejections**, a
      **98.6% reduction** against the ≥95% target. Full hex is still present on the first three of
      each shape, so diagnostic capability is preserved.
- [x] A non-multiple-of-9 length that is *not* the known 20-byte shape still logs its payload in full —
      the whole point of the guard is catching unknown formats — **satisfied by construction**: the
      counter is keyed on the `(bytes, mod9)` signature, so a shape never seen before starts at
      `count=1` and logs in full immediately regardless of how much 20-byte traffic preceded it. Not
      exercised in production during the 221 window — only the known `bytes=20 mod9=2` shape occurred.
- [x] Suppression is observable: the count of omitted packets is emitted, so the burst cadence stays
      measurable — **done**, `backfill_len_rejected_suppressed bytes=20 mod9=2 total=1400` emitted
      every 200th occurrence. The 12 summaries across the window keep the ~2 h burst cadence visible.
- [x] Consider routing through the existing `applyIngestionFilter` (Better Stack volume only) vs
      suppressing at the emit site (local log volume too) — [[TRIO-032]] shows local file size is what
      drives upload cost, so the emit site is likely correct — **resolved: emit site.** Suppression
      lives in `didReceiveBackfillResponse` ahead of `emitG7Telemetry`, so the line is never written
      to the local file at all and both local log size and Better Stack volume benefit.

### Review provenance (recorded 2026-08-17)

The `reviews` entry above is a real codex/`gpt-5.6-sol` pass —
`G7SensorKit/.task-relay/notes/20260816-211321-codex-review.md`, run
`9f3286a0`, `Status: PASSED`, "No material bugs, security issues, or correctness problems found."

One nuance so the record is not misread: codex reviewed **G7SensorKit commit `50c76a7`** in that
fork's own repo. The `reviewed_commit` field records `125424e99` instead — the Trio-dev commit that
pins `50c76a7` — because `tasks review` requires a commit resolvable in *this* repo and the fork's
SHAs are not. Same change, different repo's name for it.

### Verified in production 2026-08-16/17 (build 221)

One nuance worth recording: `backfillRejectSignatures` is an instance property and is deliberately
not reset across connections, but it *is* lost on process restart. The 7 full-payload lines observed
over 11 h rather than 3 reflect ~2 restarts of the manager in that window, not a defect — each
restart re-establishes the first-3-per-shape diagnostic sample, which is the intended behaviour.

## Design decision 2026-08-16 — sample by shape, do not port the xDrip sentinel

An earlier proposal was to port xDrip's backfill sentinel (`byte[5]`/`[9]`/`[17] == 0x00`) and use it
to *classify* this traffic as definitively-not-backfill, then log it once per burst. **Rejected.**

That sentinel is xDrip's check for the **G5/G6** backfill format. There is no known-good sample of
this 20-byte stream to validate it against, so using it to assert a semantic classification would be
claiming knowledge we do not have. That is precisely the error [[TRIO-028]] already made once — a
~205-line parser built on a single capture and an over-generalised premise, retired after a
16-minute radio-off test disproved it.

**Chosen approach: sample by packet shape.** Treat `(bytes, mod9)` as a signature. Log the full
payload for the first few occurrences of each distinct signature per sensor session, then suppress
with a running count. This:

- achieves the same ~95% volume reduction
- keeps any genuinely **new** shape logging in full immediately, which is the guard's actual purpose
- asserts nothing beyond what has been measured

The sentinel port remains open as a [[TRIO-028]] follow-on, to be done only against real validation
data.
