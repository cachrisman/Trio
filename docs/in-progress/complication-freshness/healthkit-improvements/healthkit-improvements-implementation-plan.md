# HealthKit Channel Improvements — Implementation Plan (Step 7.1 / R6.1)

**Version:** v1.0
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 11:33 CET
**Status:** COMPLETED — implemented 2026-03-15, shipped build 141. Commit `44d7a7579` on `feature/watch-complication-improvements`.

Design: [healthkit-improvements-design.md](healthkit-improvements-design.md)
Builds on: [Step 7 / R6](../alternative-delivery/alternative-delivery-implementation-plan.md#step-7--pr-r6-healthkit-background-delivery), shipped build 140.

---

## Scope

R6.1 refines the HK fetch/processing path inside the observer callback. It does not replace R6's observer registration, authorization, entitlements, or background delivery mechanics.

### What changed

| File | Scope of change |
|---|---|
| `Trio Watch App Extension/WatchState.swift` | Replaced `HKSampleQuery` fetch helper with `HKAnchoredObjectQuery`; added epoch guard, anchor lifecycle, trend/delta derivation, fire_id threading, updated log events |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Added 6 persistence methods: anchor, epoch, and previous-sample value |
| `Trio Watch Complication/TrioWatchComplication.swift` | Added R5f logging (complication_get_timeline_called, complication_get_snapshot_called) |
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | 1 line — minor logging addition |

### What did NOT change

- HealthKit authorization flow (`requestAuthorization`)
- `setupHealthKitBackgroundDelivery()` shape (exception: `low_power_mode` added to log)
- `setupGlucoseObserverQuery(store:sampleType:)` shape
- `HKObserverQuery` creation, execution, or update handler signature
- Entitlements (`TrioWatchApp.entitlements`)
- Info.plist (`Trio Watch App/Info.plist`)

---

## Key implementation decisions

### Persistence location

HK anchor and last-received epoch/value persistence belongs in `TrioComplicationDataStore`, not in raw `UserDefaults(suiteName:)` calls from `WatchState`. Six methods added:

- `hkGlucoseAnchor()` / `saveHKGlucoseAnchor(_:)` — persisted `HKQueryAnchor` (encoded via `NSKeyedArchiver`)
- `hkLastReceivedGlucoseEpoch()` / `setHKLastReceivedGlucoseEpoch(_:)` — epoch of last processed sample
- `hkLastReceivedGlucoseValueMgDl()` / `setHKLastReceivedGlucoseValueMgDl(_:)` — glucose value for delta/trend derivation

### Source predicate

**As implemented:** No SyncIdentifier predicate applied. 24h date cap when anchor is nil (first run or anchor decode failure), nil predicate when anchor exists. Source filtering deferred to R6.2.

### Delta/trend derivation

- Raw numeric delta computed first (`latestMgDl - previousMgDl`), then rounded once to integer for both trend classification and display string
- Trend threshold mapping matches `BloodGlucose.Direction.init(trend:)` — raw direction strings (`"Flat"`, `"SingleUp"`, etc.)
- Plausibility gate: derive only when `0 < timeDelta < 15 min`
- Previous sample: from batch (if 2+ samples) or persisted previous value/epoch (steady-state single-sample fires)
- Derive-then-persist ordering: delta/trend derived from previous state *before* current sample's epoch/value are persisted

### Anchor lifecycle

- Anchor advanced (saved) after every successful query — including no-new-samples and epoch-guard-skip exits
- Epoch/value updated only on genuinely new-sample path
- Anchor decode failure → nil anchor + 24h date cap fallback

---

## Verification checklist (from design doc)

All items verified post-implementation:

| Check | Result |
|---|---|
| Old `HKSampleQuery` helper removed | ✅ Replaced by `HKAnchoredObjectQuery` |
| Exactly one main-thread save block | ✅ `DispatchQueue.main.async { save(...); completionHandler() }` |
| `completionHandler()` called on every path | ✅ Error, no-new-samples, epoch-skip, guard failure, success |
| Derive-then-persist ordering | ✅ Delta/trend derived before epoch/value persisted |
| No raw `UserDefaults(suiteName:)` in WatchState for HK state | ✅ All via `TrioComplicationDataStore` |
| No `defer { completionHandler() }` | ✅ Removed |
| Anchor serialization uses `NSKeyedArchiver`/`NSKeyedUnarchiver` | ✅ |
| Trend output is raw direction string, not symbol glyph | ✅ `"Flat"`, `"SingleUp"`, etc. |

---

## Changelog

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Reconstructed from commit `44d7a7579`, alternative-delivery implementation plan Step 7.1, and remediation plan changelog v1.49–v1.51 during docs reorganization.
