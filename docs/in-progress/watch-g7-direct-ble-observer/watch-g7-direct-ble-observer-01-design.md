# Trio Watch G7 Direct BLE Observer Design

**Version:** v2  
**Status:** In Progress  
**Created:** 2026-04-24 20:41 CET  
**Last updated:** 2026-04-24 23:19 CET

## Mission

Implement a watch-only Dexcom G7 direct BLE observer for Trio Watch App Extension. Trio is not the BLE session owner: the official Dexcom G7 watch app owns authentication and keeps the same-device watchOS link warm. Trio uses its own `CBCentralManager` and GATT view to observe the authenticated session, request EGV data over the control characteristic, and persist readings into `TrioComplicationDataStore` for faster complication updates.

## Reference basis

- DiaBLE watch observer: `DiaBLE/BluetoothDelegate.swift`, `DiaBLE/Dexcom.swift`, `DiaBLE/DexcomG7.swift`.
- G7SensorKit observer/protocol authority: `G7SensorKit/BluetoothServices.swift`, `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`, `G7SensorKit/G7CGMManager/G7Sensor.swift`, `G7SensorKit/Messages/G7GlucoseMessage.swift`, `G7SensorKit/G7CGMManager/G7BackfillMessage.swift`, `G7SensorKit/Messages/AuthChallengeRxMessage.swift`.

No reference files are copied into Trio. UUIDs, opcodes, and parsing behavior are reimplemented narrowly in Trio's watch extension.

## Implementation synthesis (v2)

Canonical narrative and per-mod rationale live in [g7-direct-ble-synthesis-blueprint.md](g7-direct-ble-synthesis-blueprint.md). Summary for traceability:

- **Implementation base:** PR 29-shaped codebase (single `G7DirectBLEObserver.swift`, PR 29 state model, guarded 15s scan timeout, reconnect/scene discipline, broad discovery). PR 29 was chosen as base over PR 30 for maintainability during iteration (smaller surface, same surgical transplants from PR 30).
- **Scan timeout (explicit non-transplant):** PR 29’s guarded scan timeout is **retained**. It cannot tear down a connected session (`activePeripheral?.state != .connected` guard) and recovers from stalled scans; PR 30’s no-timeout design was rejected for that failure mode (see blueprint Phase 3).
- **MOD-C (donor PR 30):** `sessionActivationDate` anchored once per connect cycle in `parseGlucose` to remove sub-second activation drift between consecutive EGV messages.
- **MOD-B (donor PR 30):** Auth advance prefers `authenticated && bonded`; partial `authenticated && !bonded` is logged and does not advance; **6s** permissive fallback timer still calls `advanceToControl` if no gate-satisfying status was observed (same escape hatch as before, shorter delay).
- **MOD-A (donor PR 30):** Multi-trigger EGV cadence: initial request when control notify enables; additional `sendEGVRequest` on subsequent `authenticated && bonded` auth payloads after advance (`auth_transition`); **330s** fallback timer armed from successful control **write** acks (not from submit); transient control write errors retry at **10s** up to **three** failures before `control_write_retries_exhausted` reconnect; **60s** reschedule retained only for `control_not_ready`.
- **MOD-E (donor PR 24):** After starting broad scan, `registerForConnectionEvents` for `FEBC` and the G7 data service; `connectionEventDidOccur` on `.peerConnected` calls `startOrResume` when not hard-stopped (reattach ladder when Dexcom app reconnects the sensor).
- **MOD-D (donor PR 24):** In `TrioComplicationDataStore.shouldUpdate`, within **±1s** and same glucose+trend, **higher-priority** `TrioComplicationDataSource` replaces (BLE > WatchConnectivity > HealthKit); lower priority does not clobber a better source.

Variant diffs for provenance: [variants/30-cursor-opus-4.7-high.diff](variants/30-cursor-opus-4.7-high.diff), [variants/24-cursor-gpt-5.5-medium.diff](variants/24-cursor-gpt-5.5-medium.diff).

## Protocol observer sequence

1. Create an eager, long-lived, restoration-backed `CBCentralManager` on a dedicated serial queue.
2. On foreground-active entry, attach by trying persisted identifier retrieval, connected-service retrieval (`FEBC` and G7 data service), then broad scan.
3. Connect candidates matching G7 advertisement/name/service evidence.
4. Discover services and characteristics broadly (`nil`) to match DiaBLE's watch behavior and to log unexpected characteristics.
5. Enable authentication notifications.
6. Observe authentication status traffic only. Trio never writes auth-init, app-key challenge, J-PAKE, ownership, or bond packets.
7. Advance to control notifications when auth status says **authenticated and bonded**; if no qualifying status arrives after a **6s** fallback window, advance anyway (permissive escape hatch) because the official app may have completed auth before Trio subscribed or bonded may be unobservable.
8. Enable control notifications and write the EGV request opcode (`0x4e`) with response.
9. Sustain EGV reads with multiple triggers: first write after control notify enables; additional writes when a bonded authenticated auth payload arrives **after** control path is already live (`auth_transition`); **330s** fallback timer re-armed after each successful control write ack; optional OS **connection events** after scan (MOD-E) to re-run the attach ladder when the Dexcom app reconnects the sensor.
10. Parse EGV responses using G7SensorKit's field layout: message timestamp, age, glucose, algorithm state, trend rate, predicted glucose, calibration/display-only byte. Reading time is `activationDate + (messageTimestamp - age)`, where **`activationDate` is anchored once per connect cycle** from the first parsed message’s `now - messageTimestamp` (MOD-C).
11. Save a source-tagged `TrioComplicationSnapshot` and update `WatchState`.

## Attach and filtering strategy

This implementation uses standalone DiaBLE-style tolerant matching rather than iPhone-bridged exact names. It accepts candidates with G7-style names (`DXCM`, `DX02`, `DX01`, `Dexcom`), advertised `FEBC`/data service, or connected-service retrieval provenance. This minimizes dependency on phone relay freshness and aligns with the same-watch observer premise.

Attach order:

1. `retrievePeripherals(withIdentifiers:)` from a watch-local persisted peripheral identifier.
2. `retrieveConnectedPeripherals(withServices:)` for `FEBC` and the G7 data service.
3. Broad `scanForPeripherals(withServices: nil)` with verbose advertisement logging, then `registerForConnectionEvents` for G7 service UUIDs (MOD-E).

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
8. **Auth advance condition:** Prefer `authenticated && bonded` before advancing; log partial auth when bonded is false; **6s** permissive fallback still advances if no gate-satisfying packet (PR 30-style gate with PR 29 escape hatch).
9. **EGV cadence:** Send when control notify enables; again on post-advance bonded authenticated auth traffic (`auth_transition`); **330s** fallback from successful write acks; **60s** backoff only when control is not yet ready.
10. **Control-write failures:** Log NSError fields; **up to three** **10s** spaced retries on the same connection for transient control write failures, then reconnect with `control_write_retries_exhausted`; non-control write errors still reconnect immediately.
11. **Backfill:** Discover and enable/log backfill, parse no historical samples in this pass. This keeps startup unblocked while preserving telemetry for a future backfill implementation.
12. **Stop scanning after connect:** Yes. Battery is preserved and disconnect-driven retry handles reattach.
13. **Multi-peripheral disambiguation:** Prefer persisted identifier, then first matching connected-service candidate, then first matching scan candidate. RSSI/name are logged for device-test analysis.
14. **Peripheral identifier persistence:** Watch-local `UserDefaults.standard`, updated after successful EGV. It is not App Group because only the watch app observer needs it.
15. **Delta computation:** Compute locally from the last direct-BLE reading in process. First direct BLE sample uses `"--"`.
16. **Dedup/winner policy:** Store `shouldUpdate` keeps newer-wins outside **±1s**; within **±1s**, same glucose+trend uses **source priority** (BLE > WatchConnectivity > HealthKit) so the reliability path wins races (MOD-D). `minInterval: 5` keeps complication reload responsive.
17. **UI palette:** Six states plus last-event age. This makes "BLE working recently" visible even when the displayed reading source is not BLE.
18. **Active-name filter changes:** Not applicable; no iPhone-bridged filter.
19. **Attach-ladder cadence:** Single synchronous sweep followed by scan; failures schedule reconnect. This keeps behavior explainable in logs.

## Deviations from references

- G7SensorKit gates control enable on `authenticated && bonded`; Trio **matches that gate for the primary path** and uses a **short permissive fallback** (6s) so the observer still advances if status is incomplete when Trio subscribes late (synthesis MOD-B).
- G7SensorKit uses targeted service/characteristic discovery through its peripheral manager; Trio uses broad discovery to match DiaBLE's watch behavior and improve diagnostics.
- DiaBLE includes active auth behavior outside test/eavesdrop mode; Trio omits all auth-write paths to enforce observer-only posture.
- Backfill is logged but not actively requested or merged; this pass focuses on sustained live EGV delivery.

## Known risks and device-test questions

- **Trigger mix:** Compare `g7_ble_egv_request_sent` reasons (`auth_transition`, `fallback_timer_330s`, `control_write_retry`) in BetterStack to see which path dominates; simplify if one is dead code.
- **Auth fallback:** Whether 6s is optimal vs stall rates; auth partial logs (`g7_ble_blocked_auth_partial`) vs fallback fires.
- **`registerForConnectionEvents` on watchOS:** May be a no-op on some OS builds; `g7_ble_connection_event` volume validates MOD-E.
- Broad scanning may have battery cost during failure loops, though scan windows are timeout-bounded.
- Xcode target membership for new Swift files is pending human wiring by design.

## Changelog

### v2 (2026-04-24 23:19 CET)
- Documented **implementation synthesis**: PR 29 base rationale, retention of guarded scan timeout (vs PR 30 no-timeout), and grafted mods **MOD-A** through **MOD-E** with donor PRs (30 / 24) and links to the synthesis blueprint and variant diffs.
- Aligned protocol narrative and design-question answers with shipped behavior: strict-preferred auth + 6s fallback, 330s EGV fallback + auth-transition + write-ack scheduling, control-write retry budget, activation anchoring, connection-event attach hook, and source-priority dedup tie-break.

### v1 (2026-04-24 20:41 CET)
- Created the clean-room observer design for the watch-only G7 BLE observer.
- Recorded design choices and open-question answers so the implementation can be compared against other attempts and tested on device.
