# HapticBeacon — implementation log

**Plan:** [`haptic-beacon-impl-plan.md`](haptic-beacon-impl-plan.md) (v1.15)
**Started:** 2026-05-11 11:18 CET
**R8 stale-gap-relayed recovery landed (worktree):** 2026-05-11 23:08 CET
**R7 warm-arm invariant tightening landed (worktree):** 2026-05-11 23:00 CET
**R6 multi-source safety pass landed (worktree):** 2026-05-11 22:55 CET
**Cut 4 landed (worktree):** 2026-05-11 22:30 CET
**Cut 1 landed (worktree):** 2026-05-11 11:25 CET
**Cut 1 review-round-2 fixes landed (worktree):** 2026-05-11 12:25 CET
**Cut 1 review-round-3 fixes landed (worktree):** 2026-05-11 12:50 CET
**Cut 1 review-round-4 fixes landed (worktree):** 2026-05-11 13:30 CET
**Cut 1 review-round-5 fixes landed (worktree):** 2026-05-11 14:26 CET
**Status:** Cuts 1–4 + R2–R5 fixes + R6 multi-source safety pass + R7 warm-arm invariant tightening + **R8 stale-gap-relayed recovery + dedup log enrichment** implemented in worktree; Cut 2 background spike (§5.3–5.4) still pending; awaiting build / on-device verification.

---

## Cut 1 — BLE-only foreground beacon

### Files added

- **`Trio Watch App Extension/HapticBeacon.swift`** (new, 273 lines).
  Singleton `@MainActor final class HapticBeacon` matching plan §3.1 exactly:
  - Tuning constants: `expectedCadence=300`, `rampLeadTime=3`, `missGracePeriod=20`, `staleThreshold=600`, `successInterBuzzInterval=0.150`, `timerLeeway=500ms`.
  - `isEnabled` is a computed property reading `UserDefaults.standard.bool(forKey: "HapticBeacon.isEnabled")` on every access. Default OFF (key absent → `false`). Single mutation site is `setEnabled(_:)`.
  - Three `DispatchSourceTimer` slots: `rampTimer` (one-shot at expected−3s), `rampSubTimers: [DispatchSourceTimer]` (three sub-timers at +0/+1/+2s on `timerQueue`, cancellable as a group), `missTimer` (one-shot at expected+20s).
  - `noteEGVReceived(at:source:)` is the single entry hook. Cut 1 ignores any source other than `.g7DirectBLE` (parameter exists today so Cut 3 plumbing is a one-liner).
  - **Adapter-stopped invariant (plan §11 Q3 / Option A):** `isAdapterStopped()` reads `WatchState.shared.g7DirectBleStatus == .off`. Checked at `noteEGVReceived` entry (defense-in-depth) and at every `play(_:)` call. Pending timers cancelled on `noteEGVReceived` skip; per-fire skip is silent except for a `haptic_skipped` log line.
  - **Concurrency:** `timerQueue` is a private serial `DispatchQueue` with `.utility` QoS, label `org.nightscout.trio.watch.haptic.timers` — mirrors `G7WatchSensorAdapter.timerQueue`. Every timer event handler is a tiny closure that schedules `Task { @MainActor in HapticBeacon.shared.<method>() }` and returns. No beacon state is touched from `timerQueue`.
  - **Telemetry:** `WatchLogger.shared.log(...)` via fire-and-forget `Task { await ... }`. Lines tagged `module=haptic_beacon event=<name> [field=value ...]`. Five event names emitted in Cut 1: `start`, `stop`, `setEnabled`, `haptic_armed` (×2 per cycle: phase=ramp, phase=miss), `haptic_fired`, `haptic_skipped`, `rearm_skipped`.
  - **Vocabulary reservation (plan §10.1):** beacon owns `.click`, `.start`, `.notification`, `.success`, `.retry`. `.failure`, `.directionUp`, `.directionDown`, `.stop` reserved for future clinical alerter — not used anywhere in this file.
  - **`play(_:label:)` is the single delivery choke point** (plan §10.2). Cut 1 routed through `WKInterfaceDevice.current().play(_:)` only; Cut 2 (plan v1.10) prefers `WKExtendedRuntimeSession.notifyUser(haptic:)` when `currentExtendedSession?.state == .running`, else device — see § Cut 2 below.

### Files modified

- **`Trio Watch App Extension/G7WatchSensorAdapter.swift`** (2 surgical changes):
  - **Change A** (lines 26–30): added `@MainActor var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }` directly under the existing `extendedSession` declaration. Read-only computed accessor. Documented that callers must not cache the returned reference (three replacement paths exist on the adapter).
  - **Change B** (line 621, inside the existing `Task { @MainActor in }` at the end of `sensor(_:didRead glucose:)`): appended `HapticBeacon.shared.noteEGVReceived(at: Date(), source: .g7DirectBLE)` after the three `WatchState.shared.*` writes. Receipt-time anchor (`Date()`), not sensor `readingDate`, per plan §3.2.

- **`Trio Watch App Extension/TrioWatchApp.swift`** (1 line added):
  - Inside `.onChange(of: scenePhase)`, in the `newPhase == .active` branch, added `HapticBeacon.shared.start()` immediately after the existing `WatchState.shared.handleForegroundActiveEntry()` call. `start()` is idempotent (just logs `event=start is_enabled=…`); no work happens until an EGV arrives via `noteEGVReceived`.

- **`Trio Watch App Extension/Views/ComplicationDebugView.swift`** (3 changes):
  - Added `@State private var hapticBeaconEnabled: Bool = false` near the other `@State` declarations. Default `false` because the property initializer cannot touch `@MainActor` singleton state. Synced from `HapticBeacon.shared.isEnabled` in `.onAppear`.
  - In `.onAppear` (after `loadLogFileStats()`): `hapticBeaconEnabled = HapticBeacon.shared.isEnabled`.
  - In `actionsView`, immediately after the "Flush Logs" button: new `Button` labelled `"Haptic Beacon: ON"` / `"Haptic Beacon: OFF"` with `bell.fill` / `bell.slash` SF Symbol. `.bordered` style with `.tint(.pink)` (visually distinct from the existing blue / orange / purple action buttons). Tap calls `HapticBeacon.shared.setEnabled(!hapticBeaconEnabled)`, syncs the local mirror, and shows a one-shot toast via the existing `triggerConfirmation(message:)` helper.

### Files NOT modified (intentional)

- **`Trio.xcodeproj/project.pbxproj`** and **`scripts/sync_project_files.rb`** — per Trio AGENTS.md safety rule 6, no project file edits or sync invocations from this session. The new `HapticBeacon.swift` lives at `Trio Watch App Extension/HapticBeacon.swift` which is covered by the existing target glob in `scripts/sync_project_files_config.rb:15` (`"Trio Watch App Extension/**/*.{swift,m,mm}"`). Project membership refresh will happen via the canonical build/sync workflow on the next build.
- **`Trio Watch App Extension/WatchState.swift`** — Cut 3 hook sites (`applyHKSnapshot`, `saveComplicationSnapshot`) intentionally left unchanged; they are gated on Cut 2 spike outcome.
- **`Trio Watch App/Info.plist`** — already has `WKBackgroundModes=physical-therapy` (lines 19–26), pre-verified; no change required for Cut 1 (foreground only) and none expected for Cut 2 spike.

### Plan deviations

None. The implementation matches plan v1.5 §3, §4, and §9 (Cut 1 deliverables and done criteria) line by line. The only departures from a literal reading of the plan are three small refinements that don't change behavior:

1. **`[weak self]` collapsed to direct `HapticBeacon.shared` access in timer event handlers.** The plan suggested `[weak self] in Task { @MainActor [weak self] in self?.method() }`. Doubled `[weak self]` is redundant when one of the captures is in a `Task @MainActor` closure capturing from an outer closure that already has weak capture, and is potentially confusing for reviewers. Since `HapticBeacon` is a singleton (`static let shared`), it is never deallocated — direct `HapticBeacon.shared.<method>()` calls inside the `Task { @MainActor in … }` closures are correct, equally safe, and read more cleanly. This is a stylistic refinement; behavior is identical.
2. **Per-fire `isEnabled` / `isAdapterStopped` gating consolidated into `play(_:)`.** Earlier draft had the same gates in `fireRamp` and `fireMiss`. Removed the upstream gates because `play(_:)` already handles the case correctly with a `haptic_skipped` log line per intended haptic. Net effect: if the user disables mid-ramp, three `haptic_skipped` lines log (one per intended sub-haptic) rather than one `phase=ramp` skip line. Slightly noisier log, simpler code, no functional difference. Documented inline in `fireRamp`.
3. **Toast labels added** (`🔔 Haptic Beacon ON` / `🔕 Haptic Beacon OFF`). The plan §3.4 mentions using `triggerConfirmation(message:)` but didn't specify the message text — picked emoji-prefixed strings to match the existing `📡 Requesting...` / `📤 Logs flushed` / `✅ Reload triggered!` pattern in the same view.

### Self-review checklist (per Trio AGENTS.md "Self-Review Protocol")

- [x] Re-read every modified / created file top to bottom.
- [x] Imports resolve. `HapticBeacon.swift` imports `Foundation` + `WatchKit`. The two pre-existing SourceKit false-positives (`No such module 'G7SensorKit'` in `G7WatchSensorAdapter.swift:3`, `No such module 'WatchKit'` in `ComplicationDebugView.swift:2`) are unchanged from baseline — they existed before this work and are caused by the IDE not having the watch target selected.
- [x] No half-finished edits or stale TODOs in the changed surface.
- [x] Naming is consistent across all affected files (`HapticBeacon`, `noteEGVReceived`, `setEnabled`, `currentExtendedSession`).
- [x] Changes match the request and plan v1.5 — no scope creep; Cut 2 / Cut 3 hooks intentionally absent.
- [x] No patch-stack interaction (`Trio` worktree, not `Trio-dev`); `patch-test.sh` not applicable for this session.
- [x] Cross-patch type shadowing (Trio AGENTS.md self-review step 7): `HapticBeacon` does not reference any of the commonly shadowed names (`NotificationCenter`, etc.). All Foundation / WatchKit symbols used (`UserDefaults`, `Date`, `Task`, `WKInterfaceDevice`, `WKHapticType`, `DispatchQueue`, `DispatchSource`, `DispatchSourceTimer`, `DispatchTimeInterval`) are unambiguous in scope.

### Build / verification

Per Trio AGENTS.md safety rule 10, no `xcodebuild` invocation from this session. Verification is by static review only. The user will run `ci/local-build.sh` separately when ready to build, with their chosen flags.

### Cut 1 done-criteria status

From plan §9 Cut 1:

- [ ] **Toggle in debug view persists across app relaunch** — implementation correct (UserDefaults read on every `isEnabled` access; written via `setEnabled`); requires on-device verification.
- [ ] **When enabled and BLE EGV arrives in foreground: success buzz fires within 1 s** — `noteEGVReceived` calls `fireSuccess` synchronously after the source/adapter checks; the first `.success` haptic plays inside the same main-actor turn. Requires on-device verification.
- [ ] **Ramp fires at expected−3s, −2s, −1s with three perceptibly different haptics** — three sub-timers scheduled with delays 0/1/2s after `rampTimer` fires at `receiptDate + 297s`. Net effect: plays at receipt+297s, +298s, +299s (i.e. expected−3s, −2s, −1s). Haptic types `.click` → `.start` → `.notification` per plan §3.1 / §10.1. Requires on-device verification.
- [ ] **Miss fires at expected+20s if no EGV; cancelled by an EGV arriving in the grace window** — `missTimer` scheduled at `receiptDate + 320s`; cancelled by `cancelAllTimers()` inside `noteEGVReceived` if a fresh EGV arrives. Requires on-device verification.
- [ ] **No haptics when isEnabled = false** — guarded at `noteEGVReceived` entry, in `setEnabled(false)` (which cancels timers), and in `play(_:)`. Requires on-device verification.
- [ ] **No timer leaks across stop / start cycles** — `cancelAllTimers()` is called from `noteEGVReceived`, `stop`, `setEnabled(false)`. All three timer slots (`rampTimer`, `rampSubTimers`, `missTimer`) are cancelled and cleared. Requires on-device verification (toggle off → on → off → on with EGVs in flight).
- [ ] **`event=haptic_armed` and `event=haptic_fired` appear in Better Stack with the documented field shape** — emit shape exactly matches plan §4. Requires Better Stack query after first foreground EGV cycle with the kill switch ON.

---

## Cut 2 — background spike

**Code (plan §5.2): implemented** — `HapticBeacon.play(_:label:)` now prefers `G7WatchSensorAdapter.shared.currentExtendedSession?.notifyUser(haptic:)` when `session.state == .running`, otherwise `WKInterfaceDevice.current().play(_:)`. Telemetry matches plan §4.1: `delivered_via=extended_session` with `session_state=<rawValue>`, or `delivered_via=device` with `reason_no_session=<extended_session.state.rawValue|"nil">`. File-level doc comments in `HapticBeacon.swift` updated to describe the dual path and per-fire session re-query.

**Plan deviation:** §5.2 draft used `name(of: type)` in log lines; implementation retains the pre-existing `label` parameter (`ramp_click`, `success`, …) for the `type=` field — equivalent for analysts and avoids relying on `WKHapticType` debug naming.

**Spike validation (plan §5.3–5.4): not executed in-session** — 5-cycle screen-off protocol, Better Stack tally, and pass/partial/fail decision remain for on-device follow-up (`docs/in-progress/haptic-beacon/haptic-beacon-cut2-spike.md` when recorded).

### Files modified (Cut 2)

- `Trio Watch App Extension/HapticBeacon.swift` — `play(_:label:)` body + file/header comment tweaks only.

### Cut 2 done-criteria status

- [ ] Spike protocol §5.3 executed for 5 cycles; results recorded in `docs/in-progress/haptic-beacon/haptic-beacon-cut2-spike.md`.
- [ ] Decision per §5.4 (pass / partial / fail) recorded with telemetry citations.

---

## Cut 3 — phone / HK source coverage

**Code (plan §6): implemented.** Gate "Cut 2 = pass" was **explicitly deferred** by user direction in the same session that landed Cut 2. The Cut 2 spike protocol (§5.3 / §5.4) has not been executed on-device, so it is unknown whether `notifyUser(haptic:)` actually delivers haptics with the screen off. Cut 3 ships the source-filter UI and per-cycle source telemetry regardless — these are useful in foreground even if the spike fails — but the user should weigh that the multi-source plumbing was the part the gate was designed to defer.

### Plan deviations

1. **Cut 2 spike not run before Cut 3.** Plan §6 originally said Cut 3 is "gated on Cut 2 = pass" because (a) wc/hk readings can be late/batched/out-of-cadence and (b) plumbing them in before background haptics are validated is wasted work if Cut 2 fails. The user explicitly directed Cut 3 implementation in the same session. Both rationales (a) and (b) are still true; the user's tradeoff is to ship the option now and live with the consequences in the source-filter telemetry. §6 rewritten to reflect the new gating posture; the original "Why deferred" rationale is retained as historical context.

2. **`cancelAllTimers()` now owns the `lastCycleSource = nil` clearing.** Plan §6 specified the new state slot as paired with `lastReceiptAt`. Implementation chose to centralize the clear in `cancelAllTimers()` instead of repeating `lastCycleSource = nil` in every caller (`stop`, `setEnabled(false)`, `setSourceFilter`, the adapter-stopped branch of `noteEGVReceived`). The function captures `currentSourceTag()` *before* clearing so cancellation telemetry still tags the cycle being torn down. Equivalent semantics, fewer drift opportunities.

3. **`setSourceFilter` cancellation is conditional.** Plan §6 implied "Add a second debug-view button … toggle"; the implementation refines the contract: narrowing `.all` → `.ble` cancels in-flight timers **only when** `lastCycleSource` is non-nil and not already `.g7DirectBLE`. Widening `.ble` → `.all` is always a no-op until the next non-BLE EGV. This avoids cancelling a perfectly-good BLE-anchored cycle when the user merely flips the policy.

4. **`source` tag added to several skip logs that the plan only listed for `armed` / `fired`.** Plan §6 said "Telemetry: `source=ble|hk|wc` on both `armed` and `fired` lines." Implementation also adds `source=` to `haptic_cancelled`, `haptic_skipped`, `rearm_skipped reason=stale_gap`, and `rearm_skipped reason=deadline_passed`. Same telemetry contract direction; broader coverage so analysts can attribute every line to a provenance.

5. **New `egv_ignored` event.** Plan §6 said `noteEGVReceived` "ignores non-BLE sources unless `.all` is selected" but did not specify whether the rejection should log. Implementation logs `egv_ignored reason=source_filtered source=<tag> filter=<value>` so analysts can size the wc/hk traffic the filter is currently shielding from. Expected in `.ble` mode whenever a phone or HK EGV arrives.

### Files modified (Cut 3)

- `Trio Watch App Extension/HapticBeacon.swift` — `SourceFilter` enum, persisted `sourceFilter` + `Keys.sourceFilter` / `setSourceFilter(_:)`, `lastCycleSource` slot, helpers (`accepts(source:under:)`, `shortTag(for:)`, `currentSourceTag()`), source-tagged log lines on `armed`/`cancelled`/`fired`/`skipped`/`rearm_skipped`, new `egv_ignored` + `setSourceFilter` events, `start` now logs `source_filter`. File-level docstring updated with a "Source filter" section.
- `Trio Watch App Extension/WatchState.swift` — two one-line hooks: `applyHKSnapshot` end (after `lastWatchStateUpdate = snapshot.readingDate`) calls `noteEGVReceived(at: Date(), source: .healthKit)`; `saveComplicationSnapshot` after `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` calls `noteEGVReceived(at: Date(), source: .watchConnectivity)`. Both hooks are past their respective accept gates (`tryAttributeDisplayedReadingSource` for HK, `shouldSkipPreDispatch` for WC).
- `Trio Watch App Extension/Views/ComplicationDebugView.swift` — `@State hapticBeaconSourceFilter`, init in `.onAppear`, second `Button` in `actionsView` immediately below the existing Haptic Beacon toggle.

### Source-filter cancellation: which transition cancels timers?

| Prior `sourceFilter` | New `sourceFilter` | `lastCycleSource` at toggle | Action |
|---|---|---|---|
| `.ble` | `.all` | any | log `setSourceFilter value=all` only |
| `.all` | `.ble` | nil | log `setSourceFilter value=ble` only |
| `.all` | `.ble` | `.g7DirectBLE` | log `setSourceFilter value=ble` only — BLE cycles survive |
| `.all` | `.ble` | `.watchConnectivity` or `.healthKit` | `cancelAllTimers()`, clear `lastReceiptAt`, log `setSourceFilter value=ble action=cancelled_pending_timers prior_cycle_source=wc\|hk` |

### Self-review checklist (per Trio AGENTS.md)

- [x] All three modified files re-read top to bottom after final edit.
- [x] All new symbols (`SourceFilter`, `setSourceFilter`, `accepts`, `shortTag`, `currentSourceTag`, `lastCycleSource`, `Keys.sourceFilter`) are referenced consistently across the file (no orphans, no dangling).
- [x] Imports unchanged — `Foundation` and `WatchKit` already present in `HapticBeacon.swift`; `WatchState.swift` and `ComplicationDebugView.swift` already had `HapticBeacon` in scope (same module).
- [x] No half-finished edits; all `lastCycleSource = nil` redundancies removed in favor of centralization in `cancelAllTimers()`.
- [x] No scope creep into clinical-alerts (§10) or new haptic types.
- [x] No project file edits or `sync_project_files.rb` invocation (AGENTS rule 6); WatchState/Views are existing tracked files, no new files added.
- [x] SourceKit lints (`No such module 'WatchKit'` / `No such module 'WatchConnectivity'`) are pre-existing IDE-only false positives — same noise as Cut 1+2 rounds.

### Cut 3 done-criteria status

(Done-criteria identical to plan §9 Cut 3.)

- [ ] With `Source: BLE only` selected, behavior identical to Cut 1+2 (only BLE EGVs arm cycles). Verify in foreground by toggling the second debug button to BLE only and watching `egv_ignored reason=source_filtered source=wc|hk` in Better Stack while a phone-relayed reading arrives.
- [ ] With `Source: All` selected, beacon fires on phone-relayed and HK-relayed EGVs. Verify success buzz fires after `noteEGVReceived` from `applyHKSnapshot` or `saveComplicationSnapshot` paths.
- [ ] `egv_ignored reason=source_filtered` log volume in `.ble` mode roughly matches the number of non-BLE EGVs received during the window.
- [ ] Narrowing `.all` → `.ble` while a wc/hk cycle is armed cancels in-flight timers and emits `setSourceFilter ... action=cancelled_pending_timers prior_cycle_source=<wc|hk>`.
- [ ] False-miss rate on non-BLE sources documented (subjective + telemetry) — primarily a question of how often `haptic_fired type=retry_1|retry_2 source=wc|hk` appears in `.all` mode.

---

## Cut 4 — richer cadence (ramp / success / miss)

**Code (plan § Cut 4 narrative + §9): implemented** in `Trio Watch App Extension/HapticBeacon.swift` only.

### What changed

- **`rampLeadTime`:** `3` → **`5` s**. Ramp one-shot still fires at `lastReceiptAt + (expectedCadence − rampLeadTime)` → **`receipt + 295 s`** for a nominal live anchor (vs **297 s** before).
- **`fireRamp()`:** Seven UUID-keyed sub-timers from a single `steps` literal — offsets **0.0, 0.5, 1.5, 2.0, 3.5, 4.0, 4.5** s from ramp trigger; types `.click` ×2 → `.start` ×2 → `.notification` ×3; telemetry labels reuse **`ramp_click`**, **`ramp_start`**, **`ramp_notif`** per beat group (same string repeated), matching plan § Cut 4 table.
- **Success:** Removed **`successTimer` / `successTimerID`** (Cut 1–3 pair-buzz). Added **`successSubTimers: [UUID: DispatchSourceTimer]`** + **`successSubTimerFired`**, driven by static **`successBuzzSteps`**: triple `.success` at **0 / 200 / 350 ms** with labels **`success_1`**, **`success_2`**, **`success_3`**.
- **Miss:** Outer **`missTimer`** unchanged; **`fireMiss()`** now schedules **`missSubTimers`** from **`missRetrySteps`**: double `.retry` at **0 / 300 ms** with **`retry_1`**, **`retry_2`**.
- **`cancelAllTimers()`:** Emits **`phase=success_sub`** and **`phase=miss_sub`** with **`pending_count`** when triple-success or double-miss sub-steps are torn down mid-sequence (same pattern as **`phase=ramp_sub`**). Order: ramp outer → ramp_sub → success_sub → miss outer → miss_sub; **`lastCycleSource`** cleared last.

### Plan deviations

None. Matches plan v1.12 §3.1, §4.1–§4.2, § Cut 4 table, and §9 Cut 4 deliverables.

### Analyst / query migration notes

Historical logs and queries that filtered on **`type=success`** should treat Cut 4+ lines as **`success_1`**, **`success_2`**, **`success_3`** (often counting **`success_1`** ≈ completed success bursts). Miss accounting: **`retry_1`** ≈ **`retry_2`** when neither sub-step cancelled; **`haptic_armed phase=miss`** still counts outer miss arms.

### Self-review checklist (per Trio AGENTS.md)

- [x] Re-read `Trio Watch App Extension/HapticBeacon.swift` after Cut 4 edits (constants, `fireRamp` / `fireSuccess` / `fireMiss`, `cancelAllTimers`, file header).
- [x] No new Swift symbols conflict with in-scope shadows; `play(_:label:)` choke point unchanged.
- [x] No `project.pbxproj` or `sync_project_files.rb` changes (AGENTS rule 6).
- [x] Static verification only — no `xcodebuild` / `ci/local-build.sh` per AGENTS rule 10.

### Cut 4 done-criteria status

From plan §9 Cut 4:

- [ ] Ramp spans **5 s** before expected EGV with **seven** perceptible beats in the planned grouping.
- [ ] Success delivers **three** `.success` haptics at ~0 / 200 / 350 ms.
- [ ] Miss delivers **two** `.retry` haptics at ~0 / 300 ms when grace fires with no EGV.
- [ ] Better Stack shows **`success_*`** / **`retry_*`** labels and mid-sequence **`haptic_cancelled phase=success_sub|miss_sub`** when interrupted.

---

## Cut 3 — Cut 2 spike validation (still pending)

Cut 2's `notifyUser(haptic:)` background spike (plan §5.3 / §5.4) is unchanged by Cut 3. Cut 3's source-filter and source-tagging changes affect *which* EGVs arm cycles and *how* lines are tagged in telemetry, but not whether `notifyUser(haptic:)` delivers a haptic when `currentExtendedSession?.state == .running` with the screen off. Spike checkboxes from the Cut 2 section above remain authoritative for the §5.4 decision.

---

## Cut 1 — review round 2 (Claude + ChatGPT)

External review of the Cut 1 worktree was solicited from Claude and ChatGPT. Notes consolidated, evaluated, and dispositioned below. Full reviewer text is in the chat transcript.

### Consolidated finding table

| # | Source | Severity (reviewer) | Severity (this log) | Disposition | Fix location |
|---|---|---|---|---|---|
| 1 | Claude #1 | Major | Major (real bug) | **Fix** — guard never fires as written | `HapticBeacon.noteEGVReceived` / `rearm` |
| 2 | Claude #2, ChatGPT #1+#2 | Minor / Blocker | High (state correctness) | **Fix** — store `successTimer`, cancel in `cancelAllTimers` | `HapticBeacon.fireSuccess` / `cancelAllTimers` |
| 3 | Claude #3 | Minor (telemetry) | Minor (telemetry) | **Fix** — emit `haptic_cancelled` for truly-pending timers, plus null-on-fire so the count is meaningful | `HapticBeacon.cancelAllTimers` / `fireRamp` / `fireMiss` |
| 4 | ChatGPT #3 | Blocker | Medium (cold-start race confirmed) | **Fix** — add adapter accessor and use it | `G7WatchSensorAdapter.isIntentionallyStopped` (new) + `HapticBeacon.isAdapterStopped` |
| 5 | ChatGPT #4 | High (scope drift) | Medium (doc drift only) | **Fix in plan, not code** — bless the actual telemetry surface; the extras are operationally useful | `haptic-beacon-impl-plan.md` §4 |
| 6 | ChatGPT #5 | Blocker (compile risk) | None (verified safe) | **No-op** — `TrioComplicationDataSource: String, Codable, Equatable` (`Trio Watch Shared/TrioComplicationDataStore.swift:8`); `.rawValue` compiles | n/a |
| 7 | ChatGPT medium (`start()` no-op) | Medium (UX) | Medium (UX) | **Fix** — implement warm-arm in `setEnabled(true)` using recent `bleLastEGVDate` | `HapticBeacon.setEnabled` |
| 8 | ChatGPT medium (BLE-only miss) | Medium (tester comms) | None (by design per plan §6) | **Doc-only** — already documented; tester note added below | n/a |
| 9 | ChatGPT medium (timer cleanup) | Medium (state hygiene) | Medium | **Fix** — null `rampTimer`/`missTimer`/`successTimer` from inside their fire paths | `HapticBeacon.fireRamp` / `fireMiss` / `fireSuccess` |
| 10 | ChatGPT medium (mixed working tree) | Medium (review noise) | None (already mitigated) | **No-op** — code review doc tags every hunk `[in scope]` / `[out of scope — pre-existing]`; no actionable change | n/a |

### Per-finding evaluation

**1. Stale guard in `rearm()` — confirmed dead code (Major).** Verified: `noteEGVReceived(at: Date(), source: .g7DirectBLE)` is the only caller; `receiptDate` is always `Date()` at call time. `let age = Date().timeIntervalSince(receiptDate)` is always sub-millisecond. The guard cannot fire. Plan's "don't rearm after a 10-min outage" intent is **the gap between consecutive receipts**, not the freshness of the just-arrived receipt. Fix moves the gap check to `noteEGVReceived` using the pre-update `lastReceiptAt`, and removes the dead guard from `rearm`. New `rearm_skipped` reason: `stale_gap` (was `stale_receipt`). The first EGV after launch (`lastReceiptAt == nil`) still rearms, since there's no prior to compare.

**2. Second success buzz is uncancellable (Claude minor / GPT blocker).** Both reviewers caught this; ChatGPT escalates correctly. The local `t` will fire (the dispatch system retains a resumed `DispatchSourceTimer` until handler completion), but `cancelAllTimers()` cannot reach it — so a fresh `noteEGVReceived` inside the 150 ms window can stack a second old success buzz on top of the new pair. Fix stores the second buzz in a new `successTimer: DispatchSourceTimer?` slot and cancels it in `cancelAllTimers()`. The `play(_:)` `isEnabled` guard already prevents wrong-state plays, but tracking restores honest semantics for `cancelAllTimers()`.

**3. `haptic_armed` logged at schedule time (Minor).** Confirmed: every `noteEGVReceived` emits `haptic_armed phase=miss expected_at=<X+320>`, then 5 minutes later the next EGV's `cancelAllTimers()` cancels the still-pending miss timer silently. Better Stack tally of `haptic_armed phase=miss` vs `haptic_fired type=retry` would suggest hundreds of "misses" when none actually fired. **Fix**: combine with finding #9 — null timer slots inside their fire handlers, then in `cancelAllTimers()` only emit `haptic_cancelled` for slots that are still non-nil (i.e. truly pending). Net telemetry shape: `haptic_armed` (predicted) = `haptic_cancelled` (replaced) + `haptic_fired` (delivered) + small residue from final cycle. Documented analysis methodology in [§Telemetry methodology for Cut 2 spike](#telemetry-methodology-for-cut-2-spike) below.

**4. `isAdapterStopped()` is too blunt (Blocker — confirmed real cold-start risk).** Verified: `WatchState.swift:97` declares `var g7DirectBleStatus: G7DirectBLEStatus = .off` — defaults to `.off` until `publishConnectionStatus()` runs. If the user enables the beacon and an EGV arrives via the BLE delegate before the first publish has flipped the mirror to `.scanning` / `.active`, the beacon would suppress the success buzz with `haptic_skipped reason=adapter_stopped`. Adapter's true source of truth is `private var isStopped` (`G7WatchSensorAdapter.swift:37`), mutated only in `start()` (false) and `stop()` (true). Fix adds `@MainActor var isIntentionallyStopped: Bool { isStopped }` accessor and switches `HapticBeacon.isAdapterStopped()` to use it. Status mirror remains the public lifecycle signal for the rest of the app; the beacon now uses the precise flag.

**5. Telemetry scope expansion (High — but doc-only).** Plan §4 said "two log lines, no more"; implementation emits seven distinct event names: `start`, `stop`, `setEnabled`, `haptic_armed`, `haptic_fired`, `haptic_skipped`, `rearm_skipped`. The extras are intentional and operationally valuable (lifecycle visibility, toggle audit, suppression reasons). **Fix is in the plan, not the code:** §4 updated to bless the full telemetry surface. New events from this round (`haptic_cancelled`, `warm_armed`, `rearm_skipped` reason rename) folded in.

**6. `source.rawValue` compile risk (Blocker — verified non-issue).** Re-verified `Trio Watch Shared/TrioComplicationDataStore.swift:8`: `enum TrioComplicationDataSource: String, Codable, Equatable`. `.rawValue` is `String`. Compiles. No fix needed; flagged here to short-circuit the same review feedback in future rounds.

**7. `start()` is a no-op on warm enable (Medium UX).** Accurate observation. By design per plan §3.1 ("Enabling does not arm anything — next EGV will arm") but a tester enabling the beacon mid-cycle would wait up to 5 minutes for first feedback, which feels broken. **Fix**: in `setEnabled(true)`, if `WatchState.shared.bleLastEGVDate` is recent (< staleThreshold) and adapter is not intentionally stopped, treat it as a synthesized cadence anchor and call `rearm(after:)` directly. Suppress the success buzz (no EGV is actually arriving). Logs `warm_armed anchor_age_s=<n>`. Note: `bleLastEGVDate` is `readingDate` (sensor-side) not receipt time — typical drift between the two is < 5 seconds for live BLE, well within the 500 ms timer leeway. Acceptable for a UX warm-arm.

**8. Miss haptic semantics are BLE-only (Medium tester comms).** Already documented in plan §6 (Cut 3 plumbing for non-BLE). **Tester note** (added to debug-view / log): in Cut 1, if HK or phone-relay updates arrive while BLE is quiet, the beacon will still fire a miss buzz — not a bug, expected behavior until Cut 3 adds source filtering for `.all`.

**9. Timer cleanup after firing (Medium hygiene).** Confirmed: `rampTimer` / `missTimer` retain their references after the one-shot handler runs, so `rampTimer != nil` no longer means "pending". Fix nulls the slot from inside the timer's own handler (via small `rampFired()` / `missFired()` private wrappers, since the handler closure cannot directly assign a `private var` on the singleton without going through `HapticBeacon.shared`). Net effect: `cancelAllTimers()` can rely on `slot != nil` as "truly pending" and emit `haptic_cancelled` only when meaningful.

**10. Mixed working tree (Medium review noise).** Already addressed by the existing code review doc (`docs/code-review/haptic-beacon-cut1-and-debug-view-cleanup-code-review.md`) which tags every hunk `[in scope]` or `[out of scope — pre-existing]`. No further action required from this round.

### Telemetry methodology for Cut 2 spike

After this round of fixes, the telemetry contract for analyzing whether haptics are actually being delivered:

- **Did a haptic fire?** `count(haptic_fired group by type)`. Source of truth.
- **Was a haptic predicted but never delivered?** `count(haptic_armed group by phase) - count(haptic_cancelled group by phase) - count(haptic_fired group by type that maps to phase)`. Residue ≈ in-flight at query time + `haptic_skipped reason=adapter_stopped`.
- **Why was a haptic suppressed?** `count(haptic_skipped group by reason)`.
- **Did the user disable the beacon?** `count(setEnabled enabled=false)`.
- **Did the beacon fail to rearm after a long outage?** `count(rearm_skipped reason=stale_gap)`.

The `haptic_armed phase=miss` count is **not** a useful proxy for "missed EGVs" on its own — every EGV arms a fresh miss timer that is almost always cancelled by the next EGV. Use `haptic_fired type=retry` for the actual miss count.

---

## Cut 1 — review round 2 fixes log

Files modified in this round (worktree):

- **`Trio Watch App Extension/HapticBeacon.swift`** — main rewrite (six related changes).
- **`Trio Watch App Extension/G7WatchSensorAdapter.swift`** — one-line accessor addition.
- **`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`** — §4 telemetry section + changelog (v1.6).

### Fix 1 — Stale guard relocated (Claude #1)

**File:** `HapticBeacon.swift`. In `noteEGVReceived(at:source:)`, capture the existing `lastReceiptAt` into a local `priorReceiptAt`, then after `cancelAllTimers()` and `lastReceiptAt = receiptDate` and `fireSuccess()`, check `if let prior = priorReceiptAt, receiptDate.timeIntervalSince(prior) > Self.staleThreshold` → log `rearm_skipped reason=stale_gap gap_s=<n>` and skip the rearm. The dead guard inside `rearm(after:)` is removed (function is now schedule-only). First-EGV-after-launch path (no prior) rearms unconditionally, which is the desired behavior.

### Fix 2 — `successTimer` slot tracked and cancelled (Claude #2 / ChatGPT #1+#2)

**File:** `HapticBeacon.swift`. New private slot `private var successTimer: DispatchSourceTimer?`. `fireSuccess()` plays the immediate `.success`, schedules the +150 ms `DispatchSourceTimer`, **stores it in `successTimer`**, then resumes. The handler routes through a new `private func playSecondSuccessBuzz()` wrapper that nulls `successTimer` before calling `play(.success, label: "success")`. `cancelAllTimers()` now cancels and nils `successTimer` along with the others. No `haptic_cancelled` is emitted for the success second-buzz — it's a paired companion, not a predicted haptic, and an unfired second of the pair is not interesting telemetry.

### Fix 3 — Null-on-fire + `haptic_cancelled` for truly-pending timers (Claude #3 + ChatGPT timer cleanup)

**File:** `HapticBeacon.swift`. New private wrappers `rampFired()` and `missFired()` that null their respective slot before calling `fireRamp()` / `fireMiss()`. The `setEventHandler` closures in `scheduleRampTimer` / `scheduleMissTimer` route through these wrappers (`HapticBeacon.shared.rampFired()` / `.missFired()`). `cancelAllTimers()` now logs `haptic_cancelled phase=ramp` only when `rampTimer != nil`, `phase=ramp_sub` only when `!rampSubTimers.isEmpty`, `phase=miss` only when `missTimer != nil`. After this fix, `rampTimer != nil` ⇔ "scheduled but not yet fired".

### Fix 4 — `isIntentionallyStopped` accessor on adapter; beacon switches to it (ChatGPT #3)

**Files:** `G7WatchSensorAdapter.swift` + `HapticBeacon.swift`. New accessor on the adapter, placed directly under `currentExtendedSession`:

```swift
@MainActor var isIntentionallyStopped: Bool { isStopped }
```

`isStopped` is the adapter's authoritative private flag (mutated only by `start()` and `stop()`). The accessor is the precise mirror of intentional adapter stop, immune to the cold-start race where `g7DirectBleStatus` defaults to `.off`. `HapticBeacon.isAdapterStopped()` body changes from `WatchState.shared.g7DirectBleStatus == .off` to `G7WatchSensorAdapter.shared.isIntentionallyStopped`. Doc comment on `play(_:)`'s adapter-stopped invariant updated accordingly.

### Fix 5 — Plan §4 blesses the actual telemetry surface (ChatGPT #4)

**File:** `haptic-beacon-impl-plan.md` §4 rewritten to enumerate all seven event names emitted by Cut 1 plus the two new ones (`haptic_cancelled`, `warm_armed`) added in this round. Bumped to v1.6, changelog entry added. Body of the implementation is unchanged for this fix — the plan is catching up to the implementation, which intentionally diverged for operational debuggability.

### Fix 6 — Warm-arm on `setEnabled(true)` (ChatGPT medium)

**File:** `HapticBeacon.swift`. In `setEnabled(_:)`, after persisting `enabled=true`, check if `WatchState.shared.bleLastEGVDate` is non-nil AND not `.distantPast` AND age < `staleThreshold` AND adapter is not intentionally stopped. If yes, `cancelAllTimers()`, set `lastReceiptAt = bleLastEGV`, call `rearm(after: bleLastEGV)`, log `warm_armed anchor_age_s=<n>`. **Critical:** suppresses the success buzz on warm-arm — no EGV is actually arriving right now, only the cadence anchor is being initialized. Behavior is now: a tester who enables the beacon a few minutes after the most recent EGV gets ramp + miss buzzes on the very next cycle, instead of waiting up to 5 minutes for first feedback.

### Self-review checklist (per Trio AGENTS.md)

- [x] Re-read all three modified files top to bottom (`HapticBeacon.swift`, `G7WatchSensorAdapter.swift`, `haptic-beacon-impl-plan.md`).
- [x] Imports unchanged (`Foundation`, `WatchKit` for the two .swift files).
- [x] No half-finished edits or stale TODOs introduced; one TODO retained for Cut 2 spike (`play(_:)` extension to `notifyUser(haptic:)`).
- [x] Naming consistent — `successTimer`, `rampFired`, `missFired`, `playSecondSuccessBuzz`, `isIntentionallyStopped` follow existing camelCase.
- [x] No scope creep — Cut 2 / Cut 3 hooks intentionally not added in this round.
- [x] No patch-stack interaction — `Trio` worktree only; `patch-test.sh` not applicable.
- [x] Cross-patch type shadowing (Trio AGENTS.md self-review step 7): no new types or notification names; existing audit unchanged.
- [x] Telemetry contract self-consistent: nine event names, all documented in plan §4 v1.6, all queryable.

### Build / verification

Per Trio AGENTS.md safety rule 10, no `xcodebuild` or `ci/local-build.sh` invocation from this session. Verification by static review only. The user will run `ci/local-build.sh` separately when ready.

### Cut 1 + R2 done-criteria status

All eight Cut 1 done criteria from plan §9 remain awaiting on-device verification, plus three new R2-verifiable behaviors:

- [ ] **Warm-arm on toggle ON:** enabling the beacon < 10 min after most recent BLE EGV produces `warm_armed` log line and arms the next cycle without waiting for an EGV.
- [ ] **Stale-gap rearm skip:** if BLE drops out for > 10 min and recovers, first recovery EGV produces success buzz and `rearm_skipped reason=stale_gap` log line; no ramp/miss timers scheduled until the *next* EGV (which will now have a fresh `priorReceiptAt`).
- [ ] **`haptic_cancelled` accuracy:** Better Stack query `count(haptic_armed phase=miss) - count(haptic_cancelled phase=miss) - count(haptic_fired type=retry)` should equal in-flight count + `count(haptic_skipped reason=adapter_stopped)`.

### Tester-facing notes

- **Miss buzz is BLE-cadence-only in Cut 1.** If a phone-relayed (`watchConnectivity`) or HealthKit (`healthKit`) update arrives while BLE is quiet, the beacon will still fire a miss buzz at `bleLastEGV + 320 s`. **Not a bug** — the source filter that honors non-BLE paths is plan §6 / Cut 3 and is gated on the Cut 2 background spike outcome. Testers reporting "miss buzz fired even though the watch face shows fresh data" should ignore the report unless `g7DirectBleStatus` was `.active` at the time.
- **Cold-start grace window.** First foreground entry after a cold launch: `start()` is a no-op (logs only). `setEnabled(true)` warm-arms from `bleLastEGVDate` if a recent BLE EGV exists. If no recent BLE EGV exists (fresh boot, watch face not yet connected), no buzzes will fire until the first live BLE EGV arrives via `noteEGVReceived`.
- **Toggling off → on inside an active cycle.** Disabling cancels in-flight timers (logs `setEnabled enabled=false action=cancelled_pending_timers` plus `haptic_cancelled` lines for whatever was pending). Re-enabling triggers warm-arm if a recent BLE EGV exists; otherwise idle until next live EGV.

---

---

## Cut 1 — review round 3 (Claude + ChatGPT)

External review of the R2 worktree was solicited from Claude and ChatGPT. R2 fixed the original headline issues (successTimer tracking, stale-gap relocation, isIntentionallyStopped accessor) but introduced two new behavior bugs that weren't visible in the smaller R2 patch surface, plus several telemetry / doc inconsistencies. Notes consolidated, evaluated, and dispositioned below.

### R3 consolidated finding table

| # | Source | Severity (reviewer → me) | Disposition | Fix location |
|---|---|---|---|---|
| 1 | Claude — R2 wrappers missing guard-before-act | Major / Major (real race) | **Fix** — add `guard slot != nil` to `rampFired` / `missFired` / `playSecondSuccessBuzz` | `HapticBeacon` (3 wrappers) |
| 2 | ChatGPT #1 — `rampSubTimers` not nulled after fire | Major / Major (false-positive `haptic_cancelled phase=ramp_sub`) | **Fix** — convert `rampSubTimers` to `[UUID: DispatchSourceTimer]`; remove-on-fire wrapper | `HapticBeacon.rampSubTimers` + `fireRamp` + new `rampSubTimerFired` |
| 3 | ChatGPT #2 — warm-arm replays expired cycles | High / High (real UX bug) | **Fix** — tighten gate from `age < staleThreshold` (600s) to `age < expectedCadence` (300s); emit `warm_arm_skipped reason=cycle_already_expired` for older anchors | `HapticBeacon.setEnabled` |
| 4 | ChatGPT #3 — `bleLastEGVDate` rationale is mathematically wrong | Medium / Medium (doc inaccuracy) | **Fix in code comment** — drop the false "< leeway" claim; explicitly frame warm-arm as approximate UX with sensor-vs-receipt drift; flag a precise-anchor option for a future cut | `HapticBeacon.setEnabled` comment |
| 5 | ChatGPT #4 — plan §3.1 stale `setEnabled` / `rearm(after:)` API docs | Low / Low (doc drift) | **Fix in plan** — `setEnabled` now triggers warm-arm (not no-op); `rearm(after:)` is schedule-only (not cancel-and-schedule) | `haptic-beacon-impl-plan.md` §3.1 |
| 6 | ChatGPT #5 — telemetry math is shaky for ramp | Medium / Medium (analyst trap) | **Fix in plan** — split methodology into separate sections for miss (1:1) and ramp (1:N) | `haptic-beacon-impl-plan.md` §4.5 |
| 7 | ChatGPT #6 — `haptic_cancelled phase=ramp_sub` lacks counts | Low / Low (telemetry coarseness) | **Fix** — add `pending_count=N` field; trivially derived from new dictionary | `HapticBeacon.cancelAllTimers` + plan §4.2 |

### Per-finding evaluation

**1. Claude — guard-before-act in fire wrappers (Major).** Confirmed real race. Sequence:
1. `rampTimer` reaches deadline on `timerQueue`; `setEventHandler` closure runs there.
2. The closure dispatches `Task { @MainActor in HapticBeacon.shared.rampFired() }`. The Task is enqueued but not yet executed.
3. A live EGV arrives (a few ms before the ramp would have predicted it). `noteEGVReceived` runs on `@MainActor`, calls `cancelAllTimers()`. The slot is non-nil → log `haptic_cancelled phase=ramp`, call `rampTimer?.cancel()` (no-op — handler already ran), set `rampTimer = nil`.
4. The queued `rampFired()` Task now runs on `@MainActor`. Without the guard, `rampTimer = nil` is a no-op (already nil), then `fireRamp()` runs → schedules `.click`/`.start`/`.notification` sub-timers AFTER the cancellation.

User feels: success buzz → `.click` → `.start` (T+1) → `.notification` (T+2). Four buzzes instead of two, and the ramp sub-buzzes are arming events scheduled *after* the cycle completed. Race window is the dispatch latency from `timerQueue` to `@MainActor` — small but real, and likely to occur whenever a live EGV arrives in the 0–~3 s window before the predicted ramp (a normal cadence variance).

Fix is one line per wrapper: `guard <slot> != nil else { return }` before the nil-and-act sequence. Same fix applied to `missFired` and `playSecondSuccessBuzz` for consistency. Note: a small log inaccuracy remains (the cancellation log fires for a timer whose handler already invoked); the *behavior* is now correct, the log is slightly misleading in the rare race window. Documented in §4.5 telemetry methodology as the "race residue" caveat.

**2. ChatGPT — `rampSubTimers` not nulled after fire (Major).** Confirmed; same shape as the R2 issue I fixed for the singleton slots, but for an array. After the three sub-timers fire, the array still holds references. Next `cancelAllTimers()` sees `!rampSubTimers.isEmpty` → emits `haptic_cancelled phase=ramp_sub` even though all three sub-haptics already fired. Telemetry says "cancelled mid-ramp" when the truth is "ran to completion". Breaks the analysis methodology added in R2.

Fix: convert `rampSubTimers` from `[DispatchSourceTimer]` to `[UUID: DispatchSourceTimer]`. `fireRamp` generates a UUID per sub-timer; the timer's event handler routes through a new `rampSubTimerFired(id:type:label:)` wrapper that (a) guards on `rampSubTimers[id] != nil` (Claude's idiom, applied consistently), then (b) removes the entry, then (c) plays the haptic. After all three fire, dictionary is empty and `cancelAllTimers()`'s `!isEmpty` check is honest.

Bonus from the dictionary: `rampSubTimers.count` at cancellation time gives the exact number of pending sub-haptics, which feeds finding #7's `pending_count=N` field.

**3. ChatGPT — warm-arm replays expired cycles (High UX bug).** Confirmed and important. R2 gated warm-arm on `age < staleThreshold` (600 s = 10 min). The cadence is 300 s, ramp at 297 s, miss at 320 s. So:
- age 297 s: ramp fires immediately, miss in 23 s, real EGV imminent (≤3 s away). Tight but coherent (we're already in the lead window).
- age 305 s: ramp fires immediately (8 s past expected), miss in 15 s, real EGV overdue. Confusing — beacon says "imminent" when reality says "overdue".
- age 590 s: both ramp AND miss fire immediately. Chaotic burst from a fully expired cycle.

Cleanest gate is `age < expectedCadence` (300 s): within this window, the next EGV is "about to arrive" or "just arrived" — arming for it makes sense and the ramp will fire in the future or imminently. Beyond 300 s, skip with explicit `warm_arm_skipped reason=cycle_already_expired anchor_age_s=<n>` log; the next live EGV will rearm normally.

Trade-off vs ChatGPT's suggested 320 s gate: 320 s would allow warm-arming during the miss grace window, where miss could fire 0–20 s after enable. I considered this and chose 300 s for cleaner UX — within the miss grace window, the cycle is degraded enough that "wait for next live EGV" is the better signal than "buzz immediately after toggle".

**4. ChatGPT — `bleLastEGVDate` vs receipt-time rationale is wrong (Medium doc).** Confirmed. R2 comment claimed sensor `readingDate` drift from receipt time is "typically < 5 s — well within `timerLeeway` (500 ms) drift tolerance." That's mathematically broken: 5 s is 10× larger than 500 ms. The drift is real and the leeway argument doesn't apply (leeway governs *timer fire jitter*, not *anchor accuracy*).

The actual situation: warm-arm uses an approximate anchor. A ~5 s drift means predicted ramp fires ~5 s off from optimal. For a 3 s lead time, this can mean the ramp fires *concurrent with* or *just after* the actual EGV instead of just before. Acceptable as approximate UX, but the rationale needs to be honest. **Fix**: replace the wrong claim with explicit "approximate UX, sensor-vs-receipt drift is a known limitation, precise-anchor implementation deferred to future cut." A precise anchor would require either (a) plumbing a new `bleLastEGVReceiptDate` through `WatchState` from `G7WatchSensorAdapter.sensor(_:didRead:)`, or (b) persisting `HapticBeacon.lastReceiptAt` to UserDefaults so warm-arm uses HapticBeacon's own past-cycle data. Both are post-Cut-1 enhancements.

Note: when the user has already received an EGV in the current session (`HapticBeacon.lastReceiptAt != nil`), warm-arm could prefer that precise value over `bleLastEGVDate`. R3 keeps the `bleLastEGVDate`-only path for simplicity; flagged for R4 / Cut 2 as a "free precision win when toggling within a session".

**5. ChatGPT — plan §3.1 stale `setEnabled` / `rearm(after:)` docs (Low).** Plan §3.1 still says `setEnabled(_:) — flip persisted flag; cancel timers if disabling, no-op if enabling (rearm happens on next EGV)`. R2 changed the enabling path to warm-arm. Also says `rearm(after:) — cancel pending; schedule rampTimer at receiptDate + ...`; R2 made `noteEGVReceived` do the cancellation and `rearm(after:)` is now schedule-only.

Both lines are out of date and risk reintroducing old assumptions in future patches. **Fix**: update both descriptions in plan §3.1 to match R2/R3 reality.

**6. ChatGPT — telemetry math methodology is incomplete (Medium).** R2 §4.5 gave a single formula `armed - cancelled - fired ≈ in-flight + skipped`. That works cleanly for miss (1 armed → 1 fired or 1 cancelled) but misleads for ramp (1 armed → 0–3 fired sub-events + possible mid-ramp cancellation).

**Fix in plan §4.5**: split the methodology into separate sub-sections for miss (1:1 mapping) and ramp (1:N mapping). Document that `haptic_fired type=ramp_click` is the "ramp triggered" canonical proxy (since `.click` is always first); divergence between `count(ramp_click) ≈ count(ramp_start) ≈ count(ramp_notif)` indicates mid-ramp cancellations (and should equal `sum(haptic_cancelled.pending_count from ramp_sub)`). Also document the small "race residue" caveat from finding #1.

**7. ChatGPT — `haptic_cancelled phase=ramp_sub` is too coarse (Low).** Currently logs only `phase=ramp_sub source=ble`. With the dictionary refactor in fix #2, the count of pending sub-timers is trivially available at cancellation time. **Fix**: add `pending_count=N` field. Plan §4.2 updated.

### Findings explicitly NOT addressed in R3

- **Claude — fix 1, 2, 4, 7 acknowledged correct (no-op).** Stale-gap relocation, successTimer tracking, isIntentionallyStopped accessor, warm-arm on enable. Claude marks these correct.
- **Precise-anchor implementation for warm-arm.** Identified as post-Cut-1 follow-up; flagged in R3 fix #4 evaluation above. Not needed for Cut 1 ship-ability.
- **Optional 297–305 s sub-window for warm-arm (ChatGPT #2 optional refinement).** Considered; rejected in favor of cleaner 300 s gate. Documented in fix #3 evaluation above.

---

## Cut 1 — review round 3 fixes log

Files modified in this round (worktree):

- **`Trio Watch App Extension/HapticBeacon.swift`** — five related changes (guard-before-act in 3 wrappers + UUID-keyed `rampSubTimers` + new `rampSubTimerFired` + warm-arm gate tightening + rationale comment fix).
- **`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`** — §3.1 setEnabled/rearm descriptions + §4.2 pending_count + §4.5 split miss/ramp methodology + changelog (v1.7).

### Fix R3-1 — Guard-before-act in fire wrappers (Claude #1)

**File:** `HapticBeacon.swift`. Added `guard <slot> != nil else { return }` as the first line of `rampFired()`, `missFired()`, and `playSecondSuccessBuzz()`. The guard runs on `@MainActor` and reads the same `@MainActor`-only slot that `cancelAllTimers()` writes — so if `cancelAllTimers()` ran between the timer handler invocation (on `timerQueue`) and the queued `Task` executing (on `@MainActor`), the guard sees nil and returns without firing the haptic action. The guard does not retroactively suppress the (slightly misleading) `haptic_cancelled` log emitted by `cancelAllTimers()`; that's the documented "race residue" caveat in plan §4.5.

### Fix R3-2 — `rampSubTimers` UUID-keyed dictionary + remove-on-fire (ChatGPT #1)

**File:** `HapticBeacon.swift`. Replaced `private var rampSubTimers: [DispatchSourceTimer] = []` with `private var rampSubTimers: [UUID: DispatchSourceTimer] = [:]`. `fireRamp()` generates a UUID per sub-timer in the for-loop and captures it in the timer's `setEventHandler` closure, which dispatches to a new `rampSubTimerFired(id:type:label:)` wrapper. The wrapper guards on `rampSubTimers[id] != nil` (consistent with Claude's idiom from R3-1), then `removeValue(forKey: id)`, then `play(type, label:)`. After all three sub-timers fire, the dictionary is empty and `cancelAllTimers()`'s `!isEmpty` check accurately means "mid-ramp cancellation".

### Fix R3-3 — Warm-arm gate tightened (ChatGPT #2)

**File:** `HapticBeacon.swift`. In `setEnabled(true)`, replaced `guard age >= 0, age < Self.staleThreshold else { return }` (10 min) with explicit two-step gate: `guard age >= 0 else { return }` for sanity, then `guard age < Self.expectedCadence else { log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))"); return }` for the cadence window. Beyond 300 s, the cycle is fully past the predicted EGV time, and warm-arming would replay an expired prediction (immediate ramp + immediate-or-imminent miss), which is bad UX. The log line gives operators visibility into "user enabled but the BLE anchor was already too stale to use".

### Fix R3-4 — Honest rationale for `bleLastEGVDate` anchor (ChatGPT #3)

**File:** `HapticBeacon.swift`, comment block in `setEnabled(_:)`. Removed the wrong claim that sensor-vs-receipt drift is "well within `timerLeeway` (500 ms) drift tolerance." Replaced with explicit framing: warm-arm is approximate UX, drift is a known limitation, a precise-anchor option is identified for a future cut. Behavior is unchanged — only the comment is corrected.

### Fix R3-5 — Plan §3.1 setEnabled / rearm(after:) descriptions (ChatGPT #4)

**File:** `haptic-beacon-impl-plan.md` §3.1. Updated the bullet for `setEnabled(_:)` to describe the R2 warm-arm behavior (not "no-op if enabling"). Updated the bullet for `rearm(after:)` to describe the R2/R3 schedule-only behavior (cancellation moved to `noteEGVReceived`).

### Fix R3-6 — Telemetry methodology split (ChatGPT #5)

**File:** `haptic-beacon-impl-plan.md` §4.5. Split the single-formula methodology into separate "miss-cycle accounting" (1:1 mapping, simple) and "ramp-cycle accounting" (1:N mapping, more nuanced). Documented: `haptic_fired type=ramp_click` as canonical "ramp triggered" proxy; `count(ramp_click) ≈ count(ramp_start) ≈ count(ramp_notif)` divergences indicate mid-ramp cancellations and should be cross-checked against `sum(haptic_cancelled.pending_count from ramp_sub)`. Race residue caveat documented (rare cases where `haptic_cancelled phase=ramp` fires after the timer handler already invoked but before the `@MainActor` Task ran — guard-before-act suppresses the haptic effect but not the cancellation log).

### Fix R3-7 — `pending_count` on `haptic_cancelled phase=ramp_sub` (ChatGPT #6)

**File:** `HapticBeacon.swift`, `cancelAllTimers()`. With the dictionary refactor (R3-2), `rampSubTimers.count` at cancellation time is the exact number of pending sub-haptics. Updated the log line: `log("haptic_cancelled", "phase=ramp_sub pending_count=\(pendingCount) source=ble")`. Plan §4.2 updated to document the new field.

### R3 self-review checklist

- [x] Re-read `HapticBeacon.swift` end-to-end after all five edits.
- [x] Re-read plan §3.1, §4.2, §4.5 changes; cross-checked against code reality.
- [x] No new lint diagnostics in `HapticBeacon.swift` (verified). No changes to `G7WatchSensorAdapter.swift` in R3.
- [x] Naming consistent across new symbols (`rampSubTimerFired` matches `rampFired` / `missFired`).
- [x] No scope creep into Cut 2 (`play(_:)` body unchanged) or Cut 3 (no source-filter changes).
- [x] No patch-stack interaction (Trio worktree only).
- [x] Cross-patch shadowing audit: `UUID` is unambiguous; `Foundation.UUID` not shadowed in scope.
- [x] Telemetry contract self-consistent across plan §4 (sub-sections 4.2 and 4.5 updated together).

### R3 done-criteria additions

On top of the eight Cut 1 + three R2 done criteria, two new R3-verifiable behaviors awaiting on-device verification:

- [ ] **Race-resilient ramp:** when a live BLE EGV arrives within ~3 s before a predicted ramp (`expected − rampLeadTime`), no spurious ramp sub-haptics fire after the success buzz. Better Stack should show `haptic_cancelled phase=ramp` at receipt time and *zero* `haptic_fired type=ramp_*` events for that cycle.
- [ ] **Warm-arm rejects expired cycles:** toggling the beacon ON when `bleLastEGVDate` is > 300 s old produces `warm_arm_skipped reason=cycle_already_expired anchor_age_s=<n>` log line and *no* immediate buzzes.

---

---

## Cut 1 — review round 4 (Claude + ChatGPT)

External review of the R3 worktree was solicited from Claude and ChatGPT. **Verdicts diverged**: Claude said "ship it" (no new bugs found, R3 fixes verified). ChatGPT (in two passes — first against the R3 code, then against the updated v1.7 plan/log) escalated a new blocker plus three medium findings that Claude missed. ChatGPT is correct on the blocker — the R3 `slot != nil` guards close the cancel-only race but not the cancel-and-reschedule race. Notes consolidated, evaluated, and dispositioned below.

### R4 consolidated finding table

| # | Source | Severity (reviewer → me) | Disposition | Fix location |
|---|---|---|---|---|
| 1 | ChatGPT — single-timer guards not identity-safe | Blocker / Blocker (real race) | **Fix** — add UUID identity tokens to `rampTimer` / `missTimer` / `successTimer`; wrappers check `xxxTimerID == id` instead of `xxxTimer != nil` | `HapticBeacon` (3 schedule sites + 3 wrappers + `cancelAllTimers`) |
| 2 | ChatGPT #1 — warm-arm 297–299 s window allows immediate ramp replay | Medium / Medium (UX edge) | **Fix** — push past-deadline check inside `rearm()` (skip ramp if `rampAt <= now`, skip miss if `missAt <= now`) so warm-arm in the 297–319 s window schedules only the still-future timers; loosen `setEnabled` gate to `< expectedCadence + missGracePeriod` (320 s) so partial warm-arm is reachable | `HapticBeacon.rearm` + `setEnabled` |
| 3 | ChatGPT #2 (first pass) — uploaded plan/log lag pasted R3 summary | Medium / None (sync resolved) | **No-op** — second pass confirmed the v1.7 docs landed. Recheck below in self-review | n/a |
| 4 | ChatGPT #3 — `fireRamp()` replaces `rampSubTimers` without defensive cancel | Low / Low (defense-in-depth) | **Fix** — cancel + remove existing entries at top of `fireRamp()` before assigning the new dictionary | `HapticBeacon.fireRamp` |
| 5 | ChatGPT (second pass) — plan §3.1 still has stale Properties bullet | Low / Low (doc drift) | **Fix in plan** — `rampSubTimers: [DispatchSourceTimer] = []` → dictionary; add `successTimer` slot; add R4 identity-token slots | `haptic-beacon-impl-plan.md` §3.1 |
| 6 | Claude — R3 verified correct ("ship it") | Verdict / Conflicts with #1 | **Override** — ChatGPT's race trace is correct; Claude only considered the cancel-without-reschedule case. R4 fixes the gap Claude missed | n/a |

### Per-finding evaluation

**1. ChatGPT — single-timer guards are not identity-safe (Blocker).** Confirmed real race. Claude validated the R3 guards against the cancel-without-reschedule race (correct: `cancelAllTimers()` runs, slot is nil, queued Task's `guard slot != nil` returns). But ChatGPT identifies a strictly worse race: cancel + reschedule + stale handler. Sequence:

1. Old `rampTimer` reaches deadline on `timerQueue`; `setEventHandler` closure runs there, dispatches `Task @MainActor`. Task is queued.
2. Live BLE EGV arrives a few ms before the predicted ramp. `noteEGVReceived` runs on `@MainActor`:
   - `cancelAllTimers()` → `rampTimer?.cancel()` (no-op, handler already fired), `rampTimer = nil`, log `haptic_cancelled phase=ramp`.
   - `lastReceiptAt = receiptDate`.
   - `fireSuccess()` → success buzz.
   - `rearm(after: receiptDate)` → `scheduleRampTimer(at: receiptDate + 297)` → **new** `rampTimer` is now in the slot, scheduled for ~297 s in the future.
3. Queued old `rampFired()` Task runs on `@MainActor`:
   - `guard rampTimer != nil` → **passes** (the new timer is in the slot).
   - `rampTimer = nil` → clears the **NEW** timer reference.
   - `fireRamp()` → schedules sub-timers immediately.
4. The new timer's underlying `DispatchSource` still fires at T+297 (cancellation didn't propagate because we just nilled the reference). Its handler runs `rampFired()` again, but now `rampTimer == nil` → guard returns. No fire.

User feels: success buzz → `.click` → `.start` (T+1) → `.notification` (T+2) immediately after the success — stale ramp from the previous cycle. The next cycle's ramp is silently lost.

Same race shape applies to `missFired()` (stale miss buzz immediately after a fresh success) and `playSecondSuccessBuzz()` (stale buzz #2 inside a new pair, then new pair's buzz #2 silently lost).

**Fix is the same identity-token pattern that R3 applied to `rampSubTimers` (where it works correctly because each entry has its own UUID key).** For the singletons:
- Add `rampTimerID: UUID?`, `missTimerID: UUID?`, `successTimerID: UUID?` slots.
- `scheduleRampTimer` / `scheduleMissTimer` / `fireSuccess` generate a UUID, set both `<slot>` and `<slot>ID`, and capture the UUID in the timer's event handler.
- `rampFired(id:)` / `missFired(id:)` / `playSecondSuccessBuzz(id:)` check `xxxTimerID == id` (identity match, not slot existence). If different, the slot has been reassigned to a fresh timer — return without touching it.
- `cancelAllTimers()` clears both timer and ID slots together.

After this: if a stale handler races a reschedule, the ID check fails (the new timer has a fresh UUID), the stale handler returns without touching the new timer's state, and the new timer's eventual fire is honored normally.

**2. ChatGPT #1 — warm-arm 297–299 s edge allows immediate ramp replay (Medium UX).** Confirmed. R3's `< expectedCadence` (300 s) gate prevents miss-grace-window replay but still allows the 297–299 s edge where `rampAt = receiptDate + 297` is in the past and `scheduleRampTimer(at: rampAt)` resolves to `max(0, ...) = 0` (immediate fire). So a user enabling at age 298 s feels: ramp `.click` immediately, `.start` at +1, `.notification` at +2 — two seconds before the actual EGV-due time, four seconds *after* the optimal ramp window. Borderline acceptable but not intentional.

ChatGPT suggests two paths: (a) skip ramp if past, schedule miss if useful; (b) tighten gate further. **Chose (a) with cleaner implementation**: push the past-deadline check **inside `rearm()`** itself so it's safe regardless of caller. `rearm()` becomes:
- If `rampAt > now`: schedule + `haptic_armed phase=ramp …`. Else: `rearm_skipped reason=deadline_passed phase=ramp anchor_age_s=<n>`.
- If `missAt > now`: schedule + `haptic_armed phase=miss …`. Else: `rearm_skipped reason=deadline_passed phase=miss anchor_age_s=<n>`.

The `setEnabled` gate then loosens from `< expectedCadence` (300 s) to `< expectedCadence + missGracePeriod` (320 s) — partial warm-arm in the 297–319 s window now schedules only the still-future miss timer (which gives the user a useful "oh, the EGV didn't actually arrive" signal if BLE is genuinely stalled). Beyond 320 s, both deadlines have passed and `cycle_already_expired` skips the warm-arm entirely.

Behavior matrix:
- age 0–296 s: warm-arm both ramp + miss.
- age 297–319 s: warm-arm partial — ramp skipped, miss scheduled (fires 0–22 s in the future).
- age 320+ s: skip warm-arm; wait for next live EGV.

The past-deadline check inside `rearm()` is also defensive for the live-EGV path: `noteEGVReceived` always calls with age=0, so both deadlines are 297–320 s in the future; check is a no-op. But future plumbing (Cut 3 source-agnostic hook with potentially stale `receiptDate` from a delayed phone-relay payload) is now safe.

**3. ChatGPT (first pass) — uploaded plan/log lag pasted R3 summary (Medium → no-op).** First-pass review was against a stale upload of the docs (still showing v1.6 / `rampSubTimers: [DispatchSourceTimer] = []`). Second pass confirmed the v1.7 docs landed correctly. **Verified in this round** by re-reading the plan top-to-bottom — see fix R4-4 below for one remaining stale Properties bullet caught by second pass.

**4. ChatGPT #3 — `fireRamp()` defensive cancel (Low).** Confirmed but low-impact after R4-1. The race ChatGPT worried about (stale `fireRamp()` running after cancellation) is closed by R4-1's identity tokens (`rampFired(id:)` returns without calling `fireRamp()` if the ID doesn't match). Still, defensive cleanup at the top of `fireRamp()` makes the invariant "rampSubTimers is empty before assignment" obvious to future readers and survives unrelated regressions:

```swift
rampSubTimers.values.forEach { $0.cancel() }
rampSubTimers.removeAll()
```

Adopted as belt-and-suspenders polish.

**5. ChatGPT (second pass) — plan §3.1 stale Properties bullet (Low).** Confirmed. Plan §3.1 "Properties" still has `private var rampSubTimers: [DispatchSourceTimer] = []` (line 42) — R3 updated the *method* descriptions and *Internal* bullets but missed the Properties block. Also missing: `successTimer` (added R2) and the new R4 identity-token slots. **Fix in plan**: rewrite Properties block to match current code reality.

**6. Claude — R3 verified "ship it" (Conflicts with #1).** Claude's R3 trace (lines 242–248 of the impl log) only considers the cancel-without-reschedule case ("`cancelAllTimers()` having nilled `rampTimer` causes this method to return without firing"). Correct as far as it goes, but the realistic race is cancel + reschedule + stale-handler, where the slot is re-populated before the stale handler runs. Claude missed this. ChatGPT's trace is correct. **Override Claude's verdict and apply R4-1.** The R3 race-residue caveat in plan §4.5 was written assuming the cancel-only race; it now applies to the cancel-and-reschedule race after R4-1 (semantics narrow but the principle is the same: log may slightly lead the actual suppressed event).

### Findings explicitly NOT addressed in R4

- **Precise warm-arm anchor** (R3 follow-up): plumbing `bleLastEGVReceiptDate` through `WatchState` or persisting `HapticBeacon.lastReceiptAt` to UserDefaults. Still deferred — Cut 1 is operational with approximate anchor + R4 partial-warm-arm safety net.
- **`fireRamp()` defensive cancel as required vs polish**: with R4-1 identity tokens in place, the defensive cancel is genuinely belt-and-suspenders. Adopted but documented as polish, not load-bearing.

---

## Cut 1 — review round 4 fixes log

Files modified in this round (worktree):

- **`Trio Watch App Extension/HapticBeacon.swift`** — three related changes (identity tokens for the three single-timer slots; past-deadline check inside `rearm()`; `setEnabled` gate loosen to 320 s; defensive cleanup at top of `fireRamp()`).
- **`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`** — §3.1 Properties block rewritten + §3.1 method docs updated + §4 telemetry additions for new `rearm_skipped reason=deadline_passed` field shape + changelog (v1.8).

### Fix R4-1 — Identity tokens for single timers (ChatGPT blocker)

**File:** `HapticBeacon.swift`. Three new `@MainActor` slots:

```swift
private var rampTimerID: UUID?
private var missTimerID: UUID?
private var successTimerID: UUID?
```

Each `schedule*` / `fireSuccess` site now generates a UUID, stores both timer + ID, and captures the UUID in the timer's `setEventHandler` closure:

```swift
let id = UUID()
timer.setEventHandler {
    Task { @MainActor in HapticBeacon.shared.rampFired(id: id) }
}
rampTimer = timer
rampTimerID = id
timer.resume()
```

`rampFired(id:)` / `missFired(id:)` / `playSecondSuccessBuzz(id:)` now take the UUID parameter and check identity:

```swift
private func rampFired(id: UUID) {
    guard rampTimerID == id else { return }
    rampTimerID = nil
    rampTimer = nil
    fireRamp()
}
```

If a fresh timer has been scheduled in the slot (different UUID), the stale handler returns without touching state. `cancelAllTimers()` clears both `<slot>` and `<slot>ID` together.

This is the same identity pattern R3 applied to `rampSubTimers` (which works correctly because each dictionary entry has its own UUID key). R4 generalizes the pattern to the three singleton slots.

### Fix R4-2 — Past-deadline skip inside `rearm()` (ChatGPT #1)

**File:** `HapticBeacon.swift`. `rearm(after:)` now checks each deadline against `Date()` before scheduling:

```swift
private func rearm(after receiptDate: Date) {
    let now = Date()
    let rampAt = receiptDate.addingTimeInterval(Self.expectedCadence - Self.rampLeadTime)
    let missAt = receiptDate.addingTimeInterval(Self.expectedCadence + Self.missGracePeriod)
    let anchorAgeSeconds = Int(now.timeIntervalSince(receiptDate))

    if rampAt > now {
        scheduleRampTimer(at: rampAt)
        log("haptic_armed", "phase=ramp expected_at=\(Int(rampAt.timeIntervalSince1970)) source=ble")
    } else {
        log("rearm_skipped", "reason=deadline_passed phase=ramp anchor_age_s=\(anchorAgeSeconds)")
    }

    if missAt > now {
        scheduleMissTimer(at: missAt)
        log("haptic_armed", "phase=miss expected_at=\(Int(missAt.timeIntervalSince1970)) source=ble")
    } else {
        log("rearm_skipped", "reason=deadline_passed phase=miss anchor_age_s=\(anchorAgeSeconds)")
    }
}
```

For the live-EGV path (age=0), both deadlines are 297–320 s in the future and the check is a no-op. For the warm-arm path with stale anchor (age 297–319 s), only the miss timer is scheduled — partial warm-arm with no stale ramp burst.

The existing `rearm_skipped` event name is reused with new `reason=deadline_passed` and per-deadline `phase` and `anchor_age_s` fields. Existing `reason=stale_gap` (from R2) is unaffected — different reason value, different field shape (`gap_s` vs `anchor_age_s`).

### Fix R4-3 — Loosen `setEnabled` gate to `expectedCadence + missGracePeriod` (ChatGPT #1, paired with R4-2)

**File:** `HapticBeacon.swift`. `setEnabled(true)` warm-arm gate changed from:

```swift
guard age < Self.expectedCadence else {  // 300 s
    log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))")
    return
}
```

to:

```swift
guard age < Self.expectedCadence + Self.missGracePeriod else {  // 320 s
    log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))")
    return
}
```

Combined with R4-2: ages 297–319 s are no longer skipped wholesale; they fall through to `rearm()` which schedules only the still-future miss timer. Ages 320+ s continue to skip with the same reason name.

The `cycle_already_expired` reason is kept (no rename) to minimize churn; the underlying semantic shifts from "ramp deadline passed" to "miss deadline also passed" — i.e. "the predicted cycle is fully past, no useful warm-arm possible." Comment updated in code to reflect the new threshold.

### Fix R4-4 — Defensive cleanup at top of `fireRamp()` (ChatGPT #3)

**File:** `HapticBeacon.swift`. `fireRamp()` now starts with:

```swift
rampSubTimers.values.forEach { $0.cancel() }
rampSubTimers.removeAll()
```

before the for-loop that builds the new dictionary. Belt-and-suspenders against future regressions; load-bearing logic is the R4-1 identity-token guard on `rampFired(id:)` (which prevents `fireRamp()` from being called by a stale handler in the first place).

### Fix R4-5 — Plan §3.1 Properties block + method docs (ChatGPT second pass)

**File:** `haptic-beacon-impl-plan.md` §3.1. Properties block rewritten to match current code:
- `rampSubTimers: [UUID: DispatchSourceTimer] = [:]` (dictionary, not array)
- New `successTimer: DispatchSourceTimer?` slot (added R2)
- New `rampTimerID`, `missTimerID`, `successTimerID: UUID?` slots (added R4-1)
- Description for each updated to reflect identity-token semantics

Method docs in same section updated:
- `setEnabled(_:)`: gate is now `< expectedCadence + missGracePeriod` (320 s), warm-arm path now goes through `rearm()` which may schedule only the miss timer.
- `rearm(after:)`: now describes per-deadline past-skip behavior with `rearm_skipped reason=deadline_passed` log.
- `rampFired` / `missFired` / `playSecondSuccessBuzz`: now take `id: UUID` and check identity, not slot nullity.

### R4 self-review checklist

- [x] Re-read `HapticBeacon.swift` end-to-end after all four code edits.
- [x] Re-read plan §3.1 (Properties + method docs) and §4 changes; cross-checked against code reality.
- [x] No new lint diagnostics in `HapticBeacon.swift` (verified). No changes to `G7WatchSensorAdapter.swift` in R4.
- [x] Naming consistent across new symbols (`rampTimerID` / `missTimerID` / `successTimerID` follow `xxxTimer` pattern).
- [x] No scope creep into Cut 2 (`play(_:)` body unchanged) or Cut 3 (no source-filter changes).
- [x] No patch-stack interaction (Trio worktree only).
- [x] Cross-patch shadowing audit unchanged from R3 (`UUID` is `Foundation.UUID`, unambiguous).
- [x] Telemetry contract self-consistent: new `rearm_skipped reason=deadline_passed phase=…` shape documented in plan §4 alongside existing `reason=stale_gap`.

### R4 done-criteria additions

On top of the eight Cut 1 + three R2 + two R3 done criteria, two new R4-verifiable behaviors awaiting on-device verification:

- [ ] **Cancel-and-reschedule race resilience:** when a live BLE EGV arrives within ~3 s before a predicted ramp (the same window that triggered R3-1 and R4-1), the **next** cycle's ramp still fires correctly at receipt+297 s. Specifically: zero spurious `haptic_fired type=ramp_*` events outside the (receipt+297..receipt+299) window.
- [ ] **Partial warm-arm in 297–319 s window:** toggling the beacon ON when `bleLastEGVDate` is between 297 s and 319 s old produces a `warm_armed` log with no immediate buzzes, then either a `haptic_fired type=retry` (miss) at the appropriate time *or* a `haptic_cancelled phase=miss` followed by a fresh `haptic_armed` cycle if a live BLE EGV arrives in the grace window. The `rearm_skipped reason=deadline_passed phase=ramp` log line should accompany the `warm_armed` event.

---

## Cut 1 — review round 5 (in-session red-team pass)

User asked for "another red-team review pass on the code changed for this haptic beacon feature" after the R4 round (which had been driven by external Claude + ChatGPT reviewers). This round was an in-session adversarial walk-through of the four code surfaces in scope (`HapticBeacon.swift`, `G7WatchSensorAdapter.swift` accessors + EGV hook, `TrioWatchApp.swift` scene-phase wire-up, `ComplicationDebugView.swift` toggle button, `WatchState.swift` mirror fields). Three real findings; none of them blockers. All three fixed in the same turn.

### Consolidated R5 findings table

| # | Severity | File | What | Fix outcome |
|---|---|---|---|---|
| R5-1 | Major (followup miss) | `G7WatchSensorAdapter.swift` lines 29–42 | Two new haptic-beacon accessors (`currentExtendedSession`, `isIntentionallyStopped`) still carried `(Cut 2 spike)` / `(R2 fix, GPT #3)` framing in their doc comments. The R4 comment-cleanup pass (per user request to remove review-round / reviewer / process language from code comments) only covered `HapticBeacon.swift`. | Fixed: both accessors rewritten to describe behavior and rationale from code context only. No review-round / reviewer references. |
| R5-2 | Minor (semantic) | `HapticBeacon.swift` `setEnabled` disable branch | `setEnabled(false)` cancelled timers but did not clear `lastReceiptAt`. Effect: toggle OFF → wait many minutes / hours / days → toggle ON (warm-arm gate fails silently if `bleLastEGVDate` is also stale, which it usually is by then) → next live BLE EGV arrives → `noteEGVReceived` compares `receiptDate` against the stale pre-OFF `lastReceiptAt` → `gap > staleThreshold (600 s)` → emits `rearm_skipped reason=stale_gap`. Behavior is correct (success buzz still fires; cycle re-establishes on the *next* EGV) but the log line is misleading: the BLE pipeline didn't actually have an outage; the user just had the beacon disabled. | Fixed: `setEnabled(false)` now sets `lastReceiptAt = nil`, matching `stop()`'s clear semantics. The next live EGV after a re-enable goes through the first-EGV-after-launch path (no `stale_gap` log, no spurious `rearm_skipped`). |
| R5-3 | Low (telemetry hole) | `HapticBeacon.swift` `setEnabled(true)` warm-arm guards | Three early returns produced no log: `guard !isAdapterStopped()`, `guard let bleLastEGV = …, bleLastEGV != .distantPast`, `guard age >= 0`. Analysts seeing `setEnabled enabled=true` followed by no `warm_armed` and no `warm_arm_skipped` had to inspect source code to reason about which gate fired. The fourth gate (`age < 320 s`) already logged `warm_arm_skipped reason=cycle_already_expired` (from R3 / R4-3). | Fixed: each silent guard now emits a `warm_arm_skipped` line with a distinct `reason` value: `adapter_stopped`, `no_anchor`, `anchor_in_future` (carries `anchor_age_s` since the value is informative for clock-skew diagnosis). The fourth `cycle_already_expired` reason is unchanged. |

### Findings explicitly verified safe (no change)

These were considered during the red-team pass and confirmed correct as-shipped from R4:

- **Identity-token guard** for `rampTimer` / `missTimer` / `successTimer` (R4-1) closes the cancel-and-reschedule race. Re-traced both the cancel-only and cancel-then-reschedule sequences end-to-end; the stale handler returns at the `xxxTimerID == id` check before touching the new timer's state.
- **`rampSubTimers` UUID self-removal** (R3-2): the `0.0`-delay sub-timer cannot race the dictionary assignment in `fireRamp()` because `fireRamp` runs synchronously on `@MainActor`, and the queued `Task @MainActor` from any timer event handler must wait for the next `@MainActor` turn (which is *after* the dictionary write).
- **EOS path interaction**: `triggerEndOfSessionFromEGV` does *not* set `isStopped`, so the previously-armed miss buzz still fires when sensor binding is reset by an EOS algorithm-state EGV. This is the correct UX — the user *expected* an EGV that didn't arrive (the EOS doesn't deliver an EGV the beacon should success-buzz on), and the miss buzz signals that absence.
- **No retain cycles** in `DispatchSourceTimer` event handlers: closures capture `HapticBeacon.shared` by name (singleton, never deallocated), not `self`. Equivalent to the adapter's `[weak self]` pattern in safety, simpler in intent.
- **Type alignment** for source filtering: `TrioComplicationDataSource` is `String, Codable, Equatable`; `source == .g7DirectBLE` and `source.rawValue` interpolation in `haptic_skipped` log lines are both sound.
- **Toggle ON race** with `WatchState.shared.bleLastEGVDate`: cold-launch ordering — `setEnabled(true)` reads `bleLastEGVDate` from `@MainActor` context. If the value is nil (no BLE EGV yet), the new `warm_arm_skipped reason=no_anchor` log fires and the next live EGV arms via `noteEGVReceived` normally. No code path produces double-arming.

### Open observation NOT fixed (low priority, deferred)

- **`HapticBeacon.start()` log per `.active` transition.** Called from `TrioWatchApp.scenePhase` change → during scene-phase flicker (active → inactive → active in a single tick) it emits a `start is_enabled=…` log per cycle. The adapter's own `start()` is carefully idempotent and quiet via the `!isStopped && sensor.isConnected { return }` short-circuit; the beacon's `start()` is a one-line log because there's nothing else to do. Acceptable today (very low cost), worth a flag if scene-phase-flicker telemetry noise becomes a problem in field logs.

---

## Cut 1 — review round 5 fixes log

Files modified in this round (worktree):

- **`Trio Watch App Extension/G7WatchSensorAdapter.swift`** — comment audit on the two haptic-beacon accessors only. No behavior change.
- **`Trio Watch App Extension/HapticBeacon.swift`** — `setEnabled` revised to clear `lastReceiptAt` on disable and emit distinct `warm_arm_skipped reason=…` lines from each warm-arm guard branch.
- **`docs/in-progress/haptic-beacon/haptic-beacon-impl-plan.md`** — §3.1 method docs for `setEnabled`, §4.4 suppression-reasons enumeration, §4.5.3 operational-queries note, changelog v1.9.
- **`docs/in-progress/haptic-beacon/haptic-beacon-impl-log.md`** (this file) — header bump + R5 sections + changelog v5.

### Fix R5-1 — Comment audit on `G7WatchSensorAdapter.swift` haptic-beacon accessors

**File:** `G7WatchSensorAdapter.swift`. Both accessors rewritten to remove review-round / reviewer / process language. Behavior unchanged; doc comments now describe what the accessor returns, why callers should use it (vs alternatives), and the lifecycle invariants the underlying flag honors.

`currentExtendedSession`:

```swift
/// Read-only accessor for the currently started extended runtime session.
///
/// The adapter may replace this reference from several paths (`stop()`,
/// `renewSessionIfNeeded()`, chain inside `extendedRuntimeSessionWillExpire`), so callers
/// must re-query on every use — never cache the returned reference.
var currentExtendedSession: WKExtendedRuntimeSession? { extendedSession }
```

`isIntentionallyStopped`:

```swift
/// Read-only mirror of the adapter's authoritative `isStopped` flag.
///
/// Use this instead of `WatchState.shared.g7DirectBleStatus == .off` when an external
/// subsystem needs to know whether the adapter was intentionally stopped. The published
/// status mirror defaults to `.off` at cold start (until `publishConnectionStatus()` runs)
/// and would falsely report "stopped" before the first BLE event. `isStopped` is mutated
/// only by `start()` (false) and `stop()` (true), so this accessor reflects intentional
/// lifecycle exactly.
var isIntentionallyStopped: Bool { isStopped }
```

Matches the R4 cleanup standard already applied to `HapticBeacon.swift` (no `Cut N`, no `R<n>`, no reviewer names, no plan-section pointers in inline comments — the changelog/log carries the provenance).

### Fix R5-2 — Clear `lastReceiptAt` on `setEnabled(false)` (semantic)

**File:** `HapticBeacon.swift`. `setEnabled(false)` branch was:

```swift
if !enabled {
    cancelAllTimers()
    log("setEnabled", "enabled=false action=cancelled_pending_timers")
    return
}
```

Now:

```swift
if !enabled {
    cancelAllTimers()
    // Clear the anchor so a later re-enable starts from the first-EGV-after-launch path
    // instead of comparing the next live EGV to a hours-old or days-old prior receipt
    // (which would correctly but confusingly emit `rearm_skipped reason=stale_gap`).
    lastReceiptAt = nil
    log("setEnabled", "enabled=false action=cancelled_pending_timers")
    return
}
```

Symmetry: `stop()` already clears `lastReceiptAt`. This change makes the disable path match `stop()`'s clear semantics. After this change, `noteEGVReceived` on the first live EGV after a re-enable sees `priorReceiptAt = nil` → first-EGV-after-launch path → fires success, `rearm` (no `stale_gap` log).

Net telemetry effect: the `rearm_skipped reason=stale_gap` log line will now fire only on actual long BLE outages while the beacon was *enabled*, not on the recovery EGV after a long *disable* period. Cleaner separation of concerns in field logs.

### Fix R5-3 — Distinct `warm_arm_skipped reason=…` per silent guard (telemetry)

**File:** `HapticBeacon.swift`. The four guards in `setEnabled(true)`'s warm-arm chain previously emitted only one `warm_arm_skipped` line (the fourth — `cycle_already_expired`). The other three returned silently, leaving analysts to infer "no warm-arm because of X" from source-code reading.

Pre-R5:

```swift
guard !isAdapterStopped() else { return }
guard let bleLastEGV = WatchState.shared.bleLastEGVDate,
      bleLastEGV != .distantPast else { return }
let age = Date().timeIntervalSince(bleLastEGV)
guard age >= 0 else { return }
guard age < Self.expectedCadence + Self.missGracePeriod else {
    log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))")
    return
}
```

Post-R5:

```swift
// Each early return below logs `warm_arm_skipped` with a distinct `reason` so analysts
// can tell "no warm-arm because of X" apart from "warm-arm logic never ran" when reading
// the trail after `setEnabled enabled=true`.
guard !isAdapterStopped() else {
    log("warm_arm_skipped", "reason=adapter_stopped")
    return
}
guard let bleLastEGV = WatchState.shared.bleLastEGVDate,
      bleLastEGV != .distantPast
else {
    log("warm_arm_skipped", "reason=no_anchor")
    return
}
let age = Date().timeIntervalSince(bleLastEGV)
guard age >= 0 else {
    log("warm_arm_skipped", "reason=anchor_in_future anchor_age_s=\(Int(age))")
    return
}
guard age < Self.expectedCadence + Self.missGracePeriod else {
    log("warm_arm_skipped", "reason=cycle_already_expired anchor_age_s=\(Int(age))")
    return
}
```

Field shapes (per plan §4.4):

- `reason=adapter_stopped` — no `anchor_age_s`. The anchor age isn't relevant; the gate is the adapter's `isStopped` flag.
- `reason=no_anchor` — no `anchor_age_s`. There is no anchor to age.
- `reason=anchor_in_future` — carries `anchor_age_s` (will be negative). Useful for clock-skew diagnosis.
- `reason=cycle_already_expired` — carries `anchor_age_s` (will be ≥ 320). Existing pre-R5 reason, unchanged.

Operational query update (plan §4.5.3): warm-arm skip count is now broken down by `reason` group rather than just `cycle_already_expired`.

### Fix R5-4 — Plan and log doc updates (this round)

**Files:** `haptic-beacon-impl-plan.md` (v1.8 → v1.9), `haptic-beacon-impl-log.md` (this file, v4 → v5).

Plan changes:
- §3.1 method docs for `setEnabled(_:)`: documents the new disable-clears-anchor invariant (R5-2) and enumerates the four `warm_arm_skipped` reasons with rationale (R5-3).
- §4.4 suppression reasons: full enumeration of the four `warm_arm_skipped reason=…` values with field shapes; cross-reference under `rearm_skipped reason=stale_gap` noting the R5-2 suppression of post-disable spurious stale-gap logs.
- §4.5.3 operational queries: warm-arm skip query updated to `count(warm_arm_skipped group by reason)` so the four reasons are visible in any breakdown.
- Changelog v1.9 entry summarizing all R5 changes with pointer back here.

Log changes (this section): consolidated R5 findings table, "verified safe" list, deferred-observation note, per-fix entries (R5-1 through R5-4), R5 self-review checklist, R5 done-criteria additions.

### R5 self-review checklist

- [x] Re-read `Trio Watch App Extension/HapticBeacon.swift` end-to-end after the `setEnabled` changes.
- [x] Re-read `Trio Watch App Extension/G7WatchSensorAdapter.swift` lines 29–43 after the comment audit; no behavior change, no other code in the file touched.
- [x] Re-read plan §3.1 `setEnabled` description, §4.4 suppression-reasons enumeration, §4.5.3 operational queries, and changelog v1.9 entry; cross-checked against code reality.
- [x] No new lint diagnostics (verified via Cursor lints). The two pre-existing SourceKit `No such module 'WatchKit'` / `No such module 'G7SensorKit'` false-positives are unchanged from baseline — they exist because the IDE doesn't have the watch target selected.
- [x] No scope creep: R5 doesn't touch `play(_:)` (Cut 2 surface), doesn't add any source-filter changes (Cut 3 surface), doesn't change any timer scheduling logic.
- [x] No patch-stack interaction (Trio worktree only; not regenerating any patch in `Trio-dev/patches/`).
- [x] Cross-patch shadowing audit unchanged from R4 (no new symbols introduced).
- [x] Telemetry contract self-consistent: the four `warm_arm_skipped reason=…` values are documented in plan §4.4 with field shapes; `setEnabled(false)` log line is unchanged in shape.
- [x] No comments in `HapticBeacon.swift` carry review-round / reviewer / plan-section / finding-id language (R4 audit standard preserved). R5 inline comments describe rationale from code context only (e.g. "Clear the anchor so a later re-enable starts from the first-EGV-after-launch path instead of comparing the next live EGV to a hours-old or days-old prior receipt").

### R5 done-criteria additions

On top of the eight Cut 1 + three R2 + two R3 + two R4 done criteria, three new R5-verifiable behaviors awaiting on-device verification:

- [ ] **Disable-clears-anchor:** with the beacon enabled and a recent BLE EGV (so `lastReceiptAt` is set), toggle the beacon OFF, wait > 10 minutes, toggle the beacon ON. The next live BLE EGV produces a `setEnabled enabled=true`, `warm_arm_skipped reason=cycle_already_expired` (because `bleLastEGVDate` is also stale by now), then **`haptic_fired type=success_1` … `success_3`** (Cut 4 triple) and `haptic_armed phase=ramp`/`phase=miss`. **No `rearm_skipped reason=stale_gap` log line should appear** on this recovery EGV (pre-R5, it would have).
- [ ] **`warm_arm_skipped reason=adapter_stopped`:** with the adapter intentionally stopped (e.g. via the existing G7 BLE OFF action in the debug view), toggle the beacon ON. A `warm_arm_skipped reason=adapter_stopped` log line should appear (no `anchor_age_s` field).
- [ ] **`warm_arm_skipped reason=no_anchor`:** at cold launch with no BLE EGV yet received this process (`WatchState.shared.bleLastEGVDate == nil`), toggle the beacon ON. A `warm_arm_skipped reason=no_anchor` log line should appear (no `anchor_age_s` field). The next live BLE EGV arms normally via `noteEGVReceived`.

---

## R6 — multi-source safety + UX polish (review pass)

External review of the post-R5 + Cut2/Cut3/Cut4 worktree was solicited from Claude and ChatGPT. ChatGPT escalated **two real blockers** in the multi-source plumbing landed by Cut 3 + Cut 4: (1) WC / HK hooks treated "state updated now" as "fresh EGV received now" with no dedup, and (2) `.all` mode let stale or duplicate WC / HK readings displace an active BLE cycle. The user then provided five **product decisions** that lock down the multi-source policy. R6 implements all of ChatGPT's findings, both Claude minor-fix items, and aligns the source-filter UI / haptic feel to the product decisions.

### R6 product decisions (authoritative)

1. **Success haptic = BLE only.** The triple `.success` confirms a fresh **direct BLE** reading. WC / HealthKit relayed deliveries do not fire it.
2. **Relayed-source miss suppression:** allowed, but only when the relayed payload is genuinely new (passes the dedup gate) and BLE is stale enough (passes the precedence gate).
3. **Relayed-source cadence arming:** fallback only. BLE remains the primary cadence anchor; relayed deliveries can arm only when no recent BLE EGV exists (`bleFreshnessWindow = 360 s`).
4. **Debug UI label:** rename "All" to "BLE + relayed". Persisted enum case becomes `.bleAndRelayedFallback` (raw `"ble_relayed_fallback"`); historical `"all"` migrates to it.
5. **Different feel by source:** relayed cycles fire a single quiet `.click` (`relayed_confirm`), not the BLE success triple.

### Consolidated finding table

| # | Source | Severity (reviewer) | Severity (this log) | Disposition | Fix location |
|---|---|---|---|---|---|
| 1 | ChatGPT blocker — WC/HK call `noteEGVReceived(at: Date())` without dedup | Blocker | Blocker (false success / wrong anchor / suppressed real miss) | **Fix** — add `readingDate` parameter; track `lastAcceptedReadingDate`; reject duplicates with `egv_ignored reason=duplicate` | `HapticBeacon.noteEGVReceived` + BLE adapter call site + both WatchState hooks |
| 2 | ChatGPT blocker — `.all` lets WC/HK override BLE | Blocker | Blocker (BLE is the authoritative cadence) | **Fix** — track `lastBLEReceiptAt`; reject relayed source while `bleAge < bleFreshnessWindow` (360 s) with `egv_ignored reason=ble_recent` | `HapticBeacon.noteEGVReceived` |
| 3 | ChatGPT — `cancelAllTimers()` clearing `lastCycleSource` is risky in a generic helper | Conceptual | Medium (drift risk in future edits) | **Fix** — split into `cancelAllTimers()` (timers only) and `clearCurrentCycle()` (timers + cycle source); teardown vs. rearm callers use the appropriate one | `cancelAllTimers`, `clearCurrentCycle`, `stop`, `setEnabled(false)`, `setSourceFilter` narrowing |
| 4 | ChatGPT — `success_sub` cancellation telemetry semantics | High (telemetry meaning shift) | High (analyst confusion) | **Fix-in-doc + sync first beat (#5)** — synchronous `success_1` makes `phase=success_sub` describe companion-beat cancellation only; documented in plan §4.2 and `successSubTimers` doc comment | `fireSuccess`, `successSubTimers` doc, plan §4.2 |
| 5 | ChatGPT — 0.0 sub-timer can be cancelled before first haptic plays | High (lost confirmation) | High | **Fix** — play first beat of success/miss synchronously; sub-timers from `steps.dropFirst()` | `fireSuccess`, `fireMiss` |
| 6 | ChatGPT — duplicate ramp labels lose event-level visibility | High (analysis quality) | High | **Fix** — unique labels `ramp_click_1`/`_2`, `ramp_start_1`/`_2`, `ramp_notif_1`/`_2`/`_3` | `fireRamp` + plan §§4.1, 4.5, Cut 4 table |
| 7 | ChatGPT — code comments reintroduced "Cut 4" references | Medium | Medium (matches R4 cleanup standard) | **Fix** — rewrite source-doc comments behavior-focused; no review-round / cut references in code | `HapticBeacon.swift` headers + inline comments |
| 8 | ChatGPT + product decision — "All" label is misleading | Medium | Medium (UI honesty) | **Fix** — rename `SourceFilter.all` → `.bleAndRelayedFallback`; raw `"ble_relayed_fallback"`; debug button "BLE + relayed"; `"all"` raw value migrates | `HapticBeacon.SourceFilter` + `sourceFilter` getter migration + `ComplicationDebugView` |
| 9 | ChatGPT — `setSourceFilter(.ble)` cancels but does not warm-arm | Medium (UX) | Medium | **Fix** — factor `attemptBLEWarmArm(trigger:)`; `setSourceFilter(.ble)` calls it after cancel (with `trigger="source_filter_narrow"`) | `attemptBLEWarmArm`, `setSourceFilter`, `setEnabled` |
| 10 | ChatGPT — WC + HK can double-fire on same reading | Blocker (covered by #1) | Same fix as #1 | (covered) | (covered) |
| Claude #1 | WatchState hook thread safety | Minor (verify) | Minor (defensive) | **Fix** — wrap WatchState calls in `Task { @MainActor in … }` to match the file's existing 7+ uses of the pattern. BLE adapter call stays direct (adapter is `@MainActor`). | both WatchState hook sites |
| Claude #2 | WC hook fires regardless of `minInterval=5` debounce | Minor (maintainer note) | Minor (mitigated by R6 dedup) | **Fix** — add comment at WC call site explaining beacon-side `lastAcceptedReadingDate` dedup is what protects against batched WC; data-store guard does not | WC hook site comment |
| Claude #3 | `session.state` read twice in `play()` | Cosmetic | Cosmetic | **Fix** — capture `session.state.rawValue` once before `notifyUser` and reuse for the log line | `play(_:label:)` |

### Per-finding implementation notes

**Findings 1, 2, 10 — dedup + source precedence (the core blocker pair).**

`noteEGVReceived` signature is now `(at: Date, readingDate: Date, source: TrioComplicationDataSource)`. Two new private state slots:

- `lastAcceptedReadingDate: Date?` — set in step 5 of the accept pipeline (after dedup passes). Reading whose `readingDate <= last` is dropped before any state mutation.
- `lastBLEReceiptAt: Date?` — set in step 5 only when `source == .g7DirectBLE`. Drives the precedence gate.

Pipeline order in `noteEGVReceived` (matches plan §3.1 R6 update):

1. `isEnabled` early-return.
2. `accepts(source:under:)` — `egv_ignored reason=source_filtered` on reject.
3. `isAdapterStopped()` — `clearCurrentCycle()` + `haptic_skipped reason=adapter_stopped phase=success` on reject.
4. **Dedup** — `egv_ignored reason=duplicate reading_age_s=<int>` on reject.
5. **Source precedence** (skipped for BLE source) — `egv_ignored reason=ble_recent ble_age_s=<int>` on reject.
6. Capture prior receipt → `cancelAllTimers()` → assign `lastReceiptAt` / `lastCycleSource` / `lastAcceptedReadingDate` / (if BLE) `lastBLEReceiptAt` → fire (`fireSuccess` for BLE, `fireRelayedConfirm` for relayed).
7. Stale-gap check; otherwise `rearm(after: receiptDate)`.

Both WatchState hooks now capture the snapshot `readingDate` to a local before the `Task { @MainActor in … }` wrapper so the value is captured deterministically:

```swift
let hkReadingDate = snapshot.readingDate
Task { @MainActor in
    HapticBeacon.shared.noteEGVReceived(at: Date(), readingDate: hkReadingDate, source: .healthKit)
}
```

The BLE adapter call site (`G7WatchSensorAdapter.swift:659`) passes the already-computed `readingDate` local.

**Finding 3 — split `cancelAllTimers()` from cycle-source clearing.**

`cancelAllTimers()` now cancels only timer slots; documented as `(timers only)`. New `clearCurrentCycle()` calls `cancelAllTimers()` then `lastCycleSource = nil`. Teardown callers (`stop`, `setEnabled(false)`, `setSourceFilter` narrowing) use `clearCurrentCycle()`. Rearm callers (`noteEGVReceived` accept path, `attemptBLEWarmArm`) use `cancelAllTimers()` and reassign `lastCycleSource` immediately. Cancellation telemetry still tags the prior cycle (the source slot is still set when `cancelAllTimers()` runs).

**Findings 4 + 5 — sync first beat for success / miss.**

`fireSuccess()` plays `successBuzzSteps[0]` (`success_1`) synchronously through `play(_:label:)`, then schedules `successBuzzSteps.dropFirst()` (success_2 at +200 ms, success_3 at +350 ms) as `successSubTimers` entries. Same pattern for `fireMiss()` with `missRetrySteps`. The `successSubTimers` / `missSubTimers` doc comments describe these as **companion** beats so `phase=success_sub` / `phase=miss_sub` cancellation telemetry is no longer ambiguous about whether the confirmation itself was lost.

**Finding 6 — unique ramp labels.**

Updated `fireRamp` step array to `ramp_click_1`, `ramp_click_2`, `ramp_start_1`, `ramp_start_2`, `ramp_notif_1`, `ramp_notif_2`, `ramp_notif_3`. Each beat is now identifiable in Better Stack without grouping by `expected_at` window. Ramp accounting in plan §4.5.2 simplifies: `count(haptic_fired type=ramp_click_1)` is a 1:1 proxy for "ramp triggered at all".

**Finding 7 — comment cleanup.**

Removed every `Cut 4` reference from the source file. The header docstring describes behavior (e.g. "Pre-EGV ramp: seven beats from T-5s through ~T-0.5s"); the constants describe rationale ("Ramp begins this far before expected EGV"); the sub-timer doc comments describe the behavior contract (e.g. "Companion sub-timers for the success triple"). Matches the R4 cleanup standard previously applied to the file.

**Finding 8 — `SourceFilter` rename + UI relabel.**

```swift
enum SourceFilter: String {
    case ble
    case bleAndRelayedFallback = "ble_relayed_fallback"
}
```

The `sourceFilter` getter falls back gracefully:

```swift
guard let raw = UserDefaults.standard.string(forKey: Keys.sourceFilter) else { return .ble }
if let value = SourceFilter(rawValue: raw) { return value }
if raw == "all" { return .bleAndRelayedFallback }   // historical migration
return .ble
```

Existing testers who toggled the old `.all` keep their preference under the new policy without a `UserDefaults` reset. The debug button reads "Source: BLE only" / "Source: BLE + relayed" with toast "📡 Haptic Source: BLE + relayed fallback" on switch.

**Finding 9 — `setSourceFilter(.ble)` warm-arm.**

Factored `attemptBLEWarmArm(trigger: String)` out of `setEnabled(true)`. Two callers:

- `setEnabled(true)` → `attemptBLEWarmArm(trigger: "setEnabled")`
- `setSourceFilter(.ble)` (when narrowing displaces a non-BLE cycle) → `clearCurrentCycle()` + `attemptBLEWarmArm(trigger: "source_filter_narrow")`

Each silent guard logs `warm_arm_skipped reason=… trigger=<trigger>`. The `trigger=` field is **R6** new across `warm_armed` and all four `warm_arm_skipped reason=` values.

**Claude #1 — thread safety.**

`G7WatchSensorAdapter` is `@MainActor` (declared at line 15), so the BLE call site stays direct. `WatchState` is `@Observable final class WatchState: NSObject, WCSessionDelegate` (line 75) — not `@MainActor`. The two hook sites previously called the `@MainActor` `noteEGVReceived` directly; in Swift 5 minimal-concurrency mode this compiles (with possible warning) but is not unambiguously safe under stricter modes. Wrapped both in `Task { @MainActor in … }` to match the file's existing 7+ `DispatchQueue.main.async { @MainActor in … }` / `Task { @MainActor in … }` patterns (lines 1175, 1268, 1336, 1444, 1728, 1781).

Latency cost is one main-actor reschedule (microseconds when already on main thread); first success beat of a fresh BLE EGV is unaffected because the BLE call site is direct. Relayed cycles (WC / HK) get the synchronous `.click` from `fireRelayedConfirm` after the Task hop — perceptually still "instant" relative to the data-store save that preceded it.

**Claude #2 — WC pre-debounce.**

The data-store's `minInterval=5` debounce protects the data store, not the beacon. With **R6** dedup, batched WC deliveries for the *same* reading (same `readingDate`) are caught by `lastAcceptedReadingDate` and produce `egv_ignored reason=duplicate`. Batched WC deliveries for *distinct* readings (rare in steady state, possible during catch-up) will each fire `relayed_confirm` if BLE is stale — which is the desired behavior. Comment added at the WC hook site documenting this so future maintainers don't assume the data-store guard covers the beacon.

**Claude #3 — `session.state` read twice.**

`play(_:label:)` now reads `session.state.rawValue` once into `stateAtPlay` immediately before `notifyUser(haptic:)`, then uses that captured value in the log line. Eliminates the cosmetic risk of the gate and the log disagreeing if the session transitions between the two reads.

### R6 plan deviations (none)

All R6 changes implement plan v1.13 §"R6 — multi-source safety and UX polish" exactly. The product decisions and 13-row fix list disposition were authored together with this implementation.

### Files modified (R6)

- `Trio Watch App Extension/HapticBeacon.swift` — full rewrite (565 lines):
  - New constants: `bleFreshnessWindow`.
  - New state: `lastAcceptedReadingDate`, `lastBLEReceiptAt`.
  - `SourceFilter.all` → `.bleAndRelayedFallback` (raw `"ble_relayed_fallback"`); migration in `sourceFilter` getter.
  - `noteEGVReceived(at:readingDate:source:)` new signature; 7-step accept pipeline; new `egv_ignored reason=duplicate|ble_recent` paths.
  - New helpers: `attemptBLEWarmArm(trigger:)`, `clearCurrentCycle()`, `fireRelayedConfirm()`.
  - `fireSuccess()` / `fireMiss()` — synchronous first beat; sub-timers from `dropFirst()`.
  - `fireRamp()` — unique labels per beat.
  - `cancelAllTimers()` — no longer clears `lastCycleSource`.
  - `play(_:label:)` — single state read before `notifyUser`.
  - Header docstring + inline comments rewritten (no review-round / cut references).
- `Trio Watch App Extension/G7WatchSensorAdapter.swift` — call site updated to pass `readingDate: readingDate`.
- `Trio Watch App Extension/WatchState.swift` — both hooks now `Task { @MainActor in … }`-wrapped, pass `readingDate`, WC hook gains debounce-explanation comment.
- `Trio Watch App Extension/Views/ComplicationDebugView.swift` — `SourceFilter` rename propagated to button label / SF Symbol switch; toast text "BLE + relayed fallback".

### Self-review checklist (per Trio AGENTS.md)

- [x] Re-read all four modified files top to bottom after edits (`HapticBeacon.swift` rewrite, two WatchState hook sites, BLE adapter line, debug button block).
- [x] All new symbols (`lastAcceptedReadingDate`, `lastBLEReceiptAt`, `bleFreshnessWindow`, `attemptBLEWarmArm`, `clearCurrentCycle`, `fireRelayedConfirm`, `bleAndRelayedFallback`) referenced consistently across the file. The historical `lastCycleSource = nil` line that was inside `cancelAllTimers()` is gone (now in `clearCurrentCycle()` only); every callsite using `cancelAllTimers()` either reassigns `lastCycleSource` immediately (rearm path) or is a teardown that calls `clearCurrentCycle()` instead.
- [x] No half-finished edits or stale TODOs in the changed surface.
- [x] No project file edits or `sync_project_files.rb` invocations (AGENTS rule 6); no new files added.
- [x] No `xcodebuild` / `ci/local-build.sh` runs (AGENTS rule 10); static review + lint check only.
- [x] Lint check via `ReadLints` over the four modified files: zero new warnings/errors. Pre-existing items: `G7WatchSensorAdapter.swift` has 27 long-standing line-length / function-length / identifier-name lints unrelated to the one-line R6 edit; `WatchState.swift` shows the pre-existing SourceKit `No such module 'WatchConnectivity'` false-positive.
- [x] Cross-patch shadowing audit unchanged (no new symbol names introduced that conflict with the existing `NotificationCenter` protocol shadow or any other in-scope name).
- [x] Telemetry contract: every accept-path branch emits exactly one log line; every reject-path branch emits exactly one `egv_ignored` / `haptic_skipped`. The accept path emits `haptic_fired` (via `play`) for either `success_1` or `relayed_confirm` followed by `haptic_armed phase=ramp` and `haptic_armed phase=miss` (or `rearm_skipped reason=stale_gap` when the gap exceeds threshold).
- [x] Source-precedence + dedup interact safely with warm-arm: `attemptBLEWarmArm` sets `lastAcceptedReadingDate = bleLastEGV` so the very next live BLE EGV with the same `readingDate` is rejected as `duplicate` (correctly avoiding a redundant cycle). The next live EGV with a newer `readingDate` accepts normally.

### R6 done-criteria (on-device verification)

(In addition to the criteria from Cuts 1–4 + R2–R5.)

- [ ] WC or HK delivery with the same `readingDate` as a prior BLE accept logs `egv_ignored reason=duplicate` and does not fire any haptic.
- [ ] WC or HK delivery while `lastBLEReceiptAt` is < 360 s old logs `egv_ignored reason=ble_recent`.
- [ ] In `.bleAndRelayedFallback` mode with BLE quiet (no BLE accept ≥ 360 s), a fresh WC / HK delivery fires a single `haptic_fired type=relayed_confirm` and arms a relayed cycle (no `success_*` beats).
- [ ] `setSourceFilter(.ble)` while a non-BLE cycle is armed emits `setSourceFilter value=ble action=cancelled_pending_timers prior_cycle_source=<wc|hk>` followed by either `warm_armed trigger=source_filter_narrow` (BLE recent) or `warm_arm_skipped reason=… trigger=source_filter_narrow` (BLE not recent).
- [ ] Each ramp beat is identifiable by a unique `type=` label in Better Stack (`ramp_click_1`, `ramp_click_2`, `ramp_start_1`, `ramp_start_2`, `ramp_notif_1`, `ramp_notif_2`, `ramp_notif_3`).
- [ ] Mid-success-triple cancellation logs `phase=success_sub pending_count=1|2`; mid-miss-double cancellation logs `phase=miss_sub pending_count=1`. Neither indicates a missed confirmation (first beat of each was synchronous and would have logged `haptic_fired type=success_1` / `retry_1` before cancellation).
- [ ] Historical `"all"` source-filter preference still loads the new policy (no `UserDefaults` reset required).

---

## R7 — warm-arm invariant tightening (review pass)

A second external review pass was solicited on the post-R6 worktree from Claude (round 2) and ChatGPT (round 3). The two reviewers disagreed on the central question — whether warm-arm seeding `lastAcceptedReadingDate` poisons subsequent BLE delivery — so R7 begins with a verification step before any code change.

### Verification of the central disagreement

ChatGPT's "blocker 1" claim: warm-arm sets `lastAcceptedReadingDate = bleLastEGV`; if the next real BLE callback arrives with the same `readingDate`, the dedup gate at the top of `noteEGVReceived` will drop it as a duplicate and no success triple will fire.

Claude's defense: the next real BLE reading will have a strictly newer `readingDate`, so the dedup gate will pass.

To resolve, traced the BLE delivery path in `Trio Watch App Extension/G7WatchSensorAdapter.swift`. Lines 578–580:

```swift
if let lastSeq = lastReadingSequence, lastSeq == glucose.sequence {
    log("egv_dedup", "glucose=\(glucose.glucose.map(String.init) ?? "nil") sequence=\(glucose.sequence)")
    return
}
```

Same `sequence` is filtered before `noteEGVReceived` is ever called. `readingDate` is computed from `glucose.glucoseTimestamp` (line 600), which is a function of the sensor sequence. Therefore: **same sequence ⇒ same `glucoseTimestamp` ⇒ same `readingDate`**. Two `noteEGVReceived` calls cannot share a `readingDate` from the live BLE path.

ChatGPT's literal blocker scenario cannot occur. Claude is correct on the central point. No code change for "blocker 1".

However, ChatGPT's deeper invariant point (medium #1: warm-arm should not write `lastBLEReceiptAt` because that slot is documented as a watch receipt time, while warm-arm uses a sensor reading time) is a legitimate clean-up. Adopted that with rationale.

### Per-finding disposition

| # | Reviewer | Severity claimed | Disposition | Rationale |
|---|---|---|---|---|
| 1 | ChatGPT — "blocker 1": warm-arm seeding `lastAcceptedReadingDate = bleLastEGV` poisons the next real BLE EGV | Blocker | **Disagree, no code change.** G7 adapter dedups same-`sequence` deliveries before they reach `noteEGVReceived` (citation above). Spelled the invariant out in the `lastAcceptedReadingDate` doc comment so future readers do not re-litigate. |
| 2 | ChatGPT — "blocker 2": dedup may drop newer-source recovery after stale BLE if dedup state is poisoned | Blocker (conditional on #1) | **Resolved by docs + #4.** Once the property doc comments precisely define what `lastAcceptedReadingDate` represents (real arrival OR warm-arm anchor) and `lastBLEReceiptAt` is no longer poisoned, the precedence + dedup interaction matches the intent. |
| 3 | ChatGPT — "high-risk": relayed-fallback `.click` may be misread as "BLE healthy" | High | **No code change; intent affirmed.** Already covered by R6 product decision #5 ("different feel"). On-device validation should explicitly confirm testers can distinguish `.click` (relayed) from `.success` triple (BLE) at the wrist. |
| 4 | ChatGPT — "medium 1": `lastBLEReceiptAt = bleLastEGV` in warm-arm conflates two clocks | Medium | **Adopted.** `attemptBLEWarmArm` no longer writes `lastBLEReceiptAt`. Property doc comment makes the "only real BLE deliveries write this slot" invariant explicit. Behavior change: after warm-arm, a fresh relayed reading with a newer `readingDate` is allowed to arm a relayed cycle (no false "BLE recent" rejection). This is correct: warm-arm is a synthetic recovery, not a guarantee that BLE just delivered. |
| 5 | ChatGPT — "medium 1 invariant": dedup-state writers should be limited to real-EGV-acceptance paths | Medium | **Partially adopted.** `lastAcceptedReadingDate` is still written by warm-arm — Claude's defense is correct that this blocks WC / HK echoes of the warm-arm anchor from arming a redundant cycle. The doc comment now lists warm-arm as a documented exception with the precise invariant (warm-arm seeds with the synthetic anchor; live BLE arrivals will be strictly newer). |
| 6 | ChatGPT — "medium 2": `setEnabled(false)` clears `lastAcceptedReadingDate`, so a quick disable / re-enable could allow a replay | Medium | **No code change; documented.** Acceptable for the current debug-only beacon toggle. Inline comment added at the clear site noting that, if the toggle becomes user-facing, dedup state should survive enable cycles within the process lifetime. |
| 7 | ChatGPT — "medium 3": file-level docstrings becoming a mini design doc | Medium | **Deferred.** Active development; the docstrings serve as the local source of truth. Pre-upstream-PR cleanup task — not blocking on-device validation. |
| 8 | ChatGPT — "medium 4": pre-existing `R5c —` comment in `WatchState.swift` violates source-comment hygiene | Medium | **Out of scope.** That comment belongs to the watch G7 BLE observer initiative tracked at `Trio-dev/docs/in-progress/watch-g7-direct-ble-observer/`, not the haptic beacon. |
| 9 | Claude — `guard let firstStep = …` in `fireSuccess` / `fireMiss` is defensive on a non-empty static; cosmetic inconsistency with `fireRamp` | Cosmetic | **Documented in code.** Inline comments explain the static array is non-empty by construction and the guard exists to make the synchronous-first / companion-rest pattern locally obvious to a future maintainer. Behavior unchanged. |

### Per-finding implementation notes

**Finding 4 — `lastBLEReceiptAt` no longer seeded by warm-arm.**

Removed the `lastBLEReceiptAt = bleLastEGV` line from `attemptBLEWarmArm`. The remaining warm-arm sequence is:

```swift
cancelAllTimers()
lastReceiptAt = bleLastEGV
lastCycleSource = .g7DirectBLE
// Seeded for dedup only. See `lastAcceptedReadingDate` doc for the invariant.
lastAcceptedReadingDate = bleLastEGV
// Note: `lastBLEReceiptAt` is intentionally not seeded.
rearm(after: bleLastEGV)
log("warm_armed", ...)
```

**Property doc updates** in the same file:

- `lastAcceptedReadingDate`: a new "Warm-arm exception" paragraph spells out the invariant (warm-arm seeds with the synthetic anchor; the G7 adapter same-`sequence` dedup at `G7WatchSensorAdapter.swift:578–580` guarantees the next live BLE EGV has a strictly newer `readingDate` and accepts normally).
- `lastBLEReceiptAt`: a new "Only real BLE deliveries write this slot" paragraph explains that warm-arm uses a sensor `readingDate`, not a watch receipt time, so storing it would conflate clocks.

**Behavioral consequence to verify on device:** during the warm-armed window (after `setEnabled(true)` or `setSourceFilter(.ble)`), a fresh WC / HK delivery with a strictly newer `readingDate` than the warm-arm anchor will arm a relayed cycle and fire `relayed_confirm` — because `lastBLEReceiptAt` is no longer falsely reading "BLE just arrived". Same-`readingDate` echoes are still blocked by dedup. New R7 done-criterion records this expectation.

**Finding 6 — `setEnabled(false)` dedup-clearing comment.**

Added an inline comment at the `lastAcceptedReadingDate = nil` line acknowledging that this allows a quick disable / re-enable inside one cycle to re-accept the just-seen reading. Acceptable for the current debug-only beacon toggle (used for on-device verification). If the toggle becomes user-facing in a future cut, the comment instructs the maintainer to consider preserving dedup across enable toggles within the process lifetime.

**Finding 9 — defensive-guard comments.**

`fireSuccess` and `fireMiss` both unwrap their static step array's `first` element to play synchronously, then schedule `dropFirst()` as sub-timers. Inline comments now explain that `successBuzzSteps` / `missRetrySteps` are non-empty by construction and the `guard` is a readability anchor for the synchronous-first / companion-rest pattern (so a future maintainer comparing this method against `fireRamp`, which has no equivalent guard, understands why the asymmetry exists).

### R7 plan deviations (none)

All R7 changes implement plan v1.14 §"R7 — warm-arm invariant tightening" exactly. The verification step against `G7WatchSensorAdapter.swift:578–580` is recorded both in this section and in the plan's R7 disposition table.

### Files modified (R7)

- `Trio Watch App Extension/HapticBeacon.swift` only:
  - `attemptBLEWarmArm`: removed `lastBLEReceiptAt = bleLastEGV`; tightened inline rationale at the assignment site.
  - `lastAcceptedReadingDate` property doc: added "Warm-arm exception" paragraph with adapter-dedup citation.
  - `lastBLEReceiptAt` property doc: added "Only real BLE deliveries write this slot" paragraph.
  - `fireSuccess`, `fireMiss`: defensive-guard explanation comments.
  - `setEnabled(false)`: inline comment on dedup-clearing trade-off.

No changes to `WatchState.swift`, `G7WatchSensorAdapter.swift`, `ComplicationDebugView.swift`, or any other file. R6's WatchState `Task { @MainActor in … }` wrappers, the BLE adapter `readingDate` plumbing, and the debug UI label remain as landed.

### Self-review checklist (per Trio AGENTS.md)

- [x] Re-read the modified file (`HapticBeacon.swift`) top to bottom after edits — all five edit sites cohesive; property docs / call-site comments / sync-first-beat guards / setEnabled comment all reference the same invariants.
- [x] No half-finished edits or stale TODOs in the changed surface. The only writers of `lastBLEReceiptAt` are now the BLE branch of `noteEGVReceived` and the `setEnabled(false)` clear (matches the doc claim).
- [x] No project file edits or `sync_project_files.rb` invocations (AGENTS rule 6); no new files added.
- [x] No `xcodebuild` / `ci/local-build.sh` runs (AGENTS rule 10); static review + lint check only.
- [x] Lint check via `ReadLints` over `HapticBeacon.swift`: zero new warnings/errors.
- [x] Verified the central disagreement against the actual G7 adapter source code before adopting / rejecting either reviewer's position; cited the line numbers.
- [x] Behavior contract preserved for the documented R6 done-criteria; new behavior (relayed cycle armable during warm-armed window when no real BLE since process start) recorded as a new R7 done-criterion.

### R7 done-criteria (on-device verification)

(In addition to the criteria from Cuts 1–4 + R2–R6.)

- [ ] `setEnabled(true)` while `WatchState.shared.bleLastEGVDate` is recent emits `warm_armed`, and the next live BLE EGV (different `sequence`, hence strictly newer `readingDate`) fires `haptic_fired type=success_1` followed by `success_2` / `success_3` — no `egv_ignored reason=duplicate` line precedes it.
- [ ] `setEnabled(true)` followed by a WC / HK delivery whose `readingDate` exactly matches `bleLastEGVDate` logs `egv_ignored reason=duplicate` and fires no haptic.
- [ ] `setEnabled(true)` warm-arm on a fresh process (no prior live BLE arrivals via `noteEGVReceived`) followed by a WC / HK delivery with a strictly newer `readingDate` arms a relayed cycle and fires `relayed_confirm` — no `ble_recent` rejection precedes it (because warm-arm did not seed `lastBLEReceiptAt`).
- [ ] Better Stack search across the validation window confirms zero pairs of `egv_ignored reason=duplicate source=ble` immediately preceding a missing `haptic_fired type=success_1` — i.e., warm-arm seeding never suppresses a real BLE success in production telemetry.

---

## R8 — stale-gap-relayed recovery + dedup log enrichment (review pass)

A third external review pass (ChatGPT round 4) on the post-R7 worktree was a "close to bless" with one remaining product-behavior concern around the stale-gap rule applying uniformly to all sources, plus three explicitly non-blocking notes. R8 adopts ChatGPT's recommended option for the stale-gap concern — let relayed fallback restore cadence after a long BLE outage when the relayed reading is itself fresh — and the small log-enrichment non-blocking note (it's a tiny change with operational value and lives in the same edit surface as the dedup gate R7 reasoned about).

### Review of the central concern

Pre-R8 stale-gap policy in `noteEGVReceived` applied uniformly to all sources:

```swift
if let prior = priorReceiptAt {
    let gap = receiptDate.timeIntervalSince(prior)
    if gap > Self.staleThreshold {
        log("rearm_skipped", "reason=stale_gap gap_s=\(Int(gap)) source=\(sourceTag)")
        return
    }
}
```

For BLE, that policy is well-grounded: a long-gap BLE EGV is usually the recovery edge of an outage, and predicting cadence on it before the next EGV proves the cycle is stable would generate confident-sounding ramp/miss buzzes around the wrong time.

For relayed sources in `.bleAndRelayedFallback` mode, the same policy means the *whole point* of fallback (provide cadence haptics when BLE is unavailable) is broken in exactly the scenario where users care most: after BLE has been quiet for a while. The first relayed reading just confirms; cadence prediction only restarts on the second relayed reading 5 minutes later. Users would feel like fallback "didn't do anything" for the first EGV after the outage.

ChatGPT's recommended fix: split the policy by source and add a freshness gate so late relayed payloads (HK batch sync, late WC catch-up) still cannot poison cadence prediction. Adopted as the R8 product decision.

### R8 product decision (authoritative)

**Stale-gap rearm policy (`gap > staleThreshold`):**

| Source | Reading freshness | Behavior |
|---|---|---|
| BLE | (any) | Confirm only. `rearm_skipped reason=stale_gap`. |
| Relayed (WC / HK) | `receiptDate − readingDate < relayedFreshnessForRearmAfterGap` (30 s) | Confirm + rearm. Logs informational `rearm_after_stale_gap reason=relayed_fresh`. |
| Relayed (WC / HK) | `receiptDate − readingDate >= relayedFreshnessForRearmAfterGap` | Confirm only. `rearm_skipped reason=stale_gap_relayed_not_fresh`. |

If on-device validation shows the 30 s gate is too tight (e.g. WC hop occasionally peaks at 35 s) or too loose (some users seeing cadence rearmed on stale HK syncs), tune `relayedFreshnessForRearmAfterGap` rather than restructuring the policy.

### R8 reviewer disposition

| # | Reviewer | Severity claimed | Disposition | Rationale |
|---|---|---|---|---|
| 1 | ChatGPT — `stale_gap` rule applies uniformly; first relayed reading after long BLE outage just confirms | Product call (close-to-bless) | **Adopted ChatGPT's recommended option.** Stale-gap check is split by source; new constant + two new telemetry events (one fall-through informational, one new `rearm_skipped reason=`). Trade-off and freshness-gate threshold (30 s) documented in the constant's doc comment and in the inline comment block at the call site. |
| 2 | ChatGPT — non-blocking #1: dedup logs could include both ages | Non-blocking | **Adopted (small enrichment).** `egv_ignored reason=duplicate` log line now carries `last_reading_age_s` in addition to `reading_age_s`. Inline comment near the dedup gate documents the cross-source monotonicity assumption (in steady state each new sensor reading has a strictly newer `glucoseTimestamp`; if a future source reorders deliveries the worst case is a real reading being silently dropped, and the per-source ages on the log line will let analysts spot it). |
| 3 | ChatGPT — non-blocking #2: `relayed_confirm` may confuse users; consider opt-out | Non-blocking | **No code change.** Already covered by R6 product decision #5. Bench-mark on-device validation; revisit before any user-facing rollout. |
| 4 | ChatGPT — non-blocking #3: source comments getting long again | Non-blocking | **Deferred.** Same pre-PR cleanup task already noted in R7 finding #7. |
| 5 | ChatGPT — non-blocking #4: pre-existing `R5c —` comment in `WatchState.swift` | Non-blocking | **Out of scope.** Same as R7 finding #8. |

### Per-finding implementation notes

**Finding 1 — source-split stale-gap policy.**

Added `relayedFreshnessForRearmAfterGap: TimeInterval = 30` to the tuning constants block. The doc comment spells out the rationale: 30 s comfortably covers healthy WC hop latency (typically < 5 s) without admitting old HK batch syncs.

Restructured the stale-gap check in `noteEGVReceived` (after the confirmation fire, before `rearm(after:)`):

```swift
if let prior = priorReceiptAt {
    let gap = receiptDate.timeIntervalSince(prior)
    if gap > Self.staleThreshold {
        // (inline policy comment block)
        if isBLE {
            log("rearm_skipped", "reason=stale_gap gap_s=\(Int(gap)) source=\(sourceTag)")
            return
        }
        let relayedLatency = receiptDate.timeIntervalSince(readingDate)
        if relayedLatency >= Self.relayedFreshnessForRearmAfterGap {
            log("rearm_skipped", "reason=stale_gap_relayed_not_fresh gap_s=\(Int(gap)) reading_age_s=\(Int(relayedLatency)) source=\(sourceTag)")
            return
        }
        log("rearm_after_stale_gap", "reason=relayed_fresh gap_s=\(Int(gap)) reading_age_s=\(Int(relayedLatency)) source=\(sourceTag)")
    }
}
rearm(after: receiptDate)
```

Both new log events follow the existing `module=haptic_beacon event=… <fields>` convention. `rearm_after_stale_gap` is informational-only (no behavioral effect — falls through to the standard `rearm(after:)`), but is a distinct event so analysts can size how often fallback recovers cadence and at what relayed-latency without conflating it with normal (no-stale-gap) rearms.

**Finding 2 — dedup log enrichment.**

```swift
if let last = lastAcceptedReadingDate, readingDate <= last {
    let readingAge = Int(receiptDate.timeIntervalSince(readingDate))
    let lastReadingAge = Int(receiptDate.timeIntervalSince(last))
    log(
        "egv_ignored",
        "reason=duplicate source=\(sourceTag) reading_age_s=\(readingAge) last_reading_age_s=\(lastReadingAge)"
    )
    return
}
```

The new field gives analysts the second leg of the dedup comparison without a separate query. Comment block immediately above the gate documents the cross-source monotonicity assumption and the silent-drop failure mode.

### R8 plan deviations (none)

All R8 changes implement plan v1.15 §"R8 — stale-gap-relayed recovery + dedup log enrichment" exactly.

### Files modified (R8)

- `Trio Watch App Extension/HapticBeacon.swift` only:
  - New constant `relayedFreshnessForRearmAfterGap` with doc comment.
  - `noteEGVReceived` stale-gap block restructured per the source-split policy; inline policy comment.
  - `egv_ignored reason=duplicate` log line gains `last_reading_age_s`; inline comment documents the cross-source monotonicity assumption.

No changes to `WatchState.swift`, `G7WatchSensorAdapter.swift`, or `ComplicationDebugView.swift`.

### Self-review checklist (per Trio AGENTS.md)

- [x] Re-read the modified file (`HapticBeacon.swift`) top to bottom after edits — all edits cohesive; constant doc / call-site comment / new telemetry events all reference the same policy.
- [x] No half-finished edits or stale TODOs in the changed surface. The new `rearm_after_stale_gap` event is informational only and the fall-through into `rearm(after:)` is the standard path; no new exit branch was introduced.
- [x] No project file edits or `sync_project_files.rb` invocations (AGENTS rule 6); no new files added.
- [x] No `xcodebuild` / `ci/local-build.sh` runs (AGENTS rule 10); static review + lint check only.
- [x] Lint check via `ReadLints` over `HapticBeacon.swift`: zero new warnings/errors.
- [x] Behavior contract preserved for all R6 / R7 done-criteria; new R8 behavior (relayed fallback rearms after long gap when relayed latency < 30 s) recorded as new R8 done-criteria along with explicit "stale relayed payload still confirm-only" verification.
- [x] Telemetry contract: every new code branch emits exactly one log line; the `rearm_after_stale_gap` informational event sits between the `haptic_fired type=relayed_confirm` line (already emitted by `fireRelayedConfirm()`) and the two `haptic_armed phase=ramp|miss` lines (emitted by `rearm(after:)`).

### R8 done-criteria (on-device verification)

(In addition to the criteria from Cuts 1–4 + R2–R7.)

- [ ] **Fallback recovers cadence on fresh relayed reading after long BLE outage:** in `.bleAndRelayedFallback` mode, after ≥ 10 minutes with no accepted EGV, a fresh WC / HK reading (relayed latency < 30 s) emits `haptic_fired type=relayed_confirm` immediately followed by `rearm_after_stale_gap reason=relayed_fresh gap_s=<n> reading_age_s=<m>` and then `haptic_armed phase=ramp` + `haptic_armed phase=miss`.
- [ ] **Stale relayed payload after long outage still confirm-only:** in `.bleAndRelayedFallback` mode, after ≥ 10 minutes with no accepted EGV, a stale relayed reading (relayed latency ≥ 30 s, e.g. an HK batch sync representing an older sensor reading) emits `haptic_fired type=relayed_confirm` followed by `rearm_skipped reason=stale_gap_relayed_not_fresh gap_s=<n> reading_age_s=<m>` — no ramp / miss arm.
- [ ] **BLE long-outage behavior preserved (R6 invariant):** after ≥ 10 minutes with no accepted EGV, a long-gap BLE EGV emits `haptic_fired type=success_1` (+ companions) followed by `rearm_skipped reason=stale_gap` — no `rearm_after_stale_gap` for BLE source.
- [ ] **Steady-state telemetry:** in normal cadence (no stale gap), neither `rearm_skipped reason=stale_gap_relayed_not_fresh` nor `rearm_after_stale_gap` should appear in Better Stack — both events are stale-gap-recovery-only.
- [ ] `egv_ignored reason=duplicate` log lines now carry both `reading_age_s` and `last_reading_age_s` fields.

> **Tester note (per ChatGPT's explicit recommended test case):** "In fallback mode after >10 minutes with no accepted EGV, send one fresh WC/HK reading and verify whether the desired behavior is confirm-only or confirm+rearm." With R8 the answer is **confirm + rearm** for fresh relayed readings (latency < 30 s) and **confirm only** for stale relayed readings. If the user prefers strict semantics across the board (i.e., fallback never rearms after long outage, matching pre-R8 behavior), this is a one-line revert (collapse the source-split back to a single `rearm_skipped reason=stale_gap` branch) — recorded here so the trade-off is visible.

---

## Changelog

### v11 (2026-05-11 23:08 CET)
- **R8 — stale-gap-relayed recovery + dedup log enrichment (review pass).** Third external review (ChatGPT round 4) on the post-R7 worktree. ChatGPT verdict was "close to bless" with one product-behavior call: pre-R8 stale-gap rule applied uniformly to all sources, so `.bleAndRelayedFallback` mode required *two* relayed readings ≥ 5 minutes apart before fallback restored cadence after a long BLE outage — defeating the purpose of fallback in the exact scenario users care about. Authoritative product decision: split stale-gap policy by source (BLE remains strict; relayed sources may rearm after long gap if relayed latency < 30 s; stale relayed payloads still confirm-only). Adopted ChatGPT non-blocking #1 (dedup log enrichment) since it lives in the same edit surface as the R7 dedup-gate reasoning. New constant `relayedFreshnessForRearmAfterGap = 30 s`; new telemetry events `rearm_after_stale_gap reason=relayed_fresh` (informational fall-through) and `rearm_skipped reason=stale_gap_relayed_not_fresh`. `egv_ignored reason=duplicate` now also carries `last_reading_age_s` for ordering-anomaly debugging; inline comment near the dedup gate documents the cross-source monotonicity assumption. New section **"R8 — stale-gap-relayed recovery + dedup log enrichment (review pass)"** documents the 5-row reviewer disposition, per-finding implementation, telemetry contract changes, and five new R8 done-criteria (including ChatGPT's explicit test case and the trade-off note for reverting to strict semantics if desired). Plan reference bumped to **v1.15**. Self-review across the single modified file (`HapticBeacon.swift`); no new lints; no other files touched.

### v10 (2026-05-11 23:00 CET)
- **R7 — warm-arm invariant tightening (review pass).** Second external review (Claude round 2 + ChatGPT round 3) on the post-R6 worktree. Reviewers disagreed on the central question (warm-arm seeding `lastAcceptedReadingDate`); verified ChatGPT's literal blocker scenario against `G7WatchSensorAdapter.swift:578–580` (same-`sequence` adapter dedup happens before `noteEGVReceived`, so two `noteEGVReceived` calls cannot share a `readingDate` from the live BLE path) and sided with Claude. Adopted ChatGPT's deeper invariant point (medium #1) about clean type separation: warm-arm no longer writes `lastBLEReceiptAt` because that slot is documented as a watch receipt time and warm-arm has only a sensor reading time available. Property doc comments tightened to make both invariants explicit. Added Claude's defensive-guard explanation comments in `fireSuccess` / `fireMiss`. Added trade-off comment on `setEnabled(false)` dedup-clearing (debug-feature acceptable; revisit if user-facing). New section **"R7 — warm-arm invariant tightening (review pass)"** documents the 9-row reviewer disposition, verification trace, behavioral consequences, and four new R7 done-criteria. Plan reference bumped to **v1.14**. Self-review across the single modified file (`HapticBeacon.swift`); no new lints; no other files touched.

### v9 (2026-05-11 22:55 CET)
- **R6 — multi-source safety + UX polish (review pass).** Consolidated Claude + ChatGPT external review of the post-R5 + Cut2/Cut3/Cut4 worktree (13-row finding table) plus five authoritative product decisions on multi-source policy. Fix highlights: dedup by `readingDate` in `noteEGVReceived` (closes ChatGPT blockers #1/#10); source-precedence gate via `lastBLEReceiptAt` + `bleFreshnessWindow=360 s` (closes ChatGPT blocker #2); BLE-only success triple, relayed sources fire single `relayed_confirm` `.click` (product decision #5); unique ramp labels (`ramp_click_1`/`_2`, `ramp_start_1`/`_2`, `ramp_notif_1`/`_2`/`_3`); sync first beat for success/miss (no lost confirmation); `cancelAllTimers` / `clearCurrentCycle` split; `attemptBLEWarmArm(trigger:)` reused by `setEnabled(true)` and `setSourceFilter(.ble)` narrowing; `SourceFilter.all` → `.bleAndRelayedFallback` with `"all"` raw-value migration; debug UI label "BLE + relayed"; WatchState hooks wrapped in `Task { @MainActor in … }` (Claude #1) with debounce-context comment at WC site (Claude #2); `play()` single state-read (Claude #3); source-comment cleanup (no Cut/review references). Plan reference bumped to **v1.13**. Self-review across four modified files; no new lints. See § "R6 — multi-source safety + UX polish" above for per-finding implementation notes and seven new R6 done-criteria for on-device verification.

### v8 (2026-05-11 22:30 CET)
- **Cut 4 — richer cadence haptics:** `rampLeadTime` 5 s; seven-beat ramp (`steps` array); triple `.success` via `successSubTimers` (`success_1`…`success_3`); double `.retry` via `missSubTimers` (`retry_1`, `retry_2`); `cancelAllTimers()` gains `phase=success_sub` / `phase=miss_sub` with `pending_count`. Plan reference bumped to **v1.12**. See § Cut 4 section above; canonical code `Trio Watch App Extension/HapticBeacon.swift`.

### v7 (2026-05-11 22:15 CET)
- **Cut 3 code deliverable** ahead of Cut 2 spike, per user direction. SourceFilter (`.ble` default / `.all` opt-in) + persisted state, two new `WatchState` hooks (`applyHKSnapshot` end, `saveComplicationSnapshot` after data-store save), `lastCycleSource` slot driving per-cycle `source=` telemetry across `armed`/`cancelled`/`fired`/`skipped`/`rearm_skipped` log lines, new `egv_ignored` and `setSourceFilter` events, second debug button (`Source: BLE only` / `Source: All`). Five plan deviations documented in this section: Cut 2 gate explicitly deferred; `cancelAllTimers()` owns `lastCycleSource` clearing; `setSourceFilter` cancellation is conditional; `source=` tag broadened beyond plan's `armed`/`fired`; new `egv_ignored` event added. Self-review checklist completed; SourceKit module-not-found warnings are pre-existing IDE noise. Spike validation for Cut 2 still pending.

### v6 (2026-05-11 22:09 CET)
- **Cut 2 code deliverable:** Dual-path `play(_:label:)` (`notifyUser` when extended session `.running`, else `WKInterfaceDevice`), telemetry fields per plan §4.1 / §5.2. Spike protocol §5.3–5.4 left as manual on-device validation; Cut 2 section in this log expanded accordingly. Plan bumped v1.9 → **v1.10** (not v2.0).

### v5 (2026-05-11 14:26 CET)
- **Cut 1 review round 5** (in-session red-team pass over the post-R4 surface). Three findings — one comment-cleanup followup miss in `G7WatchSensorAdapter.swift` (the two new haptic-beacon accessors still carried "Cut 2 spike" / "R2 fix, GPT #3" framing — R4's comment-cleanup pass only touched `HapticBeacon.swift`); one minor semantic gap (`setEnabled(false)` left `lastReceiptAt` set, causing a correct-but-confusing `rearm_skipped reason=stale_gap` log on the first live EGV after a long disable period); one telemetry hole (three silent `guard` returns in the `setEnabled(true)` warm-arm path produced no log, so analysts couldn't distinguish "no warm-arm because of X" from "warm-arm logic never ran"). All three fixed in the same turn. Five findings explicitly verified safe with rationale (identity-token guards, `rampSubTimers` race, EOS interaction, retain cycles, source-filter type alignment). One observation deferred (per-`.active`-transition `start` log noise — very low priority). Three new R5-verifiable done criteria added (disable-clears-anchor; `warm_arm_skipped reason=adapter_stopped`; `warm_arm_skipped reason=no_anchor`).

### v4 (2026-05-11 13:30 CET)
- **Cut 1 review round 4.** Consolidated Claude + ChatGPT review-round-4 feedback into a 6-row evaluated table (the two reviewers diverged: Claude said "ship", ChatGPT escalated a blocker — ChatGPT was correct). Five fixes implemented (UUID identity tokens for `rampTimer` / `missTimer` / `successTimer`; per-deadline past-skip inside `rearm()` with new `rearm_skipped reason=deadline_passed phase=…` log shape; `setEnabled` gate loosened to `expectedCadence + missGracePeriod` (320 s) so 297–319 s anchors get a partial warm-arm; defensive cancel + remove at top of `fireRamp()`; plan §3.1 Properties block rewritten + identity-token method docs + R4 changelog). Two new R4-verifiable done criteria added (cancel-and-reschedule race resilience; partial warm-arm in 297–319 s window).

### v3 (2026-05-11 12:50 CET)
- **Cut 1 review round 3.** Consolidated Claude + ChatGPT review-round-3 feedback (post-R2) into a 7-row evaluated table. R2 fixed the original headline issues but introduced two new behavior bugs (Claude's guard-race in fire wrappers; ChatGPT's `rampSubTimers` stale-array) that wouldn't have been visible without R2's surface area. Seven fixes implemented (guard-before-act in 3 wrappers; UUID-keyed `rampSubTimers` + remove-on-fire; tighter warm-arm gate from 600 s → 300 s with `warm_arm_skipped` log; honest `bleLastEGVDate` rationale; plan §3.1 stale-doc fixes; plan §4.5 split miss/ramp methodology; `pending_count` field on `haptic_cancelled phase=ramp_sub`). Two new R3-verifiable done criteria added (race-resilient ramp; warm-arm rejects expired cycles).

### v2 (2026-05-11 12:25 CET)
- **Cut 1 review round 2.** Consolidated Claude + ChatGPT external-review feedback into a 10-row evaluated table with per-finding analysis. Six fixes implemented (stale guard relocation, `successTimer` tracking, null-on-fire + `haptic_cancelled` telemetry, `isIntentionallyStopped` accessor, plan §4 telemetry rebless, warm-arm on enable). Two no-ops with rationale (`source.rawValue` verified safe, mixed working tree handled by code review doc scope filter). Two doc-only items (BLE-only miss tester note, telemetry methodology for Cut 2 spike). Three new Cut 1 + R2 done criteria added for on-device verification.

### v1 (2026-05-11 11:25 CET)
- Initial entry. Cut 1 implemented in worktree, four files touched (one new, three modified), zero new lint diagnostics, two pre-existing SourceKit false-positives unchanged. Three minor stylistic deviations from the plan documented (timer-handler `self` capture, gate consolidation, toast strings). Cut 1 done criteria awaiting on-device verification by user.
