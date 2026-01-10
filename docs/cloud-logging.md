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
  - **HTTP 202 only** is treated as success.
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
- Uploads are **batched** with both:
  - a **count cap** (default: 250 events per request), and
  - a **byte-budget cap** (conservative ~8 MiB uncompressed JSON per request, estimated via encoder size).
  Offsets only advance after the final batch succeeds.
- If the file **shrinks** (truncation / rotation), its offset is reset to `0`.
- Rotation handling is intentionally simple: it only uses the **byte-offset tail model** and resets offsets when the file shrinks.

## Triggers

Uploads are triggered from the iPhone app only:

- **Manual**: `CloudLogUploadService.uploadNow()`
- **Lifecycle**:
  - app foreground
  - app background
- **Periodic**: every 5 minutes while the app is running

## Setup (token)

Trio reads Better Stack settings from a JSON file in the **Trio app group container**:

- Path: `settings/BetterStack.json`
- Example:

```json
{
  "BetterStackSourceToken": "TzZdDRFCDTCXhYTZVLWHhNsk",
  "BetterStackIngestionUrl": "https://s1658969.eu-nbg-2.betterstackdata.com/"
}
```

This file is **generated on-device** and should **not** be committed.

Currently supported injection points (in priority order):

1. App group file: `settings/BetterStack.json`
2. `UserDefaults` key: `cloudLogging.betterStackSourceToken` (fallback)
3. `Info.plist` key: `BetterStackSourceToken` (fallback; do not commit secrets)
4. Process environment variable: `BETTERSTACK_SOURCE_TOKEN` (dev-only fallback)

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

