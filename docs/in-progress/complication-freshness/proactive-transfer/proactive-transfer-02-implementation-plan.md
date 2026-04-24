# Proactive transfer — Implementation plan

**Version:** v1.7  
**Created:** 2026-04-08 22:31 CET  
**Last updated:** 2026-04-08 23:47 CET  
**Status:** Draft — not started  

**Design:** [proactive-transfer-01-design.md](proactive-transfer-01-design.md)  
**Epic context:** [`problem-and-strategy.md`](../problem-and-strategy.md)

**Implementation worktree and branch:** **`Trio` worktree**, **`feature/watch-complication-improvements`** — all implementation, PRs, and code review. Planning docs remain in **Trio-dev** only.

**Phase order:** Implement **A → E**, ship a build, run the **Phase F gate** (§7.1). Only after the gate passes, implement **Phase F** (post-dead-zone recovery).

---

## 1. Purpose

Implement the design in `proactive-transfer-01-design.md`: staleness-gated **iPhone foreground** push via **`scheduleWatchStateUpdate(source: "iphoneForeground")`** (only entry — design §5.0) and **watch foreground** `requestWatchUpdate` with **watch-local App Group** cooldown (§6.3) and **cross-surface anti-thrash** via **watch-local inference** and/or **optional WC payload** (design **§6.4** — **not** phone→watch App Group signaling). **Phase F** (post-dead-zone recovery) is a **gated follow-on** — see §7.1 and design §12.

---

## 2. Prerequisites

- [ ] **Checkout `feature/watch-complication-improvements`** in the **`Trio` worktree** (see design header). Do not implement from Trio-dev alone unless you are only editing docs.
- [ ] Read design **§3.1** (integrated baseline on the feature branch; Trio-dev links vs `Trio/Trio/Sources/...` in the Trio worktree; **`scheduleWatchStateUpdate`**, **`TrioComplicationDataStore`**, **`ComplicationDebugView`** line targets).
- [ ] Read design **§5** (entry point, freshness model, pseudocode, gates), **§6** (App Group cooldown, anti-thrash), **§8** (observability tiers), **§9–§12**.
- [ ] Read design **§10** (epic backlog pointer; what stays out of first ship).
- [ ] **Patch stack (Trio-dev):** When merging work back to **`dev`** as patches, validate with **`scripts/patch-test.sh`** on **Trio-dev**. The feature branch already contains the substance of **`patches/09-watch-complication-improvements.patch`** (and related patches) **in-tree**.
- [ ] Confirm **`scheduleWatchStateUpdate(source:)`** and coalescer state in `BaseWatchManager` / `AppleWatchManager`; confirm **`lastDataReceivedAt`** / **`TrioComplicationDataStore`** for gate G1.
- [ ] Confirm `lastWatchStateUpdate` vs **`lastDataReceivedAt`** for watch gates (design **§5.1.1** / **§5.5.2**).

---

## 3. Phase A — iPhone foreground hook

| # | Task | Notes |
|---|------|--------|
| **A.0** | **Parameter lockdown (before gate logic):** Document design **§11 Q1–Q2** in a PR table or short addendum: initial **`T_phone_active`**, **`T_send`**, **`T_watch_active`**, **`T_foreground_cooldown`**, debounce, **`T_cross_surface_suppress`**; **§6.4 strategy** (**`inference`** vs **`optional_payload_flag`** — see design §6.4); **and** exact **`AppleWatchManager`** behavior when **complication budget is zero**. **Bind** **`T_send`** to **one** concrete surface per transport: **`sendMessage`** reply/error handlers **and** unreachable path via **`transferUserInfo`** enqueue **or** iPhone **`session(_:didFinish userInfoTransfer:error:)`** (exact choice + file refs — design **§5.1.2**). | **Blocks** A.4–A.5 — no improvisation mid-implementation. |
| A.1 | Add **ForegroundWatchSyncController** (or equivalent): own **debounce**, evaluation timestamps, and **calls into** **`BaseWatchManager`**. **`T_send` / last Phase A success** is updated **only** from **existing** `AppleWatchManager` / `WCSession` completion paths (§5.1.2) — **derive**, do **not** duplicate a second shadow counter unless **A.0** documents an exception. **Cross-surface:** watch side implements §6.4 per **A.0** — **not** App Group keys written on phone for the watch to read. | Keeps `TrioApp.swift` thin. |
| A.2 | On `scenePhase == .active` (after existing guards), call `evaluateProactiveWatchSync(reason: .iphoneForeground)` following design **§5.4** order. | Single entry. |
| A.3 | Implement **debounce** per **A.0**. | Log if debounce drops duplicate. |
| A.4 | Implement **staleness gate** per design **§5.5** using **§5.1.1–5.1.2** clocks (not mixed “generic success”). | Emit **`proactive_transfer_evaluated`** then **`proactive_transfer_action`** (design **§8.1**). |
| A.5 | On pass, call **`scheduleWatchStateUpdate(source: "iphoneForeground")`** on **`BaseWatchManager`** — **only** permitted entry (design **§5.0**). **Do not** add a new Combine sink to `setupWatchState` + `sendDataToWatch`. | |
| A.6 | Unit tests: gate logic (stale vs fresh), debounce, init/onboarding skip, **transport-specific** Phase A success edges. | Mock time / mock last-send per §5.1.2. |

**Acceptance:** Opening Trio on device with stale snapshot results in at least one **`iphoneForeground`** coalescer attribution; fresh / suppressed produces skip with **`reason=`**; **A.0** doc exists before merge.

---

## 4. Phase B — Watch foreground hook

| # | Task | Notes |
|---|------|--------|
| B.1 | **`TrioWatchApp`** already calls **`handleForegroundActiveEntry()`** on **active** (design §3.1). Extend that flow (or call a helper from the same **`onChange`**) to run **`evaluateProactiveWatchRequest`** — **do not** rip out startup behavior. | Consider `Task { @MainActor in ... }` if touching `WatchState`. |
| B.2 | `evaluateProactiveWatchRequest`: reachability, **`T_foreground_cooldown`** (App Group persisted — design **§6.3**), staleness vs **`lastWatchStateUpdate`** per **A.0** / design **§6.3**. | |
| B.3 | **Anti-thrash (design §6.4):** **Do not** read phone-written App Group keys on watch. **Prefer** watch-local **inference** — if **`lastWatchStateUpdate`** / **`lastDataReceivedAt`** is within **`T_cross_surface_suppress`**, skip **`requestWatchStateUpdate`** and log **`reason=cross_surface_recent_delivery`**. **If A.0 chose `optional_payload_flag`**, parse the **existing** WC payload for **`iphoneForeground`** attribution. | |
| B.4 | On pass (not suppressed), call **`requestWatchStateUpdate()`**; on skip, log **`proactive_transfer_action`** with reason. | No duplicate send implementation. |
| B.5 | Unit tests where possible (watch target) or device test checklist. | Document manual steps if test host limited. |

**Acceptance:** Stale + reachable + not cooldown + not cross-surface suppressed ⇒ `requestWatchUpdate`; otherwise skip with explicit reason.

---

## 5. Phase C — Observability (proactive + epic backlog)

| # | Task | Notes |
|---|------|--------|
| C.1 | Ship design **§8.1 Tier 1** (`proactive_transfer_evaluated`, `proactive_transfer_action`, latencies, `reading_epoch` correlation). | Reuse existing logging sink (Better Stack pipeline). |
| C.2 | Ship design **§8.2 Tier 2** (gate / Phase F): watch **`session(_:didFinish:error:)`** **success** log (today **~1165–1190** logs **errors only** on Trio worktree — design §3.1); trustworthy **`lastDataReceivedAt`** / Phase D alignment; **G3** — **either** synthesized roll-up **or** **documented reproducible query recipe** in repo/docs (**both** satisfy gate — design §8.2). **Tier 3** — **fast-follow** PR OK. | |
| C.3 | Document example Better Stack queries / dashboard panels in `proactive-transfer/` or append to [`observability-implementation-log.md`](../observability/observability-implementation-log.md) after ship. | Version bump that file if edited. |

**Acceptance:** Tier 1 filterable in production; Tier 2 satisfies **§7.1** when combined with Phase D debug readouts.

### Gate minimums (§7.1) — Tier 2 alignment

| §7.1 criterion | Maps to design §8 | Notes |
|----------------|-------------------|-------|
| **G1** | Tier 2 + Phase D **§9.1** | Trustworthy **`lastDataReceivedAt`** / snapshot ages on-device. |
| **G2** | Tier 2 — **`session(_:didFinish:error:)` success** | **Required** before Phase F. |
| **G3** | Tier 2 — **either** roll-up **or** query recipe (design §8.2) **+** Tier 1 **`reading_epoch`** | “Watch **didFinish** success **but** **`lastDataReceivedAt`** / snapshot still stale” — transport-specific per design §5.1.2. |

**Tier 3** items do **not** gate Phase F.

---

## 6. Phase D — Watch debug screen

| # | Task | Notes |
|---|------|--------|
| D.1 | Implement design **§9.1** readouts: **watch UI applied** age (**`lastWatchStateUpdate`**); **complication snapshot** age (**`TrioComplicationDataStore.latestSnapshot()`** / **`lastDataReceivedAt`**); **latest proactive action** (mirror `proactive_transfer_action` or App Group compact state). | Validation tool — not optional “nice to have.” |
| D.2 | **Complication parity** per design **§9.2** — **`TrioComplicationSnapshot`** via **`TrioComplicationDataStore`**, same path as **`TrioWatchComplication`** (`Trio Watch Shared/…`, `Trio Watch Complication/…`). | No parallel decode path; extend existing `ComplicationDebugView` `@State snapshot`. |
| D.3 | Remove **Path** line and **App Group** subsection per design **§9.3**. | |
| D.4 | **Scroll / crown:** Fix 2nd↔3rd page sticking per **§9.3**. | Device validation; document outcome in PR. |

**Acceptance:** Matches design **§9**; **§9.4** mismatch scenarios visible on-device (pair with Phase E).

---

## 7. Phase E — Integration, QA, rollout

| # | Task | Notes |
|---|------|--------|
| E.1 | **Regression:** Verify glucose-driven and reachability-driven paths unchanged (integration smoke). | |
| E.2 | **Budget:** Spot-check `complication_budget_check` / transfer_via buckets during dev — no spike in `transferCurrentComplicationUserInfo` from foreground alone. | Compare to baseline session. |
| E.3 | **Manual matrix:** iPhone foreground only; watch foreground only; both; unreachable phone; fresh vs stale data. | Record in PR or test note. |
| E.3b | **Churn:** Rapid **active ↔ inactive ↔ active** on **iPhone** and **watch** (design §9.4) — confirm debounce + no duplicate **`scheduleWatchStateUpdate`** storms; reasons logged. | |
| E.3c | **Mismatch:** Scenarios where **watch UI** is fresh and **complication snapshot** stale — **and inverse** — using §9.1 readouts + logs. | Documents **three-way** freshness (design §5.1.1). |
| E.4 | **Build and deploy** an app version containing **Phases A–D** (foreground hooks, Phase **C** observability **Tier 1 + Tier 2** per **gate minimums**, Phase **D** debug UI). Ship to TestFlight / production per repo process. | No TestFlight upload from agent without user instruction. |
| E.5 | **Observe production logs** for an agreed window to evaluate the **Phase F gate** (§7.1). Document date range, queries, and **evidence artifact** (link or file in repo / PR). | Gate is **binary**: proceed to Phase F only when §7.1 criteria are met. If **G3** does not occur naturally, extend the window **or** document a **staged repro** that produces the same log signature — do not block Phase F forever on rarity alone. |

### 7.1 Gate — prerequisites to start Phase F (post-dead-zone)

Do **not** implement Phase F until **all** of the following are true:

| # | Criterion | How to verify |
|---|-----------|----------------|
| G1 | **`lastDataReceivedAt` is trustworthy** | Used consistently on the watch for freshness; debug UI and/or synthesized diagnostic (Phase C) align with user-visible staleness. |
| G2 | **Transfer completion success logging exists** | Watch-side **`session(_:didFinish:error:)`** (userInfo transfer completion) logs **success** (implementation Phase C / design **§8.2 Tier 2**), not only errors — so “transfer completed” is visible in Better Stack. |
| G3 | **The gap is demonstrable in logs** | At least one **documented** pattern: userInfo transfer **succeeded** (per G2) but **`lastDataReceivedAt` / snapshot age** still indicates stale data longer than an agreed threshold (dead-zone-style). **Primary:** production capture (timestamps + query). **Fallback:** staged repro with the same log signature if production is quiet after the agreed observation window. |
| G4 | **Phases A–E behavior is stable** | No open P0/P1 regressions attributed to foreground sync or observability changes. |

If G1–G4 are not met, **iterate** on A–E (or observability) until they are; Phase F stays **out of scope** until then.

---

## 8. Phase F — Post-dead-zone recovery (after gate)

**Epic reference:** [`problem-and-strategy.md`](../problem-and-strategy.md) — *Post-dead-zone recovery: pull request after stall drain*.

| # | Task | Notes |
|---|------|--------|
| F.1 | In watch **`session(_:didFinish:error:)`** **success** path (no error), evaluate staleness of **`lastDataReceivedAt`** (or equivalent canonical freshness timestamp). | Same definition as G1. |
| F.2 | If still stale per agreed threshold (TBD from G3 evidence — e.g. “success logged but data age > X s”), send **`requestWatchUpdate`** / existing phone pull (same mechanism as other recovery paths). | Rate-limit / cooldown so completion storms do not spam the phone. |
| F.3 | Log a dedicated line: `post_dead_zone_recovery` (or agreed name) with `transfer_succeeded=1`, `last_data_received_age_s`, `action=request_watch_update\|skipped`, `reason=`. | Correlates with G2 success logs. |
| F.4 | Unit or device tests where feasible; document manual dead-zone repro if automated test is impractical. | |

**Acceptance:** In staged testing or production, a simulated “success but still stale” window triggers at most one recovery request per cooldown and updates `lastDataReceivedAt` afterward when the phone responds.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Extra complication budget use | Route through existing stale-first + coalescer; tune **T_phone_active** high enough; monitor 4H `queue_depth`. |
| Duplicate sends with glucose tick | R2b epoch gate + debounce on foreground evaluation. |
| Watch request spam | App Group **Cooldown** + **§6.4** cross-surface suppress. |
| Main-thread work on app launch | Defer evaluation slightly after active; keep work async off hot path where possible. |
| Phase F request loops | Gate on §7.1; cooldown in F.2; reuse same `requestWatchUpdate` path as elsewhere. |

---

## 10. Definition of done

### Phases A–E (first ship)

- [ ] Design **§11 Q1–Q2** satisfied via **Phase A.0** artifact (numeric thresholds + R4/budget-zero branch documentation); **no** open improvisation at gate merge.
- [ ] iPhone and watch behaviors match design §5–§6; observability matches design §8; debug screen matches design §9.
- [ ] Phase **E** includes build + deploy + observation period for **§7.1 gate** documentation.
- [ ] `problem-and-strategy.md` backlog row for **Proactive transfer** updated to **Shipped** with build number when A–E release.
- [ ] Initiative README row updated (this folder).

### Phase F (second ship — only after §7.1 gate passes)

- [ ] §7.1 gate **G1–G4** documented as satisfied (with query / log evidence for G3).
- [ ] Phase **F** tasks F.1–F.4 complete; `post_dead_zone_recovery` (or agreed) logs present.
- [ ] Epic backlog row for **Post-dead-zone recovery** updated to **Shipped** with build number when released.

---

## Changelog

### v1.7 (2026-04-08 23:47 CET)
- **A.0 / A.1:** **`T_send`** binding to real **`WCSession` / `AppleWatchManager`** completions; controller **derives** — no shadow counters; **§6.4** not phone App Group → watch.
- **B.3:** Anti-thrash = inference + optional payload; **`cross_surface_recent_delivery`**.
- **C.2 / G3:** Roll-up **or** documented query recipe as gate-equivalent.
- Reason: external review feedback + cross-device App Group correction.

### v1.6 (2026-04-08 23:35 CET)
- **Phase A.0:** Lock **§11 Q1–Q2** before gate logic; **A.5** normative **`scheduleWatchStateUpdate(source: "iphoneForeground")`** only (design §5.0).
- **Phase B:** App Group cooldown **only**; **B.3** cross-surface anti-thrash; removed ambiguous B.4.
- **Phase C / §7.1:** Observability **tiers** (design §8); gate ↔ Tier 2 mapping.
- **Phase D / E:** §9 validation readouts, **§9.2** types, **E.3b–E.3c** QA churn + mismatch.
- Reason: lock implementation path, freshness/success semantics, and observability scope.

### v1.5 (2026-04-08 23:17 CET)
- **Worktree / branch:** **`Trio` worktree**, **`feature/watch-complication-improvements`** for all implementation and review; planning docs in **Trio-dev** only.
- **Prerequisites:** Replaced “patch-only” baseline with integrated feature branch + Trio-dev **patch-test** when cutting patches to `dev`.
- **Phase B.1:** Notes existing **`handleForegroundActiveEntry()`** on active; extend for proactive request.
- **Phase C.2 / D.3:** Line refs and wording aligned with design v1.6 / Trio worktree.
- Reason: match design doc worktree/branch guidance.

### v1.4 (2026-04-08 23:11 CET)
- **Prerequisites:** Design §3.1; explicit **patch stack** baseline (`patch-test.sh`, patch 09+); `scheduleWatchStateUpdate` / `TrioComplicationDataStore` grounding.
- **Phase A.5:** Concrete **`scheduleWatchStateUpdate(source: "iphoneForeground")`** on patched `BaseWatchManager`.
- **Phase C.2 / D.3:** Unpatched vs post-patch log lines; `didFinishUserInfoTransfer` errors-only today; complication parity via **`TrioComplicationDataStore`**.
- **Purpose:** References design §3.1 patch workflow.
- Reason: code review of Trio-dev + patches vs docs.

### v1.3 (2026-04-08 23:05 CET)
- **Prerequisites:** Design §10; explicit warning not to assume `scheduleWatchStateUpdate` symbol.
- **Phase C:** New **Gate minimums** subsection — minimum §8.2 deliverables for §7.1 (G1–G3) vs fast-follow items.
- **Phase E:** E.4 wording; E.5 — evidence artifact, **G3** fallback (extend window or staged repro).
- **§7.1 G3:** Production-first + staged repro fallback.
- **Phase F DoD:** Wording — “only after gate passes” (not “optional”).
- Reason: pre-implementation doc review — gate logic, observability minimums, log naming alignment, G3 rarity.

### v1.2 (2026-04-08 22:59 CET)
- **Phase E:** Added E.5 (observe logs for gate); **§7.1 Gate** defines G1–G4 before Phase F (`lastDataReceivedAt`, success logging, provable gap in logs, stability).
- **Phase F:** Post-dead-zone recovery (`didFinishUserInfoTransfer` success path + stale `lastDataReceivedAt` → `requestWatchUpdate`) after gate; dedicated log line; risk row for request loops.
- **DoD:** Split into A–E first ship vs Phase F second ship.
- Reason: user-requested staged rollout — ship A–E, validate instrumentation, then implement F only when evidence supports it.

### v1.1 (2026-04-08 22:50 CET)
- Phase C expanded for epic observability backlog (design §8.2). New Phase D (watch debug, design §9). Former integration phase renumbered to E; risks/DoD renumbered.
- Reason: match design v1.2 scope.

### v1.0 (2026-04-08 22:31 CET)
- Initial implementation plan: phases A–D, prerequisites, acceptance, risks, DoD.
- Reason: companion to `proactive-transfer-01-design.md` for execution and validation.
