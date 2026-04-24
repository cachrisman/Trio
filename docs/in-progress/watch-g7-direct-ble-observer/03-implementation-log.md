# Implementation Log

## Branch/base
- Branch: `feature/watch-g7-direct-ble-observer-a`
- Base requested: `baseline-dev-patches-01-10` (not present locally in this worktree; branch created from available local HEAD).

## Phase log
1. **Scaffold + model extension**
   - Added `TrioComplicationDataSource` enum.
   - Extended `TrioComplicationSnapshot` with `source` and fingerprint persistence.
2. **Observer implementation**
   - Added `G7DirectBLEObserver` with eager central allocation, retrieval-first attach, FEBC scan fallback, reconnect loop, auth/control notify setup, observer-only auth posture, control write opcode `0x4E`, and EGV parse/save callback.
3. **Watch integration**
   - Wired observer into `WatchState` active/inactive hooks without scene-driven hard stop.
   - Added watch-state fields for BLE status / last direct-BLE event / current snapshot source.
   - Tagged WatchConnectivity saves as `.watchConnectivity`; HealthKit saves as `.healthKit`; direct BLE saves as `.directBLE`.
4. **UI integration**
   - Replaced bottom recency-only line with recency + source + BLE status + BLE event age.

## Plan changes during implementation
- Kept no iPhone WatchConnectivity bridge for active peripheral name (chose standalone matching).
- Deferred backfill consumption to a future phase; implemented explicit skip logs.

## Validation
- Static review pass across modified files completed.
- No xcodebuild/ci/local-build run per constraints.

## Final handoff state
- Done: docs, source files, watch-side integration and UI status indicator.
- Pending human follow-up: Xcode target membership wiring and on-device validation against Dexcom watch app direct mode.
