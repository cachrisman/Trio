# Trio Watch G7 Direct BLE Observer — Design

## Mission & premise
Implement a watch-only Dexcom G7 observer that piggybacks the same-device BLE session owned by Dexcom G7 watch app, requests EGV over Trio's own control-characteristic channel, and continuously feeds `TrioComplicationDataStore` for faster watch UI/complication updates.

## Protocol sequence
1. Long-lived, restoration-backed `CBCentralManager` is allocated eagerly.
2. On foreground active, attach ladder starts: `retrieveConnectedPeripherals(withServices:[cgmService])` then broad scan.
3. On connect, discover all services/characteristics (`nil` discovery breadth).
4. Enable auth notify, control notify; discover backfill + J-PAKE and log explicit skip for active use.
5. Observe auth payload (`0x05`) only; no auth writes, no J-PAKE ownership writes.
6. After `isAuthenticated == true`, write glucose request opcode (`0x4e`) to control.
7. Parse control notifications as G7 glucose payloads and save snapshots with source `.directBLE`.

References used: DiaBLE watch `BluetoothDelegate.swift` / `DexcomG7.swift`; G7SensorKit `BluetoothServices.swift`, `Messages/G7Opcode.swift`, `Messages/AuthChallengeRxMessage.swift`, `Messages/G7GlucoseMessage.swift`.

## Filtering & attach strategy
Chose DiaBLE-style tolerant watch-local matching (name/advertisement FEBC). No iPhone bridge in this pass to maximize standalone attach reliability and reduce coupling risk.

## Reconnect & lifecycle
- Start on scene `.active` via `WatchState.handleForegroundActiveEntry`.
- No proactive teardown on `.inactive`/`.background`.
- Retry on scan timeout, connect fail, and disconnect with simple fixed delay (3s), reset on successful connect.
- Scan timeout is guarded so it does not tear down a connected session.

## UI indicator
Main watch glucose view footer is extended to show:
- source of displayed reading (`SRC: BLE/PHONE/HK/?`)
- BLE status (`OFF/SEARCH/CONN/ACTIVE/STALL/UNAV`)
- last direct-BLE activity recency (`Xm`)

## Source attribution model
`TrioComplicationSnapshot` gets optional `source: TrioComplicationDataSource` and data-path writes set:
- Direct BLE observer: `.directBLE`
- iPhone WatchConnectivity payload path: `.watchConnectivity`
- HealthKit observer path: `.healthKit`

## Observability
All observer logs use `WatchLogger` with `event=g7_ble_*` keys. Includes discovery detail, connect source attribution, characteristic discovery, auth payload previews, control writes, EGV receipts, snapshot saves, and session outcomes.

## Design-question decisions
1. **Filtering:** tolerant standalone (DiaBLE-like). Better watch-only resilience.
2. **Attach order:** connected-peripheral retrieval first, then scan; fastest attach if Dexcom session already live.
3. **Discovery breadth:** `discoverServices(nil)` + `discoverCharacteristics(nil,for:)`; avoids missing variants.
4. **Timeouts:** 12s scan timeout, 3s reconnect delay; fast retries without busy spin.
5. **Central queue:** `queue:nil` (main queue semantics) + `@MainActor` state/store writes.
6. **Restoration:** enabled; logs restoration keys and resumes attach when powered on.
7. **connect options:** `NotifyOnDisconnection=true` for visibility and reconnect trigger.
8. **Auth advance:** require observed `isAuthenticated`; ignore bonded strictness to avoid false stall.
9. **EGV cadence:** one request per connect/auth-ready cycle; reconnect loop re-issues over time.
10. **Control-write failure:** log + reconnect.
11. **Backfill:** discover + explicit skipped logs in this POC (non-gating).
12. **Scan stop after connect:** yes.
13. **Multi-peripheral:** pick first strong candidate from retrieve/scan; reconnect handles wrong pick.
14. **Identifier persistence:** none for POC; rely on live retrieval/scan.
15. **Delta on watch:** unset (`--`) for direct BLE POC.
16. **Winner policy:** existing store dedup/minInterval remains; source tagging adds visibility.
17. **UI palette:** use 6-state compact text + source + recency on main footer.
18. **Active-name mid-session:** N/A (no iPhone bridge).
19. **Attach ladder cadence:** single immediate sweep per cycle; retry loop handles repeats.

## Deviations from references
- Did not implement backfill parsing in this pass to keep attach path simpler.
- Used fixed-delay reconnect instead of more dynamic scheduling.
- Chose compact Trio-specific UI/status model instead of reference app UI patterns.

## Risks / open test questions
- Exact EGV control-write shape may need on-device adjustment beyond single-byte opcode.
- Auth-gate permissiveness might still be too strict/loose on some sensor states.
- WatchOS connection churn characteristics need empirical tuning of timeout/backoff constants.
