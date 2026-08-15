# Watch G7 Direct-BLE — Build 216 Impl Log

**Plan:** `build216-impl-plan.md` v0.5 (manifest section)
**Branches:** `feature/watch-g7` (Trio) / `main` (G7SensorKit fork) / `dev` (Trio-dev patches)
**Shipped:** 2026-07-04 — build **216** (`0.8.4`) built + deployed to TestFlight (`trio-v0.8.4-216-localCI`, 13m01s)
**Status:** ✅ Milestone complete — implementation, upstream reconciliation, build, deploy done; soak verification open

---

## What shipped (per the plan's Build 216 manifest)

Instrumentation (additive): Task A (RSSI: `did_discover`, `rssi_read`, `last_rssi`/`rssi_age_s` stamps), Task B + W-7a (heartbeat BLE diagnostics via `G7BLEDiagnosticsSnapshot` + `connecting_ticks`), Task D (`cold_launch`, debug-screen `manual_recovery_marker` button), W-6 (`phantom_disconnect` split), W-1 stage 1 (`command_timeout` state stamps).

The one behavioral change: **W-7** — arm-on-adopt for CB-restored `.connecting` attempts + a discovery-connect watchdog (closes C-212-1 accepted limitation E). Task C's central re-init deferred to 217, gated on W-7's soak.

## Commits

| Repo | SHA | Content | Author path |
|------|-----|---------|-------------|
| Trio (`feature/watch-g7`) | `56814e6` | adapter instrumentation (heartbeat diag, W-6, Task D) | Sonnet subagent, Fable-reviewed |
| G7SensorKit (`main`) | `738a35e` | fork instrumentation (RSSI, `command_timeout` state, snapshot) | Sonnet subagent, Fable-reviewed |
| G7SensorKit (`main`) | `e2d23ca` | **C-216-W7** watchdog blind-spot fix | Fable + second-model review (findings triaged, none real) |
| G7SensorKit (`main`) | `a0e4a54` | merge upstream `0c87905` (48h-lifetime UI, translations) — **the shipped pin** | — |

## Patches (in the 216 stack; uncommitted on dev pending soak)

- **02** — pin `a0e4a54f…`, base gitlink `0c87905…` (upstream 0.8.4 pointer).
- **09** — regenerated with full provenance (8 build-215 commits + `56814e6`); 29 files, no drift.
- **13** — reconciled vs upstream `8fc5e86` ("Remove core data fetch limits"): dropped the patch's `fetchLimit` hunk (2h predicate already bounds the fetch to ~24 rows). Content delta verified to be exactly that hunk; deletion-footprint audit + `DeviceDataManager` sentinel PASSED (this is the clobber-history patch — full-diff review done).

## Upstream-sync reconciliation (0.8.3.x → 0.8.4)

1. First build attempt failed at patch apply: upstream moved the G7SensorKit submodule pointer (`4d0780d → 0c87905`), making patch 02's gitlink **base** side stale (submodule hunks can't 3-way).
2. dev merged with `origin/dev` (had diverged after the script's upstream merge + rejected push) and pushed.
3. Fork merged upstream G7SensorKit `0c87905` (only `G7SensorKitUI` changes — no core-BLE overlap) → `a0e4a54`, pushed.
4. **`repin-g7.sh` extended** (this session): it now re-derives the base gitlink from `dev:G7SensorKit` and rewrites the `-Subproject commit` line + index before-abbrev when dev's pointer has moved. Previously it rewrote only the new-pin side — the root cause of failure #1.
5. Patch 13 reconciled (above); `patch-test.sh` PASSED end-to-end; build #2 succeeded.

## Post-deploy soak signals (build 216)

Query with `build='216'`, `platform='watchos'`. Baselines: build-215 full-soak numbers in the plan's "Fresh evidence" table.

| Signal | What to look for |
|--------|------------------|
| `connect_watchdog_adopted` (`scope=bound|discovery`) | Fires on relaunch-restored wedges — each one is a formerly-invisible 06-30-class wedge now under watch |
| `discovery_connect_timeout` / `_rescan` | The limitation-E hole exercising; rescans should be followed by `did_discover` within the next windows |
| heartbeat `active_peripheral_state=1` + `connect_pending_age_s=-1` | Should now be transient (adopted within one heartbeat), not multi-hour; `connecting_ticks` sizes residuals |
| `phantom_disconnect` vs `pre_egv_disconnect` | Expect ~⅔ of old pre_egv volume to move to phantom; true pre-EGV baseline ≈ 515/182h |
| `command_timeout peripheral_state=` | Splits dead-link vs starved-CPU → decides W-1 stage 2 (2s→6s raise) for 217 |
| `did_discover rssi=` / `rssi_read` / `last_rssi` stamps | Task A distributions: healthy vs stall windows |
| Deep-gap hours (awake, `connect_called=0`) | Baseline 13/172h → should shrink; episodes recovering **without** `will_restore_state` is W-7's pass criterion |
| `cold_launch` / `manual_recovery_marker` | Recovery-cause attribution (Task D) |

**Deferred to 217 (per manifest):** W-4 escalation, W-1 stage 2, W-3 gap-conditional backfill, W-5 auto-reconnect, Task C central re-init (only if W-7 soak shows unrecovered classified episodes).

---

## Build 216 soak validation (2026-07-06 — 44 h, n=1, sensor DXCMyu)

Directional only (44 h vs 215's 146 h; single wrist). Full Gate-0 readout recorded in `build217-impl-plan.md`. **Verdict: shipped clean — all instrumentation live and correct, W-7 behaves exactly as designed, no regressions.**

**Instrumentation — all emitting, all valid.** `phantom_disconnect` 346, `rssi_read` 286 (field is `value=`, populated, `error=nil`), `did_discover rssi=` 29, `connect_watchdog_adopted` 9, `discovery_connect_timeout(_rescan)` 5+25, `cold_launch` 7, `command_timeout peripheral_state=` 53. Nothing dark.

**W-7 — firing exactly on target.** All 9 `connect_watchdog_adopted` are `scope=bound`, `seq=4` (immediately post-relaunch) on the restored `F42CA099` `.connecting` peripheral — the precise 06-30-class wedge that was invisible pre-216, now watched. Discovery watchdog (old C-212-1 limitation E) firing: 5 timeouts + 25 rescans. **Deep-gap hours: 4.8% of awake hours (1/21) vs 13.1% (13/99) in 215** — down ~63%. Stalls 0.89/h vs 1.40/h; EGV 10.0/h vs 7.7/h (both confounded by coverage/usage — not attributed to W-7).

**W-6 — validated Fable's E2.** `phantom_disconnect` 346 vs true `pre_egv_disconnect` 99 → **78% phantom** (Fable estimated ~67%). The "drops within seconds" metric was mostly watchdog-cancel noise.

**W-1 stage-1 discriminator — decision delivered → W-1 stage 2 is GO for 217.** `command_timeout` by `peripheral_state`: **31/53 (58%) fire while `peripheral_state=2` (`.connected`)** — live link, late GATT callback (starved CPU). `discover_services` 15/22 connected; `set_notify_authentication` 16/25 connected. The other ~42% (states 1/0) are dead-link timeouts a longer wait won't help → the 2 s→6 s raise must be gated, as planned.

**Task A RSSI — works, and yields a real correlation.** Connected-link RSSI is typically **weak (−85 to −94 dBm; 65% of sessions)**. Per-`g7_session` yield by RSSI band is **monotonic**: ≥−75 → 93% EGV, −75..−85 → 83%, −85..−92 → 77%, <−92 → 72%. So stronger signal → higher yield, but the effect is **modest** (even −94 dBm yields 72%). Caveat: RSSI is proximity/antenna **physics, not a code lever**, confounded with scene_phase — a real slice of residual loss is physical range, not a bug.

**Discovery-rescan: converts, but doesn't recover (in-episode).** Tracing the 07-04 15:40→17:50 bad episode: each `discovery_connect_timeout_rescan` **does** produce a fresh `did_discover`→`connect` (mechanism works — no longer silent). But the resulting connects didn't yield EGVs — `F42CA099` discovery-connects re-wedge (301/785/335 s) and others (F93612D0, CBE5564D) drop in ~22 s pre-EGV. **W-7 recovered visibility, not readings, in that episode** → keeps W-4 (escalation) and Task C (re-init) alive for 217.

**New finding — foreign-device discovery churn (rotation conclusively buried; = Task 7, resolved).** My first read of this ("DXCMyu under 6 UUIDs / elevates rotation") was **wrong** — the `sensor_name=DXCMyu` on `did_discover` records is a **context stamp** (the sensor the watch is looking for), not the discovered device's name. Verified via `did_discover` (each carries `bound=false` + its own `rssi`) and a per-UUID progression count: **only `F42CA099` ever auth-bonds** (331 `did_connect` / **232 `auth_authenticated_bonded`**); every other UUID (F93612D0, 2AF299DA, 669B06A9, 8001C582, CBE5564D, 8C843588, 4D8CF8BE, 360BC9F5) has **0 auth-bond / 0 EGV** and connects only 2–3× before being dropped. Those are **other Dexcom devices in RF range** (household/neighbor sensors, or a stray expired sensor still advertising) that the service-UUID scan picks up, tries, and rejects. They appear "concurrently" because they are genuinely different devices broadcasting at once. **So the sensor has ONE stable identity (`F42CA099`) — no rotation.** Residual: discovery mode wastes a few connects on foreign advertisers (minor churn, not a gap cause). The `peripheral=` UUIDs are real CBPeripheral identifiers (not `g7_session` connection codes, which are the separate short-hex field, `nil` here).

**Watch items (not failures).** Watch drained to **5% overnight (07-05)**; relaunches ran **0.82/h vs 0.42/h** in 215 — could be W-7's extra rescans or usage; monitor that 216 isn't trading recovery for battery. Small sample (1 deep-gap hour, 9 adoptions) — needs a fuller soak before calling W-7 a win.
