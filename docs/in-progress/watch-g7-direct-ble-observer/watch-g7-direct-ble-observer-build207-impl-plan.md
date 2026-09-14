> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Watch G7 Direct-BLE Observer — Build 207 Implementation Plan

**Version:** v0.2 (open/living plan)
**Status:** OPEN — build-206 telemetry verdict landed (2026-06-09). **All code items now implemented** (uncommitted in the `Trio` feature-branch working tree + the `G7SensorKit@40b5871` fork pin): C-207-2 + M2 telemetry (fork), and C-207-1, DS1, UI-207-1/2/3 (adapter + `WatchState` + `ComplicationDebugView`). Parse-clean; second-model `ollama-task review` found no real bugs (2 false positives, verified). **Pending: the next Trio build to compile-verify + BetterStack re-measure.** P1 blocked on Apple; M3 real-EOS path still watched.
**Created:** 2026-06-07
**Branch (product code):** `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree)
**Predecessor:** build 206 (shipped to TestFlight 2026-06-07 as Trio 0.8.1 build 206).

---

## Why 207 exists / what changed since 206

Build 206 shipped the watch-BLE fixes (remove WKExtendedRuntimeSession chaining, foreground-only
session-start hygiene, false-EOS teardown fix, CB state-restoration launch touch, real NSError
logging, display-reference cleanup, dead-field removal). **Build 207 is deliberately data-gated:**
most of its scope depends on what the post-206 BetterStack telemetry shows once 206 has run for a
day (including overnight / background cycles). The only un-gated item is the cosmetic display fix.

> **Correction carried forward (important):** `WKExtendedRuntimeSessionState` raw values are
> `notStarted=0, scheduled=1, running=2, invalid=3` (verified in the watchOS SDK header). The long-
> standing reading that `rawValue: 2` = "invalid/dead" was **wrong** — it is `.running`. So the
> watch's extended-runtime session has generally been *healthy*; the debug row was just printing the
> opaque enum rather than a name. Build-206's `extendedSession`-nil-on-invalidate (D2) is still
> correct hygiene (a truly `.invalid` session should be cleared) — it was just mis-motivated. No
> revert needed.

---

## Build-206 telemetry verdict (2026-06-09)

BetterStack analysis of build 206 vs 205, watchOS only (`platform=watchos`), hot+S3 union. **Scope
caveat:** the data is dominated by **one primary device wearing one sensor (`DXCMed`)**, continuous
across the 205→206 upgrade (G7 `sequence` 1886→1891). `DXCMTx` emits **no EGVs** (transmitter
advertisement only), so capture rate is clean on a single sensor — the old DXCMed/DXCMTx mixing
concern (M1) is moot. Treat numbers as strong directional signals, n≈1 device.

**Metric:** the G7 `sequence` counter increments once per 5-min reading. Within a contiguous sensor
run, **expected = max(seq) − min(seq) + 1**, **captured = count(DISTINCT seq)** — robust to the S3
row-duplication that doubled 205's raw counts and to the g7_ble+g7_core per-EGV double-emit (true
unique EGVs = distinct `sequence` within one module). The phone reads the same sensor, so phone
distinct-seq is an independent ground-truth denominator.

### Headline (Q1: did 206 improve capture?)

**Reproducible definition (frozen 2026-06-09; counts grow as 206 keeps running):** DXCMed,
`module=g7_core`, `event=egv_received`, distinct `sequence`. Watch split by the **`build` field**;
phone (truth) is `platform=ios` distinct sequence **bounded to each build's watch seq range**.

| Build (watch seq range) | Watch captured | Phone (truth, same seq range) | **Capture rate** |
|---|---|---|---|
| **204** (seq 929–1768) | 210 | — | (context only) |
| **205** (seq 1769–1886) | 28 | 114 | **24.6%** |
| **206** (seq ≥1891, →2643) | 302 | 736 | **41.0%** |

**206 lifted watch EGV capture 24.6% → 41.0% on the same sensor (+16.4pp, ~1.67×).** Phone- and
span-denominators agree.

> **Correction (from Cursor/Codex review, verified):** an earlier draft showed "205 era 44/183 →
> 206 300/729". That **mislabelled** the 205 row — the `seq ≤1886` bucket silently included the
> **build-204 tail** (seq 1704–1768: 14 watch / 65 phone). Filtering by the literal `build` field
> gives build-205-proper **28/114** and build-206 **302/736**. The ratio and conclusion are
> unchanged; the counts/labels are now build-pure. The old "~49–54%" build-204 figure used the mixed
> `expected_window` method this plan flagged as unclean — **not comparable**.

### The insight that reframes 207

EGV captures in 206 by extended-runtime-session state (snapshot 2026-06-09, 310 EGVs; grows as 206
runs — review cross-checks confirm the proportions hold):

| `ext_session_active` | `scene_phase` | EGVs |
|---|---|---|
| **false** | unknown | ~111–120 |
| **false** | background | 107 |
| true | inactive | 45 |
| true | background | 34 |
| true | active | **4** |

**~73% of captures happened with NO active extended-runtime session; ~45% while backgrounded; only 4
in the foreground-active state.** The `WKExtendedRuntimeSession` is **not** the EGV-delivery
mechanism — **background BLE central is the workhorse.** 207 effort should target background-BLE
resilience, not the runtime session.

### M-item results

- **M1 — re-baseline:** ✅ Done (above). Clean single-sensor metric; 24%→41%. Per-sensor split
  unnecessary (only DXCMed produces watch EGVs).
- **M2 — CB state restoration:** ⚠️ **Inconclusive from telemetry; conclusion rests on policy + code,
  not BetterStack.** **Important blind spot (Cursor):** `willRestoreState` logs only via OSLog
  (`G7BluetoothManager.swift:363` `log.default("Restoring peripheral from state…")`), **not**
  `emitG7Telemetry` — so it can **never** appear in BetterStack whether or not it fires. The earlier
  "zero events ⇒ never fires" was an **invalid inference**; retract it. What we *can* assert: the
  central manager IS created with `CBCentralManagerOptionRestoreIdentifierKey` (`:131`),
  `willRestoreState` IS implemented (`:358`), `bluetooth-central` UIBackgroundMode IS declared
  (`Info.plist`), `WatchState.bleWasRestored` is **never set anywhere** in code, **and the watch
  entitlements (`TrioWatchApp.entitlements`) have only HealthKit + app-groups, no
  `bluetooth-central-background`.** On watchOS, CB background relaunch requires that entitlement →
  **D6's restoration touch cannot pay off pre-entitlement; P1 is the structural path** (this rests on
  Apple's entitlement policy + the unset `bleWasRestored`, NOT on telemetry). ✅ **Action done:** an
  `emitG7Telemetry("will_restore_state", …)` line was added in the fork (`G7SensorKit@40b5871`, patch 02)
  so restoration becomes measurable from the next build; until that data lands M2 stays open. The 45% background captures ride incidental
  wakes (complication bgtasks / HealthKit / the ~1h physical-therapy session), not proven CB relaunch.
- **M3 — D7 EOS safety:** ⚠️ **Mostly-clean, with a long-stale outlier — do NOT read as "no
  regression."** Of 89 `disconnect_suspected_eos_ignored`: **85 ≤20 min** (false-EOS reconnect churn,
  correctly ignored), but **4 at 25–30 min and 1 at 190 min** — and **`eos_detected=0`** (the
  authoritative-EGV teardown path, `algorithmState .sessionEnded/.sensorFailed`/age ceiling in
  `handleSensorDidRead`, `G7WatchSensorAdapter.swift:956`) was **never exercised in 206** (one
  continuous sensor, no real end). The 190-min ignore was *probably* correct here (sensor stayed
  alive per the phone), but it demonstrates D7 will sit on a very-stale binding the disconnect path
  can't adjudicate, and the EGV-path safety net is unproven. **Keep M3 open**; investigate the 190-min
  outlier and watch for a real sensor change. The `stale_sensor_binding_suspected` backstop (≥3
  pre-EGV disconnects, >10 min stale; `:894–932`) is firing as designed.
- **M4 — D8 session start + D9 reasons:** ✅ D8 fixed start: 14/14 `ext_session_start_requested_foreground`
  → `ext_session_started` (100%), all `scene_phase=active`. Residual failure mode (D9 reasons): the
  foreground-started session is killed on backgrounding by `RBSAssertionErrorDomain code=1`
  ("Assertions were invalidated", RunningBoard reason 4) — 10× `ext_session_unexpected_invalidation
  triggering_teardown=true` + 2× natural `expired(2)`. **This is the trigger for the harmful teardown
  in C-207-1 below.**

---

## Code changes (the actual build-207 bucket)

This is the running list of **code** changes. DS1 was the initial cosmetic item; **C-207-1 / C-207-2**
were added from the build-206 telemetry verdict above (validated against code, n≈1 device — review
before committing).

### Ready

| # | Change | Notes | Target |
|---|--------|-------|--------|
| **DS1** ✅ **IMPLEMENTED** | **Readable `WKExtendedRuntimeSessionState` in the debug row + heartbeat** | Add a `describeState(_:)` map (like D9's `describeReason`) so `extSessionState` and `emitHeartbeat`'s `ext_session_state=` print `notStarted`/`scheduled`/`running`/`invalid`/`nil` instead of `WKExtendedRuntimeSessionState(rawValue: N)`. **Fix the stale doc comment** at `G7WatchSensorAdapter.swift:~87` that lists only "notStarted/running/invalid" (missing `scheduled`, wrong implied ordering). This is the fix for the user-visible "row still says rawValue: 2" — it'll read `running`. | patch 12 |
| **C-207-1** ✅ **IMPLEMENTED** | **Don't tear down BLE when the ext-session is killed while non-active (decouple `stop()` from RBS invalidation)** | **Highest-impact, lowest-risk.** The `hasError` branch of `extendedRuntimeSession(_:didInvalidateWith:error:)` (`G7WatchSensorAdapter.swift:1153`, handler spans `:1125–1172`) calls `stop()` on *any* errored invalidation. In 206 the error is always `RBSAssertionErrorDomain code=1` fired when the app leaves the active scene (10/10), and `stop()` → `sensor.stopScanning()` (`:293`) kills BLE; the 5s recovery is gated on `scene_phase=="active"` (`:1161`) so it's skipped while non-active (`recovery_skipped` ×10 — **5 `inactive` + 5 `background`**). Net: **BLE goes dark after the app leaves active (wrist-down / inactive) — when the next EGV is due**, until the next foreground-active entry. Yet telemetry shows **background BLE delivers ~45% of all captures**. Fix: in the `hasError` branch, when `scene_phase != "active"` **and** the error is the benign RBS assertion — match on **`NSError.domain == "RBSAssertionErrorDomain"` via `describeError`/the error object, NOT `reason.rawValue == -1`** (post-`didStart` invalidations can carry a valid reason enum with RBS in the error field) — **do not call `stop()`**: clear the session ref (already done at `:1134`), clear `recoveryScheduled`, leave `isStarted=true`/timers/fork scan **running** so the OS keeps the BLE wake path alive (`scanAfterDelay` comment: "OS won't re-wake the app unless it's scanning"). Only `stop()` on a genuine non-RBS error or while foreground-active. | adapter → patch 12 |
| **C-207-2** ✅ **IMPLEMENTED** | **Fast-reconnect on pre-EGV disconnect (skip the 2s `scanAfterDelay` when no glucose was received this connection)** | `pre_egv_disconnect` fired **162×** in 206 — the dominant in-session miss. **152/162 (94%) `ext_session_active=false` (background)**; **89/162 (55%) `suspected_eos=true`** (⇒ `wasRemoteDisconnect && pendingAuth`, `G7Sensor.swift:251`) — i.e. about half are pending-auth remote drops (transmitter drops mid-handshake under background CPU starvation, before the glucose notification); the other ~45% are non-pending-auth drops. `since_connect_s=0–11` throughout. **Do not claim "all pending-auth"** — the common thread is *background pre-EGV disconnect*, not a single drop cause. The fork's `scanAfterDelay()` (`G7SensorKit/.../G7BluetoothManager.swift:244`, called from `didDisconnectPeripheral`/`didFailToConnect`) unconditionally sleeps 2s before rescanning — correct for the *normal* post-EGV transmitter shutdown, but when the drop happened **before any glucose this connection** the transmitter is likely still in its advertise/connection window, so the 2s delay + full rescan can miss it. Fix (fork, patch 02): add a **per-connection `hadGlucoseThisConnection` flag in the fork** (the adapter's `hadEGVThisSession` is adapter-side, not visible to `scanAfterDelay`) — cleared on connect, set in `handleGlucoseMessage`; on a disconnect with the flag still false, `scanForPeripheral()` immediately (no 2s sleep). **Gate on "no glucose this connection," NOT on platform** — this is a justified watch-side win but the fork is shared, so document that it leaves iPhone's post-EGV 2s shutdown wait intact (iPhone rarely drops pre-glucose). Pairs with C-207-1 and P1 (both reduce the background starvation behind the premature drop). **Also folds in the M2 `will_restore_state` telemetry (same commit).** | ✅ **DONE** — `G7SensorKit@40b5871` (`cachrisman/G7SensorKit main`, pushed), `patches/02` repinned. Parse-checked; **full compile + BetterStack verification pending the next Trio build.** |

> **Sequencing note:** **C-207-2 has landed in the fork** (`G7SensorKit@40b5871`, patch 02 repinned) —
> next is **C-207-1** (adapter-only, ship with DS1) and the **next Trio build** to compile-verify both
> and re-measure capture rate + `will_restore_state` in BetterStack. **P1 is NOT in this sequence** — it
> is blocked on Apple granting a special entitlement (see Parked) and cannot be scheduled; C-207-1/C-207-2
> are designed to stand alone without it. C-207-1 alone should move the background-capture share
> materially if the "BLE-dark-while-non-active" mechanism is as dominant as the telemetry suggests.

---

## UI / debug-view fixes (from the build-206 watch-UI review — Cursor + Codex)

Lower-priority than C-207-1/2 but cheap and ship-with-DS1 (all in `Trio Watch App Extension/Views/ComplicationDebugView.swift` plus one adapter line). **Verified against source 2026-06-09.**

| # | Change | Notes |
|---|--------|-------|
| **UI-207-1** ✅ **IMPLEMENTED** | **Fix the Connects/EGVs debug rows (display bug)** | Both rows go through `countWithDenominator` (`ComplicationDebugView.swift:578,584`), which divides by the W7 slot denom (`expectedSlotsToday − gatedSlotsToday`) and **caps the numerator with `min(count, denom)` (`:670`)** — so raw `142 EGVs / 211 connects` with 61 eligible slots renders **`61/61` on *both* rows**, hiding the real totals. The helper's own comment (`:668`) admits the connects-are-event-based-vs-slot-based mismatch. Fix: **Connects → raw `bleConnectsToday`** (no denominator); **EGVs → raw `142/211` (egvs/connects, matching `GlucoseTrendView.swift:41`)** and/or the W7 slot capture rate **un-clamped** as a clearly-labeled separate row; add **`Windows: 61 eligible / N gated`**. ⚠️ The W7 slot capture-rate (attempted slots) is a **different metric** from M1's sequence/phone capture rate (41%) — label distinctly so they aren't conflated. |
| **UI-207-2** ✅ **IMPLEMENTED** (status row keeps `rawValue`, now readable post-rename) | **Status-line accuracy (`retrieving` overloaded; `.scanning` can lie)** | `publishConnectionStatus()` (`G7WatchSensorAdapter.swift:712`) falls back to `.retrieving` for *everything* not connected/scanning/stopped — which is mostly the **idle wait between G7 advertisements** (incl. the fork's 2s `scanAfterDelay` and C1-deferred background), not OS-cache retrieval. Rename the fallback to **`waiting`** (clearer than `idle`, which reads as "disabled"). Separately, **`performEndOfSessionTeardown()` (`:766`) sets `.scanning` unconditionally right after `beginScanIfEligible(.newSensor)` — but that scan is C1-gated and can refuse (`:664` guard → `ble_gated`, returns)**, so the row can show "scanning" when no scan started; set `.scanning` only when the scan actually began. Debug view should render a **mapped/`badgeText` label, not the raw enum `rawValue`** (`:512`). Optional: surface `deferredScanKind != nil` as `gated`. |
| **UI-207-3** ✅ **IMPLEMENTED** (b: comment fixed, `Was restored` row still deferred until `bleWasRestored` is wired) | **Debug-view polish (low risk)** | (a) `glucoseColor(for:)` (`:452`) hard-codes `<70`/`>180` — use `WatchGlucoseColorComputer` so the debug header matches the main bubble after W5. (b) Fix the **stale comment** `:616–617` ("willRestoreState never fires for Trio's non-owning central") — false after D6 (the watch adapter now owns the central) and orthogonal to M2 (we can't even measure it via BetterStack); re-add a **`Was restored`** row once the fork emits `will_restore_state` (ties to M2's telemetry action). (c) DS1 already covers the opaque `extSessionState`. (d) **Verify/relabel "Last BLE event"** (`:555`): `g7DirectBleLastEventAt` is set at `WatchState.swift:994/1004/1042` — if any are non-BLE scene-phase transitions (per Codex), rename to `Last status event` or add a true BLE-activity timestamp. |

**Dead status enum cases:** `connecting`, `fastRetry`, `moderateWait`, `unavailable` are defined (`WatchState.swift:38`) but never assigned. Lowest-value cleanup, fold into UI-207-2: at minimum wire **`unavailable`** (BT off/unauthorized — genuinely useful), optionally map the 2s `scanAfterDelay` window to **`fastRetry`**, and delete whatever stays unused so the enum doesn't imply states that can't occur.

**Reviewer points NOT adopted (verified, with reason):**
- **"Use `@Bindable`/`@State` for `WatchState` in the debug section" (Cursor):** not needed — `WatchState` is `@Observable` (`WatchState.swift:75`); the Observation framework tracks `WatchState.shared.*` reads inside a SwiftUI `body` automatically (the code comment at `:490` already relies on this). The 1 Hz parent tick only drives countdown re-renders. No change.
- **"Next connect should be last-EGV+5min, not last-connect+5min" (Cursor):** the row is explicitly **labeled** "Next connect" (`:530`) and uses `bleLastConnectAt` — correct by its own definition. A clarity nit at most, not a bug; skip.
- **Duplicate `DateFormatter` statics (Cursor):** trivial; optional cleanup, not worth a 207 line.

---

## Telemetry analyses (NOT code) — RESOLVED by the build-206 verdict above

**All four M-items have been run** (2026-06-09; see "Build-206 telemetry verdict"). Status below;
findings already folded into C-207-1/C-207-2 and P1.

| # | Measurement | Result |
|---|-------------|--------|
| **M1** | Per-sensor EGV-capture re-baseline. | ✅ **DONE.** **24.6% (build 205, 28/114) → 41.0% (build 206, 302/736)** on the same DXCMed sensor, clean `build`-filtered sequence metric, phone-confirmed. Per-sensor split moot (only DXCMed yields watch EGVs). Earlier 44/183 figure was a 204+205 seq mix — corrected. |
| **M2** | Confirm CB state restoration fires. | ⚠️ **Inconclusive from telemetry** — `willRestoreState` logs via OSLog, not BetterStack, so it's unmeasurable today (retract "never fires"). Conclusion rests on **policy + code**: restore-id/`willRestoreState`/`bluetooth-central` all present but entitlement absent and `bleWasRestored` never set → **P1 is the path**, D6 can't pay off pre-entitlement. ✅ `will_restore_state` telemetry **added @ `40b5871`** — measurable after the next build. |
| **M3** | ⚠️ Confirm D7 didn't make EOS too lax. | ⚠️ **Mostly-clean, not "no regression."** 85/89 ignored-EOS ≤20 min (correct), but **4 @ 25–30 min, 1 @ 190 min**, and **`eos_detected=0`** (real-EOS path unexercised). Keep open; investigate the 190-min outlier; watch for a real sensor change. |
| **M4** | Confirm D8 reduced session-start failures; read D9 reasons. | ✅ **D8 fixed start (14/14).** Residual = `RBSAssertionErrorDomain code=1` on leaving active (RunningBoard reason 4); this is what trips the harmful `stop()` → **C-207-1**. |

---

## Conditional / parked

| # | Item | Trigger |
|---|------|---------|
| **P1** 🔒 **BLOCKED ON APPLE — NOT ACTIONABLE BY US** | **Add `com.apple.developer.bluetooth-central-background` (+ `screen-off-scanning`) entitlements** to the watch extension; would likely supersede the WKExtendedRuntimeSession physical-therapy approach. **⚠️ This is an Apple-gated, special-permission entitlement — it is NOT in the standard capabilities list and CANNOT be self-enabled in Xcode, the Developer portal, or a provisioning profile.** Apple must grant it to the team/bundle ID before it can be added to the entitlements file; until then, adding it would break signing/provisioning. **Status: waiting on Apple** — open **Feedback Assistant `FB22619409`** + a **Developer Technical Support / code-level request**, current resolution *"Change required from 3rd party."* There is **no ETA and no guarantee of approval**; this item cannot be scheduled into any build until Apple responds. **Do not treat P1 as a plannable 207 task — it is aspirational/parked behind an external blocker.** Code-side prerequisites are already in place (restore-id `G7BluetoothManager.swift:131`, `willRestoreState` `:358`, `bluetooth-central` UIBackgroundMode); the entitlement is the sole missing, non-self-serviceable piece. If/when granted, it is the structural fix for the background starvation behind `pre_egv_disconnect` (C-207-2) and the BLE-dark gaps — **so C-207-1/C-207-2 must stand on their own and not assume P1 lands.** | **External: Apple approval of FB22619409 / DTS request. No ETA. Cannot be enabled unilaterally.** |
| **P2** | **Feature-branch hygiene: drop the abandoned crashlytics commit** (`1b7dbf805 feat: crashlytics test crash button`) so the `AppDiagnosticsRootView.swift` orphan stops showing as drift. The branch was stacked on a now-removed crash-reporting patch. Alternative: formalize `--drift-exclude-regex 'AppDiagnostics'` in the patch-12 regen recipe. | Cleanup; do whenever the branch is next rebased. |
| **P3** | **Optional telemetry classifiers** (from I-5): add `reason=` to `sensor_error` (separate handshake-race from RF timeout) and a prior-state field to `start_recovered_from_nil_sensor`. Telemetry-only, low priority. | If dashboards need it. |

---

## New considerations (not previously discussed)

1. ~~**207 is mostly a verification build, not a feature build.** ... Resist pre-committing code beyond DS1 until the data says where the remaining coverage gap is.~~ **UPDATE (2026-06-09):** M1–M4 have landed (verdict above). The data *did* say where the gap is — it's **background-BLE resilience**, not the runtime session. 207 now has a clear substantive scope: C-207-1 (decouple BLE teardown) + C-207-2 (fast pre-EGV reconnect) + P1 (entitlement). The "verification build" framing is superseded.
2. **M3 is the new risk to watch.** Build 206 made the disconnect-path EOS *log-only* (conservative) to stop false teardowns. The flip side: if a real sensor session ends and the EGV-path signals don't catch it (e.g. the sensor stops advertising before a `.sessionEnded` EGV arrives), the watch could hold a dead binding. This is the one behavior 206 could have regressed, and it's safety-relevant (stale CGM). Verify explicitly.
3. **Decouple the cosmetic fix from the data work.** DS1 can ship immediately (low-risk, user-visible). The M-items may take a day of telemetry; don't block DS1 on them.

---

## Changelog

### v0.6 (2026-06-10)
- **C-207-1, DS1, UI-207-1/2/3 implemented** in the `Trio` feature-branch working tree (uncommitted, held
  until the build). Files: `G7WatchSensorAdapter.swift` (+60), `ComplicationDebugView.swift` (+64),
  `WatchState.swift` (+4).
  - **C-207-1:** `extendedRuntimeSession(_:didInvalidateWith:error:)` now early-returns (keeps BLE scanning,
    clears `recoveryScheduled`, logs `ext_session_bg_invalidation_ble_kept`) when the error domain is
    `RBSAssertionErrorDomain` AND `lastKnownScenePhase != "active"`; genuine-error/foreground path still
    calls `stop()` + gated recovery. Matched on NSError domain (scene phase is a String).
  - **DS1:** added `describeState(_:)`; routed `extSessionState`, `emitHeartbeat`, and the `ble_gated` log
    through it; fixed the stale state-list comment.
  - **UI-207-2:** `G7DirectBLEStatus.retrieving` → `.waiting` (badge `wait`); `publishConnectionStatus`
    fallback updated; `beginScanIfEligible` now `@discardableResult -> Bool`; `performEndOfSessionTeardown`
    sets `.scanning` only when the scan actually started, else `.waiting`. (Debug Status row keeps
    `rawValue`, now readable.)
  - **UI-207-1:** debug Connects/EGVs rows show raw totals; added `Capture (slots)` (un-clamped) + `Windows`
    rows; replaced clamping `countWithDenominator` with `eligibleSlots`/`slotCaptureText`.
  - **UI-207-3:** `glucoseColor` → `WatchGlucoseColorComputer.shared.bubbleColor`; "Last BLE event" →
    "Last status event"; corrected the stale `willRestoreState` comment (`Was restored` row deferred until
    `bleWasRestored` is wired to the new `will_restore_state` signal).
- **Tooling note:** `opencode-task` (devstral/qwen3-coder agentic) **failed to apply** either C-207-1 attempt
  in this environment (narrated a draft — with a `String`-vs-`Int` scene-phase bug — without writing the
  file); finalized with Claude from the spec. `ollama-task review` (single-pass) worked and was used as the
  second-model pass; it returned 2 false positives (a nesting misread; a nonexistent division-by-zero), both
  verified against source and logged to `.claude/ollama-notes/feedback.md`.
- All three files parse-clean (`swiftc -parse`); **full compile pending the next Trio build.**

### v0.5 (2026-06-09)
- **C-207-2 implemented in the G7SensorKit fork** — `G7SensorKit@40b5871` on `cachrisman/G7SensorKit main`
  (pushed), `patches/02-g7-reading-time-with-seconds.patch` repinned to that SHA. Adds a managerQueue-
  confined `receivedGlucoseSinceConnect` flag (reset on connect-issue in `connectIfNotInFlight`, set in
  `G7Sensor.handleGlucoseMessage`); `scanAfterDelay()` now rescans immediately when the connection dropped
  before any glucose this connection, keeping the 2s grace only after a real EGV. Gated on glucose-received,
  not platform (iPhone post-EGV behavior unchanged).
- **M2 telemetry added in the same commit** — `emitG7Telemetry("will_restore_state", …)` in `willRestoreState`
  (was OSLog-only), so CB background relaunch is now measurable in BetterStack from the next build.
- **Status:** parse/syntax-checked + queue-safety reasoned; **full compile + BetterStack verification pending
  the next Trio build.** Remaining 207 work: C-207-1, DS1, UI-207-1/2/3.

### v0.4 (2026-06-09)
- **Added UI/debug-view bucket (UI-207-1/2/3)** from the Cursor + Codex watch-UI reviews, all verified
  against source. Agreed & adopted: (1) **counter display bug** — `countWithDenominator` caps both the
  Connects and EGVs rows to the slot denom (`min(count,denom)`), so true totals render as `61/61`; show
  raw Connects + raw/unclamped EGV ratio + a separate eligible/gated windows row; (2) **status `retrieving`
  is an overloaded idle fallback** → rename to `waiting`, and stop `performEndOfSessionTeardown` from
  setting `.scanning` when the C1-gated scan was refused (verified `beginScanIfEligible` can return without
  scanning); show a mapped label not the raw enum; (3) **polish** — debug glucose color hard-codes 70/180
  (use `WatchGlucoseColorComputer`), fix the stale `willRestoreState never fires` comment + re-add a
  `Was restored` row once the fork emits `will_restore_state`, verify/relabel "Last BLE event"; plus wire
  or delete the dead status enum cases. **Not adopted (verified):** the `@Bindable` suggestion (`WatchState`
  is already `@Observable`, so `.shared` reads in `body` observe correctly), the "Next connect" semantics
  nit (row is correctly labeled), and the duplicate-`DateFormatter` cleanup (trivial).

### v0.3 (2026-06-09)
- **Incorporated Cursor + Codex reviews** (both telemetry-cross-checked the v0.2 verdict). Corrections:
  - **M1 counts fixed:** v0.2's "205 era 44/183" silently mixed the build-204 seq tail. Build-pure
    numbers are **205: 28/114 (24.6%)**, **206: 302/736 (41.0%)**. Ratio/conclusion unchanged; added a
    frozen, reproducible (build-filtered, seq-bounded) definition.
  - **M2 downgraded to inconclusive:** `willRestoreState` logs via OSLog, not `emitG7Telemetry`, so
    "zero BetterStack events ⇒ never fires" was an invalid inference — retracted. Conclusion now rests
    on entitlement policy + unset `bleWasRestored`; added an action to emit `will_restore_state`.
  - **M3 downgraded** from "no regression observed" to "mostly-clean with a 190-min outlier + 4 @
    25–30 min; `eos_detected=0`; real-EOS path unexercised."
  - **C-207-2 rationale softened:** pre_egv_disconnect is **94% background / 55% pending-auth**, not
    "all pending-auth." Specified a fork-level `hadGlucoseThisConnection` flag, gated on glucose-not-platform.
  - **C-207-1 wording:** "background" → "non-active" (`recovery_skipped` = 5 inactive + 5 background);
    match the RBS error by `NSError.domain`, not `reason.rawValue == -1`.
  - **P1 hardened:** marked 🔒 **blocked on Apple** — special entitlement, not self-enablable, no ETA;
    explicitly removed from the 207 sequence so C-207-1/C-207-2 don't assume it lands.

### v0.2 (2026-06-09)
- **Build-206 telemetry verdict added** (BetterStack, watchOS, hot+S3). Headline: watch EGV capture
  **~24% (205) → ~41% (206)** on the same DXCMed sensor (clean G7-`sequence` metric, phone-confirmed;
  +17pp, ~1.7×). Key reframe: **72% of captures occur with no active extended-runtime session, 47% in
  background** — background BLE central, not `WKExtendedRuntimeSession`, is the EGV workhorse.
- **M1–M4 resolved.** M1 done. M2 ❌ CB restoration never fires (entitlement-gated — confirmed in code).
  M3 ✅ no EOS regression but real-EOS path unexercised (keep open). M4 ✅ D8 fixed session start (14/14);
  residual = RBS-assertion invalidation on backgrounding.
- **Two code candidates promoted to Ready** (validated against code + telemetry, n≈1 device):
  **C-207-1** decouple BLE `stop()` from background ext-session RBS invalidation (highest-impact,
  adapter-only, ship first); **C-207-2** fast-reconnect on `pre_egv_disconnect` (fork, skip the 2s
  `scanAfterDelay` when no glucose received this connection). **P1 strengthened** with M2's code evidence.

### v0.1 (2026-06-07)
- Initial scoping. Decided: DS1 (readable session-state display + comment fix). Data-gated: M1 (per-sensor re-baseline), M2 (confirm CB restoration fires), M3 (confirm D7 didn't miss real EOS — highest risk), M4 (confirm D8 fixed session-start failures, read D9 reasons). Parked: P1 (entitlement), P2 (drop abandoned crashlytics commit / AppDiagnostics orphan), P3 (telemetry classifiers). Carried forward the `rawValue 2 = .running` correction. Reason: 206 shipped; 207 is data-gated on its measured impact.
