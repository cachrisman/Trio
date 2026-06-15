# Trio watch G7 observer — upstream pitch & PR plan

**Version:** 0.3 (draft for Charlie review — pitch + plan consolidated)
**Status:** In progress — Phase 4 prep (drafted during the 208 soak; packaging executes after
dev sync + feature-branch cleanup)
**Created:** 2026-06-11 06:00 CEST
**Last updated:** 2026-06-12 18:34 CEST

**Target:** nightscout/Trio (public PR + description). **Scope decision (Charlie):** minimal core
— logging/debug UI/telemetry stripped entirely. **Evidence policy:** aggregate numbers only — no
raw logs, timestamps, or glucose values. **Reviewer fears to pre-empt:** reliability bar, diff
size & quality.

---

## 1. The pitch — what upstream gets and why they want it

**One sentence:** the Apple Watch shows current CGM readings even when the iPhone is out of
range, asleep, or dead — by passively observing the Dexcom G7's BLE broadcasts directly on the
watch, with zero interference with the phone's pairing.

**Why this approach is the right one (the safety/ethics story, from the predecessor design):**
- **Observer-only, by design.** The watch never authenticates, never writes auth packets, never
  impersonates — it attaches as a read-only secondary central to the sensor the *phone* reports
  it is paired to (identity handed off over WatchConnectivity, never discovered independently).
  No bond, no key material on the watch, no conflict with the Dexcom app or Trio-phone session.
- **Phone-relay remains primary.** Direct BLE is an opportunistic *upgrade* channel with explicit
  source-priority arbitration (BLE > WatchConnectivity > HealthKit) — when the phone is present,
  behavior is unchanged; when it isn't, the watch keeps working.
- **Fails safe.** Wrong/no identity ⇒ the observer rejects all discoveries and the watch falls
  back to exactly today's behavior.

**The honest reliability framing (lead with it — don't let reviewers discover it):**
- watchOS gives third-party apps no entitlement for BLE-initiated background relaunch (the
  CGM-class `bluetooth-central-background` entitlement is special-grant; requested, pending), and
  no CoreBluetooth state restoration (terminated-app relaunch does not exist on watchOS). Within
  that constraint, measured capture of available 5-minute reading windows progressed
  **24.6% → 41%** across two builds of systematic fixes, with ~100% capture when the app has
  foreground or granted runtime, and **zero adapter-side data loss** (every reading the radio
  delivers is persisted — independently audited over 180 windows).
- This is an **availability supplement, not a replacement CGM path** — and the PR description says
  so. Phone-relay carries the primary SLO; the observer removes the "glanced at a blank watch"
  failure mode for phone-away periods.

**The maturity story (the diff-size defense):**
- 20+ iterations (builds ~179–208) with structured dual-platform telemetry on every build;
  documented hypothesis→data→fix loops (e.g. a 90% reduction in runtime-session invalidation
  errors root-caused to a plist regression; a false end-of-session heuristic measured at
  111/112 false-positive and corrected; a GATT-funnel analysis separating watch-side from
  transmitter-side losses).
- Multiple independent adversarial review passes over the final code (findings tracked, fixed,
  re-verified — `trio-fable5-review.md`); the supporting library fixes are being upstreamed to
  G7SensorKit separately with field evidence (see `01-g7sensorkit-pr-plan.md`).

## 2. Hard prerequisite — G7SensorKit must land first

This PR **cannot open until the G7SensorKit watchOS-support PRs land upstream**
(`01-g7sensorkit-pr-plan.md`). Two blocking reasons:

1. A public Trio PR cannot repoint the `G7SensorKit` submodule at `cachrisman/G7SensorKit`
   (patch 02). It must point at the canonical LoopKit repo, which therefore must already build
   for watchOS and expose the API the adapter uses.
2. The adapter imports fork-only surface (`G7Telemetry` hook — droppable; `G7CGMManager`
   reading-timestamp exposure used for the `g7Sequence` handoff — droppable at the cost of
   cross-channel sequence attribution). The minimum upstream G7SensorKit must provide the
   watchOS framework target and the `#if os(iOS)` isolation (G7SensorKit PR-A).

**Consequence:** the Trio PR's submodule pin waits on LoopKit merging PR-A (+ ideally PR-C). This
is the critical-path dependency; everything below assumes it.

## 3. What the feature is (one paragraph for the PR description)

On watchOS, Trio's glucose freshness depends on WatchConnectivity from the phone, which is
budget-limited (~50 transfers/day) and dies when the phone is away. This feature adds a
**passive BLE observer**: the watch runs its own `CBCentralManager`, latches onto the
phone-paired Dexcom G7 using sensor identity handed off from the phone, and reads EGVs directly —
**no pairing, no auth impersonation, no interference with the Dexcom app's session** (the watch
is a read-only secondary observer; the phone/Dexcom app owns the authenticated session). Readings
flow into the existing complication/snapshot pipeline with source-priority arbitration
(BLE > WatchConnectivity > HealthKit), so the watch shows fresh glucose independent of phone
proximity or WC budget.

## 4. Scope — the minimal-core cut

**Total: ~2,300–2,600 added lines** = patch 12 (+3,214/−394 over 18 files) − ~760 lines of
private-infra strip + ~250 inlined from patch 09 + ~150 from patch 13.

### KEEP — load-bearing (~2,200–2,400 lines)
| Component | Lines | Why essential |
|---|---|---|
| `G7WatchSensorAdapter` core | ~1,000–1,100 (post-strip) | the observer: CBCentralManager, auth gate + 6s fallback, EGV cadence + control-write retry, `willRestoreState`, connect-in-flight guard, per-session activation anchor, `WKExtendedRuntimeSession` lifecycle |
| `WatchGlucoseHistoryStore` | +198 | 24h rolling mg/dL so chart/complication survive without the phone; serial-queue serialization is correctness-critical |
| `WatchGlucoseColorComputer` + `GlucoseHueColor` (from 13) | +154 +~120 | on-watch color parity so WC payloads no longer carry per-reading color strings; shared HSB math keeps phone/watch identical |
| `WatchState` G7 integration core | ~350–400 | `G7DirectBLEStatus` state machine, reading ingestion, displayed-source attribution |
| `TrioMainWatchView` / `GlucoseTrendView` freshness gating | ~50–120 | don't blank a fresh BLE/HK reading when the phone is unreachable (buttons/IOB/COB still gate) |
| Reduced complication snapshot store + minimal `ExtensionDelegate` (inlined from 09) | ~250 | app-group snapshot store with source-priority `shouldUpdate` — upstream has no equivalent |
| Phone-side sensor-identity handoff (from 13) + `WatchMessageKeys`/model fields | ~160 | `AppleWatchManager` resolves/caches `g7ActiveSensorName` + activation epoch, persists across gaps, pushes thresholds — **without this the adapter cannot find the sensor** |
| `Info.plist` background modes | +18 | `physical-therapy` (WKExtendedRuntimeSession) + `bluetooth-central` — load-bearing; the build-203/204 regression proved their absence breaks everything |

### STRIP — private infra (~760 lines + in-file calls), replace with `os.Logger`
- `WatchTelemetryRing.swift` (+119), `G7StructuredTelemetryLogLine.swift` (+28) — BetterStack plumbing
- `ComplicationDebugView.swift` (+392/−205) — debug page; ship at most a one-line status row
- `WatchLogger`/`WatchErrorReporter` deltas (+123) — they modify patch-05/06 files absent upstream
- `WatchState` debug mirrors (~150–200 of +554): daily counters, slot accounting, restore flag
- adapter telemetry-context sync + ring enqueues (~200–300 of +1321)
- Zero BetterStack references in code or prose. (The crashlytics/AppDiagnostics experiment is
  absent by construction — it lives only in skipped patch 04.)

### INLINE from patch 09 (~250 lines)
A reduced `TrioComplicationDataStore` (snapshot save/load + source-priority `shouldUpdate`, no
ComplicationLogBuffer/ResidentTelemetry) + a minimal `ExtensionDelegate`. The snapshot store must
travel with the feature; upstream has nothing equivalent.

## 5. Pre-empting the two reviewer fears

### Fear 1 — "41% background capture reads as unfinished"
Frame it as an **SLO split, not a failure** (this must lead the PR description):
- Phone WatchConnectivity stays the **primary** glucose channel; the BLE observer is an
  **opportunistic upgrade** filling gaps WC structurally cannot (phone away, budget exhausted,
  between transfers).
- The numbers are an **improvement trajectory on a previously-zero capability** (24.6% → 41%);
  the watch saves ~100% of the EGVs its radio receives — the loss is radio availability, not
  processing.
- The ceiling is **platform-imposed, documented, outside the feature's control** (no watchOS CB
  state restoration; CGM-gated `bluetooth-central-background` entitlement). The feature is correct
  *given* those constraints and does not regress the WC path it augments.

### Fear 2 — "diff size & quality"
- **Minimal-core cut** takes the surface from ~3,200 to ~2,400 lines, mostly in **new files** —
  low blast radius; the existing-file deltas are small and localized.
- **Additive & gated:** opt-in, runs only when the phone hands off a sensor identity, touches no
  existing CGM path. Disabled → zero behavior change.
- **Paper trail of rigor:** 24 builds of telemetry-driven iteration, multi-pass adversarial
  review, G7SensorKit fixes landing upstream separately as evidence the BLE layer is sound.
- **Observer-only posture:** no J-PAKE/auth impersonation, the Dexcom app owns the session,
  DiaBLE-corroborated — pre-empts "is this supportable."

## 6. What's deliberately OUT — the scope evaluation

| Work | Verdict | Reason |
|---|---|---|
| Patches 01/03/07/08/14 (NS settings, treatments UI, chart fix, patch metadata, Live Activity TT) | exclude | personal/unrelated; 07 and 14 could be their own tiny PRs someday |
| Patch 05/06 (watch error reporting, cloud logging) | exclude | private telemetry transport; the feature degrades to `os.Logger` cleanly |
| Patch 09 beyond the reduced store | exclude | ComplicationLogBuffer, resident telemetry, debug view = fork observability |
| Patch 10 (WCSession crash guard) | **separate PR, land FIRST** | standalone phone-side stability fix; landing it first shrinks the watch PR's `AppleWatchManager` diff |
| Patch 11 (old monolithic G7DirectBLEManager) | exclude | superseded by patch 12's observer synthesis |
| Watch-side alerting, window-anchored scanning, messaging centralization | exclude | future initiatives; not part of this feature (see `03-watch-feature-ideas.md`) |

## 7. Dependencies that must ship with the PR

1. **Complication snapshot store** (inline reduced patch 09) — biggest untangling decision.
2. **Phone→watch sensor-identity relay** (from patch 13) — self-contained but lands in
   patch-05/06/09/10-modified files, so the diff must be regenerated against upstream baselines.
3. **WatchState connectivity-task completion semantics** (Fix A from complication-freshness + the
   watch-launch-stability commit series) — a **non-regression invariant**; whatever `WatchState`
   ships must preserve it.
4. **App Group container config** (TRIO_APP_GROUP_ID) — verify upstream's xcconfig/entitlements
   support the shared store rather than porting fork fixes blindly.

## 8. The unvalidated-memory risk (must disclose or mitigate)

Every fork validation (builds 179–208) ran on top of the `watch-launch-stability` memory
mitigations (lazy chart construction B3, trimmed WC logging B1, bounded HealthKit bootstrap B4).
The observer adds CoreBluetooth + `WKExtendedRuntimeSession` resident footprint to a watch
extension that **was previously jetsamming at launch**. A PR rebased onto vanilla upstream has an
**unvalidated memory profile**. Options: (a) include the relevant load-shedding pieces in the PR,
or (b) budget explicit on-device jetsam revalidation before claiming "stable." Do not ship the
claim without one of these.

## 9. Recommended landing sequence

1. G7SensorKit PR-A (watchOS support) merged upstream → submodule can point at LoopKit.
2. **Optionally** land `watch-session-crash-guard` (patch 10) as its own tiny upstream PR first —
   shrinks the watch PR's `AppleWatchManager` diff.
3. Build the minimal-core branch off upstream `dev`: cherry-pick + strip per the cut line, inline
   the 09/13 dependencies, regenerate against upstream baselines.
4. **Fix `sanitizedGlucose` mmol/comma corruption in the PR branch (review 1.10)** — comma-locale
   mmol renders "5,6" as **"56"** and dot-locale "5.6" as "6"
   (`TrioComplicationDataStore.swift:78-94`). Latent on the author's mg/dL device but live display
   corruption for mmol users — a large share of upstream's audience. Ship with unit tests for
   both locales; an upstream reviewer finding this first would undercut the reliability story.
5. On-device memory revalidation (jetsam) on the rebased branch.
6. Open as **draft** with the design docs linked; lead with the SLO framing and the observer-only
   posture.

## 10. Open questions for Charlie

- Memory risk: include load-shedding pieces, or commit to a revalidation pass? (changes PR size)
- `g7Sequence` cross-channel attribution: keep it (needs the G7SensorKit reading-timestamp API
  upstreamed) or drop it (smaller dependency, lose same-reading dedup across BLE/WC/HK)?
- Land `watch-session-crash-guard` as a separate pre-PR, yes/no?
- Is the debug status row worth keeping (one line) or strip the debug surface entirely?

---

## Changelog

### v0.3 (2026-06-12 18:34 CEST)
- Landing sequence: added step 4 — fix the `sanitizedGlucose` mmol/comma corruption (review
  1.10) in the PR branch with dual-locale unit tests, before the draft opens.

### v0.2 (2026-06-11 07:51 CEST)
- Consolidated the separate pitch doc (`02-trio-watch-pitch.md`, deleted) into this plan: the
  pitch/safety-ethics/reliability/maturity framing now leads (§1), execution detail follows.
  Completed the previously-truncated exclusion table (§6). Restored full timestamps (the prior
  drafts mislabeled CEST as CET).

### v0.1 (2026-06-11 06:00 CEST)
- Initial drafts (two files): hard G7SensorKit prerequisite, minimal-core cut (keep/strip/inline,
  ~2,300–2,600 lines), reviewer-fear framing, must-ship dependencies, unvalidated-memory
  disclosure, landing sequence.
