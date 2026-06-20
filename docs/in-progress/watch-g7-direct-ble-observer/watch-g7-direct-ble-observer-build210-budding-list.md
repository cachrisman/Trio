# Build 210 — budding list

**Status:** SUPERSEDED 2026-06-16 → scope locked into
[watch-g7-direct-ble-observer-build210-impl-plan.md](watch-g7-direct-ble-observer-build210-impl-plan.md)
(D210-1..5,7,8 → C-210-1..10). Kept for provenance.
**Created:** 2026-06-15

Collects candidate items for build 210. Scope gets locked after the 209 soak read (and after Charlie
decides what else he wants in). Several items reference detailed write-ups already in the
[build-209 plan](watch-g7-direct-ble-observer-build209-impl-plan.md) Section A.

## Items

### D210-1. Main watch display → show EGV capture success rate (`67 / 248`)
**Source:** Charlie, 2026-06-15.
**Change:** On the main watch glucose view, replace the current metric (EGV readings / connects)
with the **capture success rate** — captures / possible slots since midnight (e.g. `67 / 248`), the
same `bleEGVsToday / denom` the debug panel now shows.
**Why:** C-209-1 made the denominator honest (analytical elapsed-slots − ineligible − gated, immune
to background suspension). The captures/slots ratio is the true background capture-success rate;
readings/connects doesn't surface *missed* slots, so it can look fine during an outage. Putting the
honest ratio on the main face makes a dormancy visible at a glance.
**Notes:** Verify the exact current field/label in `TrioMainWatchView` during implementation. Keep
it glanceable (the design already has a compact source/status line). Consider whether to show it
alongside or instead of the `<source> · BLE:<status> <age>` line.

### D210-2. Direct-BLE-stall detection + indicator + notification  (= 209 plan A7)
Cross-source freshness signal (direct EGV stale + phone EGV fresh → direct-BLE stall), dormant-vs-
starved + Dexcom-vs-Trio classification (via the connection-event/window signal), tiered UI
(`stalled`/`unavailable`), a `direct_ble_stall_detected` telemetry event, and an inferred user
notification with glucose-app alarm-fatigue guards. Full design in 209 plan **A7**.

### D210-3. Stall recovery: connection-event re-kick when bound-but-stalled  (= 209 plan A7)
Extend `G7BluetoothManager.connectionEventDidOccur` to re-kick the attach when **bound AND stalled**
(no recent EGV) so Trio rides a fresh Dexcom window immediately instead of waiting on its own timer.
**Hard-gate** against the A5 reconnect storm (never re-kick when bound-and-healthy). Shared-fork
change (phone impact). Splits by fault: Trio-side stalls self-heal; Dexcom-side stalls can only be
detected + notified (can't restart another app or auth the sensor). Full design in 209 plan **A7**.

**Real-world evidence (build 209, 2026-06-16 16:00 UTC):** the watch recovered from a brief sensor/RF
blip clumsily — a ~10-min storm of connect → `pre_egv_disconnect` → `stale_sensor_binding_suspected`
re-init before re-attaching (full detail under D210-4). A bound-but-stalled re-kick should turn that
thrash into a clean immediate re-attach on the next Dexcom window.

### D210-4. Connect-gate delegate (reconnect-storm throttle)  (= 209 plan A5)
Un-shelve and build the connect-gate (review 2.2): throttle rapid reconnects (the soak saw up to 16
`did_connect` in a 5-min window). New behavior, deferred from 209.

**Real-world evidence (build 209, 2026-06-16 16:00 UTC) — the best case for this yet.** After ~21h of
steady, watchdog-free operation, the watch hit a self-recovering ~10-min reconnect storm:
**20 `did_connect` in a single 5-min window** (vs the all-day ~22/hr baseline), each dropping before
an EGV (`pre_egv_disconnect` ×19), `stale_sensor_binding_suspected` ×15, and **2 `egv_watchdog_fired`
(the first of 209's entire life)**. It recovered on its own by 16:15. Root cause: a brief shared
sensor/RF blip at ~16:00 — **the phone missed only one slot (16:01) and recovered immediately**,
while the watch's observer path amplified it into the storm. So it's watch-side fragility, not
sensor-wide. A connect-gate would have damped the 20-connect thrash cold. (Pairs with D210-3 — the
clumsy recovery is exactly what the re-kick should make graceful.)

### D210-5. Dexcom-session-dependency instrumentation  (= 209 plan A6)
Instrument detection of when the **Dexcom watch app** loses its direct-to-sensor session (the real
cause of the 06-13 full-day outage) — Trio is the observer, so it infers this from the absence of
connection-event windows while the phone path stays fresh. Pairs with D210-2.

### D210-6. Restore the C-209-5 ComplicationLogBuffer hunk
The `battery_src=` tag + 15s TTL on the complication-log path was dropped to ship 209 cleanly
(archived at `C-209-5-CLB-hunk-to-restore.patch`). **This is owned by the dev-sync Track's 09+12
merge**, not 210 directly — listed here only so it isn't forgotten if the merge slips.

### D210-7. Canonical mg/dL + unit-aware complication display  **(P0 — safety)**
**Source:** watch-g7 complication-freshness scan, adversarially verified 2026-06-16. Full writeup:
[`complication-freshness/watch-g7-scan-findings-verified.md`](../complication-freshness/watch-g7-scan-findings-verified.md).
**Bug:** the on-watch BLE and HK producers store the **raw integer mg/dL** as the display string
(`G7WatchSensorAdapter.swift:1174-1184`, `WatchState.swift:783-797`); the widget renders it verbatim
(`TrioWatchComplication.swift:337,403`). The phone WC path converts (`AppleWatchManager.swift:299-304`)
— the asymmetry means **mmol/L users see `100` instead of `5.6` on the face**, on the common path
(BLE wins arbitration). This is live right now.
**Change:** store **canonical `glucoseMgDl: Int`** in the snapshot and format in the widget/view by
unit preference. This single refactor also fixes the BLE delta baseline (D210-8 / scan #2b) and the
mg/dL-threshold color fallback (scan #1b). **Watch out:** `Int(snapshot.glucose)` call sites
(`WatchState.swift:1065,1089`) assume a bare int and must change in lockstep.
**Verified-refuted siblings (do NOT build):** #4 "widget rolls back the watermark" (write isn't
compiled into the widget target), #1a, #5, #7, #8, #9, #10 — see the verified doc.

### D210-8. Completeness-aware arbitration + arm the sequence guard  **(P1)**
**Source:** same scan (verified). **Bug:** `shouldUpdate`'s ±1s window
(`TrioComplicationDataStore.swift:640-673`) skips source-priority whenever trend differs, so a WC
reading with empty `""` trend / `"--"` delta **overwrites a complete BLE reading**. The sequence
guard (`:652`) can't help because the phone **never sends `g7_sequence`** (`Trio/Sources/Models/WatchState.swift:34`
defined, never assigned; absent from the serializers).
**Change:** (a) completeness-aware arbitration — never let empty trend/delta replace a populated
value; score recency → completeness → source. (b) Populate `g7_sequence` on the phone payload to arm
the existing guard cross-channel. (a) is the load-bearing fix; (b) is the enabler.
**Optional fast-follows from the scan:** #3 launch-time reload-generation reconciliation (narrow,
the rest of #3 was overstated); #6 HK same-epoch value-compare (real but ~unreachable for G7 EGVs).

## Changelog
### 2026-06-16
- Folded in D210-7 (canonical mg/dL + unit-aware display, **P0**) and D210-8 (completeness-aware
  arbitration + `g7_sequence`, P1) from the adversarially-verified complication-freshness scan.
  Recorded which sibling findings were *refuted* so they aren't re-litigated.
- Added build-209 real-world evidence under D210-3 / D210-4 (the 2026-06-16 16:00 UTC reconnect
  storm), reconciled from the dev-worktree copy so both edits live in one canonical budding-list.

### 2026-06-15
- Created. Seeded D210-1 (capture-rate main display, Charlie) + D210-2..6 carried from the 209 plan.
