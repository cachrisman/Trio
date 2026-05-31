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

## Changelog

- v1.0 (2026-05-31) — Initial log: fixes 1–3 implemented and committed; delivery steps pending.
