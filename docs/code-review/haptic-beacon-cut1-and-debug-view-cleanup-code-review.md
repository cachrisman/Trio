# HapticBeacon Cut 1 + watch debug-view cleanup — Code review (working tree vs `HEAD`)

**Trio worktree · branch:** `feature/watch-g7-direct-ble-observer-synthesis` · **HEAD:** `e6dd440da`
**Trio-dev worktree · branch:** `dev` · **HEAD:** `0c3bfff17`
**Generated:** 2026-05-11 12:02 CET
**Commands:**
- `git diff -- 'Trio Watch App Extension/G7WatchSensorAdapter.swift' 'Trio Watch App Extension/TrioWatchApp.swift' 'Trio Watch App Extension/Views/ComplicationDebugView.swift' 'Trio Watch App Extension/Views/TrioMainWatchView.swift' 'Trio Watch App Extension/WatchState.swift'`
- `git diff --no-index /dev/null 'Trio Watch App Extension/HapticBeacon.swift'`

**Note (transient):** scratch artifact for reviewers; regenerate after local commits/edits. Authoritative initiative docs:
- [`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`](../in-progress/haptic-beacon/haptic-beacon-impl-plan.md) (HapticBeacon Cut 1 plan, v1.5)
- [`docs/in-progress/haptic-beacon/haptic-beacon-impl-log.md`](../in-progress/haptic-beacon/haptic-beacon-impl-log.md) (Cut 1 implementation log, v1)

**Scope filter:** the working tree on `feature/watch-g7-direct-ble-observer-synthesis` also contains pre-existing uncommitted hunks unrelated to this code review (Bug #5 monotonic write guard in `TrioComplicationDataStore.swift`, Bug #6 background-task complication update in `WatchState.swift`, bounded-retry refactor in `WatchState+Requests.swift`, and a `start()` idempotency improvement in `G7WatchSensorAdapter.swift`). Two files are **excluded entirely** because they have zero in-scope hunks:
- `Trio Watch Shared/TrioComplicationDataStore.swift` (Bug #5)
- `Trio Watch App Extension/WatchState+Requests.swift` (bounded-retry)

For files with mixed hunks (`WatchState.swift`, `G7WatchSensorAdapter.swift`, `ComplicationDebugView.swift`), the per-file bullet summaries below explicitly tag each hunk as **[in scope]** or **[out of scope — pre-existing]**. The unified diff is pasted verbatim per the `code-review-diff-doc.mdc` rule (no diff edits / truncations); reviewers should focus on **[in scope]** hunks for this review.

## Patch (working tree vs `HEAD` `e6dd440da`): debug-view cleanup + HapticBeacon Cut 1

**6 files changed (5 modified + 1 new), +506 / -41**

| File | + / − | Stat source |
|---|---|---|
| `Trio Watch App Extension/HapticBeacon.swift` | +273 / −0 | new file |
| `Trio Watch App Extension/G7WatchSensorAdapter.swift` | +60 / −4 | `git diff --stat` |
| `Trio Watch App Extension/TrioWatchApp.swift` | +1 / −0 | `git diff --stat` |
| `Trio Watch App Extension/Views/ComplicationDebugView.swift` | +103 / −24 | `git diff --stat` |
| `Trio Watch App Extension/Views/TrioMainWatchView.swift` | +0 / −16 | `git diff --stat` |
| `Trio Watch App Extension/WatchState.swift` | +60 / −6 | `git diff --stat` |

### `HapticBeacon.swift` — Cadence-aware haptic beacon (Cut 1, BLE-only foreground)
**[All in scope]** — entirely new file, plan §3.1.

- New `@MainActor final class HapticBeacon` singleton (`shared`), guards a UserDefaults-backed kill switch (`HapticBeacon.isEnabled`, **default OFF / opt-in** per plan §11 Q1).
- Three timer slots on a private `.utility` `DispatchQueue` (`org.nightscout.trio.watch.haptic.timers`), all event handlers hop back to `@MainActor` via `Task { @MainActor in HapticBeacon.shared.<method>() }`:
  - `rampTimer` — one-shot at `receiptDate + (300 − 3)` s.
  - `rampSubTimers: [DispatchSourceTimer]` — three sub-timers at +0/+1/+2 s after `rampTimer` fires; cancellable as a group so kill-switch / fresh-EGV cancellation propagates mid-ramp.
  - `missTimer` — one-shot at `receiptDate + (300 + 20)` s.
- `noteEGVReceived(at:source:)` — single hook the rest of the codebase calls. Cut 1 honors only `source == .g7DirectBLE`; phone/HK silently ignored (parameter exists today so Cut 3 plumbing is one-liner).
- **Adapter-stopped invariant (plan §11 Q3 / Option A):** `isAdapterStopped()` reads `WatchState.shared.g7DirectBleStatus == .off`. Checked at `noteEGVReceived` entry (defense-in-depth) and at every `play(_:)` call. Pending timers cancelled on skip; per-fire skip is silent except for one `haptic_skipped` log line.
- **Stale-anchor guard:** `rearm` skips scheduling if receipt is > 600 s old (`staleThreshold`).
- **Vocabulary reservation (plan §10.1):** beacon owns `.click`, `.start`, `.notification`, `.success`, `.retry`. `.failure`, `.directionUp`, `.directionDown`, `.stop` are reserved for a future clinical alerter and are **not used anywhere in this file**.
- **`play(_:)` is the single delivery choke point** (plan §10.2). Cut 1 routes through `WKInterfaceDevice.current().play(_:)` only; Cut 2 spike will switch this method to prefer `G7WatchSensorAdapter.shared.currentExtendedSession.notifyUser(haptic:)` when available.
- Telemetry via `WatchLogger.shared.log(...)` tagged `module=haptic_beacon`. Events emitted in Cut 1: `start`, `stop`, `setEnabled`, `haptic_armed` (×2 per cycle: `phase=ramp`, `phase=miss`), `haptic_fired`, `haptic_skipped`, `rearm_skipped`.

### `G7WatchSensorAdapter.swift` — accessor + EGV hook + sequence anchor
- **[in scope]** Hunk 1 (line 23+): adds `@MainActor var currentExtendedSession` accessor for `HapticBeacon` (plan §3.2 Change A). Documented that callers must not cache the returned reference (three replacement paths exist: `stop()`, `renewSessionIfNeeded()`, chain inside `extendedRuntimeSessionWillExpire`).
- **[mixed]** Hunk 2 (line 30+): adds two new instance fields. **`hasAnchored`** is part of a pre-existing `start()` idempotency improvement — **out of scope**. **`bleFirstSequenceToday: Int?`** is the G7 sequence anchor for the new "X / Y" denominator on the debug view's Connects/EGVs rows — **in scope**.
- **[in scope]** Hunk 3 (line 82+): adds `Keys.firstSequenceToday` UserDefaults key for `bleFirstSequenceToday` persistence.
- **[out of scope — pre-existing]** Hunk 4 (line 103+): `start()` idempotency docstring.
- **[out of scope — pre-existing]** Hunk 5 (line 114+): `start()` idempotency early-return + `hasAnchored` gate, `stop()` clears `hasAnchored`.
- **[in scope]** Hunk 6 (line 302+): `loadDailyCounters()` clears `bleFirstSequenceToday` on day rollover and loads it from UserDefaults otherwise.
- **[in scope]** Hunk 7 (line 322+): `loadDailyCountersIfNewCalendarDay()` mirrors hunk 6's reset behaviour for the on-demand path.
- **[in scope]** Hunk 8 (line 330+): `mirrorDailyCountersToWatchState()` adds `bleFirstSequenceToday` to the published mirror.
- **[in scope]** Hunk 9 (line 514+): in `sensor(_:didRead glucose:)` — defensive `loadDailyCountersIfNewCalendarDay()` at the top of the EGV path so an EGV arriving the morning after a watch-awake midnight cannot be added to yesterday's bucket; then maintain the `bleFirstSequenceToday` anchor with sensor-swap detection (`glucose.sequence < anchor` → re-anchor).
- **[in scope]** Hunk 10 (line 557+): inside the existing `Task { @MainActor in }`, mirror `currentSequence` to `WatchState.shared.bleLastEGVSequence` and call `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)` (plan §3.2 Change B). Receipt-time anchor (`Date()`), not sensor `readingDate`.

### `TrioWatchApp.swift` — beacon lifecycle wire-up
**[All in scope]** — single line, plan §3.3.

- Added `HapticBeacon.shared.start()` in the `.active` branch of `.onChange(of: scenePhase)` immediately after `WatchState.shared.handleForegroundActiveEntry()`. Idempotent. Plan §3.3 explicitly says **not** to call `stop()` on inactive/background — direct BLE keeps running per existing watch lifecycle policy, so the beacon stays armed.

### `ComplicationDebugView.swift` — debug surface cleanups + HapticBeacon kill switch
- **[mixed]** Hunk 1 (line 17+): three new `@State` / `@Environment` properties. **`scenePhase` + `isActive`** are pre-existing 1Hz-task suspension to suppress per-second log-store reads while the watch app is not in `.active` — **out of scope**. **`hapticBeaconEnabled`** is the local mirror for the new toggle button — **in scope**.
- **[in scope]** Hunk 2 (line 55+): `G7DirectBleDebugSection(now: now)` — threads parent's 1 s tick through so the new "Next connect" countdown row re-renders even when underlying state is unchanged.
- **[mixed]** Hunk 3 (line 70+): `.onAppear` adds `hapticBeaconEnabled = HapticBeacon.shared.isEnabled` (in scope); `.onChange(of: scenePhase)` mirror block + `.task` doc expansion + `guard isActive else { continue }` are all part of the pre-existing 1 Hz-task suspension (out of scope).
- **[in scope]** Hunk 4 (line 100+): glucose / trend / delta header — `.title3` → `.title`, plus `lineLimit(1)`, `minimumScaleFactor(0.6)`, `frame(maxWidth: .infinity, alignment: .center)`, `padding(.vertical, 2)`. Per user request to make the BG / trend / delta line take ~75% of view width and center-align.
- **[in scope]** Hunk 5 (line 113+): "Reading:" row — collapse `VStack` containing `formatTime` + `(Ns ago)` into a single `Text(formatTime(...))` keeping the `ageColor` foreground colour (which already conveys staleness).
- **[in scope]** Hunk 6 (line 151+): "Last reload:" row — drop the `(Ns ago)` suffix for consistency with the Reading row change.
- **[in scope]** Hunk 7 (line 345+): new "Haptic Beacon: ON / OFF" `Button` in the ACTIONS section after Flush Logs. `.bordered` style, `.tint(.pink)`, `bell.fill` / `bell.slash` SF Symbol, fires `triggerConfirmation(message:)` toast on tap (matches existing button pattern verified at `Trio Watch App Extension/Views/ComplicationDebugView.swift:427`).
- **[in scope]** Hunk 8 (line 409+): remove `formatAge(_:relativeTo:)` private helper — orphaned after hunks 5 & 6 dropped both call sites.
- **[in scope]** Hunk 9 (line 466+): `G7DirectBleDebugSection` additions — accept `now: Date` parameter, expose `expectedCadence = 300`, add "Next connect:" row (`nextConnectCountdown(_:)` mirrors `nextReadingCountdown` semantics: `Ns` future / `⚠️+Ns` overdue / `--` no data), switch Connects/EGVs rows to `countWithDenominator(_:)` ("X / Y" sequence-anchored ratio with a 288/day sanity cap, falls back to "X" when anchor or last sequence is unknown / invalid), rename "Phone sensor filter:" → "Phone sensor:", `.monospacedDigit()` on the new numeric rows.

### `TrioMainWatchView.swift` — remove duplicate clock overlay
**[All in scope]** — single hunk, single deletion.

- Remove the 16-line `.overlay(alignment: .top) { TimelineView(.periodic …) }` block that was rendering a second app-rendered clock at the top of the `TabView`. WatchOS does not expose any public API to modify the system clock in the upper-right of the watch face; the in-app overlay only added a *second* clock rather than augmenting the system one. User explicitly requested removal.

### `WatchState.swift` — BLE sequence mirror fields
- **[in scope]** Hunk 1 (line 111+): adds `var bleLastEGVSequence: Int?` and `var bleFirstSequenceToday: Int?` to the `WatchState` published surface. Both mirror values written by `G7WatchSensorAdapter.mirrorDailyCountersToWatchState()` and the EGV-receive task; consumed by `ComplicationDebugView.G7DirectBleDebugSection.countWithDenominator(_:)`.
- **[out of scope — pre-existing]** Hunk 2 (line 218+): adds `pendingBgTaskComplicationUpdateAt` + `bgTaskComplicationUpdateWindow` (Bug #6 background-task complication update conditional refresh).
- **[out of scope — pre-existing]** Hunk 3 (line 1808+): `finalizePendingData` doc + flag-consume block (Bug #6).
- **[out of scope — pre-existing]** Hunk 4 (line 2219+): `wakeup` handler defers `forceComplicationUpdate()` to the data-application success path + stale-flag detector (Bug #6).

```diff
diff --git a/Trio Watch App Extension/G7WatchSensorAdapter.swift b/Trio Watch App Extension/G7WatchSensorAdapter.swift
index 7f9cd6500..65662b2fc 100644
--- a/Trio Watch App Extension/G7WatchSensorAdapter.swift	
+++ b/Trio Watch App Extension/G7WatchSensorAdapter.swift	
@@ -23,6 +23,12 @@ final class G7WatchSensorAdapter: NSObject {
     @MainActor private var extendedSession: WKExtendedRuntimeSession?
     @MainActor private var pendingChainSession: WKExtendedRuntimeSession?
 
+    /// Read-only accessor for `HapticBeacon` (Cut 2 spike). Three replacement paths exist for
+    /// `extendedSession` (`stop()`, `renewSessionIfNeeded()`, chain inside
+    /// `extendedRuntimeSessionWillExpire`), so callers must re-query on every use — never
+    /// cache the returned reference.
+    @MainActor var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }
+
     private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.g7WatchAdapter.timers", qos: .utility)
     private var heartbeatTimer: DispatchSourceTimer?
     private var expectedWindowTimer: DispatchSourceTimer?
@@ -30,8 +36,16 @@ final class G7WatchSensorAdapter: NSObject {
 
     private var isStopped = false
     private var recoveryScheduled = false
+    /// `start()` idempotency flag. Gates the retroactive `expected_window` tick replay
+    /// in `reanchorExpectedWindowTimer(coldStart: true)` so it runs **once** per process /
+    /// stop-recovery cycle, not on every foreground active entry. Reset to `false` in `stop()`.
+    private var hasAnchored = false
     private var bleConnectsToday: Int = 0
     private var bleEGVsToday: Int = 0
+    /// G7 sequence of the first EGV observed today; nil until the first EGV of the calendar day.
+    /// Used to derive `expected readings since first observed today` as the denominator for the
+    /// `Connects:` / `EGVs:` debug rows. Reset on day rollover and on sensor swap (sequence regression).
+    private var bleFirstSequenceToday: Int?
     private var sessionConnectAt: Date?
 
     /// BLE delegate vs lifecycle / ExtensionDelegate — protect with one lock (avoid `nonisolated(unsafe)` drift).
@@ -82,6 +96,7 @@ final class G7WatchSensorAdapter: NSObject {
         static let calendarDay = "G7DirectBLEObserver.bleCountersCalendarDay"
         static let connects = "G7DirectBLEObserver.bleConnectsToday"
         static let egvs = "G7DirectBLEObserver.bleEGVsToday"
+        static let firstSequenceToday = "G7WatchAdapter.bleFirstSequenceToday"
     }
 
     private enum AdapterSessionPhase: String {
@@ -103,6 +118,14 @@ final class G7WatchSensorAdapter: NSObject {
         loadDailyCounters()
     }
 
+    /// Begin (or no-op resume) the G7 BLE pipeline.
+    ///
+    /// **Idempotency invariant:** when the sensor is already connected and we are not stopped,
+    /// `start()` returns early without re-scanning, replaying retroactive `expected_window`
+    /// ticks, or rebinding the sensor. This prevents single-cycle scene-phase flicker
+    /// (active→inactive→active) from producing redundant `resumeScanning()` calls and tick
+    /// log floods. The retroactive replay is further gated by `hasAnchored` so it runs only
+    /// once per process / stop-recovery cycle.
     func start() {
         stopTimers()
         isStopped = false
@@ -114,22 +137,34 @@ final class G7WatchSensorAdapter: NSObject {
             log("start_skipped_no_sensor")
             return
         }
+        if !isStopped && sensor.isConnected {
+            publishConnectionStatus()
+            return
+        }
         if currentSensorName != name {
             sensor.stopScanning()
             sensor = G7Sensor(sensorID: name)
             sensor.delegate = self
             currentSensorName = name
         }
-        if let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int {
+        if !hasAnchored, let epoch = UserDefaults.standard.object(forKey: Keys.lastEGVEpoch) as? Int {
             reanchorExpectedWindowTimer(fromEpoch: epoch, coldStart: true)
+            hasAnchored = true
         }
         sensor.resumeScanning()
         publishConnectionStatus()
     }
 
+    /// Tear down the G7 BLE pipeline.
+    ///
+    /// **Invariant:** clearing `hasAnchored` here ensures the next `start()` after a real stop
+    /// re-runs the retroactive `expected_window` tick replay (e.g., post-recovery from an
+    /// extended-runtime invalidation error). Foreground re-entries that did **not** go through
+    /// `stop()` continue to skip the replay.
     func stop() {
         isStopped = true
         lastKnownExtSessionActive = false
+        hasAnchored = false
         Task { @MainActor in
             extendedSession?.invalidate()
             pendingChainSession?.invalidate()
@@ -302,11 +337,14 @@ final class G7WatchSensorAdapter: NSObject {
         if storedDay != dayStart {
             bleConnectsToday = 0
             bleEGVsToday = 0
+            bleFirstSequenceToday = nil
             UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
+            UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
             persistDailyCounters()
         } else {
             bleConnectsToday = UserDefaults.standard.integer(forKey: Keys.connects)
             bleEGVsToday = UserDefaults.standard.integer(forKey: Keys.egvs)
+            bleFirstSequenceToday = UserDefaults.standard.object(forKey: Keys.firstSequenceToday) as? Int
         }
         mirrorDailyCountersToWatchState()
     }
@@ -322,7 +360,9 @@ final class G7WatchSensorAdapter: NSObject {
         guard storedDay != dayStart else { return }
         bleConnectsToday = 0
         bleEGVsToday = 0
+        bleFirstSequenceToday = nil
         UserDefaults.standard.set(dayStart, forKey: Keys.calendarDay)
+        UserDefaults.standard.removeObject(forKey: Keys.firstSequenceToday)
         persistDailyCounters()
         mirrorDailyCountersToWatchState()
     }
@@ -330,9 +370,11 @@ final class G7WatchSensorAdapter: NSObject {
     private func mirrorDailyCountersToWatchState() {
         let connects = bleConnectsToday
         let egvs = bleEGVsToday
+        let firstSeq = bleFirstSequenceToday
         Task { @MainActor in
             WatchState.shared.bleConnectsToday = connects
             WatchState.shared.bleEGVsToday = egvs
+            WatchState.shared.bleFirstSequenceToday = firstSeq
         }
     }
 
@@ -514,8 +556,26 @@ extension G7WatchSensorAdapter: G7SensorDelegate {
         UserDefaults.standard.set(readingEpoch, forKey: Keys.lastEGVEpoch)
         reanchorExpectedWindowTimer(fromEpoch: readingEpoch, coldStart: false)
 
+        // Detect midnight rollover before mutating any daily counters — otherwise an EGV that
+        // arrives the morning after a watch-awake midnight would be added to yesterday's bucket
+        // (and would inherit yesterday's `bleFirstSequenceToday`, producing a bogus denominator).
+        loadDailyCountersIfNewCalendarDay()
+
         // Task B2 — mirrors `G7DirectBLEObserver.parseGlucose`: reliable + dedup + valid glucose bytes, then EGV counter.
         bleEGVsToday += 1
+        // Maintain `expected readings since first observed today` anchor.
+        // `bleFirstSequenceToday == nil`: first EGV of the day. `glucose.sequence < anchor`:
+        // sensor swap (sequence resets when a new G7 session starts) — re-anchor to the new sensor's sequence.
+        let currentSequence = Int(glucose.sequence)
+        if let anchor = bleFirstSequenceToday {
+            if currentSequence < anchor {
+                bleFirstSequenceToday = currentSequence
+                UserDefaults.standard.set(currentSequence, forKey: Keys.firstSequenceToday)
+            }
+        } else {
+            bleFirstSequenceToday = currentSequence
+            UserDefaults.standard.set(currentSequence, forKey: Keys.firstSequenceToday)
+        }
         persistDailyCounters()
         mirrorDailyCountersToWatchState()
         let delta: String = {
@@ -557,6 +617,8 @@ extension G7WatchSensorAdapter: G7SensorDelegate {
             WatchState.shared.applyG7DirectBleSnapshot(snapshot)
             WatchState.shared.bleLastEGVDate = readingDate
             WatchState.shared.bleLastEGVValue = glucoseValue
+            WatchState.shared.bleLastEGVSequence = currentSequence
+            HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)
         }
 
         publishConnectionStatus()
diff --git a/Trio Watch App Extension/TrioWatchApp.swift b/Trio Watch App Extension/TrioWatchApp.swift
index 3650c066e..defb060e1 100644
--- a/Trio Watch App Extension/TrioWatchApp.swift	
+++ b/Trio Watch App Extension/TrioWatchApp.swift	
@@ -24,6 +24,7 @@ import WatchKit
 
             if newPhase == .active {
                 WatchState.shared.handleForegroundActiveEntry()
+                HapticBeacon.shared.start()
             } else if newPhase == .background || newPhase == .inactive {
                 WatchState.shared.handleForegroundInactiveOrBackground()
             }
diff --git a/Trio Watch App Extension/Views/ComplicationDebugView.swift b/Trio Watch App Extension/Views/ComplicationDebugView.swift
index 2b5f3f92e..842603247 100644
--- a/Trio Watch App Extension/Views/ComplicationDebugView.swift	
+++ b/Trio Watch App Extension/Views/ComplicationDebugView.swift	
@@ -17,6 +17,25 @@ struct ComplicationDebugView: View {
     /// readings produce no-op @State assignments and no re-render without this).
     @State private var now: Date = Date()
 
+    /// Scene phase, used **only** to drive the `isActive` `@State` flag via `.onChange`.
+    /// **Do not read directly from inside the `.task` polling loop** — the task closure captures
+    /// `self` (a value-type view struct) at task creation, so a captured `scenePhase` would be
+    /// frozen at its initial value and would never reflect later scene-phase transitions.
+    /// `isActive` (below) is the actual gate the loop reads, because `@State`-backed values are
+    /// observed through SwiftUI's storage and are safe to read from a long-lived concurrent Task.
+    @Environment(\.scenePhase) private var scenePhase
+
+    /// `true` while the watch app is in `.active` scene phase. Mirror of `scenePhase` written via
+    /// `.onChange(of: scenePhase)` and read from the 1Hz polling task to gate per-second work.
+    /// Defaults to `true` so the very first ticks after `.onAppear` (before any scene-phase
+    /// transition is observed) are not unnecessarily suppressed.
+    @State private var isActive: Bool = true
+
+    /// Mirror of `HapticBeacon.shared.isEnabled` so the toggle button label re-renders after a
+    /// tap. Initialized in `.onAppear` to avoid touching `@MainActor` singleton state from a
+    /// non-isolated property initializer.
+    @State private var hapticBeaconEnabled: Bool = false
+
     private let dataStore = TrioComplicationDataStore.shared
 
     // Static formatter — allocated once, reused every 1s tick (item 21)
@@ -55,7 +74,7 @@ struct ComplicationDebugView: View {
 
                 // SECTION 3: G7 Direct BLE
                 sectionHeader("G7 DIRECT BLE")
-                G7DirectBleDebugSection()
+                G7DirectBleDebugSection(now: now)
 
                 Divider().padding(.vertical, 4)
 
@@ -70,13 +89,29 @@ struct ComplicationDebugView: View {
         .onAppear {
             loadSnapshot()
             loadLogFileStats()
+            hapticBeaconEnabled = HapticBeacon.shared.isEnabled
+        }
+        .onChange(of: scenePhase) { _, newPhase in
+            isActive = (newPhase == .active)
         }
-        // Unified 1s task — snapshot every tick, file stats every 5s (items 18, 20)
+        // Unified 1s task — snapshot every tick, file stats every 5s (items 18, 20).
         // `now` updated unconditionally to drive countdown/age even when snapshot is unchanged.
+        //
+        // **Invariant:** the loop continues running while the view exists, but skips work
+        // (no `now` tick, no `loadSnapshot()`, no `loadLogFileStats()`) whenever the watch app
+        // is not in `.active` scene phase. This eliminates 1Hz log-store reads (and the
+        // `latestSnapshot()` cascade) while the user is on the watch face or in another app.
+        //
+        // **Correctness note:** the gate reads `isActive` (a `@State`-backed mirror of
+        // `scenePhase`) instead of `scenePhase` directly. The `.task` closure captures `self`
+        // by value at task creation, so a directly-captured `@Environment(\.scenePhase)` would
+        // be **frozen** at the value present at view first-appear and would never observe later
+        // background ↔ active transitions, defeating the suspension entirely.
         .task {
             var tick = 0
             while !Task.isCancelled {
                 try? await Task.sleep(nanoseconds: 1_000_000_000)
+                guard isActive else { continue }
                 now = Date()
                 loadSnapshot()
                 tick += 1
@@ -100,7 +135,11 @@ struct ComplicationDebugView: View {
                     Text(s.trend.isEmpty ? "—" : trendSymbol(s.trend))
                     Text(s.delta)
                 }
-                .font(.title3)
+                .font(.title)
+                .lineLimit(1)
+                .minimumScaleFactor(0.6)
+                .frame(maxWidth: .infinity, alignment: .center)
+                .padding(.vertical, 2)
 
                 // item 3: source row
                 HStack {
@@ -113,13 +152,8 @@ struct ComplicationDebugView: View {
                 HStack {
                     Text("Reading:")
                     Spacer()
-                    VStack(alignment: .trailing, spacing: 2) {
-                        Text(formatTime(s.readingDate))
-                        Text("(\(Int(now.timeIntervalSince(s.readingDate)))s ago)")
-                   
-                            .font(.caption2)
-                            .foregroundColor(ageColor(s.readingDate, relativeTo: now))
-                    }
+                    Text(formatTime(s.readingDate))
+                        .foregroundColor(ageColor(s.readingDate, relativeTo: now))
                 }
 
                 // item 4: next reading countdown — only meaningful for BLE source where
@@ -151,7 +185,7 @@ struct ComplicationDebugView: View {
             HStack {
                 Text("Last reload:")
                 Spacer()
-                Text("\(formatTime(dataStore.lastReloadTimestamp)) (\(Int(dataStore.secondsSinceLastReload))s ago)")
+                Text(formatTime(dataStore.lastReloadTimestamp))
             }
 
             HStack {
@@ -345,6 +379,21 @@ struct ComplicationDebugView: View {
             }
             .buttonStyle(.bordered)
             .tint(.purple)
+
+            Button {
+                let newValue = !hapticBeaconEnabled
+                HapticBeacon.shared.setEnabled(newValue)
+                hapticBeaconEnabled = newValue
+                triggerConfirmation(message: newValue ? "🔔 Haptic Beacon ON" : "🔕 Haptic Beacon OFF")
+            } label: {
+                HStack {
+                    Image(systemName: hapticBeaconEnabled ? "bell.fill" : "bell.slash")
+                    Text("Haptic Beacon: \(hapticBeaconEnabled ? "ON" : "OFF")")
+                }
+                .frame(maxWidth: .infinity)
+            }
+            .buttonStyle(.bordered)
+            .tint(.pink)
         }
     }
 
@@ -409,14 +458,6 @@ struct ComplicationDebugView: View {
         return Self.timeFormatter.string(from: date)
     }
 
-    private func formatAge(_ date: Date, relativeTo now: Date = Date()) -> String {
-        if date == .distantPast { return "--" }
-        let seconds = Int(now.timeIntervalSince(date))
-        if seconds < 60 { return "\(seconds)s ago" }
-        if seconds < 3600 { return "\(seconds / 60)m ago" }
-        return "\(seconds / 3600)h ago"
-    }
-
     private func ageColor(_ date: Date, relativeTo now: Date = Date()) -> Color {
         if date == .distantPast { return .secondary }
         let age = now.timeIntervalSince(date)
@@ -466,6 +507,12 @@ struct ComplicationDebugView: View {
 /// G7 debug rows: read `WatchState` from this type's `body` so updates observe reliably (vs. a
 /// `private var` on the parent). DATA STORE / log stats still use the unified 1s task poll.
 private struct G7DirectBleDebugSection: View {
+    /// Driven by parent's 1s tick so countdown rows re-render even when underlying state is unchanged.
+    let now: Date
+
+    /// G7 nominal cadence (matches `ComplicationDebugView.expectedReadingCadence`).
+    private static let expectedCadence: TimeInterval = 300
+
     // item 21: static formatter
     private static let timeFormatter: DateFormatter = {
         let f = DateFormatter()
@@ -487,6 +534,13 @@ private struct G7DirectBleDebugSection: View {
                 Spacer()
                 Text(formatG7Time(WatchState.shared.bleLastConnectAt))
             }
+            // Countdown to next anticipated connect (last connect + 5 min cadence).
+            HStack {
+                Text("Next connect:")
+                Spacer()
+                Text(nextConnectCountdown(WatchState.shared.bleLastConnectAt))
+                    .monospacedDigit()
+            }
             HStack {
                 Text("Last BLE EGV:")
                 Spacer()
@@ -500,16 +554,18 @@ private struct G7DirectBleDebugSection: View {
             HStack {
                 Text("Connects:")
                 Spacer()
-                Text("\(WatchState.shared.bleConnectsToday)")
+                Text(countWithDenominator(WatchState.shared.bleConnectsToday))
+                    .monospacedDigit()
             }
             HStack {
                 Text("EGVs:")
                 Spacer()
-                Text("\(WatchState.shared.bleEGVsToday)")
+                Text(countWithDenominator(WatchState.shared.bleEGVsToday))
+                    .monospacedDigit()
             }
             // Phone-relay sensor name (UserDefaults via adapter) — must match WC `g7_active_sensor_name` sync.
             HStack {
-                Text("Phone sensor filter:")
+                Text("Phone sensor:")
                 Spacer()
                 Text(G7WatchSensorAdapter.shared.telemetrySensorName)
                     .foregroundColor(.secondary)
@@ -531,6 +587,33 @@ private struct G7DirectBleDebugSection: View {
         guard let date, date != .distantPast else { return "--" }
         return Self.timeFormatter.string(from: date)
     }
+
+    /// Mirrors `ComplicationDebugView.nextReadingCountdown` semantics: "Ns" when in the future,
+    /// "⚠️+Ns" when overdue (last connect + cadence has already passed). "--" if no connect yet.
+    private func nextConnectCountdown(_ lastConnect: Date?) -> String {
+        guard let lastConnect, lastConnect != .distantPast else { return "--" }
+        let remaining = Int(lastConnect.addingTimeInterval(Self.expectedCadence).timeIntervalSince(now))
+        if remaining < 0 { return "⚠️+\(abs(remaining))s" }
+        return "\(remaining)s"
+    }
+
+    /// Format a daily counter as "X / Y" where Y is the number of EGVs the G7 sensor has
+    /// produced since the first one observed today (sequence-anchored, not wall-clock anchored).
+    /// Falls back to "X" alone when no EGV has been received today (denominator unknown) or
+    /// when the latest sequence is somehow older than the anchor.
+    private func countWithDenominator(_ count: Int) -> String {
+        guard let first = WatchState.shared.bleFirstSequenceToday,
+              let last = WatchState.shared.bleLastEGVSequence,
+              last >= first else {
+            return "\(count)"
+        }
+        let expected = last - first + 1
+        // 5-min cadence caps a single calendar day at 288 readings. Anything larger means
+        // the anchor and last sequence transiently disagreed (e.g. mid-update read between
+        // anchor reset and lastSequence write); show count alone instead of a misleading huge ratio.
+        guard expected <= 288 else { return "\(count)" }
+        return "\(count) / \(expected)"
+    }
 }
 
 #Preview {
diff --git a/Trio Watch App Extension/Views/TrioMainWatchView.swift b/Trio Watch App Extension/Views/TrioMainWatchView.swift
index 505e43f6f..dc3a44dc8 100644
--- a/Trio Watch App Extension/Views/TrioMainWatchView.swift	
+++ b/Trio Watch App Extension/Views/TrioMainWatchView.swift	
@@ -113,22 +113,6 @@ struct TrioMainWatchView: View {
                 }
                 .tag(2)
             }
-            .overlay(alignment: .top) {
-                TimelineView(.periodic(from: .now, by: 1.0)) { context in
-                    Group {
-                        if context.cadence <= .seconds {
-                            Text(context.date, format: .dateTime.hour().minute().second())
-                        } else {
-                            Text(context.date, format: .dateTime.hour().minute())
-                        }
-                    }
-                    .font(.caption2)
-                    .monospacedDigit()
-                    .foregroundStyle(.secondary)
-                    .padding(.top, 4)
-                }
-                .allowsHitTesting(false)
-            }
             .onAppear {
                 Task {
                     await WatchLogger.shared.log("Watch main view appeared")
diff --git a/Trio Watch App Extension/WatchState.swift b/Trio Watch App Extension/WatchState.swift
index 612960156..25761d330 100644
--- a/Trio Watch App Extension/WatchState.swift	
+++ b/Trio Watch App Extension/WatchState.swift	
@@ -111,6 +111,10 @@ extension TrioComplicationDataSource {
     var bleLastConnectAt: Date?
     var bleLastEGVDate: Date?
     var bleLastEGVValue: Int?
+    /// Latest G7 EGV sequence number observed on the BLE direct path; mirrored from `G7WatchSensorAdapter`. nil until first EGV today.
+    var bleLastEGVSequence: Int?
+    /// G7 EGV sequence anchor for "expected readings today" calculation. Set on first EGV of the calendar day; reset on day rollover or sensor swap (sequence regression). Mirrored from `G7WatchSensorAdapter`.
+    var bleFirstSequenceToday: Int?
     /// True when `CBCentralManager` had state restored this process (willRestoreState).
     var bleWasRestored: Bool = false
     var overridePresets: [OverridePresetWatch] = []
@@ -218,6 +222,23 @@ extension TrioComplicationDataSource {
 
     private var backgroundRefreshCount = 0
     private var lastBackgroundRefreshDate: Date?
+
+    /// Set when a `WKApplicationRefreshBackgroundTask` triggers `requestWatchStateUpdate()` and the
+    /// resulting fresh data application should trigger `forceComplicationUpdate()`. Consumed (fired
+    /// and cleared) in `finalizePendingData` once the WC reply has been processed and applied to
+    /// UI state.
+    ///
+    /// **Two clearing paths exist**, both gated by `bgTaskComplicationUpdateWindow`:
+    /// 1. `finalizePendingData` (fresh data arrived): fires `forceComplicationUpdate()` when
+    ///    within window, or logs `"🔄 bgtask complication update flag expired"` if past it.
+    /// 2. `DispatchQueue.main.asyncAfter` scheduled alongside the flag in the bgtask handler:
+    ///    if the flag is still set with the **same timestamp** after the window elapses (no
+    ///    data ever arrived), clears the flag and logs `"⌚️ bgTask complication update skipped:
+    ///    flag stale"`. The timestamp match ensures a later bgtask's flag is not stolen.
+    private var pendingBgTaskComplicationUpdateAt: Date?
+    /// Staleness bound for `pendingBgTaskComplicationUpdateAt`. Matches the WC sync timeout in
+    /// `requestWatchStateUpdate(retryCount:)` so any flag older than this is treated as expired.
+    private let bgTaskComplicationUpdateWindow: TimeInterval = 30.0
     private var lastConnectivityTerminalAt: Date?
     private var lastConnectivityTerminalPath: String?
     private var deferredConnectivityCompletionWorkItem: DispatchWorkItem?
@@ -1808,6 +1829,14 @@ extension TrioComplicationDataSource {
         DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
     }
 
+    /// Apply any buffered WC payload to UI state, then fire the **conditional** complication
+    /// refresh that a background-task-driven `requestWatchStateUpdate()` is waiting on.
+    ///
+    /// **Invariant (Bug #6):** `forceComplicationUpdate()` runs at most **once** per pending bgtask,
+    /// and only when *fresh* data has actually been applied (we entered this method with a
+    /// non-empty `pendingData`). Empty-payload finalizes do **not** trigger the complication
+    /// refresh — they simply hide the syncing animation and let the existing complication state
+    /// remain. The flag is also auto-cleared when stale (older than `bgTaskComplicationUpdateWindow`).
     private func finalizePendingData(
         fromUserInfo: Bool = false,
         userInfoReceiveTimestamp: Date? = nil,
@@ -1845,6 +1874,21 @@ extension TrioComplicationDataSource {
             await WatchLogger.shared.log("Watch UI update complete")
         }
 
+        // Consume the bgtask-driven complication-update flag once fresh data has been applied.
+        // Stale flags (older than `bgTaskComplicationUpdateWindow`) are dropped silently so a
+        // foreground refresh long after a failed bgtask cannot trigger a spurious complication
+        // update.
+        if let bgTaskRequestedAt = pendingBgTaskComplicationUpdateAt {
+            pendingBgTaskComplicationUpdateAt = nil
+            if Date().timeIntervalSince(bgTaskRequestedAt) <= bgTaskComplicationUpdateWindow {
+                forceComplicationUpdate()
+            } else {
+                Task {
+                    await WatchLogger.shared.log("🔄 bgtask complication update flag expired; skipping forceComplicationUpdate")
+                }
+            }
+        }
+
         guard let pendingConnectivityCompletionPath else { return }
         let pendingCountBeforeCompletion = pendingConnectivityTasks.count
         let wid = BackgroundTaskWindowCounter.currentOrNil() ?? -1
@@ -2219,9 +2263,27 @@ extension TrioComplicationDataSource {
                     lastBackgroundRefreshDate = Date()
 
                     if isReachable {
+                        // Defer `forceComplicationUpdate()` to the data-application success path
+                        // (`finalizePendingData`) instead of firing unconditionally after 2s. Avoids
+                        // refreshing the complication with stale `currentGlucose` when the WC reply
+                        // is slow or never arrives — see Bug #6 / `pendingBgTaskComplicationUpdateAt`.
+                        let requestedAt = Date()
+                        pendingBgTaskComplicationUpdateAt = requestedAt
                         requestWatchStateUpdate()
-                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
-                            self.forceComplicationUpdate()
+                        // Stale-flag detector: if `finalizePendingData` never fires within the
+                        // window (WC unreachable, dropped reply, retries exhausted), the deferred
+                        // complication update is silently skipped. Emit one log line so the
+                        // bgtask → complication-update path is observable in telemetry.
+                        // The timestamp check ensures we only clear / log our **own** flag —
+                        // a later bgtask that re-set the flag with a fresh timestamp is untouched.
+                        let window = bgTaskComplicationUpdateWindow
+                        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
+                            guard let self = self else { return }
+                            guard self.pendingBgTaskComplicationUpdateAt == requestedAt else { return }
+                            self.pendingBgTaskComplicationUpdateAt = nil
+                            Task {
+                                await WatchLogger.shared.log("⌚️ bgTask complication update skipped: flag stale (no data within \(Int(window))s)")
+                            }
                         }
                     } else {
                         loadFallbackDataFromComplication()
diff --git a/Trio Watch App Extension/HapticBeacon.swift b/Trio Watch App Extension/HapticBeacon.swift
new file mode 100644
index 000000000..e38e641bc
--- /dev/null
+++ b/Trio Watch App Extension/HapticBeacon.swift	
@@ -0,0 +1,273 @@
+import Foundation
+import WatchKit
+
+/// Cadence-aware haptic beacon for the watch app. Predicts when the next G7 EGV will arrive
+/// (5-min cadence anchored on receipt time) and signals the user via haptics:
+///
+/// - **Pre-EGV ramp** (T-3s, T-2s, T-1s): `.click` → `.start` → `.notification` (increasing intensity).
+/// - **Success** (on EGV reception): `.success` × 2, ~150 ms apart.
+/// - **Miss** (T+20s past expected with no EGV): `.retry` once.
+///
+/// Cut 1: foreground delivery only via `WKInterfaceDevice.current().play(_:)`. Cut 2 spike will
+/// switch `play(_:)` to prefer `WKExtendedRuntimeSession.notifyUser(haptic:)` when a session is
+/// running on the adapter, falling back to device.
+///
+/// **Adapter-stopped invariant (plan §11 Q3 / Option A):** when
+/// `WatchState.shared.g7DirectBleStatus == .off` the beacon stays silent — pending timers are
+/// cancelled and any incoming `play(_:)` is suppressed with a `haptic_skipped` log line. Avoids
+/// false-positive miss buzzes after extended-session invalidation or manual stop.
+///
+/// **Extended session reference (plan §2):** the beacon never caches the
+/// `WKExtendedRuntimeSession` reference. Three replacement paths exist on the adapter
+/// (`stop()`, `renewSessionIfNeeded()`, chain inside `extendedRuntimeSessionWillExpire`), so
+/// `play(_:)` re-queries `G7WatchSensorAdapter.shared.currentExtendedSession` at fire time
+/// when Cut 2 lands. Cut 1 plays through `WKInterfaceDevice` only and the accessor is unused.
+///
+/// **Vocabulary reservation (plan §10.1):** `.failure`, `.directionUp`, `.directionDown`, `.stop`
+/// are reserved for a future clinical alerter. Do not add them to the beacon's haptic palette.
+@MainActor
+final class HapticBeacon {
+    static let shared = HapticBeacon()
+
+    // MARK: - Tuning constants
+
+    /// G7 nominal cadence (5 min). Mirrors `ComplicationDebugView.expectedReadingCadence`.
+    private static let expectedCadence: TimeInterval = 300
+    /// Ramp begins this far before expected EGV.
+    private static let rampLeadTime: TimeInterval = 3
+    /// Time after expected EGV before declaring a miss.
+    private static let missGracePeriod: TimeInterval = 20
+    /// Do not rearm if last receipt was older than this — system is likely down or stale.
+    private static let staleThreshold: TimeInterval = 600
+    /// Inter-buzz spacing for the success pair.
+    private static let successInterBuzzInterval: TimeInterval = 0.150
+    /// Leeway for `DispatchSourceTimer` schedules. 500 ms is forgiving on Apple Watch SE/older
+    /// hardware; reduce if observed drift > 5 s (plan §7 Risk 2).
+    private static let timerLeeway: DispatchTimeInterval = .milliseconds(500)
+
+    // MARK: - Persistence
+
+    private enum Keys {
+        static let isEnabled = "HapticBeacon.isEnabled"
+    }
+
+    /// Opt-in toggle backed by `UserDefaults.standard`. Default OFF (plan §11 Q1).
+    /// Local to the watch extension; not in App Group (plan §7 Risk 5).
+    /// Computed from UserDefaults each read so initialization side effects are zero and
+    /// `setEnabled(_:)` is the single mutation site.
+    var isEnabled: Bool {
+        UserDefaults.standard.bool(forKey: Keys.isEnabled)
+    }
+
+    // MARK: - Timer state (touched only on `@MainActor`)
+
+    /// Serial queue for `DispatchSourceTimer` scheduling. Mirrors `G7WatchSensorAdapter.timerQueue`.
+    /// All timer event handlers hop back to `@MainActor` via `Task { @MainActor in … }` before
+    /// touching beacon state or invoking haptics.
+    private let timerQueue = DispatchQueue(label: "org.nightscout.trio.watch.haptic.timers", qos: .utility)
+
+    private var rampTimer: DispatchSourceTimer?
+    /// Three ramp sub-timers at +0s/+1s/+2s from ramp trigger; cancellable as a group.
+    private var rampSubTimers: [DispatchSourceTimer] = []
+    private var missTimer: DispatchSourceTimer?
+
+    /// Receipt time of the last `noteEGVReceived` call. Cadence anchor.
+    private var lastReceiptAt: Date?
+
+    private init() {}
+
+    // MARK: - Public API
+
+    /// Idempotent. No observers in Cut 1 — the beacon arms via `noteEGVReceived` calls from
+    /// `G7WatchSensorAdapter`. Wired into `TrioWatchApp` `.active` scene-phase transitions and
+    /// kept as a hook for future cuts (Cut 3 source observers, etc.).
+    func start() {
+        log("start", "is_enabled=\(isEnabled)")
+    }
+
+    /// Idempotent. Cancels all in-flight timers and clears `lastReceiptAt`. Currently
+    /// uncalled from any production code path (BLE keeps running across scene-phase changes
+    /// per plan §3.3); exposed for symmetry, debug, and future cuts.
+    func stop() {
+        cancelAllTimers()
+        lastReceiptAt = nil
+        log("stop")
+    }
+
+    /// Persisted toggle. Disabling cancels in-flight timers immediately so a mid-ramp toggle
+    /// doesn't continue firing buzzes. Enabling does not arm anything — next EGV will arm.
+    func setEnabled(_ enabled: Bool) {
+        let wasEnabled = isEnabled
+        guard enabled != wasEnabled else { return }
+        UserDefaults.standard.set(enabled, forKey: Keys.isEnabled)
+        if !enabled {
+            cancelAllTimers()
+            log("setEnabled", "enabled=false action=cancelled_pending_timers")
+        } else {
+            log("setEnabled", "enabled=true")
+        }
+    }
+
+    /// Single hook the rest of the codebase calls when an EGV is received.
+    ///
+    /// Cut 1: only the BLE source is honored. Phone/HK are silently ignored until Cut 3 wires
+    /// them up — the parameter exists today so Cut 3 plumbing in `WatchState` is a one-liner.
+    func noteEGVReceived(at receiptDate: Date, source: TrioComplicationDataSource) {
+        guard isEnabled else { return }
+        guard source == .g7DirectBLE else {
+            // Cut 3 will switch to honoring a sourceFilter (.ble | .all).
+            return
+        }
+        guard !isAdapterStopped() else {
+            // Defense in depth: per plan §11 Q3, also gate at noteEGVReceived. EGVs should not
+            // be delivered while the adapter status is `.off`, but if they are (race between
+            // status mirror and EGV reception, or a future Cut 3 path), drop the cycle silently.
+            cancelAllTimers()
+            log("haptic_skipped", "reason=adapter_stopped phase=success source=\(source.rawValue)")
+            return
+        }
+
+        cancelAllTimers()
+        lastReceiptAt = receiptDate
+        fireSuccess()
+        rearm(after: receiptDate)
+    }
+
+    // MARK: - Internal: scheduling
+
+    private func rearm(after receiptDate: Date) {
+        // Stale guard: receipt > staleThreshold old → don't predict; system is likely down or
+        // recovering, and the cadence anchor would be unreliable.
+        let age = Date().timeIntervalSince(receiptDate)
+        if age >= Self.staleThreshold {
+            log("rearm_skipped", "reason=stale_receipt age_s=\(Int(age))")
+            return
+        }
+
+        let rampAt = receiptDate.addingTimeInterval(Self.expectedCadence - Self.rampLeadTime)
+        let missAt = receiptDate.addingTimeInterval(Self.expectedCadence + Self.missGracePeriod)
+
+        scheduleRampTimer(at: rampAt)
+        scheduleMissTimer(at: missAt)
+
+        let rampEpoch = Int(rampAt.timeIntervalSince1970)
+        let missEpoch = Int(missAt.timeIntervalSince1970)
+        log("haptic_armed", "phase=ramp expected_at=\(rampEpoch) source=ble")
+        log("haptic_armed", "phase=miss expected_at=\(missEpoch) source=ble")
+    }
+
+    private func scheduleRampTimer(at fireDate: Date) {
+        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
+        let interval = max(0, fireDate.timeIntervalSinceNow)
+        timer.schedule(deadline: .now() + interval, leeway: Self.timerLeeway)
+        timer.setEventHandler {
+            Task { @MainActor in
+                HapticBeacon.shared.fireRamp()
+            }
+        }
+        rampTimer = timer
+        timer.resume()
+    }
+
+    private func scheduleMissTimer(at fireDate: Date) {
+        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
+        let interval = max(0, fireDate.timeIntervalSinceNow)
+        timer.schedule(deadline: .now() + interval, leeway: Self.timerLeeway)
+        timer.setEventHandler {
+            Task { @MainActor in
+                HapticBeacon.shared.fireMiss()
+            }
+        }
+        missTimer = timer
+        timer.resume()
+    }
+
+    // MARK: - Internal: firing
+
+    private func fireRamp() {
+        // Three sub-timers on `timerQueue` at +0s/+1s/+2s, cancellable as a group via
+        // `rampSubTimers`. Per-fire gating (isEnabled, adapter-stopped) lives in `play(_:)`
+        // so this method stays lean and consistent with the timer model.
+        let steps: [(TimeInterval, WKHapticType, String)] = [
+            (0.0, .click, "ramp_click"),
+            (1.0, .start, "ramp_start"),
+            (2.0, .notification, "ramp_notif"),
+        ]
+        var newSubs: [DispatchSourceTimer] = []
+        for (delay, type, label) in steps {
+            let t = DispatchSource.makeTimerSource(queue: timerQueue)
+            t.schedule(deadline: .now() + delay)
+            t.setEventHandler {
+                Task { @MainActor in
+                    HapticBeacon.shared.play(type, label: label)
+                }
+            }
+            newSubs.append(t)
+            t.resume()
+        }
+        rampSubTimers = newSubs
+    }
+
+    private func fireSuccess() {
+        play(.success, label: "success")
+        // Second buzz scheduled on `timerQueue` so the kill switch / `cancelAllTimers` can
+        // suppress it within the 150 ms window. Untracked separately: worst case is one extra
+        // buzz if the user disables inside the 150 ms window — acceptable.
+        let t = DispatchSource.makeTimerSource(queue: timerQueue)
+        t.schedule(deadline: .now() + Self.successInterBuzzInterval)
+        t.setEventHandler {
+            Task { @MainActor in
+                HapticBeacon.shared.play(.success, label: "success")
+            }
+        }
+        t.resume()
+    }
+
+    private func fireMiss() {
+        play(.retry, label: "retry")
+    }
+
+    /// Single haptic-delivery choke point.
+    ///
+    /// Cut 1: device-only via `WKInterfaceDevice.current().play(_:)`. Cut 2 spike will switch
+    /// this method to prefer `WKExtendedRuntimeSession.notifyUser(haptic:)` when the adapter
+    /// has a running session, falling back to device. Plan §10.2: do not add beacon-specific
+    /// assumptions here — a future `ClinicalAlerter` may share this method or an extracted
+    /// `HapticDispatcher`.
+    private func play(_ type: WKHapticType, label: String) {
+        guard isEnabled else { return }
+        guard !isAdapterStopped() else {
+            log("haptic_skipped", "reason=adapter_stopped type=\(label)")
+            return
+        }
+        WKInterfaceDevice.current().play(type)
+        log("haptic_fired", "type=\(label) delivered_via=device")
+    }
+
+    // MARK: - Internal: housekeeping
+
+    private func cancelAllTimers() {
+        rampTimer?.cancel()
+        rampTimer = nil
+        rampSubTimers.forEach { $0.cancel() }
+        rampSubTimers.removeAll()
+        missTimer?.cancel()
+        missTimer = nil
+    }
+
+    /// Adapter-stopped check (plan §11 Q3 / Option A). Reads the status mirror published by
+    /// `G7WatchSensorAdapter.publishConnectionStatus()` rather than the adapter's `private`
+    /// `isStopped` flag — no new accessor needed.
+    private func isAdapterStopped() -> Bool {
+        WatchState.shared.g7DirectBleStatus == .off
+    }
+
+    // MARK: - Telemetry
+
+    private func log(_ event: String, _ fields: String = "") {
+        let suffix = fields.isEmpty ? "" : " \(fields)"
+        Task {
+            await WatchLogger.shared.log("module=haptic_beacon event=\(event)\(suffix)")
+        }
+    }
+}
```
