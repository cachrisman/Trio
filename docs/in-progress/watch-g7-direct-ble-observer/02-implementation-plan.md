# Implementation Plan

## New files
- `Trio Watch App Extension/G7DirectBLEProtocol.swift` — G7 UUID/opcode/auth/glucose parser helpers.
- `Trio Watch App Extension/G7DirectBLEObserver.swift` — central manager lifecycle, attach/discovery/auth-observe/control-write/reconnect.
- `Trio Watch Shared/TrioComplicationDataSource.swift` — snapshot source attribution enum used by watch + shared store.
- `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` — design choices.
- `docs/in-progress/watch-g7-direct-ble-observer/03-implementation-log.md` — execution log.

## Existing files to modify
- `Trio Watch Shared/TrioComplicationDataStore.swift` — snapshot model extension + dedup fingerprint source.
- `Trio Watch App Extension/WatchState.swift` — observer start hook, source/status state, source-aware snapshot saves.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — inline source + BLE status/recency indicator.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — consume cached snapshot source.
- `Trio/Sources/Models/WatchMessageKeys.swift` — additive `complication_source` key.
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — include `.watchConnectivity` source in watch payload.

## Phases
1. Add source-attribution model in shared snapshot/store.
2. Add G7 protocol constants/parsers.
3. Implement observer manager lifecycle + CB delegate flow.
4. Integrate observer start + watch state fields.
5. Route direct BLE snapshots to store and watch state.
6. Update main watch UI to show source + BLE status.
7. Add docs and run static review.

## Sequencing rationale
Observer implementation depends on source-attribution plumbing first so saved readings can be surfaced immediately in UI and diagnostics.

## Tests planned
No compile/build tests by scope constraint. Validation is static review + grep-based checks for required event naming and source-plumbing coverage.
