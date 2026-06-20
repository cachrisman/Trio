# Watch → Phone reading backfill (direct BLE)

**Status:** backlog / idea only — not started
**Logged:** 2026-06-19

## Observation

With the watch running direct G7 BLE (the `watch-g7-direct-ble-observer` work),
the watch picked up **1–2 EGV readings that the phone missed** (phone had a gap
the watch did not). Today this data is one-directional: the watch is an observer
and the phone is the source of truth. Readings the watch legitimately gets but the
phone misses are currently lost from the phone's perspective.

## Idea to investigate

What would it take to wire a **data sync back to the phone** so that, when the
watch legitimately captures a reading the phone missed, the phone can backfill it
(loop/treatment store, Nightscout, charts)?

Open questions for the investigation:
- Dedup / ordering: how to merge watch-sourced EGVs without double-counting ones
  the phone already has (match on sensor reading timestamp, not receipt time).
- Trust model: only backfill genuine phone gaps; don't let the watch override or
  race the phone's own readings.
- Transport: reuse existing watch↔phone messaging vs. a dedicated backfill channel.
- Effect on loop: does a backfilled reading re-trigger a loop cycle, and is that
  safe/desirable, or is it display/log-only?

## Evidence window (pull BetterStack logs later)

The miss happened in the ~30 min ending at the time this was logged. Use this
window when pulling the watch + phone EGV logs for a concrete example:

- **Start (UTC):** 2026-06-19T12:49:39Z
- **End (UTC):**   2026-06-19T13:19:39Z
- Local: 2026-06-19 ~14:49–15:19 CEST

Logs were **not** pulled at logging time (session limits) — timestamps captured
so the example can be reconstructed from BetterStack later.

## Related

- `docs/in-progress/watch-g7-direct-ble-observer/`
