# Complication Freshness — Problem and Strategy

**Version:** 1.8
**Created:** 2026-03-19 11:30 CET
**Last updated:** 2026-04-08 22:31 CET

---

## Naming Convention

| Label | Refers to |
|---|---|
| FP-Phase 0-3 | Prior plan ([`fp-plan-v1.28.md`](archive/fp-plan-v1.28.md), complete as of build 131) |
| R1-R6 | Remediation plan (budget exhaustion, redundant triggers, payload, safety nets, observability, HealthKit) |
| Implementation guide step numbering | Step 5 = R4, Step 7 = R6 |

---

## Problem Summary

The Trio watchOS complication displays the current CGM glucose reading and recency age. The goal is for it to always show the latest reading within a few minutes of acquisition.

**Structural problem:** `transferCurrentComplicationUserInfo` has a hard Apple limit of 50 transfers per day. The current code burns through this budget in 108-147 minutes due to redundant triggers. Once exhausted, the fallback is a 46-item-deep stale `transferUserInfo` queue that never drains.

**Root cause hierarchy** (confirmed by BetterStack telemetry + Cursor code audit):

1. **Six publishers** fire `scheduleWatchStateUpdate()` per CGM reading (`AppleWatchManager.swift` lines 85, 92, 103, 110, 123, 129). The 2s coalescer handles same-tick publishers but waves >2s apart produce 2-3 `transferCurrentComplicationUserInfo` calls per reading.
2. **No queue cancellation** before fallback: `outstandingUserInfoTransfers` grows to 46-48 items and is never cleared (lines 590, 594 — count read for logging only).
3. **Oversized payload:** `watchStateToDictionary` includes a 288-entry `glucoseValues` array (~18.7 KB of ~19-20 KB total). The complication needs only 5-6 scalar fields (~200 bytes).
4. **No reconnect safety net:** No mechanism to deliver the current reading during the 2-3 hour exhaustion windows. The complication is a WidgetKit extension and **cannot use `WCSession`** — the safety net must operate via the App Group shared container.

### Build 131 Baseline

Budget-ok window 04:00-06:27 UTC 2026-03-09:

| Metric | Value |
|---|---|
| Avg complication transfers/reading | 2.85x (ideal: 1.0x) |
| Budget drain rate (Cycle 2) | 20.4/hr -> exhausted in 147 min |
| Budget exhaustion cycles in first 8 hours | 2 |
| queue_depth throughout | 46-48 (frozen since pre-build-131) |
| save_age p90 | 289s |
| reload_age p90 | 558s |

---

## Strategy Overview

| Step | Description |
|---|---|
| R1 | Add reading epoch to transfer dict, cancel stale queue on startup and before enqueue |
| R2 | Reduce redundant triggers: coalescer attribution (R2a), dispatch gate (R2b), age gate (Step 3b) |
| R3 | Strip oversized payload — allowlist complication-only fields in transfers |
| R4 | `applicationContext` safety net during budget exhaustion (watch reads via `didReceiveApplicationContext`) |
| R5 | Observability hardening: coalescer attribution (R5a), BetterStack exhaustion alert (R5e), sendMessage latency (R5b), decode latency (R5c), WidgetKit timeline/snapshot logging (R5f), sleep-gap reload (R5d) |
| R6 | HealthKit background delivery on watch (observer + sample fetch + snapshot save) |
| R6.1 | HealthKit channel improvements: anchored query, trend derivation, anchor persistence |

---

## Implementation Sequence

```
R1a  (readingEpoch + transferEnqueuedAt keys in dict)  -+
R1b  (cancel stale queue — startup + before enqueue)    +-- one PR   ✅ SHIPPED (build 132)
R5e  (BetterStack exhaustion alert)                    -+

        | deploy, collect 24h data

R5a / R2a  (coalescer source logging)                                ✅ SHIPPED (build 133)
R3         (allowlist complication msg, watch-side prefer readingEpoch) ✅ SHIPPED (build 133)

        | R2a data confirms publisher attribution

R2b  (epoch+fingerprint dispatch gate)                               ✅ SHIPPED (build 134)

Step 3b  (complication-age stale-first gate; T=600s)                 ✅ SHIPPED (builds 137-138)

        | if avg C <= 1.3 after 48h -> R2c (optional, low priority)
        | if avg C > 1.3 after 48h -> R2d (pipeline split)
        | (Decision: avg C <= 1.3 confirmed -> R2d SKIPPED)

R6   (HealthKit background delivery on watch)                        ✅ SHIPPED (build 140)
R6.1 (HealthKit improvements)                                        ✅ SHIPPED (build 141)
R4   (applicationContext safety net)                                  ✅ SHIPPED (build 142)
R5b + R5c + R5f  (observability)                                     ✅ SHIPPED (build 141)
R5d  (sleep-gap forced reload)                                       ✅ SHIPPED (build 143)

        | readingDate wall-clock fallback fixes also in build 143
        | R4 handler upgraded with R5d three-constraint ordering in build 143
        | Watch log flush observability (patches 06+09) in build 143
        | WCSession crash guard (patch 10) in build 143
```

---

## Backlog

Items are ordered roughly by priority within each group. “Shipped” items are retained for traceability. “Rejected ideas” are retained so previously considered options and the rationale for not pursuing them remain visible.

---

### Shipped

| Item | Build / Status | Notes |
|---|---|---|
| R1a — readingEpoch + transferEnqueuedAt in transfer dict | 132 | Reading epoch as top-level scalar; eliminates glucoseValues dependency |
| R1b — cancel stale queue on startup and before enqueue | 132 | `cancelStaleQueuedTransfers()` drains frozen 46-item queue |
| R5e — BetterStack budget exhaustion alert | 132 | Fires when >5 `via=userInfo` events in 30 min |
| R5a / R2a — coalescer source attribution logging | 133 | `coalescer_trigger source=` on every `scheduleWatchStateUpdate` |
| R3 — complication payload allowlist (~200 bytes) | 133 | Stripped `glucoseValues` array from complication transfers |
| R2b — per-reading epoch+fingerprint dispatch gate | 134 | Prevents duplicate complication transfers for same reading |
| Step 3b — complication-age stale-first gate (T=600s) | 137–138 | Spends budget only when complication is actually stale |
| R6 — HealthKit background delivery on watch | 140 | Independent of WCSession; fires on every CGM write to HK |
| R6.1 — HK anchored query, trend derivation, anchor persistence | 141 | Eliminates full-scan on every observer fire |
| R5b — sendMessage latency instrumentation | 141 | Wall-clock timestamps on send and receive |
| R5c — didReceiveUserInfo decode latency | 141 | `decode_ms` threaded through save path; `reading_epoch` from payload |
| R5f — WidgetKit getTimeline + getSnapshot logging | 141 | `data_age_seconds` at both WidgetKit entry points |
| #24 — Consistent `reading_epoch` across pipeline | 141 | Closed by R5a (build 133) + R5b (build 141); all pipeline stages now use CGM epoch |
| R4 — updateApplicationContext safety net | 142–143 | Budget-free parallel channel during exhaustion or deep queue. R5d ordering in `didReceiveApplicationContext` shipped build 143 (see R4 handler upgrade row). |
| Bug fix — reachable + budget=0 transfer skip | 142 | `transferUserInfo` fallback was gated inside `!isReachable`; extracted to independent block. BetterStack-confirmed in production (two instances, 2026-03-18/19). See `transfer-optimization-implementation-log.md`. |
| Monotonic snapshot acceptance guard on watch | 130 (FP-Phase 3) | `saveOnMain` rejects older snapshots via `shouldUpdate` (±1s tolerance) + `lastValidTimestamp` persisted fallback. Channel-agnostic; all delivery paths funnel through `save()`. Confirmed by code audit 2026-03-19. |
| readingDate wall-clock fallback fixes (1A/1B/1C) | 143 | 3 code paths substituting `Date()` for nil CGM dates — `saveComplicationSnapshot` fallback now returns early, `didReceiveUserInfo` removes `?? dateValue` fallback, `setupWatchState` filters nil-date entries via compactMap. See investigation report §2. |
| R5d — sleep-gap forced reload | 143 | `lastDataReceivedAt` renamed + App Group persisted, `forceWidgetReloadIfStale(receivedGap:)` with 5-min rate limiter. Three-constraint ordering (gap → save → update) in both `didReceiveUserInfo` and `didReceiveApplicationContext`. Red-team review fixes applied (RT-1 thru RT-5). |
| R4 handler upgrade (R5d integration) | 143 | `didReceiveApplicationContext` upgraded from standalone to R5d three-constraint ordering (gap detection → save → timestamp update → forced reload if stale). |
| Watch log flush observability (4A/4B/4C) | 143 | Truncation logging in `WatchLogger.flushToPhone()`, phone-side upload nudge via `trioWatchLogsAppended` notification, Flush Logs debug button replacing Burst Save x14. |
| WCSession crash guard (5A/5B) | 143 | Delegate callback debounce (0.5s coalescer), activation state guard, reachability debounce, `retryConnection()` removal, `loadServices()` force-unwrap → guard-let. New patch 10. |
| Bug fix — Foundation.NotificationCenter shadowing | 143 | Custom `protocol NotificationCenter` shadows `Foundation.NotificationCenter`; qualified 4 call sites in `AppleWatchManager.swift` with `Foundation.` prefix. |
| 4G — unified `Transferred` log for R4 (`updateApplicationContext`) | 144 | Better Stack `transfer_via` parity; see `observability/observability-implementation-log.md`. |
| 4H — `queue_depth` in `complication_budget_check` | 144 | Real-time queue depth every send cycle. |
| 4I — skip WidgetKit reload retry when snapshot fresh (<60s) | 144 | `coalescedReloadOnMain`; see `build-144-plan.md` success criteria. |

---

### Pending (planned, fully specced)

*None — all specced remediation through build 144 (including watch-log 4D–4F and complication observability 4G–4I) is shipped.*

---

### Backlog (unplanned, not yet specced unless noted)

#### Remediation follow-ups

| Item | Priority | Notes |
|---|---|---|
| ~~readingDate wall-clock fallback bug~~ | ~~P0~~ → **Shipped (143)** | Fixed in build 143 (Items 1A/1B/1C). See Shipped table. |
| Post-dead-zone recovery: pull request after stall drain | Medium | In `didFinishUserInfoTransfer` success path, check staleness of `lastDataReceivedAt`; if still stale, send `requestWatchUpdate`. Addresses 66-minute dead-zone recovery gap observed 2026-03-17. |
| Proactive transfer on iOS app foreground | Medium | On `applicationDidBecomeActive` / `sceneDidBecomeActive`, call `setupWatchState()` + `sendDataToWatch()` only when the current snapshot is stale or no recent successful transfer exists. Addresses the “I just opened Trio on my phone, my watch should update” mental model without reintroducing budget spam. Deferred — re-evaluate by product priority (post–R5d gate completed 2026-03-21; see Process row). **Specced (draft):** [`proactive-transfer/proactive-transfer-01-design.md`](proactive-transfer/proactive-transfer-01-design.md), [`proactive-transfer/proactive-transfer-02-implementation-plan.md`](proactive-transfer/proactive-transfer-02-implementation-plan.md). |
| HK trend metadata on iPhone writes | Medium | Add `"com.trio.trend": glucoseSample.direction?.rawValue ?? ""` to HK metadata in `uploadGlucose(_:)`. Eliminates transient trend regression (`""` overwriting real trend) in dual-delivery normal operation. Specced in `alternative-delivery-design.md §R6`. Verify HealthKit consumer apps before shipping. |
| Adaptive budget throttling | Medium | Dynamically increase stale-first gate threshold T as remaining complication budget depletes, using remaining budget, time-of-day / projected burn, and current snapshot age as inputs. Example: if 40/50 transfers are used by noon, stretch T from 600s to 900–1200s to avoid exhaustion. Extends the budget-ok window without sacrificing freshness at the start of the day. |

#### Documentation

| Item | Priority | Notes |
|---|---|---|
| Document cross-channel arbitration rules | Low | All channels funnel into `saveOnMain`, which applies a channel-agnostic dedup gate: newer wins (>1s), first-writer wins within ±1s unless content differs, older always loses. The arbitration is already implemented (`shouldUpdate` + `lastValidTimestamp` fallback) — it's just not documented in one place. Write a short reference doc for future contributors. |

#### Observability / instrumentation

| Item | Priority | Notes |
|---|---|---|
| Log queue flush lag per delivery | Medium | Add `queue_flush_lag_seconds` to the existing `complication_did_receive_user_info` log line. Direct per-delivery WC queue dwell time; one-liner. |
| Log phone-side pipeline lag (HK write → transfer) | Medium | Add `hk_write_epoch_seconds` to the existing transfer log line. Measures phone-side HK → heartbeat → transfer latency, currently invisible. |
| Watch-side transfer completion outcome logging | Low–Medium | Watch-side `didFinishUserInfoTransfer` logs errors (with retry) but not successes. Phone-side `transfer_path` logging covers attempts. Gap: no watch-side success confirmation and no aggregate completion outcome accounting. Add a one-line success log to pair with the existing error path. |
| Synthesized freshness-state diagnostic event | Medium | Add one roll-up event at snapshot save and/or reload time with: source, `reading_epoch`, receive lag, snapshot age, reload age, queue depth, remaining complication budget, and whether the new snapshot replaced older data. Makes transport vs. WidgetKit debugging much faster than correlating narrow logs. |
| WidgetKit dispatch-to-callback black-box observability | Medium | Local reload management is well-instrumented (`coalescedReloadOnMain` logs debounce, trigger, retry skip/cancel). The blind spot is after dispatch: whether `WidgetCenter.reloadTimelines()` actually caused WidgetKit to call `getTimeline`, or was silently dropped/deferred. Investigation 2026-03-19 found that roughly 45% of logged reload dispatches were not followed by a corresponding `getTimeline` callback in the sampled 48h window (see `docs/investigations/`). Improve correlation between reload generation and `getTimeline` invocation to distinguish "fresh snapshot, stale UI" from "reload silently ignored by platform." |

*Shipped (build 144):* items **4G** (unified R4 `Transferred` log), **4H** (`queue_depth` in `complication_budget_check`), **4I** (skip reload retry when snapshot fresh) — see Shipped table and `observability/observability-implementation-log.md`. Optional Better Stack spot-checks vs [`build-144-plan.md`](build-144-plan.md) success criteria are not gating.

*Cross-reference:* Visible recency sawtooth metric reconstruction is specced as a standalone service in `docs/completed/nightscout-sawtooth-precompute/`. No Trio app changes required.

#### UX / patient safety

| Item | Priority | Notes |
|---|---|---|
| Staleness visual indicator on circular complication | Medium | Apply green/yellow/red recency colour to glucose text in `TrioAccessoryCircularView`. Corner view already has this. Circular face has no age signal at p90 `data_age` 510s. |
| Data age readout in watch debug view | Low | “Last updated Xs ago” backed by `lastDataReceivedAt` in debug screen. Handy for on-device validation after R5d without requiring a BetterStack round-trip. |

#### Platform / future work (explicitly out of scope for current freshness remediation)

| Item | Priority | Notes |
|---|---|---|
| Investigate feasibility of Background app refresh on watch (`WKApplicationRefreshBackgroundTask`) | Low–Medium | Scheduled wake-up to proactively pull data from the phone when all delivery channels (WCSession, HK observer, applicationContext) have gone silent. The App Group is written by the watch app process, so "check for fresh data already in App Group" is not the use case — the value is a fallback pull trigger when no push has arrived. Heavier and more speculative than R4/R5d follow-ups; defer until product priority (post–R5d gate completed 2026-03-21 per Process row). |
| `WKExtendedRuntimeSession` for urgent glucose | Out of scope | Separate project for critical low / rapid-fall scenarios. High value, high effort, but not part of the current complication freshness remediation backlog. Keep here only as a future adjacent project so it is not mistaken for the next remediation step. |

#### Process

| Item | Priority | Notes |
|---|---|---|
| Post-R4 + R5d freshness baseline re-measurement | **Completed** | **Done — no further action required** to close the initiative gate. Better Stack queries were run **2026-03-21 ~22:40 UTC** (~49.5h after build 143 deploy). Full metric table, R5d gap correlation, and transport assessment are recorded in **[`build-144-plan.md`](build-144-plan.md) §Prerequisites** (“Gate Results”). Outcome: `receive_lag` **pass** (sub-second); marginal p90 threshold misses on `save_age` / `reload_age` / `data_age` at getTimeline attributed to WidgetKit scheduling and overnight gaps — **transport judged healthy**; build 144 (4D–4I) proceeded without pulling deferred transport backlog items. Re-running the same queries later is **optional** (operational monitoring), not a backlog blocker. |

---

### Rejected ideas / not in current backlog (retained for traceability)

| Idea | Status | Reason not pursued |
|---|---|---|
| Nightscout precompute service in main Trio backlog | Rejected from this backlog | Useful, but it is a separate service in `cgm-remote-monitor`, not a Trio app change. Kept as a cross-reference rather than ranked beside Trio remediation work. |
| NSFileProtection audit + permanent startup log | Closed / Rejected | Investigation 2026-03-19: App Group container uses platform default `completeUntilFirstUserAuthentication` (Class C) — reads/writes succeed after first unlock, even when watch is subsequently locked. The only failure window is post-reboot/pre-first-unlock, which requires off-wrist (WCSession can't deliver anyway). Finding: safe, no follow-up needed. A permanent log line was also rejected — the answer doesn't change, so it would be noise. |
| CGM-only `readingDate` invariant audit as backlog item | Rejected | This is a code audit / validation task, not a user-facing feature. If it finds a bug, the bug belongs in backlog — not the audit itself. |
| Permanent WidgetKit `getTimeline` clustering log by family | Rejected | This is a one-time investigation to explain reload/getTimeline ratios, not an enduring product behavior change. Add temporarily if needed for investigation, not as a standing backlog item. |
| `Log isReachable duration at transfer` | Rejected | Lower actionability than queue depth, queue lag, pipeline lag, and completion outcome logging. Cut in favor of higher-signal observability. |
| Proactive watch-side pull on stale foreground / reconnect | Rejected for now | Overlaps with existing phone-side reachability-triggered push behavior and is less aligned with the user-facing “I opened Trio on my phone” scenario. Revisit only if post-R5d data shows a remaining reconnect-specific gap not covered by phone-side push. |
| Monotonic snapshot acceptance guard (as new work) | Already implemented | Pre-existing since build 130 (FP-Phase 3). See Shipped table. |

*Completed investigation reports are in [`docs/investigations/`](../investigations/).*

---

## Changelog

### v1.8 (2026-04-08 22:31 CET)
- **Backlog:** Proactive transfer row — added links to **proactive-transfer** initiative design + implementation plan (draft).
- Reason: promote backlog item to specced initiative without changing priority text.

### v1.7 (2026-04-08 22:26 CET)
- **Pending:** Wording updated from “build 143” to “through build 144” so it does not omit specced build 144 work (4D–4I).
- Reason: consistency with milestone history and `build-144-plan.md`.

### v1.6 (2026-04-08 22:20 CET)
- **Process:** Post-R4+R5d re-measurement marked **Completed** with pointer to `build-144-plan.md` gate results (~2026-03-21). Clarified that the work was already executed and recorded; optional re-queries are monitoring only.
- **Shipped table:** R4 row corrected (142–143); added 4G/4H/4I (build 144).
- **Backlog:** Removed observability rows superseded by 4G/4H/4I; added footnote. Updated “defer until post-R5d remeasurement” wording in remediation/platform rows to reference completed gate.
- Reason: align strategy doc with completed P0 gate and build 144; remove misleading “still to do” framing.

### v1.5 (2026-03-20 22:10 CET)
- Build 143 deployment update (deployed 2026-03-19 ~21:09 UTC, confirmed via Better Stack).
- Implementation Sequence: R5d marked ✅ SHIPPED (build 143); added notes for readingDate fixes, R4 handler upgrade, watch log flush, and WCSession crash guard (all build 143).
- Shipped table: Added 6 new rows — readingDate 1A/1B/1C fixes, R5d sleep-gap forced reload, R4 handler upgrade, watch log flush 4A/4B/4C, WCSession crash guard 5A/5B, Foundation.NotificationCenter shadowing fix.
- Pending section: Cleared (all planned items now shipped).
- Backlog: readingDate wall-clock bug struck through (shipped). Post-R4+R5d re-measurement upgraded to "NOW UNBLOCKED" with earliest measurement date 2026-03-21.
- Reason: reflect build 143 deployment completing the R1-R6 planned remediation sequence.

### v1.4 (2026-03-19 22:54 CET)
- Backlog (Observability): added item to emit `📤 Transferred new WatchState snapshot via=updateApplicationContext` alongside existing R4 `context_*` logs so Better Stack `transfer_via` can bucket `updateApplicationContext` like `sendMessage` / complication userInfo / `userInfo`.
- Reason: dashboard “Transfers / bucket” today relies on `transfer_via`; R4 success uses a different message shape unless extended.

### v1.3 (2026-03-19 16:45 CET)
- WidgetKit observability: softened "~45% silent drop rate" to "roughly 45% of logged reload dispatches were not followed by a corresponding getTimeline callback in the sampled 48h window" with pointer to investigation reports.
- Trimmed monotonic guard repetition: concise Shipped row, Rejected row now just points to Shipped table.
- Added investigations pointer (`docs/investigations/`) after Rejected section.
- Reason: review feedback on defensibility of claims, repetition across sections, and scattered investigation references.

### v1.2 (2026-03-19 16:22 CET)
- Monotonic snapshot acceptance guard: moved from Backlog to Shipped (pre-existing) — code audit confirmed `saveOnMain` already implements `shouldUpdate` + `lastValidTimestamp` across all channels.
- Cross-channel arbitration: rewritten from "define and implement arbitration logic" to "document existing channel-agnostic arbitration" (Low priority documentation task).
- Background app refresh: corrected description — the value is a scheduled proactive pull trigger when delivery channels are silent, not "check App Group for fresh data" (watch app is the App Group writer).
- WidgetKit reload observability: tightened scope to the WidgetKit dispatch-to-callback black box (local reload management is already well-logged). Referenced investigation finding (~45% silent drop rate).
- Reason: code audit confirmed two items were already implemented or misframed; two descriptions were inaccurate about the actual gap.

### v1.1 (2026-03-19 16:15 CET)
- Backlog restructured: flat table replaced with categorized sections (Shipped, Pending, unplanned backlog by category, Rejected ideas).
- Added readingDate wall-clock fallback bug (Medium-High) to Remediation follow-ups based on invariant audit finding 3 violations.
- NSFileProtection audit completed (safe, Class C) — moved from Process to Rejected/Closed with investigation finding.
- Added items from review: Adaptive budget throttling, Monotonic snapshot guard, Cross-channel arbitration, Synthesized diagnostic event, WidgetKit reload back-pressure observability, Background app refresh, iOS app foreground proactive transfer (restored original #4).
- Removed Nightscout precompute service from ranked backlog (cross-reference only), removed one-time investigations as standalone items.
- Upgraded Post-R4+R5d re-measurement to P0 gated on R5d.
- Reason: backlog review identified scope creep, missing items, priority gaps, and one-time investigations mixed with features.

### v1.0 (2026-03-19 11:30 CET)
- Initial creation: extracted problem summary, strategy, sequence, and backlog from remediation plan.
- Reason: provide a standalone reference for the problem and strategic approach as part of the docs reorganization.
