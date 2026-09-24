+++
uid = "01a0a9e6-9b2d-7163-a1df-70b7675af60d"
key = "TRIO-056"
title = "Sync dev with upstream 1.0.0.3 (66 commits: DosingMode, telemetry bootstrap move), reconcile patches 06/10/13, ship TestFlight build with patch 15"
status = "done"
kind = "code"
source = "human"
created = 2026-09-16
updated = 2026-09-23
touched = 2026-09-23
closed = 2026-09-23
first_closed = 2026-09-23
accepted_by = "Charlie"
accepted_at = 2026-09-23
owner = "me"
tags = ["upstream-sync", "patch-stack", "testflight"]
parent = "01a0aa42-ff8d-77fe-9978-f6b2a37397b3"

[[sessions]]
host = "claude-code"
ref = "88c4fdeb-ecce-44fd-a803-9a7d6b0cd964"
model_family = "claude"
started = 2026-09-16
role = "author"
started_at = "2026-09-16T11:34:02+00:00"

[[reviews]]
run_id = "3cb272ea-1f69-47f8-bfe6-2e8a012d1fc5"
model_family = "codex"
verdict = "waived"
reviewed_commit = "1095b0957b47a10ec043a0fc2458d29d4cb7d4bc"
reviewed_paths = ["patches/01-ns-richer-settings.patch", "patches/06-cloud-logging.patch", "patches/10-watch-session-crash-guard.patch", "patches/13-phone-ble-observer-telemetry.patch"]
recorded_at = "2026-09-16T11:38:34+00:00"
+++

## Intent

Operator instruction 2026-09-16: pull in upstream 1.0.0 via method #1 — ci/local-build.sh --base-branch dev does the fetch/merge/push of dev itself (operator-authorized push for this run), then reconcile the three patches that conflict with upstream 3ed723029 (telemetry bootstrap moved from AppDelegate.didFinishLaunching to TrioApp.startTelemetry()), re-run the build with --no-sync-upstream, deploy to TestFlight. Operator also approved converting upstream's force-unwrap in startTelemetry() to guard let telemetry = resolveOrLog(TelemetryClient.self) else { return } inside patch 10.

## Steps
- dev 690212d04 -> script merged upstream/dev cfba1ff18 as 2516b23c4 (Trio Patch Bot, unsigned — the script's own merge) and pushed origin/dev; first run failed at patch 06 as predicted.
- feature/cloud-logging 47b993221, feature/watch-session-crash-guard ff05a57e9, feature/phone-ble-observer-telemetry ec910b7ab: merged dev, resolved AppDelegate.swift (06) and TrioApp.swift loadServices (10, 13). Hazard found: git rerere replayed a throwaway sim resolution that had dropped the resolveOrLog definition — forgotten and redone by hand; verify rerere entries before trusting an auto-resolved merge.
- Patches 06/10/13 regenerated with mid-stack-update.sh --force-from-feature-branch; old-vs-new add/delete sets: 06 identical (context only), 13 identical, 10 differs only by the guard-let swap. patch-test.sh + patch-audit PASSED (10 patches). Committed 227d9cf28.
- Second build: ci/local-build.sh --base-branch dev --no-sync-upstream (sync already done; flag only suppresses the script's push).

## Acceptance criteria
- [x] TestFlight build (226) uploaded from dev 227d9cf28 = upstream 1.0.0.3 + patches 01,02,05,06,08,09,10,13,14,15
- [ ] BetterStack: forecastedLow/carbsRequired issueAlert cadence on the new build no longer at loop cadence
- [ ] Operator: push dev (227d9cf28) to origin; open the upstream PR from fix/glucose-alarm-retract-scope


## Result (2026-09-16)

- Run 1 (script sync): merged upstream/dev cfba1ff18 → dev 2516b23c4, pushed origin/dev (script), failed at patch 06 as predicted.
- Run 2: Xcode had been updated to 27.0 (27A266a; build 225 was on 26.6) and its licence was unaccepted → agvtool refused at increment_build_number. Operator ran `sudo xcodebuild -license accept`.
- Run 3: archive failed — patch 01 `closedLoop: s.closedLoop` no longer compiles (#1511 replaced TrioSettings.closedLoop with dosingMode). feature/ns-richer-settings merged dev + one-line fix `closedLoop: s.dosingMode == .closed` (8e3393872; upstream 05784c17f already reports dosingMode itself); patch 01 regenerated, delta exactly that line; dev 1095b0957.
- Run 4: **build 226 uploaded** to App Store Connect, release recorded (trio-v1.0.0-226-localCI, private backup). 14m56s on Xcode 27.0. First build on Xcode 27 — DVTCoreDeviceCore / CoreSimulator first-launch warnings in the log are benign (first-launch components not installed; `xcodebuild -runFirstLaunch` needs sudo).
- dev = 1095b0957 = upstream 1.0.0.3 + patches 01,02,05,06,08,09,10,13,14,15. origin/dev = 2516b23c4 → operator to push 227d9cf28 + 1095b0957.
- Reviews: patches 06/10/13/01 regenerated mechanically (line-set verified); no separate model review of the reconciliation — only the guard-let swap in 10 and the one-liner in 01 are new code (01 via claude backend run fe8c42ee/note 20260916-131656).


## Review (2026-09-16)

Codex (gpt-5.6-terra, high) on the regenerated patches 01/06/10/13 vs the merge commit: 0 high, 1 medium, 0 low — NEEDS-FIX. The medium is the provenance-trailer formatting (unindented PatchIds for merge commits), which is a pre-existing generator bug already present in the TRIO-052 patches and unrelated to the reconciled code; tracked as TRIO-057. No findings on the reconciliation content (tracker calls, telemetry start, guard-let failure mode, dosingMode mapping). Recorded as fail per the reviewer's verdict; waived below for acceptance because the fix belongs in the tooling task, not this sync.


Shipped in build 226 (TRIO-059).
