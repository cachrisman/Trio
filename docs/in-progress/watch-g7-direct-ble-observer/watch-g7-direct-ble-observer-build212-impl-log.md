# Watch G7 Direct-BLE — Build 212 Impl Log

**Audience:** coding agent implementing build-212 fixes in the watch direct-G7-BLE path
**Scope:** watch-side *direct* G7 BLE (`module=g7_core` / `module=g7_ble`, `category=WatchTelemetryRing`). NOT the phone→watch relay.
**Telemetry:** BetterStack source `1659391`, table `t491594.trio`. 8-day retention (so data ≥ ~Jun 12 is already aging out; see note in §1).
**Builds in window:** 208 (Jun 12–15), 209 (Jun 15–18), 210 (brief, Jun 17), 211 (Jun 18–20).
**Supersedes / corrects:** the v1.0 "Trio Watch — Direct-BLE EGV Failure Diagnosis & Fix Plan" handoff (the four-fix doc). Validated against live telemetry + source on 2026-06-20; corrections below.

---

## 10. Autonomous continuation (2026-06-21) — dispositions for the remaining items

Worked the remaining build-212 items without supervision. No fork push / patch repin / build (attended gates). Outcome: the two HIGH fork items were already done (§9); of the rest, one is **refuted**, one **verified (no-op)**, and the others are **blocked on the watch-adapter (`feature/watch-g7`) workflow** — which I deliberately did not start autonomously (switching the `Trio` worktree's branch is invasive to in-progress `feature/ns-richer-settings` work, and patch-09 regen is your attended process).

| Item | Disposition | Detail |
|---|---|---|
| **BUG-D** — skip redundant auth | ❌ **Refuted — do not implement** | The G7 auth exchange is **sensor-driven and required every connection**: `G7Sensor.didReceiveAuthenticationResponse` waits for the `authenticated && bonded` challenge before enabling control (EGV) notifications. `auth_payload_ignored` (lines 441/467) is just intermediate protocol traffic (unparseable / not-yet-authenticated responses), ~0.31/connect — **normal, not wasteful**. "Skipping auth on a bonded session" would break connectivity. Recommend dropping BUG-D from the plan. |
| **BUG-A** — `no_runtime` gating holds when worn | ✅ **Verified — no action** | Build-211 `ble_gated reason=no_runtime`: Jun 18 = 2, **Jun 19 = 0**, Jun 20 = 1 (vs 209's 13/day). The full 211 day (Jun 19, 167 EGVs) had **zero** worn-time gating. The build-208 catastrophic gating is fully mitigated by C-209/210/211. |
| **BUG-F** — stamp `scene_phase`/`ext_session_active` on all events | ✅ **DONE (pt1 + pt2)** | **Pt1 (`29f2d3e50`):** centralized stamping in the adapter `log()` with a token-boundary guard → every `g7_ble` event carries both fields. **Pt2 (`ff898835f`):** fork `g7_core` events plumbed via `WatchTelemetryRing` — `scene_phase`/`ext_session_active` added to ring context (`setContext` + appended in `enqueueCoreTelemetry`); the adapter refreshes the context via **`didSet` observers** on `lastKnownScenePhase`/`lastKnownExtSessionActive` (cleaner than hooking every change site — auto-syncs on any change). 2 cursor rounds each, no Blocker/High. Telemetry-only. Now every g7 event (both modules) carries scene/ext → enables exact per-scene yield (e.g. `did_connect` by `scene_phase`). |
| **BUG-H** — daily counters survive upgrade | 🔍 **Root cause UNCONFIRMED — do not implement yet** | Static analysis contradicts the assumed cause: `loadDailyCounters` (`G7WatchSensorAdapter.swift:618`) only resets when `Keys.calendarDay` is missing/changed, but `WatchLogger`'s `[UPGRADE]` log (`WatchLogger.swift:691-700`) reads `lastKnownBuildKey` from `UserDefaults.standard` **across** the upgrade → standard defaults **survive** in-place upgrades → `calendarDay` survives → no reset on a same-day upgrade. The reported reset is therefore more likely a **clean reinstall** or **midnight rollover coinciding with the deploy**. A speculative app-group migration may not fix it (and can't be build-tested). **Confirm the empirical repro** (backlog success criteria) before any fix; if confirmed, the daily set is `connects`/`egvs`/`calendarDay`/`gatedSlotEpochs`/`ineligibleSeconds`/`ineligibleSinceEpoch` (keys at `:166-168`+). |
| **BUG-E** — protect notify-enable across 3–10s bg kill | 🔬 **Investigated → reframed (see §11)** | The premise was wrong: the handshake is **fast** (p90 1.4s), so there's nothing to "protect" there. The 3–10s kill is a **session-uptime** problem — `ext_session_active` predicts success (98% vs 58%), sessions last ~60min but are active only ~17–22% of the time, and a session can only start on `.active` app-opens (`.inactive` is OS-blocked: `blocked_app_inactive`). The **Return-to-Clock A/B** showed Default gives ~2× the session coverage of 1-hour. One live code lever (near-expiry `.active` re-anchor) is **sketched** in §11; gain is modest + app-open-bounded. No code written. |
| **BUG-G** — re-measure coverage after the throttle | ⏳ **Post-deploy** | Can only run after build 212 is built + soaked; the §2/§4 tables are the instrument. |
| **VERIFY-1** — mmol/L face display | 🚫 **Not closable by us** | mg/dL n=1 device; no display-unit field in BetterStack (unchanged). |
| **VERIFY-2** — arbitration (bare WC vs complete BLE) | ⏳ **Needs complication telemetry** | Not in the `module=g7%` BLE stream; lives in the `TrioComplicationDataStore` path (different category). Not verified this run — a separate query against complication-arbitration events is required. |

**Bottom line:** the build-212 *fork* work that's safely doable without you is **complete** (BUG-B, BUG-C done; BUG-D refuted; BUG-A verified). Everything remaining is watch-adapter (needs the `feature/watch-g7` + patch-09 workflow), post-deploy, or not-closable — all requiring your involvement.

## 11. BUG-E investigation — background coverage & extended-runtime-session uptime

**Question:** the 3–10s background "pre-EGV" disconnects (the largest single coverage loss). Original hypotheses: hold a `WKExtendedRuntimeSession` across the reading window, and/or trim the handshake to fit a short background wake.

**Both original hypotheses are refuted by the telemetry:**
1. **The handshake is fast — not the bottleneck.** `time_to_first_egv_ms` (successful reads): p50 ≈ **0.7s**, p90 ≈ **1.4s** even in the background; only the p99 tail hits ~5s. The pre-EGV path is already cache-skipped (`servicesToDiscover`/`characteristicsToDiscover` guard on uncached-only; `applyConfiguration` skips `isNotifying`), and the post-EGV trips (backfill-subscribe + extended-version) are background-skipped by C-209-11. The remaining cost is the mandatory, sensor-paced auth handshake — nothing to trim.
2. **Windowed/reactive session-holding is impossible.** `WKExtendedRuntimeSession` can only be **started while the app is frontmost** — build 171 logs a runtime-gate state literally named **`blocked_app_inactive`**; D8 found ~95% of background start-requests denied. So you cannot start a session "around each reading" in the background.

**What actually predicts success — `ext_session_active`:**
| state | success |
|---|---|
| session active (ext=true) | **98%** (620/633) |
| background, no session (ext=false) | **58%** (1480/2543) |

- Session **lifetime ≈ 60 min** (p50 3601s — the watchOS cap), but active only **~17–22%** of the time: ~9 `.active` app-opens/day collapse into ~4 session-hours.
- Background failures cluster at **`minutes_since_last_egv = 5`** (444 — the reading-*due* moment), dropping at a median 6s. We connect at the right time; the unprotected connection just loses the race ~42% of the time. (Full distribution is a consecutive-miss survival curve: 444 single-miss → 214 double → 65 triple → … + a long sensor-gone tail.)

**A session can only start on `.active` (interaction), never on a passive glance.** Passive Return-to-Clock glances are `.inactive` → `blocked_app_inactive`. `renewSessionIfNeeded()` has exactly one caller (`applyForegroundActiveEntry`). The `.inactive`-as-session-start lever is a **confirmed dead end** (investigated in the `watch-direct-ble-cgm` lineage; `.inactive→stop()` was tried early and removed).

### The Return-to-Clock A/B (`.claude/rtc-ab-test-log.md`) — counterintuitive
| arm | dates | setting | session-active % |
|---|---|---|---:|
| A | 06-14, 06-15 | Default (2 min) | **31–36%** |
| B | 06-16, 06-17 (+ 18–20 kept) | Custom (1 hour) | **13–21%** |

**Default gave ~2× the session coverage of the 1-hour setting.** Mechanism: with **1-hour**, a wrist-raise shows Trio passively (`.inactive`, no session) → you *open* the app less → fewer `.active` events → fewer sessions. With **Default**, you see the clock → checking glucose *requires* opening Trio (`.active`) → more sessions. (Caveat: 2 days/arm, `success %` confounded by builds 208→210; trust the session-active % signal — the follow-on 1-hour days corroborate it.)

### Conclusion
- The lever is **session uptime**, bounded by **`.active` app-opens** — not the handshake (fast), not `.inactive` harvesting (OS-blocked), not background starts (OS-blocked).
- The **RTC setting is a now-measured user trade-off**: Default → ~2× session coverage (better capture) but clock-on-glance; 1-hour → Trio-at-a-glance but ~half the coverage. Product/personal call.
- **BUG-F** (shipped) is the instrument for precise future measurement; a clean re-run on a fixed build is needed to size the prize exactly.

### Proposed change (SKETCH — NOT implemented): near-expiry `.active` re-anchor
Today `renewSessionIfNeeded()` (`G7WatchSensorAdapter.swift:293`) does `guard extendedSession?.state != .running else { return }` — it **skips every running session**, so an app-open during a session's back-half is wasted and the session lapses minutes later (often in the background, where it can't restart). The early `watch-direct-ble-cgm` design re-anchored on *every* `.active` re-entry (churny); the **middle ground — re-anchor only near expiry — was never tried.** Hooks already exist: `extendedRuntimeSessionDidStart` (`:1336`) for a `sessionStartedAt` stamp, and the **dormant** intentional-invalidation path (`invalidatingSessionIDs` + handler `:1371`, kept "for the handler's stated future-caller hygiene" — this is that caller).

```swift
private static let sessionReanchorAge: TimeInterval = 45 * 60   // tune on soak data

// replace `guard extendedSession?.state != .running else { return }`:
if let current = extendedSession, current.state == .running {
    // A fresh session already covers the next ~hour; restarting it gains nothing and re-courts
    // throttling (D8). Only re-anchor when it's near expiry.
    guard let startedAt = sessionStartedAt,
          Date().timeIntervalSince(startedAt) >= Self.sessionReanchorAge else { return }
    // Near expiry + foreground-active: intentionally invalidate (no BLE teardown — via
    // invalidatingSessionIDs) and fall through to start a fresh ~1h session.
    invalidatingSessionIDs.insert(ObjectIdentifier(current))
    current.invalidate()
    extendedSession = nil
    sessionStartedAt = nil
    log("ext_session_reanchor", "age_s=\(Int(Date().timeIntervalSince(startedAt)))")
}
// ... existing sessionPendingDidStart guard, 30s debounce, start new session ...
// + set `sessionStartedAt = Date()` in extendedRuntimeSessionDidStart and the start-timeout adopt path.
```

**Risk/scope:** behavioral change to the fragile session lifecycle (same class as C-210-6/7) → full review→soak loop, not build-testable here. Brief unprotected gap during invalidate→start→didStart (you're foreground — low risk). Interacts with the pending-start wedge (fable5 §3.1); the existing 15s start-timeout watchdog covers a missing didStart. **Gain is modest and app-open-bounded — and per the A/B the RTC setting matters more.**

**Status:** ✅ **IMPLEMENTED as C-212-5** (commit `dfc6c9f2d` on `feature/watch-g7`) — but **not** as the naive inline sketch above. `cursor-task` review (4 rounds) caught that inline `invalidate()` + `start()` re-courts the overlapping-request rejection (D1), so the shipped version is **sequential**: invalidate the old session → start the replacement from the `didInvalidate` callback once it's fully gone; a `pendingReanchor` flag gates the whole function against re-entry during that window; a **15s watchdog** clears the flag + retries if `didInvalidate` never arrives; a `nil` start-stamp is lazily seeded. Accepted residuals are telemetry-only (active-flag flicker during the swap; callback-time age; magic 45-min threshold). **Not built — needs soak** (with a fixed RTC setting) to confirm the gain and tune `sessionReanchorAge`.

---

## Changelog

**v1.12 — 2026-06-22 — BUILD 213 SHIPPED (C-212-5 v2)**
- **Build 213 deployed to TestFlight** as `0.8.3 (213)` (13m7s): compiled clean, archived, uploaded, GitHub releases recorded (`trio-v0.8.3-213-localCI`). Implemented overnight, autonomously, per the user's request.
- **C-212-5 v2 inline re-anchor** (commit `d6b513053` on `feature/watch-g7`) **replaces the broken v1**. v1's sequential swap (invalidate → wait for `didInvalidate` → start) never produced a fresh session in the build-212 soak; v2 does the swap **inline** with an **A/B/C delay experiment (0/100/300 ms)**, 200 ms retry-on-rejection, arm-A circuit-breaker (5 consecutive), object-identity attribution, persisted true-age clock, swap-in-flight gate + 20 s backstop, same-visit recovery. Design: `c212-5-v2-inline-reanchor-design.md` (4 design rounds + 3 external reviews); implementation: 4 `cursor-task` rounds to no Blocker/High/Medium.
- **Integration:** patch-09 regen via `--cherry-pick` of all 5 C-212 commits (incl. the v2 commit); patch-02 still pinned to fork `3da042a`. Upstream synced 0.8.3.2 → **0.8.3.3** (3 commits: APSManager thread-safety + version bump), audited (`patch-test.sh` PASSED, sentinel intact) before building.
- **Build env fix:** first attempt failed at Ruby Dependencies — shell PATH resolved system ruby 2.6 (no bundler 4.0.4); relaunched with `/opt/homebrew/opt/ruby/bin` prepended. (Worth pinning ruby in `ci/local-build.sh` so this can't recur.)
- **Known non-blocking warning:** `G7WatchSensorAdapter.swift:1491` — delegate conformance "crosses into main actor-isolated code" (Swift-6-mode error, current-mode warning). **Pre-existing** (the `@MainActor` class conforms to the non-isolated `WKExtendedRuntimeSessionDelegate`), not a v2 regression. Flag for the eventual Swift 6 migration.
- **Patches uncommitted** (per AGENTS.md — commit after soak verifies). dev synced + at 0.8.3.3.
- **Soak read-out (per design §6):** per-arm (`delay_ms` 0/100/300) replacement-started rate, rejection rate (overlap axis), retry-succeeded rate, `reanchor_in_swap`×EGV-gap correlation (BLE-sever axis), survival 5/15 min. Watch `reanchor_armA_disabled`, `reanchor_swap_backstop_cleared`, and `ext_session_renew_skipped reason=reanchor_swap_in_flight` persisting >20 s. **Plus** the §9 blocker: how often does the user go >60 min without a foreground open (does re-anchor even earn its keep)? Soak ~3–4 days. **Build 213 changed only the re-anchor; the connect-collision D1-fix1 (2/3 of build-212's misses) is the next build.**

**v1.11 — 2026-06-21 — SHIPPED**
- **Build 212 deployed to TestFlight** as `0.8.3 (212)`. Full deploy succeeded (23m11s): compiled clean (the untested watch code BUG-E/F/monochrome built with zero errors), archived, uploaded, GitHub releases recorded (`trio-v0.8.3-212-localCI`).
- **Integration:** fork `G7SensorKit` merged to `main` + pushed (`3da042a`, C-212-1/2/3 = BUG-B/C); patch-02 repinned `c5eb668→3da042a`; patch-09 cherry-pick regen with C-212-4/5/6 (BUG-F/E/monochrome).
- **Upstream sync:** dev synced 0.8.2 → **0.8.3.2** (merged `origin/dev`, carrying the GH-action `upstream/dev` merge). Done "sync first, audited": `patch-test.sh` PASSED on the 0.8.3.2 base (sentinel "all pump-migration symbols present" ✓) **before** building.
- **Gotcha the audit caught:** `--from-feature-branch` regen swept patch-13's `AppleWatchManager.swift` changes into patch-09 (both edit that file, split by commit) → patch-13 double-applied + conflicted. Fixed with `--cherry-pick` of the 4 C-212 commits (none touch `AppleWatchManager`). **Lesson:** for a patch whose file is shared with another patch, use `--cherry-pick`, not `--from-feature-branch`.
- **Soak next:** watch `ext_session_reanchor`/`ext_session_reanchor_timeout` (BUG-E), `connect_timeout` (BUG-B), `suspected_eos_ignored` (BUG-C), `scene_phase`/`ext_session_active` stamping (BUG-F). For BUG-E's gain, soak on **Default** Return-to-Clock (A/B showed ~2× session coverage vs 1-hour).

**v1.10 — 2026-06-21**
- **BUG-E implemented** as C-212-5 (commit `dfc6c9f2d` on `feature/watch-g7`): near-expiry extended-session re-anchor in `renewSessionIfNeeded`. The naive inline sketch was caught by review (overlapping-request rejection), so the shipped version is **sequential** (invalidate → restart from the `didInvalidate` callback) with a `pendingReanchor` re-entry gate + 15s watchdog. 4 `cursor-task` rounds to no Blocker/High. §11 + §8 updated. Not built — needs soak.
- **C-212-6** (commit `656fd4fae`): grayscale the watch face when `scenePhase != .active` — a passive Return-to-Clock glance (`.inactive`) now reads grey vs full-color when actively open, surfacing the active/inactive distinction that drives session uptime. View-only; cursor-task PASSED. (Charlie-requested.)

**v1.9 — 2026-06-21**
- Added §11: full **BUG-E investigation** (handshake is fast not the bottleneck; `ext_session_active` predicts success 98% vs 58%; session lifetime ~60min but ~17–22% uptime; `.inactive` session-start OS-blocked = confirmed dead end; the **Return-to-Clock A/B** showing Default gives ~2× the session coverage of 1-hour, with the mechanism). Includes the **near-expiry `.active` re-anchor sketch** (not implemented). BUG-E reframed from "no fix" to "session-uptime lever, app-open-bounded; RTC setting is the bigger, now-measured lever."

**v1.8 — 2026-06-21**
- **BUG-F complete:** pt2 shipped (C-212-4 pt2, commit `ff898835f` on `feature/watch-g7`) — fork `g7_core` events now carry `scene_phase`/`ext_session_active` via ring context, refreshed by `didSet` observers on the scene/ext properties (robust auto-sync vs hooking each change site). 2 cursor rounds, no Blocker/High. Marked BUG-F ✅ done.

**v1.7 — 2026-06-21**
- Charlie authorized switching the `Trio` worktree to `feature/watch-g7`. **BUG-F pt1 shipped** (C-212-4, commit `29f2d3e50` — centralize `scene_phase`/`ext_session_active` stamping on `g7_ble` events; 2 cursor rounds). **BUG-F pt2** (fork `g7_core` via ring context) fully designed but deferred (multi-file, sync-on-change, unverifiable overnight). **BUG-H** root cause found unconfirmed (standard defaults appear to survive in-place upgrades) → not implemented. **BUG-E** still deferred (ext-session complexity). One claude-task misapplied an edit (duplicated `log()`, deleted `stopTimers()`) — caught by cursor-task, reverted, re-applied deterministically. **Trio worktree is now on `feature/watch-g7`** (was `feature/ns-richer-settings`).

**v1.6 — 2026-06-21**
- Autonomous run (§10): **BUG-D refuted** (auth is sensor-driven/required — would break connectivity), **BUG-A verified** (211 worn-time `no_runtime` gating ≈ 0), and **BUG-E/F/H documented as watch-adapter-blocked** with concrete code pointers. No fork/watch code shipped this run beyond the committed BUG-B/C.

**v1.5 — 2026-06-20**
- BUG-C shipped as **C-212-3** (corroborate suspected-end-of-session before `scanForNewSensor`, in `G7CGMManager`), commit `3da042a` on the same fork branch. 3 `cursor-task` rounds to no Blocker/High; accepted Mediums documented (§9). Marked BUG-C ✅ done in §8. Both HIGH fork items (BUG-B, BUG-C) now done; remaining build-212 items are MED/LOW.

**v1.4 — 2026-06-20**
- Added §9 implementation log: BUG-B shipped as **C-212-1** (connect-attempt timeout, recurring watchdog) + **C-212-2** (zombie-clock pinned to the current attempt), on fork branch `feat/c212-1-connect-timeout` (commits `29589a3`, `f9966f7`). 5+2 `cursor-task` rounds to no Blocker/High; accepted residuals documented. Not built/pushed/repinned. Marked BUG-B ✅ done in the §8 master list.

**v1.3 — 2026-06-20**
- Added §7.5 carried verification debt: C-210-1 (mmol/L face display, P0) + C-210-2 (arbitration, P1) shipped but build-unverified, surfaced by the reconciled budding-list (D210-7/8) + verified complication scan.
- Added VERIFY-1/VERIFY-2 to the master list. Flagged VERIFY-1 as **not closable by us** (mg/dL n=1 device; no display-unit field in BetterStack) → best-effort, does not gate 212.

**v1.2 — 2026-06-20**
- Confirmed via the build-210 impl log (+ user screenshot) that **all budding-list items shipped**: D210-1 (C-210-3, b210), D210-2 (C-210-4/5, b210), D210-5 (C-210-8, b210), and D210-3/4 (C-210-6/7) **landed in build 211** via the fork. Removed D210-1/D210-5 from the action list.
- Corrected §5 attribution: the 211 efficiency gain is the **C-210-7 connect-gate** landing (confirmed, not inferred).
- Tied **BUG-B** to the C-210-6/7 review's accepted "no connect timeout" residual (round-1 finding E); added the **shared-fork workflow/risk** callout to §8 (BUG-B/C/D/E are fork-level, attended).

**v1.1 — 2026-06-20**
- Swept prior notes + `docs/backlog/` for pending items and folded the in-scope ones in (§7).
- Confirmed budding-list ship status from telemetry/source (D210-2/3/4 shipped; D210-1/5 pending).
- Added BUG-H (daily-counter upgrade persistence, explicit build-212 backlog target) and D210-1 (capture-rate main display).
- Added the consolidated master change list (§8) and updated sequencing (§6).

**v1.0 — 2026-06-20**
- Validated the prior four-fix handoff against live BetterStack data and the watch-adapter source.
- **Re-rooted Fix #1** (the "dormant/torn-down central" diagnosis is wrong — see §2).
- Added independent EGV success/failure analysis → 7 ranked issues for build 212 (§4).
- Validated the 208→211 build trajectory for net effect on EGV reliability/efficiency (§5).

---

## 1. Validation summary of the prior handoff

Most of the prior doc reproduces **exactly** against a fresh pull; a few load-bearing claims do not.

| Prior claim | Verdict | Evidence |
|---|---|---|
| Headline coverage, clean days (Jun 14–19) | ✅ Reproduced exactly | unique-EGV and connect counts match to the row |
| Connection funnel totals (§3.4) | ✅ Within ~1% | 6,631 connect_called / 6,242 did_connect / 2,330 bonded / 1,105 pre_egv |
| Pre-EGV timing: 3–10s spike, max run 22 (§3.3) | ✅ Reproduced | buckets ≤2s 323 / 3–10s 569 / >10s 69 / none 144; max_consec 22 |
| 37% of connections fully (re)bond | ✅ Reproduced | 2,330 / 6,242 = 37.3% |
| **Fix #1: "central torn down, never restarted"** | ❌ **Wrong mechanism** | §2 |
| Fix #2: stale-binding spiral is real | ⚠️ Real, premise off | a hard-reset path already exists and failed; §4-B / §4 note |
| Fix #3: "~6× re-reads" | ⚠️ **Overstated → 3.9×** | 4,299 read-events / 1,110 unique = 3.87× |
| §3.2 per-scene yield | ⚠️ Directional only | `scene_phase` present on only ~50% of did_connect/egv, 0% of connect_called/pre_egv |
| Jun 12 row (141 unique) not reproducible | ✅ Explained — **not an error** | 8-day retention: Jun 12's early hours have aged out, so a later pull legitimately sees fewer rows. The doc's number was correct when pulled. |

**Net:** the prior doc's data collection is trustworthy. Fixes #2 (spiral), #4 (3–10s notify kill), the funnel, and clean-day coverage all hold. The corrections are: re-root Fix #1, down-rate the Fix #3 multiplier, and treat the per-scene table as directional.

---

## 2. Corrected root cause of the Jun 13 outage (re-roots Fix #1)

The prior doc split the 27 h outage into "Phase 1 — dormant stack (00:00–14:00), BLE emits *literally nothing*, wasn't trying" and "Phase 2 — stale-binding spiral." **Phase 1 is misdiagnosed.** During that window the stack was alive and emitting; the prior §3.1 table simply didn't chart the events that prove it.

What actually happened on Jun 13 (UTC), from the events the prior table omitted:

| Window | Reality (events present) |
|---|---|
| 00:00–03:00 | `expected_window eligible=true reason=ok` every ~5 min **+ `ble_gated reason=no_runtime`** — connects were **gated because there was no extended-runtime session**, not because the central was dead. |
| 04:00–14:00 | `will_restore_state restored_peripherals=1` (state restoration **working** — iOS relaunching the app), `connect_called` (2/hr), **`connect_skipped reason=in_flight`** — connect attempts were **skipped because a prior connect was stuck in-flight**; `did_connect`≈0. |
| 15:00 → Jun 14 02:00 | stale-binding spiral (prior Phase 2) — **confirmed**. Heavy churn, ~0 links, 0 EGVs. |
| Jun 14 03:00 | clean recovery, 36 connects → 36 EGVs — **confirmed**. |

Independently confirmed in source (G7 adapter / `G7BluetoothManager`):
- `CBCentralManagerOptionRestoreIdentifierKey` **is already set** → state restoration is on (and `will_restore_state` proves it firing).
- The `CBCentralManager` is **never torn down**; there is an explicit `ext_session_bg_invalidation_ble_kept` keep-alive path.

**Therefore the prior Fix #1 ("remove the stop()/teardown, rely on state restoration") is a no-op — there is no teardown to remove and restoration is already in place.** The real Jun 13 mechanisms are (a) **`no_runtime` gating** of BLE when no extended-runtime session exists, and (b) a **stuck in-flight connect** that suppresses all retries until relaunch. These become BUG-A and BUG-B in §4.

> Note: both mechanisms are now **largely mitigated** in build 211 (no_runtime gating 47→3; see §5), so the catastrophic Jun 13 form is mostly a build-208 artifact. The in-flight-stall mode (BUG-B), however, has **partially returned** in 211 (3 stall-hours) and is the top remaining reliability risk.

---

## 3. Method note (so the next agent doesn't re-derive)

- Use the structured JSON `event` field (`JSONExtract(raw,'event',…)`), not regex on `message` — some messages carry two `event=` tokens (e.g. `connection_event event=1`).
- **Coverage = `countDistinct(sequence)` for `egv_received` ÷ 288.** `egv_received` is a *read-event* count (~4× unique), never use it raw for coverage.
- `scene_phase` is present on ~50% of `did_connect`/`egv_received` and **0%** of `connect_called`/`pre_egv_disconnect` — any per-scene rate is a subsample (BUG-F).
- Build comparison here is **observational**, not controlled: days differ in wear, sensor sessions, off-wrist/charging time, and RF. Treat single-day deltas as low-confidence.

---

## 4. Independent EGV success/failure analysis → build-212 issue list

Ranked. Each carries the telemetry that backs it. Normalized counts are per `did_connect` over the build's window (208 n=1,153 / 209 n=4,027 / 211 n=934 did_connects).

### BUG-B (HIGH) — Stuck in-flight connect has no timeout → multi-hour total stall
The single highest-value reliability fix.

- `connect_skipped reason=in_flight` fires constantly (~0.5 per `did_connect`, all builds). Benign in steady state — it's just dedup of concurrent connect requests. **But when the in-flight `CBPeripheral` connect becomes a zombie that never completes or fails, every subsequent connect is skipped as `in_flight` until the app is relaunched** → an entire hour (or more) with `connect_called>0, did_connect=0, egv=0`.
- "Dead/stall hour" tally (hours with attempts but zero EGVs):

  | Build | active hrs | dead-attempt hrs | no-link hrs | in-flight-stall hrs |
  |---|---:|---:|---:|---:|
  | 208 | 65 | 20 | 9 | **9** |
  | 209 | 68 | **0** | 0 | **0** |
  | 211 | 47 | 3 | 3 | **3** |

- **Fix:** cap in-flight connect duration; on expiry `cancelPeripheralConnection` + clear the in-flight flag so the next `connect_called` proceeds. Never let "in-flight" persist longer than ~1–2 connect windows.
- **Lineage:** this is the **accepted-residual "no connect timeout"** from the C-210-6/7 review (build-210 log, round-1 *finding E* "`.connecting` retry drop — downgraded Medium→Low, pre-existing, not a regression"; reaffirmed at round-3 north-star "no connect timeout"). C-210-6's re-kick deliberately **excludes** `.connecting` peripherals (only cancels `.connected` zombies), so a stuck in-flight attempt is by-design out of its scope. Telemetry now quantifies that accepted gap at **3 dead hours in build 211** — promoting it from "soak follow-up" to a HIGH fix.
- **Acceptance:** zero hours with `connect_called>0 AND did_connect=0` inside an active session.

### BUG-C (HIGH) — False `suspected_end_of_session` churn loop
- Build 209 logged **419** `suspected_end_of_session` in ~3.5 days; a real sensor ends ~once per 10 days, so essentially all are **false**. Persists at ~0.10/`did_connect` in 211.
- Trigger pattern (from a live trace): `disconnect was_remote=true pending_auth=true` → `suspected_end_of_session` → `rescan_scheduled delay_s=0` → reconnect → `pre_egv_disconnect`. A peripheral-initiated disconnect *during auth* is mis-read as end-of-session, kicking an immediate (delay 0) rescan that re-drops.
- Correlates with EGV loss: Jun 19 09:00 UTC had 7 `suspected_eos` + 7 `pre_egv` and only **5/12** EGVs that hour.
- **Fix:** require corroboration before treating a mid-auth remote disconnect as EoS (e.g. `minutes_since_last_egv` over threshold AND advertisement actually gone). Back off the rescan instead of `delay_s=0` hammering.
- **Acceptance:** `suspected_end_of_session` drops toward real session-end cadence (≈ per sensor change); hours with high `suspected_eos` no longer under-yield.

### BUG-A (MED — verify, mostly mitigated) — `no_runtime` BLE gating
- `ble_gated reason=no_runtime` blocks connects when no extended-runtime session exists. Caused the Jun 13 00:00–03:00 dead window. Already down 47 (208) → 28 (209) → **3** (211).
- **Action:** confirm the 211 mitigation is robust overnight (when the watch *is* worn) and that an eligible window can always obtain or proceed without a runtime session. Distinguish genuine off-wrist/charging gaps (legitimate, not a bug) from gated-but-worn.

### BUG-D (MED) — Redundant auth on already-bonded sessions
- `auth_payload_ignored` ~0.31 per `did_connect`, flat across 209→211. Live trace shows `auth_notify_requested` re-issued after a session is bonded, consuming the short connect window and racing the 3–10s kill.
- **Fix:** skip the auth handshake when a valid bonded G7 session already exists; go straight to enabling the EGV/backfill notifications.

### BUG-E (MED — was Fix #4) — 3–10s pre-EGV disconnect at notify-enable
- Confirmed: 52% of pre-EGV disconnects fire at 3–10s (the CCCD-subscribe / EGV-delivery window); ~0.13 per `did_connect` in 211. Notify-enable `timeout` is logged (`auth_notify_failed`) and dropped silently rather than triggering a reset.
- **Fix:** keep the connect+subscribe inside one runtime budget (time scans to the G7 ~5-min advert window); route notify-enable timeouts into the hard-reset path instead of a silent `pre_egv_disconnect`.

### BUG-G (efficiency tuning, watch — do NOT regress reliability) — 211 throttle vs coverage
- Build 211's connection throttle is a big efficiency win (§5) but its full-day coverage (Jun 19, 58%) sits below 209's peak (Jun 16–17, 68–69%). Low confidence (n=1 full 211 day; overnight off-wrist inflates the gap).
- **Guidance:** do **not** loosen the throttle to chase coverage. Recover 209-level reliability by fixing BUG-B/BUG-C (the failure modes the throttle exposed), keeping 211's efficiency.

### BUG-F (LOW — diagnosability, but cheap and unblocks future analysis)
- `scene_phase` and `ext_session_active` are missing on ~50% of `did_connect`/`egv_received` and **all** `connect_called`/`pre_egv_disconnect`. This is why the per-scene yield table is only directional.
- **Fix:** stamp `scene_phase` + `ext_session_active` on **every** `module=g7*` event so foreground/background attribution is exact.

---

## 5. Did the last four builds help? (208 → 211 net effect)

**Short answer:** Net **positive on catastrophic reliability and on efficiency/battery**; **mixed on steady-state coverage.** The optimization swung from "brute-force reliable" (209) to "efficient but slightly fragile" (211). The two are reconcilable by fixing BUG-B/C.

### Reliability (catastrophic)
- The only multi-hour outage in the window (Jun 13, ~27 h) was **build 208**. No comparable outage in 209/210/211.
- `egv_watchdog_fired` 23 (208) → 8 (209) → **0** (211). `ble_gated no_runtime` 47 → 28 → **3**. `command_timeout` 0.072 → 0.033 → 0.025 per connect. `stale_sensor_binding_suspected` 0.112 → 0.036 → 0.020 per connect.
- ✅ **Clear improvement.** Big-outage risk and degraded-state churn both down.

### Reliability (steady-state, the surprise)
- **Build 209 was the most reliable build by far: 0 dead-attempt hours in 68 active hours** — every hour it was active produced EGVs. It achieved this by brute force (see efficiency below).
- **Build 211 reintroduced 3 dead/stall hours** (the in-flight-connect zombie, BUG-B). ⚠️ A small regression that the efficiency throttle exposed.

### Efficiency (battery / radio)
- Connects per **unique** EGV (full days): 208 ~5.7–6.1 → 209 ~7.5–8.0 → **211 ~2.7–3.2**.
- Re-reads per unique EGV: 209 ~4.7–6.1× → **211 ~2.0×** (211 essentially stopped redundantly re-reading the same EGV).
- `connect_called`/day: 209 up to ~1,490 → 211 ~470.
- ✅ **Large improvement** — roughly 2.5–3× less radio work for the same unique EGVs.
- **Confirmed cause:** the **C-210-7 connect-gate** (≤8 connects/5-min window) landed in **build 211** (deferred out of 210; fork `e56736b36` + patch-02 repin, Jun 17). The 209→211 churn collapse is this gate, not a coincidence. Its sibling C-210-6 (re-kick) landed the same time — but, per BUG-B, both deliberately left the in-flight/`.connecting` stall untimed, which is the 3-dead-hour regression below.

### Coverage (the headline user metric)
- Full-day unique-EGV coverage: Jun 16 67.7% / Jun 17 69.4% (209) vs Jun 19 58.0% (211). ⚠️ ~10 pts lower under 211, **but** n=1 full 211 day and Jun 19's 00:00–04:00 gap is "no events at all" (consistent with the watch off-wrist/charging overnight, i.e. legitimate, not a BLE failure). Per-connect EGV yield is similar across builds (~0.63–0.77), so 211's lower total is mostly *fewer connects × same yield* + off-wrist time, not worse per-attempt success.
- Verdict: **inconclusive / slightly down**; needs ≥3 more full 211 days. Daytime worn coverage for 211 looks ~70%+.

### Build-trend bottom line

| Axis | 208 → 209 | 209 → 211 |
|---|---|---|
| Catastrophic outages | ✅ fixed (no repeat of Jun 13) | ✅ held |
| Steady-state dead hours | ✅ 20 → 0 | ⚠️ 0 → 3 (BUG-B returned) |
| Efficiency / battery | ❌ worse (brute force) | ✅✅ 2.5–3× better |
| Coverage (full day) | ✅ up (~40% → ~68%) | ⚠️ ~68% → ~58% (low confidence) |

**The endgame for build 212:** keep 211's efficiency, recover 209's perfect steady-state reliability by killing the in-flight stall (BUG-B) and the false-EoS churn (BUG-C). Those two are the failure modes that 211's throttle no longer hides.

---

## 6. Recommended build-212 sequencing

1. **BUG-B (in-flight connect timeout)** + **BUG-C (false-EoS corroboration)** — together they restore 209-grade reliability without touching the 211 efficiency throttle. Ship and watch one full week of full days.
2. **BUG-F (stamp scene_phase/ext_session_active everywhere)** — cheap, ride along with #1 so the post-deploy analysis is exact.
3. **BUG-D (skip redundant auth)** + **BUG-E (protect notify-enable across 3–10s)** — recover the spread daytime micro-losses.
4. **BUG-A** — confirm the 211 `no_runtime` mitigation is robust; only act if worn-time gating reappears.
5. **BUG-G** — re-measure coverage after #1–#3 before considering any throttle change. Do **not** loosen the throttle pre-emptively.

Re-run the per-build dead-hour and coverage tables after each step (queries: per-hour `egv/connect_called/did_connect/skipped_in_flight` grouped by build; coverage = `countDistinct(sequence)/288`).

Slot the §7 carried items in: **BUG-H + D210-1 ride with step 2** (both are diagnostics/display and pair naturally with the BUG-F telemetry pass); **D210-5** verification rides with step 4 (it's adjacent to the `no_runtime`/stall instrumentation).

---

## 7. Incorporated pending items (prior notes + `docs/backlog/` sweep)

Source notes folded in: the **build-210 budding list**, the **watch-debug-counter-persistence** backlog idea (explicitly *target: build 212*), and a sweep of `docs/backlog/`. Ship status of the budding items was confirmed against telemetry + source so already-shipped work isn't re-planned.

### 7.1 Budding-list (build-210) ship status — ALL SHIPPED except D210-6

Confirmed against the build-210 impl log (`Trio` worktree — it only exists there, not in `Trio-dev`) + the screenshot + telemetry. **Every budding item is shipped; nothing carries into 212's action list except the deferred D210-6.**

| Item | Status | Evidence |
|---|---|---|
| D210-1 — main face shows **capture success rate** (`127/252`) instead of EGVs/connects | ✅ **Shipped — build 210** | C-210-3, commit `8d849bcbe`; **confirmed in the user's watch screenshot** (`3 min · BLE · 127 / 252 · no direct`) |
| D210-2 — direct-BLE-stall detection + indicator + notification | ✅ **Shipped — build 210** | C-210-4/5, commit `37d4882af`; telemetry `direct_ble_stall_detected` ×15 / `direct_ble_stall_notified` ×1 |
| D210-3 — bound-but-stalled connection-event re-kick | ✅ **Shipped — build 211** | C-210-6 (deferred out of 210; landed Jun 17 via fork `e56736b36` + patch-02 repin after 5 review rounds) |
| D210-4 — connect-gate / reconnect-storm throttle | ✅ **Shipped — build 211** | C-210-7 (same fork landing); **this is the change behind §5's 7.9→2.7 connects/EGV drop** |
| D210-5 — Dexcom-vs-Trio fault classification | ✅ **Shipped — build 210** | C-210-8, commit `37d4882af` (`sessionConnectAt` recency → Dexcom-side `unavailable` / Trio-side `stalled`); the **`no direct`** tier in the screenshot is this classifier |
| D210-6 — restore the C-209-5 ComplicationLogBuffer hunk (`battery_src=` + 15s TTL) | ⏸ **Deferred — owned by dev-sync 09+12 merge**, not 212 | archived at `C-209-5-CLB-hunk-to-restore.patch` |

### 7.2 BUG-H (MED — diagnostics) — Daily counters don't survive an in-place upgrade
**Source:** `docs/backlog/watch-debug-counter-persistence/` (target: build 212; observed after a 211 deploy).

- `bleConnectsToday` / `bleEGVsToday` (the `· BLE · egvs/conns` status pair + Complication Debug View) **reset on app upgrade** instead of carrying the day's running totals across an in-place install. Daily counters should only zero at local-midnight rollover.
- Code pointers (from the backlog doc): `G7WatchSensorAdapter.swift` daily-counter block (~L616–680) persists to **`UserDefaults.standard`** under `G7WatchAdapter.bleConnectsToday` / `…bleEGVsToday` / `…bleCountersCalendarDay`; displayed at `ComplicationDebugView.swift:589` + `GlucoseTrendView` status line.
- **Fix:** move the daily counters to the **app-group** container (already used by `TrioComplicationDataStore` / `ComplicationLogBuffer`) so they survive upgrade; keep the forward-only local-midnight rollover; rule out any `[UPGRADE]` build-change handler clearing the keys.
- **Acceptance:** install N with non-zero same-day counts → upgrade to N+1 mid-day → debug view + status line still show the day's accumulated totals (not 0); midnight rollover still zeroes once/day.

### 7.3 D210-1 + D210-5 — already shipped (no action)
- **D210-1 (capture success rate on main face):** ✅ shipped as **C-210-3** (commit `8d849bcbe`); `GlucoseTrendView` status line shows `captures / eligible-slots` via `G7WatchSensorAdapter.dailySlotStats()`. Confirmed live in the user's screenshot (`127 / 252`). *Note: the counter-persistence doc's reference to a `egvs/conns` label is stale — the face already shows the honest ratio. BUG-H (the upgrade-reset of the underlying counters) is the only live item on this surface.*
- **D210-5 (Dexcom-vs-Trio fault classification):** ✅ shipped as **C-210-8** (commit `37d4882af`); `sessionConnectAt` recency splits Dexcom-side (`unavailable` / "no direct") vs Trio-side (`stalled`). The `no direct` tier in the screenshot is this classifier. No build-212 work needed.

### 7.4 Related watch backlog — explicitly OUT of scope for build 212
Captured so they aren't conflated with the EGV-capture reliability work; each is a different subsystem/track:

- **`notif-complication-refresh`** — refresh the complication on notification *interaction* (snooze/tap/dismiss). This is complication **display freshness**, not BLE **capture** — separate track; don't fold into 212.
- **`watch-messaging-centralization`** — large architectural refactor of the WC messaging layer. Backlog candidate; not a 212 bugfix.
- **`perf-optimizations`** — holistic logging/battery audit. Thematically adjacent to 211's efficiency gains but a separate review; some of its intent (radio churn) is already partly addressed by C-210-4/7.
- **`watch-to-phone-reading-backfill`** — investigate syncing watch-only EGVs back to the phone when the watch legitimately catches readings the phone missed (logged this session). Future investigation, not 212.

### 7.5 Carried verification debt — C-210-1 / C-210-2 (shipped, build-UNVERIFIED)
Surfaced by the reconciled budding-list (D210-7/8) + the verified complication scan (`complication-freshness/watch-g7-scan-findings-verified.md`). Both shipped in build 210/211 but the build-210 impl log marks them **"CODE DONE, build-unverified."** These are *display-correctness* (complication), not EGV-capture, items.

- **C-210-1 (= D210-7) — canonical mg/dL + unit-aware face display (P0 safety).** Live bug: mmol/L users saw the raw mg/dL integer on the face (`100` instead of `5.6`) on the common BLE-wins path. Fix shipped, but **not verifiable by us:** (a) the only soak device is **mg/dL, n=1** — the bug is invisible on mg/dL; (b) **BetterStack carries no display-unit field** — EGV logs are canonical mg/dL; the mmol/mg-dL preference is a watch `UserDefaults` setting, never logged. → **Best-effort only:** close by code re-read and/or an mmol/L tester. Cannot be confirmed from telemetry or the current device. Do not block build 212 on it.
- **C-210-2 (= D210-8) — completeness-aware arbitration + `g7_sequence` guard (P1).** A bare WC reading (empty trend / `--` delta) could overwrite a complete BLE reading. Partially checkable from telemetry (BLE-vs-WC arbitration outcomes), but display-layer, not capture. Low priority; spot-check opportunistically.

---

## 8. Consolidated build-212 master change list

Reliability/efficiency (the EGV-capture core, §4) + carried items (§7), in implementation order:

| # | Item | Pri | Type | Layer | Source |
|---|---|---|---|---|---|
| 1 | **BUG-B** ✅ done — in-flight connect timeout (C-212-1) + zombie-clock pin (C-212-2) | HIGH | reliability | **fork** | §4, §9 |
| 2 | **BUG-C** ✅ done — corroborate suspected-end-of-session (C-212-3) | HIGH | reliability | **fork** | §4, §9 |
| 3 | **BUG-F** ✅ done — `scene_phase`/`ext_session_active` on ALL g7 events (pt1 `g7_ble` + pt2 `g7_core`) | LOW | diagnosability | watch + fork | §4, §10 |
| 4 | **BUG-H** — daily counters survive in-place upgrade (→ app-group) | MED | diagnostics | watch | backlog (target 212) |
| 5 | **BUG-D** — skip redundant auth on bonded sessions | MED | efficiency/yield | **fork** | §4 |
| 6 | **BUG-E** ✅ done — near-expiry session re-anchor (C-212-5); the 3–10s kill is a session-uptime problem | MED | reliability | watch | §4, §11 |
| 7 | **BUG-A** — verify `no_runtime` gating mitigation holds when worn | MED | reliability | watch | §2 (re-rooted Fix #1) |
| 8 | **BUG-G** — re-measure coverage before any throttle change | — | tuning guard | — | §5 |
| 9 | **VERIFY-1** — confirm C-210-1 mmol/L face display landed (`5.6`, not `100`) | P0* | display correctness | watch | §7.5 |
| 10 | **VERIFY-2** — confirm C-210-2 arbitration (bare WC can't clobber complete BLE) | P1 | display correctness | watch | §7.5 |

\* VERIFY-1 is a P0 safety bug but is **not closable by us** — mg/dL n=1 device + no display-unit field in BetterStack. Best-effort (code re-read / mmol tester); does not gate build 212.

All budding-list items are **shipped** (do not re-plan): D210-1 (C-210-3, b210), D210-2 (C-210-4/5, b210), D210-3 (C-210-6, b211), D210-4 (C-210-7, b211), D210-5 (C-210-8, b210). Deferred/elsewhere: D210-6 (dev-sync merge); notif-complication-refresh, watch-messaging-centralization, perf-optimizations, watch-to-phone-reading-backfill (separate tracks, §7.4).

> **⚠️ Workflow / risk — most of the core fixes are shared-fork.** BUG-B/C/D/E live in the `G7SensorKit` fork (`module=g7_core`/`g7_ble`) on the **shared iPhone+watch BLE path** — same surface and same risk profile as C-210-6/7, which needed **5 review rounds + a fork push + patch-02 repin** before soak. Plan build 212 as another attended shared-fork change (fork branch → loop review→fix to no Blocker/High → push `cachrisman/G7SensorKit` → repin `patches/02-g7-reading-time-with-seconds.patch` → `patch-test.sh` → build → soak). Only BUG-H and BUG-A are watch-adapter-only (lighter, patch-09 path).

---

## 9. Implementation log — BUG-B (C-212-1/2) + BUG-C (C-212-3)

**Status:** code complete, reviewed to no-Blocker/High. **NOT built, NOT pushed, NOT patch-repinned.**
**Fork branch:** `feat/c212-1-connect-timeout` off `cachrisman/G7SensorKit` main `c5eb668` (the C-210-6/7 baseline) — holds ALL build-212 fork changes.
**Commits:** `29589a3` (C-212-1) · `f9966f7` (C-212-2) · `3da042a` (C-212-3). Files: `G7BluetoothManager.swift` (B/zombie), `G7CGMManager.swift` (C).
**Authoring:** drafted/applied via `claude-task` (offload gate); reviewed via `cursor-task` (cloud) per the standard fork-review loop. Notes under the fork clone's `.claude/ollama-notes/`.

### C-212-1 — connect-attempt timeout (the BUG-B fix)
**Problem:** CoreBluetooth's `connect()` has no timeout. A peripheral wedged in `.connecting` (no `didConnect`/`didFailToConnect`) is skipped by every later `connectIfNotInFlight` as `reason=in_flight` — forever. This is the build-211 multi-hour in-flight stall (≈3 dead hours in telemetry, §5).

**Design (final):** a **recurring connect watchdog** (`scheduleConnectTimeout`). A new binding-scoped marker `connectIssuedAt` is set when the active binding issues a connect; the watchdog re-checks every `connectAttemptTimeout` (60s):
- `.connecting` past the timeout → wedged: `cancelPeripheralConnection` + keep watching (CB clears state async and a cancelled pending connect may fire no callback, so we must not rescan while still `.connecting`).
- `.disconnected` with the attempt still pending → cancel settled without a callback: re-issue via the standard retrieve+connect path (which re-arms a fresh watchdog); falls back to a re-arm if that reissue is gated.
- `.connected` → clear the marker and stop.

`connectIssuedAt` is **owned by connect-issue (set) + the watchdog (clear on `.connected`)**; explicit `disconnect()` and binding resets also clear it. **No delegate callback clears it** — that's the load-bearing invariant.

**Review path — 5 `cursor-task` rounds to convergence** (each closed a real Bluetooth-callback race):
1. cancel + synchronous `scanAfterDelay()` re-wedges (peripheral still `.connecting` when the rescan runs → skipped as `in_flight`). → recurring watchdog.
2. late `didDisconnect`/`didFailToConnect` from the cancelled attempt clears the marker → kills a newer attempt's watchdog. → stop clearing it in failure callbacks.
3. symmetric: late `didConnect` does the same. → make the marker fully watchdog-owned (no callback clears it); disarm on explicit `disconnect()`; doc fixes.
4/5. converged: no Blocker/High.

### C-212-2 — pin the zombie clock to the current attempt
**Problem (review High #2):** a belated/duplicate `didConnect` from a cancelled/superseded attempt could reset `currentConnectionStartedAt` (the C-210-6 zombie clock) to "now," making a real long-lived zombie look freshly connected and suppressing `shouldRekickBoundStalled`. C-212-1's cancel/reissue cycles widened the exposure.

**Fix path (2 rounds):** first attempt (only stamp when the clock is `nil`) was caught by review as *worse* — a missed disconnect callback would leave a stale clock on a fresh connection and trigger a **premature re-kick** of a healthy attach (the C-210-6 H1 scenario). Refined to **stamp only when `connectIssuedAt != nil`** (a connect we issued is pending): a long-lived zombie has it already cleared (no reset), and a genuinely new session always has it set even if the prior disconnect was missed (fresh baseline). Converged: no Blocker/High.

### C-212-3 — corroborate suspected-end-of-session (the BUG-C fix)
**Problem:** `suspectedEndOfSession` (`G7Sensor`: remote disconnect while auth was pending) is a heuristic that over-fires on transient RF blips — ~10% of connections in the 209/211 soak (630 events) vs a real session end ~once/10 days. Its consumer `G7CGMManager.sensorDisconnected` ran `scanForNewSensor()` **unconditionally** → forget the current sensor + rescan → reconnect churn + dropped EGVs. (The watch adapter already corroborates via `disconnect_suspected_eos_ignored`; the **phone path was the un-mitigated consumer**, and the iPhone is the north-star.)

**Fix (`G7CGMManager.swift`):** gate `scanForNewSensor()` on the reading clock — if a reading arrived within `suspectedEndOfSessionGracePeriod` (15 min ≈ 3 G7 cycles) the sensor is alive → ignore the suspicion (`emit suspected_eos_ignored`) and let normal reconnect recover; only scan once readings have actually stopped. Definitive ends (`.sessionEnded`/`sensorFailed` in `didRead`) are untouched and still scan immediately.

**Review path (3 `cursor-task` rounds):** r1 surfaced a cross-sensor-timestamp Medium; r2's attempted fix (clear the clock in `scanForNewSensor`) was caught as a **High** — `didRead` repopulates it on the terminal-message path, and fixing *that* means changing out-of-scope C-210 `didRead` behavior. r3: reverted that clear and **accepted the Medium as benign** (ignoring a fresh sensor's warmup blip is the correct action anyway; a real new-sensor failure is still caught by the definitive paths). Converged: no Blocker/High.

**Accepted residuals (C-212-3):** real end deferred ≤ grace window when no reading/definitive signal arrives; `latestReadingTimestamp` is manager-level (cross-sensor in a fast-swap warmup edge — benign); `nil` timestamp (pre-first-reading warmup) scans immediately as before.

### Accepted residuals — BUG-B (C-212-1/2), documented & benign — no High
- **CB callbacks can't be matched to a specific attempt** (no token). `connectIssuedAt != nil` is the best heuristic; worst case is a slightly skewed connection-age baseline — never a false teardown (re-kick still requires `.connected`).
- 60s timeout may cancel a slow-but-valid connect (it re-issues immediately) — soak-tunable; watch `connect_timeout` `age_s`.
- No timeout for unbound pre-pairing discovery connects — same scope limit as C-210-7's gated-retry (finding E).
- Recovery latency ≤ ~2 reading cycles after a silent cancel.

### Deferred (NOT done) — your call
None outstanding for BUG-B. (The reviewer's zombie-clock High #2 was addressed by C-212-2.)

### Soak signals (post-deploy)
- **BUG-B:** `connect_timeout` (frequency + `age_s` — if it fires on *healthy* connects, tune the 60s), `connect_timeout_reissue`; the §2 coverage / §4 dead-hour tables (build-211 in-flight-stall hours → 0).
- **BUG-C:** `suspected_eos_ignored` (should now absorb most of the ~630 `suspected_end_of_session` events) and a drop in post-EoS reconnect churn / `pre_egv_disconnect` runs. Watch that a real sensor swap is still picked up within ~the grace window.
