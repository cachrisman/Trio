# Pre-Implementation Doc Review (Report-Only + Agent Handoff)

**Version:** 1.0  
**Status:** In Use  
**Created:** 2026-03-23 09:25 CET  
**Last updated:** 2026-03-23 09:25 CET  

---

Red-team review a **set of feature documents** for consistency, completeness, and implementability. **Do not edit the source documents.** Your deliverables are a **findings report**, a **consolidated list of what should change**, and a **ready-to-paste prompt for an AI coding agent** that will apply those document edits later.

Your job is to find real defects: internal contradictions, gaps between documents, missing implementation decisions, repo-fit issues, rollout hazards, and observability gaps — not to be polite.

Treat this as adversarial review of docs that may look complete while still being inconsistent, underspecified, or not actually buildable.

## Non-negotiable: source documents stay read-only

- **Do not** modify, rewrite, or “fix” the provided source files in place.
- **Do not** suggest the user replace files outside of the report unless they explicitly asked for file output elsewhere.
- All remediation lives in the **report**, the **recommended changes** section, and the **implementation-agent prompt** you generate at the end.

## Inputs

The user may provide **either**:

### A) A small document set (typically two or three files)

Common patterns:

- **Ideas doc** (optional) — exploration, options, constraints, rough sketches.
- **Design doc** — authoritative technical design for the feature.
- **Implementation plan** — steps, sequencing, acceptance checks, rollout.

Other related specs (architecture notes, rollout checklist, API sketches) may be included; treat them as part of the set.

### B) An epic archive (e.g. a zip)

A single archive containing **multiple modules**. For each module, the user may include the same kinds of files as in (A): optional ideas doc, design doc, implementation plan, plus any module-specific supplements.

**Epic-level expectations:**

1. Build a **module inventory** (name, purpose, and which files belong to which module).
2. Review **within each module** the same way you would for (A).
3. Add an **epic pass**: cross-module dependencies, ordering, shared terminology, duplicated or conflicting decisions, observability and rollout coherence across modules.

**Ideas doc vs design:** When both exist, treat the **design doc** as the specification for what should be built unless the user’s instructions say otherwise. Use the ideas doc to catch **orphaned requirements**, **silent scope creep**, or **unresolved options** that appear in the plan without a design decision.

## Inputs (continued)

The user may also supply:

- **Optional: project-specific instructions** — constraints, architecture rules, or “must verify” items. If none are given, focus on the generic checks below.

You must verify:

1. **Technical soundness** — Each doc is internally consistent and technically plausible.
2. **Design–plan alignment** — The implementation plan faithfully operationalizes the design; nothing required by the design is missing or weakened in the plan, and nothing in the plan contradicts or silently expands the design. (When an ideas doc is present, also check that exploratory content is not accidentally treated as decided.)

## Baseline declaration

Before starting Pass 1, state:

- The **branch / repository / baseline** being reviewed (e.g. default branch, feature branch, or “documents only”).
- Whether the review is **docs only**, **docs + code**, or **docs + repository structure**.
- Whether the implementation plan is **greenfield** or **partially grounded** in existing repository conventions.
- Any **baseline uncertainty** that makes a conclusion conditional.

When verifying **repository fit** or inspecting structure (e.g. in Phase 1), use the **implementation plan’s Prerequisites** (branch context explored) as the baseline when available, so checks match the context the plan was written against.

If the baseline is mixed or incomplete, say so and mark conclusions that depend on missing context as **conditional** or **unverifiable**.

## Conflict resolution rule

Treat the **design doc** as the higher-level specification and the **implementation plan** as the execution plan.

When the two conflict:

- Treat the **design doc** as the source of truth unless there is clear, justified evidence that the implementation plan intentionally supersedes it.
- **Flag the discrepancy** as a defect.
- Do **not** silently narrow requirements in the implementation plan to make them easier.
- Do **not** assume the design doc should be weakened unless the text genuinely supports the change.

Also flag:

- Implementation details **required by the plan** but **absent from the design**.
- Design **requirements present in the design** but **missing or contradicted in the plan**.

## Required workflow

The review runs in **three phases**. Do not collapse them.

### Phase 1 — Finding passes (no edits to source)

Run at least **two full finding passes**. Pass count is not a formality: do not restate prior findings just to satisfy pass count; each pass must add new scrutiny, confirm specific resolutions, or identify remaining proof gaps.

Continue until:

- At least two full finding passes have been completed, and
- Two consecutive passes produce **no new blocker or major** findings, and
- The later pass produces at most a small number of low-value minor findings.

Each pass must:

1. Read all documents in scope fully (all modules if an epic).
2. Check **internal consistency** within each document.
3. Check **cross-document consistency** (ideas ↔ design ↔ plan ↔ related docs; and **cross-module** for epics).
4. Where relevant, inspect **repository structure and conventions** (files, modules, configuration patterns).
5. Produce a **structured findings report**.

Do not limit review to changed sections only; verify the documents make sense as a whole.

### Phase 2 — Recommendations and handoff prompt (still no edits to source)

After finding passes converge:

1. Produce a **consolidated “what should change”** section: for each finding that warrants a change (typically minor and above), state the **exact edit intent** (which document, which section or theme, what to add/remove/clarify). Group by document or by module for epics.
2. Build a single **implementation-agent prompt** (see **Implementation-agent prompt template** below) that an AI coding agent can run **in a separate session** to apply those edits. The handoff prompt must:
   - List source files by **name only** (as the user provided them), not by assumed folder locations.
   - Order work **blocker/major first**, then minor, then nits if included.
   - Require the agent to **increment version and changelog** in every document it modifies, using the project’s doc conventions.
   - Include **verification steps** (re-read for contradictions, cross-refs, design–plan alignment).

### Phase 3 — Regression pass on the deliverables

Re-read **your report and the implementation-agent prompt** only. Do not edit source documents.

Look for:

- Internal contradictions between findings or recommendations.
- Missing remediation for a blocker or major finding.
- Handoff prompt that is ambiguous, out of order, or missing file references.
- Epic: module boundaries or cross-module issues omitted from the handoff.

If Phase 3 finds a **gap in the report or handoff**, revise those deliverables (still without touching user source files). Re-run Phase 3 until clean.

## Review focus (generic)

Be especially skeptical about:

1. **Design–plan conformance**  
   Plan preserves design semantics; no required behavior omitted; no extra behavior that changes the design contract without being called out.

2. **Consistency**  
   Same concepts, names, and decisions across documents; no references to missing sections; no open-item list that contradicts resolved sections.

3. **Completeness**  
   All requirements have corresponding steps or acceptance checks; risks and open questions are carried or explicitly resolved; no placeholder language (“handle retries,” “appropriate merge”) unless marked as open.

4. **Repository fit**  
   File/module placement and conventions match the repository; configuration and style assumptions are realistic; no invented subsystems unless verified.

5. **Operational safety**  
   Partial failure, retry, rollback, and rollout are specified enough to implement safely; no accidental infinite backfill or silent gaps.

6. **Observability and validation**  
   Logs/metrics and acceptance criteria are sufficient to verify behavior; validation plan is concrete.

7. **Documentation quality**  
   No stale references; no changelog/version drift; no overclaiming “validated” where uncertainty remains.

**Optional:** If the user provides **project-specific instructions**, add those as additional required checks.

## Repository-grounding requirement

Do not hallucinate.

Before claiming that a path, convention, or mechanism exists or does not exist, **verify it in the repository** when accessible.

For each material finding, state:

- File(s) or section(s) inspected in the **source documents**.
- Repository paths or symbols inspected (when repo access exists).
- Whether the claim is **docs-only**, **repository-only**, or **both**.
- Whether the finding is **baseline-specific**, **conditional**, or **universal**.

If a required artifact cannot be inspected, mark related claims as **unverifiable**.

## Severity standard

Use the same severity levels as the other workflow prompts (01, 05):

- **blocker** — Invalidates the design, unsafe to implement, or likely to fail in practice.
- **major** — Substantial correctness, consistency, implementability, operational, or observability risk.
- **minor** — Real issue with limited blast radius or straightforward fix.
- **nit** — Wording/style only; optional in the implementation-agent prompt.

Only include real issues. Do not pad.

## Required output format

### Finding report (each Phase 1 pass and Phase 3 regression on deliverables)

For each issue:

- **ID**
- **Severity**
- **Location** — document name + section / anchor (and **module name** if epic)
- **Grounding** — docs/repository inspected; conditional or universal
- **Problem**
- **Failure mode**
- **Why it matters**
- **Exact fix required** (describe the change; do not apply it to source)
- **How to validate the fix** (after a future editor applies it)

End each pass with a **Pass verdict:** what was found, what the next pass will focus on, whether the exit criterion is met.

### Consolidated recommendations (Phase 2)

- Grouped list of **what should change**, mapped to finding IDs.
- Any finding intentionally **deferred** (with reason and residual risk).

### Implementation-agent prompt (Phase 2)

A single markdown block or section titled **Prompt for implementation agent**, containing at minimum:

1. **Goal** — Apply document edits to resolve findings `<IDs>`.
2. **Scope** — List of document **filenames** to open (per module if epic).
3. **Constraints** — Read-only on anything outside scope; follow project doc versioning/changelog rules; preserve structure unless a finding requires otherwise.
4. **Ordered task list** — Concrete edits, blocker/major first, referencing finding IDs.
5. **Self-review checklist** — Same spirit as the original pre-implementation workflow: alignment after edits, cross-references, version/changelog for each touched file.

### Editing rules (for the future implementation agent, not for you)

State explicitly in the handoff prompt:

- Smallest localized change that fully resolves each issue.
- Preserve structure unless it causes confusion.
- Keep the implementation plan aligned with the design doc after every edit.
- Do not declare documents “clean” because the happy path sounds plausible.

## Completion rule

You may conclude the review is complete only when:

- Phase 1 has run until two consecutive passes produce no new major-or-above findings.
- Phase 2 recommendations and the implementation-agent prompt are complete.
- Phase 3 regression on **deliverables** is complete with no unresolved gaps for blocker/major items.
- **Self-review of the report and handoff prompt** has passed (see below).
- You briefly explain why further passes are unlikely to surface more than low-value nits in the source material.

## Final output

### Final status

- **Verdict:** ready for implementation / ready with residual nits / not ready (blockers or majors without a clear remediation path)
- **Summary:** all issues found and recommended disposition
- **Residual risks:** unresolved concerns and severity
- **Recommended document updates:** what should change, by file (and module if epic)
- **Implementation impact:** any change to sequencing, configuration, or observability implied by recommendations
- **Unverifiable items:** conclusions that could not be fully grounded (missing repository access, etc.)

### Final coverage attestation

State whether each area was reviewed and whether it passed or produced findings:

- Design ↔ implementation-plan conformance (and ideas doc where present)
- Internal consistency (per document)
- Completeness (requirements → steps → acceptance)
- Repository fit
- Operational safety / rollout / rollback
- Observability / validation
- Versioning / changelog / cross-references (as issues, not edits)
- **Epic only:** cross-module consistency and ordering

## Self-review

After completing Phases 1–3 and the final output, perform a **full self-review** of **your report and implementation-agent prompt**:

1. **Re-read the findings** — Any contradiction, missing ID, or unclear severity?
2. **Re-check recommendations** — Every blocker and major has a concrete recommended change; none are accidentally dropped.
3. **Re-read the implementation-agent prompt** — Could a separate agent execute it without access to your reasoning? Are filenames and ordering correct?
4. **Epic** — Module coverage and epic-level issues reflected in the handoff.

If the self-review finds issues, revise the report or handoff prompt and re-run until it passes. **Do not edit user source documents** as part of self-review.

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.0     | 2026-03-23 09:25 CET | Initial version: report-only pre-implementation review; epic/zip multi-module support; implementation-agent handoff; no source doc edits; no prescribed document directory paths. |
