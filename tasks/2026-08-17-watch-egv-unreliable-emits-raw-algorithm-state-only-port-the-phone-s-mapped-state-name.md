+++
uid = "01a00ee7-e80d-70e2-97be-d4b542f16839"
key = "TRIO-041"
title = "Watch egv_unreliable emits raw algorithm_state only - port the phone's mapped state name"
status = "in-progress"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-034#watch-reverse-port"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "g7", "telemetry", "observability"]

[[acceptance]]
id = "AC-1"
text = "Watch `egv_unreliable` carries the mapped state name **and** `algorithm_state_raw`, matching the phone's field names exactly so the two streams correlate without translation — `be3f545d2`"
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
text = "The second watch guard (`:1880`, the backfill path) gets the same treatment, at parity with the phone's `backfill_entry_unreliable` — done, and the third guard (`reason=missing_glucose_value`) was included too"
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
text = "Existing field names not renamed in a way that breaks Better Stack queries built on `algorithm_state=18` — add the name, keep the raw value under a distinct key. **Deliberately not met.** The raw value is preserved under `algorithm_state_raw`, but `algorithm_state` on these three watch events now yields `temporarySensorIssue` rather than `18`, so a query filtering `algorithm_state=18` against them does break. Accepted because the phone made exactly this trade in build 221 ([[TRIO-034]]) and parity was the entire point of this task — keeping the watch on the old meaning would have preserved the very divergence being closed. `algorithm_state_raw` is now the stable numeric key on **both** platforms and is what numeric queries should use. Note `egv_received` still emits `algorithm_state=18` on both platforms; only the rejection events changed."
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "Existing field names not renamed in a way that breaks Better Stack queries built on `algorithm_state=18` — add the name, keep the raw value under a distinct key. **Deliberately not met.** The raw value is preserved under `algorithm_state_raw`, but `algorithm_state` on these three watch events now yields `temporarySensorIssue` rather than `18`, so a query filtering `algorithm_state=18` against them does break. Accepted because the phone made exactly this trade in build 221 ([[TRIO-034]]) and parity was the entire point of this task — keeping the watch on the old meaning would have preserved the very divergence being closed. `algorithm_state_raw` is now the stable numeric key on **both** platforms and is what numeric queries should use. Note `egv_received` still emits `algorithm_state=18` on both platforms; only the rejection events changed."
closed_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Changed via the feature branch and patch 09 regenerated, never hand-edited — `31039f275` via `mid-stack-update.sh`"
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
text = "Verified against a real state-18 event, or against the 2026-08-16 capture if none has occurred"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "20260817-142201-3408-ollama-implement.md"
model_family = "ollama"
started = 2026-08-17
role = "author"
started_at = "2026-08-17T12:33:03+00:00"

[[reviews]]
run_id = "eac018c4-2667-41c3-8d8b-83abe30616c7"
model_family = "codex"
verdict = "fail"
reviewed_commit = "31039f275cabd28c86545dbcc6b1f02041ce5422"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-08-17T12:33:03+00:00"

[[reviews]]
run_id = "dfe11e3c-6040-4838-8982-a4d2dbef7985"
model_family = "codex"
verdict = "pass"
reviewed_commit = "ff30b216063c72369a5791ba03125f556eb06600"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-08-18T04:54:22+00:00"

[[reviews]]
run_id = "1fbeb63e-a8fd-4db0-9042-266fdcb49862"
model_family = "codex"
verdict = "pass"
reviewed_commit = "02ec6ada3bc5c470ab33fe945a07948b4e091e2d"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-08-18T06:41:45+00:00"
+++

## Intent

The watch's `egv_unreliable` event carries only the raw algorithm-state number. The phone's
equivalent, shipped in build 221 by [[TRIO-034]], carries both the mapped case name and the raw
value. Port the phone's form to the watch.

Observed in the real 2026-08-16 state-18 capture:

```
14:41:52 220 watchos  event=egv_unreliable algorithm_state=18 sequence=1375 glucose=79 …
```

vs. what the phone now emits for the same rejection:

```
egv_unreliable sequence=1375 glucose=79 algorithm_state=temporarySensorIssue algorithm_state_raw=18
```

[[TRIO-034]]'s criterion asked for the phone to reach *parity* with the watch. It overshot — the
phone's version is strictly better, and the watch is now the weaker of the two. This task closes that
gap in the other direction.

## Why it is worth doing

`18` is meaningless without the lookup table. The whole reason [[TRIO-034]] exists is that
establishing why two readings vanished on 2026-08-16 took an afternoon of cross-referencing; a bare
integer in the watch's event is exactly the friction that caused it. It is also the CLAUDE.md
verification rule in miniature — log a mapped name, never an opaque raw enum value.

`AlgorithmState` already conforms to `CustomStringConvertible` with `description` returning
`String(describing: state)` over the inner native `State` enum, so interpolating the state directly
yields `temporarySensorIssue`. No new mapping table is needed.

## Scope

The watch's emission site is in the watch adapter (patch `09-watch-g7.patch`), not the G7SensorKit
fork — a different file from [[TRIO-034]]'s change, which is why it was not done in the same commit.

Check both watch rejection sites, not only the live-EGV one: `patches/09-watch-g7.patch:1678` and
`:1880` both guard on `hasReliableGlucose`, mirroring the phone's two sites (live EGV and backfill).

## Implemented 2026-08-17

`be3f545d2` on `feature/watch-g7`, patch 09 regenerated in `31039f275`.

**Three** sites changed, not two — the second `backfill_entry_skipped` call
(`reason=missing_glucose_value`) also logged a bare `algorithm_state`, so it was included for
consistency:

| site | event |
|---|---|
| `G7WatchSensorAdapter.swift:1443` | `egv_unreliable` |
| `:1644` | `backfill_entry_skipped reason=unreliable_state` |
| `:1649` | `backfill_entry_skipped reason=missing_glucose_value` |

Each now emits `algorithm_state=<caseName> algorithm_state_raw=<number>`.

Verified before writing the change that the watch adapter imports `G7SensorKit`, so `algorithmState`
is the same `AlgorithmState` whose `CustomStringConvertible` yields the case name — per CLAUDE.md, an
imported enum's rendering is checked against its definition rather than assumed.

Provenance: an ollama `implement` run produced all three edits correctly but with three drifted
whitespace lines. Discarded; the change was re-applied deterministically with each of the three
substitutions asserted unique before writing. Third time today drift appeared on a Swift file — there
is no static gate for Swift, so the loop cannot catch it.

`patch-test.sh` passes. **File count held at 29 (committed: 29)** — the CLAUDE.md red flag for a
silently dropped new file did not fire.

Stacked verification (all nine patches applied to a scratch tree off `dev`) — the change plus
regression guards on the same build:

| check | result |
|---|---|
| `algorithm_state_raw` sites | 3 |
| [[TRIO-037]] upload flags | 2 |
| [[TRIO-038]] round-each-operand delta | present |
| `g7Sequence` population sites | 1 |

## Notes carried over from acceptance criteria
