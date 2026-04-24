# Complication Freshness — Key File Reference

**Version:** 1.1
**Created:** 2026-03-19 11:30 CET
**Last updated:** 2026-04-08 22:26 CET

All line numbers are approximate — verify before implementing.

---

| Symbol | File | Approx. line | Notes |
|---|---|---|---|
| `watchStateToDictionary` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~474 | `"date"` key = build time, not CGM reading time — see R3 comment guidance |
| `sendDataToWatch` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~545 | Reading epoch computed here (~573) for logging only — not in dict |
| `scheduleWatchStateUpdate` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~517 | `private` on `final class BaseWatchManager`; debounce hardcoded ~529 |
| Publisher subscriptions | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | 85, 92, 103, 110, 123, 129, 1531, 1543 | 8 total call sites |
| `WatchState` (iOS model) | `Trio/Sources/Models/WatchState.swift` | 4-13 | `currentGlucose: String?`, `trend: String?`, `delta: String?` |
| `WatchMessageKeys` | `Trio/Sources/Models/WatchMessageKeys.swift` | — | String key constants; new keys added here |
| `ComplicationSnapshotFingerprint` | `Trio Watch Shared/TrioComplicationDataStore.swift` | — | Defined in FP-Plan; implemented FP-Phase 3.0; watch extension target only |
| `processRawDataForWatchState` | `Trio Watch App Extension/WatchState.swift` | ~542 | Extracts dict keys; builds `TrioComplicationSnapshot` |
| `saveComplicationSnapshot` | `Trio Watch App Extension/WatchState.swift` | ~664 | Calls `TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)` |
| `didReceiveUserInfo` | `Trio Watch App Extension/WatchState.swift` | ~286 | Watch app extension process; participates in `lastDataReceivedAt` / R5d gap path (verify line in tree) |
| `didReceiveMessage` | `Trio Watch App Extension/WatchState.swift` | ~230 | Watch app extension process |
| `lastDataReceivedAt` | `Trio Watch App Extension/WatchState.swift` | — | Renamed from `lastUserInfoReceivedAt` (R5d, build 143); **App Group–backed** for gap detection across restarts; updated from both `didReceiveUserInfo` and `didReceiveApplicationContext` |
| `saveOnMain` | `Trio Watch Shared/TrioComplicationDataStore.swift` | ~507 | Authoritative dedup gate from FP-Phase 3.1 |
| `save(_ snapshot:)` | `Trio Watch Shared/TrioComplicationDataStore.swift` | ~581 | Accepts `TrioComplicationSnapshot` directly |
| `fetchGlucose` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~415 | Fetches up to 288 entries (limit at ~422) |
| `getTimeline` | `Trio Watch Complication/TrioWatchComplication.swift` | ~152 | WidgetKit process — no WCSession access; reads App Group only |
| `sessionIsReadyForTransfer()` | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | ~845 | Shared helper (shipped build 132 with R1b); used by R1b and R4 |

---

## Changelog

### v1.1 (2026-04-08 22:26 CET)
- **Symbols:** Replaced obsolete `lastUserInfoReceivedAt` row with shipped `lastDataReceivedAt` (R5d, App Group persistence). Updated `didReceiveUserInfo` note.
- Reason: table had pre-143 state; line numbers were already approximate.

### v1.0 (2026-03-19 11:30 CET)
- Initial creation: extracted key file reference table from remediation plan.
- Reason: provide a standalone code symbol lookup as part of the docs reorganization.
