# Watch G7 Direct BLE Observer — Implementation Log

## Branch / base
- Working branch: `feature/watch-g7-direct-ble-observer-a`
- Intended base: `baseline-dev-patches-01-10`.
- Environment note: branch was created locally from current repo HEAD because no remote-tracking branches/remotes were configured in this container.

## Phase log

### Phase 0 — required reference fetch
- Attempted to fetch all 34 required DiaBLE/G7SensorKit raw URLs via `curl -fsSL`.
- Result: all requests failed with HTTP 403 in this environment.
- Impact: proceeded with explicit risk callouts and conservative clean-room implementation using known protocol constants.

### Phase 1 — shared source attribution
- Added `TrioComplicationDataSource` enum in `Trio Watch Shared/`.
- Extended `TrioComplicationSnapshot` with optional `source` and threaded it through save helpers.

### Phase 2 — watch observer core
- Added `G7DirectBLEObserver` implementing:
  - eager restoration central manager
  - connected-service retrieval + scan fallback
  - tolerant candidate filter
  - broad service/characteristic discovery
  - auth observe-only posture (no auth writes)
  - control EGV request write on auth + timer cadence
  - reconnect with bounded backoff
  - structured `event=g7_ble_*` logging

### Phase 3 — WatchState integration
- Added `WatchState+G7DirectBLE` delegate bridge and state surface.
- On direct EGV, updates WatchState, tags source `.directBLE`, and saves via existing complication store.
- Added source-tagging for existing HK and WatchConnectivity save paths.
- Hooked observer start on active entry and scene update on inactive/background transition.

### Phase 4 — UI integration
- Updated main glucose recency line in `GlucoseTrendView` to include source, BLE status, and last direct-BLE event recency.
- Updated cache hydration in `TrioMainWatchView` to restore `source` into watch state.

## Deviations from design during implementation
- None material; implementation followed the design plan.

## Validation performed
- Static review only; no `xcodebuild`, no `ci/local-build.sh`, no project-file edits.
- No target-membership wiring attempted (left for human Xcode follow-up).

## Final handoff state
- Done: docs, clean-room observer source files, WatchState/store/UI integration.
- Pending human follow-up: Xcode target membership wiring, on-device BLE validation, parser offset confirmation, battery/runtime tuning.
