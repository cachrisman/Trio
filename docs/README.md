# Docs

**Version:** v2  
**Created:** 2026-03-12 17:34 CET  
**Last updated:** 2026-03-19 10:53 CET

---

This `docs/` folder contains the written artifacts, standards, and agent prompts used to design, plan, implement, review, and document work in this repo.

## Folder map

### `docs/process/`
**Canonical "house rules"** that other docs reference. These should be edited rarely and deliberately.

- `doc-lifecycle.md` — How docs move from draft → reviewed → frozen record.
- `review-patch-protocol.md` — How reviews are performed (PASS/FAIL + PATCH format, stop rules).
- `standards-observability.md` — Logging/metrics/telemetry standards and conventions.
- `feature-branch-workflow-optimization.md` — Fork + patch stack workflow, mid-stack updates, upstream sync.
- `betterstack-guide.md` — Better Stack operational guide (metrics API, dashboards, log queries).

### `docs/templates/`
**Copy/paste starters** for new work. Create a new initiative by copying the relevant template(s) into `docs/in-progress/<initiative>/` and then iterate.

- `feasibility-memo-template.md`
- `design-doc-template.md`
- `implementation-plan-template.md`

### `docs/prompts/`
**Ready-to-run agent prompts** for a user-driven feature workflow. Each step has a Cursor rule (`.cursor/rules/`) that activates on phrase so you can trigger it by saying the phrase in chat.

See [`docs/prompts/README.md`](prompts/README.md) for the full workflow description.

#### Numbered workflow (01–05)

| Step | Prompt | Trigger phrases |
|------|--------|-----------------|
| 1 | `01-design-doc-review.md` | "do a design doc review", "review the design doc" |
| 2 | `02-create-implementation-plan-from-design.md` | "create an implementation plan", "write an implementation plan from design" |
| 3 | `03-pre-implementation-doc-review.md` | "pre-implementation doc review", "review the design and implementation plan" |
| 4 | `04-execute-implementation-plan.md` | "execute the implementation plan", "run the implementation plan", "implement the plan" |
| 5 | `05-implementation-changes-red-team-full-review.md` | "red-team review the implementation", "implementation changes red-team review" |

#### Other prompts (`prompts/others/`)

One-off or alternative prompts not part of the numbered sequence:

- `feedback-crosswalk-prompt.md` — Normalize/dedupe reviewer feedback and track dispositions.
- `postmortem.md` — Generate a postmortem from incident context and evidence.
- `review-and-repair-workflow.md` — Combined review + fix workflow.
- `trio-red-team-implementation-review.md` — Standalone red-team review prompt.
- `nightscout-precompute-docs-prompt.md` — Nightscout precompute service docs prompt.

### `docs/in-progress/`
**Active work under iteration.** Organized by initiative folder (e.g., `complication-freshness/`). Expect frequent edits, review loops, and version bumps.

Recommended artifact set per initiative (create only what you need):
- `00-feasibility.md`
- `01-design.md`
- `02-implementation-plan.md`
- `03-implementation-log.md`
- `04-postmortem.md` (only when warranted)

### `docs/completed/`
**Frozen record of decisions and shipped work.** Organized by initiative folder. Avoid changing these except for minor typos or clearly marked addenda.

### `docs/backlog/`
**Ideas and proposals not yet started.** Each subfolder holds an idea doc for a potential feature. When the user picks up an idea, they copy it into `docs/in-progress/<feature>/` as context and begin the feature workflow.

### `docs/investigations/`
**Ad-hoc investigation artifacts.** One-off analyses, data explorations, and debugging reports that don't belong to a specific initiative.

## How to start new work

1. Pick an initiative name (short, stable, kebab-case), e.g. `causality-metrics`.
2. Create the folder: `docs/in-progress/<initiative>/`.
3. Copy the appropriate template(s) from `docs/templates/` into that folder.
4. Use the feature workflow prompts (steps 1–5 above) to review, plan, implement, and red-team the feature.
5. When done, move the initiative folder to `docs/completed/<initiative>/` following `docs/process/doc-lifecycle.md`.

## Review loop (default)

- Reviewer outputs either:
  - `PASS` (and nothing else), or
  - `BLOCKERS` / `NON-BLOCKERS` + `PATCH` (exact edits)
- Apply patch, bump version + changelog, repeat until `PASS`.

See: `docs/process/review-patch-protocol.md`.

## Conventions

- Prefer **initiative folders** over flat file lists.
- Prefer **kebab-case** filenames.
- In `in-progress/`, include **Version / Status / Date** at the top and a **Changelog** section at the end.
- Keep **acceptance criteria verifiable**; keep **hypotheses separate**.
- Don't rewrite completed history — supersede it with a new in-progress doc if decisions change.

## If you're lost

Start here:
1. `docs/process/doc-lifecycle.md`
2. `docs/process/review-patch-protocol.md`
3. `docs/prompts/README.md`

---

## Changelog

### v2 (2026-03-19 10:53 CET)
- Updated `docs/prompts/` section to reflect the full 01–05 feature workflow with Cursor rule trigger phrases, matching `docs/prompts/README.md`. Moved `feedback-crosswalk-prompt.md` and `postmortem.md` under `prompts/others/` and added the other prompts in that subfolder.
- Updated `docs/process/` section to include `feature-branch-workflow-optimization.md` and `betterstack-guide.md`. Removed generic "Other stable process docs may live here" placeholder.
- Added `docs/backlog/` section for idea/proposal docs not yet started.
- Added `docs/investigations/` section for ad-hoc investigation artifacts.
- Updated "How to start new work" step 4 to reference the feature workflow prompts instead of just the review loop.
- Updated "If you're lost" to point to `docs/prompts/README.md` instead of `docs/process/standards-observability.md`.
- Added version metadata and changelog.

### v1 (2026-03-12 17:34 CET)
- Initial version. Folder map (process, templates, prompts, in-progress, completed), how to start new work, review loop, conventions.
