# Complication Freshness — Validation Protocol

**Version:** 1.0
**Created:** 2026-03-19 11:30 CET
**Last updated:** 2026-03-19 11:30 CET

---

Run 24 hours after each phase ships.

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
| R5d | Widget actually advanced | `timeline_entry_epoch` in getTimeline logs | p90 age < 600s | `save_age` fresh but `timeline_entry_epoch` stale |
| R6 | HealthKit delivery + WidgetKit wake | `hk_observer_fired` events; `reload_age` during gaps | `hk_observer_fired` present in exhaustion AND gaps; `reload_age` p90 < 300s | No `hk_observer_fired`; or `reload_age` unchanged |

---

## Changelog

### v1.0 (2026-03-19 11:30 CET)
- Initial creation: extracted validation protocol table from remediation plan.
- Reason: provide a standalone per-phase pass/fail reference as part of the docs reorganization.
