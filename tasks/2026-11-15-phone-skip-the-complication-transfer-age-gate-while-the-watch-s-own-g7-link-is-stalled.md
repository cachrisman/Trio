+++
uid = "01a1de17-fecd-7543-8453-125438b62456"
key = "TRIO-135"
title = "Phone: skip the complication transfer age gate while the watch's own G7 link is stalled"
status = "backlog"
kind = "code"
source = "human"
created = 2026-11-15
updated = 2026-11-15
touched = 2026-11-15
priority = 2
+++

## Intent

The phone's complication transfer age gate (TRIO-122, F1) holds a new reading back from the watch complication for up to 600 s, on the assumption that the watch's own G7 link fills the gap. When that link is stalled, nothing fills it, and the complication shows a reading up to about 10 minutes old while the phone has a fresh one. The gate should step aside while the watch's direct G7 link is stalled.

## Evidence (build 241, 2026-11-15, Better Stack source 1659391, times UTC)

- 06:20:17: the phone sends the 06:20:08 reading (119) via `transferCurrentComplicationUserInfo`. The gate passed: `complication_age_seconds=608`.
- 06:25:18: the phone builds the 06:25:08 reading (120) and skips it: `complication_transfer_age_gate_skipped skip_reason=age_gate age_seconds=309 threshold_seconds=600`. It skips again at 06:25:23.
- 06:25:21: the watch's own G7 link closes 2.2 s after link-up with no reading (`link_summary outcome=no_gatt`, `pre_egv_disconnect consecutive_count=3 minutes_since_last_egv=15`, `stale_sensor_binding_suspected`). The watch's last own reading was at 06:10:09.
- 06:30:00: the watch logs `direct_ble_stall_detected tier=stalled direct_stale_min=19 phone_fresh=true fault=dexcom_side`. The watch knows its link is stalled; the phone's gate doesn't.
- The operator saw the complication at about 06:29 showing 119, 8 minutes old, while the Dexcom complication showed 120.
- Part of this gap (06:27:53 to 06:30:17) was the build 241 install relaunching the apps, with watchOS not servicing 8 reload requests (`rate_limited`, `open_request_pending`). That part is a one-off and out of scope here. The 06:25:18 to 06:27:53 part was the gate plus the stalled link, and that can happen on any day.

## Wanted

- While the watch's direct G7 link is stalled, the phone sends each new reading to the complication without applying the age gate. Stalled means the watch reports `direct_ble_stall_detected`, or a defined run of pre-EGV disconnects or minutes without its own reading; settle the exact signal in the design.
- The watch has to tell the phone. Reuse an existing channel if one fits (applicationContext, or the watch state the phone already receives) rather than adding a new message path. A stale or missing stall report must fall back to today's gate, so the gate's budget saving still holds when the watch is healthy.
- Keep TRIO-122's sleep-aware behaviour (TRIO-121 sleep mode): decide in the design whether a stalled link overrides sleep mode or not, and say why.
- Mind the `transferCurrentComplicationUserInfo` daily budget: a bypass while stalled spends it faster. Log the bypass so post-deploy checks can count it (`complication_transfer_age_gate_bypassed reason=watch_ble_stalled …`).
- Nothing here touches insulin dosing.

## Notes

- Do not explain the stall itself through any phone-connection "favoring" or primary/secondary idea; that theory was ruled out. This task only makes the phone cover for a stall, whatever its cause.
- Related: TRIO-122 (the gate), TRIO-124 (coalescer fast path), TRIO-121 (sleep mode), TRIO-117 (build 240/241).
