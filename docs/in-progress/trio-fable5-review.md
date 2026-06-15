# Trio watchOS + G7SensorKit — Comprehensive Code Review

**Version:** v2.3
**Status:** review record (findings open; build-208 scope locked — see impl plan)
**Date:** 2026-06-10 (v2.3 additions: 2026-06-12)
**Scope:**
- `Trio` @ `feature/watch-g7-direct-ble-observer-synthesis` (1135fc67c) — watch extension focus
- `G7SensorKit` fork @ `main` (40b5871, C-207-2)

Paths below are relative to `/Users/charlie/Code/personal/health/diabetes/`.
"Context §N" citations refer to `TRIO_REVIEW_CONTEXT.md` (2026-06-10).

All G7SensorKit line numbers refer to the sibling fork at `G7SensorKit/` (`main` @ `40b5871`) —
confirmed to be the shipping code (context §1): builds run from `Trio-dev` (`dev` + patch stack),
and patch 02 pins the submodule to `cachrisman/G7SensorKit@40b5871`. The `Trio` feature worktree's
own submodule checkout (`b791cf5`) is stale by design and not a build source.

**Fix-layer policy applied throughout (context §2-Addition):** default to `G7WatchSensorAdapter`
for watch-only behavioral fixes. Fork changes only when clearly ADDITIVE (new delegate callback,
new telemetry event) or when the root cause is demonstrably in the fork's shared state machine.
Any fork edit ships only via the 3-step deploy (context §1): (1) commit + push to
`cachrisman/G7SensorKit`, (2) repin the SHA in `Trio-dev/patches/02-g7-reading-time-with-seconds.patch`,
(3) build. An un-pushed commit or un-bumped patch 02 silently ships the old G7SensorKit.

---

## REVISION LOG (v2.2 → v2.3)

Complication update-path review (2026-06-12, post-208-ship; code read on the post-C-208 feature
branch — `TrioComplicationDataStore.swift`, all four live save call sites, snapshot sanitization,
reload/retry/GTL machinery):
- **+6 findings:** 1.10 (mmol `sanitizedGlucose` corruption — **upstream-PR pre-flight blocker**),
  5.9 (unserviced WidgetCenter-reload blind spot), 5.10 (cold-start same-timestamp content drop),
  6.9 (`lastValidTimestamp` race with inverted main-thread guard), 6.10 (main-thread save I/O),
  6.11 (dead source-less `save()` footgun).
- **6.1 ANSWERED (non-zero):** build-208 soak shows `will_restore_state` fires on watchOS — 17×
  in ~21h (vs 2 on build 207), `restored_peripherals=` up to 3, arriving as the first ring event
  of the process. Keep D6 and the restore-identifier path; the delete option is dead. Final
  wording at soak finalization (209 plan A2).
- Verified clean in the same pass: the `g7Sequence` guard + source-priority lattice (every live
  snapshot constructor sets `source`); `updateApplicationContext` has a single caller (no context
  clobbering); save→`forceReload` main-queue FIFO ordering; retry token/ID lifecycle; the 5s
  debounce's trailing-edge loss self-heals via GTL's disk read (~57s latency).

---

## REVISION LOG (v2.1 → v2.2)

Telemetry-driven recalibration (all queries 2026-06-10, 30d, hot+S3; details in
`TRIO_REVIEW_CONTEXT.md` v3 §5 and `watch-g7-direct-ble-observer-build208-impl-plan.md`):

1. **2.2 + 5.1 downgraded HIGH → LOW (tripwired contingency).** Connect-cadence data: build 207
   averages 1.04 `did_connect` per active 5-min window (max 3, zero windows ≥4). No
   rapid-reconnect loop exists; no distinct day-1 "refusal path" is documented — day-1 differs
   in auth-grant *rate* on the same path. Tripwire: ≥4 connects/window reappearing on 207+.
2. **2.3 watchdog re-derived: 15s (was ~20–30s).** The inherited number traced to build-188's
   failed Option-C era; data: max-ever connect→EGV = 13s (1,400+ sessions), normal connection
   hold 6–10s, zombie class 600s (204/205, C3-fixed). 15s clears every observed success and
   catches every observed zombie.
3. **5.2 corrected by the GATT-funnel redo:** the watch completes its handshake steps at
   92–100% in background-dominated sessions; pre-EGV deaths are waiting-for-auth-grant (51% at
   0–2s, ~29% at window end), not CPU starvation. C-207-2's causal gloss corrected (context v3).
4. **2.7 premise corrected → LOW:** `attach_path` data shows `stored_id` (pending connect,
   **no scan**) is 95–97% of attaches on both platforms — the bound steady-state already idles
   without scanning, foreground included. There is no continuous scan for window-anchoring to
   eliminate; the surviving content of 2.7 is the slot-accounting honesty covered by 2.4/5.4.
5. **2.5 decision recorded:** ship shared and unguarded (Charlie); `configure_retry_exhausted`
   = 0 on both platforms in 30d — fail-safe insurance, no `#if os(watchOS)`.
6. **1.2 cross-platform data added:** stall proxies fire on ios too (`command_timeout` ~9/day,
   `configure_block_skipped` ~29/day on b206) — shared fix, two independent before/after datasets.
7. **Build-208 scope locked** (18 items incl. the re-scoped connection-event wake path — the
   attach-path data shrank the "experiment" to registration-at-`.poweredOn` + bound-sensor event
   handling; no scan-policy change exists to make). Counts now 2 CRITICAL / 7 HIGH / 21 MEDIUM /
   17 LOW (47 open unchanged).

---

## REVISION LOG (v2.0 → v2.1)

Priority-1 reframe, prompted by Charlie's pushback + second-agent review, and grounded in two
code verifications (call-site greps only; no full re-read):

1. **There is no user-facing "BLE off" on the watch.** `G7WatchSensorAdapter.stop()` has exactly
   **one caller** in the entire watch extension — the invalidation handler's error branch
   (`G7WatchSensorAdapter.swift:1195`). `isIntentionallyStopped` has zero readers. The v2.0
   "sticky stop" direction was hardening a path with no legitimate caller.
2. **Priority 1 rewritten — intent separation, not sticky stop** (Findings 1.1/2.1): remove the
   `stop()` call from the invalidation handler (session invalidation = session cleanup + renewal
   scheduling only; BLE runs on, iPhone-style), then delete the dead machinery (`stop()`,
   `isStopped`/`isIntentionallyStopped`, `recoveryScheduled` + the 5s recovery task, the `.off`
   status branch). The never-stop model is what produces the iPhone's ~99% and the watch's
   73%-of-captures-with-no-session (context §8.2); suppressing callbacks after a stop would have
   kneecapped exactly that path whenever an invalidation triggered it.
3. **Renewal-path independence VERIFIED before marking the recovery task deletable** (the
   second-agent's load-bearing question): `renewSessionIfNeeded()` is called from exactly one
   site — `applyForegroundActiveEntry()` (`:301`); `start()` never calls it; D8 (build 206,
   comment at `:873`) made foreground entry the sole renewal driver. The recovery task only
   restarts BLE — deleting it removes **no** session-renewal path.
4. **Finding 2.4 reframed (HIGH → MEDIUM):** fork-internal rescans are the *delivery engine*
   (73% no-session captures), not a C1 violation to suppress. The residual issue is
   documentation + `ble_gated` accounting honesty. Suppressing fork rescans would reproduce the
   same capture-kneecap as the withdrawn sticky-stop.
5. **Finding 3.4 reframed (MEDIUM → LOW):** GATT without a session is by-design the workhorse;
   the C1 invariant is correctly scoped to adapter-initiated scan entries.
6. **Finding 4.2 downgraded (HIGH → MEDIUM):** with the sole `stop()` caller removed, the
   misleading `stopScanning()` contract is a latent hazard for *future* callers, not an active
   bug; fix is documentation. (A quiescence path, if ever needed, must be built adapter-side —
   none is needed today.)
7. **Priority 2 mechanics updated:** context §6 P2a tied adapter-side backoff to "the Priority-1
   gate," which no longer exists in v2.1's reframe. Backoff options restated honestly: an
   adapter-side settle-loop (no fork change, fiddly against `scanAfterDelay`'s delayed rescan) or
   a minimal fork rescan-gate delegate (DRIFT — iPhone-default-true, iPhone-validated). The
   connect→EGV watchdog is unaffected. Backoff keys on confirmed `gate_passed=false` streaks only.
8. **Sequencing instruction added** (Priority 1, step 0): query BetterStack
   `ext_session_unexpected_invalidation triggering_teardown=true` (`platform=watchos`, post-207)
   **before** implementing — it measures exactly how often the path being removed fires, sizing
   the capture win and providing the before/after comparison event.
9. Findings 5.1, 5.3, 5.4, 3.5 and Priority Order #1/#2/#5 updated for consistency with the
   reframe; summary counts updated (totals unchanged at 47 open; severity mix now
   2 CRITICAL / 9 HIGH / 22 MEDIUM / 14 LOW).

---

## REVISION LOG (v1.1 → v2.0)

Revised against `TRIO_REVIEW_CONTEXT.md` only — no code re-read. Changes:

1. **Priority-1 fix relayered: fork → adapter** (context §2, §6 Priority 1, §7 DO NOT). The
   v1.x direction "add an `intentionalDisconnect` flag to `G7BluetoothManager`" targeted the
   wrong layer — `scanAfterDelay()`'s unconditional rescan is intentional shared iPhone/watch
   behavior the iPhone relies on. Corrected in **1.1, 2.1, 2.4, 4.2, 5.1** and Priority Order #1:
   the flag lives in `G7WatchSensorAdapter` and ignores reconnect callbacks after a deliberate
   `stop()` until restart.
2. **Priority-2 backoff relayered: fork → adapter** (context §6 Priority 2a, §7 DO NOT on
   `scanAfterDelay()`). Corrected in **2.2, 5.1** and Priority Order #2: attempt counting and
   backoff are implemented in the adapter once the Priority-1 gate is in place; no further
   `scanAfterDelay()` changes without explicit iPhone-validated justification.
3. **Finding 6.2 RETRACTED** — contradicted by build history (context §8.1): build-185 telemetry
   showed `registerForConnectionEvents`/`connectionEventDidOccur` was the *dominant* reattach
   path on watchOS (36 `peer_connected` events over 6 hours, ~every 5 minutes); build 194
   confirmed MOD-E fires together with `didConnect`. Efficacy on watchOS is empirically
   confirmed, not "unverified."
4. **Finding 5.5 corrected** — the "no ceiling on time spent `connecting`" suggestion implied a
   watch-only connect timeout, which is a hard constraint violation (context §2 "INTENTIONAL: No
   watch-only connect timeout"; §7 DO NOT, AGENTS.md v15). Retracted that sub-item; the
   connect→EGV watchdog (a different mechanism, explicitly endorsed by context §6 Priority 2b)
   and the pending-start timeout remain.
5. **Connect-storm / `reason=-1` attribution corrected** (context §5, §8.1, §8.2): the build-203
   storm's root cause is CONFIRMED as the missing `WKBackgroundModes: physical-therapy` plist key
   (fixed in build 204; `did_fail_to_connect` 526→0, `reason=-1` 256→8). The 94%-background
   pre-EGV disconnects are normal BLE window timeouts, NOT auth/cert failures (retracted
   hypothesis, §8.2). Corrected in **2.2, 3.1, 7.1** and Priority Order #4 (which previously
   claimed the `reason=-1` root cause was unconfirmed).
6. **Finding 4.1 fix direction corrected**: firing `sensorDidConnect` from the discovery-accept
   path is a shared-behavior change (DRIFT per context §2-Addition); the first-line fix is now
   documenting the contract (additive), with the callback change as an iPhone-validated option.
7. **Finding 7.2 resolved** with the verified facts from context §1 (build mechanism, 3-step
   submodule deploy, residual risks confirmed). No [NEEDS VERIFICATION] remains on 7.2.
8. **Finding 6.1 retained as [NEEDS VERIFICATION]** per context §7 DO NOT — and annotated with
   §8.2's correction that the earlier "never fires" conclusion was an instrumentation artifact
   (OSLog-only); M2 telemetry is wired as of C-207-2, result pending.
9. **[KNOWN — backlog] tags added** (context §5) to findings already on the confirmed backlog:
   1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.1 (via 1.1), 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 4.4,
   5.1 (via 2.2). Findings 3.3, 3.4 and the Section 5–6 items are tracked collectively on the
   Medium backlog (context §5 "Findings 3.3, 3.4, 5.x, 6.x"). Nothing was removed.
10. **Fork-edit fixes annotated** with the 3-step deploy requirement (context §1, §7 DO NOT).
11. **7.4 strengthened** with the build-206 datum (context §8.2): 73% of captures occurred with
    NO active extended runtime session — the session is wakeup substrate, not the EGV pathway.
12. **Recommended Priority Order rewritten** to reflect the corrected fix layers; summary counts
    updated (47 open findings + 1 retracted + 6 observations).

---

## SUMMARY TABLE

| Section | CRITICAL | HIGH | MEDIUM | LOW | Total |
|---|---|---|---|---|---|
| 1 — Critical bugs | 1 | 2 | 6 | 1 | 10 |
| 2 — BLE state machine | 1 | 1 | 3 | 5 | 10 |
| 3 — Session lifecycle | 0 | 2 | 1 | 2 | 5 |
| 4 — API surface | 0 | 1 | 5 | 2 | 8 |
| 5 — Reliability | 0 | 0 | 6 | 4 | 10 |
| 6 — Code quality / Swift | 0 | 1 | 2 | 7 | 10 (+1 retracted) |
| 7 — Architectural | — | — | — | — | 6 observations |
| **Total** | **2** | **7** | **23** | **21** | **53 open + 1 retracted + 6 obs** |

(v2.2: 2.2/5.1 → LOW tripwired contingency; 2.7 → LOW premise-corrected; 2.3 = 15s. Build-208
implementation status lives in the impl plan/log, not here. v2.3: +1.10, 5.9–5.10, 6.9–6.11 from
the complication update-path review; 6.1 ANSWERED non-zero — see revision log.)

17 findings carry **[KNOWN — backlog]** (already tracked per context §5, including the
cross-reference tags on 2.1 and 5.1); 3.3/3.4 and the Section 5–6 items are additionally tracked
collectively on the Medium backlog. Cross-cutting findings are counted once, in the section where
the fix lives.

---

## SECTION 1 — CRITICAL BUGS

### G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift (+ Trio adapter)

**1.1 — CRITICAL — Session invalidation is wired to a destructive, half-effective BLE teardown: `stop()`'s only caller is the invalidation handler** `[KNOWN — backlog, context §5; reframed v2.1]`
- The mechanism (unchanged): `stop()` (`Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift:294`) calls `sensor.stopScanning()`, which is just `bluetoothManager.disconnect()` (`G7Sensor.swift:120-122`). If a peripheral is connected/connecting, the cancel fires `didDisconnectPeripheral` → `scanAfterDelay()` (`G7BluetoothManager.swift:447`, also `:466` on `didFailToConnect`) → `scanForPeripheral()` → re-attach → reconnect. Result: a **half-stopped** adapter — `isStopped == true`, status `.off`, heartbeat/expected-window timers dead — while the fork's BLE pipeline runs on and the next EGV flips the published status back to `.active` (`handleSensorDidRead` has no `isStopped` guard, `:955` → `publishConnectionStatus` `:1077`).
- **Call-site facts (verified by grep, v2.1):** `stop()` has exactly **one** caller — the invalidation handler's error branch (`:1195`). There is no user-facing "BLE off" feature on the watch and no other subsystem calls it; `isIntentionallyStopped` (`:76`) has zero readers. So this was never a "stop must stick" problem: nothing legitimate ever asks for a stop. The conflated intents are *session invalidation* (should mean: clean up session state, schedule renewal) and *BLE teardown* (should mean: nothing — no caller wants it).
- **Why hardening stop (v2.0's direction) was wrong:** suppressing callbacks while `isStopped` would convert the half-stop into a full stop on every error-invalidation — exactly kneecapping the path that delivers **73% of captures with no active session** (context §8.2) until the next foreground entry. The fork's never-stop reconnect loop is the iPhone's ~99% engine (context §2-Addition) and the watch's workhorse; the project's own history moved away from teardown-on-invalidation three times already (build 194 `willExpire`, build 204 plist root cause, C-207-1 RBS errors — context §8.1).
- **Fix direction (v2.1 — intent separation in `G7WatchSensorAdapter`; no fork change):**
  0. *Pre-check:* query BetterStack `ext_session_unexpected_invalidation triggering_teardown=true` (`platform=watchos`, post-207) — the exact frequency of the path being removed; sizes the capture win and is the before/after comparison event.
     **DONE (2026-06-10, 30-day window, hot+S3, all events `platform=watchos`):**
     | build | teardowns | recovery_skipped | post_stop_recovery_attempt | bg_invalidation_ble_kept |
     |---|---|---|---|---|
     | 204 (6d) | 43 | 42 | 1 | — |
     | 205 (1d) | 2 | 2 | 0 | — |
     | 206 (3d) | 14 | 14 | 0 | — |
     | 207 (~14h) | **0** | 0 | 0 | 1 |
     
     Reading: pre-C-207-1, the teardown fired ~4–7×/day and the 5s recovery was skipped essentially
     **every time** (42/43, 14/14 — background at invalidation time), i.e. every firing produced a
     dark window lasting until the next foreground entry. On build 207, C-207-1's RBS carve-out is
     intercepting the dominant case (1 `bg_invalidation_ble_kept` already) and the teardown has fired
     **zero times in ~14h** — small sample, single-fleet caveat. Conclusion: the removal is
     low-risk dead-code cleanup that eliminates a proven dark-window landmine (any future
     foreground-error or background non-RBS-error invalidation would still strand BLE today);
     the immediate capture win on 207 is modest. Post-implementation, `recovery_skipped` /
     `post_stop_recovery_attempt` should disappear from telemetry entirely.
  1. Remove the `stop()` call at `:1195`. The error branch clears session references (already done at the top of the handler), logs, and returns — BLE and timers untouched, renewal via the existing foreground path.
  2. Delete the dead machinery: `stop()` itself, `isStopped`/`isIntentionallyStopped`, `recoveryScheduled` + the 5s foreground-gated recovery task (`:1196-1208`), and the `.off` branch in `publishConnectionStatus` (`:724`); simplify the now-constant `!isStopped` eligibility checks (`:553`, `:672`).
  3. *Renewal independence — VERIFIED:* `renewSessionIfNeeded()` is called solely from `applyForegroundActiveEntry()` (`:301`); `start()` never calls it (D8, build 206 — comment at `:873`: "renewal is driven solely by the foreground-active entry"). The recovery task only restarts BLE; deleting it removes no renewal path.
- The residual API-surface hazard (`stopScanning()` doesn't stop, and never can while `scanAfterDelay()` exists) moves to Finding 4.2 as documentation debt for future callers.

### G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift

**1.2 — HIGH — Lock-order inversion between `managerQueue` and the peripheral queue stalls the connect window** `[KNOWN — backlog, context §5]`
- Wait side: `runCommand` blocks the peripheral queue on `commandLock.wait` for up to `timeout` (`G7PeripheralManager.swift:337`), and the conditions are only signalled by `CBPeripheralDelegate` callbacks delivered on the central's `managerQueue` (`:452-534`).
- Block side: `peripheral` didSet does `queue.sync` (`:39-43`) and `delegate` didSet does `queue.sync` (`:73-78`) — and the `.makeActive` path calls `peripheralManager.peripheral = peripheral` **on `managerQueue`** (`G7BluetoothManager.swift:320`).
- If a discovery lands while the existing manager is mid-`runCommand`, `managerQueue` sync-waits on the peripheral queue while the peripheral queue waits for a callback only `managerQueue` can deliver. The `NSCondition` timeout (2s) breaks the deadlock, but the cost is a ~2s freeze of the entire BLE delegate queue plus a spurious discovery/notify failure (`configure_block_skipped` churn) — inside the ~5-minute G7 window where 2s can cost the reading. `debugDescription` (`:607`) has the same hazard from any thread.
- **Fix direction (fork change — endorsed by context §6 Priority 3b):** make the `peripheral`/`delegate` didSet bookkeeping `queue.async` (or lock-free flags), never `sync` from `managerQueue` into the peripheral queue. Ships only via the 3-step submodule deploy (context §1).

### G7SensorKit/G7SensorKit/G7CGMManager/G7Sensor.swift

**1.3 — HIGH — Systemic cross-queue data races on `G7Sensor` mutable state** `[KNOWN — backlog, context §5]`
- `sensorID`: written on the **caller's thread** in `scanForNewSensor()` (`G7Sensor.swift:110` — Trio calls this from `@MainActor`), written on **delegateQueue** in the discovery-accept path (`:176`), read on **managerQueue** in `readied`/`shouldConnectPeripheral`/`peripheralDidDisconnect`/`handleGlucoseMessage` (`:208,211,249,282,285,169,159,193`).
- `activationDate`: written on managerQueue (`:144`) and delegateQueue (`:178`); read cross-queue by `G7CGMManager.sensor(didRead:)`/`didReadBackfill` (`G7CGMManager.swift:376,431`).
- `pendingAuth`: written on the **peripheral queue** inside `peripheralManager.perform { ... }` (`:222`), cleared on managerQueue (`:263,385`).
- `needsVersionInfo`: read on managerQueue (`:159`), written on delegateQueue (`:179,316`) and by the consumer at init (`G7CGMManager.swift:218`).
- These are unsynchronized non-atomic properties (including `String?`); beyond formal UB, the practical failures are stale decisions in the exact path that matters for new sensors: e.g. `shouldConnectPeripheral` on managerQueue can still see `sensorID == nil` (issuing broad `.connect`s) after the delegateQueue accept already bound a sensor — a mis-binding ingredient on day 1.
- **Fix direction (fork change — endorsed by context §6 Priority 3a):** confine all of this state to `managerQueue` (hop back via `managerQueue.async` from delegate-thread accepts; pass values into delegate calls by copy), or wrap in `Locked`. Ships only via the 3-step submodule deploy (context §1).

### G7SensorKit/G7SensorKit/Messages/G7GlucoseMessage.swift

**1.4 — MEDIUM — `glucoseTimestamp` can trap (crash) on malformed payloads** `[KNOWN — backlog (Medium), context §5]`
- `G7GlucoseMessage.swift:31-33`: `messageTimestamp - UInt32(age)` traps on unsigned underflow whenever `age > messageTimestamp` (corrupt packet, hostile peripheral, or early-session edge). Consumers call it directly in the hot path: `G7WatchSensorAdapter.swift:1011`, `G7CGMManager.swift:383,412`.
- **Fix direction:** validate `age <= messageTimestamp` in `init?` (return nil) or use `subtractingReportingOverflow` with a clamped result. Shared-parser change — validate on iPhone per the fork strategy (context §2-Addition); ships via the 3-step deploy (context §1).

### G7SensorKit/G7SensorKit/G7CGMManager/G7BackfillMessage.swift + Common/Data.swift

**1.5 — MEDIUM — 3-byte slice converted as `UInt32` reads past the slice (latent OOB read)** `[KNOWN — backlog (Medium), context §5]`
- `G7BackfillMessage.swift:38`: `timestamp = data[0..<3].toInt()` (a `UInt32`). `Data.toDefaultEndian` (`Common/Data.swift:13-21`) does `bindMemory(to: T.self)` + `pointer.pointee`, dereferencing 4 bytes from a 3-byte buffer. Today it "works" only because byte 3 of the 9-byte backfill frame is the 0x00 pad inside the same allocation; any future slice at the end of an allocation, or a non-contiguous `Data`, is a real out-of-bounds read. Also `bindMemory` count is 0 for undersized buffers — the guard returns 0 silently in some layouts, i.e. silent data corruption rather than an error.
- **Fix direction:** make `to(_:)` length-checked (pad/`loadUnaligned` from a stack copy) and parse the 3-byte timestamp explicitly. Shared-parser change — validate on iPhone (context §2-Addition); 3-step deploy (context §1).

### Trio/Trio Watch App Extension/WatchLogger.swift

**1.6 — MEDIUM — Timeout task ignores cancellation → a false `sendMessage timed out` line on every successful send** `[KNOWN — backlog (Medium), context §5]`
- `WatchLogger.swift:199-205`: `try? await Task.sleep(...)` swallows `CancellationError`, then unconditionally logs "WCSession sendMessage timed out" and completes the gate. `timeoutTask.cancel()` from the reply/error handlers (`:210-221`) therefore *wakes* the sleeper, which still emits the timeout line. Every ACKed flush/drain/resend produces a phantom timeout event — corrupting exactly the WC-delivery telemetry used to debug delivery problems.
- **Fix direction:** `guard !Task.isCancelled else { return }` after the sleep (or use `try await` + `catch is CancellationError`).

### Trio/Trio Watch App Extension/WatchState.swift

**1.7 — MEDIUM — Cross-thread access to main-confined state from WCSession delegate queue** `[KNOWN — backlog (Medium), context §5]`
- `lastUserInfoReceiveTimestamp` is written on the WC delegate queue (`WatchState.swift:1392`) but read/cleared on main (`:1447, :2323`).
- `session(_:didFinish:error:)` calls `loadFallbackDataFromComplication()` directly on the WC queue (`:1493`), which reads main-confined `displayedReadingAttributedForDate` / `lastWatchStateUpdate` (`:2548, :2557`) before hopping to main.
- `WatchState` is `@Observable` with `assert(Thread.isMainThread)` discipline elsewhere; these two paths bypass it. Races are low-probability but corrupt the attribution watermark / dedup decisions silently.
- **Fix direction:** hop to main at the top of both paths (move the `Date()` capture into the main-async block; wrap the `didFinish` fallback call in `DispatchQueue.main.async`).

### G7SensorKit/G7SensorKit/G7CGMManager/G7Telemetry.swift

**1.8 — MEDIUM — `G7Telemetry.emit` is an unsynchronized global read from BLE queues** `[KNOWN — backlog (Medium), context §5; race window confirmed in context §4]`
- `G7Telemetry.swift:31` is a plain `static var` closure. It is written on the main thread at launch (`Trio/Trio Watch App Extension/ExtensionDelegate.swift:15`, `Trio/Trio/Sources/Application/TrioApp.swift:96`) *after* the `CBCentralManager` already exists (`ExtensionDelegate.swift:11` constructs the adapter first — context §4 confirms this ordering as the race window), and read from `managerQueue`/peripheral queues via `emitG7Telemetry` (`:42-48`). A BLE callback racing app launch reads a half-published closure (formal data race; TSan will flag it).
- **Fix direction:** make it set-once behind a lock (`OSAllocatedUnfairLock`) or an `atomic`-style wrapper (ADDITIVE fork change; 3-step deploy per context §1); in Trio, assign before constructing the adapter.

### G7SensorKit/Common/Locked.swift

**1.9 — LOW — `os_unfair_lock` stored inline in a Swift class**
- `Locked.swift:12-18`: passing `&lock` to `os_unfair_lock_lock` relies on Swift not moving the property — unsupported per Apple guidance (can mis-lock under exclusivity/optimization changes). Inherited LoopKit pattern, never observed failing, but it guards `G7CGMManager` state and `activePeripheralIdentifier`.
- **Fix direction:** migrate to `OSAllocatedUnfairLock` (watchOS 9+/iOS 16+) or allocate the lock with `UnsafeMutablePointer`. Shared change — validate on iPhone (context §2-Addition); 3-step deploy (context §1).

### Trio/Trio Watch Shared/TrioComplicationDataStore.swift *(v2.3)*

**1.10 — MEDIUM — `sanitizedGlucose` corrupts mmol/L display values (decimal and comma locales)**
- `TrioComplicationDataStore.swift:78-94`: the numeric extraction keeps only `0-9.`, so a
  comma-decimal mmol string (`"5,6"`) concatenates to **"56"** (dangerous nonsense), and a
  dot-decimal one (`"5.6"`) is integer-rounded to **"6"** (decimals destroyed). The tell:
  `sanitizedDelta` (`:96-117`) normalizes commas correctly — glucose never got the same path.
  Latent on this device (mg/dL); live display corruption for mmol users — **upstream-PR
  pre-flight blocker** (mmol users are a large share of nightscout/Trio's audience; see
  `upstream-pr-packaging/02-trio-watch-pr-plan.md`).
- **Fix direction:** mirror delta's comma→dot normalization; skip integer rounding for values in
  plausible mmol range (< ~40), preserving one decimal; unit tests for both locales.

---

## SECTION 2 — BLE STATE MACHINE CORRECTNESS

Lifecycle reviewed: scan → advertisement → `shouldConnectPeripheral` → connect → configure (service/char discovery) → auth-notify subscribe → auth observe → control subscribe → EGV → disconnect → rescan.

### G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift

**2.1 — CRITICAL — "Stopped" is not a reachable terminal state — and (v2.1) no state-machine consumer needs one** `[KNOWN — via 1.1, context §5]` — see Finding 1.1. State-machine framing: there is no `idle` state the manager can be put into; every disconnect (including locally-initiated) transitions to `scanning` within 0–2s. Per context §2 this is intentional shared iPhone/watch behavior — the never-stop loop *is* the delivery model. v2.1 reframe: since the watch has no off feature and `stop()`'s only caller is being removed (1.1), the correct resolution is not to create a stopped state anywhere but to stop pretending one exists — delete the `.off`-via-`stop()` machinery and let the state machine be what it is on both platforms: scan ⇄ connect ⇄ read, forever.

**2.2 — HIGH — No backoff, jitter, or attempt ceiling anywhere in the reconnect loop (latent storm mechanism)** `[KNOWN — backlog, context §5]`
- `didDisconnectPeripheral` → `scanAfterDelay()` (`G7BluetoothManager.swift:447`) and `didFailToConnect` → `scanAfterDelay()` (`:466`). With C-207-2, a pre-EGV disconnect rescans with **0s** delay (`:261`). A transmitter that drops the unbonded observer and is still advertising → instant re-discover → instant reconnect → drop → repeat for the rest of the ~5-min window. Nothing counts attempts or widens spacing.
- **Attribution corrections (context §5, §8.2):**
  - The build-203 connect storm's root cause is **CONFIRMED** as the missing `WKBackgroundModes: physical-therapy` plist key (fixed in build 204: `did_fail_to_connect` 526→0, `reason=-1` 256→8). Before attributing any storm symptom to this BLE-layer gap, verify the current patch-12 build carries the plist key (context §5).
  - The dominant pre-EGV disconnect population (162 events, build 206, 94% background) consists of **normal BLE window timeouts** — the G7's re-auth window closing — NOT auth/cert failures (retracted hypothesis, context §8.2). The no-backoff loop matters for the *refusal-loop subset* (e.g. day-1 sensors where the transmitter actively drops the observer while still advertising), not for the majority timing-miss population.
  - C-207-2's 0s fast-path is **intentional shared iPhone/watch behavior**, judged safe and beneficial for iPhone (context §7 DO NOT; §2-Addition). It is not a watch-only regression.
- **Fix direction (updated v2.1 — the §6 P2a "Priority-1 gate" precondition no longer exists):** attempt *counting* stays adapter-side (per expected window, keyed on confirmed `gate_passed=false` streaks only — never on raw disconnect counts). The *deferral* mechanics have two honest options now that there is no ignore-gate: (a) **adapter settle-loop** — on a confirmed refusal streak, call `sensor.stopScanning()` after the disconnect callback and re-check `isScanning` a few times until the fork's delayed `scanAfterDelay` rescan is actually quiesced, then resume via `beginScanIfEligible(.resume)` at the backoff deadline (no fork change, but fiddly against the 0–2s delayed rescan); or (b) **minimal fork rescan-gate delegate** (`bluetoothManagerShouldRescan`, default `true` so iPhone is unchanged) — cleaner, but its consult site is inside the frozen `scanAfterDelay()` path: DRIFT requiring explicit iPhone-validated justification (context §7 DO NOT) and the 3-step deploy (context §1). Critically, the backoff must never sit out a healthy window-timeout reconnect — per context §8.2 those are the majority population and the always-retry loop is what catches the next window.

**2.3 — HIGH — Connected-but-silent zombie: no auth/EGV watchdog after connect** `[KNOWN — backlog, context §5]`
- After `readied` subscribes to auth notifications (`G7Sensor.swift:218-232`), there is no timeout: if the auth challenge value never arrives (or arrives with `gate_passed=false` repeatedly — `:399-402` just ignores it), the connection sits in "connected, pendingAuth" until the transmitter drops it. The Trio adapter has no per-connection watchdog either. On the watch this burns the runtime window while delivering nothing.
- **Fix direction (adapter — endorsed by context §6 Priority 2b):** arm a per-connection timer in `G7WatchSensorAdapter` at `did_connect` (~20–30s); on expiry without EGV, disconnect and re-enter scan with the 2.2 backoff. **Constraint note:** this is a post-connect→EGV watchdog, NOT a connect timeout — adding a watch-only timeout on the CoreBluetooth *connect attempt itself* is prohibited (context §2 "No watch-only connect timeout", §7 DO NOT; the iPhone relies on CB's own retry).

**2.4 — MEDIUM — C1's "ONLY way the adapter starts scanning" comment overstates its scope; fork-internal rescans bypass it — by design, and they are the delivery engine** `[KNOWN — backlog, context §5; acknowledged as the C1 "known gap" in context §2; reframed + downgraded HIGH → MEDIUM in v2.1]`
- Trio: `G7WatchSensorAdapter.swift:658-664` documents C1 as the single scan entry point, gating scans on scene-active/`.running` session. Fork: `G7BluetoothManager.swift:447,466` self-initiates scans on every disconnect, bypassing C1. So "gated" slots are only gated until the first disconnect, and the `ble_gated` slot accounting (`:666-695`) undercounts actual radio activity.
- **v2.1 reframe:** the bypass is not a violation to suppress — it is the **delivery engine**. 73% of captures occur with no active session (context §8.2); the fork's autonomous reconnect loop is what produces them, exactly as it produces the iPhone's ~99% (context §2-Addition). Gating fork-internal rescans on runtime eligibility would kneecap background capture the same way the withdrawn sticky-stop would have. C1's real, still-valid job is narrower: don't *initiate fresh adapter-driven scan entries* (cold start, sensor swap, stale-binding reinit) from ineligible states.
- **Fix direction (v2.1):** documentation + accounting honesty, not behavior: (a) correct the C1 comment to scope the invariant to adapter-initiated scan entries; (b) annotate the `ble_gated` / slot accounting (and any dashboards built on it) as excluding fork-internal rescans, or add a fork-side `rescan_scheduled` telemetry event (5.4) so the denominator can be computed honestly. Do not gate the fork loop.

### G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift

**2.5 — MEDIUM — Configuration-retry exhaustion dead-ends a live connection** `[KNOWN — backlog (Medium), context §5 — C3 partial fix already shipped, context §3]`
- `G7PeripheralManager.swift:195-197`: after 5 failed configuration retries, `configure_retry_exhausted` is logged and nothing else happens. The peripheral remains connected, no notifications are armed, no delegate error fires, no disconnect — a permanently useless connection until the transmitter drops it. (C3 — context §3 — added the bounded retry itself; the exhaustion dead-end is the remaining gap.)
- **Fix direction:** on exhaustion, surface `readyingFailed` (or disconnect via the central) so the state machine re-enters scan. Fork change in the C3 path — shared with iPhone, validate both (context §3 C3 note); 3-step deploy (context §1).

### G7SensorKit/G7SensorKit/G7CGMManager/G7CGMManager.swift

**2.6 — MEDIUM — `sensor(_:didRead:)` keeps processing after triggering teardown on failed/ended sessions (iOS consumer)**
- `G7CGMManager.swift:365-373`: `sensorFailed` / `sessionEnded` call `scanForNewSensor()` (which nils `state.sensorID`/`activatedAt`) and then fall through to record/deliver the same message; `generateSyncIdentifier` (`:418-424`) now returns `"invalid"` for any display-only sample, and `state.latestReading` is repopulated from the dead session.
- **Fix direction:** `return` after each teardown branch (mirroring the watch adapter's `triggerEndOfSessionFromEGV` early-returns). **Layer note:** `G7CGMManager` is the iOS-only consumer and the iOS path runs ~99% EGV success in production (context §2-Addition) — treat as a low-urgency, iPhone-validated fix (upstream-PR style), not a watch-reliability lever. 3-step deploy if pursued (context §1).

**2.7 — MEDIUM — The ~5-minute advertisement window is observed, never *used***
- Trio tracks `reading_epoch` and runs an `expected_window` timer (`G7WatchSensorAdapter.swift:493-575`), but it only emits telemetry. Scan scheduling is uncorrelated with the window: in foreground the radio scans continuously; in background C1 defers and the slot is simply lost (`:666-695`). There is no "wake/arm scanning at reading_epoch − margin" logic anywhere, although the epoch is known to ±seconds.
- **Fix direction (adapter):** drive scan arming from the expected-window timer (start scanning at epoch−30s when runtime-eligible; stop at epoch+5min), instead of scan-always + gate. Consistent with the §2 constraint that only *when and how politely* the watch presents itself can be tuned.

### G7SensorKit/G7SensorKit/G7CGMManager/G7BluetoothManager.swift (lower severity)

**2.8 — LOW — `managerQueue_scanForPeripheral` re-issues `scanForPeripherals`/`registerForConnectionEvents` when already scanning** (`:227-242`) — harmless duplicate-filter resets, but each `resumeScanning()` from `start()`/`fetchNewDataIfNeeded` restarts the scan and re-registers; cheap to guard with `!centralManager.isScanning`. Fork DRIFT (shared path) — low priority; bundle with a justified fork change rather than shipping alone (context §2-Addition).

**2.9 — LOW — Discovery paths re-dispatch async and can interleave** — `didDiscover` re-async's onto its own queue (`:400-402`) while `connectionEventDidOccur` (`:191`) and `willRestoreState` (`:387-392`) call `handleDiscoveredPeripheral` in different hops; ordering between `.makeActive` rebind and a stale `.connect` is timing-dependent. `connectIfNotInFlight` (`:297-309`) absorbs most of it now. Document or unify the entry path.

**2.10 — LOW — Suffix-match binding can cross-connect in multi-G7 households**
- `G7Sensor.swift:282`: when following a sensor, connection is gated by `name.suffix(2)`; with two active G7s in BLE range whose serials share the final two characters, the observer binds to the wrong transmitter (auth will fail, producing persistent reconnect churn against the wrong device). Low probability, high confusion.
- **Fix direction:** compare full names when the full advertised name is available; fall back to suffix only for the DXCM↔Dexcom prefix variation. Shared matching logic — validate on iPhone (context §2-Addition); 3-step deploy (context §1).

---

## SECTION 3 — SESSION LIFECYCLE BUGS (WKExtendedRuntimeSession)

All in `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift`.

**3.1 — HIGH — `sessionPendingDidStart` can wedge session renewal forever** `[KNOWN — backlog, context §5]`
- `:318` — `renewSessionIfNeeded` refuses to request while `sessionPendingDidStart != nil`. The field is cleared only by `extendedRuntimeSessionDidStart` (`:1142-1144`), the pending-invalidation branch (`:1171-1175`), or `stop()`. If watchOS never delivers either callback for a `start()`ed session, no new session can ever be requested for the life of the process. There is no watchdog and no log line distinguishing this wedge from the normal debounce.
- **Attribution correction (context §5):** the historically dominant "start → immediate invalidation" failure mode had a CONFIRMED root cause — the missing `WKBackgroundModes: physical-therapy` plist key (fixed in build 204; in that mode the invalidation callback *did* arrive, so it is distinct from this wedge). This finding covers the residual no-callback-at-all case, which remains unguarded.
- **Fix direction:** when `start()` is requested, arm a 10–15s timeout that clears `sessionPendingDidStart` (after checking `state != .running`) and logs `ext_session_start_timeout`.

**3.2 — HIGH — A late invalidation from an *unowned* session triggers full teardown** `[KNOWN — backlog, context §5]`
- `extendedRuntimeSession(_:didInvalidateWith:)` `:1177-1208`: the `hasError` branch calls `stop()` for any erroring session that isn't in `invalidatingSessionIDs` and isn't the current `sessionPendingDidStart`. A session that was *superseded* (cleared from `extendedSession` at `:1158` on its own earlier invalidation, or replaced in `didStart` at `:1141`) is not tracked by any of those sets — its late/duplicate callback with a non-RBS error while foregrounded tears down the freshly-started pipeline and live session. The `invalidatingSessionIDs` mechanism (`:59`) protects only *intentionally* invalidated sessions; "no longer ours" sessions are unprotected.
- **Fix direction:** at the top of the handler, if `session !== extendedSession && session !== sessionPendingDidStart && !invalidatingSessionIDs.contains(id)`, log and return — never act on unowned sessions. (v2.1: once the 1.1 fix removes the teardown branch, a zombie callback's blast radius drops from "stops the pipeline" to state/log noise — this guard remains correct hygiene but is no longer protecting against a teardown.)

**3.3 — MEDIUM — Session invalidation mid-scan/mid-connect leaves CBCentralManager state to drift, then flood** `[tracked collectively on Medium backlog, context §5]`
- When a session invalidates mid-GATT, nothing quiesces the central (by design after C-207-1 — `:1187-1193` keeps BLE for background RBS kills). System-level `connect` requests never expire, so they queue while suspended; on the next runtime grant, queued `didConnect`/`didDisconnect` deliver in a burst that races `start()`'s `beginScanIfEligible(.resume)` + `consumeDeferredScanIfNeeded` (`:298-303`). `connectIfNotInFlight` (fork) absorbs duplicate connects, but the adapter still processes a connect/disconnect burst attributed to the *new* scene phase — muddying the telemetry used to compute foreground vs background success.
- **Fix direction:** timestamp the runtime gap and tag adapter events within ~2s of re-entry (`resumed_backlog=true`), or drain/ignore the first disconnect after re-entry.

**3.4 — LOW — Is the session always valid before GATT work? No — by design, and that is the workhorse** `[tracked collectively on Medium backlog, context §5; reframed + downgraded MEDIUM → LOW in v2.1]`
- `isRuntimeEligible` (`:129-131`) accepts scene-active without any session (frontmost apps have runtime), and fork-internal rescans/connects (2.4) run GATT with neither scene-active nor a session. v2.1 answer to this section's question: **no, and it shouldn't be** — 73% of captures arrive with no session (context §8.2); the session is wakeup substrate, not a GATT precondition. The C1 invariant is correctly scoped to adapter-initiated scan entries only.
- **Fix direction:** none behavioral — covered by the 2.4 documentation/accounting fix and the 1.1 teardown removal (which eliminates the one path where session state *destroyed* GATT work).

**3.5 — LOW — Are all invalidation reasons handled?**
- Reasons are decoded defensively, including `@unknown default` for the raw `-1` (`:1095-1104`); error-bearing invalidations split RBS-background (benign) vs other (teardown+recovery) (`:1186-1208`); `expired`/no-error logs only. Reason coverage itself is good — the gaps are 3.1/3.2 above, not missing enum cases. The 5s recovery task (`:1198-1208`) correctly resets `recoveryScheduled` on the skip path. (v2.1: the teardown+recovery branch and its machinery are slated for deletion under the 1.1 fix — after which every reason path reduces to clean-up-and-log, and this question closes entirely.)

---

## SECTION 4 — G7SENSORKIT API SURFACE ISSUES

### G7SensorKit/G7SensorKit/G7CGMManager/G7Sensor.swift

**4.1 — HIGH — `sensorDidConnect` is not guaranteed to fire; first-discovery sessions deliver `didRead` with no connect callback**
- `readied` fires `sensorDidConnect` only when `sensorID != nil` and matches (`G7Sensor.swift:211-216`). On the first discovery cycle (`sensorID == nil`), the sensor is accepted inside `handleGlucoseMessage` and `didRead` is invoked directly (`:169-192`) — no connect event ever. Trio had to reverse-engineer a "first-read bootstrap" (`G7WatchSensorAdapter.swift:836-875, 955-964`). Any other consumer keying session state off `sensorDidConnect` silently miscounts.
- **Fix direction (corrected for fix layer):** first line: **document the contract** on the protocol (`:15-35`) — purely additive. Firing `sensorDidConnect` from the discovery-accept path would also change iPhone-observed callback ordering (DRIFT per context §2-Addition) and should only be done with iPhone validation; 3-step deploy (context §1).

**4.2 — MEDIUM — `stopScanning()` neither stops scanning permanently nor only stops scanning** *(downgraded HIGH → MEDIUM in v2.1: latent hazard once the 1.1 fix removes the sole remaining caller)*
- `G7Sensor.swift:120-122`: `stopScanning()` = `disconnect()`, which cancels the live connection *and* (via the disconnect callback) triggers an automatic rescan (Finding 1.1 mechanism). The name invites misuse — it bit Trio's `stop()`, whose only caller (`:1195`) is slated for removal under the 1.1 fix (pending implementation). Similarly `scanForNewSensor()` (`:109-114`) silently clears sensor identity as a side effect.
- **Fix direction (v2.1):** documentation — state on the API that `stopScanning()` is "disconnect now; scanning resumes automatically" and that no quiescence primitive exists (intentional: the never-stop loop is the delivery model, context §2). If a true quiescence path is ever actually needed, it must be built adapter-side (re-issue `stopScanning()` after the disconnect callback and verify `isScanning` settles); a fork-side sticky `stop()` would gate the frozen `scanAfterDelay()` chain — DRIFT requiring iPhone-validated justification (context §7 DO NOT) and the 3-step deploy (context §1). None is needed today.

**4.3 — MEDIUM — `didDiscoverNewSensor` is a synchronous Bool callback on a private queue**
- `G7Sensor.swift:29, :175`: consumers must answer synchronously on `delegateQueue` with no actor/queue affordance. Trio's `@MainActor` adapter had to bypass its own isolation by reading UserDefaults directly in a `nonisolated` implementation (`G7WatchSensorAdapter.swift:817-824`). This API shape forces every Swift-concurrency consumer into a side-channel.
- **Fix direction:** async variant (`async -> Bool`) or a completion-based overload — ADDITIVE protocol extension (context §2-Addition); at minimum document the queue. 3-step deploy if pursued (context §1).

**4.4 — MEDIUM — `suspectedEndOfSession` semantics are heuristic, undocumented, and wrong for observer cadence** `[KNOWN — backlog, context §5 "eos_detected false positives"; established fact, context §8.2]`
- Producer: `pendingAuth && wasRemoteDisconnect` (`G7Sensor.swift:257-263`). The iOS consumer treats it as authoritative and destroys the session (`G7CGMManager.swift:341-346` → `scanForNewSensor()`); on the watch it measured 111/112 false-positive (build 205 — context §8.2) because the watch's normal 5-minute reconnect cycle looks like EOS to the phone-derived heuristic. D7 (build 206 — context §3/§8.1) already made the watch-side reaction log-only; the remaining issues are the undocumented API contract and the destructive iOS-consumer default that will trap the next consumer.
- **Fix direction:** document the heuristic on the protocol (additive). Renaming to `disconnectedBeforeAuth` is API-breaking on the shared delegate surface (the iOS consumer calls it at `G7CGMManager.swift:341-346`) — coordinate as a deliberate fork API rev with iPhone validation and the 3-step deploy (context §2-Addition, §1), or add an additively-named alias instead. Any change to the iOS consumer's destructive reaction is an iPhone behavior change — validate per context §2-Addition.

**4.5 — MEDIUM — Error types are stringly-typed and unenumerable**
- `G7SensorError` cases carry only `String` (`G7Sensor.swift:37-54`); `PeripheralManagerError` (notReady/timeout/unknownCharacteristic — the genuinely actionable distinctions) is `internal` (`G7PeripheralManager.swift:14-20`) and reaches the delegate flattened into `G7SensorError.controlError("...interpolated...")` (`:422-428`). Callers cannot branch on timeout vs missing characteristic vs not-ready.
- **Fix direction:** make the error enum carry typed causes (`case control(PeripheralManagerError)`) and expose `PeripheralManagerError`. API-breaking for existing consumers — coordinate as a deliberate fork API rev; 3-step deploy (context §1).

**4.6 — MEDIUM — Thread-safety contracts implicit/unenforced across the public surface**
- `isScanning`/`isConnected` crash via `dispatchPrecondition` if called from `managerQueue` (`G7BluetoothManager.swift:272-283`) — but nothing documents which queues delegate methods arrive on, so a consumer calling `sensor.isConnected` from a delegate callback compiles and dies at runtime (the fork itself hit this: workaround comment at `G7Sensor.swift:405-411`). `activationDate` is read cross-queue with no contract (Finding 1.3). `G7Telemetry.emit` has no documented set-once requirement (1.8).
- **Fix direction:** document queue contracts on `G7SensorDelegate` (additive); provide non-asserting async accessors. 3-step deploy if pursued (context §1).

**4.7 — LOW — `needsVersionInfo` is a public mutable knob mutated internally** (`G7Sensor.swift:79`, set by `G7CGMManager.swift:218`, cleared on delegateQueue `:316`) — ownership unclear; make it init-injected or internal.

**4.8 — LOW — `PeripheralConnectionCommand` `.connect` vs `.makeActive` undocumented** (`G7BluetoothManager.swift:14-18`) — the behavioral split (tracked-active + managed vs managed-only) is significant (drives `activePeripheralIdentifier` persistence) and only discoverable by reading `handleDiscoveredPeripheral`.

---

## SECTION 5 — RELIABILITY IMPROVEMENTS

**5.1 — HIGH — Reconnect loop needs backoff/ceiling for confirmed refusal loops** `[KNOWN — via 2.2, context §5]` — the concrete retry-logic gap behind refusal-loop churn; details, corrected attribution, and the v2.1 mechanics (adapter settle-loop vs minimal fork rescan-gate as justified DRIFT — the §6 P2a "Priority-1 gate" precondition no longer exists) in Finding 2.2. Must never throttle healthy window-timeout reconnects (context §8.2).

**5.2 — MEDIUM — Day-1 auth: no auth-aware accommodation exists**
- What exists today: discovery gating by expected name (`G7WatchSensorAdapter.swift:817-824`), C1 runtime gating (`:666-695`), C2 quarantine of dead identities (`:346-403`), and the fork's `connect_skipped` dedup. None of it is *auth-aware*: `auth_value_received gate_passed=false` (`G7Sensor.swift:378-402`) feeds telemetry only (event already exists — context §4 inventory; no new event needed). Nothing detects a gate-fail streak on a young sensor and widens retry spacing.
- Per context §2, the day-1 refusal itself is architectural (the transmitter decides; nothing local changes that) — only *when and how politely* the watch presents itself is tunable. Per context §8.2, do not infer refusals from disconnect counts (most pre-EGV disconnects are window timeouts); key the detector on actual `gate_passed=false` observations.
- **Fix direction:** surface auth-gate failures to the delegate (ADDITIVE fork callback per context §2-Addition; 3-step deploy); in the adapter, on a `gate_passed=false` streak for a sensor < 24h old, switch to window-anchored single attempts (one connect per expected window) instead of continuous retry.

**5.3 — MEDIUM — Error recovery paths that exist but are incomplete** `[tracked collectively on Medium backlog, context §5]`
- Configuration retry recovers discovery but not exhaustion (Finding 2.5).
- ~~Post-invalidation recovery runs only if foreground-active 5s later~~ — **superseded by the v2.1 1.1 fix:** with the teardown removed from the invalidation handler there is nothing to recover from; the half-stopped state (and the recovery task at `:1198-1208`) cease to exist.
- `requestWatchStateUpdate` retries only on explicit `sendMessage` error; the 30s timeout path falls back without retrying (`Trio/Trio Watch App Extension/WatchState+Requests.swift:304-313`).

**5.4 — MEDIUM — Logging gaps (structured events that should exist)** `[tracked collectively on Medium backlog, context §5]`
- Checked against the context §4 event inventory — none of the proposed events/fields already exist:
  - Fork: no event when `scanAfterDelay` self-initiates a rescan (the rescan trigger is invisible — only its consequences are logged); no event for `runCommand` `notReady` early-throws (only `command_timeout` exists); no event when `managedPeripherals` accumulates >1 entry. (Adding emissions is ADDITIVE per context §2-Addition, but the `rescan_scheduled` emission site is inside the frozen `scanAfterDelay()` — bundle with a justified change; 3-step deploy.)
  - Adapter: the `sessionPendingDidStart` wedge (3.1) is indistinguishable from debounce in `ext_session_renew_skipped` (existing reasons: `not_active|debounced` — context §4; the `guard` at `:318` returns silently). (v2.1: the previously proposed `adapter_stop` event is moot — `stop()` is being deleted under 1.1.)
- **Fix direction:** add `rescan_scheduled reason=disconnect|fail delay_s=…` (fork, additive — also the honest denominator for 2.4's accounting), and a new `reason=pending_start` value on the existing `ext_session_renew_skipped` event (adapter).

**5.5 — MEDIUM — Watchdog/timeout patterns missing where they'd prevent hangs** *(corrected)* `[tracked collectively on Medium backlog, context §5]`
- No auth/EGV watchdog post-connect (2.3 — adapter, endorsed by context §6 Priority 2b); no `sessionPendingDidStart` timeout (3.1 — adapter).
- ~~No ceiling on time spent `connecting`~~ — **RETRACTED (v2.0):** a ceiling on the CoreBluetooth connect attempt is a watch-only connect timeout, which is prohibited (context §2 "INTENTIONAL: No watch-only connect timeout"; §7 DO NOT; AGENTS.md v15 — the iPhone has no connect timeout and relies on CB's own retry).
- **Fix direction:** single per-connection-attempt watchdog in the adapter covering the **post-connect→EGV** span only (one timer arms at `did_connect`), plus the 3.1 pending-start timeout.

**5.6 — MEDIUM — Telemetry event ordering is not preserved end-to-end** `[tracked collectively on Medium backlog, context §5]`
- The fork serializes emissions (`G7Telemetry.swift:34-48`), but Trio's sinks re-dispatch each event as an unstructured `Task` (`ExtensionDelegate.swift:15-26`; adapter `log()` `G7WatchSensorAdapter.swift:443-456`), so cloud log order ≠ emission order precisely during bursts, which is when ordering matters for forensics.
- **Fix direction:** funnel into one `AsyncStream`/serial consumer per process, or stamp a monotonic sequence number into the line. (Adapter/Trio-side; no fork change needed.)

**5.7 — LOW — WatchLogger does file I/O per log line** `[tracked collectively on Medium backlog, context §5]`
- `WatchLogger.swift:299-353`: every `log()` opens/seeks/writes/closes `watch_log_daily.txt` (plus `print()`); BLE bursts make the logger a meaningful battery/latency tax inside the path being measured. Buffer and flush on the existing timer.

**5.8 — LOW — Heartbeat and expected-window timers silently stop in background suspension** — `DispatchSourceTimer` on a utility queue (`:468-543`) doesn't fire while suspended; the retroactive replay (`:493-529`) backfills `expected_window` but heartbeats just vanish, which reads as "process dead" in dashboards. Emit a `heartbeat_gap` on resume. (Per the context §5 verification rule: a `heartbeat` with `ext_session_state=2` is `.running`, not `.invalid` — interpret raw values via the mapped enum only.)

**5.9 — MEDIUM — Dropped WidgetCenter reloads are undetected and never re-requested** *(v2.3)*
- Save-path reloads pass `scheduleRetry: false` by design (`TrioComplicationDataStore.swift:829`),
  and the coalesced path skips its retry whenever the snapshot is <60s fresh (`:959-965`) — which
  on the save path it always is. Net: a reload WidgetKit drops on budget grounds is invisible and
  never re-asked; the face stays stale until the next reading (~5 min). The generation machinery
  (`reload_generation` written at request, `observed_generation`/`generation_delta` read at GTL)
  already measures servicing — drive **one** targeted re-request when a generation goes
  unserviced for ~120s. Plausible contributor to the GTL p90 ≈ 600s tail (2026-06-12 freshness
  check: p90 368s → 597s → 602s across 206/207/208 while medians stayed 16–21s).

**5.10 — LOW — Cold-start dedup drops same-timestamp content changes** *(v2.3)*
- `saveOnMain`'s fallback branch (`:764-766`, runs when the in-memory seed is unavailable)
  silently drops any snapshot with `readingDate == lastValidTimestamp` regardless of content,
  while the primary `shouldUpdate` path (`:606-645`) explicitly accepts
  same-timestamp-different-glucose. The two paths disagree on policy; align the fallback
  (compare content before dropping). Rare — needs a failed seed plus a re-sent/corrected reading.

---

## SECTION 6 — CODE QUALITY & SWIFT PATTERNS

**6.1 — HIGH — Core Bluetooth state restoration reliance on watchOS is unconfirmed [NEEDS VERIFICATION — kept open per context §7]**
- `G7BluetoothManager.swift:140` passes `CBCentralManagerOptionRestoreIdentifierKey`; `willRestoreState` (`:378-393`) and Trio's D6 launch ordering (`ExtensionDelegate.swift:5-11`) are built around being relaunched for BLE. Apple documents CB state preservation/restoration as an iOS feature, so the expectation is that it never fires on watchOS — but per context §8.2, the earlier "never fires" conclusion was an **instrumentation artifact** (the callback was OSLog-only, invisible to BetterStack). The M2 `will_restore_state` event was wired in C-207-2 precisely to answer this; **result pending**. Do not treat restoration as either working or void until the M2 data is in (context §7 DO NOT).
- **Fix direction:** answer from `will_restore_state` counts by platform over a multi-week window. If zero on watchOS, delete the restore-identifier path on watchOS and re-plan background acquisition around runtime sessions only; if non-zero, keep D6 and document it as load-bearing.
- **ANSWERED (v2.3, 2026-06-12 — build-208 soak): non-zero.** 17 `will_restore_state` fires on watchOS in ~21h of build 208 (vs 2 on 207), `restored_peripherals=` up to 3, arriving as the first ring event (`seq=1`) of the process. Restoration — at minimum the callback plus preserved-peripheral handoff at `CBCentralManager` init — is real on watchOS. **Keep D6 and the restore-identifier path; the delete option is dead.** Why 208 fires ~8× more often than 207 (prime suspect: C-208-16's `.poweredOn` connection-event registration) is the remaining attribution question for the soak; final wording lands with the 209-plan A2 row.

**6.2 — RETRACTED (v2.0) — `registerForConnectionEvents` availability/efficacy on watchOS**
- v1.x flagged this as "[NEEDS VERIFICATION] — undocumented whether watchOS delivers `connectionEventDidOccur` to third-party apps." **Contradicted by build history (context §8.1):** build-185 telemetry showed MOD-E (`registerForConnectionEvents` → `connectionEventDidOccur(.peerConnected)`) was the *dominant* successful reattach path on watchOS — 36 `peer_connected` events across 6 hours, reliably every ~5 minutes — and build 194 confirmed MOD-E fires together with `didConnect`. Efficacy on watchOS is empirically confirmed; no open question remains. (Related retired hypothesis: "MOD-E fires independently of `didConnect`" — also retracted, context §8.2.)

**6.3 — MEDIUM — `@MainActor` adapter performs blocking `managerQueue.sync` hops**
- `publishConnectionStatus` reads `sensor.isConnected` + `sensor.isScanning` — two `managerQueue.sync` round-trips on the main thread (`G7WatchSensorAdapter.swift:717-733`), invoked on every connection-status delegate event; `scanForNewSensor`/`resumeScanning`/`stopScanning` also sync onto `managerQueue` from main. Combined with Finding 1.2 (managerQueue stalled up to 2s), the watch UI thread can hitch for the same duration.
- **Fix direction:** have the fork push status snapshots through the delegate (ADDITIVE callback per context §2-Addition; 3-step deploy, context §1) instead of being polled, or cache last-known status adapter-side (no fork change).

**6.4 — MEDIUM — Concurrency discipline by `assert(Thread.isMainThread)` instead of isolation**
- `WatchState` (2634 lines) is an `@Observable NSObject` guarded by runtime asserts (~30 sites) that compile out of release builds; the two real escapes are Finding 1.7. Under Swift 6 strict concurrency this file will not migrate cleanly.
- **Fix direction:** mark the class `@MainActor` and make WCSession delegate methods `nonisolated` shims that hop (pattern already proven in `G7WatchSensorAdapter`).

**6.5 — LOW — Log timestamp formatter lacks locale/calendar pinning**
- `WatchLogger.swift:106-110`: `DateFormatter` with fixed pattern but default locale/calendar — devices on non-Gregorian calendars (Buddhist/Japanese) emit shifted years into BetterStack. Set `locale = Locale(identifier: "en_US_POSIX")` (or use `ISO8601DateFormatter` as `WatchErrorReporter` does at `:22-26`).

**6.6 — LOW — Force unwraps / IUOs in plausible-nil paths**
- `FileManager.urls(for:in:).first!` (`WatchLogger.swift:325-327, :511-513, :626-628`; `WatchErrorReporter.swift:152`) — documents dir effectively always exists; still trivially guardable. `centralManager: CBCentralManager!` (`G7BluetoothManager.swift:96`) is assigned in init-sync, safe but unnecessary as IUO.

**6.7 — LOW — `Thread.sleep` on a global queue per disconnect** (`G7BluetoothManager.swift:262-267`) — each post-EGV disconnect parks a libdispatch worker thread for 2s; storms can park several. A cleaner shape is `managerQueue.asyncAfter` — but this lives inside the frozen `scanAfterDelay()` path (context §7 DO NOT: no further changes without explicit iPhone-validated justification). Record as an observation; bundle with a future justified fork change only.

**6.8 — LOW — `WatchGlucoseHistoryStore` does synchronous disk writes under `queue.sync` from the caller's thread** (`WatchGlucoseHistoryStore.swift:82-105`) — BLE/HK insert callers (often main) block on JSON encode + atomic write. Make inserts `queue.async`; only reads need sync.

**6.9 — LOW — `Self.lastValidTimestamp` unsynchronized cross-thread write with an inverted main-thread guard** *(v2.3)* — `latestSnapshot()` (documented any-thread) hydrates the static directly when `appGroupDefaults != nil` and wraps in `onMain` only when it is nil (`TrioComplicationDataStore.swift:891-901`) — the protection sits on the wrong branch, so the common case gets the unsynchronized write while `saveOnMain` writes the same static on main. Benign in practice (a `Date` assignment); a TSan flag and a one-line fix: always assign via `onMain`.

**6.10 — LOW — Complication save path does disk I/O on the main thread per reading** *(v2.3)* — `saveOnMain` (`:722-806`) runs JSON encode + `.bak` remove/copy + atomic write on main per save, and `coalescedReloadOnMain` (`:961`) re-reads and re-decodes the snapshot **from disk on main** merely to decide retry-skip while `inMemorySavedSnapshot` is current. Use the in-memory copy for the retry decision; consider `.bak` every Nth save (atomic writes already prevent torn files); pairs with 6.8 and the 209 battery pass.

**6.11 — LOW — Source-less convenience `save(glucose:trend:...)` is dead code and a priority footgun** *(v2.3)* — `:689-707` has zero callers and builds `source: nil` (priority 0) snapshots that lose every ±1s arbitration and churn the final inequality-OR in `shouldUpdate`. Delete it, or make `source` a required parameter.

---

## SECTION 7 — ARCHITECTURAL OBSERVATIONS

**7.1 — The passive-observer model trades pairing conflicts for a structural auth ceiling** *(intentional — context §2)*
- What it does well: zero interference with the phone↔sensor bond, no Dexcom-app fights, no key material on the watch, simple mental model (the watch is a read-only eavesdropper that must be *accepted* by the transmitter).
- What it costs: the G7 decides whether to keep an unbonded central; on young sensors it mostly doesn't (13–17% day-1 success), and nothing the watch does locally can change that — only *when* and *how politely* it presents itself (context §2). The current design presents continuously and retries instantly; for the refusal-loop subset this converts each refusal into reconnect churn (2.2, with corrected attribution — the majority of pre-EGV disconnects are window timeouts, context §8.2). Foreground (81%) vs background (41%) success is largely "does the watch have radio runtime inside the window."
- Direction: keep the observer model but make presentation *windowed and polite* — anchor connect attempts to `reading_epoch` (2.7), back off on confirmed auth refusal (5.2), and treat phone-relay as the primary channel with BLE as opportunistic upgrade (the documented SLO stance, context §2).

**7.2 — The shipping G7SensorKit is selected by a single SHA-pinned build patch — RESOLVED/VERIFIED (context §1)**
- **Verified mechanism:** builds run from `Trio-dev` (`dev` + patch stack, patches 01–14 skipping `.skipped`). `Trio-dev/patches/02-g7-reading-time-with-seconds.patch` is the **sole** patch touching the submodule: it repoints `.gitmodules` from `loopandlearn/G7SensorKit` to `cachrisman/G7SensorKit` and bumps the pointer `4d0780d → 40b5871` — the fork HEAD (C-207-2) this review covers. Patch 12 is the watch BLE feature; patch 13 adds iPhone-side telemetry; both depend on 02 being applied first.
- **Verified deploy procedure (AGENTS.md, per context §1):** a fork edit reaches a build only after all three steps, in order: (1) commit on fork `main` and **push** to `github.com/cachrisman/G7SensorKit`; (2) repin the submodule SHA in patch 02 (the `Subproject commit …` line; `.gitmodules` already points at the fork); (3) build via `ci/local-build.sh --base-branch dev --build-only`. There is **no compile-time guard** — an un-pushed commit or un-bumped patch 02 silently uses the old G7SensorKit.
- **Residual risks (confirmed in context §1):**
  1. **Silent fork drift** — a stale pin succeeds silently (`patch-test.sh` validates apply, not compile) and ships the old BLE stack.
  2. **Patch identity drift** — patch 02's subject ("show reading timestamp with seconds") no longer reveals that it carries the entire fork delta (telemetry, C3, connect-dedup, C-207-2) and decides which BLE stack ships.
  3. **Feature-worktree inconsistency** — opening `Trio.xcworkspace` from the `Trio` worktree resolves G7SensorKit to `b791cf5` (no `G7Telemetry`); the watch target will not build there and Xcode indexing resolves wrong symbols. Stale by design; builds only from `Trio-dev`.
- Direction: rename patch 02 to reflect its real role (e.g. `02-g7sensorkit-fork-pin.patch`); add a `patch-test.sh` check that the pinned SHA equals the fork's `origin/main` HEAD (or an explicitly recorded intended SHA).

**7.3 — The adapter mirrors fork-private state instead of receiving intent** *(intentional tradeoff — context §2; direction is future cleanup, not current-sprint)*
- `boundSensorName` shadows the fork's private `sensorID` (`G7WatchSensorAdapter.swift:25-28`); self-inflicted disconnects are inferred via the `isScanningForNewSensor` 2s auto-clear heuristic (`:31-35, 707-715`); connect-vs-first-read is inferred via bootstrap (4.1). Every fork behavior change risks silently invalidating an adapter heuristic — C-207-2 is a confirmed instance (context §2). The tradeoff was avoiding fork API changes; the cost is a growing web of timing-based shadow state. (Note: per context §7 DO NOT, the 2s heuristic was never a candidate site for the — since-withdrawn — v2.0 sticky-stop direction; the two mechanisms are separate.)
- Direction: extend `G7SensorDelegate` with explicit intent callbacks (`didStartScan(reason:)`, `willDisconnect(initiator:)`, `didBind(sensorName:)`) and delete the heuristics — ADDITIVE fork changes, but explicitly deferred per context §2 ("future cleanup, not a current-sprint target").

**7.4 — WKExtendedRuntimeSession-as-substrate makes background acquisition opportunistic by design** *(intentional — context §2)*
- Sessions are only grantable while frontmost (D8, `:309-329`), so background windows depend on the system waking the suspended process for BLE events — which C1 then partially defers. Build-206 data confirms the framing (context §8.2): **73% of captures occurred with NO active extended runtime session**, 45% while backgrounded, only 4 during foreground-active — the background BLE central is the workhorse; the session is wakeup substrate, not the EGV pathway. The design accepts the foreground/background SLO split (81%/41%) and treats phone-relay as primary (context §2); there is no alternative entitlement on watchOS (CB restoration unconfirmed — 6.1).
- Direction: keep the documented SLO split and spend effort on window-anchored scanning (2.7), which improves *both* modes without new entitlements.

**7.5 — Observability is heavyweight inside the path it observes**
- Per-event: fork serial queue → closure → unstructured `Task` → MainActor → `WatchLogger` actor → per-line file append (+ battery probe, + WC flush machinery). During reconnect bursts this multiplies allocations, MainActor hops, and disk writes precisely when the system is resource-tight, and reorders events (5.6). The 7-field structured format itself is good; the transport is the problem.
- Direction: one bounded in-memory ring + single writer task; battery sampling on the timer, not per line.

**7.6 — `WatchState` is a god object**
- WC session delegate, HK observer pipeline, UI state, complication store coordination, background-task lifecycle, startup choreography, and G7 identity sync all live in one 2634-line `@Observable` class. Most individual pieces are carefully built (the bgtask completion paths are genuinely sophisticated), but every fix lands in the same file and the implicit main-thread contract (6.4) spans all of it.
- Direction: extract `ConnectivityCoordinator` (WC + bgtasks), `HealthKitGlucoseSource`, and `StartupSequencer`; `WatchState` keeps display state only. (Note: a `watch-messaging-centralization` design already exists and is intentionally deferred — context §8.4; reference that design rather than starting a new one.)

---

## RECOMMENDED PRIORITY ORDER

**1. Unwire BLE teardown from session invalidation; delete the dead stop machinery (Findings 1.1 / 2.1 / 3.5; v2.1 reframe)**
Verified facts drive this: `stop()` has exactly one caller — the invalidation handler's error branch (`:1195`) — and there is no user-facing BLE-off feature on the watch, so "session invalidation" and "BLE teardown" are two intents conflated at a single call site that nothing legitimate wants. Step 0 (BetterStack, **done 2026-06-10** — full table in Finding 1.1): builds 204–206 show the teardown fired ~4–7×/day with the 5s recovery skipped essentially every time (42/43, 14/14) — each firing a dark window until the next foreground entry; on build 207 C-207-1 intercepts the dominant background-RBS case and the teardown has fired **zero times in ~14h** (small sample). So this is confirmed as low-risk landmine removal rather than a large immediate capture win — and `recovery_skipped`/`post_stop_recovery_attempt` vanishing from telemetry is the post-ship verification signal. Then: remove the `stop()` call (the handler clears session refs, logs, returns — BLE and timers run on, iPhone-style), and delete `stop()`, `isStopped`/`isIntentionallyStopped`, the `recoveryScheduled` + 5s recovery machinery, and the `.off` status branch. Renewal independence is verified: `renewSessionIfNeeded()` is called solely from `applyForegroundActiveEntry()` (`:301`, D8) — the recovery task never carried renewal, so its deletion removes nothing. No fork change, no 3-step deploy, no iPhone risk; this completes the project's own three-step retreat from teardown-on-invalidation (build 194 → 204 → C-207-1).

**2. Refusal-loop backoff + connect→EGV watchdog (2.2 / 2.3 / 5.2; mechanics updated in v2.1)**
The connect→EGV watchdog is unchanged and adapter-only (~20–30s timer armed at `did_connect`; explicitly *not* a connect timeout, which is prohibited — context §7). The backoff's *counting* is adapter-side and keyed strictly on confirmed `gate_passed=false` streaks — never raw disconnect counts, since per context §8.2 most pre-EGV disconnects are healthy window timeouts and the always-retry loop is what catches the next window. The *deferral* mechanics lost their v2.0 precondition (the Priority-1 ignore-gate no longer exists), leaving two options to evaluate: an adapter settle-loop (`stopScanning()` post-disconnect + verify `isScanning` settles, resume at the backoff deadline — no fork change, fiddly) or a minimal fork rescan-gate delegate (default-`true`, iPhone unchanged — cleaner, but DRIFT into the frozen `scanAfterDelay()` path requiring iPhone-validated justification and the 3-step deploy). Decide with day-1 telemetry in hand.

**3. Fork hygiene: `G7Sensor` queue confinement (1.3) + didSet lock inversion (1.2) — via the 3-step deploy (context §6 Priority 3, §1)**
These are the correctness floor and the two fork changes the context explicitly endorses. The sensorID/pendingAuth/activationDate races run through the new-sensor discovery path — the day-1 flow with the worst numbers — and the didSet inversion stalls the BLE queue up to 2s inside the connect window. Both are mechanical (hop-and-copy; `sync`→`async`), low-risk, and shared-path improvements that benefit the iPhone too. They ship only via: fork commit + push → repin SHA in patch 02 → build; remember there is no compile-time guard against a stale pin.

**4. Harden the runtime-session delegate: pending-start watchdog + ignore unowned sessions (3.1 / 3.2)**
Corrected rationale: the historically dominant `reason=-1`/storm failure had a **confirmed** root cause — the `WKBackgroundModes: physical-therapy` plist regression, fixed in build 204 (`reason=-1` 256→8; context §5). What remains are two residual, lower-frequency holes: a silent permanent wedge (a pending session whose callbacks never arrive blocks all future renewals — 3.1, still the functional hole) and a zombie-callback hazard (an unowned session's late error mutating adapter session state — after Priority #1 removes the teardown branch, its blast radius is state/log noise rather than a pipeline stop, so the 3.2 guard is correctness hygiene and insurance against future reintroduction of action in that handler). Both fixes are ~10 lines plus telemetry (`ext_session_start_timeout`, `reason=pending_start`), and the new events make the residual `reason=-1` tail diagnosable instead of inferable.

**5. Anchor scanning to the expected reading window (2.7, supported by 7.4 and context §8.2)**
Once teardown is unwired (1) and refusal loops are bounded (2), the biggest remaining win is using the `reading_epoch` knowledge the adapter already maintains: arm the radio at `epoch − 30s`, disarm at `epoch + 5min`, attempt once per window with the backoff policy. Build-206 data shows the background BLE central — not the session — is the workhorse (73% of captures had no active session), so spending granted background runtime exactly inside the window attacks the foreground/background gap at its mechanism. One v2.1 caution applies here too: "disarm" runs into the same no-quiescence-primitive reality as the backoff (2.2) — evaluate the window-anchored design only with that mechanics question answered, and never let it suppress the fork's own reconnect cycle mid-window.

---

*Generated by Claude (Fable 5) — findings verified against the cited code paths (v1) and revised against `TRIO_REVIEW_CONTEXT.md` (v2.0); the remaining [NEEDS VERIFICATION] item (6.1) states exactly what evidence would close it.*

---

## Changelog

### v2.3 (2026-06-12)
- Complication update-path review pass: +6 findings (1.10 mmol sanitization MED; 5.9 unserviced
  reload MED; 5.10 cold-start same-ts drop LOW; 6.9 `lastValidTimestamp` race LOW; 6.10
  main-thread save I/O LOW; 6.11 dead source-less `save()` LOW). 6.1 ANSWERED non-zero from the
  build-208 soak (17 watchOS `will_restore_state` fires, restored_peripherals ≤3) — restore path
  kept. Verified-clean list recorded in the revision log. Totals 47 → 53 open.

### v2.2 (2026-06-10)
- Telemetry-driven recalibration; see REVISION LOG (v2.1 → v2.2). Highlights: 2.2/5.1 → LOW
  (tripwired contingency — no reconnect loop exists on 207), 2.3 = 15s (data-derived), 2.7 → LOW
  (premise corrected — bound steady-state never scans; `stored_id` 95–97%), 5.2/C-207-2 causal
  gloss corrected via GATT-funnel redo, 2.5 locked shared/unguarded, build-208 scope locked
  (impl plan v1.0). Counts: 2/7/21/17 = 47 open.

### v2.1 (2026-06-10)
- Priority-1 reframed from "make stop sticky in the adapter" to "unwire BLE teardown from session
  invalidation; delete the dead stop machinery," after Charlie's pushback established there is no
  user-facing BLE-off feature and greps verified: `stop()` has exactly one caller (`:1195`),
  `isIntentionallyStopped` has zero readers, and `renewSessionIfNeeded()` is called solely from
  `applyForegroundActiveEntry()` (`:301`) — so deleting the recovery task removes no renewal path.
- Findings reframed/downgraded: 1.1 rewritten (intent separation), 2.1 rewritten (no stopped
  state needed), 2.4 HIGH→MEDIUM (fork rescans are the delivery engine; fix is docs/accounting),
  3.4 MEDIUM→LOW (session-less GATT is by design), 4.2 HIGH→MEDIUM (latent API hazard only).
- 2.2/5.1 backoff mechanics restated (the §6 P2a "Priority-1 gate" precondition no longer
  exists): adapter settle-loop vs minimal fork rescan-gate (DRIFT). 5.3/5.4/3.5 updated for the
  deleted machinery. Priority Order #1/#2/#5 rewritten; BetterStack pre-check
  (`ext_session_unexpected_invalidation triggering_teardown=true`, watchos, post-207) added as
  step 0. Severity mix now 2 CRITICAL / 9 HIGH / 22 MEDIUM / 14 LOW (47 open unchanged).
- Post-revision verification (2 lenses: stale references, counts/log accuracy) found and fixed:
  a stale present-tense sticky-stop reference in 7.3; Priority #4 still using the pre-reframe
  "zombie callback stops the pipeline" rationale (now aligned with 3.2's v2.1 note); 4.2
  describing the pending 1.1 caller-removal as already-shipped code (re-tensed to "pending
  implementation"). Counts verified clean.
- **Priority-1 step 0 executed (2026-06-10):** BetterStack 30-day query (hot+S3,
  `GROUP BY build, platform`) — teardowns: 43 (b204) / 2 (b205) / 14 (b206) / **0 (b207, ~14h)**;
  recovery skipped 42/43 and 14/14 pre-207 (every background firing = dark window); 1
  `bg_invalidation_ble_kept` on 207 confirms C-207-1 interception. Results recorded in
  Finding 1.1 and Priority Order #1: removal proceeds as low-risk landmine elimination.

### v2.0 (2026-06-10)
- Revised against `TRIO_REVIEW_CONTEXT.md` per its Sections 1, 2, 2-Addition, 3–8. See the
  REVISION LOG section at the top for the itemized changes: Priority-1/2 fix-layer corrections
  (fork → adapter), 6.2 retracted, 5.5 corrected (no watch-only connect timeout), storm/`reason=-1`
  attribution corrected, 7.2 resolved with the verified 3-step deploy, [KNOWN — backlog] tags added,
  fork-edit fixes annotated with the 3-step deploy, priority order rewritten, counts updated
  (47 open + 1 retracted + 6 observations).
- Post-revision adversarial verification (4 lenses vs the context doc) found and fixed: 4.2's
  sticky-`stop()` mislabeled ADDITIVE (it gates the frozen rescan chain → DRIFT framing added);
  4.4's rename mislabeled additive (API-breaking → fork-API-rev framing); six fork-edit fix
  directions missing the per-finding 3-step deploy note (1.9, 2.6, 2.10, 4.3, 4.6, 6.3); KNOWN
  count corrected 16 → 17 (5.1 via 2.2 was tagged but uncounted).

### v1.1 (2026-06-10)
- **7.2 verified:** confirmed the build mechanism via `Trio-dev/patches/02-g7-reading-time-with-seconds.patch` and `Trio-dev/docs/README.md` — the fork @ `40b5871` is what ships. Rewrote 7.2 from "[NEEDS VERIFICATION] committed tree may not build" to the verified patch-stack mechanism plus three residual risks (silent fork drift on un-regenerated SHA pin, patch identity drift, feature-worktree inconsistency). Updated the header note accordingly.
- Remaining [NEEDS VERIFICATION] items: 6.1 (CB state restoration on watchOS — answerable via the M2 `will_restore_state` BetterStack event), 6.2 (`registerForConnectionEvents` efficacy on watchOS).

### v1 (2026-06-10)
- Initial review: 48 findings + 6 architectural observations across `Trio` watch extension and the `G7SensorKit` fork. Originally written to `~/trio-fable5-review.md`; moved into `docs/in-progress/` by Charlie.
