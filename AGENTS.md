# AGENTS.md

Instructions for AI agents working in this repository.

This repo is a personal fork that maintains a patch stack in `./patches/` applied on top of upstream `dev`. Agents should optimize for repeatable patch application and safe builds.

Read first:
- `docs/feature-branch-workflow-optimization.md`
- `docs/feature-branch-workflow-optimization-patch-migration.md` (only during migration/cutover work)

## Non-negotiable safety rules

1) **Never upload to TestFlight unless explicitly instructed.**
   - Default to **build-only** for local builds.
   - Do not run `fastlane release` unless explicitly requested.

2) **Never print or inspect secrets** (including `.trio-env`, signing secrets, API keys, tokens).

3) **Do not perform destructive submodule cleanup** (no `git clean` / `git reset` inside submodules) unless explicitly instructed.

4) **Do not change bundle IDs, signing, or Fastlane lanes** unless explicitly instructed.

5) **Do not hand-edit patch files to fix apply failures.**
   - Fix code and regenerate the patch.

6) **Do not commit/push** unless explicitly asked.
   - Summarize changes first.

7) **For plan/workflow document edits, increment the document version and update the changelog.**
   - When editing plan/workflow docs (e.g., `*.plan.md`, `*.cursor.md`, workflow prompts/checklists), always increment the document's version number and update the changelog section in the same change.

## Non-negotiable rules for working with patches

1) **Keep patch filenames and ordering deterministic.**
   - Numeric prefix `NN-` defines ordering; ordering is alphabetical by filename.

2) **`generate-patch.sh` remains the canonical patch generator post-cutover.**
   - It will emit mailbox patches suitable for `git am` (temporary `*.am.patch` during cutover, then `*.patch` steady-state).

## Key invariant

A clean checkout of fork `dev` (synced to upstream) must be able to apply all patches in `./patches/` in order using `git am`.

## Common workflows

### Build current branch (no patches, no upload)
```bash
ci/local-build.sh --build-current --build-only
```

### Simulate CI build: dev + patch stack (no upload)
```bash
ci/local-build.sh --base-branch dev --build-only
```

### Validate patch stack (authoritative)
```bash
scripts/patch-test.sh
```

### Generate a patch (preferred)
```bash
./scripts/generate-patch.sh -n -d "short-description"
```

Manual (single commit):
```bash
# Steady state (post-cutover): mailbox patch with .patch extension
git format-patch -1 --stdout HEAD > patches/NN-short-description.patch
git am --check patches/NN-short-description.patch

```

## Upstream sync (local)

```bash
git remote add upstream https://github.com/nightscout/Trio.git   # if not present
git checkout dev
git fetch upstream
git merge upstream/dev
git push origin dev
```

After syncing, re-run the patch validation.

## Optional: convert git-apply patch to git-am mailbox patch (provenance)

## Reporting template

- Goal
- Changes made (file-by-file)
- Commands run
- Result
- If failure: top error excerpt + likely cause + next step
- If success: next step (patch gen, patch validation, build)

---

## Better Stack MCP Usage

### Authentication

- Before issuing any queries, authenticate with the Better Stack MCP server to obtain the required credentials.
- Use the provided authentication flow to retrieve the username and password or token needed for subsequent MCP tool calls.
- **Never log, echo, persist, or summarize authentication credentials in chat output.**

### Querying Better Stack via MCP

- Use the Better Stack MCP server to query logs and events related to Trio and Nightscout.
- Prefer scoped, time-bounded queries (e.g., last 1h, 6h, 24h) rather than unbounded searches.
- When available, filter by service, source, tag, or severity (e.g., `trio`, `nightscout`, `sensor`, `carbs`, `errors`, `warnings`).
- If a query returns excessive data, refine it by narrowing the time range or adding filters before retrying.

### Suggested default queries

- "Show errors and warnings from Trio in the last 6 hours."
- "List Nightscout anomalies or ingestion issues in the last 24 hours."
- "Were there any data gaps or missing entries longer than 20 minutes in the last day?"
- "Show log events within ±15 minutes of a specified timestamp (e.g., when a BG spike or drop occurred)."
- "Summarize repeated warnings or unusual patterns since midnight."

### Interpretation & summarization

- Summarize findings in plain language before citing specific timestamps or log excerpts.
- Highlight correlations across systems (e.g., Trio and Nightscout events occurring close together).
- Explicitly state when no relevant events are found for the queried time window.
- Prefer concise summaries over raw log dumps unless the user explicitly requests details.

---

## Diabetes & Nightscout Safety Guardrails

- Treat all Nightscout and Trio data as **observational telemetry**, not medical guidance.
- Do not infer intent, causality, or clinical meaning beyond what is directly supported by logs.
- When summarizing BG-related events, use neutral phrasing such as:
  - "A rapid rise was observed"
  - "Data indicates a gap or ingestion delay"
  - "No anomalies were detected in the logs"

**Goal:** Help the user quickly answer "what happened?" by turning Better Stack logs into clear, time-scoped, non-speculative summaries while maintaining strict safety and privacy boundaries.
