+++
uid = "019f8141-e117-77db-9216-aad03fbb7431"
key = "TRIO-003"
title = "Build 219: single-sensor re-read to de-confound no-session-yield regression"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/watch-g7-direct-ble-observer/build219-impl-plan.md#L55"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["watch", "g7", "telemetry"]
+++

## Intent

Build 218's soak (94h, n=1) showed a no-session EGV yield drop (52.1% → 29.5%), but the soak
spanned two sensor changes (DXCMWF → DXCM8a) plus RF, so the signal is confounded. Per the
intervention-index discipline (re-derive from classified episodes; check the confound before
building), build 219's first move is a clean single-sensor re-read of the telemetry — not a code
change. Only if the drop survives sensor-stable data does it become a candidate for a code-level
fix. See `docs/in-progress/watch-g7-direct-ble-observer/build219-impl-plan.md` §"Scope of 219" and
`egv-intervention-index.md`.

## Acceptance criteria

- [ ] Pull single-sensor BetterStack telemetry (no sensor change mid-window)
- [ ] Re-derive no-session yield on that clean window
- [ ] Record verdict: drop confirmed (candidate for 219) vs. sensor/RF artifact (drop the lever)
