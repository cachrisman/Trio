+++
uid = "019f8141-e117-77db-9216-aadfb23a4344"
key = "TRIO-016"
title = "Patch/build tooling: local build provenance + generate-patch.sh guards"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/patch-build-tooling-hardening/01-design.md#L178"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["patch-tooling"]

[[acceptance]]
id = "AC-1"
text = "`build-<N>.json` local provenance artifact emitted for every `--build-only` run (released builds already get a manifest via `record-release.sh` + `BuildDetails.plist`; this is the local convenience equivalent)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "`generate-patch.sh` rejects output paths outside `patches/`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Drift-exclude regexes persisted in a checked-in `.patch-drift-excludes` file"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Lower-priority follow-ups (G/H) from the patch/build tooling hardening initiative. Changes A-F
(cherry-pick gate, `repin-g7.sh`, submodule-list derivation, worktree-preserve-on-error,
`cleanup-build-leftovers.sh`, docs) already shipped and are committed (`6cc0ce148`, `09768528b`).
Verified 2026-07-20: G/H are still unimplemented (no `build-<N>.json` provenance file found, no
output-path guard or persisted drift-exclude regex found in `generate-patch.sh`).

## Notes carried over from acceptance criteria
