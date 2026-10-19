+++
uid = "01a14492-e10e-72b5-afb6-a26baf85e8c5"
key = "TRIO-078"
title = "Phone misses G7 readings the Dexcom app on the same phone receives live (connection-level loss)"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "side-2332fe6b/phone-conn-loss-vs-dexcom"
created = 2026-10-16
updated = 2026-10-16
touched = 2026-10-16
tags = ["g7", "ble", "phone", "capture"]
files = ["G7SensorKit/G7CGMManager/G7PeripheralManager.swift", "G7SensorKit/G7CGMManager/G7BluetoothManager.swift"]
priority = 3

[[acceptance]]
id = "AC-1"
text = "Timeline of at least 3 missed phone cycles from telemetry, showing where Trio's attempt fails while the Dexcom app's succeeds"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-10-16

[[acceptance]]
id = "AC-2"
text = "Either a tested change with a measured capture gain on one sensor, or a written conclusion that the loss is not fixable on Trio's side"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-10-16
+++

## Intent

On the phone, Trio misses G7 readings that the Dexcom app on the same phone receives live from the same sensor. Find out why Trio's connection fails on cycles where the Dexcom app's succeeds, and fix whatever part of that is on Trio's side.

## Evidence (2026-10-16)

- Slot analysis over 12 weeks of raw Nightscout (26,292 five-minute slots, Jul 17 – Oct 16). Each slot is classed by whether a Trio Bluetooth reading or a Share gap-fill exists within ±150s, after reclassifying Share echoes (see the Share-echo task):
  - Trio has 23,834 slots.
  - Share fills 2,358 slots that Trio missed.
  - 100 slots (0.38%) are missing from both.
  - Share fills are uploaded within 7 min for 2,252 of 2,358 slots (96%), which means the Dexcom app had the reading live, not by its own backfill.
  - On sensor DXCMVL (Oct 3–13), Trio missed 614 readings and Share filled every one of them, all within 7 min. The Dexcom app's Bluetooth path on the same phone was close to perfect while Trio's ran at 79.5%.
- Phone BetterStack, 8 days: 1929 `egv_received` = 1929 stored, so nothing received is dropped (not Trio#1610). The loss is entirely in connections that never deliver an EGV:
  - 2445 `connect_timeout` (age ≈290s)
  - 742 `command_timeout op=discover_services timeout_s=2` (G7PeripheralManager.swift:414)
  - 284 `auth_notify_failed`
  - 177 `configure_retry_abandoned reason=disconnected`
  - 152 remote disconnect with `pending_auth=true` → `suspected_end_of_session`
  - 8 "Forgetting existing sensor"
- Loss is worst at night (Share fills are 19–28% of readings at 21:00–04:00 UTC and 5–12% by day). `suspected_end_of_session` per hour correlates with Share fills per hour at r = 0.78.
- Capture varies by sensor: 79.5% to 94.9% across the last 8 sensors. That fits a margin problem, where a weak link affects Trio's attach more than the Dexcom app's.
- Prior connection work (C-212-1 connect timeout, C-212-3 suspected-EOS corroboration, build190 discovery watchdog) targeted the watch. Nothing measures the phone against the Dexcom app's own success on the same cycle.

## Questions

- On a cycle where the Dexcom app gets the EGV and Trio logs `discover_services` timeout or `configure_retry_abandoned`, what sequence does Trio go through? Does a 2s discovery timeout abandon a link the Dexcom app is still using?
- Does a longer `discover_services` timeout, or not abandoning on `disconnected` while the Dexcom app holds the link, raise capture? A/B on a single sensor, comparing nights.
