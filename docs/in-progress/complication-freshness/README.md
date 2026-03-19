# Complication Freshness — Initiative Overview

Status dashboard and navigation hub for the complication-freshness initiative.

**Current status:** Build 142 deployed. R4 validated, R6.1 shipped, R5b/R5c/R5f shipped.
Next: R5d (sleep-gap forced reload) — the only remaining item in Step 6.

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
| [observability/](observability/) | R5 | In progress (R5b/R5c/R5f shipped; R5d pending) |
| [healthkit-improvements/](healthkit-improvements/) | R6.1 | Completed (build 141) |
| [dashboards/](dashboards/) | Sawtooth dashboard design docs | Reference |
| [archive/](archive/) | Frozen original FP-plan, full changelogs | Reference |

---

## Changelog

### v1.0 (2026-03-19 11:30 CET)
- Initial creation as part of complication-freshness docs reorganization.
- Reason: provide a navigable entry point for the initiative's restructured documentation.
