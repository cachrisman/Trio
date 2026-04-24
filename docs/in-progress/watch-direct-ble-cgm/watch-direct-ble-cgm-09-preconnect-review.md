# Watch Direct BLE — Pre-Connect Review (Build 180 / Build 181 Plan)

**File under review:** `Trio Watch App Extension/G7DirectBLEManager.swift`  
**Branch:** `feature/watch-direct-ble-cgm`  
**Review date:** 2026-04-22  
**Reviewer scope:** static analysis only — no runtime evidence from build 180

---

## Part 1 — Validate build 180 `willRestoreState` implementation

**Code under review (lines 2282–2303):**

```2282:2303:Trio Watch App Extension/G7DirectBLEManager.swift
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let keys = dict.keys.sorted().joined(separator: ",")

        // Cancel any peripherals CB restored from the prior session.
        // Without this, a subsequent connect() call is treated as a duplicate
        // by CB and delivers no didConnect / didFailToConnect / didDisconnect.
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restored {
                central.cancelPeripheralConnection(peripheral)
            }
        }

        // Stop any scan CB restored — the Phase G scheduler owns scan start/stop.
        central.stopScan()

        Task {
            let restoredCount = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.count ?? 0
            await logG7Ble(
                "event=g7_ble_will_restore_state keys=\(keys) restored_peripheral_count=\(restoredCount)"
            )
        }
    }
```

### Findings

1. **`central.stopScan()` is called — CONFIRMED.** Line 2295, after the cancel loop, before returning. Severity: N/A (correct).

2. **`cancelPeripheralConnection` for each restored peripheral — CONFIRMED.** Lines 2288–2292. The `for peripheral in restored` loop covers every entry in `CBCentralManagerRestoredStatePeripheralsKey`. Severity: N/A (correct).

3. **`restored_peripheral_count=N` field is present — CONFIRMED.** Line 2300. Note this re-reads the key (second cast) instead of reusing the `restored` local. Cosmetic only — if the cast succeeds in the first block it will succeed here too. Severity: low. Recommended action: optionally hoist `restoredCount` above the cancel loop for readability; not required.

4. **Ordering (`stopScan` vs `cancelPeripheralConnection`).** Order does not matter for correctness. `CBCentralManager.stopScan()` and `cancelPeripheralConnection(_:)` target different internal state machines inside CB. Both are sync dispatch calls onto CB's internal queue; neither blocks, both queue their effects asynchronously. The current order (cancel first, then stopScan) matches the comment intent ("flush restored connections before flushing restored scan"). **Severity: N/A (correct).**

5. **Risk: phantom `didDisconnectPeripheral` callbacks during the first moments after launch. SEVERITY: HIGH.**

   `cancelPeripheralConnection(peripheral)` on a restored peripheral that CB has internally parked as `.connected` or `.connecting` **will** cause CB to dispatch `centralManager(_:didDisconnectPeripheral:error:)` on the delegate queue shortly after `willRestoreState` returns. At that moment:
   - `self.peripheral` is `nil` (we never assigned a reference to the restored peripheral).
   - `pendingDisconnectReason` is `nil` (build 180 does not set it before the restore cancel).
   - `scanningStarted` is `false` (we haven't started a cycle yet).

   `didDisconnectPeripheral` (lines 2427–2472) does **not** guard that the callback's `peripheral` matches `self.peripheral`. It falls through to `teardownSession(reason: "disconnected", isFailure: false)` (lines 2443/2471), which:
   - Cancels cycle timers (`cycleRetryWorkItem`, via `teardownSession` preamble lines 1195–1201).
   - Calls `resetSessionState()` — OK (already reset).
   - Sets `scanningStarted = false` (already false).
   - Emits `g7_ble_session_outcome outcome=incomplete final_stage=none duration_ms=0 g7_session=none` (line 1250).
   - Falls into `scheduleNextCycleAfterMiss(reason: "disconnected", category: "timing")` (line 1275, because `isFailure=false` and `shouldAttemptSameCycleRetry=true`).

   Net effect at launch: a spurious `g7_ble_session_outcome` + a spurious cycle miss are scheduled **before the real cycle scheduler has even run**. This is observable and may mask the real first-cycle anchor (`scheduleNextCycleAfterMiss` calls `refreshCadenceScheduler(trigger: "cycle_miss_disconnected", forceReschedule: true)`).

   **Recommended action (pre-183):** in `willRestoreState`, set `pendingDisconnectReason = "will_restore_flush"` before the cancel loop, and add a guard in `didDisconnectPeripheral` that short-circuits (log + return) when `peripheral !== self.peripheral` OR when `pendingDisconnectReason == "will_restore_flush"`. Either is a sufficient, cheap fix.

6. **Risk: phantom `didConnect` callback for restored-but-not-yet-cancelled peripheral. SEVERITY: MEDIUM.**

   Between `willRestoreState` returning and CB processing the cancel, CB could (in theory) deliver `didConnect` first for a peripheral that was in `.connecting` at the time of restore. `centralManager(_:didConnect:)` (line 2361) does not guard peripheral identity either, and it eagerly:
   - Calls `persistPeripheralIdentifier(peripheral.identifier, …)` — writes a potentially-wrong identifier into the app group (if restored peripheral isn't the active G7).
   - Calls `peripheral.discoverServices(…)` — on a peripheral we never set as `self.peripheral`.

   In practice this race is narrow because our `cancel` is queued ahead of any pending connect delivery, but it is not airtight. **Recommended action:** add `guard peripheral === self.peripheral else { return }` in `didConnect`, `didFailToConnect`, and `didDisconnectPeripheral`. This is cheap defense-in-depth and makes the restore-flush provably safe.

### Part 1 summary

Build 180's `willRestoreState` correctly implements "flush CB's restored state so a subsequent `connect()` is not swallowed as a duplicate". It closes the bug-1 hypothesis as described. The remaining risks are **collateral damage from the flush itself** (phantom disconnect → spurious miss log, and unguarded `didConnect`/`didDisconnect` paths). These should be addressed in build 181 or bundled into 184 (`willRestoreState` fast-path).

---

## Part 2 — Validate build 181 plan (`doesPeripheralMatchActiveFilter` + suffix)

**Current implementation (lines 1746–1749):**

```1746:1749:Trio Watch App Extension/G7DirectBLEManager.swift
    private func doesPeripheralMatchActiveFilter(_ peripheral: CBPeripheral) -> Bool {
        guard let active = activePeripheralName else { return false }
        return (peripheral.name ?? "unknown") == active
    }
```

### Findings

1. **Not every attach path goes through `doesPeripheralMatchActiveFilter`. SEVERITY: BLOCKER for build 181.**

   Call sites of `doesPeripheralMatchActiveFilter`:
   - Line 1759 — `selectIdentifierRetrievedPeripheralForAttach` (retrieved-identifier path).
   - Line 1771 — `selectConnectedRetrievedPeripheralForAttach` (retrieved-connected path).
   - Line 1834 — `logConnectedRetrievedPeripheralSkipsIfNeeded` (logging only).
   - Line 1871 — `beginRetrievedOrEventAttachIfEligible` (retrieved/connection-event attach).

   **But `centralManager(_:didDiscover:…)` does NOT go through this helper.** It uses a direct exact-string compare at line 2341:

   ```2337:2346:Trio Watch App Extension/G7DirectBLEManager.swift
        guard hasActivePeripheralNameFilter else {
            _ = emitAttachBlockedIfNeeded(source: "did_discover")
            return
        }
        if let active = activePeripheralName, name != active {
            Task {
                await logG7Ble("event=g7_ble_peripheral_skipped peripheral=\(name) reason=not_active_sensor")
            }
            return
        }
   ```

   **This is the scan path.** In the current build, advertisements arrive as `DXCMxx` and `activePeripheralName` is `DexcomXX` — the exact-match fails here and `didDiscover` returns before `beginConnectToG7Peripheral` is ever called. If build 181 fixes only `doesPeripheralMatchActiveFilter` and leaves line 2341 alone, **the scan path will still be blocked**.

   **Recommended action:** build 181 must either:
   - (a) replace the inline compare at lines 2341–2346 with a call to `doesPeripheralMatchActiveFilter(peripheral)`, **or**
   - (b) apply the suffix(2) rule identically inline.

   Without this, bug 2 is only half-fixed. Given that the OS caches `DexcomXX` after the first paired connection, the retrieved-identifier path may still unblock attach once the fix lands — but the scan path (cold boot, no cached identifier) stays dark. This is specifically relevant for **first-ever attach after the watch is reinstalled** or after `clearStoredPeripheralIdentifier()` runs.

2. **Proposed suffix(2) rule is correct for G7 / G7 ONE+ / Stelo. SEVERITY: N/A (correct).**

   Both reference implementations use `suffix(2)`:
   - G7SensorKit `G7Sensor.swift:250` — `name.suffix(2) == sensorName.suffix(2)` (comment at line 246 explicitly states: `"DXCMxx"` ↔ `"Dexcomxx"` — both end in the last two chars of the serial).
   - DiaBLE `BluetoothDelegate.swift:89–100` — all G7/ONE+/Stelo rename paths preserve `suffix(2)` as the stable identifier.

   The full 6-char Dexcom serial is of the form `<family-prefix><2-char-suffix>`. Only the 2-char suffix is present in both the advertised (`DXCMxx`) and post-cache (`Dexcomxx`) forms. `suffix(3)` would be incorrect because the "8" character in `DXCM08` is index 5 but in `Dexcom08` is index 7 — comparing `CM08` vs `com08` via `suffix(3)` → `M08` vs `m08` (case-mismatch and character-mismatch on G7). **`suffix(2)` is the only length that works across both name formats.**

3. **False-positive risk from suffix(2) collisions with other BLE devices in the environment. SEVERITY: LOW.**

   The scan is filtered by `withServices: [G7BLEUUID.advertisement]` (FEBC), which is the Dexcom-G7-only advertising UUID. Non-Dexcom devices cannot pass the scan filter regardless of name. The only collision surface is:
   - Another G7 sensor in range whose serial happens to end in the same 2 chars as the active one. Probability: 1/256 for a random pair of serials (hex pairs aren't uniform, but as an order of magnitude). Users with two active Dexcom G7s in pocket/purse range (e.g. a family member, a lab environment) could see a mismatch.
   - `retrieveConnectedPeripherals(withServices: [dataService, advertisement])` can return peripherals other watchOS apps (e.g. Dexcom's own app) have connected — these still have to be G7-family sensors because the service UUIDs gate the retrieval. Same 1/256 risk.

   **Recommended action:** accept the risk for build 181 (matches G7SensorKit precedent). Add a TODO / debug log that emits `peripheral_suffix_match=soft` vs `exact` so we can see in field logs whether we ever rely on the soft match when an exact match was available. Optionally, prefer an exact match over a suffix match in `selectIdentifierRetrievedPeripheralForAttach` / `selectConnectedRetrievedPeripheralForAttach` (pick the exact match first, fall back to suffix).

4. **Risk: suffix(2) fix accidentally triggering `active_name_changed` clear. SEVERITY: LOW — does not occur in current code paths.**

   `setActivePeripheralName` (line 2870) is called only from `applyForegroundActiveEntry` (line 405) and `updatePhoneActivePeripheralName` (line 414). Both receive the phone-supplied `activePeripheralName`, not the peripheral's BLE name. The peripheral's advertised/cached name (`DXCMxx` / `DexcomXX`) **is never assigned to `activePeripheralName`**. Therefore the suffix(2) fix does not introduce a loop where a peripheral-name flip would feed back into `setActivePeripheralName` and trigger `clearPersistedPeripheralIdentifier(reason: "active_name_changed")`.

   The only remaining way this could regress: if the phone ever sends `DXCMxx` on some cycles and `DexcomXX` on others (i.e. the phone-side active-sensor source is inconsistent). Out of scope of this file but worth auditing on the phone side (`WatchMessageKeys.swift` active-sensor payload).

### Part 2 summary

The proposed suffix(2) rule is correct and matches both G7SensorKit and DiaBLE precedent. **However, the fix as stated ("update `doesPeripheralMatchActiveFilter`") is insufficient** — `didDiscover` at line 2341 uses an inline exact-string compare that bypasses the helper. **Build 181 must update both the helper and the inline `didDiscover` guard**, otherwise the scan path remains blocked.

---

## Part 3 — Full pre-connect attach matrix

All code paths that reach `central?.connect(peripheral, options: nil)` (line 2248) pass through **`beginConnectToG7Peripheral`**. Here is the complete matrix:

### Path A: Scan / advertisement (`source="scan"`)

Trigger: `centralManager(_:didDiscover:…)` line 2328.

| Guard | Location | Effect today | After 180+181 |
|-------|----------|--------------|---------------|
| `guard scanningStarted` | L2334 | passes once scheduler runs `startScanning()` | unchanged |
| `guard hasActivePeripheralNameFilter` | L2337 | blocks until phone sends active sensor | unchanged (phone-supplied) |
| `name != active` exact compare | L2341 | **CURRENT BLOCKER**: `DXCMxx != DexcomXX` | **STILL BLOCKED** unless build 181 also updates this line |
| `attemptedConnectPeripheralIdentifiers.contains(…)` | L2183 | only blocks within one `g7_session` | unchanged |
| — | `connect()` L2248 | reached if all above pass | reached only if L2341 is updated |

### Path B: Retrieved-connected (`source="retrieved_connected"`)

Trigger: `attemptRetrievedAttachIfAvailable` → `selectConnectedRetrievedPeripheralForAttach` (L1771) → `beginRetrievedOrEventAttachIfEligible` (L1853).

Called from:
- `startScanning()` L494 — every cycle, before opening the FEBC scan.
- `centralManagerDidUpdateState` L2264 — after `poweredOn`.

| Guard | Location | Effect today | After 180+181 |
|-------|----------|--------------|---------------|
| `hasActivePeripheralNameFilter` | L1770, L1815 | gates attach | unchanged |
| `doesPeripheralMatchActiveFilter` | L1771 | **CURRENT BLOCKER**: exact compare | **UNBLOCKED** by suffix(2) |
| `scanningStarted` | L1858 | passes after `startScanning()` | unchanged |
| `expectedCycleGeneration == currentCycleGeneration` | L1859 | gates stale cycles | unchanged |
| `emitAttachBlockedIfNeeded(source:)` | L1867 | no-op when filter armed | unchanged |
| `doesPeripheralMatchActiveFilter` (second check) | L1871 | **same BLOCKER** | **UNBLOCKED** by suffix(2) |
| `attemptedConnectPeripheralIdentifiers.contains(…)` | L2183 | one-shot per attach cycle | unchanged |

### Path C: Retrieved-identifier (`source="retrieved_identifier"`)

Trigger: `attemptRetrievedAttachIfAvailable` → `selectIdentifierRetrievedPeripheralForAttach` (L1755) → `beginRetrievedOrEventAttachIfEligible` (L1853).

Same guards as Path B; same unblocking after 181.

Additional prerequisite: `loadPersistedPeripheralIdentifier()` must return non-nil. Persisted only by `persistPeripheralIdentifier(peripheral.identifier, reason: "connect_attempt" | "did_connect")` (L2249, L2362). On cold boot after reinstall, identifier is absent and Path C is unavailable until Path A or B succeeds once. **This makes the scan-path fix (Part 2 finding 1) critical for bootstrap.**

### Path D: Connection event (`source="connection_event"`)

Entire handler is commented out (L2305–2326). Re-enabling is build 182 (H1). Until then, this path is not live.

### Comparison to DiaBLE's attach path

DiaBLE (`BluetoothDelegate.swift`) attach path is structurally much simpler:
- No cycle scheduler / no Phase G gating.
- No `WKExtendedRuntimeSession` dependency for attach (only for the watch presentation).
- `willRestoreState` is a no-op log (L294–296).
- Name filtering happens **in the delegate** via peripheral-name normalization (`DXCMxx` → `DEXCOMG7xx` via `suffix(2)`).
- No `attemptedConnectPeripheralIdentifiers` dedup set.
- `scanForPeripherals(withServices: nil, options: …)` — nil services, accepting any advertisement (DiaBLE scans broadly then filters by name).

G7SensorKit's attach path (the iOS Trio precedent that works):
- Uses `suffix(2)` throughout (`G7Sensor.swift:250`).
- `willRestoreState` **re-attaches** restored peripherals via `handleDiscoveredPeripheral` rather than cancelling — this is exactly what build 184 proposes as a "fast-path".
- Uses `registerForConnectionEvents` **always** (L218 in `managerQueue_scanForPeripheral`).

### Structural differences that could still prevent `didConnect` after 180+181

1. **Cycle-generation gating (L1859) is Trio-specific.** If a cycle rolls over (new generation) between `retrieve` and `connect`, the retrieved-attach is suppressed as `stale_cycle_generation`. Acceptable but worth confirming via logs.
2. **`attemptedConnectPeripheralIdentifiers` (F5 dedup) is Trio-specific.** If the first connect attempt silently fails (no `didConnect` / `didFailToConnect` — the exact bug 180 symptom), a later re-sighting in the same `g7_session` is suppressed. After build 180, CB should fire `didFailToConnect` on timeout, which triggers `teardownSession` → new session. But within the connect-timeout window (30s or bounded by cycle hard-stop), re-sightings are lost. **Severity: medium; see Part 6 finding 5.**
3. **`beginConnectToG7Peripheral` sets `self.peripheral = peripheral` BEFORE `connect()` (L2195).** This is correct, but it means that if `connect()` is ever truly swallowed (post-180), subsequent `central.cancelPeripheralConnection(self.peripheral)` calls (e.g. in `startScanning_rescan` or `stop`) will correctly target that peripheral. Good.
4. **`peripheral.delegate = self` set before `connect()` (L2196).** Good — DiaBLE does the same.
5. **`discoverServices([G7BLEUUID.dataService])` at L2391** — specific UUID, not `nil`. DiaBLE uses `nil` (discover all). G7SensorKit's `G7PeripheralManager` uses a specific list. Specific is faster and matches G7SensorKit; no issue. **Severity: N/A.**
6. **`central.scanForPeripherals(withServices: [G7BLEUUID.advertisement], options: nil)`** — FEBC filter vs DiaBLE's `nil` services. OK, G7SensorKit uses the same FEBC filter. **Severity: N/A.**
7. **CBCentralManager is allocated with `queue: nil`** (L558) — main queue. DiaBLE does the same. G7SensorKit uses a private `managerQueue`. Trio's main-queue choice is intentional (delegate-queue parity with timers). Good.
8. **`resetSessionState()` at L490 is called INSIDE `startScanning()` BEFORE the retrieved-attach attempt at L494.** This clears `dataService`, chars, auth state. Fine because retrieved-attach re-enters `beginConnectToG7Peripheral` which sets `self.peripheral` and proceeds with fresh discovery.

### Part 3 summary

After 180+181 (with the scan-path inline compare also fixed), all three active paths (A, B, C) should be unblocked. The remaining structural differences vs DiaBLE are **design choices** (cycle gating, runtime session) rather than CB-layer bugs. The biggest residual risk is the F5 dedup set (`attemptedConnectPeripheralIdentifiers`) silently eating re-sightings within a session — only matters if 180 doesn't fully fix the silent-swallow, i.e. if there's a third bug we haven't found yet.

---

## Part 4 — Post-connect chain readiness

Assuming `didConnect` fires cleanly, trace:

### 4.1 Service / characteristic discovery

```2361:2392:Trio Watch App Extension/G7DirectBLEManager.swift
    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        persistPeripheralIdentifier(peripheral.identifier, reason: "did_connect")
        …
        peripheral.discoverServices([G7BLEUUID.dataService])
    }
```

- Discovers **only** `G7BLEUUID.dataService` (specific UUID). Matches G7SensorKit. DiaBLE uses `nil`; either is valid.
- `peripheral(_:didDiscoverServices:)` (L2478) then calls `discoverCharacteristics([communication, authentication, control, backfill, jPake], for: dataService)` (L2523). Explicit list — good.
- Incomplete-characteristics guard at L2585 requires both `authenticationCharacteristic` and `controlCharacteristic`. Matches observer-mode requirements.

**Finding 4.1: CORRECT.** The chain looks right; UUIDs match DiaBLE/G7SensorKit. **Severity: N/A.**

### 4.2 Auth observer path (no active pairing write)

```2618:2620:Trio Watch App Extension/G7DirectBLEManager.swift
        if let auth = authenticationCharacteristic {
            peripheral.setNotifyValue(true, for: auth)
        }
```

- Only enables notifications; **does not write `0x01 0x00`** or any active-pairing bytes. Observer-only. **Good.**
- `handleAuthenticationNotification` (L1982) parses:
  - `0x03` → `latestSessionSawAuthChallenge03 = true` (L1989), no reply sent.
  - `0x05` → parses `authenticated` (byte 1) and `bonded` (byte 2); sets `passiveObservationGateSatisfied = true` if authenticated; then triggers `setNotifyValue(true, for: control)` (L2032).
- Does not block on `bonded`; gate is `authenticated_only`. Matches observer intent.

**Finding 4.2: CORRECT.** Observer path is intact. **Severity: N/A.**

### 4.3 Control notify + 0x4E fallback

- Control notify is enabled reactively after `0x05 authenticated=true` (L2032) and in `armPassiveObservationIfReady` (L2084–).
- Fallback request: `triggerFallbackEgvRequestIfNeeded` (L2094) writes `Data([0x4E])` with `.withResponse`. Gate: `passiveObservationArmed && awaitingFirstEgv && controlNotificationsReady && !fallbackEgvRequestSent`. Scheduled by `schedulePassiveObservationFallback` at `currentCycleFallbackDate` (5s past expected reading, default 60s fallback).
- `didWriteValueFor` (L2745) logs success/error; nonfatal.

**Finding 4.3: CORRECT.** Fallback path is sane. **Severity: N/A.**

**Minor risk 4.3b:** `triggerFallbackEgvRequestIfNeeded` is `@MainActor`-annotated (L2093), and it's scheduled via `DispatchQueue.main.asyncAfter` inside a `DispatchWorkItem` that dispatches into `Task { @MainActor in … }` (L1453). Double hop — works but adds latency. **Severity: low.** Recommended: either drop the `Task` wrapper (the work item already runs on main) or drop the `@MainActor` annotation on the method. Cosmetic.

### 4.4 EGV parse → snapshot save

`handleEGVPayload` (L1495):
- Filter: only `data[0] == 0x4E` (L1503) — correct G7 EGV opcode.
- Length check: `data.count >= 19` (L1496). G7SensorKit requires similar length; OK.
- Parses `txTime`, `sequenceNumber`, `egvAge`, `glucoseRaw`, `trendByte` — offsets 2/6/10/12/15, all within `[0, 15]` for a 19-byte payload. OK.
- `activation = Date() - txTime` on first EGV; `readingDate = activation + (txTime - egvAge)`. Matches G7 spec.
- `TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)` (L1619).
- `WatchState.shared.applyDirectBleSnapshot(snapshot)` (L1620).
- Does **not** invalidate the extended runtime session after snapshot save — intentional per comment at L1622, keeps listening.

**Finding 4.4: CORRECT.** Parse and save chain is clean. **Severity: N/A.**

### 4.5 Ranked post-connect failure likelihoods

Given what we know about the reference implementations and observer mode semantics, here's the ranked likelihood of failure **after** `didConnect` fires:

1. **`awaiting_first_egv` timeout without any `0x4E` frame. LIKELIHOOD: MEDIUM–HIGH.** Observer-mode eavesdrop depends on the sensor broadcasting EGVs on the control char to an authenticated listener. If the OS auth state is stale (post-upgrade, post-reinstall of the watch app, or first-time pairing lineage on a fresh sensor), `0x05` may report `authenticated=false`, gating closes. Even with `authenticated=true`, the sensor only emits EGVs every ~5 minutes; a cycle that attaches too late in the window may never see an EGV before the cycle's `graceClose`.  
   Mitigation: the 0x4E fallback covers this after `currentCycleFallbackDate`, but fallback requires a control write-with-response and an authenticated pipe; if auth is partial, fallback also fails silently.

2. **`authenticated=false` on `0x05`. LIKELIHOOD: MEDIUM.** This is the hardest observer-mode gate. Happens when the watch has never been a bonded peer of this sensor, or after a sensor swap. Trio's observer path has no active-pairing response, so we depend entirely on iOS/watchOS OS-level bond state being present. Result: `emitPassiveGateBlocked` + `emitPassiveObservationBlockedIfNeeded("authenticated_false")`, no EGV, cycle misses as `observation`/`passive_gate_not_satisfied`.

3. **`characteristics_incomplete` (missing auth or control char). LIKELIHOOD: LOW.** Unlikely on G7 — the sensor always exposes the standard char set. Only realistic if connected to a device that advertises FEBC but isn't actually a G7 (vanishingly rare given scan-filter).

4. **`notification_state` error for auth/control. LIKELIHOOD: LOW.** Requires a descriptor-write refusal from the peer. Not seen in G7 logs historically.

5. **`discover_services` / `no_data_service`. LIKELIHOOD: VERY LOW.** Would indicate a peer that advertises FEBC but not dataService — not a real G7.

6. **`gatt_setup` timeout (60s, bounded by cycle hard-stop). LIKELIHOOD: LOW.** Only happens if auth notify enables but `0x05` never arrives. Distinct from the `first_egv` timeout; covers the gap between char-discovery and the passive-ready gate.

### Part 4 summary

The post-connect chain is structurally ready to deliver a glucose reading. The top residual risks after `didConnect` fires are observer-mode auth state issues (items 1–2 above), which are inherent to observer-mode eavesdrop — not bugs in the chain. If build 180+181 restore `didConnect` and we still see cycle misses, the next diagnostic focus should be `g7_ble_status_reply authenticated=false` vs `authenticated=true` counts and `first_egv` timeout occurrences.

---

## Part 5 — Priority ranking for builds 181–185

Given the goal (reliable 5-minute CGM on the complication):

### Reordered / annotated priority list

**181 — doesPeripheralMatchActiveFilter + scan-path inline fix (suffix(2)).**  
- Prereq stated: YES (bug 2 is real).  
- **Bundle-in REQUIRED:** also fix the inline `name != active` compare in `didDiscover` (L2341). Without this, the scan path remains blocked and only the retrieved paths benefit. **This is a blocker for 181.**  
- Regression risk if deployed single-variable: LOW. suffix(2) is a net widening of match; the only regression surface is a second in-range G7 with the same 2-char suffix (Part 2 finding 3).  
- **Keep at position 1.** Without this, 180 alone doesn't restore `didConnect` via the scan path.

**182 — Re-enable `registerForConnectionEvents` (H1).**  
- Prereq stated: YES (connection-event attach is a supplementary path present in G7SensorKit).  
- Bundle-in considered: combine with enabling the `connectionEventDidOccur` delegate path (currently commented L2305–2326). These two must ship together — one is useless without the other.  
- Regression risk single-variable: LOW — connection events are additive; worst case is extra `g7_ble_connection_event_fired` log lines.  
- **Demote to position 3.** After 181, we should first validate whether the scan+retrieved paths alone deliver `didConnect` reliably. Connection events are an optimization, not a prerequisite.

**183 — Post-connect GATT validation / any needed fixes.**  
- Prereq stated: YES — contingent on 180+181 restoring `didConnect`.  
- Bundle-in: folding in the peripheral-identity guards (Part 1 findings 5–6: guard `self.peripheral ===` in `didConnect`/`didFailToConnect`/`didDisconnectPeripheral`) is a natural fit here — they're post-connect callback hygiene. Consider renaming to "post-connect callback hardening + GATT validation".  
- Regression risk single-variable: LOW. Identity guards only affect peripherals we don't own.  
- **Promote to position 2.** Combined with 181, this removes the last two silent-callback risks before we layer on connection events. It also pays off the Part 1 finding-5 (phantom `didDisconnect` during restore flush).

**184 — `willRestoreState` fast-path (attach restored peripherals instead of flushing).**  
- Prereq stated: YES — contingent on 180 flush working and 183 callback hygiene landing.  
- Bundle-in: this is effectively replacing the 180 flush with a G7SensorKit-style `handleDiscoveredPeripheral` attach (see `G7BluetoothManager.swift:340–345`). That requires routing restored peripherals through `beginRetrievedOrEventAttachIfEligible` with a new source label (e.g. `restored_state`). Split out the label + per-source allow-listing in `isRetrievedAttachSource` explicitly.  
- Regression risk single-variable: MEDIUM. The flush approach (build 180) is simple and proven by G7SensorKit's-ish pattern plus our added `stopScan`. Fast-path attach could re-introduce the silent-connect issue if our restored peripheral's state is `.connecting` and we fire another `connect()` without first cancelling. Must handle `peripheral.state == .connected` (attach straight to GATT discovery) vs `.connecting` (cancel first, or wait for `didFailToConnect`) explicitly.  
- **Keep at position 4.** Optimization over 180's flush; only worth doing after 181–183 confirm the basic path works.

**185 — Background operation validation.**  
- Prereq stated: YES (depends on foreground reliability first).  
- Bundle-in: include runtime-gate observability improvements (e.g. explicit `g7_ble_runtime_gate` stall detection when `isForegroundActive=false` across cycle boundaries).  
- Regression risk: N/A (observation build).  
- **Keep at position 5.**

### Final ordering I'd ship

1. **181** — suffix(2) fix to `doesPeripheralMatchActiveFilter` **AND** the `didDiscover` inline compare at L2341.  
2. **183 (promoted)** — peripheral-identity guards in didConnect / didFailToConnect / didDisconnectPeripheral + GATT validation.  
3. **182** — re-enable `registerForConnectionEvents` + `connectionEventDidOccur`.  
4. **184** — willRestoreState fast-path (attach restored instead of flushing).  
5. **185** — background operation validation.

---

## Part 6 — Other issues identified through static analysis

### Finding 6.1 — `didDiscover` bypasses `doesPeripheralMatchActiveFilter`. SEVERITY: BLOCKER.

**Location:** L2337–2346.

Already covered in Part 2 finding 1 and Part 5 (181 prereq). Restating here because it has the severity of a blocker for build 181's stated goal.

**Fix:** replace the inline compare with `guard doesPeripheralMatchActiveFilter(peripheral) else { … log skip … return }`, or duplicate the suffix(2) rule inline.

### Finding 6.2 — `didConnect` / `didFailToConnect` / `didDisconnectPeripheral` do not guard peripheral identity. SEVERITY: HIGH.

**Location:** L2361 (didConnect), L2394 (didFailToConnect), L2427 (didDisconnectPeripheral).

When `willRestoreState` flushes restored peripherals (build 180), the follow-up `didDisconnectPeripheral` lands on our delegate for peripherals we never set as `self.peripheral`. The current code:
- Logs `g7_ble_did_disconnect` + `g7_ble_error` as if this were our session ending.
- Emits a bogus `g7_ble_session_outcome outcome=incomplete … g7_session=none`.
- Calls `teardownSession(reason: "disconnected", isFailure: false)` → `scheduleNextCycleAfterMiss` → `refreshCadenceScheduler(trigger: "cycle_miss_disconnected", forceReschedule: true)`.

Same risk applies to a phantom `didConnect` mid-flush (narrow race): we would persist the restored peripheral's UUID into the app group and call `discoverServices` on a peripheral we don't own.

**Fix (bundle into build 183):**
```swift
func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral === peripheral else {
        Task { await logG7Ble("event=g7_ble_callback_ignored callback=did_connect reason=not_our_peripheral peripheral_id_short=\(peripheralIdShort(peripheral))") }
        return
    }
    …
}
```
…and analogous guards in the other two callbacks. For `didDisconnectPeripheral`, an alternative/ complementary fix is to check `pendingDisconnectReason == "will_restore_flush"` and early-return.

### Finding 6.3 — `connectTimeoutWorkItem` can fire in ≤100 ms if cycle hard-stop has already passed. SEVERITY: HIGH (conditional).

**Location:** L1369–1393 (`scheduleConnectTimeout`) via L1321 (`cycleRelativeDelay`).

```swift
private func cycleRelativeDelay(until targetDate: Date?, fallback: TimeInterval) -> TimeInterval {
    guard let targetDate else { return fallback }
    return max(0.1, targetDate.timeIntervalSinceNow)
}
```

If a connect is attempted after `currentCycleHardStopDate` has already passed (e.g. a late re-sighting, a runtime gate opening after the deadline, retrieved-attach deep into the grace window), `cycleRelativeDelay` clamps to `0.1` seconds. The connect timeout then fires at 100 ms with `stage=awaiting_connect` → `teardownSession(reason: "timeout_awaiting_connect")`. This guarantees a miss even if CB would have delivered `didConnect` within the normal ~500ms–5s window.

**Fix options:**
- Add a floor: `max(G7BLEInstrumentation.minConnectTimeoutFloor, cycleRelativeDelay(…))` with `minConnectTimeoutFloor = 5` or `8` seconds.
- Or gate the attach earlier: refuse to call `beginConnectToG7Peripheral` if `currentCycleHardStopDate < now + 5s` (classify as `timing` miss without burning a connect attempt).

Preferred: **gate earlier** — otherwise we still connect and then tear down immediately.

### Finding 6.4 — `attemptedConnectPeripheralIdentifiers` can strand a valid peripheral within a session. SEVERITY: MEDIUM.

**Location:** L105–109 (declaration), L2183–2192 (check + insert).

If `connect()` is swallowed by CB (the bug 180 symptom) and no callback ever fires, the connect-timeout eventually fires (30s, bounded by hard-stop). Until it does, any re-sighting from the scanner or a fresh `retrieveConnectedPeripherals` result is suppressed as `duplicate_peripheral_in_attach_cycle`. This is documented as "intentional diagnostic tradeoff for F5" (L107–108), but it means:
- After builds 180+181, if there's residual silent-connect behavior from a third unknown bug, we'll have only one attempt per session to observe the failure.
- The connect-timeout fallback + `scheduleRetryWithinCurrentCycle` will clear this via `startScanning()` (which resets the set, L469), but only after a 30-second wait.

**Fix (optional, part of build 183 hardening):** on connect timeout, clear `attemptedConnectPeripheralIdentifiers` before the retry so the next `startScanning()` can hit the same peripheral without waiting for the dedup to clear. Alternatively, add an age-based eviction: if a peripheral was inserted more than `cycleRelativeDelay(hardStop)` ago and no callback fired, evict.

### Finding 6.5 — Phantom `session_outcome=incomplete` log lines on launch due to unguarded `didDisconnectPeripheral`. SEVERITY: MEDIUM (log-quality).

**Location:** L1249–1251 in `teardownSession`, triggered by unguarded L2427 when restore-flush cancels land.

Covered by fix 6.2; flagged separately because it also pollutes the session-outcome metric that the analysis doc relies on for diagnosis.

### Finding 6.6 — Runtime-gate `blocked_app_inactive` is silent after the first cycle. SEVERITY: MEDIUM.

**Location:** `ensureRuntimeForCurrentCycle` L886–893.

```swift
guard isForegroundActive else {
    Task {
        await logG7Ble(
            "event=g7_ble_runtime_gate trigger=\(trigger) state=blocked_app_inactive expected_epoch=\(…)"
        )
    }
    return .unavailable
}
```

When the watch app is not active (user left the app, or the scheduler fires from a background-like state), the cycle misses as `runtime_unavailable` → `scheduleNextCycleAfterMiss` → the next cycle is anchored at the next 5-minute boundary and warms up again. If `isForegroundActive` never flips back to true, we log one `blocked_app_inactive` per cycle but never attempt to recover until foreground re-entry.

This is by design per the Phase G doc, but the user-facing goal ("reliable 5-minute CGM readings on the complication") fundamentally requires the watch app to be foregrounded often enough to reacquire runtime. This is a platform constraint, not a bug, but it's worth explicit measurement in build 185.

**Recommended action:** add a `g7_ble_cycle_missed category=runtime reason=foreground_unavailable consecutive_count=N` log so we can see the background-reliability ceiling in field logs.

### Finding 6.7 — `central.scanForPeripherals(withServices: [advertisement], options: nil)` vs restore. SEVERITY: LOW.

**Location:** L503 (`startScanning`), L2271 (`centralManagerDidUpdateState`).

With `CBCentralManagerOptionRestoreIdentifierKey` set, watchOS expects the restored scan to survive relaunch. Our build 180 explicitly stops the restored scan and starts a new one from `startScanning()`. This is correct for the current design (Phase G scheduler owns scan start/stop). No action required.

### Finding 6.8 — `egvReceivedThisSession` is NOT reset on cycle rearm. SEVERITY: LOW.

**Location:** L1040 in `resetSessionState` (reset on teardown); L2069 `resetObservationStateForCycleRearm` does NOT reset `egvReceivedThisSession`.

If the same connected session sees EGV #1 in cycle N and then is re-armed for cycle N+1 via `armPassiveObservationIfReady(forceCycleRearm: true)`, `egvReceivedThisSession` remains `true` from the prior cycle. Impact: `mapSessionOutcome` at teardown would misclassify the cycle as `success` even if cycle N+1 never produced an EGV. Also `continueCurrentCycleExecution` at L784 re-arms observation but doesn't reset awaiting-EGV flags via `resetObservationStateForCycleRearm` directly — it's called inside `armPassiveObservationIfReady(forceCycleRearm: true)` (L2070) which calls `resetObservationStateForCycleRearm` but that function (L993) does NOT clear `egvReceivedThisSession`.

**Fix:** add `egvReceivedThisSession = false` to `resetObservationStateForCycleRearm` (L993–1005), OR derive cycle success from `lastSuccessfulDirectBleReadingDate >= currentCycleAnchorDate` instead of a per-session flag. The latter is more robust.

### Finding 6.9 — `activePeripheralName` normalization is whitespace-only, not case-insensitive. SEVERITY: LOW.

**Location:** `normalizedPeripheralName` L2888–2891.

If the phone sends `"DexcomXX"` one cycle and `"dexcomxx"` another (hypothetical phone-side lowercasing bug), the suffix match `name.suffix(2) == active.suffix(2)` will hit `"XX"` vs `"xx"` and fail. G7SensorKit is case-sensitive too, so this is only a concern if Trio's phone side normalizes differently.

**Fix:** consider lowercasing both sides in `doesPeripheralMatchActiveFilter` for the suffix comparison. Cheap defense.

### Finding 6.10 — `scheduleGattSetupTimeout` is started on `didConnect`, but it's cancelled only on `observer_ready` (all three gates). SEVERITY: LOW.

**Location:** L2366 (arm), L2712–2715 (cancel gate).

If authentication succeeds but control notify enable takes longer than the bounded gatt-setup timeout (60s or hard-stop-bounded), we time out as `awaiting_gatt_setup` even though the observer is close to ready. In practice this overlaps with `firstEgvTimeoutWorkItem` (armed at `armPassiveObservationIfReady`), but there's a gap: between `0x05 authenticated=true` and `controlNotificationsReady=true`, only `gatt_setup` is armed. **Severity: low**, because this gap is usually sub-second, but worth noting for tuning.

### Finding 6.11 — `persistPeripheralIdentifier(peripheral.identifier, reason: "connect_attempt")` fires BEFORE `didConnect`. SEVERITY: LOW.

**Location:** L2249.

We persist the identifier as soon as we issue `connect()`, not after `didConnect`. If a wrong peripheral is selected (Part 2 finding 3 — suffix(2) collision), we persist the wrong UUID. The next cold-boot `retrievePeripheralsByIdentifierIfAvailable` will preferentially re-attach to this wrong peripheral. `setActivePeripheralName` clears the persisted identifier when the phone-side name changes (L2874–2877), but not on suffix collision.

**Fix:** persist only on `didConnect` (the second call at L2362 already does this). Remove the `connect_attempt` persist, OR add a "tentative" flag that is promoted to "confirmed" only on `didConnect`.

---

## Prioritized action list (next 5 builds)

1. **Build 181 — suffix(2) AT BOTH SITES.** Update `doesPeripheralMatchActiveFilter` (L1746) AND the inline compare in `didDiscover` (L2341) to use suffix(2). Add debug log distinguishing `match=exact` vs `match=suffix`. **MUST ship together.** (Blocks all attach paths from working.)

2. **Build 183 (promoted) — post-connect callback hardening.** Add `guard self.peripheral === peripheral else { return }` to `didConnect`, `didFailToConnect`, `didDisconnectPeripheral`. Set `pendingDisconnectReason = "will_restore_flush"` in `willRestoreState` before the cancel loop. Add `egvReceivedThisSession = false` to `resetObservationStateForCycleRearm`. Remove the `connect_attempt` persist OR mark it tentative. Optional: add a min floor to `cycleRelativeDelay` used in connect-timeout scheduling (Finding 6.3).

3. **Build 182 — re-enable connection events.** Un-comment `registerForConnectionEventsIfNeeded` invocations (L502, L2270) AND the `connectionEventDidOccur` delegate (L2305). Ship together.

4. **Build 184 — `willRestoreState` fast-path.** Route restored peripherals through `beginRetrievedOrEventAttachIfEligible` with a new `source="restored_state"` label, handling `.connected` vs `.connecting` explicitly. Replaces the 180 flush. Requires 183's callback guards to be in place.

5. **Build 185 — background operation validation.** Add cumulative `foreground_unavailable` miss counting (Finding 6.6). Add `g7_ble_cycle_missed` observability for consecutive runtime-gate misses. No functional changes.

---

**End of review.**
