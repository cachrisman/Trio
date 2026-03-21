# Complication Freshness — Initiative Overview

Status dashboard and navigation hub for the complication-freshness initiative.

**Current status:** Build 144 deployed (2026-03-21). All R1-R6 remediation items plus build 144 refinements (4D-4I) shipped.
Post-R5d 48h gate completed — transport layer healthy. 4G/4I pending full telemetry validation. Remaining backlog is unplanned follow-ups.

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

---

## Changelog

### v1.2 (2026-03-22 00:35 CET)
- Build 144 deployment: added milestone row, updated status and next steps. Updated observability subfolder to include 4G/4H/4I. Watch log flush observability and WCSession crash guard initiatives moved to `docs/completed/`.

### v1.1 (2026-03-20 22:10 CET)
- Build 143 deployment: added milestone row, updated status to "all planned R1-R6 items shipped", updated observability subfolder to Completed, added next step (48h re-measurement).

### v1.0 (2026-03-19 11:30 CET)
- Initial creation as part of complication-freshness docs reorganization.
- Reason: provide a navigable entry point for the initiative's restructured documentation.
