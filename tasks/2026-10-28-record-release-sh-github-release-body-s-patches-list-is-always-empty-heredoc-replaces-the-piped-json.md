+++
uid = "01a184a9-288c-74fd-bcb6-0610480b3e0d"
key = "TRIO-097"
title = "record-release.sh: GitHub release body's Patches list is always empty (heredoc replaces the piped JSON)"
status = "review"
kind = "code"
source = "human"
created = 2026-10-28
updated = 2026-10-28
touched = 2026-10-28
tags = ["ci", "release"]

[[acceptance]]
id = "AC-1"
text = "generate_release_body lists every patch: for the current patches/ (17) the body has one '- NN-…' line per patch with subject, sha and date, and no 'error parsing patches' on stderr"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "2026-10-28, uncommitted scripts/record-release.sh: scratchpad repro (sources the script, stubs task notes and stage summary, calls generate_release_body with get_patch_metadata patches): before the fix 'patch lines in body: 0' plus '(error parsing patches: Expecting value…)'; after it 'metadata entries: 17', 'patch lines in body: 17', no error, lines like '- 01-ns-richer-settings.patch — [PATCH] feat: ns-richer-settings (from 4c5dc3d50b38, Wed, 16 Sep 2026 13:18:02 +0200)'"
met_at = 2026-10-28
met_ts = "2026-10-28T23:40:15+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-2"
text = "If the patch JSON cannot be parsed, the body shows a visible '(could not list patches: …)' line instead of an empty list; the error still goes to stderr"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "2026-10-28: generate_release_body 1 2 c t dev a b 'not json' (helpers stubbed) ends with 'Patches:' then '(could not list patches: Expecting value: line 1 column 1 (char 0))'; the stderr line is kept"
met_at = 2026-10-28
met_ts = "2026-10-28T23:40:15+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-3"
text = "No other change to the release body or to record-release.sh behaviour; bash -n passes"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "git diff: only the formatter block in generate_release_body changes (env var PATCHES_JSON + python3 -, import os, json.loads, one stdout line in except); bash -n passes; codex-work terra review 20261028-233928 found no other pipe-plus-heredoc and no bugs"
met_at = 2026-10-28
met_ts = "2026-10-28T23:40:15+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-4"
text = "The next recorded release (build 235) shows the full Patches list on GitHub"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28

[[sessions]]
host = "claude-code"
ref = "b8e3beaa-c6c4-443c-9d30-a0c821279c16"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T22:38:45+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[reviews]]
run_id = "b39bc9d7-a0fd-4e9b-9d6b-e45e530810c3"
model_family = "codex"
verdict = "pass"
reviewed_commit = "6737274a9e432e76599fc24e2fe2c52775391092"
reviewed_paths = ["scripts/record-release.sh"]
recorded_at = "2026-10-28T22:40:14+00:00"
+++

## Intent

Every GitHub release that `scripts/record-release.sh` records has an empty "Patches:" list. During Record Release the step prints `(error parsing patches: Expecting value: line 1 column 1 (char 0))` to stderr. Seen on build 233 (noted in its task) and build 234 (2026-10-28). The release manifest asset still lists the patches; only the release body is wrong.

## Cause

`generate_release_body` runs `echo "$patches_json" | python3 <<'PYTHON_EOF' … PYTHON_EOF`. The heredoc replaces python3's stdin, so the pipe is discarded. Python reads the heredoc as its script, and `json.load(sys.stdin)` then sees an empty stream. It is the only pipe-plus-heredoc in `scripts/` and `ci/`.

Reproduced: sourcing the script and calling `generate_release_body` with `get_patch_metadata patches` (17 entries) gives 0 patch lines in the body.

## Fix

Pass the JSON to the Python formatter some way that does not collide with the script on stdin (environment variable, or `python3 -c`). If parsing still fails, the body should say so on its own line instead of an empty list.

Operator request in chat 2026-10-28: "File and fix that glitch".
