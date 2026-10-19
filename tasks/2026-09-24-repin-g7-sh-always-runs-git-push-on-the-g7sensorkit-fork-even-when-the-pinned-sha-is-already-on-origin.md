+++
uid = "01a0d05b-f550-7219-afcb-764ea0ee80e3"
key = "TRIO-064"
title = "repin-g7.sh always runs git push on the G7SensorKit fork, even when the pinned SHA is already on origin"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-062#repin-g7-unconditional-push"
created = 2026-09-24
updated = 2026-09-26
touched = 2026-09-26
tags = ["tooling", "g7sensorkit"]

[[acceptance]]
id = "AC-1"
text = "A run where the clone HEAD is already on origin performs no `git push`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "A run where the SHA is not on origin does not push unless explicitly allowed (mechanism per operator decision), and fails with an actionable message otherwise"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Header version bumped with a CHANGELOG line; behaviour verified against the fixture cases (already-on-origin, not-on-origin, base-only refresh)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

`scripts/repin-g7.sh` (v1.1) unconditionally runs `git -C "$G7_CLONE" push origin "$CLONE_BRANCH"` in its "Push fork" step before re-pinning patch 02. The operator's standing rule is that agents never `git push` in any repo. So every run of the script from an agent session is a push, even when there is nothing to push.

Hit during TRIO-062 (upstream 1.0.1.5 sync, 2026-09-22): the fork HEAD `0013c90` was already on `origin/main`, the push was a no-op ("Everything up-to-date"), and the only real work was refreshing patch 02's base pin. The operator had to explicitly direct using the script anyway.

## Proposed behaviour

- Before pushing, check whether `NEW_SHA` is already reachable from an `origin/*` ref (the script already does this check *after* the push, to confirm). If it is, skip the push and say so.
- Only push when the SHA is genuinely not on origin, and treat that as an operator-authorized step. Either refuse with a clear message telling the operator to push the fork first, or require an explicit `--push` flag. The operator decides which. Default to not pushing.
- `--dry-run` output should say which branch it would take.

## Notes carried over from acceptance criteria
