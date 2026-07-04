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
