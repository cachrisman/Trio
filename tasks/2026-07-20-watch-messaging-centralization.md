+++
uid = "019f8141-e117-77db-9216-aaccb3c85341"
key = "TRIO-023"
title = "Centralize watch/phone WatchConnectivity messaging architecture"
status = "waiting"
kind = "code"
waiting_on = "upstream-pr-packaging initiative (task landing/declared dead — see docs/backlog/upstream-pr-packaging) and feature/watch-g7 reaching a quiet point on WatchState/AppleWatchManager, per docs/in-progress/watch-messaging-centralization/fable-advisory.md §3.3"
source = "human"
source_ref = "docs/backlog/watch-messaging-centralization/watch-messaging-centralization-00-idea.md#L4"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["watch", "architecture"]
+++

## Intent

Trio's Apple Watch ↔ iPhone path spreads message construction, parsing, dedup, ACK handling, and
side effects across large types (`AppleWatchManager`, `WatchState`) using several WatchConnectivity
transports and ad hoc `[String: Any]` payloads. This initiative centralizes those into shared typed
contracts, shared decode/validation, a single inbound dispatcher per platform, an explicit
transport-policy layer, and typed sender APIs — without changing wire format or re-fixing the
already-shipped forced-closure bugfix (a preserved invariant). Design:
`docs/in-progress/watch-messaging-centralization/watch-messaging-centralization-01-design.md`
(v1.9). Implementation plan: `...-02-implementation-plan.md` (v1.11, Phases A–G). Advisory
(2026-07-17, recommends holding and gives the placement analysis):
`docs/in-progress/watch-messaging-centralization/fable-advisory.md`.

Architecture is settled per the advisory — do not redesign it. The load-bearing open decision is
*where* the refactor lives (upstream-first is recommended): the fork carries ~17k diff lines of
watch patches over exactly the files this would reorganize, and doing it fork-side before the
upstream watch PR resolves would maximize merge pain.

A small independent slice (envelope/ACK literal-constant extraction) does not need to wait — see
the separate `messaging-centralization-b2-literal-slice` task.

## Acceptance criteria

- [ ] Trigger to start: upstream-pr-packaging initiative's watch PR lands or is declared dead, AND `feature/watch-g7` reaches a quiet point (no in-flight build plan touching `WatchState`/`AppleWatchManager`)
- [ ] Phase A: re-run inventory greps at kickoff (fable-advisory.md §1 has a 2026-07-17 baseline), resolve Task A3 (target placement) and `WatchStartupTransportGate` delegate-vs-subsume
- [ ] Follow plan order B (contracts) → C (decode) → D (phone dispatch) → E (watch dispatch + completion, mandatory 72h soak) → F (transport policy) → G (cleanup)
- [ ] Dedupe stays with session owners (`BaseWatchManager`/`WatchState`); dispatcher only routes
- [ ] Queue/threading contract verified in-tree (not assumed) before Phase D/E
- [ ] No regression to complication-freshness budget/transport cascade or the forced-closure completion invariants
