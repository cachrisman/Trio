+++
uid = "01a0aa44-4f49-70af-a2cd-01be6faa62ba"
key = "TRIO-060"
title = "ci/local-build.sh --task <KEY>: append attempts, stage summary and release URL to the build epic automatically"
status = "done"
kind = "code"
source = "agent-discovered"
source_ref = "agents-md-v22-build-tasks"
created = 2026-09-16
updated = 2026-09-16
touched = 2026-09-16
closed = 2026-09-16
first_closed = 2026-09-16
accepted_by = "Charlie"
accepted_at = 2026-09-16
owner = "me"
tags = ["build-tooling", "tasks"]
files = ["ci/local-build.sh"]

[[sessions]]
host = "claude-code"
ref = "41b10b61-b74f-4f43-b9ef-4ceb0ad09779"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "ef7c1c20-5171-497e-8f7e-a97b0b3cb453"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "d729729e-b9a9-4d9b-9491-b46fded66729"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "6eaf21e8-9095-4e0b-a34c-2453af6c2956"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "45c5d385-4ea2-4293-afc9-82ee93bd01f9"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "b0c4cbe9-22ab-4804-86ec-2534c9e1bc72"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:31+00:00"

[[sessions]]
host = "claude-code"
ref = "4604b7bc-68a9-4cb0-b8fa-16eed51cd275"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T19:10:32+00:00"

[[reviews]]
run_id = "787b1950-9762-4b53-931e-ea2535d878e9"
model_family = "codex"
verdict = "fail"
reviewed_commit = "1095b0957b47a10ec043a0fc2458d29d4cb7d4bc"
reviewed_paths = ["scripts/build-task-notes.py", "scripts/record-release.sh", "ci/local-build.sh"]
recorded_at = "2026-09-16T19:10:32+00:00"

[[reviews]]
run_id = "020e4018-06db-4ec6-b03c-2135061b405d"
model_family = "codex"
verdict = "fail"
reviewed_commit = "1095b0957b47a10ec043a0fc2458d29d4cb7d4bc"
reviewed_paths = ["scripts/build-task-notes.py", "scripts/record-release.sh", "ci/local-build.sh"]
recorded_at = "2026-09-16T19:10:32+00:00"

[[reviews]]
run_id = "840ccd1c-b146-4c9d-9d7a-9d6535724bdf"
model_family = "codex"
verdict = "fail"
reviewed_commit = "1095b0957b47a10ec043a0fc2458d29d4cb7d4bc"
reviewed_paths = ["ci/local-build.sh"]
recorded_at = "2026-09-16T19:10:32+00:00"

[[reviews]]
run_id = "2238ac47-ee1a-4edc-bf8d-abe59341afca"
model_family = "codex"
verdict = "pass"
reviewed_commit = "1095b0957b47a10ec043a0fc2458d29d4cb7d4bc"
reviewed_paths = ["ci/local-build.sh", "scripts/record-release.sh", "scripts/build-task-notes.py"]
recorded_at = "2026-09-16T19:14:46+00:00"

[[reviews]]
run_id = "637ca106-5678-4383-a13a-bd5c2f8dea31"
model_family = "codex"
verdict = "pass"
reviewed_commit = "206cf7517fa9a6bbe5afec83a173fd64ca0ec5cf"
reviewed_paths = ["ci/local-build.sh", "scripts/record-release.sh", "scripts/build-task-notes.py"]
recorded_at = "2026-09-16T19:41:19+00:00"
+++

## Intent

AGENTS.md v22 makes a build epic mandatory per build (template: TRIO-059) and asks the agent to hand-copy the stage summary, log path, patch sha256 list and release URL into it. Everything in that list is already printed by ci/local-build.sh, so the copy is pure transcription and will be skipped or drift under time pressure — the same failure mode the task-evidence rules in ~/.claude/CLAUDE.md describe.

Proposal: a --task <KEY> flag on ci/local-build.sh. At start it appends an '## Attempt N' line (command line, dev SHA, upstream base, Xcode version, log path) via 'task-relay tasks body <KEY> --append-file -'; on exit it appends outcome + failing stage (from stage-summary.txt), and on success the stage table, the release URL(s) from the Record Release stage and the TestFlight result. Read-only w.r.t. frontmatter — status changes stay with the agent/operator. Optionally: the record-release step includes the epic key and its '## Contains' keys in the GitHub release body so the release and the task index point at each other from both sides.

## Acceptance criteria
- [x] --task appends attempt start/end blocks through the task-relay CLI (never edits the file directly); absent flag = today's behaviour
- [x] Stage summary table and release URL land in the epic on success; failing stage + cause on failure
- [x] Release notes carry the epic key (and child keys when present)
- [x] AGENTS.md 'Build tasks' updated to say which fields are automatic


## Design (agreed direction, 2026-09-16)

Operator asked whether record-release could use task bodies / the epic body as the release body. Decision: share, but split by source of truth — the script knows the *facts*, the task graph knows the *meaning*.

1. **Script → epic (facts).** `ci/local-build.sh --task <EPIC>`: at attempt start append `## Attempt N` (command line, dev SHA, upstream base, Xcode version, log path); at attempt end append outcome + failing stage (from stage-summary.txt). On success append the text `scripts/record-release.sh:generate_release_body` already produces (version/build/tag, upstream + fork SHAs, patch list with subjects, stage summary) plus the release URL(s) and TestFlight result. All via `task-relay tasks body <EPIC> --append-file -`; never edit frontmatter or status.

2. **Tasks → release (meaning).** `scripts/record-release.sh --task <EPIC>`: read the epic's `## Contains` keys; for each child task read its title and an optional `## Release note` section (one user-facing paragraph); render a **"What's in this build"** section at the top of the release body, one bullet per child (`TRIO-nnn — <release note or title>`), then the existing facts. Put the epic key and child keys in the body and in the manifest JSON so release ↔ tasks link both ways. Children without `## Release note` fall back to the title.

3. **Not doing:** using the epic body wholesale as the release body — at Record Release time the epic is incomplete (attempts/stage summary are written afterwards) and it carries internal content (acceptance checkboxes, operator to-dos, known-issue pointers) that is not release material; and it would invert the source of truth for the build facts.

4. **Degradation:** no `--task`, or an epic without `## Contains` → body identical to today's. Task files are TOML-frontmatter markdown; section extraction is a small Python helper inside record-release.sh (no new dependency). Optional later: `record-release.sh --resync <EPIC>` to re-render the draft private release body after the epic is accepted.

5. **Convention to add to AGENTS.md "Build tasks" when this lands:** child tasks that ship user-visible behaviour carry a `## Release note` paragraph; the epic's `## Contains` must be complete before the build is launched (step 0), because that is what the release body is rendered from.


## Implementation (2026-09-16)

- `scripts/build-task-notes.py` (new): renders "What's in this build:" bullets (markdown) or JSON from the epic's `## Contains` children and their `## Release note` sections; falls back to titles; searches `tasks/` and `tasks/archive/**`. Verified against TRIO-059.
- `scripts/record-release.sh` v1.4.0: `BUILD_TASK_KEY` (validated `^[A-Z][A-Z0-9]*-[0-9]+$`) and `TASKS_DIR` (default resolved next to the script, never cwd — the script runs inside the build worktree); inserts the block after the title line and a `Build task:` line after `Tag:`; manifest gains `tasks.{epic,contains}` only when a key is set (no-key manifest byte-identical); key reaches the manifest Python via env (`RR_BUILD_TASK_KEY`), never interpolated. Also fixed: two progress echoes inside `record_private_backup_release()` leaked into the captured private-release URL (stdout → stderr).
- `ci/local-build.sh --task <KEY>`: `task_record` (only write path: `task-relay tasks body KEY --repo ROOT --append-file -`), `task_record_attempt_start` right after the log tee (pre-sync SHAs, provisional `EXIT` trap), `- dev after upstream sync` bullet when the SHA changed, `task_record_attempt_end` (guarded, subshell under `set +e`) called from `cleanup()` and from both `--release-only` exits; release URLs read from a synchronously tee'd `RECORD_RELEASE_OUT` (guarded mktemp), build number/TestFlight from the log, stage table from `stage-summary.txt`; failed runs get the failing stage + last error lines (case-insensitive). No-`--task` behaviour unchanged.
- AGENTS.md v22 "Build tasks" updated: `--task` is mandatory on every run, `## Contains` complete before launch, `## Release note` on children.
- Verification: `bash -n`, shellcheck count unchanged (11 pre-existing), `generate_release_body` exercised with real/absent/bogus keys, `run_task_notes_helper json` → `[TRIO-055, TRIO-056]`; local-build recording functions exercised against a scratch copy of `tasks/` with the real build-226 log (success block) and end-to-end by running the script from a scratch tree with `--release-only` + missing IPA (attempt start + FAILED outcome with the real ERROR line). Not run: a real build with `--task` — first real use is the next build.
- Reviews: codex ×4 (gpt-5.6-terra high): 5 → 2 → 3 findings fixed across rounds, final pass CLEAN. Deferred, recorded here: (a) SIGTERM/SIGHUP can let the EXIT trap observe exit 0 and record success — pre-existing property of `cleanup`'s trap, out of scope; (b) argument combinations rejected before logging record nothing — by design.
- Claude backend stalled on the dirty-target guard for every follow-up run on an already-edited file; each note's diff was applied onto a HEAD copy, verified as working-file + fix, and installed (feedback logged ×4).
- Repo is `agent.signing = deny`: changes staged, proposed message at `.unattended-run/../proposed-commit-trio-060.txt` — operator commits.
