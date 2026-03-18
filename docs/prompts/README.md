# Feature docs and implementation workflow

**Version:** 1.4  
**Status:** In Use  
**Created:** 2026-03-17 12:18 CET  
**Last updated:** 2026-03-17 14:15 CET  

---

This folder contains prompts for a **user-driven** workflow: creating feature docs (design, implementation plan), reviewing them, implementing the feature, and red-teaming the implementation. The workflow is **not automated**. The user instructs the agent to run each step (e.g. "do a design doc review"); the user reviews the outcome and then instructs the next step.

**Review vs. mutation:** Steps 1 and 3 primarily review and analyze docs; they normally also **update** the design doc and/or plan to fix findings (fix-and-update is the default). Step 2 **creates or updates** the implementation plan. Step 4 **implements** code and docs and **updates the implementation log** in the implementation plan (that plan is the canonical place for execution logging during step 4). Step 5 **reviews** the implementation and normally **applies fixes** (fix-and-update is the default). Review-only behavior (report without making doc or code changes) is opt-in: the user must explicitly ask for it (e.g. "review only" or "don't make changes").

## Intended order

| Step | Prompt | What the user does |
|------|--------|--------------------|
| 1 | [01-design-doc-review.md](01-design-doc-review.md) | Ask the agent to run a design doc review (see below). Review the report and any doc edits, then proceed when satisfied. |
| 2 | [02-create-implementation-plan-from-design.md](02-create-implementation-plan-from-design.md) | Instruct the agent to create an implementation plan from the design doc (provide the design doc path). Review the plan, then proceed. |
| 3 | [03-pre-implementation-doc-review.md](03-pre-implementation-doc-review.md) | Instruct the agent to review the design + implementation plan (and any related docs) for consistency and gaps. Review the findings and edits, then proceed. |
| 4 | [04-execute-implementation-plan.md](04-execute-implementation-plan.md) | Instruct the agent to execute the implementation plan (provide design doc and plan paths). Review the implementation and implementation log in the plan, then proceed. |
| 5 | [05-implementation-changes-red-team-full-review.md](05-implementation-changes-red-team-full-review.md) | Instruct the agent to red-team review the implementation changes (provide design doc, plan, and branch). Review the report and any fixes, then consider the feature complete or iterate. |

## Cursor rules

Each step can be triggered by phrase. Cursor rules in **`.cursor/rules/`** map those phrases to the correct prompt file so the agent runs the workflow as specified (read prompt, execute, don't substitute).

| Step | Rule file | Example trigger phrases |
|------|-----------|-------------------------|
| 1 | `design-doc-review.mdc` | "do a design doc review", "review the design doc" |
| 2 | `create-implementation-plan.mdc` | "create an implementation plan", "write an implementation plan from design" |
| 3 | `pre-implementation-doc-review.mdc` | "pre-implementation doc review", "review the design and implementation plan" |
| 4 | `execute-implementation-plan.mdc` | "execute the implementation plan", "run the implementation plan", "implement the plan" |
| 5 | `implementation-changes-red-team-review.mdc` | "red-team review the implementation", "implementation changes red-team review" |

All five rules have `alwaysApply: false` and activate when you use the relevant phrase. Document paths (design doc, plan, branch) are those you provide or have open (e.g. under `docs/in-progress/<feature>/`).

**Scope of this workflow:** These prompts assume feature docs (design, implementation plan) live under `docs/in-progress/<feature>/`. A separate backlog folder may hold ideas the user might later turn into a proper feature (with design doc, implementation plan, etc.). When the user picks up an idea from backlog, they would copy it into a feature folder under `docs/in-progress/<feature>/` as an idea doc for context; that copy step is out of scope for this set of documents. The workflow does not reference the backlog folder.

## Other prompts

Other files in this folder (e.g. prompts in `others/`) may be used for one-off or alternative workflows; they are not part of the numbered 01–05 sequence above.

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.4     | 2026-03-17 14:15 CET | Mutation expectations: which steps review vs create/modify; default fix-and-update for 1, 3, 5; impl plan canonical for step 4 execution log; review-only opt-in. |
| 1.3     | 2026-03-17 13:45 CET | All five Cursor rules use alwaysApply: false (phrase-triggered only). |
| 1.2     | 2026-03-17 13:15 CET | Cursor rules: document all five rule files and trigger phrases; step 1 alwaysApply, steps 2–5 on phrase. |
| 1.1     | 2026-03-17 12:33 CET | Scope: workflow assumes docs under docs/in-progress/<feature>/; backlog clarified as out of scope (ideas copied into in-progress by user when needed). Removed backlog from path example. |
| 1.0     | 2026-03-17 12:18 CET | Initial version. User-driven workflow 01→05; how to trigger step 1 via design-doc-review rule. |
