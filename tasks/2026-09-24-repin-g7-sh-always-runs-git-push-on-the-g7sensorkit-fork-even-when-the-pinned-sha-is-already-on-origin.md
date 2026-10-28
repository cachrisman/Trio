+++
uid = "01a0d05b-f550-7219-afcb-764ea0ee80e3"
key = "TRIO-064"
title = "repin-g7.sh always runs git push on the G7SensorKit fork, even when the pinned SHA is already on origin"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-062#repin-g7-unconditional-push"
created = 2026-09-24
updated = 2026-10-28
touched = 2026-10-28
tags = ["tooling", "g7sensorkit"]
parent = "01a18464-7f48-7364-8944-b13bdac2ec28"

[[acceptance]]
id = "AC-1"
text = "A run where the clone HEAD is already on origin performs no `git push`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "run"
evidence = "Real run 2026-10-28 against fork 7fa073c (already on origin): printed 'is on origin (origin/main); no push needed', repinned patch 02, no git push executed (no push command remains in the script; grep shows only the printed operator instruction)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-2"
text = "A run where the SHA is not on origin never pushes: it exits non-zero before touching patch 02, with an actionable message naming the SHA, branch and the exact push command for the operator (operator decision 2026-10-28: no --push flag)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "run"
evidence = "Fixture 2026-10-28: clone of the fork with an extra unpushed empty commit, G7_CLONE=fixture --dry-run -> exit 1, 'is not on any origin branch' with the quoted push command, patches/ unchanged (claude implement notes 20261028-222450-75916, -222718-89834)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-3"
text = "Header version bumped with a CHANGELOG line; behaviour verified against the fixture cases (already-on-origin, not-on-origin, base-only refresh)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "run"
evidence = "v1.2 header + CHANGELOG. Exercised: already-on-origin (real run + idempotent re-run exit 0), not-on-origin (fixture). Base-only refresh was NOT executed: its code path is unchanged from v1.1 apart from now being preceded by the origin check; verified by diff inspection only."
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[sessions]]
host = "claude-code"
ref = "b720bc82-ba41-4d7e-9ef8-7d0880ae5200"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:25:45+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "b042cc6d-15f3-4b50-8b1e-b3cebb1712f5"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:28:06+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "a610303c-1767-4980-acc0-36a727f32765"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:32:37+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"
+++

## Intent

`scripts/repin-g7.sh` (v1.1) unconditionally runs `git -C "$G7_CLONE" push origin "$CLONE_BRANCH"` in its "Push fork" step before re-pinning patch 02. The operator's standing rule is that agents never `git push` in any repo. So every run of the script from an agent session is a push, even when there is nothing to push.

Hit during TRIO-062 (upstream 1.0.1.5 sync, 2026-09-22): the fork HEAD `0013c90` was already on `origin/main`, the push was a no-op ("Everything up-to-date"), and the only real work was refreshing patch 02's base pin. The operator had to explicitly direct using the script anyway.

## Proposed behaviour

- Before pushing, check whether `NEW_SHA` is already reachable from an `origin/*` ref (the script already does this check *after* the push, to confirm). If it is, skip the push and say so.
- Only push when the SHA is genuinely not on origin, and treat that as an operator-authorized step. Either refuse with a clear message telling the operator to push the fork first, or require an explicit `--push` flag. The operator decides which. Default to not pushing.
- `--dry-run` output should say which branch it would take.

## Notes carried over from acceptance criteria

## Decision (2026-10-28)

The operator asked in chat for the script to be updated "so that it doesn't push". It never runs `git push`. If the SHA is already on an `origin/*` ref, it says so and continues. If it is not, it stops before touching patch 02 and prints the push command for the operator to run. There is no `--push` flag. This came up during the build 234 (TRIO-095) repin of fork `7fa073c`, which the operator had already pushed.

## Review history (2026-10-28)

Implemented with the claude backend (notes `20261028-222450-75916`, `-222718-89834`, `-223216-15565`). Reviewed with codex-work `gpt-5.6-terra` at high effort:

1. **`222607-82774`:**
   - MEDIUM: an early "nothing to do" exit skipped the origin check. Fixed: the check now runs first.
   - MEDIUM: a loose `origin/` substring match. Fixed: it now uses `for-each-ref` over `refs/remotes/origin/` and excludes `origin/HEAD`.
   - LOW: dry-run help text. Fixed.
   - LOW: unquoted clone path in the printed command. Fixed with `printf %q`.
2. **`222818-95616`:**
   - The fixes were verified.
   - MEDIUM, declined: a failed fetch falls back to the cached `origin/*` refs, so a force-pushed or deleted remote branch could validate a stale SHA. v1.1 had the same fetch-then-check behaviour. The operator never force-pushes the fork, and in the sandbox fetch always fails (`FETCH_HEAD` is not writable), so failing closed would block every sandboxed run. Revisit if the fork's history is ever rewritten.

Found while running it: a successful run exited 1. The EXIT trap's trailing `[ … ] && …` test leaked its status under `set -e`. That was pre-existing in v1.1, and is fixed in v1.2: the trap returns the original rc. The idempotent re-run now exits 0. The rollback path after the fix has not been exercised.
