# Build 190 — Implementation Plan (v2.7)

## 1. Document metadata

| Field | Value |
|---|---|
| Title | Build 190 — Implementation Plan |
| Version | 2.7 |
| Timestamp | 2026-04-27 23:17 CET |
| Branch | `feature/watch-g7-direct-ble-observer-synthesis` |
| Build under review | 189 |
| Target build | 190 |
| Source inputs | (a) prior v1.0 / v2.0 / v2.3 of this plan, (b) BetterStack log re-query 2026-04-24 → 2026-04-27, (c) `G7DirectBLEObserver.swift` build 189, (d) ChatGPT review of v2.0 (2 rounds) plus diff-aware ranking, (e) historical **185→186→187→188→189** source progression (protocol-relevant deltas pinned per transition), (f) historical context: `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true` removed for user-facing OS notification cost (**186→187**, not “185–188” generically), (g) **full 185→186→187→188→189 diff progression** with line-level references in archived `G7DirectBLEObserver.NNN.swift` snapshots |
| Status | Implementation-ready |
| Identity of this build | **Hardening** (P0-A/B/C/E, P1-A/B/C/D, P2-A/B) plus **185-parity regression restorations** **P0-D Experiments 4 and 1** (coupled pair — see §7). **P0-D Experiment 2** is **downscoped** to generation-check + instrumentation for the surviving 30 s discoveringServices watchdog (no behavioral revert assumed). |

---

## 2. Executive summary — what changed since v2.3

The **full diff progression invalidates** the old “185↔188 only” framing. Protocol-relevant changes landed across **multiple transitions** (not solely at 188), and the measured success-rate steps (**11.7% → 5.3% → 1.6% → 0%**) align with that layered story.

**Two structural consequences:**

1. **No single 188 revert restores 185.** At minimum, **two** surviving parity gaps matter for the drop toward zero: **(a)** `willRestoreState` semantics (**entered 185→186**; build **186 still achieved ~5.3%** — necessary for full parity, **not sufficient alone** for the 0% outcome), and **(b)** removal of the early-path **`registerForConnectionEvents`** call (**187→188** change set; unique **188+** protocol delta that survives in 189 — **P0-D Experiment 4**).

2. **Sensor swap timing does not drive the diagnosis.** DXCMQU appears in logs only after the user’s normal sensor rotation (~**05:00 UTC 2026-04-27**). **Build 188’s DXCM08-only window** (before that swap) provides **sensor-controlled isolation**: same DXCM08 hardware path as build 185, different code, **72 connects / 0 `0x05`** — see §3.4. Standard G7 behavior is assumed; the narrative does **not** attribute outcomes to “two sensor types in the ledger.”

**Build 190 priorities (this doc, v2.7):**

- **P0** — P1-A (first-stamp-only phase timestamps).
- **P0** — P0-E (session generation).
- **P0** — P0-A (re-entry guard; addresses **Bug 1 surface introduced in 189** — see §5.6).
- **P0** — P0-B (connection-event self-loop).
- **P0** — P0-C (persisted ID write-on-connect; ladder reorder; clear-on-failures).
- **P0** — **P0-D Experiment 4** — restore early-path `registerForConnectionEvents` (parity with 185–187). **Strongest 188+-unique surviving regressor.**
- **P0** — **P0-D Experiment 1** — `willRestoreState` eager attach for **connected** restores. **Necessary** for 185 parity; **not sufficient alone** (186 had it and still ~5.3%).
- **P1** — P1-B (re-anchor and shorten fallback).
- **P1** — P1-C, P1-D (fallback skip logging; auth-observation instrumentation).
- **P1 (downscoped)** — **P0-D Experiment 2:** generation-check + log the **30 s discoveringServices** watchdog per P0-E; auth-stage timeout **verified absent** in 189 source (Open Q6 **closed** — §5.2).
- **P2** — P2-A (drop stale-`.connecting` cancel), P2-B (in-session debounce).
- **Defer:** P0-D Experiment 3 (instrument-only timing moves **within** `.poweredOn`) — **superseded for parity** by Exp 4’s early-path restore; optional diagnostics only.
- **Defer but prepare:** packet capture; **185↔186 per-commit bisection** of `G7DirectBLEObserver.swift` as **190 development-phase** deliverable if Exp 4+1 restore **~5%** not ~12% (EDIT G).

**Development-phase deliverable (bisection):** The **185→186** transition bundled **multiple** behavioral changes (`willRestoreState` flip, stale-`.connecting` cancel, `connectInFlight` / `isDiscoveringServices`, post-EGV backoff, etc.). Attribution of the **11.7% → 5.3%** step to `willRestoreState` alone is a **leading hypothesis**, not a measured fact. If Build 190 (Exp 4 + Exp 1 + hardening) lands near **186-like** success rather than **185-like**, run **per-commit bisection** between **185 and 186** during the 190 cycle.

---

## 3. Updated Build 189 evidence review

### 3.1 Per-build success ledger (Apr 24 → Apr 27, watchos)

**Definitions:** unchanged from prior versions (*Sessions* = `g7_ble_session_outcome` rows; *Success* = `sessionEGVCount > 0`; raw counts subject to WatchLogger duplication — treat ordinally).

| Build | First seen UTC | Sensor mix (ledger) | Sessions | Success | EGVs (raw) | `0x05` events | `0x03` events |
|---|---|---|---|---|---|---|---|
| 184 | Apr 24 12:14 | DXCM08 | 12 | 0 | 0 | 0 | 0 |
| **185** | **Apr 24 22:32** | **DXCM08** | **1044** | **122** | **125** | **140** | **134** |
| 186 | Apr 25 21:46 | DXCM08 | 724 | 38 | 38 | 38 | 43 |
| 187 | Apr 26 19:50 | DXCM08 | 249 | 4 | 4 | 4 | 4 |
| 188 | Apr 26 23:29 | DXCM08 → DXCMQU mid-build | 265 | 0 | 0 | 0 | 0 |
| 189 | Apr 27 16:54 | DXCMQU | 20 | 0 | 0 | 0 | 0 |

Approximate success rates: **185 ~11.7%**, **186 ~5.3%**, **187 ~1.6%**, **188–189 0%**.

### 3.2 Build 185 happy-path baseline

Build **185** established the **passive observer contract** end-to-end on watchOS: attach via persisted ID / retrieval / scan; discover services; enable **authentication** notify; **wait** for sensor-emitted **`0x05`** (authenticated + bonded) before advancing; enable **control** notify; write **`0x4E`** EGV request; parse EGVs and save snapshots. **MOD-E** (`registerForConnectionEvents`) drove overnight **peer_connected** → attach ladder cycles without requiring foreground. **Fallback** (`authFallbackDelay` 6 s) was a safety net when status bytes did not arrive in time — in successful runs, **`0x05` arrived ~1 s** and fallback often did not fire. That baseline is the functional target for “regression materially fixed” in §10.

### 3.3 Ledger vs. headline isolation

§**3.1** aggregates **full-build** rows (a build may span **DXCM08 → DXCMQU** mid-window). **Rates** are therefore blend-sensitive. **§3.4** uses the **DXCM08-only** slice of build **188** as **sensor-controlled code isolation** — do not mix that conclusion with blended ledger denominators without stating the window.

### 3.4 Headline isolation evidence — build 188, **DXCM08-only** window

**Build 188 against DXCM08 only:** In the window from build 188 **first seen 2026-04-26 23:29 UTC** until the user’s normal sensor swap to DXCMQU at **~05:00 UTC 2026-04-27**, build 188’s code produced **72 connects**, **0** `auth_payload_received` events, **0** EGVs against the **same DXCM08** sensor family build 185 used for **122** successful sessions. That is **direct, sensor-controlled isolation of the regression to code** on the passive-observer path — independent of any later DXCMQU rows in the aggregate ledger.

### 3.5 Suspension and scheduling (H6)

watchOS may **suspend** the extension or **delay** queued work. Logs match **late fallback firing**, **stretched inter-callback gaps**, and **session windows missed** without proving the OS scheduler root cause. **Not** a substitute for code regression fixes — treat as **environment** that **P0-E** (generation-tagged timers) and **P1-B** (callback-anchored fallback) must tolerate.

### 3.6 Trace to §4 / §7

**H6** (suspension/throttling) is the hypothesis bucket for this behavior; mitigations are **P0-E**, **P1-B**, and careful log interpretation during Tier 1 soak.

## 4. Hypothesis verdicts (revised)

| # | Hypothesis | Verdict | Why |
|---|---|---|---|
| H1 | Bug 1 (duplicate config / fallback reset) | Real — **189-introduced surface** | `discovery_skipped reason=already_discovered` short-circuit (**188→189**) re-enters `configureObserverCharacteristics`; P0-A still correct. See §5.6. |
| H2 | Fallback timing too late | Real but secondary | When it fires, late. 185 succeeded without fallback firing. |
| H3 | `0x05` not observable to a late observer | **Rejected** | Observed abundantly in 185; 188 DXCM08 window isolates code. |
| H4 | Observer must subscribe before Dexcom auth completes | **Rejected** | 185 successes with normal cadence. |
| H6 | watchOS suspension/throttling | Strongly supported | S6 / S8 / S3 / S7 class logs. |
| **H7** | Control path invalid even with ACK | Downgraded — not primary | 185 proves path *can* work; 189 path may differ post-auth. |
| H8 | CBError 7 = sensor rejection | Rejected | 185 successes also see CBError 7. |
| H9 | Bug 2 stale persisted ID | Confirmed | Prior evidence stands. |
| H11 | Phase-timestamp overwrite | Confirmed | P1-A. |
| **H12** | Surviving **188+** protocol deltas block `0x05` | **Open — narrowed** | Leading candidates: **Exp 4** (early `registerForConnectionEvents` removal) + **Exp 1** (`willRestoreState` deferral since **186**). §5. |

---

## 5. Build 185 → 186 → 187 → 188 → 189 diff: regression-candidate audit

Each candidate below is pinned to the **transition where it entered**, which builds it was **active** in, and how that lines up with **observed rates**. Suspicion is stated separately for **“185→186 step”** vs **“path to 0%”** where they differ.

### 5.1 `willRestoreState` semantics (HIGH for 185→186 step; MEDIUM for 0% problem)

- **Entered:** **185 → 186** (not “185→188” only).
- **185:** eager attach for **connected** restores (delegate, `activePeripheral`, discover).
- **186+:** defer attach to central powered-on / foreground ladder; cancel **non-connected** restores only; **connected** not cancelled (189 source).
- **Empirical:** **186** ran with the new semantics and still produced **~5.3%** success → change is **not sufficient** for 0% **alone**; still **required** for full **185** parity.
- **P0-D Exp 1:** ship parity revert; **calibrate expectations** — do not treat Exp 1 as “the sole fix” for 0%.

### 5.2 Stage-timeout machinery (**HIGH** for **188**; **LOW** for **189**)

- **Entered:** **187 → 188** (`scheduleDiscoveringServicesStageTimeout` **30 s**, `scheduleObservingAuthStageTimeout` **10 s**).
- **188:** both active; **Option C** + auth-stage watchdog sufficient to rationalize catastrophic failure **in 188**.
- **189:** **`scheduleObservingAuthStageTimeout` removed** — verified **not defined / not called** in live 189 `G7DirectBLEObserver.swift`. **Open Q6 closed.**
- **Surviving:** **30 s discoveringServices** watchdog; discovery typically completes **&lt;1 s** in observed sessions → **unlikely** to fire during auth-phase; risk is mainly **stale work-item** behavior → **P0-E generation-check** + logs.
- **P0-D Exp 2 (v2.5):** **No gated 190 vs 191 revert tree.** Scope = **generation-check** the surviving watchdog + `g7_ble_stage_timeout_*` events. Remove any **residual** auth-stage scheduler if ever reintroduced (Tier 0).

### 5.3 `registerForConnectionEvents` lifecycle (**HIGH** — promote from prior MEDIUM)

- **185–186:** early registration in **`connect()`** path on attempts.
- **187:** `.poweredOn` site **added** → **two** registration sites (early + poweredOn).
- **188–189:** **early path removed** (187→188 deletion) → **only** `.poweredOn` remains.
- **Unique 188+ protocol delta surviving 189** that differs from **every non-zero-rate** build’s early-path behavior.
- **Mechanism (hypothesis):** `.poweredOn` may be **once per process lifetime**; **`connect()`** re-registration restored robustness each attempt.
- **P0-D Experiment 4:** restore early-path `registerForConnectionEvents` — **required** parity item; keep `.poweredOn` site.

### 5.4 Stale-`.connecting` cancel in `connect()` (MEDIUM; entered **185→186**)

- **186** had this cancel and **~5.3%** → **not sufficient** for 0%.
- **P2-A:** drop cancel branch (unchanged recommendation).

### 5.5 Phase metric overwrite (defect, not regressor)

Unconditional `sessionPhaseAuthNotifyAt = Date()` — P1-A.

### 5.6 Bug 1 surface — **`discovery_skipped reason=already_discovered`** (**189**, not 188)

**188→189** added the guard that short-circuits when `peripheral.services != nil`, logs `g7_ble_discovery_skipped reason=already_discovered`, and **calls `configureObserverCharacteristics` directly** — surfacing duplicate notify / fallback-reset behavior **more aggressively** than 188’s path. **Narrative:** Bug 1 metrics **worsen visibility in 189**; root fix remains **P0-A** re-entry guard.

### 5.7 Retained changes reviewed but deprioritized (annotated)

| Change | Annotation |
|---|---|
| **`CBConnectPeripheralOptionNotifyOnDisconnectionKey: true` removed** | **186→187** (not “185–188”). User cost if restored — **not** a default action. |
| **290 s post-EGV backoff** | Active **186–188**; **replaced** in 189 — not an “188+ only” story. |
| `connectInFlight` / `isDiscoveringServices` | Introduced with 186-era guards — not primary 0% suspects alone. |
| Instrumentation-only rows | Unchanged rationale. |

### 5.8 Rate progression **185→186→187** — partial answer (formerly Open Q7)

- **185→186 (~−54%):** **`willRestoreState`** flip is the leading explainable delta; contributors may include stale-`.connecting` cancel, post-EGV backoff timing, discovery guards.
- **186→187 (~−70%):** **Confidence intervals overlap** given N — may include **noise**. If real: **`NotifyOnDisconnectionKey` removal** (unlikely `0x05` mechanism) **or** interaction with **dual** `registerForConnectionEvents` sites added in **187**.

---

## 6. Alternative explanations / hypotheses considered

| Hypothesis | Status |
|---|---|
| Dexcom watch app not running / no warm session | Operational — out of scope for code; logs show connect success |
| watchOS jetsam / suspension eating timers | Partially supported (H6); mitigated by P0-E + P1-B |
| Sensor firmware or iOS Dexcom app version drift | Possible if **all** code-parity restores fail — packet capture |
| Wrong BLE UUID / opcode drift | Low — same sensor family; escalate only after Tier 2 **no restoration** |

**H7** / **H12** tracking: see §4 and §5. **No sensor-model split** as a diagnosis axis — standard G7; isolation evidence in §3.4.

---

## 7. Build 190 implementation plan

### Build strategy — pick **Option A** or **Option B** (do not mix without labeling)

The plan **commits** to one of:

**Option A — Attribution-preserving sequence**

1. **190a:** Hardening only (through P0-C + P1-A where practical).
2. **191:** Add **P0-D Experiment 4** only (early `registerForConnectionEvents`).
3. **192:** Add **P0-D Experiment 1** (`willRestoreState` eager attach).

Each build adds **one** parity variable from the post-hardening baseline.

**Option B — One-shot (recommended default)**

**Single Build 190** ships **hardening + P0-D Exp 4 + P0-D Exp 1** together. **Causal attribution per fix is forfeited** within that binary; interpretation is **bundle-level** (“worked / didn’t”). **Recommended** when **time-to-recovery** dominates and TestFlight iteration is costly.

**Coupled pair:** Experiments **4** and **1** are **both** necessary **185-parity** restorations for the layered regression story — not independent hypotheses to rank against each other in one A/B sense.

**Rollback:** If Build **190** is worse than **189** in session health (e.g. duplicate **`auth_notify_enabled`**, Option C–like ordering, or success rate **below** 189’s observed band), **revert to the 189 shipping baseline** and re-apply changes in smaller slices (Option A). **190** must not accumulate unexplained regressions — treat **189** as the safety anchor.

---

### P0-A — Re-entry guard (session + peripheral identity)

**Problem.** Build **189** can reach **`configureObserverCharacteristics`** twice within one logical session — notably via **`discovery_skipped reason=already_discovered`** (§5.6) **and** the normal post-`discoverServices` completion path. That duplicates **`setNotifyValue(true)`** on auth, **re-arms fallback timers**, and corrupts ladder metrics (**Bug 1**).

**Goals.** At most **one** coherent observer-configuration pipeline per **`{peripheral.identifier, session generation}`** unless a full teardown explicitly resets state.

**Implementation.**

1. **`configureObserverCharacteristics(peripheral)`** — add an **identity + generation gate** at entry: require `peripheral.identifier == activePeripheral?.identifier` (or equivalent “this peripheral is the session owner” rule already used elsewhere); require **`sessionGenerationAtConnect == currentSessionGeneration`** (names as implemented — see P0-E). On mismatch: log `event=g7_ble_observer_config_skipped reason=stale_identity_or_gen` and **return**.
2. **`observerConfigInFlight` (Bool):** set **`true`** at the **start** of the **first** `configureObserverCharacteristics` invocation for **`currentSessionGeneration`**; **`false`** on full teardown paths and when auth+control setup for this session is abandoned. The **189** **`discovery_skipped reason=already_discovered`** branch **must** check this flag: if **`true`**, log **`event=g7_ble_discovery_skipped_suppressed reason=already_configuring`** and **do not** call **`configureObserverCharacteristics`** again.
3. Coordinate with **P0-E**: any **generation bump** invalidates stale work; the flag resets with session teardown / generation bump per implementation.

**Acceptance.** Logs show **one** primary **`g7_ble_auth_notify_enable_requested`** sequence per **`currentSessionGeneration`** per peripheral for stable sessions; no triple **`auth_notify_enabled`** spikes attributable to duplicate config entry.

---

### P0-B — Ignore `peerConnected` for Trio’s own active peripheral

**Problem.** **MOD-E** fires for peer connections **including** connections initiated by Trio’s **`central.connect`**. Running **`startOrResume`** again on that event duplicates attach / discovery (**Bug family related to session machine churn**).

**Change.** Early in **`connectionEventDidOccur`** for **`.peerConnected`**: if **`peripheral.identifier == activePeripheral?.identifier`**, log **`event=g7_ble_connection_event_skipped reason=own_active_peripheral`** and **return** (do not call **`startOrResume`**).

**Acceptance.** No immediate double **attach** ladder for the same peripheral UUID Trio just connected.

---

### P0-C — Persisted peripheral identifier on connect; clear-on-failures

**Problem.** **Bug 2** — stale **`UserDefaults`** peripheral UUID points at wrong sensor after swap or extended failure windows.

**Writes.** On **`didConnect`** (validated path): persist **`persistedPeripheralIdentifier = peripheral.identifier`** once the peripheral is accepted as the active G7 target **before** relying on retrieval for subsequent launches.

**Clears.** Keep **all existing** explicit clear sites; extend only if new failure classes appear in logs. Policy: clear on **definitive** wrong-device / repeated **connect_failed** streaks **per existing codebase conventions** — do not diverge silently from **`clearPersistedIdentifier`** semantics already in **`G7DirectBLEObserver.swift`**.

---

### P0-E — Session generation tagging

**Problem.** **`DispatchWorkItem`** callbacks (**fallback**, **reconnect**, **stage timeouts**) can fire after reconnect churn and mutate the wrong session.

**Critical with P0-D Exp 1:** For **already-`.connected`** restored peripherals, CoreBluetooth **does not** necessarily fire **`didConnect`** again. **Exp 1** attaches from **`willRestoreState`** **before** any **`didConnect`**. If generation were bumped **only** in **`didConnect`**, the restore path would run with a **stale generation** — **P0-A**’s stale-gen guards and **all** timer guards become **wrong** on exactly the path Exp 1 adds.

**Implementation.**

1. **`private var currentSessionGeneration`** (UInt / UInt64 — match codebase). **Exactly one increment per logical attach**, using **one** of two canonical sites (CoreBluetooth **does not** redeliver **`didConnect`** for already-**`.connected`** restores — that path uses only the second bullet):
   - **`didConnect`** — after resetting per-session state that must not bleed (**`hasAdvancedBeyondAuth`**, notify flags per policy, phase timestamps per policy) **before** scheduling timers or calling **`discoverServicesIfNeeded`**.
   - **`willRestoreState`** — in the **`peripheral.state == .connected`** branch **of Exp 1**, **after** assigning **`delegate`** / **`activePeripheral`** and **before** **`discoverServicesIfNeeded(peripheral)`**, perform the **same** generation bump + per-session reset bundle as **`didConnect`** would for a new session on this peripheral (shared helper **`beginSessionGeneration(for: reason:)`** recommended).
2. **Every deferred work item** that mutates BLE state captures **`let gen = currentSessionGeneration`** at **schedule** time; first line of execution: **`guard gen == self.currentSessionGeneration else { log … stale_gen; return }`**.
3. **`cancelTransientTimers()`** remains the primary immediate cancel on teardown; generation bump ensures **late** items self-drop.
4. Log **`event=g7_ble_session_generation_bumped new_gen=<n> reason=<did_connect|will_restore_connected>`** when incrementing.

**Dependency.** Must land **before** interpreting timer-related logs for Build 190 stop conditions. **Land P0-E before or with Exp 1** — not after.

---

### P1-A — First-stamp-only session phase timestamps

**Problem.** **`sessionPhaseAuthNotifyAt = Date()`** (and similar) **overwrites** on duplicate **`auth_notify_enabled`** callbacks → **`connect_to_auth_notify_ms`** and ladder metrics become **garbage**.

**Change.** For each **`sessionPhase*At`** field: assign **only when the stored value is `nil`** for the current connect cycle (first stamp wins). Reset all phase fields to **`nil`** at **`connect()`** / session boundary per existing pattern.

**Acceptance.** Stable **`session_outcome`** ladder intervals; absence of alternating **0 ms** / huge ms spikes from duplicate stamps.

---

### P1-B — Re-anchor and shorten the auth fallback

**Issue.** Fallback is scheduled from **`configureObserverCharacteristics`** immediately after **`setNotifyValue`** **request**, not from **`auth_notify_enabled` success**. With **6 s** delay, most of the usable Dexcom window can elapse before fallback fires **if** notify-enable is slow.

**Change.**

1. **Remove** **`scheduleAuthFallback(peripheral)`** from **`configureObserverCharacteristics`** (leave **`cancel`** there if needed).
2. **Call** **`scheduleAuthFallback`** from **`handleNotificationState`** in **`G7BLEUUID.authentication`** branch **after** **`auth_notify_enabled result=success`** with **`characteristic.isNotifying == true`** (same queue semantics as today).
3. **`authFallbackDelay = 2`** seconds (named constant).
4. **Generation-tag** the work item per **P0-E**; stale generation → **`g7_ble_auth_fallback_skipped reason=stale_gen`** (see P1-C).

**Why keep fallback.** Build **185** usually received **`0x05`** ~**1 s** and advanced via **`auth_authenticated_bonded`**; fallback is **bounded recovery** when **`auth_notify_enabled`** succeeded but **`0x05`** never arrives — **not** Option C.

**Option C-lite** (immediate advance on notify-enabled): **NOT in Build 190.**

---

### P1-C — Fallback skip logging

When a fallback **`DispatchWorkItem`** runs but **`scheduledGeneration != currentSessionGeneration`**, log **`event=g7_ble_auth_fallback_skipped reason=stale_gen scheduled_gen=<n> current_gen=<m>`** and return without **`advanceToControl`**.

---

### P1-D — Auth-path instrumentation (Build 190)

Add **sparse, high-signal** logs (tunable if rate is high):

- **`event=g7_ble_auth_path_summary`** once per session (or on teardown): counts **`handleAuthPayload`** by opcode; **`first_0x05_delta_ms`** from **`auth_notify_enabled`** if both timestamps exist.
- Ensure **`advanceToControl(reason:)`** logs reason on **first** transition only if duplicate calls are still possible — helps falsify Option C regressions.

---

### P2-A — Drop stale-`.connecting` cancel in **`connect()`**

**Context.** Cancel branch entered **185→186**; **186** still had **~5.3%** success — not the sole **0%** driver; **P2-A** may reduce **callback disorder** at connect.

**Change.** Remove:

```swift
if peripheral.state == .connecting {
    centralManager.cancelPeripheralConnection(peripheral)
    log("event=g7_ble_stale_connect_cancelled ...")
}
```

immediately before **`central.connect`**. Rely on **`connectInFlight`** + **P0-E** to drop stale disconnect side effects.

**Rollback trigger.** If parallel **`connect_attempt`** storms return in logs, restore **only** with metrics proving benefit — prefer **P0-B** / attach ladder guards first.

---

### P2-B — In-session foreground debounce

**Purpose.** Reduce **`startOrResume`** thrash from rapid **`scenePhase`** flips **without** delaying first cold-launch attach.

**Implementation.** If the codebase already has **`failedAttempts`** / cooldown hooks on foreground, tighten **only** the path that fires **`startOrResume(reason:)`** twice within **~300–500 ms** **while `activePeripheral?.state == .connected`** — **no debounce** on cold start / first **`hasReceivedForegroundEntry`**.

**Verify-before-build:** grep **`applyForegroundActiveEntry`** / **`startOrResume`** — align with existing **`watch-g7-direct-ble-observer`** branch behavior; **skip** if redundant with **189** scheduler.

---

### P0-D — Regression isolation

**Option C** remains **out** — 189 reverted it; do not reintroduce immediate advance on notify-enabled before authenticated payload.

#### Experiment 4 — Restore early-path `registerForConnectionEvents` (**ships in 190 under Option B**)

**Change:** At **`connect()`** entry (or equivalent before peripheral work), when `central.state == .poweredOn`:

```swift
centralManager.registerForConnectionEvents(options: [
    CBConnectionEventMatchingOption.serviceUUIDs: [
        G7BLEUUID.advertisement,
        G7BLEUUID.dataService
    ]
])
log("event=g7_ble_connection_events_registered reason=connect_attempt")
```

**Keep** the existing `.poweredOn` registration block — both matter for different lifecycle phases.

**Note (aggressiveness vs 185):** Build **185** registered earlier in the lifecycle (not necessarily on **every** `connect()` attempt). Calling **`registerForConnectionEvents`** on each **`connect()`** while **`.poweredOn`** is **slightly more aggressive**. Per Apple’s contract, repeated calls with the **same options** replace prior registration and are **safe** / **idempotent** in effect. If logs show **connection-event** anomalies, **narrow the site** (e.g. foreground + `connect()` only) in a follow-up build.

**Stop condition:** Non-zero `0x05` in protocol-reaching sessions when combined with hardening + Exp 1 per §10.

#### Experiment 1 — `willRestoreState` eager attach (**connected** restores)

**Change:** if **`peripheral.state == .connected`** in **`willRestoreState`**: set **`peripheral.delegate`**, assign **`activePeripheral`**, then **bump session generation** (P0-E — same helper as **`didConnect`**) **before** **`discoverServicesIfNeeded(peripheral)`**. **Keep** cancel **only** for **`state != .connected`**. Log **`g7_ble_restore_attached`** vs **`g7_ble_restore_cancelled`** / skip-cancel as today.

**Interaction with 189 `discovery_skipped`:** Exp 1 calls **`discoverServicesIfNeeded`** immediately; CB may return cached services → **`peripheral.services != nil`** → **189** takes **`discovery_skipped reason=already_discovered`** → **`configureObserverCharacteristics`** runs **without** a fresh **`discoverServices`** round-trip. That is the **Bug 1** surface. **Correctness requires:** (i) **P0-E** generation bumped **on this path** before config; (ii) **P0-A** identity + gen gate + **`observerConfigInFlight`** so the short-circuit does **not** double-enter **`configureObserverCharacteristics`** for the same generation.

**Expectation:** **Necessary** for 185 parity; **insufficient alone** for full rate recovery (186 precedent).

#### Experiment 2 — Downscoped (**30 s discoveringServices** watchdog)

Verify **no** **`scheduleObservingAuthStageTimeout`**; **generation-check** + instrument **`scheduleDiscoveringServicesStageTimeout`** per P0-E (`g7_ble_stage_timeout_*`).

#### Experiment 3 — **Superseded** for parity by Exp 4

Defer micro-moves of the `.poweredOn` registration site unless diagnostics still show ordering bugs **after** Exp 4.

#### **Cut:** `CBConnectPeripheralOptionNotifyOnDisconnectionKey: true`

Still **out** — user-facing notifications.

---

## 8. Items deferred to post-190

| Item | Reason | Pull forward when |
|---|---|---|
| P0-D Exp 3 (`.poweredOn`-only timing tweaks) | Superseded by Exp 4 for early-path parity | Still failing after Exp 4 + 1 |
| Option C-lite | 189 revert surface | **Tier 0–1** clean, Exp 4+1+hardening still fail, diagnostics justify |
| `NotifyOnDisconnectionKey` restoration | OS notification spam | Unlikely |
| Foreground-only mode | Premature | Fallback anomalies persist post P1-B |
| **Packet capture — execution** | Escalation | Tier 2 **no restoration** after bundle (§10) |
| **185↔186 bisection** | Optional until needed | Exp 4+1 yields **~186-like** not **185-like** success |

**Packet capture — preparation** (not deferred; do during 190 development so Tier-2 failure can escalate same day):

- Choose tooling: **PacketLogger** (paired Mac) and/or **Nordic nRF Sniffer** on a dedicated test device.
- Predefine what to answer: (a) does the sensor emit **`0x05`** only to the bonded central’s link vs broadcast; (b) does the Dexcom watch app re-run full auth each connect vs once per session; (c) which link-layer event immediately precedes disconnect after Trio’s **`0x4E`** write.
- Write one-paragraph **capture success criteria** (what log pattern or frame observation would confirm each).

## 9. Logging and instrumentation plan

Baseline: **every** new or touched log line uses **`event=g7_ble_*`**, **`key=value`** pairs, **`WatchLogger`**. Do not add duplicate logging frameworks.

| Event | When | Fields |
|---|---|---|
| `g7_ble_connection_events_registered` | Early-path **and** `.poweredOn` | `reason=connect_attempt` / `reason=powered_on` |
| `g7_ble_connection_event_skipped` | Self-loop / duplicate handling | `reason=own_active_peripheral` |
| `g7_ble_stage_timeout_scheduled` | discoveringServices watchdog armed | `stage`, `gen`, `delay_s` |
| `g7_ble_stage_timeout_fired` | Post generation-check | `stage`, `gen`, `current_gen` |
| `g7_ble_session_generation_bumped` | P0-E — **`didConnect`** **or** **`willRestoreState` connected** | `new_gen`, `reason=did_connect` / `will_restore_connected` |
| `g7_ble_observer_config_skipped` | P0-A gate rejects stale work | `reason=stale_identity_or_gen` |
| `g7_ble_discovery_skipped_suppressed` | 189 short-circuit suppressed | `reason=already_configuring` |
| `g7_ble_restore_attached` / `g7_ble_restore_cancelled` | Exp 1 | `peripheral_id`, `state` |
| `g7_ble_auth_fallback_skipped` | Fallback not run | `reason=stale_gen` |
| `g7_ble_auth_path_summary` | Consolidated auth-path diagnostics | Policy-specific key=value pairs |

---

## 10. Success criteria for Build 190

### Tier 0 — Pre-build invariants (must pass before tagging Build 190)

1. **`scheduleObservingAuthStageTimeout`** is **not** defined and **not** called.
2. **Option C** immediate-advance block **absent** from `handleNotificationState` for auth notify-enabled.
3. No **new** `advanceToControl` call sites firing from CB callbacks **without** sensor-emitted auth payload path **except** documented fallback (post P1-B).
4. **290 s** post-EGV backoff **absent** if policy says removed (match 189 intent).

### Tier 1 — Hygiene and ordering (must pass for a valid soak)

Interpret logs over the **24 h** soak window used for Tier 2.

1. **No Option C:** no **`advanceToControl(reason: auth_notify_enabled_observer)`** (or equivalent immediate advance on **`auth_notify_enabled`** before **`g7_ble_auth_payload_received authenticated=true bonded=true`**).
2a. **No Option C–style reorder when `0x05` exists:** in any session where **`g7_ble_auth_payload_received`** with **`opcode=0x05`** and **`authenticated=true bonded=true`** is logged, that event must precede the first **`g7_ble_control_notify_enable_requested`** (or equivalent control advance) **for the same `currentSessionGeneration`**.
2b. **Advance reasons:** every **`g7_ble_control_notify_enable_requested`** (or equivalent control advance) must be preceded by **either** (i) a matching **`0x05`** payload event **for that generation**, **or** (ii) an **`auth_fallback_*`** event **for that generation** (post–P1-B fallback-success path). **No other advance reason** is permitted — this allows **legitimate fallback-success** sessions where control notify is enabled **without** having logged **`0x05`** first.
3. **`0x4E` timing:** EGV write occurs within **~1 s** of **`did_connect`** when the session reaches control (same gate as §11 falsification).
4. **Single auth-notify enable request** per session generation (no triple **`auth_notify_enabled`** spikes from duplicate config — P0-A).
5. **Session outcome ladder** fields numerically plausible (P1-A first-stamp-only — no alternating **0** / garbage ms).

### Tier 2 — Rate outcomes (calibrated)

| Outcome | Meaning |
|---|---|
| **Full restoration** | **≥ ~10%** session success rate (order-of-magnitude **185** ledger rate **11.7%**) — suggests **both** major parity gaps (Exp 4 + Exp 1 class fixes) are addressed alongside hardening. |
| **Partial restoration** | **Non-zero** but **&lt; ~10%** — one major surviving regressor or incomplete parity; continue bisection / logs. |
| **No restoration** | **Zero** — **either** an **additional code regressor** not yet isolated, **or** an **incorrect/incomplete revert** — escalate **packet capture** **and** **git bisection** **185↔189** on `G7DirectBLEObserver.swift` (no sensor-model escape hatch). |

Evaluate Tier 2 **only after** Tier 0 (source grep / pre-ship checklist) **and** Tier 1 (24 h log hygiene) pass.

---

## 11. Falsification / next-step criteria

| Outcome | Implication | Next step |
|---|---|---|
| **Tier 0–1 pass; Tier 2 partial** (non-zero success **&lt; ~10%**) | One parity gap addressed, another still active — **or** a smaller third regressor | **Option A** isolation: ship next build with **only one** of **{Exp 4, Exp 1}** reverted; compare rates |
| **Tier 0–1 pass; Tier 2 zero** | Either an **additional regressor** not yet isolated **or** one **revert was incomplete/wrong** | Packet capture **+** **185↔189** per-commit bisection of **`G7DirectBLEObserver.swift`** |
| **Tier 1 fails** (Option C reappears, duplicate **`auth_notify_enabled`**, or **2a/2b** violated) | Implementation regression in Build **190** itself | **Revert Build 190** to **189** baseline; re-implement the failing item |
| **Tier 0–1 pass; Tier 2 fails — `0x05` still absent** after **hardening + Exp 4 + Exp 1** (and downscoped Exp 2 gen-check), **`0x4E` timely** | Passive-observer theory weakens vs **185**; failure is **code-side** — additional regressor or wrong revert | Packet capture **+** per-commit / range bisection **185↔189**; revisit §5.7 |

---

## 12. Recommended implementation order

**Option B (default):**

1. P1-A  
2. P0-E  
3. P0-A  
4. P0-B  
5. P0-C  
6. **P0-D Experiment 4** — early `registerForConnectionEvents`  
7. **P0-D Experiment 1** — `willRestoreState` connected attach  
8. P0-D Exp 2 — generation-check discoveringServices watchdog + logs  
9. P1-B  
10. P1-C, P1-D  
11. P2-A, P2-B  

**Option A:** run **steps 1–5** → **ship 190a** → **Exp 4** → **191** → **Exp 1** → **192** per §7.

**Checkpoint:** Optional hardening-only build after step 5; if `0x05` returns, **attribute to hardening** — **do not** treat as proof Exp 4/1 unnecessary without a follow-up experiment.

---

## 13. Open questions

**Closed (see §5 / §10):**

- Auth-stage **`scheduleObservingAuthStageTimeout`** — absent in 189 (**§5.2**).
- Monotonic decline **185→186→187** — partial narrative (**§5.8**).

**Still open (runtime verification — not settled by plan text alone):**

- Does **Exp 1**’s eager-attach path interact correctly with **189**’s **`discovery_skipped reason=already_discovered`** short-circuit under **P0-A** + **P0-E** (generation bump + **`observerConfigInFlight`**) — **watch logs** on device.
- Does **Exp 4**’s per-**`connect()`** **`registerForConnectionEvents`** cause unexpected **`connectionEventDidOccur`** volume or anomalies — **monitor**; narrow registration site per §7 if needed.
- Is there a **residual 187→188** delta not yet isolated that contributes to the **1.6% → 0%** step alongside **Exp 4** — **bisection** if Tier 2 stays partial after Exp 4+1+hardening.

## 14. Change log

| Version | Timestamp | Author | Changes |
|---|---|---|---|
| **2.7** | **2026-04-27 23:17 CET** | **assistant + v2.6 review** | **P0-E:** two canonical **`currentSessionGeneration`** bumps — **`didConnect`** **and** **`willRestoreState`** **connected** (before **`discoverServicesIfNeeded`** / notify work). **Tier 1:** split ordering into **2a** / **2b** (fallback-success sessions). **Exp 1:** trace **`discovery_skipped`** → **`configureObserverCharacteristics`** + **P0-A** / **P0-E** deps. **P0-A:** **`observerConfigInFlight`** + **`g7_ble_discovery_skipped_suppressed`**. **Exp 4:** idempotent **`registerForConnectionEvents`** note. **§9** logging rows; **§11** falsification rows; **§13** realistic open items; **rollback** to **189**; **§3.3** ledger vs isolation; **§3.5–3.6** H6 inline; **§8** Tier 0–1 gate for Option C-lite. |
| **2.6** | **2026-04-27 23:09 CET** | **assistant** | **Self-contained doc:** inlined full **§7** specs for **P0-A/B/C/E**, **P1-A/B/C/D**, **P2-A/B**, **P0-D Experiments 1–4** (no “see other file” stubs). Expanded **§3.2** 185 baseline; **§6** alternatives table; **§10 Tier 1** checklist + Tier 2 ordering note; **§8** packet-capture prep bullets; **§9** baseline convention; **§11/§13** wording for Tier 0–1 vs Tier 2. Version bump. |
| **2.5** | **2026-04-27 23:06 CET** | **assistant + user directives** | Full 185→189 framing, Exp 4/1, Tier 0, Option A/B, etc. |
| **2.3** | **2026-04-27 22:39 CET** | **assistant** | ChatGPT v2.1 feedback: Exp 2 gate, attribution rule, wording. |
| **2.2** | **2026-04-27 22:37 CET** | **assistant (skeptical review)** | §5.1 cancel vs attach; Exp 2 verify-first; §7 caveat. |
| **2.1** | **2026-04-27 23:45 CET** | **claude-opus-4-7** | Stage-timeout rank; NotifyOnDisconnectionKey cut; H7. |
| 2.0 | 2026-04-27 22:15 CET | claude-opus-4-7 | Major rewrite from v1.0. |
| 1.0 | 2026-04-27 19:30 CET | claude-opus-4-7 | Initial plan. |
