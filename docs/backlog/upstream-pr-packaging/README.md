# Backlog: Upstream PR packaging (G7SensorKit → Trio watch)

**Status:** Backlog — deferred behind the dev-sync + branch-cleanup track
**Full plan:** [docs/in-progress/upstream-pr-packaging/](../../in-progress/upstream-pr-packaging/)

## Summary

Package the watch G7 direct-BLE work and the fork fixes as upstream PRs. It's a **dependency
chain, not parallel**: `G7SensorKit` must land upstream (LoopKit) before the Trio watch PR can open
(a public Trio PR can't repoint the submodule at the personal fork, and the adapter imports
fork-only API).

Sequence (from the detailed plan):
- **G7SensorKit:** A (watchOS support) → B (no-op telemetry seam) → **C (verifiable thread-safety /
  reliability fixes — the credibility PR)** → D (behavioral changes, issue-first).
- **Trio watch:** minimal-core cut (~2,300–2,600 lines), most of it new files.

## Why deferred

Gated behind the **dev-sync + branch-cleanup** track — the upstream PRs need a clean, synced stack
(09+12 merged, branch==patch hygiene, fork rebased onto upstream). Start it after that track lands.

## Note (2026-06-15)

The `Data.swift` bounded-read fix shipped in build 209 (fork commit `cd879d5`, fixes a latent
out-of-bounds read + a Swift 6 compiler crash) is **credibility-PR (PR C) material** — carry it into
that PR with its aggregate field evidence.
