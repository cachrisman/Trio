+++
uid = "01a0aa02-c25f-71fa-b1da-599f65cf87a3"
key = "TRIO-057"
title = "mid-stack-update.sh: provenance trailer emits unindented PatchIds for merge commits, truncating the recorded id list"
status = "done"
kind = "code"
source = "agent-discovered"
source_ref = "codex-review-20260916-133420-23959"
created = 2026-09-16
updated = 2026-09-24
touched = 2026-09-24
closed = 2026-09-24
first_closed = 2026-09-24
accepted_by = "Charlie"
accepted_at = 2026-09-24
owner = "me"
tags = ["patch-tooling", "provenance"]
files = ["scripts/mid-stack-update.sh"]

[[sessions]]
host = "claude-code"
ref = "43afa4d4-e539-4e5c-a990-4b6709144e80"
model_family = "claude"
started = 2026-09-23
role = "author"
started_at = "2026-09-23T18:18:30+00:00"

[[sessions]]
host = "claude-code"
ref = "4bbe49d7-5056-48cd-b100-778da11ff120"
model_family = "claude"
started = 2026-09-23
role = "author"
started_at = "2026-09-23T18:18:30+00:00"

[[sessions]]
host = "claude-code"
ref = "04133e02-3b3b-4446-8b53-af62777cca17"
model_family = "claude"
started = 2026-09-23
role = "author"
started_at = "2026-09-23T18:18:30+00:00"

[[sessions]]
host = "claude-code"
ref = "8c654654-eb7d-4604-8dc7-86e3e3d42db7"
model_family = "claude"
started = 2026-09-23
role = "author"
started_at = "2026-09-23T18:18:30+00:00"

[[reviews]]
run_id = "0573e865-76bf-4e35-ae54-9a7fd41c7ee3"
model_family = "codex"
verdict = "fail"
reviewed_commit = "92ab21640986a4d7e7c876e23e3811a6b178e7d0"
reviewed_paths = ["scripts/mid-stack-update.sh"]
recorded_at = "2026-09-23T18:18:30+00:00"

[[reviews]]
run_id = "0fe2bae0-6665-49da-a0e6-fdca46974324"
model_family = "codex"
verdict = "pass"
reviewed_commit = "92ab21640986a4d7e7c876e23e3811a6b178e7d0"
reviewed_paths = ["scripts/mid-stack-update.sh"]
recorded_at = "2026-09-23T18:18:30+00:00"

[[reviews]]
run_id = "f9827a3a-3876-4dec-9045-4b02cc4264ae"
model_family = "codex"
verdict = "pass"
reviewed_commit = "3c3360a7377f1593bcd08ec5df6c6950b570837a"
reviewed_paths = ["scripts/mid-stack-update.sh"]
recorded_at = "2026-09-23T19:47:07+00:00"
+++

## Intent

Found by codex review of the 1.0.0.3 patch regeneration (note .task-relay/notes/20260916-133420-23959-codex-review.md). In scripts/mid-stack-update.sh the Trio-Patch-Source-PatchIds trailer is built by piping each source commit through _patch_id and prefixing one space. For merge commits on the feature branch (e.g. 'Merge dev (...) into feature/...'), _patch_id returns more than one line, so only the first gets the indent; the rest are emitted unindented (patch 10: 10e82116…, 8fe7265c…, 77ce1d1b…, 4bc3746a…; patch 13 likewise). _recorded_patch_ids() stops capturing at the first line that is not indented hex, so every id after that point is invisible to the cherry-pick-viability gate and drift checks — those source commits are treated as unrecorded on the next update. Pre-existing: the same unindented lines are in the patches committed at 2516b23c4 (TRIO-052 regeneration); no effect on built code.

## Acceptance criteria
- [ ] _patch_id (or its caller) yields exactly one id per source commit — skip merge commits or take the combined-diff id deliberately, documented in the script header
- [ ] _recorded_patch_ids() tolerates/flags a malformed block instead of silently truncating
- [ ] Patches 10 and 13 regenerated (no hand-edits) and the trailer parses fully; patch-test.sh passes


## Committed and validated in a real regeneration (2026-09-23)

Committed to dev as `3c3360a73`. First live exercise came immediately after, regenerating patch 09 for TRIO-058:

- Patch 09's new trailer: **38 well-formed ids, 0 unindented lines, 0 parser warnings**, plus the new `Trio-Patch-PatchIds-Note:` line. Before the fix the same patch carried 39 ids of which 7 were malformed and only 31 were visible to the parser.
- The cherry-pick gate behaved correctly rather than auto-allowing: it resolved 1 commit to cherry-pick and completed in `--cherry-pick` mode.
- `patch-test.sh` + deletion-footprint audit PASSED on the full 10-patch stack.

Remaining legacy trailers (patches 05, 10, 13) are handled by the legacy-compatibility path and will clean themselves the next time each patch is regenerated; no action needed.
