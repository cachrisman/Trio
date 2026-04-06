# Watch foreground launch — memory / jetsam investigation

**Document:** `03-watch-foreground-launch-memory-investigation.md`  
**Version:** 1.6  
**Last updated:** 2026-04-06 15:48 CET  
**Status:** Final  
**Scope:** Trio Watch App Extension (`Trio Watch App Extension/`), shared complication store (`Trio Watch Shared/`), and iPhone-side watch payload construction (`Trio/Sources/Services/WatchManager/AppleWatchManager.swift`) as needed to bound payload size.  
**Branch reviewed:** `feature/watch-complication-improvements` (Trio worktree).  
**Related project docs (do not replace):** [00-investigation-findings.md](00-investigation-findings.md), [01-startup-load-shedding-design.md](01-startup-load-shedding-design.md), [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md), [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md). Those docs frame **Path B** (foreground memory-hardening / launch footprint) as the **primary remediation track** and **Path A** (startup load shedding / launch pressure) as a **justified parallel** track. This document is the **completed investigation artifact** and **primary evidence input for Path B**; **04** holds Path B **decisions and gates**; Path A remains **work scheduling / transport**, which is related but not identical to resident footprint.

---

## Executive summary

**Evidence-backed finding:** The watch app’s foreground path combines (a) a **large, type-erased WatchConnectivity payload** (up to **288** glucose points from the phone per `AppleWatchManager.fetchGlucose()`), (b) **additional in-memory copies** when merging into `pendingData` and when converting to `WatchState.glucoseValues` with embedded `SwiftUI.Color`, (c) **SwiftUI `TabView` + `Charts`** keeping a **chart page in the hierarchy** that binds to the full `glucoseValues` array, and (d) **logging that stringifies entire `[String: Any]` messages**, which can temporarily duplicate the payload as a huge `String`.

**Inference (hypothesis for repeatable ~305–334 MiB jetsam):** Repeatable kills on foreground open are **plausibly driven by the combination** of runtime baseline (SwiftUI + Charts + observation of `WatchState`) **plus** the first full watch-state delivery (288-point history + dictionaries) **plus** peak logging/flush activity, rather than a single tiny leak. **Confidence:** medium — resident size at jetsam is an OS measurement; this document maps **code-level allocators/retainers**, not a verified allocation profile.

**Path A — Startup load shedding (already in tree):** Defers first `requestWatchStateUpdate()` by 2s, HealthKit setup by 10s, and persisted log flush by 10s, and suppresses log transport until the first deferred refresh fires (`WatchState.handleForegroundActiveEntry`, `fireDeferredStartupWatchStateRefreshOnMain`, `WatchStartupTransportGate`). That reduces **contention and WC traffic** early; it does **not** remove the **288-point chart payload** once it arrives, nor **verbatim message logging**—those gaps are why parent planning treats **Path B** as the **primary footprint track** while **Path A** remains a **parallel pressure-reduction** track.

**Post-investigation implementation (2026-04-06):** **Path B** **B3** now gates **`GlucoseChartView`** behind the chart **`TabView`** page (`currentPage == 1`), so launch no longer pays full **Charts** / **`PointMark`** construction until the user opens that tab. **B1** and **B4** address ranked items **3** and **4** below (trimmed WC logging; bounded nil-anchor HK bootstrap + anchor establishment). **Field:** TestFlight **152** reported **stable foreground launch** without jetsam/forced closure — **supportive** for the hypothesis that **eager chart construction at first frame** was a dominant launch allocator alongside payload/logging/HK risk. This doc’s **launch-path map** and ranked list remain the **investigation-time** baseline unless a paragraph explicitly says **current tree**.

---

## Launch-path map

**Naming:** The **steps** below are **runtime launch timeline** labels only. They are **unrelated** to planning work items **A1–A3** (Path A) or **B0–B5** (Path B).

**Step 1 — Process / delegate (before first frame)**

1. `WatchState.shared` lazy init (`WatchState.init`): `setupSession()` → `WCSession.default` delegate = self, `activate()`; schedules `DispatchQueue.main.asyncAfter(1s)` → `forceComplicationUpdate()` + `scheduleBackgroundRefresh()` (`WatchState.swift`).
2. `@main struct TrioWatchApp`: `init()` → `WatchNotificationHandler.shared.configure()`; `Task { WatchLogger.shared.log("[DEPLOY]…") }` (`TrioWatchApp.swift`).
3. `ExtensionDelegate.applicationDidFinishLaunching`: `TrioComplicationDataStore.setLogForwarder { … WatchLogger… }`; `WatchState.shared.scheduleBackgroundLaunchDisarmIfNeeded()`; `Task` logs + `TrioComplicationDataStore.shared.diagnosticsSummary(…)`; `WatchState.shared.scheduleBackgroundRefresh()` (`ExtensionDelegate.swift`).
4. `WatchLogger.shared` first touch: actor `init` starts perpetual `Task` flush timer (`WatchLogger.swift`).

**Step 2 — SwiftUI first frame**

5. `WindowGroup { TrioMainWatchView() }` (`TrioWatchApp.swift`).
6. `TrioMainWatchView`: `@State private var state = WatchState.shared` — `@Observable` `WatchState` drives view dependency tracking (`TrioMainWatchView.swift`).
7. `TabView` builds **page 0** (`GlucoseTrendView`). **Page 1** (**investigation baseline**): `GlucoseChartView(…)` was constructed **unconditionally** while the chart tab was not visible. **Current tree (B3):** **`GlucoseChartView` only when `currentPage == 1`**, otherwise a lightweight placeholder (`Color.clear`) — same gating pattern as **page 2** / `ComplicationDebugView` (`TrioMainWatchView.swift`).
8. `.onAppear`: `TrioComplicationDataStore.shared.latestSnapshot()` (disk read + JSON decode); may copy snapshot fields into `state` (`TrioMainWatchView.swift`); `TrioComplicationDataStore.latestSnapshot()` (`TrioComplicationDataStore.swift`).

**Step 3 — Foreground “active” (may fire twice; second is a no-op)**

9. `ExtensionDelegate.applicationDidBecomeActive` → `WatchState.shared.handleForegroundActiveEntry()` (`ExtensionDelegate.swift`).
10. `scenePhase == .active` → `handleForegroundActiveEntry()` (`TrioWatchApp.swift`).  
    `handleForegroundActiveEntry`: `WatchStartupTransportGate.arm(…)`; `noteAppBecameActive()`; `scheduleStartupSequenceOnMain` (2s / 10s / 10s work items); `Task { WatchErrorReporter.shared.startup() }` (`WatchState.swift`).

**Step 4 — Deferred first refresh (2s after foreground)**

11. `fireDeferredStartupWatchStateRefreshOnMain` → `requestWatchStateUpdate()` (`WatchState.swift`, `WatchState+Requests.swift`).
12. Phone responds via `session(_:didReceiveMessage:)` → `processWatchMessage` → `scheduleUIUpdate` → debounced `finalizePendingData` → `processRawDataForWatchState` (`WatchState.swift`).

**Step 5 — Parallel / opportunistic delivery (not strictly ordered)**

- `session(_:didReceiveApplicationContext:)` may deliver a full `watchState` dictionary on main and call `saveComplicationSnapshot` + `scheduleUIUpdate` (`WatchState.swift`).
- `session(_:didReceiveUserInfo:)` may merge `payload` into `pendingData` or call `scheduleUIUpdate` directly (`WatchState.swift`).
- `session(_:activationDidCompleteWith:)` calls `forceConditionalWatchStateUpdate()`, but **startup grace** suppresses outbound refresh until the deferred first refresh fires (`shouldSuppressStartupSignalOnMain`, `WatchState.swift`).

**Step 6 — HealthKit (10s after foreground, once per process)**

13. `fireDeferredStartupHealthKitSetupOnMain` → `setupHealthKitBackgroundDelivery()` → `HKHealthStore`, `HKObserverQuery`, and on fire glucose fetch (**investigation baseline:** `HKAnchoredObjectQuery` with **`limit: HKObjectQueryNoLimit`** and **24h** predicate when anchor is nil). **Current tree (B4):** nil-anchor path uses bounded **`HKSampleQuery`** (cap **64**, newest-first) plus **`establishHealthKitGlucoseTimelineAnchorAfterBootstrap`**; incremental path uses anchored query with persisted anchor (`WatchState.swift`; see **02** § B4).

**Step 7 — Persisted log flush (10s after foreground)**

14. `fireDeferredStartupPersistedLogFlushOnMain` → `WatchStartupTransportGate.disarm` (if matching sequence) → `WatchLogger.shared.flushPersistedLogs(…)` (`WatchState.swift`, `WatchLogger.swift`).

---

## Major data structures on the launch path (enumeration)

| Structure | Where created / updated | Notes |
|-----------|-------------------------|-------|
| `WatchState` singleton | `WatchState.shared` | Large `@Observable` object: `glucoseValues`, `pendingData`, session, HealthKit fields, many UI mirrors (`WatchState.swift`). |
| `pendingData: [String: Any]` | `scheduleUIUpdate` merge; `didReceiveUserInfo` merge | Retains **phone-shaped** nested arrays/dictionaries until `finalizePendingData` clears (`WatchState.swift`). |
| WatchConnectivity `userInfo` / `applicationContext` / `message` | System → delegate | `NSDictionary` / `[String: Any]` bridging; includes `glucoseValues` as `[[String: Any]]`. |
| `glucoseValues: [(date:Date, glucose:Double, color:Color)]` | `processRawDataForWatchState` | Up to **288** entries after decode; each holds `SwiftUI.Color` (`WatchState.swift`). |
| `TrioComplicationSnapshot` + disk JSON | `saveOnMain`, `latestSnapshot` | Encoder/decoder `Data`, optional backup file copy (`TrioComplicationDataStore.swift`). |
| `WatchLogger.logs: [String]` | Every `log()` | Ring buffer **500** entries; each line includes timestamp, file, line, battery context (`WatchLogger.swift`). |
| Log flush buffers | `flushToPhone`, chunking | `joined` string of up to 500 lines; chunk builder; envelope `["data": content]` (`WatchLogger.swift`). |
| Complication log drain | `flushPersistedLogs` → `drainComplicationLogs` | Reads whole drain files into `Data`/`String` (cap 64 KiB per send) (`WatchLogger.swift`). |
| HK sample batch | `HKAnchoredObjectQuery` / bootstrap `HKSampleQuery` handler | **Investigation baseline:** with **nil anchor** and **no limit**, anchored pull could return **all samples in 24h**. **Current tree (B4):** nil-anchor bootstrap uses a **positive sample limit** (64); anchored incremental path after anchor persistence (`WatchState.swift`). |
| SwiftUI `Chart` / `PointMark` series | `GlucoseChartView` | Binds to `filteredValues` derived from `glucoseValues` (`GlucoseChartView.swift`). |

---

## Ranked top 10 launch memory consumers

For each item: **component / file / symbols**, **phase**, **likely memory**, **why large**, **confidence**, **role** (primary / secondary / incidental), **mitigation**.

### 1. WatchConnectivity watch-state payload + `pendingData` merge (up to 288 glucose points)

- **Component / file / symbols:** `WatchState.scheduleUIUpdate`, `pendingData.merge`, `processRawDataForWatchState`; phone builder `AppleWatchManager.setupWatchState`, `fetchGlucose` (`fetchLimit: 288`), `watchStateToDictionary` (`WatchState.swift`, `AppleWatchManager.swift`).
- **Phase:** First `didReceiveMessage` / `didReceiveUserInfo` / `didReceiveApplicationContext` after launch, and/or deferred `requestWatchStateUpdate` reply; **also** `pendingData.merge(payload)` on userInfo path when `pendingConnectivityTasks` is non-empty (`WatchState.swift` ~933).
- **Likely memory:** One **Objective-C / Swift bridging** graph (`NSDictionary`, `NSArray`, `NSString`, `NSNumber`) for the full message, **plus** merged `pendingData` holding the same nested `glucoseValues` until finalize; then a second representation as Swift arrays in `processRawDataForWatchState`.
- **Why large:** **288** points × (date + double + color string) in **`[[String: Any]]`**, repeated across merge/copy paths; color strings duplicated per point on the wire.
- **Confidence:** **High** (explicit `fetchLimit: 288` on phone; explicit merge/decode on watch).
- **Role:** **Primary** for “what scales with history length.”
- **Mitigation:** Reduce points sent to the watch (shorter horizon or downsampling for chart-only use); avoid retaining full payload in `pendingData` longer than necessary (merge keys selectively); send compact binary or smaller DTO; chart-specific payload vs full state.

### 2. `WatchState.glucoseValues` as `[(Date, Double, Color)]` + `GlucoseChartView` (`Charts`)

- **Component / file / symbols:** `WatchState.glucoseValues`; `GlucoseChartView` `Chart { ForEach(filteredValues,…) { PointMark… } }` (`WatchState.swift`, `GlucoseChartView.swift`, `TrioMainWatchView.swift`).
- **Phase:** After `processRawDataForWatchState`; **investigation baseline:** chart view was **constructed in `TabView` page 1** regardless of current page. **Current tree (B3):** chart is built **only when the chart page is selected**.
- **Likely memory:** Swift array of tuples with **`Color`** value types; Charts internal representation for marks/scales; observation via `@Observable` invalidates chart when `glucoseValues` changes.
- **Why large:** **288** `PointMark`s; `Color` may carry rendering pipeline state; Charts has non-trivial per-series overhead (exact bytes depend on OS version).
- **Confidence:** **Medium–high** for array cost; **medium** for Charts internals (not measured here).
- **Role:** **Primary** for UI/runtime footprint once data arrives.
- **Mitigation:** Lazy-construct chart only when user switches to chart page; downsample for display; replace Charts with lighter rendering for watch; cap points on watch independent of phone fetch.

### 3. Verbatim logging of full WC messages (`didReceiveMessage`)

- **Component / file / symbols:** `session(_:didReceiveMessage:)` — **investigation baseline:** logged full `message` string. **Current tree (B1):** `watchConnectivityInboundSummary` (keys, counts, epochs only) (`WatchState.swift`).
- **Phase:** Any incoming message carrying `watchState` (can coincide with foreground refresh).
- **Likely memory:** **Temporary peak** — `String` describing entire nested dictionary including **`glucoseValues`**; also appended to `logs` ring and `watch_log_daily.txt` (`WatchLogger.log`).
- **Why large:** Interpolation traverses and formats the whole structure; with 288 points this can be **hundreds of KB to MB** per log line **in addition to** the live payload copy.
- **Confidence:** **High** that this allocates large strings when messages are large; **medium** that it is the dominant peak among all logs.
- **Role:** **Secondary amplifier** (spikes transient RAM and disk append churn).
- **Mitigation:** Log keys + counts + `reading_epoch` only; mirror phone’s `CloudLogUploader` trim strategy (“drop from `glucoseValues =` onward”) on watch; never stringify full `message`.

### 4. HealthKit anchored glucose query with **no limit** on nil anchor (up to 24h window)

- **Component / file / symbols:** **Investigation baseline:** `HKAnchoredObjectQuery(…, limit: HKObjectQueryNoLimit, …)` with 24h predicate when `anchor == nil`. **Current tree (B4):** bounded `HKSampleQuery` on nil anchor, anchor establishment query, then incremental anchored path (`WatchState.swift`).
- **Phase:** First successful `setupHealthKitBackgroundDelivery` (deferred **10s** after foreground by Path **A**); also whenever observer fires.
- **Likely memory:** `[HKQuantitySample]` as returned by HealthKit; sorted copy `sortedByDate`.
- **Why large:** **Investigation baseline:** **unbounded** count for 24h if anchor missing. **Current tree:** bootstrap batch capped (64 samples).
- **Confidence:** **High** on historical unbounded API shape; **high** that B4 removes unbounded nil-anchor pull; **medium** on field frequency of bootstrap vs incremental path.
- **Role:** **Primary** when anchor missing/corrupt (**baseline**); **secondary** once anchor persisted (**current**).
- **Mitigation:** **Shipped (B4):** positive limit on bootstrap; anchor establishment; incremental anchored delivery. Optional: further predicate tightening if metrics warrant.

### 5. `TrioMainWatchView` observation of entire `WatchState` + heavy chrome

- **Component / file / symbols:** `@State private var state = WatchState.shared`; toolbar, sheets, `NavigationStack`, `TabView`, symbol effects (`TrioMainWatchView.swift`).
- **Phase:** First frame through steady state.
- **Likely memory:** SwiftUI dependency graph for all fields read in `body` and children; `GlucoseTrendView` shadows and `symbolEffect(.variableColor.iterative, options: .repeating, …)`.
- **Why large:** Broad observation ties unrelated state changes to wider diffing; repeating symbol effects keep animation state.
- **Confidence:** **Medium** (typical SwiftUI cost; not profiled).
- **Role:** **Secondary** baseline amplifier.
- **Mitigation:** Narrow dependency surface (smaller view models / split observable buckets); reduce animated SF Symbols on main screen; lazy sheets.

### 6. `TrioComplicationDataStore` save / reload path (JSON `Data`, backup, `WidgetCenter.reloadTimelines`)

- **Component / file / symbols:** `saveOnMain` encoder `Data`, `snapshot.bak` copy, `latestSnapshot` decoder; `reloadTimeline()` → `WidgetCenter.shared.reloadTimelines` (`TrioComplicationDataStore.swift`); `forceComplicationUpdate` +1s from `WatchState.init`.
- **Phase:** `saveComplicationSnapshot` after state processing; `onAppear` snapshot read; `forceComplicationUpdate` scheduled **1s** after `WatchState` init; sleep-gap reload path.
- **Likely memory:** Transient `Data` for encode/decode; duplicated file on disk; system-side widget extension work **outside this process** but correlated in time.
- **Confidence:** **High** for transient encode/decode; **medium** for system-wide pressure from `reloadTimelines`.
- **Role:** **Secondary** (spiky allocations + system churn).
- **Mitigation:** Avoid redundant `latestSnapshot` reads; batch reloads; skip `forceReload` when snapshot unchanged; reconsider `forceComplicationUpdate` timing on cold launch.

### 7. `WatchLogger` ring buffer, daily file append, and flush materialization

- **Component / file / symbols:** `logs: [String]` max **500**; `appendToDailyLog`; `flushToPhone` `joined` / chunking; `sendLogPayload` duplicate `content` in envelope + on-disk file (`WatchLogger.swift`).
- **Phase:** Continuous from first `log()`; flush when count ≥ **100** or timer **3 min** unless startup gate suppresses; `flushPersistedLogs` at **10s** deferred.
- **Likely memory:** In-memory log strings; joined super-string on flush; per-payload file copy.
- **Why large:** High log volume from connectivity + complication + HealthKit paths; each line includes battery context and location metadata.
- **Confidence:** **Medium** (bounded by 500 lines × line size, but lines can be long).
- **Role:** **Secondary** steady / flush spikes.
- **Mitigation:** Lower `maxEntries` / flush thresholds on watch; shorter log lines; sampling; ensure startup suppression covers all burst sources.

### 8. `WatchErrorReporter.startup` + reading daily log on “previous foreground crash” suspicion

- **Component / file / symbols:** `WatchErrorReporter.startup` → `checkForPreviousCrash` → `readRecentLogs` reads `watch_log_daily.txt` (cap **16 KiB**), builds line array (`WatchErrorReporter.swift`).
- **Phase:** First foreground `handleForegroundActiveEntry` `Task`.
- **Likely memory:** Modest `String` / `[String]`; **only** when prior run flagged foreground without background.
- **Confidence:** **High** for code path; **low–medium** as total footprint contributor.
- **Role:** **Incidental** except in crash-reporting scenarios.
- **Mitigation:** Keep cap; defer until after first frame; stream file tail without full copy.

### 9. `ComplicationLogBuffer` ring (200) + drain files (up to 64 KiB each in memory during send)

- **Component / file / symbols:** `ComplicationLogBuffer` `entries` max **200** (`ComplicationLogBuffer.swift`); `WatchLogger.drainComplicationLogs` / `sendLogContentFromFile` (`WatchLogger.swift`).
- **Phase:** Complication extension appends (separate process); watch drains during `flushPersistedLogs`.
- **Likely memory:** Watch app reads file → `String` up to **64 KiB** per drain send path.
- **Confidence:** **Medium** (bounded, but stacks with other flush work).
- **Role:** **Secondary** during drain bursts.
- **Mitigation:** Drain less aggressively; smaller complication log cap; fewer forwarded `TrioComplicationDataStore.log` lines.

### 10. Duplicate “snapshot vs live state” strings in `WatchState` + complication snapshot

- **Component / file / symbols:** `TrioMainWatchView.onAppear` copies `latestSnapshot()` into `state` fields; `processRawDataForWatchState` updates same fields; `saveComplicationSnapshot` builds `TrioComplicationSnapshot` (`TrioMainWatchView.swift`, `WatchState.swift`, `TrioComplicationDataStore.swift`).
- **Phase:** First frame and first WC update.
- **Likely memory:** Duplicate strings (glucose, trend, delta, color hex) across SwiftUI state and snapshot model; small vs chart payload but persistent.
- **Confidence:** **High** for duplication pattern; **low** as sole jetsam driver.
- **Role:** **Incidental** / minor steady cost.
- **Mitigation:** Single source of truth for display fields; avoid redundant snapshot reads when WC update imminent.

**Consolidated note:** Items **1** and **2** share one **root cause** (288-point history crossing the wire for chart + state). Items **1** and **3** together describe **payload + log string duplication**.

---

## Cross-cutting themes / duplication patterns

1. **Same glucose history in three layers:** Phone `WatchState.glucoseValues` → WC `[[String: Any]]` → watch `pendingData` → `WatchState.glucoseValues` with `Color` → `Charts` series (`AppleWatchManager.swift`, `WatchState.swift`, `GlucoseChartView.swift`).
2. **Logging doubles hot data:** Full `message` stringification (`WatchState.swift`) on top of live dictionaries; phone uploader already acknowledges trimming `glucoseValues` in logs (`CloudLogUploader.swift` comments) — watch should align.
3. **Snapshot and live state:** `latestSnapshot()` on `onAppear` plus incoming WC updates both write display fields (`TrioMainWatchView.swift`, `WatchState.swift`).
4. **Unbounded vs capped history:** Phone caps at **288**; **investigation baseline:** HealthKit nil-anchor path used **`HKObjectQueryNoLimit`** for 24h — **asymmetric risk** vs phone cap (**B4** addresses nil-anchor side in current tree) (`AppleWatchManager.swift`, `WatchState.swift`).
5. **Foreground work vs resident size:** Startup deferral changes **when** network/HealthKit/logging run; it does not automatically shrink **maximum** reachable footprint when payloads arrive.

---

## Immediate instrumentation plan (device)

**Goal:** Separate **baseline** (SwiftUI + empty state) from **deltas** (WC decode, merge, chart render, HealthKit batch, log flush).

1. **Memory timeline (Instruments):** Allocations + Memory Graph on physical watch; mark phases with `os_signpost` or unified logging around:
   - `TrioMainWatchView.onAppear` (before/after `latestSnapshot()`).
   - `processRawDataForWatchState` entry/exit (log `glucoseValues.count` from message).
   - `flushToPhone` / `flushPersistedLogs` entry/exit.
   - `HKAnchoredObjectQuery` resultsHandler (log `samples.count`).
2. **Resident footprint:** Sample `mach_task_basic_info` / `task_vm_info` (or Xcode Memory Gauge) at: cold launch, first frame, +2s deferred refresh fired, first `didReceiveMessage` handled, +10s HealthKit, +10s flush.
3. **Payload sizing:** Log **only** `message.count` (if bridged to NSDictionary, approximate via key enumeration + estimated nested count) or log **`glucoseValues.count`** without printing values — **do not** log full message in production instrumentation.
4. **Charts isolation A/B:** Feature flag to replace `GlucoseChartView` with empty `Color.clear` for one build; compare memory slope on identical WC traffic.
5. **HealthKit A/B:** Log `anchor == nil` vs non-nil when query runs; correlate with sample batch size.

---

## Highest-leverage mitigation candidates (no code in this pass)

1. **Stop logging full WC messages** on watch; log structured metadata only (`WatchState.session(_:didReceiveMessage:)`).
2. **Cap or downsample `glucoseValues`** for watch chart (negotiate with phone payload or trim on watch before storing).
3. **Lazy chart construction** — do not build `GlucoseChartView` until page selected (mirror debug page gating pattern).
4. **HK anchored query:** replace `HKObjectQueryNoLimit` with a **small positive limit** until anchor is established.
5. **Review `forceComplicationUpdate` +1s timer** from `WatchState.init` for interaction with foreground jetsam (reload + I/O + logs).

---

## Open questions / unknowns

1. **Actual size of WC-deserialized message** on device (bridging overhead) vs Swift-native model — needs Instruments.
2. **Whether `TabView` eagerly instantiates off-screen pages** on watchOS for this view hierarchy — affects chart cost at first frame (**unknown** without runtime test).
3. **Typical `HKAnchoredObjectQuery` batch size** for your CGM when anchor is nil or after decode failure — could dwarf 288 points (**unknown**).
4. **How often `didReceiveApplicationContext` delivers a full `watchState` relative to foreground** — can overlap with deferred refresh (**behavioral**).
5. **Jetsam category attribution:** `per-process-limit` vs `highwater` vs others — **both** former strings now appear in **archived** `.ips` alongside this doc set (see **00** § 4 and **04** § Jetsam reason strings); interpreting **spike** vs **steady** resident as the dominant trigger still needs **profiling / instrumentation**, not reason strings alone.

---

## Adversarial review (second pass)

**Overclaims corrected:**

- This document **does not** prove Charts is “the” top allocator; it flags **chart + 288 points** as a **plausible** major consumer — **must be validated** with instrumentation.
- `WidgetCenter.reloadTimelines` primarily stresses **other processes**; included here as **system-level amplifier**, not necessarily watch app RSS.

**Missed consumers initially considered then added:**

- `pendingData.merge(payload)` on **`didReceiveUserInfo`** when connectivity tasks are pending — can retain **another** full copy of the payload alongside the in-flight WC object graph.
- `WatchLogger` **stringification of `message`** — easy to underestimate vs chart data; can be comparable when logs hold full arrays.

**Items deliberately not ranked as top 10:** Core SwiftUI layout for small views, individual `DateFormatter` instances in hot paths, `UserDefaults` pending payload arrays — non-trivial but **secondary** to 288-point arrays and unbounded HK batches.

---

## Appendix — device jetsam diagnostics (reference)

Sibling files in `docs/in-progress/watch-launch-stability/` (not code):

- [JetsamEvent-2026-04-01-143500.ips](JetsamEvent-2026-04-01-143500.ips) — Trio `reason`: **`per-process-limit`**
- [JetsamEvent-2026-04-03-164956.ips](JetsamEvent-2026-04-03-164956.ips) — Trio `reason`: **`highwater`** (`active` / `frontmost`)
- [JetsamEvent-2026-04-03-165709.ips](JetsamEvent-2026-04-03-165709.ips) — Trio `reason`: **`per-process-limit`**
- [JetsamEvent-2026-04-03-230456.ips](JetsamEvent-2026-04-03-230456.ips) — Trio `reason`: **`per-process-limit`** (see **Observation log** at end of document)

Canonical summary table: [04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md) § Jetsam reason strings.

---

## Appendix — files and symbols inspected

**Watch app extension**

- `Trio Watch App Extension/TrioWatchApp.swift` — `@main`, `scenePhase`, `WatchNotificationHandler`, `handleForegroundActiveEntry`.
- `Trio Watch App Extension/ExtensionDelegate.swift` — `applicationDidFinishLaunching`, `applicationDidBecomeActive`, `handle(_ backgroundTasks:)`.
- `Trio Watch App Extension/WatchState.swift` — `init`, `setupSession`, startup deferral, WC delegates, `pendingData`, `scheduleUIUpdate`, `processRawDataForWatchState`, HealthKit queries, `saveComplicationSnapshot`, `forceComplicationUpdate`, `forceWidgetReloadIfStale`, `loadFallbackDataFromComplication`, `resolveEffectiveCGMReadingDate`.
- `Trio Watch App Extension/WatchState+Requests.swift` — `requestWatchStateUpdate`.
- `Trio Watch App Extension/WatchLogger.swift` — `WatchStartupTransportGate`, actor state, `flushToPhone`, `flushPersistedLogs`, `drainComplicationLogs`, `sendLogContentFromFile`.
- `Trio Watch App Extension/WatchErrorReporter.swift` — `startup`, `readRecentLogs`.
- `Trio Watch App Extension/WatchStateSnapshot.swift` — snapshot DTO.
- `Trio Watch App Extension/Views/TrioMainWatchView.swift` — `TabView`, `onAppear`, snapshot hydrate.
- `Trio Watch App Extension/Views/GlucoseChartView.swift` — `Charts`, `PointMark`, `filteredValues`.
- `Trio Watch App Extension/Views/GlucoseTrendView.swift` — main face UI.
- `Trio Watch App Extension/Helper/WatchNotificationHandler.swift` — notification categories.

**Watch shared**

- `Trio Watch Shared/TrioComplicationDataStore.swift` — `saveOnMain`, `latestSnapshot`, reload ring, HealthKit anchor keys.
- `Trio Watch Shared/ComplicationLogBuffer.swift` — ring buffer, file append (widget), drain contract.

**iPhone (payload size evidence)**

- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` — `fetchGlucose` `fetchLimit: 288`, `watchStateToDictionary`.
- `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift` — references trimming `glucoseValues` in logged watch strings (context for logging hazard).

---

## Observation log — build 149 field report, jetsam `2026-04-03 23:04`, Better Stack (2026-04-03)

This section records **post–doc-1.4** device behavior, a new archived jetsam diagnostic, and **Better Stack** queries against the Trio logs source. It does **not** supersede the code-review / ranked-consumer analysis above; it adds **field correlation** for the same symptom class (foreground open → return to clock face).

### Field report (build 149, deployed)

- **Observed UX:** The watch app **opens**, shows a **syncing data** indicator, then the system **returns to the clock face** after **almost exactly ~5 seconds**.
- **Build:** **149** (user-reported; shipped after Path **B1** / **B4** mitigations documented in [02-startup-load-shedding-implementation-plan.md](02-startup-load-shedding-implementation-plan.md) § Implementation log).
- **Interpretation (non-clinical):** The **~5 s** wall-clock timing remains **compatible with** both (a) the historical **~5 s `WCSession` / connectivity timeout** narrative tied to `WatchLogger` (`2e3db70f5` in [00-investigation-findings.md](00-investigation-findings.md)) **and** (b) **jetsam** after resident growth on the **foreground** path — the two are **not mutually exclusive**. Path **A**’s **2 s** deferred first refresh means a **≥ ~2 s** window before the first coordinator-owned phone request fires; a **~5 s** user-visible “syncing” stall can still fit **either** jetsam **or** a reply/transport stall **unless** device diagnostics distinguish them.

### Jetsam diagnostic — [JetsamEvent-2026-04-03-230456.ips](JetsamEvent-2026-04-03-230456.ips)

**Device / OS (from file header):** `Watch6,15`, **watchOS 26.3** (`23S620`). **Timestamp:** `2026-04-03 23:04:56.48 +0200` (local). **Equivalent UTC (for log correlation):** `2026-04-03 21:04:56` (approximately).

| Field | Value |
|--------|--------|
| `largestProcess` | **`Trio Watch App`** |
| `memoryStatus.pageSize` | **16384** (16 KiB pages) |
| `memoryStatus.memoryPages.free` at snapshot | **2293** pages → **~37.6 MiB** free (× 16 KiB) |

**`Trio Watch App` process rows** in this snapshot (multiple generations listed; all relevant rows show **`reason`: `per-process-limit`**):

| `rpages` | `states` | Approx. resident (rpages × 16 KiB) |
|---------|----------|-------------------------------------|
| 19430 | `active` | **~304 MiB** |
| 19308 | `active` | **~301 MiB** |
| 21686 | `active`, **`frontmost`** | **~339 MiB** |

**Takeaway:** This capture is **another `per-process-limit` jetsam** on **foreground-class** process state (`active`, and **`frontmost`** on the largest `rpages` line), with **resident pages in the same ~300–340 MiB band** as earlier archived events referenced in [00-investigation-findings.md](00-investigation-findings.md) § 4. It **supports** treating **memory-budget closure** as an ongoing failure mode for **build 149** alongside any **timeout-shaped** telemetry.

### Better Stack — Trio source, watch logs, build **149**

**Source:** Trio logs (`table` **`t491594.trio`**, `source_id` **1659391**). **Extraction:** `JSONExtract(raw, 'platform', …)`, `JSONExtract(raw, 'build', …)`, `JSONExtract(raw, 'message', …)` on `raw`.

**Findings (queries run 2026-04-03 ~23:11 CET):**

1. **`platform = watchos`, last ~6 hours (`remote(t491594_trio_logs)`):** **233** rows; **`GROUP BY build` → only `148`** — **no rows** with **`build = '149'`** in the hot window.
2. **`platform = watchos`, calendar day `2026-04-03` (`remote` ∪ `s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`):** **8702** rows; **`GROUP BY build` → only `148`** — again **no `149`** in the structured `build` field for watch logs in that day bucket.
3. **Latest `watchos` row on `2026-04-03` in S3 for the sampled day:** **`2026-04-03 20:12:52`** UTC, **`build=148`** (`event=complication_get_timeline_called`, …). **No `watchos` rows** appeared in S3 samples for **that UTC day** with **`dt` after ~20:12** (hourly histogram for `watchos` on `2026-04-03` shows **no events in hour ≥ 21 UTC**).
4. **Phone-side (`platform = ios`) around `20:59` UTC (hot tier):** Rows such as **`Watch is not reachable (activationState: 2)`**, **`Setup WatchState - … values: 288`**, and (earlier in the same window) **`WCSession sendMessage timed out context=drain`** — **corroborate stress on the phone↔watch pipe** but **do not** replace watch-native crash/jetsam attribution.

**Caveats:** If build **149** logs use a **different `raw.build` encoding** (or the watch process dies before flush), telemetry may **under-report** build 149. **Silence** of `watchos` rows after **~20:12 UTC** on `2026-04-03` in S3 may reflect **kills**, **reachability**, **ingestion lag**, or **clock skew** vs the diagnostic’s **`+0200`** timestamp — treat Better Stack as **supporting evidence**, not a complete forensic timeline.

---

## Changelog

### v1.6 (2026-04-06 15:48 CET)

- **Executive summary:** **Post-investigation implementation** paragraph — **B3** lazy chart, **B1**/**B4**, TestFlight **152** field outcome. **Launch-path map** steps **7** and **13** split **investigation baseline** vs **current tree**. **Ranked #2, #3, #4**, structures table, and cross-cutting theme **4** updated for shipped mitigations vs baseline wording.

### v1.5 (2026-04-03 23:11 CET)

- **Observation log:** Documented **build 149** field report (syncing UI → **~5 s** return to clock face), analysis of **[JetsamEvent-2026-04-03-230456.ips](JetsamEvent-2026-04-03-230456.ips)** (`per-process-limit`, **`largestProcess` = Trio Watch App**, **~301–339 MiB** resident band, **`frontmost`** on largest line), and **Better Stack** query results: **no `watchos` + `build=149`** rows in sampled hot + S3 day aggregates; last sampled **`watchos`** log **`2026-04-03 20:12:52` UTC** with **`build=148`**; phone-side **288-value WatchState** / **not reachable** / **drain timeout** corroboration noted with caveats.

### v1.4 (2026-04-03 21:56 CET)

- **Jetsam evidence:** Added appendix listing **three** `JetsamEvent` `.ips` references; tightened open question **5** now that **`highwater`** and **`per-process-limit`** both appear in **captured** diagnostics (spike vs steady remains instrumentation-dependent).

### v1.3 (2026-04-03 21:39 CET)

- Renamed launch-path map **Phase A–G** → **Step 1–7** and added explicit disambiguation from planning **A1–A3 / B0–B5** (ChatGPT polish). Linked **[04-watch-foreground-memory-hardening-design.md](04-watch-foreground-memory-hardening-design.md)** in related docs.

### v1.2 (2026-04-03 21:19 CET)

- Aligned the related-docs blurb and executive-summary Path A/B framing with parent docs: **Path B primary**, **Path A parallel**; added explicit **Status: Final** for this investigation artifact.

### v1.1 (2026-04-03 21:01 CET)

- Cross-linked parent docs after they adopted **Path A / Path B** naming; clarified this document as the primary **Path B** investigation input and labeled the in-tree startup deferral section as **Path A**.

### v1.0 — 2026-04-03 20:48 CET

- Initial publication: launch-path map, top-10 ranked memory consumers with evidence vs inference, instrumentation plan, mitigations, adversarial review, appendix.
