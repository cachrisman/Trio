+++
uid = "01a00f98-aefe-7702-8391-6bbd8364264c"
key = "TRIO-046"
title = "Rebuild the stale cloud-logging and phone-ble-observer-telemetry feature branches"
status = "ready"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-038#branch-staleness-survey"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["patches", "tooling", "maintenance"]

[[acceptance]]
id = "AC-1"
text = "`feature/cloud-logging` rebuilt, orphan gone, oracle diff clean, patch 06 regenerates with `Drift check: CLEAN`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "`feature/phone-ble-observer-telemetry` rebuilt, same bar, patch 13 regenerates clean"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Each rebuilt branch verified against the fully stacked tree, not the patch alone"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Old branches retained as `-pre-rebuild` refs"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Re-run the orphan survey afterwards and confirm 0 of 8 branches affected"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Two feature branches still carry stale artifacts that will fail `mid-stack-update.sh`'s drift check
fail-closed the next time their patch is regenerated. `feature/watch-session-crash-guard` had the same
problem and was rebuilt on 2026-08-17 ([[TRIO-038]]); this task covers the remaining two.

Not urgent — nothing is broken in the shipped stack, and neither branch blocks anything today. The
cost is one hard failure whenever someone next touches patch 06 or 13.

## Survey (2026-08-17): 3 of 8 branches affected, 5 clean

| branch | orphaned file | root cause |
|---|---|---|
| `feature/cloud-logging` | `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift` | patch **03** retired during the 0.8.4 sync |
| `feature/phone-ble-observer-telemetry` | `Trio Watch App Extension/Views/ComplicationDebugView.swift` | build-217 rename → `WatchDiagnosticsView.swift` |
| ~~`feature/watch-session-crash-guard`~~ | ~~`ComplicationDebugView.swift`~~ | **fixed 2026-08-17** |

Clean and needing nothing: `ns-richer-settings`, `watch-error-reporting`, `patch-metadata`,
`watch-g7`, `temp-target-default-tab`.

"Orphaned" = a file changed on the branch that no patch in the stack owns. Computed by comparing
`git diff --name-only dev...<branch>` against the union of `+++ b/` paths across `patches/*.patch`.

## Proven method (from [[TRIO-038]])

1. Build a baseline worktree: branch from `dev`, `git am --3way` patches `01 02 05 06 08 09`
   (stop before the patch being rebuilt).
2. Cherry-pick that patch's **own** commits onto it — not the embedded earlier-patch commits, and
   note the merge commits cannot be cherry-picked, so their conflict resolutions must be re-derived.
3. **Verify with an oracle before trusting it:** apply the *committed* patch to the same baseline and
   diff the two trees. They must differ only by work that postdates the committed patch. Anything
   else is a replay error.
4. Regenerate the patch, confirm `Drift check: CLEAN`, run `patch-test.sh`, and verify against the
   **fully stacked** tree — never the patch or branch in isolation.
5. Rename the old branch to `<name>-pre-rebuild` rather than deleting it.

## The trap this method exists to catch

Replaying patch 10's commits verbatim silently reintroduced a **superseded** `g7Sequence`
implementation that [[TRIO-030]] had deliberately excluded during the sync — along with a duplicate
`import G7SensorKit` and `fetchGlucoseManager` injection. Nothing failed; it applied cleanly and
would have shipped a second, differently-windowed population site alongside patch 13's.

Only the oracle diff caught it. **Do not skip step 3.** Expect the same class of problem on these two
branches, since they are stale for the same reasons.

## Notes carried over from acceptance criteria
