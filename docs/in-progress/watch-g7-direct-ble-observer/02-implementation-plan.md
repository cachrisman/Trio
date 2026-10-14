# Implementation plan

## New files
- `Trio Watch App Extension/G7DirectBLE/G7DirectBLEManager.swift` — watch observer CoreBluetooth manager, protocol sequencing, reconnect, structured logging.
- `Trio Watch Shared/TrioComplicationDataStore.swift` — shared snapshot/store with source attribution and direct-BLE status tracking.
- `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` — design decisions and DQ answers.
- `docs/in-progress/watch-g7-direct-ble-observer/03-implementation-log.md` — implementation trace and handoff notes.

## Existing files to modify
- `Trio Watch App Extension/TrioWatchApp.swift` — scene phase start/resume hooks for BLE observer.
- `Trio Watch App Extension/WatchState.swift` — direct-BLE snapshot application + source/status fields for UI.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — glanceable BLE/source indicator in main view.
- `Trio/Sources/Models/WatchMessageKeys.swift` — additive `readingSource` key.
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — populate reading source as `watchConnectivity`.

## Phases
1. **Scaffold shared data model/store**: snapshot/source/status types + persistence/reload methods.
2. **Build BLE manager skeleton**: central manager lifecycle, scene hooks, restoration, logging helper.
3. **Attach strategy**: retrieve-connected fast path, scan fallback, tolerant matching, connect source attribution.
4. **Discovery/protocol sequence**: discover service/chars, auth notify observe-only, control notify, EGV request writes.
5. **Parse/store handoff**: EGV parse -> snapshot -> store save + notification broadcast.
6. **UI integration**: watch state receives direct BLE snapshots and shows source/status/last-event recency in main view.
7. **Reconnect hardening**: connect timeout + bounded retry backoff + blocked state events.
8. **Documentation pass**: design/plan/log finalize, explicit constraints and open risks.

## Dependencies and sequencing rationale
- Store and source model first to avoid ad hoc state threading later.
- BLE manager before UI to ensure indicator surfaces real state transitions.
- UI changes after handoff path to keep display model grounded in emitted snapshots.

## Planned tests/checks (non-Xcode)
- Static review of changed files for observer-only auth posture (no auth writes/J-PAKE writes).
- Command-line checks: `git diff`, `git status`, targeted grep for forbidden auth-write patterns.
