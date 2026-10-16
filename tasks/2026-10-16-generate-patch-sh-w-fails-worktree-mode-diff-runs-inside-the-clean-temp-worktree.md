+++
uid = "01a144d4-db80-7799-a548-9e4d343654ee"
key = "TRIO-080"
title = "generate-patch.sh -w fails: worktree-mode diff runs inside the clean temp worktree"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "side-2332fe6b/generate-patch-w-worktree-diff"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
tags = ["tooling", "patches"]
files = ["scripts/generate-patch.sh", "scripts/tests/generate-patch-provenance.test.sh"]
parent = "01a14459-1abb-73ba-9248-679079504c8e"
priority = 3

[[acceptance]]
id = "AC-1"
text = "generate-patch.sh -w run on the source branch with uncommitted changes produces a patch that contains those changes"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: bash scripts/tests/generate-patch-provenance.test.sh case 3b runs generate-patch.sh -w to exit 0; patch is non-empty and contains the uncommitted line (ok 24, ok 25; 32/32 passed)"
met_at = 2026-10-16
met_ts = "2026-10-16T15:15:23+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-2"
text = "scripts/tests/generate-patch-provenance.test.sh case 3b asserts the -w patch is generated, contains the uncommitted line and has no Trio-Patch- lines, and the whole test passes inside the Claude Code Bash sandbox"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: case 3b asserts patch generated, contains uncommitted-line, no Trio-Patch- lines (ok 24-28); 32/32 passed in the Claude Code Bash sandbox"
met_at = 2026-10-16
met_ts = "2026-10-16T15:15:24+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-3"
text = "patch-test.sh passes after the change; no file under patches/ is modified"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "./scripts/patch-test.sh at ec4626a35: patch-audit PASSED; commit touches only scripts/generate-patch.sh and scripts/tests/generate-patch-provenance.test.sh, no patches/ file modified"
met_at = 2026-10-16
met_ts = "2026-10-16T15:15:24+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[sessions]]
host = "claude-code"
ref = "8e52c8ac-b315-44a6-970b-f7761e820ebe"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T13:10:55+00:00"

[[reviews]]
run_id = "20e308e5-8cd7-4242-951b-e1ffc42c22da"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"
reviewed_paths = ["scripts/generate-patch.sh", "scripts/tests/generate-patch-provenance.test.sh"]
recorded_at = "2026-10-16T13:15:23+00:00"
+++

## Intent

## Problem

`scripts/generate-patch.sh -w` (and answering yes to the interactive "include staged + unstaged changes" prompt) always fails with `error: No valid patches in input` and then `Failed to apply diff in temporary worktree`.

In worktree mode, `diff_patch_cmd` is `git diff --binary --full-index -M --find-renames "$TARGET_BRANCH"`. It runs only after the script has done `cd "$TEMP_WORKTREE"`, so it diffs the target against the clean temp worktree (a checkout of the target) rather than the operator's working tree, and the diff is empty. Committed mode (`TARGET..SOURCE`) is unaffected because a two-ref diff does not depend on the working tree. Confirmed at 3db1ef7a0, so it predates TRIO-079.

Found while adding the `-w` provenance-skip test for TRIO-079; that test's case 3b checks only the log because generation fails.

## Plan

- Run the worktree-mode patch diff against the original repo (`git -C "$REPO_ROOT"`).
- Extend case 3b of `scripts/tests/generate-patch-provenance.test.sh` to assert the patch is generated, contains the uncommitted change, and carries no `Trio-Patch-` lines.
