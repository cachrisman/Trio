# Dexcom G7 CGM: Data from Device vs Derived by iOS App

**Purpose:** Clarify which glucose-related data is received directly from the Dexcom G7 CGM over BLE and which is derived by the Trio iOS app. Focus: glucose value, timestamp, trend, delta, and trend arrow.

**Codebase references:** G7SensorKit (`G7GlucoseMessage`, `G7CGMManager`), Trio APS (`PluginSource`, `AppleWatchManager`, `BloodGlucoseExtensions`), Watch (`WatchState`).

---

## 1. Data received directly from the Dexcom G7 CGM

The following are parsed from the G7 BLE payload in `G7GlucoseMessage` (and for backfill in `G7BackfillMessage`):

| Data | Source | Notes |
|------|--------|------|
| **Glucose value** | **CGM** | Raw value from the payload (bytes 12–13, masked to 12-bit). |
| **Timestamp** | **CGM** | From `messageTimestamp` (seconds since pairing) and `age` (seconds from sensor reading to BLE). The app computes reading time as `activationDate + (messageTimestamp - age)`. |
| **Trend** | **CGM** | Byte 15: signed trend rate in 0.1 mg/dL/min (e.g. `-2.5` → −2.5 mg/dL/min). Parsed as `trend: Double?`. `0x7f` means no trend. |
| **Trend arrow / direction** | **CGM** | Same trend value. Mapped in `G7GlucoseMessage.trendType` to `LoopKit.GlucoseTrend` (flat, up, upUp, …), then in Trio to `BloodGlucose.Direction` via `BloodGlucose.Direction(trendType: newGlucoseSample.trend)` in `PluginSource.swift` (line 241). There is no separate “arrow” field; the arrow is the CGM trend. |
| **Trend rate** | **CGM** | Same numeric `trend` (mg/dL/min) exposed as `HKQuantity` for LoopKit. |

### Other fields from the CGM

- **algorithmState** (byte 14): e.g. warmup, ok, expired, session ended, sensor failed.
- **sequence** (bytes 6–7).
- **glucoseIsDisplayOnly** (bit in byte 18).
- **predicted** (bytes 16–17): predicted glucose (live message only; not in backfill).
- **condition** (below/above range): derived in the app from glucose vs `GlucoseLimits`, not a separate CGM field.

Backfill messages (`G7BackfillMessage`) provide: timestamp, glucose, trend, algorithmState, glucoseIsDisplayOnly (no predicted).

---

## 2. Data derived by the iOS app

| Data | Derived how |
|------|--------------|
| **Delta** | **Always derived.** Computed as current minus previous reading. On iPhone: `AppleWatchManager` (lines 382–393), `deltaValue = glucoseObjects[0].glucose - glucoseObjects[1].glucose`. On the watch (e.g. R6 HealthKit path): `WatchState.swift` (259–263), same formula from the last two HealthKit samples. The G7 does not send a delta; the app never uses a CGM delta. |

---

## 3. Other data received from the CGM

Beyond value, timestamp, trend, and arrow, the G7 BLE protocol provides:

- **algorithmState** – session state (warmup, ok, expired, failed, session ended, etc.).
- **sequence** – message sequence number.
- **glucoseIsDisplayOnly** – flag for display-only readings.
- **predicted** – predicted glucose (live messages only).
- **age** – delay from sensor measurement to BLE message (used to derive reading time from `messageTimestamp`).

---

## 4. Summary

- **From CGM:** Glucose value, timestamp (via `messageTimestamp` and `age`), trend (numeric rate), trend arrow/direction (mapped from that rate), trend rate, plus algorithm state, sequence, predicted, glucoseIsDisplayOnly, and for backfill the same minus predicted.
- **Derived by app:** Delta (current − previous); condition (from glucose vs limits). Timestamp is “from CGM” in the sense that `messageTimestamp` and `age` come from the CGM; the actual reading time is computed as `messageTimestamp - age` then converted to `Date` using sensor activation.

The “trend from numeric delta” logic in `BloodGlucoseExtensions.init(trend: Int)` is used for other sources (e.g. Minimed, or when only a delta is available), not for G7. For G7, trend and arrow come from the CGM trend byte mapped through `trendType` → `BloodGlucose.Direction`.
