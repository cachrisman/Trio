+++
uid = "01a144c0-68b2-7139-aa9f-2fa1040fb95a"
key = "TRIO-079"
title = "generate-patch.sh writes provenance trailers itself for feature-branch patches"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "side-2332fe6b/generate-patch-provenance"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
tags = ["tooling", "patches", "provenance"]
files = ["scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "AGENTS.md"]
parent = "01a14459-1abb-73ba-9248-679079504c8e"
priority = 2

[[acceptance]]
id = "AC-1"
text = "Provenance trailer building, _patch_id, _patch_ids_all, _recorded_patch_ids and _recorded_source_branch live in one shared helper sourced by both scripts/generate-patch.sh and scripts/mid-stack-update.sh; neither script keeps its own copy"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: scripts/lib/patch-provenance.sh unchanged since cba818195; both scripts source it and define neither helper (provenance test static checks ok 29-32)"
met_at = 2026-10-16
met_ts = "2026-10-16T15:19:12+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-2"
text = "generate-patch.sh run with -s <feature branch> and no --message-trailers-file writes all seven Trio-Patch-* trailers into the patch header; an explicit --message-trailers-file is used verbatim instead"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: bash scripts/tests/generate-patch-provenance.test.sh 32/32 - case 1 all seven trailers once, correct Base/Tip/Source-Commits/PatchIds, git am applies; case 2/2b explicit file (absolute and relative) used verbatim"
met_at = 2026-10-16
met_ts = "2026-10-16T15:19:13+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-3"
text = "A script-level test generates a throwaway patch from a scratch feature branch, asserts every trailer is present and that _recorded_patch_ids returns the expected ids; its git commits use -c commit.gpgsign=false and it runs inside the Claude Code Bash sandbox"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: scripts/tests/generate-patch-provenance.test.sh 32/32 inside the Claude Code Bash sandbox; hermetic, commit.gpgsign=false on every commit; case 3b now also runs -w to completion"
met_at = 2026-10-16
met_ts = "2026-10-16T15:19:13+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-4"
text = "AGENTS.md (version bumped, changelog entry) says new patches get provenance automatically and trailers are never hand-added"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "ec4626a35: AGENTS.md v25 unchanged since cba818195 ('Provenance is automatic', trailers never hand-added, v25 changelog entry)"
met_at = 2026-10-16
met_ts = "2026-10-16T15:19:13+02:00"
met_by = "unknown"
met_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"

[[acceptance]]
id = "AC-5"
text = "patch-test.sh passes on the current stack after the change; no file under patches/ is modified"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "./scripts/patch-test.sh exit 0 after 7c1fcbca5's changes, patch-audit PASSED (39 pre-existing warnings) on the full stack incl. the untracked patches/15; git status shows no tracked file under patches/ modified"
met_at = 2026-10-16
met_ts = "2026-10-16T14:54:53+02:00"
met_by = "unknown"
met_commit = "7c1fcbca5439bab1c0dc31bb4beb6eabc93a1cf4"

[[sessions]]
host = "claude-code"
ref = "3677ec05-4852-42c0-88e0-beea9462d432"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:49:26+00:00"

[[sessions]]
host = "claude-code"
ref = "1e840b9f-0b93-4128-955d-5b7e1700d460"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:50:45+00:00"

[[sessions]]
host = "claude-code"
ref = "31e25233-594f-48f7-a318-afe50b3b9c0f"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:52:40+00:00"

[[sessions]]
host = "claude-code"
ref = "b49f1ad5-7148-481a-8dd5-4a0016177d12"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T12:59:13+00:00"

[[sessions]]
host = "claude-code"
ref = "20261016-150500-direct-cba8181"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T13:00:29+00:00"

[[reviews]]
run_id = "5b924ecb-8f2e-4b38-b106-482fe691d68b"
model_family = "cursor"
verdict = "fail"
reviewed_commit = "7c1fcbca5439bab1c0dc31bb4beb6eabc93a1cf4"
reviewed_paths = ["AGENTS.md", "scripts/generate-patch.sh", "scripts/lib/patch-provenance.sh", "scripts/mid-stack-update.sh", "scripts/tests/generate-patch-provenance.test.sh"]
recorded_at = "2026-10-16T12:57:43+00:00"

[[reviews]]
run_id = "f7f0ca09-c5e6-435f-8283-d20e16ce5172"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "cba818195e8b5b2dd711771a926c7b049f54a254"
reviewed_paths = ["AGENTS.md", "scripts/generate-patch.sh", "scripts/tests/generate-patch-provenance.test.sh"]
recorded_at = "2026-10-16T13:04:17+00:00"

[[reviews]]
run_id = "17bd644c-3838-4e18-88df-225b631f464c"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "ec4626a35e7cc0df7d8d00fff0788e89abeff495"
reviewed_paths = ["scripts/lib/patch-provenance.sh", "scripts/generate-patch.sh", "scripts/mid-stack-update.sh", "scripts/tests/generate-patch-provenance.test.sh"]
recorded_at = "2026-10-16T13:19:13+00:00"
+++

## Intent

## Problem

Only `scripts/mid-stack-update.sh` builds provenance trailers (`Trio-Patch-Source-Branch`, `-Base`, `-Feature-Tip`, `-Generated`, `-Source-Commits`, `-PatchIds-Note`, `-Source-PatchIds`) and hands them to `generate-patch.sh` via `--message-trailers-file`. AGENTS.md tells agents to run `generate-patch.sh` directly for a NEW patch, and nothing builds trailers on that path, so every new patch ships without provenance. Patches 08, 14 and 15 have no `Trio-Patch-Source-PatchIds` block; patch 15 got a hand-added `Source-Branch` line, which should never happen.

Without PatchIds, `mid-stack-update.sh` treats a patch as legacy: it cannot auto-compute `--cherry-pick` and it blocks `--from-feature-branch`.

Found while regenerating patch 15 for TRIO-077.

## Plan

- Move the trailer building, `_patch_id`, `_patch_ids_all`, `_recorded_patch_ids` and `_recorded_source_branch` into one shared helper sourced by both scripts.
- `generate-patch.sh` writes provenance by default when the source branch is a feature branch and no `--message-trailers-file` was given; an explicit file still wins.
- Keep the TMPDIR-template mktemp style from TRIO-075.
- Script-level test: a throwaway repo with a feature branch, run `generate-patch.sh`, check every trailer is present and `_recorded_patch_ids` reads the ids back.
- AGENTS.md: new patches get provenance automatically; trailers are never hand-added.

Out of scope: regenerating or editing any patch in `patches/`.
