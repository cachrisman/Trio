+++
uid = "01a00be0-212c-72fb-a24d-c3767e13bab9"
key = "TRIO-034"
title = "Phone emits no explicit egv_unreliable event when a reading is rejected"
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
tags = ["g7", "telemetry", "logging", "observability"]

[[sessions]]
host = "claude-code"
ref = "20260816-205313-80821-ollama-implement.md"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T18:56:25+00:00"

[[reviews]]
run_id = "b790bd0e-050e-4b2d-8476-5387c1bd85f0"
model_family = "codex"
verdict = "pass"
reviewed_commit = "125424e990ee3c61c11bcf2a2adeac79779d26e1"
reviewed_paths = ["G7SensorKit/G7CGMManager/G7CGMManager.swift"]
recorded_at = "2026-08-17T07:46:31+00:00"
+++

## Intent

When the G7 reports a reading whose `algorithmState` is not `.ok`, `G7CGMManager` drops it:

```swift
guard message.hasReliableGlucose else {
    updateDelegate(with: .error(AlgorithmError.unreliableState(message.algorithmState)))
    return
}
```

The watch emits an explicit `egv_unreliable` telemetry event at this point. **The phone emits
nothing.** The state is recorded only as a field inside the preceding `egv_received` line, and there
is no event saying "this reading was rejected, and here is why".

Measured on a full day of phone logs (`a393ff9d-log.txt`, 2026-08-16, 47,985 lines):

| | count |
|---|---|
| phone `egv_unreliable` events | **0** |
| phone `algorithm_state=18` sightings | 2 |

## Why it matters

On 2026-08-16 two readings went missing from the phone between 16:36 and 16:56 CEST:

| Time | Seq | Glucose | State | Outcome |
|---|---|---|---|---|
| 16:41:46 | 1375 | 79 | 18 (`temporarySensorIssue`) | dropped |
| 16:46:48 | 1376 | 104 | 18 (`temporarySensorIssue`) | dropped |

Establishing that took an afternoon of cross-referencing Better Stack, the watch's telemetry, and
finally the raw phone log — because from the phone's own logs the readings simply *vanish*. With a
rejection event carrying the sequence, glucose and mapped state name, it is a single grep.

This is the same class of defect as [[TRIO-028]]: a value discarded silently, with the telemetry
recording only what survived the filter.

## Acceptance criteria

- [x] Phone emits an explicit rejection event on the `hasReliableGlucose` guard, at parity with the
      watch's `egv_unreliable` — done in G7SensorKit `852da77`, emitting `egv_unreliable` with
      `sequence` / `glucose` / `algorithm_state` / `algorithm_state_raw`
- [x] Event carries sequence, glucose value, and the **mapped state name** (`temporarySensorIssue`),
      not only the raw number — per CLAUDE.md, never log `String(describing:)` of an imported `NS_ENUM`
      — done, and the CLAUDE.md trap is genuinely avoided rather than merely dodged: `AlgorithmState`
      is a **native Swift** enum (`public enum AlgorithmState: RawRepresentable`, `.known(State)` /
      `.unknown(RawValue)`), not an imported `NS_ENUM`, and it conforms to `CustomStringConvertible`
      with `description` returning `String(describing: state)` over the inner native `State` enum. So
      interpolation yields `temporarySensorIssue`, not an opaque `Type(rawValue: 18)`. The raw value
      is carried alongside in its own `algorithm_state_raw` field for parsers.
- [x] Same treatment for the backfill path, which has its own separate `hasReliableGlucose` guard
      (`G7CGMManager.swift:464`) and currently only calls `logDeviceCommunication` — done in the same
      commit, emitting `backfill_entry_unreliable` with `timestamp` instead of `sequence`, since
      backfill records carry a sensor-relative timestamp and no sequence number
- [x] Verified against a real state-18 event (they occur ~4×/day, see [[TRIO-035]]) — **done against
      the real 2026-08-16 capture**, not a synthetic injection. See the section below for the full
      record. The shipped binary has not itself emitted one yet (zero `egv_unreliable` and zero
      `backfill_entry_unreliable` on iOS over the first 11 h of build 221, 2026-08-16 20:18Z →
      2026-08-17 07:00Z) — but that is absence of the trigger, not absence of the code: the watch's
      long-standing `egv_unreliable` also recorded zero over the same window, so no unreliable
      reading occurred on either platform to fire it.

## ✅ Confirmed firing in production 2026-08-17

The shipped code emitted for the first time during a live state-18 episode on build 221, exactly as
designed:

```
10:51:46Z  event=egv_unreliable sequence=1617 glucose=65 algorithm_state=temporarySensorIssue algorithm_state_raw=18
10:56:46Z  event=egv_unreliable sequence=1618 glucose=76 algorithm_state=temporarySensorIssue algorithm_state_raw=18
```

Mapped case name **and** raw value, both present, correlating on `sequence` with the preceding
`egv_received`. This upgrades the criterion below from verified-by-inspection to verified-in-production
— the two readings are grep-able by event name in a single query, which is precisely what took an
afternoon of cross-referencing on 2026-08-16.

The operator noticed the episode from the app; the telemetry answered "which readings, what values,
why" immediately. That is the whole point of the change.

## Verification against the real state-18 event (recorded 2026-08-17)

The motivating event is fully captured in Better Stack, both readings, on build 220 — i.e. the exact
real-world input the new code was written for, with every field known:

```
14:41:46 220 ios      event=egv_received glucose=79  sequence=1375 algorithm_state=18 …
14:41:46 220 ios      PLUGIN CGM - Process CGM Reading Result launched with
                      error(G7SensorKit.AlgorithmError.unreliableState(temporarySensorIssue))
14:41:52 220 watchos  event=egv_received glucose=79  sequence=1375 algorithm_state=18 …
14:41:52 220 watchos  event=egv_unreliable algorithm_state=18 sequence=1375 glucose=79 …
14:46:48 220 ios      event=egv_received glucose=104 sequence=1376 algorithm_state=18 …
14:46:48 220 ios      PLUGIN CGM - Process CGM Reading Result launched with
                      error(G7SensorKit.AlgorithmError.unreliableState(temporarySensorIssue))
```

Against these inputs the shipped guard emits
`egv_unreliable sequence=1375 glucose=79 algorithm_state=temporarySensorIssue algorithm_state_raw=18`.

### Correction — "the phone emits nothing" was too strong

The Intent above says the phone emitted nothing at the rejection point. It is not silent: Trio's
plugin layer logged `AlgorithmError.unreliableState(temporarySensorIssue)` at the same second as each
rejected reading, carrying the mapped state name. The real defect is narrower and worth stating
precisely — that line is **unstructured**: no `event=` key, no `sequence`, no `glucose`, so it cannot
be grepped by event name, cannot be correlated to the `egv_received` it rejects, and does not appear
in any event-name aggregation. That is why the afternoon of cross-referencing was still necessary.
The task's conclusion is unchanged; its premise is now accurate.

### The phone's event is better than parity, not equal to it

Criterion 1 asks for parity with the watch. The watch emits `algorithm_state=18` — the bare raw
number. The phone emits `algorithm_state=temporarySensorIssue` **and** `algorithm_state_raw=18`, so
it is strictly more readable than the event it was modelled on. Worth considering the reverse port to
the watch, which is [[TRIO-029]]'s file rather than this one.

Also visible in the capture: only seq 1375 produced a watch `egv_unreliable`; seq 1376 produced no
watch line at all, the watch having disconnected in between. For that second reading the phone's new
event is the *only* structured record that would exist — which is the case for the change in one line.

## Review provenance (recorded 2026-08-17)

The `reviews` entry above is a real codex/`gpt-5.6-sol` pass —
`G7SensorKit/.task-relay/notes/20260816-205542-codex-review.md`, run `b790bd0e`, `Status: PASSED`,
"No findings. BLE fields are logged in their native parsed forms … Both events occur only on the
existing unreliable-reading rejection paths."

As with [[TRIO-033]]: codex reviewed **G7SensorKit commit `852da77`**, but `reviewed_commit` records
the Trio-dev pin commit `125424e99`, since `tasks review` requires a SHA resolvable in this repo.

## Shipped in build 221 (2026-08-16)

Via the G7SensorKit pin, not a patch hunk: `852da77` is an ancestor of `50c76a7`, the pin set in
`125424e99`. Worth noting because `grep egv_unreliable patches/` finds only the **watch** copy in
`09-watch-g7.patch` and reads as "the phone fix did not ship" — the phone-side change lives in the
submodule and is invisible to a patch-stack grep.
