+++
uid = "01a1846c-1d2b-75ab-a30f-c190a1d55fed"
key = "TRIO-096"
title = "patch-audit.sh: git am inherits the operator's commit signing and fails when 1Password is locked"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "repin-g7-2026-10-28-patch-audit-am-signing"
created = 2026-10-28
updated = 2026-10-28
touched = 2026-10-28
tags = ["tooling", "patches"]
priority = 2
parent = "01a18464-7f48-7364-8944-b13bdac2ec28"

[[acceptance]]
id = "AC-1"
text = "patch-audit.sh's git am passes a per-command bot identity and commit.gpgsign=false (same as patch-test.sh's GIT_BOT); no git config writes"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Diff: GIT_BOT array (bot identity, commit.gpgsign=false) passed to patch-audit.sh's git am; no git config writes (claude implement note 20261028-223042-7530)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-2"
text = "patch-test.sh (including patch-audit) passes with the operator's 1Password locked"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Same session, 2026-10-28: before the fix patch-audit failed on 01 with '1Password: failed to fill whole buffer'; after it, the repin run's patch-test.sh + patch-audit passed with 1Password still locked"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:06+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[sessions]]
host = "claude-code"
ref = "9f1bce33-430f-45d7-9996-19149282e72c"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:31:06+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"
+++

## Intent

`scripts/patch-audit.sh:103` applies each patch with `git -c submodule.recurse=false am --3way` in its temp worktree. It sets no identity and does not disable signing, so it inherits the operator's global config: `commit.gpgsign=true` through 1Password `op-ssh-sign`. When 1Password is locked, `git am` fails with `error: 1Password: failed to fill whole buffer` / `fatal: failed to write commit object`. patch-audit then reports "failed to apply" and a FAILED audit, which reads as a patch-safety STOP.

`patch-test.sh` fixed the same problem in v1.2: a `GIT_BOT` array (bot identity plus `commit.gpgsign=false`) passed per command. The operator's rule is that a script or test that commits must never inherit the operator's signing config.

Hit on 2026-10-28 during the build 234 (TRIO-095) repin of patch 02 to fork `7fa073c`. Every patch applied in patch-test, the audit failed on 01 for this reason, and repin-g7.sh rolled patch 02 back.

## Fix

Pass the same per-command bot identity and `commit.gpgsign=false` to patch-audit's `git am`. Change nothing else.

## Review

Reviewed with codex-work `gpt-5.6-terra` at high effort (`.task-relay/notes/20261028-223333-25132-codex-work-review.md`): no findings.
