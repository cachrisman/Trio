# Dev sync + feature-branch cleanup — plan

**Version:** 1.1 (Q2 resolved; branch keep/delete set enumerated; patch-14 delete contradiction fixed)
**Status:** Planning — gated behind the 209 ship
**Created:** 2026-06-13 17:25 CEST
**Last updated:** 2026-06-14 09:45 CEST

Goal: sync local `dev` with `upstream/dev`, excise the abandoned crashlytics experiment from the
drift path, and clean the feature branches so the stack is maintainable. Guiding principle:
feature branch == patch, each clearly scoped.

## Locked decisions

1. **Sequencing (Q1):** ship **build 209 on the current stack first**, *then* run this cleanup.
   Avoids regenerating the watch patch twice and keeps the soak-gated 209 build uncoupled from a
   big refactor.
2. **09/12 → Flavor B (merge).** Combine patches **09 (watch-complication)** + **12 (watch direct
   BLE)** into one `feature/watch-g7` branch → one merged watch patch. Rationale: 11 files are
   co-owned by both (incl. god-objects `WatchState`, `TrioComplicationDataStore`, `WatchLogger`,
   `ExtensionDelegate`), and single commits straddle both concerns (C-209-5 was the live proof), so
   "keep split + non-overlapping" is a fiction without splitting god-objects. Patches are private /
   never distributed, so the only cost of merging (independent distributability) is a non-issue.
   - Patch **10** (session-crash-guard) is phone-only (`TrioApp`, `AppleWatchManager`) — touches
     none of the 11 shared files, so merging across its stack position is clean.
   - Patch **13** (phone BLE telemetry) is entirely phone-side — **stays its own patch**, do NOT
     fold into the watch merge.
3. **Crashlytics removal → revert, not rebase.** Use `git revert` (SHA-stable) rather than
   history-rewrite. **DONE for the live synthesis branch:** `faedb574b` reverts `1b7dbf805`.
   Branches verified (2026-06-14) to contain crashlytics `1b7dbf805`: `baseline-dev-patches-01-10`,
   `claude/friendly-pare-23c8ee`, `claude/strange-maxwell-7be004`, `list`,
   `feature/live-activity-temp-target-badge`, and `feature/watch-g7-direct-ble-observer-synthesis`
   (the last via introduce+revert — net-zero, fine).
   - The first four get **deleted** in Phase 4, so no revert needed there.
   - ⚠️ **Correction (2026-06-14):** `feature/live-activity-temp-target-badge` is the **source branch
     for patch 14** (tip `74abf089b` / `915b37666` map to `14-live-activity-temp-target.patch`).
     **Do NOT delete it** — that breaks the `--from-feature-branch` regen path and violates
     branch==patch. Instead `git revert` the crashlytics commit on it, same as synthesis. (Harmless
     in ancestry as long as patch-14 scope excludes the crashlytics files.)
   - ⚠️ The crashlytics **experiment branch itself**, `feature/crashlytics-test-crash-button`, was
     missing from the original delete list — **add it to Phase 4 deletes.**
   - Delete patch `04-crashlytics-test-crash-button.patch.skipped`.
4. **Re-signing:** 114 feature commits (build-205→208) are unsigned. Fold re-signing into the
   Phase-1 dev-sync **rebase** via `--exec 'git commit --amend --no-edit -S'` — one pass, no extra
   SHA churn. Do NOT re-sign as a standalone rewrite (would re-SHA the C-209 commits).
5. **Docs:** living docs (review, upstream-PR plan, 209 plan, complication-freshness README) →
   inline update; frozen historical docs → one-line header banner noting the old 09/12 split.
6. **MUST restore:** the C-209-5 ComplicationLogBuffer hunk (dropped to ship 209) →
   re-apply `watch-g7-direct-ble-observer/C-209-5-CLB-hunk-to-restore.patch` into the merged watch
   patch. Charlie's condition for approving the drop.

## Corrected ordering (from the qwen3.6 critique, 2026-06-13)

- **Rebase feature branches onto the synced dev BEFORE regenerating patches** — patch context was
  captured against old `dev`; regenerating against a mutated base conflicts. (This was a real
  ordering bug in the first draft.)
- **One-patch dry-run first** — on a throwaway branch, sync the base and regen ONE patch through
  `patch-test.sh` before committing to the full sequence.
- **pbxproj / submodule conflicts = explicit Charlie-in-Xcode step**, not "resolve them" in passing.

## Q2 — RESOLVED (2026-06-14): `origin/dev` is diverged, NOT auto-synced

Fetched `upstream` + `origin` and checked the relationship directly:

| Comparison | Result |
|---|---|
| Is `origin/dev` a FF descendant of `upstream/dev`? | **No** |
| `origin/dev` vs `upstream/dev` | ahead **160**, behind **19** |
| local `dev` vs `upstream/dev` | ahead **162**, behind **30** |

**Finding:** `origin/dev` is **not** an auto-synced mirror of `upstream/dev`. It is the cachrisman
fork's own dev carrying the full ~160-commit patch stack on top of an *older* upstream base (19
behind). Do **not** treat `origin/dev` as the sync source. Sync target stays `upstream/dev`
(nightscout) — confirmed correct.

**Good news on scope:** the conflict surface is only the **~30 upstream commits** local `dev` is
behind, not hundreds.

**Rebase-vs-merge (the decision Q2 gated):** local `dev` is 162 ahead of upstream, of which **37
are merge commits** (the recurring "Merge upstream/dev into dev"). The history is **merge-based**,
so:
- **Dev sync → MERGE `upstream/dev` into `dev`, not rebase.** A 162-commit rebase would rewrite the
  entire fork history and flatten 37 merges for zero benefit; the sync only needs to absorb ~30
  upstream commits.
- The "rebase" language applies only to **feature branches onto the synced dev** (that's where the
  `--exec … -S` re-sign pass belongs). Phase 1's "rebase local dev" is corrected to **merge** below.

## Phase outline (execute after 209 ships)

- **Phase 0 — safety net:** tag `dev` + every feature branch; work on a throwaway integration
  branch; gate each phase on `patch-test.sh`.
- **Phase 1 — sync `dev` ← `upstream/dev`:** (Q2 resolved — origin/dev is diverged, not a mirror).
  **MERGE** `upstream/dev` into local `dev` (NOT a rebase — history is merge-based, 37 merges in the
  162-ahead; only ~30 upstream commits to absorb). Then **rebase feature branches** onto the synced
  dev (with `--exec … -S` to re-sign); resolve submodule/pbxproj (Charlie in Xcode); one-patch
  dry-run; re-validate full stack.
- **Phase 2 — crashlytics cleanup:** revert already done (`faedb574b`); delete patch 04 (+ patch 11
  `.skipped`, superseded by 12); regen affected patches to confirm drift cleared.
- **Phase 3 — merge 09+12 (Flavor B):** unify the watch branch; restore the CLB hunk (#6);
  regenerate one merged watch patch at slot 09; drop patch 12; keep 13 separate.
- **Phase 4 — branch==patch hygiene:** 1:1 mapping, record `Trio-Patch-Source-Branch` trailers
  (most patches lack them), delete stale branches. **Explicit keep/delete set below (2026-06-14).**

  **KEEP — patch source branches (1:1 with a patch):**

  | Branch | Patch |
  |---|---|
  | `feature/ns-richer-settings` | 01 |
  | `feature/g7sensorkit-timestamp-seconds` | 02 |
  | `feature/treatments-fixed-bottom-action` | 03 |
  | `feature/watch-error-reporting` | 05 |
  | `feature/cloud-logging` | 06 — ⚠️ ahead **371**/behind 17 vs origin; needs its own reconciliation |
  | `fix/chart-height-bug` | 07 *(verify mapping)* |
  | `feature/watch-complication-improvements` | 09 → merges into… |
  | `feature/watch-g7-direct-ble-observer-synthesis` | 12 → …merged 09+12 (Flavor B) |
  | `feature/watch-session-crash-guard` | 10 |
  | `feature/phone-ble-observer-telemetry` | 13 |
  | `feature/live-activity-temp-target-badge` | 14 — **revert crashlytics, do NOT delete** (see decision 3) |

  **DELETE — stale / experiment / junk / merged-upstream:**
  - `baseline-dev-patches-01-10`
  - `claude/friendly-pare-23c8ee`, `claude/jolly-mclean-b2b1af`, `claude/strange-maxwell-7be004`
  - `feature/crashlytics-test-crash-button` (the experiment itself)
  - `feature/watch-complication-improvements-backup`
  - `feature/watch-direct-ble-cgm` (Build 184, superseded by synthesis/patch 12)
  - `fix/build-errors-chart-height-app-termination` (superseded by `fix/chart-height-bug`)
  - `list`, `ls` (junk doc branches)
  - `trial/sync-option-a-built-fw`
  - `docs` — **delete** (docs now live in the `dev` branch; confirmed 2026-06-14)
  - `feature/fix-ios-app-notification-duplicates-and-add-snooze-options` — **delete**; submitted as a
    PR to `upstream/dev` and **accepted/merged upstream**, so the local branch is redundant
    (confirmed 2026-06-14)

  **Patch 08 (`08-patch-metadata`) — no source branch; RECONSTRUCT, don't resurrect.** Provenance:
  merged via **[PR #15](https://github.com/cachrisman/Trio/pull/15)** (codex task), reviewed clean
  2026-06-14. Investigation findings:
  - The PR's head branch `codex/add-patches-section-to-submodulesview.swift` (recovered via
    `refs/pull/15/head`, tip `15474ff`) is a **dead end** — its commits only *add/edit the `.patch`
    file* (`patches: add/update 08-patch-metadata`), contain **zero applied source code**, and are
    already an ancestor of `dev`. Resurrecting + renaming it yields an **empty diff vs dev**.
  - The mailbox `From 01a99c75…` commit (the real applied-code commit) was transient and **never
    pushed** — not in history anywhere.
  - **Do NOT stack patches 1–8 onto the branch.** Verified `generate-patch.sh` diffs
    `SOURCE..TARGET` with `TARGET` defaulting to **bare `dev`** (`generate-patch.sh:738`, `:526`) —
    it does **not** build a 1..(n-1) baseline. The sequential 01→N apply is `patch-test.sh`'s
    *validation* job, run automatically at build time, not something the source branch bakes in.
    Stacking 1–8 would make `generate-patch` emit a patch containing all eight diffs.
  - Patch 08 is **independent**: its three files (`BuildDetails.swift`, `SubmodulesView.swift`,
    `scripts/capture-build-details.sh`) are touched by no other patch (01–07), and the mailbox patch
    `git am`s cleanly onto bare `dev` (dry-run 2026-06-14, no conflicts).

  **Action (Phase 4, in the `../Trio` worktree):**
  ```
  git checkout -b feature/patch-metadata dev
  git am -3 patches/08-patch-metadata.patch          # one "feat: patch-metadata" commit
  git commit --amend --no-edit -S                     # sign, to match decision 4
  ```
  Then it satisfies branch==patch — `generate-patch.sh --from-feature-branch feature/patch-metadata`
  reproduces patch 08 exactly.
- **Phase 5 — docs:** living inline; frozen banners.

## Changelog
### v1.1 (2026-06-14 09:45 CEST)
- **Q2 resolved** by fetch + FF check: `origin/dev` is **diverged, not auto-synced** (ahead 160 /
  behind 19 vs `upstream/dev`). Sync target `upstream/dev` confirmed; conflict scope is only ~30
  commits. **Dev sync → MERGE not rebase** (37 merge commits in the 162-ahead; merge-based history).
  Phase 1 updated accordingly.
- **Patch-14 delete contradiction fixed:** `feature/live-activity-temp-target-badge` is patch 14's
  source branch → revert crashlytics on it, do NOT delete (decision 3 + Phase 4 corrected).
- **Added** `feature/crashlytics-test-crash-button` (the experiment branch) to the Phase 4 deletes —
  was missing.
- **Enumerated** the full Phase 4 keep/delete branch set (verified against live refs).
- **`docs` branch → delete** (docs live in `dev` now); **snooze-options branch → delete** (PR merged
  upstream).
- **Patch 08 source resolved:** came via merged PR #15. The codex head branch is a dead end (patch
  file only, no applied code); **reconstruct** `feature/patch-metadata` by `git am`-ing the mailbox
  patch onto bare `dev` in Phase 4 (verified independent + clean apply). Do NOT stack patches 1–8 —
  `generate-patch.sh` diffs against `dev`, not a 1..(n-1) baseline (that's `patch-test.sh`'s job).
### v1.0 (2026-06-13 17:25 CEST)
- Initial capture. Decisions 1–6 locked; corrected ordering from the qwen3.6 critique; Q2 left to
  verify at Phase 1. Crashlytics revert (`faedb574b`) and CLB drop (`7776d8cff`) already committed
  on synthesis as part of the 209-ship prep.
