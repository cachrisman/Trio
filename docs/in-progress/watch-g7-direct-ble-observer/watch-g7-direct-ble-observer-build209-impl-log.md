> **Historical note (2026-06-16):** The former patches **09** (`watch-complication-improvements`) and **12** (`direct-ble-observer`) were merged into a single watch patch `09-watch-g7.patch` during the dev-sync / branch-cleanup. References to the separate 09/12 split below are historical. See [`dev-sync-branch-cleanup/00-plan.md`](../dev-sync-branch-cleanup/00-plan.md).

# Build 209 — implementation log

**Status:** SHIPPED — build 209 on TestFlight, live on phone + watch
**Plan:** [build-209 impl plan](watch-g7-direct-ble-observer-build209-impl-plan.md)
**Shipped:** 2026-06-15

## Ship summary

- **Build 209** (version 0.8.1) built + uploaded to TestFlight; GitHub release
  [trio-v0.8.1-209-localCI](https://github.com/cachrisman/Trio/releases/tag/trio-v0.8.1-209-localCI).
- Deployed via `./ci/local-build.sh --include-untracked --no-sync-upstream`.
- **C-209-1 … C-209-12 implemented** (see plan for per-item detail). Section A soak verdicts (A1–A5,
  A6/A7) resolved from the 208 soak and recorded in the plan.

## Patch regen (the path had two real snags — recorded for next time)

- **patch-12 redone via cherry-pick** of the full contiguous chain build-206→HEAD:
  `1135fc67c(207) 694e006b7 c144e9e5c b2417f7bd(208) f4ae97537 f1b6450b7 9d0568371(209) 7776d8cff`
  + `--extra-files "Trio Watch App Extension/WatchTelemetryRing.swift"` + `--allow-behind-origin`.
  - **Gotcha:** the committed patch-12 baseline was still **build-206** (the 208 milestone was never
    committed), so cherry-picking only the 209 commits conflicted — the full 207+208+209 chain is
    required. Derive the baseline from the committed patch's provenance trailer, not the patch-id
    suggestion (it reads working-tree provenance and undercounts).
  - The dangling crashlytics revert `faedb574b` is **excluded** (it reverts a commit not in the
    chain → conflicts on `AppDiagnostics`; zero patch-12 content). `7776d8cff` nets out the
    ComplicationLogBuffer hunk so there's no cross-patch drift.
  - Use `--cherry-pick`, NOT `--from-feature-branch` (the latter resets the provenance trailer).
  - Verified: 18 files, all 207/208/209 content present, ComplicationLogBuffer file unmodified,
    `battery_src` absent, no crashlytics code (provenance lineage only), `patch-test.sh` PASS.

- **Fork compiler-crash fix (build-time, not in the original plan):** C-209-12's `Data.toDefaultEndian`
  bounded-read rewrite used `withUnsafeMutableBytes(of: &value)` on a generic `T`, which **crashes
  the Swift 6 compiler** (Xcode 26.5: "failed to produce diagnostic for expression"). It was
  committed to the fork without a build (AGENTS.md rule 10), so it surfaced only at archive time —
  the first 209 build **failed** here. Rewrote pointer-free (byte-by-byte little-endian via
  `self[self.startIndex + i]` + `T(truncatingIfNeeded:)`), preserving the bounded-read safety fix;
  typecheck-verified in Swift 6. Fork commit `cd879d5` on `cachrisman/G7SensorKit` main; patch-02
  repinned. **Also caught:** `local-build.sh` reported `TOTAL (Success)` / exit 0 on that failed
  archive — logged in `docs/backlog/build-script-archive-exit-code/`.

## Section A — 209 confirmation pass (2026-06-15, ~10 min post-install)

| Item | Verdict | Evidence |
|---|---|---|
| **C-209-1** analytical denominator | ✅ **CLOSED** | On-device `67 / 248` at 20:54 CEST; `248 = 250 elapsed slots − 2 ineligible` — correct. Display-time computation, soak-independent. |
| **A2** CB restore on watchOS | ✅ **CONFIRMED on 209** | `will_restore_state` fired at launch — the path we *kept* (vs the planned delete). One-shot event, valid regardless of window. |
| C-209-3 logging-tax demotion | ⏳ mechanism live (`log_pipeline_summary` present); the ~60–70% volume drop needs a clean soak day to quantify | |
| A4 watchdogs quiet | ⏳ 0 fires so far, but 10 min proves nothing — needs soak | |
| Capture health | 🟢 heartbeat: g7_ble EGVs capturing on cadence, 0 errors/timeouts/stalls, clean bootstrap | |
| A1 / A3 / A5 / **A6 dormancy** | ⏳ **soak-gated** — rate comparisons + deep-background dormancy need a day+; A6 is the headline question | |

## Follow-ups

- **Soak loop** running to track the capture ratio + A6 dormancy + watchdog/error counts on 209.
- **Section A close-out** (A1/A3/A5/A6 + logging-volume quantification) after the soak read.
- **Build-209 milestone committed** (patches 02 + 12) → makes the committed patch-12 baseline =
  build-209, which keeps future regens clean and unblocks the dev-sync + branch-cleanup track.
- Build-210 candidates collected in [build-210 budding list](watch-g7-direct-ble-observer-build210-budding-list.md).
