# G7 phone missed readings — per-sensor, left-arm pattern (2026-10-28)

Question: since build 233, the iPhone app seems to miss G7 readings often, and the operator keeps pulling down to backfill from Nightscout. Is the cause the operator's build, the G7SensorKit fork, upstream, or something else? Scope is the phone app only.

## Method

- **Nightscout:** the MCP `get_glucose` in `provenance: true` mode, in 120-hour windows from 2026-08-24 to 2026-10-28 09:05Z, with 18,661 five-minute slots. Each slot is classified as follows:
  - `direct`: Trio uploaded it, no device, insert lag under 60 s.
  - `direct_late`: Trio uploaded it with a lag of 60 s or more, i.e. a G7 BLE backfill or a delayed upload.
  - `ns_only`: only Dexcom Share had it. That is either `device: dexcom-share`, or a Share document that Trio re-uploaded, signed by an insert lag of 15 s or more at the cron phase (minute%5==0, second 8–45).
  - `ns_only` means Trio's BLE missed the reading while the Dexcom app on the same phone got it.
  - Entries within 150 s of each other are one slot.
- **Sensors:** taken from `Sensor Start` treatments. Builds are taken from the `cachrisman/Trio` localCI release times.
- **Arms:** the operator alternates arms on every sensor. DXCM8o (10-24) is on the left arm and DXCMKV (10-13) on the right. The watch (an Apple Watch Ultra 4 since 2026-09-22 19:30Z) is worn on the left wrist. During the day the phone is in the left pocket.
- **Phone telemetry:** BetterStack source 1659391, `platform=ios`. Retention is only about 8 days, so it covers 10-20 09:10Z → 10-28 only.
- **Raw data is local only, in `data/`, which is gitignored by its own `data/.gitignore` (`*`).** Never commit it; the fork is on GitHub. It contains:
  - `data/raw-mcp/`: the untouched MCP `get_glucose` (provenance) and `get_treatments` results.
  - `data/nightscout-entries-provenance.csv`: one row per Nightscout entry (18,776 entries).
  - `data/slots.csv`: one classified row per 5-minute slot, with sensor, arm and build.
  - `data/scripts/load.py` and `classify.py`: the classifier. Run it with `cd data/scripts && python3 -I -c 'import sys; sys.path.insert(0,"."); from classify import *; print(len(slots()))'`.
  - The sensor and build boundaries are hard-coded in `classify.py`. Extend them for new data.
- If the data is ever lost, re-pull it with the MCP as above.

## Findings

### 1. Miss rate tracks the sensor, not the build

| Sensor (start) | Arm | Watch | Builds | Slots | Missed (`ns_only`) |
|---|---|---|---|---|---|
| (before 09-01) | L | old | 222–223 | 2411 | 7.8% |
| DXCMPO 09-01 | R | old | 223 | 3014 | 9.0% |
| DXCMwO 09-12 | L | old | 223–226 | 3017 | 4.9% |
| DXCMcq 09-22 | R | Ultra 4 | 226–230 | 2988 | 4.5% |
| **DXCMVL 10-03** | **L** | **Ultra 4** | 228–231 | 3016 | **20.4%** |
| DXCMKV 10-13 | R | Ultra 4 | 231–233 | 3019 | 5.3% |
| **DXCM8o 10-24** | **L** | **Ultra 4** | 233 | 1196 | **24.3%**, rising: 16, 15, 27, 34% per day |

- **Same build, different sensors:**
  - Build 233 missed 4.2% on DXCMKV and 24.3% on DXCM8o.
  - Builds 228–230 missed 4.3% on DXCMcq and 20.5% on DXCMVL.
- **Left arm with the Ultra 4 runs at 21.5%. Every other combination runs at 4.9–9.1%:** left arm with the old watch 6.2%, right arm with the Ultra 4 4.9%, right arm with the old watch 9.1%. Only two sensors fall in the bad cell, so this is a strong pattern, not proof.
- **Within the Ultra 4 era:**
  - Left arm: 19.8% by day (07–23), 25.3% at night (23–07).
  - Right arm: 3.1% by day, 8.2% at night.
- The bad sensors were bad from day 0 and at all hours. Misses are mostly single slots ("flapping"), not long outages. Glucose level makes no difference.
- G7 BLE backfill almost never recovers a missed slot: `direct_late` was 13 on DXCMVL and 5 on DXCM8o.
- **Timing clue:** on the two bad sensors about 75% of missed slots carry a Share timestamp 10–15 s after the normal reading phase. On the good sensors it is 0–5 s. The phone's remote disconnects land at about the same offset.

### 2. Upstream did not regress

- LoopKit/G7SensorKit #62/#63 (defer forgetting the sensor on a suspected session end) entered the fork at `0013c90`. That is the pin for builds 224–230. `1f12fea` (builds 231+) adds only translations on top.
- Sensors before it missed 7.8–9.0%, and the good sensors after it 4.5–5.3%.
- Trio-side patches 13, 15, 17 and 19 don't touch the BLE path; patch 13 adds only comments to `PluginSource.swift`. The first bad sensor (10-03) predates patches 15–19.

### 3. Phone mechanism, DXCMKV (right) vs DXCM8o (left), build 233

- **Unchanged:**
  - Connections: did_connect about 540 a day, connect_called about 900–1000 a day.
  - RSSI: median −82 vs −81. RSSI does not separate missed slots from received ones.
  - The fork's connect gate (`connect_gated`) fired 3–4 times in total, so it isn't a factor.
- **Changed, per day on the right arm vs the left arm:**

| Event | Right arm | Left arm |
|---|---|---|
| `command_timeout` | 6–16 | 68–188 |
| `auth_notify_failed` | 1–9 | 30–77 |
| `suspected_end_of_session` | 7–10 | 25–55 |
| `configure_block_skipped` (fork C3 path) | 18–37 | 56–200 |

- **Where missed slots die:** about 74% hit GATT timeouts (discover_services or set_notify_authentication). About 23% get a connect and then a remote drop before auth. About 2% show no phone event at all.
- **The link is still up during the timeouts:** 92% of discover_services and 86% of set_notify_authentication timeouts fire with `peripheral_state=2` (connected).
- **Replies arrive late:** in 29% of auth-timeout misses, `auth_notify_subscribed` arrives 1–2 s after the 2 s timeout. Counting any late completion, it is 39%.
- **Healthy vs missed timing:**
  - A healthy slot completes connect → auth → EGV within 1 s.
  - The sensor closes the link 7–10 s after connect either way.
- **Inference:** on these sensors the GATT exchange is slow, and the 2 s per-op timeout (upstream's value) gives up on a live link. Why the exchange is slow is unproven.

### 4. Watch-contention hypothesis: not supported

The watch is on the left wrist, so a left-arm sensor sits next to both the watch and (by day) the phone in the left pocket. Watch telemetry covers 10-20 → 10-28.

- **The watch is much closer on the left arm:** watch RSSI median −80 on DXCM8o vs −88 on DXCMKV. Phone RSSI is unchanged (−81 vs −82).
- **The watch does not connect more:** 20.4 connects/h vs 23.8/h.
- **The watch fails too:** its EGV per connect fell from 0.51 to 0.39.
- **A watch connect doesn't raise the phone's miss chance.** On DXCM8o, the phone missed:
  - 22% of slots where the watch connected,
  - 24.5% of slots where it didn't.
- **Missed slots show no extra overlap:** a watch connect within ±10 s of a phone connect occurred in 65.6% of missed slots vs 67.7% of received ones.
- **Reading:** the cause is shared and sits on the sensor/link side. Both devices see a slow, lossy GATT exchange with this sensor, not the watch crowding the phone out.
- Two caveats:
  - The data only shows correlation, and it can't rule out a constant background airtime cost that affects every slot equally.
  - Whether the left arm itself matters, e.g. body position, or whether it's these two sensor units, can't be separated with n=2. The left-arm sensor of 09-12, worn with the old watch, was fine at 4.9%.

## Related upstream reports

- nightscout/Trio#1384, #1514, #1521, #1610 (open): passive-mode G7 gaps. Maintainers attribute them to eavesdropping on the Dexcom app's connection. The structural fix is Direct mode, nightscout/Trio#1548 (merged to `dev` on 10-18).
- LoopKit/G7SensorKit#78 attributes the remaining tester outages to poor signal or CBError 15.
- Several reports are on iOS 27. None proves a cause.

## Next steps (proposed)

1. **Optional no-code A/B (lower priority after §4):** wear the watch on the right wrist, or turn its Bluetooth off, for 24–48 h on the current left-arm sensor, then compare the phone `ns_only` rate and `command_timeout`/day. This would rule out a background airtime effect that §4 can't see.
1b. **Try the next left-arm sensor in a different spot** (higher or further back), or report DXCM8o to Dexcom for replacement. That separates the site from the unit.
2. **Phone GATT timeout 2 s → 5 s.** Scope below.

## Scope: phone GATT timeout 2 s → 5 s

### What to change

All changes are in the G7SensorKit fork, in the standalone clone only, on `main`.

- `G7PeripheralManager.swift`, `foregroundDiscoveryTimeout = 2`. Used by `applyConfiguration`: discover_services, discover_characteristics, and the config `setNotifyValue` calls.
  - The fork already raises this to 6 s when `G7BackgroundHints.isHostBackgrounded`, i.e. a backgrounded watch (C-217 W-1).
- `G7PeripheralManager.swift`, `setNotifyValue(_:for: CGMServiceCharacteristicUUID, timeout: TimeInterval = 2)`, about line 684. This is reached via `listenToCharacteristic` for `.authentication`, `.control` and `.backfill`.
  - **This is where the `set_notify_authentication` timeouts come from.**
  - The existing background 6 s rule does *not* cover it, so changing only `foregroundDiscoveryTimeout` would leave about 40% of the timeout misses untouched.
- Keep the change iOS only.
  - The watch's foreground path uses the same constant, and the watch has its own tuning history.
  - Simplest option: `#if os(iOS)` → 5, else 2.
  - Alternative: a host-settable `G7BackgroundHints` value, default 2, set by Trio's phone host. That follows the fork's "opt-in per host" convention, but it also needs a Trio patch change.
- Leave alone:
  - the 1 s `write_control_extended_version`,
  - `connectAttemptTimeout` (60 s),
  - the C3 retry ladder (2/4/8/16/32 s backoff).
- **Recommended small addition:** emit a sampled success-latency field on the slow path, e.g. `op_ms` when an op takes over 1 s. Today only timeouts are logged, so we can't see the latency distribution. This shows whether 5 s is the right number.

### Expected effect and risks

- **Ceiling:** about 39% of DXCM8o timeout misses had the op complete late (median 3 s after the timeout). About 29% had the auth subscription complete 1–2 s late. Those are what a 5 s timeout could rescue.
  - Roughly, the DXCM8o miss rate would go from about 24% to about 15–17%.
  - The remaining roughly 60% of timeout misses never complete inside the window, and 23% of misses are pre-auth remote drops. A longer timeout doesn't help either group. **It mitigates; it doesn't fix.**
- **Window budget:** the sensor drops the link 7–10 s after connect.
  - A sequential worst case (discover 5 s, then auth 5 s) could overrun the window where today's 2 s + C3 retry at +2 s might squeeze in.
  - Healthy slots finish within 1 s, so they are unaffected.
- **Queue blocking:** `runCommand` blocks the peripheral `queue` on an `NSCondition` for up to the full timeout. A disconnect does not wake it; nothing broadcasts on disconnect.
  - On a dead link each op therefore holds the queue up to 5 s instead of 2 s.
  - Reconnects run on `managerQueue` and the next sensor window is about 5 min away, so this is low risk.
  - The C-208-12 lock-order fix (`queue.async` in the didSets) still holds.
- **Not insulin-dosing code**, but it is the primary CGM path. A regression would show up as gaps, not wrong values.

### Process

1. Create a TRIO task with ACs:
   - code change limited to the two sites, iOS only;
   - `timeout_s=5` visible in phone `command_timeout` telemetry;
   - on a left-arm sensor, phone `command_timeout`/day and the Nightscout `ns_only` rate fall below the DXCM8o baseline (about 24%, with `command_timeout` at 68–188/day);
   - no rise on right-arm sensors (baseline 4.5–5.3%).
2. Implement via task-relay (claude backend) in `~/Code/personal/health/diabetes/G7SensorKit`, then review with codex-work (gpt-5.6-terra, high).
   - `agent.signing = deny`, so the operator commits and pushes the fork.
3. Repin the submodule in `patches/02-g7-reading-time-with-seconds.patch` via `./scripts/mid-stack-update.sh`, then run `./scripts/patch-test.sh`.
4. Build only on explicit request.
5. **Timing confound:** the next sensor will be on the right arm, which already performs well. The test must ship while DXCM8o is still worn (10-day end about 11-03 16:52Z, 15-day end about 11-08), or wait for the next left-arm sensor.
6. **Run the no-code watch A/B first or separately, not at the same time.** Changing both at once makes the result unattributable.
