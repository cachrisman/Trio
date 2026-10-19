# Apple first-party on-device AI stack for meal photo to description + carbs/protein/fat (as of 2026-10-13)

Research date: 2026-10-13. Sources were fetched live this session. iOS 27 shipped publicly on 2026-09-14 (per [MacRumors iOS 27 Health guide](https://www.macrumors.com/guide/ios-27-health-app/) and [Apple Support 121115](https://support.apple.com/en-us/121115), published 2026-09-14). WWDC 2026 was the week of 2026-06-08. Where a claim comes only from third-party blogs, it is labelled. The researcher's own model knowledge ends mid-2026; anything from that knowledge that was not re-verified this session is marked "unverified".

## Q1. Foundation Models framework: image input, API, model, context, guided generation, availability, limits

### Takeaway
iOS 26 Foundation Models was text-only for developers. At WWDC 2026, Apple added image input to the on-device model in the iOS 27 / macOS 27 cycle via `Attachment(...)` inside the existing prompt builder. It combines with `@Generable` guided generation, so a typed `{description, carbs, protein, fat}` struct can be requested straight from a photo. A new `PrivateCloudComputeLanguageModel` (32K context, reasoning, daily per-user quota, entitlement required) is also exposed through the same `LanguageModelSession` API. It is not documented whether that PCC model accepts images.

### Cited Findings
- **iOS 26 (2025) was text-only:** "In 2025, Foundation Models opened Apple's on-device language model to app developers. But it could not take an image as input." — [Blake Crosley blog (third-party)](https://blakecrosley.com/blog/foundation-models-image-input-ios-27). Corroborated by the framing of WWDC26 session 241, which says "The on-device model gains vision" — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **Image input API (iOS 27 cycle):** images go into the existing prompt builder next to text. Shown code: `try await session.respond { "What animal is this?"; Attachment(UIImage(...)) }` — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/). Caption example: `let prompt = Prompt { "Generate a caption for this image"; Attachment(image) }; let response = try await session.respond(to: prompt)` — [WWDC26 session 237 "What's new in image understanding"](https://developer.apple.com/videos/play/wwdc2026/237/)
- **Accepted attachment sources:** `UIImage`, `NSImage`, `CGImage`, Core Image types, CoreVideo pixel buffers, and file URLs. Any size or aspect ratio is accepted with no crop or pad. Larger images use more tokens and add latency. No max dimensions or per-image token cost are stated. — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **Structured output from an image:** session 237 shows `session.respond(generating: EventInfo.self) { "Get the date, location, and website from this flyer"; Attachment(image).label("flyer") }`. This is guided generation (`@Generable`) driven directly by an image attachment, the exact pattern a macros struct needs. — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/). `@Generable` and tool calling work the same with on-device and PCC models — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- **Image-aware tool calling:** a `Tool` can take an `ImageReference` argument, resolved via `@SessionProperty(\.history)` + `Transcript(history)` + `imageReference.resolve(in:)` → `imageAttachment.pixelBuffer()`. A reference is valid only in the transcript that produced it. Labelling attachments (`.label("...")`) helps the model pick which image to pass. — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/)
- **Built-in Vision-backed tools:** `BarcodeReaderTool` (barcodes and QR codes) and an OCR tool covering 30+ languages (Crosley names it `OCRTool`; the session transcript does not give the class name). In the demo, the model alone could not read a QR code but could with `BarcodeReaderTool`. — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/); [Blake Crosley](https://blakecrosley.com/blog/foundation-models-image-input-ios-27)
- **New on-device model:** "rebuilt from the ground up," better at logic and tool calling. No parameter count, version, or name is given in the transcript. — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **On-device context window (conflicting sources):** session 241 sample shows `SystemLanguageModel().contextSize` → `8192`. Session 319's video says on-device is "4K", while its code comments say `4096` on OS 26.0 and `8192` on OS 27.0 "for newer devices". — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/); [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/). `contextSize` and `tokenCount(for:)` were introduced in iOS 26.4 — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **2025 on-device model size:** about 3B parameters, with KV-cache sharing and 2-bit quantization-aware training. The 2025 report describes both the on-device and server models as "multilingual, multimodal" (image understanding existed internally even though the iOS 26 developer API was text-only). — [Apple Intelligence Foundation Language Models Tech Report 2025 (arXiv 2507.13575)](https://arxiv.org/pdf/2507.13575). No 2026 Apple tech report was found.
- **2026 model lineage:** joint Google/Apple statement of 2026-01-12 says "the next generation of Apple Foundation Models will be based on Google's Gemini models and cloud technology" and will keep running on-device and on Private Cloud Compute — [Google blog joint statement](https://blog.google/company-news/inside-google/company-announcements/joint-statement-google-apple/). Whether the iOS 27 on-device developer model is itself Gemini-derived is not stated in the sessions fetched.
- **PCC model for third-party developers (iOS 27 cycle):** `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`. Context `32768`. Reasoning via `contextOptions: ContextOptions(reasoningLevel: .light | .moderate | .deep)`, and reasoning tokens count toward context. No API keys or accounts are needed, and requests count against the user's iCloud account. Each user has a **daily limit**, higher with iCloud+. `model.quotaUsage.status`, `.isLimitReached`, and `.limitIncreaseSuggestion` handle limits, and exceeding the limit throws. Requires **internet** and an **entitlement applied for on the developer site**. Free (no token cost) for apps with **fewer than 2M (first-time App Store) downloads**. Also callable from watchOS 27. — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/); [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/); [MacRumors Platforms State of the Union 2026-06-09](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- **PCC image input not documented:** session 319 says the on-device model now supports image input but "does not say whether the PCC model accepts images." — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- **Usage accounting:** `LanguageModel` protocol shared by local and server models; `response.usage.input.totalTokenCount`, `.cachedTokenCount`, `usage.output.reasoningTokenCount`. — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **Third-party models through the same Swift API:** Anthropic and Google publish Swift packages that plug into `LanguageModelSession`. Apple advises fetching tokens via OAuth and storing them in Keychain, not in the binary. — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/); [MacRumors 2026-06-09](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/). Apple also said it will open-source the framework "later this summer" (2026). — [MacRumors](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- **Availability checks:** session 319 shows `model.isAvailable` with a fallback, and Xcode's "Simulate Apple Foundation Models Availability" option can simulate quota states. — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/). iOS 26's `SystemLanguageModel.default.availability` returns `.available` / `.unavailable(reason)`, with reasons `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` (**unverified**: the doc page body did not render this session, so these come from background knowledge — [doc URL](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason)).
- **Evaluations framework:** new in 2026 for choosing models and reasoning levels from data. — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- **Rate limits / background:** sessions 241 and 319 mention no rate limits for on-device use, and session 319's table lists on-device "Request limits: None". Background-execution restrictions were not mentioned in either session. — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)

### Inferences
- The proposed Trio flow (take photo → `Attachment` + `@Generable struct MealEstimate { description; carbsGrams; proteinGrams; fatGrams }` → pre-fill → discard photo) is directly supported by documented iOS 27 APIs, fully on-device with no network. It is **not** possible on iOS 26 with Apple's stack: no developer image input there.
- An 8K (or 4K on older devices or OS) context is ample for one photo plus a short prompt and a small struct, but image token cost is undocumented. Downscaling the photo before attaching is a sensible latency control.
- Apple's own positioning ("open-ended and descriptive tasks" go to Foundation Models, fixed tasks to Vision) and the small on-device model size suggest macro estimates will be rough. No Apple accuracy figures exist for food or nutrition (see Gaps). The accuracy question needs empirical testing against a labelled meal set.
- The PCC model is the only first-party path to a larger reasoning model. Image support there is undocumented, and there is a structural problem for Trio: the entitlement is applied for per developer/app, and the free tier is defined by App Store download counts. Trio is built from source by each user under their own team ID, so every user would presumably need their own entitlement. This is not confirmed; treat PCC as impractical for Trio until verified.

### Gaps
- Exact iOS 27 Swift type and initializer for `Attachment` (session 241 shows `Attachment(UIImage(...))`; Crosley says the exact signatures were not shown in docs he read). The minimum OS for image input is presumably 27.0, but no doc page confirming this was fetched.
- Per-image token cost, maximum resolution, and whether multiple images per prompt are supported.
- Whether `PrivateCloudComputeLanguageModel` accepts image attachments.
- Exact PCC daily quota numbers (not given in either session), and whether a non-App-Store (Xcode/TestFlight, per-user team ID) app can obtain the PCC entitlement.
- On-device background-execution behavior (e.g., whether requests are throttled or rejected while the app is backgrounded). Background knowledge suggests a `rateLimited` generation error exists for background use; this was not verified this session.
- No 2026 Apple Foundation Models tech report found on machinelearning.apple.com. On-device parameter count for the iOS 27 model is unknown.

## Q2. Acceptable-use policy and guardrails for health, medical, nutrition, diabetes

### Takeaway
Apple's Foundation Models acceptable-use requirements do not ban health or nutrition apps. The only relevant clause prohibits "inaccurate or dangerous outputs, or makes decisions without human supervision that have a material impact on individual rights, in high-risk domains, including … medical." Trio's design keeps a human in the loop (user confirms pre-filled values before any dosing). Guardrail false positives are a documented, recurring problem, but no thread specifically reports diabetes or food content being blocked.

### Cited Findings
- Full prohibited-use list fetched from both Apple URLs. The relevant clause is identical on both: "Provides inaccurate or dangerous outputs, or makes decisions without human supervision that have a material impact on individual rights, in high-risk domains, including in employment, medical, legal, or finance." Also: "Enables dependency or spiraling user interactions detrimental to a user's mental health" and "Circumvents any safety policies, guardrails, or restrictions integrated into the Foundation Models framework". There is no effective date on the page (footer © 2026). — [Apple: Acceptable use requirements (apple-intelligence path)](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/); [Apple: Acceptable use requirements (support/terms path)](https://developer.apple.com/support/terms/acceptable-use-requirements-for-the-foundation-models-framework/)
- A search-engine summary claimed a "newer version" lists "engaging in regulated healthcare, legal, or financial services" as prohibited. **Direct fetches of both Apple pages on 2026-10-13 did not contain that wording.** Treat that claim as unverified or erroneous.
- The policy text says "including a model accessed by the framework", so it also covers PCC and third-party models called through the framework. — [Apple AUP](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/)
- **Guardrail tuning:** guardrail adjustments in iOS 26.4 reduced false positives, and further improvements are promised in iOS 27. — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- **Guardrail regression report (June 2026):** a developer reports `Generable` conversions that previously worked failing with guardrail violations from around iOS/macOS 26.5. They used `SystemLanguageModel(guardrails: .permissiveContentTransformations)` and noted that the permissive mode does not apply to `Generable` output. An Apple Frameworks Engineer only advised filing Feedback with full transcript details. — [Apple Developer Forums thread 835777](https://developer.apple.com/forums/thread/835777)
- **Other false positives:** news articles about deaths rejected, "Six Flags Great America" flagged, "population of Sweden" flagged while New York passed, and a mental-health crisis-banner classifier frequently blocked. Apple DevRel acknowledged over-triggering for some languages and locales. — [Forums 787736 "Model Guardrails Too Restrictive?"](https://developer.apple.com/forums/thread/787736); [Forums 793876](https://developer.apple.com/forums/thread/793876); [Forums 792888](https://developer.apple.com/forums/thread/792888); [Forums 802921](https://developer.apple.com/forums/thread/802921)
- `LanguageModelSession.logFeedbackAttachment` is the suggested way to capture false-positive reports. — referenced in forum results ([Forums 833614](https://origin-devforums.apple.com/forums/thread/833614))

### Inferences
- A "suggest macros, user confirms" flow fits within "human supervision". An auto-dose-from-photo flow without confirmation would arguably fall under the prohibited unsupervised medical decision clause.
- Because `.permissiveContentTransformations` reportedly does not cover `Generable` output, Trio cannot rely on relaxing guardrails for the structured-output path. Code must handle `guardrailViolation` gracefully (fall back to manual entry).
- Food photos are low-risk content, but prompts mentioning "insulin", "dose", or "diabetes" might trip guardrails. Keep the prompt nutrition-only (no dosing language). This is untested; treat it as a hypothesis.

### Gaps
- No forum report found of guardrails blocking food, nutrition, or diabetes prompts specifically, and no report of guardrail behavior on image inputs.
- No Apple statement on whether medical-adjacent apps need any extra review or entitlement for Foundation Models (none found).

## Q3. Vision framework: classification taxonomy, food granularity, captioning

### Takeaway
Vision has no food-specific or nutrition API and no captioning or "describe image" API. Its generic `ClassifyImageRequest` / `VNClassifyImageRequest` returns labels from a fixed taxonomy that includes some food categories (size and contents unverified this session). Apple's 2026 guidance is that open-ended image description belongs to Foundation Models with image input, and Vision is for fixed tasks.

### Cited Findings
- WWDC26 session 237 says Vision supports "over 30 types of image analysis", including image classification, and names no new classification or captioning API. New iOS 27-cycle Vision APIs are segmentation (`GenerateIterativeSegmentationRequest` with `addIncludedPoint(_:)`, which needs an on-device asset download via `downloadAssets` / `assetStatus`) and saliency cropping (`GenerateObjectnessBasedSaliencyImageRequest`, including watchOS). — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/)
- Apple's guidance: Foundation Models for "open-ended and descriptive tasks". Vision is "fine-tuned for specific tasks" and fast enough for real-time video. Combine them via tool calling. Captioning is shown via Foundation Models, not Vision. — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/)
- Searches for the `VNClassifyImageRequest` taxonomy (label count, food classes) returned no Apple documentation this session.

### Inferences
- Tap-to-segment could let a user isolate individual food items on a plate before sending crops to the model. This is a possible UX aid, not a nutrition feature.
- `ClassifyImageRequest` labels could serve as a cheap "is this food?" pre-check, but they will not give portion or macro data.

### Gaps
- Exact `ClassifyImageRequest` taxonomy size and food-label granularity were not verified. Background knowledge (unverified) suggests about 1,300 labels with generic food classes. It can be enumerated on-device with `knownClassifications(forRevision:)` (VN API) or the Swift `ClassifyImageRequest` equivalent.
- No Apple food-recognition, nutrition, or calorie API was found in Vision, VisionKit, or Core ML documentation.

## Q4. Visual Intelligence and App Intents: can a third-party app invoke it and get text back?

### Takeaway
No. Visual Intelligence (camera or screenshot) is user-initiated system UI. Third-party apps integrate only as result providers: they implement `IntentValueQuery` and receive a `SemanticContentDescriptor` (labels + pixel buffer) to return their own `AppEntity` results. There is no API for an app to submit a photo to Visual Intelligence and receive a description.

### Cited Findings
- iOS 26 App Intents: `IntentValueQuery.values(for: SemanticContentDescriptor) -> [AppEntity]`. The descriptor exposes `labels: [String]` and `pixelBuffer: CVReadOnlyPixelBuffer?`. The system queries every registered app and aggregates results in the Visual Intelligence UI, and tapping a result opens the app. Multiple result types need a `@UnionValue` enum, and each entity type needs an `OpenIntent`. — [Blake Crosley, App Intents 2.0 in iOS 26 (third-party)](https://blakecrosley.com/blog/app-intents-2-ios-26-additions); [community skill summary (third-party)](https://smithery.ai/skills/rshankras/visual-intelligence)
- WWDC 2026 App Intents additions: new entity and intent schemas to add content to Spotlight's semantic index, and a new **View Annotations API** letting Siri act on on-screen content conversationally. — [MacRumors 2026-06-09](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- The iOS 27 Camera app has a "Siri mode" (Visual Intelligence) that gives qualitative food feedback (see Q9). It is a system feature, not a developer API. — [MacRumors iOS 27 Health guide](https://www.macrumors.com/guide/ios-27-health-app/)

### Inferences
- Trio could theoretically register an `IntentValueQuery` so a Visual Intelligence camera capture surfaces a "Log carbs in Trio" entity, using the passed `pixelBuffer` with its own Foundation Models call. The analysis would still be Trio's own on-device model call, not Visual Intelligence's.

### Gaps
- No Apple primary doc fetched this session for `SemanticContentDescriptor` (details come from third-party write-ups). Field names should be confirmed in Xcode.

## Q5. Siri / Apple Intelligence (Gemini-based), PCC, and ChatGPT extension: programmatic access?

### Takeaway
There is no public API to send an image to Siri (or "Siri AI") and get structured output back. Apps integrate with Siri only via App Intents. The one developer-facing route to Apple's server models is the new `PrivateCloudComputeLanguageModel` in the Foundation Models framework (iOS 27 cycle, entitlement, quotas; image support undocumented). The ChatGPT extension is a system feature with no third-party API, but in 2026 Apple lets apps call Claude or Gemini through Foundation Models via vendor Swift packages (with the developer's own credentials).

### Cited Findings
- **Gemini basis (confirmed):** joint Apple–Google statement, 2026-01-12: next-generation Apple Foundation Models will be based on Gemini models and cloud technology and will help power "a more personalized Siri coming this year". Apple Intelligence continues to run on-device and on PCC. — [Google blog joint statement](https://blog.google/company-news/inside-google/company-announcements/joint-statement-google-apple/)
- **"Siri AI" status:** Apple's support page (published 2026-09-14) lists "Siri AI" as a server-based feature with daily limits and says "Siri AI is in beta". It says "expanded access to such features will be available for a fee in the future". — [Apple Support 121115](https://support.apple.com/en-us/121115)
- Timeline confusion (iOS 26.4 vs iOS 27) appears across secondary sources. Some say the rollout spanned two phases, iOS 26.4 and iOS 27, but these are low-quality blogs. — [MacObserver](https://www.macobserver.com/tips/round-ups/does-siri-ai-use-google-gemini/); [kersai.com (low quality)](https://kersai.com/apple-siri-google-gemini-upgrade-2026-complete-guide-ios-26-ios-27/)
- **Developers cannot reach the Gemini-derived Siri models directly.** The sanctioned route is the Foundation Models framework. — [MacObserver (secondary)](https://www.macobserver.com/tips/round-ups/does-siri-ai-use-google-gemini/). Siri capabilities for apps are built on App Intents. — [same](https://www.macobserver.com/tips/round-ups/does-siri-ai-use-google-gemini/)
- A claimed `INIntentGeminiExtension` developer API appears only in a low-quality blog and was not found in Apple docs. Treat it as **fabricated or unverified**. — noted in search results ([wowhow.cloud](https://wowhow.cloud/blogs/apple-wwdc-2026-ios-27-siri-extensions-claude-gemini-chatgpt-developer-guide))
- **Developer PCC access:** `PrivateCloudComputeLanguageModel` (details in Q1). — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- **Third-party LLMs via the framework:** Anthropic and Google Swift packages; developer-supplied credentials (OAuth, Keychain). — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- On-screen content: apps can associate entities with `NSUserActivity` so users can ask Siri or ChatGPT about visible content (user-initiated). — [Blake Crosley (third-party)](https://blakecrosley.com/blog/app-intents-2-ios-26-additions)

### Inferences
- For Trio, "use Siri AI to analyze my meal photo" is not implementable as an in-app programmatic call. At most a user could ask Siri about on-screen content, which yields free text in system UI, not values Trio can read.
- Calling Claude or Gemini through Foundation Models is technically first-party plumbing, but it is not on-device and not Apple's model. It falls outside this note's scope (cloud/third-party).

### Gaps
- Whether the PCC model is the same model family that powers Siri AI is not stated in fetched sources.
- No Apple doc on the ChatGPT extension having any developer API (none found; consistent with it being system-only).

## Q6. Image Playground, Writing Tools, other Apple Intelligence APIs

### Takeaway
None are relevant to photo-to-macros. Image Playground generates images and Writing Tools rewrites text. Apple's support page lists Image Playground and intelligent photo editing as server-based features with daily limits.

### Cited Findings
- Server-based features (Siri AI, intelligent photo editing, Image Playground, cloud models in Shortcuts) have varying daily limits. — [Apple Support 121115](https://support.apple.com/en-us/121115)
- "Cloud models in Shortcuts" are a user-facing feature. — [Apple Support 121115](https://support.apple.com/en-us/121115)

### Inferences
- A user-built Shortcut using cloud models could in theory analyze a photo and pass text to Trio via an App Intent. This is a user-side workaround, not an app API, and subject to daily limits.

### Gaps
- Not verified whether Shortcuts' "Use Model" action accepts image input in iOS 27, or which model it uses.

## Q7. Hardware, region, language, storage requirements

### Takeaway
Apple Intelligence (and therefore Foundation Models) needs iPhone 15 Pro / 15 Pro Max, iPhone Air, or iPhone 16 models and later. It also needs Apple Intelligence enabled, matching device and Siri languages, and up to 8 GB of storage (14 GB on iPhone 17 Pro / Pro Max / Air). It is unavailable on mainland-China devices or accounts.

### Cited Findings
- Supported: "iPhone 16 models or later", iPhone 15 Pro and 15 Pro Max, iPhone Air. — [Apple Support 121115 (2026-09-14)](https://support.apple.com/en-us/121115)
- Storage: up to 14 GB on iPhone 17 Pro / Pro Max / Air, up to 8 GB on other supported models. — [Apple Support 121115](https://support.apple.com/en-us/121115)
- Languages: English, Danish, Dutch, French, German, Italian, Norwegian, Portuguese, Spanish, Swedish, Turkish, Vietnamese, Simplified and Traditional Chinese, Japanese, Korean. Device language and Siri language must match, and changing the Siri language can temporarily make Apple Intelligence unavailable. — [Apple Support 121115](https://support.apple.com/en-us/121115)
- China: features "will not currently work for supported devices purchased in China mainland" (or with a mainland Apple Account region while in mainland China). EU: next-generation features are available on iOS 27. — [Apple Support 121115](https://support.apple.com/en-us/121115)
- PCC model: "only available on Apple Intelligence devices"; on-device works offline, PCC needs internet. — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- On-device context is reportedly 4096 on OS 26 vs 8192 on OS 27 "for newer devices" (implies per-device variation). — [WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)

### Inferences
- `modelNotReady` (asset still downloading after enabling Apple Intelligence or after an OS update) is a realistic runtime state. The Trio UI should hide or disable the photo button rather than fail.
- "For newer devices" suggests older Apple Intelligence iPhones (e.g., 15 Pro) may get a smaller context or older model even on iOS 27. Image input on those devices is not confirmed.

### Gaps
- Whether image input works on every Apple Intelligence iPhone under iOS 27 or only newer ones. RAM requirements are not stated by Apple.

## Q8. Portion size / volume estimation APIs (LiDAR, ARKit depth, Object Capture)

### Takeaway
No Apple API produces food portion, volume, or mass estimates. Only general-purpose depth and 3D primitives exist (LiDAR scene depth in ARKit, Object Capture photogrammetry), which would require Trio to build its own volume estimation.

### Cited Findings
- No portion or volume capability is mentioned in WWDC26 sessions 237 or 241 (image understanding / Foundation Models). — [WWDC26 session 237](https://developer.apple.com/videos/play/wwdc2026/237/); [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)

### Inferences
- Portion size from a 2D photo will rely on the language model's implicit priors (plate size, typical servings). This is the dominant error source for carb estimation, and no Apple API mitigates it.

### Gaps
- ARKit `ARFrame.sceneDepth` (LiDAR, Pro iPhones) and RealityKit Object Capture exist per background knowledge but were **not re-verified this session**. No Apple sample or API for food volume was found.

## Q9. Apple Health / HealthKit meal-photo-to-nutrition features (iOS 26/27), Health+ / AI coach

### Takeaway
iOS 27 adds a qualitative food check through the Camera app's Siri / Visual Intelligence mode. It gives a "very low"–"very high" nutritional ranking plus traits like processed, protein, or high sugar. It does not give calories or macros, and per MacRumors its data does not sync to Health. There is no developer API for it. The Health+ AI coach ("Project Mulberry") was scrapped before the iOS 27 beta per MacRumors. Nothing photo-to-nutrition is exposed through HealthKit.

### Cited Findings
- iOS 27: open the Camera app to the new Siri mode and photograph a food item. The output is not exact calories; it indicates heavily processed, contains protein, high sugar, and gives a ranking from "very low" to "very high". "Data does not sync to the Health app." Visual Intelligence requires iPhone 15 Pro or later. Article dated 2026-08-04 (beta period). — [MacRumors iOS 27 Health guide](https://www.macrumors.com/guide/ios-27-health-app/)
- Health+ AI service: rumored but scrapped before the iOS 27 beta and not part of iOS 27; it may resurface. A 2026-10-12 MacRumors headline says Apple's "New Health App" is in beta and won't launch with iOS 27.2 (content not fetched). — [MacRumors iOS 27 Health guide](https://www.macrumors.com/guide/ios-27-health-app/)
- Earlier reporting: the coach was scaled back, with capabilities expected to roll out individually in Health over time. A smaller "Quartz" tier may focus on educational video. "Health Coaching" / "Health Plans" code strings appeared in the iOS 26.4 beta. — [Athletech News](https://athletechnews.com/apple-is-scaling-back-its-ai-health-coach-plans-per-report/); [Wareable](https://www.wareable.com/apple/apple-quartz-health-plus-ai-coaching-service-2026-launch-rumor); [Macworld](https://www.macworld.com/article/3062678/ios-26-4-beta-suggests-apple-hasnt-given-up-on-its-ai-health-coach.html) (all rumor/reporting, not Apple statements)
- Nutrition-label scanning writing calories and protein to Health in iOS 27 is claimed by one third-party app-vendor blog. It is **not mentioned** in the MacRumors iOS 27 Health guide. — [bentobunny.app (third-party, unverified)](https://www.bentobunny.app/guides/ios-27-calorie-tracking-features); [sahha.ai (third-party)](https://sahha.ai/blog/ios-27-health-fitness-developers/)

### Inferences
- Apple itself ships only qualitative food judgments, not gram estimates. This may reflect Apple's own caution about the accuracy or liability of model-derived macros, which is relevant context for Trio's design (always user-confirmed, never auto-dosed).

### Gaps
- Unconfirmed whether iOS 27 Health has nutrition-label scanning (conflicting / third-party-only sources).
- Contents of the "New Health App" beta (2026-10) not fetched; unknown whether it includes meal logging or any HealthKit API.
- No HealthKit API for food recognition or photo nutrition was found in any source.
