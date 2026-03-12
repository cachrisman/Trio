You are reviewing an implementation plan for a watchOS complication freshness / WidgetKit observability system (Trio CGM app).

Your job is NOT to rewrite the design doc. Your job is to review the IMPLEMENTATION PLAN itself — whether it is correct, complete, sequenced well, and safe to hand to an engineer.

## What to evaluate (for each phase + task)

1) Correctness
- Is the proposed change technically correct for watchOS / Swift / WidgetKit / WCSession / App Group constraints?
- Call out anything that would fail, regress, or behave differently on-device.

2) Completeness
- Are there missing steps that would leave the system broken or inconsistent after that phase?
- Are dependencies between tasks respected?

3) Sequencing / ship boundaries
- Is the phase order safe?
- Could any phase make things worse before a later phase fixes it?
- Flag phase boundaries that are risky to ship independently.

4) Acceptance criteria quality
- Are the acceptance criteria verifiable (logs/CI/metrics), not vague?
- “Logs contain X” is verifiable. “Users report better freshness” is not.

5) Known pitfalls (must explicitly check)
- App Group cross-process locking: do NOT recommend flock/POSIX locks; avoid multi-writer shared files/state.
- WidgetKit behavior: reloadTimelines is a suggestion; coalescing is expected; avoid 1:1 assumptions.
- “Latency” measurement: beware stale correlation (getTimeline can run without a recent reload request). Prefer validity window + generation/delta (or explicitly acknowledge ambiguity).
- Provider restarts: provider-local state resets; plan should mark/handle restart artifacts (e.g. provider_restart flag / instance id) and avoid negative deltas.
- App Group UserDefaults: handle “unset vs 0” correctly; define behavior when scalar absent.
- High-cardinality IDs: do NOT extract UUIDs as metrics labels.

6) Spikes / unresolved items
- Does the plan correctly flag unknowns as spikes (e.g. notification-tap path, background task behavior), or does it assert certainty where it shouldn’t?

## Output format (strict)

Be terse — 1–2 sentences per bullet unless longer is genuinely necessary. No padding.

Phase [N] — [name]
- Task [N.M]: [issue or confirmation]. [One sentence on what to change or why it’s fine.]
- ...
- Phase-level risk: [ship-boundary or cross-task dependency concern]

Cross-cutting issues
- [issue]: [brief explanation + suggested correction]

Items correctly handled
- [bullet list]

Unresolved / needs spike
- [bullet list]

## Invariables

Do NOT summarize the plan back to me. 

Max 5 issues per pass; highest severity first.

For doc fixes: provide exact replacement text blocks under PATCH.

Start directly with phase-by-phase feedback.