# Watch G7 Direct BLE Observer — Design v1

## Mission and premise
Implement a watch-only Dexcom G7 observer path that attaches to the same-device BLE session owned by the official Dexcom G7 watch app, requests EGV payloads on Trio's own control characteristic channel, and persists readings into the existing watch complication snapshot pipeline.

## Reference validation status
The required raw GitHub URL fetches were attempted first using `curl -fsSL` for all listed DiaBLE and G7SensorKit files, but this environment returned HTTP 403 for every URL. Because of that, implementation relied on already-known Dexcom G7 UUID/opcode conventions and baseline Trio architecture, and logs this as the top empirical risk.

## Protocol sequence implemented
1. Eager restoration-backed `CBCentralManager` allocated at process init.
2. On scene `.active`, attempt attach via `retrieveConnectedPeripherals(withServices: [data-service])`, then scan fallback.
3. Connect candidate and discover services/characteristics using broad discovery (`nil`).
4. Enable auth notify; explicitly skip J-PAKE and log skip.
5. Enable control notify.
6. Observe auth traffic (no auth writes), then send EGV request opcode on control write channel.
7. Parse control notifications into EGV, trend, readingDate, delta; save into `TrioComplicationDataStore` with source attribution.

## Discovery / attach strategy
- Order: connected-service retrieval first, then broad scan.
- Rationale: fast-path attached peripherals first, with scan fallback for cases where retrieval misses or cache is stale.
- Connect `source=` tags are emitted (`retrieved_data_service`, `scan`).

## Filtering approach
- Chosen: DiaBLE-style standalone tolerant matching by peripheral name/advertisement patterns (Dexcom/DXCM/FEBC hints).
- Rationale: avoids iPhone dependency and keeps observer self-contained for watch-only attach reliability.

## Auth advance condition + request cadence
- Advance condition: any auth payload observed marks link auth-ready for observer sends.
- EGV request cadence: on auth payload + recurring 5-minute timer while connected.
- Rationale: avoids over-strict auth-state gating stalls and targets sustained reads over time.

## Reconnect policy
- Automatic reconnect with bounded exponential backoff (2s→20s), reset on connect.
- No scene-gated hard stop; inactive/background transitions do not forcibly tear down a healthy link.

## Scene/lifecycle model
- Start on foreground active.
- Inactive/background only updates scene activity marker; no proactive BLE teardown.
- Explicit `stop()` remains available and is not scene-wired.

## UI indicator design
- Existing recency line is augmented to include source + BLE status + last direct BLE event age.
- Format: `"<recency> · <source> · BLE:<status> · <heartbeat>"`.
- Source labels: `Phone`, `HK`, `BLE`, `?`.

## Source attribution model
- New `TrioComplicationDataSource` enum added in shared watch code.
- `TrioComplicationSnapshot` extended with optional `source`.
- WatchConnectivity saves as `.watchConnectivity`, HK saves as `.healthKit`, direct observer saves as `.directBLE`.

## Observability plan
- Structured `event=g7_ble_*` logs include state transitions, scan/connect attempts, peripheral discovery details, characteristic setup, auth payload receipt, EGV request sends, control payload handling, snapshot saves, and reconnect scheduling.
- Logging helper forwards call-site file/line/function through `WatchLogger`.

## Design question decisions
1. Filtering: standalone tolerant matching — fewer dependencies.
2. Attach strategy: retrieveConnected(data service) then scan — fast attach + robust fallback.
3. Discovery breadth: broad (`nil`) discovery — reduces risk of missing required chars.
4. Timeout/backoff: 12s scan timeout, 2→20s reconnect — practical aggressive retry.
5. Central queue: main queue (`queue:nil`) plus MainActor model interactions.
6. Restoration: enabled with restore identifier + restore-state logging.
7. Connect options: notify-on-disconnect enabled.
8. Auth advance: first auth payload gates readiness (looser to avoid deadlock).
9. Request cadence: auth-event + 5-minute periodic timer.
10. Control write failure: log + reconnect schedule.
11. Backfill: discovered/logged as skipped in this pass.
12. Stop scanning after connect: yes.
13. Multi-peripheral disambiguation: first passing candidate wins.
14. Identifier persistence: none in this pass.
15. Delta computation: local from previous direct-BLE glucose.
16. Winner policy: existing store dedup + source tagging (no extra arbitration layer).
17. UI palette: six-state compact text (`off/search/conn/active/stall/na`) + heartbeat age.
18. Active-name filter changes: not applicable (no iPhone-bridged filter).
19. Attach-ladder cadence: single-sweep with reconnect loop.

## Known risks / device-test questions
- Required external reference files were inaccessible from this environment (HTTP 403), so parser/auth nuances may need device calibration.
- EGV payload decode offsets are best-effort and require watch-on-device validation.
- Backfill is currently non-active (log-only skip).
