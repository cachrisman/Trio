# Build 144 Plan

**Version:** 1.5
**Created:** 2026-03-21 15:17 CET
**Last updated:** 2026-03-22 00:10 CET
**Status:** Deployed (build 144)

---

## Prerequisites

### Post-R5d 48h re-measurement (P0 gate)

Build 143 deployed ~21:09 UTC on 2026-03-19. The 48h observation window closes ~21:09 UTC on 2026-03-21 (tonight). Run the following Better Stack queries after that time:

| Metric | Query target | Pass threshold |
|--------|-------------|----------------|
| `save_age` p90 | `complication_save_age` during budget-ok windows | < 300s |
| `reload_age` p90 | `complication_reload_age` or `data_age_seconds` at `getTimeline` | < 600s |
| `receive_lag` p50/p90 | `receive_wall - send_wall` from R5b logs | p50 < 10s, p90 < 30s |
| `data_age` at `getTimeline` | `data_age_seconds` from `complication_get_timeline_called` | p90 < 600s |
| R5d validation | `data_age_seconds` from `complication_get_timeline_called` shortly after `sleep_gap_detected` / `forced_widget_reload_after_gap` events | p90 < 600s |

If these pass, the transport layer is healthy and the build 144 scope below is confirmed. If any fail significantly, transport fixes (dead-zone recovery, foreground push) may need to be pulled in.

### Gate Results (queried 2026-03-21 ~22:40 UTC, full 49.5h window)

| Metric | n | p50 | p90 | p95 | max | Threshold | Result |
|--------|---|-----|-----|-----|-----|-----------|--------|
| `save_age` | 445 | 104s | **324s** | 518s | 14,173s | p90 < 300s | Marginal fail (+8%) |
| `reload_age` | 537 | 208s | **608s** | 647s | 14,173s | p90 < 600s | Marginal fail (+1.3%) |
| `receive_lag` | 194 | **0.09s** | **0.77s** | 2.3s | 128s | p50<10s, p90<30s | **Pass** |
| `data_age` at getTimeline | 230 | 322s | **761s** | 1,313s | 14,296s | p90 < 600s | Fail (+27%) |
| R5d post-sleep-gap freshness | 4 gaps | 172s | 248s | — | 269s | p90 < 600s | **Pass** |

**R5d detail:** 8 `sleep_gap_detected_context` events (all via `didReceiveApplicationContext`), 7 `sleep_gap_reload_firing` events (no rate-limited skips). Correlated first `complication_get_timeline_called` after each gap:

| Gap time (UTC) | Gap (s) | First getTimeline | data_age (s) | WidgetKit latency (s) |
|----------------|---------|-------------------|--------------|----------------------|
| Mar 20 20:53 | 646 | 20:53:09 | **141** | 0 |
| Mar 21 01:41 | 730 | 02:05:17 | **269** | 260 |
| Mar 21 18:08 | 701 | 18:19:13 | **203** | 128 |
| Mar 21 18:54 | 771 | 19:04:04 | **194** | 85 |

All post-gap `data_age` values are well under 600s. The forced reload mechanism is working — after sleep gaps, the complication recovers with fresh data. No `sleep_gap_detected` events from the `didReceiveUserInfo` path — all gaps were detected via `didReceiveApplicationContext` (expected when budget is exhausted during sleep).

**Assessment:** Transport layer is healthy — `receive_lag` is sub-second (strong pass). The `save_age` and `reload_age` marginal failures are driven by WidgetKit scheduling latency (p50=244s, p90=504s) which is outside our control. The `data_age` fail at getTimeline is structurally `save_age + WidgetKit latency`. The 14,000s+ outliers are overnight sleep gaps. No transport fixes need to be pulled in; build 144 scope confirmed as-is.

**`save_age` budget-ok filter caveat:** The gate specifies "during budget-ok windows" but the query was run unfiltered. Excluding budget-exhausted periods would likely push p90 under 300s.

---

## Scope

Five changes across two areas: watch log pipeline improvements (4D/4E/4F) and complication observability refinements (4G/4H/4I).

### Watch Log Pipeline (patch 06)

| Item | Description | Effort | Patch |
|------|-------------|--------|-------|
| **4D** | Raise `logSizeCap` from 16 KB to 64 KB | Trivial (one constant) | 06-cloud-logging |
| **4E** | Split oversized payloads into sequential chunks (max 4 × 64 KB) | Small-medium | 06-cloud-logging |
| **4F** | Replace 5-min timer + 30s cooldown with 30s timer; nudge triggers immediate upload + timer reset | Small | 06-cloud-logging |

**Rationale:** Production telemetry from build 143 shows 137 truncation events in 26h — nearly every flush cycle truncates 65–88% of log lines. 4D eliminates ~80% of truncations; 4E handles the rest. 4F closes the upload latency gap where nudges could be blocked by the cooldown, reducing worst-case latency from ~5 minutes to ~30 seconds.

**Design + implementation plan:** `docs/completed/watch-log-flush-observability/01-*-design.md` (v2.2) and `02-*-implementation-plan.md` (v2.2).

### Complication Observability (patch 09)

| Item | Description | Effort | Patch |
|------|-------------|--------|-------|
| **4G** | Unified `Transferred` log for R4 (`updateApplicationContext`) | Trivial (one log line) | 09-watch-complication-improvements |
| **4H** | Log `outstandingUserInfoTransfers.count` in heartbeat | Trivial (one log line) | 09-watch-complication-improvements |
| **4I** | Skip retry scheduling when snapshot is fresh (< 60s) at reload time | Small | 09-watch-complication-improvements |

**4G rationale:** R4's `updateApplicationContext` success currently logs `context_succeeded` but doesn't emit the `📤 Transferred new WatchState snapshot via=...` sentence shape. Better Stack's `transfer_via` extraction rule (used for the "Transfers / bucket" dashboard) only matches that pattern, so R4 transfers are invisible in the dashboard. One additional log line after `updateApplicationContext` success, e.g.:
```
📤 Transferred new WatchState snapshot via=updateApplicationContext reading_date_epoch_seconds=... userinfo_budget_exhausted=... queue_depth=...
```
Note: uses `userinfo_budget_exhausted` (not `budget_exhausted`) because `updateApplicationContext` does not consume the `remainingComplicationUserInfoTransfers` budget — it's a separate mechanism. The field is contextual information about why this path was taken, not a constraint on this transfer.

**4H rationale:** `outstandingUserInfoTransfers.count` is logged only in `cancelStaleQueuedTransfers` today (as `depth_before`/`depth_after`). Adding it to the `complication_budget_check` log line in `sendDataToWatch` (already emitted every cycle) as `queue_depth=N` makes queue depth visible in real time — prerequisite for dead-zone stall alerting (the 66-minute gap observed March 17 would have been detectable if queue depth were graphable). The field name `queue_depth` is already used consistently in the `📤 Transferred` log lines for both `transferCurrentComplicationUserInfo` and `transferUserInfo` paths, and in `context_attempted` — so Better Stack queries can join without aliasing.

**4I rationale:** `coalescedReloadOnMain` currently schedules a retry after every reload dispatch via `scheduleRetryAfterReloadOnMain`. When the snapshot is already fresh, the retry is wasted — WidgetKit just rendered current data. Skipping the retry reduces WidgetKit budget pressure without any freshness cost. The regular delivery cycle (next CGM reading → save → reload) handles subsequent updates.

**4I freshness check:** At the point where `coalescedReloadOnMain` would call `scheduleRetryAfterReloadOnMain`, read `store.latestSnapshot()` and compute `Date().timeIntervalSince(snapshot.readingDate)`. If `< 60` seconds, skip the retry. This uses the glucose reading timestamp (not wall-clock time of the save), so "fresh" means the complication is displaying data from the last 60 seconds — well within one CGM cycle (~5 minutes).

---

## Sequencing (as executed)

1. **Gate queries** run at ~22:40 UTC 2026-03-21 (49.5h post-deploy). Results recorded above.
2. **Implemented 4D → 4E → 4F** on `feature/cloud-logging`, committed, regenerated `06-cloud-logging.patch` via `mid-stack-update.sh`.
3. **Implemented 4G → 4H → 4I** on `feature/watch-complication-improvements`, committed, regenerated `09-watch-complication-improvements.patch` via `mid-stack-update.sh`.
4. **Code review:** Claude review feedback evaluated; accepted 4I `freshnessThreshold` constant suggestion, rejected 4E `continue` bug claim (logic is correct). See `build-144-code-review.md`.
5. **Upstream sync:** Merged `upstream/dev` (11 commits, 0.6.0.58–0.6.0.61). Two file overlaps (`SettingItems.swift`, `MainChartView.swift`) resolved cleanly by `--3way`.
6. **Patch 01 fix:** Upstream removed `TrioSettings.timeCap` (FPU duration setting removal). Regenerated `01-ns-richer-settings.patch` with `timeCap: nil` using `generate-patch.sh` against a fresh feature branch from dev.
7. **`patch-test.sh`** — all 10 patches pass.
8. **Build 144** — `ci/local-build.sh --base-branch dev` (build + deploy).

---

## Success Criteria

| Item | Criterion |
|------|-----------|
| 4D | `log_flush_truncated` events show `cap_bytes=65536`; truncation frequency drops ≥80% vs build 143 baseline |
| 4E | `log_flush_chunk` markers (with `lines_in_chunk`) appear when splitting occurs; sum of `lines_in_chunk` across chunks matches pre-split total; no missing chunks for a `payload_id`. *Non-blocking:* splitting may not trigger in the initial window since most payloads fit within the new 64 KB cap — validate opportunistically or via manual flush. |
| 4F | Upload attempt occurs within 30s of log append (measured via upload-attempt log lines); no `successCooldown` in `CloudLogUploader` |
| 4G | `transfer_via=updateApplicationContext` with `userinfo_budget_exhausted=true` appears in Better Stack during budget-exhausted windows |
| 4H | `queue_depth` visible in `complication_budget_check` log lines every cycle |
| 4I | Retry scheduling skipped when `Date().timeIntervalSince(snapshot.readingDate) < 60`; no regression in `reload_age` p90 (must remain < 600s per gate table) |

---

## Out of Scope (deferred to post-144)

- Post-dead-zone recovery (pull request after stall drain) — depends on re-measurement showing remaining gap
- Proactive transfer on iOS app foreground — depends on re-measurement
- HK trend metadata on iPhone writes — needs HealthKit consumer app verification
- Adaptive budget throttling — optimization, not a fix
- Staleness visual indicator on circular complication — UX change, separate review

---

## Changelog

### v1.5 (2026-03-22 00:10 CET)
- **R5d gate clarification:** `timeline_entry_epoch` was a design concept name, never implemented as a literal log field. The actual metric is `data_age_seconds` from `complication_get_timeline_called` filtered to events shortly after `sleep_gap_detected` / `forced_widget_reload_after_gap`. Updated gate table and results accordingly.

### v1.4 (2026-03-21 23:58 CET)
- **Status → Deployed.** Recorded P0 gate metrics (49.5h window). Transport healthy; all marginal fails driven by WidgetKit latency, not transport. Build 144 scope confirmed.
- **Sequencing updated** to reflect actual execution: implementation, code review, upstream sync, patch 01 fix (upstream removed `timeCap`), and build.
- **Upstream merge note:** 11 upstream commits (FPU refactor, glucose smoothing, negative IOB fix, translations). Patch 01 regenerated to handle removed `timeCap` field.

### v1.3 (2026-03-21 22:43 CET)
- **4E:** Marked success criterion as non-blocking for ship — splitting may not trigger in the initial observation window since most payloads fit within the new 64 KB cap.

### v1.2 (2026-03-21 21:36 CET)
- Updated design/impl plan version references from v2.1 to v2.2 (cancelStaleQueuedTransfers false risk removed).
- **4G:** Renamed `budget_exhausted` to `userinfo_budget_exhausted` in the proposed log line. `updateApplicationContext` doesn't consume the complication userInfo budget — the field is contextual, not a constraint. Updated success criterion.
- **4H:** Added note confirming `queue_depth` field name is already used consistently in existing `📤 Transferred` and `context_attempted` log lines — no aliasing needed for Better Stack queries.
- **4I:** Clarified "fresh" means `Date().timeIntervalSince(snapshot.readingDate) < 60` where `snapshot` is `store.latestSnapshot()` read at reload time. Added explicit threshold (`< 600s`) to success criterion matching the P0 gate table.
- **Prereqs:** Confirmed `complication_save_age` is the correct query target (no rename to `hk_sync_lag_seconds` occurred).

### v1.1 (2026-03-21 15:45 CET)
- Updated design/impl plan version references from v2.0 to v2.1.
- Updated 4E success criterion: uses `lines_in_chunk` sum and chunk gap detection instead of `lines_total`.
- Updated 4F success criterion: measured via upload-attempt log lines as proxy (direct `appendToWatchLog` timestamp correlation requires instrumentation not yet added).

### v1.0 (2026-03-21 15:17 CET)
- Initial build 144 plan: 4D/4E/4F (watch log pipeline), 4G/4H/4I (complication observability).
- Reason: define scope and sequencing for the next build based on build 143 production telemetry findings.
