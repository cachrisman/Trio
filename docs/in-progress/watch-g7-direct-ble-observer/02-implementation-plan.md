# Trio Watch — G7 Direct BLE Observer (Implementation Plan)

Branch: `cursor/feature/watch-g7-direct-ble-observer-1c81` off
`baseline-dev-patches-01-10`.

Project-file / Xcode target membership is out of scope for this pass
(per the prompt). All new Swift sources live in their target folder and
the human completes `project.pbxproj` membership in Xcode.

---

## New Swift sources

All under `Trio Watch App Extension/G7DirectBLE/` except the shared enum.

| File | Purpose |
| --- | --- |
| `Trio Watch Shared/TrioComplicationDataSource.swift` | Cross-target enum: `watchConnectivity`, `healthKit`, `g7DirectBLE`. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLEConstants.swift` | UUIDs, opcodes, restoration key, preferred-peripheral UserDefaults key. Comments cite `G7SensorKit/BluetoothServices.swift` / `G7SensorKit/Messages/G7Opcode.swift`. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLEMessages.swift` | `G7DirectAuthChallenge`, `G7DirectGlucoseMessage`, `G7DirectBackfillMessage`. Parsing mirrors `G7SensorKit/Messages/G7GlucoseMessage.swift` and `G7SensorKit/Messages/G7BackfillMessage.swift`; no dependency on LoopKit. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLEDataReader.swift` | Small endian-aware `Data` helpers scoped to this module so we do not pollute global namespaces. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLEObserverStatus.swift` | 5-state enum + small DTO with `lastEGVAt` for UI. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLELog.swift` | Typed logging helper forwarding `#fileID / #line / #function` into `WatchLogger.shared.log`. Defines the `g7_ble_*` event name constants. |
| `Trio Watch App Extension/G7DirectBLE/G7DirectBLEObserver.swift` | `@MainActor`-isolated public façade + central-queue `CBCentralManager` delegate. This is the main component. |
| `Trio Watch App Extension/Views/G7DirectBLEStatusRow.swift` | Compact SwiftUI view rendering the BLE status + source row. |

### Existing files modified

| File | Change |
| --- | --- |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Add `source` optional to `TrioComplicationSnapshot`; extend `save(...)` convenience overload to accept `source`. Extend fingerprint? No — fingerprint excludes `source` by design (matches `shouldUpdate`). |
| `Trio Watch App Extension/WatchState.swift` | Add `@Observable latestReadingSource`, `g7ObserverStatus`, `lastG7BLEReadingAt`. Pass `.watchConnectivity` into snapshots saved from WC paths; pass `.healthKit` into snapshots saved from HK path. |
| `Trio Watch App Extension/ExtensionDelegate.swift` | Call `G7DirectBLEObserver.shared.primeCentral()` from `applicationDidFinishLaunching`. Call `observer.start()` on `applicationDidBecomeActive`. |
| `Trio Watch App Extension/TrioWatchApp.swift` | On `.active` also call `G7DirectBLEObserver.shared.scenePhaseChanged(.active)`. On `.inactive`/`.background` call `.scenePhaseChanged(.inactive)` (no teardown — see design §12). |
| `Trio Watch App Extension/Views/TrioMainWatchView.swift` | Render `G7DirectBLEStatusRow` on page 0 below `GlucoseTrendView` (inside the same `ZStack`/`VStack` block). |

No changes to `Trio.xcodeproj/project.pbxproj`. No Xcode runs. Human
completes target membership for the new files afterward.

---

## Phases (ordering)

1. **Scaffolding & shared types.**
   - `TrioComplicationDataSource` enum.
   - Add `source` field + constructor param to `TrioComplicationSnapshot`
     (default `nil`; keeps existing call sites compiling).
   - `G7DirectBLEObserverStatus` enum.
2. **BLE constants, parsers, logging.**
   - `G7DirectBLEConstants`, `G7DirectBLEMessages`, `G7DirectBLEDataReader`,
     `G7DirectBLELog`.
3. **Observer core.**
   - `G7DirectBLEObserver` — central init, discovery, attach ladder,
     reconnect backoff, service/characteristic discovery, auth observation
     with fallback timer, EGV request write, EGV parse, snapshot emit.
4. **Integration.**
   - `WatchState` — expose observer status + source field; plumb source
     into existing snapshot saves.
   - `TrioComplicationDataStore` — accept and persist source in snapshots.
   - `ExtensionDelegate`, `TrioWatchApp` — wire lifecycle.
5. **UI.**
   - `G7DirectBLEStatusRow`.
   - Place it in `TrioMainWatchView` page 0.
6. **Self-review & docs.**
   - Read every modified file end-to-end.
   - Update `03-implementation-log.md`.

---

## Sequencing rationale

- Phase 1 is non-BLE and adds optional-by-default fields, so it can't
  break baseline behavior.
- Phase 2 is pure value types and constants, no threading or lifecycle.
- Phase 3 is the risky piece. Keeping it isolated from the UI and from
  `WatchState` plumbing means a human can stub out the observer (return
  `.off` forever) and the rest of the integration still works.
- Phase 4 relies on phases 1 and 3 but doesn't block phase 5 — the UI
  reads `WatchState` fields that default to safe values even if the
  observer never transitions.
- Phase 5 is cosmetic and tolerant of a never-started observer.

---

## Unit tests (planned, narrow)

Placed under `Trio Watch App Tests/G7DirectBLE/` once a human wires the
target. Not added in this pass since they would otherwise be orphaned.
Recorded here as intent:

- `G7DirectGlucoseMessageTests`
  - Valid `0x4e` message parses glucose, trend, sequence, age, timestamp.
  - Message with `glucose == 0xffff` yields `nil` glucose.
  - Message with `trend == 0x7f` yields `nil` trend rate.
- `G7DirectAuthChallengeTests`
  - `0x05 0x01 0x01` → authenticated + bonded.
  - `0x05 0x00 0x01` → not authenticated, bonded.
  - Non-`0x05` prefix → nil.
- `G7DirectBackfillMessageTests`
  - Exactly-9-byte packet parses timestamp, glucose, trend.
- `G7DirectBLEObserverStatusTests` (pure value semantics).

BLE-level behavior is not unit-tested in this pass; that requires a
fakeable `CBCentralManager` scaffold that is out of scope.

---

## Risks

- Project-file integration is deferred. Any naming or path choices that
  don't match `scripts/sync_project_files_config.rb`'s globs will leave
  the files outside the watch extension target until the human fixes it.
  The chosen folder (`Trio Watch App Extension/G7DirectBLE/`) matches the
  existing `Trio Watch App Extension/Helper/` pattern, so globs like
  `Trio Watch App Extension/**/*.swift` will include them.
- `TrioComplicationSnapshot` is shared with the complication extension;
  adding a new optional `Codable` field requires careful default-init
  handling so persisted snapshots from old builds still decode. Plan: use
  `decodeIfPresent` for `source`. Encoding always writes `source` only if
  non-nil (Codable's default).
- `WatchState` is large and has many save paths. Care is needed to plumb
  `source` at every call site so UI attribution is accurate. Partial
  plumbing (missing a single HK call) would show "src: —" on HK-only
  cycles; acceptable degradation but noted.

---

## Explicitly not in this pass

- Project file edits, target membership, build verification.
- Backfill forwarding to the data store.
- Extended runtime sessions.
- iPhone-bridged active-name filter.
- Unit tests (written but not placed on disk — would need target wiring).
- HealthKit write-through from BLE observer — prohibited by prompt.
