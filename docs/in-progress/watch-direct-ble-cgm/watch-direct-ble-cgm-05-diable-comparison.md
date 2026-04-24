# Report: DiaBLE vs Trio Watch G7 BLE Comparison

**Version:** v1.10  
**Status:** Active — historical v1.2 report preserved; the v1.10 addendum is the current active layer after the deployed/live build 166 F4 watch review and the Trio Phone / G7SensorKit cross-check. Build 166 produced the first watch-side `g7_ble_did_connect` / `g7_ble_connected` and one moved timeout boundary at `awaiting_gatt_setup`, but still no service / auth / control / EGV / snapshot milestone. The next planned sequence is `F5` post-connect GATT attribution closure, then `F6` or `F7` only if `F5` leaves those discovery callbacks as the first unsatisfied gate; `F8` is an audit / attribution subtask unless `F5` exposes a real readiness bug, and `F9` remains an analysis track. PacketLogger / raw capture remains deferred while the current watch-only logs are still moving the boundary.  
**Created:** 2026-04-14 00:38 CEST  
**Last updated:** 2026-04-16 17:16 BST  

**Related docs:** [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md), [watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md), [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md), [watch-direct-ble-cgm-04-diaBLE-logs.md](watch-direct-ble-cgm-04-diaBLE-logs.md)  
**Primary references:** `DiaBLE/DiaBLE/BluetoothDelegate.swift`, `DiaBLE/DiaBLE/DexcomG7.swift`, `DiaBLE/DiaBLE/Dexcom.swift`, `Trio Watch App Extension/G7DirectBLEManager.swift`, `G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift`, `G7SensorKit/G7SensorKit/G7CGMManager/G7Sensor.swift`, `G7SensorKit/G7SensorKit/G7CGMManager/G7CGMManager.swift`, `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, `watch-direct-ble-cgm-04-diaBLE-logs.md`

---

## Scope

This report compares the working DiaBLE watch Dexcom G7 BLE path against the current Trio watch implementation on branch `feature/watch-direct-ble-cgm`.

- DiaBLE runtime outcome is grounded in the proven watch log captured in `watch-direct-ble-cgm-04-diaBLE-logs.md`.
- Trio implementation state in this report includes the current isolation-test deltas:
  - App Group persistence for the active G7 peripheral name
  - `g7_ble_retrieve_result count=...` instrumentation
  - temporary `WKExtendedRuntimeSession` disablement at connect / renewal time
- Trio runtime outcome is still based on the last known failing watch behavior until this new isolation build is run on hardware.

---

## Comparison Matrix

| Area | DiaBLE Watch | Trio Watch | Remaining divergence | `didConnect` stall assessment |
| --- | --- | --- | --- | --- |
| 1. Pre-connect: peripheral discovery path | On `poweredOn`, DiaBLE first tries `retrieveConnectedPeripherals(withServices: [FEBC])`; if a Dexcom peripheral is retrieved it routes it through the same `didDiscover` path, otherwise it scans broadly and filters by Dexcom naming / preferred device pattern. | Trio calls `retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])` (Dexcom G7 **data** service `F8083532-849E-531C-C594-30F1F86A4EA5`), not **FEBC** — `FEBC` is the advertisement UUID used for **scanning**; retrieval matches **implemented** GATT services. Trio logs `event=g7_ble_retrieve_result count=<n> filter_armed=<bool>`, and only attaches when the peripheral name matches the phone-provided active sensor filter. If the filter is missing it blocks attach and logs `g7_ble_attach_blocked`; the filter is now preloaded from the App Group cache on launch. | Trio is stricter because it requires the phone-reported active sensor identity before attach. The launch-time race should now be materially reduced by cached App Group preload. Separately, Trio uses the **data-service** UUID for retrieval (vs FEBC in the DiaBLE column above) by design — see `G7DirectBLEManager`. | **Known suspect, partially mitigated.** Before the cache change, Trio could block itself before the first WC payload. The new cache should remove that race on subsequent launches, but runtime proof is still needed. |
| 2. Connection options | DiaBLE calls `manager.connect(peripheral, options: nil)`. | Trio calls `central.connect(peripheral, options: nil)`. | None. | **Confirmed non-issue.** Both use `options: nil`, so this is not a meaningful structural difference. |
| 3. `discoverServices` scope | DiaBLE uses `peripheral.discoverServices(nil)` and then inspects all discovered services. | Trio uses `peripheral.discoverServices([G7BLEUUID.dataService])`. | Trio narrows service discovery to the Dexcom data service instead of asking CoreBluetooth for all services. | **Unknown.** This is a concrete implementation difference, but there is no evidence yet that it explains a pre-`didConnect` stall. |
| 4. `discoverCharacteristics` scope | DiaBLE uses `peripheral.discoverCharacteristics(nil, for: service)` and then enables / skips characteristics based on UUID and mode. | Trio uses a targeted list: authentication, control, backfill, and J-PAKE on the Dexcom data service. | Trio is more restrictive; DiaBLE asks for all characteristics and then filters. | **Unknown.** This is post-connect behavior, so it cannot explain the missing `didConnect` directly, but it remains a post-connect divergence worth keeping visible. |
| 5. Post-connect runtime session | DiaBLE watch does not use `WKExtendedRuntimeSession` around `connect()`. | Trio contains `WKExtendedRuntimeSession` machinery, but this isolation-test build now skips starting it at connect time and on foreground renewal, logging `event=g7_ble_ext_session_skipped reason=isolation_test`. | Prior Trio builds started the extended session before `connect()`. This isolation build intentionally removes that one structural difference at connect time while keeping the rest of the manager unchanged. | **Known suspect.** This is the clearest structural difference being isolated in the current build. If `didConnect` starts firing now, the runtime session path was interfering. |
| 6. Auth sequence | In test/eavesdrop mode, DiaBLE enables auth notify, explicitly skips J-PAKE notifications, waits for `0x03`, waits for `0x05`, confirms `authenticated: true, bonded: true`, then enables control notify. It does not perform J-PAKE ownership in observer mode. | Trio now mirrors the observer path: auth notify on, explicit `g7_ble_jpake_skipped`, no auth-init write, no J-PAKE subscribe, `0x03` observed, `0x05` parsed with both `authenticated` and `bonded` required before proceeding. | The main observer-path divergence is closed. DiaBLE still issues extra control commands after auth for diagnostics; Trio intentionally stays minimal. | **Confirmed non-issue for the current stall.** All of this happens after `didConnect`, so it cannot explain the connect timeout itself. |
| 7. GATT readiness gate | DiaBLE effectively considers the watch observer path ready once auth is satisfied and control notifications are enabled; backfill is optional and only enabled later in test/eavesdrop flows. | Trio now gates startup readiness on auth notify enabled, `0x05 authenticated=true bonded=true`, and control notify enabled. Backfill no longer blocks the initial EGV happy path. | No material divergence for observer mode. | **Confirmed non-issue for the current stall.** This is post-connect gating and does not explain missing `didConnect`. |
| 8. `0x4E` request trigger | DiaBLE reaches control notify and then sends the EGV request on control, after the authenticated / bonded state is already established by the owner session. | Trio sends `0x4E` only after the status gate is satisfied and control notify is ready; blocked cases now log `g7_ble_egv_request_blocked`. | Behavior is intentionally aligned. DiaBLE sends additional control commands after auth for richer introspection; Trio keeps only the minimum observer request. | **Confirmed non-issue for the current stall.** This logic is downstream of a successful connection. |
| 9. Disconnect / reconnect | DiaBLE logs disconnects, then for Dexcom sleeps briefly and restarts FEBC scanning to reconnect. | Trio tears down state, logs the outcome, and schedules a 7-second reconnect / rescan when the disconnect is unexpected and foreground scanning is still desired. | Different reconnect pacing and bookkeeping. | **Unknown but low priority for the present issue.** This matters after a connected session exists, not before `didConnect` ever fires. |
| 10. Known outcome | DiaBLE watch: proven `didConnect`, services/characteristics discovered, `0x03`, `0x05 authenticated=true bonded=true`, control notify enabled, `0x4E` received, EGV parsed, reconnect path exercised. | Trio watch: last observed hardware outcome before this isolation build was `awaiting_connect` timeout with no `g7_ble_connected` event. The current code now adds cached filter arming, retrieve-result diagnostics, and ext-session skipping, but those changes are not yet runtime-validated. | Trio still lacks a new proof log showing whether `didConnect` now fires. | **Open.** This is the unresolved problem statement the current isolation build is meant to answer. |

---

## Focused Pre-connect Path Comparison (2026-04-14)

This section compares the exact pre-connect code path — from `CBCentralManager` creation through the `connect()` call — between the two implementations. This is the key diagnostic material for Phase E / build 162.

### `CBCentralManager` creation

| Property | DiaBLE Watch | Trio Watch |
|----------|-------------|------------|
| **Timing** | Eager — created in `MainDelegate.init()` at app launch | Lazy — created in `startScanning()` on first foreground entry |
| **Queue** | `nil` (CoreBluetooth dispatches to main) | `.main` (explicit) |
| **Options** | `[CBCentralManagerOptionRestoreIdentifierKey: "DiaBLE"]` | `[CBCentralManagerOptionShowPowerAlertKey: false]` |
| **State restoration** | Yes — CoreBluetooth can re-deliver pending connections | No — pending connections are lost on relaunch |
| **`willRestoreState` delegate** | Present (logs restored peripherals) | Not implemented |

### `.poweredOn` handling

| Behavior | DiaBLE Watch | Trio Watch |
|----------|-------------|------------|
| `retrieveConnectedPeripherals` | Called inside `.poweredOn` handler — can return results | Called inside `startScanning()` **before** manager reaches `.poweredOn` on first launch — always returns empty |
| Scan start | Only if retrieval returns nothing | Always starts scan; retrieval result is pre-emptied by timing |

### `didDiscover` → `connect()` path

| Behavior | DiaBLE Watch | Trio Watch |
|----------|-------------|------------|
| `stopScan()` | Immediate | Immediate |
| Between `stopScan()` and `connect()` | Nothing — calls `connect` directly | Prior builds: started `WKExtendedRuntimeSession` between stop and connect. Current isolation builds: skipped. Spawns `async Task` for logging. |
| `peripheral.state` check before `connect()` | None explicit | None explicit |
| `connect()` options | `nil` | `nil` |

### What Phase E is really about: connect-context parity

The core question is not "which single API option is wrong?" but **"what runtime context is Trio in when it calls `connect()`, and how does that differ from the context DiaBLE is in?"** DiaBLE reaches `connect()` from a clean, early-launch `CBCentralManager` with state restoration, inside a `.poweredOn` handler that already confirmed the manager is live. Trio reaches `connect()` from a lazily-created manager, after an async scan path, with no state restoration, and (in prior builds) with a `WKExtendedRuntimeSession` starting in between. The individual API differences in the table above are symptoms; the underlying gap is session/lifecycle/runtime context at the moment `connect()` fires.

Phase E instruments that context (Task E1) and makes one parity change (Task E3: restore identifier) that is the **selected first experiment**, not a proven fix. If the instrumentation reveals unexpected `peripheral.state` or `central.state` values, the root cause may be something else entirely — a watchOS lifecycle transition that invalidated state, a double-connect from a prior attempt, etc. The pre-connect snapshot is the primary diagnostic; the restore key is a concrete experiment to run alongside it.

### Ranked plausible causes for missing `didConnect`

The ranking below groups causes by theme. **Runtime/context issues** (how Trio reaches `connect()`) are the strongest category overall; individual API-level differences are experiments within that frame.

| # | Cause | Category | Likelihood | Addressed in build 162? |
|---|-------|----------|------------|------------------------|
| 1 | **`WKExtendedRuntimeSession` starting immediately before `connect()`** — CoreBluetooth may have deferred or dropped the connection while the runtime context was being renegotiated | Runtime context | Likely | Yes — already isolated (disabled at connect time since builds ~158) |
| 2 | **Unknown runtime state at `connect()` time** — Trio has no observability into whether the peripheral is already `.connecting` / `.connected`, whether the central is actually `.poweredOn`, or whether the session is a preserved re-entry vs a fresh start | Runtime context | Likely (instrumentation gap) | **Yes — Task E1 captures it** |
| 3 | **Missing `CBCentralManagerOptionRestoreIdentifierKey`** — without state restoration, watchOS cannot re-deliver pending connections after lifecycle transitions; DiaBLE has this, Trio does not | API config | Plausible | **Yes — Task E3 adds it (selected first experiment)** |
| 4 | **`retrieveConnectedPeripherals` always empty on first launch** — Trio calls it before `.poweredOn`, missing already-connected peripherals | Timing | Plausible | **Yes — Task E2 retries inside `.poweredOn`** |
| 5 | **`CBCentralManager` queue `nil` vs explicit `.main`** — implementation-defined CoreBluetooth behavior difference | API config | Plausible (weak) | No — deferred to Phase F |
| 6 | **`async Task` spawns between `stopScan()` and `connect()`** — unlikely to cause a miss but adds indirection to the connect path | Runtime context (minor) | Weak | No — acceptable risk for now |
| 7 | **Scan filter `[FEBC]` vs `nil`** — DiaBLE scans broadly; Trio filters on `FEBC` | API config | Weak / dead end | No — peripheral is discovered, so the filter works |

---

## Focused Conclusions

1. The observer-path auth / control / `0x4E` behavior is no longer the primary suspect for the missing Trio `didConnect`; those divergences have been narrowed substantially.
2. The strongest remaining hypothesis is that **Trio reaches `connect()` from a different runtime context than DiaBLE** — a combination of lifecycle state, manager readiness, peripheral ownership, and session history that CoreBluetooth treats differently on watchOS. The individual API-level differences (restore key, retrieval timing, queue) are concrete experiments within that broader frame.
3. **Phase E / build 162** addresses this by:
   - **Task E1:** Capturing the exact runtime context at `connect()` time — `peripheral.state`, `central.state`, source path, first-attempt vs reconnect, preserved vs fresh session. This is the primary diagnostic.
   - **Task E2:** Fixing `retrieveConnectedPeripherals` timing to match DiaBLE (inside `.poweredOn` where it can return results).
   - **Task E3:** Adding `CBCentralManagerOptionRestoreIdentifierKey` as the selected first parity experiment (plausible improvement, not a proven fix).
   - Extended runtime remains disabled at connect time (already isolated since ~build 158).

---

## Next Hardware Questions (build 162)

1. **What runtime context does Trio have at `connect()` time?** Does `g7_ble_pre_connect` show `peripheral_state=0 central_state=5` (nominal), or does it reveal an unexpected state that explains the stall?
2. Does `g7_ble_retrieve_on_powered_on count=1` ever fire with a matching peripheral?
3. Does `g7_ble_will_restore_state` fire, and if so, what keys does it report?
4. **Primary question:** Does Trio now emit `g7_ble_connected` or still fall into `g7_ble_timeout stage=awaiting_connect`?
5. If still failing after E1–E3: the instrumentation from E1 should narrow the cause. Proceed to Phase F with the specific context gap identified (e.g. `queue: nil`, `discoverServices(nil)`, or a lifecycle-specific fix).

---

> **Active-layer note:** The preserved sections above are the historical v1.0-v1.2 report and remain intact for traceability. The current ranking, focused conclusions, and next-step sequence are the v1.7 addendum below.

## Updated Comparison Report — v1.9 (2026-04-16)

**Status:** Active addendum — current active comparison layer after the deployed/live build 166 F4 watch review and Trio Phone / G7SensorKit cross-check. Build **166** now proves watch-side **`g7_ble_did_connect`** can happen in Trio Watch, but only once so far, and the best build-166 session still stalls before **`g7_ble_services_discovered`**. **PacketLogger / raw capture** remains deferred while the current watch-only logs are still providing actionable stage movement.  
**Scope:** Connect-establishment plus the immediate post-connect GATT-startup boundary now that watch-side **`g7_ble_did_connect`** has been proven once.  
**Evidence base:** Current Trio `feature/watch-direct-ble-cgm` watch code, current Trio Phone `G7SensorKit` code, current DiaBLE source, `watch-direct-ble-cgm-02-implementation-plan.md` through v1.45 / the build 165 and build 166 watch reviews, `watch-direct-ble-cgm-03-instrumentation-report.md` through v1.33, and the DiaBLE watch log captured in `watch-direct-ble-cgm-04-diaBLE-logs.md`.

### Updated Comparison Report

The current evidence now proves watch-side Trio **`didConnect`** can happen, but it still does **not** prove stable post-connect progression. The active comparison is therefore no longer purely pre-connect: the first unsatisfied gate has moved to the boundary between **connect establishment** and **immediate GATT startup / service discovery**.

Relative to the historical v1.2 report, the main changes are now:

- Phase E corrected the `.poweredOn` retrieval timing in code, added the restore identifier and `willRestoreState`, and closed the main pre-connect observability gaps with `g7_ble_pre_connect` and `g7_ble_retrieve_on_powered_on`.
- Phase F / F1 proved that the current stall was still at the **connect-boundary callback-delivery** layer in build 163: Trio emitted a closed watch-side trail through `g7_ble_connect_attempt -> g7_ble_connect_timeout_armed -> g7_ble_timeout stage=awaiting_connect`, with no watch-side `g7_ble_did_connect`, `g7_ble_did_fail_to_connect`, or `g7_ble_did_disconnect` before timeout.
- Phase F / F2 then showed that `queue: nil` did **not** materially change that stall in build 164 across **7** reviewed watch-side connect attempts.
- The completed build **165 / F3** review stayed fully negative across **9** watch-side connect attempts: the watch still never crossed `didConnect`.
- Build **166 / F4** is the first build in this cycle to show positive connect-boundary movement: **17** watch-side connect attempts include **1** watch-side **`g7_ble_did_connect`**, **1** **`g7_ble_connected`**, **1** **`g7_ble_connect_timeout_canceled reason=did_connect`**, and **1** session whose final outcome is **`final_stage=discovering_services`** with timeout at **`awaiting_gatt_setup`**.
- The same build-166 review also matters for retrieval interpretation: the only session that reached **`didConnect`** used **`source=retrieved`**, while the remaining **16** attempts still timed out at **`awaiting_connect`** from the scan path.
- Trio Phone still matters as a **same-product reference path**: `G7SensorKit` successfully reads G7 data in Trio on iPhone, so the Trio-specific downstream Dexcom read / parse path is already proven somewhere in the product. That does **not** prove watch behavior, but it does sharpen which watch-specific gaps still deserve active weight.

The Trio Phone / G7SensorKit cross-check remains useful because it shows how a **working Trio implementation** handles the same connect-establishment areas:

| Area | DiaBLE Watch | Trio Watch | Trio Phone (`G7SensorKit`) | Current implication |
| --- | --- | --- | --- | --- |
| `CBCentralManager` creation / lifecycle | Eager at app launch; restore identifier present; `willRestoreState` implemented. | Now initialized earlier in `G7DirectBLEManager.init()` with restore identifier present, `willRestoreState` implemented, and `startScanning()` reusing the already-lived manager in the normal path. | Eager in `G7BluetoothManager.init()` on a dedicated `managerQueue`; restore identifier present; `willRestoreState` restores peripherals. | This discrepancy is now corrected in code. Build **166** suggests it mattered: the first watch-side `didConnect` arrived only after Trio Watch adopted the earlier-lifecycle pattern. |
| `.poweredOn` entry and retrieval | Retrieval is performed from `.poweredOn`, then scanning continues only if nothing useful is returned. | Retrieval happens in `startScanning()` and again in `.poweredOn`; build **166** is the first review where a `source=retrieved` path reached `didConnect`, `connected`, and `discovering_services`. | `centralManagerDidUpdateState(.poweredOn)` calls the manager scan path, which first tries `retrievePeripherals(withIdentifiers:)` for the active peripheral and then `retrieveConnectedPeripherals(withServices: [advertisement, cgmService])` before scanning. | Retrieval timing is corrected in code and now appears runtime-relevant again because the only build-166 success path was retrieval-assisted. |
| Scan start / scan options | Broad scan: `scanForPeripherals(withServices: nil, options: nil)`. | Filtered scan: `withServices: [FEBC]`, `options: nil`. | Filtered scan: `withServices: [FEBC]`, `options: nil`, plus `registerForConnectionEvents` for the same service UUIDs. | Trio Phone success and the negative build-165 F3 result both weaken simple scan-option theory. It is no longer the active lead discrepancy. |
| Advertisement filtering / active-sensor attach | Normalizes Dexcom advertisement / local-name patterns and does not depend on a phone-fed exact-name contract. | Requires a phone-provided active peripheral name and only normalizes by trimming whitespace; non-exact matches are skipped. | `G7Sensor.shouldConnectPeripheral` matches `DXCM*` / `DX02*` advertisements by suffix against the known `sensorID`, and can also connect when `sensorID == nil` to discover a new sensor. Separately, the Trio Phone app sends the watch `AppleWatchManager.activeG7PeripheralNameForWatchPayload()` from exact trimmed `G7CGMManager.sensorName`. | Trio Watch still has the strictest attach contract: the phone path itself is tolerant, but the watch-facing contract depends on an exact relayed name. This remains real, though it is lower-confidence than the current connect/GATT boundary evidence. |
| `didDiscover` to `connect()` boundary | Shared discovery path; proven watch-side `didConnect`. | `didDiscover` or retrieval routes into `beginConnectToG7Peripheral`, stops scan, logs `g7_ble_pre_connect`, calls `connect(options: nil)`, and arms the 30 s `awaiting_connect` timeout. Build **166** proves this path can now cross `didConnect`, but only once so far and only from `source=retrieved`. | `handleDiscoveredPeripheral` routes through delegate policy (`ignore` / `connect` / `makeActive`) and calls `centralManager.connect(peripheral)` on the manager queue without the same watch-only timeout instrumentation. | The watch callback absence is no longer absolute. The active issue is now unstable / inconsistent connection establishment plus what happens immediately after the rare successful connect. |
| Connect-boundary callback visibility | Working watch log proves `didConnect` and the downstream observer milestones. | F1-F4 now show both behaviors: most build-166 attempts still die at `awaiting_connect`, but build **166** also proves the watch can emit `g7_ble_did_connect`, `g7_ble_connected`, and `g7_ble_connect_timeout_canceled reason=did_connect`. | Phone path has `didConnect`, `didFailToConnect`, and `didDisconnectPeripheral`, then rescans after failure / disconnect. | The timeout is still an observation boundary, but the current watch investigation has moved past “no callback ever arrives.” |
| Immediate post-connect proof | Proven full observer path to `0x4E`, EGV parse, and reconnect. | Build **166** now has one watch-side session through `didConnect` and `stage=discovering_services`, but still **0** `g7_ble_services_discovered`, `g7_ble_characteristics_discovered`, `g7_ble_auth_notify_enabled`, `g7_ble_control_notify_enabled`, `g7_ble_egv_received`, or `g7_ble_snapshot_saved`. | Successful live CGM read path through `G7Sensor`, `G7CGMManager`, and `sensorDidConnect` / `didRead`. | The first unsatisfied watch gate has moved from pure connect-callback delivery to immediate post-connect GATT / service discovery startup. |

### Discrepancy Status Table

Status labels are intentionally precise in this addendum:

- **`corrected in code`** means the structural code discrepancy is removed.
- That label does **not** mean the item solved the stall at runtime.
- Where runtime evidence now exists, the status line says so explicitly.

| Discrepancy / prior claim | Status | Evidence | Implication |
| --- | --- | --- | --- |
| launch-time active-sensor filter race / missing filter at attach time | partially corrected | `WatchState` now loads a cached active G7 peripheral name on init and persists later WC updates into the App Group cache; build 163/164/165 target selection and pre-connect state did not show an obvious attach-to-wrong-target failure. | Still a cold-start / empty-cache risk, but no longer a leading explanation for the current boundary. |
| retrieval timing mismatch relative to `.poweredOn` | corrected in code; runtime-relevant again | Trio now runs `retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])` inside `centralManagerDidUpdateState(.poweredOn)` before scanning. In build **166**, the only session that reached `didConnect` came from `source=retrieved`. | The old timing bug is fixed, but retrieval/attach context remains an active runtime clue. |
| missing restore identifier | corrected in code; runtime value still secondary | Current Trio manager init includes `CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"` and implements `centralManager(_:willRestoreState:)` with `g7_ble_will_restore_state`. | Missing restore support is no longer a current code gap. |
| queue `.main` vs `nil` | corrected in code; negative runtime result | Current Trio `HEAD` uses `queue: nil`; build 164 isolated that change across **7** reviewed watch-side connect attempts and still showed no watch-side connect callback. Trio Phone succeeds on a dedicated `managerQueue`, which further weakens any simple queue-choice theory. | This is no longer a current code difference, and the runtime result is negative. |
| connect-boundary observability gaps | corrected | Phase F / F1 added `g7_ble_connect_timeout_armed`, `g7_ble_connect_timeout_canceled`, `g7_ble_did_connect`, `g7_ble_did_fail_to_connect`, and `g7_ble_did_disconnect`. | Trio no longer lacks watch-side callback visibility at the connect boundary. |
| connect timeout ambiguity / lack of closed-trail logs | corrected | Build 163 produced a closed watch-side trail ending in `g7_ble_timeout stage=awaiting_connect`. Build 166 then added one watch-side `didConnect` trail and one `awaiting_gatt_setup` trail. | The active question is no longer "what happened?" but "why is the successful path rare and why does it still stall before services discovered?" |
| pre-connect state blind spots (`CBPeripheral.state`, `CBCentralManager.state`, preserved session, etc.) | superseded by new evidence | Phase E added `g7_ble_pre_connect`; builds 163-166 now show mostly sane pre-connect state even while the outcomes differ. | This is no longer an open blind spot. |
| scan option difference | negative runtime result / de-prioritized | Trio now scans with `withServices: [FEBC], options: nil` on the watch; DiaBLE scans broadly with `withServices: nil, options: nil`; Trio Phone succeeds with `withServices: [FEBC], options: nil`; the completed build **165** watch-only review covered **9** connect attempts and remained fully negative. | This is no longer the active lead theory. |
| extended-runtime start near connect | retired / dead end | Trio currently skips extended-runtime start at connect / renewal for the isolation build, and build 163 still timed out pre-connect. | Do not keep this alive as the primary current suspect. |
| observer/auth/control path differences | corrected in code | Trio now skips auth-init, logs `g7_ble_jpake_skipped`, requires `authenticated && bonded`, and gates `0x4E` on control-ready. | These are no longer active pre-connect suspects. |
| J-PAKE / auth-init / bonded gate / backfill gate differences | corrected in code | Current Trio observer-path code matches the intended DiaBLE-style observer path closely enough that these differences are downstream-only once Trio actually crosses `didConnect`. | Keep these out of the active pre-connect suspect list. |
| central-manager lifecycle mismatch (DiaBLE eager init vs Trio lazy foreground allocation) | corrected in code; partial positive runtime result | Trio Watch now allocates its manager earlier in `G7DirectBLEManager.init()` with the restore-backed lifecycle intact. Build **166** is the first watch review in this cycle to show `g7_ble_did_connect`, `g7_ble_connected`, and a moved timeout boundary at `awaiting_gatt_setup` / `final_stage=discovering_services`. | F4 appears to have had real connect-boundary impact, but it did not complete the end-to-end watch read. |
| immediate post-connect GATT startup / first service-discovery gate | still active | In build **166**, the only moved session reaches `g7_ble_stage stage=discovering_services` and later times out at `g7_ble_timeout stage=awaiting_gatt_setup`, with **0** `g7_ble_services_discovered`, `g7_ble_characteristics_discovered`, `g7_ble_auth_notify_enabled`, `g7_ble_control_notify_enabled`, `g7_ble_egv_received`, or `g7_ble_snapshot_saved`. | This is now the strongest active unresolved boundary in the watch path. |
| active-sensor exact-match / advertisement normalization asymmetry | still active | Trio requires the phone-provided active sensor name before attach (trim-only via `normalizedPeripheralName`); it does **not** apply Dexcom-style `DXCMxx` / `DX02xx` advertisement matching. DiaBLE can normalize advertisement/local-name forms, and Trio Phone succeeds with suffix-based `DXCM*` / `DX02*` matching in `G7Sensor.shouldConnectPeripheral` even though `AppleWatchManager` relays the watch an exact trimmed `G7CGMManager.sensorName`. | This remains a real attach-path asymmetry, but current evidence does not show it as the primary current blocker. |

### Remaining Top Discrepancies

Only the discrepancies below still meaningfully compete as the **current ranked plausible-cause list** after the build-166 F4 review.

1. **Immediate post-connect GATT startup / first service-discovery gate**
   Why it still matters: build **166** now proves the watch can cross **`didConnect`**, but the best session still stops at **`stage=discovering_services`** and later times out at **`awaiting_gatt_setup`** with no **`g7_ble_services_discovered`**.
   Type: `runtime-context / immediate post-connect issue`
   Rating: `likely`
2. **Retrieval-assisted success vs scan-path instability**
   Why it still matters: the only build-166 session that reached **`didConnect`** used **`source=retrieved`** after **`g7_ble_retrieve_result count=1`**. The remaining **16** build-166 attempts still died at **`awaiting_connect`** from the scan path.
   Type: `runtime-context issue`
   Rating: `plausible`
3. **Active-sensor filter / name-normalization asymmetry**
   Why it still matters: Trio Watch still depends on the phone-provided exact peripheral name after trim-only normalization, while DiaBLE and Trio Phone can work from more tolerant advertisement-driven matching. This remains lower confidence than the two boundaries above, but it is not fully retired.
   Type: `runtime-context issue`
   Rating: `weak`

Explicitly retired from the ranked list:

- central-manager lifecycle mismatch as an **open code discrepancy** (F4 corrected it in code and appears to have had partial positive runtime impact)
- simple queue-choice theory
- duplicate-suppression scan option as the active lead
- observer/auth/J-PAKE/backfill gating as pre-connect suspects
- extended-runtime-near-connect as the current root cause

### Focused Conclusions

1. Build **166** proves watch-side **`g7_ble_did_connect`** is now possible in current Trio Watch code. The old statement “watch-side `didConnect` is still unproven” is no longer accurate.
2. F4 appears to have mattered at the connect boundary. The first watch-side **`didConnect`**, **`connected`**, and **`connect_timeout_canceled reason=did_connect`** all arrive only after Trio Watch adopted earlier `CBCentralManager` allocation.
3. F4 did **not** complete the end-to-end watch read path. The first unsatisfied gate in build **166** is now immediate post-connect GATT startup / service discovery, not pure callback delivery.
4. Trio Phone still matters as a reference: it continues to prove that Trio’s downstream Dexcom read path already works in-product, so the watch investigation should stay tightly focused on watch-specific connect / attach / GATT-startup behavior.

### Evidence-Backed Recommendations

Use the same recent Phase F discipline: let the evidence move the boundary before selecting the next code change.

- Build **165 / F3** is now fully reviewed and negative: **9** watch-side connect attempts, all still timing out at **`awaiting_connect`**.
- Build **166 / F4** is now reviewed as a **partial positive result**: **17** watch-side connect attempts, **1** watch-side **`didConnect`** / **`connected`**, **1** **`final_stage=discovering_services`**, and still **0** downstream service / auth / control / EGV / snapshot milestones.
- **PacketLogger / raw capture** remains deferred while the current watch-only Better Stack evidence is still providing concrete stage movement.

1. **Treat F4 as partial success, not a negative result**
   Why current evidence justifies it: build **166** is the first watch build in this cycle to cross **`didConnect`** and to move a timeout from **`awaiting_connect`** to **`awaiting_gatt_setup`**.
   What this changes: the docs should no longer frame F4 as “the next experiment” or as a failed experiment. It is now a completed, live build with real but incomplete impact.
2. **Run F5 next: close the post-connect GATT trail before another parity guess**
   Target area: explicit service / characteristic / notify entry and success/failure attribution, plus clearer **`awaiting_gatt_setup`** arm / cancel evidence and debug-funnel blocker mapping.
   Why current evidence justifies it: build **166** already moved the boundary to the immediate post-connect layer; the highest-value next step is to make that boundary as closed and attributable as the pre-connect trail became in **F1**.
3. **Keep F9 as analysis context while F5 lands**
   Target area: continue splitting watch-only evidence by **`source=retrieved|scan`** so the one moved build-166 session is interpreted in context rather than collapsed into a generic “didConnect happened once” summary.
   Why current evidence justifies it: the only build-166 moved session used **`source=retrieved`**, while the remaining attempts still died at **`awaiting_connect`** from the scan path.
4. **Choose F6 or F7 only after F5 closes the first missing callback**
   Target area: if **F5** still leaves the first missing post-connect callback at service discovery / data-service presence, run **F6** (`discoverServices(nil)` parity). If service discovery succeeds and characteristic discovery remains the first missing gate, run **F7** (`discoverCharacteristics(nil, for:)` parity).
   Why current evidence justifies it: both are legitimate post-connect parity experiments now, but only one of them should come next, and only after the trail shows which layer is actually missing.
5. **Keep F8 as an audit / attribution task unless F5 proves a real readiness bug**
   Target area: startup-ready and timeout-cancel behavior around **auth notify + `0x05 authenticated=true bonded=true` + control notify**.
   Why current evidence justifies it: the current code already uses the intended observer-ready rule, so **F8** should not displace **F5** unless the newly closed trail shows a real mismatch.
6. **Keep PacketLogger / raw capture deferred unless the current watch-log analysis stops yielding new information**
   Why current evidence justifies it: the build-166 watch logs already moved the boundary materially without requiring raw capture, so PacketLogger still is not the immediate gate.

Guardrails for the current cycle:

- Do **not** rewrite the history to say build **166** solved watch direct BLE end-to-end; it did not.
- Do **not** keep describing Trio Watch as if it still allocates `CBCentralManager` lazily in `startScanning()`; that is now historical wording only.
- Do **not** reopen downstream observer / auth / J-PAKE design debates as if they were the current root cause; the first unsatisfied gate is now earlier than that.
- Do **not** change Trio Phone / `G7SensorKit` behavior as part of the watch evidence review; keep the phone path as a fixed reference.

### Evidence Hygiene Notes

- Watch-only Trio `g7_ble_*` logs remain the primary proof for Trio watch behavior.
- DiaBLE logs and DiaBLE code are reference behavior, not proof of Trio success.
- PacketLogger / raw capture is still a **deferred** parallel evidence track; it may become useful later, but it does not supersede the current watch-log proof.
- In this addendum, **`corrected in code`** means the code-level parity gap is closed; it does **not** mean the item was the sole cause or that the watch now reads the CGM successfully.
- Minimum proof of watch-side connect success is now met: build **166** produced **`g7_ble_did_connect`** on the watch.
- The new minimum proof that the bottleneck moved downstream is also met once: build **166** produced **`final_stage=discovering_services`** and timeout at **`awaiting_gatt_setup`**.
- The build-166 outcome was reconstructed with a small watch-only Better Stack search set: grouped event counts by build, grouped session outcomes by final stage, grouped timeouts by stage, grouped connect attempts by source, and the full timeline for the only **`didConnect`** session.

---

## Changelog

| Version | Date | Changes |
| --- | --- | --- |
| v1.10 | 2026-04-16 17:16 BST | Updated the active addendum to add the planned post-**F4** sequence: **F5** next for post-connect GATT attribution closure, **F9** as retrieval-vs-scan analysis context, then conditional **F6** / **F7** discovery-scope parity only after **F5** closes the first missing callback. Reframed **F8** as an audit / attribution task unless **F5** exposes a real readiness bug, and kept PacketLogger / raw capture explicitly deferred. |
| v1.9 | 2026-04-16 16:11 BST | Updated the active addendum after the deployed/live build **166** F4 review. The addendum now records build **166** as the first watch build in this cycle to emit **`g7_ble_did_connect`** / **`g7_ble_connected`** and to move one session to **`final_stage=discovering_services`** / **`awaiting_gatt_setup`**, while keeping the downstream service / auth / control / EGV / snapshot milestones at zero. Replaced the old “F4 next” framing with the current state, updated the lifecycle wording so Trio Watch is no longer described as still allocating `CBCentralManager` lazily, and documented the watch-only Better Stack search set used to understand the build-166 outcome. |
| v1.8 | 2026-04-15 19:26 BST | Updated the active addendum after the preliminary negative build **165** watch review. The active recommendation is now **F4 next**, with build **165 / F3** recorded as negative so far across **2** observed connect attempts, and **PacketLogger / raw capture** still deferred until after **F4** if Trio Watch still cannot read the CGM. |
| v1.7 | 2026-04-15 18:58 BST | Updated the active addendum after build **165** F3 deployment. The recommendation sequence is now **F3 review -> F4 if F3 is negative -> PacketLogger / raw capture only after both if the watch still cannot read the CGM**. Kept the historical sections intact and preserved manager lifecycle / launch context as the strongest remaining structural discrepancy. |
| v1.6 | 2026-04-15 16:54 BST | Added a Trio Phone / `G7SensorKit` cross-check to the active addendum so each current pre-connect / connect-boundary area now shows how the working Trio Phone path behaves, including the exact `G7CGMManager.sensorName` relay from `AppleWatchManager` into the watch filter contract. Re-ranked the active plausible-cause list to reflect that two successful reference paths (DiaBLE Watch and Trio Phone) share early, restore-backed manager lifecycle while Trio Watch still allocates lazily. Added a current-state **Focused Conclusions** subsection and an active-layer note so the preserved historical report and the active addendum no longer read out of order. |
| v1.5 | 2026-04-15 17:40 CET | **Comparison matrix row 1:** Corrected Trio `retrieveConnectedPeripherals` to use **`G7BLEUUID.dataService` (F808…)** rather than **FEBC**; clarified that **FEBC** is for scan/advertisement and data service is for retrieval. **Discrepancy / ranked list:** Clarified Trio **trim-only** `normalizedPeripheralName` vs DiaBLE-style Dexcom name normalization. Reason: align the live matrix and asymmetry notes with current `G7DirectBLEManager` / `WatchState` behavior. |
| v1.4 | 2026-04-15 16:16 BST | Refreshed the active addendum against implementation plan **v1.42**. Tightened status labels so code-level parity closure is distinguished from runtime proof, incorporated the negative build 164 watch-only review (`queue: nil` did not materially change the callback-free pre-connect stall), and advanced the recommendation sequence so the immediate next gate is the build 164 PacketLogger / raw-capture re-check before F3. |
| v1.3 | 2026-04-15 15:56 BST | Appended a new **Updated Comparison Report** addendum that re-evaluates the DiaBLE vs Trio watch comparison against current Trio code and current Phase E / F evidence, while preserving the historical v1.2 report exactly as written. Reclassified prior discrepancies into corrected / partially corrected / retired / superseded / still active, added a current-state ranked discrepancy list, and replaced the old active suspect set with evidence-backed next investigations and explicit evidence-hygiene rules. |
| v1.2 | 2026-04-14 16:00 CEST | **Connect-context framing:** Reframed Phase E as a **connect-context parity** investigation, not primarily a restore-key experiment. Added "What Phase E is really about" section explaining that the core question is Trio's runtime context at `connect()` time. Softened `CBCentralManagerOptionRestoreIdentifierKey` from "highest-priority parity gap" to "selected first experiment" alongside the instrumentation. Elevated unknown runtime state (Task E1) to a top-level cause in the ranked table. Added Category column to ranked causes. Updated conclusions and hardware questions to lead with runtime-context diagnostics. |
| v1.1 | 2026-04-14 15:42 CEST | Added **Focused Pre-connect Path Comparison** section with detailed `CBCentralManager` creation, `.poweredOn` handling, and `didDiscover` → `connect()` path comparison tables. Added **Ranked plausible causes** table mapping each cause to Phase E tasks. Updated conclusions and hardware questions to align with build 162 plan. |
| v1.0 | 2026-04-14 00:38 CEST | Initial DiaBLE vs Trio watch BLE comparison report covering discovery, connect, GATT, auth, reconnect, and current `didConnect` stall suspects. |
