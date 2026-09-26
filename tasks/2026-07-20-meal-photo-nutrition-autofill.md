+++
uid = "019f8141-e117-77db-9216-aae1307eba6a"
key = "TRIO-013"
title = "Implement meal-photo nutrition autofill (OpenAI vision)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/trio-ai-features/README.md#L26"
created = 2026-07-20
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["ai", "feature"]

[[acceptance]]
id = "AC-1"
text = "API keys stored in Keychain only — never `UserDefaults`, never logged, never committed"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Meal photos never persisted — in-memory only for the OpenAI call's duration"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "AI-suggested values remain user-editable before saving"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Graceful degradation when no API key configured or the AI call fails"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "`NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription` added to Info.plist"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Follows existing `BaseStateModel<Provider>`/`BaseView`/`Screen` conventions, `@Injected()` DI, `Decimal` nutrition types"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
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

## Notes carried over from acceptance criteria
