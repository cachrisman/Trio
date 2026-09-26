+++
uid = "01a00f69-deb9-7295-a6ba-8f8b0291a211"
key = "TRIO-045"
title = "Watch delta spans the whole gap - ignores backfill readings between the last live EGV and the current one"
status = "in-progress"
kind = "code"
source = "human"
source_ref = "operator-report-2026-08-17-watch-delta"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "g7", "display", "delta", "backfill"]

[[acceptance]]
id = "AC-1"
text = "Delta is computed against the most recent reading *before* the current one from the store, including backfill-sourced entries, rather than the last live EGV held in memory"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "`lastSavedGlucoseValue` either updated when backfill lands, or removed in favour of the store lookup — decide deliberately which, and record why"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Cold start / sensor swap still renders a real delta rather than `--` (the behaviour the `??` fallback was added for; do not regress it)"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Dedup interaction checked: backfill records carry `sequence: nil` and dedup against the live EGV at the same ±1 s timestamp (TRIO-029), so the lookup must not select the current reading itself as its own predecessor"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Covered by a test with a gap: live reading, gap, backfill fill-in, live reading — asserting the delta reflects the last 5-minute step and not the whole gap"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Verified on a real build against a genuine disconnect-then-backfill"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-7"
text = "Delta computed against the most recent reading before the current one from the store, including backfill-sourced entries — `d689bec9e`"
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
text = "`lastSavedGlucoseValue` removed in favour of the store lookup, with the reason recorded above"
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
text = "Cold start / sensor swap still renders a real delta — the store persists across launches, and this is now the only path rather than a fallback"
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
text = "Dedup interaction checked — insertion happens after the delta, verified at `:1582` vs `:1495`"
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
text = "Covered by a test with a gap. **Not met.** No test was added; the watch extension has no test target in this stack, and adding one is out of scope for a build fix. The store-ordering argument above is a static proof, not a regression guard — a future refactor moving the insert above the delta would silently reintroduce this."
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "Covered by a test with a gap. **Not met.** No test was added; the watch extension has no test target in this stack, and adding one is out of scope for a build fix. The store-ordering argument above is a static proof, not a regression guard — a future refactor moving the insert above the delta would silently reintroduce this."
closed_at = 2026-09-26

[[acceptance]]
id = "AC-12"
text = "Verified on a real build against a genuine disconnect-then-backfill — pending build 222"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "7259a81e-3e5f-4a1a-81ef-18fabf841856"
model_family = "claude"
started = 2026-08-18
role = "author"
started_at = "2026-08-18T06:43:16+00:00"

[[reviews]]
run_id = "1d61a9ef-c51e-4e5b-874c-372ff71a02fe"
model_family = "codex"
verdict = "pass"
reviewed_commit = "c1bf529d0c64ba765726b72afa9f1d30baf0e2f3"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-08-18T05:45:17+00:00"

[[reviews]]
run_id = "1fbeb63e-a8fd-4db0-9042-266fdcb49862"
model_family = "codex"
verdict = "pass"
reviewed_commit = "02ec6ada3bc5c470ab33fe945a07948b4e091e2d"
reviewed_paths = ["patches/09-watch-g7.patch"]
recorded_at = "2026-08-18T06:41:45+00:00"
+++

## Intent

Operator report, 2026-08-17: the watch occasionally shows a much larger delta than the actual
change, because it subtracts the last *live* reading it saw from the current one even when backfill
readings have since filled the gap between them.

**Validated in code — the report is accurate.**

## The mechanism

`G7WatchSensorAdapter`, live-EGV path (`patches/09-watch-g7.patch:1741`):

```swift
let previous = lastSavedGlucoseValue
    ?? WatchGlucoseHistoryStore.shared.mostRecentMgDl(before: readingEpoch)
guard let previous else { return "--" }
return WatchGlucoseColorComputer.shared.displayDeltaString(previousMgDl: previous, currentMgDl: glucoseValue)
```

`lastSavedGlucoseValue` has exactly three assignment sites in the patch — `:956` and `:1435` set it to
`nil` (reset), and **`:1746` sets it to the new value in the live-EGV path only**. The backfill
handler never touches it.

The history-store fallback is reached only via `??`, i.e. only when `lastSavedGlucoseValue` is `nil` —
a cold start or sensor swap. In the ordinary case it is non-nil, so the store is not consulted.

Sequence that produces the inflated delta:

1. Live EGV at T0, value B → `lastSavedGlucoseValue = B`
2. Watch disconnects; several readings are missed
3. Reconnect; backfill arrives and **is stored** in `WatchGlucoseHistoryStore` (TRIO-029), but
   `lastSavedGlucoseValue` stays at B
4. Live EGV at T1, value A
5. Delta renders as `A − B` — spanning the entire gap, not the last 5-minute step

## TRIO-029 made the data available and this did not start using it

Before TRIO-029 shipped (build 220), backfill entries were logged and thrown away, so there was
nothing better to subtract from. Now they are persisted to the same store the fallback already knows
how to query — the correct previous reading is present and simply not consulted. Confirmed live on
build 221: `build205_w_history_insert source=backfill batch=8 appended=3 deduped=5 total=239`.

That makes this a genuinely small fix: the lookup already exists and is already called on the cold
path.

## Severity

Display-only — the delta string next to the current glucose. It does not reach dosing, and the stored
history itself is correct. But it misleads exactly when trust matters most: after a gap, when the user
is checking whether glucose moved while the watch was disconnected. A gap-spanning delta reads as a
sudden large excursion that did not happen.

## Notes carried over from acceptance criteria
## Related

TRIO-038 also concerns this delta, but is a different defect — that one is about *rounding order*
in mmol/L, this one about *which reading is subtracted*. Both touch `displayDeltaString`'s callers;
fixing them together is reasonable, but they are independent.


## Implemented 2026-08-18

`d689bec9e` on `feature/watch-g7`; patch 09 regenerated in `b70f080e7`, then again in `4272b3614`
when the TRIO-043 cascade forced a rebuild of the patch.

**Decision on the second criterion: `lastSavedGlucoseValue` was removed, not updated.** A second
source of truth for "previous reading" is what caused this defect, so keeping it and remembering to
update it on backfill would preserve the failure mode's cause. Evidence that removal is safe:

- `mostRecentMgDl(before:)` is **strictly**-before over epoch-ascending entries, returning the
  immediate predecessor — exactly the wanted semantics.
- The live EGV is inserted into the store at `:1582`, **after** the delta is computed at `:1495`. The
  current reading therefore cannot be selected as its own predecessor. The dedup criterion is met by
  construction rather than by care.
- The sensor-swap resets (`:719`, `:1198`) set the property to `nil`, which already fell through to
  the same store lookup — and the store still holds the previous sensor's readings. Those resets never
  isolated sensors, so removing them changes no behaviour.

Whitespace drift note: the offload added one leading space to seven lines, two of them on the
unrelated `C2 accepted swap` comment. Corrected by line number with before/after assertions.
`git diff --check` does not catch added indentation, only trailing space.
