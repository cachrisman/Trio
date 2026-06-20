# Watch-G7 complication-freshness scan — adversarially-verified findings

**Created:** 2026-06-16
**Status:** Verified. Findings below were produced by a 4-way review (cursor, codex, two Claude
subagent passes) and then **adversarially re-checked against the actual code** — each finding was
assigned to an agent whose job was to *refute* it, defaulting to "not real" unless cited code
proved otherwise. This doc records the verdicts, not the raw scan.

**Scope:** the watch-g7 work added two *on-watch* glucose producers — direct G7 BLE
(`G7WatchSensorAdapter.swift`) and HealthKit (`WatchState.swift` HK path) — feeding a complication
freshness pipeline (builds 131–209) that was built and hardened around the phone WatchConnectivity
(WC) channel as the sole producer. The recurring failure mode is: **the new producers skip
machinery the WC path has** (unit formatting, unified-history delta, arbitration quality).

> **Lesson reinforced:** the original collation led with "4/4 consensus = strong." Adversarial
> verification confirmed the P0 but **refuted the two next-loudest bug claims (#4, the strong
> reading of #3)** — consensus among reviews reading the *same code* is partly shared blind spot,
> not independent confirmation. Verify load-bearing claims in code before they drive a plan.

---

## ✅ Confirmed real — worth fixing

### #1 — BLE/HK store raw mg/dL → mmol users see wrong glucose  **(P0, safety)**
The two on-watch producers store the raw integer mg/dL as the display string; nothing downstream
converts it for mmol/L users. The widget and live bubble render the string verbatim.
- BLE: `G7WatchSensorAdapter.swift:1174-1184` — `glucose: "\(tail.glucoseMgDl)"`.
- HK: `WatchState.swift:783-797` — `String(hkMgDl)`.
- Widget renders verbatim: `TrioWatchComplication.swift:337,403`. Bubble: `GlucoseTrendView.swift:155`.
- The WC path **does** convert (`AppleWatchManager.swift:299-304`, `formattedAsMmolL`) — this
  asymmetry is the bug. The converter `WatchGlucoseColorComputer.displayValue(forMgDl:)` exists
  (`WatchGlucoseColorComputer.swift:147`) but is used only for chart Y-values, never the face number.
- **Common path** (BLE wins arbitration). mmol users see `100` instead of `5.6`.
- **Fix:** store **canonical `glucoseMgDl: Int`** in the snapshot, format in the widget/view by unit
  preference. (Routing the producer strings through the converter is the smaller-but-leakier
  alternative; note `Int(snapshot.glucose)` call sites at `WatchState.swift:1065,1089` assume a bare
  int and must change in lockstep.)

### #2 — Arbitration: ±1s window ignores source priority + completeness  **(P1)**
`shouldUpdate` (`TrioComplicationDataStore.swift:640-673`): within the ±1s window neither the
newer-wins nor older-rejects branch fires; the sequence guard (`:652`) is skipped because WC carries
`sequence == nil` (see #2a); `sameCore` (`:661`) is false whenever trend differs (BLE 5-min rate vs
phone direction routinely differ), so the priority block (`:662-667`) is skipped; the fallthrough
(`:668-672`) then returns `true` on any trend/delta difference. **A WC reading with empty `""`
trend / `"--"` delta overwrites a complete BLE reading.** Empty WC payloads are realistic
(`AppleWatchManager.swift:382,385-397,502-503`).
- Nuance: "can't be repaired" is **overstated** — the next reading >1s away with good fields repairs
  it. The immediate clobber is real and user-visible.
- **Fix:** completeness-aware arbitration — never let empty trend/delta replace populated; score
  recency → completeness → source in the ±1s window.

### #2a — Phone never sends `g7_sequence`, so the sequence guard can't engage  **(P1, enabler)**
Key exists (`WatchMessageKeys.swift:58`) and the watch reads it (`WatchState.swift:1410,2084,2310`),
but the phone field `g7Sequence` (`Trio/Sources/Models/WatchState.swift:34`) is **never assigned**
and absent from both serializers (`AppleWatchManager.swift:498-535,763-771`). So every WC snapshot
reaches `shouldUpdate` with `sequence == nil` and the guard at `:652` can only ever work BLE-vs-BLE.
- **Fix:** populate `g7_sequence` on the phone payload. Prerequisite for the guard to matter
  cross-channel, but #2's completeness guard is the load-bearing fix.

### #2b — BLE delta from a per-process baseline, not unified history  **(P2)**
`lastSavedGlucoseValue` is an in-memory `Int?` (`G7WatchSensorAdapter.swift:156`), nil at cold start
and reset on sensor swap (`:436`) / EOS (`:796`); delta computed against it (`:1088-1092`). So the
first reading after restart/swap emits `"--"`, even though `WatchGlucoseHistoryStore` holds the prior
reading and is written in the same drain path (`:1165-1172`).
- **Fix:** seed the delta from `WatchGlucoseHistoryStore` (all sources). Folds into the #1 refactor.

---

## 🟡 Confirmed but overstated / low-payoff

### #3 — Reload→getTimeline gap  **(P2, partially confirmed)**
- **(a) No trailing-edge flush** — true code fact (`coalescedReloadOnMain` early-returns at
  `TrioComplicationDataStore.swift:977-983` with no deferred schedule) **but severity overstated**:
  a retry timer (`:1125-1153`) and WidgetKit's 5-min `.after` policy (`TrioWatchComplication.swift:258`)
  bound it to *latency*, not data loss.
- **(b) Detector "process-volatile"** — **half wrong.** The trigger timer is in-memory
  (`:376-377,:1084-1101`), but its comparison inputs **are persisted** to the App Group
  (`reloadGenerationKey` `:1044-1047`; `widgetObservedGenerationKey` written by the widget at
  `TrioWatchComplication.swift:203`/`:886`). The only genuine gap: **nothing re-runs the comparison
  on resume/launch.**
- **Fix (narrow):** a launch-time reconciliation comparing the two already-persisted generation
  counters recovers across suspension without a live timer. Lower priority than #1/#2.

### #6 — HK same-epoch corrections dropped  **(P2 code, ~unreachable)**
`WatchState.swift:742` skips on epoch equality without comparing value, so a corrected same-epoch
sample is lost. **But G7 EGVs aren't retroactively corrected in place**, so the path isn't exercised
by the real data source. Cheap value-compare fix exists; negligible real payoff. Note the skip also
serves as the idempotency guard — a value-compare fix preserves that.

---

## ❌ Refuted — do not implement

| # | Claim | Why refuted |
|---|---|---|
| **#4** | Widget process writes `lastValidTimestamp` → rolls watermark backward (*"sharpest find"*) | **High-confidence refute.** `save()` write (`TrioComplicationDataStore.swift:820`) is **not compiled into the complication target** (`scripts/sync_project_files_config.rb:25-29`); the only widget-reachable write is hydration double-gated under `== nil` (`:930-941`) — can only go nil→value, never backward. Proposed `#if` guard fixes nothing. |
| #1a | `forceComplicationUpdate` checks mmol bounds vs mg/dL string | Code is already unit-aware (`WatchState.swift:2349-2362`), with a comment citing it as fixed in an earlier review. |
| #5 | HK trend overstates after a gap (no guard) | A 15-min suppression guard already exists (`WatchState.swift:765,771`). Worse: the proposed `delta*300/Δt` *reduces* magnitude for the common single-missed-sample case and injects high-variance extrapolated arrows. |
| #7 | HK batch newest-only → wrong predecessor | Descending sort picks predecessor = `sortedByDate[1]` correctly (`WatchState.swift:729,752`). (Separate real gap: intermediate batch samples aren't persisted to history — *not* #7's claim.) |
| #8 | `Task { @MainActor }` reorders BLE EGVs → wrong delta | Refuted in practice: serial upstream `delegateQueue`, ~5-min cadence makes concurrency unreachable, and every authoritative gate is monotonic/sequence-guarded (`G7WatchSensorAdapter.swift:1041-1048`; `TrioComplicationDataStore.swift:759-774`; `WatchState.swift:1124-1126`). |
| #9 | Live-UI monotonic guard mixes render-clock vs reading-clock | Premise factually wrong — all guards compare reading-date vs reading-date (`WatchState.swift:1124,1029-1030,2555-2556`). The delivery-clock field feeds only a 15s anti-flicker debounce. Also foreground-UI-only — out of scope for the complication. |
| #10 | `dedupQueue` read-on-queue / write-off-queue coherence gap | `dedupQueue` never writes (`TrioComplicationDataStore.swift:699-707`); the single authoritative writer is main-thread `saveOnMain` (`:734-787,823-826`). Worst case = redundant work, never a stale/backwards reading. |

---

## Net for build 210

The real, worth-fixing set collapses to **two safety/correctness themes** (→ folded into the
build-210 budding list as **D210-7** and **D210-8**):

1. **Canonical mg/dL + unit-aware display** — fixes #1 (P0), #2b (delta baseline), and the residual
   #1b coloring fallback in one structural change. *Live on every mmol user's BLE-fed face today.*
2. **Completeness-aware arbitration + arm the sequence guard** — #2 + #2a.

`#3`'s narrow resume-reconciliation piece and `#6`'s value-compare are optional fast-follows.
