# Fusion Workflow Fit Assessment — wf-001 (Trio Feature) & wf-002 (Build Cadence)

**Version:** v1
**Status:** Assessment (evidence-required)
**Created:** 2026-07-12
**Assesses:** the two workflow SKETCHES in [`fusion-integration-proposal.md`](fusion-integration-proposal.md) — §2 "Workflow A — Trio Feature" (**wf-001**) and §3 "Workflow B — Build Cadence" (**wf-002**) — against Trio-dev's real development pattern as practiced in watch-g7 builds ~207–218.

> **State check (confirms the brief):** `fn_workflow_list` returns only `builtin:*` ids (coding, coding-ideas, quick-fix, review-heavy, stepwise-coding, design, pr-workflow, brainstorming, …). Neither wf-001 nor wf-002 exists as a live Fusion workflow — they are the §2/§3 sketches only. Fusion's model registry (`fn_models_list`) holds **1062** models across `anthropic`, `zai`, `openrouter`, `grok-cli`, `groq`, `deepseek`, `google`, `mistral`, `xai`, … — a real multi-provider panel is available for the review fan-out.

---

## Method — how this assessment was produced (multi-model fan-out + credit)

Three independent passes, each a different model driving its own read of the corpus, then reconciled here. Fusion's registry is what a production panel would draw from; concrete ids for the lanes appear in the build-spec appendices.

| Pass | Model (this run) | Fusion-registry analog | Lens | What it uniquely caught |
|---|---|---|---|---|
| A | Claude Opus 4.8 | `anthropic/claude-opus-4-8` | wf-002 lifecycle & correctness | Gate-0/G1–G5 exists in **only one build** and is **per-task + multi-valued**, not a global GO/NO-GO; the readout is a **log→plan two-document handoff**; incident-insertion build 218; A/B/C arms + instrumentation-gated ideas have no edge in a 4-node loop. |
| B | Claude Sonnet 5 | `anthropic/claude-sonnet-5` (2nd independent Claude lane) | wf-001 artifact + review-contract fidelity | The cited "PASS/PATCH contract" file **never contains the token PASS** and conflates **three** contracts; the 00→04 artifact chain matches **none** of the three real naming patterns; fix-and-update default collides with a review-gate; report-only is a **separate file**, not a toggle. |
| C | Claude Haiku 4.5 | `zai/glm-5.1` or `openrouter/deepseek-v3.2` (cheap breadth lane) | Settings / verify / patch-topology breadth | Independently **confirmed** §1/§5/§6/§9 are accurate against `feature-branch-workflow-optimization.md`, `patch-clobber-guardrails.md`, AGENTS.md — the mechanics half of the proposal has no material mismatch. |

Reconciliation note: A and B never contradict; they cover different halves (wf-002 lifecycle vs wf-001 artifacts). C's "no mismatch on settings" is the load-bearing negative result — it tells us the proposal's *plumbing* is right and its *process modeling* is where the gaps are. All three passes' load-bearing citations were re-verified by hand against source before inclusion (Gate-0 block, 218 S-0, 209 Section A, the separate `03-…log.md` file).

---

# wf-001 — "Trio Feature" (the 5-step pipeline)

## 1. Plain summary

A per-feature, linear, human-gated pipeline whose five nodes carry the `docs/prompts/01–05` prompts: **Design Review → Create Plan → Pre-Impl Doc Review → Execute → Red-Team Review**, with a human approval gate between every step, an explicit "merge disabled" terminal, on-disk versioned docs (`00-feasibility/01-design/02-implementation-plan/03-implementation-log/04-postmortem`) as the source of truth, review nodes encoding a "PASS/PATCH + 4-severity" contract, and verification restricted to `patch-test.sh` + static review (never a build, never a commit to `dev`). It is meant to be reused *inside* each wf-002 build cycle.

## 2. Node-by-node match matrix

| Node (proposal §2) | Real pattern step (citation) | Fit | Note |
|---|---|---|---|
| **Design Review** — `01-design-doc-review` (≥2 adversarial passes, self-review, verdict clean/nits/needs-revision), human approve | `01-design-doc-review.md:25` "at least 2 full passes; 3+ for … high-risk"; verdict `:145` "clean / clean with minor nits / needs revision"; but the initiative has **one** `01-design.md` (2026-04-24) reused across ~30 builds, cited only as an architecture touchstone (`build209-impl-plan.md:87-88`), **not** re-authored per build; `grep "design doc"` in build207/215/216/217/218 plans → **0 hits** | **partial** | Node & prompt are faithful, but there is no per-cycle design doc to review in the dominant pattern. Node runs ~once per *initiative*, not per build. |
| **Create Plan** — `02-create-implementation-plan` writes `02-implementation-plan.md` with an *empty Implementation log section* | `02-…from-design.md:64,79` "Include the **Implementation log** section (empty) … at the end, **before** the Changelog"; real plans are per-**build** (`build215-impl-plan.md`, `build217-impl-plan.md`), drafted from the **predecessor build's log + fresh telemetry**, not from a design (`build218-impl-plan.md:5` "Predecessor: build 217 … Full record: …build217-impl-log.md") | **partial** | Prompt matches; the *unit* is wrong — a "plan" is one build's task set, keyed to its predecessor, not to a design doc. |
| **Pre-Impl Doc Review** — `03` (3-phase finding→edit→regression; design is source of truth), human PASS | `03-…doc-review.md:62` "runs in **three phases**. Do not collapse them"; `:44-53` design-as-source-of-truth conflict rule; `:210` verdict "clean / … / not clean" | **gap** | Two problems: (a) verdict is **not** "PASS" (see property b); (b) design-as-source-of-truth has **no live design doc** to anchor to for most builds (property a). The 3-phase internal loop is flattened to one node (property c). |
| **Execute** — `04` code in `Trio` worktree, updates **in-plan** impl log; verify = patch-test/static, no build, no commit-to-dev | `04-execute-implementation-plan.md:44-45` log "must live **in the implementation plan document itself**"; `:98` "must not use `xcodebuild` … Verification = static review, `patch-test.sh`"; `:79` "Do not commit unless the user explicitly instructs" | **match** | The single strongest-fitting node. Worktree split, in-plan log, no-build verify, no-commit all confirmed. |
| **Red-Team Review** — `05` (≥3 passes, cross-patch type-resolution check), human PASS → in-review | `05-…red-team.md:43` "at least **3 full review passes**"; `:71` cross-patch type-resolution (Foundation shadowing); `:196` verdict "clean / … / not clean"; real multi-model practice already exists — `build207-…impl-plan.md:6` "second-model `ollama-task review` found no real bugs (2 false positives, verified)" | **partial** | Prompt & cross-patch check faithful; verdict vocabulary wrong (property b); multi-pass loop flattened (property c). |
| **~~Merge~~** — disabled; human runs patch scripts + build + verify-live, moves docs to `completed/` | `build217-impl-log.md:115` "Patches 02 + 09 remain **uncommitted** on `dev`; the milestone commit waits for build+deploy+verify-live"; `build210-impl-log.md:146,151` "DEFERRED to an attended session … warrant **human review**" | **match** | Correctly models "done = in-review + PASS; human does integration." |

## 3. Property readout (wf-001 lens)

### (a) Doc-artifact fidelity — **GAP (blocker-class)**
The proposal maps nodes 1:1 to `00-feasibility → 01-design → 02-implementation-plan → 03-implementation-log → 04-postmortem` (the `doc-lifecycle.md` "Standard artifact set"). The grounding initiative uses **none** of that chain end-to-end. Three coexisting real patterns, none matching:

1. **Current prompt convention (02/04):** the impl **log is a section inside the plan**, not a `03-*.md` file — `02-…from-design.md:79`, `04-…plan.md:44-45`. This already contradicts the proposal's separate "03-implementation-log" node.
2. **Earliest instance (Apr 2026):** a genuinely separate `watch-g7-direct-ble-observer-03-implementation-log.md` (own header, `v5`) beside `…-02-implementation-plan.md` which has **no** Implementation-Log section (`grep -i "implementation log" …-02-…plan.md` → **no match**). Matches the literal `00-04` numbering but contradicts the current prompts.
3. **Dominant convention (builds 187, 190–218):** per-build `buildNNN-impl-plan.md` + `buildNNN-impl-log.md` pairs — a *third* scheme.

`00-feasibility.md` and `04-postmortem.md` are **never created** in the folder (`ls | grep -iE 'feasib|postmortem'` → none; they exist only as unused `docs/templates/*` and `docs/prompts/others/postmortem.md`). A workflow whose artifact graph is `00→01→02→03→04` would, every cycle, either block on artifacts that never get made or force the executor to fabricate them. **This is the initiative the proposal names as its evidence base** (proposal header cites "builds 215/216/217").

### (b) PASS/PATCH contract + 4-level severity — **PARTIAL → GAP on the contract, MATCH on severity**
- **4-level severity: MATCH.** `blocker/major/minor/nit` is genuinely uniform and cross-referenced across `01:61`, `03:149-156`, `05:114-121`. Encode it verbatim.
- **PASS/PATCH + "max 5 issues/pass": GAP (conflation of three contracts).** The proposal (`fusion-integration-proposal.md:57`) attributes "`PASS` or exact `PATCH` blocks, max 5 issues/pass" to `review-patch-protocol.md`. But that file is a **bespoke one-off** watchOS-complication reviewer ("You are reviewing an implementation plan for a watchOS complication freshness / WidgetKit observability system", line 1); it contains "Max 5 issues per pass; highest severity first" (`:57`) and "PATCH" (`:59`) but the **token `PASS` never appears in it**. The real contracts are three distinct things:
  - `doc-lifecycle.md:60-63` — the generic **PASS-or-issues+patch loop** ("Repeat until reviewer returns `PASS`").
  - `review-patch-protocol.md:57,59` — a **5-issue-capped PATCH** format, from one feature's prompt.
  - `01/03/05` — **unbounded, multi-pass adversarial** reviews whose verdicts are `clean / clean with minor nits / needs revision|not clean` (`01:145`, `03:210`, `05:196`) with **no max-5 cap anywhere**.

  Hard-coding "emit PASS, cap at 5 issues" onto the 01/03/05 nodes would make them produce a token they never emit and impose a cap they explicitly lack.

### (c) Human gate between every step + verify = patch-test/static — **PARTIAL**
- **Verify discipline: MATCH.** No-`xcodebuild`, no unsolicited `local-build.sh`, no commit-to-`dev` confirmed at `04:98`, `05:110-112`, `04:79`, and AGENTS.md rules 10/11. Proposal §1/§5 encode this correctly (Pass C found **no** mismatch).
- **Gate shape: two collisions.**
  1. **Multi-pass loops flattened.** Each review node is internally a *loop-until-exit* (01 ≥2 passes; 03 = 3 non-collapsible phases, Phase-1 runs "until two consecutive passes produce no new blocker or major", `03:68-72`; 05 ≥3 passes). The sketch's one "node → human PASS" hides this; if a Fusion node can't loop internally it must be modeled as N looping sub-nodes + a `step-review`/`gate`, not one node.
  2. **Reviewer nodes *edit*, they don't gate.** The default for 01/03/05 is **fix-and-update**, not report-then-approve — `README.md:12` "fix-and-update is the default … Review-only … is opt-in"; `01:10`; `05:10`. And report-only for 03 is a **separate prompt file** (`03-pre-implementation-doc-review-report-only.md`), not a runtime flag. A "reviewer gate that also mutates the artifact and self-terminates on an internal verdict" is a different node shape than a PASS/PATCH hand-off gate; the sketch doesn't reconcile them.

## 4. Fixes

### 4a. Redlines to `fusion-integration-proposal.md`

**§2 intro sentence.**
- *Before:* "Custom workflow whose nodes carry `docs/prompts/01–05` as node prompts, with **human gates between each**:"
- *After:* "Custom workflow whose nodes carry `docs/prompts/01–05` as node prompts, with **human gates between each**. **Each review node (Design Review, Pre-Impl, Red-Team) is an internal fix-and-update loop, not a single pass** — model it as a looping sub-node region that runs the prompt's mandated passes (01: ≥2, 3+ high-risk; 03: 3 non-collapsible phases to two-clean-consecutive; 05: ≥3) and self-terminates on the prompt's own verdict before parking for the human gate. **Reviewers edit the artifact by default (fix-and-update); report-only is opt-in and, for 03, is a distinct prompt (`03-…-report-only.md`).**"

**§2 table rows — replace the artifact assumptions.**
- *Before (Create Plan row):* "→ writes `02-implementation-plan.md` with empty `Implementation log` section"
- *After:* "→ writes the build/feature plan (`buildNNN-impl-plan.md` in the dominant per-build pattern, or `02-implementation-plan.md`) **with the Implementation-log as a section inside that plan doc** per `04:44-45` — there is no separate `03-implementation-log.md` node."

**§2 — new note under the table (artifact reality).**
- *Add:* "**Artifact caveat.** The real initiative uses per-**build** plan+log pairs keyed to the *predecessor build*, not a per-feature `00→04` chain; `00-feasibility.md`/`04-postmortem.md` are typically never created, and a single `01-design.md` is reused as an architecture touchstone across many builds. Do not gate the workflow on a fresh design doc per cycle. When wf-001 runs inside a build cycle (wf-002), the **Design Review and Create-Plan nodes are optional/skippable**; the usual entry point is Pre-Impl review of a plan drafted from the predecessor log + soak evidence."

**§2 — replace the review-contract paragraph.**
- *Before:* "Encode the **PASS/PATCH contract** (`review-patch-protocol.md`: `PASS` or exact `PATCH` blocks, max 5 issues/pass, highest-severity first) and the **4-level severity** (blocker/major/minor/nit) as reviewer node config."
- *After:* "Encode the **4-level severity** (blocker/major/minor/nit — uniform across `01/03/05`) and each prompt's **native verdict vocabulary** (`clean / clean with minor nits / needs revision|not clean`) as reviewer node config. Do **not** impose a literal `PASS` token or a `max 5 issues/pass` cap on the 01/03/05 nodes — those come from `doc-lifecycle.md`'s lightweight doc-review loop and a one-off feature prompt (`review-patch-protocol.md`) respectively, not from the deep-review prompts. If a lightweight doc-review lane is wanted, add it as a *separate* node type carrying the `doc-lifecycle.md` PASS/PATCH loop."

**§10 "What to explicitly disable" — add.**
- *Add bullet:* "❌ hard-coding a `PASS` verdict or a 5-issue cap onto the 01/03/05 review nodes (verdict is `clean/nits/needs-revision`; passes are unbounded)."

### 4b. Fusion build-spec appendix (wf-001) — `fn_workflow_*` terms

```
fn_workflow_create name="Trio Feature (wf-001)" ir.version=2
```

**Settings (typed declarations; values set per-project via `fn_workflow_settings`):**
| id | type | default | purpose |
|---|---|---|---|
| `severityScale` | enum(multi) | `blocker,major,minor,nit` | shared 4-severity; injected into every review node prompt |
| `verdictVocab` | enum | `clean / clean-with-nits / needs-revision` | forbids a `PASS` token on deep-review nodes |
| `designReviewPasses` | number | 2 | 01 min passes (raise to 3 for high-risk) |
| `preImplPhases` | enum | `finding,edit,regression` | 03 three non-collapsible phases |
| `redTeamPasses` | number | 3 | 05 min passes |
| `reviewerMode` | enum | `fix-and-update` | vs `report-only`; 03 report-only swaps prompt file |
| `verifyCmd` | string | `scripts/fusion-verify.sh` | patch-test + static; non-zero on xcodebuild |

**Columns (traits from `fn_trait_list`):** `backlog` → `feature-active` → `in-review` → `done(manual-integration)`. Set project `autoMerge=false`, `planApprovalMode=require-all` via `fn_settings_update`.

**Artifacts (`ir.artifacts`, declared but OPTIONAL — none force-required):**
`01-design` (role: reference, optional), `plan` (key=`impl-plan`, producedBy=`create-plan`), `impl-log` (role: **section-of** `impl-plan`, not a standalone artifact). Do **not** declare `00-feasibility`/`04-postmortem` as required.

**Nodes / edges (kinds per IR):**
- `start` → `optional-group{design}`:
  - `n_design_review` kind=`prompt` (01) → self-loop `rework` edge (bounded by `designReviewPasses`) → `ask-user` gate `g_design`.
  - `optional-group` so the whole design lobe is skippable when wf-001 nests in a build cycle.
- `n_create_plan` kind=`prompt` (02) → `hold` `g_plan` (parks for approval).
- `n_preimpl` kind=`prompt` (03) with an internal `loop` region (`finding→edit→regression`, `rework` edges, exit on two-clean-consecutive) → `step-review` → `ask-user` `g_preimpl`.
- `n_execute` kind=`prompt` (04) → `code` verify step running `verifyCmd` (config: `blockXcodebuild=true`) → (no gate; produces in-plan log).
- `n_redteam` kind=`prompt` (05) with `loop` region (≥`redTeamPasses`, `rework` edges) → `step-review` → `ask-user` `g_redteam` → moves card to `in-review`.
- `exit-gate` `n_merge_disabled` kind=`hold` (manual): human runs `mid-stack-update.sh`/`repin-g7.sh`/`patch-test.sh`/build/verify-live. **No `pr-merge`/`merge-attempt` node** (autoMerge off).

**Per-node model lanes (`fn_workflow_settings` per-phase):** review nodes → panel: `anthropic/claude-opus-4-8` (correctness/lifecycle) + `anthropic/claude-sonnet-5` (independent) + a breadth lane `zai/glm-5.1` or `openrouter/deepseek-v3.2`; execute node → single strong model.

---

# wf-002 — "Build Cadence" (soak review + ideation; research lane)

## 1. Plain summary

A cyclic, per-build, telemetry-gated outer loop that runs a research/analysis lane (no worktree, no code): **Soak Review** (read BetterStack evidence, produce a Gate-0/G1–G5 GO/NO-GO readout, human decides) → **Ideas Gathering** (a governed Fable-5 ideation research run, checkpoint-first) → **Select** (human ranks survivors; each becomes a build-plan task feeding wf-001) → **Soak Review of build N** (a scheduled/queued follow-up that reads acceptance off telemetry → GO/NO-GO, "closing the loop"). Its stated premise is that *done ≠ verified*: acceptance is measured on the *next* soak, so it must be a two-task ship→later-soak-review pattern, with a do-not-repeat memory (`egv-intervention-index.md` + per-build graveyard).

## 2. Node-by-node match matrix

| Node (proposal §3) | Real pattern step (citation) | Fit | Note |
|---|---|---|---|
| **Soak Review** — "Evidence base + Gate-0 (G1–G5) readout" via BetterStack MCP → human GO/NO-GO | Real gate exists **verbatim in one build**: `build217-impl-plan.md:19` "## Gate 0 — Build-216 soak readout"; rows `:25-29` labeled **G1–G5**. But it is **per-task** ("G1 … **Task 1 (W-1 stage 2)** ships only if …", `:25`) and **multi-valued** ("GO"; "premise confirmed"; "modest upside … keep but low priority"; "Does **not** kill Task 4", `:39-43`). The same function appears under **different schemas**: `build209-impl-plan.md:59` "Section A — Soak-gated decisions" rows **A1–A5**; `build207-…plan.md:31` "Build-206 telemetry verdict". Readout is authored in the prior **log** (`build216-impl-log.md:58`) and transcribed into the next **plan** (`build217-…plan.md:33-45`). | **partial** | Concept real and central, but "Gate-0 (G1–G5) → one GO/NO-GO" mis-models it three ways: per-task not per-build; multi-valued not binary; log→plan two-doc handoff not one node output. See property (a). |
| **Evidence base** (part of Soak Review) | `build216-impl-plan.md:25` "## Evidence base (build 215 soak, BetterStack, 8-day window, sensor DXCMyu, n=1)"; `build217-…plan.md:51`; every plan opens with real funnel numbers | **match** | Plans genuinely open with a soak-evidence section with numbers before proposing work. |
| **Ideas Gathering** — `fable5-egv-ideation-prompt.md` as governed research run, **checkpoint-first** | `fable5-egv-ideation-prompt.md:17` "**Checkpoint first — before proposing anything, stop and report back for confirmation:** (a) restate the hard-constraints … (b) top 3 telemetry signals … Wait for the go-ahead"; adversarial self-cull "~8 of 10 fresh ideas die on contact" `:15` | **match** | Checkpoint-first and adversarial cull are faithful. Output appends to the build plan (`:72`), not a standalone doc. |
| **Select** — human ranks survivors → each becomes a build-plan Task feeding wf-001 | Survivors ranked & culled: `egv-intervention-index.md:138-152` "Candidate pool — VALIDATED … 8 of 10 culled"; but a build ships **multiple co-shipped arms** and **instrumentation to unblock next round** (`build217-…plan.md` co-ship Tasks 1–4; `build216-impl-plan.md:129-170` per-idea "blocked on 216-A/B" flags) | **gap** | "Select → one build-plan task" can't express: (i) N arms in one build, (ii) instrumentation shipped in build N whose only job is to unblock ideas in N+1, (iii) an idea downgraded to diagnostic-only (`build216-…plan.md:203`). See property (c). |
| **Soak Review (build N)** — scheduled/queued follow-up reads acceptance → GO/NO-GO, "closes the loop" | Deferred acceptance confirmed: `build216-impl-log.md:68` "W-1 stage 2 is **GO for 217**"; `build218-impl-plan.md:5` "Its EGV-capture pass/fail verdicts (Tasks 1–4) **need the ≥2–3 day soak — they are NOT part of 218**"; `build216-impl-plan.md:95` "## Open questions (**carry into soak review**)" | **match (with caveat)** | Two-task ship→later-soak is real. Caveat: the "later soak review" IS the next build's Gate-0 — so this node and the first node are the **same recurring artifact**, one build shifted. |
| *(missing)* incident-driven insertion build | `build218-impl-plan.md:7` "S-0 — a **CRITICAL** fork safety fix … **caused a real CGM blackout**"; `:13` "gate Task-2/4 off the iPhone primary path" — inserted *outside* the Ideas→Select path because a 217 ship caused an incident | **gap** | The soak of build N can emit an **incident** that forces a hotfix build; the 4-node loop has no edge for it. See property (c). |

## 3. Property readout (wf-002 lens)

### (a) Telemetry-gated Gate-0 (soak-review → GO/NO-GO before next-build work) — **PARTIAL**
The *intent* is real and is the spine of the process: no next-build task ships until the prior soak is read (`build217-…plan.md:7` "each gated on a specific 216 soak signal … nothing ships on a hypothesis the data has already killed"). But the sketch's "Gate-0 (G1–G5) → human GO/NO-GO" is wrong in three concrete ways the evidence forces:
1. **Per-task, not per-build.** Each gate binds to one task's ship decision (`build217-…plan.md:25-29`). A build ships the subset of tasks whose gates say GO — it is a **gate matrix**, not one build-level verdict.
2. **Multi-valued, not binary.** Verdicts include "premise confirmed", "modest upside, keep but low priority", "Does not kill Task 4" (`:39-43`). A boolean GO/NO-GO destroys the "keep but sequence later / low priority" outcomes the humans actually write.
3. **Not a stable schema, and authored across two docs.** "G1–G5" is build-217 vocabulary; 209 used "A1–A5", 207 used a prose "telemetry verdict". The numbers originate in build N's **impl-log** and are transcribed into build N+1's **plan**. Modeling it as one node's structured output over-specifies a count that varies and hides the log→plan handoff.

**Verdict: partial.** Keep the telemetry-gated-before-next-work spine; replace "single GO/NO-GO" with a **per-task gate matrix** whose cells are an enum (`go / hold-sequence-later / low-priority / premise-confirmed / killed`), sourced from the prior build's log.

### (b) Human gates / no autopilot — **MATCH**
Fully supported. Patches left uncommitted until build+deploy+verify-live (`build217-impl-log.md:115,140`); builds/TestFlight human-run; deferrals to "attended session" (`build210-impl-log.md:146,151`); co-ship scope is an explicit "user decision" (`build217-impl-plan.md` Gate-0 attribution note). Proposal §1 (`autoMerge=false`, `planApprovalMode=require-all`) and the "Fusion never merges to `dev` / never runs iOS builds" principle encode this correctly (Pass C: no mismatch). This is wf-002's strongest property.

### (c) Deferred verification (done ≠ verified) — **PARTIAL; the hardest, and the sketch can express only the simple half** ⚠️
This is the property the brief flagged as hardest, so it is called out explicitly. The **basic** two-task pattern IS expressible and IS real: build N ships a task; build N+1's Gate-0 reads its acceptance (`build216-impl-log.md:68` GO-for-217; `build218-impl-plan.md:5` verdicts "NOT part of 218"). A `notify`/scheduled follow-up soak-review task closes that. **But three real behaviors break a naive "ship-task → one deferred soak-review-task" model:**

1. **The deferred review is not a fresh task — it is the next cycle's Soak-Review node.** Acceptance for build N's tasks is a *subset of build N+1's Gate-0 matrix*. So "ship-task" and "later-soak-review-task" are not 1:1; one soak-review evaluates the union of *all* arms shipped in the prior build **and** produces the go/no-go for the *next* build's candidate tasks. The follow-up is a **fan-in over many prior ship-tasks**, not a paired partner of one.
2. **Acceptance can be "not decidable yet, defer again."** `build216-impl-plan.md:203` downgrades W-2 to diagnostic-only; Task C is "deferred to 217, **gated on W-7's soak**" (`build216-impl-log.md:14,54`) — i.e. a verdict of "still can't tell, carry forward." A binary close-the-loop can't represent a verdict that re-defers.
3. **Instrumentation-first cycles invert the dependency.** Build N frequently ships *only instrumentation* whose acceptance is "did it let us classify the failure mode?", which then *unblocks ideas* for N+1 (`build216-impl-plan.md:129-170` "blocked on 216-A/B"; `build217-…plan.md:222` "216's instrumentation … IS the next EGV step"). The "acceptance" of an instrumentation ship is measured as *ideation unblocking*, not an EGV-success delta — a different acceptance type than the sketch's "reads acceptance metrics → GO/NO-GO".

**Verdict: partial.** The sketch names the pattern (good — most proposals miss it entirely) but models it as a clean pair. Reality is a **fan-in soak-review that emits a per-task gate matrix with a re-defer state**, plus an **instrumentation→ideation dependency edge** the linear loop lacks.

### (extra) Do-not-repeat memory — **MATCH (mechanically real)**
`egv-intervention-index.md` is exactly the graveyard the proposal wants: "Rejected / Prohibited — DO NOT re-propose without new evidence" (`:111`), a culled candidate pool (`:138-152`), and the fable5 prompt makes reading it step 1 and mandatory (`fable5-egv-ideation-prompt.md:20` "This is your do-not-repeat list"). Storing it as Fusion memory or requiring the ideation node to read it on-disk both satisfy the intent.

## 4. Fixes

### 4a. Redlines to `fusion-integration-proposal.md`

**§3 table — Soak Review row.**
- *Before:* "**Soak Review** | Evidence base + Gate-0 (G1–G5) readout | research/analysis task … outputs the readout; **human GO/NO-GO**"
- *After:* "**Soak Review** | Evidence base + a **per-task gate matrix** (the recurring soak-readout; labelled G1–Gn / A1–An / prose across builds — the count is not fixed) | research/analysis task (BetterStack MCP) that **reads the prior build's impl-log readout** and emits, per candidate task, a verdict in `{go, hold-sequence-later, low-priority, premise-confirmed, re-defer, killed}`; **human ratifies the matrix**. Not a single build-level GO/NO-GO."

**§3 table — Select row.**
- *Before:* "**Select** | rank survivors → candidates | human picks; each becomes a build-plan Task feeding Workflow A"
- *After:* "**Select** | rank survivors → candidates | human picks a **co-ship bundle** (often several arms + instrumentation) that becomes **one build's** plan feeding Workflow A. A selected item may be **instrumentation whose acceptance is 'unblocks next-round ideas', not an EGV delta**; label it so its deferred review checks the right thing."

**§3 table — Soak Review (build N) row.**
- *Before:* "**Soak Review (build N)** | deferred acceptance check | a scheduled/queued follow-up task that reads acceptance metrics off telemetry → GO/NO-GO. Closes the loop."
- *After:* "**Soak Review (build N)** | deferred acceptance check | **this is the next cycle's Soak-Review node**, not a separate paired task: it **fans in** over *all* arms shipped in build N and emits both their acceptance and the next build's candidate-task gates. Acceptance may be **re-deferred** ('still can't tell — gate on the following soak'). One soak-review ≠ one ship-task."

**§3 — add a row for incident insertion.**
- *Add:* "**Incident hotfix (unscheduled)** | a soak that surfaces a regression/incident | a build inserted **outside** Ideas→Select (e.g. build 218 S-0, a CRITICAL fork fix after a real CGM blackout, `build218-impl-plan.md:7`). Model as an edge from Soak-Review → a priority build-plan task, bypassing Ideas Gathering."

**§Preamble (deferred-verification paragraph) — sharpen.**
- *After the existing text, add:* "Concretely: the 'later soak-review task' is a **fan-in** — one soak-review evaluates every arm the prior build shipped and simultaneously gates the next build's candidates. Its verdict set is not binary: it includes **re-defer** (carry acceptance to the following soak) and **premise-confirmed-but-sequence-later**. Instrumentation ships are a special case whose acceptance is *ideation unblocking*, not a success metric."

### 4b. Fusion build-spec appendix (wf-002) — `fn_workflow_*` terms

```
fn_workflow_create name="Build Cadence (wf-002)" ir.version=2   # research lane: no worktree, no code
```

**Settings:**
| id | type | default | purpose |
|---|---|---|---|
| `gateVerdict` | enum(multi) | `go, hold-sequence-later, low-priority, premise-confirmed, re-defer, killed` | per-task gate cell values (replaces boolean GO/NO-GO) |
| `soakMinHours` | number | 44 | min soak before a readout is valid (n=1 directional) |
| `checkpointFirst` | bool | true | ideation must checkpoint before generating candidates |
| `graveyardPath` | string | `…/egv-intervention-index.md` | required reading for the ideation node |
| `betterstackSource` | string | `1659391 / t491594.trio` | BetterStack MCP source (token via Fusion secret ref) |

**Custom fields (`ir.fields`, on each task card):** `arm` (enum, e.g. `A/B/C`), `acceptanceType` (enum: `egv-delta | instrumentation-unblock | battery | telemetry`), `gatedOnSoak` (build id), `killSwitch` (bool — mirrors the real `@AppStorage` per-arm kill-switches, `build217-…plan.md` Gate-0 note).

**Columns:** `soak` → `ideas` → `selected` → `building`(hands to wf-001) → `shipped` → `awaiting-soak` (loops back to `soak`). `ideas` is a backlog-style column (borrow `builtin:coding-ideas` traits).

**Nodes / edges (kinds):**
- `start` → `n_soak_review` kind=`prompt` (BetterStack MCP; reads prior build's log) → emits a **gate-matrix artifact** (one row per candidate task, cell ∈ `gateVerdict`) → `ask-user` `g_soak` (human ratifies).
- `n_soak_review` --`condition=incident`--> `n_hotfix` kind=`prompt` → hands directly to wf-002's `building` column (bypass ideation). Models build-218-class insertions.
- `g_soak` → `n_ideas` kind=`prompt` (fable5 prompt; config `checkpointFirst=true`, `requiredReading=[graveyardPath]`) → `ask-user` `g_checkpoint` (restate constraints + top-3 signals; wait) → continues to candidate generation.
- `n_ideas` → `n_select` kind=`ask-user` (human picks a **co-ship bundle**; sets `arm`/`acceptanceType`/`killSwitch` fields) → for each selected task, spawn a wf-001 run (`fn_task_create workflow_id=<wf-001>` in `building`).
- After ship: `notify`/scheduled node `n_await_soak` places the card in `awaiting-soak`; a **`rework` edge** `n_await_soak → n_soak_review` closes the loop — the *same* Soak-Review node fans in over all arms next cycle (do **not** create a separate "soak review build N" node; it is the recurring node one build later).
- No `code`/`pr-*`/`merge` nodes anywhere (research lane).

**Model lanes:** `n_soak_review` and `n_ideas` → `anthropic/claude-opus-4-8` (reasoning over telemetry) with a second independent lane (`anthropic/claude-sonnet-5`) for the adversarial cull; breadth lane optional.

---

# Cross-workflow note — does wf-001 nest inside wf-002 cleanly?

**Mostly no — two boundaries collide, one cleanly, one not.**

1. **Artifact boundary (collides).** wf-002's unit of selection is *one arm of one build*, and its plan is `buildNNN-impl-plan.md` drafted from the predecessor **log**, not a design doc (`build218-impl-plan.md:5`). wf-001's first two nodes (Design Review, Create-Plan-from-design) assume a per-feature `01-design.md` that, in the cadence loop, does not get re-authored per build (`grep "design doc"` in the recent build plans → 0). So when wf-001 nests, its Design-Review and Create-Plan nodes are usually **skipped**, and the real entry point is **Pre-Impl review (03) of the co-ship plan**. The fix (wf-001 §4a: wrap the design lobe in an `optional-group`) is what makes the nesting hold; without it, the nested pipeline blocks on a missing design artifact every cycle.

2. **Verification / human-gate boundary (collides on timing).** wf-001's terminal is "done = in-review + PASS; human integrates." wf-002's premise is "done ≠ verified; acceptance is the *next* soak." These are **two different definitions of done at two different time scales**, and they must not be conflated: a wf-001 run can legitimately reach `in-review`/PASS (static + patch-test clean) while its wf-002 acceptance is still **weeks and one soak away**. The nesting is clean only if the wf-001 PASS is explicitly *not* wired to any wf-002 acceptance gate — the `awaiting-soak` column and the deferred fan-in soak-review are what keep them separate. If someone later "optimizes" by treating wf-001 PASS as build acceptance, the loop silently loses its deferred-verification discipline — the exact failure the proposal's preamble warns about (`fusion-integration-proposal.md:27`).

3. **What nests cleanly:** the execution + red-team half (04/05 → in-review, no build, no commit) drops straight into wf-002's `building` column with no boundary friction — it is the strongest-fitting part of both workflows.

**Bottom line.** The proposal's *plumbing* (settings, verify wrapper, worktree/patch topology, safety-path audit, no-AI-attribution — §1/§5/§6/§9) is accurate and needs no change (Pass C). The gaps are all in *process modeling*: wf-001's artifact chain and review-contract don't match the real docs (two blocker-class fixes), and wf-002's Gate-0 and deferred-verification are real-but-under-modeled (per-task multi-valued gate matrix + fan-in re-deferrable soak-review + incident/instrumentation edges). Apply the redlines and the two build-specs are ready to instantiate with `fn_workflow_create` when the team moves past the sketch stage.

---

## Changelog

### v1 (2026-07-12)
- Initial assessment. Multi-model fan-out (Opus/Sonnet/Haiku independent passes) reconciled into per-workflow node matrices, property readouts, redlines, and `fn_workflow_*` build-specs. Grounded in `docs/prompts/01–05`, `doc-lifecycle.md`, `review-patch-protocol.md`, `patch-clobber-guardrails.md`, `feature-branch-workflow-optimization.md`, `egv-intervention-index.md`, `fable5-egv-ideation-prompt.md`, and watch-g7 build 207–218 plans/logs. Key findings: wf-001 artifact chain matches none of three real patterns and the cited PASS/PATCH contract conflates three sources (blocker-class); wf-002 Gate-0 is per-task/multi-valued/log-authored not a single GO/NO-GO, and deferred verification is a fan-in re-deferrable soak-review, not a clean ship→review pair. Proposal §1/§5/§6/§9 mechanics confirmed accurate.
