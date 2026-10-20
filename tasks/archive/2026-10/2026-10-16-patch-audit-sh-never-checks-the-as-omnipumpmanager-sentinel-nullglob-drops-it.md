+++
uid = "01a1462a-7e20-7475-9858-6c38da382840"
key = "TRIO-081"
title = "patch-audit.sh never checks the 'as? OmniPumpManager' sentinel (nullglob drops it)"
status = "done"
kind = "code"
source = "agent-discovered"
source_ref = ".task-relay/notes/20261016-211816-36896-cursor-review.md#HIGH-nullglob-sentinel"
created = 2026-10-16
updated = 2026-10-20
touched = 2026-10-20
closed = 2026-10-20
first_closed = 2026-10-20
accepted_by = "charlie"
accepted_at = 2026-10-20
accepted_ts = "2026-10-20T19:31:16+02:00"
priority = 2
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"

[[acceptance]]
id = "AC-1"
text = "Every symbol in SENTINEL_SYMBOLS is grepped, including 'as? OmniPumpManager', regardless of nullglob or files in the worktree; the audit fails if the number of symbols checked differs from the number declared"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "041223aa4 — sentinel greps every SENTINEL_SYMBOLS entry as a fixed string from an IFS='|' array and fails if checked != declared; codex-work review PASS cfb87f4a"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:27+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[acceptance]]
id = "AC-2"
text = "Demonstrated: with a copy of DeviceDataManager.swift missing 'as? OmniPumpManager' the sentinel reports MISSING; with the real file it passes; full patch-test passes"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "run"
evidence = "2026-10-19: harness ran the committed sentinel block of scripts/patch-audit.sh (lines 146-165 at 041223aa4, unmodified) against fixtures of DeviceDataManager.swift from dev HEAD: real file -> pass; copy without 'as? OmniPumpManager' -> MISSING + fail; copy without 'DeviceCatalog.pumpEntry(forPersistedIdentifier' -> MISSING + fail; symbol list with trailing '|' -> 'checked 3 of 4' + fail. Full scripts/patch-test.sh over patches 01-18 PASSED with sentinel present."
met_at = 2026-10-19
met_ts = "2026-10-19T21:54:08+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[sessions]]
host = "claude-code"
ref = "39eef9c5-f625-4d35-b2cd-b8acaf5bcc16"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:17:33+00:00"

[[sessions]]
host = "claude-code"
ref = "20261019-213149-direct-041223a"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:31:49+00:00"

[[reviews]]
run_id = "cfb87f4a-74ce-44ac-b2a4-63d316a76fca"
model_family = "codex"
verdict = "pass"
reviewed_commit = "041223aa"
reviewed_paths = ["scripts/patch-audit.sh"]
recorded_at = "2026-10-19T19:32:00+00:00"
+++

## Intent

The deletion-footprint audit's Omnipod sentinel silently checks only two of its three symbols. `scripts/patch-audit.sh` turns on `shopt -s nullglob` (line 89) and later loops `for sym in $SENTINEL_SYMBOLS` with `IFS='|'` (lines 147-148), unquoted. The third token, `as? OmniPumpManager`, contains `?`, a glob metacharacter. With no matching file in the worktree, nullglob removes the word, so it is never grepped and a patch that deleted it would pass.

Reproduced 2026-10-16 in plain bash with the same `SENTINEL_SYMBOLS`, `IFS` and `nullglob`: only `func pumpManagerTypeByIdentifier` and `DeviceCatalog.pumpEntry(forPersistedIdentifier` are visited.

Found by the cursor review of TRIO-051 (note `.task-relay/notes/20261016-211816-36896-cursor-review.md`, run 71a17fad). Present since the guard was added in f3e4978f7 (2026-06-18); TRIO-051's change did not introduce it. This sentinel guards the dropped-pod failure class (DeviceDataManager Omnipod identifier migration), so a silent false negative matters.

Likely fix: disable globbing around the loop (`set -f` / `set +f`), or split into an array with `IFS='|' read -r -a`, and add a self-check that the number of symbols checked equals the number declared. The same review also noted (MEDIUM) that `git diff-tree --numstat` runs without rename detection, so a moved safety file reads as a full deletion; consider it here or separately.


Landed with build 233 (TRIO-083), 2026-10-19. Scripts only, not in the app.
