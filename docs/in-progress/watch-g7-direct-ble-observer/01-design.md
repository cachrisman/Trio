# Watch G7 direct BLE observer — design

**Version:** v2  
**Status:** Draft (device validation pending)  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 17:24 CEST  

---

## Mission

Trio’s watch app extension **eavesdrops** on the Dexcom G7 session that the **official Dexcom G7 watch app** already holds in direct-to-watch mode, using **same-device CoreBluetooth**: Trio’s `CBCentralManager` gets its own GATT view, subscribes to auth/control notifications, and **writes the EGV-request opcode** on the control characteristic. The goal is **sustained delivery of many EGV readings over time**, not a one-shot read.

Trio does **not** own authentication (no J-PAKE, no app-key auth, no `sendAuthRequest`); it only **observes** auth traffic and **requests data** once the session is ready per the advance condition below.

**References (read-only, not copied into the tree):** G7SensorKit `G7BluetoothManager.swift`, `G7Sensor.swift`, `G7GlucoseMessage.swift`, `AuthChallengeRxMessage.swift`, `BluetoothServices.swift`; DiaBLE `BluetoothDelegate.swift`, `DexcomG7.swift`.

## Baseline: `dev` + patches 01–10

The implementation is integrated on **`dev` with `patches/01-*.patch` … `patches/10-*.patch` applied** (watch complication data store, session/telemetry, etc.). The G7 observer **extends** the existing `Trio Watch Shared/TrioComplicationDataStore` (optional `TrioComplicationDataSource` on `TrioComplicationSnapshot`); it does **not** replace that store with a duplicate.

---

## Protocol sequence (high fidelity)

1. `CBCentralManager` with **restore identifier** (G7SensorKit, DiaBLE pattern).
2. **Attach ladder:** `retrievePeripherals(withIdentifiers:)` (last good UUID) → `retrieveConnectedPeripherals` with `FEBC` then cgm service → **scan** `FEBC` with allow-duplicates and `registerForConnectionEvents`.
3. `connect` with `CBConnectPeripheralOptionNotifyOnConnectionKey` + `NotifyOnDisconnectionKey`.
4. **Services:** `discoverServices` for cgm + serviceB (J-PAKE service for **discovery-only** logging; **no notify** on J-PAKE).
5. **Characteristics:** `discoverCharacteristics(nil, for: cgm)`.
6. Enable **auth** notify first; on **AuthChallengeRx** `0x05` with `isAuthenticated && isBonded`, enable **control** notify, then **write** `0x4E` to control **withResponse**.
7. Parse EGV with **G7GlucoseMessage** field layout; activation: `Date() - messageTimestamp` on first EGV.
8. **Backfill:** log only; does not gate.

**Safety:** no auth writes; no J-PAKE subscription.

---

## Dedup / source (DQ 16, post-patch integration)

- **Newer `readingDate` wins.**
- **Within ±1s** with same glucose/trend/delta: **higher** `TrioComplicationDataSource` priority can replace (`g7DirectBLE` > `watchConnectivityPhone` > `healthKit` > unknown).
- Saves use `TrioComplicationDataStore.save(..., minInterval: 5)`.

## Source attribution (pipeline)

- `TrioComplicationSnapshot.dataSource` (optional) + `WatchState.displayedComplicationDataSource` for the main view.

## UI (DQ 17)

- G7 status on `WatchState` + `GlucoseTrendView` recency line (`src:`, `G7:` line).

## Observability

- `event=g7_ble_*` via `G7BLELog` → `WatchLogger`.

## Known risks

- Device / Xcode: add new G7 `*.swift` files to the Watch App Extension target.
- Fingerprint in App Group: new optional `dataSource` field; older fingerprints decode with `dataSource: nil` (treated as unknown).

---

## Changelog

### v2 (2026-04-24 17:24 CEST)

- Documented integration on **dev + patches 01–10** and use of **shared** `TrioComplicationDataStore` + `dataSource` (no duplicate G7 store).

### v1 (2026-04-24 16:02 CEST)

- Initial design: eavesdrop sequence, DQs, pipeline, UI, and risks for watch-only G7 observer POC.
