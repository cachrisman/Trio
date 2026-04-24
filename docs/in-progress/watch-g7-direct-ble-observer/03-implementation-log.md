# Implementation Log

- Branch: `feature/watch-g7-direct-ble-observer-a`
- Base reference requested: `baseline-dev-patches-01-10` (not present as a local branch in this worktree; implementation performed from current branch baseline).

## Phase log
1. **Reference fetch**
   - Raw `curl` to GitHub failed in shell due network 403 in this environment.
   - Successfully fetched all required DiaBLE and G7SensorKit file URLs through the web fetch tool and used those contents for protocol/flow alignment.

2. **Source attribution plumbing**
   - Added `TrioComplicationDataSource` enum.
   - Extended `TrioComplicationSnapshot` + fingerprint to carry optional source.

3. **Direct BLE observer implementation**
   - Added clean-room `G7DirectBLEObserver` with eager central allocation, retrieval+scan attach ladder, auth observation, control-write request, reconnect.
   - Added `G7DirectBLEProtocol` for UUID/opcode/auth/glucose parsing.

4. **WatchState and UI integration**
   - Added BLE status/source/last-event fields.
   - Started observer on foreground active path.
   - Tagged HealthKit and WatchConnectivity snapshot writes with source.
   - Updated glucose trend footer to show `SRC`, `BLE` status, and BLE recency.

5. **iPhone additive key**
   - Added `complication_source` key and populate as `watch_connectivity` in watch payload dictionary.

## Deviations from plan
- No iPhone-bridged active-name filtering was implemented; used DiaBLE-style standalone matching only.
- Backfill parsing left as explicit logged skip in this pass.

## Validation performed
- Static review of all modified/new files.
- Grep checks for `g7_ble_` events and source-key propagation.
- No xcodebuild/local-build/sync-project invocation (per constraints).

## Final handoff state
- Implemented code + docs complete for this pass.
- Pending human follow-up: Xcode target membership wiring for new files, device validation/tuning, possible opcode/cadence refinements based on logs.
