# Watch G7 direct BLE observer — implementation plan

**Version:** v2  
**Status:** In progress (Xcode wiring on patched baseline)  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 17:24 CEST  

---

## New / modified (patched baseline)

| Location | Change |
|----------|--------|
| `Trio Watch App Extension/G7/*.swift` | G7 protocol + `G7DirectBLEManager` (no duplicate `TrioComplicationDataStore`) |
| `Trio Watch Shared/TrioComplicationDataSource.swift` | **New** enum for snapshot provenance |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | `TrioComplicationSnapshot` + optional `dataSource`; `shouldUpdate` tie-break; `ComplicationSnapshotFingerprint` includes optional `dataSource`; `wouldAcceptMainThreadSave` for G7 path |
| `Trio Watch App Extension/WatchState+G7ComplicationPipeline.swift` | `applyG7DirectFromObserver` |
| `Trio Watch App Extension/WatchState.swift` | G7 + `displayedComplicationDataSource`; WC/HK snapshot builders set `dataSource` |
| `Trio Watch App Extension/Views/TrioMainWatchView.swift` | `ScenePhase` + G7 `bind`/`start` (with `WatchState.shared`) |
| `Trio Watch App Extension/Views/GlucoseTrendView.swift` | Recency + source + G7 status |

**Baseline:** `dev` with **`git am --3way patches/01-..` through `10-..`**. Human must add **G7 Swift files + `TrioComplicationDataSource.swift` + shared file edits** to the correct targets in Xcode.

## Phases

1. Apply patches 01–10.  
2. Integrate G7 on top (shared store + G7 module).  
3. Xcode: target membership for new files.  

## Changelog

### v2 (2026-04-24 17:24 CEST)

- Replaced plan: integration with `Trio Watch Shared` after patches 1–10; drop G7-local duplicate `TrioComplication*` types.

### v1 (2026-04-24 16:02 CEST)

- Initial plan (pre-patch baseline, listed G7 copies of store) — **superseded** by v2.
