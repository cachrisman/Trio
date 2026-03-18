# Create Implementation Plan from Design Doc

**Version:** 1.4  
**Status:** In Use  
**Created:** 2026-03-17 10:50 CET  
**Last updated:** 2026-03-17 13:00 CET

---

Given a design document for a feature, produce a companion implementation plan that lays out the concrete steps (and phases, when appropriate) needed to implement the feature. The plan must be grounded in the codebase and faithful to the design.

## Inputs

- **Design doc:** Path to the design document (e.g. `docs/in-progress/<feature>/<design-doc>.md`).
- Optionally: other referenced docs (architecture notes, related specs).

The user will provide the design doc path or @-reference the file.

## Core objective

Produce an implementation plan document that:

1. **Operationalizes the design** — Every material requirement, constraint, and success criterion in the design is reflected in concrete steps or acceptance checks.
2. **Is codebase-grounded** — Steps reference real files, modules, types, and extension points where they exist; proposed new artifacts fit the repo layout and conventions.
3. **Is ordered and dependency-aware** — Steps are sequenced so that prerequisites and dependencies are respected; phases group related work when the feature is complex or has many steps.

## Required workflow

1. **Read the design doc in full.**  
   Extract: problem, requirements, constraints, functional behavior, scope boundaries, risks/open questions, success criteria.

2. **Investigate the codebase.**  
   Goal: see what exists and is available (your investigation may span different branches). Do **not** limit to a single branch or require a full index of every branch.

   **Rule of thumb:** Start with **dev**. Be sure to look at the **patches** directory (it contains the accumulation of all current feature-branch work). Then consider branch names: if a branch seems related to the idea being investigated, look at its commit history and optionally checkout that branch and explore relevant files.

   For each area the design touches (APIs, types, flows, persistence, notifications, etc.):
   - Locate the relevant files, types, and call sites.
   - Confirm naming, ownership, and extension points.
   - Note existing tests or patterns to follow.
   - Identify where new code vs. changes to existing code are needed.

3. **Draft the implementation plan structure.**  
   - If the feature is relatively complex or has **more than ~10 significant steps** (rule of thumb), organize work into **phases** (e.g. Phase 1: data model and wiring; Phase 2: handlers and integration; Phase 3: observability and validation).
   - Otherwise, a single ordered list of steps may suffice.
   - Each step must be actionable: a developer can do it without guessing the target.

4. **Write the implementation plan.**  
   For each step (and each phase, if used):
   - **What** to do (goal of the step).
   - **Where** (files, modules, or “new file under X”).
   - **How** it satisfies the design (brief trace to design section or requirement).
   - **Acceptance** — how to verify the step is done (test, manual check, or observable behavior).
   - **Dependencies** — which earlier steps or phases must be done first.

5. **Cross-check against the design.**  
   - Every design requirement/constraint/success criterion is covered by at least one step or an explicit acceptance check.
   - No step contradicts the design or expands scope beyond what the design allows.
   - Open questions or risks in the design are called out in the plan (e.g. “Staleness threshold: decide value and config mechanism per §6”).

6. **Place and format the output.**  
   - Write the plan to `docs/in-progress/<feature>/<implementation-plan>.md` (or the path the user specifies).
   - Use the same version/changelog conventions as other docs in `docs/` (version at top, changelog at end).
   - Include the **Implementation log** section (empty) so the executor (04) has a standard place to record progress.
   - In **Prerequisites**, record the branch(es) and context you explored (e.g. dev, patches, any feature branches inspected) so the plan documents what was investigated.

## Implementation plan document structure (recommended)

- **Title** and **Version** (e.g. 1.0).
- **Design doc reference** — path and brief summary of what this plan implements.
- **Prerequisites** — branch(es) and key context explored when investigating the codebase (e.g. dev, patches, and any feature branches inspected); tooling or other context needed before starting.
- **Phases** (if used), each with:
  - Phase name and objective.
  - Ordered steps within the phase.
  - Phase-level acceptance (what “done” means for the phase).
- **Steps** — each with: ID, title, what/where/how, acceptance, dependencies.
- **Rollout / validation** — how to verify the full feature (e.g. manual scenarios, tests, metrics).
- **Risks and open items** — carried from design or discovered during planning; do not resolve them silently.
- **Implementation log** — A section at the end, **before** the Changelog, for the executor (prompt 04) to record step-by-step progress. Leave this section empty when creating the plan; 04 will add entries as steps are completed.
- **Changelog** at the end.

## Code-grounding rules

- Do not invent file paths, type names, or APIs. Search the repo and cite what you find.
- If the design references existing types or flows (e.g. `TrioComplicationSnapshot`, `UNUserNotificationCenterDelegate`), locate them and ensure the plan uses the same names and extension points.
- If the repo uses a particular pattern (e.g. sync scripts for project structure, patch workflow), the plan must respect it; do not assume generic layouts.
- When something cannot be verified (e.g. missing repo access), say so and mark those parts of the plan as conditional or to be confirmed during implementation.

## Self-review

After completing the steps above, perform a **full self-review** of the implementation plan you created:

1. **Re-read the implementation plan** from top to bottom as if you are a new reader.
2. **Re-read the design doc** and verify every requirement, constraint, and success criterion is still covered by at least one step or acceptance check; fix any gap.
3. **Re-verify codebase grounding** — Confirm each cited file, type, or path exists (or is clearly “new file under X”); correct or soften any claim that does not hold.
4. **Check ordering and dependencies** — Ensure no step runs before its dependencies; phase boundaries are clear; no circular or missing prerequisites.
5. **Check for scope creep** — Remove or reframe any step that implements behavior not in the design.
6. **Check structure and clarity** — Section headers, step IDs, and changelog are consistent; no broken or vague “see above/below” references.

If the self-review finds issues, fix them and then re-run the self-review until the plan passes. Only then consider the task complete and present the result.

## Output expectations

- The implementation plan is a **standalone** doc: someone with the design doc and this plan can implement the feature without re-deriving steps.
- Steps are **concrete** — no vague “implement the handler” without saying where and what interface.
- **No scope creep** — the plan does not add features or requirements beyond the design; if something is out of scope in the design, it stays out of scope in the plan.


## Completion rule

You are done when:

- The implementation plan document is written to the agreed path.
- Every design requirement, constraint, and success criterion is reflected in the plan.
- The plan is grounded in the codebase (or gaps are explicitly called out).
- Phases are used when the feature has more than ~10 significant steps or is clearly multi-stage; otherwise steps are clearly ordered with dependencies.
- Version and changelog are present and updated.
- **Self-review has been completed and passed** (re-read plan and design, re-verify grounding, ordering, scope, structure; fix and re-run until it passes).

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.4     | 2026-03-17 13:00 CET | Completion rule: Self-review must be completed and passed before considering the task done. |
| 1.3     | 2026-03-17 12:51 CET | Investigate codebase: goal is what exists (may span branches); rule of thumb dev + patches + related branches. Prerequisites: record branch(es) and context explored; placement step to fill Prerequisites. |
| 1.2     | 2026-03-17 12:18 CET | Implementation plan structure: added Implementation log section (before Changelog) for executor (04); placement step updated to include it. |
| 1.1     | 2026-03-17 11:10 CET | Added self-review section: full pass over the created implementation plan against design, codebase, ordering, scope, and structure. |
| 1.0     | 2026-03-17 10:50 CET | Initial version. Create implementation plan from design doc; codebase investigation; phases when >10 steps or complex; placement in docs/in-progress. |
