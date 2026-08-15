> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 208 — Implementation plan

**Version:** 1.0
**Status:** Approved (Charlie, 2026-06-10); C-208-1 already implemented; remainder in progress
**Created:** 2026-06-10 CEST
**Last updated:** 2026-06-10 CEST

**Sources:** [trio-fable5-review.md](../trio-fable5-review.md) v2.1+ (findings), `TRIO_REVIEW_CONTEXT.md` v3
(§5 baselines: teardown counts, connect cadence, GATT funnel, attach paths), build-204→207 plans/logs.
**Log:** [watch-g7-direct-ble-observer-build208-impl-log.md](watch-g7-direct-ble-observer-build208-impl-log.md)

---

## Theme

Correctness floor + telemetry integrity + background wake-path completion. No scheduler, no new
state machines ("don't build a timer empire inside the BLE state machine"). Every behavioral
item is either fires-never insurance, a race/stall fix, or completes a wake path that mostly
already exists.

## Context (what the data established, 2026-06-10)

1. **Teardown-on-invalidation removed (C-208-1, done):** `stop()`'s only caller was the
   invalidation error branch; recovery was skipped 58/59 firings (204–206); 0 teardowns on 207.
2. **No reconnect storm exists:** b207 averages 1.04 `did_connect` per active 5-min window
   (max 3). Backoff (review 2.2/5.1) is a **tripwired contingency**, not build content.
   Tripwire: ≥4 connects/window on 207+.
3. **GATT funnel (b206/207):** connect→ready 100%, →auth-subscribe 92–96%, →auth-grant 72–81%,
   →EGV 92–94% of grants. Sessions die *waiting for the transmitter's auth grant* (51% of
   pre-EGV drops at 0–2s; ~29% at window end), not computing. C-207-2's "background CPU
   starvation" gloss corrected in context doc v3.
4. **Attach paths:** `stored_id` (pending connect, **no scan**) = 95–97% of attaches on both
   platforms. The bound steady-state already idles without scanning. Two wake-path gaps remain:
   connection-event registration only happens inside the (rare) scan branch, and
   `connectionEventDidOccur` ignores events while bound.
5. **Stall proxies:** `command_timeout` + `configure_block_skipped` ≈ 38–80/day watchos,
   ~9–29/day ios — the 1.2 lock inversion is measurable on both platforms via before/after.
6. **`configure_retry_exhausted` = 0** on both platforms (30d): the 2.5 escalation is
   fail-safe insurance for a state never yet reached.

## Items

### Adapter (`Trio/Trio Watch App Extension/`, feature branch → patch 12)

| ID | Item | Review finding | Design |
|---|---|---|---|
| C-208-1 | ✅ Unwire BLE teardown from session invalidation; delete stop machinery | 1.1/2.1/3.5 | Done — commit `694e006b7`; see impl log |
| C-208-2 | Pending-start watchdog | 3.1 | After `session.start()` in `renewSessionIfNeeded`, arm a 15s `Task`: if `sessionPendingDidStart === session` and `state != .running`, clear it + log `ext_session_start_timeout`. Identity-guarded (no generation machinery). |
| C-208-3 | Unowned-session guard | 3.2 | Top of `didInvalidateWith`: if session is neither `extendedSession` nor `sessionPendingDidStart` nor intentionally-invalidated → log `ext_session_unowned_invalidation` + return. Compute ownership flags BEFORE clearing refs. |
| C-208-4 | Connect→EGV watchdog, **15s** | 2.3 | Armed in `recordSessionConnect` (token = `adapterSessionID`), self-cancelling via token+`hadEGVThisSession` checks; on fire: log `egv_watchdog_fired` + `sensor.stopScanning()` (disconnect → fork's normal re-attach). 15s > max-ever observed connect→EGV (13s); NOT a connect timeout (prohibited) — covers post-connect→EGV only. Expected fire rate ≈ 0 (zombie class was 204/205-era; C3 fixed the cause; this is the 2.5-gap backstop + regression detector). |
| C-208-5 | WatchLogger phantom-timeout fix | 1.6 | `guard !Task.isCancelled` after the sleep in `sendMessageAwaitingReply`'s timeout task. Removes false "sendMessage timed out" on every ACKed send. |
| C-208-6 | WatchState cross-thread fixes | 1.7 | Capture `Date()` locally in `didReceiveUserInfo` and assign `lastUserInfoReceiveTimestamp` inside the main hop; wrap `didFinish`'s `loadFallbackDataFromComplication()` in `DispatchQueue.main.async`. |
| C-208-7 | Telemetry init ordering | 1.8 | `ExtensionDelegate`: assign `G7Telemetry.emit` BEFORE constructing `G7WatchSensorAdapter.shared`. |
| C-208-8 | Log timestamp locale pinning | 6.5 | `en_US_POSIX` locale + Gregorian calendar on `WatchLogger.dateFormatter`. |
| C-208-9 | Producer-side log ring | 5.6/5.7/7.5 | **New file** `WatchTelemetryRing.swift`: lock-guarded ring (512 entries, drop-oldest with drop counter, monotonic `seq=` stamped into each line) + single drainer task feeding the existing `WatchLogger` transport. `G7Telemetry.emit` and adapter `log()` enqueue synchronously — no per-event `Task` spawn / MainActor hop on BLE paths. Daily-log batching deferred to 209. **Patch regen MUST use `--extra-files` for the new file** (build-206 lesson: silently dropped otherwise). |
| C-208-10 | Defer-tail v1 ("first write secures the capture") | slim-path | `handleSensorDidRead` hot part ends at: dedup/sequence + counters + `lastEGVEpoch` + reanchor + persist a `PendingEGVTail` record (epoch/mgdl/seq/trend/delta inputs, UserDefaults JSON). Tail (history insert → complication save → WatchState apply → publish) runs via `drainPendingEGVTail()`: immediately after the hot part, on `applyForegroundActiveEntry`, on next EGV (drain old before writing new), and on `start()` (launch replay after process death). Ordering invariant preserved (history before chart refresh); coalescing = single-record slot, latest wins for display, both readings reach history. Background-skip of backfill/extendedVersion round trips deferred to 209 (needs a fork knob). |

### Fork (`G7SensorKit/` @ `main`, sibling repo → patch 02 repin)

| ID | Item | Review finding | Design |
|---|---|---|---|
| C-208-11 | C3 exhaustion escalation — shared, unguarded | 2.5 | In `scheduleConfigurationRetry`'s exhausted branch: emit `configure_retry_exhausted` (existing) then `central?.cancelPeripheralConnection(peripheral)` → normal disconnect/re-attach recovery. Decision (Charlie): no `#if os(watchOS)` — fires-never today (0 in 30d both platforms), strictly better than holding a dead connection when it does. |
| C-208-12 | didSet lock-inversion fix | 1.2 | `peripheral`/`delegate` didSet bookkeeping `queue.sync` → `queue.async`. A stale `needsConfiguration` window is C3-protected (fail-closed + retry). Verification = `command_timeout`/`configure_block_skipped` rate drop on BOTH platforms. |
| C-208-13 | `G7Sensor` shared-state race fix | 1.3 | Wrap `sensorID`, `activationDate`, `pendingAuth`, `needsVersionInfo` in `Locked<>` (the sanctioned lower-risk option vs queue-confinement refactor — avoids the `stopScanning()` same-queue-sync trap and minimizes ordering shifts). Public `needsVersionInfo` API preserved via computed accessor. The one item with real behavioral surface: timing-sensitive heuristics (`suspectedEndOfSession`, makeActive/connect decisions) now read defined values at defined times. iPhone validation via telemetry (below). |
| C-208-14 | `G7Telemetry.emit` set-once safety | 1.8 | Back the static var with `Locked<closure?>`; reads in `emitG7Telemetry` go through the same lock. |
| C-208-15 | `rescan_scheduled` telemetry | 5.4 / 2.4 | One `emitG7Telemetry("rescan_scheduled", "delay_s=… had_glucose=…")` in `scanAfterDelay()` (additive telemetry hook — sanctioned; no control-flow change). Gives the wake-path work its denominator. |
| C-208-16 | Connection-event wake path (the experiment, re-scoped) | new / absorbs old 2.7+exp | (a) `registerForConnectionEvents(options: [.serviceUUIDs: [FEBC, cgmService]])` at `centralManagerDidUpdateState(.poweredOn)` — registration no longer rides the rare scan branch (build-190 lesson). (b) `connectionEventDidOccur`: handle `.peerConnected` for the **bound** peripheral too (today guarded to discovery mode only) → `handleDiscoveredPeripheral` → `connectIfNotInFlight` (no-op nudge if a connect is already pending; the value is the WAKE + telemetry). New `connection_event` telemetry. No flag (Charlie's call); revert = small 209 diff. NOT a scan-policy change — `stored_id` data shows the bound state already doesn't scan. |
| C-208-17 | Delegate contract docs | 4.1/4.4 | Doc comments on `G7SensorDelegate`: first-discovery delivers `didRead` with no `sensorDidConnect`; `didDiscoverNewSensor` is synchronous on the private `delegateQueue`; `suspectedEndOfSession` = pendingAuth-at-remote-disconnect heuristic, 111/112 false on watch cadence — do not take destructive action without corroboration. |
| C-208-18 | `glucoseTimestamp` underflow guard | 1.4 | `guard messageTimestamp >= UInt32(age) else { return nil }` in `G7GlucoseMessage.init` — rejects the corrupt packet instead of trapping. |

## Verification strategy (no debug builds / no TSan in the TestFlight pipeline)

TSan requires a debug/test build; the Trio pipeline is TestFlight-only. Alternatives, in order
of weight:

1. **`dispatchPrecondition` guards (active in release builds):** the fork already uses them
   pervasively and they remain enforced in `-O` builds — queue-contract violations crash loudly
   in production rather than corrupting silently. C-208-13 keeps/extends them where access
   contracts change.
2. **Structure over discipline:** `Locked<>` wrapping makes the 1.3 races impossible by
   construction (no "remember to hop" contract to violate).
3. **BetterStack before/after on both platforms** — the field validation the fork strategy
   requires: `command_timeout`/`configure_block_skipped` rates (C-208-12), `suspected_end_of_session`
   frequency by platform (C-208-13's most timing-sensitive downstream heuristic), the GATT
   funnel rates, `attach_path` + `connection_event` mix (C-208-16), capture rate vs the 207
   baseline.
4. **Optional, outside the pipeline:** the G7SensorKit fork builds standalone
   (`G7SensorKit.xcodeproj`) — its unit-test scheme CAN run locally in Xcode with TSan enabled,
   independent of TestFlight constraints. Available if C-208-13 ever needs deeper interrogation;
   not a gate for 208.
5. AGENTS.md rule 10 applies: static review + `patch-test.sh`; compile confirmation via
   `ci/local-build.sh` is a user-run step.

## Post-ship telemetry checklist (build 208, `platform=watchos` unless noted)

- `recovery_skipped` = 0, `post_stop_recovery_attempt` = 0 (C-208-1 signal; reappearance = regression)
- `ext_session_unexpected_invalidation` only ever `triggering_teardown=false`
- `ext_session_start_timeout` ≈ 0 (each one = a previously-invisible wedge caught)
- `egv_watchdog_fired` ≈ 0 (each one = a zombie the C3 gap let through)
- `command_timeout` + `configure_block_skipped` rates drop vs 207, **both platforms** (C-208-12)
- `suspected_end_of_session` per-connect rate ≈ unchanged on **ios** (C-208-13 behavioral guard)
- `connection_event` events appear; `attach_path` mix and capture rate vs 207 baseline (C-208-16)
- `seq=` gaps + ring `dropped=` counter ≈ 0 under normal load (C-208-9)
- backoff tripwire: any 5-min window with ≥4 `did_connect` (watchos) → revisit review 2.2

## Deploy sequence

1. Fork: commit on `main` → **push** to `github.com/cachrisman/G7SensorKit` (user/build-time step).
2. Repin SHA in `patches/02-g7-reading-time-with-seconds.patch` (deploy step).
3. Trio: feature-branch commits → `mid-stack-update.sh --patch 12 --cherry-pick <shas>`
   **with `--extra-files "Trio Watch App Extension/WatchTelemetryRing.swift"`** (new file!).
4. `patch-test.sh` → build per AGENTS.md "When the user instructs a build" (ask flags).

## Risks

- **C-208-13** is the only item with real behavioral surface (defined-time reads can shift rare
  interleavings of `suspectedEndOfSession` / connect-intent on both platforms). Mitigation:
  `Locked<>` minimal-diff approach, iOS telemetry guard above, optional local TSan run.
- **C-208-10** is the largest new adapter surface; its failure mode is display staleness (a
  deferred tail), never a lost capture (the secure-write precedes it). Cut to 209 if review
  bandwidth runs out — explicitly approved as the first cut.
- **C-208-9** new file ⇒ the `--extra-files` regen requirement; the "Files in patch: N" count
  must increase by 1 (build-206 lesson).
- **C-208-16** changes background dynamics with no flag; revert is a small 209 diff. Phone relay
  remains the primary channel throughout (context §2).

---

## Changelog

### v1.0 (2026-06-10)
- Initial plan: 18 items (C-208-1 pre-implemented), re-scoped connection-event experiment per
  the attach-path baseline (stored_id 95–97% ⇒ no scan-policy change needed), TSan-alternative
  verification strategy, post-ship telemetry checklist, deploy sequence with `--extra-files`
  callout.
