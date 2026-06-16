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
| A4 watchdogs quiet | ✅ **CONFIRMED** | **0** `egv_watchdog_fired` / `ext_session_start_timeout` across the full ~6.4h worn overnight soak — it only fires on real stalls (14× during the 06-13 outage). |
| **A6 dormancy** | ✅ **SETTLED — pass (2026-06-16 overnight soak)** | No recurrence in the worn deep-background overnight stretch. See "Overnight soak result" below. |
| A1 / A3 / A5 | 🟢 clean overnight — no `command_timeout`/`configure_block_skipped` spikes, no reconnect storms, no `did_fail_to_connect` — consistent with the resolved 208 verdicts |
| Capture health | 🟢 sustained over the worn overnight stretch (~68% of slots; misses are position, not software — see below) |

## Overnight soak result — A6 SETTLED (2026-06-16)

First worn + deep-background overnight stretch — the exact condition that produced 208's full-day
06-13 dormancy. **Build 209 handled it cleanly: no dormancy recurrence.**

Worn window 21:46→04:10 UTC (~6.4h, ~77 possible 5-min slots):

| Metric | 209 (this night) | 06-13 (208 — the failure) |
|---|---|---|
| g7_ble EGVs captured | **52 (~68% of slots)** | **0 all day** |
| `connect_called` | 136 (~21/hr, healthy throughout) | collapsed to ≤2/hr (dormant) |
| `egv_watchdog_fired` | **0** | 14 |
| `did_fail_to_connect` | 0 | high |
| `stale_sensor_binding_suspected` | 2 | ~50 |

The ~32% missed slots were **sleep-position occlusion** (arm/body blocking the 2.4 GHz link to the
body-worn sensor) — every gap recovered, connects stayed healthy, the watchdog never fired. That's
the environmental ceiling of worn-overnight direct BLE, not a software defect, and it costs no data
(the phone/WC path covers those slots). The pattern all night was oscillation between clean 5-min
stretches and 10–30 min position gaps, always recovering — the opposite of 06-13's monotonic collapse.

**Caveats:** (1) one night isn't statistical proof — the 06-13 root cause was the *Dexcom app*
losing its sensor session (Dexcom-side, independent of Trio's code), so a clean night shows 209
handles the normal case well, not that the Dexcom app can never drop again. (2) The real safeguard
against a future 06-13 is the **A7 direct-BLE-stall detection (210)** — detect + notify, since Trio
cannot prevent a Dexcom-side drop.

## Follow-ups

- **Soak loop STOPPED 2026-06-16** — A6 settled; watchdog/error counts stayed at 0 all night.
- **Section A: largely closed** — A6 settled (pass), A4 confirmed; C-209-1 + A2 closed at install.
  Only remaining nicety: rigorous logging-volume quantification (C-209-3) over a clean day, if wanted.
- **Build-209 milestone committed** (patches 02 + 12) → makes the committed patch-12 baseline =
  build-209, which keeps future regens clean and unblocks the dev-sync + branch-cleanup track.
- Build-210 candidates collected in [build-210 budding list](watch-g7-direct-ble-observer-build210-budding-list.md).
