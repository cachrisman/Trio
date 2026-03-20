# Nightscout sawtooth precompute — implementation log

**Version:** 1.2  
**Last updated:** 2026-03-20 21:58 CET  
**Plan reference:** `nightscout-precompute-implementation-plan.md` (v1.13+)

This document records what was built and what changed compared to the implementation plan. Implementation lives in **cgm-remote-monitor** (Nightscout): `bin/sawtooth-precompute.js` (one-shot), `bin/sawtooth-clock.js` (Heroku clock loop), `lib/sawtooth-precompute/*.js`.

---

## 14.1 Initial implementation (2026-03-16)

- **Added:** `bin/sawtooth-precompute.js` (entrypoint, .env loader), `lib/sawtooth-precompute/run.js`, `fetch-gtl-logs.js`, `parse-message.js`, `dedupe.js`, `push-metrics.js`, `state.js`, `lib/sawtooth-precompute/README.md`.
- **State:** Single checkpoint `last_emitted_minute_epoch`; file backend (lock file, atomic write) or MongoDB (same collection, single doc).
- **Flow:** loadState → emit ceiling → GTL query (S3 union when window > 40 min) → parse → dedupe → ASOF loop → pushGauges → saveState. Cold start WARN when checkpoint 0.
- **Better Stack:** Query API pinned to JSONEachRow; ingest POST to `BETTERSTACK_INGEST_HOST/metrics` with Bearer token.

---

## 14.2 Review round 1 — static code review (F1–F8)

- **F1 (idempotency):** Introduced `pending_through_minute`: save before push, recover on load by promoting to `last_emitted_minute_epoch` so next run does not re-send. *(Superseded in round 2.)*
- **F2 (cleanup):** Wrapped post-loadState path in `try/finally { await state.close(); }` so lock/lease and Mongo connection always released.
- **F3 (stale lock):** Lock file stores `{ pid, ts }`; on EEXIST, reap if pid dead or ts > 5 min, then retry.
- **F4 (corrupt state):** `loadStateFile()` throws on read/parse failure instead of returning 0 (fail closed).
- **F5 (Mongo overlap):** Lease document (`_id: 'lease'`, pid, ts) acquired before load, released in `close()`; duplicate instance fails with "lease held."
- **F6 (lock retry):** Busy wait replaced with `await sleep(ms)`; `acquireFileLock()` async.
- **F7 (observability):** Single log line: `gtl_rows=N parsed=P deduped=D skipped_no_anchor=S emitted=E`. *(Superseded by §14.7 — success path now one `pushed` line including those counters plus `end_minute` and anchor/emit-delay fields.)*
- **F8 (dedupe):** Comment added: "any off-wrist wins" and mixed-group semantics per design §4.2.

---

## 14.3 Review round 2 — ChatGPT (two-phase state, lock lifecycle, end_minute)

- **Two-phase recovery (correctness):** Replaced single `pending_through_minute` with:
  - **`preparing_through_minute`** — set *before* push; on recovery, do **not** advance; clear only. Ensures push failures do not cause permanent dropped minutes.
  - **`pushed_through_minute`** — set *after* successful push (before final checkpoint write); on recovery, advance `last_emitted_minute_epoch` and clear. Ensures "push OK, checkpoint save failed" is recovered without re-sending.
- **File lock lifecycle:** `saveState()` for file backend no longer releases the lock; only `close()` releases. Lock is held for the entire run (load → … → push → save checkpoint → close), preventing a second cron run from starting mid-push and incorrectly promoting `preparing` on recovery.
- **end_minute alignment:** `end_minute = Math.max(0, Math.floor((wall_now - 60 - emit_delay_seconds) / 60) * 60)` so the emit ceiling is always on a minute boundary regardless of `SAWTOOTH_EMIT_DELAY_SECONDS`.
- **Mongo lease:** `MONGO_LEASE_EXPIRY_MS` increased from 2 min to 5 min to cover worst-case run (query + push + DB latency).

---

## 14.4 Review round 3 — file lock race, Mongo lease atomicity, residual risk

- **File lock stale-reap race:** When lock file was unreadable or invalid JSON, the code previously unlinked immediately. Another process could reap a lock that was just created (gap between `openSync('wx')` and `writeSync(meta)`). **Fix:** If read/parse fails, check lock file mtime; only reap if mtime is older than `LOCK_CREATION_GRACE_MS` (15 s). Unreadable-but-recent files are left alone.
- **Mongo lease takeover:** Replaced `updateOne` + `findOne` with **findOneAndUpdate** with expiry predicate and `returnDocument: 'after'`. Acquisition is atomic: we only consider the lease ours if the atomic update returned our pid.
- **Residual risk documented:** §12 now states that if push succeeds but saving `pushed_through_minute` fails, the next run retries the range and duplicate emission can occur; accepted as rare, documented residual risk for v1.

---

## 14.5 Post-review nits and README (2026-03-16)

- **README — Heroku:** Chose dedicated worker dyno (Option C) as the project's approach. Added step-by-step instructions: Config Vars, Procfile `sawtooth` process (`while true; do node bin/sawtooth-precompute.js; sleep 60; done`), scale `sawtooth=1`, cold start (mongosh upsert). Dropped Options A (Scheduler) and D (external cron/CI); kept Option B (in-process) as a short alternative.
- **README — Mongo protection:** Wording updated to "deploy only one worker or cron; the code also enforces a lease so only one writer runs at a time" (Cron section and Heroku section).
- **README — Loop drift:** Noted that the worker loop runs every run-duration + 60s, not exactly every wall-clock minute; checkpoint/emit-ceiling logic safely catches up.
- **README — Limitations (v1):** New section documenting the residual duplicate-send edge (push OK, process exits before persisting `pushed_through_minute` → retry may resend); stated as documented v1 limitation.
- **bin/sawtooth-precompute.js:** Comment that .env load is for local dev only (Heroku injects Config Vars); second line noting the parser is minimal and may mishandle inline comments, escaped quotes, and multiline values.
- **state.js — acquireMongoLease():** Removed redundant tail (both branches threw the same error); single throw after confirming we don't own the lease.

---

## 14.6 Node clock loop for Heroku (2026-03-16)

- **Replaced** bash loop `while true; do node bin/sawtooth-precompute.js; sleep 60; done` with a Node-based clock: `bin/sawtooth-clock.js`.
- **Clock behavior:** Waits until the next wall-clock minute boundary (e.g. :00 seconds), runs `run()` once, then waits for the next boundary — no drift. Does not start another run until the current one completes (no overlap). On SIGTERM, sets a flag and exits after the in-flight run completes so Heroku can shut the dyno cleanly (exit 0).
- **Procfile:** `sawtooth: node bin/sawtooth-clock.js` (no bash).
- **README:** Heroku §2 updated to describe the clock script (wall-clock alignment, no overlap, SIGTERM); Procfile example and wording updated. One-shot `bin/sawtooth-precompute.js` remains for cron (VPS) and manual runs; Mongo checkpoint/lease logic unchanged.

---

## 14.7 Observability, README versioning, agent docs (2026-03-20)

- **Success logging:** Removed per-run `sawtooth-precompute start` and the separate post-query `gtl_rows=…` line. After checkpoint succeeds, **one** `sawtooth-precompute pushed …` line includes `gtl_rows`, `parsed`, `deduped`, `skipped_no_anchor`, `minutes`, `end_minute`, `anchor_gtl_epoch`, `anchor_gtl_age_seconds`, `emit_delay_actual_seconds` (sentinel `-1` on anchor fields when nothing emitted). `wall_at_push` is sampled immediately before the log.
- **Skip:** Unchanged: `sawtooth-precompute skip (nothing to do)`.
- **README (`lib/sawtooth-precompute/README.md`):** Document-only **Version** / **Last updated** at top and **Changelog** at bottom (not a runtime semver). Observability section documents the line shape and example Better Stack metric extractions (`gtl_rows` and `minutes` parsed from the same `pushed` line).
- **Repo root:** `AGENTS.md` and `docs/betterstack-guide.md` added in cgm-remote-monitor for Cursor/agent habits (secrets, MCP, ClickHouse notes) without referencing other product repos by name.

---

## 14.8 Dynamic emit delay, off-wrist fix, query retry (2026-03-20)

Several runtime improvements shipped in cgm-remote-monitor `lib/sawtooth-precompute/` (README v2–v5). These change behavior relative to the original design's fixed emit delay and off-wrist semantics.

### Dynamic emit delay (`run.js`)

- **Replaced** the fixed `emit_delay_seconds` with a rolling-max-based dynamic delay. Each run measures `data_horizon_lag` = `wall_now - max(dt)` across all GTL rows returned by the query. Observations are stored in an in-memory rolling window (`lagObservations`) over `SAWTOOTH_LAG_WINDOW_SECONDS` (default 3 h). `effective_emit_delay` = `rolling_max(data_horizon_lag) + SAWTOOTH_LAG_BUFFER_SECONDS` (default 120 s). Falls back to `SAWTOOTH_EMIT_DELAY_SECONDS` on cold start (no observations yet).
- **Drain lag cap** (v3): Observations above `MAX_PLAUSIBLE_DRAIN_LAG = 1800` (30 min) are excluded from the rolling window. Gaps larger than that are WidgetKit freezes (no GTL events fired), not log drain latency. Without this cap, a multi-hour freeze would inflate `effective_emit_delay` for hours after recovery.
- **Cron vs clock loop**: The dynamic delay requires the persistent clock loop (`sawtooth-clock.js`) to accumulate observations across runs. Cron deployments (new process each run) always use the cold-start fallback since the lag tracker is in-memory and resets on process restart.

### Config parsing fix (`run.js`)

- **`envInt()` helper** replaces `parseInt(env) || DEFAULT`, which incorrectly treated `0` as falsy and fell back to the default. Setting `SAWTOOTH_EMIT_DELAY_SECONDS=0` (backfill) or `SAWTOOTH_LAG_BUFFER_SECONDS=0` now works correctly.

### New env vars

| Variable | Default | Description |
|----------|---------|-------------|
| `SAWTOOTH_LAG_WINDOW_SECONDS` | 10800 | Rolling window (seconds) for data-horizon-lag observations. |
| `SAWTOOTH_LAG_BUFFER_SECONDS` | 120 | Buffer added on top of `lag_window_max` to compute `effective_emit_delay`. |

### New log fields

Both the `pushed` and `skip` log lines now include: `effective_emit_delay`, `data_horizon_lag`, `lag_window_max`, `lag_obs`. See README v5 for field reference and metric extraction expressions.

### Off-wrist detection narrowed (`dedupe.js`)

- **`battery_state=unknown`** no longer triggers `is_off_wrist`. Only `charging` and `full` (both mean the watch is on its charger) do. This diverges from the original design (§4.2) which treated `unknown` as off-wrist; in practice, `unknown` is common during WatchOS complication/provider restarts and was causing false zero periods on the sawtooth.
- **`battery_state=full`** added as off-wrist (the watch reports `full` when charged and still on the charger).

### Transient query retry (`fetch-gtl-logs.js`)

- `queryGtlLogs` now retries once (`MAX_RETRIES = 1`) with a 5 s delay on transient errors (ETIMEDOUT, ECONNRESET, ECONNREFUSED, HTTP 503, generic timeout) before throwing. Non-transient errors throw immediately. Logs a WARN on retry attempts.

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.2 | 2026-03-20 21:58 CET | §14.8 — dynamic emit delay (rolling max + drain lag cap + config parsing fix), off-wrist narrowed to charging/full (unknown is on-wrist), transient query retry in fetch-gtl-logs; new env vars and log fields. |
| 1.1 | 2026-03-20 11:15 CET | §14.7 — consolidated `pushed` log, README doc versioning, cgm-remote-monitor AGENTS + betterstack-guide; §14.2 F7 footnote to §14.7. |
| 1.0 | 2026-03-17 | Extracted from implementation plan §14; standalone implementation log for what was done vs plan. |
