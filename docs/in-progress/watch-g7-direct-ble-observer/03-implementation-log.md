# Watch G7 direct BLE observer — implementation log

**Version:** v1  
**Created:** 2026-04-24 16:02 CEST  
**Last updated:** 2026-04-24 16:02 CEST  

---

## Branch and base

- **Branch:** `feature/watch-g7-direct-ble-observer-clean-cea9`  
- **Base commit:** `1aa70ac077ef1492cddfce2bd39e0b2481f3d55c` (`dev`)  

---

## Per-phase log

| Phase | What we did | Files | Notes |
|--------|-------------|--------|--------|
| Design | Wrote G7 eavesdrop design using public G7SensorKit + DiaBLE source (web); answered DQs | `01-design.md` | Did not read `docs/in-progress/watch-direct-ble-cgm/` |
| Constants/parse | UUIDs, `G7GlucoseMessage`, `G7AuthChallengeRxMessage` | G7 `*.swift` in extension | Aligned to LoopKit G7SensorKit on GitHub for wire format |
| Store + pipeline | `TrioComplication*`, `WatchState+G7ComplicationPipeline` | as above + `WatchState` | Phone path calls `applyPhonePathToComplicationPipeline()` at end of `processRawDataForWatchState` |
| BLE | `G7DirectBLEManager` (queue, ladder, `nil` char discover on cgm, EGV 0x4E + 4m50s timer) | `G7DirectBLEManager.swift` | J-PAKE: discover on serviceB, log only, no notify |
| UI | `TrioMainWatchView` + `GlucoseTrendView` recency line | 2 view files | Scene `.active` starts manager |
| Tests | Hex fixtures in `Unit Tests.swift` | `Trio Watch App Tests/Unit Tests.swift` | **Not** run: no Xcode in agent |

## Deviations from design (during implementation)

- None that contradict the design doc; minor: `lastG7DirectBLEEventDate` is updated on G7 EGV to drive `[Xm]` in the recency line.

## Validation

- **Static review:** re-read G7 `DirectBLE` manager and pipeline glue for queue/MainActor use.  
- **Tests:** `xcodebuild` not run (per user constraints). `scripts/patch-test.sh` N/A (no patch stack change).  

## Handoff: done vs pending

| Done | Pending (human) |
|------|------------------|
| Design + plan + log; Swift sources in extension paths | **Add** new files to the Watch App Extension + Test targets in Xcode |
| Scene-phase start + UI line | **Build** with `ci/local-build.sh` or local Xcode; fix any module/import issues (e.g. `WidgetKit` in extension) |
| `event=g7_ble_*` via `G7BLELog` | On-device: verify auth `1/1`, EGV stream, and BetterStack logs |

**Note:** Reference `Archive.zip` for DiaBLE/G7 was **not** in the repo; implementation used **public GitHub** sources (LoopKit/G7SensorKit, gui-dos/DiaBLE) in line with the prompt’s authority model.

## Changelog

### v1 (2026-04-24 16:02 CEST)

- Logged implementation phases, base SHA, and handoff for Xcode wiring and device validation.
