+++
uid = "019f8141-e117-77db-9216-aac98a4cf34d"
key = "TRIO-017"
title = "Audit logging/watch-communication performance (battery)"
status = "backlog"
kind = "code"
source = "human"
source_ref = "docs/backlog/perf-optimizations/perf-optimizations-ideas.md#L1"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["performance", "battery"]
+++

## Intent

Battery-life impact has been observed. This is a holistic performance review of the logging and
watch-communication subsystems, covering four areas identified in
`docs/backlog/perf-optimizations/perf-optimizations-ideas.md`: hot-path object allocations in
logging, log-volume reduction, WatchConnectivity transfer efficiency, and filesystem I/O patterns.
The doc's own next step: scope a dedicated audit under `docs/in-progress/perf-optimizations/`
before starting.

## Acceptance criteria

- [ ] Audit hot-path allocations in `WatchLogger.log()`, `ComplicationLogBuffer.appendToFile()`, `CloudLogUploader.uploadNewContent()`
- [ ] Evaluate sampling/rate-limiting for high-frequency log categories and lazy log-message evaluation
- [ ] Review `transferUserInfo`/`sendMessage` size, frequency, and retry patterns
- [ ] Review file append patterns, directory-scan frequency, and metadata-vs-content reads
- [ ] Produce a scoped design doc before implementation begins
