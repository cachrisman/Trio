# Implementation Plan v1

## New files
- `Trio Watch App Extension/G7DirectBLEObserver.swift` — CoreBluetooth observer manager, attach/reconnect, protocol handling, EGV parse, logging.
- `Trio Watch Shared/TrioComplicationDataSource.swift` — source attribution enum shared by watch app + complication data model.
- `docs/in-progress/watch-g7-direct-ble-observer/01-design.md`
- `docs/in-progress/watch-g7-direct-ble-observer/02-implementation-plan.md`
- `docs/in-progress/watch-g7-direct-ble-observer/03-implementation-log.md`

## Modified files
- `Trio Watch Shared/TrioComplicationDataStore.swift` — add source field to `TrioComplicationSnapshot` + fingerprint.
- `Trio Watch App Extension/WatchState.swift` — observer wiring, BLE status/source state, source tagging on save paths.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — inline BLE/source status line.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — hydrate source from cached snapshot.

## Phases
1. Add source attribution model in shared snapshot/store.
2. Add observer manager with central lifecycle, attach ladder, discovery, notify, control write, EGV parse.
3. Wire observer into watch foreground lifecycle and complication store save path.
4. Surface status/source/last-BLE-event signal in main watch view line.
5. Static review and command-level checks.

## Tests planned
- Static checks only in this pass (`swift` compile not run by instruction).
- `git diff` + targeted file re-read for state transitions and prohibited auth writes.
