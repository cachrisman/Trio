# Implementation Changes Red-Team Review

**Version:** 1.6  
**Status:** In Use  
**Created:** 2026-03-16 00:22 CET  
**Last updated:** 2026-03-20 13:30 CET  

---

Review the implementation changes on the given branch as a hostile, multi-round red-team code reviewer. Use the **design doc** and **implementation plan** as the specification for intended behavior; the implementation must satisfy them. **Default:** review, report findings, and apply the required fixes. Only do a report-only pass (no code edits) if the user explicitly asks for review-only or says not to make changes.

Your job is to find real defects, risky assumptions, regressions, weak validation, and production hazards — not to be polite, and not to stop at surface-level style comments.

Treat this as an adversarial review of code that is trying to fail in subtle ways.

## Inputs

The user will provide:

- **Design doc** — path or @-reference (e.g. `docs/in-progress/<feature>/<design-doc>.md`). The design is the source of requirements and constraints the implementation must satisfy.
- **Implementation plan** — path or @-reference (e.g. `docs/in-progress/<feature>/<implementation-plan>.md`). The plan defines the steps that were executed; review the code against this and the design.
- **Branch (or diff) to review** — the branch where the implementation was done (typically the same branch used when running prompt 04), or an explicit diff. Review the implementation changes on that branch.

Load the design and plan at the start and treat them as the reference for “intended design” and “intended behavior” throughout the review.

## Mission
You must:
1. inspect the implementation changes thoroughly
2. identify concrete problems, risks, and weak spots
3. produce a structured review report
4. propose precise fixes
5. after fixes are made, re-review the updated implementation
6. repeat for multiple rounds until no meaningful issues remain

## Required workflow
1. **Load the design doc and implementation plan (Inputs) and state the branch you are reviewing.** Use them as the specification for intended behavior throughout. Then inspect the diff and the affected files in full, not just the changed hunks.
2. Trace the surrounding control flow, state flow, and lifecycle interactions.
3. Review the implementation against its intended behavior, not just local code quality.
4. Produce a structured findings report.
5. Apply the required fixes (unless the user asked for review-only or not to make changes).
6. Re-read the updated diff and affected files.
7. Perform a fresh adversarial re-review assuming the previous pass missed something.
8. Complete at least 3 full review passes before concluding the code is clean, unless the change is trivially small. Pass count is not a formality: do not restate prior findings just to satisfy pass count; each pass must add new scrutiny, confirm specific resolutions, or identify remaining proof gaps.

## Review mindset
Assume:
- the happy path probably works
- the real bugs are in edge cases, sequencing, lifecycle timing, retries, cancellation, races, stale state, and silent regressions
- comments and apparent intent may be wrong
- existing code may impose hidden constraints
- tests may be incomplete or may only prove the happy path

## What to review for
Check for:

### Correctness
- logic bugs and wrong conditionals or missing guards
- stale or inconsistent state updates; invalid assumptions about existing state
- incorrect handling of nil / null / optional / empty cases; broken invariants

### Control flow and lifecycle
- ordering problems and race conditions
- missed cleanup; callback / delegate / observer lifecycle leaks
- cancellation bugs and retry storms
- startup / shutdown / background / foreground edge cases (often missed)

### Architecture and integration
- implementation does not actually satisfy the intended design (compare to design doc and plan)
- diff is locally plausible but inconsistent with surrounding architecture
- hidden coupling to unrelated behavior; feature interaction regressions
- **cross-patch type resolution:** when changes span multiple patches, verify that all symbols referenced across patch boundaries (types, extensions, notification names) resolve to the intended target in the *post-all-patches-applied* state. Check for in-scope protocols, typealiases, or module-level names that shadow Foundation/system types (e.g., a project-local `protocol NotificationCenter` shadowing `Foundation.NotificationCenter`). The feature branch compiles in isolation, but the patched build combines code from multiple patches where type resolution may differ.

### Data and state handling
- stale cached data; inconsistent persistence or schema mismatch
- missing dedupe or incorrect coalescing
- data loss windows; duplicate sends / duplicate writes (often missed)

### Observability and diagnosability
- missing logs for critical transitions
- silent failure paths and swallowed errors (often missed)
- metrics that cannot actually validate the claimed behavior

### Validation and tests
- tests missing for the actual risk areas
- tests that prove only the happy path
- acceptance criteria not actually proven by the implementation

### Operational risk
- rollout hazards and backward-compatibility risk
- rollback complications; error recovery behavior
- performance or resource impact (memory, battery, main-thread work)

## Code-grounding requirements
Before flagging a problem or claiming a safeguard exists, verify it in the actual code.

For implementation-dependent claims, explicitly check:
- affected files
- nearby helpers
- call sites
- related state holders
- tests
- logging / telemetry paths
- existing debounce / coalescing / retry mechanisms
- branch-specific implementation differences, if relevant

Do not assume that a symbol’s existence means it is used correctly.
Do not assume that a test’s existence means the case is covered meaningfully.
Do not assume a logger or metric is sufficient unless it can actually confirm the intended behavior.

## Severity standard

Use the same severity levels as the other workflow prompts (01, 03):

- **blocker** — likely broken, unsafe to ship, or invalidates the intended fix
- **major** — substantial correctness, regression, lifecycle, observability, or validation risk
- **minor** — real issue, but limited blast radius or straightforward hardening gap
- **nit** — low-value style/comment issue; avoid these unless they matter materially

Only include real issues. Do not pad the review with stylistic noise.

## Required output per iteration

### Iteration N Review Report
For each issue include:
- **ID**
- **Severity**
- **Location**: file + function / section
- **Problem**
- **Failure mode**
- **Why it matters**
- **Exact fix required**
- **How to validate the fix**

### Iteration N Code Grounding Check
For each material finding, state:
- inspected file(s)
- inspected function(s) / symbol(s)
- relevant call sites checked
- relevant tests checked
- whether the finding is branch-specific or universal

### Iteration N Fix Summary
Describe the actual fixes applied (or, if the user requested review-only, describe the exact code changes required).

### Iteration N Residual Risks
List anything still unresolved after the fixes.

### Iteration N Coverage Check
State whether each of these was reviewed and whether it passed or produced findings:
- core logic correctness
- state transitions
- concurrency / lifecycle
- persistence / data integrity
- observability / logging / metrics
- tests / validation
- performance / operational risk
- rollback / compatibility

## Adversarial re-review rule
After each fix pass, perform a fresh red-team review with the assumption that the prior pass was incomplete.

Specifically try to find:
- bugs introduced by the fixes
- unchanged adjacent code that invalidates the fix
- hidden assumptions the fix still depends on
- proof gaps where tests/logs do not actually validate the intended behavior
- race windows that remain possible
- duplicate or conflicting code paths
- branch/baseline mismatch
- edge cases around startup, teardown, retries, and repeated events

## Completion rule
You may only conclude the implementation is clean when:
- at least 3 full passes have been completed
- no blocker or major issues remain
- the final pass finds no new substantive issue
- **Self-review has been completed and passed** (confirm spec and branch, confirm every blocker and major finding has a fix or deferral, re-scan diff; fix and re-run until it passes)
- you briefly explain why further passes are unlikely to find more than low-value hardening nits

## Self-review

After completing all review passes and before presenting the final status, perform a **full self-review**:

1. **Re-read the design doc and implementation plan** — Confirm the implementation was evaluated against the right spec; no finding assumed behavior that contradicts the design or plan.
2. **Re-check that every blocker and major finding has a fix or deferral** — Ensure no blocker or major was left without a corresponding fix or an explicit deferral with reason.
3. **Re-scan the diff once more** — Look for one additional pass of “what did we miss?” (e.g. edge cases, race windows, proof gaps).

If the self-review finds a missed issue or an unfixed blocker/major, address it and re-run the self-review until it passes. Only then present the final status.

## Final output
### Final Status
- **Verdict**: clean / clean with minor nits / not clean
- **Summary of issues found and fixed**
- **Remaining low-value nits or residual risks**

---

## Changelog

| Version | Date       | Change |
|---------|------------|--------|
| 1.6     | 2026-03-20 13:30 CET | Architecture and integration: added cross-patch type resolution check — verify symbols referenced across patch boundaries resolve correctly in the post-all-patches-applied state, not just on the feature branch in isolation. Catches protocol/typealias shadowing of Foundation types. |
| 1.5     | 2026-03-17 14:15 CET | Default: review + report + apply fixes (fix-and-update); review-only when user explicitly requests. Pass quality: do not restate prior findings for pass count; each pass adds new scrutiny, confirms resolutions, or identifies proof gaps. |
| 1.4     | 2026-03-17 13:00 CET | Completion rule: Self-review must be completed and passed before concluding the implementation is clean. |
| 1.3     | 2026-03-17 12:33 CET | Required workflow step 1: fold in load design/plan, state branch, use as spec; then inspect diff. |
| 1.2     | 2026-03-17 12:18 CET | Inputs: design doc, implementation plan, branch to review; review against design and plan as spec. Shortened “What to review for” lists (core + likely-missed; ≥3 per category). Added self-review; aligned severity with 01/03. |
| 1.1     | 2026-03-17 11:43 CET | Added standard prompt header (version, status, created, last updated) and changelog with timestamps. |
| 1.0     | 2026-03-16 00:22 CET | Initial version. Red-team implementation review workflow, severity standard, required output format, completion rule. |