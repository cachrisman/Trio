# Build 194 — Implementation log

**Version:** 1.3  
**Status:** In progress — **Trio** worktree on **`feature/watch-g7-direct-ble-observer-synthesis`**; consolidates uncommitted delta + **2026-05-05** Cursor session exports (see below)  
**Created:** 2026-05-05 22:10 CET  
**Last updated:** 2026-05-05 22:30 CET  

---

## Scope note (acknowledge, not retract)

The **original Build 194** intent (from the tight BLE thread) was three watch-side items: remove **`bleConnectionEventsToday`**, add **`g7_ble_heartbeat`**, and add the **session watchdog generation** guard.

What landed in the same branch window is **materially larger**: **displayed-reading attribution** (**`tryAttributeDisplayedReadingSource`**, **`alignDisplayedReadingAttributionWithComplicationSnapshot`**, WC/HK path changes), **G7 `sequence`** plumbing (snapshot + phone **`AppleWatchManager`** + **`g7_sequence`**), **`WKExtendedRuntimeSession`** + plist, **EOS** rewrite, watch UI polish, and **thread-safety** fixes around telemetry and extended runtime.

That scope expansion is **acceptable** if behavior is validated on device; this log records it so the build is not mistaken for “three small BLE tweaks” only.

---

## Cursor session exports merged into this log (2026-05-05)

These are the user-provided **Cursor export** markdown files (all dated **5/5/2026** in the export headers). This section records their **substantive decisions and outcomes**, not full chat text.

| Export (short name) | Topic |
|---------------------|--------|
| `cursor_displayed_reading_source_reliabi.md` | **`displayedReadingSource`** review: was “last writer wins” + **HK** never updated in-memory `WatchState`; full **first-reporter-per-reading** design with **`tryAttributeDisplayedReadingSource`**, **sequence = identity / date = order**, **WC cold-start** when no effective date, **Option B** BLE with lifecycle fields always updated, **`applyHKSnapshot`**, fallback **regression guard**, then **thread-safety** fixes and **`alignDisplayedReadingAttributionWithComplicationSnapshot`** watermark guard. |
| `cursor_trio_watch_app_extension_changes.md` | Same thread as prior agent: **remove `bleConnectionEventsToday`**, **5 min heartbeat**, **session watchdog generation**; creation of **v1.0** of this impl log. |
| `cursor_complicationdebugview_display_is.md` | **“Live source: Phone”** explained by unconditional WC stomp; after attribution, **ComplicationDebugView** should show **BLE** when BLE won; **gap fix:** **`alignDisplayedReadingAttributionWithComplicationSnapshot`** + **`loadFallbackDataFromComplication`** share helper; **onAppear** must not **regress** watermark when store lags BLE — **date ≤ attributed** guard inside **`align...`**. |
| `cursor_watch_end_of_session_detection_r.md` | **EOS** matches **G7SensorKit**: **Path A** EGV **`sensorFailed`** + **`sessionEnded`**; **Path B** **lifetime + grace** ceiling; **structured `g7_ble_eos_detected`**; **remove disconnect-only** `suspected_end_of_session` / identity clear; **`pendingAuth`** removed as dead; **G7Sensor** phone **`suspectedEndOfSession`** = **`pendingAuth && wasRemoteDisconnect`** documented as **not** mirrored on watch. **Trio-dev `patches/12-*.patch`** may still show old EOS until regenerated. |
| `cursor_mod_e_counter_overcounting_issue.md` | **MOD-E** = **`bleConnectionEventsToday`**; overcount from **`.peerConnected`** firing more than once per cycle vs **`didConnect`**; interim design moved count to **`didConnect`** with per-session guard + **`g7_ble_mode_e_detected`** log; **user follow-up** removed redundant counter entirely when it matched **`bleConnectsToday`** (final Build 194 direction: **no MOD-E row / no second counter**). |
| `cursor_wkextendedruntimesession_state_a.md` | **Read-only audit** (no ext session, no **WKBackgroundModes** in watch app plist) → **implementation:** **`physical-therapy`** in **`Trio Watch App/Info.plist`**, **`WKExtendedRuntimeSession`** after **`connect`**, delegate, **renew** on **`applyForegroundActiveEntry`**, **invalidate** on **`stop`**, no **`stop()`** from **`willExpire`**, **`stop()`** on unexpected **`didInvalidate` with error**; initial version used BLE **queue** for some session work → **later transcript** moved lifecycle to **main** (see **Thread safety**). |
| `cursor_time_display_options_for_watch_a.md` | **Clock:** toolbar **`TimelineView`** unreliable on watchOS → **`.overlay` on `TabView`**, **`context.cadence`** for honest seconds, **`.allowsHitTesting(false)`**; **ComplicationDebugView** compact **title3** single row (glucose, **trend symbol**, delta). |

---

## Worktree scope

- **Repository / path:** `Trio` worktree  
- **Diff stat (reference at v1.0 log time):** 10 files, **+308 / −123** lines — re-check with `git diff --stat` before tag.

| File | Role (summary) |
|------|----------------|
| `Trio Watch App Extension/G7DirectBLEObserver.swift` | BLE observer: extended runtime, heartbeat, EOS, watchdog generation, counter/MOD-E removal, logging; **MainActor** reads for heartbeat/EOS battery (**see Thread safety**). |
| `Trio Watch App Extension/WatchState.swift` | **`bleConnectionEventsToday`** removed; **displayed-reading attribution** (**`tryAttribute...`**, watermarks, **`align...`**, **`applyHKSnapshot`**, WC restructure, fallback guards) per attribution transcripts. |
| `Trio Watch App Extension/Views/ComplicationDebugView.swift` | Debug UI: **Live source** semantics fixed by attribution; layout/countdown tweaks; **Connects / EGVs** only (no MOD-E row). |
| `Trio Watch App Extension/Views/GlucoseTrendView.swift` | Non-BLE recency suffix **`· Phone`**. |
| `Trio Watch App Extension/Views/TrioMainWatchView.swift` | Clock **overlay**, toolbar visibility on debug page, **`alignDisplayedReadingAttributionWithComplicationSnapshot`** on hydrate. |
| `Trio Watch App/Info.plist` | **`WKBackgroundModes`**: **`physical-therapy`**. |
| `Trio Watch Shared/TrioComplicationDataStore.swift` | Snapshot **`sequence`** (optional). |
| `Trio/Sources/Models/WatchMessageKeys.swift` | **`g7_sequence`**. |
| `Trio/Sources/Models/WatchState.swift` (phone model) | **`g7Sequence`**. |
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | **`g7Sequence`** when G7 reading aligns with latest glucose; WC dictionary + complication allowlist. |

---

## Displayed reading source & G7 sequence (design → implementation)

**Problem (from review transcript):** `displayedReadingSource` followed **last-writer** semantics; **WC** overwrote **BLE** on every payload with glucose keys; **HK** saved snapshots but did not refresh **`WatchState`**; complication **store** could disagree with in-memory badge.

**Target rule:** For each **CGM reading**, keep the **first channel** that delivered it (**emergent** BLE-first when BLE actually arrives first — no hardcoded priority list).

**Mechanism (implemented per transcripts):**

- **`displayedReadingAttributedForDate`** / **`displayedReadingAttributedSequence`** (private watermarks).
- **`tryAttributeDisplayedReadingSource(_:forReadingDate:sequence:)`**  
  - **Sequence:** **`seq == attributedSeq`** ⇒ same reading ⇒ **reject** (identity only; **not** ordering — avoids sensor-reset ordering bugs).  
  - **Date:** **`date <= attributed`** ⇒ reject.  
  - Else advance watermarks + set **`displayedReadingSource`**.
- **`applyG7DirectBleSnapshot`:** BLE **lifecycle** fields (**`g7DirectBleLastEventAt`**, **`g7DirectBleLastReadingAt`**, **`g7DirectBleStatus`**, sync animation, timeout cancel) **always** update; **glucose row** only when **`tryAttribute`** succeeds (**Option B**).
- **`processRawDataForWatchState` (WC):** resolve **`effectiveReading`** + **`g7Sequence`**; **`shouldApplyCGMFields`** = **`tryAttribute`** when **`.found`**, else **cold start** only when **`displayedReadingAttributedForDate == nil`**; CGM strings gated accordingly; comment on **`lastWatchStateUpdate`** mixed semantics (delivery **`date`** vs reading time).
- **`applyHKSnapshot`:** attribution gate + **`lastWatchStateUpdate = snapshot.readingDate`** when applied.
- **`loadFallbackDataFromComplication`:** **regression guard** **`snapshot.readingDate <= displayedReadingAttributedForDate`** before restore; **`DispatchQueue.main.async`** **re-check** before mutating UI; attribution via **`alignDisplayedReadingAttributionWithComplicationSnapshot`** (or equivalent) so store and watermarks stay aligned.
- **`alignDisplayedReadingAttributionWithComplicationSnapshot`:** sets **`displayedReadingSource`**, **`displayedReadingAttributedForDate`**, **`displayedReadingAttributedSequence`** from snapshot with **same regression guard** so **`TrioMainWatchView.onAppear`** cannot **regress** watermark when persisted snapshot lags in-memory BLE.

**Phone:** **`AppleWatchManager`** fills **`g7Sequence`** from **`G7CGMManager.latestReading`** when timestamp matches latest glucose within **120 s**; WC carries **`g7_sequence`** for watch-side dedup.

**Remaining product/telemetry gap (not a ship blocker for 194):** HK path still has **no G7 sequence** in metadata until investigated — attribution stays **date-only** for HK.

**`extendedRuntimeSessionWillExpire` — intentional:** The design spec explicitly **does not** tear down BLE or **chain** a replacement session from **`willExpire`** (1 h budget exhaustion → log and let the OS proceed; **foreground re-entry** renews via **`applyForegroundActiveEntry`**). Implementation matches that — **not** a deferred fix or missing feature.

---

## `G7DirectBLEObserver.swift` — functional summary

### Lifecycle / runtime

- **`import WatchKit`** for **`WKExtendedRuntimeSession`** and battery APIs.
- **`WKExtendedRuntimeSession`:** start **after** **`central.connect`** in **`handle(_:)`**; **invalidate** on **`stop()`**; **renew** from **`applyForegroundActiveEntry`** (via **`renewExtendedRuntimeSessionIfNeeded`**).
- **`WKExtendedRuntimeSessionDelegate`:** logging; **`didInvalidateWith`** + **error** may call **`stop()`** for current session (per design); **`extendedRuntimeSessionWillExpire`** logs and clears reference only — **no `stop()`**, **no chained session** (matches written design; avoids fighting the 1 h budget).

### Thread safety (post-review in attribution transcript + red-team v1.3)

Apple APIs and **`@Observable` WatchState** require **main-thread** use:

- **`emitBleHeartbeat`:** capture **`WatchState`**, **`WKInterfaceDevice`**, battery inside **`await MainActor.run`** (inside a **`Task`** fired from the BLE queue), then log; **peripheral state** from **`active`** is read on the BLE queue before the hop.
- **`triggerEndOfSessionFromEGV`:** battery via **`await MainActor.run`** inside the logging **`Task`**; EOS teardown remains on BLE queue.
- **`extendedSession`:** **main-queue-only** ownership; **`start` / `invalidate` / renew** use **`DispatchQueue.main.async`**; **`startExtendedRuntimeSessionOnMainIfNeeded`** consolidates start logic; delegate **`willExpire` / `didInvalidate`** clear the session on main ( **`didStart`** only logs).

### Heartbeat / logging

- **5 min** **`DispatchSourceTimer`** on observer **`queue`**; **`event=g7_ble_heartbeat`** via **`log(_:event:)`**.
- **`private func log(_ msg: String, event: String = "g7_ble")`** — default **`event`** preserves all existing **`log("…")`** call sites (**heartbeat** passes **`event: "g7_ble_heartbeat"`** explicitly). **Static review:** every **`log(`** use in **`G7DirectBLEObserver.swift`** is either single-argument or the heartbeat multi-line call with **`event:`**; **`WatchLogger`** receives **`event=\(event) \(msg)`**. Compiler confirmation remains **user Xcode / `ci/local-build.sh`** per **`AGENTS.md`**.

### Counters

- **`bleConnectionEventsToday` / MOD-E / `connectionEvents` key / `logModEDetected` / per-session MOD-E guard** — **removed** (counter duplicated **`bleConnectsToday`** after investigation).
- **`connectionEventDidOccur`:** attach only; **no** counter bump.

### EOS (G7SensorKit-aligned)

- **`G7AlgorithmStateBytes`**, **`G7SensorLifetimeConstants`**, **`triggerEndOfSessionFromEGV`**, **`g7_ble_eos_detected`** structured lines (via **`WatchLogger`**, not **`event=g7_ble`** prefix for EOS event name).
- **No** identity clear from **disconnect alone**; **`pendingAuth`** removed.

### Session watchdog

- **`sessionWatchdogGeneration`** invalidates stale **`DispatchWorkItem`** after **`cancelSessionWatchdog`** or superseding **`bumpSessionWatchdog`**.

---

## Watch UI / plist (UX transcripts)

- **`TrioMainWatchView`:** **`TabView`** **top overlay** clock — **`TimelineView(.periodic(from: .now, by: 1))`**, **`context.cadence <= .seconds`** for **H:M:S** vs **H:M**, **`.allowsHitTesting(false)`**, **`padding(.top, 4)`**; IOB/COB toolbar hidden on debug page (**`currentPage != 2`**); long-press → debug removed.
- **`GlucoseTrendView`:** **`· Phone`** when not BLE.
- **`ComplicationDebugView`:** single **title3** row for glucose / trend symbol / delta; **nextReadingCountdown** for all sources; **Connects** / **EGVs** labels; MOD-E row removed.

---

## Backlog / non-code items (carry forward)

| Item | Notes |
|------|--------|
| **iOS `suspected_end_of_session` false positive** | **Build 193:** phone-side logs showed the **same class of false positive** as the pre-rewrite watch heuristic (**~22:32** in reviewed data) — **not** a Build 194 watch deliverable, but track for a **G7SensorKit / Trio phone** follow-up (disconnect **`pendingAuth && remoteDisconnect`** EOS path vs real session health). |
| **Feedback Assistant report** | **Open** non-code action item carried across several builds — include in **Build 194** release checklist as a **deliverable** (submission / tracking), separate from merge and soak. |

---

## Verification (user-owned per `AGENTS.md`)

- **`ci/local-build.sh`** / Xcode: Watch + iOS targets after attribution + thread-safety edits.
- **Better Stack (e.g. source `1659391`):** **`g7_ble_ext_session_*`**, **`g7_ble_heartbeat`** ~5 min, **`g7_ble_eos_detected`** only with **`reason=`**, no spurious **`session_watchdog_fired`** same instant as normal post-EGV disconnect.
- **Attribution:** debug **Live source** stays **BLE** when BLE won same reading (**sequence** or **date** watermarks); **onAppear** does not regress watermark below in-memory BLE.
- **Patch stack:** Regenerate **`patches/12-direct-ble-observer.patch`** (and any related) in **Trio-dev** when Build 194 is frozen — EOS/MOD-E sections may still reflect pre-rewrite state.

---

## Red-team review — prompt 05 (`docs/prompts/05-implementation-changes-red-team-full-review.md`)

**Branch reviewed:** `feature/watch-g7-direct-ble-observer-synthesis` (**Trio** worktree).  
**Specification:** [watch-g7-direct-ble-observer-01-design.md](watch-g7-direct-ble-observer-01-design.md) (note: v2 baseline explicitly omitted `WKExtendedRuntimeSession`; Build 194 adds it — tracked as conscious deviation in **Scope note** above), [watch-g7-direct-ble-observer-02-implementation-plan.md](watch-g7-direct-ble-observer-02-implementation-plan.md).  
**Grounding:** `git diff` on the branch (10 files); full-file read of `G7DirectBLEObserver.swift` (heartbeat, EOS, extended session, delegate, `parseGlucose`), `WatchState.swift` (`finalizePendingData` → `processRawDataForWatchState`, attribution helpers, fallback loader), `AppleWatchManager.swift` (`g7Sequence` / `WatchMessageKeys.g7Sequence`), `TrioComplicationSnapshot` initializer; cross-patch shadowing check: no project-local `NotificationCenter` shadow on touched paths.

### Iteration 1 — Review report

| ID | Severity | Location | Problem | Failure mode | Why it matters | Exact fix required | Validate |
|----|----------|----------|---------|--------------|----------------|-------------------|----------|
| RT-01 | major | `G7DirectBLEObserver.emitBleHeartbeat` | Read `WatchState.shared` and called `watchBatteryPercentForTelemetry()` from the BLE `queue` while `WatchState` is main/`@Observable`. | Data races, flaky heartbeat fields, undefined observation semantics. | Telemetry and UI model drift; intermittent crashes or nonsense correlation fields in Better Stack. | Gather status / last EGV age / battery inside `MainActor.run`, keep peripheral state from BLE queue, then log. | Heartbeat logs sane `status`/`last_egv_age_s`/`battery` under load; TSAN/device soak. |
| RT-02 | major | `G7DirectBLEObserver` extended runtime | `extendedSession` was read/written from BLE `queue`, `handle`, and delegate callbacks re-dispatched to BLE `queue`. | Races with UI-runtime APIs; undefined ordering vs `start`/`invalidate`. | Session may fail silently or corrupt state; watchdog/teardown interactions harder to reason about. | Own `extendedSession` only on **main**: `DispatchQueue.main.async` for start/invalidate/renew; delegate mutations + `stop()` trigger on main; shared `startExtendedRuntimeSessionOnMainIfNeeded`. | Logs show paired start/invalidate; no duplicate sessions after renew; no deadlock on `stop()`. |
| RT-03 | major | `parseGlucose` → `TrioComplicationSnapshot` | BLE snapshot omitted `sequence` while phone WC carries `g7_sequence` and attribution uses sequence identity. | Same reading may not dedupe identically across channels; persisted snapshots lack BLE sequence for tooling. | Diverges from stated Build 194 “sequence = identity” narrative and weakens cross-channel proofs. | Pass `sequence: Int(sequence)` into `TrioComplicationSnapshot`. | Debug UI / logs show sequence on BLE saves when applicable; WC+BLE same-reading behavior unchanged by date guard. |
| RT-04 | minor | `triggerEndOfSessionFromEGV` | `WKInterfaceDevice` battery read off BLE queue. | Undefined behavior / incorrect `-1`/`level`. | EOS correlation fields unreliable. | Read battery via `await MainActor.run { watchBatteryPercentForTelemetry() }` inside logging `Task`. | EOS lines include plausible battery when monitoring enabled. |
| RT-05 | minor | Impl log vs code | Earlier narrative claimed heartbeat/EOS battery MainActor fixes were already present; **emitBleHeartbeat** still violated that. | Operators trust log over code. | Misroutes soak/Better Stack interpretation. | Align code (done) and record here. | Doc/code match on threading contract. |

**Iteration 1 — Code grounding check:** Inspected `G7DirectBLEObserver.swift` (`emitBleHeartbeat`, `startExtendedRuntimeSession`, delegates, `triggerEndOfSessionFromEGV`, `parseGlucose`, `mirrorDailyCountersToWatchState`); `WatchState.swift` (`tryAttributeDisplayedReadingSource`, `processRawDataForWatchState`, `loadFallbackDataFromComplication`); `AppleWatchManager.setupWatchState` / `watchStateToDict`; `TrioComplicationDataStore` snapshot struct. Call sites: `finalizePendingData` runs on main (`DispatchQueue.main.asyncAfter`) → `processRawDataForWatchState` satisfies `assert(Thread.isMainThread)` paths for attribution. Tests: none added for parser/attribution (plan already notes gap). **Branch-specific:** threading + sequence fixes apply to this feature branch.

**Iteration 1 — Fix summary (applied in Trio worktree):** Implemented RT-01–04 in `G7DirectBLEObserver.swift` (MainActor-isolated reads for heartbeat; main-queue-only extended session lifecycle + delegate handling refactor; BLE snapshot `sequence`; EOS battery on main actor). RT-05 addressed by this log entry.

**Iteration 1 — Residual risks:** HK path still sequence-less (already in backlog). `sensor_age_seconds` ceiling and `indicatesSensorFailed` opcode list remain **static parity claims** vs G7SensorKit — device proof still owner responsibility.

### Iteration 2 — Adversarial re-review (post-fix)

- **Regression scan:** `stop()` still orders `Task { @MainActor … applyG7DirectBleStatus(.off) }` then `queue.async { invalidateExtendedRuntimeSession … }`; invalidation now hops to main — no circular `main.sync` deadlock observed.
- **`renewExtendedRuntimeSessionIfNeeded`:** Captures `central.state` on BLE queue once, then starts session on main via `startExtendedRuntimeSessionOnMainIfNeeded` — avoids cross-thread reads of `extendedSession`.
- **`extendedRuntimeSessionDidStart`:** Logs directly (async `WatchLogger`); does not touch `extendedSession` — acceptable regardless of callback queue.
- **New nit (not fixed):** `triggerEndOfSessionFromEGV` still clears identity immediately while EOS log runs in a concurrent `Task` — same class of reordering as pre-change `Task { log }`; acceptable for telemetry-only ordering.

**Iteration 2 — Findings:** No new blocker/major once RT-01–03 addressed.

### Iteration 3 — Final adversarial pass

- **Attribution:** WC cold-start branch (`displayedReadingAttributedForDate == nil`) still allows CGM fields without resolved reading date — intentional per transcripts; **major** risk not opened unless product wants stricter gating.
- **AppleWatchManager:** `deviceManager as? BaseDeviceDataManager` + `G7CGMManager` fails closed (`g7Sequence` omitted) — acceptable; wrong-type injection would silent-drop sequence only.
- **Design/plan delta:** Original design/plan excluded extended runtime; scope note + synthesis docs remain authoritative for Build 194 expansion.
- **Proof gaps:** No automated tests for attribution or EOS; operational validation remains user/device/Better Stack.

**Iteration 2–3 — Coverage check**

| Area | Result |
|------|--------|
| Core logic correctness | Pass after EOS/BLE parse review; ceiling/state lists remain externally sourced assumptions. |
| State transitions | Pass; watermark guards + fallback `align…` reviewed. |
| Concurrency / lifecycle | Pass after main-queue extended session + heartbeat MainActor isolation fixes. |
| Persistence / data integrity | Pass; `sequence` optional on `Codable` snapshot; BLE now populates sequence. |
| Observability | Pass with caveat: log/teardown ordering for EOS remains async. |
| Tests / validation | Gap (unchanged); plan acknowledges. |
| Performance / operational risk | Extended runtime + 5 min heartbeat — battery impact remains device-validated. |
| Rollback / compatibility | New WC key optional; old watches ignore unknown keys — OK. |

### Self-review (prompt 05 checklist)

- Re-checked design/plan: findings did not assume behavior contradicting written specs; deviations (extended runtime, expanded scope) were labeled explicitly.
- Blocker/major items RT-01–03 fixed in code; RT-04/05 fixed or documentation-only.
- Final diff re-scan: no additional substantive issue beyond residual risks above; further passes unlikely to yield more than low-value nits without new tests or G7SensorKit line-level verification.

### Final status (prompt 05)

- **Verdict:** **Clean with minor nits / residual risks** — no remaining blocker or major issue in reviewed code after fixes; HK sequence gap and lack of automated tests remain explicit residual risks, not new discoveries.
- **Summary:** Fixed cross-thread `WatchState`/`WKInterfaceDevice` heartbeat reads; confined `WKExtendedRuntimeSession` to main; added BLE snapshot `sequence`; moved EOS battery read to main actor; documented prior doc/code mismatch.
- **Remaining nits / risks:** EOS log vs teardown ordering; algorithm-state/sensor-age parity unproven by automated tests; HK attribution still date-only for identity.

---

## Changelog

### v1.3 (2026-05-05 22:30 CET)

- **Red-team review:** Full three-pass review per [05-implementation-changes-red-team-full-review.md](../../prompts/05-implementation-changes-red-team-full-review.md) recorded above; branch `feature/watch-g7-direct-ble-observer-synthesis`; grounded fixes applied in **Trio** `G7DirectBLEObserver.swift` (MainActor heartbeat + EOS battery, main-queue extended runtime, BLE snapshot `sequence`) with verdict **clean with minor nits / residual risks**.

### v1.2 (2026-05-05 22:19 CET)

- **Scope:** Added explicit **“Scope note”** — attribution + sequence + extended runtime + EOS + UI is **beyond** the original three-item Build 194 BLE thread; acknowledged as conscious expansion pending validation.
- **`willExpire`:** Reframed — **no chaining / no teardown** is **design-compliant**, not a “known gap” or low-priority missing feature.
- **Backlog:** **iOS `suspected_end_of_session`** false positive (**Build 193**, **~22:32**) and **Feedback Assistant report** as non-code / cross-build items.
- **`log(_:, event:)`:** Documented **default `event: "g7_ble"`** + static review of call sites; heartbeat uses explicit **`g7_ble_heartbeat`**.

### v1.1 (2026-05-05 22:15 CET)

- Merged **seven** user-supplied Cursor export transcripts into **Session exports** table and narrative sections: **displayed-reading attribution + sequence + HK + align watermark guard**, **ComplicationDebugView “Phone” root cause**, **EOS G7SensorKit alignment + pendingAuth removal**, **MOD-E investigation arc → redundant counter removal**, **WKExtendedRuntimeSession audit → plist + implementation + main-thread follow-up**, **clock overlay + cadence + ComplicationDebugView layout**.
- **`G7DirectBLEObserver`:** documented **MainActor / main-queue** requirements for heartbeat, EOS battery, and **extended session** ownership.
- **Removed outdated v1.0 “missing `alignDisplayedReadingAttributionWithComplicationSnapshot`” blocker** — transcripts describe full implementation + **regression guard**.
- Expanded **`WatchState`** row and added standalone **Displayed reading source & G7 sequence** section.

### v1.0 (2026-05-05 22:10 CET)

- Initial **Build 194** implementation log from Trio **`git diff`** + in-thread BLE counter / heartbeat / watchdog work; flagged missing **`align...`** before transcript merge.
