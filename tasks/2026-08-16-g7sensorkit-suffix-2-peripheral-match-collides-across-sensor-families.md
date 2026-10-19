+++
uid = "01a00967-5265-766e-9c5f-585ba6d295e1"
key = "TRIO-031"
title = "G7SensorKit suffix(2) peripheral match collides across sensor families"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "G7SensorKit/G7CGMManager/G7Sensor.swift#L322"
created = 2026-08-16
updated = 2026-08-16
touched = 2026-08-16
tags = ["g7", "ble", "cgm"]
+++

## Intent


## Finding

Surfaced by an `ollama` review of `G7Sensor.swift` on 2026-08-16 while reviewing the [[TRIO-028]]
backfill work. **Out of scope for TRIO-028 and pre-existing** — the code is upstream, from
`fdcfb20 "Extracting G7 from CGMBLEKit"`, not introduced by the backfill changes. Filed separately
rather than widening that commit.

The peripheral-match heuristic compares only the last two characters of the advertised name:

```swift
if let sensorName = sensorID, name.suffix(2) == sensorName.suffix(2) {
    …
    return .makeActive
}
```

Both G7 (`DXCMxx`) and Dexcom One+ (`DX02`) pass the `hasPrefix("DXCM") || hasPrefix("DX02")` gate.
`"DXCM02".suffix(2)` and `"DX02".suffix(2)` are both `"02"`, so a `G7Sensor` following a G7 named
`DXCM02` will return `.makeActive` for a One+ peripheral. Authentication then fails, producing a
`suspectedEndOfSession` and a rescan — a connect → auth-fail → rescan loop that delays reconnecting
to the correct sensor.

**Severity: low-moderate.** Requires both sensor families in range simultaneously (plausible during
a sensor swap), and the auth failure is self-correcting. But the heuristic is unsound for the two
families the code explicitly handles.

Suggested fix (from the review): require the prefix family to match as well as the suffix, e.g.
also test `name.hasPrefix("DXCM") == sensorName.hasPrefix("DXCM")`.

**Not verified against hardware.** The One+ naming (`DX02`) is asserted by the reviewer and should
be confirmed against a real device or the advertising data before implementing.
