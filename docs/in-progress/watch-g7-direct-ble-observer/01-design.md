# Trio Watch Dexcom G7 Direct BLE Observer — Design (v1)

## Mission and premise
Implement a watch-only observer that attaches to the same watchOS BLE session already held by the Dexcom G7 watch app, requests EGV over control, and persists readings into Trio’s complication snapshot path with source attribution.

## Observer protocol sequence
1. Long-lived restore-backed `CBCentralManager` is allocated once.
2. On `.active`, run attach ladder: retrieve connected peripherals by G7 data service, then broad scan.
3. On connect, discover all services/characteristics (`nil` discovery breadth).
4. Enable auth notify; explicitly discover and skip J-PAKE for safety logging.
5. Once auth bytes are observed, enable control notify and send EGV request opcode `0x4E` (`.withResponse`).
6. Parse control payload into glucose/trend/reading time, save `TrioComplicationSnapshot` with `source=.directBLE`.

## Discovery/attach and filtering choices
- **Filtering:** DiaBLE-style tolerant standalone matching (`DXCM`/`DEXCOM` name heuristics), no iPhone bridge in this pass.
- **Attach ladder:** `retrieveConnectedPeripherals(withServices:[dataService])` first, then scan fallback.
- **Connect attribution:** all attempts log `source=` (`retrieved_data_service`, `scan`, `retrieved_identifier`).

## Auth gate and EGV cadence
- **Advance condition:** first auth payload observed (looser than strict authenticated+bonded) to avoid stalls.
- **Cadence:** send `0x4E` when control notify becomes ready and again when new auth payload arrives.
- **Control-write failure:** log error + schedule reconnect with bounded backoff.

## Reconnect policy
Retry forever while foreground-active using simple bounded backoff (3s → 20s cap). Reset backoff on successful connect.

## Lifecycle model
- `.active`: start/resume observer sweep.
- `.inactive`: tolerate; no proactive teardown.
- `.background`: no proactive teardown; resume on next `.active`.
- `stop()` remains explicit hard-stop API.
- Extended runtime session not included in this pass to keep attach path minimal.

## UI/status design
Main watch view now shows:
- Existing recency line (`lastLoopTime`).
- Source/status line: `<source> · BLE:<status> · BLE:<last-event-age>`.
This gives glanceable observer state and source-of-current-reading in the primary view.

## Source attribution model
`TrioComplicationSnapshot` now carries `source: TrioReadingSource` (`direct_ble`, `watch_connectivity`, `healthkit`, `unknown`). `WatchState` tracks `currentReadingSource` for UI.

## Observability plan
`WatchLogger` events use `event=g7_ble_*` key/value lines, including:
- lifecycle (`g7_ble_lifecycle`), scan start
- discovery with names/RSSI (`g7_ble_peripheral_discovered`)
- connect attempt and source tags
- services/characteristics discovered
- auth payload previews, jpake skipped
- control request sent, write confirmations/failures
- egv received and snapshot saved

## Design question decisions
1. **Filtering:** standalone tolerant matching for reliability without WC coupling.
2. **Attach strategy:** retrieve-connected first, then scan, matching observer attach premise.
3. **Discovery breadth:** `discoverServices(nil)` / `discoverCharacteristics(nil)` for robustness.
4. **Timeout/backoff:** 3s base, 1.5x multiplier, 20s cap.
5. **Central queue:** `queue:nil` (main queue), with explicit main-bound state updates.
6. **Restoration:** yes; log restored peripherals and reconnect first candidate.
7. **Connect options:** use disconnection notification option for observability.
8. **Auth advance:** first observed auth payload, to avoid over-strict stalls.
9. **EGV cadence:** on control notify readiness + auth payload transitions.
10. **Control-write failure:** log and reconnect retry.
11. **Backfill:** discover and log-only (not gating startup).
12. **Stop scan after connect:** yes, to reduce battery churn.
13. **Multi-peripheral:** first retrieved; for scan choose first name-matched candidate.
14. **Identifier persistence:** none in this pass.
15. **Delta on watch:** unchanged (existing watch payload delta retained).
16. **Winner policy:** prefer newer readingDate, allow direct BLE to overwrite same/newer timestamps.
17. **UI palette:** compact text status (`OFF/SEARCHING/CONNECTING/ACTIVE/STALLED/UNAVAILABLE`) + event recency.
18. **Active-name mid-session:** N/A (no iPhone-bridged filter).
19. **Attach-ladder cadence:** single immediate sweep with retry loop.

## Known risks / device-test questions
- Exact auth payload gate may still be too loose/strict on some firmware.
- EGV payload parse offsets are inferred and need on-device validation.
- Tolerant scan name matching may select wrong sensor in rare multi-sensor proximity.
