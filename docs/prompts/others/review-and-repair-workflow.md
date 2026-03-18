Review `docs/in-progress/nightscout-sawtooth-precompute/nightscout-sawtooth-precompute-service.md` and iteratively fix it until it is materially clean.

You are expected to do a deep review, not a superficial consistency pass.

## Required workflow
1. Read the file(s) fully.
2. Produce a structured findings report.
3. Edit the file(s) to address the findings.
4. Re-read all the file(s) in full.
5. Perform a fresh adversarial re-review assuming the prior pass missed things.
6. Repeat for at least 3 full passes before concluding the doc(s) are clean, unless the file(s) are extremely short and trivially complete.

## Review standard
If there are more than one file, treat them files as one connected spec. Review for:
- contradictions within each file
- contradictions between files
- ambiguous or underspecified requirements
- incorrect technical claims or hidden assumptions
- design claims that are stronger than the evidence or acceptance criteria support
- implementation steps that do not fully satisfy the design
- missing edge cases, failure modes, lifecycle risks, or concurrency risks
- sequencing and dependency errors
- observability that is too vague to verify
- acceptance criteria that do not actually prove the intended behavior
- rollout, rollback, migration, and ship-boundary weaknesses
- duplicated, redundant, or unnecessarily complex sections
- terminology drift

## Editing constraints
- Prefer minimal, local edits.
- Preserve structure, detail, and intent.
- Do not summarize away specificity.
- Do not weaken claims just to make docs align unless that is the most accurate fix.
- Keep the two files aligned at all times.
- Do not invent stylistic nits to keep the loop going.
- Do not stop after fixing only wording or alignment issues; actively search for deeper technical omissions each pass.

## Code-grounding requirement
Before flagging any statement as inaccurate, verify it against the actual codebase for the intended implementation baseline.

You must:
- identify which branch / baseline you are grounding against
- inspect the relevant source files before declaring that a method, property, coalescer, call site, or behavior exists or does not exist
- explicitly distinguish:
  - “not present on this inspected baseline”
  - “present on some branches but not others”
  - “not present anywhere I inspected”
- avoid rewriting docs to remove a claim unless you have verified the claim is inaccurate for the intended baseline
- when branch variance exists, prefer branch-qualified wording over universal wording

## Required output per iteration

### Iteration N Review Report
For each issue include:
- ID
- Severity: blocker / major / minor
- Location: file + section
- Problem
- Why it matters
- Exact fix needed

### Iteration N Edits Applied
Describe the actual edits made to each file.

### Iteration N Residual Issues
List anything still unresolved.

### Iteration N Code Grounding Check
For each finding that depends on source truth, include:
- inspected branch / baseline
- inspected file(s)
- verified fact
- whether the fact is branch-specific or universal

### Iteration N Coverage Check
State whether each of these areas was reviewed and whether it passed or produced findings:
- problem statement / causality
- design changes
- edge cases
- risks and mitigations
- observability
- acceptance criteria
- rollout / compatibility
- implementation sequencing
- rollback / ship boundaries

## Completion rule
You may only conclude the documents are clean when:
- at least 3 full passes have been completed
- no blocker or major issues remain
- the final pass finds no new substantive issue
- you explain briefly why further passes are unlikely to produce more than editorial nits

## Final output
### Final Status
- Verdict: clean / clean with minor nits
- Final issues resolved
- Remaining low-value nits