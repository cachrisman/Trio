# Build 210 — Implementation log

Tracks C-210-N implementation against the
[locked plan](watch-g7-direct-ble-observer-build210-impl-plan.md).

---

## C-210-1 — Canonical mg/dL + unit-aware complication display  **(P0)** — CODE DONE, build-unverified

**Date:** 2026-06-16

### Design deviation from the plan (important)
The locked plan said "store canonical `glucoseMgDl: Int` in the snapshot and **format in the
widget** by unit preference." **That mechanism is not viable** and was changed. Evidence:
- `WatchGlucoseColorComputer` reads its unit setting from **`UserDefaults.standard`**, not the App
  Group (`WatchGlucoseColorComputer.swift:49`, and the class doc at `:15-16`: *"Settings live in the
  watch app's UserDefaults.standard (not App Group)… the complication widget renders the baked
  snapshot hex."*). The widget extension is a **separate process** with its own
  `UserDefaults.standard`, so it cannot read `isMmolL`. This is exactly why color hex is already
  **baked into the snapshot on the watch-app side** today.
- Formatting in the widget would have required also plumbing the unit preference into the App Group
  and compiling the converter into the widget target — a larger, riskier change for a P0.

**Actual approach (consistent with the existing color-hex baking):** format the unit-correct display
string **on the watch-app side** (where the producers run and the unit setting is available) and bake
it into the snapshot, mirroring how `glucoseColor` is already baked. The snapshot model is unchanged
(no `Codable` migration). The canonical mg/dL is passed to the live-UI apply functions as a parameter
so `currentGlucoseMgDl` stays canonical without parsing the display string.

### Changes
1. **`WatchGlucoseColorComputer.swift`** — added two pure helpers next to the existing
   `displayValue(forMgDl:)`:
   - `displayString(forMgDl:)` → mg/dL `"100"`, mmol `"5.6"` (one decimal; reuses `displayValue`).
   - `displayDeltaString(previousMgDl:currentMgDl:)` → mg/dL `"+5"`, mmol `"+0.5"` (converts **each**
     operand to scale-1 mmol then subtracts — matches the phone's per-reading `asMmolL` so watch and
     phone can't diverge on a half-boundary).
   - *(Drafted via `ollama-task implement`; the draft passed `&let` to `NSDecimalRound`'s `inout` —
     fixed to `var` before applying. Parity logic was correct. Feedback logged.)*
2. **`G7WatchSensorAdapter.swift`** (BLE producer) — delta now `displayDeltaString(...)`; snapshot
   glucose now `displayString(forMgDl: tail.glucoseMgDl)`; passes `glucoseMgDl:` to the apply fn.
3. **`WatchState.swift`** (HK producer) — delta string now `displayDeltaString(...)` (keeps the
   mg/dL `deltaInt` for the trend bucket); snapshot glucose now `displayString(forMgDl: hkMgDl)`;
   the canonical-telemetry log still logs mg/dL. `applyG7DirectBleSnapshot`/`applyHKSnapshot` gained a
   `glucoseMgDl: Int` param and set `currentGlucoseMgDl` from it instead of `Int(snapshot.glucose)`
   (which would return nil for `"5.6"`). The WC path was already canonical (reads
   `WatchMessageKeys.currentGlucoseMgDl` off the wire — unchanged).
4. **`Trio Watch App Tests/Unit Tests.swift`** — added parity tests for both helpers (mg/dL and
   mmol, positive/negative/zero delta) with hand-verified expected values.

### Findings swept in
- **#1** (the P0): fixed — both producers bake the unit-correct number.
- **#2b** (delta from per-process baseline): the delta is now unit-correct, but the BLE baseline is
  still the in-memory `lastSavedGlucoseValue`. **The baseline-SOURCE change (seed from
  `WatchGlucoseHistoryStore`) is deferred to C-210-2** where the arbitration/history work lives — it's
  a separate concern from units. Cold-start still yields `"--"` for the first BLE delta.
- **#1b** (widget color fallback uses mg/dL thresholds on a mmol string): **not touched.** Producers
  always bake `glucoseColor`, so the widget fallback is essentially dead code; fixing it cleanly means
  having the widget never recompute color (it can't know units). Left as a documented latent edge.

### Verification status — NOT yet built
- Parity logic reviewed by hand; unit tests authored (run in the watch test target / CI).
- **NOT compiled or built in this session.** Per the plan, this P0 **must be verified on an
  mmol/L-configured device** (invisible on mg/dL test devices). Next: build via the patch flow and
  confirm a BLE-fed mmol face shows `5.6`/`+0.5`, not `100`/`+10`.

---

## C-210-2 — Completeness-aware arbitration + #2b delta baseline  **(P1)** — CODE DONE (g7_sequence deferred), build-unverified

**Date:** 2026-06-16

### Done
1. **Completeness-aware arbitration** (`TrioComplicationDataStore.shouldUpdate`,
   `Trio Watch Shared/TrioComplicationDataStore.swift:642-696`). Replaced the permissive
   `sameCore`+fallthrough (which let a barer/lower-priority payload overwrite a complete one when the
   derived trend differed) with: **completeness → source priority → content change**. New helper
   `isComplete(_:)` (glucose ≠ "--", trend non-empty, delta ≠ "--"). The pre-existing sequence guard
   is kept as a fast-path. All documented test-case rows still hold; added two rows for the new
   completeness behavior. Verified against an Ollama `review` pass — its 5 "bugs" were all false
   positives that ignored the documented **±1s = same-reading** invariant (logged as false-positive).
2. **#2b — BLE delta from cross-source history** (`G7WatchSensorAdapter` delta block +
   `WatchGlucoseHistoryStore.mostRecentMgDl(before:)`). When the in-memory `lastSavedGlucoseValue` is
   nil (cold start / sensor swap), the delta now seeds from the history store's immediate predecessor
   instead of emitting `"--"`. This also makes a cold-start BLE reading **complete**, so the new
   arbitration no longer prefers a WC reading over it at startup.
3. **Tests** — `shouldUpdate` anti-clobber, priority, and recency cases added to the watch test target.

### #2a — send g7_sequence from the phone — **DONE** (was briefly deferred; Charlie chose to pursue it)
The phone never sent the G7 sequence (`g7Sequence` was vestigial — referenced only in the model's
`Equatable`/`hash`), and `GlucoseStored` has no sequence field. But the live `G7CGMManager` **does**
expose it: `latestReading: G7GlucoseMessage?` (`.sequence: UInt16`) and `latestReadingTimestamp`.
The `cgmManager as? G7CGMManager` cast is already an established pattern (`PluginSource.swift:228`),
and the app target links `G7SensorKit` (`PluginManager`).

Implemented in `AppleWatchManager.swift`:
- `import G7SensorKit` + `@Injected() private var fetchGlucoseManager` (no DI cycle — `FetchGlucoseManager`
  doesn't depend on the watch manager).
- In the watch-state builder: stamp `watchState.g7Sequence = Int(g7.latestReading.sequence)` only when
  the active CGM is a direct `G7CGMManager`, the reading isn't manual, and the G7's
  `latestReadingTimestamp` is within **90 s** of `latestGlucose.date` (≪ the 300 s cadence, so it
  confirms *same reading*). Non-G7 / Share / Libre → nil (guard simply doesn't engage, as before).
- Added `g7Sequence` to **both** payloads: the main dict (`watchStateToDictionary` → the
  `processRawDataForWatchState` path) and the **complication allowlist** (→ the
  `transferCurrentComplicationUserInfo` path). The watch already reads it in all three WC snapshot
  builders (`WatchState.swift:1410,2084,2310`) and `intForWatchMessageKey` handles the NSNumber bridge.

**Sequence-space validity:** the phone's `G7CGMManager` and the watch's direct BLE observe the **same
physical G7 sensor**, so the EGV sequence numbers are identical across the two channels — exactly what
the watch's sequence guard needs to dedup the BLE/WC race for one reading.

Reviewed via an Ollama `review` pass — findings were false positives (`Int(UInt16)` is non-failable;
the "correlation bug" conflated the G7 message's own sequence/timestamp). Logged as false-positive.

### Verification status — NOT yet built
Same as C-210-1: parity/logic reviewed, unit tests authored, **not compiled/built**. The arbitration
is safety-critical display logic; confirm on-device that BLE-vs-WC races keep the complete reading.

---

## C-210-3 — Capture success rate on main face — DONE (commit 8d849bcbe)
`GlucoseTrendView` under-bubble status line now shows `captures / eligible-slots` (e.g. `67 / 248`)
instead of `egvs/connects`, reusing `G7WatchSensorAdapter.dailySlotStats()` (the analytical
denominator the debug panel already uses). Connects/readings can read healthy during a dormancy;
the captures/slots ratio surfaces missed slots.

## C-210-9 — Launch reload reconciliation + C-210-10 — HK same-epoch correction — DONE (commit 130fcbfe6)
- **C-210-9 (#3 narrow):** `TrioComplicationDataStore.reconcileUnservicedReloadOnLaunch()` compares the
  persisted requested vs widget-observed reload generations at `applicationDidBecomeActive`
  (launch+resume) and re-requests once (rate-limited) — recovers an unserviced reload the in-memory
  grace timer missed across suspension. (The rest of #3 was overstated; not done.)
- **C-210-10 (#6):** HK observer now skips only a *true* duplicate (same epoch AND same value); a
  same-epoch correction is processed instead of dropped. Idempotency for the common re-fire preserved.

## C-210-4 / 5 / 8 — Direct-BLE stall detection / indicator / notification / instrumentation — DONE (commit 37d4882af)
Cross-source freshness on the ~300s expected-window tick (`evaluateDirectBleStall`): direct G7 BLE
EGV stale (>12 min soft / >30 min hard) while the phone path (`lastPhoneEGVDate`, new signal) is fresh
=> on phone relay.
- **C-210-4:** `DirectBleStallTier` (none/stalled/unavailable) on the watch face status line;
  `direct_ble_stall_detected` telemetry each tick.
- **C-210-8:** fault classification via `sessionConnectAt` recency → Dexcom-side (no window; observe
  only) vs Trio-side (window, no EGV; self-healable), logged.
- **C-210-5:** inferred notification ("reopen the Dexcom Watch app") with **hard alarm-fatigue guards**
  — only a sustained HARD Dexcom-side stall, once per episode, reset on recovery. Added notification
  auth request. Both-stale/system-wide gaps and warmup/no-sensor are NOT flagged.

## C-210-6 / C-210-7 — shared-fork items — **DEFERRED to an attended session** (decision)
**Not implemented.** Rationale: these modify the **phone's BLE reconnect path** in the `G7SensorKit`
fork (`G7BluetoothManager.connectionEventDidOccur` re-kick; connect-gate throttle), which is the
highest-risk change in build 210 — getting the re-kick wrong can tear down a live connection or feed
the A5 reconnect storm. They also require a **fork push + patch repin** (Charlie's manual workflow) to
ship, and warrant human review before reaching even a TestFlight soak. The completeness arbitration
(C-210-2) and stall detection (C-210-4/8) already address the *visibility* of these stalls; the
*recovery* levers (6/7) are best done attended. Design is fully specified in the build-209 plan **A7**
(re-kick) and **A5** (connect-gate). Ready to implement attended.

## Build 210 = the watch-app-only subset (C-210-1,2,3,4,5,8,9,10)
Build/deploy uses `./ci/local-build.sh --build-current` (builds the committed `feature/watch-g7`
state directly, skipping the patch-stack workflow). The shared-fork items being deferred, no fork
push / patch repin is needed for this build.

---

## ⚠️ CORRECTION — #2a (g7_sequence send) was already implemented by patch 13; my commit DROPPED

When regenerating patch 09 with my commits, the patch-test failed at **patch 13
(`phone-ble-observer-telemetry`)** — a conflict in `AppleWatchManager.swift`. Investigation revealed
**patch 13 already fully implements #2a**, and better:
- `import G7SensorKit`, injects `fetchGlucoseManager` (+ `deviceManager` fallback).
- Extracts `seqCtx = (Int(g7.latestReading.sequence), g7.latestReadingTimestamp)`.
- Sets `watchState.g7Sequence = ctx.sequence` when `abs(ctx.timestamp − latestGlucose.date) ≤ 120s`
  (nearly identical to my 90s correlation), plus sensor-name caching + EOS clearing.
- Serializes `dict[WatchMessageKeys.g7Sequence]` and adds it to the complication allowlist.

**So my #2a commit `89ac1de25` was 100% redundant** and is the sole cause of the conflict. It was
**dropped** from the patch/build (only my 5 watch commits were folded into patch 09).

**Root-cause of my earlier wrong "g7Sequence is vestigial" conclusion:** I reasoned about the
`feature/watch-g7` branch, where g7Sequence is indeed only in `Equatable`. But the **send lives in
patch 13**, which exists only in the *built* `dev`+patches state — exactly the AGENTS.md lesson "a
build is `dev` + the patch stack, never a feature branch directly." The watch *reads* g7_sequence
(patch 09) and patch 13 *sends* it, so the C-210-2 sequence guard works in the build **without** my
#2a. C-210-2's completeness arbitration (commit `16839948a`) is independent and fully in patch 09.

The redundant commit `89ac1de25` remains on `feature/watch-g7` (harmless, not in any patch). No
action needed; if anything, delete it from the branch later.

## Build 210 integration & deploy
- Patch `09-watch-g7` regenerated via `mid-stack-update.sh --patch 09 --cherry-pick` with the **5
  watch commits** (`ca156912c,16839948a,8d849bcbe,130fcbfe6,37d4882af`). Files in patch: 29.
  Stack validation **PASSED**, drift **CLEAN**; new base files (`WatchNotificationHandler.swift`,
  `Unit Tests.swift`) correctly pulled into the patch.
- Patch file left **uncommitted** on `dev` (per AGENTS.md patch lifecycle — commit only after build
  + deploy + BetterStack verification, and only when Charlie asks).
- Build + deploy: `ci/local-build.sh --base-branch dev --no-sync-upstream` (full TestFlight deploy)
  running from `Trio-dev`. Build 210 = C-210-1, 2 (arbitration + #2b; #2a via patch 13), 3, 4, 5, 8,
  9, 10. Shared-fork items C-210-6/7 deferred to attended.


---

## C-210-6 / C-210-7 — shared-fork stall recovery (review-driven; in progress)

**Status (2026-06-17):** code lives on the `G7SensorKit` fork branch `feat/c210-6-7-stall-recovery`
— **NOT pushed, NOT patch-02-repinned, NOT built.** Three commits + three review rounds so far;
round-3 fixes pending one decision (M-b). Per Charlie: implement both, then loop review→fix until the
reviewers converge with no Blocker/High — this is a critical, must-be-rock-solid piece on the shared
iPhone+watch BLE path (iPhone is the north-star).

**What they do**
- **C-210-7 (connect-gate, fail-safe):** throttle reconnect storms (208/209 soak saw up to 16
  `did_connect` in a 5-min window). Slide a 5-min window, gate beyond 8, schedule a drain-time retry.
- **C-210-6 (bound-but-stalled re-kick):** when bound to a `.connected`-but-EGV-silent zombie, cancel
  it on a connection event so the disconnect→`scanAfterDelay`→rescan path re-attaches. Hard-gated so
  it never cancels a healthy / fresh / `.connecting` peripheral.

**Commits on the fork branch**

| sha | what |
|---|---|
| `f21235b` | initial implementation (re-kick + connect-gate) |
| `f3062c4` | round-1 review fixes |
| `9388141` | round-2 refactor: binding-scoped `BindingBLEState` |

Reviews run via the `codex-task review` + `cursor-task review` cloud CLIs (`--base c210-review-base`,
a branch at fork base `cd879d5`); raw findings saved under `.claude/ollama-notes/*-{codex,cursor}-review.md`.

### Round 1 (vs `f21235b`) — converged codex + cursor
- **Blocker** (gate deadlock / cursor M1): a gated connect left a bound-but-disconnected peripheral
  idle (bound scan path won't scan; nothing re-attempts) with no retry.
- **B1** (Blocker/High): stale recovery state survived a sensor swap → re-kicked the NEW sensor.
- **H1** (High): re-kick cancelled a fresh `.connecting`/recovering attach.
- **H2** (High): cancel bypassed the connect-gate → churn.
- **M2:** `receivedGlucoseSinceConnect` not reset on `forgetPeripheral`.
- **E** (`.connecting` retry drop): downgraded Medium→Low (pre-existing no-connect-timeout behavior,
  not a regression) — **accepted, not fixed**. F/G/H-cosmetic = optional.
→ **Fixed in `f3062c4`:** `scheduleGatedConnectRetry`; `forgetPeripheral` resets state; re-kick
  requires `.connected` + connection-age != 0 zombie + 5-min debounce; `currentConnectionStartedAt`
  tracked in didConnect/didDisconnect/didFailToConnect.

### Round 2 (vs `f3062c4`) — converged
All round-1 fixes confirmed. New finding theme = **state lifecycle** (not algorithm):
- **A/H:** `currentConnectionStartedAt` must be set/cleared ACTIVE-binding-only.
- **B:** `gatedRetryScheduled` survived a swap (bare flag reset insufficient → needs a binding token).
- **C:** `managedPeripherals` not cleared on reset.
- **D:** seed `currentConnectionStartedAt` when adopting an already-`.connected` binding (CB restore).
- **F:** retry should resolve the peripheral by identifier, not a captured object.
- **Meta (both):** 5 separate fields × ~6 transition sites = whack-a-mole → **consensus: consolidate
  into one binding-scoped struct.**
→ **Fixed in `9388141` (refactor):** single `BindingBLEState` reset atomically in `forgetPeripheral`
  + `bindingGeneration` token; active-binding-only set/clear; seed-on-adopt; identifier-resolved
  generation-checked retry; `noteGlucoseReceived()` consolidates the glucose-received write.
  **Closes A/B/C/D/F/H structurally.**

### Round 3 (vs `cd879d5`, cumulative; commit `9388141`) — converged
**A/B/C/D/F/H: CLOSED** (both reviewers, with file:line). **No Blocker.** North-star check passed
(no connect timeout; gate cap 8/5min !>> ~1/5min cadence; 12-min stall gate means a healthy iPhone
never qualifies).
- **High (both): the `!receivedGlucoseSinceConnect` conjunct** (`shouldRekickBoundStalled`) blocks
  re-kick of a *post-EGV* zombie (a connection that delivered one EGV then went silent 12+ min while
  staying `.connected`). Pre-dates the refactor (round-1 H1 fix). **Fix: drop the conjunct** — the
  conn-age and global-stall guards already define the zombie; this *widens* coverage. Subsumes codex's
  narrower "reset the flag on adopt."
- **Medium-a (cursor M#4 + codex Med, + cursor High#2): `.makeActive` rebind to a new UUID** swaps the
  peripheral on the existing manager → no `didSet` → no generation bump AND a stale
  `activePeripheralIdentifier`; also lets discovery-stamped `lastGlucoseAt` carry into the new binding.
  **Fix: on `.makeActive` identity change, reset `bindingState` + bump generation + set the identifier.**
- **Medium-b (codex): cold-restore into an already-stalled binding can't re-kick** (`lastGlucoseAt` is
  in-memory, nil after relaunch). **DECISION PENDING.** Recommended: **ACCEPT with rationale** — the
  naive fix (treat nil `lastGlucoseAt` as stalled) would re-kick during the ~27-min warmup (no EGVs,
  connection up >6 min, nil clock); the fork has no warmup signal (that lives in the watch adapter), so
  requiring an in-process EGV baseline before re-kick is a *deliberate safety property*. Fully closing
  it needs fork-level last-EGV persistence (heavier, its own risk). Cold-restore-into-stalled is
  covered by the watch adapter's watchdog / the first EGV.
- **Medium-c (cursor M#3): `managedPeripherals.removeAll()`** could drop a late `didDisconnect` —
  confirmed NOT a non-swap regression (`forgetPeripheral` only called from `scanForNewSensor`); accept
  + scope comment.
- **Low #5:** `receivedGlucoseSinceConnect` left outside the struct — no runtime gap (connection-scoped
  vs binding-scoped, reset together); fix the comment overclaim only.
- **Verified safe (both):** `noteGlucoseReceived` `managerQueue` precondition; struct mutation across
  the `asyncAfter` boundary.

**Round-3 fix plan (NOT yet applied):** drop `!receivedGlucoseSinceConnect`; `.makeActive`
binding-change reset + identifier (closes M-a + High#2); comment fixes (Low#5, M-c); **M-b accept
with documented rationale** (pending Charlie's decision: accept vs fork-persistence). Then round 4
review. Convergence bar: no Blocker/High before fork push → patch-02 repin → soak.


### Round 3 — fixes APPLIED (commit `5301edf`, 2026-06-17)
- **High:** dropped the never-delivered-EGV conjunct from `shouldRekickBoundStalled` — re-kick now
  fires on any `.connected` zombie silent past the stall threshold and connected past the zombie
  threshold, regardless of an earlier EGV on the connection.
- **M-a (+ cursor High#2 + M#4):** `.makeActive` now resets `bindingState` + bumps `bindingGeneration`
  on a re-bind to a different peripheral identifier, and sets `lockedPeripheralIdentifier` explicitly
  (the existing-manager `.peripheral` swap doesn't fire the didSet).
- **M-b:** ACCEPTED (Charlie) — documented warmup-safety rationale in `shouldRekickBoundStalled`.
- **M-c / Low#5:** comment/scope fixes only.
Round 4 review running next; convergence bar unchanged (no Blocker/High before push → repin → soak).


### Round 4 — converged (no Blocker/High); one fix applied (commit pending in branch)
Both reviewers: no Blocker, no High; round-3 fixes ONE-FOUR all CLOSED; A-H closed.
- **codex Medium (re-kick object mismatch):** FIXED — `rekickBoundStalledPeripheral` adopts the
  connection-event peripheral as the active object before cancelling, so a fresh same-UUID CBPeripheral
  can't cause `didDisconnect` to drop the active map entry. (cursor missed this; codex's didDisconnect
  object-identity trace was correct — verified.)
- **Finding E (connect-gate during unbound discovery, no drain retry):** ACCEPTED + documented
  (discovery-scoped pairing latency only); soak follow-up.
- Other residuals (M-b, M-c, Low-5, adopt-seed Date(), weak-self) remain accepted/documented.
Round 5 review running to confirm the round-4 fix closes clean.


### Round 5 — CONVERGED CLEAN (2026-06-17)
Both reviewers (codex + cursor): **no Blocker, no High, no Medium.** Round-4 fix CLOSED; A-H and all
prior-round fixes CLOSED; re-kick gates intact; `!==` identity check confirmed correct; E / M-b / M-c
remain accepted + documented (Low / soak follow-ups). **This is the convergence point** — 5 review
rounds, 2 independent reviewers, on the shared iPhone+watch BLE path.

**Branch state:** `feat/c210-6-7-stall-recovery` in the G7SensorKit fork, commits f21235b → f3062c4 →
9388141 → 5301edf → 8a9183c. **NOT pushed, NOT patch-02-repinned, NOT built.**

**Next steps (gated on Charlie):** fork push to `cachrisman/G7SensorKit` main → repin the submodule SHA
in `patches/02-g7-reading-time-with-seconds.patch` → `patch-test.sh` → build (dev + patches) → soak
with `connection_event_rekick`, `connect_gated`, `connect_gate_retry`, `did_connect` grouped by
`platform`. Then this is build 211 (or a 210 respin). Also relocate the fork dev branch out of the
in-product-worktree submodule checkout (Charlie noted).


### Relocate (2026-06-17) — fork dev moved out of the product-worktree submodule
The `feat/c210-6-7-stall-recovery` branch + 5 commits now live in a standalone fork clone at
`~/Code/personal/health/diabetes/G7SensorKit-fork` (sibling to Trio / Trio-dev), `origin` →
`github.com/cachrisman/G7SensorKit`, branch tip `8a9183c`. The five review notes moved to that
clone's `.claude/ollama-notes/`. The in-product submodule `Trio/G7SensorKit` was returned to its
pinned commit `cd879d5` (working tree clean; the branch still exists in that submodule store as a
backup until the push). Charlie drives the rest: push the branch from `G7SensorKit-fork` →
merge/pin on the fork → repin the SHA in `patches/02-g7-reading-time-with-seconds.patch` →
`patch-test.sh` → build (dev + patches) → soak.


### C-210-6/7 landed in the patch stack (2026-06-17)
Fork pushed: `e56736b36` on `cachrisman/G7SensorKit` origin/main (PR #2 = the C-210-6/7 branch; PR #3 =
a `LoopKit/main` upstream sync merged alongside). `patches/02-g7-reading-time-with-seconds.patch` (dev
stack) repinned `4d0780db -> e56736b36` (index line updated; base matches dev's submodule pin).
Verified: SHA on origin/main, contains the work (BindingBLEState, rekickBoundStalled), cd879d5 (C-209)
is an ancestor (no regression). **patch-test.sh PASSED.** Remaining: build (dev + patches) + soak,
watching connection_event_rekick / connect_gated / connect_gate_retry / did_connect by platform.
Note: the dev patch carries an upstream sync too (PR #3), so soak should also watch for any
upstream-introduced BLE behavior. (The feature-worktree copy Trio/patches/02 still pins old cd879d5 —
stale, unused by the dev build.)
