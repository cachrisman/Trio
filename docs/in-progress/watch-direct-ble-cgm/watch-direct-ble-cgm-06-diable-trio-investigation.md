# watch-direct-ble-cgm-06-diable-trio-investigation

Version: v1.5
Last updated: 2026-04-19

# 1. Executive conclusion

The previous v1.3 framing is now incomplete. The implementation log and current watch code shift the strongest conclusions in two important ways.

First, **F10 identifier-first retrieval is no longer just a proposed experiment**. It is implemented in Trio watch code, and build **170** shows that it materially changed the attach profile: watch logs recorded **90** `g7_ble_connect_attempt` events, **88** of them from **`source=retrieved_identifier`**, with **13** `g7_ble_did_connect`, **5** `g7_ble_services_discovered`, and **3** `g7_ble_characteristics_discovered` before the trail collapsed. That means the old “Trio almost never crosses `didConnect`” statement is no longer globally true for the current code line ([watch-direct-ble-cgm-02-implementation-plan.md](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-02-implementation-plan.md)).

Second, the active top-level investigation has moved again. **Phase G** shipped in build **171** and changed the question from “what attach source should Trio try next?” to “does cadence-aware scheduling plus stricter runtime gating produce better watch outcomes in live volume?” Build **171** proves that the Phase G scheduler and runtime gate are live, but the reviewed window still shows **0** watch-side `g7_ble_did_connect` and **5** `timeout_awaiting_connect` outcomes, all on **`source=retrieved_identifier`** ([watch-direct-ble-cgm-02-implementation-plan.md](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-02-implementation-plan.md)).

The best current evidence-backed read is therefore:

- **Attach context does matter.** Build 170 shows that identifier-first retrieval can reach `didConnect` and sometimes service / characteristic discovery.
- **Timing / runtime lifecycle now matter at least as much.** Build 170 shows repeated extended-runtime invalidation, and build 171 makes runtime activation / app-active gating explicit in logs.
- **Post-connect startup is still unresolved, but it is no longer purely hypothetical.** Trio has reached `didConnect`, services, and characteristics in the current code line, but still has not produced auth/control/EGV/snapshot completion on watch.
- The active next step is **Phase G live-log refinement**, not “run F10 next,” not “F5 first,” and not “promote G3 / F11 immediately.”

# 2. What changed since v1.3

The following v1.3 recommendations are now stale or need narrower wording:

- **“Evaluate F10 next” is stale.** F10 is implemented and live-reviewed in build 170.
- **“F5-first is the right immediate move” is stale as the top recommendation.** Build 170 already proved part of the post-connect trail: `didConnect` can happen, `didDiscoverServices` can happen, and `didDiscoverCharacteristics` can happen. The missing boundary has moved farther downstream, and the active shipped lane is now Phase G rather than another F5-style attribution build.
- **“The main current split is scan vs retrieved_data_service / retrieved_febc” is stale.** In current live code and current logs, the more important retrieved split is now **`retrieved_identifier`** vs everything else.
- **“Connection-event registration is the obvious next attach-context experiment” is too strong.** It remains conditional behind the shipped Phase G readout.

What remains valid from v1.3:

- DiaBLE still demonstrates a working watch observer path.
- Trio’s auth/J-PAKE redesign is no longer the dominant explanation.
- Discovery-scope widening (`discoverServices(nil)`, `discoverCharacteristics(nil, for:)`) remains a valid later test, but only after cadence-aware logs justify it.

# 3. Current Trio vs DiaBLE state

## 3.1 DiaBLE still defines the working observer reference

DiaBLE watch still provides the reference happy path: eager restore-backed central manager, retrieval on `.poweredOn`, broad discovery, auth notify, passive observer behavior around the owner session, control notify, and eventual EGV readout ([watch-direct-ble-cgm-04-diaBLE-logs.md](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-04-diaBLE-logs.md), [watch-direct-ble-cgm-05-diable-comparison.md](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-05-diable-comparison.md)).

## 3.2 Current Trio watch code is materially different from the v1.3 picture

Current `G7DirectBLEManager` now does all of the following in code:

- uses an eager restore-backed manager
- requires the phone-provided active sensor name, with trim-only normalization and exact match
- tries **`retrievePeripherals(withIdentifiers:)`** first
- then tries `retrieveConnectedPeripherals(withServices:)` for both the G7 data-service UUID and **FEBC**
- falls back to scan only after retrieval does not attach
- keeps targeted discovery (`discoverServices([dataService])`, targeted characteristic discovery)
- keeps the passive auth/control observer path
- keeps `registerForConnectionEvents` **absent** on watch
- in Phase G, moves runtime ownership and cycle scheduling into the manager and waits for **`extendedRuntimeSessionDidStart(...)`** before treating runtime as active ([G7DirectBLEManager.swift](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio%20Watch%20App%20Extension/G7DirectBLEManager.swift), [WatchState.swift](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio/Trio%20Watch%20App%20Extension/WatchState.swift), [watch-direct-ble-cgm-02-implementation-plan.md](/Users/charliechrisman/Code/src/cachrisman/diabetes/Trio-dev/docs/in-progress/watch-direct-ble-cgm/watch-direct-ble-cgm-02-implementation-plan.md)).

This means the current Trio gap is no longer “missing identifier continuity” or “missing cadence scheduling” in code. Both are now present and have live evidence.

## 3.3 Build-by-build evidence trail

### Build 166

- **17** connect attempts
- **1** `didConnect`
- the single moved session was retrieval-assisted
- that session timed out at `awaiting_gatt_setup`
- no services / characteristics / auth / control / EGV completion were proven in that build

Interpretation: the first hard evidence that attach context could move the boundary.

### Build 168

- **17** connect attempts
- all reviewed attempts still died at `awaiting_connect`
- retrieval returned **0** candidates on both reviewed service UUID paths
- no retrieved attach attempts were seen in the reviewed live window

Interpretation: useful attribution build, but still mostly a pre-connect story.

### Build 170

- **90** watch-side `g7_ble_connect_attempt`
- **88** `source=retrieved_identifier`
- **13** `g7_ble_did_connect` / `g7_ble_connected`
- **5** `g7_ble_services_discovered`
- **3** `g7_ble_characteristics_discovered`
- **0** `g7_ble_status_reply`
- **0** `g7_ble_control_notify_enabled`
- **0** `g7_ble_egv_received`
- **0** `g7_ble_snapshot_saved`
- **52** `g7_ble_ext_session_invalidated` with the repeated watchOS rejection text: “The app must be active and before applicationWillResignActive to start or schedule a WKExtendedRuntimeSession.”

Interpretation: this is the strongest new finding since v1.3. Identifier-first retrieval clearly moved the boundary in practice, but runtime / lifecycle pressure and downstream startup fragility still prevent a usable watch reading path.

### Build 171

- **44** `g7_ble_cycle_scheduled`
- **40** `g7_ble_cycle_anchor source=snapshot`
- **9** `g7_ble_cycle_started`
- **22** `g7_ble_runtime_gate` lines across `starting`, `active`, `active_waiting_for_lead_window`, `activation_timeout`, and `blocked_app_inactive`
- **5** `g7_ble_connect_attempt source=retrieved_identifier`
- **5** `g7_ble_timeout stage=awaiting_connect`
- **5** `g7_ble_cycle_missed category=timing reason=timeout_awaiting_connect`
- **0** `g7_ble_did_connect`
- **0** services / characteristics / auth / control / EGV / snapshot milestones

Interpretation: Phase G is definitely shipped and visible in logs, but in the reviewed window it has not yet reproduced build-170 attach success. The active live question is now how cycle timing, runtime activation, and app-active gating interact with the identifier-retrieval attach path.

# 4. Re-ranked evidence-backed findings

## 4.1 The dominant investigation is no longer “what should Trio try after scan?”

That was the right question for builds 166 to 168. It is not the right top-level question after builds 170 and 171.

The current top-level question is:

- under the shipped Phase G scheduler/runtime model, when do `retrieved_identifier` cycles start
- which anchor source is driving them
- what runtime-gate state they are in
- whether they reach `didConnect`
- and, if they do, where the next failure boundary sits

## 4.2 Attach-context asymmetry is real, but narrower than before

The best evidence-backed statement is now:

- Trio’s current live attach path of interest is **identifier retrieval**
- identifier retrieval can sometimes reach `didConnect`, services, and characteristics
- that does **not** mean attach context is solved
- it means attach context is no longer purely speculative and should now be analyzed together with runtime/timing state, not in isolation

## 4.3 Runtime / lifecycle pressure is now first-class evidence, not a side hypothesis

This is the biggest new substantive finding beyond v1.3.

Build 170 produced repeated `g7_ble_ext_session_invalidated` lines with an explicit watchOS rejection message, and build 171 now logs runtime-gate states directly (`starting`, `active_waiting_for_lead_window`, `activation_timeout`, `blocked_app_inactive`). That elevates runtime / app-active lifecycle handling from background theory to evidence-backed investigation lane.

## 4.4 Post-connect startup remains unresolved

Current evidence says Trio can now sometimes reach:

- `didConnect`
- service discovery
- characteristic discovery

But current evidence still does **not** show:

- stable auth status progression
- control notify readiness
- passive observation completion
- EGV receipt
- snapshot save

So the post-connect problem is real, but the active shipped build is currently failing earlier again.

## 4.5 The current live cadence anchor is mostly complication snapshot

Build 171’s reviewed window is dominated by `g7_ble_cycle_anchor source=snapshot`. That is an evidence-backed detail worth keeping prominent because it means the first live Phase G behavior is being seeded mainly from the saved complication snapshot in the reviewed window, not from direct-BLE reading timestamps.

# 5. What now looks weaker

These remain weak as primary explanations for the current shipped behavior:

- queue choice
- scan duplicate suppression
- returning to auth-init / J-PAKE / observer-path redesign as the main explanation

These are no longer the strongest immediate-next recommendations:

- “run F10 next”
- “F5-first”
- “promote F11 now”
- “promote G3 discovery widening now”

# 6. Current best next steps

## 6.1 Stay on Phase G live-log refinement

This is now the right top-level next step.

The highest-signal live questions are:

- how often runtime ends in `activation_timeout` or `blocked_app_inactive`
- whether `source=retrieved_identifier` attempts cluster inside the intended lead window
- whether the current snapshot-anchored cycles are starting too early, too late, or while the app is inactive
- whether any later build reproduces the build-170 `didConnect` / services / characteristics movement under the Phase G scheduler

## 6.2 Keep G3 conditional

`discoverServices(nil)` and broader characteristic discovery still make sense only if a cadence-aware build starts reaching `didConnect` again with enough regularity to justify a discovery-scope test.

## 6.3 Keep F11 conditional

`registerForConnectionEvents` is still a viable later attach-context experiment, but it should not displace the current Phase G readout unless Phase G evidence clearly points back to attach-context weakness rather than timing/runtime gating.

## 6.4 Keep PacketLogger conditional

PacketLogger / raw capture still becomes high-value if either of these happens:

- cadence-aware identifier-retrieval cycles keep timing out silently with no callback movement
- a future cadence-aware build reaches `didConnect` but still never shows the decisive next callback

# 7. Historical appendix: preserve useful non-active ideas

This appendix keeps the higher-value ideas from the longer v1.3 investigation so they are not lost, even though they are not the active top-level recommendation after builds 170 and 171.

## 7.1 Retrieved peripheral may still represent a better OS-known relationship than scan

Still useful later because build 170 supports the narrower claim that **identifier retrieval** can move Trio farther than scan. What remains unproven is the exact Apple/CoreBluetooth mechanism.

What would strengthen it:

- repeated success with the same `CBPeripheral.identifier`
- better outcomes for `retrieved_identifier` than scan in comparable timing windows
- later evidence that retrieval-state continuity correlates with `didConnect` or service discovery

What would weaken it:

- scan matching identifier-retrieval outcomes once timing/runtime are controlled

## 7.2 Manager lifecycle / restoration identity may still matter

Still useful because the first attach movement arrived after the long-lived restore-backed manager changes, and the current scheduler/runtime work still depends on that persistent manager posture.

What would strengthen it:

- success clustering around restored identity reuse or longer-lived watch sessions
- repeated cases where the same manager lifetime preserves better retrieval behavior

What would weaken it:

- no measurable difference once timing/runtime state is controlled

## 7.3 Connection-slot contention with the Dexcom watch app remains plausible

This is still worth retaining as a physical/runtime hypothesis even though it is not the active next implementation step.

What would strengthen it:

- better outcomes when Trio attaches in windows that appear less competitive with the Dexcom watch app
- raw capture or later logs suggesting attach attempts are rejected or starved rather than logically mishandled in Trio

What would weaken it:

- stable Trio success under the same ambient Dexcom-watch conditions once Phase G timing/runtime is improved

## 7.4 Timing-window / cadence alignment remains a core hypothesis lane

This idea is no longer just a hypothesis; Phase G is the shipped implementation response to it. Still, the earlier formulation is worth preserving because it explains why the initiative pivoted away from blind reconnect experiments.

What would strengthen it:

- `didConnect` or later progress clustering near the predicted reading window
- fewer misses once runtime is active before the lead window

What would weaken it:

- continued failures even when live evidence shows cycles are correctly aligned and runtime is active in-window

## 7.5 Discovery-scope widening is still a real later test

The older `F6/F7` ideas remain worth preserving, just not promoting yet.

What would strengthen them as the next step:

- cadence-aware builds reliably reaching `didConnect`
- a repeated stall at or immediately after current targeted discovery

What would weaken them:

- continued failure before `didConnect`
- strong evidence that runtime/app-active gating is still the earlier boundary

## 7.6 Connection-event registration on watch remains a later attach-context candidate

This remains useful as a later experiment if Phase G stops moving the boundary.

What would strengthen it:

- identifier retrieval failing to improve current live results further
- evidence that watchOS exposes useful connection-state changes that Trio is not currently observing

What would weaken it:

- Phase G timing/runtime refinements already producing stable attach progress without it

## 7.7 PacketLogger remains an escalation path, not discarded

The shorter rewrite kept this conditional, but the reason to preserve it explicitly is that it remains the best escalation tool if app-level logs stop being diagnostic.

Pull it forward if:

- cycles still die silently before callback movement after Phase G refinement
- `didConnect` happens again but the next missing callback remains ambiguous
- runtime state looks healthy but BLE progression still disappears without explanation

# 8. Bottom-line ranking of likely explanations

## Most likely, evidence-backed core explanation

The current watch problem is a **combined timing/runtime plus downstream-startup problem**, not a single attach-source problem. Identifier retrieval can move Trio into a better attach context, but stable watch runtime activation / app-active timing and later startup progression still fail to produce a usable reading path.

## Next most likely explanation

Attach-context quality still matters, specifically stable peripheral identity continuity. Build 170 strongly supports that, but build 171 shows that identifier retrieval alone is not sufficient.

## Next plausible explanation

Post-connect startup on watch is still fragile enough that even when Trio reaches `didConnect`, the session often dies before auth/control/EGV readiness.

## Currently weaker explanations

Queue parity, scan-option parity, and a return to observer/auth redesign as the main explanation.

# Changelog

## v1.5 — 2026-04-19

- Added a **historical appendix** that preserves the higher-value non-active ideas from the longer v1.3 version so they are not lost: retrieved-vs-scan OS-state interpretation, manager lifecycle/restoration identity, Dexcom-watch-app contention, cadence-window theory, later discovery-scope widening, connection-event registration, and PacketLogger escalation triggers.
- Kept those items explicitly labeled as preserved hypothesis lanes rather than current top-level recommendations, so the document stays current without discarding useful future investigation paths.

## v1.4 — 2026-04-19

- Reworked the document around the current implementation-log reality: **F10** is implemented and live-reviewed in **build 170**, and **Phase G** is shipped/live in **build 171**.
- Replaced the stale “F10 next / F5 first” recommendations with the current active conclusion: stay on **Phase G live-log refinement** while keeping **G3**, **F11**, and PacketLogger conditional.
- Added the strongest new evidence from the implementation log and current code: build-170 **`retrieved_identifier`** attach movement, repeated extended-runtime invalidation, build-171 cycle/runtime-gate counts, snapshot-dominated anchors, current retrieval/discovery/runtime behavior in `G7DirectBLEManager`, and the absence of watch-side `registerForConnectionEvents`.

## v1.3 — 2026-04-18

- Updated the executive framing and next-step sections to reflect that **F10 identifier-first retrieval** is now implemented in code as the next standalone watch attach-context experiment.
- Updated the retrieved-source explanation so the document now distinguishes **`retrieved_identifier`**, **`retrieved_data_service`**, and **`retrieved_febc`** rather than treating all retrieved-derived attaches as one path.
- Reworked the “what I would do next” guidance so it now centers on evaluating the F10 build rather than proposing F5/F5+dual-UUID as future work.

## v1.2 — 2026-04-18

- Added the build-168 live readout: F5 is implemented and deployed, retrieval currently returns zero candidates on both UUID paths, and all observed build-168 connect attempts remain scan-sourced pre-connect timeouts.
- Tightened the executive framing so the active live boundary is now stated as “retrieval absent, then scan-path timeout before `didConnect`,” while preserving the earlier build-166 retrieved-assisted success as relevant but not over-weighted context.

## v1.1 — 2026-04-17

- Added required document versioning metadata and changelog.
- Tightened wording around what `source=retrieved` does and does not prove.
- Reduced repeated explanations while preserving the current structure, hypotheses, and recommendations.

## v1.0 — 2026-04-17

- Initial consolidated investigation report covering Trio vs DiaBLE watch G7 BLE behavior, retrieval-vs-scan asymmetry, post-connect uncertainty, and prioritized next steps.
