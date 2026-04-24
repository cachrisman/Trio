# Design: Watch — Dexcom G7 direct BLE eavesdrop (foreground)

**Version:** v1.25  
**Status:** Accepted (observer-mode baseline; **Phase E** pre-connect instrumentation **implemented** in `Trio`, hardware validation open)  
**Created:** 2026-04-11 22:45 CET  
**Last updated:** 2026-04-19 00:05 CEST  

**Implementation plan:** [watch-direct-ble-cgm-02-implementation-plan.md](watch-direct-ble-cgm-02-implementation-plan.md)  
**Instrumentation report:** [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)  
**Code:** Swift sources live in the sibling **`Trio`** worktree — traceability is **this initiative folder** + **`Trio`**; optional transient `git diff` scratch docs under repo `docs/code-review/` are **not** linked here.

---

## Positioning (explicit)

This initiative adds an **optional, foreground-only** path on **watchOS** to **observe** Dexcom **G7** Bluetooth Low Energy traffic and derive **glucose readings** for **complication updates**, without implementing a full Dexcom pairing/auth protocol as the primary data path.

- **Not medical advice:** CGM data are observational telemetry for UI; Trio remains a diabetes management tool with existing safety posture.
- **Not a replacement** for HealthKit, Nightscout sync, or phone-mediated CGM pipelines unless product explicitly promotes it later.
- **Official Dexcom G7 app is the BLE session owner:** The authenticated Dexcom app owns the runtime session; Trio watch attaches as an **observer / eavesdrop client** to that session.
- **Direct BLE watch mode is observer-only:** There is no separate "active pairing" direct-BLE watch mode under discussion here; the direct watch BLE path itself is the observer path.
- **Phone relay remains a separate watch path:** Trio may still continue to support a **phone-relay / WatchConnectivity** watch path, but that path is distinct from direct BLE and is not the mode specified in this design.
- **Eavesdrop / passive stance:** The design intentionally does **not** complete J-PAKE, app-key auth, or otherwise impersonate an authenticated Dexcom client; it **listens** for owner-driven auth traffic, enables passive observation once `authenticated == true`, keeps `bonded` as an observed/debug bit, and reserves an explicit `0x4E` write for fallback only if passive observation fails to produce glucose traffic in time.

---

## Problem

- **Latency / gaps:** When the watch complication depends on **HealthKit** or **transferred** snapshots, users can see **stale** readings relative to the live G7 radio session driven by the Dexcom app or receiver.
- **Opportunity:** If the G7 is advertising and the watch extension is **foreground-active**, CoreBluetooth may allow **direct observation** of the G7 service, enabling **faster** `TrioComplicationDataStore` updates **without** changing iOS phone behavior.

---

## Context / current state

- **Watch state hub:** `Trio Watch App Extension/WatchState.swift` orchestrates foreground vs background, HealthKit, WatchConnectivity, and complication persistence via **`TrioComplicationDataStore`** (`Trio Watch Shared/`).
- **Existing pattern:** Other paths call `TrioComplicationDataStore.shared.save(..., minInterval: 5)` to coalesce reload churn.
- **Observability:** `WatchLogger` provides structured, grep-friendly logs for Better Stack / operational review (`docs/process/betterstack-guide.md`).

---

## Constraints / requirements

### Product / behavior

1. **UI-gated start, OS-gated end:** Begin / recover the direct BLE pipeline when the app UI is **active** (`ScenePhase.active` → **`applyForegroundActiveEntry`**). **Do not** call **`g7DirectBLEManager.stop()`** on **`.inactive`** or **`.background`** — **`WKExtendedRuntimeSession`** + CoreBluetooth continue receiving CGM updates until **watchOS** ends the extended session (**`extendedRuntimeSessionWillExpire`** / invalidation) or **`teardownSession`** handles errors / disconnect / rescan. **`stop()`** remains an **explicit** API for future product off-switches or tests, not scene-phase wiring.
2. **Observer-only auth path:** Do not implement J-PAKE completion, app-key ownership, or auth-init ownership on the watch observer path; **observe** auth traffic and proceed along the passive sequence validated by Trio phone-side `G7SensorKit` and DiaBLE passive mode (`auth notify` → `0x03` / `0x05` observed → `control notify` → passive `0x4E` receipt when available). In observer mode the watch must **not** send `0x01 0x00` auth-init, and any explicit `0x4E` must remain a fallback rather than the default path.
3. **Phone-provided active sensor identity is required:** The watch direct BLE observer path must only attempt to attach to the same active G7 sensor identity the phone reports over **WatchConnectivity**. Do **not** connect to arbitrary Dexcom advertisements when that identity is absent or does not match.
4. **Complication handoff:** Successful parses feed **`TrioComplicationSnapshot`** with **`readingDate`** consistent with the derived G7 timing model.
5. **Coalescing:** Use existing store APIs with **`minInterval`** consistent with other watch glucose paths (default: **5** seconds) unless a measured reason dictates otherwise.

### Engineering / repo process (non-negotiable)

Per **`AGENTS.md`** and **`docs/process/feature-branch-workflow-optimization.md`**:

- **Do not** hand-edit `Trio.xcodeproj/project.pbxproj` or run `scripts/sync_project_files.rb` from an agent session. New Swift files are added under the correct directory; **target membership** is resolved via the **canonical** human/build workflow (`ci/local-build.sh` / Xcode).
- **Do not** use Xcode CLI builds (`xcodebuild`) or ad-hoc `ci/local-build.sh` as routine agent verification; static review + targeted tests (where feasible) suffice unless the user requests a build.
- **Feature delivery model:** Implementation typically lives on a **`feature/<name>`** branch in the **`Trio`** worktree; publication into the fork’s **`./patches/`** stack follows **`generate-patch.sh`** when the feature is ready — see process doc.

### Source / flags

- **No compile-time feature flag** in source for this path (no `#if ENABLE_G7_DIRECT_BLE` in implementation files; no active `ENABLE_G7_DIRECT_BLE` wiring in sync config) — the feature is **unconditional** at the source level; operational kill-switch (if ever needed) is a **product** decision outside this v1.0 design unless revisited.

## DiaBLE Observer Reference (Normative)

The working **DiaBLE** watch / phone implementation and the runtime evidence in
`watch-direct-ble-cgm-04-diaBLE-logs.md` are now the primary behavioral
reference for this Trio watch path.

The proven observer / eavesdrop sequence is:

1. Scan / find `DXCMKo` via `FEBC`
2. Connect
3. Discover services / characteristics
4. Enable **authentication** notifications
5. Explicitly **skip J-PAKE notifications while eavesdropping**
6. Receive auth challenge traffic (`0x03`)
7. Receive status reply (`0x05`) and confirm `authenticated: true` while recording the bonded bit for diagnostics
8. Enable **control** notifications and passively observe glucose/control traffic
9. Touch **communication** when authenticated if available (`notify`) as an optional passive side channel; do not rely on an immediate active read in the watch observer path
10. Receive / parse / store the EGV (`0x4E`), using an explicit `0x4E` only as a fallback if passive observation stalls
11. Disconnect / reconnect as needed

The operational interpretation is explicit:

- The **official Dexcom G7 app** remains the authenticated session owner.
- Trio watch direct BLE is an **observer / eavesdrop client**, not a pairing / J-PAKE owner.
- The separate **phone-relay / WatchConnectivity** watch path, if used, is outside this direct-BLE mode and is not changed by this observer design.
- **J-PAKE is not the default observer path**.
- The DiaBLE logs doc is a **key implementation reference**, not just supplemental background.

## Current Trio Watch Divergence (2026-04-13 Review)

Current `Trio Watch App Extension/G7DirectBLEManager.swift` diverges from that
proven DiaBLE observer sequence at four concrete points:

1. After auth notifications turn on, Trio still calls `sendAuthRequest()` and writes `0x01 0x00`, which makes the watch initiate auth traffic instead of passively waiting for the owner session.
2. Trio does not currently discover or track the `J-PAKE` characteristic, so it cannot explicitly log the observer skip or guarantee that the watch path remains out of the J-PAKE flow.
3. Trio advances on `0x05` when `authenticated == true` only; it ignores the bonded byte and therefore does not enforce the `authenticated: true, bonded: true` gate proven in the DiaBLE logs.
4. Trio treats `backfill` as part of the required startup / timeout readiness path (`characteristics_incomplete`, `awaiting_gatt_setup` cancel), even though the minimal working observer sequence only requires auth notify, `0x05`, control notify, and `0x4E`.

---

## Decision

### Recommended approach

Introduce a dedicated **`G7DirectBLEManager`** (CoreBluetooth central + peripheral delegate) that:

1. **Scans** for G7 advertisement service **`FEBC`**.
2. **Connects** and discovers the Dexcom **data service** and the **authentication**, **control**, **backfill**, and **J-PAKE** characteristics (UUIDs as verified against DiaBLE / reverse-engineering references — document in code comments, not duplicated here as normative spec). The watch discovers **J-PAKE** only so it can explicitly log the observer skip; it does **not** subscribe to or enable that characteristic in observer mode.
3. **Observer auth path:** Enable **authentication** notifications, explicitly **skip J-PAKE notifications**, and **do not** send `0x01 0x00`, `0x02`, `0x04`, or J-PAKE ownership packets from the watch observer path. Wait passively for owner-driven auth traffic.
4. **Status gate:** On `0x03`, log the challenge traffic. On `0x05`, parse both auth status bytes, proceed when **`authenticated == true`**, and keep the bonded bit as a logged/debug signal rather than a hard passive gate.
5. **EGV:** After the authenticated passive gate, enable **control** notifications and arm passive observation first. If the passive path does not produce expected glucose traffic within a bounded timeout, allow a **fallback** `0x4E` write on **control**. **Backfill is optional** for this observer path and does not gate control readiness. Parse **EGV** payloads (`0x4E`), compute **reading time** from **activation wall clock** + (**txTime** − **egvAge**), map **trend** to Nightscout-style arrow strings consistent with existing watch usage.
6. **Persist:** `TrioComplicationDataStore.shared.save(snapshot, triggerReload: true, minInterval: 5)` on valid glucose.
7. **Lifecycle:** **`WatchState`** holds a single **`G7DirectBLEManager`** instance (**`@ObservationIgnored private let`** — **`lazy`** is incompatible with **`@Observable`** macro expansion in this configuration; **`CBCentralManager`** is still created only inside **`startScanning()`**). **`handleForegroundActiveEntry()`** calls **`applyForegroundActiveEntry(activePeripheralName:)`** (applies the phone filter and calls **`startScanning()`** only when no live **`.scanning`…`.connected`** session needs preserving). **`handleForegroundInactiveOrBackground`** does **not** stop BLE — it only correlates **`g7_ble_lifecycle`** + existing startup bookkeeping.

### Why this tradeoff

- **Deferred `CBCentralManager` creation** avoids launch-time BLE cost; **UI-gated (re)start** via **`applyForegroundActiveEntry`** avoids nuking a live session when the user pops back into the app while **`WKExtendedRuntimeSession`** is still streaming off-watch-face.
- **Eavesdrop** reduces protocol surface and legal/ToS exposure versus cloning Dexcom’s full pairing.
- **Observer-only auth** keeps the watch aligned with the now-proven DiaBLE runtime: the Dexcom app owns session authentication and Trio consumes the resulting authenticated window.
- **Store + logger** reuse preserves one complication pipeline and one observability style.

---

## Functional behavior

### User flows / triggers

- User brings Trio watch app UI **active** (`ScenePhase.active`) → **`applyForegroundActiveEntry`** may **`startScanning()`** (or **skip** a full restart if a **`.scanning`…`.connected`** session is already in progress after a watch-face detour).
- **Leaving the app UI (inactive / background):** **`TrioWatchApp`** forwards **`ScenePhase`** to **`WatchState.handleForegroundInactiveOrBackground`**. **`.inactive`** and **`.background`** emit **`g7_ble_lifecycle`** correlation lines with **`ble_continues=true`** — they **do not** call **`g7DirectBLEManager.stop()`**. Direct BLE + **`WKExtendedRuntimeSession`** keep running so CGM samples can still update **`TrioComplicationDataStore`** until the **OS** ends the extended runtime budget (**`extendedRuntimeSessionWillExpire`**) or **`teardownSession`** runs on errors / disconnect / rescan / invalidation without a prior graceful teardown.
- **Graceful end when the OS ends extended runtime:** **`G7DirectBLEManager`** implements **`WKExtendedRuntimeSessionDelegate`**. **`extendedRuntimeSessionWillExpire`** runs only when the callback’s session matches the **current** **`extendedSession`** handle and is treated as an **advance warning only**: it logs **`g7_ble_ext_session_expiring action=await_invalidation`** and does **not** tear BLE down early. **`extendedRuntimeSession(_:didInvalidateWith:)`** runs on **`MainActor`**: it records whether the callback’s session is the **current** handle **before** clearing **`extendedSession`** (so **stale** invalidations after **renewal** cannot clear the replacement pointer, and **error** invalidations of the **current** session still reach **`teardownSession`** — clearing first would make the teardown guard always fail). **`teardownSession(reason: ext_session_invalidated, …)`** only when **`error != nil`** **and** that **pre-capture** identity matched — intentional **`invalidate()`** for renewal uses **`error == nil`** and must **not** disconnect BLE.
- **`stop()`** is **not** obsolete: it is the **explicit** “hard off” API (future settings, debugging). **Scene phase never calls it** in the current wiring.

### Data model (conceptual)

- **Inputs:** Raw BLE `Data` on authentication + control characteristics.
- **Outputs:** `TrioComplicationSnapshot` fields: glucose string, trend string, `readingDate`, `date` (ingest time), optional color nil.

### Edge cases

- Bluetooth **off** / **unauthorized** → structured error log; no crash.
- **Multiple** peripherals / RSSI — the watch must **not** connect to a random Dexcom advertisement. **`G7DirectBLEManager.activePeripheralName`** is populated from the phone’s currently active sensor identity and used as a required exact-match filter on watch. Peripherals that do not match are **skipped** (logged: `g7_ble_peripheral_skipped`). If the phone has not yet supplied the active sensor identity, the watch direct BLE observer path should remain non-connected / filter-waiting rather than attach to an arbitrary `DXCM*` device. **iPhone → watch bridge (WatchConnectivity):** the iOS app sends **`WatchMessageKeys.activeG7PeripheralName`** inside the nested **`watchState`** dictionary (same payload as other watch UI fields; included in the complication **`userInfo`** / **`applicationContext`** allowlist so it survives budgeted paths). The value is **`G7CGMManager.sensorName`** (G7SensorKit — the active sensor identity currently used for matching and the same string CoreBluetooth uses for the paired sensor). The watch caches it from incoming messages / `userInfo` / `applicationContext` and passes it into **`applyForegroundActiveEntry`** from **`handleForegroundActiveEntry()`**. An **empty** string clears the filter; **omitting** the key leaves the prior cache unchanged (older iPhone builds). **App Group `UserDefaults` does not sync** phone ↔ watch — this path is **WC only**.
- **Coexistence** with Dexcom mobile app on the same phone/watch — **operational** risk; may affect connect reliability (device validation).

### Extended runtime (`WKExtendedRuntimeSession`)

- **Intent (continuous listening):** After **`central.connect(...)`** (post peripheral-name filter), keep the watch process eligible for **ongoing** BLE work and notifications so **each new** CGM sample can update **`TrioComplicationDataStore`** / complication state — not only the **first** EGV in a session. The extended session **stays active** while **`ScenePhase`** is **inactive/background**; it ends when **watchOS** expires or invalidates the **`WKExtendedRuntimeSession`**, or when **`teardownSession`** runs for protocol/BLE reasons (errors, disconnect, rescan). **Scene phase does not call `stop()`.** **Do not** invalidate the extended session merely because one reading was persisted.
- **Foreground re-entry renewal (≤1h away):** **`WatchState`** records **`noteSceneLeftActiveUi(at:)`** when the UI leaves **`.active`** (and on **`.background`** if the app never went through **`.inactive`** first). On the next **`applyForegroundActiveEntry`**, if the user was away **&gt; 0s** and **&lt; 3600s**, the manager **`invalidate()`s** the current **`WKExtendedRuntimeSession`** and starts a **new** one when **`peripheral != nil`** and **`G7BLEConnectionState`** is **`.connecting`**, **`.authenticating`**, or **`.connected`** — so the ~**1h** extended-runtime budget can **re-anchor** from **last time the UI was active**, not only from the original **`didDiscover`** time. If away ≥ 3600s, renewal is skipped (logged). See **[Connection state model (cross-reference)](#connection-state-model-cross-reference)** for why steady-state streaming remains **`.connected`** between 5‑minute EGVs.
- **Historical note:** Earlier experiments tied **`stop()`** to **`ScenePhase.inactive`**, which ended direct BLE when returning to the watch face. That **conflicts** with continuous reception off-screen and is **removed** — **`willExpire`** is now warning-only, while **invalidation** + **`teardownSession`** are the normal graceful exits for the extended-runtime window.
- **Mechanism:** Start **`WKExtendedRuntimeSession`** when committing to **`central.connect(...)`** (after peripheral name filter). **`teardownSession`** and explicit **`stop()`** invalidate the extended session. **`stop()`** is reserved for non–scene-phase teardown. **On-device validation** remains required (TODO at call site in code).

### Connection state model (cross-reference)

**Trio (`G7DirectBLEManager.G7BLEConnectionState`):** The app-level enum tracks **setup vs live** — **`.scanning`**, **`.connecting`**, **`.authenticating`**, **`.connected`**, then **`.disconnected` / `.error`**. Assignments are **sparse**: after successful auth (**`0x05`**), **`connectionState`** is set to **`.connected`** and is **not** cleared between 5‑minute EGV packets; “quiet” time between glucose notifications is still **`.connected`**. Instrumentation **`emitStageIfChanged("awaiting_egv")`** reflects **protocol stage** (`lastInstrumentationStage`), not a separate connection-state value.

**LoopKit `G7SensorKit` (local sibling repo `G7SensorKit/`):** **`G7CGMManagerState`** is **persisted CGM metadata** (sensor id, latest reading, etc.) — **not** a BLE link-state machine. Link liveness uses **Core Bluetooth** **`CBPeripheralState`** (e.g. **`runCommand`** requires **`peripheral.state == .connected`**). **`G7SensorLifecycleState`** (**searching / warmup / ok / …**) is **sensor product life**, not per-packet BLE. Authentication during setup uses a **`pendingAuth`** flag and auth notifications; there is **no** oscillating “authenticating” state on every reading.

**DiaBLE (`DexcomG7.swift`):** Commented protocol sequence shows **one connection** with periodic control/auth traffic — consistent with **staying CB-connected** between EGVs rather than reconnecting every 5 minutes.

**Renewal guard:** Foreground re-entry extended-runtime renewal requires **`.connecting` / `.authenticating` / `.connected`** **and** **`peripheral != nil`**. That is **not** “only while a reading is actively transmitting”; it matches **steady streaming** after auth. **`.scanning`** without a peripheral does not start **`WKExtendedRuntimeSession`** in this design (session starts at **`didDiscover`**), so renewal correctly no-ops until a peripheral exists.

### Non-functional

- **Main thread:** Central manager on **main** queue to align with `WatchState` thread assertions.
- **Battery / policy:** No unconstrained 24/7 background scan; work is still bounded by **watchOS** extended-runtime rules and user visibility expectations — device soak validates practical battery impact while the UI is not foreground.

### Observability expectations

- Structured logs with prefix **`event=g7_ble_*`** and **`key=value`**-friendly fields where possible.
- **Connect failure taxonomy:** **`didFailToConnect`** uses **`event=g7_ble_connect_failed`** with **`error_domain=`** / **`error_code=`** / **`error_desc=`** (NSError) — not generic **`g7_ble_error`** — so Better Stack can distinguish OS-level failure modes.
- **Discovery:** **`g7_ble_peripheral_discovered`** includes **`rssi=`** (radio context).
- **Observer proof points:** The watch must emit explicit observer-phase lines for **`auth notify enabled`**, **`J-PAKE skipped`**, **`0x03 received`**, **`0x05 authenticated/bonded`**, **`control notify enabled`**, **`passive observation armed`**, optional **fallback `0x4E` sent**, **`0x4E received`**, and **snapshot saved**.
- **Negative proof:** In observer mode the watch must **not** emit an auth-init write line (`g7_ble_auth_request_sent`) or any J-PAKE ownership write.
- **Active-name filter:** When **`applyForegroundActiveEntry`** applies a non-nil phone-supplied name, **`event=g7_ble_active_name_applied filtered=true`** (watch — does not log the raw peripheral name). **`g7_ble_foreground_reentry_skipped`** when a full **`startScanning()`** restart was skipped because a session was already in progress.
- **Explicit blocked-state logging:** Emit compact observer-stall lines when attach is intentionally withheld because the phone-provided active sensor filter is missing, when a `0x05` reply does not satisfy the passive authenticated gate, and when passive observation is intentionally withheld because control / auth prerequisites are not ready. Exact event names and bounded-emission rules live in report **03**.
- **Session summary:** **`event=g7_ble_session_outcome`** at teardown with **`outcome=`** (e.g. cancelled / timeout / success / failure / incomplete), **`final_stage=`**, **`duration_ms=`**, **`g7_session=`** — **`success`** only when an EGV was received and persisted in that session (implementation-defined mapping).
- **Extended session:** **`g7_ble_ext_session_started`**, **`g7_ble_ext_session_expiring`**, **`g7_ble_ext_session_ended`**, **`g7_ble_ext_session_invalidated`**, **`g7_ble_ext_session_renewal`** (foreground re-entry within 1h), **`g7_ble_ext_session_renewal_skipped`** (away ≥ 3600s) as applicable (historical **`g7_ble_stop_deferred`** may appear in older builds — **not** part of the current **`stop()`** design).
- **`WatchLogger` call-site metadata:** The BLE manager’s private **`logG7Ble`** helper forwards **`#fileID`**, **`#line`**, and **`#function`** into **`WatchLogger.shared.log`** so downstream parsing (e.g. Better Stack **`file` / `lineNumber` / `method`**) reflects the **syntactic caller** of **`logG7Ble`** (often a line inside a **`Task { }`** for CoreBluetooth callbacks), not the helper’s own definition. This preserves grep-friendly **`event=`** strings while improving operational attribution.
- Critical transitions: scan start, discovered, connected, auth phases, EGV received, snapshot saved, disconnect/errors.
- **Normative instrumentation details** (session id, stage transition rules, timeouts, lifecycle correlation, bounded protocol logging): **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** — implement Tier 1–3 there when extending observability beyond the baseline spike logs.
- **Lifecycle correlation** (`g7_ble_lifecycle`, session coupling, timing — report **03** Tier 1) is **normative** for the full instrumentation track, **not** optional “extra” logging layered on top of baseline **`g7_ble_*`** events.
- **Exact event strings:** The canonical `event=g7_ble_*` names and ordered proof set live in report **03** and should be treated as authoritative over this design doc’s prose labels.

### Watch debug view

Add a lightweight section to the **existing watch debug view** for the **Direct BLE / G7 observer** path so operators can answer, from the watch alone, whether the session is on the expected observer track or stalled before `0x4E`.

The debug section should show compact status fields only:

- **Feature / path state:** mode (`Direct BLE Observer`), expected session owner (`Dexcom G7 app`), and whether the watch is currently using **phone relay** instead of direct BLE.
- **Connection state:** one compact stage value such as `Idle`, `Scanning`, `Connecting`, `Awaiting auth`, `Awaiting control`, `Awaiting EGV`, `Connected`, or `Error`.
- **Peripheral state:** last peripheral name, RSSI, last discover time, and whether the phone-provided active sensor identity filter is armed / applied.
- **Observer / auth state:** auth notify enabled, J-PAKE skipped, last auth opcode seen, authenticated, bonded, and control notify enabled.
- **Data state:** last EGV received time, last glucose value, last reading age, last sequence number, and last snapshot save result / time.
- **Session diagnostics:** current `g7_session`, last disconnect reason, reconnect scheduled, timeout stage if any, and whether the extended runtime session is active.

The watch debug view is intentionally operational, not a packet inspector:

- It should mirror the same observer milestones used in logging.
- It should not display raw packet hex dumps or giant scrolling logs on-screen.

### Rollout / backward compatibility

- Additive feature; **no** migration of persisted schema required for v1.0.

---

## Alternatives considered (and why rejected)

| Alternative | Why rejected for v1.0 |
|-------------|------------------------|
| Full Dexcom client (J-PAKE complete) | Large scope, maintenance + policy risk; not required for eavesdrop spike |
| Background BLE | Higher App Review / OS policy risk; unnecessary for first ship |
| Feature flag in source | Explicitly out of scope for this v1.0 design |

---

## Risks / open questions

1. **Protocol drift:** Firmware may change characteristic behavior or EGV layout — mitigated by logs + device soak.
2. **Write-with-response vs without-response** on control/auth — **must** be validated on hardware.
3. **Activation time inference** from first EGV may drift vs true sensor activation — acceptable for complication freshness; not for clinical timing claims.
4. **Target membership** for new Swift files must be correct in Xcode — not verifiable from `Trio-dev` docs alone.
5. **Pre-connect parity gap (Phase E / build 162 — code in `Trio`, hardware TBD):** Trio watch still stalls before `didConnect` after `central.connect(...)` — the observer-mode auth/GATT/EGV path has never been exercised on hardware because the connection itself never completes. A focused comparison against DiaBLE's working watch path ([watch-direct-ble-cgm-05-diable-comparison.md](watch-direct-ble-cgm-05-diable-comparison.md)) identified the root question as **what runtime context Trio is in when it calls `connect()`** and how that differs from DiaBLE. Phase E adds pre-connect state instrumentation, fixes `retrieveConnectedPeripherals` timing, and experiments with `CBCentralManagerOptionRestoreIdentifierKey` — **implemented** in **`Trio`** `G7DirectBLEManager.swift`; see [implementation plan](watch-direct-ble-cgm-02-implementation-plan.md) **Implementation log (execution)**. **Open:** whether build 162 resolves `didConnect` on device.

---

## Success criteria (verifiable)

1. **Lifecycle:** Direct BLE starts from the **`ScenePhase.active`** entry path (**`applyForegroundActiveEntry`**); **`.inactive` / `.background`** do **not** end BLE. Session ends on OS extended-runtime expiry / **`teardownSession`** / explicit **`stop()`** (code review / logs).
2. **Observer proof:** Watch logs show the passive sequence: **`auth notify enabled`** → **`J-PAKE skipped`** → **`0x03`** → **`0x05 authenticated=<bool> bonded=<bool>`** → **`control notify enabled`** → **`passive observation armed`** → optional **fallback `0x4E`** → **`0x4E received`** → **snapshot saved**. Exact proof names and ordering follow report **03**.
3. **Sensor identity gate:** Watch direct BLE only attempts attach when the phone-provided active sensor identity / name filter is present and matches the discovered peripheral; it does not attach to arbitrary Dexcom advertisements.
4. **Negative proof:** The observer watch path does **not** send auth-init or J-PAKE ownership writes.
5. **Complication:** After a valid EGV, complication snapshot updates via `TrioComplicationDataStore` with **`minInterval: 5`** (device / widget reload observation).
6. **Safety:** No `precondition` crash on malformed packets in production paths — **stretch** hardening if initial spike uses strict helpers (see implementation plan).

---

## Changelog

### v1.25 (2026-04-19 00:05 CEST)
- **Passive follow-up tightened:** The watch observer path now treats `communication` as notify-only on the passive path instead of issuing an immediate read, keeping the watch side less active while preserving optional diagnostics.
- **Fallback stays rescue-only:** The documented fallback `0x4E` path is now treated as a later rescue step, not an eager near-default follow-up to passive observation.

### v1.24 (2026-04-18 23:40 CEST)
- **Passive observer model updated:** The design now treats the watch path as passive-first after auth, with `authenticated == true` as the passive gate, `bonded` retained for diagnostics, and explicit `0x4E` moved to fallback-only behavior.
- **DiaBLE passive communication note added:** The normative sequence now documents optional `communication` notify/read handling when authenticated so the watch design matches the known passive DiaBLE behavior more closely.

### v1.23 (2026-04-18 22:35 CEST)
- **Extended runtime expiry semantics corrected:** `extendedRuntimeSessionWillExpire` is now documented as a warning-only callback that logs and waits for actual invalidation rather than tearing BLE down immediately.
- **Reconnect intent clarified:** The design now matches the current watch implementation more closely: retries continue after disconnects and failed connects unless teardown was an explicit stop, rather than suppressing failure-class reconnects by default.

### v1.22 (2026-04-14 16:09 CEST)
- **Phase E code landed:** Risk/open-question #5 updated — Phase E pre-connect work is **implemented** in **`Trio`** `G7DirectBLEManager.swift`; **open** remains on-device **`didConnect`** outcome (build 162). Pointer to **implementation plan** **Implementation log (execution)**.

### v1.21 (2026-04-14 16:00 CEST)
- **Pre-connect parity gap documented:** Added risk/open-question #5 — Trio still stalls before `didConnect`; the active investigation is Phase E (build 162), focused on connect-context parity vs DiaBLE. Cross-links to comparison doc and implementation plan Phase E.

### v1.20 (2026-04-13 23:05 CEST)
- **Blocked-state observability tightened:** Added a design-level requirement for explicit observer-stall logging when attach is blocked by a missing phone filter, when `0x05` fails the `authenticated && bonded` gate, and when `0x4E` is intentionally held back pending prerequisites.
- **Instrumentation authority reaffirmed:** Clarified that the exact event names and bounded blocked-state logging rules remain normative in report **03** rather than being duplicated here.

### v1.19 (2026-04-13 22:21 CEST)
- **Phone-provided sensor identity made mandatory:** Clarified that the watch direct BLE observer path must only attempt attach when the phone has supplied the currently active sensor identity over WatchConnectivity; connecting to arbitrary Dexcom advertisements is now explicitly out of spec.
- **`0x4E` cadence clarified:** Documented the minimum behavior as one `0x4E` request after each successful connect / auth / control-ready cycle, repeated on reconnect, while explicitly rejecting a speculative repeating watch-side polling loop in this delta.
- **Debug view placement and proof linkage tightened:** The new status fields now live in the **existing** watch debug view, show whether the phone-provided filter is armed, and the design success criteria now point to report **03** for exact proof-set event names.

### v1.18 (2026-04-13 22:10 CEST)
- **Watch debug-view requirement added:** Added a small **Watch debug view** requirement that defines a compact on-watch **Direct BLE / G7 observer** status section covering path mode, connection stage, peripheral state, observer/auth state, data state, and session diagnostics.
- **Operational scope clarified:** The debug UI is explicitly for answering where the observer flow stalled, not for raw packet inspection; it must mirror the same milestones used in logging and avoid packet hex dumps / giant logs.

### v1.17 (2026-04-13 22:04 CEST)
- **Mode boundary clarified:** Added explicit wording that **watch direct BLE is observer-only**, while any **phone-relay / WatchConnectivity** watch path remains a separate mode and is not the direct-BLE behavior under discussion.
- **Observer path tightened:** Named **`0x01 0x00` auth-init** explicitly as forbidden in observer mode and clarified that **J-PAKE is discovered only for skip/logging**, not subscribed/enabled.
- **Approval state recorded:** Header status now reflects that the design is ready for review but **code changes remain pending approval**.

### v1.16 (2026-04-13 21:46 CEST)
- **DiaBLE observer sequence made normative:** Added **DiaBLE Observer Reference** and promoted `watch-direct-ble-cgm-04-diaBLE-logs.md` to a primary implementation reference. The design now explicitly states that the **official Dexcom G7 app is the runtime session owner**, Trio watch is an **observer / eavesdrop client**, and **J-PAKE is not the default observer path**.
- **Current Trio divergence documented:** Added a concrete divergence list against the proven DiaBLE pattern: Trio still sends auth-init, does not explicitly discover / skip J-PAKE, ignores the bonded bit on `0x05`, and over-couples startup readiness to backfill.
- **Decision / observability / success criteria updated:** The watch design now requires **auth notify only**, passive `0x03` / `0x05 authenticated+bonded`, **control notify then `0x4E`**, observer-proof logging, and absence of auth-init / J-PAKE ownership writes in observer mode.

### v1.15 (2026-04-13 00:03 CET)
- **`didInvalidateWith` error teardown:** Documented **MainActor** handler that captures **current-session identity before** nil-ing **`extendedSession`**, so **OS error** invalidation still triggers **`teardownSession`**; stale callbacks after **renewal** remain safe. **`WatchState`** — comment on **`.background`** **`noteSceneLeftActiveUi`** (normal **`.inactive`** path already set timestamp; background branch is rare ordering only).
- **Reason:** External review (ChatGPT / Claude) — prior clear-then-guard ordering blocked **`ext_session_invalidated`** teardown.

### v1.14 (2026-04-12 23:55 CET)
- **Foreground re-entry extended-runtime renewal:** Documented **`noteSceneLeftActiveUi`**, ≤1h re-anchor of **`WKExtendedRuntimeSession`**, and delegate identity rules (**`willExpire`** / **`didInvalidateWith`** only for the **matching** session; **`nil`** error on intentional **`invalidate()`** does not tear down BLE). **Extended runtime** + **Observability** bullets updated.
- **Connection state model (cross-reference):** New section — Trio **`G7BLEConnectionState`** vs **`G7SensorKit`** (**`G7CGMManagerState`**, **`CBPeripheralState`**, **`G7SensorLifecycleState`**) vs DiaBLE protocol notes; explains why renewal’s **`.connecting`…`.connected`** guard is appropriate for steady-state streaming between 5‑minute EGVs.
- **Reason:** Align design with shipped **`Trio`** behavior and record cross-repo validation for **connection-state** semantics.

### v1.13 (2026-04-12 23:40 CET)
- **Scene phase vs BLE:** **Constraints**, **Decision §6**, **User flows**, **Extended runtime**, **Non-functional battery**, and **Observability** — **`.inactive` / `.background`** no longer imply **`stop()`**; **`applyForegroundActiveEntry`**, OS **`willExpire` / invalidation** graceful teardown, explicit **`stop()`** role, **`g7_ble_foreground_reentry_skipped`**. **Implementation plan** **v1.23**; **instrumentation report 03** **v1.15** (lifecycle rows).
- **Reason:** Product decision — continuous CGM reception until extended runtime ends, not when the user leaves the app UI.

### v1.12 (2026-04-12 23:35 CET)
- **User flows / lifecycle accuracy:** Replaced misleading “user backgrounds the app → **`stop()`**” line with **watchOS `ScenePhase` behavior** — **`inactive`** drives **`g7DirectBLEManager.stop()`** (e.g. Digital Crown to watch face); **`.background`** does not call **`stop()`** again (correlation log only). Added **product tension** paragraph: **`.inactive` → `stop()`** ends direct BLE when leaving the app UI; that is **not** the same as “only stop when the OS kills extended runtime,” unless lifecycle policy changes later.

### v1.11 (2026-04-12 23:21 CET)
- **Extended runtime — product intent:** Documented **continuous listening**: **`WKExtendedRuntimeSession`** stays active for **subsequent** CGM samples / complication updates until **`stop()`** / teardown / OS expiry — **not** ended after the first persisted EGV. Aligned **User flows**, **Mechanism** (invalidate at **`stop()`** / **`teardownSession`**, no defer gate), and observability note on **`g7_ble_stop_deferred`**. **Implementation plan** **v1.22** records the code/doc correction.
- **Reason:** Prior red-team follow-up treated “success-path termination” as “end session after first reading”; that conflicts with the intended **stream** behavior.

### v1.10 (2026-04-12 22:58 CET)
- **Initiative / code-review decoupling:** Removed header link to transient **`docs/code-review/`** diff artifacts; replaced with a short **Code** line (**`Trio`** worktree + explicit non-link to scratch diffs). **Implementation plan** **v1.20**.

### v1.9 (2026-04-12 22:57 CET)
- **Active G7 name bridge:** Documented **WatchConnectivity**–mediated population of **`G7DirectBLEManager.activePeripheralName`** from iPhone **`G7CGMManager.sensorName`** (**`WatchMessageKeys.activeG7PeripheralName`**), empty-string clear semantics, legacy “key omitted” behavior, and explicit note that **App Group stores are per-device** (not a cross-device sync channel). Replaces the prior **TODO** / “shared state” placeholder.
- **Reason:** Implementation landed in **`Trio`** (`AppleWatchManager`, `WatchMessageKeys`, `WatchState`); keep design authoritative for operators and future patches.

### v1.8 (2026-04-12 21:53 CET)
- **Operational observability + extended runtime:** Documented **`activePeripheralName`** exact-match filter (stale `DXCM**` neighbors), **`g7_ble_connect_failed`** / RSSI / **`g7_ble_session_outcome`**, and **`WKExtendedRuntimeSession`** + **`stop()`** deferral pattern. Cross-links unchanged — **implementation plan** records execution (**v1.18**).

### v1.7 (2026-04-12 14:00 CET)
- **Lifecycle driver:** Implementation aligns with instrumentation report **03** **v1.11** — **`g7_ble_lifecycle`** leave-active is driven only by **`TrioWatchApp`** **`ScenePhase`** (not **`ExtensionDelegate`**). **Plan** **v1.16**.

### v1.6 (2026-04-12 13:56 CET)
- **Observability (instrumentation feedback):** Normative lifecycle / GATT-timeout semantics are in **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** **v1.10** — e.g. **`phase=background`** only when the scene is **`.background`**; **`active_window_ms`** naming; **`awaiting_gatt_setup`** cancel rule. **Implementation plan** **v1.15** records code changes.

### v1.5 (2026-04-12 13:36 CET)
- **Observability:** Documented **`logG7Ble` → `WatchLogger`** forwarding of **`#fileID` / `#line` / `#function`** for Better Stack–friendly **call-site** metadata (vs attributing the private helper). Reason: encode the implementation decision and set expectations that **`Task`**-wrapped logs attribute the **await** line inside the task body.

### v1.4 (2026-04-12 13:31 CET)
- **Code review doc (historical):** Recorded a canonical diff path under **`Trio-dev`** `docs/code-review/` (aligned with implementation plan **v1.13**). **Superseded by v1.10** — initiative docs no longer link transient diff artifacts; header line updated; removed incorrect “sibling **`Trio`** only” note.

### v1.3 (2026-04-12 13:06 CET)
- **Cross-links:** Removed sibling **version numbers** from **Implementation plan** / **Instrumentation report** lines in the header — each linked file’s own **Version** field is authoritative (avoids cascading edits when a sibling doc bumps).

### v1.2 (2026-04-12 13:02 CET)
- **Observability:** Clarified that **lifecycle correlation** in **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** (Tier 1) is **normative** for the instrumentation spec, not optional add-on logging.

### v1.1 (2026-04-12 12:52 CET)
- **Lifecycle / `WatchState`:** Replaced “lazy manager” wording with shipped pattern — **`@ObservationIgnored private let`** (see implementation plan **v1.6**); deferred **`CBCentralManager`** creation unchanged (**`startScanning()`**).
- **Observability:** Pointed to **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** for normative Tier 1–3 instrumentation.
- **Cross-links:** Added **Instrumentation report** in header.

### v1.0 (2026-04-11 22:45 CET)
- Initial design: foreground G7 eavesdrop path, lifecycle hooks in `WatchState`, complication + logging integration, repo process constraints.
