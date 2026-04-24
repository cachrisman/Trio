# Design: Meal Photo Nutrition Autofill

**Version:** v1.1
**Created:** 2026-03-22
**Last updated:** 2026-03-22
**Status:** Proposed

Ideas: [ideas.md](ideas.md)
Implementation plan: [implementation-plan.md](implementation-plan.md)

---

## Problem

Users on the AddCarbs screen manually estimate carbs, fat, and protein from memory. This is error-prone for mixed meals, restaurant portions, and anything with hidden fat. Estimation errors propagate directly into bolus calculations and loop performance. The user's phone is already in hand at bolus time — photo capture is a low-friction opportunity to improve estimate quality.

---

## Context / Current State

- AddCarbs is an existing SwiftUI screen in Trio. It accepts numeric input for carbs, fat, and protein.
- No image capture or AI integration exists anywhere in Trio.
- Trio uses MVVM architecture, Swinject for dependency injection, and an existing `Keychain` wrapper for secret storage.
- OpenAI's `gpt-4o` model supports vision inputs via the `/v1/chat/completions` endpoint using base64-encoded images.

---

## Constraints / Requirements

- **Platform:** iOS, Swift, SwiftUI. MVVM. Swinject. Keychain for secrets.
- **No image persistence:** The image must not be written to disk, stored in any database, sent to any service other than OpenAI, or retained after the API response is received.
- **User consent:** The user must be informed that their image is sent to OpenAI before the first use. This disclosure must appear in the confirmation dialog or a preceding onboarding step.
- **AI values are suggestions:** Pre-populated fields must remain editable. There is no auto-save on AI response.
- **Graceful degradation:** If no API key is configured, or the API call fails, the user continues with manual entry. No crashes, no silent failures.
- **User-supplied API key:** No app-managed OpenAI billing. Key stored in Keychain.

---

## Decision

### Recommended Approach

Build a self-contained, opt-in photo analysis path inside the existing AddCarbs screen. Four new components:

1. **`OpenAIConfig` module** — Keychain-backed API key storage with a dedicated Settings UI screen.
2. **`OpenAIVisionService`** — stateless `async`-based service that accepts a `UIImage`, encodes to base64, POSTs to `/v1/chat/completions`, and returns a typed `MacroEstimate`.
3. **`ImagePicker`** — SwiftUI-compatible wrapper over `PHPickerViewController` (library) and `UIImagePickerController` (camera).
4. **AddCarbs modifications** — "Analyze Meal Photo" button, `.confirmationDialog`, state variables, `.onChange` trigger, spinner, and error display.

Image lifecycle: capture in memory → resize → base64 encode → POST to OpenAI → receive response → populate fields → **discard**. No disk writes at any stage.

### Why This Approach

- Keeping the feature inside AddCarbs (rather than a separate screen) minimises navigation steps for on-the-go use.
- User-supplied API key avoids any server-side billing or key management complexity for the Trio project.
- Stateless `OpenAIVisionService` is trivially unit-testable and replaceable if the provider changes.
- Swift `async/await` throughout keeps concurrency readable and avoids callback nesting.

---

## Functional Behavior

### User Flows

**Happy path:**
1. User taps "Analyze Meal Photo."
2. `.confirmationDialog` offers "Take Photo" / "Choose from Library." Copy includes disclosure that image will be sent to OpenAI.
3. `ImagePicker` sheet presented.
4. On image selection, `mealImage` binding is set.
5. `.onChange(of: mealImage)` fires → `isAnalyzingPhoto = true` → `stateModel.analyzeMealPhoto()` called via `Task {}`.
6. `OpenAIVisionService` POSTs base64 image to OpenAI.
7. Response parsed → `carbs`, `fat`, `protein` on `StateModel` populated.
8. `isAnalyzingPhoto = false`, `mealImage = nil`, form fields updated.
9. User reviews, edits if needed, saves normally.

**No API key configured:**
- Button visible but disabled with subtitle: "Configure API key in Settings → AI Features."

**API error / timeout:**
- `visionError: String?` set on `StateModel` → displayed as inline error text below the button.
- Existing field values unchanged.

**Partial response (model returns only some fields):**
- Populate only fields present in the parsed response. Others retain their prior values.

**User dismisses picker without selecting:**
- `mealImage` remains `nil`. `.onChange` does not fire. No spinner, no error.

### Data Model

```swift
struct MacroEstimate {
    let carbs: Float?
    let fat: Float?
    let protein: Float?
}
```

OpenAI prompt requests:
```json
{ "carbs": <float grams>, "fat": <float grams>, "protein": <float grams> }
```

System prompt (draft): *"You are a nutrition estimator. Respond only with a valid JSON object with keys carbs, fat, and protein as floats representing grams. No explanation, no markdown, no additional keys."*

Model: `gpt-4o`. Stored as a named constant in `OpenAIVisionService`. Not user-configurable at MVP.

### State Additions to AddCarbs.RootView

```swift
@State private var mealImage: UIImage?
@State private var isAnalyzingPhoto = false
@State private var visionError: String?
@State private var showImageSourceDialog = false
```

### Service Interface

```swift
protocol VisionService {
    func analyzeMeal(image: UIImage, apiKey: String) async throws -> MacroEstimate
}
```

Error cases:
```swift
enum VisionServiceError: Error {
    case unauthorized       // 401
    case rateLimited        // 429
    case parseError         // non-JSON or unexpected schema
    case networkUnavailable // URLError
    case unknown(Int)       // other HTTP status
}
```

### OpenAIConfig Module

- `OpenAIConfigDataFlow.swift` — protocol defining `apiKey: String?`, `saveAPIKey(_:)`, `deleteAPIKey()`. Keychain key constant.
- `OpenAIConfig.StateModel.swift` — `ObservableObject`. Reads/writes key via `Keychain`. `@Published var apiKeyIsSet: Bool`. Key never cached in a `@Published` property — Keychain is the source of truth.
- `OpenAIConfigRootView.swift` — Settings UI. Masked display when key present ("API key configured ✓"). "Replace" reveals `SecureField`. "Delete" requires confirmation. Save button appears only when field value differs from stored state. Visual feedback (brief checkmark) on save/delete.

### Edge Cases

| Scenario | Behavior |
|---|---|
| No API key | Button disabled, hint shown. No network call. |
| Network unavailable | `.networkUnavailable` error → inline error message |
| OpenAI returns 401 | `.unauthorized` → "Invalid API key. Check Settings → AI Features." |
| OpenAI returns 429 | `.rateLimited` → "Rate limited. Wait a moment and try again." |
| Non-JSON response body | `.parseError` → "Could not read AI response. Try again." |
| Camera unavailable (simulator) | `ImagePicker` falls back to photo library |
| User taps Save mid-analysis | Save proceeds with current field values; analysis result applied if it completes before save fires |

### Non-Functional

- **Latency:** Target < 5s end-to-end. `ProgressView` shown during analysis. Fields remain editable while waiting.
- **Image size:** Resize to max 1024px longest side before encoding. Reduces token cost and upload time with negligible accuracy impact.
- **Privacy:** Image encoded in memory only. Never passed to `FileManager`, `UserDefaults`, Core Data, or any logging system.
- **Accessibility:** "Analyze Meal Photo" button has `accessibilityLabel`. `ProgressView` has `accessibilityHint`. Error text is in an accessible element. Confirmation dialog copy is readable by VoiceOver.
- **Single retry:** One automatic retry on network timeout, 500ms delay. No retry on 401/429.

### Observability

Log events emitted via existing Trio logging infrastructure. No image data or API key values in any log event.

| Event | Fields |
|---|---|
| `meal_photo_analysis_started` | `timestamp` |
| `meal_photo_analysis_completed` | `duration_ms`, `carbs_populated: Bool`, `fat_populated: Bool`, `protein_populated: Bool` |
| `meal_photo_analysis_failed` | `error_type: String` (no PII) |
| `meal_photo_values_edited` | fired when user modifies an AI-populated field before saving (enables future accuracy tracking) |

### Rollout / Backward Compatibility

- Fully additive — zero changes to existing AddCarbs behavior.
- If `VisionService` is not registered in Swinject (e.g., API key absent), button is hidden or disabled.
- No schema changes to existing Trio data models for MVP.
- Fat and protein fields already exist in AddCarbs — no new persistent fields required.

---

## Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| On-device Core ML nutrition model | No suitable general-food model available; high maintenance burden; accuracy below GPT-4o for diverse foods |
| Nightscout-proxied AI call (phone → NS → OpenAI) | Adds latency, requires NS reachable, complicates key management — no benefit for this use case |
| Store image in S3, send URL to OpenAI | Adds storage/retention/privacy complexity; unnecessary since OpenAI accepts inline base64 |
| Separate "Analyze Meal" screen | Extra navigation step; worse for on-the-go use |
| Completion-handler API instead of async/await | Inconsistent with modern Swift concurrency adopted elsewhere in Trio |

---

## Risks / Open Questions

1. **Prompt reliability.** The exact system prompt affects how consistently the model returns clean JSON. Needs testing across diverse meal photos (different cuisines, lighting, portion sizes) before shipping.
2. **Non-Western food accuracy.** GPT-4o performance varies by cuisine. Consider a UI disclaimer for initial release.
3. **API key UX for non-technical users.** If a key expires or is revoked, the error message must be comprehensible without technical knowledge.
4. **Fat/protein field naming.** Confirm AddCarbs field names map correctly to Nightscout treatment record fields (relevant for Area 3 meal analysis).

---

## Success Criteria

- User can capture or select a meal photo and receive carbs/fat/protein estimates within 5 seconds on a standard mobile connection.
- All three fields populated correctly from a well-formed JSON response.
- API errors surface as readable inline messages — no crashes, no silent failures.
- Image is provably not written to disk (verifiable in unit test via `FileManager` inspection).
- Feature is fully inert when no API key is configured.
- Zero regressions to existing AddCarbs manual entry flow.

---

## Changelog

### v1.1 (2026-03-22)
- Red team pass. Medical/regulatory and App Store review concerns removed — Trio is a DIY sideloaded app; these do not apply.
- No structural design changes required.

### v1.0 (2026-03-22)
- Initial design created.
