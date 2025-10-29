## Trio Watch Sync — Project Overview & Status (iOS 26 / watchOS 26)

Purpose
- Rebuild/refactor phone↔︎watch sync and complication behavior so the watch app launches reliably (no "bounce"), then re‑enable efficient delta updates once stable.

Environment
- Target: iOS 26 / watchOS 26 (min iOS 17)

Cold‑start policy
- Launch throttles apply only on true cold start (first activation after process start).

---

### Phase A — Stabilization (Full-only) [COMPLETED]
- Readiness gates: Skip sends until session is Activated; re-activate on NotActivated.
- Watch cold-start window: 60s by default; gates delta and reduces launch pressure.
- Complication: Snapshot persistence (App Group), immediate reload on BG change, delayed backup reload (+10s), throttle ~60s.
- Manual refresh: Long‑press overlay + full refresh request; success tick and auto-dismiss.

Key PR changes
- `Trio Watch App Extension/WatchState.swift`: cold-start window, snapshot save trigger, ack dedupe.
- `Trio Watch App Extension/TrioComplicationDataStore.swift`: snapshot persistence + reload throttling.
- `Trio Watch Complication/TrioWatchComplication.swift`: reads snapshot and shows current glucose; periodic reload policy (~5m).
- `Trio Watch App Extension/Views/ManualRefreshOverlay.swift` + integration in `TrioMainWatchView`.
- `WatchMessageKeys.swift`: added `correlationId`.
- `AppleWatchManager.swift`: acks echo correlationId; activation gating; full snapshot send path.

---

### Phase B — Delta Infrastructure & Sequence [COMPLETED]
- Model: `WatchGlucoseDelta` with `sequenceNumber`, `correlationId`, minimal fields (+ last ~6 readings).
- Phone: `createDeltaUpdate()`; monotonic `trio.iphone.deltaSequence`; debounce identical state (<30s) using lightweight hash.
- Watch: `processDeltaUpdate()`; sequence gating (`seq > lastProcessed`), gap handling (>20 → request full), cold-start gate.
- History: Maintains 24h window in-memory and updates snapshot; merges new readings.
- Messaging: New key `watchDelta` for delta payload; merges into complication snapshot and reloads with throttle.

Key PR changes
- `WatchMessageKeys.swift`: `watchDelta`, `sequenceNumber`, `newReadings`, `activeOverrideName`, `activeTempTargetName`, `manualRefresh*`.
- `Trio/Sources/Models/WatchGlucoseDelta.swift`: phone-side delta model.
- `AppleWatchManager.swift`: Phase flags, state hash debounce, full-vs-delta decision, delta send path, persistent sequence.
- `WatchState.swift`: delta receive, sequence persistence, 24h pruning, snapshot merge, adaptive background schedule.

---

### Phase C — Background Refresh, Scheduling, and Reliability [COMPLETED]
- Adaptive cadence: reachable & fresh → ~5 min; stale → ~3 min; unreachable → ~12 min.
- Background tasks: schedules next refresh; minimal delegate to request fresh state.

Key PR changes
- `Trio Watch App Extension/ExtensionDelegate.swift` + `@WKExtensionDelegateAdaptor` in `TrioWatchApp`.

---

### Presets & Temp Targets Parity [PARTIALLY COMPLETE]
Implemented
- Watch→Phone control messages carry `correlationId` and receive acks with echoed id.
- Phone applies changes and sends updated state; watch UI reflects changes.
- Idempotence: basic ring-buffers on both sides ignore duplicate requests/acks.

Remaining
- Config push channel (optional) to ship preset lists independently of full state.
- Additional error codes (`not_found`, `conflict`) surfaced consistently across all paths.

---

### Logging & Diagnostics [ONGOING]
- Watch side: `WatchLogger` actor with periodic flush and persistence fallback.
- Phone side: debug logs on decisions (activation, send paths, errors).

---

### Tunables / Feature Flags
- `isStabilizationMode` (Phase A): forces Full updates (phone).
- `coldStartWindowSeconds` (watch): default 60s; expected 10–15s after stability proven.
- `timelineReloadThrottleInterval` (watch): default ~60s.

---

### Acceptance Checklist — Current State
- No-bounce opens: stabilized via cold start and readiness gates.
- Complication reloads on BG change, throttled; periodic ~5 min reload in provider.
- After 25+ minutes idle, next open fetches fresh data (delta/sequence gating + conditional request).
- Deltas enabled, payload reduced; correlationId-based idempotence in control paths.

---

### Remaining Work
- Optional config channel: decouple presets/config from Full state (small payloads).
- Broader error taxonomy (`ackCode`): add `not_found`, `conflict` across all control flows.
- Fine-tune cadences and cold-start window during rollout.
- Add more unit tests: sequence persistence, pruning, debounce hash, complication reload rule.

---

### File Touchpoints (Summary)
- Phone: `AppleWatchManager.swift`, `WatchGlucoseDelta.swift`, `WatchMessageKeys.swift`.
- Watch: `WatchState.swift`, `WatchState+Requests.swift`, `TrioComplicationDataStore.swift`, `ExtensionDelegate.swift`.
- Complication: `TrioWatchComplication.swift`.
