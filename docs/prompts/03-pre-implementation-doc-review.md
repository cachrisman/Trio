# Pre-Implementation Doc Review (Generic)

**Version:** 1.4  
**Status:** In Use  
**Created:** 2026-03-17 10:50 CET  
**Last updated:** 2026-03-17 14:15 CET  

---

Red-team review a **set of feature documents** (design doc, implementation plan, and any related specs) for consistency, completeness, and implementability. Then edit the docs to fix the problems.

Your job is to find real defects: internal contradictions, gaps between design and plan, missing implementation decisions, repo-fit issues, rollout hazards, and observability gaps — not to be polite.

Treat this as adversarial review of docs that may look complete while still being inconsistent, underspecified, or not actually buildable.

## Inputs

The user will provide:

- **Document set** — typically:
  - Design doc (e.g. `docs/in-progress/<feature>/<design-doc>.md`)
  - Implementation plan (e.g. `docs/in-progress/<feature>/<implementation-plan>.md`)
  - Optionally: other related files (architecture notes, rollout checklist, etc.)
- **Optional: project-specific instructions** — constraints, architecture rules, or “must verify” items (e.g. “no Trio app changes,” “two-source Better Stack model,” “use existing sync scripts”). If none are given, focus on the generic checks below.

You must verify:

1. **Technical soundness** — Each doc is internally consistent and technically plausible.
2. **Design–plan alignment** — The implementation plan faithfully operationalizes the design; nothing required by the design is missing or weakened in the plan, and nothing in the plan contradicts or silently expands the design.

## Baseline declaration

Before starting Pass 1, state:

- The **branch / repo / baseline** being reviewed (e.g. `dev`, feature branch, or “docs only”).
- Whether the review is **docs only**, **docs + code**, or **docs + repo structure**.
- Whether the implementation plan is **greenfield** or **partially grounded** in existing repo conventions.
- Any **baseline uncertainty** that makes a conclusion conditional.

When verifying **repo fit** or inspecting repo structure (e.g. in Phase 1), use the **implementation plan’s Prerequisites** (branch(es) and context explored) as the baseline when available, so repo checks match the context the plan was written against.

If the baseline is mixed or incomplete, say so and mark conclusions that depend on missing context as **conditional** or **unverifiable**.

## Conflict resolution rule

Treat the **design doc** as the higher-level specification and the **implementation plan** as the execution plan.

When the two conflict:

- Treat the **design doc** as the source of truth unless there is clear, justified evidence that the implementation plan intentionally supersedes it.
- **Flag the discrepancy** as a defect.
- Do **not** silently narrow requirements in the implementation plan to make them easier.
- Do **not** weaken the design doc unless the text genuinely supports the change.

Also flag:

- Implementation details **required by the plan** but **absent from the design**.
- Design **requirements present in the design** but **missing or contradicted in the plan**.

## Required workflow

The review runs in **three phases**. Do not collapse them.

### Phase 1 — Finding passes (no edits)

Run at least **two full finding passes**. Pass count is not a formality: do not restate prior findings just to satisfy pass count; each pass must add new scrutiny, confirm specific resolutions, or identify remaining proof gaps.

Continue until:

- At least two full finding passes have been completed, and
- Two consecutive passes produce **no new blocker or major** findings, and
- The later pass produces at most a small number of low-value minor findings.

Each pass must:

1. Read all docs in the set fully.
2. Check **internal consistency** within each doc.
3. Check **cross-doc consistency** (design ↔ plan ↔ any related docs).
4. Where relevant, inspect **repo structure and conventions** (files, modules, config patterns).
5. Produce a **structured findings report**.

Do not limit review to changed sections only; verify the docs make sense as a whole.

### Phase 2 — Primary edit pass

After finding passes converge, make **one coherent edit pass**, highest-severity first.

- Prefer resolving all known findings in one pass rather than many small edits.
- Edits should be: **additive when possible**, **localized when possible**, **structure-preserving** unless structure is part of the problem.
- After editing, **increment version and update changelog** in each modified doc.

### Phase 3 — Regression pass

Re-read all **edited** docs as if the fixes might have introduced new mistakes.

Look for:

- New contradictions introduced by the edits.
- Cross-reference or section drift.
- Version/changelog inconsistencies.
- Steps or requirements that no longer match after edits.
- Wording that overclaims certainty.
- Fixes in one doc that created drift in another.

If Phase 3 finds a **new blocker or major** issue introduced by the edits, do one targeted follow-up edit pass, then re-run the regression pass.

## Review focus (generic)

Be especially skeptical about:

1. **Design–plan conformance**  
   Plan preserves design semantics; no required behavior omitted; no extra behavior that changes the design contract without being called out.

2. **Consistency**  
   Same concepts, names, and decisions used across docs; no “see below” to missing sections; no open-item list that contradicts resolved sections.

3. **Completeness**  
   All requirements have corresponding steps or acceptance checks; risks and open questions are carried or explicitly resolved; no placeholder language (“handle retries,” “appropriate merge”) unless marked as open.

4. **Repo fit**  
   File/module placement and conventions match the repo; config/env/style assumptions are realistic; no invented subsystems unless verified.

5. **Operational safety**  
   Partial failure, retry, rollback, and rollout are specified enough to implement safely; no accidental infinite backfill or silent gaps.

6. **Observability and validation**  
   Logs/metrics and acceptance criteria are sufficient to verify behavior; validation plan is concrete.

7. **Documentation quality**  
   No stale references; no changelog/version drift; no overclaiming “validated” where uncertainty remains.

**Optional:** If the user provides **project-specific instructions**, add those as additional required checks (e.g. “verify two-source Better Stack model,” “do not assume overwrite/upsert behavior”).

## Repo-grounding requirement

Do not hallucinate.

Before claiming that a path, convention, or mechanism exists or does not exist, **verify it in the repo** when accessible.

For each material finding, state:

- File(s) or section(s) inspected.
- Repo path(s) or symbol(s) inspected.
- Whether the claim is **docs-only**, **repo-only**, or **both**.
- Whether the finding is **baseline-specific**, **conditional**, or **universal**.

If a required file or path cannot be inspected, mark related claims as **unverifiable**.

## Severity standard

Use the same severity levels as the other workflow prompts (01, 05):

- **blocker** — Invalidates the design, unsafe to implement, or likely to fail in practice.
- **major** — Substantial correctness, consistency, implementability, operational, or observability risk.
- **minor** — Real issue with limited blast radius or straightforward fix.
- **nit** — Wording/style only; no edit required unless chosen.

Only include real issues. Do not pad.

## Required output format

### Finding report (each Phase 1 pass and Phase 3 regression)

For each issue:

- **ID**
- **Severity**
- **Location** — doc + section / anchor
- **Grounding** — docs/repo inspected; conditional or universal
- **Problem**
- **Failure mode**
- **Why it matters**
- **Exact fix required**
- **How to validate the fix**

End each pass with a **Pass verdict:** what was found, what the next pass will focus on, whether the exit criterion is met.

### Edit pass summary (Phase 2)

- Exact doc changes made.
- Which finding IDs were resolved.
- Any finding intentionally deferred and why.
- Version/changelog updates per doc.

### Regression pass report (Phase 3)

Same format as a finding report, focused on: contradictions introduced by edits, stale references, design–plan drift from edits, version/changelog inconsistency, new ambiguity.

### Editing rules

- Smallest localized change that fully resolves each issue.
- Preserve structure unless it causes confusion.
- Keep the implementation plan aligned with the design doc after every edit.
- Do not declare docs “clean” because the happy path sounds plausible.

## Completion rule

You may conclude the docs are clean only when:

- Phase 1 has run until two consecutive passes produce no new major-or-above findings.
- Phase 2 edits have been applied.
- Phase 3 regression pass is complete with no new blocker or major issues.
- **Self-review has been completed and passed** (re-read edited docs, confirm design–plan alignment and cross-refs, confirm every blocker and major finding has a fix or explicit deferral; fix and re-run until it passes).
- You briefly explain why further passes are unlikely to surface more than low-value nits.

## Final output

### Final status

- **Verdict:** clean / clean with minor nits / not clean
- **Summary:** all issues found and resolution status
- **Residual risks:** unresolved concerns and severity
- **Required doc updates:** any docs still inaccurate or incomplete
- **Implementation impact:** any change to sequencing, config, or observability caused by the edits
- **Unverifiable items:** conclusions that could not be fully grounded (missing repo, etc.)

### Final coverage attestation

State whether each area was reviewed and whether it passed or produced findings:

- Design ↔ implementation-plan conformance
- Internal consistency (per doc)
- Completeness (requirements → steps → acceptance)
- Repo fit
- Operational safety / rollout / rollback
- Observability / validation
- Versioning / changelog / cross-references

## Self-review

After completing Phase 1–3 and the final output, perform a **full self-review** of what was created and changed:

1. **Re-read every edited document** in full, as if you did not write it. Look for new contradictions, unclear wording, or overclaiming introduced by the edits.
2. **Re-check design–plan alignment** — After all edits, confirm the implementation plan still faithfully reflects the design; no requirement was dropped or weakened by the fix pass.
3. **Re-check cross-references** — Section names, anchors, and “see §X” references are still valid in both docs; fix any drift from renames or restructure.
4. **Re-check version and changelog** — Each modified doc has an incremented version and a new changelog entry that accurately describes the edits.
5. **Re-check the finding and edit record** — Every blocker and major finding from Phase 1 has a corresponding fix or an explicit deferral with reason; no finding was forgotten.

If the self-review finds issues, apply targeted fixes and re-run the self-review until it passes. Only then present the final status and coverage attestation.

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.4     | 2026-03-17 14:15 CET | Pass quality: do not restate prior findings for pass count; each pass adds new scrutiny, confirms resolutions, or identifies proof gaps. |
| 1.3     | 2026-03-17 13:00 CET | Baseline: use plan’s Prerequisites when verifying repo fit. Completion rule: Self-review must be completed and passed. |
| 1.2     | 2026-03-17 12:18 CET | Severity standard: aligned wording with 01 and 05 (blocker / major / minor / nit). |
| 1.1     | 2026-03-17 11:10 CET | Added self-review section: full pass over edited docs and review record for contradictions, alignment, cross-references, version/changelog, and unresolved findings. |
| 1.0     | 2026-03-17 10:50 CET | Initial version. Generic pre-implementation doc review for any feature doc set; three-phase workflow; design-as-spec, plan-as-execution; optional project-specific instructions. |
