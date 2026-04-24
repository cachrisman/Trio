# Proactive transfer — Design

**Version:** v1.8  
**Created:** 2026-04-08 22:31 CET  
**Last updated:** 2026-04-08 23:47 CET  
**Status:** Draft — ready for review  

**Canonical backlog reference:** [`problem-and-strategy.md`](../problem-and-strategy.md) — *Proactive transfer on iOS app foreground* (Remediation follow-ups).

**Implementation worktree and branch:** **`Trio` worktree**, branch **`feature/watch-complication-improvements`** — all code changes, PR review, and **code review** for this initiative should happen there. **Planning docs** remain in **Trio-dev** (`docs/in-progress/...`); do not duplicate them into the Trio worktree.

---

## 1. Summary

Users expect that **opening Trio on iPhone** or **bringing the watch app to the foreground** improves freshness of watch UI and complications without waiting for the next CGM tick. Today there is **no** iPhone lifecycle hook that evaluates staleness and pushes watch state; the watch only conditionally requests an update when **WCSession reachability** changes (and last update is missing or older than ~15s).

This initiative defines **two coordinated behaviors**:

1. **iPhone — foreground evaluation and push:** When the iOS app becomes active, evaluate whether the watch likely needs a refresh; if so, call **`scheduleWatchStateUpdate(source: "iphoneForeground")`** on **`BaseWatchManager`** — the **only** permitted iPhone foreground entry into the coalesced watch-state pipeline. That path **internally** runs `setupWatchState()` → `sendDataToWatch(_:)` with **budget-aware** complication transfer (existing coalescing, stale-first gates, R4 / queue logic — no new uncapped `transferCurrentComplicationUserInfo` source).

2. **Watch — foreground evaluation and pull:** When the watch app becomes active, evaluate staleness; if the phone is reachable and **anti-thrash** (§6.4) allows, send **`requestWatchUpdate`** (existing message) so the phone computes and returns state; simultaneous phone foreground is **suppressed** when a proactive iPhone push is pending or just completed (App Group–visible window).

The design prioritizes **mental-model alignment** (“I looked at the app, it should sync”) while **preserving** the remediation program’s guardrails against redundant `transferCurrentComplicationUserInfo` usage.

---

## 2. Problem and user mental model

- **Observation:** Users open Trio on the phone to “wake” data or confirm loop state; they expect the watch face and complication to catch up without a new CGM reading.
- **Gap:** Foreground transitions do not currently trigger a staleness-gated sync on iOS. Opening the phone does not reliably change WCSession reachability, so the watch’s existing `sessionReachabilityDidChange` → `forceConditionalWatchStateUpdate()` path may not run.
- **Non-goal:** This is not a substitute for HealthKit observer delivery, R4 `applicationContext`, or R5d sleep-gap reload. It is an **opportunistic** sync when the user explicitly foregrounds an app.

---

## 3. Current behavior (baseline)

| Surface | Behavior |
|--------|----------|
| **iPhone `TrioApp`** | `scenePhase == .active` performs version check and cleanup only — **no** watch sync. |
| **iPhone `BaseWatchManager`** | Pushes on session activation, reachability-on, Core Data / glucose / IOB-driven updates; handles watch-initiated `requestWatchUpdate`. |
| **Watch `TrioWatchApp`** | `scenePhase` **active** → `handleForegroundActiveEntry()` (startup grace, telemetry — **not** proactive `requestWatchUpdate` yet); **inactive/background** → `handleForegroundInactiveOrBackground()`; logging flush when leaving active. **Staleness-gated** foreground `requestWatchUpdate` is **design §6** (not in current code). |
| **Watch `WatchState`** | On **reachability** true: `forceConditionalWatchStateUpdate()` — requests update if never updated or **> 15 s** since `lastWatchStateUpdate` (see §3.1). |

### 3.1 Code audit snapshot (`feature/watch-complication-improvements`, Trio worktree)

**Code baseline:** Implement and review against the **`Trio` worktree** on **`feature/watch-complication-improvements`** — the watch/complication stack is **integrated in-tree** (same substance as **`patches/09-watch-complication-improvements.patch`** / related patches on **Trio-dev** `dev`). **Do not** treat “unpatched Trio-dev files” as the sole reference; **do not** implement only from the patch file without checking the feature branch.

**Trio-dev patch workflow:** Regenerating or validating patches (`./patches/*.patch`, `scripts/patch-test.sh`, `mid-stack-update.sh`) still runs from **Trio-dev** on **`dev`** when cutting work back to the patch stack.

**Path layout for links below:** Paths use **Trio-dev** repo layout (`Trio/Sources/...`). In the **Trio** worktree, the iOS app target lives under **`Trio/Trio/Sources/...`** (nested product folder). Watch extension and complication paths match the same folder names as in Trio-dev. **`ComplicationDebugView.swift`** is cited by path only — it exists on **`feature/watch-complication-improvements`** in the **Trio** worktree and may be **absent** on a bare Trio-dev `dev` tree; open it from the Trio worktree when following §3.1 / §9.

| Area | Location (links → Trio-dev) | Verified behavior (feature branch; line # from Trio worktree) |
|------|-----------------------------|------------------------------------------------------------------|
| **iPhone `scenePhase`** | [`Trio/Sources/Application/TrioApp.swift`](../../../../Trio/Sources/Application/TrioApp.swift) | `.onChange(of: scenePhase)` **~347–365**: `.background` → `coreDataStack.save()`; `.active` → `AppVersionChecker`, `performCleanupIfNecessary()` if `initState.complete` — **no** watch manager calls. |
| **Phone → watch** | [`Trio/Sources/Services/WatchManager/AppleWatchManager.swift`](../../../../Trio/Sources/Services/WatchManager/AppleWatchManager.swift) | **`scheduleWatchStateUpdate(source:)`** **~658–713** (coalescer, `coalescer_trigger` / `coalescer_fired`); **`sendDataToWatch(_:...)`** **~721+**; **`session(_:didReceiveMessage:)`** handles **`requestWatchUpdate`** **~1148–1160** → `setupWatchState` + `sendDataToWatch`. Combine sinks call **`scheduleWatchStateUpdate`** (e.g. glucose ~104). **iPhone foreground** must call **`scheduleWatchStateUpdate(source: "iphoneForeground")`** — normative; see §5. |
| **Watch app lifecycle** | [`Trio Watch App Extension/TrioWatchApp.swift`](../../../../Trio%20Watch%20App%20Extension/TrioWatchApp.swift) | **`onChange(scenePhase)`** **~21–38**: **active** → `handleForegroundActiveEntry()`; **inactive/background** → `handleForegroundInactiveOrBackground()`; async log with flush when not active. **Proactive** `requestWatchUpdate` on foreground is **not** implemented yet (design §6). |
| **Watch `WatchState`** | [`Trio Watch App Extension/WatchState.swift`](../../../../Trio%20Watch%20App%20Extension/WatchState.swift) | **`lastDataReceivedAt`** / **`TrioComplicationDataStore`** **~104–108**, **~572+**; **`session(_:didFinish:error:)`** (userInfo transfer completion) **~1165–1190** — **error path logs**; **`else`** **~1187–1189** resets retry count, **no success log** → §8.2. **`sessionReachabilityDidChange`** **~1192+** → **`forceConditionalWatchStateUpdate()`** when appropriate; **`forceConditionalWatchStateUpdate()`** **~1254–1291** (**> 15 s** vs `lastWatchStateUpdate` at **~1283–1287**). |
| **Watch request API** | [`Trio Watch App Extension/WatchState+Requests.swift`](../../../../Trio%20Watch%20App%20Extension/WatchState+Requests.swift) | **`requestWatchStateUpdate()`** builds `[WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState]`. |
| **Watch debug UI (Phase D)** | `Trio Watch App Extension/Views/ComplicationDebugView.swift` *(Trio worktree, feature branch — see path note above)* | **Path** row **~111–118**; **App Group** section **~122+** — removal targets for design §9. |
| **Complication target** | [`Trio Watch Complication/TrioWatchComplication.swift`](../../../../Trio%20Watch%20Complication/TrioWatchComplication.swift) | Full glucose complication + WidgetKit paths on feature branch (not placeholder-only). |

**Dashboard / log names:** Strings such as `complication_budget_check`, `transfer_via`, and epic **§8.2** line names refer to the **integrated** logging pipeline on the feature branch; confirm exact keys in **`AppleWatchManager`** / complication extension when implementing.

---

## 4. Goals and non-goals

### Goals

- **G1 — iPhone foreground:** On transition to **active** (SwiftUI `scenePhase` or equivalent single entry point), evaluate whether a watch sync is warranted; trigger push only when justified.
- **G2 — Watch foreground:** On transition to **active**, evaluate staleness; if justified and session reachable, request fresh state from the phone (`requestWatchUpdate`) with rate limiting.
- **G3 — Budget safety:** Complication-related transfers must remain behind existing **stale-first**, **epoch/fingerprint**, and **coalescing** machinery — no new uncapped `transferCurrentComplicationUserInfo` source.
- **G4 — Observability:** Emit **Tier 1** events in §8 for first ship; **Tier 2** for Phase F gate (aligned with [`problem-and-strategy.md`](../problem-and-strategy.md) where applicable).
- **G5 — Watch debug screen:** Validation tool in §9 (UI vs complication ages, latest proactive action, parity with **`TrioComplicationDataStore`** / **`TrioWatchComplication`**).

### Non-goals

- **NG1:** Do not add a parallel “foreground-only” payload or bypass App Group / `saveOnMain` arbitration.
- **NG2:** Do not replace R4, R6, or R5d; this initiative complements transport when the user is looking at the UI.
- **NG3:** Do not guarantee sub-second complication refresh on every foreground; WidgetKit scheduling remains platform-controlled.

---

## 5. Design — iPhone (foreground check and push)

### 5.0 Required entry point

- **Normative:** The **only** permitted iPhone foreground entry into the watch-state send pipeline is **`scheduleWatchStateUpdate(source:)`** on **`BaseWatchManager` / `AppleWatchManager`**, with **`source: "iphoneForeground"`** (string literal — same coalescer attribution family as other sources).
- **Forbidden:** New Combine sinks that call `setupWatchState()` + `sendDataToWatch(_:)` directly from the foreground path; ad-hoc duplicates of the coalescer.

### 5.1 Canonical freshness sources and transport-specific success

Implementers **must not** improvise a single vague “success” or “fresh” concept. Use **distinct** clocks and **transport-specific** completion rules.

#### 5.1.1 Three freshness surfaces (what “stale” means where)

| Surface | Canonical source | Use |
|--------|------------------|-----|
| **Phone-side decisioning (Phase A)** | **Reading / snapshot epoch** available to the phone at evaluation time (same epoch the coalescer / `sendDataToWatch` path would serialize), **plus** the **last Phase A “successful proactive-eligible send”** record defined in §5.1.2 | Gates **`T_phone_active`** and **`T_send`** for whether to call **`scheduleWatchStateUpdate(source: "iphoneForeground")`**. |
| **Watch UI freshness** | **`lastWatchStateUpdate`** on the watch (when the main watch UI last applied watch state from the phone path). | Reachability / `forceConditionalWatchStateUpdate()`, watch foreground staleness vs UI (§6), debug §9 “watch UI applied” age. |
| **Complication / WidgetKit snapshot freshness** | **`TrioComplicationDataStore`** — **`lastDataReceivedAt`** (App Group–backed) and **`latestSnapshot()`** → **`TrioComplicationSnapshot`** (`Trio Watch Shared/TrioComplicationDataStore.swift`). Timeline reads in **`Trio Watch Complication/TrioWatchComplication.swift`** use the same store. | R5d, complication parity (§9), **§7.1 gate G1**, Phase F staleness. |

These three can **diverge** (e.g. UI fresh while complication snapshot stale); QA must cover mismatches (§9, Phase E).

#### 5.1.2 “Success” for Phase A (phone gating) vs Phase F (watch transfer completion)

| Concept | Definition | Transport-specific rule |
|--------|------------|---------------------------|
| **Last successful phone→watch send (Phase A / `T_send`)** | Last time a **proactive-evaluated** schedule completed such that the phone **initiated** a watch delivery attempt **and** the **phone-side** completion for that transport fired (see below). **Not** watch **`didFinish`** and **not** WidgetKit reload. | **Per transport (Phase A.0 binds to existing `AppleWatchManager` / `WCSession` surfaces — no second shadow counter):** **Reachable** — success is **`sendMessage(_:replyHandler:errorHandler:)`** **replyHandler** invoked **or**, if the codebase uses a single completion path, the **same** success branch **`AppleWatchManager`** already uses for interactive delivery (exact method + line references in A.0). **Unreachable** — success is **`transferUserInfo(_:)`** returning a **`WCSessionUserInfoTransfer`** the session **accepted for queuing**, **or** iPhone **`WCSessionDelegate`** **`session(_:didFinish userInfoTransfer:error:)`** with **`error == nil`** for the **outgoing** transfer — **only** if **`AppleWatchManager`** already uses that callback for “phone-side send complete” for **`T_send`** — **pick one** binding in A.0 and do not mix. |
| **Watch-side userInfo transfer completion (Phase F / gate G2)** | **`session(_:didFinish:error:)`** with **`error == nil`** for **`WCSessionUserInfoTransfer`**. | **Per transport:** userInfo **delivery completion** on watch only — distinct from Phase A phone-send success. Used to prove “queue drained” vs **`lastDataReceivedAt`** still stale. |

Phase A **must not** treat watch **`didFinish`** success as the **`T_send`** clock unless explicitly documented and wired (otherwise Phase A waits on watch completion and adds latency/coupling).

### 5.2 Trigger

- **Primary:** SwiftUI `.onChange(of: scenePhase)` when `newScenePhase == .active`, **after** existing active-phase work (version check, cleanup) so startup cost stays ordered.
- **Debounce:** Coalesce rapid active/inactive churn (initial window **300–500 ms** or single-flight Task — exact value **Phase A.0**) to avoid duplicate evaluation when switching apps.

### 5.3 Preconditions

- Initialization complete (`initState.complete` or equivalent guard already used elsewhere).
- Watch session supported, paired, watch app installed (mirror guards inside `setupWatchState()` / send path).
- Optional: skip during onboarding if watch sync is meaningless.

### 5.4 iPhone foreground decision flow (pseudocode)

**Intent:** Evaluate **after** debounce in this order: **hard preconditions** → **freshness / suppression** → **log evaluation (Tier 1)** → **gate** → **`scheduleWatchStateUpdate`**. Implementations may factor helpers.

**Durability:** Do **not** treat “noncompliant” if a **hard** precondition fails fast (e.g. catastrophic missing session) **without** Tier 1 logs — that is acceptable when logging would be misleading or impossible. For **normal** paths (init complete, watch available), emit **`proactive_transfer_evaluated`** / **`proactive_transfer_action`** as shown.

```
on scenePhase -> active (after existing .active work):
  if debounce_coalesces_this_transition: return

  if not initState.complete: log proactive_transfer_action skipped reason=init_incomplete; return
  if watch not (supported && paired && appInstalled): log skipped reason=watch_unavailable; return

  compute reading_epoch_age_s, seconds_since_last_phaseA_send  // §5.1.1–5.1.2
  if recent_suppression_window_hit:   // cooldown / “already fresh” short-circuit from Phase A.0
     log proactive_transfer_evaluated ...; proactive_transfer_action skipped reason=recent_success_or_fresh; return

  log proactive_transfer_evaluated with gate fields  // §8 tier 1

  if not should_push_per_§5_5:
     proactive_transfer_action skipped + reason; return

  scheduleWatchStateUpdate(source: "iphoneForeground")
  proactive_transfer_action push_scheduled + reason  // §8 tier 1
```

**`should_push_per_§5_5`:** Boolean from §5.5.1 (snapshot age **or** silent-gap per **`T_send`**, with short-circuit; reachability selects **transport only**, not an extra OR).

### 5.5 Staleness and “should push?” gates

Use the **signals** below with the **combination rule** in §5.5.1. Numeric defaults (**`T_phone_active`**, **`T_send`**, suppression window) are **not** open-ended: they are **chosen and documented in Phase A.0** (implementation plan) before gate logic ships.

| Signal | Purpose |
|--------|--------|
| **Snapshot / reading age** | Phone-side reading / snapshot epoch older than **`T_phone_active`** (initial default range **60–120 s** unless Phase A.0 documents otherwise). |
| **Time since last Phase A successful send** | No successful send per §5.1.2 in **`T_send`** (initial default **30–60 s** unless Phase A.0 documents otherwise) — repairs “silent” gaps. |
| **Reachability** | Informs **which transport** applies (`sendMessage` vs queued userInfo vs R4 `updateApplicationContext`). **Not** a blind third OR for “must push.” **When complication budget is exhausted,** whether to call **`updateApplicationContext`** vs only schedule complication transfer follows **existing R4 policy** — the **exact branch** used when budget is zero is **fixed in Phase A.0** (no improvisation at gate coding time). |

**Decision:** If the combined rule says “do not sync,” emit **`proactive_transfer_action`** with `action=skipped` and **`reason=`** (§8). If “sync,” call **`scheduleWatchStateUpdate(source: "iphoneForeground")`** — **only** this entry point.

#### 5.5.1 Gate combination (disambiguation)

The three rows are **not** three independent OR triggers by themselves: **reachability** shapes **transport choice**, not “foreground means push.” For **whether** to sync, combine **snapshot/reading age** and **time since last Phase A successful send** per §5.5:

- **Intent:** Push when **(A)** reading / snapshot epoch exceeds **`T_phone_active`**, **or** **(B)** silent gap exceeds **`T_send`** — subject to **recent-success / already-fresh** suppression (Phase A.0).
- Do **not** treat “at least one table row” as uncapped OR without the short-circuit.

#### 5.5.2 Freshness clocks (reference)

Same clocks as §5.1; do not mix **`lastWatchStateUpdate`**, **`lastDataReceivedAt`**, and Phase A **`T_send`** without labeling which gate uses which.

### 5.6 Interaction with existing send paths

- Foreground uses **`scheduleWatchStateUpdate(source: "iphoneForeground")`** so **`coalescer_trigger` / `coalescer_fired`** attribution matches R5a/R2a.
- **R4 / `updateApplicationContext` when budget is zero:** behavior is **pinned in Phase A.0** to match existing **`AppleWatchManager`** policy on **`feature/watch-complication-improvements`** (see §11).

---

## 6. Design — Watch (foreground check and request)

### 6.1 Trigger

- **`TrioWatchApp`:** The app already handles **`newScenePhase == .active`** via **`WatchState.shared.handleForegroundActiveEntry()`** (startup grace, resident telemetry, deferred refresh — see `WatchState.swift` ~218+). **This initiative** adds **staleness-gated** evaluation and, when justified, **`requestWatchStateUpdate()`** (§6.2–§6.5), by extending that flow or invoking a small helper from the same **`onChange`** path after existing work — **without** duplicating the startup pipeline.

### 6.2 Behavior

- Reuse **`requestWatchStateUpdate()`** (`WatchState+Requests.swift`) when:
  - `WCSession` is activated,
  - `session.isReachable == true`,
  - staleness gate passes (§6.3),
  - **and** anti-thrash (§6.4) allows.

### 6.3 Staleness gate (watch)

- **Different from reachability path:** The existing `forceConditionalWatchStateUpdate()` uses **~15 s** since **`lastWatchStateUpdate`**. Foreground may use the **same** threshold initially **or** **`T_watch_active`** (initial default **30–60 s** unless Phase A.0 / watch Phase B notes say otherwise) — document the chosen value with Phase A.0 / Phase B.
- **Cooldown:** Foreground-driven **`requestWatchStateUpdate`** is rate-limited using **`T_foreground_cooldown`** (initial default **60 s** unless Phase A.0 documents otherwise). Store **`lastWatchForegroundRequestAt`** (or equivalent) in **App Group–backed storage** (same UserDefaults suite / mechanism as other R5d freshness keys — **not** “process lifetime only”). **Normative:** persisted App Group only.

### 6.4 Anti-thrash (phone push vs watch pull)

- **Problem:** Simultaneous iPhone + watch foreground can produce redundant **push + pull** churn.
- **Critical constraint:** **App Group `UserDefaults` (and similar) are not a shared memory bus between iPhone and Apple Watch** — each device has its **own** container; the watch **cannot** read keys the phone wrote for cross-device “I just scheduled” signaling. **Do not** implement anti-thrash by having the phone write an App Group timestamp that the watch reads to detect a recent **`iphoneForeground`** schedule — that design is **invalid** for cross-device signaling. **Watch-local** App Group keys (e.g. **`lastWatchForegroundRequestAt`**) remain correct for **§6.3** cooldown only.

- **Preferred (same-watch, minimal):** Before **`requestWatchStateUpdate()`** on the watch foreground path, **suppress** if **watch-local** freshness already shows a **very recent** update: e.g. **`lastWatchStateUpdate`** or **`lastDataReceivedAt`** (§5.1.1) is **within** **`T_cross_surface_suppress`** (initial default **2–5 s**, fixed in Phase A.0) of **now**, **and** the §6.3 staleness gate would **not** independently demand a pull — i.e. **implicit** “phone (or pipeline) already refreshed the watch” without a new WC field. Log **`proactive_transfer_action` `skipped`** with **`reason=cross_surface_recent_delivery`** (or agreed enum).

- **Optional (only if A.0 proves inference insufficient):** Piggyback an explicit flag or **source tag** already in the **`WatchState` / userInfo** payload (WatchConnectivity) so the watch can see **`iphoneForeground`** attribution — **no** new transport; **Phase A.0** documents the **exact** field name and parsing site. **Do not** add a parallel bookkeeping file on the watch.

- **Phone coalescer “in flight”:** The watch **cannot** observe the phone coalescer directly. Rely on **recent delivery** + **`T_cross_surface_suppress`** (above) **or** payload attribution (optional).

### 6.5 When not to request

- Phone not reachable → log skip (user may still get HK / complication paths without a live message).
- Session not activated → existing `session.activate()` path; avoid request spam in a tight loop.

---

## 7. Ordering and race conditions

- **iPhone and watch both foreground:** Best-effort ordering; **§6.4** suppresses redundant watch **`requestWatchUpdate`** when watch-local freshness shows a **recent** refresh (or optional payload flag per A.0).
- **Duplicate request + push:** Phone may receive `requestWatchUpdate` while also running foreground push — existing dispatch gate (R2b) and epoch fingerprinting should collapse duplicates; **§6.4** reduces simultaneous open churn.

---

## 8. Observability and logging

Names align with existing `debug(.watchManager)` / Better Stack pipeline unless otherwise noted.

### 8.1 Tier 1 — Required for first ship (Phases A–E)

Must be present in production for the build that ships **A–E**.

| Event / field | Purpose |
|----------------|---------|
| **`proactive_transfer_evaluated`** | `surface=iphone_foreground \| watch_foreground`, gate inputs: `reading_epoch_age_s`, `seconds_since_last_phaseA_send`, `reachability`, `gate_results` (structured; not a vague blob) |
| **`proactive_transfer_action`** | `action=push_scheduled \| request_sent \| skipped`, **`reason=`** enum (includes **`cross_surface_recent_delivery`** when §6.4 inference suppresses — §6.4) |
| **Latency** | **`foreground_to_first_send_ms`** (iPhone active → first attempt attributed to **`iphoneForeground`**); **`watch_foreground_to_request_ms`** (watch active → `requestWatchUpdate` send, when not suppressed) |
| **Correlation** | **`reading_epoch`** (or phone-side epoch) on evaluation lines so rows line up with `complication_budget_check` / `transfer_via` |

### 8.2 Tier 2 — Required before Phase F (gate + §7.1)

The **hard gate** stays centered on: **(1)** trustworthy **complication** freshness state (**`lastDataReceivedAt`** / **`TrioComplicationDataStore`**), **(2)** **watch-side** userInfo **`session(_:didFinish:error:)` success** logging ( **`error == nil`** ), **(3)** enough **correlation** to prove **“transfer completed (watch)”** vs **“`lastDataReceivedAt` / snapshot age still stale”** (dead-zone pattern).

| Item | Tier | Notes |
|------|------|--------|
| **Watch-side userInfo completion — success log** | **Tier 2 (required before F)** | One-line **success** in **`session(_:didFinish:error:)`** when **`error == nil`**, distinct from existing error path — **gate G2** |
| **Trustworthy `lastDataReceivedAt` + debug alignment** | **Tier 2** | Debug §9 shows same ages as pipeline; **gate G1** |
| **“Success but stale” correlation (G3)** | **Tier 2** | **Gate requires** **either** a **shipped synthesized** roll-up event **or** a **documented, reproducible query recipe** (SQL/steps) that teams can run in Better Stack — **either** counts as Tier 2 complete for **G3**; no ambiguity. |
| **Queue flush lag (`queue_flush_lag_seconds`)** | **Tier 3 — fast-follow** | Epic line `complication_did_receive_user_info` — confirm string on branch |
| **Phone pipeline lag (`hk_write_epoch_seconds`)** | **Tier 3 — fast-follow** | Transfer log line on phone |
| **WidgetKit reload ↔ `getTimeline` correlation** | **Tier 3 — fast-follow** | Epic backlog |

**Tier 2 minimums** match implementation plan Phase C gate subsection; **Tier 3** may ship in a fast-follow PR if needed but **must not** block shipping Tier 1 for first build.

**G3 sharpness:** Satisfying **G3** for the Phase F gate means **either** the synthesized roll-up **or** the documented query recipe is **in production docs** (or repo) — not “we’ll figure out a query later.”

### 8.3 Epic reference

Additional items mirror [`problem-and-strategy.md`](../problem-and-strategy.md) §Observability / instrumentation; Tier 3 rows above.

---

## 9. Watch debug screen (watch app) — validation tool

On-device validation for **foreground sync**, **three-way freshness** (§5.1.1), and **proactive** decisions — not cosmetic-only. Align with [`problem-and-strategy.md`](../problem-and-strategy.md) UX row (“Data age readout in watch debug view”).

### 9.1 Required readouts (Phase D)

| Readout | Source | Detail |
|---------|--------|--------|
| **Watch UI applied — timestamp and age** | **`lastWatchStateUpdate`** (and/or the same field the main UI uses for “synced”) | Absolute time + “Xs ago” — must match what the user sees on main watch UI for sync freshness. |
| **Complication snapshot — timestamp and age** | **`TrioComplicationDataStore.shared.latestSnapshot()`** → **`TrioComplicationSnapshot`** (`Trio Watch Shared/TrioComplicationDataStore.swift`); freshness via **`lastDataReceivedAt`** / snapshot **`readingDate`** as implemented | Same store **`Trio Watch Complication/TrioWatchComplication.swift`** uses for timeline (`latestSnapshot()`). Show age **and** raw timestamps so **UI fresh / complication stale** (or inverse) is visible. |
| **Latest proactive action** | Last **`proactive_transfer_action`** (or compact mirror: last `action` + `reason` + timestamp persisted in App Group for on-watch display) | Lets field debugging confirm skip vs push vs cross-surface suppress without log tail. |

### 9.2 Complication parity (resolved dependency — no mid-phase stall)

**Normative sources** (feature branch):

- **Data store / snapshot:** **`TrioComplicationDataStore`**, **`TrioComplicationSnapshot`**, **`lastDataReceivedAt()`** — `Trio Watch Shared/TrioComplicationDataStore.swift`.
- **WidgetKit / timeline display path:** **`TrioWatchComplication`** — `Trio Watch Complication/TrioWatchComplication.swift` (reads **`TrioComplicationDataStore.shared.latestSnapshot()`**).

The parity section **must** render the **same** glucose/trend/delta/state strings (or canonical subset) the complication entry uses from **`latestSnapshot()`** — not a second decoding path. **`ComplicationDebugView`** already holds `@State private var snapshot: TrioComplicationSnapshot?` — extend that binding to parity requirements rather than introducing a parallel type.

### 9.3 Layout cleanup

| Change | Detail |
|--------|--------|
| **Data store section** | Remove the **Path** line (**~111–118** in `ComplicationDebugView.swift` on **`feature/watch-complication-improvements`** — §3.1). |
| **App Group** | Remove the **App Group** subsection (starts **~122** on that branch). |
| **Scroll / navigation** | Fix 2nd↔3rd page sticking (digital crown vs scroll) so the user reaches the **top of debug** without accidental **chart** navigation; deliberate chart navigation remains possible. |

### 9.4 QA scenarios (see Phase E)

Exercise **fresh UI vs stale complication**, **stale UI vs fresh complication**, and **rapid active/inactive churn** while observing §9.1 readouts.

---

## 10. Other epic backlog items

Work **not** specified in §8–§9 remains in [`problem-and-strategy.md`](../problem-and-strategy.md) §Backlog (e.g. adaptive budget throttling, cross-channel arbitration documentation, platform follow-ups), except **post-dead-zone recovery**, which is **Phase F** in [`proactive-transfer-02-implementation-plan.md`](proactive-transfer-02-implementation-plan.md) (gated after Phases A–E; see implementation plan §7.1).

**Explicitly out of scope for the first ship (Phases A–E):** Phase F / post-dead-zone — see §12.

**Explicitly out of scope for this initiative overall:** `WKApplicationRefreshBackgroundTask`, `WKExtendedRuntimeSession`, Nightscout precompute service.

---

## 11. Parameters owned in Phase A.0 (not open at gate coding time)

The following are **resolved and documented before** implementing §5.5 / §6 gate logic (implementation plan **Phase A.0**). Defaults may start conservative; tune from production histograms afterward **without** changing the success semantics in §5.1.2.

| # | Topic | Output of Phase A.0 |
|---|--------|---------------------|
| **Q1** | Initial **T_phone_active**, **T_watch_active**, **T_send**, **T_foreground_cooldown**, debounce window, **`T_cross_surface_suppress`**; **§6.4 anti-thrash strategy** (**`inference`** from **`lastWatchStateUpdate` / `lastDataReceivedAt`** vs **`optional_payload_flag`** from existing `WatchState` / userInfo — **not** cross-device App Group keys) | Single table in PR or short addendum: numeric values + which clock each uses (§5.1.1) + **exact** Phase A **`T_send`** bindings per §5.1.2 (`sendMessage` reply path vs `transferUserInfo` enqueue vs iPhone **`session(_:didFinish userInfoTransfer:error:)`** — **one** binding for unreachable). |
| **Q2** | **`updateApplicationContext`** vs complication-only path when **complication budget is exhausted** | Explicit branch: when budget zero, follow existing **`AppleWatchManager`** R4 policy on **`feature/watch-complication-improvements`** — document **which existing helper/branches** run (no improvisation **after** **A.0** when coding §5.5 / **`sendDataToWatch`**). |

**Resolved in doc (normative):**

- **Q3 — Entry point:** **`scheduleWatchStateUpdate(source: "iphoneForeground")`** only — §5.0.
- **Q4 — Complication parity types/paths:** §9.2 — **`TrioComplicationDataStore`**, **`TrioComplicationSnapshot`**, **`TrioWatchComplication`**, **`ComplicationDebugView`**.

---

## 12. Post-dead-zone recovery (Phase F — gated)

**Epic:** [`problem-and-strategy.md`](../problem-and-strategy.md) — *Post-dead-zone recovery: pull request after stall drain*.

**Behavior (summary):** On the watch, in **`session(_:didFinish:error:)`** when the userInfo transfer **completes without error**, evaluate whether **`lastDataReceivedAt`** (or the canonical freshness timestamp) is still **stale**. If stale, send **`requestWatchUpdate`** (or equivalent) with **rate limiting**, so a “successful” queue drain does not leave the complication stale indefinitely.

**Ordering:** Implement only after **Phases A–E** are shipped and the **gate** in the implementation plan (**§7.1**) passes: trustworthy `lastDataReceivedAt`, **success** logging on transfer completion, **documented** “success but still stale” gap in production logs, and stable A–E behavior. Detailed tasks: implementation plan **§8 Phase F**.

---

## Changelog

### v1.8 (2026-04-08 23:47 CET)
- **§5.4:** Ordering guidance softened (hard precondition fast-fail without logs OK); **§5.1.2** Phase A **`T_send`** binds to **existing** `WCSession` / `AppleWatchManager` surfaces (no shadow counters).
- **§6.4:** **Fix:** cross-device anti-thrash **cannot** use App Group keys phone→watch; **watch-local inference** + optional WC payload flag; **§7** pointer updated.
- **§8.2:** **G3** — **either** synthesized roll-up **or** documented query recipe explicitly gate-satisfying.
- **§11 Q1:** Anti-thrash strategy + **`T_send`** binding outputs in A.0.
- Reason: external review (ChatGPT/Claude) — durable wording + correct cross-device mechanics.

### v1.7 (2026-04-08 23:35 CET)
- **§5:** Normative **`scheduleWatchStateUpdate(source: "iphoneForeground")`** only (§5.0); **§5.1** canonical freshness + **transport-specific** Phase A vs Phase F success (§5.1.2); **§5.4** pseudocode flow; **§5.5** gates; **§5.6** R4/budget pinned in **A.0**.
- **§6:** App Group–**only** foreground cooldown; **§6.4** cross-surface anti-thrash.
- **§8:** Observability **Tier 1 / 2 / 3**; gate centered on freshness + watch **`didFinish`** success + correlation.
- **§9:** Validation readouts, **§9.2** fixed types/paths, **§9.4** QA scenarios.
- **§11:** Q1–Q2 owned in **Phase A.0**; Q3–Q4 closed in-doc.
- Reason: remove entry-point ambiguity; lock freshness/success model, observability tiers, and debug/QA coverage.

### v1.6 (2026-04-08 23:17 CET)
- **Worktree / branch:** Implementation and code review on **`Trio` worktree**, **`feature/watch-complication-improvements`**; planning docs stay in **Trio-dev**.
- **§3 / §3.1:** Baseline is **integrated** code on the feature branch (line refs from Trio worktree); Trio-dev **patch** workflow called out separately; **`TrioWatchApp`** **active** handling (`handleForegroundActiveEntry`) and **`ComplicationDebugView`** Path/App Group line targets; `session(_:didFinish:error:)` **~1165–1190**; `scheduleWatchStateUpdate` **~658+**; `requestWatchUpdate` **~1148+**.
- **§5–§6, §9, §11:** Wording aligned with feature branch (no “unpatched-only” baseline); §6.1 reflects existing **active** lifecycle vs new proactive request.
- Reason: user direction — implement/review on Trio feature branch, not patch-file-only narrative.

### v1.5 (2026-04-08 23:11 CET)
- **§3.1:** Code audit snapshot — unpatched `TrioApp` / `BaseWatchManager` / `WatchState` / `TrioWatchComplication` paths, line ranges, **`didFinishUserInfoTransfer` errors-only**; patch 09/10 as source of `scheduleWatchStateUpdate`, coalescer, `lastDataReceivedAt`, full complication.
- **§5.4, §5.3.2, §8.2, §11:** Aligned with repo + patch workflow; open Q3/Q4 updated with resolved/patch-grounded answers.
- Reason: code review of Trio-dev workspace vs docs.

### v1.4 (2026-04-08 23:05 CET)
- **§5.3:** Clarified reachability row (transport, not blind OR trigger); unified skip logging with §8.1 (`proactive_transfer_action` + reason); added **§5.3.1** gate combination and **§5.3.2** freshness clocks table (`lastDataReceivedAt` vs others).
- Reason: pre-implementation doc review — remove ambiguous “at least one row” OR interpretation; align naming.

### v1.3 (2026-04-08 22:59 CET)
- **§10:** Post-dead-zone called out as **Phase F** (implementation plan); first ship explicitly excludes F.
- **§12:** New — post-dead-zone behavior summary and pointer to implementation plan gate + Phase F tasks.
- Reason: staged delivery — A–E + deploy + observe, then Phase F only after evidence.

### v1.2 (2026-04-08 22:50 CET)
- **§8:** Split proactive events vs epic observability backlog (queue lag, HK→transfer lag, watch transfer success, synthesized diagnostic, WidgetKit correlation) as implementation targets.
- **§9:** Watch debug screen — data age, remove Path line, remove App Group section, complication-parity section, scroll/crown vs chart investigation.
- **§10:** Replaced “related/adjacent” table with a short pointer to epic backlog; removed prescriptive cross-item narrative.
- Reason: align docs with requested scope; keep strategic judgment out of the design doc.

### v1.1 (2026-04-08 22:49 CET)
- Goals G4/G5 expanded; partial observability/debug scope (superseded by v1.2 structure).

### v1.0 (2026-04-08 22:31 CET)
- Initial design: iPhone foreground push, watch foreground `requestWatchUpdate`, gating, observability, open questions.
- Reason: backlog item “Proactive transfer on iOS app foreground” expanded into a full initiative with watch symmetry and budget-safe constraints.
