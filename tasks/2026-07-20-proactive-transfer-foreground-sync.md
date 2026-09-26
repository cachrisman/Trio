+++
uid = "019f8141-e117-77db-9216-aad18fed48dd"
key = "TRIO-019"
title = "Proactive transfer on iPhone/watch foreground (staleness-gated sync)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/complication-freshness/problem-and-strategy.md#L149"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["complication-freshness", "watch"]

[[acceptance]]
id = "AC-1"
text = "Phase A0: lock down parameters (T_phone_active, T_send, T_watch_active, T_foreground_cooldown, debounce, §6.4 cross-surface strategy, zero-budget behavior) before any gate logic"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Phase A: `ForegroundWatchSyncController` (or equivalent) added, thin `TrioApp.swift`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Phases B-E implemented per plan"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Ship a build, run the Phase F gate (§7.1)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Only after the gate passes: hand off to `post-dead-zone-recovery`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

On `applicationDidBecomeActive`/`sceneDidBecomeActive`, call `setupWatchState()` +
`sendDataToWatch()` only when the current snapshot is stale or no recent successful transfer
exists — addressing the "I just opened Trio on my phone, my watch should update" mental model
without reintroducing budget spam. Full design:
`docs/in-progress/complication-freshness/proactive-transfer/proactive-transfer-01-design.md`.
Implementation plan (Phases A-E, then a gate, then Phase F):
`proactive-transfer-02-implementation-plan.md` (v1.7, status "Draft — not started"). Implementation
happens in the `Trio` worktree (plan currently says branch `feature/watch-complication-improvements`,
which was merged into `feature/watch-g7` in the 2026-06-16 dev-sync — use `feature/watch-g7`).

Phase F (post-dead-zone recovery) is a separate, gated follow-on task — see
`post-dead-zone-recovery`, blocked on this task passing its Phase F gate.

## Notes carried over from acceptance criteria
