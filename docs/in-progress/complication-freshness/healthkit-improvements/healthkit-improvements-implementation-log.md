# HealthKit Channel Improvements — Implementation Log

**Version:** v1.0
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 11:33 CET

---

### Build 141 — R6.1 HealthKit Channel Improvements (2026-03-15/16)

**Commit:** `44d7a7579` ("fix: R5c attribution with work item; R5b inner-payload comment; R6.1/R5f logging") on `feature/watch-complication-improvements`, 2026-03-16 00:22 CET
**Patch:** `09-watch-complication-improvements.patch` regenerated
**Build:** 141 (v0.6.0) — deployed to TestFlight
**Bundled with:** R5b, R5c, R5f in the same commit (shared commit because all changes were reviewed together)

**Files changed (R6.1-specific):**

| File | Lines changed | R6.1 scope |
|---|---|---|
| `Trio Watch App Extension/WatchState.swift` | +230 / -63 | `HKAnchoredObjectQuery` replacing `HKSampleQuery`; anchor lifecycle; epoch guard; trend/delta derivation via `hkTrendString(fromDeltaMgDl:)`; `fire_id` threading; updated log taxonomy |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | +49 | 6 persistence methods (`hkGlucoseAnchor`, `saveHKGlucoseAnchor`, `hkLastReceivedGlucoseEpoch`, `setHKLastReceivedGlucoseEpoch`, `hkLastReceivedGlucoseValueMgDl`, `setHKLastReceivedGlucoseValueMgDl`); storage keys |

**What was implemented:**

1. **Anchored query:** `HKSampleQuery` (fetch last 2, stateless) replaced with `HKAnchoredObjectQuery` (fetch since last anchor, stateful). Anchor loaded from `TrioComplicationDataStore` on each observer fire; nil anchor falls back to 24h date cap. Anchor saved after every successful query regardless of outcome.

2. **Epoch guard:** Post-query check — if latest returned sample's epoch matches persisted last-received epoch, anchor is saved but no snapshot/persistence update occurs. Logs `hk_observer_skipped_known_epoch`.

3. **Phantom fire classification:** Zero new samples from anchored query logs `hk_observer_no_new_samples` (vs R6 which logged `hk_observer_fired` for all fires uniformly).

4. **Trend derivation:** `hkTrendString(fromDeltaMgDl:)` implements the same integer threshold mapping as `BloodGlucose.Direction.init(trend:)`:
   - `<= -30` → `DoubleDown`, `-29..-20` → `SingleDown`, `-19..-10` → `FortyFiveDown`
   - `-9..<10` → `Flat`
   - `10..<20` → `FortyFiveUp`, `20..<30` → `SingleUp`, `>= 30` → `DoubleUp`
   - Plausibility gate: only derived when `0 < timeDelta < 15 min`

5. **Delta derivation:** Raw numeric delta (`latestMgDl - previousMgDl`) rounded once to integer. Previous sample from batch (2+ samples) or persisted previous value/epoch (single-sample steady-state). Derive-then-persist ordering enforced.

6. **Persistence in `TrioComplicationDataStore`:** All six methods use App Group `UserDefaults` with dedicated keys. Anchor serialized via `NSKeyedArchiver`/`NSKeyedUnarchiver` (`NSSecureCoding`). No raw `UserDefaults(suiteName:)` usage from `WatchState`.

7. **Log taxonomy update:** `hk_observer_fired` gains `fire_id`, `sync_lag` (renamed from `save_age`), `trend`, `trend_derived`, `samples_in_batch`, `query_type=anchoredQuery`. New events: `hk_observer_no_new_samples`, `hk_observer_skipped_known_epoch`, `hk_observer_nil_anchor`, `hk_anchor_decode_failed`.

**Source predicate (deviation from spec):** SyncIdentifier predicate was specified in the design but not applied in the implementation. Current query uses nil predicate when anchor exists, 24h date cap when anchor is nil. Source filtering deferred to R6.2.

**Delta/trend fix (v1.49 changelog):** During review, derivation was corrected to compute raw numeric delta first then round once — avoids endpoint-rounding differences at threshold boundaries.

**Post-review corrections (v1.50–v1.51):** R5c attribution fix (shared boolean replaced with threaded `fromUserInfo` parameter) and R5b inner-payload verification were applied in the same commit. See [observability implementation log](../observability/observability-implementation-log.md) for R5b/R5c details.

---

## Changelog

### v1.0 (2026-03-19 11:33 CET)
- Initial version. Reconstructed from commit `44d7a7579`, remediation plan changelog v1.49–v1.51, and alternative-delivery implementation plan Step 7.1 during docs reorganization.
