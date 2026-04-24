# Complication Freshness — Initiative Overview

**Version:** v1.6  
**Last updated:** 2026-04-08 23:17 CET

Status dashboard and navigation hub for the complication-freshness initiative.

**Current status:** Build 144 deployed (2026-03-21). All R1–R6 remediation items plus build 144 refinements (4D–4I) shipped. Post–R5d 48h gate completed (see [`build-144-plan.md`](build-144-plan.md) §Prerequisites) — transport layer assessed healthy. **4G–4I** are implemented in production; optional Better Stack spot-checks against `build-144-plan.md` success criteria remain useful but are not gating. Remaining work is **unplanned follow-ups** in [`problem-and-strategy.md`](problem-and-strategy.md) §Backlog (canonical — **v1.8**).

---

## Milestone History

| Build | What shipped |
|---|---|
| 131 | FP-Phase 0-5 complete (baseline instrumentation, dedup, fingerprint) |
| 132 | R1 (reading epoch + stale queue drain) + R5e (exhaustion alert) |
| 133 | R2a (coalescer attribution) + R3 (payload allowlist) |
| 134 | R2b (dispatch gate) |
| 137-138 | Step 3b (age gate) + cloud logging pipeline fixes |
| 140 | R6 (HealthKit background delivery) |
| 141 | R6.1 (HealthKit improvements) + R5b/R5c/R5f (observability) |
| 142 | R4 (applicationContext safety net) — validated |
| 143 | R5d (sleep-gap forced reload), readingDate wall-clock fixes, R4 handler upgrade (R5d integration), watch log flush observability (4A/4B/4C), WCSession crash guard (new patch 10), Foundation.NotificationCenter fix |
| 144 | Watch log pipeline improvements (4D/4E/4F: raised cap, chunk splitting, 30s timer), complication observability refinements (4G/4H/4I: unified R4 log, queue_depth, fresh-snapshot retry skip), upstream sync (FPU removal), patch 01 fix |

---

## Navigation

### Top-level docs

| Document | Description |
|---|---|
| [Problem and Strategy](problem-and-strategy.md) | Problem statement, R1-R6 strategy overview, naming convention, implementation sequence |
| [Validation Protocol](validation-protocol.md) | Per-phase pass/fail criteria |
| [Key File Reference](key-file-reference.md) | Code symbol/file/line table |

### Subfolders

| Folder | Scope | Status |
|---|---|---|
| [transfer-optimization/](transfer-optimization/) | R1 + R2 + R3 | Completed (builds 132-138) |
| [alternative-delivery/](alternative-delivery/) | R4 + R6 | Completed (builds 140, 142) |
| [observability/](observability/) | R5 + 4G/4H/4I | Completed (R5b/R5c/R5f build 141; R5d build 143; 4G/4H/4I build 144) |
| [healthkit-improvements/](healthkit-improvements/) | R6.1 | Completed (build 141) |
| [dashboards/](dashboards/) | Sawtooth dashboard design docs | Reference |
| [archive/](archive/) | Frozen original FP-plan, full changelogs | Reference |
| [proactive-transfer/](proactive-transfer/) | iPhone + watch foreground staleness-gated sync | Draft design + implementation plan — **implement in `Trio` worktree, branch `feature/watch-complication-improvements`** |

---

## Changelog

### v1.6 (2026-04-08 23:17 CET)
- **proactive-transfer:** Navigation row notes **`Trio` worktree / `feature/watch-complication-improvements`** for implementation (planning docs remain in **Trio-dev**).
- Reason: align hub with proactive-transfer worktree/branch guidance.

### v1.5 (2026-04-08 22:31 CET)
- Added **proactive-transfer/** initiative (design + implementation plan) for staleness-gated foreground sync; navigation row in Subfolders.
- Reason: backlog item “Proactive transfer on iOS app foreground” expanded with watch symmetry.

### v1.4 (2026-04-08 22:26 CET)
- Cross-doc pass: pointed **Problem and Strategy** to v1.7 (Pending line now includes build 144). No milestone/navigation changes.
- Reason: keep hub aligned with strategy doc after validation/key-file fixes.

### v1.3 (2026-04-08 22:09 CET)
- Clarified current status: removed contradiction between “4G/4I pending validation” and observability subfolder “Completed”; aligned with `problem-and-strategy.md` v1.6 (gate completed; 4G–4I shipped; optional spot-checks only). Added version metadata.
- Reason: epic doc consistency pass.

### v1.2 (2026-03-22 00:35 CET)
- Build 144 deployment: added milestone row, updated status and next steps. Updated observability subfolder to include 4G/4H/4I. Watch log flush observability and WCSession crash guard initiatives moved to `docs/completed/`.

### v1.1 (2026-03-20 22:10 CET)
- Build 143 deployment: added milestone row, updated status to "all planned R1-R6 items shipped", updated observability subfolder to Completed, added next step (48h re-measurement).

### v1.0 (2026-03-19 11:30 CET)
- Initial creation as part of complication-freshness docs reorganization.
- Reason: provide a navigable entry point for the initiative's restructured documentation.
