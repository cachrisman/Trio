# Watch G7 Direct-BLE — Build 217 Impl Log

**Plan:** `build217-impl-plan.md` v0.19 (Gate-0 verdicts + execution ledger)
**Branches:** `feature/watch-g7` (Trio) / `main` (G7SensorKit fork) / `dev` (Trio-dev patches)
**Predecessor:** build 216 (`0.8.4`, `trio-v0.8.4-216-localCI`) — instrumentation + W-7; its 44 h soak produced the Gate-0 verdicts that gated everything here.
**Status:** ✅ Implementation + patch integration + compile-check build complete (`ci/local-build.sh --build-only`, 4m52s, archive succeeded). **Deploy + soak verification OPEN** — patches 02/09 uncommitted on `dev` pending build+deploy+verify-live (lifecycle).

This build was implemented across **two sessions**; this log combines both.

---

## What shipped

217 converts the build-216 instrumentation into targeted capture fixes, **each gated on a specific 216 soak signal** (Gate-0), plus a display/diagnostics batch. One co-shipped bundle (user decision): Tasks 1–4 + D-7 + D-8 + V-2b. Task 5 explicitly excluded (changes reconnect ownership; last, alone, behind a flag).

| Area | Item | Gate-0 verdict that unlocked it |
|---|---|---|
| Fork (capture) | **Task 1** — background-gated GATT timeout 2 s→6 s | G1: 58% of `command_timeout` fire on a `.connected` peripheral (starved-CPU, not dead-link) |
| Fork (capture) | **Task 2** — connect-wedge escalation (stop the blind 60 s re-cancel loop) | G2: `connect_timeout` age>200 s tail persists at 17% post-W-7 |
| Fork (capture) | **Task 3** — gap-conditional background backfill subscribe | G5: modest upside; LOW priority, **premise unverified — the pass/fail IS the test** |
| Fork (recovery) | **Task 4** — CoreBluetooth central re-init on sustained hard Dexcom-side stall | G2/G4: W-7 recovers *visibility*, not *readings* — episodes still re-wedge |
| App (display) | **D-7** — diagnostics view revamp + rename + Task-4 kill-switch toggles | — (display-layer, EGV-path-disjoint) |
| App (display) | **D-8** — edge-perimeter cycle ring + on-watch tuning panel | — |
| App (display) | **V-2b** — accessoryRectangular 2 h sparkline | — |

**Task 7 (multi-identity discovery)** resolved with no code in the 216 soak — the sensor has ONE stable identity (`F42CA099`); other discovered UUIDs are foreign Dexcom devices. This let Task 4 drop any identity-refresh/scan phase (plain teardown+rebuild is correct).

**Attribution discipline (co-ship accepted):** Tasks 2+4 share the connect/recovery machinery. Per-episode attribution survives via Task-D markers (`connect_wedge_persistent`→`did_connect` = Task 2; `central_reinit reason=self_reset` = Task 4). Independent watch-local kill-switches (`@AppStorage`, default on, in the diagnostics view) allow mid-soak isolation of Task-2 vs Task-4 without a rebuild.

---

## Commits

| Repo | SHA | Content | Session / review |
|---|---|---|---|
| G7SensorKit (`main`) | `b8b7835` | **Task 2+4** — wedge escalation + `reinitCentral` + 2 kill-switches + restore-id observability + fall-through fix + once-per-wedge debounce | Session A — cursor + ollama×2 + Opus |
| G7SensorKit (`main`) | `6626387` | **Task 4** `G7Sensor.requestCentralReinit` passthrough | Session A |
| G7SensorKit (`main`) | `e838501` | **Task 1** — GATT discovery timeout 2 s→6 s (backgrounded only) | Session A |
| G7SensorKit (`main`) | `d4f8301` | **Task 3** — gap-conditional background backfill subscribe | Session B — cursor + ollama + static |
| Trio (`feature/watch-g7`) | `a9170af9c` | **Task 4** adapter trigger (`evaluateDirectBleStall` → `requestCentralReinit`, once per hard Dexcom-side episode) | Session A |
| Trio (`feature/watch-g7`) | `2a1b704b0` | **D-7** — diagnostics revamp + `ComplicationDebugView`→`WatchDiagnosticsView` rename + Task-4 kill-switch toggles + adapter fault exposure | Session B — 4 cursor passes + Sonnet review |
| Trio (`feature/watch-g7`) | `cae0ec386` | **D-8** — edge-perimeter cycle ring + on-watch tuning panel | Session B — cursor + static |
| Trio (`feature/watch-g7`) | `0e3ccbaea` | **V-2b** — accessoryRectangular 2 h sparkline (5 files) | Session B — 5 cursor passes + Sonnet review (caught a real bug) |

Fork build order: all four fork edits committed, then a **single batched `repin-g7.sh`** pushed the three unpushed commits and re-pinned patch 02 `b8b7835`→`d4f8301`. Patch 09 regenerated **once** at the end.

---

## Session A — fork capture/recovery core (Tasks 2, 4, 1) + Task-4 adapter trigger

**Design collapse (Task 2 ≡ Task 4).** The plan's "Task 2 alone, then Task 4" split was found unimplementable: a peripheral wedged in `.connecting` whose `cancelPeripheralConnection` yields **no callback** cannot be cleared at the peripheral level (retrieve/rescan return the same cached in-flight object → skipped as in-flight). The only recovery is a `CBCentralManager` re-init. So Task-2 escalation *is* Task-4's re-init; they merged into one fork unit (`b8b7835`). Design captured in `task2-4-fork-spec.md`.

**Mechanism (`b8b7835`):**
- **Task 2** — `scheduleConnectTimeout` counts consecutive `.connecting` ticks on the same `connectIssuedAt` (`connectWedgeTicks` in `BindingBLEState`). Tick 1 = today's cancel+reschedule. Tick ≥2 with `isConnectWedgeEscalationEnabled` → emit `connect_wedge_persistent` (once per wedge) and **escalate** instead of blind re-cancel.
- **Task 4** — `reinitCentral()` recreates the `CBCentralManager` with the **same** restore identifier; 120 s anti-loop guard (`lastCentralReinitAt`); `requestCentralReinit()` public entry for the adapter's C-210-8 episode classifier. Two host kill-switches: `isConnectWedgeEscalationEnabled`, `isCentralReinitEnabled` (both default ON in `G7BackgroundHints`).
- **Restore-id observability** — `since_reinit_s` + `restored_ids` on `will_restore_state`, plus a `central_powered_on` marker, to detect in-process restore replay / wedge re-inheritance during soak.
- **Scope:** bound-path only; discovery-watchdog escalation deferred and documented (most discovery connects are to foreign Dexcom devices — firing a re-init on a stranger's sensor is the wrong trade).

**Review — two DISTINCT fixes (do not conflate; different reviewers, different fixes).**
- **The fall-through REAL BUG — caught by the Opus review** of cursor's first pass, *before* the automated review round. cursor's initial `.connecting` case called `escalateWedgedConnect` then **unconditionally `return`ed**. But `reinitCentral` no-ops when `isCentralReinitEnabled` is off **or** within the 120 s guard, so a suppressed escalation killed the watchdog chain with **no recovery at all** — silently regressing C-212-1 and, worse, breaking the intended Task-4-off soak-isolation mode. **Fix:** `reinitCentral` returns `Bool` (false when disabled/guarded), `escalateWedgedConnect` propagates it, and the `.connecting` case **falls through to the legacy cancel+reschedule when reinit did not happen**. (NOT a tick-cap.)
- **The once-per-wedge debounce — from ollama's review-round #1.** ollama flagged `connect_wedge_persistent` re-emitting every 60 s during a suppressed-reinit window (log spam, relevant only during a Task-4-off soak). Its framing ("wasted teardown cycles") was wrong — `reinitCentral` early-returns, no teardown — and its proposed fix (cap `connectWedgeTicks` to 2) was **broken** (re-increments next tick). Rescoped into a `wedgePersistentEmitted` flag: **emit once per wedge, escalation still attempted every tick** so it fires the moment the 120 s guard clears. ollama's other findings were rejected (out-of-scope pre-existing code / serial-queue-safe) and logged as false-positives. Both fixes ride in `b8b7835`.

**Restore-id risk — primary fear VERIFIED benign; a secondary CB concern accepted with mitigations.** The primary worry: recreating the central with the **same** restore identifier could replay `willRestoreState` **in-process** and re-inherit the wedged `.connecting` peripheral, defeating the re-init. **Verified against Apple's docs** (`CBCentralManagerDelegate.willRestoreState`) + community sources: `willRestoreState` is a **launch-time** callback — delivered when the system *relaunches* the app for a BLE event (tied to `didFinishLaunchingWithOptions`), **not** replayed when a new `CBCentralManager` is created in a running process. So the fresh central starts clean and does not re-adopt the wedge. Keeping the identifier is also *required* (dropping it forfeits background-wake state restoration). The observability (`since_reinit_s`/`restored_ids`/`central_powered_on`) exists to catch it in soak if this understanding is ever wrong. **Secondary concern (accepted with mitigations):** the swap clears `delegate=nil` on the old central before instantiating the new one; CoreBluetooth may drop a near-synchronous `didDisconnectPeripheral` and leave a `.connecting` slot locked until an OS timeout — structurally plausible, version-dependent, not provable without soak. Accepted because (a) the 120 s guard bounds re-init frequency; (b) the restore-id observability makes any slot re-inheritance visible; (c) the fork-spec fallback (no central recreate) is weaker and doesn't clear a truly stuck `.connecting`. A telemetry-timestamp-race UNCERTAIN (ollama) was refuted — the serial `managerQueue` guarantees `lastCentralReinitAt` is set before any callback reads it.

**Task 1 (`e838501`).** `applyConfiguration`'s discovery/CCCD timeout gated on `G7BackgroundHints.isHostBackgrounded` (6 s backgrounded, 2 s otherwise). Gate = *backgrounded*, not session-state (G1's starved-CPU timeouts span both session states but are all non-foreground). One constant, watch/background-only; iPhone + foreground watch unchanged.

**Task-4 adapter trigger (`a9170af9c`).** `evaluateDirectBleStall()` calls `sensor.requestCentralReinit(reason: "dexcom_side_episode")` on the same sustained-hard-Dexcom-side condition that gates the restart-Dexcom notification — once per episode (`centralReinitThisEpisode` latch, reset in `clearDirectBleStallIfNeeded`). Covers the `connect_called=0` deep-gap class Task-2 escalation cannot reach; bounded by the fork kill-switch + 120 s guard.

Session A left the repin and patch-09 regen **batched** to Session B (per operating decision — one repin after all fork edits, one patch-09 at the very end).

---

## Session B — Task 3, patch integration, display batch (D-7/D-8/V-2b), build

### Task 3 — gap-conditional background backfill (`d4f8301`, fork)
`handleGlucoseMessage` now computes the sequence gap vs the current binding's last EGV. When backgrounded, C-209-11 normally skips the backfill subscribe; Task 3 **allows it only when `sequence` jumps > 1** (a real gap to fill via the sensor's push-based backfill — passive-contract-clean, subscribe only, no writes). Capped ≤ 1/10 min; the extended-version request stays background-skipped.

**Placement decision:** `lastSequence` is `G7Sensor`-local (`Locked<UInt16?>`, C-208-13 pattern) — `BindingBLEState` is private to `G7BluetoothManager`, while the handler lives in `G7Sensor`. Resets to `nil` in `scanForNewSensor` so a fresh binding never false-fires; persists across same-sensor reconnects/`.makeActive` (a gap there is a *real* gap). Gap computed in `Int` to avoid `UInt16` overflow. Emits `background_backfill_gap` + adds `sequence_gap` to `background_gatt_skipped`.

**Review:** cursor implement → static review (all four execution paths verified) → ollama review (findings were whole-file noise on untouched production code — `backfillBuffer`/`stopScanning`/`activationDate`, none in the Task-3 diff; logged as false-positive). **Honest label:** improves history completeness, not real-time freshness; the premise (background backfill delivers to a passive observer) is unverified — the soak `backfill_entry` rate IS the test; revert if ~0.

### Batched `repin-g7.sh`
Pushed the three unpushed fork commits, re-pinned patch 02 `b8b7835`→`d4f8301` (base gitlink `0c87905` unchanged — no upstream bump), `patch-test.sh` PASSED. Patch 02 re-pinned but NOT committed.

### D-7 — diagnostics view revamp + rename (`2a1b704b0`)
Four cursor passes, each integrity-checked:
- **(A) Rename** `ComplicationDebugView` → `WatchDiagnosticsView` (git mv + whole-word ident rename across 4 files: view, `TrioMainWatchView` call site, `TrioComplicationDataStore`/adapter comments). It's a watch diagnostics dashboard now, not a complication debugger.
- **(B) Adapter** — expose `lastDirectBleStallFault` (set in `evaluateDirectBleStall`, cleared on recovery) for the Stall row; `applyKillSwitchesFromDefaults()` (called once/process from `start()`, registers ON defaults, re-applies persisted kill-switch state into the fork's in-memory `G7BackgroundHints` flags — which reset ON every process — so a persisted OFF survives relaunch); `logKillSwitchToggled` emits the marker.
- **(C) View revamp** — standalone glucose headline at top; section reorder (headline → G7 → LOGS → DATA STORE → ESCALATION → ACTIONS); G7 row reorder; remove Session ID + Last status event; merge Connects/EGVs/Windows → "Today:", Phone/Expected/Bound → "Sensor:" (divergence-coloured); drop mg/dL; Stall+fault; layout stability (`lineLimit(1)`+`minimumScaleFactor`); actions reorder; remove the D-6 inline `CountdownRingView` (keep `g7CountdownFraction`/`g7CountdownRingColor` — D-8 reuses them).
- **(C2) Kill-switch toggles** — two `@AppStorage` toggles wired to the fork flags + the marker.

**Sonnet review clean.** Its one "Critical" (submodule won't compile) was a build-model misread — the build fetches the GitHub fork at the patch-02 SHA (`d4f8301`, already repinned); the local Trio-worktree submodule checkout is IDE-cosmetic. Later refuted outright by the green build.

### D-8 — edge-perimeter cycle ring + tuning panel (`cae0ec386`)
Option B (thin full-360° screen-edge ring), reviving the April intent without its documented killers. A custom `EdgeRingShape` traces the rounded-rect perimeter **from top-center clockwise**, so a plain `.trim(from:0,to:fraction)` fills clockwise from 12 o'clock — **no `.rotationEffect`** (the axis-swap that broke every prior variant) and **no `.animation`** (the resume-sweep glitch). Stepped from the view's existing 1 Hz `now` tick; faint white track under the coloured progress arc; in-view `.overlay(...).ignoresSafeArea()` + `allowsHitTesting(false)`. Fraction reuses `g7CountdownFraction` over the 5-min CGM cycle. On-watch **live tuning panel** (RING TUNING): five `@AppStorage` knobs (corner radius / line width / inset X/Y / track opacity) read live — geometry dialed in on-wrist instead of build-per-guess (the loop that consumed the 8 April iterations). Static-verified: no rotation/animation on the ring, braces balanced.

### V-2b — accessoryRectangular 2 h sparkline (`0e3ccbaea`, 5 files)
Completes the deferred V-2 sparkline. **Data plumbing** (the reason it was deferred — `WatchGlucoseHistoryStore` is extension-local; the widget process can't read it): `TrioComplicationSnapshot` gains an optional `recentReadings: [[Int]]?` ([epoch, mgdl], last ~2 h, ≤24 pts) — optional for clean Codable evolution, excluded from `ComplicationSnapshotFingerprint` so the rolling window never forces extra reloads; `WatchGlucoseHistoryStore.recentReadingsCompact()`; an `ExtensionDelegate`-set provider closure enriches the snapshot in `saveOnMain` (the snapshot is the app-group bridge). **Rendering:** a lightweight `Path` polyline beneath the text line (no Charts — widget memory budget); fixed 2 h X-window; Y padded ±20 mg/dL clamped to ≥40 span; gaps >15 min render as line breaks (a gap IS information); recency-dimmed; text-only fallback for nil/<2 pts. Codable evolution unit-tested both directions.

**Sonnet review caught a REAL BUG (fixed before commit).** `getTimeline`'s `makeEntry` built every live timeline entry from the memberwise init and **dropped `recentReadings`** — so the sparkline would have appeared only in the widget gallery preview (`getSnapshot`), never on the live face. Fixed by threading `recentReadings: timelineBase.recentReadings` through `makeEntry`; the stale "no sparkline yet" comment was refreshed.

### Batched patch-09 regen
One `mid-stack-update.sh --patch 09 --cherry-pick 5041e8ab5,bb6be20b7,a9170af9c,2a1b704b0,cae0ec386,0e3ccbaea`. **Note the 6-commit list.** The committed patch 09 on `dev` predated the widened-net work (`5041e8ab5`/`bb6be20b7`, folded into the *uncommitted* working-tree patch 09), which the mid-stack script auto-restores away before regenerating. D-7's rename builds on that content, so the initial 4-commit cherry-pick **conflicted on the rename**; `--from-feature-branch` was correctly **refused** (history aligned, not diverged — it would sweep unrelated tree state); the script computed the correct 6-commit list (the "missing intermediate commits" cause from AGENTS.md). Result: rename clean (`WatchDiagnosticsView.swift` in, `ComplicationDebugView.swift` fully gone), **29 files, `patch-test` + patch-audit PASSED** (36 known watch-patch warnings, pump-migration sentinel intact), drift check CLEAN.

### Compile-check build
`ci/local-build.sh --base-branch dev --build-only --include-untracked` → **✅ archive succeeded, 4m52s.** All patches applied (patch 02 @ `d4f8301`, regenerated patch 09). Validates: the fork Tasks 2/4/1/3 compile, the rename resolves (`--extra-files` path), the view revamp + kill-switches + edge ring compile, and the cross-target V-2b snapshot field / provider / entry threading + unit test compile. **Non-fatal:** the automatic `upstream/dev` merge failed (build proceeded on current `dev` — expected for a compile check; upstream has diverged and should be reconciled before the next real build). CoreSimulator "out of date" warnings are benign (device support disabled; archive unaffected).

---

## Verification discipline / notable catches

- **Human + adversarial review each earned their keep.** Session A's **Opus review** caught the fall-through REAL BUG (a suppressed re-init abandoning recovery via an unconditional `return`) *before* the automated round; the round's **ollama** pass then caught the separate `connect_wedge_persistent` re-emit spam (→ the once-per-wedge debounce, after correcting ollama's broken proposed fix). Session B's **Sonnet** pass caught the V-2b `makeEntry` `recentReadings` drop (fixed before commit). All were behavioural issues static review alone would have missed.
- **Build-model false alarm handled correctly.** Two reviews independently flagged "submodule won't compile" from the stale Trio-worktree submodule checkout; both were build-model misreads (the build clones the fork at the patch-02 SHA) and were refuted by the green build. No wasted action.
- **Every cursor run integrity-checked** (`git diff --stat` + grep new symbols + scope + brace balance) — cursor is capable of a silent no-op / scope creep; none occurred here.
- **Patch lifecycle held.** Patches 02 + 09 remain **uncommitted** on `dev`; the milestone commit waits for build+deploy+verify-live. No AI attribution in any commit (incl. the fork).

---

## Post-deploy soak signals (build 217)

Query `build='217'`, `platform='watchos'`. Lead go/no-go on drop-robust aggregate deltas (per-episode joins go silent during the exact deep-gap states we measure). Baselines: 216 soak (44 h, n=1, DXCMyu) in `build217-impl-plan.md` Gate-0.

| Task | Primary pass/fail (directional, n=1, ≥3-day) | Corroborating markers |
|---|---|---|
| **Task 1** | `command_timeout op=discover_services\|set_notify_authentication` per 100 connects ↓ ≥50%; `gatt_ready→auth_notify_subscribed` 84%→≥92%; no `did_connect`/`egv_received` regression | — |
| **Task 2** | `connect_timeout` age>200 s share 17%→<5%; `phantom_disconnect` share <40%; `did_connect`/`connect_called` >40% | `connect_wedge_persistent`→`did_connect` on same binding within 10 min (guards the stopped-cancelling false pass) |
| **Task 4** | ≥1 classified episode recovers with `central_reinit reason=self_reset` and **no** `will_restore_state` within ±10 min; manual-restart recoveries per episode ↓ | Negative guardrails: `central_reinit` ≤1/episode (alert >2); no rise in `connect_called`/hr or `phantom_disconnect` share vs Task-2-alone |
| **Task 3** | `backfill_entry` > 0 on ≥25% of gap-following bg connections; distinct-seq daily coverage +5 pp; no `pre_egv_disconnect` increase on those connects | `background_backfill_gap` markers (join to `backfill_entry`); revert if ~0 |
| **Kill-switches** | `kill_switch_toggled` markers timestamp any mid-soak Task-2-vs-Task-4 isolation | Restore-id: `since_reinit_s`, `restored_ids`, `central_powered_on` — watch for wedge re-inheritance after a swap |

**On-wrist (no BetterStack):** the revamped diagnostics view now surfaces BLE link/wedge state, RSSI, Stall+fault, "Was restored", merged Today/Sensor rows, the ESCALATION kill-switch toggles, and the edge cycle ring; the rectangular complication shows the 2 h sparkline.

**Deferred:** Task 5 (`CBConnectPeripheralOptionEnableAutoReconnect`, last/alone/flagged); discovery-watchdog escalation (revisit if `discovery_connect_timeout` recurs with no `connect_wedge_persistent` on real EGV loss); D-8 ring geometry finalization (dial in on-wrist, then hardcode defaults).

---

## Next steps (user-gated)

1. **Deploy** — full `ci/local-build.sh` (no `--build-only`) → build + TestFlight upload (+ resolve the `upstream/dev` merge first if desired).
2. **Milestone patch commit** — commit patches 02 + 09 + docs to `dev`, only after deploy + BetterStack verify-live.
