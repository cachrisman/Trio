# G7 Backfill Length Guard — Implementation Plan

**Version:** v0.3 (2026-08-15 — measurement returned; Phase 1 retired)

> **Changelog**
> - **v0.3 (2026-08-15)** — **Phase 0 measurement returned and refutes this plan's premise. Phase 1 is retired — do not build it.** 650 rejected packets captured on build 219: `bytes=20` (`mod9=2`), uniform entropy 7.803 bits/byte, and 0/50 pass xDrip's non-backfill sentinel (`byte[5]`/`[9]`/`[17]` must be `0x00`). They are not batched 9-byte records; they are not glucose data in any alignment. A chunk-tolerant `count / 9` parser would recover nothing. Full verdict, evidence tables and the corrected description of how G7 backfill actually works (two delivery forms; stream records are **8** bytes, not 9) are in `TRIO-028`. Also recorded there: the "Why this is not in the graveyard" section below rests on *"no range-request exists"*, which secondary evidence now contradicts (`0x59` + 8-byte start/end timestamps) — flagged as unverified, pending confirmation.
> - **v0.2 (2026-08-15)** — Phase 0 now logs the rejected packet's payload as hex, not just its length. Rationale in Phase 0 below. This retires the "capture hex via Console" fallback in *Reading the result*, which required a second confirmed gap event with the phone tethered. Implemented in the `G7SensorKit` fork; tracked as `TRIO-030`.
> - **v0.1 (2026-08-07)** — initial draft.

> ⚠️ **STATUS: superseded in part.** Phase 0 shipped and answered the question; the answer was "neither
> hypothesis". Everything in this document downstream of Phase 0 was written against a premise that
> the measurement has now falsified. Read `TRIO-028`'s VERDICT section before acting on any of it.
> The "Why this is not in the graveyard" section immediately below is specifically affected.
**Task:** `TRIO-028`
**Related:** `TRIO-029` (watch discards received backfill), `TRIO-024` (watch→phone EGV backfill)
**Repos touched:** `G7SensorKit` (fork, `main`) primary; `Trio` (`feature/watch-g7`) only in branch B.

> **Measurement-first.** Phase 0 is a two-line instrumentation change and a wait. Every code path
> after it is conditional on what that measurement says. Do not implement Phase 1 or 2 speculatively —
> the entire point of this plan is that the existing telemetry cannot distinguish the two hypotheses,
> and building against the wrong one wastes a build cycle.

---

## Why this is not in the graveyard

`egv-intervention-index.md` already rejects **Idea #8, "Active `0x59` backfill request"** — backfill is
push-based, no range-request exists, and the passive-observer contract forbids writing to control.
That rejection stands and this plan does not touch it. **No writes to the sensor are proposed here.**

What is new is orthogonal to that: the index records `B192 backfill` as ✅ *(parsing)* — "lazy
backfill-notify + 9-byte parse + buffer + flush on `0x59`/disconnect". Nobody has asked what happens
to a backfill notification that is **not** 9 bytes. The answer is that it is discarded with no
telemetry:

```swift
// G7Sensor.swift:466-477
func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {
    log.debug("Received backfill response: %{public}@", response.hexadecimalString)
    guard response.count == 9 else { return }          // ← silent, uncounted
    if let msg = G7BackfillMessage(data: response) { backfillBuffer.append(msg) }
}
```

So `B192 = ✅` is only established for the single-record push. It is unestablished — not disproven —
for a batched push.

## Evidence base

- BetterStack `1659391` / `t491594.trio`, 30 days: **438/438 `backfill_flush` carry `count=1`**
  (ios 409, watchos 29). Post-filter metric; cannot show drops. This is the whole problem.
- `G7BackfillMessage` is a fixed 9-byte record (`G7BackfillMessage.swift:29-34`), and its own init
  re-guards `data.count == 9`. The `[G7BackfillMessage]` array accumulating across notifications is
  correct design; the suspect is admission, not the container.
- The guard is upstream (Pete Schwamb, `b1b5b34`, 2022-11-11). **This is not reassurance:** upstream
  never requests backfill either, so no consumer of this library has ever received a bulk response.
  Well-tested against the routine push; untested against a batch.
- No other length filter — `G7BluetoothManager.swift:1098-1109` passes `characteristic.value` through
  untouched.
- BLE plausibility: notification payload ≤ MTU−3. Default MTU 23 → 20 bytes → 2 records; negotiated
  MTU → dozens. Batching is the natural firmware choice for a bulk response.

## The two hypotheses

| | Claim | If true |
|---|---|---|
| **H1** | Per-connection routing — the sensor notifies only the connection that requested backfill (the Dexcom app's). Nothing reaches Trio. | Passive observation is dead. Nightscout auto-backfill is the only channel. |
| **H2** | Batched packets — the sensor notifies all subscribers but packs N records per notification. Trio drops them on length. | Parser fix on a path we own. Instant, offline, authoritative, no Nightscout round-trip, no re-upload cascade. |

H2 is strictly better if true, which is why it gates the design.

---

## Phase 0 — Instrument the reject path (GATING)

**Repo:** `G7SensorKit` fork, `main`. **Size:** ~12 lines, telemetry only.

Emit on the drop, mirroring `auth_payload_ignored` which already exists ~15 lines below in the same
file (`G7Sensor.swift:494`) — same pattern, same helper, no new machinery:

- Event name: `backfill_len_rejected`
- Fields: `bytes=<N>`, `mod9=<N % 9>` so a batched-but-clean length is distinguishable from a
  genuinely unexpected format at a glance, `truncated=<bool>`, and `payload=<uppercase hex>`.
- Payload hex is capped at the first **192 bytes** (`truncated` records when it was longer), so a
  malformed or huge notification cannot emit an unbounded log line. The cap is deliberately much
  larger than `auth_payload_ignored`'s 8-byte cap: there the interesting case is a short payload,
  here it is precisely the long one.
- Keep the existing `log.debug` hex line.

**Why log the payload and not just the length (v0.2).** With length alone, each outcome is worse
than it looks. `mod9 == 0` says only that the length divides by 9 — it does not establish that the
records *are* `G7BackfillMessage`s, so Phase 1 would be written against an inferred format. And
`mod9 != 0` sent us back for a **second** confirmed gap event with Console attached and the phone
tethered, which is the hardest part of this whole measurement to arrange. The `log.debug` hex line
above the guard does not rescue either case: OSLog `.debug` is not persisted, so it cannot be read
retroactively. Logging the payload collapses both outcomes into a single capture and makes Phase 1
verifiable before a line of parser is written.

Cost accepted: this ships sensor payload hex to BetterStack. Not a new exposure — `backfill_entry`
already sends `glucose=` values to the same sink — but it is a slightly different shape of data, and
the reject-path event rate is by definition unmeasured. The 192-byte cap bounds each event; it does
not bound the event count. If the reject path turns out to be chatty, add rate limiting here.

Ship it in the next build. No behaviour change — this phase only adds observability.

### Exit criterion

A **confirmed** phone-gap-then-reconnect event captured with the instrumentation live. "Confirmed"
means the operator knows they left the phone out of range for ≥30 min and returned — not an inferred
gap from telemetry alone. One pool session is sufficient.

### Reading the result

```
backfill_len_rejected present, mod9 == 0          → H2. Confirm the payload really does split into
                                                    N valid 9-byte G7BackfillMessages before
                                                    writing the parser — the hex is in the event.
backfill_len_rejected present, mod9 != 0          → unknown format. The hex is already captured, so
                                                    analyse it offline. Do NOT guess offsets
                                                    (index: Prohibited).
backfill_len_rejected absent, gap confirmed       → H1. Proceed to Phase 2.
backfill_len_rejected present, truncated == true  → raise the cap and recapture before parsing;
                                                    do not infer the tail.
```

> **Do not conclude H1 from a quiet week.** Absence only counts against a *confirmed* gap event. A
> week with no pool session proves nothing, and reading it as H1 would repeat exactly the
> survivorship error this task exists to correct.

---

## Phase 1 — Chunk-tolerant parser (ONLY if H2)

**Repo:** `G7SensorKit` fork. **Depends on:** Phase 0 verdict = H2.

Make the handler parse `count / 9` records when the length is a clean multiple of 9. This is a
**strict superset** of current behaviour — a 9-byte packet still yields exactly one record — so it
cannot regress the routine push path that `B192` already validates.

Constraints:

- Reject non-multiples of 9 loudly (keep the telemetry from Phase 0); never guess offsets.
- Preserve buffer/flush semantics — records still accumulate into `backfillBuffer` and flush on
  `0x59` / disconnect. Do not restructure the flush path in this change.
- Still **no writes**. The passive-observer contract holds; this is parsing what already arrives.
- Sanity-cap the record count per packet so a malformed length cannot produce an absurd allocation.

Then verify the recovered readings actually land in the phone's Core Data store, not merely the
buffer — `flushBackfillBuffer` → delegate → `G7CGMManager` → `FetchGlucoseManager`. A parser fix that
stops at the delegate boundary looks like success in telemetry and changes nothing for the user.

**Watch-side storage is `TRIO-029`, not this task** — but if H2 holds, sequence TRIO-029 immediately
after, because arrival volume stops being marginal and the discard becomes load-bearing.

---

## Phase 2 — Nightscout auto-backfill (ONLY if H1)

**Repo:** `Trio`. **Depends on:** Phase 0 verdict = H1. File as its own task with the H1 evidence
attached; the design below is the starting position, not a committed spec.

Topology that makes this work at all: Dexcom app → Dexcom Share → Nightscout. That is a genuine
second uploader, so NS holds readings Trio cannot otherwise obtain.

- **Trigger:** gap detected (last reading 15 min – 3 h old) enters a *persistent* "filling" state;
  retry on foreground **and** on a modest timer while in that state; exit on success or ~30 min.
- **Why not one-shot on foreground:** the Share→NS bridge polls on ~5 min cadence, so at the moment
  Trio foregrounds the data has not arrived at NS yet. A single fetch at reconnect returns nothing.
  This is the failure mode a naive implementation would ship with.
- **Window:** `since: glucoseStorage.syncDate()`, not the manual button's hardcoded 24 h.
- **Write path:** `GlucoseStorage.backfillGlucose(_:)` — 1 s buffer vs `DeletedGlucoseStored` +
  3.5 min vs existing. **Never** `storeGlucose(_:)`, which the manual button uses and which will
  resurrect deliberately-deleted readings on every retry.
- **Upper bound ~3 h**, matching sensor storage: beyond it the data does not exist anywhere in the chain.

Known risk to resolve before shipping: `configureGlucoseEntry` sets `isUploadedToNS = false` on every
inserted row (`GlucoseStorage.swift:211-219`, shared by both storage paths), so backfilled rows get
POSTed back to Nightscout under Trio's own `device` string while the originals carry the Share
bridge's. Whether that dedups is NS-version-dependent — verify against the operator's own instance
before enabling, or every pool session doubles its entries.

---

## Out of scope

- Any write to the sensor, including a range request — index Idea #8, unchanged.
- Watch→phone EGV sync — `TRIO-024`.
- Watch-side backfill storage — `TRIO-029`.
- Changing the manual "Backfill Glucose" button's 24 h window or its `storeGlucose` call. Worth
  fixing on its own merits (same deleted-glucose hazard) but it is not on this path.

## Risks

| Risk | Handling |
|---|---|
| Concluding H1 from absence of evidence | Exit criterion requires a *confirmed* gap event, not elapsed time |
| Guessing at an unknown packet format | Non-multiple-of-9 → capture hex, stop, escalate. Prohibited list is explicit |
| Phase 1 regressing the routine push | Superset-by-construction; a 9-byte packet takes the identical path |
| Parser fix that never reaches storage | Phase 1 verification is Core Data arrival, not buffer arrival |
| NS re-upload duplicate cascade (Phase 2) | Verify dedup on the operator's own NS before enabling |
