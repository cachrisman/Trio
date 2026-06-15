# Codex review prompt — Trio build 205 (watch UX/persistence/data + G7 capture reliability)

You are reviewing an **uncompiled** change set for bugs and correctness/concurrency/edge-case issues.
Because it has **not been compiled yet**, also flag compile-level problems: type mismatches, optional
mishandling, access levels (e.g. a `private` symbol referenced cross-type), missing imports, enum/case
typos, and Swift-concurrency/isolation errors.

## Scope (three repos)

1. **Trio** — branch `feature/watch-g7-direct-ble-observer-synthesis`, commits `68d4419..HEAD`
   (the 10 commits whose subjects start with `build205(`). Files changed:
   - `Trio/Sources/Helpers/GlucoseHueColor.swift` (new), `…/Helpers/DynamicGlucoseColor.swift`
   - `Trio Watch App Extension/WatchGlucoseColorComputer.swift` (new), `WatchGlucoseHistoryStore.swift` (new)
   - `Trio Watch App Extension/WatchState.swift`, `G7WatchSensorAdapter.swift`,
     `Views/TrioMainWatchView.swift`, `Views/ComplicationDebugView.swift`
   - `Trio/Sources/Models/WatchState.swift`, `WatchGlucoseObject.swift`, `WatchMessageKeys.swift`
   - `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, `Model/Helper/GlucoseStored+helper.swift`
2. **G7SensorKit fork** — commit `74824a1` (`G7SensorKit/G7CGMManager/G7PeripheralManager.swift`) — C3.
3. **Trio (dev branch)** — commit `9f3adf7a` (`scripts/sync_project_files_config.rb`) — registers the new
   shared file for the watch target.

A full implementation log with rationale + intentional deviations is at
`docs/in-progress/watch-g7-direct-ble-observer/watch-g7-direct-ble-observer-build205-impl-plan.md`
(read the "Implementation log (build 205)" section first).

## What the change set does (so you can judge intent)

The watch now owns glucose **color** and **unit** rendering locally; the phone stops sending color strings
and display-unit chart values and instead sends canonical **mg/dL** + the user's color settings. A new
on-watch rolling-24h history store feeds the chart (incl. on cold start). Three capture-reliability levers
gate BLE scanning behind runtime eligibility (C1), key sensor identity on name+activation-epoch with an
EOS quarantine (C2), and make the shared `configureAndRun` fail-closed with a bounded retry (C3).

## High-priority correctness targets (check each)

1. **Color parity (W5).** `WatchGlucoseColorComputer.hexFromHSB` must reproduce the phone's
   `toHexString()` byte-for-byte: `Int(x*255)` **truncation** (not rounding) and **uppercase** `%02X`.
   Verify the HSB→RGB math, the hard-coded `55/220` dynamic bounds, saturation 0.6 / brightness 0.9 in the
   shared `glucoseHueComponents`, the white-strictly-in-range bubble rule (`> low && < high`), and that the
   static hex constants are treated as the source of truth (they were captured on iOS 26.5, light mode).
2. **Watch-local unit conversion.** `displayValue(forMgDl:)` replicates `Int.asMmolL`
   (× exchange-rate `0.0555`, `NSDecimalRound` scale 1, `.plain`). Confirm it matches the phone exactly and
   that the chart y-axis (phone-sent, display units) and chart points stay on the same scale.
3. **`WatchGlucoseHistoryStore` concurrency.** It serializes via a private `DispatchQueue` with `queue.sync`
   in every public method (it is NOT `@MainActor`). Check for: re-entrant `queue.sync` deadlocks (does any
   public method call another?), correctness of the ±1s / "either sequence nil" dedup, source-priority
   replacement (ble>wc>hk), prune + `suffix(288)`, atomic write, and that callers from BLE/HK/WC/startup
   contexts are safe.
4. **P2 wire contract.** The chart entry key was renamed `glucose`/`color` → `glucoseMgDl` (Int, no color)
   end-to-end. Verify: no remaining reader of the old keys or of `currentGlucoseColorString` from the wire;
   `StoredGlucoseReading.from(wcEntry:source:)` is NSNumber/Date-bridging-safe; `currentGlucoseMgDl` is
   validity-gated (`>= 25`) on decode; phone DTO `WatchState` `==`/`hash` no longer reference `.color`.
5. **Snapshot-baking invariant.** All four snapshot builders (WC `saveComplicationSnapshot`,
   `forceComplicationUpdate`, BLE `handleSensorDidRead`, HK `finishHKGlucoseObserverFetch`) must bake the
   bubble hex only when mg/dL is valid and set `glucoseColor = nil` otherwise — **never bake red for
   no-data**. Confirm `TrioComplicationSnapshot.glucoseColor` is `String?` and the nil path is correct.
6. **W7 ratio invariant.** `expectedSlotsToday` is a monotonic high-water (`slotEpoch > lastExpectedSlotEpoch`,
   today-only); `gatedSlotEpochsToday` is a Set inserted at C1's gate and **removed when an EGV is captured
   in that slot** (EGV-save hook). The debug ratio `count / max(0, expected − gated)` must never exceed 100%.
   Check `advanceDayIfNeeded` is forward-only (`dayStart > storedDay`) and resets all daily state incl. the
   high-water + set. Confirm slot accumulators are **not** reset on sensor swap (only the sequence anchor is).
7. **C1 runtime gate.** Every scan entry routes through `beginScanIfEligible` (`start`, `applyNewSensorName`,
   EOS teardown, disconnect-rescan). `performScanForNewSensor` clears `boundSensorName` itself (deferred
   clear). Deferral is consumed in `applyForegroundActiveEntry` + `extendedRuntimeSessionDidStart` with
   clear-before-reissue. Verify `.newSensor` precedence is preserved across deferral and that `start()`'s
   `isStarted`/timers run before the gate (never gated wholesale).
8. **C2 identity state machine.** Scrutinize `isQuarantined` truth table (same name blocks unless strictly
   newer epoch; different name escapes; epoch-bearing vs name-only quarantine = accept/promote; missing-epoch
   same-name = blocked), the swap-vs-promotion decision, `applyNewSensorName(_:force:)` for the same-name
   newer-epoch case, `pendingSensorSwap` set **and cleared** (no leak that misclassifies a later routine
   rebind), EOS recording identity into quarantine **before** nilling `expectedSensorName`/epoch, and the
   persisted `storedActivationEpochSeconds` lifecycle. Confirm the watch reader sits behind the existing
   build-time freshness gate and that `SensorIdentity`/`setActiveSensorIdentity` access levels allow the
   cross-type call from `WatchState`.
9. **C3 fork (`configureAndRun`).** The `catch` must `return` (skip `block(self)`) — confirm the `return`
   exits the returned closure, not just the inner do/catch. Review `scheduleConfigurationRetry`: first-wins
   (never replaces a pending retry — preserves the auth subscription), clears the work-item slot before
   re-entering `perform`, abandons if `peripheral.state != .connected`, capped attempts + backoff, reset on
   config success, cancel on `peripheral`/`delegate` `didSet`, `[weak self]`. All confined to `queue`.
   This path is shared with the iPhone CGM — flag any iPhone-side regression.
10. **W3 persistence.** IOB/COB/lastLoopTime cache is keyed on `lastWatchStateUpdate` (phone build time),
    NOT `Date()`; restore only when age ∈ [0, 30 min] (rejects stale AND future-dated/clock-skew).
11. **Threading.** `WatchState` is `@Observable` (not `@MainActor`). Confirm `@Observable` UI property
    writes happen on the main thread in every path (WC finalize, BLE `applyG7DirectBleSnapshot`, HK main
    block, `onAppear`), and that calling the non-isolated history store from these contexts is sound.

## Intentional deviations (do NOT report these as bugs — verify they're implemented as described)

- Units are watch-local (`cachedUnitsRaw` + `displayValue`) instead of the phone's `GlucoseUnits`/`asMmolL`,
  because those live in `BloodGlucose.swift` which is not in the watch target.
- `WatchGlucoseHistoryStore` uses a serial `DispatchQueue` rather than `@MainActor` (the watch WC chain is
  not actor-isolated).
- `GlucoseTrendView` is unchanged; `currentGlucoseColorString` is repurposed as the watch's local bubble-hex
  store (white default ⇒ no-data is never red; robust to snapshot restore which has no mg/dL).
- W6 removed; W9 deferred. `bleFirstSequenceToday`/`bleLastEGVSequence` are knowingly dead-after-W7 but kept.

## Output

Group findings by severity (blocker / high / medium / low). For each: `file:line`, the issue, why it's
wrong, and a concrete fix. Call out any **compile-breaking** issue explicitly (this has not been built).
Note any place where the watch and phone could disagree on a glucose value, a color, or a unit.
