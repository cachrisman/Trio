# Watch G7 Direct BLE Observer — Implementation Plan

## New files
- `Trio Watch App Extension/G7DirectBLEObserver.swift` — CoreBluetooth observer manager and protocol flow.
- `Trio Watch App Extension/G7DirectBLEStatus.swift` — glanceable BLE status model for UI.
- `Trio Watch Shared/TrioComplicationDataSource.swift` — shared snapshot source attribution enum.

## Existing files to modify
- `Trio Watch App Extension/TrioWatchApp.swift` — scene-phase start/resume hooks.
- `Trio Watch App Extension/WatchState.swift` — observer status/source fields and direct BLE state updates.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — load source from cached snapshot.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — add BLE status/source indicators.
- `Trio Watch Shared/TrioComplicationDataStore.swift` — extend snapshot/fingerprint model with source attribution.

## Phases
1. Add shared source attribution model.
2. Extend snapshot/store model with source field.
3. Implement BLE observer manager (central lifecycle, attach ladder, discovery, auth observe, control write, parse/save, reconnect).
4. Wire scene lifecycle start/resume into watch app.
5. Add watch state fields for BLE status + last event + source.
6. Add UI status/source indicators in main glucose trend view.
7. Static review pass for invariants and anti-patterns.

## Sequencing rationale
Data model first prevents temporary parallel storage pathways. Observer second establishes data path. UI last consumes stable state fields.

## Tests for this pass
No compile/build per constraints. Validation is static review + targeted grep checks for forbidden auth writes/J-PAKE ownership behavior and scene-gated reconnect anti-patterns.
