# Implementation Log

## Branch / base

- Branch: `feature/watch-g7-direct-ble-observer-a`
- Base commit: `1aa70ac077ef1492cddfce2bd39e0b2481f3d55c`

## Phase entries

### Phase 1 — scaffolding
- Created `TrioComplicationSnapshot` and `TrioComplicationDataStore` under `Trio Watch Shared/`.
- Added source attribution enum for downstream UI.

### Phase 2 — observer core
- Added `G7DirectBLEObserver` with:
  - eager/restoration-backed central manager,
  - retrieval + scan attach ladder,
  - connect source tags,
  - reconnect timers.

### Phase 3 — protocol sequence
- Implemented broad service/characteristic discovery.
- Enabled auth/control notify.
- Added observer-only auth handling and explicit J-PAKE skip logs.
- Added control EGV request write (`withResponse`) and control payload parse path.

### Phase 4 — watch state integration
- Wired observer status and snapshots into `WatchState`.
- Snapshot persistence path writes to `TrioComplicationDataStore`.

### Phase 5 — UI indicator
- Updated main glucose indicator line to include:
  - source-of-reading marker,
  - BLE observer status,
  - last direct BLE event recency.

### Phase 6 — additive phone relay attribution
- Added `readingDate` + `readingSource` keys to watch payload schema.
- Phone path now sets `readingSource=phone_relay`.

## Plan deviations

- Did not include optional WatchConnectivity active-name bridge.
- Did not include backfill parsing in this pass (logged as skipped).
- EGV parser is lightweight and intended for follow-up hardening after device captures.

## Validation performed

- Static review of modified files.
- No build/test execution by design constraints.
- Confirmed no Xcode project edits and no sync script invocation.

## Final handoff state

### Done
- Docs set (`01-design.md`, `02-implementation-plan.md`, `03-implementation-log.md`).
- Core watch observer implementation + UI/source attribution wiring.

### Pending (human/device follow-up)
- Xcode target membership wiring for new files.
- Buildability/compile verification in Xcode.
- On-device BLE validation and parser hardening with real payload traces.
