# Build 219 Watch EGV — Implementation Plan

**Version:** v0.1 (2026-07-12 — DRAFT for review: soak readout + Gate-0 matrix + scope framing only; candidate ideation deferred to the next gated node)
**Status:** Draft — for review
**Predecessor:** build 218 (`0.8.4 (218)`, deployed TestFlight 2026-07-08; 94 h soak). 218 batched **S-0** (CRITICAL fork safety fix) + **E-1…E-6** (UI polish) onto all of 217. Build 217 (`0.8.4.x`, 26 h) shipped the EGV-capture **Tasks 1–4** + D-7/D-8/V-2b; per `build218-impl-plan.md:5` their pass/fail verdicts needed this ≥2–3 day soak — **so this is where they land.**

**Fusion:** cadence card `TRIO-001` (Trio project, workflow `WF-002` "Build Cadence"). This doc is the narrative source of truth; the gate matrix below is mirrored to the card. Scope of this pass = **Soak Review node output only** (evidence base + Gate 0 + 219 framing). Checkpoint-first Fable-5 ideation and Select are the next gated nodes.

> **Method note.** This soak review was produced by the `WF-001` Soak Review contract: read the predecessor log + BetterStack telemetry, emit a per-task, multi-valued gate matrix. All figures are **n=1, directional** (single device; the soak spanned **two sensors** — DXCMWF then DXCM8a — so RF/proximity is confounded). Verdicts use the gate vocabulary `{go, hold-sequence-later, low-priority, premise-confirmed, re-defer, killed}`.

---

## Evidence base (build 218 soak, BetterStack, 94 h, n=1 device, sensors DXCMWF + DXCM8a)

Source `1659391` / `t491594.trio`, `platform=watchos`, `category=WatchTelemetryRing`, S3 cluster.

- **Logging health: clean.** `logs_dropped_total`, `ring_dropped_total`, `daily_write_failures_total` all **0** for 216/217/218 → counts are directional-accurate, **not** lower bounds.
- **Builds in window:** 218 (94 h, 33 109 events), 217 (26 h, 10 092), 216 (70 h, 34 231).
- **EGV yield (g7_ble module):**
  | Metric | 216 | 217 | **218** |
  |---|---|---|---|
  | Session-active yield | 217/231 = 93.9% | 56/62 = 90.3% | **287/303 = 94.7%** |
  | No-session yield | 549/1053 = **52.1%** | 68/246 = 27.6% | **234/793 = 29.5%** |
  | Session coverage | 231/1284 = 18.0% | 62/308 = 20.1% | **303/1096 = 27.6%** |
  | Overall g7_ble yield | 766/1284 = 59.7% | 124/308 = 40.3% | **521/1096 = 47.5%** |
- **Overall capture:** 1065 `egv_received` / 94 h = **11.3/h** (≈ ideal 12/h when worn; overnight gaps pull the mean down).
- **Funnel / errors (218):** `connect_timeout` 1482 (15.8/h); `phantom_disconnect` 1236; `pre_egv_disconnect` 572 (ratio 0.54/egv, healthy); `command_timeout` 215 (**71% `peripheral_state=.connected`** starved-CPU: discover_services 63%, set_notify_authentication 88%); `auth_notify_failed` 74 (6.7/100 conn, ok); `sensor_error` 86 (7.8/100, ok); `direct_ble_stall_detected` 58 (0.62/h, ok); `central_reinit` 14 (all `reason=dexcom_side_episode`); `backfill_finished` 385 / `backfill_entry` 330 (active).
- **Deep gaps (218 hourly):** ~8 h zero-EGV overnight 07-10 23:00→07-11 07:00 (connects + connect_called near-0, heartbeats fading) and ~7 h 07-11 21:00→07-12 04:00. Signature = not-worn / OS-suspended / `dexcom_side` — the known, non-app-fixable class.

---

## Gate 0 — Build-218 soak readout (RECORDED 2026-07-12; 94 h, n=1, DXCMWF/DXCM8a; directional)

Per-task gate matrix for everything shipped in 217–218. Verdict ∈ `{go, hold-sequence-later, low-priority, premise-confirmed, re-defer, killed}`.

| # | Task (shipped) | Signal that decides it | Measured (218 soak) | Verdict |
|---|---|---|---|---|
| **S-0** | CRITICAL: gate Task-2/4 escalation/re-init OFF the iPhone primary path (fork fix, patch 02) | iOS occurrences of `central_reinit` / `connect_wedge_persistent` on `platform=ios, category=Service` | **217: `central_reinit`=2, `connect_wedge_persistent`=2 on iOS** (the blackout mechanism). **218: ZERO on iOS**; `central_reinit` fires **watchos-only** (14). | **go — VERIFIED FIXED.** The CGM-blackout path is closed across a 94 h soak. Headline result; unblocks committing 217+218's patches. |
| **1** | W-1 stage 2 — GATT command-timeout raise 2 s→6 s, gated on `peripheral_state=connected`/backgrounded | `command_timeout` share in `.connected` (state=2, starved-CPU) vs dead-link; per-100-connect rate trend | **71% `.connected`** (153/215) — premise strongly holds (≥30% bar). Rate **19.6/100 conn** vs 217's 22.7 — modest drop, **not eliminated**. | **premise-confirmed.** Starved-CPU hypothesis validated; the raise buys alive-but-slow connections time but timeouts persist. Keep; a further lever is warranted (see 219 framing). |
| **2** | W-4 — persistent-wedge connect recovery | `connect_timeout` age-tail / churn; `phantom_disconnect` baseline; EGV-yield lift | Wedges still churn: `connect_timeout` 15.8/h (217: 18.8/h, slight ↓); `phantom_disconnect` 1236. No clean EGV-yield lift visible, and **2-sensor confound**. | **re-defer.** Recovery machinery fires but no attributable capture win on a sensor-unstable window; carry to the next single-sensor soak. |
| **4** | Task C — central re-init on classified `dexcom_side` episodes | `central_reinit` firing; whether classified episodes convert to EGVs | Fired **14× (`dexcom_side_episode`)**, watchos-only. Overnight deep gaps persist; re-init recovers **visibility, not readings** (as predicted — `dexcom_side` is sensor-side). | **low-priority.** Works as designed; capped EGV upside (visibility/safety, not capture). Keep behind its kill-switch; not a 219 capture lever. |
| **3** | W-3 — backfill capture | `backfill_finished` / `background_gatt_skipped` volume | `backfill_finished` 385, `backfill_entry` 330 (active; contributes to the 11.3/h). | **low-priority.** Working, modest steady contribution — matches 217 G5 ("modest upside, keep, low priority"). |
| **D** | 217 D-7/D-8/V-2b diagnostics revamp + kill-switches + ring/sparkline (display) | Infra exercised; no capture regression | `kill_switch_toggled` observed (217: 12) — kill-switches shipped & exercised; session-active yield healthy 94.7% (no regression). | **go.** Landed, functioning, no capture regression. |
| **E** | 218 E-1…E-6 UI polish (display-layer, EGV-path-disjoint) | Capture regression check | Session-active yield 94.7%, capture 11.3/h — no regression. | **go.** Landed, no capture regression. |

**Attribution caveat:** 217 co-shipped Tasks 1–4 (2+4 share the connect/recovery machinery); the per-episode Task-D markers and independent `@AppStorage` kill-switches are what keep mechanism-level attribution alive within the build. Combined with the 2-sensor soak, Tasks 2/4 verdicts are deliberately hedged (`re-defer`/`low-priority`) rather than forced to GO/NO-GO.

---

## Scope of 219 (framing — candidates NOT yet selected)

Ideation (checkpoint-first Fable-5) is the **next** gated node; this section only frames where the evidence points, so the human can steer the checkpoint. **Do not treat these as selected tasks.**

1. **S-0 is verified → commit the 217+218 patch bundle.** With the blackout path closed on a 94 h soak, the milestone commit for patches 02 + 09 (uncommitted on `dev` pending verify-live) is now unblocked — a human action, not a 219 code task.
2. **Primary investigation — the no-session yield drop (52%→~29%).** This is the biggest new signal, but it is **confounded by two sensor changes** (DXCMWF/DXCM8a) and RF. Per the intervention-index discipline (re-derive from classified episodes; check the confound before building), 219's first move is a **clean single-sensor re-read**, not a code change. Only if the drop survives sensor-stable data does it become a candidate.
3. **Starved-CPU command-timeout tail (71% `.connected`).** W-1 stage 2 confirmed the mechanism but didn't clear it. A candidate lever is a CPU-starvation-aware strategy (further timeout shaping or deferring non-critical GATT under starvation) — but check `egv-intervention-index.md` Rejected/Prohibited first (naive blocking timeouts are an anti-pattern).
4. **Do-not-chase:** overnight deep gaps (not-worn / OS-suspended / `dexcom_side`) remain non-app-fixable; the Apple bg-central entitlement is still blocked. Ideation must not re-tread these (`egv-intervention-index.md` graveyard).

**Explicitly out of scope for 219 until ideation:** any Task-2/4 change (re-deferred), any new background-wake mechanism (ruled out), any backfill range-request (protocol-impossible).

---

## Risks and open items

- **n=1 / 2-sensor soak.** Every yield figure is directional; the no-session-yield regression may be sensor/RF, not code. Resolve before acting.
- **Tasks 2/4 carry an unresolved verdict** (`re-defer`/`low-priority`) — they must be re-read on the next single-sensor soak, not silently dropped.
- **Patch-commit hygiene:** patches 02 + 09 stay uncommitted on `dev` until the human runs build+deploy+verify-live; S-0 verification does not authorize an agent to commit.

---

## Implementation log

_(empty — populated by the executor when 219 candidate tasks are selected and implemented via the Trio Feature (`WF-001`) pipeline.)_

---

## Changelog

### v0.1 (2026-07-12)
- Initial draft: build-218 soak readout (94 h, n=1, DXCMWF/DXCM8a) + Gate-0 per-task gate matrix (S-0 verified fixed; Tasks 1/3/4 resolved; Task 2 re-deferred; D/E landed) + 219 scope framing. Produced via the Build Cadence (`WF-002`) Soak Review contract; mirrored to cadence card `TRIO-001` (Trio project). Candidate ideation deferred to the next gated node.
