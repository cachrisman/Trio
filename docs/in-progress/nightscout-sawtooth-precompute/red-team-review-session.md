# Red-team review session — Nightscout sawtooth precompute docs

Run per `docs/prompts/nightscout-precompute-docs-prompt.md`. Exact workflow: baseline → Phase 1 (≥2 finding passes until convergence) → Phase 2 (edit pass) → Phase 3 (regression pass) → Final output.

---

## Baseline declaration

- **Branch / repo / baseline:** Trio-dev workspace; docs under `docs/in-progress/nightscout-sawtooth-precompute/`. Nightscout (cgm-remote-monitor) repo at `/Users/charliechrisman/Code/src/cachrisman/cgm-remote-monitor` used for repo-grounding.
- **Review scope:** Docs + repo structure (and referenced project docs). No existing sawtooth code in cgm-remote-monitor; design and implementation plan are the only spec.
- **Implementation plan basis:** Greenfield with repo conventions: plan is grounded in design doc, AGENTS.md, and verified Nightscout paths (`lib/server/env.js`, `lib/storage/mongo-storage.js`, `lib/server/bootevent.js`, `bin/` scripts). Implementation plan §3.1 cites these files; verified present and consistent.
- **Uncertainty:** Better Stack Query API actual response format (JSON vs TSV) not re-verified from external docs in this run; plan §8.1 says "lock to one format" and "prefer the format documented by the Better Stack Query API". Conclusions about that contract are docs-only until the implementer confirms the API’s response format.

---

## Phase 1 — Pass 1: Finding report

**Docs read:** Design `nightscout-sawtooth-precompute-service.md` (v1.13), Implementation plan `nightscout-precompute-implementation-plan.md` (v1.4).  
**Repo inspected:** `cgm-remote-monitor`: `lib/server/env.js` (storageURI, MONGODB_URI), `lib/storage/mongo-storage.js`, `lib/server/bootevent.js`, `bin/testdatarunner.js` (bin script pattern).  
**Project docs:** `docs/completed/betterstack/betterstack-complication-dashboard-setup.md` exists (design §2 reference). AGENTS.md hot/S3 and MCP usage referenced in plan.

### Finding P1-1

| Field | Content |
|-------|--------|
| **ID** | P1-1 |
| **Severity** | minor |
| **Location** | Implementation plan §7.1 (Phase 7: Cold start and backfill) |
| **Grounding** | Impl plan §7.1, §11 step 3. Docs only. |
| **Problem** | Phase 7.1 says "set `last_emitted_minute_epoch` in state file" and "State file missing or `last_emitted_minute_epoch: 0`". For MongoDB backend there is no state file; cold start is "no document" or doc with 0. Wording is file-centric and could mislead when using Mongo. |
| **Failure mode** | Implementer on Mongo backend might look for a "state file" to create for cold start instead of relying on loadState returning 0 and first run advancing. |
| **Why it matters** | Rollout §11 step 3 is already backend-specific; §7.1 should acknowledge both backends so cold-start behavior is unambiguous. |
| **Exact fix** | In §7.1, replace or extend with: "before first production run, set checkpoint so the first run is bounded: **file backend** — write state file with last_emitted_minute_epoch = floor(now/60)*60 - 3600; **MongoDB backend** — same value via mongosh upsert (see §11 step 3) or rely on cold start (0); prefer explicit init for bounded first run." Add one line: "State missing or last_emitted_minute_epoch = 0 (file or Mongo): cold start; prefer initializing as above." |
| **Validate** | Re-read §7.1 and §11 step 3; confirm both backends and cold start are covered. |

### Finding P1-2

| Field | Content |
|-------|--------|
| **ID** | P1-2 |
| **Severity** | nit |
| **Location** | Implementation plan §8.6 Push payload (metrics ingest) |
| **Grounding** | Impl plan §8.6, §7 table BETTERSTACK_INGEST_HOST. Docs only. |
| **Problem** | §8.6 says "**Endpoint:** `POST https://s2301525.eu-fsn-3.betterstackdata.com/metrics`" (hardcoded host). §7 table correctly says ingest host is from env with no default. Contract should not hardcode the host. |
| **Failure mode** | Copy-paste implementation could hardcode the host instead of using BETTERSTACK_INGEST_HOST. |
| **Why it matters** | Consistency with §7 and with "current known value in example only" principle. |
| **Exact fix** | In §8.6, change to "**Endpoint:** `POST https://${BETTERSTACK_INGEST_HOST}/metrics` (host from env; see §7). Example current value: s2301525.eu-fsn-3.betterstackdata.com." |
| **Validate** | Grep for hardcoded ingest host in plan; ensure only example shows the value. |

### Finding P1-3

| Field | Content |
|-------|--------|
| **ID** | P1-3 |
| **Severity** | minor |
| **Location** | Design §5 step 4; Design §8 (Risks) |
| **Grounding** | Design doc §5 step 4, §8 table. Docs only. |
| **Problem** | Design §5 step 4 says "If none, skip this minute (or treat as 0; see §8 Sparse GTL coverage)." Design §8 is "Risks (explicit)" and has a row "**Sparse GTL coverage**" with text "either skip that minute (gap) or emit 0. Skipping is safer…". So the cross-ref is correct but "§8 Sparse GTL coverage" is slightly ambiguous (§8 is the whole Risks section). |
| **Failure mode** | Low; reader can find the row. Optional clarity: reference the risk by name. |
| **Why it matters** | Precision of cross-references. |
| **Exact fix** | Optional: in §5 step 4 change to "see §8 (Risks) row **Sparse GTL coverage**" or leave as-is. Mark as nit if no edit. |
| **Validate** | Confirm §8 contains that row. |

### Finding P1-4

| Field | Content |
|-------|--------|
| **ID** | P1-4 |
| **Severity** | minor |
| **Location** | Implementation plan §10 Test plan — Cold start bullet |
| **Grounding** | Impl plan §10. Docs only. |
| **Problem** | "State file missing or `last_emitted_minute_epoch: 0`" — again file-centric. For Mongo, "no document" or document with 0 is the equivalent. |
| **Failure mode** | Test plan could be read as file-only for cold start. |
| **Why it matters** | Test plan should cover both backends for cold start. |
| **Exact fix** | Change to "Checkpoint missing or last_emitted_minute_epoch: 0 (file: state file missing; Mongo: no document or doc with 0); run with end_minute from now; verify no unbounded backfill. Prefer initializing checkpoint (file or Mongo per §11) before first run." |
| **Validate** | Re-read test plan; confirm file and Mongo both mentioned where relevant. |

### Pass 1 verdict

- **What was found:** Four items: two minor (P1-1 §7.1 cold start wording file-centric; P1-4 §10 test plan cold start file-centric), one nit (P1-2 §8.6 hardcoded ingest host), one nit (P1-3 §5→§8 cross-ref clarity; optional).
- **Next pass:** Pass 2 will re-read both docs for internal and cross-doc consistency, and for any missing design→plan or plan→design requirements; will also re-check the eight focus areas for anything Pass 1 missed.
- **Exit criterion:** Not yet met — need Pass 2; no blocker or major in Pass 1.

---

## Phase 1 — Pass 2: Finding report

**Focus:** Full re-read; design↔plan conformance; architecture correctness; algorithm and checkpoint semantics; rollout/observability; any finding introduced by or missed in Pass 1.

### Finding P2-1

| Field | Content |
|-------|--------|
| **ID** | P2-1 |
| **Severity** | nit |
| **Location** | Design §11 table — `lib/sawtooth-precompute/fetch-gtl-logs.js` row |
| **Grounding** | Design §11, Implementation plan §4 file tree, §8.1. Docs only. |
| **Problem** | Design says fetch-gtl-logs "parse rows into `{ gtl_epoch, data_age_seconds, is_off_wrist }`". Plan §8.1 and fetch contract say the query client produces `{ dt, message }[]`; parse-message and dedupe then produce the GTL list. So fetch-gtl-logs parses response → `{ dt, message }[]`, not directly to gtl_epoch/is_off_wrist (those come after parse-message + dedupe). Design is slightly oversimplified. |
| **Failure mode** | Implementer might try to make fetch-gtl-logs output gtl_epoch/is_off_wrist directly, conflating query client with parser+dedupe. |
| **Why it matters** | Fidelity of design to actual module boundaries in the plan. |
| **Exact fix** | In design §11 fetch-gtl-logs row, say "call Query API (env: …), return rows as `{ dt, message }`; parse and dedupe (parse-message, dedupe) produce `{ gtl_epoch, data_age_seconds, is_off_wrist }`." Or leave as-is and rely on plan as authoritative for module boundaries. |
| **Validate** | Plan §4 and Phase 2/3 are authoritative; design §11 is suggestion. Optional wording tweak. |

### Pass 2 verdict

- **What was found:** One nit (P2-1 design §11 fetch-gtl-logs row vs plan module boundaries). No new blocker or major. P1-1, P1-2, P1-4 are still valid; P1-3 optional.
- **Next pass:** Two consecutive passes (Pass 1 and Pass 2) have produced no new blocker or major. Pass 2 adds only a low-value nit. Exit criterion for Phase 1 is met: at least two full finding passes, two consecutive with no new blocker/major, and the later pass has at most a small number of low-value minors/nits.
- **Exit criterion:** Met. Proceed to Phase 2 (primary edit pass).

---

## Phase 2 — Primary edit pass

**Order:** Resolve by severity (blocker → major → minor → nit). No blocker/major from Phase 1. Resolve minors P1-1, P1-4; nits P1-2, P2-1 (and optionally P1-3).

**Planned edits:**

1. **P1-1 (minor):** Implementation plan §7.1 — add backend-aware cold start wording and "state missing or 0" for both backends.
2. **P1-2 (nit):** Implementation plan §8.6 — endpoint use `${BETTERSTACK_INGEST_HOST}` and note "example value" in text.
3. **P1-3 (nit):** Skip or minimal: design §5 step 4 cross-ref to §8 — leave as-is (already correct).
4. **P1-4 (minor):** Implementation plan §10 Test plan — cold start bullet: "checkpoint missing or 0" and "(file or Mongo)" plus reference §11.
5. **P2-1 (nit):** Design §11 fetch-gtl-logs row — clarify that fetch returns `{ dt, message }`, parse/dedupe produce GTL shape.

**Version/changelog:** Bump implementation plan to 1.5 and design to 1.14; add changelog rows for red-team edits.

**Edit pass completed.** Finding IDs resolved: P1-1 (§7.1), P1-2 (§8.6), P1-4 (§10 cold start), P2-1 (design §11 fetch-gtl-logs). P1-3 skipped (optional nit; cross-ref already correct). Deferred: none.

---

## Phase 3 — Regression pass

**Focus:** New contradictions from edits; cross-reference drift; version/changelog consistency; algorithm/rollout wording.

### Regression finding R3-1

| Field | Content |
|-------|--------|
| **ID** | R3-1 |
| **Severity** | minor |
| **Location** | Implementation plan §6 "Inputs (from env and state)" |
| **Problem** | After Phase 2, §6 still said "from state file; 0 or last pushed minute". Plan is backend-agnostic elsewhere; this line was file-centric. |
| **Fix** | Changed to "from state — file or Mongo; 0 or last pushed minute." |

### Regression finding R3-2

| Field | Content |
|-------|--------|
| **ID** | R3-2 |
| **Severity** | nit |
| **Location** | Implementation plan §9 Observability |
| **Problem** | "checkpoint file mtime for 'last success' signal" — no Mongo equivalent mentioned. |
| **Fix** | Changed to "checkpoint last update (file: mtime; Mongo: updated_at) for 'last success' signal." |

**Phase 3 verdict:** Two small regressions (backend-agnostic wording) found and fixed. No new blocker or major. Changelog 1.5 entry updated to include Phase 3 regression fixes. No further follow-up edit pass required.

---

## Final output

### Final status

- **Verdict:** **Clean with minor nits.** No blockers or majors. Minors and nits from Phase 1/2 were fixed; Phase 3 regression fixes applied.
- **Summary:**  
  - **Pass 1:** P1-1 (cold start §7.1 file-centric), P1-2 (§8.6 hardcoded ingest host), P1-3 (optional §5→§8 ref), P1-4 (test plan cold start file-centric).  
  - **Pass 2:** P2-1 (design §11 fetch-gtl-logs vs plan module boundaries).  
  - **Phase 2:** P1-1, P1-2, P1-4, P2-1 resolved; P1-3 skipped.  
  - **Phase 3:** R3-1 (§6 inputs), R3-2 (§9 observability) resolved.
- **Residual risks:** None beyond those already in §12 (empty GTL permanent gap, single writer, duplicate dt). Better Stack Query API response format (JSON vs TSV) remains "lock to one format" per docs; implementer must confirm from API docs.
- **Required doc updates:** All planned updates applied. Design v1.14; implementation plan v1.5.
- **Implementation impact:** None beyond what was already in the plan: cold start and test plan explicitly cover file and Mongo; push endpoint uses env var; design §11 aligns with plan module boundaries.
- **Unverifiable items:** Better Stack Query API actual response format and Accept/Content-Type behavior not re-verified from external docs in this run; plan correctly defers to "format documented by the Better Stack Query API."

### Final coverage attestation

| Area | Reviewed | Result |
|------|-----------|--------|
| Core architecture correctness | Yes | Pass — two-source model, Trio logs read-only, Prometheus sink, cron + standalone, checkpoint semantics intact. |
| Design ↔ implementation-plan conformance | Yes | Pass — plan preserves design; design §11 fetch-gtl-logs aligned with plan. |
| Better Stack source/query/ingest assumptions | Yes | Pass — correct source split, ingest from env, query contract in §8.1, no reliance on overwrite/dedupe. |
| Reconstruction algorithm correctness | Yes | Pass — emit ceiling, window, dedupe, ASOF, empty-GTL, checkpoint advance rules match design. |
| Checkpointing / idempotency / delayed-ingestion behavior | Yes | Pass — file + Mongo, lock required for file, single-writer for Mongo; atomic advance; emit delay in algorithm. |
| Nightscout repo fit | Yes | Pass — bin/ and lib/ pattern verified; env.js, mongo-storage.js, bootevent.js repo-grounded; no invented subsystems. |
| Logging / observability / validation | Yes | Pass — logging §9; observability backend-aware; test plan covers cold start and empty GTL for both backends. |
| Rollout / rollback / operational safety | Yes | Pass — rollout backend-specific (§11); rollback simple; lock and single-writer explicit. |
| Versioning / changelog / cross-references | Yes | Pass — design v1.14, plan v1.5; changelog updated; design reference in plan header v1.14. |

**Why further passes are unlikely to surface more than low-value nits:** Two full finding passes plus regression pass covered internal and cross-doc consistency, repo grounding, and all eight focus areas. Remaining nits would be stylistic or optional cross-ref wording (e.g. §5→§8). No open placeholders, no "see below" to missing sections, no overclaiming "validated" where uncertainty remains.

---

## Maintenance note (2026-03-20)

Shipped **cgm-remote-monitor** `run.js` logging differs from Phase 6 / §9 as written during this red-team session: there is **no** per-run `sawtooth-precompute start` line and **no** separate `gtl_rows=N` line before success. Instead, after checkpoint, a **single** `sawtooth-precompute pushed …` line carries pipeline counters, `minutes`, `end_minute`, and anchor / emit-delay fields. Use **implementation plan §9 (v1.13+)**, **design §7 (v1.16)**, **implementation log §14.7–14.8**, and **cgm-remote-monitor `lib/sawtooth-precompute/README.md`** as the authoritative description of the current log contract. The attestation table above reflects the **pre-shipment** doc set.

### Post-shipment semantic changes (2026-03-20 evening)

Several changes shipped after this review that affect the findings above:

- **Off-wrist semantics diverged from Explore:** `battery_state=unknown` is now treated as **on-wrist** (was off-wrist in the original design and Explore query). `battery_state=full` added as off-wrist. This affects design §4.2, §5, and this review's grounding in Explore semantics (§2). The change is intentional — `unknown` during provider restarts caused false zero periods.
- **Dynamic emit delay:** Fixed `emit_delay_seconds` replaced with rolling-max-based dynamic delay (design §4.5, implementation log §14.8). The algorithm pseudocode in design §10 still shows the fixed version but §4.5 now documents the dynamic mechanism.
- **Transient query retry:** `fetch-gtl-logs.js` retries once on transient network errors (implementation plan §5 Phase 2.1, implementation log §14.8).
- **New log fields:** `effective_emit_delay`, `data_horizon_lag`, `lag_window_max`, `lag_obs` on both `pushed` and `skip` lines.

These changes are documented in implementation plan v1.13, design v1.16, and implementation log v1.2 §14.8.
