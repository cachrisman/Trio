+++
uid = "01a00e96-5f02-7308-89d3-f0ebcc4500eb"
key = "TRIO-036"
title = "G7 backfill follow-ons: identify the 20-byte stream, form-2 parsing, and the active-request decision"
status = "ready"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-028#follow-on-criteria"
created = 2026-08-17
updated = 2026-10-16
touched = 2026-10-16
owner = "me"
tags = ["g7", "ble", "cgm"]

[[acceptance]]
id = "AC-1"
text = "Identify what the 20-byte high-entropy stream on `F8083536` is, or positively exclude it from the backfill path"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Port xDrip's sentinel (`byte[5]`/`[9]`/`[17] == 0x00`) so non-backfill traffic is classified rather than counted as a backfill failure — cheap, passive-safe, no writes. **Precondition from [[TRIO-033]]: only against real validation data.** That sentinel is xDrip's check for the **G5/G6** format and there is no known-good sample of this 20-byte stream to validate it against, so using it to assert a classification would repeat TRIO-028's own earlier error (a ~205-line parser built on a single capture, retired after a 16-minute radio-off test disproved it). TRIO-033 removed the log-volume pressure to do this by sampling on packet *shape* instead, which asserts nothing — so this should stay blocked on validation data rather than be taken up for its own sake."
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Implement form (2) parsing (sequence assembly + 4-byte length + **8-byte** records) so a pushed multi-record backfill would be captured if one ever arrives — passive-safe, no writes"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Verify the DiaBLE `0x59` + 8-byte start/end-timestamp request format against a real implementation before considering an active request"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Operator decision required: whether to relax the passive contract for an active `0x59` request. **Not an agent decision** — it changes the fork from observer to participant"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Update `egv-intervention-index.md` (`docs/in-progress/watch-g7-direct-ble-observer/`): `C-04-C1b/c` rationale (\"`0x59` format was unknown\") and the Idea #8 graveyard entry (\"no range-request exists\") are both contradicted by TRIO-028's verdict, pending the DiaBLE verification criterion above"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Split out of [[TRIO-028]] on 2026-08-17. That task answered its own question — hypothesis (2) is
confirmed, the sensor batches whole 9-byte records and the `== 9` guard was discarding them — and its
parser fix is shipped and confirmed firing in production. What remained under its "Follow-on
criteria" heading is genuinely new scope: research, an unshipped parser form, and one decision that
is not an agent's to make. Keeping them there left a finished investigation unable to close.

TRIO-028 retains one original criterion of its own (recovered readings reaching the **phone's** Core
Data store), which is not part of this task.



## Context worth carrying over

The 20-byte stream is well characterised even though unidentified, from [[TRIO-033]]'s measurements:

- 20 bytes, `mod9=2` — cannot be a whole number of 9-byte `G7BackfillMessage` records
- Shannon entropy ≈ 7.803 vs ≈ 3.777 for confirmed backfill payloads — effectively random
- Fails xDrip's backfill sentinel (`byte[5]`/`[9]`/`[17] == 0x00`)
- Stable burst cadence, ~600 per burst, ~2 h apart, ~1,400 per 11 h on build 221

It is still emitting on build 221 and still sampled (first 3 per shape in full, then a running total
every 200), so the diagnostic sample keeps accumulating without a new run being needed.

**Evidence update 2026-10-16 (side session 2332fe6b; BetterStack source 1659391, Oct 8–16).**

- *AC-1, the 20-byte stream.* Still about 600 packets per burst, every 2h (drifting about +5 min per burst), on both DXCMVL and DXCMKV. The `_suppressed` counter carried across the Oct 13 sensor change and reset only at two app relaunches (Oct 9 08:39, Oct 11 11:39). Every packet was logged by the phone and none by the watch. All 70 bursts I checked arrived 0–10s after an EGV the phone had received and uploaded, so a burst never costs that cycle's reading. My best guess is an encrypted or compressed bulk dump that the Dexcom app pulls on its own connection (Trio's phone connection follows it), probably for Dexcom's cloud. That is unconfirmed, and it bears out the "positively exclude" branch of AC-1 in practice.
- *AC-4, the `0x59` format.* The 19-byte `backfillFinished` payload decodes as `59 | status | 00 | length u32 LE | 4 opaque bytes (CRC?) | first timestamp u32 | last timestamp u32`. The first and last timestamps match the logged `backfill_entry` records exactly, and length/9 matches the record count. 59 of 67 matched; the other 8 (7 on the watch, 1 on the phone) arrived with zero records. The start/end pair matches the DiaBLE request shape described in AC-4.
- *AC-5, the decision input.* Passive backfill on the phone recovered 7 readings out of about 375 missed in 8 days; all 63 phone backfill records reached Nightscout with the correct glucose value. Over 12 weeks the Dexcom app had 96% of Trio-missed slots live (Share upload within 7 min), so its requests cover only its own gaps, not Trio's. An active `0x59` request is the only Bluetooth route to the rest. With TRIO-074's Nightscout pull plus the Share-echo fix, most of that value is already reachable without one.
