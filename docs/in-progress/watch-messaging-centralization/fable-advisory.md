# Advisory: Watch / phone messaging centralization — readiness, sequencing, and execution routing

**Version:** v1.0
**Status:** Advisory (informational — no scope authority over design/plan)
**Created:** 2026-07-17
**Author:** Fable 5 (research/advisory session; no code changes, no commits)

**Design:** [watch-messaging-centralization-01-design.md](watch-messaging-centralization-01-design.md) (v1.9)
**Implementation plan:** [watch-messaging-centralization-02-implementation-plan.md](watch-messaging-centralization-02-implementation-plan.md) (v1.11)
**Idea (backlog):** [watch-messaging-centralization-00-idea.md](../../backlog/watch-messaging-centralization/watch-messaging-centralization-00-idea.md) (v1.7)

---

## Executive summary

This is **not a raw backlog item**. A heavily reviewed design (v1.9) and a phased implementation plan (v1.11, Phases A–G with hard gates) already exist; the implementation log is empty and no code has started. The design's core factual claims were **re-verified against today's tree** (`feature/watch-g7`) in this session and all hold. The single biggest decision is not architectural — the design already settles that well — it is **where and when the refactor lives**: the fork currently carries ~17k diff lines of watch patches over exactly the files this refactor would reorganize, and an upstream watch PR is in flight that deliberately excludes centralization. Starting now would maximize merge pain for minimum benefit. Recommendation: **hold until the upstream watch-G7 PR lands or is declared dead** (as `03-watch-feature-ideas.md` Tier 3 #7 already states), optionally cherry-pick the one cheap slice (envelope-literal elimination, plan Task B2) earlier, and when execution starts, route mechanical phases through the normal task-relay/cursor pipeline with frontier-model review reserved for Phases D/E diffs and the queue-contract verification.

---

## 1. Current state (verified 2026-07-17 against `feature/watch-g7`)

### Documents

| Artifact | Version | State |
|---|---|---|
| Backlog idea | v1.7 (2026-06-16) | Candidate proposal; records upstream precedent `a965e056b` |
| Design | v1.9 (2026-04-08) | Draft, multi-round reviewed (ChatGPT/Claude rounds in changelog) |
| Implementation plan | v1.11 (2026-04-08) | Draft; Phases A–G, gate taxonomy, empty implementation log |

Formal status per `doc-lifecycle.md`: **in-progress at design+plan stage, un-started on code**, and explicitly deferred by other initiative docs (see § 2 and § 4).

### Code (sizes and shape today)

- **Phone:** `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — 2,032 lines, `BaseWatchManager: WCSessionDelegate`. Four inbound payload methods; `didReceiveMessage:` (no reply handler) is ~160 lines with 10+ payload branches (envelope logs/errors, legacy logs/errors, `requestWatchUpdate`, snooze, bolus, carbs, combined meal, override activate/cancel, temp-target activate/cancel, bolus recommendation). Outbound watch-state snapshot uses **four transports** selected by reachability + complication budget + queue depth (`sendMessage` → `transferCurrentComplicationUserInfo` → `transferUserInfo` → `updateApplicationContext` safety net, lines ~826–908).
- **Watch:** `Trio Watch App Extension/WatchState.swift` — 2,668 lines. `didReceiveUserInfo:` is ~145 lines and owns pre-dispatch dedup, sleep-gap detection, and the quiet-window machinery (`pendingConnectivityTasks`, 300 ms debounce via `quietWindowWorkItem`/`finalizeWorkItem`, terminal completion in `completePendingConnectivityTasksOnMain`, 5 s late-task rescue in `handle(_:backgroundTasks:)`).
- **Other WC owners:** `WatchState+Requests.swift` (292 lines, eight watch→phone request senders), `WatchLogger.swift` (1,522 lines, includes `WatchStartupTransportGate` at lines 8–42, consulted at four send/flush sites), `WatchErrorReporter.swift`, `WatchNotificationHandler.swift` (snooze with `transferUserInfo` fallback), `TrioComplicationDataStore.swift` (watch→phone `complicationLastValidTimestamp` via `updateApplicationContext`).
- **Dedup/ACK:** phone keeps `processedIds` (UserDefaults dict, 100-entry cap, 7-day TTL) + `pendingAcks` (batch-ACKed when reachable); watch normalizes IDs via `WatchConnectivityPayloadIds` (String/NSString/UUID/NSUUID accepted, NSNumber rejected).

### Design claims re-verified — all confirmed

| April design claim | July 2026 verdict |
|---|---|
| Keys partially centralized; stray literals | **Confirmed, and worse than the doc's examples**: the *entire envelope/ACK protocol* is literals — `"type"`, `"payloadId"`, `"payloadIds"`, `"data"`, `"ackIds"`, `"pendingIds"` and type values `"watchLogs"`, `"watchError"`, `"ack"`, `"batchAck"`, `"queryAcks"`, `"watchLogConfirm"` — plus `"complicationLastValidTimestamp"` and `"context_updated_at"` |
| Inbound sprawl in `BaseWatchManager` / watch `WatchState` | Confirmed (sizes above; grown since April) |
| Four transports for watch-state snapshots | Confirmed |
| `WatchConnectivityPayloadIds` normalizes ID types | Confirmed |

### Drift since the design was written (April → July)

1. **The watch-g7 feature added a large watch-local stack but zero new WC surface.** `G7WatchSensorAdapter`, `WatchTelemetryRing`, `WatchGlucoseHistoryStore`, `WatchStateSnapshot` have **no** `WCSession` usage — direct-BLE readings stay on-watch. The only WC change is phone→watch G7 identity/sequence keys (`g7_active_sensor_name`, `g7_activation_epoch`, `g7_sequence`, `reading_epoch`) riding the existing snapshot, and these **were added to `WatchMessageKeys` properly**. There is **no watch→phone glucose reading path** today.
2. **`watch-launch-stability` moved to `docs/completed/`.** The design links it as an in-progress sibling (`../watch-launch-stability/`); that link is stale. The design's own fallback (Baseline row at kickoff is the operative anchor) covers this, but the link should be fixed at Phase A.
3. **File growth**: the two host files are now ~4,700 lines combined; Phase A line-span references in the plan will need re-anchoring (the plan itself anticipates this in Prerequisites).

### Pain points, restated with today's evidence

- **Envelope protocol has no single owner**: the dedup/ACK wire format — the part whose breakage has the worst failure mode (see § 4) — is the *least* centralized part of the system.
- **Transport policy exists only as inline comments** ("R1/R2/R4" blocks in `AppleWatchManager`); a new payload family gets its transport chosen by copy-paste.
- **Completion semantics are a distributed invariant**: every inbound early-return on the watch must individually remember to call the completion helper; the design correctly treats this as the #1 regression boundary.
- **Fork-maintenance tax (not in the design docs' problem statement, but real)**: patches 05, 06, 09 (~11.6k lines), 10, and 13 all touch this surface. Every upstream sync already pays a reconciliation cost over these files — the patch-clobber incident (`docs/process/patch-clobber-guardrails.md`) happened in exactly this territory (patch 13, `DeviceDataManager`/watch surface).

---

## 2. What "centralization" means here

The initiative is an **architectural follow-up** to the shipped connectivity-completion fixes: absorb the lesson structurally so the messaging layer stops re-growing fragmentation. Concretely (design §§ 1–5):

1. **Shared typed contracts** per payload family (watch state, treatment requests, logs, error reports, snooze, ACK metadata), replacing implied-by-usage dictionary shapes; single key registry.
2. **Shared decode/validation** per side — type bridging, required-field checks, discriminated known/unknown results — generalizing what `WatchConnectivityPayloadIds` already does for IDs.
3. **One inbound dispatcher per platform** — the `didReceive*` bodies become thin parse→dispatch adapters; handlers return a typed completion contract (ACK / reply / none) that the session owner enforces. Lifecycle/reachability callbacks explicitly stay out.
4. **Explicit transport policy layer** — the four-transport snapshot cascade and the snooze/log fallbacks become named policy decisions instead of inline branching.
5. **Typed sender APIs** — `WatchState+Requests` and phone send paths become facades over the policy layer.

Equally important is what it is **not**: not a generic WC wrapper that hides transport semantics, not a wire-format change (dictionaries stay; protobuf explicitly deferred), and not a re-fix of the forced-closure bug — that behavior is a **preserved invariant**, with the completion state machine and multi-channel parity as hard non-regression boundaries.

Upstream has independently validated the direction: nightscout/Trio's `a965e056b` (PR #1162) introduced a unified `handleIncomingWatchStatePayload(_:)` on watchOS — a ~5% slice of proposal point 3, on a simpler codebase. The fork deliberately did not adopt it during the dev-sync (its own receive path is a functional superset), but it is a clean reference point and a signal that upstream would likely be receptive to this class of refactor.

---

## 3. Recommended approach

### 3.1 The architecture is settled — don't redesign it

The design doc is unusually strong: it has survived multiple review rounds, refuses the tempting universal abstraction, keeps dedupe with session owners, demands in-tree verification of queue/threading assumptions rather than asserting Apple's model, and encodes the completion invariants precisely. **This advisory endorses it without architectural changes.** The remaining decisions are sequencing, placement, and execution routing.

### 3.2 The load-bearing decision: where the refactor lives

The refactor spans code owned by upstream (base `dev`) *and* by five fork patches. Three options:

- **(a) Upstream-first (recommended).** After the watch-G7 upstream PR resolves, propose centralization (or its phone-side slice) as upstream PRs, using `a965e056b` as precedent. The fork then inherits the structure at sync time and re-bases its patches once onto the new shape. This is the only option where the fork's per-sync tax goes *down* afterwards.
- **(b) Fork-first.** Do it on a feature branch → patch. Every subsequent upstream sync must reconcile upstream's evolving `AppleWatchManager`/`WatchState` against a fork that has *reorganized* those files — conflicts stop being line-level and become structural. Given the patch-clobber history, this materially raises the risk of exactly the silent-deletion failure mode the guardrails exist for. Only justified if upstreaming is abandoned.
- **(c) Hybrid slices.** Land the near-zero-risk, high-value slice early regardless of (a)/(b): **plan Task B2 (key-literal elimination)** extended to the envelope/ACK literals found in § 1. That is a mechanical constants extraction, behavior-identical, small diff, low patch-conflict surface — and it removes the most embarrassing drift. Everything from Phase C onward waits for the placement decision.

### 3.3 Sequencing (consistent with what the docs already say)

1. **Now:** nothing beyond (optionally) the B2 literal slice and doc hygiene (fix the stale `watch-launch-stability` link; re-anchor design inventory line references). The blocking conditions named in `03-watch-feature-ideas.md` Tier 3 #7 still hold: the upstream PR is in flight and `feature/watch-g7` is still mutating all three target files (build 219 planning is active).
2. **Trigger to start:** upstream watch PR lands or is declared dead, **and** `feature/watch-g7` reaches a quiet point (no in-flight build plan touching `WatchState`/`AppleWatchManager`). Record both in the implementation log as the branch-coordination gate (plan Dependencies).
3. **Phase A is now cheap:** this session's verified inventory (§ 1, plus the full transport-call-site table in the research below) is most of Task A1. Re-run the greps at kickoff to catch drift, then paste the table into the implementation log after the Baseline row. Task A3 (target placement) and the `WatchStartupTransportGate` delegate-vs-subsume decision remain genuinely open and need a human/owner call.
4. **Then follow the plan's order** — B (contracts) → C (decode) → D (phone dispatch) → E (watch dispatch + completion) → F (transport policy) → G (cleanup) — phone-before-watch, smallest possible PRs, with the plan's hard gates (Baseline row, A3, A2 minimal fixtures + branch coordination, queue contract, 72 h watch soak) unchanged.

### 3.4 Design decisions to hold firm on, and pitfalls

- **Dedupe stays with session owners** (design § Dedupe and idempotency ownership). The dispatcher routes; `BaseWatchManager`/`WatchState` keep processed-ID/ACK bookkeeping. Splitting this is the fastest route to a duplicate-treatment bug.
- **Queue contract is evidence-based.** Do not let any executor assume `WCSession` callback threading; verify in-tree and record (plan D1/E1). Treat unverified threading claims in review as acceptance failure — this repo has a documented history of "from-memory" enum/behavior misreads (CLAUDE.md verification discipline).
- **Decoder is pure in Phase C** — no completion-timing movement until Phase E. The 300 ms quiet-window debounce and the 5 s late-task rescue are behavior, not incidental detail.
- **Reply-handler exception safety**: every `didReceiveMessage:replyHandler:` path must always reply, including post-refactor error paths.
- **Watch state snapshot keys are dual-read territory**: legacy clients in the field during rollout; keep tolerant decode with fixtures (Task A2 minimal bar: watch-state snapshot, ACK/payload-ID metadata, watch logs).
- **New files in patches**: if execution happens fork-side, any phase adding files (decoders, dispatchers, policy modules) must regenerate patches with `--extra-files` and verify the `Files in patch: N` count — the known silent-drop failure mode.
- **`watch-to-phone-reading-backfill` interplay**: that backlog idea is the one initiative that would add a genuinely new inbound family on the phone (watch-sourced EGVs, with dedup/ordering/trust questions). If it is wanted soon, centralization-first turns it into a clean typed family; backfill-first adds another ad-hoc `[String: Any]` path that Phase C/D must then absorb. Sequence deliberately, don't let them interleave.

---

## 4. Effort and risk assessment

### Size

Engineering effort (focused agent/engineer time, excluding soak/build wall-clock):

| Phase | Estimate | Notes |
|---|---|---|
| A | 0.5–1 day | Inventory largely done (this session); fixtures from Better Stack + A3/gate decisions |
| B | 1–2 days | Envelope types + literal elimination; additive, behavior-neutral |
| C | 3–5 days | Two decoders, dual-read tables, log-only rejection flags; 7-day flag soak runs in parallel |
| D | 2–3 days | Phone dispatcher + queue-contract verification + device ACK/reply/batched-ACK script |
| E | 3–5 days | Watch dispatcher + completion integration; **mandatory 72 h device soak + regression battery** |
| F | 2–3 days | Transport policy extraction both sides + `WatchStartupTransportGate` parity proof |
| G | 1 day | Dead-code removal, flag cleanup, grep gates |

Total: roughly **2–3 weeks of engineering**, but **4–6+ weeks calendar** — the critical path is soak gates and the fork's TestFlight build cadence, not code. Diff footprint: reorganizing ~4,700 lines across the two host files plus ~6–10 new modules. If fork-side, add per-build patch-regeneration overhead and a permanent increase in upstream-sync reconciliation cost (§ 3.2).

### What breaks if done wrong (severity-ordered)

1. **Treatment-path regression (safety-critical).** Bolus/carbs/override/temp-target requests flow through the exact `didReceiveMessage` branches being refactored, and the processed-ID dedup is what prevents a re-delivered request from being enacted twice. A dedup or decode regression here is not a UX bug; it is a dosing-safety bug. This is why decode must stay 1:1 and dedup must not move.
2. **Stranded background tasks** → watch app returns to clock face / stops updating in background: the original forced-closure symptom this codebase already paid to fix. Any early-return that forgets terminal completion reintroduces it. Phase E's soak gate is the defense; do not weaken it.
3. **Complication freshness regression** — the budget/transport cascade encodes hard-won behavior (complication-freshness initiative, shipped build 144); the policy layer must transplant it verbatim, not "clean it up."
4. **Silent decode rejects of legacy payloads** during mixed-version rollout — mitigated by dual-read + log-only rejection flags + fixtures.
5. **Patch-stack structural conflicts** (fork-side execution only) — the guardrail tooling (`patch-audit.sh`) catches safety-path deletions, but a reorganized file layout raises the baseline conflict rate for every future sync.

### Safe sequencing summary

Hold now → B2 literal slice (optional, cheap) → wait for upstream PR + g7 quiet point → Phase A re-anchor with this session's inventory → phone before watch → smallest PRs → hard gates as written. The plan's own gate taxonomy is sound; nothing needs adding, and nothing should be waived.

---

## 5. Is Fable the right tool for implementation?

**Mostly no for execution; selectively yes for verification.** Reasoning:

- **The frontier-judgment work is already done or front-loaded.** The design and plan are the product of many review rounds and are written to be executor-proof (explicit gates, acceptance criteria, files, even grep commands). The open judgment calls that remain — target placement (A3), `WatchStartupTransportGate` delegate-vs-subsume, fork-vs-upstream placement (§ 3.2) — are decisions for the human owner, informed by this advisory, not token-heavy model work.
- **Phases B, C, F, G are Sonnet-appropriate** (or, per this project's standing workflow, task-relay with cursor as executor): mechanical extraction against precise specs, with `patch-test.sh` and the plan's grep-based acceptance checks as guardrails. Spending Fable tokens on envelope-type extraction is waste.
- **Where Fable-level capability earns its cost** (three narrow spots):
  1. **Phase D/E diff review against the invariants** — adversarial verification that every early-return still reaches terminal completion, ACK/reply contracts hold on all paths, and dedup ownership didn't drift. This is exactly the subtle, cross-file, failure-mode-oriented reasoning where a stronger reviewer pays for itself, and the failure cost (dosing safety, stranded tasks) is asymmetric.
  2. **The queue-contract verification (D1/E1)** — reading the actual concurrency structure of `BaseWatchManager`/`WatchState` and stating the evidence-based threading contract. Past incidents in this repo came from plausible-but-wrong concurrency/enum assumptions.
  3. **Phase E integration design detail** — the dispatcher-vs-`WatchState` split of the completion machinery, if the executor's first cut looks awkward.
- **Suggested routing:** human owner makes the § 3.2 placement call → Sonnet/cursor executes phase-by-phase off the plan → Fable (or `/code-review` at high effort) reviews the C, D, and E diffs against design § "Forced-closure fix: preserved invariants" before each merge → soak gates as written. Budget-wise that concentrates frontier tokens on the ~15% of the work where wrongness is expensive and hard to see.

---

## Appendix: session research provenance

- Docs read in full: design v1.9, implementation plan v1.11, backlog idea v1.7; initiative survey across `docs/in-progress/` and `docs/backlog/` (watch-g7-direct-ble-observer, watch-to-phone-reading-backfill, complication-freshness, notif-complication-refresh, upstream-pr-packaging 02/03, dev-sync-branch-cleanup, trio-fable5-review §533).
- Source verified on `feature/watch-g7` (Trio worktree): full transport-call-site inventory (phone lines ~827/850/865/902/923/1062/1290/1342; watch `WatchState+Requests` 26–259, `WatchErrorReporter` 375/401, `WatchLogger` 263/696/750/1317/1372, `WatchNotificationHandler` 87–93, `TrioComplicationDataStore` 875), both `WCSessionDelegate` conformances, completion machinery (`completePendingConnectivityTasksOnMain` ~1759, `finalizePendingData` ~2021, quiet-window ~1461–1486, BGTask handling ~2500–2567), dedup/ACK stores, `WatchMessageKeys` (75 lines, read fully), `WatchStartupTransportGate` (`WatchLogger.swift` 8–42).
- Patch stack: `grep '+++ b/'` over `patches/*.patch` — watch-surface patches are 05, 06, 09 (11,617 lines), 10, 13.
- Line numbers are anchors as of this date; re-verify at Phase A kickoff per plan Prerequisites.

---

## Changelog

### v1.0 (2026-07-17)
- Initial advisory: current-state verification of the April design against the July tree (all claims confirmed; envelope/ACK literals worse than documented; watch-g7 added no new WC surface; `watch-launch-stability` link stale), placement analysis (upstream-first recommended), effort/risk assessment (2–3 weeks engineering, 4–6+ weeks calendar; treatment-path dedup named as highest-severity failure mode), and execution routing (Sonnet/cursor for mechanical phases, frontier review for C/D/E diffs and queue contract).
