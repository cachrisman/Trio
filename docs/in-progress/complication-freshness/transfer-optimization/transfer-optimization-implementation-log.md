# Transfer Optimization — Implementation Log

**Version:** v1.2
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 15:08 CET

---

### Build 132 — Step 1: R1a + R1b + R5e (2026-03-09)

**Commit:** `917777267` on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09`
**Build:** 132 (v0.6.0) — deployed to TestFlight, 17m 58s total

**R1a — Reading epoch keys:** Confirmed working. BetterStack logs show `reading_epoch` and `transfer_enqueued_at` present in watch-side payload merge at 21:25:54 UTC.

**R1b — Stale queue drain:** Confirmed working.
- 21:23:53 UTC: Startup drain attempted, `queue_drain_skipped session_not_ready activation=2` — `isPaired` or `isWatchAppInstalled` was momentarily false during app launch.
- 21:27:45 UTC: Queue drain fired successfully via budget-exhausted call site: `cancel_requested=44 depth_before=45 depth_after=1 kept_epoch=0 kept_enqueued_at=0`. All queued items were pre-R1a (no epoch data); FIFO fallback kept last item.
- 21:27:54 UTC: Follow-up drain: `cancel_requested=1 depth_before=2 depth_after=1` — new transfer enqueued between drains, immediately cleaned.
- 21:30:57 UTC: Steady state: `queue_depth=2` (down from 46-48 pre-deploy).

**R5e — BetterStack alert:** Configured manually in BetterStack UI. Warning severity.

**Observation:** The startup drain in `session(_:activationDidCompleteWith:)` was skipped due to session readiness timing, but the budget-exhausted drain in `sendDataToWatch` caught it on the next transfer cycle. The queue-deep observation path (>5 items, 60s cooldown) was not needed — the budget-exhausted drain handled the entire frozen queue.

**Next gate:** Observe 24h to confirm `queue_depth` p95 < 5 before proceeding to Step 2.

---

### Build 133 — Step 2: R2a + R3 (2026-03-10)

**Commits:** `a69955c06` (Step 1 fix: paired/installed drain log + comment), `4bb1018f3` (R2a + R3) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick a69955c06,4bb1018f3`
**Build:** 133 (v0.6.0) — deployed to TestFlight, 16m 14s total

**R2a — Coalescer attribution:** Confirmed working. BetterStack logs show:
- `coalescer_trigger` events with source tags: `glucoseStored` (eligible=true), `orefDetermination`, `iobUpdate` (eligible=false).
- `coalescer_fired` events with full attribution: `trigger_count=7 sources=glucoseStored,glucoseStored,glucoseStored,orefDetermination,iobUpdate,orefDetermination,orefDetermination last_eligible_at=1773138464`.
- Typical pattern: 3 glucoseStored triggers + 3-4 orefDetermination/iobUpdate triggers per 5-minute cycle, coalesced into a single fire.

**R3 — Complication payload allowlist:** Confirmed working.
- Watch-side `saveComplicationSnapshot` receives exactly the 7 allowlisted keys: `transfer_enqueued_at, currentGlucoseColorString, currentGlucose, delta, reading_epoch, trend, date`.
- No `complication_payload missing key` warnings — all 7 keys present in every transfer.
- No `complication_transfer_skipped` events — `readingEpoch` is always present (R1a keys established in build 132).
- Payload reduced from ~19KB (full message) to ~200 bytes (allowlist only) for complication transfers.

**R1b — Queue health (continued):** Queue depth steady at 1-2, consistent with build 132 baseline. `queue_drain` events still firing normally: `cancel_requested=1 depth_before=2 depth_after=1`.

**Bug fixes included in this build (post-Step-1 review):**
- Queue-deep drain block moved outside reachability branches (runs after all transfer paths).
- `session.outstandingUserInfoTransfers.count` read moved inside `sessionIsReadyForTransfer()` guard.
- Watch-side `saveComplicationSnapshot` logs warning when falling back to build-time date (readingEpoch missing).
- `queue_drain_skipped` log now includes `paired=` and `installed=` detail.

**Next gate:** Observe 24h coalescer attribution data to determine whether Step 3 (R2b dispatch gate) alone resolves redundant transfers, or whether Step 4 (R2d source-eligible send mode) is also needed.

---

### Build 134 — Step 3: R2b dispatch gate (2026-03-11)

**Commits:** `89266f4c8` (R2b dispatch gate) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick 89266f4c8`
**Build:** 134 (v0.6.0) — deployed to TestFlight

**R2b — Per-reading-epoch dispatch gate:** Implemented.
- `lastDispatchedGateKey`: App Group-backed computed property using `appGroupIDCandidate()` (same helper used for generation counter diagnostics — known-good pattern).
- `computeDispatchGateKey(state:)`: Builds gate key as `"(epoch)|(currentGlucose)|(trend)|(delta)"` using `max(by: date)` for epoch (matching R1a). All fields are `String?` on `WatchState` — no locale sensitivity risk.
- Gate logic in `sendDataToWatch`: computed after `saveLatestDateToDisk`, before `sendMessage`. `sendMessage` always fires. Complication transfer gated on both `readingEpochPresent` and `!isDuplicateDispatch`. Logs `complication_transfer_gate_skipped` with gate key when duplicate detected.

**Code review feedback — Round 1 (Claude, 6 points evaluated):**

1. **`appGroupIDCandidate()` safety** — Confirmed: same helper used elsewhere in `AppleWatchManager` (line 192, generation counter). Falls back to `""` if nil (gate passes everything through). **No change needed.**
2. **Gate key write on non-duplicate only** — Confirmed correct: `lastDispatchedGateKey` only written when `!isDuplicateDispatch`. **No change needed.** (But see Round 2 #1 — this turned out to be in the wrong location.)
3. **Locale sensitivity risk on gate key fields** — Non-issue: `currentGlucose`, `trend`, `delta` are all `String?` on `WatchState` (pre-formatted). Epoch uses `String(Int(...))` (locale-safe). **No change needed.**
4. **Budget cycle reset — gate doesn't clear on new cycle** — Gate key persists in App Group UserDefaults indefinitely. After a budget cycle reset (~2.5h), if glucose hasn't changed, the first transfer of the new cycle would be suppressed. **Fix applied:** Added `lastDispatchedGateKey = ""` in `session(_:activationDidCompleteWith:)` so the first post-launch transfer always fires.
5. **`sendMessage` always fires** — Confirmed correct: gate only affects `transferCurrentComplicationUserInfo` and `transferUserInfo` paths. **No change needed.**
6. **Log noise from gate-skip on reachable/missing-epoch paths** — `isDuplicateDispatch` log fires even when complication transfer would have been suppressed by other conditions. Acceptable for debugging. **No change needed.**

**Code review feedback — Round 2 (ChatGPT, critical bug found):**

1. **🚨 Gate key advanced on sendMessage-only (reachable) path** — `lastDispatchedGateKey = gateKey` was written unconditionally before the reachability check. When the watch is in foreground (`isReachable == true`), `sendMessage` fires but no complication transfer occurs — yet the gate key is consumed. When the watch later goes to background for the same reading, the gate sees "duplicate" and suppresses the complication transfer. This directly undermines freshness during the foreground→background transition that users actually hit. **Fix applied:** Moved `lastDispatchedGateKey = gateKey` to immediately after each actual enqueue call (`transferCurrentComplicationUserInfo` and `transferUserInfo`), so the persisted key truly means "we successfully attempted a complication transfer." Gate key computation and duplicate check remain unconditional for logging/debugging. Placement after (not before) the enqueue is a defensive measure — if a future refactor adds an early return in the block, the gate key won't be prematurely consumed.
2. **Activation clear is a blunt instrument** — Clearing the gate on every activation effectively resets persistence across restarts. Accepted tradeoff: the gate's primary value is preventing duplicate transfers *within a session*, not across restarts. A TTL-based approach could be added later if needed.
3. **Suite instability** — `appGroupIDCandidate()` returns a deterministic value from Info.plist or bundle ID. Won't change between calls in the same app lifecycle. Non-issue.
4. **Gate key write placement: after enqueue, not top of block** — Reinforced that the write should be immediately after the actual `transferCurrentComplicationUserInfo` / `transferUserInfo` call, not at the top of the conditional block. This ensures the persisted key reflects an actual transfer attempt, making the code robust against future refactors that might add early returns.
5. **`!isReachable` gate on complication transfers** — Questioned whether gating complication transfers on `!session.isReachable` is intentional. **Confirmed as deliberate budget conservation:** when the watch app is foregrounded (`isReachable == true`), `sendMessage` updates the watch UI for free and the complication is not visible to the user. Firing `transferCurrentComplicationUserInfo` would waste budget on invisible updates. `transferCurrentComplicationUserInfo` works regardless of reachability (not an API limitation), but calling it only when not reachable is the correct design choice. Added explicit code comment documenting this rationale.

**Observation:** The Round 2 bug (#1) was the most critical finding across both reviews. The failure mode (foreground `sendMessage` consumes the gate, suppressing the first background complication transfer for the same reading) would have been triggered on every foreground→background transition where the reading hadn't changed — a common real-world scenario.

**Next gate:** Build + deploy, then observe 48h BetterStack data for `complication_transfer_gate_skipped` frequency and avg C/reading.

---

### Builds 137-138 — Step 3b: Complication-age stale-first budget gate (2026-03-12/13)

**Commits:** `e32d87cac` (Step 3b: stale-first gate T=600s), `03da1ac79` (age gate fix + diagnostic logging Parts A+B+C) on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` regenerated
**Build:** 137 (initial), 138 (with cloud logging fixes)

**Step 3b — Complication-age stale-first budget gate:** Implemented. When the complication data is older than 600s (T=600s), complication transfers are prioritized over `sendMessage`. This ensures budget is spent on the complication path when the data is stale, rather than being consumed by `sendMessage` deliveries to the watch app (which updates the watch UI but not the complication).

**Age gate fix (build 138, `03da1ac79`):** Parts A+B+C — fixed age gate logic and added diagnostic logging to track gate behavior in production.

---

### Builds 137-138 — Cloud logging pipeline fixes (2026-03-12/13)

**Scope:** Logging pipeline fixes — not a complication-freshness step, but directly impacts Step 4 decision gate.
**Design doc:** `docs/completed/logging-fixes/logging-fixes-design-doc.md` v1.11
**Implementation plan:** `docs/completed/logging-fixes/logging-fixes-implementation-plan.md` v1.14
**Patches:** `06-cloud-logging.patch` and `09-watch-complication-improvements.patch` regenerated via `mid-stack-update.sh --from-feature-branch`

**Build 137 (Phase 1, 2026-03-12):** Embed `[b:BUILD]` in all log lines, parser/uploader extraction, retention reduction (7d→48h, 20→10 files), upgrade-time flush on both watch and phone, app launch sentinels, drain file ACK fix (`batchAck` dispatch in WatchState + `transferUserInfo`-based confirmation).

**Build 138 (Phase 2, 2026-03-13):** Cleanup observability (`[CLEANUP]` tags on all 7 deletion sites, `[INVENTORY]` daily health check, inline metrics with cached counts, retention summaries), `DateFormatter` caching in SimpleLogReporter and WatchLogger, watch debug view LOG FILES section, `flushToPhone` crash-safety fix (write-before-send durability).

**Impact on complication-freshness observation:**
- Before build 137, avg C per build was unreliable: `CloudLogUploader.buildCommonAttributes()` stamped `build` from `Bundle.main` at upload time. Backlogged watch logs (drain files up to 7 days old, pending payloads) were attributed to the uploading build, not the originating build. This was discovered when build 136 avg C data included events from March 10-11 with `dt` predating deployment.
- Build 137+ embeds the true build in each log line at write time. `parseWatch()` and `parseIOS()` extract it; `CloudLogUploader` uses parsed build when present, falls back to `Bundle.main` for old-format lines.
- The Step 4 decision gate (avg C > 1.3?) should query build >= 137 data only. Earlier builds have contaminated build attribution.

**Next gate:** Observe 48h from build 137 deployment (2026-03-12). Run avg C query ~2026-03-15. If avg C <= 1.3: skip Step 4, proceed to Step 5 (R4). If avg C > 1.3: implement Step 4 (R2d).

---

### Step 4 Gate — Avg C Analysis (2026-03-17)

**Decision: Skip Step 4 (R2d). Proceed to Step 5 (R4).**

BetterStack query run against build ≥ 137 data (2026-03-12 onward), S3 + hot storage. Results by day:

| Day | Total Transfers | Unique Readings | Avg C (all) | Complication Path | UserInfo Path | Budget Exhausted Events | Budget-OK Avg C |
|---|---|---|---|---|---|---|---|
| 2026-03-12 | 598 | 283 | 2.11 | 0 | 598 | 598 | n/a (0 budget-ok transfers) |
| 2026-03-13 | 1182 | 284 | 4.16 | 0 | 1182 | 1182 | n/a (0 budget-ok transfers) |
| 2026-03-14 | 677 | 236 | 2.87 | 308 | 369 | 369 | 1.94 |
| 2026-03-15 | 648 | 224 | 2.89 | 330 | 318 | 318 | 2.04 |
| 2026-03-16 | 189 | 178 | **1.06** | 111 | 78 | 78 | **0.77** |
| 2026-03-17 | 61 | 62 | **0.98** | 13 | 48 | 48 | **0.34** |

**Interpretation:**

- **Mar 12–13:** Budget exhausted 100% — zero complication-path transfers, all via userInfo fallback. These days don't reflect steady-state behavior; they show the exhaustion state before R6 + R6.1 were active.
- **Mar 14–15:** Build 141 landing late on Mar 14; mix of build 140 (no R6.1) and 141. Budget still partially exhausted; elevated avg C.
- **Mar 16–17:** Build 141 dominant. Avg C drops to 1.06 / 0.98 overall; budget-ok avg C drops to 0.77 / 0.34. Both are well below the 1.3 gate threshold.

**Gate result:** Avg C ≤ 1.3 on build 141 data. R2d criterion not triggered. Step 4 skipped. Next step: Step 5 (R4 — `updateApplicationContext` safety net).

---

### Bug fix — Reachability gate on `transferUserInfo` fallback (2026-03-19)

**Commit:** `a33ddc4b6` on `feature/watch-complication-improvements`
**Patch:** `09-watch-complication-improvements.patch` (regenerated 2026-03-19 11:37 CET)
**Build:** 142 — deployed

**Discovery:** A code audit of `sendDataToWatch` revealed that the budget-exhausted `transferUserInfo` fallback was nested inside `if !session.isReachable, readingEpochPresent, !isDuplicateDispatch { ... }`. When `isReachable == true` and budget was exhausted, `sendMessage` fired but no `transferUserInfo` was enqueued for background complication refresh.

**Audit findings (6 questions answered):**

1. Three `isReachable` references in `sendDataToWatch`, all if-statements. The main reachability gate at line 821 controlled all complication transfer paths.
2. `transferUserInfo` was inside the `!isReachable` block, in the `else` clause of `if budgetSnapshot > 0`. Unreachable when `isReachable == true`.
3. `cancelStaleQueuedTransfers()` had two call sites: one inside the `!isReachable` block (budget-exhausted), one outside (queue-deep drain).
4. No path existed for `isReachable == true` + `remaining == 0` + `!isDuplicateDispatch` to enqueue a `transferUserInfo`.
5. The `complication_transfer_skipped_reachable` log fired for the budget-exhausted case, misleadingly implying the skip was intentional.
6. Full trace for the buggy scenario: `sendMessage` fires, three log lines, entire complication block skipped, `lastDispatchedGateKey` not updated. Zero complication transfers enqueued.

**Changes (single file: `AppleWatchManager.swift`):**

1. **Hoisted `budgetSnapshot`** above the `isReachable` block so logging references it.
2. **Split `complication_transfer_skipped_reachable` log** into:
   - `complication_transfer_skipped_reachable` (budget > 0)
   - `complication_budget_exhausted_reachable` (budget == 0)
3. **Flattened `!isReachable` block** — now contains only the budgeted path with `budgetSnapshot > 0` in the compound condition.
4. **Extracted budget-exhausted fallback** into an independent block: `if budgetSnapshot == 0, readingEpochPresent, !isDuplicateDispatch { ... }` — no reachability condition.

**Not changed:** `transferCurrentComplicationUserInfo` stays inside `!isReachable`. `cancelStaleQueuedTransfers()` remains immediately before `transferUserInfo`. Queue-deep drain block untouched. Age gate logic untouched.

**BetterStack validation (build 142, 2026-03-18/19 UTC):**

Two confirmed instances of `complication_budget_exhausted_reachable` in production:

**Instance 1 — 2026-03-18 22:47:07 UTC:** Full sequence in the same second:
1. `complication_budget_check remaining=0 isReachable=true readingEpochPresent=true isDuplicate=false`
2. `sendMessage_sent reading_epoch=1773873646`
3. `complication_budget_exhausted_reachable remaining=0 - userInfo fallback will enqueue`
4. `Transferred new WatchState snapshot via=userInfo budget_exhausted=true queue_depth=1`

**Instance 2 — 2026-03-18 23:15:52 UTC:** Identical sequence — budget check (remaining=0, reachable=true), sendMessage, budget-exhausted log, transferUserInfo enqueued with queue_depth=1.

Both instances confirm the fix is working: when `isReachable == true` and budget is exhausted, `sendMessage` fires AND `transferUserInfo` is enqueued in the same call. The `complication_transfer_skipped_reachable` log (budget > 0 variant) also continues to fire correctly — e.g. 2026-03-19 13:36 UTC shows `remaining=43`, confirming it only logs when budget is available.

Queue health remains clean: all budget-exhausted transfers show `queue_depth=1` or `queue_depth=2`, consistent with the R1b drain working as designed.

---

## Changelog

### v1.2 (2026-03-19 15:08 CET)

- Updated bug fix entry: status changed from "committed" to "deployed (build 142)". Added patch reference, BetterStack validation with two confirmed production instances showing the fix working correctly.
- Reason: fix was included in patch 09 and deployed as build 142; production logs confirm the reachable + budget-exhausted path now enqueues `transferUserInfo`.

### v1.1 (2026-03-19 15:03 CET)

- Added "Bug fix — Reachability gate on `transferUserInfo` fallback" entry.
- Reason: record the audit findings, code changes, and next steps for the bug where the budget-exhausted fallback was gated behind `!isReachable`.

### v1.0 (2026-03-19 11:33 CET)

- Extracted from complication-freshness-remediation-plan.md v1.56 during docs reorganization.
