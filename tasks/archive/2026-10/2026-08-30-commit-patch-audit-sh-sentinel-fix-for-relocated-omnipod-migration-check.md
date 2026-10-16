+++
uid = "01a0520e-830a-76bc-82a6-a92799489e58"
key = "TRIO-051"
title = "Commit patch-audit.sh sentinel fix for relocated Omnipod migration check"
status = "done"
kind = "code"
source = "human"
created = 2026-08-30
updated = 2026-10-16
touched = 2026-10-16
closed = 2026-10-16
first_closed = 2026-10-16
accepted_by = "charlie"
accepted_at = 2026-10-16
accepted_ts = "2026-10-16T21:32:00+02:00"
owner = "me"
tags = ["patches", "tooling", "patch-audit"]

[[acceptance]]
id = "AC-1"
text = "`scripts/patch-audit.sh` diff reviewed one more time before committing — re-checked immediately pre-commit, matched the earlier-verified spec exactly"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-2"
text = "Committed to `dev` as a normal commit (not a patch), with the operator's sign-off — `5dd6fb1d3`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-3"
text = "`scripts/patch-test.sh` re-confirmed green post-commit — PASSED, 31 warnings"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[sessions]]
host = "claude-code"
ref = "interactive-session-2026-08-30-upstream-sync"
model_family = "claude"
started = 2026-08-30
role = "author"
started_at = "2026-08-30T09:45:00+00:00"

[[reviews]]
run_id = "71a17fad-4c14-453e-8a50-639cfb790399"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
reviewed_paths = ["scripts/patch-audit.sh"]
recorded_at = "2026-10-16T00:00:00+00:00"
+++

## Intent

Surfaced during [[TRIO-050]] (2026-08-30 upstream sync): `scripts/patch-audit.sh`'s deletion-footprint
sentinel started failing after merging 37 upstream commits, because upstream's device-picker refactor
(`9121d70f1`, `2f2994bf8`) relocated the Omnipod legacy-identifier fallback out of
`Trio/Sources/APS/DeviceDataManager.swift` and into the new `Trio/Sources/APS/Devices/DeviceCatalog.swift`.
Verified this was a false positive, not a repeat of the 2026-06 dropped-pod incident the sentinel
guards against — see TRIO-050's "Progress 2026-08-30" section for the full verification (upstream's
own `DeviceCatalogTests.swift::testLegacyOmnipodIdentifiers` covers the same property).

Fixed the sentinel (operator-approved) by swapping the stale literal `managerIdentifier.hasPrefix(OmniStr)`
for `DeviceCatalog.pumpEntry(forPersistedIdentifier` in `SENTINEL_SYMBOLS`, and rewrote the comment
above it to explain the relocation. Edit was offloaded to `task-relay implement` (ollama) since the
file hit the offload gate; diff verified against the exact spec before trusting it. `patch-test.sh`
re-run PASSED (31 warnings, matching the build-219 baseline) with the fix in place.

**This is a build/infra change, not a patch** — per AGENTS.md "Build system changes vs product
changes," `scripts/` tooling changes are committed directly to `dev`, not carried as a patch. It rode
along uncommitted in build 223 (TRIO-050) because `ci/local-build.sh` picks up uncommitted tracked
changes on `dev` via stash-reapply, but it still needs its own normal commit — separate from the
patch-stack's own commit lifecycle (which gates on build+deploy+verify and wasn't touched by this fix
since no patches were actually regenerated this run).

## Done 2026-08-30

Re-reviewed the diff immediately before committing — unchanged since the offload spec verification in
TRIO-050, no unrelated hunks. Confirmed `scripts/patch-audit.sh` was the only intended file staged
(the pre-existing unrelated `AGENTS.md`/`DanaKit`/`EversenseKit` working-tree edits were left alone).

Committed to `dev` as a normal commit via `agent-commit` (`agent.signing = allow` in this repo):
`5dd6fb1d3` — "scripts: fix patch-audit sentinel for relocated Omnipod migration check". Operator
authorized via "move it to in progress and finish it".

`scripts/patch-test.sh` re-run post-commit: **PASSED (31 warnings)**, sentinel shows
`✓ all pump-migration symbols present`.

## Notes carried over from acceptance criteria


## Review 2026-10-16

Cursor review of `scripts/patch-audit.sh` at dev 826bf8a23 (note `.task-relay/notes/20261016-211816-36896-cursor-review.md`, run 71a17fad) confirmed this task's change: replacing `managerIdentifier.hasPrefix(OmniStr)` with `DeviceCatalog.pumpEntry(forPersistedIdentifier` was the right false-positive fix. Its HIGH finding is real but pre-existing: since f3e4978f7 (2026-06-18) the sentinel loop's glob expansion under `nullglob` drops the `as? OmniPumpManager` token, so that symbol is never checked. That is not in this task's lines and is filed as TRIO-081. Recorded as a pass for TRIO-051 on that basis.
