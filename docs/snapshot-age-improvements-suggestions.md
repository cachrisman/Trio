# Watch Complication snapshot_age_seconds: Improvement Suggestions

**Version:** 1.2  
**Date:** 2026-03-08  
**Context:** Follow-up to the patch-application/chat transcript and the complication freshness plan; focuses on improving the `snapshot_age_seconds` metric and reducing perceived complication staleness (e.g. "+8m" recency when the app shows fresher data).

---

## 1. Summary and Log Evidence (Better Stack)

Logs from the Trio source (Better Stack, last ~18h hot buffer) show how `snapshot_age_seconds` behaves today.

### 1.1 Snapshot save and reload age

**Query:** Messages containing `snapshot_age_seconds` or `Snapshot saved` or `reload_snapshot_age`.

| Event | Example log message | Interpretation |
|-------|---------------------|----------------|
| Save (good) | `✅ Snapshot saved: glucose=95, trend=Flat, delta=+8, snapshot_age_seconds=9` | Data reached watch quickly; age at write is 9s. |
| Save (bad) | `✅ Snapshot saved: glucose=77, trend=FortyFiveDown, delta=-20, snapshot_age_seconds=229` | Data was already ~4 min old when saved (e.g. queued during unreachability). |
| Reload age | `🔔 reload_snapshot_age_seconds=310` | WidgetKit reload ran when the *current* snapshot was already 310s old. |
| Reload age | `🔔 reload_snapshot_age_seconds=439` / `440` | Same; reloads sometimes occur with 7+ min old snapshot. |

**Observed save-time ages:** 9, 10 (good); 87, 105, 229 (poor — data delayed).  
**Observed reload-time ages:** 9, 16 (good); 87, 137, 229, 310, 405, 406, 439, 440 (poor).

So both “how old the data was when we saved it” and “how old the data was when we asked WidgetKit to reload” vary a lot; high values correlate with the “+8m” staleness reported in the transcript.

Note: WCSession delivery, system wake budgets, and iOS connectivity are outside the app's full control; the app does not control the WCSession send queue end-to-end. The app's contribution is robust queue drain on wake and not adding artificial delays.

### 1.2 Reload and debounce pattern

**Query:** Messages containing `Reload`, `DEBOUNCED`, or `forceReload`.

| Pattern | Example | Interpretation |
|--------|---------|----------------|
| Debounce working | `⏳ Reload DEBOUNCED: 0s elapsed (min: 5s)` | Extra reloads within 5s correctly suppressed. |
| Retry firing | `🔄 Reload TRIGGERED: 6s since last reload (retry)` | Retry 31s after a reload adds another `reloadTimelines` call. |
| Multiple triggers | `🔄 Reload TRIGGERED: 300s since last reload` then retry at 286s | Each successful reload schedules a retry, increasing total reload volume. |

So: debounce (e.g. 5s) is helping, but every coalesced reload still schedules a retry ~31s later, which can contribute to WidgetKit budget pressure and reloads that sometimes run when the snapshot is already old (high `reload_snapshot_age_seconds`).

---

## 2. Code References (Where snapshot_age_seconds and Recency Live)

| Concern | File / location |
|--------|------------------|
| **Logging snapshot age at save** | `TrioComplicationDataStore.swift` — `saveOnMain`: `ageSec = Int(Date().timeIntervalSince(snapshot.readingDate))`; log line `Snapshot saved: ... snapshot_age_seconds=\(ageSec)` (~507). |
| **Logging snapshot age at reload** | `TrioComplicationDataStore.swift` — `reloadTimeline()`: `reload_snapshot_age_seconds=\(Int(Date().timeIntervalSince(lastTS)))` (~621–622). |
| **Recency in UI** | `TrioWatchComplication.swift` — `TrioAccessoryCornerView`: `age = entry.date.timeIntervalSince(entry.readingDate)`; `shortRelativeTime(from: entry.readingDate, now: entry.date)` (~208–215). |
| **Timeline entries** | `TrioWatchComplication.swift` — `getTimeline`: 30 entries with `entryDate = now + minuteOffset*60`, same `snapshot.readingDate` for all (~146–165). |
| **Reload after save** | `TrioComplicationDataStore.swift` — `saveOnMain`: after write, `coalescedReloadOnMain(minInterval: minInterval)` (~509–510). Default `minInterval` 30; watch passes 5 in `WatchState.saveComplicationSnapshot`. |
| **Retry after reload** | `TrioComplicationDataStore.swift` — `coalescedReloadOnMain`: `scheduleRetryAfterReloadOnMain(minInterval)` (~593–594); `forceReloadOnMain`: `scheduleRetryAfterReloadOnMain(minInterval: 30)` when `scheduleRetry` true (~614–615). |
| **Watch save path** | `WatchState.swift` — `saveComplicationSnapshot(from:)`: builds snapshot with `readingDate` from message, `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` (~611–646). |
| **Force reload path** | `WatchState.swift` — `forceComplicationUpdate()`: uses `TrioComplicationDataStore.lastValidTimestamp` only for `effectiveReadingDate`; `save(..., triggerReload: false)` then `forceReload(scheduleRetry: false)` (~673–694). |

---

## 3. Top 5 Improvement Suggestions

### 3.1 Reduce reload volume and retry semantics (high impact)

**Problem:** Every coalesced reload schedules a retry ~31s later. Logs show “Reload TRIGGERED … (retry)” and reloads with high `reload_snapshot_age_seconds` (310, 406, 439s). More `reloadTimelines` calls increase WidgetKit budget use and can lead to reloads that run when the snapshot is already old, without improving freshness.

**Evidence (Better Stack):**

- `🔄 Reload TRIGGERED: 6s since last reload (retry)` — retry adds a second reload per cycle.
- `🔔 reload_snapshot_age_seconds=310` / `439` — reloads often run with 5–7 min old snapshot.

**Code references:**

- `TrioComplicationDataStore.swift`: `coalescedReloadOnMain` calls `scheduleRetryAfterReloadOnMain` whenever it triggers a reload (~593–594). `forceReloadOnMain` does the same when `scheduleRetry` is true (~615).

**Suggestions:**

1. **Make retry conditional or opt-in:** e.g. schedule retry only when `snapshot_age_seconds` at reload time is above a threshold (e.g. > 60), or add a parameter so the main “new data just saved” path does not schedule a retry.
2. **Cap retries:** at most one retry per “generation” (already partially enforced by `reloadGenerationToken`); consider no retry when the snapshot was already fresh at reload time (e.g. age &lt; 60s).
3. **Document:** “Reloads per reading” should account for 1 initial + 1 retry when projecting WidgetKit budget (as in red-team feedback).

**Reconnect / catch-up behavior:** The platform handles reconnect and catch-up via queued WatchConnectivity delivery and by waking the watch app with `WKWatchConnectivityRefreshBackgroundTask` when payloads are delivered. A separate app-level reconnect signal is not required. If post-reconnect staleness persists, investigate `handle(_:)` / `hasContentPending` / drain behavior rather than adding reachability callbacks (e.g. `WCSession.sessionReachabilityDidChange`), which are unreliable across watchOS versions.

**Expected impact:** Fewer `reloadTimelines` calls, less budget exhaustion, reloads more likely to occur when they materially improve freshness; `reload_snapshot_age_seconds` distribution should improve over time as a result.

---

### 3.2 Use a single, CGM-based source of truth for recency (high impact)

**Problem:** Recency (and thus perceived “freshness”) must always reflect the CGM reading time (`readingDate`), not phone or watch wall-clock build/transfer time. Any fallback to `lastWatchStateUpdate` or `Date()` as “reading date” can make stale data look fresh (e.g. “0m”).

**Evidence (from transcript/red-team):**

- Plan and red-team called out: `WatchState(date: Date())` and fallbacks like `lastValidTimestamp ?? lastWatchStateUpdate ?? .distantPast` risk using transport/write time instead of sensor time.
- Current `forceComplicationUpdate` already guards: `guard let effectiveReadingDate = TrioComplicationDataStore.lastValidTimestamp else { return }` and does not use `lastWatchStateUpdate` for readingDate — good.

**Code references:**

- `WatchState.swift` ~673–678: `forceComplicationUpdate` uses only `lastValidTimestamp` for `effectiveReadingDate`.
- `TrioWatchComplication.swift` ~38–47: `TrioWatchComplicationEntry(snapshot:)` uses `snapshot.readingDate`; ~208–215: recency = `entry.date.timeIntervalSince(entry.readingDate)` and `shortRelativeTime(from: entry.readingDate, now: entry.date)` — i.e. recency is driven by `readingDate` and the entry’s `date`.
- `TrioComplicationDataStore.swift` ~506–507: `snapshot_age_seconds` is `Date().timeIntervalSince(snapshot.readingDate)` — correct (CGM reading time).

**Suggestions:**

1. **Audit all readingDate sources:** Ensure every path that sets `readingDate` in a snapshot (message, userInfo, forceComplicationUpdate, fallbacks) uses a CGM-derived timestamp only; never use “message received time” or “WatchState build date” as readingDate.
2. **Keep forceComplicationUpdate strict:** Do not reintroduce `lastWatchStateUpdate` (or any `Date()`) as a fallback for `effectiveReadingDate`.
3. **Document:** “All recency and snapshot_age_seconds use CGM readingDate only; transport/write timestamps are for telemetry only.”

**Expected impact:** Recency and `snapshot_age_seconds` consistently reflect true data age; no “0m” on stale data.

---

### 3.3 Make recency advance with timeline entries (medium–high impact)

**Problem:** The complication shows recency as `entry.date - entry.readingDate` with `shortRelativeTime(from: entry.readingDate, now: entry.date)`. So recency is tied to the **entry’s** `date`, not the device “now”. If WidgetKit keeps showing the same entry for several minutes (e.g. due to budget or `.after(refreshInterval)`), the displayed “+2m” won’t advance to “+3m” until a new timeline is requested or a new entry is chosen.

**Evidence (logs + code):**

- Logs show high `reload_snapshot_age_seconds` (310–440s), i.e. long gaps between reloads; during those gaps the user may see a frozen recency.
- Transcript: user saw “+8m” on the complication, then opening the app showed fresher data; returning to the watch face then showed an updated complication — consistent with “reload finally happened” and/or “new entry chosen”.

**Code references:**

- `TrioWatchComplication.swift` ~146–165: `getTimeline` builds 30 entries with `entryDate = now.roundedDownToMinute + minuteOffset*60` and same `snapshot.readingDate`; policy `.after(nextRefresh)` with `refreshInterval = 300` (5 min).
- ~208–215: `age = entry.date.timeIntervalSince(entry.readingDate)`; `timeText = shortRelativeTime(from: entry.readingDate, now: entry.date)`.

**Suggestions:**

1. **Rely on entry.date as intended:** The 30 entries (one per minute) are designed so that as WidgetKit advances the displayed entry over time, recency should increase (+0m, +1m, +2m …) without a reload. Verify in practice that the system does advance the displayed entry; if it does not, document as a platform limitation.
2. **Optional: shorten refreshInterval only after measuring reload budget:** Red-team noted that lowering `refreshInterval` (e.g. to 120–180s) could increase timeline requests and share the same budget as `reloadTimelines`. Only consider reducing it after Phases 1–4 have reduced reload count and we have metrics (e.g. reloads per hour).
3. **Logging:** When building the timeline, log (or metric) the snapshot age at timeline build time so we can correlate “timeline requested” with “how old was the data?” (similar to `reload_snapshot_age_seconds`).

**Expected impact:** Clearer understanding of whether “+8m” is due to (a) not advancing entries, (b) not reloading, or (c) data actually 8 min old; if (a), platform or policy changes can be targeted.

---

### 3.4 Treat snapshot_age_seconds as an observable metric (medium impact)

**Problem:** Today `snapshot_age_seconds` appears only in log messages. To validate improvements and set SLAs, we need a way to aggregate and track it (e.g. p50/p95/p99, or at least counts above thresholds).

**Evidence (Better Stack):**

- Save: `snapshot_age_seconds=9` vs `229` — wide spread.
- Reload: `reload_snapshot_age_seconds=9` vs `439` — same.

**Code references:**

- `TrioComplicationDataStore.swift` ~505–507 (save); ~621–622 (reload).

**Suggestions:**

1. **Structured logging or metrics:** Emit a structured field (e.g. `snapshot_age_seconds`, `event=save` or `event=reload`) so Better Stack (or another pipeline) can aggregate.
2. **Use in validation:** Define targets (e.g. “p95 save age &lt; 120s”, “p95 reload age &lt; 180s”) and track after each change (dedup, retry policy, phone-side coalescing).
3. **Red-team alignment:** Matches “Metrics to add: complication_snapshot_age_seconds (p50/p95/p99)” and “reload_requests_total by type”.

**getTimeline / budget characterization:** `reloadTimelines` calls can be coalesced or throttled by the system; they are not 1:1 with `getTimeline` executions. A persistent large divergence from baseline between reload requests and `getTimeline` calls is the signal of budget exhaustion (not "first reload after reset"). Expect coalescing; measure distribution and baselines rather than raw 1:1 equality.

**Expected impact:** Data-driven validation of fixes; ability to detect regressions and set clear freshness goals.

---

**Freshness decomposition (empirically derived, 2026-03-08):**

    save_age        ≈ WatchConnectivity queue flush lag
                      (receive→save ≈ 0s; save_age is almost entirely the time
                      the data spends queued in WatchConnectivity before the
                      watch session activates and drains it)

    reload_age      ≈ save_age + save→reload delay
                      (save→reload ≈ 0s median; bounded by 5s coalescer)

    wrist freshness ≈ reload_age + WidgetKit scheduling latency
                      (provider latency: p50 ~101s, p90 ~440s; ~32% coalescing rate)

Observed baselines (12h, 2026-03-08, hot+S3):

    save_age:    p50 ~161s,  p90 ~437s
    reload_age:  p50 ~278s,  p90 ~543s
    WC reachability: 62–68% of transfers find watch not immediately reachable (active hours)

The dominant controllable lever is WatchConnectivity session activation latency.
WidgetKit scheduling is the secondary delay and is largely platform-constrained.
Use Phase 2.3 per-reading join queries to update these baselines after Phase 3 ships.

---

### 3.5 Harden dedup and out-of-order handling (medium impact)

**Problem:** When the watch receives many queued payloads (e.g. after being unreachable), out-of-order or duplicate deliveries can overwrite newer data or cause duplicate saves (each triggering a reload). Dedup and “newer-wins” must be robust so that (1) we don’t replace newer data with older, and (2) we don’t do redundant saves that increase reload volume and worsen `reload_snapshot_age_seconds`.

**Evidence (transcript + red-team):**

- Transcript: “14 Received userInfo within same second” on wake; “8 snapshot saves and 4 FORCE reloads within 7 seconds” for one reading.
- Red-team: Date equality without tolerance fails after ISO8601 round-trip (sub-second); dedup comparing raw message glucose to stored value can be wrong if stored value is sanitized (“153” vs “153 mg/dL”); didReceiveUserInfo and didReceiveMessage use different dedup keys so the same reading can be applied twice.

**Code references:**

- `TrioComplicationDataStore.swift` ~432–453: `saveOnMain` — future-skew guard; cold-start seed; newer-wins (`timeDiff < 0` reject); duplicate skip with 1s tolerance and full display-field equality (glucose, trend, delta, glucoseColor, state); fallback to `lastValidTimestamp` for older rejection. Snapshot is built from already-sanitized `TrioComplicationSnapshot` in this path.
- `WatchState.swift` ~611–646: `saveComplicationSnapshot(from:)` builds snapshot from raw message (glucose, trend, delta, readingDate); no sanitization before building snapshot — but the snapshot’s `glucose` is set from `glucoseValue` and `TrioComplicationSnapshot` init sanitizes it (~27–28 in DataStore). So when we compare in `saveOnMain`, we compare `existing.glucose` (sanitized) to `snapshot.glucose` (sanitized in init). So for the watch path the comparison is consistent. The red-team concern was about a *phone-side* guard comparing unsanitized to sanitized; if we add guards in WatchState before calling save(), we must compare sanitized-to-sanitized or use a full snapshot equality.
- Date: `saveOnMain` uses `timeDiff = snapshot.readingDate.timeIntervalSince(existing.readingDate)` and `timeDiff < 1.0` for duplicate window — so we use a 1s tolerance, not exact equality. Good.
- `latestSnapshot()` and `lastValidTimestamp` are written from both watch app and complication extension; red-team suggested single writer and monotonic lastValidTimestamp.

**Suggestions:**

1. **Keep dedup in saveOnMain:** All “newer-wins” and duplicate detection remain main-thread, atomic with the write (as today), so no TOCTOU between “check” and “write”.
2. **Unify dedup key across message and userInfo:** Use a single “last processed reading date” (or reading date + hash of display fields) in App Group storage, updated by both didReceiveMessage and didReceiveUserInfo, so the same reading isn’t applied twice via different paths.
3. **Any new guard that compares message fields to “last snapshot”:** Compare sanitized-to-sanitized (e.g. build a `TrioComplicationSnapshot` from the message and use `==` or the same 1s + display-field logic as in `saveOnMain`).
4. **lastValidTimestamp:** Only update when the new value is strictly newer than the current value (monotonic); consider documenting that both processes can read it but only the “writer” of the snapshot file should advance it after a successful write.

**App Group cross-process locking:** Do not use `flock` or other POSIX file locks for App Group cross-process synchronization on watchOS; on Darwin they do not provide cross-process mutual exclusion for App Group storage. Prefer monotonic guards and accept TOCTOU risk where acceptable. `NSFileCoordinator` is an option but can block the complication provider and risk WidgetKit timeouts. Default to monotonic guards unless proven necessary.

**Expected impact:** Fewer duplicate saves and reloads; no regression to older data when out-of-order or duplicate payloads arrive; better `snapshot_age_seconds` at save (fewer redundant writes) and at reload (fewer reloads).

---

## 4. Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-27 | Initial document: transcript context, Better Stack log evidence, code refs, top 5 suggestions (retry/reload volume; CGM-only recency; timeline recency; snapshot_age_seconds as metric; dedup/out-of-order). |
| 1.1 | 2026-03-04 | Phase 1.1 doc corrections: §1.1 Bucket 1 scope (WCSession/wake budget note); §3.1 Reconnect/catch-up behavior; §3.4 getTimeline/budget characterization; §3.5 App Group locking (no flock/POSIX; monotonic preferred). |
| 1.2 | 2026-03-08 | §3.4: Added freshness decomposition formula block (Phase 2.3.4) with empirically derived baselines (save_age, reload_age, WC reachability) and the key insight that WatchConnectivity session activation latency is the dominant controllable lever. |
