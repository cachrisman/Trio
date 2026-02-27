# Better Stack Ingestion Filter — Pipeline-Only Volume Reduction

**Goal:** Reduce Trio log volume ingested by Better Stack by 10–25% by filtering and trimming **only in the cloud upload pipeline**, leaving all local logging (file + console) unchanged.

**Version:** 1.0  
**Date:** 2026-02-26

---

## Current pipeline (from patch 06-cloud-logging)

```
Log files (log.txt, watch_log.txt)
    → CloudLogUploader.uploadNewContent()
    → readCompleteLines() → aggregateEntries() → [entries]
    → compactMap: parser(entry) → CloudLogEvent(message:, dt:, attributes:, raw: entry)
    → truncateMessage() already applied (max 256 KB per message)
    → buildBatches(events) → provider.upload(events: batch)
    → BetterStackLogtailProvider → HTTP to Better Stack
```

Local logging (e.g. `debug(.storage, ...)`, `Logger`, SimpleLogReporter writing to file) is **unchanged**. Only the path from "read file" to "send to provider" is modified.

---

## Approach: single filter step inside the uploader

Insert one step **after** building `[CloudLogEvent]` and **before** `buildBatches(events)`:

```text
let events: [CloudLogEvent] = entries.compactMap { ... }   // existing
let eventsToUpload = applyIngestionFilter(events)          // NEW
let batches = buildBatches(events: eventsToUpload)         // existing
```

- **Drop:** remove events that match high-volume or low-value patterns (optionally with time-based throttling).
- **Trim:** for events that match "verbose" patterns, shorten `message` and optionally `raw` before upload (local file already has full content).

All logic lives in the uploader (or a small helper type the uploader calls). No changes to app log call sites, SimpleLogReporter, or Logger.

---

## Implementation options

### Option A — Logic inside `CloudLogUploader` (recommended)

Add to **CloudLogUploader.swift**:

1. **Throttle state** (inside the actor, so thread-safe):
   - e.g. `private var ingestionThrottleLastSent: [String: Date]` for pattern-based "at most one per N seconds" rules.

2. **Filter function** (private):
   - `private func applyIngestionFilter(events: [CloudLogEvent], now: Date) -> [CloudLogEvent]`
   - Returns a new array: some events dropped, some with trimmed `message`/`raw`.
   - For throttle rules: if an event matches a throttled pattern and we've already "sent" one for that pattern within the interval, **drop** it; otherwise keep it and update `ingestionThrottleLastSent[pattern] = now`.
   - For trim rules: if `event.message` matches a verbose pattern (e.g. prefix `"Watch received data"`) and length > cap, replace with a shortened message and set `raw: nil` or a short summary.

3. **Call site:** in `uploadNewContent`, after building `events`:
   - `let eventsToUpload = applyIngestionFilter(events, now: Date())`
   - Use `eventsToUpload` in `buildBatches` and for upload.

**Pros:** One place for all ingestion rules; state lives in the existing actor.  
**Cons:** Uploader file grows; rules are in code (could later move to a small config if needed).

---

### Option B — Dedicated `CloudLogIngestionFilter` type

New file **CloudLogIngestionFilter.swift**:

- **Stateless rules:** e.g. "drop if message contains X", "trim message to N chars if contains Y".
- **Stateful throttle:** filter holds `var lastSent: [String: Date]` and an `apply(events: [CloudLogEvent], now: Date) -> [CloudLogEvent]` method. The uploader calls it and, if we want state to persist across upload runs, the uploader passes state in/out or the filter is held as a property of the uploader (actor) so it's not recreated each time.

Then in **CloudLogUploader**:

- Add `private let ingestionFilter = CloudLogIngestionFilter()` (or with config).
- In `uploadNewContent`: `let eventsToUpload = ingestionFilter.apply(events, now: Date())`.

**Pros:** Clear separation; easy to unit test the filter.  
**Cons:** Throttle state must live somewhere (uploader or filter); one more type to maintain.

---

### Option C — Wrapper provider

Create **FilteringCloudLogProvider: CloudLogProvider** that wraps the real provider:

- `upload(events:)` → filter/trim `events` → `inner.upload(events: filtered)`.
- Filter and throttle state live in the wrapper.

**Pros:** Uploader stays untouched; all ingestion rules in one wrapper.  
**Cons:** Throttle state is updated only when we actually call `inner.upload` (per batch), so "last sent" is per batch, not per event — still reasonable for "at most N per minute" style rules if we consider each batch as a time slice.

---

## Recommended: Option A with clear rule list

Implement **Option A** inside **CloudLogUploader**, with a small set of rules derived from the Better Stack analysis. Keep rules in one place (e.g. a private struct or enum) so they're easy to tune.

### Rule 1 — Throttle OpenAPS Dynamic ISF prediction lines

- **Match:** `message` contains `"Dynamic ISF (Logarithmic Formula)"` and either `"adjusted predictions for IOB and ZT"` or `"adjusted prediction for UAM"`.
- **Action:** Keep at most **one per 60 seconds** per sub-type (IOB_ZT vs UAM). Drop the rest.
- **Impact:** Most of the ~17 MB/day from these two patterns.

### Rule 2 — Throttle PersistedProperty success

- **Match:** `message` matches pattern like `"✅ [PersistedProperty:...] Saved value successfully."` (e.g. regex or `contains`).
- **Action:** Keep at most **one per 10 minutes per key** (key = PersistedProperty name), or **drop all** if you don't need these in the cloud.
- **Impact:** Most of the ~5.7 MB/day from Storage category.

### Rule 3 — Trim "Watch received data" blobs

- **Match:** `message` has prefix `"Watch received data"` and length > 500 (or 1000) chars.
- **Action:** Replace with e.g. `"Watch received data: [trimmed, \(originalCount) chars]"` and set `raw = nil` (or a short fixed string) so the huge payload isn't sent.
- **Impact:** Large per-event savings when this fires (each can be 30 KB+).

### Rule 4 — Trim very long storage/error messages

- **Match:** `message` contains `"Failed to retrieve file"` or similar and length > 300.
- **Action:** Truncate to 300 chars (or 200) and set `raw = nil` to avoid full path/UserInfo in cloud.
- **Impact:** Moderate; reduces size of the biggest storage error lines.

### Rule 5 (optional) — Throttle short autosens lines

- **Match:** `message` matches `"autosens.js:"` and the rest is very short (e.g. ≤ 15 chars, like `"2g"`).
- **Action:** At most one per 60 seconds.
- **Impact:** Saves ~0.5–1 MB/day.

---

## Throttle state and "now"

- **Per run:** For each call to `uploadNewContent`, pass `Date()` as `now`. Update throttle state only when we **keep** an event (so "last sent" is the time we decided to keep one).
- **Persistence:** Throttle state can be in-memory only (`private var` in the actor). After app restart we might send a few extra events until the 60s window fills again; that's acceptable and avoids persistence complexity.
- **Per pattern key:** Use a key like `"openaps:IOB_ZT"`, `"openaps:UAM"`, `"storage:PersistedProperty"`, `"autosens:short"` so different rules don't interfere.

---

## Lower bound for trimming (avoid breaking search)

- Keep **message** long enough that Better Stack search (e.g. by category, level, or a short substring) still works. For "Watch received data", 200–500 chars of summary (e.g. "Watch received data: keys=watchState, currentGlucose=109") is enough.
- Trimming **raw** to `nil` or a short string is fine; the main searchable content is in **message**.

---

## Patch placement

- If cloud logging lives only in **06-cloud-logging.patch**: add the filter step and throttle state inside that patch (in **CloudLogUploader.swift**).
- If you prefer to keep 06 as-is: add a **new patch** (e.g. **10-betterstack-ingestion-filter.patch**) that introduces **CloudLogIngestionFilter** and wires it into the uploader (or that patches **CloudLogUploader** to add `applyIngestionFilter` and the call site). That way ingestion tuning can be updated without touching the rest of the cloud logging patch.

---

## Summary

| Item | Recommendation |
|------|----------------|
| **Where** | Better Stack ingestion pipeline only (CloudLogUploader or a small filter type it uses). |
| **Local logging** | No changes to Logger, debug/info/warning, or file writing. |
| **Mechanisms** | Drop (with optional throttle) + trim message/raw for known high-volume/verbose patterns. |
| **State** | In-memory throttle state inside the uploader actor; keyed by pattern. |
| **Expected impact** | ~10–25% daily volume reduction (on the order of ~6–20 MB/day depending on current volume). |

Implementing **Option A** with Rules 1–4 (and optionally 5) gives a single, clear place to tune Better Stack volume without touching the rest of the app.
