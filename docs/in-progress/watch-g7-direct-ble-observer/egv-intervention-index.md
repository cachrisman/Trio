# Watch G7 Direct-BLE — EGV Reliability Intervention Index

**Purpose:** A single reference of every distinct technical intervention tried, rejected, deferred, or proposed to improve watch-side G7 direct-BLE EGV (glucose reading) capture success. Use it **before proposing new work** to avoid re-litigating settled decisions. Compiled 2026-07-01 from builds 04–216 impl plans/logs, design docs, investigations, and backlog.

**How to update:** when a build ships/rejects/defers an EGV-capture intervention, add a one-line row under the right theme with its ID, mechanism, build, and status. Keep the **Rejected / Prohibited** section current — it is the highest-value part for avoiding dead ends.

> Cross-reference discipline (from the analysis that produced this file): the `fault=dexcom_side` classifier is a **recency heuristic**, not a mechanism; the underlying Dexcom-app link-loss cause is **labelled conjecture, outside Trio's code**. Do NOT invoke a "G7 favors a single phone connection" / primary-secondary theory — debunked (G7 accepts concurrent centrals; the watch observer connects to the same sensor as the phone). See [[watch-g7-dexcom-side-stall-no-favoring-theory]] and build209-impl-plan.md:109.

---

## Telemetry baseline (build 215 soak, sensor DXCMyu, n=1, 114 h)

Key funnel/yield facts the ideas below target:

- **Two-layer connect funnel (fork `g7_core`):** `connect_called` 2745 → `did_connect` 904 (**~33%**); `connect_timeout` 948 (avg age ~140 s, 100% `g7_core`); `connect_skipped` 929 (all `reason=in_flight`); `rescan_scheduled` 1781. Adapter (`g7_ble`) mirrors 869 connects.
- **This is NOT a connection storm.** The C-210-7 connect-gate (≤8 `connect_called`/300 s) is shipped and rarely even trips: avg **3.1** calls per active 5-min window, only **9 of 882** windows over the ceiling, 15 `connect_gated` events total. The residual is **low per-attempt success rate** (steady-rate reconnecting that mostly times out), not bursts — a distinct problem the storm throttle does not address (it bounds *how many* attempts, not *whether* they succeed).
- **Session state dominates yield:** session-active did_connect→egv ≈ **93%** (166/178); no-session ≈ **52–58%**. Session coverage ~44% (215), up from ~28% (214). Coverage is **app-open-gated** (sessions only start while `.active`).
- **pre_egv_disconnect** 1084, `since_connect_s`=0–9 (connections drop within seconds), only ~12% `suspected_eos=true`.
- **Stalls** 95% `fault=dexcom_side`, 100% `phone_fresh=true`; spike at the 40% battery bucket (44 vs 11–22). No Low-Power-Mode / RSSI field is logged.
- **Deep-gap signature:** observer awake (`heartbeat`, `expected_window` firing) but `connect_called=0` — cause (OS-suspend vs no-candidate vs connect-fail) is currently indistinguishable.

---

## Shipped / tried interventions by theme

Status key: ✅ SHIPPED · ❌ REJECTED · ⏸ DEFERRED · 📋 BACKLOG · 💡 PROPOSED-ONLY · 🔎 ANALYSIS/VERIFY (no code)

### Connection / Reconnect / Discovery
| ID | Mechanism | Build | Status |
|---|---|---|---|
| C-04-B0 | `willRestoreState`: cancel CB-preserved pending connects on relaunch; no duplicate ladder | 04 | ✅ |
| C-04-B1 / C-206-D6 | `connectInFlight` guard; force-touch adapter at launch so CB central inits early | 04/206 | ✅ |
| C-04-B3 | `isDiscoveringServices` gate (kills triple auth_notify) | 04 | ✅ |
| C-204-1 | Ensure `bluetooth-central` + background-mode plist reaches built watch app | 204 | ✅ |
| C-204-2 | Seed `G7Sensor(sensorID:)` with expected name (reconnect via stored ID, not scan) | 204 | ✅ |
| C-204-3 / C-208-16 | Shared-fork connect-in-flight guard; register connection events at `.poweredOn`, handle bound peripheral | 204/208 | ✅ |
| B187/B190 MOD-E | Register `connectionEvents` in `.poweredOn` + `connect()` (survives restart) | 187/190 | ✅ |
| B191 scheduler | Unified retry: 2 s fast + 15 s moderate (replaced exponential backoff) | 191 | ✅ |
| B191 attach ladder | `retrieveConnectedPeripherals(withServices:)` first, then stored-ID, then scan | 191 | ✅ |
| B190/B191 timeouts | `connectTimeout` 20→8 s; `discoveryTimeout` 30→15 s (named constants) | 190/191 | ✅ |
| C-207-1 | Don't tear down BLE when ext-session killed while non-active | 207 | ✅ |
| C-207-2 | Fast-reconnect on pre-EGV disconnect (skip 2 s `scanAfterDelay` if no glucose this connection) | 207 (fork) | ✅ |
| C-208-12 | CB didSet lock-inversion fix (`queue.sync`→`async`) | 208 (fork) | ✅ |
| C-212-1 | In-flight connect watchdog (60 s cap on wedged `.connecting`) | 212 | ✅ |
| C-212-2 | Pin zombie-clock to current attempt (guard late didConnect) | 212 | ✅ |

### Session / Runtime / Reanchor
| ID | Mechanism | Build | Status |
|---|---|---|---|
| C-04-B2 | Post-EGV 290 s sleep (stop inter-window churn; MOD-E cancels early) | 04 | ✅ |
| B194-H4 / C-206-D1 | Only `stop()` session on error; **remove** ext-session chaining | 194/206 | ✅ (chaining removed) |
| C-206-D8 | Session-start hygiene: scene-guard `renewSessionIfNeeded`; remove background connect-path renew | 206 | ✅ |
| C-208-1/2/3 | Unwire BLE teardown from invalidation; 15 s pending-start watchdog; unowned-session guard | 208 | ✅ |
| BUG-E finding | `ext_session_active` → 98% vs 58% success; uptime is the lever (not handshake speed) | 212 | 🔎 |
| C-212-5 v1 | Sequential invalidate→restart reanchor | 212 | ❌ (slow `didInvalidate` ~15 s; ended sessions early) |
| C-212-5 v2 | **Inline** near-expiry reanchor while `.active` (0/100/300 ms A/B/C arms, circuit-breaker) | 213 | ✅ |
| Task 5 (215) | Reanchor age 45→40 min (wider reanchor window) | 215 | ✅ |
| Task 9a/9b (215) | didStart ownership guard; reanchor watchdog drains deferred scans | 215 | ✅ |

### Scan / Discovery throttle
| ID | Mechanism | Build | Status |
|---|---|---|---|
| C-210-7 | Connect-gate: ≤8 connects/300 s, gate + retry on overflow (storm throttle) | 211 (fork) | ✅ |
| A5/A7 (209) | Reconnect-storm tripwire; direct-BLE-stall detection (fed C-210-x) | 208/209 | 🔎→✅ |

### Auth / Handshake
| ID | Mechanism | Build | Status |
|---|---|---|---|
| B189 passive contract | Enable auth-notify, wait for `0x05`, then advance to control (passive observer) | 189 | ✅ |
| Synth-MOD-B | Prefer strict `authenticated&&bonded`, fallback permissive after 6 s | 04/181 | ✅ |
| BUG-D | Skip auth on already-bonded session | — | ❌ (G7 auth is sensor-driven, required every connect) |

### Cadence / Timing
| ID | Mechanism | Build | Status |
|---|---|---|---|
| Synth-MOD-A | Multi-trigger EGV cadence (first-connect + auth-transition + 330 s fallback + write-retry) | 04/181 | ✅ |
| B189-B | Inter-window sleep: wake 30 s before next expected window | 189 | ⏸ (removed in 191 for unified scheduler) |
| Return-to-Clock A/B | Default (2 min) gives ~2× session coverage vs 1-hour (more app opens) | 212 | 🔎 (user setting; no code) |
| BUG-G | Re-measure coverage post-throttle; do NOT loosen throttle to chase coverage | 212 | ⏸ |

### Backfill / Gap recovery
| ID | Mechanism | Build | Status |
|---|---|---|---|
| B192 backfill | Lazy backfill-notify + 9-byte parse + buffer + flush on `0x59`/disconnect | 192 | ✅ (parsing) |
| C-209-11 | Skip backfill-subscribe + extended-version GATT in background | 209 (fork) | ✅ |
| C-04-C1a | Sequence-gap detection + logging | 04 | ✅ |
| C-04-C1b/c | **Actively request** backfill (write `0x59`) on small gaps + parse/store | 04 | 💡 (never shipped — `0x59` format was unknown then) |

### Recovery / Stall handling
| ID | Mechanism | Build | Status |
|---|---|---|---|
| B192 watchdog | 20 s stall watchdog re-armed on every CB callback | 192 | ✅ |
| C-208-4 | Connect→EGV 15 s watchdog (`egv_watchdog_fired` + stopScanning) | 208 | ✅ |
| B195 stale-sensor | N≥3 pre-EGV drops → `stale_sensor_binding_suspected`; N≥5 → re-init `G7Sensor` same name | 195 | ✅ |
| C-210-6 | Re-kick bound-but-stalled connection (no full rescan) | 211 (fork) | ✅ |
| C-210-4/5/8 | Cross-source stall tiers; "Restart Dexcom app" notification; Dexcom-vs-Trio fault classification | 210 | ✅ |
| 216-A..E | RSSI logging (A ✅), heartbeat scan/BLE diagnostics (B ✅), recovery markers (D ✅), churn analysis (E ✅); central re-init (C) re-scoped behind C-216-W7, deferred to 217 | 216 | ✅/⏸ |
| **C-216-W7** | Arm-on-adopt for CB-restored `.connecting` attempts + discovery-connect watchdog — closes C-212-1's unwatched-pending-connect blind spots (the 06-30 multi-hour silent-gap class; see build216 plan "Validation update") | 216 | ✅ |
| C-216-W6/W1a | `phantom_disconnect` split (67% of old pre_egv_disconnect was watchdog-cancel fallout); `command_timeout` peripheral/central state stamps (decides the 217 GATT-timeout raise) | 216 | ✅ (telemetry) |

### Observability (selected; many more shipped)
`will_restore_state`, `heartbeat` (5-min), session outcome/`terminal_reason`, `attach_path`, `module=g7_core/g7_ble` namespacing, `scene_phase`/`ext_session_active` stamping (C-212-4), `command_timeout op=`, flush-truncation drop accounting (Task 7 / `177a6c723`), `session_age_s`, `ext_session_nearing_expiry`, `os_version`, `name_provenance`. WatchLogger silent-loss paths root-caused + fixed (`2066f6479`, `177a6c723`).

---

## Rejected / Prohibited — DO NOT re-propose without new evidence

| Idea | Why it's out |
|---|---|
| Skip auth on bonded session (BUG-D) | G7 auth is sensor-driven, required **every** connection; `auth_payload_ignored` is normal traffic |
| CB scan fallback after N failures (NOT-1.0) | Won't find sensor while Dexcom app holds a session; contention not cooperation; unjustified complexity |
| Scene-gated reconnect | **Intentionally** scene-independent (iPhone model); foreground-only windowing breaks background delivery |
| "Add a connect timeout to stop stuck connects" (naive) | Anti-pattern; recovery is via `scheduleReconnect` + the bounded in-flight watchdog (C-212-1). Bounded watchdog is fine; a blocking timeout is not |
| Ext-session **chaining** at willExpire | Removed in 206 (unreliable); replaced by inline reanchor (C-212-5 v2) |
| Apple bg-central / screen-off-scanning entitlement | **Not self-serviceable** — blocked on Apple (FB22619409); no ETA/approval |
| Delete CB restore-identifier path | Reversed: `willRestoreState` **does** fire on watchOS (39 events, build 208) — keep it |
| `CBConnectPeripheralOptionNotifyOnDisconnectionKey:false` | Treats a symptom (accessory-disconnected notif), not cause |
| Persistent "stay-connected between windows" (DiaBLE-style) | Not viable for G7: the **transmitter** shuts BLE down after each EGV (post-EGV shutdown is normal); the watch cannot hold the link open |
| Guessing `0x59` backfill byte offsets | Prohibited in 04 plan (don't guess offsets). NOTE: fork now parses backfill (B192), so the format is known — see Idea #8 |
| "G7 favors single phone connection" / primary-secondary | Debunked; cause is conjecture. See top-of-file note |

---

## Backlog (known, deferred — not in the hot EGV-capture path)
- **watch-to-phone-reading-backfill** — sync watch-caught EGVs the phone missed (better antenna/proximity). 📋
- **perf-optimizations** — logging/battery/radio-churn audit. 📋
- **notif-complication-refresh** — refresh complication on notification interaction (display, not capture). 📋
- **watch-messaging-centralization** — WC payload/dispatch refactor. 📋

---

## Candidate pool — VALIDATED 2026-07-04 (8 of 10 culled)

10 ideas were generated 2026-07-01, then validated against watchOS/CoreBluetooth reality and prior docs. **Only 2 survive as genuine EGV-success levers.** The cull is the valuable part — do not resurrect the rejected ones without new evidence.

**Overarching constraint (why most died):** watchOS offers three background-execution paths and **all are already used or blocked** — `WKExtendedRuntimeSession` (frontmost-only; chaining "non-compliant, fails 100%", build206:17), CoreBluetooth restoration + connection events (the workhorse), and the Apple bg-central entitlement (blocked, non-self-serviceable, build207 P1). **"73% of captures occur with NO active session; the background BLE central is the workhorse, the session is wakeup substrate"** (trio-fable5-review.md:524). There is no untapped "new background wake" to invent — Apple doesn't provide one. The real levers make the *existing* autonomous background reconnect succeed more often per attempt.

### Survivors after code-level validation (2026-07-04): none stand as-is
Both nominal survivors were checked against `G7BluetoothManager.swift` (fork) and fell:

5. **Stale `CBPeripheral`-handle refresh** — ❌ **REJECTED (code evidence).** The connect watchdog (C-212-1, `G7BluetoothManager.swift:542-577`) already cancels a wedged `.connecting` and re-issues through the attach ladder (`:310`, `retrievePeripherals(withIdentifiers:)`) on every cycle — the handle is **already re-retrieved**. And CoreBluetooth vends **one `CBPeripheral` instance per identifier**, so a "fresh handle" for the same sensor is not obtainable. The idea is both already-done and CB-impossible. No target.
7. **Connect-scheduler liveness watchdog** — ⏸ **BLOCKED on 216-B evidence.** The observed deep-gap (06-30 09:00: `heartbeat`/`expected_window` firing, `connect_called=0`, scan running) is **"scan running, no candidate advertising"**, not a Trio scheduler that stopped issuing connects — a scan-restart conjures nothing when there's no peripheral. #7 only has a target if the central is *scanning-but-internally-wedged*, which is one of the three states **216-B (scan-liveness) is built to distinguish**. Do not build #7 until 216-B proves that wedge state occurs.

> **Superseded 2026-07-04 (same day, second ideation round):** a fresh full-soak (182 h) pull + code pass produced a NEW validated pool — W-1..W-7 in `build216-impl-plan.md` §"Fable 5 candidate ideation" — of which **W-7 shipped in build 216** (with the A/B/D instrumentation) and W-1 stage 2 / W-3 / W-4 / W-5 are queued for 217 behind soak data. The "0 of 10" verdict below applies to the *first* pool only; its cull reasoning remains valid and binding.

**Conclusion:** after code + platform validation, **0 of the 10 are clearly-actionable novel EGV-success levers today.** The connection-recovery design space (watchdog C-212-1, re-kick C-210-6, gate C-210-7, re-retrieving attach ladder, fast-rescan C-207-2) is already thoroughly covered. Residual loss is either sensor/RF-side (dexcom_side + phone_fresh) or OS-suspension — neither app-fixable — and **the real gate is the 216 instrumentation (RSSI, scan-liveness) to tell which**. Ship 216-A/B, then re-derive ideas from classified episodes rather than from aggregate counts.

### ⚠️ Downgraded (cheap but low EGV-success value)
1. **LPM + thermal instrumentation.** `isLowPowerModeEnabled` is *already* logged on the HK path (alternative-delivery). Adding `thermalState` to BLE events is cheap, BUT the motivating 40%-battery stall spike is almost certainly **overnight time-of-day** (the multi-hour dexcom_side episodes drain the battery), not LPM — watch LPM is user-toggled, not auto-at-40%. Weak hypothesis; low priority.
10. **Fault-adaptive reconnect budget.** Feasible (wire C-210-8 into C-210-7), but dexcom_side stalls are **unfixable by us** — backing off is a **battery** save, not an EGV gain; trio_side is ~6 events. Near-zero yield upside; file under battery, not capture.

### ⚠️ Not novel + known blocker
4. **Cadence-phase-aligned connects.** Already proposed as "arm radio at epoch−30 s, disarm at epoch+5 min" (fable5:552), **and** blocked: watchOS has "no-quiescence-primitive" (can't reliably disarm) and you must never suppress the fork's reconnect loop. B189-B (fixed 30 s pre-window sleep) was tried and removed. Only the *arm* side is safe; not the win I claimed.

### ❌ Rejected (killed by platform/protocol reality)
2. **HKObserver wake → BLE connect.** The wake fires *because the phone already wrote the reading to HealthKit* (syncs to watch) — waking to BLE-fetch the same reading is circular; adds no new EGV.
3. **`WKApplicationRefreshBackgroundTask` to prime a connect.** Already judged "heavier and more speculative" and **explicitly out of scope** (proactive-transfer:307). Sparse budget (few/hour) can't cover 5-min cadence; it's a data-*pull* mechanism, not BLE.
6. **Connection-parameter / supervision-timeout tuning.** A CoreBluetooth **central has no API** to set supervision timeout / connection interval (peripheral+OS negotiated). Not possible as described.
8. **Active `0x59` backfill request.** Backfill is **push-based** (subscribe → sensor pushes → `0x59` terminates); no range-request exists, and the passive-observer contract is **"never write to control"** (build192:552). Phone already backfilled those readings to HealthKit.
9. **Wrist-raise connect trigger.** Already wired — every wrist-raise fires `scenePhase` transitions + `connection_events_registered reason=foreground_active` (04-plan:222); its rapid-fire *caused* the 3-simultaneous-connect bug. No new hook exists.
