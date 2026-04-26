# Trio Watch G7 Direct BLE Observer Implementation Plan

**Version:** v2  
**Status:** In Progress  
**Created:** 2026-04-24 20:41 CET  
**Last updated:** 2026-04-24 20:57 CET

## Swift files to create

- `Trio Watch App Extension/G7DirectBLEObserver.swift` - long-lived CoreBluetooth observer, G7 UUID/opcode constants, auth observation, EGV request cadence, EGV parser, and complication-store handoff.

## Existing files to modify

- `Trio Watch Shared/TrioComplicationDataStore.swift` - add optional source attribution to `TrioComplicationSnapshot` and source-aware dedup.
- `Trio Watch App Extension/WatchState.swift` - start observer on active scene, tolerate inactive/background, track direct-BLE status/source recency, and apply direct-BLE snapshots to the visible UI state.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` - restore cached snapshot source into `WatchState`.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` - show source-of-reading and BLE observer status near the existing recency label.

No iPhone-side files are modified because the implementation uses standalone DiaBLE-style matching.

## Phases and ordering

1. **Reference review**
   - Fetch all DiaBLE and G7SensorKit files from the prompt.
   - Extract high-fidelity mechanics: central allocation, retrieval/scan ladder, discovery behavior, auth notification, control notification, and G7 EGV parsing.
2. **Scaffolding integration**
   - Extend the existing shared snapshot instead of creating a parallel store.
   - Add watch-state fields for current source and BLE observer state.
3. **Central + attach ladder**
   - Add an eager restoration-backed central manager on a serial queue.
   - Try identifier retrieval, system-connected service retrieval, then broad scan.
4. **Discovery + observer auth**
   - Discover services/characteristics broadly.
   - Subscribe to authentication notifications.
   - Explicitly log and skip J-PAKE.
5. **Control request + sustained delivery**
   - Enable control notifications after authenticated auth status or timeout fallback.
   - Write `0x4e` with response immediately and every 60 seconds while connected.
6. **EGV parse + store handoff**
   - Parse G7 EGV payload fields using G7SensorKit layout.
   - Save a source-tagged `TrioComplicationSnapshot` through `TrioComplicationDataStore.shared.save(..., minInterval: 5)`.
   - Apply the snapshot to `WatchState` on `MainActor`.
7. **UI indicator**
   - Add inline source and BLE status row under the existing recency label.
8. **Reconnect**
   - Retry after scan timeout, connect failure, disconnect, discovery failure, and write failure using bounded backoff.
   - Do not scene-gate reconnect once scheduled.
9. **Static review**
   - Re-read touched files and inspect for source compatibility, unsafe auth writes, timer teardown hazards, and forbidden project/build actions.

## Dependencies and sequencing rationale

- Source attribution must precede UI work so the UI can display the serving path without timestamp inference.
- The observer is isolated to the watch extension because no shared/iPhone protocol or WatchConnectivity bridge is needed.
- `WatchState` and data-store interactions are sequenced through `MainActor` from CoreBluetooth callbacks.
- Target membership is intentionally left for a later human Xcode step per the task constraints.

## Narrow tests considered

- Payload parsing unit tests would be useful for `G7ObservedGlucose` sample vectors from `G7SensorKit/Messages/G7GlucoseMessage.swift`.
- This pass did not add tests because the new observer file is not wired into the Xcode project and the task explicitly excludes project-file sync/build validation. Static parser review was used instead.

## Changelog

### v2 (2026-04-24 20:57 CET)
- Removed `TrioWatchApp.swift` from the final modified-file list because lifecycle integration stayed inside `WatchState`.
- Keeps the plan aligned with the final implementation surface and avoids implying an unchanged file needs review.

### v1 (2026-04-24 20:41 CET)
- Added the implementation plan for the clean watch-only observer.
- Captured file scope and sequencing so follow-up target-membership and device verification can proceed without reinterpreting the design.
