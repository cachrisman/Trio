# Implementation Plan: Meal Photo Nutrition Autofill

**Version:** v1.2
**Created:** 2026-03-22
**Last updated:** 2026-03-22 15:07 CET
**Status:** Draft
**Design reference:** [design.md](design.md)

---

## Scope

- `OpenAIConfig` settings module (Keychain-backed API key storage + Settings UI)
- `MacroEstimate` value type
- `OpenAIVisionService` (image → OpenAI → `MacroEstimate`)
- `ImagePicker` SwiftUI component
- `AddCarbs.RootView` and `AddCarbs.StateModel` modifications
- Swinject DI registrations for new types
- Observability log events

## Out of Scope (post-MVP)

- Text annotation field before sending
- Image preview before sending
- Confidence scoring / uncertainty warnings
- Localization of new strings
- API key validation call (`GET /v1/models`)
- Accuracy feedback tracking beyond basic log events
- Real-time camera analysis mode

## Dependencies

- OpenAI API access (user-supplied key; no Trio-side account required)
- Existing `Keychain` wrapper in Trio
- Existing `AddCarbs.RootView` and `AddCarbs.StateModel`
- Existing Swinject container configuration
- Existing Trio logging infrastructure

---

## Sequencing + Ship Boundaries

| Phase | Content | Shippable alone? |
|---|---|---|
| A | `OpenAIConfig` module — Keychain service + Settings UI + navigation wiring (Tasks A1–A6) | Yes — settings-only, no AddCarbs change |
| B | `MacroEstimate` + `OpenAIVisionService` + `ImagePicker` | No — no UI entry point yet |
| C | `AddCarbs` integration (plist entries, RootView, StateModel) | Requires A + B |
| D | Swinject DI registrations + Logger.Category + observability events (Tasks D1–D3) | Required before any phase ships to users |

**Recommended ship boundary:** All four phases together in a single TestFlight build. Phase separation is for implementation ordering, not staged release.

---

## Shared Conventions

- All new Swift files follow existing Trio naming: `<Module><Role>.swift` (e.g. `OpenAIConfigStateModel.swift`, `OpenAIConfigProvider.swift` — no dots in filenames)
- New modules follow Trio's `BaseStateModel<Provider>` / `BaseView` / `Screen` routing pattern
- Dependencies injected via `@Injected()` property wrappers — not constructor injection
- `async/await` throughout — no completion-handler callbacks in new code
- All Keychain access goes through the existing `Keychain` wrapper (returns `Result<T, KeychainError>`) — no raw `SecItem` calls
- API key never stored in `@Published` property, `UserDefaults`, or any log output
- All log events use the existing Trio `debug(.openAI, ...)` logging infrastructure with new `.openAI` category

---

## Phase A: OpenAIConfig Settings Module

**Ship gate:** Safe alone — adds a Settings entry, no AddCarbs change.
**Rollback:** Remove the Settings navigation entry and assembly registrations. Files can remain.

### Task A1 — OpenAIConfigDataFlow.swift

- **File:** `Trio/Sources/Modules/OpenAIConfig/OpenAIConfigDataFlow.swift` (new)
- **Change:** Define `enum OpenAIConfig {}` namespace, `OpenAIConfigProvider` protocol, `OpenAIConfigObservable` protocol, and Keychain key constant.
- **Steps:**
  1. Create file at path above.
  2. Define `enum OpenAIConfig {}` namespace (Trio convention for module namespacing — see `Treatments`, `PumpConfig`, etc.).
  3. Define `protocol OpenAIConfigProvider: Provider {}` (data access abstraction — Trio convention).
  4. Define `protocol OpenAIConfigObservable`:
     ```swift
     protocol OpenAIConfigObservable {
         var apiKey: String? { get }
         var apiKeyIsSet: Bool { get }
         func saveAPIKey(_ key: String)
         func deleteAPIKey()
     }
     ```
  5. Define `let openAIKeychainKey = "trio.openai.api_key"` constant.
- **Acceptance:** File compiles. Protocols importable by Provider, StateModel, and AddCarbs.
- **Observability:** None.

### Task A2 — OpenAIConfigManager.swift (shared service)

- **File:** `Trio/Sources/Services/OpenAIConfig/OpenAIConfigManager.swift` (new)
- **Change:** Lightweight singleton service implementing `OpenAIConfigObservable`. Wraps Keychain for API key CRUD. Shared by the OpenAIConfig Settings UI and AddCarbs.
- **Steps:**
  1. Create `OpenAIConfigManager` class implementing `OpenAIConfigObservable` and `Injectable`.
  2. `@Injected() var keychain: Keychain!`
  3. `apiKeyIsSet` — calls `keychain.hasValue(forKey: openAIKeychainKey)`, handles `Result` (returns `false` on `.failure`).
  4. `apiKey` — calls `keychain.getValue(String.self, forKey: openAIKeychainKey)`, unwraps `Result` (returns `nil` on `.failure`).
  5. `saveAPIKey(_:)` — calls `keychain.setValue(key, forKey: openAIKeychainKey)`. Log warning (no key value) on `.failure` via `debug(.openAI, ...)`.
  6. `deleteAPIKey()` — calls `keychain.removeObject(forKey: openAIKeychainKey)`. Log warning on `.failure`.
- **Acceptance:** Unit test: save key → read key → values match. Delete key → `apiKey` returns `nil`. `apiKeyIsSet` reflects state after each operation. Keychain `Result` failures handled without crash.
- **Notes:** `apiKey` must not appear in any log statement, debug description, or `CustomStringConvertible` implementation. The real Keychain API returns `Result<T, KeychainError>` — all call sites must handle both `.success` and `.failure`.

### Task A3 — OpenAIConfigProvider.swift

- **File:** `Trio/Sources/Modules/OpenAIConfig/OpenAIConfigProvider.swift` (new)
- **Change:** Concrete `BaseProvider` subclass implementing `OpenAIConfigProvider`.
- **Steps:**
  1. `extension OpenAIConfig { final class Provider: BaseProvider, OpenAIConfigProvider {} }`
- **Acceptance:** Compiles. Resolvable by `BaseStateModel<Provider>`.

### Task A4 — OpenAIConfigStateModel.swift

- **File:** `Trio/Sources/Modules/OpenAIConfig/OpenAIConfigStateModel.swift` (new)
- **Change:** `BaseStateModel<Provider>` for the Settings screen. Delegates to injected `OpenAIConfigManager`.
- **Steps:**
  1. `extension OpenAIConfig { final class StateModel: BaseStateModel<Provider> { ... } }`
  2. `@Injected() var configManager: OpenAIConfigObservable!`
  3. `@Published var apiKeyIsSet: Bool = false` — set from `configManager.apiKeyIsSet` in `subscribe()` and after save/delete.
  4. `func saveAPIKey(_ key: String)` — delegates to `configManager.saveAPIKey(key)`, updates `apiKeyIsSet`.
  5. `func deleteAPIKey()` — delegates to `configManager.deleteAPIKey()`, updates `apiKeyIsSet`.
- **Acceptance:** Round-trip key entry works via StateModel. `apiKeyIsSet` updates on save and delete.
- **Notes:** This StateModel is the Settings UI controller. The shared `OpenAIConfigManager` (Task A2) is the singleton injected into other modules like AddCarbs.

### Task A5 — OpenAIConfigRootView.swift

- **File:** `Trio/Sources/Modules/OpenAIConfig/View/OpenAIConfigRootView.swift` (new)
- **Change:** `BaseView`-conforming SwiftUI Settings screen for API key management.
- **Steps:**
  1. `extension OpenAIConfig { struct RootView: BaseView { let resolver: Resolver; @StateObject var state = StateModel() } }`
  2. When `state.apiKeyIsSet == false`: show `SecureField("Paste API key", text: $draftKey)`. "Save" button disabled until `draftKey` non-empty.
  3. When `state.apiKeyIsSet == true`: show "API key configured ✓". "Replace" button reveals `SecureField`. "Delete" button shows confirmation alert before calling `state.deleteAPIKey()`.
  4. "Save" calls `state.saveAPIKey(draftKey)`. Clear `draftKey`. Show brief success indicator.
  5. Call `configureView()` in `.onAppear` (standard `BaseView` lifecycle).
- **Acceptance:** Round-trip key entry via UI works. Key masked when present. Delete removes from Keychain. View correctly uses `BaseView` lifecycle.
- **Observability:** None required.

### Task A6 — Navigation wiring

- **Files:** 4 existing files modified.
- **Change:** Wire OpenAIConfig into Trio's Settings navigation.
- **Steps:**
  1. `Router/Screen.swift` — add `.openAIConfig` case to the `Screen` enum.
  2. `Router/Screen.swift` (in `view(resolver:)`) — add branch: `case .openAIConfig: return .init(view: OpenAIConfig.RootView(resolver: resolver))`.
  3. `Settings/SettingItems.swift` — add a `SettingItem(title: "AI Features", view: .openAIConfig, searchContents: ["OpenAI", "API key", "AI"], path: ["Services", "AI Features"])` to the appropriate items array (e.g. `serviceItems`).
  4. `Settings/View/Subviews/ServicesView.swift` (or appropriate section subview) — add `Text("AI Features").navigationLink(to: .openAIConfig, from: self)`.
- **Acceptance:** Settings → Services → "AI Features" navigates to the OpenAIConfig screen. Screen searchable in Settings search.

---

## Phase B: MacroEstimate + OpenAIVisionService + ImagePicker

**Ship gate:** Not independently shippable to users — no AddCarbs entry point yet. Safe for internal TestFlight.
**Rollback:** Remove files. No other code references them at this stage.

### Task B1 — MacroEstimate.swift

- **File:** `Trio/Sources/Models/MacroEstimate.swift` (new)
- **Change:** Plain value type used by service and `StateModel`.
- **Steps:**
  1. Define struct with `carbs: Decimal?`, `fat: Decimal?`, `protein: Decimal?`.
  2. Add `Codable` conformance for JSON decoding from OpenAI response body. `Decimal` is natively `Codable` via `NSDecimalNumber` bridging.
- **Acceptance:** Compiles. Decodable from `{"carbs":42.5,"fat":12.0,"protein":18.0}`. Tolerates missing keys (optional fields). Type matches `AddCarbs.StateModel` properties (`Decimal`) — no lossy conversion needed.
- **Notes:** Do not use `Float` or `Double` — the rest of the codebase (`AddCarbs.StateModel`, `CarbsEntry`) uses `Decimal` for carbs/fat/protein to avoid floating-point precision artifacts.

### Task B2 — VisionService protocol + VisionServiceError

- **File:** `Trio/Sources/Services/VisionService.swift` (new)
- **Change:** Protocol and error enum.
- **Steps:**
  1. Define `protocol VisionService { func analyzeMeal(image: UIImage, apiKey: String) async throws -> MacroEstimate }`.
  2. Define `VisionServiceError: Error` with cases: `.unauthorized` (401), `.rateLimited` (429), `.serverError` (5xx), `.parseError` (non-JSON or unexpected schema), `.networkUnavailable` (URLError), `.unknown(Int)` (other HTTP status).
  3. Add `var userFacingMessage: String` computed property on `VisionServiceError` with human-readable copy for each case.
- **Acceptance:** Compiles. `OpenAIVisionService` and a mock can both conform.

### Task B3 — OpenAIVisionService.swift

- **File:** `Trio/Sources/Services/OpenAIVisionService.swift` (new)
- **Change:** Concrete `VisionService` implementation. Accepts injectable `URLSession` for testability.
- **Steps:**
  1. Initializer accepts `urlSession: URLSession = .shared` so unit tests can inject a mock session without URL protocol hacks.
  2. On `analyzeMeal(image:apiKey:)`:
     - Resize image to max 1024px longest side (maintain aspect ratio) using `UIGraphicsImageRenderer`.
     - Convert to JPEG data (quality 0.85). Convert to base64 string.
     - Construct request body: model `gpt-4o`, messages array with system prompt + user message containing image content block (`type: "image_url"`, `image_url.url: "data:image/jpeg;base64,<base64>"`) and text "Estimate the macronutrients in this meal."
     - POST to `https://api.openai.com/v1/chat/completions` with `Authorization: Bearer <apiKey>` and `Content-Type: application/json`.
     - On HTTP 401 → throw `.unauthorized`. On 429 → throw `.rateLimited`. On 5xx → throw `.serverError`. On other non-2xx → throw `.unknown(statusCode)`.
     - Extract `choices[0].message.content` string from response JSON.
     - **JSON extraction:** The model may wrap its JSON in markdown code fences or surrounding prose. Before decoding, attempt to extract the first `{...}` substring (brace-matched or regex). If no braces found, use the raw content string.
     - Decode extracted string as `MacroEstimate` using `JSONDecoder`. On failure → throw `.parseError`.
     - Return `MacroEstimate`.
  3. Single retry on `URLError` (`.networkUnavailable`) or `.serverError` (5xx), 500ms delay. No retry on 401/429.
  4. No image data retained after function returns.
- **Acceptance:** Unit test with injected mock `URLSession`: valid JSON response → correct `MacroEstimate` with `Decimal` values. JSON wrapped in markdown fences → still parses correctly. 401 → `.unauthorized`. 500 → `.serverError` after one retry. Non-JSON → `.parseError`. `URLError` → `.networkUnavailable` after one retry.
- **Notes:** System prompt constant defined at top of file for easy tuning: `private let systemPrompt = "You are a nutrition estimator. Respond only with a valid JSON object with keys carbs, fat, and protein as numbers representing grams. No explanation, no markdown, no additional keys."` Model name constant: `private let model = "gpt-4o"`.

### Task B4 — ImagePicker.swift

- **File:** `Trio/Sources/Views/ImagePicker.swift` (new)
- **Change:** SwiftUI `UIViewControllerRepresentable` for image selection.
- **Steps:**
  1. Accept `sourceType: SourceType` (`.camera` / `.photoLibrary`) and `@Binding var image: UIImage?`.
  2. Use `PHPickerViewController` for `.photoLibrary`. Use `UIImagePickerController` for `.camera`.
  3. On selection: assign `UIImage` to binding, dismiss.
  4. On cancel: dismiss without assigning.
  5. If `.camera` source requested but camera unavailable (e.g., simulator): fall back to `.photoLibrary`.
- **Acceptance:** Picker presents and dismisses in both modes. Selected image assigned to binding. Cancel does not modify binding.

---

## Phase C: AddCarbs Integration

**Ship gate:** Requires Phase A + B complete. Full feature visible to users.
**Rollback:** Revert AddCarbs changes. Phase A/B files remain but are inert without the entry point.

### Task C0 — iOS permission plist entries

- **File:** `Trio/Resources/Info.plist` (modify)
- **Change:** Add required usage description strings. Without these the app will crash with a `NSInternalInconsistencyException` when the permission prompt fires on a real device — this applies to sideloaded/TestFlight builds as well as any other distribution method.
- **Steps:**
  1. Add `NSCameraUsageDescription` → `"Trio uses your camera to photograph meals for AI-assisted nutrition estimation."`
  2. Add `NSPhotoLibraryUsageDescription` → `"Trio can read photos from your library to estimate meal nutrition with AI."`
  3. Confirm neither key already exists (Trio may already have camera access for another feature — if so, append the new context to the existing string rather than replacing it).
- **Acceptance:** App does not crash when tapping "Take Photo" on a physical device running iOS 16+. Permission prompt displays the correct description string. Simulator: no crash (camera falls back to photo library per Task B4).

### Task C1 — AddCarbs.RootView additions

- **File:** `Trio/Sources/Modules/AddCarbs/View/AddCarbsRootView.swift` (modify)
- **Change:** Add photo analysis UI elements and state.
- **Steps:**
  1. Add state variables: `@State private var mealImage: UIImage?`, `@State private var isAnalyzingPhoto = false`, `@State private var visionError: String?`, `@State private var showImageSourceDialog = false`, `@State private var analysisTask: Task<Void, Never>?`.
  2. Add "Analyze Meal Photo" button in the form. Disabled when `!state.apiKeyIsSet` with subtitle hint. Enabled tap sets `showImageSourceDialog = true`.
  3. Add `.confirmationDialog("Analyze Meal Photo", isPresented: $showImageSourceDialog)` with "Take Photo" and "Choose from Library" actions. Dialog message copy includes: "Your photo will be sent to OpenAI for analysis."
  4. Track selected source in `@State private var imageSource`. Present `ImagePicker` as `.sheet` keyed to source selection.
  5. When `isAnalyzingPhoto == true`: show `ProgressView("Analyzing…")` overlaid or inline below the button.
  6. When `visionError != nil`: show inline error `Text(visionError!)` in red below the button. Clear on next analysis attempt.
  7. Add `.onChange(of: mealImage)` using the **iOS 17 two-parameter closure**:
     ```swift
     .onChange(of: mealImage) { _, newValue in
         guard let image = newValue else { return }
         analysisTask?.cancel()
         visionError = nil
         isAnalyzingPhoto = true
         analysisTask = Task {
             visionError = await state.analyzeMealPhoto(image)
             isAnalyzingPhoto = false
             mealImage = nil
         }
     }
     ```
  8. Add `.onDisappear { analysisTask?.cancel() }` to cancel in-flight analysis on navigation away.
  9. Cancel `analysisTask` before save: in the Save button action, call `analysisTask?.cancel()` before `state.add()`.
- **Acceptance:** Button visible and disabled without key. Dialog presents on tap. Source selection triggers picker. Spinner shown during analysis. Error text appears on failure and clears on next attempt. Fields populated after successful analysis. Analysis cancelled on navigation away or Save.
- **Notes:** Do not lock form fields during analysis — user can still type manually. The stored `analysisTask` prevents stale state mutation after navigation or save.

### Task C2 — AddCarbs.StateModel additions

- **File:** `Trio/Sources/Modules/AddCarbs/AddCarbsStateModel.swift` (modify)
- **Change:** Add `@Injected()` dependencies for `VisionService` and `OpenAIConfigObservable`. Add `analyzeMealPhoto` function.
- **Steps:**
  1. Add `@Injected() var visionService: VisionService!` and `@Injected() var openAIConfig: OpenAIConfigObservable!` as property wrappers (Trio's DI pattern — resolved from the global container by `BaseStateModel.injectServices(resolver)`. **Do not** use constructor injection or register `AddCarbs.StateModel` in Swinject).
  2. Expose `var apiKeyIsSet: Bool { openAIConfig.apiKeyIsSet }` for the view's button state.
  3. Add `@Published var aiPopulatedFields: Set<String> = []` — tracks which fields were populated by AI (for `meal_photo_values_edited` observability event).
  4. Add:
     ```swift
     func analyzeMealPhoto(_ image: UIImage) async -> String? {
         guard let apiKey = openAIConfig.apiKey else {
             return "No API key configured. See Settings → AI Features."
         }
         do {
             let estimate = try await visionService.analyzeMeal(image: image, apiKey: apiKey)
             await MainActor.run {
                 aiPopulatedFields = []
                 if let c = estimate.carbs   { self.carbs = c; aiPopulatedFields.insert("carbs") }
                 if let f = estimate.fat     { self.fat = f; aiPopulatedFields.insert("fat") }
                 if let p = estimate.protein { self.protein = p; aiPopulatedFields.insert("protein") }
                 if estimate.fat != nil || estimate.protein != nil {
                     self.useFPUconversion = true
                 }
             }
             return nil
         } catch let error as VisionServiceError {
             return error.userFacingMessage
         } catch {
             return "An unexpected error occurred. Please try again."
         }
     }
     ```
- **Acceptance:** Mock service returning a known `MacroEstimate` → `Decimal` fields populated correctly. Fat/protein population auto-expands FPU section. Mock service throwing `.unauthorized` → error string returned, fields unchanged. `aiPopulatedFields` correctly tracks which fields were set.
- **Notes:** `userFacingMessage` is defined in Task B2 (on `VisionServiceError`). The `Decimal` type of `estimate.carbs` etc. matches `self.carbs` etc. — no conversion needed.

---

## Phase D: Swinject DI + Observability

**Ship gate:** Required before any phase ships to users. Implement in same build as Phase C.
**Rollback:** Remove registrations. Types remain available but not injected.

### Task D1 — Swinject registrations

- **File:** `Trio/Sources/Assemblies/ServiceAssembly.swift` (modify)
- **Change:** Register `OpenAIConfigObservable` and `VisionService` in the DI container.
- **Steps:**
  1. Add registrations to `ServiceAssembly.assemble(container:)`:
     ```swift
     container.register(OpenAIConfigObservable.self) { _ in
         OpenAIConfigManager()
     }.inObjectScope(.container)

     container.register(VisionService.self) { _ in
         OpenAIVisionService()
     }.inObjectScope(.container)
     ```
  2. **Do NOT register `AddCarbs.StateModel`** — it is created inline via `@StateObject var state = StateModel()` in `AddCarbs.RootView`. Its new dependencies (`VisionService`, `OpenAIConfigObservable`) are resolved via `@Injected()` property wrappers when `BaseStateModel.injectServices(resolver)` is called during the `configureView()` lifecycle.
- **Acceptance:** App launches without DI resolution errors. `OpenAIConfigObservable` and `VisionService` resolvable from the global container. AddCarbs screen loads without resolution crashes.
- **Notes:** Follow the existing registration pattern in `ServiceAssembly` (e.g. `container.register(Foo.self) { ... }.inObjectScope(.container)`).

### Task D2 — Logger.Category addition

- **File:** `Trio/Sources/Logger/Logger.swift` (modify)
- **Change:** Add a new `Logger.Category` case for AI-related logging.
- **Steps:**
  1. Add `case openAI` to the `Logger.Category` enum.
  2. Add a corresponding `static let openAI = Logger(...)` instance (follow existing pattern for other categories).
  3. Add `case .openAI: return .openAI` branch in the `logger` computed property's `switch`.
- **Acceptance:** `debug(.openAI, "test")` compiles and emits to console.

### Task D3 — Observability log events

- **Files:** `AddCarbsStateModel.swift`, `OpenAIVisionService.swift`, `AddCarbsRootView.swift`
- **Change:** Emit structured log events at key points using the new `.openAI` category.
- **Events:**

| Event | Location | Fields |
|---|---|---|
| `meal_photo_analysis_started` | `StateModel.analyzeMealPhoto` entry | `timestamp` |
| `meal_photo_analysis_completed` | `StateModel.analyzeMealPhoto` success | `duration_ms`, `carbs_populated`, `fat_populated`, `protein_populated` |
| `meal_photo_analysis_failed` | `StateModel.analyzeMealPhoto` catch | `error_type` (no PII) |
| `meal_photo_values_edited` | `AddCarbs.RootView` on field change when `state.aiPopulatedFields` contains the field name | `field: String` |

- **`meal_photo_values_edited` implementation:** In `AddCarbsRootView`, add `.onChange` observers on `state.carbs`, `state.fat`, `state.protein`. When a change occurs and `state.aiPopulatedFields.contains("carbs")` (etc.), emit the event and remove the field from `aiPopulatedFields` (fire once per AI population, not on every keystroke).
- **Acceptance:** All four events appear in Trio console log during manual test of happy path, error path, and manual edit after AI population. No API key value appears in any log output.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| GPT prompt returns prose around JSON | `OpenAIVisionService` extracts first `{...}` substring before decoding (Task B3); falls back to `.parseError` if no braces found |
| Image size causes slow upload on cellular | Max 1024px resize + JPEG compression before encoding |
| User submits form while analysis is running | `analysisTask` cancelled before save (Task C1 step 9). Save proceeds with current field values. No post-save state mutation. |
| User navigates away during analysis | `analysisTask` cancelled via `.onDisappear` (Task C1 step 8). No stale state mutation. |
| API key leaked via log | All log events reviewed at code review: no `apiKey` parameter or string interpolation allowed. Logger category `.openAI` does not emit key values. |
| OpenAI changes base64 image request format | `OpenAIVisionService` is the single change point; integration test against live API before shipping |
| Mock `VisionService` in unit tests receives `apiKey` parameter | Tests must use a clearly fake key string (e.g., `"test-key-not-real"`) and never the real Keychain value; the protocol signature exposes it, so test discipline is required |
| Keychain operation fails (device locked, corruption) | `OpenAIConfigManager` handles all `Result<T, KeychainError>` returns. Failures surface as warnings in logs and graceful fallbacks (nil key, false for isSet). |
| OpenAI 5xx server error | Single retry with 500ms delay (same as network timeout). `.serverError` case in `VisionServiceError`. |

---

## Hypotheses / Expectations

- GPT-4o will return valid JSON (with or without surrounding prose) in > 90% of attempts given a well-crafted system prompt.
- Latency will be 2–5 seconds on a typical mobile connection — acceptable with spinner.
- Users will edit AI-populated values in approximately 20–40% of cases — expected and desirable.
- Fat and protein estimates will be less reliable than carb estimates across diverse meal types.

---

## Changelog

### v1.2 (2026-03-22 15:07 CET)
- Red team review — structural fixes:
  - **MacroEstimate type changed from `Float` to `Decimal`** (Task B1) to match AddCarbs.StateModel and CarbsEntry. Added note prohibiting `Float`/`Double`.
  - **Phase A rewritten for Trio module pattern:** Expanded from 3 tasks (A1–A3) to 6 tasks (A1–A6). Added `OpenAIConfigManager` shared service (A2), `Provider` (A3), renamed StateModel to `BaseStateModel<Provider>` (A4), RootView now `BaseView` (A5), and navigation wiring as a separate 4-file task (A6).
  - **AddCarbs DI corrected** (Task C2): uses `@Injected()` property wrappers instead of constructor injection. `AddCarbs.StateModel` is NOT registered in Swinject.
  - **Phase D1 rewritten:** registers `OpenAIConfigObservable` and `VisionService` in `ServiceAssembly`, not `AddCarbs.StateModel`.
  - **Task cancellation added** (Task C1): stored `analysisTask`, cancelled on `.onDisappear` and before Save.
  - **iOS 17 `.onChange` API** (Task C1 step 7): two-parameter closure `{ _, newValue in }`.
  - **VisionServiceError.serverError added** (Task B2) for 5xx; retry policy extended (Task B3).
  - **JSON extraction step added** to Task B3 — extract first `{...}` substring before decoding.
  - **URLSession injection** added to Task B3 for testability.
  - **Logger.Category requirement** added as new Task D2. Old D2 renumbered to D3.
  - **`meal_photo_values_edited` tracking mechanism** detailed in Task C2 (`aiPopulatedFields: Set<String>`) and Task D3.
  - **Fat/protein auto-expand:** Task C2 sets `useFPUconversion = true` when AI populates fat/protein.
  - **Keychain `Result` handling** documented in Task A2 and Risks table.
  - **File naming convention** fixed: `<Module><Role>.swift` (no dots).
  - **File paths corrected:** `AddCarbsRootView.swift` → `View/AddCarbsRootView.swift`, `AddCarbsStateModel.swift`.
  - **`userFacingMessage`** moved from Task C2 to Task B2 (where `VisionServiceError` is defined).
  - **Shared Conventions** updated for module pattern, `@Injected()`, `Result` API, `.openAI` logger category.
  - **Risks table expanded:** added Keychain failure, 5xx retry, task cancellation on navigate-away.

### v1.1 (2026-03-22)
- Red team: added Task C0 for required iOS plist permission entries (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`) — without these the app crashes on device regardless of distribution method.
- Red team: removed App Store review language from Task C0 notes — Trio is a DIY sideloaded app; this does not apply.
- Red team: added mock API key hygiene note to Risks table.

### v1.0 (2026-03-22)
- Initial plan created.
