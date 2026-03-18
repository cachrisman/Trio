# Red-Team Code Review Prompt

Red-team review the implementation changes for this Trio feature as a hostile, multi-round reviewer, then fix the code.

You are reviewing a Swift / iOS / watchOS implementation where subtle lifecycle, concurrency, background execution, telemetry, persistence, and compatibility issues matter.

Your job is not to be polite. Your job is to find real defects, risky assumptions, regressions, validation gaps, and production hazards, then edit the code to address them.

Treat this as adversarial review of code that may appear correct on the happy path while still failing in the real app.

---

## Inputs

Review the implementation changes in this branch/patch against:
- `docs/in-progress/complication-freshness/complication-freshness-implementation-guide.md`
- `docs/in-progress/complication-freshness/complication-freshness-remediation-plan.md`

You must verify both:
1. Whether the implementation is technically sound
2. Whether the implementation actually matches the design and plan

---

## Baseline declaration

Before starting Phase 1, explicitly state:
- the branch / patch / baseline being reviewed
- whether the review is against the live working tree, a patch file, or a mixed docs+code state
- any known branch-sensitive implementation differences that may affect findings

If the intended baseline is ambiguous or mixed, explicitly say so and mark any branch-sensitive conclusion as conditional or unverifiable rather than universal.

## Conflict resolution rule

When design docs and code contradict each other, treat the design docs as the specification. Flag the discrepancy and treat it as a code defect unless you have explicit evidence the docs are known-stale. Do not resolve a code-vs-doc mismatch by casually weakening or narrowing the docs unless the text genuinely supports that interpretation. If the code only matches a weaker interpretation than the docs state, treat that as a conformance defect.

---

## Required workflow

The review runs in three phases. Do not collapse them.

### Phase 1 — Finding passes (no edits)

Run at least two full finding passes. 

Continue until:
- at least two full finding passes have been completed, and
- two consecutive passes produce no new blocker or major findings, and
- the later of those passes produces at most a small number of genuinely low-value minor findings.

Each pass:
1. Read `complication-freshness-implementation-guide.md` and `complication-freshness-remediation-plan.md` fully.
2. Inspect the implementation diff.
3. Inspect the full affected files, not just changed hunks.
4. Trace all related helpers, state holders, call sites, delegate paths, observers, async tasks, persistence, logging, and tests.
5. Produce a structured findings report (format below).

Inspect enough unchanged surrounding code to verify that the edited code still behaves correctly in context. Do not limit review to changed hunks or directly edited symbols.

### Phase 2 — Primary edit pass

After finding passes converge, make a primary edit pass, highest-severity first. Prefer to resolve all known findings in one coherent pass rather than many small churny edit rounds.

### Phase 3 — Regression pass

Re-read all edited code plus adjacent unchanged code. Assume the edits introduced new bugs. Look specifically for regressions, not just re-confirmation of original findings.

If Phase 3 finds a new blocker or major issue introduced by the edits, perform one targeted follow-up edit pass to resolve it, then re-run the regression pass.

---

## Trio-specific review focus

Be especially skeptical about:

### WatchConnectivity / app lifecycle
- `WCSession` activation timing
- delegate callback storms
- duplicate sends / duplicate receives
- message vs applicationContext semantics
- stale application context reuse
- startup relaunch loops
- foreground/background differences
- watch app relaunch caused by connectivity activity
- ordering problems between activation, delegate callbacks, and app state restoration
- repeated work triggered by both connectivity and publisher/state observation paths
- whether a fix suppresses the crash/reload storm without suppressing legitimate updates

### Coalescing / debounce / scheduling
- duplicate coalescers on different paths
- branch-specific coalescing assumptions
- stale pending work items
- lost updates due to cancellation
- repeated scheduling with inconsistent keys/state
- timer/debounce logic that fails across app relaunch or background transitions
- delegate-triggered and publisher-triggered paths interfering with each other

### Persistence / snapshot / state integrity
- stale snapshot reuse
- partial writes
- missing atomicity
- mismatched schema assumptions
- state surviving relaunch in harmful ways
- dedupe state not persisted when needed
- persisted suppression flags that block valid future behavior
- App Group read/write assumptions
- phone/watch shared-state compatibility

### Background execution / tasking
- assumptions that work will complete after notification actions, background launches, refresh tasks, or app lifecycle transitions
- operations started without enough execution budget
- unbounded retries
- duplicate background refresh requests
- cleanup not guaranteed on interruption
- hidden reliance on foreground-only behavior

### Telemetry / observability
- missing logs for key transitions and decisions
- logs too vague to diagnose real failures
- metrics that cannot prove the claimed fix
- inability to distinguish suppression, coalescing, stale-data gating, retry, dedupe, and success paths
- no evidence path for validating that the crash-loop or storm was actually removed

Specifically verify that telemetry can distinguish all of the following independently:
- suppressed duplicate startup events
- legitimate update sends
- stale-data gating decisions
- complication reload attempts
- actual timeline refresh consumption
- crash-loop absence vs mere silence

For any fix that suppresses, coalesces, deduplicates, or rate-limits work, explicitly verify the proof burden:
- what evidence proves the bad path is suppressed
- what evidence proves legitimate behavior still occurs
- what evidence distinguishes true success from mere silence or lack of execution

### Swift correctness / concurrency
- actor/thread violations
- main-thread assumptions
- queue hopping bugs
- state captured incorrectly in async closures
- weak/strong self mistakes
- cancellation and task lifetime issues
- race conditions around mutable singleton/shared state
- callback reentrancy hazards

### Regression / ship safety
- fix works locally but breaks existing complication updates
- fix prevents legitimate urgent updates
- over-hardening that masks symptoms without fixing root cause
- behavior differs across `dev` vs feature baseline
- tests/logs only prove the happy path
- rollback path not obvious

Be highly skeptical of any fix that reduces event frequency without proving it preserves legitimate complication freshness. Verify that suppression and coalescing only affect the storm path and do not degrade normal update latency.

---

## Code-grounding requirement

Do not hallucinate.

Before claiming that a helper, state variable, debounce path, retry mechanism, symbol, or safeguard exists or does not exist, verify it in the actual code. For every material finding, state the file name and line number (or nearest identifiable anchor) where you verified the claim. If you cannot locate a symbol, say so explicitly — do not infer from context.

For every material finding, you must explicitly inspect:
- the relevant file(s) and line(s)
- the relevant symbol(s)
- nearby helpers
- the call site(s)
- related tests
- related logging/telemetry code
- related plan/design sections

You must explicitly distinguish:
- "not present in the inspected baseline"
- "present but unused / ineffective"
- "present on some branches/baselines but not others"
- "present and working as intended"

If a required file cannot be inspected (missing, wrong path, inaccessible), mark any finding that depends on it as **unverifiable** rather than inferring.

Do not remove or rewrite doc/code assumptions merely because you did not immediately see a symbol in one location. If baseline differences exist, preserve that distinction and review against the intended baseline rather than flattening branch-specific truth into a universal claim.

For any blocker or major finding, explicitly state whether there is meaningful automated test coverage for the affected behavior. If not, say so directly.

---

## Required conformance checks against the docs

You must verify all of the following:

### Design conformance
- The code implements the stated mechanism, not a different one
- The code does not silently narrow or expand scope
- The claimed risks and mitigations are actually reflected in code
- The success criteria are meaningfully testable from the implementation and telemetry

### Implementation-plan conformance
- The steps were implemented in the intended places
- Sequencing/dependencies match the plan
- Required logging/metrics are actually present and usable
- Acceptance/validation steps are actually supportable by the code
- Branch-sensitive instructions are handled correctly

Flag both directions:
- Required by docs but missing in code
- Present in code but missing or contradictory in docs

---

## Severity standard

- **blocker** — likely broken, unsafe to ship, or invalidates the intended fix
- **major** — substantial correctness, lifecycle, concurrency, regression, telemetry, or validation risk
- **minor** — real issue with limited blast radius or straightforward hardening gap
- **nit** — style or naming only; no corresponding edit required unless the author chooses

Only include real issues. Do not pad.

---

## Required output format

### Finding report (each Phase 1 pass and the Phase 3 regression pass)

For each issue:

- **ID**
- **Severity**
- **Location**: file + function/symbol/line anchor
- **Grounding**: files inspected, symbols inspected, call sites inspected, tests inspected, design/plan section inspected, whether baseline-specific or universal
- **Problem**
- **Failure mode**
- **Why it matters**
- **Exact fix required**
- **How to validate the fix**

End each finding pass with a one-paragraph **Pass verdict**: what was found, what the next pass will focus on, and whether the exit criterion has been met.

### Edit pass summary (Phase 2)

- Exact code changes made
- Which finding IDs were resolved
- Any finding intentionally deferred and why
- Any adjacent unchanged code that still needs attention (becomes a finding for Phase 3)

### Regression pass report (Phase 3)

Same format as a finding report. Focus specifically on:
- bugs introduced by the edits
- unchanged adjacent code that still undermines the intended fix
- duplicate or conflicting update paths
- stale-state windows that persist after the edits
- race windows around startup, delegate callbacks, and async work
- telemetry that still cannot prove the intended behavior
- doc/code drift introduced by the fixes
- suppression/coalescing logic that now drops legitimate updates
- any reliance on foreground execution or timing not guaranteed on watchOS/iOS

---

## Editing rules

- Make the smallest localized change that fully resolves each issue.
- Preserve surrounding architecture unless a deeper change is required to actually fix the root cause.
- Do not rewrite large areas unless necessary.
- Keep implementation aligned with the design and plan after every edit.
- The smallest-edit rule governs what you change. It does not prevent you from flagging adjacent unchanged code that still undermines the fix — those become new findings in Phase 3, not additional edit targets in Phase 2.
- If code changes require doc updates for accuracy, note them explicitly in the edit pass summary.
- Do not claim "clean" because the happy path looks correct.

---

## Completion rule

You may only conclude the implementation is clean when:
- Phase 1 has run until two consecutive passes produce no new findings of major severity or above
- Phase 2 edits have been applied
- Phase 3 regression pass is complete and finds no new blocker or major issues
- You briefly explain why further passes are unlikely to surface more than low-value nits

---

## Final output

### Final Status

- **Verdict**: clean / clean with minor nits / not clean
- **Summary**: all issues found across all passes and their resolution status
- **Residual risks**: unresolved concerns and their severity
- **Required doc updates**: any documentation that is now inaccurate relative to the edited code
- **Unverifiable items**: any conclusions that could not be fully grounded due to missing/inaccessible files or ambiguous baseline

### Final coverage attestation

State whether each area was reviewed and whether it passed or produced findings:
- Core logic correctness
- Lifecycle / startup / relaunch behavior
- WatchConnectivity behavior
- Coalescing / debounce / dedupe
- Persistence / App Group / snapshot handling
- Concurrency / async / queueing
- Telemetry / logs / metrics
- Tests / validation
- Performance / battery / operational impact
- Rollback / compatibility