# HealthKit Channel Improvements — Design (R6.1)

**Version:** v1.0
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 11:33 CET
**Status:** COMPLETED — implemented 2026-03-15, shipped build 141. Commit `44d7a7579` on `feature/watch-complication-improvements`.

See [problem-and-strategy.md](../problem-and-strategy.md) for overall context.
Implementation plan: [healthkit-improvements-implementation-plan.md](healthkit-improvements-implementation-plan.md)
Implementation log: [healthkit-improvements-implementation-log.md](healthkit-improvements-implementation-log.md)

---

## Problem

R6 (HealthKit Background Delivery, build 140) established a working HK-based delivery channel for the watch complication but had several limitations:

1. **Stateless fetch:** `HKSampleQuery` re-fetches the last 2 samples on every observer fire. No way to distinguish genuinely new data from phantom/re-delivery fires.
2. **No trend derivation:** `trend=""` on all HK-sourced snapshots, causing trend arrow overwrite when dual-delivery (WC + HK) occurs for the same reading.
3. **No phantom fire classification:** All observer fires logged identically as `hk_observer_fired`, making it impossible to distinguish new-data fires from system-triggered phantom fires.
4. **No epoch guard:** Modified or re-delivered samples could produce duplicate snapshot saves.

## Design

### Anchored Query (replacing HKSampleQuery)

Replace R6's stateless `HKSampleQuery` with `HKAnchoredObjectQuery`. The anchored query tracks a cursor (anchor) and returns only samples added since the last query, enabling:

- **Incremental fetch:** Only new samples returned, not the entire recent history
- **Phantom fire detection:** Zero new samples → `hk_observer_no_new_samples` (not a spurious `hk_observer_fired`)
- **Known-epoch guard:** If latest returned sample's epoch matches persisted last-received epoch → `hk_observer_skipped_known_epoch` (edge case for modified/re-delivered samples)

**Anchor lifecycle:**
- Loaded from `TrioComplicationDataStore` at each observer fire
- Nil anchor (first run or decode failure) → fallback to 24h date cap predicate
- Advanced (saved) after every successful query — including no-new-samples and epoch-guard-skip exits
- Not advanced on query errors or pre-query guard failures
- Serialized via `NSKeyedArchiver`/`NSKeyedUnarchiver` (`HKQueryAnchor` is `NSSecureCoding`, not `Codable`)

**Sample ordering:** Latest and previous samples determined by sorting `addedObjects` by `startDate`, not by raw array order. Store-insertion order is not guaranteed chronological during backfill or sync catch-up.

### Persistence in TrioComplicationDataStore

Six methods added to `TrioComplicationDataStore` for App Group `UserDefaults` persistence:

| Method | Purpose |
|---|---|
| `hkGlucoseAnchor()` / `saveHKGlucoseAnchor(_:)` | Anchored query cursor |
| `hkLastReceivedGlucoseEpoch()` / `setHKLastReceivedGlucoseEpoch(_:)` | Epoch of last processed sample |
| `hkLastReceivedGlucoseValueMgDl()` / `setHKLastReceivedGlucoseValueMgDl(_:)` | Glucose value for delta/trend derivation |

No raw `UserDefaults(suiteName:)` usage from `WatchState` for HK state. All HK persistence centralized in `TrioComplicationDataStore` alongside existing complication snapshot/fingerprint/metadata storage.

**Derive-then-persist ordering:** Delta/trend are derived from the persisted previous epoch/value *before* the current sample's epoch/value are persisted. This prevents overwriting the previous-sample state before derivation.

### Delta and Trend Derivation

**Delta:** Raw numeric delta (`latestMgDl - previousMgDl`), rounded once to integer. Used for both trend classification and display string formatting.

**Previous sample source:**
- **Batch (2+ samples):** Second-most-recent by `startDate` in the same anchored query result
- **Steady state (1 sample):** Persisted previous value/epoch from `TrioComplicationDataStore`
- Delta and trend use the same selected previous sample on a given fire

**Plausibility gate:** Derive only when `0 < timeDelta < 15 min`. When gate fails, both trend and delta fall back: trend to `""`, delta to `"--"`.

**Trend threshold mapping** (same as `BloodGlucose.Direction.init(trend:)`):

| Delta range (mg/dL) | Direction string |
|---|---|
| `<= -30` | `DoubleDown` |
| `-29 .. -20` | `SingleDown` |
| `-19 .. -10` | `FortyFiveDown` |
| `-9 .. 9` | `Flat` |
| `10 .. 19` | `FortyFiveUp` |
| `20 .. 29` | `SingleUp` |
| `>= 30` | `DoubleUp` |

**Output format:** Raw direction strings (`"Flat"`, `"SingleUp"`, etc.), not symbol glyphs. Matches WC path format for correct `TrendSymbolMapper` rendering and dedup alignment.

**Dual-delivery dedup benefit:** When R6.1 trend derivation produces the same raw direction string as the WC path for the same reading, `shouldUpdate` may return `false` for same-reading dual delivery — reducing/eliminating the R6 trend-overwrite regression.

### Source Predicate

**As implemented:** No SyncIdentifier predicate applied. 24h date cap when anchor is nil, nil predicate when anchor exists. Source filtering deferred to R6.2.

**Original spec:** `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)` as a presence-only filter. Not applied in implementation — the single-param `predicateForObjects(withMetadataKey:)` API was not available on watchOS at implementation time.

**Practical risk:** In multi-app HealthKit setups, non-Trio samples may be included. Accepted tradeoff for R6.1. Value-specific or bundle/source refinement deferred to R6.2.

### Scope Boundary

R6.1 only derives `delta` and `trend`. Explicitly out of scope:
- `glucoseColor` remains `nil`
- `state` is not synthetically derived
- HK delta formatting stays mg/dL only (no mmol/L parity)
- `sync_lag` used for logging only — not in display, dedup, or trend logic

---

## Log Taxonomy (R6.1)

| Event | Fields | When |
|---|---|---|
| `hk_background_delivery_registered` | `success=Bool low_power_mode=Bool` | App launch, authorization granted |
| `hk_background_delivery_registration_failed` | `error=String` | Registration failed |
| `hk_authorization_failed` | `granted=Bool error=String` | Authorization denied |
| `hk_observer_error` | `fire_id=UUID error=String` | Observer query error callback |
| `hk_observer_fired` | `fire_id=UUID reading_epoch=Int sync_lag=Int glucose=String delta=String trend=String trend_derived=Bool samples_in_batch=Int query_type=anchoredQuery` | New sample processed |
| `hk_observer_no_new_samples` | `fire_id=UUID` | Anchored query returned zero new samples |
| `hk_observer_skipped_known_epoch` | `fire_id=UUID epoch=Int` | Latest sample epoch matches persisted epoch |
| `hk_observer_query_error` | `fire_id=UUID error=String` | Anchored query error |
| `hk_observer_guard_failed` | `fire_id=UUID reason=String` | Pre-query guard failed |
| `hk_observer_nil_anchor` | `fire_id=UUID` | First run or anchor decode failure |
| `hk_anchor_decode_failed` | `fire_id=UUID` | Persisted anchor could not be decoded |

`query_type=anchoredQuery` on `hk_observer_fired` distinguishes R6.1 logs from R6 logs. R6 uses `save_age`; R6.1 renames to `sync_lag` (identical semantics).

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Anchor decode failure | Low | Falls back to nil anchor + 24h date cap. Logs `hk_anchor_decode_failed`. No data loss — just a wider fetch on next fire |
| Source predicate over-inclusion | Low–Medium | No predicate applied in R6.1. Multi-app setups may include non-Trio samples. Deferred to R6.2 |
| Trend false confidence | Low | Threshold mapping approximates CGM native trend. Acceptable — strictly better than R6's `trend=""` |
| Log complexity (11 event types) | Low | Events are structured and mutually exclusive per fire. BetterStack queries use `query_type=anchoredQuery` discriminator |
| Inherited unit mismatch | Low | HK delta always mg/dL; WC may format mmol/L. Dedup can't recognize same-reading for mmol/L users. Deferred |

---

## Implementation Boundaries

R6.1 did NOT modify:
- HealthKit authorization flow (`requestAuthorization`)
- `setupHealthKitBackgroundDelivery()` shape (exception: `low_power_mode` added to log)
- `setupGlucoseObserverQuery(store:sampleType:)` shape
- `HKObserverQuery` creation, execution, or update handler signature
- Entitlements (`TrioWatchApp.entitlements`)
- Info.plist (`Trio Watch App/Info.plist`)

Scope: HK fetch/processing path (inside the observer callback) + App Group persistence helpers in `TrioComplicationDataStore`.

---

## Changelog

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Reconstructed from remediation plan changelog v1.36–v1.51, alternative-delivery implementation plan Step 7.1, and code inspection during docs reorganization.
