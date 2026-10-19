# Authoring a custom Fusion workflow that actually executes — field notes

**Version:** v2
**Status:** Reference (hard-won)
**Created:** 2026-07-14
**Audience:** an agent building a custom Fusion workflow (via the operator MCP) and finding that tasks won't run.

---

**TL;DR:** Clone the spine of **`builtin:coding`** (the auto-executing default), *not* `builtin:coding-ideas` (a manual-promotion backlog). Put `start` in an `intake` column, work nodes in a `wip` column, human gates as `awaitInput` prompt nodes, and deliver output **inline** (not attachments/documents). Almost every "it won't run" problem is the **dispatch spine**, not permissions or feature flags.

These notes come from standing up a real research-lane workflow (a telemetry "soak review" that queries an MCP and is human-gated) in a project driven over `fn mcp serve`. It took ~6 rebuilds; this is what each failure actually was.

---

## The correct recipe (copy this)

Columns — the **traits** are what matter, not the ids/names:

```
triage       [{trait:"intake"}]                                            # start lives here; BARE intake
todo         [{trait:"hold", config:{release:"capacity"}}, {trait:"reset-on-entry"}]
in-progress  [{trait:"wip"}, {trait:"abort-on-exit"}, {trait:"timing"}]    # work lives here; BARE wip
done         [{trait:"complete"}]
archived     [{trait:"archived"}]
```

**Column-trait vocabulary** (`builtin-traits.ts`). The recipe uses these nine:
- `intake` — entry column; new cards land here and get triaged.
- `hold` — a release-gated queue; config `release` (use `"capacity"` for the dispatch queue).
- `wip` — the active/executing column; config `limitSetting` (e.g. `"maxConcurrent"`) + `countPending`, or bare `{trait:"wip"}`.
- `complete` — terminal success (the `done` column).
- `archived` — hidden from the board.
- `human-review` — card can't leave until approved (also renders the Auto-merge toggle — prefer an `awaitInput` node for gating).
- `abort-on-exit` — hard-cancel work when the card leaves the column.
- `reset-on-entry` — reset step state on entry.
- `timing` — active-time accounting.

The registry defines **five more** (for merge/PR/notification flows a research lane doesn't need): `merge-blocker`, `gate`, `merge`, `stall-detection`, `notify` — **14 total**; list them live with `fn_trait_list`.

Nodes / edges:

- `start` → column `triage`. The first **work** node → column `in-progress`. Edge `start → work` — intake flows to wip **directly**; no hold-column hop, no routing node.
- Work node: `kind:"prompt"`, `config.toolMode:"coding"`. `coding` is what gets the task a worktree **and** access to MCP tools + file writes. `readonly` blocks MCP tools (e.g. BetterStack) and all writes, but needs no worktree.
- Human gate: a `prompt` node with `config.awaitInput:true`. **Do not** use the `human-review` column trait for gating (see traps).
- Output: instruct the node to put its full result **inline in its final response** — it renders in the task **Activity** tab, which is mobile-accessible.

Minimal working shape:

```
start(triage) --success--> work(in-progress, prompt, toolMode:coding)
work --success--> gate(in-progress, prompt, awaitInput:true)
work --failure--> end(done)
gate --success--> end(done)
```

---

## What I tried, what failed, and why

| Attempt | Symptom | Root cause |
|---|---|---|
| Created workflows/tasks; got the wrong id prefix | Landed in the wrong **project** | Operator MCP was `--project`-bound elsewhere. **Check `fn_project_current`; switch with `fn_project_use`.** |
| Tried to enable `workflowColumns` / `workflowGraphExecutor` | Not in the dashboard's experimental toggles; patching them was a no-op | They **graduated to default-on** (`packages/core/src/settings-schema.ts:319`; `packages/engine/src/executor.ts:4789, 5082, 5157`). Don't chase them. |
| Columns `intake`/`hold`/`human-review`, no real spine; `{trait:"wip", config:{limit:2}}` | Task triaged, then sat in the queue column forever, never dispatched | (a) No proper `todo(hold:capacity) → in-progress(wip)` spine; (b) wrong wip config — use **bare `{trait:"wip"}`** (or `{limitSetting:"maxConcurrent", countPending:true}`), **not `{limit:N}`** (an unrecognized limit resolves to no capacity). |
| Cloned **`builtin:coding-ideas`** | Card parked in the `ideas` column and never auto-advanced, even after setting `autoTriage:true` | `coding-ideas` is a **manual-promotion backlog** — its `ideas` intake ships `autoTriage:false` by design. Wrong template entirely. |
| Put `start` in the `todo`/hold column; added a `prep` routing node in `todo` | Still stuck | `start` must be in an **intake** column; the routing node was unnecessary (intake → wip is a direct edge). |
| MCP (BetterStack) calls failed: **"Action requires approval (none)"** | Looked like a tool-permission / allowlist problem | The task never reached a real **executor** session — only **heartbeat** ticks touched it, and heartbeats lack tool approval. **Fix dispatch and tool access follows** — in a real executor session the MCP tool worked with no allowlist change. |
| Put multiple stages (A → B → C) as **nodes in one card** | Approving the first gate just **re-ran stage A** | The task's triaged **`PROMPT.md` dominates the per-node prompts**. One card = one spec. |
| Node persisted output via `fn_task_attach` | File 404s on mobile ("Task … not found") | Attachments aren't mobile-viewable, and there is **no `task_document_write` tool** in the executor toolset. |
| A second task queued behind a gate-parked task | Wouldn't dispatch | A task **parked at an `awaitInput` gate still holds the wip slot**. Approve/archive it to free the lane. |

---

## What I learned (the mental model)

1. **"Won't run" is almost always the dispatch spine — not flags, not permissions.** The engine moves a card by column *traits*: `intake → hold(release:"capacity") → wip → complete`. Get those exact traits right and it flows.
2. **`builtin:coding` is the reference for auto-execution; `builtin:coding-ideas` is a manual backlog.** Fetch `fn_workflow_get builtin:coding` and mirror its column traits + `start`/work-node placement.
3. **`toolMode` gates capability:** `coding` = worktree + MCP tools + writes; `readonly` = no worktree, but no MCP tools and no writes. A research task that queries an MCP server needs `coding`.
4. **Human gate = `awaitInput` prompt node, not the `human-review` column trait.** The `human-review` trait also renders the per-column "Auto-merge" toggle (the dashboard shows it when a column has `mergeBlocker || humanReview`), cluttering every column — and it isn't needed for a per-node pause.
5. **The Activity feed is the canonical output surface.** There is no doc-write tool, and attachments break on mobile — so tell every node to emit its result inline in its response.
6. **One task = one stage.** For a multi-stage flow, make each stage its own task (its *description* is the spec) and chain by creating the next task after each gate approval. Do not stuff distinct stages into one card's node graph.
7. **Verify against the running source, not memory or docs.** Every wrong turn came from theorizing; each got resolved by reading `builtin:coding`'s IR or the engine source (`hold-release.ts`, `Column.tsx`, `settings-schema.ts`).

---

## The single debugging move that saves the most time

When a card is stuck, **fetch `builtin:coding` and diff your column traits + your `start`/work-node column placement against it.** That one comparison exposes the intake/hold/wip spine bug, the wip-config bug, and the `start`-placement bug simultaneously — the three that account for most "it triages but never dispatches" cases.

---

## Sources

Verified against the live Fusion repo (`~/Code/agents/Fusion`) and the operator MCP.

**Fusion codebase:**
- `packages/core/src/builtin-traits.ts` — the column-trait catalog (defines every trait these notes rely on).
- `packages/core/src/trait-registry.ts`, `packages/core/src/trait-types.ts` — trait registration + types.
- `packages/core/src/builtin-coding-workflow-ir.ts` — the reference AUTO-EXECUTING spine to mirror (`builtin:coding`).
- `packages/core/src/builtin-coding-ideas-workflow-ir.ts` — the MANUAL-BACKLOG anti-pattern (`builtin:coding-ideas`; its `ideas` intake ships `autoTriage:false`).
- `packages/core/src/hold-release.ts` — the `hold` → `wip` capacity-release logic.
- `packages/core/src/settings-schema.ts:319` — `workflowGraphExecutor` / `workflowColumns` graduated to default-on.
- `packages/engine/src/executor.ts:4789, 5082, 5157` — runtime confirmation that the graph engine + workflow columns are the default (kill switches removed).
- `packages/core/src/builtin-browser-verification-group.ts:114` (`toolMode:"coding"`) and `packages/core/src/builtin-code-review-group.ts:116` (`toolMode:"readonly"`) — worked examples of the two tool modes.
- `packages/dashboard/app/components/Column.tsx` — where the `human-review` trait renders the per-column Auto-merge toggle.

**Operator MCP tools (`fn mcp serve`):**
- `fn_workflow_get` (fetch `builtin:coding` to diff against), `fn_workflow_create` / `fn_workflow_update` (author the IR), `fn_workflow_settings` (per-workflow policy knobs).
- `fn_project_current` / `fn_project_use` (confirm / switch the bound project).
- `fn_task_attach` (used — but attachments break on mobile, and there is NO `task_document_write` in the executor toolset).

---

## Changelog

### v2 (2026-07-14)
- Added this Sources section (verified Fusion codebase files + operator-MCP tools) and corrected the graduated-flags `executor.ts` line references to **4789 / 5082 / 5157** (was `4926`). Added the column-trait vocabulary to the recipe. Corrections cross-verified against the live Fusion repo (second agent, re-confirmed here). Note: `builtin-traits.ts` defines **14** traits total — the recipe uses nine — so the catalog is presented as a subset, not "the full nine."

### v1 (2026-07-14)
- Initial writeup, distilled from ~6 rebuilds of a research-lane custom workflow: correct `builtin:coding`-based spine recipe, the failure/root-cause table (wrong project binding, graduated flags, wip-config, `coding-ideas`-vs-`coding`, `start` placement, heartbeat-vs-executor tool approval, one-card multi-stage prompt precedence, attachment/mobile output, gate-slot capacity), the trait-driven dispatch mental model, and the fetch-and-diff-`builtin:coding` debugging move.
