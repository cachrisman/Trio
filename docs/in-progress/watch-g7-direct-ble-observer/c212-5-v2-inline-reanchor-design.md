# C-212-5 v2 — Inline Extended-Session Re-anchor: Design for Review

**Status:** DESIGN ONLY — not implemented. For cursor-task + multiple external reviews to converge before any code is written.
**Supersedes:** C-212-5 v1 (shipped in build 212, commit `dfc6c9f2d`), which the build-212 soak showed is broken (see §1).
**Author context:** v1 was shipped on static review alone and never verified on-device. This doc's entire purpose is to *not repeat that* — the design includes its own falsification test (the A/B) and the success criteria are read off telemetry, not asserted.

---

## 1. What happened with v1 (the evidence we're designing against)

v1: when the app is foreground-`.active` and the running extended session is older than 45 min (of its ~60-min budget), invalidate it and start a fresh one. To avoid watchOS's overlapping-session rejection, the replacement was started **sequentially** — from the `didInvalidate` callback, not inline.

Build-212 soak (2026-06-21, 13:17–15:56 UTC, DXCM2Y), from BetterStack:

- Two re-anchors fired: **14:02:51** (session age 2724 s) and **15:00:55** (age 2755 s). Trigger logic worked.
- **Both** hit the 15 s watchdog (`ext_session_reanchor_timeout` at 14:03:59 and 15:01:30) → `didInvalidate` did **not** arrive in time.
- **Neither** produced a fresh `ext_session_started`. The next session starts were the next *foreground opens* (14:15:00, 15:22:50) — i.e. the natural cadence, not the re-anchor.
- **All 3 EGV misses (3005, 3007, 3019) fell in the post-re-anchor windows; the 44-min stretch with no re-anchor (3008–3015) was 100% clean.**

**Conclusion:** v1's sequential restart depends on `didInvalidate` firing promptly *and* the scene still being `.active` when it does. In this workload both fail: the OS delivers `didInvalidate` >15 s late, and by then the user has glanced-and-left (scene `.inactive`), so the replacement is blocked. Net: v1 ends a session ~15 min early with no replacement — strictly worse than doing nothing.

## 2. The four constraints any fix must beat

1. **No overlap.** watchOS rejects a second `WKExtendedRuntimeSession` while one is live (`sessionInProgress`). To refresh you must end the old before starting the new → an unavoidable zero-session instant.
2. **Start-only-when-active.** A session can only be *started* while foreground-`.active`.
3. **`didInvalidate` is slow/unreliable.** Measured >15 s, sometimes absent. Cannot be on the happy path.
4. **Active windows are brief.** Glances. The thing that makes sessions short is the thing that starves the swap of time.

v1 lost to (3)+(4). This design attacks (3) by removing the callback dependency (inline start) and attacks (4) by only acting during a *sustained* active window.

## 3. Proposed design — inline re-anchor

One change vs v1: **do the swap inline.** When the app is foreground-`.active` and the running session is ≥ 45 min old, `invalidate()` the old session and **immediately** `start()` the replacement in the same runloop turn (or after a small delay — see §4). No dependency on the slow/unreliable `didInvalidate` callback that killed v1. The two calls are synchronous and back-to-back, so the zero-session gap is sub-millisecond (no-delay arm), and the whole thing happens while we *know* we're active.

This is, deliberately, a return to the **inline** approach that cursor-review talked v1 out of in round 1. The review's objection (overlap rejection) was *theoretical*; v1's actual flaw (callback dependency) was *fatal in production*. §4 is the experiment to find out whether the review's objection was even real.

**No sustained-active gate** (dropped after round-2 review). v1's swap took >15 s, so a glance could leave it half-done — a gate made sense there. The inline swap completes in sub-millisecond while active; `start()` only needs to be *called* while active, which it is. So the "burn a session during a glance" window is already closed by the inline design — a gate would add complexity and *reduce* how often re-anchor can fire, for no benefit. The one residual unknown the gate would have covered — *does a session started via `start()`-while-active still come up if the app backgrounds milliseconds later, before `didStart`?* — we **measure** rather than gate against (log `scene_phase` at start time; §8.10). Add a minimal "stay active ~1 s" only if the data shows failures clustering there.

### Illustrative pseudocode (Swift-ish; real impl is on `G7WatchSensorAdapter`)

```
renewSessionIfNeeded():                      // called on each foreground-.active entry
    guard scene == .active else { return }
    if let current = extendedSession, current.state == .running:
        let age = trueSessionAge()    // from persisted didStart wall-clock, NOT callback time (§8.7)
        guard age >= reanchorAge /*45m*/ else { log reanchor_skip(not_near_expiry); return }
        guard sessionPendingDidStart == nil else { log reanchor_skip(pending_start); return }

        attemptCounter += 1                                  // persisted in UserDefaults
        let delayMs = [0, 100, 300][attemptCounter % 3]      // A/B/C, §4
        let sid = UUID()                                     // stable local id for telemetry (§5)
        log reanchor_attempt(delayMs, sid, age_s: age, scene, old_state_before: current.state)

        invalidatingSessionIDs.insert(current)
        current.invalidate()
        let oldStateAfter = current.state
        extendedSession = nil
        // do NOT flip ext_session_active=false here; emit reanchor_in_swap and keep the
        // continuity baseline clean until the replacement definitively fails (§5, cont.)
        log reanchor_invalidated(delayMs, sid, old_state_after: oldStateAfter)

        let issueStart = {
            guard scene == .active else { log reanchor_abandoned(reason: left_active, delayMs, sid); return }  // B/C re-check
            let s = WKExtendedRuntimeSession(); s.delegate = self
            pendingReanchorSession = s                        // attribute by object identity (=== ), NOT userTag (doesn't exist)
            sessionPendingDidStart = s
            s.start()
            log reanchor_start_issued(delayMs, sid, scene_at_start: scene)
            startPendingWatchdog(15s)                         // backstop: IPC can black-hole the request
        }
        delayMs == 0 ? issueStart() : dispatchOnMain(after: delayMs, issueStart)
    else:
        ...normal "start when none exists" path (unchanged)...

// delegate:
didStart(session):
    if session === pendingReanchorSession:
        persistSessionStart(now)                             // §8.7 true-age clock
        if didRetry(sid) { log reanchor_retry_succeeded(sid) } else { log reanchor_replacement_started(sid) }
        armAConsecFailures = 0                               // any success resets the breaker
    ...adopt as extendedSession...

didInvalidate(session, reason):
    if session === pendingReanchorSession AND reason == .sessionInProgress:
        if !didRetry(sid):
            markRetried(sid)
            log reanchor_replacement_rejected(sid)           // first attempt rejected (raw per-arm signal)
            dispatchOnMain(after: 200ms) {                   // §8.8 single same-visit retry
                guard scene == .active else { log reanchor_abandoned(retry, left_active, sid); recordArmFailure(sid); return }
                let s2 = WKExtendedRuntimeSession(); s2.delegate = self
                pendingReanchorSession = s2; sessionPendingDidStart = s2
                s2.start(); log reanchor_retry(sid)
            }
        else:
            log reanchor_retry_rejected(sid)                 // both attempt + retry failed → a real gap
            recordArmFailure(sid)                            // counts toward the breaker (arm A: 5 consecutive → disable)
    else if session was in invalidatingSessionIDs:
        log ext_session_intentional_invalidation
    ...

recordArmFailure(sid):
    if armOf(sid) == A { armAConsecFailures += 1; if armAConsecFailures >= 5 { disableArmA(); log reanchor_armA_disabled } }
```

## 4. The central unknowns → the A/B/C delay experiment

**Two opposing failure modes pull on the delay length** — which is why a binary delay/no-delay split isn't enough:
- **Too short** → the inline `start()` may hit the old session's not-yet-processed teardown and be **rejected for overlap** (`.sessionInProgress`). External-review consensus: a rejection = a real coverage gap, because `invalidate()` is a *terminal* teardown IPC — the old session is already gone, not recoverable (§8.2).
- **Too long** → the no-session window may be long enough for the OS to **suspend the BLE central**, severing the sensor link even though the replacement session starts fine (§8.10b / open-Q #10), *and* it widens the window for a scene flip mid-wait.

So the right delay, if one exists, is a **sweet spot** between overlap-rejection (short) and BLE-severing (long). We don't know where it is, or whether it exists. We measure.

**Three arms (A/B/C), round-robin by a persisted attempt counter** (replaces hour-parity — all three external reviewers flagged time-of-day routine bias):
```
attemptCounter += 1                          // persisted in UserDefaults, survives restarts
delayMs = [0, 100, 300][attemptCounter % 3]
```
| arm | delay | what it probes |
|---|---|---|
| **A** | 0 ms | pure inline — does synchronous `invalidate→start` actually overlap-reject? |
| **B** | 100 ms | minimal delay — enough for the daemon to clear teardown, short enough to (hopefully) not sever BLE |
| **C** | 300 ms | overlap-safe, but most exposed to BLE-sever and to a scene flip during the wait |

`delay_ms` + a local `session_id` are logged in every `reanchor_*` event, so arms are self-labeled regardless of bucketing.

**Sample size:** ~15–20 re-anchors/day ÷ 3 arms ≈ 5–7/arm/day → plan a **~3–4 day** soak (not 1–2) for confidence, or read only *strong* early signals (e.g. arm A rejecting nearly every time).

**Single same-visit retry on rejection.** A rejection usually means the daemon hadn't finished tearing down the old session yet — so on `.sessionInProgress`, retry `start()` once ~200 ms later (the old session is gone by then). This is what rescues the would-be gap, and is likely the right *shipping* behavior (zero-delay speed on the happy path, fall back only when needed). First-attempt and retry outcomes are logged **separately** (`reanchor_replacement_rejected`, then `reanchor_retry` / `reanchor_retry_succeeded`) so the raw per-arm rejection signal stays clean.

**Arm-A circuit-breaker:** a swap counts as a true failure for the breaker only if **both** the first attempt *and* its retry fail. After **5 consecutive** such arm-A failures (reset on any arm-A success), drop arm A from rotation (`delayMs = [100, 300][counter % 2]`), log `reanchor_armA_disabled`, re-enable on the next build. B/C need no rejection breaker (the delay avoids overlap); arm C's BLE-sever risk is watched in the read-out (§6 item 4) and pulled manually if 300 ms is clearly severing.

**Scene re-check in B/C:** B and C dispatch `start()` after a delay, so they must re-verify `scene == .active` inside the delayed closure (watchOS can flip in single-digit ms) and abandon+log if not. Note the old session is already invalidated by then, so an abandon there is itself a gap — that residual gap is the intrinsic cost of any non-zero delay, and is one of the things the three-arm comparison prices.

## 5. Telemetry — log everything

Every event carries `delay_ms` (0/100/300), `session_id` (local UUID, **not** an object address — for cross-event correlation), `session_age_s` (from the persisted true-age clock, §8.7), `scene_phase`, `scene_at_start`, `ext_session_active`.

| Event | Meaning |
|---|---|
| `reanchor_skip` (+reason) | check fired but didn't attempt (not_active / not_near_expiry / pending_start) |
| `reanchor_attempt` | swap starting; records `delay_ms`, `sid`, `old_state_before` |
| `reanchor_invalidated` | old session `invalidate()` issued; records `old_state_after` |
| `reanchor_in_swap` | marks the no-session window; correlate with EGV stream for BLE-sever (#10) |
| `reanchor_start_issued` | replacement `start()` called; records `scene_at_start` |
| **`reanchor_replacement_started`** | replacement `didStart` fired — **launch** success |
| **`reanchor_replacement_rejected`** | first-attempt `didInvalidate(.sessionInProgress)` — raw per-arm overlap signal |
| `reanchor_retry` | single ~200 ms same-visit retry issued (§8.8) |
| **`reanchor_retry_succeeded`** | retry's `didStart` fired — the rescue worked |
| **`reanchor_retry_rejected`** | retry *also* rejected → a real gap; counts toward the arm-A breaker |
| `reanchor_abandoned` (+reason) | scene left active during a B/C delay or the retry / start threw |
| `reanchor_pending_timeout` | 15 s backstop fired (replacement never resolved) |
| `reanchor_armA_disabled` | circuit-breaker tripped — arm A dropped from rotation (§4) |

Plus existing `ext_session_started` / `ext_session_active` stamping and the EGV `sequence` stream. **Survival** (`replacement_survived_5m` / `_15m`) is *derived*: did the `session_id` from a `reanchor_replacement_started` still own the live session 5/15 min later (no intervening invalidate)? — launch ≠ a meaningful OS budget.

## 6. Read-out — how we decide (per arm A/B/C)

1. **Launch success rate** = `reanchor_replacement_started` / `reanchor_attempt`.
2. **Rejection rate** = `reanchor_replacement_rejected` / `reanchor_attempt` → the **overlap** axis (expected to fall as delay rises).
3. **Survival rate** = `replacement_survived_15m` / `reanchor_replacement_started` → did the OS grant a *real* budget, not a 2-min stub.
4. **BLE-sever / swap-gap correlation (#10)** = EGV misses whose timestamp lands in a `reanchor_in_swap` window → the **sever** axis (expected to *rise* as delay rises). This is what makes the three arms worth running.
5. **Net miss reduction** = EGV misses in re-anchor windows vs the v1 baseline (3/3 post-re-anchor).

**Decision matrix:** the winning arm maximizes (launch × survival) while minimizing (rejection + sever). Concretely:
- An arm with high launch **and** high survival **and** low swap-gap misses → ship that delay.
- If A rejects ~always but B/C don't, and B's sever rate ≤ C's → ship **B** (shortest delay that clears overlap).
- If *every* arm fails (low survival, or sever ≥ overlap savings) → inline is not viable on watchOS; **abandon re-anchor** and rely on natural foreground refresh (already ~continuous per §9).
- **Ship threshold (set in round 4, before any data):** the winning arm's swap-window miss rate must be **≤ the natural-cadence baseline (≈0 misses)** *and* re-anchor must visibly hold coverage across **≥2 real >60-min gaps**. If it can't beat "do nothing," abandon — no post-hoc goalpost-moving.

## 7. Fail-safe & rollback

- **Single feature flag** (`reanchorEnabled`, default … TBD by review) so it can be killed without a rebuild path change.
- **Arm A** has no slow window (synchronous invalidate+start while active). **Arms B/C** re-check `scene == .active` inside the delayed closure and abandon if it flipped. The **arm-A circuit-breaker** (§4) stops zero-delay once it's shown to reject, so the experiment can't keep self-harming.
- **Object-identity attribution + persisted true-age clock** (§8) so adopted/resurrected sessions are aged and routed correctly, not mis-handled.
- **If `start()` is rejected** and the old session turns out to be *gone* (the bad case), the loss is bounded to ≤15 min (we only act ≥45 min into a 60-min budget) and the next foreground open restarts — same floor as today's natural cadence.
- **15 s pending watchdog** remains a backstop (clears `pendingReanchor`/`sessionPendingDidStart`), but is explicitly *not* on the happy path.

## 8. Open questions for reviewers (please pressure-test these)

**Resolved in round 3** (3 external reviews — see §11):
- **Bucketing** → persisted attempt-counter `% 3` (A/B/C). All reviewers flagged hour-parity routine bias.
- **Delay values** → A/B/C arms = 0 / 100 / 300 ms (Charlie's call; Gemini-Ext's "drop zero" declined — circuit-breaker bounds it).
- **Attribution** → object identity (`session === pendingReanchorSession`); `userTag` doesn't exist on `WKExtendedRuntimeSession`, subclassing is unstable.
- **Age clock** → persist the `didStart` wall-clock to `UserDefaults`; compute age from it, so an adopted/resurrected session isn't mis-aged.
- **Sustained-active gate** → dropped in round 2; the inline swap closes the glance window by design.

**Resolved in round 4** (Charlie):
- **Retry within one activation (was 8.8)** → **yes**, a single ~200 ms same-visit retry on rejection (the daemon has cleared the old session by then). First-attempt vs retry logged separately so the raw rejection signal stays clean. §3, §4, §5.
- **Ship/no-ship threshold (was 8.11)** → winning arm's swap-window miss rate must be **≤ the natural-cadence baseline (≈0)** *and* we must observe **≥2 real >60-min gaps where re-anchor held coverage**. If it can't beat "do nothing," abandon. Set now, before any data is read. §6, §9.
- **Circuit-breaker params** → trip arm A after **5 consecutive** true failures (both first attempt *and* retry fail), reset on any arm-A success. §4.

**Still open:**
2. **🔴 Rejection = loss (lean: yes).** All reviewers argue `invalidate()` is a *terminal* teardown IPC, so a rejected `start()` leaves no session → a real gap, not harmless. ChatGPT adds **Case C**: the old session can linger a few seconds then expire — looks fine in telemetry but isn't. The A/B still *confirms* this empirically (arm A) with the circuit-breaker bounding harm. Q: is there a live probe (`old.state` post-invalidate, logged as `old_state_after`) that distinguishes Case A/B/C in real time?
5. **Watchdog interaction:** keep the 15 s watchdog (IPC can black-hole `start()` — neither delegate fires). Can it misfire and double-start on the inline path, or race the 200 ms retry?
9. **Deploy-time age reset:** just after install, an already-old session won't re-anchor until 45 min later (clock seeds to now). Note for first-hours-of-soak interpretation.
10. **🔵 Start-while-active sufficiency:** does `start()`-while-active suffice if the app backgrounds before `didStart`? Measured via `scene_at_start`, not gated. (Gemini-Pro: theoretically yes — the system registers intent during the active state.)
10b. **🔵 BLE-sever during the swap gap (#10):** does the no-session window (esp. 300 ms, arm C) let the OS suspend the CoreBluetooth central and drop the sensor? Measured by correlating `reanchor_in_swap` with EGV-stream drops across arms (§6 item 4). This is the *sever* axis that opposes the *overlap* axis — the reason there are three arms.

*(8.8 retry, 8.11 threshold, and circuit-breaker params resolved in round 4 — see above.)*

## 9. The prior question this doesn't answer: is it worth it?

The build-212 data shows the user opens the app every ~45–65 min, and each open refreshes the ~60-min session *just before* it lapses — so natural cadence already keeps coverage near-continuous. The re-anchor only earns its keep when the user goes **>60 min without opening the app.** Before investing in tuning this, a day of `scene_phase` telemetry should answer *how often that gap actually occurs.* If it's rare, the correct outcome of this whole exercise is **revert and don't rebuild.**

**🚧 Formal exit criterion (promoted to a hard gate by all three round-3 reviewers):** if **≥90–95% of session expiries are naturally refreshed by a foreground open before coverage is lost**, abandon re-anchor *regardless of the A/B/C outcome* — the complexity and maintenance burden aren't justified by the residual edge case. This `scene_phase` gap-frequency number is a **blocker on any RC merge**, gathered in parallel with the A/B/C soak.

## 10. Implementation note

When converged: implement on `Trio Watch App Extension/G7WatchSensorAdapter.swift` (feature/watch-g7), update patch-09 via **`--cherry-pick`** (NOT `--from-feature-branch` — it shares `AppleWatchManager.swift` with patch-13; see build-212 impl log §changelog). Verify on-device by soak + telemetry read-out (§6) **before** declaring done. Do not ship on static review.

## 11. Review log

**Round 1 — cursor-task (2026-06-21), status PASSED.** Reviewed this doc against the still-on-disk v1 diff. Outcome:
- **Validated §1's diagnosis independently** — v1 sequential re-anchor "ends a near-expiry session ~15+ min early with no replacement — strictly worse than doing nothing"; confirmed all 3 build-212 misses fell post-re-anchor while the no-re-anchor stretch was clean. Endorsed the v2 direction (sustained-active gate + inline swap + A/B).
- Folded into this doc: §8 open-Qs 7 (callback-time vs OS-budget age), 8 (retry within one activation), 9 (deploy-time age reset).
- **Telemetry refinement (to fold into §5 at implementation):** during the swap, v1 clears `ext_session_active=false` before the replacement starts, which makes C-212-4 stamping misreport continuity. v2 should emit a distinct **`reanchor_in_swap`** state (or keep `ext_session_active` accurate across the inline swap) so the §6 item-3 continuity read-out isn't fooled by the swap-window artifact.
- Noted (operational, not design): the v1 diff on disk still ships the broken sequential re-anchor + has no kill switch — reinforces reverting/replacing C-212-5 before the next build, and adding the `reanchorEnabled` flag (§7) in v2.

**Round 2 — Charlie (2026-06-21).** Dropped the sustained-active gate. Rationale: it was a holdover mitigation for v1's *slow* (>15 s) swap; the inline swap is two synchronous calls (<1 ms) completing while active, so the "burn a session on a glance" window is already closed by design. The gate only added complexity and reduced firing frequency. The one risk it nominally covered — start-while-active sufficiency if the app backgrounds before `didStart` — is now **measured** (§8.10, `scene_at_start`), not gated against. Also added the arm-asymmetry result to §4 (`noDelay` has zero gap; `delay` re-introduces a 300 ms sliver of v1's harm).

**Round 3 — external (2026-06-21): ChatGPT-5.5, Gemini-3.1-Pro, Gemini-3.1-Pro-Extended.** All three: *approve with revisions*; the inline pivot and "measure don't guess" stance endorsed. Dispositions folded into this rev:
- **Bucketing → persisted attempt-counter `% 3`** (all 3 flagged hour-parity routine bias). §4.
- **A/B → A/B/C 0/100/300 ms** (Charlie). Two opposing axes now explicit: *overlap-rejection* (short) vs *BLE-sever* (long); the sweet spot, if any, is what we hunt. §4, §6.
- **Rejection = loss** (both Geminis: `invalidate()` is terminal IPC; old session "walking dead"). ChatGPT's **Case C** (lingers then dies) added. Raises arm-A stakes → **arm-A circuit-breaker** added (§4). §8.2.
- **Survival metric** (ChatGPT): launch ≠ budget → derived `replacement_survived_5m/15m`. §5, §6.
- **Attribution** (Gemini-Ext): `userTag` doesn't exist → **object identity** + local UUID `session_id`. §3, §5, §8.
- **Persisted true-age clock** (Gemini-Ext + cursor r1): avoids the adoption-resets-clock-vs-OS-budget drift. §3, §8.
- **`reanchor_in_swap`** + the **#10 BLE-sever correlation** adopted as the sever-axis read-out (Gemini-Ext + cursor r1). §5, §6, §8.10b.
- **B/C scene re-check** restored inside the delayed closure (Gemini-Pro). §3, §4.
- **§9 promoted to a hard exit-criterion / RC blocker** (all 3): abandon if ≥90–95% of expiries are naturally refreshed. §9.
- **Declined:** Gemini-Ext's "drop the zero arm" — kept as arm A behind the circuit-breaker, since confirming "does zero reject?" is cheap and avoids baking in an unnecessary delay.
- **Carried to reviewers:** §8.11 (set the ship/no-ship EGV-miss threshold before reading results — Gemini-Pro).

**Round 4 — Charlie (2026-06-21).** Closed the three remaining judgement calls:
- **Retry-within-activation (§8.8) → adopted:** one ~200 ms same-visit retry on rejection (the rescue for the rejection=loss case); first-attempt vs retry logged separately.
- **Ship threshold (§8.11) → set, pre-data:** swap-window miss rate ≤ natural baseline (≈0) **and** ≥2 observed >60-min gaps held. Can't beat "do nothing" → abandon.
- **Circuit-breaker → 5** consecutive true arm-A failures (first + retry both fail), reset on any success.

**Design is settled.** Remaining open items (§8.2, 5, 9, 10, 10b) are *empirical questions the soak answers*, not design decisions. Next: implement (§10) → A/B/C soak ~3–4 days + the §9 gap-frequency blocker → read out (§6).
