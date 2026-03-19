# Complication Freshness — Problem and Strategy

**Version:** 1.0
**Created:** 2026-03-19 11:30 CET
**Last updated:** 2026-03-19 11:30 CET

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
R5d  (sleep-gap forced reload)                                       pending (Step 6)
```

---

## Backlog

| Idea | Status | Disposition |
|---|---|---|
| #4 Proactive transfer on iOS app foreground | Not implemented | Deferred — re-evaluate after R4 and R6.1 observation windows close |
| #6 Log `isReachable` duration at transfer | Not implemented | Low effort; add `lastReachabilityChangeDate: Date?` to `AppleWatchManager` |
| #8 sendMessage latency instrumentation | ✅ Shipped (build 141) | R5b — `sendMessage_sent` / `didReceiveMessage` wall-clock timestamps |
| #12 Coalescer trigger count + source logging | ✅ Shipped (build 133) | R5a / R2a |
| #13 Lightweight complication payload | ✅ Shipped (build 133) | R3 |
| #16 Sleep-gap forced reload | Not implemented | R5d — pending (Step 6) |
| #19 `WKExtendedRuntimeSession` for urgent glucose | Not implemented | High value for urgent-low; significant effort; separate project |
| #21 `didReceiveUserInfo` decode latency | ✅ Shipped (build 141) | R5c — `userInfo_decoded` with threaded `fromUserInfo` / `userInfoReceiveTimestamp` |
| #24 Consistent `reading_epoch` across pipeline | ✅ Shipped (build 141) | Closed by R5a (build 133) + R5b (build 141) |
| #28 WidgetKit `getTimeline` call clustering | Partial | Generation counter present; per-family clustering untracked; low priority |
| #30 Scheduled freshness alert | ✅ Shipped (build 132) | R5e |
| HealthKit background delivery on watch | ✅ Shipped (build 140) | R6 — live; `hk_observer_fired` confirmed |
| HealthKit channel improvements (anchored query, trend, observability) | ✅ Shipped (build 141) | R6.1 — anchored query, trend derivation, phantom fire classification |

---

## Changelog

### v1.0 (2026-03-19 11:30 CET)
- Initial creation: extracted problem summary, strategy, sequence, and backlog from remediation plan.
- Reason: provide a standalone reference for the problem and strategic approach as part of the docs reorganization.
