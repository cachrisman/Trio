# Trio Watch Dexcom G7 Direct BLE Observer — Design v1

## Mission and premise
Implement a watch-only observer that attaches to the Dexcom G7 watch app’s existing same-device BLE session and requests EGV payloads on Trio’s own control-characteristic channel. Trio does **not** initiate or own auth.

## Protocol sequence
1. Eager restoration-backed `CBCentralManager` is allocated at watch app startup.
2. On scene `.active`, attempt attach via `retrieveConnectedPeripherals(withServices:[dataService])`; fallback to FEBC scan.
3. Connect, discover services/characteristics broadly (`nil`) and locate auth/control/backfill/jPake chars.
4. Enable auth notify and control notify.
5. Observe auth packets only; never respond; explicitly log jPake as skipped.
6. Once auth-ready + control-ready + observed authenticated auth status packet, write opcode `0x4E` on control.
7. Parse control notification payload into EGV snapshot and persist to `TrioComplicationDataStore` with source `.directBLE`.

## Attach and filtering strategy
- Filtering: DiaBLE-style local tolerant matching (`Dexcom`/`DX` peripheral names) to avoid dependency on phone bridge state.
- Attach order: connected-service retrieval first (fast path when Dexcom app already owns link), then scan fallback.
- Connect attempts are logged with `source=` tags.

## Lifecycle and reconnect
- Start on `.active`; no proactive disconnect on `.inactive`/`.background`.
- `stop()` remains explicit hard-off API.
- On disconnect/connect-failure/control-write-failure, schedule bounded-delay reconnect (3s), reset by active re-entry.

## UI and source attribution
- `TrioComplicationSnapshot` extended with `source: TrioComplicationDataSource`.
- Main bobble recency line now includes: recency + source label + BLE status + BLE-last-event recency.
- Source labels: `BLE`, `PHONE`, `HK`, `?`.

## Observability
Structured logs (via `WatchLogger`) under `event=g7_ble_*` include lifecycle, scan, discovered/skipped, connect attempts with source, notify enabled, auth/control payloads, EGV requests, EGV received, reconnect scheduling, and write failures.

## Design question answers
1. **Filtering:** standalone tolerant matching. Maximizes attach independence from iPhone transport.
2. **Attach strategy:** retrieve-connected(dataService) then FEBC scan. Optimizes fast attach while keeping robust fallback.
3. **Discovery breadth:** broad `discoverServices(nil)` + `discoverCharacteristics(nil, for:)`. More robust to watchOS GATT presentation variance.
4. **Timeout/backoff:** 3s reconnect backoff; no destructive scan-timeout teardown.
5. **Queue:** `queue:nil` (main queue semantics) + MainActor state/store updates.
6. **Restoration:** enabled; logs restore keys for diagnostics.
7. **connect options:** uses disconnect notification option for observability.
8. **Auth advance condition:** auth notify enabled + control notify enabled + observed auth status packet with nonzero status byte.
9. **EGV cadence:** send on readiness transition (per attach cycle). Simpler baseline to validate sustained reconnect cycles.
10. **Control write failure:** log + reconnect.
11. **Backfill:** discover and explicitly log skipped (does not gate EGV path).
12. **Stop scan after connect:** yes.
13. **Multi-peripheral disambiguation:** first acceptable candidate; log IDs for post-hoc analysis.
14. **Identifier persistence:** not used in this pass.
15. **Delta computation:** leave unset (`--`) for BLE path in this pass.
16. **Winner policy:** existing store dedup/min-interval behavior retained; source is carried for UI attribution.
17. **UI status palette:** kept 6-state label set (`off/search/conn/active/stalled/unavail`) rendered inline with recency/source.
18. **Active-name mid-session:** not applicable (no phone-bridged name).
19. **Attach ladder cadence:** single sweep (retrieve then scan), reconnect loop on failures.

## Deviations from references
- No backfill consumption yet (logged skip only) to keep first pass focused on reliable live EGV capture.
- EGV trigger currently once-per-ready-cycle rather than additional cadence timer.

## Risks / open test questions
- Exact auth-status byte interpretation may vary across firmware variants.
- Name-based tolerant filter may admit extra candidates in dense BLE environments.
- Control payload parsing offsets need on-device verification against real notifications.
