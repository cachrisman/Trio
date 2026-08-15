# Build 218 Watch EGV — Implementation Plan

**Version:** v0.5 (2026-07-08 — **BUILT + DEPLOYED to TestFlight** as `0.8.4 (218)` / `trio-v0.8.4-218-localCI`: S-0 fork fix + E-1…E-6, batched onto all of 217. Patches uncommitted on `dev` pending verify-live. v0.4 — E-1…E-6 implemented (`50c3e035f`); S-0 committed (`7369b20`). v0.3: added S-0 (CRITICAL). v0.2: added E-6. v0.1: initial polish + dialed-in geometry).

**Predecessor:** build 217 (`0.8.4.x`) — LIVE on TestFlight 2026-07-07. Ships Tasks 1–4 (fork capture/recovery) + D-7 (diagnostics revamp/rename/kill-switches) + D-8 (edge ring + tuning panel) + V-2b (rectangular sparkline). Full record: `watch-g7-direct-ble-observer-build217-impl-log.md`. Its EGV-capture pass/fail verdicts (Tasks 1–4) need the ≥2–3 day soak — they are NOT part of 218.

**Scope of 218:** (1) **S-0 — a CRITICAL fork safety fix** (Task-2/4 escalation/re-init must not run on the iPhone primary path; caused a real CGM blackout), plus (2) small UI/UX polish on the 217 diagnostics view + edge ring (E-1…E-6, display-layer, EGV-path-disjoint). S-0 is a fork change → repin patch 02; the E-items are Trio-only → patch 09. Additional tasks may be appended once the 217 soak yields data.

> UI items (E-1…E-6) land on `feature/watch-g7` (Trio) → batched `--patch 09` (no new files ⇒ no `--extra-files`). **S-0 lands in the G7SensorKit fork → `repin-g7.sh` (patch 02).** Patches stay uncommitted on `dev` until build+deploy+verify (lifecycle). No AI attribution. **S-0 may warrant fast-tracking ahead of the E-items given it's CGM-on-an-insulin-app.**

---

## S-0 — CRITICAL: gate Task-2/4 (wedge escalation + central re-init) off the iPhone primary path ⛑️

**Status:** fork fix **committed** (`G7SensorKit@main 7369b20`); NOT yet pushed/repinned/built (batch or fast-track per user).

### The incident (2026-07-08, phone `platform=ios`, BetterStack-confirmed)
- Old sensor `DXCMyu` (~10.1 days, in grace) reading normally until **14:39:32** (seq 2922), then `disconnect was_remote=true` (flaky end-of-life sensor). The phone's reconnect **wedged** in `.connecting` for 279 s.
- **14:44:19** — build-217 **Task 2 `connect_wedge_persistent` (ticks=2) → Task 4 `central_reinit reason=wedge_escalation`** fired **on the iPhone** (fired once; the 120 s guard held).
- **14:44 → 16:13 (~89 min): the phone's G7 manager went 100% silent** — `g7_events=0` in every 5-min bucket, no scan, no `connect_called`, no `central_powered_on` — while the app otherwise ran in the background. Before the re-init it was actively (normally) reconnecting; it flatlined *the instant the re-init fired* and revived only on a cold app relaunch at 16:13:02, which reconnected to `DXCMyu` within ~90 s.
- **The sensor was fine the entire time:** the **watch** (independent BLE observer) kept reading `DXCMyu` throughout the blackout (seq 2924→2940, glucose 63–128) — so this was 100% a phone-side Trio failure, and it spanned a **real low (63–65 mg/dL ~15:04–15:14)** during which the phone loop had no fresh CGM (watch→phone backfill is unshipped).

### Root cause
Two design gaps, both in build 217:
1. **`central_reinit` recreates the `CBCentralManager`; in the background the new central never resumed scanning** — the exact CoreBluetooth risk the fork review flagged ("orphaned/non-scanning central; locked `.connecting` slot"), now confirmed in the wild.
2. **Task 2/4 were not scoped to the watch.** The fork kill-switch flags (`isConnectWedgeEscalationEnabled`/`isCentralReinitEnabled`) defaulted **ON for every host**, so the iPhone silently inherited a watch-only recovery tool — violating the iPhone north-star (AGENTS.md: "the iPhone relies on CoreBluetooth's own retry; no aggressive intervention"). CB's own retry *would* have recovered (it did, on relaunch).

### The fix (design + why this option)
**Flip the two fork kill-switch defaults `true → false` (opt-in per host)** — `G7Telemetry.swift` `G7BackgroundHints`. Rationale for choosing this over the alternatives:
- ❌ *Foreground-only re-init* — neuters Task 4 on the watch (almost always backgrounded — its whole purpose).
- ❌ *Rip out `central_reinit` / fork-spec fallback (rescan same central)* — big change to unproven-on-watch behavior; fork-spec itself calls it "weaker, may not clear a stuck `.connecting`." Premature.
- ❌ *Explicit `if platform == watch` gate* — duplicates intent, hard-codes a platform check into shared BLE code.
- ✅ **Default OFF, opt-in** — the kill-switch flags already mean "this host wants aggressive recovery." The **watch already opts in** (`G7WatchSensorAdapter.applyKillSwitchesFromDefaults()`, once per process in `start()`, from an on-wrist @AppStorage toggle defaulting ON). The **iPhone `G7CGMManager` never calls that**, so with the default flipped it stays OFF → reverts to pure CB-own-retry. Minimal (2 values), safe-by-default, no new flags, no platform checks, watch behavior unchanged.

**Change (committed `7369b20`):** `lockedWedgeEscalationEnabled` and `lockedCentralReinitEnabled` `Locked<Bool>(true) → Locked<Bool>(false)`, with doc comments recording the incident + the opt-in contract. `isHostBackgrounded` untouched.

**Ship path:** `repin-g7.sh` (patch 02 → `7369b20`) → `patch-test.sh` → build → deploy. If fast-tracked ahead of the E-items, repin + build alone; otherwise batch with the E-items' patch-09.

**Pass/fail (verify live after ship):** on the iPhone, `connect_wedge_persistent` / `central_reinit` no longer appear (`platform=ios`); a wedged iPhone connect recovers via CB retry with no G7-silence gap. On the watch, both markers still available (opt-in intact) and the on-wrist toggles still work.

### Residual risk (note — do NOT fix blindly)
The re-init's background-scan-death likely applies to the **watch** too (same fork), but: (a) no watch harm observed yet (`central_reinit`=0 on the watch in the 2026-07-07 window); (b) the watch has the on-wrist kill-switch; (c) disabling the watch's only wedge recovery pre-emptively is wrong. **Soak-watch signal:** on the watch, a `central_reinit` followed by a G7-silence gap (no `central_powered_on`, no EGV) = the same failure → then escalate to foreground/extended-session-gating or the fork-spec fallback. The 217 restore-id / `central_powered_on` markers make this detectable.

---

## Tasks

> **STATUS 2026-07-08:** E-1…E-6 **IMPLEMENTED** on `feature/watch-g7` (`50c3e035f`, one commit, all in `WatchDiagnosticsView.swift`, cursor + integrity-checked). S-0 fork fix committed (`G7SensorKit@main 7369b20`). **Remaining:** batched repin (patch 02 → `7369b20`) + patch 09 (cherry-pick `50c3e035f`) + `patch-test` + build + deploy. **E-6 was implemented as Option A** (keep all three identities, stacked legibly on divergence) — sidesteps the "which fields stay" decision; simplify to Option B later if the phone-relay row proves noise.

### Task E-1 — Edge ring: drive it off the "Next connect" countdown, not the reading countdown ⭐ (behavioral)

- **Now:** `edgeCycleRing` computes `fraction = g7CountdownFraction(from: snapshot?.readingDate, to: now)` — the same reference as the upper-right nav-title countdown (time since the displayed reading).
- **Want:** base the ring on the **next-connect** cycle, matching the G7 section's "Next connect:" row.
- **Change (`WatchDiagnosticsView.swift`, `edgeCycleRing`):** `let fraction = g7CountdownFraction(from: WatchState.shared.bleLastConnectAt, to: now)`.
- **Why:** the ring is a BLE-cycle indicator (5-min connect cadence), not a reading-age indicator; anchoring it to `bleLastConnectAt` makes the sweep and the "Next connect" text agree.
- **Pass/fail:** on-wrist, the ring fill tracks the "Next connect:" countdown, resetting on each connect.

### Task E-2 — Hardcode the dialed-in ring geometry as defaults ⭐

On-wrist tuning converged (user, 2026-07-07). Update the `@AppStorage` defaults in `WatchDiagnosticsView.swift`:

| Knob | 217 default | 218 default |
|---|---|---|
| `ringCornerRadius` | 48 | **37** |
| `ringLineWidth` | 3 | **6** |
| `ringInsetX` | 0 | **4** |
| `ringInsetY` | 0 | **3** |
| `ringTrackOpacity` | 0.12 | **0** |

- **Note:** `track = 0` ⇒ the faint track ring is invisible (user preference). The track stroke stays in the code (still tunable up); no structural change. Consider whether the track stroke is worth keeping at all — leave it for now (tunable, ~2 lines).
- The tuning panel STAYS (see E-3/E-4) — the knobs remain useful for future re-tuning; the new values are just better starting points.

### Task E-3 — Ring tuning steals the Digital Crown ⭐ (bug)

- **Symptom:** the `Stepper` rows capture Digital Crown rotation, so the crown adjusts a stepper instead of scrolling the diagnostics list. The D-8 design explicitly intended crown = vertical scroll, +/- buttons = adjust.
- **Root cause:** watchOS `Stepper` binds the Digital Crown to its value while focused.
- **Fix:** replace the `Stepper` in `ringStepper(...)` with an explicit **−/+ `Button` pair** (plain `HStack { Button("−"){…}; label+value; Button("+"){…} }`, clamped to the range, `.buttonStyle(.plain)` or `.bordered`), so the crown is never captured and the `ScrollView` keeps it for scrolling. Do NOT use `.digitalCrownRotation` anywhere in this view.
- **Pass/fail:** on-wrist, the Digital Crown scrolls the whole diagnostics view; ring values change ONLY via the on-screen −/+ buttons.

### Task E-4 — Ring tuning row display text (garbled/occluded) — SAME ROOT CAUSE as E-3

- **Symptom (confirmed by screenshot 2026-07-07):** the native `Stepper`, when focused, renders **oversized circular −/+ buttons that occlude the label**, and the label ("Corner" + value "37") **wraps across ~3 lines** behind them — on-wrist it reads as broken fragments ("…or 3 / n 7 / …er."). Unusable.
- **Root cause = E-3's:** the watchOS `Stepper` control itself (big focus-mode buttons + a wrapping label). Fixing E-3 (replace `Stepper` with a compact custom −/+ `Button` row) fixes this at the same time.
- **Layout for the replacement row:** `HStack { Button("−"); Text(label); Spacer(); Text(value).monospacedDigit(); Button("+") }` — small bordered/plain buttons (not full-width), `label`+`value` single line with `lineLimit(1)` + `minimumScaleFactor`, value right-aligned and fixed-ish width so it doesn't jump. Verify all five rows fit one line on the smallest supported watch.
- **Pass/fail:** each tuning row is one legible line with small inline −/+ buttons; no occlusion, no wrapping.

### Task E-5 — Logs "Upload status" wraps to two lines 

- **Symptom:** the LOGS section "Upload status:" row spans two lines; it should be one.
- **Fix (`WatchDiagnosticsView.swift`, `uploadStatusView` / its row):** enforce `lineLimit(1)` + `minimumScaleFactor` on the status text (D-7 intended "one line, e.g. `ACK (1)`"), and/or shorten the label ("Upload:") or the status strings ("`3L·1D queued`", "ACK (1)", "Clean"). The circle-dot + text HStack must not exceed one line at the label width.
- **Pass/fail:** the Upload status row is a single line across states (pending / queued / clean).

### Task E-6 — "Sensor:" divergence line is illegible — rethink the display (needs design)

- **Symptom (confirmed by screenshot 2026-07-07):** on divergence the merged Sensor row renders `exp DXCMyu · bnd — · ph DXC…` — three labelled fields crammed into one watch-width line, yellow, at `.lineLimit(1).minimumScaleFactor(0.5)`, and still **truncated** (`ph DXC…`). Nearly impossible to read — and it degrades exactly when it matters (a real binding divergence). The converged form (`DXCMyu ✓`) is fine.
- **Intent to preserve:** surface *which* of phone-relay / expected / bound disagree — a divergence can mean the observer is bound to the wrong sensor or unbound (the screenshot shows `bnd —` = the live `G7Sensor` is not bound while expected/phone say `DXCMyu`, a genuinely important state). Only the **legibility of the divergence form** is broken.
- **Design options (pick during impl — this is the "rethink"):**
  - **(A) Multi-line on divergence.** Keep one-line `NAME ✓` when converged; on divergence expand to a small `VStack` of up to 3 short rows (`exp DXCMyu` / `bnd —` / `ph DXCMyu`), each `lineLimit(1)` at a readable scale. Costs vertical space only when something's wrong (rare + important — acceptable).
  - **(B) Show only the deviating field(s).** Converged: `DXCMyu ✓`. Diverged: show only what differs from `expected`, e.g. `bnd — (exp DXCMyu)`. Phone-relay (`ph`) is the least load-bearing — consider dropping it from the row (leave it to BetterStack) so the row carries just the bound-vs-expected signal.
  - **(C) Icon + short form.** Yellow ⚠ + the single most-important mismatch (`bound ≠ expected`). Minimal but loses detail.
- **Recommendation:** lean **(B)** — least clutter, and "bound vs expected" is the load-bearing comparison; phone-relay divergence is informational. **Confirm with Charlie** which fields must stay before implementing. Fallback (A) if all three must remain visible.
- **File:** `WatchDiagnosticsView.swift` → `sensorRowText` / `sensorRowConverged` + the Sensor `HStack` in `G7DirectBleDebugSection`.
- **Pass/fail:** on a real divergence, the row is legible (no truncation, readable size) and still tells you which field disagrees.

---

## Sequencing

**S-0 is the priority and is fork-side** (already committed `7369b20`; needs `repin-g7.sh` + build + deploy) — fast-track it ahead of the UI items given it's a CGM-safety fix, or batch if shipping 218 as one. The E-items are all Trio-only (patch 09). E-1 + E-2 are one-liners; E-3 is the substantive change (Stepper → buttons) and subsumes E-4's layout; E-5 is independent; **E-6 needs a design decision (which fields stay) before coding**. Suggested single commit `watch(build-218): diagnostics polish — next-connect ring reference, dialed-in defaults, crown-safe tuning, one-line upload status, legible Sensor row`, or split the ring items (E-1..E-4) from the view-row items (E-5, E-6). Then batched `--patch 09`, then a build (user-instructed).

## Open / deferred
- **217 soak verdicts** (Tasks 1–4 pass/fail) land here as they arrive — may spawn further 218 capture tasks or a 219.
- **Track stroke** (E-2): if `track=0` proves the permanent preference, drop the track `EdgeRingShape().stroke(...)` entirely (minor cleanup).

## Changelog
- **v0.5 — 2026-07-08.** **Build 218 (`0.8.4`) BUILT + DEPLOYED to TestFlight** (`trio-v0.8.4-218-localCI`, 12m47s; TestFlight upload + GitHub release OK). Batched integration: patch 02 re-pinned to the S-0 fork commit `7369b208b` (pushed); patch 09 regenerated with the full 217+218 commit set (`--cherry-pick 5041e8ab5,bb6be20b7,a9170af9c,2a1b704b0,cae0ec386,0e3ccbaea,50c3e035f` — the committed `dev` patch 09 still predates the widened-net, so the full list was required; rename intact, E-items present); `patch-test` + patch-audit PASS. Deployed with `--include-untracked --no-sync-upstream` (skipped the unresolved upstream/dev merge). Note: mid-stack-update's *internal* patch-test reported a false failure on patch 10 (it stashed the pre-existing dirty patches 06/10 and tested their committed versions); the real working tree passes patch-test. **Patches 02/09 remain uncommitted on `dev`** pending verify-live. **S-0 verify:** on `platform=ios`, `connect_wedge_persistent`/`central_reinit` must no longer appear.
- **v0.4 — 2026-07-08.** **E-1…E-6 implemented + committed** (`feature/watch-g7@50c3e035f`, one commit, `WatchDiagnosticsView.swift`, via cursor, each integrity-checked): E-1 ring→`bleLastConnectAt`; E-2 defaults 37/6/4/3/0; E-3/E-4 native `Stepper`→plain −/+ `Button`s (frees the Digital Crown for scroll + fixes the occluded/garbled label); E-5 one-line `Upload:` / `ACK (N)`; E-6 Sensor row stacks exp/bnd/ph legibly on divergence (**Option A** — kept all three fields, no field-drop decision needed). S-0 fork fix already committed (`7369b20`). Remaining: batched repin + patch 09 + build + deploy.
- **v0.3 — 2026-07-08.** Added **S-0 (CRITICAL)** — BetterStack investigation of a phone CGM outage found build-217's Task-2/4 (`connect_wedge_persistent` → `central_reinit`) fired on the **iPhone** at 14:44 UTC when an end-of-life sensor's reconnect wedged; the background `CBCentralManager` re-init never resumed scanning → **~89-min iPhone CGM blackout** (across a real 63–65 mg/dL low), while the watch observer kept reading the (healthy) sensor throughout. Root cause: the fork kill-switches defaulted ON for every host, so the iPhone inherited a watch-only recovery tool (violating the CB-own-retry north-star), and background central re-init is unsafe (the fork review's flagged CONCERN, confirmed). **Fix committed** (`G7SensorKit@main 7369b20`): flip both kill-switch defaults `true→false` (opt-in per host — the watch adapter opts in, the iPhone stays OFF). Chose default-flip over foreground-gating / fork-spec-fallback / explicit platform-check (see S-0 for why). Scope note updated (218 now includes a fork change). Fast-track candidate.
- **v0.2 — 2026-07-07.** Added **E-6** — the "Sensor:" divergence line is illegible on-wrist (`exp DXCMyu · bnd — · ph DXC…`, crammed to one truncated tiny line). Rethink the divergence display (options A multi-line / B show-only-deviating-field / C icon+short; lean B, confirm which fields stay). Kill-switch escalation toggles were live-verified correct end-to-end (BetterStack `kill_switch_toggled` matched the on-wrist state) — **no 218 item needed** for those. Sequencing note + version updated.
- **v0.1 — 2026-07-07.** Initial. Five polish items from the live build-217 on-wrist review: E-1 ring → next-connect reference (behavioral), E-2 dialed-in ring defaults (corner 37 / width 6 / insetX 4 / insetY 3 / track 0), E-3 crown-steal fix (Stepper → −/+ buttons), E-4 tuning row text layout, E-5 one-line upload status.
