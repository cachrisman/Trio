# Red-Team Design + Implementation Plan Review Prompt

Red-team review these Nightscout/Better Stack design and implementation-plan docs as a hostile, multi-round reviewer, then edit the docs to fix the problems.

Your job is not to be polite. Your job is to find real defects, hidden assumptions, internal contradictions, missing implementation decisions, repo-fit problems, rollout hazards, observability gaps, and places where the plan sounds plausible but would fail in real implementation.

Treat this as adversarial review of docs that may look complete while still being operationally unsafe, logically inconsistent, or not actually buildable.

⸻

# Inputs

Review these docs together:
	•	docs/completed/nightscout-sawtooth-precompute/nightscout-sawtooth-precompute-service.md
	•	docs/completed/nightscout-sawtooth-precompute/nightscout-precompute-implementation-plan.md

You must verify both:
	1.	Whether the design and implementation plan are technically sound
	2.	Whether the implementation plan actually matches and faithfully operationalizes the design doc

Also verify alignment against the current agreed architecture:
	•	No Trio app changes
	•	Trio Better Stack logs source remains the source of truth
	•	Separate Better Stack Prometheus-push source for derived metrics
	•	Nightscout-hosted standalone script + cron for v1
	•	Checkpoint-based idempotency
	•	Emit delay / emit ceiling
	•	Off-wrist zero handling
	•	Do not rely on Better Stack duplicate timestamp overwrite/upsert behavior

⸻

# Project specific instructions

	•	Verify the existing Better Stack source split remains explicit:
	  •	Trio logs source for reads
	  •	Trio Complication Recency Prometheus source for writes
	•	Treat complication_visible_recency_seconds as fixed unless the docs themselves justify changing it
	•	Do not convert the design into a simpler 5-minute proxy
	•	Do not assume Better Stack historical overwrite/upsert behavior for duplicate metric timestamps
	•	Prefer cron + standalone script + local checkpoint file for v1 unless repo evidence proves that impossible
	•	increment the version number and update the changelog section

⸻

# Baseline declaration

Before starting Pass 1, explicitly state:
	•	the branch / repo / baseline being reviewed
	•	whether the review is against docs only, docs + code, or docs + repo structure
	•	whether the implementation plan is greenfield or partially grounded in existing Nightscout repo conventions
	•	any repo/baseline uncertainty that makes a conclusion conditional

If the baseline is mixed or incomplete, explicitly say so and mark any conclusion that depends on missing implementation as conditional or unverifiable, not universal.

⸻

# Conflict resolution rule

Treat the design doc as the higher-level specification and the implementation plan as the execution plan.

When the two docs conflict:
	•	treat the design doc as the source spec unless there is clear evidence the implementation plan intentionally supersedes it and the change is justified
	•	flag the discrepancy as a defect
	•	do not silently narrow requirements in the implementation plan to make them easier
	•	do not weaken the design doc casually unless the text genuinely supports it

Also flag the reverse:
	•	implementation detail required by the implementation plan but absent from the design doc
	•	design requirement present in the design doc but missing from the implementation plan

⸻

# Required workflow

The review runs in three phases. Do not collapse them.

## Phase 1 — Finding passes (no edits)

Run at least two full finding passes.

Continue until:
	•	at least two full finding passes have been completed, and
	•	two consecutive passes produce no new blocker or major findings, and
	•	the later of those passes produces at most a small number of low-value minor findings

Each pass must:
	1.	Read both docs fully.
	2.	Check internal consistency within each doc.
	3.	Check cross-doc consistency between design and implementation plan.
	4.	Inspect the current Nightscout repo structure and conventions where relevant.
	5.	Inspect any referenced Better Stack assumptions already documented in the project docs.
	6.	Produce a structured findings report.

Do not limit review to changed sections only. Inspect surrounding sections to verify that the docs still make sense as a whole.

⸻

## Phase 2 — Primary edit pass

After finding passes converge, make one coherent doc-edit pass, highest-severity first.

Prefer resolving all known findings in one coherent update rather than many churny partial rewrites.

Edits should be:
	•	additive when possible
	•	tightly localized when possible
	•	structure-preserving unless structure itself is part of the problem

⸻

## Phase 3 — Regression pass

Re-read both edited docs as if the fixes introduced new mistakes.

Look specifically for:
	•	new contradictions introduced by the edits
	•	cross-reference drift
	•	version/changelog inconsistencies
	•	implementation steps that no longer match the architecture
	•	wording that now overclaims certainty
	•	places where a fix in one doc created doc drift in the other

If Phase 3 finds a new blocker or major issue introduced by the edits, perform one targeted follow-up edit pass, then re-run the regression pass.

⸻

# Review focus

Be especially skeptical about these areas:

1) Architecture correctness
	•	two-source Better Stack model stays intact
	•	Trio logs source is read-only input, not overloaded with derived writes
	•	Prometheus source is metrics-only derived output
	•	Nightscout is the host for the worker, not the semantic source of truth
	•	no silent reintroduction of “latest 2 GTLs only” logic
	•	no silent collapse from minute-level reconstruction to coarse bucket proxy unless explicitly intended

2) Design-to-plan conformance
	•	implementation plan preserves the actual design semantics
	•	checkpointing, emit delay, empty-result handling, off-wrist zero handling, dedupe, and push behavior are all implemented in the intended places
	•	the implementation plan does not quietly omit hard parts that the design doc includes
	•	the implementation plan does not add behavior that changes the design contract without calling it out

3) Better Stack query/push correctness
	•	correct source split
	•	correct ingest endpoint assumptions
	•	correct use of gauge metric shape
	•	correct query shape for the derived metric source
	•	correct understanding of timestamp handling
	•	no hidden reliance on undocumented overwrite/dedupe/upsert behavior
	•	no inconsistent use of logs query API vs metrics ingest API

4) Reconstruction algorithm correctness
	•	minute anchor selection matches the intended Explore-equivalent semantics
	•	dedupe rules are fully specified and deterministic
	•	tie-break behavior is explicit
	•	emit ceiling / delay is actually reflected in the algorithm, not just the risks section
	•	empty GTL window behavior is explicit and operationally safe
	•	late-ingestion tradeoff is described honestly
	•	checkpoint advancement rules are precise and failure-safe

5) Nightscout repo fit
	•	file/module placement is realistic for the repo
	•	cron vs in-process choice is consistent
	•	config/env var style matches repo conventions where possible
	•	logging/error handling style fits the repo
	•	rollout/rollback steps are realistic for Nightscout deployment
	•	no invented subsystems, job runners, or abstractions unless verified

6) Operational safety
	•	partial failure behavior is explicit
	•	batching strategy is clear
	•	retry behavior is defined enough to implement safely
	•	no accidental infinite backfill
	•	no accidental permanent silent gaps without documentation
	•	no concurrency hazards like double writers or mixed cron/in-process execution
	•	rollback is simple and real, not aspirational

7) Observability and validation
	•	logs/metrics are sufficient to validate the worker end to end
	•	doc explains how to prove the output is correct vs Explore
	•	doc distinguishes “no data because no GTL” vs “no data because worker failure”
	•	validation plan is concrete enough for implementation and rollout
	•	acceptance criteria are actually testable

8) Documentation quality under adversarial scrutiny
	•	no stale section references
	•	no “see below” references to missing sections
	•	no changelog/version drift
	•	no open-item list that contradicts resolved sections
	•	no overclaiming “validated” where the text still contains uncertainty
	•	no unresolved placeholder language like “handle retries,” “query recent logs,” or “appropriate merge” unless intentionally marked as open

⸻

# Repo-grounding requirement

Do not hallucinate.

Before claiming that a Nightscout hook, cron convention, script location, env var pattern, logging style, or config mechanism exists or does not exist, verify it in the actual repo if accessible.

For every material finding, state:
	•	file(s) inspected
	•	section(s) inspected
	•	repo path(s) inspected
	•	symbol/module/script/config pattern inspected
	•	whether the claim is grounded in docs only, repo only, or both
	•	whether the finding is baseline-specific, conditional, or universal

Explicitly distinguish:
	•	not present in the inspected repo
	•	present but unused
	•	recommended as new
	•	assumed by docs but not verified
	•	verified and aligned

If a required repo file/path cannot be inspected, mark related claims as unverifiable rather than inferring.

⸻

# Required conformance checks

You must verify all of the following:

Design conformance
	•	implementation plan preserves the stated mechanism
	•	implementation plan does not silently narrow or expand scope
	•	stated risks and mitigations remain reflected in the implementation plan
	•	success criteria remain testable from the proposed implementation and observability

Implementation-plan conformance
	•	steps are sequenced realistically
	•	required modules/files are identified
	•	required config/env vars are present
	•	required logging/metrics are specified
	•	rollout and rollback are actually supportable
	•	branch/repo-sensitive instructions are handled correctly

Cross-doc consistency

Flag both directions:
	•	required by design but missing in implementation plan
	•	present in implementation plan but absent, contradictory, or unjustified in design
	•	same concept described differently across the two docs in a way that could cause implementation mistakes

⸻

# Severity standard
	•	blocker — invalidates the design, unsafe to implement, or likely to fail operationally
	•	major — substantial correctness, consistency, implementation-readiness, operational, observability, or repo-fit risk
	•	minor — real issue with limited blast radius or straightforward hardening/documentation gap
	•	nit — wording/style only; no corresponding edit required unless chosen

Only include real issues. Do not pad.

⸻

# Required output format

## Finding report (each Phase 1 pass and the Phase 3 regression pass)

For each issue:
	•	ID
	•	Severity
	•	Location: doc + section / anchor
	•	Grounding: docs inspected, repo files/paths inspected, project docs inspected, whether repo-grounded or docs-only, whether conditional/unverifiable
	•	Problem
	•	Failure mode
	•	Why it matters
	•	Exact fix required
	•	How to validate the fix

End each pass with a short Pass verdict:
	•	what was found
	•	what the next pass will focus on
	•	whether the exit criterion has been met

⸻

## Edit pass summary (Phase 2)

Report:
	•	exact doc changes made
	•	which finding IDs were resolved
	•	any finding intentionally deferred and why
	•	any adjacent unresolved issue that should be re-checked in Phase 3
	•	version/changelog updates made

⸻

## Regression pass report (Phase 3)

Same format as a finding report, but focus specifically on:
	•	contradictions introduced by edits
	•	stale references or renamed sections
	•	design/plan drift introduced by edits
	•	overclaiming certainty after fixes
	•	algorithm text no longer matching examples/pseudocode
	•	version/changelog/status inconsistency
	•	newly introduced ambiguity in rollout, retry, checkpointing, or Better Stack behavior
	•	any new repo-fit problem introduced by the edits

⸻

# Editing rules
	•	Make the smallest localized doc change that fully resolves each issue.
	•	Preserve surrounding structure unless structure itself causes confusion or contradiction.
	•	Do not broadly rewrite both docs unless necessary.
	•	Keep implementation plan aligned with the design doc after every edit.
	•	If a doc change implies implementation impact, say so explicitly.
	•	Do not declare docs “clean” because the happy path sounds plausible.

⸻

# Completion rule

You may only conclude the docs are clean when:
	•	Phase 1 has run until two consecutive passes produce no new findings of major severity or above
	•	Phase 2 edits have been applied
	•	Phase 3 regression pass is complete and finds no new blocker or major issues
	•	you briefly explain why further passes are unlikely to surface more than low-value nits

⸻

# Final output

## Final Status
	•	Verdict: clean / clean with minor nits / not clean
	•	Summary: all issues found across all passes and their resolution status
	•	Residual risks: unresolved concerns and their severity
	•	Required doc updates: any documentation still inaccurate or incomplete
	•	Implementation impact: any change to plan sequencing, config, module layout, rollout, or observability caused by the doc edits
	•	Unverifiable items: any conclusions that could not be fully grounded due to missing/inaccessible repo files or unverified platform behavior

## Final coverage attestation

State whether each area was reviewed and whether it passed or produced findings:
	•	Core architecture correctness
	•	Design ↔ implementation-plan conformance
	•	Better Stack source/query/ingest assumptions
	•	Reconstruction algorithm correctness
	•	Checkpointing / idempotency / delayed-ingestion behavior
	•	Nightscout repo fit
	•	Logging / observability / validation
	•	Rollout / rollback / operational safety
	•	Versioning / changelog / cross-references
