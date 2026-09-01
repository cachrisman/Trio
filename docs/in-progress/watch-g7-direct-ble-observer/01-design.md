# Trio Watch Dexcom G7 Direct BLE Observer — Design v1

## Mission and premise

Implement a watch-only observer path that attaches to the Dexcom G7 watch app's already-owned BLE session on the same watchOS device, requests EGV data over Trio's own GATT view, and writes snapshots into Trio's complication pipeline with explicit source attribution.

This design assumes the Dexcom G7 watch app is installed and actively connected in direct-to-watch mode. Trio does not attempt to own auth or pair the sensor.

## Protocol sequence

1. Create long-lived `CBCentralManager` with restoration identifier.
2. On foreground `.active`, attempt attach ladder:
   - `retrieveConnectedPeripherals(withServices: [dataService])`
   - then scan fallback.
3. On connect, discover services/characteristics broadly (`nil`) and find auth/control/backfill/jpake by UUID.
4. Enable auth notify and control notify.
5. Observe auth payloads only (no auth writes, no J-PAKE participation).
6. Send EGV request opcode on control (`withResponse`) once control notify is active and again when auth notifications are observed.
7. Parse control notifications into glucose/trend, build `TrioComplicationSnapshot`, save via `TrioComplicationDataStore.shared.save(..., minInterval: 5)`.
8. On disconnect/failure, auto-retry with simple backoff.

## Filtering choice

Chosen: DiaBLE-style standalone tolerant matching (name/advertisement heuristic) with no iPhone bridge in this pass. Rationale: minimize dependencies and maximize attach probability when phone/watch builds are mismatched.

## Attach strategy

Chosen order:
1. `retrieveConnectedPeripherals(withServices:)`
2. broad scan (`withServices: nil`, duplicates allowed) with tolerant name matching.

Rationale: retrieval is fastest when OS already has active G7 link; scan fallback recovers when retrieval misses.

## Auth advance condition and EGV cadence

Advance condition: control characteristic notify enabled. Auth notifications are observed and used as positive signal; they are not a hard block because some session states may not expose stable `authenticated && bonded` semantics to observer clients.

Cadence:
- send once when control notify is enabled,
- send again on observed auth payload,
- resend after reconnect cycles.

This balances reliability and avoids tight polling loops.

## Reconnect / lifecycle

- Start on scene `.active`.
- Do not proactively tear down on `.inactive`/`.background`.
- Explicit `stop()` exists and stays separate from scene phase.
- Backoff is fixed simple retry (4s) with scan window timeout (12s).

`WKExtendedRuntimeSession` is omitted in this pass to keep scope focused on core attach/eavesdrop reliability.

## UI indicator design

Existing recency text is augmented to:
`<recency> · <source> · BLE:<status> <last-ble-recency>`.

- Source badges: `BLE`, `Phone`, `HK`, `?`.
- BLE status uses palette values (`off/searching/connecting/active/stalled/unavailable`).
- Last-direct-BLE-event recency remains visible even if current reading is from a different source.

## Source attribution model

`TrioComplicationSnapshot` carries `source: TrioReadingSource` (`direct_ble`, `phone_relay`, `healthkit`, `unknown`).

Phone relay messages include `readingSource=phone_relay`; direct BLE writes `direct_ble`.

## Observability plan

Structured logs with `event=g7_ble_*`, including:
- lifecycle/scene phase
- scan start/stop
- peripheral discovered/skipped with raw name, advertisement dictionary, RSSI, identifier
- connect attempt with `source=` attribution
- connect failure with NSError domain/code/description
- services/characteristics discovery
- notify enable states
- auth/control payload hex previews
- EGV request send / write ack / write failure
- session outcome on disconnect

No auth-init writes or J-PAKE ownership writes are emitted; J-PAKE is explicitly logged as skipped.

## Open design questions — decisions

1. **Filtering:** standalone tolerant matching. Reduces cross-device dependency and keeps attach path local.
2. **Attach strategy:** retrieval then scan. Fast path first, robust fallback second.
3. **Discovery breadth:** broad discovery (`nil`) for services/chars. Matches high-fidelity guidance and avoids missing variants.
4. **Timeout/backoff:** scan timeout 12s, reconnect 4s. Aggressive but bounded.
5. **Central queue:** `queue: nil` (main runloop callbacks). Simpler and aligned with UI/MainActor handoff needs.
6. **Restoration:** yes; restore peripherals and reconnect.
7. **connect options:** enable `NotifyOnDisconnection`.
8. **Auth advance:** control notify readiness + observed auth traffic when available; avoid strict bonded gate.
9. **EGV cadence:** on control-ready + auth-traffic + reconnect.
10. **Control write failure:** log + reconnect cycle.
11. **Backfill:** discover + explicitly log skipped in this pass.
12. **Stop scan after connect:** yes.
13. **Multi-peripheral:** first matching candidate; log all discovered for diagnostics.
14. **Identifier persistence:** not used in pass 1.
15. **Delta on watch:** leave unset for direct BLE in pass 1.
16. **Winner policy:** latest-write plus `minInterval: 5`; source attribution preserved for UI.
17. **UI palette:** keep 6-state palette with compact inline text.
18. **Active-name mid-session:** N/A (no iPhone-bridged filter in this pass).
19. **Attach ladder cadence:** single sweep then retry loop on timeout/failure.

## Deviations from references

- Backfill parsing not enabled yet (only discovery + skip logging) to keep pass focused on repeated live EGV.
- EGV parsing currently lightweight and intentionally conservative; full timestamp/activation math remains follow-up hardening.
- No phone-bridged exact-name filter in pass 1.

## Known risks / open test questions

- UUID/opcode and payload field offsets must be device-validated against real watch session traffic.
- Some watchOS sessions may require slightly different auth-observation gating before control writes are accepted.
- Without target membership wiring/build, compilation-level issues remain for Xcode follow-up.
