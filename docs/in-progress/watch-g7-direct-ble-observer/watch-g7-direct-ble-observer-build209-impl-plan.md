> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 209 — Implementation plan

**Version:** 1.0 (implementation started — confirmed scope only; Section A stays soak-gated)
**Status:** IN PROGRESS — Sections B/C implemented; **Section A soak verdicts RESOLVED 2026-06-14**
(see below). A-driven scope changes for **209**: drop `.peerConnected` (A1), **keep** CB restore path
(A2 — cancels a planned deletion), un-shelve connect-gate (A5). New findings: **A6** (06-13 full-day
direct-BLE outage — root cause is the upstream Dexcom-watch-app session dependency, NOT Trio
dormancy) and **A7** (direct-BLE-stall detection — a **210 candidate**, not 209).
**Created:** 2026-06-11 06:00 CEST
**Last updated:** 2026-06-14 15:20 CEST

## Implementation items (C-209-N)

| # | Source | What | Files | Status |
|---|---|---|---|---|
| C-209-1 | B1 | Denominator: incremental → analytical (delete timer machinery, edge-event ineligible tracking) | `G7WatchSensorAdapter`, `ComplicationDebugView`, `WatchState` | **done** (f1b6450b7) |
| C-209-2 | B2 + triage #2 | Daily-log batching per flush; hoist `createDirectory`; `print()` → DEBUG-only | `WatchLogger` | **done** (f4ae97537) |
| C-209-3 | triage #1 | Demote shipping meta-chatter (~70% of volume) to counters + one summary line per flush; keep error/timeout lines | `WatchLogger` | **done** (f4ae97537) |
| C-209-4 | triage #3 | Background-aware flush interval (180s fg → 600s bg/no-session) | `WatchLogger`, `TrioWatchApp` scene hook | **done** (f4ae97537) |
| C-209-5 | B6 | Battery-context accuracy: enable monitoring at launch; state TTL 15s (level stays 60s); `battery_src=` tag on complication-path lines | `WatchLogger`, `ComplicationLogBuffer`, `ExtensionDelegate` | **done** (f4ae97537) |
| C-209-6 | B7 / review 1.10 | `sanitizedGlucose` mmol + comma fix (+ tests where runnable) | `TrioComplicationDataStore` | **done** (f4ae97537) |
| C-209-7 | B7 / review 5.9 | Unserviced-reload detector: widget persists observed generation; app re-requests once at +120s if unserviced | `TrioComplicationDataStore`, widget provider | **done** (f4ae97537) |
| C-209-8 | B7 / 5.10, 6.9, 6.10, 6.11 | Hygiene: cold-start content compare; `lastValidTimestamp` via `onMain`; in-memory retry-skip; `.bak` every 10th save; delete dead `save()` | `TrioComplicationDataStore` | **done** (f4ae97537) |
| C-209-9 | review 6.8 | History-store inserts → `queue.async` | `WatchGlucoseHistoryStore` | **done** (f4ae97537) |
| C-209-10 | B4 | C1 comment scope correction | `G7WatchSensorAdapter` | **done** (f4ae97537) |
| C-209-11 | B3 | Fork: background GATT-skip knob (skip backfill-subscribe + extended-version when host backgrounded) | fork `G7Sensor`/`G7Telemetry` + adapter | **code done + fork pushed + patch-02 repinned** (`3287f4c`); patch-12 regen remains |
| C-209-12 | B5 / review 1.5 | Fork: `Data.to()` bounded rewrite | fork `Common/Data.swift` | **done** — fork `3287f4c` pushed |

**Deliberately deferred from C-209-8:** moving save I/O off-main — the store's main-thread
confinement is a documented invariant (`assert(Thread.isMainThread)` throughout); changing it
needs its own design pass, not a hygiene batch.

**Sources:** [trio-fable5-review.md](../trio-fable5-review.md) v2.2 (open findings),
`TRIO_REVIEW_CONTEXT.md` v3, the build-208 impl plan/log, the complication-debug-view
denominator investigation (2026-06-11), and the watch-feature-ideas menu
([upstream-pr-packaging/03-watch-feature-ideas.md](../upstream-pr-packaging/03-watch-feature-ideas.md)).

> **Gating note.** Build 208 changed a lot at once (teardown removal, two watchdogs, fork
> threading, the telemetry ring, defer-tail, the connection-event wake path). The highest-value
> thing 209 can be is the build where 208's open telemetry questions get answered against a
> stable baseline — plus the cheap, confirmed cleanups. **Most of Section A is decided BY the
> soak, not before it.** Don't finalize 209 scope until a few days of settled-sensor 208 data
> are in. (First-overnight read, 2026-06-11: funnel healthy, all "GONE" signals absent, both
> watchdogs silent, `connection_event` firing 41× — but only ~5.8h of watch data delivered, a
> day-1 sensor was applied mid-window, and stall proxies were slightly UP not down. Inconclusive;
> re-read after the soak.)

## Theme

Pay down 208's cost and answer its questions. No new behavioral systems. Two flavors: (1)
**soak-gated decisions** that 208's telemetry resolves, and (2) **confirmed cleanups** — the
debug-view denominator rewrite, the deferred-from-208 leftovers, and a battery/perf pass that
naturally pairs with the debug-view work (both delete timer machinery). Keep it small.

---

## Section A — Soak-gated decisions — RESOLVED (BetterStack verification 2026-06-14)

Verified against the 208 soak (source `Trio` 1659391). Baseline = build 207 (06-09→06-10);
settled 208 window = 06-11…06-14, with **06-11 and 06-12 the only clean watch days** (see the
06-13 dormancy outage below). Per-EGV/per-day normalized (207 ≈1.5d vs 208 ≈3.5d exposure).
Note: each EGV emits two `egv_received` rows (`module=g7_core` + `g7_ble`) — fractions use g7_ble.

| Q | Verdict | Evidence | 209 action |
|---|---|---|---|
| A1. Connection-event wake path earns its keep? | **NO lift — but KEEP (code review reversed the action)** | `connection_event` fires steadily (new in 208; ~286/day iOS, ~240/day watch on clean days) but background mix is **flat**: background-phase EGV 48% (207) → 47% (208); `ext_session_active=false` 70% → 68% | **No change in 209.** The "drop the bound-peripheral `.peerConnected` handling" action does not map to the code: the only `.peerConnected` handler (`G7BluetoothManager.connectionEventDidOccur`, in the **shared fork**) acts *only when unbound* (`activePeripheralIdentifier == nil`) — it is the cold-start/recovery discovery path, the dominant attach mechanism per build-186, and how Trio rides the Dexcom reconnect windows (A6). Removing it would hurt cold start and touch the phone too. **Keep handler + telemetry.** The latent design-vs-impl gap it exposes is a 210 opportunity → A7. |
| A2. CB state restoration on watchOS | **FIRES on watchOS** (assumption was wrong) | `will_restore_state` watchos: 207=4, **208=39** (18/13/7 across 06-11/12/13). Settles the review-doc contradiction in the FAVOUR of the review doc | **KEEP** the restore-identifier path — **cancel the planned deletion.** It is a live, regularly-exercised recovery path |
| A3. C-208-12 lock-inversion fix | **Flat / noisy** | Per clean day watchos: `command_timeout` 207≈24 vs 208 21,11; `configure_block_skipped` 207≈26 vs 208 39,14. iOS flat. Lumped-window "up" read was an exposure artifact | No action; inversion wasn't the dominant cause. Don't conclude the fix failed |
| A4. Watchdog fire counts | **Earned its keep** | `egv_watchdog_fired`=14, **all** on 06-13(10)+06-14(4) — exactly the dormancy outage. `ext_session_start_timeout`=0 | Keep the watchdog. **New investigation:** the dormancy outage it flagged (below) |
| A5. Reconnect-storm tripwire | **FIRES** | Multiple ≥4 `did_connect`/5-min windows on clean days, incl. **two 16-connect bursts** (06-11 06:10, 06-12 06:15) | **Un-shelve and build** the connect-gate delegate (review 2.2) |

### A6 (NEW). Watch direct-BLE outage — 06-13, full day — upstream Dexcom-session dependency
> **✅ SETTLED — pass (2026-06-16).** The first worn deep-background overnight soak on build 209 (the
> exact 06-13 condition) showed **no dormancy recurrence**: ~6.4h worn, 52 g7_ble EGVs (~68% of
> slots), `connect_called` healthy ~21/hr throughout, **0** watchdog fires — vs 06-13's 0 EGVs /
> dormant connects / 14 watchdog fires. The ~32% misses were sleep-position occlusion, not software.
> See the [build-209 impl log](watch-g7-direct-ble-observer-build209-impl-log.md) "Overnight soak
> result." Residual risk is Dexcom-side (the root cause), addressed by A7 stall-detection in 210.

**Symptom:** on 06-13 the watch captured **zero direct-BLE EGVs for the entire day** (iOS steady
~285/day throughout). The watch was **worn** (battery `unplugged` 14,239 vs `charging` 1,069) and
the app was **alive** (complication bgtask path 300–800 events/hr on phone-WC) — so the outage was
**invisible to the wearer** (complication stayed fresh from phone-forwarded data).

**Architecture reminder (why this matters).** Per
[01-design.md](watch-g7-direct-ble-observer-01-design.md): *Trio is not the BLE session owner — the
official Dexcom G7 watch app owns authentication and keeps the same-device link warm; Trio observes
that authenticated session.* The dominant delivery mechanism is `registerForConnectionEvents`
(MOD-E), which fires when **the sensor opens its ~5-min re-auth window with the Dexcom watch app**.
So Trio's direct capture is **gated on the Dexcom watch app maintaining a live direct-to-sensor
session.** No Dexcom direct session → no windows → Trio observes nothing. This is a **dependency**,
not contention (Trio and the Dexcom app cooperate; they do not compete for the sensor).

**Root cause (corrected — supersedes the earlier "Trio background-dormancy" framing).** The **Dexcom
watch app lost its direct-to-sensor session all day** and fell back to phone relay (Charlie saw the
Dexcom app's own "signal loss" notifications). Evidence Trio's logs are consistent with this:
- 06-13 00:00→15:00 — **no windows**: no `connection_event`, `connect_called` ≤2/hr, zero EGV
  (Trio also cold-relaunched overnight — `seq` resets, `sensor_name=nil`).
- 06-13 15:00→24:00 — **windows present, still starved**: `connection_event` 90, `did_connect` 53,
  heavy `stale_sensor_binding_suspected` (~50) + `stale_sensor_reinit`, yet **zero EGV** and
  `command_timeout`/`pre_egv_disconnect` — i.e. Trio attached but the session behind it wasn't
  delivering glucose.
- iOS unaffected throughout (its own independent authenticated G7 connection).
- **Fix was restarting the *Dexcom* app** (force-stop): its direct session re-established and Trio's
  windows + EGVs returned within ~4 min. Force-stopping Trio was secondary.

**Why the Dexcom app lost its link (conjecture — outside Trio's code, labelled):** (a) sensor-side
connection-table/radio arbitration when the phone holds a strong continuous link; (b) range/body
occlusion for a sustained period; (c) a transient Dexcom-app/watchOS BLE wedge that only cleared on
a hard restart. Trio cannot see the Dexcom app's internals; these stay hypotheses.

**Trio-side contributor (real, addressable):** Trio's watch app cold-relaunched repeatedly overnight
(`seq` resets, `sensor_name=nil`) and couldn't re-bootstrap observation — so even a brief Dexcom
window could be missed.

**Takeaway:** Trio's direct capture is **bounded by the Dexcom watch app's session health** and the
WC/phone fallback **hides the failure** (complication stays fresh). Trio can't fix a Dexcom-side
stall — but it *can* detect and surface it. See the A7 candidate below.

### A7 (210 CANDIDATE). Direct-BLE-stall detection + indicator
**Goal:** detect when the watch's direct path is down and surface it, instead of it hiding behind
the WC/phone fallback for hours. Out of scope for 209 (new behavioral system); design for **210**.

**Primary signal — cross-source freshness.** Trio's watch sees three sources (BLE, WC/phone,
HealthKit). Compare `lastDirectEGV` vs `lastWC/phoneEGV`:
- direct **stale** + phone **fresh (<~7 min)** → **direct-BLE stall** (actionable; the user-visible
  "on phone relay" state).
- both stale → sensor/system-level (warmup, sensor fail, out of range) — **not** a direct-BLE stall.

**Who failed (decision via the window signal `connection_event`):**
- no windows in last ~15 min + phone fresh → **Dexcom-side** (its direct link down) → can't self-fix;
  prompt user to restart the Dexcom app.
- windows firing but no EGV → **Trio-side** (extraction failing) → Trio self-recovers (re-scan /
  restart its BLE engine).
- Trio process silent / `seq` reset → **Trio suspended/crashed** → Trio-side.

**Tiers (cadence ≈ 300s):** soft stall `>~12 min` → UI `stalled` + emit `direct_ble_stall_detected`;
hard stall `>~30 min` → UI `unavailable` + escalate recovery.

**False-positive guards:** gate on the B1 `ineligibleSeconds` (suppress during warmup/`sessionEnded`/
no `expectedSensorName`); don't trigger within ~2 min of cold launch; require phone-fresh for the
soft state so a brief mutual gap doesn't flap.

**Already exists vs new:** exists — `egv_watchdog_fired`, `pre_egv_disconnect`, `command_timeout`,
`connect_called`, `ineligibleSeconds`, the BLE-status UI palette (`stalled`/`unavailable`). New — the
cross-source comparison, the dormant-vs-starved/Dexcom-vs-Trio classification, and a
`direct_ble_stall_detected` telemetry event to measure stall frequency the way the watchdog measures
fires. Would have flagged 06-13 within ~15 min instead of never.

**Recovery levers (paired with the detection above) — split by fault:**

*Trio-side stalls (Trio's own engine wedged / suspended / fumbled the read) — Trio CAN self-heal:*
- **Connection-event re-kick (the A1 design-vs-impl gap, inverted).** Today
  `G7BluetoothManager.connectionEventDidOccur` only acts when **unbound**; the original MOD-E design
  intended `startOrResume` on every Dexcom reconnect. **Extend it to re-kick the attach when
  bound-but-stalled** (no recent EGV) so Trio rides a fresh Dexcom window immediately instead of
  waiting on its own timer — targets the mild 10–15 min missed-window gaps seen in the 2026-06-14
  soak. **Gate hard:** only when bound AND stalled, never when bound AND healthy, or it tears down a
  live connection and **feeds the A5 reconnect storm**. Shared-fork change (phone impact) → 210.
- Restart own `CBCentralManager` / re-scan on a hard Trio-side stall; recover from own suspension.
- **Goal: stop making the user force-restart *Trio*.** Achievable.

*Dexcom-side stalls (the Dexcom watch app lost its sensor session — the 06-13 case) — Trio CANNOT
auto-fix:* Trio is observer-only. It cannot restart another app (OS sandbox) nor authenticate the
sensor itself (no auth path; without the Dexcom app's authenticated session there are no EGVs to
observe). A direct scan when Dexcom has fully dropped won't substitute (still no auth). **Ceiling =
detect + notify.** "Asking too much" to fully auto-recover — confirmed by the architecture.

**Stall notification (user-facing) — inferred, not callback-driven.** The Dexcom app notifies from a
CB callback because it *owns* the connection; Trio must **infer** a Dexcom-side stall (A7 signal) and
fire its own: *"Watch direct sensor link down — on phone relay. Restart the Dexcom Watch app."*
**Alarm-fatigue guards (this is a glucose app — non-negotiable):**
- Fire only on a **sustained Dexcom-side hard stall** (~30+ min, no windows), never on the mild gaps.
- **Debounce** to once per episode.
- Prefer firing only when it **actually costs data** (direct down *and* phone path unreliable). When
  the phone is covering the complication, use the quiet signals instead — the on-watch `stalled`
  indicator + the `direct_ble_stall_detected` telemetry — not a push.

---

## Section B — Confirmed cleanups (do regardless of soak)

### B1. Complication debug-view denominator: incremental → analytical *(investigated 2026-06-11)*

**Problem:** the "captured / possible chances since midnight" denominator (`expectedSlotsToday −
gatedSlotsToday`) is accumulated by a `DispatchSourceTimer` that does not fire while the watch is
suspended — so the denominator **freezes during exactly the background outage it exists to
expose** (ratio reads an artificial 60/60). Five secondary bugs (gated > expected collapsing the
denominator to 0; cold-start replay keyed on a possibly-absent `lastEGVEpoch`; the 50-tick cap
silently dropping slots; gate-first-after-midnight mis-seeding the day; permanent undercount from
the monotonic high-water) are all symptoms of integrating a time-based quantity with an
event-based, background-suspended accumulator.

**Fix — compute analytically at display time:**

```
elapsedSlots = Int(now.timeIntervalSince(startOfToday)) / 300          // correct across any suspension
denom        = max(0, elapsedSlots − ineligibleSlotsToday − gatedSlotsToday)
ratio        = denom > 0 ? "\(bleEGVsToday) / \(denom)" : "\(bleEGVsToday)"
```
- `ineligibleSlotsToday = ineligibleSecondsToday / 300` — the ONLY thing that needs tracking:
  wall-clock seconds today during which a reading was impossible (no `expectedSensorName`,
  adapter stopped, warmup/`sessionEnded`/`sensorFailed`). Maintained by **edge events only** (no
  timer): stamp `ineligibleSince` on entry to a no-read state, accumulate `now − ineligibleSince`
  on exit, clamp the open interval to `startOfToday`, add the still-open interval on the fly at
  display time, reset in `resetDailyCountersInMemory`.
- Keep `gatedSlotEpochsToday` as-is (the one piece that legitimately needs per-slot dedup); with
  the analytical base, `gated ≤ elapsedSlots` by construction so the negative/collapse path
  disappears.
- **Delete** (denominator-as-timed machinery): `expectedSlotsToday`, `lastExpectedSlotEpoch`, the
  slot-counting branch in `emitExpectedWindowTick`, `reanchorExpectedWindowTimer` /
  `scheduleWindowTick` / `fireExpectedWindowTick` as a denominator source, the `>50` cold-start
  cap, the `hasAnchored` gate, and the `WatchState.expectedSlotsToday` mirror. The
  `expected_window` log line can stay as pure telemetry or go.
- Keep the ratio **un-clamped** at display (UI-207-1 intent — backfill >100% stays visible); but
  now >100% is unambiguous (the denominator no longer freezes), so it genuinely means
  "more reads than slots" rather than "the timer was asleep."

**Citations:** `ComplicationDebugView.swift:677-691`; `G7WatchSensorAdapter.swift:506-562,
564-588, 612-619, 633-645, 1056-1066`; `WatchState.swift:118-120`. **Effort:** medium; net code
*reduction*. **Risk:** low — debug-surface-only; no capture-path effect. Pairs with B-perf
(both delete timer machinery).

### B2. Daily-log batching (consumer-side I/O) — review 5.7
208's ring fixed the producer side; `appendToDailyLog` still opens/seeks/writes/closes
`watch_log_daily.txt` per line inside the actor. Batch per flush. Small. Completes the
observability-tax work.

### B3. Background-skip non-essential GATT round-trips
Skip backfill-subscribe + `requestExtendedVersion` when backgrounded — extra radio trips inside
the runtime slice that contribute nothing to the current reading (the slim-path work deferred
from C-208-10). Needs a fork knob (scene phase isn't visible to the fork) → small fork + adapter,
ships via the 3-step deploy.

### B4. C1 comment scope correction — review 2.4
The "ONLY way the adapter starts scanning" comment overstates C1's scope; `rescan_scheduled`
shipped in 208 gives the honest denominator. Correct the comment + any `ble_gated`-derived
dashboard math. Trivial.

### B5. `Data.to()` slice over-read — review 1.5
The 3-byte-slice-as-`UInt32` latent OOB read in `Common/Data.swift`. Careful rewrite of a shared
parser primitive (length-checked / `loadUnaligned` from a stack copy); validate on iPhone. Fork
change, 3-step deploy.

### B6. Battery-context accuracy fixes *(investigated 2026-06-11)*
Small, confirmed, debug-surface-only:
- **Enable battery monitoring once at launch** (`ExtensionDelegate`), not lazily on first log —
  removes the cold-start `unknown/unknown` window (rare in data: 4–6 lines/build, but free to fix).
- **Read `battery_state` fresh** (or give state a much shorter TTL than level) in both caches —
  the 60s TTL smears state for up to a minute around plug/unplug transitions. Level can keep the
  60s cache; state is the part that must be fresh.
- **Two cache implementations diverge by design** (`WatchLogger` actor cache blocks for a fresh
  read when stale; `ComplicationLogBuffer`'s queue-confined cache returns stale-first and
  refreshes fire-and-forget, so complication-path lines lag a full refresh cycle and start each
  process as `unknown` — observed disagreeing with WatchLogger lines within 26s in the
  2026-06-11 export). Either unify, or stamp the source so analysis can tell them apart. Note the
  sawtooth/off-wrist dashboards key on `charging`/`full` — complication-line staleness is the
  variant that could mislabel off-wrist.
- **State-cycle verification (done, 2026-06-11):** all four states appear with correct patterns —
  206 shows the textbook full cycle (charging → 710 sustained `full`@100 lines → unplugged); 207
  never reached 100% → zero `full` (consistent); 208 has only 2 `full` lines because the watch
  came off the charger right at 100%. `unknown_default` never appears. No missing-state bug.

### B7. Complication update-path fixes *(review pass 2026-06-12 — findings 1.10, 5.9, 5.10, 6.9–6.11)*
- **mmol `sanitizedGlucose` fix (review 1.10, MED)** — comma→dot normalization (mirroring
  `sanitizedDelta`) + no integer rounding in mmol range, unit tests for both locales. Latent
  locally (mg/dL device), **upstream-PR pre-flight blocker** — must be in the PR branch.
- **Unserviced-reload detector (review 5.9, MED)** — one targeted re-request when a
  `reload_generation` goes unobserved at getTimeline for ~120s; the generation plumbing already
  exists. Candidate reducer for the GTL p90 ≈ 600s tail — measure the tail before/after.
- **Cheap hygiene (LOWs):** align the cold-start same-timestamp fallback with `shouldUpdate`
  content policy (5.10); always assign `lastValidTimestamp` via `onMain` (6.9); use
  `inMemorySavedSnapshot` for the retry-skip check + `.bak` every Nth save + move save I/O
  off-main (6.10 — pairs with Section C and 6.8); delete the dead source-less `save()` (6.11).

---

## Section C — Battery / perf pass *(feature-ideas #1; strong include — triage DONE 2026-06-11)*

**Logs-triage result (26h of build-208 watchos data): the logging pipeline is the dominant
self-inflicted battery driver — the observability tax, not the BLE feature.**

| Driver (ranked) | Evidence | Fix |
|---|---|---|
| 1. **Log-shipping meta-chatter** | `WatchLogger.swift` wrote **13,695 of ~20,000 lines (~70%)** from 11 self-logging sites (chunk markers, "Logs queued", sendMessage timeouts). The pipeline mostly ships its own chatter → more chunks → more meta-lines (compounding). | Demote meta-lines to counters + ONE summary line per flush cycle. Biggest single lever. |
| 2. **Per-line syscall storm** | `log()` does `print(entry)` + `appendToDailyLog` (which runs `createDirectory` **every line**, then open/append/close) + a flush check — per line. ~20k lines/26h; the morning foreground burst wrote **~9k lines in ~10 min**. | Extends B2: batch daily-log writes per flush, hoist `createDirectory` to init, keep a `FileHandle` open per flush window, drop `print()` in release. |
| 3. **WC ship cadence** | `flushInterval = 180s` → radio transfer every 3 min (`sendMessage` with reply-wait, else `transferUserInfo`), plus ~420 complication age-report/reload lines and 369 `complication_bgtask_forwarding`/26h. | Lengthen flush interval when backgrounded/no-session; coalesce age reports. |
| 4. **Scan duty cycle** | Radio *events* are modest (178 `connect_called`, 91 `rescan_scheduled`/26h) and scan `options: nil` (no `allowDuplicates` — that suspect is CLEARED). Cost is continuous scanning while unattached; `stored_id` attach (95–97%) doesn't need it. | Window-anchored scanning (feature-ideas #2) — still gated on the A1 verdict. |
| 5. Small fry | `WatchGlucoseHistoryStore` sync JSON write per insert (124/26h, review 6.8 — blocks BLE callers, perf > battery); HK anchored-query batches (97/26h); defer-tail UserDefaults write per EGV (109/26h, negligible). | 6.8 → `queue.async`; rest: leave. |

Extended-runtime sessions are deliberately *not* on the list — they're the capture mechanism;
their cost is the feature's cost. (A soak query on session start→invalidate durations can verify
none are held longer than needed.)

**Measurement protocol for before/after:** drain %/hr from `battery_level_percent` during
unplugged, monotonically-decreasing runs (level-only — sidesteps state smear), bucketed by `dt`
(verified == write time, see Conventions below), same sensor age, full discharge cycles.
Instruments Energy Log on-device for any claim a specific fix "saved battery."

**Open the `docs/in-progress/perf-optimizations/` design before implementing** (per the backlog
doc's own next-step). Scope: items 1–3 above + 6.8 — not an open-ended audit.

---

## Telemetry query conventions *(learned 2026-06-11 — apply to all soak analysis)*

- **`dt` IS write time**, not delivery time — verified two ways (NDJSON export: 0s skew on all
  lines; ClickHouse: 0s skew on 11,902 lines). The watch ships logs in delayed bursts, but each
  line's embedded `[timestamp]` becomes `dt`. Bucketing by `dt` is valid. (Only lines *without*
  an embedded timestamp — `log_flush_chunk` meta-lines, blank lines — get ingestion-time `dt`.)
- **Use `uniqExact` for precision counts** — duplicate rows exist (hot-tier/S3 overlap:
  one window showed 2,906 rows / 1,752 unique lines). `count(*)` can overstate.
- **The ClickHouse `raw` column is the JSON envelope**; the log line is the inner `raw` field —
  anchor regexes accordingly (`JSONExtract(raw, 'raw', ...)`).
- A 5-min bucket can contain a genuine state *transition* — don't read mixed states in one
  bucket as a data bug.

---

## Section D — Backlog candidates (if 209 has room)
- **6.3** — stop polling `isConnected`/`isScanning` via `managerQueue.sync` from MainActor; have
  the fork push status snapshots (additive delegate callback). Pairs with the perf pass.
- **5.3 leftover** — `requestWatchStateUpdate`'s 30s timeout path doesn't retry.

## Explicitly NOT 209
- Watch-side alerting (feature-ideas #6) — the real new capability, but its own initiative;
  active safety feature, high scrutiny, do AFTER the upstream PR so it doesn't bloat review.
- Window-anchored scanning (review 2.7) — gated on the A1 connection-event verdict; may be moot.
- Messaging centralization, notif-complication-refresh — wrong phase / fallback-only value.
- The upstream-PR packaging work — parallel track, not a build item.

## Verification strategy
Same as 208 (no debug builds / no TSan in the TestFlight pipeline): `dispatchPrecondition`
guards, structure-over-discipline, BetterStack before/after, optional standalone-fork TSan run.
B1 is debug-surface-only (easy to eyeball); B3/B5 are fork changes needing iPhone validation +
3-step deploy. New post-ship signal for B1: the debug ratio should track real outages instead of
freezing (verify by correlating a known background gap against the displayed denominator).

## Open questions for Charlie
- Finalize 209 scope after how many days of 208 soak? (recommend ≥3 on a settled sensor)
- Battery pass: full `perf-optimizations` design doc first, or just the 2-3 cheap wins inline?
- B1 debug-view rewrite: do it standalone now (it's confirmed + self-contained), or batch with
  the rest of 209?

---

## Changelog

### v1.7 (2026-06-13 17:25 CEST) — patch-12 blocker RESOLVED (CLB hunk dropped); ship-order set
- **Decision (Charlie):** ship 209 on the current split stack FIRST, then do the dev-sync + 09/12
  merge cleanup. So the CLB cross-patch issue is resolved the lightweight way for now:
- **CLB hunk dropped** — `7776d8cff` (signed) restores `ComplicationLogBuffer.swift` to its pre-209
  (b2417f7bd) state, undoing only C-209-5's `battery_src` tag + 15s TTL. The patch-12 regen no
  longer has a cross-patch file → the fail-closed blocker is gone. The dropped hunk is archived at
  `C-209-5-CLB-hunk-to-restore.patch`. **TRACKED RESTORE:** re-apply it into the merged watch patch
  during the Flavor-B 09+12 merge (cleanup Phase B) — Charlie's condition for approving the drop.
- **Crashlytics neutralized** — `faedb574b` (signed) reverts `1b7dbf805` (the test-crash button in
  `AppDiagnosticsRootView.swift`), tree-level/SHA-stable, clearing that persistent drift. (Note:
  the `AppDiagnostics` *module* is legit and stays; only the one button was removed.)
- **Updated patch-12 regen** (run at build time, soak-gated): re-derive the cherry-pick list via
  suggestion mode (omit `--cherry-pick`) — it now spans the 7 prior commits + `faedb574b` +
  `7776d8cff`; `--extra-files "Trio Watch App Extension/WatchTelemetryRing.swift"`. CLB no longer
  trips the drift check.
- **Signing finding:** only the 4 newest feature commits are signed; the 114 below (build-205→208)
  are unsigned. Re-signing is deferred to the cleanup's dev-sync rebase (`--exec 'git commit
  --amend --no-edit -S'`) — doing it now would re-SHA the C-209 commits right before the 209 ship.

### v1.6 (2026-06-13 09:30 CEST) — REAL blocker diagnosed: C-209-5 spans two patches
- The v1.5 "stale base" read was incomplete. With the correct full cherry-pick list
  (`1135fc67c,694e006b7,c144e9e5c,b2417f7bd,f4ae97537,f1b6450b7,9d0568371` — every commit from
  the committed build-206 tip `06cb245de` to HEAD; verified contiguous), the cherry-picks
  **apply cleanly** — the regen now fail-closes at the **drift check**:
  > FATAL: 1 file changed on the feature branch is MISSING from the regenerated patch:
  > `Trio Watch Shared/ComplicationLogBuffer.swift`
- **Root cause:** C-209-5 (commit `f4ae97537`) edited `ComplicationLogBuffer.swift` (battery_src
  tag + 15s TTL), but that file is **owned by patch 09** (`09-watch-complication-improvements`,
  diff-entry confirmed), NOT patch 12. The commit bundles a complication-patch change into the
  BLE-observer patch. Forcing it into 12 via `--extra-files` would duplicate the file across
  patches 09 and 12 → full-stack apply conflict. The fail-closed check is correct.
- **Resolution (build session, careful multi-patch):**
  1. Home the ComplicationLogBuffer hunk in patch 09: `./scripts/mid-stack-update.sh --patch 09
     --cherry-pick f4ae97537 --feature-branch <fb> --allow-behind-origin` (only the in-scope
     ComplicationLogBuffer change lands; the other f4ae97537 files are out of 09's scope).
  2. Regen patch 12: 7-commit list + `--extra-files "Trio Watch App Extension/WatchTelemetryRing.swift"`
     + `--drift-exclude-regex 'Trio Watch Shared/ComplicationLogBuffer\.swift'` (v1.10 flag — tells
     the drift check that file is intentionally homed in 09). The 7-commit chain already proved it
     cherry-picks clean, so this should pass.
  - **Alternative to consider:** drop the ComplicationLogBuffer edit from 209 entirely (revert that
    one hunk) — it's the lowest-value B6 piece (a debug-log battery tag). Then patch 12 regens with
    no cross-patch entanglement. Charlie's call: keep (split across 09+12) or drop.
  - Committing the build-208 patch 12 first (the v1.5 idea) shrinks step 2 to the 3-commit list but
    does NOT avoid the ComplicationLogBuffer homing — step 1 is needed either way.
- State left clean: patch 02 repinned `3287f4c` ✓; patch 12 = build-208 (18 files) working tree;
  fork pushed ✓; no tmp branches; build-208 patch backed up at `$TMPDIR/patch12.build208.working.bak`.

### v1.5 (2026-06-13 09:10 CEST) — patch-12 regen attempted, BLOCKED on stale committed base
- **Ran the regen tonight; it does NOT work turnkey** (v1.4's claim was wrong). Two attempts,
  both failed, worktree cleanly restored each time (build-208 patch 12 backed up + re-restored;
  no damage; patch 02 repin intact).
- **Root cause:** the committed patch 12 is **build-206 era** (17 files) — the build-208 regen
  was generated but **never committed** (patch lifecycle). So any regen reconstructs from
  build-206, and:
  - The clean 3-commit list (`f4ae97537,f1b6450b7,9d0568371`) the patch-id probe suggested
    **conflicts** (cherry-picks onto a build-206 base missing the 207/208 ExtensionDelegate
    changes — conflict on `ExtensionDelegate.swift`). The probe undercounts because it reads the
    *working-tree* (build-208) provenance, not the committed base.
  - The full 206→209 chain
    (`1135fc67c,694e006b7,c144e9e5c,b2417f7bd,f4ae97537,f1b6450b7,9d0568371` + `--extra-files
    "Trio Watch App Extension/WatchTelemetryRing.swift"`) — the proven 208 pattern + 3 appended —
    **also failed** (error scrolled off; tmp branches were cleaned before capture). Needs
    interactive conflict resolution.
- **Recommended fix (build session):** **commit the build-208 patch 12** (a milestone commit —
  Charlie's call) so the committed base is build-208; then the clean 3-commit 209 regen works
  (probe already confirms the patch-id delta is exactly those 3). Alternatively, resolve the
  full-chain cherry-pick conflicts interactively. Either way it's a build-time task with the
  conflict in front of you, not a turnkey one-liner.
- State left for the build session: patch 02 repinned to `3287f4c` ✓; patch 12 = build-208
  staging (18 files) in the working tree, uncommitted; fork pushed ✓.

### v1.4 (2026-06-13 06:48 CEST)
- Patch-12 regen pre-flighted (not run — deliberately deferred to the build pass; see below).
  Confirmed: working-tree patch 12 is the uncommitted build-208 state (18 files, provenance
  trailer through `c144e9e5c`/`b2417f7bd`); the three 209 watch commits touch only existing
  files (count stays 18, no `--extra-files`). **Turnkey regen command for the build session:**
  ```
  ./scripts/mid-stack-update.sh --patch 12 \
    --cherry-pick f4ae97537,f1b6450b7,9d0568371 \
    --allow-behind-origin
  ```
  then `./scripts/patch-test.sh`, then grep the regenerated patch for `G7BackgroundHints` /
  `dailySlotStats` / `log_pipeline_summary` to confirm the 209 content landed, and confirm
  `Files in patch: 18` (red flag if it drops). Deferred-not-because-verdict-gated (it isn't —
  patch 12 is verdict-independent) but to run it ONCE, batched with the build, after the soak
  closeout — so an A1=NO fork change re-pins patch 02 and regens patch 12 together, not twice.

### v1.3 (2026-06-13 06:46 CEST)
- Fork `3287f4c` pushed to `cachrisman/G7SensorKit main` (`cb216bd..3287f4c`, signed). Patch 02
  repinned to `3287f4c3eb…` (both the `+Subproject commit` full SHA and the `index …160000` hint
  → `3287f4c3e`; base `4d0780db0` untouched). **Only patch-12 cherry-pick regen remains** before
  the build, gated on the soak closeout.

### v1.2 (2026-06-13 06:35 CEST)
- C-209-11 + C-209-12 implemented. Fork commit `3287f4c` (signed, **not yet pushed**): added
  `G7BackgroundHints.isHostBackgrounded` (Locked<Bool>, in G7Telemetry.swift to avoid a pbxproj
  change), gated the backfill-subscribe + extended-version round-trips in `handleGlucoseMessage`,
  and the bounded `Data.toDefaultEndian` rewrite. Adapter half `9d0568371` sets the hint on scene
  transitions. All four files pass `swiftc -parse`. **Remaining deploy steps** (3-step): push the
  fork → repin patch 02 to `3287f4c…` (both `+Subproject commit` and the index hint) → regenerate
  patch 12 via **cherry-pick** (the documented default — run with `--cherry-pick` omitted
  first to take the script's auto-suggested commit list; no `--extra-files`, no new files).
  NOT `--from-feature-branch` — that mode is for history-rewrite/scope-change regens like the
  upcoming dev-sync crashlytics drop, not clean linear appends. All gated on the soak closeout.

### v1.1 (2026-06-12 23:15 CEST)
- C-209-1 implemented (`f1b6450b7`, 3 files, +105/-93): analytical denominator per the B1 spec.
  Two DRIFT notes: (1) warmup counts as eligible — ineligibility collapsed to the single
  `expectedSensorName` nil/non-nil edge since every terminal path funnels through
  `performEndOfSessionTeardown` and stop() no longer exists; (2) the `expected_window` tick
  survives as pure telemetry, wall-clock-aligned (EGV-anchored re-anchor + retroactive replay +
  `retroactive=` field deleted — COV dashboard consumers keyed on reason/eligible unaffected).
  All six edited watch files pass `swiftc -parse`. Remaining: C-209-11/12 (fork, 3-step deploy).

### v1.0 (2026-06-12 19:55 CEST)
- Implementation started. C-209-2..10 implemented and committed to the feature branch
  (`f4ae97537`, 8 files, +244/-72): logger batching + meta-chatter demotion + background
  cadence, battery-context accuracy, mmol fix, unserviced-reload detector, store hygiene,
  history-store async inserts, C1 comment. Remaining: C-209-1 (denominator rewrite) and the
  two fork items C-209-11/12 (need the 3-step deploy + signing). Ship stays gated on the
  soak verdicts (A1-A5).

### v0.3 (2026-06-12 18:34 CEST)
- Added B7 (complication update-path fixes) from the 2026-06-12 review pass: mmol sanitization
  (review 1.10, upstream blocker), unserviced-reload detector (5.9, p90-tail candidate), and the
  5.10/6.9/6.10/6.11 hygiene batch. Note for A2: build-208 soak answered 6.1 **non-zero**
  (17 watchOS `will_restore_state` fires/~21h, restored_peripherals ≤3) — the A2 "delete the
  restore path" branch is dead; remaining question is attribution (why 208 ≫ 207), resolve at
  soak finalization.

### v0.2 (2026-06-11 10:05 CEST)
- Battery triage executed: Section C rewritten from "to-do audit" to ranked findings (logging
  pipeline ~70% of line volume is its own meta-chatter; per-line print/createDirectory/open-close
  syscalls; 3-min WC ship cadence; scan duty cycle — `allowDuplicates` suspect cleared,
  `options: nil`). Added B6 (battery-context accuracy: enable-at-launch, fresh state read,
  dual-cache divergence, state-cycle verification result). Added Telemetry query conventions
  (`dt` == write time — earlier "delivery time" claim retracted; `uniqExact` for counts; JSON
  envelope vs inner raw; transitions within buckets).

### v0.1 (2026-06-11 06:00 CEST)
- Initial DRAFT. Soak-gated decision table (A1-A5), confirmed cleanups (B1 debug-view analytical
  rewrite with the full formula + delete list, B2-B5 deferred-from-208), battery/perf pass (C),
  backlog candidates (D), and the explicit not-209 list. Scope provisional pending the 208 soak.
