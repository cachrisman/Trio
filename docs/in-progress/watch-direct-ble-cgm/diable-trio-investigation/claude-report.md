This confirms a critical detail: DiaBLE retrieves with `FEBC` (advertisement UUID) while Trio retrieves with the data service UUID `F8083532...`. Now I have all the evidence I need.

---

# 1. Executive conclusion

The current evidence strongly indicates that **Trio's primary problem is not a single code bug but an environmental/timing mismatch in how it presents itself to CoreBluetooth on watchOS** relative to DiaBLE. The one successful `didConnect` on build 166 came via `source=retrieved`, not `source=scan`, which is a strong signal that the Dexcom G7 peripheral's relationship with the watch OS was already more established in that specific moment. The 16 scan-path failures are consistent with the hypothesis that **watchOS CoreBluetooth connects to a recently-scanned peripheral far less reliably than to a peripheral it already knows about from retrieval, state restoration, or prior system-level interaction** — and that DiaBLE implicitly benefits from this because it (a) creates its `CBCentralManager` eagerly at launch with a restore identifier, and (b) routes retrieved peripherals through the same connect path as scanned ones, meaning it catches the "already known" window more often.

The build-166 session that did succeed then **stalled at service discovery** — `g7_ble_timeout stage=awaiting_gatt_setup` with zero `g7_ble_services_discovered` — which is a separate, probably post-connect GATT attribution issue that I will analyze below.

The docs' current plan (F5 next, then conditional F6/F7) is structurally sound but **under-weighted on the retrieval-path advantage** and **missing some non-obvious Apple-platform hypotheses** that the evidence now supports. I identify three materially new ideas and critically evaluate the existing plan below.

---

# 2. What `source=retrieved` means in plain English

When Trio logs `event=g7_ble_connect_attempt source=retrieved`, it means the `CBPeripheral` object that Trio passed to `central.connect()` was **not obtained from a scan advertisement callback** (`didDiscover`). Instead, it was obtained from `central.retrieveConnectedPeripherals(withServices:)` — an API that asks CoreBluetooth: "do you already know about any peripherals that are connected to the system and implementing this GATT service?"

In concrete terms: the Dexcom G7 was already connected at the **watchOS system level** — likely by the Dexcom Watch app or by a prior CoreBluetooth session — when Trio asked. CoreBluetooth handed Trio a reference to that already-connected peripheral. Trio then called `connect()` on that reference.

This differs from `source=scan` because:
- **Scan path**: Trio discovers a peripheral via BLE advertisement (`FEBC`), then calls `connect()` on a freshly-discovered, never-before-interacted-with `CBPeripheral`. CoreBluetooth must negotiate a brand new link-layer connection.
- **Retrieved path**: Trio gets a `CBPeripheral` that CoreBluetooth already considers connected. When Trio calls `connect()` on this, CoreBluetooth may not need to establish a new link-layer connection at all — it may only need to transfer the existing system-level connection ownership to Trio's process.

---

# 3. Why the retrieved success matters

Out of 17 build-166 connect attempts, **16 scan-path attempts all timed out at `awaiting_connect`**. The **only** attempt that crossed `didConnect` used `source=retrieved`. This is a 0/16 vs 1/1 split. With only one success, this is not statistically conclusive, but the signal is strong enough to be the single most important clue in the current data set.

It matters because:
1. It demonstrates that Trio's post-`connect()` code path **does work** — the CoreBluetooth delegate wiring, stage transitions, and timeout cancellation all function correctly when `didConnect` actually fires.
2. It narrows the root cause to **what happens between `connect()` and `didConnect`**, not to Trio's code quality or API misuse.
3. It points to a **peripheral-state or connection-ownership** explanation: the peripheral that was already connected at the system level required less from CoreBluetooth to deliver `didConnect` to Trio.

A "better starting relationship" means, concretely: **CoreBluetooth already had an active link-layer connection to that peripheral when Trio called `connect()`**. This means no GAP-level connection negotiation, no advertisement-based connection setup, and potentially no contention with the Dexcom app for the connection slot. The peripheral was already "warm."

---

# 4. Evidence-backed findings

## 4a. The scan-path failure pattern is consistent across builds 163-166

**Evidence:** Instrumentation report v1.34 — builds 163, 164, 165, and 166 all show the same scan-path pattern: `g7_ble_connect_attempt -> g7_ble_connect_timeout_armed -> g7_ble_timeout stage=awaiting_connect`. No `g7_ble_did_connect`, `g7_ble_did_fail_to_connect`, or `g7_ble_did_disconnect` fires for scan-path sessions.

**Interpretation:** This is not a random failure. CoreBluetooth **silently drops** the connect request on the scan path. It doesn't fail — it simply never delivers `didConnect` or `didFailToConnect`. This is characteristic of watchOS connection management where the OS decides the connection attempt is not viable (wrong timing window, peripheral not connectable, connection slot already held, etc.) and silently abandons it without notifying the app.

**Status:** `already in docs` — well-documented in the comparison doc.

## 4b. DiaBLE's `discoverServices(nil)` vs Trio's `discoverServices([dataService])`

**Evidence (direct code inspection):**
- DiaBLE `BluetoothDelegate.swift` line 284: `peripheral.discoverServices(nil)` — discovers ALL services
- Trio `G7DirectBLEManager.swift` line 1247: `peripheral.discoverServices([G7BLEUUID.dataService])` — discovers only the data service
- DiaBLE `BluetoothDelegate.swift` lines 330-443: `peripheral.discoverCharacteristics(nil, for: service)` — discovers ALL characteristics for each service
- Trio `G7DirectBLEManager.swift` lines 1376-1379: `peripheral.discoverCharacteristics([auth, control, backfill, jPake], for: svc)` — discovers specific characteristics only
- G7SensorKit `G7PeripheralManager.swift`: also uses targeted service and characteristic UUIDs (not nil)

**Critical observation:** The build-166 session that did connect then stalled at `stage=discovering_services` with zero `g7_ble_services_discovered`. This means `peripheral.discoverServices([G7BLEUUID.dataService])` was called but the delegate callback never fired. This is exactly where a `discoverServices(nil)` vs `discoverServices([specific])` difference could matter: **if the Dexcom G7's GATT database presents services differently on a retrieved/already-connected peripheral vs a freshly-scanned one**, a targeted filter might miss them while `nil` would catch them. Or the GATT cache from the prior owner session might be stale.

**However:** G7SensorKit on the phone also uses targeted UUIDs and succeeds. So targeted discovery is not inherently broken. The question is whether it behaves differently **on watchOS** for a **retrieved peripheral that was previously owned by another app**.

**Status:** `already in docs` as discrepancy #3 (F6 candidate). But the post-connect stall evidence now makes this **much more urgent** than the docs suggest.

## 4c. The retrieval UUID difference

**Evidence (direct code inspection):**
- DiaBLE retrieves with `FEBC` (advertisement UUID): `manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: Dexcom.UUID.advertisement.rawValue)])` — `BluetoothDelegate.swift` line 49
- Trio retrieves with `F8083532-849E-531C-C594-30F1F86A4EA5` (data service UUID): `central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])` — `G7DirectBLEManager.swift` line 314, 1128
- G7SensorKit retrieves with **both**: `[SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID]`

**Interpretation:** `retrieveConnectedPeripherals(withServices:)` matches against **implemented GATT services** on connected peripherals. Trio's use of the data service UUID should work, since a connected G7 does implement that service. However, it is possible that **on watchOS, the `FEBC` advertisement service UUID is indexed differently in the system's peripheral cache** than the full GATT data service UUID. DiaBLE using `FEBC` for retrieval could catch peripherals that Trio's data-service-UUID retrieval misses, particularly if the peripheral's GATT table hasn't been fully cached yet.

**Status:** `materially new idea` — the docs note the UUID difference in the comparison matrix but do not call out that it could affect **whether retrieval succeeds at all**, not just which UUID is "more correct."

## 4d. The observer/auth/control path is no longer the boundary

**Evidence:** All observer-path divergences (auth-init, J-PAKE, bonded gate, backfill coupling) have been corrected in code per comparison doc v1.10 discrepancy table. These are explicitly downstream of `didConnect` and cannot explain the pre-connect stall or the post-connect service-discovery stall.

**Status:** `already in docs` — correctly retired.

---

# 5. Apple/CoreBluetooth/watchOS hypotheses

### H1: Connection-slot contention with the Dexcom Watch app (Tier 1 — evidence-backed)

**Hypothesis:** The Dexcom G7 supports a **limited number of simultaneous BLE connections** (the BLE whitelist query returns `max_devices: 3` in the DiaBLE logs). On watchOS, the Dexcom Watch app likely holds the primary connection slot. When Trio calls `connect()` on a freshly-scanned peripheral, CoreBluetooth must negotiate a **new** link-layer connection, which the G7 firmware may **reject** (silently from CoreBluetooth's perspective) because the connection slot is occupied by the Dexcom app. When Trio calls `connect()` on a **retrieved** peripheral, CoreBluetooth can transfer or share the **existing** system-level connection without requiring a new link-layer connection negotiation, bypassing the slot limitation.

**Evidence supporting this:**
- DiaBLE log 1 (watch): `BLE whitelist: max devices: 3` — G7 has a hard connection limit
- DiaBLE logs show `error type 7: The specified device has disconnected from us` after each read — the G7 actively disconnects after data transfer
- The G7 connects to the official Dexcom app every ~5 minutes and disconnects between readings
- The one Trio success was on the retrieved path — consistent with catching an existing system connection
- 16/16 scan-path failures — consistent with the G7 rejecting new connections from a second client

**What would strengthen it:** Capture the exact timing of the successful `source=retrieved` connect attempt relative to the Dexcom app's 5-minute cycle. If it happened during a window where the Dexcom app was connected (and the watch OS shared that connection), that would be strong confirmation.

**What would weaken it:** If DiaBLE on the watch also connects via fresh scan (not retrieval) every time and succeeds. But the DiaBLE logs show `not yet known` on discovery, suggesting DiaBLE does sometimes connect fresh — though the logs also show DiaBLE using `retrieveConnectedPeripherals` in the `poweredOn` handler, and the watch logs may not distinguish which path actually produced the `connect()`.

**Status:** `materially new idea` — the docs mention connection slot limits as a risk but do not connect them to the retrieved-vs-scan asymmetry.

### H2: watchOS peripheral caching / "known device" advantage (Tier 2 — plausible)

**Hypothesis:** On watchOS, CoreBluetooth maintains an internal peripheral cache. A peripheral that has been previously connected (by any app) retains **encryption keys, GATT cache, and connection parameters** in the system cache. When Trio retrieves such a peripheral, `connect()` benefits from this cached state — it can skip GAP-level negotiation and go straight to GATT operations. A freshly-scanned peripheral lacks this cached state, and the connection attempt may time out or be deprioritized by the OS scheduler.

**Evidence:** The `CBCentralManagerOptionRestoreIdentifierKey` is now set in Trio. State restoration allows CoreBluetooth to re-deliver pending connections across app launches. DiaBLE has had this since inception. But Trio only added it in Phase E (build 162), and the positive result came in build 166 (after F4's earlier `CBCentralManager` allocation). The combination of restore identifier + earlier init + retrieval may have finally put Trio in the right lifecycle state to benefit from the system's peripheral cache.

**Test:** Log `peripheral.state` before `connect()` on every attempt, split by `source=scan|retrieved`. If retrieved peripherals show `state = .connected` (already connected) while scan-path peripherals show `state = .disconnected`, this confirms the cache advantage.

**Status:** `refinement of existing doc idea` (Phase E / restore identifier), but the **mechanism** (system-level encryption/GATT cache) is materially new.

### H3: The Dexcom G7 5-minute connection window (Tier 2 — plausible)

**Hypothesis:** The G7 advertises continuously but only accepts connections during a narrow window around its 5-minute reading cycle. The Dexcom app connects, exchanges data, and disconnects within seconds. DiaBLE's approach (eager manager, fast retrieval in `poweredOn`, immediate connect) catches this window reliably. Trio's approach (foreground-gated, scan-then-connect) may systematically miss the window because the scan-to-connect latency is longer, or because Trio's connect attempt arrives when the G7 is already servicing the Dexcom app.

**Evidence:** DiaBLE logs show the full cycle (discover → connect → services → auth → EGV → disconnect) completing in under 2 seconds. The G7 disconnects after data transfer (`error type 7`). Trio's scan path may reach `connect()` at arbitrary times relative to this cycle.

**Test:** Log the wall-clock time of each connect attempt and correlate with known G7 reading cadence. If successful connects cluster near the expected 5-minute marks (when the G7 has just finished its owner session and is briefly available), this would confirm timing-window relevance.

**Status:** `materially new idea` — not explicitly explored in the docs.

---

# 6. Plausible but not yet proven hypotheses

### P1: `discoverServices(nil)` would fix the post-connect stall (Tier 2)
- **Why plausible:** The build-166 session that crossed `didConnect` stalled at `discovering_services` with zero `g7_ble_services_discovered`. DiaBLE uses `discoverServices(nil)` and succeeds. On a retrieved/shared peripheral, the GATT cache may be owned by the prior app, and a targeted service request might not match correctly.
- **Test:** F6 build — change to `peripheral.discoverServices(nil)` and measure.
- **Would strengthen:** If services are discovered and the flow continues.
- **Would weaken:** If services still aren't discovered even with `nil`.
- **Status:** `already in docs` (F6 candidate), but **I am promoting its priority** because the post-connect stall evidence now directly implicates it.

### P2: Retrieval UUID mismatch causing missed opportunities (Tier 2)
- **Why plausible:** DiaBLE retrieves with `FEBC`, Trio with `F8083532...`. If the system peripheral cache indexes by advertisement service UUID more reliably than by GATT data service UUID, Trio's retrieval could return empty when DiaBLE's returns a match.
- **Test:** Add a parallel `retrieveConnectedPeripherals(withServices: [G7BLEUUID.advertisement])` call alongside the data-service retrieval and log the counts for both.
- **Would strengthen:** If the `FEBC` retrieval returns results when the data-service retrieval returns empty.
- **Would weaken:** If both return the same results.
- **Status:** `materially new idea`.

### P3: `registerForConnectionEvents` (Tier 2)
- **Why plausible:** G7SensorKit on the phone calls `centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [...]])` — this tells the OS to wake the app when a matching peripheral connects, even if the app wasn't scanning at that moment. DiaBLE doesn't use it, but Trio Watch doesn't either. On watchOS, this API could provide an additional pathway to catch the G7's connection window.
- **Test:** Add `registerForConnectionEvents` with both `FEBC` and data-service UUIDs.
- **Would strengthen:** If `connectionEventDidOccur` fires and produces a connectable peripheral.
- **Would weaken:** If it never fires on watchOS.
- **Status:** `materially new idea` — not in the docs at all.

---

# 7. Which current doc ideas still look strongest

1. **F5 (post-connect GATT trail closure)** — **Still the strongest next step.** The build-166 evidence directly shows a post-connect stall, and the current logs don't distinguish between "service discovery never started" and "service discovery started but callback never arrived." F5 would close that gap.

2. **F9 (retrieval-vs-scan analysis context)** — **Stronger than the docs suggest.** The 0/16 vs 1/1 split is the most important signal in the entire data set. This should be elevated from "analysis context" to "active diagnostic priority."

3. **F6 (`discoverServices(nil)` parity)** — **Stronger now than before.** The post-connect stall at service discovery makes this the natural F5 follow-up if F5 confirms that `didDiscoverServices` never fires.

---

# 8. Which current doc ideas look weaker now

1. **F7 (`discoverCharacteristics(nil)` parity)** — **Weaker.** We haven't even reached characteristics yet. This should only be considered after F6 proves service discovery works.

2. **F8 (audit startup-ready / timeout-cancel)** — **Weaker.** The timeout and readiness logic appears correct based on the build-166 log trail. The problem is upstream.

3. **PacketLogger deferral** — **I now disagree with continuing to defer.** The current logs show that CoreBluetooth silently drops connect requests without any delegate callback. PacketLogger is the **only** tool that can show what happens at the link-layer level — whether the connection request was sent, whether the G7 responded, and whether watchOS killed the attempt. After F5, if the pattern persists, PacketLogger should be pulled forward.

---

# 9. Materially new ideas beyond the current docs

### N1: Dual-UUID retrieval experiment
Add a parallel retrieval with `FEBC` alongside the current data-service-UUID retrieval. Log both counts. If `FEBC` retrieval catches peripherals that the data-service retrieval misses, switch to `FEBC` or use both. This is a zero-risk additive change.

### N2: `registerForConnectionEvents` on watchOS
G7SensorKit uses this on the phone to catch connections that happen while the app isn't scanning. On watchOS, this could provide an additional pathway to detect the G7 during its brief connectable window. The delegate `connectionEventDidOccur` would deliver a peripheral that Trio can immediately `connect()` to — potentially catching the window that scan misses.

### N3: Timing-correlated connect attempts
Instead of connecting whenever a scan advertisement arrives, **delay the connect attempt to align with the G7's expected 5-minute reading cycle**. If the G7 disconnects from the Dexcom app at time T, the optimal connect window is T + ~2 seconds (after the G7 is free but still connectable). This requires knowing or estimating the cycle timing, which could come from the previous EGV's timestamp or from observing advertisement pattern changes.

---

# 10. Best evidence-backed next steps

| Priority | Step | Question it answers | Code change | Why before others | Confirming result | Falsifying result |
|---|---|---|---|---|---|---|
| **1** | **F5: Post-connect GATT entry/exit logging** | Does `discoverServices` even start? Does `didDiscoverServices` ever fire? | Add entry/exit logging around `discoverServices`, log the peripheral state when called | Closes the gap between `didConnect` and the stall at `awaiting_gatt_setup` | `didDiscoverServices` fires with `service_count=0` or an error → points to F6 | `didDiscoverServices` fires with data service → problem is downstream |
| **2** | **Dual-UUID retrieval** (N1) | Does `FEBC` retrieval catch peripherals that data-service retrieval misses? | Add parallel `retrieveConnectedPeripherals(withServices: [FEBC])` alongside existing retrieval, log both counts | Zero-risk additive diagnostic; could immediately explain why retrieval rarely finds a peripheral | `FEBC` returns count > 0 when data-service returns 0 → switch to FEBC | Both return same counts → UUID choice is irrelevant |
| **3** | **F6: `discoverServices(nil)` parity** | Does widening service discovery scope fix the post-connect stall? | Change `discoverServices([dataService])` to `discoverServices(nil)` | Direct DiaBLE parity; addresses the exact post-connect stall | Services discovered, flow continues to characteristics | Services still not discovered → problem is lower |
| **4** | **PacketLogger capture** | What is watchOS doing at the link layer when scan-path connects fail? | No code change — profile capture | Answers whether the G7 is even receiving the connection request | Shows G7 rejecting or not seeing the request → confirms slot contention | Shows successful link-layer connection that the app layer drops → points to an OS/framework bug |
| **5** | **`registerForConnectionEvents`** (N2) | Can watchOS deliver G7 connection events to Trio without scanning? | Add `registerForConnectionEvents` with both service UUIDs | Alternative pathway that doesn't depend on scan timing | `connectionEventDidOccur` fires → new connect pathway | Never fires on watchOS → dead end |

**What to do NOW:** Steps 1 and 2 can be done in the same build. F5 (entry/exit logging at service discovery) plus the dual-UUID retrieval experiment. This is one build, two additive changes, maximum information.

**What NOT to do yet:** Do not change `discoverServices` scope (F6), do not add `registerForConnectionEvents`, do not change the reconnect strategy, and do not rewrite the connect path. Get the diagnostic data first.

---

# 11. What I would do next if this were my branch

**Immediate build (F5+):** Combine F5 post-connect attribution closure with the dual-UUID retrieval experiment (N1). This is one additive, non-breaking build that answers two orthogonal questions simultaneously.

Specific changes:
1. In `beginConnectToG7Peripheral`, log `peripheral.state` right before `connect()` (is the retrieved peripheral actually in `.connected` state vs `.disconnected`?).
2. In `didConnect`, log the peripheral state again and the list of `peripheral.services` (is there a cached GATT table from a prior session?).
3. In `startScanning()` and `centralManagerDidUpdateState(.poweredOn)`, add a parallel `retrieveConnectedPeripherals(withServices: [G7BLEUUID.advertisement])` call and log the count alongside the existing data-service retrieval count.
4. In `didDiscoverServices`, add entry logging immediately (already present but confirm it fires).
5. If `didDiscoverServices` never fires, that's the signal to proceed directly to F6.

**If that build shows `FEBC` retrieval works better:** Switch retrieval to use `FEBC` or both UUIDs. This alone could dramatically increase the rate of retrieved-path connections.

**If F5+ still shows service discovery never completing:** Immediately follow with F6 (`discoverServices(nil)`). Do not wait for another analysis cycle.

**Pull forward PacketLogger** if, after F5+ and F6, the scan-path connect still silently fails. At that point, the app-level instrumentation has been exhausted for the connect boundary, and only link-layer visibility can answer what watchOS is doing with the connection request.

**The hypothesis I'd bet on:** The combination of (a) dual-UUID retrieval increasing the hit rate on already-connected peripherals and (b) `discoverServices(nil)` fixing the post-connect stall will produce the first end-to-end watchOS EGV read. The scan path may never be reliable on watchOS due to connection-slot contention with the Dexcom app, but that's acceptable — if retrieval works consistently, the watch can catch each 5-minute cycle by being ready to retrieve the system-connected peripheral at the right moment.