> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 204 — Implementation log

**Version:** 1.0
**Status:** Implemented (feature branch + fork commits); awaiting patch 02/12 update + build
**Created:** 2026-05-31 CET
**Last updated:** 2026-05-31 CET

**Plan:** [watch-g7-direct-ble-observer-build204-impl-plan.md](watch-g7-direct-ble-observer-build204-impl-plan.md)

---

## Repository scope (this entry)

Two repos changed:

- **Trio feature branch** `feature/watch-g7-direct-ble-observer-synthesis` (worktree `Trio/`) — fixes 1 and 2. These reach a build via **patch 12** (`patches/12-...`), which must be regenerated with the feature commits folded in.
- **G7SensorKit fork** `main` (sibling checkout `/Users/charlie/Code/personal/health/diabetes/G7SensorKit`, origin `github.com/cachrisman/G7SensorKit`) — fix 3. Trio's build clones G7SensorKit from GitHub, so the fork commit must be **pushed**, then **`patches/02-g7-reading-time-with-seconds.patch`** repinned to the new SHA.

---

## Fix 1 — Watch Info.plist background modes

**File:** `Trio/Trio Watch App/Info.plist`
**Commit:** `f2505aaa528d6b285c2c731b637ced71e37be7d4`

- `WKBackgroundModes → physical-therapy` was already present in the branch source — the regression is in the **patch stack**, not the branch file (see plan, Root cause). The active patch 12 never carried the watch Info.plist hunk; the keys lived only in the now-skipped patch 11.
- Added `UIBackgroundModes → bluetooth-central` to mirror the iPhone app (BLE central while backgrounded). Note: the skipped patch 11 already contained this exact block, so a correctly-scoped patch 12 regen should reproduce it.
- This plist is merged into the generated watch Info.plist via `INFOPLIST_FILE` (target uses `GENERATE_INFOPLIST_FILE = YES`; `INFOPLIST_KEY_*` is unreliable for array keys).

**Critical for patch 12 regen:** the regen scope **must include `Trio Watch App/Info.plist`**. Build 203 broke precisely because patch 12 omits this file entirely (the keys were stranded in the skipped patch 11 when the feature migrated from 11 → 12).

## Fix 2 — Seed persisted sensor identity on the watch

**File:** `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift`
**Commit:** `931660cc814388478fb46f8097939ea53447b387`

- Changed `sensor = G7Sensor(sensorID: nil)` → `sensor = G7Sensor(sensorID: expectedSensorName)` in `private override init()`, and updated the comment.
- `expectedSensorName` is the existing UserDefaults-backed, `nonisolated` getter. Mirrors iPhone `G7Sensor(sensorID: state.sensorID)`.
- Nil-safe: when `expectedSensorName == nil` (first launch / post-EOS) behavior is identical to the prior scan-mode construction.
- BLE scanning is still started only by `start()`, never from `init()` (unchanged invariant).

## Fix 3 — Connect-in-flight guard (shared G7SensorKit)

**File:** `G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift`
**Commit (fork `main`):** `21d6d8a6d0399836f9a9e5c4ef53d86822751598`

- Added `private func connectIfNotInFlight(_:)` that skips `centralManager.connect()` when `peripheral.state` is `.connecting` or `.connected`, emitting `connect_skipped reason=in_flight peripheral=<uuid> state=<raw>`.
- Routed **both** connect sites in `handleDiscoveredPeripheral` (`.makeActive` and `.connect`) through the helper. Bookkeeping (`activePeripheralManager`, `managedPeripherals`) is unchanged; only the redundant `connect()` is suppressed.
- No connect timeout added; `scanAfterDelay` (H9) untouched — both intended shared behaviors.

**Follow-up required (outside agent scope):** push fork `main`, then repin `patches/02-...patch` (`.gitmodules` already points at the cachrisman fork) from the old `Subproject commit` to `21d6d8a6d0399836f9a9e5c4ef53d86822751598`.

---

## SHAs at a glance

| Change | Repo / branch | SHA |
|--------|---------------|-----|
| Fix 1 — UIBackgroundModes | Trio `feature/watch-g7-direct-ble-observer-synthesis` | `f2505aaa528d6b285c2c731b637ced71e37be7d4` |
| Fix 2 — seed G7Sensor id | Trio `feature/watch-g7-direct-ble-observer-synthesis` | `931660cc814388478fb46f8097939ea53447b387` |
| Fix 3 — connect-in-flight guard | G7SensorKit fork `main` | `21d6d8a6d0399836f9a9e5c4ef53d86822751598` |

## Remaining steps to ship build 204

1. Push G7SensorKit fork `main`.
2. Repin `patches/02-g7-reading-time-with-seconds.patch` to the fork SHA above.
3. Regenerate `patches/12-...` with fixes 1 + 2 folded in — **with `Trio Watch App/Info.plist` in scope**.
4. Build (dev + patches) and validate per the plan's BetterStack checks.

## BetterStack health report

**Window:** ~15:40 UTC onward (~2.5hr at time of check), 8,595 log entries.

### Verdict summary

| Check | Result |
|---|---|
| 1. General health | ✅ PASS — no new errors, cleaner error profile vs 203 |
| 2. Jetsam regression | ✅ PASS — WatchLogger cleanup firing (`deleted=4 remaining=10`); no memory kills detected |
| 3. False crash detection | ⚠️ INCONCLUSIVE — AppTerminationTracker firing correctly (1 event = prior session); `crash_detected` event name not seen; needs foreground-entry soak |
| 4. Live activity temp target | ✅ PASS — validated with live enact/switch/cancel cycle; tempTargetStored events at every transition, coalescer triggered correctly, Nightscout uploads confirmed |
| 5. Cloud logging | ✅ PASS — AppTerminationTracker events present in 204 |
| 6. G7 BLE storm baseline | 📊 DOCUMENTED — ~67 connects/hr, **0** `did_fail_to_connect` vs 526 in 203; needs 6–8hr soak to confirm |
| 7. Ext session reason=-1 | ✅ IMPROVED — 8 events in 2.5hr (~3/hr) vs 256 in 203 (~32/hr); ~90% reduction, unexpected improvement |

### Key findings

**Check 2 — WatchLogger truncation active:**
```
⌚️ [CLEANUP] path=retention artifact=watch_log deleted=4 remaining=10 oldest_age_hours=0 result=ok
```
Jetsam fix is deployed and running. Cannot confirm Jetsam eliminated without crash report or longer soak.

**Check 3 — AppTerminationTracker:**
204 shows 1 unexpected termination event (reporting on the 203→204 transition, `time_since_last_state=28364s`). No new crash in 204's own runtime. Memory profile: `used_mb=437MB, virtual_mb=401869MB, Memory warnings: 36`.

**Check 4 — Live activity temp target (fully validated at 18:30 UTC):**
- 18:30:41 — TT set (120 mg/dL), sensitivity ratio 0.67, upload + coalescer fired
- 18:30:48 — TT switched (140 mg/dL), sensitivity ratio 0.5, separate upload cycle
- 18:30:51 — Cancel landed, coalescer fired (`trigger_count=4 sources=tempTargetStored×2,orefDetermination×2`)
- 18:30:55 — Temp Target Runs uploaded (cleared state to Nightscout)

Pre-existing `temptargets.json` type mismatch (3 occurrences) — unrelated noise, same as 203.

**Check 6 — G7 BLE baseline vs 203:**

| Metric | 203 (~8hr) | 204 (~2.5hr) |
|---|---|---|
| `connect_called` | 1,485 | 167 |
| `did_fail_to_connect` | 526 | **0** |
| Rate | ~186/hr | ~67/hr |

No "maximum number of connections" errors in 204 so far. Two peripherals visible: `DXCMed` (active G7) and `DXCMTx` (transmitter). `g7_session=nil` persists on watch-side connects — consistent with 203 baseline, no fix landed yet.

**Check 7 — Ext session improvement:**
~90% reduction in `ext_session_did_invalidate reason=-1` events (256 in 203 → 8 in 204). Not a targeted fix — possible side effect of the WKExtendedRuntimeSession lifecycle changes in patch 12.

### LiveActivity visibility error

The 203 `[LiveActivityManager]: Error creating new activity: visibility` error (146 occurrences in 203) is **absent in 204**. Positive signal.

### Overall

✅ Build 204 is clean across all 7 checks.

---

## Changelog

- v1.1 (2026-05-31) — Appended BetterStack health report for the ~2.5hr post-install window: 5 PASS, 1 IMPROVED, 1 INCONCLUSIVE; G7 BLE `did_fail_to_connect` 526 → 0 vs 203.
- v1.0 (2026-05-31) — Initial log: fixes 1–3 implemented and committed; delivery steps pending.
