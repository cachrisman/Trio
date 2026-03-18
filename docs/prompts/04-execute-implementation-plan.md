# Execute Implementation Plan

**Version:** 1.6  
**Status:** In Use  
**Created:** 2026-03-17 10:50 CET  
**Last updated:** 2026-03-17 14:15 CET  

---

Given a design doc and an implementation plan (plus any other referenced docs), **execute the implementation plan** step by step. Implement the feature as specified, without expanding scope or skipping steps.

## Inputs

The user will provide:

- **Design doc** — path or @-reference (e.g. `docs/in-progress/<feature>/<design-doc>.md`).
- **Implementation plan** — path or @-reference (e.g. `docs/in-progress/<feature>/<implementation-plan>.md`).
- Optionally: other relevant docs (architecture, rollout checklist, etc.).

Use these as the **authoritative context** for what to build and in what order.

## Core objective

- **Follow the plan** — Execute steps (and phases, if any) in the order and manner described in the implementation plan.
- **Satisfy the design** — Every change must align with the design’s requirements, constraints, and success criteria; do not add features or behavior outside the design.
- **Stay codebase-grounded** — Work in the real repo: correct branches, existing types/modules, and repo conventions (e.g. sync scripts for project layout, patch workflow per AGENTS.md).

## Required workflow

1. **Load context.**  
   Read the design doc and implementation plan in full. Note prerequisites, phases, step order, dependencies, and acceptance criteria.

2. **Confirm baseline.**  
   Identify the branch and worktree to use (e.g. feature branch in Trio worktree per AGENTS.md). Ensure you are not on a branch or state that would conflict with the plan (e.g. wrong worktree for code vs. patches).

3. **Execute by step (and phase).**  
   - If the plan has **phases**, complete each phase before moving to the next; within a phase, complete steps in order unless the plan allows parallel work.
   - For each **step**:
     - **Do** the work (code, config, tests, or docs as specified).
     - **Verify** the step’s acceptance criteria (run tests, manual check, or observable behavior).
     - If a step hits a **true blocker** (would require inventing behavior not in the design or plan, violating the design, or proceeding without a required dependency), stop and report the blocker with exact reference to the plan and design. Otherwise, complete the maximum grounded subset of the step, record any assumptions or deviations in the implementation log, and continue.
   - After each step (or small group of related steps), ensure the codebase still builds and any step-level tests pass.

4. **Track progress.**  
   Keep an **implementation log** (execution log) as you complete steps. The log must live **in the implementation plan document itself**, in a dedicated section placed **at the end of the document, immediately before the Changelog section**.

   - **If the plan has no such section yet:** Add one (e.g. `## Implementation log` or `## N. Implementation log` to match the plan’s numbering). Place it after the last substantive section and before the `---` and `## Changelog`.
   - **As you complete each step (or phase):** Append an entry to that section. Each entry must include: **step ID** (and phase if applicable), **what was done**, **where** (files or paths touched), and **how acceptance was verified** (test run, manual check, or observable behavior). Note any **deviation** from the plan (e.g. “Step 3.2 implemented in X instead of Y because …”) and any **deferred or open items**.
   - **Ongoing:** Update the log after each step or small group of steps so the plan document always reflects current progress. Version and changelog updates for the plan may be batched per execution session or per meaningful batch of work (e.g. end of a phase or logical group of steps); you do not need to increment version and add a changelog entry for every single log append.

5. **Final validation.**  
   When all steps are complete, run the **rollout / validation** section of the implementation plan (e.g. full test suite, manual scenarios, metrics check). If the plan references design success criteria, confirm they are met.

6. **Report.**  
   Produce a short execution summary: what was implemented, what was skipped or deferred and why, any blockers or follow-ups, and where the implementation lives (branch, key files). **Include the branch name (and worktree if relevant)** so the user can pass them to prompt 05 (red-team review).

## Rules during execution

- **No scope creep** — Do not add features, refactors, or “improvements” beyond the design and plan. If you see a worthwhile addition, note it as a follow-up; do not implement it in this pass.
- **Do not skip steps** — Unless the plan explicitly marks a step optional or conditional, attempt it and complete it as fully as the available codebase, dependencies, and design support allow. Do not stop for ordinary ambiguity. If a step is unclear but not truly blocked, use the minimal grounded interpretation that best matches the design and implementation plan, record the assumption/deviation in the implementation log, and continue. Only stop when the ambiguity is a true blocker under the blocker-handling rule.
- **Respect repo rules** — Follow AGENTS.md and any project rules: e.g. no manual `project.pbxproj` edits (use sync scripts), no hand-editing patch files (fix code and regenerate), no TestFlight upload unless requested.
- **Tests and acceptance** — For each step that specifies tests or acceptance, run them. If tests are missing but the plan says “add tests,” add them as part of that step.
- **Blocker handling** — Stop only for a **true blocker**: one that would require inventing behavior not in the design or plan, violating the design, or proceeding without a required dependency. In that case, report the blocker with exact reference to the plan and design and suggest what would unblock. Otherwise, complete the maximum grounded subset of the step, record assumptions and deviations in the implementation log, and continue.

## Self-review

After completing execution (all steps or stop at blocker) and before presenting the final summary, perform a **full self-review** of what was implemented:

1. **Re-read the implementation plan** and the **implementation log section** (in that document) — Confirm every completed step is accurately logged with what was done, where, and how acceptance was verified; fix any omission or misstatement in the log.
2. **Re-read the design doc** — Verify the implemented behavior satisfies the stated requirements, constraints, and success criteria; flag any shortfall or deviation in the report.
3. **Re-scan the changed files** — Walk through every modified or new file; check for obvious bugs, missing error handling, inconsistent naming, or leftover TODOs that contradict the plan.
4. **Re-run step-level and final validation** — Run the tests and acceptance checks called out in the plan; if anything fails, fix or report as a residual issue in the summary.
5. **Re-check repo rules** — Confirm no AGENTS.md or project rules were violated (e.g. no manual pbxproj edits, no TestFlight upload, correct worktree/branch).

If the self-review finds defects or gaps, fix them and re-run the relevant acceptance checks; then repeat the self-review until it passes. Only then present the execution summary and final verdict.

## Output expectations

- **Code and config** — Leave all changes in the working tree for user review. Do not commit unless the user explicitly instructs you to. Staging is optional and only when useful or explicitly requested (e.g. to group related changes for review). This aligns with AGENTS.md: the agent does not commit or push unless explicitly asked.
- **Implementation log** — Kept **in the implementation plan document** (section at the end, before the Changelog). Contains step-by-step entries: what was done, where, how acceptance was verified, and any deviations or deferrals. Update the log as steps complete; version and changelog for the plan may be batched per session or meaningful batch of work rather than on every log entry.
- **Final summary** — Verdict (complete / partial with blockers / deferred items), list of key files touched, branch (and worktree if relevant) for handoff to 05, and any recommended follow-up (e.g. doc update, next phase).

## Completion rule

Execution is **complete** when:

- Every step (and phase) in the implementation plan has been executed and its acceptance criteria met, or
- Execution is **stopped** at a blocker, with a clear report of the blocker and what is needed to resume.

Do not mark the plan “done” if steps were skipped without the plan’s approval or if success criteria from the design are not yet verifiable.

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.6     | 2026-03-17 14:15 CET | Commit policy: leave changes in working tree; no commit unless user explicitly instructs; staging optional. Blocker behavior: stop only for true blocker (inventing/violating design/missing required dependency); otherwise complete max grounded subset and log assumptions. Version/changelog: may batch per session or meaningful batch. |
| 1.5     | 2026-03-17 13:00 CET | Completion rule: Self-review must be completed and passed before presenting the final summary. |
| 1.4     | 2026-03-17 12:33 CET | Report and final summary: include branch (and worktree if relevant) so user can pass them to prompt 05. |
| 1.3     | 2026-03-17 11:41 CET | Timestamps: follow doc-timestamps rule; Last updated and this changelog entry use current-time command output. |
| 1.2     | 2026-03-17 11:30 CET | Required workflow §4 (Track progress): implementation log must be kept in the implementation plan document at the end before the Changelog; added where to place the section, what each entry must include, and version/changelog updates when the log is updated. Output expectations and self-review updated to match. |
| 1.1     | 2026-03-17 11:10 CET | Added self-review section: full pass over implementation, execution log, design alignment, changed files, validation, and repo rules before final summary. |
| 1.0     | 2026-03-17 10:50 CET | Initial version. Execute implementation plan from design + plan; step-by-step workflow; no scope creep; blocker reporting; execution log and final summary. |
