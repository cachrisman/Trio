# Feedback Crosswalk Prompt v1.0

You are updating an implementation plan based on reviewer feedback from two reviewers.

Inputs:
- Implementation plan (current version)
- Reviewer feedback (bulleted lists)
  - R1 feedback from ChatGPT
  - R2 feedback from Claude

Task:

A) Cross-reference & deduplicate feedback
1) Normalize both lists into a single set of “issues” (merge duplicates and near-duplicates).
2) For each normalized issue, record support:
   - Raised by: R1 only / R2 only / Both
   - Any conflict: if R1 and R2 recommend different fixes, note the conflict explicitly.

B) Disposition (for each normalized issue)
- Mark: APPLIED / PARTIALLY APPLIED / REJECTED.
- If PARTIALLY APPLIED or REJECTED:
  - Provide a concise technical justification (1–3 sentences).
  - If rejecting, propose an alternative mitigation if applicable.

C) Plan update
- Update the plan text to reflect APPLIED/PARTIALLY APPLIED items.
- Keep plan scope unchanged (no new features unless explicitly required by feedback or necessary to preserve correctness).
- Preserve or improve phase sequencing; do not create unsafe ship boundaries.
- If sequencing changes, explain why in one sentence.

D) Verification quality
- For any task you modify, ensure acceptance criteria are objective and testable:
  - logs contain X (exact event/field)
  - metric Y exists and excludes Z (exact filter)
  - dashboard query returns non-empty results for a known test action
  - unit/integration test passes
- Demote speculative numeric targets (e.g., “should be ~60–90%”) into a “Hypotheses/Expectations” note, not acceptance criteria.

E) Versioning
- Increment plan version.
- Update changelog with a bullet list of concrete edits (what changed, where, why).

Deliverables (in order):
1) “Feedback crosswalk” table:
   - Normalized issue
   - Raised by (R1 / R2 / Both)
   - Disposition (Applied / Partial / Rejected)
   - Rationale
   - Where implemented (phase/task + file/section)
2) Updated implementation plan (full text, vNext)
3) “Risks & mitigations” (only if changed by edits)
4) “Hypotheses/Expectations” (optional; only if you moved speculative targets out of acceptance criteria)

Notes:
- Treat “Raised by Both” as high priority unless there is a concrete technical reason not to.
