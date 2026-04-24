# Trio Watch G7 Direct BLE Observer Design

**Version:** v1  
**Status:** In Progress  
**Created:** 2026-04-24 20:41 CET  
**Last updated:** 2026-04-24 20:41 CET

## Mission

Implement a watch-only Dexcom G7 direct BLE observer for Trio Watch App Extension. Trio is not the BLE session owner: the official Dexcom G7 watch app owns authentication and keeps the same-device watchOS link warm. Trio uses its own `CBCentralManager` and GATT view to observe the authenticated session, request EGV data over the control characteristic, and persist readings into `TrioComplicationDataStore` for faster complication updates.

## Reference basis

- DiaBLE watch observer: `DiaBLE/BluetoothDelegate.swift`, `DiaBLE/Dexcom.swift`, `DiaBLE/DexcomG7.swift`.
- G7SensorKit observer/protocol authority: `G7SensorKit/BluetoothServices.swift`, `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`, `G7SensorKit/G7CGMManager/G7Sensor.swift`, `G7SensorKit/Messages/G7GlucoseMessage.swift`, `G7SensorKit/G7CGMManager/G7BackfillMessage.swift`, `G7SensorKit/Messages/AuthChallengeRxMessage.swift`.

No reference files are copied into Trio. UUIDs, opcodes, and parsing behavior are reimplemented narrowly in Trio's watch extension.

## Protocol observer sequence

1. Create an eager, long-lived, restoration-backed `CBCentralManager` on a dedicated serial queue.
2. On foreground-active entry, attach by trying persisted identifier retrieval, connected-service retrieval (`FEBC` and G7 data service), then broad scan.
3. Connect candidates matching G7 advertisement/name/service evidence.
4. Discover services and characteristics broadly (`nil`) to match DiaBLE's watch behavior and to log unexpected characteristics.
5. Enable authentication notifications.
6. Observe authentication status traffic only. Trio never writes auth-init, app-key challenge, J-PAKE, ownership, or bond packets.
7. Advance to control notifications when auth status says authenticated; if no status arrives after a short fallback window, try control anyway because the official app may have already completed auth before Trio subscribed.
8. Enable control notifications and write the EGV request opcode (`0x4e`) with response.
9. Repeat EGV requests periodically while connected to sustain multiple readings over time.
10. Parse EGV responses using G7SensorKit's field layout: message timestamp, age, glucose, algorithm state, trend rate, predicted glucose, calibration/display-only byte. Reading time is `activationDate + (messageTimestamp - age)`, where `activationDate = now - messageTimestamp`.
11. Save a source-tagged `TrioComplicationSnapshot` and update `WatchState`.

## Attach and filtering strategy

This implementation uses standalone DiaBLE-style tolerant matching rather than iPhone-bridged exact names. It accepts candidates with G7-style names (`DXCM`, `DX02`, `DX01`, `Dexcom`), advertised `FEBC`/data service, or connected-service retrieval provenance. This minimizes dependency on phone relay freshness and aligns with the same-watch observer premise.

Attach order:

1. `retrievePeripherals(withIdentifiers:)` from a watch-local persisted peripheral identifier.
2. `retrieveConnectedPeripherals(withServices:)` for `FEBC` and the G7 data service.
3. Broad `scanForPeripherals(withServices: nil)` with verbose advertisement logging.

Every connect attempt logs `source=` (`retrieved_identifier`, `retrieved_data_service`, `retrieved_febc`, `scan`, `restored_state`).

## Lifecycle and reconnect

- `WatchState.handleForegroundActiveEntry()` starts/resumes the observer.
- `.inactive` and `.background` are logged but do not stop or tear down the BLE session.
- `stop()` remains an explicit hard-off surface only.
- Reconnect is indefinite with capped exponential backoff. It is not gated on active scene state, preserving recovery after brief inactive/background transitions.
- Scan timeout checks whether a peripheral is already connected before stopping or scheduling reconnect.

No `WKExtendedRuntimeSession` is included in this pass. The baseline target is foreground-active operation, and the core attach/protocol path is the higher-risk proof point.

## Source attribution and data store

`TrioComplicationSnapshot` is extended with optional `source: TrioComplicationDataSource?`. Optional decoding preserves compatibility with snapshots already persisted without source. Direct BLE saves use `.g7DirectBLE`; HealthKit saves use `.healthKit`; WatchConnectivity saves use `.watchConnectivity` through `WatchState` live-state attribution. The complication extension can keep rendering existing fields unchanged.

The direct BLE path saves snapshots through `TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)` and updates `WatchState` on `MainActor`.

## UI indicator

The main watch glucose view now keeps the existing recency line and adds a compact source/status line:

`<source> · BLE:<status> <last-event-age>`

Examples: `BLE · BLE:ok 12s`, `Phone · BLE:scan 2m`, `HK · BLE:stall 8m`.

The BLE status palette is six states: `off`, `searching`, `connecting`, `active`, `stalled`, `unavailable`. This is small enough for glanceability while still separating "trying", "connected/auth/control work", "recent EGV success", and platform unavailable states.

## Observability

All observer logs use `WatchLogger` and `event=g7_ble_*`. The private helper forwards `#fileID`, `#line`, and `#function` to preserve caller attribution.

Logged fields include peripheral names, identifiers, RSSI, advertisement service UUIDs, manufacturer data hex, match/skip reasoning, attach source, service/characteristic UUIDs, notification enable results, auth/control payload previews, write type, parse outcomes, snapshot saves, disconnect errors, reconnect scheduling, and session outcomes.

Negative-proof events such as `g7_ble_auth_request_sent` must never appear; this implementation has no auth-write code path.

## Design question answers

1. **Peripheral filtering:** Standalone tolerant matching. It reduces dependency on iPhone state and follows the proven watch reference shape.
2. **Attach strategy:** Persisted identifier, connected-service retrieval on `FEBC`/data service, then broad scan. This combines G7SensorKit's retrieval ladder with DiaBLE's watch scanning tolerance.
3. **Discovery breadth:** `discoverServices(nil)` and `discoverCharacteristics(nil, for:)`. DiaBLE does broad discovery on watch; broad discovery also gives better diagnostics for a POC.
4. **Timeout/backoff:** 15s scan timeout, 20s connect timeout, capped exponential reconnect up to 30s. These are short enough for watch foreground feedback without spinning.
5. **Central queue:** Dedicated serial utility queue. G7SensorKit uses a serial manager queue; all store/state mutations hop to `MainActor`.
6. **Restoration:** Yes. Restored peripherals are logged, delegated, and reused if they match.
7. **Connect options:** `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true`. This asks the OS to surface disconnects; no private/unsupported options.
8. **Auth advance condition:** Advance on authenticated status reply regardless of bonded bit; fallback after 8s of auth silence. This avoids stalling when Trio subscribes after the official app already completed auth.
9. **EGV cadence:** Send immediately after control notify enables, then every 60s while connected. Periodic requests are the simplest way to deliver multiple readings over time instead of one per connect.
10. **Control-write failures:** Log NSError fields, mark stalled through reconnect, and retry via the attach ladder.
11. **Backfill:** Discover and enable/log backfill, parse no historical samples in this pass. This keeps startup unblocked while preserving telemetry for a future backfill implementation.
12. **Stop scanning after connect:** Yes. Battery is preserved and disconnect-driven retry handles reattach.
13. **Multi-peripheral disambiguation:** Prefer persisted identifier, then first matching connected-service candidate, then first matching scan candidate. RSSI/name are logged for device-test analysis.
14. **Peripheral identifier persistence:** Watch-local `UserDefaults.standard`, updated after successful EGV. It is not App Group because only the watch app observer needs it.
15. **Delta computation:** Compute locally from the last direct-BLE reading in process. First direct BLE sample uses `"--"`.
16. **Dedup/winner policy:** Existing store newer-wins/dedup remains authoritative; source does not override an older reading. `minInterval: 5` keeps complication reload responsive.
17. **UI palette:** Six states plus last-event age. This makes "BLE working recently" visible even when the displayed reading source is not BLE.
18. **Active-name filter changes:** Not applicable; no iPhone-bridged filter.
19. **Attach-ladder cadence:** Single synchronous sweep followed by scan; failures schedule reconnect. This keeps behavior explainable in logs.

## Deviations from references

- G7SensorKit gates control enable on `authenticated && bonded`; Trio advances on authenticated and falls back after auth silence. The mission prioritizes observer reattach reliability when the official watch app may have completed auth before Trio observes the status packet.
- G7SensorKit uses targeted service/characteristic discovery through its peripheral manager; Trio uses broad discovery to match DiaBLE's watch behavior and improve diagnostics.
- DiaBLE includes active auth behavior outside test/eavesdrop mode; Trio omits all auth-write paths to enforce observer-only posture.
- Backfill is logged but not actively requested or merged; this pass focuses on sustained live EGV delivery.

## Known risks and device-test questions

- The periodic 60s EGV request cadence may need tuning if the sensor rate-limits control writes or only emits fresh EGV every 5 minutes.
- The 8s auth fallback may be too early or too late on some watchOS versions; BetterStack auth/control logs should guide tuning.
- Broad scanning may have battery cost during failure loops, though scan windows are timeout-bounded.
- Xcode target membership for new Swift files is pending human wiring by design.

## Changelog

### v1 (2026-04-24 20:41 CET)
- Created the clean-room observer design for the watch-only G7 BLE observer.
- Recorded design choices and open-question answers so the implementation can be compared against other attempts and tested on device.
