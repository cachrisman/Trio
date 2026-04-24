# Implementation plan: Watch — Dexcom G7 direct BLE eavesdrop

**Version:** v1.82
**Status:** Watch-only **DiaBLE observer alignment** and the **Phase E / F** watch-side instrumentation trail remain implemented historical groundwork in `Trio`, and that execution trail extends through **F10 / build 170**. **Phase G** has now shipped in **build 171** and remains the basis for the current watch scheduler/runtime behavior: cadence-aware predicted-reading cycles, strict runtime-activation gating, and cycle-relative miss classification are live on device. Build-171 Better Stack logs show that this successfully changed the implementation boundary from blind retries to timing-aware runtime-gated attempts, but the dominant live failure bucket remains **pre-connect**: reviewed build-171 attempts still terminate at **`timeout_awaiting_connect`** with **0** watch-side **`g7_ble_did_connect`**. The active next effort is therefore now **Phase H — Pre-connect attach reliability**, not another observer-path or post-connect protocol phase. **Phase H2 and H3** (combined connected-peripheral retrieval ahead of identifier retrieval, and retrieval-aware **`preConnectSane`**) are **implemented and active** in the current `Trio` watch extension. **Phase H1** (`registerForConnectionEvents` + **`connectionEventDidOccur`**) is **implemented in source but disabled (commented out)** per **Phase I**. **Build 180** is now **deployed**, implementing the **`willRestoreState`** CB state restoration fix (primary hypothesis: CB silently swallows retrieval-path **`connect()`** due to restored scan state conflict). **Two complementary root causes** have been identified: (1) **`willRestoreState`** no-op allows CB to restore a stale scan / pending connection that makes subsequent **`connect()`** calls silent — **addressed in build 180** (static follow-up: restore flush can produce phantom delegate callbacks — see **[watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)** and **build 182** in the forward plan); (2) **`DXCMxx`** vs **`DexcomXX`** name duality: retrieval paths use **`doesPeripheralMatchActiveFilter`** (exact equality), while **`didDiscover`** uses a **separate inline** **`name != active`** guard that **bypasses** that helper — **both sites were fixed in build 181** (now **deployed**). **Build 182** is **deployed and field-validated**: retry loop confirmed working (multiple `connect_attempt` events per session), zero daytime `didConnect` due to slot competition + WKExtendedRuntimeSession gate. **Build 183** (**WKExtendedRuntimeSession gate removal** — decouple `startScanning()` from session activation; scan proceeds on `.starting` and `.unavailable`; session still started opportunistically) is now **deployed and live**; the **active next pre-connect build** in sequence is **184** (H1 re-enable) once identity guards / **[09](watch-direct-ble-cgm-09-preconnect-review.md)** gating is satisfied. **Sequential implementation order** remains **181 → 186** (see forward plan). The earlier round-robin attach-strategy comparison remains only a fallback diagnostic. **F10**, **F11**, and the other attach-context experiments remain preserved as historical evidence and later conditional tools only if **Phase H** / later evidence points back there.
**Created:** 2026-04-11 22:45 CET  
**Last updated:** 2026-04-23

**Design reference:** [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md)  
**Instrumentation report:** [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)  
**Pre-connect static review (build 180 / 181 plan):** [watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)  
**Diff review (out of band):** Optional transient `git diff` scratch docs may be generated under repo **`docs/code-review/`** per **`.cursor/rules/code-review-diff-doc.mdc`** — **not** linked from this initiative; traceability is **design / plan / report 03** only.

Per-version notes live in the [Changelog](#changelog) below (not duplicated in the header).

**Document state:** The active path in this document is now **Phase H** with **Phase I** field evidence through **builds 177–179** and **build 180** recorded in the **Implementation log**, plus a **two-bug analysis** (restore-path race + name-filter split across helper vs **`didDiscover`**) and a **forward plan through build 186** reconciled with **[watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)**. **Implementation sequencing uses strict ascending build numbers:** **181 → 182 → 183 → 184 → 185 → 186** (the **09** priority “harden delegates before H1” maps to **182** then **183** (WKS gate) then **184** (H1), not to out-of-order build labels). **Phase G** is implemented and shipped current behavior, and **build 171** is the first shipped/live execution point proving that the watch is now running a cadence-aware per-reading loop with explicit runtime gating instead of a generic reconnect model. That Phase G shift remains the foundation for all next work. The current dominant failure bucket is still **pre-connect / `awaiting_connect`**. **H2/H3** are active in `Trio`; **H1** remains commented out; planned for a later build after identity-guard hardening. **Build 180** is **deployed** with the **`willRestoreState`** flush fix. **Build 181** (suffix(2) name hygiene + skip retrieved-identifier dedup insert) is **deployed**. **Build 182** is **deployed and field-validated** (retry loop working; root cause of zero daytime `didConnect` identified as Phase G `WKExtendedRuntimeSession` gate + slot competition). **Build 183** (`WKExtendedRuntimeSession` gate removal) is **deployed and live**; **initial** BetterStack validation (2026-04-23) confirms build-tagged **`g7_ble_*`** trail including **`g7_ble_cycle_anchor` / `g7_ble_cycle_scheduled`**, **`g7_ble_lifecycle`**, **`g7_ble_peripheral_match_classified`**, and **`g7_ble_connect_suppressed`**; extended soak against the **Phase I — Build 183** acceptance list is ongoing. The prior **Phase E / F** material remains below as preserved historical evidence from the attach-context investigation, and the implementation log records **build 170** as the last attach-context-era baseline before the Phase G ship point and **build 171** as the transition point into the current Phase H diagnosis. Those sections still inform Phase H, but they are no longer the active top-level sequence; the round-robin attach-strategy experiment, **G3**, **PacketLogger / raw capture**, broader discovery, and deeper post-connect orchestration remain conditional follow-ons only if Phase H evidence later justifies them.

---

## Phase G — Cadence-aware watch G7 observation loop

Phase **F** narrowed the current watch boundary enough to justify a strategy change. The initiative is now shifting from blind retry / attach-context experimentation to cadence-aware scheduling around the Dexcom G7’s roughly **5-minute** reading cadence. **Phase E / F** remain preserved below because they established the current boundary and still matter as evidence, and the Phase F execution trail now includes **F10 / build 170** as the final attach-context implementation point before this strategy change. Deeper attach-context or protocol experiments are no longer the active path unless Phase G later points back there.

### Current behavior summary

- The pre-Phase-G baseline behaved more like a generic reconnect loop than a predicted-reading loop.
- Most historical sessions failed before connect, which strongly suggested the watch was usually trying outside the sensor’s attachable window.
- A smaller set of historical sessions reached connect, but post-connect watch startup still appeared fragile.
- The passive auth/control observer behavior remained directionally good enough to hold steady while timing/runtime was reworked, and Phase G preserves that path while changing scheduler/runtime ownership.

The working model is now explicitly two-layered: most failures appear to be **pre-connect timing** misses, while a smaller number of sessions that do connect still show **post-connect GATT / runtime** fragility.

### Root-cause ranking

1. **Mistimed attach attempts relative to the 5-minute cadence** — **high confidence**. This is supported by the current watch behavior and live evidence showing many attempts that never reach **`didConnect`**.
2. **Runtime lifecycle owned from the wrong boundary** — **high confidence**. The pre-Phase-G baseline tied runtime usage too tightly to connect/startup flow rather than a purposeful observation cycle, which is why Phase G moves that ownership into the cadence scheduler.
3. **No cycle-scoped scheduler existed in the prior baseline** — **high confidence**. Phase G now adds that predicted-next-reading observation loop in code, and field logs must confirm that it actually clusters attempts around the expected cadence window.
4. **Post-connect GATT startup is still fragile on watch** — **medium confidence**. Broader discovery is a promising simplification experiment, but not a proven requirement yet.
5. **The prior timeout model was session-based instead of cycle-based** — **medium-high confidence**. Phase G now replaces that with cycle-relative windows that still need field validation.
6. **Passive-vs-fallback protocol details are probably not the main blocker right now** — **medium-high confidence**. The observer path is much cleaner than before; timing/runtime is the higher-value next lever.

### Proposed scheduling model

Use a cadence-aware loop anchored to the newest trustworthy reading timestamp in this order:

1. latest successful direct-BLE reading timestamp
2. latest saved complication snapshot reading timestamp
3. latest trustworthy relayed phone reading timestamp already applied on watch

If no anchor exists, run one bootstrap cycle immediately on foreground entry. After the bootstrap phase, the first durable anchor becomes either the first successful direct-BLE reading or, if direct BLE has never succeeded, the first trustworthy relayed reading with a real CGM timestamp.

Compute **`nextExpectedReadingDate = anchor + 5 minutes`**, rolling forward in 5-minute increments until it is in the future. Add an explicit anchor log requirement:

- **`g7_ble_cycle_anchor source=direct_ble|snapshot|phone_relay anchor_epoch=... next_expected_epoch=...`**

### Initial timing defaults

Treat these as **initial tunable defaults for field validation**, not proven constants. They should be implemented as local scheduler constants and adjusted after device-log review.

- warm-up target: **`T-30s`**
- active attach window target: **`T-20s`**
- earliest fallback **`0x4E`**: **`T+5s`**
- initial hard-stop target: **`T+25s`**
- initial grace / retry close: **`T+35s`**

### Proposed retry policy

Use a cycle-scoped retry model only. The current generic **7-second** reconnect loop should no longer be the main behavior.

- Allow at most one short same-cycle retry for no-connect misses if the cycle is still inside grace.
- Allow at most one short same-cycle retry for connect-then-GATT-fail cases if enough cycle time remains.
- After a cycle closes, roll to the next predicted reading rather than blind retrying.
- After success, save the reading, advance the anchor, and schedule the next cycle.
- Bootstrap with no anchor should not fall into endless retries.

### Proposed runtime-session model

Move runtime ownership out of **`beginConnectToG7Peripheral(...)`** and into the cadence scheduler.

- **Target:** let one runtime session span multiple reading cycles when watchOS allows it.
- **Required behavior:** still work correctly if runtime must be reacquired more often than desired.
- Treat runtime as available for attach / GATT startup only after **`extendedRuntimeSessionDidStart(...)`** confirms it is active. A created session object or a `start()` request alone is **not** enough to begin a new cycle attempt.
- Keep **`extendedRuntimeSessionWillExpire(...)`** warning-only.
- Treat invalidation as control flow, not transport noise.

Handle invalidation explicitly:

- if runtime invalidates before the active window fully opens and the current cycle is still salvageable, try to reacquire runtime for the same cycle
- if invalidation happens during active attach / GATT / observation, fail that cycle and roll to the next one

### Implementation ownership note

- **`WatchState`** remains the lifecycle entry point, but only as the place that forwards foreground-entry context and the latest phone-provided active sensor identity into the direct-BLE layer.
- **`G7DirectBLEManager`** owns anchor selection, predicted-cycle scheduling, runtime ownership, retry policy, and cycle execution.
- **`applyForegroundActiveEntry(...)`** should become a thin scheduler-entry wrapper: refresh active-sensor context, seed or refresh cadence state from the best available timestamps, and ask the manager to evaluate whether to bootstrap, continue, or reschedule the current cycle. It should no longer be the place that owns the reconnect loop or extended-runtime control flow directly.

### Proposed GATT/BLE updates

#### Must do first

- add cycle-scoped scheduler state
- move runtime acquisition/renewal into scheduler ownership
- replace the generic reconnect loop with cycle-scoped retries
- add cycle IDs / generation guards to all timers and deferred callbacks
- make fallback timing relative to the predicted cycle, not just passive-arm time

#### First GATT simplification experiment after cadence scheduling

Treat this as a hypothesis, not a requirement.

- try **`discoverServices(nil)`**
- try **`discoverCharacteristics(nil, for: dataService)`**

Rationale:

- watch-side post-connect startup is still fragile
- DiaBLE uses broader discovery
- this is the first simplification experiment once cadence-aware cycles are in place

#### Leave unchanged initially

Keep these stable for now:

- passive auth/control observer path
- authenticated-only passive gate
- optional communication notify as non-blocking
- fallback **`0x4E`** existence itself

### Logging / validation plan

Add cycle-oriented logs:

- **`g7_ble_cycle_anchor ...`**
- **`g7_ble_cycle_scheduled ...`**
- **`g7_ble_cycle_started ...`**
- **`g7_ble_cycle_completed ...`**
- **`g7_ble_cycle_missed ...`**
- **`g7_ble_runtime_gate ...`**

Keep existing auth/control/fallback/read logs, but include the cycle ID where practical. The expected successful sequence is:

1. anchor chosen
2. cycle scheduled
3. runtime active before the lead window
4. attach begins inside the lead window
5. **`didConnect`**
6. service discovery
7. characteristic discovery
8. auth notify ready
9. authenticated status observed
10. control notify ready
11. passive observation armed
12. **`0x4E`** received passively or after fallback
13. snapshot saved
14. cycle completed
15. next cycle scheduled from the new reading timestamp

Operational success criterion for the phase:

- Treat Phase G as having moved the boundary once watch attempts cluster near predicted reading windows and at least one cycle reaches **`didConnect`** inside the lead window.

Define failure buckets explicitly:

- **timing miss**
- **runtime miss**
- **GATT miss**
- **observation miss**

### Implementation plan

**G1 — cadence scheduler and runtime ownership**

Add cycle state, anchor selection, and predicted-reading scheduling to the watch direct-BLE manager, seed that scheduler from direct-BLE or trustworthy relay/complication-snapshot timestamps, and move runtime acquisition / renewal into the scheduler. `WatchState` should continue to call **`applyForegroundActiveEntry(...)`**, but in Phase G that method becomes a thin scheduler-entry wrapper rather than the owner of reconnect or runtime flow. Runtime gating in this step should be explicit: the scheduler may request runtime during warm-up, but attach / GATT startup should wait until **`extendedRuntimeSessionDidStart(...)`** confirms the session is active, otherwise the cycle closes as a **runtime miss**. The goal of this step is to prove that watch attempts now cluster around the expected 5-minute reading window instead of blind retrying.

**G2 — cycle-relative timeout model**

Redefine connect, startup, fallback, and terminal read timeouts relative to the predicted cycle, and ensure generation guards prevent stale timers from firing into later cycles. The goal of this step is to produce clean cycle execution and clean miss classification.

**G3 — first GATT simplification experiment**

If cadence-aware cycles now reach connect more reliably, test broader service / characteristic discovery while holding the passive observer path steady. The goal is to determine whether watch-side startup fragility is partly caused by current discovery scope.

**G4 — reassess only after field logs**

Use real device logs from the cadence-aware builds to decide whether deeper protocol or attach-context changes are still warranted. Do not return to broader attach-context experimentation unless the Phase G evidence clearly points back there.

## Build 171 transition summary

Build **171** established that the shipped watch path is now cadence-aware and runtime-gated rather than a blind reconnect loop. The live logs show cycle-anchor, cycle-schedule, cycle-start, runtime-gate, and cycle-miss events, so attach work is now happening inside an explicit predicted-reading loop rather than on a generic retry timer.

The reviewed build-171 window also shows that attach attempts are clustering under the new predicted-cycle machinery and that runtime activation is visibly gating attach work, but the dominant live boundary is still before **`didConnect`**. In the reviewed shipped window, attach attempts still ended at **`awaiting_connect`** with no successful watch-side **`didConnect`**.

That is the justification for the next phase: keep the current Phase G runtime/scheduler basis, but move the active top-level effort to **pre-connect attach reliability**.

### Watch extension build matrix (what each shipped / numbered build contains)

Use this table as the single index for **TestFlight / internal build numbers** vs **initiative steps**. Per-build field evidence (Better Stack) stays in the **Implementation log** and **Phase I** sections; this matrix only lists **what code changes were bundled** as recorded in this document.

| Build(s) | When (doc) | Included changes |
|----------|------------|------------------|
| **163** | Apr 12 | **F1** — connect-boundary instrumentation: **`g7_ble_connect_timeout_armed` / `canceled`**, **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`** (delegate trail); timeout cancel reasons; existing attempt/timeout lines unchanged. |
| **164** | Apr | **F2** — **`CBCentralManager`** delegate **`queue: nil`** (DiaBLE-style); no scan/retrieval logic change in the same step. |
| **165** | Apr | **F3** — scan calls use **`options: nil`** (omit **`CBCentralManagerScanOptionAllowDuplicatesKey`**); FEBC service filter unchanged. |
| **166** | Apr 16 | **F4** — allocate **`CBCentralManager` in `G7DirectBLEManager.init()`**; **`startScanning()`** reuses the instance; restore identifier + prior F1–F3 behavior preserved. |
| **168** | Apr 17 | **F5** — dual-UUID retrieval diagnostics, explicit **`source=`** labels, duplicate-connect suppression within a cycle, expanded pre-connect fields, post-connect callback probes; debug view / chart wiring as shipped with F5. |
| **170** | Apr 18–19 | **F10** — identifier-first retrieval before scan; passive-first observer / lifecycle cleanup; warning-only **`extendedRuntimeSessionWillExpire`**; reconnect after disconnect/fail unless explicit teardown. Last **Phase E/F** attach-context baseline before Phase G. |
| **171** | Apr 19+ | **Phase G** — cadence scheduler, anchor selection, runtime gate, cycle IDs, cycle-relative timeouts, cycle logs (**`g7_ble_cycle_*`**, **`g7_ble_runtime_gate`**). **Phase H1 enabled in binary** — **`registerForConnectionEvents`** + **`connectionEventDidOccur`** + **`g7_ble_connection_event_fired`**. |
| **172–176** | Apr 19–21 | Incremental **Phase H** reliability / parity work between 171 and the Phase I experiment (exact per-build splits not itemized here): includes session teardown / **`cancelPeripheralConnection`** (**build 174** per Phase I notes), **`stopScan()` before `connect()`**, **`bluetooth-central`** **`UIBackgroundModes`**, single **`handleForegroundActiveEntry`** path (**build 175**), and related lifecycle dedup. |
| **177** | 2026-04-22 | **Phase I — `registerForConnectionEvents` removal:** commented out **`registerForConnectionEventsIfNeeded`**, its call sites, and **`connectionEventDidOccur`** (four locations); no other changes. **Field outcome (Better Stack):** negative — **`g7_ble_did_connect`** **0**; **`registerForConnectionEvents`** ruled out as regression cause. Details: **Implementation log — Phase I field evidence**. |
| **178** | 2026-04-22 | **Nil scan experiment:** both **`scanForPeripherals`** call sites use **`withServices: nil`** (FEBC filter preserved as comments); **`registerForConnectionEvents`** remains off from **177**. **Field outcome:** negative — **`g7_ble_did_connect`** **0**; nil scan ruled out. Details: **Implementation log — Phase I field evidence**. |
| **179** | 2026-04-22 | **Restore persist-on-connect-attempt:** after **`central?.connect(...)`** in **`beginConnectToG7Peripheral`**, call **`persistPeripheralIdentifier(..., reason: "connect_attempt")`**; nil scan from **178** retained. **Field outcome:** negative on **`didConnect`** despite retrieval chain seeded; necessary correctness fix, not regression fix. Details: **Implementation log — Phase I field evidence**. |
| **180** | Apr 22 | **Phase I / root cause fix** — **`willRestoreState`** now calls **`central.stopScan()`** + **`cancelPeripheralConnection`** for each restored peripheral before logging; **`restored_peripheral_count=N`** added to log line. Addresses CB state restoration race: prior no-op allowed CB to silently swallow retrieval-path **`connect()`** due to duplicate pending connection from restored scan. |
| **181** | Apr 22 | **Suffix(2) name hygiene + skip `retrieved_identifier` dedup insert — deployed:** updated `doesPeripheralMatchActiveFilter` to exact-or-`suffix(2)` via new `classifyPeripheralAgainstActiveFilter` helper; replaced `didDiscover` inline `name != active` guard with same classifier (`match=exact\|suffix` log); conditioned `attemptedConnectPeripheralIdentifiers.insert` on `source != "retrieved_identifier"` so live scan-path `connect()` is no longer suppressed after stale `rssi=0` retrieval attach. Red-team review: orphan-instance guards on `didConnect`/`didFailToConnect`/`didDisconnect`. |
| **182 (deployed)** | Apr 22 | **G7SensorKit-style per-attempt retry loop — deployed and field-validated (2026-04-23):** (1) 8 s per-attempt timeout replaces 45 s single timeout — on fire: cancel CB, clear peripheral/dedup; retry scan after 2 s if within `hardStopDate`, teardown if past; (2) `didFailToConnect` → retry not teardown (all errors incl. code 11) unless past `hardStopDate`; (3) `stopScan()` removed from `beginConnectToG7Peripheral` (live scan during connect); (4) `attemptedConnectPeripheralIdentifiers` cleared per-attempt (retry model, not single-attempt-per-session); (5) `cycleRelativeDelay` floor 0.1 s → 5.0 s. Bug fixes: `pendingDisconnectReason="per_attempt_timeout_cancel"` pre-set before `cancelPeripheralConnection`; `connectionState == .connecting` guard in timeout handler; generation capture around `await` suspension points; retrieved-identifier dedup insert; `emitStageIfChanged("scanning")` post-timeout. New log events: `g7_ble_per_attempt_timeout`, `g7_ble_scan_retry_scheduled`, `attempt_count=N` on `g7_ble_connect_attempt`. Success signal: multiple `g7_ble_connect_attempt` events ~10 s apart in one `g7_session`. |
| **183 (deployed, live)** | 2026-04-23 | **`WKExtendedRuntimeSession` gate removal** — `startScheduledCycleIfNeeded` / `scheduleRetryWithinCurrentCycle` no longer block scan on `.starting` / `.unavailable`; `armRuntimeActivationDeadlineIfNeeded` timeout log-only. See **Phase I — Build 183**. Prerequisite: build 182 deployed — **met**. |
| **184 (planned)** | — | Re-enable **`registerForConnectionEvents`** + **`connectionEventDidOccur`** (H1) **together** — additive attach path. Prerequisite: build 183 deployed (per **09**) — **met** for binary availability; follow **[09](watch-direct-ble-cgm-09-preconnect-review.md)** before ship. |
| **185 (planned)** | — | **`willRestoreState`** fast-path — attach restored peripherals (**`source=restored_state`**) instead of flushing; explicit **`.connected` vs `.connecting`** handling; **build 183** guards in place. |
| **186 (planned)** | — | Background soak — **`WKExtendedRuntimeSession`** + **`bluetooth-central`**; **`g7_ble_cycle_missed` / consecutive `foreground_unavailable`** style observability per **09** Finding 6.6. |

## Phase H — Pre-connect attach reliability

Phase **H** follows directly from the build-171 result. **Phase G** successfully changed the watch from blind retries to cadence-aware, runtime-gated attempts, but the active live boundary is still before **`didConnect`**. The next active effort should therefore focus on improving attach reliability, not on changing the observer path or treating post-connect GATT/protocol work as the main problem.

Phase H does **not** replace Phase G scheduling/runtime behavior; it uses that behavior as the fixed execution framework while optimizing how attach attempts are chosen and triggered inside the predicted reading window. The active implementation shape for Phase H is a mandatory attach-context alignment pass: OS-level connection-event delivery on watch (**H1**), combined connected-peripheral retrieval before stale remembered identifiers (**H2**), and corrected retrieval-path pre-connect diagnostics (**H3**), with identifier policy as a separate build-level variable rather than mixing it with attach-lane experiments. **H2–H3 are active in the current `Trio` tree; H1 is landed in source but commented out** pending the **Phase I** regression experiment (see **Implementation status** below).

The active purpose of Phase H is:

- improve pre-connect attach success inside the current Phase G cadence/runtime framework
- recover the live-connected peripheral attach path by using OS-delivered connection events and connected-peripheral retrieval before stale remembered identifiers or pure scan timing
- tighten identifier persistence / retrieval policy so stale remembered peripherals do not dominate the attach path
- improve cadence-anchor quality where that materially changes attach timing
- keep this phase primarily **pre-connect**, not a post-connect GATT/protocol phase

Operational success criterion for the phase:

- **When H1 is enabled:** treat Phase H as successful once the **`g7_ble_connection_event_fired`** log line appears consistently in Better Stack alongside watch-side **`g7_ble_did_connect`** events, confirming that **`registerForConnectionEvents`** is delivering OS notifications on watchOS and that attach is occurring on the live-connected peripheral path rather than requiring scan timing.
- **During Phase I (H1 disabled):** connection-event lines will not fire; interim success is defined by **Phase I** — recovery of watch-side **`g7_ble_did_connect`** on scan and/or retrieval paths without connection-event registration, after which H1 can be re-enabled in a separate controlled build.

**Ship-order note (pre-connect review 09, 2026-04-22):** **[watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)** recommends **delegate identity guards + GATT validation before re-enabling H1**. This plan maps that priority to **strict sequential builds:** **182** (retry + validation) **then** **183** (**WKExtendedRuntimeSession** gate removal) **then** **184** (H1) — see **Forward plan — builds 181–186** in the **Implementation log**.

### Implementation status vs `Trio` (static code review, 2026-04-21)

| Item | In current `Trio` watch extension |
|------|-----------------------------------|
| **H2** — Combined **`retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService, G7BLEUUID.advertisement])`**, checked **before** **`retrievePeripherals(withIdentifiers:)`** in **`attemptRetrievedAttachIfAvailable`** | **Active** — `connectedAttachServiceUUIDs` + retrieval order as designed. |
| **H3** — **`preConnectSane`** allows **`peripheral.state == .connected`** for retrieval/event sources via **`isRetrievedAttachSource`** | **Active** — sane for **`retrieved_*`** and **`connection_event`**. |
| **H1** — **`registerForConnectionEvents`**, **`connectionEventDidOccur`**, **`g7_ble_connection_event_fired`** | **Present in file but commented out** (Phase I isolation); not active in compiled behavior until uncommented. |

### Active implementation shape

1. **H1 — Mandatory attach-context foundation plus separate identifier-policy hardening.**
   **Current code:** H1 is **implemented but commented out** for **Phase I** (see **Implementation status** above). **When H1 is enabled in a shipped binary,** the following applies. The H1 identifier policy stays fixed for the whole implementation build. Identifier policy must not vary per cycle. If a different identifier policy is later tested, that is a separate follow-up build, not part of any attach-strategy experiment. Call **`registerForConnectionEvents`** in **`startScanning()`** alongside **`scanForPeripherals`**, using both **`G7BLEUUID.dataService`** and **`G7BLEUUID.advertisement`** service UUIDs. Implement **`centralManager(_:connectionEventDidOccur:for:)`** as a **`CBCentralManagerDelegate`** path and route its attach handling through the existing **`beginConnectToG7Peripheral`** path with the same active-sensor name filter check, **`attemptedConnectPeripheralIdentifiers`** duplicate suppression, cycle-generation guard, and **`scanningStarted`** gate used by every other attach path.

   **Required logs:** emit **`event=g7_ble_connection_event_fired peripheral=... source=connection_event`** when the OS event fires on watchOS so Better Stack can confirm delivery. The event-driven attach path should preserve the existing **`source=`** logging model on downstream pre-connect and connect-attempt lines.
2. **H2 — Connected-peripheral retrieval alignment and priority fix.**
   Replace the two separate **`retrieveConnectedPeripherals`** calls with one combined query: **`central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService, G7BLEUUID.advertisement])`**. This matches the known-working **`G7BluetoothManager.swift`** pattern and better reflects how CoreBluetooth caches connected peripherals regardless of which service UUID indexed them. In **`attemptRetrievedAttachIfAvailable`**, check the combined **`retrieveConnectedPeripherals`** result before **`retrievePeripherals(withIdentifiers:)`**. A peripheral returned by **`retrieveConnectedPeripherals`** is already live in the system and is the better eavesdrop target; a peripheral returned only by identifier retrieval may still be disconnected and waiting for advertisement.
3. **H3 — Pre-connect diagnostic correction and fallback attach-strategy experiment.**
   Fix the pre-connect diagnostic so retrieval-derived attach paths are not mislabeled as insane. For retrieval-derived attach sources such as the combined connected-peripheral path (**`retrieved_connected`**) and **`connection_event`**, treat **`peripheral.state == .connected`** as sane in **`preConnectSane`** so the most likely successful attach path no longer pollutes log analysis. Keep explicit **`source=`** attribution for **`scan`**, **`retrieved_identifier`**, **`retrieved_connected`**, and **`connection_event`** so Better Stack can still distinguish transport/attach attribution. The earlier round-robin attach-strategy experiment (**`identifierFirst`** vs **`scanFirst`** vs **`dualLane`**) is preserved only as a fallback diagnostic if the H1–H3 attach-context fixes still do not produce recurring **`didConnect`** events. If that fallback is needed later, keep identifier policy fixed across the build and use the existing cycle-frozen **`attachExperimentIndex`** model rather than recomputing strategy mid-cycle.

   **Fallback experiment logs and evaluation:** if the round-robin experiment is later promoted, emit **`g7_ble_attach_strategy strategy=... selection_source=round_robin experiment_index=...`**, carry **`strategy=`** on cycle-start, connect-attempt, and same-cycle retry logs, and compare **`connect_attempt`**, **`didConnect`**, **`session_outcome final_stage`**, miss buckets, and timing by strategy while continuing to treat **`source`** as the lower-level transport attribution.
4. **H4 — Conditional later Phase H follow-ons remain unchanged in spirit.**
   Anchor-quality changes remain conditional only if the mandatory connection-event and retrieval-priority fixes still do not move the boundary and timing evidence suggests the attach window is offset from real cadence. PacketLogger / raw capture and later post-connect follow-ons remain conditional only if the attach failure still cannot be explained after H1–H3. Phase H must not expand into runtime redesign, GATT widening, or payload redesign during this attach-context pass.

---

## Phase I — G7 Direct BLE — `didConnect` Regression: Build 177 Summary for Agent Peer Review

**Implementation status:** **Implemented in code** on the watch extension (`Trio` — `G7DirectBLEManager.swift`): **`registerForConnectionEvents`** registration and **`centralManager(_:connectionEventDidOccur:for:)`** are **commented out** (equivalent to the “remove four locations” Build 177 spec). **Builds 177, 178, and 179** are **deployed** and **field-reviewed** (Better Stack, 2026-04-22); all three outcomes are **negative** — watch-side **`g7_ble_did_connect`** remains **0**. **Build 180** is **deployed** with the **`willRestoreState`** CB restoration flush (**`stopScan()`** + **`cancelPeripheralConnection`** per restored peripheral + **`restored_peripheral_count`** logging). Static analysis (**`watch-direct-ble-cgm-08-build-179-analysis.md`**, **`watch-direct-ble-cgm-09-preconnect-review.md`**) documents **two complementary root causes**: restore-path duplicate pending connection (build **180**) and **exact-name filtering** split across **`doesPeripheralMatchActiveFilter`** (retrieval paths) and a **`didDiscover`** inline compare (scan path) — **build 181** must update **both**. See **Implementation log (execution) — Phase I field evidence — builds 177, 178, 179** plus **Phase I — Build 180**, **Two-bug analysis**, and **Forward plan — builds 181–186**.

---

### Goal

Trio Watch App needs to eavesdrop on the Dexcom G7 CGM sensor's BLE connection, receiving glucose readings directly on the watch every 5 minutes. This is the same pattern used successfully by DiaBLE watch app and by both Trio and DiaBLE phone apps.

---

### Device & App Setup

**Phone (all working):**
- Official Dexcom G7 app — primary BLE connection to sensor
- Trio iPhone app — eavesdrops via G7SensorKit ✓
- DiaBLE iPhone app — eavesdrops ✓

**Watch:**
- Official Dexcom G7 watch app — independent BLE connection to sensor (watch has its own Bluetooth radio, fully separate from the phone)
- Trio Watch App — eavesdrop attempt ✗ currently broken
- DiaBLE watch app — eavesdrop ✓ 100% reliable (reference implementation)

The G7 sensor supports multiple simultaneous BLE connections. Eavesdropping does not require winning a connection race — DiaBLE watch successfully eavesdrops alongside the official watch app's active connection.

---

### Current Symptom (Builds 171–176)

`centralManager(_:didConnect:)` has not fired once. Every cycle:

```
g7_ble_scan_started
g7_ble_peripheral_discovered  DXCM08  rssi=-78 to -86  is_connectable=true
g7_ble_pre_connect             peripheral_state=0  central_state=5 (poweredOn)
g7_ble_connect_timeout_armed   timeout_s=22
g7_ble_connect_attempt         source=scan
g7_ble_connection_event_fired  ← official Dexcom watch app connecting
g7_ble_timeout                 stage=awaiting_connect  [22 seconds later]
```

All three CB connection callbacks confirmed silent across builds 171–176:
- `g7_ble_did_connect` — 0 occurrences
- `g7_ble_did_fail_to_connect` — 0 occurrences
- `g7_ble_did_disconnect` (CB-originated) — 0 occurrences

Confirmed with app continuously foreground (106-second active window spanning entire connect window), battery at 90%, DiaBLE watch killed. Background/runtime is ruled out as a cause.

---

### Build History and the Regression Boundary

| Build | Date | Key Change | `didConnect` |
|-------|------|-----------|-------------|
| 163–165 | Apr 12–16 | F1–F3: logging, queue, scan options | 0 |
| **166** | **Apr 16** | **F4: CBCentralManager allocated in `G7DirectBLEManager.init()` (early allocation)** | **1 — retrieval path, sensor `DXCMKo`** |
| 168 | Apr 17 | F5: instrumentation, dual-UUID retrieval diagnostics | 0 |
| **170** | **Apr 18–19** | **F10: identifier-first retrieval + passive-path cleanup** | **Multiple on DXCM08** |
| **171** | **Apr 19+** | **Phase G (cadence scheduling) + Phase H1 (`registerForConnectionEvents` added)** | **0 — never again** |
| 172–176 | Apr 19–21 | Phase H fixes: teardown, stopScan, bluetooth-central, lifecycle dedup | 0 |

Build 170 → 171 is the regression boundary. **Caveat:** build 171 introduced two major changes simultaneously — Phase G and `registerForConnectionEvents`. The regression cannot be attributed to either alone from data. Both remain suspects, but one is much more likely (see below).

---

### Attach Source Analysis — Build 170

From BetterStack cold storage (April 18–19):

**Scan-path sessions:** all timed out. Scan-start to discovery latency was ~40 seconds. Every scan attempt failed before `didConnect`.

**Retrieval-path sessions (after identifier persisted from first connect attempt):**
```
session 8821BB23: source=retrieved_identifier, rssi=0 → g7_ble_did_connect (ms_since_discover=13)
subsequent sessions: source=retrieved_identifier, rssi=0, ms_since_discover=5–80ms → didConnect
```

**Key finding: build 170 never proved the scan path works.** F10 persisted the peripheral identifier on connect attempt (not on `didConnect`), enabling instant cache-based retrieval in subsequent cycles. All `didConnect` events came from the retrieval path, not scan.

**Since build 171, the system has been operating in a scan-only regime.** Because `didConnect` has never fired, the identifier was never persisted, retrieval always returns empty (`stored_id_short=none` in every cycle), and every attempt depends on the scan path — which was already failing even in build 170.

---

### Timing Analysis — Scan Discovery Is Faster Now, But Attach Timing Remains Uncertain

**Build 170 scan-to-discovery latency:** ~40 seconds (confirmed from logs)

**Current builds scan-to-discovery latency:** 4–23 seconds

Scan discovery is faster in current builds than in build 170. Phase G's cadence scheduler is working correctly — it's timing scans tighter to the reading window. The scan-latency variant of the timing regression hypothesis is **narrowed** by this.

However, scan discovery latency is not the same as attach timing. Build 170's successes came from the retrieval path, which connected in milliseconds from a CB-cached peripheral state. The current scan path connects to a freshly discovered advertisement. Whether the difference in peripheral state at `connect()` time — cached vs. advertisement-discovered — affects CB's ability to complete the connection on watchOS remains unknown. Timing is narrowed as a standalone explanation but cannot be fully dismissed.

---

### Primary Suspect: `registerForConnectionEvents`

Added as Phase H item H1 in build 171. DiaBLE watch — which gets `didConnect` reliably — does not call it. `didConnect` occurred in builds 166 and 170 without it. `didConnect` has not fired in any build where it is present.

This makes `registerForConnectionEvents` the **primary causal candidate** for the regression, though it is not yet confirmed — Phase G changes cannot be fully decoupled from the H1 introduction without an isolated build.

---

### Build 177 Change

**One change only: remove `registerForConnectionEvents` and its handler.**

Four locations in `G7DirectBLEManager.swift` (line numbers from **2026-04-21** `Trio` tree — adjust if the file shifts):

1. **`registerForConnectionEventsIfNeeded(on:)`** — commented out / removed
2. **~502** — call inside **`startScanning()`** — commented out
3. **~2269** — call inside **`centralManagerDidUpdateState`** — commented out
4. **`connectionEventDidOccur` delegate** — commented out (**~2288+**)

`connectionEventDidOccur` is only invoked when `registerForConnectionEvents` is registered — both must go together. The connection-event attach path is worth restoring later, but only after `didConnect` is working again on the scan path.

**Do not bundle any other changes.** Single variable, single build.

**Code status:** The current watch extension implements this as **commented-out blocks** (preserving the code for a later re-enable build) rather than deleting the symbols outright.

---

### Already Verified — Do Not Change

- **Early `CBCentralManager` allocation in `init()` at line 383** — confirmed present. F4 change that produced the first `didConnect` in build 166. Critical to preserve.
- **`stopScan()` before `connect()`** — restored in build 175, matches DiaBLE.
- **`cancelPeripheralConnection` in `teardownSession`** — added in build 174.
- **`bluetooth-central` in `UIBackgroundModes`** — added in build 175.
- **Single `handleForegroundActiveEntry` call site** — fixed in build 175.

---

### Success Metric

After deploy, query BetterStack:

```sql
SELECT dt, JSONExtract(raw, 'message', 'Nullable(String)') as message
FROM remote(t491594_trio_logs)
WHERE dt > now() - INTERVAL 2 HOUR
AND JSONExtract(raw, 'platform', 'Nullable(String)') = 'watchos'
AND JSONExtract(raw, 'message', 'Nullable(String)') LIKE '%g7_ble_did_connect%'
ORDER BY dt ASC
```

Also check attach source (`source=scan` vs `source=retrieved_identifier`) and GATT progression (`discovering_services` → `discovering_characteristics` → `authenticating`).

**Pass:** `g7_ble_did_connect` appears → `registerForConnectionEvents` strongly implicated as primary causal factor. Given build 170's pattern, the first `didConnect` should come from scan, persist the identifier, and retrieval-path connects should follow in subsequent cycles.

---

### If Build 177 Fails

**Primary remaining suspect — scan-path attach reliability (never proven to work).** The scan path has never successfully produced `didConnect` in any build. If removing `registerForConnectionEvents` doesn't restore `didConnect`, the issue may be structural to the scan attach path itself, potentially related to CB peripheral state at connect time (freshly-discovered advertisement vs. cache).

**Next test:** switch to `scanForPeripherals(withServices: nil)` to match DiaBLE's exact scan behavior. One-line change, single build.

---

### BetterStack Reference

- Source ID: `1659391`, table: `t491594.trio`
- watchOS filter: `JSONExtract(raw, 'platform', 'Nullable(String)') = 'watchos'`
- Hot storage (~30 min): `remote(t491594_trio_logs)`
- Cold storage: `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`
- Key events: `g7_ble_did_connect`, `g7_ble_connect_attempt`, `g7_ble_timeout stage=awaiting_connect`, `g7_ble_stage`, `g7_ble_did_fail_to_connect`

### Ranked candidate next steps

1. **Re-enable watch-side `registerForConnectionEvents` (Phase H H1) after Phase I evidence.**
   Rationale: **`G7BluetoothManager.swift`** uses connection-event registration as part of the normal attach flow. **While Phase I is active, H1 stays commented out** so logs can prove whether **`didConnect`** returns without OS connection events. If **`didConnect`** stabilizes without H1, reintroduce H1 in a **single-variable** build to recover **`g7_ble_connection_event_fired`** and live-connected attach without conflating with the regression under test.
2. **Align connected-peripheral retrieval with the G7SensorKit pattern and prefer it before stale remembered identifiers.**
   Rationale: a single combined **`retrieveConnectedPeripherals(withServices: [dataService, advertisement])`** query better matches the known-working path, and a live connected peripheral is a better eavesdrop target than a disconnected peripheral returned only from identifier retrieval.
3. **Fix pre-connect diagnostics for connected retrieval paths.**
   Rationale: retrieval-derived attach paths currently look artificially unhealthy if **`peripheral.state == .connected`** is still logged as not sane. Correcting that diagnostic is necessary so Better Stack can distinguish a genuinely bad attach context from the most likely successful one.
4. **Tighten identifier persistence / retrieval policy.**
   Rationale: build **171** attempts were all **`source=retrieved_identifier`** yet still all timed out at **`awaiting_connect`**; the current identifier persistence/retrieval policy may therefore be too permissive or stale-biased for the current attach boundary and should be re-evaluated as a separate build-level variable rather than mixed into per-cycle attach-strategy changes.
5. **Keep retrieved-vs-scan source-split analysis as a first-class evaluation metric.**
   Rationale: this was already informative across builds **168**, **170**, and **171**, and Phase H still needs comparison output grouped by actual attach source so the connection-event and connected-retrieval paths can be evaluated independently from later fallback strategy experiments.
6. **Use the round-robin attach-strategy experiment only as a fallback diagnostic if H1–H4 do not move the boundary.**
   Rationale: once OS-delivered connection events and live connected-peripheral retrieval are in place, strategy ordering becomes secondary. Preserve the round-robin comparison as a disciplined fallback, not as the primary next build.
7. **Tighten Phase G runtime/foreground gating behavior where it affects attach timing.**
   Rationale: runtime activation is now visibly gating attach work in live logs, so Phase H should keep validating that foreground/runtime policy is helping attach timing rather than obscuring it.
8. **Improve cadence-anchor quality, especially by favoring trustworthy phone-confirmed timing when newer than snapshot timing.**
   Rationale: build **171** anchored heavily from **`snapshot`**; newer trustworthy phone-confirmed reading timing may improve predicted attach alignment.
9. **Use PacketLogger / raw Bluetooth capture only if current attach-context experiments still leave the connect failure unexplained.**
   Rationale: raw capture remains valuable, but only as a conditional escalation after the current attach-lane / identifier-policy experiments.
10. **Only after `didConnect` becomes occasional again, run Phase G’s deferred G3 service/characteristic discovery widening.**
   Rationale: broader **`discoverServices(nil)`** / **`discoverCharacteristics(nil, for:)`** is still a valid experiment, but it is downstream of the current pre-connect boundary.
11. **Only after connect becomes meaningfully reliable, consider more G7SensorKit-style post-connect command/condition orchestration.**
   Rationale: deeper peripheral-manager orchestration is a plausible post-connect hardening move, but it should not displace the current pre-connect priority.

## Deferred candidates / future experiments

These remain traceable because they may become valuable later, but they are **not** the active top-level implementation target while **Phase H** is focused on pre-connect attach reliability. These are not part of the current mandatory attach-context fix set.

- **Single-build round-robin attach-strategy experiment (`identifierFirst` / `scanFirst` / `dualLane`).**
  Conditional follow-on only if the mandatory connection-event and connected-retrieval fixes still do not produce recurring **`didConnect`** events; preserve the existing cycle-frozen **`attachExperimentIndex`** model if this fallback is later promoted.

- **Broader scan filtering / nil-scan experiments during attach windows.**
  Conditional follow-on if Phase H source-split evidence says the current FEBC-focused scan policy is materially constraining attach.
- **PacketLogger / raw Bluetooth capture escalation.**
  Conditional follow-on if current attach-lane and identifier-policy experiments still do not explain where the connect failure dies.
- **`discoverServices(nil)` / `discoverCharacteristics(nil, for:)`.**
  Conditional follow-on once connect becomes occasional again; this remains the deferred **G3** GATT-scope experiment, not the active pre-connect phase.
- **Deeper G7SensorKit-style peripheral-manager / command model.**
  Conditional follow-on after connect becomes meaningfully reliable enough that post-connect sequencing, not attach itself, is the dominant remaining problem.
- **Stronger phone-to-watch cadence-anchor enrichment.**
  Conditional follow-on if current Phase H anchor-quality work shows that the watch needs more explicit phone-provided cadence context than active sensor name plus the normal watch-state payload.

> Bridge note: **Phase H** is now the active plan. **Phase G** remains the implemented current watch behavior and the basis for the runtime/scheduler model. The attach-context and observer-alignment sections below remain preserved historical context unless **Phase H** explicitly points back to them.

## Prerequisites

| Field | Record |
|-------|--------|
| **Docs worktree** | `Trio-dev` — `docs/in-progress/watch-direct-ble-cgm/` |
| **Code worktree** | **`Trio`** sibling worktree (Swift sources not in `Trio-dev`) |
| **Branch** | `feature/watch-direct-ble-cgm` (expected) |
| **Process** | `docs/process/feature-branch-workflow-optimization.md` — implement on feature branch; publish via `generate-patch.sh` when ready; **do not** hand-edit `patches/*.patch` |

---

## Scope

> Historical bridge note: the sections below preserve the earlier observer-alignment and attach-context implementation / investigation record that produced the current **build-170 passive-first baseline**. Unless **Phase H** above explicitly points back to a section below, treat that material as historical context rather than the active top-level implementation target.

The bullets below remain useful baseline context, but they do not override the active **Phase H** plan above.

- Define the **watch direct BLE** mode as **observer-only**.
- Require the phone-provided active sensor identity / name filter for watch direct BLE attach; do not fall back to arbitrary Dexcom peripherals.
- Add **`G7DirectBLEManager`** to the **Trio Watch App Extension** target (Swift source under `Trio Watch App Extension/`).
- Historical build-170 baseline only: the observer-alignment cycle kept the existing **watch foreground entry + extended-runtime continuation** model in **`WatchState`** and avoided a phone-path redesign. **Do not implement new work against that model.** **Phase G** supersedes it by moving runtime ownership and cycle control into the cadence scheduler.
- Integrate **`TrioComplicationDataStore`** + **`WatchLogger`** per design.
- **Phone → watch active G7 Bluetooth name (v1.19):** one **additive** **`WatchMessageKeys.activeG7PeripheralName`** field in the nested **`watchState`** payload (iPhone: **`G7CGMManager.sensorName`** via **`FetchGlucoseManager`** in **`AppleWatchManager.sendDataToWatch`**; included in complication **`userInfo`** / **`applicationContext`** allowlist; watch: **`applyPhoneActiveG7PeripheralNameIfPresent`**, then **`g7DirectBLEManager.activePeripheralName`** before **`startScanning()`**). **Not** App Group–backed (per-device stores do not sync).

## Out of scope (v1.0)

- Full Dexcom J-PAKE client or bonding UI.
- Background BLE scanning or `BGTask` BLE refresh.
- Converting watch direct BLE into an "active pairing mode" separate from observer mode.
- Broad redesign of WatchConnectivity message shapes beyond the **additive** **`active_g7_peripheral_name`** field (see **Scope**).
- Redesigning the existing **phone-relay / WatchConnectivity** watch path; that remains a separate non-direct-BLE mode.
- **`ENABLE_G7_DIRECT_BLE`** (or similar) compile flags in source or sync config for this v1.0 track.

## Dependencies

- Correct **target membership** for new Swift files (human/Xcode canonical workflow — **`AGENTS.md`** forbids agent-driven `project.pbxproj` edits and `sync_project_files.rb`).
- Optional: DiaBLE / public UUID references for G7 — cite in code comments only; design doc stays product-level.

## Historical process gate (observer-alignment cycle)

This gate governed the completed observer-alignment delta that established the current passive-first baseline. It is preserved for provenance and does **not** replace **Phase H** as the current next implementation target.

1. Update the **Trio-dev** design / plan / instrumentation docs first.
2. Stop after the docs update and wait for **explicit approval** before changing any Trio watch code.
3. When approval is given, implement only the **minimum watch-only direct-BLE observer delta** described below.

## Historical observer-alignment delta record (2026-04-13)

This section records the previously approved / implemented observer-alignment delta that moved the watch path to the current passive-first **build-170** baseline. Preserve it as implementation history unless **Phase H** explicitly points back to a detail here.

Primary references for that historical doc cycle:

- `DiaBLE/DiaBLE/Dexcom.swift`
- `DiaBLE/DiaBLE/DexcomG7.swift`
- `DiaBLE/DiaBLE/BluetoothDelegate.swift`
- `Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-04-diaBLE-logs.md`

Current Trio watch divergence to correct:

1. `G7DirectBLEManager` still writes auth-init (`0x01 0x00`) via `sendAuthRequest()` after auth notifications turn on, which makes the watch initiate auth traffic instead of passively observing the Dexcom app-owned session.
2. The watch path does not currently discover / track the `J-PAKE` characteristic, so it cannot explicitly prove the observer skip.
3. `handleAuthenticationNotification(_:)` only checks `authenticated` from `0x05`; it does not require `bonded == true`.
4. Trio still treats `backfill` as a required startup / timeout dependency even though the proven DiaBLE observer sequence only needs auth notify, `0x05`, control notify, and `0x4E`.

## Minimum code-change target (historical approved / implemented delta)

This section documents the completed observer-alignment delta that produced the current passive-first baseline. It is no longer the top-level next implementation target; **Phase H** above is, while **Phase G** remains the implemented current scheduler/runtime basis.

Observer mode is the **only** watch direct BLE mode in this implementation. Do **not** add a watch-side mode switch or alternate “active pairing” path inside the BLE manager for this delta.

1. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Discover `authentication`, `control`, `backfill`, and `J-PAKE`; require only `authentication` and `control` for the initial observer path. `J-PAKE` is discovered only so the watch can log the observer skip; it must not be subscribed/enabled in observer mode.
2. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Remove the auth-init write path (`sendAuthRequest()`, `g7_ble_auth_request_sent`, auth write success/error handling tied to that write). In observer mode the watch must not send `0x01 0x00`; after auth notify is enabled it waits passively for owner-driven `0x03` / `0x05`.
3. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Parse `0x05` as `authenticated` **and** `bonded`; use `authenticated == true` as the passive observer gate and keep the bonded bit for logging / debug verification.
4. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Explicitly log `J-PAKE skipped` in observer mode and do not enable J-PAKE notifications.
5. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Enable **control** notifications once the passive authenticated gate is satisfied; `backfill` remains optional follow-up work and must not gate `awaiting_gatt_setup` cancellation.
6. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Keep the existing EGV parse / complication save path, but add proof logs for auth notify, J-PAKE skip, `0x03`, `0x05`, control notify, passive observation armed, fallback `0x4E` if used, `0x4E` receive, and persistence.
7. `Trio Watch App Extension/G7DirectBLEManager.swift`
   Add optional passive `communication` handling when authenticated (`notify`) to mirror DiaBLE passive mode without making communication readiness a hard requirement.
8. `WatchState`, `AppleWatchManager`, and phone-side code
   No redesign is expected. Existing active-sensor-name bridging stays as-is unless a shared constant or parser detail forces a tiny additive change.

Direct BLE attach gating for this delta:

- Only attempt connect / attach when the phone-provided active sensor identity / name filter is present and matches the discovered peripheral.
- Do **not** connect to a random `DXCM*` peripheral when the filter is absent.
- If the filter is absent, remain in non-connected observer readiness and rely on the separate phone-relay path if that is the only currently available watch data path.

This is intentionally a **tight watch-only delta**. No broad direct-BLE redesign, no phone-path redesign, and no change to the separate phone-relay / WatchConnectivity mode are planned in the approval-gated implementation step.

Passive observation / fallback cadence for this delta:

- Mainline behavior is passive observation after auth + control readiness.
- On reconnect, re-arm passive observation rather than immediately sending `0x4E`.
- A bounded fallback `0x4E` is allowed only if passive observation fails to produce expected glucose traffic within the timeout window.
- Do **not** add a speculative repeating timer or alternate watch-side polling loop in this approval-gated delta. Sustained in-session multi-reading behavior should follow proven DiaBLE / runtime behavior and be validated in soak.

## Expected Runtime Sequence (Observer Mode)

1. Scan / find the active `DXCM*` peripheral via `FEBC`
2. Connect
3. Discover the G7 data service and `authentication`, `control`, `backfill`, `J-PAKE`
4. Enable auth notifications
5. Log `J-PAKE skipped` and remain out of the pairing flow without subscribing/enabling J-PAKE
6. Receive `0x03`
7. Receive `0x05` and confirm `authenticated=true` while logging `bonded`
8. Enable control notifications and arm passive observation
9. Optionally touch `communication` (`notify` / `read`) when authenticated if present
10. Receive / parse `0x4E`, or send fallback `0x4E` only if passive observation stalls
11. Persist / surface the glucose snapshot for the watch complication
12. Disconnect / reconnect as needed while the Dexcom app remains the session owner

---

## Sequencing + ship boundaries

| Phase | Name | Current role | Ship boundary |
|-------|------|--------------|---------------|
| A | Lifecycle wiring in `WatchState` | Historical foundation | Yes (no-op if manager not invoked) |
| B | `G7DirectBLEManager` CoreBluetooth + parse + persist | Historical foundation | Yes (device-tested) |
| C | Observability + soak validation | Historical foundation | Yes (evidence in logs) |
| D | Hardening (optional follow-up) | Historical follow-up bucket | Yes |
| E | Pre-connect parity investigation (build 162) | Historical phase | Yes (additive instrumentation + one CBCentralManager option) |
| F | Attach-context / boundary movement investigation (builds 163-170) | Historical phase; completed through the current **build-170 passive-first baseline** | Yes (one-change-per-build sequence) |
| G | Cadence-aware watch G7 observation loop | Historical shipped/current behavior baseline; established the runtime-gated cadence framework in **build 171** | Yes (shipped; remains current behavior basis) |
| H | Pre-connect attach reliability | **Active next implementation target** (with **Phase I** code landed: **H1** connection-event path **off** pending field results) | **Shipped in code:** combined `retrieveConnectedPeripherals` + connected-before-identifier order + `preConnectSane` for retrieval sources (**H2/H3** active). **`registerForConnectionEvents`** + delegate (**H1**) implemented but **commented out** per Phase I until Better Stack proves `didConnect` without them. **Success:** Phase I interim = `g7_ble_did_connect` without H1; full Phase H (H1 on) = `g7_ble_connection_event_fired` + `g7_ble_did_connect` in Better Stack. Round-robin attach-strategy remains fallback-only. |

---

## Shared conventions

- Observability: `docs/process/standards-observability.md` — new logs use `event=g7_ble_*` (design).
- Logging: **no secrets**; avoid PHI in fixtures; Better Stack queries per `docs/process/betterstack-guide.md`.
- **`G7DirectBLEManager`:** Private **`logG7Ble(_:function:file:line:)`** appends **`g7_session=`** when applicable and forwards **`#fileID` / `#line` / `#function`** into **`WatchLogger.shared.log`** so phone-side / Better Stack fields reflect the **call site** of **`logG7Ble`**, not the helper. The unused **`logG7`** wrapper was removed. See [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md) (**Log line attribution**).

---

## Phase A: Lifecycle wiring (`WatchState`)

**Ship gate:** Yes — the **`G7DirectBLEManager`** instance is created eagerly, and **`CBCentralManager`** is allocated in **`G7DirectBLEManager.init()`** (**F4 / build 166** parity with DiaBLE/phone lifecycle). **`startScanning()`** starts scanning and attach flow using that existing central; it does **not** defer first central allocation to the first scan in the normal path.

### Task A1 — Manager property + foreground entry

- **Files:** `Trio Watch App Extension/WatchState.swift`
- **Change:** Add **`@ObservationIgnored private let g7DirectBLEManager = G7DirectBLEManager()`** (shipped pattern — **`lazy`** is incompatible with **`@Observable`** macro expansion here). **`CBCentralManager`** is allocated in **`G7DirectBLEManager.init()`** (**F4**); scanning and connect attempts still begin from **`startScanning()`** / foreground entry, not at **`init`** time.
- **Steps:** Place near other extension-owned subsystems; ensure **main-thread** context matches existing `assert(Thread.isMainThread, ...)` for lifecycle methods.
- **Acceptance:** `handleForegroundActiveEntry()` ends with `g7DirectBLEManager.applyForegroundActiveEntry(activePeripheralName:)` after existing startup `Task` work is **scheduled** (ordering preserved vs `WatchErrorReporter` startup). **`applyForegroundActiveEntry`** calls **`startScanning()`** only when a full restart is needed (not when a **`.scanning`…`.connected`** session is already in progress). **`CBCentralManager`** lifetime follows **F4**: created in **`G7DirectBLEManager.init()`**, not lazily on first **`startScanning()`** alone.
- **Observability:** None required beyond manager internals; lifecycle correlation logs (**`g7_ble_lifecycle`**) per **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** when implementing **Task C3**.

### Task A2 — Inactive / background correlation (no BLE stop)

- **Files:** `WatchState.swift`, `TrioWatchApp.swift`, `ExtensionDelegate.swift`
- **Change:** `handleForegroundInactiveOrBackground(scenePhase:)` — **`ScenePhase.inactive`** / **`.background`** emit **`g7_ble_lifecycle`** correlation (**`ble_continues=true`**, **`active_window_*`** on inactive) and run existing **non-BLE** startup bookkeeping (**`startupIsForegroundActive`**, deferred startup cancellation, etc.). **Do not** call **`g7DirectBLEManager.stop()`** — direct BLE continues until **OS extended-runtime expiry / invalidation** or **`teardownSession`**. **`ScenePhase.background`** emits **`phase=background`** when a prior inactive pass stashed **`g7_session`**. **Single driver:** invoke **only** from **`TrioWatchApp`** **`.onChange(of: scenePhase)`** (do **not** call from **`ExtensionDelegate.applicationWillResignActive`** — avoids duplicate OS callbacks; **`ExtensionDelegate`** may keep **`watch_app_resigning_active`** for transport diagnostics).
- **Acceptance:** No BLE stop on leave-active; no spurious **`phase=background`** on inactive-only transitions; one canonical entry path for **`g7_ble_lifecycle`** leave-active lines per report **03** **v1.15**.

---

## Phase B: `G7DirectBLEManager`

**Ship gate:** Yes after on-device smoke test.

### Task B1 — Central + scan + connect

- **Files:** `Trio Watch App Extension/G7DirectBLEManager.swift`
- **Change:** `CBCentralManager` with delegate queue **`nil`** (**F2** parity — not **`.main`**); scan `FEBC`; connect only the phone-filtered active sensor; discover the data service and the `communication`, `authentication`, `control`, `backfill`, and `J-PAKE` characteristics needed for observer-mode logging and control handoff. If no phone-provided active sensor identity is available, do not connect to an arbitrary Dexcom peripheral; emit an explicit blocked line such as `g7_ble_attach_blocked reason=missing_active_sensor_filter` instead of relying only on the absence of a connection.
- **Acceptance:** Logs `g7_ble_scan_started`, `g7_ble_peripheral_discovered`, `g7_ble_connected` on the matched-sensor success path, or emits the explicit missing-filter blocked event and remains in filtered / skipped state without attaching to a random Dexcom peripheral.

### Task B2 — Auth eavesdrop + subscribe

- **Change:** Enable notify on **authentication** only; **do not** send auth-init / app-key / J-PAKE ownership packets from the watch observer path. Explicitly log `J-PAKE skipped` when the characteristic is discovered. On `0x03`, log challenge traffic. On `0x05`, parse and log `authenticated` and `bonded`, proceed when `authenticated == true`, and keep bonded as a diagnostic bit instead of a hard passive gate.
- **Acceptance:** Logs show `auth notify enabled`, `J-PAKE skipped`, `0x03 received`, `0x05 authenticated=<bool> bonded=<bool>`, and `g7_ble_passive_gate_satisfied gate=authenticated_only` on the success path. If `authenticated` is false, emit `g7_ble_passive_gate_blocked ...` and do not proceed to control. No `g7_ble_auth_request_sent` remains in observer mode.

### Task B3 — EGV request + parse + save

- **Change:** When **control** notifications are ready after the passive authenticated gate, arm passive observation instead of immediately writing `0x4E`. If the watch intentionally withholds progress because the passive gate is not satisfied or control is not ready, emit `g7_ble_passive_observation_blocked reason=...`. If passive observation stalls, allow a clearly logged fallback `0x4E` write on **control**. Parse EGV (`0x4E` opcode), compute `readingDate`, build `TrioComplicationSnapshot`, call `TrioComplicationDataStore.shared.save(..., triggerReload: true, minInterval: 5)` **synchronously on the main queue** (same as CB delegate).
- **Acceptance:** `g7_ble_control_notify_enabled`, `g7_ble_passive_observation_armed`, optional `g7_ble_egv_fallback_sent`, `g7_ble_egv_received`, and `g7_ble_snapshot_saved` logs appear in order on the happy path; blocked prerequisite cases emit an explicit `g7_ble_passive_observation_blocked ...` line instead of silently stalling.

### Task B4 — Teardown + errors

- **Change:** **`stop()`** (explicit), **`teardownSession`**, and **`WKExtendedRuntimeSessionDelegate`** expiry/invalidation paths stop scan, cancel connection, reset session state as applicable; update timeout cancellation so observer startup is satisfied by auth notify + `0x05 authenticated=true` + control notify (not by backfill readiness). That observer-specific startup-ready rule should be treated as the direct-BLE happy-path threshold for timeout purposes. Log disconnect/errors with structured fields.
- **Acceptance:** Graceful teardown on OS extended-runtime end and error paths; no leaked assertions on unhappy paths.

---

## Phase C: Validation

### Task C1 — Device soak

- **Acceptance:** Capture Better Stack or console excerpt showing end-to-end `g7_ble_*` sequence; note build identifier.

### Task C1a — Observer proof checklist

- **Positive proof:** `g7_ble_auth_notify_enabled`, `g7_ble_jpake_skipped`, `g7_ble_auth_challenge_received`, `g7_ble_status_reply authenticated=<bool> bonded=<bool>`, `g7_ble_passive_gate_satisfied gate=authenticated_only`, `g7_ble_control_notify_enabled`, `g7_ble_passive_observation_armed`, optional `g7_ble_egv_fallback_sent opcode=0x4E`, `g7_ble_egv_received`, `g7_ble_snapshot_saved`
- **Negative proof:** No `g7_ble_auth_request_sent` and no J-PAKE ownership write from the watch observer path
- **Scope guard:** No unintended phone-path changes beyond already-existing active-sensor-name support

### Task C1b — Lightweight watch debug view

- **Change:** Add a small **Direct BLE / G7 observer** section to the **existing watch debug view**. It should show:
  `Mode: Direct BLE Observer`, expected session owner (`Dexcom G7 app`), whether the watch is using **phone relay**, the current connection stage, last peripheral name / RSSI / discover time, whether the phone-provided active sensor identity filter is armed / applied, auth notify enabled, J-PAKE skipped, last auth opcode seen, authenticated, bonded, control notify enabled, last EGV received time, last glucose value, last reading age, last sequence number, last snapshot save result / time, current `g7_session`, last disconnect reason, reconnect scheduled, timeout stage, and extended-runtime active state.
- **Purpose:** Let operators answer, from the watch UI, whether the observer flow found the right device, passed auth, reached the passive authenticated gate, enabled control, armed passive observation, used fallback `0x4E` if needed, and saved the reading.
- **Guardrail:** Keep this section compact and status-oriented. Do **not** render raw packet hex dumps or giant scrolling logs in the watch UI.
- **Acceptance:** The debug UI reflects the same observer milestones used in logging: auth notify enabled, J-PAKE skipped, `0x03` seen, `0x05 authenticated/bonded observed`, control notify enabled, passive observation armed, fallback `0x4E` if used, `0x4E` received, and snapshot saved.

### Task C2 — Optional diff review (out of band)

- **Acceptance:** None required for initiative closure — transient `git diff` scratch docs may be generated under repo **`docs/code-review/`** per [`.cursor/rules/code-review-diff-doc.mdc`](../../../.cursor/rules/code-review-diff-doc.mdc) when an agent or reviewer wants a verbatim diff; **not** linked from **design / plan / report 03** in this folder.

### Task C3 — Instrumentation (Tier 1–3) per report **03**

- **Reference:** [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md).
- **Acceptance:** Implement **Tier 1** as a unit when tackling observability upgrades (`g7_session`, stage transitions, milestones, timing, timeouts + teardown, lifecycle `g7_ble_lifecycle`, dedupe); **Tier 2–3** as follow-ons. **Snapshot** table in report **03** lists current code vs target — use it to avoid duplicating event names.

---

## Phase D: Optional hardening (deferrable)

- **`Data` endian helpers:** Prefer optional reads + early `egv_parse_bounds` / `egv_txtime_invalid` logs (partially addressed in v1.2 code; unit tests still optional).
- Sanitize `error=` / `peripheral=` log fields for strict `key=value` parsers.
- Rate-limited log for non-`0x4E` control-channel payloads.
- Unit tests for pure Swift parse helpers (if extracted).

---

## Phase E: Pre-connect parity investigation (build 162)

**Ship gate:** Yes — additive instrumentation + one parity experiment; observer/auth/GATT/EGV logic unchanged.

**Context:** Builds through 158 show Trio's `central.connect(peripheral, options: nil)` never receiving `didConnect` — the watch stalls at `awaiting_connect` and times out after 30 s. DiaBLE Watch connects successfully to the same G7 sensor. A focused code comparison of the pre-connect path (see [watch-direct-ble-cgm-05-diable-comparison.md](watch-direct-ble-cgm-05-diable-comparison.md)) identified several structural differences that could explain the missing callback. Phase E isolates the most plausible candidates with minimal instrumentation and one parity change.

**Constraints (carry forward from prior isolation):**

- **Extended runtime still disabled** at connect time and on foreground renewal (`logExtendedRuntimeSessionSkipped`). Do not re-enable until `didConnect` is confirmed.
- **Observer / auth / GATT / EGV logic unchanged.** No post-connect changes in this phase.
- **Scan filter unchanged** (`withServices: [FEBC]`). The peripheral *is* being discovered; the scan filter is not the suspect.
- **No broader redesign.** Queue (`nil` vs `.main`), `discoverServices` scope, and reconnect pacing are deferred to Phase F if build 162 is still inconclusive.

### Task E1 — Pre-connect state instrumentation

- **Files:** `Trio Watch App Extension/G7DirectBLEManager.swift`
- **Change:** Add **one** new structured log line immediately before `central?.connect(peripheral, options: nil)` in `beginConnectToG7Peripheral`:

  ```
  event=g7_ble_pre_connect
      peripheral_state=<CBPeripheral.state.rawValue>
      central_state=<CBCentralManager.state.rawValue>
      source=scan|retrieved
      first_attempt=<true|false>
      preserved_session=<true|false>
  ```

  Fields:

  - **`peripheral_state`**: `CBPeripheral.state.rawValue` at the instant before `connect()`. Expected: `0` (disconnected). If `2` (connected) or `1` (connecting), the peripheral may already be owned by another process — this is a primary diagnostic signal.
  - **`central_state`**: `CBCentralManager.state.rawValue` at the instant before `connect()`. Expected: `5` (poweredOn). Any other value means the `connect()` is issued to a non-ready manager.
  - **`source`**: Whether this peripheral came from the `retrieveConnectedPeripherals` path (`retrieved`) or the `didDiscover` scan path (`scan`).
  - **`first_attempt`**: Whether this is the first connect attempt since the last `startScanning()` call (i.e. not a reconnect after disconnect).
  - **`preserved_session`**: Whether the current `g7_session` was carried over from a prior foreground entry via `applyForegroundActiveEntry` (i.e. the manager was already `.scanning`…`.connected` and skipped a full restart).

- **Acceptance:** Better Stack shows `event=g7_ble_pre_connect` with all five fields on every connect attempt in build 162. The values directly answer whether CoreBluetooth state is nominal at the moment `connect()` is called.

### Task E2 — `retrieveConnectedPeripherals` retry inside `.poweredOn`

- **Files:** `Trio Watch App Extension/G7DirectBLEManager.swift`
- **Change:** In `centralManagerDidUpdateState(_:)` when `state == .poweredOn`, after the existing scan start, add a `retrieveConnectedPeripherals(withServices: [G7BLEUUID.advertisement])` call and log the result:

  ```
  event=g7_ble_retrieve_on_powered_on count=<n> first_name=<name|unknown> first_state=<rawValue>
  ```

  This matches DiaBLE's timing: DiaBLE calls `retrieveConnectedPeripherals` **inside** the `.poweredOn` handler (where it can actually return results), while Trio currently calls it only inside `startScanning()` — which on first launch executes **before** the manager reaches `.poweredOn`, always returning empty.

  If a peripheral is retrieved and the active-name filter matches, route it through `beginConnectToG7Peripheral(_, source: "retrieved_on_powered_on")`. If the filter does not match or is not armed, log but do not connect.

- **Acceptance:** Better Stack shows `event=g7_ble_retrieve_on_powered_on count=<n>` on every fresh `CBCentralManager` creation that reaches `.poweredOn`. If `count > 0` and the filter matches, the peripheral enters the connect path via retrieval instead of waiting for a `didDiscover` scan callback.

### Task E3 — `CBCentralManagerOptionRestoreIdentifierKey` parity experiment

- **Files:** `Trio Watch App Extension/G7DirectBLEManager.swift`
- **Change:** Add `CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"` to the `CBCentralManager` creation options alongside the existing `CBCentralManagerOptionShowPowerAlertKey: false`. Add the corresponding `willRestoreState` delegate method:

  ```swift
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
      Task {
          await logG7Ble("event=g7_ble_will_restore_state keys=\(dict.keys.sorted().joined(separator: ","))")
      }
  }
  ```

  **Rationale:** DiaBLE uses `CBCentralManagerOptionRestoreIdentifierKey: "DiaBLE"` on both phone and watch. Trio does not. State restoration allows CoreBluetooth to:
  - Re-deliver pending connection attempts after app relaunch
  - Maintain connection state across watchOS lifecycle transitions
  - Deliver `willRestoreState` with in-flight connection info on relaunch

  On watchOS, where the runtime aggressively suspends/resumes extensions, this is the single most impactful pre-connect parity gap vs DiaBLE.

- **What this does NOT change:**
  - Queue remains `queue: .main` (defer `queue: nil` experiment to Phase F if needed).
  - Scan filter remains `withServices: [FEBC]`.
  - Extended runtime remains disabled at connect time.
  - Observer / auth / GATT / EGV path unchanged.

- **Acceptance:** Better Stack shows `event=g7_ble_will_restore_state keys=…` when CoreBluetooth restores the manager (if it does). The primary acceptance criterion is whether build 162 now produces `g7_ble_connected` instead of `g7_ble_timeout stage=awaiting_connect`.

### Expected diagnostic output from build 162

On each connect attempt, Better Stack should show (in order):

1. `g7_ble_scan_started` or `g7_ble_retrieve_on_powered_on count=<n>`
2. `g7_ble_peripheral_discovered` (scan path) or `g7_ble_retrieve_on_powered_on count=1` → connect (retrieval path)
3. `g7_ble_pre_connect peripheral_state=0 central_state=5 source=scan first_attempt=true preserved_session=false`
4. `g7_ble_connect_attempt`
5. Either `g7_ble_connected` (success — Phase E achieved its goal) or `g7_ble_timeout stage=awaiting_connect` (still failing — proceed to Phase F)

If `g7_ble_pre_connect` shows unexpected values (e.g. `peripheral_state=2`, `central_state!=5`), that directly explains the stall.

If `g7_ble_will_restore_state` fires, its keys indicate what CoreBluetooth is restoring — pending peripherals, in-flight connections, etc.

### Phase F: Watch pre-connect parity, gated by evidence (historical sequence before Phase G)

Replace the loose candidate list with **four** one-change-per-build experiments. Do **not** batch them.

**Hard rules for Phase F**

- For **every** Phase F build, collect watch-only **`g7_ble_*`** logs.
- Filter all connect-boundary analysis to **`platform=watchos`**. iPhone logs may be noted as context but are not proof of watch-side connect success.
- Keep the existing event names for dashboard continuity; new connect-boundary events are **additive**.
- **PacketLogger / raw-capture work is deferred for now**. It is **not** mandatory for each build in the current post-**F4** sequence and should be revisited only after the watch-only log trail stops yielding actionable boundary movement, or sooner if later evidence makes it necessary.
- Stop Phase F as soon as the primary success condition is met; do **not** continue to later code experiments after a successful earlier step.

**Historical execution / option sequence before Phase G**

| Step | Change | Notes |
|------|--------|-------|
| **F1** | Add explicit connect-boundary observability | **Implemented and reviewed in build 163** — the watch-only trail is now closed, but the session still times out at **`awaiting_connect`** with no **`didConnect`**, **`didFailToConnect`**, or **`didDisconnect`** |
| **F2** | Change `CBCentralManager` queue from **`.main`** to **`nil`** | **Implemented and deployed as build 164** — watch-only Better Stack review is now complete and negative; keep options / retrieval / discovery scope unchanged |
| **F3** | Remove **`CBCentralManagerScanOptionAllowDuplicatesKey: false`** and omit the option | **Implemented and deployed as build 165**; watch-only Better Stack review is now recorded as negative, so proceed to **F4** |
| **F4** | Move `CBCentralManager` allocation earlier for lifecycle / launch-context parity | **Implemented and deployed as build 166**; produced the first watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`** and one **`discovering_services`** outcome, but still no service/EGV/snapshot milestone |
| **F5** | Close post-connect GATT attribution **and** add dual-UUID retrieval diagnostics | **Implemented and deployed as build 168** — additive instrumentation landed cleanly and the live result is now clearer: retrieval has returned **0** candidates on both **data service** and **FEBC** so far, all observed connect attempts remain **`source=scan`**, and every observed build-168 attempt still dies before **`didConnect`** |
| **F6** | Broaden service discovery to `discoverServices(nil)` parity | **Conditional build after F5** — only if **F5** shows **`didConnect`** but still no usable service-discovery callback / data-service visibility |
| **F7** | Broaden characteristic discovery to `discoverCharacteristics(nil, for:)` parity | **Conditional build after F5/F6** — only if service discovery succeeds and characteristic discovery becomes the first missing gate |
| **F8** | GATT-setup readiness / timeout-cancel audit | **Audit / attribution task, not a default standalone build** — no longer a top active suspect; only promote if **F5** exposes a real mismatch |
| **F9** | Retrieved-vs-scan diagnostic lane | **Historical analysis lane** — source-split metrics and interpretation guide used to decide whether a later retrieval-focused build was warranted |
| **F10** | Identifier-first retrieval experiment | **Implemented and deployed as build 170**, then carried forward into the current watch baseline together with the passive-first observer/lifecycle follow-ups. Identifier-first retrieval remains part of the preserved attach-context record, but it is no longer the active top-level next step because the initiative is now moving into **Phase G**. |
| **F11** | Connection-event registration on watch | **Superseded for execution by Phase H H1** (shipped **with `registerForConnectionEvents` enabled** in **build 171**, then **disabled in source** for **Phase I / 177+** regression isolation). Historical row preserved; use **Phase H / Phase I** sections as the live record. |

**F1 — connect-boundary observability**

- Keep existing events unchanged for continuity: **`g7_ble_connect_attempt`**, **`g7_ble_connected`**, **`g7_ble_connect_failed`**, **`g7_ble_disconnected`**, **`g7_ble_timeout`**.
- Add watch-only delegate / timer events:
  - **`g7_ble_connect_timeout_armed timeout_s=30`**
  - **`g7_ble_connect_timeout_canceled reason=did_connect|did_fail_to_connect|teardown|startScanning_rescan|stop_requested`**
  - **`g7_ble_did_connect`**
  - **`g7_ble_did_fail_to_connect`**
  - **`g7_ble_did_disconnect`**
- Emit **`g7_ble_did_disconnect`** at the delegate boundary **before** any early return, including the intentional **`startScanning_rescan`** path.
- Update report **03** so the expected trail is explicit:
  **`connect_attempt -> connect_timeout_armed -> did_connect|did_fail_to_connect|timeout`**, with **`did_disconnect`** logged whenever it occurs.

**F2 — `CBCentralManager` queue parity**

- Change **`CBCentralManager(delegate:queue:options:)`** from **`queue: .main`** to **`queue: nil`**.
- Do **not** change manager options, scan options, retrieval logic, or service-discovery scope in this build.
- As part of the F2 review, verify that all state-mutation paths still satisfy the existing main-thread assumptions / assertions. Do **not** patch over queue issues with ad hoc dispatching in this step.
- Keep all F1 instrumentation unchanged so the comparison isolates the queue change.

**F3 — scan option parity**

- Remove **`CBCentralManagerScanOptionAllowDuplicatesKey: false`** from both scan call sites so Trio matches DiaBLE by omitting the option.
- Do **not** add new scan logs in this step.
- Compare connect-boundary outcomes only, and watch for excessive duplicate discovery noise in the existing **`g7_ble_peripheral_discovered`** volume.
- Keep retrieval, restore-key behavior, extended-runtime behavior, and service-discovery scope unchanged.

**F4 — `CBCentralManager` lifecycle / early allocation parity**

- Triggered only after **F3** proved negative. That trigger was met by build **165**, and **F4** has now been implemented and deployed as build **166**.
- Rationale: the remaining strongest structural discrepancy is now manager lifecycle / launch context parity rather than scan filtering alone.
- **DiaBLE Watch** and **Trio Phone** both operate with an already-lived, restore-backed central-manager lifecycle.
- Before **F4**, **Trio Watch** allocated the manager lazily inside **`startScanning()`**.
- Change for this build only: move **`CBCentralManager`** allocation earlier so the watch manager lifecycle better matches the successful **DiaBLE Watch** / **Trio Phone** pattern. In the current code that means the manager is created in **`G7DirectBLEManager.init()`**, while **`startScanning()`** reuses the already-lived manager in the normal path.
- Preserve the current **`queue: nil`** setting, restore identifier, retrieval behavior, and all existing logging from the prior build.
- Keep this as a standalone **one change per build** experiment.
- Current runtime result for build **166**: partial positive movement. Watch-only Better Stack review now shows **17** connect attempts in build **166**, including **1** retrieval-assisted session that emitted **`g7_ble_did_connect`**, **`g7_ble_connected`**, and **`g7_ble_connect_timeout_canceled reason=did_connect`**, then timed out later at **`g7_ble_timeout stage=awaiting_gatt_setup`** with **`final_stage=discovering_services`**. The remaining **16** build-166 sessions still time out at **`awaiting_connect`**.
- Build **166** still shows **no** watch-side **`g7_ble_services_discovered`**, **`g7_ble_characteristics_discovered`**, **`g7_ble_auth_notify_enabled`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_egv_request_sent`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`**. Treat **F4** as a moved boundary, not as end-to-end success.

**F5 — post-connect GATT attribution closure + dual-UUID retrieval diagnostic**

- This step is now **implemented and deployed as build 168**.
- Goal: keep the build **additive and diagnostic**, not behavioral. For every session that reaches **`g7_ble_did_connect`**, make the next missing GATT callback or readiness gate explicit rather than inferred from a later **`awaiting_gatt_setup`** timeout. In the same build, compare the current retrieval path against a parallel **FEBC** retrieval path to see whether Trio is missing more favorable retrieved candidates.
- Retrieval scope for this build:
  - keep the existing retrieval on **`G7BLEUUID.dataService`**
  - add a parallel retrieval on **`G7BLEUUID.advertisement`** / **FEBC**
  - log retrieval counts separately for each UUID
  - log whether the returned peripheral identifiers overlap across the two retrieval result sets
  - keep explicit source attribution for every connect attempt: **`source=scan`**, **`source=retrieved_data_service`**, or **`source=retrieved_febc`**
  - ensure no duplicate connect attempt is issued for the same peripheral identifier within one attach cycle unless explicitly intended as a later isolated experiment
- Pre-connect attribution additions for this build:
  - log **`peripheral.state`** immediately before **`connect()`**
  - log **`peripheral.identifier`** (or existing bounded short form) immediately before **`connect()`**
  - preserve the existing watch-only connect-boundary trail so the new fields remain comparable to builds **163–166**
- Tighten watch-side attribution around:
  - in **`didConnect`**, log whether **`peripheral.services`** is already non-`nil` before calling service discovery
  - **`didDiscoverServices`** entered
  - **`didDiscoverServices`** success / failure, callback error if present, service count, bounded discovered service UUID list, and whether the Dexcom data service was found
  - **`didDiscoverCharacteristicsFor`** entered
  - characteristic presence summary for **auth / control / backfill / J-PAKE**
  - **`didUpdateNotificationStateFor`** success / failure per characteristic
  - explicit **`awaiting_gatt_setup`** arming / cancellation attribution
  - debug-funnel blocker reasons for **no data service**, **no required characteristic**, **notify failed**, **authenticated=false**, **bonded=false**, and **control notify not enabled**
- Interpretation guardrail: a better outcome on **retrieved-sourced attempts** (**`source=retrieved_data_service`** or **`source=retrieved_febc`**) does **not** by itself prove Trio joined an existing OS-level session or inherited another app’s connection. Treat it as evidence of a different attach context, not as proof of a specific CoreBluetooth mechanism.
- Scope discipline: keep observer semantics unchanged. **F5** is an attribution / retrieval-diagnostic build, not a discovery-scope parity build and not a connect-path rewrite.
- Current live build-168 outcome:
  - the F5 instrumentation is present and emitting the intended fields
  - retrieval has produced **no** live candidates so far on either **data service** or **FEBC**
  - observed connect attempts remain **`source=scan`** only
  - there are still **no** build-168 watch-side **`g7_ble_did_connect`**, **`g7_ble_did_discover_services`**, or later GATT / observer milestones
  - therefore **F5** has clarified the current boundary without moving it: the dominant live failure remains **scan-path pre-connect timeout**

**F6 — `discoverServices(nil)` parity**

- Planned only after **F5**, and only if a later **build-168-or-newer** session shows **`didConnect`** but still leaves the first missing post-connect boundary at service discovery or usable data-service visibility.
- Goal: test whether Trio’s narrow **`discoverServices([G7BLEUUID.dataService])`** call is part of the post-connect stall now that build **166** has crossed **`didConnect`** once.
- Keep this as a standalone one-change build: do **not** bundle it with characteristic-scope changes or readiness-logic changes.

**F7 — `discoverCharacteristics(nil, for:)` parity**

- Planned only after service discovery is no longer the first missing gate — either directly after **F5** or after a negative **F6** result.
- Goal: test whether Trio’s targeted characteristic request is too restrictive or behaves differently from DiaBLE in the watch context once service discovery itself is no longer the first boundary.
- Keep observer/auth semantics unchanged. This is discovery-scope parity only.

**F8 — GATT-setup readiness / timeout-cancel audit**

- This is not the default next build and is no longer a top active suspect.
- Current code already treats the observer startup-ready gate as **auth notify enabled + `0x05 authenticated=true bonded=true` + control notify enabled**, with **backfill optional**.
- Use **F8** only if **F5** exposes a real mismatch between the intended startup-ready rule and the actual timer / blocker behavior. Otherwise keep it as documentation / attribution work, not a standalone build.

**F9 — retrieved-vs-scan diagnostic lane**

- This is a historical analysis lane in the Phase F record, not an automatic current code change.
- Build **166** matters because the only moved session so far used **`source=retrieved`**, while the remaining sessions still timed out at **`awaiting_connect`** from the scan path.
- For every later build, split watch-only metrics by **`source=scan`** vs retrieved-derived sources (**`source=retrieved_identifier`**, **`source=retrieved_data_service`**, and **`source=retrieved_febc`**):
  - **`g7_ble_connect_attempt`**
  - **`g7_ble_did_connect`**
  - **`g7_ble_timeout`** by stage
  - service / characteristic / auth / control milestones, if any occur
- Interpretation guidance:
  - persistent clustering of success on retrieved-derived sources strengthens the attach-context hypothesis
  - it does **not** prove a specific Apple/CoreBluetooth mechanism
  - if scan and retrieved-derived sources converge, demote retrieval-context theories accordingly
- Use watch-only Better Stack searches first. Promote this into a later code experiment only if the source split remains materially asymmetric after **F5** closes the post-connect trail.
- Build **168** sharpens this lane in a different way than build **166** did: the current live result is not “retrieved is winning,” but “retrieval is absent.” That means later retrieval-focused experiments should be justified by continued zero-result retrieval plus persistent scan-path timeout, not by over-reading the single build-166 retrieved-assisted success.

**F10 — identifier-first retrieval experiment**

- This step is now **implemented and deployed as build 170**. It remains part of the preserved attach-context investigation record, but it is no longer the active top-level next step because the initiative is now moving into **Phase G**.
- Goal: test whether stable peripheral identity continuity is the real attach advantage by attempting **`retrievePeripherals(withIdentifiers:)`** before falling back to service-based retrieval or scan.
- Implementation scope in the current code:
  - persist the watch-side **`CBPeripheral.identifier`** in App Group defaults on **connect attempt** and refresh it again on **`didConnect`**
  - clear the stored identifier only when the phone-provided active sensor name materially changes or is removed
  - attempt identifier retrieval before the existing **data-service** and **FEBC** connected-service retrieval paths in both pre-scan entry points
  - add explicit source attribution **`source=retrieved_identifier`**
  - keep the existing exact active-name attach policy, duplicate suppression, scan behavior, and post-connect logic unchanged
- Scope discipline for this build: **do not** bundle identifier-first retrieval with **`registerForConnectionEvents`**, restored-peripheral auto-reattach, discovery-scope parity changes, or broader connect-path rewrites.
- The current build-170 watch baseline that follows this step now also includes the later passive-first observer-path cleanup, warning-only **`extendedRuntimeSessionWillExpire(...)`**, and reconnect after disconnect / failed connect unless teardown was explicit control flow.

**F11 — connection-event registration on watch**

- **Execution status:** This exploratory step was **folded into Phase H as H1** and shipped **enabled** in **build 171** alongside Phase G. It is **not** a separate future F-series build anymore.
- **Current code posture:** **Phase I** intentionally **comments out** H1 (**177+** / current `Trio` tree) to isolate the build-171+ **`didConnect` regression**; re-enable only after field evidence supports it.
- Historical note: the original **F11** gate (“promote only if…”) predates the mandatory H1 work; keep this subsection as provenance only.

**Validation plan**

- For each Phase F build, capture:
  - watch-only **`g7_ble_*`** logs
  - source-split Better Stack queries / counts for **scan** vs retrieved-derived attempts
  - for **F5** specifically, retrieval-count logs for **data service**, **FEBC**, and identifier overlap between the two result sets
- **PacketLogger / raw capture** is a deferred parallel diagnostic track for the current cycle, not a required per-build gate. Pull it forward only if **F5** still leaves the first missing callback ambiguous, or if **`didConnect`** occurs but **`didDiscoverServices`** still never becomes attributable.
- **F5** should close the post-connect trail before any new discovery-scope parity build is selected.
- If a build reaches post-connect behavior, keep the same capture running longer to assess early post-connect stability.
- Closed-trail acceptance for every build:
  - every **`g7_ble_connect_attempt`** has one **`g7_ble_connect_timeout_armed`**
  - every **connect-boundary** armed timeout ends with exactly one of **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, or **`g7_ble_timeout stage=awaiting_connect`**
  - any disconnect produces **`g7_ble_did_disconnect`**, including intentional rescan paths
- Define the working **operational `g7_ble_did_connect` threshold** as either:
  - **2 consecutive** observed connect attempts in the same build reaching **`g7_ble_did_connect`**, or
  - **2 of the first 3** observed connect attempts in the same build reaching **`g7_ble_did_connect`**
- A build does **not** meet that operational threshold if, after the first success, the remaining observed attempts simply fall back into the prior all-**`awaiting_connect`** timeout pattern.
- **Primary stop condition:** stable watch-side **`g7_ble_did_connect`** is observed **and** at least one watch-side direct-BLE read path completes, proven by **`g7_ble_egv_received`** plus **`g7_ble_snapshot_saved`**.
- **Preferred stronger stop condition:** the same build also captures **3** CGM updates after connect success.
- Once the primary stop condition is met, stop applying later Phase F code changes. Keep the same build running long enough to try to reach the stronger 3-update condition, but do not proceed to the next code experiment.

**Out of active scope unless the post-F4 sequence stops yielding new boundary movement**

- Broad connect-path rewrites
- Extended-runtime re-enable
- Restore key as an active lever
- More queue experiments
- More restore-key experiments
- Reopening observer auth-init / J-PAKE / bonded debates as current-root-cause work
- Timing-window and Dexcom-watch-app contention theories as standalone code changes before the next disciplined attribution build

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Wrong write response type | Device validation; log write failures |
| Protocol / layout drift | Versioned logs + soak |
| Xcode target membership | Human verification after file add |

---

## Hypotheses (NOT acceptance)

- EGV byte layout matches community/DiaBLE-style layouts for test vectors.
- Trend byte maps linearly to mg/dL/min for arrow mapping.

---

## Implementation log

_Added in **v1.1** (post-implementation). The phased task sections above are unchanged from **v1.0** and remain the authoritative pre-implementation spec._

### Baseline (kickoff)

| Field | Value |
|-------|--------|
| **Date** | 2026-04-11 (CET) |
| **Design / plan** | `watch-direct-ble-cgm-01-design.md` v1.0; this plan **v1.0** (prospective) at kickoff |
| **Code worktree** | `Trio` — branch **`feature/watch-direct-ble-cgm`** |
| **Baseline SHA (at diff review)** | `1b3919a7c` (parent for `WatchState.swift` diff in code review doc) |
| **Patch stack** | Not published to `./patches/` in `Trio-dev` as part of this doc write — follow **`generate-patch.sh`** when ready |

### Record — implementation landed (prospective tasks → actual)

**Date:** 2026-04-11 22:45 CET  

- **Phase A:** Implemented **A1** + **A2**: `private lazy var g7DirectBLEManager` in `WatchState.swift`; `g7DirectBLEManager.startScanning()` at end of `handleForegroundActiveEntry()`; `g7DirectBLEManager.stop()` at start of `handleForegroundInactiveOrBackground()`.
- **Phase B:** Added **`G7DirectBLEManager.swift`** — CoreBluetooth scan (`FEBC`), connect, service/characteristic discovery, auth eavesdrop (`0x03` logged, no J-PAKE reply), `0x05` → notify on control/backfill, EGV request `0x4E`, parse + `TrioComplicationDataStore.save(..., minInterval: 5)`, `WatchLogger` lines with `event=g7_ble_*`.
- **Phase C:** Optional diff review — **2 files**, **+485 / −0** vs baseline; noted **uncommitted** at time of review generation (historical). **Superseded:** initiative no longer links transient **`docs/code-review/`** artifacts (**v1.20**).
- **Phase D:** **Partial** — **2026-04-11:** `Data` reads use **optional** `readUInt16LE` / `readUInt32LE` + `egv_parse_bounds` / `egv_txtime_invalid` logs (no `precondition` on parse). Log sanitization, rate-limited non-EGV control logs, and unit tests **deferred**.

**Artifacts**

- **Trio:** `Trio Watch App Extension/G7DirectBLEManager.swift`, `WatchState.swift` (hooks).
- **`Trio-dev`:** (historical) optional diff scratch under **`docs/code-review/`** — **not** linked from this initiative (**v1.20**).

**Open follow-ups (non-blocking for doc completeness)**

- Confirm **target membership** for `G7DirectBLEManager.swift` via canonical Xcode/build workflow (**not** agent `sync_project_files.rb`).
- On-device soak + Better Stack correlation.
- Optional hardening per Phase D and red-team IDs **R3–R6** (see **v1.2** external review).

### Record — external code review (Claude) + fixes (2026-04-11)

**Source:** Third-party review of `G7DirectBLEManager.swift` / `WatchState` / process expectations.

| # | Severity | Finding | Disposition (after fixes) |
|---|----------|---------|---------------------------|
| 1 | Blocker | `didWriteValueFor` tore down session on **any** write error | **Fixed** — teardown only on **authentication** write failure (`write_failed_auth`); non-auth logs `g7_ble_write_error_nonfatal`. |
| 2 | Blocker | EGV request gated on **backfill** notify | **Fixed** — `trySendEGVRequestIfReady()` gates on `controlNotificationsReady` only. |
| 3 | Blocker | `save` inside `Task` | **Already correct / clarified** — `TrioComplicationDataStore.save` was already synchronous; added **comment** that delegate is main queue. |
| 4 | Major | `storedActivationWallClock` when `txTime == 0` | **Fixed** — guard `txTime > 0` before first activation store; log `egv_txtime_invalid`. |
| 5 | Major | No reconnection after disconnect while foreground | **Fixed** — `teardownSession` schedules `startScanning()` after **7s** when `scanningStarted` is still true; `stop()` / `startScanning()` cancel `reconnectWorkItem`. |
| 6 | Major | `trendString` thresholds vs R6.1 | **Fixed** — `hkTrendStringFromDeltaMgDl` mirrors `WatchState.hkTrendString(fromDeltaMgDl:)` (mg/dL per ~5 min from `rate * 5`). |
| 7 | Minor | `pendingDisconnectReason` double `stop()` | **Noted** — low risk; foreground lifecycle; no code change. |
| 8 | Minor | `.error` vs `.disconnected` inconsistency | **Fixed** — `teardownSession(reason:isFailure:)`; `g7_ble_disconnected` includes `failure=true|false`; user stop uses `isFailure: false`. |
| 9 | Minor | `precondition` in BLE parsers | **Fixed** — optional reads + `egv_parse_bounds` path. |
| 10 | Minor | `sync_project_files_config.rb` / `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | **Won’t apply** — design/plan explicitly avoid **compile flags** for this path; CoreBluetooth links via `import` without a custom condition. **No** agent edits to sync config. |
| 11 | Minor | New file in target Sources | **Open** — human verification / build (`AGENTS.md` — no agent `pbxproj` / sync). |

### Record — red-team self-review (full pass, prompt 05)

**Date:** 2026-04-11 22:57 CET  
**Prompt:** `docs/prompts/05-implementation-changes-red-team-full-review.md` (adversarial pass on current `G7DirectBLEManager.swift` + prior findings).

#### New findings (this pass)

| ID | Severity | Location / topic | Problem | Disposition |
|----|----------|------------------|---------|-------------|
| **RT1** | **major** | `startScanning()` | Prior code set `peripheral = nil` without `cancelPeripheralConnection` when a connection existed — orphan link + undefined multi-connect behavior on rescan/reconnect. | **Fixed** — cancel existing peripheral before clearing; set `pendingDisconnectReason = "startScanning_rescan"`. |
| **RT2** | **major** | `teardownSession` + reconnect | Follow-on: naive cancel triggered `didDisconnect` → `teardownSession` → **second** reconnect schedule while `startScanning` already re-armed scan — duplicate work / stacked `DispatchWorkItem`s. | **Fixed** — `didDisconnect` **returns early** when `override == "startScanning_rescan"` (intentional cancel for rescan; no teardown log/reconnect). |
| **RT3** | minor | Reconnect loop | Repeated protocol failures while foreground could **7s spin** indefinitely (no backoff / max attempts). | **Partially addressed (v1.4)** — `teardownSession` only schedules 7s rescan when **`!isFailure`**; protocol/GATT failures no longer auto-reconnect. Residual: repeated **non-failure** disconnects still retry every 7s; backoff optional. |
| **RT4** | minor | `handleEGVPayload` | Non-`0x4E` control payloads still **silent** (debuggability). | **Open** — Phase D rate-limited log. |
| **RT5** | minor | Logs | `localizedDescription` / peripheral names may break strict `key=value` parsers (prior R5). | **Open** — sanitize or quote. |
| **RT6** | nit | `readingDate` math | `Int64(txTime) - Int64(egvAge)` extreme values theoretically overflow — unlikely on real G7. | **Open** — no change. |

#### Fixes applied in code (2026-04-11)

- **`startScanning()`:** `cancelPeripheralConnection` on existing peripheral before `peripheral = nil`; **`pendingDisconnectReason = "startScanning_rescan"`** before cancel.
- **`didDisconnect`:** Early return when `override == "startScanning_rescan"` so intentional rescans do not run `teardownSession` or schedule reconnect.

#### Coverage check (prompt 05)

| Area | Result |
|------|--------|
| Core logic / EGV | Pass — optional parse, `txTime > 0`, R6.1 trend parity |
| State transitions | Pass — `isFailure` on disconnect; rescan disconnect isolated |
| Concurrency / lifecycle | Pass — main queue; reconnect work cancelled on stop/start |
| Persistence | Pass — synchronous `save` on main |
| Observability | Partial — RT4/RT5 open |
| Tests | Fail — no automated tests (R2 / RT) |
| Operational | Partial — RT3 reconnect backoff; RT6 nit; device soak open |

#### Verdict (this pass)

- **Not “prompt-05 clean”** while **automated tests**, **device soak**, and **Phase D** items (RT4, RT5, backoff) remain open.
- **Blocker-class issues from this pass (RT1/RT2)** addressed in code before closing the doc update.
- **Residual:** RT3–RT6, target membership (#11), patch publish.

#### Self-review table (prompt 05 IDs — updated dispositions)

| ID | Severity | Topic | Disposition (after v1.3 pass) |
|----|----------|-------|-------------------------------|
| R1 | major (process) | Design/plan traceability | **Resolved** — design + this plan |
| R2 | major (validation) | No unit tests | **Open** |
| R3 | minor | `startScanning` without cancel | **Resolved** (v1.3) — cancel + `startScanning_rescan` / `didDisconnect` early exit |
| R4 | minor | `precondition` in `Data` helpers | **Resolved** (v1.2) — optional reads |
| R5 | minor | Log injection | **Open** |
| R6 | minor | Silent non-`0x4E` control | **Open** |
| R7 | minor (ops) | Dexcom app coexistence | **Open** — device |
| R8 | minor | Rapid stop/start | **Open** — soak |

**AGENTS.md alignment:** No `project.pbxproj` edits; no `sync_project_files.rb`; no `xcodebuild` / unsolicited `ci/local-build.sh` for this verification pass.

### Record — Cursor review (v2, pre-soak)

**Date:** 2026-04-11 23:05 CET  
**Source:** Cursor feedback on current implementation + docs trail.

**Assessment (summary)**

- Original blockers and **RT1/RT2** (rescan/reconnect) treated as **resolved**; **`startScanning_rescan`** + **`didDisconnect` early return** validated as the right pattern.
- **R6.1** trend parity via `rate * 5` + duplicated thresholds noted as clean; shared-helper extraction deferred (not a blocker).

**Fix applied**

| Topic | Change |
|-------|--------|
| Reconnect on protocol failures | **Superseded by later watch-side fix.** The current watch implementation now schedules the 7s retry after both disconnects and failed connects, unless teardown was an explicit stop (`stop_requested`). This row remains as historical review context only; the active behavior is no longer `!isFailure`-gated. |

**Open for soak / Phase D**

- RT4, RT5, RT6, R2, R11 as in prior tables; **hkTrendString** deduplication → follow-up in shared code.

**Verdict (Cursor):** Ready for **device soak** after this reconnect guard; remaining items Phase D or soak validation.

### Record — patch stack (`Trio-dev`) — patch 11

**Date:** 2026-04-11 23:23 CET  
**Worktree:** `Trio-dev` on **`dev`** — `scripts/generate-patch.sh` + `scripts/patch-test.sh` per `docs/process/feature-branch-workflow-optimization.md` / **`AGENTS.md`**.

| Step | Result |
|------|--------|
| **Goal** | Add **`patches/11-watch-direct-ble-g7.patch`** with only `Trio Watch App Extension/G7DirectBLEManager.swift` + `WatchState.swift` from **`feature/watch-direct-ble-cgm`**. |
| **First attempt** | `-n -s feature/watch-direct-ble-cgm -t dev --include-files "…/G7DirectBLEManager.swift,…/WatchState.swift" -d watch-direct-ble-g7` — `generate-patch.sh` dry-run on **raw `dev`** succeeded. |
| **`patch-test.sh`** | **Failed** applying patch **11** after **01–10**: `WatchState.swift` **merge conflict** — earlier patches already changed that file, so a patch whose context matches **raw `dev`** does not match **`dev` + 01…10**. |
| **Fix (overlap baseline)** | Create **`tmp/watch-direct-ble-baseline`** from **`dev`**, `git am --3way` patches **`01`–`10`** only (skip **`11`**), then regenerate: **`-s feature/watch-direct-ble-cgm -t tmp/watch-direct-ble-baseline`** with the same **`--include-files`**, **`-o patches/11-watch-direct-ble-g7.patch`**. Delta vs baseline: **~554** lines (new manager + **7** lines in `WatchState`), not the large **feature vs raw `dev`** churn on `WatchState`. Delete **`tmp/watch-direct-ble-baseline`** after. |
| **`patch-test.sh` (retry)** | **Passed** — patches **01** through **11** apply cleanly. |

**Artifact:** `Trio-dev/patches/11-watch-direct-ble-g7.patch` (add/commit with your usual patch-stack workflow when ready).

### Record — patch 11 regeneration (post–Tier 1 commit)

**Date:** 2026-04-12 14:59 CET  
**Trio feature commit:** **`b4dd0d7dd`** — `watch: G7 direct BLE Tier 1 instrumentation and lifecycle fixes` (**4 files**: `G7DirectBLEManager.swift`, `WatchState.swift`, `TrioWatchApp.swift`, `ExtensionDelegate.swift`).

| Step | Result |
|------|--------|
| **Baseline** | **`tmp/watch-direct-ble-baseline`** from **`dev`**, **`git am --3way`** patches **01**–**10** (skip **11**), branch deleted after |
| **generate-patch.sh** | **`-s feature/watch-direct-ble-cgm -t tmp/watch-direct-ble-baseline -o patches/11-watch-direct-ble-g7.patch -d watch-direct-ble-g7 -y`** **`--include-files`** = four Watch Extension paths above |
| **patch-test.sh** | **Passed** — **01**–**11** apply cleanly |

**Next (historical note — superseded in v1.10):** Previously: build + deploy; **Record — build / deploy** below records completion.

### Record — build / deploy

**Date:** 2026-04-12 13:02 CET  
**Status:** **Build and deploy** for this feature are **complete** (execution trail). **Remaining:** **device soak** / Better Stack correlation (**Phase C**), optional Phase **D** / **R2** and open items in review tables; target membership (**#11**) human-verified via canonical Xcode/build path as needed. **Task C3** Tier 1 — see **Record — Task C3** below (supersedes the pre-C3 “remaining” line for instrumentation).

### Record — CI / fastlane build 158

**Date:** 2026-04-13 00:44 CET  
**Build number:** **158**  
**Result:** **Succeeded** — validates **`dev` + patches 01–11** (including **`patches/11-watch-direct-ble-g7.patch`** with **`Trio Watch App Extension/TrioWatchApp.swift`** and **`G7DirectBLEManager`** **`WKExtendedRuntimeSessionDelegate`** conformance to **`extendedRuntimeSession(_:didInvalidateWith:error:)`** with **`WKExtendedRuntimeSessionInvalidationReason`**).

### Record — Task C3 (instrumentation Tier 1) — report 03

**Date:** 2026-04-12 13:25 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**. **Diff baseline:** working tree vs **`52241a6b2`** at log time (**+264 / −31** over `G7DirectBLEManager.swift` + `WatchState.swift`).

| Area | Outcome |
|------|---------|
| **Normative spec** | [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md) — **Tier 1** required set; **Tier 2** reconnect line + **Tier 3** rate-limited control opcode included in this pass |
| **`G7DirectBLEManager.swift`** | **`g7_session`** UUID per **`startScanning()`**; **`logG7Ble`** appends **`g7_session=`** on **`g7_ble_*`** lines; **`event=g7_ble_stage`** (transition-only); **`discovering_characteristics`** before **`discoverCharacteristics`**; milestones (**`g7_ble_connect_attempt`**, services/characteristics discovered, **`g7_ble_notify_state`**, **`g7_ble_write_ok`**, **`ms_since_discover`** on connect); **timeouts** — **`awaiting_connect`** (30s), **`awaiting_gatt_setup`** (60s, cleared when **control** and **backfill** notify are both enabled), **`awaiting_first_egv`** (90s); **`g7_ble_timeout`** + **`teardownSession`** with per-session stage dedupe; **`g7_ble_reconnect_scheduled delay_s=7`**; **`g7_ble_control_opcode`** (1s rate limit, non-**0x4E** control payloads on EGV path); **`currentG7SessionId`** for **`WatchState`** |
| **`WatchState.swift`** | **`g7_ble_lifecycle`** — **`phase=active`** after **`startScanning()`**; **`phase=inactive`** + **`active_window_s`** on leave-active; **`phase=background`** only for **`scenePhase == .background`**; **`reason=stop_requested`** + **`active_window_ms`** (segment duration); **`TrioWatchApp`** passes **`ScenePhase`** (**`ExtensionDelegate`** does **not** call **`handleForegroundInactiveOrBackground`**) |
| **Optional diff review** | Out of band — **`docs/code-review/`** scratch docs per **`.cursor/rules/code-review-diff-doc.mdc`**; **not** an initiative deliverable |
| **Follow-up** | **Done (v1.17):** commit **`b4dd0d7dd`**, patch **11** regenerated — **soak** / Better Stack queries on new fields remain **open** |

**AGENTS.md:** No `project.pbxproj` or `sync_project_files.rb`; no `xcodebuild` / unsolicited `ci/local-build.sh` for this doc + instrumentation pass.

### Record — Tier 1 follow-on (operational observability + extended runtime)

**Date:** 2026-04-12 21:53 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**. **Diff baseline:** **`b4dd0d7dd`** (`watch: G7 direct BLE Tier 1 instrumentation and lifecycle fixes`); follow-on changes **uncommitted** at log time.

| Area | Outcome |
|------|---------|
| **Design** | [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md) **v1.8** — `activePeripheralName`, extended runtime, observability bullets |
| **`G7DirectBLEManager.swift`** | **`g7_ble_connect_failed`** (`error_domain` / `error_code` / `error_desc`); **`rssi=`** on **`g7_ble_peripheral_discovered`**; **`g7_ble_peripheral_skipped`** when **`activePeripheralName`** set and name mismatches; **`WKExtendedRuntimeSession`** + **`WKExtendedRuntimeSessionDelegate`** (TODO device validation); **`stop()`** → **`g7_ble_stop_deferred`** while extended session active; **`invalidateExtendedSession`** from **`teardownSession`** and **`startScanning_rescan`** path; **`sessionStartedAt`** + **`egvReceivedThisSession`**; **`g7_ble_session_outcome`** after **`g7_ble_disconnected`** |
| **`WatchState.swift`** | **TODO** before **`startScanning()`** to set **`activePeripheralName`** when resolvable (**`G7CGMManager`** not on watch) — **superseded** by **Record — iPhone → watch active G7 peripheral name** below |
| **Instrumentation report** | [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md) **v1.12** — new events listed |
| **Optional diff review** | **Superseded** — initiative no longer links transient **`docs/code-review/`** artifacts (**v1.20**); historical snapshot only |

**Next:** Device soak + confirm **`WKExtendedRuntimeSession`** behavior for BLE connect; **`generate-patch.sh`** / **`patch-test.sh`** when committing (overlap baseline per **Record — patch stack** if **`11`** still overlaps **`01–10`**).

### Record — iPhone → watch active G7 peripheral name (WatchConnectivity)

**Date:** 2026-04-12 22:57 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`** (or equivalent). **Closes** the **TODO** in **Record — Tier 1 follow-on** for **`WatchState`** (`activePeripheralName` population).

| Area | Outcome |
|------|---------|
| **Design** | [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md) **v1.9** — edge-case + observability text for **WC** bridge; **no** App Group cross-device sync |
| **`WatchMessageKeys.swift`** | **`activeG7PeripheralName`** (`active_g7_peripheral_name`) — nested inside **`watchState`** dictionary on the wire |
| **`AppleWatchManager.swift` (iOS)** | **`import G7SensorKit`**, **`@Injected() FetchGlucoseManager`**, **`activeG7PeripheralNameForWatchPayload()`** (`G7CGMManager.sensorName` or **`""`**); merge into **`fullMessage`** after **`watchStateToDictionary`**; add key to **`complicationAllowlist`** so **`transferCurrentComplicationUserInfo`**, **`transferUserInfo`**, and **`updateApplicationContext`** carry the field |
| **`WatchState.swift` (watch)** | **`phoneActiveG7PeripheralName`**; **`applyPhoneActiveG7PeripheralNameIfPresent`** (key **omitted** → legacy, no cache change; **present** + empty → clear filter); **`handleForegroundActiveEntry`** sets **`g7DirectBLEManager.activePeripheralName`** then **`startScanning()`**; **`event=g7_ble_active_name_applied filtered=true`** when filter non-nil; early **`dispatch`** on **`userInfo`** so invalid CGM payloads still update the name |
| **Instrumentation report** | [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md) **v1.13** |

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb` from agent sessions for this work.

### Record — CI build: `WatchState` `g7DirectBLEManager` storage (`@Observable` + `lazy`)

**Date:** 2026-04-11 23:31 CET  
**Branch:** `feature/watch-direct-ble-cgm` (**Trio** worktree). **Patch:** `Trio-dev/patches/11-watch-direct-ble-g7.patch` regenerated **vs `tmp/watch-direct-ble-baseline`** (`dev` + patches **01–10**), same **`--include-files`** as in **v1.5** record.

| Symptom | Cause |
|--------|--------|
| `‘lazy’ cannot be used on a computed property` | **Observation** / **`@Observable`** macro expansion treats tracked members as computed; **`lazy`** is incompatible with that expansion. |
| `init accessor cannot refer to property '_g7DirectBLEManager'…` / `ObservationTracked` macro errors | **`@ObservationIgnored` + `lazy` still** interacted badly with macro-generated `init` accessors (same class of issue as above). |

**Resolution**

| Step | Change |
|------|--------|
| **Code** | **`import Observation`** (alongside existing imports). **`@ObservationIgnored private let g7DirectBLEManager = G7DirectBLEManager()`** — drop **`lazy`**. Rationale (2026-04-11 record): **`lazy`** is not supported with Swift Observation **+** **`@Observable`** in this configuration. **Update:** later **F4** moved **`CBCentralManager`** allocation into **`G7DirectBLEManager.init()`**; this row’s original “no central until **`startScanning()`**” wording applied to the pre-**F4** tree only. |
| **Patch** | Regenerate **`11-watch-direct-ble-g7.patch`** after the commit; **`./scripts/patch-test.sh`** **passes** (**01**–**11**). |

**Plan alignment:** Phase **A1** text described a **`lazy`** manager; **shipped** storage is **`let`** + **`@ObservationIgnored`** for compiler/toolchain correctness. **F4** later allocated **`CBCentralManager`** in **`G7DirectBLEManager.init()`**; attach/scan behavior still starts from foreground **`startScanning()`**, not from **`init`** alone.

### Record — self-review (prompt 05 + checklist) — historical snapshot

**Date:** 2026-04-11 22:45 CET  
**Prompt:** `docs/prompts/05-implementation-changes-red-team-full-review.md` (see `.cursor/rules/implementation-changes-red-team-review.mdc`)

**Summary**

| ID | Severity | Topic | Disposition |
|----|----------|-------|-------------|
| R1 | major (process) | No formal design/plan in repo before implementation | **Resolved** for traceability — `watch-direct-ble-cgm-01-design.md` + this plan (v1.0 prospective, v1.1 log) |
| R2 | major (validation) | No unit tests for parse/state | **Open** — Phase D / extracted pure helpers |
| R3 | minor | `startScanning()` clears `peripheral` without `cancelPeripheralConnection` if ever called while connected | **Superseded** — see **v1.3** red-team RT1/RT2; R3 marked **Resolved** in updated table above |
| R4 | minor | `precondition` in `Data` helpers | **Resolved** in code (v1.2) — optional `readUInt16LE` / `readUInt32LE`; see external review #9 |
| R5 | minor | Log field injection (`error=`, `peripheral=`) | **Open** — sanitize for strict parsers |
| R6 | minor | Silent drop for non-`0x4E` control payloads | **Open** — optional debug log |
| R7 | minor (ops) | Dexcom app coexistence | **Open** — device validation |
| R8 | minor | Rapid stop/start races | **Open** — monitor in soak |

**Verdict (self-review):** **Not “prompt-05 clean”** while **R2** and optional hardening remain open; **documentation + implementation record** are aligned with **design v1.0** and **plan v1.0** task spec for the **informal spike** that was implemented. Further passes: apply Phase D items, add tests, re-run red-team.

**AGENTS.md alignment:** No `project.pbxproj` edits and no `sync_project_files.rb` from agent sessions for this work; no `xcodebuild` / unsolicited `ci/local-build.sh` used for verification.

### Record — red-team + ChatGPT + Claude consolidation (extended runtime + WC)

**Date:** 2026-04-12 23:12 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**. **Prompt:** adversarial pass on **`G7DirectBLEManager`**, **`WatchState`**, **`AppleWatchManager`**, **`WatchMessageKeys`**, watch **`Info.plist`**; external blocks: **ChatGPT** (extended runtime scope + success-path end), **Claude** (main-thread **`teardownSession`**, rescan/outcome, plist, allowlist, deferred **`stop`** log).

#### Consolidated findings (all three sources)

| ID | Source | Severity | Topic | Summary |
|----|--------|----------|-------|---------|
| **RR1** | Self + **ChatGPT** | major | **`stop()` + `WKExtendedRuntimeSession`** | Prior **`stop()`** returned early whenever **`extendedSession != nil`**, so after **`didDiscover`** started a session, **`stop()`** could keep suppressing full teardown for the whole connect/GATT/read window — not limited to “in-flight connect.” |
| **RR2** | Self + **ChatGPT** | major | Success-path extended runtime | No explicit end of extended session when the protected milestone (first persisted glucose) completes — session could remain until teardown, timeout, or expiry. |
| **RR3** | Self | minor | **`didInvalidateWith`** | If the system invalidates the session without going through **`invalidateExtendedSession`**, **`extendedSession`** could remain non-**`nil`** until another path cleared it. |
| **RR4** | **Claude** | major → mitigated | Main thread / **`teardownSession`** | **`extendedRuntimeSessionWillExpire`** calls **`teardownSession`** from a **`Task { @MainActor in … }`**; **`teardownSession`** mutates BLE state assumed main-confined. **Mitigation:** **`assert(Thread.isMainThread)`** at **`teardownSession`** entry (CB delegate queue is main). |
| **RR5** | **Claude** | info | **`startScanning_rescan`** vs **`g7_ble_session_outcome`** | Early return in **`didDisconnect`** skips **`teardownSession`** — **intentional**; **`g7SessionID`** resets at next **`startScanning()`**. **No bug.** |
| **RR6** | **Claude** | info | **`g7_ble_stop_deferred`** ordering | **`Task`**-logged defer could race with expiry logs — **informational**; **obsolete** once defer removed (**RR1** fix). |
| **RR7** | **Claude** | **disagree** | **`complicationAllowlist` tuple** | Concern: second tuple element might be used as **`fullMessage`** key — **actual loop uses `fullMessage[key]`** where **`key`** is **`WatchMessageKeys.*`**. **No code change beyond a clarifying comment** in **`AppleWatchManager`**. |
| **RR8** | **Claude** | **disagree (with repo-context caveat)** | **`WKBackgroundModes` plist target** | Concern: mode must live on “extension” plist vs **`Trio Watch App/Info.plist`**. In **`Trio`**, **`sync_project_files_config.rb`** places **`Trio Watch App Extension/**/*.swift`** under the **`Trio Watch App`** target and sets **`INFOPLIST_FILE` => `Trio Watch App/Info.plist`** for that target — **no separate `Trio Watch App Extension` target in `TARGET_BUILD_SETTINGS`**. **Disposition:** keep **`WKBackgroundModes`** in **`Trio Watch App/Info.plist`**; **still validate** in a real **watchOS** build that the running process that executes **`G7DirectBLEManager`** inherits the capability (Xcode **Signing & Capabilities** / on-device behavior). |

#### Code changes (this record)

| File | Change |
|------|--------|
| **`Trio Watch App Extension/G7DirectBLEManager.swift`** | **`stop()`:** remove early return; **`invalidateExtendedSession(reason: "stop_requested")`** at start, then existing reconnect cancel / scan stop / disconnect (**RR1**). |
| Same | **First glucose EGV path:** after **`TrioComplicationDataStore.shared.save`**, **`invalidateExtendedSession(reason: "first_egv_received")`** (**RR2**). **Superseded by v1.22** — product intent is **continuous** listening; **do not** invalidate on first EGV (see **Record — extended runtime: continuous listening** below). |
| Same | **`teardownSession`:** **`assert(Thread.isMainThread, …)`** (**RR4**). |
| Same | **`extendedRuntimeSession(_:didInvalidateWith:)`:** clear **`extendedSession`** on the main queue (**RR3**). |
| Same | **`didDisconnect` / `startScanning_rescan`:** comment — intentional skip of **`g7_ble_session_outcome`** (**RR5**). |
| **`Trio/Sources/Services/WatchManager/AppleWatchManager.swift`** | Comment above **`complicationAllowlist`:** tuple **`.0`** is the dictionary key; **`.1`** is a debug label only (**RR7**). |

#### Historical table note (**Record — Tier 1 follow-on**)

- The **v1.18** row **`stop()` → `g7_ble_stop_deferred` while extended session active** is **superseded** by this record: **`stop()`** no longer defers; **`g7_ble_stop_deferred`** is **not** emitted by the current branch unless reintroduced.

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb`; no **`xcodebuild`** / unsolicited **`ci/local-build.sh`** for this pass.

### Record — extended runtime: continuous listening (product intent)

**Date:** 2026-04-12 23:21 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**.

**Product intent:** **`WKExtendedRuntimeSession`** exists so the watch can **stay eligible** for BLE + notifications long enough to receive **ongoing** CGM samples and push each update through **`TrioComplicationDataStore`** (and related watch state), **not** only the first EGV in a session. The session should continue until **`stop()`** (foreground leave / user-driven teardown), **`teardownSession`** (errors, disconnect policy, **`startScanning_rescan`** invalidation path), or **OS-imposed** end (**`extendedRuntimeSessionWillExpire`**, **`didInvalidateWith`**).

**Best practice (what to implement):**

- **Do not** call **`invalidateExtendedSession`** after a successful **`save`** on each EGV — that would drop extended runtime right after the first reading and **defeat** continuous updates.
- **Do** invalidate when **`stop()`** runs (**explicit** product teardown — not scene phase), when **`teardownSession`** runs (full BLE session end), or when the **delegate** reports expiry/invalidation (system budget exhausted or policy).
- **Rely on Apple’s limits** for “as long as possible” — the **physical-therapy** extended runtime mode has a **bounded** maximum (per Apple docs; **on-device** validation in soak). There is no supported API to extend indefinitely **beyond** what watchOS grants; **reconnect** / **`startScanning()`** after a **fresh** foreground entry may start a **new** session if the product needs another window after expiry.

**Code change (v1.22):** Removed **`invalidateExtendedSession(reason: "first_egv_received")`** after **`TrioComplicationDataStore.shared.save`** in **`G7DirectBLEManager.handleEGVPayload`**; replaced with a comment stating **continuous listening** intent. **Design** bumped to **v1.11** (**Extended runtime** section).

**Revision of v1.21 / RR2:** External review framed **RR2** as “no explicit end after first successful read” as a **bug**; for this product, **keeping** the session after the first read is **correct**. The **v1.21** table row for **first-EGV invalidate** is **retracted** and superseded by this record.

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb`; no **`xcodebuild`** / unsolicited **`ci/local-build.sh`** for this pass.

### Record — scene phase decoupled from BLE `stop()` (v1.23)

**Date:** 2026-04-12 23:40 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**.

**Product decision:** **`ScenePhase.inactive`** and **`.background`** must **not** call **`g7DirectBLEManager.stop()`** or otherwise end **`WKExtendedRuntimeSession`** / CoreBluetooth solely because the user left the app UI. CGM reception continues until **watchOS** ends the extended runtime window (**`extendedRuntimeSessionWillExpire`**, **`didInvalidateWith`**) or **`teardownSession`** runs for protocol/BLE reasons.

**Code (`Trio`):**

| File | Change |
|------|--------|
| **`G7DirectBLEManager.swift`** | New **`applyForegroundActiveEntry(activePeripheralName:)`** — applies filter, then **`startScanning()`** only if **`shouldSkipFullStartScanningAfterForegroundReentry()`** is false (live **`.scanning`…`.connected`** session). Logs **`g7_ble_foreground_reentry_skipped`** when skipping. **`stop()`** docstring — not scene-driven; reserved for explicit teardown. **`extendedRuntimeSession(_:didInvalidateWith:)`** — refined in **v1.25** (**pre-capture** + **`MainActor`**); see **Record — `didInvalidateWith` error teardown ordering**. |
| **`WatchState.swift`** | **`handleForegroundActiveEntry`** calls **`applyForegroundActiveEntry`** instead of raw **`startScanning()`**. **`handleForegroundInactiveOrBackground`** — removed **`g7DirectBLEManager.stop()`**; **`g7_ble_lifecycle`** lines include **`ble_continues=true`**. |
| **`ExtensionDelegate.swift`** | Comment — inactive does not stop BLE. |

**Docs:** **Design** **v1.13**; **Instrumentation report 03** **v1.15**; **Phase A2** / **Task A1** acceptance updated in this plan.

**`stop()` is still needed** for: explicit future off-switch (settings), tests, and any code path that must hard-disconnect outside OS expiry — it is simply **not** wired from **`ScenePhase`**.

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb`; no **`xcodebuild`** / unsolicited **`ci/local-build.sh`** for this pass.

### Record — foreground re-entry extended-runtime renewal + connection-state cross-repo check (v1.24)

**Date:** 2026-04-12 23:55 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`** (working tree may be ahead of last commit).

**Product / code — extended runtime re-anchor:**

| Area | Implementation |
|------|----------------|
| **`WatchState`** | **`noteSceneLeftActiveUi(at:)`** from **`handleForegroundInactiveOrBackground`** — **`.inactive`** uses a single **`sceneLeftActiveAt`** timestamp (shared with **`active_window_*`**). **`.background`** calls **`noteSceneLeftActiveUi`** only if **`startupIsForegroundActive`** (edge: background without a prior inactive pass). |
| **`G7DirectBLEManager`** | **`lastSceneLeftActiveUiAt`** + **`foregroundReentryRenewalMaxAwaySeconds` (3600)**. **`applyForegroundActiveEntry`** — if away **(0, 3600)s**, **`renewExtendedRuntimeSessionAfterForegroundReentry`**: **`invalidateExtendedSession(reason: foreground_reentry_renewal)`**, then **`startNewExtendedRuntimeSessionIfConnected`** when **`peripheral != nil`** and **`connectionState`** ∈ **`.connecting` / `.authenticating` / `.connected`** — logs **`g7_ble_ext_session_renewal`**. If away ≥ 3600s with **`awaySec > 0`**, logs **`g7_ble_ext_session_renewal_skipped`**. **`beginExtendedRuntimeSession()`** shared by **`didDiscover`** and renewal. |
| **Delegate safety** | **`extendedRuntimeSessionWillExpire`** / **`didInvalidateWith`**: only act when **`extendedSession === session`**; **`didInvalidateWith`** teardown only if **`error != nil`** **and** the session was **current** (**v1.25**: identity captured **before** nil-ing the pointer — see **Record — `didInvalidateWith` error teardown ordering**). Intentional **`invalidate()`** for renewal must not **`teardownSession`**. |

**Connection-state validation (cross-repo):** Documented in **design** **v1.14** § **Connection state model (cross-reference)** — Trio **`G7BLEConnectionState`** stays **`.connected`** between 5‑minute EGVs; **G7SensorKit** uses **`CBPeripheralState.connected`** for command readiness and does not model “between readings” as disconnected; DiaBLE **`DexcomG7`** sequence is consistent with **one** BLE connection. Confirms renewal’s **`.connecting`…`.connected`** guard is appropriate for steady streaming, not “only while transmitting a packet.”

**Docs:** **Design** **v1.14+**; **Instrumentation report 03** **v1.16+**; optional scratch **`docs/code-review/feature-watch-direct-ble-cgm-code-review.md`** regenerated from **`git diff HEAD`** in **`Trio`**.

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb`; no **`xcodebuild`** / unsolicited **`ci/local-build.sh`** for this pass.

### Record — `didInvalidateWith` error teardown ordering (v1.25)

**Date:** 2026-04-13 00:03 CET  
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**.

**Issue (ChatGPT / Claude):** In **`extendedRuntimeSession(_:didInvalidateWith:)`**, clearing **`extendedSession`** before the **`teardownSession`** guard made **`guard let ext = extendedSession, ext === session`** always fail **after** a synchronous clear on the main thread — **error** invalidations of the **current** session never tore down BLE.

**Fix:** One **`Task { @MainActor in … }`**: compute **`isCurrentSession`** from **`extendedSession`** **before** assigning **`extendedSession = nil`**; **`await logG7Ble("event=g7_ble_ext_session_invalidated …")`**; **`guard error != nil, isCurrentSession, scanningStarted, peripheral != nil`** then **`teardownSession(reason: ext_session_invalidated, isFailure: true)`**.

**Minor:** **`WatchState`** — comment on **`.background`** **`noteSceneLeftActiveUi`**: normal path sets timestamp on **`.inactive`**; **`.background`** branch only if **`startupIsForegroundActive`** (rare ordering).

**Docs:** **Design** **v1.15**; **Instrumentation report 03** **v1.17**.

**AGENTS.md:** No `project.pbxproj` / `sync_project_files.rb`; no **`xcodebuild`** / unsolicited **`ci/local-build.sh`** for this pass.

### Record — DiaBLE observer alignment implementation (watch-only)

**Date:** 2026-04-13 23:31 CEST
**Worktree:** **`Trio`** — branch **`feature/watch-direct-ble-cgm`**. **Approval gate:** Docs updated first; watch code changed only after explicit approval in this cycle.

| Area | Outcome |
|------|---------|
| **Observer-mode BLE sequence** | **`G7DirectBLEManager.swift`** now follows the DiaBLE observer pattern on watch: auth notify first, **no auth-init write**, **no J-PAKE subscription**, passive `0x03` / `0x05`, require `authenticated=true bonded=true`, then enable control notify and send `0x4E`. |
| **Attach gating** | Direct BLE attach remains hard-gated by the phone-provided active sensor name. The watch does **not** connect to arbitrary Dexcom peripherals when the active-name filter is missing. |
| **Blocked-state instrumentation** | Added / retained explicit blocked-state lines for `g7_ble_attach_blocked reason=missing_active_sensor_filter`, `g7_ble_status_gate_blocked authenticated=<bool> bonded=<bool>`, and `g7_ble_egv_request_blocked reason=...` so observer stalls are visible without inference. |
| **Startup readiness** | `backfill` is no longer part of the observer startup happy path. Timeout cancellation / startup progress now treat **auth notify + `0x05 01 01` + control notify** as the direct-BLE readiness threshold for the initial `0x4E` path. |
| **Watch UI state** | After a successful direct-BLE save, **`WatchState.applyDirectBleSnapshot(_:)`** updates live watch glucose state immediately so the read reaches active watch UI state, not only the complication snapshot store. |
| **Existing debug view** | **`ComplicationDebugView.swift`** now includes the compact **`DIRECT BLE / G7 OBSERVER`** section in the existing debug screen with connection stage, observer/auth state, data state, timeout/reconnect/session diagnostics, and phone-relay status. |

**Verification mode (this pass):** Static review only. No agent-run `xcodebuild`, no `project.pbxproj` edits, and no agent-run project sync.

### Record — observer alignment code review feedback + follow-up fixes

**Date:** 2026-04-13 23:31 CEST
**Sources:** Regenerated scratch diff review under **`docs/code-review/feature-watch-direct-ble-cgm-code-review.md`** plus follow-up feedback from **ChatGPT** and a red-team / Cursor-style implementation review. This record closes the missing implementation-log entries for those current-cycle code reviews.

| ID | Source | Severity | Finding | Disposition |
|----|--------|----------|---------|-------------|
| **OA1** | ChatGPT | low | `didDiscover` still returned silently when the phone-provided active-sensor filter was missing, so discovery-time attach blocking was not explicit in logs. | **Fixed** — `didDiscover` now emits `g7_ble_attach_blocked reason=missing_active_sensor_filter source=did_discover` once per session/source instead of silently returning. |
| **OA2** | ChatGPT | low | `lastEgvRequestBlockedReason` could stay stale in the debug view after the observer flow recovered. | **Fixed** — blocked reason now clears when the status gate succeeds and again when control notify becomes ready / `0x4E` is sent. |
| **OA3** | Red-team | high | `isUsingPhoneRelayForCurrentWatchData` compared mixed timestamps (`WatchMessageKeys.date`, `snapshot.readingDate`, direct-BLE save wall clock), so the debug row could report the wrong source. | **Fixed** — `WatchState` now tracks **`currentWatchDataSource`** (`phoneRelay` vs `directBLE`) based on the last live update path instead of timestamp comparison. |
| **OA4** | Red-team | medium | The debug view could appear stale during soak if the direct-BLE rows only refreshed on manual interaction. | **Mitigated in code** — the existing debug view now auto-refreshes on a 1-second timer and reloads the latest snapshot while visible, in addition to the existing manual refresh button. |
| **OA5** | Red-team | low | `applyDirectBleSnapshot(_:)` forced `#ffffff` when the snapshot omitted `glucoseColor`, which could overwrite a prior color. | **Fixed** — direct-BLE watch-state updates now preserve the existing color unless the snapshot explicitly provides one. |
| **OA6** | Red-team | medium | Phone filter updates can intentionally rescan off an attached peripheral if the phone changes the active sensor name mid-session. | **Accepted / keep as designed** — this is the required wrong-sensor safety behavior for the watch observer path. Monitor reconnect frequency in soak. |
| **OA7** | Red-team | medium | Observer ordering / `0x05 bonded` timing and repeated `0x4E` behavior still need hardware validation on real Dexcom firmware. | **Open for soak only** — instrumentation is now explicit enough to validate on device; no additional code change in this pass. |

**Artifact note:** The scratch diff review doc remains **out of band** and transient. The authoritative initiative traceability for this cycle is this implementation log plus the design and instrumentation docs in **`docs/in-progress/watch-direct-ble-cgm/`**.

---

## Implementation log (execution)

### Phase G — cadence scheduler + cycle-relative timeout model (2026-04-19)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`**. **Verification:** static review only in the agent session; no agent-run **`xcodebuild`**, **`ci/local-build.sh`**, project sync, or `project.pbxproj` edits per **AGENTS.md** safety rules.

| Step | Done | Files | Notes |
|------|------|-------|-------|
| **G1** | Added cycle-scoped scheduler state, anchor selection, predicted-reading scheduling, cycle IDs, and scheduler-owned runtime gating in the watch BLE manager. Anchor priority now follows the tightened active implementation order: latest successful direct-BLE reading, latest saved complication snapshot reading, then latest trustworthy phone-relay reading already applied on watch. The first implementation pass does **not** use raw connect time as a cadence anchor because that proved too weak a proxy for a confirmed reading phase. **`applyForegroundActiveEntry(...)`** is now a thin scheduler-entry wrapper that applies the active-sensor filter, forwards cadence seed context, and lets the manager decide whether to bootstrap immediately, continue an in-flight cycle, or schedule the next predicted window. | `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/WatchState.swift` | Added Phase G cycle logs: **`g7_ble_cycle_anchor`**, **`g7_ble_cycle_scheduled`**, **`g7_ble_cycle_started`**, **`g7_ble_cycle_completed`**, **`g7_ble_cycle_missed`**, and **`g7_ble_runtime_gate`**. **`WatchState`** now seeds cadence state from the latest saved complication snapshot and trustworthy phone-relay reading already applied on watch, while **`G7DirectBLEManager`** owns anchor selection, runtime ownership, cycle execution, same-cycle retry policy, and cycle roll-forward scheduling. Complication-snapshot seed handling is now monotonic as well, so an older foreground-entry seed cannot regress an already newer in-manager anchor. Runtime ownership moved out of **`beginConnectToG7Peripheral(...)`** and into the cadence scheduler; the old generic reconnect loop was replaced with cycle-scoped same-cycle retry logic and cycle roll-forward scheduling. The follow-up runtime-gating pass now treats runtime as available only after **`extendedRuntimeSessionDidStart(...)`** confirms an active session, keeps cycles waiting in an explicit runtime-starting state while activation is pending, and classifies cycles that never reach active runtime by the hard-stop boundary as **runtime misses** instead of allowing attach to start on a mere `start()` request. |
| **G2** | Connect, GATT-setup, fallback, and first-read timeouts now run relative to the predicted cycle instead of fixed session-relative delays. Same-cycle retries are limited to one no-connect retry and one post-connect retry while the cycle is still inside grace. Existing passive auth/control observer behavior, authenticated-only passive gate, optional communication notify handling, and the bounded fallback **`0x4E`** path were preserved. | `Trio Watch App Extension/G7DirectBLEManager.swift` | Fallback timing is now tied to **`nextExpectedReadingDate`** (**earliest fallback `T+5s`**) rather than the passive-arm timestamp. The follow-up fix pass also made the cycle transition stricter: misses now clear old cycle state before roll-forward reschedule, forced passive-observation rearms reset per-cycle fallback / wait state, and same-cycle runtime reacquire is explicitly treated as foreground-only. Discovery scope remains unchanged in this pass; **`discoverServices(nil)`** / **`discoverCharacteristics(nil, for:)`** remain conditional **G3** work only after field logs show cadence-aware cycles are reaching connect more reliably. |

### Phase G shipped evidence — build 171 watch-only Better Stack review (2026-04-19)

- Build **171** is the shipped/live Phase G evidence point: watch-only Better Stack logs tagged **`build=171`** confirm that the cadence-aware scheduler and runtime gate are active on device.
- Search set used to reconstruct the shipped outcome:
  - grouped watch-only **`g7_ble_*`** counts by **`event`** for **`build=171`**
  - grouped **`g7_ble_runtime_gate`** by logged state
  - grouped **`g7_ble_cycle_anchor`**, **`g7_ble_pre_connect`**, and **`g7_ble_connect_attempt`** by source
  - grouped **`g7_ble_cycle_missed`**, **`g7_ble_timeout`**, and **`g7_ble_session_outcome`** by reason / final stage
  - expanded the event timeline for the live build-171 cycle/session trail
- Current build-171 watch-only counts from that search set:
  - **44** **`g7_ble_cycle_scheduled`**
  - **40** **`g7_ble_cycle_anchor source=snapshot`**
  - **9** **`g7_ble_cycle_started`**
  - **22** **`g7_ble_runtime_gate`** lines, including **`state=starting`**, **`active`**, **`active_waiting_for_lead_window`**, **`activation_timeout`**, and **`blocked_app_inactive`**
  - **5** **`g7_ble_connect_attempt source=retrieved_identifier`**
  - **5** **`g7_ble_timeout stage=awaiting_connect`**
  - **5** **`g7_ble_cycle_missed category=timing reason=timeout_awaiting_connect`**
  - **5** **`g7_ble_session_outcome outcome=timeout final_stage=connecting`**
  - **0** watch-side **`g7_ble_did_connect`**, **`g7_ble_connected`**, **`g7_ble_services_discovered`**, **`g7_ble_characteristics_discovered`**, **`g7_ble_auth_notify_enabled`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`**
- Operational interpretation from the shipped logs:
  - **Phase G is definitely shipped**: the live logs now show the new cycle-anchor, cycle-schedule, cycle-start, runtime-gate, cycle-miss, and cycle-outcome trail rather than the old generic reconnect-only shape.
  - The observed live anchor source is currently **`snapshot`**, which means the shipped cadence loop is seeding from the saved complication snapshot in the reviewed window.
  - The observed live attach path is currently **identifier retrieval**, not scan: every build-171 **`g7_ble_connect_attempt`** in the reviewed window used **`source=retrieved_identifier`**.
  - Runtime behavior is now explicit enough to reason about directly in production evidence: the shipped build logs show cycles waiting for runtime activation, cycles held until the lead window, some **`activation_timeout`** misses, and some **`blocked_app_inactive`** cases.
  - The current build-171 result does **not** yet satisfy the Phase G success metric. The scheduler/runtime boundary is live, but no observed cycle reached **`didConnect`**, so the boundary has not yet moved from **pre-connect timeout** to a later watch-side stage.
  - Therefore the post-171 work tracked in this document is **Phase H attach-context alignment** and the **Phase I** connection-event removal experiment, not further Phase G-only log refinement. **G3** discovery-scope widening is still conditional and not yet justified until **`didConnect`** is recovered.

### Phase H — attach-context alignment foundation (2026-04-20)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`**. **Verification:** static review only in the agent session; no agent-run **`xcodebuild`**, **`ci/local-build.sh`**, project sync, or `project.pbxproj` edits per **AGENTS.md** safety rules.

| Step | Done | Files | Notes |
|------|------|-------|-------|
| **H1** | Implemented then **disabled for Phase I**: connection-event registration and delegate remain in source as **commented blocks** (`registerForConnectionEventsIfNeeded`, call sites in **`startScanning()`** / **`centralManagerDidUpdateState`**, **`connectionEventDidOccur`**). Shipped **171** had this **enabled**; current tree matches **Phase I** (Build 177-class) removal until field evidence supports re-enabling. | `Trio Watch App Extension/G7DirectBLEManager.swift` | When uncommented, handler preserves active-sensor filter, duplicate suppression, cycle-generation guard, **`scanningStarted`** gate, and emits **`event=g7_ble_connection_event_fired ... source=connection_event`**. |
| **H2** | Replaced the old split connected-peripheral retrieval with one combined **`retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService, G7BLEUUID.advertisement])`** query and moved that live connected-peripheral path ahead of remembered-identifier retrieval in the attach order. | `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/Views/ComplicationDebugView.swift` | The current debug view now reports a single **Connected count** value instead of separate data-service / FEBC counts so the on-watch retrieval section matches the new combined retrieval path. |
| **H3** | Corrected retrieval-path pre-connect diagnostics so live connected retrieval no longer looks artificially insane in logs, and preserved the earlier round-robin experiment only as a fallback diagnostic rather than active code. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **`g7_ble_pre_connect`** now treats **`peripheral.state == .connected`** as sane for retrieval-derived sources (including **`connection_event`**), so Better Stack can distinguish the preferred live-connected path from a genuinely bad pre-connect context. |

### Phase I field evidence — builds 177, 178, 179 (2026-04-22)

#### Build 177 — `registerForConnectionEvents` removal (Phase I isolation)

**Date:** 2026-04-22  
**Hypothesis:** `registerForConnectionEvents` (H1, added in build 171) is the cause of the `didConnect` regression.  
**Change:** Commented out `registerForConnectionEventsIfNeeded(on:)` and `connectionEventDidOccur` at all four locations in `G7DirectBLEManager.swift`. No other changes.

**BetterStack result (2026-04-22):**
- `g7_ble_connection_event_fired` — **0** — removal confirmed active ✓
- `g7_ble_did_connect` — **0** — regression not resolved
- Every cycle ends `g7_ble_timeout stage=awaiting_connect`
- `g7_ble_retrieve_identifier_result stored_id_short=none` on every cycle — retrieval path never seeded; system permanently in scan-only regime
- Attach source distribution: 100% `source=scan`; scan-to-discovery latency 4–23s (faster than build 170's 40s, ruling out Phase G timing regression as the cause)

**Verdict:** `registerForConnectionEvents` was **not** the regression cause. Cleanly eliminated as a single variable. Secondary finding: `persistPeripheralIdentifier` is only called on `didConnect` (line 2356, `reason="did_connect"`). The persist-on-connect-attempt behavior from F10 — which seeded the retrieval chain in build 170 — was lost in the Phase G/H refactor. Since `didConnect` never fires, the identifier is never persisted, retrieval always returns empty, and the system is stuck in scan-only mode. Scan path has never produced `didConnect` in any build.

---

#### Build 178 — nil scan experiment

**Date:** 2026-04-22  
**Hypothesis:** FEBC-filtered `scanForPeripherals(withServices: [G7BLEUUID.advertisement])` vs DiaBLE's `nil` scan is causing CB to handle peripheral internal state differently at `connect()` time.  
**Change:** Both `scanForPeripherals` call sites changed to `withServices: nil`. Original lines preserved as comments. `registerForConnectionEvents` remains commented out from build 177.

**BetterStack result (2026-04-22):**
- `g7_ble_did_connect` — **0**
- Discovery latency and timeout behavior identical to build 177
- `stored_id_short=none` unchanged

**Verdict:** Nil scan made no difference. Eliminated. Scan filter is not the cause.

---

#### Build 179 — restore persist-on-connect-attempt

**Date:** 2026-04-22  
**Hypothesis:** Missing persist-on-connect-attempt is preventing the retrieval chain from being seeded, keeping the system permanently in scan-only mode. In build 170, F10 persisted the identifier on connect attempt (not just `didConnect`), which allowed the retrieval path to produce `didConnect`. In the current code `persistPeripheralIdentifier` is only called at `didConnect` — which never fires — so `stored_id_short=none` forever.  
**Change:** Added one line in `beginConnectToG7Peripheral` immediately after `central?.connect(peripheral, options: nil)`:

```swift
persistPeripheralIdentifier(peripheral.identifier, reason: "connect_attempt")
```

Nil scan from build 178 reverted.

**BetterStack result (2026-04-22):**
- `g7_ble_identifier_persisted reason=connect_attempt peripheral_id_short=5679a1ec` — firing correctly ✓
- Next cycle: `g7_ble_retrieve_identifier_result stored_id_short=5679a1ec count=1 first_name=DXCM08 first_state=0` — retrieval chain seeded ✓
- `g7_ble_retrieved_attach_selected source=retrieved_identifier` — retrieval attach path selected ✓
- `g7_ble_connect_attempt source=retrieved_identifier` — firing correctly ✓
- `g7_ble_did_connect` — **0** — even on the retrieval path with conditions identical to build 170 (rssi=0, peripheral_state=0, source=retrieved_identifier)
- Both scan-path and retrieval-path connect attempts end `timeout stage=awaiting_connect`
- `cbcentral_allocated_in_start_scanning=false` on every connect attempt
- `g7_ble_will_restore_state keys=kCBRestoredScanServices` firing — CB state restoration active

**Key finding:** Build 179 reproduced the exact attach conditions from build 170 on the retrieval path — same source, same rssi=0, same peripheral_state=0. In build 170 this produced `didConnect` in 5–80ms. In build 179 it times out at 45 seconds. The persist-on-connect-attempt fix was a necessary correctness fix (retrieval chain now functional) but did not resolve the underlying regression. `connect()` is accepted by CB and no callback is delivered — not `didConnect`, not `didFailToConnect`, not CB-originated `didDisconnect`. This is a structural CB callback delivery failure.

**Verdict:** Root cause remains unidentified. The regression is not `registerForConnectionEvents` (build 177), not scan filter (build 178), not identifier persistence (build 179). Something in the Phase G/H codebase — introduced between build 170 and build 171 — is causing CB to silently accept `connect()` without delivering any delegate callback.

**Active investigation questions (open as of 2026-04-22):**
1. Whether `central.delegate` is ever cleared or reassigned after `G7DirectBLEManager.init()`.
2. Whether `CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"` was present in build 170 or added later — `g7_ble_will_restore_state` firing in current builds may indicate CB state restoration is delivering callbacks to a stale/orphaned delegate rather than the current one.
3. Whether Phase G can cause a second `CBCentralManager` instance to be created via `ensureCentralManagerInitialized()`, orphaning the first instance's delegate.

### Phase I — Build 180: `willRestoreState` CB state restoration fix (2026-04-22)

**Hypothesis:** `CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"` (present since Phase F2 / build 164) causes watchOS to relaunch the app and restore CB's prior scan state internally. The prior `willRestoreState` handler was a no-op — it logged the dict keys and returned. When Phase G then called `connect()` on the retrieval-path peripheral, CB already had a pending connection attempt from the restored scan and silently swallowed the duplicate — no `didConnect`, `didFailToConnect`, or `didDisconnect` ever fires. This explains the complete CB callback silence on the retrieval path across builds 177–179.

**Supporting evidence:**
- `g7_ble_will_restore_state keys=kCBRestoredScanServices` fires in every session (appearing after connect attempts in BetterStack due to async Task logging delay, but actually fires synchronously during `CBCentralManager` init before any app scan/connect)
- `g7_ble_pre_connect source=retrieved_identifier` and `g7_ble_connect_attempt source=retrieved_identifier` confirm `connect()` IS being called — ruling out attach-path gating as the explanation
- `g7_ble_did_connect` — 0 across all builds 171–179 despite `connect()` being called

**Change:** `centralManager(_:willRestoreState:)` now:
1. Calls `central.cancelPeripheralConnection(peripheral)` for each peripheral in `CBCentralManagerRestoredStatePeripheralsKey`
2. Calls `central.stopScan()` to clear any restored scan state
3. Logs `event=g7_ble_will_restore_state keys=\(keys) restored_peripheral_count=\(N)`

**Status:** Deployed. BetterStack validation pending — success metric is `g7_ble_did_connect` appearing after `restored_peripheral_count` > 0 or `g7_ble_will_restore_state` in the same session.

**Static follow-up ([watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md), Part 1):** the flush is **correct** for the duplicate-`connect()` hypothesis, but **`cancelPeripheralConnection`** on restored peripherals can dispatch **`didDisconnectPeripheral`** (and, narrowly, **`didConnect`**) for objects **never assigned** to **`self.peripheral`**. Unguarded delegate paths risk spurious **`g7_ble_session_outcome`**, **`scheduleNextCycleAfterMiss`**, identifier **`persist`**, and **`discoverServices`** on the wrong peripheral. **Mitigation:** ship **peripheral-identity guards** and/or **`pendingDisconnectReason = will_restore_flush`** handling in **build 182** (see forward plan).

### Two-bug analysis — complementary root causes (2026-04-22)

Static code review (Claude Code, `watch-direct-ble-cgm-08-build-179-analysis.md`) identified a second independent bug alongside the `willRestoreState` race:

**Bug 1 (build 180):** `willRestoreState` no-op — addressed above.

**Bug 2 (build 181): exact-name mismatch — helper *and* `didDiscover` inline bypass ([09](watch-direct-ble-cgm-09-preconnect-review.md) Part 2 / Part 6)**

```swift
// Current — broken for retrieval paths (helper):
return (peripheral.name ?? "unknown") == active  // exact equality

// Fix — mirrors G7SensorKit G7Sensor.swift suffix(2) approach:
return name == active ||
       (name.count >= 2 && active.count >= 2 && name.suffix(2) == active.suffix(2))
```

**Blocker:** **`centralManager(_:didDiscover:…)`** applies a **separate** inline **`name != active`** exact compare and **does not call** **`doesPeripheralMatchActiveFilter`**. Updating the helper **alone** leaves **Path A (scan)** blocked — **build 181 must change both** (replace inline guard with **`doesPeripheralMatchActiveFilter(peripheral)`** or duplicate the suffix rule identically). **[09](watch-direct-ble-cgm-09-preconnect-review.md)** — Part 3 attach matrix; Part 5 priority (**hardening / gate fixes before H1**) is reflected here as **sequential builds 182 → 183** (retry then **`WKExtendedRuntimeSession`** gate) **→ 184** (H1) (not renumbered out of order).

The G7 advertises under two different name strings:
- **Advertising name** (`DXCMxx`): seen in `didDiscover` and `retrieveConnectedPeripherals`
- **Full name** (`DexcomXX`): OS-cached after a prior connection; returned by `retrievePeripherals(withIdentifiers:)`

`activePeripheralName` comes from the phone's sensor record as the full name (`DexcomXX`). Exact equality fails against `DXCMxx` on **both** the helper (Paths B/C) and the **`didDiscover`** gate (Path A). **`suffix(2)`** is the stable serial tail per G7SensorKit and DiaBLE; **`suffix(3)`** is incorrect across formats (**09** Part 2). Cold bootstrap when **`loadPersistedPeripheralIdentifier()`** is empty depends especially on **Path A** after **181**.

The regression additionally triggered a third issue: `setActivePeripheralName` clears the persisted identifier when the name changes. If Phase G's initialization path delivered the name with any format difference from build 170, the identifier was cleared, the retrieval chain was severed, and the scan path's name mismatch then kept it permanently empty.

**Fix plan:** **Build 181** — **one shipped change set**, not a single function: **`doesPeripheralMatchActiveFilter`** **+** **`didDiscover`** inline gate; optional **`match=exact|suffix`** logging per **09**.

### Forward plan — builds 181–186

**Build numbers follow strict ascending TestFlight sequence** (**181** then **182** …). Substance from **[watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)** Part 5 is preserved by mapping **“hardening before H1”** to **182** (retry) **→ 183** (**`WKExtendedRuntimeSession`** gate) **→ 184** (H1) (not to non-sequential labels).

| Build | Scope | Prerequisite | Status |
|-------|-------|-------------|--------|
| **181** | **Suffix(2)** in `doesPeripheralMatchActiveFilter` and same rule in `didDiscover`; optional exact vs suffix log — **deployed** | Build 180 deployed | **Deployed** |
| **182** | **G7SensorKit-style per-attempt retry loop**: 8 s per-attempt timeout; `didFailToConnect`→retry unless past `hardStopDate`; live scan during connect; per-attempt dedup clear; `cycleRelativeDelay` floor 5.0 s; red-team bug fixes — **deployed and field-validated** | Build 181 deployed | **Deployed** |
| **183** | **WKExtendedRuntimeSession gate removal**: `startScheduledCycleIfNeeded` and `scheduleRetryWithinCurrentCycle` no longer block scan on `.starting`/`.unavailable` — call `continueCurrentCycleExecution` in all cases; `armRuntimeActivationDeadlineIfNeeded` timeout handler changed to log-only. Session starts opportunistically; scan proceeds immediately regardless of session state. | Build 182 deployed | **Deployed and live** |
| **184** | Re-enable **`registerForConnectionEvents`** and **`connectionEventDidOccur`** together (H1) — additive attach path | Build 183 live (per **09** — avoid layering events before gate fix confirmed; **gate fix shipped in 183**) | Planned |
| **185** | **`willRestoreState`** fast-path — `restored_state` attach vs flush; `.connected` vs `.connecting` explicit | Build 183 guards in place | Planned |
| **186** | Background soak — `WKExtendedRuntimeSession` + `bluetooth-central`; `g7_ble_cycle_missed` / consecutive `foreground_unavailable` style observability per **09** Finding 6.6 | Foreground chain validated | Planned |

The previously planned build 183 (H1 re-enable) has shifted to build 184. Build 183 is now the `WKExtendedRuntimeSession` gate fix, which is higher priority because static analysis and the build 170 revert confirmed it is the primary reason Phase G builds cannot connect during daytime.

### Phase I — Build 181: `suffix(2)` name hygiene + skip `retrieved_identifier` dedup insert (2026-04-22)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`**. **Verification:** static review only in the agent session; no agent-run **`xcodebuild`**, **`ci/local-build.sh`**, project sync, or `project.pbxproj` edits per **AGENTS.md** safety rule 10. Patch stack unchanged — change lives only on the feature branch code, not in `patches/`.

**Hypothesis revision within this build window:** An earlier take on build 181 (see [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 2 and the v1.75 changelog entry) framed the primary failure as **name duality** — `DexcomXX` vs `DXCMxx` — blocking filtering. Field evidence from Better Stack for the first device surfaced a different picture and invalidated name-duality as the primary blocker for this device:

- `g7_ble_retrieve_identifier_result first_name=DXCM08` — CB caches the identifier-retrieved peripheral with the short name already.
- `activePeripheralName` for this account is `"DXCM08"` (phone already sends the short name), so the existing exact-equality compares already succeeded on this device.
- `g7_ble_connect_attempt source=retrieved_identifier rssi=0` → no `g7_ble_did_connect`, no `g7_ble_did_fail_to_connect`, no `g7_ble_did_disconnect` for ~20 s. The retrieval-identifier attach is firing `central.connect(_:options:)` on a CB-cached peripheral with **no recent advertisement** (`rssi=0`) — and on watchOS this call appears to silently produce no delegate callback.
- ~20 s later `centralManager(_:didDiscover:…)` observes the live `DXCM08` advertisement (real RSSI, e.g. `−83…−90`), enters `beginConnectToG7Peripheral(… source: "scan")` — and is suppressed by `attemptedConnectPeripheralIdentifiers` with `g7_ble_connect_suppressed reason=duplicate_peripheral_in_attach_cycle source=scan`. The only attach path that is actually reaching a usable peripheral reference on this device is being blocked by the in-cycle dedup set.

The revised primary hypothesis for build 181 is therefore **stale-reference retrieval attach** — not name duality. The suffix(2) change is **retained** as hygiene because the name-duality case is still real for other accounts whose phone sends `DexcomXX`; shipping both together keeps the build 181 scope to a single deploy.

**Changes — two shipped change sets:**

1. **Name-match hygiene (suffix(2)) — unchanged from v1.75.** Refactored `doesPeripheralMatchActiveFilter(_:)` from exact equality to an exact-or-**`suffix(2)`** rule, factored through a private `classifyPeripheralAgainstActiveFilter(_:)` helper returning `.none | .exact | .suffix`. Suffix rule mirrors G7SensorKit `G7Sensor.swift:250` and DiaBLE `BluetoothDelegate.swift:89–100`. For the first field device this is a **no-op** (phone-provided name already matches exactly); for accounts whose phone sends `DexcomXX`, this unblocks Paths B and C (retrieved-connected, retrieved-identifier) as originally planned.
2. **Scan-gate unification + `match=exact|suffix` log — unchanged from v1.75.** Replaced the inline `name != active` exact compare in `centralManager(_:didDiscover:advertisementData:rssi:)` with `classifyPeripheralAgainstActiveFilter(peripheral)`. Skip log adds `source=scan`; a new `event=g7_ble_peripheral_match_classified source=scan match=exact|suffix peripheral=<name>` is emitted at the successful match site for collision-surface analysis (per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 2 Finding 3).
3. **Skip the dedup-set insert for `source == "retrieved_identifier"` — new in v1.76.** In `beginConnectToG7Peripheral`, the early `attemptedConnectPeripheralIdentifiers.contains(...)` check is **unchanged** (so same-source duplicate suppression within a cycle still works). Only the subsequent `.insert(peripheral.identifier)` call is now conditioned on `source != "retrieved_identifier"`. All other sources — `scan`, `retrieved_connected`, `connection_event`, and `nil` — continue to insert as before.

    The intended outcome is that when the retrieval-identifier path fires its `central.connect(_:options:)` on the CB-cached (potentially `rssi=0`) peripheral and stalls silently, the subsequent `didDiscover` for the same peripheral on the live advertisement reference is **not** suppressed as `duplicate_peripheral_in_attach_cycle` and is instead allowed to call `central.connect(_:options:)` a second time on the live reference. If CB on watchOS internally dedups by peripheral UUID, the second connect is a harmless no-op; if CB prefers the live advertisement reference, `g7_ble_did_connect` should now arrive on the scan path. This is exactly the Better Stack experiment the field trace asks for.

**Files:** `Trio Watch App Extension/G7DirectBLEManager.swift` (helper refactor + scan-gate unification + conditional dedup-set insert). Full diff is scoped to this one file; no other code or patches touched.

**Scope guardrails preserved (per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 5 priority #1):**

- Phase G scheduler / runtime gating, Phase H2/H3 combined connected-peripheral retrieval order, Phase I `registerForConnectionEvents` commented-out state, and the build 180 `willRestoreState` flush are all unchanged.
- Early `attemptedConnectPeripheralIdentifiers.contains(...)` suppression (and the `g7_ble_connect_suppressed reason=duplicate_peripheral_in_attach_cycle` log it emits) is preserved unchanged — only the subsequent `.insert` is gated.
- Same-cycle dedup is still enforced for `scan`, `retrieved_connected`, and `connection_event`. The only source that now never marks itself as "attempted" is `retrieved_identifier`, which is the specific failure mode the field trace identifies.
- Minimal orphan-instance guards were added to all three CBCentralManagerDelegate connect-boundary callbacks — `didConnect`, `didFailToConnect`, and `didDisconnectPeripheral` — during red-team review (see **Red-team review** subsection below). The guards are required because change 2 deliberately puts two `central.connect(_:options:)` calls in flight for the same sensor UUID; without them the orphan retrieval-instance's late CB callback would either `teardownSession` the live scan-path session (fail/disconnect) or `persistPeripheralIdentifier` + `discoverServices` on the wrong instance (connect), in both cases invalidating the experiment. The `didConnect` guard was folded into build 181 as a completeness pass once the fail/disconnect guards were in — it does not broaden the experiment; it only prevents orphan CB callbacks from cross-wiring the tracked instance's state. Full identity-guard coverage across the CBPeripheralDelegate surface (service/characteristic discovery, notify state, write callbacks) remains build 182 scope per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 1 findings 5–6 and Part 6 finding 6.2.
- No `connect_attempt` persist change or `cycleRelativeDelay` floor (deferred to **build 182** per findings 6.3 / 6.11).
- No changes to `setActivePeripheralName` clear-on-change behavior.

**Acceptance verification (no-Xcode-compile, per AGENTS.md rule 10):**

- **Acceptance 1 (suffix(2) fallback in helper):** `doesPeripheralMatchActiveFilter(_:)` returns `classifyPeripheralAgainstActiveFilter(peripheral) != .none`, where the classifier returns `.exact` (strict equality) or `.suffix` (2-char tail match). Confirmed by re-reading lines ~1746–1786 after the edit.
- **Acceptance 2 (scan-gate uses helper / classifier):** `centralManager(_:didDiscover:…)` now calls `classifyPeripheralAgainstActiveFilter(peripheral)` in place of the prior inline `name != active` compare, and `g7_ble_peripheral_skipped reason=not_active_sensor source=scan` / `g7_ble_peripheral_match_classified source=scan match=exact|suffix peripheral=<name>` are the two possible outcomes at this site. Using the classifier directly (rather than the boolean `doesPeripheralMatchActiveFilter`) is required so the scan-path debug log can emit the `match=` kind; the underlying filter rule is identical to what the boolean helper returns. Confirmed by re-reading lines ~2392–2406.
- **Acceptance 3 (retrieval-identifier dedup insert skipped):** In `beginConnectToG7Peripheral`, `attemptedConnectPeripheralIdentifiers.insert(peripheral.identifier)` is now wrapped in `if source != "retrieved_identifier" { … }`. Other sources (`scan`, `retrieved_connected`, `connection_event`, `nil`) still insert. Confirmed by re-reading lines ~2218–2246.
- **Acceptance 4 (no duplicate-suppression of scan after retrieval attach):** Because `retrieved_identifier` no longer inserts its UUID into the dedup set, the scan-path `attemptedConnectPeripheralIdentifiers.contains(peripheral.identifier)` guard in `beginConnectToG7Peripheral` returns `false` for the same peripheral, so `g7_ble_connect_suppressed reason=duplicate_peripheral_in_attach_cycle source=scan` can no longer fire for a peripheral whose only prior attach in this cycle was `retrieved_identifier`. Verified by tracing the guard against all four `beginConnectToG7Peripheral` sources in the file.
- **Acceptance 5 (no other changes):** The three intended edits land exclusively in `Trio Watch App Extension/G7DirectBLEManager.swift`. During the red-team review, three additional defects directly activated by change 2 were identified and fixed in the same file per prompt 05's "default: review, report findings, and apply the required fixes" workflow — see the **Red-team review** subsection below for the scoped additions (orphan-instance guards on `didFailToConnect` / `didDisconnectPeripheral`, stricter nil-name / empty-filter classifier, stale reason-label rename). These are narrowly scoped to protect build 181's own acceptance criteria (specifically criterion 4) against a race the experiment introduces; they do not expand into build 182's deferred identity-guard work across the CBPeripheralDelegate surface. `ComplicationDebugView.swift` changes are pre-existing unrelated feature-branch work, not part of build 181.
- No patch stack touched — change is on the feature branch only; `scripts/patch-test.sh` is not required for this edit.
- **Deferred to build deploy:** Better Stack confirmation of the experiment, per the acceptance-5 outcome description in [09](watch-direct-ble-cgm-09-preconnect-review.md) framing — specifically:
    - Scan-path `g7_ble_connect_attempt source=scan` fires ~20 s into the cycle for the same peripheral ID as the prior `retrieved_identifier` attempt, without an intervening `duplicate_peripheral_in_attach_cycle` skip.
    - `g7_ble_did_connect` arrives on the scan path for the same `peripheral_id_short`. If `didConnect` fires on the scan path but not the retrieval path, the `rssi=0` cached-peripheral state is confirmed as the watchOS CB blocker.
    - The **user** runs the build via **`ci/local-build.sh`** when ready per AGENTS.md "When the user instructs a build".

**Deviation / open items:**

- The optional `match=exact|suffix` debug log was added at the `didDiscover` match site only; retrieval-path match sites still use their existing `g7_ble_retrieved_attach_selected` / `g7_ble_retrieve_identifier_result` attribution. Extending `match=` to retrieval sites is a low-value follow-up and can piggyback on build 182's logging pass if field data shows it is informative.
- Build 181 deliberately does **not** add a `retrieved_identifier rssi_eligibility` pre-gate (e.g. skipping the retrieval attach when the cached peripheral has no recent advertisement). That is an alternative mitigation if the double-`connect()` experiment shows CB **does** deduplicate internally — it would be considered for **build 182** once the experiment outcome is in hand.
- Build 181 does **not** change `persistPeripheralIdentifier(..., reason: "connect_attempt")` placement; a stale cached identifier can still be persisted on the retrieval path and is revisited in **build 182** per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 6 finding 6.3.

**Red-team review (iterations 1–3, 2026-04-22 17:25 CEST, prompt 05):**

The red-team review ran three adversarial passes against the build 181 changes on `feature/watch-direct-ble-cgm` in the `Trio` worktree, using the design ([01](watch-direct-ble-cgm-01-design.md)) and plan (this document v1.76) as the behavioural spec. Verification remained static-only per AGENTS.md rule 10 (no `xcodebuild`, no `ci/local-build.sh`).

- **Finding 1.1 — MAJOR — orphan retrieval-instance CB failure callback tears down the live scan-path session.** Change 2 intentionally leaves a `source=retrieved_identifier` `central.connect(_:options:)` in flight on a CB-retrieved `CBPeripheral` instance while the scan path issues a second `central.connect(_:options:)` on a fresh scan-discovered `CBPeripheral` instance for the same sensor UUID. `peripheral.delegate = self` is set on both instances. When CB eventually delivers a late `didFailToConnect` or `didDisconnectPeripheral` for the orphan retrieval instance (minutes later, after the scan-path session is already live and healthy), the existing delegate handlers did no identity matching and would run `teardownSession(reason: "connect_failed" | <error>, isFailure: true)` against the live scan-path session. This would silently destroy a working session and poison the Build 181 acceptance-criterion-4 signal (no `duplicate_peripheral_in_attach_cycle` for scan-path, `g7_ble_did_connect` arrives on scan-path). **Fix applied** — minimal instance-identity guards at the top of `centralManager(_:didFailToConnect:error:)` and `centralManager(_:didDisconnectPeripheral:error:)`: if `self.peripheral !== peripheral`, emit a scoped `g7_ble_did_fail_to_connect_ignored` / `g7_ble_did_disconnect_ignored` log with `reason=orphan_peripheral_instance`, `peripheral_id_short`, `tracked_peripheral_id_short`, `error_desc`, and return before touching any session state (timer cancels, `pendingDisconnectReason` override consumption, teardown). The guards compare by `===` because the same sensor UUID legitimately has two live CBPeripheral instances during change 2's experiment window; pointer identity is the correct discriminator. Legitimate failures of the tracked peripheral instance still flow through the normal path. A matching guard was folded into `centralManager(_:didConnect:)` in v1.78 as a completeness pass — see the v1.78 changelog entry. Full CBPeripheralDelegate identity-guard coverage (service/characteristic discovery, notify state, write callbacks) remains [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 6 finding 6.2 (build 182).
- **Finding 1.2 — MINOR — `classifyPeripheralAgainstActiveFilter` suffix-matches on `peripheral.name == nil` via the `"unknown"` fallback.** The initial Build 181 classifier used `let name = peripheral.name ?? "unknown"` before the `name.suffix(2) == active.suffix(2)` compare. Collision with a Dexcom `DXCMxx` / `DexcomXX` suffix is only avoided by coincidence. **Fix applied** — replaced the fallback with `guard let name = peripheral.name else { return .none }` and added `!active.isEmpty` to the activePeripheralName guard so any future caller that skips `hasActivePeripheralNameFilter` cannot silently suffix-match. All call sites (the boolean wrapper `doesPeripheralMatchActiveFilter` and the scan-gate `centralManager(_:didDiscover:…)`) were audited and pass with the stricter semantics.
- **Finding 1.3 — MINOR — stale reason label `missing_name_for_exact_match` in `attemptRetrievedAttachIfAvailable`.** Build 181 widens matching from exact-only to exact-or-suffix(2), so the `"_for_exact_match"` suffix in the reason label is no longer accurate. `rg missing_name_for_exact_match` confirmed the label lives in one live site only (the other matches are patch-stack / `build/worktree-patches-*` scratch regenerated from the feature branch). **Fix applied** — renamed to `missing_peripheral_name` with a short `// Build 181 …` comment; no Better Stack saved-query dependencies found.
- **Finding 1.4 — NIT — `PeripheralActiveFilterMatch.none.logValue = "none"` is unreachable.** `g7_ble_peripheral_match_classified` is gated on `matchKind != .none`. Left as-is; enum exhaustivity justifies the harmless `.none` case.

**Adversarial re-review passes (iterations 2 and 3):** no additional blocker or major findings. Confirmed that the orphan guard interacts safely with `pendingDisconnectReason` (override cases flow through the tracked instance, never orphan), that `scheduleConnectTimeout`'s silent cancel of the prior work item is pre-existing and unaffected, and that the classifier change does not regress any caller. Residual risks documented: (R1) orphan CBPeripheralDelegate callbacks remain build 182 scope; (R2) orphan CB pending connects are not actively cancelled and can accumulate per cycle — fixable in build 182 alongside the identity-guard expansion; (R3) operator interpretation — when two connect attempts target the same UUID in one cycle, the instrumentation trail-closure invariant from [03](watch-direct-ble-cgm-03-instrumentation-report.md) §305 applies to the *newer* attempt; the orphan's `g7_ble_connect_timeout_armed` is silently cancelled and the orphan's late fail/disconnect is routed to the `_ignored` variants.

**New log events introduced by this review:** `g7_ble_did_fail_to_connect_ignored`, `g7_ble_did_disconnect_ignored` (both with `reason=orphan_peripheral_instance`, `peripheral_id_short`, `tracked_peripheral_id_short`, `error_desc`). These are additive-only; dashboard continuity for the existing `g7_ble_did_fail_to_connect` / `g7_ble_did_disconnect` events is preserved for tracked-instance callbacks. The instrumentation report ([03](watch-direct-ble-cgm-03-instrumentation-report.md)) should be updated in a follow-up pass to reflect the new event names; build 181 itself is unchanged.

### Phase I — Build 182: G7SensorKit-style per-attempt retry loop (2026-04-22)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`**. **File:** `Trio Watch App Extension/G7DirectBLEManager.swift`. **Verification:** static review only; no `xcodebuild`, `ci/local-build.sh`, or `project.pbxproj` edits per AGENTS.md safety rule 10.

**Key insight:** G7SensorKit has no 5-minute timer. It uses a pure scan→connect→retry loop: on `didFailToConnect` or `didDisconnectPeripheral` → wait 2 s → scan again. The 5-minute reading cadence emerges from the G7 sensor itself opening a connection slot. Trio's Phase G `WKExtendedRuntimeSession` scheduler remains as the outer time boundary (`hardStopDate`), but inside the session window the BLE manager now mimics G7SensorKit's retry behavior instead of issuing a single long-timeout connect attempt.

**Changes:**

1. **Replace 45 s connect timeout with 8 s per-attempt timeout.** On fire: cancel `CBPeripheral` connection, clear `self.peripheral` and the dedup set. If still within `hardStopDate` → retry scan after 2 s delay (`g7_ble_scan_retry_scheduled`). If past `hardStop` → teardown.
2. **`didFailToConnect` → retry not teardown (all errors including code 11).** Only tears down when past `hardStopDate`. Prior behavior tore down the session on any connect failure.
3. **Remove `central?.stopScan()` from `beginConnectToG7Peripheral`.** Scan stays live while a connect attempt is in flight, so the manager can rediscover the sensor without restarting the scan cycle.
4. **Clear `attemptedConnectPeripheralIdentifiers` per-attempt** (in per-attempt timeout and in `didFailToConnect` before retry). The model is no longer single-attempt-per-session — the dedup set is reset each retry so the same peripheral can be reconnected.
5. **`cycleRelativeDelay` floor: 0.1 s → 5.0 s.** Prevents tight-loop retries at session window open.

**Bug fixes (red-team review, also in build 182):**
- `pendingDisconnectReason = "per_attempt_timeout_cancel"` set **before** `cancelPeripheralConnection` to prevent `didDisconnectPeripheral` from tearing down the retry loop.
- `guard connectionState == .connecting` at top of `handlePerAttemptConnectTimeout` to prevent race with `didConnect`.
- Generation capture around `await` suspension points in `handlePerAttemptConnectTimeout`.
- Retrieved-identifier path also inserts into the dedup set to prevent double-connect with live scan.
- `emitStageIfChanged("scanning")` called after per-attempt timeout to keep the stage stream accurate.

**New log events:**
- `g7_ble_per_attempt_timeout` — fires when the 8 s per-attempt timer expires
- `g7_ble_scan_retry_scheduled` — fires when retry is queued after timeout or fail (includes `attempt_count=N`)
- `attempt_count=N` field added to `g7_ble_connect_attempt`

**Success signal:** Multiple `g7_ble_connect_attempt` events within a single `g7_session` approximately 10 s apart. `g7_ble_did_connect` follows when a G7 connection slot opens.

**Status:** Deployed and field-validated (2026-04-23).

**BetterStack validation results:**
- Retry loop confirmed working: `g7_ble_connect_attempt attempt_count=2`, `attempt_count=3`, `attempt_count=4` observed across multiple cycles within a single `g7_session`.
- 8 s per-attempt timeout fires precisely. `g7_ble_scan_retry_scheduled delay_s=2` follows immediately. `g7_ble_scan_started` appears 2 s later.
- Second and subsequent attempts use `source=scan` with real RSSI (−85 to −88) and `is_connectable=true` — live advertisement path confirmed.
- `g7_ble_did_connect` = 0 during daytime foreground testing. Root cause: all 3 G7 BLE connection slots occupied during the day (Dexcom iPhone + Trio G7SensorKit + Dexcom watch app). The retry loop is correct; slot availability is the environmental constraint.
- DiaBLE watch app analysis on a separate device confirmed `is_connectable=true` on DXCM08 with manufacturer data `0604` (occupied session state), and DiaBLE itself connected but was immediately kicked with CBError 7 — confirming slot saturation, not a Trio-specific failure.

**Root cause identified during build 182 validation (→ build 183):** Build 170 revert run overnight produced 3 `did_connect` events (22:44, 02:34, third session) when competing apps were idle. Historical BetterStack records also show build 170 connecting at 14:59 on April 18 — mid-afternoon daytime — with the same BLE environment as builds 171–182. This proves slot competition is not the only factor. Static analysis of `G7DirectBLEManager.swift` confirmed the Phase G `WKExtendedRuntimeSession` gate is the code-level regression: `startScheduledCycleIfNeeded` only calls `continueCurrentCycleExecution` when `ensureRuntimeForCurrentCycle` returns `.active` — the `.starting` and `.unavailable` branches both skip scanning entirely. Build 170 source confirmed the correct model: `beginExtendedRuntimeSession()` was called inside `beginConnectToG7Peripheral` after `connect()`, with `extendedRuntimeSessionDidStart` logging only. Scanning was unconditional.

### Phase I — Build 183: WKExtendedRuntimeSession gate removal (2026-04-23)

**Worktree:** `Trio` — branch `feature/watch-direct-ble-cgm`. **File:** `Trio Watch App Extension/G7DirectBLEManager.swift`. **Verification:** static analysis confirmed before implementation; see Q1–Q6 analysis from 2026-04-23 session.

**Root cause:** `WKExtendedRuntimeSession` was acting as a gate on `startScanning()` rather than as a runtime extender. Two code paths blocked scan: (1) `startScheduledCycleIfNeeded` — `.starting` and `.unavailable` branches return without calling `continueCurrentCycleExecution`; (2) `scheduleRetryWithinCurrentCycle` — same. When `isForegroundActive == false` at lead-window open, `ensureRuntimeForCurrentCycle` returns `.unavailable` and the cycle is missed without a single `scanForPeripherals` call. Build 170 source confirmed the correct model: session started after `connect()`, not before `startScanning()`.

**Changes:**

1. **`startScheduledCycleIfNeeded`** — `.starting` and `.unavailable` branches now call `continueCurrentCycleExecution(trigger:)` instead of returning. Log actions updated: `action=scan_while_runtime_starting` (was: `action=await_runtime_activation`) and `action=scan_without_extended_runtime` (was: cycle miss). `scheduleNextCycleAfterMiss` removed from `.unavailable` branch.
2. **`scheduleRetryWithinCurrentCycle`** — `.starting` and `.unavailable` branches fall through to `self.startScanning()` instead of returning. `scheduleNextCycleAfterMiss` removed from `.unavailable` branch.
3. **`armRuntimeActivationDeadlineIfNeeded` timeout handler** — changed from `scheduleNextCycleAfterMiss(reason: "runtime_unavailable")` to log-only: `event=g7_ble_runtime_activation_timeout note=scan_already_in_progress generation=N`.

**What is unchanged:** `ensureRuntimeForCurrentCycle` still calls `beginExtendedRuntimeSession()` opportunistically and returns `.starting`/`.unavailable`/`.active` — its return value is now advisory only, not a gate. `extendedRuntimeSessionDidStart` still calls `resumeCurrentCycleAfterRuntimeActivation` — `continueCurrentCycleExecution` hits `if scanningStarted { return }` and no-ops cleanly. `extendedRuntimeSession(_:didInvalidateWith:error:)` teardown on `.error` unchanged. Build 182 retry loop unchanged.

**New log events:**
- `g7_ble_cycle_started action=scan_while_runtime_starting` — session start in flight, scan proceeds anyway
- `g7_ble_cycle_started action=scan_without_extended_runtime` — session unavailable, scan proceeds anyway
- `g7_ble_runtime_activation_timeout note=scan_already_in_progress` — replaces cycle miss on activation timeout

**Acceptance criteria (BetterStack):**
1. `g7_ble_scan_started` appears in cycles where `g7_ble_ext_session_started` is absent or late
2. `g7_ble_cycle_missed category=runtime reason=runtime_unavailable` drops to zero from `blocked_app_inactive`
3. `g7_ble_connect_attempt` appears during daytime foreground testing
4. No double `g7_ble_scan_started` within a single `g7_session`
5. `g7_ble_runtime_gate state=blocked_app_inactive` still logs for observability but no longer causes a cycle miss

**BetterStack — initial build-183 field slice (2026-04-23, Trio source, hot + reviewed window):**
- **Coverage:** `build=183` lines present from **19:04 UTC** through at least **20:34 UTC** the same day (~2k build-tagged lines in the queried window), confirming the build is **live in field telemetry**.
- **Structured G7 direct-BLE events (`g7_ble_*` prefix):** **15** lines in the reviewed window, including **`event=g7_ble_cycle_anchor`**, **`event=g7_ble_cycle_scheduled`** (phone relay and foreground), **`event=g7_ble_lifecycle`** (active / inactive / background with `ble_continues=true` where applicable), **`event=g7_ble_peripheral_match_classified source=scan match=exact`**, and **`event=g7_ble_connect_suppressed reason=duplicate_peripheral_in_attach_cycle source=scan`**. This confirms the **post-183** watch path is still **scheduling cycles**, still **classifying** scan-path peripheral matches, and still **deduping** a second `connect` when the same peripheral is seen twice in an attach cycle — i.e. the **instrumented attach surface** is live on build 183.
- **Not observed in this narrow slice:** `g7_ble_connect_attempt`, `g7_ble_scan_started`, or the new **`g7_ble_cycle_started action=scan_while_runtime_starting` / `scan_without_extended_runtime`** / **`g7_ble_runtime_activation_timeout`** strings — so items **(1)–(3)** and **(5)** of the acceptance list above are **not yet closed** from this first-day sample (timing, session shape, or query window). **Extended soak and/or a wider time range (including S3) remains** to validate the full gate-removal effect against the list.

**Status:** **Deployed and live** (TestFlight / device). **Full** BetterStack validation against the acceptance list **in progress** (initial slice above).

### Phase E — pre-connect parity (prompt 04, 2026-04-14)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`** (expected). **Verification:** static review of `G7DirectBLEManager.swift`; **`./scripts/patch-test.sh`** in **`Trio-dev`** (patches **01–11** apply cleanly — does **not** compile the edited `Trio` worktree). **No** `xcodebuild` / **`ci/local-build.sh`** per **AGENTS.md** safety rule 10.

| Step | Done | Files | Notes |
|------|------|-------|-------|
| **E1** | **`event=g7_ble_pre_connect`** with `peripheral_state`, `central_state`, `source` (`scan` \| `retrieved`), `first_attempt`, `preserved_session`, **`is_connectable=true|false|unknown`** (from **`CBAdvertisementDataIsConnectable`** on the scan path; **`unknown`** when the peripheral came from retrieval), **`discover_count_for_target=<n>`** (how many times the active-name-matched peripheral was seen in **`didDiscover`** this session before this connect — reset in **`startScanning()`**), **`peripheral_id_short=<last8>`** (last 8 hex digits of **`CBPeripheral.identifier`** without dashes), **`cbcentral_allocated_in_start_scanning=true|false`** (**`true`** only when **this** **`startScanning()`** call allocated **`CBCentralManager`** — not “fresh for this connect” when **`applyForegroundActiveEntry`** preserved the session and skipped **`startScanning()`**). **`g7_ble_peripheral_discovered`** and **`g7_ble_retrieve_on_powered_on`** include **`peripheral_id_short`** where applicable (**`none`** when no peripheral on retrieve). **`g7_ble_pre_connect`** is logged via fire-and-forget **`Task { await logG7Ble(…) }`**, then **`central?.connect(_:options:)`** runs **synchronously on the same call path**; **`scheduleConnectTimeout()`** runs **after** **`connect()`** so the awaiting-connect timer starts when the connect is actually issued. Counters: **`connectAttemptsSinceStartScanning`** (reset in **`startScanning()`**), **`sessionPreservedAcrossForegroundReentry`** (set when **`applyForegroundActiveEntry`** skips full restart; cleared on **`startScanning()`**). **`didDiscover`** passes **`source: "scan"`**. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **Revision:** initial Phase E wrap of **`connect()`** inside an async **`Task`** was reverted per review — connect must not be deferred behind a task hop. **v1.37:** connect-context fields **`is_connectable`**, **`discover_count_for_target`**, **`peripheral_id_short`**, **`manager_fresh`**. **v1.38:** field renamed to **`cbcentral_allocated_in_start_scanning`**; **`retrieveConnectedPeripherals`** uses **GATT data service** UUID (see **E2**). |
| **E2** | **`g7_ble_retrieve_on_powered_on`** after **`retrieveConnectedPeripherals`** in **`centralManagerDidUpdateState(.poweredOn)`**; **`retrieveConnectedPeripherals(withServices: [G7 data service UUID])`** — **not** the **`FEBC`** advertisement UUID (CoreBluetooth matches connected **GATT** services; **`FEBC`** remains the **`scanForPeripherals`** filter). Retrieve runs before **`scanForPeripherals`** (DiaBLE-style); scan starts only when retrieval does not attach. Same attach / filter rules as **`startScanning()`** retrieve path; **`emitAttachBlockedIfNeeded(source: "powered_on_retrieve")`**. | same | **Revision:** scan-after-retrieve ordering per review. **v1.38:** retrieval service UUID corrected to GATT data service. |
| **E3** | **`CBCentralManagerOptionRestoreIdentifierKey: "TrioG7DirectBLE"`** on manager init; **`centralManager(_:willRestoreState:)`** → **`g7_ble_will_restore_state`**. | same | |

### Phase F — connect-boundary parity execution (2026-04-14)

**Worktree:** `Trio` — branch **`feature/watch-direct-ble-cgm`**. **Verification:** build / deploy executed via **`ci/local-build.sh --base-branch dev --include-untracked`** (no direct **`xcodebuild`**), with watch-only **`g7_ble_*`** log review as the active Phase F evidence path. The Phase F execution trail now runs through **build 170 / F10**: build **166 / F4** provided the first watch-side **`didConnect`** / **`connected`** evidence in this cycle, build **168 / F5** sharpened the pre-connect attribution trail, and build **170** is now the last attach-context-era execution point before the initiative shifts to **Phase G**. **PacketLogger / raw capture** remains deferred while the current watch-only logs still provide actionable boundary movement.

| Step | Done | Files | Notes |
|------|------|-------|-------|
| **F1** | Added **`g7_ble_connect_timeout_armed`**, **`g7_ble_connect_timeout_canceled`**, **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, and **`g7_ble_did_disconnect`** in **`G7DirectBLEManager`** while keeping **`g7_ble_connect_attempt`**, **`g7_ble_connected`**, **`g7_ble_connect_failed`**, **`g7_ble_disconnected`**, and **`g7_ble_timeout`** unchanged. **`g7_ble_did_disconnect`** is emitted at the delegate boundary before the **`startScanning_rescan`** early return. Timeout cancellation reasons are restricted to **`did_connect`**, **`did_fail_to_connect`**, **`teardown`**, **`startScanning_rescan`**, and **`stop_requested`**. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **Build 163:** deployed and reviewed. The connect trail is now closed on the watch path: **`g7_ble_connect_attempt -> g7_ble_connect_timeout_armed -> g7_ble_timeout stage=awaiting_connect`**. No watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, or **`g7_ble_did_disconnect`** arrived before timeout; retrieval remained empty, so proceed to **F2**. |
| **F2** | Changed **`CBCentralManager(delegate:queue:options:)`** from **`queue: .main`** to **`queue: nil`** with no manager-option, scan-option, retrieval, or service-discovery changes in the same build. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **Build 164:** deployed successfully via **`ci/local-build.sh --base-branch dev --include-untracked`** and processed in TestFlight with changelog applied. Expanded watch-only Better Stack review now covers **7** distinct connect attempts and shows **no** watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, or **`g7_ble_connect_timeout_canceled`**; every completed attempt still ends **`g7_ble_timeout stage=awaiting_connect`** → **`g7_ble_disconnected reason=timeout_awaiting_connect`**. |
| **F3** | Removed **`CBCentralManagerScanOptionAllowDuplicatesKey: false`** from both watch scan call sites by passing **`options: nil`** while keeping the **FEBC** service filter and all existing **F1/F2** logging unchanged. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **Build 165:** built via **`ci/local-build.sh --base-branch dev --include-untracked`**, uploaded, processed, and distributed to internal testers. The completed watch-only Better Stack review is **negative** across **9** observed connect attempts: all still end at **`g7_ble_timeout stage=awaiting_connect`** with no watch-side connect/fail/disconnect or EGV/snapshot milestone. |
| **F4** | Moved **`CBCentralManager`** allocation earlier so **`G7DirectBLEManager.init()`** now creates the manager and **`startScanning()`** normally reuses that already-lived instance. Preserved **`queue: nil`**, restore identifier, retrieval behavior, and existing logging. | `Trio Watch App Extension/G7DirectBLEManager.swift` | **Build 166:** live and reviewed. Build **166** shows the first watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`**, but still no watch-side service / characteristic / auth / control / EGV / snapshot milestone. |
| **F5** | Added dual-UUID retrieval diagnostics, explicit retrieval-source labels, duplicate-connect suppression within an attach cycle, tighter pre-connect attribution, and post-connect callback probes; shipped together with the expanded watch debug-view section already described in **Task C1b**. | `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/Views/ComplicationDebugView.swift`, `Trio Watch App Extension/Views/GlucoseChartView.swift`, `Trio Watch App Extension/Views/GlucoseTrendView.swift`, `Trio Watch App Extension/Views/TrioMainWatchView.swift` | **Build 168:** live and reviewed. The new instrumentation is visible in Better Stack, the debug-view changes shipped with the same build, and the current live result is still pre-connect: retrieval remains empty on both UUID paths and no build-168 session has crossed **`didConnect`** yet. |
| **F10** | Added identifier-first retrieval before service-based retrieval / scan and then carried that baseline forward into the later passive-first watch observer/lifecycle cleanup. | `Trio Watch App Extension/G7DirectBLEManager.swift`, `Trio Watch App Extension/WatchState.swift`, `Trio Watch App Extension/Views/ComplicationDebugView.swift` | **Build 170:** deployed and now treated as the last attach-context-era execution point before **Phase G**. The build-170 baseline includes identifier-first retrieval, the passive-first observer-path cleanup, warning-only **`extendedRuntimeSessionWillExpire(...)`**, and reconnect after disconnect / failed connect unless teardown was explicit control flow. The interpretation is not that attach-context is solved, but that the watch path is now clean enough that cadence-aware scheduling is the higher-value next move. |

**Phase F build evidence**

| Build | Scope | Outcome | Next |
|------|-------|---------|------|
| **163** | **F1 only** | Watch-only logs closed the connect trail and confirmed the stall is still **pre-connect / callback-delivery**: target selection and pre-connect state looked sane, but there was no watch-side **`didConnect`**, **`didFailToConnect`**, or **`didDisconnect`** before the 30 s timeout. | Proceed to **F2** |
| **164** | **F2 only** (`queue: nil`) | Successfully built, uploaded, processed, and tagged for release. Expanded watch-only Better Stack review now shows **7** distinct build-164 connect attempts: target and pre-connect state remain sane (`DXCMKo` / `fbb0eda7`, `peripheral_state=0`, `central_state=5`), but there are still **no** watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, or **`g7_ble_connect_timeout_canceled`** events. All completed attempts still terminate as **`g7_ble_timeout stage=awaiting_connect`** followed by **`g7_ble_disconnected reason=timeout_awaiting_connect`**, so **`queue: nil`** did **not** materially change the watch-side stall. | Proceed to **F3** |
| **165** | **F3 only** (omit duplicate-suppression scan option) | Successfully built, uploaded, processed, and distributed to internal testers. Completed watch-only Better Stack review is **negative** across **9** observed connect attempts, all still timing out at **`awaiting_connect`** with no watch-side connect/fail/disconnect or EGV/snapshot milestone. | Proceed to **F4** |
| **166** | **F4 only** (early `CBCentralManager` allocation parity) | IPA archive/export/upload succeeded and live watch logs tagged **`build=166`** confirm deployment. Watch-only Better Stack review now shows **17** connect attempts, including **1** retrieval-assisted watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`** and one session that moved to **`g7_ble_timeout stage=awaiting_gatt_setup`** with **`final_stage=discovering_services`**. The other **16** attempts still terminate at **`awaiting_connect`**, and there are still **0** watch-side service / characteristic / auth / control / EGV / snapshot milestones in build **166**. | Proceed to **F5** next; keep **F9** as analysis context and choose **F6** or **F7** only after **F5** closes the post-connect trail |
| **168** | **F5 only** (post-connect attribution closure + dual-UUID retrieval diagnostics) | IPA archive/export/upload succeeded and live watch logs tagged **`build=168`** confirm deployment. The F5 instrumentation is active in Better Stack, including **`retrieval_uuid=data_service|febc`** result lines, explicit **`source=scan|retrieved_*`** attribution, **`peripheral_state`** / **`peripheral_id_short`** on pre-connect, and the new post-connect callback probes. The current de-duplicated watch-only build-168 review shows **17** connect attempts, all **`source=scan`**, **18** zero-result retrieval observations on both **data service** and **FEBC**, and **0** watch-side **`g7_ble_did_connect`** / service / characteristic / auth / control / EGV / snapshot milestones. Every observed completed attempt still ends at **`g7_ble_timeout stage=awaiting_connect`** with **`g7_ble_session_outcome outcome=timeout final_stage=connecting`**. | Keep **F9** active; do **not** promote **F6** or **F7** until a later session actually crosses **`didConnect`** again |
| **170** | **F10 + watch passive-path/lifecycle follow-ups** | Build **170** is now the current watch baseline and the last attach-context-era execution point before the plan shifts to **Phase G**. The baseline now includes identifier-first retrieval, the passive-first observer-path cleanup, warning-only **`extendedRuntimeSessionWillExpire(...)`**, and reconnect after disconnect / failed connect unless teardown was explicit control flow. The key interpretation is not that attach-context is solved, but that the watch path is now clean enough that the dominant remaining problem is better modeled as mostly mistimed pre-connect attempts plus some post-connect runtime / GATT fragility. | Proceed to **Phase G** |

**Build 165 watch-only Better Stack review (completed 2026-04-16):**

- Distinct watch-side connect attempts now recorded in build **165**: **9**.
- All observed build-165 connect attempts still target **`DXCMKo`** / **`peripheral_id_short=fbb0eda7`** and show sane pre-connect fields (`peripheral_state=0`, `central_state=5`).
- All observed build-165 attempts terminate as **`g7_ble_timeout stage=awaiting_connect`** followed by **`g7_ble_session_outcome outcome=timeout final_stage=connecting`**.
- Build **165** still shows **0** watch-side **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, **`g7_ble_connect_timeout_canceled`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`** events.
- That completed build-165 review is the baseline used for the current build-166 comparison.

**Build 166 watch-only Better Stack review (2026-04-16):**

- Build **166** is live in production evidence: watch-only Better Stack logs tagged **`build=166`** confirm the deploy after the local build/archive/export/upload succeeded.
- Search set used to reconstruct the outcome:
  - grouped watch-only **`g7_ble_*`** counts by **`build`** and **`event`**
  - grouped **`g7_ble_session_outcome`** by **`final_stage`**
  - grouped **`g7_ble_timeout`** by **`stage`**
  - grouped **`g7_ble_connect_attempt`** by **`source=scan|retrieved`**
  - expanded the full event timeline for the only build-166 session that emitted **`g7_ble_did_connect`**
- Current counts from that search set:
  - **17** build-166 watch-side **`g7_ble_connect_attempt`**
  - **1** build-166 **`g7_ble_did_connect`**
  - **1** build-166 **`g7_ble_connected`**
  - **1** build-166 **`g7_ble_connect_timeout_canceled reason=did_connect`**
  - **16** build-166 **`g7_ble_timeout stage=awaiting_connect`**
  - **1** build-166 **`g7_ble_timeout stage=awaiting_gatt_setup`**
  - **16** build-166 **`g7_ble_session_outcome final_stage=connecting`**
  - **1** build-166 **`g7_ble_session_outcome final_stage=discovering_services`**
- The single moved session was retrieval-assisted:
  - **`g7_ble_retrieve_result count=1`**
  - **`g7_ble_retrieved_connected peripheral=DXCMKo`**
  - **`g7_ble_connect_attempt source=retrieved`**
  - **`g7_ble_did_connect`**
  - **`g7_ble_connected`**
  - **`g7_ble_connect_timeout_canceled reason=did_connect`**
  - **`g7_ble_stage stage=discovering_services`**
  - later **`g7_ble_timeout stage=awaiting_gatt_setup`**
  - later **`g7_ble_session_outcome outcome=timeout final_stage=discovering_services`**
- No build-166 watch-side **`g7_ble_services_discovered`**, **`g7_ble_characteristics_discovered`**, **`g7_ble_auth_notify_enabled`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_egv_request_sent`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`** events have appeared yet.
- The current interpretation is therefore narrow: **F4 moved the boundary at least once**, but build **166** still does **not** prove a completed watch CGM read.

**Build 168 watch-only Better Stack review (2026-04-18):**

- Build **168** is live in production evidence: watch-only Better Stack logs tagged **`build=168`** confirm the deploy after the local build/archive/export/upload succeeded.
- Search set used to reconstruct the current outcome:
  - grouped de-duplicated watch-only **`g7_ble_*`** counts by **`event`**
  - grouped de-duplicated **`g7_ble_connect_attempt`**, **`g7_ble_pre_connect`**, and **`g7_ble_peripheral_discovered`** by **`source`**
  - grouped de-duplicated **`g7_ble_retrieve_result`** lines by **`retrieval_uuid`** and **`count`**
  - searched for any build-168 watch-side **`g7_ble_did_connect`**, **`g7_ble_did_discover_services`**, **`g7_ble_did_discover_characteristics`**, and later observer milestones
- Current de-duplicated build-168 counts from that search set:
  - **17** build-168 watch-side **`g7_ble_connect_attempt`**
  - **17** build-168 **`g7_ble_pre_connect`**
  - **17** build-168 **`g7_ble_timeout stage=awaiting_connect`**
  - **17** build-168 **`g7_ble_session_outcome outcome=timeout final_stage=connecting`**
  - **18** build-168 **`g7_ble_retrieve_result retrieval_uuid=data_service count=0`**
  - **18** build-168 **`g7_ble_retrieve_result retrieval_uuid=febc count=0`**
  - **0** build-168 **`g7_ble_connect_attempt source=retrieved_data_service`**
  - **0** build-168 **`g7_ble_connect_attempt source=retrieved_febc`**
  - **0** build-168 **`g7_ble_retrieved_attach_selected`**
  - **0** build-168 **`g7_ble_did_connect`**
  - **0** build-168 watch-side service / characteristic / auth / control / EGV / snapshot milestones
- Pre-connect shape remains consistent in build **168**:
  - connect attempts still target the same peripheral identity (**`DXCM08`** / **`peripheral_id_short=5679a1ec`**)
  - pre-connect state remains sane on the scan path (**`peripheral_state=0`**, **`central_state=5`**, **`is_connectable=true`**)
  - **`preserved_session=true`** still appears on some attempts, but it does not change the outcome
- Interpretation:
  - **F5 succeeded as an attribution build**
  - the current live issue is still **pre-connect**
  - the new retrieval lane is now more explicit: in build **168** so far, retrieval is not merely weaker than scan; it is producing **no** candidates at all on either UUID path
  - because build **168** has not reached **`didConnect`**, the new post-connect attribution lines have not yet been exercised in live volume

**Build 170 baseline and interpretation (2026-04-19):**

- Build **170** is the current watch baseline and the final attach-context-era execution point before the active plan shifts to **Phase G**.
- That baseline now includes passive auth observation, the authenticated-only passive gate, control notify, optional communication notify, passive-first observation, bounded fallback **`0x4E`**, warning-only **`extendedRuntimeSessionWillExpire(...)`**, and reconnect after disconnect / failed connect unless teardown was explicit control flow.
- The protocol-path cleanup has improved the observer path, but it does not change the higher-level interpretation: the dominant blocker is still likely timing and runtime / GATT startup reliability rather than another blind attach-context tweak.

**Build 170 watch-only Better Stack findings (2026-04-19):**

- Search scope: watch-only **`g7_ble_*`** lines with **`build=170`** in Trio logs.
- Observed **90** watch-side **`g7_ble_connect_attempt`** events in build **170**.
- Source split is now strongly identifier-led: **88** connect attempts use **`source=retrieved_identifier`**, while only **2** use **`source=scan`**.
- The attach-context change is no longer purely theoretical in logs: build **170** shows **13** watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`** pairs, **5** **`g7_ble_services_discovered`** events, and **3** **`g7_ble_characteristics_discovered`** events.
- The post-connect trail still collapses early: only **2** **`g7_ble_auth_notify_enabled`** lines appear, while there are **0** **`g7_ble_status_reply`**, **`g7_ble_control_notify_enabled`**, **`g7_ble_passive_observation_armed`**, **`g7_ble_egv_fallback_sent`**, **`g7_ble_egv_received`**, or **`g7_ble_snapshot_saved`** events.
- Runtime invalidation remains prominent in build **170**: **52** **`g7_ble_ext_session_invalidated`** lines include the same watchOS rejection text, **`The app must be active and before applicationWillResignActive to start or schedule a WKExtendedRuntimeSession.`**
- Short interpretation: build **170** does show more successful attach-context movement than build **168**, especially through identifier retrieval, but it still does not reach a usable glucose-read path. The evidence now points more strongly to timing/runtime/GATT startup reliability than to another blind attach-context tweak.

**Planned next sequence after build 170 (historical note executed by build 171)**

- Historical note: this planned next sequence was executed by **Phase G shipment in build 171**. The bullets below are preserved as the pre-ship decision record.
- **Phase G** is now the active next step. The current watch path is clean enough that cadence-aware scheduling is the higher-value next move.
- **F9** remains a conditional interpretation lane if later Phase G evidence needs retrieved-vs-scan analysis.
- **F11** remains a later attach-context candidate only if Phase G results point back toward attach-context weakness rather than timing/runtime.
- **F6** and **F7** remain conditional only if a future cadence-aware build reaches **`didConnect`** reliably but still exposes a clean post-connect discovery boundary.
- **PacketLogger / raw capture** remains conditional escalation, not the active top-level path.

**Build 164 watch-only Better Stack re-check (2026-04-15):**

- Distinct watch-side connect attempts now recorded: **7** (`C016E31E-4AFE-4F82-A0BD-D6134409511D`, `DC907C34-E658-46FA-BEB7-1337B4CC5617`, `6A3BF4CB-98E9-4C0A-A450-5741D68F9CF2`, `F43FC4FE-1325-495A-8541-C13BFD7FC1D6`, `F6125D5F-0D44-491E-BC4A-23862A4469EE`, `851C775A-8207-44C4-AFE9-81264AA55918`, `4297231B-AF7A-4B09-94B8-2D18A577540F`).
- Every completed attempt still targets **`DXCMKo`** / **`peripheral_id_short=fbb0eda7`** and shows sane pre-connect fields (`peripheral_state=0`, `central_state=5`).
- One attempt used **`source=retrieved`**; the others used **`source=scan`**. The retrieved path did not improve the outcome.
- Most first terminal events occur at **31–32 s**, but later attempts stretched to **49 s** and **180 s** before the first terminal watch-side timeout/disconnect pair. This changes observed timeout timing, not the callback outcome.
- Primary evidence remains watch-only. iPhone logs are not used as proof of watch connection success.

### WatchState — WC / direct-BLE merge hardening (2026-04-14)

**Worktree:** **`Trio`** — **`WatchState.swift`**.

| Item | Change |
|------|--------|
| **Stale WC → active G7 filter** | **`applyPhoneActiveG7PeripheralNameIfPresent`** runs only after **`scheduleUIUpdate`** passes the same **`WatchMessageKeys.date`** monotonic gate as the rest of the payload (not before). Removed eager application from **`didReceiveUserInfo`** and **`didReceiveApplicationContext`** pre-validation paths. **`finalizePendingData`** still applies from merged **`pendingData`** after debounce. |
| **Direct BLE vs WC monotonic** | **`applyDirectBleSnapshot`** no longer writes **`lastWatchStateUpdate`** (phone ordering). **CGM reading time** replay guard: **`lastDirectBleAppliedReadingDate`** (**`private(set)`**), updated from direct BLE and from **phone relay** **`processRawDataForWatchState`** via **`resolveEffectiveCGMReadingDate`** (**`max`** merge), so older/replayed direct-BLE EGV cannot clobber UI and a partial BLE update does not block a richer WC payload for the same reading era. |
| **Phase G cadence seed handoff** | **`WatchState`** now tracks **`lastPhoneRelayAppliedReadingDate`** separately from the merged direct-BLE replay guard and forwards both **phone-relay** and **complication snapshot** reading dates into **`G7DirectBLEManager.applyForegroundActiveEntry(...)`** as Phase G cadence seed context. |
| **Main watch UI freshness (Codex P1, v1.39)** | **`lastWatchStateUpdate`** remains **WC-only** for **`scheduleUIUpdate`**. New **`lastDirectBleUiFreshnessAt`** (wall time) on direct-BLE apply and complication hydration; **`effectiveWatchUiFreshnessAt`** = **`max(lastWatchStateUpdate, lastDirectBleUiFreshnessAt)`** for **`TrioMainWatchView.isWatchStateDated`**, **`scheduleBackgroundRefresh`** “recent data”, and **`loadFallbackDataFromComplication`** early-return. **`noteComplicationSnapshotUiFreshness`** / **`loadFallback`** merge **`readingDate`** into **`lastDirectBleAppliedReadingDate`** with **`max`**. **`TrioMainWatchView` `onAppear`** uses **`noteComplicationSnapshotUiFreshness`** instead of writing **`lastWatchStateUpdate`**. |

### External review — feedback recorded (2026-04-14)

| Source | Topic | Disposition |
|--------|-------|-------------|
| **Codex** (static, P1) | Direct BLE updated glucose but **`isWatchStateDated`** still used **`lastWatchStateUpdate`** only → main UI stayed “stale” (**`--`**). | **v1.39:** **`effectiveWatchUiFreshnessAt`** — see **WatchState** table row **Main watch UI freshness**. |
| **ChatGPT** | v1.38 merge/filter/retrieve/rename looks good; **tradeoff:** filter-only phone repair with missing/stale **`WatchMessageKeys.date`** is dropped. | **Accepted:** safety of monotonic freshness vs late filter-only repairs (wrong-sensor risk). Documented here. |
| **Prior (same cycle)** | Stale WC retargeting filter; BLE vs WC **`lastWatchStateUpdate`**; **`retrieveConnectedPeripherals`** UUID; **`manager_fresh`** → **`cbcentral_allocated_in_start_scanning`**. | **v1.38** — **WatchState — WC / direct-BLE merge hardening** + Phase E rows. |

---

## Changelog

### v1.82 (2026-04-23 22:50 CET)

- **Build 183 marked deployed and live.** Header **Status**, **Document state**, watch **build matrix**, **Forward plan — builds 181–186**, and **Phase I — Build 183** now treat **183** as **shipped in TestFlight** with the **active next** sequential build **184** (H1) subject to **[09](watch-direct-ble-cgm-09-preconnect-review.md)**. **Prerequisite** text for **184** updated so **“build 183 deployed”** is **met** for the binary, with **[09](watch-direct-ble-cgm-09-preconnect-review.md)** still gating the H1 ship decision.
- **Initial BetterStack evidence for build 183.** **Phase I — Build 183** now includes a **BetterStack — initial build-183 field slice** summary: time window, line counts, observed **`g7_ble_cycle_*` / `g7_ble_lifecycle` / `g7_ble_peripheral_match_classified` / `g7_ble_connect_suppressed`**, and explicit **not yet observed** items (connect-attempt, scan-start, new `g7_ble_cycle_started` actions) so acceptance criteria are **not over-claimed** from a first-day hot-window query.
- **Reason:** User requested live telemetry review and plan reconciliation after build 183 deployment; document must reflect field status without overstating validation completeness.

### v1.81 (2026-04-23)

- **Build 183 Phase I section added.** New **Phase I — Build 183** implementation log entry documents the `WKExtendedRuntimeSession` gate removal: root cause, three code changes, unchanged elements, new log events, and acceptance criteria. Build 183 status: in-progress.
- **Header, Status, Document state updated** to reflect build 182 deployed+validated and build 183 in-progress.
- **Reason:** Record build 183 plan and update all status tracking.

### v1.80 (2026-04-23)

- **Build 182 field validation recorded.** Phase I — Build 182 status updated to deployed and field-validated. BetterStack results added: retry loop confirmed working (attempt_count=2,3,4 observed); zero daytime `didConnect` confirmed as slot competition + Phase G runtime gate. DiaBLE watch analysis (manufacturer data `0604`, CBError 7) and G7SensorKit source analysis (no 5-minute timer; pure `scanAfterDelay` loop) documented.
- **Root cause identified.** Build 170 revert overnight produced 3 `didConnect` events; historical records show build 170 also connected at 14:59 daytime April 18. Static analysis confirmed Phase G `WKExtendedRuntimeSession` gate blocks scan on `.starting`/`.unavailable`. Build 170 source confirmed correct model: session started after `connect()`, not before `startScanning()`.
- **Forward plan extended to build 186.** Table renamed to "builds 181–186". Build 183 scope changed from H1 re-enable to WKExtendedRuntimeSession gate fix. Old build 183 (H1) shifts to 184; 184 (willRestoreState fast-path) shifts to 185; 185 (background soak) shifts to 186. Status column added.
- **Reason:** Record build 182 validation outcome and root cause identification; update forward plan for new build 183.

### v1.79 (2026-04-22)

- **Build 182 — G7SensorKit-style retry loop recorded.** Added **Phase I — Build 182** section documenting five code changes and five post-red-team bug fixes shipped in build 182: (1) 45 s single-attempt timeout replaced by 8 s per-attempt timeout with `hardStopDate`-gated retry (scan restart after 2 s); (2) `didFailToConnect` now retries instead of tearing down (for all errors including code 11) unless past `hardStopDate`; (3) `stopScan()` removed from `beginConnectToG7Peripheral` so scan stays live during connect attempts; (4) `attemptedConnectPeripheralIdentifiers` cleared per-attempt to allow same-peripheral retries; (5) `cycleRelativeDelay` floor raised from 0.1 s to 5.0 s. Bug fixes: `pendingDisconnectReason = "per_attempt_timeout_cancel"` pre-set before `cancelPeripheralConnection`; `connectionState == .connecting` guard in per-attempt timeout handler; generation capture around `await` suspension points; retrieved-identifier dedup insert; `emitStageIfChanged("scanning")` after per-attempt timeout.
- **Build log table updated:** Build 181 row updated from `(planned)` to deployed with actual change summary. Build 182 row updated from `(planned)` to `(in-progress)` with actual G7SensorKit-style retry loop scope (replaces the previously planned identity-guard + GATT validation scope).
- **Forward plan table updated:** Build 181 marked deployed. Build 182 row scope revised to reflect actual G7SensorKit-style retry loop; prerequisite updated to `Build 181 deployed`.
- **Header Status and Document state updated** to reflect build 181 deployed and build 182 in-progress.
- **Files touched:** `Trio Watch App Extension/G7DirectBLEManager.swift` (feature branch only). Plan doc amended in place — version bumped, Phase I — Build 182 section added, both build tables updated, header updated.
- **Reason:** Document build 182 G7SensorKit-style retry loop as in-progress; update all status tracking sections.

### v1.78 (2026-04-22 17:45 CEST)

- **Build 181 completeness pass — orphan-instance identity guard added in `centralManager(_:didConnect:)`.** The v1.77 red-team fix only covered the two failure-side callbacks (`didFailToConnect`, `didDisconnectPeripheral`) because those paths run `teardownSession` on the active session and were therefore the acute risk to acceptance 4. The success-side callback was left unguarded on the assumption that the `rssi=0` retrieval-instance silently never receives `didConnect`. That assumption is the very thing build 181 is designed to test, so it cannot be relied on to protect correctness: if CB on watchOS does deliver `didConnect` on the orphan retrieval instance, the unguarded handler would `persistPeripheralIdentifier` from the wrong instance, cancel the scan-path connect timer, arm a GATT setup timer bound to the orphan, and call `discoverServices` on the orphan — muddying the experiment signal and cross-wiring GATT state with the tracked peripheral. The fix mirrors the failure-side guards exactly: at the top of `centralManager(_:didConnect:)`, return early when `self.peripheral !== peripheral`, emitting `event=g7_ble_did_connect_ignored reason=orphan_peripheral_instance peripheral_id_short=… tracked_peripheral_id_short=…`. Comparison is by instance identity (`===` / `!==`), not UUID, because during the experiment window two CBPeripheral instances legitimately share the same UUID.
- **Scope preservation.** No other behaviour in `didConnect` changes for the tracked instance: identifier persist, connect-timeout cancel, GATT setup timer, stage emit, and `discoverServices` all continue to run unchanged when `peripheral === self.peripheral` (or when `self.peripheral` is `nil`). The guard only trims a pathological orphan-delivery path that change 2 newly made reachable — it does not alter which peripheral the scan path connects to, does not affect the `rssi=0` vs live-advertisement experiment, and does not suppress any log line the tracked instance emits.
- **New log event (additive):** `g7_ble_did_connect_ignored` (`reason=orphan_peripheral_instance`, `peripheral_id_short`, `tracked_peripheral_id_short`). Existing `g7_ble_did_connect` / `g7_ble_connected` dashboards remain valid for tracked-instance callbacks. Follow-up `docs/in-progress/watch-direct-ble-cgm-03-instrumentation-report.md` pass bundles the three `_ignored` events introduced in v1.77 and v1.78 together.
- **Doc reconciliations.** "Scope guardrails preserved" in the **Phase I — Build 181** log entry and the v1.77 **Finding 1.1** bullet are amended so they no longer say `didConnect` is deferred — it is now part of build 181. Build 182's residual-risk list remains accurate: full CBPeripheralDelegate-surface identity-guard coverage (service/characteristic discovery, notify state, write callbacks) is still out of scope for build 181.
- **Files touched:** `Trio Watch App Extension/G7DirectBLEManager.swift` (feature branch only; no patch stack changes). Plan doc amended in place — version bumped, Phase I — Build 181 and v1.77 entries cross-referenced to v1.78.
- **Reason:** Requested tightly-localized delta to close the last success-side orphan-callback leak before the build-and-deploy step. Static review only, no `xcodebuild` / `ci/local-build.sh` (AGENTS.md rule 10).

### v1.77 (2026-04-22 17:25 CEST)

- **Build 181 red-team review (prompt 05):** Ran three adversarial passes on `feature/watch-direct-ble-cgm` (`Trio` worktree) using the design ([01](watch-direct-ble-cgm-01-design.md)) and plan (v1.76) as spec. Iteration 1 surfaced one MAJOR and two MINOR findings; iterations 2 and 3 confirmed the scoped fixes and found no new blocker / major issues. Static review only, no `xcodebuild` / `ci/local-build.sh` (AGENTS.md rule 10).
- **Finding 1.1 (MAJOR) — orphan retrieval-instance teardown race.** Change 2 puts two `central.connect(_:options:)` calls in flight on two CBPeripheral instances for the same sensor UUID. Without instance-identity matching, a delayed CB `didFailToConnect` / `didDisconnectPeripheral` for the orphan retrieval instance would `teardownSession` the live scan-path session and invalidate the experiment. Minimal fix applied: at the top of `centralManager(_:didFailToConnect:error:)` and `centralManager(_:didDisconnectPeripheral:error:)`, return early when `self.peripheral !== peripheral`, emitting a scoped `g7_ble_did_fail_to_connect_ignored` / `g7_ble_did_disconnect_ignored` log with `reason=orphan_peripheral_instance` for traceability. (`didConnect` was left unguarded in v1.77 and folded into build 181 in v1.78 — see v1.78 entry.)
- **Finding 1.2 (MINOR) — classifier nil-name `"unknown"` fallback hardened.** `classifyPeripheralAgainstActiveFilter` now returns `.none` when `peripheral.name == nil` or when `activePeripheralName` is nil/empty, instead of relying on the coincidental `"unknown".suffix(2) == "wn"` non-collision with Dexcom suffixes.
- **Finding 1.3 (MINOR) — stale reason label rename.** `attemptRetrievedAttachIfAvailable` now emits `reason=missing_peripheral_name` (was `missing_name_for_exact_match`) when a retrieved peripheral has no name. Build 181 widened matching to exact-or-suffix(2), so `_for_exact_match` was misleading. `rg` confirmed no live references other than the call site itself; patch-stack `build/worktree-patches-*` copies are regenerated artifacts.
- **Finding 1.4 (NIT) — unreachable `.none.logValue` case.** Left as-is; enum exhaustivity.
- **New log events (additive):** `g7_ble_did_fail_to_connect_ignored`, `g7_ble_did_disconnect_ignored` (both `reason=orphan_peripheral_instance`, `peripheral_id_short`, `tracked_peripheral_id_short`, `error_desc`). Existing `g7_ble_did_fail_to_connect` / `g7_ble_did_disconnect` dashboards remain valid for tracked-instance callbacks. A follow-up pass should add these names to [03](watch-direct-ble-cgm-03-instrumentation-report.md)'s event catalogue; build 181 itself is unchanged.
- **Scope adjustment:** The "Scope guardrails preserved" bullet and Acceptance 5 verification in the Phase I — Build 181 log entry now explicitly document the red-team fix additions so the "no other changes" criterion is read honestly: three additional defects activated by change 2 were fixed in the same file under prompt 05's default "review, report, apply fixes" workflow, scoped narrowly to protect build 181's own acceptance criterion 4 against the race change 2 introduces.
- **Residual risks deferred to build 182:** orphan CBPeripheralDelegate callbacks (R1), orphan pending-connect accumulation (R2), full identity-guard coverage across didConnect and the CBPeripheralDelegate surface.
- **Files touched:** `Trio Watch App Extension/G7DirectBLEManager.swift` (feature branch only; no patch stack changes). Plan doc amended in place — version bumped, Phase I — Build 181 entry amended with red-team iteration, changelog updated.
- **Reason:** Prompt 05 completion rule — three full passes executed, self-review passed, no blocker or major remaining; document before handing back to the user for the build-and-deploy step.

### v1.76 (2026-04-22 16:57 CEST)

- **Build 181 amended:** Revised hypothesis and added a second code change based on Better Stack field evidence from the first device. The new trace shows `activePeripheralName=DXCM08` (phone already sends the short name, exact match already succeeded), `retrieved_identifier` `connect_attempt` fires with `rssi=0` and produces no CB delegate callback, then ~20 s later the live `DXCM08` scan rediscovery is suppressed as `duplicate_peripheral_in_attach_cycle source=scan`. The suffix(2) fix is **kept** as hygiene for accounts whose phone sends `DexcomXX`, but it is a no-op for this device. The primary fix is now in `beginConnectToG7Peripheral`: `attemptedConnectPeripheralIdentifiers.insert(peripheral.identifier)` is now conditioned on `source != "retrieved_identifier"`, so the scan-path `contains(…)` guard no longer suppresses the live-advertisement `connect(_:options:)` that is the only reference shown to be usable on watchOS for this device. All other sources (`scan`, `retrieved_connected`, `connection_event`, `nil`) still insert — same-cycle dedup for those is preserved.
- **Implementation log updated:** Rewrote **Phase I — Build 181** entry in **Implementation log (execution)** under the new title **“`suffix(2)` name hygiene + skip `retrieved_identifier` dedup insert”**, documenting the hypothesis revision, the three shipped edits, the updated scope guardrails, the five acceptance criteria and how each was verified, and the deferred follow-ups (retrieval-path `match=` logging, `rssi_eligibility` pre-gate, `connect_attempt` persist placement).
- **Files touched:** `Trio Watch App Extension/G7DirectBLEManager.swift` (feature branch only; no patch stack changes).
- **Reason:** Bring the plan doc into line with the actual build 181 as implemented under prompt **04 (execute implementation plan)** after the user's STOP-AND-READ correction with field data, and record the new primary hypothesis (stale `rssi=0` retrieval reference) vs. the retained hygiene change (suffix(2) for name duality) for the red-team review in prompt 05.

### v1.75 (2026-04-22 16:45 CEST)

- **Build 181 executed:** Added **Implementation log (execution)** section **Phase I — Build 181: `suffix(2)` name match at helper + `didDiscover`** recording the two-site change: `doesPeripheralMatchActiveFilter` refactored to exact-or-`suffix(2)` via a new `classifyPeripheralAgainstActiveFilter(_:)` helper; `centralManager(_:didDiscover:…)` inline `name != active` guard replaced with the same classifier so the scan gate and the retrieval helper can never diverge again. Added optional `event=g7_ble_peripheral_match_classified source=scan match=exact|suffix peripheral=<name>` debug log at the scan match site per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 2 Finding 3. Skip log adds `source=scan` for convention parity with the other `g7_ble_peripheral_skipped` sites. Scope held to build 181 only — identity guards, `connect_attempt` persist policy, and `cycleRelativeDelay` floor remain deferred to build **182** per [09](watch-direct-ble-cgm-09-preconnect-review.md) Part 5.
- **Files touched:** `Trio Watch App Extension/G7DirectBLEManager.swift` (feature branch only; no patch stack changes).
- **Reason:** Record build 181 execution per prompt **04 (execute implementation plan)**; close the Bug 2 name-duality gap documented in the two-bug analysis and [09](watch-direct-ble-cgm-09-preconnect-review.md) so Paths A–C can actually reach `central.connect(_:options:)` once the phone-provided active sensor name disagrees with the advertised name.

### v1.74 (2026-04-22 16:37 CEST)

- **Sequential build numbering:** Forward plan and matrix now use strict **181 → 182 → 183 → 184 → 185** order. **182** = delegate hardening + GATT validation (restore-flush collateral); **183** = H1 re-enable — same **09** substance as before, without out-of-sequence build labels.
- **Cross-references updated:** Header **Status**, **Document state**, **Phase H** ship-order note, **Build 180** static follow-up, forward-plan table, and **184** prerequisite (**182** guards).
- **Reason:** Keep TestFlight / implementation build IDs monotonic while preserving **09** “harden before H1” priority.

### v1.73 (2026-04-22 16:29 CEST)

- **Pre-connect review integrated:** **[watch-direct-ble-cgm-09-preconnect-review.md](watch-direct-ble-cgm-09-preconnect-review.md)** linked from the header; **build 181** scope corrected to **two sites** (**`doesPeripheralMatchActiveFilter`** + **`didDiscover`** inline compare — **blocker** if only the helper changes).
- **Forward plan reordered:** **183** (delegate identity guards + restore-flush collateral + GATT validation) **promoted before** **182** (H1 re-enable); **184** / **185** descriptions updated per **09** (fast-path prereqs, background observability).
- **Build 180 follow-up:** **Implementation log** notes phantom **`didDisconnect`/`didConnect`** risk from restore flush and points mitigations to **183**.
- **Header / document state / Phase H** updated for the new ship order and **Phase I** status cross-link to **09**.
- **Reason:** Align the plan with static pre-connect findings so the next builds close scan-path gating and restore collateral before connection events.
- **Superseded by v1.74:** build labels **181 → 183 → 182** were replaced by **strict ascending** **181 → 182 → 183** to match implementation sequencing.

### v1.72 (2026-04-22 15:45 CEST)

- **Build 180 recorded:** `willRestoreState` CB state restoration fix — `stopScan()` + `cancelPeripheralConnection` for restored peripherals; `restored_peripheral_count=N` added to log line. Primary hypothesis for build 171+ regression.
- **Two-bug analysis added:** `doesPeripheralMatchActiveFilter` exact-name mismatch (`DXCMxx` ≠ `DexcomXX`) documented as second independent bug — scan path has never called `connect()` in any build; build 181 suffix(2) fix planned.
- **Forward plan 181–185 added** to implementation log.
- **Header and document state updated** to reflect build 180 deployed and dual root-cause analysis.
- **Reason:** Record build 180 deployment, two complementary root causes identified by Claude Code static analysis, and forward plan through background operation validation.

### v1.71 (2026-04-22 13:19 CEST)

- **Phase I field evidence recorded:** Added implementation log records for builds **177**, **178**, and **179** with Better Stack outcomes. All three builds confirmed **`g7_ble_did_connect` = 0**. Build **177** eliminated **`registerForConnectionEvents`** as the regression cause. Build **178** eliminated nil scan. Build **179** restored persist-on-connect-attempt (retrieval chain functional again) but **`didConnect`** still absent even on the retrieval path with build-170-identical conditions.
- **Header/status updated:** Phase I implementation status now reflects all three builds deployed and field-reviewed; root cause unidentified; active investigation open on CB delegate lifecycle, restore identifier key history, and potential double-allocation.
- **Build matrix split:** **`177+`** row split into builds **177**, **178**, and **179** with distinct scope and outcome per build.
- **Reason:** Record actual field results against Phase I predictions and document the open investigation state.

### v1.70 (2026-04-21 20:56 CET)

- **Consistency pass:** Aligned **Sequencing + ship boundaries** Phase **H** row with **Phase I** (H1 off in current tree, H2/H3 on), updated **Phase A1** / **Phase B1** task text to match shipped **F4** (central in **`init()`**) and **F2** (delegate queue **`nil`**), corrected **F11** table + subsection to reflect **Phase H H1** superseding the old “later F11” gate, and rewrote ranked candidate **#1** + **H1** active-shape bullets so they no longer read as “add **`registerForConnectionEvents` next”** while Phase I keeps it disabled.
- **Historical records:** Fixed **Record — CI build: WatchState** table + **Plan alignment** note that still claimed **`CBCentralManager`** was not allocated until **`startScanning()`** (false after **F4**); added **v1.66** / **v1.68** changelog supersession notes where later doc versions reversed the framing.
- **Reason:** Remove contradictions between the plan body, historical Phase F/F11 wording, and the current `G7DirectBLEManager.swift` behavior.

### v1.69 (2026-04-21 20:39 CET)

- **Phase H vs code:** Documented **H2/H3** as active in `Trio` and **H1** as implemented-but-commented-out per **Phase I**; added an **Implementation status** table under Phase H and split the operational success criterion for H1-off vs Phase I.
- **Phase I:** Marked the Build 177 connection-event removal as **implemented in code**; clarified that fleet/Better Stack validation is still the next operational step.
- **Build matrix:** Added **Watch extension build matrix** table indexing builds **163**–**177+** to the initiative steps bundled in each (F1–F10, Phase G, Phase H increments, Phase I).
- **Stale wording:** Updated build-171 operational bullets so the “next step” is Phase H / Phase I rather than “Phase G live-log refinement only.”
- **Reason:** Align the plan with the current `G7DirectBLEManager.swift` worktree after static review (2026-04-21).

### v1.68 (2026-04-20 16:47 CEST)

- **Phase H H1–H3 foundation recorded as implemented:** The header, document-state note, Phase H framing, and implementation log now state that the first attach-context alignment pass is landed in `Trio` while live Better Stack review is still pending.
- **Mandatory connection-event attach path implemented:** Recorded that **`registerForConnectionEvents`** now lives in the active watch attach path, that **`centralManager(_:connectionEventDidOccur:for:)`** is implemented, and that the new proof log is **`event=g7_ble_connection_event_fired ... source=connection_event`**.
- **Superseded by v1.69:** **Phase I** later documented **H1** as **commented out** in the current tree for regression isolation; treat the bullets above as describing the **pre-Phase-I** attachment of H1 to active code, not the current compiled default.
- **Connected-peripheral retrieval alignment recorded:** Recorded the combined **`retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService, G7BLEUUID.advertisement])`** query, the new retrieval priority ahead of stale identifier retrieval, and the aligned debug-view retrieval count.
- **Pre-connect retrieval diagnostic correction recorded:** Recorded that retrieval-derived **`g7_ble_pre_connect`** lines now treat connected peripherals as sane so Better Stack can evaluate the preferred live-connected attach path cleanly.

### v1.67 (2026-04-20 16:03 CEST)

- **`registerForConnectionEvents` promoted into mandatory H1 work:** Phase H no longer treats watch-side connection-event registration as an H4 experiment. The active plan now requires **`registerForConnectionEvents`** in **`startScanning()`**, a new **`centralManager(_:connectionEventDidOccur:for:)`** delegate path, and explicit **`event=g7_ble_connection_event_fired ... source=connection_event`** logging.
- **Connected-peripheral retrieval alignment added:** Phase H now specifies one combined **`retrieveConnectedPeripherals(withServices: [G7BLEUUID.dataService, G7BLEUUID.advertisement])`** query and requires that live connected-peripheral retrieval be checked before **`retrievePeripherals(withIdentifiers:)`** in the attach path.
- **Pre-connect diagnostic fix added:** The plan now corrects the retrieval-path diagnostic so connected retrieval sources are treated as sane in pre-connect logging rather than polluting analysis.
- **Round-robin experiment demoted to a fallback diagnostic:** The earlier **`identifierFirst`** / **`scanFirst`** / **`dualLane`** round-robin remains preserved, but only as a later fallback if the mandatory connection-event and retrieval-priority fixes still do not move the attach boundary.
- **Phase H success criterion updated:** Success is now defined by recurring **`g7_ble_connection_event_fired`** lines appearing alongside watch-side **`g7_ble_did_connect`** events in Better Stack, proving that watchOS is delivering OS-level attach context and that the watch is using the live-connected peripheral path.

### v1.66 (2026-04-20 14:29 CEST)

- **Phase H implementation shape made explicit:** Phase H now states directly that the active execution shape is a single-build round-robin attach-strategy experiment inside the fixed Phase G scheduler/runtime framework.
- **Round-robin strategy selection defined:** The plan now states that the round-robin experiment assumes H1 identifier-policy hardening is already in place and held constant across the whole experiment build, with strategy selected once per new cycle via persisted **`attachExperimentIndex`** and frozen through same-cycle retry.
- **Round-robin persistence and retry guard clarified:** The plan now says **`attachExperimentIndex`** should persist across app restarts unless that is materially risky and documents that **`dualLane`** same-cycle retry must keep the original cycle's first-lane-wins suppression rules.
- **Phase H analysis wording aligned with the experiment:** Ranked candidates, evaluation wording, and the top-level sequencing row now describe comparison by **`strategy`** and **`source`** under one interleaved build, while leaving H4 conditional follow-ons unchanged in sequence.
- **Superseded by v1.67+:** Subsequent edits demoted the round-robin to **fallback-only** and reframed Phase H around mandatory **H1–H3** attach-context work; the live plan text no longer describes round-robin as the primary execution shape.

### v1.65 (2026-04-19 22:41 CEST)

- **Phase H framing tightened:** Added an explicit sentence that Phase H works inside the shipped Phase G cadence/runtime model rather than reopening scheduler/runtime redesign.
- **Phase H success criterion added:** Added a concrete operational success test for Phase H: recurring watch-side **`didConnect`** inside predicted windows often enough that post-connect behavior becomes the dominant remaining boundary.
- **Ranked/deferred candidate wording refined:** Softened the identifier-policy rationale so it reads as an evidence-backed re-evaluation rather than a prematurely fixed conclusion, clarified that `registerForConnectionEvents` is a next-tier attach-context experiment, and added stronger phone-to-watch cadence-anchor enrichment to the deferred idea tree.

### v1.64 (2026-04-19 22:36 CEST)

- **Phase H promoted to the active next phase:** Updated the header, document-state framing, and top-level phase structure so the document now says explicitly that **Phase G** remains the shipped/current scheduler-runtime basis while **Phase H — Pre-connect attach reliability** is the active next implementation target.
- **Build 171 transition interpreted operationally:** Added a concise transition summary stating that Phase G successfully established cadence-aware runtime-gated scheduling in **build 171**, but that the remaining dominant live boundary is still pre-connect **`awaiting_connect`**.
- **Ranked follow-on candidates added with explicit priority split:** Added a ranked Phase H candidate list centered on attach-lane selection, identifier persistence/retrieval policy, source-split analysis, runtime/foreground timing, anchor quality, and conditional connection-event support, plus a separate deferred-candidates section so lower-priority or later-phase ideas remain traceable without being confused for the active plan.

### v1.63 (2026-04-19 22:18 CEST)

- **Phase G shipped state recorded:** Updated the header and document-state framing to mark **build 171** as the first shipped/live Phase G execution point and to make Phase G live-log refinement, not a new phase, the current next step.
- **Build 171 Better Stack review added:** Added a localized shipped-evidence subsection that records the watch-only **`g7_ble_*`** analysis for **`build=171`**, including cycle/runtime event counts, anchor source, attach source, miss buckets, and the absence of any watch-side **`didConnect`** progression.
- **Historical build-170 planning note tightened:** Marked the old "Planned next sequence after build 170" block as a historical note that was executed by the build-171 Phase G ship point.

### v1.62 (2026-04-19 16:41 CEST)

- **Phase G runtime gate tightened:** The active plan and execution log now state explicitly that attach / GATT startup must wait for **`extendedRuntimeSessionDidStart(...)`**, not just for runtime creation or `start()` request issuance.
- **G1 implementation note clarified:** The G1 row now records the explicit runtime-starting state and cycle-scoped activation-deadline behavior that closes a cycle as a **runtime miss** if runtime never becomes active.
- **Versioning refreshed for the localized runtime follow-up:** Bumped the plan doc to **v1.62** and updated **Last updated** for the final Phase G runtime-gating pass.

### v1.61 (2026-04-19 16:09 CEST)
- **Phase G snapshot seed made monotonic:** `updateCycleSeedContext(...)` now keeps the max complication-snapshot reading timestamp instead of blindly overwriting it, so an older foreground-entry seed cannot move the scheduler anchor backward.
- **Execution log aligned with the seed fix:** The Phase G `G1` row now notes that complication-snapshot seed handling is monotonic in the active implementation.
- **Versioning refreshed for the localized fix:** Bumped the plan doc to **v1.61** and updated **Last updated** for the follow-up correction.

### v1.60 (2026-04-19 15:51 CEST)
- **Phase G anchor policy tightened:** The active Phase G scheduling model and execution log no longer advertise `last_connect` as a first-version cadence anchor. The active implementation now anchors only from trustworthy reading timestamps: direct BLE, complication snapshot, then trustworthy phone relay.
- **Phase G follow-up fix pass recorded:** The implementation log now reflects the stricter G1 shape after the code follow-up: explicit cycle close before roll-forward reschedule, deliberate same-cycle rearm reset for passive observation state, and a clearer foreground-only interpretation of same-cycle runtime reacquire.
- **Versioning refreshed for the fix pass:** Bumped the plan doc to **v1.60** and updated **Last updated** for the localized Phase G consistency follow-up.

### v1.59 (2026-04-19 15:45 CEST)
- **Phase G execution wording tightened:** Header status and document-state now say more directly that the active Phase G implementation target has been executed in code at the planned **G1 / G2** scope, rather than describing those changes as merely initial landings.
- **G1 ownership split made explicit in the execution log:** The Phase G implementation-log row now states plainly that **`WatchState`** seeds cadence state from complication-snapshot and trusted phone-relay timestamps, while **`G7DirectBLEManager`** owns anchor selection, runtime control, retries, and cycle execution.
- **Versioning refreshed for the implementation pass:** Bumped the plan doc to **v1.59** and updated **Last updated** to match the localized Phase G implementation record cleanup.

### v1.58 (2026-04-19 15:40 CEST)
- **Phase G implementation recorded:** Header status / document-state now reflect that the initial **G1 / G2** cadence-scheduler and cycle-relative-timeout changes have landed in code on top of the build-170 passive-first baseline, while **G3** remains conditional on field logs.
- **Execution log updated for the active phase:** Added a new **Phase G — cadence scheduler + cycle-relative timeout model** record under **Implementation log (execution)** describing the manager-side scheduler, runtime gating, cycle logs, and the choice to leave discovery scope unchanged in this pass.
- **WatchState cadence seed handoff documented:** Updated the **WatchState — WC / direct-BLE merge hardening** table to record the new Phase G handoff of phone-relay and complication-snapshot reading timestamps into the BLE cadence scheduler.

### v1.57 (2026-04-19 15:24 CEST)
- **Phase G ownership clarified:** Added a short implementation-ownership note stating that **`WatchState`** remains the lifecycle entry point while **`G7DirectBLEManager`** owns anchor selection, cadence scheduling, runtime ownership, retries, and cycle execution.
- **`applyForegroundActiveEntry(...)` role tightened:** **G1** now states explicitly that **`applyForegroundActiveEntry(...)`** remains in use as a thin scheduler-entry wrapper rather than the owner of reconnect or extended-runtime flow.
- **Phase G validation made more operational:** Added an explicit success criterion for Phase G and standardized the anchor-source wording from "watch snapshot" to **complication snapshot**. The historical scope bullet now says more bluntly that new work should not be implemented against the old build-170 lifecycle model.

### v1.56 (2026-04-19 15:19 CEST)
- **Phase G made unambiguous as the only current next target:** Tightened the header document-state language so the plan now has one explicit answer to "what is the next implementation target?" and that answer is **Phase G**.
- **Historical observer-alignment sections relabeled in place:** Added a bridge note near the start of the older plan body, retitled the old process-gate and observer-alignment sections as historical, and clarified that the prior minimum-delta instructions are preserved provenance for the **build-170 passive-first baseline**, not current top-level directives.
- **Top-level sequencing table extended through Phase G:** Updated **Sequencing + ship boundaries** so the concise top-level structure now reflects historical **Phases A-F** plus active **Phase G**.

### v1.55 (2026-04-19 14:58 CEST)
- **Build 170 Better Stack evidence added:** Added a short watch-only log-findings section under the build-170 implementation-log baseline with concrete counts for connect attempts, identifier-retrieved attach selections, post-connect milestone drop-off, and repeated extended-runtime invalidation.
- **Header versioning refreshed:** Bumped the implementation plan to **v1.55** and updated **Last updated** to reflect the log-evidence follow-up.

### v1.54 (2026-04-19 14:50 CEST)
- **Active framing moved to Phase G:** The header status/document-state framing now points to **Phase G — cadence-aware watch G7 observation loop** instead of treating another attach-context build as the top-level next step.
- **Cadence-aware plan inserted as the new active phase:** Added **Phase G** before **Prerequisites**, shifting the initiative from blind retry / attach-context experimentation to a cadence-aware per-reading watch observation loop while preserving **Phase E / F** below as historical investigative context.
- **Runtime and timing posture clarified:** The active plan now treats multi-cycle runtime as a target when watchOS allows it, not a guaranteed assumption, and labels the proposed timing windows as initial tunable defaults for field validation.
- **GATT simplification reframed:** Broader **`discoverServices(nil)`** / **`discoverCharacteristics(nil, for:)`** is now documented as the first GATT simplification experiment after cadence scheduling, not as a proven required change.
- **Implementation log updated through build 170:** The execution trail now records **F10 implemented and deployed with build 170** as the last attach-context-era execution point before the Phase G transition.

### v1.52 (2026-04-19 00:05 CEST)
- **Passive follow-up minimized:** The plan now records the narrower watch behavior: `communication` remains optional and passive via notify-only handling, while communication notify failure stays non-blocking because it is not part of the watch readiness gate.
- **Fallback de-eagered:** The bounded fallback `0x4E` path remains in scope, but the follow-up now treats it as a later rescue step inside the first-EGV window rather than an early near-default action.

### v1.51 (2026-04-18 23:40 CEST)
- **Passive observer follow-up recorded:** The plan now matches the watch passive-path implementation more closely: `authenticated == true` is the passive gate, `bonded` remains diagnostic, passive observation is armed before any control write, and `0x4E` is retained only as a bounded fallback.
- **Communication parity documented:** Added the minimal DiaBLE-style `communication` notify/read handling to the implementation target and updated the debug/validation language to include passive-observation checkpoints instead of an unconditional `0x4E sent` milestone.

### v1.50 (2026-04-18 22:35 CEST)
- **Extended-runtime expiry handling corrected:** The implementation plan now matches the shipped watch code: `extendedRuntimeSessionWillExpire` is warning-only and no longer documents early BLE teardown before real invalidation.
- **Reconnect policy updated to current behavior:** The plan no longer treats failure-class teardowns as terminal by default; the current watch logic retries after disconnects and failed connects unless teardown was an explicit stop.
- **`0x4E` request path explicitly retained:** Clarified the implemented watch behavior as auth notify -> `0x05 authenticated+bonded` -> control notify -> explicit `0x4E` control write -> `0x4E` receive, rather than a passive-only control-observation model.

### v1.49 (2026-04-18 12:20 CEST)
- **F10 implementation recorded:** Updated the header status, document-state note, active sequence table, and the dedicated **F10** section to reflect that the identifier-first retrieval experiment is now implemented in `Trio` as the next standalone watch-side attach-context build, but is not yet deployed or live-reviewed.
- **Next-step sequencing updated:** Replaced the old “later conditional F10” wording with the current sequence: evaluate **`source=retrieved_identifier`** next, keep **F11** as the next later attach-context candidate if F10 is negative, and keep **F6/F7** conditional on a future real **`didConnect`** rather than promoting post-connect parity immediately.

### v1.48 (2026-04-18 10:05 CEST)
- **F5 implementation and deploy recorded:** Updated the header status, document-state note, active sequence table, and Phase F execution trail to reflect that **F5** is now implemented in code, shipped with the updated watch debug view, and deployed as **build 168**.
- **Build-168 evidence added:** Added a new **Phase F build evidence** row and a dedicated **Build 168 watch-only Better Stack review** section summarizing the de-duplicated live result: **17** scan-sourced connect attempts, **18** zero-result retrieval observations on both **data service** and **FEBC**, and **0** post-connect milestones.
- **Post-F5 sequencing tightened:** Reworded the next-step guidance so **F6/F7** stay conditional on a future real **`didConnect`** in build **168** or later, while **F9** now explicitly interprets build **168** as “retrieval absent” rather than assuming a continuing retrieved-path advantage.

### v1.47 (2026-04-17 18:05 CEST)
- **F5 expanded into the next additive diagnostic build:** The plan now keeps **F5** as the immediate next step but expands it to include the **dual-UUID retrieval** diagnostic in the same build: retain retrieval on **`G7BLEUUID.dataService`**, add parallel retrieval on **`G7BLEUUID.advertisement`** / **FEBC**, and log per-UUID retrieval counts, explicit **`source=scan|retrieved`**, plus **`peripheral.state`** / **`peripheral.identifier`** before **`connect()`**.
- **F6–F9 re-ranked and tightened:** **F6** remains the next clean parity test only if **F5** shows **`didConnect`** but no usable service-discovery callback; **F7** is explicitly demoted until service discovery succeeds; **F8** is now framed as an audit/escalation path rather than an active suspect; **F9** is strengthened from background context into an explicit retrieved-vs-scan diagnostic lane with source-split metrics and interpretation guidance.
- **Later conditional Phase F steps added without broadening scope:** Added **F10** identifier-first retrieval and **F11** connection-event registration as later, concrete, testable steps with prerequisites. Timing-window and Dexcom-watch-app contention ideas remain in analysis / interpretation lanes for now, not immediate code builds.
- **PacketLogger trigger clarified:** Raw capture remains deferred behind the next disciplined attribution build, but the plan now states more explicitly when it should be pulled forward if **F5** still leaves the first missing callback ambiguous.
- **F5 attribution detail clarified:** Refined the next-build logging guidance to distinguish **`source=scan`**, **`source=retrieved_data_service`**, and **`source=retrieved_febc`**; log retrieval-result overlap by peripheral identifier; avoid duplicate connect attempts within one attach cycle; include bounded discovered service UUID lists in `didDiscoverServices`; and replace broad `status gate not satisfied` wording with concrete blocker fields.
- **Consistency / validation wording tightened:** Aligned **F5** and **F9** with the concrete retrieval-source labels, added a note to log whether **`peripheral.services`** is already non-`nil` in **`didConnect`**, and tightened the validation wording around source-split capture, connect-boundary timeout closure, and the operational `g7_ble_did_connect` threshold.

### v1.46 (2026-04-16 17:16 BST)
- **Post-F4 sequence added:** The active **Phase F** table now extends past **F4** with **F5** post-connect GATT attribution closure, conditional **F6** / **F7** discovery-scope parity builds, **F8** as an audit-only escalation path unless **F5** finds a real readiness bug, and **F9** as a retrieval-vs-scan analysis track.
- **Build-166 follow-up sequencing clarified:** The **Phase F build evidence** row for build **166** and the new post-build-166 sequence note now state explicitly that **F5** is next, **F9** runs as analysis context, and **F6/F7** are selected only after **F5** closes the post-connect trail.
- **PacketLogger deferral wording carried forward:** The active sequencing language now keeps **PacketLogger / raw capture** deferred through the post-**F4** cycle instead of framing it as a required gate before the next build.

### v1.45 (2026-04-16 16:11 BST)
- **Build 166 / F4 deploy and runtime review recorded:** Header / status / document-state, the **Phase F** execution table, and the **Phase F build evidence** table now record build **166** as the live **F4** deployment with the first watch-side **`g7_ble_did_connect`** / **`g7_ble_connected`** and one moved timeout boundary at **`awaiting_gatt_setup`** / **`final_stage=discovering_services`**.
- **F4 wording updated to match the shipped code:** The **F4** section now states explicitly that the lifecycle parity change moved **`CBCentralManager`** allocation into **`G7DirectBLEManager.init()`**, while **`startScanning()`** normally reuses the already-lived manager.
- **Build 166 log-search method documented:** Added the exact Better Stack search set used to understand the build-166 outcome: grouped watch-only counts by build/event, grouped session outcomes by final stage, grouped timeouts by stage, grouped connect attempts by source, and the expanded timeline for the single **`didConnect`** session.

### v1.44 (2026-04-15 19:26 BST)
- **Build 165 preliminary runtime result recorded:** Header / status / document-state and the **Phase F** execution tables now record the current watch-only Better Stack read for build **165**: **2** observed connect attempts, both still timing out at **`awaiting_connect`** with no watch-side connect / fail / disconnect or EGV / snapshot milestone.
- **F4 advanced from fallback to active next build:** The active Phase F sequence now promotes **F4 — `CBCentralManager` lifecycle / early allocation parity** from reserved fallback to the next one-change build after the preliminary negative **F3** result.
- **PacketLogger deferral preserved after the F3 review:** The active wording now makes clear that **PacketLogger / raw capture** remains deferred even after the first negative **F3** read; it is still not the immediate next gate ahead of **F4**.

### v1.43 (2026-04-15 18:58 BST)
- **F3 advanced from planned to deployed:** Header / status / document-state and the **Phase F** execution tables now record **F3** as the active build **165** change: remove **`CBCentralManagerScanOptionAllowDuplicatesKey: false`** while keeping the **FEBC** filter and all existing **F1/F2** logging unchanged.
- **F4 promoted to the next fallback build:** The active Phase F sequence now extends through **F4 — `CBCentralManager` lifecycle / early allocation parity**, defined as the next standalone one-change experiment only if **F3** is negative.
- **PacketLogger deferral made explicit:** Removed the old per-build PacketLogger requirement and replaced it with the current policy: **PacketLogger / raw capture** is deferred for now, not abandoned, and should be revisited only after **F3** and **F4** are both negative or if later evidence changes direction.

### v1.42 (2026-04-15 16:18 BST)
- **Build 164 analysis recorded:** Header / status / document-state and **Phase F — connect-boundary parity execution** now record the expanded watch-only Better Stack re-check for **build 164**. The doc now states explicitly that **7** distinct watch connect attempts were observed and none produced **`g7_ble_did_connect`**, **`g7_ble_did_fail_to_connect`**, **`g7_ble_did_disconnect`**, or **`g7_ble_connect_timeout_canceled`** before timeout.
- **F2 conclusion tightened:** The **Phase F build evidence** row for **build 164** now records the evidence-backed conclusion that **`queue: nil`** did **not** materially change the watch-side pre-connect stall, while keeping PacketLogger / raw captures as the final gate before **F3**.
- **F3 gate refined:** The F2 row and F3 row now point specifically to the build **164** PacketLogger / raw-capture re-check rather than the already-completed generic watch-only review.

### v1.41 (2026-04-14 22:50 CEST)
- **Phase F execution advanced through F2:** Header / status / document-state lines now record **Phase F / F1** as reviewed in **build 163** and **Phase F / F2** as implemented / deployed in **build 164**, with **F3** still gated on the build 164 watch-only review / PacketLogger cycle.
- **Implementation log refreshed:** Replaced the static **F1** implementation-only note with **Phase F — connect-boundary parity execution (2026-04-14)**, including the build-163 closed-trail result, the isolated **`queue: nil`** change for build 164, and a compact **Phase F build evidence** table for builds **163** and **164**.
- **Phase F active sequence updated:** The execution table now shows **F1** reviewed, **F2** deployed, and **F3** explicitly gated on the build 164 evidence review.

### v1.40 (2026-04-14 21:22 CEST)
- **Phase F rewritten as a gated sequence:** Replaced the old deferred candidate table with three one-change-per-build experiments: **F1** connect-boundary observability, **F2** **`queue: nil`** parity, **F3** scan-option parity. Added explicit watch-only interpretation, mandatory PacketLogger capture for every Phase F build, stable-`didConnect` definition, primary / stronger stop conditions, and the active out-of-scope list.
- **Phase F / F1 implemented:** Added **Implementation log (execution)** subsection **Phase F — F1 connect-boundary observability (2026-04-14)** recording the additive **`g7_ble_connect_timeout_*`** and **`g7_ble_did_*`** event work in **`Trio`**, and stating that **F2/F3** remain gated on the first Phase F build / deploy / review cycle.

### v1.39 (2026-04-14 17:08 CEST)
- **Codex P1 / main watch UI:** **`effectiveWatchUiFreshnessAt`** + **`lastDirectBleUiFreshnessAt`** so direct-BLE sessions advance **`TrioMainWatchView.isWatchStateDated`** / chart refresh signals without writing **`lastWatchStateUpdate`**. **ChatGPT** tradeoff on filter-only WC payloads recorded under **External review — feedback recorded**.
- **Implementation log:** Table row **Main watch UI freshness**; external review table for **Codex** / **ChatGPT** / prior **v1.38** feedback.

### v1.38 (2026-04-14 16:47 CEST)
- **Phase E / watch-state hardening:** **`g7_ble_pre_connect`** field **`manager_fresh`** renamed to **`cbcentral_allocated_in_start_scanning`** (semantics: only this **`startScanning()`** allocated **`CBCentralManager`**). **`retrieveConnectedPeripherals`** now uses **GATT data service** UUID; **`FEBC`** remains scan-only — see **Implementation log** **E1** / **E2** and code comments in **`G7DirectBLEManager`**. **WatchState** — **WC** active-G7 filter gated by stale check; **direct-BLE** snapshot vs **WC** monotonic merge — see new subsection **WatchState — WC / direct-BLE merge hardening**.

### v1.37 (2026-04-14 16:28 CEST)
- **Phase E connect-context fields (implementation):** **`g7_ble_pre_connect`** — **`is_connectable`**, **`discover_count_for_target`**, **`peripheral_id_short`**, **`manager_fresh`**. **`g7_ble_retrieve_on_powered_on`** / **`g7_ble_peripheral_discovered`** — **`peripheral_id_short`** for bounded CoreBluetooth identity correlation. See **Implementation log (execution)** **E1** row and **Instrumentation report 03** **v1.25**.

### v1.36 (2026-04-14 16:18 CEST)
- **Phase E execution log revised (post-review):** **E1** — **`connect()`** is synchronous again; **`scheduleConnectTimeout()`** moved to after **`connect()`**; **`g7_ble_pre_connect`** remains fire-and-forget **`Task`**. **E2** — **`centralManagerDidUpdateState`**: retrieve before **`scanForPeripherals`**.

### v1.35 (2026-04-14 16:09 CEST)
- **Phase E executed:** Implemented **E1–E3** in **`Trio`** `G7DirectBLEManager.swift` per Phase E spec. Added **Implementation log (execution)** subsection with prompt **04** traceability.

### v1.34 (2026-04-14 15:42 CEST)
- **Phase E added — pre-connect parity investigation (build 162):** New phase with three tasks targeting the `didConnect` stall. **Task E1:** one new `event=g7_ble_pre_connect` instrumentation line immediately before `connect()` with `peripheral_state`, `central_state`, `source=scan|retrieved`, `first_attempt`, and `preserved_session`. **Task E2:** `retrieveConnectedPeripherals(withServices: [FEBC])` retry inside `.poweredOn` to match DiaBLE's timing. **Task E3:** add `CBCentralManagerOptionRestoreIdentifierKey` parity experiment (single most impactful pre-connect gap vs DiaBLE). Phase F candidates table defers queue `nil` vs `.main`, `discoverServices(nil)`, and `AllowDuplicatesKey` unless build 162 is inconclusive. Extended runtime remains disabled at connect time; observer/auth/GATT/EGV logic unchanged; scan filter unchanged.

### v1.33 (2026-04-13 23:31 CEST)
- **Status moved from approval-gated to implemented:** Header/status/document-state now reflect that the watch-only DiaBLE observer-alignment delta has been implemented and is in post-implementation review / soak follow-up, rather than still waiting on approval.
- **Implementation log updated for the current observer cycle:** Added **Record — DiaBLE observer alignment implementation (watch-only)** to capture the actual watch-path code changes that landed after approval.
- **Previously missing code reviews logged:** Added **Record — observer alignment code review feedback + follow-up fixes** consolidating the latest ChatGPT and red-team / Cursor-style implementation reviews, including the follow-up dispositions for discovery-path attach blocking, stale request-block UI state, relay-source semantics, debug-view refresh, and direct-BLE color preservation.

### v1.32 (2026-04-13 23:05 CEST)
- **Blocked-state events added to the implementation target:** The watch plan now explicitly requires a missing-filter attach-blocked event, a `0x05` status-gate-blocked event, and an `0x4E` request-blocked event so stalled observer sessions are visible in logs without inference.
- **Observer timeout gate sharpened:** Reworded the teardown / timeout task so the direct-BLE startup happy path is explicitly `auth notify + 0x05 authenticated=true bonded=true + control notify`, with `backfill` excluded from startup readiness.

### v1.31 (2026-04-13 22:21 CEST)
- **Active sensor gate made explicit:** Added a hard requirement that watch direct BLE only attempts attach when the phone has supplied the active sensor identity / name filter; no arbitrary Dexcom connect fallback remains in scope.
- **Document state clarified:** Added a short header note explaining that the pending delta is the remaining observer-alignment work plus the new section in the **existing** watch debug view, while the long implementation log remains historical context.
- **`0x4E` cadence clarified:** Documented the minimum behavior as one `0x4E` request per successful connect / auth / control-ready cycle, repeated on reconnect, while explicitly rejecting a speculative repeating polling loop in this delta.

### v1.30 (2026-04-13 22:10 CEST)
- **Watch debug-view task added:** Added **Task C1b — Lightweight watch debug view** with a compact field list covering path mode, connection stage, peripheral state, auth/control readiness, last EGV / snapshot state, and session diagnostics.
- **Debug UI tied to observer proof:** The plan now explicitly requires the debug UI to mirror the same observer milestones used in logging and to avoid raw packet hex dumps or oversized on-watch logs.

### v1.29 (2026-04-13 22:04 CEST)
- **Approval gate made explicit:** Added **Process gate (current cycle)** so this plan now states the required sequence: update docs first, then stop and wait for approval before any Trio watch code changes.
- **Observer-only scope tightened:** Added explicit scope/out-of-scope wording that **watch direct BLE is observer-only**, while the separate **phone-relay / WatchConnectivity** path remains distinct and out of scope for this direct-BLE change.
- **Minimum code-change target added:** Reframed the implementation delta as a **tight watch-only** set of changes: no `0x01 0x00` auth-init, `J-PAKE` discovered only for skip/logging, `0x05` gated on `authenticated && bonded`, and `backfill` made optional for the initial `0x4E` happy path.

### v1.28 (2026-04-13 21:46 CEST)
- **Re-opened for DiaBLE observer alignment:** Header status now reflects that the watch path is back in planning review specifically to match the proven DiaBLE observer / eavesdrop sequence.
- **Exact Trio divergence documented:** Added a concrete delta section covering the remaining mismatches in `G7DirectBLEManager`: auth-init write, missing explicit J-PAKE skip, missing bonded gate on `0x05`, and backfill being treated as required startup readiness.
- **Implementation tasks narrowed to the watch path:** Updated **Phase B** to require auth notify only, passive `0x03` / `0x05 authenticated+bonded`, control notify then `0x4E`, optional backfill, and proof logging. Added an explicit observer proof checklist for validation.

### v1.27 (2026-04-13 00:47 CET)
- **Doc hygiene:** Removed the long header **Versioning** paragraph (it duplicated the changelog). **Status** line shortened to current facts + **Open**; added one-line pointer above **Prerequisites**.

### v1.26 (2026-04-13 00:44 CET)
- **CI / fastlane build 158:** New **Implementation log** **Record — CI / fastlane build 158** — **succeeded**; **status** / **versioning** lines updated.
- **Reason:** Document confirmed green build after **`TrioWatchApp.swift`** inclusion in patch **11** and **WatchKit** delegate API fix.

### v1.25 (2026-04-13 00:03 CET)
- **`didInvalidateWith` blocker fix:** New **Implementation log** **Record — `didInvalidateWith` error teardown ordering**; **Record — v1.24** delegate row **v1.25** pointer. **Design** **v1.15**; **Instrumentation report 03** **v1.17**; optional **`docs/code-review/`** diff refresh.
- **Reason:** External review — **pre-capture** session identity so **`ext_session_invalidated`** teardown runs on **error** invalidation.

### v1.24 (2026-04-12 23:55 CET)
- **Foreground re-entry renewal + connection-state audit:** New **Implementation log** **Record — foreground re-entry extended-runtime renewal + connection-state cross-repo check**; pointers to **design** **v1.14**, **report 03** **v1.16**, optional **`docs/code-review/`** diff refresh.
- **Reason:** Re-anchor ~1h **`WKExtendedRuntimeSession`** budget from **last active UI** when returning within 1h; document Trio vs **G7SensorKit** vs DiaBLE so renewal guards are not misread as “per-packet” states.

### v1.23 (2026-04-12 23:40 CET)
- **Scene phase decoupled from BLE `stop()`:** New **Implementation log** **Record — scene phase decoupled from BLE `stop()`**; **Phase A2** renamed + **Task A1** acceptance; **Code** table (**`applyForegroundActiveEntry`**, **`WatchState`**, **`ExtensionDelegate`**). **Design** **v1.13**; **Instrumentation report 03** **v1.15**.
- **Reason:** CGM stream should continue until extended runtime ends, not when the user returns to the watch face.

### v1.22 (2026-04-12 23:21 CET)
- **Extended runtime — continuous listening:** New **Implementation log** subsection **Record — extended runtime: continuous listening** — product intent (**stream** until **`stop()`** / teardown / OS expiry); **best practice** bullets; **RR2** / **v1.21** first-EGV invalidate **retracted**; **Code:** removed **`first_egv_received`** **`invalidateExtendedSession`** in **`G7DirectBLEManager`**. **Design** **v1.11** (Extended runtime + user flows + observability note).
- **Reason:** **v1.21** first-EGV invalidation matched **ChatGPT** “success-path termination” but **conflicts** with intended **ongoing** CGM → complication updates.

### v1.21 (2026-04-12 23:12 CET)
- **Red-team + ChatGPT + Claude consolidation:** New **Implementation log** subsection **Record — red-team + ChatGPT + Claude consolidation** — findings **RR1–RR8**, code change table, disagreements (**RR7** allowlist, **RR8** plist target), Tier 1 follow-on **`g7_ble_stop_deferred`** row superseded.
- **Code (`Trio` worktree):** **`G7DirectBLEManager`** — **`stop()`** invalidates extended session up front; **first persisted EGV** invalidates extended session; **`teardownSession`** main-thread assert; **`didInvalidateWith`** clears **`extendedSession`**; **`startScanning_rescan`** comment. **`AppleWatchManager`** — allowlist comment.
- **Reason:** Close **ChatGPT**/**Claude**/self-review issues on extended-runtime lifecycle and document dispositions.

### v1.20 (2026-04-12 22:58 CET)
- **Initiative / `docs/code-review/` decoupling:** Header **Diff review (out of band)**; **Task C2** reframed optional; **Record — Task C3** + **Tier 1 follow-on** table rows scrubbed; **Implementation log** baseline lines **Phase C** / **Artifacts** de-linked; **Versioning** paragraph **v1.12–v1.19** bullets cleaned (no initiative links to transient diff files). **Design** **v1.10**; **Instrumentation report 03** **v1.14**.
- **Reason:** Transient diff scratch docs are not tracked deliverables for this initiative.

### v1.19 (2026-04-12 22:57 CET)
- **iPhone → watch G7 name:** **Scope** + **Out of scope** — additive **`active_g7_peripheral_name`** only (not a broad WC redesign). **Implementation log:** new **Record — iPhone → watch active G7 peripheral name (WatchConnectivity)**; **Record — Tier 1 follow-on** **`WatchState`** row annotated **superseded** (historical **21:53** snapshot preserved).
- **Versioning paragraph:** **v1.19** bullet — see **Record** above; pointers to design **v1.9**, report **03** **v1.13**.
- **Status line:** Notes phone → watch wiring **implemented** alongside prior Tier 1 follow-on items.
- **Reason:** Document shipped **`WatchMessageKeys`**, **`AppleWatchManager`**, **`WatchState`** integration and distinguish from App Group sync.

### v1.18 (2026-04-12 21:53 CET)
- **Tier 1 follow-on:** **Implementation log** — **Record — Tier 1 follow-on (operational observability + extended runtime)**; **`G7DirectBLEManager`** + **`WatchState`** summaries; pointers to design **v1.8**, report **03** **v1.12** (historical optional diff scratch — **superseded** by **v1.20**).
- **Status / versioning paragraph:** **v1.18** describes follow-on vs **`b4dd0d7dd`**; patch regen noted as follow-up when committed.
- **Reason:** Encode Better Stack–friendly connect failure taxonomy, RSSI, active-sensor filter, extended runtime + inactive **`stop`** interaction, session outcome line.

### v1.17 (2026-04-12 14:59 CET)
- **Trio:** Feature commit **`b4dd0d7dd`** (`watch: G7 direct BLE Tier 1 instrumentation and lifecycle fixes`).
- **Patch stack:** **`patches/11-watch-direct-ble-g7.patch`** regenerated vs **`tmp/watch-direct-ble-baseline`** (**`dev` + 01–10**); **`patch-test.sh`** pass. **Implementation log:** **Record — patch 11 regeneration**.

### v1.16 (2026-04-12 14:00 CET)
- **Lifecycle single driver:** **`ExtensionDelegate.applicationWillResignActive`** no longer calls **`WatchState.handleForegroundInactiveOrBackground`** — **`TrioWatchApp`** **`.onChange(of: scenePhase)`** is the only entry for **`g7_ble_lifecycle`** leave-active / BLE **`stop()`** (comment in **`ExtensionDelegate`**). **Task A2** + **Record — Task C3** table updated.
- **Instrumentation report 03** **v1.11** — fixed stale “v1.8 controlled edition” note; **Placement / single source** paragraph aligned.

### v1.15 (2026-04-12 13:50 CET)
- **Instrumentation feedback (Tier 1):** **`WatchState`** — **`handleForegroundInactiveOrBackground(scenePhase:)`**; emit **`phase=background`** only when **`ScenePhase.background`** (pending session id from prior inactive); **`active_window_ms`** replaces misleading **`ms_since_last_active`** on **`stop_requested`**. **`G7DirectBLEManager`** — **`awaiting_gatt_setup`** cancels when **control** + **backfill** notifications are on; **`discovering_characteristics`** stage moved to **before** characteristic discovery call.
- **Docs:** Instrumentation report **03** **v1.10** (snapshot table + lifecycle / timeout / field naming); **Record — Task C3** table rows updated.
- **Diff review (historical):** Optional scratch **`git diff`** under repo **`docs/code-review/`** — **superseded** by **v1.20** (initiative no longer links).

### v1.14 (2026-04-12 13:36 CET)
- **`G7DirectBLEManager` logging:** **`logG7Ble`** forwards **`#fileID` / `#line` / `#function`** to **`WatchLogger.shared.log`**; removed dead **`logG7`**. **Shared conventions** updated; cross-reference to report **03** log attribution. **Design** bumped to **v1.5**; **instrumentation report 03** to **v1.9**. Reason: Better Stack and raw watch log lines should show **who called** the BLE logger (typically a **`Task`** body line for CB delegates), not the helper definition.

### v1.13 (2026-04-12 13:31 CET)
- **Diff doc location (historical):** Canonical scratch path was under **`Trio-dev`** `docs/code-review/` (duplicate **`Trio`** / stale **`in-progress/`** copies removed). **Superseded by v1.20** — initiative docs no longer link here.
- **Status:** **v1.13**.

### v1.12 (2026-04-12 13:25 CET)
- **Task C3:** **Tier 1** instrumentation per **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** landed in **`Trio`** (`G7DirectBLEManager.swift`, `WatchState.swift`) — session/stage/milestones/timeouts/lifecycle + Tier 2 reconnect + Tier 3 control opcode logging.
- **Implementation log:** New **Record — Task C3 (instrumentation Tier 1) — report 03**; **Record — build / deploy** “remaining” line adjusted (C3 → **Record — Task C3**).
- **Diff review (historical):** Refreshed optional scratch doc with working-tree **`git diff`** — **superseded by v1.20** (initiative decoupled).
- **Status:** **v1.12** — **Task C3** Tier 1 **implemented**; **open:** soak, patch **11** regen after commit, Phase **D** / tests per tables.

### v1.11 (2026-04-12 13:06 CET)
- **Cross-links:** Removed **(v1.2)** / **(v1.7)** suffixes from **Design reference** and **Instrumentation report** header lines — linked files’ headers are authoritative; avoids version churn in this doc when siblings bump.

### v1.10 (2026-04-12 13:02 CET)
- **Execution trail:** **Build and deploy** recorded **complete**; **status** line updated — **open:** soak, **Task C3** instrumentation (**03**), Phase **D** / tests per tables. New **Implementation log** subsection **Record — build / deploy**; **Record — patch stack** **Next** line superseded (historical).
- **Cross-links:** Design **v1.2**; instrumentation report **03** **v1.7** (lifecycle/`g7_session` coupling rule + **`WatchState`** hook single-source).

### v1.9 (2026-04-12 12:57 CET)
- **Instrumentation report:** **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** **v1.6** — explicit Tier 1 **watch lifecycle** (`g7_ble_lifecycle`, phases/reasons, timing, `g7_session`); timeout definition lead-in; reaffirmed **`g7_ble_*` + `g7_session`** wording; header cross-reference **(v1.6)**.

### v1.8 (2026-04-12 12:52 CET)
- **Instrumentation report:** **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** bumped to **v1.5** with **five** changelog entries (**v1.1–v1.5**) for feedback-driven revisions; header cross-reference updated to **(v1.5)**.

### v1.7 (2026-04-12 12:52 CET)
- **Instrumentation:** Added **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** (v1.0) to initiative; **Phase C** new **Task C3** — Tier 1–3 acceptance vs report **03**.
- **Phase A1:** Task text updated from **`lazy var`** to shipped **`@ObservationIgnored private let`** (matches **v1.6** implementation log and design **v1.1**); pointer to report **03** for lifecycle logs.
- **Cross-links:** Design reference bumped to **v1.1**; **Instrumentation report** line in header; versioning note for **v1.7**.
- **Reason:** Single normative place for session/stage/timeout/lifecycle instrumentation; aligns design “lazy” wording with shipped **`@ObservationIgnored private let`** (design **v1.1**).

### v1.6 (2026-04-11 23:31 CET)
- **CI / Swift:** New **Implementation log** subsection **Record — CI build: `WatchState` `g7DirectBLEManager` storage (`@Observable` + `lazy`)** — documents **`xcodebuild`** failures (`lazy` vs computed/macro expansion; **`ObservationTracked` / init accessor**), resolution (**`import Observation`**, **`@ObservationIgnored private let`**, no **`lazy`**), **`G7DirectBLEManager`** init cost note, **patch 11** regeneration + **`patch-test.sh`** pass, and **Phase A1** plan vs shipped wording.
- **Status:** Bumped to **v1.6**.

### v1.5 (2026-04-11 23:23 CET)
- **Patch stack:** New **Implementation log** subsection **Record — patch stack (`Trio-dev`) — patch 11** — documents **`generate-patch.sh`** with **`--include-files`**, first **`patch-test.sh`** failure on raw **`-t dev`** after patches **01–10**, regeneration against **`tmp/…-baseline`** (**`dev` + 01–10**), successful **`patch-test.sh`** for **01–11**; artifact **`patches/11-watch-direct-ble-g7.patch`**.
- **Status:** Bumped to **v1.5** — ready for **build + deploy**; soak/tests still open.

### v1.4 (2026-04-11 23:05 CET)
- **Cursor v2 (pre-soak):** New **Record — Cursor review (v2, pre-soak)** — assessment summary, **fix:** `teardownSession` reconnect only when **`!isFailure`** (stops protocol-failure loops); **RT3** disposition updated to **partially addressed**.
- **Code:** `G7DirectBLEManager.teardownSession` — `if scanningStarted, !isFailure { … }` for 7s rescan work item.

### v1.3 (2026-04-11 22:57 CET)
- **Red-team self-review (full):** New subsection **Record — red-team self-review (full pass, prompt 05)** with findings **RT1–RT6**, coverage table, verdict, updated **R3** disposition (**Resolved**), and **code fixes** — `startScanning` cancels in-flight peripheral; **`startScanning_rescan`** + **`didDisconnect` early return** to avoid duplicate `teardownSession`/reconnect when rescanning.
- **Reason:** Close prompt-05-style **blocker-class** issues from adversarial pass; document remaining opens (tests, soak, backoff, log sanitization).

### v1.2 (2026-04-11 22:52 CET)
- **External code review:** Added table **Record — external code review (Claude) + fixes** with disposition per finding (write-error teardown, EGV gate, activation `txTime`, reconnect, R6.1 trend parity, `isFailure` disconnect state, optional parsers; #3 N/A; #10 won’t apply; #11 open).
- **Implementation log:** Updated Phase **D** partials; **Open follow-ups** point to v1.2 review.
- **Plan text:** Task **B3** corrected (control-only EGV gate; synchronous save on main).
- **Self-review table:** R4 marked **Resolved** (aligned with optional parse helpers).

### v1.1 (2026-04-11 22:47 CET)
- **Post-implementation bump:** Added **Implementation log** (baseline, landed work vs `1b3919a7c`, artifacts, Phase D not executed, open follow-ups) and **self-review** record (prompt **05**, IDs R1–R8, verdict, **AGENTS.md** alignment). Introduced versioning note under title: **v1.0** = prospective plan only; **v1.1** = first revision that records actuals + review.
- **Reason:** Separate “plan as written before coding” (**v1.0**) from “what happened + red-team self-review” (**v1.1**) for traceability.

### v1.0 (2026-04-11 22:45 CET)
- Initial **pre-implementation** implementation plan: **Scope** through **Hypotheses** only — prerequisites, Phases **A–D** task specs (prospective), risks, hypotheses. **No** implementation log, **no** post-implementation self-review, **no** code-review artifact pointer required to satisfy v1.0 (those belong to execution and v1.1).
