+++
uid = "01a0abba-e523-740a-828a-37493311ba00"
key = "TRIO-061"
title = "Patch/build tooling leaked the bot git identity and commit.gpgsign=false into the shared .git/config; scope it per command"
status = "done"
kind = "code"
source = "human"
created = 2026-09-16
updated = 2026-09-23
touched = 2026-09-23
closed = 2026-09-23
first_closed = 2026-09-23
accepted_by = "Charlie"
accepted_at = 2026-09-23
owner = "me"
tags = ["git", "tooling", "signing"]
files = ["scripts/patch-test.sh", "scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "ci/local-build.sh"]

[[sessions]]
host = "claude-code"
ref = "9f357010-f913-4232-923b-493439c12dd9"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:07+00:00"

[[sessions]]
host = "claude-code"
ref = "8e173511-d9b9-4147-869c-8a61f174a45d"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:07+00:00"

[[sessions]]
host = "claude-code"
ref = "02d65c69-c994-4c29-b7b0-9e40f9226d83"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:07+00:00"

[[sessions]]
host = "claude-code"
ref = "43cc15ee-a9f3-45c0-91f4-55176c157570"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:08+00:00"

[[sessions]]
host = "claude-code"
ref = "d65827fd-418d-443e-aad9-6d7ded294124"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:08+00:00"

[[sessions]]
host = "claude-code"
ref = "d95dd4eb-7032-4065-b5d6-15c9c1477d72"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:08+00:00"

[[sessions]]
host = "claude-code"
ref = "786592bd-4dfd-4906-a40c-e06f5e7408c1"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:08+00:00"

[[sessions]]
host = "claude-code"
ref = "ad598297-27f3-4002-971c-dc41eaa60848"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:39:08+00:00"

[[reviews]]
run_id = "667a7eae-9e0a-4fb2-a806-ca2bdcedc7d2"
model_family = "codex"
verdict = "fail"
reviewed_commit = "206cf7517fa9a6bbe5afec83a173fd64ca0ec5cf"
reviewed_paths = ["scripts/patch-test.sh", "scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "ci/local-build.sh"]
recorded_at = "2026-09-16T19:39:08+00:00"

[[reviews]]
run_id = "c3f0130d-25b7-44e0-ab45-0233a430eeea"
model_family = "codex"
verdict = "pass"
reviewed_commit = "206cf7517fa9a6bbe5afec83a173fd64ca0ec5cf"
reviewed_paths = ["scripts/patch-test.sh", "scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "ci/local-build.sh"]
recorded_at = "2026-09-16T19:39:08+00:00"

[[reviews]]
run_id = "452001b2-c799-4b71-9c03-6aee40d55e1a"
model_family = "codex"
verdict = "pass"
reviewed_commit = "5f14fe99aa5ab13db35f3a92bec908d1e0ac48b1"
reviewed_paths = ["ci/local-build.sh", "scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "scripts/patch-test.sh"]
recorded_at = "2026-09-23T17:54:02+00:00"

[tldr]
source_digest = "sha256:19498ad24673724f3198e88a6e1b2a9173c819e895ed341af38a7ae9f970d5b2"
prompt_version = 2
purpose = "Fixes: build and patch scripts leak bot identity and disable signing into the shared .git/config."
generated = "2026-09-16T20:47:45.043925+00:00"
+++

## TL;DR

- **Fixes:** build and patch scripts leak bot identity and disable signing into the shared .git/config.
- **State:** review. Authored by claude. 2 reviews: codex fail, codex pass.
- **Open:** 2 of 5 criteria unmet

<!-- prose -->
The build and patch scripts leak the bot identity and disable signing into the shared .git/config. Claude authored the fix, which is in review with a pass and a fail from codex. Three of five criteria are met, with the remaining two pending.
<!-- /tldr -->

## Intent

Operator instruction 2026-09-16: the bot identity must apply only to the patch tooling's throwaway commits; commits the operator makes must carry their own name/email and be signed by them.

## Cause
scripts/patch-test.sh ran 'git config user.name/user.email' inside its temporary worktree and ci/local-build.sh ran 'git config user.name/user.email/commit.gpgsign false' inside the build worktree. Linked worktrees share the main repo's .git/config, so every build or patch-test rewrote the operator's identity to 'Trio Build Bot' / 'Trio Patch Bot' and disabled signing for all later commits in Trio, Trio-dev and every worktree (seen today: the TRIO-060 commit landed as Trio Build Bot, unsigned; the upstream-PR amend landed as Trio Patch Bot). The leaked commit.gpgsign=false had also been masking that the tooling's own commits (git am, cherry-pick, squash/sync commits) would otherwise inherit the operator's 1Password-backed signing, which hangs when 1Password is locked.

## Fix
- Removed the leaked values from the shared config (git config --unset user.name / user.email / commit.gpgsign); identity and signing now resolve from ~/.gitconfig.
- No 'git config' writes remain in the tooling. Every commit-producing call (commit, am, cherry-pick) in patch-test.sh (v1.2), generate-patch.sh, mid-stack-update.sh (v1.12) and ci/local-build.sh passes '-c user.name=<bot> -c user.email=<bot> -c commit.gpgsign=false' per command (GIT_BOT array). A first attempt used 'git config --worktree' + extensions.worktreeConfig; dropped after review because --worktree silently falls back to --local when the extension is off and enabling it is a repo-wide change.
- patch-test.sh's 'sync patches for test' commit ran before its old identity block; now self-contained.
- ci/local-build.sh's 'git merge upstream/dev' on the real dev branch is deliberately left to the operator's identity/signing.

## Verification
- patch-test.sh run twice after the change: green, shared config stays clean, no config.worktree files left behind; effective user.name resolves to ~/.gitconfig.
- Codex (gpt-5.6-terra high): round 1 — 2 high / 2 medium (am/cherry-pick sites missed; --worktree fallback; extension enabling; author.* precedence, the last accepted as theoretical); round 2 after switching to per-command -c: CLEAN.
- Not run: a real build (next build exercises ci/local-build.sh's git am path).

## Acceptance criteria
- [x] Shared .git/config carries no user.*/commit.gpgsign
- [x] No 'git config user.*|commit.*|extensions.*' writes in scripts/ or ci/
- [x] patch-test.sh green with the shared config unchanged afterwards
- [ ] Next TestFlight build: patches apply (bot author on the throwaway commits), operator's identity untouched afterwards
- [ ] Operator: commit the four staged files


**Review anchor corrected (2026-09-23):** the original codex pass was recorded against `206cf7517` because it reviewed the uncommitted working tree; the change was then committed as `5f14fe99a`, so acceptance refused it as stale. Verified `5f14fe99a` is the only commit touching the four files since that anchor (53 later commits left them untouched, working tree matches HEAD), then re-ran the codex review with `--commit 5f14fe99a`: CLEAN, 0 findings, recorded as pass against that commit. No content changed.
