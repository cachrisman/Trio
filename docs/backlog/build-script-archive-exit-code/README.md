# Backlog: `local-build.sh` reports success on a failed archive

**Status:** Backlog (not scheduled)
**Severity:** Medium — safety/process (a failed build can masquerade as a shipped one)
**Found:** 2026-06-15, during the build-209 deploy

## Problem

On the first build-209 attempt, the IPA archive **failed** (Swift compiler crash in the
G7SensorKit fork's `Common/Data.swift`), yet `ci/local-build.sh` printed:

```
[stage] ✗ Failed: Build IPA (1m 37s)
...
║  ✅ TOTAL (Success)                2m 0s  ║
EXIT_CODE=0
```

The Build-IPA stage correctly logged `ARCHIVE FAILED` / `❌ Build step FAILED (exit code: 1)`, but
the **overall script still printed `TOTAL (Success)` and exited 0**. The failure was only caught by
reading the log (`ARCHIVE FAILED`, `Data.swift:21:9: error`), not the exit code.

By contrast, the successful re-run reached the **Record Release** stage and exited 0 — so the
distinguishing signal of a real success is "did it reach TestFlight Upload + Record Release," not the
exit code or the summary banner.

## Why it matters

This is a medical-app deploy pipeline. An agent or person who trusts the wrapper's exit code / the
green `TOTAL (Success)` banner could believe a build shipped when the archive actually failed. The
exit code must reflect the real archive/upload result.

## Fix direction

- Propagate the Build-IPA stage's non-zero exit through to the wrapper's final exit code and the
  summary banner (don't print `✅ TOTAL (Success)` when any stage failed).
- Consider a final assertion: success requires the TestFlight-upload "Successfully uploaded" line
  (and/or the Record-Release stage) to have run; otherwise hard-fail.

## Verification reference

- Failed run log markers: `ARCHIVE FAILED`, `[build] ❌ Build step FAILED (exit code: 1)`,
  `[stage] ✗ Failed: Build IPA`, yet `TOTAL (Success)` + `EXIT_CODE=0`.
- Successful run: `Build IPA … ✅`, `TestFlight Upload … ✅`, `Record Release … ✅`,
  `[build] Local build + TestFlight upload finished successfully.`
