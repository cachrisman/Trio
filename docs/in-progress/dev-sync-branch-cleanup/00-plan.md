# Dev sync + feature-branch cleanup — plan

**Version:** 1.2 (executed 2026-06-16 — see changelog for outcomes + deviations)
**Status:** Complete — Phases 0–5 done, build-validated, committed (`c21092055`) + force-pushed to `origin/dev` 2026-06-16. TestFlight deploy not yet run (build-only validation; deferred per Charlie).
**Created:** 2026-06-13 17:25 CEST
**Last updated:** 2026-06-16 00:15 CEST

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
### v1.2 (2026-06-16 00:15 CEST) — EXECUTED
- **Phase 0:** 25 annotated safety tags `safety/pre-dev-sync-20260615/<branch>` (dev + all 24 branches). Baseline patch-test green.
- **Phase 1:** Clean MERGE `upstream/dev` → `dev` (`3191d6296`, signed, 0 conflicts; 0 behind upstream). Per-patch outcome vs synced dev: `01/03/06/07/08` apply clean (no regen); `05` applies clean via `git am --3way` (upstream watch overlap absorbed); `02` regenerated preserving **build-209 G7 pin `cd879d59a`** (decision Q3=A; branch reconstructed). **Patch 14 dropped** in favor of upstream's superior Live Activity temp-target work — replaced by a slim `14-temp-target-default-tab` (Adjustments tab reorder only; push-on-cancel dropped per Charlie). Signing now works in-sandbox (1Password socket allowlisted). Feature-branch work moved to a fresh worktree `.trio-worktrees/fb-rebase-20260615` (avoids `../Trio` untracked-CLAUDE.md collision + a corrupted OmnipodKit submodule that was repaired).
- **Phase 2:** Deleted `04-…skipped` + `11-…skipped`. Crashlytics **experiment** (`1b7dbf805`) confirmed excised (reverted on synthesis; experiment branch deleted). Legitimate `FirebaseCrashlytics` *logging* usage (05/06/09/10/13) intentionally retained. `feature/live-activity-temp-target-badge` crashlytics-revert moot (branch deleted, patch 14 dropped).
- **Phase 3 (Flavor B):** Merged 09+12 → **`09-watch-g7.patch`** (27 files) on synced dev; restored the C-209-5 ComplicationLogBuffer hunk (#6). Upstream #1162 back-sync reconciliation: **Option A** — kept patch-09's richer 209-shipped receive path (superset of upstream's unified `handleIncomingWatchStatePayload`); upstream's load-bearing send-side `state.date = Date()` stamping preserved in `AppleWatchManager`. (Upstream's unified-handler refactor ≈ a ~5% slice of the [watch-messaging-centralization](../../backlog/watch-messaging-centralization/) plan point #3 — noted there as a precedent; full centralization remains deliberate future work.) Dropped patch 12. **Patch 13 reconciled** (Q=drop Omni-removal): its stale `DeviceDataManager` Omni-removal would have deleted the OmnipodKit/`OmniPumpManager` backend upstream still ships — dropped; kept only its telemetry additions.
- **Phase 4:** 1:1 branch↔patch mapping established (11↔11). `feature/patch-metadata` reconstructed via `git am` of patch 08 (signed). Deleted all Phase-4-list stale branches + (Q2a) superseded `feature/watch-g7-direct-ble-observer-synthesis` and `feature/watch-complication-improvements` + replaced `feature/live-activity-temp-target-badge` + scratch/integration branches. **Deviation:** the 5 reconstructed source branches sit cleanly on synced dev (0 behind); the 6 untouched old branches (`01/03/05/06/07/10`) retain heavy drift (123–794 behind) — patches apply + compile, but branches are stale regeneration sources. Full reconciliation deferred (Q2b: leave clean branches' signing alone). `feature/cloud-logging` still needs its own origin reconciliation (ahead/behind vs origin) — separate item.
- **Build:** `ci/local-build.sh --base-branch dev --build-only --include-untracked --no-sync-upstream` → **signed `Trio.ipa` produced, TOTAL Success 4m47s** (verified real export, not just exit 0). Reorganized stack applies clean AND compiles.
- **Milestone (done 2026-06-16):** patches + docs committed to `dev` as `c21092055` (signed) and force-pushed to `origin/dev` (`cf1219af6`→`c21092055`, `--force-with-lease`) per Charlie's "commit now, no deploy". origin/dev's 4 prior commits were content-redundant (attribution rule + GlucoseHueColor sync-config already on dev; 2 merge commits) — nothing of value lost. All 6 drifted source branches reconciled onto synced dev; `Trio-Patch-Source-Branch` trailers added to all 11 patches; frozen watch-g7 docs bannered.
- **Cloud-logging branch fixed (2026-06-16):** `feature/cloud-logging` rebuilt clean on current dev (dev+01–06, signed, crashlytics-free) and force-pushed to `origin/feature/cloud-logging` (`c4292d9f1`→`a66a1cd28`, `--force-with-lease`, explicitly authorized). origin's 17 stale build-143/144-era commits (+ crashlytics experiment + old 01/02) were superseded by the 209 patches; old tip preserved at tag `safety/origin-cloud-logging-pre-fix-20260616`.
- **Still open (deferred, all optional, none blocking):** TestFlight deploy + BetterStack verification (only build-only was run — `./ci/local-build.sh --base-branch dev` for full); living-doc inline updates (review / upstream-PR plan / 209 plan / complication-freshness README — banners done, not rewrites); the other 10 reconstructed feature branches not yet pushed to origin (only `dev` + `feature/cloud-logging` are); scratch worktree `.trio-worktrees/fb-rebase-20260615` + `../Trio` detached at `7776d8cff`; `safety/*` recovery tags (26) retained until fully confirmed.

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
