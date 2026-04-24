
Here is the disciplined report. Citations point to your initiative docs and the current `G7DirectBLEManager` / DiaBLE / `G7BluetoothManager` code paths.

---

## 1. Executive conclusion

**Evidence-backed:** Build **166** (instrumentation report **03** v1.33–v1.34, comparison doc **05** v1.9–v1.10) shows the failure mode has **split**: **16/17** connect attempts still die at **`awaiting_connect`** on the **scan** path, while **exactly one** session used **`source=retrieved`**, crossed **`g7_ble_did_connect`**, then stalled at **`discovering_services`** / **`awaiting_gatt_setup`** with **no downstream service/auth/EGV proof** in that build’s watch-only review. That shifts the primary **unresolved** boundary from “no `didConnect` ever” to **(a)** why **scan-path `connect()` usually never completes on watchOS**, and **(b)** why **`didDiscoverServices` / full GATT startup did not complete** in the one post-connect case.

**Interpretation:** `source=retrieved` means Trio obtained the `CBPeripheral` from **`retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])`** (and logged **`g7_ble_connect_attempt` / `g7_ble_pre_connect`** with that source), not from **`didDiscover`** (`source=scan`). That usually implies CoreBluetooth is surfacing a peripheral the **system already treats as connected** for the **data GATT service**—a different **starting relationship** than a peripheral only seen from an advertisement.

**Strongest next move:** Close the **post-connect** trail with **high-signal attribution** (your **F5** intent: make the first missing **CoreBluetooth delegate** after `didConnect` obvious—confirm whether **`peripheral(_:didDiscoverServices:)`** ever runs, with errors, and whether **`g7_ble_did_discover_services_entered`** appears in Better Stack). **Parallel:** keep **F9-style** split analysis (**retrieved vs scan**) because the only **`didConnect`** in build **166** was **retrieved**, which is too strong to treat as coincidence until disproven.

**PacketLogger:** Remain **deferred** until **F5** proves whether the stall is **“callback never delivered”** vs **“delivered but filtered out of searches”**. If **`g7_ble_did_discover_services_entered`** is absent, that is already strong grounds to **pull PacketLogger forward** for ACL/GATT visibility. If it is present with an error, stay on **logs + code** first.

---

## 2. What `source=retrieved` means in plain English

In Trio’s instrumentation, **`source=retrieved`** on **`g7_ble_pre_connect`** / **`g7_ble_connect_attempt`** means: **`central.connect(peripheral, options: nil)`** is being driven from the **`retrieveConnectedPeripherals`** branch, not from the advertisement **`didDiscover`** path.

**Code:** `beginConnectToG7Peripheral` maps `source` to logging as **`scan`** only when the argument is **`nil` or `"scan"`**; any other string (e.g. **`"retrieved"`**) logs as **`retrieved`**:

```1090:1114:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift
        let preConnectSource: String = {
            switch source {
            case nil, "scan": return "scan"
            default: return "retrieved"
            }
        }()
        ...
        central?.connect(peripheral, options: nil)
```

Retrieval is invoked in **`startScanning()`** (before scanning) and again in **`centralManagerDidUpdateState(.poweredOn)`** when still in **`.scanning`**:

```314:345:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift
        let retrievedPeripherals = central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])
        ...
                    beginConnectToG7Peripheral(
                        retrieved,
                        ...
                        source: "retrieved",
```

```1127:1162:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift
        let retrievedOnPoweredOn = central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService])
        ...
                    beginConnectToG7Peripheral(
                        retrievedPeripheral,
                        ...
                        source: "retrieved",
```

**Plain English:** “Use the peripheral object CoreBluetooth associates with an **already-active** connection (for the **data service UUID**), instead of the one you just found advertising.”

---

## 3. Why the retrieved success matters

**Evidence (docs):** Instrumentation report **03** v1.33 and comparison **05** v1.9 state that the **only** build-166 session that reached **`g7_ble_did_connect`** used **`source=retrieved`**, while the **16** others failed at **`awaiting_connect`** from the **scan** path.

That pattern supports:

- **Tier 1:** **Scan-path and retrieval-path are not equivalent** on this hardware/OS stack for Trio—even though both call the same **`connect(options: nil)`**.
- **Tier 2:** Retrieval may correlate with **system-level** knowledge (active GATT / link) that makes **`didConnect`** (or equivalent progression) **much more likely** than a cold connect from an adv.

It does **not** prove retrieval “fixes everything”: that same session still **did not** show a completed service-discovery / observer pipeline in the build **166** review.

---

## 4. Evidence-backed findings

| Finding | Support |
|--------|---------|
| Observer/auth divergence is **no longer** the leading **pre-connect** story | Design **01** still lists historical divergence; **03** snapshot (v1.34) says observer path rows are **met**; **05** marks observer/J-PAKE/backfill as **corrected** for the current stall story. |
| **Pre-connect** blind spot is largely closed | **03** Tier 1 item 11: **`g7_ble_pre_connect`**; **05**: pre-connect superseded as primary unknown. |
| **`queue: nil`** did not fix the dominant stall | **03** v1.30: build **164** — **7** attempts, no **`didConnect`**; **05**: queue theory weakened. |
| **Scan option** change did not fix it | **03** v1.33: build **165** — **9** attempts, all **`awaiting_connect`**. |
| **Early `CBCentralManager` init (F4)** coincided with **first** watch **`didConnect`** | **03** v1.33: build **166** — **1/17** **`didConnect`**; **05** v1.9. |
| **Only `retrieved` session reached `didConnect`** in that positive build | **03** v1.33 / **05** v1.9 (explicit). |
| **Post-connect** boundary is now the lead: **`discovering_services`** / **`awaiting_gatt_setup`** without **`g7_ble_services_discovered`** (per build **166** review) | **03** v1.33; **05** “immediate post-connect GATT startup” row. |
| Trio **narrow** `discoverServices([dataService])` vs DiaBLE **`discoverServices(nil)`** | **05** matrix rows 3–4; code **`didConnect`** → **`discoverServices([G7BLEUUID.dataService])`** at ```1247:1248:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift```. |
| DiaBLE watch **happy path** (logs **04**): connect → discover services → auth notify → skip J-PAKE → **0x03/0x05** → control notify → **0x4E** | **04** Log 1 / 3; **01** DiaBLE Observer Reference. |
| Trio phone **`G7BluetoothManager`** uses **`registerForConnectionEvents`** + **`retrieveConnectedPeripherals`** (adv + CGM service) + scan | ```206:227:/Users/charliechrisman/Code/src/cachrisman/diabetes/G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift``` — Trio watch **does not** use **`registerForConnectionEvents`**. |

---

## 5. Apple/CoreBluetooth/watchOS hypotheses

(Each labeled: **Tier 1** = strongly supported; **2** = plausible; **3** = weak.)

1. **Retrieved peripheral = OS-known active GATT for that central (Tier 1–2)**  
   **`retrieveConnectedPeripherals`** is defined by Apple as returning peripherals **currently connected** and implementing the given service UUIDs. So **`source=retrieved`** usually means: the **stack already has** a live connection context for that service—not merely “seen in an ad.” **Discriminating experiment:** log **`peripheral.state`** and **`peripheral.identifier`** on **`g7_ble_pre_connect`** for both paths (partially there via **`peripheral_state`**); compare **retrieved-success** vs **scan-fail** sessions.

2. **Scan-path `connect()` stalls because the G7 / OS is not granting a **second** central role from the watch at that moment; retrieval only appears when the watch already participates in a connection (Tier 2)**  
   DiaBLE logs (**04**) show **“Encryption is insufficient”** on control/backfill until after auth path progresses—suggests **link-layer / security** gating. **Experiment:** time Trio attempts vs Dexcom app state on phone/watch; log **`didFailToConnect`** (often absent today if nothing fires—**03** F1 trail).

3. **State restoration + early manager (F3/F4) changed **which** `CBPeripheral` instances exist and when `retrieveConnectedPeripherals` is non-empty (Tier 2)**  
   Trio now uses **`CBCentralManagerOptionRestoreIdentifierKey`** in ```410:419:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift```. **Experiment:** frequency of **`g7_ble_will_restore_state`** vs success.

4. **Post-connect: `discoverServices` dispatched but `didDiscoverServices` not delivered before **`awaiting_gatt_setup`** timeout (Tier 1 given build 166 narrative)**  
   Code calls **`discoverServices`** immediately in **`didConnect`**; success logs **`g7_ble_services_discovered`** only after delegate runs ```1334:1374:/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio Watch App Extension/G7DirectBLEManager.swift```. **Experiment:** confirm presence/absence of **`g7_ble_did_discover_services_entered`** in Better Stack for the stalled session (**refinement of F5**, not new).

5. **`registerForConnectionEvents` absence on watch (Tier 2, materially new vs F5–F9 framing)**  
   Phone **`G7BluetoothManager`** registers connection events for service UUIDs; Trio watch does not. **Hypothesis:** on watchOS, some connections are surfaced primarily via **connection events** rather than scan. **Kill:** if PacketLogger shows scan-path **CONNECT_REQ** never gets a response, it’s not just “missing event registration.”

---

## 6. Plausible but not yet proven hypotheses

| Idea | Label | Why plausible | Strengthen | Weaken |
|------|-------|---------------|------------|--------|
| Dexcom **multi-device whitelist** (logs show **max devices: 3** in **04**) interacts with **which** central gets a link | **materially new idea** | G7 may accept limited simultaneous centrals; scan-path may retry when slot full. | Correlate failures with **`0xEA` whitelist** replies on a working client | Stable failures even when Dexcom app killed |
| **watch extension** suspended / runtime budget between **`connect`** and service discovery | **materially new idea** | **`awaiting_gatt_setup`** is long (60s code) but still might race with scheduler. | On-device **`WKApplication`** / scene state logs around stall | Clean **`didDiscoverServices`** always follows **`didConnect`** in console |
| **Name / filter mismatch** on scan (**DXCMKo** vs phone string) | **refinement of existing doc idea** | Trio uses **trim-only** **`normalizedPeripheralName`** ```1659:1661```; DiaBLE rewrites names in **`BluetoothDelegate`**. | Log **both** `peripheral.name` and **active** filter when skipping | **`g7_ble_peripheral_skipped`** already firing often (it isn’t in the 16/17 story—those are connect timeouts, not skip storms) |
| **Double retrieval** (`startScanning` + `.poweredOn`) causes odd ordering | **refinement** | Two code paths call retrieval. | Single retrieval experiment | No ordering anomalies in logs |

---

## 7. Which current doc ideas still look strongest

- **F5-style post-connect attribution** (**already in docs**): Still the best **next** move because build **166** moved the boundary to **post-`didConnect`** (**03** v1.33).
- **F9 retrieval vs scan analysis** (**already in docs**): Still mandatory context—the **only** **`didConnect`** was **`retrieved`** (**05** v1.9).
- **F6/F7 conditional on F5** (**already in docs**): Still logical: **`discoverServices(nil)`** vs **`discoverCharacteristics(nil)`** parity **after** you know which callback is missing (**05** matrix).

---

## 8. Which current doc ideas look weaker now

- **Queue `nil` as primary lever** (**weaker**): **03** v1.30 — negative at scale.
- **Scan duplicate-suppression option** (**weaker**): **03** v1.33 — negative.
- **Extended runtime near connect** as **current** blocker (**weaker / retired**): **05** — isolation + build **163** still timed out pre-connect; code still skips ext session ```448:450```.

---

## 9. Materially new ideas beyond the current docs

1. **`registerForConnectionEvents` parity with `G7BluetoothManager` on watch** (see §5) — **materially new idea**.
2. **Explicit hypothesis: “G7 link slot / whitelist / phone-app ownership”** timed with Trio attempts — **materially new idea** (informed by **04** whitelist lines, not proven for Trio’s failure).
3. **Extension process scheduling / suspension** between **`connect`** and **`didDiscoverServices`** — **materially new idea** (testable with process/foreground correlation, not in F5–F9 text).

---

## 10. Best evidence-backed next steps

**NOW (highest signal):**  
**F5-class instrumentation** (**refinement of existing doc idea**): Ensure Better Stack queries include **`g7_ble_did_discover_services_entered`**, **`g7_ble_services_discovered`**, **`g7_ble_services_discovery_failed`**, and **`g7_ble_did_discover_characteristics_entered`** — they already exist in code ```1334–1374```, ```1382–1400``` but build **166** summary cited **`g7_ble_services_discovered`** count **0**; **verify** whether **`g7_ble_did_discover_services_entered`** was emitted (dashboards may have searched only one event name). **Question answered:** Is the stall **before** or **inside** `didDiscoverServices`?

**Next:** If **`did_discover_services_entered`** is **absent**, treat as **delegate never called** → consider **PacketLogger** (**pull forward**). If **present with error**, parse error domain first.

**Conditional:** **F6** `discoverServices(nil)` (**already in docs**) only if F5 proves **`didDiscoverServices`** completes but **data service** missing (unlikely if you only need one service).

**Do NOT yet:** Broad rewrite of observer protocol, phone **`G7SensorKit`**, or large scan rearchitecture.

**PacketLogger:** **Defer** until F5 clarifies whether the gap is **air/link** vs **GATT delegate**. **Justification:** **03** v1.34 — logs still moved the boundary without sniffing; **but** if F5 shows **`didConnect` + no `did_discover_services_entered`**, **pull PacketLogger forward** for that session.

---

## 11. What I would do next if this were my branch

1. Run one Better Stack timeline on build **166**’s successful session id: list **every** `g7_ble_*` including **`g7_ble_did_discover_services_entered`** and **`g7_ble_gatt_setup_timeout_armed`** (if any). **Question:** Did **`peripheral(_:didDiscoverServices:)`** run at all?  
2. If **`did_discover_services_entered` is missing** after **`didConnect`**, **pull PacketLogger** for that run only.  
3. Split dashboards: **`g7_ble_connect_attempt source=scan`** vs **`source=retrieved`** rates and **`g7_ble_did_connect`** — **F9** (**already in docs**).  
4. Only then consider **`discoverServices(nil)`** (**F6**) as a **single-variable** experiment if F5 proves service discovery returns empty or wrong services.

---

### Tier summary (required)

- **Tier 1 — Evidence-backed:** Build **166** split (**scan** fails **`awaiting_connect`**, **one** **`retrieved`** **`didConnect`**); post-connect stall before full GATT/observer proof (**03**/ **05**); Trio **`discoverServices([dataService])`** and full delegate chain in **`G7DirectBLEManager`**; DiaBLE **`04`** proves watch observer sequence when connect works; phone **`G7BluetoothManager`** uses **restore + retrieve + `registerForConnectionEvents`**.

- **Tier 2 — Plausible, testable:** Multi-client / whitelist / phone-app ownership; **`registerForConnectionEvents`** on watch; extension scheduling; retrieved vs scan **OS relationship** difference.

- **Tier 3 — Weak / dead for *current* evidence:** Queue-only theory; scan-option-only theory; extended-runtime-at-connect as **primary** (retired); **pure** name-normalization as **primary** blocker for the **16** scan timeouts (no skip storm described—connect never completes).

---

### Direct answers (compressed)

**A1–A4:** `source=retrieved` = connect via **`retrieveConnectedPeripherals`** (data service), not adv **`didDiscover`**. **`scan`** = from **`didDiscover`**. Retrieved success matters because it’s the **only** **`didConnect`** in build **166** data. “Better starting relationship” ≈ **system already has** a **connected** GATT context for that peripheral/service UUID from this Bluetooth stack’s perspective—not only a **hearing an advertisement**.

**B:** DiaBLE: **`BluetoothDelegate`** **`.poweredOn`** → **`retrieveConnectedPeripherals`** (Dexcom uses **advertisement UUID FEBC** in DiaBLE ```48:51:/Users/charliechrisman/Code/src/cachrisman/diabetes/DiaBLE/DiaBLE/BluetoothDelegate.swift```) → synthetic **`didDiscover`** → **`stopScan`** → device **`connect`** path (see **04**). Trio **aligns** on observer sequence **in code** (**03**); **differs** on retrieval UUID (**data** vs DiaBLE **FEBC** in DiaBLE), **scan** filter breadth, **no** **`registerForConnectionEvents`**, strict **phone name** filter. **Relevant to failure:** connect-path **context** (retrieved vs scan, manager lifecycle) + **post-connect** discovery scope; **red herring for current boundary:** auth-init/J-PAKE (fixed in code per **03**).

**C:** Retrieved more likely to reach **`didConnect`** **because** it’s tied to **already-connected** peripherals for the service (**strong**, Apple API semantics + **05** runtime). **Encryption/session readiness** (**plausible**). **Tier 3:** “retrieved is always better radio” without evidence.

**D:** **Best explanation:** **Scan-path** `connect()` usually never completes on watchOS under current runtime (**16/17**). **One** **retrieved** path completed link enough for **`didConnect`**, then **GATT discovery pipeline** did not complete within the **awaiting_gatt_setup** window (**03**). **Primary boundary now:** **post-connect** (not “pure pre-connect only”). **Strongest unresolved:** **`didDiscoverServices` / service discovery completion** vs timeout.

**E–G:** Covered in §§9–11; **smallest discriminating experiment:** single-session timeline including **`g7_ble_did_discover_services_entered`**; **noise:** more scan-tuning without **`source=`** split.

---

**Novelty check:** ≥3 **materially new** testable hypotheses: **`registerForConnectionEvents`** (§5/9), **whitelist/slot/ownership timing** (§6), **extension suspension** (§6). ≥1 **Apple/CoreBluetooth** hypothesis not reducible to F5–F9: **retrieveConnected = system-connected GATT context** vs **adv-only peripheral** (§2–3, §5).