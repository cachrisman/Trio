+++
uid = "01a1462a-7e20-7475-9858-6c38da382840"
key = "TRIO-081"
title = "patch-audit.sh never checks the 'as? OmniPumpManager' sentinel (nullglob drops it)"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = ".task-relay/notes/20261016-211816-36896-cursor-review.md#HIGH-nullglob-sentinel"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
priority = 2
+++

## Intent

The deletion-footprint audit's Omnipod sentinel silently checks only two of its three symbols. `scripts/patch-audit.sh` turns on `shopt -s nullglob` (line 89) and later loops `for sym in $SENTINEL_SYMBOLS` with `IFS='|'` (lines 147-148), unquoted. The third token, `as? OmniPumpManager`, contains `?`, a glob metacharacter. With no matching file in the worktree, nullglob removes the word, so it is never grepped and a patch that deleted it would pass.

Reproduced 2026-10-16 in plain bash with the same `SENTINEL_SYMBOLS`, `IFS` and `nullglob`: only `func pumpManagerTypeByIdentifier` and `DeviceCatalog.pumpEntry(forPersistedIdentifier` are visited.

Found by the cursor review of TRIO-051 (note `.task-relay/notes/20261016-211816-36896-cursor-review.md`, run 71a17fad). Present since the guard was added in f3e4978f7 (2026-06-18); TRIO-051's change did not introduce it. This sentinel guards the dropped-pod failure class (DeviceDataManager Omnipod identifier migration), so a silent false negative matters.

Likely fix: disable globbing around the loop (`set -f` / `set +f`), or split into an array with `IFS='|' read -r -a`, and add a self-check that the number of symbols checked equals the number declared. The same review also noted (MEDIUM) that `git diff-tree --numstat` runs without rename detection, so a moved safety file reads as a full deletion; consider it here or separately.
