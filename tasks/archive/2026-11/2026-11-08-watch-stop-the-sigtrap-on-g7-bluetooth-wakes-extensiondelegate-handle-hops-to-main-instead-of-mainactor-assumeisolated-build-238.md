+++
uid = "01a1bab4-c1c1-70fe-90b5-46d618b43e31"
key = "TRIO-103"
title = "Watch: stop the SIGTRAP on G7 Bluetooth wakes — ExtensionDelegate.handle(_:) hops to main instead of MainActor.assumeIsolated (build 238)"
status = "done"
kind = "code"
source = "human"
created = 2026-11-08
updated = 2026-11-13
touched = 2026-11-13
closed = 2026-11-13
first_closed = 2026-11-13
accepted_by = "charlie"
accepted_at = 2026-11-13
accepted_ts = "2026-11-13T09:32:09+01:00"
tags = ["watch", "g7", "crash"]
files = ["Trio Watch App Extension/ExtensionDelegate.swift", "patches/09-watch-g7.patch"]
priority = 1

[[acceptance]]
id = "AC-1"
text = "ExtensionDelegate.handle(_:) no longer calls MainActor.assumeIsolated off main: it runs noteAcquisitionWake and WatchState.handleBackgroundTasks on main, inline when Thread.isMainThread and via DispatchQueue.main.async otherwise; the forwarding log line records on_main"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "commit"
evidence = "feature/watch-g7 fa7110af1: handle(_:) logs on_main, runs noteAcquisitionWake + handleBackgroundTasks via @MainActor handleBackgroundTasksOnMain, inline under assumeIsolated on main else DispatchQueue.main.async; codex-work gpt-5.6-terra review PASSED, 0 findings"
met_at = 2026-11-08
met_ts = "2026-11-08T11:33:43+01:00"
met_by = "claude-code"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"
renewed_at = "2026-11-09T12:51:43+01:00"
renewed_by = "claude-code"
renewal_evidence = "Patch 09 changed in 258850599 (TRIO-107: WatchTelemetryRing.swift + G7WatchSensorAdapter.swift only); its diff has no ExtensionDelegate.swift lines, and patches/09-watch-g7.patch at 258850599 still carries handleBackgroundTasksOnMain from fa7110af1"

[[acceptance]]
id = "AC-2"
text = "Patch 09 regenerated via mid-stack-update --cherry-pick; patch-test.sh passes with patch-audit PASSED; full diff of patch 09 vs the committed version touches only ExtensionDelegate.swift and provenance"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "c5e0b60d8 patch 09 regenerated via mid-stack-update --cherry-pick fa7110af1 (33->33 files, stack validation PASSED, drift CLEAN); ./scripts/patch-test.sh exit 0, patch-audit PASSED, pump-migration sentinel intact; patch diff vs 853bf8f67 = ExtensionDelegate.swift handle(_:) + provenance only"
met_at = 2026-11-08
met_ts = "2026-11-08T11:33:50+01:00"
met_by = "claude-code"
met_commit = "c5e0b60d8dae6e5a5eb5d167b6d7768141d90fe4"

[[acceptance]]
id = "AC-3"
text = "Build 238 built and uploaded to TestFlight"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "ci/local-build.sh --no-sync-upstream from dev c5e0b60d8: archive + TestFlight upload succeeded 2026-11-08 11:41 (log build/artifacts/ci-local-build-20261108-113345.log); release trio-v1.0.2-238-localCI; watch dSYM UUID 04F19366 (arm64) contains handleBackgroundTasksOnMain at ExtensionDelegate.swift:91"
met_at = 2026-11-08
met_ts = "2026-11-08T11:48:20+01:00"
met_by = "claude-code"
met_commit = "c5e0b60d8dae6e5a5eb5d167b6d7768141d90fe4"

[[acceptance]]
id = "AC-4"
text = "On device: no new Trio Watch App SIGTRAP crash reports on BLE wakes after installing build 238, and the watch reads EGVs directly"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "operator"
evidence = "Verified by charlie on the board"
met_at = 2026-11-13
met_ts = "2026-11-13T09:32:03+01:00"
met_by = "charlie"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"

[[sessions]]
host = "claude-code"
ref = "d12ac37b-8d3a-44b1-913a-0c9015c2dabe"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T10:30:25+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[reviews]]
run_id = "e47e600e-898c-4927-8700-1b496a62df59"
model_family = "codex"
verdict = "pass"
reviewed_commit = "fa7110af19fcac8ab0344f75342b6528f7e615a4"
recorded_at = "2026-11-08T10:33:42+00:00"
+++

## Intent

Watch app crashes (EXC_BREAKPOINT / SIGTRAP) on every G7 Bluetooth wake in builds 236 and 237. 16 unique crash reports from 2026-11-07 14:59 to 2026-11-08 10:39 share one stack: `MainActor.assumeIsolated` ← `ExtensionDelegate.handle(_:)` (ExtensionDelegate.swift:83), triggered on `com.loudnate.CGMBLEKit.bluetoothManagerQueue`. WatchKit delivers `WKApplicationDelegate.handle(_:)` on CoreBluetooth's delegate queue during a BLE wake, so the assumption in patch 09 that it runs on main is false and the runtime check traps. The app dies around connect/auth before any EGV is read, which is the "watch loses the link before auth" symptom.

Fix (patch 09, `feature/watch-g7`): `handle(_:)` logs whether it is on main, then runs its body (`noteAcquisitionWake` + `WatchState.handleBackgroundTasks`) on the main thread, inline when already on main and via `DispatchQueue.main.async` otherwise. No dosing code; watch-only.

Operator asked 2026-11-08: "Yes fix it here. To build and deploy to TestFlight".
