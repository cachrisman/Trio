+++
uid = "019fdc98-fbd2-7086-be8f-bedc1ca43e8d"
key = "TRIO-029"
title = "Watch discards received G7 backfill entries (handleSensorDidReadBackfill logs only)"
status = "done"
kind = "code"
source = "human"
created = 2026-08-07
updated = 2026-09-12
touched = 2026-09-12
closed = 2026-09-12
first_closed = 2026-09-12
accepted_by = "Charlie"
accepted_at = 2026-09-12
owner = "me"
tags = ["g7", "watch", "ble"]

[[sessions]]
host = "claude-code"
ref = "20260816-154005-73802-ollama-implement.md"
model_family = "ollama"
started = 2026-08-16
role = "author"
started_at = "2026-08-16T13:43:13+00:00"

[[reviews]]
run_id = "fc3f3f1b-bb56-4387-ae56-2c8109b1eb7b"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "3dfb75e92caf91f3502dc9fec060491b89238d03"
recorded_at = "2026-08-16T13:53:46+00:00"
+++

## Intent

On the watch, backfill entries that arrive over BLE are received, telemetered, and then thrown away.
`G7WatchSensorAdapter.handleSensorDidReadBackfill` (`Trio Watch App Extension/G7WatchSensorAdapter.swift:1609-1615`)
only logs:

```swift
private func handleSensorDidReadBackfill(backfill: [G7BackfillMessage]) {
    for msg in backfill {
        log("backfill_entry", "timestamp=\(msg.timestamp) glucose=…")
    }
}
```

Compare the EGV path immediately above it, which runs the full cascade — `TrioComplicationDataStore.save`,
`WatchState.applyG7DirectBleSnapshot`, `WatchGlucoseHistoryStore.insert` (same file, ~:1578).

This makes C-217 Task 3 incomplete against its own stated purpose. That change arms a gap-triggered
background backfill subscribe specifically *"so the sensor's push-based backfill can recover the
missed reading(s)"* (`G7Sensor.swift:246-249`) — and then the watch drops the recovered reading.

## Value and limits

> ### ⚠️ CORRECTION 2026-08-16 — the premise below was wrong, in this task's favour
>
> The original text read: *"every observed flush is `count=1` (438/438 over 30 days), so this
> recovers at most one reading per connection."* **That statistic measured the guard's output, not
> the sensor's.** [[TRIO-028]] resolved on 2026-08-16: the sensor batches whole 9-byte records into
> one notification, and everything that is not exactly 9 bytes is discarded. `count=1` was the
> fingerprint of *only the odd remainder ever being parsed*.
>
> The conditional in the last paragraph has therefore fired: **this is now load-bearing, not
> marginal.**

Small but real. It is worth doing because the feature is already built, shipped, and silently not
doing its job.

### Live evidence 2026-08-16 (30-minute gap test) — the watch recovered zero

The watch received a real backfill at `12:22:04Z` and stored nothing:

```
backfill_len_rejected bytes=18 mod9=0   ← 2 records dropped by the TRIO-028 guard
backfill_len_rejected bytes=18 mod9=0   ← 2 records dropped
backfill_entry ts=403386 glucose=191    ← 1 record parsed
backfill_finished bytes=19
backfill_flush count=1
```

| stage | outcome |
|---|---|
| sensor sent | **5 records** |
| dropped by the 9-byte guard ([[TRIO-028]]) | 4 |
| parsed | 1 |
| **discarded here** | **1** |
| **net recovered** | **0** |

The four dropped records decode cleanly to 172 / 177 / 183 / 189 at exact 300 s spacing, matching
the missing sequences. This is the *"verified against a real gap-then-reconnect"* evidence the last
acceptance criterion asks for — obtained before the fix rather than after.

Confirmation that nothing is stored, from the same capture: the live EGV two seconds earlier
produced `w_history_insert appended=1` → `saveOnMain` → `Snapshot saved` → complication reload. The
`backfill_entry` produced **none of those**.

### Series dependency — this and TRIO-028 are both required on the watch

The two defects sit in series on the watch and only one of them is in the phone's path:

- **Phone** — `G7CGMManager` converts backfill entries into `NewGlucoseSample`s and stores them
  (gated on `hasReliableGlucose`). The [[TRIO-028]] parser fix alone recovers readings there.
- **Watch** — with TRIO-028 fixed the adapter would parse all 5 and still throw all 5 away. **Both
  are needed** for the watch to recover anything.

So they are independent wins, not a chain: TRIO-028 fixes the phone, this fixes the watch.

## Acceptance criteria

- [x] Backfill entries stored via the same path as EGVs (`WatchGlucoseHistoryStore.insert`) — done in
      `63810b6ab`
- [x] Dedup against readings already held for the same sensor timestamp — done. Records carry
      `sequence: nil` so `sequencesMatch` treats them as matching the live EGV at the same ±1 s
      timestamp; a literal `0` would have compared unequal and stored a duplicate.
- [x] Complication/`WatchState` refresh behaviour decided deliberately — **history only.** The
      handler does not touch the complication store, the `WatchState` snapshot, or
      `bleLastEGVDate/Value`, so a backfilled historical reading can never present as the current
      value. Only the chart array is refreshed (`090cdcb64`).
- [x] Verified against a real gap-then-reconnect, not only a synthetic injection — **confirmed on
      build 221**, 2026-08-17 05:50:48Z. Shipped in build 220 (patch 09); the verifying gap landed
      on 221. Full chain in one second:

      ```
      background_backfill_gap
      backfill_batch bytes=18 records=2      ×4     ← TRIO-028 parser, 8 records from 4 packets
      backfill_flush count=8
      backfill_persist_summary arrived=8 candidate=8 skipped=0
      build205_w_history_insert source=backfill batch=8 appended=3 deduped=5 total=239
      ```

      `candidate=8` is the non-zero count this criterion asked to watch for. Three records were
      genuinely new and five deduped against readings already held — which also exercises the dedup
      criterion above in production, not just by construction. The `source=backfill` insert is a
      separate event from the `source=ble` insert logged in the same second, confirming the entries
      travel the same store path as EGVs while remaining distinguishable.

      `backfill_flush count=8` is also the first `count>1` flush ever recorded, against the 30-day
      438/438 `count=1` baseline cited in [[TRIO-028]] — the "what shipping would prove" prediction,
      confirmed.

### Insertion conventions checked against the phone (2026-08-16)

Compared against how Nightscout-sourced backfill is inserted
(`NightscoutConfigStateModel.backfillGlucose()` → `GlucoseStorage.storeGlucose()`). Dedup window
matches exactly (±1 s both sides), no deleted-reading filter on either, post-insert refresh
analogous. The one divergence was a `max(40, min(400,·))` clamp that mirrored `G7CGMManager`'s
`GlucoseLimits` — a bound on an `HKQuantity` built for display, not a storage bound. Trio's storage
layer has no ceiling and floors at 39 only because oref's `glucose-get-last` drops `<= 38`, which
the watch never feeds. Removed in `3dfb75e92`: the store's `canary()` logs implausible values
without rewriting them, and the live EGV path stores raw. Before the fix a genuine 401 landed as
400 via backfill but 401 when live. Cursor review: PASSED.

