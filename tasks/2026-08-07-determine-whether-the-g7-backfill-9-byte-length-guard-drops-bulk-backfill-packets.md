+++
uid = "019fdc98-5a19-7363-bbd8-10ff27ce6fa4"
key = "TRIO-028"
title = "Determine whether the G7 backfill 9-byte length guard drops bulk backfill packets"
status = "in-progress"
kind = "code"
source = "human"
created = 2026-08-07
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["g7", "ble", "cgm"]

[[acceptance]]
id = "AC-1"
text = "Reject-path telemetry added to `didReceiveBackfillResponse` in the G7SensorKit fork, recording byte length (mirrors the existing `auth_payload_ignored` pattern in the same file)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-2"
text = "A confirmed phone-gap-then-reconnect event captured in BetterStack with the instrumentation live"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-3"
text = "Hypothesis (1) vs (2) resolved from that capture, and the verdict written into this task — **(2) refuted; (1) half right; two independent blockers identified**"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-4"
text = "If (2): handler made chunk-tolerant — **done in `bd248c6`**, parsing `count / 9` records. A 9-byte packet still yields exactly one record, so it is a strict superset of prior behaviour."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-5"
text = "If (2): recovered readings verified to reach the phone's Core Data store, not just the buffer — **still open on the phone.** The parser fix went to TestFlight in **build 220** (2026-08-16, G7SensorKit pinned to `3fb1105` via patch 02; 221 re-pins to `50c76a7`). Telemetry to watch for is unchanged: `backfill_batch bytes=18 records=2` (parser fired) followed by the reading reaching Nightscout/Core Data rather than only `backfill_entry`."
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "If (1): passive observation ruled out in writing — **(1) is refuted.** Backfill *does* reach a passive observer unprompted: the 2026-08-16 capture recovered four records, including one never seen live, without any request being sent."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-7"
text = "Non-multiple-of-9 lengths logged rather than silently dropped — shipped in build 219"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-8"
text = "Identify what the 20-byte high-entropy stream on `F8083536` is, or positively exclude it from the backfill path — [[TRIO-036]]"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-9"
text = "Port xDrip's sentinel (`byte[5]`/`[9]`/`[17] == 0x00`) so non-backfill traffic is classified rather than counted as a backfill failure — [[TRIO-036]], which also carries [[TRIO-033]]'s precondition that this be attempted only against real validation data"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-10"
text = "Implement form (2) parsing (sequence assembly + 4-byte length + **8-byte** records) so a pushed multi-record backfill would be captured if one ever arrives — [[TRIO-036]]"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-11"
text = "Verify the DiaBLE `0x59` + 8-byte start/end-timestamp request format against a real implementation before considering an active request — [[TRIO-036]]"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-12"
text = "Operator decision required: whether to relax the passive contract for an active `0x59` request — [[TRIO-036]]. **Not an agent decision** — it changes the fork from observer to participant"
owner = "operator"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-13"
text = "Update `egv-intervention-index.md`: `C-04-C1b/c` rationale (\"`0x59` format was unknown\") and the Idea #8 graveyard entry (\"no range-request exists\") are both contradicted by the above — [[TRIO-036]], pending its DiaBLE verification criterion"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "covered by TRIO-036 (migrated from [-])"
closed_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "20260815-153645-4357-ollama-implement.md"
model_family = "ollama"
started = 2026-08-15
role = "author"
started_at = "2026-08-15T13:39:40+00:00"

[[sessions]]
host = "claude-code"
ref = "e2363f9f-ebf9-44e5-acaf-d0b5b86f2aec"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T05:01:50+00:00"

[[sessions]]
host = "claude-code"
ref = "d6d91d4f-13ea-4273-bdfa-a3f4ce30d3db"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T05:01:50+00:00"
+++

## Intent

Motivating symptom: phone left in a locker for 1–2h (pool). On return the Dexcom app recovers the
missed readings from sensor storage; Trio does not, leaving a multi-hour hole in the phone's CGM
history.

`G7Sensor.bluetoothManager(_:didReceiveBackfillResponse:)` drops any backfill notification that is
not exactly 9 bytes, silently — no telemetry, no counter:

```swift
guard response.count == 9 else { return }        // G7Sensor.swift:470
if let msg = G7BackfillMessage(data: response) { backfillBuffer.append(msg) }
```

There are two competing explanations for why Trio never sees a multi-entry backfill, and the
existing telemetry **cannot distinguish them**, because it only counts packets that survived the
guard:

1. **Per-connection routing.** The G7 sends requested backfill only to the connection that asked
   (the Dexcom app's). Trio is a passive observer and never asked, so nothing is broadcast to it.
   Passive observation is then impossible and Nightscout is the only channel that can close the gap.
2. **Length-guard drop.** The sensor *does* notify all subscribed connections, but batches multiple
   9-byte records into one larger notification. Trio discards every such packet unparsed.

If (2), the fix is a parser change on a path we already own — instant, offline, authoritative, same
sensor, no Nightscout round-trip and no re-upload cascade. That is strictly better than every other
option, so this measurement gates the design.

## Evidence gathered 2026-08-07

- BetterStack source 1659391, 30 days: **438/438 `backfill_flush` events carry `count=1`** (ios 409,
  watchos 29). Zero multi-entry flushes ever observed. This is consistent with *both* hypotheses —
  it is a post-filter metric, so it cannot show dropped packets.
- `G7BackfillMessage` is a genuine fixed-width 9-byte record, one reading
  (`G7BackfillMessage.swift:29-34`). The `[G7BackfillMessage]` array and its accumulate-across-
  notifications design are correct; the suspect is admission to the array, not the array.
- The `== 9` guard is upstream (Pete Schwamb, `b1b5b34`, 2022-11-11, "Extracting G7 from CGMBLEKit"),
  **not** a fork regression. But upstream G7SensorKit also never requests backfill — same opcode
  table, no request opcode — so no user of this library has ever received a bulk response. The guard
  is well-tested against the routine single push and **untested against a bulk response**.
- No other length filter exists: `G7BluetoothManager.peripheralManager(_:didUpdateValueFor:)` passes
  `characteristic.value` straight through (`G7BluetoothManager.swift:1098-1109`).
- BLE plausibility: a notification carries up to MTU−3 bytes. At the default 23-byte MTU that is 20
  bytes — room for two records; with a negotiated MTU, dozens. Firmware answering a bulk range
  request has every reason to batch.
- `log.debug("Received backfill response: …")` already logs every packet's hex *before* the guard,
  but OSLog `.debug` is not persisted, so this cannot be checked retroactively.

## Scope

This task is the **measurement and the conditional parser fix**. Two adjacent items are deliberately
out of scope and tracked separately:

- Watch→phone EGV backfill — [[TRIO-024]].
- `handleSensorDidReadBackfill` discards received backfill on the watch (logs only, never stores) —
  [[TRIO-029]].

Impl plan: `docs/in-progress/g7-backfill-length-guard/impl-plan.md`.

## ✅ FINAL VERDICT 2026-08-16 — hypothesis (2) is CONFIRMED, exactly as first written

**Everything below this section that claims hypothesis (2) is refuted is wrong and superseded.**
It is kept as the record of how the wrong conclusion was reached, because the reasoning error is
worth not repeating.

### The decisive test

Operator-run, 2026-08-16: Bluetooth off on the phone for 16 minutes (three EGV slots), then back
on. Baseline anchored beforehand at seq 1298 (glucose 103, `08:16:48Z`).

At `08:33:46Z` the phone reconnected and the sensor sent **two notifications of 18 bytes each,
both `mod9=0`**:

```
bytes=18 mod9=0 payload=4EEE05006700060FF6 7AEF05006400060FF7
bytes=18 mod9=0 payload=A6F005006200060FF9 D2F105006000060FFA
```

Decoded as consecutive 9-byte records:

| # | hex | timestamp | glucose | state | dispOnly | trend | matches |
|---|---|---|---|---|---|---|---|
| 1 | `4EEE05006700060FF6` | 388686 | 103 | 6 | false | −1.0 | seq 1298 |
| 2 | `7AEF05006400060FF7` | 388986 | 100 | 6 | false | −0.9 | seq 1299 |
| 3 | `A6F005006200060FF9` | 389286 | **98** | 6 | false | −0.7 | **seq 1300 — never seen live** |
| 4 | `D2F105006000060FFA` | 389586 | 96 | 6 | false | −0.6 | seq 1301 |

Exact 300-second spacing; glucose tracks the live trend (108→103→100→**98**→96→93); record 3 is
the reading neither phone nor watch ever received. `backfill_finished bytes=19` followed.

**The sensor batches whole 9-byte records into one notification, and the `== 9` guard discards
them.** That is hypothesis (2) verbatim, and the fix is Phase 1 exactly as the plan first
specified: parse `count / 9` records when the length is a clean multiple of 9.

### Where the 2026-08-15 reasoning went wrong

The 650-packet, 20-byte, high-entropy capture analysed below **was** genuinely non-backfill — that
finding stands and the implementation still refuses it. The error was **over-generalising from a
single capture**: concluding batching was refuted, then modelling a sequenced-stream parser on
xDrip's shared G5/G6 path. The real G7 format is the simpler one the task named on 2026-08-07.

Cost of that error: ~205 lines of speculative parser, six reviewers, twenty defects (four
introduced by fixes to earlier findings), across roughly a day. A 16-minute radio-off test settled
it in minutes. **The plan's own rule — do not build Phase 1 speculatively — was correct and was
not followed.** The `mod9` field, added purely as a diagnostic, is what identified the format
instantly once real data arrived.

### Consequences

- The display-only limitation is **moot**: byte 7 of a real record is `0x0F`, so the 9-byte form
  carries the flag and parsing preserves it exactly.
- The unverified declared-length semantics are **moot** — there is no length header in this format.
- The `0x59` request question (`C-04-C1b/c`, Idea #8) stays open but is **no longer urgent**:
  backfill reaches a passive observer unprompted, as build 218 suggested and this capture proves.

### Second capture 2026-08-16 (30-minute gap) — format confirmed, and the `count=1` baseline explained

Operator-run 30-minute Bluetooth-off test, baseline seq 1342 (glucose 176, `11:56:49Z`). The
**watch** received the backfill at `12:22:04Z`:

```
backfill_len_rejected bytes=18 mod9=0 payload=0A230600AC00060EED 36240600B100060EF8
backfill_len_rejected bytes=18 mod9=0 payload=62250600B700060EFF 8E260600BD00060E03
backfill_entry        timestamp=403386 glucose=191
backfill_finished     bytes=19
backfill_flush        count=1
```

| record | ts | glucose | seq | fate |
|---|---|---|---|---|
| 1 | 402186 | 172 | ~1343 | **dropped** |
| 2 | 402486 | 177 | ~1344 | **dropped** |
| 3 | 402786 | 183 | ~1345 | **dropped** |
| 4 | 403086 | 189 | ~1346 | **dropped** |
| 5 | 403386 | 191 | ~1347 | parsed → `flush count=1` |

Exact 300-second spacing. Records 4 and 5 cross-check against live readings (1346 @ 403089 = 189,
1347 @ 403407 = 191), so the decode is corroborated, not inferred.

**Two things this settles.**

1. **The format holds beyond two records, and packets cap at 18 bytes.** Five records arrived as
   `18 + 18 + 9`, never a single larger notification — consistent with the default ATT MTU of 23
   limiting a notification payload to 20 bytes, so two 9-byte records is the maximum that fits.
   Predicted before the test and confirmed.

2. **The 30-day `438/438 backfill_flush count=1` baseline is fully explained.** It never meant
   "backfill only ever contains one reading". It means **only the odd 9-byte remainder is ever
   parsed** and every 18-byte pair is silently discarded. An even-record backfill produces no flush
   at all — which is exactly what the first (16-minute, 4-record) capture showed: two 18-byte
   packets, no `backfill_entry`, no flush. The statistic that looked like evidence *against*
   batching was the fingerprint *of* it.

`bd248c6` would have recovered all five records in this capture.

### ⚠️ Open — the phone received no backfill in this test

The backfill above went to the **watch**, which had its own brief reconnect (`g7_session`
`562CA7EA` → `D34D5A61`). The phone reconnected nine minutes later at `12:31:49Z` and received a
**fresh** reading (seq 1349, `age_s=6`) with **no backfill packets at all**. That differs from the
16-minute test, where the phone reconnected and got a catch-up reading (`age_s=124`) *plus* backfill.

**The "watch drained the buffer" hypothesis is weakened.** The watch was connected and receiving
during the 16-minute test too, and the phone got backfill anyway. A better-supported pattern
emerged once three more phone connections were observed:

| platform | time | `age_s` | backfill |
|---|---|---|---|
| ios | `08:33:46` | **124** | ✅ |
| watch | `12:16:45` | 3 | ❌ |
| watch | `12:22:04` | **21** | ✅ |
| ios | `12:31:49` | 6 | ❌ |
| ios | `12:41:46` | 4 | ❌ |

**Backfill accompanies a *catch-up* delivery, not a live broadcast.** When a client connects late
relative to the 5-minute cycle the sensor hands over its stored reading (high `age_s`) *and* the
backfill; when the client happens to catch the broadcast moment (`age_s` ≈ 3–6) it gets the reading
and nothing else. Five observations, both platforms, no counter-example.

That is consistent rather than proven, but it has a useful consequence: the motivating pool-locker
case should *still* work, because a phone returning from a long absence connects late by
definition — exactly the 16-minute test's `age_s=124` path. The 30-minute test's phone simply
happened to establish its connections on broadcast boundaries.

Ruled out as the cause: the phone authenticated normally on those connections and emitted no
`backfill_notify_failed`, no `background_gatt_skipped` and no `set_notify_backfill` timeout, so the
subscription was armed. (Note the success path only writes an OSLog `.debug` line, so a *successful*
subscribe cannot be positively confirmed from telemetry — only the absence of failure.)

**Unrecovered either way.** The phone's store is still missing 1343–1348 from the test, plus 1350
from a separate connection at `12:36:45` that connected twice and never authenticated. Seven
readings, none recovered — which is the user-facing cost of the guard this task exists to fix.

### Series dependency with [[TRIO-029]] — this fix is sufficient for the phone, not for the watch

The same capture shows the watch received all five records and stored **none**: four dropped by this
task's guard, the fifth parsed and then discarded by
`G7WatchSensorAdapter.handleSensorDidReadBackfill`, which only logs. Confirmed in code and by the
absence of the `w_history_insert` → `saveOnMain` → `Snapshot saved` cascade that the live EGV two
seconds earlier produced.

- **Phone** — `G7CGMManager` stores backfill entries as `NewGlucoseSample`s (gated on
  `hasReliableGlucose`). `bd248c6` alone is sufficient.
- **Watch** — with `bd248c6` applied the adapter would parse all five and still discard all five.
  [[TRIO-029]] is also required.

For the motivating pool-locker case — a hole in the *phone's* store — `bd248c6` is the fix that
matters. TRIO-029 is about the watch keeping its own history complete.

---

## ~~VERDICT 2026-08-15~~ (SUPERSEDED — see FINAL VERDICT above) — both hypotheses as stated are wrong

**Hypothesis (2), the length-guard batching theory, is refuted. Hypothesis (1) is half right for the
wrong reason.** The real answer is two independent blockers, neither of which is "the guard discards
clean multiples of 9".

> ### CORRECTION 2026-08-16 — (2) was refuted in mechanism, not in spirit
>
> The wording above overstates it. What the capture refutes is the *assumed mechanism* — "the sensor
> concatenates several 9-byte records into one notification, so parse `count / 9`". That is wrong:
> the lengths are not multiples of 9 and the captured bytes are not glucose data.
>
> But the **premise that the guard discards multi-record backfill still stands, by a different
> mechanism.** Per xDrip, multi-record backfill arrives as a *sequenced stream* — 2-byte header per
> packet, accumulated into a buffer with a 4-byte length prefix and **8-byte** records. G7SensorKit
> cannot parse that at all; every packet of it fails `count == 9` and is dropped.
>
> Two facts make this the leading explanation:
> - **Passive observation of backfill demonstrably works.** Build 218 parsed 36 real `backfill_entry`
>   records with genuine glucose values (e.g. `glucose=206 algorithm_state=6 trend=2.5`), terminated by
>   42 `backfill_finished` markers — all without ever sending a request. On iOS
>   `G7BackgroundHints.isHostBackgrounded` is set only by the watch extension, never by the phone
>   path, so the phone subscribes to the backfill characteristic on **every** EGV.
> - **We have never once observed a multi-record backfill.** The 30-day baseline in *Evidence gathered
>   2026-08-07* is `438/438 backfill_flush events carry count=1`. Single-record backfills (form 1) are
>   parsed; multi-record ones (form 2) would be dropped whole, which is exactly what a 100%-count=1
>   distribution looks like.
>
> So the 650-packet capture is a **separate phenomenon** (non-backfill traffic on the same
> characteristic) that happened to be what the instrumentation caught first. It does not bear on
> whether form-2 backfill is being dropped — and the count=1 baseline says it almost certainly is.
>
> **Consequence for the plan:** Phase 1 as *written* (`count / 9`) stays retired. Phase 1 *re-scoped*
> to implement form-2 stream parsing is now the leading candidate fix, and it is passive-safe.

### The capture

650 reject events on iOS, build 219, in three bursts (21:27 / 21:31 / 21:36 CEST), `bytes=20`
(`mod9=2`) plus one `bytes=16` tail. Zero `backfill_entry` parsed on 219.

**The sensor retransmits a growing unacknowledged backlog.** 650 packets total but exactly **333
distinct**, and burst 3 was itself 333 packets — set logic therefore proves bursts 1 and 2 are
subsets of burst 3. Each connection replays everything sent before, plus more (110 → 207 → 333). The
backlog grows ~100–126 packets (≈2–2.5 KB) per 5 minutes, which is ~250× the rate of one 9-byte
reading per 5 min.

### The rejected packets are not backfill data at all

Four independent tests, all order-independent:

| Test | Observed | Real backfill |
|---|---|---|
| Shannon entropy | **7.803** bits/byte | 3.777 (fork's own test vectors) |
| Zero bytes | **0.3%** | 25.9% |
| `byte[3]==0 && byte[5]==0` at all 9 alignments | **0 / 110** | 100% by construction |
| xDrip's non-backfill sentinel (`byte[5]`,`[9]`,`[17]` all `0x00`) | **0 / 50 pass** | 100% |

Every byte position is near-uniform random (41–48 distinct values per 50 samples, full `0x00`–`0xFF`
range). `byte[1]` has 45 distinct values where any framing scheme needs it constant.

The last test is the decisive one: **xDrip's `BackFillStream.pushNew()` contains a purpose-built
detector for exactly this situation** — if a >17-byte packet does not have `0x00` at bytes 5, 9 and
17 it logs *"Non backfill data received - locking stream"* and stops. 100% of our capture trips it.
A working third-party implementation classifies our entire capture as not-backfill.

**So Phase 1 as designed is dead.** Splitting this stream into 9-byte records yields garbage, and the
lengths are not multiples of 9 anyway. Phase 0 did its job: it killed the plan before the build cycle
was spent, which is exactly what it was for.

### Independent corroboration: the burst had no `0x59` terminator

A real backfill transfer ends with a `backfillFinished` (`0x59`) control message. That message is
**always 19 bytes**, on both platforms and both builds:

| build | platform | `backfill_finished` count | parsed entries |
|---|---|---|---|
| 218 | ios | 14 | 12 |
| 218 | watchos | 28 | 24 |
| **219** | **ios** | **0** | **0** |
| 219 | watchos | 2 | 0 |

Build 218's counts track its parsed entries closely — data packets, then a terminator, then a flush.
**The 650-packet burst on 219 iOS was accompanied by zero `0x59` messages.** The sensor never
declared a backfill finished, because as far as the backfill protocol is concerned one never started.
This is an entirely separate line of evidence from the entropy and sentinel tests and it agrees with
them.

### Highest-value next instrumentation (passive-safe, no writes)

`case .backfillFinished:` logs only the length and **discards the payload**:

```swift
case .backfillFinished:
    emitG7Telemetry("backfill_finished", "bytes=\(response.count)")   // payload dropped
    flushBackfillBuffer()
```

Those 19 bytes are very likely the metadata that answers the remaining questions. The G6 analogue,
`GlucoseBackfillRxMessage` (`0x51`, 20 bytes), carries `status`, `backfillStatus`, `identifier`,
`startTime`(4), `endTime`(4), **`bufferLength`(4)** and **`bufferCRC`(2)** — and DiaBLE reports G7
dropped the trailing CRC, which would explain 19 vs 20. If G7's `0x59` carries a `bufferLength`, it
states exactly how many bytes the sensor believes it sent, which settles what the 20-byte stream is
without any guessing.

Logging that payload as hex is the same one-line pattern as the reject logging that just proved its
worth here, is read-only, and does not touch the passive contract. `default: break` in the same
switch also silently swallows every other control opcode — worth logging the opcode at minimum.

**Not implemented.** This is a fork change requiring a push, a patch-02 repin and a build; recorded as
a recommendation for the operator, not an agent decision.

### How G7 backfill actually works (read from xDrip source, the working implementation)

`NightscoutFoundation/xDrip`, `g5model/BackFillStream.java` + `cgm/dex/g7/`. Same characteristic we
use: `F8083536` (xDrip calls it `ProbablyBackfill`). It handles **two** delivery forms:

1. **Single 9-byte packet** = one record. `dexTime`(4) `glucose`(2, `&0xfff`) `type`(1) `extra`(1)
   `trend`(1). ← the only form G7SensorKit implements.
2. **Sequenced multi-packet stream** — `packet[0]` is a sequence number (must equal `last+1`,
   starting at 1), `packet[1]` is skipped, bytes `2..n` are appended to a 2800-byte buffer. The
   assembled buffer starts with a 4-byte length, then **8-byte records**: `dexTime`(4)
   `glucose`(2) `type`(1) `trend`(1) — note **no `extra` byte**, so stream records are 8 bytes, not 9.

xDrip also defines a characteristic we do not: `ExtraData = F8083538`.

### Why G7SensorKit cannot do backfill — two independent blockers

1. **It cannot parse form (2).** `guard response.count == 9 else { return }` handles only form (1).
   There is no sequence assembly, no 4-byte length header, no 8-byte record decode, and no sentinel
   check. Anything that is not exactly 9 bytes is discarded.
2. **It never asks.** The only write in the entire kit is `extendedVersionTx` (`0x52`,
   `G7PeripheralManager.swift:117`). `G7Opcode` declares `backfillFinished = 0x59` as receive-only and
   there is no request message type at all (`Messages/` holds only AuthChallengeRx, ExtendedVersion,
   G7Glucose, G7Opcode, SensorMessage). The fork's passive contract (C-217, *"subscribe only, no
   writes"*) then forbids adding one as a matter of policy.

For contrast, G6 `CGMBLEKit` — which does support backfill — writes `GlucoseBackfillTxMessage`
(`0x50`) with start/end times, assembles indexed frames via `GlucoseBackfillFrameBuffer`, and
validates the result against a length **and CRC** returned in `GlucoseBackfillRxMessage` (`0x51`).
G7SensorKit has no equivalent of any of those three pieces.

### This reopens a rejected idea

`egv-intervention-index.md` lists `C-04-C1b/c` (**actively request** backfill by writing `0x59`) as
💡 *"never shipped — `0x59` format was unknown then"*, and the graveyard rejects Idea #8 partly on
*"no range-request exists"*.

**That premise now looks wrong.** Per [DiaBLE discussion #17](https://github.com/gui-dos/DiaBLE/discussions/17),
G7 backfill is requested with opcode `0x59` followed by **eight bytes: the start and end timestamps**,
and in G7 the same opcode serves as both request and reply marker with no trailing CRC. If that holds,
the format is no longer unknown and only the passive-contract *policy* blocks it — a decision, not a
protocol limit.

⚠️ **Secondary source, not verified by me.** Everything above it in this section was read directly
from xDrip/CGMBLEKit source; this paragraph is a reverse-engineering discussion thread. It must be
confirmed against a real implementation before anything is built on it. Note also that the same
thread claims *"Dexcom is not encrypting … the backfill stream"*, which does not sit comfortably with
our 7.8-bits/byte capture — either the capture is a different stream (most likely, given xDrip's
sentinel exists precisely because non-backfill traffic appears on this characteristic), or that claim
does not hold for this firmware. **Do not treat the encryption question as settled.**

### What is still unknown

- **What the 20-byte stream actually is.** It is not backfill. Candidates: one of the encrypted
  internal streams (calibration/factory/debug) DiaBLE mentions, or traffic on `F8083536` intended for
  the authenticated peer. Unresolved.
- **Why it stopped after 21:36** and has not recurred.
- **Why build 218 parsed clean 9-byte records** at 13:31 (ios, 12) and 16:17 (watchos, 24) — small,
  well-formed, ~1 per flush, completely unlike these bursts. Two different things arrive on this
  characteristic and the switch between them is not understood.
- Whether the 218 era also had 20-byte rejects. **Unknowable retroactively** — no instrumentation.

### Ruled out

The 218→219 G7SensorKit diff is **12 added lines entirely inside the existing `guard` failure
branch**; the `guard` and its `return` predate it. Build 219 changed no behaviour, so these packets
were being discarded silently before and nothing regressed. This was verified by direct diff of
`7369b20..509994f`, not inferred.

## ✅ FINAL IMPLEMENTATION 2026-08-16 — batched 9-byte records (committed, NOT pushed)

`bd248c6` in the `G7SensorKit` fork on `main`, agent-signed, one file, **+23 / −219** against the
shipped build-219 baseline `509994f`. It supersedes the entire stream-parser effort recorded in the
superseded section below; those commits (`5d3e411..3debcfa`) remain in history.

### What it does

The guard accepts any length that is at least 9 **and a whole multiple of 9**, then walks the
response in 9-byte steps, carving each record with `subdata(in:)` — which re-bases to index 0,
required because `G7BackfillMessage.init` reads absolute offsets `0...8` and a range subscript
would keep the parent's indices and misread. A batch emits one `backfill_batch` event first.

A single 9-byte notification behaves **exactly** as before: one record, no extra telemetry.

Lengths that are **not** a whole multiple of 9 keep the existing `backfill_len_rejected` telemetry
untouched. That path identified this format and remains the catch-all for unknown shapes —
notably the 20-byte high-entropy traffic on the same characteristic, which is not backfill and is
still correctly refused.

### Verification — replayed against the real captured bytes

The two notifications the sensor actually sent were run through this exact logic:

```
backfill_batch bytes=18 records=2
  record startIndex=0 ts=388686 glucose=103 state=6 displayOnly=false trend=-1.0
  record startIndex=0 ts=388986 glucose=100 state=6 displayOnly=false trend=-0.9
backfill_batch bytes=18 records=2
  record startIndex=0 ts=389286 glucose=98  state=6 displayOnly=false trend=-0.7
  record startIndex=0 ts=389586 glucose=96  state=6 displayOnly=false trend=-0.6

parsed:   [103, 100, 98, 96]      expected: [103, 100, 98, 96]   ✅
```

`startIndex=0` on every record confirms the re-basing. This is a regression test against bytes the
sensor genuinely sent — stronger evidence than anything the 219 deleted lines carried.
`swiftc -parse` clean (syntax only; full type resolution is not proven until a build).

### What was deleted, and why that matters

Six stream state fields, two caps, the first-packet sentinel, sequence tracking, the drain method,
the declared-length logic and the `scanForNewSensor` reset — all removed. **All twenty defects
found by six reviewers are gone because the code containing them no longer exists.** Two flagged
operator decisions dissolved with it: the display-only limitation (byte 7 is `0x0F`, the flag is
carried) and the unverified declared-length interpretation (there is no length header).

### Process lesson

The plan states: *"Do not implement Phase 1 or 2 speculatively — building against the wrong one
wastes a build cycle."* A parser was nonetheless built against a format never once observed, whose
semantics were inferred from a reference implementation for a different sensor generation. Six
reviewers, twenty defects and four fix-induced regressions followed. A 16-minute radio-off test
produced the answer in minutes.

The reviews were not wasted — every finding was real for the code as written — but they were
reviewing code that should not have existed. **Diverse review cannot rescue a wrong premise; only
data can.** Where a measurement is cheap and the format is unknown, take the measurement first.

## ~~Implementation 2026-08-16 — form-2 stream parsing~~ (SUPERSEDED by `bd248c6`)

Three commits in the `G7SensorKit` fork on `main`, all agent-signed, one file,
**+146 / −17** vs the shipped build-219 baseline `509994f`:

| Commit | What |
|---|---|
| `5d3e411` | form-2 sequenced-stream parsing; `0x59` payload hex; unknown control opcodes logged |
| `c559257` | declared-length bounding; discard incomplete/corrupt streams; dirty-state fix |
| `24b330f` | abort telemetry made self-diagnosing for the declared-length interpretation |
| `517e34a` | bound the stream accumulator at 2800 bytes (codex finding) |
| `d06ccda` | restore the batched-9-byte diagnostic; stale comment (cursor finding) |

**Nothing is pushed.** `origin/main` is still `509994f`. Patch 02 is not re-pinned and no
build has been run — those need operator authorization.

### What it does

`didReceiveBackfillResponse` now handles both delivery forms. The 9-byte single-record path
is byte-for-byte unchanged. Anything else enters a stream path: sequence byte must be
`last + 1`, byte 1 discarded, bytes 2+ accumulated. On `0x59` **or disconnect**,
`flushBackfillBuffer` drains: 4-byte LE declared length, then 8-byte records expanded to the
9-byte form `G7BackfillMessage` requires by inserting a zero display-only byte.

xDrip's sentinel (bytes 5, 9, 17 zero in a stream's first packet) separates unrelated traffic
from backfill and fires **once per stream** — the 650-packet burst would now be one event plus
a suppressed count.

New telemetry: `backfill_stream_drain`, `_drain_aborted`, `_locked_out`, `_seq_mismatch`,
`_reset`, `unknown_control_opcode`. `backfill_finished` now carries the `0x59` payload hex.
**`backfill_len_rejected` is retired** — queries and the 650-packet baseline reference it.

### Verification

- 8→9 reconstruction **proved against the fork's own `testBackfill` vector**: the 8-byte form of
  `cf5802008f00060f10` reconstructs to `cf5802008f00060010` and decodes to timestamp 153807 /
  glucose 143 / state 6, matching the test's assertions. Run through the Swift interpreter, and
  `startIndex=0` confirms `subdata(in:)` re-bases correctly (`G7BackfillMessage.init` reads
  absolute offsets `data[0..<3]`…`data[8]`, so a parent-indexed slice would misread or trap).
- `swiftc -parse` clean at every step. Note this is **syntax only, not type-checking** — full
  type resolution is not verified until a build.
- Zero writes added (grep-verified) — the passive contract holds.
- Every deletion in every diff reviewed and accounted for.

### Seven defects found and fixed during implementation

Defects 1–4 share one signature: **fail-closed, silent, and indistinguishable in telemetry from
"no backfill happened"**. None would surface in a build or in `patch-test.sh`. Defect 6 is the
opposite shape — a resource-exhaustion crash rather than silent loss — and defect 7 is a
regression in *observability* rather than behaviour. That spread is why no single reviewer found
them all.

1. *(self)* Lock-out never cleared — `resetBackfillStream()` sat behind drain's empty-payload
   early return, which is exactly the state a locked-out stream is in. Lock-out would persist
   for the life of the `G7Sensor` object, suppressing every later genuine backfill.
2. *(claude review)* `declaredLen` decoded and logged but never bounding the record loop, which
   ran to `payload.count`. `G7BackfillMessage` validates nothing but length, so trailing bytes
   became readings. All-zero padding is caught downstream (`State` has no `rawValue 0` →
   `.unknown(0)` → fails `hasReliableGlucose`), but bytes landing on state `6` would inject a
   plausible fabricated glucose value.
3. *(claude review)* A sequence mismatch never advanced `backfillStreamLastSequence`, freezing
   `expectedSeq` so every later packet was rejected — then the truncated prefix was drained and
   handed on as if complete.
4. *(self)* The new sequence-break flag was missing from the dirty-state check. Subscribing
   part-way through a transfer already in flight (the normal passive-observer case) sets it with
   an empty payload and pristine siblings, so reset never ran and every subsequent well-formed
   stream aborted. Same root cause as #1.
5. *(self, unverified-assumption class)* The declared-length interpretation was load-bearing but
   unconfirmed — see below.
6. *(codex review)* The stream accumulator was **unbounded**, so a peripheral that never
   terminated a stream could exhaust host memory; the 1-byte sequence counter could also wrap
   past 255 packets. The reference implementation bounds its buffer at 2800 bytes and logs on
   reaching it — I read that code and ported the accumulation without the bound. Fixed in
   `517e34a` at the same 2800, which also makes the wrap unreachable.
7. *(cursor review)* Concatenated 9-byte records (18, 27, 36 bytes) were misrouted into the
   sequenced-stream path, where they trip the sentinel and are dropped — and retiring
   `backfill_len_rejected` removed the `mod9`+hex diagnostic for exactly that shape. This made
   **the task's own core hypothesis harder to measure than before the work began**. Fixed in
   `d06ccda`: intercepted, reported, dropped without touching stream state, not parsed.

### ⚠️ Load-bearing unverified assumption

The 4-byte header is read as the **record-region byte count**, and that reading now decides
parse-vs-discard. It has never been confirmed against real data: **xDrip reads the same field
into an unused local and carries a literal `// TODO check length`**, looping to the full extent
instead. Two rival readings are equally plausible — the field may include its own 4-byte header
(`4 + 8N`, so `% 8 == 4` for every well-formed stream), or count records rather than bytes.

Under either rival reading the new guards discard **all** backfill. That is the safe direction
for a glucose app, and it loses nothing we have today, but it means **shipping this may buy one
more diagnostic cycle rather than the fix**. `backfill_stream_drain_aborted` therefore reports
`declared_eq_trailing`, `declared_eq_trailing_plus_4` and `declared_times_8_eq_trailing`, so the
first real stream settles it outright.

### ⚠️ Known limitation — display-only is unrecoverable in stream form

Stream records carry no display-only byte, so stream-sourced entries report
`isDisplayOnly` / `wasUserEntered` as `false`. The **admission gate is unaffected** —
`G7CGMManager:464` filters on `hasReliableGlucose`, derived from the algorithm state, which is
preserved exactly. But the fork's own `testBackfillCalibration` vector shows a display-only
record can carry state `6`, so such a record would pass the gate and land as an ordinary
reading. xDrip has the identical limitation in stream mode. **Operator decision.**

### Review record

Two `--backend claude` reviews (task-relay cannot record these formally: `tasks review` scopes
task lookup and commit resolution to the same `--repo`, and this task lives in `Trio-dev` while
the commits live in the fork — recorded in prose rather than fabricating a `Trio-dev` commit).

- Review 1 (`claude`) against `5d3e411` — **effectively a fail**: found defects 2 and 3.
- Review 2 (`claude`) against `c559257` — fixes present and internally consistent; arithmetic
  guards safe (no negative surplus, `endOffset ≤ payload.count`, no overflow); raised the
  unverified declared-length semantics, which produced `24b330f`.
- Review 3 (`codex`, run `37524bab`, verdict **PASSED**) against `509994f..24b330f` — found two
  issues **both claude reviews missed**:
  - **P1, valid and fixed in `517e34a`.** The stream accumulator was unbounded; only a finish
    message or disconnect ends a stream, so a peripheral that never terminates could exhaust
    memory. Also flagged that the expected-sequence calculation uses wrapping addition on a
    single byte, so past 255 packets the counter wraps and accepts from zero again. **This was my
    miss, not a subtle one** — the reference implementation bounds its equivalent buffer at 2800
    bytes and logs on reaching it; I read that code and ported the accumulation without the
    bound. Capping at the same 2800 also makes the wrap unreachable (~155 packets).
  - **P2, correct arithmetic, deliberately not changed.** `response.prefix(192)` caps 192
    *bytes*, which hex-encodes to 384 *characters*. This is the identical `hexCap = 192` from
    `509994f` already shipped in build 219, and [[TRIO-030]] records the accepted design as
    "payload (uppercase hex, capped at 192 bytes)" — the operator weighed sensor payload hex
    reaching BetterStack when approving it. Reducing it now would silently override that
    decision, so the behaviour stands; only the imprecise "192 characters" wording in this
    session's commit/prompt text was wrong.

- Review 4 (`cursor`, run `020be1f9`, model `auto`, verdict **PASSED**, no High findings) against
  `509994f..24b330f` — confirmed the earlier defects genuinely fixed and the 2800-byte cap matches
  the reference bound. Found one thing **the other three missed**:
  - **M2, valid and fixed in `d06ccda`.** A notification of several whole 9-byte records
    concatenated (18, 27, 36 …) — *the original TRIO-028 hypothesis* — was falling into the
    sequenced-stream path, where its byte 0 is glucose data rather than a sequence number and
    bytes 5/9/17 are record data, so it trips the sentinel, locks the stream out and is dropped.
    And retiring `backfill_len_rejected` removed the `mod9`+hex diagnostic that described exactly
    this shape. **The change had made the batching hypothesis harder to observe than before the
    work started.** Multiples of 9 are now intercepted ahead of the stream path and reported, then
    dropped without touching stream state. Deliberately **not parsed** — batching is the open
    question and parsing an unconfirmed layout is how fabricated readings get in.
  - Assessed and not acted on: **M3** (failed record parses skipped without abort) is
    **unreachable** — the reconstructed buffer is always exactly 9 bytes and the initializer's only
    guard is `count == 9`, so the `nil` branch cannot be taken; cursor did not trace that. **M1**
    duplicates codex's declared-length finding. **L5** (short first packet skips the sentinel)
    matches the reference implementation. **L6** (4-byte stream timestamp vs 3-byte parser) was
    already verified benign — byte 3 lands in the ignored padding slot. **L7** (disconnect flush
    gated on `sensorID` match) is the residual edge case already noted. **L8** stale comment fixed.

**Four model families produced four disjoint finding sets.** Ollama's in-loop review timed out
entirely and found nothing; claude found the parsing-correctness defects; codex found the
resource-exhaustion one; cursor found the batched-record misrouting and the lost measurement. No
single reviewer caught all of them — the strongest argument yet for keeping diverse review on this
component rather than treating one pass as sufficient.

**And the one claim two reviewers made confidently was the false one.** Both claude reviews
asserted no reset path exists on disconnect; cursor correctly observed that
`peripheralDidDisconnect` does call `flushBackfillBuffer()`. Agreement between reviewers is not
evidence — each finding still has to be checked against the source.

Note: the claude implement run `487db1a9` is marked `SUSPECT (out-of-scope changes)`. Verified
false positive — all four commits touch only `G7Sensor.swift`; the guard was flagging the run's
own untracked `.task-relay/notes` writes in the worktree.

**Both claude reviews independently asserted "no reset path exists on disconnect".** Both are
wrong — `peripheralDidDisconnect` calls `flushBackfillBuffer()`, and the G7 drops the link after
every EGV, so state clears within ~5 min. Recorded because it is direct evidence for not
accepting review findings unverified.

Ollama's own quality loop **timed out on its review step** (`STALLED`), so the main
implementation run shipped unreviewed by its own gate. Without the cross-family reviews,
defects 2 and 3 would have gone in. Recommend a different-family review as standard for
`G7SensorKit` changes.

### What shipping would prove

If the reframed hypothesis holds, `backfill_flush` should start showing `count>1` after a real
gap, against a 30-day baseline of 438/438 `count=1`. If it stays 100% `count=1` across several
gaps — or `_drain_aborted` fires with one of the three interpretation booleans set — the next
step is determined without guessing.

## Notes carried over from acceptance criteria

      **Update 2026-08-17 — the parser is confirmed firing in production, on the watch.** Build 221,
      2026-08-17 05:50:48Z: `backfill_batch bytes=18 records=2` ×4 → `backfill_flush count=8`, the
      predicted signature exactly, and the first `count>1` flush against the 438/438 `count=1`
      baseline. Those eight records then reached the watch's store
      (`build205_w_history_insert source=backfill batch=8 appended=3 deduped=5`), which closes
      [[TRIO-029]]'s last criterion.
      That does **not** close this one. This criterion is about the **phone's** Core Data, and the
      phone received no parseable backfill in the 11 h 221 window: zero `backfill_batch` and zero
      `backfill_entry` on iOS, only `backfill_len_rejected` / `_suppressed` for the unrelated
      `bytes=20 mod9=2` shape (follow-on criterion below). The parser being right is now established
      independently of the platform; what remains is a real phone-side gap-then-reconnect.
### Follow-on criteria (new, from the verdict) — split out to [[TRIO-036]] on 2026-08-17
These six are research, an unshipped parser form, and one decision that is not an agent's to make.
They were holding a finished investigation open, so they now live in their own task with their full
annotations carried over.
