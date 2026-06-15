> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 208 — Implementation log

**Version:** 1.5
**Status:** SHIPPED — build 208 built + uploaded to TestFlight + release recorded
(2026-06-11 00:16 UTC, 13m48s, exit 0). Awaiting BetterStack post-ship verification
(checklist in the impl plan).
**Created:** 2026-06-10 CEST
**Last updated:** 2026-06-11 CEST

**Plan:** [watch-g7-direct-ble-observer-build208-impl-plan.md](watch-g7-direct-ble-observer-build208-impl-plan.md)
v1.0 (authoritative scope — 18 items, C-208-1 … C-208-18). Decision trail:
[trio-fable5-review.md](../trio-fable5-review.md) v2.2 REVISION LOGs + `TRIO_REVIEW_CONTEXT.md` v3
(§5 baselines: teardown counts, connect cadence, GATT funnel, attach paths).

> **Scope expansion (v1.1):** this log originally covered only C-208-1 (the Priority-1 teardown
> unwire). Build 208 now bundles the correctness floor (fork races/stalls), fire-never watchdogs,
> telemetry-integrity fixes, the producer-side log ring, defer-tail v1, and the re-scoped
> connection-event wake path. Per-item entries are appended below as they are implemented.

---

## Repository scope (this entry)

One repo changed:

- **Trio feature branch** `feature/watch-g7-direct-ble-observer-synthesis` (worktree `Trio/`) —
  C-208-1, single file. Reaches a build via **patch 12** (`patches/12-direct-ble-observer.patch`),
  which must be regenerated with the feature commit folded in.
- **G7SensorKit fork: NOT changed.** No patch 02 repin needed. `scanAfterDelay()` and
  `stopScanning()` are untouched (intentional shared iPhone/watch behavior — context preamble §2).
- **No new files; no `project.pbxproj` edits; no project sync run** (AGENTS.md rule 6 — no
  project membership refresh is expected, since only an existing file changed).

---

## Pre-implementation verifications (all passed before any edit)

1. **`stop()` call-site census:** exactly one caller in the entire watch extension — the
   invalidation handler's error branch (`G7WatchSensorAdapter.swift:1195` pre-change). No
   user-facing BLE-off feature exists; no settings/debug path calls it.
2. **`isIntentionallyStopped` reader census:** zero readers anywhere.
3. **Renewal-path independence:** `renewSessionIfNeeded()` is called from exactly one site —
   `applyForegroundActiveEntry()` (`:301`). `start()` never calls it (D8, build 206, comment at
   `:873`). The 5s recovery task carried no session-renewal responsibility; deleting it removes
   no renewal path.
4. **BetterStack baseline (30-day window, hot+S3, `platform=watchos`):**

   | build | window | teardowns | recovery_skipped | recovery ran | bg_invalidation_ble_kept |
   |---|---|---|---|---|---|
   | 204 | ~6d | 43 | 42 | 1 | — |
   | 205 | ~1d | 2 | 2 | 0 | — |
   | 206 | ~3d | 14 | 14 | 0 | — |
   | 207 | ~14h | **0** | 0 | 0 | 1 |

   Pre-C-207-1 the teardown fired ~4–7×/day and its recovery was skipped 58/59 times (background
   at invalidation) — every firing a dark BLE window until the next foreground entry. On 207,
   C-207-1 intercepts the dominant RBS-background case. Build-203's 256 invalidations were all
   `pending_start_invalidated` (the WKBackgroundModes plist regression signature — independent
   confirmation of the build-204 root cause; that path never reached the teardown).

---

## C-208-1 — Unwire BLE teardown from session invalidation; delete dead stop() machinery

**File:** `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` (only file changed)
**Commit:** `694e006b7` (`feature/watch-g7-direct-ble-observer-synthesis`)
**Diff:** 1 file, +51/−96

### Behavior change

`extendedRuntimeSession(_:didInvalidateWith:)` error branch is now **log-only**:

- Background `RBSAssertionErrorDomain` errors → `ext_session_bg_invalidation_ble_kept`
  (unchanged event; the `recoveryScheduled = false` side effect is gone with the variable).
- All other errors → `ext_session_unexpected_invalidation` now logs
  **`triggering_teardown=false`** (was `=true` followed by `stop()` + 5s foreground-gated
  recovery task).
- No-error invalidations → `ext_session_natural_or_unknown_expiry` (unchanged).

Session invalidation now means *session cleanup only*: references are cleared at the top of the
handler (unchanged), renewal happens on the next foreground entry via `renewSessionIfNeeded()`
(unchanged, D8), and the BLE pipeline + adapter timers run for the life of the process — the
iPhone model.

### Deletions

| Symbol / branch | Was at (pre-change) | Why safe |
|---|---|---|
| `func stop()` | `:278-296` | Sole caller removed; no off feature exists; teardown was half-effective (fork `scanAfterDelay()` resurrected scanning while adapter timers/status stayed dead) |
| `isStopped` | `:103` + reads `:247,:428,:553-554,:672,:724` | Constant `false` once `stop()` is gone; all reads constant-folded |
| `isIntentionallyStopped` | `:68-76` | Zero readers |
| `recoveryScheduled` + 5s recovery `Task` | `:108,:248,:1191-1208` | Recovery ran 1/59 firings (builds 204–206); carried no renewal path (verification 3) |
| `.off` branch in `publishConnectionStatus` | `:724` | Unreachable; `.off` remains only as WatchState's pre-first-event default |
| `reason=stopped` value in `expected_window` | `:554` | Unreachable; reason domain is now `ok\|no_sensor` |

### Retained (deliberate)

- **`invalidatingSessionIDs`** + its early-return branch: no inserters remain (the sole inserter
  was `stop()`), documented as such in the comment. Retained so any future intentional
  `invalidate()` gets its callback classified instead of falling through to the error branch.
  Compiles warning-free (still read/mutated). Verified harmless by the adversarial review.
- **`stopTimers()` at the top of `start()`**: provably a no-op now (`start()` is one-shot per
  process since `isStarted` is never cleared); kept as defensive code with a one-line comment.

### Telemetry semantics changes (for dashboard/query maintenance)

- `recovery_skipped` and `post_stop_recovery_attempt` **can no longer occur** — their
  disappearance is the post-ship verification signal; any reappearance = regression.
- `ext_session_unexpected_invalidation` now only ever carries `triggering_teardown=false`.
- `ext_session_intentional_invalidation` can no longer occur (no inserters into
  `invalidatingSessionIDs`).
- `expected_window` `reason` field loses the `stopped` value; `ble_gated` `identity_eligible`
  no longer factors a stopped state.
- Adapter never publishes `.off` status anymore (it remains WatchState's cold-start default
  until the first BLE event).

### Verification performed (AGENTS.md rule 10 — no build; static review)

1. Self-Review Protocol: full diff re-read; greps across all four watch targets for
   `isStopped`, `isIntentionallyStopped`, `recoveryScheduled`, `.stop()` — zero matches.
2. Two-lens adversarial agent review (compile/reference integrity; behavioral equivalence on
   every path that previously touched the deleted state): **passed, no blockers**. 4 notes; 2
   actionable (stale `applyNewSensorName` doc-comment clause; `stopTimers()` defensive comment)
   — both applied before commit. 2 informational (the retained `invalidatingSessionIDs` design;
   confirmed compile-safe).
3. `scripts/patch-test.sh` — **pending** (runs after patch 12 regeneration, below).

---

## C-208-2 … C-208-10 — Adapter batch (watchdogs, ring, defer-tail, cross-thread fixes)

**Files:** `G7WatchSensorAdapter.swift`, `ExtensionDelegate.swift`, `WatchLogger.swift`,
`WatchState.swift`, **`WatchTelemetryRing.swift` (NEW FILE)**
**Commit:** `c144e9e5c` (5 files, +295/−40)

- **C-208-2 (3.1):** 15s pending-start watchdog after `session.start()`; identity-guarded; logs
  `ext_session_start_timeout`. The renew-skip guard now logs `reason=pending_start` (previously a
  silent return indistinguishable from the debounce).
- **C-208-3 (3.2):** ownership computed before reference-clearing in `didInvalidateWith`;
  unowned sessions log `ext_session_unowned_invalidation` and return.
- **C-208-4 (2.3):** 15s connect→EGV watchdog armed in `recordSessionConnect`; on fire logs
  `egv_watchdog_fired` + `sensor.stopScanning()` (fork re-attaches normally). Token-guarded by
  `adapterSessionID`; EGV/disconnect invalidate it implicitly.
- **C-208-5 (1.6):** `guard !Task.isCancelled` in WatchLogger's send-timeout task.
- **C-208-6 (1.7):** `lastUserInfoReceiveTimestamp` now written only on main (wall clock captured
  on the WC queue, assigned in the main hop); `didFinish`'s fallback call hops to main.
- **C-208-7 (1.8):** `G7Telemetry.emit` assigned before adapter construction.
- **C-208-8 (6.5):** log timestamp formatter pinned to `en_US_POSIX` + Gregorian.
- **C-208-9:** `WatchTelemetryRing` — synchronous producer-side ring (512, drop-oldest with
  surfaced `ring_dropped=` counter, monotonic `seq=`), single drainer into the existing
  `WatchLogger` transport. Adapter `log()` and the fork's `emit` closure enqueue synchronously;
  `syncTelemetryRingContext()` keeps emit-time session attribution current (5 call sites).
  Project membership via the watch target's synchronized file group (no pbxproj edit; none run).
- **C-208-10:** defer-tail v1. `PendingEGVTail` secure-write at EGV parse; tail (history →
  complication → UI, W1/W2 order preserved) drains immediately and replays on launch /
  foreground entry / next EGV (drain-before-persist keeps the single-record slot lossless).
  Clear-after-cascade + downstream dedup make double-replay harmless.

## C-208-11 … C-208-18 — Fork batch (G7SensorKit `main`)

**Files:** `G7PeripheralManager.swift`, `G7Sensor.swift`, `G7BluetoothManager.swift`,
`G7Telemetry.swift`, `G7GlucoseMessage.swift`
**Commit:** `9f57ea9` (5 files, +136/−21) — originally committed unsigned as `781abb0`
(1Password agent unavailable headlessly), then amend-signed by Charlie, **pushed to
`origin/main`**, and **patch 02 repinned** to `9f57ea9ab3…` (verified 2026-06-10).

- **C-208-11 (2.5):** exhaustion branch now disconnects (`action=disconnect` field added);
  shared, unguarded per decision (state unreached in 30d on both platforms).
- **C-208-12 (1.2):** `peripheral`/`delegate` didSet bookkeeping `queue.sync` → `queue.async`
  (lock-order inversion vs `runCommand` removed; stale-`needsConfiguration` window is
  C3-protected). `debugDescription`'s sync left as-is (debug-only).
- **C-208-13 (1.3):** `sensorID`, `activationDate`, `pendingAuth`, `needsVersionInfo` wrapped in
  `Locked<>` (the sanctioned lower-risk option); all call sites unchanged (computed properties);
  public `needsVersionInfo` API shape preserved.
- **C-208-14 (1.8):** `G7Telemetry.emit` lock-backed.
- **C-208-15 (5.4):** `rescan_scheduled delay_s= had_glucose=` emitted in `scanAfterDelay()` —
  observability only, no control-flow change to the frozen path.
- **C-208-16:** connection-event wake path — registration moved to `.poweredOn` (was
  scan-branch-only; `stored_id` = 95–97% of attaches meant it was usually absent), and
  `.peerConnected` now handled for the bound peripheral (was discovery-mode-only); new
  `connection_event peripheral= bound=` telemetry. Routes through `connectIfNotInFlight` (no-op
  nudge when a connect is already pending).
- **C-208-17 (4.1/4.4):** `G7SensorDelegate` contract docs (queue contract; first-discovery
  connect-callback gap; `didDiscoverNewSensor` sync-on-delegateQueue; `suspectedEndOfSession`
  heuristic semantics + 111/112 false-positive warning). Zero behavior.
- **C-208-18 (1.4):** `G7GlucoseMessage.init` rejects `age > messageTimestamp` (underflow trap).

---

## Adversarial verification results (2026-06-10) + C-208-V1 fixes

Two-lens review (compile/reference integrity; behavioral soundness) of `c144e9e5c` + the fork
batch: **14 findings — 2 blockers, 3 concerns, 9 notes.** All blockers/concerns and 7 of 9
notes fixed; 2 notes accepted as documented behavior.

**Trio fixes (`b2417f7bd`):**
- BLOCKER: shell-heredoc escape artifact `guard \!buffer.isEmpty` in `WatchTelemetryRing.swift`
  — would not compile (reproduced with swiftc by the verifier). Fixed; diff-wide artifact scan
  clean.
- Ring: locking hoisted out of the async drain (`dequeueLine()` sync helper — Swift-6-safe);
  drop accounting moved to drain time (`ring_dropped=` window + `ring_dropped_total=`
  cumulative on an un-evictable line); context-attribution comment corrected (early-connection
  fork lines carry the prior session id by design).
- Adapter: `egv_dedup` now sets `hadEGVThisSession` (EGV watchdog can't false-fire on a healthy
  duplicate-only reconnection); `start()` publishes status AFTER the tail replay (stale-replay
  `.active` corrected immediately); intentional-invalidation branch clears a pending session it
  owns; pending-start watchdog ADOPTS a running-but-undelivered session (didStart-mirror)
  instead of skipping.

**Fork fixes (`d427db3` — UNSIGNED, needs amend `-S` + push + patch-02 re-repin):**
- `configurationRetryAttempts` reset when escalating to disconnect (stored_id re-attach reuses
  the same `CBPeripheral` instance, so the identity-guarded didSet never resets the budget —
  without this, post-exhaustion reconnections would fail-fast with no retry ladder).
- `connectionEventDidOccur`: pre-208 discovery-mode behavior restored (any event when unbound,
  incl. `.peerDisconnected`); bound case stays `.peerConnected`-only; event raw value added to
  `connection_event`.
- C-208-12 didSet comment corrected (stale-window protection is `configureAndRun`'s read-site
  `services == nil` check + `unknownCharacteristic` throws — not C3's retry).

**Accepted notes (no code change):** pbxproj/`--extra-files` operational reminder (executed
below); fork-line session-attribution semantics (documented in the ring's comment).

## Patch regeneration (2026-06-10)

- Pre-flight enumerated exactly the three 208 commits; first regen attempt **conflicted on
  C-208-1** — root cause: the committed patch 12 is the build-206 version (`2350c37cc`); the
  build-207 regen was never committed (correct per patch lifecycle), so the restored baseline
  lacked `1135fc67c`. Resolved per the AGENTS.md missing-intermediate-commit procedure.
- Final invocation: `mid-stack-update.sh --patch 12 --cherry-pick
  1135fc67c,694e006b7,c144e9e5c,b2417f7bd --extra-files "Trio Watch App
  Extension/WatchTelemetryRing.swift" --allow-behind-origin` (dev is 5/14 diverged from origin).
- Verified: **Files in patch 17 → 18**, `WatchTelemetryRing` content present (10 refs),
  provenance trailers record all four commits, feature tip `b2417f7bd`.
- **`patch-test.sh`: PASS** — all 13 active patches apply cleanly.

## SHAs at a glance

| Change | Repo / branch | SHA |
|--------|---------------|-----|
| C-208-1 — unwire teardown + delete stop machinery | Trio `feature/watch-g7-direct-ble-observer-synthesis` | `694e006b7` |
| C-208-2..10 — adapter batch (incl. NEW `WatchTelemetryRing.swift`) | Trio `feature/watch-g7-direct-ble-observer-synthesis` | `c144e9e5c` |
| C-208-11..18 — fork batch | G7SensorKit `main` (signed, pushed) | `9f57ea9` |
| C-208-V1 — verification fixes (Trio) | Trio `feature/watch-g7-direct-ble-observer-synthesis` | `b2417f7bd` |
| C-208-V1 — verification fixes (fork) | G7SensorKit `main` (signed, pushed; patch 02 repinned) | `cb216bd` (amend of `d427db3`) |

---

## Follow-ups (not yet done)

1. ~~Sign + push the fork fix~~ — **DONE** (Charlie): amend-signed as
   `cb216bdc16ed9c276742c10e89553e9287941471`, pushed; verified HEAD = origin/main, tree
   identical to reviewed `d427db3`, signature good.
2. ~~Re-repin patch 02~~ — **DONE** (Charlie repinned the `Subproject commit` line to `cb216bd`;
   agent additionally corrected the gitlink index hint `..b791cf56c` → `..cb216bdc1` so a
   `--3way` fallback cannot resolve the post-image to the stale fork SHA).
3. ~~Regenerate patch 12~~ — **DONE**: 18 files, ring content verified, provenance includes the
   build-207 intermediate (`1135fc67c`) + all three 208 commits.
4. ~~Validate the stack~~ — **DONE**: `patch-test.sh` PASS (13/13), re-run after the final repin.
5. **Build** — READY. On explicit instruction only, with user-chosen flags (AGENTS.md "When the
   user instructs a build").
6. **Post-ship BetterStack checks:** full checklist in the impl plan ("Post-ship telemetry
   checklist") — headline signals: `recovery_skipped`/`post_stop_recovery_attempt` absent;
   `triggering_teardown=false` only; `ext_session_start_timeout` ≈ 0; `egv_watchdog_fired` ≈ 0;
   `command_timeout`/`configure_block_skipped` rates drop on BOTH platforms;
   `suspected_end_of_session` per-connect rate ~unchanged on ios (C-208-13 guard);
   `connection_event` appears + `attach_path` mix; `seq=` gaps ≈ 0; backoff tripwire
   (≥4 `did_connect`/window) stays silent.

---

## Changelog

### v1.5 (2026-06-11)
- **Build 208 SHIPPED.** `./ci/local-build.sh --include-untracked --no-sync-upstream` (full
  deploy), log `ci-local-build-20260611-000216.log`. Stages: patch application 2s (all 13
  applied, both modified patches picked up), Build IPA 5m10s (zero compile errors),
  TestFlight upload 7m44s (no network/entitlement issues), record-release 28s. Total 13m48s,
  exit 0; `agvtool new-version -all 208` confirmed. Next: post-ship BetterStack checklist
  after a few days of wear.

### v1.4 (2026-06-10)
- Fork verification fixes signed/pushed as `cb216bd` (tree-identical to reviewed `d427db3`);
  patch 02 repinned (incl. gitlink index-hint correction `..b791cf56c` → `..cb216bdc1` to keep
  a `--3way` fallback from resolving to the stale fork). `patch-test.sh` re-run: PASS. Status →
  BUILD-READY.

### v1.3 (2026-06-10)
- Adversarial verification results recorded (14 findings; 2 blockers incl. a heredoc `\!`
  compile-breaker in the ring file). C-208-V1 fixes committed: Trio `b2417f7bd`, fork `d427db3`
  (unsigned). Patch 12 regenerated (17→18 files, conflict resolved by including the
  never-committed build-207 intermediate `1135fc67c` per AGENTS.md procedure); `patch-test.sh`
  PASS. Remaining before build: fork `d427db3` sign+push, patch-02 re-repin.

### v1.2 (2026-06-10)
- C-208-2 … C-208-18 implemented and committed: adapter batch `c144e9e5c` (incl. NEW
  `WatchTelemetryRing.swift`), fork batch `781abb0` (unsigned — amend `-S` before push).
  Follow-ups rewritten for the full deploy sequence (fork sign+push → patch-02 repin → patch-12
  regen with `--extra-files` → patch-test → build).

### v1.1 (2026-06-10)
- Scope expanded from C-208-1-only to the 18-item plan; header repointed to the impl plan.

### v1.0 (2026-06-10)
- Initial log: C-208-1 implemented and committed on the feature branch (`694e006b7`);
  pre-implementation verifications, deletion/retention inventory, telemetry semantics changes,
  and follow-up steps recorded.
