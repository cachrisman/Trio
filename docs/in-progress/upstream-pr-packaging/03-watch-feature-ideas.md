# Watch feature ideas — what else is worth building

**Version:** 0.1 (for Charlie)
**Status:** In progress — companion to the upstream-PR planning
**Created:** 2026-06-11 06:00 CEST

Sources: the three backlog ideas, the shipped-initiatives inventory, and gaps observed across
builds 185–208. Each item: what, why it matters on a watch CGM app, effort, and how it relates
to the shipped observer. **Not a commitment list — a menu to prioritize against.**

---

## Tier 1 — high leverage, builds directly on what shipped

### 1. Battery / hot-path performance pass `[backlog: perf-optimizations]`
**What:** audit allocations and I/O on the always-on paths the observer added — `WatchLogger.log`
per-line file open/write/close, log volume/sampling, battery-context capture frequency, WC
transfer sizing. **Why it's now Tier 1:** the observer makes the watch run a continuous
`CBCentralManager` + extended-runtime sessions + higher log volume — battery is the scarcest
resource on a watch CGM, and the observer moved the worst case. Best value/effort ratio in the
whole backlog; build 208's telemetry ring already did the producer-side half, so this is the
consumer-side completion (daily-log batching) plus measurement. **Effort:** low–medium.
**Relation:** completes 208's observability-tax work; partially overlaps the old WC-efficiency
item (BLE reduced WC dependence for glucose, but logs/treatments/state still ride it).

### 2. Window-anchored / duty-cycled scanning (foreground-first) `[review 2.7, deferred]`
**What:** use the `reading_epoch` the adapter already tracks to arm scanning at `epoch−30s` and
idle between windows, instead of scan-always. **Why:** foreground battery + connect-politeness;
the expected-window timer infrastructure already exists. **Effort:** medium, design-sensitive
(the 186–192 scheduler history is a cautionary tale — "don't build a timer empire"). **Relation:**
gated behind the build-208 connection-event experiment's verdict — if event-driven waking works,
the whole arming model changes. **Re-evaluate after 208 soak, not before.**

### 3. Day-1 auth accommodation `[review 5.2]`
**What:** detect a confirmed `gate_passed=false` streak on a <24h sensor and switch to
window-anchored single attempts instead of continuous retry. **Why:** day-1 success is 13–17%;
nothing the watch does locally changes the transmitter's decision, but it can stop hammering.
**Effort:** low (the data exists; it's a policy on top of existing events). **Relation:** pairs
with #2; both are "present more politely" levers from the architectural-observations section.
**Caveat:** the cadence data shows no current storm — this is a contingency, tripwire-gated.

## Tier 2 — genuine user-facing features (net-new capability)

### 4. Notification-action complication refresh `[backlog: notif-complication-refresh, fully specced]`
**What:** use watch notification interactions (snooze/tap/dismiss) as a budget-free, deterministic
complication-refresh hook — phone attaches a snapshot to the notification userInfo; the watch
delegate writes the store + reloads the timeline. **Why:** a freshness path for users **not** on
the BLE observer (other CGMs, BLE disabled, observer failing). **Effort:** low (v1.2 spec exists,
narrow). **Relation:** its original motivation is *superseded on the BLE path* (the observer
already delivers minute-fresh complications), so its remaining value is strictly as a
**non-BLE fallback**. Revise the pre-observer spec before investing. **Honest take:** only worth
it if you care about the non-BLE-user population.

### 5. Standalone-watch resilience hardening
**What:** make the watch degrade gracefully through longer phone-absent stretches — the history
store (24h) already exists; this is about the UI/complication story when WC has been silent for
hours and only BLE/HK are feeding. **Why:** the observer's whole selling point is phone-independence;
this makes the failure modes graceful instead of cliff-edged. **Effort:** medium. **Relation:**
extends the freshness-gating work already in `TrioMainWatchView`.

### 6. Watch-side glucose alerting (opportunistic)
**What:** local high/low haptic alerts driven by the BLE reading when the phone is away — the one
thing a phone-relayed watch genuinely cannot do that an observer can. **Why:** this is the
*safety* payoff of having real-time glucose on the wrist independent of the phone. **Effort:**
medium–high (alert policy, dedup vs phone alerts, do-no-harm design — must not double-alert or
contradict the phone's loop). **Relation:** the highest-value *new* capability the observer
unlocks, but also the highest-scrutiny (it's an active safety feature, not a display feature).
**Flag:** there's an unverified "haptic beacon" idea in the tree that hooks `G7WatchSensorAdapter`
— check whether it overlaps before starting.

## Tier 3 — architectural, sequence carefully

### 7. Watch messaging centralization `[backlog + in-progress design v1.9, not implemented]`
**What:** consolidate the WC layer (typed contracts, one decode/validation path per side, explicit
transport-policy module). **Why:** it's the foundation everything else sits on; the ad-hoc
`[String:Any]` payloads are a growing liability. **Effort:** high, highest-risk (refactor of the
two largest watch files with explicit non-regression boundaries). **Relation:** **explicitly
deferred** — wrong time while a public PR is in flight; its Phase C gate blocks on the status of
branches touching `AppleWatchManager`/`WatchState`/`TrioComplicationDataStore`. Sequence **after**
the upstream PR lands or is declared. Its design also needs re-anchoring on the post-208 tree.

## What I'd actually pick, and why

If optimizing for **upstream credibility + user value with least risk**, in order:
1. **#1 battery pass** — finishes 208's work, directly addresses the reviewer "maintenance/battery"
   concern, low risk, immediately measurable.
2. **#6 watch-side alerting** — the real new capability the observer exists to enable; do it *after*
   the PR so it doesn't bloat the review, but it's the feature that makes the whole effort matter.
3. **#2/#3 politer scanning** — after the 208 connection-event verdict, which may reshape both.
4. Defer #4 (fallback-only value), #5 (incremental), #7 (refactor — wrong phase).

The honest meta-point: the observer is *shipped and working*. The highest-value next move isn't
another capture-rate lever (diminishing returns against the platform ceiling) — it's either
**spending the capability you now have** (#6 alerting) or **paying down its cost** (#1 battery).
Everything else is secondary.

## Open questions for Charlie

- Is there a known "haptic beacon" idea/branch? (#6 may overlap.)
- Do you care about the non-BLE-user population enough to justify #4?
- Watch-side alerting (#6): appetite for an active safety feature, or keep the watch display-only?

---

## Changelog

### v0.1 (2026-06-11)
- Initial menu: 7 ideas across 3 tiers, sourced from backlog + shipped inventory + 185–208 gaps;
  recommendation (battery pass → alerting → politer scanning → defer the rest).
