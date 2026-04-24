# Design: Watch / phone messaging architecture centralization

**Version:** v1.9  
**Status:** Draft  
**Created:** 2026-04-06 17:41 CET  
**Last updated:** 2026-04-08 09:31 CET  

**Idea (backlog):** [watch-messaging-centralization-00-idea.md](../../backlog/watch-messaging-centralization/watch-messaging-centralization-00-idea.md)  
**Implementation plan:** [watch-messaging-centralization-02-implementation-plan.md](watch-messaging-centralization-02-implementation-plan.md)  
**Related initiatives (context, not scope substitutes):** [watch-launch-stability](../watch-launch-stability/) (startup load, connectivity background semantics, memory), complication freshness / `watch-complication-improvements` branch work as applicable.

---

## Positioning (explicit)

This is a **follow-up architectural** feature to **simplify and harden** watch ↔ phone messaging. It is **not** the narrow watchOS **forced-closure** bugfix; that fix is **already shipped** and verified. This design treats the corrected **background connectivity task completion** behavior as a **behavioral invariant** that any consolidation **must preserve**.

---

## Regression baseline (connectivity completion — “must not regress” anchor)

This initiative’s **non-regression boundary** is the **watch connectivity background-task completion state machine** and **multi-channel inbound** handling: `WKWatchConnectivityRefreshBackgroundTask` work must complete in line with **logical** processing (including deferred / quiet-window paths), across **`didReceiveUserInfo`**, **`didReceiveApplicationContext`**, and **`didReceiveMessage`** (see § “Forced-closure fix: preserved invariants” below).

**Scope note:** Investigation documents under [watch-launch-stability](../watch-launch-stability/) also cover **memory / jetsam** and other launch-stability tracks. Those are **related product symptoms** but **not identical** to this design’s WC completion baseline. Do not conflate **Path B / chart lazy-load / TestFlight 152** validation with the **connectivity-task commit series** below—they address different failure mechanisms.

### Documented git anchors (connectivity-task series)

The fork’s investigation record lists first-parent commits on the watch workstream that introduced and refined **terminal-path-aware connectivity task completion** and follow-on wake handling:

| Commit (short) | Date       | Summary (from investigation doc) |
|----------------|------------|----------------------------------|
| `07175b577`    | 2026-03-30 | Terminal-path-aware connectivity task completion |
| `58f706a0f`    | 2026-03-30 | Deferred retry logic around connectivity completion |
| `fdd94106b`    | 2026-03-31 | Confirm-only connectivity wake handling adjustments |

**Source:** [watch-launch-stability/00-investigation-findings.md](../watch-launch-stability/00-investigation-findings.md) § “Repo history / commit review” and consolidated timeline.

### Code anchors (always re-verify in-tree)

- `Trio Watch App Extension/WatchState.swift` — `pendingConnectivityTasks`, deferred completion / quiet-window finalization, inbound `WCSessionDelegate` paths.
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — phone inbound `WCSessionDelegate` paths, ACK / dedup behavior tied to the same wire protocol.

### Evidence (operational)

- Better Stack / query notes and completion-path observations around the Mar **2026** connectivity-task rollout are summarized in [00-investigation-findings.md](../watch-launch-stability/00-investigation-findings.md) § “Better Stack evidence” and the consolidated timeline.

### Record at implementation kickoff (mandatory)

Before merging refactors, the **implementation log** must add a single **Baseline row** with at least:

- **Branch name(s)** and **`git rev-parse HEAD`** (and merge-base to `dev` / upstream if using a feature branch).
- **Fork patch context** if applicable: whether `./patches/` were applied on top of `dev` for validation (per fork workflow), or whether validation used a feature branch only.
- **Build / TestFlight identifier** used for soak (if any).
- **Pointer** to soak notes or log queries used to prove “no regression” for this change set.

If the product line has moved since the Mar **2026** commit table, the baseline row **supersedes** the table for “what we tested against,” but the **invariants** in this doc remain unchanged.

**Fallback if investigation artifacts are unavailable:** If linked **`watch-launch-stability`** materials are **missing**, **stale**, or **not reviewed** alongside this feature, the **implementation kickoff Baseline row** (§ **Record at implementation kickoff** above) is the **operative anchor** for regression comparison, together with the invariants in § **Forced-closure fix: preserved invariants**; the git table above is **context** when present, not a substitute for the recorded baseline.

---

## Problem

- **Duplicated and scattered contracts:** Keys are partially centralized in `WatchMessageKeys` (`Trio/Sources/Models/WatchMessageKeys.swift`), but inbound code also uses **literal keys** (e.g. `watchLogs`, `complicationLastValidTimestamp` in `BaseWatchManager`). Payload shapes are implied by usage, not declared in one place.
- **Inbound logic sprawl:** Phone-side `BaseWatchManager` (`AppleWatchManager.swift` — file name is historical; the type is `BaseWatchManager`) implements `WCSessionDelegate` with multiple entry points (`didReceiveMessage` with/without `replyHandler`, `didReceiveUserInfo`, `didReceiveApplicationContext`, activation/reachability). Watch-side `WatchState` mirrors this with additional **background task** orchestration.
- **Transport semantics are easy to misuse:** The codebase correctly uses **multiple** APIs for watch state / complication snapshots (`sendMessage`, `transferCurrentComplicationUserInfo`, `transferUserInfo`, `updateApplicationContext`) with intentional ordering and budgeting comments. Without an explicit **policy layer**, new code can pick the wrong transport.
- **Type bridging fragility:** `WatchConnectivityPayloadIds` (`Trio Watch App Extension/WatchConnectivityPayloadIds.swift`) already exists to normalize ID types; similar bridging issues likely recur for other fields unless validation is centralized.

---

## Context / current state (grounded inventory)

### Targets and primary types

| Area | Location (representative) | Role |
|------|---------------------------|------|
| Phone WC manager | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — `final class BaseWatchManager: WCSessionDelegate` | Session lifecycle, outbound watch state / complication multi-path send, inbound messages / userInfo / applicationContext, ACK batching, dedup (`processedIds` / `pendingAcks`), settings-driven updates |
| Phone DI | `Trio/Sources/Assemblies/ServiceAssembly.swift` — `WatchManager` → `BaseWatchManager` | Injection surface is `WatchManager` protocol |
| Phone domain model | `Trio/Sources/Models/WatchState.swift` — `struct WatchState` | Codable snapshot shape for UI / encoding to watch |
| Keys | `Trio/Sources/Models/WatchMessageKeys.swift` | String constants for payload keys |
| Watch WC + UI state | `Trio Watch App Extension/WatchState.swift` — `@Observable class WatchState: WCSessionDelegate` | **Different type** from phone `WatchState` struct; owns session, inbound merge, **pendingConnectivityTasks**, deferred completion, HealthKit, startup gating |
| Watch outbound requests | `Trio Watch App Extension/WatchState+Requests.swift` | `sendMessage` for bolus/carbs/overrides/temp targets / bolus recommendation / state refresh |
| Watch logs | `Trio Watch App Extension/WatchLogger.swift` | Buffered logs, flush timer, `sendMessage` with reply/error gate, persistence, interaction with `WatchStartupTransportGate` |
| Watch errors / crash hints | `Trio Watch App Extension/WatchErrorReporter.swift` | Forwards structured dictionaries toward phone / Crashlytics path |
| Notification actions | `Trio Watch App Extension/Helper/WatchNotificationHandler.swift` | Snooze → `sendMessage` with `transferUserInfo` fallback |
| Complication storage | `Trio Watch Shared/TrioComplicationDataStore.swift` | Snapshot schema `TrioComplicationSnapshot`, dedup, App Group persistence |
| Extension lifecycle | `Trio Watch App Extension/ExtensionDelegate.swift` | Forwards background tasks to `WatchState.handleBackgroundTasks` |

### Payload / transport families (non-exhaustive; Phase A must confirm)

- **Watch state snapshot:** Nested under `WatchMessageKeys.watchState`; sent via multiple transports from phone; received on watch via `didReceiveMessage`, `didReceiveUserInfo`, `didReceiveApplicationContext` (see inline comments in code for R4/R5 series requirements).
- **Treatment / therapy requests:** Bolus, carbs, overrides, temp targets, bolus recommendation — primarily watch-initiated `sendMessage` (`WatchState+Requests`).
- **ACKs / dedup metadata:** Phone sends ACK messages; both sides track payload IDs — uses `WatchConnectivityPayloadIds` on watch; phone maintains processed ID LRU and pending ack storage (keys in `BaseWatchManager`).
- **Watch logs:** `watchLogs` string payloads and related handling branches in `BaseWatchManager` (including explicit comments about **not** sending certain reverse transfers for this family).
- **Error / crash reporting:** `WatchErrorReporter` builds dictionaries forwarded to phone.
- **Notification snooze:** `WatchMessageKeys.snoozeDuration` via `sendMessage` or `transferUserInfo` (`WatchNotificationHandler`).
- **Complication timeline / snapshot side paths:** `TrioComplicationDataStore`, `WidgetCenter` reloads — coordinate with WC deliveries but are not identical to WC.

#### Error / crash reporting family (implementation phase scope)

Centralized **decode** (implementation plan Phase C) and **dispatch** (Phase D) for the **error / crash-report** family are **not** required in the **first** shipping slice **provided** (1) existing **inline** code paths remain **behavior-identical** until migrated, and (2) any deferral is **recorded** in the implementation log with a **named follow-up phase**. If not deferred, apply the same verification bar as other inbound families. **Silent omission** without a log entry is **not allowed**.

**Uncertainty:** Garmin-related watch plumbing (`GarminManager`, `GarminWatchState`) may share concepts but is **not** fully inventoried here; Phase A should list whether any WC-shaped payloads overlap.

---

## Constraints / requirements

### Functional

- **Preserve shipped connectivity completion semantics:** Watch **background connectivity** work (`WKWatchConnectivityRefreshBackgroundTask`) must complete only after **logical** processing of inbound work finishes, including paths that finalize through timers / deferred work — matching the intent documented in `WatchState` (`pendingConnectivityTasks`, deferred completion, quiet-window finalize). **Non-userInfo** inbound paths (`didReceiveMessage`, `didReceiveApplicationContext`) must **not** strand tasks or complete too early relative to processing.
- **No false universal abstraction:** Keep **explicit** transport choice per family; document semantics (reachability, queuing, complication budget, last-writer behavior for `applicationContext`).
- **Backward compatibility:** Assume mixed versions in the field during rollout; Phase planning must allow **dual-read** or **tolerant decode** where needed.
- **Observability:** Retain or improve structured debug categories (e.g. `debug(.watchManager, ...)`, `WatchLogger` lines) around dispatch boundaries—centralization should make logs **more** consistent, not noisier.

### Non-functional

- **Risk control:** Prefer incremental extraction over a single mega-PR that rewrites all delegates.
- **Performance:** Avoid extra copies of large glucose arrays; validation should be **zero-copy** where feasible (e.g. validate keys then pass references).

---

## Decision: recommended target architecture

### 1) Shared message definitions

- Introduce **typed envelopes** per logical family (e.g. `WatchStateEnvelope`, `TreatmentRequestEnvelope`, `WatchLogEnvelope`, `SnoozeEnvelope`, `ErrorReportEnvelope`) even if the wire form remains dictionary-based initially.
- **Single registry** of keys: extend `WatchMessageKeys` or replace with generated / audited enum-backed keys; eliminate stray literals where possible.
- **Target placement:** Record whether shared types live in a **new shared framework**, **duplicated files**, or an **existing shared target** per implementation plan **Task A3** — **before** Phase B envelope work begins.

### 2) Shared decode / validation layer

- Per-side `WatchInboundDecoder` (name illustrative) that:
  - normalizes bridging types,
  - validates required fields per envelope,
  - returns **discriminated results** (known family vs unknown / ignored),
  - logs **structured** reject reasons (rate-limited in production if needed).
- **Tolerant decode:** Maintain **dual-read** fallbacks for legacy wire shapes; record the mapping in the implementation log. **Prior-format** acceptance tests use **fixtures** from implementation plan **Task A2** (Better Stack / staging, **no PHI**) under a **minimal bar** plus **staged backfill** so telemetry gaps do not stall architecture work. **New** rejection paths roll out with **log-only** soak first when they did not exist in prior inline logic (see implementation plan Phase C for **flag exit** and **Task G1** removal).

### 3) Central inbound dispatcher (per platform)

- **Phone:** Inbound **payload** delegate methods become thin — parse → dispatch → handler returns a **completion contract** (e.g. “ACK required”, “reply required”, “none”). The **outer** `BaseWatchManager` layer **enforces** the contract (e.g. dispatches ACKs for **ACK-required** families, satisfies `replyHandler` for **reply-required** paths) so dispatcher logic does not bypass the owner’s **threading / queueing** rules. **Callback execution context** (which queue(s) `WCSession` uses for inbound work, documented `MainActor` hops, etc.) **must be verified in-tree and recorded** in the implementation plan **Phase D1** **queue contract** **before** implementation treats any threading model as settled — this design **does not** assert Apple’s queue behavior as a fact here. Typed contracts and device acceptance (including **batched ACK** scripts) are specified in the implementation plan (Phase D1 / E1).
- **Watch:** `WatchState` session methods delegate to a dispatcher that coordinates with **existing** `finalizePendingData`, complication save, and **background task** completion policy **without** duplicating completion rules in each callback. The implementation plan **Phase E1** extends the **queue contract** (with **D1**) for **`pendingConnectivityTasks`** safety — **verify and record** watch-side execution context the same way (no assumed queue model in this doc).

#### Inbound dispatch scope (what must vs must not go through the inbound dispatcher)

**Must route through the inbound dispatcher (end state):** methods that deliver **inbound payloads** — on iOS today this includes `session(_:didReceiveMessage:replyHandler:)`, `session(_:didReceiveMessage:)`, `session(_:didReceiveUserInfo:)`, `session(_:didReceiveApplicationContext:)` (see `BaseWatchManager` in `AppleWatchManager.swift`). **Watch:** the corresponding `didReceive*` methods on watch `WatchState`.

**Not required to live inside the inbound dispatcher module:** **session lifecycle / reachability** callbacks that do not parse an inbound payload — e.g. `activationDidCompleteWith`, `sessionReachabilityDidChange`, `sessionDidBecomeInactive`, `sessionDidDeactivate` (phone has these patterns today). They may stay in the session owner type and call **outbound policy** or **send** helpers directly; they are a **different concern** than inbound message dispatch. Refactors must **not** accidentally move completion semantics for background tasks into these hooks.

This distinction is what makes “one dispatcher module per side” consistent with the actual `WCSessionDelegate` surface.

#### Dedupe and idempotency ownership (end state)

- **Wire / transport-level dedupe** (payload IDs, processed-ID LRU, pending ACK bookkeeping, “already seen this wire message”): Stays with the **session owner** types that own those structures today (`BaseWatchManager` on phone; watch-side mirrored ID / ACK state). The **inbound dispatcher** routes by **family**; the **outer session layer** continues to **enforce** transport idempotency and ACK side effects so **early-return** paths stay **completion-correct** (see **Regression baseline**). Splitting ID tracking across modules requires an explicit **implementation log** decision.
- **Family-specific / domain idempotency** (e.g. therapy actions keyed by a domain identifier): Remains in **domain handlers** behind dispatch; the decoder validates **shape**, not business replay policy.
- **Complication snapshot / App Group persistence dedupe:** Remains in **`TrioComplicationDataStore`** / `TrioComplicationSnapshot` — the messaging layer **passes through** validated slices and **does not** re-implement timeline or snapshot dedupe at the WC boundary.

### 4) Transport policy layer

- Explicit module or `enum` grouping: `WatchTransportPolicy.sendWatchState(…)`, `WatchTransportPolicy.sendSnooze(…)`, etc., encapsulating the **current** good behavior (sendMessage + complication transfer + userInfo queue + applicationContext safety net) as documented in phone code comments today.

#### Transport policy and `WatchStartupTransportGate`

**`WatchStartupTransportGate`** (watch extension; see inventory) constrains **early outbound** traffic (e.g. log flush / transport suppression). When **Phase F** introduces **`WatchTransportPolicy`** on watch, adopt **one** explicit strategy and **record it by end of Phase A** (implementation plan **Task A1**): **`delegate`** — policy APIs **call through** or otherwise **preserve** the gate so suppression semantics stay in one owner; or **`subsume`** — gate rules are **folded into** policy behind a short **parity checklist** (startup suppression, flush timing) proven in plan **Task F2** acceptance. **Both** are acceptable; **silent bypass** of gate semantics **without** a logged **`delegate` / `subsume`** choice is **not**.

### 5) Typed sender APIs

- Watch: `WatchState+Requests` calls into policy layer instead of building raw dictionaries inline.
- Phone: outbound watch state updates route through policy layer from `scheduleWatchStateUpdate` / coalescer paths.

### What stays separate (and why)

- **UIKit / SwiftUI / Core Data** concerns remain outside the dispatcher.
- **Complication snapshot sanitization** stays in `TrioComplicationSnapshot` / data store; the messaging layer passes **through** validated slices, not re-sanitizing display strings at the WC boundary.
- **Garmin** integration remains isolated unless inventory proves shared wire format.

---

## Forced-closure fix: preserved invariants (regression boundaries)

Any refactor **must not** regress:

1. **Logical completion coupling:** Completing `WKWatchConnectivityRefreshBackgroundTask` instances must remain tied to **logical** inbound processing completion, not to “whichever callback fired first” in a way that drops work.
2. **Multi-channel inbound parity:** `didReceiveUserInfo`, `didReceiveApplicationContext`, and `didReceiveMessage` paths must all participate in the **same** completion rules where applicable (including **late task** rescue behavior documented in `WatchState`).
3. **Early returns:** Dedup, invalid payload, or “already processed” paths must **still** run the **same** completion / terminal markers so tasks do not remain pending indefinitely.
4. **Deferred / quiet-window finalize:** Timer-based finalization that drains pending connectivity tasks must remain correct under bursty `userInfo` delivery.

---

## Functional behavior expectations

- **No user-visible regression** in bolus/carbs flows, snooze actions, complication freshness (within existing budget constraints), or log upload behavior.
- **Unknown payloads:** Continue to be safe to ignore or log without crashing; central decoder should not tighten this accidentally.
- **ACK behavior:** Preserve phone ↔ watch ACK semantics for batched and single messages, including branches that use `replyHandler`.

---

## Edge cases / failure modes / reliability

- **Reachability flaps:** Policy layer must preserve today’s `sendMessage` vs queued transfer fallbacks (e.g. snooze handler).
- **Budget exhaustion:** Complication transfer gating and `applicationContext` safety net must remain explicit policy decisions.
- **Malformed types:** Bridge mismatches (`NSNumber` where `String` expected) should fail **validation** without poisoning dedup state.

---

## Observability expectations

- Add **stable event names** at dispatcher boundaries using the **canonical schema** below (extend `debug(.watchManager, ...)`, `WatchLogger`, or structured logs consistently).
- Maintain correlation fields already in use (`reading_epoch`, window counters, pending task counts) — centralization should not remove them.

### Canonical observability schema (v1 — converge during implementation)

Use these **event** names (string payloads / key=value lines) at the boundaries called out in the implementation plan. **Required fields** should appear when applicable; use `n/a` or omit only when truly unavailable.

| Event | When to emit | Required fields (when applicable) |
|-------|----------------|-----------------------------------|
| `event=wc_inbound_received` | Entry to inbound path (per `WCSessionDelegate` callback) | `transport` (`message` \| `userInfo` \| `applicationContext`), `activation_state`, `reachable` (phone/watch as available) |
| `event=wc_decode_result` | After decode/validation | `family` (logical enum name), `ok` (`true`/`false`), `reject_reason` (if `ok=false`) |
| `event=wc_dispatch_started` | Dispatcher begins routing to a handler | `family`, `transport` |
| `event=wc_dispatch_completed` | Handler finished (success or controlled no-op) | `family`, `transport`, `completion` (`ack` \| `reply` \| `none`) |
| `event=wc_background_task_completed` | After `WKWatchConnectivityRefreshBackgroundTask.setTaskCompleted` (or equivalent) | `pending_count_before`, `pending_count_after`, `completion_path` (short string: e.g. `quiet_window`, `terminal_rescue`, `timeout_fallback`) |
| `event=wc_policy_selected` | Outbound policy chose a transport | `family`, `via` (`sendMessage` \| `transferUserInfo` \| `transferCurrentComplicationUserInfo` \| `updateApplicationContext`), `reason` (budget, reachability, safety_net, etc.) |

**Core correlation fields (preserve across refactors where present today):** `reading_epoch` (or equivalent CGM epoch), `payload_id` / ACK id sets, `pending_count` (watch connectivity tasks), `window_id` / background wake correlation if logged today, `queue_depth` / budget markers for complication transfers.

**Rate limiting:** high-volume paths may aggregate or sample in production; document any sampling in the implementation log.

---

## Migration / compatibility

- Phase in **read path first** (decode + dispatch behind existing methods), then **write path** (sender policy), then **delete** duplicated parsing.
- **End state:** one inbound **dispatcher module per platform** and one **transport policy** surface for outbound choices. **During migration**, **allow-listed exceptions** (temporary delegate bodies or duplicate parse paths) are acceptable **only** when listed in the **implementation log** with owner + removal phase; stale exceptions are a review failure.
- Maintain **feature flags** only if needed for risky decode tightening; default should be behavior-neutral.

---

## Alternatives considered (and why rejected)

- **Single mega-wrapper around `WCSession`:** Rejected — hides materially different semantics and encourages wrong transport use.
- **Third-party messaging layer:** Rejected — unlikely to match Trio’s complication + ACK + background task constraints; adds dependency risk.
- **Protocol-buffer wire format:** Deferred — higher migration cost; may be reconsidered if dictionary fragility remains after centralization.

---

## Success criteria (verifiable)

- [ ] Inventory (implementation plan Phase A) lists **every** inbound/outbound payload family with file pointers and transport used.
- [ ] **End state:** all **inbound payload** `WCSessionDelegate` methods (`didReceiveMessage` / `didReceiveUserInfo` / `didReceiveApplicationContext` and watch equivalents) route through **one inbound dispatcher module per side**. **Lifecycle / reachability** callbacks remain in the session owner per **Inbound dispatch scope** above; they are **not** required to pass through the inbound dispatcher. **During phased rollout**, **temporary** allow-listed exceptions are permitted **only** when recorded in the **implementation log** with rationale and a planned removal phase (see **Migration / compatibility**).
- [ ] **Zero** new raw `sendMessage([String: Any])` call sites outside the policy layer (allow-listed list in plan) — applies to **new** code after the policy layer exists; pre-existing call sites migrate by phase.
- [ ] Manual or automated checklist confirms **background connectivity tasks** complete after processing under scripted sequences (userInfo burst, context-first, message-first, late task), against the **recorded implementation baseline** (see **Regression baseline**).
- [ ] Logs include the **canonical observability schema** events (or deliberate, documented substitutions) with **core correlation fields** preserved.
- [ ] Complication freshness metrics / logs show **no regression** vs baseline during soak (for WC-heavy flows).

---

## Risks / open questions

- **Merge contention** with active branches touching `WatchState` / `BaseWatchManager` / complication stores — follow implementation plan **Dependencies** (**branch coordination** gate before Phase C).
- **Test gap:** watchOS CI may not exercise all WC paths; may require device soak scripts.
- **Naming collision:** Phone `WatchState` struct vs watch `WatchState` class — documentation and new modules must use unambiguous names (`PhoneWatchStateSnapshot` in prose, etc.).
- **Deferred error / crash family (intentional):** Centralized decode/dispatch may follow in a later phase per § **Error / crash reporting family (implementation phase scope)**. **Review risk:** prolonged **hybrid** (dispatcher + inline paths) — treat migration status as an explicit **phase-review** checkpoint until the logged follow-up phase completes.

---

## Changelog

### v1.9 (2026-04-08 09:31 CET)
- **R2 (ChatGPT):** **Risks** — deferred error/crash path may leave a **hybrid** state; explicit **phase-review** checkpoint. *(Plan **Gate taxonomy** addresses process-weight **M1**.)*

### v1.8 (2026-04-08 09:24 CET)
- **Queue / threading:** §3 no longer asserts a specific `WCSession` queue model — **verify and record** in plan **D1/E1**. **§2** tolerant decode: **Task A2** **minimal bar** + **staged backfill** (plan). **New § Dedupe and idempotency ownership** — transport vs domain vs complication store; plan **C/D/E** mirror.

### v1.7 (2026-04-07 23:00 CET)
- **Transport policy and `WatchStartupTransportGate`:** **`delegate`** vs **`subsume`** decision (logged by end of Phase A); **Phase F2** proves parity. **§2** tolerant decode: **Task A2** fixtures + Phase C flag exit / **G1** pointer. **§3** phone dispatcher: plan **D1** **queue contract** (threading); watch **E1** extends contract for **`pendingConnectivityTasks`**. **Risks:** branch coordination gate cross-reference. *(v1.8 softens §3 — verify queue model in-tree; do not assert.)*

### v1.6 (2026-04-07 22:26 CET)
- **F2:** New § **Error / crash reporting family (implementation phase scope)** — first slice may defer centralized decode/dispatch **only** if inline paths stay **behavior-identical** and deferral is **logged** with a **named follow-up phase**; no silent omission. **F3:** **Regression baseline** — fallback when **`watch-launch-stability`** is unavailable: **Baseline row** at kickoff + § **Forced-closure fix: preserved invariants** are operative. **F1:** *(plan-only; see implementation plan v1.7.)*

### v1.5 (2026-04-07 22:15 CET)
- Aligned with implementation plan **F1–F7**: **§1** target placement gate (**Task A3**); **§2** dual-read + soak-gated new rejections; **§3** phone **outer-layer** enforcement of completion contract + pointer to plan Phase D1/E1 (ACK / reply / batched ACK).

### v1.4 (2026-04-07 14:25 CET)
- Pre-implementation doc review (prompt **03**): added **Inbound dispatch scope** — inbound `didReceive*` vs lifecycle/reachability callbacks (repo-grounded: `BaseWatchManager` in `AppleWatchManager.swift`); **success criteria** wording updated so “one dispatcher” applies to **payload** entry points only; fixed typo in `sendMessage([String: Any])` criterion.

### v1.3 (2026-04-07 10:50 CET)
- Review feedback: added **Regression baseline** (commit anchors from `watch-launch-stability/00-investigation-findings`, code anchors, evidence pointers, mandatory kickoff row); **canonical observability schema** table; clarified **migration** vs strict **end state** for dispatchers; aligned **success criteria** with phased allow-listed exceptions; expanded observability success check.

### v1.2 (2026-04-07 10:44 CET)
- Idea doc moved back to `docs/backlog/watch-messaging-centralization/`; header link updated to backlog path.

### v1.1 (2026-04-06 17:48 CET)
- File renamed with initiative prefix (`watch-messaging-centralization-01-design.md`); idea doc link updated to in-progress sibling; added implementation plan cross-link.

### v1.0 (2026-04-06 17:41 CET)
- Initial design: current-state inventory table, target architecture (contracts, decode, dispatch, policy, senders), explicit non-regression boundaries for the shipped forced-closure / background completion fix, success criteria, alternatives, and risks.
