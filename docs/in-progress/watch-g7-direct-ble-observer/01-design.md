# Trio Watch — Dexcom G7 Direct BLE Observer (Design)

Version 1.0 — clean-room design written on `feature/watch-g7-direct-ble-observer-1c81` branched from `baseline-dev-patches-01-10`.

---

## 1. Mission restated

The Trio Watch App Extension eavesdrops on the BLE session already held by the
official **Dexcom G7 watch app** on the same watchOS device, using same-device
CoreBluetooth peripheral sharing. Trio's own `CBCentralManager` gets its own
GATT view of the already-connected G7 peripheral, its own CCCD subscriptions,
and its own write channel on the control characteristic. Trio never initiates
or owns G7 authentication.

The goal is **sustained delivery of multiple EGV readings over time**, not a
one-shot attach. Every decision in this design is weighed against "does this
make sustained eavesdropping more reliable?"

This path is additive. It does not replace HealthKit or the existing
WatchConnectivity phone-relay path; it flows into the same
`TrioComplicationDataStore` alongside them and is tagged as a distinct source.

Foundational assumption: the Dexcom G7 watch app is installed on the same
watch and currently in direct-to-watch mode. If that is not true, the observer
cannot function; we do not try to detect or diagnose that state in this POC.

---

## 2. Architectural premise: same-device CoreBluetooth sharing

Because Trio runs on the same watch as the Dexcom G7 watch app, the BLE link
to the sensor is already owned at the OS level. Trio is not competing for a
connection slot — it attaches to the peripheral that the system already
considers connected. This is why `retrieveConnectedPeripherals(withServices:)`
is typically sufficient on watchOS, and it's the premise that lets DiaBLE's
observer approach work.

Trio's `CBCentralManager` receives its own view of the peripheral with its
own GATT state (characteristic subscriptions, pending writes, notify enables).
Writes Trio makes to the control characteristic are multiplexed with the
Dexcom app's writes; subscribe-notifications Trio enables are independent of
any CCCD enable the Dexcom app did. The GATT server on the sensor sees two
"clients" on the same link.

---

## 3. Protocol observer sequence

Validated against references:

- UUIDs and opcodes: `G7SensorKit/BluetoothServices.swift`,
  `G7SensorKit/Messages/G7Opcode.swift`.
- EGV parsing, activation math, trend mapping:
  `G7SensorKit/Messages/G7GlucoseMessage.swift`.
- Observer lifecycle: `G7SensorKit/G7CGMManager/G7BluetoothManager.swift`,
  `G7SensorKit/G7CGMManager/G7Sensor.swift`.
- WatchOS-specific validation: `DiaBLE/BluetoothDelegate.swift`,
  `DiaBLE Watch/MainDelegate.swift`.

Sequence:

1. `CBCentralManager` powered on with restoration identifier
   `trio.g7.observer.v1`.
2. Discover peripheral (see §5).
3. `connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])`.
4. `didConnect` → `peripheral.discoverServices(nil)` (broad; see §7).
5. On the G7 CGM service, `discoverCharacteristics(nil, for: service)`.
6. Enable notify on authentication characteristic (`F8083535-…`). Record but
   **do not** subscribe to J-PAKE characteristic (`F8084533-…`) — discover
   only, skip explicitly.
7. Observe auth handshake traffic. On each notification byte pattern matching
   `AuthChallengeRxMessage` (prefix `0x05`, 3+ bytes), read the authenticated
   and bonded flags. See §8 for the advance condition.
8. On advance condition satisfied: enable notify on control characteristic
   (`F8083534-…`), then enable notify on backfill (`F8083536-…`).
9. Write `[0x4e]` (G7Opcode `.glucoseTx` / DiaBLE `.egv`) to control with
   `.withResponse`. This is the EGV request. See §9 for cadence.
10. On control notify with prefix `0x4e` and 19+ bytes, parse
    `G7GlucoseMessage`. Compute `readingDate = now - (messageTimestamp -
    age)` **relative to the activation date** that is derived from the message
    itself:
    `activationDate = Date() - TimeInterval(message.messageTimestamp)`,
    `readingDate = activationDate + TimeInterval(message.glucoseTimestamp)`.
11. Build a `TrioComplicationSnapshot` with `source = .g7DirectBLE`, trend
    mapped to the Nightscout-style arrow string the rest of the watch
    pipeline uses. Persist via
    `TrioComplicationDataStore.shared.save(snapshot, triggerReload: true,
    minInterval: 5)`.
12. Backfill: observed only (option b). We discover and subscribe (G7SensorKit
    does subscribe post-auth), but for this POC we log packets and do not
    forward them into the data store. See §11.

Explicitly prohibited in code: any write to the authentication characteristic,
any J-PAKE packet, any `exchangePakePayload` or `appKeyChallenge` opcode.
A static assert / structured log makes this observable.

---

## 4. Peripheral filtering approach

**Choice:** DiaBLE-style standalone tolerant matching. No iPhone-bridged
active-name filter in this POC.

**Rationale:**

- DiaBLE already proves this works on watchOS. `retrieveConnectedPeripherals`
  with the G7 service UUIDs typically returns the active peripheral directly,
  and any scan fallback can match advertised names with the `DXCM` / `DX02`
  prefix.
- Avoiding the iPhone bridge shrinks the end-to-end surface area for this
  first attempt. If matching accuracy proves insufficient, adding the iPhone
  bridge is a small additive WatchConnectivity change in a follow-up.
- Multi-peripheral disambiguation (§DQ13) prefers the most-recently-seen
  candidate; if ambiguity persists we revisit with the iPhone bridge.

Name-prefix accept list:

- `DXCM` (G7).
- `DX02` (Dexcom ONE+; uses the same protocol). Included because both
  references accept it; rejecting it would complicate future reuse.

Peripherals that fail the name-prefix test are logged as
`g7_ble_peripheral_skipped` with `reason=name_mismatch`.

---

## 5. Discovery / attach strategy

**High-fidelity area.** Both references use the same rough structure; we
match it. Sequence, on `centralManagerDidUpdateState(.poweredOn)` and on
every foreground-active re-entry while unconnected:

1. `retrievePeripherals(withIdentifiers:)` if we have a persisted identifier
   from a prior successful attach (watch-local `UserDefaults`). Attribution
   tag: `retrieved_identifier`.
2. `retrieveConnectedPeripherals(withServices:)` for:
   - `SensorServiceUUID.cgmService` (`F8083532-…`). Tag: `retrieved_data_service`.
   - `SensorServiceUUID.advertisement` (`FEBC`). Tag: `retrieved_febc`.
   Each peripheral returned is passed through the name filter; the first
   accepted candidate becomes the active target.
3. If none of the above produced a peripheral, `scanForPeripherals(withServices:
   [SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID])`.
   Tag: `scan`.

On successful `didConnect`, scanning is stopped (§DQ12).

The whole attach ladder runs as one sweep; if step 1 or 2 finds and connects
to a candidate, steps below are skipped. Between sweeps, we use the reconnect
policy (§12).

**Why this sequence:**

- `retrievePeripherals` is cheapest and most specific.
- `retrieveConnectedPeripherals` on the data service is the canonical
  same-device hook; it returns the peripheral that the Dexcom G7 watch app is
  already talking to.
- `FEBC` (advertisement service UUID) is included as a belt-and-suspenders
  fallback because G7SensorKit registers for connection events on both
  `FEBC` and the data service UUID.
- Scan is the last resort and only useful if `retrieveConnectedPeripherals`
  misses — which shouldn't happen on a healthy same-device setup.

Every `connect(...)` call emits `g7_ble_connect_attempt source=<tag>`.

---

## 6. Central-queue choice, restoration, connect options

- **Central queue:** dedicated serial `DispatchQueue(label:
  "com.trio.watch.g7.ble", qos: .userInitiated)`.
  Matches G7SensorKit; keeps delegate callbacks off main so they don't
  contend with the watch app's SwiftUI updates. All `WatchState` /
  `TrioComplicationDataStore` writes hop to main via `Task { @MainActor in
  ... }` or `DispatchQueue.main.async`.
- **Restoration:** eager, with restoration identifier
  `trio.g7.observer.v1`. `willRestoreState` handler logs the restored
  peripherals and dispatches each through the same discovery path the live
  retrieval uses.
- **Connect options:** `[CBConnectPeripheralOptionNotifyOnDisconnectionKey:
  true]`. Both references use or permit this; it improves reconnect
  responsiveness on watchOS.

---

## 7. Discovery breadth

`discoverServices(nil)` and `discoverCharacteristics(nil, for: service)`.

DiaBLE uses this breadth. G7SensorKit uses a configured map
(`[cgmService: [authentication, control, backfill]]`). Prior Trio
implementations used targeted UUIDs and failed. Both-reference-agreement is
not a tie: the broader sweep is strictly a superset and costs only a small
amount of BLE airtime that's a one-shot per connect cycle. We take the
broader option because it mirrors the working watchOS reference exactly and
because targeted discovery has already been observed to fail in this codebase.

---

## 8. Auth advance condition

**Choice:** permissive, with a fallback timer.

Specifically:

- If Trio observes an `AuthChallengeRxMessage` on the authentication
  characteristic with `isAuthenticated == true && isBonded == true`
  (G7SensorKit's gate), advance immediately. Emit
  `g7_ble_auth_payload_received authenticated=true bonded=true`.
- Otherwise, start a 6-second fallback timer after auth notify enable. When
  the timer fires, if `didConnect` has happened, control notify has been
  discovered, and the peripheral is still connected, advance anyway and
  write the EGV request. Log `g7_ble_advance_on_timer` with reason.

**Rationale:** the Dexcom G7 app has already authenticated this session
before Trio attaches. The auth-challenge packet is informational from
Trio's view; the fact that the sensor is currently streaming data to the
Dexcom app proves the session is already authenticated. A strict
`authenticated && bonded` gate is correct when the auth challenge arrives
for us, but if the G7 app paired earlier and the sensor doesn't re-emit an
auth challenge for our observer, we would deadlock waiting forever. The
fallback timer protects against that.

Worst case: we write `[0x4e]` on an unauthenticated connection. The sensor
rejects the write, we log the error, we retry after the control-write
failure path (§10). No safety impact — we never sent any auth bytes.

---

## 9. EGV-request cadence

**Choice:** once-per-connect + on each observed auth transition + 5-minute
fallback timer while connected.

- **Once-per-connect:** write `[0x4e]` as soon as the advance condition is
  satisfied.
- **On each observed auth-challenge notification** (G7 re-authentication
  every ~5 min): if the payload indicates authenticated+bonded, write
  `[0x4e]` again. This mirrors the sensor's natural session cadence and
  produces one EGV per re-auth cycle, matching the 5-minute G7 output
  cadence.
- **5-minute fallback timer:** if no EGV has been delivered in the last 5
  min 30 s and the peripheral is still connected, write `[0x4e]`. This
  covers the case where the re-auth notification is missed (e.g., the Dexcom
  app acks before we get a chance to observe the packet).

**Rationale:** the prior Trio attempt used rigid "once per connect/auth
cycle" and apparently hit states where no EGV arrived despite a healthy
connection. G7SensorKit's implementation is de-facto "every time we see an
authenticated auth challenge"; DiaBLE writes opcodes from the service-
discovery path. Combining both with a fallback timer makes the request
signal resilient to a single missed packet.

Dedup on the receive side (snapshot `readingDate` comparison, see §11)
ensures that duplicate EGV deliveries collapse to a single store write.

---

## 10. Control-write failure handling

- On `didWriteValueFor(control)` with a non-nil error:
  log `g7_ble_egv_request_write_failed error_domain=… error_code=… error_desc=…`.
- If the error is `CBATTError.insufficientAuthentication` (8) or
  `CBATTError.insufficientEncryption` (15) or the NSError indicates a
  pairing/encryption issue, wait until the next observed auth challenge or
  until the 5-minute fallback timer, then retry.
- If the error indicates disconnection, rely on the disconnect delegate
  path to reconnect.
- On any other error, schedule a retry after a 10-second backoff, capped at
  3 attempts per connect cycle. Each retry increments a session-scoped
  counter recorded in the teardown `g7_ble_session_outcome` log.

---

## 11. Backfill

**Choice:** (b) discover and log, do **not** gate on backfill and do not
push backfill payloads into the data store.

Backfill would improve reading density during brief disconnects, but this
POC's success criterion is "multiple EGVs over time from direct BLE." The
primary reading stream is the `0x4e` response on control. Backfill is
logged (`g7_ble_backfill_packet_received length=… hex_prefix=…`) and
discovered so we subscribe (mirrors G7SensorKit to avoid changing the GATT
shape the sensor sees from Trio), but the parsed payloads are dropped.

This is an intentional deviation from G7SensorKit's full behavior. Rationale:
backfill payloads on G7 require accurate activation-time tracking and would
introduce dedup complexity (control-delivered EGV vs backfill-delivered
EGV for the same sensor minute). Adding that in a follow-up is simpler than
testing it as part of the initial attach-reliability work.

---

## 12. Reconnect policy

Simple, principled, always-on while the app is foreground-active.

- **Baseline:** `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true`.
- **On `didDisconnectPeripheral`** (normal or error): immediately call
  `central.connect(peripheral, options: …)` again. Reset backoff on
  `didConnect`.
- **On `didFailToConnect`:** backoff then retry.
  Backoff schedule: `2s, 5s, 10s, 20s, 30s, …` capped at 30 s.
- **On scene transition to `.active`:** reset backoff, immediately re-run
  the full attach ladder (§5) if not connected.
- **On scene transition to `.inactive` or `.background`:** do **not** tear
  down. Let CoreBluetooth / watchOS decide. The observed anti-pattern of
  scene-gating the reconnect path from prior Trio attempts is explicitly
  avoided — see `G7DirectBLEObserver.scenePhaseChanged` in source.
- **Scan timeout:** we do not use one. The anti-pattern of "timer fires 12s
  after a successful connect and tears down a healthy session" is
  eliminated by not creating that timer at all. If a scan fails to produce
  a candidate, the reconnect backoff simply keeps retrying the full attach
  ladder.

The observer never permanently gives up while foreground-active. `stop()` is
retained only for explicit tests / product off-switch.

---

## 13. Scene-phase / lifecycle model

- `CBCentralManager` is allocated eagerly at first access of
  `G7DirectBLEObserver.shared` (lazy singleton). Initialized from
  `ExtensionDelegate.applicationDidFinishLaunching` via
  `G7DirectBLEObserver.shared.primeCentral()` so watchOS has the object
  alive before the first `.active` entry.
- On `.active`: `observer.start()` — attach ladder if not yet connected;
  no-op if healthy.
- On `.inactive` / `.background`: no-op. No teardown, no `stop()`.
- `WKExtendedRuntimeSession`: **not included in this POC.** The mission is
  foreground-active sustained delivery; extended runtime adds lifecycle
  complexity (expiration, renewal, invalidations) that the references
  handle differently (DiaBLE uses it scheduled around reading cadence;
  G7SensorKit does not use it at all since it runs on iOS). For POC
  stability, we keep the observer scoped to what the foreground-active
  SwiftUI scene affords.

---

## 14. UI indicator

Starting-point proposal (§6 request) is adopted largely as-is, with one
simplification — merged to a 5-state palette:

- `off` — observer not started (scene inactive for extended time, or user
  toggled stop).
- `searching` — central powered on, attach ladder running, no peripheral
  yet.
- `connecting` — peripheral connected at CB level, not yet receiving EGVs.
  Collapses "connecting" and "authenticating/discovery" — the user-visible
  difference is negligible at a glance.
- `active` — peripheral connected AND at least one EGV received since
  `start()`.
- `stalled` — peripheral connected but no EGV received in the last 6 min.
- `unavailable` — Bluetooth off / unauthorized / unsupported. Surfaces the
  OS constraint that observer cannot function.

The separate `unavailable` state matters because the user action (enable
Bluetooth / grant permission) is different from "wait for reconnect."

**Integration with the existing recency indicator** (`lastLoopTime`
"1 min" shown in `GlucoseTrendView`): that text is untouched. We add a
**separate compact status row** above the treatment toolbar on the main
glucose page (page 0 / `GlucoseTrendView`). The row renders:

```
[•] BLE:<state>  src:<source>  <last-egv age>
```

Where:

- `[•]` is a small circle colored by state (`active`=green,
  `connecting`/`searching`=yellow, `stalled`=orange, `off`/`unavailable`=
  gray).
- `BLE:<state>` is the lowercase state word above.
- `src:<source>` indicates which source served the currently-displayed
  glucose reading: `ble`, `wc` (WatchConnectivity phone relay), `hk`
  (HealthKit), or `—` (unknown / not yet set).
- `<last-egv age>` is "—", or "12s", or "3m" — the time since the last
  direct-BLE EGV was received. Distinct from the reading-recency shown
  below in `GlucoseTrendView` (which reflects the currently-displayed
  reading regardless of source).

Font sizes and spacing are sized to the existing `minutesAgoFontSize` so
the row looks native on every supported watch size.

The row is only rendered when any of the three signals has non-default
content — i.e., once the observer has had a chance to emit anything, or
once a source attribution exists on the latest snapshot. On a completely
cold watch, the row is hidden and the UI looks identical to the baseline.

---

## 15. Source attribution model through the pipeline

`TrioComplicationSnapshot` gains one optional field: `source:
TrioComplicationDataSource?`. `TrioComplicationDataSource` is a new public
enum in `Trio Watch Shared/TrioComplicationDataSource.swift`:

```swift
enum TrioComplicationDataSource: String, Codable, Equatable {
    case watchConnectivity = "wc"
    case healthKit = "hk"
    case g7DirectBLE = "ble"
}
```

Writers at each call site pass `source:`:

- `WatchState.saveComplicationSnapshot(from:)` → `.watchConnectivity`.
- `WatchState.finishHKGlucoseObserverFetch(...)` → `.healthKit`.
- `G7DirectBLEObserver.saveSnapshot(from:)` → `.g7DirectBLE`.

`WatchState` exposes:

- `@Observable` `latestReadingSource: TrioComplicationDataSource?` — set
  whenever a snapshot is applied to visible fields. Drives the UI row
  `src:` label.
- `@Observable` `g7ObserverStatus: G7DirectBLEObserverStatus` (mirrored
  from observer) and `lastG7BLEReadingAt: Date?`.

Dedup: the existing `shouldUpdate` comparator ignores `source`. This is
deliberate — two paths can race for the same reading, and the behavior the
store should exhibit is "accept the first, skip the second," not "write
both." The `source` field therefore records **which path won**, not "which
paths contributed." If a later path delivers a newer reading (>1s
difference), it overwrites both value and source.

For §6's "which path served the currently-displayed reading" requirement,
`WatchState.latestReadingSource` is the authoritative answer.

---

## 16. Observability plan

All logs through `WatchLogger.shared.log`. Helper `G7BLELog.log(_:)`
forwards `#fileID/#line/#function` so attribution stays at the call site.

**Lifecycle:**
`g7_ble_lifecycle phase=<start|stop|prime|scene_active|scene_inactive>`.

**Central state:**
`g7_ble_central_state state=<poweredOn|poweredOff|unauthorized|unsupported|resetting|unknown>`.

**Discovery / attach:**
- `g7_ble_scan_start` / `g7_ble_scan_stopped reason=…`.
- `g7_ble_peripheral_discovered identifier=… name=… rssi=… advert_keys=…`.
- `g7_ble_peripheral_skipped identifier=… reason=<name_mismatch|not_connectable>`.
- `g7_ble_connect_attempt identifier=… source=<retrieved_identifier|retrieved_data_service|retrieved_febc|scan|restored>`.
- `g7_ble_did_connect identifier=… name=…`.
- `g7_ble_connect_failed identifier=… error_domain=… error_code=… error_desc=…`.
- `g7_ble_did_disconnect identifier=… is_reconnecting=… error_domain=… error_code=…`.

**GATT:**
- `g7_ble_services_discovered count=… uuids=…`.
- `g7_ble_characteristics_discovered service=… uuids=…`.
- `g7_ble_auth_notify_enabled`.
- `g7_ble_jpake_skipped` (on every discovery).
- `g7_ble_control_notify_enabled` / `g7_ble_backfill_notify_enabled`.

**Observer protocol:**
- `g7_ble_auth_payload_received hex_prefix=… authenticated=… bonded=…`.
- `g7_ble_advance_ready reason=<auth_gate|timer_fallback>`.
- `g7_ble_egv_request_sent cadence=<first_connect|auth_transition|fallback_timer> attempt=…`.
- `g7_ble_egv_request_write_failed attempt=… error_domain=…`.
- `g7_ble_egv_received glucose=… trend_rate=… algorithm_state=… message_timestamp=… age=… reading_date=…`.
- `g7_ble_backfill_packet_received length=… hex_prefix=…`.
- `g7_ble_snapshot_saved glucose=… reading_date_epoch=… source=ble`.

**Blocked / diagnostic:**
- `g7_ble_blocked_no_peripheral` (attach ladder produced zero candidates).
- `g7_ble_blocked_auth_incomplete elapsed_ms=…` (auth timer not yet fired).
- `g7_ble_blocked_control_not_ready`.

**Teardown:**
- `g7_ble_session_outcome outcome=<success|failure|incomplete|cancelled|timeout> final_stage=… duration_ms=… g7_session=… egv_count=…`.

**Negative proofs** (must never appear):
- `g7_ble_auth_request_sent`, any J-PAKE or auth-init opcode log.
  A compile-time check lives as a comment in the source; additionally, a
  precondition in the write helper rejects any opcode the observer isn't
  allowed to send.

**Verbosity:** pre-`didConnect` and pre-`egv_received` events are logged at
full verbosity. Post-`egv_received`, the EGV parse log is rate-limited to
one per unique `message_timestamp` per session to keep steady-state log
volume bounded.

---

## 17. Deviations from DiaBLE / G7SensorKit

- **Restoration identifier:** Trio-specific ID so it doesn't collide with
  DiaBLE's.
- **Auth condition:** we add a fallback timer that G7SensorKit does not
  use. Rationale in §8 — Trio is attaching to an already-authenticated
  session, and a strict gate can deadlock.
- **EGV request cadence:** we add a fallback 5-minute timer that G7SensorKit
  does not have. Rationale in §9 — prior Trio implementations stalled on
  "once per auth cycle."
- **Backfill disposition:** we discover and log, but drop payloads. Both
  references forward backfill; we defer integration.
- **Target app integration:** we write snapshots into
  `TrioComplicationDataStore`, not LoopKit or DiaBLE internal state. Out
  of scope for reference comparison.
- **No `WKExtendedRuntimeSession`** (DiaBLE uses one). Rationale in §13.
- **No iPhone-bridged filter** (optional per spec). Rationale in §4.

All deviations are mission-driven: reliability + sustained delivery first.

---

## 18. Open design questions — answers

1. **Peripheral filtering approach** → DiaBLE-style standalone (§4). No
   phone bridge.
2. **Attach strategy specifics** → `retrievePeripherals(withIdentifiers:)`,
   `retrieveConnectedPeripherals(withServices:)` on cgmService and FEBC,
   then `scanForPeripherals(withServices: [FEBC, cgmService])` (§5).
3. **Discovery breadth** → `discoverServices(nil)` + `discoverCharacteristics(nil,
   for:)` (§7). Broader is safer.
4. **Scan timeout / backoff / connect-attempt timeout** → no scan
   timeout (§12). Reconnect backoff 2/5/10/20/30 s capped at 30 s.
5. **Central-queue choice** → dedicated serial queue (§6); main hops for
   `WatchState` / store writes.
6. **Restoration handling** → yes, identifier `trio.g7.observer.v1` (§6).
   Restored peripherals dispatch through the same discovery path.
7. **`connect()` options** → `NotifyOnDisconnectionKey: true` (§6).
8. **Auth advance condition** → `authenticated && bonded` preferred; 6-second
   fallback timer (§8).
9. **EGV-request cadence** → once per connect + on auth transition + 5-min
   fallback (§9).
10. **Control-write failure handling** → 10 s / 3 attempts per connect cycle,
    auth errors deferred to next auth transition (§10).
11. **Backfill handling** → (b) discover and log; drop payloads (§11).
12. **Stop scanning after connect** → yes (§5).
13. **Multi-peripheral disambiguation** → prefer the most-recently-
    discovered candidate; if still ambiguous, first one through the name
    filter wins and the others are logged with
    `reason=ambiguous_skipped`. Revisit with iPhone bridge if empirical
    data shows stable ambiguity.
14. **Peripheral identifier persistence** → watch-local `UserDefaults`
    (App Group not required since this identifier is process-local to the
    watch). Key: `trio.g7.observer.preferredPeripheralUUID`. Cleared on
    explicit `forget()` and on 5 consecutive connect failures for the same
    identifier.
15. **Delta computation** → local, from the previously delivered
    `G7DirectBLEObserver` reading only. Delta is mg/dL rounded to integer,
    signed. If no prior BLE reading exists this session, delta is `"--"`.
    This deliberately ignores HK/WC deltas to keep the BLE snapshot
    self-consistent.
16. **Dedup / winner policy** → existing 1-s `shouldUpdate` window
    (`minInterval: 5` on save) + source recorded as "winner" (§15).
17. **UI status palette** → 5-state (§14).
18. **Active-name filter change** — N/A (no bridged filter).
19. **Attach-ladder cadence** → single sweep on each attempt; no serialized
    delays between steps (§5). Between sweeps, the reconnect backoff
    gates pacing.

---

## 19. Known risks / open questions for device test

- **Auth-challenge never observed.** If the Dexcom G7 app paired long ago
  and the sensor doesn't re-emit an auth packet for a new GATT client,
  we rely entirely on the 6-second fallback timer. On-device verification
  should measure how often the timer fallback triggers vs a real
  auth-gated advance.
- **Control-write rejection.** If the sensor rejects Trio's `0x4e` write
  because of "insufficient encryption" without providing a recoverable
  error, we log and retry, but the session could be stuck in
  `connecting`. Needs real-world validation.
- **Scan-result pollution.** If multiple G7-family devices are in range,
  the disambiguation policy may pick the wrong one. Only relevant for
  users with multiple G7s or living near a neighbor on Dexcom.
- **Link sharing with the Dexcom app.** Untested assumption: CCCD
  enables for Trio's GATT view do not disturb the Dexcom app's view.
  Worst case the Dexcom app loses notifications on the control
  characteristic — which should quickly trigger a reconnect on its
  side, but could cause user-visible Dexcom app glitches. Needs
  device testing.
- **Extended-runtime omission.** Deliberately scoped out, but if the
  watch app backgrounds while the user is actively watching for BG,
  BLE delivery will stop. Follow-up iteration.
- **Identifier persistence churn.** If the G7 sensor is replaced, the
  persisted identifier becomes stale and the first sweep will waste a
  retrieval round-trip. Acceptable overhead (10s of ms).
