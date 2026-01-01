# Cloud Logging for Trio

This document captures the current on-device logging setup and how to relay logs to a cloud provider without changing the existing file-based pipeline.

## Current log files (source of truth)

### iPhone
- **Directory:** `~/Documents/logs/`
- **Files:**
  - `log.txt` (current day)
  - `log_prev.txt` (previous day after rotation)
- **Rotation:** At the first log write after midnight, `log.txt` is moved to `log_prev.txt` and a new `log.txt` is created with a `creationDate` at start-of-day.
- **Flush behavior:** Each log write appends immediately (no buffering).
- **Format examples:**
  - `2025-12-31T22:02:48+0100 [WatchManager] AppleWatchManager.swift - sendDataToWatch(_:) - 536 - DEV: 📤 Transferred new WatchState snapshot via userInfo`
  - `2025-12-31T22:05:40+0100 [Nightscout] FetchTreatmentsManager.swift - subscribe() - 29 - DEV: FetchTreatmentsManager heartbeat`
  - Fields: timestamp (`yyyy-MM-dd'T'HH:mm:ssZ` with offsets like `+0100`), category in brackets, file, function, line, then `LEVEL:` followed by the message.

### Watch logs as stored on the phone
- **Directory:** `~/Documents/logs/`
- **Files:**
  - `watch_log.txt` (current day)
  - `watch_log_prev.txt` (previous day after rotation)
- **Rotation:** Same midnight move pattern as iPhone logs.
- **How they arrive:** The watch bundles logs into strings and sends them via `WCSession`. The phone simply appends the received text to `watch_log.txt`; no transformation is performed.
- **Format example (watch-originated lines):**
  - `[2025-12-31T00:01:27+0100] [WatchLogger.swift:169] flushToPhone() → ⌚️ Logs queued for background delivery to phone`
  - `[2025-12-31T00:02:40+0100] [WatchState.swift:658] handleBackgroundTasks(_:) → Handling background tasks: 1`
  - Fields: timestamp in brackets, file:line (used as category), function, arrow (`→`), and the message. No explicit level prefix.

## Parsing hints
- **iPhone level:** Extract the `LEVEL:` token appearing after delimiters, using the exact strings `DEV`, `INFO`, `WARN`, `ERR` (mapped to debug/info/warning/error). Do **not** check prefix-only.
- **iPhone category:** The bracketed value immediately after the timestamp (e.g., `[WatchManager]`).
- **Watch category:** Derived from the `File.swift` token in `[File.swift:line]` (extension stripped).
- **Timestamps:** Parsed as `yyyy-MM-dd'T'HH:mm:ssZ` and normalized to RFC3339 by inserting the colon in the offset (e.g., `+0100` → `+01:00`). If normalization fails, omit `dt` and let the provider assign ingest time.
- **Correlation IDs:** Not present in current formats.

## Provider choice
- **Primary:** Better Stack (Logtail)
  - Generous free tier (~50k logs/month, 3-day retention on free plan at time of writing) and simple HTTPS ingestion.
  - Full-text search with structured attributes; supports export via API.
  - HTTP ingestion endpoint: `https://in.logs.betterstack.com` with `Authorization: Bearer <source-token>`.
- **Fallback:** Axiom (cloud.axiom.co)
  - Free tier (limited events/day, 7-day retention); accepts HTTPS writes with a dataset token.
  - Good search/filter and CSV/NDJSON export.

## Configuration (iPhone)
1. Create a Logtail source (primary) and grab the **Source token**. For Axiom, create a dataset and note the ingest token and dataset name.
2. Add the following to `ConfigOverride.xcconfig` (or your preferred xcconfig) before building:
   ```
   CLOUD_LOGGING_ENABLED = YES
   CLOUD_LOGGING_ENDPOINT = https://in.logs.betterstack.com
   CLOUD_LOGGING_TOKEN = <logtail-source-token>
   CLOUD_LOGGING_ENV = dev // or prod
   ```
   - For Axiom, set `CLOUD_LOGGING_ENDPOINT = https://api.axiom.co/v1/datasets/<dataset>/ingest` and `CLOUD_LOGGING_TOKEN = <axiom-token>`.
3. Build/install the app. The uploader reads the values from `Info.plist` at runtime; if disabled or missing, cloud uploads are skipped.

## What gets uploaded
- The uploader tails `log.txt`, `log_prev.txt`, `watch_log.txt`, and `watch_log_prev.txt` from the phone’s Documents/logs directory using a per-file byte offset checkpoint.
- Each line is sent as the message body. Parsed attributes include:
  - `platform` (ios/watchos)
  - `level` (derived from `DEV`/`INFO`/`WARN`/`ERR` prefixes when present)
  - `category` (iPhone lines only)
  - `env`, `appVersion`, and `build`
- Offsets are stored locally; if a file shrinks (rotation), the offset resets to `0` and the file is re-read from the beginning.

## Querying and export
- **Logtail:**
  - Search by `platform:"watchos"` or `category:"Service"`.
  - Filter by `level:error` for ERR lines.
  - Export via the Better Stack API or UI as NDJSON/CSV for offline/AI analysis.
- **Axiom fallback:**
  - Use the query builder or Axiom Query Language (AQL), e.g., `['platform' == "ios" and 'level' == "warning"]`.
  - Export via the dataset export tab or `axiom export` CLI.

## Manual checks (expected behavior)
- New log lines appear in Logtail within a few seconds of upload when connectivity is available.
- Only appended content is uploaded; offsets prevent re-sending unless a rotation shrink is detected (in which case the day’s files may re-upload).
- Watch log lines are tagged with `platform=watchos` and can be filtered separately.
- Uploads are attempted on app foreground/background transitions and every five minutes while running; `uploadNow()` can be called manually for immediate flushing.
