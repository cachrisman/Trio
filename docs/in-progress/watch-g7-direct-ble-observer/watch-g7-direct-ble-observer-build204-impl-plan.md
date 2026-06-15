> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 204 — Implementation plan

**Version:** 1.0
**Status:** Accepted
**Created:** 2026-05-31 CET
**Last updated:** 2026-05-31 CET

**Sibling logs/plans:** [watch-g7-direct-ble-observer-build204-impl-log.md](watch-g7-direct-ble-observer-build204-impl-log.md), [watch-g7-direct-ble-observer-build195-impl-log.md](watch-g7-direct-ble-observer-build195-impl-log.md)

---

## Problem

The watch G7 direct-BLE observer stopped delivering readings reliably on **build 203**. Telemetry (BetterStack source `1659391`, table `t491594.trio`) showed, on `platform=watchos` and that build only:

- A **connect storm** — `connect_called` firing repeatedly for the same/various peripheral UUIDs.
- `configuration_failed` from `WKExtendedRuntimeSession`.
- Multiple sensor UUIDs churning instead of one stable connection.

The iPhone app (`platform=ios`, same G7SensorKit) did **not** show this; it connects reliably with no connect timeout.

## Root cause

1. **Primary — `WKBackgroundModes` regression (patch-stack, not source).** The on-disk
   feature-branch `Trio Watch App/Info.plist` has always contained `WKBackgroundModes →
   physical-therapy`. The regression is in the **patch stack** that actually ships:
   - The watch Info.plist keys (`WKBackgroundModes` + `UIBackgroundModes bluetooth-central`)
     existed only in the **old** direct-BLE patch `11-watch-direct-ble-g7.patch` (lines
     ~5248–5254).
   - When the feature migrated to the **active** patch `12-direct-ble-observer.patch`, that
     Info.plist hunk was **not** carried over — patch 12 does not touch the watch Info.plist
     at all. Patch 11 was then renamed `.skipped` (inactive).
   - Patch `09` does modify the watch Info.plist, but only complication keys
     (`EXAppExtensionAttributes`) — no background modes.
   - **Net:** a build = `dev` + patches `09` + `12`, so the *built* watch app has no
     `WKBackgroundModes`, even though the branch source file does. Without it, every
     `WKExtendedRuntimeSession.start()` immediately invalidates before `didStart`, so the
     observer never holds a runtime session. The connect storm and UUID churn are downstream
     symptoms.
2. **Secondary — watch builds `G7Sensor(sensorID: nil)`** in `G7WatchSensorAdapter.init()`, unlike the iPhone app which seeds `G7Sensor(sensorID: state.sensorID)`. The watch therefore always re-scans/re-discovers rather than reconnecting to a known sensor.
3. **Shared dedup gap.** `G7BluetoothManager.handleDiscoveredPeripheral` issues `centralManager.connect()` with no in-flight guard, so several discovery paths can stack duplicate connects on one already-connecting peripheral. Not watch-specific, but it amplifies the storm.

**North star:** match iPhone behavior; diverge only with specific justification. Do **not** add a connect timeout, and do **not** change `scanAfterDelay` (H9) — that is intended shared behavior.

## Fixes (this build)

| # | Fix | Where | Delivery |
|---|-----|-------|----------|
| 1 | Ensure `WKBackgroundModes physical-therapy` (already in source) + add `UIBackgroundModes bluetooth-central` reach the build | `Trio/Trio Watch App/Info.plist` (feature branch) | Fold into **patch 12**; patch 12 regen scope **must** include this plist. Keys currently exist only in the skipped patch 11. |
| 2 | Seed `G7Sensor(sensorID: expectedSensorName)` | `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` (feature branch) | patch 12 |
| 3 | Connect-in-flight guard + `connect_skipped reason=in_flight` telemetry | `G7SensorKit/.../G7BluetoothManager.swift` (fork `main`) | Commit + push fork → bump SHA in **patch 02** |

## Why ship all three together

Each has a distinct proximal telemetry signal, so attribution stays clean in one build:

- Fix 1 working → `WKExtendedRuntimeSession` reaches `didStart` (no `configuration_failed`); session stays up.
- Fix 2 working → reconnect via stored id (`attach_path path=stored_id`) instead of `path=scan` on cold start.
- Fix 3 working → `connect_skipped reason=in_flight` lines appear and duplicate `connect_called` volume drops.

## Validation plan

- Confirm `WKBackgroundModes`/`UIBackgroundModes` present in the **built** watch app Info.plist (not just the merge file).
- BetterStack, `platform=watchos`, new build: session reaches `didStart`; `connect_called` no longer storms; `connect_skipped reason=in_flight` observed under contention; one stable sensor UUID.

## Risks / notes

- Fix 2 is nil-safe: `expectedSensorName == nil` (first launch / post-EOS) reproduces prior scan-mode behavior exactly.
- **Regression guard:** if patch 12 is ever regenerated without `Trio Watch App/Info.plist` in scope, fix 1 is lost again exactly as in build 203. See impl log + AGENTS.md.

## Changelog

- v1.0 (2026-05-31) — Initial plan recorded after implementation.
