+++
uid = "01a18378-2d41-727e-8369-e3a910f8410e"
key = "TRIO-093"
title = "G7SensorKit: raise foreground GATT op timeout 2s to 5s (phone + watch) and add command_slow telemetry"
status = "review"
kind = "code"
source = "human"
created = 2026-10-28
updated = 2026-10-28
touched = 2026-10-28
tags = ["g7", "ble", "g7sensorkit"]
priority = 2
files = ["G7SensorKit/G7CGMManager/G7PeripheralManager.swift"]
parent = "01a18464-7f48-7364-8944-b13bdac2ec28"

[[acceptance]]
id = "AC-1"
text = "Foreground timeout is 5 s for applyConfiguration (discover services, discover characteristics, notify enables) and for the UUID setNotifyValue overload used by listenToCharacteristic, on iOS and watchOS; a backgrounded watch gets 6 s at both sites; one helper feeds both"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "uncommitted fork diff on G7SensorKit main @1f12fea, G7PeripheralManager.swift +23/-9; read in full 2026-10-28; codex-work gpt-5.6-luna review 1d718259 (G7SensorKit/.task-relay/notes/20261028-181318-40983-codex-work-review.md) found no bugs. Not compiled (no build run)."
met_at = 2026-10-28
met_ts = "2026-10-28T18:16:13+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-2"
text = "runCommand emits command_slow (op, elapsed_ms, timeout_s) when an op completes after more than 2 s; command_timeout output is unchanged"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "uncommitted fork diff on G7SensorKit main @1f12fea, G7PeripheralManager.swift +23/-9; read in full 2026-10-28; codex-work gpt-5.6-luna review 1d718259 (G7SensorKit/.task-relay/notes/20261028-181318-40983-codex-work-review.md) found no bugs. Not compiled (no build run)."
met_at = 2026-10-28
met_ts = "2026-10-28T18:16:13+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-3"
text = "Full diff vs fork main reviewed statically: only G7PeripheralManager.swift changes; removed lines are only the replaced timeout constant/defaults, the single NSCondition wait and the notify-state match; other timeouts (1 s extended version write, connect gate, scanAfterDelay, C3 ladder) untouched"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "uncommitted fork diff on G7SensorKit main @1f12fea, G7PeripheralManager.swift +23/-9; read in full 2026-10-28; codex-work gpt-5.6-luna review 1d718259 (G7SensorKit/.task-relay/notes/20261028-181318-40983-codex-work-review.md) found no bugs. Not compiled (no build run)."
met_at = 2026-10-28
met_ts = "2026-10-28T18:16:13+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-4"
text = "Fork change committed and pushed to cachrisman/G7SensorKit main"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "operator"
evidence = "Operator pasted terminal output in chat 2026-10-28 showing 'git commit' [main a1f2474] (TRIO-093) and [main 7fa073c] (TRIO-094) in ~/Code/personal/health/diabetes/G7SensorKit, then 'git push': '1f12fea..7fa073c  main -> main' to https://github.com/cachrisman/G7SensorKit."
met_at = 2026-10-28
met_ts = "2026-10-28T22:18:48+01:00"
met_by = "charlie"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-5"
text = "Patch 02 repinned to the new fork commit via mid-stack-update.sh and patch-test.sh passes"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "./scripts/repin-g7.sh 2026-10-28 (v1.2, no push): '7fa073c… is on origin (origin/main); no push needed', patch 02 rewritten dd91f465b..7fa073c2a, patch-test.sh: all 16 patches applied, patch-audit passed (47 warnings, pump-migration sentinel present)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:04+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-6"
text = "After install, BetterStack shows command_slow events and a lower phone command_timeout rate, and the Share-only slot share is compared on the same sensor before vs after (classify.py)"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28

[[acceptance]]
id = "AC-7"
text = "runCommand waits in a predicate loop on commandConditions.isEmpty against a fixed deadline, so a spurious NSCondition wakeup is not treated as completion (review 6db2b532 LOW)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "uncommitted fork diff on G7SensorKit main @1f12fea, G7PeripheralManager.swift +23/-9; read in full 2026-10-28; codex-work gpt-5.6-luna review 1d718259 (G7SensorKit/.task-relay/notes/20261028-181318-40983-codex-work-review.md) found no bugs. Not compiled (no build run)."
met_at = 2026-10-28
met_ts = "2026-10-28T18:16:13+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-8"
text = "didUpdateNotificationStateFor matches the pending condition by UUID when the callback carries an error, so a failed enable surfaces cbPeripheralError instead of waiting out the 5-6 s timeout (review 921efea1 MEDIUM)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "uncommitted fork diff on G7SensorKit main @1f12fea, G7PeripheralManager.swift +23/-9; read in full 2026-10-28; codex-work gpt-5.6-luna review 1d718259 (G7SensorKit/.task-relay/notes/20261028-181318-40983-codex-work-review.md) found no bugs. Not compiled (no build run)."
met_at = 2026-10-28
met_ts = "2026-10-28T18:16:13+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[sessions]]
host = "claude-code"
ref = "618a92ab-9657-4fb2-b997-768de30294a1"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "a67e3b1e-ae11-4058-a5ad-d12232783ede"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "fec5b55a-1401-406d-8895-a7aab02bcc1b"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"
+++

## Intent

Raise the G7SensorKit fork's foreground GATT operation timeout from 2 s to 5 s, on the phone and on the foreground watch. It covers discover services, discover characteristics and the notify enables. Also add telemetry for operations that finish late, so the effect can be measured.

## Why

The 2026-10-28 investigation is in `docs/investigations/2026-10-28-g7-phone-missed-readings/README.md`. It found the phone's missed-reading rate tracks the individual sensor: 4–5% on good sensors and 20–24% on bad ones, with the same build. On the current bad sensor (DXCM8o, left arm), misses are mostly `command_timeout` on `discover_services` or `set_notify_authentication`. 86–92% of those timeouts fire while the peripheral is still connected. In 29% of auth-timeout misses the reply arrived 1–2 s after the 2 s timeout (39% counting any late completion). The sensor drops the link 7–10 s after connect, so a 5 s timeout still fits inside the window.

The fork already uses 6 s for a backgrounded watch (C-217 W-1). That applies only to `applyConfiguration`. The `setNotifyValue(_:for: CGMServiceCharacteristicUUID, timeout: = 2)` overload, used by `listenToCharacteristic(.authentication/.control/.backfill)` in `G7Sensor.swift`, stays at 2 s even on a backgrounded watch.

## Scope

- `G7SensorKit/G7CGMManager/G7PeripheralManager.swift` in the standalone fork clone (`~/Code/personal/health/diabetes/G7SensorKit`, `main`).
- Foreground value 2 → 5 s on every host (operator, 2026-10-28: make it work for the watch too, unless there is a specific reason not to). The backgrounded watch keeps 6 s.
- One host-aware helper feeds both sites, `applyConfiguration` and the UUID `setNotifyValue` overload, so the two can't drift apart again.
- New `command_slow` telemetry: an op that completes after more than 2 s emits `op`, `elapsed_ms` and `timeout_s`. This counts what the longer timeout rescues.
- Not touched: the 1 s `write_control_extended_version` timeout, the connect gate, `scanAfterDelay`, the C3 retry ladder.

## Expected effect and limits

The ceiling is the late-reply share of timeout misses, about 30–40%. On DXCM8o that means roughly 24% → 15–17% Share-only slots. The other ~60% of timeout misses never get a reply before the sensor drops the link, so no timeout value helps them. Risk: on a dead link the queue can now block up to 5 s per op instead of 2 s, which is still inside the connection window.

## Process

Implement via task-relay (claude backend), review with codex-work (`gpt-5.6-luna`, operator's choice for this task). The fork is `agent.signing = deny`, so the operator commits and pushes it. Then repin patch 02 from Trio-dev with `mid-stack-update.sh` and run `patch-test.sh`. Build only on request.

## Review history (fork change, uncommitted on G7SensorKit main @1f12fea)

All reviews ran on codex-work with `gpt-5.6-luna` at high effort. The notes are in `G7SensorKit/.task-relay/notes/`. They are not recorded in `reviews[]` yet, because a review there has to pin a commit in this repo and the fork change has no commit yet. Record them once the fork commit exists and patch 02 is repinned here.

- **6db2b532:** NEEDS-FIX. LOW: a spurious NSCondition wakeup was read as completion. Fixed with a predicate loop (AC-7). MEDIUM: sequential 5 s ops can exceed the 7–10 s window. Not changed: ops that slow fail at 2 s too, so the only cost is a dead op using 5 s instead of 2 s before the C3 retry. AC-6 measures it.
- **921efea1:** NEEDS-FIX. Accepted the window reasoning as a monitored tradeoff. MEDIUM: a failed notify enable never matched its condition and waited out the timeout. Fixed (AC-8).
- **1d718259:** no real bugs, no suggestions.

Author sessions: claude, three implement runs. The reviewer family (codex) differs.

## Release note

G7: Trio now waits up to 5 seconds instead of 2 for each Bluetooth step when connecting to the sensor, on the phone and on the watch in the foreground. On some sensors the reply often arrives just after 2 seconds, and that reading used to be missed.
