# Performance Optimizations — Backlog

Version: 1.0
Date: 2026-03-13
Status: Backlog (ideas to explore)

## Context

Battery life impact has been observed and performance optimizations should be prioritized. This file tracks ideas for a holistic performance review of the logging and watch communication subsystems.

## Ideas

### 1. Audit hot-path object allocations in logging

`SimpleLogReporter.log()` is called on every iOS log line. Any per-call allocations (formatters, intermediate strings, Data objects) are multiplied by log volume. The `dateFormatter` computed property was identified as creating a new `DateFormatter` on every call (fixed in logging-fixes Task A3b). A broader audit should check for similar patterns across:
- `WatchLogger.log()` (actor — serial, but still per-call)
- `ComplicationLogBuffer.appendToFile()` (static — called from complication extension)
- `CloudLogUploader.uploadNewContent()` (batch processing — per-line parsing)

### 2. Log volume reduction

High-frequency log categories may be generating more data than needed for observability. Consider:
- Sampling or rate-limiting verbose categories
- Reducing battery context frequency (currently on every watch log line)
- Lazy evaluation of log message interpolation (avoid string construction if log won't be written)

### 3. WatchConnectivity transfer efficiency

- `transferUserInfo` message size and frequency
- `sendMessage` retry patterns and their impact on radio usage
- Batch size optimization for watch log payloads

### 4. Filesystem I/O patterns

- File append patterns (open/write/close per log line vs buffered writes)
- Directory scanning frequency (inventory, inline metrics caching)
- Metadata-only reads vs content reads for size computation

---

## Next steps

When ready to investigate, create a dedicated `docs/in-progress/perf-optimizations/` folder with a design doc scoping the audit.
