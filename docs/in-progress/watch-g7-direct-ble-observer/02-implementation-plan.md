# Watch G7 Direct BLE Observer — Implementation Plan v1

## New files
- `Trio Watch App Extension/G7DirectBLEObserver.swift` — CoreBluetooth observer lifecycle, attach flow, auth observation, control request cadence, payload handling.
- `Trio Watch App Extension/WatchState+G7DirectBLE.swift` — WatchState integration + observer delegate bridge + snapshot persistence path.
- `Trio Watch Shared/TrioComplicationDataSource.swift` — source attribution model shared by app + complication data pipeline.

## Existing files to modify
- `Trio Watch Shared/TrioComplicationDataStore.swift` — extend `TrioComplicationSnapshot` with optional source attribution.
- `Trio Watch App Extension/WatchState.swift` — observer lifecycle hooks + source tagging on existing snapshot save paths.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — inline BLE/source status indicator in recency area.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — restore source attribution when hydrating from cached snapshot.

## Phase ordering
1. Shared model extension (source attribution).
2. Observer core implementation (central/scanning/connect/discovery/auth/control/request/reconnect).
3. WatchState wiring (scene hooks + delegate outputs + save path).
4. UI indicator integration in existing recency label.
5. Static review pass over all changed files.
6. Write implementation log and handoff notes.

## Dependencies and rationale
- Shared snapshot source support lands first to avoid temporary parallel state paths.
- BLE core precedes UI to ensure visible status is driven by real observer state.
- WatchState bridges all side effects through existing application state and store interfaces.

## Planned tests/checks for this pass
- Static diff review only.
- Optional syntax-only checks were skipped because this pass explicitly excludes project wiring/buildability verification.
