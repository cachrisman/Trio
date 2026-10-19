+++
uid = "01a00be0-2187-75d6-a6d5-c6089a795ce5"
key = "TRIO-035"
title = "Design: should sensor-flagged unreliable readings be displayed but excluded from dosing"
status = "backlog"
kind = "docs"
source = "human"
created = 2026-08-16
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["g7", "cgm", "safety", "design"]

[[acceptance]]
id = "AC-1"
text = "Operator decision recorded here: status quo, display/dosing split, or observability-only"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "If a split is chosen: confirm oref can never receive a display-only sample, with a test"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "If a split is chosen: decide Nightscout upload behaviour for display-only readings"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Re-measure the state-18 rate over a longer window before committing to build work"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Raised by the operator 2026-08-16: two readings Trio discarded were still shown in the Dexcom app's
chart. Should Trio reconsider rejecting sensor-flagged readings outright?

**This is a clinical judgement and belongs to the operator, not to an agent.** This task records the
evidence and the options; it does not make the call.

## What Trio does today

`G7CGMManager` drops the reading before it enters any Trio pipeline:

```swift
guard message.hasReliableGlucose else {
    updateDelegate(with: .error(AlgorithmError.unreliableState(message.algorithmState)))
    return
}
```

`hasReliableGlucose` is true **only** for `.ok`. So the reading never reaches Core Data, HealthKit,
the chart, oref, or Nightscout. It is all-or-nothing — display and dosing are lost together.

## Frequency (Better Stack, 8 days, 2026-08-09 → 2026-08-16)

| algorithmState | occurrences |
|---|---|
| 6 (`ok`) | 4,122 |
| **18 (`temporarySensorIssue`)** | **32** |
| every other non-ok state | **0** |

**0.8% of readings, ~4/day.** No warmup, no calibration states, no sensor failures in the window.
The entire question is therefore about state 18 specifically — a state the protocol names
*temporary*, distinct from the hard failure states (11, 12, 19, 20, 21, 25).

Observed instance: 74 → 70 → **[79 rejected]** → **[104 rejected]** → 145. The rejected values sit
plausibly on the trajectory; the surrounding pattern is consistent with a compression low and
recovery.

## The asymmetry that frames the decision

The Dexcom app **displays**. Trio **doses**. Rendering 79 on a chart is not the same act as feeding
79 to oref to compute insulin. That the Dexcom app shows a value is not evidence that the value is
safe to dose on — and the sensor itself is asserting it does not trust the reading.

Against that: a silent 10-minute hole costs situational awareness, and a user seeing Dexcom and Trio
disagree loses confidence in Trio.

## Options

1. **Status quo.** Safe, upstream-aligned, zero work. Cost: silent gaps, ~0.8% of readings.
2. **Display/dosing split** — ingest flagged readings marked display-only, render them distinctly,
   exclude them from oref. LoopKit's `NewGlucoseSample` already defines `isDisplayOnly: Bool`, and
   `G7BackfillMessage`/EGV already expose `glucoseIsDisplayOnly` — but **Trio references
   `isDisplayOnly` nowhere in `Trio/Sources/`**, so the field is currently dropped on the floor.
   Requires: G7SensorKit fork divergence, a `GlucoseStored` attribute + Core Data migration, chart
   rendering, an oref input filter, and a Nightscout upload decision.
3. **Observability only** ([[TRIO-034]]) — surface *why* the gap exists without changing what is
   stored or dosed. Cheapest, captures much of the practical value.

## Assessment

Option 2 is the only defensible way to "show them like Dexcom does", because it never lets flagged
data reach dosing. But it is a multi-layer change with a Core Data migration and a safety surface
touching oref's glucose input, for a phenomenon affecting 0.8% of readings.

Recommendation: **do option 3 now; do not put option 2 in a build without a deliberate design pass.**
Revisit if the state-18 rate rises materially above the measured 0.8%.

## Live event 2026-08-17 — new evidence that sharpens the design

A state-18 episode occurred on build 221, captured in full while it happened:

```
10:51:46Z  seq 1617  glucose 65  state:temporarySensorIssue  glucoseIsDisplayOnly:false
10:56:46Z  seq 1618  glucose 76  state:temporarySensorIssue  glucoseIsDisplayOnly:false
```

Three things this settles:

**1. The sensor's own `glucoseIsDisplayOnly` flag is the wrong lever — it is `false` here.** Option 2
must have Trio *set* `NewGlucoseSample.isDisplayOnly = true` based on `algorithmState`, using the
LoopKit field as the transport. It cannot simply forward the sensor's flag, which is not asserting
"display only" for these readings. Worth stating explicitly because "use the isDisplayOnly flag"
reads as though the sensor already marks them, and it does not.

**2. Dexcom discarded them too, this time.** Both readings are absent from the Dexcom app as well as
Trio — unlike the 2026-08-16 instance, where the operator reported Dexcom still charted them. So
"Dexcom shows them and Trio doesn't" is not reliably true, which weakens the parity argument for
option 2 somewhat.

**3. Backfill cannot rescue these, by design, at four separate guards.** Even if the sensor re-sends
a flagged reading in a bulk backfill, every ingestion path re-applies `hasReliableGlucose`:
phone live EGV, phone backfill (`G7CGMManager.swift:464`), watch live EGV, and watch backfill
(`patches/09-watch-g7.patch:1880`, which logs `backfill_entry_skipped reason=unreliable_state`). There
is therefore **no recovery route for a flagged reading short of implementing option 2** — no amount of
reconnecting or backfilling will bring one back.

The values themselves survive in Trio's telemetry (the raw `G7GlucoseMessage` carries
`glucose:Optional(65)` and the full payload hex), so a flagged reading is recoverable *as data* from
the logs even though it is unreachable through every product path.

## Notes carried over from acceptance criteria
