+++
uid = "01a18629-b9d2-7573-9a69-01f069935b58"
key = "TRIO-099"
title = "G7SensorKit: log the Request Missed Readings toggle (on change and at launch) and a skip reason for every gap the request path passes over"
status = "in-progress"
kind = "code"
source = "human"
created = 2026-10-29
updated = 2026-10-29
touched = 2026-10-29
parent = "01a18629-b536-77bb-880c-bb88484be460"
priority = 1

[[acceptance]]
id = "AC-1"
text = "Setting change emits backfill_toggle enabled=<new> previous=<old> (only when the value changes); the first glucose message after each app launch emits backfill_toggle_state enabled=<value> (not at G7CGMManager init: the host installs G7Telemetry.emit after the CGM manager exists, so an init-time event is dropped)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "run"
evidence = "Static diff review 2026-10-29 (fork working tree on 7fa073c): G7CGMManager setter reads the old value and emits backfill_toggle enabled/previous only when it changes; G7Sensor.handleGlucoseMessage emits backfill_toggle_state once per G7Sensor instance after egv_received, marked logged only when G7Telemetry.emit is set (review 518a02a6 LOW fixed). Not built."
met_at = 2026-10-29
met_ts = "2026-10-29T06:43:12+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-2"
text = "Every gap reaching requestMissedReadingsIfNeeded that sends no request emits backfill_request_skipped with reason disabled|not_current_sensor|host_backgrounded|already_requested_this_connection|empty_range; the existing stale_connection skip is unchanged"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "run"
evidence = "Static diff review 2026-10-29: requestMissedReadingsIfNeeded emits backfill_request_skipped reason=disabled (only when priorSequence != nil and sequenceGap > 1), not_current_sensor, host_backgrounded, already_requested_this_connection, empty_range; stale_connection unchanged. Watch-only background path (isHostBackgrounded is set only in G7WatchSensorAdapter) already logs background_gatt_skipped with sequence_gap. Not built."
met_at = 2026-10-29
met_ts = "2026-10-29T06:43:12+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-3"
text = "No behaviour change: static full-diff review shows only new emitG7Telemetry calls (no GATT op, guard order, timeout or existing event format change), plus a codex-work review with no unresolved findings"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "run"
evidence = "git diff on fork 7fa073c: +40/-5, the 5 removed lines are guard one-liners that now emit before the same return; no GATT op, guard order, timeout or existing event format change. codex-work gpt-5.6-terra high: 518a02a6 (1 MEDIUM declined as watch-only, 3 LOW: 1 fixed, 2 declined), e2bc9da3 no findings, declines accepted. Notes in G7SensorKit/.task-relay/notes."
met_at = 2026-10-29
met_ts = "2026-10-29T06:43:12+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-4"
text = "Fork change committed and pushed (G7SensorKit is agent.signing = deny)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "operator"
evidence = "Operator in chat 2026-10-29, asked whether the G7SensorKit fork fix 0b10d55 was committed and pushed: \"Yes\""
met_at = 2026-10-29
met_ts = "2026-10-29T10:07:13+01:00"
met_by = "charlie"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-5"
text = "After install, BetterStack shows backfill_toggle_state on launch and backfill_toggle on each flip on build 235"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-29
evidence_kind = "query"
evidence = "BetterStack source 1659391, 2026-10-29 10:44-10:48 UTC, build 235: ios and watchos each logged backfill_toggle_state enabled=false at 10:45:26 (first glucose message after launch); ios logged backfill_toggle enabled=true previous=false at 10:46:54 when the operator switched Request Missed Readings on. That was the only switch in the window; both devices also logged egv_received on 235."
met_at = 2026-10-29
met_ts = "2026-10-29T11:48:08+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"
build = "01a18629-b536-77bb-880c-bb88484be460"

[[sessions]]
host = "claude-code"
ref = "20261029-063829-53723-claude-implement"
model_family = "claude"
started = 2026-10-29
role = "author"
started_at = "2026-10-29T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "20261029-064100-direct-g7sensor-emit-guard"
model_family = "claude"
started = 2026-10-29
role = "author"
started_at = "2026-10-29T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"
+++

## Intent

TRIO-094 added the Request Missed Readings toggle but logs nothing about its state: the setter in G7CGMManager only persists it, and with the toggle off requestMissedReadingsIfNeeded returns at its first guard without an event. An off window and an on window with no gaps look identical in BetterStack, so the TRIO-094 on/off analysis would have depended on the operator reporting flip times in chat. The operator had asked for exactly this logging check before build 234.

Audit (2026-10-29) of what the analysis needs vs what is logged: egv_received carries sequence (gaps derivable); backfill_request_sent/_failed/_result, backfill_finished/_flush exist. Missing: the toggle state, and four silent exits on the on path (sensor name != sensorID, host backgrounded, already requested this connection, empty range).

## Fix

- On a change of the setting, emit backfill_toggle enabled=<new> previous=<old>.
- At G7CGMManager init (each app launch), emit backfill_toggle_state enabled=<value>.
- On every gap (prior sequence known, sequenceGap > 1) that reaches requestMissedReadingsIfNeeded and does not send a request, emit backfill_request_skipped with a reason: disabled, not_current_sensor, host_backgrounded, already_requested_this_connection, empty_range. The off path gains only these log lines; no GATT op, call order or timing change.

## Review history

Implemented with the claude backend (note `20261029-063829-53723-claude-implement.md` in `G7SensorKit/.task-relay/notes/`), plus a two-line direct repair. Reviewed with codex-work `gpt-5.6-terra` at high effort:

1. **`20261029-063931-57818` (run 518a02a6): findings.**
   - Fixed: the per-launch flag was set even while `G7Telemetry.emit` was nil (LOW). It is now marked logged only once a sink exists.
   - Declined: the backgrounded gap bypass (MEDIUM). `isHostBackgrounded` is set only by the watch adapter, the toggle is phone-only, and that path already logs `background_gatt_skipped`.
   - Declined: the setter compound race (LOW), because there is a single main-thread writer.
   - Declined: per-instance rather than per-process scope (LOW). An extra state event is harmless.
2. **`20261029-064131-67336` (run e2bc9da3): no findings.** The reviewer accepted the declines.

`tasks review` refused to record both verdicts: it requires a `--reviewed-commit` in this repo, and the reviewed code is a fork working tree. The notes above are the review record.
