+++
uid = "01a18434-1eb5-710a-a658-8f8c459375e1"
key = "TRIO-094"
title = "G7SensorKit: opt-in active 0x59 backfill request on sequence gap, behind a default-off G7 settings toggle (phone)"
status = "review"
kind = "code"
source = "human"
created = 2026-10-28
updated = 2026-10-28
touched = 2026-10-28
tags = ["g7", "ble", "g7sensorkit", "backfill"]
priority = 2
parent = "01a18464-7f48-7364-8944-b13bdac2ec28"

[[acceptance]]
id = "AC-1"
text = "Toggle: new G7CGMManagerState key (absent reads false), a row in G7SettingsView next to Upload Readings labelled experimental, persisted, and passed to G7Sensor; changes take effect from the next connection"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Static diff review 2026-10-28 (fork working tree on 1f12fea): G7CGMManagerState.requestMissedReadings (absent reads false), G7CGMManager property persists via mutateState and pushes to G7Sensor at init and on set; G7SettingsView toggle 'Request Missed Readings (Experimental)' bound via G7SettingsViewModel."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:53+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-2"
text = "Off path identical except the AC-10 upstream notification fix: with the toggle off the new backfill-request code returns at its first statement; no other change to call order, GATT ops, timeouts or existing telemetry formats (static full-diff review)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Static full-diff review plus Luna review 4 (/Users/charlie/Code/personal/health/diabetes/G7SensorKit/.task-relay/notes/20261028-220657-92787-codex-work-review.md): toggle off adds no GATT op; requestMissedReadingsIfNeeded's first statement is the guard; flushBackfillBuffer unchanged except a no-op hook; only off-path change is the AC-10 fix and its telemetry."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:53+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-3"
text = "On path: on an EGV with sequenceGap > 1, after the existing backfill subscribe, write 0x59 | start UInt32 LE | end UInt32 LE (sensor seconds) .withResponse to control; start = last pre-gap reading's sensor time, end = current EGV's; clamp to >= activation and <= 3 h span; at most one request per connection; watch hosts unaffected (toggle never set there)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Static review: on sequenceGap > 1 after the backfill subscribe, one 0x59|start|end LE write (.withResponse, 1 s, op write_control_backfill_request) per connection; range is glucose time (prior+1 .. current-1), clamped to 3 h and >= 0; generation check skips stale perform blocks; watch never sets the flag. Not built or run."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:53+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-4"
text = "Telemetry, new events only (none while off): backfill_request_sent (start/end sensor s and ISO wall dates, sequence_gap, prior and current sequence), backfill_request_failed (error), backfill_request_result per requested connection (records received, first/last reading ISO dates, records inside the requested range)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Static review: new events backfill_request_sent/_failed/_skipped/_result (ack-attributed via DiaBLE layout, in-range records, other_acks), emitted only when a request was attempted; existing event formats unchanged."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:53+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-5"
text = "Static review of the complete diff vs base plus codex-work review (gpt-5.6-luna, high) with no unresolved findings"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "codex-work gpt-5.6-luna high, four rounds: 214838-1956 (2 MEDIUM, fixed), 215542-37790 (1 MEDIUM fixed; sequence wrap and scan-telemetry declined, accepted by reviewer), 220054-62215 (2 MEDIUM, fixed), 220657-92787 (no real bugs). Notes in /Users/charlie/Code/personal/health/diabetes/G7SensorKit/.task-relay/notes."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:54+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-6"
text = "Fork change committed and pushed (G7SensorKit is agent.signing = deny)"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "operator"
evidence = "Operator pasted terminal output in chat 2026-10-28 showing 'git commit' [main a1f2474] (TRIO-093) and [main 7fa073c] (TRIO-094) in ~/Code/personal/health/diabetes/G7SensorKit, then 'git push': '1f12fea..7fa073c  main -> main' to https://github.com/cachrisman/G7SensorKit."
met_at = 2026-10-28
met_ts = "2026-10-28T22:18:49+01:00"
met_by = "charlie"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-7"
text = "Repin patch 02 via mid-stack-update.sh and run patch-test.sh clean"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "./scripts/repin-g7.sh 2026-10-28 (v1.2, no push): '7fa073c… is on origin (origin/main); no push needed', patch 02 rewritten dd91f465b..7fa073c2a, patch-test.sh: all 16 patches applied, patch-audit passed (47 warnings, pump-migration sentinel present)"
met_at = 2026-10-28
met_ts = "2026-10-28T22:33:05+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[acceptance]]
id = "AC-8"
text = "Run the on/off test protocol on a bad sensor and report Dexcom app health (no new signal-loss alerts, Share still on time)"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28

[[acceptance]]
id = "AC-9"
text = "Analyze on vs off windows: requests sent, readings recovered, Trio backfill rows reaching Nightscout (no device, insert lag >= 4 min, matched to backfill_request_result dates), Share-only slot rate, Share timeliness, command_timeout rate"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-28

[[acceptance]]
id = "AC-10"
text = "On every path (operator 2026-10-28: 'Fold it in for every path'), G7PeripheralManager delivers unmatched notifications to the delegate even while a command is pending, as upstream 764e002 does; each such delivery the old gate would have dropped is counted and logged (unmatched_notification_while_pending with characteristic, first byte, pending op; rate-limited, with a per-connection summary)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-28
evidence_kind = "run"
evidence = "Static review: didUpdateValueFor delivers unmatched notifications unconditionally (upstream 764e002); deliveries while a command is pending emit unmatched_notification_while_pending (control/auth always, others first 3 per connection) and a per-connection summary at disconnect; currentCommandOp set and cleared under commandLock."
met_at = 2026-10-28
met_ts = "2026-10-28T22:10:54+01:00"
met_by = "claude-code"
met_commit = "478413770a1d51f92f08a7d8919ae6813effc325"

[[sessions]]
host = "claude-code"
ref = "76845c1e-cc16-4a52-9b08-b31f992621bf"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T20:48:17+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "bd0d4eab-cb85-4faf-a76f-1218cb573e0d"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T20:55:38+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "ec5c756d-f448-41ad-9c2f-3f4d37b1fce3"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:00:51+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[sessions]]
host = "claude-code"
ref = "f9d6dcbb-e5a3-4f60-a2a7-c7c7989d8dfb"
model_family = "claude"
started = 2026-10-28
role = "author"
started_at = "2026-10-28T21:06:54+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"
+++

## Intent

Let Trio's phone ask the G7 sensor for readings it missed, straight over Bluetooth, so a missed slot comes back from the sensor a few minutes later without going through Dexcom Share and Nightscout. The request is behind a G7 settings toggle that defaults to off. With the toggle off, behavior is identical to the current code. The operator will turn it on for time-boxed tests and off again.

## Why

TRIO-036 (2026-10-28 update) found that passive backfill overhearing on the phone fills almost no missed slots. On DXCM8o, ~1,028 of ~1,030 phone backfill entries in 8 days just repeated the current reading. An active `0x59` request is the only Bluetooth route to the missed readings. The operator decided TRIO-036 AC-5 in chat on 2026-10-28: relax the passive contract for this one request only, behind a default-off toggle. They want the offline route tried before automatic Share/Nightscout gap-fill.

## Design

- **Request format**, from upstream LoopKit `requestBackfillIfNeeded` (commit `764e002`, TRIO-036 AC-4): `0x59 | start UInt32 LE | end UInt32 LE`, seconds since activation, written `.withResponse` to the control characteristic.
- **Toggle**: a new `G7CGMManagerState` key (absent reads as false) and a row in `G7SettingsView` next to "Upload Readings", labelled as experimental. The value is passed to `G7Sensor`.
- **Off path**: the new code returns at its first statement. No other connection-path change, and no new telemetry while off.
- **On path**: on a connection with an EGV and `sequenceGap > 1` (already computed in `handleGlucoseMessage`), after the existing backfill subscribe, write one request covering last reading → now, capped (a few hours). At most one request per connection. Telemetry is emitted for the send and its outcome.
- **Scope**: phone only. The watch runs `G7Sensor` without the settings screen, so the watch is a follow-up once phone results are in.
- **Repos**: the fork only, plus the usual patch 02 repin. The fork is `agent.signing = deny`, so the operator commits and pushes.

Provenance (Nightscout tagging, BetterStack fields) is being checked before implementation; ACs follow from that check.

## Provenance check (2026-10-28, before implementation)

**In Trio.** Live and backfilled G7 samples are built identically in the fork (`G7CGMManager.swift` live ~L505, backfill ~L560). `PluginSource.readCGMResult` then drops `syncIdentifier` and `device` and assigns a fresh UUID. `GlucoseStored` has no source field. Backfill samples older than the newest reading go through `BaseGlucoseStorage.backfillGlucose`, which drops anything within ±3.5 min of a stored row (silently, no log), stores survivors with `isUploadedToNS=false`, and uploads them. A backfill-only batch does not trigger a loop run. Trio's NS payload is `id, sgv, direction, date, dateString, filtered, unfiltered, glucose, type`, with no `device`.

**In Nightscout (nightscout-nextjs).**
- Ingest is v1 `entrySchema.passthrough()`, so extra fields are kept. Upsert matches exact `{sysTime, type}` and fully replaces the doc, keeping `_id`.
- The Share cron writes `device: dexcom-share` plus Share's `trend`, and skips a reading within ±150 s of any existing sgv.
- Nothing stops a Trio upload landing seconds away from an existing Share doc. That gives two docs for one slot.
- MCP provenance exposes `device`, `insertedAt`/`insertLagSec`, `clientId` and `trend`. It does not expose `srvModified` or custom fields.

**Consequences for this task.**
- **No Trio or Nightscout change is needed to analyse the test.** A Trio backfill row in NS is an untagged doc with insert lag ≥ about 4 min. It is matched exactly by reading time to `backfill_request_result` in BetterStack, which retains about 8 days, so analysis must happen within a week of a test.
- **Known side effect:** when Share has already gap-filled a slot, a recovered reading lands in NS as a second doc beside the Share doc (Trio's 3.5 min dedup only sees Trio's own store). This is cosmetic for the test. A server-side near-duplicate rule in nightscout-nextjs is a separate follow-up.
- **Per-source tagging is out of scope.** A `device` tag on Trio uploads would need a Core Data attribute, a `BloodGlucose` field and a `PluginSource` change. It is a separate decision if the feature is kept.

## External validation (2026-10-28 web/code research)

**Confirmed by independent code:**
- The request format is `0x59 | start i32/u32 LE | end LE`, in seconds since activation. Sources: Juggluco `askfilldata` (`Common/src/main/cpp/dexcom/java.cpp`), xDrip+ `BackFillTxMessage2` (LITTLE_ENDIAN, sent from `Ob1G5StateMachine.backFillIfNeeded`, native mode), DiaBLE `DexcomG7.swift:290-296` (`.withResponse`), and LoopKit `requestBackfillIfNeeded`.
- Records are 9 bytes, and the sensor packs two per notification (upstream next-dev `G7Sensor.swift:868`; the fork already splits batches since TRIO-028).
- The `0x59` acknowledgement arrives after the records and acts as the end marker (next-dev `G7Sensor.swift:837`). DiaBLE decodes it as status, length, CRC, first sequence, first timestamp and last timestamp.
- The request cap is 24 h, and the sensor omits what it no longer holds (next-dev `G7Sensor.swift:129`).

**Passive-mode precedent:**
- Control writes from a passive client already ship. Loop sends `0x52` (G7SensorKit PR #48). xDrip4iOS "coexistence" writes `0x52/0x4A/0x22/0x34/0x32`.
- No public example exists of a passive client sending `0x59`.
- xDrip4iOS's G6 transmitter deliberately suppresses backfill in coexistence (`CGMG5Transmitter.swift:1317`, reason unstated).
- gui-dos (G7SensorKit #45) warned that backfill in passive mode needs care to finish before the Dexcom app sends its disconnect (`0x09`).
- No reports were found of effects on Share, Clarity or alerts, positive or negative.

**Write collision (drives the new AC):** Pete's next-dev `G7PeripheralManager.swift:523-529` delivers a notification "Unconditionally, pending command or not". The reason given is that a backfill write in flight threw the glucose reply away, "Seen in the field as signal loss". The fork still has the old gate, `else if commandConditions.isEmpty { notifyDelegate = true }`, so a notification arriving while a command is pending is dropped. TRIO-094 bypasses the gate only while its own request is outstanding. Whether the gate also costs readings on today's off path (for example an auth value landing while the auth subscribe is pending) is an open question for a separate task.

**Upstream reports of the same missed-reading symptom:** nightscout/Trio #1610 ("just a drawback of passive reading consumption"), #1384 (auth/backfill notify timeouts), #1521; G7SensorKit PR #62. None attributes misses to a specific sensor, arm or watch, and none raises the 2 s timeout.

**iOS shared link:** Apple's `cancelPeripheralConnection` docs say other apps may keep the physical link up. That one app's ATT requests queue behind another's is not documented anywhere found, so treat it as unverified.

## Test protocol (post-deploy, AC-8 and AC-9)

**Run it on a bad sensor.** DXCM8o ends around 11-03, or 11-08 if it is a 15-day sensor. A good sensor gives too few gaps to measure. BetterStack keeps about 8 days, so analyse each run within a week.

1. **Baseline: toggle off, at least 24 h on the new build.**
   - Note: the unconditional notification delivery is live on this path.
   - Check `unmatched_notification_while_pending`, especially `char=control opcode=0x4E`, which marks glucose replies the old gate would have dropped.
   - Check `command_slow`, `command_timeout`, `egv_received` per hour and the Share-only slot rate, compared with the days before the install on the same sensor.
2. **On/off windows.**
   - Turn the toggle on for 4–6 h while you can watch the phone, then off for an equal window at a similar time of day.
   - Repeat 2–3 times over 2–3 days, alternating which comes first.
   - Mark each flip with a Trio note, such as "backfill on" or "backfill off". The toggle itself is not logged.
3. **Stop at once and turn it off if any of these happen:**
   - the Dexcom app shows a signal-loss alert or an error it didn't show before;
   - `dexcom-share` entries in Nightscout stop or start arriving late;
   - Trio's live `egv_received` rate drops below the off-window rate;
   - `suspected_end_of_session` events appear;
   - `backfill_request_failed` repeats on most gaps.
4. **What "working" means:**
   - most `backfill_request_sent` events are followed by `backfill_request_result` with `records >= 1` and `finished=true`;
   - the recovered readings appear in Trio's history, and in Nightscout as untagged docs with insert lag of 4 min or more at the `first_date`..`last_date` times;
   - the Share-only slot rate is lower in on windows than in off windows;
   - the Dexcom app and Share are unchanged: the same `dexcom-share` docs per hour, the same Share insert lag, and no new alerts.
5. **Analysis (AC-9).** Per window, from BetterStack (source 1659391, `platform=ios`) and Nightscout MCP provenance:
   - requests sent, failed, skipped and attributed (`other_acks`);
   - readings recovered, `in_range`;
   - Trio backfill rows that reached NS;
   - Share-only rate;
   - Share timeliness;
   - `command_timeout`, `command_slow` and `unmatched_notification_while_pending` rates.
   Record the verdict here.

## Review history

Implemented with the claude backend in four passes (notes `20261028-214545-88798`, `-215321-25356`, `-220017-58584`, `-220514-82484`, in `G7SensorKit/.task-relay/notes/`). Reviewed with codex-work `gpt-5.6-luna` at high effort:

1. **`214838-1956`: NEEDS-FIX.** A stale perform block could write on a newer connection. The Dexcom app's own `0x59` ack could be misattributed. Both were fixed with a connection-generation check, an end of current − 1, and ack attribution by first/last timestamp.
2. **`215542-37790`: NEEDS-FIX.** Records already buffered when the request started were not counted; fixed. The reviewer accepted two declines: UInt16 sequence wrap (about 227 days, longer than any sensor) and losing telemetry on `scanForNewSensor` (telemetry-only).
3. **`220054-62215`: NEEDS-FIX.** The range used message time instead of glucose time. The seeding read `backfillBuffer` off its queue. Fixed: glucose timestamps throughout, and accumulation only in `flushBackfillBuffer`.
4. **`220657-92787`: no real bugs.**

The operator decided on 2026-10-28 to apply upstream's unconditional notification delivery ("Fold it in for every path"). `tasks review` records wait for a resolvable commit (fork push plus patch 02 repin), as with TRIO-093. Not compiled.

## Release note

G7: new experimental setting, **Request Missed Readings**, in the G7 settings screen (off by default). When it is on and the phone misses a reading, Trio asks the sensor for the missed readings on the next connection. Also fixed: an incoming Bluetooth message is no longer dropped when it arrives while Trio is waiting on its own request.
