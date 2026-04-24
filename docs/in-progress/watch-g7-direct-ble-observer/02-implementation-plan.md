# Watch G7 direct BLE observer — implementation plan

**Version:** v1  
**Status:** Complete (code + docs; Xcode wiring pending)  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 16:02 CEST  

---

## New Swift files (`Trio Watch App Extension/G7/` and extensions)

| File | Purpose |
|------|---------|
| `G7BLELog.swift` | `WatchLogger` wrapper; forwards `#file`/`#line`/`#function` for `event=g7_ble_*` |
| `G7BLEConstants.swift` | Service/characteristic UUIDs, `FEBC`, opcodes, restore ID |
| `G7Data+G7Bytes.swift` | `Data` little-endian parse helpers for messages |
| `G7AlgorithmState.swift` | `AlgorithmState` mirror for G7 EGV |
| `G7GlucoseMessage.swift` | EGV struct + `trendString` for Nightscout arrow names |
| `G7AuthChallengeRxMessage.swift` | Auth 0x05 `isAuthenticated`/`isBonded` |
| `G7DirectBLEStatus.swift` | Glanceable UI enum |
| `G7DirectBLEManager.swift` | `CBCentral` ladder, GATT, auth → control, EGV timer, persistence |
| `TrioComplicationDataSource.swift` | `displayed` source enum |
| `TrioComplicationSnapshot.swift` | `readingDate` + `ingestDate` + `dataSource` |
| `TrioComplicationDataStore.swift` | Winner policy + throttled `WidgetCenter.reload` |
| `WatchState+G7ComplicationPipeline.swift` | Apply phone vs G7 snapshots, local delta for G7 |

## Modified files

| File | Change |
|------|--------|
| `Trio Watch App Extension/WatchState.swift` | G7 UI + `displayedComplicationDataSource`; `applyPhonePathToComplicationPipeline()` at end of `processRawDataForWatchState` |
| `Trio Watch App Extension/Views/TrioMainWatchView.swift` | `ScenePhase` + `G7DirectBLEManager` bind + `start` on active |
| `Trio Watch App Extension/Views/GlucoseTrendView.swift` | Recency + source + G7 status line |
| *(deferred)* `Trio Watch App Tests` (or new extension test target) | EGV/auth hex fixtures after Xcode adds `@testable import` for the extension |

## Phases (ordering)

1. **Constants + parsing** — wire-format correctness without BLE.  
2. **Complication model + store** — winner + attribution.  
3. **BLE manager** — central, ladder, GATT, auth, control, EGV.  
4. **WatchState + UI** — display path + scene `start()`.  
5. **Unit tests** — message parsing.  
6. **Human** — add Swift files to watch extension target, optionally add a **Watch App Extension** test target and wire `@testable import` for the hex fixture tests, fix any `WidgetKit` import if build fails.

## Dependencies

- G7 must be in direct-to-watch with Dexcom app; Trio is observer-only.  
- iPhone remains unchanged (no `activeG7PeripheralName` in this attempt).

## Tests (narrow)

- EGV **hex fixture** in `G7GlucoseMessage` (19 bytes) and **Auth 05 01 01** — to be added in an extension test target when `@testable import` is available.  

## Changelog

### v1 (2026-04-24 16:02 CEST)

- Initial plan: file list, order, and test scope for the watch-only observer POC.
