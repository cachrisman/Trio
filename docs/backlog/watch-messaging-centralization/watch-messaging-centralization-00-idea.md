# Backlog idea: Watch / phone messaging architecture centralization

**Version:** v1.6  
**Status:** Backlog (candidate feature)  
**Created:** 2026-04-06 17:41 CET  
**Last updated:** 2026-04-08 09:31 CET  

**Design:** [watch-messaging-centralization-01-design.md](../../in-progress/watch-messaging-centralization/watch-messaging-centralization-01-design.md)  
**Implementation plan:** [watch-messaging-centralization-02-implementation-plan.md](../../in-progress/watch-messaging-centralization/watch-messaging-centralization-02-implementation-plan.md)

### Document lifecycle (explicit)

- This file lives under **`docs/backlog/`** as a **candidate proposal** (problem, motivation, rough scope). It is **not** required to move into `docs/in-progress/` when design/plan work starts.
- The **active initiative artifacts** for this feature are **`watch-messaging-centralization-01-design.md`** and **`watch-messaging-centralization-02-implementation-plan.md`** in **`docs/in-progress/watch-messaging-centralization/`** (reviewed, versioned, changelog-driven).
- Keep this backlog doc **as context** until the feature is completed, superseded, or intentionally archived—do not treat it as a third “in-progress” artifact that must track every design bump.

### Traceability (depth — design/plan are authoritative)

This file stays **high level** on purpose. Subtlety that **does** matter for implementation lives in the **design** and **implementation plan**, including: **dedupe ownership** (transport vs domain vs complication store — design § **Dedupe and idempotency ownership**); **queue / execution-context verification** before relying on threading (design §3, plan **D1** / **E1**); **minimal fixture bar** + staged backfill before full decode coverage (plan **Task A2**, **Phase C**); **hard vs hygiene** checkpoints (plan § **Gate taxonomy**). Read those artifacts before scoping effort — the refactor is **not** only “centralize parsing.”

### Baseline pointer (non-regression boundary)

Detailed **git anchors, evidence, and preserved behaviors** for the shipped **watch connectivity background-task completion** work are recorded in the **design** (§ **Regression baseline**) and **implementation plan** (§ **Prerequisites** and **Regression boundaries**). This idea doc only restates the intent: refactors must **not** regress that behavior. If **`watch-launch-stability`** investigation artifacts are unavailable, the design’s **Baseline row** at implementation kickoff remains the anchor (see design § **Regression baseline**).

---

## Problem

Trio’s Apple Watch ↔ iPhone path uses **WatchConnectivity** across several transports (`sendMessage`, `transferUserInfo`, `transferCurrentComplicationUserInfo`, `updateApplicationContext`) and many **ad hoc `[String: Any]`** payloads. Message construction, parsing, deduplication, ACK handling, and side effects are **spread across large types** (notably phone-side `BaseWatchManager` in `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` and watch-side `WatchState` in `Trio Watch App Extension/WatchState.swift`), with helpers such as `WatchMessageKeys`, `WatchConnectivityPayloadIds`, `WatchLogger`, `WatchErrorReporter`, and complication storage in `Trio Watch Shared/TrioComplicationDataStore.swift`.

That spread makes it easy to introduce **inconsistent validation**, **transport drift** (using the wrong API for a payload family), and **fragile completion semantics**—especially on watchOS where background refresh tasks must align with **logical** processing completion, not a single delegate callback shape.

## Motivation

- **Safety and reliability:** Central definitions and validation reduce the chance of silent type mismatches, partial payloads, and divergent key strings between targets.
- **Maintainability:** A single inbound pipeline per platform clarifies where to add metrics, guards, and tests.
- **Explicit transports:** Apple’s APIs have materially different delivery, reachability, budget, and ordering semantics; the codebase should encode those policies deliberately instead of re-deriving them in scattered call sites.

## Why now

A **separate** watchOS issue (forced return to the clock face after ~seconds) had **multiple contributing mechanisms** in investigation (including **connectivity background-task completion** coupling and, separately, **memory / jetsam**—see [watch-launch-stability](../../in-progress/watch-launch-stability/) docs). The **connectivity completion** line of fixes is treated here as **already integrated** on the product path; **concrete commit anchors and evidence** for “what counts as fixed” are listed in the **design / plan baseline sections**, not in this backlog file. This initiative is the **architectural follow-up**: absorb the lesson structurally so future work does not reintroduce fragmentation.

Work under **`watch-launch-stability`** (startup load shedding, foreground memory hardening) and **complication freshness** continues in parallel; this idea is about the **messaging layer** that those efforts depend on, not replacing them.

## Non-goals

- **Not** a repeat of the narrow forced-closure bugfix; that behavior is a **preserved invariant**, not the primary deliverable here.
- **Not** collapsing all transports into one generic “send/receive” abstraction that hides `sendMessage` vs `transferUserInfo` vs `applicationContext` semantics.
- **Not** (initially) redesigning unrelated watch UI, HealthKit observers, or Garmin watch support (`GarminManager` / `GarminWatchState`) unless a later phase proves a shared contract is unavoidable.
- **Not** changing product-visible loop/pump behavior except through **bugfix-level** corrections discovered during consolidation.

## Rough proposal

1. **Shared contracts:** One obvious place for payload families (watch state snapshot, treatment requests, logs, error reports, snooze / notification actions, ACK metadata), keyed consistently with `WatchMessageKeys` (and any keys today only in string literals, e.g. `watchLogs`).
2. **Shared decode / validation:** Normalize bridging types (`String` / `NSString` / `NSNumber` / nested dictionaries) and reject invalid payloads in one layer per side, building on patterns like `WatchConnectivityPayloadIds`.
3. **Central inbound dispatch:** On iOS, route all `WCSessionDelegate` inbound paths through a single dispatcher that invokes typed handlers. On watchOS, the same for `didReceiveMessage`, `didReceiveUserInfo`, `didReceiveApplicationContext`, and related completion orchestration.
4. **Transport policy layer:** Small, explicit module(s) that decide *which* WC API to use for each logical message family (foreground vs background, complication budget, ACK expectations), separate from business logic.
5. **Typed sender APIs:** Watch-side extensions such as `WatchState+Requests` and phone-side send paths become thin facades over the policy layer.

## Top risks

- **Regression risk** against stabilized watch connectivity background completion, dedup, and early-return paths—especially `pendingConnectivityTasks` / deferred completion logic in watch `WatchState`.
- **Behavior drift** if validation tightens and accidentally rejects production-shaped payloads.
- **Schedule risk:** large file (`AppleWatchManager.swift`) refactors conflict with active complication / launch-stability work.

## Open questions

- Should **shared contracts** live in a new **shared framework / target** vs duplicated files in both targets (today `WatchMessageKeys` is iOS-side; watch uses the same keys via target membership—verify during Phase A).
- Whether **log** and **crash report** payloads should share one “telemetry envelope” type or remain distinct families with shared encoding rules only.
- How far to push **automated tests** (unit tests on pure decode vs device-only WC delegate tests).

## Relationship to the completed forced-closure bugfix

That fix corrected **when** connectivity background tasks complete relative to **logical** inbound processing across **multiple** inbound channels (`didReceiveUserInfo`, `didReceiveApplicationContext`, `didReceiveMessage`, late task delivery). This feature **presumes** that fix is deployed and treats its semantics as a **non-regression boundary** for any refactor.

## Relationship to `watch-complication-improvements` / complication freshness work

Complication delivery today uses **dedicated** WC surfaces (`transferCurrentComplicationUserInfo`, `transferUserInfo`, `updateApplicationContext`) plus `TrioComplicationDataStore` / `TrioComplicationSnapshot`. This initiative must **preserve** those semantics and budgets while making **policies and contracts** easier to reason about. It should **not** silently change complication freshness guarantees; coordinated sequencing with open complication initiatives is expected.

---

## Changelog

### v1.6 (2026-04-08 09:31 CET)
- **R1 (ChatGPT):** **Traceability** subsection — pointers to design/plan for **dedupe**, **queue verification**, **fixtures**, **gate taxonomy** (this backlog remains summary-level).

### v1.5 (2026-04-07 22:26 CET)
- **F3 (portability):** **Baseline pointer** — if **`watch-launch-stability`** is unavailable, **Baseline row** at kickoff is still the regression anchor (mirrors design § **Regression baseline** fallback).

### v1.4 (2026-04-07 14:25 CET)
- Pre-implementation doc review (prompt **03**): **Baseline pointer** now names design § **Regression baseline** and plan § **Prerequisites** / **Regression boundaries** explicitly.

### v1.3 (2026-04-07 10:50 CET)
- Review feedback: added **Document lifecycle** (backlog vs in-progress artifacts), **Baseline pointer** to design/plan, and clarified **Why now** so connectivity vs jetsam mechanisms are not conflated; pointed at `watch-launch-stability` for investigation context.

### v1.2 (2026-04-07 10:44 CET)
- Moved back to `docs/backlog/watch-messaging-centralization/`; status restored to **Backlog (candidate feature)**. Cross-links to design and implementation plan updated to relative paths into `docs/in-progress/watch-messaging-centralization/`.

### v1.1 (2026-04-06 17:48 CET)
- Moved from `docs/backlog/watch-messaging-centralization/` to `docs/in-progress/watch-messaging-centralization/`; file renamed with initiative prefix. Status set to **Draft** to match sibling artifacts; added links to design and implementation plan.

### v1.0 (2026-04-06 17:41 CET)
- Initial backlog idea: problem, motivation, proposal sketch, risks, open questions, and explicit separation from the already-shipped forced-closure bugfix.
