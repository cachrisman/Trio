# Remediation Plan — Full Changelog Archive

> This is the full version history of the remediation plan (complication-freshness-remediation-plan.md) through v1.56. Archived during docs reorganization (2026-03-19). For the current design docs, see the group subfolders under `docs/in-progress/complication-freshness/`.

---

## Changelog

### v1.56 — 2026-03-18 22:38 CET | Validation Protocol table consistency, changelog precision

- **Validation Protocol table R4 row updated:** Previously listed only `save_age` with `p90 < 300s` pass criteria. Now matches the fuller §R4 validation section: requires correlation of three signals (iOS `context_succeeded`, watch `didReceiveApplicationContext`, `save_age` improvement); pass requires all three present; falsification criteria include both receive failure and send absence cases; explicit note that freshness alone is suggestive but not sufficient.
- **v1.55 changelog wording tightened:** R5d logging fix entry now precisely names the three corrected log calls rather than using "adjacent handlers."

### v1.55 — 2026-03-18 22:21 CET | R4 validation, readiness ordering, prerequisites, R5d logging fixes

- **R4 validation strengthened:** Pass criteria now require correlation across three signals: iOS `context_succeeded`, watch `didReceiveApplicationContext` receipt, and `save_age` improvement. Freshness improvement alone is explicitly stated as suggestive but not sufficient. Falsification criteria expanded.
- **iOS-side readiness-first ordering:** `sessionIsReadyForTransfer()` guard moved before `budgetExhausted` / `queueDeep` computation. Session properties are now read only after readiness is confirmed, consistent with existing transfer paths. Added explanatory note.
- **App Group persistence prerequisite added:** Explicit note in R4 architecture section that R4 depends on `TrioComplicationDataStore` save path (FP-Phase 3.0/3.1) being healthy and stable.
- **R4 status wording updated:** Removed stale "after the R6 48h observation window concludes" language. Status now reflects current state: next PR to implement, all gates passed.
- **R5d watch-side logging fixed:** In the §R5d code samples, corrected the `sleep_gap_detected` log in `didReceiveUserInfo` and both log calls (`didReceiveApplicationContext` entry log and `sleep_gap_detected_context`) in the integrated `didReceiveApplicationContext` handler from `debug(.watchManager, ...)` to `Task { await WatchLogger.shared.log(...) }`. These are watch-side (`WatchState.swift`) code blocks; `debug(.watchManager, ...)` is iOS-side only.

### v1.54 — 2026-03-18 22:08 CET | R4 pre-implementation audit — stale line numbers, logging pattern, consistency fixes

- **R4b line numbers updated:** `sessionReachabilityDidChange` is at line 612 (ends ~631) in current `WatchState.swift`, not ~403 as originally documented (line numbers drifted after R6/R6.1/R5 implementations shifted watch-side code). Updated R4b section and v1.9 changelog entry.
- **Watch-side logging pattern corrected:** Standalone R4 handler in §R4 now uses `Task { await WatchLogger.shared.log(...) }` instead of `debug(.watchManager, ...)`. The `debug(.watchManager, ...)` pattern is iOS-side only (`AppleWatchManager.swift`); `WatchState.swift` uses `WatchLogger.shared.log(...)`. Added explicit warning note below the handler code.
- **MARK line number updated:** `// MARK: - WCSessionDelegate` is at line 422, not 202.

### v1.53 — 2026-03-17 | Step 4 gate evaluated — R2d skipped; proceeding to Step 5

- **Avg C analysis run** against BetterStack build ≥ 137 data (S3 + hot, 2026-03-12 onward). Build 141 data (Mar 16–17): avg C 1.06 / 0.98 overall; 0.77 / 0.34 in budget-ok windows. Both well below the 1.3 gate threshold.
- **Step 4 (R2d) skipped.** Gate criterion not triggered. Implementation log entry added with full per-day table (transfers, readings, path breakdown, budget-ok avg C).
- **Next step: Step 5 (R4 — `updateApplicationContext` safety net).** No code change in this version.

### v1.52 — 2026-03-16 | Build 141 deployed (patch 09 + docs)

- **Build 141 built and deployed.** Includes patch 09 (watch-complication-improvements) with post-review R5c attribution and R5b verification corrections (R6.1, R5f, delta/trend fix, R5c follow-up cleanups).
- **Docs and patch committed to dev:** Remediation plan v1.52, implementation guide v1.37, and `patches/09-watch-complication-improvements.patch` committed together on `dev`.

### v1.51 — 2026-03-15 | R5c post-review follow-up (ChatGPT + Claude)

- **Review context:** After the v1.50 R5c attribution fix (fromUserInfo + work-item capture), two follow-up reviews (ChatGPT, then Claude) evaluated the implementation.
- **ChatGPT:** Confirmed the fix addresses the main attribution flaw (epoch from payload, timestamp threaded through the path). Requested two cleanups: (1) Remove the fallback `userInfoReceiveTimestamp ?? lastUserInfoReceiveTimestamp` so that when `fromUserInfo` is true we use only the threaded timestamp — avoids reintroducing ambiguity if a path ever reaches saveComplicationSnapshot with `fromUserInfo == true` but nil timestamp. (2) Remove the unused `lastUserInfoReadingEpoch` property and its assignment; dead attribution state can confuse future edits. Both applied.
- **Claude:** Confirmed (1) capture of `receiveTs` outside the DispatchWorkItem at creation time is correct; (2) `reading_epoch` from the payload being saved is the right fix. Noted the fallback would re-introduce a shared-state read in the unexpected-nil case; by then the fallback had already been removed per ChatGPT. Noted unconditional `lastUserInfoReceiveTimestamp = nil` when `fromUserInfo` is correct (cleans up even when no timestamp available). Confirmed R5b/R5f/R6.1 live in other files; a diff that only touches WatchState for R5c is expected.
- **§R5c "As implemented (post-review)":** Expanded to describe threading of `userInfoReceiveTimestamp`, epoch from payload, no fallback, removal of `lastUserInfoReadingEpoch`, and capture of `receiveTs` outside the work item. Added one-sentence reference to ChatGPT + Claude follow-up.

### v1.50 — 2026-03-15 | Post-review R5c attribution and R5b verification

- **Review context:** Implementation (R6.1, R5f, R5c, R5b, delta/trend fix) was reviewed; docs (remediation plan v1.49, implementation guide v1.34) were accepted. Two code corrections were required before considering the implementation ready.
- **R5c (major):** Attribution was originally implemented with a shared boolean `userInfoTriggeredThisFinalize` set/cleared by didReceiveUserInfo and didReceiveMessage. In mixed traffic, the path that last touched the flag could differ from the payload actually being finalized, producing wrong or missing `userInfo_decoded` logs. **Fix:** Attribution now rides with the work item. `scheduleUIUpdate(with:fromUserInfo:)` and `finalizePendingData(fromUserInfo:)` take a `fromUserInfo` parameter; the userInfo path (including the quiet-window work item) passes `true`, the sendMessage path passes `false`; the debounced work item captures the value and passes it through. No shared flag is used for R5c attribution.
- **R5b (near-blocker):** Reviewer requested verification that the watch-side R5b log reads `readingEpoch` from the **inner** watch-state payload (the value of `WatchMessageKeys.watchState`), not the outer sendMessage envelope. **Verified:** We only enter the R5b block after extracting `watchStateDict = message[WatchMessageKeys.watchState]`; that is the inner payload matching iPhone's `fullMessage`. A code comment was added in `WatchState.swift` documenting this for R5b end-to-end timing.
- **§R5b / §R5c:** Added "As implemented (post-review)" paragraphs summarizing the above so future implementers and reviewers see the final design.

### v1.49 — 2026-03-15 | R6.1 delta/trend correctness + source-predicate doc accuracy

- **R6.1 delta/trend fix:** Derivation now computes raw numeric delta first (`latestMgDl - previousMgDl`), then rounds once to obtain the integer used for both trend classification and display delta string. This matches the documented intent and avoids endpoint-rounding differences at threshold boundaries (display, trend bucket, dedup). No change to fallback behavior, plausibility gate, or threshold mapping.
- **Source-predicate doc accuracy:** §Source Predicate Decision now includes an "As implemented" paragraph: R6.1 shipped without the SyncIdentifier predicate; implementation uses 24h date cap when anchor is nil and nil predicate when anchor exists; SyncIdentifier/source filtering deferred to R6.2. §Delta and Trend Derivation "Numeric delta" bullet updated to specify raw-delta-first-then-round-once semantics.

### v1.48 — 2026-03-15 | R6.1 + R5f + R5c + R5b implementation complete

- **R6.1 implemented:** HealthKit fetch path replaced with `HKAnchoredObjectQuery`; anchor, last-received epoch, and previous glucose value persisted in `TrioComplicationDataStore`; derive-then-persist ordering; trend/delta from integer thresholds (raw direction strings); R6.1 log taxonomy and `fire_id`; `low_power_mode` on `hk_background_delivery_registered`. **Deviation:** SyncIdentifier presence predicate not applied (no `predicateForObjects(withMetadataKey:)` single-param API on watchOS); nil anchor uses 24h date cap only; predicate refinement deferred to R6.2.
- **R5f implemented:** `event=complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds` and `data_age_seconds`; new `event=complication_get_snapshot_called` with `get_snapshot_at_epoch_seconds` and `data_age_seconds`; data age from snapshot actually used on each path; sentinel `-1` for invalid reading date.
- **R5c implemented:** `didReceiveUserInfo` sets receive timestamp; `saveComplicationSnapshot(from:fromUserInfo:)` logs `userInfo_decoded reading_epoch= decode_ms=` when `fromUserInfo` and timestamp set; `processRawDataForWatchState` calls with `fromUserInfo: true`.
- **R5b implemented:** iPhone `sendMessage` path logs `sendMessage_sent reading_epoch= send_wall=`; watch `didReceiveMessage` logs `didReceiveMessage reading_epoch= receive_wall=`.

### v1.47 — 2026-03-15 | R5f expanded: timeline + snapshot WidgetKit entry-path logging

- **R5f expanded from timeline-only to both WidgetKit entry paths:** R5f now specifies observability for both `getTimeline` and `getSnapshot`. The complication can render fresh data from either path; getTimeline-only logging does not reconstruct full visible recency.
- **New `event=complication_get_snapshot_called` added to spec:** Fields `get_snapshot_at_epoch_seconds` and `data_age_seconds` (same semantics as timeline path — snapshot actually used to build the entry on that path; sentinel for invalid reading date).
- **Better Stack sawtooth guidance corrected:** getTimeline-only chart is described as timeline-refresh / timeline-recency sawtooth, not full visible-recency; snapshot logging is needed to reconcile "face shows NOW without logged getTimeline"; both events support visible-recency analysis in Explore. Scope boundary and chart naming/interpretation note added.

### v1.46 — 2026-03-15 | getTimeline visible-recency logging (R6.1 enhancement)

- **`event=complication_get_timeline_called` now includes `get_timeline_at_epoch_seconds`:** Unix epoch when getTimeline was invoked/logged; supports reconstructing recency between calls.
- **`event=complication_get_timeline_called` now includes `data_age_seconds`:** Age of the snapshot actually used to build the timeline (complication-extension / getTimeline fields only, not HealthKit observer). Enables visible recency at getTimeline time and sawtooth reconstruction in Better Stack Explore.
- **§R5f expanded:** Visible recency fields, rationale (directly queryable, avoids save/reload inference, reflects user-visible recency), scope (observability only; no behavior change), and limitation (Explore today; dashboards may not support as-of natively) added. R5f-getTimeline impact updated to reference the new fields.

### v1.45 — 2026-03-15 | 3-pass adversarial review — correctness fixes, stale sequencing, orphaned fields

**Summary:** Three-pass structured review correcting factual errors that were documented in deviation notes or code review tables but never backported to the normative sections of the plan, plus clearing stale sequencing language left over before build 140 changed the actual ship order.

**Correctness fixes in normative code (blocked an implementer or would trigger a repeated compile/deploy failure):**

- **R6c code — `SortDescriptor` compile error:** The code block used `SortDescriptor(\.startDate, order: .reverse)` as the primary form. `HKSampleQuery` requires `[NSSortDescriptor]?`; Swift `SortDescriptor` does not bridge to it and will not compile. Replaced with `NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)` with explanatory comment. (This was the actual cause of the build 140 compile issue, fixed in deviation — but normative code was never corrected.)
- **R6c code — `.milligramsPerDeciliter()` unavailable on watchOS:** Both `HKSampleQuery` result extraction calls used this LoopKit extension. Replaced with `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))` inline in both places (latest and previous sample). Comment added. The architecture table ("What's Available in HealthKit") Notes column was also corrected.
- **R6b code — `guard let self` missing (CR2):** The normative `setupGlucoseObserverQuery` code used `self?.fetchLatestGlucoseFromHealthKit(completionHandler:)`. If `self` is nil, `completionHandler()` is never called — the system throttles future background delivery. CR2 (required fix) documented this, and the CR table in the implementation guide showed it as "Fixed." But the normative plan code was never updated. Replaced with explicit `guard let self else { completionHandler(); return }` pattern with explanatory comment.

**Correctness fixes in normative text:**

- **`NSHealthUpdateUsageDescription` (§R6 Entitlement requirements, Risks table):** Both locations stated this key "is not required" because `toShare: nil`. Build 140 confirmed Apple's altool rejects uploads when the HealthKit entitlement is present but this key is absent, regardless of `toShare: nil` (ITMS-90683). Corrected in §Entitlement section and Risks table to "required by App Store Connect validation." Historical "Fixed in v1.34/v1.35" markers updated to reflect confirmed behavior.
- **R6a placement (§Watch Side Implementation):** Stated "Place in `WatchState.init()` or `setupSession()` (where `WCSession.activate()` already runs)." This description implies placement inside the `if WCSession.isSupported()` block — which CR1 explicitly required it to be **outside**. Corrected: "Place at the **end of `setupSession()`**, **outside** the `if WCSession.isSupported()` block" with rationale.
- **R4 watch-side handler — R5d dependency (§R4 watch app extension side):** Simplified handler shown without note that the full handler (with `lastDataReceivedAt` and `forceWidgetReloadIfStale`) requires R5d. Added labelled "standalone R4 handler" clarification and cross-reference to §R5d for the R5d-integrated version.

**Orphaned field fix (§R6.1 Updated Log Taxonomy):**

- **`hk_background_delivery_registered` `low_power_mode=Bool`:** R6.1 taxonomy changed this field from `success=Bool` to `low_power_mode=Bool` with no implementation path, no source API, and no explanation of why `success` was dropped. An implementer had no way to know what `low_power_mode` was or how to produce it. Resolved: both `success=Bool` and `low_power_mode=Bool` now specified; `low_power_mode` source documented as `ProcessInfo.processInfo.isLowPowerModeEnabled`; logging behavior for `success=false` case documented (⚠️ prefix).

**Stale sequencing and status language:**

- **§R6 "Recommended sequencing" paragraph:** Was written as live present-tense advice ("Go straight to R6…Ship R6 first") for a decision already made. Recast as historical rationale paragraph reflecting the actual outcome (R6 shipped build 140 before R4).
- **§R6 Decision Gate:** "Ship R6 after R4" was the original recommendation; actual order was reversed. Rewritten to document actual ship order and direct readers to §Implementation Sequence for current status.
- **§Implementation Sequence diagram:** Fully updated to reflect current state — R1–R6 all annotated with build numbers and ✅ status; R4, R5b/c/d, and R6.1 annotated as PENDING with rationale for ordering.
- **§R4 header:** "can ship after R6 or bundle with R6 in same PR" — R6 has shipped. Replaced with current status: "PENDING — ship R4 as next PR after R6 48h observation window concludes."
- **§R6 Risks table — trend derivation row:** "add delta-based trend derivation in R6.1 if user feedback requests it" (×2). Replaced with "see R6.1 (spec complete — see §R6.1)" since R6.1 is now planned independently of user feedback.
- **§R6 Trend derivation options — option 3:** Same "if user feedback requests it" language corrected to "spec complete — see §R6.1, ready for implementation."

### v1.44 — 2026-03-15 | R6.1 delta/trend derivation clarity — numeric vs display, threshold input, fallback, scope boundary

- **Section renamed:** "Trend Derivation" → "Delta and Trend Derivation" to reflect that the section covers both delta and trend.
- **Numeric vs display delta clarified:** "Delta computation" renamed to "Numeric delta" with explicit statement that the single integer mg/dL delta serves both trend classification and display-string formatting. New "Display delta formatting" bullet specifies how `TrioComplicationSnapshot.delta` is produced from the same numeric delta.
- **Shared previous-sample constraint:** Input bullet now explicitly requires that delta and trend use the same selected previous sample on a given fire.
- **Threshold input clarified:** Threshold mapping bullet now explicitly states the integer delta is applied directly — no separate floating-point threshold system in R6.1.
- **Fallback expanded:** Fallback bullet now covers both trend and delta (not just trend). Explicitly states both fall back when the plausibility gate fails, regardless of batch vs persisted previous-sample source.
- **Derivation scope boundary added:** New paragraph after the inherited unit note explicitly documenting that R6.1 only derives `delta` and `trend`; `glucoseColor`, `state`, mmol/L parity, and `sync_lag` in display/dedup/trend are intentionally out of scope.

### v1.43 — 2026-03-15 | R6.1 taxonomy fix — `fire_id` on `hk_observer_error`

- **`hk_observer_error` now includes `fire_id`:** Added `fire_id=UUID` to the R6.1 `hk_observer_error` event fields for consistency with all other observer-callback events. Per the spec, `fire_id` is generated at the start of each observer callback before error checking, so it is available on this path.

### v1.42 — 2026-03-15 | R6.1 final polish — backfill validation, Anchor Lifecycle clarity

- **Backfill validation tightened:** Anchored-query correctness pass condition now explicitly requires verifying that the saved snapshot uses the sample with the greatest `startDate` in backfill batches, not just that a single save occurred.
- **Anchor Lifecycle "Normal operation" row tightened:** Replaced vague "saved after processing" wording with a cross-reference to the detailed anchor advancement, epoch/value persistence, and snapshot save rules in subsequent rows.

### v1.41 — 2026-03-15 | Better Stack avg C metrics — complication_c_total_transfers (sum only), chart formula

- **Avg C metrics section completed:** Documented that `complication_c_total_transfers` uses **sum** aggregation only. Dashboard chart formula added: `sumMerge(complication_c_total_transfers_sum) * 1.0 / nullIf(uniqMerge(complication_c_readings_uniq), 0)` per bucket. Extraction rule label clarified to "aggregation: **sum**".

### v1.39 — 2026-03-15 | R6.1 spec polish — derive-then-persist ordering, startDate qualifiers, source-predicate validation

- **Trend Derivation `startDate` qualifier added:** Input line now explicitly says "Latest sample by `startDate`" and "second-most-recent by `startDate` in batch," matching the Design section's sort requirement. Prevents ambiguity for readers entering the Trend Derivation section directly.
- **Derive-then-persist ordering clarified:** TrioComplicationDataStore Additions section now explicitly states that delta/trend must be derived from the persisted previous epoch/value *before* the current sample's epoch/value are persisted. Prevents an implementer from accidentally overwriting the previous-sample state before derivation.
- **Source-predicate over-inclusion validation note added:** Validation Approach section now includes guidance that anomalous delta/trend values in multi-app setups should be considered as possible source-predicate over-inclusion symptoms before treating them as implementation bugs. Known R6.1 tradeoff; value-specific refinement deferred to R6.2.

### v1.38 — 2026-03-14 | R6.1 spec tightening — anchor advancement, field rename, sample ordering, trend observability

- **Anchor advancement on non-save exits clarified:** Anchor Lifecycle table restructured — "Successful anchor advancement" renamed to "Anchor advancement rule" covering all successful-query paths. Anchor is always saved after a non-error query (including no-new-samples and epoch-guard-skip exits), but epoch/value are only updated when a genuinely new sample is processed. Query errors and pre-query guard failures do not advance the anchor. Design section "Persist query anchor" bullet updated to match.
- **`save_age` → `sync_lag` field rename documented:** R6 uses `save_age` on `hk_observer_fired`; R6.1 renames to `sync_lag`. Added explicit note in Updated Log Taxonomy section with BetterStack query guidance for cross-build queries.
- **Anchored-query sample ordering requirement specified:** Design section now states that latest/previous sample must be determined by sorting `addedObjects` by `startDate`, not by relying on raw array order. Store-insertion order is not guaranteed chronological during backfill, sync catch-up, or retroactive delivery.
- **`trend=String` field added to `hk_observer_fired` log taxonomy:** R6.1 logs the actual derived direction string alongside `trend_derived=Bool`, enabling validation of threshold mapping correctness and WC/HK format alignment in BetterStack.
- **Latency-domain wording tightened:** `sync_lag` description now notes it includes watch-side observer/query processing time, not just transit. Post-log processing estimation reworded to acknowledge watch-side logs cannot fully decompose latency into separate buckets.
- **Validation approach wording softened:** Phantom fire rate and trend coverage pass conditions changed from specific percentage thresholds to directional expectations. Trend coverage now includes `trend` value validation.

### v1.37 — 2026-03-14 | R6.1 spec review fixes — previous-sample persistence, trend format, epoch ordering

- **Previous-sample persistence added:** `hkLastReceivedGlucoseValueMgDl()` and `setHKLastReceivedGlucoseValueMgDl(_:)` added to `TrioComplicationDataStore` planned methods (now 6 total). Design section updated to explain how persisted previous glucose value/epoch enables delta/trend derivation for the common steady-state single-sample anchored-query case.
- **Trend output format specified:** R6.1 must produce raw direction strings (`"Flat"`, `"SingleUp"`, etc.) matching the WC path format, not symbol glyphs. Aligns with existing `TrendSymbolMapper.symbol(from:)` and enables `shouldUpdate` dedup to correctly identify same-reading dual delivery.
- **Trend derivation changed from mg/dL/min rate to raw-delta threshold mapping:** Now uses the same `Int` delta thresholds as `BloodGlucose.Direction.init(trend:)` (<=−30 DoubleDown through >=30 DoubleUp). Threshold table added to spec. Note added that the switch statement may need duplication or extraction for the watchOS target.
- **Epoch-guard ordering corrected:** Changed from "checked before executing the anchored query" to "post-query filter applied to returned results." Clarified that this is an edge-case filter for modified/re-delivered samples, not the primary incremental mechanism.
- **Anchor serialization specified:** `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:)` / `NSKeyedUnarchiver.unarchivedObject(ofClass:from:)` — `HKQueryAnchor` is `NSSecureCoding`, not `Codable`. References LoopKit `PersistenceController` pattern.
- **Deletion handling added:** Anchor Lifecycle table now explicitly states deleted objects from `HKAnchoredObjectQuery` are ignored; modified/re-delivered samples caught by epoch guard.
- **Source-predicate risk language tightened:** `HKMetadataKeySyncIdentifier` described as a standard Apple key used by multiple diabetes apps, not a Trio-specific key. Over-inclusion risk upgraded to practical, not theoretical. Severity raised to Low–Medium.
- **Dual-delivery dedup benefit noted:** WC healthy + HK healthy scenario updated to explain that matching raw direction strings can prevent the R6 trend-overwrite regression via `shouldUpdate` returning `false`.
- **`fire_id` lifecycle clarified:** Generated once per observer callback; threaded through all subordinate functions; not regenerated per helper or save.
- **Inherited unit-consistency note added:** HK delta is mg/dL-only; WC may format as mmol/L; affects dedup for mmol/L users. Deferred unless separately scoped.

### v1.36 — 2026-03-14 | R6.1 HealthKit channel improvements spec added

- **R6.1 section added:** New `## R6.1 — HealthKit Channel Improvements` section with full planning/specification material for the follow-on HealthKit channel refinement. R6 remains shipped in build 140; R6.1 is spec complete and ready for implementation.
- **Anchored-query design specified:** Planned replacement of R6's `HKSampleQuery` fetch path with `HKAnchoredObjectQuery` — incremental fetch, persisted anchor, persisted last-received epoch, fast exit on known-epoch fires.
- **Anchor/epoch persistence location specified:** Four new methods planned for `TrioComplicationDataStore` (`hkGlucoseAnchor`, `saveHKGlucoseAnchor`, `hkLastReceivedGlucoseEpoch`, `setHKLastReceivedGlucoseEpoch`). Raw `UserDefaults(suiteName:)` in `WatchState` explicitly forbidden for this feature.
- **Source predicate decision recorded:** `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)` selected; rationale and residual risk documented.
- **Trend derivation specified:** Latest + previous sample, mg/dL/min rate, 15-minute gate, blank fallback when gate fails.
- **Log taxonomy expanded:** 11 R6.1 events specified with fields; 2 R6-only events identified for replacement; `query_type=anchoredQuery` as the R6/R6.1 discriminator.
- **Latency domains callout added:** Three-domain breakdown (iPhone write, cross-device sync, app processing) with explicit note that `sync_lag` does not isolate Apple sync latency.
- **R6.1 risks table added:** Anchor decode failure, source predicate over-inclusion, trend false confidence, log complexity.
- **Validation approach added:** Phantom fire rate, trend coverage, anchored-query correctness, known-epoch skip, no duplicate save explosion.
- **WC failure mode scenarios added:** Four scenarios showing R6.1 behavior when WC is healthy, degraded, or absent.
- **Backlog table updated:** R6.1 row added (planned — spec complete, ready for implementation).

### v1.35 — 2026-03-14 | R6 shipped (build 140) + NSHealthUpdateUsageDescription remediation

- **R6 shipped and live:** Build 140 deployed to TestFlight. `hk_background_delivery_registered success=true` confirmed at 15:45:19 UTC; `hk_observer_fired` events confirmed (glucose=110/111, delta computed correctly). HealthKit background delivery is operational on the watch.
- **Unplanned remediation — `NSHealthUpdateUsageDescription`:** Apple App Store Connect validation (altool) rejected the build 139 upload with error ITMS-90683: "Missing purpose string in Info.plist" for `NSHealthUpdateUsageDescription`. Despite `toShare: nil` (no write access requested), Apple requires both `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` whenever the `com.apple.developer.healthkit` entitlement is present. This is a blanket validation requirement, not tied to actual API usage. **Fix:** Added `NSHealthUpdateUsageDescription` to `Trio Watch App/Info.plist`: "Trio may save blood glucose readings to Apple Health to keep your health data synchronized." The v1.34 statement that `NSHealthUpdateUsageDescription` is "not needed" was correct at the code level but incorrect for App Store submission.
- **Unplanned remediation — `HKUnit.milligramsPerDeciliter` unavailable on watchOS:** Build failed with `type 'HKUnit' has no member 'milligramsPerDeciliter'`. This is a custom extension in `LoopKit/MockKitUI` which is linked to the iOS app but not the watchOS target. **Fix:** Replaced with inline construction: `HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`.
- **Status line:** Updated to reflect R6 shipped.
- **Backlog table:** HealthKit row updated to ✅ Shipped.

### v1.34 — 2026-03-14 | R6 blocker fix: NSHealthShareUsageDescription for watch app

- **Blocker found (Cursor code review, confirmed by ChatGPT + Claude):** `Trio Watch App/Info.plist` was missing `NSHealthShareUsageDescription`. The watch app calls `requestAuthorization(toShare: nil, read:)` — Apple requires the read usage description in the requesting process's Info.plist. Without it, authorization may crash the watch app on launch or fail silently. Since `setupHealthKitBackgroundDelivery()` runs from `init()` → `setupSession()` on every launch, this was a high-risk failure mode for the entire watch app.
- **Fix:** Added `NSHealthShareUsageDescription` to `Trio Watch App/Info.plist` with user-facing string: "Trio reads your blood glucose data to keep the watch complication current when wireless sync is unavailable." The "when wireless sync is unavailable" clause explains why the watch needs HealthKit specifically (backup channel, not primary).
- **Not needed (at code level):** `NSHealthUpdateUsageDescription` — `toShare: nil` means no write access is requested. However, Apple App Store Connect validation requires `NSHealthUpdateUsageDescription` in Info.plist whenever the HealthKit entitlement is present, regardless of whether the app actually writes. See v1.35.
- **Entitlement and Info.plist Requirements section:** Renamed from "Entitlement Requirements"; added privacy usage description subsection with rationale, XML block, and explicit note that `NSHealthUpdateUsageDescription` is not needed.
- **Risks table:** Added `NSHealthShareUsageDescription` missing row (Blocker, fixed in v1.34).

### v1.32 — 2026-03-14 | Step 7 implementation — code review (ChatGPT round 1 + 2)

- **CR1:** HK setup must not be inside `if WCSession.isSupported()` — R6 is an independent wake path. Call `setupHealthKitBackgroundDelivery()` outside that block. Implemented in WatchState.
- **CR2:** In `HKObserverQuery` update handler, if `self` is nil, `completionHandler()` was never called. Add `guard let self else { completionHandler(); return }`. Implemented.
- **CR3/CR4:** Log sample query errors and zero samples; log `success=false` for background delivery distinctly. Implemented.
- **CR5 (ChatGPT round 2):** completionHandler() was called via defer when the HKSampleQuery closure exited, but the save runs in DispatchQueue.main.async — system was told "done" before save ran. Call completionHandler() inside the main.async block after save. R6d section updated; implementation guide v1.18 CR5 + prompt updated.
- **Sanity checks (ChatGPT round 3):** (1) TrioComplicationDataStore.save() uses onMain(); when caller is already on main, onMain runs the block synchronously — no extra async hop; completionHandler() after save is correct. (2) WatchState is singleton (static let shared); no duplicate HK setup. See implementation guide Step 7 sanity-checks table.

### v1.33 — 2026-03-14 | Step 7 sanity checks (ChatGPT round 3) — doc

- Version bump; sanity-check verification (save synchronous on main, WatchState singleton) already noted in v1.32 changelog. Implementation guide v1.19 adds Step 7 sanity-checks table.

### v1.31 — 2026-03-14 | R6 pre-implementation fixes (entitlements, weak self, SortDescriptor)

- **Entitlement Requirements:** HealthKit already enabled on watch extension App ID in Apple Developer portal. Table updated: both keys now ✅ "Already present in provisioning profile"; note changed to "Entitlements file addition only required — no provisioning profile update needed." Removed "must update provisioning profile" language.
- **Risks table:** HealthKit row updated to state provisioning profile already has HealthKit; only entitlements file must be added.
- **R6a code block:** Added `[weak self]` and `guard let self else { return }` in `requestAuthorization` callback to avoid strong capture in async callback.
- **R6c code block:** Replaced deprecated `NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)` with `SortDescriptor(\.startDate, order: .reverse)` in `HKSampleQuery`; removed `sort` variable.

### v1.30 — 2026-03-14 | Step 5/R4 and Step 7/R6 mapping + sequencing

- **Step ↔ Plan mapping:** Added to Naming Convention: Step 5 = R4 (applicationContext safety net), Step 7 = R6 (HealthKit background delivery).
- **R4 (Step 5):** Heading now includes "(Step 5)". Recommended line updated: can ship after R6 or bundle with R6 in same PR; noted complementary files (AppleWatchManager vs WatchState).
- **R6 (Step 7):** Heading now includes "(Step 7)". Replaced "Prerequisite: R4 must be shipped first" with **Recommended sequencing: go straight to R6.** Rationale: R4 would have done nothing for the 24-minute gap (data already in App Group, WidgetKit not calling getTimeline; R4 still ends with reloadTimelines WidgetKit can ignore). R6 gives independent system-triggered wake when new glucose arrives; e.g. during 9-min gap, R6 would have fired from 05:37 reading. R4 still valuable for budget exhaustion but lower urgency. Ship R6 first; R4 after R6 or bundle both.

### v1.29 — 2026-03-14 | R6 dedup accuracy + stale conditional language

- **Dedup and Dual-Delivery Behavior:** Rewrote section for accuracy against actual code. The prior version claimed "the second delivery is rejected as a duplicate" which was incorrect — `shouldUpdate` compares `trend` and the HK snapshot's `trend=""` differs from WC's real trend, so `shouldUpdate` returns `true` and both writes are accepted. New section documents: (a) the HK snapshot overwrites WC's trend arrow in normal dual-delivery operation, (b) this is transient and acceptable (glucose+delta correct, trend restored on next WC delivery), (c) the overwrite's `coalescedReloadOnMain` call fires because 10–60s HealthKit sync latency exceeds the 5s debounce, (d) in target scenarios (exhaustion, WidgetKit gaps) there is no overwrite because WC is not delivering.
- **Risks table:** Added "Trend arrow overwrite in normal operation" (Low severity).
- **Backlog table row:** Updated from "gated on R4 post-deploy data" to "ship after R4; see §R6" — consistent with v1.27 decision gate broadening.
- **Implementation sequence arrow:** Changed from "if p90 complication_age > 300s in exhaustion windows after 48h" to "observe 48h, then ship R6" — consistent with v1.27 decision gate broadening.

---

### v1.28 — 2026-03-14 | R6 nit fixes (naming, entitlement)

- **Naming convention:** Fixed `R1`–`R5` → `R1`–`R6` in the naming convention line and annotated the initial-draft changelog entries. The naming convention table was already updated in v1.26 but the prose reference was missed.
- **`healthkit.access` entitlement:** Not referenced in the remediation plan (only in the implementation guide). Noted here for cross-reference: the guide's XML block and Cursor prompt incorrectly included `com.apple.developer.healthkit.access` (empty array). This entitlement is for sensitive HealthKit capability types and is not needed for reading `.bloodGlucose`. Removed in guide v1.14.

---

### v1.27 — 2026-03-14 | R6 decision gate broadened

- **R6 decision gate:** Broadened from "ship only if budget-exhaustion staleness persists" to "ship after R4 — addresses two distinct failure modes." Added WidgetKit scheduling gap as co-equal motivation (observed in build 139: 9-min gap with fresh App Group data, `reload_age=548s`). The `HKObserverQuery` wake trigger fires when new glucose data arrives in HealthKit, providing an independent opportunity to call `reloadTimelines` outside of WidgetKit's own scheduling.
- **Prerequisite:** Updated to describe both failure modes explicitly (budget exhaustion + WidgetKit scheduling gaps). Removed "motivated only if" conditional language.
- **Validation:** Pass conditions split into two categories (budget exhaustion: `save_age` p90 < 300s in exhaustion windows; WidgetKit gaps: `reload_age` p90 < 300s overall). Validation Protocol table row updated.

---

### v1.26 — 2026-03-14 | R6 HealthKit Background Delivery

- **R6 section added:** New remediation phase — HealthKit background delivery as an independent complication update channel on watchOS, completely outside WatchConnectivity.
- **Codebase audit results embedded:** iPhone-side HealthKit writes confirmed in `HealthKitManager.swift` line 205 (`.bloodGlucose`, `.milligramsPerDeciliter`, no trend/delta metadata). Watch extension and complication confirmed to have zero HealthKit references. Entitlements audit: watch extension missing both `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` (blocker). Main app has both.
- **Architecture:** `HKObserverQuery` + `enableBackgroundDelivery` on watch → sample fetch → `TrioComplicationSnapshot` construction → existing `TrioComplicationDataStore.shared.save()` path. Delta derived from last 2 samples; trend set to `""` initially (derivation deferred to R6.1).
- **Dedup:** `saveOnMain` (FP-Phase 3.1) handles dual-channel dedup automatically — no new dedup logic needed.
- **Naming convention:** Updated R-namespace to R1–R6. Implementation Sequence, Validation Protocol, and Backlog tables updated.

---

### v1.25 — 2026-03-13 | Logging fixes context for Step 4 gate

- **Status:** Updated to reflect builds 137-138 deployment with cloud logging pipeline fixes. Step 3b is now deployed and observable with accurate build attribution.
- **Step 3b section:** Added "Logging pipeline fixes" paragraph documenting the build-mislabeling fix and its impact on avg C measurement reliability. The 48h observation window for the Step 4 decision gate effectively starts from build 137 deployment (2026-03-12), since prior data had inaccurate build attribution.
- **Step 4 gating criteria:** avg C query must filter to build >= 137 with `dt` after build 137 deploy time. The `[b:BUILD]` token embedded in log lines by builds 137+ ensures accurate per-build attribution.
- **Cross-reference:** Logging fixes design doc, implementation plan, and cursor plan at `docs/completed/logging-fixes/`.

---

### v1.24 — 2026-03-12 | Step 3b completion

- **Status:** Step 3b (complication-age stale-first budget gate) marked implemented; code review complete. Status line updated: Step 3b code complete; observe 48h before Step 4.
- **Step 3b section:** Added "Implementation status" paragraph documenting code verification (helper pattern, constant, branching, lastDispatchedGateKey rule, log taxonomy) and next step (observe 48h).

---

### v1.23 — 2026-03-11 | Nit-only consistency pass

- Version bump only; no behavioral changes. Aligns with implementation guide v1.8 and Cursor plan reference. Validation Protocol Step 3b row: added skip_reason=age_gate (and duplicate_gate, missing readingEpoch) for queryability. Newline at EOF.

---

### v1.22 — 2026-03-11 | Nit consistency cleanup (Step 3b)

- **Helper:** Step 3b helper guidance made identical in remediation plan and implementation guide: exact 4-step pattern (guard suite/defaults → return .infinity; let lastValid; if lastValid == nil return .infinity; else return max(0, …)).
- **lastDispatchedGateKey rule:** Stated explicitly in all three docs: only set when complication transfer actually enqueued (transferCurrentComplicationUserInfo or transferUserInfo); not on sendMessage-only; not when age gate fails; do not reintroduce Step 3 foreground→background suppression bug.
- **Skip-log taxonomy:** Three queryable categories documented consistently: skip_reason=age_gate (Step 3b), skip_reason=duplicate_gate (R2b), missing readingEpoch.
- **Validation/STOP:** Step 3b STOP block (guide) now explicitly states age gate applies ONLY to transferCurrentComplicationUserInfo, NOT sendMessage and NOT userInfo fallback. Remediation validation table Gate behavior row aligned.

---

### v1.21 — 2026-03-11 | Step 3b — Complication-age stale-first budget gate

- **New step:** Step 3b (Complication-age stale-first budget gate) added to the implementation sequence, after Step 3 (R2b) and before Step 4 (R2d).
- **Behavior:** Gate use of `transferCurrentComplicationUserInfo` on current complication age &gt; T (600s initial). Complication age is computed on iOS by reading App Group key `TrioComplication_lastValidTimestamp` (written by watch-side store). If missing, treat age as very large so first transfer is allowed. `sendMessage` and budget-exhausted `transferUserInfo` fallback are not gated.
- **Rationale:** Preserve 50/day budget for moments when the complication is actually stale; avoid burning budget when complication is already fresh (e.g. from sendMessage or prior transfer).
- **Data-driven threshold:** T = 10 minutes from BetterStack 48h analysis: reload_age proxy p90 ≈ 10.3m; &gt;10m ≈ 79/day, &gt;12m ≈ 40/day, &gt;15m ≈ 14/day. Validation targets and falsifiers documented; Implementation Sequence updated to insert Step 3b.
- **Sketch and status (same release):** Code sketch corrected to explicit branching — age gate applies only when `remainingComplicationUserInfoTransfers > 0`; when budget is exhausted, userInfo fallback runs regardless of age (duplicate gate only). Skip log includes `skip_reason=age_gate` for BetterStack. Status line updated: Step 3 (R2b) deployed as build 134; observing 48h; Step 3b added (not implemented yet).

---

### v1.20 — 2026-03-11 | Step 3 implementation + code review feedback (R2b)

- **Status:** Updated to Step 3 in progress.
- **Implementation log:** Added Build 134 section documenting R2b dispatch gate implementation.
- **Code review Round 1 (Claude):** 6 points evaluated; 1 fix (activation-clear for budget-cycle concern).
- **Code review Round 2 (ChatGPT):** Critical bug found — gate key was advanced on sendMessage-only paths, suppressing complication transfers on foreground→background transition. Fix: moved gate key write inside complication transfer block.

---

### v1.19 — 2026-03-10 | Step 2 deployment (build 133)

- **Status updated:** Step 2 (R2a + R3) deployed as build 133; observing 24h before Step 3.
- **Implementation Log:** Added Build 133 entry documenting R2a coalescer attribution and R3 complication payload allowlist deployment, with BetterStack verification results.

---

### v1.18 — 2026-03-09 | Step 1 deployment (build 132)

- **Status updated:** Step 1 (R1a + R1b + R5e) deployed as build 132; observing 24h before Step 2.
- **Implementation Log section added:** Build 132 entry documenting R1a reading epoch keys, R1b stale queue drain, and R5e BetterStack alert deployment, with BetterStack verification results.

---

### v1.3 — 2026-03-09 | ChatGPT critique #2 of Remediation Plan

**Critical bug fix:**
- **R5d:** `CLKComplicationServer.reloadTimelines` replaced with `WidgetCenter.shared.reloadTimelines(ofKind:)`. The complication is a WidgetKit widget — `CLKComplicationServer` is legacy ClockKit and would silently do nothing. Would have created false confidence in the sleep-gap safety net.

**Architectural fixes:**
- **R5d:** Sleep-gap check added to `didReceiveApplicationContext` path in addition to `didReceiveUserInfo`. During budget exhaustion, `didReceiveUserInfo` may not fire at all — the check must also run on the applicationContext delivery path or it's useless precisely when it's most needed.
- **R4:** `updateApplicationContext` made conditional on `remainingComplicationUserInfoTransfers == 0 || queue_depth > 5`. Previously always-on, which would have added serialization overhead on every send before R2 tames the send rate.

**Logic corrections:**
- **R1b:** Startup/session-activation drain added. Previously only cancelled on budget-exhausted branch — the queue was already frozen at 46–48 items before exhaustion, so this would never have run. Also switched staleness heuristic from enqueue wall time to `readingEpoch` comparison — semantically correct (stale by glucose time, not transport time).
- **R2b:** `lastDispatchedGateKey` persisted to App Group `UserDefaults`. Previously in-memory only — iOS app restart or watch manager reinitialization would reset the gate and allow a re-burst of redundant transfers.

**Prioritization changes:**
- **R2c** deprioritized. Pipeline split (added to backlog) would supersede it; and the UX regression risk (shared coalescer drives both complication and watch UI) isn't worth taking before R2a attribution data is available.
- **Pipeline split** (complication channel vs UI channel) added as high-priority backlog item. Gated on R2a attribution data. The most reliable structural path from 2.85x → ~1.0x per reading. Would supersede R2c entirely.

**Open questions added:**
- Prompt R5d-kind: need `kind` string from WidgetKit `Widget` struct for `WidgetCenter.shared.reloadTimelines(ofKind:)`.

---

### v1.2 — 2026-03-09 | Cursor codebase audit Round 1 (key inventory + key names)

- **R3:** Added `WatchMessageKeys.units` to complication strip list — confirmed present in `watchStateToDictionary`, not needed by complication.
- **R3:** Confirmed `WatchMessageKeys.glucoseValues` constant name and string value `"glucoseValues"` — no rename needed.
- Remaining open question: Prompt R4b — `didReceiveApplicationContext` existence on watch side still needs Cursor confirmation.

---

### v1.1 — 2026-03-09 | Cursor codebase audit Round 1 (architecture findings)

**Critical architecture correction:**
- **R4:** `WCSession` / `receivedApplicationContext` unavailable in WidgetKit complication process. R4 redesigned: iOS sends `updateApplicationContext`, watch app extension receives via `didReceiveApplicationContext` and writes to App Group store, complication reads App Group store unchanged.

**Scope corrections:**
- **R3:** Narrowed — `glucoseValues` only used in complication path to call `latestGlucoseDate()`. Adding top-level `readingEpoch` key (R1a) eliminates the need for the array on the complication transfer path entirely.
- **R1a:** Top-level `"date"` key in `watchStateToDictionary` is build time (`Date()` at state construction), not CGM reading time. New `WatchMessageKeys.readingEpoch` constant required for the actual reading timestamp.

**Field names confirmed:**
- **R2b:** `currentGlucose: String?`, `trend: String?`, `delta: String?` — all pre-formatted optional strings on iOS `WatchState` model. Gate hash can use these directly.
- **R5d:** `lastUserInfoReceivedAt: Date?` confirmed at line ~102, but in-memory only — needs App Group persistence for cross-restart sleep gap detection.

**Safe-to-change confirmations:**
- `scheduleWatchStateUpdate` is `private` on `final class BaseWatchManager` — signature change has no subclass or protocol impact.
- Coalescer debounce is hardcoded inline literals on line ~529 (`min(2.0, 5.0 - elapsed)`) — not named constants, but trivially parameterized.

**Budget clarification:**
- `via=sendMessage` does NOT consume `remainingComplicationUserInfoTransfers`. Only `transferCurrentComplicationUserInfo` calls drain the budget. Prior report was wrong on this point.

---

### v1.0 — 2026-03-09 | Initial version

First draft of the Freshness Remediation Plan (R1–R5; R6 added in v1.26), synthesized from:
- BetterStack telemetry analysis (build 131, 2026-03-08/09)
- ChatGPT critique #1 of the Next-Steps Report
- Prior implementation plan `complication-freshness-implementation-plan.md` v1.27 (FP-Phase 0–3)

Established root-cause hierarchy (redundant triggers → budget burn → frozen queue → stale complication), defined R1–R5 phases (R6 added in v1.26), and set the implementation sequence.

---

### v1.4 — 2026-03-09 | ChatGPT critique #3 of Remediation Plan v1.3

**Logic fix — R1b same-epoch duplicate handling:**
R1b's `epoch < latestEpoch` predicate correctly cancelled older-epoch items but did nothing when all queued transfers shared the same latest epoch (e.g. 2–3 per reading with identical epoch). The frozen 46–48 item queue was entirely this pattern. Rewrote cancellation policy to group by epoch, pick the single newest transfer within the latest epoch by `transferEnqueuedAt`, and cancel everything else including same-epoch duplicates. This will actually deflate the queue to depth 1 regardless of how many same-epoch duplicates are present.

**Maintainability fix — R3 allowlist build replaces strip list:**
"Copy fullMessage then remove keys" was a maintainability trap: adding any new field to `watchStateToDictionary` would silently bloat the complication payload with no compile-time signal. Replaced with an explicit allowlist build — `complicationMessage` is now constructed directly from only the 6 fields the complication needs. Payload regression is now structurally impossible unless someone deliberately adds to the allowlist.

**Correctness fix — R5d reload gated on snapshot age, not just receive gap:** ~~Previously `forceWidgetReload()` fired whenever receive gap > 600s regardless of whether the incoming snapshot was fresh. The reload helper now checks `TrioComplicationDataStore.shared.latestSnapshot().readingDate` — reload only fires if snapshot age > 300s.~~ ⚠️ **Reversed in v1.12** — this guard defeats itself because callers save before calling `forceWidgetReloadIfStale()`, so the just-saved fresh snapshot always reads as fresh and the guard always blocks. See v1.12 changelog.

**Structural fix — R2d promoted from backlog to formal phase:**
"Pipeline split" was in the backlog. Given that R2b's `(epoch, displayFields)` gate provably allows early-nil then late-computed double sends per reading, and the stated goal is avg C ≤ 1.3, R2d is now a formal phase with a clear decision gate: if avg C > 1.3 after 48h of R2b data, implement R2d (authoritative-source allowlist for complication transfers) rather than R2c. R2c remains in the plan as a fallback but is subordinate to R2d.

**Bug fix — R4 `guard ... else { break }` footgun:**
`break` in a guard in function scope won't compile; in a `switch` it silently exits the wrong construct. Replaced with `return`. Added `context_attempted` / `context_succeeded` split log fields to allow BetterStack monitoring of whether the R4 safety net is actually arming and delivering during exhaustion windows.

**Sequence updated:**
R2b now ships and observes for 48h before deciding R2c vs R2d. Decision gate is explicit: avg C ≤ 1.3 → optional R2c; avg C > 1.3 → R2d (pipeline split). Pipeline split removed from backlog table.

**Process addition:**
Added "Decisions & Rejected Alternatives" section. Documents 5 deliberate deviations from reviewer suggestions with reasoning, so reviewers don't re-raise the same points in future critiques.

---

### v1.5 — 2026-03-09 | ChatGPT critique #4 of Remediation Plan v1.4

**Production safety fix — R3 property list compliance:**
Replaced `Optional-as-Any` / `compactMapValues` pattern with explicit `if-let` inserts. `fullMessage[key] as Any` when the key is absent produces `Optional<Any>.none`, which is not property-list-safe for WatchConnectivity and can cause `transferCurrentComplicationUserInfo` to silently fail serialization. Explicit inserts guarantee only real plist-safe values enter the payload. Added `readingEpoch` as a load-bearing guard — if absent, the entire send aborts with a log warning rather than sending an unusable payload.

**Correctness fix — R2d mode selection uses last source, not any source:**
`coalescerSources.contains(where: { eligible.contains($0) })` would classify a window as complication-eligible if any eligible source appeared at any point — even if the final trigger was IOB-only. Changed to `lastCoalescerSource` / `lastCoalescerSourceAt` tracking (add to R2a's `scheduleWatchStateUpdate`). Mode is now determined by the last trigger at coalescer fire time, aligning budget use with actual glucose-origin events.

**Robustness fix — R5d reload rate limiter:**
Added `lastWidgetReloadAt` persisted to App Group `UserDefaults`, capping forced reloads at once per 5 minutes. Prevents reload storms if App Group suite keys break, timestamps bounce, or the function is called repeatedly. Rate limiter state survives process restarts.

**Observability improvements — R1b logging:**
Added `queue_depth_before`, `queue_depth_after` (re-read once after cancel), `kept_epoch`, `kept_enqueued_at` fields. Added hard-cap warning log when `depth_after > 5` — indicates cancellation isn't taking effect. Removed race-prone startup drain log that re-read count before the method ran.

**Narrative fix — R2b ceiling acknowledged:**
Added explicit callout in R2b that the `(epoch, displayFields)` gate will not prevent the "early-nil then late-computed" double-send pattern, and that R2b may plateau above the ≤1.3x target. R2d is the structural fix for that case, not R2b.

**Validation improved:**
Added `timeline_entry_epoch` row to validation protocol — confirms WidgetKit actually advanced the timeline, not just that the App Group store is fresh.

**Decisions section update:**
R1b "FIFO certainty" framing softened to engineering tradeoff. The keep-1 decision stands, but the justification now correctly describes it as a tradeoff (self-healing via next reading's transfer) rather than a FIFO correctness claim.

**New Cursor prompts:**
- Prompt R5d-snapshot: `latestSnapshot()` thread safety, blocking I/O, and `readingDate` property name
- Prompt R5f-getTimeline: `TimelineEntry` type and reading epoch field for `timeline_entry_epoch` logging

---

### v1.6 — 2026-03-09 | ChatGPT critique #5 of Remediation Plan v1.5

**Logic fix — R2d mode selection corrected (again):**
v1.5's "last source" predicate was too strict: if `glucoseStored` fired then `iobUpdate` fired last in the same coalescer window, the last source would be non-eligible and no complication transfer would fire — silently suppressing legitimate glucose updates. Replaced with window-scoped check: `lastEligibleSourceAt >= coalescerFirstScheduledAt`. Correctly answers "did any glucose-origin event fire during this specific coalescer window?" for all source orderings. See Decisions & Rejected Alternatives for the full three-version design history.

**Correctness fix — coalescer state snapshotted before clearing:**
R2a's work item cleared `coalescerSources`, `coalescerTriggerCount`, and `coalescerFirstScheduledAt` before calling `sendDataToWatch`. Since R2d mode selection and logging depend on these values, they must be captured into local snapshots (`sourcesSnapshot`, `lastEligibleSnapshot`, `windowStartSnapshot`) before the clear. Added `lastEligibleSourceAt` to the snapshot/clear cycle. `sendDataToWatch` now receives these as parameters rather than reading stale/empty live properties.

**Robustness fix — R1b session readiness guard:**
`cancelStaleQueuedTransfers()` now guards on `session.activationState == .activated && session.isPaired && session.isWatchAppInstalled` before attempting cancellation. Avoids noise logs and undefined behavior when the watch is unavailable.

**Explicit dependency — R3 requires R1a:**
R3 phase header now carries a hard-dependency warning: R3 strips `glucoseValues` from the payload and relies on `readingEpoch` (added by R1a) as the only date derivation path. Shipping R3 before R1a will cause `saveComplicationSnapshot` to abort on every transfer and stop saving snapshots entirely. This was always implied by the sequence but is now an explicit constraint.

**Decisions section — R2d mode selection design history:**
Added entry documenting all three versions of the mode selection predicate (v1.4 "any in window," v1.5 "last source," v1.6 "window-scoped eligible") so future reviewers understand why the current design exists and won't re-raise the "any in window" or "last source" approaches.

**Test plan added to R2d:**
Two mandatory manual verification cases before shipping: (1) glucoseStored→iobUpdate must produce `mode=complicationAndUI`; (2) iobUpdate alone must produce `mode=uiOnly`.

---

### v1.7 — 2026-03-09 | ChatGPT critique #6 of Remediation Plan v1.6

**Correctness fix — R2a nil coalescerFirstScheduledAt handled explicitly:**
`?? Date()` was replaced with explicit nil detection. If `coalescerFirstScheduledAt` is nil at fire time (invariant violation), the plan now emits a `⚠️ coalescer_window_start_nil` warning and sets `windowStart = Date(timeIntervalSince1970: .infinity)` — a sentinel value that guarantees the epoch comparison always evaluates false, routing to the clock-skew fallback path rather than silently suppressing complication transfers.

**Correctness fix — R2d clock-skew fallback added:**
Wall-clock jumps backward (NTP sync, user time change) can cause `lastEligibleSourceAt >= windowStart` to evaluate false incorrectly. Added detect-and-log path: if epoch check fails but `sourcesSnapshot` contains an eligible source, emit `⚠️ eligible_source_clock_skew` and fail open (treat as eligible). Avoids the refactor cost of switching to `CACurrentMediaTime()` while making skew events observable. Refactor is deferred pending telemetry evidence. **Trigger for refactor:** if `eligible_source_clock_skew` fires more than ~once per week in production, that is the signal to switch `lastEligibleSourceAt` and `windowStartEpoch` to monotonic time (`CACurrentMediaTime()`) — wall clock is no longer trustworthy for this comparison.

**Observability fix — R2d transfer outcome logging:**
Added `complication_transfer_attempted` and `transfer_path` (complication | userInfo | skipped_session_not_ready) to prevent the "avg C/reading looks good because session-guard skips aren't counted" problem. `skipped_session_not_ready` frequency during exhaustion windows is itself a diagnostic signal.

**Robustness fix — R1b also drains queue-deep path:**
Added a third `cancelStaleQueuedTransfers()` call site: in `sendDataToWatch()`, if `queue_depth > 5` even before hitting the budget-exhausted branch. Handles the case where session was already activated before this code deployed (activation drain never ran). Safe because the readiness guard inside `cancelStaleQueuedTransfers()` prevents execution when watch is unavailable.

**Log level fix — R3 non-load-bearing missing keys:**
Non-load-bearing keys (`trend`, `delta`, etc.) now log at `debug` level when absent rather than ⚠️, preventing log spam when these fields are legitimately nil during early readings. `readingEpoch` retains ⚠️ as the only load-bearing field.

**Hard prerequisite — R5d blocked on Prompt R5d-snapshot:**
R5d section now carries an explicit blocking prerequisite: `latestSnapshot()` must be confirmed non-blocking and main-safe before implementing R5d as written. If it does file I/O, the read must move to a background queue. This was previously a "confirm" soft dependency; it is now a hard gate.

---

### v1.8 — 2026-03-09 | ChatGPT critique #7 of Remediation Plan v1.7 (final pre-implementation review)

**Cleanliness fix — nil-window sentinel replaced with explicit optional:**
`Date(timeIntervalSince1970: .infinity)` replaced with `windowStartEpoch: TimeInterval?`. `nil` is passed when `coalescerFirstScheduledAt` is nil (invariant violation). Self-documenting, won't appear in logs as a confusing timestamp, and routes cleanly to the fallback path. `sendDataToWatch` signature updated accordingly.

**Correctness fix — clock-skew fallback now requires `lastEligibleSourceAt != 0`:**
Without this guard, any eligible source in `sourcesSnapshot` would "invent" eligibility if the epoch comparison failed, even if `lastEligibleSourceAt` was never set. This would silently revert to "any eligible in snapshot" behavior and re-burn budget. The `!= 0` guard requires that eligibility was actually observed during the session, not just that an eligible source appears in the snapshot history.

**Shared helper — `sessionIsReadyForTransfer()` added:**
New method encapsulates the three-condition session readiness check (`activationState == .activated && isPaired && isWatchAppInstalled`). Used by `cancelStaleQueuedTransfers()` and the R2d transfer path. Prevents R1b and R2d from drifting out of sync again.

**Robustness fix — queue-deep drain cooldown:**
The third `cancelStaleQueuedTransfers()` call site (queue_depth > 5 path) now has a 60-second in-process cooldown via `lastQueueDeepDrainAt: TimeInterval`. Prevents repeated iterate+cancel overhead if something is rapidly enqueueing. New `lastQueueDeepDrainAt` property added to `BaseWatchManager`.

**Documentation fix — `WatchMessageKeys.date` comment strengthened:**
Inline comment in R3 allowlist now reads `⚠️ BUILD TIME, not CGM reading time — kept for backward compat only; never treat as readingDate`. Prevents the same bug from being reintroduced.

**Validation fix — BetterStack avg C/reading query must exclude session skips:**
R2 validation section now explicitly notes that the query must filter `transfer_path IN ('complication', 'userInfo')` and exclude `skipped_session_not_ready`. Prevents the metric from appearing better than reality due to silent session-guard skips.

---

### v1.9 — 2026-03-09 | Cursor audit Round 2 — all four prompts resolved

**R4b resolved:** `session(_:didReceiveApplicationContext:)` is absent from `WatchState.swift`. Purely additive — add after `sessionReachabilityDidChange` (~line 631) under `// MARK: - WCSessionDelegate`.

**R5d-kind resolved:** Widget kind string confirmed as `"TrioWatchComplication"` via `TrioComplicationDataStore.complicationKind` constant (line 147). Replaced `WidgetCenter.shared.reloadAllTimelines()` placeholder with `WidgetCenter.shared.reloadTimelines(ofKind: TrioComplicationDataStore.complicationKind)`. Single widget in target confirmed.

**R5d-snapshot resolved:** `latestSnapshot()` performs synchronous file I/O (~200 bytes, JSON decode) but is safe to call on main — negligible cost for the file size, already used from multiple threads in production. No background queue needed. CGM timestamp property confirmed as `readingDate: Date` (distinct from `date: Date` = snapshot creation time). Hard prerequisite block removed; R5d can implement as written.

**R5f resolved:** Timeline entry type is `TrioWatchComplicationEntry` with `readingDate: Date` (CGM reading time) already propagated from snapshot into all 30 entries. Added R5f section with confirmed log snippet using `firstEntry.readingDate.timeIntervalSince1970`. `date` is the WidgetKit display time (distinct from `readingDate`); recency age in the complication views is computed as `entry.date.timeIntervalSince(entry.readingDate)`.

**Plan status:** All open questions closed. Implementation-ready.

---

### v1.10 — 2026-03-09 | Cursor plan-review pass — 6 bugs fixed

**Issue 1 (Critical) — R3 `readingEpoch` guard no longer kills `sendMessage`:**
Replaced `guard ... return` with a `readingEpochPresent` flag. `sendMessage` (budget-free watch UI path) always fires. Only `transferCurrentComplicationUserInfo` / `transferUserInfo` are gated on `readingEpochPresent`. Previous code would have blacked out the watch UI entirely whenever `readingEpoch` was absent (e.g. transitional build, empty `glucoseValues`).

**Issue 2 (Significant) — R5d reload now fires AFTER save in both handlers:**
`forceWidgetReloadIfStale()` previously fired before `saveComplicationSnapshot()` in both `didReceiveUserInfo` and `didReceiveApplicationContext`. WidgetKit would call `getTimeline` before fresh data was on disk, build a stale timeline, and the 5-minute rate limiter would block the corrective follow-up. Ordering corrected to: save → update timestamp → gap check → reload.

**Issue 3 (Notable) — renamed `lastUserInfoReceivedAt` → `lastDataReceivedAt`, updated in both handlers:**
`lastUserInfoReceivedAt` was never updated by the `didReceiveApplicationContext` path. During budget exhaustion windows (the exact scenario R4 targets), every applicationContext delivery would see `gap = infinity` and trigger a forced WidgetKit reload every 5 minutes — semantically wrong and noisy. Renamed to `lastDataReceivedAt` and updated in both handlers.

**Issue 4 (Compile error) — R1b `Set<ObjectIdentifier>` type mismatch fixed:**
`keeper.map { [ObjectIdentifier($0)] } ?? []` returns `[ObjectIdentifier]?` → `[ObjectIdentifier]`. Swift won't implicitly convert Array to Set. Fixed to `Set([ObjectIdentifier($0)])` in both branches.

**Issue 5 (Sequencing) — R2a now explicitly defines `complicationEligibleSources` and `lastEligibleSourceAt`:**
Both properties were referenced in R2a's code but only formally defined in R2d. Since R2a ships first (with a 24h observation window before R2d is even considered), R2a must define them. Added explicit callout block in R2a with the exact property declarations. R2d section updated to mark them as "already defined in R2a — shown for reference only."

**Issue 6 (Minor) — R4 guard placement now has explicit callout:**
Added `⚠️ Placement` note to R4's iOS-side block: the `guard budgetExhausted || queueDeep else { return }` goes at the END of `sendDataToWatch`, after all existing transfer and `sendMessage` calls. If placed before them it would skip all sends when budget is healthy — the opposite of the intent.

---

### v1.11 — 2026-03-09 | Cursor plan-review pass 2 — 4 issues fixed

**Issue 1 (Critical) — R5d `didReceiveUserInfo` gap now computed before timestamp update:**
In v1.10's fix, `lastDataReceivedAt = Date()` was set before computing the gap, making `Date().timeIntervalSince(Date())` ≈ 0ms always — sleep-gap detection was dead code. Fixed to match the correct `didReceiveApplicationContext` pattern: snapshot gap first, save, update timestamp, then conditionally reload.

**Issue 2 (Notable) — R2b `sendMessage` suppression documented as explicit tradeoff:**
The R2b gate `return` exits `sendDataToWatch` entirely, including the budget-free `sendMessage` path. IOB/COB updates sharing a gate key with the prior glucose reading will not reach the watch app UI until the next glucose reading. This is intentional but was undocumented. Added explicit `⚠️ Tradeoff` callout with the accept/revisit condition.

**Issue 3 (Minor) — `"bgTaskRefresh"` removed from `complicationEligibleSources`:**
No inventoried call site uses this source tag — it was a phantom entry. Removed from both the R2a definition and the R2d reference copy.

**Issue 4 (Minor) — Buggy `didReceiveApplicationContext` version removed:**
The plan previously showed a wrong implementation followed by "Wait — cleaner:" and then the correct one. Removed the wrong version; only the correct three-constraint ordering remains.

---

### v1.12 — 2026-03-09 | Cursor plan-review pass 3

**Issue 1 (Significant) — Snapshot age guard removed from `forceWidgetReloadIfStale()`:**
The guard (`snapshotAge > 300`) defeated itself: callers save before calling the function, so `latestSnapshot().readingDate` always reflects just-saved data. In the primary scenario (fresh reading arriving after a 2-hour sleep gap), `snapshotAge ≈ 60s`, the guard fails, and the reload is skipped — leaving the complication stale until WidgetKit's next natural refresh. The stale-backlog concern that motivated the guard is addressed upstream by R1b's queue draining. Guard removed; the 5-minute rate limiter is now the only storm backstop. Decisions table updated to reflect reversal.

**Issue 2 (Minor) — "v2.0" typo fixed in input documents header:**
The 6-issue plan-review pass was incorrectly attributed to "v2.0" — corrected to "v1.10".

---

### v1.13 — 2026-03-09 | ChatGPT review pass — 5 concerns addressed

**Concern 1 (act on it) — R2b gate now scoped to complication transfer only, not sendMessage:**
Previously the `guard gateKey != lastDispatchedGateKey else { return }` exited `sendDataToWatch` entirely, suppressing `sendMessage` for IOB/COB updates sharing a gate key with the prior glucose reading. Restructured using an `isDuplicateDispatch` flag: the complication transfer path is skipped when true, but `sendMessage` always fires. Follows the same pattern established by R3's `readingEpochPresent` flag. The tradeoff callout added in v1.11 is removed as the tradeoff no longer exists.

**Concern 2 (observability) — `widgetCenter_reload_triggered` now logs `reading_epoch` and `snapshot_read_ms`:**
After firing the reload, `forceWidgetReloadIfStale()` reads back the just-saved snapshot and logs `reading_epoch` (to detect stale-backlog reloads) and `snapshot_read_ms` (to prove main-thread I/O is negligible). Comment added: if `snapshot_read_ms` ever logs >20ms, move the read to a background queue.

**Concern 3 (main-thread I/O) — resolved via concern 2 log:**
No structural change to `latestSnapshot()` call site. The `snapshot_read_ms` log field provides production proof. If evidence emerges of >20ms reads, background queue refactor is the documented next step.

**Concern 4 (R2d clock-skew) — delta field added to skew fallback log:**
`eligible_source_clock_skew` log now includes `delta=Xs` (the difference between `lastEligibleSourceAt` and `windowStartEpoch`). Small negative delta → genuine time skew; large delta → logic bug. Directly answers the "skew vs bug" question without guesswork.

**Concern 5 (R4 complicationMessage scope) — explicit callout added:**
Added `⚠️ complicationMessage must be in scope` note alongside the R4 placement warning. `complicationMessage` must be built unconditionally at the top of `sendDataToWatch` — not gated on `readingEpochPresent` or any other condition — so R4's safety net always has a valid payload to send during exhaustion windows.

---

### v1.14 — 2026-03-09 | ChatGPT review pass 2 — 5 concerns addressed

**Concern 1 (stale snapshot reload) — `reload_with_stale_snapshot` warning log added:**
`forceWidgetReloadIfStale()` now logs `⚠️ reload_with_stale_snapshot` when `snapshotAge > 600s` at reload time, with `reading_epoch` and `snapshot_age` fields. Reload still fires — the rate limiter prevents storms — but the event is now searchable in BetterStack. Directly catches the reconnect-ordering edge case where a stale userInfo slips through before R1b's drain completes.

**Concern 2 (snapshot_read_ms measurement) — timer now wraps the call, logs before reload:**
Timer now measures `latestSnapshot()` on the actual call path (before reload is triggered), not after. Log fields `reading_epoch`, `snapshot_age`, and `snapshot_read_ms` all emit before `WidgetCenter.reloadTimelines()` fires. Reflects real I/O latency on the hot path.

**Concern 3 (wall-clock R2d) — monotonic refactor trigger documented:**
Added explicit trigger condition to the R2d clock-skew note: if `eligible_source_clock_skew` fires more than ~once per week in production, switch `lastEligibleSourceAt` and `windowStartEpoch` to `CACurrentMediaTime()`. No code change; telemetry determines whether the refactor is needed.

**Concern 4 (cancel_requested_count) — added to R1b drain log:**
`queue_drain` log now includes `cancel_requested=N` alongside `depth_before` and `depth_after`. Enables distinguishing "we asked to cancel N transfers" from "the queue visibly shrank by N" in BetterStack. The `queue_drain_incomplete` warning also includes `cancel_requested` for the same reason.

**Concern 5 (R4 uses raw activationState) — replaced with `sessionIsReadyForTransfer()`:**
R4's `updateApplicationContext` guard was checking only `activationState == .activated`, inconsistent with the `sessionIsReadyForTransfer()` helper built for exactly this purpose. Replaced; `context_skipped` log now includes all three conditions (`activation_state`, `paired`, `installed`) to make the skip reason visible. R4 decisions table updated accordingly.

---

### v1.15 — 2026-03-09 | Final review pass (ChatGPT + Cursor)

**Cursor — stale R5d section header fixed:**
"gated on snapshot age, not just receive gap" updated to "rate-limited, with diagnostic snapshot read" — the snapshot age guard was removed in v1.12.

**ChatGPT concern 1 (log spam) — not acted on:**
`forceWidgetReloadIfStale()` only fires when `gap > 600s` and at most once per 5 minutes — log spam is not a realistic risk in this call pattern. Skipped.

**ChatGPT concern 2 (stale threshold misclassifies sensor gaps) — fixed:**
Replaced the fixed `staleThreshold = 600s` with `snapshotAge > (receivedGap - 60)`. The real stale-backlog signature is `snapshotAge ≈ receivedGap` (snapshot barely advanced relative to the gap that triggered the reload). A fixed 600s threshold would misclassify legitimate >10-min sensor warmup or connectivity gaps as stale backlog. `forceWidgetReloadIfStale()` now accepts `receivedGap: TimeInterval` parameter; both call sites updated.

**ChatGPT concern 3 (queueDepthNow without readiness guard) — fixed:**
The queue-deep drain call site now guards `outstandingUserInfoTransfers.count` read behind `sessionIsReadyForTransfer()`. When not paired/installed the count can return stale values and trigger spurious `queue_deep_drain triggered` logs.

**ChatGPT concern 4 (R2d fallback conflates three scenarios) — fixed:**
Split into three distinct log strings: `eligible_source_window_nil_fallback` (nil windowStart — invariant violation), `eligible_source_clock_skew` (small negative delta < 5s — genuine NTP skew), and `eligible_source_epoch_inversion` (large negative delta — likely logic bug). Production triage can now distinguish these without guesswork.

**ChatGPT concern 5 (glucoseValues.first sorted-order assumption) — fixed:**
Both `watchStateToDictionary` (R1a `readingEpoch` payload) and `computeDispatchGateKey` (R2b gate epoch) switched from `.first?.date` to `.max(by: { $0.date < $1.date })`. Removes the load-bearing assumption that `glucoseValues` is sorted newest-first. Both now use the same source, so gate keys and `readingEpoch` always agree.

---

### v1.16 — 2026-03-09 | Self-review

**Bug fix — `forceWidgetReloadIfStale(receivedGap:)` call sites not updated in v1.15:**
The v1.15 signature change added `receivedGap: TimeInterval` to the helper but the two inline call sites in `didReceiveUserInfo` and `didReceiveApplicationContext` were not updated — both still called the old `forceWidgetReloadIfStale()` (no argument). This would not compile. Fixed: both call sites now pass `receivedGap: gap`. The orphaned "Update both call sites" migration note appended below the helper definition was also removed since it is now redundant.

No other issues found in self-review.

---

### v1.17 — 2026-03-09 | ChatGPT final pass

**Critical fix 1 — R5d "blocked" banner replaced:**
The `⚠️ Hard prerequisite: R5d implementation is blocked on Prompt R5d-snapshot` banner contradicted the Cursor Round 2 resolution already documented elsewhere in the plan. Replaced with a `✅ Confirmed safe on main` note referencing the resolution directly, with the `snapshot_read_ms > 20ms` refactor trigger retained.

**Critical fix 2 — ordering comment updated to use correct signature:**
The `// (2) save must happen BEFORE forceWidgetReloadIfStale()` comment in the `didReceiveUserInfo` ordering block used the old zero-argument signature. Updated to `forceWidgetReloadIfStale(receivedGap:)` to match the v1.15 signature change and prevent copy-paste compile errors. Changelog references to the old signature retained as historical record.

**Non-critical notes acknowledged, not acted on:**
- `max(by:)` on 288 values is O(n) — negligible for this call frequency; no change.
- R2d skew bucket thresholds are intentionally heuristic; documented as such.

---
