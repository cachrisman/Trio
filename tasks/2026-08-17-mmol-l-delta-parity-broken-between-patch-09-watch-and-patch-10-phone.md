+++
uid = "01a00ee7-e70e-75a3-9494-269ca0d7af98"
key = "TRIO-038"
title = "mmol/L delta parity broken between patch 09 (watch) and patch 10 (phone)"
status = "in-progress"
kind = "code"
source = "agent-discovered"
source_ref = "20260817-094710-codex-review#mmol-delta-parity"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "patches", "display", "mmol"]

[[acceptance]]
id = "AC-1"
text = "Decide which side is canonical — **operator decision 2026-08-17: round-each-operand.** Base `dev` already implements exactly that, so patch 10 was the deviation, not the watch."
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
text = "The losing side changed to match, via its feature branch and regenerated (never hand-edited) — `09e9e93a0` on the rebuilt `feature/watch-session-crash-guard`, patch 10 regenerated in `48d0608c3`. Implemented as a **pure revert to base's form**, so patch 10 no longer touches the block at all and the patch shrinks rather than gaining a third variant."
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
text = "Patch 09's doc comment updated to describe the phone's *actual* behaviour, whichever way this resolves — **no change needed.** The comment says the phone \"converts EACH operand … then subtracts\", which is true again now that base's form is restored. It was accurate when written and became stale only because patch 10 diverged; reverting patch 10 makes it correct rather than requiring a rewrite."
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
text = "Boundary cases covered by a test: a step that rounds differently under the two orders (e.g. 100 → 101 mg/dL in mmol/L mode), in both directions and across zero"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Verified on a real build that phone and watch show the same delta for the same reading pair"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "20260817-113118-ollama-implement.md"
model_family = "ollama"
started = 2026-08-17
role = "author"
started_at = "2026-08-17T12:03:18+00:00"

[[reviews]]
run_id = "f9a929cf-27a4-471c-8ad0-102b472a4471"
model_family = "codex"
verdict = "pass"
reviewed_commit = "48d0608c36f10c29f30131383a7fc4d33cd028de"
reviewed_paths = ["patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-08-17T12:03:18+00:00"

[[reviews]]
run_id = "10fb890c-0c22-4625-8d7e-9d7f2fb33d47"
model_family = "codex"
verdict = "pass"
reviewed_commit = "c1bf529d0c64ba765726b72afa9f1d30baf0e2f3"
reviewed_paths = ["patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-08-18T05:43:40+00:00"

[[reviews]]
run_id = "fabd4aac-7701-48bb-8fe5-887d8c603207"
model_family = "codex"
verdict = "pass"
reviewed_commit = "02ec6ada3bc5c470ab33fe945a07948b4e091e2d"
reviewed_paths = ["patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-08-18T06:42:42+00:00"
+++

## Intent

Two patches in the same stack disagree about how an mmol/L glucose delta is computed, so at a
rounding boundary the phone and the watch display different deltas. Found by a codex review of
`6116ce8d6` on 2026-08-17 while recording diverse-review evidence for [[TRIO-030]]; confirmed by
reading both sites.

Split out of [[TRIO-030]], which is the sync task, not the owner of this behaviour.

## The disagreement

Patch 09 states the invariant explicitly, in its own doc comment
(`patches/09-watch-g7.patch:4134`, `displayDeltaString`):

> mmol converts EACH operand to scale-1 mmol (matching the phone's per-reading `asMmolL` rounding,
> **which subtracts the two rounded values**) so watch and phone can't disagree on a half-boundary.

It implements exactly that — `NSDecimalRound` each operand to scale 1, then subtract.

Patch 10 (`patches/10-watch-session-crash-guard.patch:207`) changes the phone to do the opposite —
subtract in mg/dL first, convert the difference afterwards:

```diff
-                    var glucoseLast = Decimal(glucoseObjects[0].glucose)
-                    var glucoseSecondLast = Decimal(glucoseObjects[1].glucose)
+                    var deltaValue = Decimal(glucoseObjects[0].glucose - glucoseObjects[1].glucose)
+
                     if self.units == .mmolL {
-                        glucoseLast = glucoseLast.asMmolL
-                        glucoseSecondLast = glucoseSecondLast.asMmolL
+                        deltaValue = Double(truncating: deltaValue as NSNumber).asMmolL
                     }
```

So patch 09's guarantee is written against phone behaviour that patch 10 removes. Round-then-subtract
and subtract-then-round are not the same at a boundary: for a 100 → 101 mg/dL step the phone produces
`+0.1` mmol/L while the watch's direct-BLE/HealthKit path produces `+0`.

## Severity

Display-only. No dosing impact — this is the delta string shown next to the current glucose, not a
value that reaches the algorithm. But cross-source parity is the entire reason patch 09's helper
exists, and a user seeing `+0.1` on the phone and `+0` on the watch for the same pair of readings
reasonably reads it as one of them being wrong.

## Implemented 2026-08-17 — and what it cost

`09e9e93a0` (rebuilt `feature/watch-session-crash-guard`) + `48d0608c3` (patch 10 regenerated).

Landing this required rebuilding the patch-10 feature branch first — see [[TRIO-046]] for the method
and the survey of which other branches still need it. That branch was a stale stack embedding retired
patches 03/07 and a pre-rename patch 09, and its stale file tripped `mid-stack-update.sh`'s
fail-closed drift check on every regeneration attempt.

Provenance, stated precisely: an ollama `implement` run produced a logically correct but stylistically
different rewrite, plus three drifted whitespace lines. It was **discarded**. Since base `dev` already
contains the canonical round-each-operand form, the committed change is a deterministic revert to
base's exact text — asserted to match in exactly one place, then verified by diff. The offload
informed the change but did not author the committed content. Its note was lost when the worktree was
cleaned up, the same slip as [[TRIO-037]]'s second run.

**Verified on the fully stacked tree**, never the patch in isolation: 9/9 patches apply, the delta
block is base's round-each-operand form, and exactly one `g7Sequence` population site exists.

Codex `gpt-5.6-terra` (high) reviewed `48d0608c3` — `PASSED`, no material findings, independently
confirming both properties: *"preserves the round-each-operand mmol/L delta and leaves the later
patch's G7 sequence implementation as the sole population path."*

## Notes carried over from acceptance criteria
## Review note 2026-08-18 (codex, run 10fb890c)

Re-reviewed at the final patch-10 state after [[TRIO-043]] forced a regeneration. **PASSED, no
findings.** The reviewer confirmed the round-each-operand order matches the phone's canonical
behaviour and that rounding-boundary, zero, and negative deltas are all handled consistently.

One behaviour worth knowing rather than fixing: **a rounded tie can legitimately display `+0.0`** —
two readings that differ in mg/dL but round to the same mmol/L value produce a signed zero. That is
the correct consequence of matching the phone, not a defect, but it will look odd to a user watching
a slow drift and is the sort of thing that gets re-reported as a bug.
