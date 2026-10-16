+++
uid = "01a14428-6c3f-7720-95fd-ce91f8a8865d"
key = "TRIO-075"
title = "Make generate-patch.sh, patch-test.sh and patch-audit.sh work inside the Claude Code Bash sandbox"
status = "in-progress"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-074#patch16-mktemp-sandbox"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
priority = 2

[[acceptance]]
id = "AC-1"
text = "Every mktemp call in scripts/generate-patch.sh, scripts/patch-test.sh and scripts/patch-audit.sh uses an explicit template under \"${TMPDIR:-/tmp}\", and no script writes to a hardcoded /tmp path"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-2"
text = "Inside the Claude Code Bash sandbox, scripts/generate-patch.sh -n -W -s feature/ns-backfill-on-pull -t dev -d ns-backfill-on-pull --include-files <the 5 TRIO-074 files> produces patches/16-ns-backfill-on-pull.patch (left uncommitted)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-3"
text = "Inside the Claude Code Bash sandbox, scripts/patch-test.sh passes end to end, including the patch-audit deletion-footprint audit"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-4"
text = "No behaviour change beyond temp locations: a full diff review shows only temp-path edits, and patch-audit.safety-paths / patch-audit.waivers are untouched"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[sessions]]
host = "claude-code"
ref = "d6849c06-4c4c-4fff-9df2-a8dfc2f00bb2"
model_family = "cursor"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T10:02:40+00:00"

[[reviews]]
run_id = "870fed6b-bf1b-4b34-9d9d-1c78ebbf3a98"
model_family = "codex"
verdict = "pass"
reviewed_commit = "7e91aaea06270984bc0a631993b51ab9e24c7c48"
reviewed_paths = ["scripts/generate-patch.sh", "scripts/patch-test.sh", "scripts/patch-audit.sh"]
recorded_at = "2026-10-16T00:00:00+00:00"
+++

## Intent

Generating TRIO-074's patch 16 failed because `scripts/generate-patch.sh` calls bare `mktemp` / `mktemp -d`. On macOS those write to `/var/folders/.../T` and ignore `TMPDIR`, and the Claude Code Bash sandbox denies that (`mkstemp failed ... Operation not permitted`). Running the script unsandboxed was refused by the auto-mode classifier, so patch work from an agent session is blocked.

The same class of problem exists in `scripts/patch-test.sh` (bare `mktemp`, and a worktree created under a hardcoded `/tmp/trio-patch-test-XXXXXX`) and in `scripts/patch-audit.sh`, which `patch-test.sh` runs and which writes its `git am` log and sentinel copy to hardcoded `/tmp/pa-am.log` and `/tmp/pa-ddm.swift`. Reproduced in the sandbox on 2026-10-16: bare `mktemp` fails, `touch /tmp/x` fails, `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"` succeeds.

Fix: every temp file or directory in the three scripts uses an explicit template under `"${TMPDIR:-/tmp}"`, and patch-audit's fixed `/tmp` paths move into a private temp location that its cleanup removes. Script behaviour is otherwise unchanged. `scripts/patch-audit.safety-paths` and `scripts/patch-audit.waivers` are not touched.
