# Investigation: `g7_session=nil` on watch-side G7SensorKit core telemetry

**Version:** v1  
**Status:** Complete (investigation only — no code changes)  
**Created:** 2026-06-03 12:38 CET  
**Last updated:** 2026-06-03 12:38 CET  
**Branch reviewed:** `feature/watch-g7-direct-ble-observer-synthesis` (Trio worktree); G7SensorKit fork `21d6d8a`

---

## Executive summary

**Root cause (confirmed):** Fork core telemetry (`module=g7_core`) gets `g7_session` from the **host emit closure**, not from G7SensorKit. On watch, `ExtensionDelegate` supplies `G7WatchSensorAdapter.shared.adapterSessionID ?? "nil"` (`ExtensionDelegate.swift:10–15`), but `adapterSessionID` is only assigned in `recordSessionConnect` (`G7WatchSensorAdapter.swift:653`) — which runs **after** the fork has already emitted early-cycle events (`attach_path`, `connect_called`, `did_connect`, `gatt_ready`, `auth_notify_*`, `configuration_failed`, etc.). Until connect bookkeeping runs, the closure formats `g7_session=nil` (the literal string `"nil"`, not Swift optional absence).

**Plan hypothesis (refuted):** Build 205 deferred text says the watch should “mirror the iPhone's session-id plumbing into the shared manager.” Source shows **neither platform** threads a session id into G7SensorKit. The fork exposes only `G7Telemetry.emit: ((G7TelemetryPayload) -> Void)?` (`G7Telemetry.swift:28–31`); session is appended by host formatting (`G7StructuredTelemetryLogLine.formatCoreTelemetry`, `:8–15`). iPhone hardcodes `g7Session: "na"` (`TrioApp.swift:105–108`) — not a live session UUID and not read from `G7CGMManager`.

**Minimal fix (describe only):** Host-side (patch **12**): mint a cycle-scoped session id **before** the fork can emit (e.g. at `start()` / `initiateScanForNewSensor()` / first `resumeScanning()` for the attach cycle), store it in `adapterSessionID` (or a dedicated property read by `ExtensionDelegate`), and stop re-minting in `recordSessionConnect` when an id already exists for the cycle. **No fork change required** for this fix. Optional fork API (session provider on `G7Telemetry`) would ride C3 + patch 02 but adds no capability the host closure cannot already provide.

**Batch with C3 fork commit?** **No** — not required. This is a watch-host telemetry wiring / lifecycle timing issue. It can ship in patch 12 alone without touching C3's `configureAndRun` fail-closed behavior or expanding C3's validation surface. If someone still wanted it in the same fork SHA bump as C3 for process reasons, a host-only mint-earlier change could land in patch 12 in the same build with **no** additional fork commit.

---

## 1. Watch emit wiring

### Where `G7Telemetry.emit` is set

| Location | Evidence |
|----------|----------|
| Watch extension startup | `ExtensionDelegate.applicationDidFinishLaunching()` (`ExtensionDelegate.swift:5–19`) |
| Patch 12 | Same hunk in `patches/12-direct-ble-observer.patch:38–48` |

```swift
G7Telemetry.emit = { payload in
    Task { @MainActor in
        let sid = G7WatchSensorAdapter.shared.adapterSessionID ?? "nil"
        let sensorName = G7WatchSensorAdapter.shared.telemetrySensorName
        let line = G7StructuredTelemetryLogLine.formatCoreTelemetry(
            sensorName: sensorName,
            payload: payload,
            g7Session: sid
        )
        await WatchLogger.shared.log(line)
    }
}
```

### What value is passed as `g7Session`

- **At format time:** `adapterSessionID` if non-nil; otherwise the **string** `"nil"` (`ExtensionDelegate.swift:10`, `G7StructuredTelemetryLogLine.swift:15`).
- **Source of `adapterSessionID`:** Optional `String?` on `G7WatchSensorAdapter`, documented as “Set on `sensorDidConnect`, cleared on `sensorDisconnected`” (`G7WatchSensorAdapter.swift:127–128`).
- **When it is assigned:** `adapterSessionID = String(UUID().uuidString.prefix(8))` inside `recordSessionConnect` (`G7WatchSensorAdapter.swift:653`).
- **When it is cleared:** `adapterSessionID = nil` in `handleSensorDisconnected` (`G7WatchSensorAdapter.swift:731`).
- **`telemetrySensorName`:** `UserDefaults.standard.string(forKey: Keys.sensorName) ?? "nil"` (`G7WatchSensorAdapter.swift:131–133`) — independent of session id.

### Emit dispatch path

1. Fork calls `emitG7Telemetry(_:_:)` (`G7Telemetry.swift:42–47`) on serial queue `com.g7sensorkit.telemetry` (`G7Telemetry.swift:34–37`).
2. Host closure runs, then hops to `@MainActor` via `Task` (`ExtensionDelegate.swift:9–17`).
3. Session id is read **at MainActor format time**, not cached when the closure is installed.

**Not the adapter `log()` path:** Adapter BLE module lines use `formatBleModule` with the same `adapterSessionID ?? "nil"` (`G7WatchSensorAdapter.swift:321–333`) but run from adapter code **after** connect bookkeeping for `did_connect`-class events emitted via `log()` inside `recordSessionConnect` (`G7WatchSensorAdapter.swift:662–665`).

---

## 2. iPhone emit wiring

### Where `G7Telemetry.emit` is set

| Location | Evidence |
|----------|----------|
| iOS app startup | `TrioApp.configureG7ForkTelemetry` called from `loadServices()` (`TrioApp.swift:75`, `:95–111`) |
| When `loadServices` runs | After Core Data init, on `@MainActor` (`TrioApp.swift:189–191`) |
| Patch 13 | `patches/13-phone-ble-observer-telemetry.patch:69–85` |

```swift
G7Telemetry.emit = { [deviceDataManager, fetchGlucoseManager] payload in
    let sensorName: String
    let g7 = (fetchGlucoseManager?.cgmManager as? G7CGMManager)
        ?? (deviceDataManager?.cgmManager as? G7CGMManager)
    if let g7 {
        sensorName = g7.sensorName ?? "nil"
    } else {
        sensorName = "nil"
    }
    let line = G7StructuredTelemetryLogLine.formatCoreTelemetry(
        sensorName: sensorName,
        payload: payload,
        g7Session: "na"
    )
    debug(.service, line)
}
```

### How iPhone obtains `g7Session`

- **Constant `"na"`** — not derived from `G7CGMManager`, not per-emit, not a UUID (`TrioApp.swift:108`).
- **`sensor_name`** is resolved per emit from `G7CGMManager.sensorName` via plugin/device managers (`TrioApp.swift:97–104`).
- **`G7CGMManager`** does not define or expose a telemetry session id; `sensorDidConnect` only updates `state.latestConnect` (`G7SensorKit/.../G7CGMManager.swift:334–338).

### Per-emit vs setup-time

| Field | iPhone behavior |
|-------|-----------------|
| `G7Telemetry.emit` closure | Set once at startup |
| `sensor_name` | Resolved **per emit** from live `G7CGMManager` |
| `g7_session` | **Fixed literal** `"na"` every emit |

**Correction vs user prompt:** If logs show iPhone `g7_session` as “populated,” that is **`g7_session=na`**, not a real session identifier. Watch shows **`g7_session=nil`** (literal) when `adapterSessionID` is unset. Neither platform currently correlates fork core events with a live UUID on iPhone.

---

## 3. Timing — when `nil`-bearing core events fire

### Session id lifecycle on watch

| Phase | `adapterSessionID` | Evidence |
|-------|-------------------|----------|
| Process / adapter init | `nil` (optional default) | `G7WatchSensorAdapter.swift:128` |
| `start()` / scan / connect attempts | Still `nil` until connect bookkeeping | No assignment in `start()` (`:193–218`), `initiateScanForNewSensor()` (`:501–508`), or `resumeScanning()` path |
| Connect bookkeeping | Minted 8-char UUID prefix | `recordSessionConnect` `:653` |
| Disconnect | Cleared | `handleSensorDisconnected` `:731` |

### `recordSessionConnect` entry points (when id becomes non-nil)

1. **`sensorDidConnect` delegate** → `handleSensorDidConnect` → `recordSessionConnect` (`G7WatchSensorAdapter.swift:578–580`, `:631–633`, `:646+`).
2. **First-discovery glucose path** when `boundSensorName == nil` → `recordSessionConnect(..., source: "first_discovery_path")` (`G7WatchSensorAdapter.swift:746–747`).

Delegate hops use `Task { @MainActor in … }` (`G7WatchSensorAdapter.swift:578–580`), so connect bookkeeping is **asynchronous** relative to fork BLE queue work.

### Fork event order vs session mint (reconnect path, `sensorID` already set)

Documented order within one attach cycle:

| Order | Fork event(s) | Emitted from | Session id at emit time |
|-------|---------------|--------------|-------------------------|
| 1 | `attach_path` (`path=stored_id` / `path=scan` / …) | `G7BluetoothManager.swift:204–226` | `nil` → `g7_session=nil` |
| 2 | `connect_called` | `G7Sensor.swift:278–281` | `nil` |
| 3 | `did_connect` | `G7BluetoothManager.swift:381` | `nil` |
| 4 | `gatt_ready` | `G7Sensor.swift:204` (inside `readied`, **before** delegate async) | `nil` |
| 5 | `auth_notify_subscribed`, `auth_notify_requested`, … | `G7Sensor.swift:218–219` | `nil` |
| 6 | `configuration_failed` (if config errors) | `G7PeripheralManager.swift:148` | `nil` |
| 7 | `sensorDidConnect` scheduled | `G7Sensor.swift:208–210` (`delegateQueue.async`) | still `nil` on BLE threads |
| 8 | `recordSessionConnect` on MainActor | `G7WatchSensorAdapter.swift:653` | **now set** |
| 9 | Later events (`egv_received`, `auth_authenticated_bonded`, …) | `G7Sensor.swift` / managers | **usually set**, unless MainActor bookkeeping races ahead of a very early post-connect emit |

**Key ordering facts (confirmed):**

- Fork `did_connect` (`G7BluetoothManager.swift:381`) fires **before** `readied` → `gatt_ready` → optional `sensorDidConnect` (`G7BluetoothManager.swift:385–391`, `G7Sensor.swift:199–210`).
- `adapterSessionID` is minted only in `recordSessionConnect` (`:653`), which runs **after** steps 1–6 for a typical reconnect.
- On **first discovery** (`sensorID == nil`), `sensorDidConnect` may not run in `readied` at all (`G7Sensor.swift:206–210` requires matching `sensorID`); id mint may wait until **first glucose** (`G7WatchSensorAdapter.swift:746–747`), delaying session id further while auth/config telemetry already fired.

**Hypothesis status:** “`adapterSessionID` is only minted on discovery/connect while configure/connect telemetry fires earlier” — **confirmed** with file:line evidence above.

### Post-connect core events

After `recordSessionConnect`, fork emissions such as `egv_received` (`G7Sensor.swift:135–138`) should generally see a non-nil `adapterSessionID` when the MainActor `Task` in `ExtensionDelegate` runs — **inferred**, not log-verified in this investigation. Residual `g7_session=nil` on late events would require a separate race analysis (MainActor `Task` ordering vs telemetry queue); the dominant volume of `nil` reports aligns with pre-connect fork events.

---

## 4. Mechanism difference — iPhone vs watch

| Aspect | iPhone | Watch |
|--------|--------|-------|
| Emit installed | `TrioApp.loadServices` → `configureG7ForkTelemetry` | `ExtensionDelegate.applicationDidFinishLaunching` |
| `g7_session` source | Literal `"na"` | `adapterSessionID ?? "nil"` |
| Session in G7SensorKit / manager | **None** — fork has no session parameter | **None** — same fork API |
| `sensor_name` source | Live `G7CGMManager.sensorName` | UserDefaults `G7DirectBLEObserver.sensorName` |
| Adapter/module-specific logs | N/A (no watch adapter on phone) | `module=g7_ble` via `G7WatchSensorAdapter.log()` with same `adapterSessionID` |

**Plan hypothesis:** “Watch host does not thread a session id into the shared manager the way the iPhone does.”

**Verdict: Refuted.** The iPhone does **not** thread a session id into `G7Sensor` / `G7CGMManager` / `G7Telemetry` either. Both hosts set a single global `G7Telemetry.emit` closure; the difference is **what string the closure passes**:

- iPhone: static `"na"` (always non-nil-looking, but not a real session).
- Watch: dynamic id that is **unset for most of the attach cycle**, formatting as literal `nil`.

The watch actually **attempts** richer correlation than iPhone for core telemetry; it fails for early-cycle events because the id is minted too late.

---

## 5. Minimal fix (description only — do not implement here)

### Recommended: host-only (patch 12)

1. **Mint a cycle-scoped id before fork emissions** — e.g. when starting a BLE attach cycle in `start()` (when scan/connect begins), `initiateScanForNewSensor()` (`G7WatchSensorAdapter.swift:501+`), and/or when `resumeScanning()` is invoked with no active session id. Mirrors the retired `G7DirectBLEManager` pattern (session at `startScanning()` — see `docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-03-instrumentation-report.md`, item on `g7_session` at scan start).
2. **Reuse, don’t double-mint** — In `recordSessionConnect` (`:653`), assign a new id only if nil (or explicitly rotate on genuine new cycle after disconnect clear at `:731`).
3. **No `ExtensionDelegate` change required** if it keeps reading `adapterSessionID` — early `attach_path` / `connect_called` / `configuration_failed` lines would pick up the cycle id once step 1 is in place.

### Not required

- **Fork change** for `emitG7Telemetry` signature (C3 already uses existing 2-arg helper).
- **Threading session into G7SensorKit** — iPhone doesn’t do this; host closure remains the correct seam (`G7Telemetry.swift:28–31`).

### iPhone parity (optional, out of scope)

- Could replace `"na"` with a phone-side cycle id using the same host-closure pattern — not needed to fix watch `nil`.

---

## 6. C3 batching decision

| Question | Answer |
|----------|--------|
| Can this batch into the C3 fork commit without expanding C3's behavioral surface? | **No need to involve C3 at all** for the fix. |
| Requires fork + patch 02 repin? | **No** — host-only patch 12 suffices. |
| If forced into same build as C3? | Host mint-earlier change is **telemetry-only**; orthogonal to C3 fail-closed `configureAndRun`. No shared fork code required; **does not** expand C3 validation (no connect-timeout / scan-timing changes). |
| Separate behavioral validation? | **Minimal** — confirm early `module=g7_core` lines show the same cycle id as later `module=g7_ble did_connect` / `egv_received` in Better Stack; no EGV/capture regression expected. |

---

## 7. Claims not verified against runtime logs

| Claim | Status |
|-------|--------|
| Better Stack shows `g7_session=nil` on specific events | **Assumed from prompt** — not queried in this pass |
| iPhone shows “populated” UUID session ids on core telemetry | **Contradicted by source** — iPhone uses `g7_session=na` |
| Post-connect core events still show `nil` after fix | **Not tested** — would need log query after implementation |
| MainActor `Task` reordering causes late-event `nil` | **Possible but secondary** — primary gap is pre-mint timing |

---

## 8. Reference map (quick)

| Symbol | Path |
|--------|------|
| Fork emit API | `G7SensorKit/G7CGMManager/G7Telemetry.swift` |
| Host formatter | `Trio/Sources/Helpers/G7StructuredTelemetryLogLine.swift` |
| Watch emit wiring | `Trio Watch App Extension/ExtensionDelegate.swift:5–19` |
| Watch session property | `Trio Watch App Extension/G7WatchSensorAdapter.swift:127–128, :653, :731` |
| iPhone emit wiring | `Trio/Sources/Application/TrioApp.swift:95–111` |
| Early fork events | `G7BluetoothManager.swift`, `G7Sensor.swift`, `G7PeripheralManager.swift` (see §3) |

---

## Changelog

### v1 (2026-06-03 12:38 CET)
- Initial investigation: watch vs iPhone `G7Telemetry.emit` wiring, timing analysis, refutation of build-205 “mirror iPhone manager plumbing” hypothesis, minimal fix and C3 batching recommendation. Reason: decide whether `g7_session=nil` fix belongs in C3 fork lane or patch 12 only.
