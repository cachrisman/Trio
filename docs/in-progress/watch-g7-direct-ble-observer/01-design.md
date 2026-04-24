# Watch G7 Direct BLE Observer — Design

## Mission and premise
Implement a watch-only Dexcom G7 observer that piggybacks on the same-device BLE session owned by the Dexcom G7 watch app, then writes EGV readings into `TrioComplicationDataStore` for faster watch freshness.

## Reference validation
Fetched and reviewed the required DiaBLE + G7SensorKit files before implementation (using GitHub URLs). Core mechanics were taken from their shared behavior: eager restoration-backed central, broad service/characteristic discovery, auth notify observation, control write for glucose request, and control notify for payload delivery.

## Observer sequence
1. Create long-lived `CBCentralManager` with restoration identifier at app lifetime.
2. On `.active`, attempt attach via `retrieveConnectedPeripherals(withServices:)` using G7 data-service UUID then FEBC UUID.
3. If retrieval misses, start broad scan and match Dexcom-like names from discovered peripherals.
4. Connect; discover services/characteristics with `nil` breadth.
5. Enable auth notifications.
6. Observe auth notifications (never respond, never write auth, never J-PAKE writes).
7. Enable control notifications and write opcode `0x4e` (glucose request).
8. Parse control response into glucose/trend/time, build snapshot, persist with `source=.directBLE`.
9. Keep request cadence running to sustain multiple reads over time.

## Attach strategy
Primary: connected-service retrieval; fallback: scan. This matches high-fidelity reference behavior and prioritizes immediate piggyback attach to the session already held by Dexcom.

## Filtering choice
Used standalone tolerant matching (DiaBLE-like) by peripheral/advertised name patterns (`DXCM`/`DEXCOM`/`G7`) to avoid optional iPhone dependencies for this pass.

## Auth advance + request cadence
Advance condition: first auth payload observed OR auth-fallback timeout (4s) after auth notify enable. This avoids permanent stalls if a strict auth state never appears on the observer side.
Cadence: immediate request after advance, then repeat every ~295s while connected.

## Reconnect model
On fail/disconnect/timeout, schedule reconnect with simple 2s delay; no permanent give-up while active.

## Scene/lifecycle
- Start/resume on `.active`.
- `.inactive`/`.background` do not hard-stop BLE manager; they only update status.
- `stop()` exists as explicit hard-off API.
- No `WKExtendedRuntimeSession` in this pass.

## UI indicator
Integrated into existing recency line:
- `"<loop recency> · BLE:<status>"`
- second line: `"SRC:<BLE|PHONE|HK|--> · BLE:<last-event-age>"`
This gives both live observer status and source attribution for the displayed reading.

## Source attribution model
Added `TrioComplicationDataSource` and stored `source` in `TrioComplicationSnapshot`.
- WatchConnectivity saves as `.watchConnectivity`
- HealthKit saves as `.healthKit`
- Observer saves as `.directBLE`

## Observability
All observer logs use `WatchLogger` with `event=g7_ble_*` taxonomy including discovery details, attach source, notify setup, payload reception, write outcomes, and reconnect reasons.

## Open design questions and decisions
1. Filtering: standalone tolerant matching (max autonomy, fewer dependencies).
2. Attach ladder: retrieve data-service, retrieve FEBC, then scan.
3. Discovery breadth: `discoverServices(nil)` + `discoverCharacteristics(nil, for:)` (reference-aligned tolerance).
4. Timeouts: scan 12s, reconnect 2s, auth fallback 4s.
5. Queue: dedicated serial CB queue; MainActor hop for UI/store writes.
6. Restoration: enabled; logs restored keys.
7. connect options: set notify-on-disconnect true.
8. Auth gate: payload-or-timeout to avoid strict-state deadlock.
9. EGV cadence: immediate + periodic 295s.
10. Write failure: reconnect.
11. Backfill: discover + log skipped.
12. Stop scan after connect: yes.
13. Multi-peripheral: pick first matching discovery/retrieval candidate.
14. Identifier persistence: none in this pass.
15. Delta on watch: left as `--` for direct BLE path.
16. Winner policy: existing store dedup/minInterval + latest reading recency.
17. UI palette: off/searching/connecting/active/stalled/unavailable.
18. Active-name mid-session: not applicable (no iPhone filter bridge).
19. Attach-ladder cadence: single sweep then reconnect retry loop.

## Deviations from references
- Did not add backfill parsing in this pass (logged as skipped).
- Simplified auth advance (payload/timeout) vs strict auth-state interpretation to prioritize sustained reads.

## Risks / device-test questions
- Exact control payload layout may vary; parser assumptions need on-device validation.
- Some Dexcom configurations may require tighter auth-state interpretation.
- Multi-sensor environments may require stronger disambiguation than name heuristics.
