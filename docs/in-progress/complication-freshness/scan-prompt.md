# Complication-freshness code-scan prompts (for codex / cursor)

**Created:** 2026-06-16 · **Status:** Uncommitted tooling — reusable scan prompts.

Two prompts for an external coding agent (codex/cursor). **Two-worktree setup:** read the reference
docs in the **`Trio-dev`** worktree (`/Users/charlie/Code/personal/health/diabetes/Trio-dev/`); do the
**code** investigation in the **`Trio`** worktree (`/Users/charlie/Code/personal/health/diabetes/Trio/`)
on the **`feature/watch-g7`** branch (the merged 09+12 watch stack, already checked out there).
**Prompt A** is a broad complication-freshness audit; **Prompt B** narrows to the concurrency/race seam
(usually the richest in this multi-queue code). Run them as separate passes — fresh context each,
read-only.

Both assume the agent first reads `docs/in-progress/complication-freshness/` (esp.
`problem-and-strategy.md` §Backlog, `key-file-reference.md`) and `docs/in-progress/trio-fable5-review.md`
so it doesn't re-report shipped work (builds 131–144 R1–R6 + 4G–4I; build 209 C-209-6/7/8).

---

## Prompt A — broad complication-freshness audit

> **Task: audit the watchOS complication-freshness code paths for bugs and improvements.**
>
> You are reviewing **Trio**, an open-source iOS/watchOS automated-insulin-delivery app. The Apple
> Watch **complication** displays the user's latest CGM glucose. Keeping that reading **fresh** is hard
> because watchOS aggressively throttles background updates and WidgetKit reloads. This is a
> **medical-safety** context: a stale or wrong glucose on the watch face can mislead a real person —
> correctness and freshness matter more than style.
>
> **Do this first (so you don't re-report already-fixed work):** in the **`Trio-dev`** worktree
> (`/Users/charlie/Code/personal/health/diabetes/Trio-dev/`), read
> `docs/in-progress/complication-freshness/` (esp. `problem-and-strategy.md` §Backlog v1.8,
> `key-file-reference.md`) and `docs/in-progress/trio-fable5-review.md`. Builds 131–144 already shipped a
> large remediation (R1–R6, observability 4G–4I), and build 209 shipped complication fixes C-209-6/7/8
> (mmol/locale `sanitizedGlucose`, an unserviced-reload detector, store hygiene). **Do not re-report
> shipped items.** Look for *new* bugs and *unaddressed* improvements.
>
> **Do the code investigation in the `Trio` worktree**
> (`/Users/charlie/Code/personal/health/diabetes/Trio/`) on the **`full-patch-stack`** branch (already
> checked out there) — that's where the applied watch-extension + phone source lives.
>
> **Architecture — the complication is fed by multiple channels, all funneling into one store:**
> - **Phone → watch (WCSession):** `AppleWatchManager.swift` — `scheduleWatchStateUpdate` →
>   `sendDataToWatch` → `watchStateToDictionary`, sent via `sendMessage` (reachable), `transferUserInfo`
>   (queued), and `updateApplicationContext` (latest-wins safety net). Budget-limited.
> - **Watch receive:** `Trio Watch App Extension/WatchState.swift` — `didReceiveMessage` /
>   `didReceiveUserInfo` / `didReceiveApplicationContext` → `processRawDataForWatchState` →
>   `saveComplicationSnapshot`. `lastDataReceivedAt` (App-Group-backed) drives sleep-gap recovery.
> - **HealthKit background delivery** on the watch (independent of WCSession).
> - **Direct G7 BLE observer** on the watch: `G7WatchSensorAdapter.swift` (newest source).
> - **Dedup/arbitration (authoritative):** `Trio Watch Shared/TrioComplicationDataStore.swift` — `save`
>   → `saveOnMain` → `shouldUpdate` (newer-wins >1s; within ±1s first-writer-wins unless content
>   differs; monotonic via `lastValidTimestamp`; source-priority BLE > WC > HealthKit).
> - **WidgetKit render:** `Trio Watch Complication/TrioWatchComplication.swift` —
>   `getTimeline`/`getSnapshot` read **only** the App Group; reloads via `WidgetCenter.reloadTimelines`
>   (coalesced/debounced on the watch).
> - Support: `WatchLogger.swift`, `ComplicationLogBuffer.swift`, `WatchGlucoseHistoryStore.swift`,
>   `ExtensionDelegate.swift`.
>
> **Hunt specifically for:**
> 1. **Concurrency / data races** — shared mutable state touched from the BLE serial queue, WCSession
>    delegate queue, HealthKit observer queue, and MainActor (unsynchronized access, main-thread
>    assumptions, reentrancy).
> 2. **Freshness loss** — any path where a *fresher* reading is dropped or a *staler* one shown:
>    `shouldUpdate` ±1s tie-break edge cases, the monotonic `lastValidTimestamp` guard rejecting a
>    legitimately newer reading, source-priority clobbering, transient trend/delta regression
>    (`""`/nil overwriting a real value).
> 3. **Clock / epoch correctness** — wall-clock `Date()` substituted for nil CGM reading time,
>    timezone/DST, reading-epoch consistency across channels, day-boundary handling.
> 4. **Reload reliability** — coalescing/debounce dropping a *needed* reload; the known blind spot where
>    `WidgetCenter.reloadTimelines()` dispatches but `getTimeline` is never called (~45% in a past
>    sample) — anything that worsens it or could detect it.
> 5. **Lifecycle / persistence** — App-Group read/write races, cold-start / state-restoration ordering,
>    the `.bak` save path, queue drain on launch.
> 6. **Edge cases** — mmol vs mg/dL & locale, missing trend/delta, sensor warmup / `sessionEnded` /
>    `sensorFailed`, backfill, budget exhaustion behavior.
>
> **Output:** a **prioritized list** of findings. For each: short title; severity **P0–P3** (P0 = could
> show wrong/dangerously-stale glucose); exact `file:line` (verify against the current tree — reference
> line numbers drift); what's wrong; why it matters for freshness/safety; evidence or a repro reasoning
> chain; a proposed fix; and a **confidence** level. Put speculative *improvement ideas* (not bugs) in a
> separate section. **Read-only — do not modify code.** Prefer a few high-confidence, verified findings
> over a long list of maybes; explicitly note uncertainty.

---

## Prompt B — concurrency / data-race deep pass

> **Task: find data races, deadlocks, and thread-safety bugs in Trio's watchOS complication code.**
>
> You are reviewing **Trio** (open-source iOS/watchOS insulin-delivery app). Focus **only** on
> concurrency correctness in the watch complication data path — a **medical-safety** path where a race
> can drop a fresh glucose reading or display a stale/wrong one. The project builds in **Swift 6
> language mode** (data-race safety enforced), so also scrutinize the escape hatches used to satisfy it.
>
> **Worktrees:** read the docs below in the **`Trio-dev`** worktree
> (`/Users/charlie/Code/personal/health/diabetes/Trio-dev/`); do the **code** investigation in the
> **`Trio`** worktree (`/Users/charlie/Code/personal/health/diabetes/Trio/`) on the
> **`full-patch-stack`** branch (already checked out there).
>
> **Read first:** `docs/in-progress/complication-freshness/key-file-reference.md` and
> `docs/in-progress/trio-fable5-review.md` (the BLE/threading review). Don't re-report fixes already
> shipped in builds 143/144/209.
>
> **The code runs across several concurrency domains that all converge on one store. Map them, then
> find where they collide:**
> - **MainActor** — `TrioComplicationDataStore` is main-thread-confined (`assert(Thread.isMainThread)`
>   throughout); `saveOnMain` is the gate.
> - **BLE serial queue** — `G7WatchSensorAdapter` / the G7 observer dispatch; produces snapshots that
>   hop to main.
> - **WCSession delegate queue** — `didReceiveMessage` / `didReceiveUserInfo` /
>   `didReceiveApplicationContext` in `Trio Watch App Extension/WatchState.swift`.
> - **HealthKit observer queue** — background delivery callbacks (anchored query, anchor persistence).
> - **WidgetKit process** — a *separate process*; `getTimeline`/`getSnapshot` in
>   `TrioWatchComplication.swift` read the **App Group** with no shared in-memory state.
> - **App Group (`UserDefaults`/files)** — cross-process shared storage written by the watch app
>   process and read by the WidgetKit process; `lastDataReceivedAt`, `lastValidTimestamp`, snapshot +
>   `.bak`.
>
> **Look specifically for:**
> 1. **Shared mutable state without synchronization** — fields read/written from more than one of the
>    queues above (the store, `lastDataReceivedAt`, HK anchors, fingerprints, dedup state, any cached
>    "last snapshot"). Confirm every access is either MainActor-hopped or lock-guarded; flag any that
>    isn't.
> 2. **Main-thread assumptions that can be violated** — code asserting/assuming main but reachable from
>    a delegate/observer/BLE callback; `assert` (compiled out in release) standing in for a real hop.
> 3. **Cross-process races on the App Group** — non-atomic read-modify-write between the watch-app and
>    WidgetKit processes; a reload firing while a write is half-done; `.bak`/primary write ordering;
>    torn reads of the snapshot.
> 4. **async/await + locks (Swift 6)** — a non-recursive lock held across an `await` suspension; actor
>    reentrancy; `Task {}` capturing mutable state; ordering assumptions broken by suspension points.
> 5. **Swift 6 escape hatches** — `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`,
>    force-unwraps after a hop — audit each for an actual race behind the suppression.
> 6. **Reentrancy / ordering** — the R5d "gap → save → timestamp-update → forced-reload" sequence and
>    the `shouldUpdate` dedup: can two channels interleave to reverse order, double-save, or skip a
>    needed reload? Can a save and a reload race such that the reload reads pre-save state?
> 7. **Timer/debounce closures** — coalescer/debounce/retry work items dispatched to a queue that may
>    differ from where their captured state lives; a stale closure firing after the relevant object
>    changed.
>
> **Output:** prioritized findings. For each: title; severity **P0–P3** (P0 = a race that can corrupt or
> drop the displayed glucose); exact `file:line` (verify in the tree); the **specific interleaving** that
> triggers it (which two queues/threads, in what order); why current synchronization doesn't prevent it;
> a proposed fix (MainActor hop, lock, atomic write, ordering change); and a **confidence** level. A real
> interleaving you can name beats a vague "this looks unsafe." **Read-only.** Flag uncertainty
> explicitly; prefer verified races over speculation.
