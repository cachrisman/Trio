# Build 213 — `ext_session_started` Logging Gap: Investigation

**Version:** 7. **Status: ROOT-CAUSED + FIXED** (fix committed `2066f6479` on `feature/watch-g7`, patch-09; shipped in **build 214**. A related ship-side path fixed `177a6c723`, folded into patch-09 + patch-tested, **queued for build 215** with the next feature set — not yet built. Cloud-logging review: verified, nothing to fix, one ≈never-fires item deferred — see below).
- rev 1–2: ring-eviction hypothesis added then refuted (`ring_dropped=0`); "emitted"→"enqueued".
- rev 3: settled-window `missing=0`/1026 → "(b) lag, no drops." Premature.
- rev 4: 75-min recheck still absent → reclassified to "(a) post-drain *shipping* loss." **Also wrong.**
- rev 5: **the raw on-device watch log was pulled — it has the *identical* gap.** So the loss is **on-device, inside `WatchLogger`, not in shipping.** Conclusion corrected; hardening + instrumentation built.

> Author note: the conclusion moved four times (unevidenced "dropped" → "lag" → "shipping loss" → "on-device WatchLogger loss"). Each step was evidence-driven, but the load-bearing evidence — the raw on-device log — should have been requested first. Lesson logged.

## The question
Heartbeat `ext_session_state` flips `nil`→`running` (a `WKExtendedRuntimeSession` went live) with **no `ext_session_started`** in BetterStack near it (observed `nil` @ 13:20:46 CEST → `running` @ 13:39:20). Code bug, telemetry loss, or ingestion artifact?

## Method
- **Code audit** of every site that turns a session "on."
- **`seq` analysis.** `WatchTelemetryRing` stamps each line with a process-monotonic `seq` **at enqueue** (`WatchTelemetryRing.swift:80`). **`seq` resets per process** (one OS process at a time; relaunch → `seq=1`), so the same `seq` value recurs across processes — analyses must stay within one process. The ring is bounded (512) drop-oldest and **annotates its own evictions** (`ring_dropped_total`, `:13–16`).
- **Raw on-device log cross-check.** The decisive step: compare BetterStack against the watch's own `watch_log_daily.txt` (WatchLogger's persisted drain output). A line absent from *both* was lost on-device; a line present in the file but not BetterStack would be a shipping loss.

## Code evidence (`G7WatchSensorAdapter.swift`) — unchanged from rev 4
`lastKnownExtSessionActive = true` / `extendedSession = <running>` happen at exactly three sites, each logging a start-class event:

| path | log | emits `ext_session_started`? |
|---|---|---|
| `extendedRuntimeSessionDidStart` (`:1541`) | `ext_session_started` | yes |
| 15s pending-start **watchdog adopt** (`didStart` withheld, `:418`) | `ext_session_start_timeout` | **no** |
| re-anchor **watchdog adopt** (`:461`) | `reanchor_replacement_started` | **no** |

**C1 — PROVEN.** No path turns a session on without a start-class log.
**C2 — PROVEN.** `ext_session_started` is **not** emitted on either watchdog-adopt path. So it undercounts whenever watchOS withholds `didStart`. Use `{ext_session_started, ext_session_start_timeout, reanchor_replacement_started}` or heartbeat `ext_session_state`.

## Telemetry evidence (the 13:38 CEST session; process launched ~11:10 CEST)
BetterStack: seq 977–1052 continuous (`active=false`), **1053–1062 absent**, 1063+ continuous (`active=true`); flag flips false(1052)→true(1063); by C1 a start-class log sits in the missing 1053–1062. Settled neighbors and 1026 other seqs all present; 1053–1062 still absent at >75 min. (My rev-3/4 confusion: `seq` resets per process, so the raw log's seq 1053–1062 at *10:44* is a **different** process — the 13:38 session is a *different instance of the same seq numbers*.)

## DECISIVE evidence — the raw on-device log (`watch_log.txt`, 11,293 lines)
For the 13:38 process, the on-device file goes **seq 1052 (line 8165, 13:35:48, `active=false`) → seq 1063 (line 8236, 13:38:36, `active=true`)** — **1053–1062 absent from the file too** — and there are **zero `ring_dropped` annotations in the entire file.**

So the lost lines never reached *either* WatchLogger output (local file **or** BetterStack). The loss is **on-device, upstream of both** — **not a shipping/network problem** (refuting rev 4).

## Cause — resolved
| hypothesis | verdict | basis |
|---|---|---|
| (c) ring eviction | REFUTED | `ring_dropped=0` file-wide; FIFO drain + seq 1063 dequeued un-annotated ⇒ 1053–1062 dequeued, not evicted |
| (d/e) process death, undrained ring | REFUTED | `seq` continuous 1052→1063 → same process |
| (a) shipping/network loss | **REFUTED** | the **on-device file** also lacks them |
| **(W) loss inside `WatchLogger`, after the ring, before both outputs, *silent*** | **CONFIRMED** | dequeued (FIFO) → `WatchLogger.shared.log()` (`WatchTelemetryRing:124`) → appended to both `logs` and `dailyLogBuffer` (no filter) → absent from both outputs, with no accounting |

**The two silent-loss paths in `WatchLogger` (pre-fix):**
1. **File:** `drainDailyLogBuffer` cleared the buffer **before** writing (`removeAll` then `appendToDailyLog`), and `appendToDailyLog` swallowed **every** file error with `try?` → a failed batch write silently lost the batch. (A nearby fallback also `data.write(to:)`-overwrote the whole file on an open failure.)
2. **BetterStack:** the `logs` ship-queue drops-oldest at `maxEntries=500` with **no counter**; `flushToPhone` is skipped while the transport gate is suppressed (background) → `logs` overflows and silently drops the oldest.

The ring meticulously counts its own drops; **WatchLogger counted nothing**, so any loss here is invisible — which is *why* the exact path for this specific 10-line chunk can't be uniquely reconstructed from static analysis. That undeterminability **was** the bug.

## The fix (built — commit `2066f6479`, patch-09)
1. `appendToDailyLog` returns success; **buffer kept + retried on failure** (bounded by `dailyLogBufferMaxLines`); the **overwrite fallback removed** (open-failure on an existing file now fails rather than truncating it).
2. **Drop accounting** mirroring the ring: `logs_dropped` / `daily_write_failures` / `daily_lines_dropped` + a sanitized `daily_write_err` (`domain#code`, never a path) surfaced on the `log_pipeline_summary` line.
3. Size-triggered daily retries **throttled** (`lastDailyDrainCount`) so a stuck batch can't turn every `log()` into a disk retry.
cursor-task: 2 rounds to no Blocker/High. Accepted residuals: a truncate failure still returns `true` (the batch *was* written; oversize/Jetsam is indirectly observable via relaunch telemetry); failure metrics surface on the next `flushToPhone`.

## Implications
1. **`ext_session_started` undercounts** (C2) — query the union set or heartbeat `ext_session_state`.
2. **The watch silently dropped log lines on-device** — a network retry could never have fixed it. Post-fix, any recurrence leaves a trace (`logs_dropped`/`daily_write_failures`/`daily_write_err`).
3. **For the A/B/C soak:** the loss was on-device, so the read-out is now trustworthy *only with the new counters watched* — if `reanchor_*` events go missing during a window where `logs_dropped`/`daily_write_failures` are nonzero, treat it as a logging drop, not a behavior signal.

## Related: a third silent-loss path (ship-side), found + fixed post-214
The build-214 hardening review (ollama, whole-file) surfaced a **third** silent drop, distinct from the two above and **not** the cause of the 1053–1062 gap: `flushToPhone` splits an oversized flush into ≤4 chunks; a single flush exceeding **4×`logSizeCap` (~256 KB)** packs what fits into the last chunk and **silently discarded the overflow** (no counter; `lines_flushed` still claimed all). These lines drop from the **BetterStack ship path only** — they remain in the on-device daily log — so it's a completeness gap, not total loss. Fixed (`177a6c723`, patch-09, **build 215**): `droppedInTrunc` counted into `logs_dropped`/`_total` and stamped as `lines_dropped=N` on the `log_flush_truncated` marker. Residual: per-flush `logs_dropped` lags one flush (summary logs before chunking); the cumulative total + marker are immediate. Fires only on a >256 KB single flush (≈never in normal soak). **Process note:** this was in the ollama review *before* 214 built and should have been flagged for an inclusion decision then, not after.

## Cloud-logging (patch-06) review: verified, nothing to fix — one item deferred
An ollama whole-file review flagged 8 items; all were verified against the code. Of the cloud-logging ones:
- **"Serial resend stalls the actor" — NOT a bug.** `sendMessageAwaitingReply` is `await withCheckedContinuation { … session.sendMessage(…) }` (`:248`); the `await` suspends the task and **releases the actor**, so `flushIfNeeded`/`log()`/lifecycle interleave during a resend. Serial = slower backlog drain, never a stall.
- **"Silent payload-write loss" — self-heals.** `resendPendingPayloads` drops an unreadable/missing record (`:981-987`); `storePendingPayload` TTL-prunes; lines are also in the on-device daily log.
- **Pending-record / file-cleanup coupling (`#5`) — real but ≈never fires. DEFERRED.** Across 3 sites (`sendLogPayload`, `resendPendingPayloads`, `deleteFilesForPayloadIds:1113`) the pending record is dropped **only if the local file delete succeeded** (`if res.succeeded { removePendingPayload }`). The record does double-duty — "needs resend" **and** "file needs cleanup" — so a *failed* delete keeps the record and the already-ACKed payload is **re-sent (a duplicate)** on the next cycle. But `removeFileTracked` returns success on a **missing** file (`:177`), so `succeeded==false` only on a genuine non-missing FS error deleting the watch's **own sandbox file** — essentially never; it's also TTL-bounded and payloadId-dedup'd on the phone.
  - **Correct fix (the "refactor"):** split the pending record's two roles — track "resend-needed" separately from "file-cleanup-needed", so an ACK always clears resend-state (no duplicate) while a failed delete only retries cleanup. The naive one-liner (always `removePendingPayload` on ACK) just trades the ≈never duplicate for a ≈never orphaned file, so it's not a real fix.
  - **Deferred** as not worth the cost for the value (≈never fires, no data loss). On `feature/cloud-logging` / patch-06 **only if we ever touch this area.**

## Out of scope (C-212-5 v2 code issues raised by review; tracked separately)
Backstop/stale-guard not clearing `pendingReanchorSession`/`sessionPendingDidStart`; watchdog-adopt resetting the true-age clock to "now" (partial BUG-E regression); compile-time-only `reanchorEnabled`.

## Changelog
- **rev 1** — ring-eviction hypothesis; "emitted"→"enqueued".
- **rev 2** — ring-eviction refuted (`ring_dropped=0`).
- **rev 3** — settled `missing=0`/1026 → "lag" (premature).
- **rev 4** — 75-min absence → "post-drain shipping loss" (wrong: BetterStack-only).
- **rev 5** — raw on-device log has the same gap → loss is **inside WatchLogger** (silent, unaccounted); seq-resets-per-process clarified; hardening + instrumentation built (`2066f6479`).
- **rev 6** — build-214 shipped the fix (`4973014bf`); post-build ollama review found a **third** silent-loss path (ship-side `flushToPhone` chunk truncation), fixed (`177a6c723`) + queued for build 215.
- **rev 7** — verified all 8 ollama flags against code: 6 false-positive/by-design/cosmetic, the 2 "real" cloud-logging ones refuted (#3 actor releases at the continuation) / ≈never-fires (#5 `removeFileTracked` missing=success). No cloud-logging fix; #5 refactor deferred. `177a6c723` folded into patch-09 + patch-tested (not built).
