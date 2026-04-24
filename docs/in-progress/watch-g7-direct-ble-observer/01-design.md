# Watch G7 direct BLE observer — design

**Version:** v1  
**Status:** Draft (device validation pending)  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 16:02 CEST  

---

## Mission

Trio’s watch app extension **eavesdrops** on the Dexcom G7 session that the **official Dexcom G7 watch app** already holds in direct-to-watch mode, using **same-device CoreBluetooth**: Trio’s `CBCentralManager` gets its own GATT view, subscribes to auth/control notifications, and **writes the EGV-request opcode** on the control characteristic. The goal is **sustained delivery of many EGV readings over time**, not a one-shot read.

Trio does **not** own authentication (no J-PAKE, no app-key auth, no `sendAuthRequest`); it only **observes** auth traffic and **requests data** once the session is ready per the advance condition below.

**References (read-only, not copied into the tree):** G7SensorKit `G7BluetoothManager.swift`, `G7Sensor.swift`, `G7GlucoseMessage.swift`, `AuthChallengeRxMessage.swift`, `BluetoothServices.swift`; DiaBLE `BluetoothDelegate.swift`, `DexcomG7.swift`.

---

## Protocol sequence (high fidelity)

1. `CBCentralManager` with **restore identifier** (G7SensorKit, DiaBLE pattern).
2. **Attach ladder:** `retrievePeripherals(withIdentifiers:)` (last good UUID) → `retrieveConnectedPeripherals` with `FEBC` then `F8083532-…` (cgm) → **scan** `FEBC` with allow-duplicates and `registerForConnectionEvents` (G7SensorKit `managerQueue_scanForPeripheral` + connection events; DiaBLE retrieval from FEBC + broad scan when needed).
3. `connect` with `CBConnectPeripheralOptionNotifyOnConnectionKey` + `NotifyOnDisconnectionKey` (foreground awareness; G7 often uses `nil` options — we adopt notify keys for diagnosability without changing auth).
4. **Services:** `discoverServices` for cgm + serviceB (J-PAKE service exists for **discovery-only** logging; **no notify** on J-PAKE characteristics — `g7_ble_jpake_discovered` / `g7_ble_jpake_skipped` style).
5. **Characteristics:** `discoverCharacteristics(nil, for: cgm)` (DiaBLE `discoverCharacteristics(nil,for:)` after `discoverServices` — full discovery, not a minimal UUID list).
6. Enable **auth** notify first; on **AuthChallengeRx** `0x05` with `isAuthenticated && isBonded` (G7SensorKit `G7Sensor.bluetoothManager(_:peripheralManager:didReceiveAuthenticationResponse:)`), enable **control** notify, then **write** `0x4E` (glucose) to control **withResponse** (DiaBLE `DexcomG7.swift` connection comment: `write 3534 4E`).
7. Parse control notifications for opcode `0x4E` using the **G7SensorKit** `G7GlucoseMessage` field layout; compute reading time: `activationDate = now - messageTimestamp` on first EGV, then `readingDate = activationDate + glucoseTimestamp` (same as G7SensorKit `G7Sensor.handleGlucoseMessage` activation derivation).
8. **Backfill:** characteristics discovered; **not** used for gating. Log `g7_ble_backfill_ignored` for notify traffic — no active backfill in v1 to limit scope; can enable later (DQ 11).

**Safety:** no writes to the authentication characteristic except never — observer-only. No J-PAKE subscription.

---

## Peripheral discovery / attach strategy (DQ 2)

**Order (serialized in one `performWork` pass):**

1. `retrieved_identifier` — `UserDefaults` `g7directble.lastPeripheralUUID` when present.
2. `retrieved_febc` — `retrieveConnectedPeripherals(withServices: [FEBC])`.
3. `retrieved_data_service` — `retrieveConnectedPeripherals(withServices: [cgm])`.
4. `scan` — `scanForPeripherals` with `FEBC` + `registerForConnectionEvents` for `FEBC` and cgm (matches G7SensorKit).

**Stop scan** on `didConnect` (DQ 12).

---

## Filtering (DQ 1)

**DiaBLE-style standalone tolerances** on the watch: accept names with prefixes `DXCM`, `DX02`, `DX01`, `DEXCOM*`, or unknown name when advertisement already filtered by FEBC scan. **No** iPhone WatchConnectivity filter in v1 (adds no dependency, maximizes eavesdrop on shared radio).

---

## Central queue (DQ 5)

**Dedicated serial** `DispatchQueue` for `CBCentralManager` and all delegate callbacks (G7SensorKit `managerQueue` pattern). **Watch state / `TrioComplicationDataStore` / UI** are updated on **`MainActor`** via `Task { @MainActor in … }` from the BLE queue.

## Restoration (DQ 6)

**Yes** — `willRestoreState` logs and re-attaches delegate to restored peripherals. Same restore ID string as in G7SensorKit’s style (`kG7DirectBLERestoreIdentifier`).

## Connect options (DQ 7)

`NotifyOnConnection` + `NotifyOnDisconnection` so disconnect/reconnect is visible. Dexcom’s stack already holds the real link; these options only affect local notifications.

## Auth advance condition (DQ 8)

**G7SensorKit-consistent:** `AuthChallengeRxMessage` with `isAuthenticated && isBonded` before control notify + EGV write. If auth never reaches this, **90s watchdog** → `g7_ble_blocked_auth_incomplete` and UI `stalled`; keep retrying on disconnect/reconnect ladder (no auth-init from Trio). If field tests show **stall while Dexcom app has live data**, relax to `isAuthenticated` only in a follow-up (documented risk below).

## EGV cadence (DQ 9)

- On each qualifying **0x05** auth message: `send 0x4E`.
- **Timer:** every **4m50s** re-issue `0x4E` while connected (stays under typical 5-minute G7 cadence, matches “periodic nudge” need for multi-read delivery).
- On **reconnect**, timer resets with new `start()`.

## Control write failure (DQ 10)

Log `event=g7_ble_connect_failed source=control_write` with `error_desc=`. Do not tear down; rely on backfill of disconnect/restore and next connect attempt. If write repeatedly fails, watchdog + reconnect path applies.

## Backfill (DQ 11)

**Option (b):** discover, log, ignore for v1. Does not block startup.

## Scan after connect (DQ 12)

Stop scan in `didConnect` — no parallel scan when connected to one G7.

## Multi-peripheral (DQ 13)

If multiple G7 candidates appear, first **successfully connectable** wins in current ladder; when scanning, the **first** that passes the name filter. (Future: RSSI tie-break — not needed for single-sensor typical case.)

## Identifier persistence (DQ 14)

`UserDefaults.standard` key `g7directble.lastPeripheralUUID` after first successful EGV; cleared only when a human or future “forget sensor” exists — for POC, **never** auto-clear (DQ: stable retrieve path).

## Delta (DQ 15)

**Local delta** on the watch for G7 direct: store previous value in `G7ComplicationDeltaState`; recompute `delta` when a new G7 EGV supersedes. Phone path unchanged for WC/HK.

## Dedup / winner (DQ 16)

`TrioComplicationDataStore` keeps **newer `readingDate` wins**; on **tie**, priority **G7 direct > phone > healthKit** so low-latency eavesdrop can surface when timestamps collide. `save(..., minInterval: 5)` throttles widget reload.

## Source attribution (pipeline)

`TrioComplicationSnapshot.dataSource` + `WatchState.displayedComplicationDataSource` for the value **shown after winner policy**.

## UI (DQ 17, §6)

- **Status:** `G7DirectBLEStatus` (`off` / `searching` / `connecting` / `active` / `stalled` / `unavailable`) on `WatchState` + `lastG7DirectBLEEventDate` = last G7 event time (e.g. last EGV or active session touch).
- **Recency line:** `"{lastLoopTime} · src:Phone|BLE|… · G7:ok[2m]"` in `GlucoseTrendView` — one line, glanceable, detailed logs in BetterStack.

## Extended runtime (stretch)

**Not** included: foreground-active baseline is enough for the POC; omission logged in implementation log.

## Observability

`event=g7_ble_*` with `key=value` via `G7BLELog` (forwards `#file`/`#line`/`#function` to `WatchLogger`). **Never** emit `g7_ble_auth_request_sent` or J-PAKE write events from Trio.

## Deviations from references (with reason)

- **DiaBLE** runs full app auth when not in test mode; we **never** write auth bytes — this is the non-negotiable product constraint.
- **DiaBLE** `discoverServices(nil)`; we use **targeted** `[cgm, serviceB]` to discover J-PAKE service for “skipped” logging while still `nil` characteristics on cgm — balances DiaBLE’s broad discover with a clear Service B pass.
- **G7SensorKit** does not document the standalone `0x4E` write; **DiaBLE** does — we follow DiaBLE for the EGV nudge, G7SensorKit for parse/auth gating.
- **Connect options** — add notify keys; optional vs `nil` in G7SensorKit; chosen for debuggability on watch.

## Known risks (empirical)

- `isBonded` false while Dexcom app is live: possible stall; mitigation is the relaxation candidate above.
- **Compilation / target membership** not verified in this pass; Xcode must add new Swift files to the watch extension target.
- `WidgetCenter` in app extension may need deployment target and capability; if compile fails, gate `reloadAllTimelines` in follow-up (left unconditional per spec).

---

## Changelog

### v1 (2026-04-24 16:02 CEST)

- Initial design: eavesdrop sequence, DQs, pipeline, UI, and risks for watch-only G7 observer POC.
