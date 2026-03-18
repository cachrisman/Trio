# Better Stack Log Volume & VRL Filter Candidates

> Version 1.4 — 2026-03-16

Investigation of Trio log ingestion volume and VRL-based filtering options to stay under the 5 GB/month cap without requiring an app redeploy.

---

## 1. Usage and cap

- **Plan:** 5 GB/month; ingestion stops when the cap is reached.
- **Daily equivalent:** 5,000 MB ÷ 30 ≈ **166 MB/day**.
- **Your data:** Many days in Jan–Mar exceed that (e.g. 200–330 MB/day; some spikes to ~500–800 MB). So you are often over the sustainable rate and will hit the cap at current pace.
- **Source:** Trio is the main consumer; nightscout-chrisman-io is relatively stable (~50 MB/day).

### March projection (first 15 days, Mar 1–15)

| Source | Mar 1–15 total | Avg/day | Projected March (31 days) |
|--------|----------------|---------|----------------------------|
| **Trio** | 2,347.5 MB (~2.35 GB) | 156.5 MB | **~4.85 GB** |
| **nightscout-chrisman-io** | 751.8 MB | 50.1 MB | **~1.55 GB** |
| **Combined** | 3,099.3 MB (~3.1 GB) | 206.6 MB | **~6.4 GB** |

The 5 GB cap applies to **combined** ingestion. At the current 15-day average, projected March total is **~6.4 GB**, so you would exceed the cap by ~1.4 GB unless volume drops or VRL filters reduce Trio (and optionally Nightscout) ingestion.

### March remainder math (filters applied mid‑month)

If you apply **nightscout-chrisman-io drop-all** and **Trio filters #1–#8** from ~Mar 16 for the rest of March:

| Levers | Est. savings (remainder of March) |
|--------|-----------------------------------|
| **Over budget (no filters)** | ~1.4 GB |
| Drop **nightscout-chrisman-io** (all logs) | 50 MB/day × 16 days ≈ **~800 MB** (you said ~700 MB; 50×14 ≈ 700) |
| Trio **#1–#8** (targeted drops) | 308 MB/**month** → for 16 days: 308 × (16/31) ≈ **~159 MB** |
| **Still over** | 1,400 − 700 − 159 ≈ **541 MB** (or 1,400 − 800 − 159 ≈ 441 MB) |

So you end up **~400–540 MB over** the cap, i.e. **about 2–3 days** of logs at 206.6 MB/day combined. That’s acceptable if you’re okay with ingestion stopping a few days before month-end; April is on a much better footing with both levers in place. **Note:** 308 MB is the *monthly* savings for Trio #1–#8; for the remainder of March you only get the prorated ~159 MB.

---

## 2. VRL transformation (ingestion-time)

Better Stack applies **VRL (Vector Remap Language)** to each event **before** it is stored. Changes there:

- Reduce **ingestion volume** (and cost) without touching the app.
- Can **drop** events, **remove** fields, or **truncate** messages.
- Are configurable in: **Sources → [Trio source] → Configure → Transform** (or **Transformations** tab).

Docs: [Transforming ingested logs with VRL](https://betterstack.com/docs/logs/using-logtail/transforming-ingested-data/logs-vrl/).

Important: use **Test transformation** with sample JSON from your logs to confirm behavior. The event shape is the JSON your app sends (e.g. `message`, `level`, `category`, `dt`, etc.).

---

## 3. What the app already does (no change needed there)

The Trio cloud logging pipeline already:

- Drops **PersistedProperty "Saved value successfully"**.
- Throttles **OpenAPS Dynamic ISF** prediction lines (1 per 60 s per subtype).
- Throttles short **autosens.js** lines.
- Trims **"Watch received data"** (drops `glucoseValues = (...)` and similar).
- Trims long **"Failed to retrieve file"** messages.
- Truncates message size at **256 KB** per event.

So the biggest remaining wins are from events that are **not** filtered or trimmed in the app today. Below are candidates for **VRL-only** filtering, ordered by estimated impact on ingestion volume.

---

## 4. High-impact VRL filter candidates (by ingestion volume)

Based on a 1-hour sample of Trio logs (hot buffer): **~1.25 MB/h**, **~1,930 events**. About **88% of bytes** were **debug** level. Top patterns by **bytes** and representative **message** / **category** are below. Implement in VRL in order; test after each change.

**Monthly savings assumption:** Volume per hour from the 1h sample is extrapolated to a month as **KB/h × 24 h × 30 days = MB/month** (e.g. 150 KB/h → 108 MB/month). Actual savings will vary with usage; treat these as order-of-magnitude estimates.

### 4a. In-depth analysis (24h historical, S3)

A **24-hour** window was queried from **S3** (historical tier) to check whether the 1h hot-buffer snapshot is representative.

**24h totals (Trio):** 94,189 events, 60,098,057 bytes (**~60.1 MB**). Average rate **~2.5 MB/h** (vs 1h hot sample **~1.25 MB/h** — the 1h sample was a quieter hour; 24h includes more variable activity).

**Top patterns by bytes (24h), with identified message type:**

| Rank | Bytes (24h) | Identified pattern (sample message) |
|------|-------------|-------------------------------------|
| 1 | 6.22 MB | **To be uploaded openapsStatus** (Nightscout) |
| 2 | 2.91 MB | **meal.js: Warning: clock input Invalid Date** (OpenAPS) |
| 3 | 2.82 MB | **Storing X new pump events** (DeviceManager) |
| 4 | 2.16 MB | **coalescer_trigger** (WatchManager) |
| 5 | 1.63 MB | **Device message:** (DeviceManager) |
| 6 | 1.56 MB | **OREF DETERMINATION:** (OpenAPS) |
| 7 | 1.42 MB | **[LiveActivityManager] Updating current activity** (Default) |
| 8 | 1.28 MB | **New pump status Basal:** (DeviceManager) |
| 9 | 1.24 MB | **determine_basal.js: CR:…** (OpenAPS) |
| 10 | 1.07 MB | **Treatments uploaded** (Nightscout) |
| 11 | 1.03 MB | **complication_budget_check** (WatchManager) |
| 12 | 903 KB | CGM Manager did update state (DeviceManager) |
| 13 | 818 KB | **PLUGIN CGM - Process CGM Reading Result** (DeviceManager) |
| … | … | (coalescer_fired, Watch not reachable, Duplicate event, etc.) |

**Category breakdown (24h):** OpenAPS 13.4 MB, DeviceManager 11.6 MB, Nightscout 10.4 MB, WatchManager 7.9 MB, Default 5.9 MB, WatchState 2.6 MB, ApsManager 2.4 MB, ExtensionDelegate 2.0 MB, Service 2.0 MB, CoreData 0.77 MB, Storage 0.56 MB, … Same category ordering as 1h.

**Level breakdown (24h):** debug **46.5 MB (77%)**, empty 5.0 MB, info 5.0 MB, warn 3.1 MB, error 0.56 MB. Again debug dominates; 1h had ~88% debug.

**Does the 24h analysis match the 1h?** **Yes.** The same patterns dominate in both windows; only the order of #2–#4 shifts slightly (meal.js, pump events, coalescer_trigger). All of the VRL filter candidates (#1–#8 and the WatchManager/complication patterns) appear in the 24h top-15 by bytes. The 1h snapshot was slightly quieter (~1.25 MB/h vs 24h average ~2.5 MB/h), so the earlier **monthly** savings estimates (based on 1h) are conservative if your typical day looks like the 24h average; if the 1h hour was more typical, they remain in the right ballpark.

---

### 1. Drop or truncate **"To be uploaded openapsStatus"** (largest single pattern)

- **Category:** Nightscout, **level:** debug.
- **Sample:** `To be uploaded openapsStatus: OpenAPSStatus(iob: Optional(...), suggested: Optional(...), enacted: Optional(...), version: "0.6.0", ...)`.
- **Volume (1h):** ~150 KB (17 events, ~8.8 KB each).
- **Est. monthly savings:** 150 KB/h × 24 × 30 ≈ **108 MB/month**.
- **Impact:** Very high (one of the biggest single patterns).

**VRL – drop entirely (recommended first):**

```vrl
# Drop full openaps status dumps (already in Nightscout; not needed in logs).
if exists(.message) && starts_with(string!(.message), "To be uploaded openapsStatus") {
    del(.)
}
```

**VRL – keep a short line instead of dropping:**

```vrl
# Truncate to first ~120 chars (removes IOB/predictions dump).
if exists(.message) && starts_with(string!(.message), "To be uploaded openapsStatus") {
    .message = slice(string!(.message), 0, 120) + "… [truncated]"
}
```

Use **slice** only if your VRL version supports it; otherwise prefer **drop**.

---

### 2. Drop **"Storing 1 new pump events"** (full LoopKit dumps)

- **Category:** DeviceManager, **level:** debug.
- **Sample:** `Storing 1 new pump events: [LoopKit.NewPumpEvent(date: ..., dose: Optional(...), ...)]`.
- **Volume (1h):** ~63 KB (23 events).
- **Est. monthly savings:** 63 KB/h × 24 × 30 ≈ **45 MB/month**.
- **Impact:** High.

**VRL:**

```vrl
if exists(.message) && contains(string!(.message), "Storing 1 new pump events") {
    del(.)
}
```

---

### 3. Throttle or drop **"meal.js: Warning: clock input Invalid Date"**

- **Category:** OpenAPS, **level:** warn.
- **Volume (1h):** ~52 KB (99 events).
- **Est. monthly savings:** 52 KB/h × 24 × 30 ≈ **37 MB/month**.
- **Impact:** High (repetitive warning).

**VRL – drop all (cleanest):**

```vrl
if exists(.message) && contains(string!(.message), "meal.js: Warning: clock input Invalid Date") {
    del(.)
}
```

If you need to keep a few for debugging, VRL cannot do in-process throttling by time; you’d keep them and optionally truncate, or add throttling in the app later.

---

### 4. Drop or truncate **"coalescer_trigger"** (WatchManager debug)

- **Sample:** `⏱️ coalescer_trigger source=glucoseStored eligible=true pending=true`.
- **Category:** WatchManager, **level:** debug.
- **Volume (1h):** ~42 KB (80 events).
- **Est. monthly savings:** 42 KB/h × 24 × 30 ≈ **30 MB/month**.
- **Impact:** Medium–high.

**VRL:**

```vrl
if exists(.message) && contains(string!(.message), "coalescer_trigger") {
    del(.)
}
```

---

### 5. Drop **"New pump status Basal:"** / **"New pump status Bolus:"** (DeviceManager debug)

- **Sample:** `New pump status Basal: Optional(LoopKit.PumpManagerStatus.BasalDeliveryState.active(...))`.
- **Volume (1h):** ~34 KB (Basal) + ~12 KB (Bolus) ≈ 46 KB.
- **Est. monthly savings:** 46 KB/h × 24 × 30 ≈ **33 MB/month**.
- **Impact:** Medium.

**VRL:**

```vrl
if exists(.message) && (contains(string!(.message), "New pump status Basal:") || contains(string!(.message), "New pump status Bolus:")) {
    del(.)
}
```

---

### 6. Drop **"PLUGIN CGM - Process CGM Reading Result launched with newData"** (DeviceManager debug)

- **Sample:** Long line with `LoopKit.NewGlucoseSample(...)`.
- **Volume (1h):** ~25 KB (18 events).
- **Est. monthly savings:** 25 KB/h × 24 × 30 ≈ **18 MB/month**.
- **Impact:** Medium.

**VRL:**

```vrl
if exists(.message) && contains(string!(.message), "PLUGIN CGM - Process CGM Reading Result launched with newData") {
    del(.)
}
```

---

### 7. Drop **"[LiveActivityManager] Updating current activity:"** (Default debug)

- **Sample:** `[LiveActivityManager] Updating current activity: 849AC0A4-3A8F-4FE0-...`.
- **Volume (1h):** ~27 KB (54 events).
- **Est. monthly savings:** 27 KB/h × 24 × 30 ≈ **19 MB/month**.
- **Impact:** Medium.

**VRL:**

```vrl
if exists(.message) && contains(string!(.message), "[LiveActivityManager] Updating current activity:") {
    del(.)
}
```

---

### 8. Drop **"OREF DETERMINATION:"** (OpenAPS debug, few events but very large)

- **Sample:** ` OREF DETERMINATION: |` (then huge payload).
- **Volume (1h):** ~25 KB (9 events, ~2.8 KB each).
- **Est. monthly savings:** 25 KB/h × 24 × 30 ≈ **18 MB/month**.
- **Impact:** Medium.

**VRL:**

```vrl
if exists(.message) && contains(string!(.message), "OREF DETERMINATION:") {
    del(.)
}
```

---

### 9. Drop high-frequency **WatchManager** debug lines (complication/coalescer)

- **Examples:** `complication_budget_check`, `complication_age_check`, `complication_transfer_age_gate_skipped`, `coalescer_fired`, `Transferred new WatchState snapshot`.
- **Volume (1h):** ~60–65 KB combined (from pattern bytes in sample).
- **Est. monthly savings:** ~63 KB/h × 24 × 30 ≈ **45 MB/month**.
- **Impact:** Low–medium.

**VRL (example – adjust prefixes to match):**

```vrl
if exists(.message) && exists(.category) && string!(.category) == "WatchManager" && string!(.level) == "debug" {
    msg = string!(.message)
    if starts_with(msg, "🔍 complication_budget_check") || starts_with(msg, "🔍 complication_age_check") || starts_with(msg, "⏭️ complication_transfer_age_gate_skipped") || starts_with(msg, "📡 coalescer_fired") || starts_with(msg, "📤 Transferred new WatchState snapshot") {
        del(.)
    }
}
```

(Use `starts_with` / `contains` as in your VRL docs; exact function names may differ.)

---

### 10. Nuclear option: drop all **debug** level

- **Volume (1h):** ~1.1 MB of ~1.25 MB (≈88% of bytes).
- **Est. monthly savings:** 1.1 MB/h × 24 × 30 ≈ **792 MB/month**.
- **Impact:** Very high; you lose all debug context.

**VRL:**

```vrl
if exists(.level) && string!(.level) == "debug" {
    del(.)
}
```

Use only if you are sure you don’t need debug in Better Stack; otherwise prefer targeted drops (1–9) so you keep errors, warns, and some info.

---

## 5. Suggested order of implementation

1. **#1 – "To be uploaded openapsStatus"** (drop).
2. **#2 – "Storing 1 new pump events"** (drop).
3. **#3 – meal.js clock warning** (drop).
4. **#4 – coalescer_trigger** (drop).
5. **#5 – New pump status Basal/Bolus** (drop).
6. **#6 – PLUGIN CGM Process CGM Reading Result** (drop).
7. **#7 – LiveActivityManager Updating current activity** (drop).
8. **#8 – OREF DETERMINATION** (drop).
9. **#9 – WatchManager complication/coalescer** (drop by prefix/category/level).
10. Only if still over cap: consider **#10 – drop all debug** or add **message truncation** (e.g. cap `.message` at 500–1000 chars for retained events).

**Cumulative est. monthly savings (targeted filters #1–#9 only):** 108 + 45 + 37 + 30 + 33 + 18 + 19 + 18 + 45 ≈ **353 MB/month**. That’s about 2.1 days’ worth of cap (166 MB/day). Adding #10 would save another ~792 MB but removes all debug.

**#1–#8 only (skip #9 during active WatchManager/complication work):** 108 + 45 + 37 + 30 + 33 + 18 + 19 + 18 = **308 MB/month**.

---

## 5b. nightscout-chrisman-io: blanket drop (optional)

Sampled **nightscout-chrisman-io** (1h): **~1.5 MB**, **~7,100 events**. Content is mostly:

- **Heroku-style request logs:** `at=info method=GET path="/api/v1/entries.json?..."` (hundreds per hour).
- **Dyno memory/load samples:** `source=web.1 dyno=... sample#memory_total=... sample#load_avg_1m=...`.
- **YAML-like snippets:** `created_at: '...'`, `eventType: 'Sensor Start'`, `enteredBy: 'Trio'`, `carbs: 1.6`, heartbeat/entries/devicestatus timestamps.

There are no obvious high-value *targeted* exclusions; the volume is spread across many small request and metrics lines. If you don’t use this source in Better Stack, a **blanket drop-all** is the simplest way to save **~50 MB/day** (~**700–800 MB** for the remainder of March from ~Mar 16).

**VRL for nightscout-chrisman-io source (drop all events):**

```vrl
# Drop all logs for this source (not used in Better Stack; saves ~50 MB/day).
del(.)
```

Apply this in **Sources → nightscout-chrisman-io → Configure → Transform**. One line is enough: every event is dropped before storage.

---

## 6. VRL syntax notes

- **Drop event:** `del(.)`.
- **Remove a field:** `del(.message)` or `del(.some_nested_field)`.
- **Conditionals:** `if exists(.message) { ... }`, `string!(.message)` when the field is required.
- **String checks:** `starts_with(..., "prefix")`, `contains(..., "substring")` (names may vary; see [VRL docs](https://vrl.dev)).
- **Truncation:** If supported, e.g. `.message = slice(string!(.message), 0, 500)`; otherwise drop the event or keep as-is.
- **Errors:** Prefer non-failing checks (e.g. `exists(.level)`) and avoid `!` on optional fields so a missing field doesn’t break the pipeline. Failed transforms can leave events in Logs with `_ingest.error` / `_ingest.transform_error` for debugging.

---

## 7. How to test

1. In Better Stack: **Sources → Trio → Configure → Transform**.
2. Paste one of the VRL snippets above (or a small combination).
3. In **Input JSON**, paste a sample event from your Trio logs (e.g. copy from Logs & traces for a "To be uploaded openapsStatus" line).
4. Run **Try a sample transformation** and check **Output JSON** (or that the event is dropped).
5. Save and monitor **ingestion volume** over the next 24–48 hours; add or relax rules as needed.

---

## Changelog

| Version | Date       | Summary |
|--------|------------|--------|
| 1.0    | 2026-03-16 | Initial investigation: usage math, VRL overview, 10 filter candidates ordered by impact. |
| 1.1    | 2026-03-16 | Added monthly savings assumption (KB/h × 24 × 30 = MB/month) and est. monthly savings per candidate; cumulative ~353 MB for #1–#9, ~792 MB for #10. |
| 1.2    | 2026-03-16 | Added March projection table for Trio and nightscout-chrisman-io (first 15 days); combined ~6.4 GB projected vs 5 GB cap. |
| 1.3    | 2026-03-16 | Added March remainder math (mid-month filters), nightscout-chrisman-io sample + blanket drop-all VRL, and #1–#8-only cumulative (308 MB/month); corrected remainder-of-March Trio savings to prorated ~159 MB. |
| 1.4    | 2026-03-16 | Added 24h S3 in-depth analysis: top patterns, category/level breakdown; confirmed 1h and 24h match (same patterns dominate; 24h avg ~2.5 MB/h vs 1h ~1.25 MB/h). |
