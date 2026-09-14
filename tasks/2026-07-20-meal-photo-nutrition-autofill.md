+++
uid = "019f8141-e117-77db-9216-aae1307eba6a"
key = "TRIO-013"
title = "Implement meal-photo nutrition autofill (OpenAI vision)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/trio-ai-features/README.md#L26"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["ai", "feature"]
+++

## Intent

On the AddCarbs screen, let the user optionally photograph their meal. The image is sent to
OpenAI's vision API, which returns estimated carbs/fat/protein to pre-populate the form (user
reviews/edits before saving; image never stored). New components: `OpenAIConfig` (Keychain-backed
key storage + Settings UI), `OpenAIConfigManager` (DI singleton), `OpenAIVisionService` (stateless
UIImage → MacroEstimate), `ImagePicker`, plus `AddCarbs.RootView`/`AddCarbs.StateModel`
modifications and navigation wiring. Full docs: `docs/in-progress/trio-ai-features/meal-photo/`
(ideas → design "Proposed" → implementation plan "Draft"). Suggested branch:
`feature/meal-photo-autofill`.

## Acceptance criteria

- [ ] API keys stored in Keychain only — never `UserDefaults`, never logged, never committed
- [ ] Meal photos never persisted — in-memory only for the OpenAI call's duration
- [ ] AI-suggested values remain user-editable before saving
- [ ] Graceful degradation when no API key configured or the AI call fails
- [ ] `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription` added to Info.plist
- [ ] Follows existing `BaseStateModel<Provider>`/`BaseView`/`Screen` conventions, `@Injected()` DI, `Decimal` nutrition types
