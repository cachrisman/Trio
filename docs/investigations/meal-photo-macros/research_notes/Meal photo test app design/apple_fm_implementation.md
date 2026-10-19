# Apple Foundation Models (iOS 27): implementation detail for a meal-photo → macros test app (as of 2026-10-13)

Research date: 2026-10-13. Builds on `../On device meal photo macros/apple_on_device_stack.md` and corrects it in a few places (flagged "Correction"). Primary source is Apple's DocC JSON (`https://developer.apple.com/tutorials/data/documentation/<path>.json`), fetched live this session. That is the shipped iOS 27 documentation and outranks the June WWDC transcripts where they disagree. Labels used: **[doc]** Apple documentation JSON, **[WWDC]** WWDC26 session or lab transcript, **[forum]** Apple Developer Forums, **[repo]** vendor source code read this session, **[3p]** third-party blog, **[unverified]** background knowledge or inference that was not confirmed.

## 1. Image input API

**Attachment** is a generic struct, `struct Attachment<Content>`, available on iOS/iPadOS/macOS/visionOS/watchOS/Mac Catalyst 27.0. It conforms to `PromptRepresentable` and `InstructionsRepresentable`, so it goes straight into a `Prompt { }` / `respond { }` builder, and also into instructions. [doc: FoundationModels/Attachment]

Initializers (all 27.0, available when `Content == ImageAttachmentContent`) [doc: Attachment/init(_:orientation:)]:
- `init(_ cgImage: CGImage, orientation: CGImagePropertyOrientation? = nil)`
- `init(_ ciImage: CIImage, orientation: CGImagePropertyOrientation? = nil)`
- `init(_ uiImage: UIImage, orientation: UIImage.Orientation? = nil)`
- `init(_ nsImage: NSImage, orientation: CGImagePropertyOrientation? = nil)`
- `init(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation? = nil)`
- `init(imageURL: URL, orientation: CGImagePropertyOrientation? = nil)`. The framework infers an image from the URL's `UTType`.
- `init(_ content: Content)` for data attachments (`DataAttachmentRepresentable`). This one is **iOS 27.2, beta**.
- `orientation: nil` means "use the image's natural orientation". Pass an explicit orientation for un-rotated buffers, for example from AVFoundation (`Attachment(img, orientation: .right)`). [doc: analyzing-images-with-multimodal-prompting]
- `func label(_ label: String) -> Attachment<Content>`. Labels let the model refer to a specific image in tool calls and in `ImageReference` fields of structured output. A label should be a stable string the model can quote back. [doc: Attachment/label(_:), Origami sample]

**Placement in the prompt builder**: put text lines and `Attachment(...)` lines side by side in the closure. Several images per prompt are supported; Apple's own example compares two images, and Origami attaches several photos in one prompt. [doc]

**Scaling**: "The framework performs the necessary scaling and color conversions before passing an image to the model, so you don't need to scale or convert images to different formats." [doc: analyzing-images-with-multimodal-prompting]. Session 241 says any size or aspect ratio is accepted but "larger images will consume more tokens and incur more latency" [WWDC 241]. Apple also suggests considering preprocessing such as "isolating a region of interest" (cropping) [doc].

**Respond with a Generable type and an image** [doc: LanguageModelSession/respond(generating:includeSchemaInPrompt:options:prompt:)]:
```swift
@discardableResult nonisolated(nonsending) final func respond<Content>(
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
) async throws -> LanguageModelSession.Response<Content> where Content : Generable
```
There are also `respond(to: Prompt, generating:includeSchemaInPrompt:options:)`, `respond(schema:...)` for a runtime `DynamicGenerationSchema`, and new iOS 27 overloads with `contextOptions:metadata:` (`ContextOptions` carries `reasoningLevel`, which matters only for PCC and reasoning models).

**includeSchemaInPrompt**: defaults to `true` ("injects the schema into the prompt to bias the model"). Set it to `false` only when the model already knows the format, for example on later turns of the same session. Doing so saves "hundreds of tokens per request". [doc: respond(...), analyzing-the-runtime-performance]. For a single-shot meal call, leave it `true`.

**GenerationOptions** [doc]:
- `init(samplingMode:temperature:maximumResponseTokens:)`, `init(samplingMode:temperature:maximumResponseTokens:toolCallingMode:)` (27.0), and the older `init(sampling:temperature:maximumResponseTokens:)`.
- `SamplingMode`: `.greedy`, `.random(top:seed:)`, `.random(probabilityThreshold:seed:)`. Apple's image-classification example uses `GenerationOptions(samplingMode: .greedy)` and adds the tip "Use the greedy sampling option when you want the model to always pick the most likely option". Use `.greedy` for reproducible estimates (deterministic on the same model version; across variants, see §3).
- Apple warns against `maximumResponseTokens` except as a safety cap, because it can truncate output.
- `ToolCallingMode` (27.0): `.allowed`, `.disallowed`, `.required`. With `.required` you must define an exit condition or the model keeps calling tools.

**Streaming** [doc]: `streamResponse(generating:includeSchemaInPrompt:options:prompt:)` returns `LanguageModelSession.ResponseStream<Content>`, an AsyncSequence of `Snapshot`. Each snapshot has `content: Content.PartiallyGenerated` (all fields optional), `rawContent`, `transcriptEntries`, and `usage`. `collect()` returns the final response. Apple warns: "If running in the background, use the non-streaming respond… to reduce the likelihood of encountering `LanguageModelError.rateLimited`."

**Response** [doc]: `content`, `rawContent`, `usage` (`LanguageModelSession.Usage`: `input`, `output`, `totalTokenCount`, `metadata`; WWDC also shows `usage.input.cachedTokenCount` and `usage.output.reasoningTokenCount`), and `transcriptEntries`. `session.usage` accumulates across the session. Other session APIs: `prewarm(promptPrefix:)`, which is only worthwhile with at least 1 s of lead time (for example on camera open), and `transcriptErrorHandlingPolicy` (`.preserveTranscript` / `.revertTranscript`, 27.0).

**Reading images back** (`Transcript.ImageAttachment`, 27.0): `cgImage`, `ciImage`, `orientation`, `url`, and `pixelBuffer(resolution:pixelFormat:)`. [doc]

**Correction to the WWDC transcript code**: session 237's sample code uses `imageReference.resolve(in: transcript)` and `imageAttachment.pixelBuffer()`. The shipped API is `ImageReference.resolved(in: some Sequence<Transcript.Entry>) -> Transcript.ImageAttachment?`, which returns the latest matching label, and `pixelBuffer(resolution:pixelFormat:)`. [doc: ImageReference/resolved(in:)]

## 2. @Generable / @Guide for a meal estimate

All of the following are confirmed in docs [doc: GenerationGuide, Generable, managing-the-context-window]:
- Numeric ranges: `.range(_:)` has overloads for `ClosedRange<Int>`, `Double`, `Float`, and `Decimal`. Also `.minimum(_:)` and `.maximum(_:)`. Apple's example is `@Guide(.minimum(1), .maximum(10)) var rating: Int`.
- Arrays: `.count(_:)`, `.minimumCount(_:)`, `.maximumCount(_:)`, `.element(_:)`. Apple recommends `maximumCount` to cap tokens. Stacking two `@Guide` attributes on one property (description plus count) appears in Apple's own example.
- Strings: `.pattern(_:)` (Regex), `.constant(_:)`, `.anyOf(_:)`.
- Enums: `@Generable enum` is supported, including string raw values whose raw value text is shown to the model (Origami's `ImageCategory: String`). This is the way to express confidence.
- Optional fields (`String?`) are allowed (Origami's `completionMessage: String?`). `@Generable(description:representNilExplicitlyInGeneratedContent:)` exists.
- `GenerationID` can serve as a stable id for array elements.
- `ImageReference` is itself `Generable`, so an output field can point back to a labelled input image.
- Token hygiene: each Generable becomes a JSON schema in the prompt, and every `@Guide` description costs tokens. Apple's advice is to start without guides, use short clear property names, and add guides only where they improve quality.
- [unverified, WWDC25 background knowledge] Properties are generated in declaration order. Put `items` before totals so the totals are conditioned on the itemisation, or better, compute totals in Swift from the items.

## 3. Models, variants, context window, image token cost

- **Two on-device variants on iOS 27**: `SystemLanguageModel.variant` returns `.core3` ("AFM 3 Core") or `.coreAdvanced3` ("AFM 3 Core Advanced"), and `variant.displayName` gives a user-facing name. [doc: SystemLanguageModel/Variant]
  - Apple staff mapping (accepted forum answer): **iPhone Air, iPhone 17 Pro and 17 Pro Max → AFM 3 Core Advanced (20B sparse) on iOS 27.0. iPhone 15 Pro, 15 Pro Max and iPhone 16 or later → AFM 3 Core (3B).** Devices before the 27.0 betas used the prior 3B model. [forum 843063]. A Japanese write-up adds that Core Advanced needs 12 GB RAM and lists 18 Pro as a Core Advanced device. [3p classmethod, Sept 2026]
  - Apple ML research (2026-06-08): Core is a 3B dense model and "accept[s] image inputs". Core Advanced is 20B total with 1 to 4B active, "natively multimodal", stored in flash with experts paged into DRAM per prompt. Core image understanding was preferred over the prior generation more than 61% of the time. [Apple ML research, third-generation AFM]
  - **Consequence**: image input works on the base Core model, so it should work on the iPhone 15 Pro. Apple staff said image support shipped "with the updated on device model" and the PCC model [WWDC lab 8011]. Variant-specific "personalities" are real: in one developer's 50-case tool-calling test, Core completed 60% and Core Advanced 98% [forum 843063]. Expect macro estimates to differ by device. Record `variant` with every test result.
- **Context size**: `contextSize` is back-deployed and reports the actual value. Apple docs still say "4096 tokens per session" (managing-the-context-window) and list "4K" in the PCC comparison table. Session 319's code reads `// 4096 on 26.0 // 8192 on 27.0 (newer devices)`, and the forum report says core3 is 4K while coreAdvanced3 is 8K. **Working assumption: 4,096 on Core (15 Pro/16/17), 8,192 on Core Advanced (Air/17 Pro).** Read `SystemLanguageModel.default.contextSize` at runtime and log it. PCC is 32,768. [doc, WWDC 319, forum]
- **Image token cost**: no documented formula. An Apple engineer in the WWDC26 group lab said "about 200 tokens or so for an image typically" [WWDC lab 8011]. A third-party summary of the 241 demo reports roughly 323 input tokens for an origami-crane caption (image plus text) [3p ivanmagda]. The 2025 tech report (old model) used 672×672 images, which became 144 tokens [arXiv 2507.13575]. Since the framework rescales internally, the number is probably roughly constant per image, but the "larger images cost more" remark contradicts that. **Measure it**: log `response.usage.input.totalTokenCount` with and without the image. There is no image overload of `tokenCount(for:)`: `tokenCount(for: Instructions)` (26.4) is the documented signature, and a `Prompt` overload is [unverified].
- **Downscaling**: not required by the API. For a test app, downscale anyway to a long edge of about 1024–1600 px, to cut memory and conversion time and to keep a 48 MP capture from doing anything odd. This is an [unverified] engineering choice, not Apple guidance. Cropping to the plate (for example with Vision saliency, `GenerateObjectnessBasedSaliencyImageRequest`) is in line with Apple's "isolating a region of interest" advice.
- **Budget for one meal call** on 4K: instructions (~100–200) + schema (~150–300 with guides) + image (~200–300) + response (~150–300). That fits comfortably. Use a fresh session per photo.

## 4. Availability

- `SystemLanguageModel.default.availability` returns `.available` or `.unavailable(reason)`. `UnavailableReason` has `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady` (downloading or other system reasons), and the enum is non-frozen, so include a default case. `isAvailable` is a Bool shortcut. [doc]. This confirms the earlier "unverified" list.
- **Vision capability flag**: `LanguageModelCapabilities.Capability.vision` ("accept image inputs in prompts"), with siblings `.guidedGeneration`, `.toolCalling`, `.reasoning` [doc]. Every `LanguageModel` exposes `capabilities`, and if you send an image to a model without `.vision` the framework throws `LanguageModelError.unsupportedCapability`. Check `model.capabilities.contains(.vision)` before attaching. This is the main guard when swapping in third-party or Core AI models. Whether `SystemLanguageModel` reports `.vision` on both variants was not checked on a device [unverified, expected yes].
- Runtime asset errors: `SystemLanguageModel.Error.assetsUnavailable` (27.0). [doc]
- Simulator: `OCRTool` and `BarcodeReaderTool` are "not available in Simulator" [doc]. Whether image prompts to the system model work in the Simulator (which uses the host Mac's model) is untested. Test on a device.

## 5. Guardrails and errors

- `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`. **Docs confirm** that permissive mode only relaxes **String** generation: "When you generate responses other than String, this mode behaves the same way as default mode and throws `LanguageModelError.guardrailViolation`." So it does nothing for a `@Generable` meal estimate. A two-step workaround (String description first, then Generable) is possible but probably not worth it. Nothing documents image-specific guardrails. [doc: Guardrails/permissiveContentTransformations]
- **New error types in iOS 27**: `LanguageModelSession.GenerationError` is **deprecated in 27.0**. "Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You must update to Xcode 27 to catch the new error types." So with Xcode 27, catch [doc]:
  - `LanguageModelError` (any model, `@nonexhaustive`): `.contextSizeExceeded(_)`, `.rateLimited(_)` (has `resetDate`), `.refusal(_)` (has `explanation` / `explanationStream`), `.timeout(_)`, `.guardrailViolation(_)` (has `debugDescription`, `metadata`), `.unsupportedCapability(_)`, `.unsupportedTranscriptContent(_)`, `.unsupportedGenerationGuide(_)`, `.unsupportedLanguageOrLocale(_)`.
  - `SystemLanguageModel.Error.assetsUnavailable(_)`.
  - `LanguageModelSession.Error.concurrentRequests` / `.transcriptMutationWhileResponding`. Do not fire a second `respond` on a session that `isResponding`.
  - `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_)` for PCC.
  - **Correction**: the prior note's `.exceededContextWindowSize` and `decodingFailure` belong to the deprecated `GenerationError`, so do not code against them on 27.
- On-device rate limiting happens only in the background under load ("in the foreground… never any rate limiting") [WWDC lab 8011].
- To report false positives, use `session.logFeedbackAttachment(sentiment:issues:desiredOutput:)` and attach the result to Feedback Assistant. [doc]

## 6. Tools

- **Built-in Vision tools** (import `Vision`, 27.0): `BarcodeReaderTool()` and `OCRTool()`, each with `init(name:description:)` to rename or re-describe. `OCRTool` is not on watchOS. Neither works in the Simulator. Usage: `LanguageModelSession(tools: [BarcodeReaderTool(), OCRTool()])` plus a **labelled** attachment. [doc: vision/barcodereadertool, vision/ocrtool]. For meals, `OCRTool` could read a nutrition label or menu in the photo, and `BarcodeReaderTool` could read a UPC that a custom lookup tool then resolves.
- **Custom tools with an image argument** use `@Generable struct Arguments { @Guide(description: "…") var image: ImageReference }`. In `call(arguments:)`, resolve with `arguments.image.resolved(in: history)`, where `history` comes from `@SessionProperty(\.history)`, then use `.cgImage`, `.ciImage`, or `pixelBuffer(resolution:pixelFormat:)`. Apple's sample tool runs `ClassifyImageRequest().perform(on: attachment.ciImage)` and returns the top 5 labels as a String. [doc]
- **Nutrition-DB lookup tool (USDA FoodData Central)**: supported in principle. The `Tool` protocol is `Tool<Arguments, Output>: Sendable`, with `call(arguments:) async throws -> Output` where `Output: PromptRepresentable` (String works), plus `name`, `description`, and `includesSchemaInInstructions`. Apple's own description says a tool can search "a local or online database". Design notes:
  - Each tool's definition and its output cost context. Apple advises 3–5 tools at most and short descriptions, and says "If the model always needs specific information, retrieve it directly… rather than relying on tool calling."
  - On the 4K Core model, tool loops are the weak spot (forum 843063: 4.4 calls per run and context blowouts on Core, 1.3 on Core Advanced).
  - **Recommended pattern for the test app [inference]**: pass 1 is image → `@Generable` items with `name` and estimated grams. Then call FDC from Swift, outside the model, and compute macros deterministically. Optionally use pass 2 (a new session, text-only) to reconcile. This avoids the tool loop entirely and keeps the macro math out of the LLM.
  - If a tool is used, return compact per-100 g values, not raw FDC JSON.

## 7. Adapters (custom fine-tune of Apple's model): **not available on iOS 27**

- Apple's toolkit page says "Version 26.0.0 is the last release of this toolkit and is not compatible with macOS, iOS, iPadOS, or visionOS 27 and later." [Apple: foundation-models-adapter page, fetched 2026-10-13]
- An Apple staff reply in [forum 831314] (June 2026) says "we're no longer supporting adapters as of OS 27."
- The adapter API docs are gone from the 27 doc set. `SystemLanguageModel` topics no longer list `Adapter`, and the DocC JSON for `systemlanguagemodel/adapter`, `init(adapter:guardrails:)`, `loading-and-using-a-custom-adapter-with-foundation-models`, and the `com.apple.developer.foundation-model-adapter` entitlement all return 404 (checked this session).
- Even on 26 the toolkit was text-only: JSONL `[{"role":"user","content":…},{"role":"assistant","content":…}]`, LoRA, a 32 GB Apple-silicon Mac or Linux GPU, Python 3.11, about 160 MB per adapter, retraining for every base-model version, and an entitlement required to ship. There was no vision adapter path.
- **Fine-tune path on 27 instead**: bring your own model through the same API. Export an open-weights model with **Core AI** (`apple/coreai-models`, `CoreAILanguageModel(resourcesAt:)`, iOS 27 / Xcode 27) or **MLX** (`MLXLanguageModel` in `ml-explore/mlx-swift-lm`), then `LanguageModelSession(model: thatModel)`. A model you fine-tuned yourself (for example a small VLM fine-tuned on food photos) would slot into the same code path. **Whether `CoreAILanguageModel` / MLX bridge image `Attachment`s (that is, report `.vision`) was not verified.** The coreai-models README and the FM article only show text LLMs, and Apple's suggested starter size is about 0.6B. Check `capabilities.contains(.vision)` before you count on it.

## 8. Third-party cloud models through `LanguageModelSession` (one code path for Apple, Claude and Gemini)

The `LanguageModel` protocol (27.0) is what makes this work: `capabilities`, `executorConfiguration`, and an `Executor`. `LanguageModelSession.init(model: some LanguageModel, tools:instructions:)` overloads exist. [doc]

- **Anthropic: `ClaudeForFoundationModels`** at https://github.com/anthropics/ClaudeForFoundationModels (Apache-2.0). Latest tag **0.2.3 (2026-10-07)**, first tagged 0.1.0 on 2026-06-08, marked "Beta". Product `ClaudeForFoundationModels`, platforms iOS/macOS/visionOS/watchOS 27, Xcode 27. [repo]
  - Code: `import ClaudeForFoundationModels`, then `let model = ClaudeLanguageModel(name: .sonnet5_5, auth: .apiKey(key))` and `LanguageModelSession(model: model)`. Model constants include `.haiku5_5`, `.sonnet5_5`, `.opus5_5`, `.fable5_1`, `.fable5`, `.opus5`, `.sonnet5`, `.opus4_8`, `.opus4_7`, `.opus4_6`, `.sonnet4_6`, `.haiku4_5`, and all of them declare `imageInput: true`.
  - **Image attachments: verified in source.** `ClaudeLanguageModel.capabilities` adds `.vision` when every model in the fallback chain has `imageInput`. `RequestBuilder` maps the `.attachment(.image)` segments of a prompt to Claude image blocks through `ClaudeImage(cgImage:orientation:)`. That type bakes in orientation, downscales to a long edge of 1568 px or 1.15 MP, re-encodes JPEG, and strips EXIF/GPS. **@Generable: supported** (`.guidedGeneration` when the model has `structuredOutput`). Tool calling, streaming, and reasoning (FM `.light`/`.moderate`/`.deep` map to Claude effort `low`/`medium`/`high`) are also supported.
  - Auth options: `.appAttest(clientID:)` is recommended and requires a physical device plus the App Attest entitlement and app registration in the Anthropic console. `.apiKey` is for the simulator or dev. `.proxied(headers:)` with `baseURL` goes through your own relay. For a personal test app, `.apiKey` from Keychain or an xcconfig is the pragmatic choice. Errors not mapped to `LanguageModelError` surface as `ClaudeError` (for example `.missingCredential`).
- **Google: Gemini through Firebase AI Logic**. This is not a standalone package: it is the Firebase Apple SDK `https://github.com/firebase/firebase-ios-sdk` **≥ 12.19.0** (preview originally used the `wwdc26-preview` branch), with products **`FirebaseAILogic` + `FirebaseAppCheck`**. Code: `let ai = FirebaseAI.firebaseAI(backend: .googleAI())`, `let model = ai.geminiLanguageModel(name: "gemini-3.8-flash")`, and `LanguageModelSession(model: model)`. It needs a Firebase project, and App Check is enforced, so development needs `AppCheckDebugProviderFactory` with a registered debug token. Status: **Preview**, no SLA. Listed models include `gemini-3.1-pro-preview`, `gemini-3.8-flash` (plus 3.7/3.6/3.5 flash) and `gemini-3.5-flash-lite`. [Firebase get-started doc; Firebase blog 2026-06]
  - Google says Gemini in FM supports "images, audio, video, or PDFs alongside your prompt" and that "existing @Generable… structures work unchanged". **Neither the exact image-Attachment bridging nor `.vision` in `capabilities` was verified in source this session [unverified].** Check `model.capabilities.contains(.vision)` at runtime.
- **Apple PCC (`PrivateCloudComputeLanguageModel`)** accepts images. This is confirmed by an Apple engineer ("support for image input, both with the updated on device model… and… the new server model running on PCC") [WWDC lab 8011] and by the Origami sample routing photo prompts through PCC [doc]. The entitlement requires **App Store Small Business Program enrollment and fewer than 2M first-time downloads**. TestFlight and ad hoc testing are allowed; development-signed builds are not addressed. Quota is daily per user. [developer.apple.com/private-cloud-compute]. For a personal test app this is likely more hassle than Claude or Gemini.
- **Single-code-path inference**: one `func estimate(with model: some LanguageModel, image:)` works for `SystemLanguageModel.default`, `PrivateCloudComputeLanguageModel()`, `ClaudeLanguageModel(...)`, and `GeminiLanguageModel`. The same `@Generable MealEstimate`, `Attachment`, and `GenerationOptions` apply. Caveats: `samplingMode: .greedy` / temperature may be dropped for Claude models that reject sampling params (the package's capability matrix decides). Context budgets differ (4K/8K/32K/~1M). Guardrail and refusal behaviour differs by provider.

## 9. Performance, memory, tooling

- **Latency**: no published on-device numbers for image prompts. Apple: larger images mean more tokens and latency, and time-to-first-token is dominated by prompt processing ("shorten your prompt") [WWDC 243]. Use streaming for perceived latency, and `prewarm()` when the camera opens. **Measure with Instruments**: Product > Profile > **Foundation Models** template. It has 6 lanes. Yellow bars show input processing time and orange bars show generation. It reports Time to First Token, Tokens per Second, Total Latency, token counts, and cache hit rate. Traces store prompts and responses unencrypted. [doc: analyzing-the-runtime-performance; WWDC 243]
- **Memory**: the on-device model is "managed by the OS" and may be evicted when unused or when the system needs it [WWDC 241 via search summary]. Core Advanced streams experts from flash into DRAM [Apple ML research]. That inference runs in a system process and does not count against the app's jetfam limit is [unverified]: it is consistent with the OS-managed framing but not documented. The app pays only for its own image buffers, so downscale large captures before attaching.
- **#Playground** (Xcode 26.4+/27): the `#Playground` macro canvas shows Input Token Count and Response Token Count separately, plus a context-window usage estimate [doc: Updates/FoundationModels, Feb 2026]. Whether a `#Playground` can take a bundled test image (for example `UIImage(named:)` in an app target) is [unverified] but likely. It is good for prompt and guide iteration on the Mac model, but on-device variant behaviour differs (§3), so confirm on the phone.
- **Evaluations framework** (WWDC26 session 298) can score responses against a labelled meal set, including LLM-as-judge. [WWDC search summary]
- Xcode scheme option "Simulated Apple Foundation Models Availability" simulates PCC quota states. [doc, WWDC 319]

## 10. Code sketch (doc-derived; not compiled this session)

Every symbol below was checked against the iOS 27 DocC JSON, except the lines marked `// [unverified]`.

```swift
import SwiftUI
import FoundationModels

@Generable(description: "Nutrition estimate for one meal photo")
struct MealEstimate {
    @Guide(description: "One short sentence describing the meal")
    var description: String

    @Guide(.maximumCount(8))
    var items: [FoodItem]              // listed before totals so totals follow the itemisation

    @Guide(description: "Total carbohydrate, grams", .range(0...400))
    var carbsGrams: Int
    @Guide(.range(0...300)) var proteinGrams: Int
    @Guide(.range(0...300)) var fatGrams: Int

    var confidence: Confidence
}

@Generable
struct FoodItem {
    var name: String
    @Guide(description: "Estimated portion in grams", .range(1...1500))
    var portionGrams: Int
    @Guide(.range(0...400)) var carbsGrams: Int
    @Guide(.range(0...300)) var proteinGrams: Int
    @Guide(.range(0...300)) var fatGrams: Int
}

@Generable
enum Confidence: String { case low, medium, high }

enum MealEstimateError: Error { case modelUnavailable(String), noVision }

func estimateMeal(_ photo: UIImage, model: some LanguageModel = SystemLanguageModel.default)
    async throws -> (MealEstimate, LanguageModelSession.Usage)
{
    guard model.capabilities.contains(.vision) else { throw MealEstimateError.noVision }

    let session = LanguageModelSession(
        model: model,
        instructions: "You estimate macronutrients from meal photos. Be concise."
    )
    let response = try await session.respond(
        generating: MealEstimate.self,
        options: GenerationOptions(samplingMode: .greedy)
    ) {
        "List each food in this photo with an estimated portion, then estimate grams of carbohydrate, protein and fat."
        Attachment(photo).label("meal")      // UIImage init; orientation nil = image's own
    }
    return (response.content, response.usage)
}

// Call site
func run(_ photo: UIImage) async {
    let sys = SystemLanguageModel.default
    guard case .available = sys.availability else { return }   // .deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady
    print(sys.variant.displayName, sys.contextSize)             // log per result: core3 vs coreAdvanced3, 4096 vs 8192
    do {
        let (estimate, usage) = try await estimateMeal(photo.downscaled(maxLongEdge: 1280)) // [unverified] own helper
        print(estimate, usage.input.totalTokenCount)            // [unverified] exact Usage.Input property names (from WWDC 241 slide)
    } catch LanguageModelError.guardrailViolation(let info) {
        print("guardrail:", info.debugDescription)               // manual entry fallback
    } catch LanguageModelError.refusal(let r) {
        print("refusal:", r.explanation)                         // [unverified] explanation may be async/stream
    } catch LanguageModelError.contextSizeExceeded {
        // downscale/crop, trim instructions, or retry on PCC/cloud model
    } catch LanguageModelError.unsupportedCapability {
        // model lacks .vision or .guidedGeneration
    } catch SystemLanguageModel.Error.assetsUnavailable {
        // model assets not downloaded yet
    } catch {
        print(error)
    }
}

// Same function, other backends (each needs its own package/setup):
// estimateMeal(photo, model: PrivateCloudComputeLanguageModel())                     // needs PCC entitlement
// estimateMeal(photo, model: ClaudeLanguageModel(name: .sonnet5_5, auth: .apiKey(k))) // ClaudeForFoundationModels
// estimateMeal(photo, model: FirebaseAI.firebaseAI(backend: .googleAI())
//                              .geminiLanguageModel(name: "gemini-3.8-flash"))         // FirebaseAILogic; .vision unverified
```

Notes on the sketch:
- `Usage.input.totalTokenCount` comes from the WWDC 241 slide. The docs list `Usage.input` / `Usage.Input` but the member names were not opened.
- `Refusal.explanation` exists in the docs, but its type (async or not) was not checked.
- Passing `some LanguageModel` straight through to `LanguageModelSession(model:instructions: String?)` matches a documented overload.
- Prefer computing totals in Swift from `items`, and drop the top-level totals if they drift.

## Gaps / to verify on device

1. Actual image token cost on core3 vs coreAdvanced3, and whether it depends on input resolution. Log `usage` for 512/1024/2048/4032 px inputs.
2. `contextSize` per device on 27.0 GA (4K vs 8K), and `capabilities.contains(.vision)` for `SystemLanguageModel.default` on a 15 Pro.
3. Latency (TTFT, total) for one meal image on each variant. There are no published numbers.
4. Guardrail behaviour on food photos with a Generable output (permissive mode does not help).
5. Gemini `GeminiLanguageModel` image-attachment bridging and `.vision` flag.
6. Whether Core AI / MLX `LanguageModel` bridges accept image attachments, which decides whether a self-fine-tuned VLM can use the same code path.
7. Whether a development-signed (non-TestFlight) build can use the PCC entitlement.

## Sources

- Apple DocC JSON (fetched 2026-10-13): [Foundation Models](https://developer.apple.com/documentation/foundationmodels), [Attachment](https://developer.apple.com/documentation/foundationmodels/attachment), [Attachment init(_:orientation:)](https://developer.apple.com/documentation/foundationmodels/attachment/init(_:orientation:)), [ImageReference](https://developer.apple.com/documentation/foundationmodels/imagereference), [Analyzing images with multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting), [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [Variant](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/variant-swift.struct), [LanguageModelCapabilities.Capability](https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities/capability), [LanguageModelError](https://developer.apple.com/documentation/foundationmodels/languagemodelerror), [GenerationError (deprecated 27.0)](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror), [Guardrails.permissiveContentTransformations](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails/permissivecontenttransformations), [GenerationOptions](https://developer.apple.com/documentation/foundationmodels/generationoptions), [GenerationGuide](https://developer.apple.com/documentation/foundationmodels/generationguide), [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession), [PrivateCloudComputeLanguageModel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel), [Adding server-side intelligence with PCC](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute), [Origami sample](https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence), [Running a Core AI model in a FM session](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session), [Analyzing runtime performance](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app), [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels), [Vision BarcodeReaderTool](https://developer.apple.com/documentation/vision/barcodereadertool), [Vision OCRTool](https://developer.apple.com/documentation/vision/ocrtool)
- Apple: [Foundation Models adapter toolkit page](https://developer.apple.com/apple-intelligence/foundation-models-adapter/), [Private Cloud Compute eligibility](https://developer.apple.com/private-cloud-compute/), [Introducing the third generation of Apple Foundation Models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- WWDC26: [237 image understanding](https://developer.apple.com/videos/play/wwdc2026/237/), [241 what's new in FM](https://developer.apple.com/videos/play/wwdc2026/241/), [243 Instruments](https://developer.apple.com/videos/play/wwdc2026/243/), [319 PCC](https://developer.apple.com/videos/play/wwdc2026/319/), [8011 Apple Intelligence group lab](https://developer.apple.com/videos/play/wwdc2026/8011/)
- Forums: [831314 adapters on OS 27](https://developer.apple.com/forums/thread/831314), [843063 core3 vs coreAdvanced3](https://developer.apple.com/forums/thread/843063)
- Vendors: [anthropics/ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) (README, Package.swift, ClaudeImage.swift, ClaudeModel.swift, ClaudeLanguageModel.swift, RequestBuilder.swift, CHANGELOG read at main, tag 0.2.3), [Firebase: Gemini via Apple FM get-started](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started), [Firebase blog 2026-06](https://firebase.blog/posts/2026/06/apple-foundation-models-gemini), [apple/coreai-models](https://github.com/apple/coreai-models)
- Third-party: [classmethod AFM3 devices (JP)](https://dev.classmethod.jp/articles/afm3-devices/), [Ivan Magda, FM year two](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/), [theswift.dev image analysis](https://www.theswift.dev/posts/analyze-images-with-foundation-models-in-swiftui/), [Apple FM tech report 2025](https://arxiv.org/pdf/2507.13575)
