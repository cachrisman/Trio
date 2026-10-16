+++
uid = "01a14428-6c3f-7720-95fd-ce91f8a8865d"
key = "TRIO-075"
title = "Make generate-patch.sh, patch-test.sh and patch-audit.sh work inside the Claude Code Bash sandbox"
status = "review"
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
state = "met"
added_at = 2026-10-16
evidence_kind = "commit"
evidence = "c8851ce78 — grep of the three scripts shows only templated mktemp calls under ${TMPDIR:-/tmp}; the /tmp/pa-am.log and /tmp/pa-ddm.swift writes moved into AUDIT_TMP"
met_at = 2026-10-16
met_ts = "2026-10-16T12:11:01+02:00"
met_by = "unknown"
met_commit = "c8851ce78964bad2b3ccceb1c03ed9494baf1ef3"

[[acceptance]]
id = "AC-2"
text = "Inside the Claude Code Bash sandbox, scripts/generate-patch.sh -n -W -s feature/ns-backfill-on-pull -t dev -d ns-backfill-on-pull --include-files <the 5 TRIO-074 files> produces patches/NN-ns-backfill-on-pull.patch with all 5 files (left uncommitted)"
owner = "agent"
phase = "pre-review"
state = "waived"
added_at = 2026-10-16
reason = "The task-relay shell gate conservatively treats every path argument of a repo script that writes anything as a write target (interpreter_write_targets), so the sandboxed agent run of generate-patch with --include-files <.swift paths> was denied twice (gate-log 12:03). Working as intended, not a script bug. The operator ran the identical command from their terminal; it produced patches/15-ns-backfill-on-pull.patch with all 5 files (280+/5-), left uncommitted, and patch-test passed on it (AC-3). Operator, 2026-10-16 in chat: \"let's just live with it for now... Go ahead and waive AC2\"."
closed_at = 2026-10-16
closed_ts = "2026-10-16T12:38:24+02:00"
closed_by = "charlie"

[[acceptance]]
id = "AC-3"
text = "Inside the Claude Code Bash sandbox, scripts/patch-test.sh passes end to end, including the patch-audit deletion-footprint audit"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "run"
evidence = "scripts/patch-test.sh run inside the Claude Code Bash sandbox on 2026-10-16, dev d459fd2c5 + untracked patches/15-ns-backfill-on-pull.patch, exit 0. Worktree created at /tmp/claude-501/trio-patch-test-*, all 12 patches applied, patch-audit PASSED (39 warnings, sentinel ok), no temp dirs left after cleanup."
met_at = 2026-10-16
met_ts = "2026-10-16T12:21:20+02:00"
met_by = "unknown"
met_commit = "d459fd2c5dfe54b477920a23a248d0c739c43177"

[[acceptance]]
id = "AC-4"
text = "No behaviour change beyond temp locations: a full diff review shows only temp-path edits, and patch-audit.safety-paths / patch-audit.waivers are untouched"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-16
evidence_kind = "commit"
evidence = "c8851ce78 — full diff review: only mktemp templates and patch-audit AUDIT_TMP paths/cleanup changed; patch-audit.safety-paths and .waivers untouched; codex review 870fed6b found no issues"
met_at = 2026-10-16
met_ts = "2026-10-16T12:11:01+02:00"
met_by = "unknown"
met_commit = "c8851ce78964bad2b3ccceb1c03ed9494baf1ef3"

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

[[reviews]]
run_id = "7565b841-c15e-4c06-b7b4-0c122ab48f4a"
model_family = "codex"
verdict = "pass"
reviewed_commit = "c8851ce78964bad2b3ccceb1c03ed9494baf1ef3"
reviewed_paths = ["scripts/generate-patch.sh", "scripts/patch-test.sh", "scripts/patch-audit.sh"]
recorded_at = "2026-10-16T00:00:00+00:00"
+++

## Intent

Generating TRIO-074's patch 16 failed because `scripts/generate-patch.sh` calls bare `mktemp` / `mktemp -d`. On macOS those write to `/var/folders/.../T` and ignore `TMPDIR`, and the Claude Code Bash sandbox denies that (`mkstemp failed ... Operation not permitted`). Running the script unsandboxed was refused by the auto-mode classifier, so patch work from an agent session is blocked.

The same class of problem exists in `scripts/patch-test.sh` (bare `mktemp`, and a worktree created under a hardcoded `/tmp/trio-patch-test-XXXXXX`) and in `scripts/patch-audit.sh`, which `patch-test.sh` runs and which writes its `git am` log and sentinel copy to hardcoded `/tmp/pa-am.log` and `/tmp/pa-ddm.swift`. Reproduced in the sandbox on 2026-10-16: bare `mktemp` fails, `touch /tmp/x` fails, `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"` succeeds.

Fix: every temp file or directory in the three scripts uses an explicit template under `"${TMPDIR:-/tmp}"`, and patch-audit's fixed `/tmp` paths move into a private temp location that its cleanup removes. Script behaviour is otherwise unchanged. `scripts/patch-audit.safety-paths` and `scripts/patch-audit.waivers` are not touched.

**Status 2026-10-16:** script fix committed as c8851ce78 (cursor implement, codex gpt-5.6-terra review 870fed6b: no findings). Verified sandboxed: patch-test.sh creates its worktree in $TMPDIR and applies patches 01–14, and patch-audit.sh runs its full pass and cleans up its temp dirs. Two things are still open. (1) AC-2: the task-relay shell gate denies the generate-patch command twice, because it reads the `--include-files` Swift paths as write targets. Waiting on the operator. (2) AC-3: patch 15 (glucose-alarm-retract-scope) no longer applies to dev 7e91aaea0, because upstream commit 7a56e057b already contains the change. Its conflict is the audit's only error, so a full green patch-test.sh depends on reconciling patch 15.

**AC-2, 2026-10-16:** the operator declined a gate bypass and ran generate-patch in their own terminal. It produced patches/15-ns-backfill-on-pull.patch with all 5 TRIO-074 files and passed the git am dry run on dev. It got number 15 because the patch-15 session had already deleted 15-glucose-alarm-retract-scope.patch. No sandboxed run of generate-patch has happened, because the task-relay shell gate denies it (it reads `--include-files` paths as write targets). AC-2 stays open: an operator waiver, or a gate fix plus a sandboxed run, would close it.
