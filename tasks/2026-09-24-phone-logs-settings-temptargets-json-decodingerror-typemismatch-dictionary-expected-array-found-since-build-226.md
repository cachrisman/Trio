+++
uid = "01a0d444-b0c0-73f9-b89b-a46a954b38af"
key = "TRIO-067"
title = "Phone logs 'settings/temptargets.json' DecodingError.typeMismatch (dictionary expected, array found) since build 226"
status = "review"
kind = "code"
source = "human"
created = 2026-09-24
updated = 2026-10-19
touched = 2026-10-19
owner = "me"
tags = ["bug", "phone", "temp-targets"]
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"

[[acceptance]]
id = "AC-1"
text = "Reader, writer and call site identified, with the cause written up here"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "note"
evidence = "tasks/2026-09-24-phone-logs-settings-temptargets-json-decodingerror-typemismatch-dictionary-expected-array-found-since-build-226.md"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:26+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[acceptance]]
id = "AC-2"
text = "Impact assessed: what the failed read skipped, and whether any data or behaviour was affected"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "note"
evidence = "tasks/2026-09-24-phone-logs-settings-temptargets-json-decodingerror-typemismatch-dictionary-expected-array-found-since-build-226.md"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:26+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[acceptance]]
id = "AC-3"
text = "Fixed in the right place (upstream PR or owning patch), patch-test and audit pass"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "2f9d809a5 — fix on upstream-based fix/filestorage-append-probe-log (upstream PR candidate), carried as patches/18-filestorage-append-probe-log.patch; scripts/patch-test.sh full stack 01-18 applied, patch-audit PASSED; codex-work review PASS 4267d88f"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:26+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[acceptance]]
id = "AC-4"
text = "BetterStack: no `temptargets.json` typeMismatch lines on the build that ships the fix, across at least one morning window"
owner = "agent"
phase = "post-deploy"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "c7778b5e-ccd4-4f34-b967-956fe669b1bb"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:22:07+00:00"

[[reviews]]
run_id = "4267d88f-f189-42e7-b5d9-47c227ff3965"
model_family = "codex"
verdict = "pass"
reviewed_commit = "bcebda2f5881b5835cecdade8593f951493ac899"
reviewed_paths = ["Trio/Sources/Services/Storage/FileStorage.swift"]
recorded_at = "2026-10-19T19:31:47+00:00"
+++

## Intent

Find and fix why the phone logs, several times a day:

`Failed to retrieve file 'settings/temptargets.json': DecodingError.typeMismatch: Expected value of type Dictionary<String, Any>. Debug description: Expected to decode Dictionary<String, Any> but found an array instead.`

Something reads the temp-targets settings file expecting a dictionary (an object at the top level), but the file holds an array.

## Evidence (BetterStack, source 1659391, platform ios)

| Build | Lines | First seen (UTC) | Last seen (UTC) |
|---|---|---|---|
| 226 | 21 | 2026-09-17 06:25:04 | 2026-09-22 09:21:16 |
| 227 | 9 | 2026-09-23 06:25:57 | 2026-09-23 16:27:00 |
| 228 | 3 | 2026-09-24 06:31:36 | 2026-09-24 07:07:14 |

- None from 2026-08-10 to 2026-09-09. Build 226 was the first build on the upstream 1.0.0 sync (TRIO-059), so the likely cause is an upstream 1.0.0 change to the temp-target storage format, or a reader (upstream or a fork patch, e.g. patch 14 temp-target-default-tab) still expecting the old shape.
- The times cluster around 06:25 to 07:07 UTC, with one at 16:27, which looks like a scheduled or periodic job rather than user actions.
- The error is logged at error level and has not caused any visible failure so far; impact unknown until the reader is identified.

## Plan

1. Find every reader of `settings/temptargets.json` (the file storage key) in dev plus the applied patch stack, and what type each decodes it as.
2. Compare with how upstream 1.0.0 writes the file, and check the fork patches for a reader expecting the old shape.
3. Identify the caller behind the morning cadence (the log line's call site and job), and what it does with the failed read (skips, falls back, or loses data).
4. Fix the reader (or migrate the stored file if the format changed and an old reader is correct), via the owning feature branch or an upstream PR if the bug is upstream.

## Cause (2026-10-19)

- Reader: `BaseFileStorage.append(_:[Value], to:uniqBy:)` in `Trio/Sources/Services/Storage/FileStorage.swift` (upstream code, no fork patch involved). Its first step probes the file as a single `Value` (one `TempTarget`, a JSON object) before falling back to `[Value]`. `settings/temptargets.json` always holds an array, so that probe always fails, and `retrieve()` logs the decode error at error level.
- Writer and call site: `TempTargetsStorage.saveTempTargetsToStorage` is the only `uniqBy` caller. It runs on every temp-target save, i.e. the Nightscout treatment fetch (`FetchTreatmentsManager`), setting or cancelling a temp target in Adjustments or Home, and `AdjustmentManager`. That explains the bursty, non-user-looking cadence.
- Impact: none on data. After the failed probe, `append` reads the file as `[Value]`, which succeeds, and merges and saves as intended. The only effect was a misleading error line per save. Why the line first appears with build 226 is not confirmed: the probe-then-fallback logic is in upstream `append`, so the 1.0.0 sync most likely added this call path or raised its log level.
- Fix: probe silently (`retrieveSilently`, no logging) only for that first single-object attempt; the array read still logs real failures. Branch `fix/filestorage-append-probe-log` off upstream dev (commit 2f9d809a5), carried as patch 18 and suitable as an upstream PR.

## Notes carried over from acceptance criteria
