# Build 179 Pre-Connect Attach-Context Investigation

**Scope:** Everything that matters before `didConnect` — all paths to `central?.connect(peripheral, options:)`, all guards that block them, comparison against G7SensorKit (working Trio phone reference) and DiaBLE (working watch reference).

**Context:** Build 179 is the third Phase I isolation build. Build 170 produced multiple `didConnect` events (first via `source=retrieved_identifier`). Build 171 introduced Phase G (cadence scheduler) + `registerForConnectionEvents` simultaneously and caused a regression. Builds 171–179: zero `didConnect`, zero `didFailToConnect`, zero CB-originated `didDisconnect`. Phase I isolation builds: 177 removed `registerForConnectionEvents`, 178 tried nil scan filter, 179 added persist-on-connect-attempt — all three failed.

---

## Section 1 — Executive Conclusion

Build 179 is not missing a feature that has not been built yet. It is in a stable regression from build 170 whose root cause Phase I (builds 177–179) has not identified.

The regression signature is unambiguous: zero `didConnect`, zero `didFailToConnect`, zero `didDisconnect` from CB since build 171. This combination means `connect()` has never been called since the regression began. The CB radio is not the bottleneck — the app is never reaching `central?.connect(peripheral, options: nil)`.

Every path to `connect()` in the current code gates on `doesPeripheralMatchActiveFilter`, which is an exact string equality check between the peripheral's name at discovery/retrieval time and `activePeripheralName`. The G7 advertises under its short name (`DXCMxx`) during the scan phase; `activePeripheralName` comes from the phone's sensor record as the full name (`DexcomXX`). These do not match. The only path that bypasses this mismatch is identifier retrieval, where the OS returns a peripheral whose cached full name is `DexcomXX` — but that path requires a persisted identifier, and the identifier is only persisted on `didConnect` (or in build 179, on connect-attempt — which is never reached for the same reason). The system is locked in a self-reinforcing trap: no identifier → scan only → name mismatch → no `connect()` → no `didConnect` → no identifier.

The build 170 → 171 regression most likely started when Phase G's initialization run of `setActivePeripheralName` cleared the persisted identifier that build 170's single `didConnect` had written. Every build since then has been operating without a usable identifier, and the scan path's exact-name mismatch has silently blocked `connect()` on every `didDiscover` callback.

Phase I isolation tested three surface-level BLE variables (`registerForConnectionEvents`, scan service filter, persist-on-connect-attempt). None of them addressed the name-matching logic or the identifier-loss mechanism. Phase I is exhausted without touching the actual blocker.

---

## Section 2 — Pre-Connect Attach Matrix (Build 179 Current State)

| # | Attach path | Trigger | Key guard before `connect()` | Build 170 outcome | Build 179 state | Blocking? |
|---|---|---|---|---|---|---|
| A | `retrievePeripherals(withIdentifiers:)` | `startScanning()`, `centralManagerDidUpdateState` | `hasActivePeripheralNameFilter` + exact-name match via `doesPeripheralMatchActiveFilter` | ✅ Worked — produced `didConnect` (`source=retrieved_identifier`) | Empty — no persisted identifier since 171 regression | ✅ Trapped: no ID → no retrieval |
| B | `retrieveConnectedPeripherals(withServices:)` | Same callers; uses `[dataService, FEBC]` | Same exact-name guard (`selectConnectedRetrievedPeripheralForAttach` line 1770) | Likely empty (G7 not system-connected on watchOS at test time) | Empty — G7 not system-connected on watchOS | ✅ Trapped: G7 only system-connected on watchOS if Dexcom Watch app is running |
| C | `didDiscover` scan callback | FEBC scan (`[G7BLEUUID.advertisement]`) | `hasActivePeripheralNameFilter` + exact-name match (lines 2321–2329) | 🚫 Never produced `didConnect` even before build 170 | Running — discovers `DXCMxx`, fails exact match vs `DexcomXX` | ✅ Blocked: `DXCMxx ≠ DexcomXX` |
| D | `connectionEventDidOccur` | G7 connects to ANY app on watchOS | Name match via `doesPeripheralMatchActiveFilter` | Not present until build 171 | **Commented out** (Phase I, build 177) | 🚫 Disabled |
| E | `willRestoreState` restored peripherals | CB state restoration on process relaunch | Not implemented — only logs key names | Logs only | Logs only | 🚫 Unimplemented |

All five paths are blocked in build 179. The core gating condition that all active paths share is `doesPeripheralMatchActiveFilter` (lines 1746–1749):

```swift
private func doesPeripheralMatchActiveFilter(_ peripheral: CBPeripheral) -> Bool {
    guard let active = activePeripheralName else { return false }
    return (peripheral.name ?? "unknown") == active     // exact string equality
}
```

G7SensorKit's equivalent uses `suffix(2)` to handle the `DXCMxx`/`DexcomXX` duality explicitly:

```swift
// G7Sensor.swift lines 246–254 — comment: "G7 advertises 'DXCMxx', later reports full name 'Dexcomxx'"
if name.hasPrefix("DXCM") || name.hasPrefix("DX02") {
    if let sensorName = sensorID, name.suffix(2) == sensorName.suffix(2) {
        return .makeActive
    }
}
```

---

## Section 3 — Most Important Differences vs Working Implementations

### Difference 1 — Exact-name match vs suffix-tolerant match (Trio Watch only; structurally blocking)

`doesPeripheralMatchActiveFilter` requires `peripheral.name == activePeripheralName`. The Dexcom G7's BLE stack advertises two different name strings:

- **Short advertising name** (`DXCMxx`): seen in `didDiscover` and returned by `retrieveConnectedPeripherals`
- **Full name** (`DexcomXX`): cached by the OS after a prior connection; returned by `retrievePeripherals(withIdentifiers:)` once the peripheral has been previously seen with its full name

G7SensorKit's `shouldConnectPeripheral` comment explicitly documents this duality and matches on `name.suffix(2)`. Trio Watch never normalized for it. For the identifier-retrieval path (path A), the OS-cached peripheral carries the full name and the match succeeds — this is why build 170 worked. For the scan path (path C), `didDiscover` fires with `DXCMxx`, the exact match against `DexcomXX` (from the phone's sensor record) fails, and `connect()` is never called. This is the reason scan path C has produced zero `didConnect` across all builds, including before build 170.

### Difference 2 — `setActivePeripheralName` clears the persisted identifier on name change (regression trigger)

```swift
// G7DirectBLEManager.swift lines 2858–2861
if let previous, previous != normalized {
    let reason = normalized == nil ? "active_name_removed" : "active_name_changed"
    clearPersistedPeripheralIdentifier(reason: reason)
}
```

Build 170's single `didConnect` persisted the G7 identifier. Build 171 introduced Phase G, which rewrote `applyForegroundActiveEntry` and called `setActivePeripheralName` during initialization from the new `G7BLECycleSeedContext` path. If the name string arrived with any difference (different prefix normalization, whitespace, format) between builds, the clear fired and the identifier was lost. Once lost, no further `didConnect` could replenish it because the scan path was always blocked by exact-name mismatch. The trap sealed.

G7SensorKit and DiaBLE do not have this identifier-clear-on-name-change coupling — they are always scanning and use tolerant name matching, so there is no single point where a name-format change can permanently strand the session.

### Difference 3 — Phase G cadence scheduler gates `startScanning()` behind `WKExtendedRuntimeSession` (new in build 171)

`startScheduledCycleIfNeeded` → `ensureRuntimeForCurrentCycle` → if session not yet `.active` → returns `.starting` and does **not** call `startScanning()`. The call to `startScanning()` only happens after `extendedRuntimeSessionDidStart` fires via `resumeCurrentCycleAfterRuntimeActivation`. If the session fails to start before `hardStopDate = expectedReadingDate + 25s`, the cycle is skipped entirely (`scheduleNextCycleAfterMiss(reason: "runtime_unavailable")`).

G7SensorKit scans continuously with no runtime gate. DiaBLE's session is allocated once at init and runs independently of per-cycle timing. Only Trio Watch conditions every scan start on session activation.

### Difference 4 — `continueCurrentCycleExecution` does not restart a stalled scan (architectural)

```swift
// lines 792–797
if scanningStarted || connectionState == .connecting || connectionState == .authenticating {
    // action=continue_existing_attempt — returns without restarting
    return
}
startScanning()
```

Once `startScanning()` has been called and `scanningStarted = true`, subsequent cycle executions see the existing state and do nothing. If a prior scan attempt connected-but-stalled (e.g., timed out at `awaiting_gatt_setup`) and `scanningStarted` remained true, the next cycle would not restart clean. G7SensorKit always re-executes its full scan sequence on `scanForPeripheral()` regardless of prior state.

### Difference 5 — `willRestoreState` does not reconnect restored peripherals (Trio + DiaBLE vs G7SensorKit)

G7SensorKit's `willRestoreState` iterates `CBCentralManagerRestoredStatePeripheralsKey` and calls `handleDiscoveredPeripheral` for each restored peripheral. Trio Watch only logs key names. After a background-terminated watchOS process relaunches, G7SensorKit immediately re-enqueues the G7 for connection; Trio Watch starts cold with no identifier and a scan-only regime.

---

## Section 4 — Red Herrings (Ruled Out by Phase I)

**`registerForConnectionEvents` as sole regression cause** — Ruled out by build 177. Removing it left zero `didConnect`. The callback being commented out disables path D, but paths A/B/C remain unaffected and were already blocked before path D was introduced.

**Scan service filter (`[FEBC]` vs `nil`)** — Ruled out by build 178. Nil scan still produces `didDiscover` callbacks with peripheral name `DXCMxx`; exact-name match still fails; zero `connect()` calls. The filter widening was irrelevant because the blocker is downstream (name match), not upstream (which services to scan for).

**Persist-on-connect-attempt** — Ruled out by build 179. The rationale was sound: persist identifier when `connect()` is called so the next cycle can use identifier retrieval. But `connect()` itself is never called (name match blocks it in `didDiscover`), so persist-on-connect-attempt never executes. The identifier remains absent.

**`UIBackgroundModes: bluetooth-central` absence** — Added in build 175, predates Phase I entirely. Not relevant to the pre-connect failure in foreground testing.

**`CBCentralManagerOptionShowPowerAlertKey: false`** — Present since early builds including working build 170. Not the cause.

**Delegate queue (main vs dedicated)** — Trio Watch and DiaBLE both use `queue: nil`. Build 170 worked with main queue. Not the cause.

---

## Section 5 — What Builds 171–179 / Phase I Rules Out

| Variable removed/added | Build | Result | What it rules out |
|---|---|---|---|
| `registerForConnectionEvents` removed | 177 | 0 `didConnect` | `registerForConnectionEvents` as sole or primary regression cause |
| Nil scan (`withServices: nil`) | 178 | 0 `didConnect` | Scan service filter as the blocking variable |
| Persist-on-connect-attempt added | 179 | 0 `didConnect` | Identifier absence as the only thing preventing `connect()` — deeper blocker confirmed |

**What Phase I collectively rules out:** Any explanation that requires `registerForConnectionEvents` as the essential missing piece. Any explanation that attributes failure to too-narrow scan filter. Any explanation that says "if only we persisted the identifier on attempt instead of on success, retrieval would work" — because even with identifier persisted on attempt, `connect()` must first be called, and it never is.

**What Phase I did not test:** The name-matching logic. The identifier-clear-on-name-change path. The `WKExtendedRuntimeSession` gate timing. Phase G scheduler timing accuracy vs actual G7 advertising windows. The `willRestoreState` reconnect behavior. `stopScan()` before `connect()`. Whether `g7_ble_pre_connect` ever appears in Phase I logs.

---

## Section 6 — What Build 179 Promotes Next

**Promoted: Name-mismatch exact-match is the immediate `connect()` blocker for the scan path**

Zero `didConnect` + zero `didFailToConnect` → `connect()` is never called. All paths to `connect()` require `doesPeripheralMatchActiveFilter`. Scan-discovered peripherals arrive with `DXCMxx`, `activePeripheralName` is `DexcomXX`. These never match under exact equality. The scan path has been structurally broken since before build 158 — it was masked in build 170 by identifier-retrieval success, which returned the peripheral with its OS-cached full name.

**Promoted: Identifier loss at the build 171 boundary as the regression trigger**

Build 170 had a working identifier. Build 171 introduced Phase G which called `setActivePeripheralName` in a new initialization path (`G7BLECycleSeedContext`). `setActivePeripheralName` clears the identifier when the name string changes. The identifier was likely lost at this boundary, collapsing from "retrieval works" to "scan-only + exact-match-fails = zero `connect()`."

**Demoted: Phase G timing as the primary regression cause**

Phase G timing matters for *when* `startScanning()` is called per cycle, but once scanning starts, `scanningStarted = true` keeps the scan running continuously between cycles. The `DXCMxx` advertisement is seen by `didDiscover` regardless of Phase G timing. Phase G timing governs background wake scheduling; it does not prevent an already-running foreground scan from calling `connect()`. Timing is a secondary concern once name matching is fixed.

**Demoted: `WKExtendedRuntimeSession` gate as the primary regression cause**

The confirmed 106-second foreground window in build 168 testing means foreground gating cannot fully explain zero `didConnect`. With the app in foreground, `isForegroundActive == true`, `ensureRuntimeForCurrentCycle` calls `beginExtendedRuntimeSession()` and proceeds to `.starting`. The runtime gate is a background reliability concern, not the primary foreground regression explanation.

---

## Section 7 — Highest-Signal Next Investigations

### Investigation 1 — Confirm `connect()` is never called: check for `g7_ble_pre_connect` in Phase I logs *(zero-change diagnostic; highest confidence)*

`g7_ble_pre_connect` is logged at line 2244 inside `beginConnectToG7Peripheral`, immediately before `central?.connect(peripheral, options: nil)`. If this event has zero occurrences across builds 171–179, it definitively confirms that neither scan-discover, retrieval, nor connection-event paths ever reach `connect()`. This one log check distinguishes "CB is silently failing to fire callbacks" from "the app never calls connect" — two completely different failure modes requiring completely different fixes.

### Investigation 2 — Log peripheral name vs `activePeripheralName` at the exact-match decision point *(zero-change diagnostic; directly confirms name-mismatch hypothesis)*

Add a probe log before the `doesPeripheralMatchActiveFilter` guard in `didDiscover`:

```swift
// in centralManager(_:didDiscover:advertisementData:rssi:), before the guard:
await logG7Ble(
    "event=g7_ble_name_match_probe peripheral_name=\(name) active_name=\(activePeripheralName ?? "nil") would_match=\(doesPeripheralMatchActiveFilter(peripheral))"
)
```

If logs show `peripheral_name=DXCMxx active_name=DexcomXX would_match=false` on every `didDiscover` callback, the hypothesis is confirmed and the fix is a one-function change. This probe should also be added to `selectConnectedRetrievedPeripheralForAttach` and `selectIdentifierRetrievedPeripheralForAttach`.

### Investigation 3 — Switch to suffix(2) match, mirroring G7SensorKit *(1-function code change; highest-impact fix candidate)*

Replace the body of `doesPeripheralMatchActiveFilter` with:

```swift
private func doesPeripheralMatchActiveFilter(_ peripheral: CBPeripheral) -> Bool {
    guard let active = activePeripheralName, let name = peripheral.name else { return false }
    // G7 advertises as DXCMxx during scan and reports full name as DexcomXX after connection.
    // Use exact match first; fall back to suffix(2) to handle the DXCMxx / DexcomXX duality,
    // mirroring the approach in G7SensorKit G7Sensor.swift.
    return name == active ||
           (name.count >= 2 && active.count >= 2 && name.suffix(2) == active.suffix(2))
}
```

This is a single-function change with no architectural impact. If the name-mismatch hypothesis is correct, this change restores `connect()` calls from `didDiscover` (scan path C). Combined with build 179's persist-on-connect-attempt, the identifier is then persisted on the first connect attempt, making identifier-retrieval available on subsequent cycles. This should be the next isolation build — one variable, maximum impact.

### Investigation 4 — Confirm identifier-clear-on-name-change fired at build 171 boundary *(log archaeology; confirms regression trigger; no code change needed)*

Check whether `clearPersistedPeripheralIdentifier` was logged immediately after the first launch of build 171. The event should be `g7_ble_peripheral_identifier_cleared reason=active_name_changed` or equivalent. If this event appears in early build 171 logs but not in build 170 logs, it confirms Phase G's `setActivePeripheralName` in the new `G7BLECycleSeedContext` initialization path cleared the identifier that build 170's `didConnect` had written.

### Investigation 5 — Uncomment `stopScan()` before `connect()` (line 2185) *(low-risk parity fix; not primary suspect but correct hygiene)*

```swift
// line 2185 — currently commented:
// central?.stopScan()

// Restore:
central?.stopScan()
```

Both DiaBLE (`didDiscover` calls `stopScan()` before `connect()`, line 173 of `BluetoothDelegate.swift`) and G7SensorKit (stops scan after delegate `readied` returns true) stop scan before completing a connection attempt. Keeping scan running while `connect()` is in flight is an unusual configuration; some CoreBluetooth versions on watchOS behave better when scan is stopped first. This is unlikely to be the sole regression cause but is correct parity and eliminates a radio-state variable from future debugging.

### Investigation 6 — Implement `willRestoreState` restored-peripheral reconnect *(medium complexity; addresses cold-launch gap; post-regression-fix priority)*

```swift
func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let keys = dict.keys.sorted().joined(separator: ",")
    Task { await logG7Ble("event=g7_ble_will_restore_state keys=\(keys)") }

    // Mirror G7SensorKit: attempt attach for each restored peripheral.
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
        let generation = currentCycleGeneration
        for peripheral in peripherals {
            _ = beginRetrievedOrEventAttachIfEligible(
                peripheral,
                source: "restored_state",
                expectedCycleGeneration: generation
            )
        }
    }
}
```

G7SensorKit calls `handleDiscoveredPeripheral` for each restored peripheral on process relaunch. Trio Watch only logs key names. After background termination, G7SensorKit immediately re-enqueues the G7 for connection from the restored state; Trio Watch starts cold. This matters most once the foreground regression is resolved.

---

## Priority Ranking for Next Build

| Priority | Action | Expected outcome |
|---|---|---|
| 1 | **Check `g7_ble_pre_connect` log presence in Phase I logs** | Confirms whether `connect()` is ever called — determines all subsequent strategy |
| 2 | **Add name-match probe log at exact-match decision point** | Directly confirms or refutes `DXCMxx`/`DexcomXX` name-mismatch hypothesis |
| 3 | **Switch `doesPeripheralMatchActiveFilter` to suffix(2) match** | If hypothesis confirmed, single-function change that restores `connect()` on scan path |
| 4 | **Check build 171 logs for identifier-clear event** | Confirms regression trigger; no code change needed |
| 5 | **Uncomment `stopScan()` before `connect()` (line 2185)** | Parity with DiaBLE; eliminates radio-state variable |
| 6 | **Implement `willRestoreState` reconnect** | After foreground regression is resolved; improves cold-launch reliability |
