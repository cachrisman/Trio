# Implementation Plan v1

## New files

1. `Trio Watch App Extension/G7DirectBLEObserver.swift`
   - CoreBluetooth observer manager (attach, discovery, notify, request EGV, parse, reconnect, logs).
2. `Trio Watch Shared/TrioComplicationSnapshot.swift`
   - Shared snapshot schema and source attribution enum.
3. `Trio Watch Shared/TrioComplicationDataStore.swift`
   - Shared persistence/reload surface used by watch observer.

## Existing files to modify

1. `Trio Watch App Extension/WatchState.swift`
   - Observer wiring and snapshot-to-UI application; source/status state.
2. `Trio Watch App Extension/TrioWatchApp.swift`
   - Scene-phase start trigger for observer lifecycle.
3. `Trio Watch App Extension/Views/GlucoseTrendView.swift`
   - Glanceable source + BLE status + last BLE event recency indicator.
4. `Trio/Sources/Models/WatchMessageKeys.swift`
   - Add source attribution keys (`readingDate`, `readingSource`).
5. `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
   - Send phone-relay source attribution fields in watch payload.

## Phases

1. **Scaffolding**
   - Add shared snapshot/store schema.
2. **Observer core**
   - Add central allocation, retrieval+scan attach ladder, connect/discovery path.
3. **Observer protocol path**
   - Auth observe-only + control notify + EGV request + lightweight parse.
4. **Persistence handoff**
   - Save snapshot to complication store and publish callback to watch state.
5. **UI status/source**
   - Show source-of-reading and direct-BLE status/recency inline in main view.
6. **Phone relay attribution**
   - Mark legacy watch updates as `phone_relay`.
7. **Docs and review**
   - Write design/plan/log and static self-review.

## Dependencies / sequencing rationale

- Shared snapshot/store first to avoid temporary ad-hoc payload contracts.
- Observer before UI so UI binds to concrete status/snapshot states.
- Phone-side attribution added last and additive to avoid changing routing semantics.

## Planned validation

- Static review only (per constraints):
  - Ensure no auth-init writes/J-PAKE ownership writes exist.
  - Ensure `WatchState` and store interactions run on main actor paths.
  - Ensure logs include `event=g7_ble_*` and connect source attribution.
- No `xcodebuild`, no project sync.
