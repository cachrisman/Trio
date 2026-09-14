> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 205 — Implementation plan: Watch UX, persistence, data architecture, and G7 capture reliability

**Version:** 1.16
**Status:** Draft
**Created:** 2026-06-01 CET
**Last updated:** 2026-06-06 CET

**Sibling docs:** [build204 impl log](watch-g7-direct-ble-observer-build204-impl-log.md), [build195 design](watch-g7-direct-ble-observer-build195-design.md)

---

## Changelog

- **v1.16 (2026-06-06)** — Closed the two open W5/W7 TODOs (source-verified + authoritative runtime capture):
  - **W5 static-color hex (was placeholder `#______`) — RESOLVED by capture, not reasoning.** Verified the exact path (static branch returns SwiftUI `Color.orange/.red/.green`, `DynamicGlucoseColor.swift:23–29`, through `toHexString()` which truncates `Int(x*255)`, `GlucoseColorScheme.swift:32`), then ran the real UIKit path on the iOS 26.5 simulator (`simctl spawn` a tiny tool replicating `toHexString()`). Final light-mode constants: `staticLowHex=#FF383C` (red 255,56,60), `staticInRangeHex=#34C759` (green 52,199,89), `staticHighHex=#FF8D28` (orange 255,141,40). Killed the false leads: SwiftUI colors are OS-version-dependent, **not** pure RGB, **not** `UIColor.system*` (`#FF3B30`/`#FF9500`), and **not** the stale web `#E84D3D` (old-iOS red). Dynamic golden hexes also captured (55→`#E55B5B` … 220→`#A05BE5`). **Correctness fix:** the watch's `hexFromHSB` must **truncate** (`Int(x*255)`), not `.rounded()` — corrected in design + validation. **Verified detail:** dynamic branch is `Color(hue:, saturation: 0.6, brightness: 0.9)` (`:64`). Residual (dark-mode / future-iOS drift) is covered by a temp in-205 `color_parity` confirmation log, removed in 206.
  - **W7 `bleFirstSequenceToday` consumer (was "verify")** — surveyed all sites: its only value-reader is the old `countWithDenominator` (`ComplicationDebugView.swift:649`, reads it + `bleLastEGVSequence`), which W7 replaces. The `handleSensorDidRead:803–810` check is write-only maintenance (no new-sensor detection / branch / telemetry). **Confirmed dead-after-W7;** kept in 205, removal flagged as a post-205 cleanup chip (with `bleLastEGVSequence`).
  - **Pre-execution review pass** — re-verified all 15 load-bearing source line claims against the worktree (all accurate; only trivial drift `lastWatchStateUpdate` is `:2038` not `:2035`). Tightened three under-specified spots that could cause bugs at implementation time: (1) **`pendingSensorSwap` lifecycle** — must be cleared right after the inline swap teardown (set-once-never-cleared would misclassify later routine rebinds as swaps); also pinned the C1 deferred-`boundSensorName`-clear execution point to `performScanForNewSensor`. (2) **C3 retry cap** — the `scheduleConfigurationRetry` sample omits the attempt counter/`nextBackoff()`; spelled out the counter + **reset-on-config-success** (else a later failure inherits an exhausted budget). (3) **Hex case** — `toHexString` is `%02X` uppercase, so `hexFromHSB` must format uppercase (or compare case-insensitively) or the parity test false-fails. Also verified the three pre-build prerequisites against the worktree: the `init()` fix is committed (`7560fa1a8`); the patch-12 Info.plist hunk (`WKBackgroundModes`/`physical-therapy` + `UIBackgroundModes`/`bluetooth-central`) is intact in both the committed patch and the feature-branch tree; build204 log is uncommitted (non-gating). **Decision:** regenerate patch 12 via **`--from-feature-branch`** (captures the `init()` fix + all W/C commits, avoiding the subset-cherry-pick hazard) with `--extra-files` for the two new watch files.
- **v1.15 (2026-06-03)** — Cursor red-team pass on v1.14 (4 must-fix + 4 stale-text; all accepted):
  - **Display-unit plumbing (High — silent mmol/L regression)** — after P2 stores canonical mg/dL, the watch must convert at render. `units` is **already on the wire** (`AppleWatchManager:612`); the watch now reads + caches it (`WatchGlucoseColorComputer.cachedUnits`) and `loadAsDisplayValues(units:)` converts mg/dL → display (`asMmolL`/raw), matching the phone-sent display-unit y-axis. Color math stays in mg/dL.
  - **`GlucoseTrendView` `Int?` rule (Medium)** — explicit `guard let mgDl … else .secondary`; never call the computer with a sentinel; missing ⇒ neutral, not red (live render + snapshot bake).
  - **C2 adapter state & API (Medium)** — specified: bound identity on the adapter (`sensorName` + new persisted `Int64 activationEpochSeconds`), in-memory `quarantine: SensorIdentity?`, `setActiveSensorIdentity(_:)` replacing `setActiveSensorName`, and `performEndOfSessionTeardown` records the identity into quarantine **before** nilling `expectedSensorName`.
  - **W1 HK write-site anchor (Low)** — pinned insert + snapshot bake to the `finishHKGlucoseObserverFetch` main block (~`:787–790`), same pass as `applyHKSnapshot`.
  - **Stale text** — Risks W5 line, Fixes-table W5/W7 rows updated to `glucoseHueComponents`/refactor-in-place and the gated **set**; W2 decode unified to a failable `StoredGlucoseReading(from:source:)` (= the P2 decode, one path); trimmed the obsolete `Color.resolve` bullets to the single hex-first story.
- **v1.14 (2026-06-03)** — ChatGPT red-team pass (10 + validation): C3 first-wins retry; W7 gated-as-set + remove-on-capture; C1 gate rollover; `currentGlucoseMgDl` optional; C2 Int64 epoch; W1 `@MainActor` + `suffix(288)`; W5 Foundation-only helper; dynamic-hex parity; scan-kind preservation (`:724` verified `.newSensor`); greps + future-skew guard.
- **v1.13 (2026-06-03)** — ChatGPT pass: `currentGlucoseMgDl` Int; `glucoseHueComponents` extraction; grep precision; W13 `lastEGVEpoch` preserved; C3 single-in-flight phrasing.
- **v1.12 (2026-06-02)** — ChatGPT pass (architecture endorsed; 9 fixes): C1 gated identity-eligibility; C3 cancellation refined; clear-before-reissue; real runtime logging; W5 hex-first + Int mg/dL; `[weak self]`; W7/W13 upgrade vs restart; grep checklist.
- **v1.9 (2026-06-02)** — `sync_project_files_config.rb` is a **direct `dev` commit** (build infra), sequenced before the build.
- **v1.8 (2026-06-02)** — Third Codex pass (consistency cleanups after its in-worktree verification of all six requested files):
  - **W5 inconsistency removed** — Fixes table + patch mapping no longer say "shared `DynamicGlucoseColor.swift`" (which would pull `GlucoseColorScheme`/UIKit into watch). Named the extracted file **`GlucoseHueColor.swift`**, specified **move-not-copy** (single impl), and clarified the `sync_project_files_config.rb` edit rides the patch diff.
  - **C2 constant placement** — `WatchMessageKeys.g7ActivationEpoch` constant is added in **patch 09** (not 13); patch 13 only adds the *send*. Aligns the C2 bullet with sequencing constraint #6.
  - **C3 stale wording removed** — dropped the "`emitG7Telemetry` signature change" line; the 2-arg helper already exists, so nothing telemetry-side ships.
  - **W3 timestamp reworded** — precise: `lastWatchStateUpdate` = `WatchMessageKeys.date` = phone **WatchState build time** (verified assigned at `WatchState.swift:2035`), not CGM reading or watch receipt time.
  - **W7 risk note** — corrected to the forward-only real-time rollover (was still describing tick-epoch attribution).
  - **W5 snapshot baking** — named the HK + direct-BLE snapshot builders (both currently write `nil` glucoseColor per Codex) as the sites that must bake the bubble hex; `TrioComplicationSnapshot.glucoseColor` confirmed present (`TrioComplicationDataStore.swift:49`).
  - Verifications closed: watch `WatchState.swift`, `G7PeripheralManager.swift` (C3 real), `TrioMainWatchView.swift` (W4 refs accurate), `TrioComplicationSnapshot`, `sync_project_files_config.rb`, patch 09/13 ownership — all confirmed.
- **v1.7 (2026-06-02)** — Verified against uploaded source: C3 needs no telemetry-helper change (`emitG7Telemetry(_:_:)` already builds a payload); phone `WatchState` `.color` in `==`/`hash` confirmed and pinned.
- **v1.6 (2026-06-02)** — Second Codex pass (six findings accepted, two were compile blockers):
  - **P2 / phone `WatchState` `==`/`hash`** — removing `WatchGlucoseObject.color` breaks the custom `Equatable`/`Hashable` referencing `value.color` (`WatchState.swift:37/:63`). Added `Trio/Sources/Models/WatchState.swift` to P2's patch-09 scope.
  - **W5 sharing not viable → extraction is primary** — `DynamicGlucoseColor.swift` references `GlucoseColorScheme` (UIKit-importing, not watch-safe) and isn't in the watch sync config. Now: extract only the pure `calculateHueBasedGlucoseColor` into a watch-safe shared file; watch does the static branch locally and never references `GlucoseColorScheme`/`getDynamicGlucoseColor`; add a watch-safe `Color → hex` (or direct-from-HSB) for snapshot baking (watch had only hex → `Color`).
  - **C3 telemetry is payload-based** — `G7Telemetry.emit` takes a `G7TelemetryPayload` (patch12:38, `.event`/`.fields`), not a `String`. `emitG7Telemetry` must build a payload; the v1.4/v1.5 string-formatting form was based on a **stale `/mnt/project` mirror** and is corrected here.
  - **W7 rollover forward-only** — replaced the replay-epoch day comparison (which could flip `calendarDay` backward and zero today) with a real-time `advanceDayIfNeeded()` plus a today-only increment guard (`slotEpoch >= startOfToday`); pre-midnight replays are skipped, not counted.
  - **C1/C2 `boundSensorName` reconciled** — accepted swap (C2) tears down binding immediately + defers only the scan (via `pendingSensorSwap`); routine gated rebind (C1) defers the clear. No longer two contradictory instructions.
  - **W6 wording fixed** — `bleFirstSequenceToday` is pre-existing (not W6's); only the denominator *computation* is removed. Field kept (C2 reset + W13 migrate); flagged to verify its remaining consumer for a possible later cleanup.
- **v1.5 (2026-06-02)** — ChatGPT review pass. W1 dedup → "either sequence nil"; C1 `isStarted` contradiction resolved (latch + explicit consumers); W7 counters slot-keyed; C2 missing-epoch fallback + upgrade promotion; **W6 dropped (obsolete)**; C3 retry contract; W5 target-safety guard; W3 timestamp guard; units canary softened; validation rewritten (display-state, 2h-recovery); one build held + `build205_*` labels.
- **v1.4 (2026-06-02)** — Review pass (Codex + Claude). Blockers: B1 lifecycle/cherry-pick; B2 canonical mg/dL + `currentGlucoseMgDl`; B3 C1 unified gated primitive; B4 two-rule color + shared color math; B5 `WatchGlucoseObject` model change; B6 `nonZeroOr` removed. D1 settings in `UserDefaults.standard` + snapshot baking; D2 `gatedSlotsToday`; D3 30-min IOB/COB cap; D4 key migration. One build; rename deferred; C3 `emitG7Telemetry` 2-arg; widget color source confirmed.
- v1.3 (2026-06-01) — Source-verification fixes from a full review pass (M1 patch-09 fetch ownership; L1 `WatchGlucoseColorComputer` typo; L2 color-scheme key name; L3 `Keys.lastEGVSequence`; L4 W4 line refs; L5 `loadGlucoseHistoryOnStartup` wrapper; L6 startup-validation window).
- v1.2 (2026-06-01) — Folded in the G7 BLE EGV-pipeline audit: capture-pipeline problem group, bucket table, C1/C2/C3, patch mapping, capture validation, risks. Widest-reach: 205 regenerates patches 02/09/12/13 + a fork commit.
- v1.1 (2026-06-01) — Completeness pass: Pre-build prerequisites, Delivery / patch mapping, Deferred `g7_session=nil` section, P2 correction, carried-over bug-audit items W9–W12.
- v1.0 (2026-06-01) — Initial plan.

---

## Problem

Build 204 stabilised the G7 direct-BLE path (session management, sensor seeding, connect storm). Build 205 addresses the second-order class of issues surfaced by the post-204 audit and code review:

1. **Startup blank screen.** Opening the watch app shows `--` for current glucose, IOB, COB until the WC transfer completes — even though cached data exists on device.
2. **Chart always empty on startup.** `glucoseValues` is in-memory only; the chart is blank until the phone delivers a payload.
3. **Session-unreachability incorrectly hides data.** `isSessionUnreachable` gates the IOB/COB *display*, not just the action buttons. Phone-reachability is irrelevant to displaying data that arrived via BLE or HealthKit.
4. **WC payload carries 24 hours of glucose history on every update.** `fetchLimit: 288` (~14 KB per transfer) when only a handful of new readings exist since the last delivery.
5. **Per-reading color strings in WC payload, and values sent in display units.** Each glucose reading carries a hex-encoded `color` string (~10 bytes × 288 ≈ 2.9 KB), and chart values are sent in *display* units (mmol/L when selected). The watch can compute colors locally (matching the phone's exact rules), and the payload should carry canonical **mg/dL**.
6. **Denominator for Connects:/EGVs: debug rows is wrong on sensor-swap days.** The current sequence-arithmetic denominator silently resets when a new sensor starts mid-day; slots from the previous sensor are lost.
7. **Denominator lost on process restart.** The sequence-arithmetic denominator fails after restart until the first new EGV arrives. (Addressed by W7's persisted slot counter, not by persisting a last-sequence — see W6 removal.)
8. **Debug view missing high-value diagnostic rows.** `g7DirectBleLastEventAt` and `adapterSessionID` exist in code but are not displayed.

### Capture-pipeline issues (G7 BLE EGV pipeline audit)

Folded in from a separate G7 BLE EGV-pipeline audit (n=1: ~15 h / full overnight / two battery cycles). **Core fact:** the watch saves 100% of the EGVs its radio actually receives (adapter drop = 0% over 180 windows). The gap is entirely *before* delivery — steady-state capture is ~49% of emitted windows (~54% excluding one battery outage). The fixable missed-window buckets:

| Bucket | n | Cause | Fix |
|---|---|---|---|
| Background-no-runtime | 23 | BLE connects in background with no confirmed runtime session → `ext_session_did_invalidate reason=-1` → `pre_egv_disconnect` | C1 |
| Config churn | 14 | `configureAndRun` continues after config failure; runs against missing characteristics → no EGV | C3 |
| EOS / stale-binding | 8 | Stale sensor identity revived by phone after EOS → reconnect storm | C2 |
| Alive, no successful connect | 24 | Connect already armed/pending; G7 didn't service the window | ⚠️ Mostly not addressable — **do not** add a reconnect watchdog (see What does NOT change) |
| Battery off | 18 | Exogenous (watch died) | ❌ Not addressable |
| Transient app-silence | 8 | watchOS suspended the extension for single windows | ⚠️ Maybe; not targeted this build |

**Caveat (carried from the audit):** all data from one device. Relative bucket sizes are the durable signal; absolute rates are directional and need replication across devices/sensor sessions. The capture fixes are validated by *bucket reduction*, not an absolute capture-% target.

---

## BetterStack evidence

**±1s dedup window.** Queried watchOS save events (`platform=watchos`, `saveOnMain entered`) over the new-sensor window of 2026-05-31 16:30–19:00 UTC. Observed 8 confirmed BLE + WC same-reading pairs, delta always exactly 1 second (BLE derives `readingDate` from integer arithmetic on the sensor's `glucoseTimestamp`; WC uses the phone's CoreData date which rounds +1s). The current `> 1.0` threshold is **correct**: `timeDiff = 1.0` falls through to the sequence-equality check, which keeps the BLE version (priority 3) over the arriving WC version (priority 2). **No change to the ±1s window.** The history store reuses the same `shouldUpdate` logic.

One TOCTOU double-write was observed at 21:00 UTC. Harmless for the single snapshot; the history-store merge path must handle it gracefully (idempotent insert by `(readingDate ± 1s, sequence)`).

---

## Pre-build prerequisites

Build 205 source edits happen on the feature branch in the `Trio` worktree and land via `mid-stack-update.sh` cherry-picks. Per `AGENTS.md:32, :93, :98`, **patch files stay uncommitted on `dev` until you explicitly ask** — nothing here commits to `dev` as a prerequisite. There are two in-flight build-204 items to reconcile:

1. **Patch-12 `init()` compile fix — captured via `--from-feature-branch` (verified 2026-06-06).** The committed build 204 (`7216483d2`) seeded identity with `sensor = G7Sensor(sensorID: expectedSensorName)`; that getter touches `self` and is illegal before `super.init()`. The fix reads UserDefaults directly:
   ```swift
   sensor = G7Sensor(sensorID: UserDefaults.standard.string(forKey: Keys.sensorName))
   ```
   **Verified:** the fix is committed on `feature/watch-g7-direct-ble-observer-synthesis` as **`7560fa1a8`** ("fix build — read sensorName UserDefaults directly before super.init"); its buggy predecessor is `931660cc8` (working tree confirmed correct at `G7WatchSensorAdapter.swift:181`). `mid-stack-update.sh` v1.7 **auto-restores the committed version of a dirty target patch** (`AGENTS.md:98`), so a hand-edit of `patches/12` would be silently reverted on regen. **Action (chosen):** regenerate patch 12 with **`--from-feature-branch`** (not `--cherry-pick`) — it rebuilds the patch from the feature-branch tree, capturing **all** committed work (`7560fa1a8` + `931660cc8` + every W/C1/C2 commit) in one shot, which structurally avoids the `AGENTS.md:286` "subset cherry-pick" hazard. **Caveat:** `--from-feature-branch` stages only files already in the committed patch's scope (+ `--extra-files`), so the **new** 205 watch files must be passed explicitly:
   ```bash
   ./scripts/mid-stack-update.sh --patch 12 --from-feature-branch \
     --extra-files "Trio Watch App Extension/WatchGlucoseHistoryStore.swift,Trio Watch App Extension/WatchGlucoseColorComputer.swift"
   ```
2. **Patch-12 regen scope includes `Trio Watch App/Info.plist` (verified — already a scope file).** Build 204's lesson — recorded in the 204 log and `AGENTS.md` — is that a patch-12 regen can silently drop the `Info.plist` hunk, taking `WKBackgroundModes` (`physical-therapy`) / `UIBackgroundModes` (`bluetooth-central`) with it, breaking the WKExtendedRuntimeSession machinery C1 depends on. **Verified 2026-06-06:** the committed `patches/12` already carries the 18-line Info.plist hunk (both keys), and the feature-branch `Trio Watch App/Info.plist` has both (`WKBackgroundModes`→`physical-therapy` at `:19–26`, `UIBackgroundModes`→`bluetooth-central` at `:28–35`). Because it is an existing scope file, `--from-feature-branch` re-captures it automatically (no `--extra-files` entry needed for it). **Action:** still **verify after regen** that `WKBackgroundModes`/`physical-therapy` survived (`grep` the regenerated patch / built plist) before shipping — the grep is in the pre-validation checklist.
3. **`build204-impl-log.md` (uncommitted doc).** Close it per the normal doc lifecycle (it's a doc, same uncommitted-until-asked rule). It does not gate 205 source work.

**Do not** add a "commit the patch to `dev` before regen" step — that both violates the lifecycle and fails to address the auto-restore mechanism (the fix survives only by being in the cherry-pick scope, not by being committed to `dev`).

---

## Fixes (this build)

| # | Area | Description | Files (watch extension unless noted) |
|---|------|-------------|--------------------------------------|
| W1 | Glucose history store | New `WatchGlucoseHistoryStore` — rolling 24h, 288 readings max, canonical mg/dL, persisted to Documents; **batch insert** for the WC path | New file: `WatchGlucoseHistoryStore.swift` |
| W2 | Chart data population | Load `WatchState.glucoseValues` from history store on startup; merge new readings from all three channels (BLE, HK, WC) into the store | `WatchState.swift`, `G7WatchSensorAdapter.swift`, `TrioMainWatchView.swift` |
| W3 | IOB/COB/lastLoopTime persistence | **Four** new UserDefaults keys; write on WC delivery; load on startup with a **30-min freshness cap** | `WatchState.swift` |
| W4 | Display gate fix | Remove `isSessionUnreachable` from glucose/IOB/COB *display*; keep it on action buttons only; show stale data dimmed instead of `--` | `TrioMainWatchView.swift` |
| W5 | Local color computation | New `WatchGlucoseColorComputer` (settings + display `units` in `UserDefaults.standard`) + new shared `GlucoseHueColor.swift` (Foundation-only `glucoseHueComponents`; phone `calculateHueBasedGlucoseColor` refactored in place to call it); two rules — `chartColor` (always colored) and `bubbleColor` (white strictly in settings range). Phone pushes the four color settings + `units` + `currentGlucoseMgDl` | New files: `WatchGlucoseColorComputer.swift`, `GlucoseHueColor.swift`; edit `DynamicGlucoseColor.swift`; `sync_project_files_config.rb` |
| W6 | *(removed — obsolete)* | Persisted `bleLastEGVSequence`; its only consumer (the sequence denominator) is replaced by W7. Dropped | — |
| W7 | `expectedSlotsToday` (monotonic) + `gatedSlotEpochsToday` (set) | Expected: high-water counter in `emitExpectedWindowTick`; gated: **slot-epoch set** inserted at C1's gate and **removed when an EGV is captured in that slot** (so a deferred-then-captured slot isn't subtracted); debug rows show `N / (expected − gated)`, never > 100% | `G7WatchSensorAdapter.swift`, `WatchState.swift`, `ComplicationDebugView.swift` |
| W8 | Debug view improvements | Add `Last BLE event:` (`g7DirectBleLastEventAt`) and `Session ID:` (`adapterSessionID`) rows above the counter rows | `ComplicationDebugView.swift` |
| W9 | `log()` unstructured task (audit, Low) | Replace per-event bare `Task { await … }` in adapter `log()` with a bounded/structured logging hop | `G7WatchSensorAdapter.swift` |
| W10 | `triggerConfirmation` coalescing (audit, Low, debug-only) | Cancel the prior `asyncAfter` clear of `showConfirmation` before scheduling a new one | `ComplicationDebugView.swift` |
| W11 | `applyG7DirectBleSnapshot` timeout hygiene (audit, Low) | After `syncTimeoutWorkItem?.cancel()` also set `= nil` | `WatchState.swift` |
| W12 | Rename `isSessionUnreachable` (audit, Low) | Rename to reflect activation+reachability after W4 narrows it to buttons | `TrioMainWatchView.swift` |
| W13 | Adapter key-naming migration | Migrate the adapter `Keys` enum to the `G7WatchAdapter.*` convention; `sensorName` read-through migration | `G7WatchSensorAdapter.swift` |
| P1 | WC payload size reduction | `fetchLimit: 288 → 24` (2 hours) + new `glucoseForTwoHoursAgo` predicate | `AppleWatchManager.swift`, `GlucoseStored+helper.swift` (phone) |
| P2 | Canonical mg/dL payload + strip colors | Chart entries become `{date, glucoseMgDl}`; add `currentGlucoseMgDl` + the four color settings; **stop populating/reading** `currentGlucoseColorString` and the per-entry `color` | `AppleWatchManager.swift`, watch decode paths (phone + watch) |
| **C1** | **Runtime gate** (capture lever #1) | Allow BLE scan/connect only when scene active **or** runtime session confirmed `.running`; otherwise defer via a single gated scan primitive and log `ble_gated`. **Gate, don't recover-harder** | `G7WatchSensorAdapter.swift` |
| **C2** | **Sensor identity epoch + EOS quarantine + adapter reset** (capture lever #2) | Identity = `name + activationEpochSeconds` (Int64); reject revived `name+epoch` after EOS; full reset on accepted swap | `G7WatchSensorAdapter.swift`, `WatchState.swift` + `AppleWatchManager.swift` (phone) |
| **C3** | **`configureAndRun` fail-closed** (capture lever #3) | On config failure, `return` instead of running the block + bounded-backoff retry; log `configure_block_skipped` | `G7PeripheralManager.swift` (G7SensorKit fork) |

---

## Detailed design per fix

### W1 — `WatchGlucoseHistoryStore`

**Serialization invariant (required).** All access is **single-threaded** — declare the store `@MainActor` (watch-local, ~288 rows, keeps call sites simple) so the read-modify-write cycle (load → merge → prune → sort → write) can't interleave across the BLE, HK, WC, and startup-load callers. Without this, two near-simultaneous inserts can both load file `{A}`, then write `{A,B}` and `{A,C}` — losing one. (An `actor` is the alternative but forces `await` at every call site; `@MainActor` is sufficient here since all callers are already on or can hop to main.) The BLE/HK/WC inserts must run on that isolation.

**Storage.** JSON file at `Documents/glucose_history.json` in the watch app extension container. **Not** App Group — the complication widget consumes the baked snapshot color, not the history. File format:

```swift
struct StoredGlucoseReading: Codable {
    let epochSeconds: Int    // Int(readingDate.timeIntervalSince1970)
    let glucoseMgDl: Int     // canonical integer mg/dL (NEVER display units)
    let sequence: Int?       // G7 EGV sequence when known; nil for HK
    let source: String       // "ble" | "wc" | "hk"
}
```

**Units invariant.** `glucoseMgDl` is always canonical mg/dL. The WC path now delivers mg/dL (P2); HK delivers a `Double` from `HKQuantity.doubleValue(for: .milligramsPerDeciliter)` (integer-valued, Double-typed) which is **rounded** to `Int` at insert; BLE is already integer mg/dL. Display-unit conversion (mmol/L) happens only at render in `loadAsDisplayValues`. A **logged canary** (not a hard `assert`, which is stripped in release) guards against accidental display-unit values: `if reading.glucoseMgDl != 0 && reading.glucoseMgDl < 25 { log("units_suspicious mgdl=\(reading.glucoseMgDl) source=\(reading.source)") }` — any realistic mmol/L value (≤ ~22) trips it, while the `!= 0` allows a sentinel. Dexcom floors real readings at 40 mg/dL, so `< 25` has no legitimate-reading false positives.

Color is **not stored** — computed at read time from cached settings (W5).

**Capacity — enforce BOTH age and count.** Age-pruning alone (drop > 24 h) does *not* guarantee ≤ 288 entries: duplicates that slip the dedup, HK backfill quirks, or off-cadence values can exceed it. After prune+sort, **hard-cap with `suffix(288)`**:
```swift
entries = entries
    .filter { $0.epochSeconds >= cutoff24h }
    .sorted { $0.epochSeconds < $1.epochSeconds }
if entries.count > 288 { entries = Array(entries.suffix(288)) }   // keep the newest 288
```

**Merge logic.** Two entry points — a single-reading insert for the BLE and HK paths (which arrive one at a time), and a **batch insert** for the WC path (which arrives as up to 24 readings at once). The batch form prunes, sorts, and writes the file **once** per delivery rather than once per reading:

```swift
// Single-reading insert — BLE / HK (one disk write each; they arrive singly).
func insert(_ reading: StoredGlucoseReading) {
    mergeInMemory(reading)   // dedup/replace/append only — no sort, no write
    pruneOlderThan24h()
    sortAscending()
    writeAtomically()
}

// Batch insert — WC delivery (one prune/sort/write for the whole batch).
func insert(_ readings: [StoredGlucoseReading]) {
    for r in readings { mergeInMemory(r) }
    pruneOlderThan24h()
    sortAscending()
    writeAtomically()        // single atomic write for the batch
}

// mergeInMemory(reading):
//   1. Find existing entry with |existingEpoch - reading.epochSeconds| <= 1
//      AND ( both sequences exist and are equal
//            OR at least one side's sequence is nil )   ← sequence wins when present;
//                                                          otherwise the ±1s window is the key
//   2. found & existing priority >= reading priority → no-op
//   3. found & reading priority > existing            → replace
//   4. not found                                      → append
```

> **Why "either sequence nil," not "both nil."** P2 sends WC chart entries as `{date, glucoseMgDl}` with **no sequence**; BLE readings carry a G7 sequence. The same physical EGV arriving via both channels is ~1 s apart (observed BLE/WC skew). A "both nil" rule would never match BLE(seq=X) against WC(seq=nil) → duplicate chart points. "Either nil" lets the ±1 s timestamp dedup them, with source priority (`ble=3 > wc=2`) keeping the BLE copy — mirroring `shouldUpdate`'s practical behavior. HK(nil)+WC(nil) at ~1 s also dedup correctly; genuinely distinct readings are never within 1 s at the 5-min cadence. (If `GlucoseStored` exposes a sequence, sending it in the WC payload would make this exact; the "either nil" rule is the correct fallback when it doesn't.)

Source priority: `ble=3`, `wc=2`, `hk=1` — mirrors `TrioComplicationDataSource.priority`.

> **Rationale for the batch form (W2 reconciliation).** The cost of per-reading insert is not the sort (288 entries × 24 ≈ negligible CPU) — it is **24 atomic file writes** per WC delivery where one suffices. On watchOS, atomic writes (temp-file + rename) are syscall-heavy; the batch insert collapses them to one. Correctness is identical either way.

**Write sites:**
- BLE: `G7WatchSensorAdapter.handleSensorDidRead` after building the snapshot (already on `@MainActor`) → single `insert`.
- HK: `WatchState.finishHKGlucoseObserverFetch` in the `DispatchQueue.main.async` block (~`:787–790`, the same pass as `applyHKSnapshot`) → single `insert` (rounded mg/dL) **and** the snapshot bubble-hex bake (when mg/dL valid) in that one block, so HK insert + snapshot color are written together.
- WC: `WatchState.processRawDataForWatchState` → **batch** `insert(_ readings:)` of the incoming array (max 24 per W2/P1).

**Read site.** `WatchState.loadGlucoseHistoryOnStartup()` (a thin `WatchState` wrapper called from `TrioMainWatchView.onAppear` after the complication snapshot is loaded) delegates to `WatchGlucoseHistoryStore.shared.loadAsDisplayValues(units:colorComputer:)`. It converts `[StoredGlucoseReading]` → `[(date, glucose, color)]` by (a) converting mg/dL → **display units** using the cached `units` (see "Display units" below), and (b) calling `WatchGlucoseColorComputer.chartColor(for:)` per reading (color is always computed from **mg/dL**, never display units).

**`GlucoseChartView` is unchanged.** It still receives `[(date: Date, glucose: Double, color: Color)]` — `glucose` is in display units; `color` is now computed locally.

**Display units (required wire — else mmol/L users get a broken chart).** Before P2 the phone sent chart points **already converted** to display units, so the watch never needed to convert. After P2 the history stores canonical **mg/dL**, so the watch must convert at render — and it needs to know the user's units. The units are **already on the wire**: the phone sends `WatchMessageKeys.units` (`AppleWatchManager.swift:612`) and converts the y-axis min/max to display units phone-side (`:451–458`, sent `:592–593`). The watch must:
- **Read `WatchMessageKeys.units`** in `processRawDataForWatchState` on every WC delivery and **cache it in `UserDefaults.standard`** alongside the W5 color settings (same restore-before-first-payload + 30-min story), so `loadAsDisplayValues` has a value on cold start.
- `loadAsDisplayValues(units:colorComputer:)` converts each `glucoseMgDl` → display units with the **same** conversion the phone uses (`Decimal(mgDl).asMmolL` for mmol/L; raw for mg/dL), so chart points and the (still phone-sent, display-unit) y-axis stay on the same scale.
- **Do not** convert the color inputs — `WatchGlucoseColorComputer` thresholds and `currentGlucoseMgDl` are mg/dL; only the chart point Y-value and any numeric display are converted.
> mg/dL users are unaffected (mg/dL == mg/dL); the regression is mmol/L-only and silent (numbers look plausible but sit on the wrong axis). The existing mmol/L history validation case ties to this plumbing.

---

### W2 — Chart data population (startup and merge)

**TrioMainWatchView.onAppear** — after the snapshot restore:
```swift
if state.glucoseValues.isEmpty {
    state.glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
        units: WatchGlucoseColorComputer.shared.cachedUnits,   // cached display units (see W1)
        colorComputer: WatchGlucoseColorComputer.shared
    )
}
```

**WC merge.** `processRawDataForWatchState` currently replaces `glucoseValues` wholesale. New:
```swift
// glucoseData is now canonical mg/dL (P2). StoredGlucoseReading(from:source:) IS the P2
// NSNumber-safe decode (single source of truth — no second decode path):
//   guard let date = dateValue(from: d["date"]),
//         let mgDl = (d["glucoseMgDl"] as? NSNumber)?.intValue else { return nil }
let readings = glucoseData.compactMap { StoredGlucoseReading(from: $0, source: "wc") }   // compactMap: skips malformed
WatchGlucoseHistoryStore.shared.insert(readings)            // batch — one disk write
state.glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
    units: WatchGlucoseColorComputer.shared.cachedUnits,
    colorComputer: WatchGlucoseColorComputer.shared
)
```
> `StoredGlucoseReading(from: [String: Any], source:)` is a **failable** initializer implementing exactly the P2 decode (bridging-safe date + NSNumber `glucoseMgDl`, no `color`). W2 uses it via `compactMap` so a malformed entry is skipped, not crashed — and there is only one decode definition, not two that can drift.

WC sends ≤ 24 readings (P1); the batch insert prunes/sorts/writes once.

---

### W3 — IOB/COB/lastLoopTime persistence

**Four new UserDefaults keys** (watch extension standard UserDefaults, not App Group):

```
WatchState.cachedIOB          String?
WatchState.cachedCOB          String?
WatchState.cachedLastLoopTime String?
WatchState.cachedWCTimestamp  Double   // timeIntervalSince1970 of lastWatchStateUpdate when cached
```

**Write.** At the end of `processRawDataForWatchState`:
```swift
UserDefaults.standard.set(iob, forKey: "WatchState.cachedIOB")
UserDefaults.standard.set(cob, forKey: "WatchState.cachedCOB")
UserDefaults.standard.set(lastLoopTime, forKey: "WatchState.cachedLastLoopTime")
UserDefaults.standard.set(lastWatchStateUpdate?.timeIntervalSince1970, forKey: "WatchState.cachedWCTimestamp")
```

> **`cachedWCTimestamp` must be the WatchState build time (`lastWatchStateUpdate`), not `Date()` at cache-write time.** Verified: `processRawDataForWatchState` assigns the incoming `WatchMessageKeys.date` directly to `lastWatchStateUpdate` (`WatchState.swift:2035`) — that is the time the *phone built the WatchState payload* (not the CGM reading time, and not watch receipt time). The 30-min cap and `isWatchStateDated` both key on it, so caching it preserves correct staleness; caching `Date()` at write would make a stale payload (e.g. built 20 min ago) look fresh. Do not "simplify" to `Date()`.

**Load (with 30-min cap).** In `WatchState.init()` — restore only if the cache is ≤ 30 min old; otherwise leave `--`:
```swift
let cachedTS = UserDefaults.standard.object(forKey: "WatchState.cachedWCTimestamp") as? Double
// Reject both stale (> 30 min) AND future-dated (age < 0) caches: a clock-skewed or malformed
// future timestamp would otherwise read as "fresh" indefinitely until the wall clock catches up.
let ageOK = cachedTS.map { ts -> Bool in
    let age = Date().timeIntervalSince1970 - ts
    return age >= 0 && age <= 30 * 60
} ?? false
if ageOK, let t = cachedTS {
    iob          = UserDefaults.standard.string(forKey: "WatchState.cachedIOB") ?? "--"
    cob          = UserDefaults.standard.string(forKey: "WatchState.cachedCOB") ?? "--"
    lastLoopTime = UserDefaults.standard.string(forKey: "WatchState.cachedLastLoopTime") ?? "--"
    lastWatchStateUpdate = Date(timeIntervalSince1970: t)
}
// else: leave defaults ("--") — stale-by-hours IOB/COB is misleading and is not restored.
```

Interaction with W4: within the 30-min window the restored values display, dimmed if past the `isWatchStateDated` staleness threshold; older than 30 min they show `--` (never restored).

---

### W4 — Display gate fix

**Current (incorrect)** — actual `TrioMainWatchView.swift` (verified line refs):
```swift
// :179  iob value — ORs isSessionUnreachable into the "--" gate (WRONG)
Text(isWatchStateDated || isSessionUnreachable ? "--" : state.iob ?? "--")
// :180  iob color — already correct (only isWatchStateDated)
    .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
// :193  cob value — ORs isSessionUnreachable into the "--" gate (WRONG)
Text(isWatchStateDated || isSessionUnreachable ? "--" : state.cob ?? "--")
// :194  cob color — ALSO ORs isSessionUnreachable (WRONG; asymmetric with iob :180)
    .foregroundStyle(isWatchStateDated || isSessionUnreachable ? Color.secondary : Color.white)
```

**Three edits:** strip `isSessionUnreachable` from the value gates at **:179** and **:193**, and from the cob color gate at **:194**. The iob color gate at **:180** is already correct and is the template.

**Target state:**

| Condition | Glucose bubble | IOB/COB display | Action buttons |
|---|---|---|---|
| Data fresh, phone reachable | Normal | Normal | Enabled |
| Data fresh, phone unreachable | Normal | Normal (cached) | **Disabled** |
| Data stale, phone reachable | Glucose visible, `STALE DATA` | Dimmed | Disabled |
| Data stale, phone unreachable | Glucose visible, `STALE DATA` | Dimmed | Disabled |
| No data ever received | `--` | `--` | Disabled |

**New display gate for IOB/COB:**
```swift
Text(state.iob ?? "--")
    .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
```

**Action buttons** keep the existing `isWatchStateDated || isSessionUnreachable` disable gate — unchanged.

**Rename note (W12).** W4 narrows `isSessionUnreachable` to buttons only, sharpening the name/meaning mismatch. W12 renames it (e.g. `isPhoneCommandUnavailable`) at the declaration + action-button call sites, in the same patch-12 regen as W4.

---

### W5 — Local color computation (replaces phone-sent colors)

**Why this exists.** P2 stops the phone from sending color to the watch (`currentGlucoseColorString` for the bubble; a per-point `color` hex for the chart). The watch must therefore reproduce the phone's *exact* color rules locally — this is a parity task, not new policy. Confirmed against `AppleWatchManager.swift`:

- **Chart points** (`:420–432`) — always colored. `getDynamicGlucoseColor(value, high, low, target, scheme)`; static scheme uses the user's settings thresholds, dynamic uses the hue gradient.
- **Current-glucose bubble** (`:398–410`) — same computed color, **but forced to white when the reading is within `[settings low, settings high]`**, colored only when `≤ low` or `≥ high`.
- **Dynamic-scheme hue bounds are hard-coded `55/220`** (`:388–393`), not the user thresholds. The white-in-range gate and the static scheme use the user thresholds. Target is the hue midpoint.

So the watch needs the four **settings** (low, high, target, scheme) — pushed from the phone (P2) — and hard-codes `55/220` for the dynamic hue bounds, matching the phone.

**Settings live in `UserDefaults.standard` (watch app), not App Group.** The complication widget renders `entry.glucoseColor` from the baked snapshot (verified: `TrioWatchComplication.swift` threads `snapshot.glucoseColor` onto the `TimelineEntry`); it never reads color settings. Only the watch app computes color, so per-extension `UserDefaults.standard` is sufficient.

**Extract the pure hue function into a watch-safe shared file — do not share `DynamicGlucoseColor.swift` whole.** Verified blocker (Codex, in-worktree): the watch globs in `sync_project_files_config.rb` do **not** include `DynamicGlucoseColor.swift` or any shared-helper glob, and the file references `GlucoseColorScheme`, whose own file **imports UIKit** — unavailable on watchOS. So target-membership sharing is not viable. Instead:
- Create a new file **`Trio/Sources/Helpers/GlucoseHueColor.swift`** that extracts the **hue *math*** (not just the Color wrapper), so the watch can compute dynamic hex without any `Color → hex` round-trip:
  ```swift
  struct GlucoseHueComponents { let hue: Double; let saturation: Double; let brightness: Double }

  /// Pure HSB math — the parity-sensitive part. **Foundation only; no SwiftUI/UIKit** (this is the whole file).
  func glucoseHueComponents(_ glucose: Decimal, high: Decimal, low: Decimal, target: Decimal) -> GlucoseHueComponents
  ```
  The SwiftUI `Color` wrapper stays in the **phone-only** `DynamicGlucoseColor.swift` (which imports SwiftUI) and is refactored to call the shared math:
  ```swift
  // DynamicGlucoseColor.swift (phone) — refactored, not moved out:
  func calculateHueBasedGlucoseColor(glucoseValue: Decimal, highGlucose: Decimal, lowGlucose: Decimal, targetGlucose: Decimal) -> Color {
      let c = glucoseHueComponents(glucoseValue, high: highGlucose, low: lowGlucose, target: targetGlucose)
      return Color(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
  }
  ```
  The phone keeps calling `calculateHueBasedGlucoseColor` (then `toHexString`); the **watch** calls `glucoseHueComponents` + a **watch-local** `hexFromHSB(_:) -> String` (deterministic HSB → RGB → `#RRGGBB`, no UIKit). The shared `glucoseHueComponents` keeps the hue/sat/brightness identical on both sides; only the final HSB→hex differs, covered by the dynamic-hex parity validation.
- **Extract the math, refactor the wrapper in place — no symbol move, no duplicate-symbol risk.** `GlucoseHueColor.swift` gains **only** the new `glucoseHueComponents` (Foundation). `calculateHueBasedGlucoseColor` is **not moved**: it stays in `DynamicGlucoseColor.swift`, refactored to call `glucoseHueComponents`. So there is no duplicate definition (the earlier "delete/move + duplicate-symbol" concern no longer applies). `getDynamicGlucoseColor` (phone-only, references `GlucoseColorScheme`) is unchanged. Patch scope: **patch 09** adds `GlucoseHueColor.swift` and edits `DynamicGlucoseColor.swift` (the refactor).
- **Target membership.** At `Trio/Sources/Helpers/`, the **phone** picks up `GlucoseHueColor.swift` automatically via the existing `Trio/Sources/**` glob. Only the **watch** target needs an explicit entry in `sync_project_files_config.rb`. **Delivery lane:** that edit is a **direct `dev` commit** (build infra — not patch-carried), **sequenced before the 205 build**; otherwise the watch target won't see the file and W5 won't compile on watch. (The file is added via the patch stack.)

The watch never calls `getDynamicGlucoseColor`/`calculateHueBasedGlucoseColor` and never references `GlucoseColorScheme` — it does the static branch itself and calls the shared `glucoseHueComponents` (then `hexFromHSB`) for the dynamic branch:

```swift
final class WatchGlucoseColorComputer {
    static let shared = WatchGlucoseColorComputer()

    // Thresholds are canonical INTEGER mg/dL (avoids Decimal(Double) parity drift — see note).
    private(set) var low: Int = 70
    private(set) var high: Int = 180
    private(set) var target: Int = 100
    private(set) var isDynamic: Bool = false
    private(set) var cachedUnits: GlucoseUnits = .mgdL   // display units for the chart (NOT for color math)

    // Hard-coded dynamic-hue bounds — must match AppleWatchManager.swift:388–389.
    private let dynamicLow: Decimal = 55
    private let dynamicHigh: Decimal = 220

    // Static-scheme hex — HARDCODED to match the phone's toHexString() output. CAPTURED authoritatively by
    // running the real UIKit path on the iOS 26.5 simulator (UIColor(Color.X).getRed() then Int(x*255)
    // TRUNCATION, ambient UITraitCollection = light, matching the phone's background WCSession call site).
    // NOTE: SwiftUI's Color.red/.green/.orange are OS-version-dependent and are NOT pure RGB, NOT the
    // UIColor.system* set, and NOT the stale web value (#E84D3D was old-iOS red; iOS 26 red is #FF383C).
    private let staticHighHex   = "#FF8D28"   // == toHexString(.orange), light: (255,141,40)  [iOS 26.5 sim]
    private let staticLowHex     = "#FF383C"   // == toHexString(.red),    light: (255,56,60)   [iOS 26.5 sim]
    private let staticInRangeHex = "#34C759"   // == toHexString(.green),  light: (52,199,89)   [iOS 26.5 sim]
    private let bubbleWhiteHex   = "#ffffff"   // verified AppleWatchManager:409 (hardcoded, not via toHexString)

    private let defaults = UserDefaults.standard
    private enum K { static let low="WatchGlucoseColor.low", high="WatchGlucoseColor.high", target="WatchGlucoseColor.target", dynamic="WatchGlucoseColor.dynamic", units="WatchGlucoseColor.units" }

    init() { load() }

    /// Phone sends integer mg/dL thresholds (no float conversion on the wire). `units` is display-only.
    func apply(low: Int, high: Int, target: Int, dynamic: Bool, units: GlucoseUnits) {
        self.low = low; self.high = high; self.target = target; self.isDynamic = dynamic; self.cachedUnits = units
        defaults.set(low, forKey: K.low); defaults.set(high, forKey: K.high)
        defaults.set(target, forKey: K.target); defaults.set(dynamic, forKey: K.dynamic)
        defaults.set(units.rawValue, forKey: K.units)
    }
    func load() {
        low = (defaults.object(forKey: K.low) as? Int) ?? 70
        high = (defaults.object(forKey: K.high) as? Int) ?? 180
        target = (defaults.object(forKey: K.target) as? Int) ?? 100
        isDynamic = defaults.bool(forKey: K.dynamic)
        cachedUnits = (defaults.string(forKey: K.units)).flatMap(GlucoseUnits.init(rawValue:)) ?? .mgdL
    }

    // ---- HEX-FIRST: hex is canonical (this is what gets baked into the snapshot) ----

    /// Chart points — always colored (no white-in-range).
    func chartColorHex(for mgDl: Int) -> String { colorHex(for: mgDl) }

    /// Current-glucose bubble — white STRICTLY inside (low, high); else the chart color.
    func bubbleColorHex(for mgDl: Int) -> String {
        // Phone colors when mgDl <= low OR mgDl >= high (AppleWatchManager:406), so white is strict.
        if mgDl > low && mgDl < high { return bubbleWhiteHex }   // NOT >= / <=
        return colorHex(for: mgDl)
    }

    private func colorHex(for mgDl: Int) -> String {
        if isDynamic {
            // Shared HSB math (parity) + watch-local HSB→hex (no UIKit). Validate dynamic hex vs phone.
            let c = glucoseHueComponents(Decimal(mgDl), high: dynamicHigh, low: dynamicLow, target: Decimal(target))
            return hexFromHSB(c)   // watch-local: HSB → RGB → "#RRGGBB"
        }
        if mgDl >= high { return staticHighHex }     // static branch, settings thresholds
        if mgDl <= low  { return staticLowHex }
        return staticInRangeHex
    }

    // Color accessors derive from hex so render and baked-snapshot color are identical.
    func chartColor(for mgDl: Int)  -> Color { Color(hex: chartColorHex(for: mgDl)) }
    func bubbleColor(for mgDl: Int) -> Color { Color(hex: bubbleColorHex(for: mgDl)) }
}
```

**Hex generation is hex-first (one approach — no `Color.resolve`).** The computer above is the source of truth: static bands return **hardcoded hex constants** (captured from the phone's `toHexString()` for `.orange`/`.red`/`.green` and `#ffffff`), and the dynamic band computes hex from the shared `glucoseHueComponents` via a watch-local **`hexFromHSB(_:)`** (deterministic HSB → RGB → `#RRGGBB`, **`Int(x*255)` truncation — NOT rounding** — to match `toHexString` byte-for-byte; see truncation note below). There is **no** `Color → hex` round-trip and **no** `Color.resolve` path — `Color(hex:)` is used only in the reverse direction (the `Color` accessors derive from the canonical hex). The existing watch helper still only parses hex → `Color` (`Helper+Extensions.swift:18`); that's fine, since baking goes hex-first and never needs `Color → hex`.

> Note: the white-in-range gate always uses the **settings** thresholds, even when the color itself comes from the dynamic 55/220 scheme — exactly as the phone does.

> **Static-color hex — RESOLVED (authoritative capture, 2026-06-06).** Source path confirmed: the static branch returns SwiftUI `Color.orange` (high) / `Color.red` (low) / `Color.green` (in-range) — `DynamicGlucoseColor.swift:23–29`, reached via `getDynamicGlucoseColor` from `AppleWatchManager.swift:398/420` — through `toHexString()` (`GlucoseColorScheme.swift:21`), which does `UIColor(self).getRed()` then `Int(x*255)` **truncation**.
> - **Captured by running the real UIKit path**, not by reasoning or web lookup: a disposable Swift tool compiled against the iphonesimulator SDK and run via `simctl spawn` on the iOS **26.5** simulator, replicating `toHexString()` exactly (incl. the `Int(x*255)` truncation) under the ambient `UITraitCollection.current` (= light, which the unforced call also produced — matching the phone's background WCSession call-site context). Results (light mode):
>   | Band | SwiftUI color | Hex | RGB |
>   |---|---|---|---|
>   | low | `Color.red` | **`#FF383C`** | 255,56,60 |
>   | in-range | `Color.green` | **`#34C759`** | 52,199,89 |
>   | high | `Color.orange` | **`#FF8D28`** | 255,141,40 |
> - **Why reasoning/web failed (recorded so nobody re-litigates this):** SwiftUI's `Color.red/.green/.orange` are **OS-version-dependent** and are **not** pure RGB (`#FF0000`…), **not** `UIColor.system*` (`systemRed #FF3B30`, `systemOrange #FF9500`), and **not** the stale web value (`#E84D3D` was *old-iOS* red from 2020-era articles; iOS 26 resolves red to `#FF383C`). Only executing Apple's resolver on the target OS gives the bytes.
> - **Residual caveat (covered by the in-205 confirmation log, see below):** the capture is for **iOS 26.5, light/ambient**. If the phone forces dark mode app-wide its call-site traits could differ (dark: red `#FF4245`, green `#30D158`, orange `#FF9230`), and a future iOS could shift the palette again. The temp `color_parity` log shipped in 205 confirms the baked constants on the real device/OS; correct in 206 if it ever diverges.
> - **Dynamic-branch — verified + captured.** `calculateHueBasedGlucoseColor` uses `Color(hue:, saturation: 0.6, brightness: 0.9)` (`DynamicGlucoseColor.swift:64`) — **not** 1.0/1.0. The shared `glucoseHueComponents` must return `saturation = 0.6, brightness = 0.9`, and `hexFromHSB` must convert HSB→RGB then `Int(x*255)` **truncate** (matching `toHexString`). Dynamic output is appearance-independent (same light/dark); authoritative expected hexes at target=100, bounds 55/220: **55→`#E55B5B`, 70→`#E5B75B`, 100→`#5BE55B`, 130→`#5BE5B1`, 180→`#5B89E5`, 220→`#A05BE5`** (iOS 26.5 sim) — use these as the dynamic-parity golden values.

**New `WatchMessageKeys` (added in patch 09 — earliest consumer):**
```swift
static let lowGlucoseThreshold       = "low_glucose_threshold"     // Int, mg/dL (canonical — no float on the wire)
static let highGlucoseThreshold      = "high_glucose_threshold"    // Int, mg/dL
static let glucoseTarget             = "glucose_target"            // Int, mg/dL
static let glucoseColorSchemeDynamic = "glucose_color_dynamic"     // Bool
static let currentGlucoseMgDl        = "current_glucose_mgdl"      // Int, mg/dL (for bubble color)
```

**Bubble color + snapshot baking.** `GlucoseTrendView` currently uses `state.currentGlucoseColorString.toColor()`. Because `state.currentGlucoseMgDl` is `Int?` (P2), the live render **must guard** — never pass a sentinel to the computer:
```swift
// GlucoseTrendView — explicit Int? handling:
if let mgDl = state.currentGlucoseMgDl {
    bubbleColor = WatchGlucoseColorComputer.shared.bubbleColor(for: mgDl)
} else {
    bubbleColor = .secondary           // missing/invalid current glucose → neutral, NOT red
}
```
(`isWatchStateDated` continues to drive the secondary/dimmed treatment as today; the `guard` above is specifically for missing mg/dL, independent of reachability.) Because the complication widget renders `snapshot.glucoseColor` (via `glucoseDisplayColor`, which parses the entry's hex and never reads settings), the watch app must **bake the bubble hex into the snapshot** when building it — and likewise only when mg/dL is valid (`snapshot.glucoseColor = nil` otherwise, per the P2 invariant). Verified: `TrioComplicationSnapshot` already has `glucoseColor` (`TrioComplicationDataStore.swift:49`), but the **HK and direct-BLE snapshot builders currently write `nil`** — both must be updated to set the watch-computed bubble hex when valid (the WC builder too). This is where the watch-safe `bubbleColorHex(for:)` helper is consumed.

> **Known minor parity gap (accepted).** The widget's color fallback (`TrioWatchComplication.swift:88+`) computes a color from the value against **hardcoded 70/180 static** thresholds with no white-in-range rule — matching neither the baked bubble color nor the chart's 55/220 dynamic rule. It fires only when `glucoseColor` is nil/unparseable, which baking-on-every-snapshot makes rare (a pre-upgrade snapshot, until the next reading). Aligning the fallback would require the widget to read settings → App Group, defeating the `UserDefaults.standard` decision, so it is left as-is.

`currentGlucoseColorString` is **not deleted** (upstream constant); the phone stops populating it and the watch stops reading it.

---

### W6 — Removed (obsolete)

**Dropped from build 205.** W6 originally persisted `bleLastEGVSequence` so the post-restart **denominator guard** would work before the first new EGV. W7 replaces that sequence-arithmetic denominator entirely with the slot accumulator (`expectedSlotsToday − gatedSlotsToday`), so the persisted last-sequence has **no remaining consumer**: dedup uses each reading's *own* sequence (in `mergeInMemory`/`shouldUpdate`), not a stored global last-sequence. Adding the field/key/write/load/reset would be dead code. If a future need for a persisted last-sequence appears, reintroduce it with a named consumer.

> The `Keys` enum still gets the W13 convention migration (six existing members → `G7WatchAdapter.*`); it simply does not gain a `lastEGVSequence` key.

---

### W7 — `expectedSlotsToday` + `gatedSlotsToday` counters

**Purpose.** `expectedSlotsToday` = 5-minute slots since midnight where the sensor was active and the adapter was eligible-by-identity. `gatedSlotsToday` = the subset of those that C1 deliberately deferred (background, no runtime). The debug rows show `N / (D − gated)` so the on-watch ratio measures capture against windows actually *attempted*, not windows deferred by design. BetterStack still sees the full `expectedSlotsToday` via telemetry.

**Why sequence arithmetic fails on swap days.** When a new sensor starts mid-day, `bleFirstSequenceToday` resets and the prior sensor's contribution is lost. `expectedSlotsToday` accumulates across both sensors without resetting on swap.

**Current code.** `emitExpectedWindowTick` (`:429–438`) today **only logs** — it computes `eligible`/`reason` and emits `expected_window`. It does no counting; the counter block below is entirely additive.

**New keys & fields:**
```swift
private var expectedSlotsToday: Int = 0
private var gatedSlotsToday: Int = 0               // == gatedSlotEpochsToday.count (mirrored for display)
private var lastExpectedSlotEpoch: Int = -1        // expected: monotonic high-water; persisted, restored on cold start
private var gatedSlotEpochsToday: Set<Int> = []    // gated: SET (a slot can be un-gated by a later capture); persisted as [Int]
static let expectedSlots   = "G7WatchAdapter.expectedSlotsToday"
static let gatedSlotEpochs  = "G7WatchAdapter.gatedSlotEpochsToday"   // [Int]
```

**Increment (expected) — monotonic high-water, today-only.** In `emitExpectedWindowTick`, count each 5-minute slot at most once using a **strictly-increasing** guard, and only if the slot is in the current local day. The high-water (`>`) guard — not `!=` — is required because `reanchorExpectedWindowTimer(coldStart:true)` replays slots from `lastEGVEpoch + 300` to now (adapter `:371–393`); on a restart those already-counted slots would be re-emitted, and a bare `!=` only blocks the single most-recent slot, so every earlier replayed slot would be **double-counted**. `lastExpectedSlotEpoch` is persisted and restored, so the high-water survives restart:
```swift
private func emitExpectedWindowTick(epoch: Int, retroactive: Bool) {
    let lastSuccess = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int ?? -1
    let eligible = !isStopped && expectedSensorName != nil
    let reason = eligible ? "ok" : (isStopped ? "stopped" : "no_sensor")
    if eligible {
        advanceDayIfNeeded()                                  // forward-only, keyed on real time
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let slotEpoch = epoch - (epoch % 300)
        if slotEpoch >= startOfToday && slotEpoch > lastExpectedSlotEpoch {   // monotonic: skips replays of counted slots
            expectedSlotsToday += 1
            lastExpectedSlotEpoch = slotEpoch
            persistDailyCounters()                            // persists counters + lastExpectedSlotEpoch
            mirrorDailyCountersToWatchState()
        }
    }
    log("expected_window",
        "tick_epoch=\(epoch) last_success_epoch=\(lastSuccess) eligible=\(eligible) reason=\(reason) retroactive=\(retroactive) ext_session_active=\(lastKnownExtSessionActive)")
}
```

**Increment (gated) — slot-set, at the C1 gate, removable on capture.** `gatedSlotEpochsToday` is updated in `beginScanIfEligible` (C1): the current 5-minute slot is inserted (idempotent — `Set`), so multiple gated attempts (start / WC push / disconnect-rescan) in one window count once. It must live at the gate — *not* derived in the tick — because the expected-window timer is suspended in exactly the background windows C1 gates. **Crucially, a slot is removed from the set when an EGV is captured in it** (EGV-save, `:796`): a window deferred in the background but then captured after foregrounding is *not* a gated loss, so it must not be subtracted from the denominator. `gatedSlotsToday = gatedSlotEpochsToday.count` is mirrored for display; `denom = expectedSlotsToday − gatedSlotsToday` now excludes only genuinely-gated-and-uncaptured windows.

> **Why a set, not a high-water int.** With a scalar high-water you can't *remove* a slot when it's later captured, so a gated-then-captured window would both subtract from the denominator and add to the numerator → ratio can exceed 100%. The set + remove-on-capture closes that. Cost is ≤288 ints/day.

**Day rollover — forward-only, real-time keyed.** `advanceDayIfNeeded()` compares **`Calendar.startOfDay(for: Date())`** against the stored `calendarDay`; it resets the daily counters, the `lastExpectedSlotEpoch` high-water (to `-1`), **and clears `gatedSlotEpochsToday`** only when the real day has advanced. It never rolls the day *backward*. Combined with the today-only guards (`slotEpoch >= startOfToday`), a morning replay across midnight counts only post-midnight slots and drops pre-midnight ones (they belong to yesterday). It is invoked at the top of both `emitExpectedWindowTick` and `beginScanIfEligible` (the gate often runs first after midnight while timers are suspended).

**Persist/load/reset.** `persistDailyCounters()` (`:460–463`) currently writes only `connects`/`egvs` — **extend it to write `expectedSlots`, `lastExpectedSlotEpoch`, and `gatedSlotEpochs` (the set, as `[Int]`)**. Add all to `loadDailyCounters()` (`:442`); on load, `gatedSlotsToday = gatedSlotEpochsToday.count`. Midnight rollover resets the high-water to `-1` and clears the set. **None** is cleared on sensor swap (slots under the previous sensor today still count).

**Mirror to WatchState:** `expectedSlotsToday: Int`, `gatedSlotsToday: Int` (new properties).

**`countWithDenominator` replacement** in `G7DirectBleDebugSection` (clamp at 0 — `gated` can momentarily lead `expected` if a slot is gated live before its expected tick replays):
```swift
private func countWithDenominator(_ count: Int) -> String {
    let denom = max(0, WatchState.shared.expectedSlotsToday - WatchState.shared.gatedSlotsToday)
    guard denom > 0 else { return "\(count)" }
    return "\(count) / \(denom)"
}
```

The old **denominator computation** (first-sequence + last-sequence arithmetic) is removed (see W6 removal). The `bleFirstSequenceToday` *field* is **pre-existing** (not introduced by W6) and is **kept** — C2 still resets it on an accepted swap and W13 still migrates its key. Per-reading sequence dedup in `mergeInMemory`/`shouldUpdate` is unaffected (it uses each reading's own sequence, never a persisted global last-sequence).

> **Verified (2026-06-06): `bleFirstSequenceToday` has NO remaining value-consumer once the denominator is replaced — it becomes write-only state. Keep for 205, schedule removal as a separate cleanup.** Full survey of the field + its `Keys.firstSequenceToday` UserDefaults key in `G7WatchSensorAdapter.swift`:
> - **Its single value-reader is the OLD denominator** in `ComplicationDebugView.swift:649` — `countWithDenominator` reads `bleFirstSequenceToday` **and** `bleLastEGVSequence` (`expected = last - first + 1`). W7 **replaces** this exact function with `max(0, expectedSlotsToday − gatedSlotsToday)`, which references neither field. So after W7 lands, nothing reads `bleFirstSequenceToday`'s value.
> - **The `handleSensorDidRead` regression check (`:803–810`) is write-only maintenance.** It reads the field **only to decide whether to lower the anchor** (`if currentSequence < anchor { anchor = currentSequence }`, else seed on first read), then writes it back. It drives **no** new-sensor detection, no branch, no reset, no log/telemetry field. (New-sensor detection is unaffected — and C2 now keys identity on `name+epoch`, fully independent of this anchor.)
> - **All other sites are write/persist/reset only:** loaded in `loadDailyCounters` (`:455`); nilled+removed on swap (`applyNewSensorName:305`), on midnight rollover (`loadDailyCounters:448`, `loadDailyCountersIfNewCalendarDay:471`), and on EOS (`performEndOfSessionTeardown:566`); mirrored to `WatchState.bleFirstSequenceToday` (`:481`, declared `WatchState.swift:117`) solely so the debug view could read it for the denominator.
> - **Conclusion / action.** Confirmed dead-after-W7. Per the plan it is **kept in 205** (pre-existing, harmless, and removing a persisted key is its own migration); C2 still resets it and W13 still migrates its key. **Follow-up cleanup (post-205, not scoped here):** remove the field + `Keys.firstSequenceToday` + its mirror + the `:803–810` maintenance block, alongside the `bleLastEGVSequence` removal — the two are only ever read together by the now-replaced denominator. A `spawn_task` chip has been flagged for this cleanup.

---

### W8 — Debug view improvements

Two rows added to `G7DirectBleDebugSection.body`, above `Pre-EGV disconnects:`:
```swift
HStack { Text("Last BLE event:"); Spacer()
    Text(formatG7Time(WatchState.shared.g7DirectBleLastEventAt)).foregroundColor(.secondary) }
HStack { Text("Session ID:"); Spacer()
    Text(G7WatchSensorAdapter.shared.adapterSessionID ?? "—")
        .foregroundColor(.secondary).font(.system(.caption, design: .monospaced)) }
```
`g7DirectBleLastEventAt` (`WatchState.swift:98`) and `adapterSessionID` (`G7WatchSensorAdapter.swift:128`) already exist — display-only additions.

---

### W9–W13 — Low-priority audit items + key migration

**W9 — `log()` unstructured `Task`.** `G7WatchSensorAdapter.log()` (`:321`) spins a fresh `Task { await … }` per event (`:324`). Route through a single serial logging actor/queue instead. (This `log()` already passes `g7Session: adapterSessionID` at `:330` — adapter lines are *not* the `g7_session=nil` source; see Deferred.)

**W10 — `triggerConfirmation` coalescing.** Hold the 1.5s clear in a `DispatchWorkItem`; cancel the prior before scheduling. Debug-only.

**W11 — `applyG7DirectBleSnapshot` timeout hygiene.** After `syncTimeoutWorkItem?.cancel()` set `= nil` (match `processRawDataForWatchState`).

**W12 — rename `isSessionUnreachable`.** See W4. Mechanical; same patch-12 regen.

**W13 — adapter key-naming migration.** The `Keys` enum mixes two conventions: `sensorName`/`connects`/`egvs`/`calendarDay` use `G7DirectBLEObserver.*`; `lastEGVEpoch`/`firstSequenceToday` use `G7WatchAdapter.*`. Migrate all to `G7WatchAdapter.*`:
```swift
private enum Keys {
    static let sensorName        = "G7WatchAdapter.sensorName"
    static let lastEGVEpoch      = "G7WatchAdapter.lastEGVEpoch"
    static let calendarDay       = "G7WatchAdapter.bleCountersCalendarDay"
    static let connects          = "G7WatchAdapter.bleConnectsToday"
    static let egvs              = "G7WatchAdapter.bleEGVsToday"
    static let firstSequenceToday = "G7WatchAdapter.bleFirstSequenceToday"
    static let expectedSlots     = "G7WatchAdapter.expectedSlotsToday"   // W7
    static let gatedSlotEpochs    = "G7WatchAdapter.gatedSlotEpochsToday" // W7 ([Int] set)
}
```
- **`sensorName` is load-bearing** (drives reconnect; read in `init`/`G7Sensor` seed at `:181`, getter/setter `:167–168`). Renaming the key string would lose the bound sensor on upgrade, forcing a fresh scan. Add a **one-time read-through migration** in `init()` (before the `G7Sensor` seed): if the new key is empty and the old `"G7DirectBLEObserver.sensorName"` has a value, copy it forward and remove the old key.
- **Daily counters self-heal**: `loadDailyCounters` keys off `calendarDay`; with the renamed key the stored day reads as absent → a one-time reset of *today's* debug counts only (acceptable). No migration needed for `connects`/`egvs`/`calendarDay`.
- **`lastEGVEpoch` and `firstSequenceToday` are already `G7WatchAdapter.*`** — they are **not** renamed by W13, only the four `G7DirectBLEObserver.*` keys are. So the cold-start replay anchor (`lastEGVEpoch`, read by `reanchorExpectedWindowTimer`) is **preserved across the upgrade** — no replay discontinuity from a key rename. The only upgrade-time reset is the daily counters above (and the brand-new W7 `expectedSlots`/`gatedSlotEpochs` + slot high-water mark, which start fresh by definition).

---

### P1 — WC payload size reduction

**`AppleWatchManager.swift:516–523`** (upstream fetch — see patch mapping):
```swift
// before:
predicate: NSPredicate.glucose,   // date >= Date.oneDayAgo
fetchLimit: 288
// after:
predicate: NSPredicate.glucoseForTwoHoursAgo,   // date >= Date().addingTimeInterval(-7200)
fetchLimit: 24
```
Add `static var glucoseForTwoHoursAgo: NSPredicate` to `GlucoseStored+helper.swift`.

**Payload size impact:** 24 readings × ~20 bytes (date + mg/dL, no color) ≈ 480 bytes vs ~14 KB. **~28× reduction per transfer.**

**Dependency.** P1 requires W1 (history store) in place first so the watch retains the full 24h chart window. Do not ship P1 without W1.

---

### P2 — Canonical mg/dL payload + remove embedded colors

**Confirmed bug.** `AppleWatchManager.swift:416–418` currently sends chart values in **display units** (`Decimal(glucose.glucose).asMmolL` when mmol/L is selected). Storing those as `glucoseMgDl: Int` would persist `5`/`6` for mmol/L users. The fix makes the payload canonical mg/dL.

**Chart entries (patch 09, `setupWatchState`).** Replace the display-unit + color map with raw mg/dL under a **renamed wire key**:
```swift
// each entry: ["date": epoch, "glucoseMgDl": Int(glucose.glucose)]   // raw mg/dL, no color
```
**Rename the wire key `"glucose"` → `"glucoseMgDl"` end-to-end** (don't keep `"glucose"` with silently-changed units). The value's *meaning* changes from display-units to mg/dL; renaming means a stale **queued** old-format payload (which carries `"glucose"`/`"color"`) simply fails to decode and is ignored, rather than being mis-read as mg/dL. `WatchGlucoseObject` changes accordingly (see below).

**Current glucose (patch 09).** Keep `currentGlucose` as the preformatted **display string** (text only). Add `currentGlucoseMgDl` (**Int**, raw mg/dL) so the watch can compute the bubble color. The watch's `WatchState.currentGlucoseMgDl` property is **optional (`Int?`)** and validity-gated on decode (`>= 25`, else `nil`) — see the watch-side rule below.

**Color settings (patch 09, `watchStateToDictionary`).** Add the four W5 keys. Send thresholds as **Int mg/dL** (canonical) — not `Double` — so the watch never does `Decimal(Double)` and there's no representation drift on a parity-sensitive path:
```swift
dict[WatchMessageKeys.lowGlucoseThreshold]       = Int(lowGlucose)        // mg/dL
dict[WatchMessageKeys.highGlucoseThreshold]      = Int(highGlucose)       // mg/dL
dict[WatchMessageKeys.glucoseTarget]             = Int(currentGlucoseTarget)
dict[WatchMessageKeys.glucoseColorSchemeDynamic] = (glucoseColorScheme == .dynamicColor)
dict[WatchMessageKeys.currentGlucoseMgDl]        = Int(latestGlucose.glucose)
```
> If any threshold can legitimately be non-integer mg/dL in the phone's model, round deliberately at the send site (don't let `Decimal(Double)` round implicitly on the watch). Trio's thresholds are integer mg/dL, so `Int(...)` is exact here.

**Stop populating `currentGlucoseColorString`** (`watchStateToDictionary` `:579`) **and remove its allowlist entry** (`:858`) — the upstream constant stays defined.

**`WatchGlucoseObject` model change.** Confirmed `color: String` is non-optional (`WatchGlucoseObject.swift`). Change the model — remove `color`, and `glucose` is now canonical mg/dL:
```swift
struct WatchGlucoseObject: Hashable, Equatable, Codable {
    let date: Date
    let glucose: Double   // canonical mg/dL
}
```
The watch computes per-point color via `WatchGlucoseColorComputer.chartColor(for:)` at render.

**Phone `WatchState` `==`/`hash` must drop `.color` (compile blocker — verified).** `Trio/Sources/Models/WatchState.swift` is the Codable DTO with a **custom** `Equatable`/`Hashable`. Removing `WatchGlucoseObject.color` breaks two sites:
- `static func ==`: the `glucoseValues` term `zip(...).allSatisfy { $0.0.date == $0.1.date && $0.0.glucose == $0.1.glucose && $0.0.color == $0.1.color }` — drop the `&& $0.0.color == $0.1.color`.
- `hash(into:)`: the `for value in glucoseValues { … hasher.combine(value.color) }` loop — drop the `hasher.combine(value.color)`.

`WatchGlucoseObject` + the DTO `WatchState` are the **phone-side** encode/model representation (and back the phone's custom `==`/`hash` used for change-detection before sending). The **watch does not consume `WatchGlucoseObject`** — it decodes the raw WC dictionary into `[(date, glucose, color)]` tuples (see watch decode below). So this `.color` removal is a **phone-side change (patch 09)**; the watch's matching change is the **dictionary decode, which appears in both patch 09 and patch 12** (see "Watch-side decode/plumbing" below). They must land in the same build (different files, not "compiled into both targets"). Add `WatchGlucoseObject.swift` + `WatchState.swift` to P2's patch-09 scope.

**Watch side (`processRawDataForWatchState`):**
- Read the four color keys + `WatchMessageKeys.units` (NSNumber-safe ints; units via `GlucoseUnits(rawValue:)`) → `WatchGlucoseColorComputer.shared.apply(low:high:target:dynamic:units:)`. `units` is cached for the chart's display conversion (see W1 "Display units"); it does **not** affect color math (thresholds stay mg/dL).
- Read `currentGlucoseMgDl` as an **optional, validity-gated** `Int?` — decode only when it's an `NSNumber` with `.intValue >= 25` (the same sentinel floor as the units canary); otherwise `nil`. Bake the bubble hex into `snapshot.glucoseColor` **only when non-nil**; a missing/invalid reading sets `snapshot.glucoseColor = nil`, **never** a baked color:
  ```swift
  if let mgDl = state.currentGlucoseMgDl {            // Int?, already validity-gated on decode
      snapshot.glucoseColor = WatchGlucoseColorComputer.shared.bubbleColorHex(for: mgDl)
  } else {
      snapshot.glucoseColor = nil                     // no data → no color (NOT red)
  }
  ```
  > **Invariant:** never call `bubbleColorHex(for:)`/`chartColorHex(for:)` with a sentinel `0` or a missing value. `currentGlucoseMgDl` defaulting to `0` would make the computer treat "no data" as low glucose and bake **red** into the complication for `--` / decode-failure / first-launch-before-first-payload. Missing mg/dL ⇒ no baked glucose color.
- Stop reading `currentGlucoseColorString` and per-entry `color`.

**Watch dictionary decode — explicit migration (compile/runtime break if missed).** The current decode hard-requires both keys:
```swift
// current (WatchState.swift ~:2054–2064):
guard let glucose = data["glucose"] as? Double,
      let colorString = data["color"] as? String   // ← stops returning entries the instant P2 drops "color"
else { return nil }
```
After P2 this returns `nil` for every entry (no `"color"`), blanking the chart. Replace with a decode that drops the color requirement, reads the renamed key, and is **WC-bridging-safe** (WC delivers numbers as `NSNumber`, and dates may bridge as `Date`/`TimeInterval`/`NSNumber`). Reuse the existing `dateValue(from:)` helper (`WatchState.swift:2463`) for the timestamp and coerce mg/dL via `NSNumber` rather than a bare `as? Int`:
```swift
// new: renamed key, no color, NSNumber-safe numeric + existing date bridging
guard let date = dateValue(from: data["date"]),                 // handles Date / TimeInterval / NSNumber
      let mgDl = (data["glucoseMgDl"] as? NSNumber)?.intValue    // NSNumber-safe (Int/Double both bridge)
else { return nil }
let reading = StoredGlucoseReading(epochSeconds: Int(date.timeIntervalSince1970), glucoseMgDl: mgDl, sequence: nil, source: "wc")
```
> A bare `data["glucoseMgDl"] as? Int` / `data["date"] as? Int` is brittle — WC can deliver these as `Double`/`NSNumber`, which would fail the cast and blank the chart. Use the bridging helpers.

then W2 batch-inserts the `[StoredGlucoseReading]` and rebuilds `glucoseValues` via `loadAsDisplayValues` (which converts mg/dL → display units and computes color). **No backward-compat fallback is needed:** phone and watch ship in one atomic build (sole user, no version skew), and the key rename makes any stale *queued* old-format payload decode to empty and be ignored — safe, and masked anyway because the history store persists across the gap.

**Watch-side decode/plumbing lives in BOTH patch 09 and patch 12 — regenerate both.** Verified (Codex, in-worktree): the watch reads `data["color"]` / `currentGlucoseColorString` in patch 09 (the `glucoseValues` decode + snapshot plumbing in `processRawDataForWatchState`) **and** in patch 12 (direct-BLE usage). Both regens must drop the color reads, switch to `glucoseMgDl`, and use the bridging-safe decode. (This supersedes any earlier "watch decode is only patch 12" / "only patch 09" phrasing — it is genuinely both.)

**`TrioComplicationSnapshot.glucoseColor`** is now **populated by the watch** (baked bubble color) for all sources, so the widget keeps rendering. The field stays in the model.

---

### C1 — Runtime gate (capture lever #1)

**Problem.** `start()` (`:193–217`) sets `isStarted = true` (`:195`) behind a `guard !isStarted else { return }` (`:194`), then reaches **two** scan entries — `initiateScanForNewSensor()` (`:210`, when `boundSensorName != name`) and `sensor.resumeScanning()` (`:216`) — regardless of runtime eligibility. In the background with no confirmed `WKExtendedRuntimeSession`, the connect proceeds, the session invalidates (`reason=-1`), and the window is lost (`pre_egv_disconnect`). Largest recurring bucket (23/92).

**Two failure modes a naïve gate would create:**
1. A top-of-`start()` `guard … else { return }` after `isStarted = true` **permanently starves** the deferred scan: the flag latches, and the next foreground `start()` returns immediately at `:194` until `stop()` resets it.
2. A top-of-`start()` gate also returns before `startHeartbeatTimer()`, stopping the expected-window ticks — which W7 requires to keep counting gated windows.

There are also scan entries **outside** `start()`: `applyNewSensorName` (`:308–310`, a WC name push while backgrounded) and the disconnect-rescan (`:724`).

**Fix — single gated scan primitive.** Route every scan entry through one helper; never gate `start()` wholesale (timers/counters keep running):
```swift
private var isRuntimeEligible: Bool {
    lastKnownScenePhase == "active" || extendedSession?.state == .running
}
private var deferredScanKind: ScanKind?       // nil = none pending; .newSensor takes precedence over .resume
private var gatedSlotEpochsToday: Set<Int> = []   // W7: gated-and-not-yet-captured slots (persisted as [Int])

/// The ONLY way the adapter starts scanning/connecting. All call sites route here.
private func beginScanIfEligible(_ kind: ScanKind) {   // .resume or .newSensor
    advanceDayIfNeeded()   // roll the day FIRST — the gate runs while the expected-window timer is suspended,
                            // so it can be the first counter activity after midnight (else gated lands on the stale day).
    guard isRuntimeEligible else {
        // Preserve the *kind* across the deferral. A pending .newSensor must not be
        // downgraded to .resume by a later gated resume; .newSensor wins.
        deferredScanKind = (deferredScanKind == .newSensor || kind == .newSensor) ? .newSensor : .resume
        // Count this slot as gated ONLY when also identity-eligible — same predicate expectedSlotsToday uses.
        let identityEligible = !isStopped && expectedSensorName != nil
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let slot = Int(Date().timeIntervalSince1970); let slotEpoch = slot - (slot % 300)
        if identityEligible, slotEpoch >= startOfToday, gatedSlotEpochsToday.insert(slotEpoch).inserted {
            gatedSlotsToday = gatedSlotEpochsToday.count
            persistDailyCounters(); mirrorDailyCountersToWatchState()
        }
        log("ble_gated",
            "reason=no_runtime kind=\(kind) slot=\(slotEpoch) identity_eligible=\(identityEligible) " +
            "scene_phase=\(lastKnownScenePhase) runtime_eligible=false " +
            "ext_session_state=\(extendedSession?.state.rawValue.description ?? "nil") " +
            "last_known_ext_session_active=\(lastKnownExtSessionActive)")
        return
    }
    switch kind {
    case .resume:    sensor.resumeScanning()
    case .newSensor: performScanForNewSensor()   // the real scan body, formerly inline in initiateScanForNewSensor
    }
}
```
> **Gated means "gated and not later captured."** A slot deferred in the background can still be captured after foregrounding. If such a slot stayed in the gated count while its EGV also counted, the on-watch denominator `expected − gated` would shrink while the numerator grew — the ratio could exceed 100%. So track gated slots as a **set** and **remove a slot when an EGV is captured in it** (at the EGV-save site, `:796`):
> ```swift
> let slotEpoch = readingEpoch - (readingEpoch % 300)
> if gatedSlotEpochsToday.remove(slotEpoch) != nil {
>     gatedSlotsToday = gatedSlotEpochsToday.count
>     persistDailyCounters(); mirrorDailyCountersToWatchState()
> }
> ```
> Persist the set as `[Int]` (≤288 entries/day — cheap). `expectedSlotsToday` stays a monotonic high-water (`lastExpectedSlotEpoch`); only *gated* needs the set because only gated can be retroactively "un-gated" by a capture.
- `start()` calls `beginScanIfEligible(.newSensor)` / `.resume` instead of the raw calls at `:210`/`:216`. Leave `startHeartbeatTimer()` and the counter machinery **before** the gate so they always run.
- **`isStarted` semantics (resolved).** `start()` may set `isStarted = true` because the adapter *lifecycle* — timers and expected-window accounting — is active even while the BLE scan is deferred. Deferred scans therefore **do not** rely on a later `start()` call (which the `guard !isStarted` re-entry guard at `:194` would short-circuit anyway). They resume **only** via the explicit deferral consumers below. (This supersedes the earlier "do not latch `isStarted`" idea, which would have required splitting lifecycle-start from scan-start.)
- **Preserve each call site's original scan semantic — don't blanket-convert to `.newSensor`.** Map `sensor.resumeScanning()` → `.resume` and `initiateScanForNewSensor()` → `.newSensor`; converting a routine reconnect into `.newSensor` would needlessly clear binding / rotate session / broaden scanning. **Verified per-site mapping:** `:216` resume → `.resume`; `:210` (start, `boundSensorName != name`) → `.newSensor`; `:308–310` `applyNewSensorName` → `.newSensor`; `:724` disconnect-rescan → `.newSensor` — *verified correct*, it's the stale-sensor-reinit path (`consecutivePreEGVDisconnects >= 5 && minutesSinceEGV > 15`) that **nils `boundSensorName`** first, i.e. a genuine new-sensor scan, not a routine reconnect.
- Defer the rebind cleanly **in the routine gated-rebind case only** (`start()` finds `boundSensorName != name`, then gates): do **not** clear `boundSensorName` until eligible, so a still-valid binding isn't torn down for a scan that won't run. This does **not** apply to a C2 accepted swap — see the C1/C2 reconciliation under C2.

**Consume the deferral (the only resume paths).** In the scene-active entry (`applyForegroundActiveEntry`, where `lastKnownScenePhase = "active"`) and in `extendedRuntimeSessionDidStart`, if `deferredScanKind != nil`, capture and **clear it before** re-issuing `beginScanIfEligible(kind)` **with the stored kind** (don't default to `.resume`):
```swift
let kind = deferredScanKind
deferredScanKind = nil
if let kind { beginScanIfEligible(kind) }
// clear-BEFORE-call is intentional: if runtime is still not eligible (e.g. extendedSession
// not yet .running, or scene state not yet recorded), beginScanIfEligible re-stashes the kind.
// Do NOT refactor to clear-after-call — that risks dropping or double-issuing the deferral.
```
Do not depend on `start()` being called again.

**Gate, don't recover-harder.** No background renewal chaining or new session-acquisition path. The only deferral is background-with-no-session — precisely when a scan would fail with `reason=-1` anyway — so no legitimate foreground scan is blocked (the gate is an OR including `scene active`).

---

### C2 — Sensor identity epoch + EOS quarantine + adapter reset (capture lever #2)

**Problem.** Identity today is the sensor *name* only. After local EOS (`performEndOfSessionTeardown` `:555` nils `expectedSensorName`), the phone can re-push the **same** name, reviving the dead identity → reconnect storm (8/92).

**Identity = `name + activationEpochSeconds` (Int64).** The phone has the epoch (`AppleWatchManager.lastKnownG7SensorActivatedAtEpoch` = `G7CGMManager.state.activatedAt.timeIntervalSince1970`; cleared with `sensorID` on `scanForNewSensor()`); it is simply not sent today. **Normalize to integer seconds** — never compare raw `Double` timestamps (`1717351200.0` vs `1717351199.9999998` would read as different identities, or "newer epoch" would go fuzzy):
```swift
struct SensorIdentity: Equatable { let name: String; let activationEpochSeconds: Int64? }
```
- **Phone (patch 13 — owns the `g7_active_sensor_name` send):** add the `g7ActivationEpoch` send as **`Int64` seconds** — `Int64(activatedAt.timeIntervalSince1970.rounded())` — alongside the existing name. The `WatchMessageKeys.g7ActivationEpoch` **constant** is added in **patch 09** with the other new keys (not patch 13) — patch 12's watch reader needs it and applies before 13. (Key name stays `g7ActivationEpoch`; type/comment is now Int64 seconds.) See sequencing constraint #6.
- **Watch (`applyG7ActiveSensorNameFromWatchPayloadIfPresent`, `WatchState.swift:1751`, patch 12):** read the epoch NSNumber-safe as `Int64` (`(payload[...] as? NSNumber)?.int64Value`); form `SensorIdentity`. All comparison / storage / quarantine / "newer epoch" logic operates on the Int64 seconds. Sits *behind* the existing build-time freshness gate.

**EOS quarantine.** On local EOS, record the quarantined `(name, epoch)` **in memory** (not persisted). Reject an incoming identity equal to it; accept on (a) newer epoch, or (b) different name. An **app restart clears the quarantine** (it's in-memory) — the intended escape hatch, matching the existing "reboot clears dirty state" recovery; the EOS-revival this defends against happens within a single live session, so in-memory coverage suffices and no persisted manual-reset action is built for 205. Log `identity_quarantined` / `identity_accepted reason=…`.

**Missing-epoch fallback (rollout + edge cases).** The watch may receive a name with **no** `activationEpoch` — an old/queued payload, a phone that hasn't computed `activatedAt` yet, or a timing gap. Define it explicitly so a legitimate sensor is never quarantined and `(name, 0)` is never synthesized:
- If `activationEpoch` is **absent**, treat the identity as **legacy name-only**: do not synthesize `(name, 0)` and do not overwrite an existing epoch-bearing identity. **But it must not bypass an active quarantine:** if **any quarantined identity has the same name** — whether the quarantine is epoch-bearing *or* name-only — **ignore the missing-epoch payload** (do not accept, do not revive) until either a *newer epoch* for that name or a *different name* arrives (or a restart clears the in-memory quarantine). Only a name with no same-name quarantine is accepted on the legacy path. Log `identity_epoch_missing` and, when blocked, `identity_quarantined reason=missing_epoch_same_name`.
  > Rationale: after an epoch-bearing EOS quarantine of `(name=X, epoch=1000)`, a same-name payload with no epoch would otherwise slip through (it doesn't "exactly match" the epoch-bearing record) and revive the dead sensor. Same-name match on *either* quarantine form closes that hole. Since the 205 phone always sends the epoch (patch 13), a missing epoch is only a transient/queued artifact, so the cost of ignoring it is nil.
- Once an epoch-bearing `(name, epoch)` arrives for that name, **promote** the identity to the epoch-bearing form and apply quarantine logic from then on.

**Upgrade migration.** Existing installs have a bound `sensorName` (via W13) but no stored epoch. After upgrade, keep using the bound name (legacy path) until the first epoch-bearing payload arrives, then promote. This prevents a forced re-scan or spurious quarantine on the first launch of the new build.

**Adapter state & API (where everything lives — so `WatchState` and the adapter don't re-derive it inconsistently).**
- **Bound identity** lives on `G7WatchSensorAdapter`: `boundSensorName` (already persisted, `G7WatchAdapter.sensorName`) **plus** a new persisted `G7WatchAdapter.activationEpochSeconds` (`Int64`, absent until the first epoch-bearing payload — legacy path). Persisting the epoch lets the bound identity survive restart so a post-restart swap is still detectable.
- **Quarantine** lives on the adapter, **in memory only**: `private var quarantine: SensorIdentity?` (or a small `Set<SensorIdentity>` if more than one is ever needed; one is sufficient for 205). Not persisted — an app restart clears it (the documented escape hatch).
- **API.** `WatchState.applyG7ActiveSensorNameFromWatchPayloadIfPresent` (`:1751`) reads `name` + `Int64` epoch, forms `SensorIdentity`, and calls a new **`adapter.setActiveSensorIdentity(_:)`** (replacing the bare `setActiveSensorName(name)` at `:1779`). `setActiveSensorIdentity` runs the accept/quarantine decision and the swap teardown below. Keep a thin `setActiveSensorName` shim that forwards `SensorIdentity(name:, activationEpochSeconds: nil)` only if some caller still needs the name-only entry point.
- **EOS → quarantine flow.** `performEndOfSessionTeardown` (`:555`) must **record the current bound `SensorIdentity` into `quarantine` *before*** it nils `expectedSensorName`. Order matters: if it nils first, the identity to quarantine is already gone. After recording, the existing teardown proceeds.

**Full adapter reset on accepted swap** (`applyNewSensorName` `:282` preserves state today):
- `adapterSessionID` → new (`:653` already mints on discovery; ensure it fires on swap).
- peripheral ref / `boundSensorName` → cleared (fresh scan).
- configured-state → cleared (pairs with C3 `needsConfiguration`).
- expected-window state → re-anchored (`hasAnchored = false`; reset `bleFirstSequenceToday`; **`expectedSlotsToday`/`gatedSlotsToday` (W7) NOT reset** — they accumulate across both sensors on a swap day).

**C1/C2 reconciliation on `boundSensorName` (background swap).** C1's "don't clear `boundSensorName` while gated" and C2's "accepted swap clears `boundSensorName`" must not both be live. Resolve by event type:
- **Accepted swap (C2)** — the old binding is *definitively dead* (new physical sensor), so there is no valid binding to strand. Immediately: persist the new identity + quarantine decision, clear `boundSensorName` + peripheral ref + configured-state, then call `beginScanIfEligible(.newSensor)`. If gated, that sets `deferredScanKind = .newSensor` and the rescan replays when runtime returns. So the *state teardown* is immediate; only the *scan* is deferred (and carries the `.newSensor` kind).
- **Routine gated rebind (C1)** — `start()` sees `boundSensorName != name` for the *same* logical sensor (no swap accepted): defer the clear until eligible, per C1.
The discriminator is whether C2 just accepted a swap (new `name`/epoch passing quarantine). Track it with a `pendingSensorSwap` flag set by the C2 accept path so `start()`/`beginScanIfEligible` know to tear down immediately rather than preserve.

> **`pendingSensorSwap` lifecycle (required — a set-once-never-cleared flag is a bug).** Set it `true` in `setActiveSensorIdentity`'s accept-swap branch, and **clear it to `false` in the same accept branch immediately after the inline teardown + `beginScanIfEligible(.newSensor)` call** (the teardown is synchronous, so the flag only needs to live across that call). Do **not** leave it set: a lingering `true` would make the next *routine* `start()` (`boundSensorName != name` for the same sensor) misclassify as a swap and tear down a valid binding. Note it is largely belt-and-suspenders: because the accept path clears `boundSensorName` **inline**, by the time any later `start()` runs the binding is already nil and the deferred scan already carries `.newSensor` via `deferredScanKind`; `pendingSensorSwap` exists only to cover a `start()` that races *between* accept-teardown and the deferred scan consuming. If implementation shows no such race, the flag may be dropped entirely — but if kept, it MUST be cleared as above.
> **C1 deferred-clear execution point (routine rebind).** For the routine gated-rebind case, the deferred `boundSensorName` clear happens inside `performScanForNewSensor()` (the real new-sensor scan body) when the deferral is finally consumed and runs — *not* in `beginScanIfEligible`'s gate. Confirm `performScanForNewSensor` (extracted from `initiateScanForNewSensor`) clears the binding as its first step, so a deferred `.newSensor` resolves the stale binding exactly when the scan actually proceeds.

**W7 interaction:** reset the *sequence* anchor (`bleFirstSequenceToday`); keep the *slot* accumulators and their slot-epoch guards.

---

### C3 — `configureAndRun` fail-closed (capture lever #3, G7SensorKit fork)

**Problem.** `G7PeripheralManager.configureAndRun` (`:130`): the `catch` on failed configuration logs `configuration_failed` with `// Will retry` (`:147–151`) then **falls through to `block(self)`** (`:155`) — running auth/control/backfill against a peripheral whose characteristics were never discovered → no EGV (config churn, 14/92; 96 failures overnight).

**Fix — fail closed.** Two helper details:

- **`emitG7Telemetry` already has the right shape — no fork-helper change.** Verified against the live `G7Telemetry.swift`: `emitG7Telemetry(_ event: String, _ fields: String = "")` already exists and builds a `G7TelemetryPayload(event:fields:)` for the payload-based `G7Telemetry.emit` (patch12:38 wiring). C3 simply **calls** it — there is no signature change and nothing new to ship in the fork commit beyond the fail-closed logic. (The earlier "single-arg `String`" reading was from a stale `/mnt/project` mirror; the live fork is 2-arg payload.)
- **`scheduleConfigurationRetry(rerunning:)` does not exist yet** — define it. It must **re-run the captured operation block** after a successful re-configuration, not merely re-configure. `configureAndRun(_ block:)` (`:130`) is the only thing that runs `block`; on a fail-closed return the `block` (e.g. the initial auth subscription, `G7Sensor.swift:213`) is dropped, and there is no guaranteed later `perform` to re-issue it. So the retry captures `block` and re-enters via `perform(block)`.

```swift
} catch let error {
    emitG7Telemetry("configure_block_skipped", "error=\(String(describing: error))")
    self.log.error("Peripheral configuration failed; skipping operation block: %{public}@", String(describing: error))
    self.needsConfiguration = true                  // set explicitly — don't rely on it "staying" true
    self.scheduleConfigurationRetry(rerunning: block)   // capture block; re-run it after config succeeds
    return                                                // fail closed — do NOT run block now
}
block(self)
```
`scheduleConfigurationRetry(rerunning: block)` waits a capped, exponentially-backed-off interval, then calls `self.perform(block)`. Because `needsConfiguration` is `true`, that re-enters configuration; on success the **same `block` runs once**, on failure it returns and (within caps) schedules again. No connect-timeout or `scanAfterDelay` change (build 204 north star). (No telemetry-helper change ships — `emitG7Telemetry(_:_:)` already exists; see above.)

```swift
private func scheduleConfigurationRetry(rerunning block: @escaping (G7PeripheralManager) -> Void) {
    queue.async {
        // FIRST-WINS: never replace an already-pending retry with a *different* failed block.
        // Without closure identity we cannot tell "same op re-failure" from "different op",
        // so replacing would silently drop the first (dominant) skipped op — the auth subscription.
        guard self.configurationRetryWorkItem == nil else {
            self.emitG7Telemetry("configure_retry_already_pending")
            return
        }
        self.needsConfiguration = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.configurationRetryWorkItem = nil          // clear BEFORE re-entering perform
                guard self.peripheral?.state == .connected else {
                    self.emitG7Telemetry("configure_retry_abandoned", "reason=disconnected")
                    return
                }
                self.perform(block)                            // a re-failure schedules the next attempt
            }
        }
        self.configurationRetryWorkItem = work
        self.queue.asyncAfter(deadline: .now() + self.nextBackoff(), execute: work)
    }
}
```

**Retry contract (to avoid a ghost retry loop and a dropped operation):**
- **Re-runs the operation.** The pending block is captured and re-executed via `perform(block)` after the backoff — the skipped operation is not lost.
- **First-wins, never replace.** If a retry is already pending, a *new* failed operation does **not** replace it: log `configure_retry_already_pending` and keep the first pending block. The dominant skipped op is the initial auth subscription, which must survive; a later op (backfill/control) will re-run naturally once config is fixed. The retry clears `configurationRetryWorkItem` immediately before re-entering `perform(block)`, so a re-failure *from that retry* can schedule the next attempt. (This replaces the earlier "single `DispatchWorkItem?`, replace on re-failure" wording, which could drop auth.)
- **Queue & closure.** Schedule on the same `G7PeripheralManager` serial `queue` used by `perform`. `configureAndRun`/`perform` already take `@escaping (_ manager:) -> Void` (verified `:130`/`:159`); the scheduled `DispatchWorkItem` captures `[weak self]`.
- **Preconditions.** Do not re-run if the peripheral is disconnected/deallocated (`peripheral?.state == .connected` guard; else log `configure_retry_abandoned`).
- **Cancellation (real hooks — there is no `stop()`).** Cancel the pending work item **only** on: (a) peripheral reset/disconnect — the `peripheral` `didSet` that sets `needsConfiguration = true` (`:40`, `:67`); (b) dealloc. **Do not cancel on a "superseding `perform`" or another `perform` succeeding configuration** — those run a *different* block, not the skipped auth subscription, so cancelling would drop auth and kill the EGV path.
- **Cap (NOT shown in the sample above — must be added).** The `scheduleConfigurationRetry` snippet omits the counter for brevity. Implement: a `configurationRetryAttempts` counter incremented per scheduled attempt; bound both the per-attempt backoff ceiling (`nextBackoff()` — define it, e.g. `min(maxBackoff, base * 2^attempts)`) and the total attempt count; on exhaustion, stop and wait for the next natural connect/`perform`. **Reset the counter to 0 when configuration ultimately succeeds** (the `block` runs) — otherwise a later, unrelated config failure inherits an exhausted budget and never retries. `nextBackoff()` is referenced in the sample but not defined there; define it alongside the counter.

**Delivery:** fork `main` commit → push → repin `patches/02-g7-reading-time-with-seconds.patch` SHA. Shared with iPhone — fail-closed is correct on both; validate iPhone explicitly.

---

## Dependency order

```
W5 (color computer)  → before W1 (history loadAsDisplayValues uses chartColor)
W1 (history store)   → before W2 (chart population uses it)
W1 + W2              → before P1 (reduce WC window only once watch has local history)
W5 + P2              → ship together (don't strip colors / change units before the watch can compute)
W3, W4               → independent
W7, W8, W13          → adapter-local; W13 (key migration) lands with W7
C1                   → adapter-local; routes through beginScanIfEligible; depends on W7 counters
C2                   → depends on W7 slot semantics (keep slot accumulators on swap); phone epoch (patch 13) + watch consume (patch 12) land together
C3                   → G7SensorKit fork; fork push + patch 02 repin
```

**One build.** 205 ships as a single build (considered and rejected a 205A/B/C split: sole TestFlight user, and each fix carries a distinct proximal signal, so a split mainly costs a second deep patch-09 reach). The W/P (display/persistence/units/color) and C1–C3 (capture) work are orthogonal; attribution stays clean within one build via distinct signals:
- **C1** → `ble_gated reason=no_runtime` appears; background `pre_egv_disconnect` drops; `gatedSlotsToday` rises.
- **C2** → `identity_quarantined` / `identity_accepted`; post-EOS storms disappear; `adapterSessionID` rotates once per real swap.
- **C3** → `configure_block_skipped` replaces `configuration_failed`→no-EGV.

**Per-path instrumentation labels (insurance for the single build).** Because the W/P paths don't all have a natural distinct signal, tag the new/changed paths with explicit `build205_*` events so post-build BetterStack analysis can attribute movement to a specific change rather than the build as a whole:
- `build205_w_history_insert` (W1 merge: source, dedup hit/miss, batch size)
- `build205_w_wc_decode_mgdl` (P2 watch decode: confirms mg/dL units + the four settings applied)
- `build205_c1_ble_gated` (alias of `ble_gated`, kept for symmetry)
- `build205_c2_identity_decision` (accepted / quarantined / epoch_missing + both epochs)
- `build205_c3_configure_block_skipped` (alias of `configure_block_skipped`)

---

## Delivery / patch mapping

Source edits go on the feature branch in the `Trio` worktree, then land via `./scripts/mid-stack-update.sh --patch <NN> --cherry-pick <sha>` from `Trio-dev` on `dev`, validated with `./scripts/patch-test.sh`. Per `AGENTS.md`, patches stay uncommitted until you ask.

**Watch extension → patch 12 (`12-direct-ble-observer.patch`); phone WC payload *mapping* → patch 09 (`09-watch-complication-improvements.patch`).** Verified: patch 12 has 0 hits on `AppleWatchManager`; patch 09 owns the value mapping and `watchStateToDictionary`. Patch 09 does **not** own the glucose *fetch* — `fetchGlucose()` (`AppleWatchManager.swift:516–523`) and `GlucoseStored+helper.swift` are **upstream**, so P1 is a new hunk extending patch 09 into upstream regions.

| Fix | Patch(es) | Files / notes |
|-----|-----------|---------------|
| W1 history store | **12** | New `WatchGlucoseHistoryStore.swift` |
| W2 chart population | **12** | `WatchState.swift`, `G7WatchSensorAdapter.swift`, `TrioMainWatchView.swift` |
| W3 IOB/COB persistence | **12** | `WatchState.swift` |
| W4 display gate | **12** | `TrioMainWatchView.swift` |
| W5 color computer | **09** + **12** + **dev** | New shared `GlucoseHueColor.swift` (Foundation-only `glucoseHueComponents`) + **`DynamicGlucoseColor.swift` refactored to call it** (no symbol move/delete) + new `WatchMessageKeys` → **09**; `WatchGlucoseColorComputer.swift` (watch) → **12**; `sync_project_files_config.rb` watch-target entry → **direct `dev` commit**, before the build |
| W7 expected/gated slots | **12** | `G7WatchSensorAdapter.swift`, `WatchState.swift`, `ComplicationDebugView.swift` |
| W8 debug rows | **12** | `ComplicationDebugView.swift` |
| W9 `log()` task | **12** | `G7WatchSensorAdapter.swift` |
| W10 confirm coalesce | **12** | `ComplicationDebugView.swift` |
| W11 timeout nil | **12** | `WatchState.swift` |
| W12 rename | **12** | `TrioMainWatchView.swift` |
| W13 key migration | **12** | `G7WatchSensorAdapter.swift` (+ one-time `sensorName` migration) |
| P1 WC payload size | **09** (upstream regions) | `AppleWatchManager.swift` `fetchGlucose()` + new `glucoseForTwoHoursAgo` in `GlucoseStored+helper.swift` |
| P2 canonical mg/dL + strip colors | **09** + **12** | Phone populate + shared models `Trio/Sources/Models/WatchGlucoseObject.swift` (drop `color`) and `…/WatchState.swift` (drop `.color` from `==`/`hash`) in 09; watch dictionary decode (drop color, read `glucoseMgDl`, bridging-safe) appears in **both 09 and 12** — regenerate both |
| C1 runtime gate | **12** | `G7WatchSensorAdapter.swift` |
| C2 identity epoch + reset | **12** + **13** | Adapter + `WatchState` in 12; phone `g7ActivationEpoch` in **13** |
| C3 fail-closed | **fork + 02** | Fork `main` commit → push → repin `patches/02-…` |

**Key sequencing constraints:**

1. **New `WatchMessageKeys` constants added in patch 09** (applied before 12) so phone (09), watch (12), and the epoch send (13) all reference them. Don't add in 12 — 09 would fail to compile.
2. **Do not delete `currentGlucoseColorString`** (upstream). Stop populating (09) and reading (09 + 12); remove its allowlist entry (09).
3. **`GlucoseStored+helper.swift` touched by no patch today** — `glucoseForTwoHoursAgo` is a new hunk inside patch 09. No new patch number.
4. **P1 + W1 atomicity.** P1 (patch 09) must not land without W1 (patch 12). They live in different patches, so the 09 regen and the 12 regen must land in the **same build**.
5. **Patch 09 is a deeper mid-stack edit than 204** (which touched 02 + 12 only). Replays 10–14 on top; `patch-test.sh` after the 09 regen and before 12.
6. **C2 phone epoch goes in patch 13**, not 09 (the `g7_active_sensor_name` send lives there; doc comment `WatchState.swift:1737`). Constant in `WatchMessageKeys` via patch 09 is safe for all later consumers.
7. **C3 forces a second fork commit + patch 02 repin.** Push the fork first, then `mid-stack-update` patch 02.

**Widest-reach summary:** 205 regenerates patches **02 (C3), 09 (P1/P2/keys), 12 (all W + C1/C2-watch), 13 (C2 epoch)** + one fork commit, **plus a direct `dev` commit to `sync_project_files_config.rb`** (W5 watch-target membership for `GlucoseHueColor.swift`), landed before the build. Sequence bottom-up (sync-config commit → 02 → 09 → 12 → 13), `patch-test.sh` between each patch.

**Grep-based pre-validation (run after each patch regen, before `patch-test.sh`).** This build has heavy cross-patch rename/removal risk (color stripped in two patches, `glucose`→`glucoseMgDl`, symbol move, epoch key, Info.plist). Greps catch leftovers and accidental drops faster than eyeballing the diff:
```bash
# USES of the old color must be gone (the property/key DECLARATION stays defined — a declaration-only hit is fine):
grep -Rn 'data\["color"\]' "Trio Watch App Extension" Trio/Sources
grep -Rn 'WatchMessageKeys\.currentGlucoseColorString.*=' Trio "Trio Watch App Extension"      # population via dict[key] = …
grep -Rn 'currentGlucoseColorString.*\(toColor\|Color\)' Trio "Trio Watch App Extension"        # reads into a Color
# INSPECT (not zero-hit): old chart decode must read glucoseMgDl, not data["glucose"].
grep -Rn 'data\["glucose"\]' "Trio Watch App Extension" Trio/Sources    # any hit here = stale decode → fix to glucoseMgDl
grep -Rn '"glucose"' "Trio Watch App Extension" Trio/Sources            # manual scan; legitimate currentGlucose string hits exist
# Must be PRESENT on both sides of the wire (renamed key, epoch):
grep -Rn 'glucoseMgDl' "Trio Watch App Extension" Trio/Sources
grep -Rn 'g7ActivationEpoch' "Trio Watch App Extension" Trio/Sources
# Symbol move/refactor sanity: components extracted once; wrapper still single-definition in DynamicGlucoseColor.swift.
grep -Rn 'func glucoseHueComponents' Trio              # expect 1 (GlucoseHueColor.swift)
grep -Rn 'func calculateHueBasedGlucoseColor' Trio     # expect 1 (DynamicGlucoseColor.swift) — NOT duplicated
# Background modes must survive the patch-12 regen (204 lesson):
grep -n 'WKBackgroundModes\|physical-therapy' "Trio Watch App/Info.plist"
```
Treat any unexpected hit/miss as a regen defect before running the full patch test.

---

## What does NOT change

- `TrioComplicationDataStore.shouldUpdate` ±1s window: correct as-is (`timeDiff = 1.0` is not `> 1.0`). Add a comment documenting the observed 1s BLE-vs-WC delta.
- `WKExtendedRuntimeSession` chaining: unchanged. C1 adds a read-only runtime *gate*, not a session-acquisition path.
- **No blind-reissue reconnect watchdog.** The "alive, no successful connect" bucket (24/92) already has a connect pending; a watchdog would stack duplicate connects. Out of scope.
- `G7DirectBLEStatus` dead cases: document, don't wire/remove.
- `GlucoseChartView`: unchanged signature `[(date, glucose, color)]`; `glucose` is display units, `color` now computed locally.
- **`TrioComplicationDataStore` rename → `TrioWatchDataStore`: deferred** to the `watch-messaging-centralization` plan (pure cross-extension rename; zero functional benefit in 205; would inflate blast radius and muddy attribution).

---

## Validation plan

### Startup behavior (W1–W4)
1. Run ≥ 30 min; force-quit; reopen.
2. Glucose bubble shows the last reading immediately (not `--`); IOB/COB show cached values **only if < 30 min old** (else `--`); chart populated from the history store.
   - **Expected asymmetry:** the glucose bubble/trend restore from the `TrioComplicationDataStore` snapshot, but IOB/COB restore only from the 30-min UserDefaults cache (W3). So **IOB/COB may show `--` on a cold open even when glucose is visible from the snapshot** — this is intentional, not a bug.
3. Verify startup **display state** directly (startup restores from snapshot/history; it does not necessarily emit a `saveOnMain`):
   - snapshot restored from `TrioComplicationDataStore` (current glucose/trend/delta non-`--` when the snapshot is fresh enough);
   - `WatchGlucoseHistoryStore` chart count > 0;
   - no display fallback to `--` caused *solely* by WC being unreachable (W4).
4. **Post-upgrade recovery expectation:** on the first launch after the 205 upgrade the history store is empty; the first WC delivery seeds only **~2 h** (24 readings, P1), not 24 h. The full 24 h backfills gradually as new BLE/HK/WC readings arrive over the following day. A reviewer should **not** expect instant 24 h chart restoration.

### WC payload size + units (P1/P2)
- `watch_wc_inbound`: `glucoseValues_count` ≤ 24 (was ≤ 288).
- Set the phone to **mmol/L**; confirm stored history is mg/dL (e.g. ~100, not ~5.5) and the chart/bubble render correct mmol/L values and colors.

### Color parity (W5 + P2)
- Compare bubble + chart colors to iPhone at low (< 70), in-range (~130), target (~100), high (> 180), under **both** static and dynamic schemes. Confirm bubble is **white in range**, colored out of range; chart points always colored.
- Confirm `currentGlucoseColorString` absent from watch-side inbound WC lines.
- **Settings-cache works across restart:** set **non-default** thresholds + the **dynamic** scheme on the phone; after the first 205 WC payload applies them, force-quit and reopen the watch app; confirm chart/bubble colors still match (computed from cached `UserDefaults.standard` settings) **before** any new WC payload arrives. Also confirm a `nil`/`--` current glucose bakes **no** color (snapshot `glucoseColor == nil`), not red.
- **Static hex parity:** on a pre-205 build, capture the phone-sent `currentGlucoseColorString` hex for each static band (`.orange`/`.red`/`.green`) and white-in-range; confirm the 205 watch-baked `snapshot.glucoseColor` is byte-identical for the same mg/dL. Any mismatch means the hardcoded static-hex constants don't match the phone's `toHexString()` and must be corrected.
- **Dynamic hex parity (explicit, not just visual):** on a pre-205 build under the **dynamic** scheme, capture `currentGlucoseColorString` at representative mg/dL — **55, 70, 100, 130, 180, 220** — and confirm the 205 `bubbleColorHex`/`chartColorHex` produce **byte-identical** hex for the same inputs (except the white-in-range bubble rule). **`toHexString` uses `Int(x*255)` truncation, NOT rounding** (verified `GlucoseColorScheme.swift:32`), so the watch's `hexFromHSB` must match it with `let r = Int(rgb.r * 255)` (truncate toward zero), **not** `.rounded()` — using `.rounded()` would drift a byte at any component whose scaled value lands just below an integer. Apply the same explicit truncation to all three channels; do not leave the conversion implicit. **Case:** `toHexString` uses `%02X` (**uppercase**), so `hexFromHSB` must format uppercase too (or normalize case before comparing) — a string-level byte-parity check would false-fail on `#5be55b` vs `#5BE55B` even though the rendered color is identical. (`Color(hex:)`/`toColor()` parsing is case-insensitive, so rendering is unaffected either way; only the parity *test* and the snapshot string are case-sensitive. Note the white constant is lowercase `#ffffff`, matching the phone's hardcoded lowercase at `AppleWatchManager:409`.)

### Denominator (W7)
- After midnight: `expectedSlotsToday` starts at 0 and increments each cycle; gated slots accumulate in `gatedSlotEpochsToday`; debug row shows `N / (expected − gated)`.
- **Hard invariant: the debug ratio must never exceed 100%** (except a one-time legacy pre-205 reset artifact). If it does, a gated-then-captured slot wasn't removed from `gatedSlotEpochsToday` — check the EGV-save removal hook.
- **Gated-then-captured:** gate a slot in background (`ble_gated`), then foreground so the deferred scan runs and an EGV lands in that same 5-min slot; confirm `gatedSlotsToday` **decrements** (slot removed from the set) and the ratio stays ≤ 100%.
- Sensor-swap day: denominator accumulates across both sensors (no reset at swap).
- After an **ordinary restart within 205**: counters and the slot high-water + gated set restore from UserDefaults.
- On the **pre-205 → 205 upgrade only**: renamed daily-counter keys read as absent → counters reset **once** to 0 (only `sensorName` migrates, per W13). Expected — don't read the post-upgrade zero as a failure.
- After failure + recovery: retroactive ticks increment for missed windows without zeroing today's counter across midnight.

### Key migration (W13)
- After restart: debug rows show the denominator immediately (W7 counters restored from UserDefaults).
- After upgrade: bound `sensorName` survives (no forced re-scan) via the one-time migration; new keys read under `G7WatchAdapter.*`.

### Capture pipeline (C1–C3) — bucket reduction, not absolute %
- **C1.** `ble_gated reason=no_runtime` in background; background `pre_egv_disconnect` drops vs the 23-window baseline; foregrounding runs the deferred scan (no permanent starvation); `applyNewSensorName`/disconnect rescans in the background are also gated.
- **C2.** Force swap / EOS + re-push: `identity_quarantined` blocks the stale pair; `identity_accepted` only on newer epoch/name; `adapterSessionID` rotates once; no storm; `expectedSlotsToday`/`gatedSlotsToday` do not reset at swap while `bleFirstSequenceToday` does. **Epoch normalization cases:** same name + same epoch-seconds → same identity; same name + epoch + sub-second serialization noise → **same** normalized identity (Int64 seconds); same name + newer epoch-seconds → accepted; same name + older epoch-seconds → rejected/quarantined; same name + **missing** epoch while a same-name quarantine is active → ignored.
- **C3.** Overnight, no swap: `configure_block_skipped` replaces `configuration_failed`→no-EGV; verify on **both** platforms. **Two-failed-ops case (the dangerous hole):** force a config failure so the auth retry is pending, then drive a *second* operation that also hits config before the retry fires — confirm the log shows `configure_retry_already_pending`, the auth retry is **not** replaced, and an EGV still appears once config recovers (auth wasn't dropped).
- **Aggregate (n=1, directional):** target recovering ~43 addressable windows, ~54% → ~81% non-battery capture. Needs replication.

---

## Risks / notes

- **Color parity** is de-risked by extracting the pure HSB math (`glucoseHueComponents`, Foundation-only) into a watch-safe shared file (`GlucoseHueColor.swift`) and **refactoring the phone's `calculateHueBasedGlucoseColor` in place** to call it — no symbol move, so no duplicate-symbol risk. Sharing the whole `DynamicGlucoseColor.swift` is **not** viable (it references `GlucoseColorScheme` → UIKit). The watch does the static branch locally, computes the dynamic branch via `glucoseHueComponents` + a watch-local `hexFromHSB`, and never references `GlucoseColorScheme`/`getDynamicGlucoseColor`/`calculateHueBasedGlucoseColor`. Static hex uses hardcoded constants matching the phone's `toHexString()`; dynamic hex is byte-parity-validated. The `55/220` dynamic bounds and the white-in-range bubble rule must match `AppleWatchManager.swift:388–410` exactly.
- **Units regression surface.** P2 changes the on-wire unit for chart values. Any consumer still assuming display units will break; the history-store `units_suspicious` logged canary (`mgdl < 25`, excluding sentinel 0) is the tripwire.
- **History store first write.** Empty on first launch post-upgrade; chart blank until the first WC delivery or HK fire. Same as today — no regression.
- **Retroactive slot catch-up timing.** `expectedSlotsToday` catches up only when `start()` runs (foreground). If the user never opens the app after an overnight failure, the denominator is understated until they do; the `Since EGV:` row already shows the outage. Midnight is handled forward-only: `advanceDayIfNeeded()` rolls the day on real wall-clock and the increment guard counts only slots `>= startOfToday`, so pre-midnight replays are skipped rather than attributed backward.
- **P1 safe deployment gating.** Do not land P1 (`fetchLimit: 24`, patch 09) without W1 (patch 12) in the **same build**.
- **C1 over-gating.** Predicate is an OR (`scene active` **or** `.running`); a scene-phase / `didStart` transition must consume `deferredScanKind`. Watch `ble_gated` followed by a successful EGV to confirm deferred scans actually run.
- **C2 quarantine lockout.** A bad epoch comparison could quarantine a legitimate sensor. Mitigations: accept on name change OR newer epoch; log both epochs on every decision. The quarantine is held **in memory only** (not persisted) — an app restart clears it, which is the existing "reboot clears dirty state" recovery and is the intended escape hatch (the EOS-revival it defends against occurs within a live session, so in-memory coverage is sufficient). A manual debug "clear quarantine" action is **deferred** (not in 205 scope); restart suffices.
- **C3 shared-fork blast radius.** `configureAndRun` is shared with iPhone CGM; validate iPhone explicitly; bound the retry backoff.
- **n=1 evidence.** Capture buckets from a single device over ~15 h. Ship C1–C3 as instrumented improvements and confirm bucket reduction on the same device before generalizing.

---

## Implementation log (build 205)

Chronological record of execution on `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree). Each slice is a feature-branch commit; patches are regenerated later (one build). Deviations from the plan above are recorded here as the authority.

### 2026-06-06 — W5 (color foundation) — source committed

**Files (feature branch):**
- NEW `Trio/Sources/Helpers/GlucoseHueColor.swift` — Foundation-only `GlucoseHueComponents` + `glucoseHueComponents(_:high:low:target:)` (hue math, saturation 0.6, brightness 0.9). Uses `Double` (not `CGFloat`) to stay CoreGraphics-free for the watch target.
- EDIT `Trio/Sources/Helpers/DynamicGlucoseColor.swift` — `calculateHueBasedGlucoseColor` refactored in place to call the shared `glucoseHueComponents` and wrap in `Color` (no symbol move; single definition preserved).
- NEW `Trio Watch App Extension/WatchGlucoseColorComputer.swift` — the computer: captured static hex constants, `hexFromHSB` (uppercase `%02X`, `Int(x*255)` truncation), `chartColorHex`/`bubbleColorHex` (+ `Color` accessors via the existing `String.toColor()`), `apply`/`load`, and `displayValue(forMgDl:)`.
- EDIT `Trio/Sources/Models/WatchMessageKeys.swift` — added the five W5/P2 keys (`lowGlucoseThreshold`, `highGlucoseThreshold`, `glucoseTarget`, `glucoseColorSchemeDynamic`, `currentGlucoseMgDl`) + `g7ActivationEpoch` (C2). (Patch-09 ownership; landed on the feature branch with the rest.)
- EDIT `scripts/sync_project_files_config.rb` — added `Trio/Sources/Helpers/GlucoseHueColor.swift` to the **Trio Watch App** target globs (phone gets it via `Trio/Sources/**`).

**Deviation 1 (resolved) — `GlucoseUnits`/`asMmolL` are NOT in the watch target.** The plan's `cachedUnits: GlucoseUnits` and `loadAsDisplayValues` using `Decimal(mgDl).asMmolL` would not compile on the watch: both live in `Trio/Sources/Models/BloodGlucose.swift`, which the watch sync globs do **not** include (only `Trio Watch App Extension/**`, `NotificationIdentifiers.swift`, `WatchMessageKeys.swift`, shared complication files). **Resolution:** keep units watch-local — store the wire string (`cachedUnitsRaw`, "mg/dL"/"mmol/L") and replicate the phone's conversion exactly in `displayValue(forMgDl:)` (`× 0.0555` exchange rate, `NSDecimalRound` scale 1 `.plain`). This preserves value parity with the phone's `Int.asMmolL` without dragging `BloodGlucose.swift` (+ its JSON/other deps) into the watch target. **Plan impact:** W1's `loadAsDisplayValues` should call `WatchGlucoseColorComputer.shared.displayValue(forMgDl:)` rather than `asMmolL`, and `cachedUnits: GlucoseUnits` becomes `cachedUnitsRaw: String` / `isMmolL: Bool`.

**Verification done at write time:** `hsbToRGB` + `Int(x*255)` truncation hand-traced against all six captured dynamic golden hexes (55→#E55B5B, 70→#E5B75B, 100→#5BE55B, 130→#5BE5B1, 180→#5B89E5, 220→#A05BE5) — exact match. Static constants are the iOS-26.5 captured values. Not yet compiler-verified (build deferred per "one build").

**Status:** ✅ committed `a29643c6c` ("build205(W5): local watch glucose color computation"). Pending later patch 09/12 regen (the `GlucoseHueColor.swift` watch registration in `sync_project_files_config.rb` lands as a direct `dev` commit before the build, per the plan). Not yet compiler-verified.

### 2026-06-06 — W1 (`WatchGlucoseHistoryStore`) — source committed

**File:** NEW `Trio Watch App Extension/WatchGlucoseHistoryStore.swift`.
- `struct StoredGlucoseReading: Codable` (epochSeconds, glucoseMgDl, sequence?, source) + the **single P2 decode path** `StoredGlucoseReading.from(wcEntry:source:)` (NSNumber-safe `glucoseMgDl`, `Date`/`TimeInterval`/`NSNumber` date bridging). W2's WC merge will `compactMap` through this.
- `@MainActor final class WatchGlucoseHistoryStore` (serialization invariant) → `Documents/glucose_history.json`. Merge = ±1s window + "either sequence nil" rule; source priority `ble=3 > wc=2 > hk=1`; `pruneAndCap` (drop >24h, sort ascending, hard `suffix(288)`); single `insert(_:)` (BLE/HK) and batch `insert(_:[ ])` (WC, one write).
- `loadAsDisplayValues(colorComputer:)` → `[(date, glucose, color)]` (the `WatchState.glucoseValues`/`GlucoseChartView` tuple, verified).
- Telemetry via `WatchLogger.shared.log` (async): `build205_w_history_insert` (source/batch/appended/deduped/total) + the `units_suspicious` canary (`mgdl != 0 && < 25`).

**Deviation 2 (follows W5 deviation 1) — `loadAsDisplayValues` signature.** Dropped the plan's `units:` parameter; units now live on the color computer (`displayValue(forMgDl:)`), so the store takes only `colorComputer:`. W2's call sites change accordingly.
**Deviation 3 (minor) — date bridging duplicated, not reused.** The plan said "reuse `WatchState.dateValue(from:)`," but that's a `private` instance method; to keep `StoredGlucoseReading` free of WatchState coupling, the same Foundation-only bridging is a `static` on `StoredGlucoseReading` (`bridgedDate(from:)`). Behaviour identical.

**Status:** ✅ committed `f9d17d1e1` ("build205(W1): WatchGlucoseHistoryStore"). Not yet compiler-verified.

### 2026-06-06 — P2 (phone-side send) — source committed

**Files (feature branch):**
- EDIT `Trio/Sources/Models/WatchGlucoseObject.swift` — dropped `color`; `glucose` is now canonical mg/dL.
- EDIT `Trio/Sources/Models/WatchState.swift` (phone DTO) — added `currentGlucoseMgDl: Int?`; dropped `.color` from `==`/`hash` (the compile-blocker) and added `currentGlucoseMgDl` to both; kept `currentGlucoseColorString` field (upstream, unused now).
- EDIT `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`:
  - removed the phone-side bubble/chart color computation (`getDynamicGlucoseColor`/`toHexString`); set `watchState.currentGlucoseMgDl = Int(latestGlucose.glucose)`; chart map now emits `WatchGlucoseObject(date:, glucose: mg/dL)` with no color/unit-conversion.
  - `watchStateToDictionary`: removed `currentGlucoseColorString`; chart entry key `"glucose"`/`"color"` → **`"glucoseMgDl"`** (Int, no color); added the four color settings (`Int` mg/dL via `NSDecimalNumber(decimal:).intValue`, dynamic Bool) + `currentGlucoseMgDl`. `units` already sent as `state.units.rawValue` (the wire string the watch caches).
  - complication allowlist: replaced `currentGlucoseColorString` with `currentGlucoseMgDl` (background path bakes the snapshot color from it + cached settings).

**Verified:** no remaining phone-side readers of `WatchGlucoseObject.color` or `currentGlucoseColorString` (grep clean; the field/key/one comment remain by design).

**Status:** ✅ committed `c0f24e88f` ("build205(P2 phone): send canonical mg/dL + color settings, drop colors"). Watch-side *receive* half is the next unit. Not yet compiler-verified.

### 2026-06-06 — W2 + P2 (watch-side receive) + W1 store refactor — source committed

**Files (feature branch):** `Trio Watch App Extension/WatchGlucoseHistoryStore.swift`, `…/WatchState.swift`, `…/G7WatchSensorAdapter.swift`, `…/Views/TrioMainWatchView.swift`.

- **WC decode (`processRawDataForWatchState`):** read the four color settings + `units` → `WatchGlucoseColorComputer.shared.apply(...)` (unconditional, cached); read `currentGlucoseMgDl` (validity-gated ≥25) → set `currentGlucoseMgDl` + compute `currentGlucoseColorString` locally; replaced the `data["glucose"]/data["color"]` chart decode with `StoredGlucoseReading.from(wcEntry:source:"wc")` → batch `insert` → `loadAsDisplayValues`.
- **Startup (`TrioMainWatchView.onAppear`):** load the chart from the history store when `glucoseValues` is empty (after snapshot restore).
- **Snapshot bakes (P2 invariant — nil on missing, never red):** `saveComplicationSnapshot(from:)` bakes from the message's `currentGlucoseMgDl` (≥25 else `nil`); `forceComplicationUpdate` bakes `currentGlucoseColorString` only when `currentGlucoseMgDl != nil`; BLE + HK snapshot builders now bake `bubbleColorHex(for:)` (was `nil`).
- **BLE + HK inserts (W2 merge):** adapter `handleSensorDidRead` inserts (`source:"ble"`, sequence) before the snapshot apply; HK `finishHKGlucoseObserverFetch` inserts (`source:"hk"`, rounded mg/dL). `applyG7DirectBleSnapshot`/`applyHKSnapshot` now set `currentGlucoseMgDl`, set `currentGlucoseColorString` from the baked snapshot, and refresh `glucoseValues` from the store (live chart update across all three channels).

**Deviation 4 — W1 store is serial-queue, not `@MainActor`.** Verified the watch's `WatchState` is `@Observable` (NOT class-level `@MainActor`) and `processRawDataForWatchState` runs on the main *thread* via a `DispatchQueue.main.asyncAfter` work item but is not actor-isolated; the BLE adapter calls in from its own context. Calling an `@MainActor` store synchronously from there won't compile and would cascade `@MainActor` across the WC-delegate chain. **Resolution:** rebuilt `WatchGlucoseHistoryStore` to serialize via a private `DispatchQueue` (every public method `queue.sync`), preserving the no-interleave invariant while being safe from any caller. (Supersedes W1's `@MainActor` design.)
**Deviation 5 — `GlucoseTrendView` unchanged; `currentGlucoseColorString` kept as the watch's local bubble-hex store.** Instead of the plan's rewrite to guard on `currentGlucoseMgDl`, the watch keeps populating `currentGlucoseColorString` locally (white default ⇒ "no data" is never red) so the existing `GlucoseTrendView` and snapshot-build/restore consumers work unchanged. This is also more robust: snapshot **restore** has no `mgDl`, so a `currentGlucoseMgDl`-based bubble would go neutral after a cold restore, whereas the restored hex renders correctly.

**Verified (grep):** no `data["glucose"]`/`data["color"]` or `message[currentGlucoseColorString]` reads remain on the watch; new keys + store wired in 21 sites; `GlucoseTrendView` uses the local hex.

**Status:** ✅ committed `d20f1e3ff` ("build205(W2+P2 watch): chart from history store, local color, all-channel merge"). Not yet compiler-verified.

### 2026-06-06 — P1 + W3 + W4 — source committed

- **P1 (WC payload window):** `Model/Helper/GlucoseStored+helper.swift` adds `NSPredicate.glucoseForTwoHoursAgo` (date ≥ now−7200); `AppleWatchManager.fetchGlucose` uses it + `fetchLimit: 24` (was `.glucose` / `288`). Watch keeps the full 24h via its store (W1), so only ~2h ships.
- **W3 (IOB/COB/lastLoopTime persistence):** `WatchState` — write four `WatchState.cached*` UserDefaults keys at the end of `processRawDataForWatchState` (keyed on `lastWatchStateUpdate`, the phone build time, not `Date()`); `restoreCachedLoopMetrics()` called from `init()` restores them only when the cache age is in `[0, 30 min]` (rejects stale **and** future-dated/clock-skew), else leaves `--`.
- **W4 (display gate):** `TrioMainWatchView` — stripped `isSessionUnreachable` from the IOB value, COB value, and COB color gates (now `isWatchStateDated` only, matching the IOB color template). Action buttons keep `isWatchStateDated || isSessionUnreachable`. (W12 rename of `isSessionUnreachable` still pending — mechanical, lands with the adapter cluster.)

**Status:** ✅ committed `faa03febe` ("build205(P1+W3+W4): shrink WC window, persist IOB/COB, fix display gate"). Not yet compiler-verified.

### 2026-06-06 — W13 + W7 (adapter keys + slot counters) — source committed

**Files:** `G7WatchSensorAdapter.swift`, `WatchState.swift`, `Views/ComplicationDebugView.swift`.
- **W13 key migration:** `Keys` enum unified to `G7WatchAdapter.*` (sensorName/calendarDay/connects/egvs renamed; lastEGVEpoch/firstSequenceToday already correct). One-time `migrateLegacySensorNameKeyIfNeeded()` (static, UserDefaults-only → legal before `super.init()`) copies the bound name from the legacy `G7DirectBLEObserver.sensorName` and removes it. Daily-counter keys self-heal (one-time reset on upgrade — accepted).
- **W7 slot counters:** adapter fields `expectedSlotsToday` / `gatedSlotsToday` / `lastExpectedSlotEpoch` / `gatedSlotEpochsToday` (Set, persisted as `[Int]`). `emitExpectedWindowTick` increments the **monotonic high-water** (`slotEpoch > lastExpectedSlotEpoch`, today-only) after `advanceDayIfNeeded()`. New **`advanceDayIfNeeded()`** = forward-only (`dayStart > storedDay`) rollover resetting all daily state incl. the high-water + gated set; `loadDailyCountersIfNewCalendarDay` now delegates to it. `loadDailyCounters`/`persistDailyCounters` extended to all slot state; `mirrorDailyCountersToWatchState` mirrors `expectedSlotsToday`/`gatedSlotsToday`. **EGV-save un-gate hook** in `handleSensorDidRead` removes the captured slot from the gated set (keeps ratio ≤ 100%). `ComplicationDebugView.countWithDenominator` now shows `count / max(0, expected − gated)`. `WatchState` gains the two mirror props.

**Note:** `gatedSlotEpochsToday` is declared here (W7) and **consumed** by C1's `beginScanIfEligible` (next slice) — C1 must not redeclare it.

**Status:** ✅ committed `2177b22ce` ("build205(W13+W7): unify adapter keys + slot-based capture denominator"). Not yet compiler-verified.

### 2026-06-06 — C1 (runtime gate) — source committed

**File:** `G7WatchSensorAdapter.swift`.
- New `isRuntimeEligible` (`scene == active || extendedSession?.state == .running`), `ScanKind { resume, newSensor }`, `deferredScanKind`.
- **`beginScanIfEligible(_:)`** — the single scan entry: `advanceDayIfNeeded()` first, then if not eligible defer (preserve `.newSensor` precedence), insert the slot into W7's `gatedSlotEpochsToday` (only when identity-eligible + today), log `ble_gated`, return; else `.resume` → `sensor.resumeScanning()`, `.newSensor` → `performScanForNewSensor()`.
- **`performScanForNewSensor()`** (renamed from `initiateScanForNewSensor`) now clears `boundSensorName` itself (deferred-clear: only when the scan actually runs).
- **Routed all four scan entries** through the gate: `start()` (`.newSensor` when `boundSensorName != name`, `.resume` otherwise), `applyNewSensorName`, `performEndOfSessionTeardown`, disconnect-rescan — each dropped its inline `boundSensorName = nil` (now in `performScanForNewSensor`).
- **Deferral consumers** `consumeDeferredScanIfNeeded()` (clear-before-reissue) called from `applyForegroundActiveEntry` (scene-active) and `extendedRuntimeSessionDidStart` (session `.running`). `start()` keeps `isStarted=true` + timers/counters before the gate (never gated wholesale).

**Note:** three stale comments still say `initiateScanForNewSensor` (cosmetic; the function is `performScanForNewSensor` now). **C2 will add** the accept-path inline `boundSensorName` teardown + `pendingSensorSwap` on top of this.

**Status:** ✅ committed `3206027b6` ("build205(C1): runtime gate for BLE scans"). Not yet compiler-verified.

### 2026-06-06 — C2 (phone-side epoch send) — source committed

**Files:** `Trio/Sources/Models/WatchState.swift`, `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`.
- DTO `WatchState` gains `g7ActivationEpoch: Int64 = 0` (+ `==`/`hash`).
- The G7 resolver (`MainActor.run` block) now also returns `resolvedActivationEpoch` (`Int64(sessionEpoch.rounded())` for the live name, `cachedEpoch` for the cached-name branch, 0 when none); assigned to `watchState.g7ActivationEpoch`.
- `watchStateToDictionary` sends `WatchMessageKeys.g7ActivationEpoch` (Int64) only when `> 0` (absence ⇒ watch legacy name-only path); added to the complication allowlist so the epoch travels with the name on the background path.

**Safe standalone:** the watch doesn't read `g7ActivationEpoch` yet, so this commit is inert until the C2 watch/adapter half lands.

**Status:** ✅ committed `6dcaee776` ("build205(C2 phone): send G7 sensor activation epoch with the name"). Not yet compiler-verified.

### 2026-06-06 — C2 (watch + adapter identity state machine) — source committed

**Files:** `G7WatchSensorAdapter.swift`, `WatchState.swift`.
- **Reconciled with existing freshness gate:** the watch's `lastAppliedG7SensorNamePayloadDate` (build-time, out-of-order suppression) is orthogonal and kept; C2's identity quarantine sits *behind* it in the adapter (per plan).
- **Adapter:** nested `SensorIdentity { name; activationEpochSeconds: Int64? }`; in-memory `quarantine`; `pendingSensorSwap`; persisted `storedActivationEpochSeconds` (`Keys.activationEpochSeconds`).
  - **`setActiveSensorIdentity(_:)`** — quarantine gate (`isQuarantined`) → missing-epoch log → change-type (`isSwap` = different name OR same-name strictly-newer epoch) → no-swap promotes a legacy binding to epoch-bearing → accepted swap persists epoch, sets `pendingSensorSwap`, calls `applyNewSensorName(name, force: true)`. Logs `identity_quarantined` / `identity_epoch_missing` / `identity_promoted` / `identity_accepted`.
  - **`isQuarantined`** — same name blocks unless strictly-newer epoch; different name escapes; epoch-bearing vs name-only quarantine = accept (promote); missing-epoch same-name = blocked.
  - **`applyNewSensorName(_:force:)`** — `force` bypasses the name-guard (same-name newer-epoch swap); clears `storedActivationEpochSeconds` on a nil (clear); when `pendingSensorSwap`, clears `boundSensorName` immediately (even if the scan is gated).
  - **`performEndOfSessionTeardown`** — records `(name, epoch)` into `quarantine` and logs `identity_quarantined reason=eos` **before** nilling `expectedSensorName`/epoch.
  - `setActiveSensorName(_:)` kept as the clear/legacy shim (named → `setActiveSensorIdentity` legacy identity; nil → `applyNewSensorName(nil)`). `adapterSessionID` rotates naturally on the swap's gated rescan→discovery (mint at `recordSessionConnect`).
- **Watch reader** (`applyG7ActiveSensorNameFromWatchPayloadIfPresent`): reads `g7ActivationEpoch` (Int64, NSNumber-safe), forms `SensorIdentity` → `setActiveSensorIdentity` for a named payload; `setActiveSensorName(nil)` for clear.

**Verified (grep):** watch reader routes correctly; `applyNewSensorName` callers = clear + force-swap; all `identity_*` telemetry present; W7 slot accumulators NOT reset on swap (only `bleFirstSequenceToday` via `applyNewSensorName`).

**Status:** ✅ committed `bf8da492c` ("build205(C2 watch): sensor identity epoch + EOS quarantine + swap reset"). Not yet compiler-verified.

### 2026-06-06 — W8 / W10 / W11 / W12 hygiene (W9 deferred) — source committed

- **W8:** `ComplicationDebugView` — added `Last BLE event:` (`WatchState.shared.g7DirectBleLastEventAt` via `formatTime`) and `Session ID:` (`adapterSessionID`, monospaced) rows above `Pre-EGV disconnects:`.
- **W10:** `triggerConfirmation` holds the 1.5s clear in a `DispatchWorkItem` (`confirmationClearWorkItem`) and cancels the prior before scheduling (debug-only coalescing).
- **W11:** `applyG7DirectBleSnapshot` sets `syncTimeoutWorkItem = nil` after `.cancel()` (matches `processRawDataForWatchState`).
- **W12:** renamed `isSessionUnreachable` → `isPhoneCommandUnavailable` in `TrioMainWatchView` (decl + the three action-button gates + comments). Only active site; commented-out refs in `BolusProgressOverlay.swift` left untouched (dead). Also fixed the 3 stale `initiateScanForNewSensor` → `performScanForNewSensor` comments in the adapter (C1 rename follow-up).
- **W9 — DEFERRED (recorded).** "Replace the per-event `Task { await … }` in adapter `log()` with a bounded/structured logging hop." `WatchLogger.shared` already serializes internally, so the per-call `Task` is benign; a true structured-logging hop (AsyncStream/continuation) is an infra refactor whose risk outweighs the Low/audit benefit. Left for a follow-up; not in 205.

**Status:** ✅ committed `60260343c` ("build205(W8/W10/W11/W12): debug rows, confirm coalesce, timeout nil, rename"). Not yet compiler-verified.

### 2026-06-06 — C3 (G7SensorKit fork) — BLOCKED, needs fork workflow + decision

Confirmed the C3 site: `G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift:130` `configureAndRun` returns a closure; the `catch` (`:147–150`) logs "Will retry" then falls through to `block(self)` (`:154`). `perform` = `queue.async(execute: configureAndRun(block))`; `queue` exists (`:46`). The intended fix (fail-closed `return` + `needsConfiguration = true` + `scheduleConfigurationRetry(rerunning: block)`) is structurally sound — `return` inside the catch exits the returned closure, skipping `block(self)`.

**Blockers found (plan assumption was stale):**
1. **Submodule base mismatch.** Working-tree `G7SensorKit` is at **`b791cf5`** ("Merge branch 'LoopKit:main' into main"), but `patches/02` pins **`4d0780db`** (the Trio telemetry-bearing fork commit). The build applies patch 02 to move the submodule to `4d0780db`; the working tree here is the *pre-telemetry base*.
2. **`emitG7Telemetry`/`G7Telemetry` absent in this checkout.** The plan (v1.6/v1.7) verified them against the patched fork SHA, not `b791cf5`. So C3 must be written on top of `4d0780db` (or the fork's current telemetry-bearing main), where the helper exists — not the working-tree base.
3. **Outward push required.** Delivery is fork `main` commit → **push** (publishes) → repin `patches/02` to the new SHA. Cannot complete without pushing to `github.com/cachrisman/G7SensorKit`.

**RESOLVED — committed in the standalone fork.** The up-to-date fork is the standalone repo at `/Users/charlie/Code/personal/health/diabetes/G7SensorKit` (branch `main`, has `emitG7Telemetry` at `G7Telemetry.swift:42`) — NOT the Trio submodule checkout. Implemented there:
- `configureAndRun` catch is now **fail-closed**: emits `configure_block_skipped`, sets `needsConfiguration = true`, calls `scheduleConfigurationRetry(rerunning: block)`, and `return`s (skips `block(self)`).
- `scheduleConfigurationRetry` — first-wins (`configure_retry_already_pending`), capped (`maxConfigurationRetryAttempts = 5`, backoff `2<<attempt` → 2..32s, ≤60), clears the work-item slot before re-entering `perform(block)`, abandons if `peripheral.state != .connected` (`configure_retry_abandoned`); logs `configure_retry_scheduled`/`configure_retry_exhausted`.
- Reset-on-success (`configurationRetryAttempts = 0` when config completes); `cancelConfigurationRetry()` from the `peripheral`/`delegate` `didSet`s; dealloc safety via `[weak self]`.
- **Commit `74824a104f79f5263afd0624828e2d8e8c8a3a7f`** (`74824a1`) on fork `main`. **NOTE: unsigned** (1Password SSH-signing couldn't fill non-interactively) and **local-only** — needs `git push` to `github.com/cachrisman/G7SensorKit` before the build can fetch it. (SHA history: `8fc20cb` → `823e60d` → `74824a1`; the last two replays both stripped attribution trailers — see note below. The prior commit `21d6d8a` "fix(ble): skip redundant connect", which also had a trailer, was replayed to `97388ef`.)
- **Delivery (user-owned):** repin `patches/02` to `74824a1…` (`mid-stack-update --patch 02`). Validate fail-closed on **both** watch and iPhone (shared `configureAndRun`).

> **Commit-message attribution corrected (2026-06-06).** All build-205 commits were initially made with a `Co-Authored-By: Claude …` trailer, violating the user's standing "no commit attribution" rule (the memory was siloed in another project and didn't load — now duplicated into this project's memory). Fixed: the C3 fork commit was amended (SHA `8fc20cb` → `823e60d`); the 11 Trio feature-branch commits were rewritten via `git filter-branch` to strip the trailer (message-only — trees/content unchanged; `refs/original` backup retained). **Feature-branch commit SHAs listed elsewhere in this log are therefore superseded** (the patches regenerate from the tree, not by SHA, so this is informational).

### 2026-06-06 — 3-way code review (this agent + Cursor + Codex) — dispositions

Three independent reviews; merged/deduped. **0 compile blockers.** Fixes:
- **DONE (fork, folded into C3 `3a0b2ac`):** (1) auth-drop hole — `assertConfiguration`'s empty probe no longer arms the fail-closed retry (`retryOnConfigFailure=false`), so it can't first-win the slot and drop a real auth retry (Codex; this agent had missed it); (low) `cancelConfigurationRetry` resets `configurationRetryAttempts`.
- **DONE (feature branch, commit `96c57798c` "build205(review-fixes)"):**
  - **#2 (high):** `forceComplicationUpdate()` now uses unit-aware sanity bounds (mmol/L ~2.0–22.5 vs mg/dL 40–400), so mmol/L users aren't skipped. (Chose unit-aware display bounds over gating on `currentGlucoseMgDl` to avoid regressing the snapshot-restore path, where `currentGlucoseMgDl` is nil.)
  - **#4 (med):** invalid-`currentGlucoseMgDl` else branch now sets `currentGlucoseColorString = "#ffffff"` — no stale color for no-data.
  - **#5 (med):** factored `applyColorSettingsFromPayloadIfPresent(_:)`, called from both `processRawDataForWatchState` and `saveComplicationSnapshot`; added the 4 settings + `units` to the complication allowlist.
  - **#3 (med, debug-only):** `countWithDenominator` caps the numerator at the denominator (`min(count, denom)`) so the ratio can never display >100% (chose the cap over slot-realignment — the gate/EGV slot mismatch is inherent to deferred-then-captured windows; this is a debug diagnostic).
  - **lows:** exchange rate → `Decimal` float-literal (bit-match the phone); epoch `0`→`nil`; `loadAsDisplayValues` prunes on read; `StoredGlucoseReading.from` accepts bare Int/Double.
  - **DEFERRED:** BLE/HK current-glucose mmol/L formatting — the snapshot `glucose` string is parsed back to `Int` to recover `currentGlucoseMgDl`, so converting it needs a `TrioComplicationSnapshot` model change; out of scope (user uses mg/dL). HK insert-all-batch-samples also deferred (LOW; latest-sample is the chart-relevant point).
- **Adjudicated OUT (not bugs):** C2 BLE-discovery "ignores epoch" (epoch isn't in the advert; quarantine gates via `expectedSensorName`); dynamic-color dark-mode drift (accepted, `color_parity` log); main-thread `queue.sync` (acceptable for ~288-row JSON); "patches not regenerated" (delivery, not a defect).

---

## Delivery / patch-regen phase (after all source slices — NOT yet started)

All build-205 source is on `feature/watch-g7-direct-ble-observer-synthesis` (11 commits, `a29643c6c`…`60260343c`), **not yet compiled**. Remaining mechanical delivery, in order (per "Delivery / patch mapping" + sequencing constraints above):
2. ⚠️ **Fork — re-deliver needed (2026-06-06):** C3 commit **amended to `3a0b2ac`** (was `74824a1`, which was pushed + pinned) to fold in two review fixes: (a) the no-op `assertConfiguration` probe now passes `retryOnConfigFailure=false` so its empty block can't first-win the single retry slot and drop a real auth/control retry (Codex-found auth-drop hole), and (b) `cancelConfigurationRetry` resets `configurationRetryAttempts`. **Action (user): force-push the fork `main` (history rewritten) and re-repin `patches/02` to `3a0b2ac`.**
1. ✅ **Done (2026-06-06):** `sync_project_files_config.rb` `GlucoseHueColor.swift` watch entry committed directly to **`dev`** as `9f3adf7ad`. The W5 hunk for this file was **removed from the feature branch** (it should not live there — build infra is not patch-carried): `git filter-branch` reset the file to its pre-W5 blob across `dev..HEAD` (W5 still adds the two new `.swift` files; only the sync-config hunk dropped). Feature-branch commit SHAs changed again as a result (still informational — patches regen from the tree).
3. ✅ **Patch 09 — NO regen needed (2026-06-06).** Every patch-09 file build 205 touches is **also owned by a higher patch** (`WatchMessageKeys`→12, `AppleWatchManager`→13, watch files→12), whose baseline already includes patch 09 — so regenerating 09 would over-capture, and the build-205 watch changes depend on patch-12 (direct-BLE) context so can't live in 09 anyway. Left untouched.
4. ✅ **Patch 12 regenerated** (`--from-feature-branch` + `--extra-files` `WatchGlucoseHistoryStore.swift`,`WatchGlucoseColorComputer.swift`) — 17 files; **stack validation PASSED**; `WKBackgroundModes`/`physical-therapy` survived (grep=3). Uncommitted.
5. ✅ **Patch 13 regenerated** (`--from-feature-branch` + `--extra-files` `GlucoseHueColor.swift`,`DynamicGlucoseColor.swift`,`WatchGlucoseObject.swift`,`GlucoseStored+helper.swift`) — `AppleWatchManager` (P1/P2/C2) + 4 new/upstream phone files (8 files); **stack validation PASSED**. Uncommitted.
   - **Verified:** all 8 build-205 product files byte-identical between the regenerated stack and the feature branch (0 build-205 drift). The large `.swift` drift report = dev ahead of the stale feature branch on unrelated modules + dev-only docs/patches/scripts; not build 205. Grep checks pass (`glucoseMgDl`, `g7ActivationEpoch`, single `glucoseHueComponents`/`calculateHueBasedGlucoseColor`, no stale `data["color"]`).
   - **Deviation:** new `WatchMessageKeys` landed in 12 (not 09) and the W5 phone helpers in 13 (not 09). Compile-correct (09 doesn't reference build-205 keys; 13 applies after 12 which defines them).
6. ⚠️ **`patches/02` is STALE — still pins `74824a1`** (first C3, before the auth-drop review fix). **User action:** force-push the fork (`3a0b2ac`) + repin `patches/02` → `3a0b2ac`, then re-run `patch-test.sh` and do the single build (your flags). Patches 12/13 (and 02) remain **uncommitted** per the lifecycle.

---

### 2026-06-06 — first build attempt failed on upstream drift → reset to pre-sync base (Option A)

The first build's **automatic upstream sync** merged `upstream/dev` into dev (`7d8eb828f`, Trio Patch Bot 16:26), pulling `a965e056b` which **rewrote the watch WC-receive path** (`AppleWatchManager.swift` + watch `WatchState.swift`: unified `didReceiveMessage`/`didReceiveUserInfo` into `handleIncomingWatchStatePayload`, `state.date`→send-time, dropped a guard). Patch 09 (pre-existing) then conflicted against the new base; build-205's patch 12 overlaps the same region. `patch-test` had passed pre-sync.

**Chosen path A (ship 205 first):** `git reset --hard 9f3adf7ad` on dev (dropped the upstream merge; my build-205 patches preserved via stash; product code back to pre-merge — `handleIncomingWatchStatePayload` absent). `patch-test.sh` PASSES on this base (01–14 all apply). Rebuild with **`--no-sync-upstream`**. Local dev is intentionally behind `origin/dev` — do not `git pull` (would re-merge).

**Deferred (Option B — separate upstream reconciliation):** rebase the feature branch onto the new upstream, adapt build-205's WC-receive edits to `handleIncomingWatchStatePayload`, regen 12/13, fix patch 09 vs upstream, and **re-examine W3**: upstream changed `state.date` to send-time, which is the build-time anchor W3 keys its 30-min cache on (probably benign — send-time is still a valid recency anchor — but verify).

**Build attempt 1 → compile error (fixed).** `ComplicationDebugView.swift:563 cannot find 'formatTime' in scope` — the W8 "Last BLE event:" row is in `G7DirectBleDebugSection`, whose helper is `formatG7Time(_:Date?)` (not `formatTime`, which lives in the other struct). Fixed on the feature branch (`5c2b53a6a`).

**Tooling: added `--allow-behind-origin` (committed to dev `bfa0eb9d7`).** Option A's pre-merge reset left dev behind origin, which `generate-patch.sh` hard-blocks (single guard, no override). Added an opt-in `--allow-behind-origin` flag to `generate-patch.sh`, threaded through `mid-stack-update.sh`, for intentional pre-merge regen. (Had to be **committed**, not left uncommitted — mid-stack-update stashes uncommitted changes, which swept up the flag and made generate-patch reject it.) **Patch 12 regenerated with the W8 fix via the flag — Stack validation PASSED** (`formatG7Time` present; broken `formatTime` row gone). Patches 12/13/02 uncommitted; ready to rebuild with `--no-sync-upstream`.

**Still open before/at rebuild:** `patches/02` pins `74824a1` (C3 without the auth-drop review fix). To ship the auth-drop fix, force-push the fork (`3a0b2ac`) + repin `patches/02` → `3a0b2ac`; otherwise the build uses `74824a1` (C3 functional, missing only the empty-probe refinement).

---

## Deferred (not in this build)

**`g7_session=nil` on watch-side connects.** Appears on the shared **G7SensorKit fork** core telemetry (`G7Telemetry.swift` formats `… g7_session=…`; the *host* supplies the value), not the watch adapter's own `log()` (which already passes `g7Session: adapterSessionID`, verified `G7WatchSensorAdapter.swift:321–333`). The watch host does not thread a session id into the shared manager the way the iPhone does.
- **Impact.** Diagnostic only — no effect on delivery/persistence/UX.
- **Why deferred.** Out of 205's theme; lands in the fork + a patch 02 repin (same lane as C3); root cause needs investigation first.
- **Next step.** Mirror the iPhone's session-id plumbing on the watch host; deliver via fork commit + `patches/02-…` SHA bump. If scoped in, batch with C3 to avoid a third patch-02 repin.