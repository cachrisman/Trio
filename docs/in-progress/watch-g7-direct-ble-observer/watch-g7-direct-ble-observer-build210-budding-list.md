# Build 210 — budding list

**Status:** Budding — items accumulate during the build-209 soak; NOT a committed plan yet.
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

### D210-4. Connect-gate delegate (reconnect-storm throttle)  (= 209 plan A5)
Un-shelve and build the connect-gate (review 2.2): throttle rapid reconnects (the soak saw up to 16
`did_connect` in a 5-min window). New behavior, deferred from 209.

### D210-5. Dexcom-session-dependency instrumentation  (= 209 plan A6)
Instrument detection of when the **Dexcom watch app** loses its direct-to-sensor session (the real
cause of the 06-13 full-day outage) — Trio is the observer, so it infers this from the absence of
connection-event windows while the phone path stays fresh. Pairs with D210-2.

### D210-6. Restore the C-209-5 ComplicationLogBuffer hunk
The `battery_src=` tag + 15s TTL on the complication-log path was dropped to ship 209 cleanly
(archived at `C-209-5-CLB-hunk-to-restore.patch`). **This is owned by the dev-sync Track's 09+12
merge**, not 210 directly — listed here only so it isn't forgotten if the merge slips.

## Changelog
### 2026-06-15
- Created. Seeded D210-1 (capture-rate main display, Charlie) + D210-2..6 carried from the 209 plan.
