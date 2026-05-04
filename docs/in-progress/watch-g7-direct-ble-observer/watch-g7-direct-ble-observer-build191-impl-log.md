# Build 191 — Implementation log

**Version:** 1.3  
**Status:** Complete (code + verification notes + post-review follow-ups + soak snapshot)  
**Last updated:** 2026-05-03 10:13 CET  

---

## Scope

Implementation executed per [watch-g7-direct-ble-observer-build191-impl-plan.md](watch-g7-direct-ble-observer-build191-impl-plan.md) (plan v1.7). All feature commits touch **only** `Trio/Trio Watch App Extension/G7DirectBLEObserver.swift` on branch **`feature/watch-g7-direct-ble-observer-synthesis`** (Trio worktree).

## Pre-ship / companion work (outside this branch)

- **Confirm before tagging build 191:** `06-cloud-logging.patch` has been regenerated from `feature/cloud-logging` (BetterStack dedup / `CloudLogUploader.uploadRotatingPair()`). User indicated this is **already completed** — no implementation in this branch.
- After ship + midnight rotation: Tier 0 / Tier 2 dedup verification per plan §7 and §9.

## Commits (11)

Rows **1–10** match plan §6 order; row **11** is a post-plan follow-up on the same branch and file.

| # | Subject (short) | SHA (short) |
|---|-----------------|-------------|
| 1 | peripheral-identity guards in CB callbacks | `a1961324d` |
| 2 | connectInFlight guard and lifecycle clears | `1e9ae62dd` |
| 3 | isDiscoveringServices re-entry gate | `37c12b685` |
| 4 | retrieveConnectedPeripherals(dataService) first in attach ladder | `f3913e089` |
| 5 | named timing constants; connectTimeout 8s | `3b2d73857` |
| 6 | authFallbackDelay 2s | `2623720ef` |
| 7 | discoveryTimeoutInterval 15s | `77979da5c` |
| 8 | unified scheduler (fast retry + moderate wait) | `f1ff7c71e` |
| 9 | re-register connection events on foreground entry | `51e062517` |
| 10 | daily BLE counters (UserDefaults + WatchState mirror) | `fbf5e737c` |
| 11 | post_egv_disconnect attribution + remove dead `failedAttempts` | `bdd368447` |

**Commit 11 notes (red-team / soak correctness):**

- **`post_egv_disconnect`:** In `didDisconnectPeripheral`, scheduler reason **`post_egv_disconnect`** when `sessionEGVCount > 0` **only** (no `error == nil` requirement). CoreBluetooth often passes a non-nil `CBError` on clean sensor disconnects; the prior condition hid the plan §8 success-path signature.
- **`failedAttempts`:** Removed property and all reset sites — grep showed **no read sites** after `scheduleReconnect` removal; counter was dead state.

## Behavioral notes (implementation)

- **Scheduler:** `scheduleReconnect` removed; `scheduleNextAttempt(reason:)` implements 2s fast retry / 15s moderate wait after 5 consecutive scheduler retries since last EGV; `fastRetryCount` reset on EGV in `handleGlucose`; disconnect uses **`post_egv_disconnect`** when **`sessionEGVCount > 0`** (follow-up `bdd368447`); otherwise `pendingTerminalReason ?? "disconnect"` (preserves e.g. `connect_timeout` when still set before `emitSessionOutcome`). Scheduler reason is still captured **before** `emitSessionOutcome`.
- **Anchors for build 192:** `lastCBEventAt` updated on every `.peerConnected` (including before self-loop guard); `lastSuccessfulEGVAt` set from `reading.readingDate` on counted EGV.
- **Daily counters:** Keys under `G7DailyCounterKeys`; `loadDailyCounters()` after `CBCentralManager` init; `loadDailyCountersIfNewCalendarDay()` on foreground queue before CB registration / `startOrResume`; increments on matching `didConnect`, non-dedup `handleGlucose`, and each `.peerConnected` connection event; mirrored to `WatchState.shared` on MainActor after persist.

## Verification performed (no Xcode build)

- Static re-read of final `G7DirectBLEObserver.swift` for lifecycle ordering (disconnect scheduler reason capture before `emitSessionOutcome`).
- Tier 0–style greps (counts/literals): single declarations for `connectTimeout == 8`, `authFallbackDelay == 2`, `discoveryTimeoutInterval == 15`; `scheduleNextAttempt` present; `scheduleReconnect` absent; exponential backoff pattern absent; three `peripheral_mismatch` logs; two `fastRetryCount = 0` sites (`handleGlucose`, moderate-wait branch).
- **Not run:** `xcodebuild`, `ci/local-build.sh`, `scripts/patch-test.sh` (patch stack unchanged in this session; AGENTS.md rule 10).

## Build 191 soak results (2026-05-02 19:00 → 2026-05-03 06:32 UTC, ~11.5h)

**Tier 1 — confirmed:**
- `g7_ble_scheduler` events present from first session; both `mode=fast_retry` and
  `mode=moderate_wait` observed within the first hour.
- `connect_skipped reason=already_connecting`: **35 events** — `connectInFlight` guard
  working; parallel attach ladders eliminated.
- `opcode=0x05` observed within first soak window (19:07 UTC, ~7 min after deploy).

**Tier 2 — confirmed:**
- `mode=moderate_wait fast_retry_count=5`: threshold fired **29 times** — scheduler
  threshold logic correct.
- `connect_timeout` avg duration: **58s** (down from 292s in build 190, −80%).
  Min 8013ms confirms the 8s timeout fires correctly; post-cancel CB callback delivery
  accounts for remaining duration.
- `post_egv_disconnect` reason: **10 occurrences** — post-success fast-retry path
  working correctly.
- CB `peer_connected` events: **75** over 11.5h, alive across process restarts.
- `auth_fallback_no_egv` avg duration: **164s** (down from 518s in build 190).
- No peripheral mismatch events; no discovery re-entry events.

**Tier 3:**
- **5 EGVs** received (vs 2 in build 190 over a comparable window).
  All via `0x05` auth-payload path; avg session duration 8.5s.
  Sequences: 1616, 1621, 1628, 1629, 1738.
- Overnight gap (seq 1629 → 1738, ~9h) unchanged — background execution budget
  problem; not addressed by build 191. Build 192 (H2 inter-window sleep) is the
  next step.

## Red-team review (prompt 05 summary)

- **Passes:** Three adversarial passes over scheduler ordering, disconnect vs pending terminal reason, mismatch guards vs `connectInFlight`, discovery gate vs resume paths, counter increments vs dedup EGV path, foreground registration ordering.
- **Findings:** No blocker or major defect requiring code change; **minor nit:** plan text names `SchedulerMode` — implementation uses file-private `G7BLESchedulerMode` to avoid generic name clashes (behavior identical).
- **Follow-ups shipped after review:** `post_egv_disconnect` attribution corrected (`bdd368447`); `failedAttempts` removed after grep confirmed no readers (`bdd368447`).
- **Residual:** Compile proof and soak Tier 1–3 criteria remain **user / device** validation.

## Open / remaining items

1. Human Tier 0 checklist in plan §7 (grep locations + BetterStack dedup after rotation).
2. Local **`ci/local-build.sh`** (user flags) before tagging build 191.
3. Confirm **`06-cloud-logging.patch`** state at tag time (pre-ship gate).

---

## Changelog

### v1.3 (2026-05-03 10:13 CET)
- Added **Build 191 soak results** (~11.5h UTC window): Tier 1–3 confirmations, metrics vs build 190, **`post_egv_disconnect` (10 occurrences)** in Tier 2, overnight-gap pointer to build 192 (H2). 

### v1.2 (2026-05-02 19:23 CET)
- Merged commit **11** (`bdd368447`) into the single commits table; retained notes under **Commit 11**. Reason: one authoritative list for all build 191 branch commits touching `G7DirectBLEObserver.swift`.

### v1.1 (2026-05-02 19:22 CET)
- Documented follow-up commit `bdd368447`: `post_egv_disconnect` uses `sessionEGVCount > 0` only (CB often reports non-nil error on clean disconnect); removed dead `failedAttempts` after grep showed no read sites.
- Renamed commits section for clarity; refreshed behavioral notes and red-team section to match shipped code.

### v1.0 (2026-05-02 18:54 CET)
- Initial implementation log: ten commits, verification notes, red-team summary, pre-ship `06-cloud-logging.patch` reminder, open items.
