# Build 215 Watch EGV Improvements — Implementation Plan

**Version:** v1.4

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session-lifecycle observability, fix one genuine retry-budget bug, and apply minor tuning to the G7 watch BLE path. **This plan does NOT "fix regressions" — see the framing note below.**

**Architecture:** Telemetry enrichment, one bounded retry-budget fix, and a constant tune — no new BLE logic, no new session lifecycle paths. G7WatchSensorAdapter / watch launch changes go into patch 09 (via `mid-stack-update.sh`). **G7SensorKit changes are fork-first** (standalone clone on `main`, then `repin-g7.sh` → patch 02) — never commit fork work only inside `Trio/G7SensorKit`.

**Tech Stack:** Swift, watchOS, WatchKit (WKExtendedRuntimeSession), CoreBluetooth, BetterStack telemetry via WatchTelemetryRing.

---

## ⚠️ Framing note: the build 214 "regressions" are not code regressions

A direct `git diff` of the build tags shows the BLE/session/EGV/configure-retry code is **byte-identical** between builds 213 and 214:

| File | Diff `trio-v0.8.3-213-localCI` → `trio-v0.8.3-214-localCI` |
|------|-----------|
| `G7WatchSensorAdapter.swift` | **empty (byte-identical)** |
| `G7PeripheralManager.swift` | **empty (byte-identical)** |
| `WatchLogger.swift` | +97 lines (logging transport only — not BLE behavior) |
| all others | build scripts, AGENTS.md, docs |

Therefore the reported deltas — session coverage 54%→22.9%, session-active yield 98.4%→90.2%, configure_retry_abandoned 3.6→6.3/100 — **cannot be attributed to a code change**; the code that produces them did not change. They reflect **sample / usage / RF-environment variance** between two short single-device soaks (~40h each, one wrist):

- **Coverage** is driven by app-open rate, which the report itself recorded as 0.30 opens/hr (214) vs 0.53 opens/hr (213). `renewSessionIfNeeded()` only starts a session while `scene == "active"` ([adapter:318](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)), so fewer opens ⇒ fewer sessions ⇒ lower coverage. Pure behavior-of-the-human, not code.
- **Session-active yield** "regression" is ~6 missed EGVs on 61 connects — within noise for this sample size.
- **configure_retry_abandoned** 3.6→6.3/100 is likewise a handful of events on a small denominator.

Additionally, 213's metrics were collected with a `WatchLogger` that **silently dropped overflow lines on large flushes** (the drop-counting fix landed after 214 — see Task 7), so cross-build metric comparisons are not even apples-to-apples.

**Recommendation:** Before treating coverage/yield as real problems, collect a longer or multi-device soak. The work below is justified on its own merits (observability we lack today + one real bug + low-risk tuning), independent of the noisy 213↔214 comparison.

---

## Global Constraints

- All **Trio app** code changes go in the `Trio` worktree on the feature branch; patch tooling runs from `Trio-dev` on `dev`.
- **G7WatchSensorAdapter / watch launch commits** (Tasks 3–5, 9–10): after each commit, run `./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>` from `Trio-dev`.
- **G7SensorKit commits** (Tasks 1–2, 2b): edit and commit in the **standalone fork** at `~/Code/personal/health/diabetes/G7SensorKit` on branch `main` — **not** in `Trio/G7SensorKit` (the submodule checkout inside the Trio worktree). Then from `Trio-dev`: `./scripts/repin-g7.sh` (pushes the fork, re-pins patch 02, runs `patch-test.sh`). The `G7SensorKit` gitlink in the Trio tree is updated when patch 02 is applied (`git am` during `patch-test.sh` / `ci/local-build.sh`) — **no separate submodule-pointer commit on the Trio feature branch.** Do **not** use `mid-stack-update.sh --patch 09` for submodule work — patch 09 carries no submodule diffs.
- Run `./scripts/patch-test.sh` after every patch update. A FAIL is a hard stop.
- Never hand-edit patch files. Never edit `scripts/patch-audit.safety-paths` or `.waivers`.
- No `Co-Authored-By: Claude` or `🤖 Generated with Claude Code` in any commit message or PR body.
- Static review + `patch-test.sh` are the verification tools; do not run `xcodebuild` or trigger builds as a verification step (AGENTS.md rule 10).

---

## G7SensorKit fork workflow (Tasks 1–2, 2b)

Trio's build clones G7SensorKit from the `cachrisman` fork on GitHub; it does **not** ship edits made only in `Trio/G7SensorKit`. The canonical edit location is the **standalone clone**:

| | Path |
|---|------|
| **Edit + commit here** | `~/Code/personal/health/diabetes/G7SensorKit` (`main`) |
| **Do not commit fork work here** | `Trio/G7SensorKit` (submodule checkout — detached or behind; commits here do not reach builds) |
| **Re-pin patch 02 from** | `Trio-dev` → `./scripts/repin-g7.sh` |

**Sequence:** (1) edit `G7SensorKit/G7CGMManager/G7PeripheralManager.swift` in the fork and commit on `main`; (2) `./scripts/repin-g7.sh` from `Trio-dev` (pushes fork, updates patch 02, runs `patch-test.sh`). That is the complete Tasks 1–2 handoff — **do not** commit a separate `G7SensorKit` gitlink bump on the Trio feature branch. When patch 02 is applied (`git am` in `patch-test.sh` or `ci/local-build.sh`), the `+Subproject commit` hunk advances the submodule pointer automatically.

Line references below that use `Trio/G7SensorKit/...` are for navigation against the pinned tree in the Trio worktree; **apply edits in the fork path** `~/Code/personal/health/diabetes/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift` (same relative path under the clone root).

---

## Files Modified

| File | Tasks | Patch | Where to edit |
|------|-------|-------|---------------|
| `G7SensorKit/.../G7PeripheralManager.swift` | 1, 2, 2b | patch 02 (`repin-g7.sh`) | **Fork:** `~/Code/personal/health/diabetes/G7SensorKit` |
| `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` | 3, 4, 5, 9 | patch 09 (`mid-stack-update`) | **Trio** feature branch |
| `Trio/Trio Watch App Extension/TrioWatchApp.swift` | 10 | patch 09 (`mid-stack-update`) | **Trio** feature branch |

---

## Task 1: configure_retry_abandoned telemetry enrichment

**Priority: LOW (convenience).** The abandoned tier is **already recoverable today**: `configure_retry_scheduled` ([line 245](../../../Trio/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift)) logs `attempt=N backoff_s=N` immediately before the work item is scheduled, so each `configure_retry_abandoned` can be correlated to the preceding `configure_retry_scheduled` on the same peripheral. This task only saves a windowed self-join in ClickHouse by stamping the fields directly. Cheap; do it alongside Task 2 since it's the same file.

> **Where to edit:** standalone fork `~/Code/personal/health/diabetes/G7SensorKit` — see [G7SensorKit fork workflow](#g7sensorkit-fork-workflow-tasks-12). Do **not** edit/commit only in `Trio/G7SensorKit`.

**Files:**
- Modify: `G7SensorKit/G7CGMManager/G7PeripheralManager.swift` (in the fork) — inside `scheduleConfigurationRetry`, the abandon branch (line 237)

**Current code (verified at line 230–241):**

```swift
let attempt = self.configurationRetryAttempts
let backoff = min(60.0, Double(2 << attempt)) // 2,4,8,16,32s, capped at 60
let work = DispatchWorkItem { [weak self] in
    guard let self else { return }
    self.queue.async {
        self.configurationRetryWorkItem = nil // clear BEFORE re-entering perform
        guard self.peripheral.state == .connected else {
            emitG7Telemetry("configure_retry_abandoned", "reason=disconnected")
            return
        }
        self.perform(block)
    }
}
```

**Target:** add `attempt`/`backoff` to the abandon line (both are captured `let` bindings — correct closure capture):

```swift
            emitG7Telemetry("configure_retry_abandoned", "reason=disconnected attempt=\(attempt) backoff_s=\(Int(backoff))")
```

**Steps:**

- [ ] **1.1** Confirm the single occurrence (in the **fork**):

  ```bash
  grep -n "configure_retry_abandoned" ~/Code/personal/health/diabetes/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift
  ```

  → exactly one hit.

- [ ] **1.2** Apply the edit above in the fork (combine with Task 2.2 — one edit, not two).
- [ ] **1.3** Commit in the fork together with Task 2 (single commit — same file/function). See Task 2 Steps 2.4–2.5.

---

## Task 2: Reset the configuration-retry budget on abandon (genuine bug)

**Priority: MEDIUM — real code defect.** When `configure_retry_abandoned reason=disconnected` fires, the work item returns **without resetting `configurationRetryAttempts`**. The budget is reset on config **success** ([line 166](../../../Trio/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift)), a **new** `CBPeripheral` instance ([line 52](../../../Trio/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift), identity-guarded), delegate swap (line 89), and **exhaustion** (line 225) — but **not** on abandon.

Per the C-208-11 comment at line 220–224, the stored-id re-attach returns the **same** `CBPeripheral` instance, so the identity-guarded `peripheral` didSet does **not** fire on a normal disconnect/reconnect. Consequence: a sensor whose connection window is too short to finish configuration climbs the backoff ladder **across reconnects**:

```
connect 1: attempt 0 → 2s backoff,  disconnect during wait → abandon (attempts now 1)
connect 2: attempt 1 → 4s backoff,  disconnect → abandon (attempts 2)
connect 3: attempt 2 → 8s backoff,  disconnect → abandon (attempts 3)
connect 4: attempt 3 → 16s backoff, ...
connect 5: attempt 4 → 32s backoff
connect 6: attempts == 5 → exhaustion → cancelPeripheralConnection + reset
```

Each successive reconnect gets a **longer** backoff, making the retry progressively **less** likely to land inside the brief connection window — the opposite of what a per-connection retry ladder should do. This is a plausible self-reinforcing contributor to elevated `configure_retry_abandoned`, present in **all** builds (so not the 213↔214 delta, but a real improvement candidate).

**Fix:** reset the budget on abandon. This is safe — the connection is already gone (so the exhaustion path's zombie-connection concern does not apply), and a fresh connection should get a fresh ladder starting at the 2s backoff most likely to fit the window. This mirrors the C-208-11 reset already applied to the exhaustion path.

> **Where to edit:** standalone fork `~/Code/personal/health/diabetes/G7SensorKit` — see [G7SensorKit fork workflow](#g7sensorkit-fork-workflow-tasks-12). Do **not** edit/commit only in `Trio/G7SensorKit`.

**Files:**
- Modify: `G7SensorKit/G7CGMManager/G7PeripheralManager.swift` (in the fork) — the abandon branch (line 236–239)

**Target code (combined with Task 1's field enrichment):**

```swift
        guard self.peripheral.state == .connected else {
            // C-215: reset the retry budget on abandon. The same stored-id CBPeripheral reconnects
            // (identity-guarded peripheral didSet never fires), so without this the backoff ladder
            // climbs ACROSS reconnects — each successive retry less likely to fit the connection
            // window. The connection is already gone, so the exhaustion zombie-hold concern is moot.
            emitG7Telemetry("configure_retry_abandoned", "reason=disconnected attempt=\(attempt) backoff_s=\(Int(backoff))")
            self.configurationRetryAttempts = 0
            return
        }
```

**Steps:**

- [ ] **2.1** Confirm current behavior (in the **fork**):

  ```bash
  grep -n "configurationRetryAttempts = 0\|configure_retry_abandoned" \
    ~/Code/personal/health/diabetes/G7SensorKit/G7SensorKit/G7CGMManager/G7PeripheralManager.swift
  ```

  Expected resets at lines 166, 225, 254 — none in the abandon branch.

- [ ] **2.2** Apply the Target code above in the fork (covers both Task 1's fields and the reset).
- [ ] **2.3** Static diff review (fork only):

  ```bash
  cd ~/Code/personal/health/diabetes/G7SensorKit
  git diff G7SensorKit/G7CGMManager/G7PeripheralManager.swift
  ```

  Confirm only the abandon branch changed.

- [ ] **2.4** Commit in the **standalone fork** (on `main`):

  ```bash
  cd ~/Code/personal/health/diabetes/G7SensorKit
  git add G7SensorKit/G7CGMManager/G7PeripheralManager.swift
  git commit -m "fix(g7): reset config-retry budget on abandon + stamp attempt/backoff_s on abandon log"
  ```

- [ ] **2.5** Re-pin patch 02 from `Trio-dev` (`repin-g7.sh` pushes the fork and pins the committed HEAD):

  ```bash
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/repin-g7.sh
  ./scripts/patch-test.sh
  ```

  Expected: patch-test PASS; patch 02 `Subproject commit` line shows the new SHA; applying the stack updates the `G7SensorKit` gitlink (no Trio feature-branch submodule commit needed). Review the patch diff; do not commit patch 02 until milestone complete (patch lifecycle).

---

## Task 2b: `command_timeout` op label (observability prerequisite)

**Priority: MEDIUM (observability — prerequisite before timeout tuning).** `command_timeout` is the most persistently elevated G7 BLE metric on build 214 (~18.5/100 connects, above the 15/100 review threshold). Today the emission site logs only `timeout_s=` — no indication of which GATT operation timed out (`discover_services`, `discover_characteristics`, `set_notify_authentication`, `set_notify_control`, etc.). Without `op=`, you cannot choose between timeout tuning, retry-budget changes, or background-skip logic.

> **Where to edit:** standalone fork `~/Code/personal/health/diabetes/G7SensorKit` — see [G7SensorKit fork workflow](#g7sensorkit-fork-workflow-tasks-12).

**Files:**
- Modify: `G7SensorKit/G7CGMManager/G7PeripheralManager.swift` (in the fork)

**Change summary:**
- `runCommand(timeout:op:command:)` takes a required `op: String`; `command_timeout` emits `op=\(op) timeout_s=\(Int(timeout))`.
- Call sites label discovery (`discover_services`, `discover_characteristics`), notify (`set_notify_authentication`, `set_notify_control`, … via `characteristicOpName`), read/write/wait paths.
- `listenToCharacteristic(.authentication)` path (via the `CGMServiceCharacteristicUUID` wrapper) emits `set_notify_authentication` on timeout.

**Steps:**

- [ ] **2b.1** Apply the `op` threading in the fork (`G7PeripheralManager.swift`):
- [ ] **2b.2** Commit in the fork (can be combined with Tasks 1–2 if not yet committed, or a separate commit if 1–2 already landed):

  ```bash
  cd ~/Code/personal/health/diabetes/G7SensorKit
  git add G7SensorKit/G7CGMManager/G7PeripheralManager.swift
  git commit -m "telemetry(g7): stamp op= on command_timeout for GATT op attribution"
  ```

- [ ] **2b.3** Re-pin patch 02 from `Trio-dev` (once all pending fork commits are on `main`):

  ```bash
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/repin-g7.sh
  ./scripts/patch-test.sh
  ```

**Do not tune timeout values until post-215 soak shows which `op=` dominates.**

---

## Task 3: Session heartbeat — session_age_s and session_dead_since_s (observability)

**Priority: MEDIUM (new observability we lack today).** There is currently no continuous signal for "how long has the session been dead, waiting for a foreground open?" — the exact blind spot behind coverage analysis. The 5-min heartbeat is the natural carrier.

**Known limitation (document, don't fix):** the heartbeat is a `DispatchSource` timer ([adapter:704](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) that is suspended while the app is suspended in the background. So `session_dead_since_s` is only emitted when the process is briefly alive (e.g., a complication refresh or a foreground open) — it gives sampled, not continuous, visibility into long no-session gaps. Still strictly more than today (nothing).

**Files:**
- Modify: `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` — `emitHeartbeat()` (line 718), `extendedRuntimeSessionDidStart` (line 1537), and the watchdog/reanchor adoption sites

**Current `emitHeartbeat()` (verified line 718–727):**

```swift
private func emitHeartbeat() {
    let extStateRaw: String
    if let s = extendedSession {
        extStateRaw = describeState(s.state)
    } else {
        extStateRaw = "nil"
    }
    let active = lastKnownExtSessionActive
    log("heartbeat", "ext_session_active=\(active) ext_session_state=\(extStateRaw)")
}
```

**Concurrency note:** the whole adapter is `@MainActor` ([line 16](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) and the heartbeat handler hops to `Task { @MainActor }` before calling `emitHeartbeat` ([line 710](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)). All property reads here are MainActor-isolated — no data race.

**Steps:**

- [ ] **3.1** Add a `sessionInvalidatedAt: Date?` property near the other session-tracking properties (around line 49, beside `sessionStartedAt`):

  ```swift
  /// Wall-clock of the most recent non-intentional session invalidation. Drives the heartbeat's
  /// session_dead_since_s. Set in didInvalidateWith (real-death path) and the reanchor-failure
  /// paths; cleared on every session-start path.
  private var sessionInvalidatedAt: Date?
  ```

- [ ] **3.2** Set it on **every** path that flips `lastKnownExtSessionActive = false` for a real death. Verified sites:
  - `extendedRuntimeSession(_:didInvalidateWith:)` — insert `sessionInvalidatedAt = Date()` **after** the `sessionPendingDidStart` guard returns (after [line 1651](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)), so a never-started pending session does not get a bogus timestamp. This single insertion covers both the `hasError` and natural-expiry branches.
  - Reanchor-failure paths that set the flag false: [line 438](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift) (`reanchor_abandoned`/left_active at start), [line 467](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift) (`reanchor_pending_timeout`), [line 1603](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift) (`reanchor_abandoned`/retry left_active), [line 1620](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift) (`reanchor_retry_rejected`/`reanchor_replacement_invalidated`). Add `sessionInvalidatedAt = Date()` (or `self.sessionInvalidatedAt = Date()` inside the `Task` closures) immediately after each `lastKnownExtSessionActive = false`.

  Find them all and verify count:
  ```bash
  grep -n "lastKnownExtSessionActive = false" "Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift"
  ```
  Expected sites: 438, 467, 1533 (willExpire — see note), 1603, 1620, 1635, 1642. Set `sessionInvalidatedAt` at 438, 467, 1603, 1620, and the post-pending-guard insertion (~1652). **Do not** set it at 1533 (willExpire: session still running, not dead), 1635 (swap teardown of OLD session — replacement is taking over, not a real gap), or before the pending guard.

- [ ] **3.3** Clear `sessionInvalidatedAt = nil` on **every** session-start path (verified the three `lastKnownExtSessionActive = true` sites):
  - `extendedRuntimeSessionDidStart` ([line 1541](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift))
  - start-timeout watchdog adoption ([line 418](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift))
  - reanchor-replacement watchdog adoption ([line 463](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift))

  ```bash
  grep -n "lastKnownExtSessionActive = true" "Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift"
  ```
  Add `sessionInvalidatedAt = nil` after each (expected: 3 sites — 418, 463, 1541).

- [ ] **3.4** Update `emitHeartbeat()` to compute and emit the two fields. Use `extendedSession?.state == .running` alongside the flag so the willExpire window (flag false, session still running) is still counted live:

  ```swift
  private func emitHeartbeat() {
      let extStateRaw: String
      if let s = extendedSession {
          extStateRaw = describeState(s.state)
      } else {
          extStateRaw = "nil"
      }
      let sessionLive = lastKnownExtSessionActive || extendedSession?.state == .running
      let ageS = sessionLive ? (trueSessionAge().map(Int.init) ?? -1) : -1
      let deadSinceS = (!sessionLive && sessionInvalidatedAt != nil)
          ? Int(Date().timeIntervalSince(sessionInvalidatedAt!))
          : -1
      log("heartbeat", "ext_session_active=\(lastKnownExtSessionActive) ext_session_state=\(extStateRaw) session_age_s=\(ageS) session_dead_since_s=\(deadSinceS)")
  }
  ```

- [ ] **3.5** Static diff review: `cd Trio && git diff "Trio Watch App Extension/G7WatchSensorAdapter.swift"`.
- [ ] **3.6** Commit + update patch 09:

  ```bash
  cd Trio
  git add "Trio Watch App Extension/G7WatchSensorAdapter.swift"
  git commit -m "telemetry(watch): add session_age_s and session_dead_since_s to heartbeat"
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>
  ./scripts/patch-test.sh
  ```

---

## Task 4: ext_session_nearing_expiry log (observability)

**Priority: LOW–MEDIUM (new observability).** Quantifies "session reached the last ~5 min of its life while the app was NOT foreground" — i.e., a reanchor window that passed unused. Telemetry-only; no UI, no notification.

**Files:**
- Modify: `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` — `emitHeartbeat()` and the session-start sites from Task 3

**Verified:** `lastKnownScenePhase == "active"` is the adapter's own string convention (set literally at [line 298](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift); compared at 143/318/437/501/1602/1669). The `!= "active"` test below is correct (it is NOT a `WKAppScenePhase` raw value).

**Steps:**

- [ ] **4.1** Add a per-session dedup flag near `sessionInvalidatedAt`:

  ```swift
  /// One-shot guard so ext_session_nearing_expiry fires at most once per session across the
  /// 5-min heartbeat ticks in the 55–60 min window. Reset on every session-start path.
  private var sessionNearExpiryLogged = false
  ```

- [ ] **4.2** Reset `sessionNearExpiryLogged = false` at the same three session-start sites as Task 3 Step 3.3 (lines 418, 463, 1541).

- [ ] **4.3** Add the check at the end of `emitHeartbeat()` (after the `log("heartbeat", …)` line). Use `extendedSession?.state == .running`, NOT `lastKnownExtSessionActive`, so it still fires after willExpire flips the flag:

  ```swift
  if !sessionNearExpiryLogged,
     extendedSession?.state == .running,
     let age = trueSessionAge(),
     age >= 55 * 60,
     lastKnownScenePhase != "active" {
      sessionNearExpiryLogged = true
      log("ext_session_nearing_expiry", "age_s=\(Int(age)) scene_phase=\(lastKnownScenePhase)")
  }
  ```

- [ ] **4.4** Commit + update patch 09:

  ```bash
  cd Trio
  git add "Trio Watch App Extension/G7WatchSensorAdapter.swift"
  git commit -m "telemetry(watch): emit ext_session_nearing_expiry once/session when >55min old in background"
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>
  ./scripts/patch-test.sh
  ```

---

## Task 5: Reduce sessionReanchorAge from 45 min to 40 min (tuning)

**Priority: LOW (tuning lever).** Widens the reanchor-eligible window from 15 min to 20 min before the ~60-min cap. **Will not move the coverage metric** (coverage is gated by app-opens, not the reanchor threshold), but it gives each session more chances to reanchor on a foreground visit before a background bg-kill. Harmless: the replacement starts a fresh ~60-min clock.

**Files:**
- Modify: `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift` — the `sessionReanchorAge` constant ([line 51](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift))

**Current:**
```swift
private static let sessionReanchorAge: TimeInterval = 45 * 60
```
**Target:**
```swift
/// Build 215: lowered 45→40 min — widens the reanchor window to 20 min vs 15 min. Coverage is
/// app-open-gated, so this only adds reanchor opportunities; the replacement starts a fresh ~1h clock.
private static let sessionReanchorAge: TimeInterval = 40 * 60
```

**Steps:**

- [ ] **5.1** `grep -n "sessionReanchorAge" "Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift"` → 2 hits (definition line 51, usage in `renewSessionIfNeeded` ~line 343).
- [ ] **5.2** Change `45 * 60` → `40 * 60` in the **definition only**.
- [ ] **5.3** Re-grep to confirm the usage site (`guard age >= Self.sessionReanchorAge`) is unchanged.
- [ ] **5.4** Commit + update patch 09:

  ```bash
  cd Trio
  git add "Trio Watch App Extension/G7WatchSensorAdapter.swift"
  git commit -m "tune(watch): reduce sessionReanchorAge 45→40 min to widen reanchor window"
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>
  ./scripts/patch-test.sh
  ```

---

## Task 6: connect_gated reason=rate_limit — documented + intentional

**Priority: CLOSED (no code change).** Resolved: the string is **not** missing from the shipped binary — it lives in the G7SensorKit fork's connect-gate (`C-210-7`), not in the Trio adapter.

**Finding (build 214 telemetry):** 13 `connect_gated reason=rate_limit` events in 85 h (~0.15/hr). Also 8 on build 211; absent on 212/213 reflects soak length / no reconnect storm, not missing code (213/214 adapter byte-identical).

**Source:** `G7BluetoothManager.swift` in the fork at patch 02 pin — throttles reconnect storms when `recentConnectIssueTimes.count >= connectGateMaxPerWindow` (8 connects per 300 s window), then schedules `connect_gate_retry`:

```swift
// C-210-7: connect-gate. Throttle reconnect STORMS ...
guard bindingState.recentConnectIssueTimes.count < Self.connectGateMaxPerWindow else {
    emitG7Telemetry(
        "connect_gated",
        "reason=rate_limit window_s=\(Int(Self.connectGateWindow)) recent_connects=\(bindingState.recentConnectIssueTimes.count) peripheral=\(peripheral.identifier.uuidString)"
    )
    scheduleGatedConnectRetry(peripheral)
    return
}
```

**Action:** None for 215. **Revisit only if** gated connects **without** a subsequent successful `connect_gate_retry` / `did_connect` correlate with EGV loss in BetterStack (same conditional the investigation task originally proposed).

**Steps:**

- [x] **6.1** Located `connect_gated` in fork `G7BluetoothManager.swift` (`C-210-7`).
- [x] **6.2** Confirmed intentional storm-throttling; 13/85 h is expected low-volume behavior.
- [x] **6.3** Documented finding inline (this task). No glossary/code change required.

---

## Task 7: Verify flush-truncation drop-accounting is in patch 09

**Priority: VERIFY.** Confirmed against the tags: the precise drop accounting (`droppedInTrunc` → `logsDropped`/`logsDroppedTotal`, `lines_dropped=` on the marker) is in **HEAD** but was **NOT in build 214** — it is genuinely a 215 item (commit `177a6c723`). Confirm patch 09 carries it.

**Steps:**

- [ ] **7.1** `grep "log_flush_truncated\|lines_dropped\|droppedInTrunc" /Users/charlie/Code/personal/health/diabetes/Trio-dev/patches/09-watch-g7.patch | head` — expect added (`+`) lines including `droppedInTrunc`.
- [ ] **7.2** If absent: `./scripts/mid-stack-update.sh --patch 09 --cherry-pick 177a6c723 && ./scripts/patch-test.sh`.
- [ ] **7.3** If present: document as verified.

---

## Task 8: Full patch validation

**When:** after all code tasks (1–2, 2b, 3–5, 7, 9, and 10) complete and all patch updates have run. Tasks 9–10 were added after initial plan review; each carries its own `patch-test`, but re-run the steps below as the final gate once they are in.

**Steps:**

- [ ] **8.1** `cd Trio-dev && ./scripts/patch-test.sh` → PASS (any safety-path FAIL is a hard stop).
- [ ] **8.2** Static review of patch 09 vs base — accidental deletions; `grep "^Files in patch:" patches/09-watch-g7.patch` count did not drop.
- [ ] **8.3** Confirm patch 02 pin: `grep "Subproject commit" patches/02-g7-reading-time-with-seconds.patch` shows the new G7SensorKit SHA.
- [ ] **8.4** (Human-requested only, per AGENTS.md rule 10) `./ci/local-build.sh --include-untracked`; monitor `build/artifacts/ci-local-build-*.log`.

---

## Expected Post-Build-215 Effects

| Change | Effect |
|--------|--------|
| Task 2 (retry-budget reset on abandon) | Each reconnect retries at the 2s backoff most likely to fit the connection window; should reduce `configure_retry_abandoned` for flaky short-window sensors |
| Task 2b (`op=` on `command_timeout`) | BetterStack can attribute timeouts to discovery vs auth-notify vs control-notify before any timeout tuning |
| Task 1 (`attempt`/`backoff_s` on abandon) | Direct ClickHouse aggregation of which tier abandons (was: correlatable via self-join) |
| Task 3 (`session_age_s`, `session_dead_since_s`) | Sampled visibility into session lifetime + no-session gap length |
| Task 4 (`ext_session_nearing_expiry`) | Count of unused reanchor windows (session aged out in background) |
| Task 5 (reanchor 40 min) | ~33% wider reanchor-eligible window per session |
| Task 7 (flush drop accounting) | Future flush-overflow drops are counted, not silent |
| Task 9a (didStart ownership guard) | A late orphaned `didStart` can no longer clobber a newer live session; reanchor/scan-gate track the correct object |
| Task 9b (reanchor deferred-scan drain) | C1-gated scans resume immediately on reanchor-watchdog adoption instead of waiting for the next foreground entry |
| Task 9c/9d (scan-flag window, name provenance) | Cleaner `pre_egv_disconnect` attribution; explicit connect-name provenance in telemetry |
| Task 10 (`os_version` on launch banner) | Every `watch_app_launch` DEPLOY line carries watchOS version for build/soak attribution (e.g. `26.5`) |

---

## Task 9: Adapter session-tracking correctness fixes (whole-file cursor review)

**Priority: MEDIUM (Finding 1 + 2 are real correctness; 5 + 6 are low/optional).** These are **pre-existing latent issues** surfaced by a whole-file review — *not* 213→214 regressions (the adapter is byte-identical across those builds). They're worth fixing because they're real, low-risk, and adapter-only (patch 09). Findings 3 (watchdog-no-invalidate) and 4 (age-reset on adoption) from the review were folded in / rejected: #3 is subsumed by the #1 guard below; #4 is a ~15s approximation (the watchdog fires a fixed 15s after `start()`), not a real bug.

**Files:**
- Modify: `Trio/Trio Watch App Extension/G7WatchSensorAdapter.swift`

> **Dependency:** Tasks 3 and 4 already add `sessionInvalidatedAt = nil` and `sessionNearExpiryLogged = false` to the reanchor-watchdog adoption site ([line 463](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)). Step 9.2 below only adds the `consumeDeferredScanIfNeeded()` call at that same site.

### 9a — Finding 1 (HIGH): add an ownership guard to `extendedRuntimeSessionDidStart`

`extendedRuntimeSessionDidStart` ([line 1537](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) assigns `extendedSession = session` unconditionally, while `didInvalidateWith` guards unowned sessions (line 1579). The 15s pending-watchdog clears `sessionPendingDidStart` **without invalidating** the orphaned session (lines 421–424), so an orphaned session A that later goes `.running` and delivers a late `didStart` clobbers a newer live session B. Since `isRuntimeEligible` and the reanchor-age logic key off `extendedSession`, the adapter would then track and reanchor the wrong object.

**Current head of the method:**

```swift
func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
    // Defensive cleanup: a started session should not be in the intentional-invalidation set,
    // but if it somehow is, remove it so the set stays bounded.
    invalidatingSessionIDs.remove(ObjectIdentifier(session))
    lastKnownExtSessionActive = true
    extendedSession = session
```

**Target — add the guard before any state mutation:**

```swift
func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
    // C-215: reject a late didStart we no longer expect when a DIFFERENT session is already live and
    // running. The pending-watchdog (line ~421) clears the pending slot WITHOUT invalidating an
    // orphaned start, so without this guard that orphan's late didStart would clobber a newer live
    // session. Tear the orphan down (mark intentional so its didInvalidate is classified clean).
    // Mirrors the ownership guard in extendedRuntimeSession(_:didInvalidateWith:).
    let isExpected = session === sessionPendingDidStart
        || session === pendingReanchorSession
        || session === extendedSession
        || extendedSession == nil
    if !isExpected, let live = extendedSession, live !== session, live.state == .running {
        invalidatingSessionIDs.insert(ObjectIdentifier(session))
        session.invalidate()
        log("ext_session_unowned_did_start", "state=\(describeState(session.state)) live_state=\(describeState(live.state))")
        return
    }
    // Defensive cleanup: a started session should not be in the intentional-invalidation set,
    // but if it somehow is, remove it so the set stays bounded.
    invalidatingSessionIDs.remove(ObjectIdentifier(session))
    lastKnownExtSessionActive = true
    extendedSession = session
```

- [ ] **9.1** Apply the guard above. Verify it sits before the `extendedSession = session` assignment and that `live !== session` prevents self-rejection of the normal adopt-current case.

### 9b — Finding 2 (MEDIUM): drain deferred scan on reanchor-watchdog adoption

The normal start-timeout watchdog ([line 420](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) and `didStart` (line 1562) both call `consumeDeferredScanIfNeeded()` on adoption; the reanchor watchdog ([lines 460–465](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) does not. A C1-gated deferred scan then stays gated until the next foreground entry even though the replacement is now `.running` (a runtime-eligible transition).

- [ ] **9.2** In `startReanchorPendingWatchdog`'s `if session.state == .running` adoption branch (after the `reanchor_replacement_started` log at line 465), add:

  ```swift
  self.consumeDeferredScanIfNeeded() // C-215: C1 parity with didStart + the normal start-timeout watchdog
  ```

### 9c — Finding 5 (LOW, optional): scan-flag auto-clear vs slow disconnect

`performScanForNewSensor` ([lines 1011–1019](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) sets `isScanningForNewSensor = true` with a fixed **2s** auto-clear. If `bluetoothManager.disconnect()` takes >2s, the flag clears before the disconnect callback at [line 1213](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift), so `initiatedScan == false` and a self-inflicted rescan is mis-counted as a pre-EGV disconnect — slightly **inflating** the `pre_egv_disconnect` metric.

> **Tradeoff:** the 2s timer also exists to clear the flag when *no* disconnect follows (we weren't connected when the rescan was requested). Don't simply delete it.

- [ ] **9.3** (Optional) Either (a) lengthen the auto-clear to a safer bound (e.g. 5s) as a cheap mitigation, or (b) leave the 2s timer as a backstop but ALSO clear the flag at the start of the disconnect handler, whichever the disconnect-timing telemetry supports. If deferring, add a one-line comment at line 1016 noting the known race. Decide based on observed `disconnect()` latency; default to (a) if unsure.

### 9d — Finding 6 (LOW, telemetry cosmetic): first-discovery bind logs expected, not peripheral, name

On the first-discovery path, `recordSessionConnect(name: expected, source: "first_discovery_path")` ([line 1294](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) sets `boundSensorName` to `expectedSensorName`. The actual discovered peripheral name is not available here (a `G7GlucoseMessage` doesn't carry it), and binding is suffix-gated — so functionally correct, but `boundSensorName` / connect telemetry can disagree with the full peripheral name when full names differ. The `source=first_discovery_path` field on the `did_connect` line already disambiguates *which* path bound the name; make the provenance explicit so log readers don't treat it as peripheral-confirmed.

- [ ] **9.4** In `recordSessionConnect` ([line 1156](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)), add a `name_provenance` field to the `did_connect` log that distinguishes peripheral-confirmed binds from expected-derived ones. Minimal approach — derive it from the existing `source` argument (no new parameter needed):

  ```swift
  let nameProvenance = (source == "first_discovery_path") ? "expected" : "peripheral"
  log(
      "did_connect",
      "scene_phase=\(lastKnownScenePhase) ext_session_active=\(lastKnownExtSessionActive) source=\(source) name_provenance=\(nameProvenance)"
  )
  ```

### Commit + patch update

- [ ] **9.5** Static diff review: `cd Trio && git diff "Trio Watch App Extension/G7WatchSensorAdapter.swift"`.
- [ ] **9.6** Commit + update patch 09:

  ```bash
  cd Trio
  git add "Trio Watch App Extension/G7WatchSensorAdapter.swift"
  git commit -m "fix(watch): didStart ownership guard + reanchor deferred-scan drain + connect-name provenance"
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>
  ./scripts/patch-test.sh
  ```

- [ ] **9.7** Re-run Task 8's full validation as the final gate (after Task 10 if not yet done).

---

## Task 10: `os_version` on watch launch DEPLOY banner

**Priority: LOW (telemetry attribution).** The `[DEPLOY] event=watch_app_launch` sentinel already stamps `platform=watchos` and `build=`; add `os_version=` so BetterStack soaks can segment by watchOS release without inferring from sparse device metadata.

**Files:**
- Modify: `Trio/Trio Watch App Extension/TrioWatchApp.swift` — `TrioWatchApp.init()` DEPLOY `Task` ([line 11–14](../../../Trio/Trio%20Watch%20App%20Extension/TrioWatchApp.swift)). (`@WKApplicationDelegateAdaptor(ExtensionDelegate.self)` is on the same struct; the banner is emitted here, not from `ExtensionDelegate`.)

**Current (verified line 11–14):**

```swift
        Task {
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            await WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build)")
        }
```

**Target:**

```swift
        Task {
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let osVersion = WKInterfaceDevice.current().systemVersion
            await WatchLogger.shared.log("[DEPLOY] event=watch_app_launch platform=watchos build=\(build) os_version=\(osVersion)")
        }
```

`WatchKit` is already imported ([line 3](../../../Trio/Trio%20Watch%20App%20Extension/TrioWatchApp.swift)); no new imports.

**Steps:**

- [ ] **10.1** `grep -n "watch_app_launch" "Trio/Trio Watch App Extension/TrioWatchApp.swift"` → exactly one hit (line 13).
- [ ] **10.2** Apply the Target edit above.
- [ ] **10.3** Static diff review: `cd Trio && git diff "Trio Watch App Extension/TrioWatchApp.swift"` — only the DEPLOY line and `osVersion` local change.
- [ ] **10.4** Commit + update patch 09:

  ```bash
  cd Trio
  git add "Trio Watch App Extension/TrioWatchApp.swift"
  git commit -m "telemetry(watch): add os_version to watch_app_launch DEPLOY banner"
  cd /Users/charlie/Code/personal/health/diabetes/Trio-dev
  ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>
  ./scripts/patch-test.sh
  ```

  May be folded into another patch-09 commit if convenient; if so, still verify the banner line in the final patch diff.

- [ ] **10.5** Re-run Task 8's full validation as the final gate.

---

## Dropped from this plan

- **willExpire flag-flip "fix" (prior Task 8) — DROPPED.** Three independent reasons: (1) the plan's "current code" was hallucinated — the real `extendedRuntimeSessionWillExpire` ([line 1530](../../../Trio/Trio%20Watch%20App%20Extension/G7WatchSensorAdapter.swift)) is a guarded one-liner, not a `Task`-wrapped block calling `recoverSessionAfterFailedReanchor`; (2) the willExpire code is **identical in builds 213 and 214**, so it cannot cause a 213→214 regression; (3) `lastKnownExtSessionActive` is **pure telemetry** — every read is a log interpolation or the debug-UI accessor; nothing gates behavior on it (gating uses `extendedSession?.state == .running`). History runs the opposite way: build 212 flipped it unconditionally; v2 (213/214) narrowed it to the current session — already an attribution improvement.

## Out of Scope for Build 215

- **Reduce configure_retry first backoff (2s→0.5s):** revisit after Task 1/2 telemetry shows the post-fix abandon distribution.
- **Continuous (non-sampled) no-session gap tracking:** would require background-budget work; the heartbeat sampling in Task 3 is the pragmatic first step.
- **Reanchor age < 40 min:** churns sessions with 20+ min remaining.
- **UI/notification near-expiry nudge:** alarm-fatigue risk for a glucose app.
- **Platform attribution on shared fork events:** revisit if BetterStack shows cross-platform event mixing (`JSONExtract(raw,'platform',…)`).

---

## Changelog

### v1.4 (2026-06-26 CET)
- Added **Task 2b** — `command_timeout` `op=` label in `G7PeripheralManager.runCommand` (observability prerequisite before timeout tuning).
- **Task 6 closed** — `connect_gated reason=rate_limit` is intentional `C-210-7` connect-gate throttling in fork `G7BluetoothManager.swift`, not a missing-binary mystery. Revisit only if gated connects without successful retry correlate with EGV loss.

### v1.3 (2026-06-26 06:47 CET)
- Removed Step 2.6 (manual Trio `G7SensorKit` gitlink bump). The gitlink is advanced when patch 02 is applied during `patch-test.sh` / build — not via a separate feature-branch commit. Reason: user correction; v1.2 implied an extra step that does not match the actual build workflow.

### v1.2 (2026-06-26 06:43 CET)
- Clarified **G7SensorKit fork-first workflow** for Tasks 1–2: edit/commit in `~/Code/personal/health/diabetes/G7SensorKit` (`main`), not `Trio/G7SensorKit`; `repin-g7.sh` pushes and re-pins patch 02. Added dedicated workflow section, table "Where to edit" column, Task 1/2 callouts, and reordered Steps 2.4–2.6. Reason: agents were misreading "commit in the submodule" as the Trio worktree checkout.

### v1.1 (2026-06-25 13:27 CET)
- Added **Task 10** — stamp `os_version=\(WKInterfaceDevice.current().systemVersion)` on the `[DEPLOY] event=watch_app_launch` line in `TrioWatchApp.init()`. Reason: segment build/soak telemetry by watchOS release without inferring OS from device metadata.

### v1 (2026-06-24 CET)
- Initial build 215 implementation plan (Tasks 1–9, investigation Tasks 6–7, validation Task 8).
