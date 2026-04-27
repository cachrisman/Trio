# Watch G7 direct BLE observer — implementation log

**Version:** v2  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 17:24 CEST  

---

## Branch and base

- **Branch:** `feature/watch-g7-direct-ble-observer-patched-cea9`  
- **Base:** `dev` @ `1aa70ac077ef1492cddfce2bd39e0b2481f3d55c`  
- **Patches applied (order):** `patches/01-*.patch` … `patches/10-*.patch` via `git am --3way` (clean apply, no conflict).  

## What changed vs first attempt

The earlier branch `feature/watch-g7-direct-ble-observer-clean-cea9` was from **plain `dev`** and missed the watch **complication / session** stack. Cherry-picking that commit onto **dev+01–10** **conflicts** with `TrioMainWatchView` and would **duplicate** `TrioComplicationDataStore` (patches 09+ already add `Trio Watch Shared/TrioComplicationDataStore.swift`).

**Resolution:** Re-integrate the G7 observer to use the **shared** `TrioComplicationDataStore` + add optional `dataSource` on `TrioComplicationSnapshot`, G7 `applyG7DirectFromObserver`, and wire `TrioMainWatchView` to `G7DirectBLEManager` without dropping **WatchState.shared**, telemetry, or the third (debug) tab.

## Validation

- `scripts/patch-test.sh` not re-run in this follow-up; patches were applied with `git am` only.  
- No `xcodebuild` (per process rules).  

## Changelog

### v2 (2026-04-24 17:24 CEST)

- Logged rebased work on `dev+01–10`, conflict rationale, and shared-store integration.

### v1 (2026-04-24 16:02 CEST)

- Initial handoff log (plain-`dev` base).
