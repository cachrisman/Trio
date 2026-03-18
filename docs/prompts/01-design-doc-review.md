# Design Doc Review Prompt

**Version:** 1.5  
**Status:** In Use  
**Created:** 2026-03-17 09:30 CET  
**Last updated:** 2026-03-17 14:15 CET

---

Review the design document and produce a structured review report. The design doc to review is the one the **user provides** or the doc they have open (typically at `docs/in-progress/<feature>/<design-doc>.md`). **Default:** review, report findings, and apply doc edits to address them; re-review after edits. Only do a report-only pass (no doc edits) if the user explicitly asks for review-only or says not to make changes.

You are expected to do a deep design review, not a superficial consistency pass.

## Core review objective
Evaluate whether the design is clear enough, correct enough, and complete enough that another engineer could implement it without making major incorrect assumptions.

Review the design as written. Do not invent new product requirements, implementation preferences, or stylistic expectations.

## Required workflow
1. Read the design doc fully.
2. Produce a structured findings report based only on the document contents (and codebase inspection only if code-grounding is needed).
3. Apply minimal edits to address the findings (unless the user asked for review-only or not to make changes).
4. Re-read the entire document in full after any edits.
5. Perform a fresh adversarial re-review as if prior passes missed important issues.
6. Complete at least 2 full passes; use 3+ passes for long, high-risk, or cross-cutting designs.

Pass count is not a formality: do not restate prior findings just to satisfy pass count. Each pass must add new scrutiny, confirm specific resolutions, or identify remaining proof gaps. A pass only counts if you:
- re-read the full document, and
- either identify new substantive findings or explicitly confirm why prior findings are resolved and no new substantive issues were found.

## Review standard (design doc only)
Review for:
- **Problem and goals:** unclear problem statement, missing goals, missing/non-measurable success criteria
- **Contradictions:** conflicts within the doc or between linked sections
- **Ambiguity / underspecification:** undefined terms, unclear behavior, unclear boundaries, missing decision criteria
- **Incorrect or unsupported claims:** claims stronger than the rationale/evidence supports
- **Missing design decisions:** places where the doc implies a choice but does not actually make one
- **Assumptions and constraints:** hidden assumptions, missing constraints, or inconsistent constraints
- **Alternatives and tradeoffs:** missing alternatives, weak tradeoff discussion, unexplained choice
- **Edge cases and failure modes:** lifecycle, invalid states, concurrency, recovery, degraded modes, partial failure
- **Terminology drift:** inconsistent or overloaded terms, or terms that diverge from project/codebase norms
- **Structure and completeness:** missing key sections, duplicated content, confusing sequencing, unclear in-scope vs out-of-scope boundaries
- **Observability and validation:** vague or non-actionable claims about how the design will be validated

Do **not** treat implementation detail, code structure, rollout mechanics, or task breakdown as in scope unless the design explicitly makes them part of the design.

Do **not** create findings based only on personal doc preferences.

## Adversarial re-review standard
On the re-review pass, actively try to break the design by asking:
- What would an implementer still have to guess?
- Where could two engineers implement different behaviors from this doc?
- What assumptions only exist implicitly?
- What happens off the happy path?
- Where is the rationale too weak to justify the chosen design?
- Where do terms or responsibilities drift across sections?

## Finding requirements
Every finding must include:
- **ID**
- **Severity:** blocker / major / minor / nit (same scale as 03 and 05)
- **Type:** contradiction / unsupported claim / ambiguity / missing decision / assumption gap / tradeoff gap / edge-case gap / terminology / structure / observability
- **Location:** section name and, when possible, a short quote or excerpt
- **Problem**
- **Why it matters for the design**
- **Suggested fix:** exact wording or bullet-level guidance
- **Evidence:** exact quoted text or concrete reference from the document that triggered the finding

Do not report a finding unless you can point to the text that caused it.

## Editing constraints
- Prefer minimal, local edits.
- Preserve structure, specificity, and intent.
- Do not summarize away detail.
- Do not weaken accurate claims just to make wording safer.
- Do not expand scope into implementation.
- Do not rewrite for style unless it resolves a real design issue.
- Do not invent filler nits to justify additional passes.

## Optional: code-grounding
If the design references existing behavior, APIs, types, files, or constraints, you may verify those against the codebase. **When the design references existing code, code-grounding is recommended** so findings about the codebase are accurate; if you skip it, mark any such findings as **unverified** or **conditional**.

When code-grounding:
- Identify the branch / baseline inspected
- Inspect the relevant files before claiming a symbol, API, flow, or behavior exists or does not exist
- Distinguish clearly between:
  - present on the inspected baseline
  - present only on some branches / patches inspected
  - not found in inspected code
  - not verified
- Never infer existence or behavior from naming alone
- If inspection is partial, say exactly what was inspected and what was not
- If repo state may differ across dev, feature branch, or patch-applied build state, explicitly name which state was inspected and avoid collapsing them into a single “the codebase does X” claim.

If the design is greenfield or does not depend on current codebase truth, you may skip code-grounding.

## Required output per iteration

### Iteration N Review Report
Include all findings.

### Iteration N Edits Applied (if any)
Describe only the actual edits made.

### Iteration N Residual Issues
List unresolved issues that remain after edits.

### Iteration N Coverage Check
State whether each area was reviewed and whether it passed or produced findings:
- problem statement / goals / success criteria
- assumptions and constraints
- design decisions and rationale
- alternatives and tradeoffs
- edge cases / failure modes
- terminology and consistency
- structure / scope / completeness
- observability / validation

### Iteration N Pass Quality Check
State:
- whether the full doc was re-read this iteration
- whether new findings were found
- whether prior findings were confirmed resolved or still open

## Self-review

After completing the finding and edit passes and before presenting the final status, perform a **full self-review**:

1. **Re-read the entire design doc** — As if you did not write it. Look for new contradictions, unclear wording, or overclaiming introduced by any edits.
2. **Confirm every blocker and major finding has been addressed** — Either fixed by edits or explicitly accepted as residual risk; no blocker or major left unresolved without reason.
3. **Confirm pass quality** — The full doc was re-read on the final pass; no new substantive issue was found.

If the self-review finds a missed issue or an unresolved blocker/major, address it and re-run the self-review until it passes. Only then present the final status.

## Completion rule
You may conclude the design doc review only when:
- at least 2 full passes have been completed (3+ for long, high-risk, or cross-cutting docs)
- no blocker or major issues remain
- the final pass finds no new substantive issue
- **Self-review has been completed and passed** (re-read doc, confirm every blocker and major finding addressed, confirm pass quality)
- you explain briefly why further passes are unlikely to produce more than low-value editorial feedback or nits

## Final output
### Final Status
- **Verdict:** clean / clean with minor nits / needs revision
- **Summary**
- **Final issues resolved**
- **Remaining low-value nits**
- **Residual design risks accepted**
- **Questions intentionally deferred by the design** (if any)

---

### Changelog
| Version | Date | Change |
|---------|------|--------|
| 1.5 | 2026-03-17 14:15 CET | Default: review + report + apply doc edits (fix-and-update); review-only when user explicitly requests. Pass quality: do not restate prior findings for pass count; each pass adds new scrutiny, confirms resolutions, or identifies proof gaps. |
| 1.4 | 2026-03-17 12:51 CET | Design doc path: user provides or has open (typically docs/in-progress). Completion rule: Self-review must be completed and passed. Code-grounding: recommended when design references existing code; if skipped, mark findings unverified/conditional. |
| 1.3 | 2026-03-17 12:18 CET | Severity: added nit (aligned with 03, 05). Self-review section: re-read doc, confirm blocker/major addressed, confirm pass quality. |
| 1.2 | 2026-03-17 10:15 CET | Finding type list: added observability; added changelog. |
| 1.1 | 2026-03-17 09:30 CET | Design-only scope, evidence requirement, pass quality check, adversarial re-review. |