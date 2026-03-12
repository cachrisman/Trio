# Docs

This `docs/` folder contains the written artifacts, standards, and agent prompts used to design, plan, implement, review, and document work in this repo.

## Folder map

### `docs/process/`
**Canonical “house rules”** that other docs reference. These should be edited rarely and deliberately.

- `doc-lifecycle.md` — How docs move from draft → reviewed → frozen record.
- `review-patch-protocol.md` — How reviews are performed (PASS/FAIL + PATCH format, stop rules).
- `standards-observability.md` — Logging/metrics/telemetry standards and conventions.
- Other stable process docs may live here (e.g., workflow standards like feature-branch rules).

### `docs/templates/`
**Copy/paste starters** for new work. Create a new initiative by copying the relevant template(s) into `docs/in-progress/<initiative>/` and then iterate.

- `feasibility-memo-template.md`
- `design-doc-template.md`
- `implementation-plan-template.md`

### `docs/prompts/`
**Ready-to-run agent prompts** (paste into ChatGPT/Cursor/etc.). These are operational tools, not narrative docs.

- `feedback-crosswalk-prompt.md` — Normalize/dedupe reviewer feedback and track dispositions.
- `postmortem.md` — Generate a postmortem from incident context and evidence.

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

## How to start new work

1. Pick an initiative name (short, stable, kebab-case), e.g. `causality-metrics`.
2. Create the folder: `docs/in-progress/<initiative>/`.
3. Copy the appropriate template(s) from `docs/templates/` into that folder.
4. Iterate using the review loop in `docs/process/review-patch-protocol.md`.
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
- In `in-progress/`, include **Version / Status / Date** at the top and a **Changelog** section.
- Keep **acceptance criteria verifiable**; keep **hypotheses separate**.
- Don’t rewrite completed history—supersede it with a new in-progress doc if decisions change.

## If you’re lost

Start here:
1. `docs/process/doc-lifecycle.md`
2. `docs/process/review-patch-protocol.md`
3. `docs/process/standards-observability.md`