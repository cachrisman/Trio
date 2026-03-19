# Observability Standards

**Version:** v1  
**Created:** 2026-03-19 10:58 CET  
**Last updated:** 2026-03-19 10:58 CET

---

Standards and conventions for logging, telemetry, and metrics in this repo. This is a process doc: edit deliberately and bump the version.

For Better Stack operational details (API endpoints, MCP tools, dashboard queries), see `docs/process/betterstack-guide.md`. For cloud logging architecture, see `docs/completed/betterstack/cloud-logging.md`.

## Logging architecture

### Components

| Component | Location | Role |
|-----------|----------|------|
| `Logger` | `Trio/Sources/Logger/Logger.swift` | iOS logging facade. Holds category enum; routes to `GroupedIssueReporter`. |
| `SimpleLogReporter` | `Trio/Sources/Logger/IssueReporter/SimpleLogReporter.swift` | File writer. Writes iOS logs to `logs/log.txt`; watch logs to `logs/watch_log.txt`. |
| `CloudLogUploadService` | `Trio/Sources/Logger/CloudLogging/CloudLogUploadService.swift` | Schedules uploads (5-min timer + lifecycle triggers). |
| `CloudLogUploader` | `Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift` | Tails log files, parses, filters, batches, uploads. |
| `CloudLogLineParser` | `Trio/Sources/Logger/CloudLogging/CloudLogLineParsing.swift` | `parseIOS()` and `parseWatch()` produce `CloudParsedLogLine`. |
| `BetterStackLogtailProvider` | `Trio/Sources/Logger/CloudLogging/BetterStackLogtailProvider.swift` | HTTP transport to Better Stack (expects HTTP 202). |
| `WatchLogger` | `Trio Watch App Extension/WatchLogger.swift` | Actor. In-memory buffer on watch; flushes to phone via WatchConnectivity. |
| `ComplicationLogBuffer` | `Trio Watch Shared/ComplicationLogBuffer.swift` | Static enum. Writes to App Group file from complication extension process. |

### Data flow

```
iOS app:
  debug/info/warning/error → Logger → GroupedIssueReporter → SimpleLogReporter → logs/log.txt

Watch app:
  WatchLogger.log() → in-memory buffer → flushToPhone() → sendMessage/transferUserInfo → phone

Complication extension:
  ComplicationLogBuffer.append() → App Group complication_log.txt
    → WatchLogger.drainComplicationLogs() → phone

Phone receives watch logs:
  AppleWatchManager → SimpleLogReporter.appendToWatchLog() → logs/watch_log.txt

Cloud upload:
  CloudLogUploadService → CloudLogUploader tails log.txt + watch_log.txt
    → parse → filter → batch → BetterStackLogtailProvider → Better Stack
```

## Log levels

| Level | Logger method | File prefix | Cloud normalized | When to use |
|-------|--------------|-------------|-----------------|-------------|
| Debug | `debug()` | `DEV:` | `debug` | Diagnostic detail useful during development. High volume is expected. Subject to cloud filtering. |
| Info | `info()` | `INFO:` | `info` | Normal user-relevant events: state transitions, successful operations, lifecycle events. |
| Warning | `warning()` | `WARN:` | `warn` | Non-fatal issues that deserve attention but don't block operation. Also triggers `reportNonFatalIssue`. |
| Error | `error()` | `ERR:` | `error` | Fatal or near-fatal conditions. Calls `fatalError` after logging. Reserve for genuine failures. |

### Guidelines

- **Debug is the default.** Use it for anything that helps diagnose behavior but is not operationally significant.
- **Info is for events you'd want on a dashboard.** State changes, successful completions, lifecycle markers.
- **Warning is for things that should be investigated** but don't crash the app: connectivity failures, unexpected but recoverable states.
- **Error is for conditions that should never happen.** The app calls `fatalError` after logging; treat it as a crash report precursor.
- **Debug dominates cloud volume** (~77% of bytes historically). When adding new debug logging, consider whether it will generate high-frequency output and whether cloud ingestion filtering may be needed.

### Message-based level detection

The cloud upload parser (`CloudLogLineParser.detectLevelFromMessage()`) can upgrade a log line's level based on message content. Known error/warn patterns (e.g., "failed to retrieve file", WatchConnectivity error domains) are re-classified at upload time. This means some lines logged at `debug` level may appear as `warn` or `error` in Better Stack.

## Categories

Categories are defined as `Logger.Category` (a `String`-valued enum):

| Category | Raw value | Typical usage |
|----------|-----------|---------------|
| `default` | `"Default"` | General / uncategorized |
| `service` | `"Service"` | DI assembly, service lifecycle |
| `businessLogic` | `"BusinessLogic"` | Core loop logic |
| `openAPS` | `"OpenAPS"` | Algorithm (oref, autosens, meal.js) |
| `deviceManager` | `"DeviceManager"` | Pump + CGM device interaction |
| `apsManager` | `"ApsManager"` | APS manager |
| `nightscout` | `"Nightscout"` | Nightscout sync |
| `remoteControl` | `"RemoteControl"` | Remote commands |
| `bolusState` | `"BolusState"` | Bolus state machine |
| `watchManager` | `"WatchManager"` | Watch connectivity + complication |
| `coreData` | `"CoreData"` | CoreData persistence |
| `storage` | `"Storage"` | UserDefaults, file storage |

### Guidelines

- Use the most specific category available.
- Watch log categories are derived from the source filename at parse time (e.g., `WatchState.swift` becomes category `WatchState`).
- Each category maps to an `OSLog` instance for console filtering.

## Log line format

### iOS

```
<TIMESTAMP> [b:<BUILD>] [<CATEGORY>] <File.swift> - <function> - <line> - <LEVEL>: <message>
```

Example:
```
2026-03-19T10:30:00+0100 [b:142] [WatchManager] AppleWatchManager.swift - sendDataToWatch(_:) - 536 - DEV: Transferred new WatchState snapshot via userInfo
```

### Watch

```
[<TIMESTAMP>] [b:<BUILD>] [<File.swift>:<line>] <function> → <message>
```

Example:
```
[2026-03-19T10:30:00+0100] [b:142] [WatchLogger.swift:169] flushToPhone() → Logs queued for background delivery to phone
```

### Build token

Every log line embeds `[b:<BUILD>]` at write time. This ensures lines are attributed to the build that wrote them, not the build that uploaded them. Old-format lines (pre-build-token) omit this field; the parser returns `build: nil` and the uploader falls back to `Bundle.main`.

## Structured logging (key=value)

Use `key=value` pairs in the message body for fields that will be queried or extracted into metrics.

### Format rules

- **Delimiter:** space-separated `key=value` pairs.
- **Keys:** `snake_case`, descriptive, stable across releases.
- **Values:** no spaces (use underscores or camelCase for multi-word values).
- **Event marker:** start structured lines with `event=<event_name>` for discoverability.

### Examples

```
event=complication_reload_requested reload_generation=42 reload_requested_at_epoch_seconds=1710841800
event=complication_get_timeline_called observed_reload_generation=42 generation_delta=1 latency_valid=true latency_seconds=8.3
event=complication_bgtask_completing path=fast window_id=abc123 task_type=refresh completed_count=3
hk_observer_fired fire_id=abc123 reading_epoch=1710841800 sync_lag=2.1 glucose=109 delta=3 trend=flat samples_in_batch=1
battery_level_percent=85 battery_state=charging
```

### Conventions

- **Identifiers:** `window_id`, `fire_id`, `reload_id`, `provider_instance_id` — use for correlation, but do not extract UUIDs into metrics labels (high cardinality).
- **Epoch timestamps:** use `_epoch` or `_epoch_seconds` suffix for Unix timestamps.
- **Boolean fields:** `true`/`false` (lowercase).
- **Sentinel events:** `event=app_launch` and `event=watch_app_launch` mark build boundaries; logged at startup with `[DEPLOY]` prefix.

### Extraction in Better Stack

Structured fields are extracted for metrics via regex on the `message` field:

```sql
extract(JSONExtractString(raw, 'message'), 'field_name=([^ ]+)')
```

## Cloud upload pipeline

### Upload triggers

- App foreground / background lifecycle
- 5-minute periodic timer
- Manual via `CloudLogUploadService.uploadNow()`

### Pipeline stages

1. **Tail** log files by byte offset (only newly appended complete lines).
2. **Aggregate** multi-line entries into single logical lines.
3. **Parse** with `parseIOS()` or `parseWatch()` → `CloudParsedLogLine`.
4. **Truncate** messages exceeding 256 KB.
5. **Filter** via `applyIngestionFilter()` (drop, throttle, or trim).
6. **Batch** (250 events or ~8 MB per request).
7. **Upload** via `BetterStackLogtailProvider` (HTTP POST, expects 202).
8. **Advance offset** only after the final batch succeeds.

### Rotation handling

If a file shrinks (truncation/rotation), its offset resets to 0.

## Ingestion filtering (in-app)

The uploader applies `applyIngestionFilter()` before batching. This is pipeline-only — local log files are unaffected.

### Active filter rules

| Rule | Pattern | Action |
|------|---------|--------|
| Drop PersistedProperty | `[PersistedProperty:…] Saved value successfully.` | Drop all |
| Throttle OpenAPS Dynamic ISF | `Dynamic ISF (Logarithmic Formula)` + IOB_ZT or UAM subtypes | 1 per 60s per subtype |
| Throttle short autosens | `autosens.js:` with message body ≤15 chars | 1 per 60s |
| Trim Watch received data | `Watch received data` with body >500 chars | Drop from `glucoseValues = (` onward |
| Trim long error messages | `Failed to retrieve file` with body >300 chars | Truncate to 300 chars |

### Adding new rules

- Add rules in `CloudLogUploader.applyIngestionFilter()`.
- Throttle state is in-memory (keyed by pattern, inside the actor). Acceptable to reset on app restart.
- **Never filter error-level lines** unless there is a specific, documented reason.

## VRL filtering (Better Stack server-side)

Better Stack applies VRL (Vector Remap Language) transforms at ingestion time. These reduce stored volume without requiring app changes.

### Where to configure

Better Stack UI: **Sources → [source] → Configure → Transform**.

### Conventions

- Test every VRL change with sample JSON using "Try a sample transformation" before saving.
- Document active VRL filters in the relevant completed doc or this file.
- Prefer targeted drops (by message pattern) over blanket level drops.
- The nuclear option (drop all `debug`) saves ~77% of volume but removes diagnostic context.

See `docs/completed/log-volume-optimization/betterstack-vrl-filter-candidates.md` for the full candidate list with volume estimates.

## Metrics

### Extraction rules (Better Stack)

Metrics are extracted from log lines server-side using Better Stack extraction rules. These rules run regex on `raw.message` and produce time-series data for dashboards.

**Key properties:**

- Extraction rules only process events that arrive **after** the rule is created (not retroactive).
- API: `POST /api/v2/sources/{source_id}/metrics` (see `betterstack-guide.md`).
- Avoid high-cardinality labels (e.g., UUIDs) in extraction rules.

### Causality metrics pattern

The complication freshness initiative established a reusable pattern for pipeline causality metrics:

1. **Generation counter** — monotonic counter incremented by the producer (e.g., `reload_generation`), read by the consumer (e.g., `observed_reload_generation`). Delta = coalescing/association signal.
2. **Validity window** — latency is only meaningful within a bounded time window after the triggering event. Log `latency_valid=true/false` alongside `latency_seconds`.
3. **Instance ID** — `provider_instance_id` distinguishes process restarts from genuine zero-deltas. Log `provider_restart=true` on first invocation.

### Dashboard query conventions

- Use `FROM {{source}}` (never hardcode table names).
- Use `{{time}}`, `{{start_time}}`, `{{end_time}}` for time filtering.
- Read aggregated metrics with `sumMerge()`, `countMerge()`, `quantilesMerge()`, etc.
- Handle NULLs: `coalesce(sumMerge(metric), 0)`.
- Time bucketing: `toStartOfInterval(dt, INTERVAL 60 MINUTE) AS time`.

## Anti-patterns

| Anti-pattern | Why it's bad | What to do instead |
|-------------|-------------|-------------------|
| Logging at `error` level for recoverable conditions | Triggers `fatalError`; app crashes | Use `warning` for recoverable issues |
| Extracting UUIDs into metrics labels | High cardinality; breaks dashboards | Use `event=` correlation in raw log queries |
| Filtering error-level lines in ingestion | Hides real failures | Only filter debug/info patterns |
| Assuming `getTimeline` runs 1:1 with `reloadTimelines` | WidgetKit coalesces; system can invoke independently | Use generation counter + validity window |
| Writing to App Group from both watch app and provider | Cross-process race conditions | Single writer (watch app writes, provider reads) |
| Stamping build number at upload time | Backlogged lines get the wrong build | `[b:BUILD]` embedded at write time |
| Using `flock`/POSIX locks for App Group coordination | Unreliable across extension processes | Atomic single-writer patterns |

## Volume budget

- Better Stack plan: **5 GB/month** combined across all sources.
- Daily sustainable rate: ~166 MB/day.
- Trio is the primary consumer; Nightscout is secondary (~50 MB/day).
- Debug level accounts for ~77% of bytes. Targeted filtering is preferred over blanket debug drops.

Monitor ingestion volume regularly. If approaching the cap:
1. Check if new high-volume log lines have been added without corresponding ingestion filters.
2. Review VRL filter candidates.
3. As a last resort, consider dropping all `debug` level via VRL.

---

## Changelog

### v1 (2026-03-19 10:58 CET)
- Initial version. Codifies logging architecture, log levels, categories, line formats, structured logging conventions, cloud upload pipeline, ingestion filtering, VRL filtering, metrics extraction patterns, causality metrics pattern, anti-patterns, and volume budget. Derived from existing codebase patterns and completed docs (cloud-logging, logging-fixes, betterstack-ingestion-filter-proposal, vrl-filter-candidates, causality-metrics-design).
