# Trio Watch Dexcom G7 Direct BLE Observer — Implementation Plan (v1)

## New files
- `Trio Watch App Extension/G7DirectBLEObserver.swift` — BLE observer central/peripheral delegate, attach ladder, auth observation, control write, EGV parsing, reconnect.
- `Trio Watch Shared/TrioComplicationSnapshot.swift` — snapshot + source model used by watch app and future complication target.
- `Trio Watch Shared/TrioComplicationDataStore.swift` — persisted snapshot store with dedup/winner logic.

## Existing files modified
- `Trio Watch App Extension/WatchState.swift` — observer lifecycle bridge, source attribution state, direct BLE snapshot writes.
- `Trio Watch App Extension/TrioWatchApp.swift` — scene phase → observer lifecycle wiring.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — inject shared watch state from app root.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — source/status indicator UI.
- `Trio/Sources/Models/WatchMessageKeys.swift` — additive keys for source metadata.

## Phases
1. **Scaffold models/store** (snapshot + source + datastore).
2. **Central lifecycle + attach ladder** (restore-backed manager, retrieve/scan).
3. **GATT discovery + safety posture** (auth/control enable, explicit J-PAKE skip).
4. **EGV request + parse + store handoff**.
5. **WatchState integration + scene lifecycle**.
6. **UI indicator integration**.
7. **Static review and docs log finalization**.

## Sequencing rationale
Store/model first unblocks observer and UI source attribution, then BLE transport, then WatchState/UI integration.

## Planned tests/checks
- Static `git diff` review of BLE safety constraints (no auth-init writes, no J-PAKE writes).
- Optional targeted unit tests were deferred in this pass because no stable parser fixture corpus is available in-repo for watch target.
