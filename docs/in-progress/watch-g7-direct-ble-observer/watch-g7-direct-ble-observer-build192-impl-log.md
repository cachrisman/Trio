# Build 192 — Implementation log

**Version:** 1.2  
**Status:** Complete — pre-tag cleanup + red-team stop-path follow-up applied; compile/soak proof remains user-side per AGENTS.md  
**Created:** 2026-05-03 09:37 CET  
**Last updated:** 2026-05-03 11:24 CET  

---

## Scope

Single-file replacement of **`Trio/Trio Watch App Extension/G7DirectBLEObserver.swift`** on branch **`feature/watch-g7-direct-ble-observer-synthesis`** (Trio worktree). Aligns watch-side passive G7 BLE with **G7SensorKit** ordering and semantics from the Build 192 reference implementation (manager class in the spec was **`G7DirectBLEManager`**; shipped type name remains **`G7DirectBLEObserver`** for callers and file naming).

No patch regeneration, tags, or Xcode builds were run in the agent sessions that produced the initial replacement or the pre-tag cleanup; **`ci/local-build.sh`** remains user-owned before tag.

## Architecture summary

- **Attach ladder:** `retrievePeripherals(withIdentifiers:)` → `retrieveConnectedPeripherals(withServices: [advertisement, dataService])` → `registerForConnectionEvents` + `scanForPeripherals(withServices: [advertisement])`.
- **Connect:** no application-level connect timeout; `central.connect(_:options: nil)`.
- **Discovery:** single data service; characteristics **`authentication`**, **`control`**, **`backfill`** only.
- **Auth:** enable notify on **`authentication`** first; **`pendingAuth = true`** only after notify enable succeeds; cleared on **`0x05`** authenticated+bonded payload; then enable **`control`** notify. **Never write `0x4E`** to control (sensor pushes glucose).
- **Glucose:** parse **`0x4E`** on **`control`**; algorithm state **`6`** only for reliable EGV; **sequence-only** dedup vs **`lastReadingSequence`**.
- **Sensor identity:** **`knownSensorName`** (full peripheral name) locked on **first reliable EGV** (after dedup), not at auth success (**auto-adopt** path — intentional difference from delegate-mediated G7SensorKit).
- **Backfill:** enable **`backfill`** notify lazily after first reliable EGV; parse 9-byte messages into **`backfillBuffer`**; **`flushBackfillBuffer`** on **`0x59`** (`backfillFinished`) on control or on disconnect; **application deferred to Build 193** (log-only flush).
- **Recovery:** **20 s** stall watchdog re-armed on meaningful CB callbacks (char-specific labels where noted); **2 s** **`scanAfterDelay`** after disconnect / **`didFailToConnect`**; discovery / value-update / **auth+control** notify failures → **`cancelPeripheralConnection`**; **backfill** notify failure → log only.
- **Pending auth + remote disconnect:** If **`CBError.peripheralDisconnected`** on peripheral whose name **`suffix(2)`** matches known sensor while **`pendingAuth`**, clear **`knownSensorName`**, **`persistedID`**, **`lastReadingSequence`**, **`lastSavedGlucoseValue`** (suspected end of session).
- **Logging:** compact **`event=g7_ble <subevent>`** via **`WatchLogger`** (replaces prior **`event=g7_ble_*`** strings).

## Code review consensus (pre-tag)

**Build 192 BLE design is sound; ship after a small cleanup patch.** Review agreed on restoring upgrade continuity (CB restore identifier), real **`stop()`** semantics with scan suppression after teardown, minimal **`WatchState`** G7 status wiring, EGV log/delta parity with prior observer ergonomics, and UUID-based stale callback guards (vs object identity after restore).

## Entry points and lifecycle

| API | Behavior |
|-----|----------|
| **`applyForegroundActiveEntry()`** | Calls **`start()`** (idempotent re-entry: **`scanForPeripheral()`** no-ops if stopped, not powered on, or **`active != nil`**). |
| **`start()`** | On **`queue`**: clears **`isStopped`**, **`loadDailyCountersIfNewCalendarDay()`**, then **`scanForPeripheral()`**. |
| **`noteForegroundInactiveOrBackground(_:)`** | No-op stub; logs foreground/background call (**policy:** no teardown — Core Bluetooth owns lifecycle). |
| **`stop()`** | MainActor **`applyG7DirectBleStatus(.off)`**; on **`queue`**: sets **`isStopped`**, cancels watchdog, flushes backfill buffer, stops scan, **`cancelPeripheralConnection`** if **`active`**, clears session state including **`lastSavedGlucoseValue`** and **`lastReadingSequence`**, logs **`stop_completed`**. **`teardownAndRescan`** does not call **`scanAfterDelay()`** when **`isStopped`** so disconnect callbacks cannot restart scanning. |

**Call sites (Trio):** **`WatchState`** invokes **`applyForegroundActiveEntry()`** and **`noteForegroundInactiveOrBackground(_:)`**. **`stop()`** remains available for explicit wiring; no broad refactors required.

## Pre-tag cleanup patch (applied in `G7DirectBLEObserver.swift`)

Single-file changes before tagging Build 192:

1. **`CBCentralManagerOptionRestoreIdentifierKey`** reverted to **`org.nightscout.trio.watch.g7DirectBLEObserver`** (matches Build 191 / upgrade continuity).
2. **`isStopped`** gate: **`scanForPeripheral()`** returns if stopped; **`start()`** clears the flag; **`stop()`** performs full teardown; **`teardownAndRescan`** only schedules **`scanAfterDelay()`** when **`!isStopped`**. *(Follow-up: **`handle(_:)`** also gates on **`!isStopped`** — see **Red-team stop-path** below.)*
3. **`noteStatus(_:)`** helper → **`WatchState.shared.applyG7DirectBleStatus`** on MainActor, **only** at: passive scan path after **`scan_started`** (**.searching**); **`didConnect`** after identifier guard (**.connecting**); **`parseGlucose`** after dedup / **`lastReadingSequence = sequence`** (**.active**); **`centralManagerDidUpdateState`** for **`.poweredOff`**, **`.unauthorized`**, **`.unsupported`** (**.unavailable**); **`stop()`** sets **`.off`** directly (not via **`noteStatus`**).
4. **`egv_received`** log includes **`delta`**, **`age_s`**, **`message_timestamp`**, plus existing glucose/sequence/trend/algorithm_state/reading_epoch fields.
5. **`lastSavedGlucoseValue`**: delta string **`"--"`** or **`"%+d"`** vs previous saved mg/dL; updated each reliable EGV; cleared on **`stop()`** and in suspected end-of-session block (with **`lastReadingSequence`**).
6. Stale-callback guards: **`active?.identifier == p.identifier`** (with ignore logs) in **`didConnect`**, **`didFailToConnect`**, **`didDisconnectPeripheral`** — avoids **`===`** mismatch when Core Bluetooth reconstructs **`CBPeripheral`** instances (e.g. after **`willRestoreState`**).

## Red-team: stop-path follow-up

**Issue — `handle(_:)` not gated on `isStopped`:** After **`stop()`**, Core Bluetooth can still deliver **`connectionEventDidOccur`**, **`didDiscover`**, or **`willRestoreState`**, all of which funnel into **`handle(_:)`**. **`scanForPeripheral()`** and **`teardownAndRescan`** were already **`isStopped`**-aware, but **`handle`** could still call **`central.connect(p, …)`** and re-arm a session.

**Fix:** At the top of **`handle(_:)`**, **`guard !isStopped else { log("connect_skipped reason=stopped peripheral=…"); return }`** before the intent / **`active`** guard so only the stopped case emits **`connect_skipped`** (no extra log noise for ignore intent or already-active).

**Issue — `lastReadingSequence` not cleared in `stop()`:** Suspected end-of-session in **`teardownAndRescan`** already cleared **`lastReadingSequence`** and **`lastSavedGlucoseValue`** together; **`stop()`** cleared only the latter, leaving a small inconsistency for the next **`start()`** (stale sequence vs new session).

**Fix:** **`stop()`** also sets **`lastReadingSequence = nil`** alongside **`lastSavedGlucoseValue = nil`**.

## Non-blockers / post-tag watchouts

- **BetterStack / log dashboards:** Event strings moved from **`event=g7_ble_*`** to **`event=g7_ble <subevent>`**; saved queries or panels keyed on old names may need updates.
- **First sensor switch** on Build 192: manually sanity-check identity + dedup + delta behavior on device.
- **Backfill:** still parse/buffer/flush (log-only); historical application remains **Build 193**.
- **Scan service UUID `[FEBC]`:** aligned with G7SensorKit; use soak logs to confirm discovery stays healthy in the field.

## Daily counters (preserved from Build 191)

**Keys:** file-private **`G7DailyCounterKeys`** — unchanged UserDefaults keys **`G7DirectBLEObserver.bleCountersCalendarDay`**, **`bleConnectsToday`**, **`bleEGVsToday`**, **`bleConnectionEventsToday`**.

| Counter | Increment site |
|---------|----------------|
| **`bleConnectsToday`** | **`centralManager(_:didConnect:)`** after **`guard active?.identifier == p.identifier`**, before **`discoverServices`**, then **`persistDailyCounters()`** + **`mirrorDailyCountersToWatchState()`**. |
| **`bleEGVsToday`** | **`parseGlucose`** after sequence dedup passes (**`lastReadingSequence = sequence`**), **before** snapshot / lazy backfill notify / watchdog bump for EGV, then persist + mirror. |
| **`bleConnectionEventsToday`** | **`connectionEventDidOccur`** for **every** **`.peerConnected`** (including events that do not call **`handle`**), then persist + mirror. |

**Load/mirror:** **`loadDailyCounters()`** once at end of **`init`** after **`CBCentralManager`** creation; **`loadDailyCountersIfNewCalendarDay()`** at start of **`start()`** on **`queue`**; **`mirrorDailyCountersToWatchState()`** uses **`Task { @MainActor in WatchState.shared.… }`**.

## Persistence / restore identifiers

| Item | Value / note |
|------|----------------|
| **Peripheral UUID** | **`G7DirectBLEObserver.peripheralIdentifier`** (continuity with prior observer). |
| **Sensor display name** | **`G7DirectBLEObserver.sensorName`** (new key vs spec snippet’s **`G7DirectBLEManager.sensorName`** — aligns with type rename; first reliable EGV re-locks if missing). |
| **`CBCentralManagerOptionRestoreIdentifierKey`** | **`org.nightscout.trio.watch.g7DirectBLEObserver`** (reverted from interim Build 192 snippet value for upgrade / state-restore continuity with Build 191). |

## Removed from Build 191 observer (non-exhaustive checklist)

Application-level **`connectTimeout`**, **`discoveryTimeoutInterval`**, **`scanTimeout`**; **`scheduleNextAttempt`** / **`fastRetryCount`** / **`schedulerMode`** / **`G7BLESchedulerMode`**; **`pendingTerminalReason`** / **`currentSessionGeneration`**; **`connectInFlight`** / **`isDiscoveringServices`**; **`controlWriteRetryWorkItem`** and EGV write-and-retry path; **`egvFallbackTimerSeconds`**, **`egvControlNotReadyRetryDelay`**, **`controlWriteRetryDelay`**, **`maxConsecutiveControlWriteFailuresBeforeReconnect`**; **`authFallbackWorkItem`** / **`authFallbackDelay`** / **`scheduleAuthFallback`** / **`cancelAuthFallback`**; **`emitSessionOutcome`** / **`resolveTerminalReason`** / **`G7ObserverStage`**; legacy **`event=g7_ble_*`** log strings.

## Intentional differences vs G7SensorKit (retained)

- Sequence-only EGV dedup.
- **`TrioComplicationSnapshot`** / **`WatchState.applyG7DirectBleSnapshot`** save path.
- No extended-version request (**`0x52`**).
- Auto-adopt first reliable sensor (no delegate/UI gate).
- Backfill application deferred to **Build 193**.
- Stall-style session watchdog instead of per-GATT-operation timeouts.

## Metrics

- **Previous file length (Build 191-era reference):** ~1151 lines.  
- **Post–Build 192 replacement:** ~568 lines.  
- **After pre-tag cleanup patch:** ~625 lines.  
- **After red-team stop-path follow-up:** ~629 lines (`wc -l` on **`G7DirectBLEObserver.swift`** as of 2026-05-03).

## Verification performed (agent session)

- Static consistency with Build 192 behavioral checklist supplied in implementation brief (attach ladder, notify ordering, no control write, backfill flush triggers, watchdog + fast cancel paths).
- Pre-tag cleanup: code review items 1–6 reflected in **`G7DirectBLEObserver.swift`** (restore ID, **`stop()`** / **`isStopped`**, status + EGV log + delta, UUID guards).
- Red-team stop-path: **`handle(_:)`** **`isStopped`** gate + **`lastReadingSequence`** clear in **`stop()`** documented and applied in the same file.
- **Not run:** **`xcodebuild`**, **`ci/local-build.sh`**, **`scripts/patch-test.sh`** (AGENTS.md rule 10; user-owned compile/soak).

## Open / remaining items

1. **Build 193:** consume **`backfillBuffer`** / historical application path.
2. Local **`ci/local-build.sh`** with user-chosen flags before tagging Build 192.
3. Post-tag: BetterStack dashboard / query updates if still keyed on legacy **`event=g7_ble_*`** strings; soak confirmation of scan/discovery and first sensor switch.

---

## Changelog

### v1.2 (2026-05-03 11:24 CET)
- Documented **red-team stop-path** gaps after the first cleanup: **`handle(_:)`** could still **`connect`** when **`isStopped`**; **`stop()`** omitted **`lastReadingSequence`** reset.
- Recorded **fixes**: **`guard !isStopped`** at top of **`handle`** with **`connect_skipped reason=stopped`** only for that case; **`lastReadingSequence = nil`** in **`stop()`** next to **`lastSavedGlucoseValue`**.
- Updated **entry-point** **`stop()`** row, **pre-tag item 2** cross-reference, **metrics** (~629 lines), **verification**, **status**, and **version**. Reason: impl log matches code shipped after red-team pass.

### v1.1 (2026-05-03 11:15 CET)
- Recorded **code review consensus** (design good; small cleanup before tag) and the **six pre-tag fixes** applied in code: CB restore identifier, **`isStopped` + real `stop()`**, minimal **`WatchState`** status map, EGV log fields + delta from **`lastSavedGlucoseValue`**, UUID-based lifecycle guards.
- Replaced stale “lifecycle stubs / restore key tradeoff” narrative with current **`stop()`** / **`start()`** behavior and **`…g7DirectBLEObserver`** restore key.
- Added **non-blockers / post-tag watchouts** (BetterStack event rename, sensor switch sanity, backfill deferral, scan soak).
- Updated **metrics** (~625 lines post-cleanup), **daily counter** row (identifier guard), **open items**, verification bullets, **scope** footnote (agent sessions + user-owned build), and **architecture** suspected-session bullet (**`lastSavedGlucoseValue`** clear). Reason: align log with shipped code and review at tag time.

### v1.0 (2026-05-03 09:37 CET)
- Initial Build 192 implementation log: G7SensorKit-aligned observer replacement, entry-point mapping, lifecycle stubs, daily counter contracts, persistence keys, removals checklist, intentional deltas vs G7SensorKit, metrics, and verification bounds. Reason: capture shipped design decisions and traceability without coupling to sibling plan doc versions.
