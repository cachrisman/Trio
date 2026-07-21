+++
uid = "019f8141-e117-77db-9216-aadfb23a4344"
key = "TRIO-016"
title = "Patch/build tooling: local build provenance + generate-patch.sh guards"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/in-progress/patch-build-tooling-hardening/01-design.md#L178"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["patch-tooling"]
+++

## Intent

Lower-priority follow-ups (G/H) from the patch/build tooling hardening initiative. Changes A-F
(cherry-pick gate, `repin-g7.sh`, submodule-list derivation, worktree-preserve-on-error,
`cleanup-build-leftovers.sh`, docs) already shipped and are committed (`6cc0ce148`, `09768528b`).
Verified 2026-07-20: G/H are still unimplemented (no `build-<N>.json` provenance file found, no
output-path guard or persisted drift-exclude regex found in `generate-patch.sh`).

## Acceptance criteria

- [ ] `build-<N>.json` local provenance artifact emitted for every `--build-only` run (released builds already get a manifest via `record-release.sh` + `BuildDetails.plist`; this is the local convenience equivalent)
- [ ] `generate-patch.sh` rejects output paths outside `patches/`
- [ ] Drift-exclude regexes persisted in a checked-in `.patch-drift-excludes` file
