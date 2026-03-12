---
name: Complication Freshness Remediation
overview: Implement the complication freshness remediation plan (R1-R5) from the implementation guide in 7 sequential steps, each producing a patch, with build/deploy gates between steps.
todos:
  - id: step1
    content: "Step 1: R1a + R1b + R5e — Reading epoch keys, queue drain, BetterStack alert"
    status: completed
  - id: step2
    content: "Step 2: R2a + R3 — Coalescer attribution + complication payload allowlist"
    status: completed
  - id: step3
    content: "Step 3: R2b — Per-reading-epoch dispatch gate"
    status: completed
  - id: step3b
    content: "Step 3b: Complication-age stale-first budget gate (T=600s)"
    status: pending
  - id: step4
    content: "Step 4: R2d — Source-eligible send mode (conditional on Step 3 data: only if avg C > 1.3)"
    status: pending
  - id: step5
    content: "Step 5: R4 — App Group safety net (applicationContext)"
    status: pending
  - id: step6
    content: "Step 6: R5 — Observability hardening (R5b, R5c, R5d, R5f)"
    status: pending
isProject: false
---

# Complication Freshness Remediation — Implementation Plan

Based on [complication-freshness-implementation-guide.md](docs/complication-freshness-implementation-guide.md) Part 2, referencing [complication-freshness-remediation-plan.md](docs/complication-freshness-remediation-plan.md) v1.23 for full pseudocode.

**Worktree layout:**

- **Trio-dev** (on `dev`) — patch tooling, build scripts, patch generation
- **Trio** (on `feature/watch-complication-improvements`) — code changes

**Per-step workflow (repeat for each step):**

1. **Code** in the **Trio** worktree on `feature/watch-complication-improvements` — commit normally
2. **Update patch 09** from the **Trio-dev** worktree (must be on `dev`):

```
   ./scripts/mid-stack-update.sh --patch 09 --cherry-pick <sha>[,<sha>,...] \
       --feature-branch feature/watch-complication-improvements
   

```

   The script handles: stash, baseline creation (patches 01-08), cherry-pick, squash, `generate-patch.sh` with `--include-files` against the baseline, `patch-test.sh` validation, drift check, and cleanup. It does NOT commit the updated patch.
3. **Review** the regenerated `patches/09-watch-complication-improvements.patch` diff
4. **Build** from Trio-dev on `dev`: `ci/local-build.sh --base-branch dev --build-only`

Stash safety: `mid-stack-update.sh` runs `git stash -u` internally and pops on exit. If Trio-dev has untracked docs, they are preserved.

---

## Step 1 — R1a + R1b + R5e: Reading Epoch, Queue Drain, BetterStack Alert

**Files modified:**

- [Trio/Sources/Models/WatchMessageKeys.swift](Trio/Sources/Models/WatchMessageKeys.swift) (2 new keys)
- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift) (new properties, helpers, call sites)
- BetterStack alert config (manual, via MCP or UI)

**Changes:**

- **R1a** — Add `readingEpoch` and `transferEnqueuedAt` keys to `WatchMessageKeys.swift`. In `watchStateToDictionary` (line ~474): add `readingEpoch` using `state.glucoseValues.max(by: { $0.date < $1.date })?.date.timeIntervalSince1970` (not `.first`). In `sendDataToWatch` (line ~545): stamp `transferEnqueuedAt = Date().timeIntervalSince1970` before transfer calls.
- **R1b** — Add to `AppleWatchManager.swift`:
  - New properties: `hasPerformedStartupQueueDrain: Bool = false`, `lastQueueDeepDrainAt: TimeInterval = 0`
  - New helpers: `sessionIsReadyForTransfer() -> Bool` and `cancelStaleQueuedTransfers()` (keep newest transfer within latest epoch, cancel rest)
  - Call sites: (1) `session(_:activationDidCompleteWith:)` one-time drain, (2) `sendDataToWatch` budget-exhausted branch before `transferUserInfo`, (3) queue-deep path with cooldown
- **R5e** — BetterStack alert: `budget_exhausted=true AND via=userInfo > 5 in 30 min`

**Gate:** Code review, build/deploy, observe 24h BetterStack data, confirm `queue_depth` p95 < 5.

---

## Step 2 — R2a + R3: Coalescer Attribution + Complication Payload Allowlist

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift)
- [Trio/Sources/Models/WatchMessageKeys.swift](Trio/Sources/Models/WatchMessageKeys.swift) (inline comment on `date` key)
- [Trio Watch App Extension/WatchState.swift](Trio%20Watch%20App%20Extension/WatchState.swift) (R3 watch-side changes)

**Changes:**

- **R2a** — Modify `scheduleWatchStateUpdate` (line ~517) to accept `source: String = "unknown"` parameter. Add properties: `coalescerTriggerCount`, `coalescerSources`, `lastEligibleSourceAt`, `complicationEligibleSources` (all defined now for compilation). Update all 8 call sites with source tags. Snapshot state before clearing in work item, pass to `sendDataToWatch`.
- **R3** — Build `complicationMessage` unconditionally at top of `sendDataToWatch` via explicit `if let` inserts. Gate complication transfers with `readingEpochPresent` flag (not `guard...return`). `sendMessage` always fires with `fullMessage`. Add inline comment on `WatchMessageKeys.date`: "BUILD TIME, not CGM reading time."

**Gate:** Code review, build/deploy, collect 24h coalescer attribution data from `coalescer_fired sources=` logs.

---

## Step 3 — R2b: Per-Reading-Epoch Dispatch Gate

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift)

**Changes:**

- Add `lastDispatchedGateKey` backed by App Group `UserDefaults`
- Gate key = `"\(epoch)|\(currentGlucose)|\(trend)|\(delta)"` using `max(by: date)` for epoch
- Gate skips complication transfer only — `sendMessage` always fires
- Log `complication_transfer_gate_skipped` for duplicates
- BetterStack validation: filter `transfer_path IN ('complication', 'userInfo')`

**Gate:** Code review, build/deploy, observe 48h BetterStack data. If avg C <= 1.3: skip Step 4, go to Step 5. If avg C > 1.3: proceed to Step 4.

---

## Step 3b — Complication-age stale-first budget gate

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift)

**Changes:**

- Add `private func currentComplicationAgeSeconds() -> TimeInterval`: same 4-step pattern as remediation plan (guard suiteName/defaults → .infinity; let lastValid; if lastValid == nil return .infinity; return max(0, Date().timeIntervalSince(lastValid!))). No Watch Shared import.
- Add `private static let complicationAgeGateThresholdSeconds: TimeInterval = 600`.
- In `sendDataToWatch`, after building `complicationMessage` and `gateKey`, compute `complicationAgeSeconds` and `ageGatePassed`. **Explicit branching:** Under `!isReachable && readingEpochPresent && !isDuplicateDispatch`: if `remaining > 0` then apply age gate (if `ageGatePassed` → transferCurrentComplicationUserInfo; else → log age-gate skip); **else** (budget exhausted) → cancelStaleQueuedTransfers + transferUserInfo (no age gate). Do not gate `sendMessage` or the userInfo fallback.
- **lastDispatchedGateKey rule:** `lastDispatchedGateKey` is ONLY set when a complication transfer is actually enqueued (after `transferCurrentComplicationUserInfo` OR after `transferUserInfo` fallback). Do NOT set it on sendMessage-only paths. Do NOT set it when the age gate fails. Do not reintroduce the Step 3 foreground→background suppression bug.
- **Skip-log taxonomy:** Three queryable categories: `skip_reason=age_gate` (Step 3b), `skip_reason=duplicate_gate` (R2b), missing readingEpoch.
- **Logging:** On transfer: include `complication_age_seconds`, `complication_age_gate_threshold_seconds`. When skipped due to fresh complication: `complication_transfer_age_gate_skipped skip_reason=age_gate age_seconds=... threshold_seconds=600 gate_key=...`.

**Acceptance criteria:**

- Transfers occur only when `complication_age_seconds` > 600 and other gates pass.
- When complication is fresh (age ≤ 600s), log shows `complication_transfer_age_gate_skipped` and no complication budget is consumed.
- `sendMessage` and budget-exhausted `transferUserInfo` behavior unchanged.

**Gate:** Code review, build/deploy, observe 48h — budget no longer drains in first 2–3h after reset; age gate applies ONLY to transferCurrentComplicationUserInfo (not sendMessage, not userInfo fallback); `complication_transfer_age_gate_skipped` present when appropriate.

---

## Step 4 — R2d: Source-Eligible Send Mode (conditional on Step 3 data)

**Only implement if avg C > 1.3 after Step 3.**

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift)

**Changes:**

- Add `WatchSendMode` enum: `.complicationAndUI` / `.uiOnly`
- Mode selection based on `eligibleThisWindow = lastEligibleSourceAt >= windowStartEpoch`
- Three-way fallback log split: `eligible_source_window_nil_fallback`, `eligible_source_clock_skew`, `eligible_source_epoch_inversion`
- Use `sessionIsReadyForTransfer()` in transfer guard
- Log `complication_transfer_attempted` and `transfer_path`
- `complicationEligibleSources` and `lastEligibleSourceAt` already defined in Step 2

**Gate:** Manual verification of two test cases (simulator/device), code review, build/deploy, observe 48h — confirm avg C/reading <= 1.3.

---

## Step 5 — R4: App Group Safety Net (applicationContext)

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift) (iOS side)
- [Trio Watch App Extension/WatchState.swift](Trio%20Watch%20App%20Extension/WatchState.swift) (watch side — new delegate method)

**Changes:**

- **iOS side** — At END of `sendDataToWatch`, after all transfer and `sendMessage` calls: call `session.updateApplicationContext(complicationMessage)` when `budgetExhausted || queueDepth > 5`. Guard with `sessionIsReadyForTransfer()`. Log `context_attempted`, `context_succeeded`, `context_failed`, `context_skipped`.
- **Watch side** — Add `session(_:didReceiveApplicationContext:)` after `sessionReachabilityDidChange` (~line 405). Three-constraint ordering: compute gap before save, save snapshot, update `lastDataReceivedAt`, then `forceWidgetReloadIfStale(receivedGap:)` if gap > 600.

**Gate:** Code review, build/deploy, validate during budget exhaustion window: `save_age` p90 < 300s.

---

## Step 6 — R5: Observability Hardening (parallel-safe after Step 1)

**Files modified:**

- [Trio/Sources/Services/WatchManager/AppleWatchManager.swift](Trio/Sources/Services/WatchManager/AppleWatchManager.swift) (R5b: sendMessage wall-clock)
- [Trio Watch App Extension/WatchState.swift](Trio%20Watch%20App%20Extension/WatchState.swift) (R5c: decode_ms, R5d: sleep-gap forced reload)
- [Trio Watch Complication/TrioWatchComplication.swift](Trio%20Watch%20Complication/TrioWatchComplication.swift) (R5f: timeline validation)

**Changes:**

- **R5b** — Add `sendMessage` wall-clock timestamp on iOS send
- **R5c** — Add `decode_ms` to `didReceiveUserInfo` (receive to saveComplicationSnapshot return)
- **R5d** — Rename `lastUserInfoReceivedAt` (line 102) to `lastDataReceivedAt`; persist to App Group `UserDefaults`. Implement `forceWidgetReloadIfStale(receivedGap:)` with 5-min rate limiter, diagnostic snapshot read, gap-relative stale detection. Use `TrioComplicationDataStore.complicationKind` (line 145) for reload. Update both `didReceiveUserInfo` and the new `didReceiveApplicationContext` (from Step 5).
- **R5f** — Add `timeline_built` logging in `getTimeline` (line ~152) of `TrioWatchComplication.swift`

**Gate:** Code review, build/deploy, confirm in BetterStack: `timeline_built snapshot_age` p90 < 600s after sleep gaps.

---

## Patch Strategy

All steps update the same patch: `patches/09-watch-complication-improvements.patch` (last in the 9-patch stack). Each step adds commits to `feature/watch-complication-improvements` in the Trio worktree, then uses `mid-stack-update.sh --patch 09` from Trio-dev on `dev` to regenerate the patch. The script creates a temporary baseline from patches 01-08, diffs against it, validates the full stack with `patch-test.sh`, and cleans up tmp branches. Do not commit the updated patch file until explicitly asked.

## Execution Protocol

I will ask for confirmation before beginning each step. Between steps, the guide requires build/deploy/observe gates — I will pause and ask to proceed after each.
