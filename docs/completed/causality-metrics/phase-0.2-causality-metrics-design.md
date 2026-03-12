## Updated design review note: Phase 0.2 reload→getTimeline causality and metrics reliability

**Version:** 1.2  
**Date:** 2026-03-05  
**Status:** Proposed (decision-quality; ready for implementation planning)

### Problem
We want Phase 0.2 observability to answer, with dashboard-quality reliability:

1) **Association:** Did WidgetKit run `getTimeline` *after* our app issued reload requests (vs system-driven refresh)?  
2) **Coalescing:** How much coalescing is happening (multiple reload requests collapsing into fewer provider executions)?  
3) **Latency (meaningful):** What is a meaningful "reload→provider execution latency" distribution, without pollution from provider runs that are not plausibly tied to a recent reload request?

**Key diagnosis:** the current metric
> `latency_seconds = now - newestReloadRequestEpochSeconds`

is **time since last recorded reload request at the time of provider execution**, not the time WidgetKit took to honor a specific reload. That distinction is the crux of misleading tail spikes.

### Context / current state
- Watch app logs `event=complication_reload_requested` and appends a reload request record (UUID + epoch seconds) to App Group state.
- Complication/provider logs `event=complication_get_timeline_called` and includes a "most recent reload" time and computed `latency_seconds`.
- Logs reach Better Stack via file drain; dashboards run on logs→metrics aggregates (high-cardinality labels like UUIDs are not viable).

### Constraints / requirements
- WidgetKit does **not** expose a definitive "reason" for `getTimeline` invocation.
- Multiple reload requests may be coalesced; system may invoke `getTimeline` without an app reload request.
- Better Stack dashboards operate over a metrics schema; avoid high-cardinality labels (UUIDs).
- Prefer minimal cross-process coordination: maintain "single writer" posture for App Group state where possible.
- Interpretability: percentiles/tails must reflect actionable behavior, not stale-correlation artifacts.

---

## Recommended decision
Implement **(A) reload generation + delta** and **(B) latency validity window** together, plus a small **context marker** so we can segment "notification tap / app-open" effects.

These solve different questions:
- Generation/delta answers: "was this provider run reload-associated?" and "how many reloads were coalesced?"
- Validity window answers: "is this time gap meaningful to treat as reload latency?"
- Context marker answers: "do certain entry paths correlate with worse tails/burstiness?"

---

## A) Monotonic reload generation counter

### Storage: App Group (durable)
Store these scalars in **App Group UserDefaults** (suite):

- `reload_generation: Int`
- `last_reload_request_epoch_seconds: Int` (epoch seconds; updated on each reload request)

**Important nuance:** App Group `UserDefaults` writes can be coalesced. In bursts, the "most recent persisted value" may briefly lag the in-memory increments. For our purposes, this is acceptable (we're not doing transactional accounting), but it means occasional "unexpected" `generation_delta` values during bursts may reflect write timing rather than true system behavior.

### On reload request (watch app)
- Read `reload_generation` from App Group.
- Increment: `reload_generation += 1`
- Persist it to App Group immediately.
- Persist `last_reload_request_epoch_seconds = nowEpochSeconds` immediately.
- Log: `event=complication_reload_requested reload_generation=<N> reload_requested_at_epoch_seconds=<now>`  
  (UUID may remain in raw logs for debugging, but must not be extracted into metrics labels.)

**Optional—but useful—debounce context:** include a low-cardinality reason tag (not UUID), e.g.:
- `reload_reason=save|manual|debug|other`

### On provider invocation (complication `getTimeline`)
- Read `reload_generation` and `last_reload_request_epoch_seconds` from App Group.
- Log: `event=complication_get_timeline_called observed_reload_generation=<N> ...`

### Provider-local "last seen" and delta (in memory)
Maintain:
- `last_seen_generation` (Int?) in provider process memory
- `provider_instance_id` (UUID) generated once per provider process lifetime (standard, not optional)

Compute and log:
- If `last_seen_generation` is set: `generation_delta = observed - last_seen`
- If `last_seen_generation` is nil (first call in this provider instance): log `provider_restart=true` and set `generation_delta = NULL` (or 0) for that first event; then set `last_seen_generation = observed`.

Update:
- `last_seen_generation = observed`

Log fields:
- `provider_instance_id=<uuidString>` (always)
- `provider_restart=true|false`
- `generation_delta=<int or -1/NULL>`

**Interpretation**
- `generation_delta == 0` → provider ran with no new reload requests since last provider call (likely system-driven)
- `generation_delta > 0` → provider ran after one or more reload requests (reload-associated)
- `generation_delta > 1` → coalescing occurred (multiple reloads before a provider run)

### Watch app restart handling (must verify)
**Requirement:** `reload_generation` and `last_reload_request_epoch_seconds` must be durably stored in App Group, not in-memory. Verify they survive watch app restarts and do not reset to 0 unexpectedly.

---

## B) Latency validity window (necessary component)

Even with generation deltas, a provider run with `generation_delta > 0` does not imply the time gap is meaningful "reload latency." For example, a reload request hours earlier still yields `generation_delta > 0` but should not be counted as "WidgetKit took hours to honor it."

### Define two quantities
1) **Association/coalescing**: `generation_delta` (always meaningful except restart artifact rows)  
2) **Latency**: meaningful only within a bounded window after a reload request, and only if we have a valid timestamp

### Implementation
At `getTimeline`, compute:

- If `last_reload_request_epoch_seconds` is missing/unset:  
  - `latency_valid=false`  
  - `latency_seconds = -1`  
  - (this covers fresh install / first run / upgrade scenarios)

- Else compute:
  - `time_since_last_reload_request_seconds = nowEpochSeconds - last_reload_request_epoch_seconds`
  - `latency_valid = (time_since_last_reload_request_seconds <= WINDOW)`
  - If `latency_valid=true`, emit `latency_seconds = time_since_last_reload_request_seconds`
  - Else set `latency_seconds=-1` (or omit from extraction)

**Suggested initial WINDOW:** 10–30 minutes (tune based on observed distributions).

### Dashboard rule
Latency percentiles (p50/p90/p95/p99) and tail counts (>60s, >300s) must be computed only over:
- `event=complication_get_timeline_called`
- `provider_restart=false`
- `latency_valid=true`

---

## C) Context marker (small tweak from external examples)
External reports suggest refresh behavior can vary by **execution context** (e.g., app-intent/background scene, or app-open path such as notification taps). Since you already observed "tap notification → slower complication update," add a low-cardinality context marker so you can segment tails.

### Proposed context marker logging
In the watch app (where you can observe entry paths), log events such as:
- `event=watch_opened_via_notification`
- `event=watch_opened_normally`

This does not need to be perfect. It should be "good enough" to answer: *do tails/burstiness correlate with this entry path?*

If you want it integrated into the Phase 0.2 pipeline, you can also attach a `recent_context` scalar in App Group (low-cardinality string) updated on app open, but that's optional. The simplest is just a log marker event and time-based correlation.

---

## Expected healthy steady-state distribution (baseline priors)
Not strict requirements—just priors to help evaluation:

- **Most reload-associated provider runs should have `generation_delta ≈ 1`.**
- **Occasional `generation_delta == 0`** should occur due to system-driven refreshes.
- **`generation_delta > 1`** should appear during bursts and is expected; Phase 1/2 aim to reduce its frequency.
- After implementing validity window, **latency tails** should reflect real "near-term after reload" scheduling, not hours-old correlations.

---

## Why this is the best tradeoff
- Works within WidgetKit limits (no reason API).
- Avoids UUID cardinality problems in logs→metrics.
- Avoids provider writes to App Group (safer cross-process design).
- Produces actionable signals:
  - reload-associated vs system-driven runs
  - coalescing intensity (delta distribution)
  - meaningful latency tails (validity-filtered)
  - ability to segment by lifecycle context (notification open vs normal)

---

## Alternatives considered and rejected

### A) Drain the UUID ring buffer in `getTimeline`, log UUID list, then clear it
Rejected: provider becomes cross-process writer/deleter; risk of losing evidence; unqueryable variable-length logs; incompatible with metrics extraction; still no definitive "winner" reload request.

### B) Use WidgetKit APIs to identify invocation reason and triggering reload
Rejected: no public API provides invocation reason or triggering reload identifier.

### C) "Validity window only" without generation/delta
Rejected as a full solution. Necessary but insufficient alone: it prevents chart pollution but cannot distinguish reload-associated vs system-driven provider runs or quantify coalescing.

### D) Extract UUIDs into metrics labels for joins/match rate
Rejected: high cardinality; not viable in logs→metrics dashboards.

### E) Provider writes acknowledgements back to App Group ("ack last processed reload")
Rejected: adds provider writes to shared state; increases race/coordination risk; still not definitive for invocation reason.

---

## Risks / open questions
1) **App Group UserDefaults coalescing during bursts**  
   - May cause short-lived divergence between in-memory increment patterns and persisted values, potentially yielding occasional `delta=0` where you expected `>0` during intense bursts.  
   - Mitigation: accept as non-transactional; rely on trends/distributions.

2) **Choosing WINDOW**  
   - Too small drops legitimate delayed reload-associated calls; too large reintroduces stale correlation.  
   - Mitigation: start 10–30 min; tune.

3) **Provider restart artifacts**  
   - Mitigation: `provider_restart=true` on first call, plus standard `provider_instance_id`.

4) **Watch app restart semantics**  
   - Must verify persistence of generation + epoch scalar in App Group.

5) **UUID ring buffer lifecycle**  
   - Keep temporarily as transition sanity check; plan to remove once generation/delta is validated through a full evaluation cycle.

---

## Success criteria
- Latency percentiles/tails stop being dominated by stale-hour spikes (after validity gating).
- Dashboard can report:
  - % provider runs with `generation_delta == 0` vs `>0`
  - delta distribution (coalescing intensity)
  - valid-latency p50/p90/p95/p99 and tail rates (>60s, >300s), filtered to `latency_valid=true` and `provider_restart=false`
- Phase changes (esp. 1/2) shift expected metrics:
  - reload volume and burstiness down
  - delta distribution shifts toward 1
  - valid tail rates down or stable

---

## Minimal implementation notes (to feed an implementation plan)
- Watch app (App Group writes):
  - `reload_generation` increment + persist
  - `last_reload_request_epoch_seconds` persist
- Provider logs:
  - `provider_instance_id` (standard)
  - `provider_restart`
  - `observed_reload_generation`
  - `generation_delta`
  - `latency_valid`
  - `latency_seconds` (only meaningful when valid)
- Better Stack extraction:
  - generation_delta metric (avg/max + buckets if desired)
  - provider_restart label/metric
  - latency_valid label/metric
  - latency_seconds metric extracted only when latency_valid=true

---

## Changelog
| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-03-05 | Initial decision note: problem framing, constraints, recommended generation counter + validity window, alternatives, risks, success criteria. |
| 1.1 | 2026-03-05 | Clarified validity window as required component; added provider restart mitigation; added watch app restart persistence verification; plan to keep UUID ring temporarily then remove. |
| 1.2 | 2026-03-05 | Added App Group UserDefaults coalescing nuance; made provider_instance_id standard; defined behavior when last_reload_request_epoch_seconds absent; added baseline priors for generation_delta distribution; added context-marker suggestion (notification/app-open segmentation). |
