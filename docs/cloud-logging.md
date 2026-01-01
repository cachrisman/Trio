# Cloud logging (Better Stack / Logtail)

## Goals / constraints

- **File-based logs remain the source of truth** (no changes to how logs are written).
- **Watch → iPhone log transfer is reused** (watch logs are uploaded from the phone only).
- **Cloud upload tails files using byte offsets** (no extra buffering system).
- **Provider is swappable** (Better Stack is implemented; Axiom is a fallback design target).

## Provider

- **Primary**: Better Stack / Logtail
- **Fallback**: Axiom (not implemented yet, but the code is structured around a `CloudLogProvider` protocol)

### Better Stack endpoint

- **URL**: `https://in.logs.betterstack.com/`
- **Method**: `POST`
- **Headers**:
  - `Authorization: Bearer <SOURCE_TOKEN>`
  - `Content-Type: application/json`
- **Success criteria**:
  - **Any HTTP 2xx** is treated as success.
  - Any other status does **not** advance offsets (uploads are safe to retry).

## Log files (authoritative on-device sources)

### iPhone logs

Written by existing file logging (`SimpleLogReporter`):

- Current: `Documents/logs/log.txt`
- Previous (daily rotation): `Documents/logs/log_prev.txt`

Format:

`<TIMESTAMP> [CATEGORY] <File.swift> - <function> - <line> - <LEVEL>: <message>`

Example:

`2025-12-31T22:02:48+0100 [WatchManager] AppleWatchManager.swift - sendDataToWatch(_:) - 536 - DEV: 📤 Transferred new WatchState snapshot via userInfo`

### Watch logs (on iPhone)

The watch sends logs via WatchConnectivity; the iPhone already persists them (no changes required):

- Current: `Documents/logs/watch_log.txt`
- Previous (daily rotation): `Documents/logs/watch_log_prev.txt`

Format:

`[<TIMESTAMP>] [<File.swift>:<line>] <function>() → <message>`

Example:

`[2025-12-31T00:01:27+0100] [WatchLogger.swift:169] flushToPhone() → ⌚️ Logs queued for background delivery to phone`

## Upload-time parsing (best-effort, non-destructive)

Parsing is done **only at upload time** and is **tolerant of failures**: if parsing fails, the original line is still uploaded.

### Timestamp normalization

Both iPhone and watch timestamps use `+0100` style timezones. When possible, they are normalized to `+01:00`:

- `2025-12-31T22:02:48+0100` → `2025-12-31T22:02:48+01:00`

If normalization fails, `dt` is omitted.

### iPhone parsing

- **dt**: first token, normalized timezone
- **category**: extracted from `[Category]` immediately after timestamp
- **level**: extracted via delimiter-aware match: `\s-\s(DEV|INFO|WARN|ERR):\s` and normalized:
  - `DEV` → `debug`
  - `INFO` → `info`
  - `WARN` → `warn`
  - `ERR` → `error`
- **message**: everything after `<LEVEL>: `

### watch parsing

- **dt**: extracted from first `[ ... ]`, normalized timezone
- **category**: derived from filename in `[File.swift:line]` (without `.swift`)
- **level**: not inferred
- **message**: everything after `→`

### Platform tagging

- iPhone files → `platform = ios`
- watch files → `platform = watchos`

## Offsets + rotation

Uploads tail each file using a **byte offset** stored on-device.

- On each run, only newly appended **complete lines** (ending in `\n`) are uploaded.
- Uploads are **batched** (default: 250 events per request). Offsets only advance after the final batch succeeds.
- If the file **shrinks** (truncation / rotation), its offset is reset to `0`.
- For daily rotation where `*_log.txt` is moved to `*_log_prev.txt`, the uploader best-effort uploads any missed tail from `*_log_prev.txt` before continuing with the new day’s `*_log.txt`.

## Triggers

Uploads are triggered from the iPhone app only:

- **Manual**: `CloudLogUploadService.uploadNow()`
- **Lifecycle**:
  - app foreground
  - app background
- **Periodic**: every 5 minutes while the app is running

## Setup (token)

You must provide a Better Stack **source token**.

Currently supported injection points (in priority order):

1. `UserDefaults` key: `cloudLogging.betterStackSourceToken` (intended for a future in-app UI)
2. `Info.plist` key: `BetterStackSourceToken` (build-time injection recommended; do not commit secrets)
3. Process environment variable: `BETTERSTACK_SOURCE_TOKEN` (useful for local/dev builds)

## Querying + export for AI analysis

Recommended practice:

- Filter by `attributes.platform`, `attributes.category`, `attributes.level`, `attributes.env`, `attributes.appVersion`, `attributes.build`.
- Export by time range + filters for a focused dataset (e.g., around a crash or loop failure).
- This implementation does **not** upload a duplicate `raw` field; the uploaded `message` is either the parsed message or the original full line if parsing fails.

## Future: on-device log viewer (Idea #1)

This design supports an on-device log viewer without rework because:

- The authoritative log files remain on disk (`Documents/logs/...`).
- Cloud upload logic reads using byte offsets without changing log writes.
- A future viewer can read the same files and optionally reuse the same parsing helpers.

