# Build 210 — Implementation plan

**Version:** 1.1 (**LOCKED** — scope frozen 2026-06-16 by Charlie)
**Status:** IN PROGRESS (autonomous overnight run 2026-06-16). **DONE (code, committed on
`feature/watch-g7`):** C-210-1, 2 (incl. #2a/#2b), 3, 4, 5, 8, 9, 10. **DEFERRED to attended:**
C-210-6 / C-210-7 (shared-fork BLE-reconnect re-kick + connect-gate — highest risk, need review +
manual fork push). Build 210 = the watch-app-only subset, built via `--build-current`. See the
[impl log](watch-g7-direct-ble-observer-build210-impl-log.md) for details and the build/deploy status.
**Created:** 2026-06-16
**Last updated:** 2026-06-16

## Theme

Two strands, both feeding the same goal — an **honest, correct watch face**:
1. **Freshness correctness** (verified scan) — the on-watch BLE/HK producers bypass machinery the
   phone/WC path has. Fix the units P0 and the arbitration P1. Source:
   [`complication-freshness/watch-g7-scan-findings-verified.md`](../complication-freshness/watch-g7-scan-findings-verified.md).
2. **Direct-BLE stall handling** (209 plan A5/A6/A7) — detect when the direct path is down, surface
   it, self-heal the Trio-side cases, and notify on the Dexcom-side ones. Full design in the
   [209 plan](watch-g7-direct-ble-observer-build209-impl-plan.md) Sections **A5/A6/A7**.

## Implementation items (C-210-N)

| # | From | What | Files | Tier |
|---|---|---|---|---|
| **C-210-1** | D210-7 / scan #1,#1b,#2b | **Unit-aware display (DONE — code, build-unverified).** *Approach changed:* widget can't read units (`UserDefaults.standard`, not App Group — `WatchGlucoseColorComputer.swift:15,49`), so "format in widget" is out. Instead **bake the unit-correct string watch-side** (mirrors color-hex baking) + pass canonical mg/dL to apply fns. #2b baseline-source → C-210-2; #1b = dead-path edge. See [impl log](watch-g7-direct-ble-observer-build210-impl-log.md). **Needs mmol device.** | `WatchGlucoseColorComputer`, `G7WatchSensorAdapter`, `WatchState` (HK) | **P0** |
| **C-210-2** | D210-8 / scan #2,#2a,#2b | **DONE — code (all three).** (1) `shouldUpdate` scores completeness→priority→content so empty `""`/`"--"` can't clobber a populated reading. (2) #2b: BLE delta seeds from `WatchGlucoseHistoryStore` at cold start. (3) #2a: phone now sends `g7_sequence` from the live `G7CGMManager` (correlated within 90 s of the stored reading; direct-G7 only) on both the main + complication payloads, arming the watch's sequence guard. See [impl log](watch-g7-direct-ble-observer-build210-impl-log.md). Build-unverified. | `TrioComplicationDataStore`, `G7WatchSensorAdapter`, `WatchGlucoseHistoryStore`, `AppleWatchManager` | **P1** |
| **C-210-3** | D210-1 | **Capture success rate on main face** (`67 / 248` captures/slots) replacing readings/connects | `TrioMainWatchView` | P1 |
| **C-210-4** | D210-2 / A7 | **Direct-BLE-stall detection + indicator + telemetry.** Cross-source freshness signal; dormant-vs-starved + Dexcom-vs-Trio classification; tiered UI (`stalled`/`unavailable`); `direct_ble_stall_detected` event; false-positive guards | `G7WatchSensorAdapter`, `WatchState`, BLE-status UI | P1 |
| **C-210-5** | D210-2 / A7 | **Inferred stall notification** — *"Watch direct sensor link down — on phone relay. Restart the Dexcom Watch app."* with the non-negotiable alarm-fatigue guards (sustained Dexcom-side hard stall only, debounce per-episode, fire only when it costs data) | `WatchState` / notification path | P1 |
| **C-210-6** | D210-3 / A7 | **Stall recovery re-kick when bound-but-stalled.** Extend `connectionEventDidOccur` to re-kick attach when **bound AND stalled**; hard-gate against the A5 storm (never when bound-and-healthy). **Shared-fork change → phone impact** | fork `G7BluetoothManager` + adapter | P1 |
| **C-210-7** | D210-4 / A5 | **Connect-gate reconnect-storm throttle.** Un-shelve the connect-gate delegate (review 2.2); throttle rapid reconnects (soak saw 16 `did_connect`/5-min). **Shared-fork change** | fork connect path + adapter | P1 |
| **C-210-8** | D210-5 / A6 | **Dexcom-session-dependency instrumentation.** Infer Dexcom-watch-app session loss from absence of `connection_event` windows while phone stays fresh (the real 06-13 outage cause). Pairs with C-210-4 | `G7WatchSensorAdapter`, telemetry | P1 |
| C-210-9 | scan #3 (narrow) | **Reload-generation launch reconciliation.** Compare persisted `reloadGenerationKey` vs `widgetObservedGenerationKey` at launch/resume so an unserviced reload recovers across suspension (the rest of #3 was overstated — no trailing-flush rework) | `TrioComplicationDataStore` | low / fast-follow |
| C-210-10 | scan #6 | **HK same-epoch value-compare.** Compare value as well as epoch before skipping, so a same-epoch correction isn't dropped (real but ~unreachable for G7 EGVs; preserves idempotency) | `WatchState` (HK path) | low / fast-follow |

> **Refuted findings — explicitly NOT in 210** (verified against code, do not re-litigate): scan
> **#4** "widget rolls back the watermark" (write not compiled into the widget target), **#1a**
> (already unit-aware), **#5** (15-min guard exists; proposed fix worse), **#7** (predecessor is
> correct), **#8** (cadence makes reorder unreachable; guards neutralize it), **#9** (clock-mixing
> premise false; foreground-only), **#10** (`dedupQueue` never writes). Details in the verified doc.

## Build order & sequencing

1. **C-210-1 first (DONE — code)** — unit-aware display. *No snapshot-model change* (the widget can't
   read units; see C-210-1 note) — instead the unit-correct string is baked watch-side. Do before
   arbitration so #2's completeness logic operates on sanitized display strings as they actually ship.
2. **C-210-2** — arbitration + `g7_sequence`; also do the #2b delta-baseline-source change here
   (seed the BLE delta from `WatchGlucoseHistoryStore` instead of the in-memory baseline).
3. **C-210-3** — capture-rate display (independent, small; can land any time).
4. **C-210-4 → C-210-5 → C-210-8** — the stall *detection/notification/instrumentation* cluster
   (watch-only, no fork). Build detection first; notification and Dexcom-session instrumentation
   consume its signal.
5. **C-210-6, C-210-7** — the **shared-fork** items (re-kick + connect-gate). Group them: both touch
   the `G7SensorKit` fork's connection path, both have phone impact, and #6 must be hard-gated
   against the #7 storm. Per workflow: edit fork → push fork to `main` → repin/regenerate the
   relevant patch(es) → patch-test → build. Do these **after** the watch-only items are stable.
6. **C-210-9, C-210-10** — fast-follows; include if the build has room, drop without affecting scope.

**Fork/patch note:** C-210-6 and C-210-7 are shared-fork changes (affect the phone too). They follow
the fork-push + patch-repin flow in AGENTS.md / the feature-branch workflow doc — not a feature-branch
commit alone. Watch the `Files in patch: N` count if any new files are added.

## Verification strategy

- **C-210-1 (P0):** must be verified on an **mmol/L-configured device** (or the BLE/HK path traced
  end-to-end) — the bug is invisible on mg/dL test devices, which is why it shipped. Confirm the face
  shows `5.6`, not `100`, on a BLE-fed reading. Add a unit test on the snapshot→display formatting.
- **C-210-2:** unit-test `shouldUpdate` for the ±1s + empty-field-clobber cases; confirm a barer WC
  reading no longer overwrites a complete BLE one. Confirm `g7_sequence` appears in the phone payload.
- **C-210-4/5/8:** soak against BetterStack — `direct_ble_stall_detected` should fire within ~15 min
  of a real stall (would have caught 06-13); notification debounce holds; no false fires on mild gaps.
- **C-210-6/7:** soak the reconnect rate — re-kick reduces the 10–15 min missed-window gaps WITHOUT
  raising `did_connect` storms; connect-gate caps the 16-connect bursts.

## Open items

- None blocking. Scope is locked. Fast-follows (C-210-9/10) are the only discretionary items.

## Changelog
### v1.0 (2026-06-16) — LOCKED
- Scope frozen by Charlie: D210-7 included in 210 (P0, not a separate hotfix); all stall items in.
- Mapped budding-list D210-1..5,7,8 + verified-scan fast-follows (#3 narrow, #6) to C-210-1..10.
- Recorded the 7 refuted scan findings as explicitly out-of-scope. Set build order (canonical-model
  first; fork items grouped last; mmol-device verification mandatory for the P0).
