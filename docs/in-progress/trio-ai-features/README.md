# Trio AI Features — Trio Repo Docs

**Version:** v1.2
**Created:** 2026-03-22
**Last updated:** 2026-03-22 15:07 CET
**Repo:** `cachrisman/Trio` (Swift/SwiftUI iOS app)

---

## Scope of This Document Set

This folder contains documentation for the features implemented **inside the Trio iOS repo**. All code described here is Swift/SwiftUI targeting the Trio app.

The Trio AI Features epic spans two repos. The split is:

| Area | Repo | Docs location |
|---|---|---|
| Area 1: Meal Photo Nutrition Autofill | **Trio (here)** | `meal-photo/` |
| Area 2: Richer Settings Upload to Nightscout | Trio — **complete, no active docs** | — |
| Area 3: Nightscout AI Weekly Analysis Report | Nightscout | See `nightscout-repo` zip |

---

## Area 1: Meal Photo Nutrition Autofill

**Status:** Planning
**Branch:** `feature/meal-photo-autofill` (suggested)

When a user opens the AddCarbs screen, they can optionally photograph their meal. The image is sent to OpenAI's vision API, which returns estimated carbs, fat, and protein. Those values pre-populate the form fields. The user reviews, edits if needed, and saves normally. The image is never stored.

**New components:**
- `OpenAIConfig` module — Keychain-backed API key storage + Settings UI (follows Trio's `BaseStateModel<Provider>` / `BaseView` pattern)
- `OpenAIConfigManager` — shared singleton service implementing `OpenAIConfigObservable` for DI across modules
- `OpenAIVisionService` — stateless async service (UIImage → MacroEstimate with `Decimal` fields)
- `ImagePicker` — SwiftUI wrapper over PHPickerViewController / UIImagePickerController
- Modifications to `AddCarbs.RootView` and `AddCarbs.StateModel` (dependencies via `@Injected()`)
- Navigation wiring: `Screen` enum, `SettingItems`, Settings section subview
- `Logger.Category.openAI` for observability

See [`meal-photo/`](meal-photo/) for full ideas, design, and implementation plan.

---

## Area 2: Richer Settings Upload (Complete)

Trio now sends a structured `trioSettings` block with every Nightscout device status update, covering nine categories of clinically relevant algorithm settings. This work is complete. No active documentation in this zip — the Nightscout AI Weekly Report (Area 3) depends on this data being present.

---

## Cross-Cutting Constraints

- **API keys in Keychain only** — never in `UserDefaults`, never in logs, never committed. Keychain API returns `Result<T, KeychainError>` — all call sites handle failures.
- **No image persistence** — meal photos exist in memory only for the duration of the OpenAI API call.
- **AI values are suggestions** — all pre-populated values must remain user-editable before saving.
- **Graceful degradation** — all existing flows work normally when no API key is configured or the AI call fails.
- **iOS plist entries required** — `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` must be present in `Info.plist` before testing on a physical device (sideloaded or TestFlight).
- **Trio architecture conventions** — new modules follow `BaseStateModel<Provider>` / `BaseView` / `Screen` routing. Dependencies via `@Injected()` property wrappers. Nutritional values use `Decimal` (matching `AddCarbs.StateModel` and `CarbsEntry`).

---

## Changelog

### v1.2 (2026-03-22 15:07 CET)
- Red team review: updated component list to reflect Trio architecture (`BaseStateModel`, `@Injected()`, `Decimal` types, navigation wiring, Logger.Category). Added architecture conventions to cross-cutting constraints.

### v1.1 (2026-03-22)
- Restructured from combined epic zip into repo-specific zip. Area 3 moved to nightscout-repo zip.
- Area 2 status noted as complete with no active docs.

### v1.0 (2026-03-22)
- Initial creation.
