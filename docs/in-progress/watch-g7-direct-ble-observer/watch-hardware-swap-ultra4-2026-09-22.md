# Watch hardware swap: Apple Watch Ultra 4 (2026-09-22)

## Event

- **2026-09-22 21:30 CEST (19:30 UTC)**, as reported by the user: switched to a new **Apple Watch Ultra 4**. Same Trio build (**226**) on both watches.
- Telemetry shows the new watch started logging at **~21:11 CEST (19:11 UTC)**: watch battery jumps from 55% to 90%, and the first `expected_window` tick has `last_success_epoch=-1` (fresh install). Its first EGV arrived at **21:32:11 CEST**. Treat 19:11–19:30 UTC as setup time, not steady state.
- **Confounder: the G7 sensor also changed the same evening.** `DXCMwO` → `DXCMcq`. `DXCMcq` sent its first watch EGVs at ~18:27 UTC while the old watch was still worn. Its `message_timestamp` at 19:32 UTC was 6226 s, so the sensor session started around 17:48 UTC. Sensor placement and radio differences are therefore mixed in with the watch change.
- There is no device-model field in watch telemetry. The watch is identified by time boundary only.

## Baseline: old watch, build 226

Window: **2026-09-16 17:00 → 2026-09-22 18:00 UTC** (145 h, sensor `DXCMwO`). Telemetry ring drops: `ring_dropped_total=0`.

| Metric | Value |
|---|---|
| Distinct g7_ble EGVs (unique sensor sequence) | 744 |
| EGV coverage (EGVs / 12 per hour) | **42.8%** (744 / 1740) |
| Hours with ≥11 EGVs | 10 / 145 (6.9%) |
| Hours with 8–10 / 4–7 / 1–3 EGVs | 31 / 58 / 17 |
| Hours with zero EGVs | 29 / 145 (20%) |
| g7_ble connects (ext_session_active stamped) | 1400 |
| Session coverage (session connects / all connects) | 16.3% (228 / 1400) |
| Session-active yield (EGV / connect) | 93.0% (212 / 228) |
| No-session yield | 45.6% (535 / 1172) |
| Overall g7_ble yield | 53.4% (747 / 1400) |
| pre_egv_disconnect (no session / session) | 634 / 16 |

Old-watch daily distinct EGVs (local day, out of 288 possible): 09-17 119, 09-18 112, 09-19 158, 09-20 140, 09-21 73.

## Early new-watch sample (not conclusive)

From 19:32 to 20:05 UTC, all 7 five-minute slots got an EGV (sequence 23–29, `time_to_first_egv_ms` of about 1.1–1.7 s). Every event had `ext_session_active=true`. The user was actively using the new watch during setup, so this says nothing yet about background behavior.

## Queries (source 1659391, table `t491594.trio`)

Data older than ~30 min is in `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`. The last ~30 min is in `remote(t491594_trio_logs)`. The watch flushes logs in batches, so recent watch data can lag behind in s3.

EGV coverage by hour:

```sql
SELECT countIf(n>=11) h11_12, countIf(n>=8 AND n<11) h8_10, countIf(n>=4 AND n<8) h4_7, countIf(n<4) h1_3, count() hours_with_any, sum(n) total
FROM (SELECT toStartOfHour(dt) h, uniqExact(extract(JSONExtract(raw,'message','Nullable(String)'),'sequence=(\\d+)')) n
      FROM s3Cluster(primary, t491594_trio_s3)
      WHERE _row_type = 1 AND dt >= <start> AND dt < <end>
        AND JSONExtract(raw,'platform','Nullable(String)')='watchos'
        AND JSONExtract(raw,'event','Nullable(String)')='egv_received'
        AND extract(JSONExtract(raw,'message','Nullable(String)'),'module=(\\S+)')='g7_ble'
      GROUP BY h)
```

Yield split by session:

```sql
SELECT extract(JSONExtract(raw,'message','Nullable(String)'),'ext_session_active=(\\S+)') sess,
  countIf(JSONExtract(raw,'event','Nullable(String)')='did_connect') connects,
  countIf(JSONExtract(raw,'event','Nullable(String)')='egv_received') egvs,
  countIf(JSONExtract(raw,'event','Nullable(String)')='pre_egv_disconnect') pre_egv_disc
FROM s3Cluster(primary, t491594_trio_s3)
WHERE _row_type = 1 AND dt >= <start> AND dt < <end>
  AND JSONExtract(raw,'platform','Nullable(String)')='watchos'
  AND JSONExtract(raw,'category','Nullable(String)')='WatchTelemetryRing'
  AND extract(JSONExtract(raw,'message','Nullable(String)'),'module=(\\S+)')='g7_ble'
  AND extract(JSONExtract(raw,'message','Nullable(String)'),'ext_session_active=(\\S+)') != ''
GROUP BY sess
```

Note: the per-day counts of `expected_window` ticks are only 34–130 against 288 possible, because ticks fire only while the watch process is awake. Do not use them as the success denominator. Use distinct EGV sequences against 12 per hour.

## 24 h comparison (scheduled for 2026-09-23 21:30 CEST)

Run 2026-09-23 ~19:30 UTC. **New-watch window: 2026-09-22 19:30 → 2026-09-23 19:27:25 UTC** (latest watchos row). s3 was used for `dt < 2026-09-23 18:37:12` (s3 max for watchos) and `remote(t491594_trio_logs)` from 18:37:12 onward, so no row is counted twice. Hourly stats use hour buckets shifted by 30 min (19:30–20:30, …), which gives 24 buckets matching the 21:30 CEST boundary. Setup time (19:11–19:30 UTC) had 11 `did_connect`, 0 EGVs, and is excluded.

**Second confounder: the build changed mid-window.** Watch build 226 ran until 22:05:30 UTC. Build **227** has run from 22:08 UTC, so about 21.4 h of the 24 h is on 227. Per the commit log (`92ab21640`), 227 keeps the G7SensorKit fork pin (`0013c90`) and the other 28 watch-g7 files byte-identical. Only the base pin and the corner-complication `#if os(watchOS)` context changed. A G7 BLE behavior change is therefore unlikely, but the upgrade relaunched the app.

Drops: `ring_dropped_total=0`, WatchLogger `logs_dropped_total=0`, `daily_lines_dropped_total=0` on both 226 and 227. Sensor `DXCMcq` throughout.

| Metric | Old watch, 145 h baseline | Old watch, same local hours (6 days)¹ | **New watch, 24 h** |
|---|---|---|---|
| Distinct g7_ble EGVs | 744 | 107 / 118 / 149 / 142 / 78 / 125 | **151** |
| EGV coverage | 42.8% | 37.2 / 41.0 / 51.7 / 49.3 / 27.1 / 46.3% (mean ≈42%) | **52.4%** (151/288) |
| Hours with ≥11 EGVs | 6.9% | 0–3 per day | 3/24 (12.5%) |
| Hours 8–10 / 4–7 / 1–3 | 31 / 58 / 17 of 145 | — | 6 / 11 / 4 of 24 |
| Zero-EGV hours | 20% | 7 / 5 / 3 / 3 / 9 / ~1 per day | **0/24 (0%)** |
| Longest EGV gap | — | — | 55 min (03:07→04:02 UTC) |
| g7_ble connects | 1400 | 181 / 222 / 267 / 253 / 186 / 263 | 318 |
| Session coverage | 16.3% | 16.0 / 10.8 / 26.2 / 23.7 / 5.4 / 10.3% | **27.0%** (86/318) |
| Session yield | 93.0% | 90–100% (40% on 09-20, n=10) | 100% (86/86) |
| No-session yield | 45.6% | 53.9 / 48.0 / 42.1 / 44.6 / 42.0 / 41.5% | **28.4%** (66/232) |
| Overall yield | 53.4% | 59.7 / 53.6 / 55.8 / 56.5 / 41.9 / 47.5% | 47.8% (152/318) |
| pre_egv_disconnect (no session / session) | 634 / 16 | — | 165 / 1 |

¹ 19:30→19:30 UTC windows starting 09-16 … 09-21, sensor `DXCMwO`, build 226. The 09-21 window stops at 09-22 18:00 (22.5 h, coverage out of 270).

Zero-EGV runs ≥2 h: **none**. Every shifted hour had at least 2 EGVs. The old watch averaged about 5 zero hours per day, mostly overnight.

By build: 226 (19:30–22:05) had 13/13 session and 6/15 no-session. 227 had 73/73 session and 60/217 no-session.

**Verdict: similar to slightly better, not notably better.** Coverage of 52.4% is at the top of the old watch's same-hours range (27–52%, mean ≈42%), and the absence of zero-EGV hours is the clearest improvement. The source of the gain matters more. There were 86 session EGVs against 4–66 per old day, and session coverage rose to 27%, while **no-session (background) yield fell to 28%**, below every old day (42–54%). Background connects (232) were in the old range (152–236), but fewer of them produced EGVs. That points at **behavior**: more app/session time on a new watch (first-day novelty) filled the gaps. It does not point at better hardware or radio. The lower background yield could come from the new sensor `DXCMcq` (placement or radio), from the new watch, or from both, and this data cannot separate them. n=1 day, directional only. Confounders: sensor change `DXCMwO`→`DXCMcq`, build 226→227 at 22:08 UTC (low risk for BLE), and the first-day novelty effect.

**72 h recheck: worthwhile.** The deciding question is whether no-session yield stays near 28% once app use returns to normal. If it does, that is a real background regression to explain, from the sensor or the watch. Also check whether session coverage falls back toward about 16%, which would pull coverage back to the old range. Recheck window: 2026-09-22 19:30 → 2026-09-25 19:30 UTC, split by day.

## 72 h recheck

Run 2026-09-25 ~19:35 UTC (scheduled task, read-only). **Window: 2026-09-22 19:30:00 → 2026-09-25 19:30:00 UTC.** The latest watchos row was 19:30:11. Days are 19:30→19:30 UTC:

- Day 1: 09-22 19:30 → 09-23 19:30
- Day 2: 09-23 19:30 → 09-24 19:30
- Day 3: 09-24 19:30 → 09-25 19:30

Hour buckets are shifted to :30.

**Sources and de-duplication:** each query unions `s3Cluster(primary, t491594_trio_s3)` (`_row_type = 1`) with `remote(t491594_trio_logs)` over the same `dt` range and takes `SELECT DISTINCT raw, dt`. This departs from the plan to "use remote only for rows newer than s3 max(dt)". The s3 max for watchos was 17:45:55, but remote held WatchTelemetryRing rows back to 16:27:22 that were not in s3. The overlap check found 0 shared `raw` values across 251 rows. Because watch rows upload late with their original `dt`, a `dt` cut would drop rows. Distinct-`raw` counts no row twice. EGVs are also de-duplicated on `(sensor_name, sequence)`. Day 1 now shows 1 more session connect than the 24 h run (319 vs 318), from a late-arriving row.

**Drops:** `ring_dropped_total=0`, `logs_dropped_total=0` and `daily_lines_dropped_total=0` on every build (226–230).

**Sensor:** `DXCMcq` throughout. There was no sensor change.

**New confounders: three more builds.** 228 from 09-23 23:12, 229 from 09-24 13:19, 230 from 09-24 18:39. Day 2 spans 227→228→229→230, and day 3 is all on 230. All three are TRIO-063 complication work (Glucose Bobble/circular complication, background payload wiring in WatchState). Between 227 and HEAD, the only diff in `G7WatchSensorAdapter.swift` is one added complication-colour field. The G7 BLE code is effectively unchanged. The watch app-lifecycle and complication wake paths did change, and I have not verified that they don't affect BLE wakeups.

| Metric | Old watch, same hours (6 days) | Day 1 | Day 2 | Day 3 | 72 h |
|---|---|---|---|---|---|
| Builds | 226 | 226→227 | 227→228→229→230 | 230 | — |
| Distinct g7_ble EGVs | 78–149 | 151 | 76 | 86 | 313 |
| EGV coverage | 27–52% (mean ≈42%) | **52.4%** | **26.4%** | **29.9%** | 36.2% (313/864) |
| Hours ≥11 / 8–10 / 4–7 / 1–3 | 0–3 / 2–6 / 9–13 / 2–5 | 3 / 6 / 11 / 4 | 4 / 2 / 2 / 0 | 0 / 5 / 6 / 1 | 7 / 13 / 19 / 5 |
| Zero-EGV hours | ~1–9 (≈5/day) | 0 | **16** | **12** | 28 / 72 |
| Zero-*connect* hours | same as zero-EGV hours | 0 | 16 | 11 | 27 / 72 |
| Longest EGV gap | — | 55 min | **1005 min** (09-23 20:17 → 09-24 13:02) | **548 min** (09-25 06:27 → 15:35), then 183 min to the window end | 1005 min |
| g7_ble connects | 181–267 | 319 | **88** | 173 | 580 |
| Session coverage | 5–26% | 27.3% (87) | 77.3% (68) | **9.2%** (16) | 29.5% (171) |
| Session yield | 90–100% | 98.9% | 98.5% | 93.8% | 98.2% |
| **No-session yield** | **42–54%** | **28.4%** (66/232) | **45.0%** (9/20, tiny n) | **45.2%** (71/157) | 35.7% (146/409) |
| Overall yield | 42–60% | 47.6% | 86.4% | 49.7% | 54.1% |
| pre_egv_disconnect (no session / session) | — | 165 / 1 | 11 / 1 | 85 / 1 | 261 / 3 |
| Median connected RSSI (`rssi_read`) | −84 to −89 | −87 | −88 | −87.5 | — |

**(a) Background yield recovered.** No-session yield went 28.4% → 45% → 45.2%. Days 2 and 3 are back inside the old-watch range (42–54%). Day 2's no-session sample is only 20 connects. The day-1 drop looks like a first-day artifact. It is not a persistent per-connect regression, and connected RSSI is unchanged (about −87 dBm on both watches and both sensors).

**(b) Session coverage fell back, and so did EGV coverage, below the old range.** Day 3 session coverage was 9.2%. Day 2's 77% is an artifact of only 88 connects. EGV coverage fell to 26.4% and 29.9%, at or just below the old floor of 27%.

**The new problem is long stalls with no connects at all.** Per-connect yield is not the issue. Days 2 and 3 each contain multi-hour blocks with zero g7_ble `did_connect` while the watch app keeps logging:

- **09-23 20:17 → 09-24 13:02 (16.7 h), builds 227/228.** The onset was on 227, about 3 h before 228 installed. The watch kept issuing `connect_called`, which ended in `connect_timeout` (pending ages up to 1500 s). It also logged `phantom_disconnect`, `stale_sensor_binding_suspected`, `stale_sensor_reinit`, `ble_gated reason=no_runtime` and 18 relaunches (`will_restore_state`/`central_powered_on`), with no heartbeats between 00:30 and 12:30. `did_discover` RSSI was −84, which is normal. Heartbeats at 22:30–23:30 showed `central_state=2`. Recovery came at about 12:30 when a session started, just before 229 installed.
- **09-25 06:27 → 15:35 (9.1 h), build 230.** From 06:30 to 08:30 the central was poweredOn and the peripheral was connecting/disconnecting (1/3), but nothing connected. From **09:30 to 14:30, every heartbeat reported `central_state=2`**, then again from 16:30 to 19:30.
- `central_state` is `CBManager.state.rawValue`. I checked against the watchOS SDK `CBManager.h`: unknown=0, resetting=1, **unsupported=2**, unauthorized=3, poweredOff=4, poweredOn=5. CoreBluetooth on the watch reported **`.unsupported`** for hours at a time. On the old watch this appeared once in 5 days (6 heartbeats, 09-19 23:41 → 09-20 03:01). On the new watch it appeared in 4 separate spans in 48 h: 09-23 22:33–23:59, 09-24 ~12:40, 09-24 20:30–21:30, 09-25 09:30–14:30 and 16:30–19:30. This is a watch-side OS/radio state and says nothing about the sensor.
- During the day-2 stall, the phone kept delivering fresh readings to the watch complication (for example `reading_date` 08:22 with an age of 6 min). The sensor was transmitting throughout.

**Verdict: worse on days 2–3, and not because of background yield.** Background yield recovered to the old range, so the day-1 drop does not persist. EGV coverage fell to 26–30%, zero-EGV hours rose to 16 and 12 against about 5 per day, and the longest gaps were 16.7 h and 9.1 h. The cause is whole-block stalls in which the watch never connects, partly while CoreBluetooth reports `.unsupported`. Candidate causes:

1. **Watch hardware/OS (Ultra 4, watchOS 27).** Favoured by the `.unsupported` spans, which are watch-side and far more frequent than on the old watch, and by the phone getting readings throughout.
2. **Builds 228–230.** Complication and WatchState background-payload changes could affect app wake and BLE lifecycle. The G7 adapter code is unchanged, and the first stall began on 227, before 228.
3. **Sensor `DXCMcq`.** Weakly supported only: RSSI is normal and the phone kept receiving readings.

The same stall pattern at the per-connect level is not separable from these with this data. n=1, directional only.

**One concrete way to tell them apart:** after the next G7 sensor change, with the Ultra 4 and a build that has no watch lifecycle changes, run the per-day histogram of `heartbeat central_state` counts plus zero-connect hours. If `.unsupported` spans and multi-hour zero-connect blocks continue on a new sensor, the sensor is ruled out and the cause is watch/OS. Cheaper, and possible now: correlate the `.unsupported` spans with watch-side context (Low Power Mode, sleep focus, charging, off-wrist). A one-line change adding `ProcessInfo.isLowPowerModeEnabled` to the heartbeat would test the most likely OS trigger.

Caveat: the last 183 min of day 3 (16:27 → 19:30) may be partly upload lag. Heartbeats in that span do show `central_state=2`, so it is probably real.
