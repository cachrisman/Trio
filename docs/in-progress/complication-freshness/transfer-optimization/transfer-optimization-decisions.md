# Transfer Optimization — Decisions and Rejected Alternatives

**Version:** v1.0
**Created:** 2026-03-19 11:33 CET
**Last updated:** 2026-03-19 11:33 CET

This section documents deliberate choices to deviate from reviewer suggestions. Its purpose is to prevent the same feedback from being raised repeatedly and to give future reviewers the reasoning behind specific design decisions.

---

**R1b: Keep 1 transfer (not 2) as the post-drain target**

*Suggestion (ChatGPT critique #3):* Keep 2 transfers — "1 newest by readingEpoch, 1 newest by transferEnqueuedAt as fallback tie-breaker."

*Decision:* Keep exactly 1 — the newest by `transferEnqueuedAt` within the latest `readingEpoch`.

*Reasoning:* This is an engineering tradeoff, not a correctness claim. WatchConnectivity generally delivers `transferUserInfo` items in enqueue order within a session, but this is not a documented guarantee and cancellation/re-queuing can change the set. The argument for keeping 1 is: a second "hedge" item adds queue depth for a marginal and non-deterministic delivery benefit. If the single kept transfer fails to deliver (corrupt payload, session edge case), the next reading's transfer will be enqueued and will attempt delivery — the system self-heals within one CGM interval. The queue-depth observability benefit of keeping 1 (any `queue_depth > 2` clearly signals broken behaviour) outweighs the hedge value of keeping 2. If production telemetry shows the 1-item policy correlating with stale-complication incidents that a 2-item policy would have avoided, revisit this.

---

**R2b: Keep the (epoch, displayFields) gate rather than epoch-only**

*Suggestion (ChatGPT critique #2, partially):* Simplify the gate key to epoch alone to prevent all multi-sends per reading.

*Decision:* Gate on `(epoch, currentGlucose, trend, delta)` — same as `ComplicationSnapshotFingerprint` on the watch side.

*Reasoning:* An epoch-only gate would prevent a legitimate re-send when glucose display fields change within the same 5-minute window (e.g. a trend computation that completes 3s after the glucose value arrives). While this pattern does allow occasional 2x sends per reading, the watch-side `saveOnMain` dedup (FP-Phase 3.1) handles it if the fields haven't actually changed. The `(epoch, displayFields)` gate mirrors the existing fingerprint logic and creates a consistent dual-layer dedup. If the 2x pattern turns out to be the dominant budget drain, R2d (authoritative-source gating) is the correct fix — not collapsing to epoch-only, which would introduce a different correctness problem.

---

**R2d sequencing: gated on R2a data, not implemented speculatively**

*Suggestion (ChatGPT critique #3):* Treat the pipeline split as a near-prerequisite rather than a post-R2b option.

*Decision:* R2d ships only if avg C > 1.3 after 48h of R2b telemetry.

*Reasoning:* R2d requires knowing which sources are causing multi-C readings — that attribution data doesn't exist until R2a ships and accumulates. Implementing R2d speculatively (before R2a data) would require guessing the source allowlist, which could either under-restrict (allowlist too broad, no improvement) or over-restrict (allowlist too narrow, settings changes stop triggering complication updates at all). R2a is a low-risk instrumentation change; R2d is a behavioral change with UX consequences. The 48h observation window is the minimum viable evidence base. If R2b does hit the ≤1.3x target, R2d is unnecessary scope.

---

**R2d mode selection: "any eligible in window" vs "last source" vs "window-scoped eligible" — design history**

*v1.4 (original):* Mode = `complicationAndUI` if `coalescerSources.contains(where: { eligible.contains($0) })` — "any eligible source in window."

*Critique #3:* Too permissive — an IOB-only final wave still burns budget if a glucose event happened earlier in the same window.

*v1.5 correction:* Mode = `complicationAndUI` if `lastCoalescerSource ∈ eligible` — "last source."

*Critique #4:* Too strict — if `glucoseStored` fires then `iobUpdate` fires last in the same window, the last source is non-eligible and no complication transfer fires, even though a real glucose update arrived.

*v1.6 resolution:* Mode = `complicationAndUI` if `lastEligibleSourceAt >= coalescerFirstScheduledAt` — "any eligible source during this specific coalescer window." This is the correct predicate. `coalescerFirstScheduledAt` (already tracked) provides the window boundary. `lastEligibleSourceAt` is set in `scheduleWatchStateUpdate` when source ∈ eligible and cleared with the rest of the coalescer state. Both properties are snapshotted before clearing and passed into `sendDataToWatch`.

*Why this won't be raised again:* "Any in window" was always the intent. v1.5 introduced "last source" to solve the IOB-only misclassification, but overcorrected. The window-scoped check solves both problems by answering the correct question: "did a glucose-origin event happen during this window?"

---

## Changelog

### v1.0 (2026-03-19 11:33 CET)

- Extracted from complication-freshness-remediation-plan.md v1.56 during docs reorganization.
