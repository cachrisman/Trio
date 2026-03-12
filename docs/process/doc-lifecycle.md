# Doc lifecycle

This repo uses docs as working artifacts: they start messy, get reviewed in tight loops, and end up as a frozen record of what we decided and shipped.

## Folder meanings

- `docs/process/` — Canonical process + standards (rarely changed; referenced by other docs).
- `docs/templates/` — Copyable starting points for new docs.
- `docs/prompts/` — Ready-to-run agent prompts (paste into ChatGPT/Cursor/etc.).
- `docs/in-progress/` — Active work under iteration (expected to change).
- `docs/completed/` — Frozen record (should not change except for typo fixes or clearly marked addenda).

## Initiative folders

All work lives under an initiative folder once it exists.

- `docs/in-progress/<initiative>/...`
- `docs/completed/<initiative>/...`

Initiative names should be short and stable (e.g., `complication-freshness`, `causality-metrics`).

## Standard artifact set (recommended)

Within an initiative folder, prefer these artifacts (create only what you need):

- `00-feasibility.md` — Feasibility memo
- `01-design.md` — Functional design doc
- `02-implementation-plan.md` — Stepwise implementation plan
- `03-implementation-log.md` — What actually changed + decisions + validation done
- `04-postmortem.md` — Only when warranted (incident / major regression / learning review)

Non-standard docs are allowed, but should still be clearly named.

## Versioning + changelogs (in all in-progress docs)

In `docs/in-progress/`, every doc should have at the top:

- `Version:` (increment on every meaningful edit)
- `Status:` (Draft | In review | Accepted | Complete)
- `Date:` (last edited date)

And include a `Changelog` section at the bottom with short bullets per version.

In `docs/completed/`, the final version should remain visible (do not remove changelog).

## Review loop rules (how docs get edited)

When a doc is under review:
- Reviewer outputs either `PASS` or a short list of issues + exact patch blocks (see `docs/process/review-patch-protocol.md`).
- Apply patches and bump version.
- Repeat until reviewer returns `PASS`.

Avoid “drive-by rewrites” during review: patch what’s needed to satisfy the rubric and stop.

## When to move from in-progress → completed

Move an initiative (or a specific doc) to `docs/completed/` when ALL are true:

1. **Decision is stable**  
   Design scope and behavior are agreed (or explicitly deferred).

2. **Implementation is complete** (if applicable)  
   The code has landed and the implementation log reflects reality.

3. **Acceptance gates are satisfied**  
   Tests/telemetry/observations listed in the plan have been performed (or explicitly waived with rationale).

4. **Review has PASS**  
   The most recent review round ended with `PASS` for the artifact(s) being moved.

## How to move (required steps)

When moving a doc/folder to `docs/completed/`:

1. Ensure `Status:` is `Complete` (or `Accepted` for design-only work).
2. Add a final changelog entry noting “moved to completed”.
3. If there are known follow-ups, add a short `Follow-ups` section with links (do not keep it “open-ended”).
4. Move the file(s) into the matching `docs/completed/<initiative>/` folder.

## Changes to completed docs

Completed docs are frozen. Allowed changes:
- typos / broken links
- addenda clearly marked as `Addendum (YYYY-MM-DD)` at the end

Not allowed:
- changing decisions without creating a new in-progress doc that supersedes it

If a decision changes: create a new in-progress doc that references the old completed doc and explains what changed and why.

## Naming conventions

- Prefer kebab-case filenames: `complication-freshness-remediation-plan.md`
- Avoid vague names like `notes.md`, `misc.md`, `new-plan.md`
- If a doc is a prompt, it lives in `docs/prompts/` and is named for the action: `plan-review.md`, `code-review.md`

## Quick checklist

Before asking for review:
- [ ] Goal and non-goals are explicit
- [ ] Constraints are stated
- [ ] Acceptance criteria are verifiable
- [ ] Any risky behavior change is called out
- [ ] Changelog updated and version bumped

Before moving to completed:
- [ ] Status is `Complete`/`Accepted`
- [ ] Final review returned `PASS`
- [ ] Any follow-ups are captured as links