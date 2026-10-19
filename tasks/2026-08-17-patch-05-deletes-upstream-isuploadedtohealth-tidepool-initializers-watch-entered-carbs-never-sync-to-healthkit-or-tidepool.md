+++
uid = "01a00eb5-72af-7121-8192-7fcc4affbaa5"
key = "TRIO-037"
title = "Patch 05 deletes upstream isUploadedToHealth/Tidepool initializers - watch-entered carbs never sync to HealthKit or Tidepool"
status = "in-progress"
kind = "code"
source = "agent-discovered"
source_ref = "20260817-094712-codex-review#P1-isUploadedToHealth"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "coredata", "healthkit", "tidepool", "patch-clobber"]

[[acceptance]]
id = "AC-1"
text = "Both deleted initializers restored in both watch carb-entry paths, and patch 05 regenerated via the feature branch (never hand-edited) — `f6ca271f4` + `633cba6ed`, via `mid-stack-update.sh`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-2"
text = "`./scripts/patch-test.sh` passes, including the deletion-footprint audit — passed, with the caveat recorded above that the audit's warning for this file was always present and always invisible among 31 others"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-3"
text = "Existing watch-entered carb entries already in the store with NULL flags are considered. **Decision (operator, 2026-08-20): will NOT be backfilled.** Historical watch-entered carbs stay unsynced to HealthKit and Tidepool permanently. The fix stops the loss going forward from build 222; it does not repair what was already lost. Deliberate and closed — do not reopen as a follow-up task."
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "Existing watch-entered carb entries already in the store with NULL flags are considered. **Decision (operator, 2026-08-20): will NOT be backfilled.** Historical watch-entered carbs stay unsynced to HealthKit and Tidepool permanently. The fix stops the loss going forward from build 222; it does not repair what was already lost. Deliberate and closed — do not reopen as a follow-up task."
closed_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Verified on a real build: enter a carb via the watch, confirm it reaches HealthKit and Tidepool. **Confirmed on build 222, 2026-08-20 06:24 UTC.** 5 g entered on the watch; operator screenshot shows it in Apple Health (Carbohydrates, 5 g, Aug 20 08-09 local), and the telemetry gives the full trace in ~1 s: `⌚️ Sending carbs request: 5g` (watchos) -> `📱 Received carbs request from watch: 5g` (ios) -> `📱 Saved carbs from watch: 5g` -> `Successfully stored 1 carb samples in HealthKit.` -> `Acknowledgment received: Carbs logged successfully.` (watchos) -> `Success synchronizing carbs data. Upload to Tidepool complete.` (ios)"
owner = "agent"
phase = "post-deploy"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-5"
text = "Operator decision recorded on whether `scripts/patch-audit.safety-paths` should grow to cover Core Data upload-flag initializers — **not an agent edit**"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "a3adcfa1-d874-4992-ba74-2e51c693dab3"
model_family = "ollama"
started = 2026-08-17
role = "author"
started_at = "2026-08-17T09:26:28+00:00"

[[sessions]]
host = "claude-code"
ref = "20260817-113828-96041-ollama-implement.md"
model_family = "ollama"
started = 2026-08-17
role = "author"
started_at = "2026-08-17T09:45:48+00:00"

[[reviews]]
run_id = "c5d69fee-5998-4354-a5f2-08d9fc1a11d1"
model_family = "codex"
verdict = "pass"
reviewed_commit = "633cba6ed3f72d13cb21ff2b4fb7479c6597d363"
reviewed_paths = ["patches/05-watch-error-reporting.patch"]
recorded_at = "2026-08-17T09:27:15+00:00"

[[reviews]]
run_id = "6b88e2a9-1c30-4db1-ab59-d497245fcd6c"
model_family = "codex"
verdict = "pass"
reviewed_commit = "d148ba67bd581e24e5da59a86feed4c80418ce8a"
reviewed_paths = ["patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-08-17T09:45:21+00:00"

[[reviews]]
run_id = "f9a929cf-27a4-471c-8ad0-102b472a4471"
model_family = "codex"
verdict = "pass"
reviewed_commit = "48d0608c36f10c29f30131383a7fc4d33cd028de"
reviewed_paths = ["patches/10-watch-session-crash-guard.patch"]
recorded_at = "2026-08-18T04:36:07+00:00"

[[reviews]]
run_id = "2cc2d70f-d1b8-4965-849e-6978972dc030"
model_family = "codex"
verdict = "pass"
reviewed_commit = "02ec6ada3bc5c470ab33fe945a07948b4e091e2d"
reviewed_paths = ["patches/05-watch-error-reporting.patch"]
recorded_at = "2026-08-18T06:41:46+00:00"
+++

## Intent

**Shipped in build 221. Confirmed, not suspected.** Carbs entered on the Apple Watch are never
uploaded to HealthKit or Tidepool. Silent — no error, nothing in the logs, the app behaves normally.

Found by a codex review of `e4e760ff9` run on 2026-08-17 while recording diverse-review evidence for
[[TRIO-030]]; verified independently against the base before filing.

## The defect

`patches/05-watch-error-reporting.patch` deletes two upstream initializers from **both** watch
carb-entry paths in `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, keeping the third:

```diff
                 carbEntry.isUploadedToNS = false
-                carbEntry.isUploadedToHealth = false
-                carbEntry.isUploadedToTidepool = false
```

Base `dev` (post-upstream-merge) carries all three at lines 849–851 and again at 913–915. After the
patch applies, the two deleted attributes are never set on watch-created entries.

## Why that silently breaks upload

The attributes are declared **optional with no default** in the Core Data model
(`Model/TrioCoreDataPersistentContainer.xcdatamodeld/…/contents`):

```xml
<attribute name="isUploadedToHealth" optional="YES" attributeType="Boolean" usesScalarValueType="YES"/>
<attribute name="isUploadedToTidepool" optional="YES" attributeType="Boolean" usesScalarValueType="YES"/>
```

An entry created without setting them stores **NULL**. The fetch that selects entries for upload
requires an explicit `false` (`Model/Helper/CarbEntryStored+helper.swift:33`):

```swift
format: "date >= %@ AND isUploadedToHealth == %@", date as NSDate, false as NSNumber
```

In SQLite predicate evaluation `NULL == 0` does not match, so those rows are never selected.

**This is why it is invisible in code.** `usesScalarValueType="YES"` makes the generated Swift
property a non-optional `Bool`, so reading `carbEntry.isUploadedToHealth` in-app returns `false` and
looks perfectly correct. The failure exists only at the store-predicate level.

Corroboration that explicit initialization is the required convention, not decoration: **every other
creation site in the codebase sets it** — `GlucoseStorage.swift:217,296`, `CarbsStorage.swift:293`,
and eleven sites in `PumpHistoryStorage.swift`. After this patch the two watch paths are the only
creation sites that do not.

## This is the patch-clobber class again

Same shape as the patch-13 / OmniBLE incident in `docs/process/patch-clobber-guardrails.md`: a
regenerated patch silently deletes upstream code, applies with no conflict, compiles, archives, ships
— and quietly loses functionality. The distinguishing feature both times is that **only conflict
hunks were reviewed**, so a clean-applying deletion went unexamined.

`patch-audit.sh` did not catch it. That is not an audit bug — `AppleWatchManager.swift` is simply not
in `scripts/patch-audit.safety-paths`, and the missing-symbol sentinel does not cover these two
attributes. **Whether to extend the safety-paths list is the operator's call** (the file is
human-maintained and must not be edited by an agent), but this is concrete evidence for widening it
to cover Core Data upload-flag initializers, which are exactly the "deleted line, no compile error,
silent data loss" shape the audit exists to catch.

[[TRIO-030]]'s acceptance criterion *"Full diff vs base reviewed for every regenerated patch,
deletions especially (AGENTS.md rule 12)"* was marked met; this deletion is in a regenerated patch
and was not caught, so that criterion has been reopened there.

## Notes carried over from acceptance criteria
## Fixed 2026-08-17 (not yet shipped)

- `f6ca271f4` on `feature/watch-error-reporting` — restores both initializers at both sites, 4
  insertions, 0 deletions. Agent-signed (`agent@chrisman.io`, sig `G`); 1Password not involved.
- `633cba6ed` on `dev` — patch 05 regenerated via `mid-stack-update.sh --patch 05 --cherry-pick`,
  never hand-edited.

Verification that the deletion is actually gone, rather than that the build is green: both deletion
hunks are absent from the regenerated patch, and the patch's own stat line drops from **91 to 87
deletions** — exactly the four restored lines — with insertions and file count unchanged at
`1029 / 6`. `mid-stack-update.sh` reported `Stack validation: PASSED`, `Drift check: CLEAN`,
`Files in patch: 6` (no drop). `./scripts/patch-test.sh` passes including `patch-audit`.

Work was authored by an ollama `implement` run (note
`20260817-111202-48797-ollama-implement.md`, run `a3adcfa1`). **The quality loop was stopped
deliberately mid-iteration**: its review pass had begun reporting REAL BUGs at L645 and L1035 —
unrelated pre-existing code far from this change — and letting it "fix" those would have contaminated
the patch regeneration with edits nobody asked for. The first-generation edit was already correct.

Two comment lines picked up a stray leading space as surgical-edit drift (`// Acknowledge failure`);
reverted before commit, so the committed diff is exactly the four intended lines.

### ⚠ CORRECTION 2026-08-17 — patch 05 was only half the cause, and the first "verified" claim was wrong

The fix above was **incomplete and its verification was invalid**. Patch 05 is not the only patch that
removes these lines: **patch 10 (`watch-session-crash-guard`) rewrites the same carb-entry region and
applies later in the stack**, re-deleting them after patch 05 had restored them.

Caught by tracking the flag count through each patch application in a fully stacked scratch tree:

| after patch | `isUploadedToHealth` count |
|---|---|
| 05 watch-error-reporting | 2 ← patch 05 fix working |
| 09 watch-g7 | 2 |
| **10 watch-session-crash-guard** | **0** ← re-deleted here |
| 13, 14 | 0 |

So after `633cba6ed`, the shipped behaviour was **unchanged** — the stacked
`AppleWatchManager.swift` still contained neither flag, while base `dev` contained both.

**Why the first verification missed it.** It checked patch 05 in isolation — the patch's own diff, its
deletion count dropping 91 → 87, and `git show feature/watch-error-reporting:…` — none of which
describe what ships. The shipped artifact is the *stacked* result of all nine patches, and it was
never built or inspected. This is the same class of error as the original defect: verifying an
intermediate artifact and reporting it as if it were the outcome. Note also that
`mid-stack-update.sh` reported `Stack validation: PASSED` and `patch-test.sh` passed both before and
after — neither tool checks that a restored line survives later patches, so a green run proved
nothing here.

**Second fix:**

- `1021a8add` on `feature/watch-session-crash-guard` — same 4 lines at the same two sites
- `d148ba67b` on `dev` — patch 10 regenerated; it no longer deletes them (it does not need to *add*
  them: patch 05 now leaves them in place and patch 10 simply stops removing them)

**Verification that is actually valid this time:** all nine patches applied in order to a scratch
worktree off `dev`; the resulting `AppleWatchManager.swift` contains `isUploadedToHealth` **twice**,
matching base `dev`. Before `d148ba67b` the same procedure yielded **zero**. `patch-test.sh` passes.

### Provenance of the patch-10 edit, stated precisely

The second offload (`20260817-113828-96041-ollama-implement.md`, run with `--no-loop`) produced the
correct four lines **plus six drifted lines** — stray leading spaces on comments, a closing paren and
a closing brace. Rather than hand-patch the drift, the file was reset (`git checkout --`) and the four
lines re-inserted deterministically, anchored on each existing `carbEntry.isUploadedToNS = false` and
inheriting its indentation. So the committed content is a mechanical re-application of the offload's
result, not the offload's raw output — recorded here because "ollama authored it" alone would
overstate what the run contributed.

Two evidence gaps worth admitting rather than hiding:

- That note file is **gone** — it lived in the `trio-037b` worktree, which was removed during cleanup
  before the note was copied out. The first offload's note was preserved; this one was not. The
  session is recorded by `--ref` and `--model-family` from the run's own printed filename.
- The `--no-loop` run emitted no `~/.task-relay/runs/*.jsonl`, so there is no independent trace of it
  either. Drift was also noticeably worse without the loop than with it — one data point, but it cuts
  against `--no-loop` on Swift files, where there is no static gate to catch indentation damage.

### Method note for any future patch-clobber fix

Verify against the **fully stacked tree**, never a single patch or feature branch:

```
git -C ../Trio worktree add --detach <scratch> dev
cd <scratch> && for p in <Trio-dev>/patches/*.patch; do
    git am --3way --keep-cr --whitespace=nowarn "$p"; done
grep -c "<symbol>" <file>          # compare against: git show dev:<file> | grep -c "<symbol>"
```

Per-patch counts across the sequence pinpoint which patch removes a symbol, which is what identified
patch 10 here.

Still to do: ship it — see [[TRIO-044]].

### The audit did warn, and the warning was invisible

`patch-audit.sh` flags this file as `⚠ … deletes pre-existing upstream code` — and always did. It is
one of **31 such warnings** across the stack, most of them legitimate, so the signal that would have
caught this was buried in routine noise rather than absent. Extending
`scripts/patch-audit.safety-paths` (operator-only) would help only if the new check is *specific*
enough not to add a 32nd warning nobody reads. The more useful lever is probably a distinct check for
deleted Core Data upload-flag initializers, which have a recognisable shape and near-zero legitimate
reason to be removed.

## Severity

Not dosing-safety: the carb entry itself is stored and does reach the algorithm and Nightscout
(`isUploadedToNS` is still set). What is lost is health-record completeness in HealthKit and Tidepool
for any carb entered from the watch. Watch carb entry is a routine daily action, so the loss is
ongoing and accumulating since the patch shipped.


## Review-coverage note (2026-08-18)

The `pass` at `d148ba67b` covers a **superseded** state of `patches/10`: the patch was regenerated
afterwards at `48d0608c3` when [[TRIO-038]]'s rebuilt feature branch landed, so that review no longer
describes the shipped artifact.

The `48d0608c3` state *was* reviewed by codex — whole-diff, run `f9a929cf` — but the verdict was
recorded against [[TRIO-038]], which is where that regeneration belonged. That review is
cross-referenced onto this task rather than re-run, since the same diff carries both changes and the
carb-flag lines are inside it. **It is not an independent second review**; the run id is shared with
[[TRIO-038]] deliberately so this cannot be miscounted as extra coverage.

Corroborated independently by the stacked verification for [[TRIO-041]], which counted the upload
flags at 2 in the fully-stacked tree after `48d0608c3`.
