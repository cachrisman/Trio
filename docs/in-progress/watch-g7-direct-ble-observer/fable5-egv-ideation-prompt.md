# Fable 5 — Watch G7 EGV-Success Ideation Prompt

**Paste the section below into a new Fable 5 code session** (from the `Trio-dev` worktree on `dev`). It asks Fable to review the docs + code and produce a **new, validated candidate list** of improvements to increase watch-side G7 direct-BLE EGV (glucose reading) capture success, appended to the build 216 impl plan.

---

## PROMPT (copy from here)

You are a senior iOS/watchOS + CoreBluetooth engineer reviewing the Trio watch **G7 direct-BLE observer** to propose ways to **increase EGV (glucose reading) capture success on the watch**. This is an ideation + feasibility-validation task, **not** an implementation task — do not edit source code. Your deliverable is a validated candidate list appended to the build 216 impl plan (location + format at the end).

This path has ~18 months of iteration; **most obvious ideas have been tried and ruled out.** Your value is in two things:
1. **Subtle-difference revival** — find previously-rejected ideas whose rejection rested on an *assumption* (not a soak-proven result), a *confound*, or a *whole-idea dismissal that a narrow sub-case sidesteps* — and articulate the precise, load-bearing difference that would change the outcome.
2. **Genuinely new** approaches not previously considered.

Both are only useful if they survive validation. Be adversarial with your own ideas — this codebase's own history is that ~8 of 10 fresh ideas die on contact with watchOS/CoreBluetooth reality. Kill your weak candidates yourself.

**Checkpoint first — before proposing anything, stop and report back for confirmation:** (a) restate the hard-constraints list in your own words (proving you absorbed the ruled-out reality), and (b) the top 3 telemetry signals you pulled with the actual numbers. Wait for the go-ahead before generating the candidate list. This early read lets the human course-correct before you spend the session on candidates.

### Required reading (in this order — do not skip)
1. **`docs/in-progress/watch-g7-direct-ble-observer/egv-intervention-index.md`** — the canonical catalog of everything tried/rejected/prohibited (builds 04–216) + the telemetry baseline + a validated candidate pool with verdicts. **This is your do-not-repeat list.** Anything in its "Rejected / Prohibited" table or culled candidate pool is off-limits *unless* you present new evidence or a genuine subtle difference (see below).
2. **`AGENTS.md`** (repo root or `../Trio/AGENTS.md`) — safety rules and verification discipline. Note the enum/API-verification rule: verify platform behavior against headers/docs, never from memory.
3. **Constraint docs — read these before proposing anything about background execution or the protocol:**
   - `watch-g7-direct-ble-observer-build206-impl-plan.md` and `-build207-impl-plan.md` — watchOS background-execution model; `WKExtendedRuntimeSession` is frontmost-only; the `com.apple.developer.bluetooth-central-background` entitlement is blocked on Apple.
   - `watch-g7-direct-ble-observer-build212-impl-log.md` — windowed session-holding is impossible; the Return-to-Clock A/B result.
   - `trio-fable5-review.md` — **the background BLE central (not the ext-session) is the workhorse: ~73% of captures occur with no active session.** Also the "no-quiescence-primitive" caveat on window-anchored radio arming.
   - `../watch-direct-ble-cgm/watch-direct-ble-cgm-01-design.md` — the **passive-observer contract** (never send auth-init; never write to control except a fallback `0x4E`).
   - `watch-egv-betterstack-status-prompt.md` — the telemetry schema, event glossary, and metric definitions.
4. **Cross-implementation ideas:** `../watch-direct-ble-cgm/watch-direct-ble-cgm-05-diable-comparison.md`, `-06-diable-trio-investigation.md`, `-07-comparison.md`, `-09-preconnect-review.md` — how DiaBLE and the iOS G7 path differ from the watch observer. The iOS G7 path achieves ~99%; look for what the watch lacks.
5. **Code (read, do not edit):**
   - Fork (canonical read location for G7SensorKit): `~/Code/personal/health/diabetes/G7SensorKit/G7SensorKit/G7CGMManager/` — `G7BluetoothManager.swift` (scan/connect/reconnect/timeout ladder), `G7Sensor.swift` (auth + parse), `G7PeripheralManager.swift` (GATT).
   - Watch adapter: `../Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` (session lifecycle, reanchor, stall classification) and `WatchState.swift` (scene handling).

### Hard constraints (a candidate that violates any of these is invalid — state how yours complies)
- **No new background wake exists.** watchOS offers exactly three background-execution paths and all are used or blocked: ext-session (frontmost-only), CoreBluetooth restoration + connection events (already the workhorse), and the blocked Apple entitlement. `WKApplicationRefreshBackgroundTask` and `HKObserverQuery` wakes cannot reliably run a fresh BLE connect+auth and are already ruled out for capture — do not re-propose them without a concrete, cited mechanism.
- **Passive-observer contract:** the watch must not send auth-init and must not write to control (except the existing fallback `0x4E`). Backfill is **push-based** (subscribe → sensor pushes → `0x59` terminates); there is no range-request.
- **CoreBluetooth central API limits:** a central cannot set connection interval / supervision timeout / link parameters — do not propose "tune connection parameters."
- **Never suppress the fork's autonomous reconnect loop** — it delivers the 73% background captures.
- The fork is shared with the iPhone; watch-only behavior must be gated, and G7SensorKit edits are fork-first (do not assume you can change shared connect logic freely).

### Telemetry baseline to target (build 215 soak, n=1, from the index)
- Connect funnel (`g7_core`): 2745 `connect_called` → 904 `did_connect` (~**33%**); 948 `connect_timeout` (avg age ~140 s); **not** a storm (C-210-7 gate rarely trips — ~3.1 calls/window).
- Yield: session-active ~**93%**, no-session ~**52–58%**; coverage ~44% and app-open-gated.
- `pre_egv_disconnect` 1084, `since_connect_s`=0–9 (drops within seconds); only ~12% `suspected_eos=true`.
- Stalls: ~95% `fault=dexcom_side`, 100% `phone_fresh=true` (sensor reachable by phone during the stall).
- Deep gaps: observer awake (`heartbeat`/`expected_window` firing) but `connect_called=0` = **scan running, no candidate advertising** (or process suspended) — indistinguishable today. **RSSI is not logged** (216-A pending); scan-liveness is not logged (216-B pending).

### Live telemetry access (discover your own signals — don't just trust the baseline above)
You have the BetterStack MCP query tool. Use it to find sub-case signals the aggregate numbers hide (this is often where the *subtle differences* live).
- **Tool:** `mcp__betterstack__query` · **source_id:** `1659391` · **table:** `t491594.trio`
- **Historical (any window >30 min):** `FROM s3Cluster(primary, t491594_trio_s3)` with `_row_type = 1`. Never use `remote(...)` for >30 min — it silently returns empty.
- **Filter:** `JSONExtract(raw,'platform','Nullable(String)')='watchos'` and usually `category='WatchTelemetryRing'`. Build numbers are **strings** (`IN ('215','216')`).
- **Fields live inside a `message` key=value blob**, not top-level JSON. Extract sub-fields with `extract(JSONExtract(raw,'message','Nullable(String)'),'key=(\\S+)')` — e.g. `module` (`g7_ble` adapter vs `g7_core` fork), `scene_phase`, `ext_session_active`, `reason`, `fault`, `phone_fresh`, `since_connect_s`, `consecutive_count`, `suspected_eos`, `battery_level_percent`, `age_s`, `seq`. Top-level JSON: `build`, `category`, `event`, `platform`.
- **Full query patterns, event glossary, and metric definitions:** `watch-egv-betterstack-status-prompt.md` (already in your reading list). 8-day retention; latest builds are 215/216.
- **Signal-hunting ideas** (not exhaustive): per-`scene_phase` yield within session-active (does `.inactive` really beat `.background`?); the connect→gatt_ready→auth_bonded→control_sub→egv **funnel drop-off stage**; `pre_egv_disconnect` distribution by `consecutive_count` and `since_connect_s`; whether `connect_timeout` clusters by time-of-day vs battery (test the 40%-battery confound); `attach_path` success rate by path (`stored_id` vs `connected_peripherals` vs `scan`); backfill yield (`backfill_finished`/`egv_received`).
- **Caveat:** n=1 device, single wrist — all figures are **directional**. Prefer signals that are robust across builds/days over single-window artifacts, and say when a candidate rests on a thin sample.

### Method (required rigor — mirror it explicitly in your output)
For **each** candidate:
1. **Classify** as `SUBTLE-VARIATION` (cite the exact prior ID/rejection from the index and state the precise load-bearing difference — assumption-not-proven, confound, or narrow-sub-case) or `NEW`.
2. **Attacks:** which specific baseline number / failure mode.
3. **Feasibility evidence:** cite the enabling watchOS/CoreBluetooth API (with its real capability) **or** a code site (`file:line`) that makes it possible. No assertions from memory — verify against headers/docs/code.
4. **Passive/contract/platform compliance:** one line on how it obeys the hard constraints.
5. **Adversarial refutation:** try to kill it the way the constraints killed the prior pool; keep it only if it survives, and show the survived-refutation note.
6. **Measurable pass/fail** and whether it is **blocked on 216-A/B data** first.
7. **Category:** does it improve *capture* (the goal) or only *battery/telemetry*? Label honestly.

Then **rank** the survivors by (EGV-success impact × feasibility), and give a short "graveyard" list of candidates you generated but killed, with the one-line reason (this is as valuable as the survivors — it prevents the next session from re-treading).

Heuristics for the subtle-difference lens: re-examine each *rejected* idea — was the rejection **empirical** (soak-proven) or **assumed**? Did a premise change (e.g. the `0x59` format is now known; the 40%-battery stall spike is a time-of-day confound, not LPM; RTC setting affects coverage)? Would a **narrow sub-case** (e.g. only the `.inactive` scene, only Trio-side stalls, only the first N seconds post-connect) work where the general form failed? Is there a **confound** in the aggregate data hiding a real effect?

### Output
Append a new top-level section to **`docs/in-progress/watch-g7-direct-ble-observer/build216-impl-plan.md`** titled **`## Fable 5 candidate ideation (YYYY-MM-DD)`**. Do not modify existing tasks or other sections. Use a summary ranking table followed by per-candidate detail in the method format above, plus the graveyard list. Keep each candidate in hypothesis → change → measurable-criterion form.

**Commit/PR hygiene:** no `Co-Authored-By` / AI-attribution trailers (AGENTS.md rule 11). Do not run builds. If you edit anything other than the plan doc, stop and explain why first.

## END PROMPT
