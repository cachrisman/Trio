+++
uid = "01a1bd22-8120-7331-8063-11c0a6c88d96"
key = "TRIO-110"
title = "G7SensorKit: skip the opportunistic readRSSI on connect on watchOS so late-auth links finish their read"
status = "dropped"
kind = "code"
source = "agent-start"
source_ref = "docs/in-progress/watch-g7-egv-capture/plan.md#W4"
created = 2026-11-08
updated = 2026-11-08
touched = 2026-11-08
closed = 2026-11-08
first_closed = 2026-11-08
tags = ["watch", "g7"]
parent = "01a1bd22-5e52-7284-a2e3-3b06fed3e6d9"
priority = 3
after = ["01a1bd22-5fa8-7543-ba29-95050bc3f332"]

[[acceptance]]
id = "AC-1"
text = "readRSSI on connect skipped or deferred on watchOS only; phone path byte-identical in behaviour; edited in the standalone G7SensorKit clone and repinned"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-2"
text = "Fork unit tests pass; patch-test.sh clean"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-11-08

[[acceptance]]
id = "AC-3"
text = "Soak: C7 share (auth05 present, no EGV) before vs after from link_summary"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-11-08
+++

## Intent

Plan docs/in-progress/watch-g7-egv-capture/plan.md W4. C7 links (~6%) authenticate at ~1.6 s and are cut off ~2 s later. The fork issues peripheral.readRSSI() on every connect before readied (G7BluetoothManager.swift:1600). Guard it with #if !os(watchOS) or defer it until after the control subscribe; the phone path must not change. Edit only in the standalone G7SensorKit clone. Expected C7 ~6% -> ~3% (inference).
