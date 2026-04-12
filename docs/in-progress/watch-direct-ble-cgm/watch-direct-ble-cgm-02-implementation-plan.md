# Implementation plan: Watch — Dexcom G7 direct BLE eavesdrop

**Version:** v1.27  
**Status:** Patch **11** on stack; **CI / fastlane build 158 — succeeded** (**2026-04-13**). **Open:** device **soak** / on-device extended-runtime validation, Phase **D** / **R2** tests and remaining items in review tables  
**Created:** 2026-04-11 22:45 CET  
**Last updated:** 2026-04-13 00:47 CET  

**Design reference:** [watch-direct-ble-cgm-01-design.md](watch-direct-ble-cgm-01-design.md)  
**Instrumentation report:** [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)  
**Diff review (out of band):** Optional transient `git diff` scratch docs may be generated under repo **`docs/code-review/`** per **`.cursor/rules/code-review-diff-doc.mdc`** — **not** linked from this initiative; traceability is **design / plan / report 03** only.

Per-version notes live in the [Changelog](#changelog) below (not duplicated in the header).

---

## Prerequisites

| Field | Record |
|-------|--------|
| **Docs worktree** | `Trio-dev` — `docs/in-progress/watch-direct-ble-cgm/` |
| **Code worktree** | **`Trio`** sibling worktree (Swift sources not in `Trio-dev`) |
| **Branch** | `feature/watch-direct-ble-cgm` (expected) |
| **Process** | `docs/process/feature-branch-workflow-optimization.md` — implement on feature branch; publish via `generate-patch.sh` when ready; **do not** hand-edit `patches/*.patch` |

---

## Scope

- Add **`G7DirectBLEManager`** to the **Trio Watch App Extension** target (Swift source under `Trio Watch App Extension/`).
- Wire **foreground / background** lifecycle in **`WatchState`** to **start** / **stop** BLE work.
- Integrate **`TrioComplicationDataStore`** + **`WatchLogger`** per design.
- **Phone → watch active G7 Bluetooth name (v1.19):** one **additive** **`WatchMessageKeys.activeG7PeripheralName`** field in the nested **`watchState`** payload (iPhone: **`G7CGMManager.sensorName`** via **`FetchGlucoseManager`** in **`AppleWatchManager.sendDataToWatch`**; included in complication **`userInfo`** / **`applicationContext`** allowlist; watch: **`applyPhoneActiveG7PeripheralNameIfPresent`**, then **`g7DirectBLEManager.activePeripheralName`** before **`startScanning()`**). **Not** App Group–backed (per-device stores do not sync).

## Out of scope (v1.0)

- Full Dexcom J-PAKE client or bonding UI.
- Background BLE scanning or `BGTask` BLE refresh.
- Broad redesign of WatchConnectivity message shapes beyond the **additive** **`active_g7_peripheral_name`** field (see **Scope**).
- **`ENABLE_G7_DIRECT_BLE`** (or similar) compile flags in source or sync config for this v1.0 track.

## Dependencies

- Correct **target membership** for new Swift files (human/Xcode canonical workflow — **`AGENTS.md`** forbids agent-driven `project.pbxproj` edits and `sync_project_files.rb`).
- Optional: DiaBLE / public UUID references for G7 — cite in code comments only; design doc stays product-level.

---

## Sequencing + ship boundaries

| Phase | Name | Shippable alone? |
|-------|------|------------------|
| A | Lifecycle wiring in `WatchState` | Yes (no-op if manager not invoked) |
| B | `G7DirectBLEManager` CoreBluetooth + parse + persist | Yes (device-tested) |
| C | Observability + soak validation | Yes (evidence in logs) |
| D | Hardening (optional follow-up) | Yes |

---

## Shared conventions

- Observability: `docs/process/standards-observability.md` — new logs use `event=g7_ble_*` (design).
- Logging: **no secrets**; avoid PHI in fixtures; Better Stack queries per `docs/process/betterstack-guide.md`.
- **`G7DirectBLEManager`:** Private **`logG7Ble(_:function:file:line:)`** appends **`g7_session=`** when applicable and forwards **`#fileID` / `#line` / `#function`** into **`WatchLogger.shared.log`** so phone-side / Better Stack fields reflect the **call site** of **`logG7Ble`**, not the helper. The unused **`logG7`** wrapper was removed. See [watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md) (**Log line attribution**).

---

## Phase A: Lifecycle wiring (`WatchState`)

**Ship gate:** Yes — the manager instance is created eagerly, but CBCentralManager creation is deferred until startScanning(), so there is no init-time BLE work.

### Task A1 — Manager property + foreground entry

- **Files:** `Trio Watch App Extension/WatchState.swift`
- **Change:** Add **`@ObservationIgnored private let g7DirectBLEManager = G7DirectBLEManager()`** (shipped pattern — **`lazy`** is incompatible with **`@Observable`** macro expansion here; **`G7DirectBLEManager`** still defers **`CBCentralManager`** until **`startScanning()`**).
- **Steps:** Place near other extension-owned subsystems; ensure **main-thread** context matches existing `assert(Thread.isMainThread, ...)` for lifecycle methods.
- **Acceptance:** `handleForegroundActiveEntry()` ends with `g7DirectBLEManager.applyForegroundActiveEntry(activePeripheralName:)` after existing startup `Task` work is **scheduled** (ordering preserved vs `WatchErrorReporter` startup). **`applyForegroundActiveEntry`** calls **`startScanning()`** only when a full restart is needed (not when a **`.scanning`…`.connected`** session is already in progress).
- **Observability:** None required beyond manager internals; lifecycle correlation logs (**`g7_ble_lifecycle`**) per **[watch-direct-ble-cgm-03-instrumentation-report.md](watch-direct-ble-cgm-03-instrumentation-report.md)** when implementing **Task C3**.

### Task A2 — Inactive / background correlation (no BLE stop)

- **Files:** `WatchState.swift`, `TrioWatchApp.swift`, `ExtensionDelegate.swift`
- **Change:** `handleForegroundInactiveOrBackground(scenePhase:)` — **`ScenePhase.inactive`** / **`.background`** emit **`g7_ble_lifecycle`** correlation (**`ble_continues=true`**, **`active_window_*`** on inactive) and run existing **non-BLE** startup bookkeeping (**`startupIsForegroundActive`**, deferred startup cancellation, etc.). **Do not** call **`g7DirectBLEManager.stop()`** — direct BLE continues until **OS extended-runtime expiry / invalidation** or **`teardownSession`**. **`ScenePhase.background`** emits **`phase=background`** when a prior inactive pass stashed **`g7_session`**. **Single driver:** invoke **only** from **`TrioWatchApp`** **`.onChange(of: scenePhase)`** (do **not** call from **`ExtensionDelegate.applicationWillResignActive`** — avoids duplicate OS callbacks; **`ExtensionDelegate`** may keep **`watch_app_resigning_active`** for transport diagnostics).
- **Acceptance:** No BLE stop on leave-active; no spurious **`phase=background`** on inactive-only transitions; one canonical entry path for **`g7_ble_lifecycle`** leave-active lines per report **03** **v1.15**.

---

## Phase B: `G7DirectBLEManager`

**Ship gate:** Yes after on-device smoke test.

### Task B1 — Central + scan + connect

- **Files:** New `Trio Watch App Extension/G7DirectBLEManager.swift`
- **Change:** `CBCentralManager` on **main** queue; scan `FEBC`; connect first discovered peripheral; discover data service + characteristics.
- **Acceptance:** Logs `g7_ble_scan_started`, `g7_ble_peripheral_discovered`, `g7_ble_connected` on success path.

### Task B2 — Auth eavesdrop + subscribe

- **Change:** Enable notify on **authentication**; on notify, send minimal auth payload as required by observed protocol; **log** `0x03`; **do not** complete J-PAKE; on `0x05` authenticated, enable notify on **control** and **backfill**.
- **Acceptance:** Logs include `g7_ble_auth_challenge_received`, `g7_ble_authenticated`, notification state transitions without crash.

### Task B3 — EGV request + parse + save

- **Change:** When **control** notifications are ready (DiaBLE sequence), write **`0x4E`** to **control** once — **do not** gate on backfill; parse EGV (`0x4E` opcode), compute `readingDate`, build `TrioComplicationSnapshot`, call `TrioComplicationDataStore.shared.save(..., triggerReload: true, minInterval: 5)` **synchronously on the main queue** (same as CB delegate).
- **Acceptance:** `g7_ble_egv_received`, `g7_ble_snapshot_saved` logs; complication updates on device.

### Task B4 — Teardown + errors

- **Change:** **`stop()`** (explicit), **`teardownSession`**, and **`WKExtendedRuntimeSessionDelegate`** expiry/invalidation paths stop scan, cancel connection, reset session state as applicable; log disconnect/errors with structured fields.
- **Acceptance:** Graceful teardown on OS extended-runtime end and error paths; no leaked assertions on unhappy paths.

---

## Phase C: Validation

### Task C1 — Device soak

- **Acceptance:** Capture Better Stack or console excerpt showing end-to-end `g7_ble_*` sequence; note build identifier.

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
| Reconnect on protocol failures | **`teardownSession`:** schedule 7s `startScanning()` only when `scanningStarted && !isFailure`. Protocol/discovery/auth-write failures (`isFailure == true`) **do not** schedule reconnect, avoiding deterministic connect → fail → loop. Clean / non-failure teardowns still rescan. **Tradeoff:** `didDisconnect` with CB **error** sets `isFailure == true` → no auto-reconnect for that path (acceptable for soak per review; refine later if needed). |

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
| **Code** | **`import Observation`** (alongside existing imports). **`@ObservationIgnored private let g7DirectBLEManager = G7DirectBLEManager()`** — drop **`lazy`**. Rationale: **`G7DirectBLEManager`** does not allocate **`CBCentralManager`** until **`startScanning()`**, so eager **`let`** does not introduce launch-time BLE work; **`lazy`** is not supported with Swift Observation **+** **`@Observable`** in this configuration. |
| **Patch** | Regenerate **`11-watch-direct-ble-g7.patch`** after the commit; **`./scripts/patch-test.sh`** **passes** (**01**–**11**). |

**Plan alignment:** Phase **A1** text described a **`lazy`** manager; **shipped** storage is **`let`** + **`@ObservationIgnored`** for compiler/toolchain correctness. Behavior (no BLE until foreground **`startScanning()`**) unchanged.

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

---

## Changelog

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
