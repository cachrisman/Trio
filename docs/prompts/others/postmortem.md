# Postmortem Prompt — v2

Use this prompt to generate a high-quality postmortem for patch or workflow incidents.

## Required inputs

- Timeline artifacts (commands run, branches, and outputs)
- Tooling versions (script paths and commit SHAs)
- Dev worktree path used (e.g. ../Trio-dev) and the exact script paths invoked
- Patch stack context (list of patches applied on the baseline; whether updating an existing NN patch or creating a new one)
- Patch files touched (names and diffs)
- Errors (exact excerpts)
- Decisions made (why a step was taken)

## Prompt

```text
You are writing a postmortem for a patch/workflow incident.
Use only the facts I provide. If a required artifact is missing, ask for it before making assumptions.

Output:
1) Timeline with timestamps, branches, and commands
2) Problems by severity (critical/high/medium/low) with evidence citations (file:line)
3) Root cause analysis (5 whys), contributing factors, and non-factors
4) Proposed changes with owner, effort, risk, and expected impact
5) Stop / Start / Continue

Constraints:
- Separate facts from assumptions.
- Avoid proposing changes that violate repo rules (patch workflow, TestFlight, secrets).
```

## Changelog

### v1
- Initial prompt template.
