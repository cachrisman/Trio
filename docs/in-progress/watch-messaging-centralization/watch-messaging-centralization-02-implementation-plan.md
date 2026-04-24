# Implementation plan: Watch / phone messaging architecture centralization

**Version:** v1.11  
**Status:** Draft  
**Created:** 2026-04-06 17:41 CET  
**Last updated:** 2026-04-08 09:31 CET  

**Design reference:** [watch-messaging-centralization-01-design.md](watch-messaging-centralization-01-design.md)  
**Idea (backlog):** [watch-messaging-centralization-00-idea.md](../../backlog/watch-messaging-centralization/watch-messaging-centralization-00-idea.md)

---

## Prerequisites

**Purpose:** Ground implementation and review in the **same tree context** this plan was written against; avoid silent drift when `AppleWatchManager.swift` / `WatchState.swift` / complication paths move on `dev` or feature branches.

| Field | At plan authoring (2026-04-07) | Record at implementation kickoff |
|-------|----------------------------------|-----------------------------------|
| **Docs worktree** | `Trio-dev` (docs path: `docs/in-progress/watch-messaging-centralization/`) | Confirm worktree; if docs edited elsewhere, note it in the [implementation log](#implementation-log). |
| **Code worktree** | Assumed sibling **`Trio`** worktree per fork workflow (Swift sources **not** in `Trio-dev`) | Branch name + `git rev-parse HEAD` + merge-base to `dev` (or upstream) for the branch that will ship the change. |
| **Fork patch stack** | This repo applies personal patches on `dev` (`./patches/`); feature code may land on a **feature branch** and be regenerated into patches later | State whether validation used **`dev` + patches**, **feature branch only**, or **both**; note any patch files touched. |
| **Baseline behavior** | Non-regression boundary is the shipped **connectivity background-task completion** semantics — see design § **Regression baseline** | Add the **Baseline row** required there (build/TestFlight, soak notes, log query pointers). |

**Known uncertainty:** File paths and line-level references in Phase tasks assume the **current** module layout; re-run Phase A inventory if the tree diverges significantly before coding.

---

## Scope

- Refactor Trio’s **Apple Watch ↔ iPhone WatchConnectivity** layer toward **shared contracts**, **shared decode/validation**, **central inbound dispatch per side**, and an **explicit transport policy layer**, as specified in the design doc.
- Preserve **shipped** watch **background connectivity task completion** semantics and **multi-channel inbound** behavior (see **Regression boundaries** below).

## Out of scope

- Rewriting unrelated watch UI, charts, or HealthKit observer strategy except where required to compile or to preserve behavior at dispatch boundaries.
- Garmin watch integration (`GarminManager` / `GarminWatchState`) unless Phase A inventory proves shared payload surfaces **and** design sign-off extends scope.
- Changing complication **product** thresholds (staleness, budget math) except to fix demonstrable bugs found during consolidation.

## Dependencies

- Coordination with any in-flight work touching:
  - `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` (`BaseWatchManager`)
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch Shared/TrioComplicationDataStore.swift`
- **Design / doc reviews** per `docs/prompts/` (01–03) before broad code churn.

**Branch coordination (gate before Phase C):** Before starting **Phase C**, confirm status of open branches / initiatives that touch the same WC surfaces (e.g. **`watch-complication-improvements`** or active complication work) against **`AppleWatchManager.swift`**, watch **`WatchState.swift`**, and **`TrioComplicationDataStore.swift`**. **Record** in the implementation log: agreed **merge order**, **paused** work, or explicit **rebase-after-partner** plan. **Phase C is blocked** until this coordination note exists **or** the log states that **no** conflicting in-flight PRs affect those paths as of the recorded date (with owner).

## Regression boundaries (explicit validation required)

The following **must not** regress relative to the **connectivity completion baseline** defined in the design doc (**Regression baseline** — commit anchors, code paths, and mandatory **Baseline row** in the implementation log).

**Not a substitute for:** jetsam / memory Path B validation (see `watch-launch-stability`); those tracks are **related** but **separate** product mechanisms unless a change touches shared code—then re-verify both as appropriate.

1. **Connectivity background tasks (WC scope):** `WKWatchConnectivityRefreshBackgroundTask` work must not be **stranded** (left uncompleted) after logical inbound processing when the refactor touches completion paths. **Note:** A **forced return to the clock face** can also be caused by **jetsam** / memory pressure (see `watch-launch-stability`); that mechanism is **out of scope** for WC-only regression checks—use device diagnostics (e.g. `JetsamEvent` vs connectivity logs) when a regression is suspected.
2. **Logical completion:** Task completion remains tied to **logical inbound processing** completion, including **deferred / quiet-window** finalization paths in watch `WatchState`.
3. **All inbound channels:** `didReceiveUserInfo`, `didReceiveApplicationContext`, and `didReceiveMessage` (with and without `replyHandler` on phone) maintain correct **completion** and **ACK** behavior — not only the `userInfo` path.
4. **Early returns:** Dedup, invalid payload, and “no-op” paths must **not** leave `pendingConnectivityTasks` non-empty without a scheduled terminal completion (same guarantees as today).

**Validation:** Each phase that touches watch inbound or completion must add or extend **device soak / scripted** checks (see tasks) and structured log markers to prove parity.

---

## Sequencing + ship boundaries

### Gate taxonomy (hard vs execution hygiene)

The plan uses many checkpoints so WC **correctness** is preserved. To avoid **process replacing product** — and to keep **important vs optional** rigor clear — only the items below are **hard gates** (do **not** advance past the named point **without** the artifact / log entry). Other bullets in tasks are **execution hygiene**: **required** deliverables for that phase, but **not** additional global stop-lines unless the task explicitly blocks the next phase.

| Class | What | When it blocks |
|-------|------|----------------|
| **Hard gate** | **Baseline row** (design § **Regression baseline**) in the [implementation log](#implementation-log) | Before large refactors / meaningful WC behavior change |
| **Hard gate** | **Task A3** target-placement decision | **Phase B** |
| **Hard gate** | **Task A2** minimal fixture bar + **Dependencies** branch coordination note | **Phase C** |
| **Hard gate** | **Queue contract** (**Task D1** / **E1** acceptance — verify in-tree; design does not assert the model) | Merging **Phase D** / **E** work that relies on threading assumptions |
| **Hard gate** | **Extended soak** criteria (**Phase E** section) | Declaring **Phase E** shippable / promoting past **E** |
| **Hygiene** | **Task A1** inventory table; **Task A2** invariant checklist + staged fixture backfill | Required Phase A deliverables; **not** separate global gates beyond the rows above |
| **Hygiene** | **`WatchStartupTransportGate`** **`delegate` / `subsume`** (Task A1 step 4 by end of Phase A) | Clarifies **Phase F2**; does **not** block Phases B–E |
| **Hygiene** | **Phase E rollback** procedure | Applies **if** soak fails — not a precondition |
| **Hygiene** | **Decode rejection log-only flag** lifecycle (C1/C2 → **Task G1**) | Phase C/G deliverables |
| **Hygiene** | Observability schema, **Task G1** grep cleanup | Phase norms |

**Principle:** The **implementation log** is **evidence** for reviewers and future maintainers; **code + tests** remain the **product**. Do not treat log checkbox completeness alone as “done.”

### Phase list

| Phase | Name | Shippable alone? | Notes |
|-------|------|------------------|-------|
| A | Inventory + preserved invariants | Yes | Docs + checklist only; no behavior change; **Task A3** gates Phase **B** |
| B | Contract extraction (keys + envelope types) | Yes | Prefer additive types; minimal call-site churn; **do not start** until **Task A3** log entry exists |
| C | Shared decode / validation layer | Mostly | **Gate:** **Task A2** **minimal fixture bar** + **Dependencies** branch coordination logged **before** starting C; staged fixture backfill allowed **during** C; behind feature flags only if decode tightening is not 1:1 behavior |
| D | Central inbound dispatch — **phone first** | Yes | Lower risk than watch; validates dispatcher pattern |
| E | Central inbound dispatch — **watch** | Yes | **Highest risk** — requires completion regression battery |
| F | Sender / transport policy consolidation | Yes | Outbound paths funneled through policy APIs |
| G | Cleanup, dead code removal, doc completion | Yes | Requires green soak + PASS reviews |

**Sequencing note:** Phone-before-watch minimizes risk to the **background task state machine** while still delivering value. If merge pressure forces watch-first, repeat Phase D/E acceptance on both sides regardless of order.

---

## Shared conventions

- This plan conforms to: `docs/process/standards-observability.md` for logging/metrics naming where new events are introduced.
- **Observability contract:** New and migrated logs should converge on the design doc’s **Canonical observability schema** (`event=wc_*` rows). Phase tasks below reference those names; do not invent parallel vocabularies without updating the design doc.
- **Dedupe ownership:** Phases **C–E** follow design § **Dedupe and idempotency ownership** — transport / ID bookkeeping stays in the **session outer layer** with the dispatcher; **domain** idempotency stays in handlers; **complication store** dedupe stays in **`TrioComplicationDataStore`**.
- **Gates:** See **[Gate taxonomy (hard vs execution hygiene)](#gate-taxonomy-hard-vs-execution-hygiene)** — not every “must” in a task is a **hard gate**.
- Plan-specific deviation: watchOS may remain **device-soak dependent** for full WC validation; document soak scripts in the implementation log when used.

---

## Phase A: Inventory + preserved invariants

**Ship gate:** Safe to ship alone (documentation + checklist).  
**Rollback:** N/A.

### Task A1 — Payload and transport inventory

- **Files (read / catalog):**
  - `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`
  - `Trio Watch App Extension/WatchState.swift`
  - `Trio Watch App Extension/WatchState+Requests.swift`
  - `Trio Watch App Extension/WatchLogger.swift`
  - `Trio Watch App Extension/WatchErrorReporter.swift`
  - `Trio Watch App Extension/Helper/WatchNotificationHandler.swift`
  - `Trio Watch App Extension/WatchConnectivityPayloadIds.swift`
  - `Trio/Sources/Models/WatchMessageKeys.swift`
  - `Trio Watch Shared/TrioComplicationDataStore.swift`
  - `Trio Watch App Extension/ExtensionDelegate.swift`
  - `Trio/Sources/Assemblies/ServiceAssembly.swift`
  - **File defining `WatchStartupTransportGate`** — exact path TBD at inventory time; **locate via grep** for `WatchStartupTransportGate` (expected under watch extension sources, e.g. `WatchLogger.swift` at time of writing).
- **Change:** Produce a **single inventory table** listing: payload family, direction, WC API(s), key(s), owning function(s), ACK/reply requirements, dedup keys.
- **Where to put it (default):** Append to the **[Implementation log](#implementation-log)** **after** the **Baseline row** (see below). Order: **(1)** Baseline row at kickoff, **(2)** this inventory table when Phase A1 completes. **Do not** create a separate inventory file unless the table becomes **unwieldy** (e.g. exceeds ~**40** rows, or needs heavy iteration that would drown the log—in that case add `watch-messaging-centralization-03-inventory.md` in this folder and **link it from the log** with one summary paragraph).
- **Steps (ordered):**
  1. Grep both targets for `sendMessage`, `transferUserInfo`, `transferCurrentComplicationUserInfo`, `updateApplicationContext`.
  2. Cross-check string keys not in `WatchMessageKeys`.
  3. Note watch **completion** touchpoints (`pendingConnectivityTasks`, deferred completion work items, quiet window) with line-span references.
  4. Document how **`WatchStartupTransportGate`** interacts with **outbound** sends (e.g. log flush / transport suppression). **Resolve** how **Phase F** relates to the gate: **`delegate`** (policy **calls / preserves** the gate — single owner for suppression semantics) or **`subsume`** (gate rules **move into** policy with a short **parity checklist**). Record a **dated** one-paragraph decision in the implementation log — see design § **Transport policy and `WatchStartupTransportGate`**. **Undecided** past **end of Phase A** is **not acceptable**.
- **Acceptance (verifiable):** Table reviewed; **no** “unknown major family” left unclassified; Garmin impact explicitly marked known/unknown; **`WatchStartupTransportGate` → Phase F** resolution is **`delegate`** or **`subsume`** with rationale (step 4).
- **Observability checks:** N/A (inventory).
- **Notes / pitfalls:** `AppleWatchManager.swift` filename vs `BaseWatchManager` type name — keep glossary in inventory to avoid agent confusion.

### Task A2 — Invariant checklist + prior-format payload fixtures (Phase C gate — minimal bar)

- **Files:** Prior `watch-launch-stability` artifacts if available; Better Stack queries per `docs/process/betterstack-guide.md` (optional for checklist); staging/device capture hooks as needed (**no PHI**).
- **Change:** (1) Checklist of **log patterns** that must remain present post-refactor (e.g. pending task counts, `reading_epoch`, transfer via markers). (2) **Prior-format payload fixtures** for Phase C **dual-read / tolerant-decode** acceptance, using a **minimal bar** so telemetry gaps do not stall the architecture work.
- **Steps (ordered):**
  1. Extract 5–10 canonical log substrings from current code; store in implementation log.
  2. **Minimal fixture bar (required before starting Phase C):** After **Task A1** inventory, produce **≥1** redacted **`[String: Any]`-shaped** fixture for each of the **three highest-regression inbound families** (default if inventory agrees: **watch state snapshot**, **ACK / payload-ID metadata**, **watch logs** — **adjust** if A1 marks a different top-three). **Or** explicit **N/A** with **owner** sign-off for a slot. **Preferred sources:** Better Stack / ClickHouse queries that recover **key sets**, nesting, and type **hints** **without** secrets (**no PHI**); else staging device / **debug-only** export.
  3. **Staged backfill:** Remaining families needed for full C1/C2 coverage may be captured **during** Phase C; log **owner**, **target milestone**, and **families pending** in the implementation log at Phase C start — **do not** block Phase C on full multi-family coverage once the **minimal bar** passes.
  4. Copy the **invariant checklist** into Phase E acceptance steps (reference by link/heading).
- **Acceptance (verifiable):** Checklist exists **and** **minimal bar** (step 2) is **met** or **N/A** with owner per slot. **Staged backfill** (step 3) is **logged** when Phase C starts. **Phase C is blocked** only until **minimal bar** + **Dependencies** branch coordination (see Phase C **Gate**) are satisfied — **not** until every family has a fixture.
- **Observability checks:** Confirm checklist queries return recent events in staging/production (as available).
- **Notes:** Do not log secrets; use category/message filters only. Fixtures are **telemetry-shaped test inputs**, not clinical records.

### Task A3 — Shared contract target placement decision

- **Files:** Xcode project / target membership for iOS app, watch extension, shared groups (inspect during task); no code change required for the decision record itself.
- **Change:** Before **Phase B** begins, **decide and record** in the **implementation log** whether shared contract types will live in a **new shared framework target** or as **duplicated files** per build-graph constraints (third option: existing shared target if one already fits—still must be named explicitly).
- **Steps (ordered):**
  1. Enumerate which targets must import each envelope / key registry.
  2. Prototype or reason about SwiftPM / Xcode target boundaries; pick one approach.
  3. Write the decision + rationale as a dated entry in the implementation log (one paragraph minimum).
  4. If the chosen approach requires a **new shared framework target**, **target membership** changes, or other **build-graph / Xcode project** edits, classify that work as **infra / build-system** (not product messaging logic alone). Record whether it must land as a **separate preparatory infra step** before Phase B/C product work, or may ship **bundled** with Task B1 (if bundled, record **why** the risk is acceptable).
- **Acceptance (verifiable):** Implementation log contains a **target-placement decision entry** before **Task B1** execution. **Phase B is blocked** until this acceptance passes. When step 4 applies, the log entry states **preparatory infra vs bundled** explicitly.
- **Observability checks:** N/A.
- **Notes:** If the decision changes mid-project, append a new log entry; do not silently diverge from the recorded choice.
- **Repo execution (build graph):** **Do not** hand-edit `Trio.xcodeproj/project.pbxproj`. Drive target membership and project structure by editing **`scripts/sync_project_files_config.rb`** (e.g. `TARGET_GLOBS`, `TARGET_BUILD_SETTINGS`) per fork **AGENTS.md**. **`scripts/sync_project_files.rb`** is run **during** the canonical local build (`ci/local-build.sh` — primary path in **`docs/process/feature-branch-workflow-optimization.md`**); **do not** run **`sync_project_files.rb`** manually. After config edits, updated **`project.pbxproj`** content lands when a **human- or explicitly-requested** build runs (per **AGENTS.md**, agents must not treat ad-hoc sync or Xcode CLI as the routine verification path). Treat any manual `pbxproj` edit as **out of process** unless an explicit exception is documented in the implementation log with owner approval.

---

## Phase B: Contract extraction

**Ship gate:** Yes, if changes are **additive** (new types/wrappers) and behavior-neutral.

**Gate:** Do **not** start Phase B until **Task A3** acceptance is satisfied (log entry exists).

### Task B1 — Envelope types (or equivalent) per family

- **Files:** New shared file(s) under a shared target or duplicated **only** if required by build graph (prefer single shared location if feasible); start with `Trio/Sources/Models/` + watch-accessible copy or shared framework — **decision recorded in log** (**Task A3**).
- **Change:** Define Swift types or `enum WatchMessageFamily` with associated metadata for each major inbound/outbound family.
- **Steps:**
  1. Start with **watch state** envelope (largest payload).
  2. Add treatment request envelope mirroring `WatchState+Requests` dictionaries.
  3. Add log / error / snooze envelopes.
- **Acceptance:** Unit compile on both targets; **no** behavior change yet (types unused or used only in `debug` asserts behind `#if DEBUG` if needed).
- **Observability:** N/A.
- **Notes:** Avoid renaming wire keys in this phase. If **Task A3** chose a **new shared target** or other **build-graph** work, complete any **preparatory infra** step recorded there **before** adding files that require the new graph; update **`scripts/sync_project_files_config.rb`** as needed — **do not** hand-edit **`project.pbxproj`** or run **`scripts/sync_project_files.rb`** manually (sync runs inside **`ci/local-build.sh`** per **AGENTS.md**).

### Task B2 — Key literal elimination pass (low risk)

- **Files:** `AppleWatchManager.swift`, watch sources using stray literals.
- **Change:** Move discovered literals into `WatchMessageKeys` or family-specific constants.
- **Acceptance:** Grep shows **no new** literals for the moved keys outside constants file.
- **Observability:** N/A.
- **Pitfalls:** Keys read from legacy clients must remain accepted (dual-read later in Phase C).

---

## Phase C: Shared decode / validation layer

**Gate:** Do **not** start Phase C until **Task A2** **minimal fixture bar** acceptance passes **and** **Dependencies** **branch coordination** is recorded. Full per-family fixture coverage may **follow** via **Task A2** staged backfill **during** Phase C.

**Ship gate:** Yes with **1:1** behavior parity; use temporary logging to compare pre/post decisions on device if needed.

### Task C1 — Phone inbound decoder

- **Files:** New `WatchPhoneInboundDecoder.swift` (name illustrative) colocated with watch manager services; wire from `BaseWatchManager` **without** changing external behavior.
- **Change:** Centralize type bridging + field presence checks currently inline in `session(_:didReceiveMessage:)` / `didReceiveUserInfo` / `didReceiveApplicationContext`. **Dedupe / processed-ID behavior** remains in the **outer** `BaseWatchManager` layer per design § **Dedupe and idempotency ownership** — decoder returns **discriminated decode results**, not transport dedupe.
- **Steps:**
  1. Move `watchLogs` string extraction into decoder.
  2. Move watch state nested dictionary validation into decoder returning optional `WatchState` / envelope.
  3. Keep **identical** branching for unknown types.
  4. Identify any key renames or coercion differences vs current behavior; for each, add a **tolerant-decode fallback** accepting the old form. Record the **dual-read table** in the implementation log.
  5. Compare **rejection** branches: if any **new** payload rejection path exists that was not present in the prior inline logic, wrap it behind a **structured-log-only** flag for the **initial soak** build; enable **enforcement** only after exit criteria below. At flag introduction, log **owner**, **removal milestone** (**Phase C follow-up PR** vs **Task G1**), and **start date**.
  6. **Flag exit (required):** **`no false reject`** on fixtures available from **Task A2** (**minimal bar** + any **backfilled** shapes) means **zero** decode rejects attributable to the **new** path when exercising those fixtures over **≥7 consecutive days** of staging soak **or** **two** consecutive internal TestFlight builds — **whichever completes first** — document **start/end** dates and build IDs in the implementation log. After criteria pass, **remove** the flag or default **enforcement on** in the **named** follow-up PR or **Task G1**; **no** open-ended flags without a dated extension approved in the log.
- **Acceptance:** Staging device test: send logs, bolus request, watch state update — **identical** functional outcomes. Send **prior-format** payloads using **Task A2** fixtures (and device paths as needed, **no PHI**); confirm **no decode reject**. **Error / crash reporting family:** meet the same decode verification as other families **unless** deferral is **explicitly recorded** in the implementation log per design § **Error / crash reporting family (implementation phase scope)** — in which case confirm pre-refactor **inline** decode paths for that family still run **unchanged** until the named follow-up phase. If a **log-only rejection flag** was used, confirm it is **removed** or **enforcement defaulted on** per step 6 **before** initiative close (**Task G1** if not done earlier).
- **Observability:** Emit `event=wc_decode_result` per the design schema (and optional `event=wc_inbound_received` upstream) — rate-limit if volume is a concern.
- **Pitfalls:** Do not tighten numeric/string coercion beyond today’s behavior.

### Task C2 — Watch inbound decoder

- **Files:** New watch extension file; integrate with `WatchState` `session` methods.
- **Change:** Same as phone for inbound watch state / ACK / ancillary messages. **Transport dedupe** stays with existing **session owner** state per design § **Dedupe and idempotency ownership**.
- **Steps:**
  1. (Mirror C1 step 4.) Identify any key renames or coercion differences vs current behavior; for each, add a **tolerant-decode fallback** accepting the old form. Record the **dual-read table** in the implementation log.
  2. (Mirror C1 steps 5–6.) Compare **rejection** branches; new rejections → **log-only** flag with **owner**, **removal milestone**, **exit criteria**, and **flag removal** same as C1.
- **Acceptance:** Device tests for `sendMessage` + `transferUserInfo` + `applicationContext` deliveries show same UI + complication snapshots. Send **prior-format** payloads per **Task A2** fixtures (**no PHI**); confirm **no decode reject**. If a **log-only rejection flag** was used, confirm removal / default enforcement per C1 step 6 **before** initiative close (**Task G1** if not done earlier).
- **Observability:** Preserve `📬` / `📦` style logs or supersede with structured equivalents **without** losing fields.
- **Pitfalls:** **Do not** move completion timing yet — decoder is pure.

---

## Phase D: Central inbound dispatch (phone)

**Ship gate:** Yes.

### Task D1 — `WCSessionDelegate` thin adapters

- **Files:** `AppleWatchManager.swift`; new `WatchPhoneInboundDispatcher.swift` (illustrative).
- **Change:** **Inbound payload** delegate methods (`didReceiveMessage` / `didReceiveUserInfo` / `didReceiveApplicationContext`) call `dispatcher.handle(message:context:)` where `context` carries transport enum (message vs userInfo vs context) and reply handler closure if present. The **dispatcher returns a typed completion contract per family** (`ACK required` / `reply required` / `none`); the **phone outer layer** (`BaseWatchManager`) **enforces** ACK dispatch for **ACK-required** families (do not bury ACK side effects inside the dispatcher in a way that bypasses the owner’s threading or queue rules). **Processed-ID / transport dedupe** stays in the **outer layer** per design § **Dedupe and idempotency ownership**. **Lifecycle / reachability** methods (`activationDidCompleteWith`, `sessionReachabilityDidChange`, `sessionDidBecomeInactive`, `sessionDidDeactivate`, etc.) stay in `BaseWatchManager` unless a separate refactor is justified — see design **Inbound dispatch scope**. Any **temporary** inbound logic left un-migrated in a phase must be **allow-listed** in the implementation log (per design **Migration / compatibility**).
- **Steps:**
  1. Extract per-family handler methods from monolithic delegate method bodies.
  2. Ensure `replyHandler` paths remain **exception-safe** (always reply).
  3. Preserve “do not send reverse transferUserInfo confirms for watchLogs” comment as **policy** in dispatcher.
- **Acceptance:** Unit tests where possible for decoder+dispatcher. **Device test** demonstrates at least one **ACK-required** and one **reply-required** family; **batched-ACK** sequences are included in the test script. **Error / crash reporting family:** same rule as design § **Error / crash reporting family (implementation phase scope)** and Task C1 — verify through the dispatcher **or** record deferral in the implementation log with a **named follow-up phase**; if deferred, confirm **inline** dispatch/handling for that family remains **behavior-identical** until that phase. **Queue contract:** **Verify** from **current Swift sources** (and optional runtime instrumentation) which **execution context** inbound `WCSession` callbacks use — **do not** assume a serial background queue without evidence. Implementation log contains a **Queue contract** note: observed behavior, which queue the **dispatcher** runs on (or explicit **MainActor** / cross-queue hops), and confirmation that **mutable shared state** access matches that contract (file + type pointers). Code review treats **unverified** threading assumptions as **acceptance failure**.
- **Observability:** `event=wc_inbound_received` + `event=wc_dispatch_started` / `event=wc_dispatch_completed` with `transport=` and `family=` per design schema.
- **Pitfalls:** **`WCSessionDelegate`** threading is a **correctness** surface — the **Queue contract** acceptance above is mandatory; the design **does not** assert Apple’s queue model.

---

## Phase E: Central inbound dispatch (watch) + completion integration

**Ship gate:** Yes **only** after **extended soak** (quantified below).

**Rollback:** If soak **fails** after Phase E merges: **revert** Phase E commits (restore **pre-E** `git` ref recorded in the implementation log at merge), **re-run** design **Regression baseline** checks + **Task A2** checklist queries, and **do not** land Phase F on top of a **known-bad** E. Document **revert SHA** and **reason** in the log.

### Task E1 — Dispatcher owns family routing; `WatchState` owns lifecycle

- **Files:** `WatchState.swift`; new `WatchInboundDispatcher` (watch) file.
- **Change:** Move switch/if chains from `session(_:didReceive...)` into dispatcher; **WatchState** retains `pendingConnectivityTasks` and calls dispatcher-provided **processing** closures. **Transport / payload-ID dedupe** stays with **WatchState** (session owner) per design § **Dedupe and idempotency ownership** — dispatcher routes; owner enforces early-return + completion invariants.
- **Steps:**
  1. Route `didReceiveUserInfo` / `didReceiveApplicationContext` / `didReceiveMessage` through dispatcher.
  2. Ensure **all** early returns call existing `completePendingConnectivityTasksIfNeeded`-style helpers (names per current code).
  3. **Do not** split completion across files without explicit ownership docstring.
- **Queue contract (watch):** Extend the **Task D1** **Queue contract** log entry (or add a watch subsection): **verify** from code/runtime which context watch inbound callbacks use; where the **dispatcher** runs; how **`pendingConnectivityTasks`** / completion helpers synchronize — **no assumed queue model** without evidence.
- **Acceptance:** **Regression battery** (manual script):
  - Background refresh delivers burst `userInfo` → tasks complete once after quiet window.
  - `applicationContext`-only delivery completes correctly.
  - `didReceiveMessage` delivery participates in completion rules where required.
  - Late task arrival after terminal path still rescued (if currently implemented — verify against code during task).
  - **Batched `userInfo` delivery** with **multiple ACKs** expected — confirm **all ACKs** dispatched and **no** pending connectivity tasks stranded.
- **Extended soak gate (required before Phase E is “shippable”):**
  - **Minimum** **72 hours** wall-clock on a **primary** test Apple Watch (dedicated device or agreed staging wearer) **after** E1 lands on the candidate branch.
  - **Minimum** **two** scripted **background connectivity** sessions (burst `userInfo`, `applicationContext`-first, `didReceiveMessage` as applicable) — **script** text or link **in the implementation log**.
  - **Pre-soak snapshot** at E merge: paste **Task A2** checklist query outputs + agreed **`event=wc_background_task_completed`** (or substitute) **volume / pattern** baselines into the log.
  - **Pass:** Post-soak, repeat the same queries — **no new** stranding / error spikes vs pre-soak baselines; scripted runs show **no** unexpected growth in stuck **`pendingConnectivityTasks`** behavior vs pre-E.
  - **Fail:** Any **confirmed** regression → **Rollback** (section header above) before promoting dependent phases.
- **Observability:** `event=wc_background_task_completed` with `pending_count_before` / `pending_count_after` and `completion_path`; compare to Phase A checklist.
- **Pitfalls:** Highest regression surface — prefer smallest diffs per PR.

---

## Phase F: Sender / transport policy consolidation

**Ship gate:** Yes.

### Task F1 — Phone outbound policy module

- **Files:** `AppleWatchManager.swift` (send paths around `sendMessage` / `transferCurrentComplicationUserInfo` / `transferUserInfo` / `updateApplicationContext`).
- **Change:** Extract “R1/R2/…” policy blocks into functions on `WatchTransportPolicy` with unit-testable inputs (reachability, budget, queue depth).
- **Acceptance:** Complication transfers still occur when expected; `applicationContext` safety net still triggers on budget exhaustion **as today**.
- **Observability:** `event=wc_policy_selected` with `via=` / `reason=`; preserve existing `via=sendMessage`-style detail inside `reason` or structured fields where helpful.

### Task F2 — Watch outbound policy wrappers

- **Files:** `WatchState+Requests.swift`, `WatchNotificationHandler.swift`, parts of `WatchLogger.swift` / `WatchErrorReporter.swift` that call WC.
- **Change:** Route through policy layer for `sendMessage` vs `transferUserInfo` selection; implement the **Task A1** logged resolution for **`WatchStartupTransportGate`** (**`delegate`** vs **`subsume`**) per design § **Transport policy and `WatchStartupTransportGate`**.
- **Acceptance:** Snooze path still tries `sendMessage` then falls back; log flush behavior unchanged. **`WatchStartupTransportGate` parity (required — see design § **Transport policy and `WatchStartupTransportGate`**):** For **`delegate`**, outbound policy **calls through** the gate (or equivalent) on every path that today consults it — **no** bypass of startup suppression / flush gating without a logged **parity** proof vs pre-F behavior. For **`subsume`**, complete the **parity checklist** from **Task A1** (startup suppression, flush timing) and mark **PASS** with device notes. Mismatch → **not shippable** until log-updated design sign-off.
- **Observability:** Confirm snooze + log flush logs still emitted.

---

## Phase G: Cleanup + documentation completion

**Ship gate:** Yes.

### Task G1 — Remove dead code / duplicate parsers

- **Files:** Prior touch list.
- **Change:** Delete inlined parsers superseded by decoder/dispatcher; ensure no duplicate keys.
- **Acceptance:** `swift build` / Xcode build for affected targets; grep for obsolete helpers = empty. **Grep** for `sendMessage([String: Any])` call sites **outside** the transport policy layer **since Phase F landed**; result must be **zero new** sites (**allow-listed** pre-existing sites **excluded** and **logged** in the implementation log). **Phase C decode flags:** Any **log-only** new-rejection flags from C1/C2 are **removed** or **enforcement defaulted on**, with **completion date** in the log — **unless** a **dated** extension with owner approval is recorded.
- **Observability:** N/A.

### Task G2 — Move initiative toward completion per `doc-lifecycle.md`

- **Files:** This folder; optionally move to `docs/completed/` when implementation log + reviews PASS.
- **Change:** Finalize design status; archive decision.
- **Acceptance:** Prompt 05 red-team complete if code landed.
- **Observability:** N/A.

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Background task regression | Phase E soak; keep PRs small; feature branch behind `watch-launch-stability` merges |
| Decode tightening rejects legacy payloads | Dual-read tables; fuzz tests with saved production dictionaries (no PHI) |
| Merge conflicts | **Dependencies** branch coordination gate before C; land smallest PRs; communicate with complication branch owners |

## Hypotheses / expectations (NOT acceptance)

- Central dispatcher will reduce time-to-diagnose WC issues in Better Stack by **consistent** `transport=` fields.
- Policy extraction may reveal **duplicate** `sendMessage` calls that can be coalesced later (optional follow-up).

---

## Implementation log

*(No implementation entries yet. Append decisions, PR links, soak results, and inventory tables here as work proceeds. **Order:** **(1)** **Baseline row** (design § **Regression baseline**) at implementation kickoff — branch/SHA/build and validation pointers — **before** large refactors land; **(2)** Phase A inventory table (Task A1), unless split per Task A1 rules; **(3)** **Task A3** target-placement decision **before** Phase B / Task B1; **(4)** **Task A2** invariant checklist + **prior-format fixtures** + **Dependencies** **branch coordination** note **before** Phase C.)*

---

## Changelog

### v1.11 (2026-04-08 09:31 CET)
- **Process weight (ChatGPT):** New § **Gate taxonomy (hard vs execution hygiene)** — **hard gates** (baseline, A3, A2 minimal + branch coordination, queue contract for D/E merge, E extended soak) vs **hygiene** (inventory, `WatchStartupTransportGate` decision for F2, rollback as-if-fail, C flag lifecycle, etc.); **principle** — log is evidence, code+tests are the product.

### v1.10 (2026-04-08 09:24 CET)
- **ChatGPT / Claude follow-up:** Design §3 **queue** wording — **verify and record**, no asserted `WCSession` queue model. **Design:** new § **Dedupe and idempotency ownership**; plan **Shared conventions** + **C1/C2/D1** reference. **Task A2** — **minimal fixture bar** (top-three families), **staged backfill** during C; Phase C **Gate** relaxed accordingly. **D1/E1** **queue contract** — evidence-based, not assumed. **F2** — explicit **`delegate`** “call through / no bypass” language (Claude gap).

### v1.9 (2026-04-07 23:00 CET)
- Post-review **M1–M4 / R1–R3:** **Task A2** now delivers **prior-format fixtures** (Better Stack / staging capture plan, **no PHI**) and **blocks Phase C** until met. **Task A1** step 4 + acceptance: **`WatchStartupTransportGate`** → Phase F **`delegate`** vs **`subsume`** (design § **Transport policy and `WatchStartupTransportGate`**); **Task F2** acceptance enforces parity. **Phase C** explicit **Gate**; **Dependencies** **branch coordination** before C. **Phase E** **Rollback** + quantified **extended soak** (72h, two scripted sessions, query baselines). **C1/C2** rejection **flag exit** (7d / 2 TF builds, owner, **G1** removal). **D1** + **E1** **queue contract** (watch extends D1 log). **G1** flag cleanup. Risks row ties merge contention to coordination gate.

### v1.8 (2026-04-07 22:28 CET)
- **Task A3 / B1 — build graph:** Corrected repo execution wording to match **AGENTS.md** and **`docs/process/feature-branch-workflow-optimization.md`**: edit **`scripts/sync_project_files_config.rb`** only; **`scripts/sync_project_files.rb`** runs **during** **`ci/local-build.sh`** — **do not** run sync manually; **`project.pbxproj`** updates apply on the next canonical human/explicit build (not ad-hoc agent sync).

### v1.7 (2026-04-07 22:26 CET)
- **F1:** **Task A3** — infra/build-graph classification, preparatory vs bundled step, **no hand-edit** of `project.pbxproj`, use **`scripts/sync_project_files_config.rb`** + **`scripts/sync_project_files.rb`** per **AGENTS.md**; **Task B1** note mirrors this when A3 implies a new target. **F2:** **C1** / **D1** acceptance aligned with design § **Error / crash reporting family (implementation phase scope)** (deferral + log + inline unchanged, or full verify). **F3:** *(design + idea carry baseline fallback; plan unchanged for F3.)*

### v1.6 (2026-04-07 22:15 CET)
- Pre-implementation review findings **F1–F7**: **A1** — `WatchStartupTransportGate` file (grep TBD) + outbound/policy note; **A3** — shared contract **target-placement** decision gates Phase B; **C1/C2** — **dual-read** table + prior-format acceptance + **rejection soak flag**; **C1** — error-report decode verified or deferred; **D1** — typed **completion contract**, outer-layer ACK enforcement, device/batched-ACK acceptance; **D1** — error-report dispatch verified or deferred; **E1** — batched userInfo + multiple ACKs acceptance; **G1** — `sendMessage([String: Any])` grep outside policy layer. Phase list / Phase B gate updated for A3.

### v1.5 (2026-04-07 14:25 CET)
- Pre-implementation doc review (prompt **03**): **Regression boundary #1** reworded to avoid conflating clock-face exit with WC-only causes; **Phase A1** + **Implementation log** ordering clarified (Baseline row first, then inventory); **Task D1** scoped to inbound `didReceive*` paths and lifecycle hooks called out per design **Inbound dispatch scope**.

### v1.4 (2026-04-07 10:50 CET)
- Review feedback: added **Prerequisites** (worktrees, branch/patch context, kickoff recording); tied **Regression boundaries** to design **Regression baseline**; **inventory placement rule** (log by default, `03-inventory` only if unwieldy); aligned phase observability bullets to design **canonical schema**; clarified jetsam vs WC scope at boundaries.

### v1.3 (2026-04-07 10:44 CET)
- Idea doc moved back to `docs/backlog/watch-messaging-centralization/`; header link updated to backlog path.

### v1.2 (2026-04-06 17:48 CET)
- File renamed with initiative prefix (`watch-messaging-centralization-02-implementation-plan.md`); design and idea links updated to sibling filenames; optional inventory filename aligned with initiative prefix.

### v1.1 (2026-04-06 17:41 CET)
- Implementation log left empty (placeholder only) before changelog, per repo workflow for pre-execution plans.

### v1.0 (2026-04-06 17:41 CET)
- Initial implementation plan: scope, regression boundaries, phases A–G with tasks (files, steps, acceptance, observability), phone-before-watch sequencing rationale.
