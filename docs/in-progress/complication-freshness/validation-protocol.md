# Complication Freshness — Validation Protocol

**Version:** 1.1
**Created:** 2026-03-19 11:30 CET
**Last updated:** 2026-04-08 22:26 CET

---

Per-phase checks after each ship. **Post–R5d transport health:** the authoritative gate for “is transport OK?” and whether to pull deferred backlog items is documented in **[`build-144-plan.md`](build-144-plan.md) §Prerequisites** (Gate Results, ~2026-03-21) — not this table alone.

Run 24 hours after each phase ships (where still applicable).

| Phase | Metric | Signal | Pass threshold | Falsified if |
|---|---|---|---|---|
| R1 | Queue depth | `queue_depth` in transfer logs | p95 < 5 | Remains > 10 |
| R1 | Stale delivery burst | `didReceiveUserInfo` rate/hr | < 15/hr | Unchanged |
| R2 | Transfers/reading | C count per `reading_date_epoch_seconds` | avg C ≤ 1.3 | avg > 1.5 |
| R2 | Budget drain rate | complication transfers/hr | < 15/hr | Drain > 18/hr |
| Step 3b | Budget spread | transfers vs time since reset; `skip_reason=age_gate` | Budget not exhausted in first 2-3h | Budget still exhausted in 3h |
| R3 | Payload size | `payload_bytes` in transfer logs | < 500 bytes | > 5 KB |
| R4 | Freshness during exhaustion | Three correlated signals: iOS `context_succeeded`, watch `didReceiveApplicationContext`, `save_age` during `budget_exhausted` hours | All three present AND `save_age` p90 < 300s | `save_age` unchanged despite `context_succeeded`; or `context_succeeded` absent |
| R5a | Publisher attribution | `coalescer_fired sources=` | No non-glucose source > 30% of multi-C readings | — |
| R5d | Widget actually advanced | `data_age_seconds` from `event=complication_get_timeline_called` (and getSnapshot path); see R5f — **not** a field named `timeline_entry_epoch` (that name was design-only; see `build-144-plan.md` changelog v1.5) | p90 `data_age_seconds` < 600s where applicable | `save_age` fresh but WidgetKit `data_age_seconds` stale at entry |
| R6 | HealthKit delivery + WidgetKit wake | `hk_observer_fired` events; `reload_age` during gaps | `hk_observer_fired` present in exhaustion AND gaps; `reload_age` p90 < 300s | No `hk_observer_fired`; or `reload_age` unchanged |

---

## Changelog

### v1.1 (2026-04-08 22:26 CET)
- **R5d row:** Replaced obsolete `timeline_entry_epoch` reference with shipped R5f fields (`data_age_seconds` / `complication_get_timeline_called`). Added pointer to `build-144-plan.md` for post–R5d gate assessment.
- Reason: align with implemented logging and `build-144-plan.md` (timeline_entry_epoch was never a literal log field).

### v1.0 (2026-03-19 11:30 CET)
- Initial creation: extracted validation protocol table from remediation plan.
- Reason: provide a standalone per-phase pass/fail reference as part of the docs reorganization.
