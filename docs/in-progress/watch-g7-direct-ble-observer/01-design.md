# Trio Watch — Dexcom G7 Direct BLE Observer Design

## Mission and premise
Implement a watch-only observer path that attaches to the same-device BLE session already owned by the Dexcom G7 watch app, requests EGV data over control characteristic writes, and persists readings to the complication store with source attribution.

## Reference note
The prompt-provided archive path was not available inside this container, so this design follows the required observer constraints from the prompt itself plus Trio codebase integration constraints. No prior Trio `G7DirectBLEManager.swift` implementation was reused.

## Observer sequence
1. Eager, long-lived `CBCentralManager` with restoration identifier.
2. On `.active`, attempt `retrieveConnectedPeripherals(withServices:)` for G7 data service first.
3. If not found, broad scan with tolerant matching (`name` patterns + FEBC adv service).
4. Connect and discover services/characteristics broadly (`nil` discovery).
5. Enable auth notifications.
6. Observe auth payloads (no auth writes).
7. After auth traffic indicates readiness, enable control notify and send EGV opcode `0x4E`.
8. Parse control payload to glucose/trend/reading date and save `TrioComplicationSnapshot` with source=`directBLE`.
9. Keep periodic EGV requests while connected to sustain multiple readings.

## Peripheral discovery / attach strategy
Chosen order: connected-service retrieval first, then scan fallback. Rationale: retrieval is low-latency and best fit for piggybacking an already-connected session; scan remains the universal fallback and is required for robustness.

## Filtering strategy
Chosen: DiaBLE-style standalone tolerant matching (name/advertisement), no iPhone-bridged exact-name filter in this pass. Rationale: fewer moving parts and no cross-target dependency for initial attach reliability.

## Auth advance + EGV cadence
Auth advance condition: first non-empty auth notify payload marks observer-ready. Rationale: avoids strict bonded/authenticated bit-gating that can stall in observer mode.

EGV cadence: immediate request when auth-ready + repeating timer (120s) while connected. Rationale: one-shot-on-connect is not enough for sustained delivery.

## Reconnect policy
On failure/disconnect: retry with bounded backoff (2s increasing to 15s max), reset backoff on successful connect, never permanently give up while foreground-active.

## Scene/lifecycle
- `.active`: start/resume observer.
- `.inactive`: no proactive teardown.
- `.background`: no teardown beyond existing app behavior.
- Explicit `stop()` remains hard-off API.
- `WKExtendedRuntimeSession`: omitted in this pass to keep focus on core attach path.

## UI indicator
Main watch view adds one inline line: `src:<source> · ble:<status> · last:<minutes>` showing current displayed source, observer status, and recency of last direct BLE event.

## Source attribution model
`TrioComplicationSnapshot` now carries `source` (`watchConnectivity`, `healthKit`, `directBLE`). Watch UI reads snapshot-derived source and displays it directly.

## Observability plan
Structured `WatchLogger` events with `event=g7_ble_*`, including:
- lifecycle, scan start/stop, discovered/skipped, connect attempt source tags
- services/characteristics discovery, auth/control notify enable
- auth/control payload receipt, EGV request sends, EGV parse/save
- connect/disconnect/failure with error fields
- blocked states and retry schedule

## Open design question answers
1. **Filtering:** standalone tolerant matching. Minimizes dependency chain and starts working with watch-only deploy.
2. **Attach strategy:** retrieve-connected first, then scan. Fast-path for session sharing plus reliable fallback.
3. **Discovery breadth:** broad (`nil`) service/characteristic discovery for compatibility and to avoid missing target chars.
4. **Timeout/backoff:** connect timeout 12s; retry 2s→15s cap. Aggressive but bounded.
5. **Central queue:** dedicated serial queue. Keeps BLE deterministic; hops to main actor only for UI/store notification.
6. **Restoration:** yes; restoration ID included and restore callback logs restored keys.
7. **connect options:** set disconnect notification option only; no extra options needed for observer POC.
8. **Auth advance:** observed auth traffic (non-empty payload) enables progress. Avoid over-strict stalls.
9. **EGV cadence:** auth-ready immediate send + periodic resend timer. Best chance for repeated readings.
10. **Control write failure:** log detailed failure and reconnect cycle.
11. **Backfill:** discover and log-only (not startup gating). Keep first pass focused on live EGV reliability.
12. **Scan after connect:** stop scanning on candidate/connect. Restart only after disconnect/retry.
13. **Multi-peripheral:** first tolerant match currently wins; diagnostics include id/name/rssi for later tuning.
14. **Identifier persistence:** not used in pass 1; no persistent identifier cache.
15. **Delta on watch:** not computed from direct BLE yet; existing pipeline delta remains unchanged.
16. **Winner policy:** latest-write with `minInterval:5` in store; source attribution preserved in snapshot.
17. **UI palette:** keep 6-state palette as proposed for glanceability.
18. **Active-name mid-session:** not applicable (no iPhone-bridged active-name in this pass).
19. **Attach ladder cadence:** single fast sweep (retrieve→scan), then retry loop on failures.

## Deviations
- Omitted iPhone-side active peripheral name bridge.
- Omitted extended runtime handling.
- Backfill left as discover/log-only.

## Risks / open questions for device test
- Exact auth advance heuristic may need tightening/loosening by observed payload semantics.
- Characteristic UUIDs and payload offsets require on-device validation against real traffic.
- Multi-sensor environments may require stronger disambiguation.
